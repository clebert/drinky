const std = @import("std");

const cancel_label = "Cancel turn";
const cancel_prefix = "cancel:";

pub fn cancelMarkup(gpa: std.mem.Allocator, serial: u64) ![]u8 {
    var buffer: [cancel_prefix.len + 20]u8 = undefined;
    const data = std.fmt.bufPrint(&buffer, cancel_prefix ++ "{d}", .{serial}) catch unreachable;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("inline_keyboard");
    try json.beginArray();
    try json.beginArray();
    try json.write(.{ .text = cancel_label, .callback_data = data });
    try json.endArray();
    try json.endArray();
    try json.endObject();
    return out.toOwnedSlice();
}

pub fn parseCancel(data: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, data, cancel_prefix)) return null;
    return std.fmt.parseInt(u64, data[cancel_prefix.len..], 10) catch null;
}

test "the cancel keyboard names the serial of its turn, and the tap data reads back" {
    const gpa = std.testing.allocator;
    const json = try cancelMarkup(gpa, 3);
    defer gpa.free(json);
    try std.testing.expectEqualStrings(
        "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:3\"}]]}",
        json,
    );
    try std.testing.expectEqual(@as(?u64, 3), parseCancel("cancel:3"));
    const largest = try cancelMarkup(gpa, std.math.maxInt(u64));
    defer gpa.free(largest);
    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        parseCancel("cancel:18446744073709551615"),
    );
}

test "data that no keyboard wrote parses to nothing" {
    try std.testing.expect(parseCancel("") == null);
    try std.testing.expect(parseCancel("cancel") == null);
    try std.testing.expect(parseCancel("cancel:") == null);
    try std.testing.expect(parseCancel("cancel:x") == null);
    try std.testing.expect(parseCancel("cancel:3:4") == null);
    try std.testing.expect(parseCancel("cancel:-3") == null);
    try std.testing.expect(parseCancel("shorten:3") == null);
    try std.testing.expect(parseCancel("row:3:4") == null);
    try std.testing.expect(parseCancel("close:3") == null);
}
