//! The credential lifecycle for the OpenRouter OAuth account: the shared
//! `auth` login and store instantiated over `oauth`'s protocol for the
//! `"openrouter-api-login"` entry in `<home>/.drinky/auth.json`. The login mints an
//! API key and stores it. The key needs no refresh, so there is no
//! `accessToken`: `apiKey` returns the stored key for the `Bearer` header.

const std = @import("std");

const auth = @import("../auth.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const oauth_callback = @import("../oauth_callback.zig");
const oauth_wire = @import("../oauth_wire.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

/// The top-level key this account's credential lives under in `auth.json`.
const account_key = llm.Account.openrouter_api_login.id();

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
path: []const u8,
tokens: ?oauth.Tokens,
/// Whether a committed credential still needs a store retry. The shared
/// lifecycle keeps this field for every account, and a busy store sets it. A
/// minted key never refreshes, so nothing reads it back here: the key of a
/// failed save lives in memory until Drinky exits.
save_pending: bool = false,

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    timeouts: net.Timeouts,
) !Auth {
    const path = try std.fs.path.join(gpa, &.{ home, ".drinky", "auth.json" });
    return .{ .gpa = gpa, .io = io, .timeouts = timeouts, .path = path, .tokens = null };
}

pub fn deinit(self: *Auth) void {
    if (self.tokens) |tokens| tokens.deinit(self.gpa);
    self.gpa.free(self.path);
}

/// Load the stored key. The call returns false when the file is absent or holds
/// no OpenRouter OAuth credential.
pub fn load(self: *Auth) !bool {
    return auth.load(self, account_key);
}

/// The stored API key for the `Bearer` header, or null when signed out.
pub fn apiKey(self: *const Auth) ?[]const u8 {
    const tokens = self.tokens orelse return null;
    return tokens.api_key;
}

/// Run the interactive OAuth login, mint the API key, and return the committed
/// credential's persistence outcome for the caller to present.
pub fn login(self: *Auth, prompt: anytype) !auth.Login {
    return auth.login(self, account_key, oauth, prompt, exchangeRedirect);
}

/// `oauth.exchange` over the received redirect. The flow carries no `state`.
fn exchangeRedirect(
    self: *Auth,
    redirect: *const oauth_callback.Redirect,
    pair: *const oauth_wire.Pkce,
) !oauth.Tokens {
    return oauth.exchange(self.gpa, self.io, self.timeouts, &.{
        .code = redirect.code,
        .verifier = &pair.verifier,
    });
}

/// Drop this account's credential: clear the in-memory key and remove its entry
/// from `auth.json`. The removal preserves every other account's entry.
pub fn logout(self: *Auth) !void {
    return auth.logout(self, account_key);
}

test "load reads the stored api key" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"openrouter-api-login\":{\"api_key\":\"sk-or-v1-x\"}}",
    });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = null,
    };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);
    try std.testing.expect(try subject.load());
    try std.testing.expectEqualStrings("sk-or-v1-x", subject.apiKey().?);
}

test "load rejects an entry missing the api key" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"openrouter-api-login\":{}}",
    });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = null,
    };
    try std.testing.expectError(error.BadCredentials, subject.load());
    try std.testing.expect(subject.apiKey() == null);
}
