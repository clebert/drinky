const std = @import("std");

const testing = @import("testing.zig");

pub fn payload(
    gpa: std.mem.Allocator,
    token: []const u8,
) error{OutOfMemory}!?std.json.Parsed(std.json.Value) {
    var segments = std.mem.splitScalar(u8, token, '.');
    _ = segments.next() orelse return null;
    const encoded = segments.next() orelse return null;
    if (segments.next() == null) return null;

    const length = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch
        return null;
    const buffer = try gpa.alloc(u8, length);
    defer gpa.free(buffer);
    std.base64.url_safe_no_pad.Decoder.decode(buffer, encoded) catch return null;
    return std.json.parseFromSlice(std.json.Value, gpa, buffer, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

test payload {
    const gpa = std.testing.allocator;
    const token = try testing.fakeJwt(gpa, "{\"sub\":\"user-1\",\"exp\":2000000000}");
    defer gpa.free(token);
    const parsed = (try payload(gpa, token)).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("user-1", parsed.value.object.get("sub").?.string);
    try std.testing.expectEqual(@as(i64, 2000000000), parsed.value.object.get("exp").?.integer);

    try std.testing.expect(try payload(gpa, "e30.e30") == null);
    try std.testing.expect(try payload(gpa, "e30.!!!.sig") == null);
    const not_json = try testing.fakeJwt(gpa, "not json");
    defer gpa.free(not_json);
    try std.testing.expect(try payload(gpa, not_json) == null);
}
