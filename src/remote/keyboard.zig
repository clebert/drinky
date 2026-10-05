const std = @import("std");

const callback_data_bytes_max = 64;

pub const Tap = union(enum) {
    cancel: u64,

    pub fn parse(data: []const u8) ?Tap {
        const colon = std.mem.indexOfScalar(u8, data, ':') orelse return null;
        const tag = std.meta.stringToEnum(std.meta.Tag(Tap), data[0..colon]) orelse return null;
        const argument = data[colon + 1 ..];
        return switch (tag) {
            .cancel => .{ .cancel = std.fmt.parseInt(u64, argument, 10) catch return null },
        };
    }

    fn label(self: Tap) []const u8 {
        return switch (self) {
            .cancel => "Cancel turn",
        };
    }

    fn callbackData(self: Tap, buffer: *[callback_data_bytes_max]u8) []const u8 {
        return switch (self) {
            .cancel => |serial| std.fmt.bufPrint(
                buffer,
                "{s}:{d}",
                .{ @tagName(self), serial },
            ) catch unreachable,
        };
    }
};

pub fn markup(gpa: std.mem.Allocator, rows: []const []const Tap) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    write(&out.writer, rows) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(writer: *std.Io.Writer, rows: []const []const Tap) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginObject();
    try json.objectField("inline_keyboard");
    try json.beginArray();
    for (rows) |row| {
        try json.beginArray();
        for (row) |tap| {
            var buffer: [callback_data_bytes_max]u8 = undefined;
            try json.write(.{ .text = tap.label(), .callback_data = tap.callbackData(&buffer) });
        }
        try json.endArray();
    }
    try json.endArray();
    try json.endObject();
}

test "a markup holds each row of taps, and the data of each tap parses back" {
    const gpa = std.testing.allocator;
    const largest: Tap = .{ .cancel = std.math.maxInt(u64) };
    const first_row = [_]Tap{ .{ .cancel = 3 }, largest };
    const second_row = [_]Tap{.{ .cancel = 4 }};
    const json = try markup(gpa, &.{ &first_row, &second_row });
    defer gpa.free(json);
    try std.testing.expectEqualStrings(
        "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:3\"}," ++
            "{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:18446744073709551615\"}]," ++
            "[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:4\"}]]}",
        json,
    );
    const Button = struct { text: []const u8, callback_data: []const u8 };
    const parsed = try std.json.parseFromSlice(
        struct { inline_keyboard: []const []const Button },
        gpa,
        json,
        .{},
    );
    defer parsed.deinit();
    const rows = [_][]const Tap{ &first_row, &second_row };
    try std.testing.expectEqual(rows.len, parsed.value.inline_keyboard.len);
    for (rows, parsed.value.inline_keyboard) |taps, buttons| {
        try std.testing.expectEqual(taps.len, buttons.len);
        for (taps, buttons) |tap, button|
            try std.testing.expectEqual(tap, Tap.parse(button.callback_data).?);
    }
}

test "data that no keyboard wrote parses to nothing" {
    try std.testing.expect(Tap.parse("") == null);
    try std.testing.expect(Tap.parse("cancel") == null);
    try std.testing.expect(Tap.parse("cancel:") == null);
    try std.testing.expect(Tap.parse("cancel:x") == null);
    try std.testing.expect(Tap.parse("cancel:3:4") == null);
    try std.testing.expect(Tap.parse("cancel:-3") == null);
    try std.testing.expect(Tap.parse(":3") == null);
    try std.testing.expect(Tap.parse("shorten:3") == null);
    try std.testing.expect(Tap.parse("row:3:4") == null);
    try std.testing.expect(Tap.parse("close:3") == null);
}
