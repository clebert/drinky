//! The hardware-cursor marker. Terminology: the *caret* is a component's own
//! logical insertion point; the *cursor* is the terminal's hardware cursor. A
//! focused component embeds `marker` at its caret so the `Surface` can learn
//! which line and column that is, strip it, and move the hardware cursor there
//! after the repaint.
//!
//! The marker is an APC string: terminals ignore it, and `width` measures it as
//! zero columns, so it rides along through wrapping without shifting any text
//! and never reaches the screen (the `Surface` removes it first).

const std = @import("std");

const width = @import("width.zig");

pub const marker = "\x1b_p\x1b\\";

/// The caret's display column within `line` if it carries the marker.
pub fn column(line: []const u8) ?usize {
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    return width.ofText(line[0..at]);
}

test column {
    try std.testing.expectEqual(@as(?usize, null), column("no caret here"));
    try std.testing.expectEqual(@as(?usize, 0), column(marker ++ "hi"));
    try std.testing.expectEqual(@as(?usize, 3), column("hi!" ++ marker));
    // Escapes before the marker do not count toward the column.
    try std.testing.expectEqual(@as(?usize, 2), column("\x1b[31mab\x1b[0m" ++ marker));
}
