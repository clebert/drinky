const std = @import("std");

const core = @import("core");

const testing = @import("testing.zig");

pub const marker_name = ".git";

pub const Boundary = struct {
    path: []const u8,
    has_root: bool,
    unreadable_marker: ?Marker = null,

    pub const Marker = struct {
        directory: []const u8,
        err: std.Io.Dir.StatFileError,
    };
};

const Head = struct {
    buffer: [head_bytes_max]u8,
    length: usize,

    pub fn name(self: *const Head) []const u8 {
        return self.buffer[0..self.length];
    }
};

pub fn findBoundary(
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
) !Boundary {
    var current = working_directory;
    for (0..std.Io.Dir.max_path_bytes) |_| {
        const marker_path = try std.Io.Dir.path.join(gpa, &.{ current, marker_name });
        defer gpa.free(marker_path);
        const stat = std.Io.Dir.cwd().statFile(io, marker_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                const parent = std.Io.Dir.path.dirname(current) orelse
                    return .{ .path = working_directory, .has_root = false };
                current = parent;
                continue;
            }
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            return .{
                .path = current,
                .has_root = false,
                .unreadable_marker = .{ .directory = current, .err = err },
            };
        };
        if (stat.kind == .directory or stat.kind == .file) {
            return .{ .path = current, .has_root = true };
        }
        const parent = std.Io.Dir.path.dirname(current) orelse
            return .{ .path = working_directory, .has_root = false };
        current = parent;
    }
    return .{ .path = working_directory, .has_root = false };
}

pub const head_bytes_max = 4096;

const object_name_columns = 7;

pub fn head(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?Head {
    const directory = headDirectory(gpa, io, root) orelse return null;
    defer gpa.free(directory);
    const path = std.Io.Dir.path.join(gpa, &.{ directory, "HEAD" }) catch return null;
    defer gpa.free(path);
    const data = readHeadFile(gpa, io, path) orelse return null;
    defer gpa.free(data);
    return parseHead(data);
}

fn headDirectory(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?[]u8 {
    const marker_path = std.Io.Dir.path.join(gpa, &.{ root, marker_name }) catch return null;
    const stat = std.Io.Dir.cwd().statFile(io, marker_path, .{}) catch {
        gpa.free(marker_path);
        return null;
    };
    if (stat.kind == .directory) return marker_path;
    defer gpa.free(marker_path);
    if (stat.kind != .file) return null;

    const data = readHeadFile(gpa, io, marker_path) orelse return null;
    defer gpa.free(data);
    const prefix = "gitdir: ";
    const line = std.mem.trim(u8, data, " \t\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const target = std.mem.trim(u8, line[prefix.len..], " \t");
    if (target.len == 0) return null;
    if (std.Io.Dir.path.isAbsolute(target)) return gpa.dupe(u8, target) catch null;
    return std.Io.Dir.path.resolve(gpa, &.{ root, target }) catch null;
}

fn readHeadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(head_bytes_max)) catch null;
}

fn parseHead(data: []const u8) ?Head {
    const line = std.mem.trim(u8, data, " \t\r\n");
    const prefix = "ref: ";
    if (std.mem.startsWith(u8, line, prefix)) {
        const reference = std.mem.trim(u8, line[prefix.len..], " \t");
        const branches = "refs/heads/";
        if (std.mem.startsWith(u8, reference, branches)) {
            return headName(reference[branches.len..]);
        }
        return headName(std.Io.Dir.path.basename(reference));
    }
    if (!objectName(line)) return null;
    return headName(line[0..object_name_columns]);
}

fn objectName(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn headName(text: []const u8) ?Head {
    std.debug.assert(text.len < head_bytes_max);
    if (text.len == 0) return null;
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    for (text) |byte| {
        if (std.ascii.isControl(byte)) return null;
    }
    var result: Head = .{ .buffer = undefined, .length = text.len };
    @memcpy(result.buffer[0..text.len], text);
    return result;
}

test "the nearest readable marker is the root, whatever kind it is" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("clone/module/work");
    try tree.directory("clone/.git");
    try tree.write("clone/module/.git", "gitdir: elsewhere\n");

    const working_directory = try tree.path("clone/module/work");
    const expected = try tree.path("clone/module");

    const boundary = try findBoundary(gpa, io, working_directory);
    try std.testing.expect(boundary.has_root);
    try std.testing.expect(boundary.unreadable_marker == null);
    try std.testing.expectEqualStrings(expected, boundary.path);
}

test "a marker that links to a Git directory is the root, and its head names the branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.write("store/work.git/HEAD", "ref: refs/heads/main\n");
    try tree.directory("work/module");
    try tree.link("../store/work.git", "work/.git", .{ .is_directory = true });

    const working_directory = try tree.path("work/module");
    const root = try tree.path("work");

    const boundary = try findBoundary(gpa, io, working_directory);
    try std.testing.expect(boundary.has_root);
    try std.testing.expectEqualStrings(root, boundary.path);
    try std.testing.expectEqualStrings("main", head(gpa, io, root).?.name());
}

test "an unreadable marker stops the walk and travels back as a value" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.link("loop", "loop", .{});
    const working_directory = try tree.path("loop");

    const boundary = try findBoundary(gpa, io, working_directory);
    try std.testing.expect(!boundary.has_root);
    try std.testing.expectEqualStrings(working_directory, boundary.path);
    const marker = boundary.unreadable_marker.?;
    try std.testing.expectEqualStrings(working_directory, marker.directory);
    try std.testing.expectEqual(error.SymLinkLoop, marker.err);
}

test "outside a repository the boundary is the working directory" {
    if (std.Io.Dir.path.sep != '/') return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var seed = std.testing.tmpDir(.{});
    defer seed.cleanup();
    const outside_root = try gpa.print("/tmp/drinky-project-{s}", .{seed.sub_path});
    defer gpa.free(outside_root);
    defer std.Io.Dir.cwd().deleteTree(io, outside_root) catch {};
    const created = try std.Io.Dir.path.join(gpa, &.{ outside_root, "work" });
    defer gpa.free(created);
    var work = try std.Io.Dir.cwd().createDirPathOpen(io, created, .{});
    work.close(io);
    const working_directory = try std.Io.Dir.realPathFileAbsoluteAlloc(io, created, gpa);
    defer gpa.free(working_directory);

    const boundary = try findBoundary(gpa, io, working_directory);
    try std.testing.expect(!boundary.has_root);
    try std.testing.expect(boundary.unreadable_marker == null);
    try std.testing.expectEqualStrings(working_directory, boundary.path);
}

test "a head names its branch, its tag, or its detached object, and only as printable text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    const root = try tree.path("repo");

    const branch_prefix = "ref: refs/heads/";
    const longest = core.text.repeat("b", head_bytes_max - branch_prefix.len - 1);
    const object = "6ab94da2f0a1b3c4d5e6f708192a3b4c5d6e7f80";
    const cases = [_]struct { data: []const u8, name: ?[]const u8 }{
        .{ .data = "ref: refs/heads/main\n", .name = "main" },
        .{ .data = "ref: refs/heads/feature/status-bar\n", .name = "feature/status-bar" },
        .{ .data = "ref: refs/tags/v1.2.0\n", .name = "v1.2.0" },
        .{ .data = object ++ "\n", .name = "6ab94da" },
        .{ .data = object ++ core.text.repeat("0", 24), .name = "6ab94da" },
        .{ .data = "ref: refs/heads/wörk\n", .name = "wörk" },
        .{ .data = branch_prefix ++ core.text.repeat("ä", 40), .name = core.text.repeat("ä", 40) },
        .{ .data = branch_prefix ++ longest, .name = longest },
        .{ .data = branch_prefix ++ longest ++ "b", .name = null },
        .{ .data = "", .name = null },
        .{ .data = "ref: \n", .name = null },
        .{ .data = "ref: refs/heads/\n", .name = null },
        .{ .data = "6ab94da\n", .name = null },
        .{ .data = "gitdir: /elsewhere\n", .name = null },
        .{ .data = "ref: refs/heads/main\x1b[31m", .name = null },
        .{ .data = "ref: refs/heads/main\nnext\n", .name = null },
        .{ .data = "ref: refs/heads/\xff\xfe\n", .name = null },
    };
    for (cases) |case| {
        try tree.write("repo/.git/HEAD", case.data);
        const maybe_head = head(gpa, io, root);
        if (case.name) |name| {
            try std.testing.expectEqualStrings(name, maybe_head.?.name());
        } else {
            try std.testing.expect(maybe_head == null);
        }
    }
}

test "a head reads the Git directory that a marker file names, and a missing head names nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    const root = try tree.path("repo");
    try std.testing.expect(head(gpa, io, root) == null);

    try tree.directory("repo/.git");
    try std.testing.expect(head(gpa, io, root) == null);

    try tree.write("repo/.git/HEAD", "ref: refs/heads/main\n");
    try std.testing.expectEqualStrings("main", head(gpa, io, root).?.name());

    try tree.write("repo/.git/worktrees/next/HEAD", "ref: refs/heads/next\n");
    try tree.write("next/.git", "gitdir: ../repo/.git/worktrees/next\n");
    const worktree_root = try tree.path("next");
    try std.testing.expectEqualStrings("next", head(gpa, io, worktree_root).?.name());

    try tree.write("next/.git", "nothing\n");
    try std.testing.expect(head(gpa, io, worktree_root) == null);
}
