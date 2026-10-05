const std = @import("std");

const providers = @import("providers");

const login = @import("../oauth/login.zig");
const store = @import("../oauth/store.zig");
const wire = @import("../oauth/wire.zig");

const client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const device_url = "https://auth.x.ai/oauth2/device/code";
const token_url = "https://auth.x.ai/oauth2/token";
const scope = "openid profile email offline_access grok-cli:access api:access";
const device_grant = "urn:ietf:params:oauth:grant-type:device_code";
const interval_ms_default = 5_000;

pub const sign_in: store.SignIn = .device;
pub const secret: store.Secret = .access_token;

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,

    pub fn deinit(self: *const Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
    }
};

const Device = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: ?[]const u8,
    interval_ms: u64,
    lifetime_ms: u64,

    pub fn deinit(self: *const Device, gpa: std.mem.Allocator) void {
        gpa.free(self.device_code);
        gpa.free(self.user_code);
        gpa.free(self.verification_uri);
        if (self.verification_uri_complete) |complete| gpa.free(complete);
    }

    pub fn url(self: *const Device) []const u8 {
        return self.verification_uri_complete orelse self.verification_uri;
    }
};

pub fn requestDevice(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
) !Device {
    const body = try wire.formBody(gpa, &.{
        .{ .name = "client_id", .value = client_id },
        .{ .name = "scope", .value = scope },
        .{ .name = "referrer", .value = providers.Transport.client_name },
    });
    defer gpa.free(body);
    const response = try wire.post(gpa, io, link, &.{
        .url = device_url,
        .content_type = wire.form_content_type,
        .body = body,
    });
    defer gpa.free(response);
    return parseDevice(gpa, response);
}

pub fn poll(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    device_code: []const u8,
) !login.Poll(Tokens) {
    const body = try wire.formBody(gpa, &.{
        .{ .name = "grant_type", .value = device_grant },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "device_code", .value = device_code },
    });
    defer gpa.free(body);
    const response = wire.postDevice(gpa, io, link, &.{
        .url = token_url,
        .body = body,
    }) catch |err|
        switch (err) {
            error.AuthorizationPending => return .pending,
            error.SlowDown => return .slow_down,
            else => return err,
        };
    defer gpa.free(response);
    return .{ .granted = try parseTokens(gpa, &.{
        .body = response,
        .now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    }) };
}

pub fn refresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    link: *const wire.Link,
    tokens: *const Tokens,
) !Tokens {
    const body = try wire.formBody(gpa, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "refresh_token", .value = tokens.refresh },
    });
    defer gpa.free(body);
    const response = try wire.post(gpa, io, link, &.{
        .url = token_url,
        .content_type = wire.form_content_type,
        .body = body,
    });
    defer gpa.free(response);
    return parseTokens(gpa, &.{
        .body = response,
        .now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .refresh_kept = tokens.refresh,
    });
}

fn parseDevice(gpa: std.mem.Allocator, body: []const u8) !Device {
    const parsed = wire.parseJson(gpa, body) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadTokenResponse => error.BadDeviceResponse,
    };
    defer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return error.BadDeviceResponse;

    const device_code = providers.json.string(object.getPtr("device_code")) orelse
        return error.BadDeviceResponse;
    const user_code = providers.json.string(object.getPtr("user_code")) orelse
        return error.BadDeviceResponse;
    const verification_uri = providers.json.string(object.getPtr("verification_uri")) orelse
        return error.BadDeviceResponse;
    if (!isHttps(verification_uri)) return error.BadDeviceResponse;
    const maybe_complete = providers.json.string(object.getPtr("verification_uri_complete"));
    if (maybe_complete) |complete| {
        if (!isHttps(complete)) return error.BadDeviceResponse;
    }
    const expires_in = providers.json.integer(object.getPtr("expires_in")) orelse
        return error.BadDeviceResponse;
    if (expires_in <= 0) return error.BadDeviceResponse;
    const lifetime_ms = std.math.mul(u64, @intCast(expires_in), 1000) catch
        return error.BadDeviceResponse;
    const interval_ms: u64 = interval: {
        const interval = providers.json.integer(object.getPtr("interval")) orelse
            break :interval interval_ms_default;
        if (interval <= 0) break :interval interval_ms_default;
        break :interval std.math.mul(u64, @intCast(interval), 1000) catch interval_ms_default;
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

fn parseTokens(gpa: std.mem.Allocator, options: *const wire.ReplyOptions) !Tokens {
    const reply = try wire.parseReply(gpa, options);
    return .{ .access = reply.access, .refresh = reply.refresh, .expires_ms = reply.expires_ms };
}

test parseTokens {
    const gpa = std.testing.allocator;
    const tokens = try parseTokens(gpa, &.{
        .body = "{\"access_token\":\"at\",\"expires_in\":21600}",
        .now_ms = test_now_ms,
        .refresh_kept = "rt",
    });
    defer tokens.deinit(gpa);
    try std.testing.expectEqualStrings("at", tokens.access);
    try std.testing.expectEqualStrings("rt", tokens.refresh);
    try std.testing.expectEqual(test_now_ms + 21_600_000 - 300_000, tokens.expires_ms);
}

const test_now_ms = 1_700_000_000_000;

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

    const plain = try parseDevice(gpa,
        \\{ "device_code": "dev-2", "user_code": "WXYZ",
        \\  "verification_uri": "https://auth.x.ai/activate", "expires_in": 300, "interval": 0 }
    );
    defer plain.deinit(gpa);
    try std.testing.expectEqualStrings("https://auth.x.ai/activate", plain.url());
    try std.testing.expectEqual(@as(u64, interval_ms_default), plain.interval_ms);
}

test "parseDevice rejects a grant it cannot poll or open" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadDeviceResponse, parseDevice(gpa,
        \\{ "device_code": "d", "user_code": "u", "verification_uri": "file:///etc/passwd",
        \\  "expires_in": 600 }
    ));
    try std.testing.expectError(error.BadDeviceResponse, parseDevice(gpa,
        \\{ "device_code": "d", "user_code": "u", "verification_uri": "https://auth.x.ai/activate",
        \\  "verification_uri_complete": "http://evil.test/", "expires_in": 600 }
    ));
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
