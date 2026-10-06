const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");

const Herdr = @import("Herdr.zig");

pub const Clock = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    mutex: std.Io.Mutex,
    now_ms: i64,
    changes: std.atomic.Value(u32),
    sleep_count: usize,
    sleep_deadline_ms: i64,

    pub fn init(self: *Clock, gpa: std.mem.Allocator) void {
        self.threaded = .init(gpa, .{});
        self.vtable = self.threaded.io().vtable.*;
        self.vtable.now = now;
        self.vtable.sleep = sleep;
        self.mutex = .init;
        self.now_ms = 0;
        self.changes = .init(0);
        self.sleep_count = 0;
        self.sleep_deadline_ms = 0;
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
        self.notify();
    }

    pub fn sleepCount(self: *Clock) usize {
        const backend = self.threaded.io();
        self.mutex.lockUncancelable(backend);
        defer self.mutex.unlock(backend);
        return self.sleep_count;
    }

    pub fn waitSleep(
        self: *Clock,
        seen: usize,
    ) error{ Timeout, Canceled, ConcurrencyUnavailable }!i64 {
        return core.timeout.run(std.testing.io, 5_000, sleepAfter, .{ self, seen }, null);
    }

    fn sleepAfter(self: *Clock, seen: usize) std.Io.Cancelable!i64 {
        const backend = self.threaded.io();
        while (true) {
            const changed = self.changes.load(.acquire);
            self.mutex.lockUncancelable(backend);
            const started = self.sleep_count > seen;
            const deadline_ms = self.sleep_deadline_ms;
            self.mutex.unlock(backend);
            if (started) return deadline_ms;
            try std.testing.io.futexWait(u32, &self.changes.raw, changed);
        }
    }

    fn notify(self: *Clock) void {
        _ = self.changes.fetchAdd(1, .release);
        self.threaded.io().futexWake(u32, &self.changes.raw, std.math.maxInt(u32));
    }

    fn of(userdata: ?*anyopaque) *Clock {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        return @fieldParentPtr("threaded", threaded);
    }

    fn nowMs(self: *Clock) i64 {
        const backend = self.threaded.io();
        self.mutex.lockUncancelable(backend);
        defer self.mutex.unlock(backend);
        return self.now_ms;
    }

    fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        return .{ .nanoseconds = @as(i96, of(userdata).nowMs()) * std.time.ns_per_ms };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self = of(userdata);
        const backend = self.threaded.io();
        try backend.checkCancel();
        const deadline_ms = switch (timeout) {
            .none => return,
            .duration => |duration| self.nowMs() +| @max(0, duration.raw.toMilliseconds()),
            .deadline => |deadline| deadline.raw.toMilliseconds(),
        };
        self.mutex.lockUncancelable(backend);
        self.sleep_count += 1;
        self.sleep_deadline_ms = deadline_ms;
        self.mutex.unlock(backend);
        self.notify();
        var seen = self.changes.load(.acquire);
        while (self.nowMs() < deadline_ms) : (seen = self.changes.load(.acquire)) {
            try backend.futexWait(u32, &self.changes.raw, seen);
        }
    }
};

pub fn expectContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) != null) return;
    std.debug.print("the text holds no \"{s}\":\n{s}\n", .{ needle, text });
    return error.TestExpectedNeedle;
}

pub const Tree = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    paths: std.ArrayList([]u8),

    pub fn init() !Tree {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .tmp = tmp, .root = root, .paths = .empty };
    }

    pub fn deinit(self: *Tree) void {
        for (self.paths.items) |path_item| std.testing.allocator.free(path_item);
        self.paths.deinit(std.testing.allocator);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    pub fn path(self: *Tree, sub_path: []const u8) ![]const u8 {
        const gpa = std.testing.allocator;
        const joined = try std.fs.path.join(gpa, &.{ self.root, sub_path });
        errdefer gpa.free(joined);
        try self.paths.append(gpa, joined);
        return joined;
    }

    pub fn directory(self: *Tree, sub_path: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, sub_path);
    }

    pub fn write(self: *Tree, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent| try self.directory(parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    pub fn skill(
        self: *Tree,
        parent: []const u8,
        options: *const struct { name: []const u8, description: []const u8 },
    ) !void {
        var path_buffer: [256]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/SKILL.md", .{parent});
        var source_buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(
            &source_buffer,
            "---\nname: {s}\ndescription: {s}\n---\nFollow this skill.\n",
            .{ options.name, options.description },
        );
        try self.write(sub_path, source);
    }

    pub fn link(
        self: *Tree,
        target: []const u8,
        sub_path: []const u8,
        flags: std.Io.Dir.SymLinkFlags,
    ) !void {
        self.tmp.dir.symLink(std.testing.io, target, sub_path, flags) catch |err| switch (err) {
            error.AccessDenied,
            error.PermissionDenied,
            error.ReadOnlyFileSystem,
            => return error.SkipZigTest,
            else => return err,
        };
    }
};

const take_ms_max = 5_000;

pub const FakeHerdr = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    path_buffer: [128]u8,
    path_length: usize,
    server: std.Io.net.Server,
    lines_buffer: [8][]u8,
    lines: std.Io.Queue([]u8),

    pub fn init(self: *FakeHerdr, gpa: std.mem.Allocator, io: std.Io) !void {
        self.gpa = gpa;
        self.io = io;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var home_buffer: [128]u8 = undefined;
        const home = try accounts.testing.tmpHome(&home_buffer, &self.tmp);
        const socket_path = try std.fmt.bufPrint(&self.path_buffer, "{s}/herdr.sock", .{home});
        self.path_length = socket_path.len;
        const address = try std.Io.net.UnixAddress.init(socket_path);
        self.server = try address.listen(io, .{});
        self.lines = .init(&self.lines_buffer);
    }

    pub fn deinit(self: *FakeHerdr) void {
        var taken: [8][]u8 = undefined;
        const count = self.lines.get(self.io, &taken, 0) catch 0;
        for (taken[0..count]) |line| self.gpa.free(line);
        self.server.deinit(self.io);
        self.tmp.cleanup();
    }

    pub fn endpoint(self: *const FakeHerdr) Herdr.Endpoint {
        return .{ .socket_path = self.path_buffer[0..self.path_length], .pane_id = "w1:p1" };
    }

    pub fn serve(self: *FakeHerdr, count: usize) !void {
        for (0..count) |_| {
            const stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            var read_buffer: [Herdr.line_bytes_max]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            const line = try reader.interface.takeDelimiterInclusive('\n');
            const owned = try self.gpa.dupe(u8, line[0 .. line.len - 1]);
            errdefer self.gpa.free(owned);
            var write_buffer: [64]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);
            try writer.interface.writeAll("{\"id\":\"drinky\",\"result\":{\"type\":\"ok\"}}\n");
            try writer.interface.flush();
            try self.lines.putOne(self.io, owned);
        }
    }

    pub fn take(self: *FakeHerdr) ![]u8 {
        return core.timeout.run(self.io, take_ms_max, takeLine, .{self}, releaseLine);
    }

    fn takeLine(self: *FakeHerdr) (std.Io.QueueClosedError || std.Io.Cancelable)![]u8 {
        var taken: [1][]u8 = undefined;
        const count = try self.lines.get(self.io, &taken, 1);
        std.debug.assert(count == 1);
        return taken[0];
    }

    fn releaseLine(line: *const []u8, args: *const struct { *FakeHerdr }) void {
        args[0].gpa.free(line.*);
    }

    pub fn drained(self: *FakeHerdr) !bool {
        var taken: [1][]u8 = undefined;
        return try self.lines.get(self.io, &taken, 0) == 0;
    }
};
