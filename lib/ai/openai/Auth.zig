//! Credential lifecycle for the ChatGPT-subscription (Codex) account: load and
//! persist tokens under `<home>/.pith/auth.json`, refresh a stale access token
//! on demand, and run the interactive login (browser + loopback callback).
//! Speaks the protocol through `oauth`; the keyed on-disk store is shared through
//! `auth_store`.
//!
//! Credentials live under `"openai_subscription"` in the shared keyed file, so a
//! save is a load-merge-write that never clobbers another account's entry.

const std = @import("std");

const auth_store = @import("../auth_store.zig");
const net = @import("../net.zig");
const oauth_callback = @import("../oauth_callback.zig");
const oauth_login = @import("../oauth_login.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

/// Top-level key this account's credentials live under in `auth.json`.
const account_key = "openai_subscription";

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
/// `openai_subscription` entry (this account is simply not logged in).
pub fn load(self: *Auth) !bool {
    var file = (try auth_store.open(self.gpa, self.io, self.path)) orelse return false;
    defer file.deinit();
    const entry = file.entry(account_key) orelse return false;

    const access = try self.gpa.dupe(u8, jsonString(entry, "access") orelse return error.BadCredentials);
    errdefer self.gpa.free(access);
    const refresh = try self.gpa.dupe(u8, jsonString(entry, "refresh") orelse return error.BadCredentials);
    errdefer self.gpa.free(refresh);
    const account_id = try self.gpa.dupe(u8, jsonString(entry, "account_id") orelse return error.BadCredentials);
    errdefer self.gpa.free(account_id);
    const expires_ms = jsonInt(entry, "expires_ms") orelse return error.BadCredentials;

    self.tokens = .{ .access = access, .refresh = refresh, .expires_ms = expires_ms, .account_id = account_id };
    return true;
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInt(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

/// A valid access token, refreshing and persisting it first if it has expired.
pub fn accessToken(self: *Auth) ![]const u8 {
    const tokens = self.tokens orelse return error.NotAuthenticated;
    const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    if (now_ms >= tokens.expires_ms) {
        const fresh = try oauth.refresh(self.gpa, self.io, self.timeouts, tokens);
        tokens.deinit(self.gpa);
        self.tokens = fresh;
        try self.save();
    }
    return self.tokens.?.access;
}

/// The ChatGPT account id sent with each request; empty when not authenticated.
pub fn accountId(self: *const Auth) []const u8 {
    const tokens = self.tokens orelse return "";
    return tokens.account_id;
}

/// Run the interactive OAuth login, reporting runtime text through the caller's
/// presentation boundary.
pub fn login(self: *Auth, prompt: anytype) !void {
    const pair = oauth.pkce(self.io);
    const url = try oauth.authorizeUrl(self.gpa, &pair);
    defer self.gpa.free(url);

    const callback = try oauth_login.receive(oauth_callback.Callback, &.{
        .url = url,
        .prompt = prompt,
        .browser = oauth_login.Browser{ .io = self.io },
        .callback = CallbackSource{ .auth = self },
    });
    defer {
        self.gpa.free(callback.code);
        self.gpa.free(callback.state);
    }
    // The verifier doubles as `state`; a mismatch means the callback is not ours.
    if (!std.mem.eql(u8, callback.state, &pair.verifier)) return error.StateMismatch;

    const tokens = try oauth.exchange(
        self.gpa,
        self.io,
        self.timeouts,
        callback.code,
        &pair.verifier,
    );
    if (self.tokens) |old| old.deinit(self.gpa);
    self.tokens = tokens;
    try self.save();

    try prompt.showAuthorized(self.path);
}

/// Drop this account's credentials: clear the in-memory tokens and remove its
/// entry from `auth.json`, preserving every other account's entry.
pub fn logout(self: *Auth) !void {
    // Remove the on-disk entry first: a failed remove then leaves the credentials
    // fully intact (in memory and the caller's readiness flag), so logout is
    // atomic rather than leaving a token-less account still marked authenticated.
    try auth_store.remove(self.gpa, self.io, self.path, account_key);
    if (self.tokens) |tokens| tokens.deinit(self.gpa);
    self.tokens = null;
}

/// The on-disk shape of this account's entry.
const Entry = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,
    account_id: []const u8,
};

fn save(self: *Auth) !void {
    const tokens = self.tokens orelse return error.NotAuthenticated;
    try auth_store.save(self.gpa, self.io, self.path, account_key, Entry{
        .access = tokens.access,
        .refresh = tokens.refresh,
        .expires_ms = tokens.expires_ms,
        .account_id = tokens.account_id,
    });
}

const CallbackSource = struct {
    auth: *Auth,

    pub fn listen(self: CallbackSource) !CallbackListener {
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(oauth.callback_port) };
        return .{
            .auth = self.auth,
            .server = try address.listen(self.auth.io, .{ .reuse_address = true }),
        };
    }
};

const CallbackListener = struct {
    auth: *Auth,
    server: std.Io.net.Server,

    pub fn deinit(self: *CallbackListener) void {
        self.server.deinit(self.auth.io);
    }

    pub fn receive(self: *CallbackListener) !oauth_callback.Callback {
        return oauth_callback.receive(self.auth.gpa, self.auth.io, &self.server);
    }
};

test "load distinguishes signed out from corrupt credentials" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var auth = try init(gpa, io, home, .{});
    defer auth.deinit();
    // An absent file and a file holding only a sibling account's entry are both
    // simply signed out; an own entry missing a field is corrupt, not ignored.
    try std.testing.expect(!try auth.load());
    try auth_store.save(gpa, io, auth.path, "anthropic_subscription", .{ .access = "a" });
    try std.testing.expect(!try auth.load());
    try auth_store.save(gpa, io, auth.path, account_key, .{ .access = "at", .refresh = "rt" });
    try std.testing.expectError(error.BadCredentials, auth.load());
}

test "save and load round-trip credentials an unexpired token serves unchanged" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var auth = try init(gpa, io, home, .{});
    defer auth.deinit();
    auth.tokens = .{
        .access = try gpa.dupe(u8, "at"),
        .refresh = try gpa.dupe(u8, "rt"),
        .expires_ms = std.math.maxInt(i64),
        .account_id = try gpa.dupe(u8, "acct"),
    };
    try auth.save();

    var loaded = try init(gpa, io, home, .{});
    defer loaded.deinit();
    try std.testing.expect(try loaded.load());
    try std.testing.expectEqualStrings("at", try loaded.accessToken());
    try std.testing.expectEqualStrings("acct", loaded.accountId());
}

test "a signed-out account refuses a token and reports no account id" {
    var auth = try init(std.testing.allocator, undefined, "home", .{});
    defer auth.deinit();
    try std.testing.expectError(error.NotAuthenticated, auth.accessToken());
    try std.testing.expectEqualStrings("", auth.accountId());
}
