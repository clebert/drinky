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
pub fn accessToken(auth: anytype, comptime account_key: []const u8, comptime refreshFn: anytype) ![]const u8 {
    const tokens = auth.tokens orelse return error.NotAuthenticated;
    const now_ms = std.Io.Timestamp.now(auth.io, .real).toMilliseconds();
    if (now_ms >= tokens.expires_ms) {
        const fresh = try refreshFn(auth.gpa, auth.io, auth.timeouts, tokens);
        tokens.deinit(auth.gpa);
        auth.tokens = fresh;
        try save(auth, account_key);
    }
    return auth.tokens.?.access;
}

/// Run the interactive OAuth login, reporting runtime text through the caller's
/// presentation boundary. `oauth` is the provider protocol module (PKCE, the
/// authorize URL, the callback port); `exchangeFn(auth, callback, pair)` trades
/// the received callback for tokens, applying any provider-specific checks first.
pub fn login(
    auth: anytype,
    comptime account_key: []const u8,
    comptime oauth: type,
    comptime exchangeFn: anytype,
    prompt: anytype,
) !void {
    const pair = oauth.pkce(auth.io);
    const url = try oauth.authorizeUrl(auth.gpa, &pair);
    defer auth.gpa.free(url);

    const callback = try oauth_login.receive(oauth_callback.Callback, &.{
        .url = url,
        .prompt = prompt,
        .browser = oauth_login.Browser{ .io = auth.io },
        .callback = CallbackSource{ .gpa = auth.gpa, .io = auth.io, .port = oauth.callback_port },
    });
    defer {
        auth.gpa.free(callback.code);
        auth.gpa.free(callback.state);
    }

    const tokens = try exchangeFn(auth, callback, &pair);
    if (auth.tokens) |old| old.deinit(auth.gpa);
    auth.tokens = tokens;
    try save(auth, account_key);

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

    pub fn receive(self: *CallbackListener) !oauth_callback.Callback {
        return oauth_callback.receive(self.gpa, self.io, &self.server);
    }
};
