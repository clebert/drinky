//! Credential lifecycle for subscription OAuth: the shared `auth` lifecycle
//! instantiated over `oauth`'s protocol for the `"anthropic_subscription"`
//! entry in `<home>/.pith/auth.json`.

const std = @import("std");

const auth = @import("../auth.zig");
const auth_store = @import("../auth_store.zig");
const net = @import("../net.zig");
const oauth_callback = @import("../oauth_callback.zig");
const oauth_wire = @import("../oauth_wire.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

/// Top-level key this account's credentials live under in `auth.json`.
const account_key = "anthropic_subscription";

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
path: []const u8,
tokens: ?oauth.Tokens,

pub fn init(gpa: std.mem.Allocator, io: std.Io, home: []const u8, timeouts: net.Timeouts) !Auth {
    const path = try std.fs.path.join(gpa, &.{ home, ".pith", "auth.json" });
    return .{ .gpa = gpa, .io = io, .timeouts = timeouts, .path = path, .tokens = null };
}

pub fn deinit(self: *Auth) void {
    if (self.tokens) |tokens| tokens.deinit(self.gpa);
    self.gpa.free(self.path);
}

/// Load stored tokens. Returns false when the file is absent or holds no
/// Anthropic subscription credential.
pub fn load(self: *Auth) !bool {
    return auth.load(self, account_key);
}

/// A valid access token, refreshing and persisting it first if it has expired.
pub fn accessToken(self: *Auth) ![]const u8 {
    return auth.accessToken(self, account_key, refreshTokens);
}

/// `oauth.refresh` in the shared lifecycle's shape (which passes whole tokens).
fn refreshTokens(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: oauth.Tokens,
) !oauth.Tokens {
    return oauth.refresh(gpa, io, timeouts, tokens.refresh);
}

/// Run the interactive OAuth login, reporting runtime text through the caller's
/// presentation boundary.
pub fn login(self: *Auth, prompt: anytype) !void {
    return auth.login(self, account_key, oauth, prompt, exchangeRedirect);
}

/// `oauth.exchange` over the received redirect: the code, its `state`, and the
/// PKCE verifier all go into the token request.
fn exchangeRedirect(
    self: *Auth,
    redirect: oauth_callback.Redirect,
    pair: *const oauth_wire.Pkce,
) !oauth.Tokens {
    return oauth.exchange(self.gpa, self.io, self.timeouts, .{
        .code = redirect.code,
        .state = redirect.state,
        .verifier = &pair.verifier,
    });
}

/// Drop this account's credentials: clear the in-memory tokens and remove its
/// entry from `auth.json`, preserving every other account's entry.
pub fn logout(self: *Auth) !void {
    return auth.logout(self, account_key);
}

fn refuseRefresh(
    _: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: oauth.Tokens,
) anyerror!oauth.Tokens {
    return error.TokenRequestFailed;
}

fn grantRefresh(
    gpa: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: oauth.Tokens,
) anyerror!oauth.Tokens {
    return .{
        .access = try gpa.dupe(u8, "fresh"),
        .refresh = try gpa.dupe(u8, "next"),
        .expires_ms = std.math.maxInt(i64),
    };
}

test "a live access token is returned without a refresh" {
    var subject: Auth = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .path = "",
        .tokens = .{ .access = "live", .refresh = "keep", .expires_ms = std.math.maxInt(i64) },
    };
    try std.testing.expectEqualStrings(
        "live",
        try auth.accessToken(&subject, account_key, refuseRefresh),
    );
}

test "a failed refresh leaves the stored credential intact" {
    var subject: Auth = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .path = "",
        .tokens = .{ .access = "stale", .refresh = "keep", .expires_ms = 0 },
    };
    try std.testing.expectError(
        error.TokenRequestFailed,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stale", subject.tokens.?.access);
    try std.testing.expectEqualStrings("keep", subject.tokens.?.refresh);
}

test "an expired access token is refreshed and re-persisted" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "old"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectEqualStrings(
        "fresh",
        try auth.accessToken(&subject, account_key, grantRefresh),
    );
    try std.testing.expectEqualStrings("next", subject.tokens.?.refresh);

    var file = (try auth_store.open(gpa, std.testing.io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);
}

test "load rejects an entry missing a credential field" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"anthropic_subscription\":{\"access\":\"a\"}}",
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
    try std.testing.expect(subject.tokens == null);
}
