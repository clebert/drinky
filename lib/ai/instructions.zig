//! Bounded loading of the instruction files that go into the system prompt.
//! `discover` finds the repository-controlled `AGENTS.md` files, and `load`
//! reads the user files that `config.json` names. Both sources run one policy,
//! so they accept the same bytes, hold the same totals, and report the same
//! reasons through one `Result`.

const std = @import("std");
const builtin = @import("builtin");

const file_bytes_max = 32 << 10;
const source_bytes_max = 64 << 10;
const notices_max = 1024;
const directory_entries_max = 100_000;
const display_bytes_max = 4 * std.fs.max_path_bytes + 1024;
// The same caps in the unit a message uses, so one constant drives both the
// limit and the sentence that reports it. A host that documents its own
// configuration reads them too, so its document cannot state a stale cap.
pub const file_kibibytes_max = @divExact(file_bytes_max, 1024);
pub const source_kibibytes_max = @divExact(source_bytes_max, 1024);

/// How many files one source can put into the prompt. A caller that builds the
/// path list can size its own buffer against this cap.
pub const files_max = 32;

/// Where a set of instruction files comes from. The value gives the noun that
/// every message about that set uses.
pub const Source = enum {
    user,
    project,

    fn noun(self: Source) []const u8 {
        return switch (self) {
            .user => "user instruction",
            .project => "project instruction",
        };
    }
};

/// One loaded instruction file. The `Result` that holds it owns every slice.
pub const File = struct {
    /// The path Pith read the file through. Messages and the prompt show it.
    path: []const u8,
    content: []const u8,
    /// The canonical path of the file, with every symbolic link resolved. It is
    /// the identity of the file: Pith compares it to recognize one file that two
    /// paths reach, so the same content cannot enter the prompt twice.
    identity: []const u8,

    fn deinit(self: *const File, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.content);
        gpa.free(self.identity);
    }
};

/// One startup message about an instruction file. An empty file is normal
/// housekeeping and carries `.information`. Every other message reports
/// something the user must fix, so it carries `.failure`.
pub const Notice = struct {
    severity: Severity,
    text: []const u8,

    pub const Severity = enum { information, failure };
};

/// Why Pith rejects the content of an instruction file. Each value gives the
/// clause that completes the sentence `Pith skipped ... because {s}.`
const Problem = enum {
    empty,
    too_large,
    contains_nul,
    not_utf8,

    fn severity(self: Problem) Notice.Severity {
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
            .contains_nul => "the file contains a NUL byte",
            .not_utf8 => "the file is not valid UTF-8",
        };
    }
};

/// The outcome of one read. A read error travels as a value, because the caller
/// reports it and continues with the remaining files.
const Content = union(enum) {
    /// The content passed every check. The caller owns the bytes.
    loaded: []u8,
    /// The content broke the shared policy.
    rejected: Problem,
    /// The read failed. The caller reports the name of this error.
    failed: anyerror,
};

/// Read at most `file_bytes_max` bytes from an open instruction file and apply
/// the shared content policy. Only cancellation and an allocation failure stop
/// the caller.
fn readContent(
    gpa: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
) error{ OutOfMemory, Canceled }!Content {
    var file_reader = file.reader(io, &.{});
    const content = file_reader.interface.allocRemaining(
        gpa,
        .limited(file_bytes_max + 1),
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

/// Apply the shared content policy. Null means Pith accepts the content.
fn checkContent(content: []const u8) ?Problem {
    if (content.len == 0) return .empty;
    if (content.len > file_bytes_max) return .too_large;
    if (std.mem.indexOfScalar(u8, content, 0) != null) return .contains_nul;
    if (!std.unicode.utf8ValidateSlice(content)) return .not_utf8;
    return null;
}

/// The instruction files of one source, with the messages the load produced.
/// The result owns every path, every byte of content, and every message.
pub const Result = struct {
    gpa: std.mem.Allocator,
    source: Source,
    project_root_path: ?[]const u8 = null,
    file_items: std.ArrayList(File) = .empty,
    notice_items: std.ArrayList(Notice) = .empty,
    notices_capped: bool = false,
    /// The running byte total, so one source can never push more than
    /// `source_bytes_max` into the prompt.
    bytes_total: usize = 0,

    const TakeOptions = struct {
        /// The path Pith read the file through.
        path: []const u8,
        /// The canonical path of `file`.
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
        for (self.notice_items.items) |notice| self.gpa.free(notice.text);
        self.notice_items.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn projectRoot(self: *const Result) ?[]const u8 {
        return self.project_root_path;
    }

    pub fn files(self: *const Result) []const File {
        return self.file_items.items;
    }

    pub fn notices(self: *const Result) []const Notice {
        return self.notice_items.items;
    }

    /// True when a loaded file already has this canonical path. The loop is
    /// bounded by `files_max`.
    fn holds(self: *const Result, identity: []const u8) bool {
        for (self.file_items.items) |file| {
            if (std.mem.eql(u8, file.identity, identity)) return true;
        }
        return false;
    }

    /// Read one open instruction file, apply the caps, and keep the content.
    /// The caller has checked that the path names a regular file it can use, and
    /// resolved the canonical path of that file. Both sources end here, so both
    /// apply one policy and report one shape.
    fn take(self: *Result, io: std.Io, options: *const TakeOptions) !void {
        const noun = self.source.noun();
        if (self.holds(options.identity)) {
            return self.report(
                .failure,
                "Pith skipped the {s} file {s} because Pith already loaded the same file.",
                .{ noun, options.path },
            );
        }
        const content = switch (try readContent(self.gpa, io, options.file)) {
            .loaded => |loaded| loaded,
            .rejected => |problem| return self.report(
                problem.severity(),
                "Pith skipped the {s} file {s} because {s}.",
                .{ noun, options.path, problem.reason() },
            ),
            .failed => |err| return self.report(
                .failure,
                "Pith could not read the {s} file {s} because of error {s}.",
                .{ noun, options.path, @errorName(err) },
            ),
        };
        errdefer self.gpa.free(content);
        if (self.file_items.items.len == files_max) {
            try self.report(
                .failure,
                "Pith skipped the {s} file {s} because Pith already loaded {d} files.",
                .{ noun, options.path, files_max },
            );
            self.gpa.free(content);
            return;
        }
        // The subtraction cannot underflow, because the total never passes the cap.
        if (content.len > source_bytes_max - self.bytes_total) {
            try self.report(
                .failure,
                "Pith skipped the {s} file {s} to keep the total at or below {d} KiB.",
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
        severity: Notice.Severity,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        if (self.notices_capped) return;
        if (self.notice_items.items.len == notices_max - 1) {
            const text = try self.gpa.dupe(
                u8,
                "Pith omitted the remaining messages about the instruction files.",
            );
            errdefer self.gpa.free(text);
            try self.notice_items.append(self.gpa, .{ .severity = .failure, .text = text });
            self.notices_capped = true;
            return;
        }
        const text = try std.fmt.allocPrint(self.gpa, format, args);
        errdefer self.gpa.free(text);
        try self.notice_items.append(self.gpa, .{ .severity = severity, .text = text });
    }
};

/// The walk from the working directory up to the project boundary. It only ever
/// runs for the project source, so its messages name that source directly.
///
/// Two boundaries guard the walk, and they differ on purpose. The `source_boundary`
/// is the top of the walk: the Git root, or the working directory when Pith found
/// no Git root. A plain instruction file must resolve inside it, so a mount trick
/// cannot pull content in from outside the repository. The `link_boundary` is the
/// Git root, or the working directory alone when there is no Git root. A
/// symbolic-link target must resolve inside it. The two differ when Pith cannot
/// read a repository marker: the walk then stops at that ancestor and still
/// scans it, but only the working directory stays trusted for a link target.
const Discovery = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
    result: *Result,

    /// The noun of the only source this walk serves, spliced into every message
    /// at compile time.
    const noun = Source.noun(.project);

    const Boundary = struct {
        path: []const u8,
        has_project_root: bool,
    };

    const ScanOptions = struct {
        directory: []const u8,
        /// The top of the walk. A plain instruction file must resolve inside it.
        source_boundary: []const u8,
        /// The boundary a symbolic-link target must resolve inside.
        link_boundary: []const u8,
    };

    const CandidateOptions = struct {
        source_path: []const u8,
        /// See `ScanOptions.source_boundary`.
        source_boundary: []const u8,
        /// See `ScanOptions.link_boundary`.
        link_boundary: []const u8,
    };

    const OpenOptions = struct {
        source_path: []const u8,
        /// The boundary that applies to this candidate: the source boundary for
        /// a plain file, the link boundary for a symbolic link.
        content_boundary: []const u8,
        follow_symlinks: bool,
        was_symlink: bool,
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
        std.mem.reverse(File, self.result.file_items.items);
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
                try self.result.report(
                    .failure,
                    "Pith could not inspect the repository marker {s} because of error {s}.",
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
            try self.result.report(
                .failure,
                "Pith could not scan the directory {s} for AGENTS.md because of error {s}.",
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
                    "Pith stopped the scan for AGENTS.md in {s} because of error {s}.",
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
                    "Pith stopped the scan for AGENTS.md in {s} after {d} entries.",
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
            if (try self.isRegularFile(path)) try self.result.report(
                .failure,
                "Pith ignored the CLAUDE.md file {s}. Add or link a project instruction file " ++
                    "named AGENTS.md in the same directory.",
                .{path},
            );
        }
        if (agent_present) {
            const path = try std.fs.path.join(self.gpa, &.{ options.directory, "AGENT.md" });
            defer self.gpa.free(path);
            if (try self.isRegularFile(path)) try self.result.report(
                .failure,
                "Pith ignored the AGENT.md file {s}. Rename the file to AGENTS.md if the file " ++
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
        if (!std.unicode.utf8ValidateSlice(options.source_path)) {
            const safe_path = try diagnosticAlloc(self.gpa, options.source_path);
            defer self.gpa.free(safe_path);
            try self.result.report(
                .failure,
                "Pith skipped the " ++ noun ++ " path {s} because the path is not valid UTF-8.",
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
            try self.result.report(
                .failure,
                "Pith could not inspect the " ++ noun ++ " path {s} because of error {s}.",
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
                            "Pith skipped the " ++ noun ++ " file {s} because the symbolic-link " ++
                                "target does not exist.",
                            .{options.source_path},
                        );
                    } else {
                        try self.result.report(
                            .failure,
                            "Pith could not inspect the symbolic-link target of the " ++ noun ++
                                " file {s} because of error {s}.",
                            .{ options.source_path, @errorName(err) },
                        );
                    }
                    return;
                };
                if (target_stat.kind != .file) {
                    try self.result.report(
                        .failure,
                        "Pith skipped the " ++ noun ++ " file {s} because the symbolic-link " ++
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
                "Pith skipped the " ++ noun ++ " path {s} because the path is not a regular file.",
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
                    "Pith skipped the " ++ noun ++ " file {s} because the symbolic-link target " ++
                        "does not exist.",
                    .{options.source_path},
                );
            } else {
                try self.result.report(
                    .failure,
                    "Pith could not open the " ++ noun ++ " file {s} because of error {s}.",
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
                "Pith could not inspect the open " ++ noun ++ " file {s} because of error {s}.",
                .{ options.source_path, @errorName(err) },
            );
            return;
        };
        if (stat.kind != .file) {
            try self.result.report(
                .failure,
                "Pith skipped the " ++ noun ++ " path {s} because the path is not a regular file.",
                .{options.source_path},
            );
            return;
        }

        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target_length = file.realPath(self.io, &target_buffer) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.result.report(
                .failure,
                "Pith could not resolve the " ++ noun ++ " file {s} because of error {s}.",
                .{ options.source_path, @errorName(err) },
            );
            return;
        };
        const target = target_buffer[0..target_length];
        if (!pathWithin(&.{ .boundary = options.content_boundary, .target = target })) {
            try self.result.report(
                .failure,
                "Pith skipped the " ++ noun ++ " file {s} because the file resolves outside " ++
                    "the project boundary.",
                .{options.source_path},
            );
            return;
        }
        // The canonical path is already resolved, so it also serves as the
        // identity that keeps one file out of the prompt twice.
        try self.result.take(self.io, &.{
            .path = options.source_path,
            .identity = target,
            .file = file,
        });
    }
};

/// Discover the project instructions for an absolute, canonical working
/// directory. The returned result owns all files, paths, and messages.
pub fn discover(
    gpa: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
) !Result {
    if (!std.fs.path.isAbsolute(working_directory)) return error.WorkingDirectoryNotAbsolute;
    if (!std.unicode.utf8ValidateSlice(working_directory)) return error.WorkingDirectoryNotUtf8;

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

pub const LoadOptions = struct {
    /// The absolute directory that a relative configured path resolves against.
    directory: []const u8,
    /// The configured paths, in the order the prompt keeps them. Pith inspects
    /// at most `files_max` of them. One entry past that cap is enough to make
    /// Pith report the rest, so a caller can cut the list at `files_max + 1`
    /// and still lose no message.
    paths: []const []const u8,
};

/// Load the configured user instruction files. Pith inspects at most `files_max`
/// entries and reports the rest. A path Pith cannot use becomes a message, so a
/// bad entry never stops the load. The returned result owns everything it holds.
pub fn load(gpa: std.mem.Allocator, io: std.Io, options: *const LoadOptions) !Result {
    if (!std.fs.path.isAbsolute(options.directory)) return error.DirectoryNotAbsolute;

    var result = Result.init(gpa, .user);
    errdefer result.deinit();
    for (options.paths, 0..) |configured, index| {
        if (index == files_max) {
            try result.report(
                .failure,
                "Pith skipped the remaining {s} files because Pith already inspected {d} " ++
                    "entries.",
                .{ result.source.noun(), files_max },
            );
            break;
        }
        // A relative path resolves against the configured directory, so
        // `~/.pith/` holds the common case.
        const path = try std.fs.path.resolve(gpa, &.{ options.directory, configured });
        defer gpa.free(path);
        try loadPath(&result, io, path);
    }
    return result;
}

/// Inspect and read one resolved configured path.
fn loadPath(result: *Result, io: std.Io, path: []const u8) !void {
    const noun = result.source.noun();
    const cwd = std.Io.Dir.cwd();
    // The stat before the open reports a directory the same way on every
    // platform, because an open of a directory fails on Linux but works on macOS.
    const stat = cwd.statFile(io, path, .{}) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        if (err == error.FileNotFound) {
            return result.report(
                .failure,
                "Pith skipped the {s} path {s} because the path does not exist.",
                .{ noun, path },
            );
        }
        return result.report(
            .failure,
            "Pith could not inspect the {s} path {s} because of error {s}.",
            .{ noun, path, @errorName(err) },
        );
    };
    if (stat.kind != .file) {
        return result.report(
            .failure,
            "Pith skipped the {s} path {s} because the path is not a regular file.",
            .{ noun, path },
        );
    }
    const file = cwd.openFile(io, path, .{ .allow_directory = false }) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return result.report(
            .failure,
            "Pith could not open the {s} file {s} because of error {s}.",
            .{ noun, path, @errorName(err) },
        );
    };
    defer file.close(io);
    // The canonical path is the identity of the file, so two configured paths
    // that reach one file through a symbolic link load it once.
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const target_length = file.realPath(io, &target_buffer) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return result.report(
            .failure,
            "Pith could not resolve the {s} file {s} because of error {s}.",
            .{ noun, path, @errorName(err) },
        );
    };
    try result.take(io, &.{
        .path = path,
        .identity = target_buffer[0..target_length],
        .file = file,
    });
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
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqualStrings("broad", result.files()[0].content);
    try std.testing.expectEqualStrings("specific", result.files()[1].content);
    try std.testing.expect(std.mem.endsWith(u8, result.files()[0].path, "repo/AGENTS.md"));
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
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 2), result.notices().len);
    try std.testing.expect(std.mem.indexOf(u8, result.notices()[0].text, "CLAUDE.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.notices()[1].text, "AGENT.md") != null);
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
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 1), result.notices().len);
    try std.testing.expect(
        std.mem.indexOf(u8, result.notices()[0].text, "is not a regular file") != null,
    );
}

test "invalid, oversized, and empty files are skipped and reported" {
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
    try std.testing.expectEqual(@as(usize, 1), result.files().len);
    try std.testing.expectEqual(@as(usize, file_bytes_max), result.files()[0].content.len);
    try std.testing.expectEqual(@as(usize, 4), result.notices().len);
    // An empty file is housekeeping, not a failure, so it reads as information.
    var empty_found = false;
    var oversized_found = false;
    var null_byte_found = false;
    var utf8_found = false;
    for (result.notices()) |notice| {
        if (std.mem.indexOf(u8, notice.text, "is empty") != null) {
            empty_found = true;
            try std.testing.expectEqual(Notice.Severity.information, notice.severity);
            continue;
        }
        try std.testing.expectEqual(Notice.Severity.failure, notice.severity);
        if (std.mem.indexOf(u8, notice.text, "larger than 32 KiB") != null) oversized_found = true;
        if (std.mem.indexOf(u8, notice.text, "NUL byte") != null) null_byte_found = true;
        if (std.mem.indexOf(u8, notice.text, "not valid UTF-8") != null) utf8_found = true;
    }
    try std.testing.expect(empty_found);
    try std.testing.expect(oversized_found);
    try std.testing.expect(null_byte_found);
    try std.testing.expect(utf8_found);
}

test "instruction messages are bounded" {
    const gpa = std.testing.allocator;
    var result = Result.init(gpa, .project);
    defer result.deinit();

    for (0..notices_max + 8) |index| try result.report(.failure, "message {d}", .{index});

    try std.testing.expectEqual(@as(usize, notices_max), result.notices().len);
    try std.testing.expectEqualStrings(
        "Pith omitted the remaining messages about the instruction files.",
        result.notices()[notices_max - 1].text,
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
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqual(@as(u8, 'a'), result.files()[0].content[0]);
    try std.testing.expectEqual(@as(u8, 'b'), result.files()[1].content[0]);
    try std.testing.expectEqual(@as(usize, 1), result.notices().len);
    try std.testing.expect(std.mem.indexOf(u8, result.notices()[0].text, "64 KiB") != null);
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
    for (0..files_max) |index| {
        try relative.writer.print("/d{d:0>2}", .{index});
        const path = try std.fmt.allocPrint(gpa, "{s}/AGENTS.md", .{relative.written()});
        defer gpa.free(path);
        try writeTestFile(io, tmp.dir, &.{ .path = path, .data = "nested" });
    }
    const working_directory = try tmpPath(gpa, io, &tmp, relative.written());
    defer gpa.free(working_directory);

    var result = try discover(gpa, io, working_directory);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, files_max), result.files().len);
    try std.testing.expect(std.mem.endsWith(u8, result.files()[0].path, "d00/AGENTS.md"));
    try std.testing.expect(
        std.mem.endsWith(u8, result.files()[files_max - 1].path, "d31/AGENTS.md"),
    );
    try std.testing.expectEqual(@as(usize, 1), result.notices().len);
}

test "instruction symlinks stay inside the project and load one file once" {
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
    // Both `a/b` and `a/b/c` link to one shared file. The scan runs from the
    // working directory upwards, so the nearest path keeps it and the broader
    // one reports the repeat.
    try std.testing.expectEqual(@as(usize, 1), result.files().len);
    try std.testing.expectEqualStrings("linked", result.files()[0].content);
    try std.testing.expect(std.mem.endsWith(u8, result.files()[0].path, "a/b/c/AGENTS.md"));
    try std.testing.expectEqual(@as(usize, 4), result.notices().len);
    var repeat_found = false;
    for (result.notices()) |notice| {
        if (std.mem.indexOf(u8, notice.text, "already loaded the same file") == null) continue;
        repeat_found = true;
        try std.testing.expect(std.mem.indexOf(u8, notice.text, "a/b/AGENTS.md") != null);
    }
    try std.testing.expect(repeat_found);
}

test "unreadable instruction files are reported and do not load" {
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
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 1), result.notices().len);
    try std.testing.expect(std.mem.indexOf(u8, result.notices()[0].text, "could not open") != null);
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
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 2), result.notices().len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.notices()[0].text,
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

test "configured files load in order and one file loads once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(io, tmp.dir, &.{ .path = "first.md", .data = "First.\n" });
    try writeTestFile(io, tmp.dir, &.{ .path = "nested/second.md", .data = "Second.\n" });
    const directory = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(directory);
    const absolute_first = try tmpPath(gpa, io, &tmp, "first.md");
    defer gpa.free(absolute_first);
    // A relative repeat, an absolute repeat, and a symbolic link all name the
    // file that `first.md` already loaded. The identity is the canonical path,
    // so none of the three reaches the prompt a second time.
    tmp.dir.symLink(io, absolute_first, "link.md", .{}) catch |err| switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.ReadOnlyFileSystem,
        => return error.SkipZigTest,
        else => return err,
    };

    var result = try load(gpa, io, &.{
        .directory = directory,
        .paths = &.{ "nested/second.md", "first.md", "./first.md", absolute_first, "link.md" },
    });
    defer result.deinit();
    try std.testing.expect(result.projectRoot() == null);
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqualStrings("Second.\n", result.files()[0].content);
    try std.testing.expectEqualStrings("First.\n", result.files()[1].content);
    // A relative configured path resolves against the configured directory.
    try std.testing.expectEqualStrings(absolute_first, result.files()[1].path);
    try std.testing.expectEqual(@as(usize, 3), result.notices().len);
    for (result.notices()) |notice| {
        try std.testing.expectEqual(Notice.Severity.failure, notice.severity);
        try std.testing.expect(
            std.mem.indexOf(u8, notice.text, "already loaded the same file") != null,
        );
    }
}

test "a configured list stops after the file cap and reports the rest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }
    for (0..files_max + 1) |index| {
        const name = try std.fmt.allocPrint(gpa, "f{d:0>2}.md", .{index});
        errdefer gpa.free(name);
        try writeTestFile(io, tmp.dir, &.{ .path = name, .data = "Instructions.\n" });
        try paths.append(gpa, name);
    }
    const directory = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(directory);

    var result = try load(gpa, io, &.{ .directory = directory, .paths = paths.items });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, files_max), result.files().len);
    try std.testing.expectEqual(@as(usize, 1), result.notices().len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.notices()[0].text,
        "skipped the remaining user instruction files",
    ) != null);
}

test "configured files stop at the shared byte budget" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(io, tmp.dir, &.{ .path = "a.md", .data = "a" ** (24 << 10) });
    try writeTestFile(io, tmp.dir, &.{ .path = "b.md", .data = "b" ** (24 << 10) });
    try writeTestFile(io, tmp.dir, &.{ .path = "c.md", .data = "c" ** (24 << 10) });
    const directory = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(directory);

    // Two 24 KiB files fit. The third would pass 64 KiB, so Pith keeps the
    // earlier files and reports the one it dropped.
    var result = try load(gpa, io, &.{
        .directory = directory,
        .paths = &.{ "a.md", "b.md", "c.md" },
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.files().len);
    try std.testing.expectEqual(@as(u8, 'a'), result.files()[0].content[0]);
    try std.testing.expectEqual(@as(u8, 'b'), result.files()[1].content[0]);
    try std.testing.expectEqual(@as(usize, 1), result.notices().len);
    try std.testing.expect(std.mem.indexOf(u8, result.notices()[0].text, "64 KiB") != null);
}

test "an unusable configured path is skipped and reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeTestDir(io, tmp.dir, "directory");
    try writeTestFile(io, tmp.dir, &.{ .path = "empty.md", .data = "" });
    try writeTestFile(io, tmp.dir, &.{ .path = "nul.md", .data = "nul\x00text" });
    try writeTestFile(io, tmp.dir, &.{ .path = "bad.md", .data = "bad\xfftext" });
    try writeTestFile(io, tmp.dir, &.{ .path = "exact.md", .data = "e" ** file_bytes_max });
    try writeTestFile(io, tmp.dir, &.{
        .path = "oversized.md",
        .data = "o" ** (file_bytes_max + 1),
    });
    const directory = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(directory);

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
    try std.testing.expectEqual(@as(usize, 6), result.notices().len);
    const expected_reasons = [_][]const u8{
        "the path does not exist",
        "the path is not a regular file",
        "the file is empty",
        "the file contains a NUL byte",
        "the file is not valid UTF-8",
        "the file is larger than 32 KiB",
    };
    for (expected_reasons, result.notices()) |reason, notice| {
        try std.testing.expect(std.mem.indexOf(u8, notice.text, reason) != null);
        try std.testing.expect(
            std.mem.indexOf(u8, notice.text, "the user instruction ") != null,
        );
    }
    try std.testing.expectEqual(Notice.Severity.information, result.notices()[2].severity);
}

test "an unreadable configured file is skipped and reported" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(io, tmp.dir, &.{ .path = "hidden.md", .data = "hidden" });
    try tmp.dir.setFilePermissions(io, "hidden.md", .fromMode(0), .{});
    defer tmp.dir.setFilePermissions(io, "hidden.md", .fromMode(0o600), .{}) catch {};
    const directory = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(directory);
    const source_path = try tmpPath(gpa, io, &tmp, "hidden.md");
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

    var result = try load(gpa, io, &.{ .directory = directory, .paths = &.{"hidden.md"} });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.files().len);
    try std.testing.expectEqual(@as(usize, 1), result.notices().len);
    try std.testing.expect(std.mem.indexOf(u8, result.notices()[0].text, "could not open") != null);
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
    try std.testing.expectEqual(@as(usize, 3), result.notices().len);
}

test "the configured load frees every partial allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(io, tmp.dir, &.{ .path = "first.md", .data = "First.\n" });
    try writeTestFile(io, tmp.dir, &.{ .path = "second.md", .data = "Second.\n" });
    try writeTestFile(io, tmp.dir, &.{ .path = "empty.md", .data = "" });
    const directory = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(directory);

    try std.testing.checkAllAllocationFailures(
        gpa,
        checkLoadAllocationFailure,
        .{ io, directory },
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

    try std.testing.expectError(
        error.DirectoryNotAbsolute,
        load(gpa, undefined, &.{ .directory = "relative", .paths = &.{} }),
    );

    var result = Result.init(gpa, .project);
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
    try std.testing.expectEqual(@as(usize, 1), result.notices().len);
    const text = result.notices()[0].text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\\xc2\\x9b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\xe2\\x80\\xae") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\xff") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0xff) == null);

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
