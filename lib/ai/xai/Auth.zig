const std = @import("std");

const auth = @import("../auth.zig");
const json_store = @import("../json_store.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

const account_key = llm.Account.xai_plan.id();

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
path: []const u8,
tokens: ?oauth.Tokens,
save_pending: bool = false,

pub fn init(gpa: std.mem.Allocator, io: std.Io, home: []const u8, timeouts: net.Timeouts) !Auth {
    const path = try std.fs.path.join(gpa, &.{ home, ".drinky", "auth.json" });
    return .{ .gpa = gpa, .io = io, .timeouts = timeouts, .path = path, .tokens = null };
}

pub fn deinit(self: *Auth) void {
    if (self.tokens) |tokens| tokens.deinit(self.gpa);
    self.gpa.free(self.path);
}

pub fn load(self: *Auth) !bool {
    return auth.load(self, account_key);
}

pub fn accessToken(self: *Auth) ![]const u8 {
    return auth.accessToken(self, account_key, oauth.refresh);
}

pub fn renew(self: *Auth) !bool {
    return auth.renew(self, account_key, oauth.refresh);
}

pub fn login(self: *Auth, prompt: anytype) !auth.Login {
    return auth.loginDevice(self, account_key, oauth, prompt);
}

pub fn logout(self: *Auth) !void {
    return auth.logout(self, account_key);
}

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
    try std.testing.expect(!try subject.load());
    try json_store.save(gpa, io, subject.path, "openai-plan", .{ .access = "a" }, .{});
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
    };
    try auth.save(&subject, account_key);

    var loaded = try init(gpa, io, home, .{});
    defer loaded.deinit();
    try std.testing.expect(try loaded.load());
    try std.testing.expect(try loaded.load());
    try std.testing.expectEqualStrings("at", try loaded.accessToken());
}

test "a signed-out account refuses a token" {
    var subject = try init(std.testing.allocator, undefined, "home", .{});
    defer subject.deinit();
    try std.testing.expectError(error.NotAuthenticated, subject.accessToken());
}
