const std = @import("std");

const core = @import("core");
const tools = @import("tools");

const Message = @import("../Message.zig");
const project = @import("../project.zig");
const Reports = @import("../Reports.zig");
const testing = @import("../testing.zig");

const file_bytes_max = 32 << 10;
const source_bytes_max = 64 << 10;
const directory_entries_max = 100_000;
pub const file_kibibytes_max = @divExact(file_bytes_max, 1024);
pub const source_kibibytes_max = @divExact(source_bytes_max, 1024);

pub const files_max = 32;

const Source = enum {
    user,
    project,

    fn noun(self: Source) []const u8 {
        return switch (self) {
            .user => "user instruction",
            .project => "project instruction",
        };
    }
};

pub const File = struct {
    path: []const u8,
    content: []const u8,
    identity: []const u8,

    fn deinit(self: *const File, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.content);
        gpa.free(self.identity);
    }
};

const Problem = enum {
    empty,
    too_large,
    not_text,

    fn severity(self: Problem) Message.Severity {
        return switch (self) {
            .empty => .information,
            else => .failure,
        };
    }

    fn reason(self: Problem) []const u8 {
        return switch (self) {
            .empty => "the file is empty",
            .too_large => std.fmt.comptimePrint(
                "the file is larger than {d} KiB",
                .{file_kibibytes_max},
            ),
            .not_text => "the file is not UTF-8 text",
        };
    }
};

const Content = union(enum) {
    loaded: []u8,
    rejected: Problem,
    failed: std.Io.File.Reader.Error,
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    source: Source,
    project_root_path: ?[]const u8 = null,
    file_items: std.ArrayList(File) = .empty,
    reports: Reports = .{ .subject = "instruction files" },
    bytes_total: usize = 0,

    const TakeOptions = struct {
        path: []const u8,
        identity: []const u8,
        file: std.Io.File,
    };

    pub fn init(gpa: std.mem.Allocator, source: Source) Result {
        return .{ .gpa = gpa, .source = source };
    }

    pub fn deinit(self: *Result) void {
        if (self.project_root_path) |project_root| self.gpa.free(project_root);
        for (self.file_items.items) |*file| file.deinit(self.gpa);
        self.file_items.deinit(self.gpa);
        self.reports.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn projectRoot(self: *const Result) ?[]const u8 {
        return self.project_root_path;
    }

    pub fn files(self: *const Result) []const File {
        return self.file_items.items;
    }

    fn holds(self: *const Result, identity: []const u8) bool {
        for (self.file_items.items) |file| {
            if (std.mem.eql(u8, file.identity, identity)) return true;
        }
        return false;
    }

    fn take(self: *Result, io: std.Io, options: *const TakeOptions) !void {
        const noun = self.source.noun();
        if (self.holds(options.identity)) {
            return self.report(
                .failure,
                "Drinky skipped the {s} file {s} because Drinky already loaded the same file.",
                .{ noun, options.path },
            );
        }
        const content = switch (try readContent(self.gpa, io, options.file)) {
            .loaded => |loaded| loaded,
            .rejected => |problem| return self.report(
                problem.severity(),
                "Drinky skipped the {s} file {s} because {s}.",
                .{ noun, options.path, problem.reason() },
            ),
            .failed => |err| return self.report(
                .failure,
                "Drinky could not read the {s} file {s} because of error {s}.",
                .{ noun, options.path, @errorName(err) },
            ),
        };
        errdefer self.gpa.free(content);
        if (self.file_items.items.len == files_max) {
            try self.report(
                .failure,
                "Drinky skipped the {s} file {s} because Drinky already loaded {d} files.",
                .{ noun, options.path, files_max },
            );
            self.gpa.free(content);
            return;
        }
        if (content.len > source_bytes_max - self.bytes_total) {
            try self.report(
                .failure,
                "Drinky skipped the {s} file {s} to keep the total at or below {d} KiB.",
                .{ noun, options.path, source_kibibytes_max },
            );
            self.gpa.free(content);
            return;
        }
        const owned_path = try self.gpa.dupe(u8, options.path);
        errdefer self.gpa.free(owned_path);
        const owned_identity = try self.gpa.dupe(u8, options.identity);
        errdefer self.gpa.free(owned_identity);
        try self.file_items.append(self.gpa, .{
            .path = owned_path,
            .content = content,
            .identity = owned_identity,
        });
        self.bytes_total += content.len;
    }

    fn report(
        self: *Result,
        severity: Message.Severity,
        comptime template: []const u8,
        args: anytype,
    ) !void {
        try self.reports.add(self.gpa, severity, template, args);
    }
};

const Discovery = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
    result: *Result,

    const noun = Source.noun(.project);

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

    fn run(self: *Discovery) !void {
        const boundary = try project.findBoundary(self.gpa, self.io, self.working_directory);
        if (boundary.unreadable_marker) |marker| try self.reportUnreadableMarker(&marker);
        if (boundary.has_root) {
            self.result.project_root_path = try self.gpa.dupe(u8, boundary.path);
        }
        const link_boundary = if (boundary.has_root)
            boundary.path
        else
            self.working_directory;

        var current = self.working_directory;
        for (0..std.Io.Dir.max_path_bytes) |_| {
            try self.scanDirectory(&.{
                .directory = current,
                .source_boundary = boundary.path,
                .link_boundary = link_boundary,
            });
            if (std.mem.eql(u8, current, boundary.path)) break;
            current = std.Io.Dir.path.dirname(current) orelse break;
        }
        std.mem.reverse(File, self.result.file_items.items);
    }

    fn reportUnreadableMarker(self: *Discovery, marker: *const project.Boundary.Marker) !void {
        const marker_path = try std.Io.Dir.path.join(
            self.gpa,
            &.{ marker.directory, project.marker_name },
        );
        defer self.gpa.free(marker_path);
        try self.result.report(
            .failure,
            "Drinky could not inspect the repository marker {s} because of error {s}.",
            .{ marker_path, @errorName(marker.err) },
        );
    }

    fn scanDirectory(self: *Discovery, options: *const ScanOptions) !void {
        var dir = std.Io.Dir.cwd().openDir(
            self.io,
            options.directory,
            .{ .iterate = true },
        ) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.report(
                .failure,
                "Drinky could not scan the directory {s} for AGENTS.md because of error {s}.",
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
                try self.result.report(
                    .failure,
                    "Drinky stopped the scan for AGENTS.md in {s} because of error {s}.",
                    .{ options.directory, @errorName(err) },
                );
                break;
            };
            const entry = maybe_entry orelse {
                scan_complete = true;
                break;
            };
            if (attempt == directory_entries_max) {
                try self.result.report(
                    .failure,
                    "Drinky stopped the scan for AGENTS.md in {s} after {d} entries.",
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
            const path = try std.Io.Dir.path.join(self.gpa, &.{ options.directory, "AGENTS.md" });
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
            const path = try std.Io.Dir.path.join(self.gpa, &.{ options.directory, "CLAUDE.md" });
            defer self.gpa.free(path);
            if (try self.isRegularFile(path)) try self.result.report(
                .failure,
                "Drinky ignored the CLAUDE.md file {s}. Add or link a project instruction file " ++
                    "named AGENTS.md in the same directory.",
                .{path},
            );
        }
        if (agent_present) {
            const path = try std.Io.Dir.path.join(self.gpa, &.{ options.directory, "AGENT.md" });
            defer self.gpa.free(path);
            if (try self.isRegularFile(path)) try self.result.report(
                .failure,
                "Drinky ignored the AGENT.md file {s}. Rename the file to AGENTS.md if the file " ++
                    "contains project instructions.",
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
        const stat = std.Io.Dir.cwd().statFile(
            self.io,
            options.source_path,
            .{ .follow_symlinks = false },
        ) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.report(
                .failure,
                "Drinky could not inspect the " ++ noun ++ " path {s} because of error {s}.",
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
                        try self.result.report(
                            .failure,
                            "Drinky skipped the " ++ noun ++ " file {s} because the " ++
                                "symbolic-link target does not exist.",
                            .{options.source_path},
                        );
                    } else {
                        try self.result.report(
                            .failure,
                            "Drinky could not inspect the symbolic-link target of the " ++ noun ++
                                " file {s} because of error {s}.",
                            .{ options.source_path, @errorName(err) },
                        );
                    }
                    return;
                };
                if (target_stat.kind != .file) {
                    try self.result.report(
                        .failure,
                        "Drinky skipped the " ++ noun ++ " file {s} because the symbolic-link " ++
                            "target is not a regular file.",
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
            else => try self.result.report(
                .failure,
                "Drinky skipped the " ++ noun ++ " path {s} because the path is not a regular " ++
                    "file.",
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
                try self.result.report(
                    .failure,
                    "Drinky skipped the " ++ noun ++ " file {s} because the symbolic-link " ++
                        "target does not exist.",
                    .{options.source_path},
                );
            } else {
                try self.result.report(
                    .failure,
                    "Drinky could not open the " ++ noun ++ " file {s} because of error {s}.",
                    .{ options.source_path, @errorName(err) },
                );
            }
            return;
        };
        defer file.close(self.io);

        const stat = file.stat(self.io) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.report(
                .failure,
                "Drinky could not inspect the open " ++ noun ++ " file {s} because of error {s}.",
                .{ options.source_path, @errorName(err) },
            );
            return;
        };
        if (stat.kind != .file) {
            try self.result.report(
                .failure,
                "Drinky skipped the " ++ noun ++ " path {s} because the path is not a regular " ++
                    "file.",
                .{options.source_path},
            );
            return;
        }

        var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const target_length = file.realPath(self.io, &target_buffer) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.report(
                .failure,
                "Drinky could not resolve the " ++ noun ++ " file {s} because of error {s}.",
                .{ options.source_path, @errorName(err) },
            );
            return;
        };
        const target = target_buffer[0..target_length];
        if (!tools.format.contains(&.{ .boundary = options.content_boundary, .target = target })) {
            try self.result.report(
                .failure,
                "Drinky skipped the " ++ noun ++ " file {s} because the file resolves outside " ++
                    "the project boundary.",
                .{options.source_path},
            );
            return;
        }
        try self.result.take(self.io, &.{
            .path = options.source_path,
            .identity = target,
            .file = file,
        });
    }
};

const LoadOptions = struct {
    directory: []const u8,
    paths: []const []const u8,
};

fn readContent(
    gpa: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
) error{ OutOfMemory, Canceled }!Content {
    var file_reader = file.reader(io, &.{});
    const content = file_reader.interface.allocRemaining(
        gpa,
        .limited(file_bytes_max),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return .{ .rejected = .too_large },
        error.ReadFailed => {
            const read_error = file_reader.err.?;
            if (read_error == error.Canceled) return error.Canceled;
            return .{ .failed = read_error };
        },
    };
    if (checkContent(content)) |problem| {
        gpa.free(content);
        return .{ .rejected = problem };
    }
    return .{ .loaded = content };
}

fn checkContent(content: []const u8) ?Problem {
    if (content.len == 0) return .empty;
    if (!tools.format.isText(content)) return .not_text;
    return null;
}

pub fn discover(
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
) !Result {
    std.debug.assert(std.Io.Dir.path.isAbsolute(working_directory));
    std.debug.assert(std.unicode.utf8ValidateSlice(working_directory));

    var result = Result.init(gpa, .project);
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

pub fn load(gpa: std.mem.Allocator, io: std.Io, options: *const LoadOptions) !Result {
    std.debug.assert(std.Io.Dir.path.isAbsolute(options.directory));

    var result = Result.init(gpa, .user);
    errdefer result.deinit();
    for (options.paths, 0..) |configured, index| {
        if (index == files_max) {
            try result.report(
                .failure,
                "Drinky skipped the remaining {s} files because Drinky already inspected {d} " ++
                    "entries.",
                .{ result.source.noun(), files_max },
            );
            break;
        }
        const path = try std.Io.Dir.path.resolve(gpa, &.{ options.directory, configured });
        defer gpa.free(path);
        try loadPath(&result, io, path);
    }
    return result;
}

fn loadPath(result: *Result, io: std.Io, path: []const u8) !void {
    const noun = result.source.noun();
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        if (err == error.FileNotFound) {
            return result.report(
                .failure,
                "Drinky skipped the {s} path {s} because the path does not exist.",
                .{ noun, path },
            );
        }
        return result.report(
            .failure,
            "Drinky could not inspect the {s} path {s} because of error {s}.",
            .{ noun, path, @errorName(err) },
        );
    };
    if (stat.kind != .file) {
        return result.report(
            .failure,
            "Drinky skipped the {s} path {s} because the path is not a regular file.",
            .{ noun, path },
        );
    }
    const file = cwd.openFile(io, path, .{ .allow_directory = false }) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return result.report(
            .failure,
            "Drinky could not open the {s} file {s} because of error {s}.",
            .{ noun, path, @errorName(err) },
        );
    };
    defer file.close(io);
    var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_length = file.realPath(io, &target_buffer) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return result.report(
            .failure,
            "Drinky could not resolve the {s} file {s} because of error {s}.",
            .{ noun, path, @errorName(err) },
        );
    };
    try result.take(io, &.{
        .path = path,
        .identity = target_buffer[0..target_length],
        .file = file,
    });
}

test "Git-root instructions are retained broad-to-specific without crossing the root" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.write("outer/AGENTS.md", "outside");
    try tree.write("outer/repo/.git", "gitdir: elsewhere\n");
    try tree.write("outer/repo/AGENTS.md", "broad");
    try tree.write("outer/repo/package/AGENTS.md", "specific");
    try tree.directory("outer/repo/package/work");

    const working_directory = try tree.path("outer/repo/package/work");
    const expected_root = try tree.path("outer/repo");
    var result = try discover(gpa, io, working_directory);
    defer result.deinit();

    try std.testing.expectEqualStrings(expected_root, result.projectRoot().?);
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqualStrings("broad", result.files()[0].content);
    try std.testing.expectEqualStrings("specific", result.files()[1].content);
    try std.testing.expect(std.mem.endsWith(u8, result.files()[0].path, "repo/AGENTS.md"));
}

test "outside Git only the working directory is inspected and compatibility files warn" {
    if (std.Io.Dir.path.sep != '/') return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var seed = std.testing.tmpDir(.{});
    defer seed.cleanup();

    const outside_root = try gpa.print("/tmp/drinky-instructions-{s}", .{
        seed.sub_path,
    });
    defer gpa.free(outside_root);
    defer std.Io.Dir.cwd().deleteTree(io, outside_root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, outside_root);
    const parent_agents = try std.Io.Dir.path.join(gpa, &.{ outside_root, "AGENTS.md" });
    defer gpa.free(parent_agents);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = parent_agents, .data = "parent" });
    const working_directory = try std.Io.Dir.path.join(gpa, &.{ outside_root, "work" });
    defer gpa.free(working_directory);
    try std.Io.Dir.cwd().createDirPath(io, working_directory);
    for ([_][]const u8{ "agents.md", "CLAUDE.md", "AGENT.md" }) |name| {
        const path = try std.Io.Dir.path.join(gpa, &.{ working_directory, name });
        defer gpa.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "ignored" });
    }

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expect(result.projectRoot() == null);
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 2), result.reports.messages().len);
    try std.testing.expect(
        std.mem.find(u8, result.reports.messages()[0].content, "CLAUDE.md") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, result.reports.messages()[1].content, "AGENT.md") != null,
    );
}

test "an exact AGENTS.md entry suppresses compatibility warnings even when skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("repo/.git");
    try tree.directory("repo/AGENTS.md");
    try tree.write("repo/CLAUDE.md", "ignored");
    try tree.write("repo/AGENT.md", "ignored");
    const working_directory = try tree.path("repo");

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 1), result.reports.messages().len);
    try std.testing.expect(
        std.mem.find(u8, result.reports.messages()[0].content, "is not a regular file") != null,
    );
}

test "invalid, oversized, and empty files are skipped and reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("repo/.git");
    try tree.write("repo/AGENTS.md", "");
    try tree.write("repo/a/AGENTS.md", "nul\x00text");
    try tree.write("repo/a/b/AGENTS.md", "bad\xfftext");
    try tree.write("repo/a/b/c/AGENTS.md", core.text.repeat("x", file_bytes_max + 1));
    try tree.write("repo/a/b/c/d/AGENTS.md", core.text.repeat("v", file_bytes_max));
    const working_directory = try tree.path("repo/a/b/c/d");

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.files().len);
    try std.testing.expectEqual(@as(usize, file_bytes_max), result.files()[0].content.len);
    try std.testing.expectEqual(@as(usize, 4), result.reports.messages().len);
    var empty_found = false;
    var oversized_found = false;
    var not_text_count: usize = 0;
    for (result.reports.messages()) |notice| {
        if (std.mem.find(u8, notice.content, "is empty") != null) {
            empty_found = true;
            try std.testing.expectEqual(Message.Severity.information, notice.severity);
            continue;
        }
        try std.testing.expectEqual(Message.Severity.failure, notice.severity);
        if (std.mem.find(u8, notice.content, "larger than 32 KiB") != null) {
            oversized_found = true;
        }
        if (std.mem.find(u8, notice.content, "not UTF-8 text") != null) not_text_count += 1;
    }
    try std.testing.expect(empty_found);
    try std.testing.expect(oversized_found);
    try std.testing.expectEqual(@as(usize, 2), not_text_count);
}

test "aggregate budgeting keeps the nearest whole files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("repo/.git");
    try tree.write("repo/AGENTS.md", core.text.repeat("r", 24 << 10));
    try tree.write("repo/a/AGENTS.md", core.text.repeat("a", 24 << 10));
    try tree.write("repo/a/b/AGENTS.md", core.text.repeat("b", 24 << 10));
    const working_directory = try tree.path("repo/a/b");

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqual(@as(u8, 'a'), result.files()[0].content[0]);
    try std.testing.expectEqual(@as(u8, 'b'), result.files()[1].content[0]);
    try std.testing.expectEqual(@as(usize, 1), result.reports.messages().len);
    try std.testing.expect(
        std.mem.find(u8, result.reports.messages()[0].content, "64 KiB") != null,
    );
}

test "the file-count limit also retains the nearest instructions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("repo/.git");
    try tree.write("repo/AGENTS.md", "root");
    var relative: std.Io.Writer.Allocating = .init(gpa);
    defer relative.deinit();
    try relative.writer.writeAll("repo");
    for (0..files_max) |index| {
        try relative.writer.print("/d{d:0>2}", .{index});
        const path = try gpa.print("{s}/AGENTS.md", .{relative.written()});
        defer gpa.free(path);
        try tree.write(path, "nested");
    }
    const working_directory = try tree.path(relative.written());

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, files_max), result.files().len);
    try std.testing.expect(std.mem.endsWith(u8, result.files()[0].path, "d00/AGENTS.md"));
    try std.testing.expect(
        std.mem.endsWith(u8, result.files()[files_max - 1].path, "d31/AGENTS.md"),
    );
    try std.testing.expectEqual(@as(usize, 1), result.reports.messages().len);
}

test "instruction symlinks stay inside the project and load one file once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("repo/.git");
    try tree.write("repo/shared/instructions.md", "linked");
    try tree.write("outside.md", "outside");
    try tree.directory("repo/a/b/c/d");
    const inside_target = try tree.path("repo/shared/instructions.md");
    const directory_target = try tree.path("repo/shared");
    const outside_target = try tree.path("outside.md");
    try tree.link(outside_target, "repo/AGENTS.md", .{});
    try tree.link("missing.md", "repo/a/AGENTS.md", .{});
    try tree.link(inside_target, "repo/a/b/AGENTS.md", .{});
    try tree.link(inside_target, "repo/a/b/c/AGENTS.md", .{});
    try tree.link(directory_target, "repo/a/b/c/d/AGENTS.md", .{ .is_directory = true });
    const working_directory = try tree.path("repo/a/b/c/d");

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.files().len);
    try std.testing.expectEqualStrings("linked", result.files()[0].content);
    try std.testing.expect(std.mem.endsWith(u8, result.files()[0].path, "a/b/c/AGENTS.md"));
    try std.testing.expectEqual(@as(usize, 4), result.reports.messages().len);
    var repeat_found = false;
    for (result.reports.messages()) |notice| {
        if (std.mem.find(u8, notice.content, "already loaded the same file") == null) continue;
        repeat_found = true;
        try std.testing.expect(std.mem.find(u8, notice.content, "a/b/AGENTS.md") != null);
    }
    try std.testing.expect(repeat_found);
}

test "unreadable instruction files are reported and do not load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("repo/.git");
    try tree.write("repo/AGENTS.md", "hidden");
    try tree.tmp.dir.setFilePermissions(io, "repo/AGENTS.md", .fromMode(0), .{});
    defer tree.tmp.dir.setFilePermissions(io, "repo/AGENTS.md", .fromMode(0o600), .{}) catch {};
    const working_directory = try tree.path("repo");
    const source_path = try std.Io.Dir.path.join(gpa, &.{ working_directory, "AGENTS.md" });
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
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 1), result.reports.messages().len);
    try std.testing.expect(
        std.mem.find(u8, result.reports.messages()[0].content, "could not open") != null,
    );
}

test "repository marker inspection errors stop ancestor traversal conservatively" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("blocked/work");
    var blocked = try tree.tmp.dir.openDir(io, "blocked/work", .{ .iterate = true });
    defer blocked.close(io);
    try blocked.setPermissions(io, .fromMode(0));
    defer blocked.setPermissions(io, .fromMode(0o700)) catch {};
    const working_directory = try tree.path("blocked/work");
    const marker_path = try std.Io.Dir.path.join(gpa, &.{ working_directory, project.marker_name });
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
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 2), result.reports.messages().len);
    try std.testing.expect(std.mem.find(
        u8,
        result.reports.messages()[0].content,
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
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
}

test "discovery frees every partial allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("repo/.git");
    try tree.write("repo/AGENTS.md", "root");
    try tree.write("repo/work/AGENTS.md", "work");
    const working_directory = try tree.path("repo/work");

    try std.testing.checkAllAllocationFailures(
        gpa,
        checkDiscoveryAllocationFailure,
        .{ io, working_directory },
    );
}

test "configured files load in order and one file loads once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.write("first.md", "First.\n");
    try tree.write("nested/second.md", "Second.\n");
    const directory = tree.root;
    const absolute_first = try tree.path("first.md");
    try tree.link(absolute_first, "link.md", .{});

    var result = try load(gpa, io, &.{
        .directory = directory,
        .paths = &.{ "nested/second.md", "first.md", "./first.md", absolute_first, "link.md" },
    });
    defer result.deinit();
    try std.testing.expect(result.projectRoot() == null);
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqualStrings("Second.\n", result.files()[0].content);
    try std.testing.expectEqualStrings("First.\n", result.files()[1].content);
    try std.testing.expectEqualStrings(absolute_first, result.files()[1].path);
    try std.testing.expectEqual(@as(usize, 3), result.reports.messages().len);
    for (result.reports.messages()) |notice| {
        try std.testing.expectEqual(Message.Severity.failure, notice.severity);
        try std.testing.expect(
            std.mem.find(u8, notice.content, "already loaded the same file") != null,
        );
    }
}

test "a configured list stops after the file cap and reports the rest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }
    for (0..files_max + 1) |index| {
        const name = try gpa.print("f{d:0>2}.md", .{index});
        errdefer gpa.free(name);
        try tree.write(name, "Instructions.\n");
        try paths.append(gpa, name);
    }
    const directory = tree.root;

    var result = try load(gpa, io, &.{ .directory = directory, .paths = paths.items });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, files_max), result.files().len);
    try std.testing.expectEqual(@as(usize, 1), result.reports.messages().len);
    try std.testing.expect(std.mem.find(
        u8,
        result.reports.messages()[0].content,
        "skipped the remaining user instruction files",
    ) != null);
}

test "configured files stop at the shared byte budget" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.write("a.md", core.text.repeat("a", 24 << 10));
    try tree.write("b.md", core.text.repeat("b", 24 << 10));
    try tree.write("c.md", core.text.repeat("c", 24 << 10));
    const directory = tree.root;

    var result = try load(gpa, io, &.{
        .directory = directory,
        .paths = &.{ "a.md", "b.md", "c.md" },
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqual(@as(u8, 'a'), result.files()[0].content[0]);
    try std.testing.expectEqual(@as(u8, 'b'), result.files()[1].content[0]);
    try std.testing.expectEqual(@as(usize, 1), result.reports.messages().len);
    try std.testing.expect(
        std.mem.find(u8, result.reports.messages()[0].content, "64 KiB") != null,
    );
}

test "an unusable configured path is skipped and reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("directory");
    try tree.write("empty.md", "");
    try tree.write("nul.md", "nul\x00text");
    try tree.write("bad.md", "bad\xfftext");
    try tree.write("exact.md", core.text.repeat("e", file_bytes_max));
    try tree.write("oversized.md", core.text.repeat("o", file_bytes_max + 1));
    const directory = tree.root;

    var result = try load(gpa, io, &.{ .directory = directory, .paths = &.{
        "missing.md",
        "directory",
        "empty.md",
        "nul.md",
        "bad.md",
        "exact.md",
        "oversized.md",
    } });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.files().len);
    try std.testing.expectEqual(@as(usize, file_bytes_max), result.files()[0].content.len);
    try std.testing.expectEqual(@as(usize, 6), result.reports.messages().len);
    const expected_reasons = [_][]const u8{
        "the path does not exist",
        "the path is not a regular file",
        "the file is empty",
        "the file is not UTF-8 text",
        "the file is not UTF-8 text",
        "the file is larger than 32 KiB",
    };
    for (expected_reasons, result.reports.messages()) |reason, notice| {
        try std.testing.expect(std.mem.find(u8, notice.content, reason) != null);
        try std.testing.expect(
            std.mem.find(u8, notice.content, "the user instruction ") != null,
        );
    }
    const empty = result.reports.messages()[2];
    try std.testing.expectEqual(Message.Severity.information, empty.severity);
}

test "an unreadable configured file is skipped and reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.write("hidden.md", "hidden");
    try tree.tmp.dir.setFilePermissions(io, "hidden.md", .fromMode(0), .{});
    defer tree.tmp.dir.setFilePermissions(io, "hidden.md", .fromMode(0o600), .{}) catch {};
    const directory = tree.root;
    const source_path = try tree.path("hidden.md");
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

    var result = try load(gpa, io, &.{ .directory = directory, .paths = &.{"hidden.md"} });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 1), result.reports.messages().len);
    try std.testing.expect(
        std.mem.find(u8, result.reports.messages()[0].content, "could not open") != null,
    );
}

fn checkLoadAllocationFailure(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) !void {
    var result = try load(gpa, io, &.{ .directory = directory, .paths = &.{
        "first.md",
        "missing.md",
        "empty.md",
        "second.md",
        "first.md",
    } });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqual(@as(usize, 3), result.reports.messages().len);
}

test "the configured load frees every partial allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.write("first.md", "First.\n");
    try tree.write("second.md", "Second.\n");
    try tree.write("empty.md", "");
    const directory = tree.root;

    try std.testing.checkAllAllocationFailures(
        gpa,
        checkLoadAllocationFailure,
        .{ io, directory },
    );
}
