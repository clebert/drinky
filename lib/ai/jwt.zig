const std = @import("std");

const base64url = std.base64.url_safe_no_pad.Decoder;

pub fn payload(
    gpa: std.mem.Allocator,
    token: []const u8,
) error{OutOfMemory}!?std.json.Parsed(std.json.Value) {
    var segments = std.mem.splitScalar(u8, token, '.');
    _ = segments.next() orelse return null;
    const encoded = segments.next() orelse return null;
    if (segments.next() == null) return null;

    const len = base64url.calcSizeForSlice(encoded) catch return null;
    const buffer = try gpa.alloc(u8, len);
    defer gpa.free(buffer);
    base64url.decode(buffer, encoded) catch return null;
    return std.json.parseFromSlice(std.json.Value, gpa, buffer, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

pub fn testToken(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var encoded: [1024]u8 = undefined;
    const middle = std.base64.url_safe_no_pad.Encoder.encode(&encoded, body);
    return std.fmt.allocPrint(gpa, "e30.{s}.sig", .{middle});
}

test payload {
    const gpa = std.testing.allocator;
    const token = try testToken(gpa, "{\"sub\":\"user-1\",\"exp\":2000000000}");
    defer gpa.free(token);
    const parsed = (try payload(gpa, token)).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("user-1", parsed.value.object.get("sub").?.string);
    try std.testing.expectEqual(@as(i64, 2000000000), parsed.value.object.get("exp").?.integer);

    try std.testing.expect(try payload(gpa, "e30.e30") == null);
    try std.testing.expect(try payload(gpa, "e30.!!!.sig") == null);
    const not_json = try testToken(gpa, "not json");
    defer gpa.free(not_json);
    try std.testing.expect(try payload(gpa, not_json) == null);
}
