const std = @import("std");

const format = @import("format.zig");
const fs = @import("fs.zig");

pub const ReadError = std.Io.Dir.ReadFileAllocError || error{InvalidSkillText};

pub fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ReadError![]u8 {
    const content = try fs.readFile(gpa, io, path);
    errdefer gpa.free(content);
    if (content.len == 0 or !format.isText(content)) return error.InvalidSkillText;
    return content;
}

pub fn write(
    writer: *std.Io.Writer,
    skill: *const struct { path: []const u8, content: []const u8 },
) std.Io.Writer.Error!void {
    try writer.print(
        "Skill location: {s}\nResolve relative paths in this skill against: {s}\n\n{s}",
        .{ skill.path, std.fs.path.dirname(skill.path) orelse ".", skill.content },
    );
}

test "a skill file must hold text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { data: []const u8, valid: bool }{
        .{ .data = "---\nname: demo\n---\nbody\n", .valid = true },
        .{ .data = "", .valid = false },
        .{ .data = "a\x00b", .valid = false },
        .{ .data = "caf\xE9", .valid = false },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "SKILL.md", .data = case.data });
        const path = try tmp.dir.realPathFileAlloc(io, "SKILL.md", gpa);
        defer gpa.free(path);
        if (!case.valid) {
            try std.testing.expectError(error.InvalidSkillText, read(gpa, io, path));
            continue;
        }
        const content = try read(gpa, io, path);
        defer gpa.free(content);
        try std.testing.expectEqualStrings(case.data, content);
    }
}

test "the header names the file and the directory before the content" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, &.{ .path = "/skills/demo/SKILL.md", .content = "body\n" });
    try std.testing.expectEqualStrings(
        "Skill location: /skills/demo/SKILL.md\n" ++
            "Resolve relative paths in this skill against: /skills/demo\n\nbody\n",
        out.written(),
    );
}
