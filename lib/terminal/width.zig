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
    var line_start: usize = 0;
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\n') {
            try lines.append(gpa, text[line_start..index]);
            index += 1;
            line_start = index;
            columns = 0;
            continue;
        }
        if (byte == escape_start) {
            index += escapeLength(text[index..]);
            continue;
        }
        const step = grapheme.stepAt(text[index..]);
        if (columns + step.columns > columns_max and index > line_start) {
            try lines.append(gpa, text[line_start..index]);
            line_start = index;
            columns = 0;
        }
        columns += step.columns;
        index += step.bytes;
    }
    try lines.append(gpa, text[line_start..]);
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
