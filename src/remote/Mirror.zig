//! The mirror of the transcript in the chat: a cursor over the committed blocks,
//! the activity message of the running turn, and the failed turn message of a
//! waiting retry. After each change of the transcript the mirror sends every
//! new committed block once, rendered as Telegram HTML, and it reads no
//! streaming event. A reasoning block and a tool box stay in the terminal,
//! because the activity message substitutes for both. A user box stays, because
//! the chat holds every message of the user. An event and a note go out under
//! their role in `html`, so the chat tells a message of Drinky from an answer
//! of the model.
//!
//! The activity message holds the `Cancel turn` and `Withdraw` buttons of the
//! turn, and the failed turn message holds `Try again` and `Dismiss`. A tap
//! names the serial of its keyboard, so the mirror tells a tap on the running
//! turn from a tap on a keyboard the chat history still shows. The mirror holds
//! no tap state: each tap acts at once or reads as stale. Both messages are
//! messages that Drinky wrote, so each one takes the symbol of its role from its
//! first send through every edit, buttons or not.
//!
//! The last answer of a completed turn holds the `Shorten` button. No edit ever
//! takes that button off, so the newest answer alone names a live serial, and a
//! tap on an answer above it reads as stale. The agent commits its last reply
//! before the turn returns, so a trailing answer waits: its send needs the
//! outcome, and no edit can add the button later. The wait ends at the end of
//! the turn, at a tool that starts, or at a block that commits below the answer,
//! because each one proves what the answer is. Every answer that goes out
//! without the button clears the live serial.
//!
//! The mirror talks to the chat through `chat`: a pointer to the controller, or
//! to a recorder in a test, with `listens`, `send`, `sendTracked`, `edit`, and
//! `delete`. A chat that does not listen gets no render and no send, and the
//! mirror keeps the state of the turn alone, so an attach during a turn finds
//! it. Every send is silent except the summary of a completed or failed turn, so
//! the chat notifies once at the end of that turn. That summary is a new
//! message, and the activity message leaves the chat. A canceled turn edits the
//! activity message and stays silent.

const std = @import("std");

const ai = @import("ai");

const ui = @import("../ui/root.zig");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const html = @import("html.zig");
const keyboard = @import("keyboard.zig");

const Mirror = @This();

/// The bytes the longest activity text takes: the phase with a tool name, the
/// separator, and the call count with every digit of a `usize`.
const activity_bytes_max = 96;

/// The buttons of the activity message.
const cancel_label = "Cancel turn";
const withdraw_label = "Withdraw";

/// The failed turn message and its buttons. The text takes the title of the
/// editor caption that names the same state in the terminal.
const retry_text = "Failed turn";
const retry_label = "Try again";
const dismiss_label = "Dismiss";

/// The button of the last answer of a completed turn.
const shorten_label = "Shorten";

gpa: std.mem.Allocator,
/// The count of leading blocks that the chat holds or that the mirror skipped.
/// It never passes the committed frontier, so a rewind of the uncommitted tail
/// cannot take back a block the chat holds.
cursor: usize,
/// The running turn, or null between turns.
turn: ?Turn,
/// The failed turn message whose buttons wait for a tap, or null.
retry: ?RetryMessage,
/// The serial of the `Shorten` button of the newest answer, or null while no
/// button of the chat names it. A newer answer replaces it, so the button above
/// it reads as stale.
answer_serial: ?u64,
/// The serial of the newest keyboard. Every keyboard takes the next one, so a
/// tap names the keyboard it came from. The owner seeds it per process, so a
/// keyboard that an earlier process left in the chat names no serial of this one.
serial: u64,

/// What the mirror reads of the session at one step.
pub const View = struct {
    /// Every block of the transcript, oldest first.
    blocks: []const ui.block.Entry,
    /// The count of leading blocks that are committed.
    committed: usize,
    /// The live tail of the running turn, or null between turns.
    tail: ?Tail,
    /// Whether a retry of a failed turn waits at the prompt. An attach that
    /// finds one sends its failed turn message.
    retry_waits: bool = false,

    pub const Tail = struct {
        /// The kind of the block that streams now, or null between two.
        streaming: ?ui.block.Entry.Kind,
        /// The name of the tool that runs, or null.
        tool: ?[]const u8,
        /// The tool calls the turn made so far.
        calls: usize,
    };

    /// Whether a tool of the turn runs now.
    fn toolRuns(self: *const View) bool {
        const tail = self.tail orelse return false;
        return tail.tool != null;
    }
};

/// How a turn ended, and what its summary states.
pub const End = struct {
    outcome: Outcome,
    /// The state of the session after the turn, for the gauge and the cost.
    status: *const ui.status.Info,
    now_ms: i64,
    /// Whether the failure armed a retry, so the chat gets the failed turn
    /// message with its buttons.
    retry_armed: bool = false,

    pub const Outcome = enum { completed, canceled, failed };
};

const Turn = struct {
    started_ms: i64,
    /// The activity message, or null while the chat holds none.
    handle: ?Attachment.Handle,
    /// The state the activity message shows.
    activity: Activity,
    /// The serial of the keyboard of the activity message.
    serial: u64,
};

const RetryMessage = struct {
    /// The failed turn message, or null when the chat dropped the send.
    handle: ?Attachment.Handle,
    serial: u64,
};

/// The state of the running turn as the activity message shows it. The message
/// edits on a change of this state alone.
const Activity = struct {
    phase: Phase,
    calls: usize,
    tool_buffer: [tool_bytes_max]u8,
    tool_length: usize,

    const Phase = enum { thinking, writing, running };

    /// The bytes of a tool name the message shows. Every tool of Drinky has a
    /// short name, so the cut guards a name alone.
    const tool_bytes_max = 32;

    const idle: Activity = .{
        .phase = .thinking,
        .calls = 0,
        .tool_buffer = undefined,
        .tool_length = 0,
    };

    fn of(tail: *const View.Tail) Activity {
        var activity = idle;
        activity.calls = tail.calls;
        if (tail.tool) |name| {
            activity.phase = .running;
            const length = @min(name.len, tool_bytes_max);
            @memcpy(activity.tool_buffer[0..length], name[0..length]);
            activity.tool_length = length;
        } else if (tail.streaming == .model) {
            activity.phase = .writing;
        }
        return activity;
    }

    fn tool(self: *const Activity) []const u8 {
        return self.tool_buffer[0..self.tool_length];
    }

    fn eql(self: *const Activity, other: *const Activity) bool {
        return self.phase == other.phase and self.calls == other.calls and
            std.mem.eql(u8, self.tool(), other.tool());
    }

    /// The text of the activity message, in `buffer`.
    fn text(self: *const Activity, buffer: []u8) []const u8 {
        var out: std.Io.Writer = .fixed(buffer);
        self.write(&out) catch unreachable;
        return out.buffered();
    }

    fn write(self: *const Activity, out: *std.Io.Writer) !void {
        switch (self.phase) {
            .thinking => try out.writeAll("Thinking"),
            .writing => try out.writeAll("Writing"),
            .running => try out.print("Running: {s}", .{self.tool()}),
        }
        if (self.calls == 0) return;
        try out.writeAll(ui.paint.separator);
        try writeCalls(out, self.calls);
    }
};

/// What the last messages of a flush carry, and where it stops.
const Close = struct {
    /// Whether the last answer of the flush takes the `Shorten` button.
    shorten: bool = false,
    /// Whether a trailing answer waits. Its message can still carry the button
    /// of the turn, and the send needs the outcome. A block that commits below
    /// it ends the wait too.
    hold_answer: bool = false,
};

/// One rendered block of a flush.
const Rendered = struct {
    text: []u8,
    /// Whether the block holds an answer of the model.
    answer: bool,
};

/// What one send of a rendered block carries beside its text.
const Send = struct {
    /// The keyboard of the last message of the block, or null.
    markup: ?[]const u8 = null,
};

pub fn init(gpa: std.mem.Allocator) Mirror {
    return .{
        .gpa = gpa,
        .cursor = 0,
        .turn = null,
        .retry = null,
        .answer_serial = null,
        .serial = 0,
    };
}

/// Start the serials at `seed`. The owner draws one random seed per process.
pub fn seedSerials(self: *Mirror, seed: u64) void {
    self.serial = seed;
}

/// Start the mirror at the committed frontier of `view`. The attach event stands
/// in the chat already, and the blocks before it stay in the terminal. A turn
/// that runs gets its activity message now, because its start lies before the
/// attach, and a retry that waits gets its failed turn message.
pub fn open(self: *Mirror, chat: anytype, view: *const View) !void {
    self.cursor = view.committed;
    if (view.retry_waits) try self.sendRetry(chat);
    const turn = if (self.turn) |*turn| turn else return;
    turn.handle = null;
    if (view.tail) |*tail| turn.activity = Activity.of(tail);
    try self.startActivity(chat);
}

/// Record the start of a turn at `now_ms`, and send its activity message with
/// the buttons of the turn. The message stands above the answer blocks of the
/// turn as its header.
pub fn beginTurn(self: *Mirror, chat: anytype, now_ms: i64) !void {
    self.turn = .{
        .started_ms = now_ms,
        .handle = null,
        .activity = .idle,
        .serial = self.nextSerial(),
    };
    if (!chat.listens()) return;
    try self.startActivity(chat);
}

fn startActivity(self: *Mirror, chat: anytype) !void {
    const turn = &self.turn.?;
    const markup = try self.activityMarkup(turn);
    defer self.gpa.free(markup);
    const text = try self.activityText(turn);
    defer self.gpa.free(text);
    turn.handle = try chat.sendTracked(text, &.{
        .disable_notification = true,
        .parse_mode = html.parse_mode,
        .markup = markup,
    });
}

/// The activity message of `turn` as the chat shows it: the state of the turn
/// under the information role. The result is owned.
fn activityText(self: *Mirror, turn: *const Turn) ![]u8 {
    var buffer: [activity_bytes_max]u8 = undefined;
    return html.wrapAlloc(self.gpa, .information, turn.activity.text(&buffer));
}

/// Send every block that committed since the last step, and edit the activity
/// message when the state of the live tail changed.
pub fn sync(self: *Mirror, chat: anytype, view: *const View) !void {
    if (!chat.listens()) return;
    // A tool that runs proves that a block follows the answer above it, so the
    // wait of that answer ends there instead of at the end of the turn.
    try self.flush(chat, view, .{ .hold_answer = self.turn != null and !view.toolRuns() });
    const turn = if (self.turn) |*turn| turn else return;
    const tail = view.tail orelse return;
    const activity = Activity.of(&tail);
    if (activity.eql(&turn.activity)) return;
    turn.activity = activity;
    try self.editActivity(chat, turn);
}

/// Replace the activity message with the state and the buttons of `turn`.
fn editActivity(self: *Mirror, chat: anytype, turn: *const Turn) !void {
    const handle = turn.handle orelse return;
    const markup = try self.activityMarkup(turn);
    defer self.gpa.free(markup);
    const text = try self.activityText(turn);
    defer self.gpa.free(text);
    try chat.edit(handle, text, &.{ .parse_mode = html.parse_mode, .markup = markup });
}

/// The keyboard of the activity message of `turn`. The result is owned.
fn activityMarkup(self: *Mirror, turn: *const Turn) ![]u8 {
    var cancel_data: [keyboard.data_bytes_max]u8 = undefined;
    var withdraw_data: [keyboard.data_bytes_max]u8 = undefined;
    return keyboard.markup(self.gpa, &.{
        .{
            .text = cancel_label,
            .data = (keyboard.Tap{ .cancel_turn = turn.serial }).write(&cancel_data),
        },
        .{
            .text = withdraw_label,
            .data = (keyboard.Tap{ .withdraw = turn.serial }).write(&withdraw_data),
        },
    });
}

/// Send the last blocks of the turn, then close the activity message. A
/// completed or failed turn deletes that message and sends the summary, which
/// notifies. A canceled turn edits the activity message into the summary and
/// stays silent, because the cancel came from the chat or the terminal took the
/// session over. A failure that armed a retry sends the failed turn message with
/// its buttons. A completed turn alone gives its last answer the `Shorten`
/// button, because a partial answer is no answer to shorten.
pub fn endTurn(self: *Mirror, chat: anytype, view: *const View, end: *const End) !void {
    defer self.turn = null;
    if (!chat.listens()) return;
    try self.flush(chat, view, .{ .shorten = end.outcome == .completed });
    if (self.turn) |*turn| {
        if (end.outcome == .canceled)
            try self.editSummary(chat, turn, end)
        else
            try self.sendSummary(chat, turn, end);
    }
    if (end.retry_armed) try self.sendRetry(chat);
}

/// Replace the activity message of `turn` with the silent summary of a canceled
/// turn. A turn without a handle changes nothing.
fn editSummary(self: *Mirror, chat: anytype, turn: *const Turn, end: *const End) !void {
    const handle = turn.handle orelse return;
    const text = try self.summary(turn, end);
    defer self.gpa.free(text);
    try chat.edit(handle, text, &.{ .parse_mode = html.parse_mode });
}

/// Send the summary of a completed or failed turn, which notifies, then take
/// the activity message out of the chat. The summary goes first, so a full
/// queue cannot drop it after the activity message is already gone. A turn
/// without a handle still sends the summary. A dropped summary keeps the
/// activity message.
fn sendSummary(self: *Mirror, chat: anytype, turn: *const Turn, end: *const End) !void {
    const text = try self.summary(turn, end);
    defer self.gpa.free(text);
    if ((try chat.sendTracked(text, &.{
        .disable_notification = false,
        .parse_mode = html.parse_mode,
    })) == null) return;
    if (turn.handle) |handle| try chat.delete(handle);
}

/// Send the failed turn message with its buttons. A newer one replaces an older
/// one that still stands, so one retry has one message.
fn sendRetry(self: *Mirror, chat: anytype) !void {
    try self.dismissRetry(chat);
    const serial = self.nextSerial();
    var retry_data: [keyboard.data_bytes_max]u8 = undefined;
    var dismiss_data: [keyboard.data_bytes_max]u8 = undefined;
    const markup = try keyboard.markup(self.gpa, &.{
        .{ .text = retry_label, .data = (keyboard.Tap{ .retry = serial }).write(&retry_data) },
        .{ .text = dismiss_label, .data = (keyboard.Tap{ .dismiss = serial }).write(&dismiss_data) },
    });
    defer self.gpa.free(markup);
    const text = try self.retryText();
    defer self.gpa.free(text);
    self.retry = .{ .serial = serial, .handle = null };
    self.retry.?.handle = try chat.sendTracked(text, &.{
        .disable_notification = true,
        .parse_mode = html.parse_mode,
        .markup = markup,
    });
}

/// Take the buttons off the failed turn message, because the retry ended: a tap
/// took it, a turn started, or the conversation cleared. The message keeps its
/// text and its symbol. A mirror without one changes nothing.
pub fn dismissRetry(self: *Mirror, chat: anytype) !void {
    const retry = self.retry orelse return;
    self.retry = null;
    const handle = retry.handle orelse return;
    const text = try self.retryText();
    defer self.gpa.free(text);
    try chat.edit(handle, text, &.{ .parse_mode = html.parse_mode });
}

/// The failed turn message as the chat shows it: the title of the terminal
/// caption under the failure role. The result is owned.
fn retryText(self: *Mirror) ![]u8 {
    return html.wrapAlloc(self.gpa, .failure, retry_text);
}

/// Whether a tap on the keyboard `serial` names the running turn. A tap on the
/// cancel button of the running turn cancels it at once, because the button
/// means one thing.
pub fn namesTurn(self: *const Mirror, serial: u64) bool {
    const turn = self.turn orelse return false;
    return turn.serial == serial;
}

/// Whether a tap on the keyboard `serial` names the failed turn message whose
/// buttons still wait.
pub fn namesRetry(self: *const Mirror, serial: u64) bool {
    const retry = self.retry orelse return false;
    return retry.serial == serial;
}

/// Whether a tap on the keyboard `serial` names the newest answer of the chat.
/// An older answer keeps its button, and a tap on it lands here as stale.
pub fn namesAnswer(self: *const Mirror, serial: u64) bool {
    const live = self.answer_serial orelse return false;
    return live == serial;
}

/// Forget the messages of the chat that closed. The chat keeps them as they
/// stand, buttons included, and a tap on one of them after the next attach reads
/// as stale. The next attach starts at the committed frontier, so every answer
/// of the detached time stays out of the chat, and no `Shorten` button of the
/// chat names the last answer any more. The turn keeps its state, so a later
/// attach gives it a new activity message, and a retry that still waits gets a
/// new failed turn message.
pub fn detached(self: *Mirror) void {
    self.retry = null;
    self.answer_serial = null;
    const turn = if (self.turn) |*turn| turn else return;
    turn.handle = null;
}

/// The next serial. A random seed can stand near the end of the range, so the
/// count wraps instead of an overflow.
fn nextSerial(self: *Mirror) u64 {
    self.serial +%= 1;
    return self.serial;
}

/// Move the cursor back over `count` blocks that left the transcript below it,
/// so the blocks behind them still go out once.
pub fn retreat(self: *Mirror, count: usize) void {
    self.cursor -|= count;
}

/// Start over at the first block, because the transcript was cleared. The
/// length alone cannot tell a cleared transcript from one that grew back. The
/// conversation holds no answer now, so every `Shorten` button of the chat reads
/// as stale.
pub fn restart(self: *Mirror) void {
    self.cursor = 0;
    self.answer_serial = null;
}

/// Send the blocks from the cursor to the committed frontier. Every block
/// renders before the first send, because a send can report into the transcript
/// and move its blocks. The cursor moves past them before the sends too, so a
/// block whose send fails goes out no twice. Every fallible step of the flush
/// stands above that move, so one failure costs no block.
fn flush(self: *Mirror, chat: anytype, view: *const View, close: Close) !void {
    self.cursor = @min(self.cursor, view.blocks.len);
    var end = view.committed;
    // A trailing answer waits for the end of the turn, so its message can carry
    // the button of the turn.
    while (close.hold_answer and end > self.cursor and view.blocks[end - 1].content == .model)
        end -= 1;
    if (self.cursor >= end) return;
    var rendered: std.ArrayList(Rendered) = .empty;
    defer {
        for (rendered.items) |item| self.gpa.free(item.text);
        rendered.deinit(self.gpa);
    }
    for (view.blocks[self.cursor..end]) |*block| {
        const text = try self.renderBlock(block) orelse continue;
        errdefer self.gpa.free(text);
        try rendered.append(self.gpa, .{ .text = text, .answer = block.content == .model });
    }
    const answer_index = lastAnswer(rendered.items);
    const shorten_index = if (close.shorten) answer_index else null;
    var markup: ?[]u8 = null;
    defer if (markup) |json| self.gpa.free(json);
    if (shorten_index != null) markup = try self.armShorten();
    self.cursor = end;
    // An answer that goes out without the button stands below the message that
    // holds the live one, so that button is stale from here on.
    if (answer_index != null and shorten_index == null) self.answer_serial = null;
    for (rendered.items, 0..) |item, index| {
        try self.sendHtml(chat, item.text, .{
            .markup = if (shorten_index == index) markup else null,
        });
    }
}

/// The index of the last answer of `items`, or null for a flush that holds
/// none.
fn lastAnswer(items: []const Rendered) ?usize {
    var index = items.len;
    while (index > 0) {
        index -= 1;
        if (items[index].answer) return index;
    }
    return null;
}

/// Arm the `Shorten` button of the newest answer: take the serial that a tap on
/// it names, and return its keyboard. The result is owned.
fn armShorten(self: *Mirror) ![]u8 {
    const serial = self.nextSerial();
    var data: [keyboard.data_bytes_max]u8 = undefined;
    const json = try keyboard.markup(self.gpa, &.{
        .{ .text = shorten_label, .data = (keyboard.Tap{ .shorten = serial }).write(&data) },
    });
    self.answer_serial = serial;
    return json;
}

/// The HTML of `block`, or null for a block that stays in the terminal. The
/// result is owned.
fn renderBlock(self: *Mirror, block: *const ui.block.Entry) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    switch (block.content) {
        .model => |list| try html.render(&out.writer, std.mem.trimEnd(u8, list.items, " \t\r\n")),
        .user_note => |list| try html.wrap(&out.writer, .note, list.items),
        .event => |flagged| {
            if (!flagged.mirrored) return null;
            try html.wrap(
                &out.writer,
                if (flagged.is_error) .failure else if (flagged.is_warning) .warning else .information,
                flagged.text.items,
            );
        },
        .intro, .user, .thinking, .tool_result => return null,
    }
    if (out.written().len == 0) return null;
    return try out.toOwnedSlice();
}

/// Send one rendered block, in as many messages as its length takes. The last
/// part takes the keyboard, because a block that splits ends there. Every part
/// is silent. The summary of the turn notifies.
fn sendHtml(self: *Mirror, chat: anytype, text: []const u8, send: Send) !void {
    var parts = html.Parts.init(text, html.message_units_max);
    // Every part consumes text, so the split ends.
    while (try parts.next(self.gpa)) |part| {
        defer self.gpa.free(part.text);
        try chat.send(part.text, &.{
            .parse_mode = html.parse_mode,
            .disable_notification = true,
            .markup = if (part.last) send.markup else null,
        });
    }
}

/// The summary of the turn as the chat shows it: its outcome where it did not
/// complete, the tool count, the time, and the numbers of the status line. A
/// failed turn takes the failure role, and every other one the information
/// role. The result is owned.
fn summary(self: *Mirror, turn: *const Turn, end: *const End) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(self.gpa);
    defer text.deinit();
    switch (end.outcome) {
        .completed => {},
        .canceled => try text.writer.print("Canceled{s}", .{ui.paint.separator}),
        .failed => try text.writer.print("Failed{s}", .{ui.paint.separator}),
    }
    try writeCalls(&text.writer, turn.activity.calls);
    var buffer: [24]u8 = undefined;
    try text.writer.print("{s}Time: {s}{s}", .{
        ui.paint.separator,
        ai.format.duration(&buffer, end.now_ms - turn.started_ms),
        ui.paint.separator,
    });
    try ui.status.writeNumbers(&text.writer, end.status);
    const role: html.Role = if (end.outcome == .failed) .failure else .information;
    return html.wrapAlloc(self.gpa, role, text.written());
}

/// The tool count as `Tools: N calls`.
fn writeCalls(out: *std.Io.Writer, calls: usize) !void {
    try out.print("Tools: {d} {s}", .{ calls, if (calls == 1) "call" else "calls" });
}

/// The chat of the tests: it records every send and every edit, with the
/// keyboard of each.
const Recorder = struct {
    gpa: std.mem.Allocator,
    sends: std.ArrayList(Sent) = .empty,
    edits: std.ArrayList(Edited) = .empty,
    deletions: std.ArrayList(Attachment.Handle) = .empty,
    handle_next: Attachment.Handle = 1,
    /// When true, a tracked send returns null and records nothing, like a full
    /// queue on the controller.
    drop_tracked: bool = false,

    const Sent = struct {
        text: []u8,
        options: Client.SendOptions,
        markup: ?[]u8,
        handle: ?Attachment.Handle,
    };

    const Edited = struct {
        handle: Attachment.Handle,
        text: []u8,
        parse_mode: ?[]const u8,
        markup: ?[]u8,
    };

    fn deinit(self: *Recorder) void {
        for (self.sends.items) |sent| {
            self.gpa.free(sent.text);
            if (sent.markup) |markup| self.gpa.free(markup);
        }
        self.sends.deinit(self.gpa);
        for (self.edits.items) |edited| {
            self.gpa.free(edited.text);
            if (edited.markup) |markup| self.gpa.free(markup);
        }
        self.edits.deinit(self.gpa);
        self.deletions.deinit(self.gpa);
    }

    fn listens(_: *const Recorder) bool {
        return true;
    }

    fn send(self: *Recorder, text: []const u8, options: *const Client.SendOptions) !void {
        try self.record(text, options, null);
    }

    fn sendTracked(
        self: *Recorder,
        text: []const u8,
        options: *const Client.SendOptions,
    ) !?Attachment.Handle {
        if (self.drop_tracked) return null;
        const handle = self.handle_next;
        self.handle_next += 1;
        try self.record(text, options, handle);
        return handle;
    }

    fn record(
        self: *Recorder,
        text: []const u8,
        options: *const Client.SendOptions,
        handle: ?Attachment.Handle,
    ) !void {
        const text_copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(text_copy);
        const markup = try self.copyMarkup(options.markup);
        errdefer if (markup) |json| self.gpa.free(json);
        var plain = options.*;
        plain.markup = null;
        try self.sends.append(self.gpa, .{
            .text = text_copy,
            .options = plain,
            .markup = markup,
            .handle = handle,
        });
    }

    fn delete(self: *Recorder, handle: Attachment.Handle) !void {
        try self.deletions.append(self.gpa, handle);
    }

    fn edit(
        self: *Recorder,
        handle: Attachment.Handle,
        text: []const u8,
        options: *const Client.EditOptions,
    ) !void {
        const text_copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(text_copy);
        const markup_copy = try self.copyMarkup(options.markup);
        errdefer if (markup_copy) |json| self.gpa.free(json);
        try self.edits.append(self.gpa, .{
            .handle = handle,
            .text = text_copy,
            .parse_mode = options.parse_mode,
            .markup = markup_copy,
        });
    }

    fn copyMarkup(self: *Recorder, markup: ?[]const u8) !?[]u8 {
        return try self.gpa.dupe(u8, markup orelse return null);
    }

    fn lastSend(self: *const Recorder) *const Sent {
        return &self.sends.items[self.sends.items.len - 1];
    }

    fn lastEdit(self: *const Recorder) *const Edited {
        return &self.edits.items[self.edits.items.len - 1];
    }
};

/// The keyboard of the activity message with the serial `serial`, as the chat
/// receives it.
fn activityKeyboard(comptime serial: []const u8) []const u8 {
    return "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:" ++
        serial ++ "\"}],[{\"text\":\"Withdraw\",\"callback_data\":\"withdraw:" ++ serial ++ "\"}]]}";
}

/// The failed turn message as the chat receives it.
const retry_wrapped = "⚠ " ++ retry_text;

/// The keyboard of the failed turn message with the serial `serial`.
fn retryKeyboard(comptime serial: []const u8) []const u8 {
    return "{\"inline_keyboard\":[[{\"text\":\"Try again\",\"callback_data\":\"retry:" ++ serial ++
        "\"}],[{\"text\":\"Dismiss\",\"callback_data\":\"dismiss:" ++ serial ++ "\"}]]}";
}

/// The keyboard of the newest answer with the serial `serial`.
fn shortenKeyboard(comptime serial: []const u8) []const u8 {
    return "{\"inline_keyboard\":[[{\"text\":\"Shorten\",\"callback_data\":\"shorten:" ++ serial ++
        "\"}]]}";
}

/// The transcript of the tests. It owns its blocks.
const Blocks = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(ui.block.Entry) = .empty,

    fn deinit(self: *Blocks) void {
        for (self.items.items) |*entry| entry.deinit(self.gpa);
        self.items.deinit(self.gpa);
    }

    fn append(
        self: *Blocks,
        kind: ui.block.Entry.Kind,
        options: ui.block.Entry.Options,
        text: []const u8,
    ) !void {
        try self.items.append(self.gpa, try ui.block.Entry.init(self.gpa, kind, options, text));
    }

    fn truncate(self: *Blocks, count: usize) void {
        for (self.items.items[count..]) |*entry| entry.deinit(self.gpa);
        self.items.shrinkRetainingCapacity(count);
    }

    /// Give the list up to its length alone, so the next append moves it.
    fn compact(self: *Blocks) void {
        self.items.shrinkAndFree(self.gpa, self.items.items.len);
    }

    /// The view with every block committed and no turn.
    fn idle(self: *const Blocks) View {
        return .{ .blocks = self.items.items, .committed = self.items.items.len, .tail = null };
    }

    /// The view of a turn with `committed` leading blocks and `tail` live.
    fn live(self: *const Blocks, committed: usize, tail: View.Tail) View {
        return .{ .blocks = self.items.items, .committed = committed, .tail = tail };
    }
};

const test_status: ui.status.Info = .{
    .directory = "",
    .branch = null,
    .context_tokens = 45_000,
    .cache_usage = .{},
    .cost = 0.42,
    .context_window = 100_000,
    .model = "claude-opus-4-8",
    .effort = "high",
    .account = .anthropic_sub_login,
    .quota = null,
    .quota_age_ms = 0,
    .credits = null,
    .turn_active = false,
};

test "a step sends each committed answer, event, and note once, and skips the rest" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.intro, .{}, "legend");
    try blocks.append(.user, .{}, "typed");
    try blocks.append(.thinking, .{}, "weigh it");
    try blocks.append(.model, .{}, "The **answer** & more.\n\n");
    try blocks.append(.tool_result, .{}, "Tool: bash");
    try blocks.append(.event, .{}, "Drinky changed the model.");
    try blocks.append(.event, .{ .mirrored = false, .is_error = true }, "Telegram rejected a message.");
    try blocks.append(.user_note, .{}, "Skill: zig-style · File: <skill>");
    var mirror = Mirror.init(gpa);

    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
    try std.testing.expectEqualStrings("The <b>answer</b> &amp; more.", chat.sends.items[0].text);
    try std.testing.expectEqualStrings("HTML", chat.sends.items[0].options.parse_mode.?);
    try std.testing.expect(chat.sends.items[0].options.disable_notification);
    try std.testing.expectEqualStrings(
        "ℹ Drinky changed the model.",
        chat.sends.items[1].text,
    );
    try std.testing.expectEqualStrings(
        "→ Skill: zig-style · File: &lt;skill&gt;",
        chat.sends.items[2].text,
    );
    // A second step over the same blocks sends nothing.
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
}

test "a mirrored warning event opens with the warning symbol" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.event, .{ .is_warning = true }, "The account offers no model now.");
    var mirror = Mirror.init(gpa);

    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);
    try std.testing.expectEqualStrings(
        "⚠ The account offers no model now.",
        chat.sends.items[0].text,
    );
}

test "a block above the committed frontier waits, and a rewound tail costs nothing" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.user, .{}, "prompt");
    try blocks.append(.model, .{}, "partial");
    var mirror = Mirror.init(gpa);
    const tail: View.Tail = .{ .streaming = .model, .tool = null, .calls = 0 };

    try mirror.sync(&chat, &blocks.live(1, tail));
    try std.testing.expectEqual(@as(usize, 0), chat.sends.items.len);
    // A retry discards the partial reply, and the cursor stands below it.
    blocks.truncate(1);
    try blocks.append(.event, .{ .survives_rewind = true }, "Drinky started retry attempt 1.");
    try blocks.append(.model, .{}, "whole");
    try mirror.sync(&chat, &blocks.live(2, tail));
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);
    try std.testing.expectEqualStrings(
        "ℹ Drinky started retry attempt 1.",
        chat.sends.items[0].text,
    );
    try mirror.sync(&chat, &blocks.live(3, tail));
    try std.testing.expectEqualStrings("whole", chat.lastSend().text);
}

test "the activity message edits on a state change alone, and the summary ends it" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.user, .{}, "prompt");
    var mirror = Mirror.init(gpa);

    // The activity message opens with the buttons of the turn, under the
    // information symbol of a message that Drinky wrote.
    try mirror.beginTurn(&chat, 1_000);
    try std.testing.expectEqualStrings("ℹ Thinking", chat.sends.items[0].text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.sends.items[0].options.parse_mode.?);
    try std.testing.expect(chat.sends.items[0].handle != null);
    try std.testing.expect(chat.sends.items[0].options.disable_notification);
    try std.testing.expectEqualStrings(activityKeyboard("1"), chat.sends.items[0].markup.?);
    const handle = chat.sends.items[0].handle.?;

    // Every edit of the state carries the keyboard, because an edit without
    // one drops it, and it keeps the symbol with its parse mode.
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = null, .calls = 0 }));
    try std.testing.expectEqual(@as(usize, 0), chat.edits.items.len);
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = .model, .tool = null, .calls = 0 }));
    try std.testing.expectEqualStrings("ℹ Writing", chat.lastEdit().text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.lastEdit().parse_mode.?);
    try std.testing.expectEqual(handle, chat.lastEdit().handle);
    try std.testing.expectEqualStrings(activityKeyboard("1"), chat.lastEdit().markup.?);
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .calls = 1 }));
    try std.testing.expectEqualStrings("ℹ Running: bash · Tools: 1 call", chat.lastEdit().text);
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .calls = 1 }));
    try std.testing.expectEqual(@as(usize, 2), chat.edits.items.len);
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = .thinking, .tool = null, .calls = 2 }));
    try std.testing.expectEqualStrings("ℹ Thinking · Tools: 2 calls", chat.lastEdit().text);

    // The last answer block closes at the receipt, so it goes out with the end
    // of the turn, silent. The activity message leaves, and a new summary
    // notifies.
    try blocks.append(.model, .{}, "first");
    try blocks.append(.model, .{}, "last");
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 126_400,
    });
    try std.testing.expectEqual(@as(usize, 4), chat.sends.items.len);
    try std.testing.expect(chat.sends.items[1].options.disable_notification);
    try std.testing.expectEqualStrings("last", chat.sends.items[2].text);
    try std.testing.expect(chat.sends.items[2].options.disable_notification);
    try std.testing.expectEqualStrings(
        "ℹ Tools: 2 calls · Time: 2m 5s · Context: 45% · Cost: ~$0.42",
        chat.lastSend().text,
    );
    try std.testing.expect(!chat.lastSend().options.disable_notification);
    try std.testing.expectEqualStrings(html.parse_mode, chat.lastSend().options.parse_mode.?);
    try std.testing.expect(chat.lastSend().markup == null);
    try std.testing.expectEqual(@as(usize, 1), chat.deletions.items.len);
    try std.testing.expectEqual(handle, chat.deletions.items[0]);
    try std.testing.expect(mirror.turn == null);
    // The turn is over, so a tap on its keyboard is stale.
    try std.testing.expect(!mirror.namesTurn(1));
}

// A tap names the serial of its keyboard, and the running turn alone answers to
// its own serial. The keyboard of a turn never changes, so a tap costs no edit.
test "a tap names the running turn alone, and the next turn makes its serial stale" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);
    try std.testing.expect(!mirror.namesTurn(1));
    try mirror.beginTurn(&chat, 0);

    try std.testing.expect(!mirror.namesTurn(7));
    try std.testing.expect(mirror.namesTurn(1));
    try mirror.sync(&chat, &blocks.live(0, .{ .streaming = .model, .tool = null, .calls = 0 }));
    try std.testing.expectEqualStrings("ℹ Writing", chat.lastEdit().text);
    try std.testing.expectEqualStrings(activityKeyboard("1"), chat.lastEdit().markup.?);
    try std.testing.expectEqual(@as(usize, 1), chat.edits.items.len);

    // The next turn opens a new keyboard, so the old serial is stale.
    try mirror.endTurn(&chat, &blocks.idle(), &.{ .outcome = .canceled, .status = &test_status, .now_ms = 0 });
    try mirror.beginTurn(&chat, 0);
    try std.testing.expectEqualStrings(activityKeyboard("2"), chat.lastSend().markup.?);
    try std.testing.expect(!mirror.namesTurn(1));
    try std.testing.expect(mirror.namesTurn(2));
}

// A failure that arms a retry gives the chat the two controls of the terminal
// caption. The message loses its buttons when the retry ends, and a retry that
// waits at the attach gets its message then.
test "a failed turn that armed a retry sends the failed turn message, which loses its buttons with the retry" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    // A failure without a retry sends the summary and no failed turn message.
    try mirror.beginTurn(&chat, 0);
    try mirror.endTurn(&chat, &blocks.idle(), &.{ .outcome = .failed, .status = &test_status, .now_ms = 0 });
    try std.testing.expectEqual(@as(usize, 2), chat.sends.items.len);
    try std.testing.expect(mirror.retry == null);

    try mirror.beginTurn(&chat, 0);
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .failed,
        .status = &test_status,
        .now_ms = 0,
        .retry_armed = true,
    });
    // The message is a message of Drinky about a failure, so it takes the
    // failure symbol.
    try std.testing.expectEqualStrings(retry_wrapped, chat.lastSend().text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.lastSend().options.parse_mode.?);
    try std.testing.expectEqualStrings(retryKeyboard("3"), chat.lastSend().markup.?);
    try std.testing.expect(chat.lastSend().options.disable_notification);
    const handle = chat.lastSend().handle.?;
    try std.testing.expect(mirror.namesRetry(3));
    try std.testing.expect(!mirror.namesRetry(2));

    // The retry ends: the message keeps its text and its symbol, and it loses
    // its buttons.
    try mirror.dismissRetry(&chat);
    try std.testing.expectEqual(handle, chat.lastEdit().handle);
    try std.testing.expectEqualStrings(retry_wrapped, chat.lastEdit().text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.lastEdit().parse_mode.?);
    try std.testing.expect(chat.lastEdit().markup == null);
    try std.testing.expect(!mirror.namesRetry(3));
    const edits = chat.edits.items.len;
    try mirror.dismissRetry(&chat);
    try std.testing.expectEqual(edits, chat.edits.items.len);

    // An attach that finds a waiting retry sends the message at once.
    try mirror.open(&chat, &.{ .blocks = &.{}, .committed = 0, .tail = null, .retry_waits = true });
    try std.testing.expectEqualStrings(retry_wrapped, chat.lastSend().text);
    try std.testing.expectEqualStrings(retryKeyboard("4"), chat.lastSend().markup.?);
    try std.testing.expect(mirror.namesRetry(4));
}

// A stale keyboard stays in the chat history, and a later process starts its
// count again, so a seed per process keeps the serials of one process apart from
// those of an earlier one. The count wraps, because a seed can stand at the end
// of the range.
test "a seed moves the serials past the keyboards of an earlier process" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    mirror.seedSerials(1_000);
    try mirror.beginTurn(&chat, 0);
    try std.testing.expectEqualStrings(activityKeyboard("1001"), chat.lastSend().markup.?);
    try std.testing.expect(!mirror.namesTurn(1));
    try std.testing.expect(mirror.namesTurn(1_001));
    try mirror.endTurn(&chat, &blocks.idle(), &.{ .outcome = .canceled, .status = &test_status, .now_ms = 0 });

    mirror.seedSerials(std.math.maxInt(u64));
    try mirror.beginTurn(&chat, 0);
    try std.testing.expectEqualStrings(activityKeyboard("0"), chat.lastSend().markup.?);
    try std.testing.expect(mirror.namesTurn(0));
}

// The detach leaves the chat as it stands, so the mirror forgets its messages
// there without an edit. The turn keeps its state, and the next attach sends a
// new activity message and a new failed turn message for a retry that still
// waits. A tap on the old keyboards then reads as stale.
test "a detach forgets the messages of the chat and keeps the turn" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);
    try mirror.open(&chat, &.{ .blocks = &.{}, .committed = 0, .tail = null, .retry_waits = true });
    try mirror.beginTurn(&chat, 0);
    const edits = chat.edits.items.len;

    mirror.detached();
    try std.testing.expectEqual(edits, chat.edits.items.len);
    try std.testing.expect(mirror.retry == null);
    try std.testing.expect(!mirror.namesRetry(1));
    try std.testing.expect(mirror.turn != null);
    try std.testing.expect(mirror.namesTurn(2));
    try mirror.open(&chat, &.{ .blocks = &.{}, .committed = 0, .tail = null, .retry_waits = true });
    try std.testing.expectEqualStrings(retryKeyboard("3"), chat.sends.items[2].markup.?);
    try std.testing.expectEqualStrings(activityKeyboard("2"), chat.lastSend().markup.?);
    try std.testing.expectEqual(edits, chat.edits.items.len);
}

test "a canceled turn ends in silence, and a failed turn notifies its summary" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(&chat, 0);
    try blocks.append(.event, .{}, "You canceled the turn.");
    try mirror.endTurn(&chat, &blocks.idle(), &.{ .outcome = .canceled, .status = &test_status, .now_ms = 500 });
    try std.testing.expect(chat.lastSend().options.disable_notification);
    // The summary keeps the outcome word, and a canceled turn keeps the
    // information role, because nothing failed.
    try std.testing.expectEqualStrings(
        "ℹ Canceled · Tools: 0 calls · Time: 500ms · Context: 45% · Cost: ~$0.42",
        chat.lastEdit().text,
    );
    try std.testing.expectEqual(@as(usize, 0), chat.deletions.items.len);

    try mirror.beginTurn(&chat, 1_000);
    try blocks.append(.event, .{ .is_error = true }, "The provider refused the request.");
    const activity = chat.lastSend().handle.?;
    try mirror.endTurn(&chat, &blocks.idle(), &.{ .outcome = .failed, .status = &test_status, .now_ms = 3_000 });
    try std.testing.expectEqualStrings(
        "⚠ The provider refused the request.",
        chat.sends.items[chat.sends.items.len - 2].text,
    );
    try std.testing.expect(chat.sends.items[chat.sends.items.len - 2].options.disable_notification);
    try std.testing.expect(std.mem.startsWith(
        u8,
        chat.lastSend().text,
        "⚠ Failed · Tools: 0 calls · Time: 2.0s",
    ));
    try std.testing.expect(!chat.lastSend().options.disable_notification);
    try std.testing.expectEqual(@as(usize, 1), chat.deletions.items.len);
    try std.testing.expectEqual(activity, chat.deletions.items[0]);
}

test "a completed turn notifies on its summary when the last answer already went out" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(&chat, 0);
    try blocks.append(.model, .{}, "answer");
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .calls = 1 }));
    try std.testing.expectEqualStrings("answer", chat.lastSend().text);
    try std.testing.expect(chat.lastSend().options.disable_notification);
    const activity = chat.sends.items[0].handle.?;

    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
    try std.testing.expect(!chat.lastSend().options.disable_notification);
    try std.testing.expect(std.mem.startsWith(u8, chat.lastSend().text, "ℹ Tools: 1 call"));
    try std.testing.expectEqual(@as(usize, 1), chat.deletions.items.len);
    try std.testing.expectEqual(activity, chat.deletions.items[0]);
}

test "a completed turn keeps the activity message when the summary cannot queue" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(&chat, 0);
    const activity = chat.sends.items[0].handle.?;
    chat.drop_tracked = true;
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);
    try std.testing.expectEqual(@as(usize, 0), chat.deletions.items.len);
    try std.testing.expectEqual(activity, chat.sends.items[0].handle.?);
}

test "an open starts at the committed frontier and gives a running turn its activity message" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.model, .{}, "before the attach");
    try blocks.append(.event, .{ .mirrored = false }, "You attached @drinky_bot.");
    var mirror = Mirror.init(gpa);

    // An idle attach: the history stays in the terminal.
    try mirror.open(&chat, &blocks.idle());
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 0), chat.sends.items.len);

    // A turn that started before the attach gets its activity message at the
    // attach, with the state of the live tail.
    try mirror.beginTurn(&chat, 0);
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);
    try mirror.open(&chat, &blocks.live(2, .{ .streaming = null, .tool = "read", .calls = 3 }));
    try std.testing.expectEqualStrings(
        "ℹ Running: read · Tools: 3 calls",
        chat.lastSend().text,
    );
    try std.testing.expectEqual(@as(?Attachment.Handle, 2), chat.lastSend().handle);
}

test "the cursor follows a cleared transcript and moves back over dropped blocks" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.thinking, .{ .account = .anthropic_sub_login }, "weigh it");
    try blocks.append(.model, .{}, "answer");
    var mirror = Mirror.init(gpa);
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);

    // A credential replacement drops the reasoning block below the cursor and
    // records its event in one step.
    blocks.truncate(0);
    try blocks.append(.model, .{}, "answer");
    try blocks.append(.event, .{}, "Drinky replaced the credential.");
    mirror.retreat(1);
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 2), chat.sends.items.len);
    try std.testing.expectEqualStrings(
        "ℹ Drinky replaced the credential.",
        chat.lastSend().text,
    );

    // A new conversation clears everything, and the mirror starts over. The
    // cleared transcript grows back to the same length in the same step, so the
    // length alone could not tell.
    blocks.truncate(0);
    try blocks.append(.intro, .{}, "legend");
    try blocks.append(.event, .{}, "fresh");
    mirror.restart();
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
    try std.testing.expectEqualStrings("ℹ fresh", chat.lastSend().text);
}

/// A chat that reports into the transcript on every send. The report appends a
/// block, so a send moves the blocks of the transcript. No chat of Drinky does
/// this today, and the flush must stay safe against one.
const Reporter = struct {
    blocks: *Blocks,
    sends: usize = 0,

    fn listens(_: *const Reporter) bool {
        return true;
    }

    fn send(self: *Reporter, text: []const u8, options: *const Client.SendOptions) !void {
        _ = text;
        _ = options;
        self.sends += 1;
        try self.blocks.append(.event, .{ .mirrored = false }, "Drinky dropped a message.");
    }

    fn sendTracked(
        _: *Reporter,
        _: []const u8,
        _: *const Client.SendOptions,
    ) !?Attachment.Handle {
        return null;
    }

    fn edit(_: *Reporter, _: Attachment.Handle, _: []const u8, _: *const Client.EditOptions) !void {}
};

// A send can report into the transcript, and the report appends a block. The
// list of blocks moves when it is full, so a flush that reads the next block
// after a send reads freed memory. Every block renders before the first send.
test "a send that reports into the transcript cannot move the blocks under the flush" {
    const gpa = std.testing.allocator;
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.model, .{}, "one");
    try blocks.append(.model, .{}, "two");
    try blocks.append(.model, .{}, "three");
    blocks.compact();
    var chat: Reporter = .{ .blocks = &blocks };
    var mirror = Mirror.init(gpa);

    // The view holds the blocks as they stand before the first send.
    const view = blocks.idle();
    try mirror.sync(&chat, &view);
    try std.testing.expectEqual(@as(usize, 3), chat.sends);
    try std.testing.expectEqual(@as(usize, 6), blocks.items.items.len);
    // The reports stay in the terminal, so the next step sends nothing.
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), chat.sends);
}

// The button rides the last answer of the closing flush, because a send during
// the turn cannot know that its answer is the last one, and no edit ever adds
// one. A block below an answer proves that the answer is not the last one, and
// a newer answer makes the button above it stale.
test "a completed turn gives its last answer the shorten button, and a newer answer stales it" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);
    try std.testing.expect(!mirror.namesAnswer(0));

    // An answer that commits during the turn waits, because the turn can still
    // end on it.
    try mirror.beginTurn(&chat, 0);
    try blocks.append(.model, .{}, "first");
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = .model, .tool = null, .calls = 0 }));
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);

    // A tool that runs proves that a block follows the answer, so the wait ends
    // there and the answer goes out with no button.
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .calls = 1 }));
    try std.testing.expectEqual(@as(usize, 2), chat.sends.items.len);
    try std.testing.expectEqualStrings("first", chat.sends.items[1].text);
    try std.testing.expect(chat.sends.items[1].markup == null);
    try std.testing.expect(mirror.answer_serial == null);

    // A block that commits below an answer ends its wait too, so the second
    // answer goes out with the event under it and takes no button either.
    try blocks.append(.model, .{}, "second");
    try mirror.sync(&chat, &blocks.live(2, .{ .streaming = .model, .tool = null, .calls = 1 }));
    try std.testing.expectEqual(@as(usize, 2), chat.sends.items.len);
    try blocks.append(.event, .{}, "Drinky changed the model.");
    try mirror.sync(&chat, &blocks.live(3, .{ .streaming = null, .tool = null, .calls = 1 }));
    try std.testing.expectEqual(@as(usize, 4), chat.sends.items.len);
    try std.testing.expectEqualStrings("second", chat.sends.items[2].text);
    try std.testing.expect(chat.sends.items[2].markup == null);
    try std.testing.expect(chat.sends.items[3].markup == null);
    try std.testing.expect(mirror.answer_serial == null);

    // The closing flush gives the last answer of the turn the button. The
    // summary follows it and notifies.
    try blocks.append(.model, .{}, "last");
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqual(@as(usize, 6), chat.sends.items.len);
    try std.testing.expectEqualStrings("last", chat.sends.items[4].text);
    try std.testing.expectEqualStrings(shortenKeyboard("2"), chat.sends.items[4].markup.?);
    try std.testing.expect(chat.lastSend().markup == null);
    try std.testing.expect(!chat.lastSend().options.disable_notification);
    try std.testing.expect(mirror.namesAnswer(2));
    try std.testing.expect(!mirror.namesAnswer(1));

    // The next answer takes the live serial, so the button above it is stale.
    try mirror.beginTurn(&chat, 0);
    try blocks.append(.model, .{}, "newer");
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqualStrings(shortenKeyboard("4"), chat.sends.items[chat.sends.items.len - 2].markup.?);
    try std.testing.expect(mirror.namesAnswer(4));
    try std.testing.expect(!mirror.namesAnswer(2));

    // A cleared conversation holds no answer, so every button of the chat is
    // stale.
    mirror.restart();
    try std.testing.expect(!mirror.namesAnswer(4));
}

// A partial answer is no answer to shorten, so a turn that did not complete
// hands out no button. Its answer stands below the message that holds the live
// button, so that button goes stale with it.
test "a canceled turn and a failed turn give no shorten button and stale the live one" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(&chat, 0);
    try blocks.append(.model, .{}, "complete");
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expect(mirror.namesAnswer(2));

    try mirror.beginTurn(&chat, 0);
    try blocks.append(.model, .{}, "canceled");
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .canceled,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqualStrings("canceled", chat.lastSend().text);
    try std.testing.expect(chat.lastSend().markup == null);
    try std.testing.expect(mirror.answer_serial == null);

    try mirror.beginTurn(&chat, 0);
    try blocks.append(.model, .{}, "failed");
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .failed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqualStrings("failed", chat.sends.items[chat.sends.items.len - 2].text);
    try std.testing.expect(chat.sends.items[chat.sends.items.len - 2].markup == null);
    try std.testing.expect(mirror.answer_serial == null);
}

test "a long answer splits into several messages, and the last part takes the button" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    const line = "x" ** 100 ++ "\n";
    try blocks.append(.model, .{}, line ** 50);
    var mirror = Mirror.init(gpa);
    try mirror.beginTurn(&chat, 0);

    try mirror.endTurn(&chat, &blocks.idle(), &.{ .outcome = .completed, .status = &test_status, .now_ms = 0 });
    // The activity message, two parts of the answer, then the summary.
    try std.testing.expectEqual(@as(usize, 4), chat.sends.items.len);
    try std.testing.expect(chat.sends.items[1].text.len <= html.message_units_max);
    try std.testing.expect(chat.sends.items[1].options.disable_notification);
    try std.testing.expect(chat.sends.items[2].options.disable_notification);
    try std.testing.expect(!chat.lastSend().options.disable_notification);
    // The block ends at its last part, so the button rides that message alone.
    try std.testing.expect(chat.sends.items[1].markup == null);
    try std.testing.expectEqualStrings(shortenKeyboard("2"), chat.sends.items[2].markup.?);
    try std.testing.expect(chat.lastSend().markup == null);
}
