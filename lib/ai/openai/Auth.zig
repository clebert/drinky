//! The credential lifecycle for the ChatGPT-subscription (Codex) account: the
//! shared `auth` lifecycle instantiated over `oauth`'s protocol for the
//! `"openai_subscription"` entry in `<home>/.pith/auth.json`.

const std = @import("std");

const auth = @import("../auth.zig");
const json_store = @import("../json_store.zig");
const net = @import("../net.zig");
const oauth_callback = @import("../oauth_callback.zig");
const oauth_wire = @import("../oauth_wire.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

/// The top-level key this account's credentials live under in `auth.json`.
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
    return auth.load(self, account_key);
}

/// A valid access token, refreshed and persisted first if it has expired.
pub fn accessToken(self: *Auth) ![]const u8 {
    return auth.accessToken(self, account_key, oauth.refresh);
}

/// The ChatGPT account id sent with each request. Empty when not authenticated.
pub fn accountId(self: *const Auth) []const u8 {
    const tokens = self.tokens orelse return "";
    return tokens.account_id;
}

/// Run the interactive OAuth login and return the committed credential's
/// persistence outcome for the caller to present.
pub fn login(self: *Auth, prompt: anytype) !auth.Login {
    return auth.login(self, account_key, oauth, prompt, exchangeRedirect);
}

/// `oauth.exchange` over the received redirect. The verifier doubles as
/// `state`. A mismatch means the redirect is not ours.
fn exchangeRedirect(
    self: *Auth,
    redirect: *const oauth_callback.Redirect,
    pair: *const oauth_wire.Pkce,
) !oauth.Tokens {
    if (!std.mem.eql(u8, redirect.state, &pair.verifier)) return error.StateMismatch;
    return oauth.exchange(self.gpa, self.io, self.timeouts, .{
        .code = redirect.code,
        .verifier = &pair.verifier,
    });
}

/// Drop this account's credentials: clear the in-memory tokens, remove its
/// entry from `auth.json`, and keep every other account's entry.
pub fn logout(self: *Auth) !void {
    return auth.logout(self, account_key);
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
    try json_store.save(gpa, io, subject.path, "anthropic_subscription", .{ .access = "a" }, .{});
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
        .account_id = try gpa.dupe(u8, "acct"),
    };
    try auth.save(&subject, account_key);

    var loaded = try init(gpa, io, home, .{});
    defer loaded.deinit();
    try std.testing.expect(try loaded.load());
    // A second load replaces the installed tokens and does not leak them.
    try std.testing.expect(try loaded.load());
    try std.testing.expectEqualStrings("at", try loaded.accessToken());
    try std.testing.expectEqualStrings("acct", loaded.accountId());
}

test "a signed-out account refuses a token and reports no account id" {
    var subject = try init(std.testing.allocator, undefined, "home", .{});
    defer subject.deinit();
    try std.testing.expectError(error.NotAuthenticated, subject.accessToken());
    try std.testing.expectEqualStrings("", subject.accountId());
}
