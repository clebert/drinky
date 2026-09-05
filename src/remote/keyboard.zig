//! The inline keyboards of the chat and the taps on their buttons. A keyboard
//! is one button per row, and every button carries a `Tap` as its callback
//! data: an id alone, never text. The owner of a keyboard stamps it with a
//! serial, so a tap on a keyboard that the chat history still shows names a
//! serial the owner no longer holds, and the owner answers it as stale.

const std = @import("std");

/// The bytes Telegram allows in one `callback_data`.
pub const data_bytes_max = 64;

/// One button of a keyboard. The texts are borrowed for the build.
pub const Button = struct {
    text: []const u8,
    data: []const u8,
};

/// One tap, as the callback data of its button names it. The serial names the
/// keyboard, and the row names the button of a picker.
pub const Tap = union(enum) {
    /// The `Cancel turn` button of the activity message.
    cancel_turn: u64,
    /// The `Withdraw` button of the activity message.
    withdraw: u64,
    /// The `Try again` button of the failed turn message.
    retry: u64,
    /// The `Dismiss` button of the failed turn message.
    dismiss: u64,
    /// One row of a picker.
    row: Row,
    /// The `‹ Back` button of a stepped picker.
    back: u64,
    /// The `Cancel` button of a picker.
    close: u64,

    pub const Row = struct {
        serial: u64,
        index: usize,
    };

    /// The keyword of each tap in its callback data.
    const Word = enum { cancel, withdraw, retry, dismiss, row, back, close };

    /// The callback data of this tap, in `buffer`.
    pub fn write(self: Tap, buffer: *[data_bytes_max]u8) []const u8 {
        return switch (self) {
            .cancel_turn => |serial| std.fmt.bufPrint(buffer, "cancel:{d}", .{serial}),
            .withdraw => |serial| std.fmt.bufPrint(buffer, "withdraw:{d}", .{serial}),
            .retry => |serial| std.fmt.bufPrint(buffer, "retry:{d}", .{serial}),
            .dismiss => |serial| std.fmt.bufPrint(buffer, "dismiss:{d}", .{serial}),
            .row => |row| std.fmt.bufPrint(buffer, "row:{d}:{d}", .{ row.serial, row.index }),
            .back => |serial| std.fmt.bufPrint(buffer, "back:{d}", .{serial}),
            .close => |serial| std.fmt.bufPrint(buffer, "close:{d}", .{serial}),
        } catch unreachable;
    }

    /// The tap that `data` names, or null for data that no keyboard of Drinky
    /// wrote.
    pub fn parse(data: []const u8) ?Tap {
        var parts = std.mem.splitScalar(u8, data, ':');
        const word = std.meta.stringToEnum(Word, parts.first()) orelse return null;
        const serial = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
        const tap: Tap = switch (word) {
            .cancel => .{ .cancel_turn = serial },
            .withdraw => .{ .withdraw = serial },
            .retry => .{ .retry = serial },
            .dismiss => .{ .dismiss = serial },
            .row => .{ .row = .{
                .serial = serial,
                .index = std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch
                    return null,
            } },
            .back => .{ .back = serial },
            .close => .{ .close = serial },
        };
        if (parts.next() != null) return null;
        return tap;
    }
};

/// The `reply_markup` object of `buttons` as JSON, one button per row. The
/// result is owned.
pub fn markup(gpa: std.mem.Allocator, buttons: []const Button) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("inline_keyboard");
    try json.beginArray();
    for (buttons) |button| {
        try json.beginArray();
        try json.write(.{ .text = button.text, .callback_data = button.data });
        try json.endArray();
    }
    try json.endArray();
    try json.endObject();
    return out.toOwnedSlice();
}

test "a tap writes its data and reads it back" {
    const taps = [_]Tap{
        .{ .cancel_turn = 3 },
        .{ .withdraw = 3 },
        .{ .retry = 8 },
        .{ .dismiss = 8 },
        .{ .row = .{ .serial = 12, .index = 4 } },
        .{ .back = 12 },
        .{ .close = 12 },
        .{ .row = .{ .serial = std.math.maxInt(u64), .index = std.math.maxInt(usize) } },
    };
    for (taps) |tap| {
        var buffer: [data_bytes_max]u8 = undefined;
        const data = tap.write(&buffer);
        try std.testing.expect(data.len <= data_bytes_max);
        try std.testing.expectEqualDeep(tap, Tap.parse(data).?);
    }
    var buffer: [data_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("row:12:4", (Tap{ .row = .{ .serial = 12, .index = 4 } }).write(&buffer));
    try std.testing.expectEqualStrings("cancel:3", (Tap{ .cancel_turn = 3 }).write(&buffer));
}

test "data that no keyboard wrote parses to nothing" {
    try std.testing.expect(Tap.parse("") == null);
    try std.testing.expect(Tap.parse("cancel") == null);
    try std.testing.expect(Tap.parse("cancel:") == null);
    try std.testing.expect(Tap.parse("cancel:x") == null);
    try std.testing.expect(Tap.parse("cancel:3:4") == null);
    try std.testing.expect(Tap.parse("row:3") == null);
    try std.testing.expect(Tap.parse("row:3:4:5") == null);
    try std.testing.expect(Tap.parse("quit:3") == null);
    try std.testing.expect(Tap.parse("cancel:-3") == null);
}

test "a markup holds one button per row" {
    const gpa = std.testing.allocator;
    const json = try markup(gpa, &.{
        .{ .text = "Cancel turn", .data = "cancel:3" },
        .{ .text = "Withdraw", .data = "withdraw:3" },
    });
    defer gpa.free(json);
    try std.testing.expectEqualStrings(
        "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:3\"}]," ++
            "[{\"text\":\"Withdraw\",\"callback_data\":\"withdraw:3\"}]]}",
        json,
    );
    const empty = try markup(gpa, &.{});
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("{\"inline_keyboard\":[]}", empty);
}
