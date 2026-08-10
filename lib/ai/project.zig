//! The repository boundary of one working directory. This module owns what marks
//! a repository, where a scan must stop, and whether a path stays inside that
//! boundary. Every scan that must not cross a repository reads the rule here, so
//! one answer serves all of them.

const std = @import("std");
const builtin = @import("builtin");

/// The name of the file or directory that marks the root of a repository. A
/// normal clone carries a directory. A worktree and a submodule carry a file.
pub const marker_name = ".git";

/// Where the search for the repository root ended. Every path is a slice of the
/// working directory the search started in, so the caller keeps the memory.
pub const Boundary = struct {
    /// The highest directory a scan can read. It is the repository root when
    /// `has_root` is true. It is the working directory when there is no root, and
    /// the directory of an unreadable marker when the search stopped there.
    path: []const u8,
    /// Whether `path` holds the repository marker. It is always false when
    /// `unreadable_marker` is set, because a marker Pith cannot read proves
    /// nothing about the directory that holds it.
    has_root: bool,
    /// The marker Pith could not read, if the search met one. The search treats
    /// that directory as the top of the walk. It is worse to cross a repository
    /// than to miss a file below an unreadable marker. Only the caller knows
    /// which noun its messages use, so only the caller reports it.
    unreadable_marker: ?Marker = null,

    pub const Marker = struct {
        /// The directory that holds the marker. Join `marker_name` for a message.
        directory: []const u8,
        err: anyerror,
    };
};

/// Find the repository root at or above `working_directory`, which must be an
/// absolute, canonical path. The walk stops at the first marker it can read.
/// Only cancellation and an allocation failure stop it, so a caller always gets
/// a boundary it can scan.
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

pub const ContainsOptions = struct {
    boundary: []const u8,
    target: []const u8,
};

/// Whether `target` is `boundary` itself or a path below it. The test is textual,
/// so both paths must be absolute and canonical. A separator must follow the
/// prefix, so `/repository` does not read as a path inside `/repo`.
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

    // A worktree and a submodule carry a marker file, not a marker directory.
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

    // A symbolic link to itself makes the stat of the marker below it fail for a
    // reason Pith cannot act on. The walk must stop here and not climb into the
    // repository above.
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
    // The cache directory sits inside this repository, so the walk must start
    // where no ancestor carries a marker.
    var seed = std.testing.tmpDir(.{});
    defer seed.cleanup();
    const outside_root = try std.fmt.allocPrint(gpa, "/tmp/pith-project-{s}", .{seed.sub_path});
    defer gpa.free(outside_root);
    defer std.Io.Dir.cwd().deleteTree(io, outside_root) catch {};
    const created = try std.fs.path.join(gpa, &.{ outside_root, "work" });
    defer gpa.free(created);
    var work = try std.Io.Dir.cwd().createDirPathOpen(io, created, .{});
    work.close(io);
    // `/tmp` is a symbolic link on some hosts, and `findBoundary` takes a
    // canonical path.
    const working_directory = try std.Io.Dir.realPathFileAbsoluteAlloc(io, created, gpa);
    defer gpa.free(working_directory);

    const boundary = try findBoundary(gpa, io, working_directory);
    try std.testing.expect(!boundary.has_root);
    try std.testing.expect(boundary.unreadable_marker == null);
    try std.testing.expectEqualStrings(working_directory, boundary.path);
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
