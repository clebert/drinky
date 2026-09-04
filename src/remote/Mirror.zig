//! The mirror of the transcript in the chat: a cursor over the committed blocks,
//! and the activity message of the running turn. After each change of the
//! transcript the mirror sends every new committed block once, rendered as
//! Telegram HTML, and it reads no streaming event. A reasoning block and a tool
//! box stay in the terminal, because the activity message substitutes for both.
//! A user box stays, because the chat holds every message of the user.
//!
//! The mirror talks to the chat through `chat`: a pointer to the controller, or
//! to a recorder in a test, with `listens`, `send`, `sendTracked`, and `edit`.
//! A chat that does not listen gets no render and no send, and the mirror keeps
//! the state of the turn alone, so an attach during a turn finds it. Every send
//! is silent except the last message of a completed or failed turn, so the chat
//! notifies once per turn.

const std = @import("std");

const ai = @import("ai");

const ui = @import("../ui/root.zig");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const html = @import("html.zig");

const Mirror = @This();

/// The bytes the longest activity text takes: the phase with a tool name, the
/// separator, and the call count with every digit of a `usize`.
const activity_bytes_max = 96;

/// The parse mode of every message that the mirror sends.
const parse_mode = "HTML";

gpa: std.mem.Allocator,
/// The count of leading blocks that the chat holds or that the mirror skipped.
/// It never passes the committed frontier, so a rewind of the uncommitted tail
/// cannot take back a block the chat holds.
cursor: usize,
/// The running turn, or null between turns.
turn: ?Turn,

/// What the mirror reads of the session at one step.
pub const View = struct {
    /// Every block of the transcript, oldest first.
    blocks: []const ui.block.Entry,
    /// The count of leading blocks that are committed.
    committed: usize,
    /// The live tail of the running turn, or null between turns.
    tail: ?Tail,

    pub const Tail = struct {
        /// The kind of the block that streams now, or null between two.
        streaming: ?ui.block.Entry.Kind,
        /// The name of the tool that runs, or null.
        tool: ?[]const u8,
        /// The tool calls the turn made so far.
        calls: usize,
    };
};

/// How a turn ended, and what its summary states.
pub const End = struct {
    outcome: Outcome,
    /// The state of the session after the turn, for the gauge and the cost.
    status: *const ui.status.Info,
    now_ms: i64,

    pub const Outcome = enum { completed, canceled, failed };
};

const Turn = struct {
    started_ms: i64,
    /// The activity message, or null while the chat holds none.
    handle: ?Attachment.Handle,
    /// The state the activity message shows.
    activity: Activity,
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

/// Whether the blocks of a flush go out silent, or the last one notifies.
const Notify = enum { silent, last };

pub fn init(gpa: std.mem.Allocator) Mirror {
    return .{ .gpa = gpa, .cursor = 0, .turn = null };
}

/// Start the mirror at the committed frontier of `view`. The attach event stands
/// in the chat already, and the blocks before it stay in the terminal. A turn
/// that runs gets its activity message now, because its start lies before the
/// attach.
pub fn open(self: *Mirror, chat: anytype, view: *const View) !void {
    self.cursor = view.committed;
    const turn = if (self.turn) |*turn| turn else return;
    turn.handle = null;
    if (view.tail) |*tail| turn.activity = Activity.of(tail);
    try self.startActivity(chat);
}

/// Record the start of a turn at `now_ms`, and send its activity message. The
/// message stands above the answer blocks of the turn as its header.
pub fn beginTurn(self: *Mirror, chat: anytype, now_ms: i64) !void {
    self.turn = .{ .started_ms = now_ms, .handle = null, .activity = .idle };
    if (!chat.listens()) return;
    try self.startActivity(chat);
}

fn startActivity(self: *Mirror, chat: anytype) !void {
    const turn = &self.turn.?;
    var buffer: [activity_bytes_max]u8 = undefined;
    turn.handle = try chat.sendTracked(
        turn.activity.text(&buffer),
        &.{ .disable_notification = true },
    );
}

/// Send every block that committed since the last step, and edit the activity
/// message when the state of the live tail changed.
pub fn sync(self: *Mirror, chat: anytype, view: *const View) !void {
    if (!chat.listens()) return;
    try self.flush(chat, view, .silent);
    const turn = if (self.turn) |*turn| turn else return;
    const tail = view.tail orelse return;
    const activity = Activity.of(&tail);
    if (activity.eql(&turn.activity)) return;
    turn.activity = activity;
    const handle = turn.handle orelse return;
    var buffer: [activity_bytes_max]u8 = undefined;
    try chat.edit(handle, activity.text(&buffer));
}

/// Send the last blocks of the turn, and turn the activity message into the
/// summary of the turn. The last message of a completed or failed turn
/// notifies. A canceled turn ends in silence, because the cancel came from the
/// chat or the terminal took the session over.
pub fn endTurn(self: *Mirror, chat: anytype, view: *const View, end: *const End) !void {
    defer self.turn = null;
    if (!chat.listens()) return;
    try self.flush(chat, view, if (end.outcome == .canceled) .silent else .last);
    const turn = if (self.turn) |*turn| turn else return;
    const handle = turn.handle orelse return;
    const text = try self.summary(turn, end);
    defer self.gpa.free(text);
    try chat.edit(handle, text);
}

/// Move the cursor back over `count` blocks that left the transcript below it,
/// so the blocks behind them still go out once.
pub fn retreat(self: *Mirror, count: usize) void {
    self.cursor -|= count;
}

/// Start over at the first block, because the transcript was cleared. The
/// length alone cannot tell a cleared transcript from one that grew back.
pub fn restart(self: *Mirror) void {
    self.cursor = 0;
}

/// Send the blocks from the cursor to the committed frontier. Every block
/// renders before the first send, because a send can report into the transcript
/// and move its blocks. The cursor moves past them before the sends too, so a
/// block whose send fails goes out no twice.
fn flush(self: *Mirror, chat: anytype, view: *const View, notify: Notify) !void {
    self.cursor = @min(self.cursor, view.blocks.len);
    const end = view.committed;
    if (self.cursor >= end) return;
    var rendered: std.ArrayList([]u8) = .empty;
    defer {
        for (rendered.items) |text| self.gpa.free(text);
        rendered.deinit(self.gpa);
    }
    for (view.blocks[self.cursor..end]) |*block| {
        const text = try self.renderBlock(block) orelse continue;
        errdefer self.gpa.free(text);
        try rendered.append(self.gpa, text);
    }
    self.cursor = end;
    for (rendered.items, 0..) |text, index| {
        const last = notify == .last and index + 1 == rendered.items.len;
        try self.sendHtml(chat, text, last);
    }
}

/// The HTML of `block`, or null for a block that stays in the terminal. The
/// result is owned.
fn renderBlock(self: *Mirror, block: *const ui.block.Entry) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    switch (block.content) {
        .model => |list| try html.render(&out.writer, std.mem.trimEnd(u8, list.items, " \t\r\n")),
        .user_note => |list| {
            try out.writer.writeAll("<i>");
            try html.escape(&out.writer, list.items);
            try out.writer.writeAll("</i>");
        },
        .event => |flagged| {
            if (!flagged.mirrored) return null;
            try out.writer.writeAll(if (flagged.is_error) "Error: " else "Event: ");
            try html.escape(&out.writer, flagged.text.items);
        },
        .intro, .user, .thinking, .tool_result => return null,
    }
    if (out.written().len == 0) return null;
    return try out.toOwnedSlice();
}

/// Send one rendered block, in as many messages as its length takes. The last
/// message notifies when `notify` is set.
fn sendHtml(self: *Mirror, chat: anytype, text: []const u8, notify: bool) !void {
    var parts = html.Parts.init(text, html.message_units_max);
    // Every part consumes text, so the split ends.
    while (try parts.next(self.gpa)) |part| {
        defer self.gpa.free(part.text);
        try chat.send(part.text, &.{
            .parse_mode = parse_mode,
            .disable_notification = !(notify and part.last),
        });
    }
}

/// The summary of the turn: its outcome where it did not complete, the tool
/// count, the time, and the numbers of the status line. The result is owned.
fn summary(self: *Mirror, turn: *const Turn, end: *const End) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    errdefer out.deinit();
    switch (end.outcome) {
        .completed => {},
        .canceled => try out.writer.print("Canceled{s}", .{ui.paint.separator}),
        .failed => try out.writer.print("Failed{s}", .{ui.paint.separator}),
    }
    try writeCalls(&out.writer, turn.activity.calls);
    var buffer: [24]u8 = undefined;
    try out.writer.print("{s}Time: {s}{s}", .{
        ui.paint.separator,
        ai.format.duration(&buffer, end.now_ms - turn.started_ms),
        ui.paint.separator,
    });
    try ui.status.writeNumbers(&out.writer, end.status);
    return out.toOwnedSlice();
}

/// The tool count as `Tools: N calls`.
fn writeCalls(out: *std.Io.Writer, calls: usize) !void {
    try out.print("Tools: {d} {s}", .{ calls, if (calls == 1) "call" else "calls" });
}

/// The chat of the tests: it records every send and every edit.
const Recorder = struct {
    gpa: std.mem.Allocator,
    sends: std.ArrayList(Sent) = .empty,
    edits: std.ArrayList(Edited) = .empty,
    handle_next: Attachment.Handle = 1,

    const Sent = struct {
        text: []u8,
        options: Client.SendOptions,
        handle: ?Attachment.Handle,
    };

    const Edited = struct {
        handle: Attachment.Handle,
        text: []u8,
    };

    fn deinit(self: *Recorder) void {
        for (self.sends.items) |sent| self.gpa.free(sent.text);
        self.sends.deinit(self.gpa);
        for (self.edits.items) |edited| self.gpa.free(edited.text);
        self.edits.deinit(self.gpa);
    }

    fn listens(_: *const Recorder) bool {
        return true;
    }

    fn send(self: *Recorder, text: []const u8, options: *const Client.SendOptions) !void {
        try self.sends.append(self.gpa, .{
            .text = try self.gpa.dupe(u8, text),
            .options = options.*,
            .handle = null,
        });
    }

    fn sendTracked(
        self: *Recorder,
        text: []const u8,
        options: *const Client.SendOptions,
    ) !?Attachment.Handle {
        const handle = self.handle_next;
        self.handle_next += 1;
        try self.sends.append(self.gpa, .{
            .text = try self.gpa.dupe(u8, text),
            .options = options.*,
            .handle = handle,
        });
        return handle;
    }

    fn edit(self: *Recorder, handle: Attachment.Handle, text: []const u8) !void {
        try self.edits.append(self.gpa, .{ .handle = handle, .text = try self.gpa.dupe(u8, text) });
    }

    fn lastSend(self: *const Recorder) *const Sent {
        return &self.sends.items[self.sends.items.len - 1];
    }

    fn lastEdit(self: *const Recorder) *const Edited {
        return &self.edits.items[self.edits.items.len - 1];
    }
};

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
    .account = .anthropic_subscription,
    .quota = null,
    .quota_age_ms = 0,
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
    try std.testing.expectEqualStrings("Event: Drinky changed the model.", chat.sends.items[1].text);
    try std.testing.expectEqualStrings(
        "<i>Skill: zig-style · File: &lt;skill&gt;</i>",
        chat.sends.items[2].text,
    );
    // A second step over the same blocks sends nothing.
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
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
    try std.testing.expectEqualStrings("Event: Drinky started retry attempt 1.", chat.sends.items[0].text);
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

    try mirror.beginTurn(&chat, 1_000);
    try std.testing.expectEqualStrings("Thinking", chat.sends.items[0].text);
    try std.testing.expect(chat.sends.items[0].handle != null);
    try std.testing.expect(chat.sends.items[0].options.disable_notification);
    const handle = chat.sends.items[0].handle.?;

    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = null, .calls = 0 }));
    try std.testing.expectEqual(@as(usize, 0), chat.edits.items.len);
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = .model, .tool = null, .calls = 0 }));
    try std.testing.expectEqualStrings("Writing", chat.lastEdit().text);
    try std.testing.expectEqual(handle, chat.lastEdit().handle);
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .calls = 1 }));
    try std.testing.expectEqualStrings("Running: bash · Tools: 1 call", chat.lastEdit().text);
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .calls = 1 }));
    try std.testing.expectEqual(@as(usize, 2), chat.edits.items.len);
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = .thinking, .tool = null, .calls = 2 }));
    try std.testing.expectEqualStrings("Thinking · Tools: 2 calls", chat.lastEdit().text);

    // The last answer block closes at the receipt, so it goes out with the end
    // of the turn, and it alone notifies.
    try blocks.append(.model, .{}, "first");
    try blocks.append(.model, .{}, "last");
    try mirror.endTurn(&chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 126_400,
    });
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
    try std.testing.expect(chat.sends.items[1].options.disable_notification);
    try std.testing.expectEqualStrings("last", chat.sends.items[2].text);
    try std.testing.expect(!chat.sends.items[2].options.disable_notification);
    try std.testing.expectEqualStrings(
        "Tools: 2 calls · Time: 2m 5s · Context: 45% · Cost: ~$0.42",
        chat.lastEdit().text,
    );
    try std.testing.expect(mirror.turn == null);
}

test "a canceled turn ends in silence, and a failed turn notifies its error" {
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
    try std.testing.expectEqualStrings(
        "Canceled · Tools: 0 calls · Time: 500ms · Context: 45% · Cost: ~$0.42",
        chat.lastEdit().text,
    );

    try mirror.beginTurn(&chat, 1_000);
    try blocks.append(.event, .{ .is_error = true }, "The provider refused the request.");
    try mirror.endTurn(&chat, &blocks.idle(), &.{ .outcome = .failed, .status = &test_status, .now_ms = 3_000 });
    try std.testing.expectEqualStrings("Error: The provider refused the request.", chat.lastSend().text);
    try std.testing.expect(!chat.lastSend().options.disable_notification);
    try std.testing.expect(std.mem.startsWith(u8, chat.lastEdit().text, "Failed · Tools: 0 calls · Time: 2.0s"));
}

test "an open starts at the committed frontier and gives a running turn its activity message" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.model, .{}, "before the attach");
    try blocks.append(.event, .{ .mirrored = false }, "Remote: @drinky_bot · Context: 0%");
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
    try std.testing.expectEqualStrings("Running: read · Tools: 3 calls", chat.lastSend().text);
    try std.testing.expectEqual(@as(?Attachment.Handle, 2), chat.lastSend().handle);
}

test "the cursor follows a cleared transcript and moves back over dropped blocks" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(.thinking, .{ .account = .anthropic_subscription }, "weigh it");
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
    try std.testing.expectEqualStrings("Event: Drinky replaced the credential.", chat.lastSend().text);

    // A new conversation clears everything, and the mirror starts over. The
    // cleared transcript grows back to the same length in the same step, so the
    // length alone could not tell.
    blocks.truncate(0);
    try blocks.append(.intro, .{}, "legend");
    try blocks.append(.event, .{}, "fresh");
    mirror.restart();
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
    try std.testing.expectEqualStrings("Event: fresh", chat.lastSend().text);
}

/// A chat that reports into the transcript on every send, as the controller does
/// when the queue drops a message. The report appends a block, so a send moves
/// the blocks of the transcript.
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

    fn edit(_: *Reporter, _: Attachment.Handle, _: []const u8) !void {}
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

test "a long answer splits into several messages, and the last one alone notifies" {
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
    // The activity message, then two parts of the answer.
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
    try std.testing.expect(chat.sends.items[1].text.len <= html.message_units_max);
    try std.testing.expect(chat.sends.items[1].options.disable_notification);
    try std.testing.expect(!chat.sends.items[2].options.disable_notification);
}
