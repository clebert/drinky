const std = @import("std");

const core = @import("core");
const tools = @import("tools");

const ui = @import("../ui/root.zig");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const html = @import("html.zig");
const keyboard = @import("keyboard.zig");

const Mirror = @This();

const activity_bytes_max = 96;

gpa: std.mem.Allocator,
cursor: usize,
turn: ?Turn,
serial: u64,

pub const View = struct {
    blocks: []const ui.Block,
    committed: usize,
    tail: ?Tail,

    const Tail = struct {
        streaming: ?ui.Block.Kind,
        tool: ?[]const u8,
        call_count: usize,
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

    pub const Outcome = enum { completed, canceled, failed };
};

pub const Chat = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        listens: *const fn (ptr: *anyopaque) bool,
        send: *const fn (
            ptr: *anyopaque,
            text: []const u8,
            options: *const Client.SendOptions,
        ) Error!void,
        sendTracked: *const fn (
            ptr: *anyopaque,
            text: []const u8,
            options: *const Client.SendOptions,
        ) Error!?Attachment.Handle,
        edit: *const fn (
            ptr: *anyopaque,
            handle: Attachment.Handle,
            text: []const u8,
            options: *const Client.EditOptions,
        ) Error!void,
        delete: *const fn (ptr: *anyopaque, handle: Attachment.Handle) Error!void,
    };

    pub const Error = error{OutOfMemory};

    fn listens(self: Chat) bool {
        return self.vtable.listens(self.ptr);
    }

    fn send(self: Chat, text: []const u8, options: *const Client.SendOptions) Error!void {
        return self.vtable.send(self.ptr, text, options);
    }

    fn sendTracked(
        self: Chat,
        text: []const u8,
        options: *const Client.SendOptions,
    ) Error!?Attachment.Handle {
        return self.vtable.sendTracked(self.ptr, text, options);
    }

    fn edit(
        self: Chat,
        handle: Attachment.Handle,
        text: []const u8,
        options: *const Client.EditOptions,
    ) Error!void {
        return self.vtable.edit(self.ptr, handle, text, options);
    }

    fn delete(self: Chat, handle: Attachment.Handle) Error!void {
        return self.vtable.delete(self.ptr, handle);
    }
};

const Turn = struct {
    started_ms: i64,
    handle: ?Attachment.Handle,
    activity: Activity,
    serial: u64,
};

const Activity = struct {
    phase: Phase,
    call_count: usize,
    tool_buffer: [tool_bytes_max]u8,
    tool_length: usize,

    const Phase = enum { thinking, writing, running };

    const tool_bytes_max = 32;

    const idle: Activity = .{
        .phase = .thinking,
        .call_count = 0,
        .tool_buffer = undefined,
        .tool_length = 0,
    };

    fn of(tail: *const View.Tail) Activity {
        var activity = idle;
        activity.call_count = tail.call_count;
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
        return self.phase == other.phase and self.call_count == other.call_count and
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
        if (self.call_count == 0) return;
        try out.writeAll(ui.paint.separator);
        try writeCallCount(out, self.call_count);
    }
};

const Flush = struct {
    hold_answer: bool = false,
};

pub fn init(gpa: std.mem.Allocator) Mirror {
    return .{
        .gpa = gpa,
        .cursor = 0,
        .turn = null,
        .serial = 0,
    };
}

pub fn seedSerials(self: *Mirror, seed: u64) void {
    self.serial = seed;
}

pub fn open(self: *Mirror, chat: Chat, view: *const View) !void {
    self.cursor = view.committed;
    const turn = if (self.turn) |*turn| turn else return;
    turn.handle = null;
    if (view.tail) |*tail| turn.activity = Activity.of(tail);
    try self.startActivity(chat);
}

pub fn beginTurn(self: *Mirror, chat: Chat, now_ms: i64) !void {
    self.turn = .{
        .started_ms = now_ms,
        .handle = null,
        .activity = .idle,
        .serial = self.nextSerial(),
    };
    if (!chat.listens()) return;
    try self.startActivity(chat);
}

fn startActivity(self: *Mirror, chat: Chat) !void {
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
    return html.noticeAlloc(self.gpa, .information, turn.activity.text(&buffer));
}

pub fn sync(self: *Mirror, chat: Chat, view: *const View) !void {
    if (!chat.listens()) return;
    try self.flush(chat, view, .{ .hold_answer = self.turn != null and !view.toolRuns() });
    const turn = if (self.turn) |*turn| turn else return;
    const tail = view.tail orelse return;
    const activity = Activity.of(&tail);
    if (activity.eql(&turn.activity)) return;
    turn.activity = activity;
    try self.editActivity(chat, turn);
}

fn editActivity(self: *Mirror, chat: Chat, turn: *const Turn) !void {
    const handle = turn.handle orelse return;
    const markup = try self.activityMarkup(turn);
    defer self.gpa.free(markup);
    const text = try self.activityText(turn);
    defer self.gpa.free(text);
    try chat.edit(handle, text, &.{ .parse_mode = html.parse_mode, .markup = markup });
}

fn activityMarkup(self: *Mirror, turn: *const Turn) ![]u8 {
    return keyboard.markup(self.gpa, &.{&.{.{ .cancel = turn.serial }}});
}

pub fn endTurn(self: *Mirror, chat: Chat, view: *const View, end: *const End) !void {
    defer self.turn = null;
    if (!chat.listens()) return;
    try self.flush(chat, view, .{});
    if (self.turn) |*turn| {
        if (end.outcome == .canceled)
            try self.editSummary(chat, turn, end)
        else
            try self.sendSummary(chat, turn, end);
    }
}

fn editSummary(self: *Mirror, chat: Chat, turn: *const Turn, end: *const End) !void {
    const handle = turn.handle orelse return;
    const text = try self.summary(turn, end);
    defer self.gpa.free(text);
    try chat.edit(handle, text, &.{ .parse_mode = html.parse_mode });
}

fn sendSummary(self: *Mirror, chat: Chat, turn: *const Turn, end: *const End) !void {
    const text = try self.summary(turn, end);
    defer self.gpa.free(text);
    if ((try chat.sendTracked(text, &.{
        .disable_notification = false,
        .parse_mode = html.parse_mode,
    })) == null) return;
    if (turn.handle) |handle| try chat.delete(handle);
}

pub fn namesTurn(self: *const Mirror, serial: u64) bool {
    const turn = self.turn orelse return false;
    return turn.serial == serial;
}

pub fn forgetActivity(self: *Mirror) void {
    const turn = if (self.turn) |*turn| turn else return;
    turn.handle = null;
}

fn nextSerial(self: *Mirror) u64 {
    self.serial +%= 1;
    return self.serial;
}

pub fn resetCursor(self: *Mirror) void {
    self.cursor = 0;
}

fn flush(self: *Mirror, chat: Chat, view: *const View, options: Flush) !void {
    self.cursor = @min(self.cursor, view.blocks.len);
    var end = view.committed;
    while (options.hold_answer and end > self.cursor and view.blocks[end - 1].content == .model)
        end -= 1;
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
    for (rendered.items) |text| try self.sendHtml(chat, text);
}

fn renderBlock(self: *Mirror, block: *const ui.Block) error{OutOfMemory}!?[]u8 {
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    writeBlock(&out.writer, block) catch return error.OutOfMemory;
    if (out.written().len == 0) return null;
    return try out.toOwnedSlice();
}

fn writeBlock(out: *std.Io.Writer, block: *const ui.Block) std.Io.Writer.Error!void {
    switch (block.content) {
        .model => |list| try html.render(out, std.mem.trimEnd(u8, list.items, " \t\r\n")),
        .user_note => |list| try html.notice(out, .note, list.items),
        .event => |*event| if (event.mirrored) {
            try html.notice(out, .of(event.severity), event.text.items);
        },
        .intro, .user, .thinking, .tool_result => {},
    }
}

fn sendHtml(self: *Mirror, chat: Chat, text: []const u8) !void {
    var parts = html.Parts.init(text, html.message_units_max);
    while (try parts.next(self.gpa)) |part| {
        defer self.gpa.free(part);
        try chat.send(part, &.{ .parse_mode = html.parse_mode, .disable_notification = true });
    }
}

fn summary(self: *Mirror, turn: *const Turn, end: *const End) error{OutOfMemory}![]u8 {
    var text: std.Io.Writer.Allocating = .init(self.gpa);
    defer text.deinit();
    writeSummary(&text.writer, turn, end) catch return error.OutOfMemory;
    const role: html.Role = if (end.outcome == .failed) .failure else .information;
    return html.noticeAlloc(self.gpa, role, text.written());
}

fn writeSummary(out: *std.Io.Writer, turn: *const Turn, end: *const End) std.Io.Writer.Error!void {
    switch (end.outcome) {
        .completed => {},
        .canceled => try out.print("Canceled{s}", .{ui.paint.separator}),
        .failed => try out.print("Failed{s}", .{ui.paint.separator}),
    }
    try writeCallCount(out, turn.activity.call_count);
    var buffer: [24]u8 = undefined;
    try out.print("{s}Time: {s}{s}", .{
        ui.paint.separator,
        tools.format.duration(&buffer, end.now_ms - turn.started_ms),
        ui.paint.separator,
    });
    try ui.status.writeNumbers(out, end.status);
}

fn writeCallCount(out: *std.Io.Writer, count: usize) !void {
    try out.print("Tools: {d} call{s}", .{ count, core.text.pluralSuffix(count) });
}

test "a step sends each committed answer, event, and note once, and skips the rest" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(&.{ .intro = "legend" });
    try blocks.append(&.{ .user = "typed" });
    try blocks.append(&.{ .thinking = "weigh it" });
    try blocks.append(&.{ .model = "The **answer** & more.\n\n" });
    try blocks.append(&.{ .tool_result = .{ .text = "Tool: bash" } });
    try blocks.append(&.{ .event = .{ .text = "Drinky changed the model." } });
    try blocks.append(&.{ .event = .{
        .text = "Telegram rejected a message.",
        .severity = .failure,
        .mirrored = false,
    } });
    try blocks.append(&.{ .user_note = "Skill: zig-style · File: <skill>" });
    var mirror = Mirror.init(gpa);

    try mirror.sync(chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), recorder.sends.items.len);
    try std.testing.expectEqualStrings(
        "The <b>answer</b> &amp; more.",
        recorder.sends.items[0].text,
    );
    try std.testing.expectEqualStrings("HTML", recorder.sends.items[0].options.parse_mode.?);
    try std.testing.expect(recorder.sends.items[0].options.disable_notification);
    try std.testing.expectEqualStrings(
        "ℹ Drinky changed the model.",
        recorder.sends.items[1].text,
    );
    try std.testing.expectEqualStrings(
        "→ Skill: zig-style · File: &lt;skill&gt;",
        recorder.sends.items[2].text,
    );
    try mirror.sync(chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), recorder.sends.items.len);
}

const Recorder = struct {
    gpa: std.mem.Allocator,
    sends: std.ArrayList(Sent) = .empty,
    edits: std.ArrayList(Edited) = .empty,
    deletions: std.ArrayList(Attachment.Handle) = .empty,
    handle_next: Attachment.Handle = 1,
    drop_tracked: bool = false,
    send_hook: ?Hook = null,

    const Hook = struct {
        context: *anyopaque,
        run: *const fn (context: *anyopaque) Chat.Error!void,
    };

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

    const vtable: Chat.VTable = .{
        .listens = listens,
        .send = send,
        .sendTracked = sendTracked,
        .edit = edit,
        .delete = delete,
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

    fn chat(self: *Recorder) Chat {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn listens(_: *anyopaque) bool {
        return true;
    }

    fn send(
        ptr: *anyopaque,
        text: []const u8,
        options: *const Client.SendOptions,
    ) Chat.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        try self.record(text, options, null);
        if (self.send_hook) |hook| try hook.run(hook.context);
    }

    fn sendTracked(
        ptr: *anyopaque,
        text: []const u8,
        options: *const Client.SendOptions,
    ) Chat.Error!?Attachment.Handle {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
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
    ) Chat.Error!void {
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

    fn delete(ptr: *anyopaque, handle: Attachment.Handle) Chat.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        try self.deletions.append(self.gpa, handle);
    }

    fn edit(
        ptr: *anyopaque,
        handle: Attachment.Handle,
        text: []const u8,
        options: *const Client.EditOptions,
    ) Chat.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
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

    fn copyMarkup(self: *Recorder, markup: ?[]const u8) Chat.Error!?[]u8 {
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
        serial ++ "\"}]]}";
}

const Blocks = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(ui.Block) = .empty,

    fn deinit(self: *Blocks) void {
        for (self.items.items) |*block| block.deinit(self.gpa);
        self.items.deinit(self.gpa);
    }

    fn append(self: *Blocks, payload: *const ui.Block.Source) !void {
        try self.items.append(self.gpa, try ui.Block.init(self.gpa, payload));
    }

    fn truncate(self: *Blocks, count: usize) void {
        for (self.items.items[count..]) |*block| block.deinit(self.gpa);
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
    .account = "anthropic-plan",
    .quota = null,
    .quota_age_ms = 0,
    .credits = null,
    .turn_active = false,
};

test "a mirrored warning event opens with the warning symbol" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(&.{ .event = .{
        .text = "The account offers no model now.",
        .severity = .warning,
    } });
    var mirror = Mirror.init(gpa);

    try mirror.sync(chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 1), recorder.sends.items.len);
    try std.testing.expectEqualStrings(
        "⚠ The account offers no model now.",
        recorder.sends.items[0].text,
    );
}

test "a block above the committed frontier waits, and a rewound tail costs nothing" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(&.{ .user = "prompt" });
    try blocks.append(&.{ .model = "partial" });
    var mirror = Mirror.init(gpa);
    const tail: View.Tail = .{ .streaming = .model, .tool = null, .call_count = 0 };

    try mirror.sync(chat, &blocks.live(1, tail));
    try std.testing.expectEqual(@as(usize, 0), recorder.sends.items.len);
    blocks.truncate(1);
    try blocks.append(&.{ .event = .{
        .text = "Drinky started retry attempt 1.",
        .survives_rewind = true,
    } });
    try blocks.append(&.{ .model = "whole" });
    try mirror.sync(chat, &blocks.live(2, tail));
    try std.testing.expectEqual(@as(usize, 1), recorder.sends.items.len);
    try std.testing.expectEqualStrings(
        "ℹ Drinky started retry attempt 1.",
        recorder.sends.items[0].text,
    );
    try mirror.sync(chat, &blocks.live(3, tail));
    try std.testing.expectEqualStrings("whole", recorder.lastSend().text);
}

test "the activity message edits on a state change alone, and the summary ends it" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(&.{ .user = "prompt" });
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(chat, 1_000);
    try std.testing.expectEqualStrings("ℹ Thinking", recorder.sends.items[0].text);
    try std.testing.expectEqualStrings(
        html.parse_mode,
        recorder.sends.items[0].options.parse_mode.?,
    );
    try std.testing.expect(recorder.sends.items[0].handle != null);
    try std.testing.expect(recorder.sends.items[0].options.disable_notification);
    try std.testing.expectEqualStrings(activityKeyboard("1"), recorder.sends.items[0].markup.?);
    const handle = recorder.sends.items[0].handle.?;

    try mirror.sync(chat, &blocks.live(1, .{ .streaming = null, .tool = null, .call_count = 0 }));
    try std.testing.expectEqual(@as(usize, 0), recorder.edits.items.len);
    try mirror.sync(chat, &blocks.live(1, .{ .streaming = .model, .tool = null, .call_count = 0 }));
    try std.testing.expectEqualStrings("ℹ Writing", recorder.lastEdit().text);
    try std.testing.expectEqualStrings(html.parse_mode, recorder.lastEdit().parse_mode.?);
    try std.testing.expectEqual(handle, recorder.lastEdit().handle);
    try std.testing.expectEqualStrings(activityKeyboard("1"), recorder.lastEdit().markup.?);
    try mirror.sync(chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .call_count = 1 }));
    try std.testing.expectEqualStrings("ℹ Running: bash · Tools: 1 call", recorder.lastEdit().text);
    try mirror.sync(chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .call_count = 1 }));
    try std.testing.expectEqual(@as(usize, 2), recorder.edits.items.len);
    try mirror.sync(
        chat,
        &blocks.live(1, .{ .streaming = .thinking, .tool = null, .call_count = 2 }),
    );
    try std.testing.expectEqualStrings("ℹ Thinking · Tools: 2 calls", recorder.lastEdit().text);

    try blocks.append(&.{ .model = "first" });
    try blocks.append(&.{ .model = "last" });
    try mirror.endTurn(chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 126_400,
    });
    try std.testing.expectEqual(@as(usize, 4), recorder.sends.items.len);
    try std.testing.expect(recorder.sends.items[1].options.disable_notification);
    try std.testing.expectEqualStrings("last", recorder.sends.items[2].text);
    try std.testing.expect(recorder.sends.items[2].options.disable_notification);
    try std.testing.expectEqualStrings(
        "ℹ Tools: 2 calls · Time: 2m 5s · Context: 45% · Cost: ~$0.42",
        recorder.lastSend().text,
    );
    try std.testing.expect(!recorder.lastSend().options.disable_notification);
    try std.testing.expectEqualStrings(html.parse_mode, recorder.lastSend().options.parse_mode.?);
    try std.testing.expect(recorder.lastSend().markup == null);
    try std.testing.expectEqual(@as(usize, 1), recorder.deletions.items.len);
    try std.testing.expectEqual(handle, recorder.deletions.items[0]);
    try std.testing.expect(!mirror.namesTurn(1));
}

test "a tap names the running turn alone, and the next turn makes its serial stale" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);
    try std.testing.expect(!mirror.namesTurn(1));
    try mirror.beginTurn(chat, 0);

    try std.testing.expect(!mirror.namesTurn(7));
    try std.testing.expect(mirror.namesTurn(1));
    try mirror.sync(chat, &blocks.live(0, .{ .streaming = .model, .tool = null, .call_count = 0 }));
    try std.testing.expectEqualStrings("ℹ Writing", recorder.lastEdit().text);
    try std.testing.expectEqualStrings(activityKeyboard("1"), recorder.lastEdit().markup.?);
    try std.testing.expectEqual(@as(usize, 1), recorder.edits.items.len);

    try mirror.endTurn(
        chat,
        &blocks.idle(),
        &.{ .outcome = .canceled, .status = &test_status, .now_ms = 0 },
    );
    try mirror.beginTurn(chat, 0);
    try std.testing.expectEqualStrings(activityKeyboard("2"), recorder.lastSend().markup.?);
    try std.testing.expect(!mirror.namesTurn(1));
    try std.testing.expect(mirror.namesTurn(2));
}

test "a seed moves the serials past the keyboards of an earlier process" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    mirror.seedSerials(1_000);
    try mirror.beginTurn(chat, 0);
    try std.testing.expectEqualStrings(activityKeyboard("1001"), recorder.lastSend().markup.?);
    try std.testing.expect(!mirror.namesTurn(1));
    try std.testing.expect(mirror.namesTurn(1_001));
    try mirror.endTurn(
        chat,
        &blocks.idle(),
        &.{ .outcome = .canceled, .status = &test_status, .now_ms = 0 },
    );

    mirror.seedSerials(std.math.maxInt(u64));
    try mirror.beginTurn(chat, 0);
    try std.testing.expectEqualStrings(activityKeyboard("0"), recorder.lastSend().markup.?);
    try std.testing.expect(mirror.namesTurn(0));
}

test "a detach forgets the messages of the chat and keeps the turn" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);
    try mirror.beginTurn(chat, 0);
    const sends = recorder.sends.items.len;
    const edits = recorder.edits.items.len;

    mirror.forgetActivity();
    try std.testing.expectEqual(edits, recorder.edits.items.len);
    try std.testing.expect(mirror.namesTurn(1));
    try mirror.open(chat, &.{ .blocks = &.{}, .committed = 0, .tail = null });
    try std.testing.expectEqual(sends + 1, recorder.sends.items.len);
    try std.testing.expectEqualStrings(activityKeyboard("1"), recorder.lastSend().markup.?);
    try std.testing.expectEqual(edits, recorder.edits.items.len);
}

test "a canceled turn ends in silence, and a failed turn notifies its summary" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(chat, 0);
    try blocks.append(&.{ .event = .{ .text = "You canceled the turn." } });
    try mirror.endTurn(
        chat,
        &blocks.idle(),
        &.{ .outcome = .canceled, .status = &test_status, .now_ms = 500 },
    );
    try std.testing.expect(recorder.lastSend().options.disable_notification);
    try std.testing.expectEqualStrings(
        "ℹ Canceled · Tools: 0 calls · Time: 500ms · Context: 45% · Cost: ~$0.42",
        recorder.lastEdit().text,
    );
    try std.testing.expectEqual(@as(usize, 0), recorder.deletions.items.len);

    try mirror.beginTurn(chat, 1_000);
    try blocks.append(&.{ .event = .{
        .text = "The provider refused the request.",
        .severity = .failure,
    } });
    const activity = recorder.lastSend().handle.?;
    try mirror.endTurn(
        chat,
        &blocks.idle(),
        &.{ .outcome = .failed, .status = &test_status, .now_ms = 3_000 },
    );
    const failure = &recorder.sends.items[recorder.sends.items.len - 2];
    try std.testing.expectEqualStrings("⚠ The provider refused the request.", failure.text);
    try std.testing.expect(failure.options.disable_notification);
    try std.testing.expect(std.mem.startsWith(
        u8,
        recorder.lastSend().text,
        "⚠ Failed · Tools: 0 calls · Time: 2.0s",
    ));
    try std.testing.expect(!recorder.lastSend().options.disable_notification);
    try std.testing.expectEqual(@as(usize, 1), recorder.deletions.items.len);
    try std.testing.expectEqual(activity, recorder.deletions.items[0]);
}

test "a completed turn notifies on its summary when the last answer already went out" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(chat, 0);
    try blocks.append(&.{ .model = "answer" });
    try mirror.sync(chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .call_count = 1 }));
    try std.testing.expectEqualStrings("answer", recorder.lastSend().text);
    try std.testing.expect(recorder.lastSend().options.disable_notification);
    const activity = recorder.sends.items[0].handle.?;

    try mirror.endTurn(chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), recorder.sends.items.len);
    try std.testing.expect(!recorder.lastSend().options.disable_notification);
    try std.testing.expect(std.mem.startsWith(u8, recorder.lastSend().text, "ℹ Tools: 1 call"));
    try std.testing.expectEqual(@as(usize, 1), recorder.deletions.items.len);
    try std.testing.expectEqual(activity, recorder.deletions.items[0]);
}

test "a completed turn keeps the activity message when the summary cannot queue" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(chat, 0);
    const activity = recorder.sends.items[0].handle.?;
    recorder.drop_tracked = true;
    try mirror.endTurn(chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), recorder.sends.items.len);
    try std.testing.expectEqual(@as(usize, 0), recorder.deletions.items.len);
    try std.testing.expectEqual(activity, recorder.sends.items[0].handle.?);
}

test "an open starts at the committed frontier and gives a running turn its activity message" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(&.{ .model = "before the attach" });
    try blocks.append(&.{ .event = .{ .text = "You attached @drinky_bot.", .mirrored = false } });
    var mirror = Mirror.init(gpa);

    try mirror.open(chat, &blocks.idle());
    try mirror.sync(chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 0), recorder.sends.items.len);

    try mirror.beginTurn(chat, 0);
    try std.testing.expectEqual(@as(usize, 1), recorder.sends.items.len);
    try mirror.open(chat, &blocks.live(2, .{ .streaming = null, .tool = "read", .call_count = 3 }));
    try std.testing.expectEqualStrings(
        "ℹ Running: read · Tools: 3 calls",
        recorder.lastSend().text,
    );
    try std.testing.expectEqual(@as(?Attachment.Handle, 2), recorder.lastSend().handle);
}

test "the cursor follows a cleared transcript" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(&.{ .thinking = "weigh it" });
    try blocks.append(&.{ .model = "answer" });
    var mirror = Mirror.init(gpa);
    try mirror.sync(chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 1), recorder.sends.items.len);

    try blocks.append(&.{ .event = .{ .text = "Drinky replaced the credential." } });
    try mirror.sync(chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 2), recorder.sends.items.len);
    try std.testing.expectEqualStrings(
        "ℹ Drinky replaced the credential.",
        recorder.lastSend().text,
    );

    blocks.truncate(0);
    try blocks.append(&.{ .intro = "legend" });
    try blocks.append(&.{ .event = .{ .text = "fresh" } });
    mirror.resetCursor();
    try mirror.sync(chat, &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), recorder.sends.items.len);
    try std.testing.expectEqualStrings("ℹ fresh", recorder.lastSend().text);
}

fn reportDrop(context: *anyopaque) Chat.Error!void {
    const blocks: *Blocks = @ptrCast(@alignCast(context));
    try blocks.append(&.{ .event = .{ .text = "Drinky dropped a message.", .mirrored = false } });
}

test "a send that reports into the transcript cannot move the blocks under the flush" {
    const gpa = std.testing.allocator;
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    try blocks.append(&.{ .model = "one" });
    try blocks.append(&.{ .model = "two" });
    try blocks.append(&.{ .model = "three" });
    blocks.compact();
    var recorder: Recorder = .{
        .gpa = gpa,
        .drop_tracked = true,
        .send_hook = .{ .context = &blocks, .run = reportDrop },
    };
    defer recorder.deinit();
    var mirror = Mirror.init(gpa);

    const view = blocks.idle();
    try mirror.sync(recorder.chat(), &view);
    try std.testing.expectEqual(@as(usize, 3), recorder.sends.items.len);
    try std.testing.expectEqual(@as(usize, 6), blocks.items.items.len);
    try mirror.sync(recorder.chat(), &blocks.idle());
    try std.testing.expectEqual(@as(usize, 3), recorder.sends.items.len);
}

test "an answer waits for a tool run, an event, or the turn end before it goes out" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    var mirror = Mirror.init(gpa);

    try mirror.beginTurn(chat, 0);
    try blocks.append(&.{ .model = "first" });
    try mirror.sync(chat, &blocks.live(1, .{ .streaming = .model, .tool = null, .call_count = 0 }));
    try std.testing.expectEqual(@as(usize, 1), recorder.sends.items.len);

    try mirror.sync(chat, &blocks.live(1, .{ .streaming = null, .tool = "bash", .call_count = 1 }));
    try std.testing.expectEqual(@as(usize, 2), recorder.sends.items.len);
    try std.testing.expectEqualStrings("first", recorder.sends.items[1].text);
    try std.testing.expect(recorder.sends.items[1].markup == null);

    try blocks.append(&.{ .model = "second" });
    try mirror.sync(chat, &blocks.live(2, .{ .streaming = .model, .tool = null, .call_count = 1 }));
    try std.testing.expectEqual(@as(usize, 2), recorder.sends.items.len);
    try blocks.append(&.{ .event = .{ .text = "Drinky changed the model." } });
    try mirror.sync(chat, &blocks.live(3, .{ .streaming = null, .tool = null, .call_count = 1 }));
    try std.testing.expectEqual(@as(usize, 4), recorder.sends.items.len);
    try std.testing.expectEqualStrings("second", recorder.sends.items[2].text);
    try std.testing.expectEqualStrings("ℹ Drinky changed the model.", recorder.sends.items[3].text);

    try blocks.append(&.{ .model = "last" });
    try mirror.endTurn(chat, &blocks.idle(), &.{
        .outcome = .completed,
        .status = &test_status,
        .now_ms = 0,
    });
    try std.testing.expectEqual(@as(usize, 6), recorder.sends.items.len);
    try std.testing.expectEqualStrings("last", recorder.sends.items[4].text);
    try std.testing.expect(recorder.sends.items[4].markup == null);
    try std.testing.expect(recorder.lastSend().markup == null);
    try std.testing.expect(!recorder.lastSend().options.disable_notification);
}

test "a long answer splits into several messages" {
    const gpa = std.testing.allocator;
    var recorder: Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const chat = recorder.chat();
    var blocks: Blocks = .{ .gpa = gpa };
    defer blocks.deinit();
    const line = "x" ** 100 ++ "\n";
    try blocks.append(&.{ .model = line ** 50 });
    var mirror = Mirror.init(gpa);
    try mirror.beginTurn(chat, 0);

    try mirror.endTurn(
        chat,
        &blocks.idle(),
        &.{ .outcome = .completed, .status = &test_status, .now_ms = 0 },
    );
    try std.testing.expectEqual(@as(usize, 4), recorder.sends.items.len);
    try std.testing.expect(recorder.sends.items[1].text.len <= html.message_units_max);
    try std.testing.expect(recorder.sends.items[1].options.disable_notification);
    try std.testing.expect(recorder.sends.items[2].options.disable_notification);
    try std.testing.expect(!recorder.lastSend().options.disable_notification);
    try std.testing.expect(recorder.sends.items[1].markup == null);
    try std.testing.expect(recorder.sends.items[2].markup == null);
    try std.testing.expect(recorder.lastSend().markup == null);
}
