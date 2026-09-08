//! The interactive login choreography of both browser flows. In the callback
//! flow the listener is ready before the best-effort browser launch, whose
//! lifetime never blocks the callback. In the device-code flow (RFC 8628) the
//! prompt shows the user code, the browser opens the verification page, and a
//! bounded poll waits for the grant.

const std = @import("std");

/// RFC 8628 section 3.5: a `slow_down` answer adds five seconds to the interval.
const slow_down_increment_ms = 5_000;
/// The floor under a poll interval, so a grant that names a zero interval still
/// spends the window and the loop ends.
const interval_ms_min = 1_000;
/// The ceiling on a grant lifetime. The callback flow waits this long too, and
/// the wait blocks the interface, so no server can hold it open for longer.
const lifetime_ms_max = 5 * std.time.ms_per_min;

/// The answer of one poll of a device-code grant.
pub fn Poll(comptime Result: type) type {
    return union(enum) {
        /// The user has not authorized yet.
        pending,
        /// The server asks for a longer interval.
        slow_down,
        granted: Result,
    };
}

pub const Clock = struct {
    io: std.Io,

    pub fn sleep(self: Clock, milliseconds: u64) std.Io.Cancelable!void {
        const bounded: i64 = @intCast(@min(milliseconds, std.math.maxInt(i64)));
        return self.io.sleep(.fromMilliseconds(bounded), .awake);
    }
};

pub const Browser = struct {
    io: std.Io,

    pub fn launch(self: Browser, url: []const u8) error{Canceled}!?Process {
        for ([_][]const u8{ "xdg-open", "open" }) |launcher| {
            const child = std.process.spawn(
                self.io,
                .{ .argv = &.{ launcher, url } },
            ) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            return .{ .io = self.io, .child = child };
        }
        return null;
    }
};

pub fn receive(comptime Result: type, options: anytype) !Result {
    var listener = try options.callback.listen();
    defer listener.deinit();

    try options.prompt.showAuthorization(options.url);

    var maybe_browser = try options.browser.launch(options.url);
    defer if (maybe_browser) |*browser| browser.deinit();
    if (maybe_browser == null) try options.prompt.showBrowserLaunchFailed();

    return listener.receive();
}

/// Wait for a device-code grant. The prompt shows the verification URL and the
/// user code, the browser opens that URL, and `options.poller.poll()` asks the
/// token endpoint once per interval until the grant arrives or its lifetime of
/// `options.lifetime_ms` ends, capped at `lifetime_ms_max`. An ended lifetime is
/// `error.DeviceCodeExpired`.
pub fn poll(comptime Result: type, options: anytype) !Result {
    try options.prompt.showDeviceCode(options.url, options.code);

    var maybe_browser = try options.browser.launch(options.url);
    defer if (maybe_browser) |*browser| browser.deinit();
    if (maybe_browser == null) try options.prompt.showBrowserLaunchFailed();

    var interval_ms: u64 = @max(options.interval_ms, interval_ms_min);
    var remaining_ms: u64 = @min(options.lifetime_ms, lifetime_ms_max);
    // Every pass spends at least the floor of the window, so the loop ends
    // inside the lifetime of the grant.
    while (remaining_ms > 0) {
        const wait_ms = @min(interval_ms, remaining_ms);
        try options.clock.sleep(wait_ms);
        remaining_ms -= wait_ms;
        switch (try options.poller.poll()) {
            .pending => {},
            .slow_down => interval_ms += slow_down_increment_ms,
            .granted => |result| return result,
        }
    }
    return error.DeviceCodeExpired;
}

const Process = struct {
    io: std.Io,
    child: std.process.Child,

    fn deinit(self: *Process) void {
        self.child.kill(self.io);
    }
};

const Fake = struct {
    listener_ready: bool = false,
    listener_fails: bool = false,
    listener_deinit_count: usize = 0,
    callback_received: bool = false,
    callback_fails: bool = false,
    callback_while_browser_running: bool = false,
    authorization_count: usize = 0,
    authorization_fails: bool = false,
    warning_count: usize = 0,
    warning_fails: bool = false,
    browser_launched: bool = false,
    browser_running: bool = false,
    browser_reaped: bool = false,
    launch_result: enum { success, unavailable, canceled } = .success,
    immediate_redirect: bool = false,
    redirect_delivered: bool = false,

    const Prompt = struct {
        fake: *Fake,

        fn showAuthorization(self: @This(), url: []const u8) !void {
            _ = url;
            self.fake.authorization_count += 1;
            if (self.fake.authorization_fails) return error.AuthorizationOutputFailed;
        }

        fn showBrowserLaunchFailed(self: @This()) !void {
            self.fake.warning_count += 1;
            if (self.fake.warning_fails) return error.WarningOutputFailed;
        }
    };

    const Browser = struct {
        fake: *Fake,

        fn launch(self: @This(), url: []const u8) !?Fake.Process {
            _ = url;
            self.fake.browser_launched = true;
            return switch (self.fake.launch_result) {
                .success => success: {
                    self.fake.browser_running = true;
                    if (self.fake.immediate_redirect and self.fake.listener_ready)
                        self.fake.redirect_delivered = true;
                    break :success .{ .fake = self.fake };
                },
                .unavailable => null,
                .canceled => error.Canceled,
            };
        }
    };

    const Process = struct {
        fake: *Fake,

        fn deinit(self: *@This()) void {
            self.fake.browser_running = false;
            self.fake.browser_reaped = true;
        }
    };

    const Callback = struct {
        fake: *Fake,

        fn listen(self: @This()) !Fake.Listener {
            if (self.fake.listener_fails) return error.ListenerSetupFailed;
            self.fake.listener_ready = true;
            return .{ .fake = self.fake };
        }
    };

    const Listener = struct {
        fake: *Fake,

        fn deinit(self: *@This()) void {
            self.fake.listener_ready = false;
            self.fake.listener_deinit_count += 1;
        }

        fn receive(self: *@This()) !void {
            self.fake.callback_received = true;
            self.fake.callback_while_browser_running = self.fake.browser_running;
            if (self.fake.immediate_redirect and !self.fake.redirect_delivered)
                return error.RedirectMissed;
            if (self.fake.callback_fails) return error.CallbackFailed;
        }
    };
};

test "callback progress does not wait for browser lifetime and reaps helper" {
    var fake: Fake = .{};
    try receive(void, &.{
        .url = "https://example.test/authorize",
        .prompt = Fake.Prompt{ .fake = &fake },
        .browser = Fake.Browser{ .fake = &fake },
        .callback = Fake.Callback{ .fake = &fake },
    });
    try std.testing.expect(fake.callback_while_browser_running);
    try std.testing.expect(fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 1), fake.listener_deinit_count);
}

test "listener setup failure does not show or launch browser" {
    var fake: Fake = .{ .listener_fails = true };
    try std.testing.expectError(error.ListenerSetupFailed, receive(void, &.{
        .url = "https://example.test/authorize",
        .prompt = Fake.Prompt{ .fake = &fake },
        .browser = Fake.Browser{ .fake = &fake },
        .callback = Fake.Callback{ .fake = &fake },
    }));
    try std.testing.expectEqual(@as(usize, 0), fake.authorization_count);
    try std.testing.expect(!fake.browser_launched);
}

test "listener is ready before browser can deliver redirect" {
    var fake: Fake = .{ .immediate_redirect = true };
    try receive(void, &.{
        .url = "https://example.test/authorize",
        .prompt = Fake.Prompt{ .fake = &fake },
        .browser = Fake.Browser{ .fake = &fake },
        .callback = Fake.Callback{ .fake = &fake },
    });
    try std.testing.expect(fake.redirect_delivered);
    try std.testing.expect(fake.browser_reaped);
}

test "browser launch fallback warns and continues listening" {
    var fake: Fake = .{ .launch_result = .unavailable };
    try receive(void, &.{
        .url = "https://example.test/authorize",
        .prompt = Fake.Prompt{ .fake = &fake },
        .browser = Fake.Browser{ .fake = &fake },
        .callback = Fake.Callback{ .fake = &fake },
    });
    try std.testing.expect(fake.callback_received);
    try std.testing.expectEqual(@as(usize, 1), fake.warning_count);
    try std.testing.expectEqual(@as(usize, 1), fake.listener_deinit_count);
}

test "callback error reaps browser and closes listener" {
    var fake: Fake = .{ .callback_fails = true };
    try std.testing.expectError(error.CallbackFailed, receive(void, &.{
        .url = "https://example.test/authorize",
        .prompt = Fake.Prompt{ .fake = &fake },
        .browser = Fake.Browser{ .fake = &fake },
        .callback = Fake.Callback{ .fake = &fake },
    }));
    try std.testing.expect(fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 1), fake.listener_deinit_count);
}

test "authorization output error closes listener without launching browser" {
    var fake: Fake = .{ .authorization_fails = true };
    try std.testing.expectError(error.AuthorizationOutputFailed, receive(void, &.{
        .url = "https://example.test/authorize",
        .prompt = Fake.Prompt{ .fake = &fake },
        .browser = Fake.Browser{ .fake = &fake },
        .callback = Fake.Callback{ .fake = &fake },
    }));
    try std.testing.expect(!fake.browser_launched);
    try std.testing.expectEqual(@as(usize, 1), fake.listener_deinit_count);
}

test "browser launch cancellation closes listener without warning" {
    var fake: Fake = .{ .launch_result = .canceled };
    try std.testing.expectError(error.Canceled, receive(void, &.{
        .url = "https://example.test/authorize",
        .prompt = Fake.Prompt{ .fake = &fake },
        .browser = Fake.Browser{ .fake = &fake },
        .callback = Fake.Callback{ .fake = &fake },
    }));
    try std.testing.expectEqual(@as(usize, 0), fake.warning_count);
    try std.testing.expectEqual(@as(usize, 1), fake.listener_deinit_count);
}

test "manual fallback warning error closes listener" {
    var fake: Fake = .{ .launch_result = .unavailable, .warning_fails = true };
    try std.testing.expectError(error.WarningOutputFailed, receive(void, &.{
        .url = "https://example.test/authorize",
        .prompt = Fake.Prompt{ .fake = &fake },
        .browser = Fake.Browser{ .fake = &fake },
        .callback = Fake.Callback{ .fake = &fake },
    }));
    try std.testing.expect(!fake.callback_received);
    try std.testing.expectEqual(@as(usize, 1), fake.listener_deinit_count);
}

/// The doubles of the device-code flow. The poller answers from a script, and
/// the clock records every wait in place of a sleep.
const DeviceFake = struct {
    answers: []const Poll(void) = &.{},
    polled: usize = 0,
    waits: [16]u64 = undefined,
    wait_count: usize = 0,
    code_shown: bool = false,
    url_shown: []const u8 = "",
    browser_running: bool = false,
    browser_reaped: bool = false,
    launch_unavailable: bool = false,
    warning_count: usize = 0,

    const Prompt = struct {
        fake: *DeviceFake,

        fn showDeviceCode(self: @This(), url: []const u8, code: []const u8) !void {
            self.fake.url_shown = url;
            self.fake.code_shown = std.mem.eql(u8, code, "ABCD-EFGH");
        }

        fn showBrowserLaunchFailed(self: @This()) !void {
            self.fake.warning_count += 1;
        }
    };

    const Browser = struct {
        fake: *DeviceFake,

        fn launch(self: @This(), url: []const u8) !?DeviceFake.Process {
            _ = url;
            if (self.fake.launch_unavailable) return null;
            self.fake.browser_running = true;
            return .{ .fake = self.fake };
        }
    };

    const Process = struct {
        fake: *DeviceFake,

        fn deinit(self: *@This()) void {
            self.fake.browser_running = false;
            self.fake.browser_reaped = true;
        }
    };

    const Clock = struct {
        fake: *DeviceFake,

        fn sleep(self: @This(), milliseconds: u64) !void {
            self.fake.waits[self.fake.wait_count] = milliseconds;
            self.fake.wait_count += 1;
        }
    };

    const Poller = struct {
        fake: *DeviceFake,

        fn poll(self: @This()) !Poll(void) {
            const index = self.fake.polled;
            self.fake.polled += 1;
            if (index >= self.fake.answers.len) return error.PollScriptExhausted;
            return self.fake.answers[index];
        }
    };

    fn options(self: *DeviceFake, interval_ms: u64, lifetime_ms: u64) struct {
        url: []const u8,
        code: []const u8,
        interval_ms: u64,
        lifetime_ms: u64,
        prompt: DeviceFake.Prompt,
        browser: DeviceFake.Browser,
        clock: DeviceFake.Clock,
        poller: DeviceFake.Poller,
    } {
        return .{
            .url = "https://example.test/activate?user_code=ABCD-EFGH",
            .code = "ABCD-EFGH",
            .interval_ms = interval_ms,
            .lifetime_ms = lifetime_ms,
            .prompt = .{ .fake = self },
            .browser = .{ .fake = self },
            .clock = .{ .fake = self },
            .poller = .{ .fake = self },
        };
    }
};

test "a device grant waits one interval between polls and returns the grant" {
    var fake: DeviceFake = .{ .answers = &.{ .pending, .pending, .{ .granted = {} } } };
    try poll(void, &fake.options(5_000, 60_000));
    try std.testing.expect(fake.code_shown);
    try std.testing.expectEqualStrings(
        "https://example.test/activate?user_code=ABCD-EFGH",
        fake.url_shown,
    );
    try std.testing.expectEqual(@as(usize, 3), fake.polled);
    try std.testing.expectEqual(@as(usize, 3), fake.wait_count);
    try std.testing.expectEqual(@as(u64, 5_000), fake.waits[0]);
    try std.testing.expectEqual(@as(u64, 5_000), fake.waits[2]);
    try std.testing.expect(fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 0), fake.warning_count);
}

// RFC 8628 section 3.5: a `slow_down` answer lengthens every later wait by
// five seconds.
test "a slow_down answer lengthens the poll interval" {
    var fake: DeviceFake = .{ .answers = &.{ .slow_down, .pending, .{ .granted = {} } } };
    try poll(void, &fake.options(5_000, 60_000));
    try std.testing.expectEqual(@as(u64, 5_000), fake.waits[0]);
    try std.testing.expectEqual(@as(u64, 10_000), fake.waits[1]);
    try std.testing.expectEqual(@as(u64, 10_000), fake.waits[2]);
}

// The window of the grant bounds the loop. The last wait takes what is left of
// the window, and a grant that never arrives ends as expired.
test "a device grant that never arrives expires with its window" {
    var fake: DeviceFake = .{ .answers = &.{ .pending, .pending, .pending } };
    try std.testing.expectError(error.DeviceCodeExpired, poll(void, &fake.options(5_000, 12_000)));
    try std.testing.expectEqual(@as(usize, 3), fake.polled);
    try std.testing.expectEqual(@as(u64, 5_000), fake.waits[0]);
    try std.testing.expectEqual(@as(u64, 5_000), fake.waits[1]);
    try std.testing.expectEqual(@as(u64, 2_000), fake.waits[2]);
    try std.testing.expect(fake.browser_reaped);
}

// A server cannot hold the wait open past the ceiling, whatever lifetime its
// grant names.
test "a long grant lifetime ends at the ceiling" {
    var fake: DeviceFake = .{ .answers = &.{ .pending, .pending, .pending } };
    try std.testing.expectError(
        error.DeviceCodeExpired,
        poll(void, &fake.options(2 * std.time.ms_per_min, std.time.ms_per_hour)),
    );
    try std.testing.expectEqual(@as(usize, 3), fake.polled);
    try std.testing.expectEqual(@as(u64, 2 * std.time.ms_per_min), fake.waits[0]);
    try std.testing.expectEqual(@as(u64, std.time.ms_per_min), fake.waits[2]);
}

// A grant that names no interval takes the floor, so the loop still spends the
// window and ends.
test "a zero interval takes the floor" {
    var fake: DeviceFake = .{ .answers = &.{ .pending, .pending } };
    try std.testing.expectError(error.DeviceCodeExpired, poll(void, &fake.options(0, 2_000)));
    try std.testing.expectEqual(@as(usize, 2), fake.polled);
    try std.testing.expectEqual(@as(u64, 1_000), fake.waits[0]);
}

test "a device poll failure ends the wait and reaps the browser" {
    var fake: DeviceFake = .{ .answers = &.{} };
    try std.testing.expectError(
        error.PollScriptExhausted,
        poll(void, &fake.options(5_000, 60_000)),
    );
    try std.testing.expect(fake.browser_reaped);
    try std.testing.expect(!fake.browser_running);
}

test "a device login without a browser warns and keeps polling" {
    var fake: DeviceFake = .{ .launch_unavailable = true, .answers = &.{.{ .granted = {} }} };
    try poll(void, &fake.options(5_000, 60_000));
    try std.testing.expectEqual(@as(usize, 1), fake.warning_count);
    try std.testing.expect(!fake.browser_reaped);
    try std.testing.expectEqual(@as(usize, 1), fake.polled);
}
