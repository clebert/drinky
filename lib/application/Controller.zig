const std = @import("std");
const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");
const tools = @import("tools");
const billing = @import("billing.zig");
const Choice = @import("Choice.zig");
const Clients = @import("Clients.zig");
const Gists = @import("Gists.zig");
const Harness = @import("Harness.zig");
const Live = @import("Live.zig");
const project = @import("project.zig");
const query = @import("query.zig");
const Record = @import("Record.zig");
const reference = @import("reference.zig");
const Reports = @import("Reports.zig");
const Settings = @import("Settings.zig");
const Snapshot = @import("Snapshot.zig");
const State = @import("State.zig");
const Surface = @import("Surface.zig");
const testing = @import("testing.zig");
const tool_environment = @import("tool_environment.zig");
const Turns = @import("Turns.zig");
const Controller = @This();

const retry_request = "<retry_request>\nFailure: {t}\n{s}{s}{s}" ++
    "Continue from the last committed checkpoint.\n</retry_request>";

const gist_system = "You write a gist for a fresh coding-agent conversation. " ++
    "A gist is a compressed summary that lets the next agent continue the work. " ++
    "The messages hold the user prompts, the texts of the agent between its tool calls, " ++
    "and its final answers. They omit tool calls, tool results, reasoning, and the skills " ++
    "that the agent loaded. A user prompt can hold a skill that the user invoked. " ++
    "Treat that skill as instructions, not as words that the user typed. " ++
    "A user message inside <gist> tags holds an earlier gist, not text that the user typed. " ++
    "Keep its facts unless later messages replace them. " ++
    "The last user message asks for the gist. " ++
    "Its optional instruction guides the gist, not work on the repository. " ++
    "Describe the current state of the work, not its history. " ++
    "Start with one line of plain text that holds a short title. " ++
    "Then state the goal and the requirements in effect. " ++
    "A later requirement replaces an earlier one, and a withdrawn requirement disappears. " ++
    "Keep the exact words of the user for hard constraints. " ++
    "State each decision with its reason, and tell user decisions from agent decisions. " ++
    "State the learnings: facts about the code, failed approaches, and traps. " ++
    "State the completed work, the verification results, and the remaining work. " ++
    "Reduce each finished part to one line. Drop learnings that no longer affect open work. " ++
    "Preserve pending user decisions and the current workflow, including any interview. " ++
    "Name the relevant files and any skills that the next agent must read again. " ++
    "Distinguish verified results from assumptions and failed or incomplete checks. " ++
    "Copy paths, commands, and technical identifiers exactly. " ++
    "Keep the language of the task. Be concise without a fixed word count. " ++
    "Write a self-contained user message for the next agent. " ++
    "Tell it to resume the work and ask for any user decision that still blocks it. " ++
    "Do not invent facts or add unrelated tasks. Output only the gist.";
const gist_request = "Write the gist.";
const gist_instruction = gist_request ++ "\n<instruction>\n{s}\n</instruction>";
const gist_message = "<gist>\n{s}\n</gist>";

gpa: std.mem.Allocator,
io: std.Io,
sink: Sink,
mailbox: Mailbox,
harness: Harness,
account_registry: accounts.Registry,
saved: accounts.State,
session: core.Session,
clients: Clients,
choice: Choice,
offer: ?Offer = null,
turns: Turns,
working_directory: []const u8,
home_directory: []const u8,
branch_root: ?[]const u8 = null,
gists: Gists = undefined,
branch_buffer: [project.head_bytes_max]u8 = undefined,
branch_length: ?usize = null,
notice: ?Record.Event = null,
notice_id: u64 = 0,
revision: u64 = 0,
surface: Surface,
closing: std.atomic.Value(bool) = .init(false),
work: Work = .idle,
operation_next: u64 = 1,
conversation: u64 = 0,
result: ?Result = null,
fetch_end: ?Event.FetchEnd = null,
paste_pending: bool = false,
response: Response = .{},
recovered: ?[]const u8 = null,
failed_path: ?[]u8 = null,
gist_read: ?[]u8 = null,
found_models: std.ArrayList(accounts.Model) = .empty,
model_facts: std.ArrayList(query.Model) = .empty,
turn_facts: std.ArrayList(query.Turn) = .empty,
skill_facts: std.ArrayList(query.Skill) = .empty,
published: ?Mark = null,
startup: Startup,
settings: Settings,
ready: bool = false,
run_block: ?std.process.Environ.PosixBlock = null,
startup_refusal: ?StartupRefusal = null,

pub const Handle = opaque {
    pub fn create(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !*Handle {
        return Controller.create(gpa, io, options) catch |err| switch (err) {
            error.OutOfMemory => core.fatal.outOfMemory(),
            else => return err,
        };
    }
    pub fn submit(handle: *Handle, command_value: *const Command) Response {
        const self = controllerOf(handle);
        self.execute(command_value) catch |err| switch (err) {
            error.OutOfMemory => core.fatal.outOfMemory(),
            error.Canceled => {},
        };
        self.publish();
        return self.response;
    }
    pub fn receive(handle: *Handle, mail: Mail) void {
        const self = controllerOf(handle);
        defer mail.deinit(self.gpa);
        const applied = switch (mail) {
            .session => |*event| self.applySessionEvent(event),
            .accounts => |*event| self.applyAccountsEvent(event),
        };
        applied catch |err| switch (err) {
            error.OutOfMemory => core.fatal.outOfMemory(),
        };
        self.publish();
    }
    pub fn listAccounts(handle: *Handle) [query.account_count]query.Account {
        const self = controllerOf(handle);
        return query.accountsOf(&self.account_registry, self.rememberedNames());
    }
    pub fn listModels(handle: *Handle, account: usize) []const query.Model {
        const self = controllerOf(handle);
        return self.modelFacts(account) catch core.fatal.outOfMemory();
    }
    pub fn effort(handle: *Handle) query.Effort {
        return query.effortOf(&controllerOf(handle).choice);
    }
    pub fn listTurns(handle: *Handle) []const query.Turn {
        const self = controllerOf(handle);
        return self.turnFacts() catch core.fatal.outOfMemory();
    }
    pub fn listSkills(handle: *Handle) []const query.Skill {
        const self = controllerOf(handle);
        return self.skillFacts() catch core.fatal.outOfMemory();
    }
    pub fn listGists(handle: *Handle) query.GistList {
        const self = controllerOf(handle);
        return self.gistFacts() catch core.fatal.outOfMemory();
    }
    pub fn readGist(handle: *Handle, id: *const Gists.Id) query.GistText {
        const self = controllerOf(handle);
        return self.gistText(id) catch core.fatal.outOfMemory();
    }
    pub fn state(handle: *Handle) State {
        return controllerOf(handle).currentState();
    }
    pub fn operation(handle: *Handle, id: u64) query.Operation {
        const self = controllerOf(handle);
        if (self.work.view().operation() == id) return .running;
        if (self.fetch_end) |ended| {
            if (ended.operation == id) return .{ .fetch_ended = ended.outcome };
        }
        const index = self.turns.find(id) orelse return .unknown;
        return .{ .turn_ended = self.turns.all()[index].end orelse return .unknown };
    }
    pub fn documents(handle: *Handle) query.Documents {
        const harness = &controllerOf(handle).harness;
        return .{
            .system_prompt = harness.system,
            .user_instructions = harness.config.user_instructions.files(),
            .project_instructions = harness.project_instructions.files(),
            .skills = harness.skill_registry.items(),
            .required_skills = harness.skill_guard.rules(),
            .required_missing = harness.required_missing.items,
        };
    }
    pub fn destroy(handle: *Handle) void {
        const self = controllerOf(handle);
        self.closing.store(true, .release);
        const gpa = self.gpa;
        self.deinit();
        gpa.destroy(self);
    }
};

pub const Startup = union(enum) {
    session,
    run: struct { model: []const u8, effort: core.Provider.Effort, prompt: []const u8 },
};
pub const Options = struct {
    directories: accounts.json_store.Directories,
    environment: *const std.process.Environ.Map,
    environ: std.process.Environ = .empty,
    startup: Startup = .session,
    frontend: Harness.Frontend,
    transport: ?providers.Transport = null,
    browser: ?accounts.oauth.login.Browser = null,
    loopback: ?accounts.oauth.callback.Loopback = null,
    sink: Sink,
    mailbox: Mailbox,
};
pub const Command = union(enum) {
    send_message: []const u8,
    invoke_skill: Skill,
    new_conversation,
    select_account: usize,
    sign_out: usize,
    submit_callback: Callback,
    fetch_models: usize,
    select_model: ModelChoice,
    set_effort: core.Provider.Effort,
    retry,
    remove_canceled_turn: u64,
    rewind: u64,
    prepare_gist: []const u8,
    save_result: u64,
    apply_result: u64,
    discard_result: u64,
    apply_gist: Gists.Id,
    delete_gist: Gists.Id,
    cancel: u64,
    dismiss_offer,
    dismiss_notice: u64,
    refresh_project,
    snapshot,

    pub const Skill = struct { name: []const u8, arguments: []const u8, line: []const u8 };
    pub const Callback = struct { operation: u64, line: []const u8 };
    pub const ModelChoice = struct { account: usize, model: []const u8 };
};
pub const Response = struct {
    refusal: ?Refusal = null,
    operation: ?u64 = null,
    recovered: ?[]const u8 = null,

    pub fn accepted(self: *const Response) bool {
        return self.refusal == null;
    }
};
pub const Refusal = union(enum) {
    busy,
    signed_out,
    no_model,
    unknown_target,
    stale,
    unavailable,
    no_conversation,
    skill_unreadable: SkillUnreadable,
    account_unloaded: Unloaded,
    credential_missing: usize,
    gist_failed: Gists.Failure,
    gist_invalid: []const u8,

    pub const SkillUnreadable = struct { name: []const u8, cause: tools.skill_file.ReadError };
    pub const Unloaded = struct { account: usize, cause: accounts.Registry.LoadError };
};
pub const StartupRefusal = union(enum) {
    nested,
    prompt_missing,
    prompt_not_utf8,
    unknown_model: []const u8,
    account_unloaded: Refusal.Unloaded,
    signed_out: usize,
    credential_missing: usize,

    pub fn dupe(
        self: *const StartupRefusal,
        gpa: std.mem.Allocator,
    ) error{OutOfMemory}!StartupRefusal {
        return switch (self.*) {
            .unknown_model => |value| .{ .unknown_model = try gpa.dupe(u8, value) },
            .nested,
            .prompt_missing,
            .prompt_not_utf8,
            .account_unloaded,
            .signed_out,
            .credential_missing,
            => self.*,
        };
    }

    pub fn deinit(self: *const StartupRefusal, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .unknown_model => |value| gpa.free(value),
            .nested,
            .prompt_missing,
            .prompt_not_utf8,
            .account_unloaded,
            .signed_out,
            .credential_missing,
            => {},
        }
    }
};
pub const Mail = union(enum) {
    session: core.Session.Event,
    accounts: accounts.Registry.Event,

    pub fn deinit(self: *const Mail, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .session => |*event| event.deinit(gpa),
            .accounts => |*event| event.deinit(gpa),
        }
    }
};
pub const Mailbox = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        post: *const fn (ptr: *anyopaque, mail: Mail) void,
    };

    pub fn post(self: Mailbox, mail: Mail) void {
        self.vtable.post(self.ptr, mail);
    }
};
pub const Sink = core.actor.Sink(Event);

const Work = union(enum) {
    idle,
    turn: u64,
    aside: Aside,
    sign_in: SignIn,
    fetch: Fetch,

    const Aside = struct { id: u64, canceled: bool = false };
    const SignIn = struct {
        id: u64,
        account: usize,
        callback: bool,
        record_index: ?usize = null,
        canceled: bool = false,
    };
    const Fetch = struct { id: u64, account: usize, canceled: bool = false };

    fn view(self: *const Work) State.Work {
        return switch (self.*) {
            .idle => .idle,
            .turn => |id| .{ .turn = id },
            .aside => |aside| .{ .aside = aside.id },
            .sign_in => |sign_in| .{ .sign_in = .{
                .operation = sign_in.id,
                .account = sign_in.account,
                .callback = sign_in.callback,
            } },
            .fetch => |fetch| .{ .fetch = .{ .operation = fetch.id, .account = fetch.account } },
        };
    }
};

const Result = struct {
    id: u64,
    conversation: u64,
    phase: State.Result.Phase,
    text: std.ArrayList(u8) = .empty,

    fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        Record.freeData(gpa, &self.phase);
    }

    fn view(self: *const Result) State.Result {
        return .{ .id = self.id, .phase = self.phase, .text = self.text.items };
    }
};

const Offer = union(enum) {
    retry: []u8,
    removal,

    fn deinit(self: *const Offer, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .retry => |request| gpa.free(request),
            .removal => {},
        }
    }
};

const TurnStart = struct {
    text: []const u8,
    start: usize,
    prompt: ?Turns.Prompt,
};

const Mark = struct {
    revision: u64,
    work: State.Work,
    offer: State.Offer,
};

pub const Event = union(enum) {
    snapshot: Snapshot,
    append_record: Record,
    record_text: RecordText,
    replace_record: Record,
    remove_records: []const u64,
    live: Live,
    statistics: Surface.Statistics,
    state: State,
    clear_conversation,
    paste_replayed,
    turn_ended: TurnEnd,
    sign_in_ended: SignInEnd,
    fetch_ended: FetchEnd,
    no_account,
    charge: f64,
    startup_refused: StartupRefusal,

    pub const RecordText = struct { id: u64, text: []const u8 };
    pub const TurnEnd = struct { outcome: core.Session.Outcome, answer: []const u8 };
    pub const SignInEnd = struct { operation: u64, account: usize, signed_in: bool };
    pub const FetchEnd = struct {
        operation: u64,
        account: usize,
        outcome: query.FetchOutcome,
    };

    pub fn dupe(self: *const Event, gpa: std.mem.Allocator) error{OutOfMemory}!Event {
        return switch (self.*) {
            .snapshot => |*value| .{ .snapshot = try value.dupe(gpa) },
            .state => |*value| .{ .state = try value.dupe(gpa) },
            inline .append_record, .replace_record => |*value, tag| @unionInit(
                Event,
                @tagName(tag),
                try value.dupe(gpa),
            ),
            .record_text => |value| .{
                .record_text = .{ .id = value.id, .text = try gpa.dupe(u8, value.text) },
            },
            .remove_records => |ids| .{ .remove_records = try gpa.dupe(u64, ids) },
            .live => |*value| .{ .live = try value.dupe(gpa) },
            .turn_ended => |*value| turn: {
                const answer = try gpa.dupe(u8, value.answer);
                errdefer gpa.free(answer);
                break :turn .{
                    .turn_ended = .{ .outcome = try value.outcome.dupe(gpa), .answer = answer },
                };
            },
            .startup_refused => |*value| .{ .startup_refused = try value.dupe(gpa) },
            .statistics,
            .clear_conversation,
            .paste_replayed,
            .sign_in_ended,
            .fetch_ended,
            .no_account,
            .charge,
            => self.*,
        };
    }

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .snapshot => |*value| value.deinit(gpa),
            .state => |*value| value.deinit(gpa),
            .append_record, .replace_record => |value| {
                var owned = value;
                owned.deinit(gpa);
            },
            .record_text => |value| gpa.free(value.text),
            .remove_records => |ids| gpa.free(ids),
            .live => |*value| value.deinit(gpa),
            .turn_ended => |*value| {
                value.outcome.deinit(gpa);
                gpa.free(value.answer);
            },
            .startup_refused => |*value| value.deinit(gpa),
            .statistics,
            .clear_conversation,
            .paste_replayed,
            .sign_in_ended,
            .fetch_ended,
            .no_account,
            .charge,
            => {},
        }
    }
};

const surface_sink_vtable: Sink.VTable = .{ .emit = emitSurfaceEvent };
const session_sink_vtable: core.Session.Sink.VTable = .{ .emit = emitSessionEvent };
const accounts_sink_vtable: accounts.Registry.Sink.VTable = .{ .emit = emitAccountsEvent };

fn create(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !*Handle {
    const self = try gpa.create(Controller);
    errdefer gpa.destroy(self);
    try self.init(gpa, io, options);
    return @ptrCast(self);
}

fn controllerOf(handle: *Handle) *Controller {
    return @ptrCast(@alignCast(handle));
}

fn emitSurfaceEvent(ptr: *anyopaque, event: *const Event) void {
    const self: *Controller = @ptrCast(@alignCast(ptr));
    self.emit(event);
}

fn emitSessionEvent(ptr: *anyopaque, event: *const core.Session.Event) void {
    const self: *Controller = @ptrCast(@alignCast(ptr));
    if (self.closing.load(.acquire)) return;
    const owned = event.dupe(self.gpa) catch core.fatal.outOfMemory();
    self.mailbox.post(.{ .session = owned });
}

fn emitAccountsEvent(ptr: *anyopaque, event: *const accounts.Registry.Event) void {
    const self: *Controller = @ptrCast(@alignCast(ptr));
    if (self.closing.load(.acquire)) return;
    const owned = event.dupe(self.gpa) catch core.fatal.outOfMemory();
    self.mailbox.post(.{ .accounts = owned });
}

fn init(self: *Controller, gpa: std.mem.Allocator, io: std.Io, options: *const Options) !void {
    const directories = &options.directories;
    const cwd = directories.working_directory;
    self.* = .{
        .gpa = gpa,
        .io = io,
        .sink = options.sink,
        .mailbox = options.mailbox,
        .harness = undefined,
        .account_registry = undefined,
        .saved = undefined,
        .session = undefined,
        .clients = .init(gpa),
        .choice = .{ .effort = reference.effort_default },
        .turns = .init(gpa),
        .working_directory = cwd,
        .home_directory = "",
        .surface = undefined,
        .startup = options.startup,
        .settings = .{},
    };
    errdefer if (self.startup_refusal) |*refusal| refusal.deinit(gpa);
    errdefer self.turns.deinit();
    var environ = options.environ;
    if (options.startup == .run) {
        if (startupRefusal(options)) |refusal| {
            self.startup_refusal = refusal;
            return self.emit(&.{ .startup_refused = refusal });
        }
        var environment = try options.environment.clone(gpa);
        defer environment.deinit();
        _ = environment.swapRemove(tools.CostPipe.environment);
        try environment.put(reference.nested, "1");
        self.run_block = try environment.createPosixBlock(gpa, .{});
        environ = .{ .block = self.run_block.? };
    }
    errdefer if (self.run_block) |block| block.deinit(gpa);
    try self.harness.init(
        gpa,
        io,
        &.{
            .directories = directories.*,
            .environ = environ,
            .surface = if (options.startup == .run) .run else .session,
            .frontend = options.frontend,
        },
    );
    errdefer self.harness.deinit(gpa);
    try self.openRegistry(options, self.harness.config.timeouts);
    errdefer self.account_registry.deinit();
    self.home_directory = try homeDirectory(gpa, io, directories);
    errdefer gpa.free(self.home_directory);
    self.gists = try .init(gpa, self.home_directory);
    errdefer self.gists.deinit();
    if (options.startup == .session) {
        self.saved = try accounts.State.open(
            gpa,
            io,
            &.{
                .directories = directories.*,
                .project = self.harness.project_instructions.projectRoot() orelse cwd,
            },
        );
    }
    errdefer if (options.startup == .session) self.saved.deinit();
    self.session = self.harness.session(gpa, io, .{ .ptr = self, .vtable = &session_sink_vtable });
    errdefer self.session.deinit();
    errdefer self.clients.deinit();
    const config = &self.harness.config;
    if (options.startup == .session) {
        self.choice.effort = self.saved.start.effort orelse
            config.effort_default orelse reference.effort_default;
        if (self.startAccount()) |account| {
            self.adopt(account);
            try self.saved.seed(account, self.choice.modelName(), self.choice.effort);
        }
    } else try self.selectRun(options.startup.run.model, options.startup.run.effort);
    self.settings = .{
        .window_pages = config.window_pages,
        .verbose = config.verbose,
        .mcp_access = config.mcp_access,
        .gauge = config.gauge,
        .animation = config.animation,
    };
    self.surface = .init(
        gpa,
        io,
        .{ .ptr = self, .vtable = &surface_sink_vtable },
        self.choice,
    );
    self.surface.muted = true;
    errdefer self.surface.deinit();
    errdefer self.closing.store(true, .release);
    try self.session.start();
    if (options.startup == .session) try self.account_registry.start();
    self.ready = true;
    try self.sync();
    if (options.startup == .session) {
        self.branch_root = self.harness.project_instructions.projectRoot();
        try self.refreshBranch();
        try self.reportStart();
    }
    self.publish();
    self.surface.muted = false;
    if (options.startup == .run) try self.startRun(options.startup.run.prompt);
}
fn startupRefusal(options: *const Options) ?StartupRefusal {
    if (options.environment.get(reference.nested) != null) return .nested;
    const prompt = options.startup.run.prompt;
    if (!std.unicode.utf8ValidateSlice(prompt)) return .prompt_not_utf8;
    if (std.mem.trim(u8, prompt, &std.ascii.whitespace).len == 0) return .prompt_missing;
    return null;
}
fn startRun(self: *Controller, prompt: []const u8) !void {
    if (self.startup_refusal) |refusal| return self.emit(&.{ .startup_refused = refusal });
    try self.startUserTurn(prompt);
    self.publish();
}
fn openRegistry(
    self: *Controller,
    options: *const Options,
    timeouts: accounts.Registry.Timeouts,
) !void {
    try self.account_registry.init(self.gpa, self.io, &.{
        .directories = options.directories,
        .environment = options.environment,
        .sink = .{ .ptr = self, .vtable = &accounts_sink_vtable },
        .timeouts = timeouts,
        .transport = options.transport,
        .browser = options.browser,
        .loopback = options.loopback,
    });
}
fn deinit(self: *Controller) void {
    if (self.startup_refusal) |*refusal| refusal.deinit(self.gpa);
    self.releaseResponse();
    self.found_models.deinit(self.gpa);
    self.model_facts.deinit(self.gpa);
    self.turn_facts.deinit(self.gpa);
    self.skill_facts.deinit(self.gpa);
    if (self.gist_read) |owned| self.gpa.free(owned);
    if (self.ready) {
        if (self.notice) |*notice| notice.deinit(self.gpa);
        self.dropResult();
        self.dropOffer();
        self.turns.deinit();
        self.surface.deinit();
        self.session.deinit();
        self.clients.deinit();
        if (self.startup == .session) self.saved.deinit();
        self.gists.deinit();
        self.gpa.free(self.home_directory);
        self.account_registry.deinit();
        self.harness.deinit(self.gpa);
    }
    if (self.run_block) |block| block.deinit(self.gpa);
}
fn selectRun(self: *Controller, value: []const u8, effort: core.Provider.Effort) !void {
    self.choice.effort = effort;
    const slash = std.mem.findScalar(u8, value, '/') orelse return self.unknownRunModel(value);
    const account = accounts.Account.index(value[0..slash]) orelse
        return self.unknownRunModel(value);
    if (!self.account_registry.isAuthenticated(account)) {
        self.startup_refusal = if (self.account_registry.loadError(account)) |err|
            .{ .account_unloaded = .{ .account = account, .cause = err } }
        else switch (accounts.Account.table[account].credential) {
            .store => .{ .signed_out = account },
            .environment, .key_file => .{ .credential_missing = account },
        };
        return;
    }
    const model = self.account_registry.findModel(account, value[slash + 1 ..]) orelse
        return self.unknownRunModel(value);
    self.choice.account = account;
    self.choice.model = model;
}
fn unknownRunModel(self: *Controller, value: []const u8) !void {
    self.startup_refusal = .{ .unknown_model = try self.gpa.dupe(u8, value) };
}
fn homeDirectory(
    gpa: std.mem.Allocator,
    io: std.Io,
    directories: *const accounts.json_store.Directories,
) ![]u8 {
    const resolved = try std.Io.Dir.path.resolve(
        gpa,
        &.{ directories.working_directory, directories.home },
    );
    errdefer gpa.free(resolved);
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, resolved, gpa) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return resolved,
        };
    defer gpa.free(canonical);
    const owned = try gpa.dupe(u8, canonical);
    gpa.free(resolved);
    return owned;
}

fn refreshBranch(self: *Controller) error{OutOfMemory}!void {
    const root = self.branch_root orelse return self.setBranch(null);
    var maybe_head = try project.head(self.gpa, self.io, root);
    self.setBranch(if (maybe_head) |*head| head.name() else null);
}

fn setBranch(self: *Controller, maybe_name: ?[]const u8) void {
    const unchanged = if (self.branch()) |shown|
        if (maybe_name) |name| std.mem.eql(u8, shown, name) else false
    else
        maybe_name == null;
    if (unchanged) return;
    self.branch_length = if (maybe_name) |name| length: {
        std.debug.assert(name.len <= self.branch_buffer.len);
        @memcpy(self.branch_buffer[0..name.len], name);
        break :length name.len;
    } else null;
    self.changed();
}

fn branch(self: *const Controller) ?[]const u8 {
    const length = self.branch_length orelse return null;
    return self.branch_buffer[0..length];
}

fn reportStart(self: *Controller) !void {
    const config = &self.harness.config;
    var config_reports = try config.reports(self.gpa, .{
        .effort = self.choice.effort,
        .required_capped = self.harness.required_capped,
    });
    defer config_reports.deinit(self.gpa);
    try self.recordReports(&config_reports);
    try self.recordReports(&config.user_instructions.reports);
    try self.recordReports(&self.harness.project_instructions.reports);
    try self.recordReports(&self.harness.skill_registry.reports);
    if (self.choice.account == null) {
        try self.setNotice(&.no_account);
        self.emit(&.no_account);
    }
}

fn startAccount(self: *Controller) ?usize {
    if (self.saved.start.account) |account| {
        if (self.account_registry.isAuthenticated(account)) return account;
    }
    return self.account_registry.firstAuthenticated();
}

const no_remembered_names: [query.account_count]?[]const u8 = @splat(null);

fn rememberedNames(self: *const Controller) *const [query.account_count]?[]const u8 {
    if (self.startup != .session) return &no_remembered_names;
    return &self.saved.model_names;
}

fn modelFacts(self: *Controller, account: usize) error{OutOfMemory}![]const query.Model {
    std.debug.assert(account < query.account_count);
    self.found_models.clearRetainingCapacity();
    self.model_facts.clearRetainingCapacity();
    try self.account_registry.listModels(account, &self.found_models, self.gpa);
    try self.model_facts.ensureTotalCapacity(self.gpa, self.found_models.items.len);
    for (self.found_models.items) |*model|
        self.model_facts.appendAssumeCapacity(query.modelOf(account, model));
    return self.model_facts.items;
}

fn turnFacts(self: *Controller) error{OutOfMemory}![]const query.Turn {
    const turns = self.turns.all();
    try self.turn_facts.resize(self.gpa, turns.len);
    var dropped = false;
    var first = turns.len;
    for (0..turns.len) |offset| {
        const index = turns.len - 1 - offset;
        dropped = dropped or turns[index].mutated;
        const prompt = turns[index].prompt orelse continue;
        first -= 1;
        self.turn_facts.items[first] = .{
            .id = turns[index].id,
            .prompt = prompt,
            .drops_mutating_turn = dropped,
        };
    }
    return self.turn_facts.items[first..];
}

fn skillFacts(self: *Controller) error{OutOfMemory}![]const query.Skill {
    const items = self.harness.skill_registry.items();
    self.skill_facts.clearRetainingCapacity();
    try self.skill_facts.ensureTotalCapacity(self.gpa, items.len);
    for (items) |*skill| self.skill_facts.appendAssumeCapacity(.{
        .name = skill.name,
        .description = skill.description,
    });
    return self.skill_facts.items;
}

fn gistFacts(self: *Controller) error{OutOfMemory}!query.GistList {
    const listing: query.GistList.Listing = if (self.gists.list(self.io)) |listed|
        .{ .listed = listed }
    else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |cause| .{ .unreadable = cause },
    };
    return .{ .directory = self.gists.directory, .listing = listing };
}

fn gistText(self: *Controller, id: *const Gists.Id) error{OutOfMemory}!query.GistText {
    if (self.gist_read) |owned| self.gpa.free(owned);
    self.gist_read = null;
    const path = try self.gists.path(self.gpa, id);
    const text = self.gists.read(self.gpa, self.io, id) catch |err| {
        self.gist_read = path;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => |cause| .{ .failed = .{ .path = path, .cause = cause } },
        };
    };
    if (Gists.parse(text) == null) {
        self.gpa.free(text);
        self.gist_read = path;
        return .{ .invalid = path };
    }
    self.gpa.free(path);
    self.gist_read = text;
    return .{ .text = text };
}

fn sync(self: *Controller) !void {
    const shown = self.surface.choice;
    self.surface.showChoice(&self.choice);
    self.clients.select(&self.account_registry, self.choice.account) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SignedOut => {
            self.choice.account = null;
            self.choice.model = null;
            self.surface.showChoice(&self.choice);
        },
    };
    if (!shown.eql(&self.choice)) self.changed();
    try self.configure();
    try self.recordState();
}

fn configure(self: *Controller) !void {
    const current = self.clients.current orelse return;
    const model = if (self.choice.model) |*model| model else return;
    if (self.clients.configured) |*configured| {
        if (configured.eql(&self.choice)) return;
    }
    const account_id = accounts.Account.table[current.account].id;
    const model_value = try self.gpa.print("{s}/{s}", .{ account_id, model.name() });
    defer self.gpa.free(model_value);
    const variables = tool_environment.variables(model_value, self.choice.effort);
    try self.session.send(&.{ .configure = .{
        .provider = current.client.provider(),
        .account = account_id,
        .model = model.name(),
        .effort = self.choice.fold(),
        .tokens_max = model.tokens_max,
        .system = self.harness.system,
        .variables = &variables,
    } });
    self.clients.addSetup(&self.choice);
}

fn recordState(self: *Controller) !void {
    if (self.startup != .session) return;
    const account = self.choice.account orelse return;
    self.saved.record(account, self.choice.modelName(), self.choice.effort) catch |err|
        try self.reportStateSaveFailure(err);
}

fn reportStateSaveFailure(self: *Controller, err: accounts.json_store.SaveError) !void {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StoreBusy => return self.recordEvent(&.choices_busy),
        error.CorruptStore => return self.recordEvent(&.{ .choices_corrupt = self.saved.path }),
        inline else => |cause| comptime core.error_set.requireMember(
            accounts.json_store.FileError,
            cause,
        ),
    }
    try self.recordEvent(&.{ .choices_unsaved = .{
        .path = self.saved.path,
        .cause = @errorName(err),
    } });
}

fn dropOffer(self: *Controller) void {
    const offer = self.offer orelse return;
    offer.deinit(self.gpa);
    self.offer = null;
}

fn nextOperation(self: *Controller) u64 {
    defer self.operation_next += 1;
    return self.operation_next;
}

fn releaseResponse(self: *Controller) void {
    if (self.recovered) |text| self.gpa.free(text);
    self.recovered = null;
    if (self.failed_path) |path| self.gpa.free(path);
    self.failed_path = null;
    self.response = .{};
}

fn refuse(self: *Controller, refusal: Refusal) void {
    self.response.refusal = refusal;
}

fn refuseBusy(self: *Controller) bool {
    if (self.work == .idle) return false;
    self.refuse(.busy);
    return true;
}

fn refusePrerequisite(self: *Controller) !bool {
    if (self.clients.configured == null or !self.clients.configured.?.eql(&self.choice))
        try self.sync();
    if (self.choice.account == null or self.clients.current == null) {
        self.refuse(.signed_out);
        return true;
    }
    if (self.choice.model == null) {
        self.refuse(.no_model);
        return true;
    }
    return false;
}

fn sendMessage(self: *Controller, text: []const u8) !void {
    if (self.refuseBusy()) return;
    if (try self.refusePrerequisite()) return;
    try self.startUserTurn(text);
}

fn invokeSkill(self: *Controller, skill: *const Command.Skill) !void {
    if (self.refuseBusy()) return;
    const target = self.harness.skill_registry.get(skill.name) orelse
        return self.refuse(.unknown_target);
    const content = target.invoke(self.gpa, self.io, skill.arguments) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => |known| return known,
        else => return self.refuse(.{ .skill_unreadable = .{ .name = target.name, .cause = err } }),
    };
    defer self.gpa.free(content);
    if (try self.refusePrerequisite()) return;
    const start = self.surface.transcript.entries().len;
    try self.surface.appendSkillNote(&.{ .name = target.name, .source = target.path });
    if (skill.arguments.len > 0) try self.surface.appendUser(skill.arguments);
    try self.runTurn(&.{ .text = content, .start = start, .prompt = .{ .line = skill.line } });
}

fn newConversation(self: *Controller) !void {
    if (self.refuseBusy()) return;
    try self.session.send(&.clear);
    self.clearConversation();
    try self.sync();
}

fn clearConversation(self: *Controller) void {
    self.dropOffer();
    self.turns.truncate(0);
    self.surface.clearConversation();
    self.conversation +%= 1;
}

fn selectAccount(self: *Controller, account: usize) !void {
    if (self.refuseBusy()) return;
    if (account >= query.account_count) return self.refuse(.unknown_target);
    if (self.choice.isActive(account)) return self.setNotice(&.{ .account_active = account });
    if (self.account_registry.isAuthenticated(account)) {
        self.adopt(account);
        try self.recordEvent(&.{ .use_changed = self.currentUse() });
        return self.sync();
    }
    const row = &accounts.Account.table[account];
    if (row.hasLogin()) return self.startLogin(account);
    if (self.account_registry.loadError(account)) |err|
        return self.refuse(.{ .account_unloaded = .{ .account = account, .cause = err } });
    self.refuse(.{ .credential_missing = account });
}

fn currentUse(self: *Controller) Record.Event.Use {
    const account = self.choice.account.?;
    const model = self.choice.modelName() orelse
        return .{ .account = .{ .account = account, .step = self.stepOf(account) } };
    return .{ .model = .{ .account = account, .model = model } };
}

fn stepOf(self: *Controller, account: usize) Record.Event.Step {
    return if (self.account_registry.offersModel(account)) .select_model else .fetch_models;
}

fn signOut(self: *Controller, account: usize) !void {
    if (self.refuseBusy()) return;
    if (account >= query.account_count or !accounts.Account.table[account].hasLogin() or
        !self.account_registry.isAuthenticated(account)) return self.refuse(.unknown_target);
    try self.logoutAccount(account);
    try self.sync();
}

fn submitCallback(self: *Controller, callback: *const Command.Callback) !void {
    const sign_in = self.activeSignIn() orelse return self.refuse(.stale);
    if (sign_in.id != callback.operation) return self.refuse(.stale);
    if (self.paste_pending) return self.refuse(.busy);
    self.paste_pending = true;
    errdefer self.paste_pending = false;
    try self.account_registry.send(&.{ .paste = callback.line });
}

fn fetchModels(self: *Controller, account: usize) !void {
    if (self.refuseBusy()) return;
    if (account >= query.account_count) return self.refuse(.unknown_target);
    if (!self.account_registry.isAuthenticated(account)) return self.refuse(.signed_out);
    try self.account_registry.send(&.{ .fetch = account });
    const id = self.nextOperation();
    self.work = .{ .fetch = .{ .id = id, .account = account } };
    self.response.operation = id;
}

fn selectModel(self: *Controller, choice: *const Command.ModelChoice) !void {
    if (self.refuseBusy()) return;
    if (choice.account >= query.account_count) return self.refuse(.unknown_target);
    if (!self.account_registry.isAuthenticated(choice.account)) return self.refuse(.signed_out);
    const model = self.account_registry.findModel(choice.account, choice.model) orelse
        return self.refuse(.unknown_target);
    if (self.choice.model) |*active| {
        if (self.choice.isActive(choice.account) and active.eql(&model))
            return self.setNotice(&.{ .model_active = .{
                .account = choice.account,
                .model = active.name(),
            } });
    }
    self.choice.account = choice.account;
    self.choice.model = model;
    try self.recordEvent(&.{ .use_changed = self.currentUse() });
    try self.sync();
}

fn setEffort(self: *Controller, level: core.Provider.Effort) !void {
    if (self.refuseBusy()) return;
    if (self.choice.effort == level) return self.setNotice(&.{ .effort_active = level });
    self.choice.effort = level;
    try self.recordEvent(&.{ .effort_changed = level });
    try self.sync();
}

fn retry(self: *Controller) !void {
    if (self.refuseBusy()) return;
    const offer = self.offer orelse return self.refuse(.stale);
    const request = switch (offer) {
        .retry => |text| text,
        .removal => return self.refuse(.stale),
    };
    if (try self.refusePrerequisite()) return;
    const start = self.surface.transcript.entries().len;
    try self.surface.appendRetryNote();
    errdefer self.surface.transcript.truncate(start);
    try self.runTurn(&.{ .text = request, .start = start, .prompt = null });
}

fn removeCanceledTurn(self: *Controller, id: u64) !void {
    if (self.refuseBusy()) return;
    const offer = self.offer orelse return self.refuse(.stale);
    const last = self.turns.all().len - 1;
    if (offer != .removal or self.turns.all()[last].id != id) return self.refuse(.stale);
    try self.rewind(last);
}

fn rewindTo(self: *Controller, id: u64) !void {
    if (self.refuseBusy()) return;
    const index = self.turns.find(id) orelse return self.refuse(.unknown_target);
    if (self.turns.all()[index].prompt == null) return self.refuse(.unknown_target);
    try self.rewind(index);
    try self.sync();
}

fn rewind(self: *Controller, turn: usize) !void {
    try self.session.send(&.{ .rewind = turn });
    self.surface.rewind(self.turns.all()[turn..]);
    const line = self.turns.takeLine(turn);
    if (self.recovered) |previous| self.gpa.free(previous);
    self.recovered = line;
    self.response.recovered = line;
    self.turns.truncate(turn);
    self.dropOffer();
    self.conversation +%= 1;
}

fn startUserTurn(self: *Controller, text: []const u8) !void {
    const start = self.surface.transcript.entries().len;
    try self.surface.appendUser(text);
    try self.runTurn(&.{ .text = text, .start = start, .prompt = .{ .line = text } });
}

fn runTurn(self: *Controller, turn: *const TurnStart) !void {
    std.debug.assert(self.work == .idle);
    try self.refreshBranch();
    const id = self.nextOperation();
    try self.turns.begin(&.{ .id = id, .start = turn.start, .prompt = turn.prompt });
    errdefer self.turns.truncate(self.turns.all().len - 1);
    try self.session.send(&.{ .prompt = turn.text });
    self.dropOffer();
    self.surface.beginTurn();
    self.conversation +%= 1;
    self.work = .{ .turn = id };
    self.response.operation = id;
}

fn cancelWork(self: *Controller, id: u64) !void {
    if (self.work.view().operation() != id) return self.refuse(.stale);
    switch (self.work) {
        .idle => unreachable,
        .turn => {
            const turn = self.surface.activeTurn().?;
            if (turn.canceled) return;
            turn.canceled = true;
            try self.session.send(&.cancel);
        },
        .aside => |*aside| {
            if (aside.canceled) return;
            aside.canceled = true;
            try self.session.send(&.cancel);
        },
        .sign_in => |*sign_in| {
            if (sign_in.canceled) return;
            sign_in.canceled = true;
            try self.account_registry.send(&.cancel);
        },
        .fetch => |*fetch| {
            if (fetch.canceled) return;
            fetch.canceled = true;
            try self.account_registry.send(&.cancel);
        },
    }
}

fn applySessionEvent(self: *Controller, event: *const core.Session.Event) !void {
    if (event.* == .setup_dropped) return self.clients.release(event.setup_dropped);
    if (event.* == .usage) {
        const model = if (self.choice.model) |*model| model else null;
        if (billing.cost(&event.usage, model)) |amount| self.emit(&.{ .charge = amount });
    }
    switch (event.*) {
        .setup_dropped => unreachable,
        .tool_started => |*call| if (core.Tool.mutating(&tools.Registry.specs, call.name)) {
            self.turns.markMutated();
        },
        .aside_text => |text| {
            try self.activeResult().text.appendSlice(self.gpa, text);
            return self.changed();
        },
        .aside_reasoning => |reasoning| {
            const generating = self.generatingResult();
            generating.thinking = true;
            generating.received_bytes +|= reasoning.len;
            return self.changed();
        },
        .aside_attempt_failed => |*attempt| {
            const failed = try Record.dupeData(self.gpa, Record.Event.Attempt.from(attempt));
            const generating = self.generatingResult();
            Record.freeData(self.gpa, &generating.retry);
            generating.retry = failed;
            return self.changed();
        },
        .aside_ended => |*outcome| return self.endAside(outcome),
        .text_started,
        .text,
        .reasoning_started,
        .reasoning,
        .tool_call_started,
        .tool_call_arguments,
        .tool_result,
        .committed,
        .tail_discarded,
        .usage,
        .cost,
        .quota,
        .credits,
        .context,
        .model_served,
        .attempt_failed,
        .skill_loaded,
        .turn_ended,
        => {},
    }
    if (event.* == .turn_ended) {
        std.debug.assert(self.work == .turn);
        self.work = .idle;
        if (self.notice != null) self.clearNotice();
    }
    const outcome = try self.surface.apply(event, self.surfaceTime()) orelse return;
    try self.endTurn(&outcome);
}

fn activeAside(self: *Controller) *Work.Aside {
    return switch (self.work) {
        .aside => |*aside| aside,
        .idle, .turn, .sign_in, .fetch => unreachable,
    };
}

fn activeSignIn(self: *Controller) ?*Work.SignIn {
    return switch (self.work) {
        .sign_in => |*sign_in| sign_in,
        .idle, .turn, .aside, .fetch => null,
    };
}

fn activeFetch(self: *Controller) ?*Work.Fetch {
    return switch (self.work) {
        .fetch => |*fetch| fetch,
        .idle, .turn, .aside, .sign_in => null,
    };
}

fn activeResult(self: *Controller) *Result {
    const result = &self.result.?;
    std.debug.assert(result.id == self.activeAside().id);
    return result;
}

fn generatingResult(self: *Controller) *State.Result.Generating {
    return switch (self.activeResult().phase) {
        .generating => |*generating| generating,
        .complete, .incomplete => unreachable,
    };
}

fn changed(self: *Controller) void {
    self.revision +%= 1;
}

fn endTurn(self: *Controller, outcome: *const core.Session.Outcome) !void {
    try self.turns.end(self.surface.transcript.entries().len, &.{
        .outcome = outcome.*,
        .answer = self.surface.answer.items,
    });
    self.dropOffer();
    try self.refreshBranch();
    if (self.startup == .run) return;
    const turns = self.turns.all();
    switch (outcome.*) {
        .stopped, .exhausted => {},
        .canceled => if (turns[turns.len - 1].prompt != null) {
            self.offer = .removal;
        },
        .failed => |*failure| {
            try self.offerRetry(failure);
            if (failure.reason == .unauthorized) {
                const account = self.choice.account orelse return;
                if (try self.rejectCredential(account)) try self.recordEvent(&.{
                    .credential_reloaded = .{
                        .account = account,
                        .next = if (self.choice.model != null)
                            .retry_turn
                        else
                            .{ .step = self.stepOf(account) },
                    },
                });
            }
        },
    }
}

fn offerRetry(self: *Controller, failure: *const core.Provider.Failure) !void {
    const detailed = failure.message.len > 0;
    const request = try self.gpa.print(retry_request, .{
        failure.reason,
        if (detailed) "Details: " else "",
        failure.message,
        if (detailed) "\n" else "",
    });
    self.offer = .{ .retry = request };
}

fn rejectCredential(self: *Controller, account: usize) !bool {
    var maybe_removal_error: ?accounts.oauth.store.Error = null;
    const recovered = self.account_registry.invalidate(account) catch |err| switch (err) {
        error.AccountHasNoRefreshCredential => return false,
        error.OutOfMemory => return error.OutOfMemory,
        else => |removal_error| failure: {
            maybe_removal_error = removal_error;
            break :failure false;
        },
    };
    const active = self.choice.isActive(account);
    if (active) self.clients.close();
    if (recovered) {
        if (active) try self.sync();
    } else {
        if (maybe_removal_error) |removal_error| try self.recordEvent(&.{
            .credential_unremoved = .{ .account = account, .cause = @errorName(removal_error) },
        });
        if (active) {
            try self.handOff(account, .{ .rejected = true });
        } else try self.recordEvent(&.{ .signed_out = .{
            .account = account,
            .rejected = true,
            .next = .unchanged,
        } });
    }
    return recovered;
}

fn handOff(self: *Controller, account: usize, options: struct { rejected: bool }) !void {
    self.adopt(self.account_registry.firstAuthenticated());
    try self.sync();
    const next: Record.Event.SignedOut.Next = if (self.choice.account == null)
        .none
    else
        .{ .use = self.currentUse() };
    try self.recordEvent(&.{ .signed_out = .{
        .account = account,
        .rejected = options.rejected,
        .next = next,
    } });
    if (next == .none) self.emit(&.no_account);
}

fn adopt(self: *Controller, maybe_account: ?usize) void {
    self.choice.adopt(&self.account_registry, &self.saved.model_names, maybe_account);
}

fn applyAccountsEvent(self: *Controller, event: *const accounts.Registry.Event) !void {
    switch (event.*) {
        .paste_replayed, .paste_refused => self.paste_pending = false,
        .refused, .authorization, .browser_launch_failed, .login_ended, .fetch_ended => {},
    }
    switch (event.*) {
        .refused => unreachable,
        .authorization => |*authorization| try self.recordAuthorization(authorization),
        .browser_launch_failed => |account| try self.setNotice(&.{ .browser_unopened = account }),
        .paste_replayed => self.emit(&.paste_replayed),
        .paste_refused => |refusal| try self.reportPasteRefusal(refusal),
        .login_ended => |*ended| try self.finishLogin(ended),
        .fetch_ended => |*ended| try self.finishFetch(ended),
    }
}

fn recordAuthorization(
    self: *Controller,
    authorization: *const accounts.Registry.Event.Authorization,
) !void {
    const sign_in = self.activeSignIn() orelse return;
    if (sign_in.account != authorization.account) return;
    try self.surface.appendAuthorization(&.{
        .account = authorization.account,
        .url = authorization.url,
        .code = authorization.code,
    });
    sign_in.record_index = self.surface.transcript.entries().len - 1;
}

fn reportPasteRefusal(self: *Controller, refusal: accounts.Registry.Event.Paste) !void {
    const account = (self.activeSignIn() orelse return).account;
    switch (refusal) {
        .not_waiting => try self.setNotice(&.{ .callback_unexpected = account }),
        .not_a_redirect => try self.setNotice(&.{ .callback_invalid = account }),
        .replay_failed => |err| {
            switch (err) {
                error.ConnectionRefused => {
                    self.emit(&.paste_replayed);
                    return self.setNotice(&.{ .callback_received = account });
                },
                inline else => |cause| comptime core.error_set.requireMember(
                    accounts.oauth.login.NetworkError,
                    cause,
                ),
            }
            try self.setNotice(&.{ .callback_unreplayed = .{
                .account = account,
                .cause = @errorName(err),
            } });
        },
    }
}

fn startLogin(self: *Controller, account: usize) !void {
    std.debug.assert(self.work == .idle);
    try self.account_registry.send(&.{ .login = account });
    const id = self.nextOperation();
    self.work = .{ .sign_in = .{
        .id = id,
        .account = account,
        .callback = accounts.Registry.takesPaste(&accounts.Account.table[account]),
    } };
    self.response.operation = id;
}

fn finishLogin(self: *Controller, ended: *const accounts.Registry.Event.LoginEnd) !void {
    const sign_in = (self.activeSignIn() orelse return).*;
    if (sign_in.account != ended.account) return;
    self.work = .idle;
    self.clearNotice();
    const account = sign_in.account;
    const committed = ended.outcome catch |login_error| {
        const failure: Record.Event = .{
            .sign_in_failed = .from(account, login_error),
        };
        if (sign_in.record_index) |index| {
            try self.surface.replaceEvent(index, &failure);
        } else try self.setNotice(&failure);
        return self.emit(&.{ .sign_in_ended = .{
            .operation = sign_in.id,
            .account = account,
            .signed_in = false,
        } });
    };
    self.adopt(account);
    try self.sync();
    const signed_in: Record.Event = .{ .signed_in = .{
        .account = account,
        .model = self.choice.modelName(),
    } };
    if (sign_in.record_index) |index| {
        try self.surface.replaceEvent(index, &signed_in);
    } else try self.recordEvent(&signed_in);
    switch (committed) {
        .saved => {},
        .memory_only => |*failure| try self.recordEvent(&.{
            .credentials_unsaved = .from(account, failure),
        }),
    }
    self.emit(&.{ .sign_in_ended = .{
        .operation = sign_in.id,
        .account = account,
        .signed_in = true,
    } });
}

fn endFetch(self: *Controller, fetch: *const Work.Fetch, outcome: query.FetchOutcome) void {
    self.fetch_end = .{ .operation = fetch.id, .account = fetch.account, .outcome = outcome };
    self.emit(&.{ .fetch_ended = self.fetch_end.? });
}

fn finishFetch(self: *Controller, ended: *const accounts.Registry.Event.FetchEnd) !void {
    const fetch = (self.activeFetch() orelse return).*;
    if (fetch.account != ended.account) return;
    self.work = .idle;
    if (self.choice.isActive(fetch.account)) {
        self.clients.close();
        try self.sync();
    }
    if (fetch.canceled) return self.endFetch(&fetch, .canceled);
    const refresh = &ended.refresh;
    if (refresh.models_error) |err| std.debug.assert(err != error.Canceled);
    if (Record.Event.fromRefresh(fetch.account, refresh)) |report| try self.recordEvent(&report);
    self.endFetch(&fetch, if (refresh.models_error) |err| .{ .failed = err } else .listed);
    const err = refresh.models_error orelse return;
    if (err != error.TokenGrantRejected and err != error.ModelListUnauthorized) return;
    if (try self.rejectCredential(fetch.account)) try self.recordEvent(&.{ .credential_reloaded = .{
        .account = fetch.account,
        .next = .{ .step = self.stepOf(fetch.account) },
    } });
}

fn logoutAccount(self: *Controller, account: usize) !void {
    const was_active = self.choice.isActive(account);
    if (was_active) self.clients.close();
    self.account_registry.logout(account) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return self.setNotice(&.{ .sign_out_failed = @errorName(err) });
    };
    if (!was_active) return self.recordEvent(&.{ .signed_out = .{
        .account = account,
        .rejected = false,
        .next = .unchanged,
    } });
    try self.handOff(account, .{ .rejected = false });
}

fn prepareGist(self: *Controller, instruction: []const u8) !void {
    if (self.refuseBusy()) return;
    if (try self.refusePrerequisite()) return;
    if (self.turns.all().len == 0) return self.refuse(.no_conversation);
    const owned: ?[]u8 = if (instruction.len == 0)
        null
    else
        try self.gpa.print(gist_instruction, .{instruction});
    defer if (owned) |text| self.gpa.free(text);
    try self.session.send(&.{ .aside = .{
        .system = gist_system,
        .text = owned orelse gist_request,
    } });
    const id = self.nextOperation();
    self.work = .{ .aside = .{ .id = id } };
    self.dropResult();
    self.result = .{
        .id = id,
        .conversation = self.conversation,
        .phase = .{ .generating = .{ .started_ms = self.nowMs() } },
    };
    self.response.operation = id;
    self.changed();
}

fn endAside(self: *Controller, outcome: *const core.Session.Outcome) !void {
    const canceled = self.activeAside().canceled;
    const result = self.activeResult();
    self.work = .idle;
    self.changed();
    if (canceled) return self.dropResult();
    const phase: State.Result.Phase = switch (outcome.*) {
        .stopped => |reason| switch (reason) {
            .complete => if (Gists.parse(result.text.items) == null)
                .{ .incomplete = .not_text }
            else
                .complete,
            .truncated => .{ .incomplete = .truncated },
        },
        .failed => |*failure| .{ .incomplete = .{ .failed = .from(failure) } },
        .canceled, .exhausted => unreachable,
    };
    const owned = try Record.dupeData(self.gpa, phase);
    Record.freeData(self.gpa, &result.phase);
    result.phase = owned;
}

fn saveResult(self: *Controller, id: u64) !void {
    if (self.refuseBusy()) return;
    const text = self.completeResult(id) orelse return self.refuse(.stale);
    self.gists.save(self.io, text) catch |err| return self.refuseGist(null, err);
    self.dropResult();
}

fn applyResult(self: *Controller, id: u64) !void {
    if (self.refuseBusy()) return;
    const result_text = self.completeResult(id) orelse return self.refuse(.stale);
    if (try self.refusePrerequisite()) return;
    self.gists.save(self.io, result_text) catch |err| return self.refuseGist(null, err);
    const text = try self.gpa.dupe(u8, result_text);
    defer self.gpa.free(text);
    try self.applyText(text, &(Gists.parse(text) orelse unreachable));
}

fn completeResult(self: *const Controller, id: u64) ?[]const u8 {
    const result = if (self.result) |*result| result else return null;
    const current = result.id == id and result.conversation == self.conversation;
    if (!current or result.phase != .complete) return null;
    return result.text.items;
}

fn applyGist(self: *Controller, id: *const Gists.Id) !void {
    if (self.refuseBusy()) return;
    if (try self.refusePrerequisite()) return;
    const text = self.gists.read(self.gpa, self.io, id) catch |err| return self.refuseGist(id, err);
    defer self.gpa.free(text);
    const parsed = Gists.parse(text) orelse {
        const path = try self.gists.path(self.gpa, id);
        self.failed_path = path;
        return self.refuse(.{ .gist_invalid = path });
    };
    try self.applyText(text, &parsed);
}

fn applyText(self: *Controller, text: []const u8, parsed: *const Gists.Parsed) !void {
    const message = try self.gpa.print(gist_message, .{text});
    defer self.gpa.free(message);
    try self.session.send(&.clear);
    self.dropResult();
    self.clearConversation();
    try self.surface.appendGistNote(parsed.title);
    if (parsed.body.len > 0) try self.surface.appendUser(parsed.body);
    try self.runTurn(&.{ .text = message, .start = 0, .prompt = .{ .gist = parsed.title } });
}

fn deleteGist(self: *Controller, id: *const Gists.Id) !void {
    if (self.refuseBusy()) return;
    self.gists.delete(self.io, id) catch |err| return self.refuseGist(id, err);
}

fn refuseGist(
    self: *Controller,
    maybe_id: ?*const Gists.Id,
    err: Gists.Error,
) error{ OutOfMemory, Canceled }!void {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {},
    }
    const path = if (maybe_id) |id|
        try self.gists.path(self.gpa, id)
    else
        try self.gpa.dupe(u8, self.gists.directory);
    self.failed_path = path;
    self.refuse(.{ .gist_failed = .{ .path = path, .cause = err } });
}

fn discardResult(self: *Controller, id: u64) !void {
    if (self.refuseBusy()) return;
    const result = self.result orelse return self.refuse(.stale);
    if (result.id != id) return self.refuse(.stale);
    self.dropResult();
}

fn dropResult(self: *Controller) void {
    const result = if (self.result) |*result| result else return;
    result.deinit(self.gpa);
    self.result = null;
    self.changed();
}

fn setNotice(self: *Controller, event: *const Record.Event) !void {
    const owned = try event.dupe(self.gpa);
    if (self.notice) |*previous| previous.deinit(self.gpa);
    self.notice = owned;
    self.notice_id +%= 1;
    self.changed();
}

fn clearNotice(self: *Controller) void {
    if (self.notice) |*notice| notice.deinit(self.gpa);
    self.notice = null;
    self.notice_id +%= 1;
    self.changed();
}

fn recordReports(self: *Controller, reports: *const Reports) !void {
    for (reports.events()) |*event| try self.recordEvent(event);
}

fn recordEvent(self: *Controller, event: *const Record.Event) !void {
    try self.surface.appendEvent(event);
}

fn emit(self: *Controller, event: *const Event) void {
    self.publish();
    self.sink.emit(self.io, event);
}
fn publish(self: *Controller) void {
    if (!self.ready) return;
    const mark = self.currentMark();
    const unchanged = if (self.published) |published| std.meta.eql(mark, published) else false;
    self.published = mark;
    const value = self.currentState();
    self.surface.flush(self.sink, if (unchanged) null else &value);
}
fn currentMark(self: *const Controller) Mark {
    return .{ .revision = self.revision, .work = self.work.view(), .offer = self.currentOffer() };
}
fn currentOffer(self: *const Controller) State.Offer {
    const offer = self.offer orelse return .none;
    return switch (offer) {
        .retry => .retry,
        .removal => removal: {
            const turns = self.turns.all();
            const last = turns[turns.len - 1];
            const returns_line = if (last.prompt) |prompt| prompt == .line else false;
            break :removal .{ .removal = .{
                .turn = last.id,
                .mutated = last.mutated,
                .returns_line = returns_line,
            } };
        },
    };
}
fn currentState(self: *const Controller) State {
    return .{
        .work = self.work.view(),
        .offer = self.currentOffer(),
        .notice = self.notice,
        .notice_id = self.notice_id,
        .result = if (self.result) |*result| result.view() else null,
        .choice = self.choice,
        .branch = self.branch(),
    };
}
fn nowMs(self: *Controller) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}
fn surfaceTime(self: *Controller) Surface.Time {
    return .{
        .awake_ms = self.nowMs(),
        .boot_ms = std.Io.Timestamp.now(self.io, .boot).toMilliseconds(),
    };
}
fn execute(self: *Controller, value: *const Command) !void {
    self.releaseResponse();
    errdefer if (self.response.refusal == null) self.refuse(.unavailable);
    if (self.startup_refusal != null) return self.refuse(.unavailable);
    if (self.startup == .run) {
        switch (value.*) {
            .cancel => |id| try self.cancelWork(id),
            .snapshot => try self.sendSnapshot(),
            .send_message,
            .invoke_skill,
            .new_conversation,
            .select_account,
            .sign_out,
            .submit_callback,
            .fetch_models,
            .select_model,
            .set_effort,
            .retry,
            .remove_canceled_turn,
            .rewind,
            .prepare_gist,
            .save_result,
            .apply_result,
            .discard_result,
            .apply_gist,
            .delete_gist,
            .dismiss_offer,
            .dismiss_notice,
            .refresh_project,
            => self.refuse(.unavailable),
        }
        return;
    }
    switch (value.*) {
        .refresh_project => return self.refreshBranch(),
        .snapshot => return self.sendSnapshot(),
        .dismiss_notice => |id| if (id != self.notice_id) return self.refuse(.stale),
        .send_message,
        .invoke_skill,
        .new_conversation,
        .select_account,
        .sign_out,
        .submit_callback,
        .fetch_models,
        .select_model,
        .set_effort,
        .retry,
        .remove_canceled_turn,
        .rewind,
        .prepare_gist,
        .save_result,
        .apply_result,
        .discard_result,
        .apply_gist,
        .delete_gist,
        .cancel,
        .dismiss_offer,
        => {},
    }
    if (self.notice != null) self.clearNotice();
    switch (value.*) {
        .snapshot, .refresh_project => unreachable,
        .dismiss_offer => self.dropOffer(),
        .dismiss_notice => {},
        .send_message => |text| try self.sendMessage(text),
        .invoke_skill => |*skill| try self.invokeSkill(skill),
        .new_conversation => try self.newConversation(),
        .select_account => |account| try self.selectAccount(account),
        .sign_out => |account| try self.signOut(account),
        .submit_callback => |*callback| try self.submitCallback(callback),
        .fetch_models => |account| try self.fetchModels(account),
        .select_model => |*choice| try self.selectModel(choice),
        .set_effort => |level| try self.setEffort(level),
        .retry => try self.retry(),
        .remove_canceled_turn => |id| try self.removeCanceledTurn(id),
        .rewind => |id| try self.rewindTo(id),
        .prepare_gist => |instruction| try self.prepareGist(instruction),
        .save_result => |id| try self.saveResult(id),
        .apply_result => |id| try self.applyResult(id),
        .discard_result => |id| try self.discardResult(id),
        .apply_gist => |*id| try self.applyGist(id),
        .delete_gist => |*id| try self.deleteGist(id),
        .cancel => |id| try self.cancelWork(id),
    }
}

fn sendSnapshot(self: *Controller) !void {
    self.publish();
    const entries = self.surface.transcript.entries();
    const records = try self.gpa.alloc(Record, entries.len);
    defer self.gpa.free(records);
    for (entries, records) |*entry, *record| record.* = entry.record;
    const value: Snapshot = .{
        .records = records,
        .live = self.surface.live(),
        .statistics = self.surface.statistics,
        .state = self.currentState(),
        .settings = self.settings,
        .working_directory = self.working_directory,
        .home_directory = self.home_directory,
    };
    self.sink.emit(self.io, &.{ .snapshot = value });
}

test "controllers own frontend text and compose it with shared instructions and reference facts" {
    const gpa = std.testing.allocator;
    const frontend_instructions = try gpa.dupe(u8, "Use the desktop window.");
    defer gpa.free(frontend_instructions);
    const frontend_reference = try gpa.dupe(u8, "## Client controls\n\nUse the toolbar.");
    defer gpa.free(frontend_reference);
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .frontend = .{
            .instructions = frontend_instructions,
            .reference = frontend_reference,
        },
        .replies = &.{
            .{ .body = "data: {\"type\":\"response.output_item.done\"," ++
                "\"item\":{\"id\":\"fc_1\"," ++
                "\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call_1\"," ++
                "\"name\":\"describe_drinky\",\"arguments\":\"{}\"}}\n\n" ++
                "data: {\"type\":\"response.completed\"," ++
                "\"response\":{\"status\":\"completed\"}}\n\n" },
            .{ .body = providers.testing.reply_stream },
        },
    });
    defer rig.deinit();
    @memset(frontend_instructions, 'x');
    @memset(frontend_reference, 'x');
    const instructions = rig.controller.documents().system_prompt;
    try testing.expectContains(instructions, "You are a coding assistant.");
    try std.testing.expectEqual(@as(?usize, null), std.mem.find(u8, instructions, "terminal"));
    try testing.expectContains(instructions, "## Frontend\n\nUse the desktop window.");
    _ = rig.send(&.{ .send_message = "Describe the harness." });
    try rig.expectTurn(.stopped);
    const snapshot = try rig.snapshot();
    defer snapshot.deinit(gpa);
    const document = for (snapshot.records) |*record| {
        if (record.content == .tool_result) break record.content.tool_result.output.content;
    } else return error.TestExpectedDocument;
    try testing.expectContains(document, "## Config file");
    try testing.expectContains(document, "## Discovery");
    try testing.expectContains(document, "## Client controls\n\nUse the toolbar.");
    for ([_][]const u8{ "/model", "/effort", "/verbose", "Ctrl+D", "purple" }) |text|
        try std.testing.expect(std.mem.find(u8, document, text) == null);
}

test "session startup exposes validated settings and acknowledges unchanged project refreshes" {
    var rig: testing.Rig = undefined;
    try rig.init(
        &.{ .config = "{\"interface\":{\"verbose\":true,\"mcp_access\":true,\"window_pages\":64," ++
            "\"gauge_percent_warning\":10,\"gauge_percent_error\":20,\"animation\":\"sweep\"}}" },
    );
    defer rig.deinit();
    const initial = try rig.snapshot();
    defer initial.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), initial.records.len);
    try std.testing.expect(initial.settings.verbose);
    try std.testing.expect(initial.settings.mcp_access);
    try std.testing.expectEqual(@as(usize, 64), initial.settings.window_pages);
    try std.testing.expectEqual(@as(f64, 10), initial.settings.gauge.percent_warning);
    try std.testing.expectEqual(Settings.Animation.sweep, initial.settings.animation);
    try std.testing.expectEqualStrings("main", initial.state.branch.?);
    for (0..2) |_| try std.testing.expect(rig.send(&.refresh_project).accepted());
    try rig.tree.write(".git/HEAD", "ref: refs/heads/changed\n");
    _ = rig.send(&.refresh_project);
    const snapshot = try rig.snapshot();
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("changed", snapshot.state.branch.?);
}

test "ordered snapshots include the streamed text of a running turn" {
    const prefix = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\"" ++
        ",\"delta\":\"partial\"}\n\n";
    var transport: testing.StreamTransport = .{
        .prefix = prefix,
        .tail = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\"" ++
            ",\"delta\":\" answer\"}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"" ++
            "m1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"" ++
            "type\":\"output_text\",\"text\":\"partial answer\"}]}}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
    };
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .transport = transport.transport() });
    defer rig.deinit();
    defer transport.released.set(std.testing.io);
    const initial = try rig.snapshot();
    initial.deinit(std.testing.allocator);
    _ = rig.send(&.{ .send_message = "Task." });
    try transport.reached.wait(std.testing.io);
    const streamed = try rig.snapshot();
    defer streamed.deinit(std.testing.allocator);
    try std.testing.expectEqual(.turn, std.meta.activeTag(streamed.state.work));
    try testing.expectUsers(streamed.records, &.{"Task."});
    try std.testing.expectEqualStrings("partial", streamed.records[1].content.model.items);
    transport.released.set(std.testing.io);
    try rig.expectTurn(.stopped);
    const ended = try rig.snapshot();
    defer ended.deinit(std.testing.allocator);
    try std.testing.expectEqual(.idle, std.meta.activeTag(ended.state.work));
    try std.testing.expectEqualStrings("partial answer", ended.records[1].content.model.items);
}

const sample_gist: Gists.Id = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab };

fn expectRefusal(response: Response, expected: Refusal) !void {
    const refusal = response.refusal orelse return error.TestExpectedRefusal;
    try std.testing.expectEqualDeep(expected, refusal);
}

test "native sign-in uses the supplied browser and loopback and ends before another operation" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .authenticated = false });
    defer rig.deinit();
    const lost = try rig.eventOf(.no_account);
    lost.deinit(std.testing.allocator);
    const started = rig.send(&.{ .select_account = accounts.testing.anthropic_plan });
    try std.testing.expect(started.accepted());
    const operation = started.operation.?;
    const signing_in = try rig.snapshot();
    defer signing_in.deinit(std.testing.allocator);
    try std.testing.expectEqual(.sign_in, std.meta.activeTag(signing_in.state.work));
    const sign_in = signing_in.state.work.sign_in;
    try std.testing.expectEqual(operation, sign_in.operation);
    try std.testing.expectEqual(accounts.testing.anthropic_plan, sign_in.account);
    try std.testing.expect(sign_in.callback);
    try expectRefusal(rig.send(&.{ .send_message = "Task." }), .busy);
    try expectRefusal(rig.send(&.{ .cancel = operation + 1 }), .stale);
    try std.testing.expect(rig.send(&.{ .cancel = operation }).accepted());
    try std.testing.expect(rig.send(&.{ .cancel = operation }).accepted());
    const ended = try rig.eventOf(.sign_in_ended);
    try std.testing.expectEqual(operation, ended.sign_in_ended.operation);
    try std.testing.expect(!ended.sign_in_ended.signed_in);
    try std.testing.expectEqual(@as(?u16, null), rig.loopback.listening());
    try expectRefusal(rig.send(&.{ .cancel = operation }), .stale);
}

test "the authorization record keeps its typed content and its id through the sign-in end" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .authenticated = false });
    defer rig.deinit();
    const initial = try rig.snapshot();
    initial.deinit(std.testing.allocator);
    _ = rig.send(&.{ .select_account = accounts.testing.anthropic_plan });
    const callback = try rig.callbackUrl();
    defer std.testing.allocator.free(callback);
    const shown = try rig.snapshot();
    defer shown.deinit(std.testing.allocator);
    const record = for (shown.records) |*record| {
        if (record.content == .authorization) break record;
    } else return error.TestExpectedAuthorization;
    const authorization = record.content.authorization;
    try std.testing.expectEqual(accounts.testing.anthropic_plan, authorization.account);
    try testing.expectContains(authorization.url, "https://claude.ai/oauth/authorize?");
    try std.testing.expect(authorization.code == null);
    _ = rig.send(&.{ .cancel = shown.state.work.operation().? });
    const idle = try rig.state(.idle);
    idle.deinit(std.testing.allocator);
    const ended = try rig.snapshot();
    defer ended.deinit(std.testing.allocator);
    const replaced = for (ended.records) |*entry| {
        if (entry.id == record.id) break entry;
    } else return error.TestExpectedRecord;
    try std.testing.expectEqualDeep(Record.Event{ .sign_in_failed = .{
        .account = accounts.testing.anthropic_plan,
        .reason = .canceled,
        .cause = "Canceled",
    } }, replaced.content.event);
}

test "a completed turn drops an earlier status notice from snapshots" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{.{ .body = providers.testing.reply_stream }} });
    defer rig.deinit();
    const initial = try rig.snapshot();
    defer initial.deinit(std.testing.allocator);
    try std.testing.expect(rig.send(&.{ .set_effort = initial.state.choice.effort })
        .accepted());
    const noticed = try rig.snapshot();
    defer noticed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Record.Event{ .effort_active = .high }, noticed.state.notice.?);
    _ = rig.send(&.{ .send_message = "Task." });
    try rig.expectTurn(.stopped);
    const ended = try rig.snapshot();
    defer ended.deinit(std.testing.allocator);
    try std.testing.expect(ended.state.notice == null);
}

test "state-dependent refusals name their reason and change nothing" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    const initial = try rig.snapshot();
    defer initial.deinit(std.testing.allocator);
    try expectRefusal(rig.send(&.{ .prepare_gist = "" }), .no_conversation);
    try expectRefusal(rig.send(&.{ .invoke_skill = .{
        .name = "missing",
        .arguments = "",
        .line = "/skill:missing",
    } }), .unknown_target);
    try expectRefusal(rig.send(&.{ .rewind = 1 }), .unknown_target);
    try expectRefusal(rig.send(&.retry), .stale);
    try expectRefusal(rig.send(&.{ .remove_canceled_turn = 1 }), .stale);
    try expectRefusal(rig.send(&.{ .save_result = 1 }), .stale);
    try expectRefusal(rig.send(&.{ .apply_result = 1 }), .stale);
    try expectRefusal(rig.send(&.{ .discard_result = 1 }), .stale);
    try expectRefusal(rig.send(&.{ .cancel = 1 }), .stale);
    try expectRefusal(
        rig.send(&.{ .sign_out = accounts.testing.openai_api_key }),
        .unknown_target,
    );
    try expectRefusal(rig.send(&.{ .select_model = .{
        .account = accounts.testing.openai_api_key,
        .model = "unknown",
    } }), .unknown_target);
    try expectRefusal(rig.send(&.{ .select_model = .{
        .account = accounts.testing.openai_plan,
        .model = "gpt-5.6-sol",
    } }), .signed_out);
    try expectRefusal(
        rig.send(&.{ .fetch_models = accounts.testing.openai_plan }),
        .signed_out,
    );
    try expectRefusal(
        rig.send(&.{ .select_account = accounts.testing.xai_api_key }),
        .{ .credential_missing = accounts.testing.xai_api_key },
    );
    const unchanged = try rig.snapshot();
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expect(initial.state.choice.eql(&unchanged.state.choice));
    try std.testing.expectEqual(@as(usize, 0), unchanged.records.len);
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "an account that failed to load refuses its selection and names the account and the error" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .variables = &.{
        .{ "GOOGLE_APPLICATION_CREDENTIALS", "/missing/key.json" },
        .{ "GOOGLE_CLOUD_LOCATION", "eu" },
    } });
    defer rig.deinit();
    try expectRefusal(
        rig.send(&.{ .select_account = accounts.testing.google_cloud_key }),
        .{ .account_unloaded = .{
            .account = accounts.testing.google_cloud_key,
            .cause = error.FileNotFound,
        } },
    );
}

test "model and effort changes during a turn are refused as busy and keep the choice" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .stall = &stall },
        .{ .body = providers.testing.reply_stream },
    } });
    defer rig.deinit();
    const initial = try rig.snapshot();
    defer initial.deinit(std.testing.allocator);
    const started = rig.send(&.{ .send_message = "Task." });
    try stall.reached.wait(std.testing.io);
    try expectRefusal(rig.send(&.{ .set_effort = .low }), .busy);
    try expectRefusal(rig.send(&.{ .select_model = .{
        .account = accounts.testing.openai_api_key,
        .model = "gpt-5.6-sol",
    } }), .busy);
    try expectRefusal(rig.send(&.{ .send_message = "More." }), .busy);
    const current = try rig.snapshot();
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqual(.turn, std.meta.activeTag(current.state.work));
    try std.testing.expect(initial.state.choice.eql(&current.state.choice));
    try std.testing.expect(rig.send(&.{ .cancel = started.operation.? }).accepted());
    try expectRefusal(rig.send(&.{ .set_effort = .low }), .busy);
    try rig.expectTurn(.canceled);
    try std.testing.expect(rig.send(&.{ .send_message = "Next task." }).accepted());
    try rig.expectTurn(.stopped);
    const ended = try rig.snapshot();
    defer ended.deinit(std.testing.allocator);
    try std.testing.expect(initial.state.choice.eql(&ended.state.choice));
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
}

test "unchanged selections are accepted with a notice and change nothing" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    const initial = try rig.snapshot();
    initial.deinit(std.testing.allocator);
    const cases = [_]struct { command: Command, notice: Record.Event }{
        .{ .command = .{ .set_effort = .high }, .notice = .{ .effort_active = .high } },
        .{
            .command = .{ .select_model = .{
                .account = accounts.testing.openai_api_key,
                .model = "gpt-5.6-sol",
            } },
            .notice = .{ .model_active = .{
                .account = accounts.testing.openai_api_key,
                .model = "gpt-5.6-sol",
            } },
        },
        .{
            .command = .{ .select_account = accounts.testing.openai_api_key },
            .notice = .{ .account_active = accounts.testing.openai_api_key },
        },
    };
    for (cases) |case| {
        try std.testing.expect(rig.send(&case.command).accepted());
        const current = try rig.snapshot();
        defer current.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(case.notice, current.state.notice.?);
        try std.testing.expectEqual(@as(usize, 0), current.records.len);
    }
}

test "model prerequisites refuse skills, gists, and retry offers" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "XAI_API_KEY", "xai-key" }},
        .files = &.{.{
            ".agents/skills/demo/SKILL.md",
            "---\nname: demo\ndescription: Test skill.\n---\nFollow the skill.\n",
        }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .status = .bad_request, .body = "{}" },
        },
    });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "Task." });
    try rig.expectTurn(.stopped);
    _ = rig.send(&.{ .send_message = "Task." });
    try rig.expectTurn(.failed);
    const selection = rig.send(&.{ .select_account = accounts.testing.xai_api_key });
    try std.testing.expect(selection.accepted());
    const selected = try rig.snapshot();
    defer selected.deinit(std.testing.allocator);
    try std.testing.expect(selected.state.choice.model == null);
    try std.testing.expect(selected.state.offer == .retry);
    try expectRefusal(rig.send(&.retry), .no_model);
    try expectRefusal(rig.send(&.{ .invoke_skill = .{
        .name = "demo",
        .arguments = "task",
        .line = "/skill:demo task",
    } }), .no_model);
    try expectRefusal(rig.send(&.{ .prepare_gist = "" }), .no_model);
    try expectRefusal(rig.send(&.{ .apply_gist = sample_gist }), .no_model);
    try expectRefusal(rig.send(&.{ .send_message = "Another task." }), .no_model);
    const unchanged = try rig.snapshot();
    defer unchanged.deinit(std.testing.allocator);
    try testing.expectUsers(unchanged.records, &.{ "Task.", "Task." });
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
}

test "a run refuses an empty prompt at its start, then refuses a snapshot, and sends no request" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .startup = .{ .run = .{
        .model = "openai-api-key/gpt-5.6-sol",
        .effort = .high,
        .prompt = "",
    } } });
    defer rig.deinit();
    const refused = try rig.next();
    defer refused.deinit(std.testing.allocator);
    try std.testing.expectEqual(.prompt_missing, refused.startup_refused);
    try std.testing.expect(!rig.send(&.snapshot).accepted());
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "a run accepts only a cancel and a snapshot" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .startup = .{ .run = .{
            .model = "openai-api-key/gpt-5.6-sol",
            .effort = .high,
            .prompt = "Task.",
        } },
        .replies = &.{.{ .stall = &stall }},
    });
    defer rig.deinit();
    try stall.reached.wait(std.testing.io);
    const running = try rig.snapshot();
    defer running.deinit(std.testing.allocator);
    try expectRefusal(rig.send(&.{ .send_message = "More." }), .unavailable);
    try expectRefusal(
        rig.send(&.{ .select_account = accounts.testing.openai_plan }),
        .unavailable,
    );
    try std.testing.expect(rig.send(&.{ .cancel = running.state.work.operation().? }).accepted());
    try rig.expectTurn(.canceled);
    try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
}

test "the state reaches the client only when it changes" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{.{ .body = providers.testing.replyStream("One two three.") }} });
    defer rig.deinit();
    const initial = try rig.snapshot();
    initial.deinit(std.testing.allocator);
    try std.testing.expect(rig.send(&.refresh_project).accepted());
    try std.testing.expectEqual(@as(usize, 0), rig.events.items.len - rig.taken);
    try std.testing.expect(rig.send(&.new_conversation).accepted());
    for (rig.events.items[rig.taken..]) |*event| try std.testing.expect(event.* != .state);
    rig.skip();
    _ = rig.send(&.{ .send_message = "Task." });
    var works: [2]std.meta.Tag(State.Work) = undefined;
    var count: usize = 0;
    var texts: usize = 0;
    for (0..4096) |_| {
        const event = try rig.next();
        defer event.deinit(std.testing.allocator);
        if (event == .turn_ended) break;
        if (event == .record_text or event == .append_record) texts += 1;
        if (event != .state) continue;
        try std.testing.expect(count < works.len);
        works[count] = std.meta.activeTag(event.state.work);
        count += 1;
    } else return error.TestExpectedEnd;
    try std.testing.expect(texts > 0);
    try std.testing.expectEqualSlices(
        std.meta.Tag(State.Work),
        &.{ .turn, .idle },
        works[0..count],
    );
}

test "a result state carries the text that grows until the result completes" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.replyStream("Resume the task.\\nBody.") },
    } });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "hello" });
    try rig.expectTurn(.stopped);
    rig.skip();
    const prepared = rig.send(&.{ .prepare_gist = "" });
    const id = prepared.operation.?;
    const shown = try rig.state(.aside);
    defer shown.deinit(std.testing.allocator);
    try std.testing.expectEqual(id, shown.result.?.id);
    try std.testing.expect(shown.result.?.phase == .generating);
    var shown_length: usize = 0;
    for (0..4096) |_| {
        const event = try rig.next();
        defer event.deinit(std.testing.allocator);
        if (event != .state) continue;
        const result = event.state.result.?;
        try std.testing.expectEqual(id, result.id);
        try std.testing.expect(result.text.len >= shown_length);
        try std.testing.expect(std.mem.startsWith(u8, "Resume the task.\nBody.", result.text));
        shown_length = result.text.len;
        if (event.state.work == .idle) break;
    } else return error.TestExpectedEnd;
    const reading = try rig.snapshot();
    defer reading.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Resume the task.\nBody.", reading.state.result.?.text);
    try std.testing.expect(reading.state.result.?.phase == .complete);
    try std.testing.expect(rig.send(&.{ .discard_result = id }).accepted());
    const discarded = try rig.snapshot();
    defer discarded.deinit(std.testing.allocator);
    try std.testing.expect(discarded.state.result == null);
}

test "a new turn publishes no previous retry or removal offer" {
    const cases = [_]struct { canceled: bool, retry: bool }{
        .{ .canceled = false, .retry = false },
        .{ .canceled = false, .retry = true },
        .{ .canceled = true, .retry = false },
    };
    for (cases) |case| {
        var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
        var rig: testing.Rig = undefined;
        try rig.init(&.{ .replies = &.{
            if (case.canceled) .{ .stall = &stall } else .{ .status = .bad_request },
            .{ .body = providers.testing.reply_stream },
        } });
        defer rig.deinit();
        const first = rig.send(&.{ .send_message = "First task." });
        if (case.canceled) {
            try stall.reached.wait(std.testing.io);
            _ = rig.send(&.{ .cancel = first.operation.? });
        }
        try rig.expectTurn(if (case.canceled) .canceled else .failed);
        const offered = try rig.snapshot();
        defer offered.deinit(std.testing.allocator);
        try std.testing.expectEqual(
            if (case.canceled) State.Offer.removal else .retry,
            std.meta.activeTag(offered.state.offer),
        );
        const next: Command = if (case.retry) .retry else .{ .send_message = "Next task." };
        try std.testing.expect(rig.send(&next).accepted());
        const active = try rig.state(.turn);
        defer active.deinit(std.testing.allocator);
        try std.testing.expect(active.offer == .none);
        try rig.expectTurn(.stopped);
        if (case.retry) try testing.expectContains(
            rig.transport.requests.items[1],
            "Continue from the last committed checkpoint.",
        );
    }
}

test "a notice dismissal keeps the removal offer, and a removal recovers the line" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{.{ .stall = &stall }} });
    defer rig.deinit();
    const initial = try rig.snapshot();
    initial.deinit(std.testing.allocator);
    const sent = rig.send(&.{ .send_message = "Task." });
    try std.testing.expect(sent.recovered == null);
    try stall.reached.wait(std.testing.io);
    _ = rig.send(&.{ .cancel = sent.operation.? });
    try rig.expectTurn(.canceled);
    _ = rig.send(&.{ .set_effort = .high });
    const noticed = try rig.snapshot();
    defer noticed.deinit(std.testing.allocator);
    const offer = noticed.state.offer.removal;
    try std.testing.expect(!offer.mutated);
    try expectRefusal(
        rig.send(&.{ .dismiss_notice = noticed.state.notice_id - 1 }),
        .stale,
    );
    const kept = try rig.snapshot();
    defer kept.deinit(std.testing.allocator);
    try std.testing.expect(kept.state.notice != null);
    try std.testing.expect(rig.send(&.{ .dismiss_notice = kept.state.notice_id }).accepted());
    const dismissed = try rig.snapshot();
    defer dismissed.deinit(std.testing.allocator);
    try std.testing.expect(dismissed.state.notice == null);
    try std.testing.expectEqual(offer, dismissed.state.offer.removal);
    try expectRefusal(rig.send(&.{ .remove_canceled_turn = offer.turn + 1 }), .stale);
    const removed = rig.send(&.{ .remove_canceled_turn = offer.turn });
    try std.testing.expect(removed.accepted());
    try std.testing.expectEqualStrings("Task.", removed.recovered.?);
    const empty = try rig.snapshot();
    defer empty.deinit(std.testing.allocator);
    try testing.expectUsers(empty.records, &.{});
    try std.testing.expect(empty.state.offer == .none);
}

test "turn facts mark mutating work, and a rewind applies at once through a stable id" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = testing.write_call_stream },
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.reply_stream },
    } });
    defer rig.deinit();
    for ([_][]const u8{ "First task.", "Second task." }) |line| {
        _ = rig.send(&.{ .send_message = line });
        try rig.expectTurn(.stopped);
    }
    const turns = rig.controller.listTurns();
    try std.testing.expectEqual(@as(usize, 2), turns.len);
    try std.testing.expectEqualDeep(Turns.Prompt{ .line = "First task." }, turns[0].prompt);
    try std.testing.expect(turns[0].drops_mutating_turn);
    try std.testing.expect(!turns[1].drops_mutating_turn);
    const first_id = turns[0].id;
    const second_id = turns[1].id;
    const rewound = rig.send(&.{ .rewind = first_id });
    try std.testing.expect(rewound.accepted());
    try std.testing.expectEqualStrings("First task.", rewound.recovered.?);
    try std.testing.expectEqual(@as(usize, 0), rig.controller.listTurns().len);
    try expectRefusal(rig.send(&.{ .rewind = second_id }), .unknown_target);
    _ = rig.send(&.{ .send_message = "Third task." });
    try rig.expectTurn(.stopped);
    const later = rig.controller.listTurns();
    try std.testing.expectEqual(@as(usize, 1), later.len);
    try std.testing.expect(later[0].id != first_id and later[0].id != second_id);
    const request = rig.transport.requests.items[3];
    try std.testing.expect(std.mem.find(u8, request, "First task.") == null);
}

test "a turn keeps its outcome and answer under its operation id until a rewind drops it" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .stall = &stall },
        .{ .body = providers.testing.reply_stream },
    } });
    defer rig.deinit();
    try std.testing.expect(rig.controller.operation(1) == .unknown);
    const started = rig.send(&.{ .send_message = "First task." });
    const id = started.operation.?;
    try stall.reached.wait(std.testing.io);
    try std.testing.expectEqual(State.Work{ .turn = id }, rig.controller.state().work);
    try std.testing.expect(rig.controller.operation(id) == .running);
    _ = rig.send(&.{ .cancel = id });
    try rig.expectTurn(.canceled);
    try std.testing.expect(rig.controller.state().work == .idle);
    try std.testing.expect(rig.controller.operation(id).turn_ended.outcome == .canceled);
    const second = rig.send(&.{ .send_message = "Second task." }).operation.?;
    try rig.expectTurn(.stopped);
    try std.testing.expectEqual(id, rig.controller.listTurns()[0].id);
    try std.testing.expectEqual(second, rig.controller.listTurns()[1].id);
    const ended = rig.controller.operation(second).turn_ended;
    try std.testing.expectEqual(core.Session.Outcome{ .stopped = .complete }, ended.outcome);
    try std.testing.expectEqualStrings("done", ended.answer);
    try std.testing.expect(rig.send(&.{ .rewind = second }).accepted());
    try std.testing.expect(rig.controller.operation(second) == .unknown);
    try std.testing.expect(rig.controller.operation(id) == .turn_ended);
}

test "a removed skill turn recovers the exact submitted line" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .files = &.{.{
            ".agents/skills/demo/SKILL.md",
            "---\nname: demo\ndescription: Demo.\n---\nBody.\n",
        }},
        .replies = &.{.{ .stall = &stall }},
    });
    defer rig.deinit();
    const line = "/skill:demo   apply\tit  \n";
    const started = rig.send(&.{ .invoke_skill = .{
        .name = "demo",
        .arguments = "apply\tit",
        .line = line,
    } });
    try stall.reached.wait(std.testing.io);
    _ = rig.send(&.{ .cancel = started.operation.? });
    try rig.expectTurn(.canceled);
    const prompt = rig.controller.listTurns()[0].prompt;
    try std.testing.expectEqualDeep(Turns.Prompt{ .line = line }, prompt);
    const turn = rig.controller.listTurns()[0].id;
    try std.testing.expectEqualStrings(
        line,
        rig.send(&.{ .remove_canceled_turn = turn }).recovered.?,
    );
    try testing.expectContains(rig.transport.requests.items[0], "apply\\tit");
}

test "a skill file that left after the discovery refuses the invocation and names the error" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .files = &.{.{
        ".agents/skills/demo/SKILL.md",
        "---\nname: demo\ndescription: Demo.\n---\nBody.\n",
    }} });
    defer rig.deinit();
    try rig.tree.tmp.dir.deleteFile(std.testing.io, ".agents/skills/demo/SKILL.md");
    try expectRefusal(rig.send(&.{ .invoke_skill = .{
        .name = "demo",
        .arguments = "apply it",
        .line = "/skill:demo apply it",
    } }), .{ .skill_unreadable = .{ .name = "demo", .cause = error.FileNotFound } });
    try std.testing.expectEqual(@as(usize, 0), rig.controller.listTurns().len);
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "a callback paste answers at once, refuses a second paste, and reports the callback" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .authenticated = false });
    defer rig.deinit();
    const initial = try rig.snapshot();
    initial.deinit(std.testing.allocator);
    const operation = rig.send(&.{ .select_account = accounts.testing.anthropic_plan }).operation.?;
    const callback = try rig.callbackUrl();
    defer std.testing.allocator.free(callback);
    rig.loopback.refuses = true;
    try expectRefusal(
        rig.send(&.{ .submit_callback = .{ .operation = operation + 1, .line = callback } }),
        .stale,
    );
    const pasted = rig.send(&.{ .submit_callback = .{ .operation = operation, .line = callback } });
    try std.testing.expect(pasted.accepted());
    try expectRefusal(
        rig.send(&.{ .submit_callback = .{ .operation = operation, .line = callback } }),
        .busy,
    );
    const replayed = try rig.eventOf(.paste_replayed);
    replayed.deinit(std.testing.allocator);
}

test "a callback refusal keeps the sign-in" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .authenticated = false });
    defer rig.deinit();
    const initial = try rig.snapshot();
    initial.deinit(std.testing.allocator);
    const operation = rig.send(&.{ .select_account = accounts.testing.anthropic_plan }).operation.?;
    try std.testing.expect(rig.send(&.{ .submit_callback = .{
        .operation = operation,
        .line = "not a callback",
    } }).accepted());
    for (0..4096) |_| {
        const event = try rig.next();
        defer event.deinit(std.testing.allocator);
        try std.testing.expect(event != .paste_replayed);
        if (event != .state) continue;
        const notice = event.state.notice orelse continue;
        if (notice != .callback_invalid) continue;
        try std.testing.expectEqual(.sign_in, std.meta.activeTag(event.state.work));
        break;
    } else return error.TestExpectedRefusal;
    try std.testing.expect(rig.send(&.{ .cancel = operation }).accepted());
}

test "account facts expose remembered models and authors of inactive accounts" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENROUTER_API_KEY", "sk-or" }},
        .remembered = &.{.{
            .account = accounts.testing.openrouter_api_key,
            .name = "openai/gpt-gone",
        }},
        .files = &.{.{
            ".drinky/metadata.json",
            "{\"openrouter\":{\"models\":[" ++
                "{\"name\":\"qwen/qwen-new\",\"context_window\":1,\"tools\":\"supported\"}," ++
                "{\"name\":\"openai/gpt-new\",\"context_window\":1,\"tools\":\"supported\"}]}}",
        }},
    });
    defer rig.deinit();
    const facts = rig.controller.listAccounts();
    const router = facts[accounts.testing.openrouter_api_key];
    try std.testing.expectEqualStrings("openrouter-api-key", router.id);
    try std.testing.expectEqualStrings("openrouter", router.vendor);
    try std.testing.expect(router.authenticated and !router.login and router.authors);
    try std.testing.expectEqualStrings("openai/gpt-gone", router.remembered.?.model);
    try std.testing.expectEqualStrings("openai", router.remembered.?.author);
    const plan = facts[accounts.testing.openai_plan];
    try std.testing.expect(!plan.authenticated and plan.login);
    try std.testing.expect(plan.remembered == null);
    const models = rig.controller.listModels(accounts.testing.openrouter_api_key);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("qwen/qwen-new", models[0].name);
    try std.testing.expectEqualStrings("qwen", models[0].author);
    try std.testing.expect(!models[0].output_limit_unknown);
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "effort facts name the requested level and the fold of each level" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    const effort = rig.controller.effort();
    try std.testing.expectEqual(core.Provider.Effort.high, effort.requested);
    try std.testing.expectEqualSlices(
        ?core.Provider.Effort,
        &.{ .low, .low, .high, .high, .high },
        &effort.folds.?,
    );
    try std.testing.expect(rig.send(&.{ .set_effort = .low }).accepted());
    try std.testing.expectEqual(core.Provider.Effort.low, rig.controller.effort().requested);
}

test "skill and document facts list complete descriptions, the system prompt, and the skills" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .files = &.{.{
        ".agents/skills/demo/SKILL.md",
        "---\nname: demo\ndescription: First sentence. Second sentence.\n---\nBody.\n",
    }} });
    defer rig.deinit();
    const skills = rig.controller.listSkills();
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("demo", skills[0].name);
    try std.testing.expectEqualStrings("First sentence. Second sentence.", skills[0].description);
    const documents = rig.controller.documents();
    try testing.expectContains(documents.system_prompt, "You are a coding assistant.");
    try std.testing.expectEqual(@as(usize, 1), documents.skills.len);
    try std.testing.expectEqualStrings("demo", documents.skills[0].name);
}

test "session initialization releases every partial allocation" {
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    try tree.write(".git", "");
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkSessionInitialization,
        .{tree.root},
    );
}

fn checkSessionInitialization(gpa: std.mem.Allocator, directory: []const u8) !void {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var listener: InitializationListener = .{ .gpa = gpa };
    const controller = try create(gpa, std.testing.io, &.{
        .directories = .{ .working_directory = directory, .home = directory },
        .environment = &environment,
        .frontend = .{
            .instructions = "Use the client.",
            .reference = "## Client\n\nClient facts.",
        },
        .sink = listener.sink(),
        .mailbox = listener.mailbox(),
    });
    controller.destroy();
}

const InitializationListener = struct {
    gpa: std.mem.Allocator,

    const sink_vtable: Sink.VTable = .{ .emit = InitializationListener.emit };
    const mailbox_vtable: Mailbox.VTable = .{ .post = InitializationListener.post };

    fn sink(self: *InitializationListener) Sink {
        return .{ .ptr = self, .vtable = &sink_vtable };
    }
    fn mailbox(self: *InitializationListener) Mailbox {
        return .{ .ptr = self, .vtable = &mailbox_vtable };
    }
    fn emit(_: *anyopaque, _: *const Event) void {}
    fn post(ptr: *anyopaque, mail: Mail) void {
        const self: *InitializationListener = @ptrCast(@alignCast(ptr));
        mail.deinit(self.gpa);
    }
};

test "run initialization releases refusal text when the session task cannot start" {
    var tree = try testing.Tree.init();
    defer tree.deinit();
    try tree.write(".git", "");
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var listener: InitializationListener = .{ .gpa = std.testing.allocator };
    for ([_][]const u8{ "unknown/model", "openai-api-key/model" }) |model| {
        try std.testing.expectError(error.ConcurrencyUnavailable, Handle.create(
            std.testing.allocator,
            threaded.io(),
            &.{
                .directories = .{ .working_directory = tree.root, .home = tree.root },
                .environment = &environment,
                .frontend = testing.frontend_default,
                .startup = .{ .run = .{ .model = model, .effort = .high, .prompt = "Task." } },
                .sink = listener.sink(),
                .mailbox = listener.mailbox(),
            },
        ));
    }
}

test "snapshot event copies release every partial allocation" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .status = .bad_request, .body = "{}" },
    } });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "hello" });
    try rig.expectTurn(.stopped);
    _ = rig.send(&.{ .prepare_gist = "" });
    const result = try rig.result();
    result.deinit(std.testing.allocator);
    _ = rig.send(&.{ .set_effort = .high });
    const snapshot: Event = .{ .snapshot = try rig.snapshot() };
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(snapshot.snapshot.state.result.?.phase == .incomplete);
    try std.testing.expect(snapshot.snapshot.state.notice != null);
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkSnapshotCopy,
        .{&snapshot},
    );
}

fn checkSnapshotCopy(gpa: std.mem.Allocator, event: *const Event) !void {
    const copy = try event.dupe(gpa);
    defer copy.deinit(gpa);
    try std.testing.expectEqual(event.snapshot.records.len, copy.snapshot.records.len);
    try std.testing.expectEqualStrings(
        event.snapshot.state.branch.?,
        copy.snapshot.state.branch.?,
    );
}

const rejected_reply: providers.testing.FakeTransport.Reply = .{
    .status = .unauthorized,
    .body = "{\"error\":{\"message\":\"expired\"}}",
};
const plan_options: testing.Rig.Options = .{
    .authenticated = false,
    .selected_account = accounts.testing.openai_plan,
    .store = accounts.testing.planStore("first"),
    .models = &.{.{ .account = accounts.testing.openai_plan, .names = &.{"gpt-5.6-sol"} }},
};

fn planRefreshBody(gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const access = try accounts.testing.fakeJwt(gpa, "{\"exp\":4102444800}");
    defer gpa.free(access);
    return gpa.print("{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh-next\"}}", .{access});
}

fn startPlanFetch(rig: *testing.Rig) !u64 {
    const response = rig.send(&.{ .fetch_models = accounts.testing.openai_plan });
    try std.testing.expect(response.accepted());
    return response.operation.?;
}

fn expectFetchEnd(
    rig: *testing.Rig,
    operation: u64,
    outcome: std.meta.Tag(query.FetchOutcome),
) !void {
    const ended = (try rig.eventOf(.fetch_ended)).fetch_ended;
    try std.testing.expectEqual(operation, ended.operation);
    try std.testing.expectEqual(accounts.testing.openai_plan, ended.account);
    try std.testing.expectEqual(outcome, std.meta.activeTag(ended.outcome));
    try std.testing.expectEqual(ended.outcome, rig.controller.operation(operation).fetch_ended);
}

fn expectRequest(rig: *const testing.Rig, index: usize, text: []const u8) !void {
    try testing.expectContains(rig.transport.requests.items[index], text);
}

test "a rejected plan credential selects the next account or reports no account" {
    const key = accounts.testing.openai_api_key;
    const cases = [_]struct {
        authenticated: bool,
        model: bool,
        next: Record.Event.SignedOut.Next,
    }{
        .{
            .authenticated = true,
            .model = true,
            .next = .{ .use = .{ .model = .{ .account = key, .model = "gpt-5.6-sol" } } },
        },
        .{
            .authenticated = true,
            .model = false,
            .next = .{ .use = .{ .account = .{ .account = key, .step = .fetch_models } } },
        },
        .{ .authenticated = false, .model = false, .next = .none },
    };
    for (cases) |case| {
        var options = plan_options;
        options.authenticated = case.authenticated;
        options.replies = &.{ rejected_reply, rejected_reply };
        if (case.model) options.models = &.{
            .{ .account = accounts.testing.openai_plan, .names = &.{"gpt-5.6-sol"} },
            .{ .account = accounts.testing.openai_api_key, .names = &.{"gpt-5.6-sol"} },
        };
        var rig: testing.Rig = undefined;
        try rig.init(&options);
        defer rig.deinit();
        try rig.tree.write(".drinky/auth.json", accounts.testing.planStore("second"));
        _ = rig.send(&.{ .send_message = "hello" });
        var no_account = false;
        for (0..4096) |_| {
            const event = try rig.next();
            defer event.deinit(std.testing.allocator);
            if (event == .no_account) no_account = true;
            if (event == .turn_ended) break;
        } else return error.TestExpectedEnd;
        for (rig.events.items[rig.taken..]) |*event| {
            if (event.* == .no_account) no_account = true;
        }
        try std.testing.expectEqual(!case.authenticated, no_account);
        const ended = try rig.snapshot();
        defer ended.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(Record.Event.SignedOut{
            .account = accounts.testing.openai_plan,
            .rejected = true,
            .next = case.next,
        }, testing.eventOf(ended.records, .signed_out).?);
        try std.testing.expectEqual(
            if (case.authenticated) @as(?usize, accounts.testing.openai_api_key) else null,
            ended.state.choice.account,
        );
        try std.testing.expect((ended.state.choice.model != null) == case.model);
        try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
        try expectRequest(&rig, 0, "authorization: Bearer access-first\n");
        try expectRequest(&rig, 1, "authorization: Bearer access-second\n");
    }
}

test "a rejected refresh during a model fetch reports no account and allows a sign-in" {
    var options = plan_options;
    options.store = testing.expired_plan_store;
    options.replies = &.{
        .{ .status = .unauthorized, .body = "{\"error\":{\"code\":\"refresh_token_reused\"}}" },
        .{ .body = "{\"data\":[]}" },
    };
    var rig: testing.Rig = undefined;
    try rig.init(&options);
    defer rig.deinit();
    const operation = try startPlanFetch(&rig);
    try expectFetchEnd(&rig, operation, .failed);
    const lost = try rig.eventOf(.no_account);
    lost.deinit(std.testing.allocator);
    const selection = rig.send(&.{ .select_account = accounts.testing.openai_plan });
    try std.testing.expect(selection.accepted());
    const signing_in = try rig.state(.sign_in);
    defer signing_in.deinit(std.testing.allocator);
    try std.testing.expectEqual(accounts.testing.openai_plan, signing_in.work.sign_in.account);
}

test "a model fetch renews a rejected access token once and lists the models" {
    const gpa = std.testing.allocator;
    const refresh_body = try planRefreshBody(gpa);
    defer gpa.free(refresh_body);
    var options = plan_options;
    options.replies = &.{
        rejected_reply,
        .{ .body = refresh_body },
        .{ .body = testing.plan_models_body },
        .{ .body = "{\"data\":[]}" },
    };
    var rig: testing.Rig = undefined;
    try rig.init(&options);
    defer rig.deinit();
    const operation = try startPlanFetch(&rig);
    try expectFetchEnd(&rig, operation, .listed);
    const models = rig.controller.listModels(accounts.testing.openai_plan);
    try std.testing.expectEqualStrings("gpt-next", models[0].name);
    try std.testing.expectEqual(@as(usize, 4), rig.transport.requests.items.len);
    try expectRequest(&rig, 0, "authorization: Bearer access-first\n");
    try expectRequest(&rig, 1, "\"refresh_token\":\"refresh-first\"");
    try std.testing.expect(std.mem.find(
        u8,
        rig.transport.requests.items[2],
        "authorization: Bearer access-first\n",
    ) == null);
    try expectRequest(&rig, 2, "authorization: Bearer e30.");
}

test "a model fetch replacement updates the next turn after each outcome" {
    const replacement_store =
        "{\"openai-plan\":{\"access\":\"access-second\",\"refresh\":\"refresh-second\"," ++
        "\"expires_ms\":4102444800000,\"account_id\":\"account-2\"}}";
    const Outcome = enum { complete, failed, canceled };
    for (std.enums.values(Outcome)) |outcome| {
        var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
        const replies = [_]providers.testing.FakeTransport.Reply{
            rejected_reply,
            switch (outcome) {
                .complete => .{ .body = testing.plan_models_body },
                .failed => .{ .status = .bad_request },
                .canceled => .{ .stall = &stall },
            },
            .{ .body = if (outcome == .canceled)
                providers.testing.reply_stream
            else
                "{\"data\":[]}" },
            .{ .body = providers.testing.reply_stream },
        };
        const count: usize = if (outcome == .canceled) 3 else 4;
        var options = plan_options;
        options.replies = replies[0..count];
        var rig: testing.Rig = undefined;
        try rig.init(&options);
        defer rig.deinit();
        try rig.tree.write(".drinky/auth.json", replacement_store);
        const operation = try startPlanFetch(&rig);
        if (outcome == .canceled) {
            try stall.reached.wait(std.testing.io);
            try std.testing.expect(rig.send(&.{ .cancel = operation }).accepted());
            try expectRefusal(rig.send(&.{ .send_message = "early" }), .busy);
        }
        try expectFetchEnd(&rig, operation, switch (outcome) {
            .complete => .listed,
            .failed => .failed,
            .canceled => .canceled,
        });
        const snapshot = try rig.snapshot();
        defer snapshot.deinit(std.testing.allocator);
        switch (outcome) {
            .complete => try std.testing.expectEqualStrings(
                "gpt-next",
                rig.controller.listModels(accounts.testing.openai_plan)[0].name,
            ),
            .failed => try std.testing.expectEqualStrings(
                "ModelListRequestFailed",
                testing.eventOf(snapshot.records, .models_unfetched).?.cause,
            ),
            .canceled => {
                try std.testing.expect(stall.canceled);
                const records = snapshot.records;
                try std.testing.expect(testing.eventOf(records, .models_unfetched) == null);
                try std.testing.expect(testing.eventOf(snapshot.records, .models_fetched) == null);
            },
        }
        try expectRequest(&rig, 1, "chatgpt-account-id: account-2\n");
        _ = rig.send(&.{ .send_message = "hello" });
        try rig.expectTurn(.stopped);
        const ended = try rig.snapshot();
        defer ended.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(
            "gpt-5.6-sol",
            ended.state.choice.modelName().?,
        );
        try std.testing.expectEqual(@as(usize, count), rig.transport.requests.items.len);
        try expectRequest(&rig, count - 1, "authorization: Bearer access-second\n");
        try expectRequest(&rig, count - 1, "chatgpt-account-id: account-2\n");
    }
}

test "a model fetch that rejects the renewed token reports no account without another renewal" {
    const gpa = std.testing.allocator;
    const refresh_body = try planRefreshBody(gpa);
    defer gpa.free(refresh_body);
    var options = plan_options;
    options.replies = &.{
        rejected_reply,
        .{ .body = refresh_body },
        rejected_reply,
        .{ .body = "{\"data\":[]}" },
    };
    var rig: testing.Rig = undefined;
    try rig.init(&options);
    defer rig.deinit();
    const operation = try startPlanFetch(&rig);
    try expectFetchEnd(&rig, operation, .failed);
    const lost = try rig.eventOf(.no_account);
    lost.deinit(gpa);
    const ended = try rig.snapshot();
    defer ended.deinit(gpa);
    try std.testing.expectEqual(@as(?usize, null), ended.state.choice.account);
    try std.testing.expectEqual(@as(usize, 4), rig.transport.requests.items.len);
}

test "an uncertain model-fetch refresh failure keeps the account and a later fetch recovers" {
    const gpa = std.testing.allocator;
    const refresh_body = try planRefreshBody(gpa);
    defer gpa.free(refresh_body);
    for ([_]std.http.Status{ .bad_request, .service_unavailable }) |status| {
        var options = plan_options;
        options.store = testing.expired_plan_store;
        options.replies = &.{
            .{ .status = status, .body = "{\"error\":\"unknown\"}" },
            .{ .body = "{\"data\":[]}" },
            .{ .body = refresh_body },
            .{ .body = testing.plan_models_body },
            .{ .body = "{\"data\":[]}" },
        };
        var rig: testing.Rig = undefined;
        try rig.init(&options);
        defer rig.deinit();
        const first = try startPlanFetch(&rig);
        try expectFetchEnd(&rig, first, .failed);
        const failed = try rig.snapshot();
        defer failed.deinit(gpa);
        try std.testing.expectEqual(
            @as(?usize, accounts.testing.openai_plan),
            failed.state.choice.account,
        );
        try std.testing.expect(testing.eventOf(failed.records, .models_unfetched) != null);
        const second = try startPlanFetch(&rig);
        try expectFetchEnd(&rig, second, .listed);
        try std.testing.expect(rig.controller.operation(first) == .unknown);
        try std.testing.expectEqualStrings(
            "gpt-next",
            rig.controller.listModels(accounts.testing.openai_plan)[0].name,
        );
        try std.testing.expectEqual(@as(usize, 5), rig.transport.requests.items.len);
    }
}

test "a rejected model fetch of another account keeps the active account usable" {
    var options = plan_options;
    options.authenticated = true;
    options.selected_account = accounts.testing.openai_api_key;
    options.store = testing.expired_plan_store;
    options.variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }};
    options.models = &.{
        .{ .account = accounts.testing.openai_plan, .names = &.{"gpt-5.6-sol"} },
        .{ .account = accounts.testing.openai_api_key, .names = &.{"gpt-5.6-sol"} },
    };
    options.replies = &.{
        .{ .status = .bad_request, .body = "{\"error\":\"invalid_grant\"}" },
        .{ .body = "{\"data\":[]}" },
        .{ .body = providers.testing.reply_stream },
    };
    var rig: testing.Rig = undefined;
    try rig.init(&options);
    defer rig.deinit();
    const operation = try startPlanFetch(&rig);
    try expectFetchEnd(&rig, operation, .failed);
    const ended = try rig.snapshot();
    defer ended.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(?usize, accounts.testing.openai_api_key),
        ended.state.choice.account,
    );
    try std.testing.expectEqualDeep(Record.Event.SignedOut{
        .account = accounts.testing.openai_plan,
        .rejected = true,
        .next = .unchanged,
    }, testing.eventOf(ended.records, .signed_out).?);
    _ = rig.send(&.{ .send_message = "hello" });
    try rig.expectTurn(.stopped);
    try expectRequest(&rig, 2, "authorization: Bearer sk-openai\n");
}

test "a rejected model fetch adopts a credential that another instance saved meanwhile" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var options = plan_options;
    options.store = testing.expired_plan_store;
    options.replies = &.{
        .{ .status = .bad_request, .body = "{\"error\":\"invalid_grant\"}" },
        .{ .body = "{\"data\":[]}", .hold = &hold },
    };
    var rig: testing.Rig = undefined;
    try rig.init(&options);
    defer rig.deinit();
    defer hold.released.set(std.testing.io);
    const operation = try startPlanFetch(&rig);
    try hold.reached.wait(std.testing.io);
    try rig.tree.write(".drinky/auth.json", accounts.testing.planStore("second"));
    hold.released.set(std.testing.io);
    try expectFetchEnd(&rig, operation, .failed);
    const ended = try rig.snapshot();
    defer ended.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(?usize, accounts.testing.openai_plan),
        ended.state.choice.account,
    );
    try std.testing.expectEqual(Record.Event.Reload{
        .account = accounts.testing.openai_plan,
        .next = .{ .step = .fetch_models },
    }, testing.eventOf(ended.records, .credential_reloaded).?);
}

test "a cancel ends the credential renewal of a model fetch and keeps the account" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var options = plan_options;
    options.replies = &.{ rejected_reply, .{ .stall = &stall } };
    var rig: testing.Rig = undefined;
    try rig.init(&options);
    defer rig.deinit();
    const operation = try startPlanFetch(&rig);
    try stall.reached.wait(std.testing.io);
    _ = rig.send(&.{ .cancel = operation });
    try expectFetchEnd(&rig, operation, .canceled);
    try std.testing.expect(stall.canceled);
    const ended = try rig.snapshot();
    defer ended.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(?usize, accounts.testing.openai_plan),
        ended.state.choice.account,
    );
    try expectRequest(&rig, 1, "https://auth.openai.com/oauth/token\n");
}

test "a rejected key credential keeps its account" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{rejected_reply} });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "hello" });
    try rig.expectTurn(.failed);
    const snapshot = try rig.snapshot();
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(?usize, accounts.testing.openai_api_key),
        snapshot.state.choice.account,
    );
    try std.testing.expectEqualDeep(Record.Event.Failure{
        .reason = .unauthorized,
        .details = "401 Unauthorized: expired",
    }, testing.eventOf(snapshot.records, .request_failed).?);
    try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
}

const choice_call_stream =
    "data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"fc_1\"," ++
    "\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call_1\"," ++
    "\"name\":\"bash\",\"arguments\":" ++
    "\"{\\\"command\\\":\\\"echo choice:$DRINKY_MODEL:$DRINKY_EFFORT\\\"}\"}}\n\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";

test "requests and tools use the selected model and effort across turns" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = choice_call_stream },
        .{ .body = providers.testing.reply_stream },
        .{ .body = choice_call_stream },
        .{ .body = providers.testing.reply_stream },
    } });
    defer rig.deinit();
    try std.testing.expect(rig.send(&.{ .set_effort = .low }).accepted());
    _ = rig.send(&.{ .send_message = "check" });
    try rig.expectTurn(.stopped);
    try std.testing.expect(rig.send(&.{ .set_effort = .max }).accepted());
    _ = rig.send(&.{ .send_message = "again" });
    try rig.expectTurn(.stopped);
    const snapshot = try rig.snapshot();
    defer snapshot.deinit(std.testing.allocator);
    var levels: [2]core.Provider.Effort = undefined;
    var count: usize = 0;
    for (snapshot.records) |*record| {
        if (record.content != .event or record.content.event != .effort_changed) continue;
        try std.testing.expect(count < levels.len);
        levels[count] = record.content.event.effort_changed;
        count += 1;
    }
    try std.testing.expectEqualSlices(core.Provider.Effort, &.{ .low, .max }, levels[0..count]);
    try std.testing.expectEqual(@as(usize, 4), rig.transport.requests.items.len);
    try expectRequest(&rig, 0, "\"model\":\"gpt-5.6-sol\"");
    try expectRequest(&rig, 0, "\"effort\":\"low\"");
    try expectRequest(&rig, 2, "\"effort\":\"high\"");
    try expectRequest(&rig, 0, "You are a coding assistant. You run inside Drinky.");
    try expectRequest(&rig, 1, "choice:openai-api-key/gpt-5.6-sol:low");
    try expectRequest(&rig, 3, "choice:openai-api-key/gpt-5.6-sol:max");
    try expectRequest(&rig, 3, "\"text\":\"check\"");
    try expectRequest(&rig, 3, "\"text\":\"again\"");
}

test "a model selection switches the account and the model without a picker" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
        .models = &.{
            .{ .account = accounts.testing.openai_api_key, .names = &.{"gpt-5.6-sol"} },
            .{ .account = accounts.testing.anthropic_api_key, .names = &.{"claude-fable-5"} },
        },
    });
    defer rig.deinit();
    try std.testing.expect(rig.send(&.{ .select_model = .{
        .account = accounts.testing.anthropic_api_key,
        .model = "claude-fable-5",
    } }).accepted());
    const switched = try rig.snapshot();
    defer switched.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(?usize, accounts.testing.anthropic_api_key),
        switched.state.choice.account,
    );
    try std.testing.expectEqualStrings("claude-fable-5", switched.state.choice.modelName().?);
    try std.testing.expectEqualDeep(Record.Event.Use{ .model = .{
        .account = accounts.testing.anthropic_api_key,
        .model = "claude-fable-5",
    } }, testing.eventOf(switched.records, .use_changed).?);
}

test "a canceled gist stays active until its end and then drops its result" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .stall = &stall },
    } });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "hello" });
    try rig.expectTurn(.stopped);
    const operation = rig.send(&.{ .prepare_gist = "" }).operation.?;
    try stall.reached.wait(std.testing.io);
    try expectRefusal(rig.send(&.{ .discard_result = operation }), .busy);
    try std.testing.expect(rig.send(&.{ .cancel = operation }).accepted());
    try expectRefusal(rig.send(&.{ .prepare_gist = "" }), .busy);
    const ended = try rig.state(.idle);
    defer ended.deinit(std.testing.allocator);
    try std.testing.expect(ended.result == null);
    try std.testing.expect(stall.canceled);
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
}

test "each save writes a new gist, and a listing names the directory and the titles" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.replyStream("# First gist\\nBody.") },
        .{ .body = providers.testing.replyStream("Second gist\\nBody.") },
    } });
    defer rig.deinit();
    const empty = rig.controller.listGists();
    try std.testing.expectEqual(@as(usize, 0), empty.listing.listed.entries.len);
    try std.testing.expectEqualStrings(try rig.tree.path(".drinky/gists"), empty.directory);
    _ = rig.send(&.{ .send_message = "Original task." });
    try rig.expectTurn(.stopped);

    const first_id = rig.send(&.{ .prepare_gist = "Keep the constraints." }).operation.?;
    const first = try rig.result();
    defer first.deinit(gpa);
    try testing.expectUsers(first.records, &.{"Original task."});
    try expectRequest(&rig, 1, "\"instructions\":\"You write a gist for a fresh coding-agent");
    try expectRequest(&rig, 1, "\"effort\":\"high\"");
    try expectRequest(&rig, 1, "\"input\":[{\"type\":\"message\",\"role\":\"user\"," ++
        "\"content\":[{\"type\":\"input_text\",\"text\":\"Original task.\"}]}," ++
        "{\"type\":\"message\",\"role\":\"assistant\"," ++
        "\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}," ++
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\"," ++
        "\"text\":\"Write the gist.\\n<instruction>\\nKeep the constraints.\\n" ++
        "</instruction>\"}]}]");
    for ([_][]const u8{ "\"tools\"", "\"prompt_cache_key\"" }) |field|
        try std.testing.expect(std.mem.find(u8, rig.transport.requests.items[1], field) == null);
    try std.testing.expect(rig.send(&.{ .save_result = first_id }).accepted());
    try expectRefusal(rig.send(&.{ .save_result = first_id }), .stale);
    const saved = try rig.snapshot();
    defer saved.deinit(gpa);
    try std.testing.expect(saved.state.result == null);
    try testing.expectUsers(saved.records, &.{"Original task."});

    const second_id = rig.send(&.{ .prepare_gist = "" }).operation.?;
    const second = try rig.result();
    defer second.deinit(gpa);
    try std.testing.expect(rig.send(&.{ .save_result = second_id }).accepted());
    const entries = rig.controller.listGists().listing.listed.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    var titles: [2][]const u8 = .{ entries[0].title, entries[1].title };
    std.mem.sortUnstable([]const u8, &titles, {}, lessText);
    try std.testing.expectEqualStrings("First gist", titles[0]);
    try std.testing.expectEqualStrings("Second gist", titles[1]);
    for (entries) |*entry| {
        var buffer: [32]u8 = undefined;
        const hex = std.fmt.bytesToHex(entry.id, .lower);
        const sub_path = try std.mem.print(&buffer, ".drinky/gists/{s}.md", .{&hex});
        const stat = try rig.tree.tmp.dir.statFile(std.testing.io, sub_path, .{});
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    }
}

fn lessText(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "an apply of a result saves it and continues in a new conversation with the marked text" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.replyStream("Resume the task.\\nKeep the tests.") },
        .{ .body = providers.testing.replyStream("Continued.") },
    } });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "Original task." });
    try rig.expectTurn(.stopped);
    const id = rig.send(&.{ .prepare_gist = "" }).operation.?;
    const ready = try rig.result();
    ready.deinit(gpa);

    try std.testing.expect(rig.send(&.{ .apply_result = id }).accepted());
    try rig.expectTurn(.stopped);
    const continued = try rig.snapshot();
    defer continued.deinit(gpa);
    try std.testing.expect(continued.state.result == null);
    try testing.expectUsers(continued.records, &.{"Keep the tests."});
    try std.testing.expectEqualDeep(
        Record.Note{ .gist = .{ .title = "Resume the task." } },
        continued.records[0].content.user_note,
    );
    const turn = rig.controller.listTurns()[0];
    try std.testing.expectEqualDeep(Turns.Prompt{ .gist = "Resume the task." }, turn.prompt);
    try expectRequest(
        &rig,
        2,
        "\"text\":\"<gist>\\nResume the task.\\nKeep the tests.\\n</gist>\"",
    );
    try std.testing.expect(std.mem.find(
        u8,
        rig.transport.requests.items[2],
        "Original task.",
    ) == null);
    const entries = rig.controller.listGists().listing.listed.entries;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Resume the task.", entries[0].title);
    const rewound = rig.send(&.{ .rewind = turn.id });
    try std.testing.expect(rewound.accepted());
    try std.testing.expect(rewound.recovered == null);
}

test "an applied gist file reads its text, and a title alone shows only the note" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .files = &.{
            .{ ".drinky/gists/0123456789ab.md", "# Saved task\nKeep the tests." },
            .{ ".drinky/gists/aaaaaaaaaaaa.md", "Title alone\n\n" },
        },
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.reply_stream },
        },
    });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "Original task." });
    try rig.expectTurn(.stopped);
    const read = rig.controller.readGist(&sample_gist);
    try std.testing.expectEqualStrings("# Saved task\nKeep the tests.", read.text);

    try std.testing.expect(rig.send(&.{ .apply_gist = sample_gist }).accepted());
    try rig.expectTurn(.stopped);
    try expectRequest(&rig, 1, "\"text\":\"<gist>\\n# Saved task\\nKeep the tests.\\n</gist>\"");
    const applied = try rig.snapshot();
    defer applied.deinit(gpa);
    try testing.expectUsers(applied.records, &.{"Keep the tests."});

    try std.testing.expect(rig.send(&.{ .apply_gist = @splat(0xaa) }).accepted());
    try rig.expectTurn(.stopped);
    const alone = try rig.snapshot();
    defer alone.deinit(gpa);
    try testing.expectUsers(alone.records, &.{});
    try std.testing.expectEqualDeep(
        Record.Note{ .gist = .{ .title = "Title alone" } },
        alone.records[0].content.user_note,
    );
}

test "a listing sorts newest first, counts hidden gists, and a read names its failure" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .files = &.{
            .{ ".drinky/gists/0123456789ab.md", "Kept\nBody." },
            .{ ".drinky/gists/eeeeeeeeeeee.md", "# Older\nBody." },
            .{ ".drinky/gists/aaaaaaaaaaaa.md", " \n\t\n" },
            .{ ".drinky/gists/dddddddddddd.md", "Title\n\xe9t\xe9" },
            .{ ".drinky/gists/ffffffffffff.md", "Title\x00Body." },
            .{ ".drinky/gists/bbbbbbbbbbbb.md/unreadable", "" },
            .{ ".drinky/gists/notes.md", "Not a gist." },
            .{ ".drinky/gists/cccccccccccc.txt", "Not a gist." },
        },
        .replies = &.{.{ .body = providers.testing.reply_stream }},
    });
    defer rig.deinit();
    for ([_]struct { name: []const u8, seconds: i96 }{
        .{ .name = ".drinky/gists/0123456789ab.md", .seconds = 2_000 },
        .{ .name = ".drinky/gists/eeeeeeeeeeee.md", .seconds = 1_000 },
    }) |stamp| {
        var file = try rig.tree.tmp.dir.openFile(std.testing.io, stamp.name, .{
            .mode = .read_write,
        });
        defer file.close(std.testing.io);
        try file.setTimestamps(std.testing.io, .{ .modify_timestamp = .{
            .new = .fromNanoseconds(stamp.seconds * std.time.ns_per_s),
        } });
    }
    const expected: Gists.Listing = .{
        .entries = &.{
            .{ .id = sample_gist, .title = "Kept", .saved_ms = 2_000_000 },
            .{ .id = @splat(0xee), .title = "Older", .saved_ms = 1_000_000 },
        },
        .unreadable = 1,
        .invalid = 3,
    };
    try std.testing.expectEqualDeep(expected, rig.controller.listGists().listing.listed);

    const invalid_paths = [_][]const u8{
        try rig.tree.path(".drinky/gists/aaaaaaaaaaaa.md"),
        try rig.tree.path(".drinky/gists/dddddddddddd.md"),
    };
    for ([_]Gists.Id{ @splat(0xaa), @splat(0xdd) }, invalid_paths) |id, path|
        try std.testing.expectEqualStrings(path, rig.controller.readGist(&id).invalid);
    const reads = [_]struct { id: Gists.Id, name: []const u8, cause: Gists.Error }{
        .{ .id = @splat(0xbb), .name = "bbbbbbbbbbbb.md", .cause = error.IsDir },
        .{ .id = @splat(0xcc), .name = "cccccccccccc.md", .cause = error.FileNotFound },
    };
    for (reads) |case| {
        var buffer: [64]u8 = undefined;
        const sub_path = try std.mem.print(&buffer, ".drinky/gists/{s}", .{case.name});
        const path = try rig.tree.path(sub_path);
        try std.testing.expectEqualDeep(
            query.GistText{ .failed = .{ .path = path, .cause = case.cause } },
            rig.controller.readGist(&case.id),
        );
    }
    _ = rig.send(&.{ .send_message = "Task." });
    try rig.expectTurn(.stopped);
    for ([_]Gists.Id{ @splat(0xaa), @splat(0xdd) }, invalid_paths) |id, path| {
        const refusal: Refusal = .{ .gist_invalid = path };
        try expectRefusal(rig.send(&.{ .apply_gist = id }), refusal);
    }
}

test "a deletion repeats without a failure even without its directory, and a missing gist refuses" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .files = &.{.{ ".drinky/gists/0123456789ab.md", "Gist\nBody." }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
    });
    defer rig.deinit();
    try std.testing.expect(rig.send(&.{ .delete_gist = sample_gist }).accepted());
    try std.testing.expect(rig.send(&.{ .delete_gist = sample_gist }).accepted());
    try std.testing.expectEqual(
        @as(usize, 0),
        rig.controller.listGists().listing.listed.entries.len,
    );
    const path = try rig.tree.path(".drinky/gists/0123456789ab.md");
    try expectRefusal(rig.send(&.{ .apply_gist = sample_gist }), .{ .gist_failed = .{
        .path = path,
        .cause = error.FileNotFound,
    } });
    try rig.tree.tmp.dir.deleteTree(std.testing.io, ".drinky/gists");
    try std.testing.expect(rig.send(&.{ .delete_gist = sample_gist }).accepted());
}

test "a failed save keeps the result and the conversation for another attempt" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.replyStream("Gist\\nBody.") },
    } });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "Task." });
    try rig.expectTurn(.stopped);
    try rig.tree.write(".drinky/gists", "blocked");
    const id = rig.send(&.{ .prepare_gist = "" }).operation.?;
    const ready = try rig.result();
    ready.deinit(gpa);
    const directory = try rig.tree.path(".drinky/gists");
    for ([_]Command{ .{ .save_result = id }, .{ .apply_result = id } }) |value| {
        const refused = rig.send(&value);
        try std.testing.expectEqualDeep(Refusal{ .gist_failed = .{
            .path = directory,
            .cause = error.NotDir,
        } }, refused.refusal.?);
    }
    const kept = try rig.snapshot();
    defer kept.deinit(gpa);
    try std.testing.expect(kept.state.result.?.phase == .complete);
    try testing.expectUsers(kept.records, &.{"Task."});
    try rig.tree.tmp.dir.deleteFile(std.testing.io, ".drinky/gists");
    try std.testing.expect(rig.send(&.{ .save_result = id }).accepted());
    try std.testing.expectEqual(
        @as(usize, 1),
        rig.controller.listGists().listing.listed.entries.len,
    );
}

test "a result that is not text stays incomplete and cannot save" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.replyStream("Title\\u0000Body.") },
    } });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "Task." });
    try rig.expectTurn(.stopped);
    const id = rig.send(&.{ .prepare_gist = "" }).operation.?;
    const ended = try rig.result();
    defer ended.deinit(std.testing.allocator);
    const not_text: State.Result.Phase = .{ .incomplete = .not_text };
    try std.testing.expectEqualDeep(not_text, ended.state.result.?.phase);
    try expectRefusal(rig.send(&.{ .save_result = id }), .stale);
    try expectRefusal(rig.send(&.{ .apply_result = id }), .stale);
}

test "a gist of an older conversation cannot save or apply" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.replyStream("Gist.\\nBody.") },
        .{ .body = providers.testing.reply_stream },
    } });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "Original task." });
    try rig.expectTurn(.stopped);
    const id = rig.send(&.{ .prepare_gist = "" }).operation.?;
    const ready = try rig.result();
    ready.deinit(std.testing.allocator);
    _ = rig.send(&.{ .send_message = "Later task." });
    try rig.expectTurn(.stopped);
    try expectRefusal(rig.send(&.{ .save_result = id }), .stale);
    try expectRefusal(rig.send(&.{ .apply_result = id }), .stale);
    try std.testing.expectEqual(
        @as(usize, 0),
        rig.controller.listGists().listing.listed.entries.len,
    );
}

test "a rejected plan credential yields to the credential that another instance saved" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var held_rejection = rejected_reply;
    held_rejection.hold = &hold;
    var options = plan_options;
    options.replies = &.{ rejected_reply, held_rejection };
    var rig: testing.Rig = undefined;
    try rig.init(&options);
    defer rig.deinit();
    defer hold.released.set(std.testing.io);
    try rig.tree.write(".drinky/auth.json", accounts.testing.planStore("second"));
    _ = rig.send(&.{ .send_message = "hello" });
    try hold.reached.wait(std.testing.io);
    try rig.tree.write(".drinky/auth.json", accounts.testing.planStore("third"));
    hold.released.set(std.testing.io);
    try rig.expectTurn(.failed);
    const snapshot = try rig.snapshot();
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        @as(?usize, accounts.testing.openai_plan),
        snapshot.state.choice.account,
    );
    try std.testing.expectEqual(Record.Event.Reload{
        .account = accounts.testing.openai_plan,
        .next = .retry_turn,
    }, testing.eventOf(snapshot.records, .credential_reloaded).?);
}
