const std = @import("std");

const auth = @import("../auth.zig");
const json_store = @import("../json_store.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const oauth_callback = @import("../oauth_callback.zig");
const oauth_wire = @import("../oauth_wire.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

const account_key = llm.Account.anthropic_plan.id();

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
    return auth.accessToken(self, account_key, refreshTokens);
}

pub fn renew(self: *Auth) !bool {
    return auth.renew(self, account_key, refreshTokens);
}

fn refreshTokens(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: oauth.Tokens,
) !oauth.Tokens {
    return oauth.refresh(gpa, io, timeouts, tokens.refresh);
}

pub fn login(self: *Auth, prompt: anytype) !auth.Login {
    return auth.login(self, account_key, oauth, prompt, exchangeRedirect);
}

fn exchangeRedirect(
    self: *Auth,
    redirect: *const oauth_callback.Redirect,
    pair: *const oauth_wire.Pkce,
) !oauth.Tokens {
    return oauth.exchange(self.gpa, self.io, self.timeouts, .{
        .code = redirect.code,
        .state = redirect.state orelse return error.StateMismatch,
        .verifier = &pair.verifier,
    });
}

pub fn logout(self: *Auth) !void {
    return auth.logout(self, account_key);
}

pub fn invalidate(self: *Auth) !bool {
    return auth.invalidate(self, account_key);
}

fn refuseRefresh(
    _: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: oauth.Tokens,
) anyerror!oauth.Tokens {
    return error.TokenGrantRejected;
}

fn grantRefresh(
    gpa: std.mem.Allocator,
    _: std.Io,
    _: net.Timeouts,
    _: oauth.Tokens,
) anyerror!oauth.Tokens {
    const access = try gpa.dupe(u8, "fresh");
    const refresh = gpa.dupe(u8, "next") catch |err| {
        gpa.free(access);
        return err;
    };
    return .{
        .access = access,
        .refresh = refresh,
        .expires_ms = std.math.maxInt(i64),
    };
}

fn grantRotatedRefresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: oauth.Tokens,
) anyerror!oauth.Tokens {
    if (!std.mem.eql(u8, tokens.refresh, "rotated")) return error.TokenGrantRejected;
    return grantRefresh(gpa, io, timeouts, tokens);
}

var race_path: []const u8 = "";

fn refuseRefreshAfterSave(
    gpa: std.mem.Allocator,
    io: std.Io,
    _: net.Timeouts,
    _: oauth.Tokens,
) anyerror!oauth.Tokens {
    std.debug.assert(race_path.len > 0);
    try json_store.save(gpa, io, race_path, account_key, .{
        .access = "winner_access",
        .refresh = "winner",
        .expires_ms = std.math.maxInt(i64),
    }, .{});
    return error.TokenGrantRejected;
}

fn grantRefreshAfterCancel(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    tokens: oauth.Tokens,
) anyerror!oauth.Tokens {
    io.sleep(.fromSeconds(60), .awake) catch io.recancel();
    return grantRefresh(gpa, io, timeouts, tokens);
}

fn refreshUnderCancel(subject: *Auth) anyerror!void {
    const access = try auth.accessToken(subject, account_key, grantRefreshAfterCancel);
    try std.testing.expectEqualStrings("fresh", access);
}

test "a live access token is returned without a refresh" {
    var subject: Auth = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .path = "",
        .tokens = .{ .access = "live", .refresh = "keep", .expires_ms = std.math.maxInt(i64) },
    };
    try std.testing.expectEqualStrings(
        "live",
        try auth.accessToken(&subject, account_key, refuseRefresh),
    );
}

test "a failed refresh leaves the stored credential intact" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "keep"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectError(
        error.TokenGrantRejected,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stale", subject.tokens.?.access);
    try std.testing.expectEqualStrings("keep", subject.tokens.?.refresh);

    try auth.save(&subject, account_key);
    try std.testing.expectError(
        error.TokenGrantRejected,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stale", subject.tokens.?.access);
    try std.testing.expectEqualStrings("keep", subject.tokens.?.refresh);
}

test "a refresh token rotated by another instance recovers without a restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    try json_store.save(gpa, io, path, account_key, .{
        .access = "rotated_access",
        .refresh = "rotated",
        .expires_ms = 0,
    }, .{});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "dead"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectEqualStrings(
        "fresh",
        try auth.accessToken(&subject, account_key, grantRotatedRefresh),
    );
    try std.testing.expectEqualStrings("next", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);
}

test "a live credential from another instance is used without a refresh" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    try json_store.save(gpa, io, path, account_key, .{
        .access = "saved_access",
        .refresh = "saved",
        .expires_ms = std.math.maxInt(i64),
    }, .{});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "dead"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectEqualStrings(
        "saved_access",
        try auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("saved", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    const entry = file.entry(account_key).?;
    try std.testing.expectEqualStrings("saved", entry.get("refresh").?.string);
    try std.testing.expectEqualStrings("saved_access", entry.get("access").?.string);
}

test "a retry that also fails keeps the credential the store holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    try json_store.save(gpa, io, path, account_key, .{
        .access = "stored_access",
        .refresh = "stored",
        .expires_ms = 0,
    }, .{});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "dead"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectError(
        error.TokenGrantRejected,
        auth.accessToken(&subject, account_key, refuseRefresh),
    );
    try std.testing.expectEqualStrings("stored_access", subject.tokens.?.access);
    try std.testing.expectEqualStrings("stored", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("stored", file.entry(account_key).?.get("refresh").?.string);
}

test "a rejected access token takes the credential another instance saved" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    try json_store.save(gpa, io, path, account_key, .{
        .access = "saved_access",
        .refresh = "saved",
        .expires_ms = std.math.maxInt(i64),
    }, .{});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "revoked"),
            .refresh = try gpa.dupe(u8, "dead"),
            .expires_ms = std.math.maxInt(i64),
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expect(try auth.renew(&subject, account_key, refuseRefresh));
    try std.testing.expectEqualStrings("saved_access", subject.tokens.?.access);
    try std.testing.expectEqualStrings("saved", subject.tokens.?.refresh);
    try std.testing.expectEqualStrings(
        "saved_access",
        try auth.accessToken(&subject, account_key, refuseRefresh),
    );
}

test "a renewal whose refresh fails takes the credential that landed meanwhile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "revoked"),
            .refresh = try gpa.dupe(u8, "spent"),
            .expires_ms = std.math.maxInt(i64),
        },
    };
    defer subject.tokens.?.deinit(gpa);

    race_path = path;
    defer race_path = "";
    try std.testing.expect(try auth.renew(&subject, account_key, refuseRefreshAfterSave));
    try std.testing.expectEqualStrings("winner_access", subject.tokens.?.access);
    try std.testing.expectEqualStrings("winner", subject.tokens.?.refresh);
}

test "a rejected access token refreshes although its own clock reads live" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "revoked"),
            .refresh = try gpa.dupe(u8, "live"),
            .expires_ms = std.math.maxInt(i64),
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expect(try auth.renew(&subject, account_key, grantRefresh));
    try std.testing.expectEqualStrings("fresh", subject.tokens.?.access);
    try std.testing.expectEqualStrings("next", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);

    var empty: Auth = .{ .gpa = gpa, .io = io, .timeouts = .{}, .path = path, .tokens = null };
    try std.testing.expect(!try auth.renew(&empty, account_key, refuseRefresh));
}

test "invalidation preserves a newer refresh token from another instance" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    try json_store.save(gpa, io, path, account_key, .{
        .access = "new_access",
        .refresh = "new_refresh",
        .expires_ms = std.math.maxInt(i64),
    }, .{});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "rejected_access"),
            .refresh = try gpa.dupe(u8, "rejected_refresh"),
            .expires_ms = 0,
        },
    };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);

    try std.testing.expect(try subject.invalidate());
    try std.testing.expectEqualStrings("new_refresh", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings(
        "new_refresh",
        file.entry(account_key).?.get("refresh").?.string,
    );
}

test "an expired access token is refreshed and re-persisted" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "old"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    try std.testing.expectEqualStrings(
        "fresh",
        try auth.accessToken(&subject, account_key, grantRefresh),
    );
    try std.testing.expectEqualStrings("next", subject.tokens.?.refresh);

    var file = (try json_store.open(gpa, std.testing.io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);
}

test "a busy store retries a refreshed credential before the next request" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "old"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);
    json_store.lock_policy = .{ .attempts_max = 2, .wait_ms = 0 };
    defer json_store.lock_policy = .{};

    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
    defer gpa.free(lock_path);
    {
        var held = try std.Io.Dir.cwd().createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = @enumFromInt(0o600),
        });
        defer held.close(io);
        try std.testing.expectError(
            error.StoreBusy,
            auth.accessToken(&subject, account_key, grantRefresh),
        );
        try std.testing.expect(subject.save_pending);
        try std.testing.expectEqualStrings("fresh", subject.tokens.?.access);
    }

    try std.testing.expectEqualStrings(
        "fresh",
        try auth.accessToken(&subject, account_key, grantRefresh),
    );
    try std.testing.expect(!subject.save_pending);
    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);
}

test "a cancel landing at the save cannot lose the rotated credential" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = path,
        .tokens = .{
            .access = try gpa.dupe(u8, "stale"),
            .refresh = try gpa.dupe(u8, "old"),
            .expires_ms = 0,
        },
    };
    defer subject.tokens.?.deinit(gpa);

    var future = try io.concurrent(refreshUnderCancel, .{&subject});
    try future.cancel(io);

    try std.testing.expectEqualStrings("next", subject.tokens.?.refresh);
    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("next", file.entry(account_key).?.get("refresh").?.string);
}

test "load ignores the marker keys that an earlier store wrote" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data =
        \\{"anthropic-plan":
        \\  {"access":"a","refresh":"r","expires_ms":1,
        \\   "account_uuid":"account","organization_uuid":"organization"}}
        ,
    });
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    var subject: Auth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = null,
    };
    defer if (subject.tokens) |tokens| tokens.deinit(gpa);
    try std.testing.expect(try subject.load());
    try std.testing.expectEqualStrings("r", subject.tokens.?.refresh);
}

test "load rejects an entry missing a credential field" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"anthropic-plan\":{\"access\":\"a\"}}",
    });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    var subject: Auth = .{
        .gpa = gpa,
        .io = std.testing.io,
        .timeouts = .{},
        .path = path,
        .tokens = null,
    };
    try std.testing.expectError(error.BadCredentials, subject.load());
    try std.testing.expect(subject.tokens == null);
}
