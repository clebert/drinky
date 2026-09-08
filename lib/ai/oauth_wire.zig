//! OAuth wire plumbing shared by the provider flows: verifier/challenge
//! generation, form bodies, and bounded POST requests with decompression. This
//! module reads the standard OAuth error code. Each provider parses its
//! successful payload.

const std = @import("std");

const net = @import("net.zig");

/// The hard cap on a token response body, well above any real exchange or
/// refresh payload.
const token_response_bytes_max = 256 * 1024;

const verifier_len = std.base64.url_safe_no_pad.Encoder.calcSize(32);

pub const form_content_type = "application/x-www-form-urlencoded";

pub const Pkce = struct {
    verifier: [verifier_len]u8,
    challenge: [verifier_len]u8,
};

pub const BearerOptions = struct {
    url: []const u8,
    authorization: []const u8,
};

/// One field of a form body.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

/// A fresh PKCE verifier/challenge pair drawn from the Io's CSPRNG.
pub fn pkce(io: std.Io) Pkce {
    var seed: [32]u8 = undefined;
    io.random(&seed);
    var result: Pkce = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&result.verifier, &seed);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&result.verifier, &digest, .{});
    _ = std.base64.url_safe_no_pad.Encoder.encode(&result.challenge, &digest);
    return result;
}

/// The form-urlencoded body of `fields`. Every byte outside the unreserved set
/// percent-encodes, so a server value that holds a delimiter cannot split a
/// field. The caller frees the result.
pub fn formBody(gpa: std.mem.Allocator, fields: []const Field) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (fields, 0..) |field, index| {
        if (index != 0) out.writer.writeByte('&') catch return error.OutOfMemory;
        std.Uri.Component.percentEncode(&out.writer, field.name, isUnreserved) catch
            return error.OutOfMemory;
        out.writer.writeByte('=') catch return error.OutOfMemory;
        std.Uri.Component.percentEncode(&out.writer, field.value, isUnreserved) catch
            return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// The unreserved set of RFC 3986, which every form-urlencoded decoder passes
/// through unchanged.
fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

/// POST `body` to an OAuth endpoint and return its owned success body. The
/// caller frees it. An `invalid_grant` error becomes `TokenGrantRejected`. The
/// connect timeout bounds the complete request and body read.
pub fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
) ![]u8 {
    const fetch: Fetch = .{
        .url = url,
        .content_type = content_type,
        .body = body,
        .error_body = .oauth,
    };
    return send(gpa, io, timeouts, &fetch);
}

/// POST the form `body` of a device-code grant (RFC 8628) and return the owned
/// success body. The caller frees it. The poll answers of the grant read as
/// errors of their own: `AuthorizationPending`, `SlowDown`,
/// `AuthorizationDenied`, and `DeviceCodeExpired`.
pub fn postDevice(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    url: []const u8,
    body: []const u8,
) ![]u8 {
    const fetch: Fetch = .{
        .url = url,
        .content_type = form_content_type,
        .body = body,
        .error_body = .device,
    };
    return send(gpa, io, timeouts, &fetch);
}

/// POST an empty body under a `Bearer` authorization and return the owned
/// success body. The caller frees it. This endpoint has no OAuth error body.
pub fn postBearer(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    options: *const BearerOptions,
) ![]u8 {
    if (!net.validHeaderValue(options.authorization)) return error.BadCredentials;
    const fetch: Fetch = .{ .url = options.url, .authorization = options.authorization };
    return send(gpa, io, timeouts, &fetch);
}

/// One POST: its target and the optional content-type, body, and authorization
/// each path installs.
const Fetch = struct {
    url: []const u8,
    content_type: ?[]const u8 = null,
    body: []const u8 = "",
    authorization: ?[]const u8 = null,
    error_body: ErrorBody = .generic,

    /// What an error body of the endpoint states: nothing Drinky reads, the
    /// standard OAuth code of a token exchange, or that code plus the poll
    /// answers of a device-code grant.
    const ErrorBody = enum { generic, oauth, device };
};

/// The standard OAuth error codes Drinky acts on. Every other code is a plain
/// failure.
const Code = enum {
    invalid_grant,
    authorization_pending,
    slow_down,
    access_denied,
    authorization_denied,
    expired_token,
};

fn send(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts, fetch: *const Fetch) ![]u8 {
    var out: ?[]u8 = null;
    return awaitBody(
        gpa,
        io,
        timeouts.connect_ms,
        &out,
        fetchInto,
        .{ gpa, io, fetch, &out },
    ) catch |err| return tokenTransportError(err);
}

/// Keep an ambiguous endpoint failure out of the whole-request retry. A failure
/// before the connection opens stays retryable because no request byte was sent.
fn tokenTransportError(err: anyerror) anyerror {
    return switch (err) {
        error.Timeout,
        error.ReadFailed,
        error.WriteFailed,
        error.EndOfStream,
        error.ConnectionResetByPeer,
        error.TlsConnectionTruncated,
        => error.TokenServiceUnavailable,
        else => err,
    };
}

/// Run `work` (which writes its result into `out`) bounded by `timeout_ms`. The
/// timeout races the request, so one that finished right at the deadline can
/// still surface as an error with its result discarded. Reclaim anything left
/// in `out` on any error so a completed-at-the-deadline request cannot leak.
fn awaitBody(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeout_ms: u64,
    out: *?[]u8,
    comptime work: anytype,
    args: std.meta.ArgsTuple(@TypeOf(work)),
) ![]u8 {
    net.withTimeout(io, timeout_ms, work, args) catch |err| {
        if (out.*) |payload| gpa.free(payload);
        return err;
    };
    return out.* orelse error.TokenRequestFailed;
}

fn fetchInto(gpa: std.mem.Allocator, io: std.Io, fetch: *const Fetch, out: *?[]u8) !void {
    const uri = try std.Uri.parse(fetch.url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var request = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = if (fetch.content_type) |content_type|
                .{ .override = content_type }
            else
                .default,
            .authorization = if (fetch.authorization) |authorization|
                .{ .override = authorization }
            else
                .default,
        },
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = fetch.body.len };
    var send_body = try request.sendBodyUnflushed(&.{});
    try send_body.writer.writeAll(fetch.body);
    try send_body.end();
    try request.connection.?.flush();

    var redirect_buffer: [2048]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    const decompress_buffer = try net.decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    const body = try readBody(gpa, reader);
    errdefer gpa.free(body);
    try checkResponse(gpa, response.head.status, body, fetch.error_body);
    out.* = body;
}

/// The response body: a body over `token_response_bytes_max` fails with
/// `error.TokenResponseTooLarge` and does not allocate without bound.
fn readBody(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return reader.allocRemaining(gpa, .limited(token_response_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => error.TokenResponseTooLarge,
        else => err,
    };
}

/// Classify a response after its capped body is available. Only an OAuth
/// `invalid_grant` under 400, 401, or 403 proves that the submitted grant is no
/// longer valid. A device-code poll states its wait and its refusal in the same
/// code field, and its code reads under every client error status, because a
/// rate limiter can answer a `slow_down` with 429.
fn checkResponse(
    gpa: std.mem.Allocator,
    status: std.http.Status,
    body: []const u8,
    error_body: Fetch.ErrorBody,
) !void {
    if (status == .ok) return;
    const readable = switch (error_body) {
        .generic => false,
        .oauth => status == .bad_request or status == .unauthorized or status == .forbidden,
        .device => status.class() == .client_error,
    };
    const maybe_code = if (readable) try errorCode(gpa, body) else null;
    if (maybe_code) |code| {
        const device = error_body == .device;
        switch (code) {
            .invalid_grant => return error.TokenGrantRejected,
            .authorization_pending => if (device) return error.AuthorizationPending,
            .slow_down => if (device) return error.SlowDown,
            .access_denied, .authorization_denied => if (device) return error.AuthorizationDenied,
            .expired_token => if (device) return error.DeviceCodeExpired,
        }
    }
    if (status == .too_many_requests or status.class() == .server_error)
        return error.TokenServiceUnavailable;
    return error.TokenRequestFailed;
}

/// The standard OAuth error code of `body`, or null for a code Drinky does not
/// act on. A malformed body has no destructive meaning.
fn errorCode(gpa: std.mem.Allocator, body: []const u8) !?Code {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const code = switch (object.get("error") orelse return null) {
        .string => |code| code,
        else => return null,
    };
    return std.meta.stringToEnum(Code, code);
}

test "an OAuth response reads its error before it classifies the status" {
    const gpa = std.testing.allocator;
    try checkResponse(gpa, .ok, "", .oauth);
    try std.testing.expectError(
        error.TokenGrantRejected,
        checkResponse(gpa, .bad_request, "{\"error\":\"invalid_grant\"}", .oauth),
    );
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .bad_request, "{\"error\":\"invalid_request\"}", .oauth),
    );
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .bad_request, "{\"error\":\"unsupported_grant_type\"}", .oauth),
    );
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .unauthorized, "{\"error\":\"invalid_client\"}", .oauth),
    );
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .forbidden, "not json", .oauth),
    );
    try std.testing.expectError(
        error.TokenServiceUnavailable,
        checkResponse(gpa, .too_many_requests, "", .oauth),
    );
    try std.testing.expectError(
        error.TokenServiceUnavailable,
        checkResponse(gpa, .service_unavailable, "", .oauth),
    );
}

// A device-code poll answers its wait and its refusal in the OAuth code field,
// so the same status reads differently under each body kind.
test "a device response reads the poll answers of its grant" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.AuthorizationPending,
        checkResponse(gpa, .bad_request, "{\"error\":\"authorization_pending\"}", .device),
    );
    try std.testing.expectError(
        error.SlowDown,
        checkResponse(gpa, .bad_request, "{\"error\":\"slow_down\"}", .device),
    );
    try std.testing.expectError(
        error.AuthorizationDenied,
        checkResponse(gpa, .bad_request, "{\"error\":\"access_denied\"}", .device),
    );
    try std.testing.expectError(
        error.AuthorizationDenied,
        checkResponse(gpa, .forbidden, "{\"error\":\"authorization_denied\"}", .device),
    );
    try std.testing.expectError(
        error.DeviceCodeExpired,
        checkResponse(gpa, .bad_request, "{\"error\":\"expired_token\"}", .device),
    );
    // A rate limiter can answer the wait with 429, and a 429 without a code is
    // still an unavailable service. A token exchange reads no code under 429,
    // so a rejected grant there stays an unavailable service, as before.
    try std.testing.expectError(
        error.SlowDown,
        checkResponse(gpa, .too_many_requests, "{\"error\":\"slow_down\"}", .device),
    );
    try std.testing.expectError(
        error.TokenServiceUnavailable,
        checkResponse(gpa, .too_many_requests, "{\"error\":\"rate_limited\"}", .device),
    );
    try std.testing.expectError(
        error.TokenServiceUnavailable,
        checkResponse(gpa, .too_many_requests, "{\"error\":\"invalid_grant\"}", .oauth),
    );
    try std.testing.expectError(
        error.TokenGrantRejected,
        checkResponse(gpa, .bad_request, "{\"error\":\"invalid_grant\"}", .device),
    );
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .bad_request, "{\"error\":\"invalid_client\"}", .device),
    );
    // A token exchange never polls, so the poll answers read as plain failures there.
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .bad_request, "{\"error\":\"authorization_pending\"}", .oauth),
    );
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .bad_request, "{\"error\":\"slow_down\"}", .generic),
    );
}

test formBody {
    const gpa = std.testing.allocator;
    const body = try formBody(gpa, &.{
        .{ .name = "grant_type", .value = "urn:ietf:params:oauth:grant-type:device_code" },
        .{ .name = "scope", .value = "openid api:access" },
        .{ .name = "device_code", .value = "a-b_c.d~e&f=g%h" },
    });
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code" ++
            "&scope=openid%20api%3Aaccess&device_code=a-b_c.d~e%26f%3Dg%25h",
        body,
    );
    const empty = try formBody(gpa, &.{});
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "a bearer response does not classify an OAuth grant" {
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(
            std.testing.allocator,
            .bad_request,
            "{\"error\":\"invalid_grant\"}",
            .generic,
        ),
    );
}

test "ambiguous endpoint failures become token service failures" {
    try std.testing.expectEqual(
        error.TokenServiceUnavailable,
        tokenTransportError(error.Timeout),
    );
    try std.testing.expectEqual(
        error.TokenServiceUnavailable,
        tokenTransportError(error.ConnectionResetByPeer),
    );
    for ([_]anyerror{
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.Canceled,
        error.OutOfMemory,
    }) |err| try std.testing.expectEqual(err, tokenTransportError(err));
}

test pkce {
    const code = pkce(std.testing.io);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&code.verifier, &digest, .{});
    var expected: [verifier_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&expected, &digest);
    try std.testing.expectEqualStrings(&expected, &code.challenge);
}

test "postBearer rejects an authorization value that can split the request head" {
    try std.testing.expectError(
        error.BadCredentials,
        postBearer(std.testing.allocator, undefined, .{}, &.{
            .url = "https://example.test/mint",
            .authorization = "Bearer token\r\nleaked: value",
        }),
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
        \\{"access_token":"at","refresh_token":"rt"}
    ;
    var buffer: [64]u8 = undefined;
    var reader = std.testing.Reader.init(&buffer, &.{.{ .buffer = body }});
    const read = try readBody(gpa, &reader.interface);
    defer gpa.free(read);
    try std.testing.expectEqualStrings(body, read);
}

fn produceThenFail(gpa: std.mem.Allocator, out: *?[]u8) anyerror!void {
    out.* = try gpa.dupe(u8, "payload");
    return error.Canceled;
}

test "a token request that fails after producing a result frees it" {
    const gpa = std.testing.allocator;
    var out: ?[]u8 = null;
    // The leak-detecting allocator proves the discarded result was freed.
    try std.testing.expectError(
        error.Canceled,
        awaitBody(gpa, std.testing.io, 1000, &out, produceThenFail, .{ gpa, &out }),
    );
}
