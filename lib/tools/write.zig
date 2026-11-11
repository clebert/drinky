const std = @import("std");

const core = @import("core");

const Context = @import("Context.zig");
const format = @import("format.zig");
const fs = @import("fs.zig");
const output = @import("output.zig");
const parse = @import("parse.zig");
const Sandbox = @import("Sandbox.zig");
const testing = @import("testing.zig");

pub const spec: core.Tool = .{
    .name = "write",
    .description = "Create or overwrite a UTF-8 text file with the given contents.",
    .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "Path to the file" },
        .{
            .name = "content",
            .type = .string,
            .required = true,
            .description = "Complete content that replaces the file",
        },
    },
    .mutates = true,
};

const Input = struct {
    path: []const u8,
    content: []const u8,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) Context.Error!core.Tool.Output {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const path = parsed.value.path;
    const content = parsed.value.content;

    const io = context.host.io;
    fs.writeFile(gpa, io, &context.deadline, &.{
        .path = path,
        .data = content,
        .sandbox = context.host.sandbox,
    }) catch |err| return fs.writeFailure(gpa, err, path);
    var result = try output.sentence(gpa, "Drinky wrote {d} byte{s} to {s}.", .{
        content.len,
        core.text.pluralSuffix(content.len),
        path,
    });
    result.measures.put(.lines, format.lines(content));
    return result;
}

test "write creates a file with the given contents" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/new.txt","content":"hello\nworld\n"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(std.mem.find(u8, result.content, "wrote 12 bytes") != null);
    const data = try tmp.dir.readFileAlloc(io, "new.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("hello\nworld\n", data);
}

const SwapIo = struct {
    vtable: std.Io.VTable,

    fn init() SwapIo {
        var vtable = std.testing.io.vtable.*;
        vtable.dirRealPath = realPath;
        vtable.dirRealPathFile = realPathFile;
        return .{ .vtable = vtable };
    }

    fn io(self: *const SwapIo) std.Io {
        return .{ .userdata = std.testing.io.userdata, .vtable = &self.vtable };
    }

    fn swap(real: []const u8) std.Io.UnexpectedError!void {
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(real), "sub")) return;
        swapDirectory(real) catch return error.Unexpected;
    }

    fn swapDirectory(real: []const u8) !void {
        var moved_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const moved = try std.fmt.bufPrint(
            &moved_buffer,
            "{s}/moved",
            .{std.Io.Dir.path.dirname(real).?},
        );
        const cwd = std.Io.Dir.cwd();
        try cwd.rename(real, cwd, moved, std.testing.io);
        try cwd.symLink(std.testing.io, "../outside", real, .{ .is_directory = true });
    }

    fn realPath(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        out_buffer: []u8,
    ) std.Io.Dir.RealPathError!usize {
        const length = try std.testing.io.vtable.dirRealPath(userdata, dir, out_buffer);
        try swap(out_buffer[0..length]);
        return length;
    }

    fn realPathFile(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        out_buffer: []u8,
    ) std.Io.Dir.RealPathFileError!usize {
        const length = try std.testing.io.vtable.dirRealPathFile(userdata, dir, path, out_buffer);
        try swap(out_buffer[0..length]);
        return length;
    }
};

test "write overwrites an existing file entirely" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old contents" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("new", data);
}

test "a write through a dangling link creates the target and keeps the link" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "AGENTS.md", "CLAUDE.md", .{});
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/CLAUDE.md","content":"new"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    const data = try tmp.dir.readFileAlloc(io, "AGENTS.md", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("new", data);
    var link_buffer: [64]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "CLAUDE.md", &link_buffer);
    try std.testing.expectEqualStrings("AGENTS.md", link_buffer[0..link_len]);
}

test "a write through a link cycle fails and keeps both links" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "b.md", "a.md", .{});
    try tmp.dir.symLink(io, "a.md", "b.md", .{});
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/a.md","content":"new"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.failed});
    try std.testing.expect(std.mem.find(u8, result.content, "SymLinkLoop") != null);
    var link_buffer: [64]u8 = undefined;
    for ([_][2][]const u8{ .{ "a.md", "b.md" }, .{ "b.md", "a.md" } }) |link| {
        const link_len = try tmp.dir.readLink(io, link[0], &link_buffer);
        try std.testing.expectEqualStrings(link[1], link_buffer[0..link_len]);
    }
}

test "write to a missing directory reports an error" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/missing/f.txt","content":"x"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.path_missing});
    try testing.expectMeasures(&result, &.{});
    try std.testing.expect(std.mem.find(u8, result.content, "could not write") != null);
}

test "write canceled mid-write propagates and leaves the file untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
    , .{tmp.sub_path});
    var cancel: testing.CancelIo = .init(.file_write);
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = cancel.io() },
    };
    try std.testing.expectError(error.Canceled, run(&context, input));
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("old", data);
}

test "a write that the time limit stops says that the file can hold either content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { target: testing.StallIo.Target, kept: []const u8 }{
        .{ .target = .write, .kept = "old" },
        .{ .target = .rename_after_cancel, .kept = "new" },
    };
    for (cases) |case| {
        var stall: testing.StallIo = undefined;
        stall.init(gpa, case.target);
        defer stall.deinit();
        const context: Context = .{
            .sink = testing.discard_sink,

            .gpa = gpa,
            .host = .{ .io = stall.io() },
            .deadline = .start(stall.io(), fs.timeout_ms),
        };
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old" });
        var input_buffer: [128]u8 = undefined;
        const input = try std.mem.print(&input_buffer,
            \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
        , .{tmp.sub_path});

        const result = try run(&context, input);
        defer result.deinit(gpa);
        var expected_buffer: [224]u8 = undefined;
        const expected = try std.mem.print(
            &expected_buffer,
            "Drinky stopped the write of .zig-cache/tmp/{s}/f.txt after 10 seconds because the " ++
                "file system did not respond. The file can hold the old or the new content.",
            .{tmp.sub_path},
        );
        try std.testing.expectEqualStrings(expected, result.content);
        try testing.expectConditions(&result, &.{.timed_out});
        try std.testing.expect(stall.canceled.load(.acquire));
        const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
        defer gpa.free(data);
        try std.testing.expectEqualStrings(case.kept, data);
    }
}

test "a sandboxed write reaches only the real paths that the sandbox allows" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "inside/sub");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.createDirPath(io, "store");
    try tmp.dir.symLink(io, "../outside/linked.txt", "inside/link.txt", .{});
    try tmp.dir.symLink(io, "../outside", "inside/folder", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const inside = try std.Io.Dir.path.join(gpa, &.{ root, "inside" });
    defer gpa.free(inside);
    const store_file = try std.Io.Dir.path.join(gpa, &.{ root, "store", "auth.json" });
    defer gpa.free(store_file);
    const sandbox: Sandbox = .{ .directories = &.{inside}, .files = &.{store_file} };
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = io, .sandbox = &sandbox },
    };
    const cases = [_]struct { path: []const u8, written: []const u8, allowed: bool }{
        .{ .path = "inside/sub/new.txt", .written = "inside/sub/new.txt", .allowed = true },
        .{ .path = "store/auth.json", .written = "store/auth.json", .allowed = true },
        .{ .path = "store/other.json", .written = "store/other.json", .allowed = false },
        .{ .path = "outside/new.txt", .written = "outside/new.txt", .allowed = false },
        .{ .path = "inside/link.txt", .written = "outside/linked.txt", .allowed = false },
        .{ .path = "inside/folder/new.txt", .written = "outside/new.txt", .allowed = false },
        .{
            .path = "inside/sub/../../outside/up.txt",
            .written = "outside/up.txt",
            .allowed = false,
        },
    };
    for (cases) |case| {
        var path_buffer: [160]u8 = undefined;
        const path = try std.mem.print(
            &path_buffer,
            ".zig-cache/tmp/{s}/{s}",
            .{ tmp.sub_path, case.path },
        );
        const input = try std.json.Stringify.valueAlloc(gpa, .{
            .path = path,
            .content = "x",
        }, .{});
        defer gpa.free(input);
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try std.testing.expectEqual(!case.allowed, result.hasFailure());
        const exists = if (tmp.dir.access(io, case.written, .{})) true else |_| false;
        try std.testing.expectEqual(case.allowed, exists);
        if (!case.allowed) try std.testing.expect(
            std.mem.endsWith(u8, result.content, "because the path is outside the sandbox."),
        );
    }
}

test "a directory that becomes a link after the sandbox check keeps the write in the sandbox" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "inside/sub");
    try tmp.dir.createDirPath(io, "outside");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const inside = try std.Io.Dir.path.join(gpa, &.{ root, "inside" });
    defer gpa.free(inside);
    const sandbox: Sandbox = .{ .directories = &.{inside}, .files = &.{} };
    const swap: SwapIo = .init();
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = swap.io(), .sandbox = &sandbox },
    };
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/inside/sub/new.txt","content":"x"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    var link_buffer: [64]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "inside/sub", &link_buffer);
    try std.testing.expectEqualStrings("../outside", link_buffer[0..link_len]);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "outside/new.txt", .{}));
    try std.testing.expect(!result.hasFailure());
    const data = try tmp.dir.readFileAlloc(io, "inside/moved/new.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("x", data);
}

test "write measures the lines of what it wrote" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buffer: [160]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/sample.txt","content":"one\ntwo\nthree\n"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try testing.expectMeasures(&result, &.{.{ .lines, 3 }});
    try testing.expectConditions(&result, &.{});
}
