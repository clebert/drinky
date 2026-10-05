const std = @import("std");

const core = @import("core");

const callback = @import("../oauth/callback.zig");
const store = @import("../oauth/store.zig");
const wire = @import("../oauth/wire.zig");

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const token_url = "https://platform.claude.com/v1/oauth/token";

pub const sign_in: store.SignIn = .{ .callback = .state };
pub const secret: store.Secret = .access_token;
pub const callback_port = 53692;

const plan: Authorization = .{
    .url = "https://claude.ai/oauth/authorize",
    .port = callback_port,
    .scope = "org%3Acreate_api_key%20user%3Aprofile%20user%3Ainference" ++
        "%20user%3Asessions%3Aclaude_code%20user%3Amcp_servers%20user%3Afile_upload",
};

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,

    pub fn deinit(self: *const Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
    }
};

pub const Authorization = struct {
    url: []const u8,
    port: u16,
    scope: []const u8,
};

const Payload = struct {
    body: []const u8,
    refresh_kept: []const u8 = "",
};

pub fn authorizeUrl(gpa: std.mem.Allocator, pkce: *const wire.Pkce) ![]u8 {
    return authorizeUrlOf(gpa, plan, pkce);
}

pub fn authorizeUrlOf(
    gpa: std.mem.Allocator,
    comptime authorization: Authorization,
    pkce: *const wire.Pkce,
) ![]u8 {
    const redirect_encoded = comptime std.fmt.comptimePrint(
        "http%3A%2F%2Flocalhost%3A{d}%2Fcallback",
        .{authorization.port},
    );
    return std.fmt.allocPrint(
        gpa,
        authorization.url ++ "?code=true&client_id=" ++ client_id ++
            "&response_type=code&redirect_uri=" ++ redirect_encoded ++
            "&scope=" ++ authorization.scope ++
            "&code_challenge={s}&code_challenge_method=S256&state={s}",
        .{ pkce.challenge, pkce.state },
    );
}

pub fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    redirect: *const callback.Redirect,
    pkce: *const wire.Pkce,
) !Tokens {
    const payload = try postCode(gpa, io, link, callback_port, redirect, pkce);
    defer gpa.free(payload);
    return parseTokens(gpa, io, &.{ .body = payload });
}

pub fn postCode(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    comptime port: u16,
    redirect: *const callback.Redirect,
    pkce: *const wire.Pkce,
) ![]u8 {
    const body = try exchangeBody(gpa, port, redirect.code, pkce);
    defer gpa.free(body);
    return wire.post(gpa, io, link, &.{
        .url = token_url,
        .content_type = "application/json",
        .body = body,
    });
}

fn exchangeBody(
    gpa: std.mem.Allocator,
    comptime port: u16,
    code: []const u8,
    pkce: *const wire.Pkce,
) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "authorization_code",
        .client_id = client_id,
        .code = code,
        .state = pkce.state[0..],
        .redirect_uri = comptime std.fmt.comptimePrint("http://localhost:{d}/callback", .{port}),
        .code_verifier = pkce.verifier[0..],
    }, .{});
}

pub fn refresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    tokens: *const Tokens,
) !Tokens {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = tokens.refresh,
    }, .{});
    defer gpa.free(body);
    const payload = try wire.post(gpa, io, link, &.{
        .url = token_url,
        .content_type = "application/json",
        .body = body,
    });
    defer gpa.free(payload);
    return parseTokens(gpa, io, &.{ .body = payload, .refresh_kept = tokens.refresh });
}

fn parseTokens(gpa: std.mem.Allocator, io: std.Io, payload: *const Payload) !Tokens {
    const reply = try wire.parseReply(gpa, &.{
        .body = payload.body,
        .now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .refresh_kept = payload.refresh_kept,
    });
    return .{ .access = reply.access, .refresh = reply.refresh, .expires_ms = reply.expires_ms };
}

test authorizeUrl {
    var pkce: wire.Pkce = undefined;
    @memset(&pkce.verifier, 'v');
    @memset(&pkce.challenge, 'c');
    @memset(&pkce.state, 's');
    const url = try authorizeUrl(std.testing.allocator, &pkce);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=sss") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "vvv") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, client_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "localhost%3A53692%2Fcallback") != null);
}

test exchangeBody {
    const pkce = wire.pkce(std.testing.io);
    const body = try exchangeBody(std.testing.allocator, 53693, "c\"ode", &pkce);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("c\"ode", object.get("code").?.string);
    try std.testing.expectEqualStrings(&pkce.state, object.get("state").?.string);
    try std.testing.expectEqualStrings(&pkce.verifier, object.get("code_verifier").?.string);
    try std.testing.expectEqualStrings(
        "http://localhost:53693/callback",
        object.get("redirect_uri").?.string,
    );
}

const test_now_ms = 1_700_000_000_000;

test parseTokens {
    const gpa = std.testing.allocator;
    var clock: core.testing.StepClock = undefined;
    clock.init(gpa, 0);
    defer clock.deinit();
    clock.now_ns = test_now_ms * std.time.ns_per_ms;
    const io = clock.io();

    const fresh = try parseTokens(gpa, io, &.{
        .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":28800}",
    });
    defer fresh.deinit(gpa);
    try std.testing.expectEqualStrings("at", fresh.access);
    try std.testing.expectEqualStrings("rt", fresh.refresh);
    try std.testing.expectEqual(test_now_ms + 28_800_000 - 300_000, fresh.expires_ms);

    const renewed = try parseTokens(gpa, io, &.{
        .body = "{\"access_token\":\"at2\",\"expires_in\":28800}",
        .refresh_kept = "rt",
    });
    defer renewed.deinit(gpa);
    try std.testing.expectEqualStrings("rt", renewed.refresh);
    try std.testing.expectEqual(test_now_ms + 28_800_000 - 300_000, renewed.expires_ms);
}
