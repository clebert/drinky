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
//! Every repaint is wrapped in a synchronized-output burst so it lands without
//! flicker. A focused text component embeds a `cursor` marker at its caret; the
//! renderer strips it before it reaches the terminal and moves the real cursor
//! there after painting, so typing stays put across repaints.

const std = @import("std");

const cursor = @import("cursor.zig");
const escape = @import("escape.zig");

const Surface = @This();

gpa: std.mem.Allocator,
writer: *std.Io.Writer,
/// The frame currently on screen, with the caret marker already stripped.
previous: std.ArrayList([]u8),
columns: usize,
rows: usize,
/// Buffer index of the first on-screen line: everything above it has scrolled
/// into native scrollback and can no longer be addressed by the cursor.
viewport_top: usize,
/// Buffer index of the row the hardware cursor physically sits on.
cursor_row: usize,
/// Tracks the terminal's cursor visibility so show/hide is emitted only on a
/// change. The owning `Tty` hides the cursor at startup, matching the initial
/// value here.
cursor_visible: bool,

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) Surface {
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

pub fn deinit(self: *Surface) void {
    for (self.previous.items) |line| self.gpa.free(line);
    self.previous.deinit(self.gpa);
}

/// Repaint the frame to show exactly `lines`. One line may carry the caret
/// marker; the real cursor is moved there and shown, otherwise it is hidden.
pub fn render(self: *Surface, lines: []const []const u8, size: struct { columns: usize, rows: usize }) !void {
    const writer = self.writer;
    const width_changed = self.columns != 0 and self.columns != size.columns;
    const height_changed = self.rows != 0 and self.rows != size.rows;
    self.columns = size.columns;
    self.rows = size.rows;

    var marker_row: ?usize = null;
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
            marker_row = index;
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
        try self.fullPaint(self.previous.items.len != 0, new.items, marker_row, marker_column);
        self.store(new);
        return;
    }

    const first = firstDiff(self.previous.items, new.items) orelse {
        // The lines are unchanged; only the caret or its visibility may differ.
        try writer.writeAll(escape.sync_set);
        try self.restoreCursor(self.cursor_row, marker_row, marker_column);
        try writer.writeAll(escape.sync_reset);
        try writer.flush();
        for (new.items) |line| self.gpa.free(line);
        new.deinit(self.gpa);
        return;
    };

    const anchor = @min(@min(first, new_len - 1), self.previous.items.len - 1);
    if (anchor < self.viewport_top) {
        try self.fullPaint(true, new.items, marker_row, marker_column);
        self.store(new);
        return;
    }

    try writer.writeAll(escape.sync_set);
    if (self.cursor_row >= anchor) {
        try escape.cursorUp(writer, self.cursor_row - anchor);
    } else {
        try escape.cursorDown(writer, anchor - self.cursor_row);
    }
    try writer.writeAll("\r");
    try writer.writeAll(escape.screen_clear_below);
    for (new.items[anchor..], anchor..) |line, index| {
        if (index > anchor) try writer.writeAll("\r\n");
        try writer.writeAll(line);
    }
    self.viewport_top = new_len -| self.rows;
    try self.restoreCursor(new_len - 1, marker_row, marker_column);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
    self.store(new);
}

/// Print the whole buffer: on the first frame without clearing (content flows
/// from the current cursor), otherwise clearing the screen and scrollback first
/// so a change above the viewport or a resize reprints from a clean slate.
fn fullPaint(
    self: *Surface,
    clear: bool,
    lines: []const []const u8,
    marker_row: ?usize,
    marker_column: usize,
) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    if (clear) try writer.writeAll(escape.screen_reset);
    for (lines, 0..) |line, index| {
        if (index > 0) try writer.writeAll("\r\n");
        try writer.writeAll(line);
    }
    self.viewport_top = lines.len -| self.rows;
    try self.restoreCursor(lines.len - 1, marker_row, marker_column);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

/// Move the hardware cursor from `physical_row` to the caret and show it, or
/// hide it when there is no on-screen caret. `physical_row` is where painting
/// left the cursor; both rows are buffer indices in the frame just drawn.
fn restoreCursor(self: *Surface, physical_row: usize, marker_row: ?usize, marker_column: usize) !void {
    const writer = self.writer;
    if (marker_row) |row| {
        if (row >= self.viewport_top) {
            if (physical_row >= row) {
                try escape.cursorUp(writer, physical_row - row);
            } else {
                try escape.cursorDown(writer, row - physical_row);
            }
            try writer.writeAll("\r");
            try escape.cursorForward(writer, marker_column);
            if (!self.cursor_visible) {
                try writer.writeAll(escape.cursor_show);
                self.cursor_visible = true;
            }
            self.cursor_row = row;
            return;
        }
    }
    if (self.cursor_visible) {
        try writer.writeAll(escape.cursor_hide);
        self.cursor_visible = false;
    }
    self.cursor_row = physical_row;
}

fn store(self: *Surface, new: std.ArrayList([]u8)) void {
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
fn firstDiff(old: []const []u8, new: []const []u8) ?usize {
    const count = @max(old.len, new.len);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (index >= old.len or index >= new.len or !std.mem.eql(u8, old[index], new[index])) return index;
    }
    return null;
}

const Emulator = @import("Emulator.zig");

const Harness = struct {
    gpa: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    surface: Surface,
    emulator: Emulator,
    consumed: usize,

    fn init(gpa: std.mem.Allocator, columns: usize, rows: usize) !*Harness {
        const self = try gpa.create(Harness);
        self.gpa = gpa;
        self.out = .init(gpa);
        self.surface = Surface.init(gpa, &self.out.writer);
        self.emulator = try Emulator.init(gpa, columns, rows);
        self.consumed = 0;
        return self;
    }

    fn deinit(self: *Harness) void {
        self.surface.deinit();
        self.emulator.deinit();
        self.out.deinit();
        self.gpa.destroy(self);
    }

    fn render(self: *Harness, lines: []const []const u8) !void {
        try self.surface.render(lines, .{ .columns = self.emulator.columns, .rows = self.emulator.rows });
        const written = self.out.written();
        try self.emulator.write(written[self.consumed..]);
        self.consumed = written.len;
    }

    fn resize(self: *Harness, columns: usize, rows: usize) !void {
        self.emulator.deinit();
        self.emulator = try Emulator.init(self.gpa, columns, rows);
        self.consumed = self.out.written().len;
    }

    fn expectRow(self: *Harness, row: usize, expected: []const u8) !void {
        var buffer: [256]u8 = undefined;
        try std.testing.expectEqualStrings(expected, self.emulator.rowText(row, &buffer));
    }

    fn expectScrollback(self: *Harness, index: usize, expected: []const u8) !void {
        var buffer: [256]u8 = undefined;
        try std.testing.expectEqualStrings(expected, self.emulator.scrollbackText(index, &buffer));
    }
};

test "first frame prints every line and leaves the cursor on the last" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{ "one", "two", "three" });

    try harness.expectRow(0, "one");
    try harness.expectRow(1, "two");
    try harness.expectRow(2, "three");
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), harness.emulator.scrollback.items.len);
}

test "appending a line touches only the tail" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{ "one", "two" });
    try harness.render(&.{ "one", "two", "three" });

    try harness.expectRow(0, "one");
    try harness.expectRow(1, "two");
    try harness.expectRow(2, "three");
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.cursor_row);
}

test "changing a middle line repaints from there down" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{ "alpha", "beta", "gamma" });
    try harness.render(&.{ "alpha", "BETA", "gamma" });

    try harness.expectRow(0, "alpha");
    try harness.expectRow(1, "BETA");
    try harness.expectRow(2, "gamma");
}

test "shrinking the frame clears the trailing rows" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{ "one", "two", "three", "four" });
    try harness.render(&.{ "one", "two" });

    try harness.expectRow(0, "one");
    try harness.expectRow(1, "two");
    try harness.expectRow(2, "");
    try harness.expectRow(3, "");
    try std.testing.expectEqual(@as(usize, 1), harness.emulator.cursor_row);
}

test "growing past the screen scrolls the top into scrollback" {
    var harness = try Harness.init(std.testing.allocator, 20, 3);
    defer harness.deinit();
    try harness.render(&.{ "one", "two", "three" });
    try harness.render(&.{ "one", "two", "three", "four", "five" });

    try harness.expectScrollback(0, "one");
    try harness.expectScrollback(1, "two");
    try harness.expectRow(0, "three");
    try harness.expectRow(1, "four");
    try harness.expectRow(2, "five");
}

test "incremental appends scroll cleanly line by line" {
    var harness = try Harness.init(std.testing.allocator, 20, 3);
    defer harness.deinit();
    try harness.render(&.{"l0"});
    try harness.render(&.{ "l0", "l1" });
    try harness.render(&.{ "l0", "l1", "l2" });
    try harness.render(&.{ "l0", "l1", "l2", "l3" });
    try harness.render(&.{ "l0", "l1", "l2", "l3", "l4" });

    try harness.expectScrollback(0, "l0");
    try harness.expectScrollback(1, "l1");
    try harness.expectRow(0, "l2");
    try harness.expectRow(1, "l3");
    try harness.expectRow(2, "l4");
}

test "a change above the viewport reprints the whole buffer" {
    var harness = try Harness.init(std.testing.allocator, 20, 3);
    defer harness.deinit();
    try harness.render(&.{ "one", "two", "three", "four", "five" });
    // "one" has scrolled off the top; editing it forces a full repaint that
    // rebuilds the scrollback so scrolling up stays consistent.
    try harness.render(&.{ "ONE", "two", "three", "four", "five" });

    try harness.expectScrollback(0, "ONE");
    try harness.expectScrollback(1, "two");
    try harness.expectRow(0, "three");
    try harness.expectRow(1, "four");
    try harness.expectRow(2, "five");
}

test "the caret marker positions and shows the hardware cursor" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{ "prompt", "> hi" ++ cursor.marker });

    try harness.expectRow(1, "> hi");
    try std.testing.expect(harness.emulator.cursor_visible);
    try std.testing.expectEqual(@as(usize, 1), harness.emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), harness.emulator.cursor_column);
}

test "a caret inside the line lands between the characters" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{"> ab" ++ cursor.marker ++ "cd"});

    try harness.expectRow(0, "> abcd");
    try std.testing.expectEqual(@as(usize, 0), harness.emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), harness.emulator.cursor_column);
}

test "moving the caret on an unchanged line repositions the cursor" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{"> abc" ++ cursor.marker});
    try std.testing.expectEqual(@as(usize, 5), harness.emulator.cursor_column);
    // Same text, caret moved left two: the content is untouched, only the cursor.
    try harness.render(&.{"> a" ++ cursor.marker ++ "bc"});

    try harness.expectRow(0, "> abc");
    try std.testing.expectEqual(@as(usize, 0), harness.emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), harness.emulator.cursor_column);
}

test "a change above the caret repaints down through it" {
    var harness = try Harness.init(std.testing.allocator, 20, 6);
    defer harness.deinit();
    try harness.render(&.{ "tool", "> hi" ++ cursor.marker });
    try harness.render(&.{ "TOOL", "> hi" ++ cursor.marker });

    try harness.expectRow(0, "TOOL");
    try harness.expectRow(1, "> hi");
    try std.testing.expect(harness.emulator.cursor_visible);
    try std.testing.expectEqual(@as(usize, 1), harness.emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), harness.emulator.cursor_column);
}

test "dropping the marker hides the cursor" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{"> hi" ++ cursor.marker});
    try std.testing.expect(harness.emulator.cursor_visible);
    try harness.render(&.{"> hi"});
    try std.testing.expect(!harness.emulator.cursor_visible);
}

test "a resize reflows via a full repaint" {
    var harness = try Harness.init(std.testing.allocator, 20, 5);
    defer harness.deinit();
    try harness.render(&.{ "one", "two", "three" });
    try harness.resize(10, 5);
    try harness.render(&.{ "one", "two", "three", "four" });

    try harness.expectRow(0, "one");
    try harness.expectRow(3, "four");
    try std.testing.expectEqual(@as(usize, 3), harness.emulator.cursor_row);
}

test "a line wider than the terminal autowraps and desyncs cursor tracking" {
    var harness = try Harness.init(std.testing.allocator, 10, 6);
    defer harness.deinit();
    // The middle line is 12 columns wide in a 10-column terminal, so the
    // terminal autowraps it onto two physical rows. The Surface counts one
    // physical row per frame line, so from here its cursor_row trails the
    // terminal by one row.
    try harness.render(&.{ "top", "AAAAAAAAAAAA", "bot" });
    try harness.expectRow(0, "top");
    try harness.expectRow(1, "AAAAAAAAAA");
    try harness.expectRow(2, "AA");
    try harness.expectRow(3, "bot");

    // Editing only the first line should rewrite row 0 in place. Because
    // cursor_row is off by one, the repaint lands a row too low: "top" is left
    // stale and "TOP" prints below it, shifting the whole frame down. This pins
    // the desync until the Surface tracks physical rows; the app keeps it out of
    // reach by wrapping every line to the terminal width before rendering.
    try harness.render(&.{ "TOP", "AAAAAAAAAAAA", "bot" });
    try harness.expectRow(0, "top");
    try harness.expectRow(1, "TOP");
    try harness.expectRow(2, "AAAAAAAAAA");
    try harness.expectRow(3, "AA");
    try harness.expectRow(4, "bot");
}
