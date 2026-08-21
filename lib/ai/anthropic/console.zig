//! The Anthropic Console OAuth protocol.
//! It uses the subscription PKCE flow on the platform host.
//! The exchange trades the code for a short-lived access token.
//! This token then mints a long-lived API key.
//! Drinky stores only the key and sends it as `x-api-key`.
//! The account needs no token refresh.
//! The key needs the Claude Code system prompt to reach every model.

const std = @import("std");

const json = @import("../json.zig");
const net = @import("../net.zig");
const oauth_wire = @import("../oauth_wire.zig");

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const authorize_url = "https://platform.claude.com/oauth/authorize";
const token_url = "https://platform.claude.com/v1/oauth/token";
const create_key_url = "https://api.anthropic.com/api/oauth/claude_cli/create_api_key";
pub const callback_port = 53693;
const redirect_uri = "http://localhost:53693/callback";

const redirect_encoded = "http%3A%2F%2Flocalhost%3A53693%2Fcallback";
const scope_encoded = "org%3Acreate_api_key%20user%3Aprofile";

/// The minted API key. It never expires in session and needs no refresh, so it
/// is the only stored field.
pub const Tokens = struct {
    api_key: []const u8,

    pub fn deinit(self: Tokens, gpa: std.mem.Allocator) void {
        gpa.free(self.api_key);
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

/// The authorization grant traded for a key: the callback's hostile `code` and
/// `state` strings plus the local PKCE `verifier`.
pub const Grant = struct {
    code: []const u8,
    state: []const u8,
    verifier: []const u8,
};

/// Trade an authorization grant for a minted API key. The exchange gets a
/// short-lived access token, then mints the key with it. The caller frees the
/// result.
pub fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    grant: *const Grant,
) !Tokens {
    const access = try exchangeAccess(gpa, io, timeouts, grant);
    defer gpa.free(access);
    const raw_key = try createApiKey(gpa, io, timeouts, access);
    return .{ .api_key = raw_key };
}

/// Exchange the authorization code for a short-lived access token. The body
/// goes through the JSON serializer, so hostile callback bytes cannot inject
/// members. The caller frees the token.
fn exchangeAccess(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    grant: *const Grant,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .grant_type = "authorization_code",
        .client_id = client_id,
        .code = grant.code,
        .state = grant.state,
        .redirect_uri = redirect_uri,
        .code_verifier = grant.verifier,
    }, .{});
    defer gpa.free(body);
    const payload = try oauth_wire.post(gpa, io, timeouts, token_url, "application/json", body);
    defer gpa.free(payload);
    return parseField(gpa, &.{
        .body = payload,
        .name = "access_token",
        .missing_error = error.MissingAccessToken,
    });
}

/// Mint a long-lived API key with the access token. The mint endpoint reads the
/// `Bearer` authorization and an empty body. The caller frees the key.
fn createApiKey(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    access: []const u8,
) ![]u8 {
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{access});
    defer gpa.free(authorization);
    const payload = try oauth_wire.postBearer(gpa, io, timeouts, &.{
        .url = create_key_url,
        .authorization = authorization,
    });
    defer gpa.free(payload);
    return parseField(gpa, &.{
        .body = payload,
        .name = "raw_key",
        .missing_error = error.MissingApiKey,
    });
}

const FieldOptions = struct {
    body: []const u8,
    name: []const u8,
    missing_error: anyerror,
};

/// Read one owned string from a JSON object response. Return `missing_error`
/// when the named field is absent.
fn parseField(gpa: std.mem.Allocator, options: *const FieldOptions) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, options.body, .{});
    defer parsed.deinit();
    const object = json.object(parsed.value) orelse return error.BadTokenResponse;
    const value = json.string(object.get(options.name)) orelse return options.missing_error;
    return gpa.dupe(u8, value);
}

test authorizeUrl {
    var code: oauth_wire.Pkce = undefined;
    @memset(&code.verifier, 'v');
    @memset(&code.challenge, 'c');
    const url = try authorizeUrl(std.testing.allocator, &code);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, client_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "org%3Acreate_api_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "53693") != null);
}

test parseField {
    const gpa = std.testing.allocator;
    const body = "{\"raw_key\":\"sk-ant-api03-x\"}";
    const key = try parseField(gpa, &.{
        .body = body,
        .name = "raw_key",
        .missing_error = error.MissingApiKey,
    });
    defer gpa.free(key);
    try std.testing.expectEqualStrings("sk-ant-api03-x", key);
    try std.testing.expectError(
        error.MissingApiKey,
        parseField(gpa, &.{
            .body = "{\"other\":\"y\"}",
            .name = "raw_key",
            .missing_error = error.MissingApiKey,
        }),
    );
}
