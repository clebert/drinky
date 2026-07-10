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

/// Erase the entire line the cursor sits on.
pub const line_clear = "\x1b[2K";
/// Erase from the cursor to the end of the screen.
pub const screen_clear_below = "\x1b[0J";
/// Clear the whole screen, home the cursor, then drop the scrollback: the full
/// reset used when a change lands above the viewport and the buffer must be
/// reprinted from scratch.
pub const screen_reset = "\x1b[2J\x1b[H\x1b[3J";

/// Move the cursor up `count` rows. No-op at zero, so the sequence is never
/// emitted with an implicit argument.
pub fn cursorUp(writer: *std.Io.Writer, count: usize) !void {
    if (count == 0) return;
    try writer.print("\x1b[{d}A", .{count});
}

/// Move the cursor down `count` rows, no-op at zero.
pub fn cursorDown(writer: *std.Io.Writer, count: usize) !void {
    if (count == 0) return;
    try writer.print("\x1b[{d}B", .{count});
}

/// Move the cursor right `count` columns, no-op at zero.
pub fn cursorForward(writer: *std.Io.Writer, count: usize) !void {
    if (count == 0) return;
    try writer.print("\x1b[{d}C", .{count});
}
