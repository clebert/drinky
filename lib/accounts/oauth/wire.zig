const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const token_response_bytes_max = 256 * 1024;
const refresh_margin_ms = 5 * std.time.ms_per_min;
const lifetime_ms_default = std.time.ms_per_hour;

const seed_len = 32;
const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(seed_len);

pub const form_content_type = "application/x-www-form-urlencoded";

pub const Error = providers.Transport.Error || error{
    OutOfMemory,
    TokenServiceUnavailable,
    TokenResponseTooLarge,
    TokenGrantRejected,
    TokenRequestFailed,
    AuthorizationPending,
    SlowDown,
    AuthorizationDenied,
    DeviceCodeExpired,
    BadTokenResponse,
    MissingAccessToken,
    MissingRefreshToken,
    MissingExpiry,
    MissingAccountId,
    MissingApiKey,
    BadDeviceResponse,
    BadCredentials,
};

pub const Pkce = struct {
    verifier: [encoded_len]u8,
    challenge: [encoded_len]u8,
    state: [encoded_len]u8,
};

const Reply = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,

    pub fn deinit(self: *const Reply, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
    }
};

pub const ReplyOptions = struct {
    body: []const u8,
    now_ms: i64,
    refresh_kept: []const u8 = "",
};

const Lifetime = struct {
    now_ms: i64,
    lifetime_ms: i64,
};

pub const Link = struct {
    transport: ?providers.Transport = null,
    timeouts: providers.Transport.Timeouts = .{},
};

const BearerOptions = struct {
    url: []const u8,
    authorization: []const u8,
};

const Field = struct {
    name: []const u8,
    value: []const u8,
};

const FetchError = Error || std.Io.Reader.ShortError;

const TimedError = FetchError || error{ Timeout, Canceled, ConcurrencyUnavailable };

const Fetch = struct {
    url: []const u8,
    content_type: ?[]const u8 = null,
    body: []const u8 = "",
    authorization: ?[]const u8 = null,
    error_body: ErrorBody = .generic,

    const ErrorBody = enum { generic, oauth, device };
};

const Code = enum {
    invalid_grant,
    authorization_pending,
    slow_down,
    access_denied,
    authorization_denied,
    expired_token,
};

const PostOptions = struct {
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const DeviceOptions = struct {
    url: []const u8,
    body: []const u8,
};

pub fn pkce(io: std.Io) Pkce {
    var result: Pkce = undefined;
    randomToken(io, &result.verifier);
    randomToken(io, &result.state);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&result.verifier, &digest, .{});
    _ = std.base64.url_safe_no_pad.Encoder.encode(&result.challenge, &digest);
    return result;
}

fn randomToken(io: std.Io, out: *[encoded_len]u8) void {
    var seed: [seed_len]u8 = undefined;
    io.random(&seed);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &seed);
}

pub fn parseJson(
    gpa: std.mem.Allocator,
    body: []const u8,
) error{ OutOfMemory, BadTokenResponse }!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadTokenResponse,
    };
}

pub fn parseReply(gpa: std.mem.Allocator, options: *const ReplyOptions) Error!Reply {
    const parsed = try parseJson(gpa, options.body);
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return error.BadTokenResponse;
    const access = providers.json.string(object.getPtr("access_token")) orelse
        return error.MissingAccessToken;
    const refresh = providers.json.string(object.getPtr("refresh_token")) orelse
        options.refresh_kept;
    if (refresh.len == 0) return error.MissingRefreshToken;
    const maybe_expires_in = providers.json.integer(object.getPtr("expires_in"));
    const lifetime_ms = if (maybe_expires_in) |expires_in| lifetime: {
        if (expires_in <= 0) return error.MissingExpiry;
        break :lifetime std.math.mul(i64, expires_in, std.time.ms_per_s) catch
            return error.MissingExpiry;
    } else lifetime_ms_default;
    const expires_ms = expiresAt(&.{ .now_ms = options.now_ms, .lifetime_ms = lifetime_ms }) orelse
        return error.MissingExpiry;

    const access_owned = try gpa.dupe(u8, access);
    errdefer gpa.free(access_owned);
    return .{
        .access = access_owned,
        .refresh = try gpa.dupe(u8, refresh),
        .expires_ms = expires_ms,
    };
}

pub fn expiresAt(lifetime: *const Lifetime) ?i64 {
    const margin_ms = @min(refresh_margin_ms, @divFloor(lifetime.lifetime_ms, 2));
    return std.math.add(i64, lifetime.now_ms, lifetime.lifetime_ms - margin_ms) catch null;
}

pub fn formBody(gpa: std.mem.Allocator, fields: []const Field) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (fields, 0..) |field, index| {
        if (index != 0) out.writer.writeByte('&') catch return error.OutOfMemory;
        percentEncode(&out.writer, field.name) catch return error.OutOfMemory;
        out.writer.writeByte('=') catch return error.OutOfMemory;
        percentEncode(&out.writer, field.value) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

pub fn percentEncode(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    return std.Uri.Component.percentEncode(writer, value, isUnreserved);
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.findScalar(u8, "-._~", byte) != null;
}

pub fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const Link,
    options: *const PostOptions,
) Error![]u8 {
    const fetch: Fetch = .{
        .url = options.url,
        .content_type = options.content_type,
        .body = options.body,
        .error_body = .oauth,
    };
    return send(gpa, io, link, &fetch);
}

pub fn postDevice(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const Link,
    options: *const DeviceOptions,
) Error![]u8 {
    const fetch: Fetch = .{
        .url = options.url,
        .content_type = form_content_type,
        .body = options.body,
        .error_body = .device,
    };
    return send(gpa, io, link, &fetch);
}

pub fn postBearer(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const Link,
    options: *const BearerOptions,
) Error![]u8 {
    if (!providers.Transport.validHeaderValue(options.authorization)) return error.BadCredentials;
    const fetch: Fetch = .{ .url = options.url, .authorization = options.authorization };
    return send(gpa, io, link, &fetch);
}

fn send(gpa: std.mem.Allocator, io: std.Io, link: *const Link, fetch: *const Fetch) Error![]u8 {
    return core.timeout.run(
        io,
        link.timeouts.connect_ms,
        fetchBody,
        .{ gpa, io, link.transport, fetch },
        releaseBody,
    ) catch |err| return tokenTransportError(err);
}

fn tokenTransportError(err: TimedError) Error {
    return switch (err) {
        error.Timeout,
        error.ReadFailed,
        error.WriteFailed,
        error.ConnectionResetByPeer,
        => error.TokenServiceUnavailable,
        else => |other| other,
    };
}

fn fetchBody(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    fetch: *const Fetch,
) FetchError![]u8 {
    const response = providers.Http.fetch(gpa, io, transport, &.{
        .url = fetch.url,
        .content_type = fetch.content_type,
        .authorization = fetch.authorization,
        .body = fetch.body,
    }, token_response_bytes_max) catch |err| return switch (err) {
        error.StreamTooLong => error.TokenResponseTooLarge,
        else => |other| other,
    };
    errdefer gpa.free(response.body);
    try checkResponse(gpa, response.status, response.body, fetch.error_body);
    return response.body;
}

fn releaseBody(body: *const []u8, args: *const std.meta.ArgsTuple(@TypeOf(fetchBody))) void {
    args[0].free(body.*);
}

fn checkResponse(
    gpa: std.mem.Allocator,
    status: std.http.Status,
    body: []const u8,
    error_body: Fetch.ErrorBody,
) Error!void {
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

fn errorCode(gpa: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?Code {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const object = (try providers.json.parseObject(arena.allocator(), body)) orelse return null;
    const code = providers.json.string(object.getPtr("error")) orelse return null;
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
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .bad_request, "{\"error\":\"authorization_pending\"}", .oauth),
    );
    try std.testing.expectError(
        error.TokenRequestFailed,
        checkResponse(gpa, .bad_request, "{\"error\":\"slow_down\"}", .generic),
    );
}

const test_now_ms = 1_700_000_000_000;

test "a token reply keeps the refresh token it replaces and expires before its lifetime" {
    const gpa = std.testing.allocator;
    const full = try parseReply(gpa, &.{
        .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":3600," ++
            "\"id_token\":\"ignored\"}",
        .now_ms = test_now_ms,
    });
    defer full.deinit(gpa);
    try std.testing.expectEqualStrings("at", full.access);
    try std.testing.expectEqualStrings("rt", full.refresh);
    try std.testing.expectEqual(test_now_ms + 3_600_000 - refresh_margin_ms, full.expires_ms);

    const partial = try parseReply(gpa, &.{
        .body = "{\"access_token\":\"at2\"}",
        .now_ms = test_now_ms,
        .refresh_kept = "kept",
    });
    defer partial.deinit(gpa);
    try std.testing.expectEqualStrings("kept", partial.refresh);
    try std.testing.expectEqual(
        test_now_ms + lifetime_ms_default - refresh_margin_ms,
        partial.expires_ms,
    );
}

test "a short token keeps half its lifetime before it counts as expired" {
    const gpa = std.testing.allocator;
    const short = try parseReply(gpa, &.{
        .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":60}",
        .now_ms = test_now_ms,
    });
    defer short.deinit(gpa);
    try std.testing.expectEqual(test_now_ms + 30_000, short.expires_ms);
}

test "a token reply without a credential or a usable lifetime fails" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { body: []const u8, err: Error }{
        .{ .body = "{\"refresh_token\":\"rt\"}", .err = error.MissingAccessToken },
        .{ .body = "{\"access_token\":\"at\"}", .err = error.MissingRefreshToken },
        .{
            .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":0}",
            .err = error.MissingExpiry,
        },
        .{
            .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\"," ++
                "\"expires_in\":9223372036854775807}",
            .err = error.MissingExpiry,
        },
        .{ .body = "[]", .err = error.BadTokenResponse },
    };
    for (cases) |case| try std.testing.expectError(
        case.err,
        parseReply(gpa, &.{ .body = case.body, .now_ms = test_now_ms }),
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
    for ([_]TimedError{
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.NameServerFailure,
        error.Canceled,
        error.OutOfMemory,
    }) |err| try std.testing.expectEqual(err, tokenTransportError(err));
}

test "the challenge hashes the verifier, and the state is a second secret" {
    const code = pkce(std.testing.io);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&code.verifier, &digest, .{});
    var expected: [encoded_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&expected, &digest);
    try std.testing.expectEqualStrings(&expected, &code.challenge);
    try std.testing.expect(!std.mem.eql(u8, &code.verifier, &code.state));
}

test "postBearer rejects an authorization value that can split the request head" {
    try std.testing.expectError(
        error.BadCredentials,
        postBearer(std.testing.allocator, undefined, &.{}, &.{
            .url = "https://example.test/mint",
            .authorization = "Bearer token\r\nleaked: value",
        }),
    );
}

test "a token response over the cap fails, and a smaller one returns its body" {
    const gpa = std.testing.allocator;
    const oversized = try gpa.alloc(u8, token_response_bytes_max + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    const body =
        \\{"access_token":"at","refresh_token":"rt"}
    ;
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = oversized },
        .{ .body = body },
    };
    var transport: providers.testing.FakeTransport = .{ .gpa = gpa, .replies = &replies };
    defer transport.deinit();
    const link: Link = .{ .transport = transport.transport() };
    const url = "https://example.invalid/token";

    try std.testing.expectError(
        error.TokenResponseTooLarge,
        post(gpa, std.testing.io, &link, &.{
            .url = url,
            .content_type = "application/json",
            .body = "{}",
        }),
    );
    const read = try post(gpa, std.testing.io, &link, &.{
        .url = url,
        .content_type = form_content_type,
        .body = "a=b",
    });
    defer gpa.free(read);
    try std.testing.expectEqualStrings(body, read);
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.requests.items[1],
        "POST https://example.invalid/token\ncontent-type: " ++ form_content_type ++ "\n",
    ));
}
