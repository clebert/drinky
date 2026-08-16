//! The credential lifecycle for the Anthropic Console account: the shared
//! `auth` login and store instantiated over `console`'s protocol for the
//! `"anthropic_console"` entry in `<home>/.pith/auth.json`. The login mints an
//! API key and stores it. The key needs no refresh, so there is no
//! `accessToken`: `apiKey` returns the stored key for the `x-api-key` header.

const std = @import("std");

const auth = @import("../auth.zig");
const net = @import("../net.zig");
const oauth_callback = @import("../oauth_callback.zig");
const oauth_wire = @import("../oauth_wire.zig");
const console = @import("console.zig");

const ConsoleAuth = @This();

/// The top-level key this account's credential lives under in `auth.json`.
const account_key = "anthropic_console";

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
path: []const u8,
tokens: ?console.Tokens,
/// Whether a committed credential still needs a store retry. The shared
/// lifecycle keeps this field for every account. A minted key never refreshes,
/// so this account reaches no retry and the field stays false.
save_pending: bool = false,

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    timeouts: net.Timeouts,
) !ConsoleAuth {
    const path = try std.fs.path.join(gpa, &.{ home, ".pith", "auth.json" });
    return .{ .gpa = gpa, .io = io, .timeouts = timeouts, .path = path, .tokens = null };
}

pub fn deinit(self: *ConsoleAuth) void {
    if (self.tokens) |tokens| tokens.deinit(self.gpa);
    self.gpa.free(self.path);
}

/// Load the stored key. The call returns false when the file is absent or holds
/// no Anthropic Console credential.
pub fn load(self: *ConsoleAuth) !bool {
    return auth.load(self, account_key);
}

/// The stored API key for the `x-api-key` header, or null when signed out.
pub fn apiKey(self: *const ConsoleAuth) ?[]const u8 {
    const tokens = self.tokens orelse return null;
    return tokens.api_key;
}

/// Run the interactive OAuth login, mint the API key, and return the committed
/// credential's persistence outcome for the caller to present.
pub fn login(self: *ConsoleAuth, prompt: anytype) !auth.Login {
    return auth.login(self, account_key, console, prompt, exchangeRedirect);
}

/// `console.exchange` over the received redirect. The verifier doubles as
/// `state`. A mismatch means the redirect is not ours.
fn exchangeRedirect(
    self: *ConsoleAuth,
    redirect: *const oauth_callback.Redirect,
    pair: *const oauth_wire.Pkce,
) !console.Tokens {
    if (!std.mem.eql(u8, redirect.state, &pair.verifier)) return error.StateMismatch;
    return console.exchange(self.gpa, self.io, self.timeouts, &.{
        .code = redirect.code,
        .state = redirect.state,
        .verifier = &pair.verifier,
    });
}

/// Drop this account's credential: clear the in-memory key and remove its entry
/// from `auth.json`. The removal preserves every other account's entry.
pub fn logout(self: *ConsoleAuth) !void {
    return auth.logout(self, account_key);
}

test "the callback state must match the verifier" {
    var pair: oauth_wire.Pkce = undefined;
    @memset(&pair.verifier, 'v');
    var subject: ConsoleAuth = .{
        .gpa = undefined,
        .io = undefined,
        .timeouts = .{},
        .path = "",
        .tokens = null,
    };
    try std.testing.expectError(
        error.StateMismatch,
        subject.exchangeRedirect(&.{ .code = "code", .state = "wrong" }, &pair),
    );
}

test "load reads the stored api key" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"anthropic_console\":{\"api_key\":\"sk-ant-api03-x\"}}",
    });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: ConsoleAuth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = null,
    };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);
    try std.testing.expect(try subject.load());
    try std.testing.expectEqualStrings("sk-ant-api03-x", subject.apiKey().?);
}

test "load rejects an entry missing the api key" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"anthropic_console\":{}}",
    });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: ConsoleAuth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = null,
    };
    try std.testing.expectError(error.BadCredentials, subject.load());
    try std.testing.expect(subject.apiKey() == null);
}
