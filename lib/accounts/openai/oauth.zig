const std = @import("std");

const providers = @import("providers");

const jwt = @import("../jwt.zig");
const callback = @import("../oauth/callback.zig");
const store = @import("../oauth/store.zig");
const wire = @import("../oauth/wire.zig");
const testing = @import("../testing.zig");

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const authorize_url = "https://auth.openai.com/oauth/authorize";
const token_url = "https://auth.openai.com/oauth/token";

pub const sign_in: store.SignIn = .{ .callback = .state };
pub const secret: store.Secret = .access_token;
pub const callback_port = 1455;

const redirect_encoded = "http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback";
const scope_encoded = "openid%20profile%20email%20offline_access";

const auth_claim = "https://api.openai.com/auth";

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,
    account_id: []const u8,

    pub fn deinit(self: *const Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
        gpa.free(self.account_id);
    }
};

const Fallback = struct { refresh: []const u8 = "", account_id: []const u8 = "" };

const Response = struct {
    body: []const u8,
    now_ms: i64,
    fallback: Fallback = .{},
};

const Payload = struct { body: []const u8, content_type: []const u8 };

pub fn authorizeUrl(gpa: std.mem.Allocator, pkce: *const wire.Pkce) ![]u8 {
    return gpa.print(
        authorize_url ++ "?response_type=code&client_id=" ++ client_id ++
            "&redirect_uri=" ++ redirect_encoded ++ "&scope=" ++ scope_encoded ++
            "&code_challenge={s}&code_challenge_method=S256" ++
            "&id_token_add_organizations=true&codex_cli_simplified_flow=true" ++
            "&originator=" ++ providers.Transport.client_name ++ "&state={s}",
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
    const body = try gpa.print(
        "grant_type=authorization_code&client_id=" ++ client_id ++
            "&code={s}&code_verifier={s}&redirect_uri=" ++ redirect_encoded,
        .{ redirect.code, pkce.verifier },
    );
    defer gpa.free(body);
    return post(gpa, io, link, &.{ .body = body, .content_type = wire.form_content_type }, &.{});
}

pub fn refresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    tokens: *const Tokens,
) !Tokens {
    const body = try refreshBody(gpa, tokens.refresh);
    defer gpa.free(body);
    return post(gpa, io, link, &.{ .body = body, .content_type = "application/json" }, &.{
        .refresh = tokens.refresh,
        .account_id = tokens.account_id,
    });
}

fn refreshBody(gpa: std.mem.Allocator, refresh_token: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = refresh_token,
    }, .{});
}

fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    payload: *const Payload,
    fallback: *const Fallback,
) !Tokens {
    const body = try wire.post(gpa, io, link, &.{
        .url = token_url,
        .content_type = payload.content_type,
        .body = payload.body,
    });
    defer gpa.free(body);
    return parseTokens(gpa, &.{
        .body = body,
        .now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .fallback = fallback.*,
    });
}

fn parseTokens(gpa: std.mem.Allocator, response: *const Response) !Tokens {
    const reply = try wire.parseReply(gpa, &.{
        .body = response.body,
        .now_ms = response.now_ms,
        .refresh_kept = response.fallback.refresh,
    });
    errdefer reply.deinit(gpa);

    const exp_ms = (try jwtExpiryMs(gpa, reply.access)) orelse return error.MissingExpiry;
    const lifetime_ms = std.math.sub(i64, exp_ms, response.now_ms) catch
        return error.MissingExpiry;
    const expires_ms = wire.expiresAt(&.{
        .now_ms = response.now_ms,
        .lifetime_ms = lifetime_ms,
    }) orelse return error.MissingExpiry;

    const parsed = try wire.parseJson(gpa, response.body);
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return error.BadTokenResponse;
    const maybe_id_token = providers.json.string(object.getPtr("id_token"));
    const account_id = response.fallback.account_id;
    return .{
        .access = reply.access,
        .refresh = reply.refresh,
        .expires_ms = expires_ms,
        .account_id = try accountId(gpa, &.{
            .id_token = maybe_id_token,
            .access_token = reply.access,
            .fallback = account_id,
        }),
    };
}

fn accountId(
    gpa: std.mem.Allocator,
    sources: *const struct {
        id_token: ?[]const u8,
        access_token: []const u8,
        fallback: []const u8,
    },
) error{ OutOfMemory, MissingAccountId }![]const u8 {
    if (sources.id_token) |id_token| {
        if (try claimAccountId(gpa, id_token)) |found| return found;
    }
    if (try claimAccountId(gpa, sources.access_token)) |found| return found;
    if (sources.fallback.len != 0) return gpa.dupe(u8, sources.fallback);
    return error.MissingAccountId;
}

fn claimAccountId(gpa: std.mem.Allocator, token: []const u8) error{OutOfMemory}!?[]const u8 {
    const parsed = (try jwt.payload(gpa, token)) orelse return null;
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return null;
    const auth = providers.json.object(object.getPtr(auth_claim)) orelse return null;
    const id = providers.json.string(auth.getPtr("chatgpt_account_id")) orelse return null;
    return try gpa.dupe(u8, id);
}

fn jwtExpiryMs(gpa: std.mem.Allocator, token: []const u8) error{OutOfMemory}!?i64 {
    const parsed = (try jwt.payload(gpa, token)) orelse return null;
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return null;
    const exp = providers.json.integer(object.getPtr("exp")) orelse return null;
    return std.math.mul(i64, exp, std.time.ms_per_s) catch null;
}

test authorizeUrl {
    var pkce: wire.Pkce = undefined;
    @memset(&pkce.verifier, 'v');
    @memset(&pkce.challenge, 'c');
    @memset(&pkce.state, 's');
    const url = try authorizeUrl(std.testing.allocator, &pkce);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.find(u8, url, "state=sss") != null);
    try std.testing.expect(std.mem.find(u8, url, "vvv") == null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, url, client_id) != null);
    try std.testing.expect(std.mem.find(u8, url, "codex_cli_simplified_flow=true") != null);
}

test refreshBody {
    const body = try refreshBody(std.testing.allocator, "r\"t");
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("r\"t", parsed.value.object.get("refresh_token").?.string);
}

const test_now_ms = 1_700_000_000_000;

test parseTokens {
    const gpa = std.testing.allocator;
    const access = try testing.fakeJwt(gpa, "{\"exp\":2000000000}");
    defer gpa.free(access);
    const id = try testing.fakeJwt(
        gpa,
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_123\"}}",
    );
    defer gpa.free(id);
    const body = try gpa.print(
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\",\"id_token\":\"{s}\"}}",
        .{ access, id },
    );
    defer gpa.free(body);

    const tokens = try parseTokens(gpa, &.{ .body = body, .now_ms = test_now_ms });
    defer tokens.deinit(gpa);
    try std.testing.expectEqualStrings(access, tokens.access);
    try std.testing.expectEqualStrings("rt", tokens.refresh);
    try std.testing.expectEqualStrings("acct_123", tokens.account_id);
    try std.testing.expectEqual(
        @as(i64, 2000000000 * 1000 - 5 * std.time.ms_per_min),
        tokens.expires_ms,
    );
}

test "parseTokens carries over refresh token and account id on a partial refresh" {
    const gpa = std.testing.allocator;
    const access = try testing.fakeJwt(gpa, "{\"exp\":2000000000}");
    defer gpa.free(access);
    const body = try gpa.print("{{\"access_token\":\"{s}\"}}", .{access});
    defer gpa.free(body);

    const tokens = try parseTokens(gpa, &.{
        .body = body,
        .now_ms = test_now_ms,
        .fallback = .{ .refresh = "old_rt", .account_id = "acct_old" },
    });
    defer tokens.deinit(gpa);
    try std.testing.expectEqualStrings("old_rt", tokens.refresh);
    try std.testing.expectEqualStrings("acct_old", tokens.account_id);
}

test "parseTokens fails cleanly when the account id cannot be found" {
    const gpa = std.testing.allocator;
    const access = try testing.fakeJwt(gpa, "{\"exp\":2000000000}");
    defer gpa.free(access);
    const body = try gpa.print(
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\"}}",
        .{access},
    );
    defer gpa.free(body);
    try std.testing.expectError(
        error.MissingAccountId,
        parseTokens(gpa, &.{ .body = body, .now_ms = test_now_ms }),
    );
}

test "parseTokens rejects a token whose JWT has no expiry" {
    const gpa = std.testing.allocator;
    const access = try testing.fakeJwt(gpa, "{\"sub\":\"x\"}");
    defer gpa.free(access);
    const body = try gpa.print(
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\"}}",
        .{access},
    );
    defer gpa.free(body);
    try std.testing.expectError(
        error.MissingExpiry,
        parseTokens(gpa, &.{ .body = body, .now_ms = test_now_ms }),
    );
}

test "parseTokens skips a crafted expiry that overflows" {
    const gpa = std.testing.allocator;
    const access = try testing.fakeJwt(gpa, "{\"exp\":9223372036854775807}");
    defer gpa.free(access);
    const body = try gpa.print(
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\"}}",
        .{access},
    );
    defer gpa.free(body);
    try std.testing.expectError(
        error.MissingExpiry,
        parseTokens(gpa, &.{ .body = body, .now_ms = test_now_ms }),
    );
}
