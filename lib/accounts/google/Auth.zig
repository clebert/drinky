const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const store = @import("../oauth/store.zig");
const wire = @import("../oauth/wire.zig");
const rs256 = @import("rs256.zig");
const testing = @import("../testing.zig");

const Auth = @This();

const key_file_bytes_max = 64 * 1024;
const token_uri_default = "https://oauth2.googleapis.com/token";
const scope = "https://www.googleapis.com/auth/cloud-platform";
const token_lifetime_s = 3600;
const grant_type = "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer";

gpa: std.mem.Allocator,
io: std.Io,
link: wire.Link,
project: []const u8,
location: providers.Gemini.Location,
email: []const u8,
token_uri: []const u8,
key: rs256.PrivateKey,
token: ?Token,
mutex: std.Io.Mutex,

pub const InitError = std.Io.Dir.ReadFileAllocError ||
    error{ BadLocation, BadCredentials, BadPrivateKey };

const Options = struct {
    key_path: []const u8,
    location: []const u8,
};

const Token = struct {
    access: []const u8,
    expires_ms: i64,

    fn deinit(self: *const Token, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
    }
};

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: wire.Link,
    options: *const Options,
) InitError!Auth {
    const location = std.meta.stringToEnum(providers.Gemini.Location, options.location) orelse
        return error.BadLocation;
    const file = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.key_path,
        gpa,
        .limited(key_file_bytes_max),
    );
    defer gpa.free(file);
    return fromKeyFile(gpa, io, link, file, location);
}

fn fromKeyFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: wire.Link,
    file: []u8,
    location: providers.Gemini.Location,
) InitError!Auth {
    defer std.crypto.secureZero(u8, file);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, file, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadCredentials,
        };
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return error.BadCredentials;

    if (!std.mem.eql(u8, try requiredString(object, "type"), "service_account"))
        return error.BadCredentials;
    const project = try requiredString(object, "project_id");
    if (!validProject(project)) return error.BadCredentials;
    const email = try requiredString(object, "client_email");
    const private_key = try requiredString(object, "private_key");
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
        .link = link,
        .project = project_copy,
        .location = location,
        .email = email_copy,
        .token_uri = token_uri_copy,
        .key = key,
        .token = null,
        .mutex = .init,
    };
}

pub fn deinit(self: *Auth) void {
    if (self.token) |token| token.deinit(self.gpa);
    self.key.deinit(self.gpa);
    self.gpa.free(self.project);
    self.gpa.free(self.email);
    self.gpa.free(self.token_uri);
}

pub fn accessToken(self: *Auth, gpa: std.mem.Allocator) ![]const u8 {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    const live = if (self.token) |token| self.nowMs() < token.expires_ms else false;
    if (!live) _ = try self.mintLocked();
    return gpa.dupe(u8, self.token.?.access);
}

pub fn renew(self: *Auth) !bool {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    return self.mintLocked();
}

pub fn credential(self: *Auth) providers.Credential {
    return .{ .ptr = self, .vtable = &store.Bearer(Auth).vtable };
}

fn mintLocked(self: *Auth) !bool {
    const fresh = try self.mint();
    const changed = if (self.token) |old| !std.mem.eql(u8, old.access, fresh.access) else true;
    if (self.token) |old| old.deinit(self.gpa);
    self.token = fresh;
    return changed;
}

fn nowMs(self: *const Auth) i64 {
    return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
}

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
    const response = wire.post(self.gpa, self.io, &self.link, &.{
        .url = self.token_uri,
        .content_type = wire.form_content_type,
        .body = body,
    }) catch |err| return switch (err) {
        error.TokenGrantRejected => error.KeyRejected,
        else => |other| other,
    };
    defer self.gpa.free(response);
    return parseToken(self.gpa, response, now_ms);
}

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
    const target = try out.addManyAsSlice(
        gpa,
        std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len),
    );
    _ = std.base64.url_safe_no_pad.Encoder.encode(target, bytes);
}

fn parseToken(gpa: std.mem.Allocator, body: []const u8, now_ms: i64) !Token {
    const parsed = try wire.parseJson(gpa, body);
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return error.BadTokenResponse;
    const access = providers.json.string(object.getPtr("access_token")) orelse
        return error.BadTokenResponse;
    const expires_in = providers.json.integer(object.getPtr("expires_in")) orelse
        return error.BadTokenResponse;
    if (access.len == 0 or expires_in <= 0) return error.BadTokenResponse;
    const expires_ms = wire.expiresAt(&.{
        .now_ms = now_ms,
        .lifetime_ms = expires_in *| std.time.ms_per_s,
    }) orelse return error.BadTokenResponse;
    return .{ .access = try gpa.dupe(u8, access), .expires_ms = expires_ms };
}

fn requiredString(object: *const std.json.ObjectMap, name: []const u8) ![]const u8 {
    return providers.json.string(object.getPtr(name)) orelse error.BadCredentials;
}

fn validProject(project: []const u8) bool {
    if (project.len == 0) return false;
    for (project) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and
            std.mem.indexOfScalar(u8, "-.:", byte) == null) return false;
    }
    return true;
}

test "fromKeyFile reads the project and the location and zeros the key file" {
    const gpa = std.testing.allocator;
    const file = try testKeyFile(gpa, test_fields);
    defer gpa.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "BEGIN PRIVATE KEY") != null);

    var auth = try fromKeyFile(gpa, std.testing.io, .{}, file, .global);
    defer auth.deinit();
    try std.testing.expectEqualStrings("my-project", auth.project);
    try std.testing.expectEqual(providers.Gemini.Location.global, auth.location);
    try std.testing.expect(std.mem.allEqual(u8, file, 0));

    const scoped_file = try testKeyFile(gpa, .{
        .type = "service_account",
        .project_id = "example.com:scoped",
        .private_key = testing.private_key_pem,
        .client_email = "e",
    });
    defer gpa.free(scoped_file);
    var scoped = try fromKeyFile(gpa, std.testing.io, .{}, scoped_file, .us);
    defer scoped.deinit();
    try std.testing.expectEqualStrings("example.com:scoped", scoped.project);
    try std.testing.expectEqual(providers.Gemini.Location.us, scoped.location);
}

fn testKeyFile(gpa: std.mem.Allocator, fields: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, fields, .{});
}

const test_fields = .{
    .type = "service_account",
    .project_id = "my-project",
    .private_key_id = "ignored",
    .private_key = testing.private_key_pem,
    .client_email = "robot@my-project.iam.gserviceaccount.com",
    .universe_domain = "googleapis.com",
};

fn testAuth(gpa: std.mem.Allocator, io: std.Io, transport: providers.Transport) !Auth {
    const file = try testKeyFile(gpa, test_fields);
    defer gpa.free(file);
    return fromKeyFile(gpa, io, .{ .transport = transport }, file, .eu);
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
        \\{"type":"service_account","project_id":"p","client_email":"e","private_key":"k",
        \\"token_uri":1}
        ,
        \\{"type":"service_account","project_id":"p","client_email":"e","private_key":"k",
        \\"token_uri":null}
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
    const path = try testing.tmpPath(&path_buffer, &tmp, "key.json");

    var auth = try init(gpa, io, .{}, &.{ .key_path = path, .location = "eu" });
    defer auth.deinit();
    try std.testing.expectEqualStrings("my-project", auth.project);
    try std.testing.expectEqual(providers.Gemini.Location.eu, auth.location);

    var missing_buffer: [160]u8 = undefined;
    const missing = try testing.tmpPath(&missing_buffer, &tmp, "none.json");
    try std.testing.expectError(
        error.FileNotFound,
        init(gpa, io, .{}, &.{ .key_path = missing, .location = "global" }),
    );
    for ([_][]const u8{ "europe-west4", "EU", "", "us:443" }) |location| {
        try std.testing.expectError(
            error.BadLocation,
            init(gpa, io, .{}, &.{ .key_path = missing, .location = location }),
        );
    }
}

fn decodeSegment(gpa: std.mem.Allocator, segment: []const u8) !std.json.Parsed(std.json.Value) {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const buffer = try gpa.alloc(u8, try decoder.calcSizeForSlice(segment));
    defer gpa.free(buffer);
    try decoder.decode(buffer, segment);
    return std.json.parseFromSlice(std.json.Value, gpa, buffer, .{});
}

test "a mint posts a signed JWT that names the issuer, the scope, the audience, and the hour" {
    const gpa = std.testing.allocator;
    var clock: core.testing.StepClock = undefined;
    clock.init(gpa, 0);
    defer clock.deinit();
    clock.now_ns = 1_700_000_000 * std.time.ns_per_s;
    const default_file = try testKeyFile(gpa, test_fields);
    defer gpa.free(default_file);
    const custom_file = try testKeyFile(gpa, .{
        .type = "service_account",
        .project_id = "my-project",
        .private_key = testing.private_key_pem,
        .client_email = "robot@my-project.iam.gserviceaccount.com",
        .token_uri = "https://token.test/mint",
    });
    defer gpa.free(custom_file);
    const key = try rs256.parsePem(gpa, testing.private_key_pem);
    defer key.deinit(gpa);
    const public_key = try std.crypto.Certificate.rsa.PublicKey.fromBytes(
        &.{ 0x01, 0x00, 0x01 },
        key.modulus,
    );
    const cases = [_]struct { file: []u8, audience: []const u8 }{
        .{ .file = default_file, .audience = token_uri_default },
        .{ .file = custom_file, .audience = "https://token.test/mint" },
    };

    for (cases) |case| {
        var transport: providers.testing.FakeTransport = .{
            .gpa = gpa,
            .replies = &.{tokenReply("token-1")},
        };
        defer transport.deinit();
        var auth = try fromKeyFile(
            gpa,
            clock.io(),
            .{ .transport = transport.transport() },
            case.file,
            .global,
        );
        defer auth.deinit();
        try std.testing.expect(try auth.renew());

        const request = transport.requests.items[0];
        const head = try std.fmt.allocPrint(gpa, "POST {s}\n" ++
            "content-type: application/x-www-form-urlencoded\n\n" ++
            "grant_type=" ++ grant_type ++ "&assertion=", .{case.audience});
        defer gpa.free(head);
        try std.testing.expect(std.mem.startsWith(u8, request, head));
        const assertion = request[head.len..];
        var segments = std.mem.splitScalar(u8, assertion, '.');
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
        try std.testing.expectEqualStrings(
            "robot@my-project.iam.gserviceaccount.com",
            object.get("iss").?.string,
        );
        try std.testing.expectEqualStrings(scope, object.get("scope").?.string);
        try std.testing.expectEqualStrings(case.audience, object.get("aud").?.string);
        try std.testing.expectEqual(@as(i64, 1_700_000_000), object.get("iat").?.integer);
        try std.testing.expectEqual(@as(i64, 1_700_003_600), object.get("exp").?.integer);

        const decoder = std.base64.url_safe_no_pad.Decoder;
        const signature_length = try decoder.calcSizeForSlice(signature_segment);
        try std.testing.expectEqual(@as(usize, 256), signature_length);
        var signature: [256]u8 = undefined;
        try decoder.decode(&signature, signature_segment);
        try std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(
            256,
            signature,
            assertion[0 .. header_segment.len + 1 + claims_segment.len],
            public_key,
            std.crypto.hash.sha2.Sha256,
        );
    }
}

const token_reply_lifetime_s = 3599;
const token_reply_expires_ms =
    (token_reply_lifetime_s - 5 * std.time.s_per_min) * std.time.ms_per_s;

fn tokenReply(comptime access: []const u8) providers.testing.FakeTransport.Reply {
    return .{ .body = std.fmt.comptimePrint(
        "{{\"access_token\":\"{s}\",\"expires_in\":{d}}}",
        .{ access, token_reply_lifetime_s },
    ) };
}

test "accessToken serves the cached token until it expires and keeps it through a failed mint" {
    const gpa = std.testing.allocator;
    var clock: core.testing.StepClock = undefined;
    clock.init(gpa, 0);
    defer clock.deinit();
    var transport: providers.testing.FakeTransport = .{ .gpa = gpa, .replies = &.{
        tokenReply("token-1"),
        tokenReply("token-2"),
        .{ .status = .service_unavailable },
        tokenReply("token-2"),
    } };
    defer transport.deinit();
    var auth = try testAuth(gpa, clock.io(), transport.transport());
    defer auth.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const copies = arena.allocator();

    try std.testing.expectEqualStrings("token-1", try auth.accessToken(copies));
    clock.now_ns = token_reply_expires_ms * std.time.ns_per_ms - 1;
    try std.testing.expectEqualStrings("token-1", try auth.accessToken(copies));
    try std.testing.expectEqual(@as(usize, 1), transport.requests.items.len);

    clock.now_ns += 1;
    try std.testing.expectEqualStrings("token-2", try auth.accessToken(copies));
    try std.testing.expectEqual(@as(usize, 2), transport.requests.items.len);

    clock.now_ns += token_reply_expires_ms * std.time.ns_per_ms;
    try std.testing.expectError(error.TokenServiceUnavailable, auth.accessToken(copies));
    try std.testing.expect(!try auth.renew());
}

test "renew mints without regard to the cache and reports a changed token" {
    const gpa = std.testing.allocator;
    var transport: providers.testing.FakeTransport = .{ .gpa = gpa, .replies = &.{
        tokenReply("token-1"),
        tokenReply("token-2"),
        tokenReply("token-2"),
    } };
    defer transport.deinit();
    var auth = try testAuth(gpa, std.testing.io, transport.transport());
    defer auth.deinit();

    try std.testing.expect(try auth.renew());
    try std.testing.expect(try auth.renew());
    const access = try auth.accessToken(gpa);
    defer gpa.free(access);
    try std.testing.expectEqualStrings("token-2", access);
    try std.testing.expect(!try auth.renew());
    try std.testing.expectEqual(@as(usize, 3), transport.requests.items.len);
}

test parseToken {
    const gpa = std.testing.allocator;
    const token = try parseToken(gpa,
        \\{"access_token":"ya29.a","expires_in":3599,"token_type":"Bearer"}
    , 1_000);
    defer token.deinit(gpa);
    try std.testing.expectEqualStrings("ya29.a", token.access);
    try std.testing.expectEqual(
        @as(i64, 1_000 + 3_599_000 - 5 * std.time.ms_per_min),
        token.expires_ms,
    );

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

test "a mint maps a rejected grant to a rejected key and passes an outage" {
    const gpa = std.testing.allocator;
    const rejected: providers.testing.FakeTransport.Reply = .{
        .status = .bad_request,
        .body = "{\"error\":\"invalid_grant\"," ++
            "\"error_description\":\"Invalid JWT Signature.\"}",
    };
    var transport: providers.testing.FakeTransport = .{ .gpa = gpa, .replies = &.{
        rejected,
        .{ .status = .service_unavailable },
        rejected,
        .{ .status = .service_unavailable },
    } };
    defer transport.deinit();
    var auth = try testAuth(gpa, std.testing.io, transport.transport());
    defer auth.deinit();

    try std.testing.expectError(error.KeyRejected, auth.accessToken(gpa));
    try std.testing.expectError(error.TokenServiceUnavailable, auth.renew());
    try std.testing.expectError(error.Rejected, auth.credential().token(gpa));
    try std.testing.expectError(error.Network, auth.credential().renew());
    try std.testing.expectEqual(@as(usize, 4), transport.requests.items.len);
}
