//! A minimal terminal emulator used only by `Surface` tests. It consumes the
//! byte stream the renderer writes and maintains a visible grid, a scrollback
//! of rows that scrolled off the top, and the cursor position and visibility —
//! enough to assert "the screen looks like this" instead of comparing raw
//! escape bytes.
//!
//! It understands exactly the escapes the `Surface` emits: carriage return and
//! line feed, cursor up/down/forward, erase-to-end-of-screen, erase-line, the
//! full screen+scrollback reset, and cursor show/hide. Synchronized-output and
//! colour (SGR) sequences are recognised and ignored; other escapes are skipped
//! as zero-width, matching `width`.

const std = @import("std");

const Emulator = @This();

const blank = ' ';

gpa: std.mem.Allocator,
columns: usize,
rows: usize,
/// Row-major visible grid of codepoints; `blank` is an empty cell.
grid: []u21,
/// Rows that scrolled above the top of the screen, oldest first.
scrollback: std.ArrayList([]u21),
cursor_row: usize,
cursor_column: usize,
cursor_visible: bool,

pub fn init(gpa: std.mem.Allocator, columns: usize, rows: usize) !Emulator {
    const grid = try gpa.alloc(u21, columns * rows);
    @memset(grid, blank);
    return .{
        .gpa = gpa,
        .columns = columns,
        .rows = rows,
        .grid = grid,
        .scrollback = .empty,
        .cursor_row = 0,
        .cursor_column = 0,
        .cursor_visible = true,
    };
}

pub fn deinit(self: *Emulator) void {
    for (self.scrollback.items) |row| self.gpa.free(row);
    self.scrollback.deinit(self.gpa);
    self.gpa.free(self.grid);
}

/// Feed one chunk of renderer output, updating the grid, scrollback, and cursor.
pub fn write(self: *Emulator, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        switch (byte) {
            0x1b => index += try self.escape(bytes[index..]),
            '\r' => {
                self.cursor_column = 0;
                index += 1;
            },
            '\n' => {
                try self.lineFeed();
                index += 1;
            },
            else => index += try self.putCodepoint(bytes[index..]),
        }
    }
}

/// Visible text of `row`, written into `buffer` with trailing blanks trimmed.
pub fn rowText(self: *const Emulator, row: usize, buffer: []u8) []const u8 {
    return trimmedText(self.grid[row * self.columns ..][0..self.columns], buffer);
}

/// Visible text of scrollback row `index` (0 = oldest), trailing blanks trimmed.
pub fn scrollbackText(self: *const Emulator, index: usize, buffer: []u8) []const u8 {
    return trimmedText(self.scrollback.items[index], buffer);
}

fn trimmedText(row: []const u21, buffer: []u8) []const u8 {
    var length: usize = 0;
    for (row) |codepoint| {
        length += std.unicode.utf8Encode(codepoint, buffer[length..]) catch blk: {
            buffer[length] = '?';
            break :blk 1;
        };
    }
    while (length > 0 and buffer[length - 1] == ' ') length -= 1;
    return buffer[0..length];
}

fn putCodepoint(self: *Emulator, bytes: []const u8) !usize {
    const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1;
    const step = @min(length, bytes.len);
    const codepoint = std.unicode.utf8Decode(bytes[0..step]) catch bytes[0];
    if (self.cursor_column < self.columns) {
        self.grid[self.cursor_row * self.columns + self.cursor_column] = codepoint;
        self.cursor_column += 1;
    }
    return step;
}

fn lineFeed(self: *Emulator) !void {
    if (self.cursor_row + 1 < self.rows) {
        self.cursor_row += 1;
        return;
    }
    try self.scroll();
}

fn scroll(self: *Emulator) !void {
    const first = try self.gpa.dupe(u21, self.grid[0..self.columns]);
    try self.scrollback.append(self.gpa, first);
    std.mem.copyForwards(u21, self.grid[0 .. (self.rows - 1) * self.columns], self.grid[self.columns..]);
    @memset(self.grid[(self.rows - 1) * self.columns ..], blank);
}

/// Apply the escape sequence at the start of `text` and return its byte length.
fn escape(self: *Emulator, text: []const u8) !usize {
    if (text.len < 2) return text.len;
    switch (text[1]) {
        '[' => return self.control(text),
        // String-terminated controls (OSC/APC/DCS/PM/SOS): skip to BEL or ST.
        ']', '_', 'P', '^', 'X' => {
            var index: usize = 2;
            while (index < text.len) : (index += 1) {
                if (text[index] == 0x07) return index + 1;
                if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '\\') return index + 2;
            }
            return text.len;
        },
        else => return 2,
    }
}

/// Apply a CSI (`ESC [`) sequence and return its byte length.
fn control(self: *Emulator, text: []const u8) !usize {
    var index: usize = 2;
    const private = index < text.len and text[index] == '?';
    if (private) index += 1;
    const params_start = index;
    while (index < text.len and !(text[index] >= 0x40 and text[index] <= 0x7e)) index += 1;
    if (index >= text.len) return text.len;
    const params = text[params_start..index];
    const final = text[index];
    index += 1;

    if (private) {
        if (std.mem.eql(u8, params, "25")) self.cursor_visible = final == 'h';
        return index;
    }
    switch (final) {
        'A' => self.cursor_row -|= firstParam(params, 1),
        'B' => self.cursor_row = @min(self.rows - 1, self.cursor_row + firstParam(params, 1)),
        'C' => self.cursor_column = @min(self.columns, self.cursor_column + firstParam(params, 1)),
        'D' => self.cursor_column -|= firstParam(params, 1),
        'G' => self.cursor_column = @min(self.columns, firstParam(params, 1) -| 1),
        'H' => {
            self.cursor_row = 0;
            self.cursor_column = 0;
        },
        'J' => self.eraseDisplay(firstParam(params, 0)),
        'K' => self.eraseLine(firstParam(params, 0)),
        else => {},
    }
    return index;
}

fn eraseDisplay(self: *Emulator, mode: usize) void {
    switch (mode) {
        0 => {
            const start = self.cursor_row * self.columns + self.cursor_column;
            @memset(self.grid[start..], blank);
        },
        2 => @memset(self.grid, blank),
        3 => {
            for (self.scrollback.items) |row| self.gpa.free(row);
            self.scrollback.clearRetainingCapacity();
        },
        else => {},
    }
}

fn eraseLine(self: *Emulator, mode: usize) void {
    const row = self.grid[self.cursor_row * self.columns ..][0..self.columns];
    switch (mode) {
        0 => @memset(row[self.cursor_column..], blank),
        2 => @memset(row, blank),
        else => {},
    }
}

fn firstParam(params: []const u8, default: usize) usize {
    const end = std.mem.indexOfScalar(u8, params, ';') orelse params.len;
    return std.fmt.parseInt(usize, params[0..end], 10) catch default;
}

test "text, wrap-free lines, and line feeds fill the grid" {
    var vt = try init(std.testing.allocator, 8, 3);
    defer vt.deinit();
    try vt.write("ab\r\ncd\r\nef");

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ab", vt.rowText(0, &buffer));
    try std.testing.expectEqualStrings("cd", vt.rowText(1, &buffer));
    try std.testing.expectEqualStrings("ef", vt.rowText(2, &buffer));
    try std.testing.expectEqual(@as(usize, 2), vt.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), vt.cursor_column);
}

test "line feed at the bottom scrolls the top row into scrollback" {
    var vt = try init(std.testing.allocator, 8, 2);
    defer vt.deinit();
    try vt.write("one\r\ntwo\r\nthree");

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), vt.scrollback.items.len);
    try std.testing.expectEqualStrings("one", vt.scrollbackText(0, &buffer));
    try std.testing.expectEqualStrings("two", vt.rowText(0, &buffer));
    try std.testing.expectEqualStrings("three", vt.rowText(1, &buffer));
}

test "cursor moves, erase-to-end, and colour skipping" {
    var vt = try init(std.testing.allocator, 8, 3);
    defer vt.deinit();
    try vt.write("\x1b[31mabc\x1b[0m\r\ndef\r\nghi");
    // Up two rows, clear from cursor to the end of the screen.
    try vt.write("\x1b[2A\r\x1b[0J");

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", vt.rowText(0, &buffer));
    try std.testing.expectEqualStrings("", vt.rowText(1, &buffer));
    try std.testing.expectEqualStrings("", vt.rowText(2, &buffer));
}

test "cursor show and hide" {
    var vt = try init(std.testing.allocator, 4, 1);
    defer vt.deinit();
    try std.testing.expect(vt.cursor_visible);
    try vt.write("\x1b[?25l");
    try std.testing.expect(!vt.cursor_visible);
    try vt.write("\x1b[?25h");
    try std.testing.expect(vt.cursor_visible);
}
