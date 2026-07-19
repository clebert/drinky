//! The interactive login choreography: listener ready before the best-effort
//! browser launch, whose lifetime never blocks the callback.

const std = @import("std");

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
