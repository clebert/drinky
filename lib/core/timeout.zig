const std = @import("std");

const testing = @import("testing.zig");

pub const Deadline = struct {
    at: ?std.Io.Timestamp,

    pub const unbounded: Deadline = .{ .at = null };

    pub fn start(io: std.Io, timeout_ms: u64) Deadline {
        if (timeout_ms == 0) return unbounded;
        return .{ .at = std.Io.Clock.awake.now(io).addDuration(duration(timeout_ms)) };
    }

    pub fn expired(self: *const Deadline, io: std.Io) bool {
        const at = self.at orelse return false;
        return std.Io.Clock.awake.now(io).durationTo(at).nanoseconds <= 0;
    }

    pub fn run(
        self: *const Deadline,
        io: std.Io,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
        comptime release: ?Release(@TypeOf(function)),
    ) Timed(@TypeOf(function)) {
        const at = self.at orelse return race(io, 0, function, args, release);
        const remaining_ns = std.Io.Clock.awake.now(io).durationTo(at).nanoseconds;
        if (remaining_ns <= 0) return error.Timeout;
        const remaining_ms: u64 = @intCast(@divFloor(remaining_ns, std.time.ns_per_ms) + 1);
        return race(io, remaining_ms, function, args, release);
    }
};

const Finish = struct {
    io: std.Io,
    event: std.Io.Event = .unset,
    first: std.atomic.Value(Racer) = .init(.none),

    const Racer = enum(u8) { none, work, timer };

    fn end(self: *Finish, racer: Racer) void {
        _ = self.first.cmpxchgStrong(.none, racer, .release, .monotonic);
        self.event.set(self.io);
    }

    fn expire(self: *Finish, timeout_ms: u64) void {
        sleep(self.io, timeout_ms) catch return;
        self.end(.timer);
    }
};

fn Return(comptime Function: type) type {
    return @typeInfo(Function).@"fn".return_type.?;
}

fn Payload(comptime Function: type) type {
    return switch (@typeInfo(Return(Function))) {
        .error_union => |error_union| error_union.payload,
        else => Return(Function),
    };
}

fn Failure(comptime Function: type) type {
    return switch (@typeInfo(Return(Function))) {
        .error_union => |error_union| error_union.error_set,
        else => error{},
    };
}

fn Timed(comptime Function: type) type {
    const Bound = error{ Timeout, Canceled, ConcurrencyUnavailable };
    return (Failure(Function) || Bound)!Payload(Function);
}

fn Release(comptime Function: type) type {
    return fn (payload: *const Payload(Function), args: *const std.meta.ArgsTuple(Function)) void;
}

pub fn run(
    io: std.Io,
    timeout_ms: u64,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    comptime release: ?Release(@TypeOf(function)),
) Timed(@TypeOf(function)) {
    return race(io, timeout_ms, function, args, release);
}

fn race(
    io: std.Io,
    timeout_ms: u64,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    comptime release: ?Release(@TypeOf(function)),
) Timed(@TypeOf(function)) {
    const Function = @TypeOf(function);
    const Work = struct {
        fn call(finish: *Finish, work_args: std.meta.ArgsTuple(Function)) Return(Function) {
            defer finish.end(.work);
            return @call(.auto, function, work_args);
        }
    };

    var finish: Finish = .{ .io = io };
    var timer: ?std.Io.Future(void) = null;
    if (timeout_ms != 0) timer = try io.concurrent(Finish.expire, .{ &finish, timeout_ms });
    defer if (timer) |*future| future.cancel(io);
    var work = try io.concurrent(Work.call, .{ &finish, args });
    finish.event.wait(io) catch |err| {
        drop(Function, work.cancel(io), &args, release);
        return err;
    };
    if (finish.first.load(.acquire) == .timer) {
        drop(Function, work.cancel(io), &args, release);
        return error.Timeout;
    }
    return work.await(io);
}

fn drop(
    comptime Function: type,
    result: Return(Function),
    args: *const std.meta.ArgsTuple(Function),
    comptime release: ?Release(Function),
) void {
    if (release) |free| {
        const payload: Payload(Function) = if (@typeInfo(Return(Function)) == .error_union)
            result catch return
        else
            result;
        free(&payload, args);
    }
}

pub fn sleep(io: std.Io, milliseconds: u64) std.Io.Cancelable!void {
    return io.sleep(duration(milliseconds), .awake);
}

fn duration(milliseconds: u64) std.Io.Duration {
    return .fromMilliseconds(@intCast(@min(milliseconds, std.math.maxInt(i64))));
}

test "run returns the result when the operation wins" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(u64, 42), try run(io, 5_000, fastWork, .{}, null));
    try std.testing.expectEqual(@as(u64, 42), try run(io, 0, fastWork, .{}, null));
}

fn fastWork() u64 {
    return 42;
}

fn slowWork(io: std.Io, canceled: *bool) std.Io.Cancelable!u64 {
    var never: std.Io.Event = .unset;
    never.wait(io) catch |err| {
        canceled.* = true;
        return err;
    };
    unreachable;
}

fn timedSlowWork(
    io: std.Io,
    canceled: *bool,
) error{ Canceled, Timeout, ConcurrencyUnavailable }!u64 {
    return run(io, 60_000, slowWork, .{ io, canceled }, null);
}

fn hidingWork(io: std.Io, canceled: *bool) error{ReadFailed}!u64 {
    var never: std.Io.Event = .unset;
    never.wait(io) catch {
        canceled.* = true;
        return error.ReadFailed;
    };
    unreachable;
}

fn unboundedHidingWork(
    io: std.Io,
    canceled: *bool,
) error{ ReadFailed, Canceled, Timeout, ConcurrencyUnavailable }!u64 {
    return run(io, 0, hidingWork, .{ io, canceled }, null);
}

fn flagWork(ran: *bool) u64 {
    ran.* = true;
    return 42;
}

test "run times out and reaps a stalled operation" {
    var clock: testing.ClockIo = undefined;
    clock.init(std.testing.allocator);
    defer clock.deinit();
    const io = clock.io();
    var canceled = false;
    try std.testing.expectError(error.Timeout, run(io, 20, slowWork, .{ io, &canceled }, null));
    try std.testing.expect(canceled);
    try std.testing.expectEqualSlices(u64, &.{20}, clock.slept());
}

test "run propagates a caller cancel as Canceled, not Timeout" {
    const io = std.testing.io;
    var canceled = false;
    var future = try io.concurrent(timedSlowWork, .{ io, &canceled });
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(canceled);
}

test "a zero window runs the work as a task, so a cancel that the work hides ends the caller" {
    var canceled = false;
    var future = try std.testing.io.concurrent(unboundedHidingWork, .{ std.testing.io, &canceled });
    try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
    try std.testing.expect(canceled);
}

test "run reports a task that cannot start and never runs the work in its place" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var ran = false;
    const bounded = run(io, 5_000, flagWork, .{&ran}, null);
    try std.testing.expectError(error.ConcurrencyUnavailable, bounded);
    try std.testing.expectError(error.ConcurrencyUnavailable, run(io, 0, flagWork, .{&ran}, null));
    try std.testing.expect(!ran);
}

fn stubbornWork(io: std.Io, gpa: std.mem.Allocator, _: *bool) error{OutOfMemory}![]u8 {
    var never: std.Io.Event = .unset;
    never.wait(io) catch {};
    return gpa.dupe(u8, "late");
}

fn releaseStubborn(
    payload: *const []u8,
    args: *const std.meta.ArgsTuple(@TypeOf(stubbornWork)),
) void {
    args[1].free(payload.*);
    args[2].* = true;
}

fn timedStubbornWork(
    io: std.Io,
    gpa: std.mem.Allocator,
    released: *bool,
) error{ OutOfMemory, Canceled, Timeout, ConcurrencyUnavailable }![]u8 {
    return run(io, 0, stubbornWork, .{ io, gpa, released }, releaseStubborn);
}

test "a payload that arrives after a cancel goes to the release of the caller" {
    const io = std.testing.io;
    var released = false;
    var future = try io.concurrent(timedStubbornWork, .{ io, std.testing.allocator, &released });
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(released);
}

test "a deadline with a zero timeout never expires and starts no timer" {
    var clock: HeldClock = undefined;
    clock.init(std.testing.allocator);
    defer clock.threaded.deinit();
    const io = clock.io();
    const deadline: Deadline = .start(io, 0);
    clock.advance(std.time.ms_per_day);
    try std.testing.expect(!deadline.expired(io));
    try std.testing.expectEqual(@as(u64, 42), try deadline.run(io, fastWork, .{}, null));
    try std.testing.expectEqual(@as(usize, 0), clock.slept().len);
}

const HeldClock = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    now_ns: i96,
    sleeps: [sleeps_max]u64,
    sleep_count: usize,

    const sleeps_max = 4;

    fn init(self: *HeldClock, gpa: std.mem.Allocator) void {
        self.threaded = .init(gpa, .{});
        self.vtable = self.threaded.io().vtable.*;
        self.vtable.now = now;
        self.vtable.sleep = hold;
        self.now_ns = 0;
        self.sleep_count = 0;
    }

    fn io(self: *HeldClock) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    fn advance(self: *HeldClock, milliseconds: u64) void {
        self.now_ns += milliseconds * std.time.ns_per_ms;
    }

    fn slept(self: *const HeldClock) []const u64 {
        return self.sleeps[0..self.sleep_count];
    }

    fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *HeldClock = @alignCast(@fieldParentPtr("threaded", threaded));
        return .{ .nanoseconds = self.now_ns };
    }

    fn hold(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *HeldClock = @alignCast(@fieldParentPtr("threaded", threaded));
        const milliseconds = switch (timeout) {
            .duration => |window| window.raw.toMilliseconds(),
            .none, .deadline => unreachable,
        };
        self.sleeps[self.sleep_count] = @intCast(milliseconds);
        self.sleep_count += 1;
        var never: std.Io.Event = .unset;
        return never.wait(threaded.io());
    }
};

test "a deadline draws one window down across its calls and refuses a call once expired" {
    var clock: HeldClock = undefined;
    clock.init(std.testing.allocator);
    defer clock.threaded.deinit();
    const io = clock.io();
    const deadline: Deadline = .start(io, 1_000);
    clock.advance(400);
    try std.testing.expectEqual(@as(u64, 42), try deadline.run(io, fastWork, .{}, null));
    clock.advance(500);
    try std.testing.expect(!deadline.expired(io));
    try std.testing.expectEqual(@as(u64, 42), try deadline.run(io, fastWork, .{}, null));
    try std.testing.expectEqualSlices(u64, &.{ 601, 101 }, clock.slept());
    clock.advance(100);
    try std.testing.expect(deadline.expired(io));
    var ran = false;
    try std.testing.expectError(error.Timeout, deadline.run(io, flagWork, .{&ran}, null));
    try std.testing.expect(!ran);
    try std.testing.expectEqual(@as(usize, 2), clock.slept().len);
}

threadlocal var gated_caller = false;

const Gated = struct {
    threaded: std.Io.Threaded,
    backend: *const std.Io.VTable,
    vtable: std.Io.VTable,
    passed: bool,
    reached: std.Io.Event,

    const spins_max = 1 << 24;

    fn init(self: *Gated, gpa: std.mem.Allocator) void {
        self.threaded = .init(gpa, .{});
        self.backend = self.threaded.io().vtable;
        self.vtable = self.backend.*;
        self.vtable.futexWait = futexWait;
        self.passed = false;
        self.reached = .unset;
    }

    fn io(self: *Gated) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    fn futexWait(
        userdata: ?*anyopaque,
        ptr: *const u32,
        expected: u32,
        timeout: std.Io.Timeout,
    ) std.Io.Cancelable!void {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *Gated = @fieldParentPtr("threaded", threaded);
        if (gated_caller and !self.passed) {
            self.passed = true;
            const backend: std.Io = .{ .userdata = userdata, .vtable = self.backend };
            self.reached.set(backend);
            for (0..spins_max) |_| {
                backend.checkCancel() catch {
                    backend.recancel();
                    break;
                };
                std.Thread.yield() catch {};
            }
            for (0..spins_max) |_| {
                if (@atomicLoad(u32, ptr, .acquire) != expected) break;
                std.Thread.yield() catch {};
            }
        }
        return self.backend.futexWait(userdata, ptr, expected, timeout);
    }
};

fn releasedWork(io: std.Io, release: *std.Io.Event) std.Io.Cancelable!u64 {
    try release.wait(io);
    return 42;
}

fn gatedCaller(
    io: std.Io,
    release: *std.Io.Event,
) error{ Canceled, Timeout, ConcurrencyUnavailable }!u64 {
    gated_caller = true;
    defer gated_caller = false;
    const value = try run(io, 0, releasedWork, .{ io, release }, null);
    try io.checkCancel();
    return value;
}

test "a cancel that meets the result of the work still ends the caller as Canceled" {
    var gated: Gated = undefined;
    gated.init(std.testing.allocator);
    defer gated.threaded.deinit();
    const io = gated.io();
    var release: std.Io.Event = .unset;
    var caller = try io.concurrent(gatedCaller, .{ io, &release });
    try gated.reached.wait(io);
    release.set(io);
    try std.testing.expectError(error.Canceled, caller.cancel(io));
}
