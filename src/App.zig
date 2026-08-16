//! The composition root and event loop. It authenticates, wires the tty, agent,
//! and `Session` together, then runs the interface off a single event channel.
//! Producer tasks push `Session.UiEvent`s onto the channel. The consumer loop
//! here drains them, drives the `Session` model, and paints through it.
//!
//! Network and stream I/O run off the UI thread. Four `io.concurrent` producers
//! feed one `std.Io.Queue(Session.UiEvent)`: a long-lived input reader
//! (stdin → `.keys`), the current turn worker (`agent.run` → generation-tagged
//! `.turn` events), a one-shot frame timer (sleep → `.tick`), and a SIGWINCH
//! watcher (self-pipe → `.resize`).
//!
//! The consumer-owned model and rendering live in `Session`: the transcript,
//! transient notice, live tail, editor, view, stats/model snapshots, and the
//! `applyTurnEvent`/`paint` seam. `Session` is io-, tty-, and agent-free, so a
//! test can drive the render loop from a scripted event sequence. `App` keeps
//! only the io, tasks, tty, and agent wiring and the key/command/turn
//! orchestration that drives the `Session`.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const Config = @import("Config.zig");
const Session = @import("Session.zig");
const State = @import("State.zig");
const system_prompt = @import("system_prompt.zig");
const ui = @import("ui/root.zig");

const App = @This();

// The compiled fallback model per vendor, used when config names none for the
// active account. Resolved at compile time so a bad name is a build error.
const anthropic_default = ai.models.get(.anthropic, "claude-opus-5") orelse
    @compileError("default anthropic model is not in the model table");
const openai_default = ai.models.get(.openai, "gpt-5.6-sol") orelse
    @compileError("default openai model is not in the model table");
const effort_default: ai.llm.Effort = .xhigh;

const intro_text = "Enter: Send · Shift+Enter: New line · Esc: Cancel · " ++
    "Ctrl+C: Clear · Ctrl+C twice: Quit · Ctrl+D: Quit";

/// Two Ctrl+C presses within this window quit. A lone press clears the editor.
const ctrl_c_window_ms = 500;

/// How long a lone Escape byte waits for the rest of a sequence before it becomes
/// an Escape key. A terminal without the Kitty protocol reports Escape as that one
/// byte, and every longer sequence starts with it. The wait must stay under human
/// reaction time and over the gap between two reads of one sequence.
const escape_wait_ms = 50;

/// Events the channel buffers before a producer blocks in `putOne`. One batched
/// `get` drains up to this many at once, so a whole burst collapses into a frame.
const queue_capacity = 256;

gpa: std.mem.Allocator,
io: std.Io,
tty: terminal.Tty,
/// SIGWINCH watcher: turns terminal resizes into `.resize` events.
resize: terminal.Resize,
accounts: ai.Accounts,
/// The configured default model per account, so an account switch mid-session
/// (a `/model`, `/login`, or `/logout`) resolves the same model as startup.
default_models: Config.DefaultModels,
/// The machine-local choices of this project: read once at startup, written
/// whenever the account, the model, or the effort level changes.
state: State,
/// The working directory the status line shows, with the home directory
/// abbreviated to `~`. Owned, and fixed for the session, because pith never
/// changes its working directory.
directory_label: []const u8,
/// Project instructions, skill metadata, and the composed prompt. All outlive
/// the agent, which borrows `prompt`.
project_instructions: ai.instructions.Result,
skills: ai.skills.Registry,
prompt: []const u8,
/// What the `config` tool returns: the document that describes every key of
/// `config.json`, and its box summary. It outlives the agent, which borrows it.
settings: ai.tool.Context.Settings,
agent: ai.Agent,
/// The consumer-owned model and rendering, driven by the loop.
session: Session,
/// Decodes stdin chunks into key events for the consumer's key handling.
input: terminal.Input,
running: bool,
ctrl_c_ms_last: i64,
/// When a held Escape byte becomes an Escape key, on the monotonic clock. Null
/// when the parser holds no lone Escape byte.
escape_deadline_ms: ?i64,
/// The one cross-thread channel: producer tasks push `UiEvent`s, and the consumer
/// drains and applies them. Backed by `queue_buffer`, so pin the `App`.
queue: std.Io.Queue(Session.UiEvent),
queue_buffer: [queue_capacity]Session.UiEvent,
/// Non-turn events temporarily removed while cancellation applies queued worker
/// progress. The consumer processes this prefix before reading newer queue data.
deferred_events: [queue_capacity]Session.UiEvent,
deferred_event_count: usize,
/// The long-lived stdin reader task, or null before the spawn. Shutdown cancels
/// and reaps it.
input_future: ?std.Io.Future(void),
/// The long-lived SIGWINCH watcher task, or null before the spawn. Shutdown
/// cancels and reaps it.
resize_future: ?std.Io.Future(void),
/// The running turn worker, or null between turns. Its result is the sole
/// terminal authority. A cancel resolves from the actual worker state and stays
/// recoverable even when the payload-free wakeup cannot enter the queue.
turn_future: ?std.Io.Future(WorkerResult),
/// A joined completion held until its already-queued terminal fence arrives.
/// The queue still carries no terminal payload or ownership.
pending_turn_result: ?WorkerResult,
/// Last generation reserved for a turn worker. The app never reuses a generation.
turn_generation: u64,
/// The pending frame timer, or null when none is armed (idle or clean).
tick_future: ?std.Io.Future(void),
/// A frame timer is armed and its `.tick` has not been drained yet.
tick_pending: bool,
/// The frame schedule. Only `armTick` advances it, so no frame can reset it.
frame_grid: FrameGrid,

/// The frame grid: the deadlines that pace the repaints. Each deadline is one
/// interval after the previous deadline, not one interval after the previous
/// frame ended. The work of a frame therefore falls inside its own interval and
/// does not add to it. A late wake moves the phase of one frame and leaves the
/// next deadline in place, which matters because macOS has no absolute sleep and
/// wakes a 16 ms wait about 3 ms late.
const FrameGrid = struct {
    /// The deadline of the armed frame timer, on the monotonic clock.
    deadline_ns: i96,

    /// The interval between two deadlines. The loop paints at most once per this
    /// window, so a keystroke echoes within it and a burst of stream events
    /// coalesces into it.
    const interval_ns = 16 * std.time.ns_per_ms;

    /// Start the grid at `now_ns`. The next deadline lands one interval later.
    fn reset(now_ns: i96) FrameGrid {
        return .{ .deadline_ns = now_ns };
    }

    /// Move to the next deadline. A slot that has already gone yields `now_ns`,
    /// so the loop never builds a backlog of missed frames, and the first frame
    /// after an idle wait paints at once.
    fn advance(self: *FrameGrid, now_ns: i96) void {
        const next_ns = self.deadline_ns + interval_ns;
        self.deadline_ns = if (next_ns <= now_ns) now_ns else next_ns;
    }
};

/// The turn worker's presentation handler. It does not mutate the transcript and
/// instead enqueues owned `UiEvent`s for the consumer. It lives on the worker
/// thread, so it touches only the thread-safe channel and gpa. `agent.run`'s
/// `anytype` handler makes this a drop-in for the consumer-side handler.
const TurnHandler = struct {
    app: *App,
    generation: u64,
    /// Monotonic count of progress events accepted by the UI queue.
    progress_sequence: u64 = 0,
    /// Latest accepted progress event known to belong to an agent checkpoint.
    progress_sequence_committed: u64 = 0,
    /// Owned error text captured from `onError`, which the agent calls just before
    /// a failed turn returns. The worker carries it in its joined result.
    error_text: ?[]u8 = null,

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
        maybe_summary: ?[]const u8,
        is_error: bool,
    ) !void {
        const name_copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(name_copy);
        const content_copy = try self.app.gpa.dupe(u8, content);
        errdefer self.app.gpa.free(content_copy);
        const maybe_summary_copy = if (maybe_summary) |summary|
            try self.app.gpa.dupe(u8, summary)
        else
            null;
        errdefer if (maybe_summary_copy) |summary_copy| self.app.gpa.free(summary_copy);
        try self.enqueue(.{ .tool_result = .{
            .name = name_copy,
            .content = content_copy,
            .summary = maybe_summary_copy,
            .is_error = is_error,
        } });
        // Tool-result slots are inside the checkpoint established before tool
        // dispatch, and the real value replaces its slot before this callback.
        self.progress_sequence_committed = self.progress_sequence;
    }

    pub fn onUsage(self: *TurnHandler, stats: ai.Agent.Stats) !void {
        try self.enqueue(.{ .usage = stats });
    }

    pub fn onStreamReset(self: *TurnHandler) !void {
        try self.enqueue(.stream_reset);
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

    /// Agent checkpoint callback: every progress event accepted so far now maps
    /// to durable history. It performs no I/O and cannot interrupt commitment.
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

/// The turn worker's authoritative joined result. Progress travels through the
/// queue, but terminal disposition, receipt, and optional owned error text live
/// only here.
const WorkerResult = struct {
    outcome: ai.Agent.Outcome,
    error_text: ?[]u8,
    generation: u64 = 0,
    /// Last progress event accepted by the UI queue.
    progress_sequence: u64 = 0,
    /// Last queued progress event that the agent committed to history.
    progress_sequence_committed: u64 = 0,
    /// Whether a payload-free terminal fence entered the queue. After an
    /// interrupted worker enqueue, the consumer uses this bit to enqueue a
    /// replacement once it joins the result.
    terminal_queued: bool = false,
};

/// Cooked-mode OAuth output keeps trusted prompt text separate from runtime URL
/// and path values, which pass through the terminal's inert-text policy.
const OauthPrompt = struct {
    writer: *std.Io.Writer,

    pub fn showAuthorization(self: *OauthPrompt, url: []const u8) !void {
        try self.writer.writeAll("Open this URL to authorize Pith:\n\n");
        try self.writeText(url);
        try self.writer.writeAll("\n\nPith waits for the response from the browser.\n");
        try self.writer.flush();
    }

    pub fn showBrowserLaunchFailed(self: *OauthPrompt) !void {
        try self.writer.writeAll("Pith could not open the browser. Open the URL above.\n");
        try self.writer.flush();
    }

    pub fn showAuthorized(self: *OauthPrompt, path: []const u8) !void {
        try self.writer.writeAll("Pith received authorization. Pith saved the credentials to ");
        try self.writeText(path);
        try self.writer.writeAll(".\n");
        try self.writer.flush();
    }

    pub fn showSaveFailed(self: *OauthPrompt, path: []const u8, error_name: []const u8) !void {
        try self.writer.writeAll(
            "Pith received authorization. Pith could not save the credentials to ",
        );
        try self.writeText(path);
        try self.writer.print(
            " because of error {s}. The sign-in stays active until Pith exits.\n",
            .{error_name},
        );
        try self.writer.flush();
    }

    fn writeText(self: *OauthPrompt, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try self.writer.writeByte('\n');
            _ = try terminal.width.writeText(self.writer, line);
            first = false;
        }
    }
};

/// The guidance sources of one startup report. Both instruction results have the
/// same type, so the field names keep the two apart at the call site.
const Sources = struct {
    user_instructions: *const ai.instructions.Result,
    project_instructions: *const ai.instructions.Result,
    skills: *const ai.skills.Registry,
};

fn validateWorkingDirectory(gpa: std.mem.Allocator, path: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(path)) return;
    const safe_path = try ai.instructions.diagnosticAlloc(gpa, path);
    defer gpa.free(safe_path);
    std.debug.print(
        "Pith cannot use the working directory {s} because its path is not valid UTF-8.\n",
        .{safe_path},
    );
    return error.WorkingDirectoryNotUtf8;
}

/// `directory` with `home` written as `~`, which is what the status line shows.
/// A directory outside the home directory keeps its own path. The result is
/// owned.
fn directoryLabel(
    gpa: std.mem.Allocator,
    directory: []const u8,
    home: []const u8,
) ![]const u8 {
    const label = if (ai.project.contains(&.{ .boundary = home, .target = directory })) home: {
        // A home directory that is a root already ends with the separator, so a
        // directory below it keeps that separator rather than losing it to the
        // `~`. The root itself is the whole label, so it keeps nothing.
        const below_root = directory.len > home.len and std.fs.path.isSep(home[home.len - 1]);
        const cut = if (below_root) home.len - 1 else home.len;
        break :home try std.fmt.allocPrint(gpa, "~{s}", .{directory[cut..]});
    } else try gpa.dupe(u8, directory);
    if (label.len <= ui.status.directory_bytes_max) return label;
    defer gpa.free(label);
    // The status line shows an identity, not a whole path, so a long path keeps
    // its tail. The start moves onto a display boundary, so the cut never splits
    // a grapheme cluster.
    const marker = "…";
    const budget = ui.status.directory_bytes_max - marker.len;
    const start = terminal.width.boundaryAtOrAfter(label, label.len - budget);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ marker, label[start..] });
}

/// The canonical home directory. The label compares it with the canonical
/// working directory, so a symbolic link inside `HOME` must resolve first. A home
/// directory Pith cannot resolve keeps its lexical path, which then simply does
/// not match, and the status line shows the whole working directory.
fn homeDirectory(
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
    home: []const u8,
) ![]u8 {
    const resolved = try std.fs.path.resolve(gpa, &.{ working_directory, home });
    errdefer gpa.free(resolved);
    // The canonical path carries a sentinel, so it becomes a plain copy that the
    // caller frees like every other path here.
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, resolved, gpa) catch return resolved;
    defer gpa.free(canonical);
    const owned = try gpa.dupe(u8, canonical);
    gpa.free(resolved);
    return owned;
}

/// Read the branch of the project and show it on the status line. Display only:
/// a repository whose head Pith cannot read leaves the directory standing alone.
fn refreshBranch(self: *App) void {
    const root = self.session.branch_root orelse return self.session.setBranch("");
    var maybe_head = ai.project.head(self.gpa, self.io, root);
    if (maybe_head) |*head| self.session.setBranch(head.name()) else self.session.setBranch("");
}

/// Wire up the tty, agent, and session, then run the interactive loop until the
/// user quits or stdin closes. When no account is authenticated the session
/// starts signed out and the login picker opens so the user signs in. Pin the
/// value: streams and the channel borrow its buffers.
pub fn run(
    self: *App,
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    api_keys: ai.Accounts.ApiKeys,
) !void {
    self.gpa = gpa;
    self.io = io;
    // The monotonic clock can start near zero. A boot press must never read as
    // the second of a pair.
    self.ctrl_c_ms_last = -ctrl_c_window_ms;
    self.escape_deadline_ms = null;
    self.tick_pending = false;
    self.frame_grid = .reset(0);
    self.input_future = null;
    self.resize_future = null;
    self.turn_future = null;
    self.pending_turn_result = null;
    self.turn_generation = 0;
    self.tick_future = null;
    self.initEventQueue();

    const cwd_source = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_source);
    const cwd = try std.Io.Dir.realPathFileAbsoluteAlloc(io, cwd_source, gpa);
    defer gpa.free(cwd);
    try validateWorkingDirectory(gpa, cwd);

    var config = try Config.load(gpa, io, &.{ .working_directory = cwd, .home = home });
    defer config.deinit(gpa);

    self.accounts = try ai.Accounts.init(gpa, io, home, config.timeouts, api_keys);
    defer self.accounts.deinit();
    self.default_models = config.default_models;

    const home_directory = try homeDirectory(gpa, io, cwd, home);
    defer gpa.free(home_directory);
    self.directory_label = try directoryLabel(gpa, cwd, home_directory);
    defer gpa.free(self.directory_label);

    self.project_instructions = try ai.instructions.discover(gpa, io, cwd);
    defer self.project_instructions.deinit();
    // One repository keeps one remembered choice, so the key is its root. Outside
    // a repository the working directory is the project.
    self.state = try State.open(gpa, io, &.{
        .working_directory = cwd,
        .home = home,
        .project = self.project_instructions.projectRoot() orelse cwd,
    });
    defer self.state.deinit();

    const user_skills = try std.fs.path.resolve(gpa, &.{ cwd, home, ".agents", "skills" });
    defer gpa.free(user_skills);
    self.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = cwd,
        .project_root = self.project_instructions.projectRoot(),
    });
    defer self.skills.deinit();
    self.prompt = try system_prompt.compose(gpa, &.{
        .core = system_prompt.default_core,
        .current_time = std.Io.Clock.real.now(io),
        .working_directory = cwd,
        .user_instructions = config.user_instructions.files(),
        .project_instructions = &self.project_instructions,
        .skills = self.skills.catalog(),
    });
    defer gpa.free(self.prompt);
    self.settings = try config.settings(gpa, &.{
        .anthropic_model = anthropic_default.name,
        .openai_model = openai_default.name,
        .effort = effort_default,
    });
    defer Config.freeSettings(gpa, &self.settings);

    // Start on the account this project used last, then on the first
    // authenticated account, or signed out (no client) when none is. The login
    // picker opens below to sign in. Pith resolves the model for the chosen or
    // placeholder account either way, so the status line has one to show.
    const active = self.startAccount();
    const start_account = active orelse .anthropic_subscription;
    const start_client = if (active) |account| self.accounts.client(account) else null;
    const start_model = self.accountModel(start_account);
    const start_effort = self.startEffort(config.default_effort);
    self.agent = ai.Agent.init(gpa, io, start_client, .{
        .model = start_model,
        .system = self.prompt,
        .retry = config.retry,
        .effort = start_effort,
        .bash = config.bash,
        .settings = self.settings,
    });
    defer self.agent.deinit();
    // Startup applies the remembered or the default choices, so it saves nothing.
    // Only a later change writes the file. A signed-out start has no account to
    // remember, so the first login records one.
    if (active) |account| try self.state.seed(account, &start_model, start_effort);

    try self.tty.init(io);
    defer self.tty.deinit();

    try self.resize.init();
    defer self.resize.deinit();

    self.session = Session.init(gpa, self.tty.writer(), self.agent.model, self.agent.effort);
    defer self.session.deinit();
    self.session.account_shown = active;
    self.session.directory_shown = self.directory_label;
    self.session.branch_root = self.project_instructions.projectRoot();
    self.refreshBranch();
    self.input = terminal.Input.init(gpa);
    defer self.input.deinit();

    try self.session.transcript.append(.intro, false, intro_text);
    // Surface any configured default-model name that did not resolve, so a typo or
    // a wrong-vendor entry does not disappear silently.
    for (config.dropped_models) |dropped| try self.recordEvent(
        .failure,
        "Pith ignored the configured default model \"{s}\" because the model is not valid for " ++
            "the {s} account. Pith uses the model \"{s}\" for this account.",
        .{ dropped.name, dropped.account.label(), self.defaultModel(dropped.account).name },
    );
    if (config.dropped_effort) |dropped| try self.recordEvent(
        .failure,
        "Pith ignored the configured default effort level \"{s}\" because Pith does not know " ++
            "that level. Pith uses the effort level \"{s}\".",
        .{ dropped, @tagName(self.agent.effort) },
    );
    // The parse ignores an unknown key so that an older binary reads a newer
    // file. Report it, because a typo otherwise looks like an applied setting.
    for (config.unknown_keys) |key| try self.recordEvent(
        .failure,
        "Pith ignored the unknown configuration key \"{s}\" in {s}.",
        .{ key, config.path },
    );
    if (config.unknown_keys_omitted) try self.recordEvent(
        .failure,
        "Pith omitted the remaining unknown configuration keys in {s}.",
        .{config.path},
    );
    try self.reportSources(&.{
        .user_instructions = &config.user_instructions,
        .project_instructions = &self.project_instructions,
        .skills = &self.skills,
    });
    // No account signed in: open the login picker (the same one /login opens) so
    // the user chooses how to sign in.
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
    // Start the frame grid at the first painted frame, so the first tick lands
    // one interval after it rather than at once.
    self.frame_grid = .reset(self.nowNs());

    self.running = true;
    defer self.shutdownTasks();
    self.input_future = try self.io.concurrent(readInput, .{self});
    self.resize_future = try self.io.concurrent(readResize, .{self});

    try self.runLoop();
}

fn initEventQueue(self: *App) void {
    self.queue = std.Io.Queue(Session.UiEvent).init(&self.queue_buffer);
    self.deferred_event_count = 0;
}

/// Leave the alternate screen and park the primary cursor before terminal teardown.
/// An output failure does not stop terminal teardown.
fn prepareTerminalExit(self: *App) void {
    self.tty.setAlternateScreen(false) catch return;
    self.session.parkCursor() catch {};
}

/// Cancel and reap every producer task, then drain and free any events they left
/// buffered. Runs before `tty.deinit`, so the reader no longer touches stdin when
/// the tty restores termios.
fn shutdownTasks(self: *App) void {
    // Shutdown is teardown, not an interactive cancel: free the worker result's
    // owned terminal text and leave the session untouched.
    if (self.cancelTurnFuture()) |result| self.freeWorkerResult(&result);
    if (self.pending_turn_result) |result| {
        self.freeWorkerResult(&result);
        self.pending_turn_result = null;
    }
    self.cancelFuture(&self.input_future);
    self.cancelFuture(&self.resize_future);
    self.cancelFuture(&self.tick_future);
    self.drainQueue();
}

/// Cancel and reap the turn worker, then return its joined result, or null if
/// none is running. `Future.cancel` returns the task's actual result, so a worker
/// that finished before the cancel reads as completed, not interrupted.
fn cancelTurnFuture(self: *App) ?WorkerResult {
    if (self.turn_future) |*future| {
        const result = future.cancel(self.io);
        self.turn_future = null;
        return result;
    }
    return null;
}

/// Reap the finished turn worker, then return its joined result, or null if none.
fn awaitTurnFuture(self: *App) ?WorkerResult {
    if (self.turn_future) |*future| {
        const result = future.await(self.io);
        self.turn_future = null;
        return result;
    }
    return null;
}

/// Take the authoritative result at its terminal fence. A late cancel can join it
/// first. Otherwise the fence guarantees the worker is ready to join.
fn takeTurnResult(self: *App) ?WorkerResult {
    if (self.awaitTurnFuture()) |result| return result;
    if (self.pending_turn_result) |result| {
        self.pending_turn_result = null;
        return result;
    }
    return null;
}

/// Nonblocking enqueue of a replacement terminal fence when cancellation joined
/// a worker with an interrupted enqueue. The fence follows every event already in
/// the queue. If producers fill the queue first, the consumer retries after its
/// next drain has opened capacity.
fn enqueuePendingTurnFence(self: *App) void {
    const result = if (self.pending_turn_result) |*pending| pending else return;
    if (result.terminal_queued) return;
    if (result.progress_sequence == std.math.maxInt(u64)) return;
    const events = [1]Session.UiEvent{.{ .turn = .{
        .generation = result.generation,
        .progress_sequence = result.progress_sequence + 1,
        .progress_sequence_committed = result.progress_sequence_committed,
        .payload = .turn_ended,
    } }};
    const count = self.queue.put(self.io, &events, 0) catch return;
    if (count == 1) result.terminal_queued = true;
}

/// Free any terminal error text still owned by a joined result after its caller
/// has resolved or discarded the outcome.
fn freeWorkerResult(self: *App, result: *const WorkerResult) void {
    if (result.error_text) |text| self.gpa.free(text);
}

/// Reconcile a completed or failed joined result, then promote late steering
/// only after a completion. A failure returns uncommitted drafts to the editor.
fn finishWorkerResult(self: *App, result: *const WorkerResult) !void {
    self.session.stats_shown = self.agent.stats;
    // A turn can check out another branch, so the status line settles here.
    self.refreshBranch();
    switch (result.outcome.disposition) {
        .completed => {
            try self.session.endTurnWithReceipt(&result.outcome.receipt);
            if (self.session.hasSteering()) try self.startSteeringTurn();
        },
        .credential_replaced => {
            const account = self.activeAccount() orelse
                return error.UnexpectedCredentialReplacement;
            if (!account.hasRefreshCredential())
                return error.UnexpectedCredentialReplacement;
            try self.finishFailedWorker(result, null);
            try self.acceptCredentialReplacement(account);
        },
        .credential_rejected => {
            const account = self.activeAccount() orelse
                return error.UnexpectedTokenGrantRejection;
            if (!account.hasRefreshCredential())
                return error.UnexpectedTokenGrantRejection;
            try self.finishFailedWorker(result, account);
        },
        .failed => try self.finishFailedWorker(result, null),
        .canceled, .closed => return error.UnexpectedTurnDisposition,
    }
}

/// Apply one failed result, then invalidate its rejected account when present.
fn finishFailedWorker(
    self: *App,
    result: *const WorkerResult,
    maybe_rejected: ?ai.llm.Account,
) !void {
    try self.session.reserveFailureRestore(&result.outcome.receipt);
    defer self.agent.steering.clear();
    try self.session.failTurnWithReceipt(&result.outcome.receipt, result.error_text);
    if (maybe_rejected) |account| try self.rejectCredential(account);
}

/// Cancel and reap `maybe_future`'s task, then clear the handle. A no-op when null.
fn cancelFuture(self: *App, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.cancel(self.io);
        maybe_future.* = null;
    }
}

/// Reap `maybe_future`'s finished task, then clear the handle. A no-op when null.
fn awaitFuture(self: *App, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.await(self.io);
        maybe_future.* = null;
    }
}

/// Free every event still buffered on the channel. Only safe once the producers
/// are reaped, so no new event can arrive mid-drain.
fn drainQueue(self: *App) void {
    var batch: [queue_capacity]Session.UiEvent = undefined;
    while (true) {
        const count = self.queue.get(self.io, &batch, 0) catch break;
        if (count == 0) break;
        for (batch[0..count]) |event| event.deinit(self.gpa);
    }
    for (self.deferred_events[0..self.deferred_event_count]) |event| event.deinit(self.gpa);
    self.deferred_event_count = 0;
}

/// Move the consumer-owned prefix into `batch` and transfer event ownership.
fn takeDeferredEvents(self: *App, batch: *[queue_capacity]Session.UiEvent) usize {
    const count = self.deferred_event_count;
    @memcpy(batch[0..count], self.deferred_events[0..count]);
    self.deferred_event_count = 0;
    return count;
}

/// The consumer: block on the channel, drain a coalesced batch, apply each event
/// to the session, and paint only on a `.tick`. The loop arms a tick whenever the
/// session is dirty, a turn animates, or a held Escape byte waits, and none is
/// pending. A clean idle interface stays inert (no tick, blocked on an empty
/// channel).
fn runLoop(self: *App) !void {
    var batch: [queue_capacity]Session.UiEvent = undefined;
    while (self.running) {
        const count = if (self.deferred_event_count > 0)
            self.takeDeferredEvents(&batch)
        else
            self.queue.get(self.io, &batch, 1) catch |err| switch (err) {
                error.Closed, error.Canceled => break,
            };
        self.enqueuePendingTurnFence();
        const ticked = try self.applyBatch(batch[0..count]);
        try self.flushEscape();
        if (ticked) {
            self.tick_pending = false;
            self.awaitFuture(&self.tick_future);
            if (self.session.advanceFrame()) {
                try self.refresh();
                self.session.dirty = false;
            }
        }
        // A held Escape byte arms a frame too, because its wait ends on a tick and
        // an idle loop has no other wake.
        const waiting = self.session.dirty or
            self.session.animating() or
            self.escape_deadline_ms != null;
        if (waiting and !self.tick_pending) self.armTick();
    }
}

/// Apply one bounded queue batch. Once the queue hands the batch to the consumer,
/// this function owns every event. An error frees the unprocessed suffix.
fn applyBatch(self: *App, events: []const Session.UiEvent) !bool {
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
                try self.handleKeys(bytes);
            },
            .turn => |*turn_event| {
                const turn_finished = try self.session.applyTurnEvent(turn_event);
                if (turn_finished) {
                    const result = self.takeTurnResult() orelse return error.MissingTurnWorker;
                    defer self.freeWorkerResult(&result);
                    try self.finishWorkerResult(&result);
                }
            },
        }
    }
    return ticked;
}

/// Arm the next frame: a one-shot timer for the next deadline on the grid. This
/// is the only place that advances the grid, so the work of a frame stays inside
/// its own interval. On the impossible failure to spawn the timer, paint inline
/// and start the grid again at the painted frame.
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

/// Frame timer task: wait for the deadline, then push one `.tick`. It waits on
/// the deadline itself, not on a duration, so the wait cannot drift with the time
/// that the arming took. A deadline that has already gone returns at once, which
/// is what `std.Io.Clock.Timestamp.wait` promises. Canceled at shutdown or when
/// its frame is superseded. A cancel just drops the tick. It takes the deadline
/// by value, so it reads no state the consumer can write.
fn frameTimer(self: *App, deadline_ns: i96) void {
    const deadline: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(deadline_ns),
        .clock = .awake,
    };
    deadline.wait(self.io) catch return;
    self.queue.putOne(self.io, .tick) catch {};
}

/// Resize watcher task: block on the SIGWINCH self-pipe and push one `.resize`
/// per wake, so the consumer repaints at the new size (which `refresh` re-reads).
/// Exits on cancel (shutdown) or a pipe fault.
fn readResize(self: *App) void {
    while (true) {
        self.resize.wait(self.io) catch return;
        self.queue.putOne(self.io, .resize) catch return;
    }
}

/// Input reader task: block on stdin and push each chunk as owned `.keys`. Exits
/// on cancel (shutdown). On stdin close or a read fault it closes the channel so
/// the consumer's `get` returns `error.Closed` and the program winds down.
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
        if (count == 0) continue;
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

/// Transcript text for a turn the agent failed without a report through `onError`.
/// These are the agent's own verdicts on a reply, not server messages, so each
/// gets a sentence. A refusal or an unrecognized provider outcome is ordinary
/// model behavior and must not read as an internal fault. A rejected credential
/// reports only the provider result. The app records its account resolution. A
/// busy credential store keeps the refreshed token in memory. The next turn
/// retries its save before a provider request. Anything unmapped returns null,
/// and the caller wraps its error name.
fn turnFailureText(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnsupportedReply => "Pith cannot keep the response because the model returned " ++
            "a refusal, a pause, or an unsupported result.",
        error.EmptyReply => "The model returned an empty response.",
        error.IncompleteReply => "Pith did not receive the complete model response.",
        error.TooManyToolRounds => "The turn reached the limit for tool rounds.",
        error.CredentialReplaced => "Pith found a replacement credential for this account. " ++
            "Pith removed the prior account evidence. Try the turn again.",
        error.TokenGrantRejected => "The provider rejected the refresh credential.",
        error.TokenRequestFailed => "The provider did not accept the token request. " ++
            "Pith kept this account signed in.",
        error.TokenServiceUnavailable => "The provider credential service is not available. " ++
            "Try the turn again.",
        error.StoreBusy => "Another Pith instance is writing the credential file. " ++
            "Try the turn again.",
        else => null,
    };
}

/// Turn worker task: run one turn, queue a payload-free completion wakeup after
/// all progress, and return the sole terminal result. Cancellation or channel
/// closure suppresses the wakeup. An interrupted wakeup still leaves the joined
/// result authoritative.
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
                    "Pith could not complete the turn because of error {s}.",
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

/// The active account, or null when the agent is signed out.
fn activeAccount(self: *const App) ?ai.llm.Account {
    const client = self.agent.client orelse return null;
    return client.account();
}

/// Whether an account is active. Pith refuses normal messages until a login.
fn signedIn(self: *const App) bool {
    return self.activeAccount() != null;
}

/// The account to start on: the one this project used last, when it is still
/// authenticated, else the first authenticated account. Null when no account is
/// authenticated.
fn startAccount(self: *const App) ?ai.llm.Account {
    if (self.state.start.account) |account| {
        if (self.accounts.isAuthenticated(account)) return account;
    }
    return self.accounts.firstAuthenticated();
}

/// The model `account` runs: the one it ran last in this project, else the
/// account's default model. A model belongs to the account that ran it, so
/// another account gets its own default. Startup, a switch, and a login all read
/// this one rule.
///
/// `state` holds the compiled table's own entry, so the account overlay applies
/// here on every read. An OpenAI subscription learns its real context windows at
/// login. A model resolved before that login keeps a stale window.
fn accountModel(self: *const App, account: ai.llm.Account) ai.models.Model {
    const base = self.state.models.get(account) orelse return self.defaultModel(account);
    return self.accounts.resolveModel(account, base);
}

/// The effort level to start on: the one this project used last, else the
/// `configured` default, else the compiled fallback.
fn startEffort(self: *const App, configured: ?ai.llm.Effort) ai.llm.Effort {
    return self.state.start.effort orelse configured orelse effort_default;
}

/// The model to start `account` on: the configured default, else the compiled
/// per-vendor fallback.
fn defaultModel(self: *const App, account: ai.llm.Account) ai.models.Model {
    const base = self.default_models.get(account) orelse switch (account.provider()) {
        .anthropic => anthropic_default,
        .openai => openai_default,
    };
    return self.accounts.resolveModel(account, base);
}

/// Decode a stdin chunk into key events and apply each. Runs on the consumer, so
/// a submitted line spawns a turn worker and ctrl-c cancels a running one.
///
/// An exit key that returns the session to the prompt — a page close, a picker
/// cancel, a turn cancel — ends the chunk, and the keys behind it are dropped.
/// Those keys are the rest of one exit attempt, such as the Esc and Ctrl+D of
/// `\x1b\x04` from a terminal without the Kitty protocol. The prompt must never
/// act on them, because Ctrl+D there quits pith and Ctrl+C there clears the draft
/// the closed layer hid. Only an exit key drains, so a picker confirmation still
/// keeps the characters typed behind it.
fn handleKeys(self: *App, bytes: []const u8) !void {
    try self.input.feed(bytes);
    while (self.input.next()) |event| {
        const at_prompt = self.session.mode == .prompt;
        try self.handleKey(&event);
        if (!at_prompt and self.session.mode == .prompt and isExitKey(&event)) {
            while (self.input.next()) |_| {}
            break;
        }
    }
    // A held Escape byte starts its wait here. Bytes that complete a sequence
    // arrive in the next chunk at the latest, so this chunk ends the wait too.
    self.escape_deadline_ms = if (self.input.pendingEscape())
        self.nowMs() + escape_wait_ms
    else
        null;
}

/// Whether `event` is one of the keys a user presses to leave the current layer.
/// Enter is not one, even where it also returns to the prompt.
fn isExitKey(event: *const terminal.Input.Key) bool {
    return switch (event.*) {
        .escape => true,
        .ctrl => |letter| letter == 'c' or letter == 'd',
        else => false,
    };
}

/// Turn a held Escape byte into an Escape key once its wait passes. A terminal
/// without the Kitty protocol reports Escape as that one byte, so this is the only
/// path that closes a page or cancels a turn there.
fn flushEscape(self: *App) !void {
    const deadline = self.escape_deadline_ms orelse return;
    if (self.nowMs() < deadline) return;
    self.escape_deadline_ms = null;
    if (!self.input.takeEscape()) return;
    try self.handleKey(&.escape);
}

fn handleKey(self: *App, event: *const terminal.Input.Key) !void {
    // Only an idle Enter can confirm the stale-cache warning. Every other user
    // action clears both the notice and its one-shot confirmation.
    const confirms_cache = self.session.mode == .prompt and event.* == .enter;
    if (!confirms_cache) self.session.cancelCacheConfirmation();
    // Clear before the key routes, so a notice produced by this action survives it.
    self.session.clearNotice();
    switch (self.session.mode) {
        .picking => return self.handlePickerKey(event),
        .viewing => return self.handlePageKey(event),
        .turn => return self.handleTurnKey(event),
        .prompt => {},
    }
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submit(),
        .ctrl => |letter| switch (letter) {
            'c' => {
                self.clearOrQuit();
                if (self.running) self.session.dirty = true;
            },
            'd' => if (self.session.editor.visible().len == 0) {
                self.running = false;
            },
            else => {},
        },
        else => {},
    }
}

/// Apply an editing key to the live editor and mark the session dirty. Returns
/// whether `event` was an editing key. Shared by the prompt and by a running
/// turn, where the editor stays live so the user can steer.
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

/// Keys during a streaming turn. The editor stays live for steering: the user can
/// type and edit, Enter queues a steering message, and Ctrl+P recalls the queue
/// into the editor. Esc and Ctrl+D cancel the turn, which keeps the draft, so
/// neither key needs the empty-editor guard that protects the quit at the prompt.
/// Ctrl+C keeps its prompt meaning and clears a draft first.
fn handleTurnKey(self: *App, event: *const terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submitSteering(),
        .escape => try self.cancelTurn(),
        .ctrl => |letter| switch (letter) {
            'c' => try self.clearOrCancel(),
            'd' => try self.cancelTurn(),
            'p' => try self.pullSteering(),
            else => {},
        },
        else => {},
    }
}

/// Ctrl+C during a turn: clear a draft, or cancel the turn when the editor is
/// empty. The editor stays live for steering, so the key that stops the turn must
/// not drop typed text. Esc is the direct cancel.
fn clearOrCancel(self: *App) !void {
    if (self.session.editor.visible().len != 0) {
        self.session.editor.clear();
        self.session.markEdited();
        return;
    }
    try self.cancelTurn();
}

/// Enter during a turn: queue the line as a steering message, shown at once and
/// carried to the worker to fold into the turn. A slash command cannot run
/// mid-turn (it can open a picker, which a turn cannot host), so it stays in the
/// editor to send once the turn ends.
fn submitSteering(self: *App) !void {
    if (self.session.editor.blank()) return;
    const text = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(text);
    if (ai.command.parse(text) != null) return;
    // Reserve the mirror slot before the channel push, so the push is the only
    // fallible step before the draft moves in. If the push fails, the editor is
    // untouched. Once it succeeds, the literal-edge-trimmed draft moves into the
    // mirror with no allocation. The channel copy is whole-prompt trimmed. The
    // recovery draft keeps its atoms and their exact payloads.
    try self.session.reserveSteering();
    try self.agent.steering.push(text);
    var draft = self.session.editor.detachTrimmed();
    self.session.commitSteeringDraft(&draft);
    self.session.dirty = true;
}

/// Ctrl+P during a turn: pull the pending steering back into the editor as live
/// placeholder drafts, after any in-progress line. Content comes from the mirror,
/// so a paste returns as its marker, not expanded text. The channel gives only
/// the count that selects the mirror's pending suffix. The remaining prefix stays
/// retained until it is consumed or a failed delivery makes it recallable.
fn pullSteering(self: *App) !void {
    // Reserve every possible draft move so no fallible work follows the channel
    // take.
    try self.session.reserveSteeringRecall();
    const taken = try self.agent.steering.take();
    defer {
        for (taken) |message| self.gpa.free(message);
        self.gpa.free(taken);
    }
    // The count identifies the rich-record suffix currently owned by the queue.
    // A batch already owned by the worker remains retained.
    self.session.recallSteering(taken.len);
}

/// Start a turn from steering the worker never took because the previous turn
/// ended first. Keep both plain and rich forms recoverable until the transcript
/// block and worker have committed.
fn startSteeringTurn(self: *App) !void {
    var taken = try self.agent.steering.take();
    defer {
        for (taken) |message| self.gpa.free(message);
        self.gpa.free(taken);
    }
    errdefer self.agent.steering.restoreTaken(&taken);
    if (taken.len == 0) {
        self.session.clearSteering();
        return;
    }

    const joined = try ai.Steering.join(self.gpa, taken);
    defer self.gpa.free(joined);
    // Copy the rich mirror before the spawn, so a failed start leaves its original
    // drafts untouched. A later cancellation can then return paste atoms intact.
    var prompt = try ui.Editor.Draft.fromDrafts(self.gpa, self.session.steering.items);
    errdefer prompt.deinit(self.gpa);
    const base = self.session.transcript.blocks().len;
    errdefer self.session.transcript.truncate(base);
    try self.session.transcript.append(.user, false, joined);
    self.session.dirty = true;
    try self.runTurn(joined);
    self.session.retainTurnPrompt(&prompt, base);
    self.session.clearSteering();
}

/// Abort the running turn: cancel and join the worker, then resolve from its
/// joined disposition rather than event timing. A genuine cancel restores
/// uncommitted rich drafts. A worker that finished first shows as its own
/// completion or failure. Queued events retain their generation and cannot affect
/// a successor.
fn cancelTurn(self: *App) !void {
    // Preflight editor capacity to restore every rich draft before the join. An
    // OOM then cannot leave an already-canceled worker's drafts unrecoverable.
    // The mirror is consumer-owned and stable here.
    try self.session.reserveSteeringRestore();
    const result = self.cancelTurnFuture() orelse return;
    switch (result.outcome.disposition) {
        // The joined outcome is authoritative. Sync the usage a queued `.usage`
        // can no longer deliver (it dies at the generation gate). Restore the
        // uncommitted rich drafts to the editor (the committed ones are in
        // history). Clear the plain queue the agent returned its rolled-back batch
        // to, and show the cancellation.
        .canceled => {
            defer self.freeWorkerResult(&result);
            const receipt = &result.outcome.receipt;
            const committed = receipt.history_end != receipt.history_base;
            // The worker is joined, so one bounded queue take owns all progress it
            // successfully published. Preserve non-turn events in a consumer-side
            // prefix. A put-back into the queue races producers.
            var maybe_progress_error = self.drainCanceledProgress(committed);
            // A queued usage snapshot can predate usage recorded while cancellation
            // unwound the provider stream. The joined agent state wins.
            self.session.stats_shown = self.agent.stats;
            // A canceled turn can leave another branch checked out behind it.
            self.refreshBranch();
            self.session.cancelReceipt(receipt, result.progress_sequence_committed);
            self.agent.steering.clear();
            if (committed) {
                self.session.abortTurn() catch |err| {
                    if (maybe_progress_error == null) maybe_progress_error = err;
                };
            } else {
                self.session.endTurn();
            }
            if (maybe_progress_error) |progress_error| return progress_error;
        },
        // The worker won the race. Retain the joined result until FIFO progress
        // ahead of its terminal fence has applied. After an interrupted worker
        // enqueue, append a replacement fence and do not block the consumer.
        .completed, .credential_replaced, .credential_rejected, .failed => {
            std.debug.assert(self.pending_turn_result == null);
            self.pending_turn_result = result;
            self.enqueuePendingTurnFence();
        },
        // The channel closed under the worker. End the turn on its receipt like
        // any normal terminal, but with no event. A dead channel is teardown,
        // not a failure worth a report or a cancellation to restore from.
        .closed => {
            defer self.freeWorkerResult(&result);
            try self.session.endTurnWithReceipt(&result.outcome.receipt);
        },
    }
}

/// After the join of a canceled worker, consume its queued progress and preserve
/// all non-turn events as a prefix for the normal loop. When history committed
/// nothing, progress needs only deinitialization because the transcript rewinds
/// to the turn base. Returns the first application error after it owns and frees
/// every event, so the caller can finish cancellation before the error propagates.
fn drainCanceledProgress(self: *App, apply_progress: bool) ?anyerror {
    // A second cancellation can occur inside the same buffered key event after a
    // first drain has created this prefix. Leave newer queue data in place until
    // the loop consumes the prefix rather than exceed its bounded storage.
    if (self.deferred_event_count > 0) return null;

    var batch: [queue_capacity]Session.UiEvent = undefined;
    const count = self.queue.get(self.io, &batch, 0) catch return null;
    std.debug.assert(self.deferred_event_count + count <= self.deferred_events.len);

    var maybe_error: ?anyerror = null;
    for (batch[0..count]) |*event| switch (event.*) {
        .turn => |*turn_event| {
            if (apply_progress and maybe_error == null) {
                self.session.applyCanceledTurnEvent(turn_event) catch |err| {
                    maybe_error = err;
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
    return maybe_error;
}

/// Ctrl+C: clear the editor, or quit when pressed twice inside the window.
/// Measured on the monotonic clock. A wall-clock step must not fake or break
/// the double press.
fn clearOrQuit(self: *App) void {
    const now = self.nowMs();
    if (now - self.ctrl_c_ms_last < ctrl_c_window_ms) {
        self.running = false;
    } else {
        self.session.editor.clear();
        self.ctrl_c_ms_last = now;
    }
}

/// Repaint: read the terminal size (keep the last known one if the query fails),
/// then hand it to the session's projection. The size read here is the source of
/// truth every frame. A `.resize` event just forces the frame so an idle
/// interface reflows too.
fn refresh(self: *App) !void {
    const size: terminal.View.Size = if (self.tty.size()) |window|
        .{ .columns = window.columns, .rows = window.rows }
    else
        .{ .columns = self.session.columns, .rows = self.session.rows };
    try self.tty.setAlternateScreen(self.session.mode == .viewing);
    try self.session.paint(size);
}

/// Milliseconds on the monotonic clock, for the double Ctrl+C window.
fn nowMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

/// Nanoseconds on the monotonic clock, for frame scheduling.
fn nowNs(self: *App) i96 {
    return std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
}

/// Enter while idle: run a command line locally, or start a turn over the prompt.
/// A command line holds its name alone, so a message that starts with a word like
/// `/new` still reaches the model.
fn submit(self: *App) !void {
    if (self.session.editor.blank()) {
        self.session.cancelCacheConfirmation();
        return;
    }
    const maybe_cache_risk = self.agent.cacheRisk();
    if (maybe_cache_risk) |*cache_risk| return self.submitWithCacheRisk(cache_risk);
    return self.submitWithCacheRisk(null);
}

/// Submit with an injected cache risk. The seam lets tests stop at the warning
/// without starting a real provider worker.
fn submitWithCacheRisk(self: *App, maybe_cache_risk: ?*const ai.Agent.CacheRisk) !void {
    const text = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(text);
    self.session.dirty = true;

    if (try self.dispatchCommand(text)) |outcome| {
        // A skill line starts its own turn, so it keeps the editor's rich draft.
        // Every other command clears the editor first.
        if (outcome == .prompt) {
            const prompt = outcome.prompt;
            defer prompt.deinit(self.gpa);
            if (!self.signedIn()) {
                self.session.cancelCacheConfirmation();
                self.session.editor.clear();
                try self.reportNotice(
                    .failure,
                    "Sign in with /login before you send a message.",
                    .{},
                );
            } else if (try self.preflightModelSubmit(maybe_cache_risk)) {
                const base = try self.startSkillTurn(&prompt);
                var draft = self.session.editor.detachTrimmed();
                self.session.retainTurnPrompt(&draft, base);
            }
        } else {
            self.session.cancelCacheConfirmation();
            self.session.editor.clear();
            try self.applyOutcome(outcome);
        }
    } else if (!self.signedIn()) {
        self.session.cancelCacheConfirmation();
        self.session.editor.clear();
        try self.reportNotice(
            .failure,
            "Sign in with /login before you send a message.",
            .{},
        );
    } else if (try self.preflightModelSubmit(maybe_cache_risk)) {
        const base = try self.startUserTurn(text);
        // The turn is live and owns its own copy. Retain the prompt's rich draft
        // so an abnormal exit that commits nothing can return it. Leave the
        // editor empty for in-progress text. Both steps are infallible, so the
        // rollback above stays correct.
        var prompt = self.session.editor.detachTrimmed();
        self.session.retainTurnPrompt(&prompt, base);
    }
}

/// Stop the first stale-cache submission and arm one confirmation for the
/// unchanged prompt.
fn preflightModelSubmit(
    self: *App,
    maybe_cache_risk: ?*const ai.Agent.CacheRisk,
) !bool {
    if (self.session.takeCacheConfirmation()) return true;
    const cache_risk = maybe_cache_risk orelse return true;
    const hour_ms: u64 = std.time.ms_per_hour;
    const minute_ms: u64 = std.time.ms_per_min;
    const retention: struct { count: u64, unit: []const u8 } =
        if (cache_risk.retention_ms % hour_ms == 0)
            .{ .count = @divExact(cache_risk.retention_ms, hour_ms), .unit = "h" }
        else if (cache_risk.retention_ms % minute_ms == 0)
            .{ .count = @divExact(cache_risk.retention_ms, minute_ms), .unit = "m" }
        else
            .{
                .count = @divFloor(cache_risk.retention_ms, std.time.ms_per_s),
                .unit = "s",
            };

    if (cache_risk.cost_extra >= 0.01) {
        try self.reportNotice(
            .warning,
            "Enter: Send anyway · Cache: Probably stale after {d}{s} · " ++
                "Extra input cost: ~${d:.2}",
            .{ retention.count, retention.unit, cache_risk.cost_extra },
        );
    } else {
        try self.reportNotice(
            .warning,
            "Enter: Send anyway · Cache: Probably stale after {d}{s} · " ++
                "Extra input cost: ~${d:.4}",
            .{ retention.count, retention.unit, cache_risk.cost_extra },
        );
    }
    self.session.armCacheConfirmation();
    return false;
}

/// Record a compact skill marker and its optional user task, then spawn the turn
/// over the expanded skill content. Returns the rich draft's rewind checkpoint.
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
    try self.session.transcript.append(.skill, false, prompt.name);
    if (prompt.arguments.len > 0)
        try self.session.transcript.append(.user, false, prompt.arguments);
    return base;
}

/// Record a plain user message and spawn its turn. Returns the rich draft's
/// rewind checkpoint.
fn startUserTurn(self: *App, text: []const u8) !usize {
    const base = self.session.transcript.blocks().len;
    try self.session.transcript.append(.user, false, text);
    errdefer self.session.transcript.truncate(base);
    try self.runTurn(text);
    self.session.dirty = true;
    return base;
}

/// Spawn a turn worker over `text` and enter turn mode. The worker owns its own
/// copy of the prompt. Only commit to turn mode once the spawn succeeds.
fn runTurn(self: *App, text: []const u8) !void {
    // A turn returns to prompt mode only after its terminal wakeup consumes the
    // worker result, so a successor can never overwrite terminal ownership.
    std.debug.assert(self.turn_future == null);
    std.debug.assert(self.pending_turn_result == null);
    // The user can check out another branch between two turns, so the label is
    // true at the moment the turn starts.
    self.refreshBranch();
    const generation = try self.reserveTurnGeneration();
    const owned = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(owned);
    self.turn_future = try self.io.concurrent(runTurnWorker, .{ self, owned, generation });
    self.session.beginTurn(generation);
}

/// Permanently reserve the next turn generation before a worker can observe it.
/// A failed allocation or spawn can leave a gap, but the app never reuses a generation.
fn reserveTurnGeneration(self: *App) !u64 {
    if (self.turn_generation == std.math.maxInt(u64)) return error.TurnGenerationExhausted;
    self.turn_generation += 1;
    return self.turn_generation;
}

/// Run `line` as a command. Null reports that the line is a message.
fn dispatchCommand(self: *App, line: []const u8) !?ai.command.Outcome {
    var context: ai.command.Context = .{
        .gpa = self.gpa,
        .io = self.io,
        .agent = &self.agent,
        .accounts = &self.accounts,
        .skill_registry = &self.skills,
    };
    return ai.command.run(&context, line);
}

/// Handle a slash command locally and apply its outcome. Every caller passes a
/// literal command line, so dispatch always returns an outcome.
fn runCommand(self: *App, line: []const u8) !void {
    if (try self.dispatchCommand(line)) |outcome| try self.applyOutcome(outcome);
}

/// Apply a command outcome: prompt, account, and conversation actions need the
/// app or agent. Presentation-only outcomes go to the session.
fn applyOutcome(self: *App, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .show_system_prompt => try self.session.openPage(&.{ .content = self.prompt }),
        .show_colors => try self.session.openPage(&.{
            .content = "",
            .presentation = .colors,
        }),
        .new_conversation => {
            self.agent.resetConversation();
            self.session.resetConversation();
        },
        // Only `submit` produces a prompt outcome (from a typed `/skill:` line),
        // and it starts that turn itself, so a prompt never reaches this shared
        // path. A prompt routed here skips the editor's rich draft.
        .prompt => unreachable,
        .login => |account| try self.loginAccount(account),
        .logout => |account| try self.logoutAccount(account),
        .switch_account => |account| {
            self.adopt(account);
            try self.recordEvent(
                .information,
                "Pith now uses {s} with {s}.",
                .{ self.agent.model.name, account.label() },
            );
        },
        else => try self.session.applyOutcome(outcome),
    }
    // Commands can switch or drop the active account. Mirror the authoritative
    // agent snapshot so an allowance cleared by that transition disappears at
    // the same time as the account changes.
    try self.mirrorAgentState();
}

/// Mirror the agent configuration into the session and the project state.
fn mirrorAgentState(self: *App) !void {
    self.session.stats_shown = self.agent.stats;
    self.session.model_shown = self.agent.model;
    self.session.effort_shown = self.agent.effort;
    self.session.account_shown = self.activeAccount();
    try self.recordState();
}

/// Remember the account, model, and effort level this project now uses, so the
/// next start resumes on them. The model stays with the account that ran it, so
/// a switch away keeps it. Only a change writes the file. A failed write never
/// stops the session, because this state is a convenience. A persistent failure
/// stops later saves, so its report lands once and names the way out.
///
/// A signed-out session records nothing, because the entry names an account.
/// This drops no user choice: `/model` and `/effort` both refuse while no
/// account is active, so the only signed-out change is the sign-in itself.
fn recordState(self: *App) !void {
    const account = self.activeAccount() orelse return;
    self.state.record(account, &self.agent.model, self.agent.effort) catch |err| switch (err) {
        error.StoreBusy => try self.recordEvent(
            .failure,
            "Pith could not save the choices of this project because another Pith instance " ++
                "is writing the state file. Pith tries again at the next save.",
            .{},
        ),
        error.CorruptStore => try self.recordEvent(
            .failure,
            "Pith stopped saving the choices of this project because Pith cannot read the " ++
                "file {s} as a JSON object. Delete that file to let the next start save again.",
            .{self.state.path},
        ),
        else => try self.recordEvent(
            .failure,
            "Pith stopped saving the choices of this project to {s} because of error {s}.",
            .{ self.state.path, @errorName(err) },
        ),
    };
}

/// Log in to `account`, then switch to it on the model it ran last here, else on
/// its default model.
/// A pre-commit failure leaves the current account untouched. After the
/// credential replacement, account readiness and replay invalidation complete
/// before any fallible final presentation.
fn loginAccount(self: *App, account: ai.llm.Account) !void {
    self.tty.leaveRaw();
    defer {
        self.tty.enterRaw() catch {};
        self.session.view.invalidate();
        self.session.dirty = true;
    }
    var prompt: OauthPrompt = .{ .writer = self.tty.writer() };
    const login = self.accounts.login(account, &prompt) catch |login_error|
        return self.reportLoginFailure(login_error);

    // A fresh login can represent another principal in the same account slot.
    // Nothing that principal produced crosses that boundary.
    self.agent.dropAccountEvidence(account);
    self.adopt(account);
    switch (login) {
        .saved => |path| try prompt.showAuthorized(path),
        .memory_only => |failure| try prompt.showSaveFailed(
            failure.path,
            @errorName(failure.save_error),
        ),
    }
    try self.recordEvent(
        .information,
        "Pith signed in to {s} and selected {s}.",
        .{ account.label(), self.agent.model.name },
    );
    switch (login) {
        .saved => {},
        .memory_only => |failure| try self.recordEvent(
            .failure,
            "Pith could not save the credentials for {s} to {s} because of error {s}. " ++
                "The sign-in stays active until Pith exits.",
            .{ account.label(), failure.path, @errorName(failure.save_error) },
        ),
    }
}

fn reportLoginFailure(self: *App, login_error: anyerror) !void {
    const message = switch (login_error) {
        error.Canceled => return error.Canceled,
        error.CallbackTimeout => "Pith stopped the sign-in because the browser did not " ++
            "respond in time.",
        error.CallbackRequestTooLarge => "Pith could not sign in because the browser " ++
            "response was too large.",
        error.CallbackTimeoutUnavailable => "Pith could not sign in because it could not " ++
            "set a browser time limit.",
        // The exchange rejects an authorization that expired or was used before.
        error.TokenGrantRejected => "The provider rejected the authorization. " ++
            "Start the sign-in again.",
        error.TokenServiceUnavailable => "The provider credential service is not available. " ++
            "Try the sign-in again later.",
        else => return self.reportNotice(
            .failure,
            "Pith could not sign in because of error {s}.",
            .{@errorName(login_error)},
        ),
    };
    return self.reportNotice(.failure, "{s}", .{message});
}

/// Accept a credential that the store identifies as another principal. The
/// worker stopped before its model request, so drop old evidence and metadata
/// before this credential can run the restored turn.
fn acceptCredentialReplacement(self: *App, account: ai.llm.Account) !void {
    self.accounts.dropPrincipalMetadata(account);
    self.agent.dropAccountEvidence(account);
    self.adopt(account);
    try self.mirrorAgentState();
}

/// Resolve a rejected refresh credential. Reload a replacement from another
/// instance. Otherwise, leave the account and select the next account.
///
/// Both paths replace the credential of `account`, and a replacement another
/// instance saved can represent another principal in the same account slot.
/// Nothing that principal produced crosses that boundary, so the evidence goes
/// before the two paths divide.
fn rejectCredential(self: *App, account: ai.llm.Account) !void {
    var maybe_removal_error: ?anyerror = null;
    const recovered = self.accounts.invalidate(account) catch |err| failure: {
        maybe_removal_error = err;
        break :failure false;
    };
    self.agent.dropAccountEvidence(account);
    if (recovered) {
        // `invalidate` dropped the limits the replaced credential discovered, so
        // the model resolves again before the session shows it.
        self.adopt(account);
        try self.recordEvent(
            .information,
            "Pith reloaded the refresh credential that another Pith instance saved. " ++
                "Try the turn again.",
            .{},
        );
        return self.mirrorAgentState();
    }

    const maybe_next = self.accounts.firstAuthenticated();
    if (maybe_next) |next| self.adopt(next) else self.agent.signOut();

    if (maybe_removal_error) |removal_error| try self.recordEvent(
        .failure,
        "Pith could not remove the rejected credential for {s} because of error {s}.",
        .{ account.label(), @errorName(removal_error) },
    );
    if (maybe_next) |next| {
        try self.recordEvent(
            .information,
            "Pith signed out of {s}. Pith now uses {s} with {s}.",
            .{ account.label(), self.agent.model.name, next.label() },
        );
    } else {
        try self.recordEvent(
            .information,
            "Pith signed out of {s}. Select an account to sign in.",
            .{account.label()},
        );
        try self.openLoginPicker();
    }
    try self.mirrorAgentState();
}

/// Open the login picker without routing its outcome back through the app.
fn openLoginPicker(self: *App) !void {
    var context: ai.command.Context = .{
        .gpa = self.gpa,
        .io = self.io,
        .agent = &self.agent,
        .accounts = &self.accounts,
    };
    if (try ai.command.run(&context, "/login")) |outcome|
        try self.session.applyOutcome(outcome);
}

/// Drop `account`'s credentials. A logout of the active account hands the
/// session to the next authenticated account. That account starts on the model
/// it ran last here, else on its default model. When none remains, it drops to a
/// signed-out state and opens the login picker so the user chooses how to sign
/// back in. Commands cannot run mid-turn, so this never races a turn.
fn logoutAccount(self: *App, account: ai.llm.Account) !void {
    const was_active = if (self.agent.client) |client| client.account() == account else false;
    self.accounts.logout(account) catch |err| {
        return self.reportNotice(
            .failure,
            "Pith could not sign out because of error {s}.",
            .{@errorName(err)},
        );
    };
    self.agent.dropAccountEvidence(account);
    if (!was_active)
        return self.recordEvent(.information, "Pith signed out of {s}.", .{account.label()});
    if (self.accounts.firstAuthenticated()) |next| {
        self.adopt(next);
        return self.recordEvent(
            .information,
            "Pith signed out of {s}. Pith now uses {s} with {s}.",
            .{ account.label(), self.agent.model.name, next.label() },
        );
    }
    // No account remains: sign out and let the user choose from the login picker
    // (no forced browser, no loop).
    self.agent.signOut();
    try self.recordEvent(
        .information,
        "Pith signed out of {s}. Select an account to sign in.",
        .{account.label()},
    );
    // Route through the session. A route through `applyOutcome` cycles the
    // inferred error sets from `logoutAccount` back to itself.
    try self.openLoginPicker();
}

/// Switch the agent to `account` on the model that account ran last, else on its
/// default model. The client is present because the caller just authenticated the
/// account or read it from the registry.
fn adopt(self: *App, account: ai.llm.Account) void {
    self.agent.switchTo(self.accounts.client(account).?, self.accountModel(account));
}

/// Replace the bottom footer with one transient notice.
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

/// Report one count line for the guidance that pith holds, then what each source
/// skipped. The counts keep the startup report short, because a normal load has
/// nothing the user must act on. `/system` shows the path of every counted file.
/// A count of zero stays out of the line, so a run with no guidance and no
/// skipped file reports nothing.
fn reportSources(self: *App, sources: *const Sources) !void {
    var line: std.Io.Writer.Allocating = .init(self.gpa);
    defer line.deinit();
    const user_count = sources.user_instructions.files().len;
    const project_count = sources.project_instructions.files().len;
    if (user_count > 0 or project_count > 0) {
        try line.writer.writeAll("Pith loaded");
        if (user_count > 0) try line.writer.print(
            " {d} user instruction file{s}",
            .{ user_count, pluralSuffix(user_count) },
        );
        if (user_count > 0 and project_count > 0) try line.writer.writeAll(" and");
        if (project_count > 0) try line.writer.print(
            " {d} project instruction file{s}",
            .{ project_count, pluralSuffix(project_count) },
        );
        try line.writer.writeByte('.');
    }
    // The catalog counts the skills the model can see, which is what `/system`
    // shows. Pith only finds a skill here and advertises its name and its
    // description. The instructions stay on disk until the skill runs.
    const skill_count = sources.skills.catalog().count();
    if (skill_count > 0) {
        if (line.written().len > 0) try line.writer.writeByte(' ');
        try line.writer.print(
            "Pith found {d} skill{s}.",
            .{ skill_count, pluralSuffix(skill_count) },
        );
    }
    if (line.written().len > 0) try self.recordEvent(.information, "{s}", .{line.written()});
    try self.reportNotices(sources.user_instructions.notices());
    try self.reportNotices(sources.project_instructions.notices());
    try self.reportNotices(sources.skills.notices());
}

/// The English plural suffix that agrees with `count`.
fn pluralSuffix(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

/// Report the startup messages of one instruction source. The instruction files
/// and the skill files both report through here. An empty file is housekeeping,
/// so its message reads as information rather than as a failure.
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

/// Record one durable event in the transcript.
fn recordEvent(
    self: *App,
    severity: ai.command.Outcome.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    try self.session.applyOutcome(
        try ai.command.Outcome.reportEvent(self.gpa, severity, format, args),
    );
}

/// Keys on a full-window page. Esc is the documented way out. Ctrl+C and Ctrl+D
/// close it too, so an exit attempt always works in a terminal that drops the Esc
/// report. A page is read-only, so no key on it quits pith.
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
    const picker = &self.session.mode.picking.picker;
    switch (event.*) {
        .up => try picker.moveUp(),
        .down => try picker.moveDown(),
        .enter => return self.confirmPicker(),
        .escape => return self.session.cancelPicker(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => return self.session.cancelPicker(),
            else => return,
        },
        else => return,
    }
    self.session.dirty = true;
}

/// Apply the highlighted picker row: the command that opened the picker runs its
/// own handler over the selected row.
fn confirmPicker(self: *App) !void {
    const picking = &self.session.mode.picking;
    const cursor = picking.picker.cursor;
    var context: ai.command.Context = .{
        .gpa = self.gpa,
        .io = self.io,
        .agent = &self.agent,
        .accounts = &self.accounts,
        .skill_registry = &self.skills,
    };
    const outcome = try picking.select(&context, cursor);
    self.session.closePicker();
    try self.applyOutcome(outcome);
}

test "OAuth prompts render runtime fields as inert text" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var prompt: OauthPrompt = .{ .writer = &out.writer };

    try prompt.showAuthorization("https://example.test/\x1b]52;c;b3duZWQ=\x07");
    try prompt.showBrowserLaunchFailed();
    try prompt.showAuthorized("/home/\x1b[2J/.pith/auth.json");
    try prompt.showSaveFailed("/home/\x1b[2J/.pith/auth.json", "AccessDenied");

    const written = out.written();
    const url_inert = "https://example.test/\u{200B}�\u{200B}]52;c;b3duZWQ=\u{200B}�\u{200B}";
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]52;c;b3duZWQ=\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, url_inert) != null);
    const path_inert = "/home/\u{200B}�\u{200B}[2J/.pith/auth.json";
    try std.testing.expect(std.mem.indexOf(u8, written, path_inert) != null);
}

test "a turn failure the agent named itself reads as a sentence, not an error name" {
    // A refusal or an unrecognized provider outcome is ordinary model behavior:
    // Pith must not show the user a bare Zig error name for it.
    for ([_]anyerror{
        error.UnsupportedReply,
        error.EmptyReply,
        error.IncompleteReply,
        error.TooManyToolRounds,
        error.CredentialReplaced,
        error.TokenGrantRejected,
        error.TokenRequestFailed,
        error.TokenServiceUnavailable,
        error.StoreBusy,
    }) |err| {
        const text = turnFailureText(err).?;
        try std.testing.expect(std.mem.indexOf(u8, text, " ") != null);
        try std.testing.expect(!std.mem.eql(u8, text, @errorName(err)));
    }
    // A credential the turn can still use names the retry, not a sign-in.
    for ([_]anyerror{
        error.CredentialReplaced,
        error.TokenServiceUnavailable,
        error.StoreBusy,
    }) |err| {
        const text = turnFailureText(err).?;
        try std.testing.expect(std.mem.indexOf(u8, text, "Try the turn again.") != null);
    }
    // A rejected credential leaves the account resolution to the app.
    const credentials = turnFailureText(error.TokenGrantRejected).?;
    try std.testing.expect(std.mem.indexOf(u8, credentials, "signed out") == null);
    try std.testing.expect(std.mem.indexOf(u8, credentials, "/login") == null);
    // An unmapped failure returns null, and the caller wraps its error name.
    try std.testing.expectEqual(null, turnFailureText(error.SignedOut));
}

test "a grant rejection refuses an account without a refresh credential" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const client = ai.provider.Client.init(gpa, io, .{ .anthropic_api = "key" }, .{});
    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, client, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_api;
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
    try std.testing.expectEqual(ai.llm.Account.anthropic_api, app.activeAccount().?);
}

test "OAuth login cancellation escapes without a failure notice" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const block_count = app.session.transcript.blocks().len;
    try std.testing.expectError(error.Canceled, app.reportLoginFailure(error.Canceled));
    try std.testing.expectEqual(block_count, app.session.transcript.blocks().len);
}

test "a login the provider refused reads as a sentence, not an error name" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    // A rejection names the one action that helps. An unavailable service does
    // not, because the same sign-in works later.
    try app.reportLoginFailure(error.TokenGrantRejected);
    try std.testing.expectEqualStrings(
        "The provider rejected the authorization. Start the sign-in again.",
        app.session.notice.?.content,
    );
    try app.reportLoginFailure(error.TokenServiceUnavailable);
    try std.testing.expectEqualStrings(
        "The provider credential service is not available. Try the sign-in again later.",
        app.session.notice.?.content,
    );
    // A failure with no single cause still wraps its error name in a sentence.
    try app.reportLoginFailure(error.TokenRequestFailed);
    try std.testing.expectEqualStrings(
        "Pith could not sign in because of error TokenRequestFailed.",
        app.session.notice.?.content,
    );
}

test "OAuth callback bounds have friendly failure notices" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const cases = [_]struct { anyerror, []const u8 }{
        .{
            error.CallbackTimeout,
            "Pith stopped the sign-in because the browser did not respond in time.",
        },
        .{
            error.CallbackRequestTooLarge,
            "Pith could not sign in because the browser response was too large.",
        },
        .{
            error.CallbackTimeoutUnavailable,
            "Pith could not sign in because it could not set a browser time limit.",
        },
    };
    for (cases) |case| {
        const failure, const message = case;
        try app.reportLoginFailure(failure);
        const notice = app.session.notice.?;
        try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
        try std.testing.expectEqualStrings(message, notice.content);
        try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    }
}

test "turn producers keep their captured generation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const generation: u64 = 42;

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
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
        try handler.onToolResult("read", "result", summary, false);
    }
    try handler.onUsage(.{});
    try handler.onStreamReset();
    try handler.onSteering("steer", 1);
    // Signed out, so the turn fails at once. The wakeup is payload-free and the
    // joined result owns the error text.
    const result = runTurnWorker(&app, try gpa.dupe(u8, "prompt"), generation);
    defer app.freeWorkerResult(&result);
    try std.testing.expectEqual(generation, result.generation);
    try std.testing.expect(result.terminal_queued);
    try std.testing.expectEqualStrings(
        "Pith could not complete the turn because of error SignedOut.",
        result.error_text.?,
    );

    var events: [8]Session.UiEvent = undefined;
    const count = try app.queue.get(io, &events, events.len);
    defer for (events[0..count]) |event| event.deinit(gpa);
    try std.testing.expectEqual(events.len, count);
    for (events[0..count]) |event| switch (event) {
        .turn => |turn_event| try std.testing.expectEqual(generation, turn_event.generation),
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(@as(u64, 2), events[2].turn.progress_sequence_committed);
    const tool_result = events[3].turn.payload.tool_result;
    try std.testing.expectEqualStrings("summary", tool_result.summary.?);
    try std.testing.expectEqual(@as(u64, 4), events[4].turn.progress_sequence_committed);
    try std.testing.expect(events[events.len - 1].turn.payload == .turn_ended);
}

// Queue a plain-text (atom-free) steering draft directly on the mirror, a stand-in
// for a message the worker already folded (so the channel no longer holds it).
// Built through the real editor detach path the app uses.
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

// A fake turn worker that returns a fixed result immediately, so a cancel test
// drives the disposition-driven resolution without a real agent run.
fn fakeWorker(result: *const WorkerResult) WorkerResult {
    return result.*;
}

fn canceledWorker() WorkerResult {
    return .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .canceled },
        .error_text = null,
    };
}

// A canceled worker whose turn committed a round, so the cancel path keeps the
// committed transcript, shows the `canceled` line, and drops no returned prompt.
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

// Spawn a fake canceled worker (nothing committed) as the active turn, so the
// cancel path restores every rich steering draft. Reaped by `cancelTurn`.
fn spawnCanceledTurn(app: *App) !void {
    app.turn_future = try app.io.concurrent(canceledWorker, .{});
}

// Spawn a canceled worker whose turn committed a round, so the cancel path keeps
// the committed transcript and shows the `canceled` line. Reaped by `cancelTurn`.
fn spawnCommittedCanceledTurn(app: *App) !void {
    app.turn_future = try app.io.concurrent(committedCanceledWorker, .{});
}

test "a failed late-steering turn start restores queue, mirror, and transcript" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.turn_generation = std.math.maxInt(u64);
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const payload = "late\n" ** 15;
    const delivered = std.mem.trim(u8, payload, " \t\r\n");
    try app.agent.steering.push(delivered);
    try app.session.editor.paste(payload, true);
    try app.session.reserveSteering();
    var draft = app.session.editor.detachTrimmed();
    app.session.commitSteeringDraft(&draft);

    try std.testing.expectError(error.TurnGenerationExhausted, app.startSteeringTurn());
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.session.hasSteering());
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items[0].atoms.items.len);
    const rich = try app.session.steering.items[0].expanded(gpa, .none);
    defer gpa.free(rich);
    try std.testing.expectEqualStrings(payload, rich);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);

    const restored = try app.agent.steering.take();
    defer {
        for (restored) |message| gpa.free(message);
        gpa.free(restored);
    }
    try std.testing.expectEqual(@as(usize, 1), restored.len);
    try std.testing.expectEqualStrings(delivered, restored[0]);
}

test "canceling a promoted steering turn restores its rich paste draft" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.turn_generation = 0;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const payload = "late\n" ** 15;
    const delivered = std.mem.trim(u8, payload, " \t\r\n");
    try app.agent.steering.push(delivered);
    try app.session.editor.paste(payload, true);
    try app.session.reserveSteering();
    var draft = app.session.editor.detachTrimmed();
    app.session.commitSteeringDraft(&draft);

    try app.startSteeringTurn();
    try std.testing.expectEqual(@as(usize, 1), app.session.turn_origin.?.prompt.atoms.items.len);

    // Replace the signed-out production worker with a deterministic canceled
    // result. Keep the live turn and its origin under test.
    if (app.cancelTurnFuture()) |result| app.freeWorkerResult(&result);
    app.drainQueue();
    try spawnCanceledTurn(&app);
    try app.cancelTurn();

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const restored = try app.session.editor.expanded(.none);
    defer gpa.free(restored);
    try std.testing.expectEqualStrings(payload, restored);
}

test "ctrl+c during a turn clears the draft first and cancels only on an empty editor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.turn_generation = 0;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);
    try spawnCanceledTurn(&app);

    // A draft is steering the user still writes. The first press takes the text
    // alone, so the turn keeps running.
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
    app.gpa = gpa;
    app.io = io;
    app.running = true;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.turn_generation = 0;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    // A cancel backs out of the turn alone: the draft stays, and pith runs on. So
    // neither key needs the empty-editor guard the quit has at the prompt.
    for ([_]terminal.Input.Key{ .escape, .{ .ctrl = 'd' } }) |key| {
        app.session.beginTurn(1);
        try spawnCanceledTurn(&app);
        app.session.editor.clear();
        try app.session.editor.insert("keep the draft");

        try app.handleKey(&key);
        try std.testing.expect(app.session.mode == .prompt);
        try std.testing.expect(app.turn_future == null);
        try std.testing.expectEqualStrings("keep the draft", app.session.editor.visible());
        try std.testing.expect(app.running);
    }
}

test "canceling a turn joins and clears its active worker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
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
    while (!started.load(.acquire) and poll < 1000) : (poll += 1)
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    try std.testing.expect(started.load(.acquire));

    try app.cancelTurn();
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(stopped.load(.acquire));
    try std.testing.expect(app.session.mode == .prompt);
}

// The race a cancel must survive: the worker folded a pasted message (channel
// entry taken, `.steering_consumed` still queued, so only the mirror holds it)
// while a newer message is pending in both. Everything returns to the editor
// exactly once, and the queued usage comes again from the joined agent.
test "canceling a turn restores in-flight steering and reads the usage again" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
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
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
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
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.initEventQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    // A committed cancel appends the `canceled` event. Force the OOM there
    // and confirm the steering is already restored, not lost to the failure.
    try app.session.editor.insert("restore me");
    try app.submitSteering();
    try spawnCommittedCanceledTurn(&app);
    try app.session.editor.reserveDrafts(app.session.steering.items);
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

test "ctrl+p recalls the steering queue after in-progress editor text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("fix it");
    try app.submitSteering();
    try app.session.editor.insert("and test");
    try app.submitSteering();
    try app.session.editor.insert("draft");

    // Through the key binding, so the turn-mode route to the pull stays covered.
    try app.handleKey(&.{ .ctrl = 'p' });
    try std.testing.expectEqualStrings("draft\n\nfix it\n\nand test", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
}

test "ctrl+p restores a steered paste as a live placeholder atom" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const payload = "line\n" ** 15; // 16 logical lines: collapses to a marker
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

// Cancel restores a worker-owned paste whose consumed event is still pending.
// A later stale event cannot remove the restored atom, and payload-edge
// whitespace survives because the draft is only literal-edge trimmed.
test "cancel restores an in-flight steered paste as a live placeholder atom" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
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
    // A stale consumed event after the turn ended dies at the generation
    // gate and cannot disturb the restored atom.
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

// A consumed event retains the rich draft, so a rolled-back batch is recoverable
// even after the event has applied.
test "cancel restores a steered paste even after its consumed event applied" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
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

    // The consumed event hides the row but retains the rich draft.
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);

    try spawnCanceledTurn(&app);
    try app.cancelTurn();
    // Nothing committed, so the uncommitted-consumed batch's rich draft returns
    // to the editor intact and its optimistic transcript block disappears.
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

// Ctrl+P recalls only the pending suffix. The already folded prefix stays rich
// but hidden until its consumed event applies or failed delivery requeues it.
test "ctrl+p recalls the pending suffix and retains the in-flight prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    // "folded": the worker took it, so only the mirror holds it (in-flight prefix).
    try seedSteering(&app, "folded");
    // "pending": still queued in both the channel and the mirror.
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
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
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

// A worker that completed before cancellation shows as its completion,
// but only after the terminal fence has preserved all earlier queue progress.
test "a cancel that loses the race waits for the terminal fence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(7);

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

    const events = [_]Session.UiEvent{.{ .turn = .{
        .generation = 7,
        .payload = endedPayload(),
    } }};
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.pending_turn_result == null);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "cancel does not commit stale text across a reset held in the current batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.input = terminal.Input.init(gpa);
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

    const events = [_]Session.UiEvent{
        .{ .keys = try gpa.dupe(u8, "\x03") },
        .{ .turn = .{
            .generation = 1,
            .progress_sequence = 2,
            .payload = .stream_reset,
        } },
    };
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .prompt);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("You canceled the turn.", blocks[0].event.text.items);
}

// Cancellation can join a worker before the consumer reaches progress that the
// worker queued ahead of its terminal fence. The joined result waits at the App
// boundary so the whole prefix applies once before the turn ends.
test "cancel preserves progress before a queued terminal fence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.input = terminal.Input.init(gpa);
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

    const events = [_]Session.UiEvent{
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
    try std.testing.expectEqualStrings("answer", blocks[0].model.items);
    try std.testing.expectEqualStrings("folded", blocks[1].user.items);
}

// The same ordering holds when cancellation interrupts the worker's terminal
// enqueue: the consumer appends a replacement fence behind the queued prefix.
test "cancel replaces an interrupted terminal fence after queued progress" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.input = terminal.Input.init(gpa);
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

    const events = [_]Session.UiEvent{
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
    try std.testing.expectEqualStrings("answer", prefix[0].model.items);
    try std.testing.expectEqualStrings("folded", prefix[1].user.items);

    var fence: [1]Session.UiEvent = undefined;
    const count = try app.queue.get(io, &fence, 1);
    try std.testing.expectEqual(fence.len, count);
    try std.testing.expect(!try app.applyBatch(fence[0..count]));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.pending_turn_result == null);
    try std.testing.expectEqual(@as(usize, 2), app.session.transcript.blocks().len);
}

// A full queue cannot deadlock the consumer while it inserts a replacement. The
// pending result remains live until a later drain opens one slot behind the
// already-buffered prefix.
test "an interrupted terminal fence retries after a full queue drain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.input = terminal.Input.init(gpa);
    defer app.input.deinit();
    app.session.beginTurn(13);

    const filler = [_]Session.UiEvent{.resize} ** queue_capacity;
    try app.queue.putAll(io, &filler);
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .completed },
        .error_text = null,
        .generation = 13,
        .terminal_queued = false,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    const events = [_]Session.UiEvent{
        .{ .keys = try gpa.dupe(u8, "\x03") },
        .{ .turn = .{
            .generation = 13,
            .payload = .{ .text = try gpa.dupe(u8, "answer") },
        } },
    };
    try std.testing.expect(!try app.applyBatch(&events));
    try std.testing.expect(!app.pending_turn_result.?.terminal_queued);
    try std.testing.expect(app.session.mode == .turn);

    var first: [1]Session.UiEvent = undefined;
    const first_count = try app.queue.get(io, &first, first.len);
    try std.testing.expectEqual(first.len, first_count);
    app.enqueuePendingTurnFence();
    try std.testing.expect(app.pending_turn_result.?.terminal_queued);
    try std.testing.expect(!try app.applyBatch(first[0..first_count]));

    var rest: [queue_capacity]Session.UiEvent = undefined;
    const rest_count = try app.queue.get(io, &rest, rest.len);
    try std.testing.expectEqual(rest.len, rest_count);
    try std.testing.expect(!try app.applyBatch(rest[0..rest_count]));

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.pending_turn_result == null);
    try std.testing.expectEqualStrings("answer", app.session.transcript.blocks()[0].model.items);
}

// A cancel that loses to a failed worker applies the authoritative joined
// result and frees its error text once.
test "a cancel that loses the race applies the failed joined result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(3);
    try app.session.transcript.append(.user, false, "prompt");
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

    var events: [1]Session.UiEvent = undefined;
    const count = try app.queue.get(io, &events, 1);
    try std.testing.expectEqual(events.len, count);
    try std.testing.expect(!try app.applyBatch(events[0..count]));

    // The joined failure rewinds the optimistic prompt, restores all authored
    // text, and clears the agent's plain steering copy before the turn ends.
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
    try std.testing.expectEqualStrings("boom", blocks[0].event.text.items);
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "boom") != null);
}

test "a joined completion starts older steering before a newer prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.turn_generation = 3;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(3);

    try app.agent.steering.push("older");
    try seedSteering(&app, "older");
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .completed },
        .error_text = null,
        .generation = 3,
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});
    defer if (app.turn_future) |*future| {
        const result = future.cancel(io);
        app.freeWorkerResult(&result);
    };
    try app.cancelTurn();
    try std.testing.expect(app.session.mode == .turn);

    var events: [1]Session.UiEvent = undefined;
    const count = try app.queue.get(io, &events, 1);
    try std.testing.expectEqual(events.len, count);
    try std.testing.expect(!try app.applyBatch(events[0..count]));

    // The replacement terminal fence starts pending steering before the
    // consumer can take a newer queue event.
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    switch (app.session.transcript.blocks()[0]) {
        .user => |text| try std.testing.expectEqualStrings("older", text.items),
        else => return error.UnexpectedTranscriptBlock,
    }
    try std.testing.expect(!app.session.hasSteering());
}

// Shutdown is teardown, not an interactive cancel: it frees the worker result and
// mutates neither the editor nor the transcript.
test "shutdown frees the worker result without restoring or recording an event" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.input_future = null;
    app.resize_future = null;
    app.tick_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.initEventQueue();
    app.session.beginTurn(1);

    try seedSteering(&app, "keep");
    const worker_result: WorkerResult = .{
        .outcome = .{ .receipt = zero_receipt, .disposition = .{ .failed = error.Boom } },
        .error_text = try gpa.dupe(u8, "boom"),
    };
    app.turn_future = try io.concurrent(fakeWorker, .{&worker_result});

    app.shutdownTasks();
    // No editor restore, no cancellation event. Shutdown freed the owned text once.
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
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("old");
    try app.submitSteering();
    const folded = try app.agent.steering.take();
    for (folded) |message| gpa.free(message);
    gpa.free(folded);

    // The worker owns "old", but its consumed event has not reached the UI.
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
    // The delayed consume marks "old" (already hidden by ctrl+p) consumed. It does
    // not hide the newer pending "new", which stays visible behind the hidden prefix.
    try std.testing.expectEqual(@as(usize, 1), app.session.steering_retained_count);
    try std.testing.expectEqual(@as(usize, 2), app.session.steering.items.len);
    try std.testing.expectEqualStrings(
        "new",
        app.session.steering.items[app.session.steering_retained_count].visible.items,
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
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
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

    // The first recall sees the batch as in flight and retains its rich drafts.
    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 2), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.session.steering_retained_count);
    try std.testing.expectEqualStrings("", app.session.editor.visible());

    // Failed delivery returns the plain batch. A later recall selects the
    // matching retained suffix and moves it back live.
    app.agent.steering.restoreTaken(&delivery);
    try app.pullSteering();
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering_retained_count);
    try std.testing.expectEqualStrings("a\n\nb", app.session.editor.visible());
}

// Literal-edge canonicalization: separately submitted " a " and " b " recall and
// rejoin as "a\n\nb". The trimmed edge spaces never return.
test "recall of literal-edge-trimmed steering rejoins without edge spaces" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert(" a ");
    try app.submitSteering();
    try app.session.editor.insert(" b ");
    try app.submitSteering();
    try app.pullSteering();
    try std.testing.expectEqualStrings("a\n\nb", app.session.editor.visible());
}

// A slash command cannot run mid-turn. Enter must leave it in the editor to
// send once the turn ends and must never queue it as prompt text for the model. A
// sentence that only starts with a command name is a message and must queue.
test "mid-turn Enter queues a message but never a command or a blank line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    try app.session.editor.insert("/model");
    try app.submitSteering();
    try std.testing.expectEqualStrings("/model", app.session.editor.visible());

    app.session.editor.clear();
    try app.session.editor.insert("   ");
    try app.submitSteering();
    try std.testing.expectEqualStrings("   ", app.session.editor.visible());

    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    const blocked = try app.agent.steering.take();
    defer gpa.free(blocked);
    try std.testing.expectEqual(@as(usize, 0), blocked.len);

    // A sentence that starts with a command name is a message, not a command.
    app.session.editor.clear();
    try app.session.editor.insert("/model names the account too");
    try app.submitSteering();
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    const taken = try app.agent.steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings("/model names the account too", taken[0]);
}

test "late placeholder steering starts before a newer key in the same batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.input = terminal.Input.init(gpa);
    defer app.input.deinit();
    app.initEventQueue();
    defer app.drainQueue();
    app.turn_future = null;
    app.pending_turn_result = null;
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
    const events = [_]Session.UiEvent{
        .{ .turn = .{ .generation = 1, .payload = endedPayload() } },
        .{ .keys = try gpa.dupe(u8, "new\r") },
    };
    try std.testing.expect(!try app.applyBatch(&events));

    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expectEqualStrings(payload, app.session.transcript.blocks()[0].user.items);
    try std.testing.expectEqual(@as(usize, 1), app.session.turn_origin.?.prompt.atoms.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.session.steering.items.len);
    try std.testing.expectEqualStrings("new", app.session.steering.items[0].visible.items);
}

// The lifecycle calls model cancellation and resubmission key entries from a
// batch App already drained. The remaining entries use the real outer queue union
// and batch dispatcher.
test "a drained batch routes only the active turn generation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    app.session.beginTurn(1);
    const first = [_]Session.UiEvent{.{ .turn = .{
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

    const rest = [_]Session.UiEvent{
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
    try std.testing.expectEqualStrings("turn B", app.session.transcript.blocks()[2].model.items);
}

// A resize marks the model dirty with no tick, so even an idle interface
// reflows on the next frame.
test "a resize event marks an idle interface dirty" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try std.testing.expect(!try app.applyBatch(&[_]Session.UiEvent{.resize}));
    try std.testing.expect(app.session.dirty);
}

test "a failed batch frees its unprocessed turn events" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    const events = [_]Session.UiEvent{
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

test "turn generations cannot wrap or be reused" {
    var app: App = undefined;
    app.turn_generation = std.math.maxInt(u64);

    try std.testing.expectError(error.TurnGenerationExhausted, app.reserveTurnGeneration());
    try std.testing.expectEqual(std.math.maxInt(u64), app.turn_generation);
}

test "a legacy escape byte closes a page after its wait" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.running = true;
    app.escape_deadline_ms = null;
    app.input = terminal.Input.init(gpa);
    defer app.input.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    try app.session.openPage(&.{ .content = "", .presentation = .colors });

    // A terminal without the Kitty protocol sends this one byte. It can still
    // start a longer sequence, so the page stays open while the wait runs.
    try app.handleKeys("\x1b");
    try std.testing.expect(app.session.mode == .viewing);
    try std.testing.expect(app.escape_deadline_ms != null);
    try app.flushEscape();
    try std.testing.expect(app.session.mode == .viewing);

    // The wait passes with no more bytes, so the byte is the Escape key.
    app.escape_deadline_ms = app.nowMs() - 1;
    try app.flushEscape();
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.escape_deadline_ms == null);
    try std.testing.expect(app.running);

    // The bytes of a real sequence end the wait instead.
    try app.handleKeys("\x1b");
    try std.testing.expect(app.escape_deadline_ms != null);
    try app.handleKeys("[A");
    try std.testing.expect(app.escape_deadline_ms == null);
    try app.flushEscape();
}

test "a page close drops the rest of an exit attempt in one chunk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Apple Terminal sends Esc as one byte, so an exit attempt can land as
    // `\x1b\x03` or `\x1b\x04` in one chunk. The Escape closes the page, and the
    // control key behind it must not reach the prompt below.
    for ([_][]const u8{ "\x1b\x03", "\x1b\x04" }) |chunk| {
        var app: App = undefined;
        app.gpa = gpa;
        app.io = io;
        app.running = true;
        app.ctrl_c_ms_last = -ctrl_c_window_ms;
        app.escape_deadline_ms = null;
        app.input = terminal.Input.init(gpa);
        defer app.input.deinit();
        app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
        defer app.session.deinit();
        try app.session.editor.insert("draft");
        try app.session.openPage(&.{ .content = "", .presentation = .colors });

        try app.handleKeys(chunk);
        try std.testing.expect(app.session.mode == .prompt);
        // Ctrl+D did not quit, Ctrl+C left the draft the page hid, and neither
        // armed the double-press quit window.
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
    app.gpa = gpa;
    app.io = io;
    app.escape_deadline_ms = null;
    app.input = terminal.Input.init(gpa);
    defer app.input.deinit();
    // The confirmation mirrors the agent state into the session, so the agent must
    // be real. A signed-out one records no project state.
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const options = try gpa.alloc([]const u8, 1);
    options[0] = try gpa.dupe(u8, "alpha");
    try app.session.applyOutcome(.{ .pick = .{
        .select = struct {
            fn select(context: *ai.command.Context, _: usize) anyerror!ai.command.Outcome {
                return ai.command.Outcome.reportNotice(context.gpa, .information, "picked", .{});
            }
        }.select,
        .title = "Sign in",
        .cancellation_message = "You canceled the sign-in selection.",
        .options = options,
        .current = null,
    } });

    // Enter confirms and returns to the prompt, but it is no exit attempt. The
    // fast typing behind it must land in the editor, as it does when the terminal
    // splits the same keystrokes across two reads.
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
    app.gpa = gpa;
    app.io = io;
    app.running = true;
    app.ctrl_c_ms_last = -ctrl_c_window_ms;
    app.escape_deadline_ms = null;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.turn_generation = 0;
    app.initEventQueue();
    defer app.drainQueue();
    app.input = terminal.Input.init(gpa);
    defer app.input.deinit();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);
    try spawnCanceledTurn(&app);

    // The Escape cancels the turn. The Ctrl+D behind it must not quit pith at the
    // prompt the cancel returns to.
    try app.handleKeys("\x1b\x04");
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expect(app.running);
}

test "ctrl+c clears then quits within the window and ctrl+d quits only when empty" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = std.testing.io;
    app.ctrl_c_ms_last = -ctrl_c_window_ms;
    app.running = true;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.editor.insert("draft");
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(app.running);

    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.running);
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(!app.running);

    app.running = true;
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(!app.running);
}

test "/new clears the conversation and the scrollback without a configuration change" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "test system",
        .retry = .{},
        .effort = .high,
    });
    defer app.agent.deinit();
    // A submitted command records the project. This test saves no choice.
    app.state = .inert(gpa, io);
    app.session = Session.init(gpa, &out.writer, anthropic_default, .high);
    defer app.session.deinit();

    const cache_key = app.agent.cache_key;
    try app.agent.items.append(gpa, .{ .message = .{
        .role = .user,
        .text = try gpa.dupe(u8, "old prompt"),
    } });
    var seeded: ai.Agent.Stats = .{ .cost = 2.5, .last = .{ .input = 10 }, .model_count = 1 };
    seeded.by_model[0] = .{
        .name = anthropic_default.name,
        .cost = 2.5,
        .usage = .{ .input = 10 },
    };
    app.agent.stats = seeded;
    try app.agent.steering.push("old steering");
    try app.session.transcript.append(.user, false, "old prompt");
    app.session.stats_shown = seeded;
    try seedSteering(&app, "old steering");
    // Paint the old conversation first, so its frame holds the screen.
    try app.session.paint(.{ .columns = 80, .rows = 6 });

    try app.session.editor.insert("/new");
    app.session.armCacheConfirmation();
    try app.submit();
    try std.testing.expect(!app.session.takeCacheConfirmation());

    // The empty conversation must start on a clean screen. The paint clears the
    // visible rows and drops the scrollback with them.
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
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expect(std.meta.eql(ai.Agent.Stats{}, app.session.stats_shown));
    try std.testing.expect(!app.session.hasSteering());
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqualStrings(anthropic_default.name, app.agent.model.name);
    try std.testing.expectEqual(ai.llm.Effort.high, app.agent.effort);
}

test "/system opens the composed prompt alone and escape restores the conversation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const full_prompt = "# Core\n\n" ++ "system row\n" ** 30;
    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.prompt = full_prompt;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = full_prompt,
        .retry = .{},
    });
    defer app.agent.deinit();
    // A submitted command records the project. This test saves no choice.
    app.state = .inert(gpa, io);
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.transcript.append(.event, false, "history marker");
    try app.session.editor.insert("/system");
    try app.submit();

    try std.testing.expect(app.session.mode == .viewing);
    try std.testing.expectEqualStrings(full_prompt, app.session.mode.viewing.content);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    const page_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 6 });
    const page_bytes = out.written()[page_start..];
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "M: Source") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "Core") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "# Core") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "history marker") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, anthropic_default.name) == null);

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

    // Reopen before a refresh can leave the old alternate screen. The new page
    // must still clear and home that screen before the paint.
    try app.session.editor.insert("/system");
    try app.submit();
    const reopen_start = out.written().len;
    try app.session.paint(.{ .columns = 40, .rows = 5 });
    const reopen_bytes = out.written()[reopen_start..];
    try std.testing.expect(std.mem.indexOf(u8, reopen_bytes, terminal.escape.screen_repaint) != null);
    try std.testing.expect(std.mem.indexOf(u8, reopen_bytes, "M: Source") != null);
    try std.testing.expect(std.mem.indexOf(u8, reopen_bytes, "Core") != null);
    try std.testing.expect(std.mem.indexOf(u8, reopen_bytes, "# Core") == null);
    // Ctrl+C closes a page and keeps pith running. A page holds no draft to clear.
    app.running = true;
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.running);

    const conversation_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 6 });
    const conversation_bytes = out.written()[conversation_start..];
    try std.testing.expect(std.mem.indexOf(u8, conversation_bytes, "history marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation_bytes, "System prompt") == null);
}

test "/colors opens the color preview page and ctrl+d restores the conversation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.prompt = "unused";
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "unused",
        .retry = .{},
    });
    defer app.agent.deinit();
    // A submitted command records the project. This test saves no choice.
    app.state = .inert(gpa, io);
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.transcript.append(.event, false, "history marker");
    try app.session.editor.insert("/colors");
    try app.submit();

    try std.testing.expect(app.session.mode == .viewing);
    try std.testing.expect(app.session.mode.viewing.presentation == .colors);
    const page_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 12 });
    const page_bytes = out.written()[page_start..];
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "M: Source") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "ANSI slots 0 to 15") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_bytes, "history marker") == null);

    // The M toggle has no source to show, so the presentation stays.
    try app.handleKey(&.{ .char = 'm' });
    try std.testing.expect(app.session.mode.viewing.presentation == .colors);
    try app.handleKey(&.page_down);
    try std.testing.expect(app.session.mode.viewing.scroll > 0);

    // Ctrl+D closes the page and keeps pith running, so a terminal that drops the
    // Esc report still has a way out.
    app.running = true;
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
        .{ .anthropic_subscription = undefined },
        .{},
    );
    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, anthropic_client, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();
    try app.state.seed(.anthropic_subscription, &anthropic_default, .none);

    app.agent.stats.quota = .{
        .secondary = .{ .used_percent = 77, .window_minutes = 10080 },
    };
    app.session.stats_shown = app.agent.stats;

    const openai_client = ai.provider.Client.init(gpa, io, .{ .openai_api = "sk-test" }, .{});
    app.agent.switchTo(openai_client, openai_default);
    try app.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .information, "switched", .{}),
    );

    try std.testing.expect(app.agent.stats.quota == null);
    try std.testing.expect(app.session.stats_shown.quota == null);
    try std.testing.expectEqualStrings(openai_default.name, app.session.model_shown.name);
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.session.account_shown.?);

    // The switch also lands in `state.json`, so the next start resumes on it.
    var file = (try ai.json_store.open(gpa, io, app.state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("openai_api", entry.get("account").?.string);
    try std.testing.expectEqualStrings("none", entry.get("effort").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqualStrings(openai_default.name, listed.get("openai_api").?.string);
    // The account left behind keeps the model it ran, so a switch back returns
    // to it even after a restart.
    try std.testing.expectEqualStrings(
        anthropic_default.name,
        listed.get("anthropic_subscription").?.string,
    );
}

test "startup resumes on the account, model, and effort level this project used last" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "openai_api", "effort": "low",
        \\    "models": { "openai_api": "gpt-5.6-luna" } } }
    );

    var app: App = undefined;
    app.default_models = .{};
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    // The remembered account wins over the first authenticated one, which is the
    // Anthropic key here.
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.startAccount().?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", app.accountModel(.openai_api).name);
    // A remembered model belongs to the account that ran it. Any other account
    // starts on its own default.
    try std.testing.expectEqualStrings(
        anthropic_default.name,
        app.accountModel(.anthropic_api).name,
    );
    // The remembered effort level outranks a configured default.
    try std.testing.expectEqual(ai.llm.Effort.low, app.startEffort(.max));
}

test "a signed-out remembered account falls back and the defaults fill the rest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    // The file names an account with no credentials and no effort level.
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "openai_api", "models": { "openai_api": "gpt-5.6-luna" } } }
    );

    var app: App = undefined;
    app.default_models = .{};
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "sk-anthropic" });
    defer app.accounts.deinit();
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    try std.testing.expectEqual(ai.llm.Account.anthropic_api, app.startAccount().?);
    try std.testing.expectEqualStrings(
        anthropic_default.name,
        app.accountModel(.anthropic_api).name,
    );
    // The memory holds for the account that ran the model, even while that
    // account has no credentials. A later login therefore restores the model and
    // does not reset to the account's default.
    try std.testing.expectEqualStrings("gpt-5.6-luna", app.accountModel(.openai_api).name);
    // With nothing remembered, the configured default wins, else the compiled one.
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
    // The project last ran an Anthropic model that is not the compiled default.
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic_api", "effort": "none",
        \\    "models": { "anthropic_api": "claude-sonnet-5" } } }
    );

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.default_models = .{};
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    const start_model = app.accountModel(.anthropic_api);
    try std.testing.expectEqualStrings("claude-sonnet-5", start_model.name);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
        .model = start_model,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, start_model, .none);
    defer app.session.deinit();
    try app.state.seed(.anthropic_api, &start_model, .none);

    // Away to another account: that account has run nothing here, so it takes
    // its own default.
    try app.applyOutcome(.{ .switch_account = .openai_api });
    try std.testing.expectEqualStrings(openai_default.name, app.agent.model.name);

    // Back again. The model the account ran returns, and the compiled default
    // never overwrites it.
    try app.applyOutcome(.{ .switch_account = .anthropic_api });
    try std.testing.expectEqualStrings("claude-sonnet-5", app.agent.model.name);

    // Both models reach the file, so the next start knows them both.
    var file = (try ai.json_store.open(gpa, io, app.state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic_api", entry.get("account").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqualStrings("claude-sonnet-5", listed.get("anthropic_api").?.string);
    try std.testing.expectEqualStrings(openai_default.name, listed.get("openai_api").?.string);
}

test "a remembered account does not resume when no account is authenticated" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "openai_api", "models": { "openai_api": "gpt-5.6-luna" } } }
    );

    var app: App = undefined;
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    // Startup then runs signed out and opens the login picker.
    try std.testing.expect(app.state.start.account != null);
    try std.testing.expect(app.startAccount() == null);
}

// The logout of the last account leaves no one to adopt. Pith must sign out and
// open the login picker itself, so the session never rests signed out with no way
// back in.
test "the logout of the last account signs out and opens the login picker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    // One signed-in subscription and no environment key: the only account there is.
    var store = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".pith/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try std.testing.expect(app.accounts.isAuthenticated(.anthropic_subscription));
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    // A signed-out session records nothing, so this test saves no choice.
    app.state = .inert(gpa, io);

    try app.applyOutcome(.{ .logout = .anthropic_subscription });

    // The credential is gone and no account remains to adopt.
    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expect(app.agent.client == null);
    try std.testing.expect(app.session.account_shown == null);

    // The event names the way back in, and the picker it names is open.
    try std.testing.expectEqualStrings(
        "Pith signed out of Anthropic Subscription. Select an account to sign in.",
        app.session.transcript.blocks()[0].event.text.items,
    );
    try std.testing.expect(app.session.mode == .picking);
    const picker = app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Select an account to sign in", picker.title);
    try std.testing.expectEqual(std.enums.values(ai.llm.Account).len, picker.options.len);
    try std.testing.expectEqualStrings("Anthropic Subscription", picker.options[0]);
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

    var store = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".pith/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "replacement", "refresh": "replacement",
        \\      "expires_ms": 4102444800000,
        \\      "account_uuid": "other", "organization_uuid": "other" } }
        ,
    });

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.default_models = .{};
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;
    app.session.beginTurn(1);
    app.state = .inert(gpa, io);

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_subscription = .{
        .signature = .{ .text = "thought", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    app.agent.stats.quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };

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
    try std.testing.expectEqual(ai.llm.Account.anthropic_subscription, app.activeAccount().?);
    try std.testing.expectEqual(ai.llm.Account.anthropic_subscription, app.session.account_shown.?);
    try std.testing.expect(app.session.mode == .prompt);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].event.is_error);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].event.text.items,
        "Try the turn again.",
    ) != null);
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

    var store = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".pith/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;
    app.state = .inert(gpa, io);

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

        try std.testing.expect(app.accounts.isAuthenticated(.anthropic_subscription));
        try std.testing.expectEqual(
            ai.llm.Account.anthropic_subscription,
            app.activeAccount().?,
        );
        try std.testing.expectEqual(
            ai.llm.Account.anthropic_subscription,
            app.session.account_shown.?,
        );
    }
    {
        var file = (try ai.json_store.open(gpa, io, app.accounts.anthropic_auth.path)).?;
        defer file.deinit();
        try std.testing.expect(file.entry("anthropic_subscription") != null);
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

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expect(app.agent.client == null);
    try std.testing.expect(app.session.account_shown == null);
    var file = (try ai.json_store.open(gpa, io, app.accounts.anthropic_auth.path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("anthropic_subscription") == null);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expect(blocks[2].event.is_error);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[2].event.text.items,
        "provider rejected",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[2].event.text.items, "/login") == null);
    try std.testing.expectEqualStrings(
        "Pith signed out of Anthropic Subscription. Select an account to sign in.",
        blocks[3].event.text.items,
    );
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expectEqualStrings(
        "Anthropic Subscription",
        app.session.mode.picking.picker.options[0],
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

    var store = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".pith/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "old_access", "refresh": "old_refresh",
        \\      "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.default_models = .{};
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    // A model an account-specific limit resolved. The replaced credential owns
    // that limit, so the reload must resolve the model again.
    var discovered = anthropic_default;
    discovered.context_window = 1;
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = discovered,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;
    app.session.beginTurn(1);
    app.state = .inert(gpa, io);

    try ai.json_store.save(gpa, io, app.accounts.anthropic_auth.path, "anthropic_subscription", .{
        .access = "new_access",
        .refresh = "new_refresh",
        .expires_ms = 4102444800000,
    }, .{});

    // The replacement can belong to another principal, so this proof of the
    // replaced credential must not survive the reload.
    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_subscription = .{
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

    try std.testing.expect(app.accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expectEqual(
        ai.llm.Account.anthropic_subscription,
        app.activeAccount().?,
    );
    try std.testing.expectEqualStrings(
        "new_refresh",
        app.accounts.anthropic_auth.tokens.?.refresh,
    );
    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    // The limit of the replaced credential is gone from the model the session
    // shows, exactly as an OpenAI context window discovered for that principal.
    try std.testing.expectEqual(anthropic_default.context_window, app.agent.model.context_window);
    try std.testing.expectEqual(
        anthropic_default.context_window,
        app.session.model_shown.context_window,
    );
    try std.testing.expect(app.session.mode == .prompt);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].event.text.items, "signed out") == null);
    try std.testing.expectEqualStrings(
        "Pith reloaded the refresh credential that another Pith instance saved. " ++
            "Try the turn again.",
        blocks[1].event.text.items,
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

    var store = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".pith/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.default_models = .{};
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .openai = "sk-openai" });
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;
    app.session.beginTurn(1);
    app.state = .inert(gpa, io);

    var result: WorkerResult = .{
        .outcome = .{
            .receipt = zero_receipt,
            .disposition = .credential_rejected,
        },
        .error_text = try gpa.dupe(u8, turnFailureText(error.TokenGrantRejected).?),
    };
    defer app.freeWorkerResult(&result);
    try app.finishWorkerResult(&result);

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.activeAccount().?);
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.session.account_shown.?);
    try std.testing.expectEqualStrings(openai_default.name, app.agent.model.name);
    try std.testing.expect(app.session.mode == .prompt);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].event.text.items, "/login") == null);
    try std.testing.expectEqualStrings(
        "Pith signed out of Anthropic Subscription. " ++
            "Pith now uses gpt-5.6-sol with OpenAI API.",
        blocks[1].event.text.items,
    );
}

test "an invoked skill records a compact marker and keeps its task visible" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const prompt: ai.command.Outcome.Prompt = .{
        .name = "zig-style",
        .arguments = "review this file",
        .content = "complete hidden skill instructions",
    };
    try std.testing.expectEqual(@as(usize, 0), try app.appendSkillPrompt(&prompt));

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    switch (blocks[0]) {
        .skill => |name| try std.testing.expectEqualStrings("zig-style", name.items),
        else => return error.ExpectedSkill,
    }
    switch (blocks[1]) {
        .user => |task| try std.testing.expectEqualStrings("review this file", task.items),
        else => return error.ExpectedUser,
    }

    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Skill: zig-style") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), prompt.content) == null);
}

// Signed out, Pith must refuse a normal message with a /login prompt rather
// than spawn a turn against no client.
test "a signed-out submit is refused with a login prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    // A submitted command records the project. This test saves no choice.
    app.state = .inert(gpa, io);
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.editor.insert("hello");
    try app.submit();

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "/login") != null);
}

test "a stale cache blocks one submit and keeps the prompt unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "sk-test" });
    defer app.accounts.deinit();
    app.skills = ai.skills.Registry.init(gpa);
    defer app.skills.deinit();
    app.state = .inert(gpa, io);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.editor.insert("keep this prompt");
    const risk: ai.Agent.CacheRisk = .{
        .retention_ms = 5 * std.time.ms_per_min,
        .cost_extra = 1.15,
    };
    try app.submitWithCacheRisk(&risk);

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("keep this prompt", app.session.editor.visible());
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expectEqual(ai.command.Outcome.Severity.warning, app.session.notice.?.severity);
    try std.testing.expect(std.mem.startsWith(
        u8,
        app.session.notice.?.content,
        "Enter: Send anyway · Cache: Probably stale after 5m",
    ));
    try std.testing.expect(std.mem.indexOf(u8, app.session.notice.?.content, "$1.15") != null);

    // The next preflight consumes the confirmation instead of warning again.
    try std.testing.expect(try app.preflightModelSubmit(&risk));
    try std.testing.expect(!app.session.takeCacheConfirmation());

    // Any other user key cancels a later confirmation.
    app.session.armCacheConfirmation();
    try app.handleKey(&.left);
    try std.testing.expect(!app.session.takeCacheConfirmation());
}

// A sentence that starts with a command name is a message, so an idle Enter takes
// the message path. Signed out, that path refuses with the login prompt. The
// command the sentence starts with must leave no trace.
test "an idle submit of a command-like sentence takes the message path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    // A submitted command records the project. This test saves no choice.
    app.state = .inert(gpa, io);
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    try app.session.transcript.append(.user, false, "history marker");

    try app.session.editor.insert("/new must clear the terminal scrollback");
    try app.submit();

    // `/new` never ran, so the history stands and no conversation reset happened.
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "/login") != null);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
}

// Pith classifies a large paste that expands to a slash command from its expanded
// text, never its marker label. The label never reaches command dispatch.
test "a large pasted slash command is classified from expanded text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    // A submitted command records the project. This test saves no choice.
    app.state = .inert(gpa, io);
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    // One command name of more than 1000 bytes: large enough to collapse to a marker.
    try app.session.editor.paste("/nope" ++ "x" ** 1000, true);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);

    try app.submit();

    // The command ran off the expanded name, not the "[paste …]" label.
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
    // The whole expanded name reached dispatch, not just its first bytes.
    try std.testing.expect(
        std.mem.startsWith(u8, notice.content, "Pith does not recognize the command /nope"),
    );
    try std.testing.expect(std.mem.endsWith(u8, notice.content, "x" ** 1000 ++ "."));
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "paste") == null);
    try std.testing.expectEqualStrings("", app.session.editor.visible());
}

test "Esc, Ctrl+C, and Ctrl+D each cancel the picker with context" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    const keys = [_]terminal.Input.Key{ .escape, .{ .ctrl = 'c' }, .{ .ctrl = 'd' } };
    for (keys) |key| {
        const options = try gpa.alloc([]const u8, 1);
        options[0] = try gpa.dupe(u8, "alpha");
        try app.session.applyOutcome(.{
            .pick = .{
                // Never called: every key under test cancels.
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

test "a user action clears a notice while background events leave it visible" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "temporary", .{}),
    );
    const background = [_]Session.UiEvent{ .resize, .tick };
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
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    try app.session.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .failure, "backend failed", .{}),
    );
    try app.handleKey(&.{ .char = 'x' });

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].event.is_error);
    try std.testing.expectEqualStrings("backend failed", blocks[0].event.text.items);
}

/// The absolute path of `suffix` inside a test temporary directory.
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

test "the startup report counts the sources in one line and keeps a skip verbose" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The `.git` marker bounds both ancestor scans, so the enclosing repository
    // cannot add its own instruction files or skills to the counts.
    var git = try tmp.dir.createDirPathOpen(io, ".git", .{});
    git.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "Project.\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "first.md", .data = "First.\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second.md", .data = "Second.\n" });
    var skill = try tmp.dir.createDirPathOpen(io, ".agents/skills/demo", .{});
    skill.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".agents/skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: a test skill\n---\nbody\n",
    });
    var hidden = try tmp.dir.createDirPathOpen(io, ".agents/skills/hidden", .{});
    hidden.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".agents/skills/hidden/SKILL.md",
        .data = "---\nname: hidden\ndescription: a manual skill\n" ++
            "disable-model-invocation: true\n---\nbody\n",
    });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);
    const user_skills = try std.fs.path.join(gpa, &.{ root, "home", ".agents", "skills" });
    defer gpa.free(user_skills);

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    var user_instructions = try ai.instructions.load(gpa, io, &.{
        .directory = root,
        .paths = &.{ "first.md", "second.md", "missing.md" },
    });
    defer user_instructions.deinit();
    app.project_instructions = try ai.instructions.discover(gpa, io, root);
    defer app.project_instructions.deinit();
    app.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = root,
        .project_root = app.project_instructions.projectRoot(),
    });
    defer app.skills.deinit();

    try app.reportSources(&.{
        .user_instructions = &user_instructions,
        .project_instructions = &app.project_instructions,
        .skills = &app.skills,
    });

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(!blocks[0].event.is_error);
    // The count covers the two skills the scan kept, minus the one that disabled
    // model invocation, because `/system` never shows that one.
    try std.testing.expectEqualStrings(
        "Pith loaded 2 user instruction files and 1 project instruction file. " ++
            "Pith found 1 skill.",
        blocks[0].event.text.items,
    );
    // A source that skipped something stays verbose, because the user must fix it.
    try std.testing.expect(blocks[1].event.is_error);
    try std.testing.expect(std.mem.indexOf(u8, blocks[1].event.text.items, "missing.md") != null);
}

test directoryLabel {
    const gpa = std.testing.allocator;
    const home = try directoryLabel(gpa, "/home/clemens", "/home/clemens");
    defer gpa.free(home);
    try std.testing.expectEqualStrings("~", home);

    const inside = try directoryLabel(gpa, "/home/clemens/github/pith", "/home/clemens");
    defer gpa.free(inside);
    try std.testing.expectEqualStrings("~/github/pith", inside);

    // A sibling that shares a name prefix is not inside the home directory.
    const outside = try directoryLabel(gpa, "/home/clemens2/work", "/home/clemens");
    defer gpa.free(outside);
    try std.testing.expectEqualStrings("/home/clemens2/work", outside);

    // A home directory that is a root already ends with the separator, which the
    // directory below it keeps and the root itself does not.
    const below_root = try directoryLabel(gpa, "/work", "/");
    defer gpa.free(below_root);
    try std.testing.expectEqualStrings("~/work", below_root);

    const root = try directoryLabel(gpa, "/", "/");
    defer gpa.free(root);
    try std.testing.expectEqualStrings("~", root);

    // A long path keeps its tail, and the cut lands on a display boundary.
    const capped = try directoryLabel(gpa, "/ä" ** 80, "/home");
    defer gpa.free(capped);
    try std.testing.expect(capped.len <= ui.status.directory_bytes_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(capped));
    try std.testing.expect(std.mem.startsWith(u8, capped, "…"));
    try std.testing.expect(std.mem.endsWith(u8, capped, "/ä"));

    // A grapheme cluster survives the cut whole. Each flag is two code points,
    // and the tail holds only whole flags.
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

    // A symbolic link in HOME resolves, so the label can compare it with the
    // canonical working directory.
    const canonical = try homeDirectory(gpa, io, "/", link);
    defer gpa.free(canonical);
    try std.testing.expectEqualStrings(real, canonical);

    // A home directory that does not exist keeps its lexical path.
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
    app.gpa = gpa;
    app.io = io;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();

    // Outside a repository the status line shows the directory alone.
    app.refreshBranch();
    try std.testing.expect(app.session.branch() == null);
    try std.testing.expect(!app.session.dirty);

    app.session.branch_root = root;
    app.refreshBranch();
    try std.testing.expectEqualStrings("topic", app.session.branch().?);
    // A changed branch repaints, and an unchanged one does not.
    try std.testing.expect(app.session.dirty);
    app.session.dirty = false;
    app.refreshBranch();
    try std.testing.expect(!app.session.dirty);

    // A head Pith cannot read leaves the directory standing alone.
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "garbage\n" });
    app.refreshBranch();
    try std.testing.expect(app.session.branch() == null);
}

test "a startup with no guidance and no skipped file reports nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var git = try tmp.dir.createDirPathOpen(io, ".git", .{});
    git.close(io);
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);
    const user_skills = try std.fs.path.join(gpa, &.{ root, "home", ".agents", "skills" });
    defer gpa.free(user_skills);

    var app: App = undefined;
    app.gpa = gpa;
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    var user_instructions = try ai.instructions.load(gpa, io, &.{
        .directory = root,
        .paths = &.{},
    });
    defer user_instructions.deinit();
    app.project_instructions = try ai.instructions.discover(gpa, io, root);
    defer app.project_instructions.deinit();
    app.skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = root,
        .project_root = app.project_instructions.projectRoot(),
    });
    defer app.skills.deinit();

    try app.reportSources(&.{
        .user_instructions = &user_instructions,
        .project_instructions = &app.project_instructions,
        .skills = &app.skills,
    });

    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

test "cancel draining preserves non-turn events ahead of newer queue data" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    defer app.drainQueue();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    var queued: [queue_capacity]Session.UiEvent = @splat(.resize);
    queued[0] = .{ .turn = .{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .usage = .{} },
    } };
    try app.queue.putAll(io, &queued);

    const producer = struct {
        fn put(queue: *std.Io.Queue(Session.UiEvent), producer_io: std.Io) void {
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
    // A second cancellation before the loop consumes this prefix leaves newer
    // data in the queue. It does not append beyond the bounded deferred buffer.
    try std.testing.expect(app.drainCanceledProgress(true) == null);
    try std.testing.expectEqual(queue_capacity - 1, app.deferred_event_count);

    var deferred: [queue_capacity]Session.UiEvent = undefined;
    const deferred_count = app.takeDeferredEvents(&deferred);
    try std.testing.expectEqual(queue_capacity - 1, deferred_count);
    for (deferred[0..deferred_count]) |event|
        try std.testing.expect(event == .resize);

    var newer: [2]Session.UiEvent = undefined;
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
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
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

// A cancel that commits nothing returns the submitted prompt to the editor as a
// rich draft, its collapsed paste preserved for an exact expansion. It shows no
// `canceled` line (the turn simply vanished).
test "cancel returns the submitted prompt as a rich draft with its paste placeholder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.initEventQueue();
    app.turn_future = null;
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(1);

    // The retained prompt is a rich draft, exactly as `submit` detaches it.
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
    // Nothing committed, so the tail rewound to empty and no cancellation event shows.
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
}

// Committed progress queued but not yet read lands before the rewind, so a
// partial-commit cancel keeps its presented round and adds `canceled`.
test "a committed cancel drains queued progress into the transcript before rewinding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.gpa = gpa;
    app.io = io;
    app.turn_future = null;
    app.pending_turn_result = null;
    app.initEventQueue();
    defer app.drainQueue();
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = anthropic_default,
        .system = "",
        .retry = .{},
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, anthropic_default, .none);
    defer app.session.deinit();
    app.session.beginTurn(5);

    const base = app.session.transcript.blocks().len;
    try app.session.transcript.append(.user, false, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    app.session.retainTurnPrompt(&prompt, base);

    // The committed round's progress is still queued, unread by the consumer.
    // Its usage snapshot predates the final canceled-stream accounting.
    app.agent.stats.cost = 2.5;
    const queued = [_]Session.UiEvent{
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
                .content = try gpa.dupe(u8, "ok"),
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
    // [user "prompt", model "answer", tool_result "read → ok", cancellation event]
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].user.items);
    try std.testing.expectEqualStrings("answer", blocks[1].model.items);
    try std.testing.expect(std.mem.indexOf(u8, blocks[2].tool_result.text.items, "ok") != null);
    try std.testing.expect(!blocks[3].event.is_error);
    try std.testing.expectEqualStrings("You canceled the turn.", blocks[3].event.text.items);
    try std.testing.expectEqual(@as(f64, 2.5), app.session.stats_shown.cost);
}

test "the frame grid holds a fixed period through a late wake and a slow paint" {
    // Model the consumer loop. The timer wakes late, the frame paints, and the
    // loop then arms the next one. Every deadline must stay exactly one interval
    // after the previous one, so the lateness and the paint cost never add to the
    // period. This is the property a per-frame reset of the grid would destroy.
    const wake_late_ns: i96 = 3 * std.time.ns_per_ms;
    const paint_ns: i96 = 5 * std.time.ns_per_ms;
    var grid: FrameGrid = .reset(1000);
    var previous_ns = grid.deadline_ns;
    for (0..60) |_| {
        const armed_ns = previous_ns + wake_late_ns + paint_ns;
        grid.advance(armed_ns);
        try std.testing.expectEqual(previous_ns + FrameGrid.interval_ns, grid.deadline_ns);
        // Anchored on the wake instead, the period would grow by the lateness and
        // the paint cost on every frame.
        try std.testing.expect(grid.deadline_ns != armed_ns + FrameGrid.interval_ns);
        previous_ns = grid.deadline_ns;
    }
    try std.testing.expectEqual(@as(i96, 1000) + 60 * FrameGrid.interval_ns, grid.deadline_ns);
}

test "the frame grid starts again after an overrun or an idle wait" {
    // A frame that overran its slot fires at once and starts the grid again, so a
    // slow frame cannot leave a backlog of missed deadlines behind it.
    var grid: FrameGrid = .reset(1000);
    const overrun_ns: i96 = 1000 + 20 * std.time.ns_per_ms;
    grid.advance(overrun_ns);
    try std.testing.expectEqual(overrun_ns, grid.deadline_ns);

    // A wake from an idle channel starts the grid again too, so the first frame
    // after it paints at once instead of after a whole interval.
    const idle_ns: i96 = 5 * std.time.ns_per_s;
    grid.advance(idle_ns);
    try std.testing.expectEqual(idle_ns, grid.deadline_ns);

    // The grid picks the fixed period up again from there.
    grid.advance(idle_ns);
    try std.testing.expectEqual(idle_ns + FrameGrid.interval_ns, grid.deadline_ns);
}
