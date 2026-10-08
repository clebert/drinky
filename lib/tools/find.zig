const std = @import("std");

const core = @import("core");

const Context = @import("Context.zig");
const format = @import("format.zig");
const output = @import("output.zig");
const parse = @import("parse.zig");
const search = @import("search.zig");
const testing = @import("testing.zig");
const walk = @import("walk.zig");

const limit_default = 1000;

pub const spec: core.Tool = .{
    .name = "find",
    .description = "Find files by glob pattern. The pattern matches the whole path below the " ++
        "search directory. The wildcards * and ? never cross '/', so use a '**/' prefix to " ++
        "recurse. The output holds one path per line, and each path starts with the search " ++
        "directory. " ++ walk.noise_note ++ " " ++ search.timeoutNote("pattern"),
    .parameters = &.{
        .{
            .name = "pattern",
            .type = .string,
            .required = true,
            .description = "Glob pattern below the search directory, as in '**/*.zig'",
        },
        .{ .name = "path", .type = .string, .description = "Directory to search (default: '.')" },
        .{
            .name = "limit",
            .type = .integer,
            .description = std.fmt.comptimePrint(
                "Maximum number of results (default: {d})",
                .{limit_default},
            ),
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

pub fn run(context: *const Context, input_json: []const u8) Context.Error!core.Tool.Output {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    if (parsed.value.limit == 0)
        return output.failure(gpa, .invalid_arguments, "Set limit to 1 or more.", .{});
    const input = &parsed.value;
    const timer: search.Timer = .start(context.host.io);
    const pattern = input.pattern;
    const base = if (input.path.len == 0) "." else input.path;
    const limit = input.limit;

    var matches = walk.collect(context.host.io, gpa, &.{
        .base = base,
        .pattern = pattern,
        .retain = limit,
        .entries_max = context.host.search.entries_max,
        .timer = timer,
    }) catch |err|
        return output.cannot(gpa, err, "search", base);
    defer matches.deinit(gpa);

    const elapsed_ms = timer.elapsedMs();
    var elapsed_buffer: [24]u8 = undefined;
    const elapsed = format.duration(&elapsed_buffer, elapsed_ms);
    const shown = matches.paths.len;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (matches.paths, 0..) |path, index| {
        if (index > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(path);
    }
    const entries_unread = matches.entries_unread;
    if (matches.matched == 0) {
        switch (matches.stop) {
            .none => if (entries_unread == 0)
                try out.writer.print("No files match {s}.", .{pattern})
            else
                try out.writer.print("No files match {s} in the part that Drinky searched.", .{
                    pattern,
                }),
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
        if (entries_unread > 0) {
            try out.writer.writeAll(" ");
            try walk.writeUnread(&out.writer, entries_unread);
        }
        try matches.skipped_noise.writeNotice(&out.writer);
    } else if (matches.stop == .entries) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print(
            "[Drinky stopped the search because the file tree is too large. Drinky shows " ++
                "the first {d} {s} in path order. Use a narrower path or pattern.]",
            .{ shown, search.matchNoun(shown) },
        );
    } else if (matches.stop == .time) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print(
            "[Drinky stopped the search after {s}. Drinky shows the first {d} {s} in path " ++
                "order. Use a narrower path or pattern.]",
            .{ elapsed, shown, search.matchNoun(shown) },
        );
    } else if (matches.matched > shown) {
        if (shown > 0) try out.writer.writeAll("\n");
        const omitted = matches.matched - shown;
        try out.writer.print("[Drinky omitted {d} {s}. Increase limit to see {s}.]", .{
            omitted,
            search.matchNoun(omitted),
            if (omitted == 1) "it" else "them",
        });
    }
    if (matches.matched > 0 and entries_unread > 0) {
        try out.writer.writeAll("\n[");
        try walk.writeUnread(&out.writer, entries_unread);
        try out.writer.writeAll("]");
    }

    var result: core.Tool.Output = .{ .content = try out.toOwnedSlice() };
    result.measures.put(.duration_ms, @intCast(@max(elapsed_ms, 0)));
    result.measures.put(.matches, shown);
    switch (matches.stop) {
        .none => {},
        .entries => result.conditions.insert(.incomplete),
        .time => result.conditions.insert(.time_limit_reached),
    }
    if (entries_unread > 0) result.conditions.insert(.incomplete);
    if (matches.matched > shown) result.measures.put(.matches_omitted, matches.matched - shown);
    return result;
}

test "find matches files by glob under a directory" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"**/*.zig","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [128]u8 = undefined;
    const expected =
        try std.mem.print(&expected_buffer, ".zig-cache/tmp/{s}/a.zig", .{tmp.sub_path});
    try std.testing.expectEqualStrings(expected, result.content);
    try testing.expectTimed(&result, &.{.{ .matches, 1 }});
    try testing.expectConditions(&result, &.{});
}

test "find keeps one slash after a search directory with a trailing slash" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"*.zig","path":".zig-cache/tmp/{s}/"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    var expected_buffer: [128]u8 = undefined;
    const expected =
        try std.mem.print(&expected_buffer, ".zig-cache/tmp/{s}/a.zig", .{tmp.sub_path});
    try std.testing.expectEqualStrings(expected, result.content);
}

test "find lists a link to a file and follows no link to a directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "" });
    try tmp.dir.symLink(io, "AGENTS.md", "CLAUDE.md", .{});
    try tmp.dir.symLink(io, "missing.md", "dangling.md", .{});
    var docs = try tmp.dir.createDirPathOpen(io, "docs", .{});
    defer docs.close(io);
    try docs.writeFile(io, .{ .sub_path = "guide.md", .data = "" });
    try tmp.dir.symLink(io, ".", "loop", .{ .is_directory = true });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"**/*.md","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/AGENTS.md\n.zig-cache/tmp/{s}/CLAUDE.md\n" ++
            ".zig-cache/tmp/{s}/docs/guide.md",
        .{ tmp.sub_path, tmp.sub_path, tmp.sub_path },
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try testing.expectTimed(&result, &.{.{ .matches, 3 }});
}

test "find reports how many more matched beyond the limit" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "" });
    }
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"*.txt","path":".zig-cache/tmp/{s}","limit":1}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/a.txt\n[Drinky omitted 2 matches. Increase limit to see them.]",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try testing.expectTimed(&result, &.{ .{ .matches, 1 }, .{ .matches_omitted, 2 } });

    const single_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"*.txt","path":".zig-cache/tmp/{s}","limit":2}}
    , .{tmp.sub_path});
    const single = try run(&context, single_input);
    defer single.deinit(gpa);
    try std.testing.expectStringEndsWith(
        single.content,
        "/b.txt\n[Drinky omitted 1 match. Increase limit to see it.]",
    );
    try testing.expectTimed(&single, &.{ .{ .matches, 2 }, .{ .matches_omitted, 1 } });
}

test "find reports a search that reached the entry cap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{
        .gpa = gpa,
        .host = .{ .io = io, .search = .{ .entries_max = 2 } },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    var input_buffer: [128]u8 = undefined;

    const found_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"*.txt","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const found = try run(&context, found_input);
    defer found.deinit(gpa);
    try std.testing.expect(!found.hasFailure());
    try std.testing.expectStringEndsWith(
        found.content,
        ".txt\n[Drinky stopped the search because the file tree is too large. Drinky shows " ++
            "the first 2 matches in path order. Use a narrower path or pattern.]",
    );
    try testing.expectTimed(&found, &.{.{ .matches, 2 }});
    try testing.expectConditions(&found, &.{.incomplete});

    const missed_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"*.md","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const missed = try run(&context, missed_input);
    defer missed.deinit(gpa);
    try std.testing.expectEqualStrings(
        "No files match *.md in the part that Drinky searched. Use a narrower path or " ++
            "pattern because Drinky could not scan the full file tree.",
        missed.content,
    );
    try testing.expectTimed(&missed, &.{.{ .matches, 0 }});
    try testing.expectConditions(&missed, &.{.incomplete});
}

test "find marks a search incomplete when it cannot read a directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "" });
    try tmp.dir.createDir(io, "locked", .default_dir);
    try tmp.dir.setFilePermissions(io, "locked", .fromMode(0), .{});
    defer tmp.dir.setFilePermissions(io, "locked", .fromMode(0o700), .{}) catch {};
    var input_buffer: [128]u8 = undefined;
    var expected_buffer: [256]u8 = undefined;

    const found_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"**/*.md","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const found = try run(&context, found_input);
    defer found.deinit(gpa);
    try std.testing.expect(!found.hasFailure());
    const expected = try std.mem.print(
        &expected_buffer,
        ".zig-cache/tmp/{s}/a.md\n[Drinky could not read 1 entry.]",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, found.content);
    try testing.expectTimed(&found, &.{.{ .matches, 1 }});
    try testing.expectConditions(&found, &.{.incomplete});

    const missed_input = try std.mem.print(&input_buffer,
        \\{{"pattern":"**/*.zig","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const missed = try run(&context, missed_input);
    defer missed.deinit(gpa);
    try std.testing.expectEqualStrings(
        "No files match **/*.zig in the part that Drinky searched. Drinky could not read 1 entry.",
        missed.content,
    );
    try testing.expectTimed(&missed, &.{.{ .matches, 0 }});
    try testing.expectConditions(&missed, &.{.incomplete});
}

fn runIn(context: *const Context, comptime input: []const u8, base: []const u8) !core.Tool.Output {
    var buffer: [256]u8 = undefined;
    return run(context, try std.mem.print(&buffer, input, .{base}));
}

test "find accepts an empty path" {
    const gpa = std.testing.allocator;
    var clock: core.testing.StepClock = undefined;
    clock.init(gpa, search.timeout_ms);
    defer clock.deinit();
    const context: Context = .{ .gpa = gpa, .host = .{ .io = clock.io() } };
    const result = try run(&context,
        \\{"pattern":"**/*.zig","path":""}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
}

test "find refuses a zero limit" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"pattern":"**/*.zig","limit":0}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("Set limit to 1 or more.", result.content);
    try testing.expectConditions(&result, &.{.invalid_arguments});
    try testing.expectMeasures(&result, &.{});
}

test "find reports when no files match" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"*.md","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("No files match *.md.", result.content);
    try testing.expectTimed(&result, &.{.{ .matches, 0 }});
}

test "find reports a missing base directory as a failure" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"pattern":"**/*.zig","path":"/definitely/not/here"}
    );
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.path_missing});
    try testing.expectMeasures(&result, &.{});
}

test "find reports a search that ran out of time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var clock: core.testing.StepClock = undefined;
    clock.init(gpa, search.timeout_ms);
    defer clock.deinit();
    const context: Context = .{ .gpa = gpa, .host = .{ .io = clock.io() } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const result = try runIn(&context, "{{\"pattern\":\"**/*.zig\",\"path\":\"{s}\"}}", base);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(
        std.mem.find(u8, result.content, "Drinky stopped the search after") != null,
    );
    try testing.expectTimed(&result, &.{.{ .matches, 0 }});
    try testing.expectConditions(&result, &.{.time_limit_reached});
}

test "find keeps the matches it found before the clock ran out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var clock: core.testing.StepClock = undefined;
    clock.init(gpa, search.timeout_ms);
    defer clock.deinit();
    const context: Context = .{ .gpa = gpa, .host = .{ .io = clock.io() } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "" });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const result = try runIn(&context, "{{\"pattern\":\"**/*.zig\",\"path\":\"{s}\"}}", base);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(std.mem.find(u8, result.content, ".zig\n[Drinky ") != null);
    try std.testing.expectStringEndsWith(
        result.content,
        ". Drinky shows the first 1 match in path order. Use a narrower path or pattern.]",
    );
    try testing.expectTimed(&result, &.{.{ .matches, 1 }});
    try testing.expectConditions(&result, &.{.time_limit_reached});
}

test "find measures the matches that it omitted when the clock stops the search" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var clock: core.testing.StepClock = undefined;
    clock.init(gpa, search.timeout_ms - 1);
    defer clock.deinit();
    const context: Context = .{ .gpa = gpa, .host = .{ .io = clock.io() } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.zig", "b.zig", "c.zig" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const input = "{{\"pattern\":\"**/*.zig\",\"path\":\"{s}\",\"limit\":1}}";
    const result = try runIn(&context, input, base);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try testing.expectTimed(&result, &.{ .{ .matches, 1 }, .{ .matches_omitted, 1 } });
    try testing.expectConditions(&result, &.{.time_limit_reached});
}

test "find reports skipped noise after an empty search" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dependency = try tmp.dir.createDirPathOpen(io, "node_modules/pkg", .{});
    defer dependency.close(io);
    try dependency.writeFile(io, .{ .sub_path = "ignored.md", .data = "" });
    var repository = try tmp.dir.createDirPathOpen(io, ".git/objects", .{});
    defer repository.close(io);
    try repository.writeFile(io, .{ .sub_path = "ignored.md", .data = "" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"pattern":"**/*.md","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);

    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings(
        "No files match **/*.md. Drinky skipped these noise directories: `node_modules`. " ++
            "Set the path to a skipped directory to search that directory fully.",
        result.content,
    );
    try testing.expectTimed(&result, &.{.{ .matches, 0 }});
}
