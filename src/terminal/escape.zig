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

pub const cursor_hide = "\x1b[?25l";
pub const cursor_show = "\x1b[?25h";

/// Erase the entire line the cursor sits on.
pub const line_clear = "\x1b[2K";
/// Erase from the cursor to the end of the screen.
pub const screen_clear_below = "\x1b[0J";

/// Move the cursor up `count` rows. No-op at zero, so the sequence is never
/// emitted with an implicit argument.
pub fn cursorUp(writer: *std.Io.Writer, count: usize) !void {
    if (count == 0) return;
    try writer.print("\x1b[{d}A", .{count});
}
