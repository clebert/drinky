//! The OpenRouter OAuth protocol. It uses PKCE with no client registration.
//! The exchange trades the code for a user-owned key. The account needs no
//! token refresh. A random callback path binds the redirect.
//!
//! OpenRouter documents this flow and the endpoints below for any client, so
//! this is a supported surface, unlike the subscription logins of the other
//! providers.

const std = @import("std");

const json = @import("../json.zig");
const net = @import("../net.zig");
const oauth_wire = @import("../oauth_wire.zig");

const authorize_url = "https://openrouter.ai/auth";
const keys_url = "https://openrouter.ai/api/v1/auth/keys";
pub const callback_port = 53694;
pub const callback_path_len = 1 + 32;

/// The minted API key. It never expires in session and needs no refresh, so it
/// is the only stored field.
pub const Tokens = struct {
    api_key: []const u8,

    pub fn deinit(self: Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.api_key);
    }
};

/// A random callback path that binds the redirect the way `state` does.
pub fn callbackPath(buffer: *[callback_path_len]u8, io: std.Io) []const u8 {
    var seed: [16]u8 = undefined;
    io.random(&seed);
    buffer[0] = '/';
    const hex = "0123456789abcdef";
    for (seed, 0..) |byte, index| {
        buffer[1 + index * 2] = hex[byte >> 4];
        buffer[2 + index * 2] = hex[byte & 0xf];
    }
    return buffer;
}

/// The browser authorize URL for `code` and `callback_path`. The caller frees
/// the result.
pub fn authorizeUrl(
    gpa: std.mem.Allocator,
    code: *const oauth_wire.Pkce,
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
    std.Uri.Component.percentEncode(&out.writer, callback_url, isUnreserved) catch
        return error.OutOfMemory;
    try out.writer.print(
        "&code_challenge={s}&code_challenge_method=S256",
        .{code.challenge},
    );
    return out.toOwnedSlice();
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

/// The authorization grant traded for a key: the callback `code` and the local
/// PKCE `verifier`.
pub const Grant = struct {
    code: []const u8,
    verifier: []const u8,
};

/// Trade an authorization grant for a minted API key. The caller frees the
/// result.
pub fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    grant: *const Grant,
) !Tokens {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .code = grant.code,
        .code_verifier = grant.verifier,
        .code_challenge_method = "S256",
    }, .{});
    defer gpa.free(body);
    const payload = try oauth_wire.post(gpa, io, timeouts, keys_url, "application/json", body);
    defer gpa.free(payload);
    return .{ .api_key = try parseKey(gpa, payload) };
}

fn parseKey(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadTokenResponse;
    const value = json.string(object.get("key")) orelse return error.MissingApiKey;
    return gpa.dupe(u8, value);
}

test authorizeUrl {
    var code: oauth_wire.Pkce = undefined;
    @memset(&code.verifier, 'v');
    @memset(&code.challenge, 'c');
    const url = try authorizeUrl(std.testing.allocator, &code, "/deadbeef");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, authorize_url ++ "?callback_url="));
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "53694") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "deadbeef") != null);
}

test callbackPath {
    var buffer: [callback_path_len]u8 = undefined;
    const path = callbackPath(&buffer, std.testing.io);
    try std.testing.expectEqual(@as(usize, callback_path_len), path.len);
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
