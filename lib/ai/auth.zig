//! The credential lifecycle that every subscription OAuth account shares. Load
//! and persist a provider's tokens under its `account_key` in the keyed
//! `auth.json` store. Refresh a stale access token on demand, and reload the
//! store once when that refresh fails, because the token rotates. Retry a save
//! after temporary store contention. Stop before a model request when the store
//! holds another principal. Run the interactive login (browser + loopback
//! callback, or browser + device-code poll). Forget a credential the provider
//! rejected, and keep a replacement another instance saved. Reread the store on
//! demand, so a sign-in or a sign-out in another instance shows here. Generic
//! over each provider's `Auth` file struct
//! (`gpa`/`io`/`timeouts`/`path`/`tokens`/`persistence` fields): the on-disk
//! entry mirrors the provider's `Tokens` fields.
//! Every save is a load-merge-write through `json_store` that never clobbers
//! another account's entry. A store file Drinky cannot parse is a bad credential
//! file, so every call translates that failure into `error.BadCredentials`.

const std = @import("std");

const json_store = @import("json_store.zig");
const net = @import("net.zig");
const oauth_callback = @import("oauth_callback.zig");
const oauth_login = @import("oauth_login.zig");
const oauth_wire = @import("oauth_wire.zig");

/// A committed login's persistence outcome. The credential is live in both
/// cases. `memory_only` carries the save failure for the caller to present. It
/// names every failed save, and `Persistence` tells a busy store, which a retry
/// settles, from a refusal for good.
pub const Login = union(enum) {
    saved: []const u8,
    memory_only: struct {
        path: []const u8,
        save_error: anyerror,
    },
};

/// Where the credential in memory stands against the store. A credential that
/// the store does not hold is the only live copy, so a reread of the store must
/// not replace it.
pub const Persistence = enum {
    /// The store holds this credential, or the memory holds none.
    saved,
    /// A busy store refused the save. The next request or the next reread
    /// tries the save again.
    save_pending,
    /// The store refused the save for good. The credential lives in memory
    /// until Drinky exits, which is what a memory-only login reports.
    memory_only,
};

fn isOptionalString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child == []const u8,
        else => false,
    };
}

/// Open the store file at `path`, or null when it does not exist. A store file
/// Drinky cannot parse is a bad credential file. The caller frees a non-null
/// result with `File.deinit`.
pub fn openStore(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?json_store.File {
    return json_store.open(gpa, io, path) catch |err| switch (err) {
        error.CorruptStore => return error.BadCredentials,
        else => return err,
    };
}

/// Load stored tokens. Returns false when the file is absent or holds no
/// `account_key` entry (the account is simply signed out).
pub fn load(auth: anytype, comptime account_key: []const u8) !bool {
    var file = (try openStore(auth.gpa, auth.io, auth.path)) orelse return false;
    defer file.deinit();
    return loadEntry(auth, account_key, &file);
}

/// Load the tokens of `account_key` from an open store. Read each `Tokens`
/// field from the entry by name. Returns false when the store holds no entry.
fn loadEntry(auth: anytype, comptime account_key: []const u8, file: *const json_store.File) !bool {
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
    auth.persistence = .saved;
    return true;
}

/// What a reread of the store found for one account, against the credential in
/// memory. The reread installs the stored credential for every change but a
/// sign-out, which clears the one in memory.
pub const Change = enum {
    /// The store agrees with the memory: the same credential, or none on both
    /// sides. The credential in memory stays where it is, so a pointer into it
    /// stays valid.
    unchanged,
    /// The store holds a credential, and the memory held none.
    signed_in,
    /// The store holds no credential, and the memory held one.
    signed_out,
    /// The store holds another credential of the same principal, as a refresh
    /// in another instance leaves it.
    rotated,
    /// The store holds the credential of another principal. The caller drops
    /// the evidence of the replaced principal, exactly as after a
    /// `CredentialReplaced` stop.
    replaced,
};

/// Reread the open store `maybe_file`, or an absent store when null, and settle
/// the credential in memory on what it holds, so a sign-in, a sign-out, or a
/// replacement in another instance shows here. The call reports what changed.
/// The caller opens the store once for every account it holds.
///
/// A credential that the store does not hold is the only live copy, so the
/// reread keeps it: nobody signed out, and the entry a refresh replaced is dead.
/// A save that a busy store refused tries again first, because a minted key
/// sends no request that retries it. The store then holds the credential, and
/// the next reread follows the store again.
pub fn reread(
    auth: anytype,
    comptime account_key: []const u8,
    maybe_file: ?*const json_store.File,
) !Change {
    switch (auth.persistence) {
        .saved => {},
        // `save` records a second refusal, so a failure here needs no report.
        .save_pending => {
            save(auth, account_key) catch {};
            return .unchanged;
        },
        .memory_only => return .unchanged,
    }
    var stored_auth = auth.*;
    stored_auth.tokens = null;
    defer clear(&stored_auth);
    const loaded = if (maybe_file) |file| try loadEntry(&stored_auth, account_key, file) else false;
    if (!loaded) {
        if (auth.tokens == null) return .unchanged;
        clear(auth);
        return .signed_out;
    }
    if (auth.tokens == null) {
        adopt(auth, &stored_auth);
        return .signed_in;
    }
    const current = &auth.tokens.?;
    const stored = &stored_auth.tokens.?;
    if (sameTokens(current, stored)) return .unchanged;
    const same_principal = samePrincipal(current, stored);
    adopt(auth, &stored_auth);
    return if (same_principal) .rotated else .replaced;
}

/// Whether two credentials of one account hold the same fields, byte for byte.
fn sameTokens(current: anytype, stored: @TypeOf(current)) bool {
    inline for (@typeInfo(@TypeOf(current.*)).@"struct".fields) |field| {
        const own = @field(current.*, field.name);
        const other = @field(stored.*, field.name);
        const same = if (comptime field.type == []const u8)
            std.mem.eql(u8, own, other)
        else if (comptime isOptionalString(field.type))
            sameOptionalString(own, other)
        else
            own == other;
        if (!same) return false;
    }
    return true;
}

fn sameOptionalString(own: ?[]const u8, other: ?[]const u8) bool {
    const string_own = own orelse return other == null;
    const string_other = other orelse return false;
    return std.mem.eql(u8, string_own, string_other);
}

/// Whether two credentials of one account name the same principal. A minted key
/// names no principal, so another key is another principal, exactly as every
/// login is.
fn samePrincipal(current: anytype, stored: @TypeOf(current)) bool {
    if (@hasDecl(@TypeOf(current.*), "samePrincipal")) return current.samePrincipal(stored);
    return false;
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
    if (auth.persistence == .save_pending) {
        // The pending token is the only live credential. Keep cancellation from
        // dropping its last save attempt before a model request can use it.
        const protection = auth.io.swapCancelProtection(.blocked);
        defer _ = auth.io.swapCancelProtection(protection);
        try save(auth, account_key);
    }
    const tokens = auth.tokens orelse return error.NotAuthenticated;
    if (expired(auth)) {
        const Tokens = @typeInfo(@TypeOf(auth.tokens)).optional.child;
        const maybe_fresh: ?Tokens = refreshFn(
            auth.gpa,
            auth.io,
            auth.timeouts,
            tokens,
        ) catch |first_error| try refreshFromStore(auth, account_key, first_error, refreshFn);
        // A null result reports that the store held a live credential, which is
        // installed and needs no save of its own.
        if (maybe_fresh) |fresh| {
            // The refresh consumed the stored (single-use) refresh token
            // server-side, so `fresh` is now the only usable credential. Block
            // cancellation until it is committed and persisted. Without the
            // block, a cancel that lands at the save (the catalog fetch runs
            // `accessToken` under a timeout) loses the credential.
            const protection = auth.io.swapCancelProtection(.blocked);
            defer _ = auth.io.swapCancelProtection(protection);
            // Read the installed tokens again: the store replaced them.
            auth.tokens.?.deinit(auth.gpa);
            auth.tokens = fresh;
            try save(auth, account_key);
        }
    }
    return auth.tokens.?.access;
}

/// Whether the installed access token has reached its expiry. Only the clock of
/// this process answers here, so a token the provider revoked still reads live.
fn expired(auth: anytype) bool {
    const now_ms = std.Io.Timestamp.now(auth.io, .real).toMilliseconds();
    return now_ms >= auth.tokens.?.expires_ms;
}

/// Renew a credential that the provider rejected on a model request. Take the
/// token another instance saved when the store holds a newer one, else refresh
/// the installed one, although it has not expired yet.
///
/// A revoked access token reads as fresh here, because only the provider knows
/// that it died. Two Drinky instances hold their own copy of one credential, so a
/// refresh in one of them revokes the token the other still holds.
///
/// The call reports whether the credential changed, so the caller repeats a
/// request only when the next one carries another token. A store that holds
/// another principal is installed and reports `error.CredentialReplaced`,
/// exactly as a failed refresh does.
///
/// A refresh that fails reads the store once more, because another instance can
/// have saved its own renewal while this one ran.
pub fn renew(
    auth: anytype,
    comptime account_key: []const u8,
    comptime refreshFn: anytype,
) !bool {
    if (auth.tokens == null) return false;
    if (try adoptStored(auth, account_key)) return true;
    const Tokens = @typeInfo(@TypeOf(auth.tokens)).optional.child;
    const maybe_fresh: ?Tokens = refreshFn(
        auth.gpa,
        auth.io,
        auth.timeouts,
        auth.tokens.?,
    ) catch |first_error| try refreshFromStore(auth, account_key, first_error, refreshFn);
    // A null result reports that the store held a live credential, which is
    // installed already.
    if (maybe_fresh) |fresh| {
        // The refresh consumed the stored refresh token server-side, so `fresh`
        // is now the only usable credential. `accessToken` blocks cancellation
        // for the same reason.
        const protection = auth.io.swapCancelProtection(.blocked);
        defer _ = auth.io.swapCancelProtection(protection);
        auth.tokens.?.deinit(auth.gpa);
        auth.tokens = fresh;
        try save(auth, account_key);
    }
    return true;
}

/// Inspect the credential that `auth.json` holds after a refresh failure. A
/// different token for the same known principal is installed. A different or
/// unknown principal is installed too, but stops before a model request. The app
/// then drops the old principal evidence before the user retries.
///
/// A null result reports that the installed credential is live, so the caller
/// uses it as it stands. Tokens report a credential that the caller must install
/// and save.
///
/// Drinky refreshes the adopted credential only when it has expired too. Every
/// refresh rotates the token that every other Drinky instance holds, so a refresh
/// of a live credential pushes the instances into a rotation loop.
fn refreshFromStore(
    auth: anytype,
    comptime account_key: []const u8,
    first_error: anyerror,
    comptime refreshFn: anytype,
) anyerror!?@typeInfo(@TypeOf(auth.tokens)).optional.child {
    // A store that holds another principal stops the session, whatever brought
    // the caller here. Every other failure of the store leaves the credential
    // in memory, so the caller reports the failure it already has.
    if (!try adoptStored(auth, account_key)) return first_error;
    if (!expired(auth)) return null;
    return try refreshFn(auth.gpa, auth.io, auth.timeouts, auth.tokens.?);
}

/// Install the credential that `auth.json` holds when another instance replaced
/// the one in memory. It reports false when the store holds nothing new, and it
/// treats a store it cannot read as nothing new, because the caller owns the
/// failure that brought it here.
///
/// A store entry of another principal is installed too, and reports
/// `error.CredentialReplaced`: the session must stop before a model request.
fn adoptStored(auth: anytype, comptime account_key: []const u8) !bool {
    var stored_auth = auth.*;
    stored_auth.tokens = null;
    defer clear(&stored_auth);
    const loaded = load(&stored_auth, account_key) catch return false;
    if (!loaded) return false;

    const current = &auth.tokens.?;
    const stored = &stored_auth.tokens.?;
    if (std.mem.eql(u8, current.refresh, stored.refresh)) return false;
    const same_principal = current.samePrincipal(stored);

    adopt(auth, &stored_auth);
    if (!same_principal) return error.CredentialReplaced;
    return true;
}

/// Move the credential that `stored_auth` loaded into `auth`, in place of the
/// one in memory. The loaded credential came from the store, so it needs no
/// save of its own.
fn adopt(auth: anytype, stored_auth: @TypeOf(auth)) void {
    clear(auth);
    auth.tokens = stored_auth.tokens;
    stored_auth.tokens = null;
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
    // A flow that binds its redirect with a random callback path builds that
    // path first, and its authorize URL names the result. The path lives as
    // long as the listener that answers on it, so the buffer stays in the arm
    // that owns both. A flow that binds with `state` allocates no such buffer.
    const redirect = switch (comptime oauth_callback.bindingOf(oauth)) {
        .path => bound: {
            var path_buffer: [oauth.callback_path_len]u8 = undefined;
            const callback_path = oauth.callbackPath(&path_buffer, auth.io);
            const url = try oauth.authorizeUrl(auth.gpa, &pair, callback_path);
            defer auth.gpa.free(url);
            break :bound try receiveRedirect(auth, prompt, &.{
                .url = url,
                .port = oauth.callback_port,
                .path = callback_path,
            });
        },
        .state => plain: {
            const url = try oauth.authorizeUrl(auth.gpa, &pair);
            defer auth.gpa.free(url);
            break :plain try receiveRedirect(auth, prompt, &.{
                .url = url,
                .port = oauth.callback_port,
            });
        },
    };
    defer {
        auth.gpa.free(redirect.code);
        if (redirect.state) |state| auth.gpa.free(state);
    }

    return commit(auth, account_key, try exchangeFn(auth, &redirect, &pair));
}

/// The browser step of one login: the URL the prompt shows, and the loopback
/// listener that answers its redirect. The fields are named, so no two can swap
/// and an absent path reads as its own rule at the call site.
const BrowserWait = struct {
    url: []const u8,
    port: u16,
    /// The one callback path the listener answers on. A login that binds its
    /// redirect with `state` names none, and the listener then answers on every
    /// path.
    path: ?[]const u8 = null,
};

/// Open the loopback listener, show the URL, and wait for the redirect. The
/// caller owns the returned code and state.
fn receiveRedirect(
    auth: anytype,
    prompt: anytype,
    wait: *const BrowserWait,
) !oauth_callback.Redirect {
    return oauth_login.receive(oauth_callback.Redirect, &.{
        .url = wait.url,
        .prompt = prompt,
        .browser = oauth_login.Browser{ .io = auth.io },
        .callback = CallbackSource{
            .gpa = auth.gpa,
            .io = auth.io,
            .port = wait.port,
            .path = wait.path,
        },
    });
}

/// Run the interactive device-code login (RFC 8628) and report pre-commit
/// runtime text through the caller's presentation boundary. `oauth` is the
/// provider protocol module: `requestDevice` opens the grant, and `poll` asks
/// for its tokens. Once tokens are installed, the function returns a non-error
/// persistence outcome, exactly as `login` does.
pub fn loginDevice(
    auth: anytype,
    comptime account_key: []const u8,
    comptime oauth: type,
    prompt: anytype,
) !Login {
    const device = try oauth.requestDevice(auth.gpa, auth.io, auth.timeouts);
    defer device.deinit(auth.gpa);

    const tokens = try oauth_login.poll(oauth.Tokens, &.{
        .url = device.url(),
        .code = device.user_code,
        .interval_ms = device.interval_ms,
        .lifetime_ms = device.lifetime_ms,
        .prompt = prompt,
        .browser = oauth_login.Browser{ .io = auth.io },
        .clock = oauth_login.Clock{ .io = auth.io },
        .poller = DevicePoller(oauth){
            .gpa = auth.gpa,
            .io = auth.io,
            .timeouts = auth.timeouts,
            .device_code = device.device_code,
        },
    });
    return commit(auth, account_key, tokens);
}

/// One poll of a device-code grant through the protocol module `oauth`.
fn DevicePoller(comptime oauth: type) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        timeouts: net.Timeouts,
        device_code: []const u8,

        pub fn poll(self: @This()) !oauth_login.Poll(oauth.Tokens) {
            return oauth.poll(self.gpa, self.io, self.timeouts, self.device_code);
        }
    };
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
    auth.persistence = .saved;
}

/// Persist the current tokens under `account_key`. The on-disk entry is the
/// `Tokens` fields verbatim. Lock contention leaves a retry marker in memory.
/// Every other failure leaves the credential memory-only, because a store
/// Drinky cannot write at all must not stop every later turn.
pub fn save(auth: anytype, comptime account_key: []const u8) !void {
    const tokens = auth.tokens orelse return error.NotAuthenticated;
    json_store.save(auth.gpa, auth.io, auth.path, account_key, tokens, .{}) catch |err| {
        auth.persistence = if (err == error.StoreBusy) .save_pending else .memory_only;
        return switch (err) {
            error.CorruptStore => error.BadCredentials,
            else => err,
        };
    };
    auth.persistence = .saved;
}

const CallbackSource = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    port: u16,
    path: ?[]const u8,

    pub fn listen(self: CallbackSource) !CallbackListener {
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        return .{
            .gpa = self.gpa,
            .io = self.io,
            .path = self.path,
            .server = try address.listen(self.io, .{ .reuse_address = true }),
        };
    }
};

const CallbackListener = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: ?[]const u8,
    server: std.Io.net.Server,

    pub fn deinit(self: *CallbackListener) void {
        self.server.deinit(self.io);
    }

    pub fn receive(self: *CallbackListener) !oauth_callback.Redirect {
        return oauth_callback.receive(self.gpa, self.io, &self.server, self.path);
    }
};

/// A test credential that names no principal, as a minted key does.
const KeyTokens = struct {
    access: []const u8,
    expires_ms: i64,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.access);
    }
};

/// A test store over `Tokens`, exactly as a provider `Auth` file struct.
fn TestAuth(comptime Tokens: type) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        tokens: ?Tokens,
        persistence: Persistence = .saved,
    };
}

/// `reread` over the store of `subject`, opened as the registry opens it.
fn rereadStore(subject: anytype, comptime account_key: []const u8) !Change {
    var maybe_file = try openStore(subject.gpa, subject.io, subject.path);
    defer if (maybe_file) |*file| file.deinit();
    return reread(subject, account_key, if (maybe_file) |*file| file else null);
}

test "a failed persist returns memory-only login and keeps credentials usable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var subject: TestAuth(KeyTokens) = .{ .gpa = gpa, .io = io, .path = undefined, .tokens = null };

    // A corrupt store refuses the rewrite: the replacement remains installed,
    // and the caller receives a committed memory-only outcome to present.
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "not json" });
    var bad_buf: [160]u8 = undefined;
    subject.path = try std.fmt.bufPrint(&bad_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    const memory_only = commit(&subject, "test_account", KeyTokens{
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
    const saved = commit(&subject, "test_account", KeyTokens{
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

// A client borrows into the credential of its account, so a reread that finds
// the same credential must leave the one in memory where it is.
test "reread settles the credential on the store and reports the change" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [160]u8 = undefined;
    var subject: TestAuth(KeyTokens) = .{ .gpa = gpa, .io = io, .path = undefined, .tokens = null };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);
    subject.path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );

    // No store yet, and no credential in memory: nothing changed.
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expect(subject.tokens == null);

    // Another instance signed in. The reread installs that credential.
    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "stored",
        .expires_ms = 1,
    }, .{});
    try std.testing.expectEqual(Change.signed_in, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("stored", subject.tokens.?.access);

    // The store still holds the same credential. The bytes in memory stay put.
    const installed = subject.tokens.?.access;
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqual(installed.ptr, subject.tokens.?.access.ptr);

    // A minted key names no principal, so another key is another principal.
    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "minted again",
        .expires_ms = 2,
    }, .{});
    try std.testing.expectEqual(Change.replaced, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("minted again", subject.tokens.?.access);

    // The other instance signed out. The reread clears the credential in memory.
    try json_store.remove(gpa, io, subject.path, "test_account");
    try std.testing.expectEqual(Change.signed_out, try rereadStore(&subject, "test_account"));
    try std.testing.expect(subject.tokens == null);
}

// A refresh in another instance rotates the token of the same principal, and
// the evidence of that principal stays valid. Only another principal takes it.
test "reread tells a rotation of one principal from a replacement" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Tokens = struct {
        access: []const u8,
        account: ?[]const u8 = null,

        fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.access);
            if (self.account) |account| allocator.free(account);
        }

        pub fn samePrincipal(self: *const @This(), other: *const @This()) bool {
            const own = self.account orelse return false;
            const theirs = other.account orelse return false;
            return std.mem.eql(u8, own, theirs);
        }
    };
    var path_buffer: [160]u8 = undefined;
    var subject: TestAuth(Tokens) = .{ .gpa = gpa, .io = io, .path = undefined, .tokens = null };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);
    subject.path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "first",
        .account = "user-1",
    }, .{});
    try std.testing.expectEqual(Change.signed_in, try rereadStore(&subject, "test_account"));

    // The same user, another token.
    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "second",
        .account = "user-1",
    }, .{});
    try std.testing.expectEqual(Change.rotated, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("second", subject.tokens.?.access);

    // Another user in the same account slot.
    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "third",
        .account = "user-2",
    }, .{});
    try std.testing.expectEqual(Change.replaced, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("third", subject.tokens.?.access);

    // An unknown user matches nobody, so the safe path takes the evidence.
    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "fourth",
        .account = null,
    }, .{});
    try std.testing.expectEqual(Change.replaced, try rereadStore(&subject, "test_account"));
    try std.testing.expect(subject.tokens.?.account == null);
}

// A save that fails for good leaves the only live copy in memory. The store can
// hold nothing, or the entry a refresh consumed, and a reread must keep the
// live credential over both, because nobody signed out and nobody rotated it.
test "a credential whose save failed survives a reread of the store" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [160]u8 = undefined;
    var subject: TestAuth(KeyTokens) = .{ .gpa = gpa, .io = io, .path = undefined, .tokens = null };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);
    subject.path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );

    // The store refuses the save of a login, so the credential is memory-only.
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "not json" });
    switch (commit(&subject, "test_account", KeyTokens{
        .access = try gpa.dupe(u8, "live"),
        .expires_ms = 1,
    })) {
        .memory_only => {},
        .saved => return error.UnexpectedLoginPersistence,
    }

    // The store reads again, and it holds no entry. The live credential stays.
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "{}" });
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("live", subject.tokens.?.access);

    // The store holds the entry that a refresh replaced. The live one stays too.
    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "consumed",
        .expires_ms = 0,
    }, .{});
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("live", subject.tokens.?.access);

    // A save that reaches the store hands the account back to the store.
    try save(&subject, "test_account");
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try json_store.remove(gpa, io, subject.path, "test_account");
    try std.testing.expectEqual(Change.signed_out, try rereadStore(&subject, "test_account"));
}

// A minted key sends no request through `accessToken`, so nothing retries the
// save that a busy store refused. The reread is the one moment where the store
// and the memory meet for every account, so it tries that save once more.
test "a reread retries the save that a busy store refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [160]u8 = undefined;
    var subject: TestAuth(KeyTokens) = .{ .gpa = gpa, .io = io, .path = undefined, .tokens = null };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);
    subject.path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    json_store.lock_policy = .{ .attempts_max = 2, .wait_ms = 0 };
    defer json_store.lock_policy = .{};

    // Another instance holds the lock while the login commits its key.
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{subject.path});
    defer gpa.free(lock_path);
    {
        var held = try std.Io.Dir.cwd().createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = @enumFromInt(0o600),
        });
        defer held.close(io);
        switch (commit(&subject, "test_account", KeyTokens{
            .access = try gpa.dupe(u8, "live"),
            .expires_ms = 1,
        })) {
            .memory_only => |failure| try std.testing.expectEqual(
                @as(anyerror, error.StoreBusy),
                failure.save_error,
            ),
            .saved => return error.UnexpectedLoginPersistence,
        }
        try std.testing.expectEqual(Persistence.save_pending, subject.persistence);

        // The store is still busy. The reread keeps the key, whatever the store holds.
        try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
        try std.testing.expectEqual(Persistence.save_pending, subject.persistence);
        try std.testing.expectEqualStrings("live", subject.tokens.?.access);
    }

    // The lock is gone. The reread saves the key and keeps it.
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqual(Persistence.saved, subject.persistence);
    try std.testing.expectEqualStrings("live", subject.tokens.?.access);
    var file = (try json_store.open(gpa, io, subject.path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings(
        "live",
        file.entry("test_account").?.get("access").?.string,
    );

    // The account follows the store from here on.
    try json_store.remove(gpa, io, subject.path, "test_account");
    try std.testing.expectEqual(Change.signed_out, try rereadStore(&subject, "test_account"));
    try std.testing.expect(subject.tokens == null);
}
