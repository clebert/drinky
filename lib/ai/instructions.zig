//! Bounded discovery of repository-controlled `AGENTS.md` instructions.

const std = @import("std");
const builtin = @import("builtin");

const file_bytes_max = 32 << 10;
const source_bytes_max = 64 << 10;
const entries_max = 32;
const warnings_max = 1024;
const directory_entries_max = 100_000;
const display_bytes_max = 4 * std.fs.max_path_bytes + 1024;

pub const Entry = struct {
    path: []const u8,
    directory: []const u8,
    content: []const u8,

    fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.directory);
        gpa.free(self.content);
        self.* = undefined;
    }
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    project_root_path: ?[]const u8 = null,
    entry_items: std.ArrayList(Entry) = .empty,
    warning_items: std.ArrayList([]const u8) = .empty,
    warnings_capped: bool = false,

    pub fn init(gpa: std.mem.Allocator) Result {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Result) void {
        if (self.project_root_path) |project_root| self.gpa.free(project_root);
        for (self.entry_items.items) |*entry| entry.deinit(self.gpa);
        self.entry_items.deinit(self.gpa);
        for (self.warning_items.items) |warning| self.gpa.free(warning);
        self.warning_items.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn projectRoot(self: *const Result) ?[]const u8 {
        return self.project_root_path;
    }

    pub fn entries(self: *const Result) []const Entry {
        return self.entry_items.items;
    }

    pub fn warnings(self: *const Result) []const []const u8 {
        return self.warning_items.items;
    }

    fn warn(self: *Result, comptime format: []const u8, args: anytype) !void {
        if (self.warnings_capped) return;
        if (self.warning_items.items.len == warnings_max - 1) {
            const notice = try self.gpa.dupe(
                u8,
                "Pith omitted more warnings about project instructions.",
            );
            errdefer self.gpa.free(notice);
            try self.warning_items.append(self.gpa, notice);
            self.warnings_capped = true;
            return;
        }
        const content = try std.fmt.allocPrint(self.gpa, format, args);
        errdefer self.gpa.free(content);
        try self.warning_items.append(self.gpa, content);
    }
};

const Discovery = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
    result: *Result,
    source_bytes_total: usize = 0,

    const Boundary = struct {
        path: []const u8,
        has_project_root: bool,
    };

    const ScanOptions = struct {
        directory: []const u8,
        source_boundary: []const u8,
        link_boundary: []const u8,
    };

    const CandidateOptions = struct {
        source_path: []const u8,
        source_boundary: []const u8,
        link_boundary: []const u8,
    };

    const OpenOptions = struct {
        source_path: []const u8,
        content_boundary: []const u8,
        follow_symlinks: bool,
        was_symlink: bool,
    };

    const ReadOptions = struct {
        source_path: []const u8,
        file: std.Io.File,
    };

    fn run(self: *Discovery) !void {
        const boundary = try self.findBoundary();
        if (boundary.has_project_root) {
            self.result.project_root_path = try self.gpa.dupe(u8, boundary.path);
        }
        const link_boundary = if (boundary.has_project_root)
            boundary.path
        else
            self.working_directory;

        var current = self.working_directory;
        for (0..std.fs.max_path_bytes) |_| {
            try self.scanDirectory(&.{
                .directory = current,
                .source_boundary = boundary.path,
                .link_boundary = link_boundary,
            });
            if (std.mem.eql(u8, current, boundary.path)) break;
            current = std.fs.path.dirname(current) orelse break;
        }
        std.mem.reverse(Entry, self.result.entry_items.items);
    }

    fn findBoundary(self: *Discovery) !Boundary {
        var current = self.working_directory;
        for (0..std.fs.max_path_bytes) |_| {
            const marker_path = try std.fs.path.join(self.gpa, &.{ current, ".git" });
            defer self.gpa.free(marker_path);
            const stat = std.Io.Dir.cwd().statFile(
                self.io,
                marker_path,
                .{ .follow_symlinks = false },
            ) catch |err| {
                if (err == error.FileNotFound) {
                    const parent = std.fs.path.dirname(current) orelse
                        return .{ .path = self.working_directory, .has_project_root = false };
                    current = parent;
                    continue;
                }
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                try self.result.warn(
                    "Pith could not inspect the repository marker {s} because of " ++
                        "technical error {s}.",
                    .{ marker_path, @errorName(err) },
                );
                return .{ .path = current, .has_project_root = false };
            };
            if (stat.kind == .directory or stat.kind == .file) {
                return .{ .path = current, .has_project_root = true };
            }
            const parent = std.fs.path.dirname(current) orelse
                return .{ .path = self.working_directory, .has_project_root = false };
            current = parent;
        }
        return .{ .path = self.working_directory, .has_project_root = false };
    }

    fn scanDirectory(self: *Discovery, options: *const ScanOptions) !void {
        var dir = std.Io.Dir.cwd().openDir(
            self.io,
            options.directory,
            .{ .iterate = true },
        ) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.warn(
                "Pith could not scan {s} for AGENTS.md because of technical error {s}.",
                .{ options.directory, @errorName(err) },
            );
            return;
        };
        defer dir.close(self.io);

        var iterator = dir.iterateAssumeFirstIteration();
        var agents_present = false;
        var claude_present = false;
        var agent_present = false;
        var scan_complete = false;
        for (0..directory_entries_max + 1) |attempt| {
            const maybe_entry = iterator.next(self.io) catch |err| {
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                try self.result.warn(
                    "Pith stopped the scan of {s} for AGENTS.md because of technical error {s}.",
                    .{ options.directory, @errorName(err) },
                );
                break;
            };
            const entry = maybe_entry orelse {
                scan_complete = true;
                break;
            };
            if (attempt == directory_entries_max) {
                try self.result.warn(
                    "Pith stopped the scan of {s} for AGENTS.md after {d} entries.",
                    .{ options.directory, directory_entries_max },
                );
                break;
            }
            if (std.mem.eql(u8, entry.name, "AGENTS.md")) {
                agents_present = true;
                scan_complete = true;
                break;
            }
            if (std.mem.eql(u8, entry.name, "CLAUDE.md")) claude_present = true;
            if (std.mem.eql(u8, entry.name, "AGENT.md")) agent_present = true;
        }

        if (agents_present) {
            const path = try std.fs.path.join(self.gpa, &.{ options.directory, "AGENTS.md" });
            defer self.gpa.free(path);
            try self.loadCandidate(&.{
                .source_path = path,
                .source_boundary = options.source_boundary,
                .link_boundary = options.link_boundary,
            });
            return;
        }
        if (!scan_complete) return;
        if (claude_present) {
            const path = try std.fs.path.join(self.gpa, &.{ options.directory, "CLAUDE.md" });
            defer self.gpa.free(path);
            if (try self.isRegularFile(path)) try self.result.warn(
                "Pith ignored {s}. Add or link an AGENTS.md file in the same directory.",
                .{path},
            );
        }
        if (agent_present) {
            const path = try std.fs.path.join(self.gpa, &.{ options.directory, "AGENT.md" });
            defer self.gpa.free(path);
            if (try self.isRegularFile(path)) try self.result.warn(
                "Pith ignored {s}. Rename the file to AGENTS.md if it contains project " ++
                    "instructions.",
                .{path},
            );
        }
    }

    fn isRegularFile(self: *Discovery, path: []const u8) !bool {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            return false;
        };
        return stat.kind == .file;
    }

    fn loadCandidate(self: *Discovery, options: *const CandidateOptions) !void {
        if (!std.unicode.utf8ValidateSlice(options.source_path)) {
            const safe_path = try diagnosticAlloc(self.gpa, options.source_path);
            defer self.gpa.free(safe_path);
            try self.result.warn(
                "Pith skipped the instruction path {s} because it is not valid UTF-8.",
                .{safe_path},
            );
            return;
        }
        const stat = std.Io.Dir.cwd().statFile(
            self.io,
            options.source_path,
            .{ .follow_symlinks = false },
        ) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.warn(
                "Pith could not inspect {s} because of technical error {s}.",
                .{ options.source_path, @errorName(err) },
            );
            return;
        };
        switch (stat.kind) {
            .file => try self.openCandidate(&.{
                .source_path = options.source_path,
                .content_boundary = options.source_boundary,
                .follow_symlinks = false,
                .was_symlink = false,
            }),
            .sym_link => {
                const target_stat = std.Io.Dir.cwd().statFile(
                    self.io,
                    options.source_path,
                    .{},
                ) catch |err| {
                    if (err == error.Canceled or err == error.OutOfMemory) return err;
                    if (err == error.FileNotFound) {
                        try self.result.warn(
                            "Pith skipped the symbolic link {s} because its target does not exist.",
                            .{options.source_path},
                        );
                    } else {
                        try self.result.warn(
                            "Pith could not inspect the target of {s} because of " ++
                                "technical error {s}.",
                            .{ options.source_path, @errorName(err) },
                        );
                    }
                    return;
                };
                if (target_stat.kind != .file) {
                    try self.result.warn(
                        "Pith skipped {s} because the symbolic-link target is not a regular file.",
                        .{options.source_path},
                    );
                    return;
                }
                try self.openCandidate(&.{
                    .source_path = options.source_path,
                    .content_boundary = options.link_boundary,
                    .follow_symlinks = true,
                    .was_symlink = true,
                });
            },
            else => try self.result.warn(
                "Pith skipped {s} because it is not a regular file.",
                .{options.source_path},
            ),
        }
    }

    fn openCandidate(self: *Discovery, options: *const OpenOptions) !void {
        const file = std.Io.Dir.cwd().openFile(self.io, options.source_path, .{
            .allow_directory = false,
            .follow_symlinks = options.follow_symlinks,
        }) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            if (options.was_symlink and err == error.FileNotFound) {
                try self.result.warn(
                    "Pith skipped the symbolic link {s} because its target does not exist.",
                    .{options.source_path},
                );
            } else {
                try self.result.warn(
                    "Pith could not open {s} because of technical error {s}.",
                    .{ options.source_path, @errorName(err) },
                );
            }
            return;
        };
        defer file.close(self.io);

        const stat = file.stat(self.io) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.warn(
                "Pith could not inspect the open file {s} because of technical error {s}.",
                .{ options.source_path, @errorName(err) },
            );
            return;
        };
        if (stat.kind != .file) {
            try self.result.warn(
                "Pith skipped {s} because it is not a regular file.",
                .{options.source_path},
            );
            return;
        }

        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target_length = file.realPath(self.io, &target_buffer) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.warn(
                "Pith could not resolve {s} because of technical error {s}.",
                .{ options.source_path, @errorName(err) },
            );
            return;
        };
        if (!pathWithin(&.{
            .boundary = options.content_boundary,
            .target = target_buffer[0..target_length],
        })) {
            try self.result.warn(
                "Pith skipped {s} because it resolves outside the project boundary.",
                .{options.source_path},
            );
            return;
        }
        try self.readFile(&.{ .source_path = options.source_path, .file = file });
    }

    fn readFile(self: *Discovery, options: *const ReadOptions) !void {
        var file_reader = options.file.reader(self.io, &.{});
        const content = file_reader.interface.allocRemaining(
            self.gpa,
            .limited(file_bytes_max + 1),
        ) catch |err| {
            switch (err) {
                error.OutOfMemory => return err,
                error.StreamTooLong => try self.result.warn(
                    "Pith skipped {s} because it is larger than 32 KiB.",
                    .{options.source_path},
                ),
                error.ReadFailed => {
                    const read_error = file_reader.err.?;
                    if (read_error == error.Canceled) return read_error;
                    try self.result.warn(
                        "Pith could not read {s} because of technical error {s}.",
                        .{ options.source_path, @errorName(read_error) },
                    );
                },
            }
            return;
        };
        errdefer self.gpa.free(content);
        if (content.len == 0) {
            self.gpa.free(content);
            return;
        }
        if (content.len > file_bytes_max) {
            try self.result.warn(
                "Pith skipped {s} because it is larger than 32 KiB.",
                .{options.source_path},
            );
            self.gpa.free(content);
            return;
        }
        if (std.mem.indexOfScalar(u8, content, 0) != null) {
            try self.result.warn(
                "Pith skipped {s} because it contains a NUL byte.",
                .{options.source_path},
            );
            self.gpa.free(content);
            return;
        }
        if (!std.unicode.utf8ValidateSlice(content)) {
            try self.result.warn(
                "Pith skipped {s} because it is not valid UTF-8.",
                .{options.source_path},
            );
            self.gpa.free(content);
            return;
        }
        if (self.result.entry_items.items.len == entries_max) {
            try self.result.warn(
                "Pith skipped {s} because Pith already loaded 32 project instruction files.",
                .{options.source_path},
            );
            self.gpa.free(content);
            return;
        }
        if (content.len > source_bytes_max - self.source_bytes_total) {
            try self.result.warn(
                "Pith skipped {s} to keep the project instructions at or below 64 KiB.",
                .{options.source_path},
            );
            self.gpa.free(content);
            return;
        }

        var entry: Entry = .{
            .path = try self.gpa.dupe(u8, options.source_path),
            .directory = undefined,
            .content = content,
        };
        errdefer self.gpa.free(entry.path);
        const directory = std.fs.path.dirname(options.source_path) orelse
            return error.InvalidInstructionPath;
        entry.directory = try self.gpa.dupe(u8, directory);
        errdefer self.gpa.free(entry.directory);
        try self.result.entry_items.append(self.gpa, entry);
        self.source_bytes_total += content.len;
    }
};

/// Discover applicable project instructions for an absolute, canonical working
/// directory. The returned result owns all entries, paths, and warnings.
pub fn discover(
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
) !Result {
    if (!std.fs.path.isAbsolute(working_directory)) return error.WorkingDirectoryNotAbsolute;
    if (!std.unicode.utf8ValidateSlice(working_directory)) return error.WorkingDirectoryNotUtf8;

    var result = Result.init(gpa);
    errdefer result.deinit();
    var discovery: Discovery = .{
        .gpa = gpa,
        .io = io,
        .working_directory = working_directory,
        .result = &result,
    };
    try discovery.run();
    return result;
}

/// A bounded terminal-safe rendering of path bytes for startup diagnostics.
pub fn diagnosticAlloc(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    return escapedAlloc(gpa, text, 96);
}

/// Escape control and format characters. Truncate oversized startup messages safely.
pub fn displayAlloc(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    return escapedAlloc(gpa, text, display_bytes_max);
}

fn escapedAlloc(gpa: std.mem.Allocator, text: []const u8, input_bytes_max: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    var index: usize = 0;
    while (index < text.len and index < input_bytes_max) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 0;
        const sequence_valid = length >= 1 and index + length <= text.len and
            index + length <= input_bytes_max and
            std.unicode.utf8ValidateSlice(text[index..][0..length]);
        const codepoint = if (sequence_valid)
            std.unicode.utf8Decode(text[index..][0..length]) catch unreachable
        else
            0;
        if (sequence_valid and codepointPrintable(codepoint)) {
            try output.writer.writeAll(text[index..][0..length]);
            index += length;
        } else {
            try output.writer.print("\\x{x:0>2}", .{text[index]});
            index += 1;
        }
    }
    if (index < text.len) try output.writer.writeAll("…");
    return output.toOwnedSlice();
}

fn codepointPrintable(codepoint: u21) bool {
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return false;
    // Unicode format controls can hide or reorder path diagnostics.
    return switch (codepoint) {
        0x00ad,
        0x0600...0x0605,
        0x061c,
        0x06dd,
        0x070f,
        0x0890...0x0891,
        0x08e2,
        0x180e,
        0x200b...0x200f,
        0x2028...0x202e,
        0x2060...0x2064,
        0x2066...0x206f,
        0xfeff,
        0xfff9...0xfffb,
        0x110bd,
        0x110cd,
        0x13430...0x1343f,
        0x1bca0...0x1bca3,
        0x1d173...0x1d17a,
        0xe0001,
        0xe0020...0xe007f,
        => false,
        else => true,
    };
}

const ContainmentOptions = struct {
    boundary: []const u8,
    target: []const u8,
};

fn pathWithin(options: *const ContainmentOptions) bool {
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

fn makeTestDir(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    var created = try dir.createDirPathOpen(io, path, .{});
    created.close(io);
}

const TestFileOptions = struct {
    path: []const u8,
    data: []const u8,
};

fn writeTestFile(io: std.Io, dir: std.Io.Dir, options: *const TestFileOptions) !void {
    if (std.fs.path.dirname(options.path)) |parent| try makeTestDir(io, dir, parent);
    try dir.writeFile(io, .{ .sub_path = options.path, .data = options.data });
}

test "Git-root instructions are retained broad-to-specific without crossing the root" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(io, tmp.dir, &.{ .path = "outer/AGENTS.md", .data = "outside" });
    try writeTestFile(io, tmp.dir, &.{
        .path = "outer/repo/.git",
        .data = "gitdir: elsewhere\n",
    });
    try writeTestFile(io, tmp.dir, &.{ .path = "outer/repo/AGENTS.md", .data = "broad" });
    try writeTestFile(io, tmp.dir, &.{
        .path = "outer/repo/package/AGENTS.md",
        .data = "specific",
    });
    try makeTestDir(io, tmp.dir, "outer/repo/package/work");

    const working_directory = try tmpPath(gpa, io, &tmp, "outer/repo/package/work");
    defer gpa.free(working_directory);
    const expected_root = try tmpPath(gpa, io, &tmp, "outer/repo");
    defer gpa.free(expected_root);
    var result = try discover(gpa, io, working_directory);
    defer result.deinit();

    try std.testing.expectEqualStrings(expected_root, result.projectRoot().?);
    try std.testing.expectEqual(@as(usize, 2), result.entries().len);
    try std.testing.expectEqualStrings("broad", result.entries()[0].content);
    try std.testing.expectEqualStrings("specific", result.entries()[1].content);
    try std.testing.expect(std.mem.endsWith(u8, result.entries()[0].path, "repo/AGENTS.md"));
}

test "outside Git only the working directory is inspected and compatibility files warn" {
    if (std.fs.path.sep != '/') return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var seed = std.testing.tmpDir(.{});
    defer seed.cleanup();

    const outside_root = try std.fmt.allocPrint(gpa, "/tmp/pith-instructions-{s}", .{
        seed.sub_path,
    });
    defer gpa.free(outside_root);
    defer std.Io.Dir.cwd().deleteTree(io, outside_root) catch {};
    try makeTestDir(io, std.Io.Dir.cwd(), outside_root);
    const parent_agents = try std.fs.path.join(gpa, &.{ outside_root, "AGENTS.md" });
    defer gpa.free(parent_agents);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = parent_agents, .data = "parent" });
    const working_directory = try std.fs.path.join(gpa, &.{ outside_root, "work" });
    defer gpa.free(working_directory);
    try makeTestDir(io, std.Io.Dir.cwd(), working_directory);
    for ([_][]const u8{ "agents.md", "CLAUDE.md", "AGENT.md" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ working_directory, name });
        defer gpa.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "ignored" });
    }

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expect(result.projectRoot() == null);
    try std.testing.expectEqual(@as(usize, 0), result.entries().len);
    try std.testing.expectEqual(@as(usize, 2), result.warnings().len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings()[0], "CLAUDE.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings()[1], "AGENT.md") != null);
}

test "an exact AGENTS.md entry suppresses compatibility warnings even when skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "repo/.git");
    try makeTestDir(io, tmp.dir, "repo/AGENTS.md");
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/CLAUDE.md", .data = "ignored" });
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/AGENT.md", .data = "ignored" });
    const working_directory = try tmpPath(gpa, io, &tmp, "repo");
    defer gpa.free(working_directory);

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.entries().len);
    try std.testing.expectEqual(@as(usize, 1), result.warnings().len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings()[0], "not a regular file") != null);
}

test "invalid and oversized files are skipped while empty files are silent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "repo/.git");
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/AGENTS.md", .data = "" });
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/a/AGENTS.md", .data = "nul\x00text" });
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo/a/b/AGENTS.md",
        .data = "bad\xfftext",
    });
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo/a/b/c/AGENTS.md",
        .data = "x" ** (file_bytes_max + 1),
    });
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo/a/b/c/d/AGENTS.md",
        .data = "v" ** file_bytes_max,
    });
    const working_directory = try tmpPath(gpa, io, &tmp, "repo/a/b/c/d");
    defer gpa.free(working_directory);

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.entries().len);
    try std.testing.expectEqual(@as(usize, file_bytes_max), result.entries()[0].content.len);
    try std.testing.expectEqual(@as(usize, 3), result.warnings().len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings()[0], "larger than 32 KiB") != null);
}

test "instruction warnings are bounded" {
    const gpa = std.testing.allocator;
    var result = Result.init(gpa);
    defer result.deinit();

    for (0..warnings_max + 8) |index| try result.warn("warning {d}", .{index});

    try std.testing.expectEqual(@as(usize, warnings_max), result.warnings().len);
    try std.testing.expectEqualStrings(
        "Pith omitted more warnings about project instructions.",
        result.warnings()[warnings_max - 1],
    );
}

test "aggregate budgeting keeps the nearest whole files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "repo/.git");
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo/AGENTS.md",
        .data = "r" ** (24 << 10),
    });
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo/a/AGENTS.md",
        .data = "a" ** (24 << 10),
    });
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo/a/b/AGENTS.md",
        .data = "b" ** (24 << 10),
    });
    const working_directory = try tmpPath(gpa, io, &tmp, "repo/a/b");
    defer gpa.free(working_directory);

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.entries().len);
    try std.testing.expectEqual(@as(u8, 'a'), result.entries()[0].content[0]);
    try std.testing.expectEqual(@as(u8, 'b'), result.entries()[1].content[0]);
    try std.testing.expectEqual(@as(usize, 1), result.warnings().len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings()[0], "64 KiB") != null);
}

test "the file-count limit also retains the nearest instructions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "repo/.git");
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/AGENTS.md", .data = "root" });
    var relative: std.Io.Writer.Allocating = .init(gpa);
    defer relative.deinit();
    try relative.writer.writeAll("repo");
    for (0..entries_max) |index| {
        try relative.writer.print("/d{d:0>2}", .{index});
        const path = try std.fmt.allocPrint(gpa, "{s}/AGENTS.md", .{relative.written()});
        defer gpa.free(path);
        try writeTestFile(io, tmp.dir, &.{ .path = path, .data = "nested" });
    }
    const working_directory = try tmpPath(gpa, io, &tmp, relative.written());
    defer gpa.free(working_directory);

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, entries_max), result.entries().len);
    try std.testing.expect(std.mem.endsWith(u8, result.entries()[0].directory, "d00"));
    try std.testing.expect(std.mem.endsWith(u8, result.entries()[entries_max - 1].directory, "d31"));
    try std.testing.expectEqual(@as(usize, 1), result.warnings().len);
}

test "instruction symlinks stay inside the project and retain their source paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "repo/.git");
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo/shared/instructions.md",
        .data = "linked",
    });
    try writeTestFile(io, tmp.dir, &.{ .path = "outside.md", .data = "outside" });
    try makeTestDir(io, tmp.dir, "repo/a/b/c/d");
    const inside_target = try tmpPath(gpa, io, &tmp, "repo/shared/instructions.md");
    defer gpa.free(inside_target);
    const directory_target = try tmpPath(gpa, io, &tmp, "repo/shared");
    defer gpa.free(directory_target);
    const outside_target = try tmpPath(gpa, io, &tmp, "outside.md");
    defer gpa.free(outside_target);
    tmp.dir.symLink(io, outside_target, "repo/AGENTS.md", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return error.SkipZigTest,
        else => return err,
    };
    try tmp.dir.symLink(io, "missing.md", "repo/a/AGENTS.md", .{});
    try tmp.dir.symLink(io, inside_target, "repo/a/b/AGENTS.md", .{});
    try tmp.dir.symLink(io, inside_target, "repo/a/b/c/AGENTS.md", .{});
    try tmp.dir.symLink(
        io,
        directory_target,
        "repo/a/b/c/d/AGENTS.md",
        .{ .is_directory = true },
    );
    const working_directory = try tmpPath(gpa, io, &tmp, "repo/a/b/c/d");
    defer gpa.free(working_directory);

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.entries().len);
    try std.testing.expectEqualStrings("linked", result.entries()[0].content);
    try std.testing.expect(std.mem.endsWith(u8, result.entries()[0].path, "a/b/AGENTS.md"));
    try std.testing.expect(std.mem.endsWith(u8, result.entries()[1].path, "a/b/c/AGENTS.md"));
    try std.testing.expectEqual(@as(usize, 3), result.warnings().len);
}

test "unreadable instruction files warn and do not load" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "repo/.git");
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/AGENTS.md", .data = "hidden" });
    try tmp.dir.setFilePermissions(io, "repo/AGENTS.md", .fromMode(0), .{});
    defer tmp.dir.setFilePermissions(io, "repo/AGENTS.md", .fromMode(0o600), .{}) catch {};
    const working_directory = try tmpPath(gpa, io, &tmp, "repo");
    defer gpa.free(working_directory);
    const source_path = try std.fs.path.join(gpa, &.{ working_directory, "AGENTS.md" });
    defer gpa.free(source_path);
    const maybe_probe: ?std.Io.File = probe: {
        const file = std.Io.Dir.cwd().openFile(io, source_path, .{}) catch |err| {
            if (err == error.AccessDenied or err == error.PermissionDenied) break :probe null;
            return err;
        };
        break :probe file;
    };
    if (maybe_probe) |probe| {
        probe.close(io);
        return error.SkipZigTest;
    }

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.entries().len);
    try std.testing.expectEqual(@as(usize, 1), result.warnings().len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings()[0], "could not open") != null);
}

test "repository marker inspection errors stop ancestor traversal conservatively" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "blocked/work");
    var blocked = try tmp.dir.openDir(io, "blocked/work", .{ .iterate = true });
    defer blocked.close(io);
    try blocked.setPermissions(io, .fromMode(0));
    defer blocked.setPermissions(io, .fromMode(0o700)) catch {};
    const working_directory = try tmpPath(gpa, io, &tmp, "blocked/work");
    defer gpa.free(working_directory);
    const marker_path = try std.fs.path.join(gpa, &.{ working_directory, ".git" });
    defer gpa.free(marker_path);
    const marker_blocked = inspect: {
        _ = std.Io.Dir.cwd().statFile(io, marker_path, .{}) catch |err| {
            if (err == error.AccessDenied or err == error.PermissionDenied) break :inspect true;
            if (err == error.FileNotFound) break :inspect false;
            return err;
        };
        break :inspect false;
    };
    if (!marker_blocked) return error.SkipZigTest;

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expect(result.projectRoot() == null);
    try std.testing.expectEqual(@as(usize, 0), result.entries().len);
    try std.testing.expectEqual(@as(usize, 2), result.warnings().len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.warnings()[0],
        "could not inspect the repository marker",
    ) != null);
}

fn checkDiscoveryAllocationFailure(
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
) !void {
    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.entries().len);
}

test "discovery frees every partial allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "repo/.git");
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/AGENTS.md", .data = "root" });
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/work/AGENTS.md", .data = "work" });
    const working_directory = try tmpPath(gpa, io, &tmp, "repo/work");
    defer gpa.free(working_directory);

    try std.testing.checkAllAllocationFailures(
        gpa,
        checkDiscoveryAllocationFailure,
        .{ io, working_directory },
    );
}

test "invalid working directories and source paths fail safely" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.WorkingDirectoryNotAbsolute,
        discover(gpa, undefined, "relative"),
    );
    try std.testing.expectError(
        error.WorkingDirectoryNotUtf8,
        discover(gpa, undefined, "/tmp/\xff"),
    );

    var result = Result.init(gpa);
    defer result.deinit();
    var discovery: Discovery = .{
        .gpa = gpa,
        .io = undefined,
        .working_directory = "/tmp",
        .result = &result,
    };
    try discovery.loadCandidate(&.{
        .source_path = "/tmp/\xc2\x9b\xe2\x80\xae\xff/AGENTS.md",
        .source_boundary = "/tmp",
        .link_boundary = "/tmp",
    });
    try std.testing.expectEqual(@as(usize, 1), result.warnings().len);
    const warning = result.warnings()[0];
    try std.testing.expect(std.mem.indexOf(u8, warning, "\\xc2\\x9b") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "\\xe2\\x80\\xae") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "\\xff") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, warning, 0xff) == null);

    const display = try displayAlloc(
        gpa,
        "/tmp/line\n\xe2\x80\xaereordered\xe2\x80\xa8next",
    );
    defer gpa.free(display);
    try std.testing.expectEqualStrings(
        "/tmp/line\\x0a\\xe2\\x80\\xaereordered\\xe2\\x80\\xa8next",
        display,
    );

    const oversized = try displayAlloc(gpa, "x" ** (display_bytes_max + 1));
    defer gpa.free(oversized);
    try std.testing.expectEqual(display_bytes_max + "…".len, oversized.len);
    try std.testing.expect(std.mem.endsWith(u8, oversized, "…"));
}

test pathWithin {
    try std.testing.expect(pathWithin(&.{ .boundary = "/repo", .target = "/repo" }));
    try std.testing.expect(pathWithin(&.{ .boundary = "/repo", .target = "/repo/file" }));
    try std.testing.expect(!pathWithin(&.{ .boundary = "/repo", .target = "/repository/file" }));
    try std.testing.expect(pathWithin(&.{ .boundary = "/", .target = "/outside" }));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(pathWithin(&.{
            .boundary = "\\\\server\\share",
            .target = "\\\\server\\share\\file",
        }));
        try std.testing.expect(!pathWithin(&.{
            .boundary = "\\\\server\\share",
            .target = "\\\\server\\share2\\file",
        }));
    }
}
