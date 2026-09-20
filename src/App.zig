const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const Config = @import("Config.zig");
const describe = @import("describe.zig");
const Herdr = @import("Herdr.zig");
const layout = @import("layout.zig");
const PromptHistory = @import("PromptHistory.zig");
const remote = @import("remote/root.zig");
const Retry = @import("Retry.zig");
const Revision = @import("Revision.zig");
const Session = @import("Session.zig");
const sources = @import("sources.zig");
const State = @import("State.zig");
const system_prompt = @import("system_prompt.zig");
const ui = @import("ui/root.zig");

const App = @This();

const effort_default: ai.llm.Effort = .xhigh;

const no_model_refusal = "Select a model with /model before you send a message.";

const telegram_signed_out_refusal =
    "Sign in with /login in the terminal before you send a message.";
const telegram_no_model_refusal =
    "Select a model with /model in the terminal before you send a message.";

const shorten_note_text = "Drinky asked the model to shorten the last answer.";
const shorten_request_text =
    \\Shorten your last answer for a phone screen.
    \\- Line 1 states the result. A reader who stops there knows it.
    \\- One line states each point that the user needs for the next decision. Leave out every other point.
    \\- Write Simplified Technical English. Use a plain word, never a metaphor.
;

const fetch_wait_text = "Drinky fetches the model list.";

const prompt_history_turn_notice = "Prompt history cannot open while a turn runs.";
const prompt_history_empty_notice = "Prompt history is empty.";
const turn_cancel_notice = "Press Esc again to cancel the turn. The draft stays.";
const prompt_history_oversized_notice = std.fmt.comptimePrint(
    "Drinky did not add the prompt to history because it exceeds {d} KiB.",
    .{@divExact(PromptHistory.entry_bytes_max, 1024)},
);

const test_anthropic_model = ai.testing.model("claude-opus-5");
const test_openai_model = ai.testing.model("gpt-5.6-sol");

const intro_keys = [_][]const u8{
    "Enter: Send",
    "Shift+Enter: New line",
    "Tab: Prompt history",
    "Esc: Cancel",
    "Ctrl+C: Clear",
    "Ctrl+D: Quit",
};

const intro_text = blk: {
    var line: []const u8 = "";
    for (intro_keys) |hint| line = line ++ hint ++ ui.paint.separator;
    break :blk line ++ "/help: Commands";
};

const token_check_wait_text = "Drinky checks the bot token.";

const login_callback_controls = "Enter: Replay callback URL · Esc: Cancel";
const login_device_controls = "Esc: Cancel";

const ctrl_c_window_ms = 500;

const escape_wait_ms = 50;

const queue_capacity = 256;

gpa: std.mem.Allocator,
io: std.Io,
tty: terminal.Tty,
resize: terminal.Resize,
accounts: ai.Accounts,
state: State,
prompt_history: PromptHistory,
config_path: []const u8,
directory_label: []const u8,
working_directory: []const u8,
home_directory: []const u8,
project_instructions: ai.instructions.Result,
skills: ai.skills.Registry,
prompt: []const u8,
document: []const u8,
sources_page: []const u8,
skill_guard: ai.tool.SkillGuard,
agent: ai.Agent,
session: Session,
input: terminal.Input,
running: bool,
ctrl_c_ms_last: i64,
escape_deadline_ms: ?i64,
queue: std.Io.Queue(UiEvent),
queue_buffer: [queue_capacity]UiEvent,
deferred_events: [queue_capacity]UiEvent,
deferred_event_count: usize,
input_future: ?std.Io.Future(void),
resize_future: ?std.Io.Future(void),
turn_future: ?std.Io.Future(WorkerResult),
pending_turn_result: ?WorkerResult,
turn_generation: u64,
fetch: ?Fetch,
fetch_generation: u64,
login: ?Login,
login_generation: u64,
retry: ?Retry,
turn_retry: bool,
revision: ?Revision,
tick_future: ?std.Io.Future(void),
tick_pending: bool,
frame_grid: FrameGrid,
herdr: Herdr,
controller: remote.Controller,
mirror: remote.Mirror,
chat_picker: remote.Picker,
remote_title: []const u8,
pairing_wait_text: []const u8,
pairing_wait_link: []const u8,
prompt_marked: bool,
steering_marked_count: usize,

pub const Options = struct {
    environ: std.process.Environ = .empty,
    credentials: ai.Accounts.Environment = .{},
    herdr: ?Herdr.Env = null,
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

const TurnHandler = struct {
    app: *App,
    generation: u64,
    progress_sequence: u64 = 0,
    progress_sequence_committed: u64 = 0,
    error_text: ?[]u8 = null,
    served_model_reported_buffer: [64]u8 = undefined,
    served_model_reported_length: usize = 0,

    pub fn onText(self: *TurnHandler, delta: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, delta);
        errdefer self.app.gpa.free(copy);
        try self.enqueue(.{ .text = copy });
    }

    pub fn onThinking(self: *TurnHandler, delta: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, delta);
        errdefer self.app.gpa.free(copy);
        try self.enqueue(.{ .thinking = copy });
    }

    pub fn onToolName(self: *TurnHandler, name: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(copy);
        try self.enqueue(.{ .tool_name = copy });
    }

    pub fn onToolArguments(self: *TurnHandler, delta: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, delta);
        errdefer self.app.gpa.free(copy);
        try self.enqueue(.{ .tool_arguments = copy });
    }

    pub fn onToolStart(self: *TurnHandler, name: []const u8, input_json: []const u8) !void {
        const name_copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(name_copy);
        const json_copy = try self.app.gpa.dupe(u8, input_json);
        errdefer self.app.gpa.free(json_copy);
        try self.enqueue(.{ .tool_start = .{ .name = name_copy, .input_json = json_copy } });
    }

    pub fn onToolResult(
        self: *TurnHandler,
        name: []const u8,
        content: []const u8,
        maybe_summary: ?ai.tool.Result.Summary,
        is_error: bool,
    ) !void {
        _ = content;
        const name_copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(name_copy);
        const maybe_summary_copy: ?ai.tool.Result.Summary = if (maybe_summary) |summary|
            .{ .text = try self.app.gpa.dupe(u8, summary.text), .kind = summary.kind }
        else
            null;
        errdefer if (maybe_summary_copy) |summary_copy| self.app.gpa.free(summary_copy.text);
        try self.enqueue(.{ .tool_result = .{
            .name = name_copy,
            .summary = maybe_summary_copy,
            .is_error = is_error,
        } });
        self.progress_sequence_committed = self.progress_sequence;
    }

    pub fn onUsage(self: *TurnHandler, stats: ai.Agent.Stats) !void {
        try self.enqueue(.{ .usage = stats });
    }

    pub fn onStreamReset(
        self: *TurnHandler,
        retry: *const ai.Agent.RetryAttempt,
    ) !void {
        const owned: ai.Agent.RetryAttempt = switch (retry.cause) {
            .failure => |failure| .{
                .attempt = retry.attempt,
                .cause = .{ .failure = failure },
            },
            .response => |response| .{
                .attempt = retry.attempt,
                .cause = .{ .response = try self.app.gpa.dupe(u8, response) },
            },
        };
        errdefer switch (owned.cause) {
            .failure => {},
            .response => |response| self.app.gpa.free(response),
        };
        try self.enqueue(.{ .stream_reset = owned });
    }

    pub fn onModelMismatch(self: *TurnHandler, mismatch: ai.Agent.ModelMismatch) !void {
        const reported =
            self.served_model_reported_buffer[0..self.served_model_reported_length];
        const key_length = @min(mismatch.served.len, self.served_model_reported_buffer.len);
        const key = mismatch.served[0..key_length];
        if (std.mem.eql(u8, reported, key)) return;
        const requested_copy = try self.app.gpa.dupe(u8, mismatch.requested);
        errdefer self.app.gpa.free(requested_copy);
        const served_copy = try self.app.gpa.dupe(u8, mismatch.served);
        errdefer self.app.gpa.free(served_copy);
        try self.enqueue(.{ .model_mismatch = .{
            .requested = requested_copy,
            .served = served_copy,
        } });
        @memcpy(self.served_model_reported_buffer[0..key_length], key);
        self.served_model_reported_length = key_length;
    }

    pub fn onSkillLoaded(self: *TurnHandler, skill: []const u8, source: []const u8) !void {
        const skill_copy = try self.app.gpa.dupe(u8, skill);
        errdefer self.app.gpa.free(skill_copy);
        const source_copy = try self.app.gpa.dupe(u8, source);
        errdefer self.app.gpa.free(source_copy);
        try self.enqueue(.{ .skill_loaded = .{
            .skill = skill_copy,
            .source = source_copy,
        } });
    }

    pub fn onSteering(self: *TurnHandler, text: []const u8, count: usize) !void {
        const copy = try self.app.gpa.dupe(u8, text);
        errdefer self.app.gpa.free(copy);
        try self.enqueue(.{ .steering_consumed = .{ .text = copy, .count = count } });
    }

    pub fn onError(self: *TurnHandler, text: []const u8) !void {
        const copy = try self.app.gpa.dupe(u8, text);
        if (self.error_text) |old| self.app.gpa.free(old);
        self.error_text = copy;
    }

    pub fn onCheckpoint(self: *TurnHandler) void {
        self.progress_sequence_committed = self.progress_sequence;
    }

    fn enqueue(self: *TurnHandler, payload: Session.TurnEvent.Payload) !void {
        if (self.progress_sequence == std.math.maxInt(u64))
            return error.TurnProgressExhausted;
        const progress_sequence = self.progress_sequence + 1;
        try self.app.queue.putOne(self.app.io, .{ .turn = .{
            .generation = self.generation,
            .progress_sequence = progress_sequence,
            .progress_sequence_committed = self.progress_sequence_committed,
            .payload = payload,
        } });
        self.progress_sequence = progress_sequence;
    }
};

const WorkerResult = struct {
    outcome: ai.Agent.Outcome,
    error_text: ?[]u8,
    generation: u64 = 0,
    progress_sequence: u64 = 0,
    progress_sequence_committed: u64 = 0,
    terminal_queued: bool = false,
};

pub const UiEvent = union(enum) {
    keys: []u8,
    turn: Session.TurnEvent,
    tick,
    resize,
    fetch_ended: u64,
    remote: remote.Attachment.Event,
    login: LoginEvent,
    pairing: remote.Pairing.Event,

    pub fn deinit(self: *const UiEvent, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .keys => |bytes| gpa.free(bytes),
            .turn => |*event| event.deinit(gpa),
            .login => |*event| event.deinit(gpa),
            .remote => |*event| event.deinit(gpa),
            .pairing => |*event| event.deinit(gpa),
            .tick, .resize, .fetch_ended => {},
        }
    }
};

const Fetch = struct {
    future: std.Io.Future(ai.Accounts.Refresh),
    account: ai.llm.Account,
    generation: u64,
};

const LoginEvent = struct {
    generation: u64,
    payload: Payload,

    const Payload = union(enum) {
        authorization: Authorization,
        browser_launch_failed,
        ended,
    };

    const Authorization = struct {
        url: []u8,
        code: ?[]u8,
        callback_path: ?[]u8,
    };

    fn deinit(self: *const LoginEvent, gpa: std.mem.Allocator) void {
        switch (self.payload) {
            .authorization => |authorization| {
                gpa.free(authorization.url);
                if (authorization.code) |code| gpa.free(code);
                if (authorization.callback_path) |callback_path| gpa.free(callback_path);
            },
            .browser_launch_failed, .ended => {},
        }
    }
};

const LoginPrompt = struct {
    app: *App,
    generation: u64,

    const Runtime = struct {
        code: ?[]const u8 = null,
        callback_path: ?[]const u8 = null,
    };

    pub fn showAuthorization(
        self: *LoginPrompt,
        url: []const u8,
        callback_path: ?[]const u8,
    ) !void {
        try self.show(url, &.{ .callback_path = callback_path });
    }

    pub fn showDeviceCode(self: *LoginPrompt, url: []const u8, code: []const u8) !void {
        try self.show(url, &.{ .code = code });
    }

    pub fn showBrowserLaunchFailed(self: *LoginPrompt) !void {
        try self.app.queue.putOne(self.app.io, .{ .login = .{
            .generation = self.generation,
            .payload = .browser_launch_failed,
        } });
    }

    fn show(self: *LoginPrompt, url: []const u8, runtime: *const Runtime) !void {
        const url_copy = try self.app.gpa.dupe(u8, url);
        errdefer self.app.gpa.free(url_copy);
        const maybe_code_copy = if (runtime.code) |code|
            try self.app.gpa.dupe(u8, code)
        else
            null;
        errdefer if (maybe_code_copy) |code_copy| self.app.gpa.free(code_copy);
        const maybe_path_copy = if (runtime.callback_path) |callback_path|
            try self.app.gpa.dupe(u8, callback_path)
        else
            null;
        errdefer if (maybe_path_copy) |path_copy| self.app.gpa.free(path_copy);
        try self.app.queue.putOne(self.app.io, .{ .login = .{
            .generation = self.generation,
            .payload = .{ .authorization = .{
                .url = url_copy,
                .code = maybe_code_copy,
                .callback_path = maybe_path_copy,
            } },
        } });
    }
};

const LoginWorkerResult = struct {
    account: ai.llm.Account,
    generation: u64,
    outcome: Outcome,

    const Outcome = union(enum) {
        completed: ai.Accounts.Login,
        failed: anyerror,
    };
};

const Login = struct {
    future: std.Io.Future(LoginWorkerResult),
    callback: ?ai.Accounts.Callback,
    callback_path: ?[]u8 = null,
    generation: u64,
    title: []const u8,
    attempt: LoginAttempt,
};

const LoginAttempt = struct {
    account: ai.llm.Account,
    event_index: ?usize = null,
};

fn validateWorkingDirectory(gpa: std.mem.Allocator, path: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(path)) return;
    const safe_path = try ai.instructions.diagnosticAlloc(gpa, path);
    defer gpa.free(safe_path);
    std.debug.print(
        "Drinky cannot use the working directory {s} because its path is not valid UTF-8.\n",
        .{safe_path},
    );
    return error.WorkingDirectoryNotUtf8;
}

fn directoryLabel(
    gpa: std.mem.Allocator,
    directory: []const u8,
    home: []const u8,
) ![]const u8 {
    const label = if (ai.format.relativeTo(&.{ .boundary = home, .target = directory })) |relative|
        try std.fmt.allocPrint(gpa, "~/{s}", .{relative})
    else if (ai.project.contains(&.{ .boundary = home, .target = directory }))
        try gpa.dupe(u8, "~")
    else
        try gpa.dupe(u8, directory);
    if (label.len <= ui.status.directory_bytes_max) return label;
    defer gpa.free(label);
    const marker = "…";
    const budget = ui.status.directory_bytes_max - marker.len;
    const start = terminal.width.boundaryAtOrAfter(label, label.len - budget);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ marker, label[start..] });
}

fn homeDirectory(
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
    home: []const u8,
) ![]u8 {
    const resolved = try std.fs.path.resolve(gpa, &.{ working_directory, home });
    errdefer gpa.free(resolved);
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, resolved, gpa) catch return resolved;
    defer gpa.free(canonical);
    const owned = try gpa.dupe(u8, canonical);
    gpa.free(resolved);
    return owned;
}

fn showProject(self: *App, inside_herdr: bool) void {
    if (inside_herdr) return;
    self.session.directory_shown = self.directory_label;
    self.session.branch_root = self.project_instructions.projectRoot();
    self.refreshBranch();
}

fn refreshBranch(self: *App) void {
    const root = self.session.branch_root orelse return self.session.setBranch("");
    var maybe_head = ai.project.head(self.gpa, self.io, root);
    if (maybe_head) |*head| self.session.setBranch(head.name()) else self.session.setBranch("");
}

pub fn run(
    self: *App,
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    options: *const Options,
) !void {
    self.initFields(gpa, io);
    defer self.input.deinit();

    const cwd_source = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_source);
    const cwd = try std.Io.Dir.realPathFileAbsoluteAlloc(io, cwd_source, gpa);
    defer gpa.free(cwd);
    try validateWorkingDirectory(gpa, cwd);

    var config = try Config.load(gpa, io, &.{ .working_directory = cwd, .home = home });
    defer config.deinit(gpa);

    self.accounts = try ai.Accounts.init(gpa, io, home, config.timeouts, options.credentials);
    defer self.accounts.deinit();
    try self.controller.openStore(home);
    defer self.controller.deinit();
    self.controller.connect_ms = config.timeouts.anthropic.connect_ms;
    var serial_seed: [8]u8 = undefined;
    io.random(&serial_seed);
    self.mirror.seedSerials(std.mem.readInt(u64, &serial_seed, .little));
    self.chat_picker.seedSerials(std.mem.readInt(u64, &serial_seed, .little));

    const home_directory = try homeDirectory(gpa, io, cwd, home);
    defer gpa.free(home_directory);
    self.working_directory = cwd;
    self.home_directory = home_directory;
    self.directory_label = try directoryLabel(gpa, cwd, home_directory);
    defer gpa.free(self.directory_label);

    self.project_instructions = try ai.instructions.discover(gpa, io, cwd);
    defer self.project_instructions.deinit();
    self.state = try State.open(gpa, io, &.{
        .working_directory = cwd,
        .home = home,
        .project = self.project_instructions.projectRoot() orelse cwd,
    });
    defer self.state.deinit();
    self.prompt_history = try PromptHistory.open(gpa, io, &.{
        .working_directory = cwd,
        .home = home,
        .enabled = config.prompt_history_enabled,
    });
    defer self.prompt_history.deinit();
    self.config_path = config.path;

    const user_skills = try std.fs.path.resolve(gpa, &.{ cwd, home, ".agents", "skills" });
    defer gpa.free(user_skills);
    self.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = cwd,
        .project_root = self.project_instructions.projectRoot(),
    });
    defer self.skills.deinit();
    self.skill_guard = .{ .working_directory = cwd };
    var skill_notices: std.ArrayList(ai.instructions.Notice) = .empty;
    defer {
        for (skill_notices.items) |notice| gpa.free(notice.text);
        skill_notices.deinit(gpa);
    }
    var required_missing: std.ArrayList(Config.RequiredSkill) = .empty;
    defer required_missing.deinit(gpa);
    try self.resolveRequiredSkills(&config, &skill_notices, &required_missing);
    self.prompt = try system_prompt.compose(gpa, &.{
        .core = system_prompt.default_core,
        .current_time = std.Io.Clock.real.now(io),
        .working_directory = cwd,
        .user_instructions = config.user_instructions.files(),
        .project_instructions = &self.project_instructions,
        .skills = self.skills.catalog(),
        .required_skills = self.skill_guard.rules(),
    });
    defer gpa.free(self.prompt);
    self.sources_page = try sources.compose(gpa, &.{
        .user_instructions = config.user_instructions.files(),
        .project_instructions = self.project_instructions.files(),
        .skills = &self.skills,
        .required_skills = self.skill_guard.rules(),
        .required_missing = required_missing.items,
        .roots = self.displayRoots(),
    });
    defer gpa.free(self.sources_page);
    self.document = try describe.compose(gpa, &.{
        .config = &config,
        .effort_default = effort_default,
        .key_hints = &intro_keys,
        .ctrl_c_window_ms = ctrl_c_window_ms,
    });
    defer gpa.free(self.document);

    const active = self.startAccount();
    const start_account = active orelse .anthropic_plan;
    const start_client = if (active) |account| self.accounts.client(account) else null;
    const start_model = self.accountModel(start_account);
    const start_effort = self.startEffort(config.default_effort);
    self.agent = ai.Agent.init(gpa, io, start_client, .{
        .model = start_model,
        .system = self.prompt,
        .retry = config.retry,
        .environ = options.environ,
        .effort = start_effort,
        .bash = config.bash,
        .document = self.document,
        .skill_guard = &self.skill_guard,
    });
    defer self.agent.deinit();
    if (active) |account| try self.state.seed(account, start_model, start_effort);

    try self.tty.init(io);
    defer self.tty.deinit();

    try self.resize.init();
    defer self.resize.deinit();

    self.session = Session.init(gpa, self.tty.writer(), self.agent.model, self.agent.effort);
    defer self.session.deinit();
    self.session.showSetup(active, self.agent.model, self.agent.effort);
    self.session.bash_timeout_ms = config.bash.timeout_ms;
    self.session.window_pages = config.window_pages;
    self.session.gauge = config.gauge;
    self.session.display_roots = self.displayRoots();
    self.showProject(options.herdr != null);

    try self.session.transcript.append(.intro, .{}, intro_text);
    if (config.dropped_effort) |dropped| try self.recordEvent(
        .failure,
        "Drinky ignored the configured default effort level \"{s}\" because Drinky does not " ++
            "know that level. Drinky uses the effort level \"{s}\".",
        .{ dropped, @tagName(self.agent.effort) },
    );
    if (config.dropped_bash_timeout_ms) |dropped| try self.recordEvent(
        .failure,
        "Drinky ignored the configured command timeout {d} because the value must be from {d} " ++
            "to {d} milliseconds. Drinky uses the default timeout of {d} milliseconds.",
        .{
            dropped,
            ai.tool.Context.Bash.timeout_ms_min,
            ai.tool.Context.Bash.timeout_ms_max,
            config.bash.timeout_ms,
        },
    );
    if (config.dropped_window_pages) |dropped| try self.recordEvent(
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
    if (config.dropped_gauge) |dropped| try self.recordEvent(
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
    try self.reportNotices(skill_notices.items);
    if (self.controller.loadError()) |err| try self.recordEvent(
        .failure,
        "Drinky could not read the saved bots in {s} because of error {s}.",
        .{ self.controller.storePath(), @errorName(err) },
    );
    for (config.unknown_keys) |key| try self.recordEvent(
        .failure,
        "Drinky ignored the unknown configuration key \"{s}\" in {s}.",
        .{ key, config.path },
    );
    if (config.unknown_keys_omitted) try self.recordEvent(
        .failure,
        "Drinky omitted the remaining unknown configuration keys in {s}.",
        .{config.path},
    );
    try self.reportNotices(config.user_instructions.notices());
    try self.reportNotices(self.project_instructions.notices());
    try self.reportNotices(self.skills.notices());
    if (!self.signedIn()) {
        try self.reportNotice(
            .information,
            "Select an account to sign in.",
            .{},
        );
        try self.runCommand("/login");
    }
    defer self.prepareTerminalExit();
    try self.refresh();
    self.frame_grid = .reset(self.nowNs());

    self.herdr.start(options.herdr);
    defer self.herdr.deinit();
    self.running = true;
    defer self.shutdownTasks();
    try self.startInputReader();
    self.resize_future = try self.io.concurrent(readResize, .{self});

    try self.runLoop();
}

fn initFields(self: *App, gpa: std.mem.Allocator, io: std.Io) void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .tty = undefined,
        .resize = undefined,
        .accounts = undefined,
        .agent = undefined,
        .session = undefined,
        .state = .inert(gpa, io),
        .prompt_history = .inert(gpa, io),
        .config_path = "",
        .directory_label = "",
        .working_directory = "",
        .home_directory = "",
        .project_instructions = .init(gpa, .project),
        .skills = .init(gpa),
        .prompt = "",
        .document = "",
        .sources_page = "",
        .skill_guard = .{},
        .input = .init(gpa),
        .running = false,
        .ctrl_c_ms_last = -ctrl_c_window_ms,
        .escape_deadline_ms = null,
        .queue = undefined,
        .queue_buffer = undefined,
        .deferred_events = undefined,
        .deferred_event_count = 0,
        .input_future = null,
        .resize_future = null,
        .turn_future = null,
        .pending_turn_result = null,
        .turn_generation = 0,
        .fetch = null,
        .fetch_generation = 0,
        .login = null,
        .login_generation = 0,
        .retry = null,
        .turn_retry = false,
        .revision = null,
        .tick_future = null,
        .tick_pending = false,
        .frame_grid = .reset(0),
        .herdr = .init(io),
        .controller = .init(gpa, io, &.{
            .store = .inert(gpa, io),
            .sink = .{ .context = self, .act = onRemoteAction },
            .attachment_sink = .{ .context = self, .emit = emitRemoteEvent },
            .pairing_sink = .{ .context = self, .emit = emitPairingEvent },
        }),
        .mirror = .init(gpa),
        .chat_picker = .init(gpa),
        .remote_title = "",
        .pairing_wait_text = "",
        .pairing_wait_link = "",
        .prompt_marked = false,
        .steering_marked_count = 0,
    };
    self.queue = std.Io.Queue(UiEvent).init(&self.queue_buffer);
}

fn prepareTerminalExit(self: *App) void {
    self.tty.setAlternateScreen(false) catch return;
    self.session.parkCursor() catch {};
}

fn shutdownTasks(self: *App) void {
    self.queue.close(self.io);
    self.controller.shutdown();
    self.chat_picker.deinit();
    self.freeRemoteStrings();
    self.dropRetry();
    self.dropRevision();
    if (self.cancelTurnFuture()) |result| self.freeWorkerResult(&result);
    if (self.pending_turn_result) |result| {
        self.freeWorkerResult(&result);
        self.pending_turn_result = null;
    }
    self.dropFetch();
    self.dropLogin();
    self.cancelFuture(&self.input_future);
    self.cancelFuture(&self.resize_future);
    self.cancelFuture(&self.tick_future);
    self.drainQueue();
}

fn cancelTurnFuture(self: *App) ?WorkerResult {
    if (self.turn_future) |*future| {
        const result = future.cancel(self.io);
        self.turn_future = null;
        return result;
    }
    return null;
}

fn awaitTurnFuture(self: *App) ?WorkerResult {
    if (self.turn_future) |*future| {
        const result = future.await(self.io);
        self.turn_future = null;
        return result;
    }
    return null;
}

fn takeTurnResult(self: *App) ?WorkerResult {
    if (self.awaitTurnFuture()) |result| return result;
    if (self.pending_turn_result) |result| {
        self.pending_turn_result = null;
        return result;
    }
    return null;
}

fn enqueuePendingTurnFence(self: *App) void {
    const result = if (self.pending_turn_result) |*pending| pending else return;
    if (result.terminal_queued) return;
    if (result.progress_sequence == std.math.maxInt(u64)) return;
    const events = [1]UiEvent{.{ .turn = .{
        .generation = result.generation,
        .progress_sequence = result.progress_sequence + 1,
        .progress_sequence_committed = result.progress_sequence_committed,
        .payload = .turn_ended,
    } }};
    const count = self.queue.put(self.io, &events, 0) catch return;
    if (count == 1) result.terminal_queued = true;
}

fn freeWorkerResult(self: *App, result: *const WorkerResult) void {
    if (result.error_text) |text| self.gpa.free(text);
}

fn finishWorkerResult(self: *App, result: *const WorkerResult) !void {
    self.session.stats_shown = self.agent.stats;
    self.refreshBranch();
    try self.settleChatMessages(&result.outcome.receipt);
    switch (result.outcome.disposition) {
        .completed => {
            _ = self.takeTurnRetry();
            try self.session.endTurnWithReceipt(&result.outcome.receipt);
            try self.endMirrorTurn(.completed);
            if (self.session.hasSteering()) try self.returnLateSteering();
        },
        .credential_replaced => {
            const account = self.activeAccount() orelse
                return error.UnexpectedCredentialReplacement;
            if (!account.hasRefreshCredential())
                return error.UnexpectedCredentialReplacement;
            try self.finishFailedWorker(result);
            try self.acceptCredentialReplacement(account);
        },
        .credential_rejected => {
            const account = self.activeAccount() orelse
                return error.UnexpectedTokenGrantRejection;
            if (!account.hasRefreshCredential())
                return error.UnexpectedTokenGrantRejection;
            try self.controller.detach(.credential_rejected);
            try self.finishFailedWorker(result);
            try self.rejectCredential(account);
        },
        .failed => try self.finishFailedWorker(result),
        .canceled, .closed => return error.UnexpectedTurnDisposition,
    }
}

fn finishFailedWorker(self: *App, result: *const WorkerResult) !void {
    const attempt = self.takeTurnRetry();
    try self.session.reserveFailureRestore(&result.outcome.receipt);
    defer self.agent.steering.clear();
    try self.session.failTurnWithReceipt(&result.outcome.receipt, result.error_text);
    try self.armRetry(result, attempt);
    try self.endMirrorTurn(.failed);
}

fn armRetry(self: *App, result: *const WorkerResult, attempt: bool) !void {
    const receipt = &result.outcome.receipt;
    const committed = receipt.history_end != receipt.history_base;
    if (!committed and !attempt) return;
    const failure = try self.gpa.dupe(
        u8,
        result.error_text orelse "Drinky could not complete the turn.",
    );
    self.setRetry(.{ .failure = failure });
}

fn setRetry(self: *App, retry: Retry) void {
    self.dismissOffer();
    self.retry = retry;
    self.session.prompt_offer = .retry;
    self.session.dirty = true;
}

fn setRevision(self: *App, revision: Revision) void {
    self.dismissOffer();
    self.revision = revision;
    self.session.prompt_offer = .revision;
    self.session.dirty = true;
}

fn dismissOffer(self: *App) void {
    std.debug.assert(self.retry == null or self.revision == null);
    if (self.retry != null) self.mirror.dismissRetry(&self.controller) catch {};
    self.dropRetry();
    self.dropRevision();
    self.session.cancelConfirmation(.revision);
    self.session.prompt_offer = .none;
    self.session.dirty = true;
}

fn takeTurnRetry(self: *App) bool {
    defer self.turn_retry = false;
    return self.turn_retry;
}

fn dropRetry(self: *App) void {
    const retry = self.retry orelse return;
    retry.deinit(self.gpa);
    self.retry = null;
}

fn dropRevision(self: *App) void {
    const revision = if (self.revision) |*revision| revision else return;
    revision.deinit(self.gpa);
    self.revision = null;
}

fn clearRetry(self: *App) void {
    if (self.retry == null) return;
    self.dismissOffer();
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
    for (self.deferred_events[0..self.deferred_event_count]) |event| event.deinit(self.gpa);
    self.deferred_event_count = 0;
}

fn takeDeferredEvents(self: *App, batch: *[queue_capacity]UiEvent) usize {
    const count = self.deferred_event_count;
    @memcpy(batch[0..count], self.deferred_events[0..count]);
    self.deferred_event_count = 0;
    return count;
}

fn runLoop(self: *App) !void {
    var batch: [queue_capacity]UiEvent = undefined;
    while (self.running) {
        const count = if (self.deferred_event_count > 0)
            self.takeDeferredEvents(&batch)
        else
            self.queue.get(self.io, &batch, 1) catch |err| switch (err) {
                error.Closed, error.Canceled => break,
            };
        self.enqueuePendingTurnFence();
        const ticked = try self.applyBatch(batch[0..count]);
        self.herdr.sync(self.herdrState());
        try self.flushEscape();
        if (ticked) {
            self.tick_pending = false;
            self.awaitFuture(&self.tick_future);
            if (self.session.advanceFrame()) {
                try self.refresh();
                self.session.dirty = false;
            }
        }
        const waiting = self.session.dirty or
            self.session.animating() or
            self.escape_deadline_ms != null;
        if (waiting and !self.tick_pending) self.armTick();
    }
}

fn herdrState(self: *const App) Herdr.State {
    std.debug.assert(self.retry == null or self.revision == null);
    if (self.session.mode == .turn) return .working;
    if (self.retry != null or self.revision != null) return .blocked;
    return .idle;
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
            .resize => self.session.dirty = true,
            .keys => |bytes| {
                defer self.gpa.free(bytes);
                self.refreshBranch();
                try self.handleKeys(bytes);
            },
            .turn => |*turn_event| {
                const turn_finished = try self.session.applyTurnEvent(turn_event);
                try self.markCommittedChatMessages();
                if (turn_finished) {
                    const result = self.takeTurnResult() orelse return error.MissingTurnWorker;
                    defer self.freeWorkerResult(&result);
                    try self.finishWorkerResult(&result);
                }
            },
            .fetch_ended => |generation| try self.finishFetch(generation),
            .login => |*login_event| try self.applyLoginEvent(login_event),
            .remote => |*remote_event| try self.controller.applyAttachmentEvent(remote_event),
            .pairing => |*pairing_event| try self.controller.applyPairingEvent(pairing_event),
        }
        try self.syncMirror();
    }
    return ticked;
}

fn armTick(self: *App) void {
    self.frame_grid.advance(self.nowNs());
    const deadline_ns = self.frame_grid.deadline_ns;
    self.tick_future = self.io.concurrent(frameTimer, .{ self, deadline_ns }) catch {
        self.refresh() catch {};
        self.session.dirty = false;
        self.frame_grid = .reset(self.nowNs());
        return;
    };
    self.tick_pending = true;
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
        const result = self.tty.read(&buffer, .none) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                self.queue.close(self.io);
                return;
            },
        };
        const count = result orelse continue;
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

fn turnFailureText(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoModel => no_model_refusal,
        error.UnsupportedReply => "Drinky cannot keep the response because the model returned " ++
            "a refusal, a pause, or an unsupported result.",
        error.EmptyReply => "The model returned an empty response.",
        error.IncompleteReply => "Drinky did not receive the complete model response.",
        error.UncorrelatedReply => "Drinky could not match a streamed part of the response to " ++
            "the item it belongs to. The provider changed the order of its stream.",
        error.TooManyToolCalls => std.fmt.comptimePrint(
            "Drinky stopped the reply because it asked for more than {d} tool calls.",
            .{ai.Agent.tool_calls_max},
        ),
        error.TooManyToolRounds => "The turn reached the limit for tool rounds.",
        error.CredentialReplaced => "Drinky found a replacement credential for this account. " ++
            "Drinky removed the prior account evidence.",
        error.TokenGrantRejected => "The provider rejected the refresh credential.",
        error.KeyRejected => "Google rejected the service account key.",
        error.TokenRequestFailed => "The provider did not accept the token request. " ++
            "Drinky kept this account signed in.",
        error.TokenServiceUnavailable => "The provider credential service is not available. " ++
            "Try the turn again.",
        error.StoreBusy => "Another Drinky instance is writing the credential file. " ++
            "Try the turn again.",
        else => null,
    };
}

fn runTurnWorker(self: *App, text: []const u8, generation: u64) WorkerResult {
    defer self.gpa.free(text);
    var handler: TurnHandler = .{ .app = self, .generation = generation };
    const outcome = self.agent.run(text, &handler);
    const maybe_failure: ?anyerror = switch (outcome.disposition) {
        .canceled, .closed => return .{
            .outcome = outcome,
            .error_text = handler.error_text,
            .generation = generation,
            .progress_sequence = handler.progress_sequence,
            .progress_sequence_committed = handler.progress_sequence_committed,
            .terminal_queued = false,
        },
        .completed => null,
        .credential_replaced => error.CredentialReplaced,
        .credential_rejected => error.TokenGrantRejected,
        .failed => |failure| failure,
    };
    if (maybe_failure) |failure| {
        if (handler.error_text == null)
            handler.error_text = if (turnFailureText(failure)) |sentence|
                self.gpa.dupe(u8, sentence) catch null
            else
                std.fmt.allocPrint(
                    self.gpa,
                    "Drinky could not complete the turn because of error {s}.",
                    .{@errorName(failure)},
                ) catch null;
    }
    const terminal_queued = queued: {
        handler.enqueue(.turn_ended) catch break :queued false;
        break :queued true;
    };
    return .{
        .outcome = outcome,
        .error_text = handler.error_text,
        .generation = generation,
        .progress_sequence = handler.progress_sequence,
        .progress_sequence_committed = handler.progress_sequence_committed,
        .terminal_queued = terminal_queued,
    };
}

fn activeAccount(self: *const App) ?ai.llm.Account {
    const client = self.agent.client orelse return null;
    return client.account();
}

fn signedIn(self: *const App) bool {
    return self.activeAccount() != null;
}

fn startAccount(self: *const App) ?ai.llm.Account {
    if (self.state.start.account) |account| {
        if (self.accounts.isAuthenticated(account)) return account;
    }
    return self.accounts.firstAuthenticated();
}

fn accountModel(self: *const App, account: ai.llm.Account) ?ai.Model {
    const remembered = self.state.models.get(account) orelse return null;
    return self.accounts.findModel(account, remembered.name());
}

fn startEffort(self: *const App, configured: ?ai.llm.Effort) ai.llm.Effort {
    return self.state.start.effort orelse configured orelse effort_default;
}

fn handleKeys(self: *App, bytes: []const u8) !void {
    try self.input.feed(bytes);
    while (self.input.next()) |event| {
        const at_prompt = self.session.mode == .prompt;
        const owner = self.session.input.owner;
        const login_generation = if (self.login) |login| login.generation else null;
        try self.handleKey(&event);
        const current_login_generation = if (self.login) |login| login.generation else null;
        const returned = (!at_prompt and self.session.mode == .prompt) or
            owner != self.session.input.owner or
            login_generation != current_login_generation;
        if (returned and isExitKey(&event)) {
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
    const at_prompt = self.session.mode == .prompt;
    const editor_live = self.session.input.owner == .terminal and self.login == null;
    const confirms_message = editor_live and (at_prompt or self.session.mode == .turn) and
        event.* == .enter;
    if (!confirms_message) self.session.cancelConfirmation(.message);
    const confirms_turn_cancel = editor_live and self.session.mode == .turn and event.* == .escape;
    if (!confirms_turn_cancel) self.session.cancelConfirmation(.turn_cancel);
    const confirms_quit = editor_live and at_prompt and event.* == .ctrl and event.ctrl == 'd';
    if (!confirms_quit) self.session.cancelConfirmation(.quit);
    const confirms_revision = editor_live and at_prompt and event.* == .ctrl and event.ctrl == 'n';
    if (!confirms_revision) self.session.cancelConfirmation(.revision);
    if (event.* == .escape and self.session.mode == .turn and editor_live) {
        if (self.session.notice != null and !self.session.confirmations.contains(.turn_cancel)) {
            self.session.clearNotice();
            return;
        }
    }
    self.session.clearNotice();
    if (self.login != null) return self.handleLoginKey(event);
    switch (self.session.mode) {
        .picking => return self.handlePickerKey(event),
        .viewing => return self.handlePageKey(event),
        .turn, .prompt => {},
    }
    if (!editor_live) return self.handleExternalKey(event);
    if (self.controller.state() == .token_prompt) return self.handleTokenKey(event);
    if (self.controller.pairs()) return self.handlePairingKey(event);
    if (self.session.mode == .turn) return self.handleTurnKey(event);
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submit(),
        .tab => try self.openPromptHistory(),
        .escape => self.dismissOffer(),
        .ctrl => |letter| switch (letter) {
            'c' => {
                self.clearOrQuit();
                if (self.running) self.session.dirty = true;
            },
            'd' => if (self.session.editor.visible().len == 0 or
                self.session.takeConfirmation(.quit))
            {
                self.running = false;
            } else {
                self.session.armConfirmation(.quit);
                try self.reportNotice(
                    .warning,
                    "Press Ctrl+D again to quit. The quit discards the draft.",
                    .{},
                );
            },
            'n' => switch (self.session.prompt_offer) {
                .none => {},
                .retry => try self.retryTurn(),
                .revision => try self.reviseTurn(),
            },
            else => {},
        },
        else => {},
    }
}

fn editKey(self: *App, event: *const terminal.Input.Key) !bool {
    const editor = &self.session.editor;
    switch (event.*) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .paste => |paste| try editor.paste(paste.bytes, paste.final),
        .backspace => editor.backspace(),
        .left => editor.moveLeft(),
        .right => editor.moveRight(),
        .up => editor.moveUp(self.session.columns),
        .down => editor.moveDown(self.session.columns),
        .home => editor.moveHome(),
        .end => editor.moveEnd(),
        .newline => try editor.insert("\n"),
        .ctrl => |letter| switch (letter) {
            'j' => try editor.insert("\n"),
            else => return false,
        },
        else => return false,
    }
    self.session.markEdited();
    return true;
}

fn handleLoginKey(self: *App, event: *const terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submitLoginLine(),
        .escape => try self.cancelLogin(),
        .ctrl => |letter| switch (letter) {
            'c' => if (self.session.editor.visible().len != 0) {
                self.session.editor.clear();
                self.session.markEdited();
            } else {
                try self.cancelLogin();
            },
            'd' => try self.cancelLogin(),
            else => {},
        },
        else => {},
    }
}

fn submitLoginLine(self: *App) !void {
    const login = if (self.login) |*login| login else return;
    const text = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(text);
    const account = login.attempt.account;
    const callback = login.callback orelse return self.reportNotice(
        .warning,
        "The sign-in to {s} does not accept a callback URL. Complete the sign-in in the browser.",
        .{account.id()},
    );
    const accepted = switch (callback.binding) {
        .state => ai.oauth_callback.holdsStateRedirect(text),
        .path => if (login.callback_path) |callback_path|
            ai.oauth_callback.holdsPathRedirect(&.{ .line = text, .path = callback_path })
        else
            false,
    };
    if (!accepted) return self.reportNotice(
        .warning,
        "The line is not the callback URL for the sign-in to {s}. " ++
            "Paste the complete callback URL from the browser.",
        .{account.id()},
    );
    ai.oauth_callback.replay(self.io, callback.port, text) catch |err| switch (err) {
        error.ConnectionRefused => {
            self.session.editor.clear();
            self.session.markEdited();
            return self.reportNotice(
                .information,
                "Drinky already received the response for the sign-in to {s}.",
                .{account.id()},
            );
        },
        else => return self.reportNotice(
            .failure,
            "Drinky could not replay the callback URL for the sign-in to {s} " ++
                "because of error {s}.",
            .{ account.id(), @errorName(err) },
        ),
    };
    self.session.editor.clear();
    self.session.markEdited();
}

fn handleTurnKey(self: *App, event: *const terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submitSteering(),
        .tab => try self.reportNotice(.information, prompt_history_turn_notice, .{}),
        .escape => try self.warnOrCancel(),
        .ctrl => |letter| switch (letter) {
            'c' => try self.clearOrCancel(),
            'd' => try self.cancelTurn(),
            'p' => try self.pullSteering(),
            else => {},
        },
        else => {},
    }
}

fn warnOrCancel(self: *App) !void {
    if (self.session.editor.visible().len == 0 or self.session.takeConfirmation(.turn_cancel))
        return self.cancelTurn();
    self.session.armConfirmation(.turn_cancel);
    try self.reportNotice(.warning, turn_cancel_notice, .{});
}

fn clearOrCancel(self: *App) !void {
    if (self.session.editor.visible().len != 0) {
        self.session.editor.clear();
        self.session.markEdited();
        return;
    }
    try self.cancelTurn();
}

fn submitSteering(self: *App) !void {
    if (self.session.editor.blank()) {
        self.session.cancelConfirmation(.message);
        return;
    }
    const text = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(text);
    if (!self.session.takeConfirmation(.message)) {
        if (ai.command.parse(text)) |name| {
            if (try self.checkCommand(text)) |refusal|
                return self.armMessageSend(refusal, "Queue as a message");
            if (ai.command.runsDuringTurn(name)) {
                if (try self.dispatchCommand(text)) |outcome|
                    return self.applySubmittedCommand(outcome);
            }
            return self.refuseCommand(name, "while a turn runs");
        }
    }
    try self.session.reserveSteering();
    try self.agent.steering.push(text);
    var draft = self.session.editor.detachTrimmed();
    self.session.commitSteeringDraft(&draft);
    self.session.dirty = true;
}

fn pullSteering(self: *App) !void {
    _ = try self.withdrawSteering();
}

fn returnLateSteering(self: *App) !void {
    try self.session.reserveSteeringRecall();
    const taken = try self.agent.steering.take();
    defer {
        for (taken) |message| self.gpa.free(message);
        self.gpa.free(taken);
    }
    std.debug.assert(taken.len == self.session.steering.items.len);
    if (self.session.recallLateSteering() == 0) return;
    try self.reportNotice(.information, "Drinky returned every queued message to the editor.", .{});
}

fn cancelTurn(self: *App) !void {
    try self.session.reserveSteeringRestore();
    try self.session.reserveRevisionCapture();
    const result = self.cancelTurnFuture() orelse return;
    switch (result.outcome.disposition) {
        .canceled => {
            defer self.freeWorkerResult(&result);
            _ = self.takeTurnRetry();
            const receipt = &result.outcome.receipt;
            const committed = receipt.history_end != receipt.history_base;
            var maybe_progress_error = self.drainCanceledProgress(committed);
            self.session.stats_shown = self.agent.stats;
            self.refreshBranch();
            try self.settleChatMessages(receipt);
            var maybe_capture: ?Session.RevisionCapture = null;
            if (committed and self.session.input.owner == .terminal)
                maybe_capture = self.session.takeCanceledRevision(receipt);
            self.session.cancelReceipt(receipt, result.progress_sequence_committed);
            self.agent.steering.clear();
            if (committed) {
                const aborted = self.session.abortTurn();
                if (maybe_capture) |capture| self.setRevision(.{
                    .history = .{ .base = receipt.history_base, .end = receipt.history_end },
                    .transcript_base = capture.transcript_base,
                    .transcript_end = self.session.transcript.blocks().len,
                    .prompt = capture.prompt,
                    .steering = capture.steering,
                    .mutated = capture.mutated,
                });
                aborted catch |err| {
                    if (maybe_progress_error == null) maybe_progress_error = err;
                };
            } else {
                std.debug.assert(maybe_capture == null);
                self.session.endTurn();
            }
            try self.endMirrorTurn(.canceled);
            if (maybe_progress_error) |progress_error| return progress_error;
        },
        .completed, .credential_replaced, .credential_rejected, .failed => {
            std.debug.assert(self.pending_turn_result == null);
            self.pending_turn_result = result;
            self.enqueuePendingTurnFence();
        },
        .closed => {
            defer self.freeWorkerResult(&result);
            _ = self.takeTurnRetry();
            try self.session.endTurnWithReceipt(&result.outcome.receipt);
            try self.endMirrorTurn(.canceled);
        },
    }
}

fn drainCanceledProgress(self: *App, apply_progress: bool) ?anyerror {
    if (self.deferred_event_count > 0) return null;

    var batch: [queue_capacity]UiEvent = undefined;
    const count = self.queue.get(self.io, &batch, 0) catch return null;
    std.debug.assert(self.deferred_event_count + count <= self.deferred_events.len);

    var maybe_apply_error: ?anyerror = null;
    for (batch[0..count]) |*event| switch (event.*) {
        .turn => |*turn_event| {
            if (apply_progress and maybe_apply_error == null) {
                self.session.applyCanceledTurnEvent(turn_event) catch |err| {
                    maybe_apply_error = err;
                    continue;
                };
            } else {
                turn_event.deinit(self.gpa);
            }
        },
        else => {
            self.deferred_events[self.deferred_event_count] = event.*;
            self.deferred_event_count += 1;
        },
    };
    return maybe_apply_error;
}

fn clearOrQuit(self: *App) void {
    const now = self.nowMs();
    if (now - self.ctrl_c_ms_last < ctrl_c_window_ms) {
        self.running = false;
    } else {
        self.session.editor.clear();
        self.ctrl_c_ms_last = now;
    }
}

fn refresh(self: *App) !void {
    const size: terminal.View.Size = if (self.tty.size()) |window|
        .{ .columns = window.columns, .rows = window.rows }
    else
        .{ .columns = self.session.columns, .rows = self.session.rows };
    try self.tty.setAlternateScreen(self.session.mode == .viewing);
    self.session.clock_ms = self.nowMs();
    self.session.boot_clock_ms = self.nowBootMs();
    try self.session.paint(size);
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
    if (self.session.editor.blank()) {
        self.session.cancelConfirmation(.message);
        return;
    }
    const text = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(text);
    self.session.dirty = true;

    const message_confirmed = self.session.takeConfirmation(.message);
    if (!message_confirmed) {
        if (try self.checkCommand(text)) |refusal|
            return self.armMessageSend(refusal, "Send as a message");
        if (try self.dispatchCommand(text)) |outcome|
            return self.applySubmittedCommand(outcome);
    }
    if (!self.signedIn()) return self.reportNotice(
        .failure,
        "Sign in with /login before you send a message.",
        .{},
    );
    if (self.agent.model == null) return self.reportNotice(.failure, no_model_refusal, .{});
    const base = try self.startUserTurn(text);
    var prompt = self.session.editor.detachTrimmed();
    self.session.retainTurnPrompt(&prompt, base);
    try self.recordPromptHistory(text);
}

fn applySubmittedCommand(self: *App, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .prompt => |prompt| {
            defer prompt.deinit(self.gpa);
            if (!self.signedIn()) {
                try self.reportNotice(
                    .failure,
                    "Sign in with /login before you send a message.",
                    .{},
                );
            } else if (self.agent.model == null) {
                try self.reportNotice(.failure, no_model_refusal, .{});
            } else {
                const base = try self.startSkillTurn(&prompt);
                var draft = self.session.editor.detachTrimmed();
                self.session.retainTurnPrompt(&draft, base);
            }
        },
        .refusal => try self.applyOutcome(outcome),
        else => {
            self.session.editor.clear();
            try self.applyOutcome(outcome);
        },
    }
}

fn armMessageSend(
    self: *App,
    refusal: ai.command.Outcome.Message,
    action: []const u8,
) !void {
    defer self.gpa.free(refusal.content);
    try self.reportNotice(refusal.severity, "Enter: {s} · {s}", .{ action, refusal.content });
    self.session.armConfirmation(.message);
}

fn startSkillTurn(self: *App, prompt: *const ai.command.Outcome.Prompt) !usize {
    const base = try self.appendSkillPrompt(prompt);
    errdefer self.session.transcript.truncate(base);
    try self.runTurn(prompt.content);
    self.session.dirty = true;
    return base;
}

fn appendSkillPrompt(self: *App, prompt: *const ai.command.Outcome.Prompt) !usize {
    const base = self.session.transcript.blocks().len;
    errdefer self.session.transcript.truncate(base);
    const head = try self.skillHead(prompt);
    defer self.gpa.free(head);
    try self.session.transcript.append(.user_note, .{}, head);
    if (prompt.arguments.len > 0)
        try self.session.transcript.append(.user, .{}, prompt.arguments);
    return base;
}

fn skillHead(self: *App, prompt: *const ai.command.Outcome.Prompt) ![]u8 {
    const source = try ai.format.path(self.gpa, prompt.source, &self.displayRoots());
    defer self.gpa.free(source);
    return std.fmt.allocPrint(self.gpa, "Skill: {s} · File: {s}", .{ prompt.name, source });
}

fn displayRoots(self: *const App) ai.format.Roots {
    return .{ .working_directory = self.working_directory, .home_directory = self.home_directory };
}

fn startUserTurn(self: *App, text: []const u8) !usize {
    const base = self.session.transcript.blocks().len;
    try self.session.transcript.append(.user, .{}, text);
    errdefer self.session.transcript.truncate(base);
    try self.runTurn(text);
    self.session.dirty = true;
    return base;
}

fn retryTurn(self: *App) !void {
    if (self.retry == null) return;
    if (!self.signedIn()) return self.reportNotice(
        .failure,
        "Sign in with /login before you try the turn again.",
        .{},
    );
    if (self.agent.model == null) return self.reportNotice(.failure, no_model_refusal, .{});
    return self.sendRetryTurn();
}

fn sendRetryTurn(self: *App) !void {
    const base = try self.startRetryTurn();
    self.session.markTurnBase(base);
}

fn startRetryTurn(self: *App) !usize {
    std.debug.assert(self.retry != null);
    const retry = &self.retry.?;
    const text = try retry.compose(self.gpa);
    defer self.gpa.free(text);
    const base = self.session.transcript.blocks().len;
    errdefer self.session.transcript.truncate(base);
    try self.session.transcript.append(.user_note, .{}, Retry.note_text);
    try self.runTurn(text);
    self.turn_retry = true;
    return base;
}

const revision_warning = "Press Ctrl+N again to remove the canceled turn. Tool changes stay.";

fn reviseTurn(self: *App) !void {
    std.debug.assert(self.session.mode == .prompt);
    const revision = if (self.revision) |*revision| revision else return;
    if (revision.mutated and !self.session.takeConfirmation(.revision)) {
        try self.reportNotice(.warning, revision_warning, .{});
        self.session.armConfirmation(.revision);
        return;
    }
    try self.session.editor.reserveComposition(&revision.prompt, revision.steering.items);
    std.debug.assert(revision.transcript_base <= revision.transcript_end);
    std.debug.assert(revision.transcript_end <= self.session.transcript.blocks().len);
    const cursor = self.mirror.transcriptCursor();
    self.agent.rewindHistory(revision.history);

    var taken = self.revision.?;
    self.revision = null;
    defer taken.deinit(self.gpa);
    self.session.stats_shown = self.agent.stats;
    const removal = self.session.removeTurn(.{
        .range_base = taken.transcript_base,
        .range_end = taken.transcript_end,
        .mirror_cursor = cursor,
    });
    self.mirror.retreat(removal.removed_before_cursor_count);
    self.session.editor.prependComposition(&taken.prompt, taken.steering.items);
    self.session.markEdited();
    self.dismissOffer();
}

fn sendShortenTurn(self: *App) !void {
    const base = self.session.transcript.blocks().len;
    errdefer self.session.transcript.truncate(base);
    try self.session.transcript.append(.user_note, .{}, shorten_note_text);
    try self.runTurn(shorten_request_text);
    self.session.markTurnBase(base);
}

fn runTurn(self: *App, text: []const u8) !void {
    std.debug.assert(self.turn_future == null);
    std.debug.assert(self.pending_turn_result == null);
    self.refreshBranch();
    const generation = try reserveGeneration(&self.turn_generation);
    const owned = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(owned);
    self.turn_future = try self.io.concurrent(runTurnWorker, .{ self, owned, generation });
    self.session.beginTurn(generation);
    self.prompt_marked = false;
    self.steering_marked_count = 0;
    self.dismissOffer();
    self.chat_picker.close();
    self.mirror.beginTurn(&self.controller, self.nowMs()) catch {};
}

fn reserveGeneration(counter: *u64) error{GenerationExhausted}!u64 {
    if (counter.* == std.math.maxInt(u64)) return error.GenerationExhausted;
    counter.* += 1;
    return counter.*;
}

fn startFetch(self: *App, account: ai.llm.Account) !void {
    std.debug.assert(self.fetch == null);
    std.debug.assert(self.session.mode == .picking);
    const generation = try reserveGeneration(&self.fetch_generation);
    const future = try self.io.concurrent(runFetchWorker, .{ self, account, generation });
    self.fetch = .{ .future = future, .account = account, .generation = generation };
    errdefer self.dropFetch();
    try self.session.beginPickerWait(fetch_wait_text);
}

fn runFetchWorker(self: *App, account: ai.llm.Account, generation: u64) ai.Accounts.Refresh {
    const result = self.accounts.refresh(account);
    self.queue.putOne(self.io, .{ .fetch_ended = generation }) catch {};
    return result;
}

fn finishFetch(self: *App, generation: u64) !void {
    const fetch = if (self.fetch) |*fetch| fetch else return;
    if (fetch.generation != generation) return;
    const account = fetch.account;
    const result = fetch.future.await(self.io);
    self.fetch = null;
    std.debug.assert(self.session.pickerWaits());
    var context = self.commandContext();
    const outcome = try ai.command.model.fetchOutcome(&context, account, &result);
    if (!keepsPicker(outcome)) self.session.closePicker();
    try self.applyOutcome(outcome);
}

fn cancelFetch(self: *App) !void {
    self.dropFetch();
    const opener = self.session.mode.picking.reopen orelse return self.session.cancelPicker();
    var context = self.commandContext();
    const outcome = try opener(&context);
    if (!keepsPicker(outcome)) self.session.closePicker();
    try self.applyOutcome(outcome);
    try self.reportNotice(.information, "You canceled the model fetch.", .{});
}

fn dropFetch(self: *App) void {
    const fetch = if (self.fetch) |*fetch| fetch else return;
    _ = fetch.future.cancel(self.io);
    self.fetch = null;
}

fn commandContext(self: *App) ai.command.Context {
    return .{
        .gpa = self.gpa,
        .io = self.io,
        .agent = &self.agent,
        .accounts = &self.accounts,
        .remembered_models = &self.state.models,
        .skill_registry = &self.skills,
        .remote_bots = self.controller.usernames(),
    };
}

fn chatContext(self: *App) ai.command.Context {
    var context = self.commandContext();
    context.remote = true;
    return context;
}

fn dispatchCommand(self: *App, line: []const u8) !?ai.command.Outcome {
    var context = self.commandContext();
    return ai.command.run(&context, line);
}

fn checkCommand(self: *App, line: []const u8) !?ai.command.Outcome.Message {
    var context = self.commandContext();
    return ai.command.check(&context, line);
}

fn runCommand(self: *App, line: []const u8) !void {
    if (try self.dispatchCommand(line)) |outcome| try self.applyOutcome(outcome);
}

fn applyOutcome(self: *App, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .show_system_prompt => try self.session.openPage(&.{
            .title = "System prompt",
            .content = self.prompt,
        }),
        .show_sources => try self.session.openPage(&.{
            .title = "Sources",
            .content = self.sources_page,
        }),
        .new_conversation => {
            self.agent.resetConversation();
            self.session.clearConversation();
            self.mirror.restart();
            self.chat_picker.close();
            try self.session.transcript.append(.intro, .{}, intro_text);
            self.dismissOffer();
            if (self.controller.listens()) try self.recordEvent(
                .information,
                "You cleared the conversation while @{s} is attached.",
                .{self.controller.botUsername().?},
            );
        },
        .prompt => unreachable,
        .login_picker => {
            try self.rereadAccounts();
            try self.openLoginPicker();
        },
        .login => |account| return self.startLogin(account),
        .logout => |account| try self.logoutAccount(account),
        .switch_account => |account| {
            self.adopt(account);
            if (self.agent.model) |model| {
                try self.recordEvent(
                    .information,
                    "Drinky now uses {s}/{s}.",
                    .{ account.id(), model.name() },
                );
            } else {
                try self.reportModelStep(account, "Drinky now uses {s}. ", .{account.id()});
            }
        },
        .credential_replaced => |account| return self.acceptFetchReplacement(account),
        .fetch => |account| return self.startFetch(account),
        .show_status => return self.recordStatus(),
        .remote_attach => |index| return self.controller.attachSaved(index),
        .remote_add => {
            self.session.editor.clear();
            return self.controller.beginTokenPrompt();
        },
        .remote_remove => |index| return self.controller.removeBot(index),
        else => try self.session.applyOutcome(outcome),
    }
    try self.mirrorAgentState();
}

fn mirrorAgentState(self: *App) !void {
    self.session.stats_shown = self.agent.stats;
    self.session.showSetup(self.activeAccount(), self.agent.model, self.agent.effort);
    try self.recordState();
}

fn recordState(self: *App) !void {
    const account = self.activeAccount() orelse return;
    self.state.record(account, self.agent.model, self.agent.effort) catch |err|
        try self.reportStateSaveFailure(err);
}

fn reportStateSaveFailure(self: *App, err: anyerror) !void {
    switch (err) {
        error.StoreBusy => try self.recordEvent(
            .failure,
            "Drinky could not save the choices of this project because another Drinky instance " ++
                "is writing the state file. Drinky tries again at the next save.",
            .{},
        ),
        error.CorruptStore => try self.recordEvent(
            .failure,
            "Drinky stopped saving the choices of this project because Drinky cannot read the " ++
                "file {s} as a JSON object. Delete that file to let the next start save again.",
            .{self.state.path},
        ),
        else => try self.recordEvent(
            .failure,
            "Drinky stopped saving the choices of this project to {s} because of error {s}.",
            .{ self.state.path, @errorName(err) },
        ),
    }
}

fn startLogin(self: *App, account: ai.llm.Account) !void {
    std.debug.assert(self.login == null);
    std.debug.assert(self.fetch == null);
    std.debug.assert(self.session.mode == .prompt);
    const title = try std.fmt.allocPrint(self.gpa, "Sign in: {s}", .{account.id()});
    errdefer self.gpa.free(title);
    const generation = try reserveGeneration(&self.login_generation);
    const future = try self.io.concurrent(runLoginWorker, .{ self, account, generation });
    self.login = .{
        .future = future,
        .callback = ai.Accounts.callback(account),
        .generation = generation,
        .title = title,
        .attempt = .{ .account = account },
    };
    self.syncInputState();
}

fn runLoginWorker(self: *App, account: ai.llm.Account, generation: u64) LoginWorkerResult {
    var prompt: LoginPrompt = .{ .app = self, .generation = generation };
    const outcome: LoginWorkerResult.Outcome = if (self.accounts.login(account, &prompt)) |login|
        .{ .completed = login }
    else |err|
        .{ .failed = err };
    self.queue.putOne(self.io, .{ .login = .{
        .generation = generation,
        .payload = .ended,
    } }) catch {};
    return .{ .account = account, .generation = generation, .outcome = outcome };
}

fn applyLoginEvent(self: *App, event: *const LoginEvent) !void {
    defer event.deinit(self.gpa);
    const login = if (self.login) |*login| login else return;
    if (event.generation != login.generation) return;
    switch (event.payload) {
        .authorization => |authorization| {
            try self.recordLoginAuthorization(login.attempt.account, &authorization);
            login.attempt.event_index = self.session.transcript.blocks().len - 1;
            if (authorization.callback_path) |callback_path| {
                const owned = try self.gpa.dupe(u8, callback_path);
                if (login.callback_path) |previous| self.gpa.free(previous);
                login.callback_path = owned;
            }
        },
        .browser_launch_failed => try self.reportNotice(
            .warning,
            "Drinky could not open the browser for the sign-in to {s}. Open the URL above.",
            .{login.attempt.account.id()},
        ),
        .ended => try self.finishLogin(event.generation),
    }
}

fn recordLoginAuthorization(
    self: *App,
    account: ai.llm.Account,
    authorization: *const LoginEvent.Authorization,
) !void {
    if (authorization.code) |code| return self.recordEvent(
        .information,
        "Open this URL to authorize the sign-in to {s}:\n\n{s}\n\n" ++
            "Enter this code if the page asks for one: {s}",
        .{ account.id(), authorization.url, code },
    );
    return self.recordEvent(
        .information,
        "Open this URL to authorize the sign-in to {s}:\n\n{s}\n\n" ++
            "If the browser shows an error, paste the callback URL from its address bar " ++
            "and press Enter.",
        .{ account.id(), authorization.url },
    );
}

fn finishLogin(self: *App, generation: u64) !void {
    const active = if (self.login) |*login| login else return;
    if (active.generation != generation) return;
    try self.resolveLogin(&active.future.await(self.io));
}

fn cancelLogin(self: *App) !void {
    const active = if (self.login) |*login| login else return;
    try self.resolveLogin(&active.future.cancel(self.io));
}

fn resolveLogin(self: *App, result: *const LoginWorkerResult) !void {
    const active = self.login.?;
    std.debug.assert(result.generation == active.generation);
    std.debug.assert(result.account == active.attempt.account);
    defer self.gpa.free(active.title);
    self.endLoginInput();
    self.session.clearNotice();
    switch (result.outcome) {
        .failed => |login_error| try self.reportLoginFailure(active.attempt, login_error),
        .completed => |login| try self.completeLogin(active.attempt, &login),
    }
}

fn endLoginInput(self: *App) void {
    if (self.login) |*login| {
        if (login.callback_path) |callback_path| self.gpa.free(callback_path);
    }
    self.login = null;
    self.syncInputState();
}

fn completeLogin(
    self: *App,
    attempt: LoginAttempt,
    login: *const ai.Accounts.Login,
) !void {
    const account = attempt.account;
    const maybe_index = if (attempt.event_index) |index|
        index - self.session.transcript.producedBefore(account, index)
    else
        null;
    self.dropAccountEvidence(account);
    self.adopt(account);
    if (self.agent.model) |model| {
        try self.recordEventAt(
            maybe_index,
            .information,
            "Drinky signed in and now uses {s}/{s}.",
            .{ account.id(), model.name() },
        );
    } else try self.recordEventAt(
        maybe_index,
        .information,
        "Drinky signed in to {s}.",
        .{account.id()},
    );
    switch (login.*) {
        .saved => {},
        .memory_only => |failure| try self.recordEvent(
            .failure,
            "Drinky could not save the credentials for {s} to {s} because of error {s}. " ++
                "The sign-in stays active until Drinky exits.",
            .{ account.id(), failure.path, @errorName(failure.save_error) },
        ),
    }
    try self.mirrorAgentState();
    var context = self.commandContext();
    try self.session.applyOutcome(try ai.command.model.forAccount(&context, account));
}

fn dropLogin(self: *App) void {
    const active = if (self.login) |*login| login else return;
    _ = active.future.cancel(self.io);
    const title = active.title;
    self.endLoginInput();
    self.gpa.free(title);
}

fn startInputReader(self: *App) !void {
    self.input_future = try self.io.concurrent(readInput, .{self});
}

fn reportLoginFailure(self: *App, attempt: LoginAttempt, login_error: anyerror) !void {
    if (login_error == error.Canceled) return self.reportLoginEnd(
        attempt,
        .information,
        "You canceled the sign-in to {s}.",
        .{attempt.account.id()},
    );
    const message = switch (login_error) {
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
        else => return self.reportLoginEnd(
            attempt,
            .failure,
            "Drinky could not sign in because of error {s}.",
            .{@errorName(login_error)},
        ),
    };
    return self.reportLoginEnd(attempt, .failure, "{s}", .{message});
}

fn reportLoginEnd(
    self: *App,
    attempt: LoginAttempt,
    severity: ai.command.Outcome.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const index = attempt.event_index orelse return self.reportNotice(severity, format, args);
    try self.recordEventAt(index, severity, format, args);
}

fn isActive(self: *const App, account: ai.llm.Account) bool {
    return self.activeAccount() == account;
}

fn reportCredentialStep(self: *App, account: ai.llm.Account, comptime lead: []const u8) !void {
    if (self.agent.model == null) return self.reportModelStep(account, lead, .{});
    return self.recordEvent(.information, lead ++ "Try the turn again.", .{});
}

fn reportModelStep(
    self: *App,
    account: ai.llm.Account,
    comptime lead: []const u8,
    lead_args: anytype,
) !void {
    if (self.accounts.offersModel(account)) return self.recordEvent(
        .information,
        lead ++ "Select a model of {s} with /model.",
        lead_args ++ .{account.id()},
    );
    return self.recordEvent(
        .information,
        lead ++ "Fetch the model list of {s} with /model.",
        lead_args ++ .{account.id()},
    );
}

fn settleCredentialReplacement(self: *App, account: ai.llm.Account) void {
    self.accounts.dropPrincipalMetadata(account);
    self.settleReplacedPrincipal(account);
}

fn settleReplacedPrincipal(self: *App, account: ai.llm.Account) void {
    self.dropAccountEvidence(account);
    if (self.isActive(account)) self.adopt(account);
}

fn rereadAccounts(self: *App) !void {
    const report = self.accounts.reread();
    var maybe_left: ?ai.llm.Account = null;
    for (std.enums.values(ai.llm.Account)) |account| switch (report.changes.get(account)) {
        .unchanged, .signed_in => {},
        .rotated => if (self.isActive(account)) self.rebindClient(account),
        .replaced => {
            self.settleReplacedPrincipal(account);
            try self.reportModelStep(
                account,
                "Drinky found a replacement credential for {s}. " ++
                    "Drinky removed the prior account evidence. ",
                .{account.id()},
            );
        },
        .signed_out => {
            self.dropAccountEvidence(account);
            if (self.isActive(account)) {
                maybe_left = account;
            } else try self.recordEvent(
                .information,
                "Another Drinky instance signed out of {s}.",
                .{account.id()},
            );
        },
    };
    if (maybe_left) |account| try self.recordHandOff(
        "Another Drinky instance signed out of {s}. ",
        account,
        self.handOff(),
    );
    if (report.read_error) |err| try self.recordEvent(
        .failure,
        "Drinky could not read the credential file {s} because of error {s}. " ++
            "The account list shows the credentials from the last read.",
        .{ self.accounts.storePath(), @errorName(err) },
    );
    for (std.enums.values(ai.llm.Account)) |account| {
        const err = report.entry_errors.get(account) orelse continue;
        try self.recordEvent(
            .failure,
            "Drinky could not read the credential of {s} in {s} because of error {s}. " ++
                "The account stays as it was.",
            .{ account.id(), self.accounts.storePath(), @errorName(err) },
        );
    }
}

fn rebindClient(self: *App, account: ai.llm.Account) void {
    self.agent.switchTo(self.accounts.client(account).?, self.agent.model);
}

fn acceptCredentialReplacement(self: *App, account: ai.llm.Account) !void {
    self.settleCredentialReplacement(account);
    try self.reportCredentialStep(account, "");
    try self.mirrorAgentState();
}

fn acceptFetchReplacement(self: *App, account: ai.llm.Account) !void {
    self.settleCredentialReplacement(account);
    try self.reportModelStep(
        account,
        "Drinky found a replacement credential for {s}. " ++
            "Drinky removed the prior account evidence. ",
        .{account.id()},
    );
    try self.mirrorAgentState();
}

fn rejectCredential(self: *App, account: ai.llm.Account) !void {
    const adopts = self.isActive(account);
    var maybe_removal_error: ?anyerror = null;
    const recovered = self.accounts.invalidate(account) catch |err| failure: {
        maybe_removal_error = err;
        break :failure false;
    };
    self.dropAccountEvidence(account);
    if (recovered) {
        if (adopts) self.adopt(account);
        try self.reportCredentialStep(
            account,
            "Drinky reloaded the refresh credential that another Drinky instance saved. ",
        );
        return self.mirrorAgentState();
    }

    const maybe_next = if (adopts) self.handOff() else null;

    if (maybe_removal_error) |removal_error| try self.recordEvent(
        .failure,
        "Drinky could not remove the rejected credential for {s} because of error {s}.",
        .{ account.id(), @errorName(removal_error) },
    );
    if (!adopts) {
        try self.recordEvent(.information, "Drinky signed out of {s}.", .{account.id()});
        return self.mirrorAgentState();
    }
    try self.reportHandOff(account, maybe_next);
    try self.mirrorAgentState();
}

fn handOff(self: *App) ?ai.llm.Account {
    const maybe_next = self.accounts.firstAuthenticated();
    if (maybe_next) |next| self.adopt(next) else self.agent.signOut();
    return maybe_next;
}

fn reportHandOff(self: *App, account: ai.llm.Account, maybe_next: ?ai.llm.Account) !void {
    try self.recordHandOff("Drinky signed out of {s}. ", account, maybe_next);
    if (maybe_next == null) try self.openLoginPicker();
}

fn recordHandOff(
    self: *App,
    comptime lead: []const u8,
    account: ai.llm.Account,
    maybe_next: ?ai.llm.Account,
) !void {
    const next = maybe_next orelse return self.recordEvent(
        .information,
        lead ++ "Select an account to sign in.",
        .{account.id()},
    );
    if (self.agent.model) |model| return self.recordEvent(
        .information,
        lead ++ "Drinky now uses {s}/{s}.",
        .{ account.id(), next.id(), model.name() },
    );
    return self.reportModelStep(next, lead ++ "Drinky now uses {s}. ", .{ account.id(), next.id() });
}

fn openLoginPicker(self: *App) !void {
    var context = self.commandContext();
    try self.session.applyOutcome(try ai.command.login.picker(&context));
}

fn logoutAccount(self: *App, account: ai.llm.Account) !void {
    const was_active = self.isActive(account);
    self.accounts.logout(account) catch |err| {
        return self.reportNotice(
            .failure,
            "Drinky could not sign out because of error {s}.",
            .{@errorName(err)},
        );
    };
    self.dropAccountEvidence(account);
    if (!was_active)
        return self.recordEvent(.information, "Drinky signed out of {s}.", .{account.id()});
    try self.reportHandOff(account, self.handOff());
}

fn adopt(self: *App, account: ai.llm.Account) void {
    self.agent.switchTo(self.accounts.client(account).?, self.accountModel(account));
}

fn dropAccountEvidence(self: *App, account: ai.llm.Account) void {
    const transcript = &self.session.transcript;
    const cursor = @min(self.mirror.transcriptCursor(), transcript.blocks().len);
    const cursor_removed = transcript.producedBefore(account, cursor);
    if (self.revision) |*revision| {
        revision.history.base -= self.agent.producedBefore(account, revision.history.base);
        revision.history.end -= self.agent.producedBefore(account, revision.history.end);
        revision.transcript_base -= transcript.producedBefore(account, revision.transcript_base);
        revision.transcript_end -= transcript.producedBefore(account, revision.transcript_end);
    }
    self.agent.dropAccountEvidence(account);
    self.session.dropAccountReasoning(account);
    self.mirror.retreat(cursor_removed);
}

fn refuseCommand(self: *App, name: []const u8, restriction: []const u8) !void {
    const refusal = try ai.command.refuse(self.gpa, name, restriction);
    try self.session.applyOutcome(.{ .refusal = refusal });
}

fn reportNotice(
    self: *App,
    severity: ai.command.Outcome.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    try self.session.applyOutcome(
        try ai.command.Outcome.reportNotice(self.gpa, severity, format, args),
    );
}

fn resolveRequiredSkills(
    self: *App,
    config: *const Config,
    notices: *std.ArrayList(ai.instructions.Notice),
    missing: *std.ArrayList(Config.RequiredSkill),
) !void {
    for (config.required_skills) |required| {
        const target = self.skills.get(required.skill) orelse {
            try missing.append(self.gpa, required);
            continue;
        };
        self.skill_guard.add(.{
            .glob = required.glob,
            .skill = target.name,
            .source = target.path,
        }) catch |err| switch (err) {
            error.TooManyRules => {
                try self.appendNotice(
                    notices,
                    .failure,
                    "Drinky used only the first {d} required skills in {s}.",
                    .{ ai.tool.SkillGuard.rules_max, config.path },
                );
                break;
            },
        };
    }
}

fn appendNotice(
    self: *App,
    notices: *std.ArrayList(ai.instructions.Notice),
    severity: ai.instructions.Notice.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(self.gpa, format, args);
    errdefer self.gpa.free(text);
    try notices.append(self.gpa, .{ .severity = severity, .text = text });
}

fn reportNotices(self: *App, notices: []const ai.instructions.Notice) !void {
    for (notices) |notice| {
        const safe_text = try ai.instructions.displayAlloc(self.gpa, notice.text);
        defer self.gpa.free(safe_text);
        const severity: ai.command.Outcome.Severity = switch (notice.severity) {
            .information => .information,
            .failure => .failure,
        };
        try self.recordEvent(severity, "{s}", .{safe_text});
    }
}

fn recordAsyncEvent(
    self: *App,
    severity: ai.command.Outcome.Severity,
    options: Session.AsyncEventOptions,
    comptime format: []const u8,
    args: anytype,
) !void {
    try self.session.recordAsyncEvent(
        try ai.command.Outcome.Message.print(self.gpa, severity, format, args),
        options,
    );
}

fn recordEvent(
    self: *App,
    severity: ai.command.Outcome.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    try self.recordEventAt(null, severity, format, args);
}

fn recordEventAt(
    self: *App,
    maybe_index: ?usize,
    severity: ai.command.Outcome.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const message = try ai.command.Outcome.Message.print(self.gpa, severity, format, args);
    if (maybe_index) |index| return self.session.replaceEvent(index, message);
    try self.session.applyOutcome(.{ .event = message });
}

fn emitRemoteEvent(context: *anyopaque, event: remote.Attachment.Event) error{Closed}!void {
    const self: *App = @ptrCast(@alignCast(context));
    self.queue.putOne(self.io, .{ .remote = event }) catch return error.Closed;
}

fn emitPairingEvent(context: *anyopaque, event: remote.Pairing.Event) error{Closed}!void {
    const self: *App = @ptrCast(@alignCast(context));
    self.queue.putOne(self.io, .{ .pairing = event }) catch return error.Closed;
}

fn onRemoteAction(context: *anyopaque, action: remote.Controller.Action) anyerror!void {
    const self: *App = @ptrCast(@alignCast(context));
    switch (action) {
        .chat_message => |message| try self.submitChatMessage(message.text, message.id),
        .chat_tap => |tap| try self.handleChatTap(tap.query_id, tap.tap),
        .report => |report| switch (report.kind) {
            .event => try self.recordAsyncEvent(report.severity, .{}, "{s}", .{report.text}),
            .terminal_event => try self.recordAsyncEvent(
                report.severity,
                .{ .mirrored = false },
                "{s}",
                .{report.text},
            ),
            .notice => try self.reportNotice(report.severity, "{s}", .{report.text}),
        },
        .state_changed => try self.syncRemoteState(),
        .pairing_changed => |change| try self.applyPairingChange(change),
    }
}

fn syncRemoteState(self: *App) !void {
    const was_terminal = self.session.input.owner == .terminal;
    switch (self.controller.state()) {
        .attached => {
            const username = self.controller.botUsername().?;
            if (was_terminal) try self.takeRemoteTitle(username);
            self.syncInputState();
            if (was_terminal) try self.openChat(username);
            return;
        },
        .detaching => {
            if (was_terminal) try self.takeRemoteTitle(self.controller.botUsername().?);
            self.chat_picker.close();
            self.mirror.detached();
        },
        .idle, .checking_token, .token_prompt, .pairing => {},
    }
    self.syncInputState();
}

fn syncInputState(self: *App) void {
    if (self.login) |*login| {
        self.session.input = .{ .caption = .{
            .title = login.title,
            .controls = if (login.callback != null)
                login_callback_controls
            else
                login_device_controls,
            .rows_max = Session.editor_caption_rows_max,
        } };
        self.session.dirty = true;
        return;
    }
    self.session.input = switch (self.controller.state()) {
        .attached => .{ .owner = .external, .caption = .{
            .title = self.remote_title,
            .controls = "Esc: Detach",
            .rows_max = Session.editor_caption_rows_max,
        } },
        .detaching => .{ .owner = .none, .caption = .{
            .title = self.remote_title,
            .controls = "Esc: Cancel",
            .rows_max = Session.editor_caption_rows_max,
        } },
        .token_prompt => .{ .caption = .{
            .title = "Bot token",
            .controls = "Enter: Save · Esc: Cancel",
            .rows_max = Session.editor_caption_rows_max,
        } },
        .idle, .checking_token, .pairing => .{},
    };
    self.session.dirty = true;
}

fn takeRemoteTitle(self: *App, username: []const u8) !void {
    const title = try std.fmt.allocPrint(self.gpa, "Remote: @{s}", .{username});
    self.gpa.free(self.remote_title);
    self.remote_title = title;
}

fn openChat(self: *App, username: []const u8) !void {
    self.session.clearNotice();
    const text = try std.fmt.allocPrint(self.gpa, "You attached @{s}.", .{username});
    defer self.gpa.free(text);
    try self.recordAsyncEvent(.information, .{ .mirrored = false }, "{s}", .{text});
    try self.controller.sendEvent(.information, text);
    try self.mirror.open(&self.controller, &self.mirrorView());
}

fn mirrorView(self: *const App) remote.Mirror.View {
    return .{
        .blocks = self.session.transcript.blocks(),
        .committed = self.session.committedCount(),
        .tail = if (self.session.liveTail()) |tail| .{
            .streaming = tail.streaming,
            .tool = tail.tool,
            .calls = tail.calls,
        } else null,
        .retry_waits = self.retry != null,
    };
}

fn syncMirror(self: *App) !void {
    try self.mirror.sync(&self.controller, &self.mirrorView());
}

fn endMirrorTurn(self: *App, outcome: remote.Mirror.End.Outcome) !void {
    const status = self.session.statusInfo();
    try self.mirror.endTurn(&self.controller, &self.mirrorView(), &.{
        .outcome = outcome,
        .status = &status,
        .now_ms = self.nowMs(),
        .retry_armed = outcome == .failed and self.retry != null,
    });
}

fn markCommittedChatMessages(self: *App) !void {
    if (!self.controller.listens()) return;
    if (!self.prompt_marked and self.session.turnCommitted()) {
        if (self.session.turn_prompt) |*prompt| switch (prompt.source) {
            .external => |id| try self.controller.react(id, .committed),
            .terminal => {},
        };
        self.prompt_marked = true;
    }
    const committed = self.session.steering_committed_count;
    const messages = self.session.steering.items;
    while (self.steering_marked_count < committed) : (self.steering_marked_count += 1) {
        switch (messages[self.steering_marked_count].source) {
            .external => |id| try self.controller.react(id, .committed),
            .terminal => {},
        }
    }
}

fn settleChatMessages(self: *App, receipt: *const ai.Agent.Receipt) !void {
    if (!self.controller.listens()) return;
    const committed = receipt.history_end != receipt.history_base;
    const prompt_settled = self.prompt_marked and committed;
    if (!prompt_settled) {
        if (self.session.turn_prompt) |*prompt| switch (prompt.source) {
            .external => |id| try self.controller.react(id, if (committed) .committed else .dropped),
            .terminal => {},
        };
    }
    for (self.session.steering.items, 0..) |*message, index| {
        const message_committed = index < receipt.steering_committed_count;
        if (message_committed and index < self.steering_marked_count) continue;
        switch (message.source) {
            .external => |id| try self.controller.react(
                id,
                if (message_committed) .committed else .dropped,
            ),
            .terminal => {},
        }
    }
}

fn statusText(self: *App) ![]u8 {
    var info = self.session.statusInfo();
    info.directory = self.directory_label;
    var maybe_head: ?ai.project.Head = null;
    if (self.project_instructions.projectRoot()) |root|
        maybe_head = ai.project.head(self.gpa, self.io, root);
    info.branch = if (maybe_head) |*head| head.name() else null;
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    try ui.status.writeSummary(&out.writer, &info);
    return out.toOwnedSlice();
}

fn recordStatus(self: *App) !void {
    const text = try self.statusText();
    try self.session.recordAsyncEvent(
        .{ .content = text, .severity = .information },
        .{ .mirrored = false, .repeats = false },
    );
}

fn applyPairingChange(self: *App, change: remote.Controller.Action.PairingChange) !void {
    switch (change) {
        .check_started => try self.session.openWait(&.{
            .select = selectNothing,
            .title = "Remote",
            .cancellation_message = "You canceled the pairing.",
            .options = &.{},
            .current = null,
        }, token_check_wait_text),
        .code_ready => {
            var link_buffer: [128]u8 = undefined;
            const link = try self.gpa.dupe(u8, self.controller.pairingLink(&link_buffer));
            errdefer self.gpa.free(link);
            const text = try std.fmt.allocPrint(
                self.gpa,
                "Send the code {s} to @{s}",
                .{ self.controller.pairingCode(), self.controller.pairingUsername() },
            );
            errdefer self.gpa.free(text);
            try self.session.setPickerWait(text, link);
            self.freePairingStrings();
            self.pairing_wait_text = text;
            self.pairing_wait_link = link;
        },
        .prompt_restored => {
            self.session.closePicker();
            self.freePairingStrings();
        },
        .ended => {
            self.session.closePicker();
            self.session.editor.clear();
            self.freePairingStrings();
        },
    }
}

fn selectNothing(
    context: *ai.command.Context,
    selection: ai.command.Outcome.Pick.Selection,
) anyerror!ai.command.Outcome {
    _ = selection;
    return ai.command.Outcome.reportNotice(context.gpa, .failure, "Select a valid row.", .{});
}

fn freePairingStrings(self: *App) void {
    self.gpa.free(self.pairing_wait_text);
    self.gpa.free(self.pairing_wait_link);
    self.pairing_wait_text = "";
    self.pairing_wait_link = "";
}

fn freeRemoteStrings(self: *App) void {
    self.freePairingStrings();
    self.gpa.free(self.remote_title);
    self.remote_title = "";
}

fn handleExternalKey(self: *App, event: *const terminal.Input.Key) !void {
    switch (event.*) {
        .escape => try self.exitRemote(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => try self.exitRemote(),
            else => {},
        },
        .enter => try self.reportRemoteNotice(),
        else => {},
    }
}

fn exitRemote(self: *App) !void {
    switch (self.controller.state()) {
        .attached => try self.controller.detach(.user),
        .detaching => try self.controller.abortDetach(),
        .idle, .token_prompt, .checking_token, .pairing => unreachable,
    }
}

fn reportRemoteNotice(self: *App) !void {
    const username = self.controller.botUsername().?;
    switch (self.controller.state()) {
        .attached => try self.reportNotice(
            .information,
            "@{s} holds the input. Esc detaches.",
            .{username},
        ),
        .detaching => try self.reportNotice(
            .information,
            "Drinky detaches @{s}. Esc ends the wait.",
            .{username},
        ),
        .idle, .token_prompt, .checking_token, .pairing => unreachable,
    }
}

fn submitChatMessage(self: *App, text: []const u8, message_id: i64) !void {
    if (self.login != null) return self.controller.reply(
        message_id,
        .warning,
        "Drinky cannot take a message while a sign-in runs in the terminal.",
    );
    var context = self.chatContext();
    const origin: ChatOrigin = .{ .message = .{ .id = message_id, .text = text } };
    switch (self.session.mode) {
        .turn => {
            if (ai.command.parse(text)) |name| {
                if (try ai.command.check(&context, text)) |refusal| {
                    defer self.gpa.free(refusal.content);
                    return self.controller.reply(message_id, refusal.severity, refusal.content);
                }
                if (ai.command.runsDuringTurn(name)) {
                    const outcome = (try ai.command.run(&context, text)).?;
                    return self.applyChatOutcome(outcome, origin);
                }
                const refusal = try ai.command.refuse(self.gpa, name, "while a turn runs");
                defer self.gpa.free(refusal.content);
                return self.controller.reply(message_id, refusal.severity, refusal.content);
            }
            var draft = try ui.Editor.Draft.fromText(self.gpa, text);
            errdefer draft.deinit(self.gpa);
            try self.session.reserveSteering();
            try self.agent.steering.push(text);
            self.session.commitExternalSteering(&draft, message_id);
            return self.controller.react(message_id, .queued);
        },
        .prompt => {},
        .picking, .viewing => return self.controller.reply(
            message_id,
            .warning,
            "Drinky cannot take a message now.",
        ),
    }
    if (ai.command.parse(text) != null) {
        if (try ai.command.check(&context, text)) |refusal| {
            defer self.gpa.free(refusal.content);
            return self.controller.reply(message_id, refusal.severity, refusal.content);
        }
        const outcome = (try ai.command.run(&context, text)).?;
        return self.applyChatOutcome(outcome, origin);
    }
    if (!self.signedIn())
        return self.controller.reply(message_id, .failure, telegram_signed_out_refusal);
    if (self.agent.model == null)
        return self.controller.reply(message_id, .failure, telegram_no_model_refusal);
    var draft = try ui.Editor.Draft.fromText(self.gpa, text);
    errdefer draft.deinit(self.gpa);
    const base = try self.startUserTurn(text);
    self.session.retainExternalTurnPrompt(&draft, base, message_id);
    try self.controller.react(message_id, .queued);
}

const ChatOrigin = union(enum) {
    message: Line,
    tap: []const u8,

    const Line = struct {
        id: i64,
        text: []const u8,
    };
};

fn applyChatOutcome(self: *App, outcome: ai.command.Outcome, origin: ChatOrigin) !void {
    switch (outcome) {
        .pick => |*pick| {
            if (pick.report) |message| self.session.applyOutcome(.{ .event = message }) catch |err| {
                for (pick.options) |*option| option.deinit(self.gpa);
                self.gpa.free(pick.options);
                return err;
            };
            switch (origin) {
                .message => try self.chat_picker.show(&self.controller, pick),
                .tap => |query_id| {
                    try self.chat_picker.step(&self.controller, pick);
                    try self.controller.answer(query_id, null);
                },
            }
        },
        .notice, .refusal => |message| {
            defer self.gpa.free(message.content);
            try self.stateChatNotice(origin, message.severity, message.content);
        },
        .event => |message| {
            self.stateChatResult(origin) catch |err| {
                self.gpa.free(message.content);
                return err;
            };
            try self.applyOutcome(outcome);
        },
        .new_conversation => {
            try self.stateChatResult(origin);
            try self.applyOutcome(outcome);
        },
        .show_status => {
            const text = try self.statusText();
            defer self.gpa.free(text);
            try self.stateChatAnswer(origin, text);
        },
        .prompt => |prompt| {
            defer prompt.deinit(self.gpa);
            if (!self.signedIn())
                return self.stateChatNotice(origin, .failure, telegram_signed_out_refusal);
            if (self.agent.model == null)
                return self.stateChatNotice(origin, .failure, telegram_no_model_refusal);
            try self.startChatSkillTurn(&prompt, origin);
        },
        .editor_text => |text| {
            defer self.gpa.free(text);
            try self.stateChatNotice(origin, .warning, terminal_only_action);
        },
        else => try self.stateChatNotice(origin, .warning, terminal_only_action),
    }
}

const terminal_only_action = "This action runs in the terminal alone.";

fn startChatSkillTurn(
    self: *App,
    prompt: *const ai.command.Outcome.Prompt,
    origin: ChatOrigin,
) !void {
    switch (origin) {
        .message => |line| {
            var draft = try ui.Editor.Draft.fromText(self.gpa, line.text);
            errdefer draft.deinit(self.gpa);
            const base = try self.startSkillTurn(prompt);
            self.session.retainExternalTurnPrompt(&draft, base, line.id);
        },
        .tap => |query_id| {
            try self.chat_picker.dismiss(&self.controller);
            try self.controller.answer(query_id, null);
            const base = try self.startSkillTurn(prompt);
            self.session.markTurnBase(base);
        },
    }
}

fn stateChatNotice(
    self: *App,
    origin: ChatOrigin,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) !void {
    switch (origin) {
        .message => |line| try self.controller.reply(line.id, severity, text),
        .tap => |query_id| {
            try self.controller.answer(query_id, text);
            try self.chat_picker.dismiss(&self.controller);
        },
    }
}

fn stateChatAnswer(self: *App, origin: ChatOrigin, text: []const u8) !void {
    switch (origin) {
        .message => |line| try self.controller.reply(line.id, .information, text),
        .tap => |query_id| {
            try self.controller.answer(query_id, null);
            try self.chat_picker.dismiss(&self.controller);
            try self.controller.sendEvent(.information, text);
        },
    }
}

fn stateChatResult(self: *App, origin: ChatOrigin) !void {
    switch (origin) {
        .message => {},
        .tap => |query_id| {
            try self.controller.answer(query_id, null);
            try self.chat_picker.dismiss(&self.controller);
        },
    }
}

const turn_over_toast = "The turn is over.";
const retry_over_toast = "The retry is over.";
const list_closed_toast = "This list is closed.";
const answer_stale_toast = "This answer is not the newest one.";

const turn_runs_toast = "A turn runs. Wait for its end.";
const session_busy_toast = "Drinky cannot act on a tap now.";
const login_runs_toast = "A sign-in runs in the terminal. Wait for its end.";
const shorten_signed_out_toast =
    "Sign in with /login in the terminal before you shorten an answer.";
const shorten_no_model_toast =
    "Select a model with /model in the terminal before you shorten an answer.";

fn handleChatTap(self: *App, query_id: []const u8, tap: remote.keyboard.Tap) !void {
    if (self.login != null) return self.controller.answer(query_id, login_runs_toast);
    switch (tap) {
        .cancel_turn => |serial| {
            if (!self.mirror.namesTurn(serial)) return self.controller.answer(query_id, turn_over_toast);
            try self.controller.answer(query_id, null);
            try self.cancelTurn();
        },
        .withdraw => |serial| {
            if (!self.mirror.namesTurn(serial)) return self.controller.answer(query_id, turn_over_toast);
            const count = try self.withdrawSteering();
            try self.controller.answer(query_id, if (count == 0) "Nothing queued." else null);
        },
        .retry => |serial| {
            if (!self.mirror.namesRetry(serial) or self.retry == null)
                return self.controller.answer(query_id, retry_over_toast);
            if (!self.signedIn()) return self.controller.answer(
                query_id,
                "Sign in with /login in the terminal before you try the turn again.",
            );
            if (self.agent.model == null) return self.controller.answer(query_id, telegram_no_model_refusal);
            try self.controller.answer(query_id, null);
            try self.sendRetryTurn();
        },
        .dismiss => |serial| {
            if (!self.mirror.namesRetry(serial)) return self.controller.answer(query_id, retry_over_toast);
            try self.controller.answer(query_id, null);
            self.clearRetry();
        },
        .shorten => |serial| {
            if (!self.mirror.namesAnswer(serial))
                return self.controller.answer(query_id, answer_stale_toast);
            switch (self.session.mode) {
                .prompt => {},
                .turn => return self.controller.answer(query_id, turn_runs_toast),
                .picking, .viewing => return self.controller.answer(query_id, session_busy_toast),
            }
            if (!self.signedIn())
                return self.controller.answer(query_id, shorten_signed_out_toast);
            if (self.agent.model == null)
                return self.controller.answer(query_id, shorten_no_model_toast);
            try self.controller.answer(query_id, null);
            try self.sendShortenTurn();
        },
        .row, .back, .close => try self.handlePickerTap(query_id, tap),
    }
}

fn handlePickerTap(self: *App, query_id: []const u8, tap: remote.keyboard.Tap) !void {
    const action = self.chat_picker.resolve(tap) orelse
        return self.controller.answer(query_id, list_closed_toast);
    var context = self.chatContext();
    switch (action) {
        .row => |index| {
            const outcome = try self.chat_picker.select(&context, index);
            try self.applyChatOutcome(outcome, .{ .tap = query_id });
        },
        .back => |opener| {
            const outcome = try opener(&context);
            switch (outcome) {
                .pick => |*pick| {
                    try self.chat_picker.replace(&self.controller, pick, self.chat_picker.openers());
                    try self.controller.answer(query_id, null);
                },
                else => try self.applyChatOutcome(outcome, .{ .tap = query_id }),
            }
        },
        .close => {
            const message = self.chat_picker.cancellationMessage();
            try self.controller.answer(query_id, message);
            try self.chat_picker.dismiss(&self.controller);
        },
    }
}

fn withdrawSteering(self: *App) !usize {
    try self.session.reserveSteeringRecall();
    var dropped: std.ArrayList(i64) = .empty;
    defer dropped.deinit(self.gpa);
    try dropped.ensureTotalCapacity(self.gpa, self.session.steering.items.len);
    const taken = try self.agent.steering.take();
    defer {
        for (taken) |message| self.gpa.free(message);
        self.gpa.free(taken);
    }
    const messages = self.session.steering.items;
    for (messages[messages.len - taken.len ..]) |*message| switch (message.source) {
        .external => |id| dropped.appendAssumeCapacity(id),
        .terminal => {},
    };
    self.session.recallSteering(taken.len);
    for (dropped.items) |id| try self.controller.react(id, .dropped);
    return taken.len;
}

fn handleTokenKey(self: *App, event: *const terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submitToken(),
        .escape => try self.cancelTokenPrompt(),
        .ctrl => |letter| switch (letter) {
            'c' => if (self.session.editor.visible().len != 0) {
                self.session.editor.clear();
                self.session.markEdited();
            } else {
                try self.cancelTokenPrompt();
            },
            'd' => try self.cancelTokenPrompt(),
            else => {},
        },
        else => {},
    }
}

fn submitToken(self: *App) !void {
    const token = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(token);
    try self.controller.submitToken(token);
}

fn cancelTokenPrompt(self: *App) !void {
    self.session.editor.clear();
    try self.controller.cancelTokenPrompt();
}

fn handlePairingKey(self: *App, event: *const terminal.Input.Key) !void {
    switch (event.*) {
        .escape => try self.controller.cancelPairing(.step),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => try self.controller.cancelPairing(.command),
            else => {},
        },
        else => {},
    }
}

fn handlePageKey(self: *App, event: *const terminal.Input.Key) !void {
    const page = &self.session.mode.viewing;
    const size: terminal.View.Size = .{
        .columns = self.session.columns,
        .rows = self.session.rows,
    };
    switch (event.*) {
        .escape => return self.session.closePage(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => return self.session.closePage(),
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
    self.session.dirty = true;
}

fn handlePickerKey(self: *App, event: *const terminal.Input.Key) !void {
    if (self.controller.pairs()) return self.handlePairingKey(event);
    if (self.session.pickerWaits()) return self.handleFetchKey(event);
    const picker = &self.session.mode.picking.picker;
    switch (event.*) {
        .up => try picker.moveUp(),
        .down => try picker.moveDown(),
        .enter => return self.confirmPicker(),
        .escape => return self.leavePicker(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => return self.session.cancelPicker(),
            else => return,
        },
        else => return,
    }
    self.session.dirty = true;
}

fn handleFetchKey(self: *App, event: *const terminal.Input.Key) !void {
    switch (event.*) {
        .escape => try self.cancelFetch(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => {
                self.dropFetch();
                try self.session.cancelPicker();
            },
            else => {},
        },
        else => {},
    }
}

fn confirmPicker(self: *App) !void {
    const picking = &self.session.mode.picking;
    const cursor = picking.picker.cursor;
    switch (picking.purpose) {
        .command => |*command| {
            var context = self.commandContext();
            const outcome = try command.select(&context, cursor);
            if (!keepsPicker(outcome)) self.session.closePicker();
            try self.applyOutcome(outcome);
        },
        .prompt_history => try self.appendPromptHistory(cursor),
    }
}

fn appendPromptHistory(self: *App, row: usize) !void {
    var source = try ui.Editor.Draft.fromText(self.gpa, self.prompt_history.entries.items[row]);
    defer source.deinit(self.gpa);
    try self.session.appendPromptHistory(&source);
}

fn openPromptHistory(self: *App) !void {
    std.debug.assert(self.session.mode == .prompt);
    if (!self.prompt_history.enabled) return self.reportNotice(
        .information,
        "Prompt history is disabled. Set prompt_history.enabled to true in {s}.",
        .{self.config_path},
    );
    self.prompt_history.load() catch |err| return self.reportNotice(
        .failure,
        "Drinky could not read prompt history from {s} because of error {s}.",
        .{ self.prompt_history.path, @errorName(err) },
    );
    const entries = self.prompt_history.entries.items;
    if (entries.len == 0) return self.reportNotice(.information, prompt_history_empty_notice, .{});
    try self.session.openPromptHistory(try promptLabels(self.gpa, entries));
}

fn promptLabels(gpa: std.mem.Allocator, prompts: []const []const u8) ![]const []const u8 {
    const labels = try gpa.alloc([]const u8, prompts.len);
    var built: usize = 0;
    errdefer {
        for (labels[0..built]) |label| gpa.free(label);
        gpa.free(labels);
    }
    for (prompts) |prompt| {
        labels[built] = try promptLabel(gpa, prompt);
        built += 1;
    }
    return labels;
}

fn promptLabel(gpa: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const label = try gpa.alloc(u8, prompt.len - std.mem.count(u8, prompt, "\r\n"));
    var written: usize = 0;
    var index: usize = 0;
    while (index < prompt.len) : (index += 1) {
        const byte = prompt[index];
        if (byte == '\r' and index + 1 < prompt.len and prompt[index + 1] == '\n') index += 1;
        label[written] = if (byte == '\r' or byte == '\n') ' ' else byte;
        written += 1;
    }
    std.debug.assert(written == label.len);
    return label;
}

fn recordPromptHistory(self: *App, text: []const u8) !void {
    std.debug.assert(text.len > 0);
    if (text[0] == '/') return;
    self.prompt_history.record(text) catch |err| switch (err) {
        error.PromptTooLarge => try self.reportNotice(
            .warning,
            prompt_history_oversized_notice,
            .{},
        ),
        error.OutOfMemory => try self.reportNotice(
            .failure,
            "Drinky could not add the prompt to history because of error {s}.",
            .{@errorName(err)},
        ),
        else => try self.reportNotice(
            .failure,
            "Drinky could not save prompt history to {s} because of error {s}.",
            .{ self.prompt_history.path, @errorName(err) },
        ),
    };
}

fn keepsPicker(outcome: ai.command.Outcome) bool {
    return switch (outcome) {
        .pick, .fetch => true,
        else => false,
    };
}

fn leavePicker(self: *App) !void {
    const opener = self.session.stepAbove() orelse return self.session.cancelPicker();
    var context = self.commandContext();
    const outcome = try opener(&context);
    switch (outcome) {
        .pick => |*pick| try self.session.openPickerAbove(pick),
        else => {
            self.session.closePicker();
            try self.applyOutcome(outcome);
        },
    }
}

const worker_start_rounds_max = 5000;

fn initForTest(self: *App, gpa: std.mem.Allocator) void {
    self.initFields(gpa, std.testing.io);
    self.running = true;
}

fn expectModel(self: *const App, expected: []const u8) !void {
    const model = self.agent.model orelse return error.TestExpectedModel;
    try std.testing.expectEqualStrings(expected, model.name());
}

test "the intro line holds every key hint and closes on the command list" {
    try std.testing.expectEqualStrings(
        "Enter: Send · Shift+Enter: New line · Tab: Prompt history · Esc: Cancel · " ++
            "Ctrl+C: Clear · Ctrl+D: Quit · /help: Commands",
        intro_text,
    );
    try std.testing.expectEqual(@as(usize, 120), terminal.width.ofText(intro_text));
    for (intro_keys) |hint|
        try std.testing.expect(std.mem.indexOf(u8, intro_text, hint) != null);
}

fn initHistoryTest(
    self: *App,
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer.Allocating,
    home: []const u8,
    enabled: bool,
) !void {
    self.initForTest(gpa);
    self.accounts = ai.testing.accounts(.{ .anthropic = "sk-ant" });
    self.agent = ai.Agent.init(gpa, io, self.accounts.client(.anthropic_api_key), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    self.agent.rounds_max = 0;
    self.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    self.session.account_shown = .anthropic_api_key;
    self.prompt_history = try PromptHistory.open(gpa, io, &.{
        .working_directory = "/work",
        .home = home,
        .enabled = enabled,
    });
    self.config_path = "/home/.drinky/config.json";
}

fn deinitHistoryTest(self: *App) void {
    self.dropRetry();
    self.drainQueue();
    self.input.deinit();
    self.prompt_history.deinit();
    self.session.deinit();
    self.agent.deinit();
}

fn finishHistoryTurn(self: *App) !void {
    const result = self.awaitTurnFuture() orelse return error.TestExpectedTurn;
    defer self.freeWorkerResult(&result);
    try self.finishWorkerResult(&result);
}

fn expectHistory(self: *App, expected: []const []const u8) !void {
    try self.prompt_history.load();
    const entries = self.prompt_history.entries.items;
    try std.testing.expectEqual(expected.len, entries.len);
    for (expected, entries) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn expectNoHistoryFile(self: *const App) !void {
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(self.io, self.prompt_history.path, .{}),
    );
}

test "Tab opens the prompt history over the idle prompt alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    defer app.controller.deinit();
    try app.prompt_history.record("older");
    try app.prompt_history.record("newer");

    try app.session.editor.insert("typed");
    try app.handleKeys("\t");
    try std.testing.expect(app.session.mode == .picking);
    const picker = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Prompt history", picker.title);
    try std.testing.expectEqual(@as(usize, 2), picker.options.len);
    try std.testing.expectEqualStrings("newer", picker.options[0].name);
    try std.testing.expectEqualStrings("older", picker.options[1].name);
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try std.testing.expect(picker.marked == null);
    try std.testing.expect(app.session.mode.picking.purpose == .prompt_history);
    try std.testing.expectEqualStrings("typed", app.session.editor.visible());
    try app.handleKeys("\t");
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expectEqual(@as(usize, 0), app.session.mode.picking.picker.cursor);
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings(
        "You canceled the prompt history selection.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqualStrings("typed", app.session.editor.visible());

    try app.session.openPage(&.{ .title = "Test page", .content = "body" });
    try app.handleKey(&.tab);
    try std.testing.expect(app.session.mode == .viewing);
    app.session.closePage();

    try app.runCommand("/help");
    try app.handleKey(&.tab);
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expectEqualStrings("Command", app.session.mode.picking.picker.title);
    try app.session.cancelPicker();

    app.session.input.owner = .external;
    try app.handleKey(&.tab);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.session.notice == null);
    app.session.input.owner = .terminal;

    var signals: LoginTestSignals = .{};
    try beginLoginForTest(&app, .xai_plan, null, &signals);
    try app.handleKey(&.tab);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.login != null);
    app.dropLogin();
    app.syncInputState();

    try app.runCommand("/remote");
    try app.handleKeys("\r");
    try std.testing.expectEqual(remote.Controller.State.token_prompt, app.controller.state());
    try app.handleKey(&.tab);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(remote.Controller.State.token_prompt, app.controller.state());
    try std.testing.expect(app.session.notice == null);
    try app.handleKey(&.escape);
    try std.testing.expectEqual(remote.Controller.State.idle, app.controller.state());
}

test "Tab during a turn shows its notice and changes no draft or turn state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    app.session.beginTurn(7);
    try app.session.editor.insert("draft");

    try app.handleKeys("\t");
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqual(@as(u64, 7), app.session.mode.turn.generation);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.information, notice.severity);
    try std.testing.expectEqualStrings(
        "Prompt history cannot open while a turn runs.",
        notice.content,
    );
    try std.testing.expectEqualStrings("draft", app.session.editor.visible());
    try app.expectNoHistoryFile();
}

test "a disabled history explains the setting on Tab and records nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/prompt_history.json",
        .data = "{\"dmFsaWQ\":{}}",
    });

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, false);
    defer app.deinitHistoryTest();

    try std.testing.expect(std.mem.indexOf(u8, intro_text, "Tab: Prompt history") != null);
    try app.session.editor.insert("typed");
    try app.handleKeys("\t");
    try std.testing.expect(app.session.mode == .prompt);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.information, notice.severity);
    try std.testing.expectEqualStrings(
        "Prompt history is disabled. Set prompt_history.enabled to true in " ++
            "/home/.drinky/config.json.",
        notice.content,
    );
    try std.testing.expectEqualStrings("typed", app.session.editor.visible());

    try app.handleKey(&.enter);
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.session.notice == null);
    try app.finishHistoryTurn();
    const data = try tmp.dir.readFileAlloc(io, ".drinky/prompt_history.json", gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{\"dmFsaWQ\":{}}", data);
}

test "an empty or unreadable history opens no picker and keeps the draft" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();

    try app.session.editor.insert("typed");
    try app.handleKeys("\t");
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(
        ai.command.Outcome.Severity.information,
        app.session.notice.?.severity,
    );
    try std.testing.expectEqualStrings("Prompt history is empty.", app.session.notice.?.content);
    try std.testing.expectEqualStrings("typed", app.session.editor.visible());

    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/prompt_history.json", .data = "{ not json" });
    try app.handleKeys("\t");
    try std.testing.expect(app.session.mode == .prompt);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
    const expected = try std.fmt.allocPrint(
        gpa,
        "Drinky could not read prompt history from {s} because of error CorruptStore.",
        .{app.prompt_history.path},
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, notice.content);
    try std.testing.expectEqualStrings("typed", app.session.editor.visible());
}

test "a history label folds its line breaks and cuts like every picker row" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    try app.prompt_history.record("one\r\ntwo\rthree\nfour");
    const long = "start " ++ "x" ** 200 ++ " end";
    try app.prompt_history.record(long);

    try app.handleKeys("\t");
    const picker = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings(long, picker.options[0].name);
    try std.testing.expectEqualStrings("one two three four", picker.options[1].name);
    try std.testing.expectEqualStrings(long, app.prompt_history.entries.items[0]);
    try std.testing.expectEqualStrings(
        "one\r\ntwo\rthree\nfour",
        app.prompt_history.entries.items[1],
    );

    try app.session.paint(.{ .columns = 40, .rows = 24 });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, picker.content.items, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "…") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "\u{FFFD}") == null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "one two three four") != null);
}

test "a failed prompt history open frees its labels once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(std.testing.allocator, io, &tmp, "");
    defer std.testing.allocator.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    try app.prompt_history.record("one\r\ntwo");
    try app.prompt_history.record("three");

    var step: usize = 0;
    while (true) : (step += 1) {
        failing.fail_index = failing.alloc_index + step;
        const result = app.openPromptHistory();
        failing.fail_index = std.math.maxInt(usize);
        if (result) |_| {
            if (app.session.mode == .picking) break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(app.session.mode == .prompt);
        if (step == 64) return error.TestSweepTooLong;
    }
    try std.testing.expectEqualStrings("three", app.session.mode.picking.picker.options[0].name);
    try std.testing.expectEqualStrings("one two", app.session.mode.picking.picker.options[1].name);
}

test "a selection appends without a write, and the submitted draft records itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    try app.prompt_history.record("alpha\nbeta");
    try app.prompt_history.record("gamma");
    const before = try tmp.dir.readFileAlloc(io, ".drinky/prompt_history.json", gpa, .unlimited);
    defer gpa.free(before);

    try app.session.editor.insert("typed");
    app.session.dirty = false;
    try app.handleKeys("\t\x1b[B\r!");
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.session.dirty);
    try std.testing.expectEqualStrings("typed\n\nalpha\nbeta!", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.editor.draft.atoms.items.len);
    const after = try tmp.dir.readFileAlloc(io, ".drinky/prompt_history.json", gpa, .unlimited);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    try app.expectHistory(&.{ "gamma", "alpha\nbeta" });

    try app.submit();
    try std.testing.expect(app.session.mode == .turn);
    try app.expectHistory(&.{ "typed\n\nalpha\nbeta!", "gamma", "alpha\nbeta" });
    try app.finishHistoryTurn();

    app.session.editor.clear();
    try app.handleKeys("\t\x1b[B\x1b[B\r");
    try std.testing.expectEqualStrings("alpha\nbeta", app.session.editor.visible());
    try app.submit();
    try app.expectHistory(&.{ "alpha\nbeta", "typed\n\nalpha\nbeta!", "gamma" });
    try app.finishHistoryTurn();
}

test "every cancel key of the history picker keeps the draft" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    try app.prompt_history.record("saved");
    try app.session.editor.insert("typed");

    for ([_]terminal.Input.Key{ .escape, .{ .ctrl = 'c' }, .{ .ctrl = 'd' } }) |key| {
        try app.handleKeys("\t");
        try std.testing.expect(app.session.mode == .picking);
        try app.handleKey(&key);
        try std.testing.expect(app.session.mode == .prompt);
        try std.testing.expect(app.running);
        try std.testing.expectEqualStrings(
            "You canceled the prompt history selection.",
            app.session.notice.?.content,
        );
        try std.testing.expectEqualStrings("typed", app.session.editor.visible());
    }
    try app.expectHistory(&.{"saved"});
}

test "a plain prompt enters the history at its successful start alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();

    try app.session.editor.insert("  hello\nworld  ");
    app.turn_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, app.submit());
    try std.testing.expect(app.session.mode == .prompt);
    try app.expectNoHistoryFile();

    app.turn_generation = 0;
    try app.submit();
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.session.notice == null);
    try app.expectHistory(&.{"hello\nworld"});
    try app.finishHistoryTurn();
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("hello\nworld", app.session.editor.visible());
    try app.expectHistory(&.{"hello\nworld"});
}

test "every outer-trimmed slash line stays out of the history" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    var skill = try tmp.dir.createDirPathOpen(io, "skills/demo", .{});
    skill.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: a test skill\n---\nbody\n",
    });
    const user_skills = try tmpPath(gpa, io, &tmp, "skills");
    defer gpa.free(user_skills);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    app.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = home,
        .project_root = null,
    });
    defer app.skills.deinit();

    try app.session.editor.insert("/status");
    try app.submit();
    try std.testing.expect(app.session.mode == .prompt);
    try app.expectNoHistoryFile();

    try app.session.editor.insert("  /skill:demo apply it");
    try app.submit();
    try std.testing.expect(app.session.mode == .turn);
    try app.expectNoHistoryFile();
    try app.finishHistoryTurn();
    app.session.editor.clear();

    try app.session.editor.insert(" /nope tell me about this");
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.confirmations.contains(.message));
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.mode == .turn);
    try app.expectNoHistoryFile();
    try app.finishHistoryTurn();
}

test "no path but a submitted terminal prompt records history" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();

    try app.session.editor.insert("direct");
    {
        const base = try app.startUserTurn("direct");
        var prompt = app.session.editor.detachTrimmed();
        app.session.retainTurnPrompt(&prompt, base);
    }
    try app.expectNoHistoryFile();
    try app.session.editor.insert("steer this");
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.hasSteering());
    try app.expectNoHistoryFile();
    try app.finishHistoryTurn();
    app.session.editor.clear();

    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    try app.sendRetryTurn();
    try app.expectNoHistoryFile();
    try app.finishHistoryTurn();
    app.session.editor.clear();
    try app.sendShortenTurn();
    try app.expectNoHistoryFile();
    try app.finishHistoryTurn();
    app.session.editor.clear();

    try app.session.editor.insert("cleared");
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.running);
    try app.expectNoHistoryFile();
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(!app.running);
}

test "a history failure warns and never touches the started turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();

    const oversized = try gpa.alloc(u8, PromptHistory.entry_bytes_max + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    try app.session.editor.insert(oversized);
    try app.submit();
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.turn_future != null);
    const warning = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.warning, warning.severity);
    try std.testing.expectEqualStrings(
        "Drinky did not add the prompt to history because it exceeds 8 KiB.",
        warning.content,
    );
    try std.testing.expectEqualStrings(oversized, app.session.transcript.blocks()[0].content.user.items);
    try app.expectNoHistoryFile();
    try app.finishHistoryTurn();
    app.session.editor.clear();

    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/prompt_history.json", .data = "{ not json" });
    try app.session.editor.insert("hello");
    try app.submit();
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.turn_future != null);
    const failure = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, failure.severity);
    const expected = try std.fmt.allocPrint(
        gpa,
        "Drinky could not save prompt history to {s} because of error CorruptStore.",
        .{app.prompt_history.path},
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, failure.content);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqualStrings("hello", blocks[blocks.len - 1].content.user.items);
    try app.finishHistoryTurn();
    const data = try tmp.dir.readFileAlloc(io, ".drinky/prompt_history.json", gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);
}

const LoginTestSignals = struct {
    started: std.atomic.Value(bool) = .init(false),
    stopped: std.atomic.Value(bool) = .init(false),
};

fn waitForLoginCancel(
    io: std.Io,
    signals: *LoginTestSignals,
    account: ai.llm.Account,
    generation: u64,
) LoginWorkerResult {
    signals.started.store(true, .release);
    defer signals.stopped.store(true, .release);
    io.sleep(.fromSeconds(60), .awake) catch {};
    return .{
        .account = account,
        .generation = generation,
        .outcome = .{ .failed = error.Canceled },
    };
}

fn beginLoginForTest(
    app: *App,
    account: ai.llm.Account,
    maybe_callback: ?ai.Accounts.Callback,
    signals: *LoginTestSignals,
) !void {
    const title = try std.fmt.allocPrint(app.gpa, "Sign in: {s}", .{account.id()});
    errdefer app.gpa.free(title);
    const generation = try reserveGeneration(&app.login_generation);
    app.login = .{
        .future = try app.io.concurrent(
            waitForLoginCancel,
            .{ app.io, signals, account, generation },
        ),
        .callback = maybe_callback,
        .generation = generation,
        .title = title,
        .attempt = .{ .account = account },
    };
    app.syncInputState();
    for (0..worker_start_rounds_max) |_| {
        if (signals.started.load(.acquire)) return;
        app.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.LoginWorkerDidNotStart;
}

test "a sign-in prompt records its URL and user code in transcript events" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    var signals: LoginTestSignals = .{};
    try beginLoginForTest(&app, .anthropic_plan, null, &signals);
    defer app.dropLogin();

    var prompt: LoginPrompt = .{ .app = &app, .generation = app.login.?.generation };
    try prompt.showAuthorization("https://example.test/\x1b]52;c;b3duZWQ=\x07", null);
    try prompt.showDeviceCode("https://example.test/activate", "AB\x1bCD");
    try prompt.showBrowserLaunchFailed();

    var events: [3]UiEvent = undefined;
    const count = try app.queue.get(app.io, &events, events.len);
    try std.testing.expectEqual(events.len, count);
    _ = try app.applyBatch(events[0..count]);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    const authorization = blocks[0].content.event.text.items;
    const device = blocks[1].content.event.text.items;
    try std.testing.expect(std.mem.indexOf(
        u8,
        authorization,
        "anthropic-plan:\n\nhttps://example.test/\x1b]52;c;b3duZWQ=\x07\n\nIf the browser",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, authorization, "URL:") == null);
    try std.testing.expect(std.mem.indexOf(u8, device, "asks for one: AB\x1bCD") != null);
    try std.testing.expectEqualStrings(
        "Drinky could not open the browser for the sign-in to anthropic-plan. " ++
            "Open the URL above.",
        app.session.notice.?.content,
    );

    try app.session.paint(.{ .columns = 120, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]52;c;b3duZWQ=\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "AB\x1bCD") == null);
}

test "a sign-in caption names the account and Enter refuses a device login line" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    var signals: LoginTestSignals = .{};
    try beginLoginForTest(&app, .xai_plan, null, &signals);
    defer app.dropLogin();

    const caption = app.session.input.caption.?;
    try std.testing.expectEqualStrings("Sign in: xai-plan", caption.title);
    try std.testing.expectEqualStrings(login_device_controls, caption.controls);
    try app.session.editor.insert("not a callback");
    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings(
        "The sign-in to xai-plan does not accept a callback URL. " ++
            "Complete the sign-in in the browser.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqualStrings("not a callback", app.session.editor.visible());

    try app.handleKey(&.{ .char = 'x' });
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(app.session.input.caption != null);
    try app.handleKey(&.escape);
    try std.testing.expect(app.login == null);
    try std.testing.expect(app.session.input.caption == null);
    try std.testing.expect(signals.stopped.load(.acquire));
    try std.testing.expectEqualStrings(
        "You canceled the sign-in to xai-plan.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqualStrings("not a callbackx", app.session.editor.visible());
}

test "Enter replays a callback URL from the raw editor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var redirect_future = try io.concurrent(
        ai.oauth_callback.receive,
        .{ gpa, io, &server, @as(?[]const u8, null) },
    );
    errdefer if (redirect_future.cancel(io)) |redirect| {
        gpa.free(redirect.code);
        if (redirect.state) |state| gpa.free(state);
    } else |_| {};

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    var signals: LoginTestSignals = .{};
    try beginLoginForTest(&app, .anthropic_plan, .{
        .port = server.socket.address.getPort(),
        .binding = .state,
    }, &signals);
    defer app.dropLogin();

    try std.testing.expectEqualStrings(
        login_callback_controls,
        app.session.input.caption.?.controls,
    );
    try app.session.editor.insert(
        "https://localhost/callback?code=paste-code&state=paste-state",
    );
    try app.handleKey(&.enter);
    const redirect = try redirect_future.await(io);
    defer {
        gpa.free(redirect.code);
        if (redirect.state) |state| gpa.free(state);
    }
    try std.testing.expectEqualStrings("paste-code", redirect.code);
    try std.testing.expectEqualStrings("paste-state", redirect.state.?);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
}

test "a pasted line of another callback path keeps the editor and warns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var redirect_future = try io.concurrent(
        ai.oauth_callback.receive,
        .{ gpa, io, &server, @as(?[]const u8, "/deadbeef") },
    );
    errdefer if (redirect_future.cancel(io)) |redirect| {
        gpa.free(redirect.code);
        if (redirect.state) |state| gpa.free(state);
    } else |_| {};

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    var signals: LoginTestSignals = .{};
    try beginLoginForTest(&app, .openrouter_api, .{
        .port = server.socket.address.getPort(),
        .binding = .path,
    }, &signals);
    defer app.dropLogin();

    const refusal = "The line is not the callback URL for the sign-in to openrouter-api. " ++
        "Paste the complete callback URL from the browser.";

    const early = "http://localhost:53694/deadbeef?code=early-code";
    try app.session.editor.insert(early);
    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings(early, app.session.editor.visible());
    try std.testing.expectEqualStrings(refusal, app.session.notice.?.content);
    app.session.editor.clear();

    var prompt: LoginPrompt = .{ .app = &app, .generation = app.login.?.generation };
    try prompt.showAuthorization(
        "https://openrouter.ai/auth?callback_url=http%3A%2F%2Flocalhost%3A53694%2Fdeadbeef",
        "/deadbeef",
    );
    var events: [1]UiEvent = undefined;
    const count = try app.queue.get(app.io, &events, events.len);
    _ = try app.applyBatch(events[0..count]);
    try std.testing.expectEqualStrings("/deadbeef", app.login.?.callback_path.?);

    const stale = "http://localhost:53694/other?code=stale-code";
    try app.session.editor.insert(stale);
    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings(stale, app.session.editor.visible());
    try std.testing.expectEqualStrings(refusal, app.session.notice.?.content);

    app.session.editor.clear();
    try app.session.editor.insert("http://localhost:53694/deadbeef?code=paste-code");
    try app.handleKey(&.enter);
    const redirect = try redirect_future.await(io);
    defer gpa.free(redirect.code);
    try std.testing.expectEqualStrings("paste-code", redirect.code);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
}

test "a sign-in cancel drops the rest of one exit attempt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    var signals: LoginTestSignals = .{};
    try beginLoginForTest(&app, .anthropic_plan, null, &signals);
    defer app.dropLogin();

    try app.handleKeys("\x1b\x04");
    try std.testing.expect(app.login == null);
    try std.testing.expect(app.running);
    try std.testing.expect(signals.stopped.load(.acquire));
}

fn completeLoginForTest(app: *App, account: ai.llm.Account, generation: u64) LoginWorkerResult {
    var prompt: LoginPrompt = .{ .app = app, .generation = generation };
    prompt.showAuthorization("https://example.test/authorize", null) catch {};
    app.queue.putOne(app.io, .{ .login = .{
        .generation = generation,
        .payload = .ended,
    } }) catch {};
    return .{
        .account = account,
        .generation = generation,
        .outcome = .{ .completed = .{ .saved = "/home/.drinky/auth.json" } },
    };
}

test "a committed sign-in adopts its account and opens its model flow" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();
    app.session.account_shown = null;
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "old reasoning");
    app.session.transcript.endMessage();

    const generation = try reserveGeneration(&app.login_generation);
    app.login = .{
        .future = try io.concurrent(
            completeLoginForTest,
            .{ &app, .anthropic_plan, generation },
        ),
        .callback = ai.Accounts.callback(.anthropic_plan),
        .generation = generation,
        .title = try gpa.dupe(u8, "Sign in: anthropic-plan"),
        .attempt = .{ .account = .anthropic_plan },
    };
    app.syncInputState();
    try std.testing.expectEqualStrings(
        "Sign in: anthropic-plan",
        app.session.input.caption.?.title,
    );

    var events: [2]UiEvent = undefined;
    const count = try app.queue.get(io, &events, events.len);
    try std.testing.expectEqual(events.len, count);
    _ = try app.applyBatch(events[0..count]);

    try std.testing.expect(app.login == null);
    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, app.activeAccount().?);
    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, app.session.account_shown.?);
    try std.testing.expect(app.session.input.caption == null);
    try std.testing.expect(app.session.mode == .picking);
    const picker = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: anthropic-plan", picker.title);
    try std.testing.expectEqual(@as(usize, 1), picker.options.len);
    try std.testing.expectEqualStrings("Fetch the model list", picker.options[0].name);
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try std.testing.expect(!picker.can_step_back);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky signed in to anthropic-plan.",
        blocks[0].content.event.text.items,
    );
}

test "a sign-in opens a cached model flow on the remembered model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "sk-ant" });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_api_key, &.{
        "claude-fable-5",
        test_anthropic_model.name(),
    });
    app.state.models.set(.anthropic_api_key, test_anthropic_model);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();

    try app.completeLogin(.{ .account = .anthropic_api_key }, &.{
        .saved = "/home/.drinky/auth.json",
    });

    try app.expectModel(test_anthropic_model.name());
    try std.testing.expect(app.session.mode == .picking);
    const picker = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: anthropic-api-key", picker.title);
    try std.testing.expectEqualStrings("Refresh the model list", picker.options[0].name);
    try std.testing.expectEqualStrings(
        test_anthropic_model.name(),
        picker.options[picker.marked.?].name,
    );
    try std.testing.expectEqual(picker.marked.?, picker.cursor);
    try std.testing.expectEqualStrings(
        "Drinky signed in and now uses anthropic-api-key/claude-opus-5.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );
}

test "an OpenRouter sign-in preselects the remembered author" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .openrouter = "sk-or" });
    defer app.accounts.deinit();
    const metadata = try gpa.alloc(ai.Metadata.Entry, 2);
    metadata[0] = .{
        .provider = .openrouter,
        .model = ai.testing.model("anthropic/claude-fable-5"),
    };
    metadata[1] = .{
        .provider = .openrouter,
        .model = ai.testing.model("openai/gpt-5.6-sol"),
    };
    app.accounts.catalog.metadata = metadata;
    app.state.models.set(.openrouter_api_key, ai.testing.model("openai/removed-model"));
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();

    try app.completeLogin(.{ .account = .openrouter_api_key }, &.{
        .saved = "/home/.drinky/auth.json",
    });

    try std.testing.expect(app.agent.model == null);
    try std.testing.expect(app.session.mode == .picking);
    const picker = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Author: openrouter-api-key", picker.title);
    try std.testing.expectEqualStrings("Refresh the model list", picker.options[0].name);
    try std.testing.expect(picker.marked == null);
    try std.testing.expectEqualStrings("openai", picker.options[picker.cursor].name);
}

test "a canceled sign-in rewrites its URL event into the cancel line" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    var signals: LoginTestSignals = .{};
    try beginLoginForTest(&app, .xai_plan, null, &signals);
    defer app.dropLogin();

    var prompt: LoginPrompt = .{ .app = &app, .generation = app.login.?.generation };
    try prompt.showDeviceCode("https://example.test/activate", "ABCD-EFGH");
    var events: [1]UiEvent = undefined;
    const count = try app.queue.get(app.io, &events, 1);
    _ = try app.applyBatch(events[0..count]);
    try std.testing.expectEqual(@as(usize, 0), app.login.?.attempt.event_index.?);
    try app.session.paint(.{ .columns = 120, .rows = 30 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ABCD-EFGH") != null);

    const painted = out.written().len;
    try app.handleKey(&.escape);
    try std.testing.expect(app.login == null);
    try std.testing.expect(app.session.notice == null);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "You canceled the sign-in to xai-plan.",
        blocks[0].content.event.text.items,
    );
    try app.session.paint(.{ .columns = 120, .rows = 30 });
    const repainted = out.written()[painted..];
    try std.testing.expect(std.mem.indexOf(u8, repainted, "You canceled the sign-in") != null);
    try std.testing.expect(std.mem.indexOf(u8, repainted, terminal.escape.screen_reset) == null);
}

test "a turn failure the agent named itself reads as a sentence, not an error name" {
    for ([_]anyerror{
        error.UnsupportedReply,
        error.EmptyReply,
        error.IncompleteReply,
        error.UncorrelatedReply,
        error.TooManyToolCalls,
        error.TooManyToolRounds,
        error.CredentialReplaced,
        error.TokenGrantRejected,
        error.KeyRejected,
        error.TokenRequestFailed,
        error.TokenServiceUnavailable,
        error.StoreBusy,
    }) |err| {
        const text = turnFailureText(err).?;
        try std.testing.expect(std.mem.indexOf(u8, text, " ") != null);
        try std.testing.expect(!std.mem.eql(u8, text, @errorName(err)));
    }
    try std.testing.expectEqualStrings(
        "Drinky stopped the reply because it asked for more than 64 tool calls.",
        turnFailureText(error.TooManyToolCalls).?,
    );
    for ([_]anyerror{
        error.TokenServiceUnavailable,
        error.StoreBusy,
    }) |err| {
        const text = turnFailureText(err).?;
        try std.testing.expect(std.mem.indexOf(u8, text, "Try the turn again.") != null);
    }
    const replacement = turnFailureText(error.CredentialReplaced).?;
    try std.testing.expect(std.mem.indexOf(u8, replacement, "Try the turn again.") == null);
    try std.testing.expect(std.mem.indexOf(u8, replacement, "/model") == null);
    const credentials = turnFailureText(error.TokenGrantRejected).?;
    try std.testing.expect(std.mem.indexOf(u8, credentials, "signed out") == null);
    try std.testing.expect(std.mem.indexOf(u8, credentials, "/login") == null);
    try std.testing.expectEqual(null, turnFailureText(error.SignedOut));
}

test "a grant rejection refuses an account without a refresh credential" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const client = ai.provider.Client.init(gpa, io, .{ .anthropic_api_key = "key" }, .{});
    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, client, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_api_key;
    app.session.beginTurn(1);

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = zero_receipt,
            .disposition = .credential_rejected,
        },
        .error_text = null,
    };
    try std.testing.expectError(
        error.UnexpectedTokenGrantRejection,
        app.finishWorkerResult(&result),
    );
    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, app.activeAccount().?);
}

test "a canceled sign-in reads as a decision, not a failure" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    const block_count = app.session.transcript.blocks().len;
    try app.reportLoginFailure(.{ .account = .anthropic_plan }, error.Canceled);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.information, notice.severity);
    try std.testing.expectEqualStrings(
        "You canceled the sign-in to anthropic-plan.",
        notice.content,
    );
    try std.testing.expectEqual(block_count, app.session.transcript.blocks().len);
}

test "a login the provider refused reads as a sentence, not an error name" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.reportLoginFailure(.{ .account = .anthropic_plan }, error.TokenGrantRejected);
    try std.testing.expectEqualStrings(
        "The provider rejected the authorization. Start the sign-in again.",
        app.session.notice.?.content,
    );
    try app.reportLoginFailure(.{ .account = .anthropic_plan }, error.AuthorizationFailed);
    try std.testing.expectEqualStrings(
        "The provider did not authorize Drinky. Start the sign-in again.",
        app.session.notice.?.content,
    );
    try app.reportLoginFailure(.{ .account = .anthropic_plan }, error.AuthorizationDenied);
    try std.testing.expectEqualStrings(
        "The provider did not authorize Drinky. Start the sign-in again.",
        app.session.notice.?.content,
    );
    try app.reportLoginFailure(.{ .account = .anthropic_plan }, error.DeviceCodeExpired);
    try std.testing.expectEqualStrings(
        "Drinky stopped the sign-in because the authorization did not arrive in time.",
        app.session.notice.?.content,
    );
    try app.reportLoginFailure(.{ .account = .anthropic_plan }, error.StateMismatch);
    try std.testing.expectEqualStrings(
        "The response belongs to another sign-in. Start the sign-in again.",
        app.session.notice.?.content,
    );
    try app.reportLoginFailure(
        .{ .account = .anthropic_plan },
        error.TokenServiceUnavailable,
    );
    try std.testing.expectEqualStrings(
        "The provider credential service is not available. Try the sign-in again later.",
        app.session.notice.?.content,
    );
    try app.reportLoginFailure(.{ .account = .anthropic_plan }, error.TokenRequestFailed);
    try std.testing.expectEqualStrings(
        "Drinky could not sign in because of error TokenRequestFailed.",
        app.session.notice.?.content,
    );
}

test "OAuth callback bounds have friendly failure notices" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    const cases = [_]struct { anyerror, []const u8 }{
        .{
            error.CallbackTimeout,
            "Drinky stopped the sign-in because the browser did not respond in time.",
        },
        .{
            error.CallbackRequestTooLarge,
            "Drinky could not sign in because the browser response was too large.",
        },
        .{
            error.CallbackTimeoutUnavailable,
            "Drinky could not sign in because it could not set a browser time limit.",
        },
    };
    for (cases) |case| {
        const failure, const message = case;
        try app.reportLoginFailure(.{ .account = .anthropic_plan }, failure);
        const notice = app.session.notice.?;
        try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
        try std.testing.expectEqualStrings(message, notice.content);
        try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    }
}

test "the input reader closes the key queue at the end of stdin" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();

    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);
    app.tty.io = io;
    app.tty.in_handle = fds[0];

    const bounded = try ai.net.race(io, 2 * std.time.ms_per_s, readInput, .{&app});
    try bounded;

    var batch: [1]UiEvent = undefined;
    try std.testing.expectError(error.Closed, app.queue.get(io, &batch, 0));
}

test "turn producers keep their captured generation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const generation: u64 = 42;

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();

    var handler: TurnHandler = .{ .app = &app, .generation = generation };
    try handler.onText("text");
    try handler.onThinking("thinking");
    handler.onCheckpoint();
    try handler.onToolStart("read", "{}");
    {
        const summary = try gpa.dupe(u8, "summary");
        defer gpa.free(summary);
        try handler.onToolResult("read", "result", .{ .text = summary }, false);
    }
    try handler.onUsage(.{});
    const retry: ai.Agent.RetryAttempt = .{
        .attempt = 2,
        .cause = .{ .response = "Overloaded" },
    };
    try handler.onStreamReset(&retry);
    try handler.onSteering("steer", 1);
    try handler.onModelMismatch(.{ .requested = "claude-fable-5", .served = "claude-opus-5" });
    try handler.onModelMismatch(.{ .requested = "claude-fable-5", .served = "claude-opus-5" });
    try handler.onModelMismatch(.{ .requested = "claude-fable-5", .served = "claude-opus-4-8" });
    const result = runTurnWorker(&app, try gpa.dupe(u8, "prompt"), generation);
    defer app.freeWorkerResult(&result);
    try std.testing.expectEqual(generation, result.generation);
    try std.testing.expect(result.terminal_queued);
    try std.testing.expectEqualStrings(
        "Drinky could not complete the turn because of error SignedOut.",
        result.error_text.?,
    );

    var events: [10]UiEvent = undefined;
    const count = try app.queue.get(io, &events, events.len);
    defer for (events[0..count]) |event| event.deinit(gpa);
    try std.testing.expectEqual(events.len, count);
    for (events[0..count]) |event| switch (event) {
        .turn => |turn_event| try std.testing.expectEqual(generation, turn_event.generation),
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(@as(u64, 2), events[2].turn.progress_sequence_committed);
    const tool_result = events[3].turn.payload.tool_result;
    try std.testing.expectEqualStrings("summary", tool_result.summary.?.text);
    try std.testing.expectEqual(@as(u64, 4), events[4].turn.progress_sequence_committed);
    const queued_retry = events[5].turn.payload.stream_reset;
    try std.testing.expectEqual(@as(u32, 2), queued_retry.attempt);
    try std.testing.expectEqualStrings("Overloaded", queued_retry.cause.response);
    const mismatch = events[7].turn.payload.model_mismatch;
    try std.testing.expectEqualStrings("claude-fable-5", mismatch.requested);
    try std.testing.expectEqualStrings("claude-opus-5", mismatch.served);
    try std.testing.expectEqualStrings(
        "claude-opus-4-8",
        events[8].turn.payload.model_mismatch.served,
    );
    try std.testing.expect(events[events.len - 1].turn.payload == .turn_ended);
}

fn seedSteering(app: *App, text: []const u8) !void {
    try app.session.editor.insert(text);
    try app.session.reserveSteering();
    var draft = app.session.editor.detachTrimmed();
    app.session.commitSteeringDraft(&draft);
}

const zero_receipt: ai.Agent.Receipt = .{
    .history_base = 0,
    .history_end = 0,
    .steering_committed_count = 0,
};

fn fakeWorker(result: *const WorkerResult) WorkerResult {
    return result.*;
}

fn canceledWorker() WorkerResult {
    return .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .canceled },
        .error_text = null,
    };
}

fn committedCanceledWorker() WorkerResult {
    return .{
        .outcome = .{ .receipt = .{
            .history_base = 0,
            .history_end = 1,
            .steering_committed_count = 0,
        }, .disposition = .canceled },
        .error_text = null,
    };
}

fn endedPayload() Session.TurnEvent.Payload {
    return .turn_ended;
}

fn spawnCanceledTurn(app: *App) !void {
    app.turn_future = try app.io.concurrent(canceledWorker, .{});
}

fn spawnCommittedCanceledTurn(app: *App) !void {
    app.turn_future = try app.io.concurrent(committedCanceledWorker, .{});
}

test "a late steering return restores a paste as a live placeholder atom" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    const payload = "late\n" ** 15;
    const delivered = std.mem.trim(u8, payload, " \t\r\n");
    try app.agent.steering.push(delivered);
    try app.session.editor.paste(payload, true);
    try app.session.reserveSteering();
    var draft = app.session.editor.detachTrimmed();
    app.session.commitSteeringDraft(&draft);

    try app.returnLateSteering();
    try std.testing.expect(!app.session.hasSteering());
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const restored = try app.session.editor.expanded(.none);
    defer gpa.free(restored);
    try std.testing.expectEqualStrings(payload, restored);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);

    const remaining = try app.agent.steering.take();
    defer gpa.free(remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}

test "ctrl+c during a turn clears the draft first and cancels only on an empty editor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);
    try spawnCanceledTurn(&app);

    try app.session.editor.insert("keep the turn");
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.turn_future != null);

    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
}

test "esc and ctrl+d cancel a turn and keep the draft" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    for ([_]terminal.Input.Key{ .escape, .{ .ctrl = 'd' } }) |key| {
        app.session.beginTurn(1);
        try spawnCanceledTurn(&app);
        app.session.editor.clear();
        try app.session.editor.insert("keep the draft");

        try app.handleKey(&key);
        if (key == .escape) {
            try std.testing.expect(app.session.mode == .turn);
            try std.testing.expect(app.session.notice != null);
            try app.handleKey(&key);
        }
        try std.testing.expect(app.session.mode == .prompt);
        try std.testing.expect(app.turn_future == null);
        try std.testing.expectEqualStrings("keep the draft", app.session.editor.visible());
        try std.testing.expect(app.running);
    }
}

test "a key between two esc presses drops the turn-cancel confirmation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);
    try spawnCanceledTurn(&app);
    try app.session.editor.insert("draft");

    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.session.confirmations.contains(.turn_cancel));
    try app.handleKey(&.{ .char = 'x' });
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(!app.session.confirmations.contains(.turn_cancel));
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .turn);
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("draftx", app.session.editor.visible());
}

test "Esc dismisses a notice and leaves the turn running" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    app.session.beginTurn(1);
    try spawnCanceledTurn(&app);
    try app.handleKey(&.tab);
    try std.testing.expectEqualStrings(prompt_history_turn_notice, app.session.notice.?.content);
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(app.turn_future != null);
    try std.testing.expect(!app.session.confirmations.contains(.turn_cancel));

    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);

    app.session.beginTurn(1);
    try spawnCanceledTurn(&app);
    try app.session.editor.insert("draft");
    try app.handleKey(&.tab);
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(app.turn_future != null);
    try std.testing.expect(!app.session.confirmations.contains(.turn_cancel));
    try std.testing.expectEqualStrings("draft", app.session.editor.visible());

    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqualStrings(turn_cancel_notice, app.session.notice.?.content);
    try std.testing.expect(app.session.confirmations.contains(.turn_cancel));
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expectEqualStrings("draft", app.session.editor.visible());
}

test "a key between two ctrl+d presses drops the quit confirmation" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    try app.session.editor.insert("draft");

    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(app.running);
    try std.testing.expect(app.session.confirmations.contains(.quit));
    try app.handleKey(&.{ .char = 'x' });
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(!app.session.confirmations.contains(.quit));
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(app.running);
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(!app.running);
    try std.testing.expectEqualStrings("draftx", app.session.editor.visible());
}

test "canceling a turn joins and clears its active worker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    var started: std.atomic.Value(bool) = .init(false);
    var stopped: std.atomic.Value(bool) = .init(false);
    const work = struct {
        const Signals = struct {
            ready: *std.atomic.Value(bool),
            done: *std.atomic.Value(bool),
        };

        fn wait(worker_io: std.Io, signals: Signals) WorkerResult {
            signals.ready.store(true, .release);
            defer signals.done.store(true, .release);
            worker_io.sleep(.fromSeconds(60), .awake) catch {};
            return .{
                .outcome = .{ .receipt = zero_receipt, .disposition = .canceled },
                .error_text = null,
            };
        }
    };
    app.turn_future = try io.concurrent(work.wait, .{ io, work.Signals{
        .ready = &started,
        .done = &stopped,
    } });
    defer if (app.turn_future) |*future| {
        const result = future.cancel(io);
        app.freeWorkerResult(&result);
    };

    var poll: usize = 0;
    while (!started.load(.acquire) and poll < worker_start_rounds_max) : (poll += 1)
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    try std.testing.expect(started.load(.acquire));

    try app.cancelTurn();
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(stopped.load(.acquire));
    try std.testing.expect(app.session.mode == .prompt);
}

test "canceling a turn restores in-flight steering and reads the usage again" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 10 ++ "line";
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    const folded = try app.agent.steering.take();
    for (folded) |message| gpa.free(message);
    gpa.free(folded);

    try app.session.editor.insert("and Y");
    try app.submitSteering();
    app.agent.stats.cost = 1.5;

    try spawnCanceledTurn(&app);
    try app.cancelTurn();
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload ++ "\n\nand Y", expanded);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(f64, 1.5), app.session.stats_shown.cost);
    try std.testing.expect(app.session.mode == .prompt);
}

test "cancel preflight failure leaves the turn and steering untouched" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("restore me");
    try app.submitSteering();
    try spawnCanceledTurn(&app);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expectError(error.OutOfMemory, app.cancelTurn());
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try app.cancelTurn();
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("restore me", app.session.editor.visible());
}

test "cancel restores steering before event allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("restore me");
    try app.submitSteering();
    try spawnCommittedCanceledTurn(&app);
    try app.session.reserveSteeringRestore();
    try app.session.reserveRevisionCapture();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expectError(error.OutOfMemory, app.cancelTurn());
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("restore me", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    const taken = try app.agent.steering.take();
    defer gpa.free(taken);
    try std.testing.expectEqual(@as(usize, 0), taken.len);
}

test "ctrl+p recalls the steering queue before in-progress editor text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("fix it");
    try app.submitSteering();
    try app.session.editor.insert("and test");
    try app.submitSteering();
    try app.session.editor.insert("draft");

    try app.handleKey(&.{ .ctrl = 'p' });
    try std.testing.expectEqualStrings("fix it\n\nand test\n\ndraft", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(app.session.editor.visible().len, app.session.editor.caret);
}

test "ctrl+p restores a steered paste as a live placeholder atom" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 15;
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(u64, 1), app.session.editor.draft.atoms.items[0].id);
    try std.testing.expect(
        std.mem.indexOf(u8, app.session.editor.visible(), "[Paste #1: 16 lines]") != null,
    );
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
}

test "cancel restores an in-flight steered paste as a live placeholder atom" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 15;
    const delivered = std.mem.trim(u8, payload, " \t\r\n");
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    const folded = try app.agent.steering.take();
    try std.testing.expectEqual(@as(usize, 1), folded.len);
    try std.testing.expectEqualStrings(delivered, folded[0]);
    for (folded) |message| gpa.free(message);
    gpa.free(folded);

    try spawnCanceledTurn(&app);
    try app.cancelTurn();
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expect(app.session.mode == .prompt);
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, delivered),
            .count = 1,
        } },
    });
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
}

test "cancel restores a steered paste even after its consumed event applied" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 15;
    const delivered = std.mem.trim(u8, payload, " \t\r\n");
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    const folded = try app.agent.steering.take();
    try std.testing.expectEqual(@as(usize, 1), folded.len);
    try std.testing.expectEqualStrings(delivered, folded[0]);
    for (folded) |message| gpa.free(message);
    gpa.free(folded);
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, delivered),
            .count = 1,
        } },
    });

    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);

    try spawnCanceledTurn(&app);
    try app.cancelTurn();
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "ctrl+p recalls the pending suffix and retains the in-flight prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try seedSteering(&app, "folded");
    try app.session.editor.insert("pending");
    try app.submitSteering();
    try std.testing.expectEqual(@as(usize, 2), app.session.steering.items.len);

    try app.pullSteering();
    try std.testing.expectEqualStrings("pending", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);
}

test "cancel restores an in-flight prefix retained by ctrl+p" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try seedSteering(&app, "folded");
    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);

    try spawnCanceledTurn(&app);
    try app.cancelTurn();
    try std.testing.expectEqualStrings("folded", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering_retained_count);
    try std.testing.expect(app.session.mode == .prompt);
}

test "a cancel that loses the race waits for the terminal fence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(7);

    try app.agent.steering.push("keep");
    try seedSteering(&app, "keep");

    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .completed },
        .error_text = null,
        .terminal_queued = true,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});
    try app.cancelTurn();

    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(app.pending_turn_result != null);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    const events = [_]UiEvent{.{ .turn = .{
        .generation = 7,
        .payload = endedPayload(),
    } }};
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.pending_turn_result == null);
    try std.testing.expectEqualStrings("keep", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "cancel does not commit stale text across a reset held in the current batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.input.deinit();
    app.session.beginTurn(1);

    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "stale attempt") },
    });
    try app.queue.putOne(io, .{ .turn = .{
        .generation = 1,
        .progress_sequence = 3,
        .payload = .{ .text = try gpa.dupe(u8, "committed retry") },
    } });
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = .{
            .history_base = 0,
            .history_end = 1,
            .steering_committed_count = 0,
        }, .disposition = .canceled },
        .error_text = null,
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 3,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    const events = [_]UiEvent{
        .{ .keys = try gpa.dupe(u8, "\x03") },
        .{ .turn = .{
            .generation = 1,
            .progress_sequence = 2,
            .payload = .{ .stream_reset = .{
                .attempt = 2,
                .cause = .{ .failure = error.Timeout },
            } },
        } },
    };
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .prompt);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "You canceled the turn.",
        blocks[0].content.event.text.items,
    );
}

test "cancel preserves progress before a queued terminal fence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.input.deinit();
    app.session.beginTurn(11);
    try seedSteering(&app, "folded");

    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = .{
            .history_base = 0,
            .history_end = 0,
            .steering_committed_count = 1,
        }, .disposition = .completed },
        .error_text = null,
        .terminal_queued = true,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    const events = [_]UiEvent{
        .{ .keys = try gpa.dupe(u8, "\x03") },
        .{ .turn = .{
            .generation = 11,
            .payload = .{ .text = try gpa.dupe(u8, "answer") },
        } },
        .{ .turn = .{
            .generation = 11,
            .payload = .{ .steering_consumed = .{
                .text = try gpa.dupe(u8, "folded"),
                .count = 1,
            } },
        } },
        .{ .turn = .{ .generation = 11, .payload = endedPayload() } },
    };
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(app.pending_turn_result == null);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("answer", blocks[0].content.model.items);
    try std.testing.expectEqualStrings("folded", blocks[1].content.user.items);
}

test "cancel replaces an interrupted terminal fence after queued progress" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.input.deinit();
    app.session.beginTurn(12);
    try seedSteering(&app, "folded");

    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = .{
            .history_base = 0,
            .history_end = 0,
            .steering_committed_count = 1,
        }, .disposition = .completed },
        .error_text = null,
        .generation = 12,
        .terminal_queued = false,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    const events = [_]UiEvent{
        .{ .keys = try gpa.dupe(u8, "\x03") },
        .{ .turn = .{
            .generation = 12,
            .payload = .{ .text = try gpa.dupe(u8, "answer") },
        } },
        .{ .turn = .{
            .generation = 12,
            .payload = .{ .steering_consumed = .{
                .text = try gpa.dupe(u8, "folded"),
                .count = 1,
            } },
        } },
    };
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.pending_turn_result.?.terminal_queued);
    const prefix = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), prefix.len);
    try std.testing.expectEqualStrings("answer", prefix[0].content.model.items);
    try std.testing.expectEqualStrings("folded", prefix[1].content.user.items);

    var fence: [1]UiEvent = undefined;
    const count = try app.queue.get(io, &fence, 1);
    try std.testing.expectEqual(fence.len, count);
    try std.testing.expect(!try app.applyBatch(fence[0..count]));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.pending_turn_result == null);
    try std.testing.expectEqual(@as(usize, 2), app.session.transcript.blocks().len);
}

test "an interrupted terminal fence retries after a full queue drain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.input.deinit();
    app.session.beginTurn(13);

    const filler = [_]UiEvent{.resize} ** queue_capacity;
    try app.queue.putAll(io, &filler);
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .completed },
        .error_text = null,
        .generation = 13,
        .terminal_queued = false,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    const events = [_]UiEvent{
        .{ .keys = try gpa.dupe(u8, "\x03") },
        .{ .turn = .{
            .generation = 13,
            .payload = .{ .text = try gpa.dupe(u8, "answer") },
        } },
    };
    try std.testing.expect(!try app.applyBatch(&events));
    try std.testing.expect(!app.pending_turn_result.?.terminal_queued);
    try std.testing.expect(app.session.mode == .turn);

    var first: [1]UiEvent = undefined;
    const first_count = try app.queue.get(io, &first, first.len);
    try std.testing.expectEqual(first.len, first_count);
    app.enqueuePendingTurnFence();
    try std.testing.expect(app.pending_turn_result.?.terminal_queued);
    try std.testing.expect(!try app.applyBatch(first[0..first_count]));

    var rest: [queue_capacity]UiEvent = undefined;
    const rest_count = try app.queue.get(io, &rest, rest.len);
    try std.testing.expectEqual(rest.len, rest_count);
    try std.testing.expect(!try app.applyBatch(rest[0..rest_count]));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.pending_turn_result == null);
    try std.testing.expectEqualStrings(
        "answer",
        app.session.transcript.blocks()[0].content.model.items,
    );
}

test "a cancel that loses the race applies the failed joined result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(3);
    try app.session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    app.session.retainTurnPrompt(&prompt, 0);
    try seedSteering(&app, "steer");
    try app.agent.steering.push("steer");

    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .{ .failed = error.Boom } },
        .error_text = try gpa.dupe(u8, "boom"),
        .generation = 3,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});
    try app.cancelTurn();
    try std.testing.expect(app.session.mode == .turn);

    var events: [1]UiEvent = undefined;
    const count = try app.queue.get(io, &events, 1);
    try std.testing.expectEqual(events.len, count);
    try std.testing.expect(!try app.applyBatch(events[0..count]));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("prompt\n\nsteer", app.session.editor.visible());
    const remaining_steering = try app.agent.steering.take();
    defer {
        for (remaining_steering) |message| gpa.free(message);
        gpa.free(remaining_steering);
    }
    try std.testing.expectEqual(@as(usize, 0), remaining_steering.len);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("boom", blocks[0].content.event.text.items);
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "boom") != null);
}

test "a joined completion returns late steering to the editor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.turn_generation = 3;
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(3);

    try app.agent.steering.push("older");
    try seedSteering(&app, "older");
    try app.session.editor.insert("draft");
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .completed },
        .error_text = null,
        .generation = 3,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});
    try app.cancelTurn();
    try std.testing.expect(app.session.mode == .turn);

    var events: [1]UiEvent = undefined;
    const count = try app.queue.get(io, &events, 1);
    try std.testing.expectEqual(events.len, count);
    try std.testing.expect(!try app.applyBatch(events[0..count]));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings("older\n\ndraft", app.session.editor.visible());
    try std.testing.expect(!app.session.hasSteering());
    try std.testing.expectEqualStrings(
        "Drinky returned every queued message to the editor.",
        app.session.notice.?.content,
    );
    const remaining = try app.agent.steering.take();
    defer gpa.free(remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}

test "shutdown frees the worker result without restoring or recording an event" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try seedSteering(&app, "keep");
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .{ .failed = error.Boom } },
        .error_text = try gpa.dupe(u8, "boom"),
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    app.shutdownTasks();
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expect(app.turn_future == null);
}

test "a delayed consumed event after ctrl+p cannot remove newer steering" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("old");
    try app.submitSteering();
    const folded = try app.agent.steering.take();
    for (folded) |message| gpa.free(message);
    gpa.free(folded);

    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);
    try app.session.editor.insert("new");
    try app.submitSteering();

    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, "old"),
            .count = 1,
        } },
    });
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);
    try std.testing.expectEqual(@as(usize, 2), app.session.steering.items.len);
    try std.testing.expectEqualStrings(
        "new",
        app.session.steering.items[app.session.steering_retained_count].draft.visible.items,
    );

    try app.pullSteering();
    try std.testing.expectEqualStrings("new", app.session.editor.visible());
}

test "a delivery restored after ctrl+p recalls its retained rich drafts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("a");
    try app.submitSteering();
    try app.session.editor.insert("b");
    try app.submitSteering();
    var delivery = try app.agent.steering.take();
    defer {
        for (delivery) |message| gpa.free(message);
        gpa.free(delivery);
    }

    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 2), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.session.steering_retained_count);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    app.agent.steering.restoreTaken(&delivery);
    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering_retained_count);
    try std.testing.expectEqualStrings("a\n\nb", app.session.editor.visible());
}

test "recall of literal-edge-trimmed steering rejoins without edge spaces" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert(" a ");
    try app.submitSteering();
    try app.session.editor.insert(" b ");
    try app.submitSteering();
    try app.pullSteering();
    try std.testing.expectEqualStrings("a\n\nb", app.session.editor.visible());
}

test "mid-turn Enter queues a message but refuses a slash line or a blank line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("/model");
    try app.submitSteering();
    try std.testing.expectEqualStrings("/model", app.session.editor.visible());
    try std.testing.expectEqualStrings(
        "The command /model cannot run while a turn runs.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqual(
        ai.command.Outcome.Severity.warning,
        app.session.notice.?.severity,
    );

    app.session.editor.clear();
    try app.session.editor.insert("   ");
    try app.submitSteering();
    try std.testing.expectEqualStrings("   ", app.session.editor.visible());

    app.session.editor.clear();
    try app.session.editor.insert("/model names the account too");
    try app.submitSteering();
    try std.testing.expectEqualStrings(
        "/model names the account too",
        app.session.editor.visible(),
    );
    try std.testing.expectEqualStrings(
        "Enter: Queue as a message · The command /model takes no argument.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqual(
        ai.command.Outcome.Severity.warning,
        app.session.notice.?.severity,
    );

    app.session.cancelConfirmation(.message);
    app.session.editor.clear();
    try app.session.editor.insert("/nope");
    try app.submitSteering();
    try std.testing.expectEqualStrings("/nope", app.session.editor.visible());
    try std.testing.expectEqualStrings(
        "Enter: Queue as a message · Drinky does not recognize the command /nope.",
        app.session.notice.?.content,
    );

    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    const blocked = try app.agent.steering.take();
    defer gpa.free(blocked);
    try std.testing.expectEqual(@as(usize, 0), blocked.len);
    app.session.cancelConfirmation(.message);

    app.session.editor.clear();
    try app.session.editor.insert("the account matters too");
    try app.submitSteering();
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    const taken = try app.agent.steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings("the account matters too", taken[0]);
}

const test_status_line = "Context: 0% (0/1.0M) · Cost: ~$0.00 · " ++
    "Model: anthropic-plan/claude-opus-5 · Effort: low";

test "/status records one terminal event for each request, also during a turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.handleKeys("/status\r");
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    const first = &app.session.transcript.blocks()[0].content.event;
    try std.testing.expectEqualStrings(test_status_line, first.text.items);
    try std.testing.expect(!first.is_error);
    try std.testing.expect(!first.mirrored);
    try std.testing.expect(first.survives_rewind);

    try app.handleKeys("/status\r");
    try std.testing.expectEqual(@as(usize, 2), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings(test_status_line, app.lastEventText());

    app.session.beginTurn(1);
    app.retry = .{ .failure = try gpa.dupe(u8, "an older failure") };
    defer app.dropRetry();
    try app.handleKeys("/effort\r");
    try std.testing.expectEqualStrings("/effort", app.session.editor.visible());
    try std.testing.expectEqualStrings(
        "The command /effort cannot run while a turn runs.",
        app.session.notice.?.content,
    );
    app.session.editor.clear();
    try app.handleKeys("/status\r");
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 3), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings(test_status_line, app.lastEventText());
    try std.testing.expect(!app.session.hasSteering());
    try std.testing.expect(app.retry != null);
    const queued = try app.agent.steering.take();
    defer gpa.free(queued);
    try std.testing.expectEqual(@as(usize, 0), queued.len);
    try app.handleKeys("/status now\r");
    try std.testing.expectEqualStrings("/status now", app.session.editor.visible());
    try std.testing.expectEqualStrings(
        "Enter: Queue as a message · The command /status takes no argument.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqual(@as(usize, 3), app.session.transcript.blocks().len);
}

test "a terminal status event neither splits a streamed reply nor disappears after a failed turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    var opening = [_]UiEvent{.{ .turn = .{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "partial ") },
    } }};
    _ = try app.applyBatch(&opening);
    try app.handleKeys("/status\r");
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    var closing = [_]UiEvent{.{ .turn = .{
        .generation = 1,
        .progress_sequence = 2,
        .payload = .{ .text = try gpa.dupe(u8, "answer") },
    } }};
    _ = try app.applyBatch(&closing);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        "partial answer",
        app.session.transcript.blocks()[0].content.model.items,
    );

    var result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .{ .failed = error.ApiError } },
        .error_text = try gpa.dupe(u8, "The provider refused the request."),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);
    try std.testing.expect(app.session.mode == .prompt);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings(
        "The provider refused the request.",
        blocks[0].content.event.text.items,
    );
    try std.testing.expectEqualStrings(test_status_line, blocks[1].content.event.text.items);
    try std.testing.expect(!blocks[1].content.event.mirrored);
}

test "late placeholder steering returns before a newer key in the same batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.input.deinit();
    defer app.drainQueue();
    defer if (app.turn_future) |*future| {
        const result = future.cancel(io);
        app.freeWorkerResult(&result);
    };
    app.turn_generation = 1;
    app.session.beginTurn(1);
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .completed },
        .error_text = null,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    const payload = "line\n" ** 10 ++ "line";
    try app.session.editor.paste(payload, true);
    try app.submitSteering();
    const events = [_]UiEvent{
        .{ .turn = .{ .generation = 1, .payload = endedPayload() } },
        .{ .keys = try gpa.dupe(u8, "new") },
    };
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload ++ "new", expanded);
}

test "a drained batch routes only the active turn generation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    app.session.beginTurn(1);
    const first = [_]UiEvent{.{ .turn = .{
        .generation = 1,
        .payload = .{ .text = try gpa.dupe(u8, "turn A") },
    } }};
    try std.testing.expect(!try app.applyBatch(&first));
    try app.session.abortTurn();
    app.session.beginTurn(2);
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .completed },
        .error_text = null,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    const rest = [_]UiEvent{
        .{ .turn = .{
            .generation = 1,
            .payload = .{ .text = try gpa.dupe(u8, "stale A") },
        } },
        .{ .turn = .{ .generation = 1, .payload = endedPayload() } },
        .{ .turn = .{ .generation = 1, .payload = endedPayload() } },
        .{ .turn = .{
            .generation = 2,
            .payload = .{ .text = try gpa.dupe(u8, "turn B") },
        } },
        .{ .turn = .{ .generation = 2, .payload = endedPayload() } },
    };
    try std.testing.expect(!try app.applyBatch(&rest));

    try std.testing.expect(!app.session.animating());
    try std.testing.expectEqual(@as(usize, 3), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        "turn B",
        app.session.transcript.blocks()[2].content.model.items,
    );
}

test "a resize event marks an idle interface dirty" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try std.testing.expect(!try app.applyBatch(&[_]UiEvent{.resize}));
    try std.testing.expect(app.session.dirty);
}

test "a failed batch frees its unprocessed turn events" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const events = [_]UiEvent{
        .{ .turn = .{
            .generation = 1,
            .payload = .{ .text = try gpa.dupe(u8, "current") },
        } },
        .{ .turn = .{
            .generation = 1,
            .payload = .{ .text = try gpa.dupe(u8, "unprocessed") },
        } },
    };
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, app.applyBatch(&events));
}

test "generations cannot wrap or be reused" {
    var counter: u64 = std.math.maxInt(u64) - 1;
    try std.testing.expectEqual(std.math.maxInt(u64), try reserveGeneration(&counter));
    try std.testing.expectError(error.GenerationExhausted, reserveGeneration(&counter));
    try std.testing.expectEqual(std.math.maxInt(u64), counter);
}

test "a legacy escape byte closes a page after its wait" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    try app.session.openPage(&.{ .title = "Test page", .content = "body" });

    try app.handleKeys("\x1b");
    try std.testing.expect(app.session.mode == .viewing);
    try std.testing.expect(app.escape_deadline_ms != null);
    try app.flushEscape();
    try std.testing.expect(app.session.mode == .viewing);

    app.escape_deadline_ms = app.nowMs() - 1;
    try app.flushEscape();
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.escape_deadline_ms == null);
    try std.testing.expect(app.running);

    try app.handleKeys("\x1b");
    try std.testing.expect(app.escape_deadline_ms != null);
    try app.handleKeys("[A");
    try std.testing.expect(app.escape_deadline_ms == null);
    try app.flushEscape();
}

test "a page close drops the rest of an exit attempt in one chunk" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    for ([_][]const u8{ "\x1b\x03", "\x1b\x04" }) |chunk| {
        var app: App = undefined;
        app.initForTest(gpa);
        defer app.input.deinit();
        app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
        defer app.session.deinit();
        try app.session.editor.insert("draft");
        try app.session.openPage(&.{ .title = "Test page", .content = "body" });

        try app.handleKeys(chunk);
        try std.testing.expect(app.session.mode == .prompt);
        try std.testing.expect(app.running);
        try std.testing.expectEqualStrings("draft", app.session.editor.visible());
        try std.testing.expectEqual(@as(i64, -ctrl_c_window_ms), app.ctrl_c_ms_last);
        try std.testing.expect(app.escape_deadline_ms == null);
    }
}

test "a picker confirmation keeps the characters typed behind it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    const options = try gpa.alloc(ai.command.Outcome.Pick.Option, 1);
    options[0] = .{ .name = try gpa.dupe(u8, "alpha") };
    try app.session.applyOutcome(.{ .pick = .{
        .select = struct {
            fn select(
                context: *ai.command.Context,
                _: ai.command.Outcome.Pick.Selection,
            ) anyerror!ai.command.Outcome {
                return ai.command.Outcome.reportNotice(context.gpa, .information, "picked", .{});
            }
        }.select,
        .title = "Sign in",
        .cancellation_message = "You canceled the sign-in selection.",
        .options = options,
        .current = null,
    } });

    try app.handleKeys("\rhi");
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("hi", app.session.editor.visible());
}

test "a turn cancel drops the rest of an exit attempt in one chunk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    defer app.input.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);
    try spawnCanceledTurn(&app);

    try app.handleKeys("\x1b\x04");
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(app.running);
}

test "ctrl+c clears then quits within the window and a draft makes ctrl+d ask twice" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.editor.insert("draft");
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(app.running);
    const notice = app.session.notice.?;
    try std.testing.expect(notice.severity == .warning);
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "Ctrl+D") != null);
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(!app.running);

    app.running = true;
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.running);
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(!app.running);

    app.running = true;
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(!app.running);
}

test "a send refuses while the account offers no model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = ai.testing.accounts(.{ .anthropic = "sk-ant" });
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();

    try app.session.editor.insert("do the work");
    try app.submit();

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("do the work", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expect(app.session.notice != null);
    try std.testing.expectEqualStrings(no_model_refusal, app.session.notice.?.content);
}

test "a refused send keeps the typed text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.editor.insert("keep this line");
    try app.submit();
    try std.testing.expectEqualStrings("keep this line", app.session.editor.visible());

    try app.applySubmittedCommand(.{ .prompt = .{
        .name = try gpa.dupe(u8, "zig-style"),
        .arguments = try gpa.dupe(u8, "review this file"),
        .content = try gpa.dupe(u8, "the whole skill file"),
        .source = try gpa.dupe(u8, "/work/.agents/skills/zig-style/SKILL.md"),
    } });
    try std.testing.expectEqualStrings("keep this line", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "/new clears the conversation and the scrollback without a configuration change" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "test system",
        .retry = .{},
        .environ = .empty,
        .effort = .high,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .high);
    defer app.session.deinit();

    const cache_key = app.agent.cache_key;
    try app.agent.items.append(gpa, .{ .message = .{
        .role = .user,
        .text = try gpa.dupe(u8, "old prompt"),
    } });
    const seeded: ai.Agent.Stats = .{ .cost = 2.5, .cache_usage = .{ .input = 10 } };
    app.agent.stats = seeded;
    try app.agent.steering.push("old steering");
    try app.session.transcript.append(.user, .{}, "old prompt");
    app.session.stats_shown = seeded;
    try seedSteering(&app, "old steering");
    try app.session.paint(.{ .columns = 80, .rows = 6 });

    try app.session.editor.insert("/new");
    try app.submit();

    const clear_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 6 });
    const clear_bytes = out.written()[clear_start..];
    try std.testing.expect(std.mem.indexOf(u8, clear_bytes, terminal.escape.screen_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, clear_bytes, "old prompt") == null);

    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    try std.testing.expect(std.meta.eql(ai.Agent.Stats{}, app.agent.stats));
    try std.testing.expect(!std.mem.eql(u8, &cache_key, &app.agent.cache_key));
    const steering = try app.agent.steering.take();
    defer gpa.free(steering);
    try std.testing.expectEqual(@as(usize, 0), steering.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        intro_text,
        app.session.transcript.blocks()[0].content.intro.items,
    );
    try std.testing.expect(std.meta.eql(ai.Agent.Stats{}, app.session.stats_shown));
    try std.testing.expect(!app.session.hasSteering());
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try app.expectModel(test_anthropic_model.name());
    try std.testing.expectEqual(ai.llm.Effort.high, app.agent.effort);
}

test "/new forgets the skill proof of the conversation it clears" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.skill_guard = .{};
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "test system",
        .retry = .{},
        .environ = .empty,
        .effort = .high,
        .skill_guard = &app.skill_guard,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .high);
    defer app.session.deinit();
    try app.skill_guard.add(.{
        .glob = "**/*.zig",
        .skill = "demo",
        .source = "/skills/demo/SKILL.md",
    });
    app.skill_guard.rule_items[0].loaded.store(true, .monotonic);
    try std.testing.expect(app.skill_guard.rule_items[0].loaded.load(.monotonic));

    try app.applyOutcome(.new_conversation);

    try std.testing.expect(!app.skill_guard.rule_items[0].loaded.load(.monotonic));
}

test "/system opens the composed prompt alone and escape restores the conversation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const full_prompt = "# Core\n\n" ++ "system row\n" ** 30;
    var app: App = undefined;
    app.initForTest(gpa);
    app.prompt = full_prompt;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = full_prompt,
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.transcript.append(.event, .{}, "history marker");
    try app.session.editor.insert("/system");
    try app.submit();

    try std.testing.expect(app.session.mode == .viewing);
    try std.testing.expectEqualStrings(full_prompt, app.session.mode.viewing.content);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    const page_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 6 });
    const page_bytes = out.written()[page_start..];
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "System prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "M: Source") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "Core") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "# Core") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "history marker") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, test_anthropic_model.name()) == null);

    try app.handleKey(&.{ .char = 'm' });
    try std.testing.expect(app.session.mode.viewing.presentation == .source);
    const source_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 6 });
    const source_bytes = out.written()[source_start..];
    try std.testing.expect(std.mem.indexOf(u8, source_bytes, "M: Render") != null);
    try std.testing.expect(std.mem.indexOf(u8, source_bytes, "# Core") != null);
    try app.handleKey(&.{ .char = 'M' });
    try std.testing.expect(app.session.mode.viewing.presentation == .markdown);

    const resize_start = out.written().len;
    try app.session.paint(.{ .columns = 40, .rows = 5 });
    const resize_bytes = out.written()[resize_start..];
    try std.testing.expect(std.mem.indexOf(u8, resize_bytes, terminal.escape.screen_repaint) != null);
    try std.testing.expect(std.mem.indexOf(u8, resize_bytes, "\x1b[3J") == null);

    try app.handleKey(&.page_down);
    try std.testing.expect(app.session.mode.viewing.scroll > 0);
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);

    try app.session.editor.insert("/system");
    try app.submit();
    const reopen_start = out.written().len;
    try app.session.paint(.{ .columns = 40, .rows = 5 });
    const reopen_bytes = out.written()[reopen_start..];
    try std.testing.expect(std.mem.indexOf(u8, reopen_bytes, terminal.escape.screen_repaint) != null);
    try std.testing.expect(std.mem.indexOf(u8, reopen_bytes, "M: Source") != null);
    try std.testing.expect(std.mem.indexOf(u8, reopen_bytes, "Core") != null);
    try std.testing.expect(std.mem.indexOf(u8, reopen_bytes, "# Core") == null);
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.running);

    const conversation_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 6 });
    const conversation_bytes = out.written()[conversation_start..];
    try std.testing.expect(std.mem.indexOf(u8, conversation_bytes, "history marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation_bytes, "System prompt") == null);
}

test "ctrl+d closes a page and restores the conversation" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.transcript.append(.event, .{}, "history marker");
    try app.session.openPage(&.{ .title = "Test page", .content = "body" });
    try std.testing.expect(app.session.mode == .viewing);

    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.running);
    const conversation_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 12 });
    const conversation_bytes = out.written()[conversation_start..];
    try std.testing.expect(std.mem.indexOf(u8, conversation_bytes, "history marker") != null);
}

test "an account-switch command clears the quota snapshot and records the project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    const anthropic_client = ai.provider.Client.init(
        gpa,
        io,
        .{ .anthropic_plan = undefined },
        .{},
    );
    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, anthropic_client, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();
    try app.state.seed(.anthropic_plan, test_anthropic_model, .low);

    app.agent.stats.quota = .{
        .secondary = .{ .used_percent = 77, .window_minutes = 10080 },
    };
    app.agent.stats.credits = .{ .total = 10, .used = 2 };
    app.session.stats_shown = app.agent.stats;

    const openai_client = ai.provider.Client.init(gpa, io, .{ .openai_api_key = "sk-test" }, .{});
    app.agent.switchTo(openai_client, test_openai_model);
    try app.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .information, "switched", .{}),
    );

    try std.testing.expect(app.agent.stats.quota == null);
    try std.testing.expect(app.session.stats_shown.quota == null);
    try std.testing.expect(app.agent.stats.credits == null);
    try std.testing.expect(app.session.stats_shown.credits == null);
    try std.testing.expectEqualStrings(test_openai_model.name(), app.session.model_shown.?.name());
    try std.testing.expectEqual(ai.llm.Account.openai_api_key, app.session.account_shown.?);

    var file = (try ai.json_store.open(gpa, io, app.state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("openai-api-key", entry.get("account").?.string);
    try std.testing.expectEqualStrings("low", entry.get("effort").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqualStrings(
        test_openai_model.name(),
        listed.get("openai-api-key").?.string,
    );
    try std.testing.expectEqualStrings(
        test_anthropic_model.name(),
        listed.get("anthropic-plan").?.string,
    );
}

test "an account switch projects the conversation for the new account" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const anthropic_client = ai.provider.Client.init(
        gpa,
        io,
        .{ .anthropic_plan = undefined },
        .{},
    );
    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, anthropic_client, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
        .effort = .high,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .high);
    defer app.session.deinit();
    app.session.showSetup(.anthropic_plan, test_anthropic_model, .high);

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_plan = .{
        .signature = .{ .text = "weigh it", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "weigh it");
    try app.session.transcript.appendStream(.model, null, "the answer");
    try app.session.paint(.{ .columns = 80, .rows = 24 });

    const switched_start = out.written().len;
    const openai_client = ai.provider.Client.init(gpa, io, .{ .openai_api_key = "sk-test" }, .{});
    app.agent.switchTo(openai_client, test_openai_model);
    try app.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .information, "switched", .{}),
    );

    try std.testing.expectEqual(@as(usize, 1), app.agent.items.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.session.transcript.blocks().len);
    try std.testing.expect(app.session.view.force_reset);
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    const switched = try terminal.View.plainText(gpa, out.written()[switched_start..]);
    defer gpa.free(switched);
    try std.testing.expect(std.mem.indexOf(u8, switched, "weigh it") == null);
    try std.testing.expect(std.mem.indexOf(u8, switched, "the answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, switched, "switched") != null);
}

test "account evidence removal retreats the mirror only over dropped blocks below the cursor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .high);
    defer app.session.deinit();
    app.session.showSetup(.anthropic_plan, test_anthropic_model, .high);

    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "weigh it");
    try app.session.transcript.appendStream(.model, null, "the answer");
    try app.session.transcript.append(.event, .{}, "You attached @bot.");
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "weigh again");
    app.mirror.cursor = 3;

    app.dropAccountEvidence(.anthropic_plan);

    try std.testing.expectEqual(@as(usize, 2), app.session.transcript.blocks().len);
    try std.testing.expectEqual(@as(usize, 2), app.mirror.cursor);

    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "once more");
    app.mirror.cursor = 9;
    app.dropAccountEvidence(.anthropic_plan);
    try std.testing.expectEqual(@as(usize, 2), app.session.transcript.blocks().len);
    try std.testing.expectEqual(@as(usize, 8), app.mirror.cursor);
}

test "startup resumes on the account, model, and effort level this project used last" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "openai-api-key", "effort": "low",
        \\    "models": { "openai-api-key": "gpt-5.6-luna" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-luna"});
    try ai.testing.seedAccount(&app.accounts, .anthropic_api_key, &.{"claude-opus-5"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    try std.testing.expectEqual(ai.llm.Account.openai_api_key, app.startAccount().?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", app.accountModel(.openai_api_key).?.name());
    try std.testing.expect(app.accountModel(.anthropic_api_key) == null);
    try std.testing.expectEqual(ai.llm.Effort.low, app.startEffort(.max));
}

test "a signed-out remembered account falls back and the defaults fill the rest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "openai-api-key",
        \\    "models": { "openai-api-key": "gpt-5.6-luna" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "sk-anthropic" });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-luna"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, app.startAccount().?);
    try std.testing.expect(app.accountModel(.anthropic_api_key) == null);
    try std.testing.expectEqualStrings("gpt-5.6-luna", app.accountModel(.openai_api_key).?.name());
    try std.testing.expectEqual(ai.llm.Effort.medium, app.startEffort(.medium));
    try std.testing.expectEqual(effort_default, app.startEffort(null));
}

test "a switch back to an account restores the model that account ran" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic-api-key", "effort": "low",
        \\    "models": { "anthropic-api-key": "claude-sonnet-5" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_api_key, &.{"claude-sonnet-5"});
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    const start_model = app.accountModel(.anthropic_api_key);
    try std.testing.expectEqualStrings("claude-sonnet-5", start_model.?.name());
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = start_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, start_model, .low);
    defer app.session.deinit();
    try app.state.seed(.anthropic_api_key, start_model, .low);

    try app.applyOutcome(.{ .switch_account = .openai_api_key });
    try std.testing.expect(app.agent.model == null);

    try app.applyOutcome(.{ .switch_account = .anthropic_api_key });
    try app.expectModel("claude-sonnet-5");

    var file = (try ai.json_store.open(gpa, io, app.state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic-api-key", entry.get("account").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqualStrings("claude-sonnet-5", listed.get("anthropic-api-key").?.string);
    try std.testing.expect(listed.get("openai-api-key") == null);
}

test "a transition names the pick where the list of the account stands cached" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic-api-key", "effort": "low",
        \\    "models": { "anthropic-api-key": "claude-sonnet-5" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_api_key, &.{"claude-sonnet-5"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    const start_model = app.accountModel(.anthropic_api_key);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = start_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, start_model, .low);
    defer app.session.deinit();

    try app.applyOutcome(.{ .switch_account = .openai_api_key });
    try std.testing.expect(app.agent.model == null);
    try std.testing.expectEqualStrings(
        "Drinky now uses openai-api-key. Fetch the model list of openai-api-key with /model.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );

    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    try app.applyOutcome(.{ .switch_account = .anthropic_api_key });
    try app.expectModel("claude-sonnet-5");
    try app.applyOutcome(.{ .switch_account = .openai_api_key });
    try std.testing.expect(app.agent.model == null);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqualStrings(
        "Drinky now uses openai-api-key. Select a model of openai-api-key with /model.",
        blocks[blocks.len - 1].content.event.text.items,
    );
}

test "a model name the catalog cannot resolve stays in the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic-api-key", "effort": "low",
        \\    "models": { "anthropic-api-key": "claude-sonnet-5",
        \\      "openai-api-key": "gpt-5.6-sol" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    try std.testing.expect(app.accountModel(.anthropic_api_key) == null);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();
    try app.state.seed(.anthropic_api_key, null, .low);

    try app.applyOutcome(.{ .switch_account = .openai_api_key });
    var file = (try ai.json_store.open(gpa, io, app.state.path)).?;
    defer file.deinit();
    const listed = file.entry("/work").?.get("models").?.object;
    try std.testing.expectEqualStrings("claude-sonnet-5", listed.get("anthropic-api-key").?.string);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed.get("openai-api-key").?.string);

    try ai.testing.seedAccount(&app.accounts, .anthropic_api_key, &.{"claude-sonnet-5"});
    try std.testing.expectEqualStrings(
        "claude-sonnet-5",
        app.accountModel(.anthropic_api_key).?.name(),
    );
}

test "a remembered account does not resume when no account is authenticated" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "openai-api-key",
        \\    "models": { "openai-api-key": "gpt-5.6-luna" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    try std.testing.expect(app.state.start.account != null);
    try std.testing.expect(app.startAccount() == null);
}

test "the logout of the last account signs out and opens the login picker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try std.testing.expect(app.accounts.isAuthenticated(.anthropic_plan));
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.applyOutcome(.{ .logout = .anthropic_plan });

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expect(app.agent.client == null);
    try std.testing.expect(app.session.account_shown == null);

    try std.testing.expectEqualStrings(
        "Drinky signed out of anthropic-plan. Select an account to sign in.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );
    try std.testing.expect(app.session.mode == .picking);
    const picker = app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Sign in", picker.title);
    try std.testing.expectEqual(std.enums.values(ai.llm.Account).len, picker.options.len);
    try std.testing.expectEqualStrings("anthropic-plan", picker.options[0].name);
}

test "the logout of the active account adopts a next account with no model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "key" });
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.applyOutcome(.{ .logout = .anthropic_plan });

    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, app.session.account_shown.?);
    try std.testing.expect(app.agent.model == null);
    try std.testing.expectEqualStrings(
        "Drinky signed out of anthropic-plan. Drinky now uses anthropic-api-key. " ++
            "Fetch the model list of anthropic-api-key with /model.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );
}

test "the logout of the active account names the pick where the next list stands" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "key" });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_api_key, &.{"claude-sonnet-5"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.applyOutcome(.{ .logout = .anthropic_plan });

    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, app.session.account_shown.?);
    try std.testing.expect(app.agent.model == null);
    try std.testing.expectEqualStrings(
        "Drinky signed out of anthropic-plan. Drinky now uses anthropic-api-key. " ++
            "Select a model of anthropic-api-key with /model.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );
}

test "a principal replacement drops old evidence before the restored turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "replacement", "refresh": "replacement",
        \\      "expires_ms": 4102444800000,
        \\      "account_uuid": "other", "organization_uuid": "other" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;
    app.session.beginTurn(1);

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_plan = .{
        .signature = .{ .text = "thought", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    app.agent.stats.quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };
    app.agent.stats.credits = .{ .total = 10, .used = 2 };

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = zero_receipt,
            .disposition = .credential_replaced,
        },
        .error_text = try gpa.dupe(u8, turnFailureText(error.CredentialReplaced).?),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    try std.testing.expect(app.agent.stats.quota == null);
    try std.testing.expect(app.agent.stats.credits == null);
    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, app.activeAccount().?);
    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, app.session.account_shown.?);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.agent.model == null);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "Try the turn again.",
    ) == null);
    try std.testing.expectEqualStrings(
        "Fetch the model list of anthropic-plan with /model.",
        blocks[1].content.event.text.items,
    );
}

test "a fetch that meets a replaced credential drops the evidence of the old principal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "replacement", "refresh": "replacement",
        \\      "expires_ms": 4102444800000,
        \\      "account_uuid": "other", "organization_uuid": "other" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_plan, &.{"claude-opus-5"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_plan = .{
        .signature = .{ .text = "thought", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "thought");

    try app.applyOutcome(.{ .credential_replaced = .anthropic_plan });

    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    try std.testing.expect(app.accounts.catalog.isEmpty(.anthropic_plan));
    try std.testing.expect(app.agent.model == null);
    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, app.activeAccount().?);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky found a replacement credential for anthropic-plan. " ++
            "Drinky removed the prior account evidence. " ++
            "Fetch the model list of anthropic-plan with /model.",
        blocks[0].content.event.text.items,
    );
    try std.testing.expect(!blocks[0].content.event.is_error);
}

test "a fetch that meets a replaced credential on an idle account names that account" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "sk-anthropic" });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_plan, &.{"gpt-5.6-sol"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_api_key;

    try app.applyOutcome(.{ .credential_replaced = .openai_plan });

    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, app.activeAccount().?);
    try app.expectModel(test_anthropic_model.name());
    try std.testing.expect(app.accounts.catalog.isEmpty(.openai_plan));

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky found a replacement credential for openai-plan. " ++
            "Drinky removed the prior account evidence. " ++
            "Fetch the model list of openai-plan with /model.",
        blocks[0].content.event.text.items,
    );
    try std.testing.expect(!blocks[0].content.event.is_error);
}

test "the login picker rereads the store and keeps the active Console key live" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-api": { "api_key": "minted-first" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_api, &.{"claude-opus-5"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_api;

    const borrowed = app.agent.client.?.credentials.anthropic_api;
    try app.applyOutcome(.login_picker);
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expectEqualStrings("Sign in", app.session.mode.picking.picker.title);
    try std.testing.expectEqualStrings(
        "anthropic-api",
        app.session.mode.picking.picker.options[1].name,
    );
    try std.testing.expectEqual(borrowed.ptr, app.agent.client.?.credentials.anthropic_api.ptr);
    try std.testing.expectEqual(
        borrowed.ptr,
        app.accounts.anthropic_console_auth.tokens.?.api_key.ptr,
    );
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    app.session.closePicker();

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-api": { "api_key": "minted-again" } }
        ,
    });
    try app.applyOutcome(.login_picker);
    try std.testing.expect(app.session.mode == .picking);
    const replaced = app.agent.client.?.credentials.anthropic_api;
    try std.testing.expectEqualStrings("minted-again", replaced);
    try std.testing.expectEqual(
        replaced.ptr,
        app.accounts.anthropic_console_auth.tokens.?.api_key.ptr,
    );
    try std.testing.expect(app.accounts.catalog.isEmpty(.anthropic_api));
    try std.testing.expect(app.agent.model == null);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky found a replacement credential for anthropic-api. " ++
            "Drinky removed the prior account evidence. " ++
            "Fetch the model list of anthropic-api with /model.",
        blocks[0].content.event.text.items,
    );
}

test "the login picker hands the session off an account another instance signed out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "key" });
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "thought");

    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "{}" });
    try app.applyOutcome(.login_picker);

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, app.activeAccount().?);
    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, app.session.account_shown.?);
    try std.testing.expect(app.agent.model == null);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Another Drinky instance signed out of anthropic-plan. " ++
            "Drinky now uses anthropic-api-key. " ++
            "Fetch the model list of anthropic-api-key with /model.",
        blocks[0].content.event.text.items,
    );
    try std.testing.expect(app.session.mode == .picking);
    const picker = app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("anthropic-plan", picker.options[0].name);
    try std.testing.expectEqualStrings("anthropic-api-key", picker.options[2].name);
}

test "the login picker signs out when another instance signed out the last account" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.openai_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .openai_plan;

    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "{}" });
    try app.applyOutcome(.login_picker);

    try std.testing.expect(app.agent.client == null);
    try std.testing.expect(app.session.account_shown == null);
    try std.testing.expectEqualStrings(
        "Another Drinky instance signed out of openai-plan. Select an account to sign in.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expectEqual(@as(usize, 0), app.session.mode.picking.trail.len);
    try std.testing.expectEqualStrings("openai-plan", app.session.mode.picking.picker.options[3].name);
}

test "the login picker shows a sign-in from another instance and keeps a rotated token" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000,
        \\      "account_uuid": "user", "organization_uuid": "org" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "thought");

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a2", "refresh": "r2", "expires_ms": 4102444800000,
        \\      "account_uuid": "user", "organization_uuid": "org" },
        \\  "xai-plan":
        \\    { "access": "x", "refresh": "xr", "expires_ms": 4102444800000 } }
        ,
    });
    try app.applyOutcome(.login_picker);

    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, app.activeAccount().?);
    try app.expectModel(test_anthropic_model.name());
    try std.testing.expectEqualStrings("r2", app.accounts.anthropic_auth.tokens.?.refresh);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    try std.testing.expect(app.session.transcript.blocks()[0].content == .thinking);
    const picker = app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("anthropic-plan", picker.options[0].name);
    try std.testing.expectEqualStrings("xai-plan", picker.options[5].name);
    try std.testing.expectEqualStrings("Signed in", picker.options[5].tag.?);
}

test "the login picker settles every other account before the active one leaves" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 },
        \\  "openai-plan":
        \\    { "access": "o", "refresh": "or", "expires_ms": 4102444800000,
        \\      "account_id": "first" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_plan, &.{"gpt-5.6-sol"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai-plan":
        \\    { "access": "o2", "refresh": "or2", "expires_ms": 4102444800000,
        \\      "account_id": "second" } }
        ,
    });
    try app.applyOutcome(.login_picker);

    try std.testing.expectEqual(ai.llm.Account.openai_plan, app.activeAccount().?);
    try std.testing.expect(app.accounts.catalog.isEmpty(.openai_plan));
    try std.testing.expect(app.agent.model == null);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky found a replacement credential for openai-plan. " ++
            "Drinky removed the prior account evidence. " ++
            "Fetch the model list of openai-plan with /model.",
        blocks[0].content.event.text.items,
    );
    try std.testing.expectEqualStrings(
        "Another Drinky instance signed out of anthropic-plan. " ++
            "Drinky now uses openai-plan. " ++
            "Fetch the model list of openai-plan with /model.",
        blocks[1].content.event.text.items,
    );
}

test "the login picker points the active client at a rotated credential" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai-plan":
        \\    { "access": "o", "refresh": "or", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.openai_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .openai_plan;

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai-plan":
        \\    { "access": "o2", "refresh": "or2", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
        ,
    });
    try app.applyOutcome(.login_picker);

    try std.testing.expectEqual(
        &app.accounts.openai_auth,
        app.agent.client.?.credentials.openai_plan,
    );
    try std.testing.expectEqualStrings("or2", app.accounts.openai_auth.tokens.?.refresh);
    try app.expectModel(test_anthropic_model.name());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "the login picker reports one entry it cannot read and settles the rest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan": { "access": 1 },
        \\  "xai-plan":
        \\    { "access": "x", "refresh": "xr", "expires_ms": 4102444800000 } }
        ,
    });
    try app.applyOutcome(.login_picker);

    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, app.activeAccount().?);
    try std.testing.expectEqualStrings("r", app.accounts.anthropic_auth.tokens.?.refresh);
    const picker = app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("anthropic-plan", picker.options[0].name);
    try std.testing.expectEqualStrings("xai-plan", picker.options[5].name);
    try std.testing.expectEqualStrings("Signed in", picker.options[5].tag.?);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    try std.testing.expect(std.mem.startsWith(
        u8,
        blocks[0].content.event.text.items,
        "Drinky could not read the credential of anthropic-plan in ",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        blocks[0].content.event.text.items,
        "because of error BadCredentials. The account stays as it was.",
    ));
}

test "the login picker opens over an unreadable credential file and reports it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;

    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try app.applyOutcome(.login_picker);

    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, app.activeAccount().?);
    try std.testing.expect(app.accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expectEqualStrings(
        "anthropic-plan",
        app.session.mode.picking.picker.options[0].name,
    );
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    try std.testing.expect(std.mem.startsWith(
        u8,
        blocks[0].content.event.text.items,
        "Drinky could not read the credential file ",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        blocks[0].content.event.text.items,
        "because of error BadCredentials. " ++
            "The account list shows the credentials from the last read.",
    ));
}

test "token request failures keep the credential before a grant rejection removes it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;

    for ([_]anyerror{
        error.TokenRequestFailed,
        error.TokenServiceUnavailable,
    }, 1..) |failure, generation| {
        app.session.beginTurn(@intCast(generation));
        var result: WorkerResult = .{
            .outcome = .{
                .receipt = zero_receipt,
                .disposition = .{ .failed = failure },
            },
            .error_text = try gpa.dupe(u8, turnFailureText(failure).?),
        };
        defer app.freeWorkerResult(&result);
        try app.finishWorkerResult(&result);

        try std.testing.expect(app.accounts.isAuthenticated(.anthropic_plan));
        try std.testing.expectEqual(
            ai.llm.Account.anthropic_plan,
            app.activeAccount().?,
        );
        try std.testing.expectEqual(
            ai.llm.Account.anthropic_plan,
            app.session.account_shown.?,
        );
    }
    {
        var file = (try ai.json_store.open(gpa, io, app.accounts.anthropic_auth.path)).?;
        defer file.deinit();
        try std.testing.expect(file.entry("anthropic-plan") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), app.session.transcript.blocks().len);

    app.session.beginTurn(3);
    {
        var result: WorkerResult = .{
            .outcome = .{
                .receipt = zero_receipt,
                .disposition = .credential_rejected,
            },
            .error_text = try gpa.dupe(u8, turnFailureText(error.TokenGrantRejected).?),
        };
        defer app.freeWorkerResult(&result);
        try app.finishWorkerResult(&result);
    }

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expect(app.agent.client == null);
    try std.testing.expect(app.session.account_shown == null);
    var file = (try ai.json_store.open(gpa, io, app.accounts.anthropic_auth.path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("anthropic-plan") == null);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expect(blocks[2].content.event.is_error);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[2].content.event.text.items,
        "provider rejected",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[2].content.event.text.items,
        "/login",
    ) == null);
    try std.testing.expectEqualStrings(
        "Drinky signed out of anthropic-plan. Select an account to sign in.",
        blocks[3].content.event.text.items,
    );
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expectEqualStrings(
        "anthropic-plan",
        app.session.mode.picking.picker.options[0].name,
    );
}

test "a replacement saved before invalidation keeps the account active" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "old_access", "refresh": "old_refresh",
        \\      "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_plan, &.{"claude-opus-5"});
    var discovered = test_anthropic_model;
    discovered.context_window = 1;
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = discovered,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "thought");
    app.session.beginTurn(1);

    try ai.json_store.save(gpa, io, app.accounts.anthropic_auth.path, "anthropic-plan", .{
        .access = "new_access",
        .refresh = "new_refresh",
        .expires_ms = 4102444800000,
    }, .{});

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_plan = .{
        .signature = .{ .text = "thought", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = zero_receipt,
            .disposition = .credential_rejected,
        },
        .error_text = try gpa.dupe(u8, turnFailureText(error.TokenGrantRejected).?),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try std.testing.expect(app.accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expectEqual(
        ai.llm.Account.anthropic_plan,
        app.activeAccount().?,
    );
    try std.testing.expectEqualStrings(
        "new_refresh",
        app.accounts.anthropic_auth.tokens.?.refresh,
    );
    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    try std.testing.expect(app.agent.model == null);
    try std.testing.expect(app.session.model_shown == null);
    try std.testing.expect(app.session.mode == .prompt);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "signed out",
    ) == null);
    try std.testing.expectEqualStrings(
        "Drinky reloaded the refresh credential that another Drinky instance saved. " ++
            "Fetch the model list of anthropic-plan with /model.",
        blocks[1].content.event.text.items,
    );
}

test "a rejected refresh credential hands the session to another account" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .openai = "sk-openai" });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    try app.state.record(.openai_api_key, test_openai_model, .low);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;
    app.session.beginTurn(1);

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = zero_receipt,
            .disposition = .credential_rejected,
        },
        .error_text = try gpa.dupe(u8, turnFailureText(error.TokenGrantRejected).?),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expectEqual(ai.llm.Account.openai_api_key, app.activeAccount().?);
    try std.testing.expectEqual(ai.llm.Account.openai_api_key, app.session.account_shown.?);
    try app.expectModel(test_openai_model.name());
    try std.testing.expect(app.session.mode == .prompt);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "/login",
    ) == null);
    try std.testing.expectEqualStrings(
        "Drinky signed out of anthropic-plan. " ++
            "Drinky now uses openai-api-key/gpt-5.6-sol.",
        blocks[1].content.event.text.items,
    );
}

test "a rejected refresh credential names the account with no model it hands the session to" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .openai = "sk-openai" });
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_plan;
    app.session.beginTurn(1);

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = zero_receipt,
            .disposition = .credential_rejected,
        },
        .error_text = try gpa.dupe(u8, turnFailureText(error.TokenGrantRejected).?),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expectEqual(ai.llm.Account.openai_api_key, app.activeAccount().?);
    try std.testing.expect(app.agent.model == null);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqualStrings(
        "Drinky signed out of anthropic-plan. Drinky now uses openai-api-key. " ++
            "Fetch the model list of openai-api-key with /model.",
        blocks[blocks.len - 1].content.event.text.items,
    );
}

test "an invoked skill sends a head that no box holds, and its task in a box" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.working_directory = "/work";
    app.home_directory = "/home/you";

    const prompt: ai.command.Outcome.Prompt = .{
        .name = "zig-style",
        .arguments = "review this file",
        .content = "complete hidden skill instructions",
        .source = "/work/.agents/skills/zig-style/SKILL.md",
    };
    try std.testing.expectEqual(@as(usize, 0), try app.appendSkillPrompt(&prompt));

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    switch (blocks[0].content) {
        .user_note => |head| try std.testing.expectEqualStrings(
            "Skill: zig-style · File: .agents/skills/zig-style/SKILL.md",
            head.items,
        ),
        else => return error.ExpectedSkill,
    }
    switch (blocks[1].content) {
        .user => |message| try std.testing.expectEqualStrings("review this file", message.items),
        else => return error.ExpectedUser,
    }

    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "Skill: zig-style · File: .agents/skills/zig-style/SKILL.md",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "review this file") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), prompt.content) == null);
}

test "an invoked skill with no task sends its head alone" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.working_directory = "/work";
    app.home_directory = "/home/you";

    const prompt: ai.command.Outcome.Prompt = .{
        .name = "interview",
        .arguments = "",
        .content = "complete hidden skill instructions",
        .source = "/home/you/.agents/skills/interview/SKILL.md",
    };
    try std.testing.expectEqual(@as(usize, 0), try app.appendSkillPrompt(&prompt));

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0].content) {
        .user_note => |head| try std.testing.expectEqualStrings(
            "Skill: interview · File: ~/.agents/skills/interview/SKILL.md",
            head.items,
        ),
        else => return error.ExpectedSkill,
    }
    try std.testing.expectEqual(@as(usize, 1), blocks[0].rows(80));
}

test displayRoots {
    const gpa = std.testing.allocator;
    var app: App = undefined;
    app.initForTest(gpa);
    app.working_directory = "/work";
    app.home_directory = "/home/you";

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "/work/.agents/skills/demo/SKILL.md", ".agents/skills/demo/SKILL.md" },
        .{ "/home/you/.agents/skills/demo/SKILL.md", "~/.agents/skills/demo/SKILL.md" },
        .{ "/opt/skills/demo/SKILL.md", "/opt/skills/demo/SKILL.md" },
    };
    for (cases) |case| {
        const path, const shown = case;
        const display = try ai.format.path(gpa, path, &app.displayRoots());
        defer gpa.free(display);
        try std.testing.expectEqualStrings(shown, display);
    }

    app.working_directory = "";
    app.home_directory = "";
    const bare = try ai.format.path(gpa, "/work/.agents/skills/demo/SKILL.md", &app.displayRoots());
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("/work/.agents/skills/demo/SKILL.md", bare);
}

test "a committed failure arms a retry that Esc dismisses" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();
    app.session.beginTurn(1);

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = .{
                .history_base = 0,
                .history_end = 2,
                .steering_committed_count = 0,
            },
            .disposition = .{ .failed = error.ApiError },
        },
        .error_text = try gpa.dupe(u8, "The provider is overloaded."),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("The provider is overloaded.", app.retry.?.failure);
    try std.testing.expectEqual(Session.PromptOffer.retry, app.session.prompt_offer);

    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Failed turn") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "Ctrl+N: Try again · Esc: Dismiss",
    ) != null);

    try app.session.editor.insert("keep this text");
    try app.handleKey(&.escape);
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqualStrings("keep this text", app.session.editor.visible());

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
}

test "Esc at the prompt dismisses a notice and a recovery offer together" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();
    app.session.beginTurn(1);

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = .{
                .history_base = 0,
                .history_end = 2,
                .steering_committed_count = 0,
            },
            .disposition = .{ .failed = error.ApiError },
        },
        .error_text = try gpa.dupe(u8, "The provider is overloaded."),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try app.session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .information, "temporary", .{}),
    );
    try app.handleKey(&.escape);
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expect(app.session.notice == null);
}

test "an uncommitted human failure returns to the editor and arms no retry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    try app.session.transcript.append(.user, .{}, "write the docs");
    app.session.beginTurn(1);
    try app.session.editor.insert("write the docs");
    var prompt = app.session.editor.detachTrimmed();
    app.session.retainTurnPrompt(&prompt, 0);

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = zero_receipt,
            .disposition = .{ .failed = error.ApiError },
        },
        .error_text = try gpa.dupe(u8, "The provider is overloaded."),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try std.testing.expectEqualStrings("write the docs", app.session.editor.visible());
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
}

test "an uncommitted skill failure returns its line and arms no retry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    try app.session.editor.insert("/skill:demo apply it");
    const prompt: ai.command.Outcome.Prompt = .{
        .name = "demo",
        .arguments = "apply it",
        .content = "SKILL BODY\napply it",
        .source = "/work/.agents/skills/demo/SKILL.md",
    };
    const base = try app.startSkillTurn(&prompt);
    var draft = app.session.editor.detachTrimmed();
    app.session.retainTurnPrompt(&draft, base);
    try seedSteering(&app, "and keep the format");

    {
        const result = app.awaitTurnFuture().?;
        defer app.freeWorkerResult(&result);
        try app.finishWorkerResult(&result);
    }
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqualStrings(
        "/skill:demo apply it\n\nand keep the format",
        app.session.editor.visible(),
    );
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    try std.testing.expectEqualStrings(
        "skill:demo",
        ai.command.parse(app.session.editor.visible()).?,
    );
}

test "Ctrl+N sends the attempt and keeps the editor text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    try app.session.editor.insert("a draft that stays");

    try app.sendRetryTurn();

    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqualStrings("a draft that stays", app.session.editor.visible());
    try std.testing.expect(app.session.turn_prompt == null);
    {
        const blocks = app.session.transcript.blocks();
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        try std.testing.expectEqualStrings(Retry.note_text, blocks[0].content.user_note.items);
    }

    {
        const result = app.awaitTurnFuture().?;
        defer app.freeWorkerResult(&result);
        try app.finishWorkerResult(&result);
    }
    try std.testing.expectEqual(Session.PromptOffer.retry, app.session.prompt_offer);
    try std.testing.expect(std.mem.indexOf(u8, app.retry.?.failure, "SignedOut") != null);
    try std.testing.expectEqualStrings("a draft that stays", app.session.editor.visible());
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
}

test "a shorten request records its line and keeps the editor text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    try app.session.editor.insert("a draft that stays");
    try app.sendShortenTurn();

    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqualStrings("a draft that stays", app.session.editor.visible());
    try std.testing.expect(app.session.turn_prompt == null);
    {
        const blocks = app.session.transcript.blocks();
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        try std.testing.expectEqualStrings(shorten_note_text, blocks[0].content.user_note.items);
    }
    {
        const result = app.awaitTurnFuture().?;
        defer app.freeWorkerResult(&result);
        try app.finishWorkerResult(&result);
    }
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("a draft that stays", app.session.editor.visible());
}

test "a signed-out Ctrl+N names the sign-in and keeps the retry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(app.turn_future == null);

    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.retry != null);
    try std.testing.expectEqual(Session.PromptOffer.retry, app.session.prompt_offer);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expectEqualStrings(
        "Sign in with /login before you try the turn again.",
        app.session.notice.?.content,
    );
}

test "Ctrl+N refuses while the account offers no model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = ai.testing.accounts(.{ .anthropic = "sk-ant" });
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    try app.handleKey(&.{ .ctrl = 'n' });

    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(app.retry != null);
    try std.testing.expectEqual(Session.PromptOffer.retry, app.session.prompt_offer);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings(no_model_refusal, app.session.notice.?.content);
}

test "a turn without a model reports a sentence and not the error name" {
    try std.testing.expectEqualStrings(no_model_refusal, turnFailureText(error.NoModel).?);
}

test "Enter sends a plain message and drops the waiting retry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    app.retry = .{ .failure = try gpa.dupe(u8, "The provider did not respond in time.") };
    app.session.prompt_offer = .retry;

    try app.session.editor.insert("also check the tests");
    {
        const base = try app.startUserTurn("also check the tests");
        var prompt = app.session.editor.detachTrimmed();
        app.session.retainTurnPrompt(&prompt, base);
    }

    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    {
        const blocks = app.session.transcript.blocks();
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        try std.testing.expectEqualStrings("also check the tests", blocks[0].content.user.items);
    }

    {
        const result = app.awaitTurnFuture().?;
        defer app.freeWorkerResult(&result);
        try app.finishWorkerResult(&result);
    }
    try std.testing.expectEqualStrings("also check the tests", app.session.editor.visible());
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
}

test "the Herdr state follows the turn and the waiting retry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    try std.testing.expectEqual(Herdr.State.idle, app.herdrState());
    try app.session.openPage(&.{ .title = "Test page", .content = "body" });
    try std.testing.expectEqual(Herdr.State.idle, app.herdrState());
    app.session.closePage();

    app.session.beginTurn(1);
    try std.testing.expectEqual(Herdr.State.working, app.herdrState());
    app.session.endTurn();

    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    try std.testing.expectEqual(Herdr.State.blocked, app.herdrState());
    app.session.beginTurn(2);
    app.dismissOffer();
    try std.testing.expectEqual(Herdr.State.working, app.herdrState());
    app.session.endTurn();
    try std.testing.expectEqual(Herdr.State.idle, app.herdrState());

    app.setRevision(.{
        .history = .{ .base = 0, .end = 0 },
        .transcript_base = 0,
        .transcript_end = 0,
        .prompt = .empty,
        .steering = .empty,
        .mutated = false,
    });
    try std.testing.expectEqual(Herdr.State.blocked, app.herdrState());
    app.session.beginTurn(3);
    app.dismissOffer();
    try std.testing.expectEqual(Herdr.State.working, app.herdrState());
    app.session.endTurn();
    try std.testing.expectEqual(Herdr.State.idle, app.herdrState());

    app.herdr.sync(app.herdrState());
    try std.testing.expect(app.herdr.future == null);
}

test "canceling an attempt ends the recovery" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();

    app.session.beginTurn(1);
    app.turn_retry = true;
    try spawnCommittedCanceledTurn(&app);
    try app.cancelTurn();

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.retry == null);
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expect(!app.turn_retry);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "You canceled the turn.",
        blocks[0].content.event.text.items,
    );

    try app.session.transcript.append(.user_note, .{}, shorten_note_text);
    app.session.beginTurn(2);
    app.session.markTurnBase(1);
    try spawnCommittedCanceledTurn(&app);
    try app.cancelTurn();
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expect(app.session.mode == .prompt);
}

const StagedTurn = struct {
    prompt: *ui.Editor.Draft,
    source: Session.Message.Source = .terminal,
    tool: ?[]const u8 = null,
};

fn stageCommittedPromptTurn(app: *App, result: *WorkerResult, staged: StagedTurn) !void {
    const gpa = app.gpa;
    const history_base = app.agent.items.items.len;
    const base = app.session.transcript.blocks().len;
    const text = try staged.prompt.expanded(gpa, .whole_prompt);
    defer gpa.free(text);
    try app.session.transcript.append(.user, .{}, text);
    try app.agent.items.append(gpa, .{ .message = .{
        .role = .user,
        .text = try gpa.dupe(u8, text),
    } });
    try app.agent.items.append(gpa, .{ .message = .{
        .role = .assistant,
        .text = try gpa.dupe(u8, "the answer"),
    } });
    app.session.beginTurn(1);
    switch (staged.source) {
        .terminal => app.session.retainTurnPrompt(staged.prompt, base),
        .external => |id| app.session.retainExternalTurnPrompt(staged.prompt, base, id),
    }

    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "the answer") },
    });
    var sequence: u64 = 1;
    if (staged.tool) |tool| {
        _ = try app.session.applyTurnEvent(&.{
            .generation = 1,
            .progress_sequence = 2,
            .progress_sequence_committed = 1,
            .payload = .{ .tool_start = .{
                .name = try gpa.dupe(u8, tool),
                .input_json = try gpa.dupe(u8, "{}"),
            } },
        });
        _ = try app.session.applyTurnEvent(&.{
            .generation = 1,
            .progress_sequence = 3,
            .progress_sequence_committed = 1,
            .payload = .{ .tool_result = .{
                .name = try gpa.dupe(u8, tool),
                .summary = .{ .text = try gpa.dupe(u8, "Lines: 1") },
                .is_error = false,
            } },
        });
        sequence = 3;
    }
    result.* = .{
        .outcome = .{ .receipt = .{
            .history_base = history_base,
            .history_end = app.agent.items.items.len,
            .steering_committed_count = 0,
        }, .disposition = .canceled },
        .error_text = null,
        .generation = 1,
        .progress_sequence = sequence,
        .progress_sequence_committed = sequence,
    };
}

fn spawnStagedTurn(app: *App, result: *const WorkerResult) !void {
    app.turn_future = try app.io.concurrent(fakeWorker, .{result});
}

fn beginCommittedPromptTurn(
    app: *App,
    result: *WorkerResult,
    prompt: []const u8,
    maybe_tool: ?[]const u8,
) !void {
    var draft = try ui.Editor.Draft.fromText(app.gpa, prompt);
    errdefer draft.deinit(app.gpa);
    try stageCommittedPromptTurn(app, result, .{ .prompt = &draft, .tool = maybe_tool });
    try spawnStagedTurn(app, result);
}

fn expectCanceledTurnStands(app: *const App, history_base: usize, transcript_base: usize) !void {
    try std.testing.expectEqual(history_base + 2, app.agent.items.items.len);
    const blocks = app.session.transcript.blocks();
    try std.testing.expect(blocks.len > transcript_base);
    try std.testing.expect(blocks[transcript_base].content == .user);
    const last = blocks[blocks.len - 1];
    try std.testing.expectEqualStrings("You canceled the turn.", last.content.event.text.items);
}

test "a committed cancellation offers the revision of the turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();
    try app.session.transcript.append(.intro, .{}, intro_text);

    for ([_]terminal.Input.Key{ .escape, .{ .ctrl = 'c' }, .{ .ctrl = 'd' } }) |key| {
        app.agent.resetConversation();
        app.session.transcript.truncate(1);
        var result: WorkerResult = undefined;
        try beginCommittedPromptTurn(&app, &result, "fix it", "read");
        try app.handleKey(&key);

        try std.testing.expect(app.session.mode == .prompt);
        try std.testing.expect(app.turn_future == null);
        try std.testing.expectEqualStrings("", app.session.editor.visible());
        try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
        try std.testing.expect(app.retry == null);
        try std.testing.expectEqual(Herdr.State.blocked, app.herdrState());
        try expectCanceledTurnStands(&app, 0, 1);
        try std.testing.expectEqual(@as(usize, 5), app.session.transcript.blocks().len);
        const revision = app.revision.?;
        try std.testing.expectEqual(@as(usize, 0), revision.history.base);
        try std.testing.expectEqual(@as(usize, 2), revision.history.end);
        try std.testing.expectEqual(@as(usize, 1), revision.transcript_base);
        try std.testing.expectEqual(@as(usize, 5), revision.transcript_end);
        try std.testing.expectEqualStrings("fix it", revision.prompt.visible.items);
        try std.testing.expectEqual(@as(usize, 0), revision.steering.items.len);
        try std.testing.expect(!revision.mutated);
        app.dismissOffer();
    }

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", "read");
    try app.cancelTurn();
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Canceled turn") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "Ctrl+N: Remove and edit · Esc: Keep turn",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Failed turn") == null);
}

test "an uncommitted cancellation restores the prompt and offers no revision" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    const payload = "line\n" ** 15;
    try app.session.transcript.append(.user, .{}, payload);
    app.session.beginTurn(1);
    try app.session.editor.paste(payload, true);
    var prompt = app.session.editor.detachTrimmed();
    app.session.retainTurnPrompt(&prompt, 0);
    try seedSteering(&app, "and test");
    try app.session.editor.insert("draft");
    try spawnCanceledTurn(&app);
    try app.cancelTurn();

    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload ++ "\n\nand test\n\ndraft", expanded);
    app.session.editor.clear();

    var result: WorkerResult = undefined;
    var draft = try ui.Editor.Draft.fromText(gpa, "fix it");
    try stageCommittedPromptTurn(&app, &result, .{ .prompt = &draft });
    result.outcome.disposition = .completed;
    result.terminal_queued = true;
    try spawnStagedTurn(&app, &result);
    try app.cancelTurn();
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.revision == null);
    try app.queue.putOne(io, .{ .turn = .{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .turn_ended,
    } });
    var batch: [queue_capacity]UiEvent = undefined;
    const count = try app.queue.get(io, &batch, 1);
    _ = try app.applyBatch(batch[0..count]);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
}

test "a cancellation offers a revision only while the terminal holds the input" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    var result: WorkerResult = undefined;
    var external = try ui.Editor.Draft.fromText(gpa, "from the chat");
    try stageCommittedPromptTurn(&app, &result, .{
        .prompt = &external,
        .source = .{ .external = 7 },
    });
    try spawnStagedTurn(&app, &result);
    app.session.input.owner = .external;
    try app.cancelTurn();
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try expectCanceledTurnStands(&app, 0, 0);

    app.agent.resetConversation();
    app.session.transcript.truncate(0);
    app.session.input.owner = .terminal;
    external = try ui.Editor.Draft.fromText(gpa, "from the chat");
    try stageCommittedPromptTurn(&app, &result, .{
        .prompt = &external,
        .source = .{ .external = 8 },
    });
    try spawnStagedTurn(&app, &result);
    try app.cancelTurn();
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    try std.testing.expectEqualStrings("from the chat", app.revision.?.prompt.visible.items);
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqualStrings("from the chat", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "Esc keeps the canceled turn while editing and a safe command keep the revision" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", "write");
    try app.cancelTurn();
    try std.testing.expect(app.revision.?.mutated);

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqualStrings(revision_warning, app.session.notice.?.content);
    try std.testing.expect(app.session.confirmations.contains(.revision));
    try expectCanceledTurnStands(&app, 0, 0);
    try app.handleKey(&.{ .char = 'x' });
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(!app.session.confirmations.contains(.revision));
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqualStrings(revision_warning, app.session.notice.?.content);
    try expectCanceledTurnStands(&app, 0, 0);

    app.session.editor.clear();
    try app.runCommand("/effort");
    try std.testing.expect(app.session.mode == .picking);
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    try app.runCommand("/effort");
    try app.handleKey(&.down);
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(ai.llm.Effort.medium, app.agent.effort);
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    try std.testing.expect(app.revision != null);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 5), blocks.len);
    try std.testing.expect(blocks[4].content == .event);
    try std.testing.expect(!blocks[4].content.event.turn_owned);

    try app.session.editor.insert("keep this text");
    try app.handleKey(&.escape);
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqual(Herdr.State.idle, app.herdrState());
    try std.testing.expectEqualStrings("keep this text", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 2), app.agent.items.items.len);
    try std.testing.expectEqual(@as(usize, 5), app.session.transcript.blocks().len);
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.session.notice == null);
    try std.testing.expectEqual(@as(usize, 5), app.session.transcript.blocks().len);
}

test "a dismissal of the revision takes its armed confirmation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", "write");
    try app.cancelTurn();
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.session.confirmations.contains(.revision));

    app.dismissOffer();
    try std.testing.expect(!app.session.confirmations.contains(.revision));
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
}

test "a prompt-history insertion appends after the draft and keeps the revision" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    defer app.controller.deinit();
    defer app.dropRevision();
    try app.prompt_history.record("older prompt");

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", null);
    try app.cancelTurn();
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);

    try app.session.editor.insert("typed");
    try app.handleKeys("\t");
    try std.testing.expect(app.session.mode == .picking);
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("typed\n\nolder prompt", app.session.editor.visible());
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    try std.testing.expect(app.revision != null);
}

test "a turn start and /new dismiss the revision and a failed start keeps it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", null);
    try app.cancelTurn();
    try std.testing.expect(app.revision != null);

    app.turn_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, app.startUserTurn("next"));
    try std.testing.expect(app.revision != null);
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    try std.testing.expectEqual(@as(usize, 3), app.session.transcript.blocks().len);
    app.turn_generation = 1;

    const base = try app.startUserTurn("next");
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqual(@as(usize, 3), base);
    try std.testing.expectEqual(@as(usize, 2), app.agent.items.items.len);
    {
        const finished = app.awaitTurnFuture().?;
        defer app.freeWorkerResult(&finished);
        try app.finishWorkerResult(&finished);
    }
    try std.testing.expect(app.session.mode == .prompt);

    try beginCommittedPromptTurn(&app, &result, "fix it", null);
    try app.cancelTurn();
    try std.testing.expect(app.revision != null);
    try app.applyOutcome(.new_conversation);
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
}

test "account evidence removal rebases the revision anchors and keeps the offer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
        .effort = .high,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .high);
    defer app.session.deinit();
    defer app.dropRevision();
    app.session.showSetup(.anthropic_plan, test_anthropic_model, .high);

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_plan = .{
        .signature = .{ .text = "earlier", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "earlier");
    try app.session.transcript.appendStream(.model, null, "earlier answer");
    var result: WorkerResult = undefined;
    var draft = try ui.Editor.Draft.fromText(gpa, "fix it");
    try stageCommittedPromptTurn(&app, &result, .{ .prompt = &draft });
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    result.outcome.receipt.history_end += 1;
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .thinking = try gpa.dupe(u8, "weigh it") },
    });
    result.progress_sequence = 2;
    result.progress_sequence_committed = 2;
    try spawnStagedTurn(&app, &result);
    try app.cancelTurn();
    {
        const revision = app.revision.?;
        try std.testing.expectEqual(@as(usize, 1), revision.history.base);
        try std.testing.expectEqual(@as(usize, 4), revision.history.end);
        try std.testing.expectEqual(@as(usize, 2), revision.transcript_base);
        try std.testing.expectEqual(@as(usize, 6), revision.transcript_end);
    }

    app.dropAccountEvidence(.anthropic_plan);
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    {
        const revision = app.revision.?;
        try std.testing.expectEqual(@as(usize, 0), revision.history.base);
        try std.testing.expectEqual(@as(usize, 2), revision.history.end);
        try std.testing.expectEqual(@as(usize, 1), revision.transcript_base);
        try std.testing.expectEqual(@as(usize, 4), revision.transcript_end);
    }

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("earlier answer", blocks[0].content.model.items);
    try std.testing.expectEqualStrings("fix it", app.session.editor.visible());
}

test "a credential replacement rebases both canonical ranges of the revision" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "replacement", "refresh": "replacement",
        \\      "expires_ms": 4102444800000,
        \\      "account_uuid": "other", "organization_uuid": "other" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_plan, &.{"claude-opus-5"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
        .effort = .high,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .high);
    defer app.session.deinit();
    defer app.dropRevision();
    app.session.showSetup(.anthropic_plan, test_anthropic_model, .high);

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_plan = .{
        .signature = .{ .text = "earlier", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    try app.session.transcript.appendStream(.thinking, .anthropic_plan, "earlier");
    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", null);
    try app.cancelTurn();

    try app.applyOutcome(.{ .credential_replaced = .anthropic_plan });
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    const revision = app.revision.?;
    try std.testing.expectEqual(@as(usize, 0), revision.history.base);
    try std.testing.expectEqual(@as(usize, 2), revision.history.end);
    try std.testing.expectEqual(@as(usize, 0), revision.transcript_base);
    try std.testing.expectEqual(@as(usize, 3), revision.transcript_end);
    try std.testing.expectEqual(@as(usize, 4), app.session.transcript.blocks().len);

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "replacement credential",
    ) != null);
}

test "Ctrl+N after read-only calls removes the canceled turn on the first press" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();
    try app.session.transcript.append(.intro, .{}, intro_text);
    try app.session.transcript.append(.user, .{}, "earlier");
    try app.agent.items.append(gpa, .{ .message = .{
        .role = .user,
        .text = try gpa.dupe(u8, "earlier"),
    } });

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", "read");
    app.agent.measured_context = .{
        .tokens = 1200,
        .model = test_anthropic_model,
        .account = .anthropic_plan,
        .reasoning = test_anthropic_model.reasoning(.low),
    };
    app.agent.stats.context_tokens = 1200;
    app.agent.stats.cost = 0.75;
    try app.session.editor.insert("draft");
    try app.cancelTurn();
    try std.testing.expectEqual(@as(?u64, 1200), app.session.stats_shown.context_tokens);
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    app.mirror.cursor = app.session.transcript.blocks().len;
    app.mirror.answer_serial = 5;

    const removed_start = out.written().len;
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expect(app.session.notice == null);
    try std.testing.expectEqual(Herdr.State.idle, app.herdrState());
    try std.testing.expectEqualStrings("fix it\n\ndraft", app.session.editor.visible());
    try std.testing.expectEqual(app.session.editor.visible().len, app.session.editor.caret);

    try std.testing.expectEqual(@as(usize, 1), app.agent.items.items.len);
    try std.testing.expectEqualStrings("earlier", app.agent.items.items[0].message.text);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[0].content == .intro);
    try std.testing.expectEqualStrings("earlier", blocks[1].content.user.items);

    try std.testing.expect(app.agent.measured_context == null);
    try std.testing.expect(app.agent.stats.context_tokens == null);
    try std.testing.expect(app.session.stats_shown.context_tokens == null);
    try std.testing.expectEqual(@as(f64, 0.75), app.agent.stats.cost);
    try std.testing.expectEqual(@as(f64, 0.75), app.session.stats_shown.cost);

    try std.testing.expectEqual(@as(usize, 2), app.mirror.cursor);
    try std.testing.expect(app.mirror.namesAnswer(5));

    try std.testing.expect(app.session.view.force_reset);
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    const painted = try terminal.View.plainText(gpa, out.written()[removed_start..]);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, out.written()[removed_start..], terminal.escape.screen_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "the answer") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "You canceled the turn.") == null);

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqualStrings("fix it\n\ndraft", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 2), app.session.transcript.blocks().len);
    try std.testing.expect(app.turn_future == null);
}

test "Ctrl+N after a mutating call warns first and removes on the second press" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    for ([_][]const u8{ "write", "edit", "bash" }) |tool| {
        var result: WorkerResult = undefined;
        try beginCommittedPromptTurn(&app, &result, "fix it", tool);
        try app.cancelTurn();
        try std.testing.expect(app.revision.?.mutated);

        try app.handleKey(&.{ .ctrl = 'n' });
        try std.testing.expectEqualStrings(revision_warning, app.session.notice.?.content);
        try std.testing.expectEqual(ai.command.Outcome.Severity.warning, app.session.notice.?.severity);
        try expectCanceledTurnStands(&app, 0, 0);
        try std.testing.expectEqual(@as(usize, 4), app.session.transcript.blocks().len);
        try std.testing.expectEqualStrings("", app.session.editor.visible());
        try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);

        try app.handleKey(&.{ .ctrl = 'n' });
        try std.testing.expect(app.revision == null);
        try std.testing.expect(app.session.notice == null);
        try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
        try std.testing.expectEqualStrings("fix it", app.session.editor.visible());
        app.session.editor.clear();
    }

    var result: WorkerResult = undefined;
    var draft = try ui.Editor.Draft.fromText(gpa, "fix it");
    try stageCommittedPromptTurn(&app, &result, .{ .prompt = &draft });
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "bash"),
            .input_json = try gpa.dupe(u8, "{\"command\":\"ls\"}"),
        } },
    });
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_result = .{
            .name = try gpa.dupe(u8, "bash"),
            .summary = .{ .text = try gpa.dupe(u8, "Time: 0ms · Exit code: 1") },
            .is_error = true,
        } },
    });
    result.progress_sequence = 3;
    result.progress_sequence_committed = 3;
    try spawnStagedTurn(&app, &result);
    try app.cancelTurn();
    try std.testing.expect(app.revision.?.mutated);
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqualStrings(revision_warning, app.session.notice.?.content);
    try std.testing.expectEqual(@as(usize, 4), app.session.transcript.blocks().len);
}

test "Ctrl+N removes the retry event of the turn and keeps the events of the session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();
    try app.session.transcript.append(.event, .{}, "before the turn");

    var result: WorkerResult = undefined;
    var draft = try ui.Editor.Draft.fromText(gpa, "fix it");
    try stageCommittedPromptTurn(&app, &result, .{ .prompt = &draft });
    try app.recordAsyncEvent(.information, .{}, "You attached @bot.", .{});
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .stream_reset = .{ .attempt = 2, .cause = .{ .failure = error.Timeout } } },
    });
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .text = try gpa.dupe(u8, "partial") },
    });
    result.progress_sequence = 3;
    result.progress_sequence_committed = 1;
    try spawnStagedTurn(&app, &result);
    try app.cancelTurn();

    const kept = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 6), kept.len);
    try std.testing.expect(std.mem.indexOf(u8, kept[4].content.event.text.items, "retry attempt 2") != null);
    try std.testing.expectEqualStrings("You canceled the turn.", kept[5].content.event.text.items);
    try app.applyOutcome(try ai.command.Outcome.reportEvent(gpa, .information, "changed", .{}));
    try std.testing.expectEqual(@as(usize, 7), app.session.transcript.blocks().len);
    app.mirror.cursor = 5;

    try app.handleKey(&.{ .ctrl = 'n' });
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("before the turn", blocks[0].content.event.text.items);
    try std.testing.expectEqualStrings("You attached @bot.", blocks[1].content.event.text.items);
    try std.testing.expectEqualStrings("changed", blocks[2].content.event.text.items);
    try std.testing.expectEqual(@as(usize, 2), app.mirror.cursor);
}

test "a revision restores the prompt and the committed steering above the editor text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    const payload = "line\n" ** 15;
    var result: WorkerResult = undefined;
    try app.session.editor.paste(payload, true);
    var prompt = app.session.editor.detachTrimmed();
    try stageCommittedPromptTurn(&app, &result, .{ .prompt = &prompt });
    try seedSteering(&app, "and test");
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, "and test"),
            .count = 1,
        } },
    });
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 2,
        .payload = .{ .text = try gpa.dupe(u8, "second answer") },
    });
    try app.session.editor.insert("later");
    try app.submitSteering();
    try app.session.editor.insert("draft");
    result.outcome.receipt.steering_committed_count = 1;
    result.progress_sequence = 3;
    result.progress_sequence_committed = 3;
    try spawnStagedTurn(&app, &result);
    try app.cancelTurn();

    try std.testing.expectEqualStrings("later\n\ndraft", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 1), app.revision.?.steering.items.len);
    try std.testing.expectEqualStrings("and test", app.revision.?.steering.items[0].visible.items);
    try std.testing.expectEqual(@as(usize, 1), app.revision.?.prompt.atoms.items.len);

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(u64, 1), app.session.editor.draft.atoms.items[0].id);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload ++ "\n\nand test\n\nlater\n\ndraft", expanded);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
}

test "a revision keeps the prompt-history entry and a revised Enter records a new one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    try app.initHistoryTest(gpa, io, &out, home, true);
    defer app.deinitHistoryTest();
    defer app.controller.deinit();
    defer app.dropRevision();
    try app.prompt_history.record("fix it");

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", null);
    try app.cancelTurn();
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqualStrings("fix it", app.session.editor.visible());
    try app.expectHistory(&.{"fix it"});

    try app.handleKeys(" now");
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.mode == .turn);
    try app.expectHistory(&.{ "fix it now", "fix it" });
    try app.finishHistoryTurn();
}

test "a failed revision changes nothing and keeps the offer" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", null);
    try app.cancelTurn();

    app.session.editor.deinit();
    app.session.editor = ui.Editor.init(gpa);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, app.handleKey(&.{ .ctrl = 'n' }));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expect(app.revision != null);
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    try std.testing.expectEqualStrings("fix it", app.revision.?.prompt.visible.items);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try expectCanceledTurnStands(&app, 0, 0);

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqualStrings("fix it", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "the revision survives an allocation failure around the cancellation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();

    var result: WorkerResult = undefined;
    var draft = try ui.Editor.Draft.fromText(gpa, "fix it");
    try stageCommittedPromptTurn(&app, &result, .{ .prompt = &draft });
    try seedSteering(&app, "and test");
    _ = try app.session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .steering_consumed = .{
            .text = try gpa.dupe(u8, "and test"),
            .count = 1,
        } },
    });
    result.outcome.receipt.steering_committed_count = 1;
    result.progress_sequence = 2;
    result.progress_sequence_committed = 2;
    try spawnStagedTurn(&app, &result);

    try app.session.reserveSteeringRestore();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, app.cancelTurn());
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.turn_future != null);
    try std.testing.expect(app.revision == null);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqualStrings("and test", app.session.steering.items[0].draft.visible.items);
    try std.testing.expectEqualStrings("fix it", app.session.turn_prompt.?.draft.visible.items);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try app.session.reserveRevisionCapture();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, app.cancelTurn());
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);
    const revision = app.revision.?;
    try std.testing.expectEqualStrings("fix it", revision.prompt.visible.items);
    try std.testing.expectEqual(@as(usize, 1), revision.steering.items.len);
    try std.testing.expectEqualStrings("and test", revision.steering.items[0].visible.items);
    try std.testing.expectEqual(@as(usize, 3), app.session.transcript.blocks().len);
    try std.testing.expectEqual(@as(usize, 3), revision.transcript_end);

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expectEqualStrings("fix it\n\nand test", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
}

test "a revision makes the skill guard search the shortened history again" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRevision();
    try app.skill_guard.add(.{ .glob = "**/*.zig", .skill = "zig-style", .source = "/skills/SKILL.md" });
    app.agent.skill_guard = &app.skill_guard;

    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", null);
    try app.cancelTurn();
    app.skill_guard.rule_items[0].loaded.store(true, .monotonic);

    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(!app.skill_guard.rules()[0].loaded.load(.monotonic));
}

test "a retry and a revision replace each other and Ctrl+N acts on the one that waits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();
    defer app.dropRevision();

    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    var result: WorkerResult = undefined;
    try beginCommittedPromptTurn(&app, &result, "fix it", null);
    try std.testing.expect(app.retry != null);
    try app.cancelTurn();
    try std.testing.expect(app.retry == null);
    try std.testing.expect(app.revision != null);
    try std.testing.expectEqual(Session.PromptOffer.revision, app.session.prompt_offer);

    app.session.beginTurn(2);
    var failed: WorkerResult = .{
        .outcome = .{
            .receipt = .{
                .history_base = 2,
                .history_end = 3,
                .steering_committed_count = 0,
            },
            .disposition = .{ .failed = error.ApiError },
        },
        .error_text = try gpa.dupe(u8, "The provider is overloaded."),
    };
    defer app.freeWorkerResult(&failed);
    try app.finishWorkerResult(&failed);
    try std.testing.expect(app.revision == null);
    try std.testing.expect(app.retry != null);
    try std.testing.expectEqual(Session.PromptOffer.retry, app.session.prompt_offer);
    try std.testing.expectEqual(Herdr.State.blocked, app.herdrState());

    try app.session.editor.insert("keep");
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings(
        "Sign in with /login before you try the turn again.",
        app.session.notice.?.content,
    );
    try std.testing.expect(app.retry != null);
    try std.testing.expectEqualStrings("keep", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 2), app.agent.items.items.len);
}

test "a retry survives an account switch and Ctrl+N routes to it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    try app.state.record(.openai_api_key, test_openai_model, .low);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_api_key;
    defer app.dropRetry();

    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    try app.applyOutcome(.{ .switch_account = .openai_api_key });
    try std.testing.expect(app.retry != null);
    try std.testing.expectEqual(Session.PromptOffer.retry, app.session.prompt_offer);
    try app.expectModel(test_openai_model.name());
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);

    app.turn_generation = std.math.maxInt(u64);
    try std.testing.expectError(
        error.GenerationExhausted,
        app.handleKey(&.{ .ctrl = 'n' }),
    );
    try std.testing.expect(app.retry != null);
    try std.testing.expectEqual(Session.PromptOffer.retry, app.session.prompt_offer);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);

    try app.applyOutcome(.new_conversation);
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    try std.testing.expect(app.session.transcript.blocks()[0].content == .intro);
}

test "a skill line runs while a retry waits and takes the context with it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var skill = try tmp.dir.createDirPathOpen(io, ".agents/skills/demo", .{});
    skill.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".agents/skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: a test skill\n---\nbody\n",
    });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);
    const user_skills = try std.fs.path.join(gpa, &.{ root, "home", ".agents", "skills" });
    defer gpa.free(user_skills);

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.dropRetry();
    app.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = root,
        .project_root = null,
    });
    defer app.skills.deinit();

    app.retry = .{ .failure = try gpa.dupe(u8, "The provider is overloaded.") };
    app.session.prompt_offer = .retry;

    try app.session.editor.insert("/skill:demo apply it");
    const prompt = (try app.dispatchCommand("/skill:demo apply it")).?.prompt;
    defer prompt.deinit(gpa);
    _ = try app.startSkillTurn(&prompt);

    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expect(app.turn_future != null);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(std.mem.startsWith(
        u8,
        blocks[0].content.user_note.items,
        "Skill: demo · File:",
    ));
    try std.testing.expectEqualStrings("apply it", blocks[1].content.user.items);

    const result = app.awaitTurnFuture().?;
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);
}

test "a signed-out submit is refused with a login prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.editor.insert("hello");
    try app.submit();

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "/login") != null);
}

test "a refused command line reaches the model on the next Enter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.editor.insert("/nope tell me about this");
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.confirmations.contains(.message));
    try std.testing.expectEqualStrings(
        "Enter: Send as a message · Drinky does not recognize the command /nope.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqualStrings("/nope tell me about this", app.session.editor.visible());

    try app.handleKey(&.{ .char = 'x' });
    try std.testing.expect(!app.session.confirmations.contains(.message));
    try app.handleKey(&.backspace);
    try std.testing.expect(!app.session.confirmations.contains(.message));

    try app.handleKey(&.enter);
    try std.testing.expect(app.session.confirmations.contains(.message));
    try app.handleKey(&.enter);

    try std.testing.expect(!app.session.confirmations.contains(.message));
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "/login") != null);
    try std.testing.expectEqualStrings("/nope tell me about this", app.session.editor.visible());
}

test "a refused command line queues as steering on the next Enter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("/model");
    try app.handleKey(&.enter);
    try std.testing.expect(!app.session.confirmations.contains(.message));
    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings("/model", app.session.editor.visible());

    app.session.editor.clear();
    try app.session.editor.insert("/nope steer with this");
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.confirmations.contains(.message));
    try std.testing.expectEqualStrings(
        "Enter: Queue as a message · Drinky does not recognize the command /nope.",
        app.session.notice.?.content,
    );

    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    const taken = try app.agent.steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings("/nope steer with this", taken[0]);
}

test "a turn that ends under the queue offer clears the row too" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("/nope tell me about this");
    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings(
        "Enter: Queue as a message · Drinky does not recognize the command /nope.",
        app.session.notice.?.content,
    );

    try app.session.endTurnWithReceipt(&.{
        .history_base = 0,
        .history_end = 0,
        .steering_committed_count = 0,
    });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(!app.session.confirmations.contains(.message));
    try std.testing.expect(app.session.notice == null);

    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings(
        "/nope tell me about this",
        app.session.editor.visible(),
    );
    try std.testing.expectEqualStrings(
        "Enter: Send as a message · Drinky does not recognize the command /nope.",
        app.session.notice.?.content,
    );
    try std.testing.expect(app.session.confirmations.contains(.message));
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "an idle submit of a slash line with a tail is refused and keeps its text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    try app.session.transcript.append(.user, .{}, "history marker");

    try app.session.editor.insert("/new must clear the terminal scrollback");
    try app.submit();

    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    try std.testing.expect(app.session.mode == .prompt);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.warning, notice.severity);
    try std.testing.expectEqualStrings(
        "Enter: Send as a message · The command /new takes no argument.",
        notice.content,
    );
    try std.testing.expectEqualStrings(
        "/new must clear the terminal scrollback",
        app.session.editor.visible(),
    );
    try std.testing.expect(app.session.confirmations.contains(.message));
}

test "a large pasted slash command is classified from expanded text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.editor.paste("/nope" ++ "x" ** 1000, true);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);

    try app.submit();

    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.warning, notice.severity);
    try std.testing.expect(std.mem.startsWith(
        u8,
        notice.content,
        "Enter: Send as a message · Drinky does not recognize the command /nope",
    ));
    try std.testing.expect(std.mem.endsWith(u8, notice.content, "x" ** 1000 ++ "."));
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "paste") == null);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
}

test "Esc, Ctrl+C, and Ctrl+D each cancel the picker with context" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    const keys = [_]terminal.Input.Key{ .escape, .{ .ctrl = 'c' }, .{ .ctrl = 'd' } };
    for (keys) |key| {
        const options = try gpa.alloc(ai.command.Outcome.Pick.Option, 1);
        options[0] = .{ .name = try gpa.dupe(u8, "alpha") };
        try app.session.applyOutcome(.{
            .pick = .{
                .select = undefined,
                .title = "Sign in",
                .cancellation_message = "You canceled the sign-in selection.",
                .options = options,
                .current = null,
            },
        });
        try app.handleKey(&key);
        try std.testing.expect(app.session.mode == .prompt);
        const notice = app.session.notice.?;
        try std.testing.expectEqual(ai.command.Outcome.Severity.information, notice.severity);
        try std.testing.expectEqualStrings(
            "You canceled the sign-in selection.",
            notice.content,
        );
        try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    }
}

test "Esc opens the step above the picker and cancels at the first step" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    try app.state.record(.openai_api_key, test_openai_model, .low);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.editor.insert("/model");
    try app.submit();
    const vendors = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Provider", vendors.title);
    try std.testing.expect(!vendors.can_step_back);

    try std.testing.expectEqual(@as(usize, 0), vendors.cursor);
    try app.handleKey(&.down);
    try app.handleKey(&.enter);
    const listed_models = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: openai-api-key", listed_models.title);
    try std.testing.expect(listed_models.marked == null);
    try std.testing.expectEqual(@as(usize, 1), listed_models.cursor);
    try std.testing.expect(listed_models.can_step_back);

    try app.handleKeys("\x1b\x1b");
    try std.testing.expect(app.session.mode == .picking);
    const reopened_vendors = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Provider", reopened_vendors.title);
    try std.testing.expectEqual(@as(usize, 1), reopened_vendors.cursor);
    try std.testing.expectEqual(@as(usize, 0), reopened_vendors.marked.?);
    try std.testing.expect(app.input.pendingEscape());
    try std.testing.expect(app.session.notice == null);

    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings(
        "You canceled the model selection.",
        app.session.notice.?.content,
    );
    try app.expectModel(test_anthropic_model.name());

    try app.session.editor.insert("/model");
    try app.submit();
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.mode.picking.picker.can_step_back);
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(app.session.mode == .prompt);
}

fn fakeFetch(result: *const ai.Accounts.Refresh) ai.Accounts.Refresh {
    return result.*;
}

fn openModelStepForTest(app: *App, out: *std.Io.Writer.Allocating, home: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.openai_api_key), .{
        .model = test_openai_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    app.session = Session.init(gpa, &out.writer, test_openai_model, .low);

    try app.session.editor.insert("/model");
    try app.submit();
    try std.testing.expectEqualStrings("Provider", app.session.mode.picking.picker.title);
    try app.handleKey(&.up);
    try app.handleKey(&.enter);
    const picker = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: anthropic-api-key", picker.title);
    try std.testing.expectEqual(@as(usize, 1), picker.options.len);
    try std.testing.expect(picker.can_step_back);
}

fn spawnFakeFetch(app: *App, result: *const ai.Accounts.Refresh) !void {
    const generation = try reserveGeneration(&app.fetch_generation);
    app.fetch = .{
        .future = try app.io.concurrent(fakeFetch, .{result}),
        .account = .anthropic_api_key,
        .generation = generation,
    };
    try app.session.beginPickerWait(fetch_wait_text);
}

test "a fetch wakeup rebuilds the model step over the fetched list" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    try openModelStepForTest(&app, &out, home);
    defer app.accounts.deinit();
    defer app.agent.deinit();
    defer app.session.deinit();
    app.state.models.set(.anthropic_api_key, ai.testing.model("claude-opus-5"));

    const result: ai.Accounts.Refresh = .{ .count = 1, .metadata_error = error.ConnectionTimedOut };
    try spawnFakeFetch(&app, &result);
    try std.testing.expect(app.session.pickerWaits());
    try std.testing.expect(app.session.animating());
    try std.testing.expectEqual(@as(usize, 0), app.session.mode.picking.picker.options.len);

    _ = try app.applyBatch(&.{.{ .fetch_ended = 99 }});
    try std.testing.expect(app.fetch != null);
    try std.testing.expect(app.session.pickerWaits());

    try ai.testing.seedAccount(&app.accounts, .anthropic_api_key, &.{"claude-opus-5"});
    _ = try app.applyBatch(&.{.{ .fetch_ended = app.fetch.?.generation }});
    try std.testing.expect(app.fetch == null);
    try std.testing.expect(!app.session.pickerWaits());
    try std.testing.expect(!app.session.animating());
    const rebuilt = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: anthropic-api-key", rebuilt.title);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", rebuilt.options[0].name);
    try std.testing.expectEqualStrings("claude-opus-5", rebuilt.options[1].name);
    try std.testing.expect(rebuilt.marked == null);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.cursor);
    try std.testing.expect(rebuilt.can_step_back);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "ConnectionTimedOut",
    ) != null);

    try app.handleKey(&.escape);
    try std.testing.expectEqualStrings("Provider", app.session.mode.picking.picker.title);
}

test "a failed fetch closes the picker and records the failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    try openModelStepForTest(&app, &out, home);
    defer app.accounts.deinit();
    defer app.agent.deinit();
    defer app.session.deinit();

    const result: ai.Accounts.Refresh = .{ .models_error = error.Timeout };
    try spawnFakeFetch(&app, &result);
    _ = try app.applyBatch(&.{.{ .fetch_ended = app.fetch.?.generation }});
    try std.testing.expect(app.fetch == null);
    try std.testing.expect(app.session.mode == .prompt);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    try std.testing.expectEqualStrings(
        "Drinky could not fetch the model list of anthropic-api-key because of error Timeout.",
        blocks[0].content.event.text.items,
    );
}

test "Esc cancels a fetch and returns the rows of its step" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    try openModelStepForTest(&app, &out, home);
    defer app.accounts.deinit();
    defer app.agent.deinit();
    defer app.session.deinit();

    const result: ai.Accounts.Refresh = .{ .count = 0 };
    try spawnFakeFetch(&app, &result);
    const generation = app.fetch.?.generation;

    try app.handleKey(&.down);
    try app.handleKey(&.enter);
    try std.testing.expect(app.fetch != null);
    try std.testing.expect(app.session.pickerWaits());

    try app.handleKey(&.escape);
    try std.testing.expect(app.fetch == null);
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expect(!app.session.pickerWaits());
    const reopened = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: anthropic-api-key", reopened.title);
    try std.testing.expectEqualStrings("Fetch the model list", reopened.options[0].name);
    try std.testing.expect(reopened.can_step_back);
    try std.testing.expectEqualStrings(
        "You canceled the model fetch.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);

    _ = try app.applyBatch(&.{.{ .fetch_ended = generation }});
    try std.testing.expect(app.fetch == null);
    try std.testing.expect(app.session.mode == .picking);

    try app.handleKey(&.escape);
    try std.testing.expectEqualStrings("Provider", app.session.mode.picking.picker.title);
}

test "Ctrl+C during a fetch leaves the command and joins the worker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    try openModelStepForTest(&app, &out, home);
    defer app.accounts.deinit();
    defer app.agent.deinit();
    defer app.session.deinit();

    const result: ai.Accounts.Refresh = .{ .count = 0 };
    try spawnFakeFetch(&app, &result);
    const generation = app.fetch.?.generation;
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(app.fetch == null);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings(
        "You canceled the model selection.",
        app.session.notice.?.content,
    );
    _ = try app.applyBatch(&.{.{ .fetch_ended = generation }});
    try std.testing.expect(app.session.mode == .prompt);
}

test "Esc walks back through the command list that opened the command" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    try app.state.record(.openai_api_key, test_openai_model, .low);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.editor.insert("/help");
    try app.submit();
    const commands = &app.session.mode.picking.picker;
    try std.testing.expect(!commands.can_step_back);
    const model_row = for (commands.options, 0..) |*option, index| {
        if (std.mem.eql(u8, option.name, "/model")) break index;
    } else return error.MissingModelRow;

    const window: terminal.View.Size = .{ .columns = 80, .rows = 12 };
    const last_row = commands.options.len - 1;
    for (0..last_row) |_| try app.handleKey(&.down);
    try app.session.paint(window);
    for (0..last_row - model_row) |_| try app.handleKey(&.up);
    try app.session.paint(window);
    const left_cursor = commands.cursor;
    const left_scroll = commands.scroll;
    try std.testing.expectEqual(model_row, left_cursor);
    try std.testing.expect(left_scroll > 0);

    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings("Provider", app.session.mode.picking.picker.title);
    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings(
        "Model: anthropic-api-key",
        app.session.mode.picking.picker.title,
    );

    app.session.dirty = false;
    try app.handleKey(&.escape);
    try std.testing.expectEqualStrings("Provider", app.session.mode.picking.picker.title);
    try std.testing.expect(app.session.dirty);

    app.session.dirty = false;
    try app.handleKey(&.escape);
    const reopened = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Command", reopened.title);
    try std.testing.expect(!reopened.can_step_back);
    try std.testing.expect(app.session.dirty);
    try std.testing.expectEqualStrings("/model", reopened.options[reopened.cursor].name);
    try std.testing.expectEqual(left_cursor, reopened.cursor);
    try std.testing.expectEqual(left_scroll, reopened.scroll);
    try std.testing.expect(reopened.marked == null);

    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings(
        "You canceled the command selection.",
        app.session.notice.?.content,
    );
}

test "the command list opens the skill list and writes the picked line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var demo = try tmp.dir.createDirPathOpen(io, "user/demo", .{});
    demo.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "user/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: Shape a demo.\n---\nFollow this skill.\n",
    });
    var work = try tmp.dir.createDirPathOpen(io, "work", .{});
    work.close(io);
    const user_root = try tmpPath(gpa, io, &tmp, "user");
    defer gpa.free(user_root);
    const project_start = try tmpPath(gpa, io, &tmp, "work");
    defer gpa.free(project_start);

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer app.skills.deinit();

    try app.session.editor.insert("/");
    try app.submit();
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expect(app.session.editor.blank());

    const commands = &app.session.mode.picking.picker;
    commands.cursor = for (commands.options, 0..) |*option, index| {
        if (std.mem.eql(u8, option.name, "/skill")) break index;
    } else return error.MissingSkillRow;
    const enter: terminal.Input.Key = .enter;
    try app.handleKey(&enter);
    try std.testing.expect(app.session.mode == .picking);
    const listed_skills = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Skill", listed_skills.title);
    try std.testing.expectEqualStrings("/skill:demo", listed_skills.options[0].name);
    try std.testing.expectEqualStrings("Shape a demo.", listed_skills.options[0].extra.?);

    try app.handleKey(&enter);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("/skill:demo ", app.session.editor.visible());
}

test "a user action clears a notice while background events leave it visible" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "temporary", .{}),
    );
    const background = [_]UiEvent{ .resize, .tick };
    try std.testing.expect(try app.applyBatch(&background));
    try std.testing.expectEqualStrings("temporary", app.session.notice.?.content);

    try app.handleKey(&.{ .char = 'x' });
    try std.testing.expect(app.session.notice == null);
    try std.testing.expectEqualStrings("x", app.session.editor.visible());
}

test "a transcript event survives later typing" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .failure, "backend failed", .{}),
    );
    try app.handleKey(&.{ .char = 'x' });

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    try std.testing.expectEqualStrings("backend failed", blocks[0].content.event.text.items);
}

fn tmpPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    tmp: *const std.testing.TmpDir,
    suffix: []const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, suffix });
}

test "the startup reports a skipped file alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "first.md", .data = "First.\n" });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    var loaded = try ai.instructions.load(gpa, io, &.{
        .directory = root,
        .paths = &.{"first.md"},
    });
    defer loaded.deinit();
    try app.reportNotices(loaded.notices());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);

    var skipped = try ai.instructions.load(gpa, io, &.{
        .directory = root,
        .paths = &.{ "first.md", "missing.md" },
    });
    defer skipped.deinit();
    try app.reportNotices(skipped.notices());
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "missing.md",
    ) != null);
}

test "/sources opens the composed page alone and escape restores the conversation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const page = "## Skills\n\n- `demo` · Scope: project · File: `SKILL.md`\n";
    var app: App = undefined;
    app.initForTest(gpa);
    app.sources_page = page;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.session.transcript.append(.event, .{}, "history marker");
    try app.session.editor.insert("/sources");
    try app.submit();

    try std.testing.expect(app.session.mode == .viewing);
    try std.testing.expectEqualStrings(page, app.session.mode.viewing.content);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    const page_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 8 });
    const page_bytes = out.written()[page_start..];
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "Sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "Scope: project") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "## Skills") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "history marker") == null);

    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
}

test "a configured required skill applies, and an unknown name reports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var skill = try tmp.dir.createDirPathOpen(io, ".agents/skills/demo", .{});
    skill.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".agents/skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: a test skill\n---\nbody\n",
    });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);
    const user_skills = try std.fs.path.join(gpa, &.{ root, "home", ".agents", "skills" });
    defer gpa.free(user_skills);

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = root,
        .project_root = null,
    });
    defer app.skills.deinit();
    app.skill_guard = .{ .working_directory = root };

    var user_instructions = ai.instructions.Result.init(gpa, .user);
    defer user_instructions.deinit();
    const required = [_]Config.RequiredSkill{
        .{ .glob = "**/*.zig", .skill = "demo" },
        .{ .glob = "**/*.ts", .skill = "nonesuch" },
        .{ .glob = "**/*.tsx", .skill = "nonesuch" },
    };
    const config: Config = .{
        .path = "/home/you/.drinky/config.json",
        .user_instructions = user_instructions,
        .required_skills = &required,
    };
    var notices: std.ArrayList(ai.instructions.Notice) = .empty;
    defer {
        for (notices.items) |notice| gpa.free(notice.text);
        notices.deinit(gpa);
    }
    var missing: std.ArrayList(Config.RequiredSkill) = .empty;
    defer missing.deinit(gpa);
    try app.resolveRequiredSkills(&config, &notices, &missing);
    try app.reportNotices(notices.items);

    try std.testing.expectEqual(@as(usize, 1), app.skill_guard.rules().len);
    const target = try std.fs.path.join(gpa, &.{ root, "src", "App.zig" });
    defer gpa.free(target);
    const refused = (try app.skill_guard.refusal(&.{
        .gpa = gpa,
        .io = io,
        .path = target,
        .history = &.{},
    })).?;
    defer refused.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, refused.content, "skill demo") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        app.skill_guard.rules()[0].source,
        ".agents/skills/demo/SKILL.md",
    ));

    const typescript = try std.fs.path.join(gpa, &.{ root, "src", "view.ts" });
    defer gpa.free(typescript);
    try std.testing.expect((try app.skill_guard.refusal(&.{
        .gpa = gpa,
        .io = io,
        .path = typescript,
        .history = &.{},
    })) == null);
    try std.testing.expectEqual(@as(usize, 0), notices.items.len);
    try std.testing.expectEqual(@as(usize, 2), missing.items.len);
    try std.testing.expectEqualStrings("**/*.ts", missing.items[0].glob);
    try std.testing.expectEqualStrings("nonesuch", missing.items[0].skill);
    try std.testing.expectEqualStrings("**/*.tsx", missing.items[1].glob);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test directoryLabel {
    const gpa = std.testing.allocator;
    const home = try directoryLabel(gpa, "/home/clemens", "/home/clemens");
    defer gpa.free(home);
    try std.testing.expectEqualStrings("~", home);

    const inside = try directoryLabel(gpa, "/home/clemens/github/drinky", "/home/clemens");
    defer gpa.free(inside);
    try std.testing.expectEqualStrings("~/github/drinky", inside);

    const outside = try directoryLabel(gpa, "/home/clemens2/work", "/home/clemens");
    defer gpa.free(outside);
    try std.testing.expectEqualStrings("/home/clemens2/work", outside);

    const below_root = try directoryLabel(gpa, "/work", "/");
    defer gpa.free(below_root);
    try std.testing.expectEqualStrings("~/work", below_root);

    const root = try directoryLabel(gpa, "/", "/");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("~", root);

    const capped = try directoryLabel(gpa, "/ä" ** 80, "/home");
    defer gpa.free(capped);
    try std.testing.expect(capped.len <= ui.status.directory_bytes_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(capped));
    try std.testing.expect(std.mem.startsWith(u8, capped, "…"));
    try std.testing.expect(std.mem.endsWith(u8, capped, "/ä"));

    const flag = "/🇩🇪";
    const flags = try directoryLabel(gpa, flag ** 20, "/home");
    defer gpa.free(flags);
    try std.testing.expect(flags.len <= ui.status.directory_bytes_max);
    try std.testing.expect(std.mem.startsWith(u8, flags, "…/🇩🇪"));
    try std.testing.expectEqual(
        @as(usize, 0),
        (flags.len - "…".len) % flag.len,
    );
}

test homeDirectory {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const real = try tmpPath(gpa, io, &tmp, "real");
    defer gpa.free(real);
    var real_directory = try std.Io.Dir.cwd().createDirPathOpen(io, real, .{});
    real_directory.close(io);
    try tmp.dir.symLink(io, real, "link", .{});
    const link = try tmpPath(gpa, io, &tmp, "link");
    defer gpa.free(link);

    const canonical = try homeDirectory(gpa, io, "/", link);
    defer gpa.free(canonical);
    try std.testing.expectEqualStrings(real, canonical);

    const missing = try homeDirectory(gpa, io, "/work", "../elsewhere");
    defer gpa.free(missing);
    try std.testing.expectEqualStrings("/elsewhere", missing);
}

test refreshBranch {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var marker = try tmp.dir.createDirPathOpen(io, ".git", .{});
    marker.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/topic\n" });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    app.refreshBranch();
    try std.testing.expect(app.session.branch() == null);
    try std.testing.expect(!app.session.dirty);

    app.session.branch_root = root;
    app.refreshBranch();
    try std.testing.expectEqualStrings("topic", app.session.branch().?);
    try std.testing.expect(app.session.dirty);
    app.session.dirty = false;
    app.refreshBranch();
    try std.testing.expect(!app.session.dirty);

    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "garbage\n" });
    app.refreshBranch();
    try std.testing.expect(app.session.branch() == null);
}

test showProject {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var marker = try tmp.dir.createDirPathOpen(io, ".git", .{});
    marker.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/topic\n" });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.input.deinit();
    app.directory_label = "~/project";
    app.project_instructions = try ai.instructions.discover(gpa, io, root);
    defer app.project_instructions.deinit();

    app.showProject(true);
    try std.testing.expectEqualStrings("", app.session.directory_shown);
    try std.testing.expect(app.session.branch_root == null);
    const events = [_]UiEvent{.{ .keys = try gpa.dupe(u8, "x") }};
    try std.testing.expect(!try app.applyBatch(&events));
    try std.testing.expect(app.session.branch() == null);

    app.showProject(false);
    try std.testing.expectEqualStrings("~/project", app.session.directory_shown);
    try std.testing.expectEqualStrings("topic", app.session.branch().?);
}

test "the status answer states the branch inside a Herdr pane" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var marker = try tmp.dir.createDirPathOpen(io, ".git", .{});
    marker.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/topic\n" });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.input.deinit();
    defer app.controller.deinit();
    app.directory_label = "~/project";
    app.project_instructions = try ai.instructions.discover(gpa, io, root);
    defer app.project_instructions.deinit();
    app.showProject(true);
    try std.testing.expectEqualStrings("", app.session.directory_shown);
    try std.testing.expect(app.session.branch() == null);

    const text = try app.statusText();
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        "~/project (topic) · Context: 0% (0/1.0M) · Cost: ~$0.00 · " ++
            "Model: anthropic-plan/claude-opus-5 · Effort: low",
        text,
    );
}

test "an input event re-reads the branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var marker = try tmp.dir.createDirPathOpen(io, ".git", .{});
    marker.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/topic\n" });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    defer app.input.deinit();
    app.session.branch_root = root;
    app.refreshBranch();
    try std.testing.expectEqualStrings("topic", app.session.branch().?);

    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/other\n" });
    const events = [_]UiEvent{.{ .keys = try gpa.dupe(u8, "x") }};
    try std.testing.expect(!try app.applyBatch(&events));
    try std.testing.expectEqualStrings("other", app.session.branch().?);
}

test "cancel draining preserves non-turn events ahead of newer queue data" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    var queued: [queue_capacity]UiEvent = @splat(.resize);
    queued[0] = .{ .turn = .{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .usage = .{} },
    } };
    try app.queue.putAll(io, &queued);

    const producer = struct {
        fn put(queue: *std.Io.Queue(UiEvent), producer_io: std.Io) void {
            queue.putOne(producer_io, .tick) catch {};
        }
    };
    var future = try io.concurrent(producer.put, .{ &app.queue, io });
    try std.testing.expect(app.drainCanceledProgress(true) == null);
    future.await(io);

    try std.testing.expectEqual(queue_capacity - 1, app.deferred_event_count);
    try app.queue.putOne(io, .{ .turn = .{
        .generation = 1,
        .progress_sequence = 2,
        .payload = .{ .usage = .{} },
    } });
    try std.testing.expect(app.drainCanceledProgress(true) == null);
    try std.testing.expectEqual(queue_capacity - 1, app.deferred_event_count);

    var deferred: [queue_capacity]UiEvent = undefined;
    const deferred_count = app.takeDeferredEvents(&deferred);
    try std.testing.expectEqual(queue_capacity - 1, deferred_count);
    for (deferred[0..deferred_count]) |event|
        try std.testing.expect(event == .resize);

    var newer: [2]UiEvent = undefined;
    try std.testing.expectEqual(newer.len, try app.queue.get(io, &newer, newer.len));
    try std.testing.expect(newer[0] == .tick);
    try std.testing.expect(newer[1] == .turn);
    newer[1].deinit(gpa);
}

test "progress allocation failure still finalizes a canceled turn" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.queue.putOne(io, .{ .turn = .{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "answer") },
    } });
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = .{
            .history_base = 0,
            .history_end = 1,
            .steering_committed_count = 0,
        }, .disposition = .canceled },
        .error_text = null,
        .generation = 1,
        .progress_sequence = 1,
        .progress_sequence_committed = 1,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expectError(error.OutOfMemory, app.cancelTurn());
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 0), app.deferred_event_count);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
}

test "cancel returns the submitted prompt as a rich draft with its paste placeholder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 15;
    try app.session.editor.paste(payload, true);
    var prompt = app.session.editor.detachTrimmed();
    app.session.retainTurnPrompt(&prompt, 0);

    try spawnCanceledTurn(&app);
    try app.cancelTurn();

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "a committed cancel drains queued progress into the transcript before rewinding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.beginTurn(5);

    const base = app.session.transcript.blocks().len;
    try app.session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    app.session.retainTurnPrompt(&prompt, base);

    app.agent.stats.cost = 2.5;
    const queued = [_]UiEvent{
        .{ .turn = .{
            .generation = 5,
            .progress_sequence = 1,
            .payload = .{ .usage = .{ .cost = 1.0 } },
        } },
        .{ .turn = .{
            .generation = 5,
            .progress_sequence = 2,
            .payload = .{ .text = try gpa.dupe(u8, "answer") },
        } },
        .{ .turn = .{
            .generation = 5,
            .progress_sequence = 3,
            .progress_sequence_committed = 2,
            .payload = .{ .tool_start = .{
                .name = try gpa.dupe(u8, "read"),
                .input_json = try gpa.dupe(u8, "{}"),
            } },
        } },
        .{ .turn = .{
            .generation = 5,
            .progress_sequence = 4,
            .progress_sequence_committed = 2,
            .payload = .{ .tool_result = .{
                .name = try gpa.dupe(u8, "read"),
                .summary = .{ .text = try gpa.dupe(u8, "Lines: 1") },
                .is_error = false,
            } },
        } },
    };
    try app.queue.putAll(io, &queued);

    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = .{
            .history_base = 0,
            .history_end = 1,
            .steering_committed_count = 0,
        }, .disposition = .canceled },
        .error_text = null,
        .generation = 5,
        .progress_sequence = 4,
        .progress_sequence_committed = 4,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});
    try app.cancelTurn();

    try std.testing.expect(app.session.mode == .prompt);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].content.user.items);
    try std.testing.expectEqualStrings("answer", blocks[1].content.model.items);
    try std.testing.expectEqualStrings(
        "Tool: read\nLines: 1",
        blocks[2].content.tool_result.text.items,
    );
    try std.testing.expect(!blocks[3].content.event.is_error);
    try std.testing.expectEqualStrings(
        "You canceled the turn.",
        blocks[3].content.event.text.items,
    );
    try std.testing.expectEqual(@as(f64, 2.5), app.session.stats_shown.cost);
    defer app.dropRevision();
    const revision = app.revision.?;
    try std.testing.expectEqual(@as(usize, 0), revision.transcript_base);
    try std.testing.expectEqual(@as(usize, 4), revision.transcript_end);
    try std.testing.expectEqualStrings("prompt", revision.prompt.visible.items);
}

test "the frame grid holds a fixed period through a late wake and a slow paint" {
    const wake_late_ns: i96 = 3 * std.time.ns_per_ms;
    const paint_ns: i96 = 5 * std.time.ns_per_ms;
    var grid: FrameGrid = .reset(1000);
    var previous_ns = grid.deadline_ns;
    for (0..60) |_| {
        const armed_ns = previous_ns + wake_late_ns + paint_ns;
        grid.advance(armed_ns);
        try std.testing.expectEqual(previous_ns + FrameGrid.interval_ns, grid.deadline_ns);
        try std.testing.expect(grid.deadline_ns != armed_ns + FrameGrid.interval_ns);
        previous_ns = grid.deadline_ns;
    }
    try std.testing.expectEqual(@as(i96, 1000) + 60 * FrameGrid.interval_ns, grid.deadline_ns);
}

test "the frame grid starts again after an overrun or an idle wait" {
    var grid: FrameGrid = .reset(1000);
    const overrun_ns: i96 = 1000 + 20 * std.time.ns_per_ms;
    grid.advance(overrun_ns);
    try std.testing.expectEqual(overrun_ns, grid.deadline_ns);

    const idle_ns: i96 = 5 * std.time.ns_per_s;
    grid.advance(idle_ns);
    try std.testing.expectEqual(idle_ns, grid.deadline_ns);

    grid.advance(idle_ns);
    try std.testing.expectEqual(idle_ns + FrameGrid.interval_ns, grid.deadline_ns);
}

const remote_testing = @import("remote/testing.zig");

const remote_ok_true = "{\"ok\":true,\"result\":true}";
const remote_ok_empty = "{\"ok\":true,\"result\":[]}";
const remote_ok_sent = "{\"ok\":true,\"result\":{\"message_id\":1}}";

fn initRemoteTest(
    self: *App,
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer.Allocating,
    server: *const remote_testing.Server,
    url_buffer: []u8,
) void {
    self.initForTest(gpa);
    self.io = io;
    self.controller.io = io;
    self.controller.base_url = server.url(url_buffer);
    self.controller.connect_ms = 60_000;
    self.controller.pace = remote_testing.pace;
    self.controller.code = "x7kq4m2p".*;
    self.agent = ai.Agent.init(gpa, io, null, .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    self.session = Session.init(gpa, &out.writer, null, .low);
    self.directory_label = "~/work/drinky";
}

fn deinitRemoteTest(self: *App) void {
    self.controller.detach(.exit) catch {};
    self.controller.abortDetach() catch {};
    self.controller.deinit();
    self.chat_picker.deinit();
    self.dropRetry();
    self.freeRemoteStrings();
    self.drainQueue();
    self.input.deinit();
    self.session.deinit();
    self.agent.deinit();
}

fn pumpRemoteEvents(self: *App, count_min: usize) !void {
    var batch: [queue_capacity]UiEvent = undefined;
    var applied: usize = 0;
    for (0..500) |_| {
        const count = try self.queue.get(self.io, &batch, 0);
        if (count > 0) {
            _ = try self.applyBatch(batch[0..count]);
            applied += count;
        }
        if (applied >= count_min) return;
        try self.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.TestTimedOut;
}

fn lastEventText(self: *const App) []const u8 {
    const blocks = self.session.transcript.blocks();
    return blocks[blocks.len - 1].content.event.text.items;
}

test "/remote lists the saved bots, and the remove row drops one with an event" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();
    defer app.controller.deinit();
    const store = &app.controller.store;
    try store.save(&.{ .token = "1:a", .id = 1, .username = "first_bot", .chat_id = 5 });
    try store.save(&.{ .token = "2:b", .id = 2, .username = "second_bot", .chat_id = 6 });

    try app.session.editor.insert("/remote");
    try app.submit();
    try std.testing.expect(app.session.mode == .picking);
    const picker = &app.session.mode.picking.picker;
    try std.testing.expectEqual(@as(usize, 4), picker.options.len);
    try std.testing.expectEqualStrings("@first_bot", picker.options[0].name);
    try std.testing.expectEqualStrings("Remove a bot", picker.options[3].name);

    try app.handleKeys("\x1b[B\x1b[B\x1b[B\r");
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expectEqualStrings("Remove a bot", app.session.mode.picking.picker.title);
    try app.handleKeys("\r");
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 1), app.controller.usernames().len);
    try std.testing.expectEqualStrings("second_bot", app.controller.usernames()[0]);
    try std.testing.expectEqualStrings("Drinky removed the bot @first_bot.", app.lastEventText());
}

test "the add row opens the token prompt, and every exit key or a bad token keeps the session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    defer app.input.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();
    defer app.controller.deinit();

    try app.session.editor.insert("/remote");
    try app.submit();
    try app.handleKeys("\r");
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(remote.Controller.State.token_prompt, app.controller.state());
    try std.testing.expect(app.session.input.owner == .terminal);
    try std.testing.expectEqualStrings("Bot token", app.session.input.caption.?.title);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Enter: Save") != null);

    try app.handleKeys("\r");
    try std.testing.expectEqualStrings("Type the bot token.", app.session.notice.?.content);
    try app.handleKeys("not a token\r");
    try std.testing.expectEqual(remote.Controller.State.token_prompt, app.controller.state());
    try std.testing.expect(std.mem.indexOf(u8, app.session.notice.?.content, "digits") != null);
    try std.testing.expectEqualStrings("not a token", app.session.editor.visible());

    try app.handleKeys("\x03");
    try std.testing.expectEqual(remote.Controller.State.token_prompt, app.controller.state());
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try app.handleKeys("\x03");
    try std.testing.expectEqual(remote.Controller.State.idle, app.controller.state());
    try std.testing.expect(app.session.input.caption == null);
    try std.testing.expectEqualStrings("You canceled the bot token.", app.session.notice.?.content);
    try std.testing.expect(app.running);

    try app.runCommand("/remote");
    try app.handleKeys("\r");
    try app.handleKeys("123:abc");
    try app.handleKey(&.escape);
    try std.testing.expectEqual(remote.Controller.State.idle, app.controller.state());
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try app.runCommand("/remote");
    try app.handleKeys("\r");
    try app.handleKeys("\x04");
    try std.testing.expectEqual(remote.Controller.State.idle, app.controller.state());
    try std.testing.expect(app.running);
}

test "Enter on the token-check wait starts no turn" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{});
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();

    try app.runCommand("/remote");
    try app.handleKeys("\r");
    try app.handleKeys("42:secret\r");
    try std.testing.expectEqual(remote.Controller.State.checking_token, app.controller.state());
    try std.testing.expect(app.session.mode == .picking);

    try app.handleKey(&.enter);
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expectEqualStrings("42:secret", app.session.editor.visible());
}

test "a pairing shows its wait and its code in the picker, and the bind takes the input" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "getMe", .replies = &.{
            .{ .status = 401, .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}" },
            .{ .body = "{\"ok\":true,\"result\":{\"id\":42,\"is_bot\":true,\"username\":\"drinky_bot\"}}" },
        } },
        .{ .method = "deleteWebhook", .replies = &.{ .{ .body = remote_ok_true }, .{ .body = remote_ok_true } } },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = remote_ok_empty },
            .{ .body =
            \\{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"/start x7kq4m2p"}}]}
            },
            .{ .body = remote_ok_empty },
        } },
        .{ .method = "sendMessage", .replies = &.{.{ .body = remote_ok_sent }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();

    try app.runCommand("/remote");
    try app.handleKeys("\r");
    try app.handleKeys("42:secret\r");
    try std.testing.expect(app.session.pickerWaits());
    try std.testing.expect(app.session.input.caption == null);
    try app.pumpRemoteEvents(1);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("Bot token", app.session.input.caption.?.title);
    try std.testing.expectEqualStrings("42:secret", app.session.editor.visible());
    try std.testing.expectEqualStrings("Telegram rejected the bot token.", app.session.notice.?.content);

    try app.handleKeys("\r");
    try app.pumpRemoteEvents(1);
    try std.testing.expectEqualStrings("Send the code x7kq4m2p to @drinky_bot", app.pairing_wait_text);
    try std.testing.expectEqualStrings("https://t.me/drinky_bot?start=x7kq4m2p", app.pairing_wait_link);
    try app.session.paint(.{ .columns = 120, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "\x1b]8;;https://t.me/drinky_bot?start=x7kq4m2p\x1b\\",
    ) != null);

    try app.pumpRemoteEvents(1);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.session.input.owner == .external);
    try std.testing.expectEqualStrings("Remote: @drinky_bot", app.session.input.caption.?.title);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqualStrings("You attached @drinky_bot.", app.lastEventText());
    const sent = try server.waitForSend(0);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"chat_id\":99") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        sent,
        "\"text\":\"ℹ You attached @drinky_bot.\"",
    ) != null);
    try app.syncMirror();
    try server.finish();
    try std.testing.expectEqual(@as(usize, 1), server.sendCount());
}

test "the barrier of an attach waits for the poller and not for a count of calls" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true, .delay_ms = 50 }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });

    try app.controller.attachSaved(0);
    try server.waitForSends(1);
    try server.waitForLongPoll();
    try std.testing.expectEqual(@as(usize, 1), server.countOf("/deleteWebhook"));
    try std.testing.expectEqual(@as(usize, 1), server.countOf("/setMyCommands"));
    try std.testing.expectEqual(@as(usize, 2), server.countOf("/getUpdates"));
    try server.finish();
}

test "while a bot holds the input the terminal takes a detach alone, and Enter names the bot" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{ .{ .body = remote_ok_sent }, .{ .body = remote_ok_sent } } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });

    try app.runCommand("/remote");
    try app.handleKeys("\r");
    try std.testing.expect(app.session.input.owner == .external);
    try std.testing.expect(app.session.mode == .prompt);
    try server.waitForLongPoll();

    try app.handleKeys("hello\r");
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings(
        "@drinky_bot holds the input. Esc detaches.",
        app.session.notice.?.content,
    );
    const attached_blocks = app.session.transcript.blocks().len;
    try app.handleKeys("/status\r");
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(attached_blocks, app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings("You attached @drinky_bot.", app.lastEventText());
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Remote: @drinky_bot") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Esc: Detach") != null);

    try app.handleKeys("\x1b\x04");
    try std.testing.expect(app.session.input.owner == .none);
    try std.testing.expectEqualStrings("Remote: @drinky_bot", app.session.input.caption.?.title);
    try std.testing.expectEqualStrings("Esc: Cancel", app.session.input.caption.?.controls);
    try std.testing.expect(app.running);
    try std.testing.expectEqualStrings("You detached @drinky_bot.", app.lastEventText());
    try app.handleKeys("hello\r");
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqualStrings(
        "Drinky detaches @drinky_bot. Esc ends the wait.",
        app.session.notice.?.content,
    );
    const sent = try server.waitForSend(1);
    try std.testing.expect(std.mem.indexOf(
        u8,
        sent,
        "\"text\":\"ℹ You detached @drinky_bot.\"",
    ) != null);
    try server.finish();

    try app.pumpRemoteEvents(1);
    try std.testing.expect(app.session.input.owner == .terminal);
    try std.testing.expect(app.session.input.caption == null);
    try app.handleKeys("\x04");
    try std.testing.expect(!app.running);
}

test "an exit key during the detach wait frees the editor at once and drops the last message" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    try app.handleKey(&.escape);
    try std.testing.expectEqual(remote.Controller.State.detaching, app.controller.state());
    try server.waitForSends(1);
    try app.handleKeys("\x1b\x04");
    try std.testing.expectEqual(remote.Controller.State.idle, app.controller.state());
    try std.testing.expect(app.session.input.owner == .terminal);
    try std.testing.expect(app.session.input.caption == null);
    try std.testing.expect(app.running);
    try std.testing.expectEqual(@as(usize, 1), server.sendCount());
    try server.finish();
}

test "an exit key under a bot clears an armed confirmation" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });

    app.session.beginTurn(1);
    try app.handleKeys("draft");
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(std.mem.indexOf(u8, app.session.notice.?.content, "Press Esc again") != null);

    try app.controller.attachSaved(0);
    try server.waitForLongPoll();
    try app.handleKey(&.escape);
    try std.testing.expectEqual(remote.Controller.State.detaching, app.controller.state());
    try app.handleKey(&.escape);
    try std.testing.expectEqual(remote.Controller.State.idle, app.controller.state());
    try std.testing.expect(app.session.mode == .turn);

    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.session.notice != null);
    try std.testing.expect(std.mem.indexOf(u8, app.session.notice.?.content, "Press Esc again") != null);
    try std.testing.expectEqualStrings("draft", app.session.editor.visible());
    try server.finish();
}

test "a Telegram message runs as a prompt, and its refusals answer in the chat" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = remote_ok_empty },
            .{ .body =
            \\{"ok":true,"result":[
            \\{"update_id":1,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"/login"}},
            \\{"update_id":2,"message":{"message_id":2,"date":0,"chat":{"id":99,"type":"private"},"text":"/nope"}},
            \\{"update_id":3,"message":{"message_id":3,"date":0,"chat":{"id":99,"type":"private"},"text":"do the work"}}
            \\]}
            },
        } },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
        } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);

    try app.pumpRemoteEvents(3);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    try server.finish();
    const login = try server.waitForSend(1);
    try std.testing.expect(std.mem.indexOf(
        u8,
        login,
        "\"text\":\"⚠ The command /login runs in the terminal alone.\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, login, "\"reply_parameters\":{\"message_id\":1}") != null);
    const unknown = try server.waitForSend(2);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "⚠ Drinky does not recognize the command /nope.") != null);
    const signed_out = try server.waitForSend(3);
    try std.testing.expect(std.mem.indexOf(
        u8,
        signed_out,
        "⚠ Sign in with /login in the terminal before you send a message.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, signed_out, "\"reply_parameters\":{\"message_id\":3}") != null);
}

test "a /status from Telegram gets one reply and no terminal event, also during a turn" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":60}}" },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
        } },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "answerCallbackQuery", .replies = &.{.{ .body = remote_ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    app.session.showSetup(null, null, .low);
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();
    const blocks_before = app.session.transcript.blocks().len;
    const status_wrapped =
        "ℹ ~/work/drinky · Context: 0 · Cost: ~$0.00 · Model: signed out · Effort: low";

    try app.submitChatMessage("/status", 30);
    const answer = try server.waitForSend(1);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"text\":\"" ++ status_wrapped ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"reply_parameters\":{\"message_id\":30}") != null);
    try std.testing.expectEqual(blocks_before, app.session.transcript.blocks().len);

    try app.submitChatMessage("/help", 31);
    _ = try server.waitForSend(2);
    try app.handleChatTap("900", .{ .row = .{ .serial = 1, .index = 4 } });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\"}",
        try server.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":60}",
        try server.waitForRequest("/deleteMessage", 0),
    );
    const tapped = try server.waitForSend(3);
    try std.testing.expect(std.mem.indexOf(u8, tapped, "\"text\":\"" ++ status_wrapped ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tapped, "reply_parameters") == null);
    try std.testing.expect(!app.chat_picker.isOpen());
    try std.testing.expectEqual(blocks_before, app.session.transcript.blocks().len);

    app.session.beginTurn(1);
    try app.submitChatMessage("/effort", 32);
    const refusal = try server.waitForSend(4);
    try std.testing.expect(std.mem.indexOf(
        u8,
        refusal,
        "\"text\":\"⚠ The command /effort cannot run while a turn runs.\"",
    ) != null);
    try app.submitChatMessage("/status", 33);
    const during = try server.waitForSend(5);
    try std.testing.expect(std.mem.indexOf(u8, during, "\"text\":\"" ++ status_wrapped ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, during, "\"reply_parameters\":{\"message_id\":33}") != null);
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(!app.session.hasSteering());
    try std.testing.expectEqual(blocks_before, app.session.transcript.blocks().len);
    try server.finish();
    try std.testing.expectEqual(@as(usize, 6), server.sendCount());
}

test "a credential rejection returns the Telegram prompt to the editor" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{ .{ .body = remote_ok_sent }, .{ .body = remote_ok_sent } } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    app.agent.deinit();
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_plan), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    app.session.account_shown = .anthropic_plan;
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    app.session.beginTurn(1);
    const base = app.session.transcript.blocks().len;
    try app.session.transcript.append(.user, .{}, "from Telegram");
    var draft = try ui.Editor.Draft.fromText(gpa, "from Telegram");
    app.session.retainExternalTurnPrompt(&draft, base, 7);
    var result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .credential_rejected },
        .error_text = try gpa.dupe(u8, turnFailureText(error.TokenGrantRejected).?),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try std.testing.expectEqual(remote.Controller.State.detaching, app.controller.state());
    try std.testing.expect(app.session.input.owner == .none);
    try std.testing.expectEqualStrings("from Telegram", app.session.editor.visible());
    try std.testing.expect(app.session.mode == .picking);
    try server.finish();
}

test "a pick after the detach wait attaches at once" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{ .{ .body = remote_ok_true }, .{ .body = remote_ok_true } } },
        .{ .method = "setMyCommands", .replies = &.{ .{ .body = remote_ok_true }, .{ .body = remote_ok_true } } },
        .{ .method = "getUpdates", .replies = &.{ .{ .body = remote_ok_empty }, .{ .body = remote_ok_empty } } },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
        } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });

    try app.controller.attachSaved(0);
    try server.waitForLongPoll();
    try app.handleKey(&.escape);
    try std.testing.expectEqual(remote.Controller.State.detaching, app.controller.state());

    try app.handleKeys("/remote\r");
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.session.mode == .prompt);

    _ = try server.waitForSend(1);
    try app.pumpRemoteEvents(1);
    try std.testing.expect(app.session.input.owner == .terminal);
    try app.runCommand("/remote");
    try app.handleKeys("\r");
    try std.testing.expectEqual(remote.Controller.State.attached, app.controller.state());
    try std.testing.expect(app.session.input.owner == .external);
    _ = try server.waitForSend(2);
    try server.finish();
}

test "a Telegram message during a turn queues as steering that drops while the bot holds the input" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
        } },
        .{ .method = "setMessageReaction", .replies = &.{.{ .body = remote_ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();
    app.session.beginTurn(1);

    try app.session.editor.insert("typed first");
    try app.submitSteering();
    try app.submitChatMessage("from the chat", 12);
    try app.submitChatMessage("/new", 13);
    try app.submitChatMessage("/nope", 14);
    try std.testing.expectEqual(@as(usize, 2), app.session.steering.items.len);
    try std.testing.expectEqual(@as(i64, 12), app.session.steering.items[1].source.external);
    const queued = try app.agent.steering.take();
    defer {
        for (queued) |message| gpa.free(message);
        gpa.free(queued);
    }
    try std.testing.expectEqual(@as(usize, 2), queued.len);
    try std.testing.expectEqualStrings("from the chat", queued[1]);
    const refusal = try server.waitForSend(1);
    try std.testing.expect(std.mem.indexOf(u8, refusal, "The command /new cannot run while a turn runs.") != null);
    const queued_mark = try server.waitForRequest("/setMessageReaction", 0);
    try std.testing.expect(std.mem.indexOf(u8, queued_mark, "\"message_id\":12,\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"👀\"}]") != null);
    const unknown = try server.waitForSend(2);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "Drinky does not recognize the command /nope.") != null);

    try app.session.endTurnWithReceipt(&.{
        .history_base = 0,
        .history_end = 0,
        .steering_committed_count = 0,
    });
    try app.session.reserveSteeringRecall();
    try std.testing.expectEqual(@as(usize, 1), app.session.recallLateSteering());
    try std.testing.expectEqualStrings("typed first", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);

    app.session.editor.clear();
    app.session.beginTurn(2);
    try app.submitChatMessage("after the detach", 14);
    try app.controller.detach(.user);
    try std.testing.expect(app.session.input.owner == .none);
    try app.session.endTurnWithReceipt(&.{
        .history_base = 0,
        .history_end = 0,
        .steering_committed_count = 0,
    });
    try app.session.reserveSteeringRecall();
    try std.testing.expectEqual(@as(usize, 1), app.session.recallLateSteering());
    try std.testing.expectEqualStrings("after the detach", app.session.editor.visible());
    app.agent.steering.clear();
    try server.finish();
}

test "the chat mirrors a completed turn with its activity message, its answer, and its summary" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":50}}" },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
        } },
        .{ .method = "editMessageText", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMessageReaction", .replies = &.{.{ .body = remote_ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    app.session.beginTurn(1);
    const base = app.session.transcript.blocks().len;
    try app.session.transcript.append(.user, .{}, "from Telegram");
    var draft = try ui.Editor.Draft.fromText(gpa, "from Telegram");
    app.session.retainExternalTurnPrompt(&draft, base, 7);
    try app.mirror.beginTurn(&app.controller, app.nowMs());
    const activity = try server.waitForSend(1);
    try std.testing.expect(std.mem.indexOf(
        u8,
        activity,
        "\"text\":\"ℹ Thinking\"",
    ) != null);

    var opening = [_]UiEvent{.{ .turn = .{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .usage = .{} },
    } }};
    _ = try app.applyBatch(&opening);
    try std.testing.expectEqual(@as(usize, 0), server.countOf("/setMessageReaction"));

    var events = [_]UiEvent{.{ .turn = .{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .text = try gpa.dupe(u8, "The **answer**.") },
    } }};
    _ = try app.applyBatch(&events);
    const committed_mark = try server.waitForRequest("/setMessageReaction", 0);
    try std.testing.expect(std.mem.indexOf(u8, committed_mark, "\"message_id\":7,\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"👍\"}]") != null);
    const writing = try server.waitForRequest("/editMessageText", 0);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":50,\"text\":\"ℹ Writing\"," ++
            "\"parse_mode\":\"HTML\",\"reply_markup\":{\"inline_keyboard\":[" ++
            "[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:1\"}]," ++
            "[{\"text\":\"Withdraw\",\"callback_data\":\"withdraw:1\"}]]}}",
        writing,
    );
    try std.testing.expectEqual(@as(usize, 2), server.sendCount());

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = .{ .history_base = 0, .history_end = 2, .steering_committed_count = 0 },
            .disposition = .completed,
        },
        .error_text = null,
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);
    try std.testing.expect(app.session.mode == .prompt);
    const answer = try server.waitForSend(2);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"text\":\"The <b>answer</b>.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"reply_markup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"disable_notification\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"parse_mode\":\"HTML\"") != null);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":50}",
        try server.waitForRequest("/deleteMessage", 0),
    );
    const summary = try server.waitForSend(3);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary,
        "\"text\":\"ℹ Tools: 0 calls · Time: ",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary,
        " · Context: 0 · Cost: ~$0.00\",\"disable_notification\":false,\"parse_mode\":\"HTML\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "reply_markup") == null);
    try server.finish();
    try std.testing.expectEqual(@as(usize, 1), server.countOf("/setMessageReaction"));
}

test "a failed turn marks its uncommitted messages and notifies its summary" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
        } },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMessageReaction", .replies = &.{
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
        } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    app.session.beginTurn(1);
    const base = app.session.transcript.blocks().len;
    try app.session.transcript.append(.user, .{}, "from Telegram");
    var draft = try ui.Editor.Draft.fromText(gpa, "from Telegram");
    app.session.retainExternalTurnPrompt(&draft, base, 7);
    try app.mirror.beginTurn(&app.controller, app.nowMs());
    try app.submitChatMessage("and this", 8);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);

    var result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .{ .failed = error.ApiError } },
        .error_text = try gpa.dupe(u8, "The provider refused the request."),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);
    app.agent.steering.clear();
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    const failure = try server.waitForSend(2);
    try std.testing.expect(std.mem.indexOf(
        u8,
        failure,
        "\"text\":\"⚠ The provider refused the request.\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, failure, "\"disable_notification\":true") != null);
    const summary = try server.waitForSend(3);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary,
        "\"text\":\"⚠ Failed · Tools: 0 calls · Time: ",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"disable_notification\":false") != null);
    const prompt = try server.waitForRequest("/setMessageReaction", 1);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"message_id\":7,\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"👎\"}]") != null);
    const dropped = try server.waitForRequest("/setMessageReaction", 2);
    try std.testing.expect(std.mem.indexOf(u8, dropped, "\"message_id\":8,\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"👎\"}]") != null);
    try server.finish();
    try std.testing.expectEqual(@as(usize, 3), server.countOf("/setMessageReaction"));
}

test "a Telegram command opens a keyboard, a tap picks a row, and a stale tap gets the toast" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":60}}" },
            .{ .body = remote_ok_sent },
        } },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "answerCallbackQuery", .replies = &.{ .{ .body = remote_ok_true }, .{ .body = remote_ok_true } } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    try app.submitChatMessage("/effort", 20);
    try std.testing.expect(app.chat_picker.isOpen());
    const picker = try server.waitForSend(1);
    try std.testing.expect(std.mem.indexOf(
        u8,
        picker,
        "\"text\":\"ℹ Effort\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, picker, "reply_parameters") == null);
    try std.testing.expect(std.mem.indexOf(u8, picker, "[{\"text\":\"✓ low\",\"callback_data\":\"row:1:0\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker, "[{\"text\":\"high\",\"callback_data\":\"row:1:2\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker, "[{\"text\":\"Cancel\",\"callback_data\":\"close:1\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker, "Back") == null);

    try app.handleChatTap("900", .{ .row = .{ .serial = 1, .index = 2 } });
    try std.testing.expect(app.agent.effort == .high);
    try std.testing.expect(!app.chat_picker.isOpen());
    try std.testing.expectEqualStrings("Drinky set the effort level to high.", app.lastEventText());
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\"}",
        try server.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":60}",
        try server.waitForRequest("/deleteMessage", 0),
    );
    try app.syncMirror();
    const event = try server.waitForSend(2);
    try std.testing.expect(std.mem.indexOf(
        u8,
        event,
        "\"text\":\"ℹ Drinky set the effort level to high.\"",
    ) != null);
    try std.testing.expectEqual(@as(usize, 0), server.countOf("/editMessageText"));

    try app.handleChatTap("901", .{ .row = .{ .serial = 1, .index = 0 } });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"901\",\"text\":\"This list is closed.\"}",
        try server.waitForRequest("/answerCallbackQuery", 1),
    );
    try std.testing.expect(app.agent.effort == .high);
    try server.finish();
}

test "the activity keyboard cancels the turn on one tap and withdraws the queue" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":50}}" },
        } },
        .{ .method = "editMessageText", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMessageReaction", .replies = &.{
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
        } },
        .{ .method = "answerCallbackQuery", .replies = &.{
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
        } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    app.session.beginTurn(1);
    try app.mirror.beginTurn(&app.controller, app.nowMs());
    const activity = try server.waitForSend(1);
    try std.testing.expect(std.mem.indexOf(u8, activity, "[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:1\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, activity, "[{\"text\":\"Withdraw\",\"callback_data\":\"withdraw:1\"}]") != null);
    try app.submitChatMessage("queued", 12);
    const queued_mark = try server.waitForRequest("/setMessageReaction", 0);
    try std.testing.expect(std.mem.indexOf(u8, queued_mark, "\"message_id\":12,\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"👀\"}]") != null);

    try app.handleChatTap("900", .{ .cancel_turn = 7 });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\",\"text\":\"The turn is over.\"}",
        try server.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqual(@as(usize, 1), server.countOf("/setMessageReaction"));

    try app.handleChatTap("901", .{ .withdraw = 1 });
    try std.testing.expectEqualStrings("{\"callback_query_id\":\"901\"}", try server.waitForRequest("/answerCallbackQuery", 1));
    const dropped = try server.waitForRequest("/setMessageReaction", 1);
    try std.testing.expect(std.mem.indexOf(u8, dropped, "\"message_id\":12,\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"👎\"}]") != null);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try app.handleChatTap("902", .{ .withdraw = 1 });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"902\",\"text\":\"Nothing queued.\"}",
        try server.waitForRequest("/answerCallbackQuery", 2),
    );

    try spawnCanceledTurn(&app);
    try app.handleChatTap("903", .{ .cancel_turn = 1 });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("{\"callback_query_id\":\"903\"}", try server.waitForRequest("/answerCallbackQuery", 3));
    const summary = try server.waitForRequest("/editMessageText", 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        summary,
        "\"text\":\"ℹ Canceled · Tools: 0 calls · Time: ",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "reply_markup") == null);
    try server.finish();
    try std.testing.expectEqual(@as(usize, 1), server.countOf("/editMessageText"));
    try std.testing.expectEqual(@as(usize, 2), server.countOf("/setMessageReaction"));
}

test "the failed turn message dismisses the retry from the chat and stands at the attach" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{ .{ .body = remote_ok_true }, .{ .body = remote_ok_true } } },
        .{ .method = "setMyCommands", .replies = &.{ .{ .body = remote_ok_true }, .{ .body = remote_ok_true } } },
        .{ .method = "getUpdates", .replies = &.{ .{ .body = remote_ok_empty }, .{ .body = remote_ok_empty } } },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":70}}" },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":80}}" },
            .{ .body = remote_ok_sent },
        } },
        .{ .method = "editMessageText", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "answerCallbackQuery", .replies = &.{ .{ .body = remote_ok_true }, .{ .body = remote_ok_true } } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    app.session.beginTurn(1);
    try app.mirror.beginTurn(&app.controller, app.nowMs());
    try app.session.transcript.append(.user, .{}, "from Telegram");
    var result: WorkerResult = .{
        .outcome = .{
            .receipt = .{ .history_base = 0, .history_end = 2, .steering_committed_count = 0 },
            .disposition = .{ .failed = error.ApiError },
        },
        .error_text = try gpa.dupe(u8, "The provider refused the request."),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);
    try std.testing.expect(app.retry != null);
    const failed = try server.waitForSend(4);
    try std.testing.expect(std.mem.indexOf(
        u8,
        failed,
        "\"text\":\"⚠ Failed turn\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "[{\"text\":\"Try again\",\"callback_data\":\"retry:2\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "[{\"text\":\"Dismiss\",\"callback_data\":\"dismiss:2\"}]") != null);

    try app.handleChatTap("900", .{ .dismiss = 1 });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\",\"text\":\"The retry is over.\"}",
        try server.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expect(app.retry != null);
    try app.handleChatTap("901", .{ .dismiss = 2 });
    try std.testing.expect(app.retry == null);
    try std.testing.expectEqual(Session.PromptOffer.none, app.session.prompt_offer);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":70,\"text\":\"⚠ Failed turn\"," ++
            "\"parse_mode\":\"HTML\"}",
        try server.waitForRequest("/editMessageText", 0),
    );

    try app.armRetry(&result, false);
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.input.owner == .none);
    _ = try server.waitForSend(5);
    try app.pumpRemoteEvents(1);
    try std.testing.expect(app.session.input.owner == .terminal);
    try app.controller.attachSaved(0);
    const attached = try server.waitForSend(7);
    try std.testing.expect(std.mem.indexOf(
        u8,
        attached,
        "\"text\":\"⚠ Failed turn\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, attached, "\"callback_data\":\"retry:3\"") != null);
    try std.testing.expect(!app.mirror.namesRetry(2));
    try app.handleKey(&.escape);
    _ = try server.waitForSend(8);
    try app.pumpRemoteEvents(1);
    try server.finish();
    try std.testing.expectEqual(@as(usize, 1), server.countOf("/editMessageText"));
}

test "the chat gives the answer its button when the commit lands before the receipt" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":50}}" },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":51}}" },
            .{ .body = remote_ok_sent },
        } },
        .{ .method = "editMessageText", .replies = &.{ .{ .body = remote_ok_true }, .{ .body = remote_ok_true } } },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = remote_ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    app.session.beginTurn(1);
    try app.mirror.beginTurn(&app.controller, app.nowMs());
    _ = try server.waitForSend(1);
    var events = [_]UiEvent{.{ .turn = .{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "The answer.") },
    } }};
    _ = try app.applyBatch(&events);
    _ = try server.waitForRequest("/editMessageText", 0);
    var committed = [_]UiEvent{.{ .turn = .{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .usage = .{} },
    } }};
    _ = try app.applyBatch(&committed);
    _ = try server.waitForRequest("/editMessageText", 1);

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = .{ .history_base = 0, .history_end = 2, .steering_committed_count = 0 },
            .disposition = .completed,
        },
        .error_text = null,
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);
    const answer = try server.waitForSend(2);
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"text\":\"The answer.\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        answer,
        "[{\"text\":\"Shorten\",\"callback_data\":\"shorten:2\"}]",
    ) != null);
    try std.testing.expect(app.mirror.namesAnswer(2));
    _ = try server.waitForSend(3);
    try server.finish();
}

test "the shorten button rides the last answer and its tap waits for the prompt" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":50}}" },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":60}}" },
        } },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "answerCallbackQuery", .replies = &.{
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
            .{ .body = remote_ok_true },
        } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    app.session.beginTurn(1);
    try app.mirror.beginTurn(&app.controller, app.nowMs());
    _ = try server.waitForSend(1);
    try app.session.transcript.append(.model, .{}, "a long answer");
    var result: WorkerResult = .{
        .outcome = .{
            .receipt = .{ .history_base = 0, .history_end = 2, .steering_committed_count = 0 },
            .disposition = .completed,
        },
        .error_text = null,
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);
    const answer = try server.waitForSend(2);
    try std.testing.expect(std.mem.indexOf(
        u8,
        answer,
        "[{\"text\":\"Shorten\",\"callback_data\":\"shorten:2\"}]",
    ) != null);

    try app.handleChatTap("900", .{ .shorten = 1 });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\",\"text\":\"This answer is not the newest one.\"}",
        try server.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expect(app.session.mode == .prompt);

    try app.handleChatTap("901", .{ .shorten = 2 });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"901\",\"text\":\"Sign in with /login in the terminal " ++
            "before you shorten an answer.\"}",
        try server.waitForRequest("/answerCallbackQuery", 1),
    );
    try std.testing.expect(app.session.mode == .prompt);

    app.agent.deinit();
    app.accounts = ai.testing.accounts(.{ .anthropic = "sk-ant" });
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api_key), .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    try app.handleChatTap("902", .{ .shorten = 2 });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"902\",\"text\":\"Select a model with /model in the terminal " ++
            "before you shorten an answer.\"}",
        try server.waitForRequest("/answerCallbackQuery", 2),
    );

    try app.session.openPage(&.{ .title = "Test page", .content = "body" });
    try app.handleChatTap("903", .{ .shorten = 2 });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"903\",\"text\":\"Drinky cannot act on a tap now.\"}",
        try server.waitForRequest("/answerCallbackQuery", 3),
    );
    app.session.closePage();

    app.session.beginTurn(2);
    try app.mirror.beginTurn(&app.controller, app.nowMs());
    try app.handleChatTap("904", .{ .shorten = 2 });
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"904\",\"text\":\"A turn runs. Wait for its end.\"}",
        try server.waitForRequest("/answerCallbackQuery", 4),
    );
    try std.testing.expect(app.mirror.namesAnswer(2));
    try server.finish();
}

test "a /new from Telegram records the remote bracket as the first event" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{ .{ .body = remote_ok_sent }, .{ .body = remote_ok_sent } } },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();
    try app.session.transcript.append(.model, .{}, "old answer");

    try app.submitChatMessage("/new", 21);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[0].content == .intro);
    try std.testing.expectEqualStrings(
        "You cleared the conversation while @drinky_bot is attached.",
        app.lastEventText(),
    );
    try std.testing.expectEqual(remote.Controller.State.attached, app.controller.state());
    try std.testing.expect(app.session.input.owner == .external);
    try app.syncMirror();
    const event = try server.waitForSend(1);
    try std.testing.expect(std.mem.indexOf(
        u8,
        event,
        "\"text\":\"ℹ You cleared the conversation while @drinky_bot is " ++
            "attached.\"",
    ) != null);
    try server.finish();
    try std.testing.expectEqual(@as(usize, 2), server.sendCount());
}

test "a skill loaded by a tap retains no prompt, so its failed turn fills no editor" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var skill = try tmp.dir.createDirPathOpen(io, ".agents/skills/demo", .{});
    skill.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".agents/skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: a test skill\n---\nbody\n",
    });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);
    const user_skills = try std.fs.path.join(gpa, &.{ root, "home", ".agents", "skills" });
    defer gpa.free(user_skills);
    var server = try remote_testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
            .{ .body = remote_ok_sent },
        } },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "answerCallbackQuery", .replies = &.{.{ .body = remote_ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    app.agent.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    app.skills.deinit();
    app.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = root,
        .project_root = null,
    });
    defer app.skills.deinit();
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();

    var context = app.chatContext();
    const prompt = (try ai.command.run(&context, "/skill:demo")).?.prompt;
    defer prompt.deinit(gpa);
    try app.startChatSkillTurn(&prompt, .{ .tap = "900" });
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.session.turn_prompt == null);
    try std.testing.expectEqualStrings("{\"callback_query_id\":\"900\"}", try server.waitForRequest("/answerCallbackQuery", 0));

    const result = app.awaitTurnFuture().?;
    defer app.freeWorkerResult(&result);
    try std.testing.expect(result.outcome.disposition == .failed);
    try app.finishWorkerResult(&result);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.session.input.owner == .external);
    try std.testing.expect(app.retry == null);
    for (app.session.transcript.blocks()) |*block| try std.testing.expect(block.content != .user_note);
    const failure = try server.waitForSend(2);
    try std.testing.expect(std.mem.indexOf(u8, failure, "\"text\":\"⚠ ") != null);
    try server.finish();
}

test "a withdraw whose mark fails after the take leaves the session and the queue in agreement" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var server = try remote_testing.Server.init(std.testing.allocator, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = remote_ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = remote_ok_empty }} },
    });
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;

    var app: App = undefined;
    app.initRemoteTest(gpa, io, &out, &server, &url_buffer);
    defer app.deinitRemoteTest();
    app.controller.gpa = std.testing.allocator;
    defer app.controller.gpa = std.testing.allocator;
    try app.controller.store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try app.controller.attachSaved(0);
    try server.waitForLongPoll();
    app.controller.gpa = gpa;
    app.session.beginTurn(1);
    try app.submitChatMessage("queued", 12);
    try std.testing.expectEqual(@as(usize, 1), app.agent.steering.messages.items.len);
    app.controller.dropped_count = 1;

    var step: usize = 0;
    while (true) : (step += 1) {
        failing.fail_index = failing.alloc_index + step;
        const result = app.withdrawSteering();
        failing.fail_index = std.math.maxInt(usize);
        const pending = app.session.steering.items.len - app.session.steering_retained_count;
        try std.testing.expectEqual(pending, app.agent.steering.messages.items.len);
        if (result) |count| {
            try std.testing.expectEqual(@as(usize, 0), count);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (step == 32) return error.TestSweepTooLong;
    }
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
}
