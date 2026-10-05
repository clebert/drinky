const std = @import("std");

const zig_files = @import("zig_files.zig");

const Span = struct { start: usize, end: usize };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var fix = false;
    var roots: std.ArrayList([]const u8) = .empty;
    var arguments = try init.minimal.args.iterateAllocator(arena);
    _ = arguments.skip();
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--fix")) fix = true else try roots.append(arena, argument);
    }
    if (roots.items.len == 0) std.process.fatal("usage: comment_scan [--fix] path...", .{});

    var total: usize = 0;
    for (try zig_files.collect(arena, io, roots.items)) |path| {
        total += try scanFile(arena, io, path, fix);
    }
    if (total == 0) return;
    if (fix) {
        std.debug.print("comment_scan: removed {d} comments.\n", .{total});
        return;
    }
    std.debug.print(
        "comment_scan: found {d} comments. Run it with --fix to remove them.\n",
        .{total},
    );
    std.process.exit(1);
}

fn scanFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, fix: bool) !usize {
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0);
    var spans: std.ArrayList(Span) = .empty;
    try comments(arena, source, &spans);
    if (spans.items.len == 0) return 0;
    if (fix) {
        const stripped = try strip(arena, source, spans.items);
        try cwd.writeFile(io, .{ .sub_path = path, .data = stripped });
    } else for (spans.items) |span| {
        const line = 1 + std.mem.countScalar(u8, source[0..span.start], '\n');
        std.debug.print("{s}:{d}: {s}\n", .{ path, line, source[span.start..span.end] });
    }
    return spans.items.len;
}

fn comments(arena: std.mem.Allocator, source: [:0]const u8, spans: *std.ArrayList(Span)) !void {
    var tokenizer: std.zig.Tokenizer = .init(source);
    var gap_start = tokenizer.index;
    var token = tokenizer.next();
    try lineComments(arena, source, .{ .start = gap_start, .end = token.loc.start }, spans);
    while (token.tag != .eof) {
        switch (token.tag) {
            .doc_comment, .container_doc_comment => try spans.append(arena, .{
                .start = token.loc.start,
                .end = token.loc.end,
            }),
            else => {},
        }
        gap_start = token.loc.end;
        token = tokenizer.next();
        try lineComments(arena, source, .{ .start = gap_start, .end = token.loc.start }, spans);
    }
}

fn lineComments(
    arena: std.mem.Allocator,
    source: []const u8,
    gap: Span,
    spans: *std.ArrayList(Span),
) !void {
    const text = source[0..gap.end];
    var index = gap.start;
    while (std.mem.indexOfPos(u8, text, index, "//")) |start| {
        const line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse gap.end;
        const comment = std.mem.trimEnd(u8, text[start..line_end], "\r");
        try spans.append(arena, .{ .start = start, .end = start + comment.len });
        index = line_end;
    }
}

fn strip(arena: std.mem.Allocator, source: []const u8, spans: []const Span) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var kept_from: usize = 0;
    for (spans) |span| {
        const newline = std.mem.lastIndexOfScalar(u8, source[0..span.start], '\n');
        const line_start = if (newline) |index| index + 1 else 0;
        const code = std.mem.trimEnd(u8, source[line_start..span.start], " \t");
        const alone_on_line = code.len == 0;
        const ends_line = span.end < source.len and source[span.end] == '\n';
        const cut_start = if (alone_on_line) line_start else line_start + code.len;
        const cut_end = if (alone_on_line and ends_line) span.end + 1 else span.end;
        try output.appendSlice(arena, source[kept_from..cut_start]);
        kept_from = cut_end;
    }
    try output.appendSlice(arena, source[kept_from..]);
    return output.toOwnedSlice(arena);
}

fn expectComments(source: [:0]const u8, expected: []const []const u8) !void {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(std.testing.allocator);
    try comments(std.testing.allocator, source, &spans);
    try std.testing.expectEqual(expected.len, spans.items.len);
    for (expected, spans.items) |text, span| {
        try std.testing.expectEqualStrings(text, source[span.start..span.end]);
    }
}

fn expectStripped(source: [:0]const u8, expected: []const u8) !void {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(std.testing.allocator);
    try comments(std.testing.allocator, source, &spans);
    const stripped = try strip(std.testing.allocator, source, spans.items);
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings(expected, stripped);
}

test "a // inside a string literal is text" {
    try expectComments("const url = \"https://example.com\";\n", &.{});
    try expectComments(
        \\const text =
        \\    \\// not a comment
        \\;
        \\
    , &.{});
}

test "a doc comment is a comment" {
    const source = "/// The answer.\nconst answer = 42;\n";
    try expectComments(source, &.{"/// The answer."});
    try expectStripped(source, "const answer = 42;\n");
}

test "a container doc comment is a comment" {
    const source = "//! The module.\n\nconst std = @import(\"std\");\n";
    try expectComments(source, &.{"//! The module."});
    try expectStripped(source, "\nconst std = @import(\"std\");\n");
}

test "a zig fmt directive is a comment" {
    const source = "// zig fmt: off\nconst a = .{1,2};\n// zig fmt: on\n";
    try expectComments(source, &.{ "// zig fmt: off", "// zig fmt: on" });
    try expectStripped(source, "const a = .{1,2};\n");
}

test "a line comment leaves with its line or with the space before it" {
    const source = "const a = 1; // one\n    // two\nconst b = 2;\n";
    try expectComments(source, &.{ "// one", "// two" });
    try expectStripped(source, "const a = 1;\nconst b = 2;\n");
}

test "four slashes open a line comment" {
    try expectComments("//// not a doc comment\n", &.{"//// not a doc comment"});
}

test "a comment at the end of the file leaves" {
    try expectStripped("const a = 1;\n// tail", "const a = 1;\n");
}

test {
    std.testing.refAllDecls(@This());
}
