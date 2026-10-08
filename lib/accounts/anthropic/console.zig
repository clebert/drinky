const std = @import("std");

const providers = @import("providers");

const callback = @import("../oauth/callback.zig");
const store = @import("../oauth/store.zig");
const wire = @import("../oauth/wire.zig");
const oauth = @import("oauth.zig");

const create_key_url = "https://api.anthropic.com/api/oauth/claude_cli/create_api_key";

pub const sign_in: store.SignIn = .{ .callback = .state };
pub const secret: store.Secret = .api_key;
pub const callback_port = 53693;

const console: oauth.Authorization = .{
    .url = "https://platform.claude.com/oauth/authorize",
    .port = callback_port,
    .scope = "org%3Acreate_api_key%20user%3Aprofile",
};

const FieldOptions = struct {
    body: []const u8,
    name: []const u8,
    missing_error: error{ MissingAccessToken, MissingApiKey },
};

pub fn authorizeUrl(gpa: std.mem.Allocator, pkce: *const wire.Pkce) ![]u8 {
    return oauth.authorizeUrlOf(gpa, console, pkce);
}

pub fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    redirect: *const callback.Redirect,
    pkce: *const wire.Pkce,
) !store.ApiKey {
    const payload = try oauth.postCode(gpa, io, link, callback_port, redirect, pkce);
    defer gpa.free(payload);
    const access = try parseField(gpa, &.{
        .body = payload,
        .name = "access_token",
        .missing_error = error.MissingAccessToken,
    });
    defer gpa.free(access);
    return .{ .api_key = try createApiKey(gpa, io, link, access) };
}

fn createApiKey(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    access: []const u8,
) ![]u8 {
    const authorization = try gpa.print("Bearer {s}", .{access});
    defer gpa.free(authorization);
    const payload = try wire.postBearer(gpa, io, link, &.{
        .url = create_key_url,
        .authorization = authorization,
    });
    defer gpa.free(payload);
    return parseField(gpa, &.{
        .body = payload,
        .name = "raw_key",
        .missing_error = error.MissingApiKey,
    });
}

fn parseField(gpa: std.mem.Allocator, options: *const FieldOptions) ![]u8 {
    const parsed = try wire.parseJson(gpa, options.body);
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return error.BadTokenResponse;
    const value = providers.json.string(object.getPtr(options.name)) orelse
        return options.missing_error;
    return gpa.dupe(u8, value);
}

test authorizeUrl {
    var pkce: wire.Pkce = undefined;
    @memset(&pkce.verifier, 'v');
    @memset(&pkce.challenge, 'c');
    @memset(&pkce.state, 's');
    const url = try authorizeUrl(std.testing.allocator, &pkce);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, console.url ++ "?code=true&client_id="));
    try std.testing.expect(std.mem.find(u8, url, "state=sss") != null);
    try std.testing.expect(std.mem.find(u8, url, "vvv") == null);
    try std.testing.expect(std.mem.find(u8, url, "org%3Acreate_api_key") != null);
    try std.testing.expect(std.mem.find(u8, url, "53693") != null);
}

test parseField {
    const gpa = std.testing.allocator;
    const body = "{\"raw_key\":\"sk-ant-api03-x\"}";
    const key = try parseField(gpa, &.{
        .body = body,
        .name = "raw_key",
        .missing_error = error.MissingApiKey,
    });
    defer gpa.free(key);
    try std.testing.expectEqualStrings("sk-ant-api03-x", key);
    try std.testing.expectError(
        error.MissingApiKey,
        parseField(gpa, &.{
            .body = "{\"other\":\"y\"}",
            .name = "raw_key",
            .missing_error = error.MissingApiKey,
        }),
    );
}
