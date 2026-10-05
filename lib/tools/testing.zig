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
        fixture.source = try std.fs.path.join(gpa, &.{ fixture.root, "SKILL.md" });
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
