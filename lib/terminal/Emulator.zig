//! A model terminal for the `View` tests. It applies exactly the escapes `View`
//! emits — cursor motion, clears, and auto-wrapping text — and reconstructs what
//! the screen shows. The cursor position is physical, and scrolled-off rows are
//! unaddressable. A miscounted row or a move past a margin then corrupts the
//! reconstruction instead of silently "working".

const std = @import("std");

const grapheme = @import("grapheme.zig");

const Emulator = @This();

gpa: std.mem.Allocator,
columns: usize,
rows: usize,
document: std.ArrayList(std.ArrayList(u8)),
// The document index of the screen's top row. The rows above it are scrollback.
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

/// Keep the cursor visible when the screen loses rows. Added rows stay blank below.
pub fn resize(self: *Emulator, rows: usize) void {
    const height = @max(rows, 1);
    if (self.rows > 0 and height < @max(self.rows, 1)) {
        const cursor_top = self.cursor_row -| (height - 1);
        self.screen_top = @max(self.screen_top, cursor_top);
    }
    self.rows = rows;
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
    if (sequence[1] == '[') return self.csi(sequence);
    if (sequence[1] == ']') return osc(sequence);
    return 2;
}

/// Consume one OSC string, such as a hyperlink. It shows nothing and moves
/// nothing, so the model terminal drops it. A string ends at ST or at BEL. Any
/// other escape ends it too and stays for the parser, the way a real terminal
/// leaves a string on the first control it cannot hold.
fn osc(sequence: []const u8) usize {
    var index: usize = 2;
    while (index < sequence.len) : (index += 1) {
        if (sequence[index] == 0x07) return index + 1;
        if (sequence[index] != 0x1b) continue;
        if (index + 1 < sequence.len and sequence[index + 1] == '\\') return index + 2;
        return index;
    }
    return sequence.len;
}

fn csi(self: *Emulator, sequence: []const u8) !usize {
    var index: usize = 2;
    while (index < sequence.len and (sequence[index] < 0x40 or sequence[index] > 0x7e)) {
        index += 1;
    }
    if (index >= sequence.len) return sequence.len;
    const parameters = sequence[2..index];
    switch (sequence[index]) {
        // A real terminal treats an explicit 0 count as 1. An emitted `\x1b[0A`
        // therefore moves here too and does not mask a missing zero guard in `escape`.
        'A' => {
            std.debug.assert(self.cursor_row >= self.screen_top);
            const count = @max(csiValue(parameters, 1), 1);
            self.cursor_row -= @min(count, self.cursor_row - self.screen_top);
        },
        // CUD clamps at the bottom row. It never scrolls the screen.
        'B' => {
            const count = @max(csiValue(parameters, 1), 1);
            const screen_bottom = self.screen_top + @max(self.rows, 1) - 1;
            self.cursor_row = @min(self.cursor_row + count, screen_bottom);
            try self.ensureRow(self.cursor_row);
        },
        // CUF clamps at the right margin. It cannot reach a pending-wrap cell.
        'C' => {
            const count = @max(csiValue(parameters, 1), 1);
            self.cursor_column = @min(self.cursor_column + count, self.columns - 1);
        },
        'H' => {
            self.cursor_row = self.screen_top;
            self.cursor_column = 0;
            self.trimBlankTail();
        },
        'J' => switch (csiValue(parameters, 0)) {
            0 => try self.clearBelow(),
            2 => self.clearScreen(),
            3 => self.clearScrollback(),
            else => {},
        },
        'h' => if (std.mem.eql(u8, parameters, "?25")) {
            self.cursor_visible = true;
        },
        'l' => if (std.mem.eql(u8, parameters, "?25")) {
            self.cursor_visible = false;
        },
        else => {},
    }
    return index + 1;
}

// Erase the visible rows. ED 2 does not move the cursor or erase scrollback.
fn clearScreen(self: *Emulator) void {
    const screen_end = @min(
        self.document.items.len,
        self.screen_top + @max(self.rows, 1),
    );
    for (self.document.items[self.screen_top..screen_end]) |*row| {
        row.clearRetainingCapacity();
    }
}

// Erase only the rows above the screen. ED 3 keeps the visible rows and cursor.
fn clearScrollback(self: *Emulator) void {
    std.debug.assert(self.cursor_row >= self.screen_top);
    const dropped = self.screen_top;
    if (dropped == 0) return;
    for (self.document.items[0..dropped]) |*row| row.deinit(self.gpa);
    const kept = self.document.items.len - dropped;
    std.mem.copyForwards(
        std.ArrayList(u8),
        self.document.items[0..kept],
        self.document.items[dropped..],
    );
    self.document.shrinkRetainingCapacity(kept);
    self.cursor_row -= dropped;
    self.screen_top = 0;
}

// The view emits H only after ED 2. The sparse document can omit the trailing
// rows because ED 2 made them blank.
fn trimBlankTail(self: *Emulator) void {
    while (self.document.items.len > self.cursor_row + 1 and
        self.document.items[self.document.items.len - 1].items.len == 0)
    {
        var row = self.document.pop().?;
        row.deinit(self.gpa);
    }
}

// Advance the cursor one physical row. When the cursor is already on the
// bottom row, scroll the screen's top row into scrollback. This is a
// terminal's auto-scroll, which makes evicted rows unaddressable.
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

fn csiValue(parameters: []const u8, default: usize) usize {
    return std.fmt.parseInt(usize, parameters, 10) catch default;
}

// The current frame occupies the last `frame.len` rows of the document. The
// rows above are scrollback from earlier paints.
pub fn expectVisible(self: *Emulator, frame: []const []const u8) !void {
    try std.testing.expect(self.document.items.len >= frame.len);
    const base = self.document.items.len - frame.len;
    for (frame, 0..) |row, index| {
        try std.testing.expectEqualStrings(row, self.document.items[base + index].items);
    }
}

pub fn expectCaret(
    self: *Emulator,
    expected: struct { frame_len: usize, row: usize, column: usize },
) !void {
    try std.testing.expect(self.cursor_visible);
    const row = self.document.items.len - expected.frame_len + expected.row;
    try std.testing.expectEqual(row, self.cursor_row);
    try std.testing.expectEqual(expected.column, self.cursor_column);
}

// The physical screen: the `rows` rows at and below the screen top. Rows that
// scrolled past the top are excluded. The check then catches a repaint that
// leaves stale content on screen or fails to reveal a row it moved into view.
pub fn expectScreen(self: *Emulator, screen: []const []const u8) !void {
    for (screen, 0..) |row, index| {
        const at = self.screen_top + index;
        const actual = if (at < self.document.items.len) self.document.items[at].items else "";
        try std.testing.expectEqualStrings(row, actual);
    }
}

test "ED 2 preserves scrollback and ED 3 removes it" {
    const gpa = std.testing.allocator;
    var emulator = try Emulator.init(gpa, 20);
    defer emulator.deinit();
    emulator.rows = 2;

    try emulator.feed("old\r\none\r\ntwo");
    try std.testing.expectEqual(@as(usize, 1), emulator.screen_top);
    try std.testing.expectEqualStrings("old", emulator.document.items[0].items);

    try emulator.feed("\x1b[2J");
    try std.testing.expectEqual(@as(usize, 1), emulator.screen_top);
    try std.testing.expectEqual(@as(usize, 2), emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), emulator.cursor_column);
    try std.testing.expectEqualStrings("old", emulator.document.items[0].items);
    try emulator.expectScreen(&.{ "", "" });

    try emulator.feed("\x1b[Hone\r\ntwo");
    try std.testing.expectEqualStrings("old", emulator.document.items[0].items);
    try emulator.expectScreen(&.{ "one", "two" });

    try emulator.feed("\x1b[3J");
    try std.testing.expectEqual(@as(usize, 0), emulator.screen_top);
    try std.testing.expectEqual(@as(usize, 1), emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), emulator.document.items.len);
    try emulator.expectScreen(&.{ "one", "two" });
}

// An OSC string shows nothing and moves nothing. It ends at ST or at BEL, and
// any other escape aborts it. The escape that aborts a string must stay for the
// parser, or an unterminated string swallows the whole repaint behind it.
test "an OSC string ends at ST, at BEL, or on the escape that aborts it" {
    const gpa = std.testing.allocator;
    var emulator = try Emulator.init(gpa, 20);
    defer emulator.deinit();
    emulator.rows = 1;

    try emulator.feed("a\x1b]8;;https://x.y\x1b\\b\x1b]0;title\x07c");
    try emulator.expectVisible(&.{"abc"});

    // The erase behind the aborted string still runs.
    try emulator.feed("\x1b]8;;https://x.y\x1b[2Jd");
    try emulator.expectVisible(&.{"d"});

    // A string with no terminator ends at the last byte and shows nothing.
    try emulator.feed("\x1b]8;;unterminated");
    try emulator.expectVisible(&.{"d"});
}
