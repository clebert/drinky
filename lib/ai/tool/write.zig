//! Creates or overwrites a UTF-8 text file with the given contents.

const std = @import("std");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const SkillGuard = @import("SkillGuard.zig");
const fs = @import("fs.zig");
const parse = @import("parse.zig");

pub const spec: llm.Tool = .{
    .name = "write",
    .description = "Create or overwrite a UTF-8 text file with the given contents.",
    .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "Path to the file" },
        .{
            .name = "content",
            .type = .string,
            .required = true,
            .description = "Full file contents; replaces the file entirely",
        },
    },
};

const Input = struct {
    path: []const u8,
    content: []const u8,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const path = parsed.value.path;
    const contents = parsed.value.content;

    // A rule that guards this file refuses the call before it changes anything.
    if (context.skill_guard) |guard| {
        if (try guard.refusal(&.{
            .gpa = gpa,
            .io = context.io,
            .path = path,
            .history = context.history,
        })) |refused| return refused;
    }

    fs.writeFile(context.io, std.Io.Dir.cwd(), .{ .sub_path = path, .data = contents }) catch |err|
        return Result.cannot(gpa, err, "write", path);
    var result = try Result.report(gpa, .ok, "Drinky wrote {d} bytes to {s}.", .{
        contents.len,
        path,
    });
    errdefer result.deinit(gpa);
    // The whole file is what the call produced, so the line counts it. `write`
    // never reads the file it replaces, so it cannot state a change. The model
    // keeps the exact byte count in the content above.
    result.summary = .{
        .text = try std.fmt.allocPrint(gpa, "Lines: {d}", .{format.lines(contents)}),
    };
    return result;
}

test "write creates a file with the given contents" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/new.txt","content":"hello\nworld\n"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "wrote 12 bytes") != null);
    const data = try tmp.dir.readFileAlloc(io, "new.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("hello\nworld\n", data);
}

test "write overwrites an existing file entirely" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old contents" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("new", data);
}

test "write to a missing directory reports an error" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/missing/f.txt","content":"x"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "could not write") != null);
}

test "write canceled mid-write propagates and leaves the file untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
    , .{tmp.sub_path});
    var cancel: fs.CancelIo = .init(.file_write);
    const context: Context = .{ .gpa = gpa, .io = cancel.io() };
    try std.testing.expectError(error.Canceled, run(&context, input));
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("old", data);
}

// A rule that guards the file must stop the call before it writes anything.
// A refusal after the write states a requirement the file no longer needs.
test "a required skill refuses the write and leaves the file absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "---\nname: zig-style\n---\nUse four spaces.\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "SKILL.md", .data = body });
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const source = try std.fs.path.join(
        gpa,
        &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "SKILL.md" },
    );
    defer gpa.free(source);
    var guard: SkillGuard = .{ .working_directory = cwd };
    try guard.add(.{ .glob = "**/*.zig", .skill = "zig-style", .source = source });

    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/new.zig","content":"const x = 1;\n"}}
    , .{tmp.sub_path});
    const blocked: Context = .{ .gpa = gpa, .io = io, .skill_guard = &guard };
    const refused = try run(&blocked, input);
    defer refused.deinit(gpa);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.content, "zig-style") != null);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.readFileAlloc(io, "new.zig", gpa, .limited(64)),
    );

    // The conversation carries the whole skill file, so the same call writes.
    const history = [_]llm.Item{
        .{ .tool_result = .{ .call_id = "1", .content = body, .is_error = false } },
    };
    const loaded: Context = .{
        .gpa = gpa,
        .io = io,
        .skill_guard = &guard,
        .history = &history,
    };
    const written = try run(&loaded, input);
    defer written.deinit(gpa);
    try std.testing.expect(!written.is_error);
    const data = try tmp.dir.readFileAlloc(io, "new.zig", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("const x = 1;\n", data);
}

// `write` and `read` count lines under one rule, so a write and a read of the
// same bytes cannot disagree about the number.
test "the box reports the lines of what was written" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/sample.txt","content":"one\ntwo\nthree\n"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    // A closing line break ends the third line, it does not open a fourth.
    try std.testing.expectEqualStrings("Lines: 3", result.summary.?.text);
}
