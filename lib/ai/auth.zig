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

fn isOptionalString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child == []const u8,
        else => false,
    };
}

fn openStore(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?json_store.File {
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
    auth.save_pending = false;
    return true;
}

pub fn accessToken(
    auth: anytype,
    comptime account_key: []const u8,
    comptime refreshFn: anytype,
) ![]const u8 {
    if (auth.save_pending) {
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
    if (adoptStored(auth, account_key)) return true;
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
    if (!adoptStored(auth, account_key)) return first_error;
    if (!expired(auth)) return null;
    return try refreshFn(auth.gpa, auth.io, auth.timeouts, auth.tokens.?);
}

fn adoptStored(auth: anytype, comptime account_key: []const u8) bool {
    var stored_auth = auth.*;
    stored_auth.tokens = null;
    defer clear(&stored_auth);
    const loaded = load(&stored_auth, account_key) catch return false;
    if (!loaded) return false;
    if (std.mem.eql(u8, auth.tokens.?.refresh, stored_auth.tokens.?.refresh)) return false;
    adopt(auth, &stored_auth);
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
    auth.save_pending = false;
}

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
        save_pending: bool = false,
    };
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
