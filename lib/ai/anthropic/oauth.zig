//! Anthropic subscription OAuth protocol: PKCE generation, the authorize URL,
//! and the token exchange/refresh HTTP calls. Credential storage and the login
//! orchestration live in `Auth`; this module only speaks the protocol.

const std = @import("std");

const net = @import("../net.zig");

const base64url = std.base64.url_safe_no_pad.Encoder;

pub const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const authorize_url = "https://claude.ai/oauth/authorize";
pub const token_url = "https://platform.claude.com/v1/oauth/token";
pub const callback_port = 53692;
pub const redirect_uri = "http://localhost:53692/callback";

const redirect_encoded = "http%3A%2F%2Flocalhost%3A53692%2Fcallback";
const scope_encoded = "org%3Acreate_api_key%20user%3Aprofile%20user%3Ainference" ++
    "%20user%3Asessions%3Aclaude_code%20user%3Amcp_servers%20user%3Afile_upload";
const refresh_margin_ms = 5 * 60 * 1000;
/// Hard cap on a token response body: a larger response fails before it can
/// allocate without bound. Well above any real exchange or refresh payload.
const token_response_bytes_max = 256 * 1024;

const verifier_len = base64url.calcSize(32);

pub const Pkce = struct {
    verifier: [verifier_len]u8,
    challenge: [verifier_len]u8,
};

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    /// Absolute epoch milliseconds at which `access` should be considered stale.
    expires_ms: i64,

    pub fn deinit(self: Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
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

/// The browser authorize URL for `code`. Caller frees the result.
pub fn authorizeUrl(gpa: std.mem.Allocator, code: *const Pkce) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        authorize_url ++ "?code=true&client_id=" ++ client_id ++
            "&response_type=code&redirect_uri=" ++ redirect_encoded ++
            "&scope=" ++ scope_encoded ++ "&code_challenge={s}&code_challenge_method=S256&state={s}",
        .{ code.challenge, code.verifier },
    );
}

/// Exchange an authorization `code` for tokens. Caller frees the result.
pub fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    code: []const u8,
    state: []const u8,
    verifier: []const u8,
) !Tokens {
    const body = try exchangeBody(gpa, code, state, verifier);
    defer gpa.free(body);
    return post(gpa, io, timeouts, body);
}

/// The exchange body via the JSON serializer, so hostile callback bytes cannot
/// inject members into the token request. Caller frees the result.
fn exchangeBody(
    gpa: std.mem.Allocator,
    code: []const u8,
    state: []const u8,
    verifier: []const u8,
) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "authorization_code",
        .client_id = client_id,
        .code = code,
        .state = state,
        .redirect_uri = redirect_uri,
        .code_verifier = verifier,
    }, .{});
}

/// Trade a refresh token for a fresh access token. Caller frees the result.
pub fn refresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    refresh_token: []const u8,
) !Tokens {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = refresh_token,
    }, .{});
    defer gpa.free(body);
    return post(gpa, io, timeouts, body);
}

/// The token request bounded by the connect timeout: the whole connect, send,
/// receive-head, and body read must finish within it, or it is cancelled and
/// reaped as `error.Timeout`.
fn post(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts, body: []const u8) !Tokens {
    var out: ?Tokens = null;
    return awaitTokens(gpa, io, timeouts.connect_ms, &out, fetchInto, .{ gpa, io, body, &out });
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

fn fetchInto(gpa: std.mem.Allocator, io: std.Io, body: []const u8, out: *?Tokens) !void {
    const uri = try std.Uri.parse(token_url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var request = try client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
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
    out.* = try parseTokens(gpa, io, payload);
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

fn parseTokens(gpa: std.mem.Allocator, io: std.Io, body: []const u8) !Tokens {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadTokenResponse,
    };
    const access = jsonString(object, "access_token") orelse return error.MissingAccessToken;
    const refresh_token = jsonString(object, "refresh_token") orelse return error.MissingRefreshToken;
    const expires_in = jsonInt(object, "expires_in") orelse return error.MissingExpiry;
    // A crafted expiry must fail cleanly, not overflow and crash.
    const expires_scaled = std.math.mul(i64, expires_in, 1000) catch return error.MissingExpiry;

    const access_owned = try gpa.dupe(u8, access);
    errdefer gpa.free(access_owned);
    const refresh_owned = try gpa.dupe(u8, refresh_token);

    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return .{
        .access = access_owned,
        .refresh = refresh_owned,
        .expires_ms = now_ms +| expires_scaled -| refresh_margin_ms,
    };
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInt(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
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
}

test exchangeBody {
    const body = try exchangeBody(std.testing.allocator, "c\"ode", "st\\ate", "verifier");
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("c\"ode", parsed.value.object.get("code").?.string);
    try std.testing.expectEqualStrings("st\\ate", parsed.value.object.get("state").?.string);
}

test parseTokens {
    const body =
        \\{"access_token":"sk-ant-oat-x","refresh_token":"sk-ant-ort-y","expires_in":3600}
    ;
    const tokens = try parseTokens(std.testing.allocator, std.testing.io, body);
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sk-ant-oat-x", tokens.access);
    try std.testing.expectEqualStrings("sk-ant-ort-y", tokens.refresh);
}

test "parseTokens rejects an expiry that would overflow" {
    const body =
        \\{"access_token":"a","refresh_token":"r","expires_in":9223372036854775807}
    ;
    try std.testing.expectError(
        error.MissingExpiry,
        parseTokens(std.testing.allocator, std.testing.io, body),
    );
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
        \\{"access_token":"sk-ant-oat-x","refresh_token":"sk-ant-ort-y","expires_in":3600}
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
