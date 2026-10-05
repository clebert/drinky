const std = @import("std");

const terminal = @import("terminal");

const Message = @import("../Message.zig");
const ui = @import("../ui/root.zig");

pub const parse_mode = "HTML";

pub const message_units_max = 4096;

const rule_text = "─" ** 12;

const list_indent = "  ";

const bullet = "• ";

pub const Role = enum {
    information,
    warning,
    failure,
    note,

    pub fn of(severity: Message.Severity) Role {
        return switch (severity) {
            .information => .information,
            .warning => .warning,
            .failure => .failure,
        };
    }

    fn prefix(self: Role) []const u8 {
        return switch (self) {
            .information => ui.paint.NoticeStyle.of(.information).prefix,
            .warning => ui.paint.NoticeStyle.of(.warning).prefix,
            .failure => ui.paint.NoticeStyle.of(.failure).prefix,
            .note => ui.paint.NoticeStyle.note.prefix,
        };
    }
};

const Decoder = struct {
    source: []const u8,
    index: usize = 0,
    pending: []const u8 = "",

    fn next(self: *Decoder) ?u8 {
        if (self.pending.len == 0) self.advance();
        if (self.pending.len == 0) return null;
        const byte = self.pending[0];
        self.pending = self.pending[1..];
        return byte;
    }

    fn advance(self: *Decoder) void {
        while (self.index < self.source.len and self.source[self.index] == '<') {
            const end = std.mem.indexOfScalarPos(u8, self.source, self.index, '>') orelse
                self.source.len - 1;
            self.index = end + 1;
        }
        if (self.index == self.source.len) return;
        const start = self.index;
        if (self.source[start] == '&') {
            const end = std.mem.indexOfScalarPos(u8, self.source, start, ';') orelse
                self.source.len - 1;
            self.index = end + 1;
            const reference = self.source[start..self.index];
            self.pending = decodeReference(reference) orelse reference;
            return;
        }
        self.index += 1;
        self.pending = self.source[start..self.index];
    }
};

const Link = struct {
    start: usize,
    end: usize,
    url: []const u8,
    label: []const u8,

    const open = "<a href=\"";
    const close = "\">";
    const end_tag = "</a>";

    fn find(source: []const u8) ?Link {
        const start = std.mem.indexOf(u8, source, open) orelse return null;
        const url_start = start + open.len;
        const url_end = std.mem.indexOfScalarPos(u8, source, url_start, '"') orelse return null;
        if (!std.mem.startsWith(u8, source[url_end..], close)) return null;
        const label_start = url_end + close.len;
        const label_end = std.mem.indexOfPos(u8, source, label_start, end_tag) orelse return null;
        return .{
            .start = start,
            .end = label_end + end_tag.len,
            .url = source[url_start..url_end],
            .label = source[label_start..label_end],
        };
    }

    fn bare(self: *const Link) bool {
        var label: Decoder = .{ .source = self.label };
        var url: Decoder = .{ .source = self.url };
        while (label.next()) |byte| {
            if (url.next() != byte) return false;
        }
        return url.next() == null;
    }
};

const Breaks = struct {
    owed: bool = false,

    fn next(self: *Breaks, out: *std.Io.Writer) !void {
        if (self.owed) try out.writeAll("\n");
        self.owed = true;
    }

    fn open(self: *Breaks, out: *std.Io.Writer, tag: []const u8) !void {
        try self.next(out);
        try out.writeAll(tag);
        self.owed = false;
    }
};

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

    fn same(self: *const Tags, other: *const Tags, tag: Tag) bool {
        if (tag == .a) return std.mem.eql(u8, self.url, other.url);
        return self.has(tag) == other.has(tag);
    }

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

pub const Parts = struct {
    html: []const u8,
    limit: usize,
    position: usize = 0,
    open: Stack = .{},
    done: bool = false,

    const depth_max = 8;

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

    const Cut = struct {
        end: usize,
        resume_at: usize,
        open: Stack,
    };

    const Token = struct {
        len: usize,
        units: usize,
        kind: Kind,

        const Kind = enum { open_tag, close_tag, entity, newline, text };
    };

    const Part = struct {
        opening: *const Stack,
        body: []const u8,
        closing: *const Stack,

        fn alloc(self: *const Part, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
            var out: std.Io.Writer.Allocating = .init(gpa);
            errdefer out.deinit();
            self.write(&out.writer) catch return error.OutOfMemory;
            return out.toOwnedSlice();
        }

        fn write(self: *const Part, out: *std.Io.Writer) std.Io.Writer.Error!void {
            for (self.opening.open()) |tag| try out.writeAll(tag);
            try out.writeAll(self.body);
            try writeClosers(out, self.closing);
        }
    };

    pub fn init(html: []const u8, limit: usize) Parts {
        return .{ .html = html, .limit = limit };
    }

    pub fn next(self: *Parts, gpa: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
        if (self.done) return null;
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
                .entity, .text => character = .{
                    .end = token_end,
                    .resume_at = token_end,
                    .open = stack,
                },
            }
            index = token_end;
        }
        const cut = maybe_cut orelse {
            const whole: Part = .{
                .opening = &self.open,
                .body = self.html[start..],
                .closing = &stack,
            };
            const text = try whole.alloc(gpa);
            self.position = self.html.len;
            self.done = true;
            return text;
        };
        const settled = self.settle(&cut);
        var body = self.html[start..settled.end];
        if (settled.open.len == 0) body = std.mem.trimEnd(u8, body, "\n");
        const part: Part = .{ .opening = &self.open, .body = body, .closing = &settled.open };
        const text = try part.alloc(gpa);
        self.position = settled.resume_at;
        self.open = settled.open;
        return text;
    }

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

    fn writeClosers(out: *std.Io.Writer, stack: *const Stack) !void {
        var index = stack.len;
        while (index > 0) {
            index -= 1;
            const tag = stack.tags[index];
            const name_end = std.mem.indexOfAny(u8, tag, " >") orelse tag.len;
            try out.print("</{s}>", .{tag[1..name_end]});
        }
    }

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
            .units = if (length == 4) 2 else 1,
            .kind = .text,
        };
    }
};

pub fn render(out: *std.Io.Writer, text: []const u8) !void {
    var blocks: ui.markdown.Blocks = .init(text);
    var breaks: Breaks = .{};
    var quoting = false;
    while (blocks.next()) |block| {
        if (quoting and closesQuote(&block.kind)) {
            quoting = false;
            try out.writeAll("</blockquote>");
        }
        switch (block.kind) {
            .fence_open => try breaks.open(out, "<pre>"),
            .fence_line => {
                try breaks.next(out);
                try escape(out, block.line);
            },
            .fence_close => try out.writeAll("</pre>"),
            .blank => try breaks.next(out),
            .rule => {
                try breaks.next(out);
                try out.writeAll(rule_text);
            },
            .table => |*rows| {
                try breaks.open(out, "<pre>");
                try writeTable(out, &breaks, block.line, rows);
                try out.writeAll("</pre>");
            },
            .heading => |heading| {
                try breaks.next(out);
                try out.writeAll("<b>");
                try inlines(out, heading.body);
                try out.writeAll("</b>");
            },
            .quote => |body| {
                if (!quoting) {
                    quoting = true;
                    try breaks.open(out, "<blockquote>");
                }
                try breaks.next(out);
                try inlines(out, body);
            },
            .list_item => |item| {
                try breaks.next(out);
                for (0..item.depth) |_| try out.writeAll(list_indent);
                if (item.marker.shown[0] == '-') {
                    try out.writeAll(bullet);
                } else {
                    try escape(out, item.marker.shown);
                }
                if (item.task_box) |box| try escape(out, box);
                try inlines(out, item.body);
            },
            .paragraph => {
                try breaks.next(out);
                try inlines(out, block.line);
            },
        }
    }
    if (blocks.fenced()) try out.writeAll("</pre>");
    if (quoting) try out.writeAll("</blockquote>");
}

fn closesQuote(kind: *const ui.markdown.Block.Kind) bool {
    return switch (kind.*) {
        .quote, .fence_line, .fence_close => false,
        .fence_open, .blank, .rule, .table, .heading, .list_item, .paragraph => true,
    };
}

pub fn notice(out: *std.Io.Writer, role: Role, text: []const u8) !void {
    try out.writeAll(role.prefix());
    try escape(out, text);
}

pub fn noticeAlloc(gpa: std.mem.Allocator, role: Role, text: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    notice(&out.writer, role, text) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn plain(out: *std.Io.Writer, source: []const u8) !void {
    var rest = source;
    while (rest.len > 0) {
        const link = Link.find(rest) orelse {
            try plainText(out, rest);
            break;
        };
        try plainText(out, rest[0..link.start]);
        try plainText(out, link.label);
        if (!link.bare()) {
            try out.writeAll(" (");
            try plainText(out, link.url);
            try out.writeAll(")");
        }
        rest = rest[link.end..];
    }
}

pub fn plainAlloc(gpa: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    plain(&out.writer, source) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn plainText(out: *std.Io.Writer, source: []const u8) !void {
    var decoder: Decoder = .{ .source = source };
    while (decoder.next()) |byte| try out.writeByte(byte);
}

const references = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "&amp;", .text = "&" },
    .{ .name = "&lt;", .text = "<" },
    .{ .name = "&gt;", .text = ">" },
    .{ .name = "&quot;", .text = "\"" },
};

fn decodeReference(reference: []const u8) ?[]const u8 {
    for (references) |entry| if (std.mem.eql(u8, entry.name, reference)) return entry.text;
    return null;
}

fn escape(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        else => try out.writeByte(byte),
    };
}

fn escapeAttribute(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '"' => try out.writeAll("&quot;"),
        else => try out.writeByte(byte),
    };
}

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

fn writeTable(
    out: *std.Io.Writer,
    breaks: *Breaks,
    header: []const u8,
    rows: *const ui.markdown.Block.TableRows,
) !void {
    var buffer: [ui.markdown.Table.count_max]usize = @splat(1);
    const widths = buffer[0..rows.count];
    ui.markdown.Table.measureRow(widths, header);
    var measured = rows.rows();
    while (measured.next()) |row| ui.markdown.Table.measureRow(widths, row);
    try breaks.next(out);
    try writeTableRow(out, widths, header);
    try breaks.next(out);
    try out.writeAll("|");
    for (widths) |width| {
        try out.writeAll(" ");
        try out.splatByteAll('-', width);
        try out.writeAll(" |");
    }
    var written = rows.rows();
    while (written.next()) |row| {
        try breaks.next(out);
        try writeTableRow(out, widths, row);
    }
}

fn writeTableRow(out: *std.Io.Writer, widths: []const usize, row: []const u8) !void {
    var cells = ui.markdown.Table.Cells.init(row);
    try out.writeAll("|");
    for (widths) |width| {
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

test "a message of Drinky takes the symbol of its role before its text" {
    const gpa = std.testing.allocator;
    const information = try noticeAlloc(gpa, .information, "Drinky now uses claude-opus-5.");
    defer gpa.free(information);
    try std.testing.expectEqualStrings("ℹ Drinky now uses claude-opus-5.", information);
    const warning_text = "The command /login runs in the terminal alone.";
    const warning = try noticeAlloc(gpa, .warning, warning_text);
    defer gpa.free(warning);
    try std.testing.expectEqualStrings("⚠ The command /login runs in the terminal alone.", warning);
    const failure = try noticeAlloc(gpa, .failure, "Telegram rejected <a> & more.");
    defer gpa.free(failure);
    try std.testing.expectEqualStrings("⚠ Telegram rejected &lt;a&gt; &amp; more.", failure);
    const note = try noticeAlloc(gpa, .note, "Skill: zig-style");
    defer gpa.free(note);
    try std.testing.expectEqualStrings("→ Skill: zig-style", note);
}

fn expectRender(expected: []const u8, source: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, source);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a split message of Drinky carries its symbol on the first part alone" {
    const gpa = std.testing.allocator;
    const message = try noticeAlloc(gpa, .information, "one two three four five six seven eight");
    defer gpa.free(message);
    var list = try collectParts(gpa, message, 20);
    defer {
        for (list.items) |part| gpa.free(part);
        list.deinit(gpa);
    }
    const expected = [_][]const u8{ "ℹ one two three four", " five six seven eigh", "t" };
    try std.testing.expectEqual(expected.len, list.items.len);
    for (expected, list.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "the plain text of a message keeps its symbol and its literal text" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { html: []const u8, plain: []const u8 }{
        .{
            .html = "⚠ Telegram rejected &lt;b&gt; &amp; more.",
            .plain = "⚠ Telegram rejected <b> & more.",
        },
        .{
            .html = "a &amp;lt;b&amp;gt; c &quot;quoted&quot;",
            .plain = "a &lt;b&gt; c \"quoted\"",
        },
        .{
            .html = "See <a href=\"https://example.com/?a=1&amp;b=2\">the docs</a>.",
            .plain = "See the docs (https://example.com/?a=1&b=2).",
        },
        .{
            .html = "<a href=\"https://example.com\"><b>docs</b></a>, <i>then</i> " ++
                "<a href=\"https://example.com/2\">more</a>",
            .plain = "docs (https://example.com), then more (https://example.com/2)",
        },
        .{
            .html = "<a href=\"https://example.com/bare\">https://example.com/bare</a> and " ++
                "<a href=\"https://x.test/?q=&quot;a&quot;\"><b>https://x.test/?q=\"a\"</b></a>",
            .plain = "https://example.com/bare and https://x.test/?q=\"a\"",
        },
        .{
            .html = "<pre>const a = 1 &lt; 2;\n\n  indented</pre>\nend",
            .plain = "const a = 1 < 2;\n\n  indented\nend",
        },
        .{ .html = "", .plain = "" },
    };
    for (cases) |case| {
        const text = try plainAlloc(gpa, case.html);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(case.plain, text);
    }
}

test "a heading becomes a bold line, and the inline markers become tags" {
    try expectRender(
        "<b>Title</b>\nPlain <b>bold</b>, <i>italic</i>, <s>struck</s>, " ++
            "and <code>a &lt;b&gt;</code>.",
        "# Title\nPlain **bold**, *italic*, ~~struck~~, and `a <b>`.",
    );
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
    try expectRender("<pre>open</pre>", "```\nopen");
}

test "a table becomes a pre block with padded cells" {
    try expectRender(
        "<pre>| Name | Value |\n| ---- | ----- |\n| a    | one   |\n| bb   | two   |</pre>\nAfter.",
        "| Name | Value |\n| :--- | ----: |\n| a | one |\n| bb | **two** |\nAfter.",
    );
    try expectRender("| a | b |\ntext", "| a | b |\ntext");
}

fn collectParts(gpa: std.mem.Allocator, html: []const u8, limit: usize) !std.ArrayList([]u8) {
    var parts = Parts.init(html, limit);
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |part| gpa.free(part);
        list.deinit(gpa);
    }
    for (0..html.len + 1) |_| {
        const part = try parts.next(gpa) orelse break;
        try list.append(gpa, part);
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
    try expectParts(&.{ "a&amp;", "b" }, "a&amp;b", 2);
    try expectParts(&.{ "x<b>y</b>", "z" }, "x<b>y</b>z", 2);
}

test "a symbol outside the basic plane counts two characters" {
    try expectParts(&.{ "😀", "a" }, "😀a", 2);
    try expectParts(&.{"ab"}, "ab", 2);
}
