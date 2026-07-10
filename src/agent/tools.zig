//! The tools the model may call, and their execution. Each tool takes the raw
//! JSON input from a `tool_use` block and returns text for the matching
//! `tool_result`. File access is relative to the process working directory.

const std = @import("std");

const message = @import("../anthropic/message.zig");
const glob = @import("glob.zig");

pub const Result = struct {
    /// Owned by the caller's allocator.
    content: []const u8,
    is_error: bool,
};

pub const definitions = [_]message.Tool{
    .{
        .name = "read",
        .description = "Read a UTF-8 text file. Output is truncated to 2000 lines or 50KB, whichever comes first; use offset and limit to page through large files (the output notes the next offset to continue from).",
        .schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file (relative or absolute)"},"offset":{"type":"integer","description":"1-indexed line to start reading from (default: 1)"},"limit":{"type":"integer","description":"Maximum number of lines to read"}},"required":["path"]}
        ,
    },
    .{
        .name = "write",
        .description = "Create or overwrite a UTF-8 text file with the given contents.",
        .schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"content":{"type":"string","description":"Full file contents; replaces the file entirely"}},"required":["path","content"]}
        ,
    },
    .{
        .name = "edit",
        .description = "Replace an exact, unique span of text in an existing file. old_text must occur exactly once; include enough surrounding context to make it unique.",
        .schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"old_text":{"type":"string","description":"Exact text to replace; must occur exactly once"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path","old_text","new_text"]}
        ,
    },
    .{
        .name = "find",
        .description = "Find files by glob pattern. Returns paths relative to the working directory, one per line. The pattern matches the whole path and * and ? never cross '/', so use a '**/' prefix to recurse. Ignores .git, zig-out, and build cache directories.",
        .schema_json =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern, e.g. '**/*.zig' or 'src/**/*.zig'"},"path":{"type":"string","description":"Directory to search (default: '.')"},"limit":{"type":"integer","description":"Maximum number of results (default: 1000)"}},"required":["pattern"]}
        ,
    },
    .{
        .name = "grep",
        .description = "Search file contents for a literal substring (not a regex). Returns matching lines as 'path:line:text', with paths relative to the working directory. Ignores .git, zig-out, and build cache directories.",
        .schema_json =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Literal substring to search for"},"path":{"type":"string","description":"Directory to search (default: '.')"},"glob":{"type":"string","description":"Only search files whose path matches this glob; * and ? do not cross '/', so use a '**/' prefix to recurse (default: all files)"},"ignore_case":{"type":"boolean","description":"Case-insensitive search (default: false)"},"limit":{"type":"integer","description":"Maximum number of matching lines (default: 100)"}},"required":["pattern"]}
        ,
    },
};

const Outcome = enum { ok, err };

const noise_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out" };
const read_lines_max = 2000;
const read_bytes_max = 50 * 1024;
const read_file_bytes_max = 16 << 20;
const find_limit_default = 1000;
const grep_limit_default = 100;
const grep_file_bytes_max = 4 << 20;
const grep_line_bytes_max = 300;

/// Execute tool `name` with `input_json`. Caller frees `Result.content`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, name: []const u8, input_json: []const u8) !Result {
    if (std.mem.eql(u8, name, "read")) return readFile(gpa, io, input_json);
    if (std.mem.eql(u8, name, "write")) return writeFile(gpa, io, input_json);
    if (std.mem.eql(u8, name, "edit")) return editFile(gpa, io, input_json);
    if (std.mem.eql(u8, name, "find")) return findFiles(gpa, io, input_json);
    if (std.mem.eql(u8, name, "grep")) return grepFiles(gpa, io, input_json);
    return report(gpa, .err, "unknown tool: {s}", .{name});
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, input_json: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const path = field(parsed.value, "path") orelse return report(gpa, .err, "missing 'path'", .{});
    const offset = fieldUint(parsed.value, "offset") orelse 1;
    const limit = fieldUint(parsed.value, "limit");

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(read_file_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => return report(gpa, .err, "{s} is larger than {d} bytes; read it another way", .{ path, read_file_bytes_max }),
        else => return report(gpa, .err, "cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    defer gpa.free(data);

    if (std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data)) {
        return report(gpa, .err, "{s} is not a UTF-8 text file", .{path});
    }

    const total = std.mem.count(u8, data, "\n") + 1;
    const start = if (offset > 0) offset - 1 else 0;
    if (start >= total) {
        return report(gpa, .err, "offset {d} is past the end of {s} ({d} lines)", .{ offset, path, total });
    }
    const lines_max = limit orelse read_lines_max;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var index: usize = 0;
    var shown: usize = 0;
    var bytes: usize = 0;
    var last = start;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| : (index += 1) {
        if (index < start) continue;
        if (shown >= lines_max) break;
        if (shown > 0 and bytes + line.len > read_bytes_max) break;
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(line);
        bytes += line.len + 1;
        last = index;
        shown += 1;
    }
    if (last + 1 < total) {
        try out.writer.print("\n\n[showing lines {d}-{d} of {d}; use offset={d} to continue]", .{ start + 1, last + 1, total, last + 2 });
    }
    return .{ .content = try out.toOwnedSlice(), .is_error = false };
}

fn writeFile(gpa: std.mem.Allocator, io: std.Io, input_json: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const path = field(parsed.value, "path") orelse return report(gpa, .err, "missing 'path'", .{});
    const contents = field(parsed.value, "content") orelse return report(gpa, .err, "missing 'content'", .{});

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents }) catch |err| {
        return report(gpa, .err, "cannot write {s}: {s}", .{ path, @errorName(err) });
    };
    return report(gpa, .ok, "wrote {d} bytes to {s}", .{ contents.len, path });
}

/// Replace the single occurrence of `old` in `data` with `new`. Errors when the
/// match is absent or ambiguous so the caller never edits the wrong span. A
/// second match starting anywhere past the first — including an overlapping one
/// like "aa" in "aaa" — counts as ambiguous.
fn applyEdit(gpa: std.mem.Allocator, data: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (old.len == 0) return error.EmptyOldText;
    const index = std.mem.indexOf(u8, data, old) orelse return error.NotFound;
    if (std.mem.indexOfPos(u8, data, index + 1, old) != null) return error.NotUnique;
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ data[0..index], new, data[index + old.len ..] });
}

fn editFile(gpa: std.mem.Allocator, io: std.Io, input_json: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const path = field(parsed.value, "path") orelse return report(gpa, .err, "missing 'path'", .{});
    const old = field(parsed.value, "old_text") orelse return report(gpa, .err, "missing 'old_text'", .{});
    const new = field(parsed.value, "new_text") orelse return report(gpa, .err, "missing 'new_text'", .{});

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        return report(gpa, .err, "cannot read {s}: {s}", .{ path, @errorName(err) });
    };
    defer gpa.free(data);

    const updated = applyEdit(gpa, data, old, new) catch |err| switch (err) {
        error.EmptyOldText => return report(gpa, .err, "old_text must not be empty", .{}),
        error.NotFound => return report(gpa, .err, "old_text not found in {s}", .{path}),
        error.NotUnique => return report(gpa, .err, "old_text is not unique in {s}; include more surrounding context", .{path}),
        else => return err,
    };
    defer gpa.free(updated);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = updated }) catch |err| {
        return report(gpa, .err, "cannot write {s}: {s}", .{ path, @errorName(err) });
    };
    return report(gpa, .ok, "edited {s}", .{path});
}

fn findFiles(gpa: std.mem.Allocator, io: std.Io, input_json: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const pattern = field(parsed.value, "pattern") orelse return report(gpa, .err, "missing 'pattern'", .{});
    const base = field(parsed.value, "path") orelse ".";
    const limit = fieldUint(parsed.value, "limit") orelse find_limit_default;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = collectFiles(io, arena, .{ .base = base, .pattern = pattern }) catch |err| {
        return report(gpa, .err, "cannot search {s}: {s}", .{ base, @errorName(err) });
    };
    if (files.len == 0) return report(gpa, .ok, "no files match {s}", .{pattern});
    std.mem.sort([]const u8, files, {}, lessThan);

    const shown = @min(files.len, limit);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (files[0..shown], 0..) |path, index| {
        if (index > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(path);
    }
    if (files.len > shown) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print("... {d} more (raise limit to see them)", .{files.len - shown});
    }
    return .{ .content = try out.toOwnedSlice(), .is_error = false };
}

fn grepFiles(gpa: std.mem.Allocator, io: std.Io, input_json: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const pattern = field(parsed.value, "pattern") orelse return report(gpa, .err, "missing 'pattern'", .{});
    if (pattern.len == 0) return report(gpa, .err, "pattern must not be empty", .{});
    const base = field(parsed.value, "path") orelse ".";
    const file_glob = field(parsed.value, "glob") orelse "**";
    const ignore_case = fieldBool(parsed.value, "ignore_case") orelse false;
    const limit = fieldUint(parsed.value, "limit") orelse grep_limit_default;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = collectFiles(io, arena, .{ .base = base, .pattern = file_glob }) catch |err| {
        return report(gpa, .err, "cannot search {s}: {s}", .{ base, @errorName(err) });
    };
    std.mem.sort([]const u8, files, {}, lessThan);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var count: usize = 0;
    var truncated = false;
    search: for (files) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(grep_file_bytes_max)) catch continue;
        defer gpa.free(data);
        if (std.mem.indexOfScalar(u8, data, 0) != null) continue;

        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            line_number += 1;
            if (!lineContains(.{ .line = line, .needle = pattern, .ignore_case = ignore_case })) continue;
            if (count == limit) {
                truncated = true;
                break :search;
            }
            const shown = line[0..utf8FloorLength(line, grep_line_bytes_max)];
            if (count > 0) try out.writer.writeAll("\n");
            try out.writer.print("{s}:{d}:{s}", .{ path, line_number, shown });
            count += 1;
        }
    }
    if (count == 0) return report(gpa, .ok, "no matches for {s}", .{pattern});
    if (truncated) {
        try out.writer.print("\n... stopped at the limit of {d} matches; refine the search or raise limit", .{limit});
    }
    return .{ .content = try out.toOwnedSlice(), .is_error = false };
}

/// Regular-file paths under `options.base` whose base-relative path matches
/// `options.pattern`, returned relative to the working directory and owned by
/// `arena`. The walk always drains — even on I/O or allocation failure — so the
/// walker's open directory handles are released (its `deinit` does not close
/// them).
fn collectFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    options: struct { base: []const u8, pattern: []const u8 },
) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, options.base, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    var failure: ?anyerror = null;
    const at_root = std.mem.eql(u8, options.base, ".");
    // Drain the whole tree even on errors so the walker's directory handles are
    // released: `next` closes the directory it fails on, and skipping an
    // unreadable subdirectory leaves its ancestors on the stack to be closed as
    // the walk completes.
    while (true) {
        const entry = (walker.next(io) catch continue) orelse break;
        switch (entry.kind) {
            .directory => if (!isNoise(entry.basename)) walker.enter(io, entry) catch {},
            .file => {
                if (failure != null or !glob.match(.{ .pattern = options.pattern, .path = entry.path })) continue;
                const relative = if (at_root)
                    arena.dupe(u8, entry.path)
                else
                    std.fmt.allocPrint(arena, "{s}/{s}", .{ options.base, entry.path });
                const owned = relative catch |err| {
                    failure = err;
                    continue;
                };
                files.append(arena, owned) catch |err| {
                    failure = err;
                };
            },
            else => {},
        }
    }
    if (failure) |err| return err;
    return files.toOwnedSlice(arena);
}

/// Largest length no greater than `max` that does not split a UTF-8 codepoint,
/// so a truncated line stays valid UTF-8 for JSON serialization.
fn utf8FloorLength(bytes: []const u8, max: usize) usize {
    var end = @min(bytes.len, max);
    while (end > 0 and end < bytes.len and bytes[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

fn lineContains(options: struct { line: []const u8, needle: []const u8, ignore_case: bool }) bool {
    const line = options.line;
    const needle = options.needle;
    if (needle.len == 0 or line.len < needle.len) return false;
    if (!options.ignore_case) return std.mem.indexOf(u8, line, needle) != null;
    const last = line.len - needle.len;
    var start: usize = 0;
    while (start <= last) : (start += 1) {
        if (std.ascii.startsWithIgnoreCase(line[start..], needle)) return true;
    }
    return false;
}

fn isNoise(basename: []const u8) bool {
    for (noise_dirs) |noise| {
        if (std.mem.eql(u8, basename, noise)) return true;
    }
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn field(value: std.json.Value, name: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const found = object.get(name) orelse return null;
    return switch (found) {
        .string => |string| string,
        else => null,
    };
}

fn fieldUint(value: std.json.Value, name: []const u8) ?usize {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const found = object.get(name) orelse return null;
    return switch (found) {
        .integer => |integer| if (integer < 0) null else std.math.cast(usize, integer),
        else => null,
    };
}

fn fieldBool(value: std.json.Value, name: []const u8) ?bool {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const found = object.get(name) orelse return null;
    return switch (found) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn report(gpa: std.mem.Allocator, outcome: Outcome, comptime format: []const u8, args: anytype) !Result {
    return .{ .content = try std.fmt.allocPrint(gpa, format, args), .is_error = outcome == .err };
}

test "unknown tool is an error" {
    const result = try run(std.testing.allocator, std.testing.io, "nope", "{}");
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "read of missing file reports an error" {
    const result = try run(std.testing.allocator, std.testing.io, "read",
        \\{"path":"/definitely/not/here.txt"}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "read paginates and points at the next offset" {
    const result = try run(std.testing.allocator, std.testing.io, "read",
        \\{"path":"build.zig.zon","limit":1}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "use offset=2 to continue") != null);
}

test "read rejects an offset past the end of the file" {
    const result = try run(std.testing.allocator, std.testing.io, "read",
        \\{"path":"build.zig.zon","offset":100000}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test applyEdit {
    const gpa = std.testing.allocator;

    const updated = try applyEdit(gpa, "one two three", "two", "2");
    defer gpa.free(updated);
    try std.testing.expectEqualStrings("one 2 three", updated);

    try std.testing.expectError(error.NotFound, applyEdit(gpa, "abc", "z", "y"));
    try std.testing.expectError(error.NotUnique, applyEdit(gpa, "a a a", "a", "b"));
    try std.testing.expectError(error.NotUnique, applyEdit(gpa, "aaa", "aa", "b"));
    try std.testing.expectError(error.EmptyOldText, applyEdit(gpa, "abc", "", "y"));
}

test "find matches files by glob under a directory" {
    const result = try run(std.testing.allocator, std.testing.io, "find",
        \\{"pattern":"**/glob.zig","path":"src"}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("src/agent/glob.zig", result.content);
}

test utf8FloorLength {
    try std.testing.expectEqual(@as(usize, 1), utf8FloorLength("a\xC3\xA9", 2));
    try std.testing.expectEqual(@as(usize, 3), utf8FloorLength("a\xC3\xA9", 3));
    try std.testing.expectEqual(@as(usize, 3), utf8FloorLength("a\xC3\xA9", 10));
    try std.testing.expectEqual(@as(usize, 0), utf8FloorLength("", 5));
}

test "grep finds a literal substring with a glob filter" {
    const result = try run(std.testing.allocator, std.testing.io, "grep",
        \\{"pattern":"pub fn match","path":"src","glob":"**/glob.zig"}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/agent/glob.zig:") != null);
}

test "grep is case-insensitive when asked" {
    const result = try run(std.testing.allocator, std.testing.io, "grep",
        \\{"pattern":"PUB FN MATCH","path":"src","glob":"**/glob.zig","ignore_case":true}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/agent/glob.zig:") != null);
}
