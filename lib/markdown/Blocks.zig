const std = @import("std");

const Cells = @import("Cells.zig");

const Blocks = @This();

text: []const u8,
lines: std.mem.SplitIterator(u8, .scalar),
fence: ?Fence = null,

pub const table_columns_max = 16;

pub const Block = struct {
    line: []const u8,
    kind: Kind,

    pub const Kind = union(enum) {
        fence_open,
        fence_line,
        fence_close,
        blank,
        rule,
        table: TableRows,
        heading: Heading,
        quote: []const u8,
        list_item: ListItem,
        paragraph,
    };

    pub const Heading = struct {
        level: usize,
        body: []const u8,
    };

    pub const ListItem = struct {
        indentation: usize,
        marker: []const u8,
        task_box: ?[]const u8,
        body: []const u8,
    };

    pub const TableRows = struct {
        count: usize,
        delimiter: []const u8,
        body: []const u8,

        pub fn rows(self: *const TableRows) Rows {
            return .{ .rest = if (self.body.len == 0) null else self.body };
        }
    };

    pub const Rows = struct {
        rest: ?[]const u8,

        pub fn next(self: *Rows) ?[]const u8 {
            const rest = self.rest orelse return null;
            const end = std.mem.findScalar(u8, rest, '\n') orelse {
                self.rest = null;
                return rest;
            };
            self.rest = rest[end + 1 ..];
            return rest[0..end];
        }
    };
};

const Fence = struct {
    marker: u8,
    length: usize,

    fn open(line: []const u8) ?Fence {
        if (line.len < 3) return null;
        const marker = line[0];
        if (marker != '`' and marker != '~') return null;
        const length = markerLength(line, marker);
        if (length < 3) return null;
        if (marker == '`' and std.mem.findScalar(u8, line[length..], '`') != null) return null;
        return .{ .marker = marker, .length = length };
    }

    fn closes(self: Fence, line: []const u8) bool {
        if (line.len < self.length or line[0] != self.marker) return false;
        const length = markerLength(line, self.marker);
        return length >= self.length and std.mem.findNone(u8, line[length..], " \t\r\n") == null;
    }

    fn markerLength(line: []const u8, marker: u8) usize {
        var length: usize = 0;
        while (length < line.len and line[length] == marker) length += 1;
        return length;
    }
};

pub fn init(text: []const u8) Blocks {
    return .{ .text = text, .lines = std.mem.splitScalar(u8, text, '\n') };
}

pub fn peek(self: *Blocks) ?[]const u8 {
    return self.lines.peek();
}

pub fn offset(self: *const Blocks, line: []const u8) usize {
    return @intFromPtr(line.ptr) - @intFromPtr(self.text.ptr);
}

pub fn next(self: *Blocks) ?Block {
    const line = std.mem.trimEnd(u8, self.lines.next() orelse return null, "\r");
    const spaces = indentation(line);
    const rest = line[spaces..];
    if (self.fence) |fence| {
        if (spaces <= 3 and fence.closes(rest)) {
            self.fence = null;
            return .{ .line = line, .kind = .fence_close };
        }
        return .{ .line = line, .kind = .fence_line };
    }
    if (spaces <= 3) {
        if (Fence.open(rest)) |fence| {
            self.fence = fence;
            return .{ .line = line, .kind = .fence_open };
        }
    }
    if (std.mem.findNone(u8, rest, " \t\r\n") == null) return .{ .line = line, .kind = .blank };
    if (isRule(rest)) return .{ .line = line, .kind = .rule };
    if (self.table(rest)) |shape| return .{ .line = line, .kind = .{ .table = shape } };
    if (headingLevel(rest)) |level| return .{ .line = line, .kind = .{ .heading = .{
        .level = level,
        .body = std.mem.trimStart(u8, rest[level..], " "),
    } } };
    if (rest[0] == '>') return .{ .line = line, .kind = .{ .quote = quoteBody(rest) } };
    if (listMarker(rest)) |marker| {
        const body = rest[marker..];
        const task_box = taskBox(body);
        return .{ .line = line, .kind = .{ .list_item = .{
            .indentation = spaces,
            .marker = rest[0..marker],
            .task_box = task_box,
            .body = if (task_box) |box| body[box.len..] else body,
        } } };
    }
    return .{ .line = line, .kind = .paragraph };
}

fn table(self: *Blocks, header: []const u8) ?Block.TableRows {
    if (header[0] != '|') return null;
    const delimiter = std.mem.trimEnd(u8, self.lines.peek() orelse return null, "\r");
    if (!Cells.isDelimiter(delimiter)) return null;
    const count = Cells.count(header);
    if (count != Cells.count(delimiter) or count > table_columns_max) return null;
    _ = self.lines.next();
    var maybe_start: ?usize = null;
    var end: usize = 0;
    while (self.lines.peek()) |row| {
        if (!Cells.isRow(row)) break;
        _ = self.lines.next();
        if (maybe_start == null) maybe_start = self.offset(row);
        end = self.offset(row) + row.len;
    }
    const start = maybe_start orelse end;
    return .{ .count = count, .delimiter = delimiter, .body = self.text[start..end] };
}

fn quoteBody(rest: []const u8) []const u8 {
    var body = rest;
    while (body.len > 0 and body[0] == '>') {
        body = body[1..];
        if (body.len > 0 and body[0] == ' ') body = body[1..];
    }
    return body;
}

fn listMarker(rest: []const u8) ?usize {
    if ((rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and
        (rest.len == 1 or rest[1] == ' '))
    {
        return @min(rest.len, 2);
    }
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits == 0 or digits == rest.len) return null;
    if (rest[digits] != '.' and rest[digits] != ')') return null;
    if (digits + 1 < rest.len and rest[digits + 1] != ' ') return null;
    return @min(rest.len, digits + 2);
}

fn taskBox(body: []const u8) ?[]const u8 {
    if (body.len < 3 or body[0] != '[' or body[2] != ']') return null;
    if (body[1] != ' ' and body[1] != 'x' and body[1] != 'X') return null;
    if (body.len > 3 and body[3] != ' ') return null;
    return body[0..@min(body.len, 4)];
}

fn headingLevel(rest: []const u8) ?usize {
    var level: usize = 0;
    while (level < rest.len and rest[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < rest.len and rest[level] != ' ') return null;
    return level;
}

fn isRule(rest: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, rest, " \t\r");
    if (trimmed.len < 3) return false;
    const mark = trimmed[0];
    if (mark != '-' and mark != '*' and mark != '_') return false;
    for (trimmed) |byte| if (byte != mark) return false;
    return true;
}

pub fn indentation(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and line[index] == ' ') index += 1;
    return index;
}

test "fences close only with the same marker and enough characters" {
    try expectKinds("````markdown\n````", &.{ .fence_open, .fence_close });
    try expectKinds("````markdown\n```\n````tail\n~~~~\n`````  \nafter", &.{
        .fence_open, .fence_line, .fence_line, .fence_line, .fence_close, .paragraph,
    });
    try expectKinds("```lang`", &.{.paragraph});
    try expectKinds("~~~text\n```\n~~~~", &.{ .fence_open, .fence_line, .fence_close });
}

fn expectKinds(text: []const u8, expected: []const std.meta.Tag(Block.Kind)) !void {
    var blocks: Blocks = .init(text);
    for (expected) |kind| {
        try std.testing.expectEqual(kind, std.meta.activeTag(blocks.next().?.kind));
    }
    try std.testing.expect(blocks.next() == null);
}

test "a delimiter row is dashes with optional alignment colons" {
    for ([_][]const u8{
        "| a |\n| --- |",
        "| a |\n|-|",
        "| a | b | c |\n  | :--- | ---: | :-: |",
    }) |text| try expectKinds(text, &.{.table});
    for ([_][]const u8{ "| a |\n| --x |", "| a |\n|  |", "| a |\n| :: |", "| a |\n|" }) |text| {
        try expectKinds(text, &.{ .paragraph, .paragraph });
    }
    try expectKinds("| a |\n---", &.{ .paragraph, .rule });

    const headers = [_]struct { text: []const u8, count: usize }{
        .{ .text = "| a | b |", .count = 2 },
        .{ .text = "| a | b", .count = 2 },
        .{ .text = "|", .count = 1 },
        .{ .text = "| `a \\| b` | c |", .count = 2 },
        .{ .text = "| a \\| b | c |", .count = 2 },
        .{ .text = "| a | b\\|", .count = 2 },
        .{ .text = "| a \\\\| b | c |", .count = 3 },
    };
    for (headers) |header| {
        var text_buffer: [64]u8 = undefined;
        var text: std.Io.Writer = .fixed(&text_buffer);
        try text.print("{s}\n|", .{header.text});
        for (0..header.count) |_| try text.writeAll("-|");
        var blocks: Blocks = .init(text.buffered());
        try std.testing.expectEqual(header.count, blocks.next().?.kind.table.count);
    }
}

test "the block iterator retains each block and its source slices" {
    const text =
        \\```zig
        \\const a = 1;
        \\```
        \\
        \\---
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\| 3 | 4 |
        \\## Title
        \\> > quoted
        \\  - [x] done
        \\plain words
        \\```
        \\open
    ;
    var blocks: Blocks = .init(text);
    const expected = [_]std.meta.Tag(Block.Kind){
        .fence_open, .fence_line, .fence_close, .blank,     .rule,       .table,
        .heading,    .quote,      .list_item,   .paragraph, .fence_open, .fence_line,
    };
    for (expected) |kind| {
        const block = blocks.next().?;
        try std.testing.expectEqual(kind, std.meta.activeTag(block.kind));
        switch (block.kind) {
            .table => |*table_rows| {
                try std.testing.expectEqual(@as(usize, 2), table_rows.count);
                try std.testing.expectEqualStrings("|---|---|", table_rows.delimiter);
                var lines = table_rows.rows();
                try std.testing.expectEqualStrings("| 1 | 2 |", lines.next().?);
                try std.testing.expectEqualStrings("| 3 | 4 |", lines.next().?);
                try std.testing.expect(lines.next() == null);
            },
            .heading => |heading| {
                try std.testing.expectEqual(@as(usize, 2), heading.level);
                try std.testing.expectEqualStrings("Title", heading.body);
            },
            .quote => |body| try std.testing.expectEqualStrings("quoted", body),
            .list_item => |item| {
                try std.testing.expectEqual(@as(usize, 2), item.indentation);
                try std.testing.expectEqualStrings("[x] ", item.task_box.?);
                try std.testing.expectEqualStrings("done", item.body);
            },
            else => {},
        }
    }
    try std.testing.expect(blocks.next() == null);

    var bare: Blocks = .init("| a |\n|---|");
    const shape = bare.next().?.kind.table;
    var empty = shape.rows();
    try std.testing.expect(empty.next() == null);
}

test "source offsets retain CRLF bytes and table row positions" {
    var blocks: Blocks = .init("## Title\r\n| a |\r\n| - |\r\n| b |\r\nend");
    const heading = blocks.next().?;
    try std.testing.expectEqual(@as(usize, 0), blocks.offset(heading.line));
    try std.testing.expectEqualStrings("Title", heading.kind.heading.body);
    const table_block = blocks.next().?;
    try std.testing.expectEqual(@as(usize, 10), blocks.offset(table_block.line));
    const table_rows = table_block.kind.table;
    try std.testing.expectEqual(@as(usize, 17), blocks.offset(table_rows.delimiter));
    var table_lines = table_rows.rows();
    try std.testing.expectEqual(@as(usize, 24), blocks.offset(table_lines.next().?));
    try std.testing.expect(table_lines.next() == null);
    const last = blocks.next().?;
    try std.testing.expectEqual(@as(usize, 31), blocks.offset(last.line));
    try std.testing.expectEqualStrings("end", last.line);
    try std.testing.expect(blocks.next() == null);
}

test "list syntax retains marker spelling and indentation" {
    var blocks: Blocks = .init("                    * [X] done\n12) next\n+");
    const first = blocks.next().?.kind.list_item;
    try std.testing.expectEqual(@as(usize, 20), first.indentation);
    try std.testing.expectEqualStrings("* ", first.marker);
    try std.testing.expectEqualStrings("[X] ", first.task_box.?);
    try std.testing.expectEqualStrings("done", first.body);
    const second = blocks.next().?.kind.list_item;
    try std.testing.expectEqualStrings("12) ", second.marker);
    try std.testing.expectEqualStrings("next", second.body);
    try std.testing.expect(second.task_box == null);
    try std.testing.expectEqualStrings("+", blocks.next().?.kind.list_item.marker);
    try std.testing.expect(blocks.next() == null);
}

test "tables stop at sixteen columns without consuming later rows" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.append(gpa, '|');
    for (0..17) |_| try text.appendSlice(gpa, "a|");
    try text.appendSlice(gpa, "\n|");
    for (0..17) |_| try text.appendSlice(gpa, "-|");
    try text.appendSlice(gpa, "\n| a |\n|-|\n| b |");
    var blocks: Blocks = .init(text.items);
    try std.testing.expect(blocks.next().?.kind == .paragraph);
    try std.testing.expect(blocks.next().?.kind == .paragraph);
    const table_rows = blocks.next().?.kind.table;
    try std.testing.expectEqual(@as(usize, 1), table_rows.count);
    var table_lines = table_rows.rows();
    try std.testing.expectEqualStrings("| b |", table_lines.next().?);
    try std.testing.expect(table_lines.next() == null);
    try std.testing.expect(blocks.next() == null);
}
