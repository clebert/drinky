const std = @import("std");

const auth = @import("../auth.zig");
const json_store = @import("../json_store.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const oauth_callback = @import("../oauth_callback.zig");
const oauth_wire = @import("../oauth_wire.zig");
const console = @import("console.zig");

const ConsoleAuth = @This();

const account_key = llm.Account.anthropic_api.id();

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
path: []const u8,
tokens: ?console.Tokens,
persistence: auth.Persistence = .saved,

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    timeouts: net.Timeouts,
) !ConsoleAuth {
    const path = try std.fs.path.join(gpa, &.{ home, ".drinky", "auth.json" });
    return .{ .gpa = gpa, .io = io, .timeouts = timeouts, .path = path, .tokens = null };
}

pub fn deinit(self: *ConsoleAuth) void {
    if (self.tokens) |tokens| tokens.deinit(self.gpa);
    self.gpa.free(self.path);
}

pub fn load(self: *ConsoleAuth) !bool {
    return auth.load(self, account_key);
}

pub fn reread(self: *ConsoleAuth, maybe_file: ?*const json_store.File) !auth.Change {
    return auth.reread(self, account_key, maybe_file);
}

pub fn apiKey(self: *const ConsoleAuth) ?[]const u8 {
    const tokens = self.tokens orelse return null;
    return tokens.api_key;
}

pub fn login(self: *ConsoleAuth, prompt: anytype) !auth.Login {
    return auth.login(self, account_key, console, prompt, exchangeRedirect);
}

fn exchangeRedirect(
    self: *ConsoleAuth,
    redirect: *const oauth_callback.Redirect,
    pair: *const oauth_wire.Pkce,
) !console.Tokens {
    const state = redirect.state orelse return error.StateMismatch;
    if (!std.mem.eql(u8, state, &pair.verifier)) return error.StateMismatch;
    return console.exchange(self.gpa, self.io, self.timeouts, &.{
        .code = redirect.code,
        .state = state,
        .verifier = &pair.verifier,
    });
}

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
        .data = "{\"anthropic-api\":{\"api_key\":\"sk-ant-api03-x\"}}",
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
        .data = "{\"anthropic-api\":{}}",
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
