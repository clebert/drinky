//! The credential of the Google Vertex account. `init` reads a service account
//! key file once and parses its RSA key. `accessToken` mints a short-lived
//! access token from a signed JWT on demand and caches it. Nothing persists:
//! the key file is the credential, so the account has no login and no logout.

const std = @import("std");

const json = @import("../json.zig");
const net = @import("../net.zig");
const oauth_wire = @import("../oauth_wire.zig");
const rs256 = @import("rs256.zig");
const Transport = @import("Transport.zig");

const Auth = @This();

/// The cap on the key file. A real key file holds about 2.5 KiB.
const key_file_bytes_max = 64 * 1024;
const token_uri_default = "https://oauth2.googleapis.com/token";
const scope = "https://www.googleapis.com/auth/cloud-platform";
const token_lifetime_s = 3600;
/// A cached token with less time left than this mints again.
const renew_margin_ms = 5 * std.time.ms_per_min;
const grant_type = "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer";

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
project: []const u8,
location: Transport.Location,
email: []const u8,
token_uri: []const u8,
key: rs256.PrivateKey,
token: ?Token,

pub const Options = struct {
    key_path: []const u8,
    /// The name of a `Transport.Location`, as the environment states it.
    location: []const u8,
};

const Token = struct {
    access: []const u8,
    /// The epoch milliseconds at which the token expires.
    expires_ms: i64,

    fn deinit(self: Token, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
    }
};

/// Read the key file and parse its key. No network request runs here. The
/// location is checked first, so a bad one reports as such whatever the file.
pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    options: *const Options,
) !Auth {
    const location = std.meta.stringToEnum(Transport.Location, options.location) orelse
        return error.BadLocation;
    const file = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.key_path,
        gpa,
        .limited(key_file_bytes_max),
    );
    defer gpa.free(file);
    return fromKeyFile(gpa, io, timeouts, file, location);
}

/// The account that `file` describes. The key bytes live in `file` and in the
/// unescaped `private_key` string of the parse, and this call zeros both.
fn fromKeyFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    file: []u8,
    location: Transport.Location,
) !Auth {
    defer std.crypto.secureZero(u8, file);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, file, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadCredentials,
        };
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadCredentials;

    if (!std.mem.eql(u8, try requiredString(object, "type"), "service_account"))
        return error.BadCredentials;
    const project = try requiredString(object, "project_id");
    if (!validProject(project)) return error.BadCredentials;
    const email = try requiredString(object, "client_email");
    const private_key = try requiredString(object, "private_key");
    // The arena owns this unescaped copy, so the cast to mutable is sound.
    defer std.crypto.secureZero(u8, @constCast(private_key));
    const token_uri = if (object.get("token_uri") == null)
        token_uri_default
    else
        try requiredString(object, "token_uri");

    const key = try rs256.parsePem(gpa, private_key);
    errdefer key.deinit(gpa);
    const project_copy = try gpa.dupe(u8, project);
    errdefer gpa.free(project_copy);
    const email_copy = try gpa.dupe(u8, email);
    errdefer gpa.free(email_copy);
    const token_uri_copy = try gpa.dupe(u8, token_uri);
    return .{
        .gpa = gpa,
        .io = io,
        .timeouts = timeouts,
        .project = project_copy,
        .location = location,
        .email = email_copy,
        .token_uri = token_uri_copy,
        .key = key,
        .token = null,
    };
}

pub fn deinit(self: *Auth) void {
    if (self.token) |token| token.deinit(self.gpa);
    self.key.deinit(self.gpa);
    self.gpa.free(self.project);
    self.gpa.free(self.email);
    self.gpa.free(self.token_uri);
}

/// A valid access token. The cached one serves while more than the renew margin
/// remains. Otherwise this mints a new one.
pub fn accessToken(self: *Auth) ![]const u8 {
    return self.accessTokenWith(mint);
}

fn accessTokenWith(self: *Auth, comptime mintFn: anytype) ![]const u8 {
    if (self.token) |token| {
        if (token.expires_ms - self.nowMs() > renew_margin_ms) return token.access;
    }
    _ = try self.renewWith(mintFn);
    return self.token.?.access;
}

/// Mint a new token after the provider rejected the cached one, and report
/// whether the bytes changed. A caller repeats a request only on a true result.
pub fn renew(self: *Auth) !bool {
    return self.renewWith(mint);
}

fn renewWith(self: *Auth, comptime mintFn: anytype) !bool {
    const fresh: Token = try mintFn(self);
    const changed = if (self.token) |old| !std.mem.eql(u8, old.access, fresh.access) else true;
    if (self.token) |old| old.deinit(self.gpa);
    self.token = fresh;
    return changed;
}

fn nowMs(self: *const Auth) i64 {
    return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
}

/// POST the signed JWT to the token endpoint and decode the token it returns.
/// A rejected grant is a rejected key. The agent maps `TokenGrantRejected` to
/// a disposition that the app refuses for this account, so the name changes here.
fn mint(self: *Auth) !Token {
    const now_ms = self.nowMs();
    const assertion = try self.jwt(@divFloor(now_ms, std.time.ms_per_s));
    defer self.gpa.free(assertion);
    const body = try std.fmt.allocPrint(
        self.gpa,
        "grant_type=" ++ grant_type ++ "&assertion={s}",
        .{assertion},
    );
    defer self.gpa.free(body);
    const response = oauth_wire.post(
        self.gpa,
        self.io,
        self.timeouts,
        self.token_uri,
        "application/x-www-form-urlencoded",
        body,
    ) catch |err| return switch (err) {
        error.TokenGrantRejected => error.KeyRejected,
        else => err,
    };
    defer self.gpa.free(response);
    return parseToken(self.gpa, response, now_ms);
}

/// The signed JWT bearer assertion issued at `now_s`. The caller frees it.
fn jwt(self: *const Auth, now_s: i64) ![]u8 {
    const gpa = self.gpa;
    const claims = try std.json.Stringify.valueAlloc(gpa, .{
        .iss = self.email,
        .scope = scope,
        .aud = self.token_uri,
        .iat = now_s,
        .exp = now_s + token_lifetime_s,
    }, .{});
    defer gpa.free(claims);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendSegment(&out, gpa, "{\"alg\":\"RS256\",\"typ\":\"JWT\"}");
    try out.append(gpa, '.');
    try appendSegment(&out, gpa, claims);

    const signature = try gpa.alloc(u8, self.key.signatureLength());
    defer gpa.free(signature);
    try rs256.sign(&self.key, out.items, signature);
    try out.append(gpa, '.');
    try appendSegment(&out, gpa, signature);
    return out.toOwnedSlice(gpa);
}

fn appendSegment(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const target = try out.addManyAsSlice(gpa, encoder.calcSize(bytes.len));
    _ = encoder.encode(target, bytes);
}

fn parseToken(gpa: std.mem.Allocator, body: []const u8, now_ms: i64) !Token {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadTokenResponse,
        };
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadTokenResponse;
    const access = json.string(object.get("access_token")) orelse return error.BadTokenResponse;
    const expires_in = json.integer(object.get("expires_in")) orelse return error.BadTokenResponse;
    if (access.len == 0 or expires_in <= 0) return error.BadTokenResponse;
    return .{
        .access = try gpa.dupe(u8, access),
        .expires_ms = now_ms +| expires_in *| std.time.ms_per_s,
    };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return json.string(object.get(name)) orelse error.BadCredentials;
}

/// The project enters the request path. A domain-scoped id carries `.` and `:`.
fn validProject(project: []const u8) bool {
    if (project.len == 0) return false;
    for (project) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and
            std.mem.indexOfScalar(u8, "-.:", byte) == null) return false;
    }
    return true;
}

/// A key file body with the fixture key and the given fields. The caller frees it.
fn testKeyFile(gpa: std.mem.Allocator, fields: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, fields, .{});
}

const test_fields = .{
    .type = "service_account",
    .project_id = "my-project",
    .private_key_id = "ignored",
    .private_key = rs256.fixture_pem,
    .client_email = "robot@my-project.iam.gserviceaccount.com",
    .universe_domain = "googleapis.com",
};

fn testAuth(gpa: std.mem.Allocator, io: std.Io) !Auth {
    const file = try testKeyFile(gpa, test_fields);
    defer gpa.free(file);
    return fromKeyFile(gpa, io, .{}, file, .eu);
}

test "fromKeyFile reads the named fields, defaults the token URI, and zeros the key" {
    const gpa = std.testing.allocator;
    const file = try testKeyFile(gpa, test_fields);
    defer gpa.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "BEGIN PRIVATE KEY") != null);

    var auth = try fromKeyFile(gpa, std.testing.io, .{}, file, .global);
    defer auth.deinit();
    try std.testing.expectEqualStrings("my-project", auth.project);
    try std.testing.expectEqual(Transport.Location.global, auth.location);
    try std.testing.expectEqualStrings("robot@my-project.iam.gserviceaccount.com", auth.email);
    try std.testing.expectEqualStrings(token_uri_default, auth.token_uri);
    try std.testing.expectEqual(@as(usize, 256), auth.key.signatureLength());
    try std.testing.expect(auth.token == null);
    // The file buffer held the key, so no byte of it survives the parse.
    try std.testing.expect(std.mem.allEqual(u8, file, 0));

    const custom = try testKeyFile(gpa, .{
        .type = "service_account",
        .project_id = "example.com:scoped",
        .private_key = rs256.fixture_pem,
        .client_email = "e",
        .token_uri = "https://token.test/mint",
    });
    defer gpa.free(custom);
    var scoped = try fromKeyFile(gpa, std.testing.io, .{}, custom, .us);
    defer scoped.deinit();
    try std.testing.expectEqualStrings("example.com:scoped", scoped.project);
    try std.testing.expectEqualStrings("https://token.test/mint", scoped.token_uri);
}

test "fromKeyFile rejects a foreign type, a missing field, and a wrong field type" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"type":"authorized_user","project_id":"p","client_email":"e","private_key":"k"}
        ,
        \\{"project_id":"p","client_email":"e","private_key":"k"}
        ,
        \\{"type":"service_account","client_email":"e","private_key":"k"}
        ,
        \\{"type":"service_account","project_id":"p","private_key":"k"}
        ,
        \\{"type":"service_account","project_id":"p","client_email":"e"}
        ,
        \\{"type":"service_account","project_id":7,"client_email":"e","private_key":"k"}
        ,
        \\{"type":"service_account","project_id":"p","client_email":"e","private_key":"k","token_uri":1}
        ,
        \\{"type":"service_account","project_id":"p","client_email":"e","private_key":"k","token_uri":null}
        ,
        \\{"type":"service_account","project_id":"","client_email":"e","private_key":"k"}
        ,
        \\{"type":"service_account","project_id":"My Project","client_email":"e","private_key":"k"}
        ,
        \\{"type":"service_account","project_id":"p/../q","client_email":"e","private_key":"k"}
        ,
        \\[]
        ,
        \\not json
        ,
    };
    for (cases) |case| {
        const file = try gpa.dupe(u8, case);
        defer gpa.free(file);
        try std.testing.expectError(
            error.BadCredentials,
            fromKeyFile(gpa, std.testing.io, .{}, file, .global),
        );
    }
    // A well-formed file with a key that is no PEM block fails on the key.
    const bad_key = try gpa.dupe(u8,
        \\{"type":"service_account","project_id":"p","client_email":"e","private_key":"k"}
    );
    defer gpa.free(bad_key);
    try std.testing.expectError(
        error.BadPrivateKey,
        fromKeyFile(gpa, std.testing.io, .{}, bad_key, .global),
    );
}

test "the project takes the path charset alone" {
    try std.testing.expect(validProject("my-project-123"));
    try std.testing.expect(validProject("example.com:scoped"));
    try std.testing.expect(!validProject(""));
    try std.testing.expect(!validProject("MyProject"));
    try std.testing.expect(!validProject("p/q"));
    try std.testing.expect(!validProject("p?x=1"));
}

test "init reads the key file from disk and refuses an absent one or a bad location" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try testKeyFile(gpa, test_fields);
    defer gpa.free(file);
    try tmp.dir.writeFile(io, .{ .sub_path = "key.json", .data = file });
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/key.json", .{tmp.sub_path});

    var auth = try init(gpa, io, .{}, &.{ .key_path = path, .location = "eu" });
    defer auth.deinit();
    try std.testing.expectEqualStrings("my-project", auth.project);
    try std.testing.expectEqual(Transport.Location.eu, auth.location);

    var missing_buffer: [160]u8 = undefined;
    const missing = try std.fmt.bufPrint(
        &missing_buffer,
        ".zig-cache/tmp/{s}/none.json",
        .{tmp.sub_path},
    );
    try std.testing.expectError(
        error.FileNotFound,
        init(gpa, io, .{}, &.{ .key_path = missing, .location = "global" }),
    );
    // A region, a case variant, and an empty value name no location Drinky
    // serves. The check runs before the file read, so the path does not matter.
    for ([_][]const u8{ "europe-west4", "EU", "", "us:443" }) |location| {
        try std.testing.expectError(
            error.BadLocation,
            init(gpa, io, .{}, &.{ .key_path = missing, .location = location }),
        );
    }
}

/// Decode one base64url JWT segment into an owned JSON value.
fn decodeSegment(gpa: std.mem.Allocator, segment: []const u8) !std.json.Parsed(std.json.Value) {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const buffer = try gpa.alloc(u8, try decoder.calcSizeForSlice(segment));
    defer gpa.free(buffer);
    try decoder.decode(buffer, segment);
    return std.json.parseFromSlice(std.json.Value, gpa, buffer, .{});
}

test "the JWT names the issuer, the scope, the audience, and the hour of validity" {
    const gpa = std.testing.allocator;
    var auth = try testAuth(gpa, std.testing.io);
    defer auth.deinit();

    const token = try auth.jwt(1_700_000_000);
    defer gpa.free(token);
    var segments = std.mem.splitScalar(u8, token, '.');
    const header_segment = segments.next().?;
    const claims_segment = segments.next().?;
    const signature_segment = segments.next().?;
    try std.testing.expect(segments.next() == null);

    var header = try decodeSegment(gpa, header_segment);
    defer header.deinit();
    try std.testing.expectEqualStrings("RS256", header.value.object.get("alg").?.string);
    try std.testing.expectEqualStrings("JWT", header.value.object.get("typ").?.string);

    var claims = try decodeSegment(gpa, claims_segment);
    defer claims.deinit();
    const object = claims.value.object;
    try std.testing.expectEqualStrings(auth.email, object.get("iss").?.string);
    try std.testing.expectEqualStrings(scope, object.get("scope").?.string);
    try std.testing.expectEqualStrings(token_uri_default, object.get("aud").?.string);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), object.get("iat").?.integer);
    try std.testing.expectEqual(@as(i64, 1_700_003_600), object.get("exp").?.integer);

    // The signature covers the two encoded segments and the dot between them.
    var signature: [256]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&signature, signature_segment);
    const public_key = try std.crypto.Certificate.rsa.PublicKey.fromBytes(
        &.{ 0x01, 0x00, 0x01 },
        auth.key.modulus,
    );
    try std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(
        256,
        signature,
        token[0 .. header_segment.len + 1 + claims_segment.len],
        public_key,
        std.crypto.hash.sha2.Sha256,
    );
}

var mint_count: usize = 0;

fn countingMint(auth: *Auth) anyerror!Token {
    mint_count += 1;
    const access = try std.fmt.allocPrint(auth.gpa, "token-{d}", .{mint_count});
    return .{ .access = access, .expires_ms = auth.nowMs() + std.time.ms_per_hour };
}

fn failingMint(_: *Auth) anyerror!Token {
    return error.TokenServiceUnavailable;
}

test "accessToken serves the cached token and mints again inside the margin" {
    const gpa = std.testing.allocator;
    var auth = try testAuth(gpa, std.testing.io);
    defer auth.deinit();
    mint_count = 0;

    try std.testing.expectEqualStrings("token-1", try auth.accessTokenWith(countingMint));
    try std.testing.expectEqualStrings("token-1", try auth.accessTokenWith(countingMint));
    try std.testing.expectEqual(@as(usize, 1), mint_count);

    // A token with less than the margin left mints again before a request.
    auth.token.?.expires_ms = auth.nowMs() + renew_margin_ms - 1;
    try std.testing.expectEqualStrings("token-2", try auth.accessTokenWith(countingMint));
    try std.testing.expectEqual(@as(usize, 2), mint_count);

    // A failed mint keeps the cached token, so the caller reports the failure
    // it has and the next call tries again.
    auth.token.?.expires_ms = 0;
    try std.testing.expectError(
        error.TokenServiceUnavailable,
        auth.accessTokenWith(failingMint),
    );
    try std.testing.expectEqualStrings("token-2", auth.token.?.access);
}

fn sameMint(auth: *Auth) anyerror!Token {
    return .{ .access = try auth.gpa.dupe(u8, "token-2"), .expires_ms = std.math.maxInt(i64) };
}

test "renew mints without regard to the cache and reports a changed token" {
    const gpa = std.testing.allocator;
    var auth = try testAuth(gpa, std.testing.io);
    defer auth.deinit();
    mint_count = 0;

    try std.testing.expect(try auth.renewWith(countingMint));
    try std.testing.expect(try auth.renewWith(countingMint));
    try std.testing.expectEqualStrings("token-2", auth.token.?.access);
    try std.testing.expectEqual(@as(usize, 2), mint_count);
    // The same bytes again report no change, so the caller repeats no request.
    try std.testing.expect(!try auth.renewWith(sameMint));
}

test parseToken {
    const gpa = std.testing.allocator;
    const token = try parseToken(gpa,
        \\{"access_token":"ya29.a","expires_in":3599,"token_type":"Bearer"}
    , 1_000);
    defer token.deinit(gpa);
    try std.testing.expectEqualStrings("ya29.a", token.access);
    try std.testing.expectEqual(@as(i64, 3_600_000), token.expires_ms);

    for ([_][]const u8{
        "{}",
        "[]",
        "not json",
        \\{"access_token":"","expires_in":3599}
        ,
        \\{"access_token":"a","expires_in":0}
        ,
        \\{"access_token":"a","expires_in":"3599"}
        ,
        \\{"access_token":"a"}
        ,
    }) |body| try std.testing.expectError(error.BadTokenResponse, parseToken(gpa, body, 0));
}

/// One canned response for the loopback test. `request_body` receives the
/// bytes the client sent.
const Reply = struct {
    status: []const u8,
    body: []const u8,
    request_body: *std.ArrayList(u8),
};

/// Serve one connection: read the request, keep its body, answer `reply`.
fn serveOne(io: std.Io, server: *std.Io.net.Server, reply: *const Reply) !void {
    var connection = try server.accept(io);
    defer connection.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &read_buffer);
    var content_length: usize = 0;
    // The head of one request holds few lines, so the cap only stops a runaway.
    var lines_left: usize = 64;
    while (lines_left > 0) : (lines_left -= 1) {
        const raw = try reader.interface.takeDelimiterInclusive('\n');
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break;
        const label = "content-length:";
        if (std.ascii.startsWithIgnoreCase(line, label)) {
            const value = std.mem.trim(u8, line[label.len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    const body = try reply.request_body.addManyAsSlice(std.testing.allocator, content_length);
    try reader.interface.readSliceAll(body);

    var write_buffer: [1024]u8 = undefined;
    var writer = connection.writer(io, &write_buffer);
    try writer.interface.print(
        "HTTP/1.1 {s}\r\ncontent-type: application/json\r\n" ++
            "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
        .{ reply.status, reply.body.len, reply.body },
    );
    try writer.interface.flush();
}

test "mint reads a token, maps a rejected grant to a rejected key, and passes an outage" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const token_uri = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.1:{d}/token",
        .{server.socket.address.getPort()},
    );
    defer gpa.free(token_uri);

    var auth = try testAuth(gpa, io);
    defer auth.deinit();
    gpa.free(auth.token_uri);
    auth.token_uri = try gpa.dupe(u8, token_uri);

    const Case = struct { status: []const u8, body: []const u8, err: ?anyerror };
    for ([_]Case{
        .{
            .status = "200 OK",
            .body = "{\"access_token\":\"ya29.minted\",\"expires_in\":3599}",
            .err = null,
        },
        .{
            .status = "400 Bad Request",
            .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Invalid JWT Signature.\"}",
            .err = error.KeyRejected,
        },
        .{ .status = "503 Service Unavailable", .body = "", .err = error.TokenServiceUnavailable },
    }) |case| {
        var request_body: std.ArrayList(u8) = .empty;
        defer request_body.deinit(gpa);
        const reply: Reply = .{
            .status = case.status,
            .body = case.body,
            .request_body = &request_body,
        };
        var serve = try io.concurrent(serveOne, .{ io, &server, &reply });
        const result = auth.mint();
        try serve.await(io);
        if (case.err) |expected| {
            try std.testing.expectError(expected, result);
        } else {
            const token = try result;
            defer token.deinit(gpa);
            try std.testing.expectEqualStrings("ya29.minted", token.access);
        }
        // Every request carries the JWT bearer grant and a three-segment assertion.
        const prefix = "grant_type=" ++ grant_type ++ "&assertion=";
        try std.testing.expect(std.mem.startsWith(u8, request_body.items, prefix));
        const assertion = request_body.items[prefix.len..];
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assertion, "."));
    }
}
