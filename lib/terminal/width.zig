const std = @import("std");

const grapheme = @import("grapheme.zig");

/// Display width of `text` in terminal columns, skipping ANSI escape sequences.
///
/// Text is measured per UAX #29 grapheme cluster (via `grapheme`), matching a
/// terminal with DECSET mode 2027: a multi-code-point glyph — a skin-tone
/// modifier, a ZWJ join, a regional-indicator flag, a keycap — takes the single
/// cell it renders as, not the sum of its code points. Combining marks and other
/// zero-width code points add nothing; East Asian wide, fullwidth, and emoji
/// clusters take two columns. ASCII control bytes count as zero.
pub fn ofText(text: []const u8) usize {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == escape_start) {
            index += escapeLength(text[index..]);
            continue;
        }
        const step = grapheme.stepAt(text[index..]);
        columns += step.columns;
        index += step.bytes;
    }
    return columns;
}

/// Longest prefix of `text` whose display width is at most `columns_max`,
/// skipping ANSI escapes when measuring. A trailing escape sequence that would
/// not add width is dropped along with the content it followed. A grapheme
/// cluster that would straddle the budget is dropped whole.
pub fn truncate(text: []const u8, columns_max: usize) []const u8 {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == escape_start) {
            index += escapeLength(text[index..]);
            continue;
        }
        const step = grapheme.stepAt(text[index..]);
        if (columns + step.columns > columns_max) break;
        columns += step.columns;
        index += step.bytes;
    }
    return text[0..index];
}

/// Hard-wrap `text` into slices of at most `columns_max` display columns,
/// appending each line into `lines`. Breaks strictly on width (no word
/// awareness) and never inside a grapheme cluster. An explicit `\n` starts a new
/// line and is not emitted.
pub fn wrap(
    text: []const u8,
    columns_max: usize,
    lines: *std.ArrayList([]const u8),
    gpa: std.mem.Allocator,
) !void {
    var iterator = wrapper(text, columns_max);
    while (iterator.next()) |line| try lines.append(gpa, line);
}

/// A streaming view of `wrap`: yields the same lines one at a time instead of
/// appending them all at once, so a caller can drop the rows above a window
/// without ever materializing the whole list. `next` returns each fitted line in
/// turn (a slice into `text`), then null. The sequence is identical to `wrap`'s
/// output, so `wrap`, `rows`, `caret`, and this stay in lockstep.
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
            if (byte == escape_start) {
                index += escapeLength(text[index..]);
                continue;
            }
            const step = grapheme.stepAt(text[index..]);
            if (columns + step.columns > self.columns_max and index > self.line_start) {
                const line = text[self.line_start..index];
                self.line_start = index;
                return line;
            }
            columns += step.columns;
            index += step.bytes;
        }
        self.done = true;
        return text[self.line_start..];
    }
};

/// Wrap `text` to at most `columns_max` display columns one line at a time — the
/// streaming form `wrap`, `rows`, and `caret` are all built on, so they stay in
/// lockstep by construction.
pub fn wrapper(text: []const u8, columns_max: usize) Wrapper {
    return .{ .text = text, .columns_max = columns_max, .line_start = 0, .done = false };
}

/// Number of physical terminal rows `text` occupies once hard-wrapped to
/// `columns_max` display columns — the count of pieces `wrap` produces. Always
/// at least one; an explicit `\n` starts a new row. A wide cluster that would
/// straddle the margin breaks to the next row, so this is not `ceil(width /
/// columns)`.
pub fn rows(text: []const u8, columns_max: usize) usize {
    var iterator = wrapper(text, columns_max);
    var count: usize = 0;
    while (iterator.next()) |_| count += 1;
    return count;
}

pub const Caret = struct { rows_before: usize, column: usize };

/// Physical position of a caret sitting at the end of `text` once wrapped to
/// `columns_max`: how many row breaks precede it and its column within that row.
/// `text` is the content up to the caret, so pass the prefix before it — a
/// greedy width wrap never lets later content move an earlier break, so the
/// suffix cannot change the answer. Built on `wrapper`, so it mirrors `wrap` for
/// free: a wide cluster near the margin pushes the caret to the next row, and a
/// trailing `\n` (or an empty line between newlines) lands it at column 0 of a
/// fresh row. `text` must end on a codepoint boundary.
pub fn caret(text: []const u8, columns_max: usize) Caret {
    var iterator = wrapper(text, columns_max);
    var result: Caret = .{ .rows_before = 0, .column = 0 };
    var first = true;
    while (iterator.next()) |line| {
        if (!first) result.rows_before += 1;
        first = false;
        result.column = ofText(line);
    }
    return result;
}

const escape_start = 0x1b;

/// Byte length of the escape sequence at the start of `text` (`text[0]` is ESC).
/// Always at least one so callers make progress on malformed input.
fn escapeLength(text: []const u8) usize {
    if (text.len < 2) return text.len;
    switch (text[1]) {
        '[' => {
            var index: usize = 2;
            while (index < text.len) : (index += 1) {
                if (text[index] >= 0x40 and text[index] <= 0x7e) return index + 1;
            }
            return text.len;
        },
        // String-terminated controls: OSC, APC, DCS, PM, SOS. Each runs to a
        // BEL or the ST sequence (ESC `\`). The zero-width cursor marker is an
        // APC string, so it is measured here and never counts toward a column.
        ']', '_', 'P', '^', 'X' => {
            var index: usize = 2;
            while (index < text.len) : (index += 1) {
                if (text[index] == 0x07) return index + 1;
                if (text[index] == escape_start and index + 1 < text.len and text[index + 1] == '\\') {
                    return index + 2;
                }
            }
            return text.len;
        },
        else => return 2,
    }
}

test ofText {
    try std.testing.expectEqual(@as(usize, 5), ofText("hello"));
    try std.testing.expectEqual(@as(usize, 0), ofText(""));
    try std.testing.expectEqual(@as(usize, 3), ofText("a\x1b[31mbc\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 2), ofText("\x1b]8;;http://x\x07hi\x1b]8;;\x07"));
    try std.testing.expectEqual(@as(usize, 1), ofText("é"));
    // The APC cursor marker is zero-width and does not split a wrapped line.
    try std.testing.expectEqual(@as(usize, 2), ofText("a\x1b_p\x1b\\b"));
    // An escape cut off at the buffer end is consumed without adding columns:
    // a bare trailing ESC, then a CSI with no final byte.
    try std.testing.expectEqual(@as(usize, 1), ofText("x\x1b"));
    try std.testing.expectEqual(@as(usize, 0), ofText("\x1b[31"));
}

test "ofText measures wide glyphs and zero-width marks" {
    try std.testing.expectEqual(@as(usize, 4), ofText("你好"));
    try std.testing.expectEqual(@as(usize, 2), ofText("😀"));
    try std.testing.expectEqual(@as(usize, 4), ofText("a你b"));
    // A base letter plus a combining mark is a single column.
    try std.testing.expectEqual(@as(usize, 1), ofText("e\u{0301}"));
}

test "ofText counts control bytes as zero and survives malformed utf-8" {
    // Tab and DEL are ASCII control bytes and add no columns.
    try std.testing.expectEqual(@as(usize, 2), ofText("a\tb"));
    try std.testing.expectEqual(@as(usize, 0), ofText("\x7f"));
    // An invalid lead byte is one replacement column and still makes progress.
    try std.testing.expectEqual(@as(usize, 1), ofText("\xff"));
    // A multi-byte sequence cut off at the buffer end is one column, not a
    // panic — a 4-byte emoji leader and a 3-byte CJK leader, each short a tail.
    try std.testing.expectEqual(@as(usize, 1), ofText("\xf0\x9f"));
    try std.testing.expectEqual(@as(usize, 1), ofText("\xf0\x9f\x98"));
    try std.testing.expectEqual(@as(usize, 1), ofText("\xe4\xb8"));
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
    try std.testing.expectEqualStrings("a\x1b[31mb", truncate("a\x1b[31mbc", 2));
    // Content past the budget is dropped together with the escape trailing it.
    try std.testing.expectEqualStrings("ab", truncate("abc\x1b[0m", 2));
    // "好" is two columns, so it never fits a single spare column.
    try std.testing.expectEqualStrings("你", truncate("你好", 3));
    try std.testing.expectEqualStrings("你", truncate("你好", 2));
    try std.testing.expectEqualStrings("", truncate("你好", 1));
    // A flag is one two-column cluster: it fits two columns whole or not at all.
    try std.testing.expectEqualStrings("🇯🇵", truncate("🇯🇵", 2));
    try std.testing.expectEqualStrings("", truncate("🇯🇵", 1));
}

test wrapper {
    // Width break, explicit newline, a wide cluster that cannot straddle, an
    // empty input yielding one empty line, and a trailing newline's empty tail.
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
}

test wrap {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    try wrap("abcdef", 3, &lines, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("abc", lines.items[0]);
    try std.testing.expectEqualStrings("def", lines.items[1]);

    lines.clearRetainingCapacity();
    try wrap("ab\ncd", 10, &lines, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("ab", lines.items[0]);
    try std.testing.expectEqualStrings("cd", lines.items[1]);

    // A wide glyph that would straddle the limit breaks to the next line whole.
    lines.clearRetainingCapacity();
    try wrap("你好世", 3, &lines, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("你", lines.items[0]);
    try std.testing.expectEqualStrings("好", lines.items[1]);
    try std.testing.expectEqualStrings("世", lines.items[2]);

    // An empty input still yields one (empty) line.
    lines.clearRetainingCapacity();
    try wrap("", 3, &lines, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("", lines.items[0]);

    // An embedded escape adds no width and does not force a break.
    lines.clearRetainingCapacity();
    try wrap("a\x1b[31mbc", 3, &lines, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("a\x1b[31mbc", lines.items[0]);
}

test rows {
    try std.testing.expectEqual(@as(usize, 1), rows("", 3));
    try std.testing.expectEqual(@as(usize, 1), rows("abc", 3));
    try std.testing.expectEqual(@as(usize, 2), rows("abcd", 3));
    // A wide cluster that cannot straddle the margin costs an extra row: three
    // two-column glyphs in three columns take one row each, not two total.
    try std.testing.expectEqual(@as(usize, 3), rows("你好世", 3));
    // An explicit newline starts a fresh row; an escape adds none.
    try std.testing.expectEqual(@as(usize, 2), rows("ab\ncd", 10));
    try std.testing.expectEqual(@as(usize, 1), rows("a\x1b[31mbc", 3));
}

test caret {
    // Within the first row, the caret column equals the prefix's display width.
    try std.testing.expectEqual(Caret{ .rows_before = 0, .column = 0 }, caret("", 3));
    try std.testing.expectEqual(Caret{ .rows_before = 0, .column = 2 }, caret("he", 3));
    // A prefix that exactly fills the budget sits pending at the margin.
    try std.testing.expectEqual(Caret{ .rows_before = 0, .column = 3 }, caret("hel", 3));
    // One glyph past the margin wraps: the second row, first column.
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 1 }, caret("hell", 3));
    // Wide glyphs push the wrap early: after two two-column glyphs the caret is
    // on the second row at column two, not row one.
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 2 }, caret("你好", 3));
    // An explicit newline starts a fresh row, like wrap.
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 1 }, caret("ab\nc", 10));
    // A trailing newline lands the caret at column 0 of the empty next row
    // (also the blank line between two newlines), and consecutive newlines each
    // add another such row.
    try std.testing.expectEqual(Caret{ .rows_before = 1, .column = 0 }, caret("a\n", 10));
    try std.testing.expectEqual(Caret{ .rows_before = 2, .column = 0 }, caret("a\n\n", 10));
}
