//! OAuth wire plumbing shared by the provider PKCE flows: verifier/challenge
//! generation and the connect-timeout-bounded token POST with its response cap
//! and decompression. Token parsing stays with each provider — the shapes
//! differ — so `post` returns the raw, size-capped body.

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

/// POST `body` to `url` and return the owned response body. The caller frees
/// it. The request is bounded by the connect timeout: the whole connect, send,
/// receive-head, and body read must finish within it, or it is cancelled and
/// reaped as `error.Timeout`.
pub fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
) ![]u8 {
    var out: ?[]u8 = null;
    return awaitBody(gpa, io, timeouts.connect_ms, &out, fetchInto, .{
        gpa, io, url, content_type, body, &out,
    });
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

fn fetchInto(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
    out: *?[]u8,
) !void {
    const uri = try std.Uri.parse(url);
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

    const decompress_buffer = try net.decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    out.* = try readBody(gpa, reader);
}

/// The response body: a body over `token_response_bytes_max` fails with
/// `error.TokenResponseTooLarge` and does not allocate without bound.
fn readBody(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return reader.allocRemaining(gpa, .limited(token_response_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => error.TokenResponseTooLarge,
        else => err,
    };
}

test pkce {
    const code = pkce(std.testing.io);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&code.verifier, &digest, .{});
    var expected: [verifier_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&expected, &digest);
    try std.testing.expectEqualStrings(&expected, &code.challenge);
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
