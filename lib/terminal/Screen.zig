//! Differential renderer for an inline (non-alternate-screen) frame.
//!
//! The whole frame — transcript and live tail alike — is one flat list of lines
//! held in `previous`. Each `render` builds the new frame, diffs it against the
//! previous one, and repaints the smallest region it can:
//!
//! - **First frame** — print every line; content flows from the cursor and
//!   scrolls into native scrollback as it grows past the screen.
//! - **On-screen change** — move to the first changed line, clear to the end of
//!   the screen, and reprint from there down. Appends are just this with the
//!   first changed line at the old end, so streaming scrolls naturally.
//! - **Change above the viewport, or a resize** — the cursor cannot reach a line
//!   that scrolled off the top, so clear the screen and scrollback and reprint
//!   the whole buffer from memory. Scrolling back up then stays consistent.
//!
//! A frame line whose display width exceeds `columns` auto-wraps onto several
//! physical terminal rows, so every cursor move counts *physical rows* — each
//! line spans as many rows as `width.rows` reports — never frame-line indices.
//! Get that wrong and a wide line desyncs the cursor for the rest of the frame.
//!
//! Every repaint is wrapped in a synchronized-output burst so it lands without
//! flicker. A focused text component embeds a `cursor` marker at its caret; the
//! renderer strips it before it reaches the terminal and moves the real cursor
//! there after painting, so typing stays put across repaints.

const std = @import("std");

const cursor = @import("cursor.zig");
const escape = @import("escape.zig");
const grapheme = @import("grapheme.zig");
const width = @import("width.zig");

const Screen = @This();

gpa: std.mem.Allocator,
writer: *std.Io.Writer,
/// The frame currently on screen, with the caret marker already stripped.
previous: std.ArrayList([]u8),
columns: usize,
rows: usize,
/// Buffer index of the first on-screen line: everything above it has scrolled
/// into native scrollback and can no longer be addressed by the cursor.
viewport_top: usize,
/// Physical terminal row the hardware cursor sits on, measured from the top of
/// the frame (line 0 starts at row 0). A line wider than `columns` spans several
/// physical rows, so this is a row count, not a frame-line index.
cursor_row: usize,
/// Tracks the terminal's cursor visibility so show/hide is emitted only on a
/// change. The owning `Tty` hides the cursor at startup, matching the initial
/// value here.
cursor_visible: bool,

pub const Size = struct { columns: usize, rows: usize };

/// How `paint` positions the cursor before reprinting from `anchor`.
const Mode = enum {
    /// First frame: print from the current cursor, no clear.
    fresh,
    /// Wipe screen and scrollback, then reprint the whole buffer from row zero.
    reset,
    /// Move up to `anchor`, clear below, and reprint the changed suffix.
    incremental,
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) Screen {
    return .{
        .gpa = gpa,
        .writer = writer,
        .previous = .empty,
        .columns = 0,
        .rows = 0,
        .viewport_top = 0,
        .cursor_row = 0,
        .cursor_visible = false,
    };
}

pub fn deinit(self: *Screen) void {
    for (self.previous.items) |line| self.gpa.free(line);
    self.previous.deinit(self.gpa);
}

/// Repaint the frame to show exactly `lines`. One line may carry the caret
/// marker; the real cursor is moved there and shown, otherwise it is hidden.
pub fn render(self: *Screen, lines: []const []const u8, size: Size) !void {
    const writer = self.writer;
    const width_changed = self.columns != 0 and self.columns != size.columns;
    const height_changed = self.rows != 0 and self.rows != size.rows;
    self.columns = size.columns;
    self.rows = size.rows;

    var maybe_marker_row: ?usize = null;
    var marker_column: usize = 0;
    var new: std.ArrayList([]u8) = .empty;
    errdefer {
        for (new.items) |line| self.gpa.free(line);
        new.deinit(self.gpa);
    }
    // A focused text component embeds at most one caret marker per frame; if
    // more than one appears the last one wins.
    for (lines, 0..) |line, index| {
        if (cursor.column(line)) |column| {
            maybe_marker_row = index;
            marker_column = column;
            try new.append(self.gpa, try stripMarker(self.gpa, line));
        } else {
            try new.append(self.gpa, try self.gpa.dupe(u8, line));
        }
    }
    const new_len = new.items.len;

    if (new_len == 0) {
        // Nothing to show: wipe the region and hide the cursor. The app always
        // emits at least the status line, so this only guards misuse.
        try writer.writeAll(escape.sync_set);
        if (self.previous.items.len != 0) try writer.writeAll(escape.screen_reset);
        if (self.cursor_visible) {
            try writer.writeAll(escape.cursor_hide);
            self.cursor_visible = false;
        }
        try writer.writeAll(escape.sync_reset);
        try writer.flush();
        self.viewport_top = 0;
        self.cursor_row = 0;
        self.store(new);
        return;
    }

    if (self.previous.items.len == 0 or width_changed or height_changed) {
        const mode: Mode = if (self.previous.items.len == 0) .fresh else .reset;
        try self.paint(mode, 0, new.items, maybe_marker_row, marker_column);
        self.store(new);
        return;
    }

    const first = firstDiff(self.previous.items, new.items) orelse {
        // The lines are unchanged; only the caret or its visibility may differ.
        try writer.writeAll(escape.sync_set);
        try self.restoreCursor(self.cursor_row, maybe_marker_row, marker_column, new.items);
        try writer.writeAll(escape.sync_reset);
        try writer.flush();
        for (new.items) |line| self.gpa.free(line);
        new.deinit(self.gpa);
        return;
    };

    const anchor = @min(@min(first, new_len - 1), self.previous.items.len - 1);
    const mode: Mode = if (anchor < self.viewport_top) .reset else .incremental;
    try self.paint(mode, if (mode == .reset) 0 else anchor, new.items, maybe_marker_row, marker_column);
    self.store(new);
}

/// Reprint `lines` from `anchor` down, positioning the cursor per `mode`. The
/// shared tail — set `viewport_top`, restore the caret, close the burst — runs
/// for every mode, and all vertical motion counts physical rows so a wrapped
/// line stays in sync.
fn paint(
    self: *Screen,
    mode: Mode,
    anchor: usize,
    lines: []const []const u8,
    maybe_marker_row: ?usize,
    marker_column: usize,
) !void {
    const writer = self.writer;
    const columns = @max(self.columns, 1);
    try writer.writeAll(escape.sync_set);
    switch (mode) {
        .fresh => {},
        .reset => try writer.writeAll(escape.screen_reset),
        .incremental => {
            const target = rowsOf(lines[0..anchor], columns);
            if (self.cursor_row >= target) {
                try escape.cursorUp(writer, self.cursor_row - target);
            } else {
                try escape.cursorDown(writer, target - self.cursor_row);
            }
            try writer.writeAll("\r");
            try writer.writeAll(escape.screen_clear_below);
        },
    }
    for (lines[anchor..], anchor..) |line, index| {
        if (index > anchor) try writer.writeAll("\r\n");
        try writer.writeAll(line);
    }
    self.viewport_top = viewportTop(lines, columns, self.rows);
    try self.restoreCursor(rowsOf(lines, columns) - 1, maybe_marker_row, marker_column, lines);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

/// Move the hardware cursor from `physical_row` to the caret and show it, or
/// hide it when there is no on-screen caret. `physical_row` is the physical row
/// painting left the cursor on; the caret's own physical row is derived from the
/// lines above it plus how its column wraps within its line.
fn restoreCursor(
    self: *Screen,
    physical_row: usize,
    maybe_marker_row: ?usize,
    marker_column: usize,
    lines: []const []const u8,
) !void {
    const writer = self.writer;
    if (maybe_marker_row) |marker_row| {
        if (marker_row >= self.viewport_top) {
            const columns = @max(self.columns, 1);
            const position = width.caret(lines[marker_row], marker_column, columns);
            const caret_row = rowsOf(lines[0..marker_row], columns) + position.rows_before;
            if (physical_row >= caret_row) {
                try escape.cursorUp(writer, physical_row - caret_row);
            } else {
                try escape.cursorDown(writer, caret_row - physical_row);
            }
            try writer.writeAll("\r");
            try escape.cursorForward(writer, position.column);
            if (!self.cursor_visible) {
                try writer.writeAll(escape.cursor_show);
                self.cursor_visible = true;
            }
            self.cursor_row = caret_row;
            return;
        }
    }
    if (self.cursor_visible) {
        try writer.writeAll(escape.cursor_hide);
        self.cursor_visible = false;
    }
    self.cursor_row = physical_row;
}

fn store(self: *Screen, new: std.ArrayList([]u8)) void {
    for (self.previous.items) |line| self.gpa.free(line);
    self.previous.deinit(self.gpa);
    self.previous = new;
}

fn stripMarker(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, line, cursor.marker).?;
    const stripped = try gpa.alloc(u8, line.len - cursor.marker.len);
    @memcpy(stripped[0..at], line[0..at]);
    @memcpy(stripped[at..], line[at + cursor.marker.len ..]);
    return stripped;
}

/// The first index at which the frames differ, treating a missing line (append
/// or deletion) as a difference. Null when both frames are identical.
fn firstDiff(old: []const []const u8, new: []const []const u8) ?usize {
    const count = @max(old.len, new.len);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (index >= old.len or index >= new.len or !std.mem.eql(u8, old[index], new[index])) return index;
    }
    return null;
}

/// Total physical rows `lines` occupy at `columns` — the sum of each line's
/// wrapped span.
fn rowsOf(lines: []const []const u8, columns: usize) usize {
    var total: usize = 0;
    for (lines) |line| total += width.rows(line, columns);
    return total;
}

/// Frame-line index of the topmost line still on screen: the highest line whose
/// physical rows, together with everything below it, fit within `rows`. The last
/// line always stays addressable, even if it alone overflows the screen.
fn viewportTop(lines: []const []const u8, columns: usize, rows: usize) usize {
    if (lines.len == 0) return 0;
    var top = lines.len - 1;
    var used = width.rows(lines[top], columns);
    while (top > 0) {
        const above = width.rows(lines[top - 1], columns);
        if (used + above > rows) break;
        used += above;
        top -= 1;
    }
    return top;
}

test rowsOf {
    try std.testing.expectEqual(@as(usize, 0), rowsOf(&.{}, 3));
    try std.testing.expectEqual(@as(usize, 2), rowsOf(&.{ "a", "b" }, 3));
    // "abcd" wraps to two rows at width three; "ef" is one.
    try std.testing.expectEqual(@as(usize, 3), rowsOf(&.{ "abcd", "ef" }, 3));
    // A wide line spans one physical row per glyph when they cannot straddle.
    try std.testing.expectEqual(@as(usize, 4), rowsOf(&.{ "你好世", "x" }, 3));
}

test viewportTop {
    try std.testing.expectEqual(@as(usize, 0), viewportTop(&.{ "a", "b", "c" }, 80, 24));
    // Five one-row lines in three rows: only the bottom three are addressable.
    try std.testing.expectEqual(@as(usize, 2), viewportTop(&.{ "a", "b", "c", "d", "e" }, 80, 3));
    // The wide line's three rows plus the last line overflow three rows, so the
    // wide line's top scrolls off and the first addressable line is index one.
    try std.testing.expectEqual(@as(usize, 1), viewportTop(&.{ "你好世", "x" }, 3, 3));
}

// A model terminal that applies exactly the escapes `Screen` emits — cursor
// motion, clears, and text with real auto-wrap — to reconstruct what the screen
// shows. Cursor position is physical, so a wide line desyncing `cursor_row`
// surfaces as a corrupted document or a misplaced caret.
const Emulator = struct {
    gpa: std.mem.Allocator,
    columns: usize,
    document: std.ArrayList(std.ArrayList(u8)),
    cursor_row: usize,
    cursor_column: usize,
    cursor_visible: bool,

    fn init(gpa: std.mem.Allocator, columns: usize) !Emulator {
        var document: std.ArrayList(std.ArrayList(u8)) = .empty;
        try document.append(gpa, .empty);
        return .{
            .gpa = gpa,
            .columns = columns,
            .document = document,
            .cursor_row = 0,
            .cursor_column = 0,
            .cursor_visible = false,
        };
    }

    fn deinit(self: *Emulator) void {
        for (self.document.items) |*row| row.deinit(self.gpa);
        self.document.deinit(self.gpa);
    }

    fn feed(self: *Emulator, bytes: []const u8) !void {
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
                self.cursor_row += 1;
                try self.ensureRow(self.cursor_row);
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
            'A' => self.cursor_row -= @min(csiValue(params, 1), self.cursor_row),
            'B' => {
                self.cursor_row += csiValue(params, 1);
                try self.ensureRow(self.cursor_row);
            },
            'C' => self.cursor_column += csiValue(params, 1),
            'H' => {
                self.cursor_row = 0;
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
            self.cursor_row += 1;
            self.cursor_column = 0;
        }
        try self.ensureRow(self.cursor_row);
        try self.document.items[self.cursor_row].appendSlice(self.gpa, bytes);
        self.cursor_column += columns;
    }

    fn csiValue(params: []const u8, default: usize) usize {
        return std.fmt.parseInt(usize, params, 10) catch default;
    }

    fn expectDocument(self: *Emulator, lines: []const []const u8) !void {
        var pieces: std.ArrayList([]const u8) = .empty;
        defer pieces.deinit(self.gpa);
        for (lines) |line| try width.wrap(line, self.columns, &pieces, self.gpa);
        try std.testing.expectEqual(pieces.items.len, self.document.items.len);
        for (pieces.items, self.document.items) |piece, row| {
            try std.testing.expectEqualStrings(piece, row.items);
        }
    }

    fn expectCaret(self: *Emulator, lines: []const []const u8, marker_row: usize, marker_column: usize) !void {
        const position = width.caret(lines[marker_row], marker_column, self.columns);
        try std.testing.expect(self.cursor_visible);
        try std.testing.expectEqual(rowsOf(lines[0..marker_row], self.columns) + position.rows_before, self.cursor_row);
        try std.testing.expectEqual(position.column, self.cursor_column);
    }
};

// Drives one `render` and replays only the bytes it produced into the emulator.
const Harness = struct {
    out: std.Io.Writer.Allocating,
    screen: Screen,
    emulator: Emulator,
    consumed: usize,

    fn deinit(self: *Harness) void {
        self.screen.deinit();
        self.emulator.deinit();
        self.out.deinit();
    }

    fn render(self: *Harness, lines: []const []const u8, size: Size) !void {
        try self.screen.render(lines, size);
        const bytes = self.out.written();
        try self.emulator.feed(bytes[self.consumed..]);
        self.consumed = bytes.len;
    }
};

fn harness(gpa: std.mem.Allocator, columns: usize) !*Harness {
    const self = try gpa.create(Harness);
    self.* = .{
        .out = .init(gpa),
        .screen = undefined,
        .emulator = try Emulator.init(gpa, columns),
        .consumed = 0,
    };
    self.screen = Screen.init(gpa, &self.out.writer);
    return self;
}

test "paints a plain frame line for line" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 80);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const frame = [_][]const u8{ "hello", "world" };
    try h.render(&frame, .{ .columns = 80, .rows = 24 });
    try h.emulator.expectDocument(&frame);
    try std.testing.expect(!h.emulator.cursor_visible);
}

test "wraps a line wider than the screen onto several physical rows" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 3);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const frame = [_][]const u8{"你好世"};
    try h.render(&frame, .{ .columns = 3, .rows = 24 });
    // Three two-column glyphs each land on their own physical row.
    try h.emulator.expectDocument(&frame);
    try std.testing.expectEqual(@as(usize, 3), h.emulator.document.items.len);
}

test "an edit below a wrapped line moves the cursor by physical rows" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 3);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    // The middle line wraps to three rows; changing the last line forces an
    // incremental repaint whose cursor move must count those rows, not one.
    const first = [_][]const u8{ "abc", "你好世", "zzz" };
    try h.render(&first, .{ .columns = 3, .rows = 24 });
    try h.emulator.expectDocument(&first);

    const second = [_][]const u8{ "abc", "好世你", "zzz" };
    try h.render(&second, .{ .columns = 3, .rows = 24 });
    try h.emulator.expectDocument(&second);
}

test "restores the caret onto its physical row past a wrapped line" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 3);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const frame = [_][]const u8{ "你好世", "ab" ++ cursor.marker };
    const shown = [_][]const u8{ "你好世", "ab" };
    try h.render(&frame, .{ .columns = 3, .rows = 24 });
    try h.emulator.expectDocument(&shown);
    // The caret sits after "ab" on row three, below the wide line's three rows.
    try h.emulator.expectCaret(&shown, 1, 2);
}
