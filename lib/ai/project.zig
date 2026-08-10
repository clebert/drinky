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

/// The longest head name Pith shows. A longer name reads as no head at all.
pub const head_name_bytes_max = 64;

/// The number of characters of an object name that a detached head shows. Git
/// itself prints seven.
const object_name_columns = 7;

/// A marker file or a `HEAD` file above this size holds no head Pith can use.
const head_file_bytes_max = 4096;

/// The head of one repository: a branch name, or the short object name of a
/// detached head. It carries its own bytes, so the caller owns nothing.
pub const Head = struct {
    buffer: [head_name_bytes_max]u8,
    length: usize,

    pub fn name(self: *const Head) []const u8 {
        return self.buffer[0..self.length];
    }
};

/// The head of the repository at `root`, which `findBoundary` reports. Pith never
/// runs the git binary. It reads the one small `HEAD` file, so a caller can name
/// the branch that a command in this directory would act on.
///
/// Null when `root` holds no repository, when Pith cannot read the head, or when
/// the head names nothing a row can show. Nothing here is authoritative, so every
/// failure reads as no head at all.
pub fn head(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?Head {
    const directory = headDirectory(gpa, io, root) orelse return null;
    defer gpa.free(directory);
    const path = std.fs.path.join(gpa, &.{ directory, "HEAD" }) catch return null;
    defer gpa.free(path);
    const data = readHeadFile(gpa, io, path) orelse return null;
    defer gpa.free(data);
    return parseHead(data);
}

/// The directory that holds `HEAD`. A marker directory is that directory itself.
/// A marker file names it on a `gitdir:` line, which is how a worktree and a
/// submodule point at the repository. The result is owned.
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
    // A relative target resolves against the directory that holds the marker
    // file, which is how Git writes a worktree.
    return std.fs.path.resolve(gpa, &.{ root, target }) catch null;
}

fn readHeadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(head_file_bytes_max)) catch null;
}

/// The head that the content of a `HEAD` file names. A symbolic head names a
/// branch. A detached head holds an object name, which shows as its first seven
/// characters.
fn parseHead(data: []const u8) ?Head {
    const line = std.mem.trim(u8, data, " \t\r\n");
    const prefix = "ref: ";
    if (std.mem.startsWith(u8, line, prefix)) {
        const reference = std.mem.trim(u8, line[prefix.len..], " \t");
        const branches = "refs/heads/";
        if (std.mem.startsWith(u8, reference, branches)) {
            return headName(reference[branches.len..]);
        }
        // A head outside `refs/heads/` still names the work, so show its tail
        // rather than nothing.
        return headName(std.fs.path.basename(reference));
    }
    if (!objectName(line)) return null;
    return headName(line[0..object_name_columns]);
}

/// Whether `text` is a Git object name: 40 hexadecimal digits for SHA-1, or 64
/// for SHA-256.
fn objectName(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

/// `text` as a head name, or null when it holds nothing a row can show. A name
/// that does not fit reads as no head, rather than as a cut name that would show
/// a branch which does not exist. This module also has no grapheme table, so it
/// cannot cut one safely. A control byte or invalid UTF-8 rejects the whole name,
/// because the head of a repository must read as itself.
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
    // A head outside `refs/heads/` shows its tail.
    try expectHeadName("v1.2.0", "ref: refs/tags/v1.2.0\n");
    // A detached head shows the short object name, for SHA-1 and for SHA-256.
    try expectHeadName("6ab94da", "6ab94da2f0a1b3c4d5e6f708192a3b4c5d6e7f80\n");
    try expectHeadName("6ab94da", "6ab94da2f0a1b3c4d5e6f708192a3b4c5d6e7f80" ++ "0" ** 24);
    try expectHeadName(null, "");
    try expectHeadName(null, "ref: \n");
    try expectHeadName(null, "ref: refs/heads/\n");
    // Neither a reference nor an object name.
    try expectHeadName(null, "6ab94da\n");
    try expectHeadName(null, "gitdir: /elsewhere\n");
}

test headName {
    // A control byte or invalid UTF-8 rejects the whole name.
    try std.testing.expect(headName("main\x1b[31m") == null);
    try std.testing.expect(headName("main\n") == null);
    try std.testing.expect(headName("\xff\xfe") == null);
    try std.testing.expectEqualStrings("wörk", headName("wörk").?.name());

    // A name that fills the buffer exactly still shows.
    const longest = "b" ** head_name_bytes_max;
    try std.testing.expectEqualStrings(longest, headName(longest).?.name());
    // One byte more reads as no head, because a cut name would show a branch
    // that does not exist, and a cut can split a grapheme cluster.
    try std.testing.expect(headName(longest ++ "b") == null);
    try std.testing.expect(headName("ä" ** 40) == null);
}

test head {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpPath(gpa, io, &tmp, "repo");
    defer gpa.free(root);
    // No repository at all.
    try std.testing.expect(head(gpa, io, root) == null);

    var marker = try tmp.dir.createDirPathOpen(io, "repo/.git", .{});
    marker.close(io);
    // A repository whose head Pith cannot read.
    try std.testing.expect(head(gpa, io, root) == null);

    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.git/HEAD",
        .data = "ref: refs/heads/main\n",
    });
    try std.testing.expectEqualStrings("main", head(gpa, io, root).?.name());

    // A worktree holds a marker file that names the real directory. The relative
    // spelling resolves against the directory that holds that file.
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

    // A marker file that names no directory reads as no head.
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
