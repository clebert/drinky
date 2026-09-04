//! Telegram HTML from the Markdown of a transcript block, and the split of a
//! long text into messages. Telegram knows a few inline tags and no block
//! element, so a heading becomes a bold line, a list keeps its marker as text, a
//! quote becomes a `blockquote`, and a fence or a table becomes a `pre` block.
//! The renderer reads the source with the parser of the terminal renderer, so
//! both agree on what a marker means.
//!
//! A message holds at most 4096 characters after the entity parse, so the tags
//! are free. `Parts` splits the rendered HTML: between two top-level elements,
//! else on a line, else on a character inside a text node, never inside a tag or
//! a character reference. A part closes every open tag at its end, and the next
//! part opens them again, so a code block continues as a code block.

const std = @import("std");

const terminal = @import("terminal");

const ui = @import("../ui/root.zig");

/// The most characters one message holds after the entity parse. Telegram counts
/// them in UTF-16 units, so a symbol outside the basic plane counts two.
pub const message_units_max = 4096;

/// The line a horizontal rule becomes. A chat has no column budget, so the line
/// takes a fixed width.
const rule_text = "─" ** 12;

/// The blanks one nesting level of a list indents by.
const list_indent = "  ";

/// The bullet of an unordered item. A chat reads a dot better than a dash.
const bullet = "• ";

/// Write `text`, a Markdown source, as Telegram HTML.
pub fn render(out: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var breaks: Breaks = .{};
    var maybe_fence: ?ui.markdown.Fence = null;
    var quoting = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const indentation = ui.markdown.leading(line);
        const rest = line[indentation..];
        if (maybe_fence) |fence| {
            if (indentation <= 3 and fence.closes(rest)) {
                maybe_fence = null;
                try out.writeAll("</pre>");
            } else {
                try breaks.next(out);
                try escape(out, line);
            }
            continue;
        }
        const quote = rest.len > 0 and rest[0] == '>';
        if (quoting and !quote) {
            quoting = false;
            try out.writeAll("</blockquote>");
        }
        const maybe_open_fence = if (indentation <= 3) ui.markdown.Fence.open(rest) else null;
        if (maybe_open_fence) |fence| {
            maybe_fence = fence;
            try breaks.open(out, "<pre>");
        } else if (ui.markdown.isBlank(rest)) {
            try breaks.next(out);
        } else if (ui.markdown.isRule(rest)) {
            try breaks.next(out);
            try out.writeAll(rule_text);
        } else if (Table.detect(rest, lines.peek())) |detected| {
            var table = detected;
            try breaks.open(out, "<pre>");
            try table.render(out, &breaks, rest, &lines);
            try out.writeAll("</pre>");
        } else if (ui.markdown.headingLevel(rest)) |level| {
            try breaks.next(out);
            try out.writeAll("<b>");
            try inlines(out, std.mem.trimStart(u8, rest[level..], " "));
            try out.writeAll("</b>");
        } else if (quote) {
            if (!quoting) {
                quoting = true;
                try breaks.open(out, "<blockquote>");
            }
            var body = rest;
            while (body.len > 0 and body[0] == '>') {
                body = body[1..];
                if (body.len > 0 and body[0] == ' ') body = body[1..];
            }
            try breaks.next(out);
            try inlines(out, body);
        } else if (ui.markdown.listMarker(rest)) |marker| {
            try breaks.next(out);
            // Sources nest a list two spaces a level, and the terminal caps the
            // depth the same way.
            const depth: usize = @min(@divFloor(indentation, 2), 4);
            for (0..depth) |_| try out.writeAll(list_indent);
            if (marker.shown[0] == '-') {
                try out.writeAll(bullet);
            } else {
                try escape(out, marker.shown);
            }
            var body = rest[marker.source..];
            if (ui.markdown.taskBox(body)) |box| {
                try escape(out, box);
                body = body[box.len..];
            }
            try inlines(out, body);
        } else {
            try breaks.next(out);
            try inlines(out, line);
        }
    }
    if (maybe_fence != null) try out.writeAll("</pre>");
    if (quoting) try out.writeAll("</blockquote>");
}

/// Write `text` with the three bytes escaped that Telegram HTML reserves.
pub fn escape(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        else => try out.writeByte(byte),
    };
}

/// Write `text` as an attribute value, with the quote escaped too.
fn escapeAttribute(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '"' => try out.writeAll("&quot;"),
        else => try out.writeByte(byte),
    };
}

/// The line breaks between the lines of the output. Every line but the first
/// owes one break before it, and the first line inside a container owes none,
/// because the container tag opens on the line of its own.
const Breaks = struct {
    owed: bool = false,

    /// Start one line.
    fn next(self: *Breaks, out: *std.Io.Writer) !void {
        if (self.owed) try out.writeAll("\n");
        self.owed = true;
    }

    /// Start one container with `tag`. The first line inside follows it at once.
    fn open(self: *Breaks, out: *std.Io.Writer, tag: []const u8) !void {
        try self.next(out);
        try out.writeAll(tag);
        self.owed = false;
    }
};

/// Write the inline runs of `text` with their tags, and close every tag at the
/// end.
fn inlines(out: *std.Io.Writer, text: []const u8) !void {
    var scanner = ui.markdown.InlineScanner.init(.{}, text, .block);
    var open: Tags = .{};
    while (scanner.next()) |span| {
        const wanted = Tags.of(&span.look);
        try open.transition(out, &wanted);
        try escape(out, span.bytes);
    }
    try open.transition(out, &.{});
}

/// The inline tags one span takes. They nest in one fixed order, outermost
/// first, so a transition between two spans closes the innermost tags alone.
const Tags = struct {
    url: []const u8 = "",
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    code: bool = false,

    const Tag = enum { a, b, i, s, code };

    const order = [_]Tag{ .a, .b, .i, .s, .code };

    fn of(look: *const ui.markdown.Look) Tags {
        return .{
            .url = look.url,
            .bold = look.bold,
            .italic = look.italic,
            .strike = look.strike,
            .code = look.code,
        };
    }

    fn has(self: *const Tags, tag: Tag) bool {
        return switch (tag) {
            .a => self.url.len > 0,
            .b => self.bold,
            .i => self.italic,
            .s => self.strike,
            .code => self.code,
        };
    }

    /// Whether `tag` opens the same way in both sets. A link with another
    /// target is another tag.
    fn same(self: *const Tags, other: *const Tags, tag: Tag) bool {
        if (tag == .a) return std.mem.eql(u8, self.url, other.url);
        return self.has(tag) == other.has(tag);
    }

    /// Close what `next` lacks, innermost first, and open what it adds. The
    /// tags before the first difference stay open, so the nesting holds.
    fn transition(self: *Tags, out: *std.Io.Writer, next: *const Tags) !void {
        var keep: usize = 0;
        while (keep < order.len and self.same(next, order[keep])) keep += 1;
        var index = order.len;
        while (index > keep) {
            index -= 1;
            if (self.has(order[index])) try writeClose(out, order[index]);
        }
        for (order[keep..]) |tag| if (next.has(tag)) try next.writeOpen(out, tag);
        self.* = next.*;
    }

    fn writeOpen(self: *const Tags, out: *std.Io.Writer, tag: Tag) !void {
        if (tag == .a) {
            try out.writeAll("<a href=\"");
            try escapeAttribute(out, self.url);
            return out.writeAll("\">");
        }
        try out.print("<{s}>", .{@tagName(tag)});
    }

    fn writeClose(out: *std.Io.Writer, tag: Tag) !void {
        try out.print("</{s}>", .{@tagName(tag)});
    }
};

/// A pipe table as the text of a `pre` block: every cell without its inline
/// markers, padded to the width of its column, between pipes. One pass over the
/// rows measures the columns, and a second one writes them.
const Table = struct {
    count: usize,
    widths: [ui.markdown.Table.count_max]usize,

    /// The table that opens at `header` when `next_line` is its delimiter row.
    fn detect(header: []const u8, next_line: ?[]const u8) ?Table {
        if (!ui.markdown.Table.isRow(header)) return null;
        const delimiter = next_line orelse return null;
        if (!ui.markdown.Table.isDelimiter(delimiter)) return null;
        const count = ui.markdown.Table.cellCount(header);
        if (count != ui.markdown.Table.cellCount(delimiter)) return null;
        if (count > ui.markdown.Table.count_max) return null;
        return .{ .count = count, .widths = @splat(1) };
    }

    /// Write the table: the header, the delimiter, and every row that follows.
    /// `lines` stands after the header, and the table consumes its rows.
    fn render(
        self: *Table,
        out: *std.Io.Writer,
        breaks: *Breaks,
        header: []const u8,
        lines: *std.mem.SplitIterator(u8, .scalar),
    ) !void {
        self.measure(header);
        var ahead = lines.*;
        _ = ahead.next();
        while (ahead.peek()) |row| {
            if (!ui.markdown.Table.isRow(row)) break;
            _ = ahead.next();
            self.measure(row);
        }
        try breaks.next(out);
        try self.writeRow(out, header);
        _ = lines.next();
        try breaks.next(out);
        try self.writeDelimiter(out);
        while (lines.peek()) |row| {
            if (!ui.markdown.Table.isRow(row)) break;
            _ = lines.next();
            try breaks.next(out);
            try self.writeRow(out, row);
        }
    }

    /// Raise each column to the display width of its cell in `row`.
    fn measure(self: *Table, row: []const u8) void {
        var cells = ui.markdown.Table.Cells.init(row);
        for (self.widths[0..self.count]) |*width| {
            const cell = cells.next() orelse break;
            var scanner = ui.markdown.InlineScanner.init(.{}, cell, .table);
            var columns: usize = 0;
            while (scanner.next()) |span| columns += terminal.width.ofText(span.bytes);
            width.* = @max(width.*, columns);
        }
    }

    fn writeRow(self: *const Table, out: *std.Io.Writer, row: []const u8) !void {
        var cells = ui.markdown.Table.Cells.init(row);
        try out.writeAll("|");
        for (self.widths[0..self.count]) |width| {
            const cell = cells.next() orelse "";
            try out.writeAll(" ");
            var scanner = ui.markdown.InlineScanner.init(.{}, cell, .table);
            var columns: usize = 0;
            while (scanner.next()) |span| {
                try escape(out, span.bytes);
                columns += terminal.width.ofText(span.bytes);
            }
            try out.splatByteAll(' ', width -| columns);
            try out.writeAll(" |");
        }
    }

    fn writeDelimiter(self: *const Table, out: *std.Io.Writer) !void {
        try out.writeAll("|");
        for (self.widths[0..self.count]) |width| {
            try out.writeAll(" ");
            try out.splatByteAll('-', width);
            try out.writeAll(" |");
        }
    }
};

/// The messages one HTML text splits into, each inside `limit` characters after
/// the entity parse. A split falls between two top-level elements, else on a
/// line, else on a character inside a text node, never inside a tag or a
/// character reference. A part closes every open tag at its end, and the next
/// part opens them again.
pub const Parts = struct {
    html: []const u8,
    limit: usize,
    position: usize = 0,
    /// The tags open at `position`, outermost first.
    open: Stack = .{},
    done: bool = false,

    /// One message of the split. The caller frees the text.
    pub const Part = struct {
        text: []u8,
        /// Whether no part follows.
        last: bool,
    };

    /// The tags that can nest at once: the block containers and the inline
    /// tags of the renderer.
    const depth_max = 8;

    /// The open tags at one place, as their opening tags in the source.
    const Stack = struct {
        tags: [depth_max][]const u8 = undefined,
        len: usize = 0,

        fn push(self: *Stack, tag: []const u8) void {
            if (self.len == depth_max) return;
            self.tags[self.len] = tag;
            self.len += 1;
        }

        fn pop(self: *Stack) void {
            self.len -|= 1;
        }

        fn open(self: *const Stack) []const []const u8 {
            return self.tags[0..self.len];
        }
    };

    /// One place the text can split: where the part ends, where the next one
    /// resumes, and the tags open there.
    const Cut = struct {
        end: usize,
        resume_at: usize,
        open: Stack,
    };

    /// One token of the HTML: a tag, a character reference, a line break, or one
    /// character of text, with the characters it counts toward the limit.
    const Token = struct {
        len: usize,
        units: usize,
        kind: Kind,

        const Kind = enum { open_tag, close_tag, entity, newline, text };
    };

    pub fn init(html: []const u8, limit: usize) Parts {
        return .{ .html = html, .limit = limit };
    }

    /// The next part, or null once the text is spent. The caller frees the text.
    pub fn next(self: *Parts, gpa: std.mem.Allocator) !?Part {
        if (self.done) return null;
        // A line break between two top-level elements separates two messages
        // already, so a part never opens on one.
        while (self.open.len == 0 and self.position < self.html.len and
            self.html[self.position] == '\n') self.position += 1;
        const start = self.position;
        if (start == self.html.len) {
            self.done = true;
            return null;
        }
        var stack = self.open;
        var units: usize = 0;
        var element: ?Cut = null;
        var line: ?Cut = null;
        var character: ?Cut = null;
        var index = start;
        var maybe_cut: ?Cut = null;
        while (index < self.html.len) {
            const token = tokenAt(self.html, index);
            if (units + token.units > self.limit) {
                // A token that alone exceeds the limit still goes out, because a
                // part with nothing in it makes no progress.
                maybe_cut = element orelse line orelse character orelse
                    Cut{ .end = index + token.len, .resume_at = index + token.len, .open = stack };
                break;
            }
            units += token.units;
            const token_end = index + token.len;
            switch (token.kind) {
                .open_tag => stack.push(self.html[index..token_end]),
                .close_tag => stack.pop(),
                .newline => {
                    const cut: Cut = .{ .end = index, .resume_at = token_end, .open = stack };
                    if (stack.len == 0) element = cut else line = cut;
                },
                .entity, .text => character = .{ .end = token_end, .resume_at = token_end, .open = stack },
            }
            index = token_end;
        }
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        for (self.open.open()) |tag| try out.writer.writeAll(tag);
        const cut = maybe_cut orelse {
            try out.writer.writeAll(self.html[start..]);
            try writeClosers(&out.writer, &stack);
            self.position = self.html.len;
            self.done = true;
            return .{ .text = try out.toOwnedSlice(), .last = true };
        };
        const settled = self.settle(&cut);
        var body = self.html[start..settled.end];
        if (settled.open.len == 0) body = std.mem.trimEnd(u8, body, "\n");
        try out.writer.writeAll(body);
        try writeClosers(&out.writer, &settled.open);
        self.position = settled.resume_at;
        self.open = settled.open;
        return .{ .text = try out.toOwnedSlice(), .last = false };
    }

    /// Move `cut` past the closing tags that follow it at once, so the next part
    /// does not open a tag that closes on its first byte.
    fn settle(self: *const Parts, cut: *const Cut) Cut {
        var settled = cut.*;
        if (settled.resume_at != settled.end) return settled;
        while (settled.end + 1 < self.html.len and
            self.html[settled.end] == '<' and self.html[settled.end + 1] == '/')
        {
            const token = tokenAt(self.html, settled.end);
            settled.end += token.len;
            settled.open.pop();
        }
        settled.resume_at = settled.end;
        return settled;
    }

    /// Write the closing tag of every open tag, innermost first.
    fn writeClosers(out: *std.Io.Writer, stack: *const Stack) !void {
        var index = stack.len;
        while (index > 0) {
            index -= 1;
            const tag = stack.tags[index];
            const name_end = std.mem.indexOfAny(u8, tag, " >") orelse tag.len;
            try out.print("</{s}>", .{tag[1..name_end]});
        }
    }

    /// The token at `index`. The renderer wrote the HTML, so every tag closes
    /// with `>` and every ampersand opens a character reference.
    fn tokenAt(html: []const u8, index: usize) Token {
        const byte = html[index];
        if (byte == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, index, '>') orelse html.len - 1;
            const closing = index + 1 < html.len and html[index + 1] == '/';
            return .{
                .len = end + 1 - index,
                .units = 0,
                .kind = if (closing) .close_tag else .open_tag,
            };
        }
        if (byte == '&') {
            const end = std.mem.indexOfScalarPos(u8, html, index, ';') orelse html.len - 1;
            return .{ .len = end + 1 - index, .units = 1, .kind = .entity };
        }
        if (byte == '\n') return .{ .len = 1, .units = 1, .kind = .newline };
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        return .{
            .len = @min(length, html.len - index),
            // A symbol outside the basic plane takes two UTF-16 units.
            .units = if (length == 4) 2 else 1,
            .kind = .text,
        };
    }
};

fn expectRender(expected: []const u8, source: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, source);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a heading becomes a bold line, and the inline markers become tags" {
    try expectRender(
        "<b>Title</b>\nPlain <b>bold</b>, <i>italic</i>, <s>struck</s>, and <code>a &lt;b&gt;</code>.",
        "# Title\nPlain **bold**, *italic*, ~~struck~~, and `a <b>`.",
    );
    // Nested markers nest their tags, and the outer tag stays open across the
    // inner one.
    try expectRender(
        "<b>bold <i>both</i> bold</b>",
        "**bold _both_ bold**",
    );
}

test "a link takes its target as a tag, and a bare URL links itself" {
    try expectRender(
        "See <a href=\"https://example.com/?a=1&amp;b=2\">the docs</a> and " ++
            "<a href=\"https://example.com/bare\">https://example.com/bare</a>.",
        "See [the docs](https://example.com/?a=1&b=2) and https://example.com/bare.",
    );
    // A target the chat cannot open shows as text behind its label.
    try expectRender("a local (docs/x.md) file", "a [local](docs/x.md) file");
}

test "a list keeps its markers as text, and a quote becomes a blockquote" {
    try expectRender(
        "• first\n  • nested\n• [x] done\n3. third",
        "- first\n  - nested\n- [x] done\n3. third",
    );
    try expectRender(
        "before\n<blockquote>one\ntwo</blockquote>\nafter",
        "before\n> one\n> two\nafter",
    );
}

test "a fence becomes a pre block, and a rule becomes a line" {
    try expectRender(
        "text\n<pre>const a = 1 &lt; 2;\n\n  indented</pre>\n" ++ rule_text ++ "\nend",
        "text\n```zig\nconst a = 1 < 2;\n\n  indented\n```\n---\nend",
    );
    // A fence a stream has not closed yet still closes its block.
    try expectRender("<pre>open</pre>", "```\nopen");
}

test "a table becomes a pre block with padded cells" {
    try expectRender(
        "<pre>| Name | Value |\n| ---- | ----- |\n| a    | one   |\n| bb   | two   |</pre>\nAfter.",
        "| Name | Value |\n| :--- | ----: |\n| a | one |\n| bb | **two** |\nAfter.",
    );
    // A header with no delimiter row is a paragraph.
    try expectRender("| a | b |\ntext", "| a | b |\ntext");
}

fn collectParts(gpa: std.mem.Allocator, html: []const u8, limit: usize) !std.ArrayList([]u8) {
    var parts = Parts.init(html, limit);
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |part| gpa.free(part);
        list.deinit(gpa);
    }
    // The split consumes the text, so it ends inside its length.
    for (0..html.len + 1) |_| {
        const part = try parts.next(gpa) orelse break;
        try list.append(gpa, part.text);
        if (part.last) break;
    }
    return list;
}

fn expectParts(expected: []const []const u8, html: []const u8, limit: usize) !void {
    const gpa = std.testing.allocator;
    var list = try collectParts(gpa, html, limit);
    defer {
        for (list.items) |part| gpa.free(part);
        list.deinit(gpa);
    }
    try std.testing.expectEqual(expected.len, list.items.len);
    for (expected, list.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a text inside the limit is one part" {
    try expectParts(&.{"<b>short</b> text"}, "<b>short</b> text", 20);
    try expectParts(&.{}, "", 20);
}

test "a split falls between two top-level elements before it falls on a line" {
    // The pre holds a line break, but the break between the elements wins, and
    // the trailing break of the first part goes.
    try expectParts(
        &.{ "one two", "<pre>a\nb</pre>" },
        "one two\n<pre>a\nb</pre>",
        10,
    );
}

test "a split on a line closes the open tags and opens them again" {
    try expectParts(
        &.{ "<pre>line one</pre>", "<pre>line two</pre>" },
        "<pre>line one\nline two</pre>",
        12,
    );
    try expectParts(
        &.{ "<blockquote><b>a</b>\n<b>b</b></blockquote>", "<blockquote><b>c</b></blockquote>" },
        "<blockquote><b>a</b>\n<b>b</b>\n<b>c</b></blockquote>",
        4,
    );
}

test "a split on a character never falls inside a tag or a character reference" {
    try expectParts(
        &.{ "<b>ab</b>", "<b>cd</b>", "<b>ef</b>" },
        "<b>abcdef</b>",
        2,
    );
    // The reference counts one character and stays whole.
    try expectParts(&.{ "a&amp;", "b" }, "a&amp;b", 2);
    // A closing tag right after the cut moves into the part it closes, so no
    // part opens a tag that closes on its first byte.
    try expectParts(&.{ "x<b>y</b>", "z" }, "x<b>y</b>z", 2);
}

test "a symbol outside the basic plane counts two characters" {
    try expectParts(&.{ "😀", "a" }, "😀a", 2);
    try expectParts(&.{"ab"}, "ab", 2);
}
