//! The composition root and event loop. It wires the tty, the agent, and the
//! `Session` together, then runs the interface off one `std.Io.Queue` of
//! `Session.UiEvent`. Five `io.concurrent` producers feed it: the input reader
//! (`.keys`), the turn worker (generation-tagged `.turn` events), the model
//! fetch worker (a generation-tagged `.fetch_ended` wakeup), a one-shot frame
//! timer (`.tick`), and a SIGWINCH watcher (`.resize`).
//!
//! A command runs on the consumer. A model fetch is the one command step that
//! reaches the network, so it leaves the consumer for a worker, and the picker
//! that asked for it waits until the result rebuilds it. The OAuth login is the
//! one blocking step: it leaves raw mode and prints its own prompts.
//!
//! `Session` owns the model and the rendering and is io-, tty-, and agent-free,
//! so a test drives it from a scripted event sequence. `App` keeps the io, the
//! tasks, the tty, the agent, and the key, command, and turn orchestration.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const Config = @import("Config.zig");
const describe = @import("describe.zig");
const Herdr = @import("Herdr.zig");
const layout = @import("layout.zig");
const Retry = @import("Retry.zig");
const Session = @import("Session.zig");
const State = @import("State.zig");
const system_prompt = @import("system_prompt.zig");
const ui = @import("ui/root.zig");

const App = @This();

const effort_default: ai.llm.Effort = .xhigh;

/// The refusal a send meets while the active account offers no model. Drinky
/// compiles none in, so the user fetches a list and picks one there.
const no_model_refusal = "Select a model with /model before you send a message.";

/// The row that a model picker shows while its fetch runs. The title of the
/// picker names the account, so the row names the work alone.
const fetch_wait_text = "Drinky fetches the model list.";

/// Two models for the tests, which build what they need because Drinky compiles
/// no model in.
const test_anthropic_model = ai.testing.model("claude-opus-5");
const test_openai_model = ai.testing.model("gpt-5.6-sol");

/// The key hints of the intro line, in the order the line shows them. The
/// `describe_drinky` document names the same hints, so the legend of the
/// interface and the document cannot drift.
const intro_keys = [_][]const u8{
    "Enter: Send",
    "Shift+Enter: New line",
    "Esc: Cancel",
    "Ctrl+C: Clear",
    "Ctrl+D: Quit",
};

/// The intro line: every key hint, then the pointer at the command list. The
/// line wraps at its separators, so no hint ever goes away.
const intro_text = blk: {
    var line: []const u8 = "";
    for (intro_keys) |hint| line = line ++ hint ++ ui.paint.separator;
    break :blk line ++ "/help: Commands";
};

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
/// The machine-local choices of this project: read once at startup, written
/// whenever the account, the model, or the effort level changes.
state: State,
/// The working directory the status line shows, with the home directory
/// abbreviated to `~`. Owned, and fixed for the session, because Drinky never
/// changes its working directory.
directory_label: []const u8,
/// The canonical working directory and home directory of this session. Both
/// borrow `run` storage, and a path that the transcript shows reads against
/// them. Empty until `run` resolves them, so a path then shows as it is.
working_directory: []const u8,
home_directory: []const u8,
/// Project instructions, skill metadata, and the composed prompt. All outlive
/// the agent, which borrows `prompt`.
project_instructions: ai.instructions.Result,
skills: ai.skills.Registry,
prompt: []const u8,
/// What the `describe_drinky` tool returns: the document that describes the
/// harness itself. It outlives the agent, which borrows it.
document: []const u8,
/// The path-triggered skill rules of the session. Every rule borrows its glob
/// from the config and its name and file from the skill registry, so both
/// outlive the agent, which borrows the guard itself.
skill_guard: ai.tool.SkillGuard,
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
/// The running model fetch, or null between fetches. The picker that asked for
/// it waits with no rows while it runs. Its join is the sole result.
fetch: ?Fetch,
/// Last generation reserved for a fetch worker. A canceled fetch can leave its
/// wakeup in the queue, so the wakeup names the fetch it belongs to and cannot
/// join the fetch that follows.
fetch_generation: u64,
/// The retry context of the latest failed turn, or null when none waits. It
/// lives at the prompt alone, because the start of any turn takes it.
retry: ?Retry,
/// Whether the live turn is a retry attempt. Its failure arms the context again,
/// because the committed work that it continues from is still in history.
turn_retry: bool,
/// The pending frame timer, or null when none is armed (idle or clean).
tick_future: ?std.Io.Future(void),
/// A frame timer is armed and its `.tick` has not been drained yet.
tick_pending: bool,
/// The frame schedule. Only `armTick` advances it, so no frame can reset it.
frame_grid: FrameGrid,
/// The state report to Herdr. Inert outside a Herdr pane. The loop derives the
/// state after each batch, so no turn end path reports it.
herdr: Herdr,

/// The process environment that the app cannot read for itself. `main` owns every
/// lookup, so a test can run the app with no environment at all.
pub const Options = struct {
    /// Each bash command inherits this process environment. `Agent.init` demands one, so the
    /// default here holds only for a test that runs no command.
    environ: std.process.Environ = .empty,
    /// The provider credentials that authenticate an account without a login.
    credentials: ai.Accounts.Environment = .{},
    /// The Herdr pane this process runs in, or null outside Herdr.
    herdr: ?Herdr.Env = null,
};

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
    /// The served model already reported for this turn, so a fallback that holds
    /// across the turn's requests reports once rather than once per request. The
    /// buffer bounds the name, and a longer name dedupes on its head.
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
        // The model reads the output, so only the box line reaches the consumer.
        _ = content;
        const name_copy = try self.app.gpa.dupe(u8, name);
        errdefer self.app.gpa.free(name_copy);
        // The copy keeps the shape beside the text it belongs to.
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
        // Tool-result slots are inside the checkpoint established before tool
        // dispatch, and the real value replaces its slot before this callback.
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

    /// Report the model that really served a reply. The turn's requests share
    /// one requested model, so a repeat of the same served model adds nothing
    /// and stays silent. A served model that changes again reports again.
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

    /// Report that Drinky sent one skill file into the turn. The transcript shows
    /// the head alone, so the user sees which skill entered the conversation and
    /// where it comes from.
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

/// One model fetch on a worker. The worker owns the account registry until the
/// join, and the picker mode admits no command meanwhile, so the consumer never
/// reads the registry under it.
const Fetch = struct {
    future: std.Io.Future(ai.Accounts.Refresh),
    account: ai.llm.Account,
    generation: u64,
};

/// Cooked-mode OAuth output keeps trusted prompt text separate from runtime URL
/// and path values, which pass through the terminal's inert-text policy.
const OauthPrompt = struct {
    writer: *std.Io.Writer,
    io: std.Io,
    /// Whether a paste watch reads the terminal. The authorization prompt
    /// promises the paste path only while one exists.
    paste_enabled: bool = false,
    /// The login worker and the paste watch write concurrently. One lock
    /// serializes them.
    mutex: std.Io.Mutex = .init,

    pub fn showAuthorization(self: *OauthPrompt, url: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.writer.writeAll("Open this URL to authorize Drinky:\n\n");
        try self.writeText(url);
        try self.writer.writeAll("\n\nDrinky waits for the response from the browser.\n");
        if (self.paste_enabled) try self.writer.writeAll(
            "If the browser shows an error, paste the URL from its address bar here " ++
                "and press Enter.\n",
        );
        try self.writer.flush();
    }

    pub fn showBrowserLaunchFailed(self: *OauthPrompt) !void {
        try self.show("Drinky could not open the browser. Open the URL above.\n");
    }

    fn showAuthorized(self: *OauthPrompt, path: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.writer.writeAll("Drinky received authorization. Drinky saved the credentials to ");
        try self.writeText(path);
        try self.writer.writeAll(".\n");
        try self.writer.flush();
    }

    fn showSaveFailed(self: *OauthPrompt, path: []const u8, error_name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.writer.writeAll(
            "Drinky received authorization. Drinky could not save the credentials to ",
        );
        try self.writeText(path);
        try self.writer.print(
            " because of error {s}. The sign-in stays active until Drinky exits.\n",
            .{error_name},
        );
        try self.writer.flush();
    }

    fn showPasteInvalid(self: *OauthPrompt) !void {
        try self.show("The pasted line is not the callback URL. " ++
            "Paste the complete URL from the address bar.\n");
    }

    fn showPasteFailed(self: *OauthPrompt, error_name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.writer.print(
            "Drinky could not replay the pasted URL because of error {s}.\n",
            .{error_name},
        );
        try self.writer.flush();
    }

    fn showPasteTooLong(self: *OauthPrompt) !void {
        try self.show("The pasted line is too long for a callback URL. " ++
            "Paste only the URL from the address bar.\n");
    }

    fn showPasteLate(self: *OauthPrompt) !void {
        try self.show("Drinky already received the response for this sign-in.\n");
    }

    fn showPasteStopped(self: *OauthPrompt) !void {
        try self.show("Drinky no longer reads a pasted URL. " ++
            "The browser response still completes the sign-in.\n");
    }

    /// Write one trusted sentence under the lock.
    fn show(self: *OauthPrompt, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.writer.writeAll(text);
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

/// The blocking OAuth login as a worker task, so the main task can watch the
/// terminal for a pasted callback URL meanwhile. `done` flips last, and the
/// paste watch polls it.
const LoginWorker = struct {
    accounts: *ai.Accounts,
    account: ai.llm.Account,
    prompt: *OauthPrompt,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *LoginWorker) anyerror!ai.Accounts.Login {
        defer self.done.store(true, .release);
        return self.accounts.login(self.account, self.prompt);
    }
};

/// The line handler of the paste watch: validate a line and replay it to the
/// local redirect listener. A failure reports through the prompt and the watch
/// continues, because the browser callback can still land.
const PasteHandler = struct {
    io: std.Io,
    port: u16,
    prompt: *OauthPrompt,

    fn onLine(self: *const PasteHandler, text: []const u8) void {
        if (!ai.oauth_callback.holdsRedirect(text)) {
            self.prompt.showPasteInvalid() catch {};
            return;
        }
        ai.oauth_callback.replay(self.io, self.port, text) catch |err| switch (err) {
            // The listener closes as soon as it holds a response, so a refused
            // port means the sign-in already moved on. A second paste is
            // ordinary, and it must not read as a fault.
            error.ConnectionRefused => self.prompt.showPasteLate() catch {},
            else => self.prompt.showPasteFailed(@errorName(err)) catch {},
        };
    }

    fn onLongLine(self: *const PasteHandler) void {
        self.prompt.showPasteTooLong() catch {};
    }
};

/// Assemble cooked-mode terminal chunks into whole trimmed lines for the
/// paste watch. The storage takes the shared paste limit, so every line the
/// validator can accept passes through whole. A longer line is dropped whole
/// and reported once.
const PasteSplitter = struct {
    storage: [ai.oauth_callback.paste_bytes_max]u8 = undefined,
    length: usize = 0,
    dropping: bool = false,

    fn feed(self: *PasteSplitter, chunk: []const u8, handler: anytype) void {
        for (chunk) |byte| {
            if (byte == '\n') {
                const dropped = self.dropping;
                const text = std.mem.trim(u8, self.storage[0..self.length], " \t\r");
                self.length = 0;
                self.dropping = false;
                if (dropped) {
                    handler.onLongLine();
                } else if (text.len != 0) {
                    handler.onLine(text);
                }
                continue;
            }
            if (self.dropping) continue;
            if (self.length == self.storage.len) {
                self.dropping = true;
                continue;
            }
            self.storage[self.length] = byte;
            self.length += 1;
        }
    }
};

/// The guidance sources of one startup report. Both instruction results have the
/// same type, so the field names keep the two apart at the call site.
const Sources = struct {
    user_instructions: *const ai.instructions.Result,
    project_instructions: *const ai.instructions.Result,
    skills: *const ai.skills.Registry,
    /// How many required skill names no discovered skill carries, each name
    /// counted once. `resolveRequiredSkills` reports the count.
    required_missing_count: usize = 0,
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

/// `directory` with `home` written as `~`, which is what the status line shows.
/// A directory outside the home directory keeps its own path. The result is
/// owned.
fn directoryLabel(
    gpa: std.mem.Allocator,
    directory: []const u8,
    home: []const u8,
) ![]const u8 {
    // The status line names an identity rather than a file, so it never falls
    // back to a path relative to the working directory the way `format.path`
    // does. It asks for the home-relative part directly, because the result of
    // `format.path` cannot say whether a leading `~/` came from home.
    const label = if (ai.format.relativeTo(&.{ .boundary = home, .target = directory })) |relative|
        try std.fmt.allocPrint(gpa, "~/{s}", .{relative})
    else if (ai.project.contains(&.{ .boundary = home, .target = directory }))
        // The home directory itself is the whole label.
        try gpa.dupe(u8, "~")
    else
        try gpa.dupe(u8, directory);
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
/// directory Drinky cannot resolve keeps its lexical path, which then simply does
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

/// Herdr labels its pane with the directory and the branch, so inside a pane the
/// status line leaves them to Herdr. The null root then also ends every branch
/// readout, because the status line is the only reader of the branch.
fn showProject(self: *App, inside_herdr: bool) void {
    if (inside_herdr) return;
    self.session.directory_shown = self.directory_label;
    self.session.branch_root = self.project_instructions.projectRoot();
    self.refreshBranch();
}

/// Read the branch of the project and show it on the status line. Display only:
/// a repository whose head Drinky cannot read leaves the directory standing alone.
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
    options: *const Options,
) !void {
    self.initFields(gpa, io);
    // `initFields` built the key decoder. Only the consumer loop feeds it, so free
    // its growth once that loop returns.
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

    const home_directory = try homeDirectory(gpa, io, cwd, home);
    defer gpa.free(home_directory);
    self.working_directory = cwd;
    self.home_directory = home_directory;
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
    // A configured glob measures against the working directory. The rules must
    // reach the guard before the prompt below names them, so the messages of a
    // rule that Drinky drops wait for the transcript.
    self.skill_guard = .{ .working_directory = cwd };
    var skill_notices: std.ArrayList(ai.instructions.Notice) = .empty;
    defer {
        for (skill_notices.items) |notice| gpa.free(notice.text);
        skill_notices.deinit(gpa);
    }
    const required_missing_count = try self.resolveRequiredSkills(&config, &skill_notices);
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
    self.document = try describe.compose(gpa, &.{
        .config = &config,
        .effort_default = effort_default,
        .key_hints = &intro_keys,
        .ctrl_c_window_ms = ctrl_c_window_ms,
    });
    defer gpa.free(self.document);

    // Start on the account this project used last, then on the first
    // authenticated account, or signed out (no client) when none is. The login
    // picker opens below to sign in. The model resolves from the name that
    // account ran here. A name the account no longer offers, and an account
    // that no fetch ran for, resolve to no model, and the status line says so.
    const active = self.startAccount();
    const start_account = active orelse .anthropic_subscription;
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
    // Startup applies the remembered or the default choices, so it saves nothing.
    // Only a later change writes the file. A signed-out start has no account to
    // remember, so the first login records one.
    if (active) |account| try self.state.seed(account, start_model, start_effort);

    try self.tty.init(io);
    defer self.tty.deinit();

    try self.resize.init();
    defer self.resize.deinit();

    self.session = Session.init(gpa, self.tty.writer(), self.agent.model, self.agent.effort);
    defer self.session.deinit();
    self.session.showSetup(active, self.agent.model, self.agent.effort);
    // The session reports how long a call has run against this timeout, so it
    // must read the same one the tool runs under.
    self.session.bash_timeout_ms = config.bash.timeout_ms;
    // The interface settings reach the frame through the session, because paint
    // reads no configuration of its own.
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
        // The file can state one share alone, and the other one is then the
        // compiled share. The pair is therefore not always a configured pair,
        // so the sentence names the shares and not the lines of the file.
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
    // The parse ignores an unknown key so that an older binary reads a newer
    // file. Report it, because a typo otherwise looks like an applied setting.
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
    try self.reportSources(&.{
        .user_instructions = &config.user_instructions,
        .project_instructions = &self.project_instructions,
        .skills = &self.skills,
        .required_missing_count = required_missing_count,
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

    // The release is the last word of this process to Herdr, so it runs after
    // every other task is down.
    self.herdr.start(options.herdr);
    defer self.herdr.deinit();
    self.running = true;
    defer self.shutdownTasks();
    try self.startInputReader();
    self.resize_future = try self.io.concurrent(readResize, .{self});

    try self.runLoop();
}

/// Give every field its start value. `run` and the test scaffolding both begin
/// here, and the exhaustive literal fails the build for a field with no start.
/// No value allocates, so a caller overwrites one without a leak. A field that
/// stays `undefined` needs a live resource that only `run` or a test can build.
fn initFields(self: *App, gpa: std.mem.Allocator, io: std.Io) void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        // A tty needs a terminal, and the watcher needs a signal handler.
        .tty = undefined,
        .resize = undefined,
        // Pinned: `client` returns a pointer into it, so the owner must build it
        // in place.
        .accounts = undefined,
        // It needs the account, model, and effort level of the caller.
        .agent = undefined,
        // It needs the writer that the caller reads back.
        .session = undefined,
        .state = .inert(gpa, io),
        .directory_label = "",
        .working_directory = "",
        .home_directory = "",
        // The source only names a noun in a report, and nothing reports an empty
        // result, so either tag serves until discovery replaces this.
        .project_instructions = .init(gpa, .project),
        .skills = .init(gpa),
        .prompt = "",
        .document = "",
        // The rules join it in `run`, once the config and the skill scan are
        // both read.
        .skill_guard = .{},
        .input = .init(gpa),
        // The loop is not live yet. `run` arms this before it enters the loop.
        .running = false,
        // The monotonic clock can start near zero. A boot press must never read
        // as the second of a pair.
        .ctrl_c_ms_last = -ctrl_c_window_ms,
        .escape_deadline_ms = null,
        // Taken below, after the literal.
        .queue = undefined,
        // The storage that the queue borrows.
        .queue_buffer = undefined,
        // Storage that only a cancel drain writes.
        .deferred_events = undefined,
        .deferred_event_count = 0,
        .input_future = null,
        .resize_future = null,
        .turn_future = null,
        .pending_turn_result = null,
        .turn_generation = 0,
        .fetch = null,
        .fetch_generation = 0,
        .retry = null,
        .turn_retry = false,
        .tick_future = null,
        .tick_pending = false,
        .frame_grid = .reset(0),
        .herdr = .init(io),
    };
    // The literal above writes `queue_buffer` too. A result location does put that
    // buffer at its final address, but do not depend on that, so take it here.
    self.queue = std.Io.Queue(Session.UiEvent).init(&self.queue_buffer);
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
    self.dropRetry();
    if (self.cancelTurnFuture()) |result| self.freeWorkerResult(&result);
    if (self.pending_turn_result) |result| {
        self.freeWorkerResult(&result);
        self.pending_turn_result = null;
    }
    self.dropFetch();
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

/// Reconcile a completed or failed joined result, then return late steering to
/// the editor after a completion. A failure returns uncommitted drafts too.
fn finishWorkerResult(self: *App, result: *const WorkerResult) !void {
    self.session.stats_shown = self.agent.stats;
    // A turn can check out another branch, so the status line settles here.
    self.refreshBranch();
    switch (result.outcome.disposition) {
        .completed => {
            _ = self.takeTurnRetry();
            try self.session.endTurnWithReceipt(&result.outcome.receipt);
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
            try self.finishFailedWorker(result);
            try self.rejectCredential(account);
        },
        .failed => try self.finishFailedWorker(result),
        .canceled, .closed => return error.UnexpectedTurnDisposition,
    }
}

/// Apply one failed result and arm its retry. The credential work stays with
/// the caller, because it can open a picker over the restored prompt.
fn finishFailedWorker(self: *App, result: *const WorkerResult) !void {
    // The turn ends here whatever follows, so its attempt flag resolves first.
    const attempt = self.takeTurnRetry();
    try self.session.reserveFailureRestore(&result.outcome.receipt);
    defer self.agent.steering.clear();
    // The reconciliation runs first, because `reserveFailureRestore` makes only
    // that step infallible. The arm allocates, so it stays outside that window.
    try self.session.failTurnWithReceipt(&result.outcome.receipt, result.error_text);
    try self.armRetry(result, attempt);
}

/// Arm one retry context from a failed turn, so Ctrl+N can ask the model to
/// continue. Only committed work can be continued, so a turn that committed
/// nothing arms nothing: its request returns to the editor instead. A failed
/// `attempt` is the exception, because the work that it continues from is already
/// in history. The latest failure replaces any older context.
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

/// Replace the retry context and mirror its caption into the session. This is
/// the one place that moves both together, so the caption cannot outlive it.
///
/// The call frees the context that it replaces, so a caller builds `maybe_retry`
/// and every byte in it first. `armRetry` duplicates the failure sentence before
/// it arrives here for exactly that reason.
fn setRetry(self: *App, maybe_retry: ?Retry) void {
    self.dropRetry();
    self.retry = maybe_retry;
    self.session.retry_shown = maybe_retry != null;
    self.session.dirty = true;
}

/// Take the attempt flag of the turn that is ending. Only a new attempt sets it
/// again, so every terminal reads it once.
fn takeTurnRetry(self: *App) bool {
    defer self.turn_retry = false;
    return self.turn_retry;
}

/// Free the retry context and forget it. Teardown uses this, because it touches
/// no session state.
fn dropRetry(self: *App) void {
    const retry = self.retry orelse return;
    retry.deinit(self.gpa);
    self.retry = null;
}

/// Discard the retry context and its caption. The editor keeps its text because
/// Esc dismisses the retry alone.
fn clearRetry(self: *App) void {
    if (self.retry == null) return;
    self.setRetry(null);
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
        // A held Escape byte arms a frame too, because its wait ends on a tick and
        // an idle loop has no other wake.
        const waiting = self.session.dirty or
            self.session.animating() or
            self.escape_deadline_ms != null;
        if (waiting and !self.tick_pending) self.armTick();
    }
}

/// The state that Herdr shows for this pane, read from the model after a batch.
/// A turn works. A failed turn that waits for Ctrl+N blocks, because the user
/// must decide on it. Everything else, the pickers included, is idle.
fn herdrState(self: *const App) Herdr.State {
    if (self.session.mode == .turn) return .working;
    if (self.retry != null) return .blocked;
    return .idle;
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
                // A checkout in another terminal shows on the next key. An idle
                // loop paints no frame, so the label waits for this wake.
                self.refreshBranch();
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
            .fetch_ended => |generation| try self.finishFetch(generation),
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
/// the deadline, not on a duration, so the arming time cannot drift the frame. A
/// cancel drops the tick. The deadline arrives by value, so the task reads no
/// state the consumer can write.
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
/// Each is the agent's own verdict on a reply, so it reads as a sentence and
/// never as an internal fault. Anything unmapped returns null, and the caller
/// wraps its error name.
fn turnFailureText(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoModel => no_model_refusal,
        error.UnsupportedReply => "Drinky cannot keep the response because the model returned " ++
            "a refusal, a pause, or an unsupported result.",
        error.EmptyReply => "The model returned an empty response.",
        error.IncompleteReply => "Drinky did not receive the complete model response.",
        error.UncorrelatedReply => "Drinky could not match a streamed part of the response to " ++
            "the item it belongs to. The provider changed the order of its stream.",
        error.TooManyToolRounds => "The turn reached the limit for tool rounds.",
        // The next step depends on the transition that follows this failure, so
        // the app names it in a later event.
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

/// The active account, or null when the agent is signed out.
fn activeAccount(self: *const App) ?ai.llm.Account {
    const client = self.agent.client orelse return null;
    return client.account();
}

/// Whether an account is active. Drinky refuses normal messages until a login.
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

/// The model `account` runs: the one it ran last in this project, else none. A
/// model belongs to the account that ran it, so another account starts on its
/// own last model. Startup, a switch, and a login all read this one rule.
///
/// `state` remembers a name alone, and the catalog says what that name is. A
/// name the account no longer offers, and an account that no fetch ran for,
/// resolve to no model, so the user picks one with `/model`.
fn accountModel(self: *const App, account: ai.llm.Account) ?ai.Model {
    const remembered = self.state.models.get(account) orelse return null;
    return self.accounts.findModel(account, remembered.name());
}

/// The effort level to start on: the one this project used last, else the
/// `configured` default, else the compiled fallback.
fn startEffort(self: *const App, configured: ?ai.llm.Effort) ai.llm.Effort {
    return self.state.start.effort orelse configured orelse effort_default;
}

/// Decode a stdin chunk into key events and apply each. An exit key that returns
/// the session to the prompt ends the chunk and drops the keys behind it. Those
/// keys are the rest of one exit attempt, such as `\x1b\x04` from a terminal
/// without the Kitty protocol, and Ctrl+D at the prompt quits Drinky.
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
    const at_prompt = self.session.mode == .prompt;
    // A refused command line goes to the model on the next Enter alone. The prompt
    // sends it, and a turn queues it, so both modes can confirm.
    const confirms_message = (at_prompt or self.session.mode == .turn) and event.* == .enter;
    if (!confirms_message) self.session.cancelConfirmation(.message);
    // Only a second Esc during a turn can confirm the turn-cancel warning. Every
    // other user action clears the warning and its one-shot confirmation.
    const confirms_turn_cancel = self.session.mode == .turn and event.* == .escape;
    if (!confirms_turn_cancel) self.session.cancelConfirmation(.turn_cancel);
    // Only a second Ctrl+D at the prompt can confirm the quit warning. Every
    // other user action clears the warning and its one-shot confirmation.
    const confirms_quit = at_prompt and event.* == .ctrl and event.ctrl == 'd';
    if (!confirms_quit) self.session.cancelConfirmation(.quit);
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
        // Esc owns the waiting retry, and it keeps the editor text.
        .escape => self.clearRetry(),
        .ctrl => |letter| switch (letter) {
            'c' => {
                self.clearOrQuit();
                if (self.running) self.session.dirty = true;
            },
            // Ctrl+D quits at once on an empty editor. A draft arms a one-shot
            // confirmation and warns instead, because the quit discards it. The
            // second Ctrl+D quits anyway.
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
            'n' => try self.retryTurn(),
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

/// Keys during a streaming turn. The editor stays live: Enter queues steering,
/// and Ctrl+P recalls the queue. Esc and Ctrl+D cancel the turn and keep the
/// draft. Esc warns first over a draft, because a reflex Esc while the user
/// types can mean a dismiss or a clear. Ctrl+D cancels at once, so the legacy
/// exit attempt Esc+Ctrl+D still works. Ctrl+C clears a draft first.
fn handleTurnKey(self: *App, event: *const terminal.Input.Key) !void {
    if (try self.editKey(event)) return;
    switch (event.*) {
        .enter => try self.submitSteering(),
        .escape => try self.warnOrCancel(),
        .ctrl => |letter| switch (letter) {
            'c' => try self.clearOrCancel(),
            // Ctrl+D cancels the turn at once.
            'd' => try self.cancelTurn(),
            'p' => try self.pullSteering(),
            else => {},
        },
        else => {},
    }
}

/// Esc during a turn: cancel at once when the editor is empty, because an Esc
/// there is a decision. A draft signals that the user types, and a reflex Esc
/// while typing must not stop the turn, so it arms a one-shot confirmation and
/// warns instead. The second Esc cancels the turn and keeps the draft.
fn warnOrCancel(self: *App) !void {
    if (self.session.editor.visible().len == 0 or self.session.takeConfirmation(.turn_cancel))
        return self.cancelTurn();
    self.session.armConfirmation(.turn_cancel);
    try self.reportNotice(.warning, "Press Esc again to cancel the turn. The draft stays.", .{});
}

/// Ctrl+C during a turn: clear a draft, or cancel the turn when the editor is
/// empty. The editor stays live for steering, so the key that stops the turn must
/// not drop typed text. Esc cancels and keeps the draft instead.
fn clearOrCancel(self: *App) !void {
    if (self.session.editor.visible().len != 0) {
        self.session.editor.clear();
        self.session.markEdited();
        return;
    }
    try self.cancelTurn();
}

/// Enter during a turn: queue the line as steering. No command runs mid-turn,
/// because a command can open a picker that a turn cannot host. A line the
/// registry cannot run as typed keeps its refusal, which arms one Enter to queue
/// it as steering. A runnable command has no such arm, because the next Enter
/// runs it once the turn ends.
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
            return self.refuseCommand(name, "while a turn runs");
        }
    }
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

/// Return steering the worker never took before the turn ended. The user wrote
/// it against an unfinished reply, so it can depend on work the final reply
/// changed. The drafts go back above the in-progress line for review instead of
/// starting a turn on their own.
fn returnLateSteering(self: *App) !void {
    // Reserve every possible draft move so no fallible work follows the channel
    // take.
    try self.session.reserveSteeringRecall();
    const taken = try self.agent.steering.take();
    defer {
        for (taken) |message| self.gpa.free(message);
        self.gpa.free(taken);
    }
    // The mirror and the channel always move together, and a completed turn
    // exits with no consumed-but-uncommitted batch, so the counts match here.
    std.debug.assert(taken.len == self.session.steering.items.len);
    self.session.recallLateSteering();
    try self.reportNotice(.information, "Drinky returned every queued message to the editor.", .{});
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
            // The user stopped this turn, so it arms no retry.
            _ = self.takeTurnRetry();
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
            _ = self.takeTurnRetry();
            try self.session.endTurnWithReceipt(&result.outcome.receipt);
        },
    }
}

/// After the join of a canceled worker, consume its queued progress and preserve
/// all non-turn events as a prefix for the normal loop. When history committed
/// nothing, progress needs only deinitialization because the transcript rewinds
/// to the turn base. Returns the first error after it owns and frees every
/// event, so the caller can finish cancellation before the error propagates.
fn drainCanceledProgress(self: *App, apply_progress: bool) ?anyerror {
    // A second cancellation can occur inside the same buffered key event after a
    // first drain has created this prefix. Leave newer queue data in place until
    // the loop consumes the prefix rather than exceed its bounded storage.
    if (self.deferred_event_count > 0) return null;

    var batch: [queue_capacity]Session.UiEvent = undefined;
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

/// Ctrl+C: clear the editor, or quit when pressed twice inside the window.
/// The clear takes no warning, because the clear is the purpose of the key and
/// not a side effect. Measured on the monotonic clock. A wall-clock step must
/// not fake or break the double press.
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
    // The session does no io, so the driver hands it both clocks every frame.
    self.session.clock_ms = self.nowMs();
    self.session.boot_clock_ms = self.nowBootMs();
    try self.session.paint(size);
}

/// Milliseconds on the monotonic clock that stops with a suspended system. It
/// drives every span the interface measures against work of its own: the double
/// Ctrl+C window, the escape wait, and the frame clock the io-free session
/// reads. A tool measures its own timeout on this clock, so a running row and
/// its timeout stay one measure.
fn nowMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

/// Milliseconds on the monotonic clock that counts a suspended system too. It
/// ages a span that a server measures, which keeps running while the machine
/// sleeps. The quota countdown is the one such span.
fn nowBootMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .boot).toMilliseconds();
}

/// Nanoseconds on the monotonic clock that stops with a suspended system, for
/// frame scheduling. A machine that sleeps owes no frame for that sleep.
fn nowNs(self: *App) i96 {
    return std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
}

/// Enter while idle: run a command line locally, or start a turn over the prompt.
/// Every line that starts with a slash is a command line, so Drinky reads it locally
/// first. A line the registry refuses stays in the editor and arms one Enter, which
/// sends that line to the model as typed.
fn submit(self: *App) !void {
    if (self.session.editor.blank()) {
        self.session.cancelConfirmation(.message);
        return;
    }
    const text = try self.session.editor.expanded(.whole_prompt);
    defer self.gpa.free(text);
    self.session.dirty = true;

    // A confirmed line skips the registry and reaches the model as typed. Without
    // that confirmation, the registry decides first: a line it cannot run keeps its
    // own refusal and arms the next Enter, so plain text that starts with a slash
    // still has a way out.
    const message_confirmed = self.session.takeConfirmation(.message);
    if (!message_confirmed) {
        if (try self.checkCommand(text)) |refusal|
            return self.armMessageSend(refusal, "Send as a message");
        if (try self.dispatchCommand(text)) |outcome|
            return self.applySubmittedCommand(outcome);
    }
    // A refused send starts no turn, so the editor keeps every byte the user
    // typed. The same Enter sends that line once the account and the model
    // stand.
    if (!self.signedIn()) return self.reportNotice(
        .failure,
        "Sign in with /login before you send a message.",
        .{},
    );
    if (self.agent.model == null) return self.reportNotice(.failure, no_model_refusal, .{});
    const base = try self.startUserTurn(text);
    // The turn is live and owns its own copy. Retain the prompt's rich draft
    // so an abnormal exit that commits nothing can return it. Leave the
    // editor empty for in-progress text. Both steps are infallible, so the
    // rollback above stays correct.
    var prompt = self.session.editor.detachTrimmed();
    self.session.retainTurnPrompt(&prompt, base);
}

/// Apply the outcome of a submitted command line.
fn applySubmittedCommand(self: *App, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        // A skill line starts its own turn, so it keeps the editor's rich draft.
        // A refused line starts none, so the editor keeps that draft as typed.
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
                // The line reproduces this request, so a failure that commits
                // nothing returns it to the editor like any other human request.
                var draft = self.session.editor.detachTrimmed();
                self.session.retainTurnPrompt(&draft, base);
            }
        },
        // The registry accepted the line, so this refusal is a command that broke.
        // Another try is the way forward, so the line stays in the editor.
        .refusal => try self.applyOutcome(outcome),
        // Every other command clears the editor first.
        else => {
            self.session.editor.clear();
            try self.applyOutcome(outcome);
        },
    }
}

/// Report a registry refusal and arm one Enter to send the line to the model as
/// typed. `action` names what that Enter does, so the row reads as a control hint.
/// The refusal keeps the line in the editor, which the arm needs, because the
/// confirmation drops on every other key, at the end of a turn, and under any later
/// notice that replaces the row.
fn armMessageSend(
    self: *App,
    refusal: ai.command.Outcome.Message,
    action: []const u8,
) !void {
    defer self.gpa.free(refusal.content);
    // Arm last, so a failed notice leaves no offer that the row never showed.
    try self.reportNotice(refusal.severity, "Enter: {s} · {s}", .{ action, refusal.content });
    self.session.armConfirmation(.message);
}

/// Record the user message of one skill invocation, then spawn the turn over
/// the expanded skill content. Returns the rich draft's rewind checkpoint.
fn startSkillTurn(self: *App, prompt: *const ai.command.Outcome.Prompt) !usize {
    const base = try self.appendSkillPrompt(prompt);
    errdefer self.session.transcript.truncate(base);
    // The turn sends the whole skill file as one user message, so the guard
    // finds its own proof in the history. Nothing marks a skill by hand.
    try self.runTurn(prompt.content);
    self.session.dirty = true;
    return base;
}

/// Record what one skill invocation sends. The request is one user message, and
/// the transcript splits it into what Drinky sent and what the user typed: the
/// head that names the skill and its file, then the task in a user box below
/// it. The expanded file stays out of the transcript, because the head reports
/// where it comes from.
///
/// The head is no box, so a message that the user types cannot look like one.
/// Only this path writes a head, and the model reads the file that it names.
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

/// The head line of one skill invocation: `Skill: {name} · File: {path}`. It
/// reads like a tool box head, and it takes one row that a narrow window cuts.
/// The result is owned.
fn skillHead(self: *App, prompt: *const ai.command.Outcome.Prompt) ![]u8 {
    const source = try ai.format.path(self.gpa, prompt.source, &self.displayRoots());
    defer self.gpa.free(source);
    return std.fmt.allocPrint(self.gpa, "Skill: {s} · File: {s}", .{ prompt.name, source });
}

/// The roots every path in the interface is measured against.
fn displayRoots(self: *const App) ai.format.Roots {
    return .{ .working_directory = self.working_directory, .home_directory = self.home_directory };
}

/// Record a plain user message and spawn its turn. Returns the rich draft's
/// rewind checkpoint.
fn startUserTurn(self: *App, text: []const u8) !usize {
    const base = self.session.transcript.blocks().len;
    try self.session.transcript.append(.user, .{}, text);
    errdefer self.session.transcript.truncate(base);
    try self.runTurn(text);
    self.session.dirty = true;
    return base;
}

/// Ctrl+N at the prompt: send one retry attempt. The attempt carries the failure
/// alone, so the editor keeps every byte it holds. A user who wants that text in
/// the conversation sends it with Enter, before the attempt or as steering during
/// it. A prompt with no waiting retry has nothing to send.
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

/// Spawn one attempt, past the gate above. The two statements pair, so they
/// stay in one place. A test drives this half with a signed-out agent, because
/// the worker then fails fast instead of reaching the network.
fn sendRetryTurn(self: *App) !void {
    const base = try self.startRetryTurn();
    // The editor holds no part of this attempt, so the rewind anchor stands alone.
    self.session.markTurnBase(base);
}

/// Send one retry attempt: record the line that names it, then spawn its turn
/// over the generated request. The attempt carries no user text, so its turn
/// takes the context and the next failure arms a fresh one that names its own
/// error. Returns the rewind checkpoint of that line.
fn startRetryTurn(self: *App) !usize {
    std.debug.assert(self.retry != null);
    const retry = &self.retry.?;
    const text = try retry.compose(self.gpa);
    defer self.gpa.free(text);
    const base = self.session.transcript.blocks().len;
    errdefer self.session.transcript.truncate(base);
    // Drinky wrote this user message, so its line takes the user color, like the
    // head of a loaded skill. The complete request stays out of the transcript,
    // as a skill head keeps its expanded file out of it.
    try self.session.transcript.append(.user_note, .{}, Retry.note_text);
    // The spawn drops the context, so the flag marks the attempt after it.
    try self.runTurn(text);
    // A failure of this attempt arms the context again from its own error.
    self.turn_retry = true;
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
    const generation = try reserveGeneration(&self.turn_generation);
    const owned = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(owned);
    self.turn_future = try self.io.concurrent(runTurnWorker, .{ self, owned, generation });
    self.session.beginTurn(generation);
    // Every turn start takes the waiting retry, not the attempt alone. A message
    // that the user sends instead of the attempt moves the conversation on, so the
    // context it named is stale. The drop runs after the spawn, because a start
    // that fails must leave the context for another try.
    self.setRetry(null);
}

/// Permanently reserve the next generation of `counter` before a worker can
/// observe it. A failed allocation or spawn can leave a gap, but the app never
/// reuses a generation.
fn reserveGeneration(counter: *u64) error{GenerationExhausted}!u64 {
    if (counter.* == std.math.maxInt(u64)) return error.GenerationExhausted;
    counter.* += 1;
    return counter.*;
}

/// Start the model fetch that a picker row asked for, on a worker, so the
/// interface keeps painting and reading keys. The picker clears its rows
/// meanwhile, and `finishFetch` rebuilds it from the result. The worker owns the
/// account registry until the join, and the picker mode admits no command, so
/// no consumer step reads the registry under it.
fn startFetch(self: *App, account: ai.llm.Account) !void {
    std.debug.assert(self.fetch == null);
    std.debug.assert(self.session.mode == .picking);
    const generation = try reserveGeneration(&self.fetch_generation);
    const future = try self.io.concurrent(runFetchWorker, .{ self, account, generation });
    self.fetch = .{ .future = future, .account = account, .generation = generation };
    errdefer self.dropFetch();
    try self.session.beginPickerWait(fetch_wait_text);
}

/// Fetch worker task: run one fetch, queue its wakeup, and return the sole
/// result. A canceled or closed channel drops the wakeup, and the join still
/// holds the result.
fn runFetchWorker(self: *App, account: ai.llm.Account, generation: u64) ai.Accounts.Refresh {
    const result = self.accounts.refresh(account);
    self.queue.putOne(self.io, .{ .fetch_ended = generation }) catch {};
    return result;
}

/// Join the fetch of `generation` at its wakeup and rebuild the picker from the
/// result, as a confirmed row does. A wakeup of a fetch that a cancel already
/// joined names a stale generation, so it changes nothing.
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

/// Esc during a fetch: stop the worker, then rebuild the step that asked for it,
/// so the rows return. The fetch is the one thing this exit ends. The notice
/// states the cancel, because a list that looks unchanged reads as a fetch that
/// found nothing new.
fn cancelFetch(self: *App) !void {
    self.dropFetch();
    const opener = self.session.mode.picking.reopen orelse return self.session.cancelPicker();
    var context = self.commandContext();
    const outcome = try opener(&context);
    if (!keepsPicker(outcome)) self.session.closePicker();
    try self.applyOutcome(outcome);
    try self.reportNotice(.information, "You canceled the model fetch.", .{});
}

/// Cancel and join the fetch worker, if one runs, and forget it. The result is
/// discarded: the catalog already holds whatever arrived, and the step that
/// follows reads the catalog.
fn dropFetch(self: *App) void {
    const fetch = if (self.fetch) |*fetch| fetch else return;
    _ = fetch.future.cancel(self.io);
    self.fetch = null;
}

/// The ambient state that every command handler reads.
fn commandContext(self: *App) ai.command.Context {
    return .{
        .gpa = self.gpa,
        .io = self.io,
        .agent = &self.agent,
        .accounts = &self.accounts,
        .skill_registry = &self.skills,
    };
}

/// Run `line` as a command. Null reports that the line is a message.
fn dispatchCommand(self: *App, line: []const u8) !?ai.command.Outcome {
    var context = self.commandContext();
    return ai.command.run(&context, line);
}

/// The registry refusal for `line`, with no command run. Null reports that the
/// registry can run the line as typed, so an active state restriction owns the
/// refusal instead.
fn checkCommand(self: *App, line: []const u8) !?ai.command.Outcome.Message {
    var context = self.commandContext();
    return ai.command.check(&context, line);
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
        .show_system_prompt => try self.session.openPage(&.{
            .title = "System prompt",
            .content = self.prompt,
        }),
        .new_conversation => {
            // The agent drops its history, and the session drops the blocks
            // that project it, so the worker and the screen empty together.
            // The agent's rollback forgets the skill proof memo with the
            // history that proved it.
            self.agent.resetConversation();
            self.session.clearConversation();
            // The intro line is the legend of the interface, so the empty
            // conversation opens on it again. The source summary does not
            // return, because it reports the discovery of one start alone.
            try self.session.transcript.append(.intro, .{}, intro_text);
            // The cleared conversation holds no work to continue from.
            self.clearRetry();
        },
        // Only `submit` produces a prompt outcome (from a typed `/skill:` line),
        // and it starts that turn itself, so a prompt never reaches this shared
        // path. A prompt routed here skips the editor's rich draft. The command
        // list runs a registry entry through this path, so no listed command may
        // return a prompt: the `/skill` row writes an editor line instead.
        .prompt => unreachable,
        .login => |account| try self.loginAccount(account),
        .logout => |account| try self.logoutAccount(account),
        .switch_account => |account| {
            self.adopt(account);
            if (self.agent.model) |model| {
                try self.recordEvent(
                    .information,
                    "Drinky now uses {s} with {s}.",
                    .{ model.name(), account.label() },
                );
            } else {
                try self.reportModelStep(account, "Drinky now uses {s}. ", .{account.label()});
            }
        },
        // A fetch asks the provider with the credential of its account, so it
        // meets the same principal boundary as a turn. The transition is
        // therefore the one a turn takes, and the report is its own, because no
        // turn ran. It mirrors the agent itself, so the shared mirror below must
        // not run a second time.
        .credential_replaced => |account| return self.acceptFetchReplacement(account),
        // The fetch starts and changes nothing yet, so no mirror runs. Its
        // result arrives through `finishFetch`, which applies its own outcome.
        .fetch => |account| return self.startFetch(account),
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
    // The account, the model, and the effort select the transcript projection
    // too, so a change repaints the conversation that the next request carries.
    self.session.showSetup(self.activeAccount(), self.agent.model, self.agent.effort);
    try self.recordState();
}

/// Remember the account, model, and effort level this project now uses. Only a
/// change writes the file, and a failed write never stops the session. A
/// signed-out session records nothing, because the entry names an account. A
/// signed-out effort change stays in the agent until the next sign-in records it.
fn recordState(self: *App) !void {
    const account = self.activeAccount() orelse return;
    self.state.record(account, self.agent.model, self.agent.effort) catch |err|
        try self.reportStateSaveFailure(err);
}

/// Report one failed write of the project state file.
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

/// Log in to `account`, then switch to it on the model it ran last here. An
/// account that ran none, and a name it no longer offers, leave the session
/// with no model, and the report names `/model`.
/// A pre-commit failure leaves the current account untouched. After the
/// credential replacement, account readiness and replay invalidation complete
/// before any fallible final presentation.
fn loginAccount(self: *App, account: ai.llm.Account) !void {
    // The input reader task owns stdin. Pause it for the whole cooked window,
    // so no line the user types there reaches the key queue. The paste watch is
    // the only reader of that window. The resume runs after the raw-mode
    // restore below, because the two defers unwind in reverse.
    const input_live = self.input_future != null;
    self.cancelFuture(&self.input_future);
    defer if (input_live) self.resumeInputReader();
    self.tty.leaveRaw();
    defer {
        self.tty.enterRaw() catch {};
        self.session.view.invalidate();
        self.session.dirty = true;
    }
    var prompt: OauthPrompt = .{ .writer = self.tty.writer(), .io = self.io };
    const login = self.runLogin(account, &prompt) catch |login_error|
        return self.reportLoginFailure(login_error);

    // A fresh login can represent another principal in the same account slot.
    // Nothing that principal produced crosses that boundary.
    self.dropAccountEvidence(account);
    self.adopt(account);
    switch (login) {
        .saved => |path| try prompt.showAuthorized(path),
        .memory_only => |failure| try prompt.showSaveFailed(
            failure.path,
            @errorName(failure.save_error),
        ),
    }
    if (self.agent.model) |model| {
        try self.recordEvent(
            .information,
            "Drinky signed in to {s} and selected {s}.",
            .{ account.label(), model.name() },
        );
    } else {
        try self.reportModelStep(account, "Drinky signed in to {s}. ", .{account.label()});
    }
    switch (login) {
        .saved => {},
        .memory_only => |failure| try self.recordEvent(
            .failure,
            "Drinky could not save the credentials for {s} to {s} because of error {s}. " ++
                "The sign-in stays active until Drinky exits.",
            .{ account.label(), failure.path, @errorName(failure.save_error) },
        ),
    }
}

/// Run the blocking OAuth login as a worker task and watch the cooked
/// terminal meanwhile. A browser that a policy blocks (an HTTPS-Only mode)
/// shows an error page whose address bar still holds the callback URL. A
/// paste of that URL replays into the same listener, so one wait serves both
/// paths. Without a port or without concurrency the login runs plain, with no
/// paste path.
fn runLogin(self: *App, account: ai.llm.Account, prompt: *OauthPrompt) !ai.Accounts.Login {
    const port = ai.Accounts.callbackPort(account) orelse
        return self.accounts.login(account, prompt);
    var worker: LoginWorker = .{
        .accounts = &self.accounts,
        .account = account,
        .prompt = prompt,
    };
    // Enabled before the worker starts, so the prompt it prints can promise
    // the paste path only when the watch below really runs.
    prompt.paste_enabled = true;
    var future = self.io.concurrent(LoginWorker.run, .{&worker}) catch {
        prompt.paste_enabled = false;
        return self.accounts.login(account, prompt);
    };
    self.watchForPaste(&worker.done, port, prompt);
    return future.await(self.io);
}

/// Start the input reader task. Startup propagates a failure, and a resume
/// degrades instead, so the two callers own their own policies.
fn startInputReader(self: *App) !void {
    self.input_future = try self.io.concurrent(readInput, .{self});
}

/// Restart the input reader task after a pause. A failed restart closes the
/// queue, so the main loop winds down instead of running deaf.
fn resumeInputReader(self: *App) void {
    self.startInputReader() catch self.queue.close(self.io);
}

/// Watch the cooked terminal during the login wait, and replay each pasted
/// callback URL to the local listener on `port`. The loop is an event wait:
/// `done` flips when the login worker finishes, and the worker's own callback
/// deadline bounds that. A closed stdin or a read fault stops the watch
/// alone, and the login wait continues.
fn watchForPaste(
    self: *App,
    done: *const std.atomic.Value(bool),
    port: u16,
    prompt: *OauthPrompt,
) void {
    // The poll bounds the exit lag after `done` flips. A paste is a human
    // action, so 200 ms costs nothing perceptible and saves a third
    // concurrent task with its cancellation path.
    const poll: std.Io.Timeout =
        .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } };
    var splitter: PasteSplitter = .{};
    var handler: PasteHandler = .{ .io = self.io, .port = port, .prompt = prompt };
    var buffer: [512]u8 = undefined;
    while (!done.load(.acquire)) {
        const result = self.tty.read(&buffer, poll) catch {
            prompt.showPasteStopped() catch {};
            return;
        };
        const count = result orelse continue;
        splitter.feed(buffer[0..count], &handler);
    }
}

fn reportLoginFailure(self: *App, login_error: anyerror) !void {
    const message = switch (login_error) {
        error.Canceled => return error.Canceled,
        error.CallbackTimeout => "Drinky stopped the sign-in because the browser did not " ++
            "respond in time.",
        error.CallbackRequestTooLarge => "Drinky could not sign in because the browser " ++
            "response was too large.",
        error.CallbackTimeoutUnavailable => "Drinky could not sign in because it could not " ++
            "set a browser time limit.",
        // The redirect reports a refusal, a scope fault, and a provider fault
        // under one parameter. The code of the failure reaches no report, so
        // one sentence covers the whole set.
        error.AuthorizationFailed => "The provider did not authorize Drinky. " ++
            "Start the sign-in again.",
        // The redirect carries the state of an earlier sign-in. A tab left open
        // and a paste of its URL both deliver one, so the sentence names no
        // source.
        error.StateMismatch => "The response belongs to another sign-in. " ++
            "Start the sign-in again.",
        // The exchange rejects an authorization that expired or was used before.
        error.TokenGrantRejected => "The provider rejected the authorization. " ++
            "Start the sign-in again.",
        error.TokenServiceUnavailable => "The provider credential service is not available. " ++
            "Try the sign-in again later.",
        else => return self.reportNotice(
            .failure,
            "Drinky could not sign in because of error {s}.",
            .{@errorName(login_error)},
        ),
    };
    return self.reportNotice(.failure, "{s}", .{message});
}

/// Whether `account` is the account the agent runs, so a change to its
/// credential moves the active agent.
fn isActive(self: *const App, account: ai.llm.Account) bool {
    return self.activeAccount() == account;
}

/// Report the step that follows a credential transition of `account`. A session
/// with no model runs no turn, so that report names the model step in place of
/// the retry. The armed retry waits behind Ctrl+N until a model makes it
/// runnable.
fn reportCredentialStep(self: *App, account: ai.llm.Account, comptime lead: []const u8) !void {
    if (self.agent.model == null) return self.reportModelStep(account, lead, .{});
    return self.recordEvent(.information, lead ++ "Try the turn again.", .{});
}

/// Report one transition that leaves the session with no model. `lead` states
/// what changed, and the step that follows unblocks `account`. The arguments of
/// `lead` come first, and the label of `account` closes the line.
///
/// The catalog answers the step alone. An account whose list stands cached
/// needs a pick, and an account with no list needs a fetch first. The project
/// memory says nothing here, because one machine caches every list and each
/// project remembers its own model.
fn reportModelStep(
    self: *App,
    account: ai.llm.Account,
    comptime lead: []const u8,
    lead_args: anytype,
) !void {
    if (self.accounts.offersModel(account)) return self.recordEvent(
        .information,
        lead ++ "Select a model of {s} with /model.",
        lead_args ++ .{account.label()},
    );
    return self.recordEvent(
        .information,
        lead ++ "Fetch the model list of {s} with /model.",
        lead_args ++ .{account.label()},
    );
}

/// Settle the session on a credential that the store identifies as another
/// principal. The worker stopped before its provider request, so the evidence
/// and the metadata of the replaced principal go first. The metadata holds the
/// model list of the account, so that account offers no model until the next
/// fetch.
///
/// Each entry reports its own step, because a turn and a fetch leave the user
/// at a different place.
fn settleCredentialReplacement(self: *App, account: ai.llm.Account) void {
    self.accounts.dropPrincipalMetadata(account);
    self.dropAccountEvidence(account);
    if (self.isActive(account)) self.adopt(account);
}

/// Accept the replacement that a turn met. That turn failed on the account it
/// ran, so the report names the retry where a model stands, and the model step
/// where none does.
fn acceptCredentialReplacement(self: *App, account: ai.llm.Account) !void {
    self.settleCredentialReplacement(account);
    try self.reportCredentialStep(account, "");
    try self.mirrorAgentState();
}

/// Accept the replacement that a model fetch met. No turn ran, and `account`
/// can be one that the session does not run, so the report names no retry. It
/// states the replacement and the dropped evidence, then the step of the
/// fetched account alone.
fn acceptFetchReplacement(self: *App, account: ai.llm.Account) !void {
    self.settleCredentialReplacement(account);
    try self.reportModelStep(
        account,
        "Drinky found a replacement credential for {s}. " ++
            "Drinky removed the prior account evidence. ",
        .{account.label()},
    );
    try self.mirrorAgentState();
}

/// Resolve a rejected refresh credential: reload a replacement that another
/// instance saved, else leave the account and select the next one. Either way
/// the credential changes principal, so the reasoning evidence of the account
/// goes before the two paths divide.
fn rejectCredential(self: *App, account: ai.llm.Account) !void {
    const adopts = self.isActive(account);
    var maybe_removal_error: ?anyerror = null;
    const recovered = self.accounts.invalidate(account) catch |err| failure: {
        maybe_removal_error = err;
        break :failure false;
    };
    self.dropAccountEvidence(account);
    if (recovered) {
        // `invalidate` dropped the model list of the replaced credential, so the
        // model resolves again before the session shows it. That list belongs to
        // the principal behind that credential, so the account offers no model
        // until the next fetch.
        if (adopts) self.adopt(account);
        try self.reportCredentialStep(
            account,
            "Drinky reloaded the refresh credential that another Drinky instance saved. ",
        );
        return self.mirrorAgentState();
    }

    // The agent settles before any fallible report. A conversation that keeps
    // its own account moves nothing, so it needs no next account.
    const maybe_next = if (adopts) self.handOff() else null;

    if (maybe_removal_error) |removal_error| try self.recordEvent(
        .failure,
        "Drinky could not remove the rejected credential for {s} because of error {s}.",
        .{ account.label(), @errorName(removal_error) },
    );
    if (!adopts) {
        try self.recordEvent(.information, "Drinky signed out of {s}.", .{account.label()});
        return self.mirrorAgentState();
    }
    try self.reportHandOff(account, maybe_next);
    try self.mirrorAgentState();
}

/// Move the session off its account: adopt the first authenticated account, or
/// sign out when none remains. Returns the account that took the session.
fn handOff(self: *App) ?ai.llm.Account {
    const maybe_next = self.accounts.firstAuthenticated();
    if (maybe_next) |next| self.adopt(next) else self.agent.signOut();
    return maybe_next;
}

/// Report where the session went after `account` left it. The next account
/// starts on the model it ran last here, and on no model where it ran none, so
/// that report names `/model`. When no account remains, the login picker opens
/// so the user chooses how to sign back in.
fn reportHandOff(self: *App, account: ai.llm.Account, maybe_next: ?ai.llm.Account) !void {
    const next = maybe_next orelse {
        try self.recordEvent(
            .information,
            "Drinky signed out of {s}. Select an account to sign in.",
            .{account.label()},
        );
        return self.openLoginPicker();
    };
    if (self.agent.model) |model| return self.recordEvent(
        .information,
        "Drinky signed out of {s}. Drinky now uses {s} with {s}.",
        .{ account.label(), model.name(), next.label() },
    );
    return self.reportModelStep(
        next,
        "Drinky signed out of {s}. Drinky now uses {s}. ",
        .{ account.label(), next.label() },
    );
}

/// Open the login picker through the session alone. A route through
/// `applyOutcome` cycles the inferred error sets of `logoutAccount` back to
/// itself.
fn openLoginPicker(self: *App) !void {
    if (try self.dispatchCommand("/login")) |outcome| try self.session.applyOutcome(outcome);
}

/// Drop `account`'s credentials. A logout of the active account hands the
/// session to the next authenticated account, or to the login picker when none
/// remains. Commands cannot run mid-turn, so this never races a turn.
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
        return self.recordEvent(.information, "Drinky signed out of {s}.", .{account.label()});
    try self.reportHandOff(account, self.handOff());
}

/// Switch the agent to `account` on the model that account ran last, and on no
/// model where it ran none. The client is present because the caller just
/// authenticated the account or read it from the registry.
fn adopt(self: *App, account: ai.llm.Account) void {
    self.agent.switchTo(self.accounts.client(account).?, self.accountModel(account));
}

/// Forget everything the principal behind `account` produced: the replay proofs
/// in history, and the reasoning blocks that hold them in the transcript. Both
/// sides drop together, so the interface never shows a block that no request
/// carries.
fn dropAccountEvidence(self: *App, account: ai.llm.Account) void {
    self.agent.dropAccountEvidence(account);
    self.session.dropAccountReasoning(account);
}

/// The shared refusal path for a command that the active state does not allow.
/// Drinky keeps the command text in the editor, sends nothing to the model, and
/// opens no picker. The notice names the command and the restriction, and it
/// warns rather than reports a failure, because a later Enter still runs the line.
fn refuseCommand(self: *App, name: []const u8, restriction: []const u8) !void {
    const refusal = try ai.command.refuse(self.gpa, name, restriction);
    try self.session.applyOutcome(.{ .refusal = refusal });
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

/// Record one source summary for the guidance that Drinky holds, then report
/// what each source skipped. The summary describes startup state, not an event.
/// It uses dense count fragments because a normal load needs no action.
/// `/system` shows each counted path. A run with no guidance and no skipped file
/// records nothing.
fn reportSources(self: *App, sources: *const Sources) !void {
    var line: std.Io.Writer.Allocating = .init(self.gpa);
    defer line.deinit();
    const user_count = sources.user_instructions.files().len;
    const project_count = sources.project_instructions.files().len;
    if (user_count > 0 or project_count > 0) {
        try line.writer.writeAll("Instructions:");
        if (user_count > 0) try line.writer.print(" {d} user", .{user_count});
        if (user_count > 0 and project_count > 0) try line.writer.writeByte(',');
        if (project_count > 0) try line.writer.print(" {d} project", .{project_count});
    }
    // The catalog counts the skills the model can see, which is what `/system`
    // shows. Drinky only finds a skill here and advertises its name and its
    // description. The instructions stay on disk until the skill runs. A
    // project skill that replaces a user skill of the same name is the
    // documented precedence, and a required skill that this project does not
    // carry is normal under a global config. Both are counts, not warnings,
    // and both repeat in a stable setup, so they must stay this small.
    const skill_count = sources.skills.catalog().count();
    const replaced_count = sources.skills.replacedCount();
    const missing_count = sources.required_missing_count;
    if (skill_count > 0 or missing_count > 0) {
        if (line.written().len > 0) try line.writer.writeAll(" · ");
        try line.writer.print("Skills: {d}", .{skill_count});
        if (replaced_count > 0 or missing_count > 0) {
            try line.writer.writeAll(" (");
            if (replaced_count > 0) try line.writer.print("{d} replaced", .{replaced_count});
            if (replaced_count > 0 and missing_count > 0) try line.writer.writeAll(", ");
            if (missing_count > 0) try line.writer.print("{d} missing", .{missing_count});
            try line.writer.writeByte(')');
        }
    }
    if (line.written().len > 0)
        try self.session.transcript.append(.source_summary, .{}, line.written());
    try self.reportNotices(sources.user_instructions.notices());
    try self.reportNotices(sources.project_instructions.notices());
    try self.reportNotices(sources.skills.notices());
}

/// Pair every configured path-triggered skill with a discovered skill and hand
/// the pair to the guard. The global config serves every project, so a name
/// that no skill here carries is a normal state. It returns the count of such
/// names for the source summary, because a typo in a name silently disables a
/// guard, and the system prompt names only the rules that resolved. An entry
/// past the cap drops with a failure.
///
/// The caller reports the messages once the transcript exists. The rules
/// themselves cannot wait that long, because the system prompt names them.
fn resolveRequiredSkills(
    self: *App,
    config: *const Config,
    notices: *std.ArrayList(ai.instructions.Notice),
) !usize {
    // The missing names, each once. Several patterns often share one skill,
    // and one name must not count once per pattern.
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(self.gpa);
    for (config.required_skills) |required| {
        const target = self.skills.get(required.skill) orelse {
            var seen = false;
            for (missing.items) |name| {
                if (std.mem.eql(u8, name, required.skill)) seen = true;
            }
            if (!seen) try missing.append(self.gpa, required.skill);
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
    return missing.items.len;
}

/// Retain one startup message that the transcript cannot take yet.
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
/// report. A page is read-only, so no key on it quits Drinky.
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
    if (self.session.pickerWaits()) return self.handleFetchKey(event);
    const picker = &self.session.mode.picking.picker;
    switch (event.*) {
        .up => try picker.moveUp(),
        .down => try picker.moveDown(),
        .enter => return self.confirmPicker(),
        .escape => return self.leavePicker(),
        .ctrl => |letter| switch (letter) {
            // Ctrl+C and Ctrl+D leave the whole command, however deep the step
            // is, so a stepped picker keeps a one-key way out.
            'c', 'd' => return self.session.cancelPicker(),
            else => return,
        },
        else => return,
    }
    self.session.dirty = true;
}

/// The keys of a picker that waits for a fetch. Esc cancels the fetch alone, and
/// the rows return. Ctrl+C and Ctrl+D leave the whole command, as they do from
/// any step, and take the fetch with it. Every other key does nothing, because
/// the list holds no row.
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

/// Apply the highlighted picker row: the command that opened the picker runs its
/// own handler over the selected row.
///
/// A row that opens another picker keeps this one open, because the replacement
/// records it on its trail. A row that starts a fetch keeps it too, because the
/// list waits for the result. Every other outcome ends the picker, so it closes
/// first.
fn confirmPicker(self: *App) !void {
    const picking = &self.session.mode.picking;
    const cursor = picking.picker.cursor;
    var context = self.commandContext();
    const outcome = try picking.select(&context, cursor);
    if (!keepsPicker(outcome)) self.session.closePicker();
    try self.applyOutcome(outcome);
}

/// Whether `outcome` continues inside the open picker.
fn keepsPicker(outcome: ai.command.Outcome) bool {
    return switch (outcome) {
        .pick, .fetch => true,
        else => false,
    };
}

/// Open the picker one step above, or cancel the command where the open picker is
/// its first step. One Esc per step therefore leaves a stepped command.
///
/// The mode stays `picking` on a step up, so `handleKeys` drains no key behind
/// that Esc and a fast repeat walks the whole way out.
fn leavePicker(self: *App) !void {
    const opener = self.session.stepAbove() orelse return self.session.cancelPicker();
    var context = self.commandContext();
    const outcome = try opener(&context);
    switch (outcome) {
        .pick => |*pick| try self.session.openPickerAbove(pick),
        // The step above reports instead of opening. That leaves no picker to
        // return to, so the command ends here.
        else => {
            self.session.closePicker();
            try self.applyOutcome(outcome);
        },
    }
}

/// Test scaffolding: an `App` on the defaults of `initFields`. A test builds the
/// `agent`, the `session`, the `accounts`, and the `tty` that it uses, and it
/// frees what a fed key or a loaded skill grows. `gpa` is a parameter so an OOM
/// test reaches every allocation through a `FailingAllocator`.
fn initForTest(self: *App, gpa: std.mem.Allocator) void {
    self.initFields(gpa, std.testing.io);
    // A test drives an app that already runs, so a key that quits can be seen.
    self.running = true;
}

/// Test scaffolding: assert that the agent runs the model that `expected` names.
/// An agent with no model fails the one test rather than aborting the binary.
fn expectModel(self: *const App, expected: []const u8) !void {
    const model = self.agent.model orelse return error.TestExpectedModel;
    try std.testing.expectEqualStrings(expected, model.name());
}

// The intro line is the legend of the interface. It holds every key hint in the
// order of the constant, and the pointer at the command list closes it. The line
// wraps, so its width costs no hint at a narrow window.
test "the intro line holds every key hint and closes on the command list" {
    try std.testing.expectEqualStrings(
        "Enter: Send · Shift+Enter: New line · Esc: Cancel · Ctrl+C: Clear · Ctrl+D: Quit · " ++
            "/help: Commands",
        intro_text,
    );
    try std.testing.expectEqual(@as(usize, 98), terminal.width.ofText(intro_text));
    for (intro_keys) |hint|
        try std.testing.expect(std.mem.indexOf(u8, intro_text, hint) != null);
}

test "OAuth prompts render runtime fields as inert text" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var prompt: OauthPrompt = .{ .writer = &out.writer, .io = std.testing.io };

    // Without a paste watch, the prompt must not promise the paste path.
    try prompt.showAuthorization("https://example.test/\x1b]52;c;b3duZWQ=\x07");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "paste the URL") == null);
    prompt.paste_enabled = true;
    try prompt.showAuthorization("https://example.test/\x1b]52;c;b3duZWQ=\x07");
    try prompt.showBrowserLaunchFailed();
    try prompt.showAuthorized("/home/\x1b[2J/.drinky/auth.json");
    try prompt.showSaveFailed("/home/\x1b[2J/.drinky/auth.json", "AccessDenied");
    try prompt.showPasteInvalid();
    try prompt.showPasteTooLong();
    try prompt.showPasteFailed("ConnectionRefused");
    try prompt.showPasteLate();
    try prompt.showPasteStopped();

    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "paste the URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "not the callback URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "too long for a callback URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "error ConnectionRefused") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "already received the response") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no longer reads") != null);
    const url_inert = "https://example.test/\u{200B}�\u{200B}]52;c;b3duZWQ=\u{200B}�\u{200B}";
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]52;c;b3duZWQ=\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, url_inert) != null);
    const path_inert = "/home/\u{200B}�\u{200B}[2J/.drinky/auth.json";
    try std.testing.expect(std.mem.indexOf(u8, written, path_inert) != null);
}

test "the paste watch assembles chunks into trimmed lines and drops a long line" {
    const Collector = struct {
        buffer: [256]u8 = undefined,
        length: usize = 0,
        long_line_count: usize = 0,

        fn onLine(self: *@This(), text: []const u8) void {
            @memcpy(self.buffer[self.length..][0..text.len], text);
            self.length += text.len;
            self.buffer[self.length] = '|';
            self.length += 1;
        }

        fn onLongLine(self: *@This()) void {
            self.long_line_count += 1;
        }
    };

    var splitter: PasteSplitter = .{};
    var collector: Collector = .{};
    // A line split across reads, cooked-terminal padding included. A blank
    // line reports nothing.
    splitter.feed("  https://localhost/callback?", &collector);
    splitter.feed("code=1&state=2 \r\nsecond\n\r\n", &collector);
    try std.testing.expectEqualStrings(
        "https://localhost/callback?code=1&state=2|second|",
        collector.buffer[0..collector.length],
    );
    try std.testing.expectEqual(@as(usize, 0), collector.long_line_count);
    // A line past the shared paste limit is dropped whole and the next line
    // still lands.
    const junk: [ai.oauth_callback.paste_bytes_max + 1]u8 = @splat('x');
    splitter.feed(&junk, &collector);
    splitter.feed("\nafter\n", &collector);
    try std.testing.expectEqual(@as(usize, 1), collector.long_line_count);
    try std.testing.expect(std.mem.endsWith(u8, collector.buffer[0..collector.length], "|after|"));
}

test "the paste handler reports each unusable line by its own cause" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var prompt: OauthPrompt = .{ .writer = &out.writer, .io = std.testing.io };
    const handler: PasteHandler = .{ .io = std.testing.io, .port = 1, .prompt = &prompt };

    // A line that holds no outcome asks for the complete URL. A dropped line
    // was too long for one, so it asks for the URL alone.
    handler.onLine("https://localhost:1455/auth/callback?code=without-state");
    handler.onLongLine();

    const written = out.written();
    const guidance = "not the callback URL";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, guidance));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "too long"));

    // The listener owns the denial verdict, so the handler replays an `error`
    // line and reports no guidance for it. Port 1 holds no listener, and a
    // refused connection means the listener already has its response.
    handler.onLine("https://localhost:1455/auth/callback?error=access_denied");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), guidance));
    try std.testing.expect(
        std.mem.indexOf(u8, out.written(), "already received the response") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "could not replay") == null);
}

test "a turn failure the agent named itself reads as a sentence, not an error name" {
    // A refusal or an unrecognized provider outcome is ordinary model behavior:
    // Drinky must not show the user a bare Zig error name for it.
    for ([_]anyerror{
        error.UnsupportedReply,
        error.EmptyReply,
        error.IncompleteReply,
        error.UncorrelatedReply,
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
    // A credential the turn can still use names the retry, not a sign-in.
    for ([_]anyerror{
        error.TokenServiceUnavailable,
        error.StoreBusy,
    }) |err| {
        const text = turnFailureText(err).?;
        try std.testing.expect(std.mem.indexOf(u8, text, "Try the turn again.") != null);
    }
    // A replacement runs before the transition that resolves the model, so the
    // app names the next step and this text names none.
    const replacement = turnFailureText(error.CredentialReplaced).?;
    try std.testing.expect(std.mem.indexOf(u8, replacement, "Try the turn again.") == null);
    try std.testing.expect(std.mem.indexOf(u8, replacement, "/model") == null);
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
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
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
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    // A rejection names the one action that helps. An unavailable service does
    // not, because the same sign-in works later.
    try app.reportLoginFailure(error.TokenGrantRejected);
    try std.testing.expectEqualStrings(
        "The provider rejected the authorization. Start the sign-in again.",
        app.session.notice.?.content,
    );
    try app.reportLoginFailure(error.AuthorizationFailed);
    try std.testing.expectEqualStrings(
        "The provider did not authorize Drinky. Start the sign-in again.",
        app.session.notice.?.content,
    );
    // A stale tab and a stale paste both deliver a redirect of an earlier
    // sign-in, so the sentence names neither source.
    try app.reportLoginFailure(error.StateMismatch);
    try std.testing.expectEqualStrings(
        "The response belongs to another sign-in. Start the sign-in again.",
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
        try app.reportLoginFailure(failure);
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

    // A pipe with a closed write end reports the end of its input, which is
    // what stdin reports once the terminal behind it is gone. `Tty.read` maps
    // that to an error, never to a zero-byte read, so the reader has one exit.
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);
    app.tty.io = io;
    app.tty.in_handle = fds[0];

    // The race bounds the reader, so a reader that fails to stop reads as a
    // failed test instead of a spin that never returns.
    const bounded = try ai.net.race(io, 2 * std.time.ms_per_s, readInput, .{&app});
    try bounded;

    // A closed queue winds the main loop down. An open queue leaves the session
    // waiting on a terminal that can never answer. A zero minimum makes the open
    // queue return immediately. The `error.Closed` expectation then fails without
    // a hang.
    var batch: [1]Session.UiEvent = undefined;
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
    // The same served model reports once per turn, so the repeat adds no event.
    try handler.onModelMismatch(.{ .requested = "claude-fable-5", .served = "claude-opus-5" });
    // A served model that changes again reports again.
    try handler.onModelMismatch(.{ .requested = "claude-fable-5", .served = "claude-opus-4-8" });
    // Signed out, so the turn fails at once. The wakeup is payload-free and the
    // joined result owns the error text.
    const result = runTurnWorker(&app, try gpa.dupe(u8, "prompt"), generation);
    defer app.freeWorkerResult(&result);
    try std.testing.expectEqual(generation, result.generation);
    try std.testing.expect(result.terminal_queued);
    try std.testing.expectEqualStrings(
        "Drinky could not complete the turn because of error SignedOut.",
        result.error_text.?,
    );

    var events: [10]Session.UiEvent = undefined;
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

    // A cancel backs out of the turn alone: the draft stays, and Drinky runs on, so
    // no press here can discard text. Esc with a draft warns first, so its cancel
    // takes a second press. Ctrl+D is a decision and cancels at once.
    for ([_]terminal.Input.Key{ .escape, .{ .ctrl = 'd' } }) |key| {
        app.session.beginTurn(1);
        try spawnCanceledTurn(&app);
        app.session.editor.clear();
        try app.session.editor.insert("keep the draft");

        try app.handleKey(&key);
        if (key == .escape) {
            // The first Esc arms the confirmation and warns. The turn runs on.
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
    // The edit clears the warning and its one-shot confirmation, so the next Esc
    // warns again instead of a cancel.
    try app.handleKey(&.{ .char = 'x' });
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(!app.session.confirmations.contains(.turn_cancel));
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .turn);
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings("draftx", app.session.editor.visible());
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
    // The edit clears the warning and its one-shot confirmation, so the next
    // Ctrl+D warns again instead of a quit.
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

// A worker that completed before cancellation shows as its completion,
// but only after the terminal fence has preserved all earlier queue progress.
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

    const events = [_]Session.UiEvent{.{ .turn = .{
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

    const events = [_]Session.UiEvent{
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

// Cancellation can join a worker before the consumer reaches progress that the
// worker queued ahead of its terminal fence. The joined result waits at the App
// boundary so the whole prefix applies once before the turn ends.
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
    try std.testing.expectEqualStrings("answer", blocks[0].content.model.items);
    try std.testing.expectEqualStrings("folded", blocks[1].content.user.items);
}

// The same ordering holds when cancellation interrupts the worker's terminal
// enqueue: the consumer appends a replacement fence behind the queued prefix.
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
    try std.testing.expectEqualStrings("answer", prefix[0].content.model.items);
    try std.testing.expectEqualStrings("folded", prefix[1].content.user.items);

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
    try std.testing.expectEqualStrings(
        "answer",
        app.session.transcript.blocks()[0].content.model.items,
    );
}

// A cancel that loses to a failed worker applies the authoritative joined
// result and frees its error text once.
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

    var events: [1]Session.UiEvent = undefined;
    const count = try app.queue.get(io, &events, 1);
    try std.testing.expectEqual(events.len, count);
    try std.testing.expect(!try app.applyBatch(events[0..count]));

    // The replacement terminal fence returns pending steering to the editor
    // before the consumer can take a newer queue event. No turn starts, so the
    // user reviews the reply before the text sends. The recall is automatic, so
    // the older steering composes above the newer in-progress line, and a
    // notice announces the return.
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

// Shutdown is teardown, not an interactive cancel: it frees the worker result and
// mutates neither the editor nor the transcript.
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

// A slash command cannot run mid-turn. Enter must leave the whole line in the
// editor, report the restriction, and never queue the line as prompt text for the
// model. A line with no leading slash is a message and must queue.
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
    // The refusal names the command and the restriction. It warns, because the
    // line is complete, and the next Enter runs it once the turn ends.
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

    // A slash line with a tail is a command line too, so it never becomes steering.
    // The registry reason wins over the turn, because the tail keeps the line
    // unrunnable after the turn ends. Such a refusal offers the queue instead.
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

    // An unknown name mid-turn keeps the registry reason too. `handleKey` drops the
    // arm of the line above on every key that is not an Enter, so drop it here too.
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
    // The arm is one-shot and belongs to this line alone, so the next key drops it.
    app.session.cancelConfirmation(.message);

    // A message keeps the steering path.
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
    const events = [_]Session.UiEvent{
        .{ .turn = .{ .generation = 1, .payload = endedPayload() } },
        .{ .keys = try gpa.dupe(u8, "new") },
    };
    try std.testing.expect(!try app.applyBatch(&events));

    // The fence returns the paste to the editor first, so the newer key lands
    // behind it in the same draft instead of an already gone steering queue.
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 0), app.session.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);
    const expanded = try app.session.editor.expanded(.none);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload ++ "new", expanded);
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
    try std.testing.expectEqualStrings(
        "turn B",
        app.session.transcript.blocks()[2].content.model.items,
    );
}

// A resize marks the model dirty with no tick, so even an idle interface
// reflows on the next frame.
test "a resize event marks an idle interface dirty" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
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
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
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
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // A terminal without the Kitty protocol sends Esc as one byte, so an exit
    // attempt can land as `\x1b\x03` or `\x1b\x04` in one chunk. The Escape
    // closes the page, and the control key behind it must not reach the prompt.
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
    app.initForTest(gpa);
    defer app.input.deinit();
    // The confirmation mirrors the agent state into the session, so the agent must
    // be real. A signed-out one records no project state.
    app.agent = ai.Agent.init(gpa, io, null, .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
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

    // The Escape cancels the turn. The Ctrl+D behind it must not quit Drinky at the
    // prompt the cancel returns to.
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

    // The first Ctrl+D with a draft warns instead of a quit, and the warning
    // offers the second press. That press quits and keeps nothing waiting.
    try app.session.editor.insert("draft");
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(app.running);
    const notice = app.session.notice.?;
    try std.testing.expect(notice.severity == .warning);
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "Ctrl+D") != null);
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(!app.running);

    // Arm again, or the window test below proves nothing.
    app.running = true;
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expectEqualStrings("", app.session.editor.visible());
    try std.testing.expect(app.running);
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(!app.running);

    // Arm again, or the quit below proves nothing.
    app.running = true;
    try app.handleKey(&.{ .ctrl = 'd' });
    try std.testing.expect(!app.running);
}

// Drinky compiles no model in, so a signed-in account with no fetched list can
// send nothing. The refusal names the command that fixes it, the line stays out
// of the transcript, and the editor keeps it.
test "a send refuses while the account offers no model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = ai.testing.accounts(.{ .anthropic = "sk-ant" });
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
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

// A refusal starts no turn, so the text the user typed must survive it. The
// user reads the notice, signs in or picks a model, and sends the same line
// again. A skill line meets the same two gates, so it keeps its text too.
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
    // Paint the old conversation first, so its frame holds the screen.
    try app.session.paint(.{ .columns = 80, .rows = 6 });

    try app.session.editor.insert("/new");
    try app.submit();

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
    // The intro line returns, so the empty conversation shows its legend again.
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

// The skill guard proof memo is only true for the history it was proven
// against, so a `/new` that leaves a stale memo behind could let the empty
// history skip a proof it never earned.
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
    // The conversation already proved the rule, so a write in it needs no read
    // of its own.
    app.skill_guard.rule_items[0].loaded.store(true, .monotonic);
    try std.testing.expect(app.skill_guard.rule_items[0].loaded.load(.monotonic));

    try app.applyOutcome(.new_conversation);

    // The empty history never proved the rule, so the memo must not survive
    // into it.
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
    // Ctrl+C closes a page and keeps Drinky running. A page holds no draft to clear.
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.running);

    const conversation_start = out.written().len;
    try app.session.paint(.{ .columns = 80, .rows = 6 });
    const conversation_bytes = out.written()[conversation_start..];
    try std.testing.expect(std.mem.indexOf(u8, conversation_bytes, "history marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, conversation_bytes, "System prompt") == null);
}

// Ctrl+D closes a page and keeps Drinky running, so a terminal that drops the
// Esc report still has a way out.
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
        .{ .anthropic_subscription = undefined },
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
    try app.state.seed(.anthropic_subscription, test_anthropic_model, .low);

    app.agent.stats.quota = .{
        .secondary = .{ .used_percent = 77, .window_minutes = 10080 },
    };
    app.session.stats_shown = app.agent.stats;

    const openai_client = ai.provider.Client.init(gpa, io, .{ .openai_api = "sk-test" }, .{});
    app.agent.switchTo(openai_client, test_openai_model);
    try app.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .information, "switched", .{}),
    );

    try std.testing.expect(app.agent.stats.quota == null);
    try std.testing.expect(app.session.stats_shown.quota == null);
    try std.testing.expectEqualStrings(test_openai_model.name(), app.session.model_shown.?.name());
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.session.account_shown.?);

    // The switch also lands in `state.json`, so the next start resumes on it.
    var file = (try ai.json_store.open(gpa, io, app.state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("openai_api", entry.get("account").?.string);
    try std.testing.expectEqualStrings("low", entry.get("effort").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqualStrings(test_openai_model.name(), listed.get("openai_api").?.string);
    // The account left behind keeps the model it ran, so a switch back returns
    // to it even after a restart.
    try std.testing.expectEqualStrings(
        test_anthropic_model.name(),
        listed.get("anthropic_subscription").?.string,
    );
}

// The command path that switches the account also projects the conversation for
// it: the canonical history and transcript keep every item, and the interface
// shows what the next request carries.
test "an account switch projects the conversation for the new account" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const anthropic_client = ai.provider.Client.init(
        gpa,
        io,
        .{ .anthropic_subscription = undefined },
        .{},
    );
    var app: App = undefined;
    app.initForTest(gpa);
    // The effort names a thinking control, so the request of this account replays
    // its stored reasoning.
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
    app.session.showSetup(.anthropic_subscription, test_anthropic_model, .high);

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_subscription = .{
        .signature = .{ .text = "weigh it", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    try app.session.transcript.appendStream(.thinking, .anthropic_subscription, "weigh it");
    try app.session.transcript.appendStream(.model, null, "the answer");
    try app.session.paint(.{ .columns = 80, .rows = 24 });

    const switched_start = out.written().len;
    const openai_client = ai.provider.Client.init(gpa, io, .{ .openai_api = "sk-test" }, .{});
    app.agent.switchTo(openai_client, test_openai_model);
    try app.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .information, "switched", .{}),
    );

    // The OpenAI request replays no Anthropic proof, so the reasoning block
    // leaves the screen. Both records keep it for the switch back.
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
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-luna"});
    try ai.testing.seedAccount(&app.accounts, .anthropic_api, &.{"claude-opus-5"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    // The remembered account wins over the first authenticated one, which is the
    // Anthropic key here.
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.startAccount().?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", app.accountModel(.openai_api).?.name());
    // A remembered model belongs to the account that ran it. An account that
    // remembered none starts without one.
    try std.testing.expect(app.accountModel(.anthropic_api) == null);
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
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "sk-anthropic" });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-luna"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    try std.testing.expectEqual(ai.llm.Account.anthropic_api, app.startAccount().?);
    // The remembered account offers no model here, so the session starts on none
    // and the user fetches a list.
    try std.testing.expect(app.accountModel(.anthropic_api) == null);
    // The memory holds for the account that ran the model, even while that
    // account has no credentials. A later login therefore restores the model and
    // does not reset to the account's default.
    try std.testing.expectEqualStrings("gpt-5.6-luna", app.accountModel(.openai_api).?.name());
    // With nothing remembered, the configured effort wins, else the compiled one.
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
    // The project last ran one model under the Anthropic API account.
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic_api", "effort": "low",
        \\    "models": { "anthropic_api": "claude-sonnet-5" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_api, &.{"claude-sonnet-5"});
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-sol"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    const start_model = app.accountModel(.anthropic_api);
    try std.testing.expectEqualStrings("claude-sonnet-5", start_model.?.name());
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
        .model = start_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, start_model, .low);
    defer app.session.deinit();
    try app.state.seed(.anthropic_api, start_model, .low);

    // Away to another account: that account has run nothing here, so it starts
    // without a model until the user picks one.
    try app.applyOutcome(.{ .switch_account = .openai_api });
    try std.testing.expect(app.agent.model == null);

    // Back again. The model the account ran returns.
    try app.applyOutcome(.{ .switch_account = .anthropic_api });
    try app.expectModel("claude-sonnet-5");

    // Both models reach the file, so the next start knows them both.
    var file = (try ai.json_store.open(gpa, io, app.state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic_api", entry.get("account").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqualStrings("claude-sonnet-5", listed.get("anthropic_api").?.string);
    // The account that ran no model here names none in the file.
    try std.testing.expect(listed.get("openai_api") == null);
}

// The model memory of a project and the model cache of the machine live in two
// files. A project therefore starts with no remembered model while the list of
// that account stands cached. The step then names the pick, because a fetch
// returns the same list.
test "a transition names the pick where the list of the account stands cached" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    // The project ran one model under the Anthropic API account, and none under
    // the OpenAI API account.
    try State.writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic_api", "effort": "low",
        \\    "models": { "anthropic_api": "claude-sonnet-5" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_api, &.{"claude-sonnet-5"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    const start_model = app.accountModel(.anthropic_api);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
        .model = start_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, start_model, .low);
    defer app.session.deinit();

    // No fetch ran for the OpenAI API account, so the step names the fetch.
    try app.applyOutcome(.{ .switch_account = .openai_api });
    try std.testing.expect(app.agent.model == null);
    try std.testing.expectEqualStrings(
        "Drinky now uses OpenAI API. Fetch the model list of OpenAI API with /model.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );

    // The machine caches that list now, and this project still remembers no
    // model of that account.
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-sol"});
    try app.applyOutcome(.{ .switch_account = .anthropic_api });
    try app.expectModel("claude-sonnet-5");
    try app.applyOutcome(.{ .switch_account = .openai_api });
    try std.testing.expect(app.agent.model == null);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqualStrings(
        "Drinky now uses OpenAI API. Select a model of OpenAI API with /model.",
        blocks[blocks.len - 1].content.event.text.items,
    );
}

// A logout, a replaced credential, and a start before the first fetch each leave
// the catalog without the list of an account. The name that account ran must
// survive the next save, so a later fetch returns the account to that model.
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
        \\{ "/work": { "account": "anthropic_api", "effort": "low",
        \\    "models": { "anthropic_api": "claude-sonnet-5",
        \\      "openai_api": "gpt-5.6-sol" } } }
    );

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    defer app.accounts.deinit();
    // The catalog holds no list for the Anthropic API account, so the stored
    // name resolves to no model.
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-sol"});
    app.state = try State.open(gpa, io, &.{
        .working_directory = home,
        .home = home,
        .project = "/work",
    });
    defer app.state.deinit();

    try std.testing.expect(app.accountModel(.anthropic_api) == null);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
        .model = null,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, null, .low);
    defer app.session.deinit();
    try app.state.seed(.anthropic_api, null, .low);

    // The switch writes the whole entry. The unresolved name stays in it.
    try app.applyOutcome(.{ .switch_account = .openai_api });
    var file = (try ai.json_store.open(gpa, io, app.state.path)).?;
    defer file.deinit();
    const listed = file.entry("/work").?.get("models").?.object;
    try std.testing.expectEqualStrings("claude-sonnet-5", listed.get("anthropic_api").?.string);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed.get("openai_api").?.string);

    // A fetch of that list returns the account to the model it ran.
    try ai.testing.seedAccount(&app.accounts, .anthropic_api, &.{"claude-sonnet-5"});
    try std.testing.expectEqualStrings(
        "claude-sonnet-5",
        app.accountModel(.anthropic_api).?.name(),
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
        \\{ "/work": { "account": "openai_api", "models": { "openai_api": "gpt-5.6-luna" } } }
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

    // Startup then runs signed out and opens the login picker.
    try std.testing.expect(app.state.start.account != null);
    try std.testing.expect(app.startAccount() == null);
}

// The logout of the last account leaves no one to adopt. Drinky must sign out and
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
    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try std.testing.expect(app.accounts.isAuthenticated(.anthropic_subscription));
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.applyOutcome(.{ .logout = .anthropic_subscription });

    // The credential is gone and no account remains to adopt.
    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expect(app.agent.client == null);
    try std.testing.expect(app.session.account_shown == null);

    // The event names the way back in, and the picker it names is open.
    try std.testing.expectEqualStrings(
        "Drinky signed out of Anthropic Subscription. Select an account to sign in.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );
    try std.testing.expect(app.session.mode == .picking);
    const picker = app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Sign in", picker.title);
    try std.testing.expectEqual(std.enums.values(ai.llm.Account).len, picker.options.len);
    try std.testing.expectEqualStrings("Anthropic Subscription", picker.options[0]);
}

// The next account can offer no model, because no fetch ran for it. The logout
// must report that state instead of unwrapping a model that is not there.
test "the logout of the active account adopts a next account with no model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    // A signed-in subscription plus an environment key, so one account remains
    // after the logout. No fetch ran, so that account offers no model.
    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "key" });
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.applyOutcome(.{ .logout = .anthropic_subscription });

    // The session moved to the remaining account and holds no model. The report
    // names that account, because the transcript is the durable record of the
    // move.
    try std.testing.expectEqual(ai.llm.Account.anthropic_api, app.session.account_shown.?);
    try std.testing.expect(app.agent.model == null);
    try std.testing.expectEqualStrings(
        "Drinky signed out of Anthropic Subscription. Drinky now uses Anthropic API. " ++
            "Fetch the model list of Anthropic API with /model.",
        app.session.transcript.blocks()[0].content.event.text.items,
    );
}

// The logout reads the same helper, so the step there follows the catalog too.
// The next account holds a cached list and no remembered model, so the user
// picks from that list.
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
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "key" });
    defer app.accounts.deinit();
    // A fetch cached the list of the account that follows, and this project ran
    // no model on it.
    try ai.testing.seedAccount(&app.accounts, .anthropic_api, &.{"claude-sonnet-5"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();

    try app.applyOutcome(.{ .logout = .anthropic_subscription });

    try std.testing.expectEqual(ai.llm.Account.anthropic_api, app.session.account_shown.?);
    try std.testing.expect(app.agent.model == null);
    try std.testing.expectEqualStrings(
        "Drinky signed out of Anthropic Subscription. Drinky now uses Anthropic API. " ++
            "Select a model of Anthropic API with /model.",
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
        \\{ "anthropic_subscription":
        \\    { "access": "replacement", "refresh": "replacement",
        \\      "expires_ms": 4102444800000,
        \\      "account_uuid": "other", "organization_uuid": "other" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;
    app.session.beginTurn(1);

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
    // The list of the replaced principal went with its metadata, so the account
    // offers no model.
    try std.testing.expect(app.agent.model == null);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    // The turn failure runs before the transition, so it names no next step.
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "Try the turn again.",
    ) == null);
    try std.testing.expectEqualStrings(
        "Fetch the model list of Anthropic Subscription with /model.",
        blocks[1].content.event.text.items,
    );
}

// A model fetch reaches the same principal boundary as a turn, because it asks
// the provider with the credential of the account. The transition is therefore
// the one a turn takes. The evidence of the replaced principal goes, its cached
// list goes, and the report names the step. The test in
// `lib/ai/command/model.zig` states that such a fetch produces this outcome.
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
        \\{ "anthropic_subscription":
        \\    { "access": "replacement", "refresh": "replacement",
        \\      "expires_ms": 4102444800000,
        \\      "account_uuid": "other", "organization_uuid": "other" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_subscription, &.{"claude-opus-5"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;

    const replay: ai.llm.Item.Reasoning.Replay = .{ .anthropic_subscription = .{
        .signature = .{ .text = "thought", .signature = "proof" },
    } };
    try app.agent.items.append(gpa, .{ .reasoning = .{ .replay = try replay.dupe(gpa) } });
    try app.session.transcript.appendStream(.thinking, .anthropic_subscription, "thought");

    try app.applyOutcome(.{ .credential_replaced = .anthropic_subscription });

    // The proofs of the replaced principal leave the history and the interface,
    // so the next request under the new credential carries none of them.
    try std.testing.expectEqual(@as(usize, 0), app.agent.items.items.len);
    // The cached list belongs to that principal too, so the account offers no
    // model until the next fetch.
    try std.testing.expect(app.accounts.catalog.isEmpty(.anthropic_subscription));
    try std.testing.expect(app.agent.model == null);
    try std.testing.expectEqual(ai.llm.Account.anthropic_subscription, app.activeAccount().?);

    // The report states the replacement and names the step, so the user reads
    // an action and no error name. No turn ran, so it names no retry.
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky found a replacement credential for Anthropic Subscription. " ++
            "Drinky removed the prior account evidence. " ++
            "Fetch the model list of Anthropic Subscription with /model.",
        blocks[0].content.event.text.items,
    );
    try std.testing.expect(!blocks[0].content.event.is_error);
}

// A fetch runs on the account of its row, and that account can be one the
// session does not run. No turn ran either, so the report states the
// replacement, names the fetched account, and names no retry.
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
        \\{ "openai_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .anthropic = "sk-anthropic" });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_subscription, &.{"gpt-5.6-sol"});
    // The session runs the Anthropic API account. The fetch runs on the OpenAI
    // subscription, which the user stepped to in the picker.
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

    try app.applyOutcome(.{ .credential_replaced = .openai_subscription });

    // The replacement reached another account, so the session keeps its own
    // account and its own model.
    try std.testing.expectEqual(ai.llm.Account.anthropic_api, app.activeAccount().?);
    try app.expectModel(test_anthropic_model.name());
    // The cached list belongs to the replaced principal, so it goes.
    try std.testing.expect(app.accounts.catalog.isEmpty(.openai_subscription));

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky found a replacement credential for OpenAI Subscription. " ++
            "Drinky removed the prior account evidence. " ++
            "Fetch the model list of OpenAI Subscription with /model.",
        blocks[0].content.event.text.items,
    );
    try std.testing.expect(!blocks[0].content.event.is_error);
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
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;

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
        "Drinky signed out of Anthropic Subscription. Select an account to sign in.",
        blocks[3].content.event.text.items,
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

    var store = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    store.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "old_access", "refresh": "old_refresh",
        \\      "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{});
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .anthropic_subscription, &.{"claude-opus-5"});
    // The model of the replaced principal. Its list goes with the credential, so
    // the reload leaves the account with no model at all.
    var discovered = test_anthropic_model;
    discovered.context_window = 1;
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = discovered,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;
    // The block of that proof stands above the turn, so only the replacement can
    // take it out again.
    try app.session.transcript.appendStream(.thinking, .anthropic_subscription, "thought");
    app.session.beginTurn(1);

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
    // The list of the replaced credential is gone, so the account offers no
    // model until the user fetches one again.
    try std.testing.expect(app.agent.model == null);
    try std.testing.expect(app.session.model_shown == null);
    try std.testing.expect(app.session.mode == .prompt);

    // The reasoning block of the replaced principal went with its proof, so the
    // two events are all that stands.
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "signed out",
    ) == null);
    try std.testing.expectEqualStrings(
        "Drinky reloaded the refresh credential that another Drinky instance saved. " ++
            "Fetch the model list of Anthropic Subscription with /model.",
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
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .openai = "sk-openai" });
    defer app.accounts.deinit();
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-sol"});
    try app.state.record(.openai_api, test_openai_model, .low);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;
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

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.activeAccount().?);
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.session.account_shown.?);
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
        "Drinky signed out of Anthropic Subscription. " ++
            "Drinky now uses gpt-5.6-sol with OpenAI API.",
        blocks[1].content.event.text.items,
    );
}

// The account that takes the session can offer no model, because no fetch ran
// for it. The report must state the move beside the step, because the
// transcript is the durable record of the active account.
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
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });

    var app: App = undefined;
    app.initForTest(gpa);
    // The OpenAI key authenticates the next account. No fetch ran for it, so it
    // offers no model.
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{ .openai = "sk-openai" });
    defer app.accounts.deinit();
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_subscription), .{
        .model = test_anthropic_model,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
    defer app.agent.deinit();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
    defer app.session.deinit();
    app.session.account_shown = .anthropic_subscription;
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

    try std.testing.expect(!app.accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expectEqual(ai.llm.Account.openai_api, app.activeAccount().?);
    try std.testing.expect(app.agent.model == null);

    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqualStrings(
        "Drinky signed out of Anthropic Subscription. Drinky now uses OpenAI API. " ++
            "Fetch the model list of OpenAI API with /model.",
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

    // One message on the wire, two blocks on the screen: what Drinky sent, and
    // what the user typed. A user message can hold no head, so the head is the
    // one part of the pair that the user cannot forge.
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

    // The head names the skill and the file that the transcript never shows.
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "Skill: zig-style · File: .agents/skills/zig-style/SKILL.md",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "review this file") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), prompt.content) == null);
}

// A skill with no task is the head alone, and the head is one row of its own.
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
    // The head takes one row, with no padding row around it.
    try std.testing.expectEqual(@as(usize, 1), blocks[0].rows(80));
}

test displayRoots {
    const gpa = std.testing.allocator;
    var app: App = undefined;
    app.initForTest(gpa);
    app.working_directory = "/work";
    app.home_directory = "/home/you";

    // A project skill reads relative to the working directory, a user skill takes
    // the `~` of the home directory, and any other path stays as it is.
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

    // Without a resolved session the path stands alone.
    app.working_directory = "";
    app.home_directory = "";
    const bare = try ai.format.path(gpa, "/work/.agents/skills/demo/SKILL.md", &app.displayRoots());
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("/work/.agents/skills/demo/SKILL.md", bare);
}

// A failed turn that committed work arms a retry. Its caption appears above the
// editor, and Esc dismisses that retry alone.
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
    try std.testing.expect(app.session.retry_shown);

    // The caption names the failed state and the two keys that own the retry.
    // Enter belongs to the editor text, so the controls leave it out.
    try app.session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Failed turn") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "Ctrl+N: Try again · Esc: Dismiss",
    ) != null);

    // Esc drops the retry and keeps every byte the editor holds.
    try app.session.editor.insert("keep this text");
    try app.handleKey(&.escape);
    try std.testing.expect(app.retry == null);
    try std.testing.expect(!app.session.retry_shown);
    try std.testing.expectEqualStrings("keep this text", app.session.editor.visible());

    // A prompt with no retry leaves Ctrl+N without an attempt to send.
    try app.handleKey(&.{ .ctrl = 'n' });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.turn_future == null);
}

// A human request that committed nothing needs no retry: it returns to the editor,
// and the next Enter sends it as a normal turn.
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
    try std.testing.expect(!app.session.retry_shown);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
}

// A skill line reproduces its own request, so an uncommitted failure returns the
// whole line and arms no retry. Uncommitted steering joins that line, and one
// Enter sends everything after the name as the task.
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

    // The line the user typed, and the request that Drinky expanded from it.
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

    // The signed-out worker fails before any provider request, so nothing commits.
    {
        const result = app.awaitTurnFuture().?;
        defer app.freeWorkerResult(&result);
        try app.finishWorkerResult(&result);
    }
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.retry == null);
    try std.testing.expect(!app.session.retry_shown);
    try std.testing.expectEqualStrings(
        "/skill:demo apply it\n\nand keep the format",
        app.session.editor.visible(),
    );
    // The rewind keeps the failure event alone: the skill box went with the
    // request that no history holds.
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
    // The restored line is still one command line, and its tail is the new task.
    try std.testing.expectEqualStrings(
        "skill:demo",
        ai.command.parse(app.session.editor.visible()).?,
    );
}

// Ctrl+N sends the attempt alone: no editor text goes with it, the transcript
// records one line, and the failure of the attempt arms the retry again.
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

    // The spawn runs past the sign-in gate, so the worker reaches the agent and
    // reports the signed-out state as the failure of this attempt.
    try app.sendRetryTurn();

    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.retry == null);
    try std.testing.expect(!app.session.retry_shown);
    // The attempt sends and clears nothing of the editor, and it retains no draft,
    // because the editor holds no part of it.
    try std.testing.expectEqualStrings("a draft that stays", app.session.editor.visible());
    try std.testing.expect(app.session.turn_prompt == null);
    {
        // Drinky wrote the message of the attempt, so its line is a user note.
        // That kind alone paints the user color, which `ui.block` pins.
        const blocks = app.session.transcript.blocks();
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        try std.testing.expectEqualStrings(Retry.note_text, blocks[0].content.user_note.items);
    }

    {
        const result = app.awaitTurnFuture().?;
        defer app.freeWorkerResult(&result);
        try app.finishWorkerResult(&result);
    }
    // The attempt continues committed work, so its own failure arms the context
    // again. Its line rewinds, and only the failure event stays.
    try std.testing.expect(app.session.retry_shown);
    try std.testing.expect(std.mem.indexOf(u8, app.retry.?.failure, "SignedOut") != null);
    try std.testing.expectEqualStrings("a draft that stays", app.session.editor.visible());
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
}

// A retry needs an account, so Ctrl+N names the sign-in and sends nothing. Without
// a retry the key has no action at all.
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
    try std.testing.expect(app.session.retry_shown);
    try std.testing.expect(app.turn_future == null);
    try std.testing.expectEqualStrings(
        "Sign in with /login before you try the turn again.",
        app.session.notice.?.content,
    );
}

// A sign-in can land on an account that offers no model, and a waiting retry
// survives it. Ctrl+N must refuse there like a send. Without the gate the
// attempt fails inside the worker and reports a raw error name.
test "Ctrl+N refuses while the account offers no model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var app: App = undefined;
    app.initForTest(gpa);
    app.accounts = ai.testing.accounts(.{ .anthropic = "sk-ant" });
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
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
    try std.testing.expect(app.session.retry_shown);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    try std.testing.expectEqualStrings(no_model_refusal, app.session.notice.?.content);
}

// The gate above keeps `error.NoModel` out of a turn, so nothing maps it today.
// The mapping stays, because a residual path must report a sentence and never
// the internal name.
test "a turn without a model reports a sentence and not the error name" {
    try std.testing.expectEqualStrings(no_model_refusal, turnFailureText(error.NoModel).?);
}

// The attempt never takes the editor text: a network or provider failure is
// nothing a user instruction prevents. Enter sends that text as a plain message,
// and the start of that turn drops the context, because the conversation moved on.
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
    app.session.retry_shown = true;

    try app.session.editor.insert("also check the tests");
    // The two steps that `submit` runs once its sign-in gate passes. A test client
    // is signed out, so the gate would stop the send before any turn.
    {
        const base = try app.startUserTurn("also check the tests");
        var prompt = app.session.editor.detachTrimmed();
        app.session.retainTurnPrompt(&prompt, base);
    }

    // The message is the whole request: no event names an attempt, and no wrapper
    // carries the failure sentence.
    try std.testing.expect(app.session.mode == .turn);
    try std.testing.expect(app.retry == null);
    try std.testing.expect(!app.session.retry_shown);
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
    // The turn committed nothing, so the human text returns and no context arms.
    try std.testing.expectEqualStrings("also check the tests", app.session.editor.visible());
    try std.testing.expect(app.retry == null);
    try std.testing.expect(!app.session.retry_shown);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.event.is_error);
}

// Herdr reads one state per pane. The loop derives it from the model after each
// batch, so a turn end path of any kind needs no report of its own.
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
    // A page is no turn, so Herdr sees no work in progress.
    try app.session.openPage(&.{ .title = "Test page", .content = "body" });
    try std.testing.expectEqual(Herdr.State.idle, app.herdrState());
    app.session.closePage();

    app.session.beginTurn(1);
    try std.testing.expectEqual(Herdr.State.working, app.herdrState());
    app.session.endTurn();

    // A failed turn with committed work waits for Ctrl+N, and the user must decide.
    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    try std.testing.expectEqual(Herdr.State.blocked, app.herdrState());
    // The attempt is a turn again, and it takes the context.
    app.session.beginTurn(2);
    app.setRetry(null);
    try std.testing.expectEqual(Herdr.State.working, app.herdrState());
    app.session.endTurn();
    try std.testing.expectEqual(Herdr.State.idle, app.herdrState());

    // Outside Herdr the reporter is inert, so the loop's call costs nothing.
    app.herdr.sync(app.herdrState());
    try std.testing.expect(app.herdr.future == null);
}

// A cancellation is the user's own stop, so it arms no retry. Esc during an attempt
// ends the recovery, and the committed work behind it stays in history.
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

    // The state of a live attempt: the turn owns the request, so no context waits.
    app.session.beginTurn(1);
    app.turn_retry = true;
    try spawnCommittedCanceledTurn(&app);
    try app.cancelTurn();

    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(app.retry == null);
    try std.testing.expect(!app.session.retry_shown);
    try std.testing.expect(!app.turn_retry);
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "You canceled the turn.",
        blocks[0].content.event.text.items,
    );
}

// A retry belongs to the conversation, not to one configuration: an account switch
// keeps it, and Ctrl+N then runs on the account the user chose. `/new` clears the
// conversation and the retry together.
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
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-sol"});
    try app.state.record(.openai_api, test_openai_model, .low);
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
    defer app.dropRetry();

    app.setRetry(.{ .failure = try gpa.dupe(u8, "The provider is overloaded.") });
    try app.applyOutcome(.{ .switch_account = .openai_api });
    try std.testing.expect(app.retry != null);
    try std.testing.expect(app.session.retry_shown);
    try app.expectModel(test_openai_model.name());
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);

    // Ctrl+N reaches the turn start on the chosen account. The exhausted generation
    // stops it there, and its rollback keeps the retry for another try.
    app.turn_generation = std.math.maxInt(u64);
    try std.testing.expectError(
        error.GenerationExhausted,
        app.handleKey(&.{ .ctrl = 'n' }),
    );
    try std.testing.expect(app.retry != null);
    try std.testing.expect(app.session.retry_shown);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);

    try app.applyOutcome(.new_conversation);
    try std.testing.expect(app.retry == null);
    try std.testing.expect(!app.session.retry_shown);
    // The event of the account switch goes, and the intro line takes its place.
    try std.testing.expectEqual(@as(usize, 1), app.session.transcript.blocks().len);
    try std.testing.expect(app.session.transcript.blocks()[0].content == .intro);
}

// A waiting retry restricts no command, because it owns no key but Ctrl+N. A
// `/skill:` line starts its own turn, and that start drops the stale context.
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
    app.session.retry_shown = true;

    try app.session.editor.insert("/skill:demo apply it");
    const prompt = (try app.dispatchCommand("/skill:demo apply it")).?.prompt;
    defer prompt.deinit(gpa);
    _ = try app.startSkillTurn(&prompt);

    // The line ran, and its turn took the waiting context with it.
    try std.testing.expect(app.session.notice == null);
    try std.testing.expect(app.retry == null);
    try std.testing.expect(!app.session.retry_shown);
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

// Signed out, Drinky must refuse a normal message with a /login prompt rather
// than spawn a turn against no client.
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

// A refused slash line is no dead end. One Enter arms the send, and the next Enter
// puts the line on the model path as typed. Every other key drops the arm, and a
// turn end drops it too, so the send always belongs to the line on screen. Signed
// out, the model path stops at the login prompt, which proves the line skipped the
// registry.
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

    // An edit invalidates the arm, so the line refuses again instead of sending.
    try app.handleKey(&.{ .char = 'x' });
    try std.testing.expect(!app.session.confirmations.contains(.message));
    try app.handleKey(&.backspace);
    try std.testing.expect(!app.session.confirmations.contains(.message));

    try app.handleKey(&.enter);
    try std.testing.expect(app.session.confirmations.contains(.message));
    try app.handleKey(&.enter);

    // The second Enter took the message path: no registry refusal, and the
    // signed-out guard stopped the turn. That guard starts no turn, so the line
    // stays where the user typed it.
    try std.testing.expect(!app.session.confirmations.contains(.message));
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, notice.severity);
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "/login") != null);
    try std.testing.expectEqualStrings("/nope tell me about this", app.session.editor.visible());
}

// The same confirmation during a turn queues the line as steering, so a slash line
// can steer a running turn. A runnable command never arms, because the next Enter
// runs it once the turn ends.
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

    // A runnable command offers no send, so a second Enter refuses again.
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

// The user can read the queue offer while the turn ends under it. The turn end is
// no key event, so the offer and its row must both go: a row that stays invites an
// Enter that no longer queues. The line waits in the editor, and the next Enter
// offers the send that the prompt does.
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

    // The turn ends while that row is on screen.
    try app.session.endTurnWithReceipt(&.{
        .history_base = 0,
        .history_end = 0,
        .steering_committed_count = 0,
    });
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expect(!app.session.confirmations.contains(.message));
    try std.testing.expect(app.session.notice == null);

    // The line survived, so one Enter offers the send again and starts no turn.
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

// A sentence that starts with a command name is a command line, so an idle Enter
// keeps it local. The command never runs, this Enter sends nothing, and the text
// stays in the editor with one offer to send it.
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

    // `/new` never ran, so the history stands and no conversation reset happened.
    // No turn started either, so the line reached no provider.
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
    // The row is a control hint, so the next Enter owns the send.
    try std.testing.expect(app.session.confirmations.contains(.message));
}

// Drinky classifies a large paste that expands to a slash command from its expanded
// text, never its marker label. The label never reaches command dispatch.
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

    // One command name of more than 1000 bytes: large enough to collapse to a marker.
    try app.session.editor.paste("/nope" ++ "x" ** 1000, true);
    try std.testing.expectEqual(@as(usize, 1), app.session.editor.draft.atoms.items.len);

    try app.submit();

    // The command ran off the expanded name, not the "[paste …]" label.
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);
    const notice = app.session.notice.?;
    try std.testing.expectEqual(ai.command.Outcome.Severity.warning, notice.severity);
    // The whole expanded name reached dispatch, not just its first bytes.
    try std.testing.expect(std.mem.startsWith(
        u8,
        notice.content,
        "Enter: Send as a message · Drinky does not recognize the command /nope",
    ));
    try std.testing.expect(std.mem.endsWith(u8, notice.content, "x" ** 1000 ++ "."));
    try std.testing.expect(std.mem.indexOf(u8, notice.content, "paste") == null);
    // The refused line stays in the editor, and its paste keeps its single atom.
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

// Esc leaves one step of a stepped command, so a repeat walks the whole way out.
// The mode stays in the picker on the way up, so the keys behind that Esc are
// kept and a fast repeat reaches the prompt.
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
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-sol"});
    try app.state.record(.openai_api, test_openai_model, .low);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
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

    // The active account marks and opens on its own provider, and the walk goes
    // down the other one. Each provider holds one authenticated account here, so
    // the row opens the model list of that account and skips the account step.
    try std.testing.expectEqual(@as(usize, 0), vendors.cursor);
    try app.handleKey(&.down);
    try app.handleKey(&.enter);
    const listed_models = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: OpenAI API", listed_models.title);
    try std.testing.expect(listed_models.can_step_back);

    // Two Escape bytes in one chunk. The first opens the step above, and the
    // second stays for its own key instead of draining with an exit.
    try app.handleKeys("\x1b\x1b");
    try std.testing.expect(app.session.mode == .picking);
    const reopened_vendors = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Provider", reopened_vendors.title);
    // The list opens on the row the walk left, not on the default row. One Enter
    // therefore returns to the same branch.
    try std.testing.expectEqual(@as(usize, 1), reopened_vendors.cursor);
    // The tag still names the account in use, which the walk did not change.
    try std.testing.expectEqual(@as(usize, 0), reopened_vendors.marked.?);
    try std.testing.expect(app.input.pendingEscape());
    try std.testing.expect(app.session.notice == null);

    // The first step has no step above it, so Esc there leaves the command.
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings(
        "You canceled the model selection.",
        app.session.notice.?.content,
    );
    try app.expectModel(test_anthropic_model.name());

    // Ctrl+C leaves the whole command from any step, so a deep flow keeps a
    // one-key way out.
    try app.session.editor.insert("/model");
    try app.submit();
    try app.handleKey(&.enter);
    try std.testing.expect(app.session.mode.picking.picker.can_step_back);
    try app.handleKey(&.{ .ctrl = 'c' });
    try std.testing.expect(app.session.mode == .prompt);
}

// A fake fetch worker that returns a fixed result at once, so a test drives the
// join and the picker rebuild without a socket.
fn fakeFetch(result: *const ai.Accounts.Refresh) ai.Accounts.Refresh {
    return result.*;
}

/// Test scaffolding: an app at the model step of the Anthropic API account, with
/// the provider step on the trail. The account offers no model yet, so the step
/// holds the fetch row alone.
fn openModelStepForTest(app: *App, out: *std.Io.Writer.Allocating, home: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    app.accounts = try ai.Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-anthropic",
        .openai = "sk-openai",
    });
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-sol"});
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.openai_api), .{
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
    try std.testing.expectEqualStrings("Model: Anthropic API", picker.title);
    try std.testing.expectEqual(@as(usize, 1), picker.options.len);
    try std.testing.expect(picker.can_step_back);
}

/// Test scaffolding: the state `startFetch` leaves behind, over a worker that
/// returns `result` instead of a request. The real worker reaches the network,
/// so a test never spawns it.
fn spawnFakeFetch(app: *App, result: *const ai.Accounts.Refresh) !void {
    const generation = try reserveGeneration(&app.fetch_generation);
    app.fetch = .{
        .future = try app.io.concurrent(fakeFetch, .{result}),
        .account = .anthropic_api,
        .generation = generation,
    };
    try app.session.beginPickerWait(fetch_wait_text);
}

// The fetch leaves the consumer, so the picker waits with no rows until the
// wakeup joins the result. The result rebuilds the same step over the list that
// arrived, with the report beside it and the trail above it intact.
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

    const result: ai.Accounts.Refresh = .{ .count = 1, .metadata_error = error.ConnectionTimedOut };
    try spawnFakeFetch(&app, &result);
    try std.testing.expect(app.session.pickerWaits());
    try std.testing.expect(app.session.animating());
    try std.testing.expectEqual(@as(usize, 0), app.session.mode.picking.picker.options.len);

    // A wakeup of another generation belongs to a fetch that a cancel already
    // joined, so it joins nothing.
    _ = try app.applyBatch(&.{.{ .fetch_ended = 99 }});
    try std.testing.expect(app.fetch != null);
    try std.testing.expect(app.session.pickerWaits());

    // The worker stored the list before its wakeup. The join reads it.
    try ai.testing.seedAccount(&app.accounts, .anthropic_api, &.{"claude-opus-5"});
    _ = try app.applyBatch(&.{.{ .fetch_ended = app.fetch.?.generation }});
    try std.testing.expect(app.fetch == null);
    try std.testing.expect(!app.session.pickerWaits());
    try std.testing.expect(!app.session.animating());
    const rebuilt = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: Anthropic API", rebuilt.title);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", rebuilt.options[0]);
    try std.testing.expectEqualStrings("claude-opus-5", rebuilt.options[1]);
    try std.testing.expect(rebuilt.can_step_back);
    // The missed metadata states itself in the scrollback beside the list.
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[0].content.event.text.items,
        "ConnectionTimedOut",
    ) != null);

    // The rebuilt step still returns to the provider step above it.
    try app.handleKey(&.escape);
    try std.testing.expectEqualStrings("Provider", app.session.mode.picking.picker.title);
}

// A fetch whose account list never arrived opens no list. The picker closes and
// the failure goes to the transcript, as the blocking fetch did before.
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
        "Drinky could not fetch the model list of Anthropic API because of error Timeout.",
        blocks[0].content.event.text.items,
    );
}

// Esc ends one thing. During a fetch that thing is the fetch: the worker joins,
// the step that asked for it returns with its rows, and the trail above it
// stands. A late wakeup of the joined fetch changes nothing.
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

    // A key that moves or selects a row has no row to act on, so the wait holds.
    try app.handleKey(&.down);
    try app.handleKey(&.enter);
    try std.testing.expect(app.fetch != null);
    try std.testing.expect(app.session.pickerWaits());

    try app.handleKey(&.escape);
    try std.testing.expect(app.fetch == null);
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expect(!app.session.pickerWaits());
    const reopened = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Model: Anthropic API", reopened.title);
    try std.testing.expectEqualStrings("Fetch the model list", reopened.options[0]);
    try std.testing.expect(reopened.can_step_back);
    try std.testing.expectEqualStrings(
        "You canceled the model fetch.",
        app.session.notice.?.content,
    );
    try std.testing.expectEqual(@as(usize, 0), app.session.transcript.blocks().len);

    // The joined worker can have left its wakeup in the queue.
    _ = try app.applyBatch(&.{.{ .fetch_ended = generation }});
    try std.testing.expect(app.fetch == null);
    try std.testing.expect(app.session.mode == .picking);

    // The next Esc leaves the step, as it did before the fetch.
    try app.handleKey(&.escape);
    try std.testing.expectEqualStrings("Provider", app.session.mode.picking.picker.title);
}

// Ctrl+C and Ctrl+D leave the whole command from any step, and a fetch is no
// exception. The worker joins with the picker, so no result reaches a picker
// that is gone.
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

// The trail holds every picker the walk down replaced, so the walk up reaches the
// command list that started it. A step that Drinky skipped opened no picker, so
// it enters no trail and the walk up skips it too.
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
    try ai.testing.seedAccount(&app.accounts, .openai_api, &.{"gpt-5.6-sol"});
    try app.state.record(.openai_api, test_openai_model, .low);
    app.agent = ai.Agent.init(gpa, io, app.accounts.client(.anthropic_api), .{
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
    const model_row = for (commands.options, 0..) |option, index| {
        if (std.mem.startsWith(u8, option, "/model —")) break index;
    } else return error.MissingModelRow;

    // Down to the last row and back up to the model row, in a window too short
    // for the list. The row then sits inside a scrolled window, so the walk must
    // return the window too and not the row alone.
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

    // Down to the model list: the list, the provider step, and the account step
    // that one authenticated account per provider skips.
    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings("Provider", app.session.mode.picking.picker.title);
    try app.handleKey(&.enter);
    try std.testing.expectEqualStrings(
        "Model: Anthropic API",
        app.session.mode.picking.picker.title,
    );

    // Up again, one Esc per picker the walk down opened. Each step marks the
    // frame, because a step that paints nothing leaves the old list on screen.
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
    // The list opens where it was left, so the next Enter runs the same command
    // and the window does not jump. The list marks no row, so nothing but the
    // trail holds either value.
    try std.testing.expectEqualStrings("/model", reopened.options[reopened.cursor][0..6]);
    try std.testing.expectEqual(left_cursor, reopened.cursor);
    try std.testing.expectEqual(left_scroll, reopened.scroll);
    try std.testing.expect(reopened.marked == null);

    // The list is the first step, so the next Esc leaves the command.
    try app.handleKey(&.escape);
    try std.testing.expect(app.session.mode == .prompt);
    try std.testing.expectEqualStrings(
        "You canceled the command selection.",
        app.session.notice.?.content,
    );
}

// The command list is the first picker over a picker. A row that opens a list
// replaces the layer, and the picked skill line lands in the editor, where the
// user adds the task.
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

    // The bare slash opens the command list and clears the line it ran.
    try app.session.editor.insert("/");
    try app.submit();
    try std.testing.expect(app.session.mode == .picking);
    try std.testing.expect(app.session.editor.blank());

    // The `/skill` row opens the skill list over the command list.
    const commands = &app.session.mode.picking.picker;
    commands.cursor = for (commands.options, 0..) |option, index| {
        if (std.mem.startsWith(u8, option, "/skill —")) break index;
    } else return error.MissingSkillRow;
    const enter: terminal.Input.Key = .enter;
    try app.handleKey(&enter);
    try std.testing.expect(app.session.mode == .picking);
    const listed_skills = &app.session.mode.picking.picker;
    try std.testing.expectEqualStrings("Skill", listed_skills.title);
    try std.testing.expectEqualStrings("/skill:demo — Shape a demo.", listed_skills.options[0]);

    // The skill row closes the picker and writes its line, with the trailing
    // blank that marks where the task goes.
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
    // A user skill with the same name. The project copy replaces it, and the
    // line reports the replacement as a count, not as a failure.
    var user_demo = try tmp.dir.createDirPathOpen(io, "home/.agents/skills/demo", .{});
    user_demo.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "home/.agents/skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: the user copy\n---\nbody\n",
    });
    const root = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(root);
    const user_skills = try std.fs.path.join(gpa, &.{ root, "home", ".agents", "skills" });
    defer gpa.free(user_skills);

    var app: App = undefined;
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
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
    try std.testing.expect(blocks[0].content == .source_summary);
    // The count covers the two skills the scan kept, minus the one that disabled
    // model invocation, because `/system` never shows that one.
    try std.testing.expectEqualStrings(
        "Instructions: 2 user, 1 project · Skills: 1 (1 replaced)",
        blocks[0].content.source_summary.items,
    );
    // A source that skipped something stays verbose, because the user must fix it.
    try std.testing.expect(blocks[1].content.event.is_error);
    try std.testing.expect(std.mem.indexOf(
        u8,
        blocks[1].content.event.text.items,
        "missing.md",
    ) != null);

    try app.session.paint(.{ .columns = 100, .rows = 24 });
    const painted = out.written();
    const accent_sequence = comptime ui.role.sequence(.accent);
    const muted_sequence = comptime ui.role.sequence(.muted);
    try std.testing.expect(std.mem.indexOf(u8, painted, accent_sequence ++ "Instructions:") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, accent_sequence ++ "Skills:") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, muted_sequence ++ " 2 user") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Event: Instructions:") == null);
}

// A configured rule reaches the guard only through a discovered skill. A name
// that no skill carries must report itself, or a write passes that the user
// believes is guarded.
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
    var project_instructions = ai.instructions.Result.init(gpa, .project);
    defer project_instructions.deinit();
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
    const missing_count = try app.resolveRequiredSkills(&config, &notices);
    try app.reportNotices(notices.items);

    // The pair that resolved guards its files, and it names the file that the
    // scan discovered.
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
    // The rule points at the file that the scan discovered, so a delivery and a
    // proof both read that file.
    try std.testing.expect(std.mem.endsWith(
        u8,
        app.skill_guard.rules()[0].source,
        ".agents/skills/demo/SKILL.md",
    ));

    // The pair Drinky could not resolve guards nothing and reports itself.
    const typescript = try std.fs.path.join(gpa, &.{ root, "src", "view.ts" });
    defer gpa.free(typescript);
    try std.testing.expect((try app.skill_guard.refusal(&.{
        .gpa = gpa,
        .io = io,
        .path = typescript,
        .history = &.{},
    })) == null);
    // A missing name is a normal state of the global config, so it leaves no
    // message of its own. Two patterns name the skill once, and the startup
    // line carries the count as one dense fragment.
    try std.testing.expectEqual(@as(usize, 1), missing_count);
    try std.testing.expectEqual(@as(usize, 0), notices.items.len);
    try app.reportSources(&.{
        .user_instructions = &user_instructions,
        .project_instructions = &project_instructions,
        .skills = &app.skills,
        .required_missing_count = missing_count,
    });
    const blocks = app.session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content == .source_summary);
    try std.testing.expectEqualStrings(
        "Skills: 1 (1 missing)",
        blocks[0].content.source_summary.items,
    );
}

test directoryLabel {
    const gpa = std.testing.allocator;
    const home = try directoryLabel(gpa, "/home/clemens", "/home/clemens");
    defer gpa.free(home);
    try std.testing.expectEqualStrings("~", home);

    const inside = try directoryLabel(gpa, "/home/clemens/github/drinky", "/home/clemens");
    defer gpa.free(inside);
    try std.testing.expectEqualStrings("~/github/drinky", inside);

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
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
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

    // A head Drinky cannot read leaves the directory standing alone.
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "garbage\n" });
    app.refreshBranch();
    try std.testing.expect(app.session.branch() == null);
}

// Herdr labels its pane with the directory and the branch, so the status line
// inside a pane shows neither, and no key reads the head.
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
    const events = [_]Session.UiEvent{.{ .keys = try gpa.dupe(u8, "x") }};
    try std.testing.expect(!try app.applyBatch(&events));
    try std.testing.expect(app.session.branch() == null);

    app.showProject(false);
    try std.testing.expectEqualStrings("~/project", app.session.directory_shown);
    try std.testing.expectEqualStrings("topic", app.session.branch().?);
}

// A checkout in another terminal shows on the next key, so the label needs no
// turn to follow it.
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
    const events = [_]Session.UiEvent{.{ .keys = try gpa.dupe(u8, "x") }};
    try std.testing.expect(!try app.applyBatch(&events));
    try std.testing.expectEqualStrings("other", app.session.branch().?);
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
    app.initForTest(gpa);
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
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
    app.initForTest(gpa);
    defer app.drainQueue();
    app.session = Session.init(gpa, &out.writer, test_anthropic_model, .low);
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

// A cancel that commits nothing returns the submitted prompt to the editor as a
// rich draft, its collapsed paste preserved for an exact expansion. It shows no
// `canceled` line (the turn simply vanished).
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
    // [user "prompt", model "answer", the read call and its box line, cancellation event]
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
}

test "the frame grid holds a fixed period through a late wake and a slow paint" {
    // Model the consumer loop. The timer wakes late, the frame paints, and the
    // loop then arms the next one. Every deadline must stay exactly one interval
    // after the previous one, so the lateness and the paint cost never add to the
    // period. A per-frame reset of the grid destroys this property.
    const wake_late_ns: i96 = 3 * std.time.ns_per_ms;
    const paint_ns: i96 = 5 * std.time.ns_per_ms;
    var grid: FrameGrid = .reset(1000);
    var previous_ns = grid.deadline_ns;
    for (0..60) |_| {
        const armed_ns = previous_ns + wake_late_ns + paint_ns;
        grid.advance(armed_ns);
        try std.testing.expectEqual(previous_ns + FrameGrid.interval_ns, grid.deadline_ns);
        // Anchored on the wake instead, the period grows by the lateness and the
        // paint cost on every frame.
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
