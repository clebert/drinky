//! OAuth wire plumbing shared by the provider PKCE flows: verifier/challenge
//! generation and bounded POST requests with decompression. This module reads
//! the standard OAuth error code. Each provider parses its successful payload.

const std = @import("std");

const net = @import("net.zig");

/// The hard cap on a token response body, well above any real exchange or
/// refresh payload.
const token_response_bytes_max = 256 * 1024;

const verifier_len = std.base64.url_safe_no_pad.Encoder.calcSize(32);

pub const Pkce = struct {
    verifier: [verifier_len]u8,
    challenge: [verifier_len]u8,
};

pub const BearerOptions = struct {
    url: []const u8,
    authorization: []const u8,
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

    const ErrorBody = enum { generic, oauth };
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
/// `invalid_grant` proves that the submitted grant is no longer valid.
fn checkResponse(
    gpa: std.mem.Allocator,
    status: std.http.Status,
    body: []const u8,
    error_body: Fetch.ErrorBody,
) !void {
    if (status == .ok) return;
    switch (status) {
        .bad_request, .unauthorized, .forbidden => {
            if (error_body == .oauth and try isInvalidGrant(gpa, body))
                return error.TokenGrantRejected;
        },
        else => {},
    }
    if (status == .too_many_requests or status.class() == .server_error)
        return error.TokenServiceUnavailable;
    return error.TokenRequestFailed;
}

/// Test the standard OAuth error code. A malformed body has no destructive meaning.
fn isInvalidGrant(gpa: std.mem.Allocator, body: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => false,
        };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const code = switch (object.get("error") orelse return false) {
        .string => |code| code,
        else => return false,
    };
    return std.mem.eql(u8, code, "invalid_grant");
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
