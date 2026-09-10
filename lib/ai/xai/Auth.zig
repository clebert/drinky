//! The credential lifecycle for the xAI subscription account: the shared `auth`
//! lifecycle instantiated over the device-code protocol of `oauth` for the
//! `"xai-sub-login"` entry in `<home>/.drinky/auth.json`.

const std = @import("std");

const auth = @import("../auth.zig");
const json_store = @import("../json_store.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

/// The top-level key this account's credentials live under in `auth.json`.
const account_key = llm.Account.xai_sub_login.id();

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
path: []const u8,
tokens: ?oauth.Tokens,
/// Whether a refreshed credential still needs a store retry.
save_pending: bool = false,

pub fn init(gpa: std.mem.Allocator, io: std.Io, home: []const u8, timeouts: net.Timeouts) !Auth {
    const path = try std.fs.path.join(gpa, &.{ home, ".drinky", "auth.json" });
    return .{ .gpa = gpa, .io = io, .timeouts = timeouts, .path = path, .tokens = null };
}

pub fn deinit(self: *Auth) void {
    if (self.tokens) |tokens| tokens.deinit(self.gpa);
    self.gpa.free(self.path);
}

/// Load stored tokens. Returns false when the file is absent or holds no
/// `xai-sub-login` entry (this account is simply not logged in).
pub fn load(self: *Auth) !bool {
    return auth.load(self, account_key);
}

/// A valid access token, refreshed and persisted first if it has expired.
pub fn accessToken(self: *Auth) ![]const u8 {
    return auth.accessToken(self, account_key, oauth.refresh);
}

/// Renew a credential the provider rejected on a request: adopt the token
/// another instance saved, else refresh this one before it expires. It reports
/// whether the credential changed.
pub fn renew(self: *Auth) !bool {
    return auth.renew(self, account_key, oauth.refresh);
}

/// Run the interactive device-code login and return the committed credential's
/// persistence outcome for the caller to present.
pub fn login(self: *Auth, prompt: anytype) !auth.Login {
    return auth.loginDevice(self, account_key, oauth, prompt);
}

/// Drop this account's credentials: clear the in-memory tokens, remove its
/// entry from `auth.json`, and keep every other account's entry.
pub fn logout(self: *Auth) !void {
    return auth.logout(self, account_key);
}

/// Forget a rejected refresh credential, or reload its stored replacement.
pub fn invalidate(self: *Auth) !bool {
    return auth.invalidate(self, account_key);
}

test "load distinguishes signed out from corrupt credentials" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var subject = try init(gpa, io, home, .{});
    defer subject.deinit();
    // An absent file and a file that holds only a sibling account's entry are
    // both simply signed out. An own entry that lacks a field is corrupt, not
    // ignored.
    try std.testing.expect(!try subject.load());
    try json_store.save(gpa, io, subject.path, "openai-sub-login", .{ .access = "a" }, .{});
    try std.testing.expect(!try subject.load());
    try json_store.save(
        gpa,
        io,
        subject.path,
        account_key,
        .{ .access = "at", .refresh = "rt" },
        .{},
    );
    try std.testing.expectError(error.BadCredentials, subject.load());
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

    var subject = try init(gpa, io, home, .{});
    defer subject.deinit();
    subject.tokens = .{
        .access = try gpa.dupe(u8, "at"),
        .refresh = try gpa.dupe(u8, "rt"),
        .expires_ms = std.math.maxInt(i64),
        .subject = try gpa.dupe(u8, "user-1"),
    };
    try auth.save(&subject, account_key);

    var loaded = try init(gpa, io, home, .{});
    defer loaded.deinit();
    try std.testing.expect(try loaded.load());
    // A second load replaces the installed tokens and does not leak them.
    try std.testing.expect(try loaded.load());
    try std.testing.expectEqualStrings("at", try loaded.accessToken());
    try std.testing.expectEqualStrings("user-1", loaded.tokens.?.subject.?);
}

// A credential from a response without an id token names no user. It stores
// and loads as such, so a later load does not read the gap as corruption.
test "a credential without a user round-trips" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var subject = try init(gpa, io, home, .{});
    defer subject.deinit();
    subject.tokens = .{
        .access = try gpa.dupe(u8, "at"),
        .refresh = try gpa.dupe(u8, "rt"),
        .expires_ms = std.math.maxInt(i64),
    };
    try auth.save(&subject, account_key);

    var loaded = try init(gpa, io, home, .{});
    defer loaded.deinit();
    try std.testing.expect(try loaded.load());
    try std.testing.expect(loaded.tokens.?.subject == null);
}

test "a signed-out account refuses a token" {
    var subject = try init(std.testing.allocator, undefined, "home", .{});
    defer subject.deinit();
    try std.testing.expectError(error.NotAuthenticated, subject.accessToken());
}
