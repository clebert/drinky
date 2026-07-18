//! A model terminal for the `View` tests: it applies exactly the escapes `View`
//! emits — cursor motion, clears, and auto-wrapping text — and reconstructs what
//! the screen shows. Cursor position is physical and scrolled-off rows are
//! unaddressable, so a miscounted row or a move past a margin corrupts the
//! reconstruction instead of silently "working".

const std = @import("std");

const grapheme = @import("grapheme.zig");

const Emulator = @This();

gpa: std.mem.Allocator,
columns: usize,
rows: usize,
document: std.ArrayList(std.ArrayList(u8)),
// Document index of the screen's top row; the rows above it are scrollback.
screen_top: usize,
cursor_row: usize,
cursor_column: usize,
cursor_visible: bool,

pub fn init(gpa: std.mem.Allocator, columns: usize) !Emulator {
    var document: std.ArrayList(std.ArrayList(u8)) = .empty;
    try document.append(gpa, .empty);
    return .{
        .gpa = gpa,
        .columns = columns,
        .rows = 0,
        .document = document,
        .screen_top = 0,
        .cursor_row = 0,
        .cursor_column = 0,
        .cursor_visible = false,
    };
}

pub fn deinit(self: *Emulator) void {
    for (self.document.items) |*row| row.deinit(self.gpa);
    self.document.deinit(self.gpa);
}

pub fn feed(self: *Emulator, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte == 0x1b) {
            index += try self.control(bytes[index..]);
            continue;
        }
        if (byte == '\r') {
            self.cursor_column = 0;
            index += 1;
            continue;
        }
        if (byte == '\n') {
            try self.lineFeed();
            index += 1;
            continue;
        }
        const step = grapheme.stepAt(bytes[index..]);
        try self.put(bytes[index .. index + step.bytes], step.columns);
        index += step.bytes;
    }
}

fn control(self: *Emulator, sequence: []const u8) !usize {
    if (sequence.len < 2) return sequence.len;
    switch (sequence[1]) {
        '[' => return self.csi(sequence),
        ']', '_', 'P', '^', 'X' => {
            var index: usize = 2;
            while (index < sequence.len) : (index += 1) {
                if (sequence[index] == 0x07) return index + 1;
                if (sequence[index] == 0x1b and index + 1 < sequence.len and sequence[index + 1] == '\\') {
                    return index + 2;
                }
            }
            return sequence.len;
        },
        else => return 2,
    }
}

fn csi(self: *Emulator, sequence: []const u8) !usize {
    var index: usize = 2;
    while (index < sequence.len and (sequence[index] < 0x40 or sequence[index] > 0x7e)) : (index += 1) {}
    if (index >= sequence.len) return sequence.len;
    const params = sequence[2..index];
    switch (sequence[index]) {
        // A real terminal treats an explicit 0 count as 1, so an emitted `\x1b[0A`
        // moves here too instead of masking a missing zero guard in `escape`.
        'A' => {
            std.debug.assert(self.cursor_row >= self.screen_top);
            self.cursor_row -= @min(@max(csiValue(params, 1), 1), self.cursor_row - self.screen_top);
        },
        // CUD clamps at the bottom row; it never scrolls or grows the document.
        'B' => self.cursor_row = @min(self.cursor_row + @max(csiValue(params, 1), 1), self.document.items.len - 1),
        // CUF clamps at the right margin; it cannot reach a pending-wrap cell.
        'C' => self.cursor_column = @min(self.cursor_column + @max(csiValue(params, 1), 1), self.columns - 1),
        'H' => {
            self.cursor_row = self.screen_top;
            self.cursor_column = 0;
        },
        'J' => switch (csiValue(params, 0)) {
            2 => try self.clearScreen(),
            0 => try self.clearBelow(),
            else => {},
        },
        'h' => if (std.mem.eql(u8, params, "?25")) {
            self.cursor_visible = true;
        },
        'l' => if (std.mem.eql(u8, params, "?25")) {
            self.cursor_visible = false;
        },
        else => {},
    }
    return index + 1;
}

fn clearScreen(self: *Emulator) !void {
    for (self.document.items) |*row| row.deinit(self.gpa);
    self.document.clearRetainingCapacity();
    try self.document.append(self.gpa, .empty);
    self.cursor_row = 0;
    self.cursor_column = 0;
    self.screen_top = 0;
}

// Advance the cursor one physical row, scrolling the screen's top row into
// scrollback when the cursor is already on the bottom row — a terminal's
// auto-scroll, which is what makes evicted rows unaddressable.
fn lineFeed(self: *Emulator) !void {
    if (self.rows > 0 and self.cursor_row + 1 >= self.screen_top + self.rows) self.screen_top += 1;
    self.cursor_row += 1;
    try self.ensureRow(self.cursor_row);
}

fn clearBelow(self: *Emulator) !void {
    while (self.document.items.len > self.cursor_row + 1) {
        var row = self.document.pop().?;
        row.deinit(self.gpa);
    }
    self.document.items[self.cursor_row].clearRetainingCapacity();
}

fn ensureRow(self: *Emulator, row: usize) !void {
    while (self.document.items.len <= row) try self.document.append(self.gpa, .empty);
}

fn put(self: *Emulator, bytes: []const u8, columns: usize) !void {
    if (self.cursor_column + columns > self.columns and self.cursor_column > 0) {
        try self.lineFeed();
        self.cursor_column = 0;
    }
    try self.ensureRow(self.cursor_row);
    try self.document.items[self.cursor_row].appendSlice(self.gpa, bytes);
    self.cursor_column += columns;
}

fn csiValue(params: []const u8, default: usize) usize {
    return std.fmt.parseInt(usize, params, 10) catch default;
}

// The current frame occupies the last `frame.len` rows of the document; the
// rows above are scrollback from earlier paints.
pub fn expectVisible(self: *Emulator, frame: []const []const u8) !void {
    try std.testing.expect(self.document.items.len >= frame.len);
    const base = self.document.items.len - frame.len;
    for (frame, 0..) |row, index| {
        try std.testing.expectEqualStrings(row, self.document.items[base + index].items);
    }
}

pub fn expectCaret(self: *Emulator, frame_len: usize, row: usize, column: usize) !void {
    try std.testing.expect(self.cursor_visible);
    try std.testing.expectEqual(self.document.items.len - frame_len + row, self.cursor_row);
    try std.testing.expectEqual(column, self.cursor_column);
}

// The physical screen: the `rows` rows at and below the scroll top. Rows that
// scrolled past the top are excluded, so a repaint that leaves stale content on
// screen or fails to reveal a row it moved into view is caught.
pub fn expectScreen(self: *Emulator, screen: []const []const u8) !void {
    for (screen, 0..) |row, index| {
        const at = self.screen_top + index;
        const actual = if (at < self.document.items.len) self.document.items[at].items else "";
        try std.testing.expectEqualStrings(row, actual);
    }
}
