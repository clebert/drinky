const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const callback = @import("callback.zig");
const wire = @import("wire.zig");

const slow_down_increment_ms = 5_000;
const interval_ms_min = 1_000;
const lifetime_ms_max = 5 * std.time.ms_per_min;

pub const NetworkError = providers.Transport.Error ||
    std.Io.net.IpAddress.ListenError ||
    std.Io.net.IpAddress.ConnectError ||
    std.Io.net.Server.AcceptError;

pub const ReceiveError = std.Io.net.IpAddress.ListenError ||
    callback.Loopback.ReceiveError ||
    error{ OutOfMemory, Canceled };

pub const Prompt = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        showAuthorization: *const fn (
            ptr: *anyopaque,
            url: []const u8,
            callback_path: ?[]const u8,
        ) error{OutOfMemory}!void,
        showDeviceCode: *const fn (
            ptr: *anyopaque,
            url: []const u8,
            code: []const u8,
        ) error{OutOfMemory}!void,
        showBrowserLaunchFailed: *const fn (ptr: *anyopaque) void,
    };

    fn showAuthorization(
        self: Prompt,
        url: []const u8,
        callback_path: ?[]const u8,
    ) error{OutOfMemory}!void {
        return self.vtable.showAuthorization(self.ptr, url, callback_path);
    }

    fn showDeviceCode(self: Prompt, url: []const u8, code: []const u8) error{OutOfMemory}!void {
        return self.vtable.showDeviceCode(self.ptr, url, code);
    }

    fn showBrowserLaunchFailed(self: Prompt) void {
        self.vtable.showBrowserLaunchFailed(self.ptr);
    }
};

pub const Browser = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        launch: *const fn (ptr: *anyopaque, url: []const u8) error{Canceled}!bool,
        reap: *const fn (ptr: *anyopaque) void,
    };

    fn launch(self: Browser, url: []const u8) error{Canceled}!bool {
        return self.vtable.launch(self.ptr, url);
    }

    fn reap(self: Browser) void {
        self.vtable.reap(self.ptr);
    }
};

pub const Opener = struct {
    io: std.Io,
    child: ?std.process.Child = null,

    const vtable: Browser.VTable = .{ .launch = launch, .reap = reap };

    pub fn browser(self: *Opener) Browser {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn launch(ptr: *anyopaque, url: []const u8) error{Canceled}!bool {
        const self: *Opener = @ptrCast(@alignCast(ptr));
        for ([_][]const u8{ "xdg-open", "open" }) |launcher| {
            self.child = std.process.spawn(
                self.io,
                .{ .argv = &.{ launcher, url } },
            ) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            return true;
        }
        return false;
    }

    fn reap(ptr: *anyopaque) void {
        const self: *Opener = @ptrCast(@alignCast(ptr));
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
    }
};

pub const Context = struct {
    prompt: Prompt,
    browser: Browser,
    loopback: callback.Loopback,
};

const Wait = struct {
    url: []const u8,
    port: u16,
    expected: callback.Expected,
};

pub fn Poll(comptime Result: type) type {
    return union(enum) {
        pending,
        slow_down,
        granted: Result,
    };
}

pub fn Poller(comptime Result: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const Self = @This();

        pub const VTable = struct {
            poll: *const fn (ptr: *anyopaque) wire.Error!Poll(Result),
        };

        fn poll(self: Self) wire.Error!Poll(Result) {
            return self.vtable.poll(self.ptr);
        }
    };
}

fn Device(comptime Result: type) type {
    return struct {
        url: []const u8,
        code: []const u8,
        interval_ms: u64,
        lifetime_ms: u64,
        poller: Poller(Result),
    };
}

pub fn receive(
    gpa: std.mem.Allocator,
    context: *const Context,
    wait: *const Wait,
) ReceiveError!callback.Redirect {
    try context.loopback.listen(wait.port);
    defer context.loopback.close();

    const callback_path: ?[]const u8 = switch (wait.expected) {
        .path => |path| path,
        .state => null,
    };
    try context.prompt.showAuthorization(wait.url, callback_path);

    const launched = try context.browser.launch(wait.url);
    defer if (launched) context.browser.reap();
    if (!launched) context.prompt.showBrowserLaunchFailed();

    return context.loopback.receive(gpa, &wait.expected);
}

pub fn poll(
    comptime Result: type,
    io: std.Io,
    context: *const Context,
    device: *const Device(Result),
) wire.Error!Result {
    try context.prompt.showDeviceCode(device.url, device.code);

    const launched = try context.browser.launch(device.url);
    defer if (launched) context.browser.reap();
    if (!launched) context.prompt.showBrowserLaunchFailed();

    var interval_ms: u64 = @max(device.interval_ms, interval_ms_min);
    var remaining_ms: u64 = @min(device.lifetime_ms, lifetime_ms_max);
    while (remaining_ms > 0) {
        const wait_ms = @min(interval_ms, remaining_ms);
        try core.timeout.sleep(io, wait_ms);
        remaining_ms -= wait_ms;
        switch (try device.poller.poll()) {
            .pending => {},
            .slow_down => interval_ms += slow_down_increment_ms,
            .granted => |result| return result,
        }
    }
    return error.DeviceCodeExpired;
}

test "callback progress does not wait for browser lifetime and reaps helper" {
    var fake: Fake = .{};
    try expectReceived(&fake);
    try std.testing.expect(fake.received_while_browser_running);
    try std.testing.expect(fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqualStrings("/deadbeef", fake.reported_path.?);
}

const Fake = struct {
    listen_fails: bool = false,
    listening: bool = false,
    close_count: usize = 0,
    receive_fails: bool = false,
    received_while_browser_running: bool = false,
    authorization_count: usize = 0,
    authorization_fails: bool = false,
    reported_path: ?[]const u8 = null,
    url_shown: []const u8 = "",
    code_shown: []const u8 = "",
    warning_count: usize = 0,
    launch_result: enum { success, unavailable, canceled } = .success,
    launched_while_listening: bool = false,
    browser_running: bool = false,
    browser_reaped: bool = false,
    answers: []const Poll(void) = &.{},
    polled: usize = 0,

    const prompt_vtable: Prompt.VTable = .{
        .showAuthorization = showAuthorization,
        .showDeviceCode = showDeviceCode,
        .showBrowserLaunchFailed = showBrowserLaunchFailed,
    };
    const browser_vtable: Browser.VTable = .{ .launch = launch, .reap = reap };
    const loopback_vtable: callback.Loopback.VTable = .{
        .listen = listen,
        .receive = receiveRedirect,
        .close = close,
        .replay = replay,
    };
    const poller_vtable: Poller(void).VTable = .{ .poll = pollGrant };

    fn context(self: *Fake) Context {
        return .{
            .prompt = .{ .ptr = self, .vtable = &prompt_vtable },
            .browser = .{ .ptr = self, .vtable = &browser_vtable },
            .loopback = .{ .ptr = self, .vtable = &loopback_vtable },
        };
    }

    fn device(self: *Fake, interval_ms: u64, lifetime_ms: u64) Device(void) {
        return .{
            .url = "https://example.test/activate?user_code=ABCD-EFGH",
            .code = "ABCD-EFGH",
            .interval_ms = interval_ms,
            .lifetime_ms = lifetime_ms,
            .poller = .{ .ptr = self, .vtable = &poller_vtable },
        };
    }

    fn of(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }

    fn showAuthorization(
        ptr: *anyopaque,
        _: []const u8,
        callback_path: ?[]const u8,
    ) error{OutOfMemory}!void {
        const self = of(ptr);
        self.reported_path = callback_path;
        self.authorization_count += 1;
        if (self.authorization_fails) return error.OutOfMemory;
    }

    fn showDeviceCode(ptr: *anyopaque, url: []const u8, code: []const u8) error{OutOfMemory}!void {
        const self = of(ptr);
        self.url_shown = url;
        self.code_shown = code;
    }

    fn showBrowserLaunchFailed(ptr: *anyopaque) void {
        of(ptr).warning_count += 1;
    }

    fn launch(ptr: *anyopaque, _: []const u8) error{Canceled}!bool {
        const self = of(ptr);
        self.launched_while_listening = self.listening;
        return switch (self.launch_result) {
            .success => success: {
                self.browser_running = true;
                break :success true;
            },
            .unavailable => false,
            .canceled => error.Canceled,
        };
    }

    fn reap(ptr: *anyopaque) void {
        const self = of(ptr);
        self.browser_running = false;
        self.browser_reaped = true;
    }

    fn listen(ptr: *anyopaque, _: u16) std.Io.net.IpAddress.ListenError!void {
        const self = of(ptr);
        if (self.listen_fails) return error.AddressInUse;
        self.listening = true;
    }

    fn receiveRedirect(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        _: *const callback.Expected,
    ) callback.Loopback.ReceiveError!callback.Redirect {
        const self = of(ptr);
        self.received_while_browser_running = self.browser_running;
        if (self.receive_fails) return error.CallbackTimeout;
        return .{ .code = try gpa.dupe(u8, "code") };
    }

    fn close(ptr: *anyopaque) void {
        const self = of(ptr);
        self.listening = false;
        self.close_count += 1;
    }

    fn replay(_: *anyopaque, _: u16, _: []const u8) callback.Loopback.ReplayError!void {}

    fn pollGrant(ptr: *anyopaque) wire.Error!Poll(void) {
        const self = of(ptr);
        const index = self.polled;
        self.polled += 1;
        if (index >= self.answers.len) return error.TokenRequestFailed;
        return self.answers[index];
    }
};

const test_wait: Wait = .{
    .url = "https://example.test/authorize",
    .port = 53692,
    .expected = .{ .path = "/deadbeef" },
};

fn expectReceived(fake: *Fake) !void {
    const redirect = try receive(std.testing.allocator, &fake.context(), &test_wait);
    redirect.deinit(std.testing.allocator);
}

test "listener setup failure does not show or launch browser" {
    var fake: Fake = .{ .listen_fails = true };
    try std.testing.expectError(error.AddressInUse, expectReceived(&fake));
    try std.testing.expectEqual(@as(usize, 0), fake.authorization_count);
    try std.testing.expect(!fake.browser_running and !fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 0), fake.close_count);
}

test "listener is ready before browser can deliver redirect" {
    var fake: Fake = .{};
    try expectReceived(&fake);
    try std.testing.expect(fake.launched_while_listening);
}

test "browser launch fallback warns and continues listening" {
    var fake: Fake = .{ .launch_result = .unavailable };
    try expectReceived(&fake);
    try std.testing.expectEqual(@as(usize, 1), fake.warning_count);
    try std.testing.expect(!fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}

test "callback error reaps browser and closes listener" {
    var fake: Fake = .{ .receive_fails = true };
    try std.testing.expectError(error.CallbackTimeout, expectReceived(&fake));
    try std.testing.expect(fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}

test "authorization output error closes listener without launching browser" {
    var fake: Fake = .{ .authorization_fails = true };
    try std.testing.expectError(error.OutOfMemory, expectReceived(&fake));
    try std.testing.expect(!fake.browser_running and !fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}

test "browser launch cancellation closes listener without warning" {
    var fake: Fake = .{ .launch_result = .canceled };
    try std.testing.expectError(error.Canceled, expectReceived(&fake));
    try std.testing.expectEqual(@as(usize, 0), fake.warning_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}

fn expectPolled(
    fake: *Fake,
    clock: *core.testing.ClockIo,
    interval_ms: u64,
    lifetime_ms: u64,
) !void {
    try poll(void, clock.io(), &fake.context(), &fake.device(interval_ms, lifetime_ms));
}

test "a device grant waits one interval between polls and returns the grant" {
    var clock: core.testing.ClockIo = undefined;
    clock.init(std.testing.allocator);
    defer clock.deinit();
    var fake: Fake = .{ .answers = &.{ .pending, .pending, .{ .granted = {} } } };
    try expectPolled(&fake, &clock, 5_000, 60_000);
    try std.testing.expectEqualStrings("ABCD-EFGH", fake.code_shown);
    try std.testing.expectEqualStrings(
        "https://example.test/activate?user_code=ABCD-EFGH",
        fake.url_shown,
    );
    try std.testing.expectEqual(@as(usize, 3), fake.polled);
    try std.testing.expectEqualSlices(u64, &.{ 5_000, 5_000, 5_000 }, clock.slept());
    try std.testing.expect(fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 0), fake.warning_count);
}

test "a slow_down answer lengthens the poll interval" {
    var clock: core.testing.ClockIo = undefined;
    clock.init(std.testing.allocator);
    defer clock.deinit();
    var fake: Fake = .{ .answers = &.{ .slow_down, .pending, .{ .granted = {} } } };
    try expectPolled(&fake, &clock, 5_000, 60_000);
    try std.testing.expectEqualSlices(u64, &.{ 5_000, 10_000, 10_000 }, clock.slept());
}

test "a device grant that never arrives expires with its window" {
    var clock: core.testing.ClockIo = undefined;
    clock.init(std.testing.allocator);
    defer clock.deinit();
    var fake: Fake = .{ .answers = &.{ .pending, .pending, .pending } };
    const expired = expectPolled(&fake, &clock, 5_000, 12_000);
    try std.testing.expectError(error.DeviceCodeExpired, expired);
    try std.testing.expectEqual(@as(usize, 3), fake.polled);
    try std.testing.expectEqualSlices(u64, &.{ 5_000, 5_000, 2_000 }, clock.slept());
    try std.testing.expect(fake.browser_reaped);
}

test "a long grant lifetime ends at the ceiling" {
    var clock: core.testing.ClockIo = undefined;
    clock.init(std.testing.allocator);
    defer clock.deinit();
    var fake: Fake = .{ .answers = &.{ .pending, .pending, .pending } };
    try std.testing.expectError(
        error.DeviceCodeExpired,
        expectPolled(&fake, &clock, 2 * std.time.ms_per_min, std.time.ms_per_hour),
    );
    try std.testing.expectEqual(@as(usize, 3), fake.polled);
    const minute = std.time.ms_per_min;
    try std.testing.expectEqualSlices(u64, &.{ 2 * minute, 2 * minute, minute }, clock.slept());
}

test "a zero interval takes the floor" {
    var clock: core.testing.ClockIo = undefined;
    clock.init(std.testing.allocator);
    defer clock.deinit();
    var fake: Fake = .{ .answers = &.{ .pending, .pending } };
    try std.testing.expectError(error.DeviceCodeExpired, expectPolled(&fake, &clock, 0, 2_000));
    try std.testing.expectEqual(@as(usize, 2), fake.polled);
    try std.testing.expectEqualSlices(u64, &.{ 1_000, 1_000 }, clock.slept());
}

test "a device poll failure ends the wait and reaps the browser" {
    var clock: core.testing.ClockIo = undefined;
    clock.init(std.testing.allocator);
    defer clock.deinit();
    var fake: Fake = .{};
    try std.testing.expectError(
        error.TokenRequestFailed,
        expectPolled(&fake, &clock, 5_000, 60_000),
    );
    try std.testing.expect(fake.browser_reaped);
    try std.testing.expect(!fake.browser_running);
}

test "a device login without a browser warns and keeps polling" {
    var clock: core.testing.ClockIo = undefined;
    clock.init(std.testing.allocator);
    defer clock.deinit();
    var fake: Fake = .{ .launch_result = .unavailable, .answers = &.{.{ .granted = {} }} };
    try expectPolled(&fake, &clock, 5_000, 60_000);
    try std.testing.expectEqual(@as(usize, 1), fake.warning_count);
    try std.testing.expect(!fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 1), fake.polled);
}
