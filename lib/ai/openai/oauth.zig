//! OpenAI ChatGPT-subscription (Codex) OAuth protocol: PKCE generation, the
//! authorize URL, and the token exchange/refresh HTTP calls, plus reading the
//! account id out of the returned JWT. Credential storage and the login
//! orchestration live in `Auth`; this module only speaks the protocol.
//!
//! These constants and the backend they authenticate against are read from the
//! open-source Codex client, not a documented public API — an acknowledged
//! off-label surface (the API-key provider is the official fallback).

const std = @import("std");

const net = @import("../net.zig");

const base64url = std.base64.url_safe_no_pad.Encoder;
const base64url_decoder = std.base64.url_safe_no_pad.Decoder;

pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const authorize_url = "https://auth.openai.com/oauth/authorize";
pub const token_url = "https://auth.openai.com/oauth/token";
pub const callback_port = 1455;
pub const redirect_uri = "http://localhost:1455/auth/callback";

const redirect_encoded = "http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback";
const scope = "openid profile email offline_access";
const scope_encoded = "openid%20profile%20email%20offline_access";
const originator = "pith";
const refresh_margin_ms = 5 * 60 * 1000;
/// Hard cap on a token response body: a larger response fails before it can
/// allocate without bound. Well above any real exchange or refresh payload.
const token_response_bytes_max = 256 * 1024;

/// The JWT claim namespace OpenAI nests the ChatGPT identity under.
const auth_claim = "https://api.openai.com/auth";

const verifier_len = base64url.calcSize(32);

pub const Pkce = struct {
    verifier: [verifier_len]u8,
    challenge: [verifier_len]u8,
};

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    /// Absolute epoch milliseconds at which `access` should be considered stale,
    /// derived from the access token's JWT `exp` claim less a refresh margin.
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

/// A fresh PKCE verifier/challenge pair drawn from the Io's CSPRNG.
pub fn pkce(io: std.Io) Pkce {
    var seed: [32]u8 = undefined;
    io.random(&seed);
    var result: Pkce = undefined;
    _ = base64url.encode(&result.verifier, &seed);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&result.verifier, &digest, .{});
    _ = base64url.encode(&result.challenge, &digest);
    return result;
}

/// The browser authorize URL for `code`. Caller frees the result. The verifier
/// doubles as the CSRF `state`, so the callback's state is checked against it.
pub fn authorizeUrl(gpa: std.mem.Allocator, code: *const Pkce) ![]u8 {
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

/// Exchange an authorization `code` for tokens (form-urlencoded body). Caller
/// frees the result. `code` is left as received from the callback — not
/// re-encoded — so it is not double-escaped into the form body.
pub fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    code: []const u8,
    verifier: []const u8,
) !Tokens {
    const body = try std.fmt.allocPrint(
        gpa,
        "grant_type=authorization_code&client_id=" ++ client_id ++
            "&code={s}&code_verifier={s}&redirect_uri=" ++ redirect_encoded,
        .{ code, verifier },
    );
    defer gpa.free(body);
    return post(gpa, io, timeouts, body, "application/x-www-form-urlencoded", .{});
}

/// Trade a refresh token for fresh tokens (JSON body). A refresh response may
/// omit the refresh token or id token, so the current `account_id` and
/// `refresh_token` are carried over when the response leaves them out. Caller
/// frees the result.
pub fn refresh(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts, tokens: Tokens) !Tokens {
    const body = try std.fmt.allocPrint(gpa,
        \\{{"grant_type":"refresh_token","client_id":"{s}","refresh_token":"{s}"}}
    , .{ client_id, tokens.refresh });
    defer gpa.free(body);
    return post(gpa, io, timeouts, body, "application/json", .{
        .refresh = tokens.refresh,
        .account_id = tokens.account_id,
    });
}

const Fallback = struct { refresh: []const u8 = "", account_id: []const u8 = "" };

/// The token request bounded by the connect timeout: the whole connect, send,
/// receive-head, and body read must finish within it, or it is cancelled and
/// reaped as `error.Timeout`.
fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    body: []const u8,
    content_type: []const u8,
    fallback: Fallback,
) !Tokens {
    var out: ?Tokens = null;
    return awaitTokens(
        gpa,
        io,
        timeouts.connect_ms,
        &out,
        fetchInto,
        .{ gpa, io, body, content_type, fallback, &out },
    );
}

/// Run `work` (which writes its result into `out`) bounded by `timeout_ms`. The
/// timeout races the request, so one that finished right at the deadline can
/// still surface as an error with its result discarded; reclaim anything left in
/// `out` on any error so a completed-at-the-deadline request cannot leak.
fn awaitTokens(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeout_ms: u64,
    out: *?Tokens,
    comptime work: anytype,
    args: std.meta.ArgsTuple(@TypeOf(work)),
) !Tokens {
    net.withTimeout(io, timeout_ms, work, args) catch |err| {
        if (out.*) |tokens| tokens.deinit(gpa);
        return err;
    };
    return out.* orelse error.TokenRequestFailed;
}

fn fetchInto(
    gpa: std.mem.Allocator,
    io: std.Io,
    body: []const u8,
    content_type: []const u8,
    fallback: Fallback,
    out: *?Tokens,
) !void {
    const uri = try std.Uri.parse(token_url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var request = try client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = content_type } },
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    var send = try request.sendBodyUnflushed(&.{});
    try send.writer.writeAll(body);
    try send.end();
    try request.connection.?.flush();

    var redirect_buffer: [2048]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.TokenRequestFailed;

    const decompress_buffer = try decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    const payload = try readBody(gpa, reader);
    defer gpa.free(payload);
    out.* = try parseTokens(gpa, payload, fallback);
}

/// The response body, capped at `token_response_bytes_max`: a larger body fails
/// with `error.TokenResponseTooLarge` rather than allocating without bound.
fn readBody(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return reader.allocRemaining(gpa, .limited(token_response_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => error.TokenResponseTooLarge,
        else => err,
    };
}

/// A decompression window sized for `encoding`, or an empty slice when the body
/// is not compressed. Caller frees a non-empty result.
fn decompressBuffer(gpa: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .gzip, .deflate => gpa.alloc(u8, std.compress.flate.max_window_len),
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedContentEncoding,
    };
}

fn parseTokens(gpa: std.mem.Allocator, body: []const u8, fallback: Fallback) !Tokens {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadTokenResponse,
    };

    const access_str = jsonString(object, "access_token") orelse return error.MissingAccessToken;
    const id_token = jsonString(object, "id_token");
    // A refresh may reissue neither the refresh token nor the id token; carry the
    // current values over when the response omits them.
    const refresh_str = jsonString(object, "refresh_token") orelse fallback.refresh;
    if (refresh_str.len == 0) return error.MissingRefreshToken;

    const expires_ms = (try jwtExpiryMs(gpa, access_str)) orelse return error.MissingExpiry;

    // The account id lives in the id-token JWT, but the same claim rides on the
    // access token, so try both before falling back to the stored id.
    const account_owned = try accountId(gpa, id_token, access_str, fallback.account_id);
    errdefer gpa.free(account_owned);

    const access = try gpa.dupe(u8, access_str);
    errdefer gpa.free(access);
    const refresh_owned = try gpa.dupe(u8, refresh_str);

    return .{
        .access = access,
        .refresh = refresh_owned,
        .expires_ms = expires_ms,
        .account_id = account_owned,
    };
}

/// The ChatGPT account id: from the id token, then the access token, then the
/// carried-over value. An owned dupe; caller frees. Errors only on OOM — a
/// malformed or claimless token is skipped cleanly.
fn accountId(
    gpa: std.mem.Allocator,
    id_token: ?[]const u8,
    access_token: []const u8,
    fallback: []const u8,
) error{ OutOfMemory, MissingAccountId }![]const u8 {
    if (id_token) |token| {
        if (try claimAccountId(gpa, token)) |found| return found;
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
    const object = jsonObject(parsed.value) orelse return null;
    const auth = jsonObject(object.get(auth_claim) orelse return null) orelse return null;
    const id = jsonStringValue(auth.get("chatgpt_account_id") orelse return null) orelse return null;
    return try gpa.dupe(u8, id);
}

/// Absolute expiry in epoch milliseconds from `token`'s JWT `exp` claim (seconds)
/// less the refresh margin, or null when the token is malformed or has no `exp`.
fn jwtExpiryMs(gpa: std.mem.Allocator, token: []const u8) error{OutOfMemory}!?i64 {
    const parsed = (try decodePayload(gpa, token)) orelse return null;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return null;
    const exp = switch (object.get("exp") orelse return null) {
        .integer => |integer| integer,
        else => return null,
    };
    // A crafted `exp` must be skipped, not crash: overflow yields a null expiry
    // (a clean MissingExpiry upstream) rather than a panic.
    const millis = std.math.mul(i64, exp, 1000) catch return null;
    return std.math.sub(i64, millis, refresh_margin_ms) catch return null;
}

/// Decode a JWT's payload (the middle of three dot-separated segments) and parse
/// it as JSON. Null — never an error — on fewer than three segments or bad
/// base64; we only read our own token, so no signature is verified.
fn decodePayload(gpa: std.mem.Allocator, token: []const u8) error{OutOfMemory}!?std.json.Parsed(std.json.Value) {
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

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return jsonStringValue(object.get(name) orelse return null);
}

fn jsonStringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

test pkce {
    const code = pkce(std.testing.io);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&code.verifier, &digest, .{});
    var expected: [verifier_len]u8 = undefined;
    _ = base64url.encode(&expected, &digest);
    try std.testing.expectEqualStrings(&expected, &code.challenge);
}

test authorizeUrl {
    var code: Pkce = undefined;
    @memset(&code.verifier, 'v');
    @memset(&code.challenge, 'c');
    const url = try authorizeUrl(std.testing.allocator, &code);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, client_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "codex_cli_simplified_flow=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=vvv") != null);
}

/// A JWT with `payload` as its (unsigned) body, for exercising the extractors.
fn makeJwt(gpa: std.mem.Allocator, payload: []const u8) ![]u8 {
    var encoded: [1024]u8 = undefined;
    const body = base64url.encode(&encoded, payload);
    return std.fmt.allocPrint(gpa, "e30.{s}.sig", .{body});
}

test parseTokens {
    const gpa = std.testing.allocator;
    // Expiry rides on the access token; the account id on the id token.
    const access = try makeJwt(gpa, "{\"exp\":2000000000}");
    defer gpa.free(access);
    const id = try makeJwt(gpa, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_123\"}}");
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
    const body = try std.fmt.allocPrint(gpa, "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\"}}", .{access});
    defer gpa.free(body);
    try std.testing.expectError(error.MissingAccountId, parseTokens(gpa, body, .{}));
}

test "parseTokens rejects a token whose JWT has no expiry" {
    const gpa = std.testing.allocator;
    const access = try makeJwt(gpa, "{\"sub\":\"x\"}");
    defer gpa.free(access);
    const body = try std.fmt.allocPrint(gpa, "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\"}}", .{access});
    defer gpa.free(body);
    try std.testing.expectError(error.MissingExpiry, parseTokens(gpa, body, .{}));
}

test "readBody rejects an oversized token response" {
    const gpa = std.testing.allocator;
    const oversized = try gpa.alloc(u8, token_response_bytes_max);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    var buffer: [64]u8 = undefined;
    var reader = std.testing.Reader.init(&buffer, &.{.{ .buffer = oversized }});
    try std.testing.expectError(error.TokenResponseTooLarge, readBody(gpa, &reader.interface));
}

test "readBody returns a normal token response body" {
    const gpa = std.testing.allocator;
    const body =
        \\{"access_token":"at","refresh_token":"rt","id_token":"it"}
    ;
    var buffer: [64]u8 = undefined;
    var reader = std.testing.Reader.init(&buffer, &.{.{ .buffer = body }});
    const read = try readBody(gpa, &reader.interface);
    defer gpa.free(read);
    try std.testing.expectEqualStrings(body, read);
}

fn produceThenFail(gpa: std.mem.Allocator, out: *?Tokens) anyerror!void {
    out.* = .{
        .access = try gpa.dupe(u8, "access"),
        .refresh = try gpa.dupe(u8, "refresh"),
        .expires_ms = 0,
        .account_id = try gpa.dupe(u8, "account"),
    };
    return error.Canceled;
}

test "a token request that fails after producing a result frees it" {
    const gpa = std.testing.allocator;
    var out: ?Tokens = null;
    // The leak-detecting allocator proves the discarded result was freed.
    try std.testing.expectError(
        error.Canceled,
        awaitTokens(gpa, std.testing.io, 1000, &out, produceThenFail, .{ gpa, &out }),
    );
}
