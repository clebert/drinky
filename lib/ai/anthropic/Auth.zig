//! The credential lifecycle for subscription OAuth: the shared `auth` lifecycle
//! instantiated over `oauth`'s protocol for the `"anthropic_subscription"`
//! entry in `<home>/.pith/auth.json`.

const std = @import("std");

const auth = @import("../auth.zig");
const json_store = @import("../json_store.zig");
const net = @import("../net.zig");
const oauth_callback = @import("../oauth_callback.zig");
const oauth_wire = @import("../oauth_wire.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

/// The top-level key this account's credentials live under in `auth.json`.
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

/// Load stored tokens. The call returns false when the file is absent or holds
/// no Anthropic subscription credential.
pub fn load(self: *Auth) !bool {
    return auth.load(self, account_key);
}

/// A valid access token. If the stored token has expired, this call refreshes
/// and persists it first.
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

/// Run the interactive OAuth login and return the committed credential's
/// persistence outcome for the caller to present.
pub fn login(self: *Auth, prompt: anytype) !auth.Login {
    return auth.login(self, account_key, oauth, prompt, exchangeRedirect);
}

/// `oauth.exchange` over the received redirect: the code, its `state`, and the
/// PKCE verifier all go into the token request.
fn exchangeRedirect(
    self: *Auth,
    redirect: *const oauth_callback.Redirect,
    pair: *const oauth_wire.Pkce,
) !oauth.Tokens {
    return oauth.exchange(self.gpa, self.io, self.timeouts, .{
        .code = redirect.code,
        .state = redirect.state,
        .verifier = &pair.verifier,
    });
}

/// Drop this account's credentials: clear the in-memory tokens and remove its
/// entry from `auth.json`. The removal preserves every other account's entry.
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

/// A server that has already rotated the refresh token: only the token the
/// store holds now still buys a new credential.
fn grantRotatedRefresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: oauth.Tokens,
) anyerror!oauth.Tokens {
    if (!std.mem.eql(u8, tokens.refresh, "rotated")) return error.TokenRequestFailed;
    return grantRefresh(gpa, io, timeouts, tokens);
}

fn grantRefreshAfterCancel(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: oauth.Tokens,
) anyerror!oauth.Tokens {
    // Park until the test's cancel request lands, then re-arm it: the next
    // cancelation point — without protection, the save — sees the cancel exactly
    // as if it arrived while the refresh response was in flight.
    io.sleep(.fromSeconds(60), .awake) catch io.recancel();
    return grantRefresh(gpa, io, timeouts, tokens);
}

fn refreshUnderCancel(subject: *Auth) anyerror!void {
    const access = try auth.accessToken(subject, account_key, grantRefreshAfterCancel);
    try std.testing.expectEqualStrings("fresh", access);
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
            .refresh = try gpa.dupe(u8, "keep"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    // There is no store file, so the failure has no second token to try.
    try std.testing.expectError(
        error.TokenRequestFailed,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stale", subject.tokens.?.access);
    try std.testing.expectEqualStrings("keep", subject.tokens.?.refresh);

    // The store holds the same refresh token, so the failure is real and stands.
    try auth.save(&subject, account_key);
    try std.testing.expectError(
        error.TokenRequestFailed,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stale", subject.tokens.?.access);
    try std.testing.expectEqualStrings("keep", subject.tokens.?.refresh);
}

// The rotation-staleness bug: the refresh token is single use, so a second Pith
// instance that refreshes first leaves this process with a dead cached token.
// Every turn then fails until a restart. A failed refresh must reload the store
// and try the token it finds there once.
test "a refresh token rotated by another instance recovers without a restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    try json_store.save(gpa, io, path, account_key, .{
        .access = "rotated_access",
        .refresh = "rotated",
        .expires_ms = 0,
    }, .{});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "dead"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectEqualStrings(
        "fresh",
        try auth.accessToken(&subject, account_key, grantRotatedRefresh),
    );
    try std.testing.expectEqualStrings("next", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);
}

// The retry is the one path that changes the tokens in memory and still fails.
// The stored credential is the only one that can still be live, so the reload
// keeps it. The caller sees the refusal, and the store file stays untouched.
test "a retry that also fails keeps the credential the store holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    try json_store.save(gpa, io, path, account_key, .{
        .access = "stored_access",
        .refresh = "stored",
        .expires_ms = 0,
    }, .{});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "dead"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectError(
        error.TokenRequestFailed,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stored_access", subject.tokens.?.access);
    try std.testing.expectEqualStrings("stored", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("stored", file.entry(account_key).?.get("refresh").?.string);
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

    var file = (try json_store.open(gpa, std.testing.io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);
}

// The rotation-durability race: the server has already consumed the old refresh
// token when a cancel (the catalog fetch's timeout, a turn cancel) lands at the
// save. The commit+save runs cancel-protected, so the rotated credential still
// reaches memory and disk. The cancel fires at the caller's next cancelation
// point.
test "a cancel landing at the save cannot lose the rotated credential" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "old"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    var future = try io.concurrent(refreshUnderCancel, .{&subject});
    try future.cancel(io);

    try std.testing.expectEqualStrings("next", subject.tokens.?.refresh);
    var file = (try json_store.open(gpa, io, path)).?;
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
