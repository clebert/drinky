const std = @import("std");

const Parser = @import("Parser.zig");

const Inlines = @This();

text: []const u8,
context: Context,
events: [Parser.events_max]Parser.Event = undefined,
events_len: usize = 0,
event_index: usize = 0,
styles: [3]usize = @splat(0),
maybe_code: ?Code = null,
start: usize = 0,
index: usize = 0,
done: bool = false,
queue: [4]Part = undefined,
queue_len: usize = 0,
queue_head: usize = 0,

pub const Context = enum { block, table };

pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    code: bool = false,
};

pub const Span = struct {
    bytes: []const u8,
    style: Style,
    url: ?[]const u8 = null,
};

pub const Link = struct {
    label: []const u8,
    url: []const u8,
    style: Style,
};

pub const Part = union(enum) {
    text: Span,
    link_open: Link,
    link_close: Style,
};

const Code = struct { end: usize, after: usize };

pub fn init(text: []const u8, context: Context) Inlines {
    var inlines: Inlines = .{ .text = text, .context = context };
    var parser: Parser = .{ .text = text, .events = &inlines.events };
    inlines.events_len = parser.run();
    return inlines;
}

pub fn next(self: *Inlines) ?Part {
    while (true) {
        while (self.queue_head < self.queue_len) {
            const part = self.queue[self.queue_head];
            self.queue_head += 1;
            if (part == .text and part.text.bytes.len == 0) continue;
            return part;
        }
        if (self.done) return null;
        self.queue_head = 0;
        self.queue_len = 0;
        self.step();
    }
}

pub fn unescape(url: []const u8, buffer: []u8) []const u8 {
    if (std.mem.findScalar(u8, url, '\\') == null) return url;
    var length: usize = 0;
    var index: usize = 0;
    while (index < url.len) : (index += 1) {
        if (url[index] == '\\' and Parser.escapeAt(url, index) != null) index += 1;
        if (length == buffer.len) return url;
        buffer[length] = url[index];
        length += 1;
    }
    return buffer[0..length];
}

pub fn sameUnescaped(left: []const u8, right: []const u8) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        if (left[left_index] == '\\' and Parser.escapeAt(left, left_index) != null) left_index += 1;
        if (right[right_index] == '\\' and Parser.escapeAt(right, right_index) != null) {
            right_index += 1;
        }
        if (left[left_index] != right[right_index]) return false;
        left_index += 1;
        right_index += 1;
    }
    return left_index == left.len and right_index == right.len;
}

fn step(self: *Inlines) void {
    if (self.maybe_code) |code| return self.stepCode(code);
    const text = self.text;
    const event_at = if (self.event_index < self.events_len)
        self.events[self.event_index].at
    else
        text.len;
    std.debug.assert(self.index <= event_at);
    if (self.index == event_at) {
        self.flush();
        if (self.event_index == self.events_len) {
            self.done = true;
            return;
        }
        self.apply(self.events[self.event_index]);
        self.event_index += 1;
        return;
    }
    const before_event = text[0..event_at];
    const candidate = std.mem.findAnyPos(u8, before_event, self.index, Parser.token_starts) orelse {
        self.index = event_at;
        return;
    };
    const token = Parser.tokenAt(text, candidate) orelse {
        self.index = candidate + 1;
        return;
    };
    self.index = candidate;
    if (token.kind == .literal) {
        self.index = token.after;
        return;
    }
    self.flush();
    switch (token.kind) {
        .literal => unreachable,
        .escape => self.start = token.start,
        .code => {
            self.maybe_code = .{ .end = token.end, .after = token.after };
            self.start = token.start;
        },
        .url => {
            const url = text[token.start..token.end];
            self.enqueue(&.{ .text = .{ .bytes = url, .style = self.style(), .url = url } });
            self.start = token.after;
        },
    }
    self.index = if (token.kind == .code) token.start else token.after;
}

fn stepCode(self: *Inlines, code: Code) void {
    var shown = self.style();
    shown.code = true;
    const content = self.text[0..code.end];
    const maybe_pipe = if (self.context == .table)
        std.mem.findPos(u8, content, self.index, "\\|")
    else
        null;
    if (maybe_pipe) |pipe| {
        self.enqueue(&.{ .text = .{ .bytes = content[self.index..pipe], .style = shown } });
        self.enqueue(&.{ .text = .{ .bytes = "|", .style = shown } });
        self.index = pipe + 2;
        return;
    }
    self.enqueue(&.{ .text = .{ .bytes = content[self.index..], .style = shown } });
    self.maybe_code = null;
    self.index = code.after;
    self.start = code.after;
}

fn apply(self: *Inlines, event: Parser.Event) void {
    switch (event.style) {
        .link => switch (event.side) {
            .open => self.openLink(event.at),
            .close => self.closeLink(event.at),
        },
        .emphasis, .strong, .strike => {
            const count = &self.styles[@backingInt(event.style)];
            switch (event.side) {
                .open => count.* += 1,
                .close => count.* -= 1,
            }
            self.index = event.at + event.width();
            self.start = self.index;
        },
    }
}

fn openLink(self: *Inlines, at: usize) void {
    const later = self.events[self.event_index + 1 .. self.events_len];
    const close_index = for (later, self.event_index + 1..) |event, index| {
        if (event.style == .link) break index;
    } else unreachable;
    const close = self.events[close_index].at;
    std.debug.assert(self.events[close_index].side == .close);
    const destination = Parser.destinationAt(self.text, close + 1) orelse unreachable;
    const label = self.text[at + 1 .. close];
    self.enqueue(&.{ .link_open = .{
        .label = label,
        .url = destination.url,
        .style = self.style(),
    } });
    if (label.len == 0) {
        self.enqueue(&.{ .link_close = self.style() });
        self.event_index = close_index;
        self.index = destination.after;
        self.start = self.index;
        return;
    }
    self.index = at + 1;
    self.start = self.index;
}

fn closeLink(self: *Inlines, at: usize) void {
    self.enqueue(&.{ .link_close = self.style() });
    const destination = Parser.destinationAt(self.text, at + 1) orelse unreachable;
    self.index = destination.after;
    self.start = self.index;
}

fn style(self: *const Inlines) Style {
    return .{
        .italic = self.styles[@backingInt(Parser.Event.Style.emphasis)] > 0,
        .bold = self.styles[@backingInt(Parser.Event.Style.strong)] > 0,
        .strike = self.styles[@backingInt(Parser.Event.Style.strike)] > 0,
    };
}

fn flush(self: *Inlines) void {
    self.enqueue(&.{ .text = .{
        .bytes = self.text[self.start..self.index],
        .style = self.style(),
    } });
    self.start = self.index;
}

fn enqueue(self: *Inlines, part: *const Part) void {
    self.queue[self.queue_len] = part.*;
    self.queue_len += 1;
}

test "inline spans retain nested styles and code" {
    var inlines: Inlines = .init("***both*** and `code`", .block);
    const first = inlines.next().?.text;
    try std.testing.expectEqualStrings("both", first.bytes);
    try std.testing.expect(first.style.bold and first.style.italic);
    try std.testing.expect(!first.style.code);
    try std.testing.expectEqualStrings(" and ", inlines.next().?.text.bytes);
    const code = inlines.next().?.text;
    try std.testing.expectEqualStrings("code", code.bytes);
    try std.testing.expect(code.style.code);
    try std.testing.expect(!code.style.bold and !code.style.italic);
    try std.testing.expect(inlines.next() == null);
}

fn expectText(text: []const u8, context: Context, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(gpa);
    var inlines: Inlines = .init(text, context);
    while (inlines.next()) |part| {
        if (part == .text) try shown.appendSlice(gpa, part.text.bytes);
    }
    try std.testing.expectEqualStrings(expected, shown.items);
}

test "links expose raw destinations and balanced boundaries" {
    var inlines: Inlines = .init("**[a `]` b](./x\\_y.md \"title\")**", .block);
    const link = inlines.next().?.link_open;
    try std.testing.expectEqualStrings("a `]` b", link.label);
    try std.testing.expectEqualStrings("./x\\_y.md", link.url);
    try std.testing.expect(link.style.bold);
    try std.testing.expectEqualStrings("a ", inlines.next().?.text.bytes);
    const code = inlines.next().?.text;
    try std.testing.expectEqualStrings("]", code.bytes);
    try std.testing.expect(code.style.bold and code.style.code);
    try std.testing.expectEqualStrings(" b", inlines.next().?.text.bytes);
    try std.testing.expect(inlines.next().?.link_close.bold);
    try std.testing.expect(inlines.next() == null);
}

test "empty labels expose boundaries without replacement text" {
    var inlines: Inlines = .init("[](javascript:x) and [a]()", .block);
    const empty = inlines.next().?.link_open;
    try std.testing.expectEqualStrings("", empty.label);
    try std.testing.expectEqualStrings("javascript:x", empty.url);
    try std.testing.expect(inlines.next().? == .link_close);
    try std.testing.expectEqualStrings(" and ", inlines.next().?.text.bytes);
    const link = inlines.next().?.link_open;
    try std.testing.expectEqualStrings("", link.url);
    try std.testing.expectEqualStrings("a", inlines.next().?.text.bytes);
    try std.testing.expect(inlines.next().? == .link_close);
    try std.testing.expect(inlines.next() == null);
}

test "the parser retains destinations that a terminal cannot link" {
    inline for ([_][]const u8{ "./x.md", "javascript:x", "https://x.y/é", "" }) |url| {
        var inlines: Inlines = .init("[a](" ++ url ++ ")", .block);
        try std.testing.expectEqualStrings(url, inlines.next().?.link_open.url);
        try std.testing.expectEqualStrings("a", inlines.next().?.text.bytes);
        try std.testing.expect(inlines.next().? == .link_close);
        try std.testing.expect(inlines.next() == null);
    }
}

test "URL escapes use caller storage and preserve the source when it does not fit" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a_b.md", unescape("a\\_b.md", &buffer));
    try std.testing.expectEqualStrings("a\\_b.md", unescape("a\\_b.md", buffer[0..2]));
    try std.testing.expectEqualStrings("a\\z", unescape("a\\z", &buffer));
    try std.testing.expect(sameUnescaped("a_b.md", "a\\_b.md"));
    try std.testing.expect(sameUnescaped("a\\_b.md", "a_b.md"));
    try std.testing.expect(!sameUnescaped("a_b.md", "a\\_c.md"));
    try std.testing.expect(!sameUnescaped("a", "ab"));
}

test "a code span removes escaped pipes only in a table cell" {
    try expectText("`cat \\| grep`", .block, "cat \\| grep");
    try expectText("`cat \\| grep`", .table, "cat | grep");
    try expectText("`` `a` ``", .block, "`a`");
    try expectText("` `", .block, " ");
}

test "a code span delimiter holds at most eight backticks" {
    try expectText("a ````````x```````` b", .block, "a x b");
    try expectText("a `````````x````````` b", .block, "a `````````x````````` b");
}

test "a full delimiter stack leaves later marks literal" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..256) |_| try text.appendSlice(gpa, "*a ");
    try text.appendSlice(gpa, "*b*");
    var inlines: Inlines = .init(text.items, .block);
    while (inlines.next()) |part| {
        try std.testing.expect(part == .text);
        try std.testing.expect(!part.text.style.italic);
    }
    try expectText(text.items, .block, text.items);
}

test "a line with more links than the event buffer keeps its last links literal" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..130) |_| try text.appendSlice(gpa, "[a](b) ");
    var inlines: Inlines = .init(text.items, .block);
    var opened: usize = 0;
    var closed: usize = 0;
    var literal: std.ArrayList(u8) = .empty;
    defer literal.deinit(gpa);
    while (inlines.next()) |part| switch (part) {
        .link_open => opened += 1,
        .link_close => closed += 1,
        .text => |span| try literal.appendSlice(gpa, span.bytes),
    };
    try std.testing.expectEqual(@as(usize, 128), opened);
    try std.testing.expectEqual(opened, closed);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, literal.items, "[a](b)"));
    try std.testing.expect(std.mem.endsWith(u8, literal.items, "a [a](b) [a](b) "));
}

test "a full bracket stack forgets its oldest open bracket" {
    const opened: [70]u8 = @splat('[');
    try expectText(opened ++ "[a](https://x.y)", .block, opened ++ "a");
}

test "autolinks retain their destinations without a terminal policy" {
    var inlines: Inlines = .init("<custom:target> https://x.y/(a)),", .block);
    const custom = inlines.next().?.text;
    try std.testing.expectEqualStrings("custom:target", custom.bytes);
    try std.testing.expectEqualStrings(custom.bytes, custom.url.?);
    try std.testing.expectEqualStrings(" ", inlines.next().?.text.bytes);
    const bare = inlines.next().?.text;
    try std.testing.expectEqualStrings("https://x.y/(a)", bare.url.?);
    try std.testing.expectEqualStrings("),", inlines.next().?.text.bytes);
    try std.testing.expect(inlines.next() == null);
}

fn parsedInline(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    var writer: CorpusWriter = .{ .arena = arena };
    var inlines: Inlines = .init(line, .block);
    var href: ?[]const u8 = null;
    while (inlines.next()) |part| switch (part) {
        .link_open => |link| {
            const buffer = try arena.alloc(u8, link.url.len);
            href = unescape(link.url, buffer);
        },
        .link_close => href = null,
        .text => |span| try writer.text(&.{
            .href = span.url orelse href,
            .strong = span.style.bold,
            .emphasis = span.style.italic,
            .code = span.style.code,
        }, span.bytes),
    };
    return try writer.finish();
}

test "inline syntax matches the CommonMark example corpus" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const examples = try std.json.parseFromSliceLeaky(
        []const CorpusExample,
        arena,
        @embedFile("commonmark_spec.json"),
        .{ .ignore_unknown_fields = true },
    );
    var example_arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer example_arena_state.deinit();
    const example_arena = example_arena_state.allocator();
    var checked: usize = 0;
    var mismatches: usize = 0;
    for (examples) |*example| {
        defer _ = example_arena_state.reset(.retain_capacity);
        const line = corpusLine(example) orelse continue;
        const expected = try expectedInline(example_arena, &.{
            .html = example.html,
            .markdown = line,
        }) orelse continue;
        const actual = try parsedInline(example_arena, line);
        const deviates = std.mem.findScalar(usize, &corpus_deviations, example.example) != null;
        checked += 1;
        if (std.mem.eql(u8, expected, actual) != deviates) continue;
        mismatches += 1;
        std.debug.print("CommonMark example {d} {s}: {s}\n  expected: {s}\n  parsed: {s}\n", .{
            example.example,
            if (deviates) "matches but is a listed deviation" else "differs",
            line,
            expected,
            actual,
        });
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    try std.testing.expect(checked >= 200);
}

const corpus_deviations = space_is_ascii ++
    bare_url_links ++ email_autolink_missing;

const space_is_ascii = [_]usize{353};
const bare_url_links = [_]usize{ 602, 608, 611 };
const email_autolink_missing = [_]usize{ 604, 605 };

const corpus_sections = [_][]const u8{
    "Backslash escapes",
    "Code spans",
    "Emphasis and strong emphasis",
    "Links",
    "Autolinks",
    "Textual content",
    "Inlines",
};

const CorpusExample = struct {
    markdown: []const u8,
    html: []const u8,
    example: usize,
    section: []const u8,
};

const CorpusMarks = struct {
    href: ?[]const u8 = null,
    strong: bool = false,
    emphasis: bool = false,
    code: bool = false,

    fn eql(self: *const CorpusMarks, other: *const CorpusMarks) bool {
        const same_href = if (self.href) |href|
            other.href != null and std.mem.eql(u8, href, other.href.?)
        else
            other.href == null;
        return same_href and self.strong == other.strong and
            self.emphasis == other.emphasis and self.code == other.code;
    }
};

const CorpusWriter = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    marks: CorpusMarks = .{},

    fn text(self: *CorpusWriter, marks: *const CorpusMarks, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (!self.marks.eql(marks)) {
            try self.close();
            try self.open(marks);
        }
        try self.out.appendSlice(self.arena, bytes);
    }

    fn open(self: *CorpusWriter, marks: *const CorpusMarks) !void {
        if (marks.href) |href| try self.out.print(self.arena, "<a href=\"{s}\">", .{href});
        if (marks.strong) try self.out.appendSlice(self.arena, "<strong>");
        if (marks.emphasis) try self.out.appendSlice(self.arena, "<em>");
        if (marks.code) try self.out.appendSlice(self.arena, "<code>");
        self.marks = marks.*;
    }

    fn close(self: *CorpusWriter) !void {
        if (self.marks.code) try self.out.appendSlice(self.arena, "</code>");
        if (self.marks.emphasis) try self.out.appendSlice(self.arena, "</em>");
        if (self.marks.strong) try self.out.appendSlice(self.arena, "</strong>");
        if (self.marks.href != null) try self.out.appendSlice(self.arena, "</a>");
        self.marks = .{};
    }

    fn finish(self: *CorpusWriter) ![]const u8 {
        self.out.items.len = std.mem.trimEnd(u8, self.out.items, " ").len;
        try self.close();
        return self.out.items;
    }
};

fn corpusLine(example: *const CorpusExample) ?[]const u8 {
    for (corpus_sections) |section| {
        if (std.mem.eql(u8, section, example.section)) break;
    } else return null;
    const markdown = std.mem.trimEnd(u8, example.markdown, "\n");
    if (std.mem.findScalar(u8, markdown, '\n') != null) return null;
    const html = example.html;
    if (!std.mem.startsWith(u8, html, "<p>") or !std.mem.endsWith(u8, html, "</p>\n")) return null;
    if (std.mem.count(u8, html, "\n") != 1) return null;
    var search: usize = 0;
    while (std.mem.findScalarPos(u8, markdown, search, '&')) |ampersand| {
        search = ampersand + 1;
        const maybe_end = std.mem.findNonePos(u8, markdown, search, entity_name_bytes);
        const end = maybe_end orelse continue;
        if (end > search and markdown[end] == ';') return null;
    }
    return std.mem.trim(u8, markdown, " \t");
}

const entity_name_bytes = "#0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn expectedInline(
    arena: std.mem.Allocator,
    example: *const struct { html: []const u8, markdown: []const u8 },
) !?[]const u8 {
    const html = example.html;
    const inner = html["<p>".len .. html.len - "</p>\n".len];
    var writer: CorpusWriter = .{ .arena = arena };
    var marks: CorpusMarks = .{};
    var strong_depth: usize = 0;
    var emphasis_depth: usize = 0;
    var index: usize = 0;
    while (index < inner.len) {
        if (inner[index] == '<') {
            const close = std.mem.findScalarPos(u8, inner, index, '>') orelse return null;
            const tag = inner[index + 1 .. close];
            index = close + 1;
            if (std.mem.eql(u8, tag, "em")) {
                emphasis_depth += 1;
            } else if (std.mem.eql(u8, tag, "/em")) {
                emphasis_depth -= 1;
            } else if (std.mem.eql(u8, tag, "strong")) {
                strong_depth += 1;
            } else if (std.mem.eql(u8, tag, "/strong")) {
                strong_depth -= 1;
            } else if (std.mem.eql(u8, tag, "code")) {
                marks.code = true;
            } else if (std.mem.eql(u8, tag, "/code")) {
                marks.code = false;
            } else if (std.mem.startsWith(u8, tag, "a href=\"")) {
                if (std.mem.find(u8, example.markdown, tag) != null) return null;
                const start = "a href=\"".len;
                const end = std.mem.findScalarPos(u8, tag, start, '"') orelse return null;
                marks.href = try decodedHref(arena, tag[start..end]);
            } else if (std.mem.eql(u8, tag, "/a")) {
                marks.href = null;
            } else {
                return null;
            }
            marks.strong = strong_depth > 0;
            marks.emphasis = emphasis_depth > 0;
            continue;
        }
        const end = std.mem.findAnyPos(u8, inner, index, "<&\t") orelse inner.len;
        if (end > index) {
            try writer.text(&marks, inner[index..end]);
            index = end;
            continue;
        }
        if (inner[index] == '\t') {
            try writer.text(&marks, "\t");
            index += 1;
            continue;
        }
        const entity = htmlEntity(inner[index..]) orelse return null;
        try writer.text(&marks, entity.shown);
        index += entity.source.len;
    }
    return try writer.finish();
}

const HtmlEntity = struct { source: []const u8, shown: []const u8 };

fn htmlEntity(text: []const u8) ?HtmlEntity {
    const entities = [_]HtmlEntity{
        .{ .source = "&amp;", .shown = "&" },
        .{ .source = "&lt;", .shown = "<" },
        .{ .source = "&gt;", .shown = ">" },
        .{ .source = "&quot;", .shown = "\"" },
    };
    for (entities) |entity| if (std.mem.startsWith(u8, text, entity.source)) return entity;
    return null;
}

fn decodedHref(arena: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < encoded.len) {
        if (htmlEntity(encoded[index..])) |entity| {
            try out.appendSlice(arena, entity.shown);
            index += entity.source.len;
        } else if (encoded[index] == '%' and index + 2 < encoded.len) {
            const byte = std.fmt.parseInt(u8, encoded[index + 1 .. index + 3], 16) catch {
                try out.append(arena, '%');
                index += 1;
                continue;
            };
            try out.append(arena, byte);
            index += 3;
        } else {
            try out.append(arena, encoded[index]);
            index += 1;
        }
    }
    return out.items;
}
