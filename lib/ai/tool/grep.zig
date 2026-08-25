//! Searches file contents for a literal substring and returns matches as
//! 'path:line:text'.

const std = @import("std");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const fs = @import("fs.zig");
const parse = @import("parse.zig");
const search = @import("search.zig");
const walk = @import("walk.zig");

const limit_default = 100;
const file_bytes_max = 4 << 20;
const line_bytes_max = 300;
// The retained candidate paths bound the path-list memory. The running total of
// bytes read across searched files bounds the actual I/O work. A bare
// `files_max * file_bytes_max` ceiling leaves the I/O work at hundreds of gigabytes.
const files_max = 100_000;
const bytes_read_max = 256 << 20;

pub const spec: llm.Tool = .{
    .name = "grep",
    .description = "Search file contents for a literal substring (not a regex). " ++
        // The routing sentence belongs here, not in the bash description alone.
        // A model reads the bash schema after it chose bash.
        "Use this tool for a literal search instead of a grep or rg command in bash. " ++
        "Returns matching lines as 'path:line:text', with paths relative to the working " ++
        "directory. Skips common version-control stores, dependency directories, virtual " ++
        "environments, build outputs, and tool caches. A path that ends with a skipped " ++
        "directory name searches it fully. " ++
        std.fmt.comptimePrint(
            "A search has a fixed {d}-second timeout. A timed-out search returns the matches " ++
                "it found. Narrow the path or the glob to search less.",
            .{@divExact(search.timeout_ms, std.time.ms_per_s)},
        ),
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
            .description = "Only search files whose path matches this glob; * and ? do not " ++
                "cross '/', so use a '**/' prefix to recurse; has no effect when path names " ++
                "a single file (default: all files)",
        },
        .{
            .name = "ignore_case",
            .type = .boolean,
            .description = "Case-insensitive search (default: false)",
        },
        .{
            .name = "limit",
            .type = .integer,
            .description = "Maximum number of matching lines (default: 100)",
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

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    if (parsed.value.pattern.len == 0)
        return Result.report(gpa, .err, "Enter a nonempty pattern.", .{});
    const timer: search.Timer = .start(context.io);
    return runTimed(context, &parsed.value, &timer);
}

/// The matching lines, or the sentence that states why the search found none.
/// The walk and the file loop poll `timer` between filesystem steps, so a
/// search of a tree too large for the window stops itself and keeps the matches
/// it found.
fn runTimed(context: *const Context, input: *const Input, timer: *const search.Timer) !Result {
    const gpa = context.gpa;
    const pattern = input.pattern;
    // A model sometimes sends an empty path instead of no path. An empty path
    // means the default, so the search runs from the working directory.
    const base = if (input.path.len == 0) "." else input.path;
    const limit = input.limit;

    // Drinky walks a directory for its files. Drinky searches a path that names a
    // single file directly and ignores the glob. The glob only filters a
    // traversal, and a named file needs none. `maybe_match` owns the walked
    // paths. The file case borrows `base`, which outlives the search.
    const single_file: [1][]const u8 = .{base};
    var paths: []const []const u8 = &single_file;
    var files_incomplete = false;
    var timed_out = false;
    var maybe_match: ?walk.Match = null;
    defer if (maybe_match) |*match| match.deinit(gpa);
    if (walk.collect(context.io, gpa, &.{
        .base = base,
        .pattern = input.glob,
        .retain = files_max,
        .timer = timer.*,
    })) |match| {
        maybe_match = match;
        paths = match.paths;
        // A walk that retains fewer candidates than it found, or a walk that
        // reached its entry cap, leaves some files unsearched. A walk that ran
        // out of time states the stop, because a walk that retained no path
        // leaves the loop below with no file to read and no check to make.
        files_incomplete = match.stop == .entries or match.matched > match.paths.len;
        timed_out = match.stop == .time;
    } else |err| switch (err) {
        // Not a directory: `base` names a file, so search that one path.
        error.NotDir => {},
        else => return Result.cannot(gpa, err, "search", base),
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var count: usize = 0;
    var line_capped = false;
    var lines_truncated = false;
    var bytes_read: usize = 0;
    var bytes_capped = false;
    search: for (paths, 0..) |path, index| {
        // One clock read per file, which costs far less than the read of that
        // file. The first file always runs, so a search that spent its whole
        // budget on the walk still reports what one file holds, and a stop only
        // lands once a further file proves the search is incomplete.
        //
        // Both bounds take their reading before the loop ends, so a file that
        // meets both reports both. The readings are local, because a walk that
        // ran out of time set the flag before this loop started and must not
        // stop it here. No test covers the pair, because the byte bound takes
        // 256 MB of reads.
        const out_of_time = index > 0 and timer.spent();
        const out_of_bytes = bytes_read >= bytes_read_max;
        if (out_of_time) timed_out = true;
        if (out_of_bytes) bytes_capped = true;
        if (out_of_time or out_of_bytes) break :search;
        const data = std.Io.Dir.cwd().readFileAlloc(
            context.io,
            path,
            gpa,
            .limited(file_bytes_max),
        ) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            // An oversized file streams the full limit off disk before it fails.
            error.StreamTooLong => {
                bytes_read += file_bytes_max;
                continue;
            },
            else => continue,
        };
        defer gpa.free(data);
        bytes_read += data.len;
        if (std.mem.indexOfScalar(u8, data, 0) != null) continue;

        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            line_number += 1;
            const hit = if (input.ignore_case)
                std.ascii.findIgnoreCase(line, pattern)
            else
                std.mem.indexOf(u8, line, pattern);
            if (hit == null) continue;
            if (count == limit) {
                line_capped = true;
                break :search;
            }
            const shown = line[0..utf8FloorLength(line, line_bytes_max)];
            if (shown.len < line.len) lines_truncated = true;
            if (count > 0) try out.writer.writeAll("\n");
            // Substitute U+FFFD for invalid bytes so the result serializes as a JSON string.
            try out.writer.print("{f}:{d}:{f}", .{
                std.unicode.fmtUtf8(path),
                line_number,
                std.unicode.fmtUtf8(shown),
            });
            count += 1;
        }
    }

    // One reading of the clock serves the sentence below and the box line, so
    // both report the same span. It leaves out the work of the report itself.
    var elapsed_buffer: [24]u8 = undefined;
    const elapsed = format.duration(&elapsed_buffer, timer.elapsedMs());
    // Every bound above already implies that files went unsearched, so this one
    // speaks for a search that no bound stopped. One name serves the notice and
    // the box line, so the two cannot drift apart. No test reaches it, because
    // the flag needs a tree of a million entries or a hundred thousand
    // candidate files.
    const files_unsearched = files_incomplete and !timed_out and !line_capped and !bytes_capped;
    // An empty search is a whole result, so its sentence is the content and the
    // count below states it. No match line precedes it, so it takes no
    // separator. A result with matches states every bound that cut it instead,
    // because the clock and the result limit ask the model for different
    // changes, and one that swallows the other hides the change it asks for.
    if (count == 0) {
        if (timed_out) {
            try out.writer.print(
                "Drinky found no matches for {s} in the part that Drinky searched. Drinky " ++
                    "stopped the search after {s}. Use a narrower path or glob.",
                .{ pattern, elapsed },
            );
        } else if (line_capped or bytes_capped or files_incomplete) {
            try out.writer.print(
                "Drinky found no matches for {s} in the part that Drinky searched. " ++
                    "Use a narrower path or glob because the search was incomplete.",
                .{pattern},
            );
        } else {
            try out.writer.print("Drinky found no matches for {s}.", .{pattern});
        }
        if (maybe_match) |*match| {
            if (!match.skipped_noise.isEmpty()) {
                try out.writer.writeAll(" ");
                try match.skipped_noise.writeNotice(&out.writer);
            }
        }
    } else {
        // The clock and a result budget can both cut one search: a walk can
        // spend the whole budget, and the first file it retained can then fill
        // the result limit. Each notice states the change it asks for.
        if (timed_out) try out.writer.print(
            "\n[Drinky stopped the search after {s}. Drinky shows the matches that it found. " ++
                "Use a narrower path or glob.]",
            .{elapsed},
        );
        if (line_capped) try out.writer.print(
            "\n[Drinky stopped after {d} matches. Refine the search or increase limit.]",
            .{limit},
        );
        if (bytes_capped) try out.writer.print(
            "\n[Drinky stopped after Drinky read {d} MB. Refine the search or use a narrower " ++
                "path or glob.]",
            .{bytes_read_max >> 20},
        );
        if (files_unsearched) try out.writer.writeAll(
            "\n[Drinky could not scan the full file tree. Drinky did not search some files.]",
        );
    }

    var summary_output: std.Io.Writer.Allocating = .init(gpa);
    errdefer summary_output.deinit();
    // The run time comes first, because the row above counted up to it and a
    // narrow window cuts the tail of this row.
    try summary_output.writer.print("Time: {s} · Matches: {d}", .{ elapsed, count });
    // Every bound that cut the result names itself, in the order the notices
    // above take.
    if (timed_out) try summary_output.writer.writeAll(" · Search: Timed out");
    if (line_capped) try summary_output.writer.writeAll(" · Limit: Reached");
    if (bytes_capped) try summary_output.writer.print(
        " · Stopped at: {d} MB",
        .{bytes_read_max >> 20},
    );
    if (files_unsearched) try summary_output.writer.writeAll(" · Search: Incomplete");
    if (lines_truncated) try summary_output.writer.writeAll(" · Lines: Truncated");
    const summary = try summary_output.toOwnedSlice();
    errdefer gpa.free(summary);
    const content = try out.toOwnedSlice();
    return .{ .content = content, .summary = .{ .text = summary }, .is_error = false };
}

/// The largest length no greater than `max` that does not split a UTF-8
/// codepoint, so a truncated line stays valid UTF-8 for JSON serialization.
fn utf8FloorLength(bytes: []const u8, max: usize) usize {
    var end = @min(bytes.len, max);
    while (end > 0 and end < bytes.len and bytes[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

test utf8FloorLength {
    try std.testing.expectEqual(@as(usize, 1), utf8FloorLength("a\xC3\xA9", 2));
    try std.testing.expectEqual(@as(usize, 3), utf8FloorLength("a\xC3\xA9", 3));
    try std.testing.expectEqual(@as(usize, 3), utf8FloorLength("a\xC3\xA9", 10));
    try std.testing.expectEqual(@as(usize, 0), utf8FloorLength("", 5));
}

test "grep finds a literal substring with a glob filter" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "nope\nneedle here\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "needle here\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}","glob":"**/*.zig"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/a.zig:2:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try search.expectMeasures(result.summary.?, "Matches: 1");
}

test "grep searches a single file given as the path" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "nope\nneedle here\n" });
    var input_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}/a.zig"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/a.zig:2:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
}

test "grep ignores the glob when the path is a single file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "needle here\n" });
    var input_buf: [192]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}/a.zig","glob":"**/*.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/a.zig:1:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
}

// A model sometimes sends an empty path instead of no path. An empty path
// means the default, so the search runs from the working directory and does
// not fail with an invisible path. The spent timer stops the walk after one
// entry, so the test does not scan the whole working tree.
test "grep treats an empty path as the working directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    const timer: search.Timer = .startedAgo(io, search.timeout_ms);
    const result = try runTimed(&context, &.{ .pattern = "needle", .path = "" }, &timer);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
}

test "grep replaces invalid UTF-8 in matched lines" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "latin1.txt", .data = "caf\xE9 latte\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"caf","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});

    const context: Context = .{ .gpa = std.testing.allocator, .io = io };
    const result = try run(&context, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.content));
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "latin1.txt:1:caf\u{FFFD} latte") != null,
    );
}

test "grep is case-insensitive when asked" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "Needle Here\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"NEEDLE","path":".zig-cache/tmp/{s}","ignore_case":true}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "a.txt:1:Needle Here") != null);
}

test "grep stops at the result limit and reports it" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "f.txt",
        .data = "hit one\nhit two\nhit three\n",
    });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}","limit":2}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/f.txt:1:hit one\n.zig-cache/tmp/{s}/f.txt:2:hit two\n" ++
            "[Drinky stopped after 2 matches. Refine the search or increase limit.]",
        .{ tmp.sub_path, tmp.sub_path },
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try search.expectMeasures(result.summary.?, "Matches: 2 · Limit: Reached");
}

test "grep skips binary and oversized files" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bin.dat", .data = "hit\x00\n" });
    const big = try gpa.alloc(u8, file_bytes_max + 1);
    defer gpa.free(big);
    @memset(big, 'a');
    @memcpy(big[0..3], "hit");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "huge.txt", .data = big });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small.txt", .data = "hit\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/small.txt:1:hit",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
}

test "grep caps the reported line length" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "hit" ++ "a" ** 397;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = line ++ "\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/long.txt:1:{s}",
        .{ tmp.sub_path, line[0..line_bytes_max] },
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try search.expectMeasures(result.summary.?, "Matches: 1 · Lines: Truncated");
}

test "grep reports an incomplete search when nothing was shown" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "hit\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}","limit":0}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "the search was incomplete") != null,
    );
    try search.expectMeasures(result.summary.?, "Matches: 0 · Limit: Reached");
}

// An empty search still states its count, so the box reads like every other
// result of this tool.
test "grep reports no matches of a complete search" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "hit\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"miss","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("Drinky found no matches for miss.", result.content);
    try search.expectMeasures(result.summary.?, "Matches: 0");
}

test "grep reports skipped noise after an empty search" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dependency = try tmp.dir.createDirPathOpen(io, "node_modules/pkg", .{});
    defer dependency.close(io);
    try dependency.writeFile(io, .{ .sub_path = "ignored.txt", .data = "needle\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "Drinky found no matches for needle. Drinky skipped these noise directories: " ++
            "`node_modules`. Set the path to a skipped directory to search that directory fully.",
        result.content,
    );
    try search.expectMeasures(result.summary.?, "Matches: 0");
}

// A search checks a wall-clock timeout between bounded steps. A stopped search
// states the stop, so the model narrows the next search on evidence.
test "grep reports a search that ran out of time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Two files, so a further entry proves the walk incomplete. Neither holds
    // the pattern, so the stopped search reports no match at all.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "nope\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "nope\n" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // A timer that started a whole timeout ago is spent at the first check, so
    // the walk keeps one entry and stops on the next one.
    const timer: search.Timer = .startedAgo(io, search.timeout_ms);
    const result = try runTimed(&context, &.{ .pattern = "hit", .path = base }, &timer);
    defer result.deinit(gpa);
    // A stopped search is a whole result, not a failure, because it reports the
    // matches it found.
    try std.testing.expect(!result.is_error);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Drinky stopped the search after") != null,
    );
    try search.expectMeasures(result.summary.?, "Matches: 0 · Search: Timed out");
}

// A search that read a file before the clock ran out keeps those matches, so the
// model narrows the next search on evidence rather than on one sentence.
test "grep keeps the matches it found before the clock ran out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hit\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "hit\n" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // The walk keeps its first entry and stops on the second, and the loop reads
    // that one file. Enumeration order decides which file it is.
    const timer: search.Timer = .startedAgo(io, search.timeout_ms);
    const result = try runTimed(&context, &.{ .pattern = "hit", .path = base }, &timer);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    // The match line stands, and the notice behind it states the stop. The span
    // it names varies with the machine, so the head and the tail pin the rest.
    try std.testing.expect(std.mem.indexOf(u8, result.content, ".txt:1:hit\n[Drinky ") != null);
    try std.testing.expectStringEndsWith(
        result.content,
        ". Drinky shows the matches that it found. Use a narrower path or glob.]",
    );
    try search.expectMeasures(result.summary.?, "Matches: 1 · Search: Timed out");
}

// The clock and the result limit ask the model for different changes, a narrower
// search and a higher limit, so a search that met both states both. A walk that
// spent the whole budget hands the loop one file, and that file alone fills the
// limit.
test "grep states both the clock and the result limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hit\nhit\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "hit\nhit\n" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const timer: search.Timer = .startedAgo(io, search.timeout_ms);
    const result = try runTimed(
        &context,
        &.{ .pattern = "hit", .path = base, .limit = 1 },
        &timer,
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Drinky stopped the search after") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Drinky stopped after 1 matches.") != null,
    );
    try search.expectMeasures(
        result.summary.?,
        "Matches: 1 · Search: Timed out · Limit: Reached",
    );
}

test "grep canceled while reading a file propagates" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "hit\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    var cancel: fs.CancelIo = .init(.file_open);
    const context: Context = .{ .gpa = gpa, .io = cancel.io() };
    try std.testing.expectError(error.Canceled, run(&context, input));
}
