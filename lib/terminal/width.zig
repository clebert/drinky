//! Display-width measurement, canonicalization, and word wrapping of text as a
//! mode-2027 terminal renders it: one UAX #29 grapheme cluster per cell step.

const std = @import("std");

const grapheme = @import("grapheme.zig");

/// Display width of inert `text` in terminal columns after canonicalization for
/// safe terminal output. The measure is per UAX #29 grapheme cluster (via
/// `grapheme`) and matches a terminal with DECSET mode 2027. LF is a logical row
/// break and adds no columns. TAB is one space. Every other C0/C1 control, DEL,
/// or malformed UTF-8 unit is one replacement-character column.
pub fn ofText(text: []const u8) usize {
    return fittedWidth(text, std.math.maxInt(usize));
}

/// Longest single-line prefix of `text` whose canonical display width is at
/// most `columns_max`. A grapheme cluster that straddles the budget is dropped
/// whole.
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

/// Write the canonical, inert representation of `text` and return its display
/// width. A logical LF emits only a zero-width grapheme boundary. Callers that
/// accept multiline text split it with `wrapper` before they compose physical rows.
pub fn writeText(writer: *std.Io.Writer, text: []const u8) !usize {
    return writeCanonical(writer, text, std.math.maxInt(usize));
}

/// Write one physical row fitted to `columns_max`. A printable grapheme wider
/// than the row becomes the same one-column replacement used for controls, so
/// even a one-column terminal remains synchronized.
pub fn writeFitted(writer: *std.Io.Writer, text: []const u8, columns_max: usize) !usize {
    return writeCanonical(writer, text, columns_max);
}

/// A streamed word wrap: `next` yields each line (a slice into `text`) of at
/// most `columns_max` display columns, then null. A caller can thus drop the
/// rows above a window and never materialize the list.
///
/// A row breaks between two words, so a terminal copy of the rows holds whole
/// words. A word too long for a row of its own breaks inside itself, which is
/// also what text with no blank, such as a CJK run, does. No break falls inside
/// a grapheme cluster. An explicit `\n` starts a new line and never reaches the
/// output.
///
/// `next` yields the cells a row paints, so it drops the blanks the wrap breaks
/// at (see `rowText`). `nextSpan` yields the bytes a row covers instead: the
/// spans are contiguous, so they cover `text` apart from the line breaks the
/// wrap consumes. A caller that maps a row onto its source takes the span, and
/// applies `rowText` before it paints.
///
/// The wrap takes one `nextWord` at a time. A caller that composes a row from
/// styled pieces places words the same way, so both break a row at one policy.
pub const Wrapper = struct {
    text: []const u8,
    columns_max: usize,
    line_start: usize,
    done: bool,

    /// One wrapped line as a byte span of `text`. A caller that maps a row back
    /// onto its source reads the offsets from here.
    pub const Span = struct { start: usize, end: usize };

    pub fn next(self: *Wrapper) ?[]const u8 {
        const span = self.nextSpan() orelse return null;
        return rowText(self.text[span.start..span.end]);
    }

    /// The bytes of each line `next` yields, as spans of `text`.
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
            // The blanks behind a word ride with it, so no row opens on a blank.
            // They never decide a break either: a row ends on them, and `rowText`
            // drops them from the cells it paints.
            const word = nextWord(text[index..], self.columns_max);
            std.debug.assert(word.bytes > 0);
            if (columns + word.columns > self.columns_max) {
                if (index > start) {
                    // The word takes the next row whole.
                    self.line_start = index;
                    return .{ .start = start, .end = index };
                }
                // A word too long for a row of its own breaks inside itself.
                // Against a room of one, `truncate` still yields one cluster, so
                // the row advances. A zero-column room fits no word at all, so
                // the branch never runs there and the line stays one row.
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

/// Wrap `text` to at most `columns_max` display columns. `rows` and `caret`
/// build on this form, so they stay in lockstep by construction.
pub fn wrapper(text: []const u8, columns_max: usize) Wrapper {
    return .{ .text = text, .columns_max = columns_max, .line_start = 0, .done = false };
}

/// The cells one wrapped row paints: `text` without the blanks it ends on. A
/// break moves the word behind those blanks to the next row, so they hold no
/// content. A row that paints them puts them in every copy of the terminal text,
/// and the ones at the margin reach no cell at all.
pub fn rowText(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, " \t");
}

/// Physical rows `text` occupies once wrapped to `columns_max`: the count of
/// lines `wrapper` yields, always at least one. A word and a wide cluster both
/// move to the next row whole, so this is not `ceil(width / columns)`.
pub fn rows(text: []const u8, columns_max: usize) usize {
    var iterator = wrapper(text, columns_max);
    var count: usize = 0;
    while (iterator.next()) |_| count += 1;
    return count;
}

pub const Caret = struct {
    rows_before: usize,
    column: usize,

    /// Which caret `caret` places, and how wide the rows it wraps to are.
    pub const Options = struct { offset: usize, columns_max: usize };
};

/// Physical position of the caret at `options.offset` once `text` wraps to
/// `options.columns_max`. The result is how many row breaks precede the caret and
/// its column within that row.
///
/// A word wrap moves a break with the text behind the caret, so the whole text
/// decides the answer and the prefix alone cannot. A caret on a row break belongs
/// to the row under it, at that row's first column. A caret that fills a row
/// exactly wraps the same way, because no cell exists at the margin. Every offset
/// in the blanks that pass the margin reports that same first column, because the
/// terminal holds no cell that separates them. `caretEnd` names the last offset
/// one row keeps. `options.offset` must be a canonical display boundary.
pub fn caret(text: []const u8, options: Caret.Options) Caret {
    const columns_max = options.columns_max;
    const target = @min(options.offset, text.len);
    var iterator = wrapper(text, columns_max);
    var result: Caret = .{ .rows_before = 0, .column = 0 };
    var row: usize = 0;
    while (iterator.nextSpan()) |span| : (row += 1) {
        if (span.start > target) break;
        const line = text[span.start..@min(span.end, target)];
        // A row's trailing blanks can pass the margin, so the clamp keeps a
        // caret among them at the last column the terminal shows.
        result = .{
            .rows_before = row,
            .column = @min(fittedWidth(line, columns_max), columns_max),
        };
    }
    if (columns_max != 0 and result.column == columns_max) {
        result.rows_before += 1;
        result.column = 0;
    }
    return result;
}

/// The last offset of one wrapped row that `caret` still places on that row.
/// `span` comes from `Wrapper.nextSpan` at the same `columns_max`.
///
/// A caret at the margin moves to the row under it, and a wrap break puts
/// `span.end` there too, so the row holds neither. A caller that maps a column
/// back onto an offset must stop here, or the offset it returns names a row it
/// did not aim at.
pub fn caretEnd(text: []const u8, span: Wrapper.Span, columns_max: usize) usize {
    // A zero-column window breaks no row, so one logical line is one row and that
    // row keeps every offset in it.
    if (columns_max == 0) return span.end;
    // A wrap break carries its offset onto the next row. A line break and the end
    // of the text both leave it on this row.
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

/// One word of `text` and the blanks behind it: `bytes` is what one row consumes,
/// `columns` measures the word alone, and `blank_columns` the blanks. A word that
/// outgrows the whole row reports exactly `columns_max + 1` columns, and `bytes`
/// then covers only the scanned head of it (see `nextWord`).
pub const Word = struct { bytes: usize, columns: usize, blank_columns: usize };

/// The next word of `text` on a row `columns_max` columns wide. A word ends at
/// the first blank or line break behind it, and the blanks that follow it ride
/// with it. Text that starts with blanks yields those blanks and no word, which
/// is what a caller sees where it resumes mid-row.
///
/// The measures fit `columns_max` the way a row that wide renders the word, so a
/// cluster wider than the whole row counts as its one-column replacement. A line
/// break stays in `text` and adds nothing, so the caller decides what it does.
///
/// A caller that composes a row from several styled pieces places one word at a
/// time, so it breaks its rows where `Wrapper` breaks a plain one.
///
/// The scan stops once the word outgrows the whole row: such a word fits no
/// room on the row, so its measures past `columns_max` decide nothing.
/// `columns` saturates at `columns_max + 1` to state the stop, and `bytes`
/// covers the scanned head alone and no blanks, which every caller treats as
/// a break inside the word and never advances by. The stop keeps a long
/// unbroken word linear: each row it wraps onto scans one row of it.
pub fn nextWord(text: []const u8, columns_max: usize) Word {
    var result: Word = .{ .bytes = 0, .columns = 0, .blank_columns = 0 };
    while (result.bytes < text.len) {
        const unit = displayUnit(text[result.bytes..]);
        if (unit.kind == .line_break or blankUnit(text[result.bytes..], &unit)) break;
        result.columns += fittedColumns(&unit, columns_max);
        result.bytes += unit.bytes;
        if (result.columns > columns_max) {
            // No overflow: the branch implies `columns_max` is below `columns`.
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

/// Byte offset immediately after the canonical display unit at `offset`.
pub fn boundaryAfter(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    return offset + displayUnit(text[offset..]).bytes;
}

/// Byte offset of the canonical display-unit boundary immediately before
/// `offset`, which must itself be a boundary. An offset past the end clamps to
/// the end first.
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

/// First canonical display boundary at or after an arbitrary byte offset.
pub fn boundaryAtOrAfter(text: []const u8, offset: usize) usize {
    var index: usize = 0;
    while (index < offset and index < text.len) index = boundaryAfter(text, index);
    return index;
}

const grapheme_boundary = "\u{200B}";
const replacement = grapheme_boundary ++ "�" ++ grapheme_boundary;

const UnitKind = enum { text, space, replacement, line_break };

const DisplayUnit = struct {
    bytes: usize,
    columns: usize,
    kind: UnitKind,
};

/// The next source unit and the shape it has after canonical display. Invalid
/// UTF-8 advances one byte, so malformed input cannot swallow printable bytes.
fn displayUnit(text: []const u8) DisplayUnit {
    const lead = text[0];
    if (lead < 0x80) return switch (lead) {
        '\n' => .{ .bytes = 1, .columns = 0, .kind = .line_break },
        '\t' => .{ .bytes = 1, .columns = 1, .kind = .space },
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
    var safe_len: usize = 0;
    while (safe_len < step.bytes) {
        const lead = text[safe_len];
        if (lead < 0x80) {
            if (lead < 0x20 or lead == 0x7f) break;
            safe_len += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(lead) catch break;
        if (step.bytes - safe_len < length) break;
        const codepoint = std.unicode.utf8Decode(text[safe_len..][0..length]) catch break;
        if (codepoint >= 0x80 and codepoint <= 0x9f) break;
        safe_len += length;
    }
    if (safe_len == step.bytes) {
        return .{ .bytes = step.bytes, .columns = step.columns, .kind = .text };
    }
    std.debug.assert(safe_len > 0);
    const safe_step = grapheme.stepAt(text[0..safe_len]);
    return .{ .bytes = safe_step.bytes, .columns = safe_step.columns, .kind = .text };
}

fn replacementUnit() DisplayUnit {
    return .{ .bytes = 1, .columns = 1, .kind = .replacement };
}

/// Whether the display unit at the head of `text` is a blank: a space or a tab.
/// A word starts after a run of blanks. Every other unit, a no-break space
/// included, holds a word together.
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

fn writeCanonical(writer: *std.Io.Writer, text: []const u8, columns_max: usize) !usize {
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
            .space => if (unit_columns > 0)
                try writer.writeAll(grapheme_boundary ++ " " ++ grapheme_boundary),
            .replacement => if (unit_columns > 0) try writer.writeAll(replacement),
            .line_break => try writer.writeAll(grapheme_boundary),
        }
        columns += unit_columns;
        index += unit.bytes;
    }
    return columns;
}

test ofText {
    try std.testing.expectEqual(@as(usize, 5), ofText("hello"));
    try std.testing.expectEqual(@as(usize, 0), ofText(""));
    try std.testing.expectEqual(@as(usize, 1), ofText("é"));
    // ESC is one visible replacement and the printable tail stays visible.
    try std.testing.expectEqual(@as(usize, 6), ofText("a\x1b[31m"));
    try std.testing.expectEqual(@as(usize, 2), ofText("x\x1b"));
    try std.testing.expectEqual(@as(usize, 4), ofText("\x1b[31"));
}

test "ofText measures wide glyphs and zero-width marks" {
    try std.testing.expectEqual(@as(usize, 4), ofText("你好"));
    try std.testing.expectEqual(@as(usize, 2), ofText("😀"));
    try std.testing.expectEqual(@as(usize, 4), ofText("a你b"));
    // A base letter plus a combining mark is a single column.
    try std.testing.expectEqual(@as(usize, 1), ofText("e\u{0301}"));
}

test "ofText canonicalizes controls and malformed utf-8" {
    try std.testing.expectEqual(@as(usize, 3), ofText("a\tb"));
    try std.testing.expectEqual(@as(usize, 1), ofText("\x7f"));
    try std.testing.expectEqual(@as(usize, 1), ofText("\xc2\x9b"));
    try std.testing.expectEqual(@as(usize, 1), ofText("\xff"));
    // Truncated or invalid multibyte input advances one byte per replacement.
    try std.testing.expectEqual(@as(usize, 2), ofText("\xf0\x9f"));
    try std.testing.expectEqual(@as(usize, 3), ofText("\xf0\x9f\x98"));
    try std.testing.expectEqual(@as(usize, 2), ofText("\xe4\xb8"));
    try std.testing.expectEqual(@as(usize, 2), ofText("\xe2A"));
}

test writeText {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const input = "a\t\x07\x1b\xc2\x9b\x7f\xff\xf0\x9f\nb";
    const columns = try writeText(&out.writer, input);
    try std.testing.expectEqualStrings(
        "a" ++ grapheme_boundary ++ " " ++ grapheme_boundary ++ replacement ++ replacement ++
            replacement ++ replacement ++ replacement ++ replacement ++ replacement ++
            grapheme_boundary ++ "b",
        out.written(),
    );
    try std.testing.expectEqual(@as(usize, 10), columns);
    try std.testing.expectEqual(columns, ofText(out.written()));

    out.clearRetainingCapacity();
    _ = try writeText(&out.writer, "\xd8\x80\xff");
    try std.testing.expectEqualStrings("\xd8\x80" ++ replacement, out.written());

    out.clearRetainingCapacity();
    const separated_columns = try writeText(&out.writer, "\x1b\u{FE0F}");
    try std.testing.expectEqualStrings(replacement ++ "\u{FE0F}", out.written());
    try std.testing.expectEqual(@as(usize, 3), separated_columns);
    try std.testing.expectEqual(separated_columns, ofText(out.written()));

    out.clearRetainingCapacity();
    const tab_columns = try writeText(&out.writer, "\t\u{FE0F}");
    try std.testing.expectEqualStrings(
        grapheme_boundary ++ " " ++ grapheme_boundary ++ "\u{FE0F}",
        out.written(),
    );
    try std.testing.expectEqual(@as(usize, 3), tab_columns);
    try std.testing.expectEqual(tab_columns, ofText(out.written()));

    out.clearRetainingCapacity();
    const prepend_columns = try writeText(&out.writer, "\u{0D4E}\t\x1b");
    try std.testing.expectEqualStrings(
        "\u{0D4E}" ++ grapheme_boundary ++ " " ++ grapheme_boundary ++ replacement,
        out.written(),
    );
    try std.testing.expectEqual(prepend_columns, ofText(out.written()));

    out.clearRetainingCapacity();
    const line_break_columns = try writeText(&out.writer, "\u{0D4E}\nA");
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
    try expectCaret(.{ .text = "你", .offset = 3, .columns_max = 1, .rows_before = 1 });
}

test "grapheme clusters measure as one terminal cell" {
    // Each renders as a single glyph and measures as the cell a mode-2027
    // terminal draws, not the sum of its code points.

    // Heart plus VS16 promotes to a two-cell emoji. VS15 keeps it at one.
    try std.testing.expectEqual(@as(usize, 2), ofText("❤\u{FE0F}"));
    try std.testing.expectEqual(@as(usize, 1), ofText("❤\u{FE0E}"));
    // A keycap sequence — digit, selector, enclosing keycap — is two columns.
    try std.testing.expectEqual(@as(usize, 2), ofText("1\u{FE0F}\u{20E3}"));
    // Thumbs-up plus skin-tone modifier: one two-column glyph.
    try std.testing.expectEqual(@as(usize, 2), ofText("👍\u{1F3FD}"));
    // ZWJ family: four emoji joined into one two-column glyph.
    try std.testing.expectEqual(@as(usize, 2), ofText("👨\u{200D}👩\u{200D}👧\u{200D}👦"));
    // A regional-indicator flag is one two-column glyph. Two flags are four.
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
    // Wide clusters stay whole. One wider than the whole row is retained so the
    // fitted writer can display its one-column replacement.
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

    // A zero-column window fits no word, so every logical line stays one row and
    // the wrap still advances.
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

    // The word moves down whole, however much of the row it leaves empty.
    var early = wrapper("aaa bbbb", 5);
    try std.testing.expectEqualStrings("aaa", early.next().?);
    try std.testing.expectEqualStrings("bbbb", early.next().?);
    try std.testing.expect(early.next() == null);

    // A word too long for a row of its own breaks inside itself.
    var long = wrapper("aaa bbbbbbb", 5);
    try std.testing.expectEqualStrings("aaa", long.next().?);
    try std.testing.expectEqualStrings("bbbbb", long.next().?);
    try std.testing.expectEqualStrings("bb", long.next().?);
    try std.testing.expect(long.next() == null);

    // A row ends on the blanks it breaks at. They hold no content, so the row
    // covers them and paints none of them.
    const spaced = "abcde   fgh";
    var blanks = wrapper(spaced, 5);
    const first = blanks.nextSpan().?;
    try std.testing.expectEqual(Wrapper.Span{ .start = 0, .end = 8 }, first);
    try std.testing.expectEqualStrings("abcde", rowText(spaced[first.start..first.end]));
    try std.testing.expectEqualStrings("fgh", blanks.next().?);
    try std.testing.expect(blanks.next() == null);

    // A no-break space holds its word together, so the whole word moves down.
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
    // A line break ends the word and stays in the text.
    const line: Word = .{ .bytes = 2, .columns = 2, .blank_columns = 0 };
    try std.testing.expectEqual(line, nextWord("ab\ncd", 80));
    const line_blanks: Word = .{ .bytes = 3, .columns = 2, .blank_columns = 1 };
    try std.testing.expectEqual(line_blanks, nextWord("ab \ncd", 80));
    const broken: Word = .{ .bytes = 0, .columns = 0, .blank_columns = 0 };
    try std.testing.expectEqual(broken, nextWord("\nab", 80));
    // The measures fit the row: a cluster wider than the whole row counts as the
    // one-column replacement the fitted writer leaves there.
    const narrow: Word = .{ .bytes = 6, .columns = 2, .blank_columns = 0 };
    try std.testing.expectEqual(narrow, nextWord("你好", 1));
    // A zero-column row fits nothing, so every measure is zero.
    const none: Word = .{ .bytes = 4, .columns = 0, .blank_columns = 0 };
    try std.testing.expectEqual(none, nextWord("word", 0));
    // The scan stops once the word outgrows the whole row, so a long unbroken
    // word costs each row only the row, not its own length. `bytes` covers the
    // scanned head alone, which no caller advances by.
    const stopped: Word = .{ .bytes = 4, .columns = 4, .blank_columns = 0 };
    try std.testing.expectEqual(stopped, nextWord("abcdef gh", 3));
    // The columns of a stopped word saturate at one past the row, so a wide
    // cluster cannot leak a larger measure through the stop.
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

/// One `caret` case: where the caret sits in `text`, how wide a row is, and the
/// physical position the wrap must give the caret.
const CaretCase = struct {
    text: []const u8,
    offset: usize,
    columns_max: usize,
    rows_before: usize = 0,
    column: usize = 0,
};

fn expectCaret(case: CaretCase) !void {
    errdefer std.debug.print("The caret case is \"{s}\" at offset {d} in {d} columns.\n", .{
        case.text,
        case.offset,
        case.columns_max,
    });
    const expected: Caret = .{ .rows_before = case.rows_before, .column = case.column };
    const options: Caret.Options = .{ .offset = case.offset, .columns_max = case.columns_max };
    try std.testing.expectEqual(expected, caret(case.text, options));
}

test caret {
    for ([_]CaretCase{
        .{ .text = "", .offset = 0, .columns_max = 3 },
        .{ .text = "he", .offset = 2, .columns_max = 3, .column = 2 },
        .{ .text = "hel", .offset = 3, .columns_max = 3, .rows_before = 1 },
        .{ .text = "你你", .offset = 6, .columns_max = 4, .rows_before = 1 },
        .{ .text = "hello", .offset = 4, .columns_max = 3, .rows_before = 1, .column = 1 },
        .{ .text = "你好", .offset = 6, .columns_max = 3, .rows_before = 1, .column = 2 },
        .{ .text = "ab\ncd", .offset = 4, .columns_max = 10, .rows_before = 1, .column = 1 },
        .{ .text = "a\n", .offset = 2, .columns_max = 10, .rows_before = 1 },
        .{ .text = "a\n\n", .offset = 3, .columns_max = 10, .rows_before = 2 },
        // An offset in the middle reads the row the whole text wraps it onto.
        .{ .text = "abcd", .offset = 1, .columns_max = 3, .column = 1 },
        .{ .text = "abcd", .offset = 3, .columns_max = 3, .rows_before = 1 },
    }) |case| try expectCaret(case);
}

test "a caret reads the row the word wrap gives it" {
    for ([_]CaretCase{
        // The word moves to the next row, and the caret inside it moves with it.
        .{ .text = "aaa bbbb", .offset = 6, .columns_max = 5, .rows_before = 1, .column = 2 },
        // A caret between the blanks and the word sits on the word's first column.
        .{ .text = "aaa bbbb", .offset = 4, .columns_max = 5, .rows_before = 1 },
        // The blanks a row ends with pass the margin, so every caret among them
        // reads the first column of the row under them.
        .{ .text = "abcde  f", .offset = 6, .columns_max = 5, .rows_before = 1 },
        .{ .text = "abcde  f", .offset = 7, .columns_max = 5, .rows_before = 1 },
    }) |case| try expectCaret(case);
}

test caretEnd {
    const columns_max = 5;
    // A wrap break ends the row before the blank it breaks at. The last row keeps
    // its own end, because no row follows it.
    const prose = "aaa bbbb";
    var iterator = wrapper(prose, columns_max);
    const first = caretEnd(prose, iterator.nextSpan().?, columns_max);
    try std.testing.expectEqual(@as(usize, 3), first);
    const second = caretEnd(prose, iterator.nextSpan().?, columns_max);
    try std.testing.expectEqual(@as(usize, 8), second);

    // Every offset a row keeps reports that row, and the offset after the last one
    // reports a row below. This is the contract `caret` and `caretEnd` share. A
    // zero-column window keeps it too, where one logical line is one row.
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
                    try std.testing.expectEqual(row, caret(text, options).rows_before);
                    if (offset == text.len) break;
                    offset = boundaryAfter(text, offset);
                }
                if (end == text.len) continue;
                const after: Caret.Options = .{
                    .offset = boundaryAfter(text, end),
                    .columns_max = columns,
                };
                try std.testing.expect(caret(text, after).rows_before > row);
            }
        }
    }
}
