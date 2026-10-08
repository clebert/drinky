const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const json_store = @import("../json_store.zig");
const testing = @import("../testing.zig");
const callback = @import("callback.zig");
const login = @import("login.zig");
const wire = @import("wire.zig");

pub const SignInError = login.ReceiveError || wire.Error || error{StateMismatch};

pub const Error = json_store.SaveError || error{ BadCredentials, NotAuthenticated };

pub const Commit = union(enum) {
    saved: []const u8,
    memory_only: struct {
        path: []const u8,
        save_error: Error,
    },
};

pub const SignIn = union(enum) {
    callback: callback.Binding,
    device,
};

pub const Secret = enum { access_token, api_key };

pub const ApiKey = struct {
    api_key: []const u8,

    fn deinit(self: ApiKey, gpa: std.mem.Allocator) void {
        gpa.free(self.api_key);
    }
};

pub const Options = struct {
    directories: json_store.Directories,
    account: []const u8,
    link: wire.Link,
};

pub const TokenError = wire.Error || error{ NotAuthenticated, KeyRejected, BadPrivateKey };

pub fn Bearer(comptime Auth: type) type {
    return struct {
        pub const vtable: providers.Credential.VTable = .{
            .token = bearerToken,
            .renew = renewToken,
        };

        fn bearerToken(
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
        ) providers.Credential.Error!?[]const u8 {
            const self: *Auth = @ptrCast(@alignCast(ptr));
            return self.accessToken(gpa) catch |err| {
                const failure: TokenError = err;
                if (failure == error.NotAuthenticated) return null;
                return credentialError(failure);
            };
        }

        fn renewToken(ptr: *anyopaque) providers.Credential.Error!bool {
            const self: *Auth = @ptrCast(@alignCast(ptr));
            return self.renew() catch |err| credentialError(err);
        }
    };
}

fn Key(comptime Auth: type) type {
    return struct {
        const vtable: providers.Credential.VTable = .{ .token = apiKey, .renew = renewKey };

        fn apiKey(ptr: *anyopaque, gpa: std.mem.Allocator) providers.Credential.Error!?[]const u8 {
            const self: *Auth = @ptrCast(@alignCast(ptr));
            return self.apiKey(gpa);
        }

        fn renewKey(ptr: *anyopaque) providers.Credential.Error!bool {
            _ = ptr;
            return false;
        }
    };
}

fn credentialError(failure: TokenError) providers.Credential.Error {
    return switch (failure) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.NotAuthenticated,
        error.BadCredentials,
        error.TokenGrantRejected,
        error.KeyRejected,
        error.BadPrivateKey,
        error.TokenRequestFailed,
        error.TokenResponseTooLarge,
        error.BadTokenResponse,
        error.BadDeviceResponse,
        error.MissingAccessToken,
        error.MissingRefreshToken,
        error.MissingExpiry,
        error.MissingAccountId,
        error.MissingApiKey,
        error.AuthorizationPending,
        error.SlowDown,
        error.AuthorizationDenied,
        error.DeviceCodeExpired,
        => error.Rejected,
        error.TokenServiceUnavailable => error.Network,
        inline else => |cause| network: {
            comptime core.error_set.requireMember(providers.Transport.Error, cause);
            break :network error.Network;
        },
    };
}

fn openStore(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Error!?json_store.File {
    return json_store.open(gpa, io, path) catch |err| switch (err) {
        error.CorruptStore => return error.BadCredentials,
        else => |other| return other,
    };
}

pub fn Store(comptime Flow: type) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        link: wire.Link,
        path: []const u8,
        account: []const u8,
        tokens: ?Tokens,
        save_pending: bool,
        mutex: std.Io.Mutex,

        const Self = @This();

        pub const flow = Flow;

        const Tokens = switch (Flow.secret) {
            .access_token => Flow.Tokens,
            .api_key => ApiKey,
        };

        const credential_vtable = switch (Flow.secret) {
            .access_token => Bearer(Self).vtable,
            .api_key => Key(Self).vtable,
        };

        const DevicePoller = struct {
            store: *Self,
            device_code: []const u8,

            const vtable: login.Poller(Tokens).VTable = .{ .poll = poll };

            fn poller(self: *DevicePoller) login.Poller(Tokens) {
                return .{ .ptr = self, .vtable = &vtable };
            }

            fn poll(ptr: *anyopaque) wire.Error!login.Poll(Tokens) {
                const self: *DevicePoller = @ptrCast(@alignCast(ptr));
                const store = self.store;
                return Flow.poll(store.gpa, store.io, &store.link, self.device_code);
            }
        };

        pub fn init(
            gpa: std.mem.Allocator,
            io: std.Io,
            options: *const Options,
        ) error{OutOfMemory}!Self {
            return .{
                .gpa = gpa,
                .io = io,
                .link = options.link,
                .path = try json_store.locate(gpa, &options.directories, "auth.json"),
                .account = options.account,
                .tokens = null,
                .save_pending = false,
                .mutex = .init,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.tokens) |tokens| tokens.deinit(self.gpa);
            self.gpa.free(self.path);
        }

        pub fn load(self: *Self) Error!bool {
            var file = (try openStore(self.gpa, self.io, self.path)) orelse return false;
            defer file.deinit();
            return self.loadEntry(&file);
        }

        pub fn signedIn(self: *Self) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.tokens != null;
        }

        pub fn credential(self: *Self) providers.Credential {
            return .{ .ptr = self, .vtable = &credential_vtable };
        }

        pub fn accessToken(self: *Self, gpa: std.mem.Allocator) ![]const u8 {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.save_pending) {
                const protection = self.io.swapCancelProtection(.blocked);
                defer _ = self.io.swapCancelProtection(protection);
                self.save() catch {};
            }
            if (self.tokens == null) return error.NotAuthenticated;
            if (self.expired()) try self.refresh();
            return gpa.dupe(u8, self.tokens.?.access);
        }

        pub fn apiKey(self: *Self, gpa: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
            return self.copyField("api_key", gpa);
        }

        pub fn copyField(
            self: *Self,
            comptime field: []const u8,
            gpa: std.mem.Allocator,
        ) error{OutOfMemory}!?[]const u8 {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const tokens = self.tokens orelse return null;
            return try gpa.dupe(u8, @field(tokens, field));
        }

        fn renew(self: *Self) !bool {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.tokens == null) return false;
            if (self.adoptStored()) return true;
            try self.refresh();
            return true;
        }

        pub fn signIn(self: *Self, context: *const login.Context) SignInError!Commit {
            const tokens = switch (comptime Flow.sign_in) {
                .callback => |binding| try self.receiveTokens(binding, context),
                .device => try self.pollTokens(context),
            };
            return self.commit(tokens);
        }

        pub fn signOut(self: *Self) Error!void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            json_store.remove(self.gpa, self.io, &.{
                .path = self.path,
                .key = self.account,
            }) catch |err|
                switch (err) {
                    error.CorruptStore => return error.BadCredentials,
                    else => |other| return other,
                };
            self.clear();
        }

        pub fn invalidate(self: *Self) Error!bool {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            const tokens = self.tokens orelse return error.NotAuthenticated;
            const removed = json_store.removeMatchingString(self.gpa, self.io, self.path, &.{
                .key = self.account,
                .field = "refresh",
                .expected = tokens.refresh,
            }) catch |err| {
                self.clear();
                return switch (err) {
                    error.CorruptStore => error.BadCredentials,
                    else => |other| other,
                };
            };
            self.clear();
            if (removed) return false;
            return self.load();
        }

        fn loadEntry(self: *Self, file: *const json_store.File) Error!bool {
            const entry = file.entry(self.account) orelse return false;
            const info = @typeInfo(Tokens).@"struct";
            var tokens: Tokens = undefined;
            var filled: usize = 0;
            errdefer {
                inline for (info.field_names, info.field_types, 0..) |name, field_type, index| {
                    if (comptime field_type == []const u8) {
                        if (index < filled) self.gpa.free(@field(tokens, name));
                    }
                }
            }
            inline for (info.field_names, info.field_types, 0..) |name, field_type, index| {
                const value = entry.get(name) orelse return error.BadCredentials;
                @field(tokens, name) = if (comptime field_type == []const u8) switch (value) {
                    .string => |string| try self.gpa.dupe(u8, string),
                    else => return error.BadCredentials,
                } else switch (value) {
                    .integer => |integer| integer,
                    else => return error.BadCredentials,
                };
                filled = index + 1;
            }
            if (self.tokens) |old| old.deinit(self.gpa);
            self.tokens = tokens;
            self.save_pending = false;
            return true;
        }

        fn expired(self: *const Self) bool {
            const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            return now_ms >= self.tokens.?.expires_ms;
        }

        fn refresh(self: *Self) !void {
            const maybe_fresh: ?Tokens = Flow.refresh(
                self.gpa,
                self.io,
                &self.link,
                &self.tokens.?,
            ) catch |first_error| switch (first_error) {
                error.Canceled => return error.Canceled,
                else => try self.refreshFromStore(first_error),
            };
            const fresh = maybe_fresh orelse return;
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);
            self.tokens.?.deinit(self.gpa);
            self.tokens = fresh;
            self.save() catch {};
        }

        fn refreshFromStore(self: *Self, first_error: wire.Error) wire.Error!?Tokens {
            if (!self.adoptStored()) return first_error;
            if (!self.expired()) return null;
            return try Flow.refresh(self.gpa, self.io, &self.link, &self.tokens.?);
        }

        fn adoptStored(self: *Self) bool {
            var stored = self.*;
            stored.mutex = .init;
            stored.tokens = null;
            defer stored.clear();
            const loaded = stored.load() catch return false;
            if (!loaded) return false;
            if (std.mem.eql(u8, self.tokens.?.refresh, stored.tokens.?.refresh)) return false;
            self.clear();
            self.tokens = stored.tokens;
            stored.tokens = null;
            return true;
        }

        fn receiveTokens(
            self: *Self,
            comptime binding: callback.Binding,
            context: *const login.Context,
        ) !Tokens {
            const pkce = wire.pkce(self.io);
            var path_buffer: [callback.path_bytes_max]u8 = undefined;
            const redirect = switch (binding) {
                .path => bound: {
                    const path = Flow.callbackPath(&path_buffer, self.io);
                    const url = try Flow.authorizeUrl(self.gpa, &pkce, path);
                    defer self.gpa.free(url);
                    break :bound try login.receive(self.gpa, context, &.{
                        .url = url,
                        .port = Flow.callback_port,
                        .expected = .{ .path = path },
                    });
                },
                .state => plain: {
                    const url = try Flow.authorizeUrl(self.gpa, &pkce);
                    defer self.gpa.free(url);
                    break :plain try login.receive(self.gpa, context, &.{
                        .url = url,
                        .port = Flow.callback_port,
                        .expected = .{ .state = &pkce.state },
                    });
                },
            };
            defer redirect.deinit(self.gpa);
            return self.exchange(binding, &redirect, &pkce);
        }

        fn exchange(
            self: *Self,
            comptime binding: callback.Binding,
            redirect: *const callback.Redirect,
            pkce: *const wire.Pkce,
        ) !Tokens {
            if (binding == .state) {
                const state = redirect.state orelse return error.StateMismatch;
                if (!std.mem.eql(u8, state, &pkce.state)) return error.StateMismatch;
            }
            return Flow.exchange(self.gpa, self.io, &self.link, redirect, pkce);
        }

        fn pollTokens(self: *Self, context: *const login.Context) !Tokens {
            const device = try Flow.requestDevice(self.gpa, self.io, &self.link);
            defer device.deinit(self.gpa);
            var poller: DevicePoller = .{ .store = self, .device_code = device.device_code };
            return login.poll(Tokens, self.io, context, &.{
                .url = device.url(),
                .code = device.user_code,
                .interval_ms = device.interval_ms,
                .lifetime_ms = device.lifetime_ms,
                .poller = poller.poller(),
            });
        }

        fn commit(self: *Self, tokens: Tokens) !Commit {
            self.mutex.lock(self.io) catch |err| {
                tokens.deinit(self.gpa);
                return err;
            };
            defer self.mutex.unlock(self.io);
            if (self.tokens) |old| old.deinit(self.gpa);
            self.tokens = tokens;
            self.save() catch |save_error| return .{ .memory_only = .{
                .path = self.path,
                .save_error = save_error,
            } };
            return .{ .saved = self.path };
        }

        fn clear(self: *Self) void {
            if (self.tokens) |tokens| tokens.deinit(self.gpa);
            self.tokens = null;
            self.save_pending = false;
        }

        fn save(self: *Self) Error!void {
            const tokens = self.tokens orelse return error.NotAuthenticated;
            json_store.save(self.gpa, self.io, &.{
                .path = self.path,
                .key = self.account,
            }, tokens, .{}) catch |err| {
                self.save_pending = true;
                return switch (err) {
                    error.CorruptStore => error.BadCredentials,
                    else => |other| other,
                };
            };
            self.save_pending = false;
        }
    };
}

test "a credential failure is a rejection only when the token service answered" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var subject = try signedInSubject(std.testing.io, &tmp, &.{
        .access = "stale",
        .refresh = "keep",
        .expires_ms = 0,
    });
    defer subject.deinit();
    const cases = [_]struct { wire.Error, providers.Credential.Error }{
        .{ error.Canceled, error.Canceled },
        .{ error.OutOfMemory, error.OutOfMemory },
        .{ error.TokenGrantRejected, error.Rejected },
        .{ error.TokenRequestFailed, error.Rejected },
        .{ error.TokenResponseTooLarge, error.Rejected },
        .{ error.BadTokenResponse, error.Rejected },
        .{ error.MissingAccessToken, error.Rejected },
        .{ error.MissingRefreshToken, error.Rejected },
        .{ error.MissingExpiry, error.Rejected },
        .{ error.MissingAccountId, error.Rejected },
        .{ error.TokenServiceUnavailable, error.Network },
        .{ error.ConnectionRefused, error.Network },
        .{ error.NameServerFailure, error.Network },
    };
    for (cases) |case| {
        test_refresh = .{ .fail = case[0] };
        try std.testing.expectError(case[1], subject.credential().token(gpa));
    }
}

const test_account = "test-plan";

const TestRefresh = union(enum) {
    fail: wire.Error,
    grant,
    grant_rotated,
    refuse_after_save,
    grant_after_cancel,
    hold,
};

var test_refresh: TestRefresh = .{ .fail = error.TokenGrantRejected };
var test_race_path: []const u8 = "";
var test_refresh_count: u32 = 0;
var test_refresh_cancels: u32 = 0;
var test_refresh_entered: std.Io.Event = .unset;
var test_refresh_release: std.Io.Event = .unset;
var test_verifier: @FieldType(wire.Pkce, "verifier") = undefined;

const TestFlow = struct {
    const secret: Secret = .access_token;

    const Tokens = struct {
        access: []const u8,
        refresh: []const u8,
        expires_ms: i64,

        fn deinit(self: *const Tokens, gpa: std.mem.Allocator) void {
            gpa.free(self.access);
            gpa.free(self.refresh);
        }
    };

    fn refresh(
        gpa: std.mem.Allocator,
        io: std.Io,
        _: *const wire.Link,
        tokens: *const Tokens,
    ) wire.Error!Tokens {
        test_refresh_count += 1;
        switch (test_refresh) {
            .fail => |failure| return failure,
            .grant => {},
            .grant_rotated => {
                if (!std.mem.eql(u8, tokens.refresh, "rotated")) return error.TokenGrantRejected;
            },
            .refuse_after_save => {
                json_store.save(gpa, io, &.{ .path = test_race_path, .key = test_account }, .{
                    .access = "winner_access",
                    .refresh = "winner",
                    .expires_ms = std.math.maxInt(i64),
                }, .{}) catch return error.TokenRequestFailed;
                return error.TokenGrantRejected;
            },
            .grant_after_cancel => {
                var never: std.Io.Event = .unset;
                if (never.wait(io)) |_| unreachable else |_| {
                    test_refresh_cancels += 1;
                    io.recancel();
                }
            },
            .hold => {
                test_refresh_entered.set(io);
                try test_refresh_release.wait(io);
            },
        }
        return testTokens(gpa, "fresh", "next", std.math.maxInt(i64));
    }
};

const KeyFlow = struct {
    const secret: Secret = .api_key;
    const sign_in: SignIn = .{ .callback = .state };
    const callback_port = 0;

    fn authorizeUrl(gpa: std.mem.Allocator, pkce: *const wire.Pkce) error{OutOfMemory}![]u8 {
        test_verifier = pkce.verifier;
        return gpa.dupe(u8, "https://auth.test/authorize");
    }

    fn exchange(
        gpa: std.mem.Allocator,
        io: std.Io,
        link: *const wire.Link,
        redirect: *const callback.Redirect,
        _: *const wire.Pkce,
    ) wire.Error!ApiKey {
        return .{ .api_key = try wire.post(gpa, io, link, &.{
            .url = "https://auth.test/token",
            .content_type = wire.form_content_type,
            .body = redirect.code,
        }) };
    }
};

fn testTokens(
    gpa: std.mem.Allocator,
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,
) error{OutOfMemory}!TestFlow.Tokens {
    const access_copy = try gpa.dupe(u8, access);
    errdefer gpa.free(access_copy);
    return .{
        .access = access_copy,
        .refresh = try gpa.dupe(u8, refresh),
        .expires_ms = expires_ms,
    };
}

fn testSubject(
    comptime Flow: type,
    io: std.Io,
    tmp: *const std.testing.TmpDir,
    link: wire.Link,
) !Store(Flow) {
    var home_buffer: [128]u8 = undefined;
    return Store(Flow).init(std.testing.allocator, io, &.{
        .directories = .{
            .working_directory = ".",
            .home = try testing.tmpHome(&home_buffer, tmp),
        },
        .account = test_account,
        .link = link,
    });
}

fn signedInSubject(
    io: std.Io,
    tmp: *const std.testing.TmpDir,
    tokens: *const TestFlow.Tokens,
) !Store(TestFlow) {
    try saveTokens(io, tmp, tokens);
    var subject = try testSubject(TestFlow, io, tmp, .{});
    errdefer subject.deinit();
    try std.testing.expect(try subject.load());
    return subject;
}

fn storePath(buffer: *[128]u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    return testing.tmpPath(buffer, tmp, ".drinky/auth.json");
}

fn saveTokens(io: std.Io, tmp: *const std.testing.TmpDir, tokens: *const TestFlow.Tokens) !void {
    var path_buffer: [128]u8 = undefined;
    try json_store.save(std.testing.allocator, io, &.{
        .path = try storePath(&path_buffer, tmp),
        .key = test_account,
    }, tokens.*, .{});
}

fn expectAccess(expected: []const u8, subject: *Store(TestFlow)) !void {
    const access = try subject.accessToken(std.testing.allocator);
    defer std.testing.allocator.free(access);
    try std.testing.expectEqualStrings(expected, access);
}

fn expectField(
    comptime field: []const u8,
    expected: []const u8,
    subject: *Store(TestFlow),
) !void {
    const value = (try subject.copyField(field, std.testing.allocator)).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings(expected, value);
}

fn expectKey(expected: []const u8, subject: *Store(KeyFlow)) !void {
    const key = (try subject.apiKey(std.testing.allocator)).?;
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings(expected, key);
}

fn expectStoredRefresh(io: std.Io, tmp: *const std.testing.TmpDir, expected: []const u8) !void {
    var path_buffer: [128]u8 = undefined;
    const path = try storePath(&path_buffer, tmp);
    var file = try json_store.open(std.testing.allocator, io, path) orelse
        return error.TestUnexpectedResult;
    defer file.deinit();
    try std.testing.expectEqualStrings(
        expected,
        file.entry(test_account).?.get("refresh").?.string,
    );
}

const ScriptedSignIn = struct {
    state: State = .matching,
    browser: testing.FakeBrowser = .{},

    const State = enum { matching, another, verifier, absent };

    const prompt_vtable: login.Prompt.VTable = .{
        .showAuthorization = showAuthorization,
        .showDeviceCode = showDeviceCode,
        .showBrowserLaunchFailed = showBrowserLaunchFailed,
    };

    const loopback_vtable: callback.Loopback.VTable = .{
        .listen = listen,
        .receive = receive,
        .close = close,
        .replay = replay,
    };

    fn context(self: *ScriptedSignIn) login.Context {
        return .{
            .prompt = .{ .ptr = self, .vtable = &prompt_vtable },
            .browser = self.browser.browser(),
            .loopback = .{ .ptr = self, .vtable = &loopback_vtable },
        };
    }

    fn showAuthorization(_: *anyopaque, _: []const u8, _: ?[]const u8) error{OutOfMemory}!void {}

    fn showDeviceCode(_: *anyopaque, _: []const u8, _: []const u8) error{OutOfMemory}!void {
        unreachable;
    }

    fn showBrowserLaunchFailed(_: *anyopaque) void {}

    fn listen(_: *anyopaque, _: u16) std.Io.net.IpAddress.ListenError!void {}

    fn receive(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        expected: *const callback.Expected,
    ) callback.Loopback.ReceiveError!callback.Redirect {
        const self: *ScriptedSignIn = @ptrCast(@alignCast(ptr));
        const maybe_state: ?[]const u8 = switch (self.state) {
            .matching => expected.state,
            .another => "another",
            .verifier => &test_verifier,
            .absent => null,
        };
        const code = try gpa.dupe(u8, "code");
        errdefer gpa.free(code);
        return .{
            .code = code,
            .state = if (maybe_state) |state| try gpa.dupe(u8, state) else null,
        };
    }

    fn close(_: *anyopaque) void {}

    fn replay(_: *anyopaque, _: u16, _: []const u8) callback.Loopback.ReplayError!void {
        unreachable;
    }
};

test "a store takes its path from the home and its entry from the id of its row" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);
    var path_buffer: [128]u8 = undefined;
    const path = try storePath(&path_buffer, &tmp);

    var subject = try Store(TestFlow).init(gpa, io, &.{
        .directories = .{ .working_directory = ".", .home = home },
        .account = test_account,
        .link = .{},
    });
    defer subject.deinit();
    try std.testing.expect(!try subject.load());
    try json_store.save(gpa, io, &.{
        .path = path,
        .key = "another-plan",
    }, .{ .access = "a" }, .{});
    try std.testing.expect(!try subject.load());
    try json_store.save(gpa, io, &.{ .path = path, .key = test_account }, .{
        .access = "at",
        .refresh = "rt",
    }, .{});
    try std.testing.expectError(error.BadCredentials, subject.load());
    try json_store.save(gpa, io, &.{ .path = path, .key = test_account }, .{
        .access = "at",
        .refresh = "rt",
        .expires_ms = std.math.maxInt(i64),
    }, .{});
    try std.testing.expect(try subject.load());
    try expectAccess("at", &subject);
}

test "a signed-out store refuses a token and holds no field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var subject = try testSubject(TestFlow, std.testing.io, &tmp, .{});
    defer subject.deinit();
    try std.testing.expect(!try subject.load());
    try std.testing.expectError(error.NotAuthenticated, subject.accessToken(std.testing.allocator));
    try std.testing.expect(try subject.copyField("refresh", std.testing.allocator) == null);
    try std.testing.expect(!subject.signedIn());
    try std.testing.expect(try subject.credential().token(std.testing.allocator) == null);
    try std.testing.expect(!try subject.credential().renew());
}

test "an api key store reads its key and rejects an entry without one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.writeStore(io, &tmp, "{\"test-plan\":{\"api_key\":\"sk-x\"}}");

    var subject = try testSubject(KeyFlow, io, &tmp, .{});
    defer subject.deinit();
    try std.testing.expect(try subject.load());
    const key = (try subject.credential().token(gpa)).?;
    defer gpa.free(key);
    try std.testing.expectEqualStrings("sk-x", key);
    try std.testing.expect(!try subject.credential().renew());

    try testing.writeStore(io, &tmp, "{\"test-plan\":{}}");
    var missing = try testSubject(KeyFlow, io, &tmp, .{});
    defer missing.deinit();
    try std.testing.expectError(error.BadCredentials, missing.load());
    try std.testing.expect(try missing.apiKey(gpa) == null);
}

test "load ignores the marker keys that an earlier store wrote" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.writeStore(io, &tmp,
        \\{"test-plan":
        \\  {"access":"a","refresh":"r","expires_ms":1,
        \\   "account_uuid":"account","organization_uuid":"organization"}}
    );
    var subject = try testSubject(TestFlow, io, &tmp, .{});
    defer subject.deinit();
    try std.testing.expect(try subject.load());
    try expectField("refresh", "r", &subject);
}

test "load rejects an entry missing a credential field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.writeStore(io, &tmp, "{\"test-plan\":{\"access\":\"a\"}}");
    var subject = try testSubject(TestFlow, io, &tmp, .{});
    defer subject.deinit();
    try std.testing.expectError(error.BadCredentials, subject.load());
    try std.testing.expect(!subject.signedIn());
}

test "a state sign-in refuses the redirect of another sign-in before the exchange" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var transport: providers.testing.FakeTransport = .{
        .gpa = gpa,
        .replies = &.{.{ .body = "sk-x" }},
    };
    defer transport.deinit();
    var subject = try testSubject(KeyFlow, io, &tmp, .{ .transport = transport.transport() });
    defer subject.deinit();

    for ([_]ScriptedSignIn.State{ .another, .verifier, .absent }) |state| {
        var scripted: ScriptedSignIn = .{ .state = state };
        const context = scripted.context();
        try std.testing.expectError(error.StateMismatch, subject.signIn(&context));
    }
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
    try std.testing.expect(!subject.signedIn());

    var matching: ScriptedSignIn = .{};
    const context = matching.context();
    _ = try subject.signIn(&context);
    try std.testing.expectEqual(@as(usize, 1), transport.requests.items.len);
    try expectKey("sk-x", &subject);
}

test "a sign-in whose save fails keeps its key in memory, and the next sign-in saves" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.writeStore(io, &tmp, "not json");
    var transport: providers.testing.FakeTransport = .{ .gpa = gpa, .replies = &.{
        .{ .body = "k1" },
        .{ .body = "k2" },
    } };
    defer transport.deinit();
    var subject = try testSubject(KeyFlow, io, &tmp, .{ .transport = transport.transport() });
    defer subject.deinit();
    var path_buffer: [128]u8 = undefined;
    const path = try storePath(&path_buffer, &tmp);
    var scripted: ScriptedSignIn = .{};
    const context = scripted.context();

    switch (try subject.signIn(&context)) {
        .memory_only => |failure| {
            try std.testing.expectEqualStrings(path, failure.path);
            try std.testing.expectEqual(error.BadCredentials, failure.save_error);
        },
        .saved => return error.TestUnexpectedResult,
    }
    try expectKey("k1", &subject);

    try tmp.dir.deleteFile(io, ".drinky/auth.json");
    switch (try subject.signIn(&context)) {
        .saved => |saved| try std.testing.expectEqualStrings(path, saved),
        .memory_only => return error.TestUnexpectedResult,
    }
    try expectKey("k2", &subject);
    var file = (try json_store.open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("k2", file.entry(test_account).?.get("api_key").?.string);
}

test "a live access token is returned without a refresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .{ .fail = error.TokenGrantRejected };
    var subject = try signedInSubject(std.testing.io, &tmp, &.{
        .access = "live",
        .refresh = "keep",
        .expires_ms = std.math.maxInt(i64),
    });
    defer subject.deinit();
    try expectAccess("live", &subject);
}

test "a failed refresh leaves the stored credential intact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .{ .fail = error.TokenGrantRejected };
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "stale",
        .refresh = "keep",
        .expires_ms = 0,
    });
    defer subject.deinit();

    try std.testing.expectError(error.TokenGrantRejected, subject.accessToken(gpa));
    try expectField("access", "stale", &subject);
    try expectField("refresh", "keep", &subject);
    try expectStoredRefresh(io, &tmp, "keep");

    try tmp.dir.deleteFile(io, ".drinky/auth.json");
    try std.testing.expectError(error.TokenGrantRejected, subject.accessToken(gpa));
    try expectField("access", "stale", &subject);
    try expectField("refresh", "keep", &subject);
}

test "a refresh token rotated by another instance recovers without a restart" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .grant_rotated;
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "stale",
        .refresh = "dead",
        .expires_ms = 0,
    });
    defer subject.deinit();
    try saveTokens(io, &tmp, &.{
        .access = "rotated_access",
        .refresh = "rotated",
        .expires_ms = 0,
    });

    try expectAccess("fresh", &subject);
    try expectField("refresh", "next", &subject);
    try expectStoredRefresh(io, &tmp, "next");
}

test "a live credential from another instance is used without a refresh" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .{ .fail = error.TokenGrantRejected };
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "stale",
        .refresh = "dead",
        .expires_ms = 0,
    });
    defer subject.deinit();
    try saveTokens(io, &tmp, &.{
        .access = "saved_access",
        .refresh = "saved",
        .expires_ms = std.math.maxInt(i64),
    });

    try expectAccess("saved_access", &subject);
    try expectField("refresh", "saved", &subject);
    try expectStoredRefresh(io, &tmp, "saved");
}

test "a retry that also fails keeps the credential the store holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .{ .fail = error.TokenGrantRejected };
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "stale",
        .refresh = "dead",
        .expires_ms = 0,
    });
    defer subject.deinit();
    try saveTokens(io, &tmp, &.{ .access = "stored_access", .refresh = "stored", .expires_ms = 0 });

    try std.testing.expectError(error.TokenGrantRejected, subject.accessToken(gpa));
    try expectField("access", "stored_access", &subject);
    try expectField("refresh", "stored", &subject);
    try expectStoredRefresh(io, &tmp, "stored");
}

test "a rejected access token takes the credential another instance saved" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .{ .fail = error.TokenGrantRejected };
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "revoked",
        .refresh = "dead",
        .expires_ms = std.math.maxInt(i64),
    });
    defer subject.deinit();
    try saveTokens(io, &tmp, &.{
        .access = "saved_access",
        .refresh = "saved",
        .expires_ms = std.math.maxInt(i64),
    });

    try std.testing.expect(try subject.credential().renew());
    try expectField("refresh", "saved", &subject);
    try expectAccess("saved_access", &subject);
}

test "a renewal whose refresh fails takes the credential that landed meanwhile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    test_refresh = .refuse_after_save;
    test_race_path = try storePath(&path_buffer, &tmp);
    defer test_race_path = "";
    var subject = try signedInSubject(std.testing.io, &tmp, &.{
        .access = "revoked",
        .refresh = "spent",
        .expires_ms = std.math.maxInt(i64),
    });
    defer subject.deinit();

    try std.testing.expect(try subject.credential().renew());
    try expectField("refresh", "winner", &subject);
    try expectAccess("winner_access", &subject);
}

test "a rejected access token refreshes although its own clock reads live" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .grant;
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "revoked",
        .refresh = "live",
        .expires_ms = std.math.maxInt(i64),
    });
    defer subject.deinit();

    try std.testing.expect(try subject.credential().renew());
    try expectField("refresh", "next", &subject);
    try expectAccess("fresh", &subject);
    try expectStoredRefresh(io, &tmp, "next");
}

test "invalidation preserves a newer refresh token from another instance" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "rejected_access",
        .refresh = "rejected_refresh",
        .expires_ms = 0,
    });
    defer subject.deinit();
    try saveTokens(io, &tmp, &.{
        .access = "new_access",
        .refresh = "new_refresh",
        .expires_ms = std.math.maxInt(i64),
    });

    try std.testing.expect(try subject.invalidate());
    try expectField("refresh", "new_refresh", &subject);
    try expectStoredRefresh(io, &tmp, "new_refresh");
}

test "an expired access token is refreshed and saved again" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .grant;
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "stale",
        .refresh = "old",
        .expires_ms = 0,
    });
    defer subject.deinit();

    try expectAccess("fresh", &subject);
    try expectField("refresh", "next", &subject);
    try expectStoredRefresh(io, &tmp, "next");

    var loaded = try testSubject(TestFlow, io, &tmp, .{});
    defer loaded.deinit();
    try std.testing.expect(try loaded.load());
    try expectAccess("fresh", &loaded);
}

test "a busy store retries a refreshed credential before the next request" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .grant;
    var clock: core.testing.ClockIo = undefined;
    clock.init(gpa);
    defer clock.deinit();
    var subject = try signedInSubject(clock.io(), &tmp, &.{
        .access = "stale",
        .refresh = "old",
        .expires_ms = 0,
    });
    defer subject.deinit();

    var path_buffer: [128]u8 = undefined;
    const path = try storePath(&path_buffer, &tmp);
    const lock_path = try gpa.print("{s}.lock", .{path});
    defer gpa.free(lock_path);
    {
        var held = try std.Io.Dir.cwd().createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = .fromMode(0o600),
        });
        defer held.close(io);
        try expectAccess("fresh", &subject);
    }
    try expectStoredRefresh(io, &tmp, "old");

    try expectAccess("fresh", &subject);
    try expectStoredRefresh(io, &tmp, "next");
}

test "a renewal whose save fails keeps the fresh token and saves at the next request" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .grant;
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "revoked",
        .refresh = "old",
        .expires_ms = std.math.maxInt(i64),
    });
    defer subject.deinit();
    try testing.writeStore(io, &tmp, "not json");

    try std.testing.expect(try subject.credential().renew());
    try expectField("access", "fresh", &subject);

    try tmp.dir.deleteFile(io, ".drinky/auth.json");
    test_refresh = .{ .fail = error.TokenGrantRejected };
    try expectAccess("fresh", &subject);
    try expectStoredRefresh(io, &tmp, "next");
}

test "a cancel landing at the save cannot lose the rotated credential" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .grant_after_cancel;
    test_refresh_cancels = 0;
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "stale",
        .refresh = "old",
        .expires_ms = 0,
    });
    defer subject.deinit();

    var future = try io.concurrent(requestToken, .{ &subject, false });
    const access = try future.cancel(io);
    defer gpa.free(access);
    try std.testing.expectEqualStrings("fresh", access);
    try std.testing.expectEqual(@as(u32, 1), test_refresh_cancels);
    try expectField("refresh", "next", &subject);
    try expectStoredRefresh(io, &tmp, "next");
}

threadlocal var watched_task = false;

const WatchedIo = struct {
    threaded: std.Io.Threaded,
    backend: *const std.Io.VTable,
    vtable: std.Io.VTable,
    blocked: std.Io.Event,

    fn init(self: *WatchedIo, gpa: std.mem.Allocator) void {
        self.threaded = .init(gpa, .{});
        self.backend = self.threaded.io().vtable;
        self.vtable = self.backend.*;
        self.vtable.futexWait = futexWait;
        self.blocked = .unset;
    }

    fn io(self: *WatchedIo) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    fn futexWait(
        userdata: ?*anyopaque,
        ptr: *const u32,
        expected: u32,
        timeout: std.Io.Timeout,
    ) std.Io.Cancelable!void {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *WatchedIo = @fieldParentPtr("threaded", threaded);
        if (watched_task) self.blocked.set(.{ .userdata = userdata, .vtable = self.backend });
        return self.backend.futexWait(userdata, ptr, expected, timeout);
    }
};

fn requestToken(subject: *Store(TestFlow), watched: bool) TokenError![]const u8 {
    watched_task = watched;
    defer watched_task = false;
    return subject.accessToken(std.testing.allocator);
}

test "a token request waits for the refresh that another task runs and refreshes nothing" {
    const gpa = std.testing.allocator;
    var watched: WatchedIo = undefined;
    watched.init(gpa);
    defer watched.threaded.deinit();
    const io = watched.io();
    test_refresh = .hold;
    test_refresh_count = 0;
    test_refresh_entered = .unset;
    test_refresh_release = .unset;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "stale",
        .refresh = "old",
        .expires_ms = 0,
    });
    defer subject.deinit();

    var first = try io.concurrent(requestToken, .{ &subject, false });
    try test_refresh_entered.wait(io);
    var second = try io.concurrent(requestToken, .{ &subject, true });
    try watched.blocked.wait(io);
    test_refresh_release.set(io);
    const first_token = try first.await(io);
    defer gpa.free(first_token);
    const second_token = try second.await(io);
    defer gpa.free(second_token);
    try std.testing.expectEqualStrings("fresh", first_token);
    try std.testing.expectEqualStrings("fresh", second_token);
    try std.testing.expectEqual(@as(u32, 1), test_refresh_count);
}

test "a cancel during a refresh ends the token request although another instance saved a token" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    test_refresh = .hold;
    test_refresh_entered = .unset;
    test_refresh_release = .unset;
    var subject = try signedInSubject(io, &tmp, &.{
        .access = "stale",
        .refresh = "old",
        .expires_ms = 0,
    });
    defer subject.deinit();
    try saveTokens(io, &tmp, &.{
        .access = "saved_access",
        .refresh = "saved",
        .expires_ms = std.math.maxInt(i64),
    });

    var request = try io.concurrent(requestToken, .{ &subject, false });
    try test_refresh_entered.wait(io);
    const token = request.cancel(io) catch |err| {
        try std.testing.expectEqual(error.Canceled, err);
        return;
    };
    gpa.free(token);
    return error.TestExpectedCanceled;
}
