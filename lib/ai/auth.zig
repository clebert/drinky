const std = @import("std");

const json_store = @import("json_store.zig");
const net = @import("net.zig");
const oauth_callback = @import("oauth_callback.zig");
const oauth_login = @import("oauth_login.zig");
const oauth_wire = @import("oauth_wire.zig");

pub const Login = union(enum) {
    saved: []const u8,
    memory_only: struct {
        path: []const u8,
        save_error: anyerror,
    },
};

pub const Persistence = enum {
    saved,
    save_pending,
    memory_only,
};

fn isOptionalString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child == []const u8,
        else => false,
    };
}

pub fn openStore(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?json_store.File {
    return json_store.open(gpa, io, path) catch |err| switch (err) {
        error.CorruptStore => return error.BadCredentials,
        else => return err,
    };
}

pub fn load(auth: anytype, comptime account_key: []const u8) !bool {
    var file = (try openStore(auth.gpa, auth.io, auth.path)) orelse return false;
    defer file.deinit();
    return loadEntry(auth, account_key, &file);
}

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
    if (auth.tokens) |old| old.deinit(auth.gpa);
    auth.tokens = tokens;
    auth.persistence = .saved;
    return true;
}

pub const Change = enum {
    unchanged,
    signed_in,
    signed_out,
    rotated,
    replaced,
};

pub fn reread(
    auth: anytype,
    comptime account_key: []const u8,
    maybe_file: ?*const json_store.File,
) !Change {
    switch (auth.persistence) {
        .saved => {},
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

fn samePrincipal(current: anytype, stored: @TypeOf(current)) bool {
    if (@hasDecl(@TypeOf(current.*), "samePrincipal")) return current.samePrincipal(stored);
    return false;
}

pub fn accessToken(
    auth: anytype,
    comptime account_key: []const u8,
    comptime refreshFn: anytype,
) ![]const u8 {
    if (auth.persistence == .save_pending) {
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
        if (maybe_fresh) |fresh| {
            const protection = auth.io.swapCancelProtection(.blocked);
            defer _ = auth.io.swapCancelProtection(protection);
            auth.tokens.?.deinit(auth.gpa);
            auth.tokens = fresh;
            try save(auth, account_key);
        }
    }
    return auth.tokens.?.access;
}

fn expired(auth: anytype) bool {
    const now_ms = std.Io.Timestamp.now(auth.io, .real).toMilliseconds();
    return now_ms >= auth.tokens.?.expires_ms;
}

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
    if (maybe_fresh) |fresh| {
        const protection = auth.io.swapCancelProtection(.blocked);
        defer _ = auth.io.swapCancelProtection(protection);
        auth.tokens.?.deinit(auth.gpa);
        auth.tokens = fresh;
        try save(auth, account_key);
    }
    return true;
}

fn refreshFromStore(
    auth: anytype,
    comptime account_key: []const u8,
    first_error: anyerror,
    comptime refreshFn: anytype,
) anyerror!?@typeInfo(@TypeOf(auth.tokens)).optional.child {
    if (!try adoptStored(auth, account_key)) return first_error;
    if (!expired(auth)) return null;
    return try refreshFn(auth.gpa, auth.io, auth.timeouts, auth.tokens.?);
}

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

fn adopt(auth: anytype, stored_auth: @TypeOf(auth)) void {
    clear(auth);
    auth.tokens = stored_auth.tokens;
    stored_auth.tokens = null;
}

pub fn login(
    auth: anytype,
    comptime account_key: []const u8,
    comptime oauth: type,
    prompt: anytype,
    comptime exchangeFn: anytype,
) !Login {
    const pair = oauth_wire.pkce(auth.io);
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

const BrowserWait = struct {
    url: []const u8,
    port: u16,
    path: ?[]const u8 = null,
};

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

fn commit(auth: anytype, comptime account_key: []const u8, tokens: anytype) Login {
    if (auth.tokens) |old| old.deinit(auth.gpa);
    auth.tokens = tokens;
    save(auth, account_key) catch |save_error| return .{ .memory_only = .{
        .path = auth.path,
        .save_error = save_error,
    } };
    return .{ .saved = auth.path };
}

pub fn logout(auth: anytype, comptime account_key: []const u8) !void {
    try remove(auth, account_key);
    clear(auth);
}

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

const KeyTokens = struct {
    access: []const u8,
    expires_ms: i64,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.access);
    }
};

fn TestAuth(comptime Tokens: type) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        tokens: ?Tokens,
        persistence: Persistence = .saved,
    };
}

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

    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expect(subject.tokens == null);

    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "stored",
        .expires_ms = 1,
    }, .{});
    try std.testing.expectEqual(Change.signed_in, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("stored", subject.tokens.?.access);

    const installed = subject.tokens.?.access;
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqual(installed.ptr, subject.tokens.?.access.ptr);

    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "minted again",
        .expires_ms = 2,
    }, .{});
    try std.testing.expectEqual(Change.replaced, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("minted again", subject.tokens.?.access);

    try json_store.remove(gpa, io, subject.path, "test_account");
    try std.testing.expectEqual(Change.signed_out, try rereadStore(&subject, "test_account"));
    try std.testing.expect(subject.tokens == null);
}

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

    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "second",
        .account = "user-1",
    }, .{});
    try std.testing.expectEqual(Change.rotated, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("second", subject.tokens.?.access);

    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "third",
        .account = "user-2",
    }, .{});
    try std.testing.expectEqual(Change.replaced, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("third", subject.tokens.?.access);

    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "fourth",
        .account = null,
    }, .{});
    try std.testing.expectEqual(Change.replaced, try rereadStore(&subject, "test_account"));
    try std.testing.expect(subject.tokens.?.account == null);
}

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

    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "not json" });
    switch (commit(&subject, "test_account", KeyTokens{
        .access = try gpa.dupe(u8, "live"),
        .expires_ms = 1,
    })) {
        .memory_only => {},
        .saved => return error.UnexpectedLoginPersistence,
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "{}" });
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("live", subject.tokens.?.access);

    try json_store.save(gpa, io, subject.path, "test_account", .{
        .access = "consumed",
        .expires_ms = 0,
    }, .{});
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqualStrings("live", subject.tokens.?.access);

    try save(&subject, "test_account");
    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try json_store.remove(gpa, io, subject.path, "test_account");
    try std.testing.expectEqual(Change.signed_out, try rereadStore(&subject, "test_account"));
}

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

        try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
        try std.testing.expectEqual(Persistence.save_pending, subject.persistence);
        try std.testing.expectEqualStrings("live", subject.tokens.?.access);
    }

    try std.testing.expectEqual(Change.unchanged, try rereadStore(&subject, "test_account"));
    try std.testing.expectEqual(Persistence.saved, subject.persistence);
    try std.testing.expectEqualStrings("live", subject.tokens.?.access);
    var file = (try json_store.open(gpa, io, subject.path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings(
        "live",
        file.entry("test_account").?.get("access").?.string,
    );

    try json_store.remove(gpa, io, subject.path, "test_account");
    try std.testing.expectEqual(Change.signed_out, try rereadStore(&subject, "test_account"));
    try std.testing.expect(subject.tokens == null);
}
