const std = @import("std");

const ai = @import("ai");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const html = @import("html.zig");
const keyboard = @import("keyboard.zig");

const Picker = @This();

const rows_max = 98;

const trail_max = 8;

const back_label = "‹ Back";
const cancel_label = "Cancel";
const current_mark = "✓ ";

gpa: std.mem.Allocator,
serial: u64,
open: ?Open,

const Open = struct {
    handle: ?Attachment.Handle,
    serial: u64,
    select: *const fn (
        *ai.command.Context,
        ai.command.Outcome.Pick.Selection,
    ) anyerror!ai.command.Outcome,
    payload: usize,
    options: []const ai.command.Outcome.Pick.Option,
    title: []const u8,
    cancellation_message: []const u8,
    reopen: ?ai.command.Outcome.Opener,
    trail: [trail_max]ai.command.Outcome.Opener,
    trail_len: usize,

    fn deinit(self: *const Open, gpa: std.mem.Allocator) void {
        for (self.options) |*option| option.deinit(gpa);
        gpa.free(self.options);
    }
};

pub const Action = union(enum) {
    row: usize,
    back: ai.command.Outcome.Opener,
    close,
};

pub fn init(gpa: std.mem.Allocator) Picker {
    return .{ .gpa = gpa, .serial = 0, .open = null };
}

pub fn seedSerials(self: *Picker, seed: u64) void {
    self.serial = seed;
}

pub fn deinit(self: *Picker) void {
    self.close();
}

pub fn isOpen(self: *const Picker) bool {
    return self.open != null;
}

pub fn cancellationMessage(self: *const Picker) []const u8 {
    return self.open.?.cancellation_message;
}

pub fn show(self: *Picker, chat: anytype, pick: *const ai.command.Outcome.Pick) !void {
    self.close();
    var open = self.take(pick, &.{});
    errdefer open.deinit(self.gpa);
    const markup = try self.buildMarkup(&open, pick.current);
    defer self.gpa.free(markup);
    const title = try html.wrapAlloc(self.gpa, .information, open.title);
    defer self.gpa.free(title);
    open.handle = try chat.sendTracked(title, &.{
        .disable_notification = true,
        .parse_mode = html.parse_mode,
        .markup = markup,
    });
    self.open = open;
}

pub fn step(self: *Picker, chat: anytype, pick: *const ai.command.Outcome.Pick) !void {
    const above = self.open orelse return self.show(chat, pick);
    var trail = above.trail[0..above.trail_len];
    var buffer: [trail_max]ai.command.Outcome.Opener = undefined;
    if (!sameStep(above.reopen, pick.reopen)) {
        if (above.reopen) |opener| {
            const kept = if (trail.len == trail_max) trail[1..] else trail;
            @memcpy(buffer[0..kept.len], kept);
            buffer[kept.len] = opener;
            trail = buffer[0 .. kept.len + 1];
        } else {
            trail = &.{};
        }
    }
    try self.replace(chat, pick, trail);
}

pub fn replace(
    self: *Picker,
    chat: anytype,
    pick: *const ai.command.Outcome.Pick,
    trail: []const ai.command.Outcome.Opener,
) !void {
    const above = self.open orelse return self.show(chat, pick);
    var open = self.take(pick, trail);
    open.handle = above.handle;
    errdefer open.deinit(self.gpa);
    const markup = try self.buildMarkup(&open, pick.current);
    defer self.gpa.free(markup);
    const title = try html.wrapAlloc(self.gpa, .information, open.title);
    defer self.gpa.free(title);
    if (open.handle) |handle| try chat.edit(handle, title, &.{
        .parse_mode = html.parse_mode,
        .markup = markup,
    });
    above.deinit(self.gpa);
    self.open = open;
}

fn sameStep(step_open: ?ai.command.Outcome.Opener, other: ?ai.command.Outcome.Opener) bool {
    const one = step_open orelse return false;
    const two = other orelse return false;
    return one == two;
}

fn take(
    self: *Picker,
    pick: *const ai.command.Outcome.Pick,
    trail: []const ai.command.Outcome.Opener,
) Open {
    self.serial +%= 1;
    var open: Open = .{
        .handle = null,
        .serial = self.serial,
        .select = pick.select,
        .payload = pick.payload,
        .options = pick.options,
        .title = pick.title,
        .cancellation_message = pick.cancellation_message,
        .reopen = pick.reopen,
        .trail = undefined,
        .trail_len = trail.len,
    };
    @memcpy(open.trail[0..trail.len], trail);
    return open;
}

pub fn resolve(self: *Picker, tap: keyboard.Tap) ?Action {
    const open = if (self.open) |*open| open else return null;
    switch (tap) {
        .row => |row| {
            if (row.serial != open.serial or row.index >= open.options.len) return null;
            return .{ .row = row.index };
        },
        .back => |serial| {
            if (serial != open.serial or open.trail_len == 0) return null;
            open.trail_len -= 1;
            return .{ .back = open.trail[open.trail_len] };
        },
        .close => |serial| {
            if (serial != open.serial) return null;
            return .close;
        },
        .cancel_turn, .withdraw, .retry, .dismiss, .shorten => return null,
    }
}

pub fn select(
    self: *const Picker,
    context: *ai.command.Context,
    index: usize,
) anyerror!ai.command.Outcome {
    return self.open.?.select(context, .{ .payload = self.open.?.payload, .row = index });
}

pub fn openers(self: *const Picker) []const ai.command.Outcome.Opener {
    const open = if (self.open) |*open| open else return &.{};
    return open.trail[0..open.trail_len];
}

pub fn dismiss(self: *Picker, chat: anytype) !void {
    const open = self.open orelse return;
    defer self.close();
    const handle = open.handle orelse return;
    try chat.delete(handle);
}

pub fn close(self: *Picker) void {
    const open = self.open orelse return;
    open.deinit(self.gpa);
    self.open = null;
}

fn buildMarkup(self: *Picker, open: *const Open, current: ?usize) ![]u8 {
    var buttons: std.ArrayList(keyboard.Button) = .empty;
    defer {
        for (buttons.items) |button| {
            self.gpa.free(button.text);
            self.gpa.free(button.data);
        }
        buttons.deinit(self.gpa);
    }
    const shown = @min(open.options.len, rows_max);
    try buttons.ensureTotalCapacity(self.gpa, shown + 2);
    for (open.options[0..shown], 0..) |*option, index| {
        const text = try rowLabel(self.gpa, option, current == index);
        errdefer self.gpa.free(text);
        const data = try dataOf(self.gpa, .{ .row = .{ .serial = open.serial, .index = index } });
        buttons.appendAssumeCapacity(.{ .text = text, .data = data });
    }
    if (open.trail_len > 0) {
        const text = try self.gpa.dupe(u8, back_label);
        errdefer self.gpa.free(text);
        const data = try dataOf(self.gpa, .{ .back = open.serial });
        buttons.appendAssumeCapacity(.{ .text = text, .data = data });
    }
    {
        const text = try self.gpa.dupe(u8, cancel_label);
        errdefer self.gpa.free(text);
        const data = try dataOf(self.gpa, .{ .close = open.serial });
        buttons.appendAssumeCapacity(.{ .text = text, .data = data });
    }
    return keyboard.markup(self.gpa, buttons.items);
}

fn rowLabel(
    gpa: std.mem.Allocator,
    option: *const ai.command.Outcome.Pick.Option,
    current: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    if (current) try out.writer.writeAll(current_mark);
    try out.writer.writeAll(option.name);
    if (option.extra) |extra| {
        try out.writer.writeAll(" \u{00B7} ");
        try out.writer.writeAll(extra);
    }
    if (option.tag) |tag| try out.writer.print(" ({s})", .{tag});
    return out.toOwnedSlice();
}

fn dataOf(gpa: std.mem.Allocator, tap: keyboard.Tap) ![]u8 {
    var buffer: [keyboard.data_bytes_max]u8 = undefined;
    return gpa.dupe(u8, tap.write(&buffer));
}

const Recorder = struct {
    gpa: std.mem.Allocator,
    sends: std.ArrayList(Message) = .empty,
    edits: std.ArrayList(Message) = .empty,
    deletions: std.ArrayList(Attachment.Handle) = .empty,
    handle_next: Attachment.Handle = 1,

    const Message = struct {
        handle: ?Attachment.Handle,
        text: []u8,
        parse_mode: ?[]const u8,
        markup: ?[]u8,

        fn deinit(self: *const Message, gpa: std.mem.Allocator) void {
            gpa.free(self.text);
            if (self.markup) |markup| gpa.free(markup);
        }
    };

    fn deinit(self: *Recorder) void {
        for (self.sends.items) |message| message.deinit(self.gpa);
        self.sends.deinit(self.gpa);
        for (self.edits.items) |message| message.deinit(self.gpa);
        self.edits.deinit(self.gpa);
        self.deletions.deinit(self.gpa);
    }

    fn sendTracked(
        self: *Recorder,
        text: []const u8,
        options: *const Client.SendOptions,
    ) !?Attachment.Handle {
        const handle = self.handle_next;
        self.handle_next += 1;
        const message = try self.record(handle, text, options.parse_mode, options.markup);
        try self.sends.append(self.gpa, message);
        return handle;
    }

    fn edit(
        self: *Recorder,
        handle: Attachment.Handle,
        text: []const u8,
        options: *const Client.EditOptions,
    ) !void {
        const message = try self.record(handle, text, options.parse_mode, options.markup);
        try self.edits.append(self.gpa, message);
    }

    fn delete(self: *Recorder, handle: Attachment.Handle) !void {
        try self.deletions.append(self.gpa, handle);
    }

    fn record(
        self: *Recorder,
        handle: ?Attachment.Handle,
        text: []const u8,
        parse_mode: ?[]const u8,
        markup: ?[]const u8,
    ) !Message {
        const text_copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(text_copy);
        const markup_copy: ?[]u8 = if (markup) |json| try self.gpa.dupe(u8, json) else null;
        return .{
            .handle = handle,
            .text = text_copy,
            .parse_mode = parse_mode,
            .markup = markup_copy,
        };
    }

    fn lastEdit(self: *const Recorder) *const Message {
        return &self.edits.items[self.edits.items.len - 1];
    }
};

fn testPick(
    gpa: std.mem.Allocator,
    rows: []const []const u8,
    current: ?usize,
    reopen: ?ai.command.Outcome.Opener,
) !ai.command.Outcome.Pick {
    var options: ai.command.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    for (rows) |row| try options.print("{s}", .{row});
    return .{
        .select = selectNothing,
        .title = "Effort",
        .cancellation_message = "You canceled the effort selection.",
        .options = try options.toOwnedSlice(),
        .current = current,
        .reopen = reopen,
    };
}

fn selectNothing(
    context: *ai.command.Context,
    selection: ai.command.Outcome.Pick.Selection,
) anyerror!ai.command.Outcome {
    _ = selection;
    return ai.command.Outcome.reportNotice(context.gpa, .failure, "Select a valid row.", .{});
}

fn reportSelection(
    context: *ai.command.Context,
    selection: ai.command.Outcome.Pick.Selection,
) anyerror!ai.command.Outcome {
    return ai.command.Outcome.reportNotice(
        context.gpa,
        .information,
        "payload {d} row {d}",
        .{ selection.payload, selection.row },
    );
}

fn openFirst(context: *ai.command.Context) anyerror!ai.command.Outcome {
    return ai.command.Outcome.reportNotice(context.gpa, .information, "first", .{});
}

fn openSecond(context: *ai.command.Context) anyerror!ai.command.Outcome {
    return ai.command.Outcome.reportNotice(context.gpa, .information, "second", .{});
}

test "a picker shows its rows as buttons with the current mark and a cancel, and a pick states the result" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    try picker.show(&chat, &(try testPick(gpa, &.{ "low", "high" }, 1, null)));
    try std.testing.expect(picker.isOpen());
    try std.testing.expectEqualStrings("ℹ Effort", chat.sends.items[0].text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.sends.items[0].parse_mode.?);
    try std.testing.expectEqualStrings(
        "{\"inline_keyboard\":[[{\"text\":\"low\",\"callback_data\":\"row:1:0\"}]," ++
            "[{\"text\":\"✓ high\",\"callback_data\":\"row:1:1\"}]," ++
            "[{\"text\":\"Cancel\",\"callback_data\":\"close:1\"}]]}",
        chat.sends.items[0].markup.?,
    );
    try std.testing.expectEqual(@as(usize, 0), picker.resolve(.{ .row = .{ .serial = 1, .index = 0 } }).?.row);
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1, .index = 2 } }) == null);
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 2, .index = 0 } }) == null);
    try std.testing.expect(picker.resolve(.{ .back = 1 }) == null);
    try std.testing.expect(picker.resolve(.{ .cancel_turn = 1 }) == null);
    try std.testing.expect(picker.resolve(.{ .close = 1 }).? == .close);
    try std.testing.expectEqualStrings("You canceled the effort selection.", picker.cancellationMessage());

    try picker.dismiss(&chat);
    try std.testing.expect(!picker.isOpen());
    try std.testing.expectEqual(@as(usize, 0), chat.edits.items.len);
    try std.testing.expectEqualSlices(Attachment.Handle, &.{1}, chat.deletions.items);
    try std.testing.expect(picker.resolve(.{ .close = 1 }) == null);
}

test "a tapped row carries the payload of its step to the selector" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    var pick = try testPick(gpa, &.{ "openai/gpt-new", "openai/gpt-old" }, null, null);
    pick.select = reportSelection;
    pick.payload = 4242;
    try picker.show(&chat, &pick);

    var context: ai.command.Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    const action = picker.resolve(.{ .row = .{ .serial = 1, .index = 1 } }).?;
    try ai.command.Outcome.expectNoticeContaining(
        try picker.select(&context, action.row),
        .information,
        "payload 4242 row 1",
    );
}

test "a step edits the same message, adds the back button, and a back takes the step off the trail" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    try picker.show(&chat, &(try testPick(gpa, &.{"Anthropic"}, null, openFirst)));
    try picker.step(&chat, &(try testPick(gpa, &.{ "Subscription", "API" }, null, openSecond)));
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);
    try std.testing.expectEqual(@as(?Attachment.Handle, 1), chat.lastEdit().handle);
    try std.testing.expectEqualStrings("ℹ Effort", chat.lastEdit().text);
    try std.testing.expectEqualStrings(html.parse_mode, chat.lastEdit().parse_mode.?);
    try std.testing.expectEqualStrings(
        "{\"inline_keyboard\":[[{\"text\":\"Subscription\",\"callback_data\":\"row:2:0\"}]," ++
            "[{\"text\":\"API\",\"callback_data\":\"row:2:1\"}]," ++
            "[{\"text\":\"‹ Back\",\"callback_data\":\"back:2\"}]," ++
            "[{\"text\":\"Cancel\",\"callback_data\":\"close:2\"}]]}",
        chat.lastEdit().markup.?,
    );
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1, .index = 0 } }) == null);
    try picker.step(&chat, &(try testPick(gpa, &.{"Subscription"}, null, openSecond)));
    try std.testing.expectEqual(@as(usize, 1), picker.openers().len);

    const action = picker.resolve(.{ .back = 3 }).?;
    try std.testing.expect(action.back == &openFirst);
    try std.testing.expectEqual(@as(usize, 0), picker.openers().len);
    try picker.replace(&chat, &(try testPick(gpa, &.{"Anthropic"}, 0, openFirst)), picker.openers());
    try std.testing.expect(std.mem.indexOf(u8, chat.lastEdit().markup.?, "‹ Back") == null);
    try std.testing.expect(std.mem.indexOf(u8, chat.lastEdit().markup.?, "\"text\":\"✓ Anthropic\",\"callback_data\":\"row:4:0\"") != null);
    try std.testing.expect(picker.resolve(.{ .back = 4 }) == null);
}

test "a newer picker makes the older one stale, and a close forgets the picker without a deletion" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    try picker.show(&chat, &(try testPick(gpa, &.{"low"}, null, null)));
    try picker.show(&chat, &(try testPick(gpa, &.{"high"}, null, null)));
    try std.testing.expectEqual(@as(usize, 2), chat.sends.items.len);
    try std.testing.expectEqual(@as(usize, 0), chat.edits.items.len);
    try std.testing.expect(picker.resolve(.{ .close = 1 }) == null);
    try std.testing.expect(picker.resolve(.{ .close = 2 }) != null);

    picker.close();
    try std.testing.expect(!picker.isOpen());
    try std.testing.expect(picker.resolve(.{ .close = 2 }) == null);
    try picker.dismiss(&chat);
    try std.testing.expectEqual(@as(usize, 0), chat.deletions.items.len);
}

test "a seed moves the serials past the keyboards of an earlier process" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    picker.seedSerials(1_000);
    try picker.show(&chat, &(try testPick(gpa, &.{"low"}, null, null)));
    try std.testing.expect(std.mem.indexOf(u8, chat.sends.items[0].markup.?, "\"callback_data\":\"row:1001:0\"") != null);
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1, .index = 0 } }) == null);
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1_001, .index = 0 } }) != null);

    picker.seedSerials(std.math.maxInt(u64));
    try picker.show(&chat, &(try testPick(gpa, &.{"low"}, null, null)));
    try std.testing.expect(std.mem.indexOf(u8, chat.sends.items[1].markup.?, "\"callback_data\":\"row:0:0\"") != null);
    try std.testing.expect(picker.resolve(.{ .close = 0 }) != null);
}

test "a long list shows the first rows alone, so the keyboard stays inside the bound" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();
    var rows: [rows_max + 5][]const u8 = undefined;
    for (&rows) |*row| row.* = "model";

    try picker.show(&chat, &(try testPick(gpa, &rows, null, null)));
    try std.testing.expectEqual(
        @as(usize, rows_max + 1),
        std.mem.count(u8, chat.sends.items[0].markup.?, "callback_data"),
    );
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1, .index = rows_max + 4 } }) != null);
}
