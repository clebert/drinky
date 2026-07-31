//! The Anthropic subscription OAuth protocol: PKCE generation, the authorize
//! URL, and the token exchange/refresh HTTP calls. Credential storage and the
//! login orchestration live in `Auth`. This module only speaks the protocol.

const std = @import("std");

const json = @import("../json.zig");
const net = @import("../net.zig");
const oauth_wire = @import("../oauth_wire.zig");

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const authorize_url = "https://claude.ai/oauth/authorize";
const token_url = "https://platform.claude.com/v1/oauth/token";
pub const callback_port = 53692;
const redirect_uri = "http://localhost:53692/callback";

const redirect_encoded = "http%3A%2F%2Flocalhost%3A53692%2Fcallback";
const scope_encoded = "org%3Acreate_api_key%20user%3Aprofile%20user%3Ainference" ++
    "%20user%3Asessions%3Aclaude_code%20user%3Amcp_servers%20user%3Afile_upload";
const refresh_margin_ms = 5 * 60 * 1000;

pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    /// The absolute epoch milliseconds at which `access` counts as stale.
    expires_ms: i64,

    pub fn deinit(self: Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
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
