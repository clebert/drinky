//! Reconciling renderer for an inline (non-alternate-screen) frame.
//!
//! The view draws a bounded **window** — the last `pages` pages (a page is the
//! terminal height) of the newest content — into the terminal's normal buffer.
//! It never lays out the whole model: the caller composes complete, pre-fitted
//! physical rows directly into the view's own buffer through a `Sink`, so memory
//! stays bounded however far the content grows.
//!
//! Each frame is composed through `beginFrame`, which resets the back frame and
//! hands back a `Sink` bound to it. The caller emits one row at a time — its
//! bytes fitted to at most `columns` display width and carrying their own style
//! escapes verbatim, an opaque `Anchor` (stable cross-frame identity), and an
//! optional caret column — then calls `render` to diff and repaint. The view
//! keeps two frames and ping-pongs them — this frame in one, last frame in the
//! other — resetting the older with retained capacity each frame, so after
//! warmup no frame allocates.
//!
//! Reconciliation is by anchor, not screen position, so a sliding window does
//! not force a reset on every append:
//!
//! - **Forward slide** (the shared top row scrolled down, e.g. an append that
//!   evicted rows off the top): repaint incrementally from the first changed
//!   row down, but no lower than the previous frame's last on-screen row, so the
//!   append scrolls the terminal by `\r\n` rather than moving the cursor below
//!   the bottom margin (where it would clamp, not scroll). Evicted rows scroll
//!   into native scrollback for free. The stored cursor row was measured from
//!   the old window top, which slid down, so it is rebased by Δ (how far the
//!   window slid) before the move.
//! - **Backward slide** (older rows re-entered above the shared row, because
//!   the footer or tail shrank): the re-entered top rows are new this frame, so
//!   the first changed row is `0`. The terminal cannot un-scroll its
//!   scrollback, so this is never incremental above the viewport — it resets,
//!   or reprints from row `0` when the window is a single page. A tail that
//!   shrinks while the shared top row stays put counts here too when rows have
//!   scrolled off: the shorter frame lifts its footer, so the last page must
//!   reveal rows now in scrollback, and only a reset can.
//! - **A change above the viewport, a resize, a page-count change, or no shared
//!   anchor** clears the screen and scrollback and reprints the whole window.
//!
//! Every line is exactly one physical row, so all cursor motion is a plain row
//! count. Every repaint is wrapped in a synchronized-output burst so it lands
//! without flicker. The active input caret is given as a column on one line;
//! after painting the view moves the hardware cursor there and shows it, or
//! hides it when there is no caret or it fell above the viewport.

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
/// painted. One line is one physical row, so this is a plain row index.
cursor_row: usize,
/// Tracks the terminal's cursor visibility so show/hide is emitted only on a
/// change. The owning `Tty` hides the cursor at startup, matching the initial
/// value here.
cursor_visible: bool,
/// The sink handed out by `beginFrame`, composing into the back frame until the
/// paired `render`.
sink: Sink,
/// Set by `beginFrame` when the columns, rows, or page count changed since the
/// last frame, forcing `render` to repaint the whole window.
structural_change: bool,

pub const Size = struct { columns: usize, rows: usize };

/// Stable identity of one physical row's content, so the diff survives a
/// sliding window. Opaque to the view, which only compares anchors for
/// equality; ids come from disjoint namespaces so they never alias as the model
/// grows.
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

/// Hardware cursor position after a repaint: a display `column` on `row`. The
/// view resolves `row` to a window-relative index; a producing component
/// reports it relative to its own rows for the assembler to rebase. Absent when
/// no input is focused.
pub const Caret = struct { row: usize, column: usize };

/// Composes rows directly into the back frame's `blob`. The caller opens a row
/// with `begin`, writes its bytes through the returned writer, optionally marks
/// the caret with `setCaret`, and closes it with `end`. Handed out by
/// `beginFrame`; valid until the paired `render`.
pub const Sink = struct {
    frame: *Frame,
    columns: usize,
    offset: usize,

    /// Open a row: capture the current `blob` end and return the writer that
    /// composes into it. The bytes may move as `blob` grows, so the row is
    /// recorded by offset, not slice.
    pub fn begin(self: *Sink) *std.Io.Writer {
        self.offset = self.frame.blob.writer.end;
        return &self.frame.blob.writer;
    }

    /// Close the row opened by `begin`, recording it under `anchor`. Asserts the
    /// row is exactly one physical row: at most `columns` display columns
    /// (escapes measured out) and free of the C0 controls that move or split a
    /// row. Inline SGR escapes are fine — zero width, no motion.
    pub fn end(self: *Sink, anchor: Anchor) void {
        const bytes = self.frame.blob.writer.buffered()[self.offset..];
        std.debug.assert(oneRow(bytes, self.columns));
        self.frame.rows.appendAssumeCapacity(.{ .offset = self.offset, .len = bytes.len, .anchor = anchor });
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
    };
}

pub fn deinit(self: *View) void {
    for (&self.frames) |*frame| frame.deinit(self.gpa);
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
    self.sink = .{ .frame = back, .columns = size.columns, .offset = 0 };
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
        try self.paintEmpty(prev_empty);
        self.front ^= 1;
        return;
    }

    if (prev_empty or self.structural_change) {
        try self.paint(if (prev_empty) .fresh else .reset, 0, back, 0);
        self.front ^= 1;
        return;
    }

    // Align on the first shared anchor, not screen position, so a slide need not reset.
    const alignment = findAlignment(prev, back) orelse {
        try self.paint(.reset, 0, back, 0);
        self.front ^= 1;
        return;
    };
    if (alignment.back_index == 0) {
        // Forward slide: the new top row is shared; rows above it scrolled away.
        const changed = firstChange(prev, alignment.prev_index, back) orelse {
            // Content unchanged, so no slide happened: `cursor_row` is still valid.
            try self.paintCaretOnly(back);
            self.front ^= 1;
            return;
        };
        const delta = alignment.prev_index;
        // A shrunk tail must reveal scrolled-off rows: a backward slide in disguise.
        const shrank = back.rows.items.len + delta < prev.rows.items.len;
        if (changed + delta < self.viewport_top or (shrank and self.viewport_top > 0)) {
            try self.paint(.reset, 0, back, 0);
        } else {
            // Reprint no lower than the previous last row, so the append scrolls by \r\n.
            const deepest = @min(prev.rows.items.len - 1 - delta, back.rows.items.len - 1);
            try self.paint(.incremental, @min(changed, deepest), back, self.cursor_row -| delta);
        }
    } else {
        // Backward slide: row 0 changed, reachable only when the whole window shows.
        if (self.viewport_top == 0) {
            try self.paint(.incremental, 0, back, self.cursor_row);
        } else {
            try self.paint(.reset, 0, back, 0);
        }
    }
    self.front ^= 1;
}

/// Reprint `frame` from `anchor` down, positioning the cursor per `mode`. In
/// `incremental` mode the move starts from `cursor_from`, the current cursor row
/// expressed in this frame's coordinates. All motion counts physical rows.
fn paint(self: *View, mode: Mode, anchor: usize, frame: *const Frame, cursor_from: usize) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    switch (mode) {
        .fresh => {},
        .reset => try writer.writeAll(escape.screen_reset),
        .incremental => {
            if (cursor_from >= anchor) {
                try escape.cursorUp(writer, cursor_from - anchor);
            } else {
                try escape.cursorDown(writer, anchor - cursor_from);
            }
            try writer.writeAll("\r");
            try writer.writeAll(escape.screen_clear_below);
        },
    }
    const items = frame.rows.items;
    for (items[anchor..], anchor..) |row, index| {
        if (index > anchor) try writer.writeAll("\r\n");
        try writer.writeAll(frame.bytes(row));
    }
    self.viewport_top = viewportTop(frame, self.rows);
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
                try escape.cursorUp(writer, from_row - caret.row);
            } else {
                try escape.cursorDown(writer, caret.row - from_row);
            }
            try writer.writeAll("\r");
            try escape.cursorForward(writer, caret.column);
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
        if (!std.mem.eql(u8, back.bytes(back_rows[index]), prev.bytes(prev_rows[prev_start + index]))) {
            return index;
        }
    }
    return null;
}

/// Window-relative index of the topmost row still on screen: the last `rows`
/// physical rows are visible, everything above sits in scrollback.
fn viewportTop(frame: *const Frame, rows: usize) usize {
    const len = frame.rows.items.len;
    const height = @max(rows, 1);
    return if (len > height) len - height else 0;
}

fn oneRow(bytes: []const u8, columns_max: usize) bool {
    if (width.ofText(bytes) > columns_max) return false;
    for (bytes) |byte| switch (byte) {
        '\n', '\r', '\t', 0x08, 0x0b, 0x0c => return false,
        else => {},
    };
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
            const writer = sink.begin();
            try writer.writeAll(item.bytes);
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

fn harness(gpa: std.mem.Allocator, columns: usize) !*Harness {
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
const Line = struct { bytes: []const u8, anchor: Anchor, caret: ?usize = null };

fn line(bytes: []const u8, id: usize) Line {
    return .{ .bytes = bytes, .anchor = .{ .id = id, .line = 0 } };
}

fn caretLine(bytes: []const u8, id: usize, column: usize) Line {
    return .{ .bytes = bytes, .anchor = .{ .id = id, .line = 0 }, .caret = column };
}

test "paints a fresh frame row for row" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 80);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const frame = [_]Line{ line("hello", 0), line("world", 1) };
    try h.render(&frame, .{ .columns = 80, .rows = 24 }, 4);
    try h.emulator.expectVisible(&.{ "hello", "world" });
    try std.testing.expect(!h.emulator.cursor_visible);
}

test "a sliding-window append repaints incrementally and keeps the caret synced" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    // Two pages of three rows: the window holds six rows before it slides.
    const first = [_]Line{ line("a", 0), line("b", 1), caretLine("c", 2, 1) };
    try h.render(&first, .{ .columns = 10, .rows = 3 }, 2);
    try h.emulator.expectVisible(&.{ "a", "b", "c" });
    try h.emulator.expectCaret(3, 2, 1);

    // Append four rows so the top row is evicted and the window slides by one.
    const second = [_]Line{
        line("a", 0),
        line("b", 1),
        line("c", 2),
        line("d", 3),
        line("e", 4),
        line("f", 5),
        caretLine("g", 6, 1),
    };
    try h.render(&second, .{ .columns = 10, .rows = 3 }, 2);
    try h.emulator.expectVisible(&.{ "b", "c", "d", "e", "f", "g" });
    // The evicted top row scrolls into scrollback and none of the on-screen rows
    // are lost: the append reprints from the old last row and scrolls by \r\n,
    // and the Δ rebase keeps the caret on the true last row.
    try h.emulator.expectCaret(6, 5, 1);
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) == null);
}

test "a backward slide past one page resets" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    // Window of four rows (two pages of two); the last four of six show.
    const tall = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r4", 4), line("r5", 5) };
    try h.render(&tall, .{ .columns = 10, .rows = 2 }, 2);
    try h.emulator.expectVisible(&.{ "r2", "r3", "r4", "r5" });

    // The tail shrinks by two rows, pulling older rows back in above the shared
    // anchor: the first changed row is 0, which sits in scrollback -> reset.
    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try h.render(&short, .{ .columns = 10, .rows = 2 }, 2);
    try h.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3" });
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) != null);
}

test "a shrink while scrolled resets so the top of the frame returns" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    // Eight rows in a four-row screen: r0..r3 scroll off, r4..r7 show. The frame
    // stays whole (well under the page budget), so its top anchor is always
    // shared and the diff takes the forward path.
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3),
        line("r4", 4), line("r5", 5), line("r6", 6), line("r7", 7),
    };
    try h.render(&tall, .{ .columns = 10, .rows = 4 }, 8);
    try h.emulator.expectScreen(&.{ "r4", "r5", "r6", "r7" });

    // Drop a row from the tail. The last page must now show r3, which had
    // scrolled off the top — reachable only by clearing and reprinting, since an
    // inline terminal cannot reveal its scrollback.
    const short = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3),
        line("r4", 4), line("r5", 5), line("r7", 7),
    };
    try h.render(&short, .{ .columns = 10, .rows = 4 }, 8);
    try h.emulator.expectScreen(&.{ "r3", "r4", "r5", "r7" });
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) != null);
}

test "a backward slide within one page reprints from row zero" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    // Single-page window of three rows; the last three of five show.
    const tall = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r4", 4) };
    try h.render(&tall, .{ .columns = 10, .rows = 3 }, 1);
    try h.emulator.expectVisible(&.{ "r2", "r3", "r4" });

    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2) };
    try h.render(&short, .{ .columns = 10, .rows = 3 }, 1);
    try h.emulator.expectVisible(&.{ "r0", "r1", "r2" });
    // Reprint from row 0, not a full reset: no scrollback clear, but a clear-below.
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) == null);
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_clear_below) != null);
}

test "a change above the viewport resets" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    // Four rows over two pages of two: rows 0 and 1 sit in scrollback.
    const first = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try h.render(&first, .{ .columns = 10, .rows = 2 }, 2);
    try h.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3" });

    // Change the top row (its anchor is stable) — it is above the viewport.
    const second = [_]Line{ line("R0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try h.render(&second, .{ .columns = 10, .rows = 2 }, 2);
    try h.emulator.expectVisible(&.{ "R0", "r1", "r2", "r3" });
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) != null);
}

test "a page-count change resets" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const frame = [_]Line{ line("a", 0), line("b", 1) };
    try h.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try h.render(&frame, .{ .columns = 10, .rows = 4 }, 3);
    try h.emulator.expectVisible(&.{ "a", "b" });
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) != null);
}

test "a jump with no shared anchor resets" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const first = [_]Line{ line("a", 0), line("b", 1) };
    try h.render(&first, .{ .columns = 10, .rows = 4 }, 2);
    const second = [_]Line{ line("c", 100), line("d", 101) };
    try h.render(&second, .{ .columns = 10, .rows = 4 }, 2);
    try h.emulator.expectVisible(&.{ "c", "d" });
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) != null);
}

test "a full-width row places the caret at the pending-wrap margin" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 3);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    // "abc" is exactly three columns, leaving the terminal pending-wrap; the
    // `\r` before caret placement resolves it and CUF clamps at the last cell.
    const frame = [_]Line{caretLine("abc", 0, 3)};
    try h.render(&frame, .{ .columns = 3, .rows = 3 }, 1);
    try h.emulator.expectVisible(&.{"abc"});
    try h.emulator.expectCaret(1, 0, 2);
}

test "the caret is hidden with no caret and when above the viewport" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 5);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const none = [_]Line{ line("a", 0), line("b", 1) };
    try h.render(&none, .{ .columns = 5, .rows = 2 }, 2);
    try std.testing.expect(!h.emulator.cursor_visible);

    // A caret on the top row of a four-row window whose viewport is two rows:
    // it is above the viewport and must stay hidden.
    const above = [_]Line{ caretLine("a", 0, 1), line("b", 1), line("c", 2), line("d", 3) };
    try h.render(&above, .{ .columns = 5, .rows = 2 }, 2);
    try std.testing.expect(!h.emulator.cursor_visible);
}

test "an empty frame wipes the region and hides the cursor" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const frame = [_]Line{caretLine("x", 0, 1)};
    try h.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try std.testing.expect(h.emulator.cursor_visible);

    try h.render(&.{}, .{ .columns = 10, .rows = 4 }, 2);
    try std.testing.expect(!h.emulator.cursor_visible);
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) != null);
}

test "an unchanged frame emits only caret motion" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 10);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const first = [_]Line{caretLine("ab", 0, 2)};
    try h.render(&first, .{ .columns = 10, .rows = 4 }, 2);
    try h.emulator.expectCaret(1, 0, 2);

    // Same bytes, caret moved left: no reprint, just a cursor move.
    const moved = [_]Line{caretLine("ab", 0, 1)};
    try h.render(&moved, .{ .columns = 10, .rows = 4 }, 2);
    try h.emulator.expectCaret(1, 0, 1);
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_reset) == null);
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), escape.screen_clear_below) == null);
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), "ab") == null);
}

test "a styled row reprinted from its own start carries its escapes" {
    const gpa = std.testing.allocator;
    const h = try harness(gpa, 20);
    defer {
        h.deinit();
        gpa.destroy(h);
    }
    const styled = "\x1b[1mBOLD\x1b[0m";
    const first = [_]Line{ line("a", 0), line("b", 1) };
    try h.render(&first, .{ .columns = 20, .rows = 4 }, 2);

    // Only the second row changes, so the incremental repaint begins at it.
    const second = [_]Line{ line("a", 0), line(styled, 1) };
    try h.render(&second, .{ .columns = 20, .rows = 4 }, 2);
    try h.emulator.expectVisible(&.{ "a", "BOLD" });
    // The row re-opens and closes its own SGR, relying on no state from above.
    try std.testing.expect(std.mem.indexOf(u8, h.lastBytes(), styled) != null);
}
