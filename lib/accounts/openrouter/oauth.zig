const std = @import("std");

const providers = @import("providers");

const callback = @import("../oauth/callback.zig");
const store = @import("../oauth/store.zig");
const wire = @import("../oauth/wire.zig");

const authorize_url = "https://openrouter.ai/auth";
const keys_url = "https://openrouter.ai/api/v1/auth/keys";
const seed_bytes = 16;
const path_bytes = 1 + 2 * seed_bytes;

pub const sign_in: store.SignIn = .{ .callback = .path };
pub const secret: store.Secret = .api_key;
pub const callback_port = 53694;

comptime {
    std.debug.assert(path_bytes <= callback.path_bytes_max);
}

pub fn callbackPath(buffer: *[callback.path_bytes_max]u8, io: std.Io) []const u8 {
    var seed: [seed_bytes]u8 = undefined;
    io.random(&seed);
    buffer[0] = '/';
    const hex = "0123456789abcdef";
    for (seed, 0..) |byte, index| {
        buffer[1 + index * 2] = hex[byte >> 4];
        buffer[2 + index * 2] = hex[byte & 0xf];
    }
    return buffer[0..path_bytes];
}

pub fn authorizeUrl(
    gpa: std.mem.Allocator,
    pkce: *const wire.Pkce,
    callback_path: []const u8,
) ![]u8 {
    const callback_url = try std.fmt.allocPrint(
        gpa,
        "http://localhost:{d}{s}",
        .{ callback_port, callback_path },
    );
    defer gpa.free(callback_url);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(authorize_url ++ "?callback_url=");
    wire.percentEncode(&out.writer, callback_url) catch return error.OutOfMemory;
    try out.writer.print(
        "&code_challenge={s}&code_challenge_method=S256",
        .{pkce.challenge},
    );
    return out.toOwnedSlice();
}

pub fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    redirect: *const callback.Redirect,
    pkce: *const wire.Pkce,
) !store.ApiKey {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .code = redirect.code,
        .code_verifier = pkce.verifier[0..],
        .code_challenge_method = "S256",
    }, .{});
    defer gpa.free(body);
    const payload = try wire.post(gpa, io, link, &.{
        .url = keys_url,
        .content_type = "application/json",
        .body = body,
    });
    defer gpa.free(payload);
    return .{ .api_key = try parseKey(gpa, payload) };
}

fn parseKey(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try wire.parseJson(gpa, body);
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return error.BadTokenResponse;
    const value = providers.json.string(object.getPtr("key")) orelse return error.MissingApiKey;
    return gpa.dupe(u8, value);
}

test authorizeUrl {
    var pkce: wire.Pkce = undefined;
    @memset(&pkce.verifier, 'v');
    @memset(&pkce.challenge, 'c');
    const url = try authorizeUrl(std.testing.allocator, &pkce, "/deadbeef");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, authorize_url ++ "?callback_url="));
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "53694") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "deadbeef") != null);
}

test callbackPath {
    var buffer: [callback.path_bytes_max]u8 = undefined;
    const path = callbackPath(&buffer, std.testing.io);
    try std.testing.expectEqual(@as(usize, path_bytes), path.len);
    try std.testing.expect(path[0] == '/');
    for (path[1..]) |byte| try std.testing.expect(std.ascii.isHex(byte));
}

test parseKey {
    const gpa = std.testing.allocator;
    const key = try parseKey(gpa, "{\"key\":\"sk-or-v1-x\"}");
    defer gpa.free(key);
    try std.testing.expectEqualStrings("sk-or-v1-x", key);
    try std.testing.expectError(error.MissingApiKey, parseKey(gpa, "{\"other\":\"y\"}"));
    try std.testing.expectError(error.BadTokenResponse, parseKey(gpa, "[]"));
}
