const std = @import("std");
const builtin = @import("builtin");

pub const marker_name = ".git";

pub const Boundary = struct {
    path: []const u8,
    has_root: bool,
    unreadable_marker: ?Marker = null,

    pub const Marker = struct {
        directory: []const u8,
        err: anyerror,
    };
};

pub fn findBoundary(
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
) !Boundary {
    var current = working_directory;
    for (0..std.fs.max_path_bytes) |_| {
        const marker_path = try std.fs.path.join(gpa, &.{ current, marker_name });
        defer gpa.free(marker_path);
        const stat = std.Io.Dir.cwd().statFile(io, marker_path, .{
            .follow_symlinks = false,
        }) catch |err| {
            if (err == error.FileNotFound) {
                const parent = std.fs.path.dirname(current) orelse
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
        const parent = std.fs.path.dirname(current) orelse
            return .{ .path = working_directory, .has_root = false };
        current = parent;
    }
    return .{ .path = working_directory, .has_root = false };
}

const head_file_bytes_max = 4096;

pub const head_name_bytes_max = head_file_bytes_max;

const object_name_columns = 7;

pub const Head = struct {
    buffer: [head_name_bytes_max]u8,
    length: usize,

    pub fn name(self: *const Head) []const u8 {
        return self.buffer[0..self.length];
    }
};

pub fn head(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?Head {
    const directory = headDirectory(gpa, io, root) orelse return null;
    defer gpa.free(directory);
    const path = std.fs.path.join(gpa, &.{ directory, "HEAD" }) catch return null;
    defer gpa.free(path);
    const data = readHeadFile(gpa, io, path) orelse return null;
    defer gpa.free(data);
    return parseHead(data);
}

fn headDirectory(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?[]u8 {
    const marker_path = std.fs.path.join(gpa, &.{ root, marker_name }) catch return null;
    const stat = std.Io.Dir.cwd().statFile(io, marker_path, .{
        .follow_symlinks = false,
    }) catch {
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
    if (std.fs.path.isAbsolute(target)) return gpa.dupe(u8, target) catch null;
    return std.fs.path.resolve(gpa, &.{ root, target }) catch null;
}

fn readHeadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(head_file_bytes_max)) catch null;
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
        return headName(std.fs.path.basename(reference));
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
    if (text.len == 0 or text.len > head_name_bytes_max) return null;
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    for (text) |byte| {
        if (std.ascii.isControl(byte)) return null;
    }
    var result: Head = .{ .buffer = undefined, .length = text.len };
    @memcpy(result.buffer[0..text.len], text);
    return result;
}

pub const ContainsOptions = struct {
    boundary: []const u8,
    target: []const u8,
};

pub fn contains(options: *const ContainsOptions) bool {
    if (std.mem.eql(u8, options.boundary, options.target)) return true;
    if (!std.mem.startsWith(u8, options.target, options.boundary) or
        options.target.len <= options.boundary.len)
    {
        return false;
    }
    if (std.fs.path.isSep(options.boundary[options.boundary.len - 1])) return true;
    return std.fs.path.isSep(options.target[options.boundary.len]);
}

fn tmpPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    tmp: *const std.testing.TmpDir,
    suffix: []const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, suffix });
}

test "the nearest readable marker is the root, whatever kind it is" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work = try tmp.dir.createDirPathOpen(io, "clone/module/work", .{});
    work.close(io);
    var clone = try tmp.dir.createDirPathOpen(io, "clone/.git", .{});
    clone.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "clone/module/.git",
        .data = "gitdir: elsewhere\n",
    });

    const working_directory = try tmpPath(gpa, io, &tmp, "clone/module/work");
    defer gpa.free(working_directory);
    const expected = try tmpPath(gpa, io, &tmp, "clone/module");
    defer gpa.free(expected);

    const boundary = try findBoundary(gpa, io, working_directory);
    try std.testing.expect(boundary.has_root);
    try std.testing.expect(boundary.unreadable_marker == null);
    try std.testing.expectEqualStrings(expected, boundary.path);
}

test "an unreadable marker stops the walk and travels back as a value" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.symLink(io, "loop", "loop", .{});
    const working_directory = try tmpPath(gpa, io, &tmp, "loop");
    defer gpa.free(working_directory);

    const boundary = try findBoundary(gpa, io, working_directory);
    try std.testing.expect(!boundary.has_root);
    try std.testing.expectEqualStrings(working_directory, boundary.path);
    const marker = boundary.unreadable_marker.?;
    try std.testing.expectEqualStrings(working_directory, marker.directory);
    try std.testing.expectEqual(error.SymLinkLoop, marker.err);
}

test "outside a repository the boundary is the working directory" {
    if (std.fs.path.sep != '/') return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var seed = std.testing.tmpDir(.{});
    defer seed.cleanup();
    const outside_root = try std.fmt.allocPrint(gpa, "/tmp/drinky-project-{s}", .{seed.sub_path});
    defer gpa.free(outside_root);
    defer std.Io.Dir.cwd().deleteTree(io, outside_root) catch {};
    const created = try std.fs.path.join(gpa, &.{ outside_root, "work" });
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

fn expectHeadName(expected: ?[]const u8, data: []const u8) !void {
    const maybe_head = parseHead(data);
    if (expected) |text| {
        try std.testing.expectEqualStrings(text, maybe_head.?.name());
    } else {
        try std.testing.expect(maybe_head == null);
    }
}

test parseHead {
    try expectHeadName("main", "ref: refs/heads/main\n");
    try expectHeadName("feature/status-bar", "ref: refs/heads/feature/status-bar\n");
    try expectHeadName("v1.2.0", "ref: refs/tags/v1.2.0\n");
    try expectHeadName("6ab94da", "6ab94da2f0a1b3c4d5e6f708192a3b4c5d6e7f80\n");
    try expectHeadName("6ab94da", "6ab94da2f0a1b3c4d5e6f708192a3b4c5d6e7f80" ++ "0" ** 24);
    try expectHeadName(null, "");
    try expectHeadName(null, "ref: \n");
    try expectHeadName(null, "ref: refs/heads/\n");
    try expectHeadName(null, "6ab94da\n");
    try expectHeadName(null, "gitdir: /elsewhere\n");
}

test headName {
    try std.testing.expect(headName("main\x1b[31m") == null);
    try std.testing.expect(headName("main\n") == null);
    try std.testing.expect(headName("\xff\xfe") == null);
    try std.testing.expectEqualStrings("wörk", headName("wörk").?.name());

    const long_unicode = "ä" ** 40;
    try std.testing.expectEqualStrings(long_unicode, headName(long_unicode).?.name());

    const longest = "b" ** head_name_bytes_max;
    try std.testing.expectEqualStrings(longest, headName(longest).?.name());
    try std.testing.expect(headName(longest ++ "b") == null);
}

test head {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpPath(gpa, io, &tmp, "repo");
    defer gpa.free(root);
    try std.testing.expect(head(gpa, io, root) == null);

    var marker = try tmp.dir.createDirPathOpen(io, "repo/.git", .{});
    marker.close(io);
    try std.testing.expect(head(gpa, io, root) == null);

    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.git/HEAD",
        .data = "ref: refs/heads/main\n",
    });
    try std.testing.expectEqualStrings("main", head(gpa, io, root).?.name());

    var worktree_marker = try tmp.dir.createDirPathOpen(io, "repo/.git/worktrees/next", .{});
    worktree_marker.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.git/worktrees/next/HEAD",
        .data = "ref: refs/heads/next\n",
    });
    var worktree = try tmp.dir.createDirPathOpen(io, "next", .{});
    worktree.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "next/.git",
        .data = "gitdir: ../repo/.git/worktrees/next\n",
    });
    const worktree_root = try tmpPath(gpa, io, &tmp, "next");
    defer gpa.free(worktree_root);
    try std.testing.expectEqualStrings("next", head(gpa, io, worktree_root).?.name());

    try tmp.dir.writeFile(io, .{ .sub_path = "next/.git", .data = "nothing\n" });
    try std.testing.expect(head(gpa, io, worktree_root) == null);
}

test contains {
    try std.testing.expect(contains(&.{ .boundary = "/repo", .target = "/repo" }));
    try std.testing.expect(contains(&.{ .boundary = "/repo", .target = "/repo/file" }));
    try std.testing.expect(!contains(&.{ .boundary = "/repo", .target = "/repository/file" }));
    try std.testing.expect(contains(&.{ .boundary = "/", .target = "/outside" }));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(contains(&.{
            .boundary = "\\\\server\\share",
            .target = "\\\\server\\share\\file",
        }));
        try std.testing.expect(!contains(&.{
            .boundary = "\\\\server\\share",
            .target = "\\\\server\\share2\\file",
        }));
    }
}
