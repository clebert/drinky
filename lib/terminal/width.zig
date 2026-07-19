//! Display-width measurement, canonicalization, and hard-wrapping of text as a
//! mode-2027 terminal renders it: one UAX #29 grapheme cluster per cell step.

const std = @import("std");

const grapheme = @import("grapheme.zig");

/// Display width of inert `text` in terminal columns after canonicalizing it for
/// safe terminal output. Text is measured per UAX #29 grapheme cluster (via
/// `grapheme`), matching a terminal with DECSET mode 2027. LF is a logical row
/// break and adds no columns, TAB is one space, and every other C0/C1 control,
/// DEL, or malformed UTF-8 unit is one replacement-character column.
pub fn ofText(text: []const u8) usize {
    return fittedWidth(text, std.math.maxInt(usize));
}

/// Longest single-line prefix of `text` whose canonical display width is at
/// most `columns_max`. A grapheme cluster that would straddle the budget is
/// dropped whole.
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

/// Write the canonical, inert representation of `text`, returning its display
/// width. A logical LF emits only a zero-width grapheme boundary; callers that
/// accept multiline text split it with `wrapper` before composing physical rows.
pub fn writeText(writer: *std.Io.Writer, text: []const u8) !usize {
    return writeCanonical(writer, text, std.math.maxInt(usize));
}

/// Write one physical row fitted to `columns_max`. A printable grapheme wider
/// than the row is represented by the same one-column replacement used for
/// controls, so even a one-column terminal remains synchronized.
pub fn writeFitted(writer: *std.Io.Writer, text: []const u8, columns_max: usize) !usize {
    return writeCanonical(writer, text, columns_max);
}

/// Streaming hard-wrap: `next` yields each line (a slice into `text`) of at most
/// `columns_max` display columns, then null, so a caller can drop the rows above
/// a window without materializing the list. Breaks strictly on width, never
/// inside a grapheme cluster; an explicit `\n` starts a new line and is not emitted.
pub const Wrapper = struct {
    text: []const u8,
    columns_max: usize,
    line_start: usize,
    done: bool,

    pub fn next(self: *Wrapper) ?[]const u8 {
        if (self.done) return null;
        const text = self.text;
        var columns: usize = 0;
        var index = self.line_start;
        while (index < text.len) {
            const byte = text[index];
            if (byte == '\n') {
                const line = text[self.line_start..index];
                self.line_start = index + 1;
                return line;
            }
            const unit = displayUnit(text[index..]);
            const unit_columns = fittedColumns(&unit, self.columns_max);
            if (columns + unit_columns > self.columns_max and index > self.line_start) {
                const line = text[self.line_start..index];
                self.line_start = index;
                return line;
            }
            columns += unit_columns;
            index += unit.bytes;
        }
        self.done = true;
        return text[self.line_start..];
    }
};

/// Wrap `text` to at most `columns_max` display columns — the form `rows` and
/// `caret` are built on, so they stay in lockstep by construction.
pub fn wrapper(text: []const u8, columns_max: usize) Wrapper {
    return .{ .text = text, .columns_max = columns_max, .line_start = 0, .done = false };
}

/// Physical rows `text` occupies once hard-wrapped to `columns_max` — the count
/// of lines `wrapper` yields, always at least one. A wide cluster that would
/// straddle the margin breaks to the next row, so this is not `ceil(width / columns)`.
pub fn rows(text: []const u8, columns_max: usize) usize {
    var iterator = wrapper(text, columns_max);
    var count: usize = 0;
    while (iterator.next()) |_| count += 1;
    return count;
}

pub const Caret = struct { rows_before: usize, column: usize };

/// Physical position of a caret at the end of `text` once wrapped to
/// `columns_max`: how many row breaks precede it and its column within that row.
/// Pass the prefix before the caret — a greedy width wrap never lets later
/// content move an earlier break, so the suffix cannot change the answer. A
/// prefix that fills a row exactly wraps the caret onto the next row's first
/// column, since no cell exists at the margin. `text` must end on a canonical
/// display boundary.
pub fn caret(text: []const u8, columns_max: usize) Caret {
    var iterator = wrapper(text, columns_max);
    var result: Caret = .{ .rows_before = 0, .column = 0 };
    var first = true;
    while (iterator.next()) |line| {
        if (!first) result.rows_before += 1;
        first = false;
        result.column = fittedWidth(line, columns_max);
    }
    if (columns_max != 0 and result.column == columns_max) {
        result.rows_before += 1;
        result.column = 0;
    }
    return result;
}

/// Byte offset into `text` whose prefix `caret` maps to `target` once `text` is
/// wrapped to `columns_max` — the inverse of `caret`. A target row past the last
/// wrapped row clamps to the end of `text`; a target column past its row's
/// content clamps to the row's end, landing on the last display boundary that
/// does not overshoot the column.
pub fn offsetAt(text: []const u8, columns_max: usize, target: Caret) usize {
    var iterator = wrapper(text, columns_max);
    var row: usize = 0;
    while (iterator.next()) |line| : (row += 1) {
        if (row != target.rows_before) continue;
        const start = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
        return start + offsetAtColumn(line, columns_max, target.column);
    }
    return text.len;
}

fn offsetAtColumn(line: []const u8, columns_max: usize, target_column: usize) usize {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < line.len) {
        const unit = displayUnit(line[index..]);
        const unit_columns = fittedColumns(&unit, columns_max);
        if (columns + unit_columns > target_column) break;
        columns += unit_columns;
        index += unit.bytes;
    }
    return index;
}

/// Byte offset immediately after the canonical display unit at `offset`.
pub fn boundaryAfter(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    return offset + displayUnit(text[offset..]).bytes;
}

/// Byte offset of the canonical display-unit boundary immediately before
/// `offset`, which must itself be a boundary; an offset past the end clamps to
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
            .space => if (unit_columns > 0) try writer.writeAll(grapheme_boundary ++ " " ++ grapheme_boundary),
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
        "a" ++ grapheme_boundary ++ " " ++ grapheme_boundary ++ replacement ++ replacement ++ replacement ++ replacement ++
            replacement ++ replacement ++ replacement ++ grapheme_boundary ++ "b",
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
    try std.testing.expectEqualStrings(grapheme_boundary ++ " " ++ grapheme_boundary ++ "\u{FE0F}", out.written());
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
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 0 }, caret("你", 1));
}

test "grapheme clusters measure as one terminal cell" {
    // Each renders as a single glyph and is measured as the cell a mode-2027
    // terminal draws, not the sum of its code points.

    // Heart plus VS16 promotes to a two-cell emoji; VS15 keeps it at one.
    try std.testing.expectEqual(@as(usize, 2), ofText("❤\u{FE0F}"));
    try std.testing.expectEqual(@as(usize, 1), ofText("❤\u{FE0E}"));
    // A keycap sequence — digit, selector, enclosing keycap — is two columns.
    try std.testing.expectEqual(@as(usize, 2), ofText("1\u{FE0F}\u{20E3}"));
    // Thumbs-up plus skin-tone modifier: one two-column glyph.
    try std.testing.expectEqual(@as(usize, 2), ofText("👍\u{1F3FD}"));
    // ZWJ family: four emoji joined into one two-column glyph.
    try std.testing.expectEqual(@as(usize, 2), ofText("👨\u{200D}👩\u{200D}👧\u{200D}👦"));
    // A regional-indicator flag is one two-column glyph; two flags are four.
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
}

test rows {
    try std.testing.expectEqual(@as(usize, 1), rows("", 3));
    try std.testing.expectEqual(@as(usize, 2), rows("abcd", 3));
}

test "canonical display boundaries follow rendered replacement units" {
    try std.testing.expectEqual(@as(usize, 1), boundaryAfter("\xf0\x9f", 0));
    try std.testing.expectEqual(@as(usize, 1), boundaryBefore("\xf0\x9f", 2));
    try std.testing.expectEqual(@as(usize, 1), boundaryBefore("ab", 100));
    try std.testing.expectEqual(@as(usize, 1), boundaryBefore("\r\n", 2));
    try std.testing.expectEqual(@as(usize, 2), boundaryAfter("\xc2\x9b", 0));
    try std.testing.expectEqual(@as(usize, 3), boundaryAtOrAfter("e\u{0301}", 1));
}

test offsetAt {
    // The inverse of caret on a plain single row.
    try std.testing.expectEqual(@as(usize, 2), offsetAt("hello", 10, .{ .rows_before = 0, .column = 2 }));
    // A newline-delimited second row, column within it.
    try std.testing.expectEqual(@as(usize, 9), offsetAt("hello\nworld", 10, .{ .rows_before = 1, .column = 3 }));
    // A width-wrapped continuation row.
    try std.testing.expectEqual(@as(usize, 4), offsetAt("abcdef", 3, .{ .rows_before = 1, .column = 1 }));
    // A column past the row's content clamps to the row's end.
    try std.testing.expectEqual(@as(usize, 9), offsetAt("abcdef\nxy", 10, .{ .rows_before = 1, .column = 9 }));
    // A row past the last wrapped row clamps to the end of text.
    try std.testing.expectEqual(@as(usize, 11), offsetAt("hello\nworld", 10, .{ .rows_before = 5, .column = 0 }));
    // A column inside a two-cell cluster lands on the boundary before it.
    try std.testing.expectEqual(@as(usize, 0), offsetAt("你好世", 10, .{ .rows_before = 0, .column = 1 }));
    try std.testing.expectEqual(@as(usize, 3), offsetAt("你好世", 10, .{ .rows_before = 0, .column = 3 }));
    // The inverse of the full-width-margin caret: the next row's first column
    // maps back to the end of the filled row.
    try std.testing.expectEqual(@as(usize, 3), offsetAt("hel", 3, .{ .rows_before = 1, .column = 0 }));
    // Column 0 of a blank row between two newlines.
    try std.testing.expectEqual(@as(usize, 2), offsetAt("a\n\nb", 10, .{ .rows_before = 1, .column = 0 }));
}

test caret {
    try std.testing.expectEqual(Caret{ .rows_before = 0, .column = 0 }, caret("", 3));
    try std.testing.expectEqual(Caret{ .rows_before = 0, .column = 2 }, caret("he", 3));
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 0 }, caret("hel", 3));
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 0 }, caret("你你", 4));
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 1 }, caret("hell", 3));
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 2 }, caret("你好", 3));
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 1 }, caret("ab\nc", 10));
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 0 }, caret("a\n", 10));
    try std.testing.expectEqual(Caret{ .rows_before = 2, .column = 0 }, caret("a\n\n", 10));
}
