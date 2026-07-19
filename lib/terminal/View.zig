//! Reconciling renderer for an inline (non-alternate-screen) frame.
//!
//! The caller composes complete, pre-fitted physical rows — the last `pages`
//! pages of the newest content, never the whole model — through the `Sink` from
//! `beginFrame`; `render` diffs against the frame on screen and repaints the
//! smallest correct region. The two frames ping-pong with retained capacity, so
//! after warmup no frame allocates.
//!
//! Reconciliation is by row **anchor** (stable cross-frame identity), not screen
//! position, so a sliding window does not force a reset on every append. A
//! forward slide repaints incrementally, but no lower than the previous frame's
//! last row: the append scrolls the terminal by `\r\n` rather than moving below
//! the bottom margin (where the cursor would clamp, not scroll), and the stored
//! cursor row is rebased by Δ, how far the window slid. A backward slide is
//! never incremental above the viewport — a terminal cannot un-scroll its
//! scrollback — so it resets, or reprints from row `0` when the whole window
//! shows. Every line is exactly one physical row, so all cursor motion is a
//! plain row count; each repaint is one synchronized-output burst.

const std = @import("std");

const Emulator = @import("Emulator.zig");
const escape = @import("escape.zig");
const width = @import("width.zig");

const View = @This();

gpa: std.mem.Allocator,
writer: *std.Io.Writer,
frames: [2]Frame,
/// Index of the frame currently on screen; the other frame is composed into.
front: u1,
columns: usize,
rows: usize,
pages: usize,
/// Window-relative index of the topmost row still on screen; everything above
/// it has scrolled into native scrollback and can no longer be addressed.
viewport_top: usize,
/// Physical row the hardware cursor sits on, window-relative to the frame last
/// painted.
cursor_row: usize,
/// Terminal cursor visibility, so show/hide is emitted only on a change. The
/// owning `Tty` hides the cursor at startup, matching the initial value here.
cursor_visible: bool,
/// The sink handed out by `beginFrame`, composing into the back frame until the
/// paired `render`.
sink: Sink,
/// Set by `beginFrame` when the columns, rows, or page count changed, forcing
/// `render` to repaint the whole window.
structural_change: bool,
/// Set by `invalidate`: the screen no longer matches the last painted frame.
force_reset: bool,

pub const Size = struct { columns: usize, rows: usize };

/// Stable identity of one physical row's content, so the diff survives a
/// sliding window. Opaque to the view (compared only for equality); ids come
/// from disjoint namespaces so they never alias as the model grows.
pub const Anchor = struct {
    id: usize,
    line: usize,

    fn eql(a: Anchor, b: Anchor) bool {
        return a.id == b.id and a.line == b.line;
    }
};

/// One complete physical line, fitted to at most the terminal width. An offset
/// into the frame's `blob`, not a slice: `blob` grows while composing and may
/// reallocate, which would dangle a slice; an offset survives.
const Row = struct { offset: usize, len: usize, anchor: Anchor };

/// Hardware cursor position after a repaint: a display `column` on window-relative
/// `row` (a producer reports it relative to its own rows; the assembler rebases).
/// Absent when no input is focused.
pub const Caret = struct { row: usize, column: usize };

/// Composes rows directly into the back frame's `blob`. The caller opens a row
/// with `begin`, writes inert display content through `text` and application
/// styling through `sgr`, optionally marks the caret with `setCaret`, and closes
/// it with `end`. The underlying writer is never exposed, so runtime content
/// cannot enter the trusted terminal-control channel.
pub const Sink = struct {
    frame: *Frame,
    columns: usize,
    offset: usize,
    columns_written: usize,
    has_text: bool,

    /// Open a row and capture the current `blob` end.
    pub fn begin(self: *Sink) void {
        self.offset = self.frame.blob.writer.end;
        self.columns_written = 0;
        self.has_text = false;
    }

    /// Append inert display text. Terminal controls and malformed UTF-8 are
    /// canonicalized by the same scanner used for layout and width accounting.
    /// A zero-width break between calls prevents separately measured fragments
    /// from fusing into a different terminal grapheme.
    pub fn text(self: *Sink, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.has_text) try self.frame.blob.writer.writeAll("\u{200B}");
        const available = self.columns -| self.columns_written;
        self.columns_written += try width.writeFitted(&self.frame.blob.writer, bytes, available);
        self.has_text = true;
    }

    /// Append up to `count` ordinary spaces without exposing the row writer.
    pub fn spaces(self: *Sink, count: usize) !void {
        return self.repeat(" ", count);
    }

    /// Append up to `count` copies of a compile-time single-column `cell` as one
    /// contiguous run, so a filled row carries no inter-cell boundaries. `cell`
    /// must be a plain decorative glyph (such as a rule dash) whose copies do not
    /// combine into a wider cluster, so `count` copies stay `count` columns.
    pub fn repeat(self: *Sink, comptime cell: []const u8, count: usize) !void {
        comptime std.debug.assert(width.ofText(cell) == 1);
        const shown = @min(count, self.columns -| self.columns_written);
        if (shown == 0) return;
        if (self.has_text) try self.frame.blob.writer.writeAll("\u{200B}");
        try self.frame.blob.writer.splatBytesAll(cell, shown);
        self.columns_written += shown;
        self.has_text = true;
    }

    /// Append a compile-time-known Select Graphic Rendition sequence. Only SGR
    /// syntax is accepted; cursor, screen, and string controls remain private to
    /// the renderer.
    pub fn sgr(self: *Sink, comptime sequence: []const u8) !void {
        comptime if (!validSgr(sequence))
            @compileError("trusted style must be one complete SGR sequence");
        try self.frame.blob.writer.writeAll(sequence);
    }

    /// Close the row opened by `begin`, recording it under `anchor`.
    pub fn end(self: *Sink, anchor: Anchor) void {
        std.debug.assert(self.columns_written <= self.columns);
        const len = self.frame.blob.writer.end - self.offset;
        self.frame.rows.appendAssumeCapacity(
            .{ .offset = self.offset, .len = len, .anchor = anchor },
        );
    }

    /// Place the caret on the row currently being composed — the one opened by
    /// the most recent `begin` — at display `column`.
    pub fn setCaret(self: *Sink, column: usize) void {
        self.frame.caret = .{ .row = self.frame.rows.items.len, .column = column };
    }
};

/// A frame's two reused buffers plus the caret it resolved. `blob` holds all row
/// bytes concatenated in screen order and grows to a high-water mark; `rows`
/// indexes them in screen order with fixed capacity.
const Frame = struct {
    blob: std.Io.Writer.Allocating,
    rows: std.ArrayList(Row),
    caret: ?Caret,

    fn init(gpa: std.mem.Allocator) Frame {
        return .{ .blob = .init(gpa), .rows = .empty, .caret = null };
    }

    fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        self.blob.deinit();
        self.rows.deinit(gpa);
    }

    fn reset(self: *Frame) void {
        self.blob.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.caret = null;
    }

    fn bytes(self: *const Frame, row: Row) []const u8 {
        return self.blob.writer.buffered()[row.offset..][0..row.len];
    }
};

/// How `paint` positions the cursor before reprinting from its anchor row.
const Mode = enum {
    /// First frame: print from the current cursor, no clear.
    fresh,
    /// Wipe screen and scrollback, then reprint the whole window from row zero.
    reset,
    /// Move to the anchor row, clear below, and reprint the changed suffix.
    incremental,
};

const Alignment = struct { back_index: usize, prev_index: usize };

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) View {
    return .{
        .gpa = gpa,
        .writer = writer,
        .frames = .{ Frame.init(gpa), Frame.init(gpa) },
        .front = 0,
        .columns = 0,
        .rows = 0,
        .pages = 0,
        .viewport_top = 0,
        .cursor_row = 0,
        .cursor_visible = false,
        .sink = undefined,
        .structural_change = false,
        .force_reset = false,
    };
}

pub fn deinit(self: *View) void {
    for (&self.frames) |*frame| frame.deinit(self.gpa);
}

/// Force the next `render` to clear the screen and scrollback and reprint: used
/// after external output (an OAuth login flow) has scrolled the terminal out from
/// under the diff. The caller has re-hidden the cursor, so tracking resets to match.
pub fn invalidate(self: *View) void {
    self.force_reset = true;
    self.cursor_visible = false;
}

/// Begin composing the next frame at `size` and `pages`: reset the back frame
/// and hand back the `Sink` that composes rows into it. Pair every `beginFrame`
/// with a `render`, which diffs the composed frame against the one on screen.
pub fn beginFrame(self: *View, size: Size, pages: usize) !*Sink {
    const width_changed = self.columns != 0 and self.columns != size.columns;
    const height_changed = self.rows != 0 and self.rows != size.rows;
    const pages_changed = self.pages != 0 and self.pages != pages;
    self.structural_change = width_changed or height_changed or pages_changed;
    self.columns = size.columns;
    self.rows = size.rows;
    self.pages = pages;

    const back = &self.frames[self.front ^ 1];
    back.reset();
    const capacity = @max(self.rows, 1) * @max(self.pages, 1);
    try back.rows.ensureTotalCapacity(self.gpa, capacity);
    self.sink = .{
        .frame = back,
        .columns = size.columns,
        .offset = 0,
        .columns_written = 0,
        .has_text = false,
    };
    return &self.sink;
}

/// Diff the frame just composed through the `Sink` against the one on screen,
/// repaint the smallest correct region, and swap frames. One row may carry the
/// caret; the real cursor is moved there and shown, otherwise it is hidden.
pub fn render(self: *View) !void {
    const back = &self.frames[self.front ^ 1];
    const prev = &self.frames[self.front];
    const prev_empty = prev.rows.items.len == 0;

    if (back.rows.items.len == 0) {
        try self.paintEmpty(prev_empty and !self.force_reset);
    } else if (self.force_reset) {
        try self.paint(.reset, back, .{});
    } else if (prev_empty or self.structural_change) {
        try self.paint(if (prev_empty) .fresh else .reset, back, .{});
    } else if (findAlignment(prev, back)) |alignment| {
        if (alignment.back_index == 0) {
            // Forward slide: the new top row is shared; rows above it scrolled away.
            const delta = alignment.prev_index;
            const deepest = @min(prev.rows.items.len - 1 - delta, back.rows.items.len - 1);
            if (firstChange(prev, delta, back)) |changed| {
                // A shrunk tail must reveal scrolled-off rows: a backward slide in disguise.
                const shrank = back.rows.items.len + delta < prev.rows.items.len;
                if (changed + delta < self.viewport_top or (shrank and self.viewport_top > 0)) {
                    try self.paint(.reset, back, .{});
                } else {
                    // Reprint no lower than the previous last row, so the append scrolls by \r\n.
                    try self.paint(.incremental, back, .{
                        .anchor = @min(changed, deepest),
                        .cursor_from = self.cursor_row -| delta,
                    });
                }
            } else if (delta == 0) {
                // Content unchanged, so no slide happened: `cursor_row` is still valid.
                try self.paintCaretOnly(back);
            } else if (self.viewport_top > 0) {
                try self.paint(.reset, back, .{});
            } else {
                // A pure top-trim keeps the tail bytes but slides the window, so rebase.
                try self.paint(.incremental, back, .{
                    .anchor = deepest,
                    .cursor_from = self.cursor_row -| delta,
                });
            }
        } else if (self.viewport_top == 0) {
            // Backward slide: row 0 changed, reachable only when the whole window shows.
            try self.paint(.incremental, back, .{ .cursor_from = self.cursor_row });
        } else {
            try self.paint(.reset, back, .{});
        }
    } else {
        try self.paint(.reset, back, .{});
    }
    self.force_reset = false;
    self.front ^= 1;
}

/// Reprint `frame` from `rows.anchor` down, positioning the cursor per `mode`.
/// In `incremental` mode the move starts from `rows.cursor_from`, the current
/// cursor row expressed in this frame's coordinates. All motion counts physical
/// rows.
fn paint(self: *View, mode: Mode, frame: *const Frame, rows: struct {
    anchor: usize = 0,
    cursor_from: usize = 0,
}) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    switch (mode) {
        .fresh => {},
        .reset => try writer.writeAll(escape.screen_reset),
        .incremental => {
            if (rows.cursor_from >= rows.anchor) {
                try escape.cursorMove(writer, 'A', rows.cursor_from - rows.anchor);
            } else {
                try escape.cursorMove(writer, 'B', rows.anchor - rows.cursor_from);
            }
            try writer.writeAll("\r");
            try writer.writeAll(escape.screen_clear_below);
        },
    }
    const items = frame.rows.items;
    for (items[rows.anchor..], rows.anchor..) |row, index| {
        if (index > rows.anchor) try writer.writeAll("\r\n");
        try writer.writeAll(frame.bytes(row));
    }
    // The last `rows` physical rows are visible; everything above is scrollback.
    self.viewport_top = frame.rows.items.len -| @max(self.rows, 1);
    try self.restoreCursor(items.len - 1, frame);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

/// The rows are unchanged; only the caret or its visibility may differ, so emit
/// nothing but the cursor move.
fn paintCaretOnly(self: *View, frame: *const Frame) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    try self.restoreCursor(self.cursor_row, frame);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

/// Nothing to show: wipe the region and hide the cursor. The app always emits at
/// least the status line, so this only guards misuse.
fn paintEmpty(self: *View, prev_empty: bool) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    if (!prev_empty) try writer.writeAll(escape.screen_reset);
    if (self.cursor_visible) {
        try writer.writeAll(escape.cursor_hide);
        self.cursor_visible = false;
    }
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
    self.viewport_top = 0;
    self.cursor_row = 0;
}

/// Move the hardware cursor from `from_row` to `frame`'s caret and show it, or
/// hide it when there is no caret or it sits above the viewport (scrolled off
/// the top, so unaddressable).
fn restoreCursor(self: *View, from_row: usize, frame: *const Frame) !void {
    const writer = self.writer;
    if (frame.caret) |caret| {
        if (caret.row >= self.viewport_top) {
            if (from_row >= caret.row) {
                try escape.cursorMove(writer, 'A', from_row - caret.row);
            } else {
                try escape.cursorMove(writer, 'B', caret.row - from_row);
            }
            try writer.writeAll("\r");
            try escape.cursorMove(writer, 'C', caret.column);
            if (!self.cursor_visible) {
                try writer.writeAll(escape.cursor_show);
                self.cursor_visible = true;
            }
            self.cursor_row = caret.row;
            return;
        }
    }
    if (self.cursor_visible) {
        try writer.writeAll(escape.cursor_hide);
        self.cursor_visible = false;
    }
    self.cursor_row = from_row;
}

/// The first anchor `back` shares with `prev`: its index in `back` and its index
/// in `prev`. Anchors are unique per frame, so the match is unambiguous.
fn findAlignment(prev: *const Frame, back: *const Frame) ?Alignment {
    for (back.rows.items, 0..) |back_row, back_index| {
        for (prev.rows.items, 0..) |prev_row, prev_index| {
            if (Anchor.eql(back_row.anchor, prev_row.anchor)) {
                return .{ .back_index = back_index, .prev_index = prev_index };
            }
        }
    }
    return null;
}

/// Scanning down from the aligned rows (`back[0]` against `prev[prev_start]`),
/// the first index at which they differ, treating a missing row on either side
/// as a difference. Null when the overlap is byte-for-byte identical and equal
/// in length.
fn firstChange(prev: *const Frame, prev_start: usize, back: *const Frame) ?usize {
    const back_rows = back.rows.items;
    const prev_rows = prev.rows.items;
    var index: usize = 0;
    while (index < back_rows.len or prev_start + index < prev_rows.len) : (index += 1) {
        const back_present = index < back_rows.len;
        const prev_present = prev_start + index < prev_rows.len;
        if (!back_present or !prev_present) return index;
        const back_bytes = back.bytes(back_rows[index]);
        if (!std.mem.eql(u8, back_bytes, prev.bytes(prev_rows[prev_start + index]))) {
            return index;
        }
    }
    return null;
}

fn validSgr(comptime sequence: []const u8) bool {
    if (sequence.len < 3 or sequence[0] != 0x1b or sequence[1] != '[' or
        sequence[sequence.len - 1] != 'm')
    {
        return false;
    }
    for (sequence[2 .. sequence.len - 1]) |byte| {
        if (byte != ';' and (byte < '0' or byte > '9')) return false;
    }
    return true;
}

// Drives one `render` and replays only the bytes it produced into the emulator.
const Harness = struct {
    out: std.Io.Writer.Allocating,
    view: View,
    emulator: Emulator,
    consumed: usize,
    last_from: usize,

    fn deinit(self: *Harness) void {
        self.view.deinit();
        self.emulator.deinit();
        self.out.deinit();
    }

    fn render(self: *Harness, lines: []const Line, size: Size, pages: usize) !void {
        self.last_from = self.consumed;
        const sink = try self.view.beginFrame(size, pages);
        const capacity = @max(size.rows, 1) * @max(pages, 1);
        const start = if (lines.len > capacity) lines.len - capacity else 0;
        for (lines[start..]) |item| {
            sink.begin();
            if (item.bold) try sink.sgr("\x1b[1m");
            try sink.text(item.bytes);
            if (item.bold) try sink.sgr("\x1b[0m");
            if (item.caret) |column| sink.setCaret(column);
            sink.end(item.anchor);
        }
        try self.view.render();
        const bytes = self.out.written();
        self.emulator.rows = size.rows;
        try self.emulator.feed(bytes[self.consumed..]);
        self.consumed = bytes.len;
    }

    // Bytes emitted by the most recent `render`, to assert the repaint shape.
    fn lastBytes(self: *Harness) []const u8 {
        return self.out.written()[self.last_from..self.consumed];
    }
};

fn makeHarness(gpa: std.mem.Allocator, columns: usize) !*Harness {
    const self = try gpa.create(Harness);
    self.* = .{
        .out = .init(gpa),
        .view = undefined,
        .emulator = try Emulator.init(gpa, columns),
        .consumed = 0,
        .last_from = 0,
    };
    self.view = View.init(gpa, &self.out.writer);
    return self;
}

/// The row a test composes through the view's `Sink`: bytes, anchor, and an
/// optional caret column.
const Line = struct { bytes: []const u8, anchor: Anchor, caret: ?usize = null, bold: bool = false };

fn line(bytes: []const u8, id: usize) Line {
    return .{ .bytes = bytes, .anchor = .{ .id = id, .line = 0 } };
}

fn boldLine(bytes: []const u8, id: usize) Line {
    return .{ .bytes = bytes, .anchor = .{ .id = id, .line = 0 }, .bold = true };
}

fn caretLine(bytes: []const u8, options: struct { id: usize, column: usize }) Line {
    return .{
        .bytes = bytes,
        .anchor = .{ .id = options.id, .line = 0 },
        .caret = options.column,
    };
}

test "paints a fresh frame row for row" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 80);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const frame = [_]Line{ line("hello", 0), line("world", 1) };
    try harness.render(&frame, .{ .columns = 80, .rows = 24 }, 4);
    try harness.emulator.expectVisible(&.{ "hello", "world" });
    try std.testing.expect(!harness.emulator.cursor_visible);
}

test "a sliding-window append repaints incrementally and keeps the caret synced" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Two pages of three rows: the window holds six rows before it slides.
    const first = [_]Line{ line("a", 0), line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&first, .{ .columns = 10, .rows = 3 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "b", "c" });
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 2, .column = 1 });

    // Append four rows so the top row is evicted and the window slides by one.
    const second = [_]Line{
        line("a", 0),
        line("b", 1),
        line("c", 2),
        line("d", 3),
        line("e", 4),
        line("f", 5),
        caretLine("g", .{ .id = 6, .column = 1 }),
    };
    try harness.render(&second, .{ .columns = 10, .rows = 3 }, 2);
    try harness.emulator.expectVisible(&.{ "b", "c", "d", "e", "f", "g" });
    // No reset: the append reprinted from the old last row; Δ rebase keeps the caret synced.
    try harness.emulator.expectCaret(.{ .frame_len = 6, .row = 5, .column = 1 });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);
}

test "a backward slide past one page resets" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Window of four rows (two pages of two); the last four of six show.
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2),
        line("r3", 3), line("r4", 4), line("r5", 5),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "r2", "r3", "r4", "r5" });

    // The tail shrinks by two rows, pulling older rows back in above the shared
    // anchor: the first changed row is 0, which sits in scrollback -> reset.
    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try harness.render(&short, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "a shrink while scrolled resets so the top of the frame returns" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Eight rows in a four-row screen: r0..r3 scroll off, r4..r7 show. The frame
    // stays whole (well under the page budget), so its top anchor is always
    // shared and the diff takes the forward path.
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3),
        line("r4", 4), line("r5", 5), line("r6", 6), line("r7", 7),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r4", "r5", "r6", "r7" });

    // Drop a row from the tail. The last page must now show r3, which had
    // scrolled off the top — reachable only by clearing and reprinting, since an
    // inline terminal cannot reveal its scrollback.
    const short = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3),
        line("r4", 4), line("r5", 5), line("r7", 7),
    };
    try harness.render(&short, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r3", "r4", "r5", "r7" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "a backward slide within one page reprints from row zero" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Single-page window of three rows; the last three of five show.
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r4", 4),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectVisible(&.{ "r2", "r3", "r4" });

    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2) };
    try harness.render(&short, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2" });
    // Reprint from row 0, not a full reset: no scrollback clear, but a clear-below.
    const last = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_reset) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_clear_below) != null);
}

test "a change above the viewport resets" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Four rows over two pages of two: rows 0 and 1 sit in scrollback.
    const first = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try harness.render(&first, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3" });

    // Change the top row (its anchor is stable) — it is above the viewport.
    const second = [_]Line{ line("R0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try harness.render(&second, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "R0", "r1", "r2", "r3" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "a page-count change resets" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const frame = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 3);
    try harness.emulator.expectVisible(&.{ "a", "b" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "a resize resets" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const frame = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.render(&frame, .{ .columns = 8, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "b" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
    try harness.render(&frame, .{ .columns = 8, .rows = 3 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "b" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "a jump with no shared anchor resets" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const first = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&first, .{ .columns = 10, .rows = 4 }, 2);
    const second = [_]Line{ line("c", 100), line("d", 101) };
    try harness.render(&second, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "c", "d" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "a full-width row places the caret at the pending-wrap margin" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 3);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // "abc" is exactly three columns, leaving the terminal pending-wrap; the
    // `\r` before caret placement resolves it and CUF clamps at the last cell.
    const frame = [_]Line{caretLine("abc", .{ .id = 0, .column = 3 })};
    try harness.render(&frame, .{ .columns = 3, .rows = 3 }, 1);
    try harness.emulator.expectVisible(&.{"abc"});
    try harness.emulator.expectCaret(.{ .frame_len = 1, .row = 0, .column = 2 });
}

test "an over-wide row clips at the margin and keeps the cursor synced" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 3);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const sink = try harness.view.beginFrame(.{ .columns = 3, .rows = 4 }, 1);
    sink.begin();
    try sink.text("abcdef");
    // A second fragment after the budget is spent adds no columns.
    try sink.text("gh");
    sink.end(.{ .id = 0, .line = 0 });
    sink.begin();
    try sink.text("z");
    sink.setCaret(1);
    sink.end(.{ .id = 1, .line = 0 });
    try harness.view.render();
    harness.emulator.rows = 4;
    try harness.emulator.feed(harness.out.written());
    // The over-wide row never wraps, so the frame stays two physical rows.
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.document.items.len);
    const top_row = harness.emulator.document.items[0].items;
    try std.testing.expect(std.mem.indexOf(u8, top_row, "abc") != null);
    try std.testing.expect(std.mem.indexOfAny(u8, top_row, "defgh") == null);
    try harness.emulator.expectCaret(.{ .frame_len = 2, .row = 1, .column = 1 });
}

test "the caret is hidden with no caret and when above the viewport" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 5);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const none = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&none, .{ .columns = 5, .rows = 2 }, 2);
    try std.testing.expect(!harness.emulator.cursor_visible);
    // The cursor is already hidden, so a caret-less frame emits no redundant hide.
    try harness.render(&none, .{ .columns = 5, .rows = 2 }, 2);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.cursor_hide) == null);

    // A caret on the top row of a four-row window whose viewport is two rows:
    // it is above the viewport and must stay hidden.
    const above = [_]Line{
        caretLine("a", .{ .id = 0, .column = 1 }), line("b", 1), line("c", 2), line("d", 3),
    };
    try harness.render(&above, .{ .columns = 5, .rows = 2 }, 2);
    try std.testing.expect(!harness.emulator.cursor_visible);
}

test "an empty frame wipes the region and hides the cursor" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const frame = [_]Line{caretLine("x", .{ .id = 0, .column = 1 })};
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try std.testing.expect(harness.emulator.cursor_visible);

    try harness.render(&.{}, .{ .columns = 10, .rows = 4 }, 2);
    try std.testing.expect(!harness.emulator.cursor_visible);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "an unchanged frame emits only caret motion" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const first = [_]Line{caretLine("ab", .{ .id = 0, .column = 2 })};
    try harness.render(&first, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectCaret(.{ .frame_len = 1, .row = 0, .column = 2 });

    // Same bytes, caret moved left: no reprint, just a cursor move.
    const moved = [_]Line{caretLine("ab", .{ .id = 0, .column = 1 })};
    try harness.render(&moved, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectCaret(.{ .frame_len = 1, .row = 0, .column = 1 });
    const last = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_reset) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_clear_below) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, "ab") == null);
    // The caret was already visible, so no redundant show is emitted.
    try std.testing.expect(std.mem.indexOf(u8, last, escape.cursor_show) == null);
}

test "a pure top-trim repaints the identical tail and rebases the caret" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const first = [_]Line{ line("a", 0), line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&first, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 2, .column = 1 });

    // The top row is trimmed and the remaining rows are byte-identical: the
    // window still slid, so a caret-only paint would desync `cursor_row`.
    const second = [_]Line{ line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&second, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectCaret(.{ .frame_len = 2, .row = 1, .column = 1 });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);

    const third = [_]Line{ line("b", 1), line("c", 2), caretLine("d", .{ .id = 3, .column = 1 }) };
    try harness.render(&third, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectScreen(&.{ "b", "c", "d" });
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 2, .column = 1 });
}

test "a pure top-trim with rows scrolled off resets" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Four rows over two pages of two: rows 0 and 1 sit in scrollback.
    const first = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), caretLine("r3", .{ .id = 3, .column = 1 }),
    };
    try harness.render(&first, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "r2", "r3" });

    // Trim the top row with the tail byte-identical: the slid window cannot be
    // reconciled incrementally against a partly scrolled-off screen.
    const second = [_]Line{
        line("r1", 1), line("r2", 2), caretLine("r3", .{ .id = 3, .column = 1 }),
    };
    try harness.render(&second, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "r2", "r3" });
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 2, .column = 1 });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "invalidate forces a full reset even when content is unchanged" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const frame = [_]Line{ line("hello", 0), line("world", 1) };
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "hello", "world" });

    // External output scrolled the terminal; the same content must reprint from a
    // full clear rather than diff to a caret-only paint.
    harness.view.invalidate();
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "hello", "world" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "canonical text boundaries survive separate sink writes" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = View.init(gpa, &out.writer);
    defer view.deinit();

    // Fragments whose adjacent edges would fuse into different graphemes (an
    // emoji ZWJ join, a variation selector after a replacement, one after a
    // space): each row must measure as the sum of its separately measured
    // fragments once composed.
    const sink = try view.beginFrame(.{ .columns = 9, .rows = 4 }, 1);
    sink.begin();
    try sink.text("\x1b");
    try sink.text("\u{FE0F}");
    try sink.text("👨\u{200D}");
    try sink.text("👩");
    try sink.spaces(2);
    sink.end(.{ .id = 0, .line = 0 });
    const first_row = sink.frame.bytes(sink.frame.rows.items[0]);
    try std.testing.expectEqual(sink.columns_written, width.ofText(first_row));
    sink.begin();
    try sink.spaces(1);
    try sink.text("\u{FE0F}");
    sink.end(.{ .id = 1, .line = 0 });
    const other_row = sink.frame.bytes(sink.frame.rows.items[1]);
    try std.testing.expectEqual(sink.columns_written, width.ofText(other_row));
    try view.render();

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\u{200D}👩") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b\u{FE0F}") == null);
}

test "a styled row reprinted from its own start carries its escapes" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 20);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const styled = "\x1b[1mBOLD\x1b[0m";
    const first = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&first, .{ .columns = 20, .rows = 4 }, 2);

    // Only the second row changes, so the incremental repaint begins at it.
    const second = [_]Line{ line("a", 0), boldLine("BOLD", 1) };
    try harness.render(&second, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "BOLD" });
    // The row re-opens and closes its own SGR, relying on no state from above.
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), styled) != null);
}
