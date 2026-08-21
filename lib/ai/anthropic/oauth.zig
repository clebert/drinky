//! The Anthropic subscription OAuth protocol: PKCE generation, token exchange,
//! refresh, and the account profile. Credential storage and login orchestration
//! live in `Auth`. This module only speaks the protocol.

const std = @import("std");

const json = @import("../json.zig");
const net = @import("../net.zig");
const oauth_wire = @import("../oauth_wire.zig");

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const authorize_url = "https://claude.ai/oauth/authorize";
const token_url = "https://platform.claude.com/v1/oauth/token";
const profile_url = "https://api.anthropic.com/api/oauth/profile";
pub const callback_port = 53692;
const redirect_uri = "http://localhost:53692/callback";

const redirect_encoded = "http%3A%2F%2Flocalhost%3A53692%2Fcallback";
const scope_encoded = "org%3Acreate_api_key%20user%3Aprofile%20user%3Ainference" ++
    "%20user%3Asessions%3Aclaude_code%20user%3Amcp_servers%20user%3Afile_upload";
const refresh_margin_ms = 5 * 60 * 1000;
const profile_response_bytes_max = 256 * 1024;

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    /// The absolute epoch milliseconds at which `access` counts as stale.
    expires_ms: i64,
    /// The stable account and organization markers from the OAuth profile.
    /// Null keeps credentials from older Drinky versions usable.
    account_uuid: ?[]const u8 = null,
    organization_uuid: ?[]const u8 = null,

    pub fn deinit(self: Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
        if (self.account_uuid) |account_uuid| gpa.free(account_uuid);
        if (self.organization_uuid) |organization_uuid| gpa.free(organization_uuid);
    }

    /// Return true only when both complete principal markers match. An unknown
    /// marker needs the safe replacement path.
    pub fn samePrincipal(self: *const Tokens, other: *const Tokens) bool {
        const account_uuid = self.account_uuid orelse return false;
        const other_account_uuid = other.account_uuid orelse return false;
        const organization_uuid = self.organization_uuid orelse return false;
        const other_organization_uuid = other.organization_uuid orelse return false;
        return std.mem.eql(u8, account_uuid, other_account_uuid) and
            std.mem.eql(u8, organization_uuid, other_organization_uuid);
    }
};

/// The stable principal markers returned by Anthropic's OAuth profile endpoint.
pub const Identity = struct {
    account_uuid: []const u8,
    organization_uuid: []const u8,

    pub fn deinit(self: Identity, gpa: std.mem.Allocator) void {
        gpa.free(self.account_uuid);
        gpa.free(self.organization_uuid);
    }
};

/// The browser authorize URL for `code`. The caller frees the result.
pub fn authorizeUrl(gpa: std.mem.Allocator, code: *const oauth_wire.Pkce) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        authorize_url ++ "?code=true&client_id=" ++ client_id ++
            "&response_type=code&redirect_uri=" ++ redirect_encoded ++
            "&scope=" ++ scope_encoded ++
            "&code_challenge={s}&code_challenge_method=S256&state={s}",
        .{ code.challenge, code.verifier },
    );
}

/// The authorization grant traded for tokens: the callback's hostile `code` and
/// `state` strings plus the local PKCE `verifier`.
pub const Grant = struct {
    code: []const u8,
    state: []const u8,
    verifier: []const u8,
};

/// Exchange an authorization grant for tokens. The caller frees the result.
pub fn exchange(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts, grant: Grant) !Tokens {
    const body = try exchangeBody(gpa, grant);
    defer gpa.free(body);
    return post(gpa, io, timeouts, body);
}

/// The exchange body via the JSON serializer, so hostile callback bytes cannot
/// inject members into the token request. The caller frees the result.
fn exchangeBody(gpa: std.mem.Allocator, grant: Grant) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "authorization_code",
        .client_id = client_id,
        .code = grant.code,
        .state = grant.state,
        .redirect_uri = redirect_uri,
        .code_verifier = grant.verifier,
    }, .{});
}

/// Trade a refresh token for a fresh access token. The caller frees the result.
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

/// Fetch the stable account and organization markers for an access token.
/// Claude Code uses this private endpoint for its OAuth account profile.
pub fn identity(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    access_token: []const u8,
) !Identity {
    var out: ?Identity = null;
    net.withTimeout(io, timeouts.connect_ms, fetchIdentityInto, .{
        gpa,
        io,
        access_token,
        &out,
    }) catch |err| {
        if (out) |found| found.deinit(gpa);
        return err;
    };
    return out orelse error.ProfileRequestFailed;
}

fn fetchIdentityInto(
    gpa: std.mem.Allocator,
    io: std.Io,
    access_token: []const u8,
    out: *?Identity,
) !void {
    if (!net.validHeaderValue(access_token)) return error.BadCredentials;
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{access_token});
    defer gpa.free(authorization);

    const uri = try std.Uri.parse(profile_url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    var request = try client.request(.GET, uri, .{
        .headers = .{ .authorization = .{ .override = authorization } },
        .extra_headers = &extra_headers,
        .redirect_behavior = .not_allowed,
    });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [2048]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.ProfileRequestFailed;

    const decompress_buffer = try net.decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const body = reader.allocRemaining(gpa, .limited(profile_response_bytes_max)) catch |err|
        switch (err) {
            error.StreamTooLong => return error.ProfileResponseTooLarge,
            else => return err,
        };
    defer gpa.free(body);
    out.* = try parseIdentity(gpa, body);
}

fn parseIdentity(gpa: std.mem.Allocator, body: []const u8) !Identity {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => return error.BadProfileResponse,
        };
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadProfileResponse;
    const account = json.object(object.get("account")) orelse return error.BadProfileResponse;
    const organization = json.object(object.get("organization")) orelse
        return error.BadProfileResponse;
    const account_uuid = json.string(account.get("uuid")) orelse return error.BadProfileResponse;
    const organization_uuid = json.string(organization.get("uuid")) orelse
        return error.BadProfileResponse;

    const account_owned = try gpa.dupe(u8, account_uuid);
    errdefer gpa.free(account_owned);
    return .{
        .account_uuid = account_owned,
        .organization_uuid = try gpa.dupe(u8, organization_uuid),
    };
}

fn post(gpa: std.mem.Allocator, io: std.Io, timeouts: net.Timeouts, body: []const u8) !Tokens {
    const payload = try oauth_wire.post(gpa, io, timeouts, token_url, "application/json", body);
    defer gpa.free(payload);
    return parseTokens(gpa, io, payload);
}

fn parseTokens(gpa: std.mem.Allocator, io: std.Io, body: []const u8) !Tokens {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadTokenResponse;
    const access = json.string(object.get("access_token")) orelse return error.MissingAccessToken;
    const refresh_token = json.string(object.get("refresh_token")) orelse
        return error.MissingRefreshToken;
    const expires_in = json.integer(object.get("expires_in")) orelse return error.MissingExpiry;
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

test authorizeUrl {
    var code: oauth_wire.Pkce = undefined;
    @memset(&code.verifier, 'v');
    @memset(&code.challenge, 'c');
    const url = try authorizeUrl(std.testing.allocator, &code);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, client_id) != null);
}

test exchangeBody {
    const body = try exchangeBody(std.testing.allocator, .{
        .code = "c\"ode",
        .state = "st\\ate",
        .verifier = "verifier",
    });
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
    try std.testing.expect(tokens.account_uuid == null);
    try std.testing.expect(tokens.organization_uuid == null);
}

test "the OAuth profile supplies stable principal markers" {
    const gpa = std.testing.allocator;
    const found = try parseIdentity(gpa,
        \\{"account":{"uuid":"account","email":"a@example.test"},
        \\ "organization":{"uuid":"organization"}}
    );
    defer found.deinit(gpa);
    try std.testing.expectEqualStrings("account", found.account_uuid);
    try std.testing.expectEqualStrings("organization", found.organization_uuid);
    try std.testing.expectError(error.BadProfileResponse, parseIdentity(gpa, "{}"));
}

test "principal comparison needs both stable markers" {
    const known: Tokens = .{
        .access = "a",
        .refresh = "r",
        .expires_ms = 0,
        .account_uuid = "account",
        .organization_uuid = "organization",
    };
    var other = known;
    try std.testing.expect(known.samePrincipal(&other));
    other.organization_uuid = "other";
    try std.testing.expect(!known.samePrincipal(&other));
    other.organization_uuid = null;
    try std.testing.expect(!known.samePrincipal(&other));
}

test "parseTokens rejects an expiry that overflows" {
    const body =
        \\{"access_token":"a","refresh_token":"r","expires_in":9223372036854775807}
    ;
    try std.testing.expectError(
        error.MissingExpiry,
        parseTokens(std.testing.allocator, std.testing.io, body),
    );
}
