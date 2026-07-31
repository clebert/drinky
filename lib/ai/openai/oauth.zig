//! The OpenAI ChatGPT-subscription (Codex) OAuth protocol: PKCE generation,
//! the authorize URL, and the token exchange/refresh HTTP calls. It also reads
//! the account id out of the returned JWT. Credential storage and the login
//! orchestration live in `Auth`. This module only speaks the protocol.
//!
//! These constants and the backend they authenticate against come from the
//! open-source Codex client, not a documented public API. This is an
//! acknowledged off-label surface (the API-key provider is the official
//! fallback).

const std = @import("std");

const json = @import("../json.zig");
const net = @import("../net.zig");
const oauth_wire = @import("../oauth_wire.zig");

const base64url = std.base64.url_safe_no_pad.Encoder;
const base64url_decoder = std.base64.url_safe_no_pad.Decoder;

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const authorize_url = "https://auth.openai.com/oauth/authorize";
const token_url = "https://auth.openai.com/oauth/token";
pub const callback_port = 1455;

const redirect_encoded = "http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback";
const scope_encoded = "openid%20profile%20email%20offline_access";
const originator = "pith";
const refresh_margin_ms = 5 * 60 * 1000;

/// The JWT claim namespace OpenAI nests the ChatGPT identity under.
const auth_claim = "https://api.openai.com/auth";

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    /// Absolute epoch milliseconds at which `access` becomes stale, derived
    /// from the access token's JWT `exp` claim less a refresh margin.
    expires_ms: i64,
    /// The ChatGPT account id (from the id-token JWT), sent as the
    /// `chatgpt-account-id` header on every request.
    account_id: []const u8,

    pub fn deinit(self: Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
        gpa.free(self.account_id);
    }
};

/// The browser authorize URL for `code`. Caller frees the result. The verifier
/// doubles as the CSRF `state`, so the callback's state must match it.
pub fn authorizeUrl(gpa: std.mem.Allocator, code: *const oauth_wire.Pkce) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        authorize_url ++ "?response_type=code&client_id=" ++ client_id ++
            "&redirect_uri=" ++ redirect_encoded ++ "&scope=" ++ scope_encoded ++
            "&code_challenge={s}&code_challenge_method=S256" ++
            "&id_token_add_organizations=true&codex_cli_simplified_flow=true" ++
            "&originator=" ++ originator ++ "&state={s}",
        .{ code.challenge, code.verifier },
    );
}

/// The authorization grant traded for tokens: the callback's `code` and the
/// local PKCE `verifier`.
pub const Grant = struct {
    code: []const u8,
    verifier: []const u8,
};

/// Exchange an authorization grant for tokens (form-urlencoded body). Caller
/// frees the result. `code` stays as received from the callback, not
/// re-encoded, so the form body does not double-escape it.
pub fn exchange(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts, grant: Grant) !Tokens {
    const body = try std.fmt.allocPrint(
        gpa,
        "grant_type=authorization_code&client_id=" ++ client_id ++
            "&code={s}&code_verifier={s}&redirect_uri=" ++ redirect_encoded,
        .{ grant.code, grant.verifier },
    );
    defer gpa.free(body);
    return post(gpa, io, timeouts, .{
        .body = body,
        .content_type = "application/x-www-form-urlencoded",
    }, .{});
}

/// Trade a refresh token for fresh tokens (JSON body). A refresh response can
/// omit the refresh token or id token, so the current `account_id` and
/// `refresh_token` carry over when the response leaves them out. Caller
/// frees the result.
pub fn refresh(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts, tokens: Tokens) !Tokens {
    const body = try refreshBody(gpa, tokens.refresh);
    defer gpa.free(body);
    return post(gpa, io, timeouts, .{ .body = body, .content_type = "application/json" }, .{
        .refresh = tokens.refresh,
        .account_id = tokens.account_id,
    });
}

/// The refresh body via the JSON serializer, so a refresh token that needs
/// escaping cannot break the request. Caller frees the result.
fn refreshBody(gpa: std.mem.Allocator, refresh_token: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = refresh_token,
    }, .{});
}

const Fallback = struct { refresh: []const u8 = "", account_id: []const u8 = "" };

const Payload = struct { body: []const u8, content_type: []const u8 };

fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    payload: Payload,
    fallback: Fallback,
) !Tokens {
    const response =
        try oauth_wire.post(gpa, io, timeouts, token_url, payload.content_type, payload.body);
    defer gpa.free(response);
    return parseTokens(gpa, response, fallback);
}

fn parseTokens(gpa: std.mem.Allocator, body: []const u8, fallback: Fallback) !Tokens {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadTokenResponse;

    const access = json.string(object.get("access_token")) orelse return error.MissingAccessToken;
    const maybe_id_token = json.string(object.get("id_token"));
    // A refresh can reissue neither the refresh token nor the id token. Carry
    // the current values over when the response omits them.
    const refresh_token = json.string(object.get("refresh_token")) orelse fallback.refresh;
    if (refresh_token.len == 0) return error.MissingRefreshToken;

    const expires_ms = (try jwtExpiryMs(gpa, access)) orelse return error.MissingExpiry;

    // The account id lives in the id-token JWT, but the same claim rides on the
    // access token. Try both, then fall back to the stored id.
    const account_owned = try accountId(gpa, maybe_id_token, access, fallback.account_id);
    errdefer gpa.free(account_owned);

    const access_owned = try gpa.dupe(u8, access);
    errdefer gpa.free(access_owned);
    const refresh_owned = try gpa.dupe(u8, refresh_token);

    return .{
        .access = access_owned,
        .refresh = refresh_owned,
        .expires_ms = expires_ms,
        .account_id = account_owned,
    };
}

/// The ChatGPT account id: from the id token, then the access token, then the
/// carried-over value. An owned dupe. Caller frees. Errors only on OOM: a
/// malformed or claimless token is skipped cleanly.
fn accountId(
    gpa: std.mem.Allocator,
    maybe_id_token: ?[]const u8,
    access_token: []const u8,
    fallback: []const u8,
) error{ OutOfMemory, MissingAccountId }![]const u8 {
    if (maybe_id_token) |id_token| {
        if (try claimAccountId(gpa, id_token)) |found| return found;
    }
    if (try claimAccountId(gpa, access_token)) |found| return found;
    if (fallback.len != 0) return gpa.dupe(u8, fallback);
    return error.MissingAccountId;
}

/// The `chatgpt_account_id` claim from `token`'s JWT payload as an owned dupe, or
/// null when the token is malformed or lacks the claim (never a crash).
fn claimAccountId(gpa: std.mem.Allocator, token: []const u8) error{OutOfMemory}!?[]const u8 {
    const parsed = (try decodePayload(gpa, token)) orelse return null;
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return null;
    const auth = json.object(object.get(auth_claim)) orelse return null;
    const id = json.string(auth.get("chatgpt_account_id")) orelse return null;
    return try gpa.dupe(u8, id);
}

/// Absolute expiry in epoch milliseconds from `token`'s JWT `exp` claim
/// (seconds) less the refresh margin. Null when the token is malformed or has
/// no `exp`.
fn jwtExpiryMs(gpa: std.mem.Allocator, token: []const u8) error{OutOfMemory}!?i64 {
    const parsed = (try decodePayload(gpa, token)) orelse return null;
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return null;
    const exp = json.integer(object.get("exp")) orelse return null;
    // A crafted `exp` must be skipped, not crash: overflow yields a null expiry
    // (a clean MissingExpiry upstream) rather than a panic.
    const millis = std.math.mul(i64, exp, 1000) catch return null;
    return std.math.sub(i64, millis, refresh_margin_ms) catch return null;
}

/// Decode a JWT's payload (the middle of three dot-separated segments) and
/// parse it as JSON. Null — never an error — on fewer than three segments or
/// bad base64. We only read our own token, so no signature is verified.
fn decodePayload(
    gpa: std.mem.Allocator,
    token: []const u8,
) error{OutOfMemory}!?std.json.Parsed(std.json.Value) {
    var segments = std.mem.splitScalar(u8, token, '.');
    _ = segments.next() orelse return null;
    const payload = segments.next() orelse return null;
    if (segments.next() == null) return null;

    const len = base64url_decoder.calcSizeForSlice(payload) catch return null;
    const buffer = try gpa.alloc(u8, len);
    defer gpa.free(buffer);
    base64url_decoder.decode(buffer, payload) catch return null;
    return std.json.parseFromSlice(std.json.Value, gpa, buffer, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

test authorizeUrl {
    var code: oauth_wire.Pkce = undefined;
    @memset(&code.verifier, 'v');
    @memset(&code.challenge, 'c');
    const url = try authorizeUrl(std.testing.allocator, &code);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, client_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "codex_cli_simplified_flow=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=vvv") != null);
}

test refreshBody {
    const body = try refreshBody(std.testing.allocator, "r\"t");
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("r\"t", parsed.value.object.get("refresh_token").?.string);
}

/// A JWT with `payload` as its (unsigned) body, to exercise the extractors.
fn makeJwt(gpa: std.mem.Allocator, payload: []const u8) ![]u8 {
    var encoded: [1024]u8 = undefined;
    const body = base64url.encode(&encoded, payload);
    return std.fmt.allocPrint(gpa, "e30.{s}.sig", .{body});
}

test parseTokens {
    const gpa = std.testing.allocator;
    // The expiry rides on the access token. The account id rides on the id token.
    const access = try makeJwt(gpa, "{\"exp\":2000000000}");
    defer gpa.free(access);
    const id = try makeJwt(
        gpa,
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_123\"}}",
    );
    defer gpa.free(id);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\",\"id_token\":\"{s}\"}}",
        .{ access, id },
    );
    defer gpa.free(body);

    const tokens = try parseTokens(gpa, body, .{});
    defer tokens.deinit(gpa);
    try std.testing.expectEqualStrings(access, tokens.access);
    try std.testing.expectEqualStrings("rt", tokens.refresh);
    try std.testing.expectEqualStrings("acct_123", tokens.account_id);
    try std.testing.expectEqual(@as(i64, 2000000000 * 1000 - refresh_margin_ms), tokens.expires_ms);
}

test "parseTokens carries over refresh token and account id on a partial refresh" {
    const gpa = std.testing.allocator;
    const access = try makeJwt(gpa, "{\"exp\":2000000000}");
    defer gpa.free(access);
    const body = try std.fmt.allocPrint(gpa, "{{\"access_token\":\"{s}\"}}", .{access});
    defer gpa.free(body);

    const tokens = try parseTokens(gpa, body, .{ .refresh = "old_rt", .account_id = "acct_old" });
    defer tokens.deinit(gpa);
    try std.testing.expectEqualStrings("old_rt", tokens.refresh);
    try std.testing.expectEqualStrings("acct_old", tokens.account_id);
}

test "parseTokens fails cleanly when the account id cannot be found" {
    const gpa = std.testing.allocator;
    const access = try makeJwt(gpa, "{\"exp\":2000000000}");
    defer gpa.free(access);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\"}}",
        .{access},
    );
    defer gpa.free(body);
    try std.testing.expectError(error.MissingAccountId, parseTokens(gpa, body, .{}));
}

test "parseTokens rejects a token whose JWT has no expiry" {
    const gpa = std.testing.allocator;
    const access = try makeJwt(gpa, "{\"sub\":\"x\"}");
    defer gpa.free(access);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\"}}",
        .{access},
    );
    defer gpa.free(body);
    try std.testing.expectError(error.MissingExpiry, parseTokens(gpa, body, .{}));
}

test "parseTokens skips a crafted expiry that would overflow" {
    const gpa = std.testing.allocator;
    // An `exp` near maxInt(i64) must fail cleanly like a missing one, not crash
    // in the conversion to milliseconds.
    const access = try makeJwt(gpa, "{\"exp\":9223372036854775807}");
    defer gpa.free(access);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\"}}",
        .{access},
    );
    defer gpa.free(body);
    try std.testing.expectError(error.MissingExpiry, parseTokens(gpa, body, .{}));
}
