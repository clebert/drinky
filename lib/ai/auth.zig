//! The credential lifecycle both subscription OAuth accounts share: load and
//! persist a provider's tokens under its `account_key` in the keyed `auth.json`
//! store, refresh a stale access token on demand, and run the interactive login
//! (browser + loopback callback). Generic over each provider's `Auth` file
//! struct (`gpa`/`io`/`timeouts`/`path`/`tokens` fields): the on-disk entry
//! mirrors the provider's `Tokens` fields, and every save is a load-merge-write
//! through `auth_store` that never clobbers another account's entry.

const std = @import("std");

const auth_store = @import("auth_store.zig");
const oauth_callback = @import("oauth_callback.zig");
const oauth_login = @import("oauth_login.zig");
const oauth_wire = @import("oauth_wire.zig");

/// Load stored tokens, reading each `Tokens` field from the entry by name.
/// Returns false when the file is absent or holds no `account_key` entry (the
/// account is simply signed out).
pub fn load(auth: anytype, comptime account_key: []const u8) !bool {
    var file = (try auth_store.open(auth.gpa, auth.io, auth.path)) orelse return false;
    defer file.deinit();
    const entry = file.entry(account_key) orelse return false;

    const Tokens = @typeInfo(@TypeOf(auth.tokens)).optional.child;
    var tokens: Tokens = undefined;
    var filled: usize = 0;
    errdefer {
        inline for (@typeInfo(Tokens).@"struct".fields, 0..) |field, i| {
            if (comptime field.type == []const u8) {
                if (i < filled) auth.gpa.free(@field(tokens, field.name));
            }
        }
    }
    inline for (@typeInfo(Tokens).@"struct".fields, 0..) |field, i| {
        const value = entry.get(field.name) orelse return error.BadCredentials;
        @field(tokens, field.name) = if (comptime field.type == []const u8) switch (value) {
            .string => |string| try auth.gpa.dupe(u8, string),
            else => return error.BadCredentials,
        } else switch (value) {
            .integer => |integer| integer,
            else => return error.BadCredentials,
        };
        filled = i + 1;
    }
    auth.tokens = tokens;
    return true;
}

/// A valid access token, refreshing and persisting it first if it has expired.
/// `refreshFn` has the provider refresher's `(gpa, io, timeouts, tokens)` shape,
/// so tests pin the credential lifecycle without the network. Refresh before
/// touching the stored tokens: a failed refresh leaves the stored credential
/// intact.
pub fn accessToken(
    auth: anytype,
    comptime account_key: []const u8,
    comptime refreshFn: anytype,
) ![]const u8 {
    const tokens = auth.tokens orelse return error.NotAuthenticated;
    const now_ms = std.Io.Timestamp.now(auth.io, .real).toMilliseconds();
    if (now_ms >= tokens.expires_ms) {
        const fresh = try refreshFn(auth.gpa, auth.io, auth.timeouts, tokens);
        // The refresh consumed the stored (single-use) refresh token server-side,
        // so `fresh` is now the only usable credential: block cancellation until
        // it is committed and persisted, or a cancel landing at the save (the
        // catalog fetch runs `accessToken` under a timeout) would lose it.
        const protection = auth.io.swapCancelProtection(.blocked);
        defer _ = auth.io.swapCancelProtection(protection);
        tokens.deinit(auth.gpa);
        auth.tokens = fresh;
        try save(auth, account_key);
    }
    return auth.tokens.?.access;
}

/// Run the interactive OAuth login, reporting runtime text through the caller's
/// presentation boundary. `oauth` is the provider protocol module (the
/// authorize URL and the callback port); `exchangeFn(auth, redirect, pair)`
/// trades the received redirect for tokens, applying any provider-specific
/// checks first.
pub fn login(
    auth: anytype,
    comptime account_key: []const u8,
    comptime oauth: type,
    prompt: anytype,
    comptime exchangeFn: anytype,
) !void {
    const pair = oauth_wire.pkce(auth.io);
    const url = try oauth.authorizeUrl(auth.gpa, &pair);
    defer auth.gpa.free(url);

    const redirect = try oauth_login.receive(oauth_callback.Redirect, &.{
        .url = url,
        .prompt = prompt,
        .browser = oauth_login.Browser{ .io = auth.io },
        .callback = CallbackSource{ .gpa = auth.gpa, .io = auth.io, .port = oauth.callback_port },
    });
    defer {
        auth.gpa.free(redirect.code);
        auth.gpa.free(redirect.state);
    }

    try commit(auth, account_key, try exchangeFn(auth, redirect, &pair), prompt);
}

/// Install exchanged tokens, persist them, and report. Installed tokens complete
/// the login — the session is signed in with or without persistence — so a failed
/// save warns (`showSaveFailed`: signed in until exit) instead of failing a login
/// whose credential is usable now.
fn commit(auth: anytype, comptime account_key: []const u8, tokens: anytype, prompt: anytype) !void {
    if (auth.tokens) |old| old.deinit(auth.gpa);
    auth.tokens = tokens;
    save(auth, account_key) catch |err| return prompt.showSaveFailed(auth.path, @errorName(err));
    try prompt.showAuthorized(auth.path);
}

/// Drop this account's credentials: clear the in-memory tokens and remove its
/// entry from `auth.json`, preserving every other account's entry.
pub fn logout(auth: anytype, comptime account_key: []const u8) !void {
    // Remove the on-disk entry first: a failed remove then leaves the credentials
    // fully intact (in memory and the caller's readiness flag), so logout is
    // atomic rather than leaving a token-less account still marked authenticated.
    try auth_store.remove(auth.gpa, auth.io, auth.path, account_key);
    if (auth.tokens) |tokens| tokens.deinit(auth.gpa);
    auth.tokens = null;
}

/// Persist the current tokens under `account_key`; the on-disk entry is the
/// `Tokens` fields verbatim.
pub fn save(auth: anytype, comptime account_key: []const u8) !void {
    const tokens = auth.tokens orelse return error.NotAuthenticated;
    try auth_store.save(auth.gpa, auth.io, auth.path, account_key, tokens);
}

const CallbackSource = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    port: u16,

    pub fn listen(self: CallbackSource) !CallbackListener {
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        return .{
            .gpa = self.gpa,
            .io = self.io,
            .server = try address.listen(self.io, .{ .reuse_address = true }),
        };
    }
};

const CallbackListener = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,

    pub fn deinit(self: *CallbackListener) void {
        self.server.deinit(self.io);
    }

    pub fn receive(self: *CallbackListener) !oauth_callback.Redirect {
        return oauth_callback.receive(self.gpa, self.io, &self.server);
    }
};

test "a failed persist warns and keeps the login usable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Tokens = struct {
        access: []const u8,
        expires_ms: i64,

        fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.access);
        }
    };
    const Prompt = struct {
        warned: usize = 0,
        authorized: usize = 0,

        fn showSaveFailed(self: *@This(), _: []const u8, _: []const u8) anyerror!void {
            self.warned += 1;
        }
        fn showAuthorized(self: *@This(), _: []const u8) anyerror!void {
            self.authorized += 1;
        }
    };
    var subject: struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        tokens: ?Tokens,
    } = .{ .gpa = gpa, .io = io, .path = undefined, .tokens = null };
    var prompt: Prompt = .{};

    // A corrupt store refuses the rewrite: the tokens stay installed (the
    // session is signed in), and the failure surfaces as the warning.
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "not json" });
    var bad_buf: [160]u8 = undefined;
    subject.path = try std.fmt.bufPrint(&bad_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    try commit(&subject, "test_account", Tokens{
        .access = try gpa.dupe(u8, "at"),
        .expires_ms = 1,
    }, &prompt);
    defer subject.tokens.?.deinit(gpa);
    try std.testing.expectEqualStrings("at", subject.tokens.?.access);
    try std.testing.expectEqual(@as(usize, 1), prompt.warned);
    try std.testing.expectEqual(@as(usize, 0), prompt.authorized);

    // A writable path persists (creating its parent) and reports authorized.
    var ok_buf: [160]u8 = undefined;
    subject.path =
        try std.fmt.bufPrint(&ok_buf, ".zig-cache/tmp/{s}/ok/auth.json", .{tmp.sub_path});
    try commit(&subject, "test_account", Tokens{
        .access = try gpa.dupe(u8, "at2"),
        .expires_ms = 2,
    }, &prompt);
    try std.testing.expectEqualStrings("at2", subject.tokens.?.access);
    try std.testing.expectEqual(@as(usize, 1), prompt.authorized);
    var file = (try auth_store.open(gpa, io, subject.path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("test_account") != null);
}
