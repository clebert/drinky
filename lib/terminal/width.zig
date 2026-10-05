const std = @import("std");

const grapheme = @import("grapheme.zig");

pub const Wrapper = struct {
    text: []const u8,
    columns_max: usize,
    line_start: usize,
    done: bool,

    pub const Span = struct { start: usize, end: usize };

    pub fn next(self: *Wrapper) ?[]const u8 {
        const span = self.nextSpan() orelse return null;
        return rowText(self.text[span.start..span.end]);
    }

    pub fn nextSpan(self: *Wrapper) ?Span {
        if (self.done) return null;
        const text = self.text;
        const start = self.line_start;
        var columns: usize = 0;
        var index = start;
        while (index < text.len) {
            if (displayUnit(text[index..]).kind == .line_break) {
                self.line_start = index + 1;
                return .{ .start = start, .end = index };
            }
            const word = nextWord(text[index..], self.columns_max);
            std.debug.assert(word.bytes > 0);
            if (columns + word.columns > self.columns_max) {
                if (index > start) {
                    self.line_start = index;
                    return .{ .start = start, .end = index };
                }
                const cut = truncate(text[index..], self.columns_max);
                std.debug.assert(cut.len > 0);
                self.line_start = index + cut.len;
                return .{ .start = start, .end = self.line_start };
            }
            columns += word.columns + word.blank_columns;
            index += word.bytes;
        }
        self.done = true;
        return .{ .start = start, .end = text.len };
    }
};

const Caret = struct {
    row: usize,
    column: usize,

    const Options = struct { offset: usize, columns_max: usize };
};

const Word = struct { bytes: usize, columns: usize, blank_columns: usize };

const UnitKind = enum { text, tab, replacement, line_break };

const DisplayUnit = struct {
    bytes: usize,
    columns: usize,
    kind: UnitKind,
};

pub const grapheme_boundary = "\u{200B}";

const replacement = grapheme_boundary ++ "�" ++ grapheme_boundary;

pub fn ofText(text: []const u8) usize {
    return fittedWidth(text, std.math.maxInt(usize));
}

pub fn truncate(text: []const u8, columns_max: usize) []const u8 {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const unit = displayUnit(text[index..]);
        const unit_columns = fittedColumns(&unit, columns_max);
        if (unit.kind == .line_break or (unit.columns > 0 and unit_columns == 0) or
            columns + unit_columns > columns_max) break;
        columns += unit_columns;
        index += unit.bytes;
    }
    return text[0..index];
}

pub fn writeFitted(writer: *std.Io.Writer, text: []const u8, columns_max: usize) !usize {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const unit = displayUnit(text[index..]);
        const columns_available = columns_max -| columns;
        const unit_columns = fittedColumns(&unit, columns_available);
        switch (unit.kind) {
            .text => if (unit.columns == 0 or unit.columns <= columns_available) {
                try writer.writeAll(text[index..][0..unit.bytes]);
            } else if (unit_columns > 0) {
                try writer.writeAll(replacement);
            },
            .tab => if (unit_columns > 0)
                try writer.writeAll(grapheme_boundary ++ " " ++ grapheme_boundary),
            .replacement => if (unit_columns > 0) try writer.writeAll(replacement),
            .line_break => try writer.writeAll(grapheme_boundary),
        }
        columns += unit_columns;
        index += unit.bytes;
    }
    return columns;
}

pub fn wrapper(text: []const u8, columns_max: usize) Wrapper {
    return .{ .text = text, .columns_max = columns_max, .line_start = 0, .done = false };
}

pub fn rowText(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, " \t");
}

pub fn rows(text: []const u8, columns_max: usize) usize {
    var iterator = wrapper(text, columns_max);
    var count: usize = 0;
    while (iterator.next()) |_| count += 1;
    return count;
}

pub fn caret(text: []const u8, options: Caret.Options) Caret {
    const columns_max = options.columns_max;
    const target = @min(options.offset, text.len);
    var iterator = wrapper(text, columns_max);
    var result: Caret = .{ .row = 0, .column = 0 };
    var row: usize = 0;
    while (iterator.nextSpan()) |span| : (row += 1) {
        if (span.start > target) break;
        const line = text[span.start..@min(span.end, target)];
        result = .{
            .row = row,
            .column = @min(fittedWidth(line, columns_max), columns_max),
        };
    }
    if (columns_max != 0 and result.column == columns_max) {
        result.row += 1;
        result.column = 0;
    }
    return result;
}

pub fn caretEnd(text: []const u8, span: Wrapper.Span, columns_max: usize) usize {
    if (columns_max == 0) return span.end;
    const wrapped = span.end < text.len and text[span.end] != '\n';
    var result = span.start;
    var index = span.start;
    var columns: usize = 0;
    while (index < span.end) {
        const next = boundaryAfter(text, index);
        columns += ofText(text[index..next]);
        if (columns >= columns_max) break;
        index = next;
        if (index < span.end or !wrapped) result = index;
    }
    return result;
}

pub fn nextWord(text: []const u8, columns_max: usize) Word {
    var result: Word = .{ .bytes = 0, .columns = 0, .blank_columns = 0 };
    while (result.bytes < text.len) {
        const unit = displayUnit(text[result.bytes..]);
        if (unit.kind == .line_break or blankUnit(text[result.bytes..], &unit)) break;
        result.columns += fittedColumns(&unit, columns_max);
        result.bytes += unit.bytes;
        if (result.columns > columns_max) {
            result.columns = columns_max + 1;
            return result;
        }
    }
    while (result.bytes < text.len) {
        const unit = displayUnit(text[result.bytes..]);
        if (unit.kind == .line_break or !blankUnit(text[result.bytes..], &unit)) break;
        result.blank_columns += fittedColumns(&unit, columns_max);
        result.bytes += unit.bytes;
    }
    return result;
}

pub fn boundaryAfter(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    return offset + displayUnit(text[offset..]).bytes;
}

pub fn boundaryBefore(text: []const u8, offset: usize) usize {
    const target = @min(offset, text.len);
    var boundary: usize = 0;
    var index: usize = 0;
    while (index < target) {
        boundary = index;
        index = boundaryAfter(text, index);
    }
    return boundary;
}

pub fn boundaryAtOrAfter(text: []const u8, offset: usize) usize {
    var index: usize = 0;
    while (index < offset and index < text.len) index = boundaryAfter(text, index);
    return index;
}

fn displayUnit(text: []const u8) DisplayUnit {
    const lead = text[0];
    if (lead < 0x80) return switch (lead) {
        '\n' => .{ .bytes = 1, .columns = 0, .kind = .line_break },
        '\t' => .{ .bytes = 1, .columns = 1, .kind = .tab },
        0x00...0x08, 0x0b...0x1f, 0x7f => .{ .bytes = 1, .columns = 1, .kind = .replacement },
        else => printableUnit(text),
    };

    const length = std.unicode.utf8ByteSequenceLength(lead) catch return replacementUnit();
    if (text.len < length) return replacementUnit();
    const codepoint = std.unicode.utf8Decode(text[0..length]) catch return replacementUnit();
    if (codepoint >= 0x80 and codepoint <= 0x9f) {
        return .{ .bytes = length, .columns = 1, .kind = .replacement };
    }
    return printableUnit(text);
}

fn printableUnit(text: []const u8) DisplayUnit {
    const step = grapheme.stepAt(text);
    return .{ .bytes = step.bytes, .columns = step.columns, .kind = .text };
}

fn replacementUnit() DisplayUnit {
    return .{ .bytes = 1, .columns = 1, .kind = .replacement };
}

fn blankUnit(text: []const u8, unit: *const DisplayUnit) bool {
    return unit.bytes == 1 and (text[0] == ' ' or text[0] == '\t');
}

fn fittedWidth(text: []const u8, columns_max: usize) usize {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const unit = displayUnit(text[index..]);
        columns += fittedColumns(&unit, columns_max);
        index += unit.bytes;
    }
    return columns;
}

fn fittedColumns(unit: *const DisplayUnit, columns_max: usize) usize {
    if (unit.columns == 0 or unit.columns <= columns_max) return unit.columns;
    return @intFromBool(columns_max > 0);
}

test ofText {
    try std.testing.expectEqual(@as(usize, 5), ofText("hello"));
    try std.testing.expectEqual(@as(usize, 0), ofText(""));
    try std.testing.expectEqual(@as(usize, 1), ofText("é"));
    try std.testing.expectEqual(@as(usize, 6), ofText("a\x1b[31m"));
    try std.testing.expectEqual(@as(usize, 2), ofText("x\x1b"));
    try std.testing.expectEqual(@as(usize, 4), ofText("\x1b[31"));
}

test "ofText measures wide glyphs and zero-width marks" {
    try std.testing.expectEqual(@as(usize, 4), ofText("你好"));
    try std.testing.expectEqual(@as(usize, 2), ofText("😀"));
    try std.testing.expectEqual(@as(usize, 4), ofText("a你b"));
    try std.testing.expectEqual(@as(usize, 1), ofText("e\u{0301}"));
}

test "ofText canonicalizes controls and malformed utf-8" {
    try std.testing.expectEqual(@as(usize, 3), ofText("a\tb"));
    try std.testing.expectEqual(@as(usize, 1), ofText("\x7f"));
    try std.testing.expectEqual(@as(usize, 1), ofText("\xc2\x9b"));
    try std.testing.expectEqual(@as(usize, 1), ofText("\xff"));
    try std.testing.expectEqual(@as(usize, 2), ofText("\xf0\x9f"));
    try std.testing.expectEqual(@as(usize, 3), ofText("\xf0\x9f\x98"));
    try std.testing.expectEqual(@as(usize, 2), ofText("\xe4\xb8"));
    try std.testing.expectEqual(@as(usize, 2), ofText("\xe2A"));
}

test "writeFitted without a column limit writes each unit in its canonical form" {
    const unlimited = std.math.maxInt(usize);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const input = "a\t\x07\x1b\xc2\x9b\x7f\xff\xf0\x9f\nb";
    const columns = try writeFitted(&out.writer, input, unlimited);
    try std.testing.expectEqualStrings(
        "a" ++ grapheme_boundary ++ " " ++ grapheme_boundary ++ replacement ++ replacement ++
            replacement ++ replacement ++ replacement ++ replacement ++ replacement ++
            grapheme_boundary ++ "b",
        out.written(),
    );
    try std.testing.expectEqual(@as(usize, 10), columns);
    try std.testing.expectEqual(columns, ofText(out.written()));

    out.clearRetainingCapacity();
    _ = try writeFitted(&out.writer, "\xd8\x80\xff", unlimited);
    try std.testing.expectEqualStrings("\xd8\x80" ++ replacement, out.written());

    out.clearRetainingCapacity();
    const separated_columns = try writeFitted(&out.writer, "\x1b\u{FE0F}", unlimited);
    try std.testing.expectEqualStrings(replacement ++ "\u{FE0F}", out.written());
    try std.testing.expectEqual(@as(usize, 3), separated_columns);
    try std.testing.expectEqual(separated_columns, ofText(out.written()));

    out.clearRetainingCapacity();
    const tab_columns = try writeFitted(&out.writer, "\t\u{FE0F}", unlimited);
    try std.testing.expectEqualStrings(
        grapheme_boundary ++ " " ++ grapheme_boundary ++ "\u{FE0F}",
        out.written(),
    );
    try std.testing.expectEqual(@as(usize, 3), tab_columns);
    try std.testing.expectEqual(tab_columns, ofText(out.written()));

    out.clearRetainingCapacity();
    const prepend_columns = try writeFitted(&out.writer, "\u{0D4E}\t\x1b", unlimited);
    try std.testing.expectEqualStrings(
        "\u{0D4E}" ++ grapheme_boundary ++ " " ++ grapheme_boundary ++ replacement,
        out.written(),
    );
    try std.testing.expectEqual(prepend_columns, ofText(out.written()));

    out.clearRetainingCapacity();
    const line_break_columns = try writeFitted(&out.writer, "\u{0D4E}\nA", unlimited);
    try std.testing.expectEqualStrings("\u{0D4E}" ++ grapheme_boundary ++ "A", out.written());
    try std.testing.expectEqual(line_break_columns, ofText(out.written()));
}

test "a grapheme wider than one column has a fitted replacement" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const columns = try writeFitted(&out.writer, "你", 1);
    try std.testing.expectEqualStrings(replacement, out.written());
    try std.testing.expectEqual(@as(usize, 1), columns);
    try std.testing.expectEqual(@as(usize, 1), rows("你", 1));
    try expectCaret(&.{ .text = "你", .offset = 3, .columns_max = 1, .row = 1 });
}

test "grapheme clusters measure as one terminal cell" {
    try std.testing.expectEqual(@as(usize, 2), ofText("❤\u{FE0F}"));
    try std.testing.expectEqual(@as(usize, 1), ofText("❤\u{FE0E}"));
    try std.testing.expectEqual(@as(usize, 2), ofText("1\u{FE0F}\u{20E3}"));
    try std.testing.expectEqual(@as(usize, 2), ofText("👍\u{1F3FD}"));
    try std.testing.expectEqual(@as(usize, 2), ofText("👨\u{200D}👩\u{200D}👧\u{200D}👦"));
    try std.testing.expectEqual(@as(usize, 2), ofText("🇯🇵"));
    try std.testing.expectEqual(@as(usize, 4), ofText("🇯🇵🇺🇸"));
}

test truncate {
    try std.testing.expectEqualStrings("hel", truncate("hello", 3));
    try std.testing.expectEqualStrings("hello", truncate("hello", 10));
    try std.testing.expectEqualStrings("", truncate("hello", 0));
    try std.testing.expectEqualStrings("", truncate("", 3));
    try std.testing.expectEqualStrings("a\x1b", truncate("a\x1b[31mbc", 2));
    try std.testing.expectEqualStrings("ab", truncate("abc\x1b[0m", 2));
    try std.testing.expectEqualStrings("ab", truncate("ab\ncd", 10));
    try std.testing.expectEqualStrings("你", truncate("你好", 3));
    try std.testing.expectEqualStrings("你", truncate("你好", 2));
    try std.testing.expectEqualStrings("你", truncate("你好", 1));
    try std.testing.expectEqualStrings("🇯🇵", truncate("🇯🇵", 2));
    try std.testing.expectEqualStrings("🇯🇵", truncate("🇯🇵", 1));
}

test wrapper {
    var basic = wrapper("abcdef", 3);
    try std.testing.expectEqualStrings("abc", basic.next().?);
    try std.testing.expectEqualStrings("def", basic.next().?);
    try std.testing.expect(basic.next() == null);

    var tabbed = wrapper("ab\tcd", 4);
    try std.testing.expectEqualStrings("ab", tabbed.next().?);
    try std.testing.expectEqualStrings("cd", tabbed.next().?);
    try std.testing.expect(tabbed.next() == null);

    var wide = wrapper("你好世", 3);
    try std.testing.expectEqualStrings("你", wide.next().?);
    try std.testing.expectEqualStrings("好", wide.next().?);
    try std.testing.expectEqualStrings("世", wide.next().?);
    try std.testing.expect(wide.next() == null);

    var empty = wrapper("", 3);
    try std.testing.expectEqualStrings("", empty.next().?);
    try std.testing.expect(empty.next() == null);

    var trailing = wrapper("ab\n", 10);
    try std.testing.expectEqualStrings("ab", trailing.next().?);
    try std.testing.expectEqualStrings("", trailing.next().?);
    try std.testing.expect(trailing.next() == null);

    var newline = wrapper("ab\ncd", 10);
    try std.testing.expectEqualStrings("ab", newline.next().?);
    try std.testing.expectEqualStrings("cd", newline.next().?);
    try std.testing.expect(newline.next() == null);

    var narrow = wrapper("ab cd\nef", 0);
    try std.testing.expectEqualStrings("ab cd", narrow.next().?);
    try std.testing.expectEqualStrings("ef", narrow.next().?);
    try std.testing.expect(narrow.next() == null);
}

test "the wrap breaks between words and keeps each word whole" {
    var prose = wrapper("one two three", 7);
    try std.testing.expectEqualStrings("one two", prose.next().?);
    try std.testing.expectEqualStrings("three", prose.next().?);
    try std.testing.expect(prose.next() == null);

    var early = wrapper("aaa bbbb", 5);
    try std.testing.expectEqualStrings("aaa", early.next().?);
    try std.testing.expectEqualStrings("bbbb", early.next().?);
    try std.testing.expect(early.next() == null);

    var long = wrapper("aaa bbbbbbb", 5);
    try std.testing.expectEqualStrings("aaa", long.next().?);
    try std.testing.expectEqualStrings("bbbbb", long.next().?);
    try std.testing.expectEqualStrings("bb", long.next().?);
    try std.testing.expect(long.next() == null);

    const spaced = "abcde   fgh";
    var blanks = wrapper(spaced, 5);
    const first = blanks.nextSpan().?;
    try std.testing.expectEqual(Wrapper.Span{ .start = 0, .end = 8 }, first);
    try std.testing.expectEqualStrings("abcde", rowText(spaced[first.start..first.end]));
    try std.testing.expectEqualStrings("fgh", blanks.next().?);
    try std.testing.expect(blanks.next() == null);

    var joined = wrapper("ab c\u{00A0}d", 4);
    try std.testing.expectEqualStrings("ab", joined.next().?);
    try std.testing.expectEqualStrings("c\u{00A0}d", joined.next().?);
    try std.testing.expect(joined.next() == null);
}

test nextWord {
    const one: Word = .{ .bytes = 4, .columns = 3, .blank_columns = 1 };
    try std.testing.expectEqual(one, nextWord("one two", 80));
    const last: Word = .{ .bytes = 3, .columns = 3, .blank_columns = 0 };
    try std.testing.expectEqual(last, nextWord("two", 80));
    const blanks: Word = .{ .bytes = 2, .columns = 0, .blank_columns = 2 };
    try std.testing.expectEqual(blanks, nextWord("  two", 80));
    const empty: Word = .{ .bytes = 0, .columns = 0, .blank_columns = 0 };
    try std.testing.expectEqual(empty, nextWord("", 80));
    const wide: Word = .{ .bytes = 8, .columns = 4, .blank_columns = 2 };
    try std.testing.expectEqual(wide, nextWord("你好\t x", 80));
    const line: Word = .{ .bytes = 2, .columns = 2, .blank_columns = 0 };
    try std.testing.expectEqual(line, nextWord("ab\ncd", 80));
    const line_blanks: Word = .{ .bytes = 3, .columns = 2, .blank_columns = 1 };
    try std.testing.expectEqual(line_blanks, nextWord("ab \ncd", 80));
    const broken: Word = .{ .bytes = 0, .columns = 0, .blank_columns = 0 };
    try std.testing.expectEqual(broken, nextWord("\nab", 80));
    const narrow: Word = .{ .bytes = 6, .columns = 2, .blank_columns = 0 };
    try std.testing.expectEqual(narrow, nextWord("你好", 1));
    const none: Word = .{ .bytes = 4, .columns = 0, .blank_columns = 0 };
    try std.testing.expectEqual(none, nextWord("word", 0));
    const stopped: Word = .{ .bytes = 4, .columns = 4, .blank_columns = 0 };
    try std.testing.expectEqual(stopped, nextWord("abcdef gh", 3));
    const saturated: Word = .{ .bytes = 6, .columns = 3, .blank_columns = 0 };
    try std.testing.expectEqual(saturated, nextWord("你你x", 2));
}

test rows {
    try std.testing.expectEqual(@as(usize, 1), rows("", 3));
    try std.testing.expectEqual(@as(usize, 2), rows("abcd", 3));
    try std.testing.expectEqual(@as(usize, 2), rows("one two three", 7));
}

test "canonical display boundaries follow rendered replacement units" {
    try std.testing.expectEqual(@as(usize, 1), boundaryAfter("\xf0\x9f", 0));
    try std.testing.expectEqual(@as(usize, 1), boundaryBefore("\xf0\x9f", 2));
    try std.testing.expectEqual(@as(usize, 1), boundaryBefore("ab", 100));
    try std.testing.expectEqual(@as(usize, 1), boundaryBefore("\r\n", 2));
    try std.testing.expectEqual(@as(usize, 2), boundaryAfter("\xc2\x9b", 0));
    try std.testing.expectEqual(@as(usize, 3), boundaryAtOrAfter("e\u{0301}", 1));
}

const CaretCase = struct {
    text: []const u8,
    offset: usize,
    columns_max: usize,
    row: usize = 0,
    column: usize = 0,
};

fn expectCaret(case: *const CaretCase) !void {
    errdefer std.debug.print("The caret case is \"{s}\" at offset {d} in {d} columns.\n", .{
        case.text,
        case.offset,
        case.columns_max,
    });
    const expected: Caret = .{ .row = case.row, .column = case.column };
    const options: Caret.Options = .{ .offset = case.offset, .columns_max = case.columns_max };
    try std.testing.expectEqual(expected, caret(case.text, options));
}

test caret {
    for ([_]CaretCase{
        .{ .text = "", .offset = 0, .columns_max = 3 },
        .{ .text = "he", .offset = 2, .columns_max = 3, .column = 2 },
        .{ .text = "hel", .offset = 3, .columns_max = 3, .row = 1 },
        .{ .text = "你你", .offset = 6, .columns_max = 4, .row = 1 },
        .{ .text = "hello", .offset = 4, .columns_max = 3, .row = 1, .column = 1 },
        .{ .text = "你好", .offset = 6, .columns_max = 3, .row = 1, .column = 2 },
        .{ .text = "ab\ncd", .offset = 4, .columns_max = 10, .row = 1, .column = 1 },
        .{ .text = "a\n", .offset = 2, .columns_max = 10, .row = 1 },
        .{ .text = "a\n\n", .offset = 3, .columns_max = 10, .row = 2 },
        .{ .text = "abcd", .offset = 1, .columns_max = 3, .column = 1 },
        .{ .text = "abcd", .offset = 3, .columns_max = 3, .row = 1 },
    }) |case| try expectCaret(&case);
}

test "a caret reads the row the word wrap gives it" {
    for ([_]CaretCase{
        .{ .text = "aaa bbbb", .offset = 6, .columns_max = 5, .row = 1, .column = 2 },
        .{ .text = "aaa bbbb", .offset = 4, .columns_max = 5, .row = 1 },
        .{ .text = "abcde  f", .offset = 6, .columns_max = 5, .row = 1 },
        .{ .text = "abcde  f", .offset = 7, .columns_max = 5, .row = 1 },
    }) |case| try expectCaret(&case);
}

test caretEnd {
    const columns_max = 5;
    const prose = "aaa bbbb";
    var iterator = wrapper(prose, columns_max);
    const first = caretEnd(prose, iterator.nextSpan().?, columns_max);
    try std.testing.expectEqual(@as(usize, 3), first);
    const second = caretEnd(prose, iterator.nextSpan().?, columns_max);
    try std.testing.expectEqual(@as(usize, 8), second);

    for ([_]usize{ 5, 1, 0 }) |columns| {
        for ([_][]const u8{ "", "aaa bbbb", "abcde  f", "abc\ndef", "aaa  ", "你好世界" }) |text| {
            var rows_iterator = wrapper(text, columns);
            var row: usize = 0;
            while (rows_iterator.nextSpan()) |span| : (row += 1) {
                const end = caretEnd(text, span, columns);
                try std.testing.expect(span.start <= end and end <= span.end);
                var offset = span.start;
                while (offset <= end) {
                    const options: Caret.Options = .{ .offset = offset, .columns_max = columns };
                    try std.testing.expectEqual(row, caret(text, options).row);
                    if (offset == text.len) break;
                    offset = boundaryAfter(text, offset);
                }
                if (end == text.len) continue;
                const after: Caret.Options = .{
                    .offset = boundaryAfter(text, end),
                    .columns_max = columns,
                };
                try std.testing.expect(caret(text, after).row > row);
            }
        }
    }
}
