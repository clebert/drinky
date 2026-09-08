//! The payload of a JSON Web Token, read without a signature check. Drinky reads
//! its own tokens alone, for a claim such as the expiry or the subject, and
//! makes no trust decision on one.

const std = @import("std");

const base64url = std.base64.url_safe_no_pad.Decoder;

/// Decode the payload of `token` (the middle of three dot-separated segments)
/// and parse it as JSON. Null, never an error, on fewer than three segments,
/// bad base64, or malformed JSON. The caller deinitializes a result.
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

/// The string claim `name` of `token` as an owned copy, or null when the token
/// is malformed or holds no such string. The caller frees a result.
pub fn stringClaim(
    gpa: std.mem.Allocator,
    token: []const u8,
    name: []const u8,
) error{OutOfMemory}!?[]const u8 {
    const parsed = (try payload(gpa, token)) orelse return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const claim = switch (object.get(name) orelse return null) {
        .string => |string| string,
        else => return null,
    };
    return try gpa.dupe(u8, claim);
}

/// A token with `body` as its unsigned payload, for a test of a reader.
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

    // A token with two segments, bad base64, or a payload that is not JSON
    // reads as no payload and never as a failure.
    try std.testing.expect(try payload(gpa, "e30.e30") == null);
    try std.testing.expect(try payload(gpa, "e30.!!!.sig") == null);
    const not_json = try testToken(gpa, "not json");
    defer gpa.free(not_json);
    try std.testing.expect(try payload(gpa, not_json) == null);
}

test stringClaim {
    const gpa = std.testing.allocator;
    const token = try testToken(gpa, "{\"sub\":\"user-1\",\"exp\":2000000000}");
    defer gpa.free(token);
    const subject = (try stringClaim(gpa, token, "sub")).?;
    defer gpa.free(subject);
    try std.testing.expectEqualStrings("user-1", subject);
    // A claim that is absent or not a string reads as none.
    try std.testing.expect(try stringClaim(gpa, token, "email") == null);
    try std.testing.expect(try stringClaim(gpa, token, "exp") == null);
    try std.testing.expect(try stringClaim(gpa, "opaque-token", "sub") == null);
    // A payload that is not an object holds no claim.
    const list = try testToken(gpa, "[1,2]");
    defer gpa.free(list);
    try std.testing.expect(try stringClaim(gpa, list, "sub") == null);
}
