const std = @import("std");

const ai = @import("ai");

const ui = @import("../ui/root.zig");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const html = @import("html.zig");
const keyboard = @import("keyboard.zig");

const Mirror = @This();

const activity_bytes_max = 96;

const cancel_label = "Cancel turn";
const withdraw_label = "Withdraw";

const retry_text = "Failed turn";
const retry_label = "Try again";
const dismiss_label = "Dismiss";

const shorten_label = "Shorten";

gpa: std.mem.Allocator,
cursor: usize,
turn: ?Turn,
retry: ?RetryMessage,
answer_serial: ?u64,
serial: u64,

pub const View = struct {
    blocks: []const ui.block.Entry,
    committed: usize,
    tail: ?Tail,
    retry_waits: bool = false,

    pub const Tail = struct {
        streaming: ?ui.block.Entry.Kind,
        tool: ?[]const u8,
        calls: usize,
    };

    fn toolRuns(self: *const View) bool {
        const tail = self.tail orelse return false;
        return tail.tool != null;
    }
};

pub const End = struct {
    outcome: Outcome,
    status: *const ui.status.Info,
    now_ms: i64,
    retry_armed: bool = false,

    pub const Outcome = enum { completed, canceled, failed };
};

const Turn = struct {
    started_ms: i64,
    handle: ?Attachment.Handle,
    activity: Activity,
    serial: u64,
};

const RetryMessage = struct {
    handle: ?Attachment.Handle,
    serial: u64,
};

const Activity = struct {
    phase: Phase,
    calls: usize,
    tool_buffer: [tool_bytes_max]u8,
    tool_length: usize,

    const Phase = enum { thinking, writing, running };

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

const Close = struct {
    shorten: bool = false,
    hold_answer: bool = false,
};

const Rendered = struct {
    text: []u8,
    answer: bool,
};

const Send = struct {
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

pub fn seedSerials(self: *Mirror, seed: u64) void {
    self.serial = seed;
}

pub fn open(self: *Mirror, chat: anytype, view: *const View) !void {
    self.cursor = view.committed;
    if (view.retry_waits) try self.sendRetry(chat);
    const turn = if (self.turn) |*turn| turn else return;
    turn.handle = null;
    if (view.tail) |*tail| turn.activity = Activity.of(tail);
    try self.startActivity(chat);
}

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

fn activityText(self: *Mirror, turn: *const Turn) ![]u8 {
    var buffer: [activity_bytes_max]u8 = undefined;
    return html.wrapAlloc(self.gpa, .information, turn.activity.text(&buffer));
}

pub fn sync(self: *Mirror, chat: anytype, view: *const View) !void {
    if (!chat.listens()) return;
    try self.flush(chat, view, .{ .hold_answer = self.turn != null and !view.toolRuns() });
    const turn = if (self.turn) |*turn| turn else return;
    const tail = view.tail orelse return;
    const activity = Activity.of(&tail);
    if (activity.eql(&turn.activity)) return;
    turn.activity = activity;
    try self.editActivity(chat, turn);
}

fn editActivity(self: *Mirror, chat: anytype, turn: *const Turn) !void {
    const handle = turn.handle orelse return;
    const markup = try self.activityMarkup(turn);
    defer self.gpa.free(markup);
    const text = try self.activityText(turn);
    defer self.gpa.free(text);
    try chat.edit(handle, text, &.{ .parse_mode = html.parse_mode, .markup = markup });
}

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

fn editSummary(self: *Mirror, chat: anytype, turn: *const Turn, end: *const End) !void {
    const handle = turn.handle orelse return;
    const text = try self.summary(turn, end);
    defer self.gpa.free(text);
    try chat.edit(handle, text, &.{ .parse_mode = html.parse_mode });
}

fn sendSummary(self: *Mirror, chat: anytype, turn: *const Turn, end: *const End) !void {
    const text = try self.summary(turn, end);
    defer self.gpa.free(text);
    if ((try chat.sendTracked(text, &.{
        .disable_notification = false,
        .parse_mode = html.parse_mode,
    })) == null) return;
    if (turn.handle) |handle| try chat.delete(handle);
}

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

pub fn dismissRetry(self: *Mirror, chat: anytype) !void {
    const retry = self.retry orelse return;
    self.retry = null;
    const handle = retry.handle orelse return;
    const text = try self.retryText();
    defer self.gpa.free(text);
    try chat.edit(handle, text, &.{ .parse_mode = html.parse_mode });
}

fn retryText(self: *Mirror) ![]u8 {
    return html.wrapAlloc(self.gpa, .failure, retry_text);
}

pub fn namesTurn(self: *const Mirror, serial: u64) bool {
    const turn = self.turn orelse return false;
    return turn.serial == serial;
}

pub fn namesRetry(self: *const Mirror, serial: u64) bool {
    const retry = self.retry orelse return false;
    return retry.serial == serial;
}

pub fn namesAnswer(self: *const Mirror, serial: u64) bool {
    const live = self.answer_serial orelse return false;
    return live == serial;
}

pub fn detached(self: *Mirror) void {
    self.retry = null;
    self.answer_serial = null;
    const turn = if (self.turn) |*turn| turn else return;
    turn.handle = null;
}

fn nextSerial(self: *Mirror) u64 {
    self.serial +%= 1;
    return self.serial;
}

pub fn transcriptCursor(self: *const Mirror) usize {
    return self.cursor;
}

pub fn retreat(self: *Mirror, count: usize) void {
    self.cursor -|= count;
}

pub fn restart(self: *Mirror) void {
    self.cursor = 0;
    self.answer_serial = null;
}

fn flush(self: *Mirror, chat: anytype, view: *const View, close: Close) !void {
    self.cursor = @min(self.cursor, view.blocks.len);
    var end = view.committed;
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
    if (answer_index != null and shorten_index == null) self.answer_serial = null;
    for (rendered.items, 0..) |item, index| {
        try self.sendHtml(chat, item.text, .{
            .markup = if (shorten_index == index) markup else null,
        });
    }
}

fn lastAnswer(items: []const Rendered) ?usize {
    var index = items.len;
    while (index > 0) {
        index -= 1;
        if (items[index].answer) return index;
    }
    return null;
}

fn armShorten(self: *Mirror) ![]u8 {
    const serial = self.nextSerial();
    var data: [keyboard.data_bytes_max]u8 = undefined;
    const json = try keyboard.markup(self.gpa, &.{
        .{ .text = shorten_label, .data = (keyboard.Tap{ .shorten = serial }).write(&data) },
    });
    self.answer_serial = serial;
    return json;
}

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

fn sendHtml(self: *Mirror, chat: anytype, text: []const u8, send: Send) !void {
    var parts = html.Parts.init(text, html.message_units_max);
    while (try parts.next(self.gpa)) |part| {
        defer self.gpa.free(part.text);
        try chat.send(part.text, &.{
            .parse_mode = html.parse_mode,
            .disable_notification = true,
            .markup = if (part.last) send.markup else null,
        });
    }
}

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

fn writeCalls(out: *std.Io.Writer, calls: usize) !void {
    try out.print("Tools: {d} {s}", .{ calls, if (calls == 1) "call" else "calls" });
}

const Recorder = struct {
    gpa: std.mem.Allocator,
    sends: std.ArrayList(Sent) = .empty,
    edits: std.ArrayList(Edited) = .empty,
    deletions: std.ArrayList(Attachment.Handle) = .empty,
    handle_next: Attachment.Handle = 1,
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

fn activityKeyboard(comptime serial: []const u8) []const u8 {
    return "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:" ++
        serial ++ "\"}],[{\"text\":\"Withdraw\",\"callback_data\":\"withdraw:" ++ serial ++ "\"}]]}";
}

const retry_wrapped = "⚠ " ++ retry_text;

fn retryKeyboard(comptime serial: []const u8) []const u8 {
    return "{\"inline_keyboard\":[[{\"text\":\"Try again\",\"callback_data\":\"retry:" ++ serial ++
        "\"}],[{\"text\":\"Dismiss\",\"callback_data\":\"dismiss:" ++ serial ++ "\"}]]}";
}

fn shortenKeyboard(comptime serial: []const u8) []const u8 {
    return "{\"inline_keyboard\":[[{\"text\":\"Shorten\",\"callback_data\":\"shorten:" ++ serial ++
        "\"}]]}";
}

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

    fn compact(self: *Blocks) void {
        self.items.shrinkAndFree(self.gpa, self.items.items.len);
    }

    fn idle(self: *const Blocks) View {
        return .{ .blocks = self.items.items, .committed = self.items.items.len, .tail = null };
    }

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
    .account = .anthropic_plan,
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

    try mirror.beginTurn(&chat, 1_000);
    try std.testing.expectEqualStrings("ℹ Thinking", chat.sends.items[0].text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.sends.items[0].options.parse_mode.?);
    try std.testing.expect(chat.sends.items[0].handle != null);
    try std.testing.expect(chat.sends.items[0].options.disable_notification);
    try std.testing.expectEqualStrings(activityKeyboard("1"), chat.sends.items[0].markup.?);
    const handle = chat.sends.items[0].handle.?;

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
    try std.testing.expect(!mirror.namesTurn(1));
}

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

    try mirror.endTurn(&chat, &blocks.idle(), &.{ .outcome = .canceled, .status = &test_status, .now_ms = 0 });
    try mirror.beginTurn(&chat, 0);
    try std.testing.expectEqualStrings(activityKeyboard("2"), chat.lastSend().markup.?);
    try std.testing.expect(!mirror.namesTurn(1));
    try std.testing.expect(mirror.namesTurn(2));
}

test "a failed turn that armed a retry sends the failed turn message, which loses its buttons with the retry" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

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
    try std.testing.expectEqualStrings(retry_wrapped, chat.lastSend().text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.lastSend().options.parse_mode.?);
    try std.testing.expectEqualStrings(retryKeyboard("3"), chat.lastSend().markup.?);
    try std.testing.expect(chat.lastSend().options.disable_notification);
    const handle = chat.lastSend().handle.?;
    try std.testing.expect(mirror.namesRetry(3));
    try std.testing.expect(!mirror.namesRetry(2));

    try mirror.dismissRetry(&chat);
    try std.testing.expectEqual(handle, chat.lastEdit().handle);
    try std.testing.expectEqualStrings(retry_wrapped, chat.lastEdit().text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.lastEdit().parse_mode.?);
    try std.testing.expect(chat.lastEdit().markup == null);
    try std.testing.expect(!mirror.namesRetry(3));
    const edits = chat.edits.items.len;
    try mirror.dismissRetry(&chat);
    try std.testing.expectEqual(edits, chat.edits.items.len);

    try mirror.open(&chat, &.{ .blocks = &.{}, .committed = 0, .tail = null, .retry_waits = true });
    try std.testing.expectEqualStrings(retry_wrapped, chat.lastSend().text);
    try std.testing.expectEqualStrings(retryKeyboard("4"), chat.lastSend().markup.?);
    try std.testing.expect(mirror.namesRetry(4));
}

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

    try mirror.open(&chat, &blocks.idle());
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 0), chat.sends.items.len);

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
    try blocks.append(.thinking, .{ .account = .anthropic_plan }, "weigh it");
    try blocks.append(.model, .{}, "answer");
    var mirror = Mirror.init(gpa);
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);

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

    blocks.truncate(0);
    try blocks.append(.intro, .{}, "legend");
    try blocks.append(.event, .{}, "fresh");
    mirror.restart();
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), chat.sends.items.len);
    try std.testing.expectEqualStrings("ℹ fresh", chat.lastSend().text);
}

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

    const view = blocks.idle();
    try mirror.sync(&chat, &view);
    try std.testing.expectEqual(@as(usize, 3), chat.sends);
    try std.testing.expectEqual(@as(usize, 6), blocks.items.items.len);
    try mirror.sync(&chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), chat.sends);
}

test "a completed turn gives its last answer the shorten button, and a newer answer stales it" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);
    try std.testing.expect(!mirror.namesAnswer(0));

    try mirror.beginTurn(&chat, 0);
    try blocks.append(.model, .{}, "first");
    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = .model, .tool = null, .calls = 0 }));
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);

    try mirror.sync(&chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .calls = 1 }));
    try std.testing.expectEqual(@as(usize, 2), chat.sends.items.len);
    try std.testing.expectEqualStrings("first", chat.sends.items[1].text);
    try std.testing.expect(chat.sends.items[1].markup == null);
    try std.testing.expect(mirror.answer_serial == null);

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

    mirror.restart();
    try std.testing.expect(!mirror.namesAnswer(4));
}

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
    try std.testing.expectEqual(@as(usize, 4), chat.sends.items.len);
    try std.testing.expect(chat.sends.items[1].text.len <= html.message_units_max);
    try std.testing.expect(chat.sends.items[1].options.disable_notification);
    try std.testing.expect(chat.sends.items[2].options.disable_notification);
    try std.testing.expect(!chat.lastSend().options.disable_notification);
    try std.testing.expect(chat.sends.items[1].markup == null);
    try std.testing.expectEqualStrings(shortenKeyboard("2"), chat.sends.items[2].markup.?);
    try std.testing.expect(chat.lastSend().markup == null);
}
