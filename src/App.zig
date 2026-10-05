const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");
const terminal = @import("terminal");
const tools = @import("tools");

const Choice = @import("Choice.zig");
const command = @import("command/root.zig");
const Config = @import("Config.zig");
const describe = @import("describe.zig");
const discovery = @import("discovery/root.zig");
const escape = @import("escape.zig");
const Herdr = @import("Herdr.zig");
const layout = @import("layout.zig");
const Message = @import("Message.zig");
const project = @import("project.zig");
const Reports = @import("Reports.zig");
const Screen = @import("Screen.zig");
const sources = @import("sources.zig");
const system_prompt = @import("system_prompt.zig");
const testing = @import("testing.zig");
const Transcript = @import("Transcript.zig");
const ui = @import("ui/root.zig");

const App = @This();

const effort_default: core.Provider.Effort = .xhigh;

const no_model_refusal = "Select a model with /model before you send a message.";
const signed_out_refusal = "Sign in with /login before you send a message.";

const fetch_wait_text = "Drinky fetches the model list.";

const turn_cancel_notice = "Press Esc again to cancel the turn. The draft stays.";
const turn_message_notice = "Drinky sends no message while a turn runs. The draft stays.";

const retry_caption: ui.Caption = .{
    .title = "Failed turn",
    .controls = "Ctrl+N: Try again · Esc: Dismiss",
    .rows_max = Screen.editor_caption_rows_max,
};
const retry_note = "Drinky asked the model to continue from the committed work.";
const retry_request =
    "<retry_request>\n{s}\nContinue from the last committed checkpoint.\n</retry_request>";

const removal_caption: ui.Caption = .{
    .title = "Canceled turn",
    .controls = "Ctrl+N: Remove and edit · Esc: Keep turn",
    .rows_max = Screen.editor_caption_rows_max,
};
const removal_warning = "Press Ctrl+N again to remove the canceled turn. Tool changes stay.";

const intro_keys = [_][]const u8{
    "Enter: Send",
    "Shift+Enter: New line",
    "Esc: Cancel",
    "Ctrl+C: Clear",
    "Ctrl+D: Quit",
};

const intro_text = blk: {
    var line: []const u8 = "";
    for (intro_keys) |hint| line = line ++ hint ++ ui.paint.separator;
    break :blk line ++ "/help: Commands";
};

const login_callback_controls = "Enter: Replay callback URL · Esc: Cancel";
const login_device_controls = "Esc: Cancel";

const sign_in_titles = blk: {
    var titles: [accounts.Account.table.len][]const u8 = undefined;
    for (&accounts.Account.table, 0..) |*row, index| titles[index] = "Sign in: " ++ row.id;
    break :blk titles;
};

const repeat_window_ms = 500;

const escape_wait_ms = 50;

const queue_capacity = 256;

gpa: std.mem.Allocator,
io: std.Io,
tty: *terminal.Tty,
resize: terminal.Resize,
config: Config,
account_registry: accounts.Registry,
state: accounts.State,
tool_registry: tools.Registry,
session: core.Session,
client: ?*accounts.Client,
client_account: ?usize,
leases: std.ArrayList(Lease),
configured: ?Choice,
choice: Choice,
mode: Mode,
offer: ?Offer,
directory_label: []const u8,
working_directory: []const u8,
home_directory: []const u8,
branch_root: ?[]const u8,
project_instructions: discovery.instructions.Result,
skill_registry: discovery.skills.Registry,
system: []const u8,
document: []const u8,
sources_page: []const u8,
skill_guard: tools.SkillGuard,
screen: Screen,
input: terminal.Input,
running: bool,
ctrl_c_ms_last: i64,
ctrl_d_ms_last: i64,
escape_deadline_ms: ?i64,
queue: std.Io.Queue(UiEvent),
queue_buffer: [queue_capacity]UiEvent,
input_future: ?std.Io.Future(void),
resize_future: ?std.Io.Future(void),
tick_future: ?std.Io.Future(void),
frame_grid: FrameGrid,
herdr: Herdr,

const Options = struct {
    working_directory: []const u8,
    home: []const u8,
    writer: *std.Io.Writer,
    environment: *const std.process.Environ.Map,
    environ: std.process.Environ = .empty,
    herdr: ?Herdr.Endpoint = null,
    transport: ?providers.Transport = null,
    browser: ?accounts.oauth.login.Browser = null,
    loopback: ?accounts.oauth.callback.Loopback = null,
};

const FrameGrid = struct {
    deadline_ns: i96,

    const interval_ns = 16 * std.time.ns_per_ms;

    fn reset(now_ns: i96) FrameGrid {
        return .{ .deadline_ns = now_ns };
    }

    fn advance(self: *FrameGrid, now_ns: i96) void {
        const next_ns = self.deadline_ns + interval_ns;
        self.deadline_ns = if (next_ns <= now_ns) now_ns else next_ns;
    }
};

const UiEvent = union(enum) {
    keys: []u8,
    session: core.Session.Event,
    accounts: accounts.Registry.Event,
    tick,
    resize,

    fn deinit(self: *const UiEvent, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .keys => |bytes| gpa.free(bytes),
            .session => |*event| event.deinit(gpa),
            .accounts => |*event| event.deinit(gpa),
            .tick, .resize => {},
        }
    }
};

const Lease = struct {
    client: *accounts.Client,
    setups: usize,
};

const Mode = union(enum) {
    prompt: Prompt,
    turn: Turn,
    picker,
    fetch: Fetch,
    page,
    sign_in: SignIn,

    const Prompt = struct {
        confirmation: ?Confirmation = null,

        const Confirmation = enum { message, quit, removal };
    };

    const Turn = struct {
        start: usize,
        line: ?[]u8,
        mutated: bool = false,
        cancel_armed: bool = false,
        cancel_sent: bool = false,
    };

    const Fetch = struct {
        account: usize,
        exit: ?Exit = null,

        const Exit = enum { step, command };
    };

    const SignIn = struct {
        account: usize,
        takes_paste: bool,
        event_index: ?usize = null,
        cancel_sent: bool = false,
    };
};

const Offer = union(enum) {
    retry: []u8,
    removal: Removal,

    const Removal = struct {
        line: []u8,
        range: Transcript.Range,
        mutated: bool,
    };

    fn deinit(self: *const Offer, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .retry => |request| gpa.free(request),
            .removal => |removal| gpa.free(removal.line),
        }
    }
};

const TurnStart = struct {
    text: []const u8,
    start: usize,
    line: ?[]const u8,
};

const session_sink_vtable: core.Session.Sink.VTable = .{ .emit = emitSessionEvent };
const accounts_sink_vtable: accounts.Registry.Sink.VTable = .{ .emit = emitAccountsEvent };

fn emitSessionEvent(ptr: *anyopaque, event: *const core.Session.Event) void {
    const self: *App = @ptrCast(@alignCast(ptr));
    const owned = event.dupe(self.gpa) catch return;
    self.keep(.{ .session = owned });
}

fn emitAccountsEvent(ptr: *anyopaque, event: *const accounts.Registry.Event) void {
    const self: *App = @ptrCast(@alignCast(ptr));
    const owned = event.dupe(self.gpa) catch return;
    self.keep(.{ .accounts = owned });
}

fn keep(self: *App, event: UiEvent) void {
    self.queue.putOneUncancelable(self.io, event) catch event.deinit(self.gpa);
}

fn homeDirectory(
    gpa: std.mem.Allocator,
    io: std.Io,
    directories: *const accounts.json_store.Directories,
) ![]u8 {
    const resolved = try std.fs.path.resolve(
        gpa,
        &.{ directories.working_directory, directories.home },
    );
    errdefer gpa.free(resolved);
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, resolved, gpa) catch return resolved;
    defer gpa.free(canonical);
    const owned = try gpa.dupe(u8, canonical);
    gpa.free(resolved);
    return owned;
}

fn showProject(self: *App, inside_herdr: bool) void {
    if (inside_herdr) return;
    self.screen.directory_shown = self.directory_label;
    self.branch_root = self.project_instructions.projectRoot();
    self.refreshBranch();
}

fn refreshBranch(self: *App) void {
    const root = self.branch_root orelse return self.screen.setBranch("");
    var maybe_head = project.head(self.gpa, self.io, root);
    if (maybe_head) |*head| self.screen.setBranch(head.name()) else self.screen.setBranch("");
}

pub fn init(self: *App, gpa: std.mem.Allocator, io: std.Io, options: *const Options) !void {
    const cwd = options.working_directory;
    const directories: accounts.json_store.Directories = .{
        .working_directory = cwd,
        .home = options.home,
    };
    self.initFields(gpa, io);
    errdefer self.input.deinit();

    self.config = try Config.load(gpa, io, &directories);
    errdefer self.config.deinit(gpa);

    try self.account_registry.init(gpa, io, &.{
        .directories = directories,
        .environment = options.environment,
        .sink = .{ .ptr = self, .vtable = &accounts_sink_vtable },
        .timeouts = self.config.timeouts,
        .transport = options.transport,
        .browser = options.browser,
        .loopback = options.loopback,
    });
    errdefer self.account_registry.deinit();

    self.working_directory = cwd;
    self.home_directory = try homeDirectory(gpa, io, &directories);
    errdefer gpa.free(self.home_directory);
    self.directory_label = try ui.status.directoryLabel(gpa, &.{
        .path = cwd,
        .home = self.home_directory,
    });
    errdefer gpa.free(self.directory_label);

    self.project_instructions = try discovery.instructions.discover(gpa, io, cwd);
    errdefer self.project_instructions.deinit();
    self.state = try accounts.State.open(gpa, io, &.{
        .directories = directories,
        .project = self.project_instructions.projectRoot() orelse cwd,
    });
    errdefer self.state.deinit();

    const user_skills = try std.fs.path.resolve(
        gpa,
        &.{ cwd, options.home, ".agents", "skills" },
    );
    defer gpa.free(user_skills);
    self.skill_registry = try discovery.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = cwd,
        .project_root = self.project_instructions.projectRoot(),
    });
    errdefer self.skill_registry.deinit();
    self.skill_guard = .{ .working_directory = cwd };
    var required_missing: std.ArrayList(Config.RequiredSkill) = .empty;
    defer required_missing.deinit(gpa);
    const required_capped = try self.resolveRequiredSkills(&required_missing);
    self.system = try system_prompt.compose(gpa, &.{
        .current_time = std.Io.Clock.real.now(io),
        .working_directory = cwd,
        .user_instructions = self.config.user_instructions.files(),
        .project_instructions = &self.project_instructions,
        .skills = self.skill_registry.items(),
        .required_skills = self.skill_guard.rules(),
    });
    errdefer gpa.free(self.system);
    self.sources_page = try sources.compose(gpa, &.{
        .user_instructions = self.config.user_instructions.files(),
        .project_instructions = self.project_instructions.files(),
        .skills = &self.skill_registry,
        .required_skills = self.skill_guard.rules(),
        .required_missing = required_missing.items,
        .roots = .{ .working_directory = cwd, .home_directory = self.home_directory },
    });
    errdefer gpa.free(self.sources_page);
    self.document = try describe.compose(gpa, &.{
        .config = &self.config,
        .effort_default = effort_default,
        .key_hints = &intro_keys,
        .repeat_window_ms = repeat_window_ms,
    });
    errdefer gpa.free(self.document);

    self.tool_registry = .{
        .host = .{
            .io = io,
            .environ = options.environ,
            .bash = self.config.bash,
            .document = self.document,
        },
        .skill_guard = &self.skill_guard,
    };
    errdefer self.freeClients();
    self.session = .init(gpa, io, &.{
        .sink = .{ .ptr = self, .vtable = &session_sink_vtable },
        .runner = self.tool_registry.runner(),
        .tools = &tools.Registry.specs,
        .retry = self.config.retry,
    });
    errdefer self.session.deinit();

    self.choice.effort = self.state.start.effort orelse
        self.config.effort_default orelse effort_default;
    if (self.startAccount()) |account| {
        self.adopt(account);
        try self.state.seed(account, self.choice.modelName(), self.choice.effort);
    }

    self.screen = Screen.init(gpa, options.writer, self.choice.effort);
    errdefer self.screen.deinit();
    self.screen.bash_timeout_ms = self.config.bash.timeout_ms;
    self.screen.window_pages = self.config.window_pages;
    self.screen.gauge = self.config.gauge;
    self.screen.display_roots = .{
        .working_directory = cwd,
        .home_directory = self.home_directory,
    };
    self.showProject(options.herdr != null);

    errdefer self.closeQueue();
    try self.session.start();
    try self.account_registry.start();
    try self.sync();
    try self.reportStart(required_capped);
    self.herdr.start(options.herdr) catch |err| try self.recordEvent(
        .failure,
        "Drinky could not start the state reports to Herdr because of error {s}.",
        .{@errorName(err)},
    );
}

pub fn deinit(self: *App) void {
    self.closeQueue();
    self.herdr.deinit();
    self.dropOffer();
    switch (self.mode) {
        .turn => |turn| if (turn.line) |line| self.gpa.free(line),
        .prompt, .picker, .fetch, .page, .sign_in => {},
    }
    self.screen.deinit();
    self.session.deinit();
    self.freeClients();
    self.gpa.free(self.document);
    self.gpa.free(self.sources_page);
    self.gpa.free(self.system);
    self.skill_registry.deinit();
    self.state.deinit();
    self.project_instructions.deinit();
    self.gpa.free(self.directory_label);
    self.gpa.free(self.home_directory);
    self.account_registry.deinit();
    self.config.deinit(self.gpa);
    self.input.deinit();
}

pub fn run(self: *App, tty: *terminal.Tty) !void {
    self.tty = tty;
    try self.resize.init();
    defer self.resize.deinit();
    defer self.prepareTerminalExit();
    try self.refresh();
    self.frame_grid = .reset(self.nowNs());

    self.running = true;
    defer self.stopTasks();
    self.input_future = try self.io.concurrent(readInput, .{self});
    self.resize_future = try self.io.concurrent(readResize, .{self});

    try self.runLoop();
}

fn reportStart(self: *App, required_capped: bool) !void {
    const config = &self.config;
    try self.screen.appendIntro(intro_text);
    if (config.effort_dropped) |dropped| try self.recordEvent(
        .failure,
        "Drinky ignored the configured default effort level \"{s}\" because Drinky does not " ++
            "know that level. Drinky uses the effort level \"{s}\".",
        .{ dropped, @tagName(self.choice.effort) },
    );
    if (config.bash_timeout_ms_dropped) |dropped| try self.recordEvent(
        .failure,
        "Drinky ignored the configured command timeout {d} because the value must be from {d} " ++
            "to {d} milliseconds. Drinky uses the default timeout of {d} milliseconds.",
        .{
            dropped,
            tools.Context.Bash.timeout_ms_min,
            tools.Context.Bash.timeout_ms_max,
            config.bash.timeout_ms,
        },
    );
    if (config.window_pages_dropped) |dropped| try self.recordEvent(
        .failure,
        "Drinky ignored the configured window page count {d} because the count must be from " ++
            "{d} to {d}. Drinky uses the default count of {d} pages.",
        .{
            dropped,
            layout.window_pages_min,
            layout.window_pages_max,
            config.window_pages,
        },
    );
    if (config.gauge_dropped) |dropped| try self.recordEvent(
        .failure,
        "Drinky ignored the gauge shares {d} and {d}. A share must be from {d} to {d}, and " ++
            "the warning share must not pass the error share. Drinky uses the shares {d} " ++
            "and {d}.",
        .{
            dropped.percent_warning,
            dropped.percent_error,
            ui.status.Gauge.percent_min,
            ui.status.Gauge.percent_max,
            config.gauge.percent_warning,
            config.gauge.percent_error,
        },
    );
    if (required_capped) try self.recordEvent(
        .failure,
        "Drinky used only the first {d} required skills in {s}.",
        .{ tools.SkillGuard.rules_max, config.path },
    );
    if (config.load_error) |err| try self.recordEvent(
        .failure,
        "Drinky could not read the config file {s} because of error {s}. Drinky uses " ++
            "the default value of each key.",
        .{ config.path, @errorName(err) },
    );
    for (config.unknown_keys) |key| try self.recordEvent(
        .failure,
        "Drinky ignored the unknown config key \"{s}\" in {s}.",
        .{ key, config.path },
    );
    if (config.unknown_keys_omitted) try self.recordEvent(
        .failure,
        "Drinky omitted the remaining unknown config keys in {s}.",
        .{config.path},
    );
    try self.recordReports(&config.user_instructions.reports);
    try self.recordReports(&self.project_instructions.reports);
    try self.recordReports(&self.skill_registry.reports);
    if (self.choice.account == null) {
        try self.reportNotice(.information, "Select an account to sign in.", .{});
        try self.runCommand("/login");
    }
}

fn initFields(self: *App, gpa: std.mem.Allocator, io: std.Io) void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .tty = undefined,
        .resize = undefined,
        .config = undefined,
        .account_registry = undefined,
        .state = undefined,
        .tool_registry = .{ .host = .{ .io = io } },
        .session = undefined,
        .client = null,
        .client_account = null,
        .leases = .empty,
        .configured = null,
        .choice = .{ .effort = effort_default },
        .mode = .{ .prompt = .{} },
        .offer = null,
        .directory_label = "",
        .working_directory = "",
        .home_directory = "",
        .branch_root = null,
        .project_instructions = undefined,
        .skill_registry = undefined,
        .system = "",
        .document = "",
        .sources_page = "",
        .skill_guard = .{},
        .screen = undefined,
        .input = .init(gpa),
        .running = false,
        .ctrl_c_ms_last = -repeat_window_ms,
        .ctrl_d_ms_last = -repeat_window_ms,
        .escape_deadline_ms = null,
        .queue = undefined,
        .queue_buffer = undefined,
        .input_future = null,
        .resize_future = null,
        .tick_future = null,
        .frame_grid = .reset(0),
        .herdr = .init(io),
    };
    self.queue = std.Io.Queue(UiEvent).init(&self.queue_buffer);
}

fn prepareTerminalExit(self: *App) void {
    self.tty.setAlternateScreen(false) catch return;
    self.screen.parkCursor() catch {};
}

fn stopTasks(self: *App) void {
    self.queue.close(self.io);
    self.cancelFuture(&self.input_future);
    self.cancelFuture(&self.resize_future);
    self.cancelFuture(&self.tick_future);
}

fn closeQueue(self: *App) void {
    self.queue.close(self.io);
    self.drainQueue();
}

fn openClient(self: *App, account: usize) !*accounts.Client {
    try self.leases.ensureUnusedCapacity(self.gpa, 1);
    const client = try self.gpa.create(accounts.Client);
    errdefer self.gpa.destroy(client);
    try self.account_registry.open(client, account);
    self.leases.appendAssumeCapacity(.{ .client = client, .setups = 0 });
    return client;
}

fn closeClient(self: *App) void {
    self.client = null;
    self.client_account = null;
    self.configured = null;
    self.sweepClients();
}

fn releaseSetup(self: *App, provider: core.Provider) void {
    for (self.leases.items) |*lease| {
        if (lease.client.provider().ptr != provider.ptr) continue;
        lease.setups -= 1;
        break;
    }
    self.sweepClients();
}

fn sweepClients(self: *App) void {
    var index = self.leases.items.len;
    while (index > 0) {
        index -= 1;
        const lease = self.leases.items[index];
        if (lease.setups > 0 or lease.client == self.client) continue;
        lease.client.deinit();
        self.gpa.destroy(lease.client);
        _ = self.leases.swapRemove(index);
    }
}

fn freeClients(self: *App) void {
    self.client = null;
    self.client_account = null;
    self.configured = null;
    for (self.leases.items) |lease| {
        lease.client.deinit();
        self.gpa.destroy(lease.client);
    }
    self.leases.deinit(self.gpa);
    self.leases = .empty;
}

fn cancelFuture(self: *App, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.cancel(self.io);
        maybe_future.* = null;
    }
}

fn awaitFuture(self: *App, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.await(self.io);
        maybe_future.* = null;
    }
}

fn drainQueue(self: *App) void {
    var batch: [queue_capacity]UiEvent = undefined;
    while (true) {
        const count = self.queue.get(self.io, &batch, 0) catch break;
        if (count == 0) break;
        for (batch[0..count]) |event| event.deinit(self.gpa);
    }
}

fn runLoop(self: *App) !void {
    var batch: [queue_capacity]UiEvent = undefined;
    while (self.running) {
        const count = self.queue.get(self.io, &batch, 1) catch |err| switch (err) {
            error.Closed, error.Canceled => break,
        };
        const ticked = try self.applyBatch(batch[0..count]);
        self.herdr.sync(self.herdrState());
        try self.flushEscape();
        if (ticked) {
            self.awaitFuture(&self.tick_future);
            if (self.screen.advanceFrame()) {
                try self.refresh();
                self.screen.dirty = false;
            }
        }
        const waiting = self.screen.dirty or
            self.screen.animating() or
            self.escape_deadline_ms != null;
        if (waiting and self.tick_future == null) try self.armTick();
    }
}

fn setMode(self: *App, mode: Mode) void {
    self.mode = mode;
    self.screen.dirty = true;
}

fn caption(self: *const App) ?ui.Caption {
    return switch (self.mode) {
        .sign_in => |sign_in| .{
            .title = sign_in_titles[sign_in.account],
            .controls = if (sign_in.takes_paste) login_callback_controls else login_device_controls,
            .rows_max = Screen.editor_caption_rows_max,
        },
        .prompt => if (self.offer) |offer| switch (offer) {
            .retry => retry_caption,
            .removal => removal_caption,
        } else null,
        .turn, .picker, .fetch, .page => null,
    };
}

fn herdrState(self: *const App) Herdr.State {
    return switch (self.mode) {
        .turn => .working,
        .prompt, .picker, .fetch, .page, .sign_in => if (self.offer) |offer| switch (offer) {
            .retry => .blocked,
            .removal => .idle,
        } else .idle,
    };
}

fn applyBatch(self: *App, events: []const UiEvent) !bool {
    std.debug.assert(events.len <= queue_capacity);
    var applied_count: usize = 0;
    errdefer for (events[applied_count..]) |event| event.deinit(self.gpa);

    var ticked = false;
    for (events) |*event| {
        applied_count += 1;
        switch (event.*) {
            .tick => ticked = true,
            .resize => self.screen.dirty = true,
            .keys => |bytes| {
                defer self.gpa.free(bytes);
                self.refreshBranch();
                try self.handleKeys(bytes);
            },
            .session => |*session_event| {
                defer session_event.deinit(self.gpa);
                try self.applySessionEvent(session_event);
            },
            .accounts => |*accounts_event| {
                defer accounts_event.deinit(self.gpa);
                try self.applyAccountsEvent(accounts_event);
            },
        }
    }
    return ticked;
}

fn armTick(self: *App) !void {
    self.frame_grid.advance(self.nowNs());
    const deadline_ns = self.frame_grid.deadline_ns;
    self.tick_future = self.io.concurrent(frameTimer, .{ self, deadline_ns }) catch |err| {
        try self.reportNotice(
            .failure,
            "Drinky could not start the frame timer because of error {s}.",
            .{@errorName(err)},
        );
        try self.refresh();
        self.screen.dirty = false;
        self.frame_grid = .reset(self.nowNs());
        return;
    };
}

fn frameTimer(self: *App, deadline_ns: i96) void {
    const deadline: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(deadline_ns),
        .clock = .awake,
    };
    deadline.wait(self.io) catch return;
    self.queue.putOne(self.io, .tick) catch {};
}

fn readResize(self: *App) void {
    while (true) {
        self.resize.wait(self.io) catch return;
        self.queue.putOne(self.io, .resize) catch return;
    }
}

fn readInput(self: *App) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = self.tty.read(&buffer) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                self.queue.close(self.io);
                return;
            },
        };
        const copy = self.gpa.dupe(u8, buffer[0..count]) catch {
            self.queue.close(self.io);
            return;
        };
        self.queue.putOne(self.io, .{ .keys = copy }) catch {
            self.gpa.free(copy);
            return;
        };
    }
}

fn startAccount(self: *App) ?usize {
    if (self.state.start.account) |account| {
        if (self.account_registry.isAuthenticated(account)) return account;
    }
    return self.account_registry.firstAuthenticated();
}

fn sync(self: *App) !void {
    if (self.choice.account != self.client_account) {
        self.closeClient();
        if (self.choice.account) |account| {
            if (self.openClient(account)) |client| {
                self.client = client;
                self.client_account = account;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SignedOut => {
                    self.choice.account = null;
                    self.choice.model = null;
                },
            }
        }
    }
    try self.configure();
    self.screen.showChoice(&self.choice);
    try self.recordState();
}

fn configure(self: *App) !void {
    const client = self.client orelse return;
    const account = self.client_account orelse return;
    const model = if (self.choice.model) |*model| model else return;
    if (self.configured) |*configured| {
        if (configured.eql(&self.choice)) return;
    }
    self.configured = self.choice;
    try self.session.send(&.{ .configure = .{
        .provider = client.provider(),
        .account = accounts.Account.table[account].id,
        .model = model.name(),
        .effort = self.choice.fold(),
        .tokens_max = model.tokens_max,
        .system = self.system,
    } });
    for (self.leases.items) |*lease| {
        if (lease.client == client) lease.setups += 1;
    }
}

fn recordState(self: *App) !void {
    const account = self.choice.account orelse return;
    self.state.record(account, self.choice.modelName(), self.choice.effort) catch |err|
        try self.reportStateSaveFailure(err);
}

fn reportStateSaveFailure(self: *App, err: accounts.json_store.SaveError) !void {
    switch (err) {
        error.StoreBusy => return self.recordEvent(
            .failure,
            "Drinky could not save the choices of this project because another Drinky instance " ++
                "is writing the state file. Drinky tries again at the next save.",
            .{},
        ),
        error.CorruptStore => return self.recordEvent(
            .failure,
            "Drinky stopped saving the choices of this project because Drinky cannot read the " ++
                "file {s} as a JSON object. Delete that file to let the next start save again.",
            .{self.state.path},
        ),
        inline else => |cause| comptime core.error_set.requireMember(
            accounts.json_store.FileError,
            cause,
        ),
    }
    try self.recordEvent(
        .failure,
        "Drinky stopped saving the choices of this project to {s} because of error {s}.",
        .{ self.state.path, @errorName(err) },
    );
}

fn handleKeys(self: *App, bytes: []const u8) !void {
    try self.input.feed(bytes);
    while (self.input.next()) |event| {
        const before = std.meta.activeTag(self.mode);
        try self.handleKey(&event);
        if (before != std.meta.activeTag(self.mode) and isExitKey(&event)) {
            while (self.input.next()) |_| {}
            break;
        }
    }
    self.escape_deadline_ms = if (self.input.pendingEscape())
        self.nowMs() + escape_wait_ms
    else
        null;
}

fn isExitKey(event: *const terminal.Input.Key) bool {
    return switch (event.*) {
        .escape => true,
        .ctrl => |letter| letter == 'c' or letter == 'd',
        else => false,
    };
}

fn flushEscape(self: *App) !void {
    const deadline = self.escape_deadline_ms orelse return;
    if (self.nowMs() < deadline) return;
    self.escape_deadline_ms = null;
    if (!self.input.takeEscape()) return;
    try self.handleKey(&.escape);
}

fn handleKey(self: *App, event: *const terminal.Input.Key) !void {
    self.disarm(event);
    if (self.mode != .prompt and event.* == .ctrl and event.ctrl == 'd')
        self.ctrl_d_ms_last = self.nowMs();
    switch (self.mode) {
        .turn => |turn| if (event.* == .escape and self.screen.notice != null and
            !turn.cancel_armed)
        {
            self.screen.clearNotice();
            return;
        },
        else => {},
    }
    self.screen.clearNotice();
    switch (self.mode) {
        .prompt => try self.handlePromptKey(event),
        .turn, .sign_in => try self.handleEditorKey(event),
        .picker => try self.handlePickerKey(event),
        .fetch => try self.handleFetchKey(event),
        .page => try self.handlePageKey(event),
    }
}

fn disarm(self: *App, event: *const terminal.Input.Key) void {
    switch (self.mode) {
        .prompt => |*prompt| {
            const confirmation = prompt.confirmation orelse return;
            const confirms = switch (confirmation) {
                .message => event.* == .enter,
                .quit => event.* == .ctrl and event.ctrl == 'd',
                .removal => event.* == .ctrl and event.ctrl == 'n',
            };
            if (!confirms) prompt.confirmation = null;
        },
        .turn => |*turn| if (event.* != .escape) {
            turn.cancel_armed = false;
        },
        .picker, .fetch, .page, .sign_in => {},
    }
}

fn handlePromptKey(self: *App, event: *const terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submit(),
        .escape => self.dropOffer(),
        .ctrl => |letter| switch (letter) {
            'c' => {
                self.clearOrQuit();
                if (self.running) self.screen.dirty = true;
            },
            'd' => try self.quitOrWarn(),
            'n' => try self.takeOffer(),
            else => {},
        },
        else => {},
    }
}

fn takeOffer(self: *App) !void {
    const offer = if (self.offer) |*offer| offer else return;
    switch (offer.*) {
        .retry => |request| try self.retryTurn(request),
        .removal => |*removal| try self.removeTurn(removal),
    }
}

fn dropOffer(self: *App) void {
    const offer = self.offer orelse return;
    offer.deinit(self.gpa);
    self.offer = null;
    self.screen.dirty = true;
}

fn retryTurn(self: *App, request: []const u8) !void {
    if (self.turnRefusal()) |refusal| return self.reportNotice(.failure, "{s}", .{refusal});
    const start = self.screen.transcript.blocks().len;
    try self.screen.appendNote(retry_note);
    errdefer self.screen.transcript.truncate(start);
    try self.runTurn(&.{ .text = request, .start = start, .line = null });
}

fn removeTurn(self: *App, removal: *const Offer.Removal) !void {
    if (removal.mutated and self.mode.prompt.confirmation != .removal) {
        try self.reportNotice(.warning, removal_warning, .{});
        self.mode.prompt.confirmation = .removal;
        return;
    }
    self.mode.prompt.confirmation = null;
    try self.screen.removeTurn(removal.range, removal.line);
    try self.session.send(&.remove_turn);
    self.dropOffer();
}

fn quitOrWarn(self: *App) !void {
    const draft = self.screen.editor.visible().len != 0;
    const recent_exit = self.nowMs() - self.ctrl_d_ms_last < repeat_window_ms;
    if (self.mode.prompt.confirmation == .quit or (!draft and !recent_exit)) {
        self.running = false;
        return;
    }
    if (draft) {
        try self.reportNotice(
            .warning,
            "Press Ctrl+D again to quit. The quit discards the draft.",
            .{},
        );
    } else {
        try self.reportNotice(.warning, "Press Ctrl+D again to quit.", .{});
    }
    self.mode.prompt.confirmation = .quit;
}

fn handleEditorKey(self: *App, event: *const terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => switch (self.mode) {
            .turn => try self.submitDuringTurn(),
            .sign_in => try self.submitLoginLine(),
            else => unreachable,
        },
        .escape => if (self.mode == .turn) try self.warnOrCancel() else try self.exitMode(),
        .ctrl => |letter| switch (letter) {
            'c' => try self.clearOrExit(),
            'd' => try self.exitMode(),
            else => {},
        },
        else => {},
    }
}

fn clearOrExit(self: *App) !void {
    if (self.screen.editor.visible().len == 0) return self.exitMode();
    self.screen.editor.clear();
    self.screen.markEdited();
}

fn exitMode(self: *App) !void {
    switch (self.mode) {
        .turn => try self.cancelTurn(),
        .sign_in => try self.cancelLogin(),
        else => unreachable,
    }
}

fn editKey(self: *App, event: *const terminal.Input.Key) !bool {
    const editor = &self.screen.editor;
    switch (event.*) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .paste => |paste| try editor.paste(paste.bytes, paste.final),
        .backspace => editor.backspace(),
        .left => editor.moveLeft(),
        .right => editor.moveRight(),
        .up => editor.moveUp(self.screen.columns),
        .down => editor.moveDown(self.screen.columns),
        .home => editor.moveHome(),
        .end => editor.moveEnd(),
        .shift_enter => try editor.insert("\n"),
        .ctrl => |letter| switch (letter) {
            'j' => try editor.insert("\n"),
            else => return false,
        },
        else => return false,
    }
    self.screen.markEdited();
    return true;
}

fn submitLoginLine(self: *App) !void {
    const text = try self.screen.editor.expanded();
    defer self.gpa.free(text);
    try self.account_registry.send(&.{ .paste = text });
}

fn warnOrCancel(self: *App) !void {
    const turn = &self.mode.turn;
    if (self.screen.editor.visible().len == 0 or turn.cancel_armed) return self.cancelTurn();
    try self.reportNotice(.warning, turn_cancel_notice, .{});
    turn.cancel_armed = true;
}

fn submitDuringTurn(self: *App) !void {
    if (self.screen.editor.blank()) return;
    const text = try self.screen.editor.expanded();
    defer self.gpa.free(text);
    var context = self.commandContext();
    if (try command.checkDuringTurn(&context, text)) |refusal| return self.setNotice(refusal);
    try self.reportNotice(.information, turn_message_notice, .{});
}

fn cancelTurn(self: *App) !void {
    const turn = &self.mode.turn;
    if (turn.cancel_sent) return;
    turn.cancel_sent = true;
    try self.session.send(&.cancel);
}

fn clearOrQuit(self: *App) void {
    const now = self.nowMs();
    if (now - self.ctrl_c_ms_last < repeat_window_ms) {
        self.running = false;
    } else {
        self.screen.editor.clear();
        self.ctrl_c_ms_last = now;
    }
}

fn refresh(self: *App) !void {
    const size: terminal.View.Size = self.tty.size() orelse
        .{ .columns = self.screen.columns, .rows = self.screen.rows };
    try self.tty.setAlternateScreen(self.mode == .page);
    try self.screen.paint(size, self.screenTime(), &self.caption());
}

fn screenTime(self: *App) Screen.Time {
    return .{ .awake_ms = self.nowMs(), .boot_ms = self.nowBootMs() };
}

fn nowMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

fn nowBootMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .boot).toMilliseconds();
}

fn nowNs(self: *App) i96 {
    return std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
}

fn submit(self: *App) !void {
    const prompt = &self.mode.prompt;
    const message_confirmed = prompt.confirmation == .message;
    prompt.confirmation = null;
    if (self.screen.editor.blank()) return;
    const text = try self.screen.editor.expanded();
    defer self.gpa.free(text);
    self.screen.dirty = true;

    if (!message_confirmed) {
        if (try self.checkCommand(text)) |refusal|
            return self.armMessageSend(refusal);
        if (try self.dispatchCommand(text)) |outcome|
            return self.applySubmittedCommand(&outcome, text);
    }
    if (self.turnRefusal()) |refusal| return self.reportNotice(.failure, "{s}", .{refusal});
    try self.startUserTurn(text);
    self.screen.editor.clear();
}

fn turnRefusal(self: *const App) ?[]const u8 {
    if (self.choice.account == null or self.client == null) return signed_out_refusal;
    if (self.choice.model == null) return no_model_refusal;
    return null;
}

fn applySubmittedCommand(
    self: *App,
    outcome: *const command.Context.Outcome,
    line: []const u8,
) !void {
    switch (outcome.*) {
        .prompt => |*prompt| return self.submitSkill(prompt, line),
        .refusal => {},
        else => self.screen.editor.clear(),
    }
    try self.applyOutcome(outcome);
}

fn submitSkill(
    self: *App,
    prompt: *const command.Context.Outcome.Prompt,
    line: []const u8,
) !void {
    defer prompt.deinit(self.gpa);
    if (self.turnRefusal()) |refusal| return self.reportNotice(.failure, "{s}", .{refusal});
    try self.startSkillTurn(prompt, line);
    self.screen.editor.clear();
}

fn armMessageSend(self: *App, refusal: Message) !void {
    defer refusal.deinit(self.gpa);
    try self.reportNotice(refusal.severity, "Enter: Send as a message · {s}", .{refusal.content});
    self.mode.prompt.confirmation = .message;
}

fn startSkillTurn(
    self: *App,
    prompt: *const command.Context.Outcome.Prompt,
    line: []const u8,
) !void {
    const start = self.screen.transcript.blocks().len;
    errdefer self.screen.transcript.truncate(start);
    try self.screen.appendSkillNote(&.{ .name = prompt.name, .source = prompt.source });
    if (prompt.arguments.len > 0) try self.screen.appendUser(prompt.arguments);
    try self.runTurn(&.{ .text = prompt.content, .start = start, .line = line });
}

fn startUserTurn(self: *App, text: []const u8) !void {
    const start = self.screen.transcript.blocks().len;
    try self.screen.appendUser(text);
    errdefer self.screen.transcript.truncate(start);
    try self.runTurn(&.{ .text = text, .start = start, .line = text });
}

fn runTurn(self: *App, turn: *const TurnStart) !void {
    std.debug.assert(self.mode == .prompt);
    self.refreshBranch();
    const maybe_line: ?[]u8 = if (turn.line) |line| try self.gpa.dupe(u8, line) else null;
    errdefer if (maybe_line) |line| self.gpa.free(line);
    try self.session.send(&.{ .prompt = turn.text });
    self.setMode(.{ .turn = .{ .start = turn.start, .line = maybe_line } });
    self.screen.beginTurn(turn.start);
}

fn leaveTurn(self: *App) Mode.Turn {
    const turn = self.mode.turn;
    self.setMode(.{ .prompt = .{} });
    return turn;
}

fn applySessionEvent(self: *App, event: *const core.Session.Event) !void {
    switch (event.*) {
        .setup_dropped => |provider| return self.releaseSetup(provider),
        .tool_started => |*call| if (core.Tool.mutating(&tools.Registry.specs, call.name)) {
            self.mode.turn.mutated = true;
        },
        else => {},
    }
    const outcome = (try self.screen.apply(event, self.screenTime())) orelse return;
    const turn = self.leaveTurn();
    try self.endTurn(&turn, &outcome);
}

fn endTurn(self: *App, turn: *const Mode.Turn, outcome: *const core.Session.Outcome) !void {
    var maybe_line = turn.line;
    defer if (maybe_line) |line| self.gpa.free(line);
    self.dropOffer();
    self.refreshBranch();
    switch (outcome.*) {
        .stopped, .exhausted => {},
        .canceled => if (maybe_line) |line| {
            self.offer = .{ .removal = .{
                .line = line,
                .range = .{ .start = turn.start, .end = self.screen.transcript.blocks().len },
                .mutated = turn.mutated,
            } };
            maybe_line = null;
        },
        .failed => |*failure| {
            try self.offerRetry(failure);
            if (failure.reason == .unauthorized) try self.rejectCredential();
        },
    }
}

fn offerRetry(self: *App, failure: *const core.Provider.Failure) !void {
    const text = try Screen.failureText(self.gpa, failure);
    defer self.gpa.free(text);
    self.offer = .{ .retry = try std.fmt.allocPrint(self.gpa, retry_request, .{text}) };
}

fn rejectCredential(self: *App) !void {
    const account = self.choice.account orelse return;
    var maybe_removal_error: ?accounts.oauth.store.Error = null;
    const recovered = self.account_registry.invalidate(account) catch |err| switch (err) {
        error.AccountHasNoRefreshCredential => return,
        else => |removal_error| failure: {
            maybe_removal_error = removal_error;
            break :failure false;
        },
    };
    self.closeClient();
    if (recovered) {
        try self.sync();
        try self.reportCredentialStep(
            account,
            "Drinky reloaded the refresh credential that another Drinky instance saved. ",
        );
    } else {
        if (maybe_removal_error) |removal_error| try self.recordEvent(
            .failure,
            "Drinky could not remove the rejected credential for {s} because of error {s}.",
            .{ accounts.Account.table[account].id, @errorName(removal_error) },
        );
        try self.handOff(account);
    }
}

fn reportCredentialStep(self: *App, account: usize, comptime lead: []const u8) !void {
    if (self.choice.model == null) return self.reportModelStep(account, lead, .{});
    return self.recordEvent(.information, lead ++ "Try the turn again.", .{});
}

fn reportModelStep(
    self: *App,
    account: usize,
    comptime lead: []const u8,
    lead_args: anytype,
) !void {
    const step = try command.model.nextStep(
        self.gpa,
        &self.account_registry,
        account,
        lead,
        lead_args,
    );
    try self.screen.appendEvent(step);
}

fn handOff(self: *App, account: usize) !void {
    const id = accounts.Account.table[account].id;
    const maybe_next = self.account_registry.firstAuthenticated();
    self.adopt(maybe_next);
    try self.sync();
    const next = maybe_next orelse {
        try self.recordEvent(
            .information,
            "Drinky signed out of {s}. Select an account to sign in.",
            .{id},
        );
        return self.openLoginPicker();
    };
    const next_id = accounts.Account.table[next].id;
    if (self.choice.model) |model| return self.recordEvent(
        .information,
        "Drinky signed out of {s}. Drinky now uses {s}/{s}.",
        .{ id, next_id, model.name() },
    );
    return self.reportModelStep(next, "Drinky signed out of {s}. Drinky now uses {s}. ", .{
        id,
        next_id,
    });
}

fn adopt(self: *App, maybe_account: ?usize) void {
    self.choice.adopt(&self.account_registry, &self.state.model_names, maybe_account);
}

fn applyAccountsEvent(self: *App, event: *const accounts.Registry.Event) !void {
    switch (event.*) {
        .refused => |refusal| try self.reportRefusal(&refusal),
        .authorization => |*authorization| try self.recordAuthorization(authorization),
        .browser_launch_failed => |account| try self.reportNotice(
            .warning,
            "Drinky could not open the browser for the sign-in to {s}. Open the URL above.",
            .{accounts.Account.table[account].id},
        ),
        .paste_replayed => {
            self.screen.editor.clear();
            self.screen.markEdited();
        },
        .paste_refused => |refusal| try self.reportPasteRefusal(refusal),
        .login_ended => |*ended| try self.finishLogin(ended),
        .fetch_ended => |*ended| try self.finishFetch(ended),
    }
}

fn reportRefusal(self: *App, refusal: *const accounts.Registry.Event.Refusal) !void {
    const id = accounts.Account.table[refusal.account].id;
    switch (refusal.command) {
        .fetch => if (self.mode == .fetch) try self.cancelPicker(),
        .login => self.dropLogin(),
    }
    switch (refusal.reason) {
        .busy => try self.reportNotice(
            .warning,
            "Drinky cannot start this now because a sign-in or a model fetch runs.",
            .{},
        ),
        .no_login => try self.reportNotice(.failure, "{s} has no sign-in.", .{id}),
        .signed_out => try self.reportNotice(.failure, "{s} is signed out.", .{id}),
    }
}

fn recordAuthorization(
    self: *App,
    authorization: *const accounts.Registry.Event.Authorization,
) !void {
    const sign_in = switch (self.mode) {
        .sign_in => |*sign_in| sign_in,
        else => return,
    };
    if (sign_in.account != authorization.account) return;
    const id = accounts.Account.table[sign_in.account].id;
    if (authorization.code) |code| {
        try self.recordEvent(
            .information,
            "Open this URL to authorize the sign-in to {s}:\n\n{s}\n\n" ++
                "Enter this code if the page asks for one: {s}",
            .{ id, authorization.url, code },
        );
    } else {
        try self.recordEvent(
            .information,
            "Open this URL to authorize the sign-in to {s}:\n\n{s}\n\n" ++
                "If the browser shows an error, paste the callback URL from its address bar " ++
                "and press Enter.",
            .{ id, authorization.url },
        );
    }
    sign_in.event_index = self.screen.transcript.blocks().len - 1;
}

fn reportPasteRefusal(self: *App, refusal: accounts.Registry.Event.Paste) !void {
    const sign_in = switch (self.mode) {
        .sign_in => |sign_in| sign_in,
        else => return,
    };
    const id = accounts.Account.table[sign_in.account].id;
    switch (refusal) {
        .not_waiting => try self.reportNotice(
            .warning,
            "The sign-in to {s} does not accept a callback URL. Complete the sign-in in the " ++
                "browser.",
            .{id},
        ),
        .not_a_redirect => try self.reportNotice(
            .warning,
            "The line is not the callback URL for the sign-in to {s}. " ++
                "Paste the complete callback URL from the browser.",
            .{id},
        ),
        .replay_failed => |err| {
            switch (err) {
                error.ConnectionRefused => {
                    self.screen.editor.clear();
                    self.screen.markEdited();
                    return self.reportNotice(
                        .information,
                        "Drinky already received the response for the sign-in to {s}.",
                        .{id},
                    );
                },
                inline else => |cause| comptime core.error_set.requireMember(
                    accounts.oauth.login.NetworkError,
                    cause,
                ),
            }
            try self.reportNotice(
                .failure,
                "Drinky could not replay the callback URL for the sign-in to {s} " ++
                    "because of error {s}.",
                .{ id, @errorName(err) },
            );
        },
    }
}

fn startLogin(self: *App, account: usize) !void {
    std.debug.assert(self.mode == .prompt);
    try self.account_registry.send(&.{ .login = account });
    self.setMode(.{ .sign_in = .{
        .account = account,
        .takes_paste = accounts.Registry.takesPaste(&accounts.Account.table[account]),
    } });
}

fn cancelLogin(self: *App) !void {
    const sign_in = &self.mode.sign_in;
    if (sign_in.cancel_sent) return;
    sign_in.cancel_sent = true;
    try self.account_registry.send(&.cancel);
}

fn finishLogin(self: *App, ended: *const accounts.Registry.Event.LoginEnd) !void {
    const sign_in = switch (self.mode) {
        .sign_in => |sign_in| sign_in,
        else => return,
    };
    if (sign_in.account != ended.account) return;
    self.setMode(.{ .prompt = .{} });
    self.screen.clearNotice();
    const committed = ended.outcome catch |login_error|
        return self.reportLoginFailure(&sign_in, login_error);
    try self.completeLogin(&sign_in, &committed);
}

fn dropLogin(self: *App) void {
    if (self.mode == .sign_in) self.setMode(.{ .prompt = .{} });
}

fn completeLogin(
    self: *App,
    sign_in: *const Mode.SignIn,
    committed: *const accounts.oauth.store.Commit,
) !void {
    const account = sign_in.account;
    const id = accounts.Account.table[account].id;
    self.adopt(account);
    try self.sync();
    if (self.choice.model) |model| {
        try self.recordEventAt(
            sign_in.event_index,
            .information,
            "Drinky signed in and now uses {s}/{s}.",
            .{ id, model.name() },
        );
    } else try self.recordEventAt(
        sign_in.event_index,
        .information,
        "Drinky signed in to {s}.",
        .{id},
    );
    switch (committed.*) {
        .saved => {},
        .memory_only => |failure| try self.recordEvent(
            .failure,
            "Drinky could not save the credentials for {s} to {s} because of error {s}. " ++
                "The sign-in stays active until Drinky exits.",
            .{ id, failure.path, @errorName(failure.save_error) },
        ),
    }
    var context = self.commandContext();
    try self.openPicker(&try command.model.forAccount(&context, account));
}

fn reportLoginFailure(
    self: *App,
    sign_in: *const Mode.SignIn,
    login_error: accounts.oauth.store.SignInError,
) !void {
    const id = accounts.Account.table[sign_in.account].id;
    const message: ?[]const u8 = switch (login_error) {
        error.Canceled => return self.reportLoginEnd(
            sign_in,
            .information,
            "You canceled the sign-in to {s}.",
            .{id},
        ),
        error.CallbackTimeout => "Drinky stopped the sign-in because the browser did not " ++
            "respond in time.",
        error.CallbackRequestTooLarge => "Drinky could not sign in because the browser " ++
            "response was too large.",
        error.CallbackTimeoutUnavailable => "Drinky could not sign in because it could not " ++
            "set a browser time limit.",
        error.AuthorizationFailed, error.AuthorizationDenied => "The provider did not " ++
            "authorize Drinky. Start the sign-in again.",
        error.DeviceCodeExpired => "Drinky stopped the sign-in because the authorization did " ++
            "not arrive in time.",
        error.StateMismatch => "The response belongs to another sign-in. " ++
            "Start the sign-in again.",
        error.TokenGrantRejected => "The provider rejected the authorization. " ++
            "Start the sign-in again.",
        error.TokenServiceUnavailable => "The provider credential service is not available. " ++
            "Try the sign-in again later.",
        error.OutOfMemory,
        error.TokenResponseTooLarge,
        error.TokenRequestFailed,
        error.AuthorizationPending,
        error.SlowDown,
        error.BadTokenResponse,
        error.BadDeviceResponse,
        error.BadCredentials,
        error.MissingAccessToken,
        error.MissingRefreshToken,
        error.MissingExpiry,
        error.MissingAccountId,
        error.MissingApiKey,
        => null,
        inline else => |cause| network: {
            comptime core.error_set.requireMember(accounts.oauth.login.NetworkError, cause);
            break :network null;
        },
    };
    const text = message orelse return self.reportLoginEnd(
        sign_in,
        .failure,
        "Drinky could not sign in because of error {s}.",
        .{@errorName(login_error)},
    );
    return self.reportLoginEnd(sign_in, .failure, "{s}", .{text});
}

fn reportLoginEnd(
    self: *App,
    sign_in: *const Mode.SignIn,
    severity: Message.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const index = sign_in.event_index orelse return self.reportNotice(severity, format, args);
    try self.recordEventAt(index, severity, format, args);
}

fn startFetch(self: *App, account: usize) !void {
    std.debug.assert(self.mode == .picker);
    try self.account_registry.send(&.{ .fetch = account });
    try self.screen.beginPickerWait(fetch_wait_text);
    self.setMode(.{ .fetch = .{ .account = account } });
}

fn finishFetch(self: *App, ended: *const accounts.Registry.Event.FetchEnd) !void {
    const fetch = switch (self.mode) {
        .fetch => |fetch| fetch,
        else => return,
    };
    if (fetch.account != ended.account) return;
    if (fetch.exit) |exit| switch (exit) {
        .command => return self.cancelPicker(),
        .step => {
            try self.reopenStep();
            return self.reportNotice(.information, "You canceled the model fetch.", .{});
        },
    };
    if (ended.refresh.models_error) |err| std.debug.assert(err != error.Canceled);
    var context = self.commandContext();
    try self.applyPickerOutcome(&try command.model.fetchOutcome(
        &context,
        fetch.account,
        &ended.refresh,
    ));
}

fn reopenStep(self: *App) !void {
    const opener = self.screen.widget.picking.reopen orelse return self.cancelPicker();
    var context = self.commandContext();
    try self.applyPickerOutcome(&try opener.run(&context));
}

fn cancelFetch(self: *App, exit: Mode.Fetch.Exit) !void {
    const fetch = &self.mode.fetch;
    if (fetch.exit != null) return;
    fetch.exit = exit;
    try self.account_registry.send(&.cancel);
}

fn commandContext(self: *App) command.Context {
    return .{
        .gpa = self.gpa,
        .io = self.io,
        .choice = &self.choice,
        .account_registry = &self.account_registry,
        .remembered_model_names = &self.state.model_names,
        .skill_registry = &self.skill_registry,
        .system_prompt = self.system,
        .sources_page = self.sources_page,
    };
}

fn dispatchCommand(self: *App, line: []const u8) !?command.Context.Outcome {
    var context = self.commandContext();
    return command.run(&context, line);
}

fn checkCommand(self: *App, line: []const u8) !?Message {
    var context = self.commandContext();
    return command.check(&context, line);
}

fn runCommand(self: *App, line: []const u8) !void {
    if (try self.dispatchCommand(line)) |outcome| try self.applyOutcome(&outcome);
}

fn applyOutcome(self: *App, outcome: *const command.Context.Outcome) !void {
    switch (outcome.*) {
        .notice, .refusal => |message| self.setNotice(message),
        .event => |message| try self.screen.appendEvent(message),
        .pick => |*pick| try self.openPicker(pick),
        .prompt => unreachable,
        .editor_text => |text| {
            defer self.gpa.free(text);
            try self.screen.setDraft(text);
        },
        .page => |*page| try self.openPage(page),
        .new_conversation => {
            try self.session.send(&.clear);
            self.dropOffer();
            self.screen.clearConversation();
            try self.screen.appendIntro(intro_text);
        },
        .login => |account| return self.startLogin(account),
        .logout => |account| try self.logoutAccount(account),
        .fetch => |account| return self.startFetch(account),
    }
    try self.sync();
}

fn openPicker(self: *App, pick: *const command.Context.Outcome.Pick) !void {
    try self.screen.openPicker(pick);
    self.setMode(.picker);
}

fn closePicker(self: *App) void {
    self.screen.closePicker();
    self.setMode(.{ .prompt = .{} });
}

fn cancelPicker(self: *App) !void {
    try self.screen.cancelPicker();
    self.setMode(.{ .prompt = .{} });
}

fn openPage(self: *App, options: *const ui.Page.Options) !void {
    try self.screen.openPage(options);
    self.setMode(.page);
}

fn closePage(self: *App) void {
    self.screen.closePage();
    self.setMode(.{ .prompt = .{} });
}

fn openLoginPicker(self: *App) !void {
    var context = self.commandContext();
    try self.openPicker(&try command.login.picker(&context));
}

fn logoutAccount(self: *App, account: usize) !void {
    const was_active = self.choice.isActive(account);
    if (was_active) self.closeClient();
    self.account_registry.logout(account) catch |err| {
        return self.reportNotice(
            .failure,
            "Drinky could not sign out because of error {s}.",
            .{@errorName(err)},
        );
    };
    if (!was_active) return self.recordEvent(
        .information,
        "Drinky signed out of {s}.",
        .{accounts.Account.table[account].id},
    );
    try self.handOff(account);
}

fn setNotice(self: *App, message: Message) void {
    switch (self.mode) {
        .prompt => |*prompt| if (prompt.confirmation == .message) {
            prompt.confirmation = null;
        },
        else => {},
    }
    self.screen.setNotice(message);
}

fn reportNotice(
    self: *App,
    severity: Message.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    self.setNotice(try Message.print(self.gpa, severity, format, args));
}

fn resolveRequiredSkills(self: *App, missing: *std.ArrayList(Config.RequiredSkill)) !bool {
    for (self.config.required_skills) |required| {
        const target = self.skill_registry.get(required.skill) orelse {
            try missing.append(self.gpa, required);
            continue;
        };
        self.skill_guard.add(.{
            .glob = required.glob,
            .skill = target.name,
            .source = target.path,
        }) catch |err| switch (err) {
            error.TooManyRules => return true,
        };
    }
    return false;
}

fn recordReports(self: *App, reports: *const Reports) !void {
    for (reports.messages()) |report| {
        const safe_text = try escape.display(self.gpa, report.content);
        defer self.gpa.free(safe_text);
        try self.recordEvent(report.severity, "{s}", .{safe_text});
    }
}

fn recordEvent(
    self: *App,
    severity: Message.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    try self.recordEventAt(null, severity, format, args);
}

fn recordEventAt(
    self: *App,
    maybe_index: ?usize,
    severity: Message.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const message = try Message.print(self.gpa, severity, format, args);
    if (maybe_index) |index| return self.screen.replaceEvent(index, message);
    try self.screen.appendEvent(message);
}

fn handlePageKey(self: *App, event: *const terminal.Input.Key) !void {
    const page = &self.screen.widget.page;
    const size: terminal.View.Size = .{
        .columns = self.screen.columns,
        .rows = self.screen.rows,
    };
    switch (event.*) {
        .escape => return self.closePage(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => return self.closePage(),
            else => return,
        },
        .up => page.moveUp(size),
        .down => page.moveDown(size),
        .page_up => page.pageUp(size),
        .page_down => page.pageDown(size),
        .home => page.moveHome(),
        .end => page.moveEnd(size),
        .char => |codepoint| switch (codepoint) {
            'm', 'M' => page.toggleSource(size),
            else => return,
        },
        else => return,
    }
    self.screen.dirty = true;
}

fn handlePickerKey(self: *App, event: *const terminal.Input.Key) !void {
    const picker = &self.screen.widget.picking.picker;
    switch (event.*) {
        .up => try picker.moveUp(),
        .down => try picker.moveDown(),
        .enter => return self.confirmPicker(),
        .escape => return self.leavePicker(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => return self.cancelPicker(),
            else => return,
        },
        else => return,
    }
    self.screen.dirty = true;
}

fn handleFetchKey(self: *App, event: *const terminal.Input.Key) !void {
    switch (event.*) {
        .escape => try self.cancelFetch(.step),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => try self.cancelFetch(.command),
            else => {},
        },
        else => {},
    }
}

fn confirmPicker(self: *App) !void {
    const picking = &self.screen.widget.picking;
    var context = self.commandContext();
    try self.applyPickerOutcome(&try picking.select(&context, picking.picker.cursor));
}

fn applyPickerOutcome(self: *App, outcome: *const command.Context.Outcome) !void {
    switch (outcome.*) {
        .pick, .fetch => {},
        else => self.closePicker(),
    }
    try self.applyOutcome(outcome);
}

fn leavePicker(self: *App) !void {
    const opener = self.screen.stepAbove() orelse return self.cancelPicker();
    var context = self.commandContext();
    const outcome = try opener.run(&context);
    switch (outcome) {
        .pick => |*pick| try self.screen.openPickerAbove(pick),
        else => {
            self.closePicker();
            try self.applyOutcome(&outcome);
        },
    }
}

test "a prompt runs a turn through the session, and the answer joins the transcript" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.reply_stream },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try std.testing.expectEqual(accounts.testing.openai_api_key, rig.app.choice.account.?);
    try std.testing.expectEqualStrings("gpt-5.6-sol", rig.app.screen.statusInfo(0).model.?);

    try rig.keys("hi\r");
    try std.testing.expect(rig.app.mode == .turn);
    try std.testing.expectEqualStrings("", rig.app.screen.editor.visible());
    try rig.settle();
    try std.testing.expect(rig.app.mode == .prompt);
    const blocks = rig.blocks();
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("hi", blocks[1].content.user.items);
    try std.testing.expectEqualStrings("done", blocks[2].content.model.items);
    try expectRequested(&rig, "\"model\":\"gpt-5.6-sol\"");
    try expectRequested(&rig, "\"effort\":\"high\"");
    try expectRequested(&rig, "You run inside Drinky, a terminal coding-agent harness.");
    try std.testing.expectEqual(@as(?u64, 12), rig.app.screen.statusInfo(0).context_tokens);

    try rig.keys("again\r");
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
    try expectRequested(&rig, "\"text\":\"hi\"");
    try expectRequested(&rig, "\"text\":\"again\"");
}

const Rig = struct {
    tmp: std.testing.TmpDir,
    directory: [:0]const u8,
    environment: std.process.Environ.Map,
    transport: providers.testing.FakeTransport,
    browser: accounts.testing.FakeBrowser,
    loopback: accounts.testing.FakeLoopback,
    clock: testing.Clock,
    out: std.Io.Writer.Allocating,
    app: App,

    const Options = struct {
        variables: []const [2][]const u8 = &.{},
        store: ?[]const u8 = null,
        config: ?[]const u8 = null,
        files: []const [2][]const u8 = &.{},
        replies: []const providers.testing.FakeTransport.Reply = &.{},
        model: ?[]const u8 = null,
        model_accounts: []const usize = &.{accounts.testing.openai_api_key},
    };

    fn init(self: *Rig, options: *const Rig.Options) !void {
        const gpa = std.testing.allocator;
        self.clock.init(gpa);
        errdefer self.clock.deinit();
        const io = self.clock.io();
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(io, .{ .sub_path = project.marker_name, .data = "" });
        self.directory = try self.tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(self.directory);
        self.environment = .init(gpa);
        errdefer self.environment.deinit();
        for (options.variables) |variable| try self.environment.put(variable[0], variable[1]);
        if (options.store) |data| try accounts.testing.writeStore(io, &self.tmp, data);
        try self.writeConfig(options);
        for (options.files) |file| {
            const parent_path = std.fs.path.dirname(file[0]).?;
            var parent = try self.tmp.dir.createDirPathOpen(io, parent_path, .{});
            parent.close(io);
            try self.tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
        }
        self.transport = .{ .gpa = gpa, .replies = options.replies };
        errdefer self.transport.deinit();
        self.browser = .{};
        self.loopback = .{ .io = io };
        self.out = .init(gpa);
        errdefer self.out.deinit();

        try self.app.init(gpa, io, &.{
            .working_directory = self.directory,
            .home = self.directory,
            .writer = &self.out.writer,
            .environment = &self.environment,
            .transport = self.transport.transport(),
            .browser = self.browser.browser(),
            .loopback = self.loopback.loopback(),
        });
        errdefer self.app.deinit();
        if (options.model) |name| try self.seedModel(name, options.model_accounts);
        self.app.running = true;
    }

    fn writeConfig(self: *Rig, options: *const Rig.Options) !void {
        const io = std.testing.io;
        var directory = try self.tmp.dir.createDirPathOpen(io, ".drinky", .{});
        defer directory.close(io);
        const data = options.config orelse
            "{\"request\":{\"attempts_max\":2,\"delay_ms_initial\":0,\"delay_ms_max\":0}}";
        try directory.writeFile(io, .{ .sub_path = "config.json", .data = data });
    }

    fn seedModel(self: *Rig, name: []const u8, model_accounts: []const usize) !void {
        const app = &self.app;
        var model = try accounts.Model.init(name);
        model.context_window = 400_000;
        model.tokens_max = 32_000;
        model.thinking = .supported;
        model.addEffort(.low);
        model.addEffort(.high);
        for (model_accounts) |account| {
            try app.account_registry.catalog.setAccount(account, &.{model});
            try app.state.seed(account, model.name(), .high);
        }
        app.adopt(app.startAccount());
        try app.sync();
    }

    fn deinit(self: *Rig) void {
        self.app.deinit();
        self.out.deinit();
        self.transport.deinit();
        self.environment.deinit();
        std.testing.allocator.free(self.directory);
        self.tmp.cleanup();
        self.clock.deinit();
    }

    fn keys(self: *Rig, bytes: []const u8) !void {
        try self.app.handleKeys(bytes);
    }

    fn escape(self: *Rig) !void {
        try self.keys("\x1b");
        self.clock.advance(escape_wait_ms);
        try self.app.flushEscape();
    }

    fn settle(self: *Rig) !void {
        var batch: [queue_capacity]UiEvent = undefined;
        for (0..1 << 16) |_| {
            const waits = self.app.mode == .turn or self.app.mode == .fetch or
                self.app.mode == .sign_in;
            const count = try self.app.queue.get(self.app.io, &batch, if (waits) 1 else 0);
            if (count == 0) return;
            _ = try self.app.applyBatch(batch[0..count]);
        }
        return error.TooManyEvents;
    }

    fn blocks(self: *const Rig) []const ui.Block {
        return self.app.screen.transcript.blocks();
    }

    fn lastRequest(self: *const Rig) []const u8 {
        return self.transport.requests.items[self.transport.requests.items.len - 1];
    }

    fn pumpUntil(self: *Rig, reached: *const fn (app: *const App) bool) !void {
        var batch: [queue_capacity]UiEvent = undefined;
        for (0..1 << 16) |_| {
            if (reached(&self.app)) return;
            const count = try self.app.queue.get(self.app.io, &batch, 1);
            _ = try self.app.applyBatch(batch[0..count]);
        }
        return error.TooManyEvents;
    }

    fn startLoginOf(self: *Rig, account: usize) !void {
        try std.testing.expect(self.app.mode == .picker);
        const picker = &self.app.screen.widget.picking.picker;
        try std.testing.expectEqualStrings("Sign in", picker.title);
        for (0..accounts.Account.table.len) |_| {
            if (picker.cursor == account) break;
            try self.keys("\x1b[B");
        }
        try std.testing.expectEqual(account, picker.cursor);
        try self.keys("\r");
        try std.testing.expectEqual(account, self.app.mode.sign_in.account);
        try self.pumpUntil(showsAuthorization);
    }

    fn takeUntilTurnEnd(self: *Rig, batch: *[queue_capacity]UiEvent) ![]const UiEvent {
        for (0..queue_capacity) |index| {
            batch[index] = try self.app.queue.getOne(self.app.io);
            const event = &batch[index];
            if (event.* == .session and event.session == .turn_ended) return batch[0 .. index + 1];
        }
        return error.TooManyEvents;
    }
};

fn expectLastEvent(rig: *const Rig, text: []const u8) !void {
    const blocks = rig.blocks();
    try std.testing.expectEqualStrings(text, blocks[blocks.len - 1].content.event.text.items);
}

fn expectEventText(rig: *const Rig, text: []const u8) !void {
    for (rig.blocks()) |*block| switch (block.content) {
        .event => |event| if (std.mem.eql(u8, event.text.items, text)) return,
        else => {},
    };
    std.debug.print("the transcript holds no event \"{s}\"\n", .{text});
    return error.TestExpectedEvent;
}

fn expectRequestHolds(rig: *const Rig, index: usize, needle: []const u8) !void {
    const request = rig.transport.requests.items[index];
    if (std.mem.indexOf(u8, request, needle) != null) return;
    std.debug.print("request {d} holds no {s}:\n{s}\n", .{ index, needle, request });
    return error.TestExpectedNeedle;
}

fn expectRequested(rig: *const Rig, needle: []const u8) !void {
    if (std.mem.indexOf(u8, rig.lastRequest(), needle) != null) return;
    std.debug.print("the last request holds no {s}:\n{s}\n", .{ needle, rig.lastRequest() });
    return error.TestExpectedNeedle;
}

fn expectNoticeHolds(rig: *const Rig, needle: []const u8) !void {
    const notice = rig.app.screen.notice orelse return error.TestExpectedNotice;
    if (std.mem.indexOf(u8, notice.content, needle) != null) return;
    std.debug.print("the notice \"{s}\" holds no \"{s}\"\n", .{ notice.content, needle });
    return error.TestExpectedNeedle;
}

test "a failed turn ends at the prompt with its event, and the message stays" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .status = .internal_server_error, .body = "{\"error\":{\"message\":\"down\"}}" },
            .{ .status = .internal_server_error, .body = "{\"error\":{\"message\":\"down\"}}" },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hi\r");
    try rig.settle();
    try std.testing.expect(rig.app.mode == .prompt);
    const blocks = rig.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    const attempt = blocks[2].content.event.text.items;
    try std.testing.expect(std.mem.startsWith(u8, attempt, "Attempt 1 failed."));
    try std.testing.expectEqualStrings(
        "The provider is overloaded. Details: 500 Internal Server Error: down",
        blocks[3].content.event.text.items,
    );
    try std.testing.expectEqual(.failure, blocks[3].content.event.severity);
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
}

const failed_reply: providers.testing.FakeTransport.Reply = .{
    .status = .internal_server_error,
    .body = "{\"error\":{\"message\":\"down\"}}",
};

test "a failed turn or retry offers a retry that Esc dismisses and Ctrl+N sends with the draft" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            failed_reply,
            failed_reply,
            failed_reply,
            failed_reply,
            failed_reply,
            failed_reply,
            .{ .body = providers.testing.reply_stream },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hi\r");
    try rig.settle();
    try std.testing.expectEqualStrings("Failed turn", rig.app.caption().?.title);
    try std.testing.expectEqual(Herdr.State.blocked, rig.app.herdrState());
    try rig.keys("draft");
    try rig.escape();
    try std.testing.expect(rig.app.caption() == null);
    try std.testing.expectEqual(Herdr.State.idle, rig.app.herdrState());
    try std.testing.expectEqualStrings("draft", rig.app.screen.editor.visible());
    try rig.keys("\x0e");
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);

    try rig.keys("\x03again\r");
    try rig.settle();
    try rig.keys("draft\x0e");
    try std.testing.expect(rig.app.mode == .turn);
    const blocks = rig.blocks();
    try std.testing.expectEqualStrings(retry_note, blocks[blocks.len - 1].content.user_note.items);
    try rig.settle();
    try expectRequested(
        &rig,
        "\"text\":\"<retry_request>\\nThe provider is overloaded. Details: 500 Internal Server " ++
            "Error: down\\nContinue from the last committed checkpoint.\\n</retry_request>\"",
    );
    try std.testing.expectEqualStrings("Failed turn", rig.app.caption().?.title);
    try rig.keys("\x0e");
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 7), rig.transport.requests.items.len);
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expect(rig.app.caption() == null);
    try std.testing.expectEqualStrings("draft", rig.app.screen.editor.visible());
}

test "Ctrl+N removes a canceled turn, keeps the later events, and returns its line to the editor" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .stall = &stall },
        .{ .body = providers.testing.reply_stream },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("fix it\r");
    try stall.reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.settle();
    try std.testing.expectEqualStrings("Canceled turn", rig.app.caption().?.title);
    try std.testing.expectEqual(Herdr.State.idle, rig.app.herdrState());
    try rig.keys("/effort\r\x1b[A\r");
    try rig.settle();
    try std.testing.expectEqualStrings("Canceled turn", rig.app.caption().?.title);
    try std.testing.expectEqual(@as(usize, 4), rig.blocks().len);

    try rig.keys("\x0e");
    try std.testing.expect(rig.app.caption() == null);
    try std.testing.expectEqualStrings("fix it", rig.app.screen.editor.visible());
    const blocks = rig.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[0].content == .intro);
    try std.testing.expect(std.mem.startsWith(
        u8,
        blocks[1].content.event.text.items,
        "Drinky set the effort level to ",
    ));
    try rig.keys("\r");
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rig.lastRequest(), "fix it"));
}

const write_call_stream =
    "data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"fc_1\"," ++
    "\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call_1\"," ++
    "\"name\":\"write\",\"arguments\":\"{}\"}}\n" ++
    "\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n" ++
    "\n";

test "Ctrl+N warns before it removes a canceled turn that ran a mutating tool" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = write_call_stream },
        .{ .stall = &stall },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("fix it\r");
    try stall.reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 4), rig.blocks().len);
    try rig.keys("\x0e");
    try expectNoticeHolds(&rig, removal_warning);
    try rig.keys("x\x0e");
    try expectNoticeHolds(&rig, removal_warning);
    try std.testing.expectEqual(@as(usize, 4), rig.blocks().len);
    try rig.keys("\x0e");
    try std.testing.expectEqual(@as(usize, 1), rig.blocks().len);
    try std.testing.expectEqualStrings("fix it\nx", rig.app.screen.editor.visible());
}

test "a canceled retry offers no removal, and a new turn and /new drop the offer" {
    var stalls: [3]providers.testing.FakeTransport.Stall = @splat(.{ .io = std.testing.io });
    const replies = [_]providers.testing.FakeTransport.Reply{
        failed_reply,
        failed_reply,
        .{ .stall = &stalls[0] },
        .{ .stall = &stalls[1] },
        .{ .body = providers.testing.reply_stream },
        .{ .stall = &stalls[2] },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("a\r");
    try rig.settle();
    try rig.keys("\x0e");
    try stalls[0].reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.settle();
    try expectLastEvent(&rig, "You canceled the turn.");
    try std.testing.expect(rig.app.caption() == null);

    try rig.keys("b\r");
    try stalls[1].reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.settle();
    try std.testing.expectEqualStrings("Canceled turn", rig.app.caption().?.title);
    try rig.keys("c\r");
    try rig.settle();
    try std.testing.expect(rig.app.caption() == null);

    try rig.keys("d\r");
    try stalls[2].reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.settle();
    try std.testing.expectEqualStrings("Canceled turn", rig.app.caption().?.title);
    try rig.keys("/new\r");
    try rig.settle();
    try std.testing.expect(rig.app.caption() == null);
}

test "Ctrl+N returns the command line of a canceled skill turn" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{.{ .stall = &stall }};
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .files = &.{.{
            ".agents/skills/demo/SKILL.md",
            "---\nname: demo\ndescription: Demo.\n---\nBody.\n",
        }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    const before = rig.blocks().len;
    try rig.keys("/skill:demo apply it\r");
    try stall.reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.settle();
    try rig.keys("\x0e");
    try std.testing.expectEqual(before, rig.blocks().len);
    try std.testing.expectEqualStrings("/skill:demo apply it", rig.app.screen.editor.visible());
}

test "a signed-out submit and a submit without a model are refused with a notice" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try std.testing.expect(rig.app.choice.account == null);
    try rig.keys("\x03");
    try rig.keys("hi\r");
    try std.testing.expect(rig.app.mode == .prompt);
    try expectNoticeHolds(&rig, signed_out_refusal);
    try std.testing.expectEqualStrings("hi", rig.app.screen.editor.visible());

    var keyed: Rig = undefined;
    try keyed.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer keyed.deinit();
    try std.testing.expectEqual(accounts.testing.openai_api_key, keyed.app.choice.account.?);
    try std.testing.expect(keyed.app.choice.model == null);
    try keyed.keys("hi\r");
    try std.testing.expect(keyed.app.mode == .prompt);
    try expectNoticeHolds(&keyed, no_model_refusal);
}

test "a slash command opens its picker, a pick applies, and Esc leaves with a notice" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("/effort\r");
    try std.testing.expect(rig.app.mode == .picker);
    try std.testing.expectEqualStrings("Effort", rig.app.screen.widget.picking.picker.title);
    try rig.keys("\x1b");
    rig.clock.advance(escape_wait_ms - 1);
    try rig.app.flushEscape();
    try rig.settle();
    try std.testing.expect(rig.app.mode == .picker);
    rig.clock.advance(1);
    try rig.app.flushEscape();
    try std.testing.expect(rig.app.mode == .prompt);
    try expectNoticeHolds(&rig, "You canceled the effort selection.");

    try rig.keys("/effort\r");
    try std.testing.expectEqual(@as(usize, 3), rig.app.screen.widget.picking.picker.cursor);
    try rig.keys("\x1b[A" ** 3 ++ "\x1b[B" ++ "\x1b[A");
    try rig.keys("\r");
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expectEqual(core.Provider.Effort.low, rig.app.choice.effort);
    const blocks = rig.blocks();
    try std.testing.expectEqualStrings(
        "Drinky set the effort level to low.",
        blocks[blocks.len - 1].content.event.text.items,
    );
    try rig.settle();
    try rig.keys("hi\r");
    try rig.settle();
    try expectRequested(&rig, "\"effort\":\"low\"");
}

test "Ctrl+C and Ctrl+D in a picker end its command with its notice" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    for ([_][]const u8{ "\x03", "\x04" }) |exit_key| {
        try rig.keys("/effort\r");
        try std.testing.expect(rig.app.mode == .picker);
        try rig.keys(exit_key);
        try std.testing.expect(rig.app.mode == .prompt);
        try std.testing.expect(rig.app.running);
        try expectNoticeHolds(&rig, "You canceled the effort selection.");
    }
}

test "a refused command line reaches the model on the next Enter" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("/nope\r");
    try std.testing.expect(rig.app.mode == .prompt);
    try expectNoticeHolds(&rig, "Enter: Send as a message · Drinky does not recognize the command");
    try std.testing.expectEqualStrings("/nope", rig.app.screen.editor.visible());
    try rig.keys("\r");
    try std.testing.expect(rig.app.mode == .turn);
    try rig.settle();
    try expectRequested(&rig, "\"text\":\"/nope\"");
}

test "a command that its state refuses keeps its line" {
    for ([_][]const u8{ "/model", "/logout", "/skill" }) |line| {
        var rig: Rig = undefined;
        try rig.init(&.{});
        defer rig.deinit();
        try rig.keys("\x03");
        try rig.keys(line);
        try rig.keys("\r");
        try std.testing.expect(rig.app.mode == .prompt);
        try std.testing.expect(rig.app.screen.notice != null);
        try std.testing.expectEqualStrings(line, rig.app.screen.editor.visible());
    }
}

test "/new clears the conversation, and the next request starts fresh" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.reply_stream },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("first\r");
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 3), rig.blocks().len);

    try rig.keys("/new\r");
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 1), rig.blocks().len);
    try std.testing.expect(rig.blocks()[0].content == .intro);
    try std.testing.expectEqual(@as(?u64, 0), rig.app.screen.statusInfo(0).context_tokens);

    try rig.keys("second\r");
    try rig.settle();
    try std.testing.expect(std.mem.indexOf(u8, rig.lastRequest(), "\"text\":\"first\"") == null);
    try expectRequested(&rig, "\"text\":\"second\"");
}

test "Enter during a turn keeps the text, and Ctrl+D with a draft warns before it quits" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("hi\r");
    try std.testing.expect(rig.app.mode == .turn);
    try rig.keys("more\r");
    try expectNoticeHolds(&rig, turn_message_notice);
    try std.testing.expectEqualStrings("more", rig.app.screen.editor.visible());
    try rig.settle();
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expectEqualStrings("more", rig.app.screen.editor.visible());

    try rig.keys("\x04");
    try std.testing.expect(rig.app.running);
    try expectNoticeHolds(&rig, "Press Ctrl+D again to quit. The quit discards the draft.");
    try rig.keys("\x04");
    try std.testing.expect(!rig.app.running);
}

test "a Ctrl+D that ends a turn or closes a page warns before the next Ctrl+D quits" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = providers.testing.reply_stream, .hold = &hold },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hi\r");
    try hold.reached.wait(std.testing.io);
    try rig.keys("\x04");
    hold.released.set(std.testing.io);
    try rig.settle();
    try std.testing.expect(rig.app.mode == .prompt);
    try rig.keys("\x04");
    try std.testing.expect(rig.app.running);
    try expectNoticeHolds(&rig, "Press Ctrl+D again to quit.");
    try rig.keys("\x03");

    try rig.keys("/system\r");
    try std.testing.expect(rig.app.mode == .page);
    try rig.keys("\x04");
    try std.testing.expect(rig.app.mode == .prompt);
    try rig.keys("\x04");
    try std.testing.expect(rig.app.running);
    try expectNoticeHolds(&rig, "Press Ctrl+D again to quit.");
    try rig.keys("\x04");
    try std.testing.expect(!rig.app.running);
}

test "a notice that replaces the send offer of a refused command line withdraws the offer" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("/nope\r");
    try expectNoticeHolds(&rig, "Enter: Send as a message");
    emitAccountsEvent(&rig.app, &.{ .refused = .{
        .account = accounts.testing.openai_api_key,
        .command = .fetch,
        .reason = .busy,
    } });
    try rig.settle();
    try expectNoticeHolds(&rig, "Drinky cannot start this now");
    try rig.keys("\r");
    try std.testing.expect(rig.app.mode == .prompt);
    try expectNoticeHolds(&rig, "Enter: Send as a message");
    try rig.keys("\r");
    try std.testing.expect(rig.app.mode == .turn);
    try rig.settle();
    try expectRequested(&rig, "\"text\":\"/nope\"");
}

fn showsAuthorization(app: *const App) bool {
    const sign_in = switch (app.mode) {
        .sign_in => |sign_in| sign_in,
        else => return false,
    };
    return sign_in.event_index != null and app.screen.notice != null;
}

fn showsNotice(app: *const App) bool {
    return app.screen.notice != null;
}

fn editorEmpty(app: *const App) bool {
    return app.screen.editor.visible().len == 0;
}

fn loginEvent(rig: *const Rig) []const u8 {
    return rig.blocks()[rig.app.mode.sign_in.event_index.?].content.event.text.items;
}

const denied_login_event = "The provider did not authorize Drinky. Start the sign-in again.";

test "a sign-in shows its URL, and a pasted callback line reaches its listener" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();

    try rig.startLoginOf(anthropic_plan);
    try std.testing.expect(std.mem.startsWith(
        u8,
        loginEvent(&rig),
        "Open this URL to authorize the sign-in to anthropic-plan:\n\n" ++
            "https://claude.ai/oauth/authorize?",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        loginEvent(&rig),
        "paste the callback URL from its address bar and press Enter.",
    ));
    try expectNoticeHolds(
        &rig,
        "Drinky could not open the browser for the sign-in to anthropic-plan.",
    );

    try rig.keys("http://localhost:53692/callback?error=access_denied&state=unknown\r");
    try rig.pumpUntil(editorEmpty);
    try std.testing.expect(rig.app.mode == .sign_in);

    const shown = loginEvent(&rig);
    const state_start = std.mem.indexOf(u8, shown, "&state=").? + "&state=".len;
    const state_end = std.mem.indexOfAnyPos(u8, shown, state_start, "&\n").?;
    const line = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://localhost:53692/callback?error=access_denied&state={s}\r",
        .{shown[state_start..state_end]},
    );
    defer std.testing.allocator.free(line);
    try rig.keys(line);
    try rig.settle();
    try std.testing.expect(rig.app.mode != .sign_in);
    try std.testing.expectEqualStrings("", rig.app.screen.editor.visible());
    try expectEventText(&rig, denied_login_event);
    try std.testing.expect(!rig.app.account_registry.isAuthenticated(anthropic_plan));
}

test "a sign-in with a callback path takes a pasted line of that path alone" {
    const openrouter_login = accounts.Account.index("openrouter-api").?;
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();

    try rig.startLoginOf(openrouter_login);
    try std.testing.expect(std.mem.startsWith(
        u8,
        loginEvent(&rig),
        "Open this URL to authorize the sign-in to openrouter-api:\n\n" ++
            "https://openrouter.ai/auth?callback_url=",
    ));
    const encoded_prefix = "localhost%3A53694%2F";
    const url = loginEvent(&rig);
    const path_start = std.mem.indexOf(u8, url, encoded_prefix).? + encoded_prefix.len;
    const after_prefix = url[path_start..];
    const hex_end = std.mem.indexOfNone(u8, after_prefix, "0123456789abcdef") orelse
        after_prefix.len;
    const callback_hex = after_prefix[0..hex_end];

    try rig.keys("http://localhost:53694/elsewhere?error=access_denied\r");
    try rig.pumpUntil(showsNotice);
    try expectNoticeHolds(
        &rig,
        "The line is not the callback URL for the sign-in to openrouter-api.",
    );
    try std.testing.expect(rig.app.mode == .sign_in);

    const line = try std.fmt.allocPrint(
        std.testing.allocator,
        "\x03http://localhost:53694/{s}?error=access_denied\r",
        .{callback_hex},
    );
    defer std.testing.allocator.free(line);
    try rig.keys(line);
    try rig.settle();
    try std.testing.expect(rig.app.mode != .sign_in);
    try expectEventText(&rig, denied_login_event);
}

fn eventWith(rig: *const Rig, needle: []const u8) ?[]const u8 {
    for (rig.blocks()) |*block| switch (block.content) {
        .event => |event| if (std.mem.indexOf(u8, event.text.items, needle) != null)
            return event.text.items,
        else => {},
    };
    return null;
}

test "a completed sign-in reports a memory-only save and opens the model step" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{.{
        .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":3600}",
    }} });
    defer rig.deinit();
    var blocked = try rig.tmp.dir.createDirPathOpen(rig.app.io, ".drinky/auth.json", .{});
    blocked.close(rig.app.io);

    try rig.startLoginOf(anthropic_plan);
    const shown = loginEvent(&rig);
    const state_start = std.mem.indexOf(u8, shown, "&state=").? + "&state=".len;
    const state_end = std.mem.indexOfAnyPos(u8, shown, state_start, "&\n").?;
    const line = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://localhost:53692/callback?code=abc&state={s}\r",
        .{shown[state_start..state_end]},
    );
    defer std.testing.allocator.free(line);
    try rig.keys(line);
    try rig.settle();

    try std.testing.expect(rig.app.account_registry.isAuthenticated(anthropic_plan));
    try expectEventText(&rig, "Drinky signed in to anthropic-plan.");
    const needle = "Drinky could not save the credentials for anthropic-plan to ";
    const unsaved = eventWith(&rig, needle) orelse return error.TestExpectedEvent;
    try std.testing.expect(std.mem.endsWith(
        u8,
        unsaved,
        "The sign-in stays active until Drinky exits.",
    ));
    try std.testing.expect(rig.app.mode == .picker);
}

test "a paste after the listener closed clears the editor with a notice" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    rig.loopback.refuses = true;

    try rig.startLoginOf(anthropic_plan);
    try rig.keys("http://localhost:53692/callback?code=abc&state=any\r");
    try rig.pumpUntil(editorEmpty);
    try expectNoticeHolds(
        &rig,
        "Drinky already received the response for the sign-in to anthropic-plan.",
    );
    try std.testing.expect(rig.app.mode == .sign_in);
}

test "Esc with a draft warns before it cancels the turn, and Ctrl+D cancels at once" {
    var stalls: [2]providers.testing.FakeTransport.Stall = @splat(.{ .io = std.testing.io });
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .stall = &stalls[0] },
        .{ .stall = &stalls[1] },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hi\r");
    try stalls[0].reached.wait(std.testing.io);
    try rig.keys("draft");
    try rig.escape();
    try std.testing.expect(rig.app.mode == .turn);
    try expectNoticeHolds(&rig, turn_cancel_notice);
    try rig.escape();
    try rig.settle();
    try std.testing.expect(stalls[0].canceled);
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expectEqualStrings("draft", rig.app.screen.editor.visible());
    try expectLastEvent(&rig, "You canceled the turn.");

    try rig.keys("\r");
    try stalls[1].reached.wait(std.testing.io);
    try rig.keys("more");
    try rig.keys("\x04");
    try rig.settle();
    try std.testing.expect(stalls[1].canceled);
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expectEqualStrings("more", rig.app.screen.editor.visible());
    try expectLastEvent(&rig, "You canceled the turn.");
}

test "exit keys during a slow cancel cannot block the end of the turn" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = providers.testing.reply_stream, .hold = &hold },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hi\r");
    try hold.reached.wait(std.testing.io);
    try rig.keys("\x04" ** 65);
    hold.released.set(std.testing.io);
    try rig.settle();
    try std.testing.expect(rig.app.mode == .prompt);
}

test "a failed allocation at the sink still ends the turn" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{.{ .stall = &stall }};
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hi\r");
    try stall.reached.wait(std.testing.io);
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    rig.app.gpa = failing.allocator();
    emitSessionEvent(&rig.app, &.{ .turn_ended = .{ .failed = .{
        .reason = .network,
        .message = "down",
    } } });
    rig.app.gpa = std.testing.allocator;
    var batch: [queue_capacity]UiEvent = undefined;
    const count = try rig.app.queue.get(rig.app.io, &batch, 0);
    _ = try rig.app.applyBatch(batch[0..count]);
    try std.testing.expect(rig.app.mode == .prompt);
}

const rejected_reply: providers.testing.FakeTransport.Reply = .{
    .status = .unauthorized,
    .body = "{\"error\":{\"message\":\"expired\"}}",
};

fn planStore(comptime generation: []const u8) []const u8 {
    return "{ \"openai-plan\": { \"access\": \"access-" ++ generation ++
        "\", \"refresh\": \"refresh-" ++ generation ++
        "\", \"expires_ms\": 4102444800000, \"account_id\": \"account-1\" } }";
}

const plan_options: Rig.Options = .{
    .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
    .store = planStore("first"),
    .replies = &.{ rejected_reply, rejected_reply },
    .model = "gpt-5.6-sol",
    .model_accounts = &.{ accounts.testing.openai_plan, accounts.testing.openai_api_key },
};

fn expectRejectionHandOff(
    options: *const Rig.Options,
    event: []const u8,
    rest: std.meta.Tag(Mode),
) !void {
    var rig: Rig = undefined;
    try rig.init(options);
    defer rig.deinit();
    try std.testing.expectEqual(accounts.testing.openai_plan, rig.app.choice.account.?);

    try accounts.testing.writeStore(rig.app.io, &rig.tmp, planStore("second"));
    try rig.keys("hi\r");
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
    try expectRequestHolds(&rig, 0, "authorization: Bearer access-first\n");
    try expectRequestHolds(&rig, 1, "authorization: Bearer access-second\n");
    try std.testing.expect(!rig.app.account_registry.isAuthenticated(accounts.testing.openai_plan));
    try expectEventHolds(&rig, event);
    try std.testing.expectEqual(rest, std.meta.activeTag(rig.app.mode));
}

test "a rejected plan credential leaves the store and hands the session to the next account" {
    try expectRejectionHandOff(
        &plan_options,
        "Drinky signed out of openai-plan. Drinky now uses openai-api-key/gpt-5.6-sol.",
        .prompt,
    );

    var model_step = plan_options;
    model_step.model_accounts = &.{accounts.testing.openai_plan};
    try expectRejectionHandOff(
        &model_step,
        "Drinky signed out of openai-plan. Drinky now uses openai-api-key. ",
        .prompt,
    );

    var sign_in_step = model_step;
    sign_in_step.variables = &.{};
    try expectRejectionHandOff(
        &sign_in_step,
        "Drinky signed out of openai-plan. Select an account to sign in.",
        .picker,
    );
}

test "a rejected key credential keeps its account" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{rejected_reply},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hi\r");
    try rig.settle();
    try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
    try std.testing.expect(
        rig.app.account_registry.isAuthenticated(accounts.testing.openai_api_key),
    );
    try std.testing.expectEqual(accounts.testing.openai_api_key, rig.app.choice.account.?);
    try expectLastEvent(
        &rig,
        "The credential is missing or invalid. Details: 401 Unauthorized: expired",
    );
}

test "a rejected plan credential yields to the credential that another instance saved" {
    var rig: Rig = undefined;
    try rig.init(&plan_options);
    defer rig.deinit();

    try accounts.testing.writeStore(rig.app.io, &rig.tmp, planStore("second"));
    try rig.keys("hi\r");
    var batch: [queue_capacity]UiEvent = undefined;
    const held = try rig.takeUntilTurnEnd(&batch);
    try accounts.testing.writeStore(rig.app.io, &rig.tmp, planStore("third"));
    _ = try rig.app.applyBatch(held);
    try rig.settle();
    try std.testing.expect(rig.app.account_registry.isAuthenticated(accounts.testing.openai_plan));
    try std.testing.expectEqual(accounts.testing.openai_plan, rig.app.choice.account.?);
    try expectLastEvent(
        &rig,
        "Drinky reloaded the refresh credential that another Drinky instance saved. " ++
            "Try the turn again.",
    );
}

test "the login picker opens with the accounts, and a set key account switches at once" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{ .{ "OPENAI_API_KEY", "sk-openai" }, .{ "XAI_API_KEY", "xai" } },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("/login\r");
    try std.testing.expect(rig.app.mode == .picker);
    const picker = &rig.app.screen.widget.picking.picker;
    try std.testing.expectEqualStrings("Sign in", picker.title);
    try std.testing.expectEqual(accounts.testing.openai_api_key, picker.cursor);
    try rig.keys("\x1b[B\x1b[B\r");
    try rig.settle();
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expectEqual(accounts.Account.index("xai-api-key").?, rig.app.choice.account.?);
    try std.testing.expect(rig.app.choice.model == null);
    const blocks = rig.blocks();
    try std.testing.expectEqualStrings(
        "Drinky now uses xai-api-key. Fetch the model list of xai-api-key with /model.",
        blocks[blocks.len - 1].content.event.text.items,
    );
    try std.testing.expectEqualStrings("xai-api-key", rig.app.screen.statusInfo(0).account.?);
}

fn expectEventHolds(rig: *const Rig, needle: []const u8) !void {
    if (eventWith(rig, needle) != null) return;
    std.debug.print("the transcript holds no event with \"{s}\"\n", .{needle});
    return error.TestExpectedEvent;
}

test "the start reports each dropped config value and each notice" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{\"default_effort\":\"turbo\",\"bash\":{\"timeout_ms\":1}," ++
            "\"interface\":{\"window_pages\":0,\"gauge_percent_warning\":90," ++
            "\"gauge_percent_error\":10},\"user_instructions\":[{\"path\":\"missing.md\"}]," ++
            "\"required_skills\":[" ++ "{\"glob\":\"*.md\",\"skill\":\"docs\"}," **
            tools.SkillGuard.rules_max ++ "{\"glob\":\"*.md\",\"skill\":\"docs\"}]," ++
            "\"mystery\":1}",
        .files = &.{
            .{ ".agents/skills/broken/SKILL.md", "no front matter" },
            .{
                ".agents/skills/docs/SKILL.md",
                "---\nname: docs\ndescription: Docs.\n---\nBody.\n",
            },
        },
    });
    defer rig.deinit();
    try std.testing.expect(rig.app.mode == .prompt);
    try expectEventText(
        &rig,
        "Drinky ignored the configured default effort level \"turbo\" because Drinky does not " ++
            "know that level. Drinky uses the effort level \"xhigh\".",
    );
    try expectEventHolds(&rig, "Drinky ignored the configured command timeout 1 because");
    try expectEventText(
        &rig,
        "Drinky ignored the configured window page count 0 because the count must be from 1 " ++
            "to 64. Drinky uses the default count of 8 pages.",
    );
    try expectEventHolds(&rig, "Drinky ignored the gauge shares 90 and 10.");
    try expectEventHolds(&rig, "Drinky ignored the unknown config key \"mystery\" in ");
    try expectEventHolds(&rig, "missing.md");
    try expectEventHolds(&rig, "because the YAML front matter is missing.");
    try expectEventHolds(&rig, "Drinky used only the first 64 required skills in ");

    var corrupt: Rig = undefined;
    try corrupt.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{ not json",
    });
    defer corrupt.deinit();
    const config = eventWith(&corrupt, "Drinky could not read the config file ") orelse
        return error.TestExpectedEvent;
    try std.testing.expect(std.mem.endsWith(
        u8,
        config,
        "Drinky uses the default value of each key.",
    ));
}

test "a start without an account opens the sign-in picker with a notice" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try std.testing.expect(rig.app.mode == .picker);
    try std.testing.expectEqualStrings("Sign in", rig.app.screen.widget.picking.picker.title);
    try expectNoticeHolds(&rig, "Select an account to sign in.");
    try std.testing.expectEqual(@as(usize, 1), rig.blocks().len);
}

test "an exit key that closes a page drops the rest of its read" {
    var rig: Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer rig.deinit();
    try rig.keys("/system\r");
    try std.testing.expect(rig.app.mode == .page);
    try rig.keys("\x04abc");
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expectEqualStrings("", rig.app.screen.editor.visible());
    try rig.keys("abc");
    try std.testing.expectEqualStrings("abc", rig.app.screen.editor.visible());
}

test "Ctrl+C clears the draft, and a second Ctrl+C at once quits" {
    var rig: Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer rig.deinit();
    try rig.keys("draft\x03");
    try std.testing.expectEqualStrings("", rig.app.screen.editor.visible());
    try std.testing.expect(rig.app.running);
    try rig.keys("\x03");
    try std.testing.expect(!rig.app.running);
}

test "Esc ends a model fetch at its step, and Ctrl+C ends the whole command" {
    var step_stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var command_stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{ .{ .stall = &step_stall }, .{ .stall = &command_stall } },
    });
    defer rig.deinit();

    try rig.keys("/model\r");
    try std.testing.expect(rig.app.mode == .picker);
    try rig.keys("\r");
    try std.testing.expect(rig.app.mode == .fetch);
    try step_stall.reached.wait(std.testing.io);
    try rig.escape();
    try rig.settle();
    try std.testing.expect(step_stall.canceled);
    try std.testing.expect(rig.app.mode == .picker);
    try expectNoticeHolds(&rig, "You canceled the model fetch.");

    try rig.keys("\r");
    try std.testing.expect(rig.app.mode == .fetch);
    try command_stall.reached.wait(std.testing.io);
    try rig.keys("\x03");
    try rig.settle();
    try std.testing.expect(command_stall.canceled);
    try std.testing.expect(rig.app.mode == .prompt);
    try expectNoticeHolds(&rig, "You canceled the model selection.");
}

test "Esc on the models of an author returns to the author step at that author" {
    var rig: Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENROUTER_API_KEY", "sk-or" }} });
    defer rig.deinit();
    try accounts.testing.seedMetadata(
        &rig.app.account_registry.catalog,
        &.{ "qwen/qwen-new", "openai/gpt-new", "openai/gpt-old" },
    );

    try rig.keys("/model\r");
    try std.testing.expect(rig.app.mode == .picker);
    const authors = &rig.app.screen.widget.picking.picker;
    try std.testing.expectEqualStrings("Author: openrouter-api-key", authors.title);
    try rig.keys("\x1b[B\r");
    const models = &rig.app.screen.widget.picking.picker;
    try std.testing.expectEqualStrings("Model: openrouter-api-key", models.title);
    try rig.escape();
    try std.testing.expect(rig.app.mode == .picker);
    const restored = &rig.app.screen.widget.picking.picker;
    try std.testing.expectEqualStrings("Author: openrouter-api-key", restored.title);
    try std.testing.expectEqualStrings("openai", restored.options[restored.cursor].name);
}

test "/logout signs out of the chosen account and hands the session to the next one" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .store = planStore("first"),
        .model = "gpt-5.6-sol",
        .model_accounts = &.{ accounts.testing.openai_plan, accounts.testing.openai_api_key },
    });
    defer rig.deinit();
    try std.testing.expectEqual(accounts.testing.openai_plan, rig.app.choice.account.?);

    try rig.keys("/logout\r");
    try std.testing.expect(rig.app.mode == .picker);
    try std.testing.expectEqualStrings("Sign out", rig.app.screen.widget.picking.picker.title);
    try rig.keys("\r");
    try std.testing.expect(rig.app.mode == .prompt);
    try std.testing.expect(!rig.app.account_registry.isAuthenticated(accounts.testing.openai_plan));
    try std.testing.expectEqual(accounts.testing.openai_api_key, rig.app.choice.account.?);
    try expectLastEvent(
        &rig,
        "Drinky signed out of openai-plan. Drinky now uses openai-api-key/gpt-5.6-sol.",
    );
}

test "the page keys scroll the page, M toggles the source, and Esc closes the page" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{\"user_instructions\":[{\"path\":\"long.md\"}]}",
        .files = &.{.{ ".drinky/long.md", "Keep this line.\n\n" ** 40 }},
    });
    defer rig.deinit();
    try rig.keys("/system\r");
    try std.testing.expect(rig.app.mode == .page);
    const page = &rig.app.screen.widget.page;

    try rig.keys("\x1b[B");
    try std.testing.expectEqual(@as(usize, 1), page.scroll);
    try rig.keys("\x1b[6~");
    const paged = page.scroll;
    try std.testing.expect(paged > 1);
    try rig.keys("\x1b[5~");
    try std.testing.expectEqual(@as(usize, 1), page.scroll);
    try rig.keys("\x1b[4~");
    const end = page.scroll;
    try std.testing.expect(end >= paged);
    try rig.keys("\x1b[B");
    try std.testing.expectEqual(end, page.scroll);
    try rig.keys("\x1b[H");
    try std.testing.expectEqual(@as(usize, 0), page.scroll);
    try rig.keys("\x1b[A");
    try std.testing.expectEqual(@as(usize, 0), page.scroll);

    try rig.keys("m");
    try std.testing.expectEqual(ui.Page.Presentation.source, page.presentation);
    try rig.keys("M");
    try std.testing.expectEqual(ui.Page.Presentation.markdown, page.presentation);
    try rig.escape();
    try std.testing.expect(rig.app.mode == .prompt);
}
