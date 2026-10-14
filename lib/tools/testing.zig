const std = @import("std");

const core = @import("core");

const SkillGuard = @import("SkillGuard.zig");

const Measured = struct { core.Tool.Measure, u64 };

pub const CancelIo = struct {
    vtable: std.Io.VTable,

    pub fn init(target: enum { file_open, file_write }) CancelIo {
        var vtable = std.testing.io.vtable.*;
        switch (target) {
            .file_open => vtable.dirOpenFile = openFile,
            .file_write => vtable.operate = operate,
        }
        return .{ .vtable = vtable };
    }

    pub fn io(self: *const CancelIo) std.Io {
        return .{ .userdata = std.testing.io.userdata, .vtable = &self.vtable };
    }

    fn openFile(
        _: ?*anyopaque,
        _: std.Io.Dir,
        _: []const u8,
        _: std.Io.Dir.OpenFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        return error.Canceled;
    }

    fn operate(
        userdata: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        if (operation == .file_write_streaming) return error.Canceled;
        return std.testing.io.vtable.operate(userdata, operation);
    }
};

pub const StallIo = struct {
    threaded: std.Io.Threaded,
    backend: *const std.Io.VTable,
    vtable: std.Io.VTable,
    target: Target,
    stalled: std.Io.Event,
    canceled: std.atomic.Value(bool),
    sleeps: [sleeps_max]u64,
    sleep_count: std.atomic.Value(usize),
    now_ns: std.atomic.Value(i64),

    const sleeps_max = 4;

    pub const Target = union(enum) {
        open_directory: []const u8,
        open_file: []const u8,
        write,
        directory_end,
        rename_after_cancel,
    };

    pub fn init(self: *StallIo, gpa: std.mem.Allocator, target: Target) void {
        self.threaded = .init(gpa, .{});
        self.backend = self.threaded.io().vtable;
        self.vtable = self.backend.*;
        self.vtable.sleep = sleep;
        self.vtable.now = now;
        switch (target) {
            .open_directory => self.vtable.dirOpenDir = openDir,
            .open_file => self.vtable.dirOpenFile = openFile,
            .write => self.vtable.operate = operate,
            .directory_end => self.vtable.dirRead = readDirectory,
            .rename_after_cancel => self.vtable.dirRename = renameAfterCancel,
        }
        self.target = target;
        self.stalled = .unset;
        self.canceled = .init(false);
        self.sleep_count = .init(0);
        self.now_ns = .init(0);
    }

    pub fn deinit(self: *StallIo) void {
        self.threaded.deinit();
    }

    pub fn io(self: *StallIo) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    pub fn slept(self: *const StallIo) []const u64 {
        return self.sleeps[0..@min(self.sleep_count.load(.acquire), sleeps_max)];
    }

    fn of(userdata: ?*anyopaque) *StallIo {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        return @fieldParentPtr("threaded", threaded);
    }

    fn backendIo(self: *StallIo) std.Io {
        return .{ .userdata = &self.threaded, .vtable = self.backend };
    }

    fn stall(self: *StallIo) std.Io.Cancelable!void {
        self.stalled.set(self.backendIo());
        var never: std.Io.Event = .unset;
        never.wait(self.backendIo()) catch |err| {
            self.canceled.store(true, .release);
            return err;
        };
        unreachable;
    }

    fn names(path: []const u8, name: []const u8) bool {
        return std.mem.eql(u8, std.Io.Dir.path.basename(path), name);
    }

    fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        const self = of(userdata);
        return .{ .nanoseconds = self.now_ns.load(.acquire) };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self = of(userdata);
        const milliseconds: u64 = switch (timeout) {
            .duration => |duration| @intCast(duration.raw.toMilliseconds()),
            .none, .deadline => 0,
        };
        const index = self.sleep_count.fetchAdd(1, .acq_rel);
        if (index < sleeps_max) self.sleeps[index] = milliseconds;
        try self.stalled.wait(self.backendIo());
        _ = self.now_ns.fetchAdd(@intCast(milliseconds * std.time.ns_per_ms), .acq_rel);
    }

    fn openDir(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.OpenOptions,
    ) std.Io.Dir.OpenError!std.Io.Dir {
        const self = of(userdata);
        if (names(path, self.target.open_directory)) try self.stall();
        return self.backend.dirOpenDir(userdata, dir, path, options);
    }

    fn openFile(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.OpenFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const self = of(userdata);
        if (names(path, self.target.open_file)) try self.stall();
        return self.backend.dirOpenFile(userdata, dir, path, options);
    }

    fn operate(
        userdata: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        const self = of(userdata);
        if (operation == .file_write_streaming) try self.stall();
        return self.backend.operate(userdata, operation);
    }

    fn readDirectory(
        userdata: ?*anyopaque,
        reader: *std.Io.Dir.Reader,
        entries: []std.Io.Dir.Entry,
    ) std.Io.Dir.Reader.Error!usize {
        const self = of(userdata);
        const count = try self.backend.dirRead(userdata, reader, entries);
        if (count == 0) try self.stall();
        return count;
    }

    fn renameAfterCancel(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_sub_path: []const u8,
        new_dir: std.Io.Dir,
        new_sub_path: []const u8,
    ) std.Io.Dir.RenameError!void {
        const self = of(userdata);
        self.stall() catch {};
        return self.backend.dirRename(userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    }
};

pub const SkillFixture = struct {
    tmp: std.testing.TmpDir,
    guard: SkillGuard,
    root: [:0]u8,
    source: []u8,
    body: []const u8 = "---\nname: zig-style\n---\nUse four spaces.\n",

    pub fn init(gpa: std.mem.Allocator) !SkillFixture {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var fixture: SkillFixture = .{
            .tmp = tmp,
            .guard = undefined,
            .root = undefined,
            .source = undefined,
        };
        try tmp.dir.writeFile(io, .{ .sub_path = "SKILL.md", .data = fixture.body });
        fixture.root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(fixture.root);
        fixture.source = try std.Io.Dir.path.join(gpa, &.{ fixture.root, "SKILL.md" });
        errdefer gpa.free(fixture.source);
        fixture.guard = .{ .working_directory = fixture.root };
        try fixture.guard.add(.{
            .glob = "**/*.zig",
            .skill = "zig-style",
            .source = fixture.source,
        });
        return fixture;
    }

    pub fn deinit(self: *SkillFixture, gpa: std.mem.Allocator) void {
        gpa.free(self.root);
        gpa.free(self.source);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

pub fn expectMeasures(output: *const core.Tool.Output, expected: []const Measured) !void {
    var count: usize = 0;
    var measures = output.measures;
    var entries = measures.iterator();
    while (entries.next()) |entry| {
        if (entry.key != .duration_ms) count += 1;
    }
    try std.testing.expectEqual(expected.len, count);
    for (expected) |item| {
        try std.testing.expectEqual(@as(?u64, item[1]), output.measures.get(item[0]));
    }
}

pub fn expectTimed(output: *const core.Tool.Output, expected: []const Measured) !void {
    try std.testing.expect(output.measures.get(.duration_ms) != null);
    try expectMeasures(output, expected);
}

pub fn expectConditions(
    output: *const core.Tool.Output,
    expected: []const core.Tool.Condition,
) !void {
    const wanted: std.EnumSet(core.Tool.Condition) = .initMany(expected);
    try std.testing.expectEqual(wanted.bits.mask, output.conditions.bits.mask);
}
