//! The ANSI escape sequences the renderer trusts: mode set/reset pairs, screen
//! clears, and bounded cursor motion. Nothing here carries runtime content.

const std = @import("std");

/// Begin/end a synchronized-output burst so a multi-line repaint lands atomically.
pub const sync_set = "\x1b[?2026h";
pub const sync_reset = "\x1b[?2026l";

/// Enable/disable bracketed paste, so pasted text arrives framed and is not
/// mistaken for typed control sequences.
pub const paste_set = "\x1b[?2004h";
pub const paste_reset = "\x1b[?2004l";

/// Framing a terminal wraps around pasted text once bracketed paste is enabled.
pub const paste_begin = "\x1b[200~";
pub const paste_end = "\x1b[201~";

/// Push/pop the Kitty keyboard protocol with the disambiguate flag. It leaves
/// plain Enter, Backspace, and printable keys as their legacy bytes but reports
/// Shift+Enter, Escape, and Ctrl combinations as distinct `CSI ... u` sequences.
/// Popping restores whatever mode was active before.
pub const keyboard_set = "\x1b[>1u";
pub const keyboard_reset = "\x1b[<u";

pub const cursor_hide = "\x1b[?25l";
pub const cursor_show = "\x1b[?25h";

/// Erase from the cursor to the end of the screen.
pub const screen_clear_below = "\x1b[0J";
/// Clear the whole screen, home the cursor, then drop the scrollback: the full
/// reset used when a change lands above the viewport and the buffer must be
/// reprinted from scratch.
pub const screen_reset = "\x1b[2J\x1b[H\x1b[3J";

/// Move the cursor `count` steps: up (`'A'`), down (`'B'`), or right (`'C'`).
/// No-op at zero, so the sequence is never emitted with an implicit argument.
pub fn cursorMove(writer: *std.Io.Writer, comptime final: u8, count: usize) !void {
    if (count == 0) return;
    try writer.print("\x1b[{d}{c}", .{ count, final });
}

test "cursor motion emits nothing at zero" {
    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try cursorMove(&writer, 'A', 0);
    try cursorMove(&writer, 'B', 0);
    try cursorMove(&writer, 'C', 0);
    try std.testing.expectEqualStrings("", writer.buffered());
    try cursorMove(&writer, 'A', 2);
    try cursorMove(&writer, 'B', 3);
    try cursorMove(&writer, 'C', 4);
    try std.testing.expectEqualStrings("\x1b[2A\x1b[3B\x1b[4C", writer.buffered());
}
