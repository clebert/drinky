const std = @import("std");

pub const sync_set = "\x1b[?2026h";
pub const sync_reset = "\x1b[?2026l";

pub const paste_set = "\x1b[?2004h";
pub const paste_reset = "\x1b[?2004l";

pub const paste_begin = "\x1b[200~";
pub const paste_end = "\x1b[201~";

pub const keyboard_set = "\x1b[>1u";
pub const keyboard_reset = "\x1b[<u";

pub const grapheme_set = "\x1b[?2027h";
pub const grapheme_reset = "\x1b[?2027l";

pub const string_end = "\x1b\\";

pub const link_set = "\x1b]8;;";
pub const link_reset = link_set ++ string_end;

pub const cursor_hide = "\x1b[?25l";
pub const cursor_show = "\x1b[?25h";

pub const screen_alternate_set = "\x1b[?1049h";
pub const screen_alternate_reset = "\x1b[?1049l";

pub const scroll_alternate_set = "\x1b[?1007s\x1b[?1007h";
pub const scroll_alternate_reset = "\x1b[?1007r";

pub const screen_clear_below = "\x1b[0J";
pub const screen_repaint = "\x1b[2J\x1b[H";
pub const screen_reset = screen_repaint ++ "\x1b[3J";

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
