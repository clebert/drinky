const std = @import("std");

const core = @import("core");

const Context = @import("Context.zig");
const format = @import("format.zig");
const output = @import("output.zig");
const parse = @import("parse.zig");
const search = @import("search.zig");
const testing = @import("testing.zig");
const walk = @import("walk.zig");

const limit_default = 100;
const file_bytes_max = 4 << 20;
const line_bytes_max = 300;
const files_max = 100_000;

pub const spec: core.Tool = .{
    .name = "grep",
    .description = "Search the content of files for a literal substring, not a regular " ++
        "expression. Use this tool for a literal search in place of a grep or rg command in " ++
        "bash. The output shows each line that matches as 'path:line:text', and each path " ++
        "starts with the search path. " ++ walk.noise_note ++ " " ++ search.timeoutNote("glob"),
    .parameters = &.{
        .{
            .name = "pattern",
            .type = .string,
            .required = true,
            .description = "Literal substring to search for",
        },
        .{
            .name = "path",
            .type = .string,
            .description = "Directory to search, or a single file to search directly " ++
                "(default: '.')",
        },
        .{
            .name = "glob",
            .type = .string,
            .description = "Glob that the path of a file below the search directory must " ++
                "match (default: all files). The wildcards * and ? never cross '/', so use a " ++
                "'**/' prefix to recurse. The glob has no effect when the path names a single " ++
                "file.",
        },
        .{
            .name = "ignore_case",
            .type = .boolean,
            .description = "Case-insensitive search (default: false)",
        },
        .{
            .name = "limit",
            .type = .integer,
            .description = std.fmt.comptimePrint(
                "Maximum number of lines that match (default: {d})",
                .{limit_default},
            ),
        },
    },
};

const Input = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    glob: []const u8 = "**",
    ignore_case: bool = false,
    limit: usize = limit_default,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) Context.Error!core.Tool.Output {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    if (parsed.value.pattern.len == 0)
        return output.failure(gpa, .invalid_arguments, "Enter a nonempty pattern.", .{});
    if (parsed.value.limit == 0)
        return output.failure(gpa, .invalid_arguments, "Set limit to 1 or more.", .{});
    const input = &parsed.value;
    const io = context.host.io;
    const timer: search.Timer = .start(io);
    const pattern = input.pattern;
    const base = if (input.path.len == 0) "." else input.path;
    const limit = input.limit;
    const bytes_read_max = context.host.search.bytes_read_max;

    var state: Search = .{
        .input = input,
        .base = base,
        .bytes_read_max = bytes_read_max,
        .collector = .init(&.{
            .base = base,
            .pattern = input.glob,
            .retain = files_max,
            .entries_max = context.host.search.entries_max,
        }),
        .out = .init(gpa),
    };
    defer state.deinit(gpa);
    var timed_out = false;
    context.deadline.run(io, Search.run, .{ &state, io, gpa }, null) catch |err|
        switch (err) {
            error.Timeout => timed_out = true,
            error.Canceled, error.OutOfMemory, error.WriteFailed => |known| return known,
            else => |failure| return output.cannot(gpa, failure, "search", base),
        };
    if (timed_out and !state.collector.opened) return search.unanswered(gpa, base);
    if (timed_out and state.maybe_match == null) {
        state.collector.stop = .time;
        state.maybe_match = try state.collector.match(gpa);
    }
    var files_incomplete = false;
    var entries_unread = state.files_unread;
    if (state.maybe_match) |*match| {
        files_incomplete = match.stop == .entries or match.matched > match.paths.len;
        entries_unread += match.entries_unread;
    }
    const out = &state.out;
    const count = state.count;
    const line_capped = state.line_capped;
    const bytes_capped = state.bytes_capped;
    const files_oversized = state.files_oversized;

    const elapsed_ms = timer.elapsedMs();
    var elapsed_buffer: [24]u8 = undefined;
    const elapsed = format.duration(&elapsed_buffer, elapsed_ms);
    const files_unsearched = files_incomplete and !timed_out and !line_capped and !bytes_capped;
    if (count == 0) {
        if (timed_out) {
            try out.writer.print(
                "Drinky found no matches for {s} in the part that Drinky searched. Drinky " ++
                    "stopped the search after {s}. Use a narrower path or glob.",
                .{ pattern, elapsed },
            );
        } else if (bytes_capped or files_incomplete) {
            try out.writer.print(
                "Drinky found no matches for {s} in the part that Drinky searched. " ++
                    "Use a narrower path or glob because the search was incomplete.",
                .{pattern},
            );
        } else if (files_oversized > 0 or entries_unread > 0) {
            try out.writer.print(
                "Drinky found no matches for {s} in the part that Drinky searched.",
                .{pattern},
            );
        } else {
            try out.writer.print("Drinky found no matches for {s}.", .{pattern});
        }
        if (files_oversized > 0) {
            try out.writer.writeAll(" ");
            try writeOversized(&out.writer, files_oversized);
        }
        if (entries_unread > 0) {
            try out.writer.writeAll(" ");
            try walk.writeUnread(&out.writer, entries_unread);
        }
        if (state.maybe_match) |*match| try match.skipped_noise.writeNotice(&out.writer);
    } else {
        if (timed_out) try out.writer.print(
            "\n[Drinky stopped the search after {s}. Drinky shows the matches that it found. " ++
                "Use a narrower path or glob.]",
            .{elapsed},
        );
        if (line_capped) try out.writer.print(
            "\n[Drinky stopped after {d} {s}. Refine the search or increase limit.]",
            .{ limit, search.matchNoun(limit) },
        );
        if (bytes_capped) try out.writer.print(
            "\n[Drinky stopped after Drinky read {d} MiB. Refine the search or use a narrower " ++
                "path or glob.]",
            .{bytes_read_max >> 20},
        );
        if (files_unsearched) try out.writer.writeAll(
            "\n[Drinky could not scan the full file tree. Drinky did not search some files.]",
        );
        if (files_oversized > 0) {
            try out.writer.writeAll("\n[");
            try writeOversized(&out.writer, files_oversized);
            try out.writer.writeAll("]");
        }
        if (entries_unread > 0) {
            try out.writer.writeAll("\n[");
            try walk.writeUnread(&out.writer, entries_unread);
            try out.writer.writeAll("]");
        }
    }

    var result: core.Tool.Output = .{ .content = try out.toOwnedSlice() };
    result.measures.put(.duration_ms, @intCast(@max(elapsed_ms, 0)));
    result.measures.put(.matches, count);
    if (entries_unread > 0) result.measures.put(.entries_unread, entries_unread);
    if (files_oversized > 0) result.measures.put(.files_oversized, files_oversized);
    if (timed_out) result.conditions.insert(.time_limit_reached);
    if (files_unsearched) result.conditions.insert(.tree_limit_reached);
    if (line_capped) result.conditions.insert(.match_limit_reached);
    if (bytes_capped) result.conditions.insert(.byte_limit_reached);
    if (files_oversized > 0 or entries_unread > 0) result.conditions.insert(.incomplete);
    if (state.lines_truncated) result.conditions.insert(.lines_truncated);
    return result;
}

const Search = struct {
    input: *const Input,
    base: []const u8,
    bytes_read_max: usize,
    collector: walk.Collector,
    maybe_match: ?walk.Match = null,
    out: std.Io.Writer.Allocating,
    count: usize = 0,
    line_capped: bool = false,
    lines_truncated: bool = false,
    bytes_read: usize = 0,
    bytes_capped: bool = false,
    files_oversized: usize = 0,
    files_unread: usize = 0,

    const Error = walk.Collector.Error || error{WriteFailed};

    fn deinit(self: *Search, gpa: std.mem.Allocator) void {
        if (self.maybe_match) |*match| match.deinit(gpa);
        self.collector.deinit(gpa);
        self.out.deinit();
    }

    fn run(self: *Search, io: std.Io, gpa: std.mem.Allocator) Error!void {
        const single_file: [1][]const u8 = .{self.base};
        var paths: []const []const u8 = &single_file;
        if (self.collector.run(io, gpa)) {
            self.maybe_match = try self.collector.match(gpa);
            paths = self.maybe_match.?.paths;
        } else |err| switch (err) {
            error.NotDir => {},
            else => |failure| return failure,
        }
        for (paths) |path| {
            if (self.bytes_read >= self.bytes_read_max) {
                self.bytes_capped = true;
                return;
            }
            try self.searchFile(io, gpa, path);
            if (self.line_capped) return;
        }
    }

    fn searchFile(self: *Search, io: std.Io, gpa: std.mem.Allocator, path: []const u8) Error!void {
        const cwd = std.Io.Dir.cwd();
        const data = cwd.readFileAlloc(io, path, gpa, .limited(file_bytes_max)) catch |err|
            switch (err) {
                error.Canceled, error.OutOfMemory => |known| return known,
                error.StreamTooLong => {
                    self.bytes_read += file_bytes_max;
                    self.files_oversized += 1;
                    return;
                },
                else => {
                    self.files_unread += 1;
                    return;
                },
            };
        defer gpa.free(data);
        self.bytes_read += data.len;
        if (std.mem.findScalar(u8, data, 0) != null) return;

        const input = self.input;
        const writer = &self.out.writer;
        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            line_number += 1;
            const hit = if (input.ignore_case)
                std.ascii.findIgnoreCase(line, input.pattern)
            else
                std.mem.find(u8, line, input.pattern);
            if (hit == null) continue;
            if (self.count == input.limit) {
                self.line_capped = true;
                return;
            }
            const shown = format.truncate(line, line_bytes_max);
            if (shown.len < line.len) self.lines_truncated = true;
            if (self.count > 0) try writer.writeAll("\n");
            try writer.print("{f}:{d}:{f}", .{
                std.unicode.fmtUtf8(path),
                line_number,
                std.unicode.fmtUtf8(shown),
            });
            self.count += 1;
        }
    }
};

fn writeOversized(writer: *std.Io.Writer, files_oversized: usize) !void {
    try writer.print("Drinky did not search {d} file{s} larger than {d} MiB.", .{
        files_oversized,
        core.text.pluralSuffix(files_oversized),
        file_bytes_max >> 20,
    });
}

test "grep finds a literal substring with a glob filter" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "nope\nneedle here\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "needle here\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}","glob":"**/*.zig"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/a.zig:2:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try expectMatches(&result, 1);
    try testing.expectConditions(&result, &.{});
}

fn expectMatches(result: *const core.Tool.Output, matches: u64) !void {
    try testing.expectTimed(result, &.{.{ .matches, matches }});
}

test "grep searches a single file given as the path" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "nope\nneedle here\n" });
    var input_buffer: [160]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}/a.zig"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/a.zig:2:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
}

test "grep ignores the glob when the path is a single file" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "needle here\n" });
    var input_buffer: [192]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}/a.zig","glob":"**/*.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/a.zig:1:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
}

fn runIn(context: *const Context, comptime input: []const u8, base: []const u8) !core.Tool.Output {
    var buffer: [256]u8 = undefined;
    return run(context, try std.mem.print(&buffer, input, .{base}));
}

test "grep treats an empty path as the working directory" {
    const gpa = std.testing.allocator;
    var stall: testing.StallIo = undefined;
    stall.init(gpa, .{ .open_directory = "." });
    defer stall.deinit();
    const context: Context = .{
        .sink = testing.discard_sink,

        .gpa = gpa,
        .host = .{ .io = stall.io() },
        .deadline = .start(stall.io(), search.timeout_ms),
    };
    const result = try run(&context,
        \\{"pattern":"needle","path":""}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings(
        "Drinky could not search . because the file system did not respond within 10 seconds.",
        result.content,
    );
    try std.testing.expect(stall.canceled.load(.acquire));
}

test "grep rejects an empty pattern" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    const result = try run(&context,
        \\{"pattern":""}
    );
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.invalid_arguments});
    try testing.expectMeasures(&result, &.{});
}

test "grep replaces invalid UTF-8 in matched lines" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "latin1.txt", .data = "caf\xE9 latte\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"caf","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});

    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = std.testing.allocator,
        .host = .{ .io = io },
    };
    const result = try run(&context, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.content));
    try std.testing.expect(
        std.mem.find(u8, result.content, "latin1.txt:1:caf\u{FFFD} latte") != null,
    );
}

test "grep is case-insensitive when asked" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "Needle Here\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"NEEDLE","path":".zig-cache/tmp/{s}","ignore_case":true}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(std.mem.find(u8, result.content, "a.txt:1:Needle Here") != null);
}

test "grep stops at the result limit and reports it" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "f.txt",
        .data = "hit one\nhit two\nhit three\n",
    });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}","limit":2}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/f.txt:1:hit one\n.zig-cache/tmp/{s}/f.txt:2:hit two\n" ++
            "[Drinky stopped after 2 matches. Refine the search or increase limit.]",
        .{ tmp.sub_path, tmp.sub_path },
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try expectMatches(&result, 2);
    try testing.expectConditions(&result, &.{.match_limit_reached});
}

test "grep skips binary and oversized files" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bin.dat", .data = "hit\x00\n" });
    const big = try gpa.alloc(u8, file_bytes_max + 1);
    defer gpa.free(big);
    @memset(big, 'a');
    @memcpy(big[0..3], "hit");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "huge.txt", .data = big });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small.txt", .data = "hit\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/small.txt:1:hit\n" ++
            "[Drinky did not search 1 file larger than 4 MiB.]",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try testing.expectConditions(&result, &.{.incomplete});
}

test "grep finds no match in an oversized file and names the file it did not search" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big = try gpa.alloc(u8, file_bytes_max + 1);
    defer gpa.free(big);
    @memset(big, 'a');
    @memcpy(big[0..3], "hit");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "huge.txt", .data = big });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}/huge.txt"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings(
        "Drinky found no matches for hit in the part that Drinky searched. " ++
            "Drinky did not search 1 file larger than 4 MiB.",
        result.content,
    );
    try testing.expectTimed(&result, &.{ .{ .matches, 0 }, .{ .files_oversized, 1 } });
    try testing.expectConditions(&result, &.{.incomplete});
}

test "grep marks a search incomplete when it cannot read a file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hit\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "locked.txt", .data = "hit\n" });
    try tmp.dir.setFilePermissions(io, "locked.txt", .fromMode(0), .{});
    var input_buffer: [160]u8 = undefined;

    const found_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const found = try run(&context, found_input);
    defer found.deinit(gpa);
    try std.testing.expect(!found.hasFailure());
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/a.txt:1:hit\n[Drinky could not read 1 entry.]",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, found.content);
    try testing.expectTimed(&found, &.{ .{ .matches, 1 }, .{ .entries_unread, 1 } });
    try testing.expectConditions(&found, &.{.incomplete});

    const single_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}/locked.txt"}}
    , .{tmp.sub_path});
    const single = try run(&context, single_input);
    defer single.deinit(gpa);
    try std.testing.expect(!single.hasFailure());
    try std.testing.expectEqualStrings(
        "Drinky found no matches for hit in the part that Drinky searched. " ++
            "Drinky could not read 1 entry.",
        single.content,
    );
    try testing.expectTimed(&single, &.{ .{ .matches, 0 }, .{ .entries_unread, 1 } });
    try testing.expectConditions(&single, &.{.incomplete});
}

test "grep stops at the byte cap and states it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,

        .gpa = gpa,
        .host = .{ .io = io, .search = .{ .bytes_read_max = 1 << 20 } },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(data);
    @memset(data, 'a');
    @memcpy(data[0..4], "hit\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = data });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = data });
    var input_buffer: [128]u8 = undefined;

    const found_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const found = try run(&context, found_input);
    defer found.deinit(gpa);
    try std.testing.expect(!found.hasFailure());
    var expected_buffer: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/a.txt:1:hit\n[Drinky stopped after Drinky read 1 MiB. Refine the " ++
            "search or use a narrower path or glob.]",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, found.content);
    try expectMatches(&found, 1);
    try testing.expectConditions(&found, &.{.byte_limit_reached});

    const missed_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"miss","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const missed = try run(&context, missed_input);
    defer missed.deinit(gpa);
    try std.testing.expectEqualStrings(
        "Drinky found no matches for miss in the part that Drinky searched. Use a narrower " ++
            "path or glob because the search was incomplete.",
        missed.content,
    );
    try expectMatches(&missed, 0);
    try testing.expectConditions(&missed, &.{.byte_limit_reached});
}

test "grep states a file tree that is too large to scan" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,

        .gpa = gpa,
        .host = .{ .io = io, .search = .{ .entries_max = 2 } },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "hit\n" });
    }
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const result = try runIn(&context, "{{\"pattern\":\"hit\",\"path\":\"{s}\"}}", base);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectStringEndsWith(
        result.content,
        ".txt:1:hit\n[Drinky could not scan the full file tree. Drinky did not search some files.]",
    );
    try expectMatches(&result, 2);
    try testing.expectConditions(&result, &.{.tree_limit_reached});
}

test "grep caps the reported line length" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "hit" ++ core.text.repeat("a", 397);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = line ++ "\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [512]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/long.txt:1:{s}",
        .{ tmp.sub_path, line[0..line_bytes_max] },
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try expectMatches(&result, 1);
    try testing.expectConditions(&result, &.{.lines_truncated});
}

test "grep refuses a zero limit" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    const result = try run(&context,
        \\{"pattern":"hit","limit":0}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("Set limit to 1 or more.", result.content);
    try testing.expectConditions(&result, &.{.invalid_arguments});
    try testing.expectMeasures(&result, &.{});
}

test "grep reports no matches of a complete search" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = std.testing.io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "hit\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"miss","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("Drinky found no matches for miss.", result.content);
    try expectMatches(&result, 0);
    try testing.expectConditions(&result, &.{});
}

test "grep reports skipped noise after an empty search" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = io },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dependency = try tmp.dir.createDirPathOpen(io, "node_modules/pkg", .{});
    defer dependency.close(io);
    try dependency.writeFile(io, .{ .sub_path = "ignored.txt", .data = "needle\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);

    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings(
        "Drinky found no matches for needle. Drinky skipped these noise directories: " ++
            "`node_modules`. Set the path to a skipped directory to search that directory fully.",
        result.content,
    );
    try expectMatches(&result, 0);
}

test "grep reports a search that ran out of time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stall: testing.StallIo = undefined;
    stall.init(gpa, .{ .open_file = "b.txt" });
    defer stall.deinit();
    const context: Context = .{
        .sink = testing.discard_sink,

        .gpa = gpa,
        .host = .{ .io = stall.io() },
        .deadline = .start(stall.io(), search.timeout_ms),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "nope\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "nope\n" });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const result = try runIn(&context, "{{\"pattern\":\"hit\",\"path\":\"{s}\"}}", base);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectStringStartsWith(
        result.content,
        "Drinky found no matches for hit in the part that Drinky searched. Drinky stopped the " ++
            "search after ",
    );
    try expectMatches(&result, 0);
    try testing.expectConditions(&result, &.{.time_limit_reached});
    try std.testing.expect(stall.canceled.load(.acquire));
}

test "grep keeps the matches it found before the time limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stall: testing.StallIo = undefined;
    stall.init(gpa, .{ .open_file = "b.txt" });
    defer stall.deinit();
    const context: Context = .{
        .sink = testing.discard_sink,

        .gpa = gpa,
        .host = .{ .io = stall.io() },
        .deadline = .start(stall.io(), search.timeout_ms),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hit\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "hit\n" });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const result = try runIn(&context, "{{\"pattern\":\"hit\",\"path\":\"{s}\"}}", base);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        "{s}/a.txt:1:hit\n[Drinky stopped the search after ",
        .{base},
    );
    try std.testing.expectStringStartsWith(result.content, expected);
    try std.testing.expectStringEndsWith(
        result.content,
        ". Drinky shows the matches that it found. Use a narrower path or glob.]",
    );
    try expectMatches(&result, 1);
    try testing.expectConditions(&result, &.{.time_limit_reached});
    try std.testing.expect(stall.canceled.load(.acquire));
}

test "grep fails at the time limit when its single file never opens" {
    const gpa = std.testing.allocator;
    var stall: testing.StallIo = undefined;
    stall.init(gpa, .{ .open_file = "a.txt" });
    defer stall.deinit();
    const context: Context = .{
        .sink = testing.discard_sink,

        .gpa = gpa,
        .host = .{ .io = stall.io() },
        .deadline = .start(stall.io(), search.timeout_ms),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "hit\n" });
    var path_buffer: [128]u8 = undefined;
    const path = try std.mem.print(&path_buffer, ".zig-cache/tmp/{s}/a.txt", .{tmp.sub_path});

    const result = try runIn(&context, "{{\"pattern\":\"hit\",\"path\":\"{s}\"}}", path);
    defer result.deinit(gpa);
    var expected_buffer: [160]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        "Drinky could not search {s} because the file system did not respond within 10 seconds.",
        .{path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try testing.expectConditions(&result, &.{.timed_out});
    try std.testing.expect(stall.canceled.load(.acquire));
}

test "grep stops at the time limit when a directory never opens" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stall: testing.StallIo = undefined;
    stall.init(gpa, .{ .open_directory = "stuck" });
    defer stall.deinit();
    const context: Context = .{
        .sink = testing.discard_sink,

        .gpa = gpa,
        .host = .{ .io = stall.io() },
        .deadline = .start(stall.io(), search.timeout_ms),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "stuck", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hit\n" });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const result = try runIn(&context, "{{\"pattern\":\"hit\",\"path\":\"{s}\"}}", base);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(
        std.mem.find(u8, result.content, "Drinky stopped the search after") != null,
    );
    try testing.expectConditions(&result, &.{.time_limit_reached});
    try std.testing.expect(stall.canceled.load(.acquire));
}

test "grep canceled while reading a file propagates" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "hit\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    var cancel: testing.CancelIo = .init(.file_open);
    const context: Context = .{
        .sink = testing.discard_sink,
        .gpa = gpa,
        .host = .{ .io = cancel.io() },
    };
    try std.testing.expectError(error.Canceled, run(&context, input));
}
