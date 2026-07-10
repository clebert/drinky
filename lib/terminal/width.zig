const std = @import("std");

/// Display width of `text` in terminal columns, skipping ANSI escape sequences.
///
/// Approximation: one column per printable codepoint, zero for ASCII control
/// bytes. CJK and emoji are not yet special-cased, so wide glyphs undercount by
/// one column each. This matches a default-mode terminal for ASCII, Latin, and
/// code, which is all the current UI emits.
pub fn display(text: []const u8) usize {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == escape_start) {
            index += escapeLength(text[index..]);
            continue;
        }
        const step = cellAt(text[index..]);
        columns += step.columns;
        index += step.bytes;
    }
    return columns;
}

/// Longest prefix of `text` whose display width is at most `columns_max`,
/// skipping ANSI escapes when measuring. A trailing escape sequence that would
/// not add width is dropped along with the content it followed.
pub fn truncate(text: []const u8, columns_max: usize) []const u8 {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == escape_start) {
            index += escapeLength(text[index..]);
            continue;
        }
        const step = cellAt(text[index..]);
        if (columns + step.columns > columns_max) break;
        columns += step.columns;
        index += step.bytes;
    }
    return text[0..index];
}

/// Hard-wrap `text` into slices of at most `columns_max` display columns,
/// appending each line into `lines`. Breaks strictly on width (no word
/// awareness). An explicit `\n` starts a new line and is not emitted.
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
        const step = cellAt(text[index..]);
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

const Cell = struct { bytes: usize, columns: usize };

fn cellAt(text: []const u8) Cell {
    const byte = text[0];
    if (byte < 0x80) {
        const printable = byte >= 0x20 and byte != 0x7f;
        return .{ .bytes = 1, .columns = @intFromBool(printable) };
    }
    const length = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .bytes = 1, .columns = 1 };
    return .{ .bytes = @min(length, text.len), .columns = 1 };
}

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

test display {
    try std.testing.expectEqual(@as(usize, 5), display("hello"));
    try std.testing.expectEqual(@as(usize, 0), display(""));
    try std.testing.expectEqual(@as(usize, 3), display("a\x1b[31mbc\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 2), display("\x1b]8;;http://x\x07hi\x1b]8;;\x07"));
    try std.testing.expectEqual(@as(usize, 1), display("é"));
    // The APC cursor marker is zero-width and does not split a wrapped line.
    try std.testing.expectEqual(@as(usize, 2), display("a\x1b_p\x1b\\b"));
}

test truncate {
    try std.testing.expectEqualStrings("hel", truncate("hello", 3));
    try std.testing.expectEqualStrings("hello", truncate("hello", 10));
    try std.testing.expectEqualStrings("", truncate("hello", 0));
    try std.testing.expectEqualStrings("a\x1b[31mb", truncate("a\x1b[31mbc", 2));
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
}
