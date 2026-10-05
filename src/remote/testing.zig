const std = @import("std");

const core = @import("core");
const providers = @import("providers");

pub const Clock = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    mutex: std.Io.Mutex,
    now_ms: i64,
    deadlines: [sleeps_max]?i64,
    changes: std.atomic.Value(u32),

    const sleeps_max = 32;

    pub fn init(self: *Clock, gpa: std.mem.Allocator) void {
        self.threaded = .init(gpa, .{});
        self.vtable = self.threaded.io().vtable.*;
        self.vtable.now = now;
        self.vtable.sleep = sleep;
        self.mutex = .init;
        self.now_ms = 0;
        self.deadlines = @splat(null);
        self.changes = .init(0);
    }

    pub fn deinit(self: *Clock) void {
        self.threaded.deinit();
    }

    pub fn io(self: *Clock) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    pub fn advance(self: *Clock, milliseconds: u64) void {
        const backend = self.threaded.io();
        self.mutex.lockUncancelable(backend);
        self.now_ms +|= @intCast(milliseconds);
        self.mutex.unlock(backend);
        self.announce();
    }

    pub fn pass(self: *Clock, milliseconds: u64) error{Canceled}!void {
        try self.waitForSleep(milliseconds);
        self.advance(milliseconds);
    }

    pub fn waitForSleep(self: *Clock, milliseconds: u64) error{Canceled}!void {
        var seen = self.changes.load(.acquire);
        while (!self.holdsSleep(milliseconds)) : (seen = self.changes.load(.acquire)) {
            try self.threaded.io().futexWait(u32, &self.changes.raw, seen);
        }
    }

    fn holdsSleep(self: *Clock, milliseconds: u64) bool {
        const backend = self.threaded.io();
        self.mutex.lockUncancelable(backend);
        defer self.mutex.unlock(backend);
        for (self.deadlines) |maybe_deadline| {
            const deadline = maybe_deadline orelse continue;
            if (deadline - self.now_ms == milliseconds) return true;
        }
        return false;
    }

    fn announce(self: *Clock) void {
        _ = self.changes.fetchAdd(1, .release);
        self.threaded.io().futexWake(u32, &self.changes.raw, std.math.maxInt(u32));
    }

    fn of(userdata: ?*anyopaque) *Clock {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        return @fieldParentPtr("threaded", threaded);
    }

    fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        const self = of(userdata);
        const backend = self.threaded.io();
        self.mutex.lockUncancelable(backend);
        defer self.mutex.unlock(backend);
        return .{ .nanoseconds = @as(i96, self.now_ms) * std.time.ns_per_ms };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self = of(userdata);
        const backend = self.threaded.io();
        try backend.checkCancel();
        const slot = self.hold(&timeout) orelse return;
        defer self.release(slot);
        var seen = self.changes.load(.acquire);
        while (!self.reached(slot)) : (seen = self.changes.load(.acquire)) {
            try backend.futexWait(u32, &self.changes.raw, seen);
        }
    }

    fn hold(self: *Clock, timeout: *const std.Io.Timeout) ?usize {
        const backend = self.threaded.io();
        const slot = slot: {
            self.mutex.lockUncancelable(backend);
            defer self.mutex.unlock(backend);
            const deadline = switch (timeout.*) {
                .none => return null,
                .duration => |duration| self.now_ms +| @max(0, duration.raw.toMilliseconds()),
                .deadline => |deadline| deadline.raw.toMilliseconds(),
            };
            for (&self.deadlines, 0..) |*vacancy, index| {
                if (vacancy.* != null) continue;
                vacancy.* = deadline;
                break :slot index;
            }
            unreachable;
        };
        self.announce();
        return slot;
    }

    fn reached(self: *Clock, slot: usize) bool {
        const backend = self.threaded.io();
        self.mutex.lockUncancelable(backend);
        defer self.mutex.unlock(backend);
        return self.now_ms >= self.deadlines[slot].?;
    }

    fn release(self: *Clock, slot: usize) void {
        const backend = self.threaded.io();
        self.mutex.lockUncancelable(backend);
        defer self.mutex.unlock(backend);
        self.deadlines[slot] = null;
    }
};

pub const Reply = struct {
    status: u16 = 200,
    body: []const u8,
    delay_ms: u64 = 0,
};

pub const Script = struct {
    method: []const u8,
    replies: []const Reply,
};

const Request = struct {
    path: []u8,
    body: []u8,
};

pub const Telegram = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    scripts: []const Script,
    served: []usize,
    requests: std.ArrayList(Request),
    readers: std.ArrayList(*std.Io.Reader),
    mutex: std.Io.Mutex,
    changes: std.atomic.Value(u32),

    const vtable: providers.Transport.VTable = .{ .open = open, .close = close };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, scripts: []const Script) !Telegram {
        const served = try gpa.alloc(usize, scripts.len);
        @memset(served, 0);
        return .{
            .gpa = gpa,
            .io = io,
            .scripts = scripts,
            .served = served,
            .requests = .empty,
            .readers = .empty,
            .mutex = .init,
            .changes = .init(0),
        };
    }

    pub fn deinit(self: *Telegram) void {
        for (self.requests.items) |request| {
            self.gpa.free(request.path);
            self.gpa.free(request.body);
        }
        self.requests.deinit(self.gpa);
        for (self.readers.items) |reader| self.gpa.destroy(reader);
        self.readers.deinit(self.gpa);
        self.gpa.free(self.served);
    }

    pub fn transport(self: *Telegram) providers.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn finish(self: *Telegram) error{Canceled}!void {
        var seen = self.changes.load(.acquire);
        while (!self.consumed()) : (seen = self.changes.load(.acquire)) {
            try self.io.futexWait(u32, &self.changes.raw, seen);
        }
    }

    pub fn waitForLongPoll(self: *Telegram) error{Canceled}!void {
        _ = try self.waitForRequest("/getUpdates", 1);
    }

    pub fn sendCount(self: *Telegram) usize {
        return self.countOf("/sendMessage");
    }

    pub fn countOf(self: *Telegram, path_suffix: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (std.mem.endsWith(u8, request.path, path_suffix)) count += 1;
        }
        return count;
    }

    pub fn waitForRequest(
        self: *Telegram,
        path_suffix: []const u8,
        index: usize,
    ) error{Canceled}![]const u8 {
        var seen = self.changes.load(.acquire);
        while (self.countOf(path_suffix) <= index) : (seen = self.changes.load(.acquire)) {
            try self.io.futexWait(u32, &self.changes.raw, seen);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (!std.mem.endsWith(u8, request.path, path_suffix)) continue;
            if (count == index) return request.body;
            count += 1;
        }
        unreachable;
    }

    pub fn waitForSends(self: *Telegram, count: usize) error{Canceled}!void {
        var seen = self.changes.load(.acquire);
        while (self.sendCount() < count) : (seen = self.changes.load(.acquire)) {
            try self.io.futexWait(u32, &self.changes.raw, seen);
        }
    }

    pub fn waitForSent(self: *Telegram, needle: []const u8) error{Canceled}![]const u8 {
        var seen = self.changes.load(.acquire);
        while (true) : (seen = self.changes.load(.acquire)) {
            if (self.sentWith(needle)) |body| return body;
            try self.io.futexWait(u32, &self.changes.raw, seen);
        }
    }

    pub fn sentWith(self: *Telegram, needle: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.requests.items) |request| {
            if (!std.mem.endsWith(u8, request.path, "/sendMessage")) continue;
            if (std.mem.indexOf(u8, request.body, needle) != null) return request.body;
        }
        return null;
    }

    pub fn bodiesOf(self: *Telegram, method: []const u8, buffer: [][]const u8) [][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (!std.mem.eql(u8, methodOf(request.path), method)) continue;
            std.debug.assert(count < buffer.len);
            buffer[count] = request.body;
            count += 1;
        }
        return buffer[0..count];
    }

    fn consumed(self: *Telegram) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.scripts, self.served) |script, count| {
            if (count < script.replies.len) return false;
        }
        return true;
    }

    fn open(
        ptr: *anyopaque,
        request: *const providers.Transport.Request,
    ) providers.Transport.Error!providers.Transport.Reply {
        const self: *Telegram = @ptrCast(@alignCast(ptr));
        const reader, const reply = try self.record(request);
        _ = self.changes.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.changes.raw, std.math.maxInt(u32));
        const answer = reply orelse {
            var never: std.Io.Event = .unset;
            try never.wait(self.io);
            unreachable;
        };
        if (answer.delay_ms > 0) try core.timeout.sleep(self.io, answer.delay_ms);
        return .{ .status = @enumFromInt(answer.status), .headers = &.{}, .body = reader };
    }

    fn close(_: *anyopaque) void {}

    fn record(
        self: *Telegram,
        request: *const providers.Transport.Request,
    ) !struct { *std.Io.Reader, ?*const Reply } {
        const path = try self.gpa.dupe(u8, pathOf(request.url));
        errdefer self.gpa.free(path);
        const body = try self.gpa.dupe(u8, request.body);
        errdefer self.gpa.free(body);
        const reader = try self.gpa.create(std.Io.Reader);
        errdefer self.gpa.destroy(reader);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.requests.ensureUnusedCapacity(self.gpa, 1);
        try self.readers.ensureUnusedCapacity(self.gpa, 1);
        const reply = self.nextReply(methodOf(path));
        reader.* = .fixed(if (reply) |found| found.body else "");
        self.requests.appendAssumeCapacity(.{ .path = path, .body = body });
        self.readers.appendAssumeCapacity(reader);
        return .{ reader, reply };
    }

    fn nextReply(self: *Telegram, method: []const u8) ?*const Reply {
        for (self.scripts, self.served) |*script, *count| {
            if (!std.mem.eql(u8, script.method, method)) continue;
            if (count.* >= script.replies.len) return null;
            count.* += 1;
            return &script.replies[count.* - 1];
        }
        return null;
    }

    fn pathOf(url: []const u8) []const u8 {
        const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
        const host = url[scheme_end + 3 ..];
        return host[std.mem.indexOfScalar(u8, host, '/') orelse host.len ..];
    }

    fn methodOf(path: []const u8) []const u8 {
        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[last_slash + 1 ..];
    }
};

pub fn Collector(comptime Event: type) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        events: std.ArrayList(Event) = .empty,
        mutex: std.Io.Mutex = .init,
        arrivals: std.atomic.Value(u32) = .init(0),

        const Self = @This();

        const vtable: core.actor.Sink(Event).VTable = .{ .emit = collect };

        pub fn deinit(self: *Self) void {
            for (self.events.items) |event| event.deinit(self.gpa);
            self.events.deinit(self.gpa);
        }

        pub fn sink(self: *Self) core.actor.Sink(Event) {
            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn waitFor(self: *Self, count: usize) error{Canceled}!void {
            var seen = self.arrivals.load(.acquire);
            while (seen < count) : (seen = self.arrivals.load(.acquire)) {
                try self.io.futexWait(u32, &self.arrivals.raw, seen);
            }
        }

        fn collect(ptr: *anyopaque, event: *const Event) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const copy = event.dupe(self.gpa) catch return;
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.events.append(self.gpa, copy) catch return copy.deinit(self.gpa);
            }
            _ = self.arrivals.fetchAdd(1, .release);
            self.io.futexWake(u32, &self.arrivals.raw, std.math.maxInt(u32));
        }
    };
}

pub const ok_true = "{\"ok\":true,\"result\":true}";
pub const ok_empty = "{\"ok\":true,\"result\":[]}";
pub const ok_sent = "{\"ok\":true,\"result\":{\"message_id\":1}}";

pub const webhook_deleted: Script = .{
    .method = "deleteWebhook",
    .replies = &.{.{ .body = ok_true }},
};
pub const commands_set: Script = .{
    .method = "setMyCommands",
    .replies = &.{.{ .body = ok_true }},
};

pub const quiet_scripts = [_]Script{
    webhook_deleted,
    commands_set,
    .{ .method = "getUpdates", .replies = &.{.{ .body = ok_empty }} },
};

pub fn Rig(comptime Event: type) type {
    return struct {
        telegram: Telegram,
        collector: Collector(Event),

        const Self = @This();

        pub fn init(self: *Self, io: std.Io, scripts: []const Script) !void {
            const gpa = std.testing.allocator;
            self.telegram = try .init(gpa, io, scripts);
            self.collector = .{ .gpa = gpa, .io = io };
        }

        pub fn deinit(self: *Self) void {
            self.collector.deinit();
            self.telegram.deinit();
        }
    };
}
