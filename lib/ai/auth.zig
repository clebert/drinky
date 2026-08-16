//! The credential lifecycle that both subscription OAuth accounts share. Load
//! and persist a provider's tokens under its `account_key` in the keyed
//! `auth.json` store. Refresh a stale access token on demand, and reload the
//! store once when that refresh fails, because the token rotates. Retry a save
//! after temporary store contention. Stop before a model request when the store
//! holds another principal. Run the interactive login (browser + loopback
//! callback). Forget a credential the provider rejected, and keep a replacement
//! another instance saved. Generic over each provider's `Auth` file struct
//! (`gpa`/`io`/`timeouts`/`path`/`tokens` fields): the on-disk entry mirrors the
//! provider's `Tokens` fields.
//! Every save is a load-merge-write through `json_store` that never clobbers
//! another account's entry. A store file Pith cannot parse is a bad credential
//! file, so every call translates that failure into `error.BadCredentials`.

const std = @import("std");

const json_store = @import("json_store.zig");
const oauth_callback = @import("oauth_callback.zig");
const oauth_login = @import("oauth_login.zig");
const oauth_wire = @import("oauth_wire.zig");

/// A committed login's persistence outcome. The credential is live in both
/// cases. `memory_only` carries the save failure for the caller to present.
pub const Login = union(enum) {
    saved: []const u8,
    memory_only: struct {
        path: []const u8,
        save_error: anyerror,
    },
};

fn isOptionalString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child == []const u8,
        else => false,
    };
}

/// Load stored tokens. Read each `Tokens` field from the entry by name.
/// Returns false when the file is absent or holds no `account_key` entry (the
/// account is simply signed out).
pub fn load(auth: anytype, comptime account_key: []const u8) !bool {
    var file = (json_store.open(auth.gpa, auth.io, auth.path) catch |err| switch (err) {
        error.CorruptStore => return error.BadCredentials,
        else => return err,
    }) orelse return false;
    defer file.deinit();
    const entry = file.entry(account_key) orelse return false;

    const Tokens = @typeInfo(@TypeOf(auth.tokens)).optional.child;
    var tokens: Tokens = undefined;
    var filled: usize = 0;
    errdefer {
        inline for (@typeInfo(Tokens).@"struct".fields, 0..) |field, i| {
            if (i < filled) {
                if (comptime field.type == []const u8) {
                    auth.gpa.free(@field(tokens, field.name));
                } else if (comptime isOptionalString(field.type)) {
                    if (@field(tokens, field.name)) |string| auth.gpa.free(string);
                }
            }
        }
    }
    inline for (@typeInfo(Tokens).@"struct".fields, 0..) |field, i| {
        const maybe_value = entry.get(field.name);
        @field(tokens, field.name) = if (comptime field.type == []const u8) value: {
            const value = maybe_value orelse return error.BadCredentials;
            break :value switch (value) {
                .string => |string| try auth.gpa.dupe(u8, string),
                else => return error.BadCredentials,
            };
        } else if (comptime isOptionalString(field.type)) value: {
            const value = maybe_value orelse break :value null;
            break :value switch (value) {
                .string => |string| try auth.gpa.dupe(u8, string),
                .null => null,
                else => return error.BadCredentials,
            };
        } else value: {
            const value = maybe_value orelse return error.BadCredentials;
            break :value switch (value) {
                .integer => |integer| integer,
                else => return error.BadCredentials,
            };
        };
        filled = i + 1;
    }
    // Install last, so a rejected entry leaves any current credential intact.
    if (auth.tokens) |old| old.deinit(auth.gpa);
    auth.tokens = tokens;
    auth.save_pending = false;
    return true;
}

/// A valid access token. If the token has expired, refresh and persist it
/// first. `refreshFn` has the provider refresher's `(gpa, io, timeouts,
/// tokens)` shape, so tests pin the credential lifecycle without the network.
/// The refresh runs before any change to the tokens on disk: a failed refresh
/// leaves the credential in `auth.json` intact. A failed refresh also tries the
/// store once more, because the refresh token rotates. That retry can replace
/// the tokens in memory with the copy the store holds (see `refreshFromStore`).
pub fn accessToken(
    auth: anytype,
    comptime account_key: []const u8,
    comptime refreshFn: anytype,
) ![]const u8 {
    if (auth.save_pending) {
        // The pending token is the only live credential. Keep cancellation from
        // dropping its last save attempt before a model request can use it.
        const protection = auth.io.swapCancelProtection(.blocked);
        defer _ = auth.io.swapCancelProtection(protection);
        try save(auth, account_key);
    }
    const tokens = auth.tokens orelse return error.NotAuthenticated;
    const now_ms = std.Io.Timestamp.now(auth.io, .real).toMilliseconds();
    if (now_ms >= tokens.expires_ms) {
        const fresh = refreshFn(auth.gpa, auth.io, auth.timeouts, tokens) catch |first_error|
            try refreshFromStore(auth, account_key, first_error, refreshFn);
        // The refresh consumed the stored (single-use) refresh token server-side,
        // so `fresh` is now the only usable credential. Block cancellation until
        // it is committed and persisted. Without the block, a cancel that lands
        // at the save (the catalog fetch runs `accessToken` under a timeout)
        // loses the credential.
        const protection = auth.io.swapCancelProtection(.blocked);
        defer _ = auth.io.swapCancelProtection(protection);
        // Read the installed tokens again: a retry through the store replaced them.
        auth.tokens.?.deinit(auth.gpa);
        auth.tokens = fresh;
        try save(auth, account_key);
    }
    return auth.tokens.?.access;
}

/// Inspect the credential that `auth.json` holds after a refresh failure. A
/// different token for the same known principal gets one refresh attempt. A
/// different or unknown principal is installed but stops before a model request.
/// The app then drops the old principal evidence before the user retries.
fn refreshFromStore(
    auth: anytype,
    comptime account_key: []const u8,
    first_error: anyerror,
    comptime refreshFn: anytype,
) anyerror!@typeInfo(@TypeOf(auth.tokens)).optional.child {
    var stored_auth = auth.*;
    stored_auth.tokens = null;
    defer clear(&stored_auth);
    const loaded = load(&stored_auth, account_key) catch return first_error;
    if (!loaded) return first_error;

    const current = &auth.tokens.?;
    const stored = &stored_auth.tokens.?;
    if (std.mem.eql(u8, current.refresh, stored.refresh)) return first_error;
    const same_principal = current.samePrincipal(stored);

    clear(auth);
    auth.tokens = stored_auth.tokens;
    auth.save_pending = stored_auth.save_pending;
    stored_auth.tokens = null;
    if (!same_principal) return error.CredentialReplaced;
    return refreshFn(auth.gpa, auth.io, auth.timeouts, auth.tokens.?);
}

/// Run the interactive OAuth login and report pre-commit runtime text through
/// the caller's presentation boundary. `oauth` is the provider protocol module
/// (the authorize URL and callback port). `exchangeFn(auth, &redirect, pair)`
/// applies provider-specific checks first, then trades the redirect for tokens.
/// Once tokens are installed, the function returns a non-error persistence
/// outcome so callers cannot mistake presentation failure for login failure.
pub fn login(
    auth: anytype,
    comptime account_key: []const u8,
    comptime oauth: type,
    prompt: anytype,
    comptime exchangeFn: anytype,
) !Login {
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

    return commit(auth, account_key, try exchangeFn(auth, &redirect, &pair));
}

/// Install exchanged tokens and report whether they reached disk. Installation
/// completes the login, so no fallible work follows the credential mutation.
fn commit(auth: anytype, comptime account_key: []const u8, tokens: anytype) Login {
    if (auth.tokens) |old| old.deinit(auth.gpa);
    auth.tokens = tokens;
    save(auth, account_key) catch |save_error| return .{ .memory_only = .{
        .path = auth.path,
        .save_error = save_error,
    } };
    return .{ .saved = auth.path };
}

/// Drop this account's credentials: clear the in-memory tokens and remove its
/// entry from `auth.json`. Every other account's entry stays intact.
pub fn logout(auth: anytype, comptime account_key: []const u8) !void {
    // Remove the on-disk entry first. A failed remove leaves the account ready.
    // Logout cannot leave a token-less account marked as authenticated.
    try remove(auth, account_key);
    clear(auth);
}

/// Forget a credential that the provider rejected. Remove the stored entry only
/// while it still holds that token. Reload a replacement from another instance.
pub fn invalidate(auth: anytype, comptime account_key: []const u8) !bool {
    const tokens = auth.tokens orelse return error.NotAuthenticated;
    const removed = json_store.removeMatchingString(
        auth.gpa,
        auth.io,
        auth.path,
        &.{
            .key = account_key,
            .field = "refresh",
            .expected = tokens.refresh,
        },
    ) catch |err| {
        clear(auth);
        return switch (err) {
            error.CorruptStore => error.BadCredentials,
            else => err,
        };
    };
    clear(auth);
    if (removed) return false;
    return load(auth, account_key);
}

fn remove(auth: anytype, comptime account_key: []const u8) !void {
    json_store.remove(auth.gpa, auth.io, auth.path, account_key) catch |err| switch (err) {
        error.CorruptStore => return error.BadCredentials,
        else => return err,
    };
}

fn clear(auth: anytype) void {
    if (auth.tokens) |tokens| tokens.deinit(auth.gpa);
    auth.tokens = null;
    auth.save_pending = false;
}

/// Persist the current tokens under `account_key`. The on-disk entry is the
/// `Tokens` fields verbatim. Lock contention leaves a retry marker in memory.
/// Every other failure clears that marker, because a store Pith cannot write at
/// all must not stop every later turn. The credential then lives in memory
/// until Pith exits, which is what a memory-only login reports.
pub fn save(auth: anytype, comptime account_key: []const u8) !void {
    const tokens = auth.tokens orelse return error.NotAuthenticated;
    json_store.save(auth.gpa, auth.io, auth.path, account_key, tokens, .{}) catch |err| {
        auth.save_pending = err == error.StoreBusy;
        return switch (err) {
            error.CorruptStore => error.BadCredentials,
            else => err,
        };
    };
    auth.save_pending = false;
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

test "a failed persist returns memory-only login and keeps credentials usable" {
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
    var subject: struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        tokens: ?Tokens,
        save_pending: bool = false,
    } = .{ .gpa = gpa, .io = io, .path = undefined, .tokens = null };

    // A corrupt store refuses the rewrite: the replacement remains installed,
    // and the caller receives a committed memory-only outcome to present.
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "not json" });
    var bad_buf: [160]u8 = undefined;
    subject.path = try std.fmt.bufPrint(&bad_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    const memory_only = commit(&subject, "test_account", Tokens{
        .access = try gpa.dupe(u8, "at"),
        .expires_ms = 1,
    });
    defer subject.tokens.?.deinit(gpa);
    try std.testing.expectEqualStrings("at", subject.tokens.?.access);
    switch (memory_only) {
        .memory_only => |failure| {
            try std.testing.expectEqualStrings(subject.path, failure.path);
            try std.testing.expect(@errorName(failure.save_error).len != 0);
        },
        .saved => return error.UnexpectedLoginPersistence,
    }

    // A writable path persists (the save creates its parent) and returns its path.
    var ok_buf: [160]u8 = undefined;
    subject.path =
        try std.fmt.bufPrint(&ok_buf, ".zig-cache/tmp/{s}/ok/auth.json", .{tmp.sub_path});
    const saved = commit(&subject, "test_account", Tokens{
        .access = try gpa.dupe(u8, "at2"),
        .expires_ms = 2,
    });
    try std.testing.expectEqualStrings("at2", subject.tokens.?.access);
    switch (saved) {
        .saved => |path| try std.testing.expectEqualStrings(subject.path, path),
        .memory_only => return error.UnexpectedLoginPersistence,
    }
    var file = (try json_store.open(gpa, io, subject.path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("test_account") != null);
}
