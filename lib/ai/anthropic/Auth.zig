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
/// Whether a refreshed credential still needs a store retry.
save_pending: bool = false,

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
    return refreshTokensWith(gpa, io, timeouts, tokens, oauth.refresh, oauth.identity);
}

/// The refresh over its two protocol calls, so a test pins the credential
/// lifecycle without the network.
fn refreshTokensWith(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: oauth.Tokens,
    comptime refreshFn: anytype,
    comptime identityFn: anytype,
) !oauth.Tokens {
    var fresh = try refreshFn(gpa, io, timeouts, tokens.refresh);
    errdefer fresh.deinit(gpa);
    try copyIdentity(gpa, &tokens, &fresh);
    healIdentity(gpa, io, timeouts, &fresh, identityFn);
    return fresh;
}

/// Give a credential from before the principal markers its own markers, so a
/// store copy another instance saved stays comparable. A marked credential
/// makes no request.
///
/// The refresh already consumed the stored token, so the fresh credential must
/// survive this best-effort request: every failure leaves it unmarked and
/// usable. The request stays cancelable, because blocking a cancel here holds
/// the interface for the whole connect timeout, which a configured zero makes
/// unbounded. A cancel is re-armed instead: `accessToken` installs and saves
/// the credential cancel-protected, and the request after that save is the next
/// cancellation point. A login answers a cancel differently (see
/// `attachIdentity`), because its credential replaces nothing.
fn healIdentity(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    fresh: *oauth.Tokens,
    comptime identityFn: anytype,
) void {
    if (fresh.account_uuid != null and fresh.organization_uuid != null) return;
    const found = identityFn(gpa, io, timeouts, fresh.access) catch |err| {
        if (err == error.Canceled) io.recancel();
        return;
    };
    if (fresh.account_uuid) |account_uuid| gpa.free(account_uuid);
    if (fresh.organization_uuid) |organization_uuid| gpa.free(organization_uuid);
    fresh.account_uuid = found.account_uuid;
    fresh.organization_uuid = found.organization_uuid;
}

fn copyIdentity(
    gpa: std.mem.Allocator,
    source: *const oauth.Tokens,
    target: *oauth.Tokens,
) !void {
    target.account_uuid = if (source.account_uuid) |account_uuid|
        try gpa.dupe(u8, account_uuid)
    else
        null;
    target.organization_uuid = if (source.organization_uuid) |organization_uuid|
        try gpa.dupe(u8, organization_uuid)
    else
        null;
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
    var tokens = try oauth.exchange(self.gpa, self.io, self.timeouts, .{
        .code = redirect.code,
        .state = redirect.state,
        .verifier = &pair.verifier,
    });
    errdefer tokens.deinit(self.gpa);
    try attachIdentity(self.gpa, self.io, self.timeouts, &tokens, oauth.identity);
    return tokens;
}

/// Mark a credential the login just exchanged. An ordinary profile failure only
/// costs the markers, so the login keeps the credential and commits it. A cancel
/// is the user's word on the whole sign-in, and it ends the login: this
/// credential is new, so nothing breaks when the caller frees it, and the next
/// `/login` mints another one. A refresh cannot answer a cancel this way, which
/// is why `healIdentity` re-arms one instead.
fn attachIdentity(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: *oauth.Tokens,
    comptime identityFn: anytype,
) !void {
    const found = identityFn(gpa, io, timeouts, tokens.access) catch |err| {
        if (err == error.Canceled) return err;
        return;
    };
    tokens.account_uuid = found.account_uuid;
    tokens.organization_uuid = found.organization_uuid;
}

/// Drop this account's credentials: clear the in-memory tokens and remove its
/// entry from `auth.json`. The removal preserves every other account's entry.
pub fn logout(self: *Auth) !void {
    return auth.logout(self, account_key);
}

/// Forget a rejected refresh credential, or reload its stored replacement.
pub fn invalidate(self: *Auth) !bool {
    return auth.invalidate(self, account_key);
}

fn refuseRefresh(
    _: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: oauth.Tokens,
) anyerror!oauth.Tokens {
    return error.TokenGrantRejected;
}

fn grantIdentity(
    gpa: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: []const u8,
) anyerror!oauth.Identity {
    const account_uuid = try gpa.dupe(u8, "healed_account");
    errdefer gpa.free(account_uuid);
    return .{
        .account_uuid = account_uuid,
        .organization_uuid = try gpa.dupe(u8, "healed_organization"),
    };
}

fn refuseIdentity(
    _: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: []const u8,
) anyerror!oauth.Identity {
    return error.ProfileRequestFailed;
}

fn cancelIdentity(
    _: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: []const u8,
) anyerror!oauth.Identity {
    return error.Canceled;
}

test "a canceled profile ends the login, and an ordinary failure does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The markers are optional, so the login keeps this credential and commits it.
    var kept: oauth.Tokens = .{
        .access = try gpa.dupe(u8, "exchanged"),
        .refresh = try gpa.dupe(u8, "exchanged_refresh"),
        .expires_ms = 0,
    };
    defer kept.deinit(gpa);
    try attachIdentity(gpa, io, .{}, &kept, refuseIdentity);
    try std.testing.expect(kept.account_uuid == null);
    try std.testing.expectEqualStrings("exchanged", kept.access);

    // A cancel ends the sign-in. The caller frees the exchanged credential,
    // which no account depends on.
    var canceled: oauth.Tokens = .{
        .access = try gpa.dupe(u8, "exchanged"),
        .refresh = try gpa.dupe(u8, "exchanged_refresh"),
        .expires_ms = 0,
    };
    defer canceled.deinit(gpa);
    try std.testing.expectError(
        error.Canceled,
        attachIdentity(gpa, io, .{}, &canceled, cancelIdentity),
    );

    // The profile marks a credential the login can compare later.
    var marked: oauth.Tokens = .{
        .access = try gpa.dupe(u8, "exchanged"),
        .refresh = try gpa.dupe(u8, "exchanged_refresh"),
        .expires_ms = 0,
    };
    defer marked.deinit(gpa);
    try attachIdentity(gpa, io, .{}, &marked, grantIdentity);
    try std.testing.expectEqualStrings("healed_account", marked.account_uuid.?);
}

fn grantTokens(
    gpa: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: []const u8,
) anyerror!oauth.Tokens {
    const access = try gpa.dupe(u8, "fresh");
    errdefer gpa.free(access);
    return .{
        .access = access,
        .refresh = try gpa.dupe(u8, "next"),
        .expires_ms = std.math.maxInt(i64),
    };
}

test "a refresh carries the markers over, and heals a credential without them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var unmarked: oauth.Tokens = .{
        .access = try gpa.dupe(u8, "stale"),
        .refresh = try gpa.dupe(u8, "old"),
        .expires_ms = 0,
    };
    defer unmarked.deinit(gpa);
    const healed = try refreshTokensWith(gpa, io, .{}, unmarked, grantTokens, grantIdentity);
    defer healed.deinit(gpa);
    try std.testing.expectEqualStrings("next", healed.refresh);
    try std.testing.expectEqualStrings("healed_account", healed.account_uuid.?);

    var marked: oauth.Tokens = .{
        .access = try gpa.dupe(u8, "stale"),
        .refresh = try gpa.dupe(u8, "old"),
        .expires_ms = 0,
        .account_uuid = try gpa.dupe(u8, "account"),
        .organization_uuid = try gpa.dupe(u8, "organization"),
    };
    defer marked.deinit(gpa);
    const carried = try refreshTokensWith(gpa, io, .{}, marked, grantTokens, grantIdentity);
    defer carried.deinit(gpa);
    try std.testing.expectEqualStrings("account", carried.account_uuid.?);
}

test "a credential from before the markers heals at its next refresh" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A refused profile leaves the refreshed credential unmarked and usable.
    var unmarked: oauth.Tokens = .{
        .access = try gpa.dupe(u8, "fresh"),
        .refresh = try gpa.dupe(u8, "next"),
        .expires_ms = 0,
    };
    defer unmarked.deinit(gpa);
    healIdentity(gpa, io, .{}, &unmarked, refuseIdentity);
    try std.testing.expect(unmarked.account_uuid == null);
    try std.testing.expectEqualStrings("fresh", unmarked.access);

    // The profile fills both markers, so the next cross-instance handoff can
    // compare principals instead of taking the replacement path.
    healIdentity(gpa, io, .{}, &unmarked, grantIdentity);
    try std.testing.expectEqualStrings("healed_account", unmarked.account_uuid.?);
    try std.testing.expectEqualStrings("healed_organization", unmarked.organization_uuid.?);

    // A marked credential keeps its own markers and makes no request.
    var marked: oauth.Tokens = .{
        .access = try gpa.dupe(u8, "fresh"),
        .refresh = try gpa.dupe(u8, "next"),
        .expires_ms = 0,
        .account_uuid = try gpa.dupe(u8, "account"),
        .organization_uuid = try gpa.dupe(u8, "organization"),
    };
    defer marked.deinit(gpa);
    healIdentity(gpa, io, .{}, &marked, grantIdentity);
    try std.testing.expectEqualStrings("account", marked.account_uuid.?);
}

fn grantRefresh(
    gpa: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    tokens: oauth.Tokens,
) anyerror!oauth.Tokens {
    const access = try gpa.dupe(u8, "fresh");
    const refresh = gpa.dupe(u8, "next") catch |err| {
        gpa.free(access);
        return err;
    };
    var fresh: oauth.Tokens = .{
        .access = access,
        .refresh = refresh,
        .expires_ms = std.math.maxInt(i64),
    };
    errdefer fresh.deinit(gpa);
    try copyIdentity(gpa, &tokens, &fresh);
    return fresh;
}

/// A server that has already rotated the refresh token: only the token the
/// store holds now still buys a new credential.
fn grantRotatedRefresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: oauth.Tokens,
) anyerror!oauth.Tokens {
    if (!std.mem.eql(u8, tokens.refresh, "rotated")) return error.TokenGrantRejected;
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
        error.TokenGrantRejected,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stale", subject.tokens.?.access);
    try std.testing.expectEqualStrings("keep", subject.tokens.?.refresh);

    // The store holds the same refresh token, so the failure is real and stands.
    try auth.save(&subject, account_key);
    try std.testing.expectError(
        error.TokenGrantRejected,
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
        .account_uuid = "account",
        .organization_uuid = "organization",
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
            .account_uuid = try gpa.dupe(u8, "account"),
            .organization_uuid = try gpa.dupe(u8, "organization"),
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectEqualStrings(
        "fresh",
        try auth.accessToken(&subject, account_key, grantRotatedRefresh),
    );
    try std.testing.expectEqualStrings("next", subject.tokens.?.refresh);
    try std.testing.expectEqualStrings("account", subject.tokens.?.account_uuid.?);
    try std.testing.expectEqualStrings("organization", subject.tokens.?.organization_uuid.?);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);
}

test "a stored credential for another principal stops before a model request" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    try json_store.save(gpa, io, path, account_key, .{
        .access = "replacement_access",
        .refresh = "replacement_refresh",
        .expires_ms = std.math.maxInt(i64),
        .account_uuid = "other_account",
        .organization_uuid = "other_organization",
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
            .account_uuid = try gpa.dupe(u8, "account"),
            .organization_uuid = try gpa.dupe(u8, "organization"),
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectError(
        error.CredentialReplaced,
        auth.accessToken(&subject, account_key, grantRotatedRefresh),
    );
    try std.testing.expectEqualStrings("replacement_access", subject.tokens.?.access);
    try std.testing.expectEqualStrings("other_account", subject.tokens.?.account_uuid.?);
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
        .account_uuid = "account",
        .organization_uuid = "organization",
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
            .account_uuid = try gpa.dupe(u8, "account"),
            .organization_uuid = try gpa.dupe(u8, "organization"),
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectError(
        error.TokenGrantRejected,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stored_access", subject.tokens.?.access);
    try std.testing.expectEqualStrings("stored", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("stored", file.entry(account_key).?.get("refresh").?.string);
}

test "invalidation preserves a newer refresh token from another instance" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    try json_store.save(gpa, io, path, account_key, .{
        .access = "new_access",
        .refresh = "new_refresh",
        .expires_ms = std.math.maxInt(i64),
    }, .{});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "rejected_access"),
            .refresh = try gpa.dupe(u8, "rejected_refresh"),
            .expires_ms = 0,
        },
    };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);

    try std.testing.expect(try subject.invalidate());
    try std.testing.expectEqualStrings("new_refresh", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings(
        "new_refresh",
        file.entry(account_key).?.get("refresh").?.string,
    );
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

test "a busy store retries a refreshed credential before the next request" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
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

    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
    defer gpa.free(lock_path);
    {
        var held = try std.Io.Dir.cwd().createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = @enumFromInt(0o600),
        });
        defer held.close(io);
        try std.testing.expectError(
            error.StoreBusy,
            auth.accessToken(&subject, account_key, grantRefresh),
        );
        try std.testing.expect(subject.save_pending);
        try std.testing.expectEqualStrings("fresh", subject.tokens.?.access);
    }

    try std.testing.expectEqualStrings(
        "fresh",
        try auth.accessToken(&subject, account_key, grantRefresh),
    );
    try std.testing.expect(!subject.save_pending);
    var file = (try json_store.open(gpa, io, path)).?;
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

test "load accepts a credential from before principal markers" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data =
        \\{"anthropic_subscription":
        \\  {"access":"a","refresh":"r","expires_ms":1}}
        ,
    });
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    var subject: Auth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = null,
    };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);
    try std.testing.expect(try subject.load());
    try std.testing.expect(subject.tokens.?.account_uuid == null);
    try std.testing.expect(subject.tokens.?.organization_uuid == null);
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
