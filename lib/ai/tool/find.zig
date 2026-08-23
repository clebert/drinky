//! Finds files by glob pattern and returns the matching paths one per line.

const std = @import("std");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const parse = @import("parse.zig");
const search = @import("search.zig");
const walk = @import("walk.zig");

const limit_default = 1000;

pub const spec: llm.Tool = .{
    .name = "find",
    .description = "Find files by glob pattern. Returns paths relative to the working " ++
        "directory, one per line. The pattern matches the whole path and * and ? never " ++
        "cross '/', so use a '**/' prefix to recurse. Skips common version-control stores, " ++
        "dependency directories, virtual environments, build outputs, and tool caches. " ++
        "A path that ends with a skipped directory name searches it fully. " ++
        std.fmt.comptimePrint(
            "A search has a fixed {d}-second timeout. A timed-out search returns the matches " ++
                "it found. Narrow the path or the pattern to search less.",
            .{@divExact(search.timeout_ms, std.time.ms_per_s)},
        ),
    .parameters = &.{
        .{
            .name = "pattern",
            .type = .string,
            .required = true,
            .description = "Glob pattern, e.g. '**/*.zig' or 'src/**/*.zig'",
        },
        .{ .name = "path", .type = .string, .description = "Directory to search (default: '.')" },
        .{
            .name = "limit",
            .type = .integer,
            .description = "Maximum number of results (default: 1000)",
        },
    },
};

const Input = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    limit: usize = limit_default,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const timer: search.Timer = .start(context.io);
    return runTimed(context, &parsed.value, &timer);
}

/// The matching paths, or the sentence that states why the search found none.
/// The walk polls `timer` between filesystem steps, so a walk of a tree too
/// large for the window stops itself and keeps what it retained.
fn runTimed(context: *const Context, input: *const Input, timer: *const search.Timer) !Result {
    const gpa = context.gpa;
    const pattern = input.pattern;
    const base = input.path;
    const limit = input.limit;

    var matches = walk.collect(context.io, gpa, &.{
        .base = base,
        .pattern = pattern,
        .retain = limit,
        .timer = timer.*,
    }) catch |err|
        return Result.cannot(gpa, err, "search", base);
    defer matches.deinit(gpa);

    // One reading of the clock serves the sentence below and the box line, so
    // both report the same span. It leaves out the work of the report itself.
    var elapsed_buffer: [24]u8 = undefined;
    const elapsed = format.duration(&elapsed_buffer, timer.elapsedMs());
    const shown = matches.paths.len;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (matches.paths, 0..) |path, index| {
        if (index > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(path);
    }
    // An empty search is a whole result, so its sentence is the content and the
    // count below states it. The paths are empty here, so the sentence opens the
    // content and takes no separator.
    if (matches.matched == 0) {
        switch (matches.stop) {
            .none => try out.writer.print("No files match {s}.", .{pattern}),
            .entries => try out.writer.print(
                "No files match {s} in the part that Drinky searched. Use a narrower path or " ++
                    "pattern because Drinky could not scan the full file tree.",
                .{pattern},
            ),
            .time => try out.writer.print(
                "No files match {s} in the part that Drinky searched. Drinky stopped the search " ++
                    "after {s}. Use a narrower path or pattern.",
                .{ pattern, elapsed },
            ),
        }
    } else if (matches.stop == .entries) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print(
            "[Drinky stopped the search because the file tree is too large. " ++
                "Drinky shows the {d} smallest matches. Use a narrower path or pattern.]",
            .{shown},
        );
    } else if (matches.stop == .time) {
        if (shown > 0) try out.writer.writeAll("\n");
        // The same measure the notice above names: the walk retained the
        // smallest matches of the part it walked, and `shown` can sit below the
        // count it saw.
        try out.writer.print(
            "[Drinky stopped the search after {s}. Drinky shows the {d} smallest matches. " ++
                "Use a narrower path or pattern.]",
            .{ elapsed, shown },
        );
    } else if (matches.matched > shown) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print(
            "[Drinky omitted {d} matches. Increase limit to see them.]",
            .{matches.matched - shown},
        );
    }
    if (matches.matched == 0 and !matches.skipped_noise.isEmpty()) {
        try out.writer.writeAll(" ");
        try matches.skipped_noise.writeNotice(&out.writer);
    }

    var summary_output: std.Io.Writer.Allocating = .init(gpa);
    errdefer summary_output.deinit();
    // The run time comes first, because the row above counted up to it and a
    // narrow window cuts the tail of this row.
    try summary_output.writer.print("Time: {s} · Matches: {d}", .{ elapsed, shown });
    switch (matches.stop) {
        .none => {},
        .entries => try summary_output.writer.writeAll(" · Search: Incomplete"),
        .time => try summary_output.writer.writeAll(" · Search: Timed out"),
    }
    // A bound that stopped the walk does not hide the omitted count: the two ask
    // the model for different changes, a narrower search and a higher limit. One
    // processed entry holds at most one match, so a tiny limit is the one route
    // to a stopped walk that omitted a match too.
    if (matches.matched > shown)
        try summary_output.writer.print(" · Omitted matches: {d}", .{matches.matched - shown});
    const summary = try summary_output.toOwnedSlice();
    errdefer gpa.free(summary);
    const content = try out.toOwnedSlice();
    return .{ .content = content, .summary = .{ .text = summary }, .is_error = false };
}

test "find matches files by glob under a directory" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"**/*.zig","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected =
        try std.fmt.bufPrint(&expected_buf, ".zig-cache/tmp/{s}/a.zig", .{tmp.sub_path});
    try std.testing.expectEqualStrings(expected, result.content);
    try search.expectMeasures(result.summary.?, "Matches: 1");
}

test "find reports how many more matched beyond the limit" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "" });
    }
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"*.txt","path":".zig-cache/tmp/{s}","limit":1}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/a.txt\n[Drinky omitted 2 matches. Increase limit to see them.]",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try search.expectMeasures(result.summary.?, "Matches: 1 · Omitted matches: 2");
}

test "find reports when no files match" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"*.md","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("No files match *.md.", result.content);
    // An empty search still states its count, so the box reads like every other
    // result of this tool.
    try search.expectMeasures(result.summary.?, "Matches: 0");
}

// A search checks a wall-clock timeout after each walk step. A stopped search
// states the stop, so the model narrows the next search on evidence.
test "find reports a search that ran out of time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Two files, so a further entry proves the walk incomplete. Neither matches
    // the pattern, so the stopped search reports no match at all.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // A timer that started a whole timeout ago is spent at the first check, so
    // the walk keeps one entry and stops on the next one.
    const timer: search.Timer = .startedAgo(io, search.timeout_ms);
    const result = try runTimed(&context, &.{ .pattern = "**/*.zig", .path = base }, &timer);
    defer result.deinit(gpa);
    // A stopped search is a whole result, not a failure, because it reports the
    // matches it found.
    try std.testing.expect(!result.is_error);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Drinky stopped the search after") != null,
    );
    try search.expectMeasures(result.summary.?, "Matches: 0 · Search: Timed out");
}

// A stopped walk keeps the matches it retained, so the result holds paths and
// not one sentence. The notice names the same measure the whole-tree notice
// names, because both show the smallest matches of what they walked.
test "find keeps the matches it found before the clock ran out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // The walk keeps its first entry and stops on the second. Enumeration order
    // decides which file it keeps.
    const timer: search.Timer = .startedAgo(io, search.timeout_ms);
    const result = try runTimed(&context, &.{ .pattern = "**/*.zig", .path = base }, &timer);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, ".zig\n[Drinky ") != null);
    try std.testing.expectStringEndsWith(
        result.content,
        ". Drinky shows the 1 smallest matches. Use a narrower path or pattern.]",
    );
    try search.expectMeasures(result.summary.?, "Matches: 1 · Search: Timed out");
}

// A stop does not hide the omitted count. A limit of zero retains nothing, which
// is the one route to a stopped walk that also saw a match it did not keep.
test "find states both the clock and the matches it omitted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const timer: search.Timer = .startedAgo(io, search.timeout_ms);
    const result = try runTimed(
        &context,
        &.{ .pattern = "**/*.zig", .path = base, .limit = 0 },
        &timer,
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try search.expectMeasures(
        result.summary.?,
        "Matches: 0 · Search: Timed out · Omitted matches: 1",
    );
}

test "find reports skipped noise after an empty search" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dependency = try tmp.dir.createDirPathOpen(io, "node_modules/pkg", .{});
    defer dependency.close(io);
    try dependency.writeFile(io, .{ .sub_path = "ignored.md", .data = "" });
    var repository = try tmp.dir.createDirPathOpen(io, ".git/objects", .{});
    defer repository.close(io);
    try repository.writeFile(io, .{ .sub_path = "ignored.md", .data = "" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"**/*.md","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "No files match **/*.md. Drinky skipped these noise directories: `node_modules`. " ++
            "Set the path to a skipped directory to search that directory fully.",
        result.content,
    );
    try search.expectMeasures(result.summary.?, "Matches: 0");
}
