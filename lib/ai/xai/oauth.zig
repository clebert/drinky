//! The xAI device-code OAuth protocol (RFC 8628) of the SuperGrok and X Premium
//! subscription: the device authorization request, the token poll, and the
//! refresh. Credential storage and the login orchestration live in `Auth`. This
//! module only speaks the protocol.
//!
//! The client id is the public one of the Grok Build client, and the access
//! token authorizes the public API at `api.x.ai` as a plain bearer token. xAI
//! publishes its OIDC endpoints and the device grant in its discovery document,
//! but documents no client for a third-party harness. This is an acknowledged
//! off-label surface (the API-key account is the official fallback).

const std = @import("std");

const json = @import("../json.zig");
const jwt = @import("../jwt.zig");
const net = @import("../net.zig");
const oauth_login = @import("../oauth_login.zig");
const oauth_wire = @import("../oauth_wire.zig");

const client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const device_url = "https://auth.x.ai/oauth2/device/code";
const token_url = "https://auth.x.ai/oauth2/token";
const scope = "openid profile email offline_access grok-cli:access api:access";
const device_grant = "urn:ietf:params:oauth:grant-type:device_code";
/// The `referrer` field names the client to xAI.
const referrer = "drinky";
/// The time before the stated expiry at which a token counts as stale. A short
/// token keeps half its lifetime, so it never counts as stale on arrival.
const refresh_margin_ms = 5 * 60 * 1000;
/// The token lifetime when a response names none. The reference clients take
/// the same value, and a guess that runs long costs one 401 renew.
const lifetime_default_s = 3600;
/// RFC 8628: a grant that names no interval polls every five seconds.
const interval_default_ms = 5_000;

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    /// The absolute epoch milliseconds at which `access` counts as stale.
    expires_ms: i64,
    /// The `sub` claim of the id token, which names the user. Null when the
    /// response carries no such claim.
    subject: ?[]const u8 = null,

    pub fn deinit(self: Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
        if (self.subject) |subject_owned| gpa.free(subject_owned);
    }

    /// Whether both credentials name the same user. An unknown user matches
    /// nobody.
    pub fn samePrincipal(self: *const Tokens, other: *const Tokens) bool {
        const subject_own = self.subject orelse return false;
        const subject_other = other.subject orelse return false;
        return std.mem.eql(u8, subject_own, subject_other);
    }
};

/// One open device-code grant, as the authorization endpoint stated it.
pub const Device = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    /// The verification URI with the user code filled in, when the server
    /// names one.
    verification_uri_complete: ?[]const u8,
    interval_ms: u64,
    /// How long the grant stays open, from the moment the server issued it.
    lifetime_ms: u64,

    pub fn deinit(self: Device, gpa: std.mem.Allocator) void {
        gpa.free(self.device_code);
        gpa.free(self.user_code);
        gpa.free(self.verification_uri);
        if (self.verification_uri_complete) |complete| gpa.free(complete);
    }

    /// The URL that the browser opens. The complete one carries the user code,
    /// so the page asks for none.
    pub fn url(self: *const Device) []const u8 {
        return self.verification_uri_complete orelse self.verification_uri;
    }
};

/// Open a device-code grant. The caller frees the result.
pub fn requestDevice(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts) !Device {
    const body = try oauth_wire.formBody(gpa, &.{
        .{ .name = "client_id", .value = client_id },
        .{ .name = "scope", .value = scope },
        .{ .name = "referrer", .value = referrer },
    });
    defer gpa.free(body);
    const response = try oauth_wire.post(
        gpa,
        io,
        timeouts,
        device_url,
        oauth_wire.form_content_type,
        body,
    );
    defer gpa.free(response);
    return parseDevice(gpa, response);
}

/// Ask the token endpoint once for the tokens of `device_code`. The caller frees
/// a granted result.
pub fn poll(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    device_code: []const u8,
) !oauth_login.Poll(Tokens) {
    const body = try oauth_wire.formBody(gpa, &.{
        .{ .name = "grant_type", .value = device_grant },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "device_code", .value = device_code },
    });
    defer gpa.free(body);
    const response = oauth_wire.postDevice(gpa, io, timeouts, token_url, body) catch |err|
        switch (err) {
            error.AuthorizationPending => return .pending,
            error.SlowDown => return .slow_down,
            else => return err,
        };
    defer gpa.free(response);
    return .{ .granted = try parseTokens(gpa, io, response, .{}) };
}

/// Trade a refresh token for fresh tokens. A refresh response can omit the
/// refresh token and the id token, so the current values carry over when the
/// response leaves them out. The caller frees the result.
pub fn refresh(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts, tokens: Tokens) !Tokens {
    const body = try oauth_wire.formBody(gpa, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "refresh_token", .value = tokens.refresh },
    });
    defer gpa.free(body);
    const response = try oauth_wire.post(
        gpa,
        io,
        timeouts,
        token_url,
        oauth_wire.form_content_type,
        body,
    );
    defer gpa.free(response);
    return parseTokens(gpa, io, response, .{
        .refresh = tokens.refresh,
        .subject = tokens.subject orelse "",
    });
}

/// Decode a device authorization response. A verification URI that is not
/// HTTPS rejects the response, because Drinky hands that URI to the browser
/// launcher of the system.
fn parseDevice(gpa: std.mem.Allocator, body: []const u8) !Device {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadDeviceResponse;

    const device_code = json.string(object.get("device_code")) orelse
        return error.BadDeviceResponse;
    const user_code = json.string(object.get("user_code")) orelse return error.BadDeviceResponse;
    const verification_uri = json.string(object.get("verification_uri")) orelse
        return error.BadDeviceResponse;
    if (!isHttps(verification_uri)) return error.BadDeviceResponse;
    const maybe_complete = json.string(object.get("verification_uri_complete"));
    if (maybe_complete) |complete| {
        if (!isHttps(complete)) return error.BadDeviceResponse;
    }
    const expires_in = json.integer(object.get("expires_in")) orelse
        return error.BadDeviceResponse;
    if (expires_in <= 0) return error.BadDeviceResponse;
    const lifetime_ms = std.math.mul(u64, @intCast(expires_in), 1000) catch
        return error.BadDeviceResponse;
    const interval_ms: u64 = interval: {
        const interval = json.integer(object.get("interval")) orelse
            break :interval interval_default_ms;
        if (interval <= 0) break :interval interval_default_ms;
        break :interval std.math.mul(u64, @intCast(interval), 1000) catch interval_default_ms;
    };

    const device_code_owned = try gpa.dupe(u8, device_code);
    errdefer gpa.free(device_code_owned);
    const user_code_owned = try gpa.dupe(u8, user_code);
    errdefer gpa.free(user_code_owned);
    const verification_uri_owned = try gpa.dupe(u8, verification_uri);
    errdefer gpa.free(verification_uri_owned);
    const complete_owned: ?[]const u8 = if (maybe_complete) |complete|
        try gpa.dupe(u8, complete)
    else
        null;

    return .{
        .device_code = device_code_owned,
        .user_code = user_code_owned,
        .verification_uri = verification_uri_owned,
        .verification_uri_complete = complete_owned,
        .interval_ms = interval_ms,
        .lifetime_ms = lifetime_ms,
    };
}

fn isHttps(uri: []const u8) bool {
    return std.mem.startsWith(u8, uri, "https://");
}

/// The values that carry over when a refresh response leaves them out. An empty
/// value carries nothing.
const Fallback = struct { refresh: []const u8 = "", subject: []const u8 = "" };

fn parseTokens(gpa: std.mem.Allocator, io: std.Io, body: []const u8, fallback: Fallback) !Tokens {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadTokenResponse;

    const access = json.string(object.get("access_token")) orelse return error.MissingAccessToken;
    const refresh_token = json.string(object.get("refresh_token")) orelse fallback.refresh;
    if (refresh_token.len == 0) return error.MissingRefreshToken;
    const expires_in = json.integer(object.get("expires_in")) orelse lifetime_default_s;
    if (expires_in <= 0) return error.MissingExpiry;
    // A crafted expiry must fail cleanly, not overflow and crash.
    const lifetime_ms = std.math.mul(i64, expires_in, 1000) catch return error.MissingExpiry;
    const margin_ms = @min(refresh_margin_ms, @divFloor(lifetime_ms, 2));
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const expires_ms = std.math.add(i64, now_ms, lifetime_ms - margin_ms) catch
        return error.MissingExpiry;

    const subject_owned = try subject(gpa, json.string(object.get("id_token")), access, fallback);
    errdefer if (subject_owned) |owned| gpa.free(owned);
    const access_owned = try gpa.dupe(u8, access);
    errdefer gpa.free(access_owned);
    const refresh_owned = try gpa.dupe(u8, refresh_token);

    return .{
        .access = access_owned,
        .refresh = refresh_owned,
        .expires_ms = expires_ms,
        .subject = subject_owned,
    };
}

/// The user id: the `sub` claim of the id token, then of the access token, then
/// the carried-over value. An owned copy, or null when no source names one.
fn subject(
    gpa: std.mem.Allocator,
    maybe_id_token: ?[]const u8,
    access_token: []const u8,
    fallback: Fallback,
) error{OutOfMemory}!?[]const u8 {
    if (maybe_id_token) |id_token| {
        if (try jwt.stringClaim(gpa, id_token, "sub")) |found| return found;
    }
    if (try jwt.stringClaim(gpa, access_token, "sub")) |found| return found;
    if (fallback.subject.len != 0) return try gpa.dupe(u8, fallback.subject);
    return null;
}

test parseDevice {
    const gpa = std.testing.allocator;
    const device = try parseDevice(gpa,
        \\{ "device_code": "dev-1", "user_code": "ABCD-EFGH",
        \\  "verification_uri": "https://auth.x.ai/activate",
        \\  "verification_uri_complete": "https://auth.x.ai/activate?user_code=ABCD-EFGH",
        \\  "expires_in": 600, "interval": 5 }
    );
    defer device.deinit(gpa);
    try std.testing.expectEqualStrings("dev-1", device.device_code);
    try std.testing.expectEqualStrings("ABCD-EFGH", device.user_code);
    try std.testing.expectEqualStrings(
        "https://auth.x.ai/activate?user_code=ABCD-EFGH",
        device.url(),
    );
    try std.testing.expectEqual(@as(u64, 600_000), device.lifetime_ms);
    try std.testing.expectEqual(@as(u64, 5_000), device.interval_ms);

    // Without the complete URI the browser opens the plain one, and a grant
    // that names no interval takes the default of the RFC.
    const plain = try parseDevice(gpa,
        \\{ "device_code": "dev-2", "user_code": "WXYZ",
        \\  "verification_uri": "https://auth.x.ai/activate", "expires_in": 300, "interval": 0 }
    );
    defer plain.deinit(gpa);
    try std.testing.expectEqualStrings("https://auth.x.ai/activate", plain.url());
    try std.testing.expectEqual(@as(u64, interval_default_ms), plain.interval_ms);
}

test "parseDevice rejects a grant it cannot poll or open" {
    const gpa = std.testing.allocator;
    // The browser launcher of the system takes the URI, so only HTTPS passes.
    try std.testing.expectError(error.BadDeviceResponse, parseDevice(gpa,
        \\{ "device_code": "d", "user_code": "u", "verification_uri": "file:///etc/passwd",
        \\  "expires_in": 600 }
    ));
    try std.testing.expectError(error.BadDeviceResponse, parseDevice(gpa,
        \\{ "device_code": "d", "user_code": "u", "verification_uri": "https://auth.x.ai/activate",
        \\  "verification_uri_complete": "http://evil.test/", "expires_in": 600 }
    ));
    // A grant without a window never ends, so it is refused.
    try std.testing.expectError(error.BadDeviceResponse, parseDevice(gpa,
        \\{ "device_code": "d", "user_code": "u", "verification_uri": "https://auth.x.ai/activate" }
    ));
    try std.testing.expectError(error.BadDeviceResponse, parseDevice(gpa,
        \\{ "device_code": "d", "user_code": "u", "verification_uri": "https://auth.x.ai/activate",
        \\  "expires_in": 0 }
    ));
    try std.testing.expectError(error.BadDeviceResponse, parseDevice(gpa,
        \\{ "user_code": "u", "verification_uri": "https://auth.x.ai/activate", "expires_in": 600 }
    ));
    try std.testing.expectError(error.BadDeviceResponse, parseDevice(gpa, "[]"));
}

test parseTokens {
    const gpa = std.testing.allocator;
    const id_token = try jwt.testToken(gpa, "{\"sub\":\"user-1\",\"email\":\"a@b.c\"}");
    defer gpa.free(id_token);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":3600," ++
            "\"id_token\":\"{s}\"}}",
        .{id_token},
    );
    defer gpa.free(body);

    const tokens = try parseTokens(gpa, std.testing.io, body, .{});
    defer tokens.deinit(gpa);
    try std.testing.expectEqualStrings("at", tokens.access);
    try std.testing.expectEqualStrings("rt", tokens.refresh);
    try std.testing.expectEqualStrings("user-1", tokens.subject.?);
    // The expiry lies ahead of now by the lifetime less the refresh margin.
    const now_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    try std.testing.expect(tokens.expires_ms > now_ms);
    try std.testing.expect(tokens.expires_ms <= now_ms + 3600 * 1000 - refresh_margin_ms);

    var other = tokens;
    try std.testing.expect(tokens.samePrincipal(&other));
    other.subject = "user-2";
    try std.testing.expect(!tokens.samePrincipal(&other));
    other.subject = null;
    try std.testing.expect(!tokens.samePrincipal(&other));
    try std.testing.expect(!other.samePrincipal(&tokens));
}

test "parseTokens carries the refresh token and the user over a partial refresh" {
    const gpa = std.testing.allocator;
    const tokens = try parseTokens(gpa, std.testing.io, "{\"access_token\":\"at2\"}", .{
        .refresh = "old_rt",
        .subject = "user-1",
    });
    defer tokens.deinit(gpa);
    try std.testing.expectEqualStrings("old_rt", tokens.refresh);
    try std.testing.expectEqualStrings("user-1", tokens.subject.?);
    // A response that names no lifetime takes the default of one hour.
    const now_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    try std.testing.expect(tokens.expires_ms > now_ms + (lifetime_default_s - 600) * 1000);
}

test "parseTokens reads the user off a JWT access token and stays silent otherwise" {
    const gpa = std.testing.allocator;
    const access = try jwt.testToken(gpa, "{\"sub\":\"user-9\",\"exp\":2000000000}");
    defer gpa.free(access);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt\",\"expires_in\":3600}}",
        .{access},
    );
    defer gpa.free(body);
    const tokens = try parseTokens(gpa, std.testing.io, body, .{});
    defer tokens.deinit(gpa);
    try std.testing.expectEqualStrings("user-9", tokens.subject.?);

    const bare = try parseTokens(
        gpa,
        std.testing.io,
        "{\"access_token\":\"opaque\",\"refresh_token\":\"rt\",\"expires_in\":3600}",
        .{},
    );
    defer bare.deinit(gpa);
    try std.testing.expect(bare.subject == null);
}

// A token shorter than the refresh margin keeps half its lifetime, so a fresh
// token never reads as stale on arrival.
test "a short token keeps half its lifetime before it counts as stale" {
    const gpa = std.testing.allocator;
    const tokens = try parseTokens(
        gpa,
        std.testing.io,
        "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":60}",
        .{},
    );
    defer tokens.deinit(gpa);
    const now_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    try std.testing.expect(tokens.expires_ms > now_ms + 20 * 1000);
    try std.testing.expect(tokens.expires_ms <= now_ms + 30 * 1000);
}

test "parseTokens rejects a response without a credential" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.MissingAccessToken,
        parseTokens(gpa, std.testing.io, "{\"refresh_token\":\"rt\"}", .{}),
    );
    try std.testing.expectError(
        error.MissingRefreshToken,
        parseTokens(gpa, std.testing.io, "{\"access_token\":\"at\"}", .{}),
    );
    try std.testing.expectError(
        error.MissingExpiry,
        parseTokens(
            gpa,
            std.testing.io,
            "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":9223372036854775807}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.MissingExpiry,
        parseTokens(
            gpa,
            std.testing.io,
            "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":0}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.BadTokenResponse,
        parseTokens(gpa, std.testing.io, "[]", .{}),
    );
}
