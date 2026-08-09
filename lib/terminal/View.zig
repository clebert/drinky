//! A renderer that reconciles a frame on the primary or alternate terminal screen.
//!
//! The caller composes complete, pre-fitted physical rows through the `Sink` from
//! `beginFrame`: the last `pages` pages of the newest content, never the whole
//! model. `render` diffs against the frame on screen and repaints the smallest
//! correct region. The two frames ping-pong with retained capacity, so after
//! warmup no frame allocates.
//!
//! Reconciliation uses row **anchors**, not screen positions. A sliding window
//! can then append without a reset. The repaint starts no lower than the previous
//! last row. Its `\r\n` sequences scroll at the bottom margin.
//!
//! The view tracks screen lines for the frame, the screen top, and the cursor.
//! These lines increase until a reset starts a new epoch. A shrink can therefore
//! end above the bottom and leave blank rows. A height loss advances the top only
//! enough to keep the cursor visible. A later height growth can add blank rows below.
//!
//! A fresh inline frame starts at the shell cursor. Tracked line zero need not be
//! physical row zero. This offset does not change cursor distances or when tracked
//! rows enter scrollback.
//!
//! The view never pulls inaccessible scrollback back onto the screen. When a
//! bounded frame adds an older prefix, the view discards that prefix and keeps
//! its printed top. It can reprint a backward slide when the previous top remains
//! on screen.
//!
//! Every frame line is one physical row. Each repaint is one synchronized-output
//! burst. Primary-screen resets clear inaccessible scrollback. An alternate-screen
//! view can preserve it.

const std = @import("std");

const Emulator = @import("Emulator.zig");
const escape = @import("escape.zig");
const grapheme = @import("grapheme.zig");
const width = @import("width.zig");

const View = @This();

gpa: std.mem.Allocator,
writer: *std.Io.Writer,
frames: [2]Frame,
/// Index of the frame currently on screen. The view composes into the other frame.
front: u1,
columns: usize,
rows: usize,
pages: usize,
/// First tracked line that remains on screen in this reset epoch. Smaller tracked
/// lines are native scrollback.
screen_top_line: usize,
/// Line of the hardware cursor in the current reset epoch.
cursor_line: usize,
/// Terminal cursor visibility, so the view emits show/hide only on a change. The
/// owning `Tty` hides the cursor at startup, which matches the initial value here.
cursor_visible: bool,
/// The sink handed out by `beginFrame`. It composes into the back frame until
/// the paired `render`.
sink: Sink,
/// Set by `beginFrame` when the columns or page count changed. This forces
/// `render` to repaint the whole window. A height change reconciles incrementally.
structural_change: bool,
/// Set by `invalidate`: the screen no longer matches the last painted frame.
force_reset: bool,
/// Full resets leave native scrollback intact, for a view on an alternate screen.
preserve_scrollback: bool,

pub const Size = struct { columns: usize, rows: usize };

/// Stable identity of one physical row's content, so the diff survives a
/// sliding window. Opaque to the view (compared only for equality). Ids come
/// from disjoint namespaces so they never alias as the model grows.
pub const Anchor = struct {
    id: usize,
    line: usize,

    fn eql(a: Anchor, b: Anchor) bool {
        return a.id == b.id and a.line == b.line;
    }
};

/// One complete physical line, fitted to at most the terminal width. An offset
/// into the frame's `blob`, not a slice: `blob` grows during composition and
/// can reallocate, which dangles a slice. An offset survives.
const Row = struct { offset: usize, len: usize, anchor: Anchor };

/// Hardware cursor position after a repaint: a display `column` on window-relative
/// `row` (a producer reports it relative to its own rows, and the assembler
/// rebases). Absent when no input is focused.
pub const Caret = struct { row: usize, column: usize };

/// Composes rows directly into the back frame's `blob`. The caller opens a row
/// with `begin` and writes inert display content through `text` and application
/// styling through `sgr`. An optional `setCaret` marks the caret, and `end`
/// closes the row. The sink never exposes the underlying writer. The one piece
/// of runtime content that reaches the trusted terminal-control channel is the
/// hyperlink URL, which `linkable` clears before `linkSet` writes any.
pub const Sink = struct {
    frame: *Frame,
    columns: usize,
    rows_max: usize,
    offset: usize,
    columns_written: usize,
    has_text: bool,
    /// Whether the tail of the last fragment written joins whatever follows it,
    /// such as a Prepend or a ZWJ. The next seam then takes a guard, whatever
    /// the fragment after it starts with.
    tail_joining: bool,
    /// Whether a hyperlink is open on the row under composition.
    link_open: bool,

    /// The longest URL a hyperlink carries. Every frame repeats the target of
    /// every visible link, so the cap keeps one row small.
    pub const url_bytes_max = 2048;

    /// The schemes a hyperlink can name. A terminal hands the target of a click
    /// to the system, so a click must not reach a scheme the user does not
    /// expect. The scheme reads case-insensitively, as a terminal accepts it.
    const url_schemes = [_][]const u8{ "http://", "https://", "mailto:" };

    /// Open a row and capture the current `blob` end.
    pub fn begin(self: *Sink) void {
        self.offset = self.frame.blob.writer.end;
        self.columns_written = 0;
        self.has_text = false;
        self.tail_joining = false;
        self.link_open = false;
    }

    /// Append inert display text. The same scanner used for layout and width
    /// accounting canonicalizes terminal controls and malformed UTF-8. A seam
    /// that can fuse takes a zero-width guard, so separately measured fragments
    /// do not become one terminal grapheme.
    pub fn text(self: *Sink, bytes: []const u8) !void {
        return self.textFitted(bytes, self.columns -| self.columns_written);
    }

    /// Append inert display text fitted to both `columns_max` and the row's
    /// remaining capacity. This lets a caller reserve trailing decoration.
    pub fn textFitted(self: *Sink, bytes: []const u8, columns_max: usize) !void {
        if (bytes.len == 0) return;
        try self.guard(bytes);
        const available = @min(columns_max, self.columns -| self.columns_written);
        const start = self.frame.blob.writer.end;
        self.columns_written += try width.writeFitted(&self.frame.blob.writer, bytes, available);
        self.trackTail(start);
    }

    /// Append up to `count` ordinary spaces and keep the row writer private.
    pub fn spaces(self: *Sink, count: usize) !void {
        return self.repeat(" ", count);
    }

    /// Append up to `count` copies of a compile-time single-column `cell` as one
    /// contiguous run. A filled row then carries no inter-cell boundaries. `cell`
    /// must be a plain decorative glyph (such as a rule dash) whose copies do not
    /// combine into a wider cluster. `count` copies then stay `count` columns.
    pub fn repeat(self: *Sink, comptime cell: []const u8, count: usize) !void {
        comptime std.debug.assert(width.ofText(cell) == 1);
        const shown = @min(count, self.columns -| self.columns_written);
        if (shown == 0) return;
        try self.guard(cell);
        const start = self.frame.blob.writer.end;
        try self.frame.blob.writer.splatBytesAll(cell, shown);
        self.columns_written += shown;
        self.trackTail(start);
    }

    /// Append a compile-time-known Select Graphic Rendition sequence. The sink
    /// accepts only SGR syntax. Cursor, screen, and string controls remain
    /// private to the renderer.
    pub fn sgr(self: *Sink, comptime sequence: []const u8) !void {
        comptime if (!validSgr(sequence))
            @compileError("trusted style must be one complete SGR sequence");
        try self.frame.blob.writer.writeAll(sequence);
    }

    /// Make the text that follows a hyperlink to `url`, which `linkReset`
    /// closes again. The sink writes nothing for a URL that `linkable` refuses,
    /// so an unsupported target still renders as plain text.
    pub fn linkSet(self: *Sink, url: []const u8) !void {
        if (!linkable(url)) return;
        const writer = &self.frame.blob.writer;
        try writer.writeAll(escape.link_set);
        try writer.writeAll(url);
        try writer.writeAll(escape.string_end);
        self.link_open = true;
    }

    /// Close the hyperlink that `linkSet` opened. It writes nothing when no link
    /// is open, so a row that carries none stays free of the string control.
    pub fn linkReset(self: *Sink) !void {
        if (!self.link_open) return;
        self.link_open = false;
        try self.frame.blob.writer.writeAll(escape.link_reset);
    }

    /// Whether `linkSet` accepts `url`. The URL is the only runtime content in
    /// the terminal control channel, so the sink is the one boundary that
    /// clears it. It must be bounded, hold printable ASCII alone, and name a
    /// scheme in `url_schemes`. No space, control byte, or string terminator
    /// can then leave the URL field of the string control, and no click can
    /// reach an unexpected scheme.
    pub fn linkable(url: []const u8) bool {
        if (url.len == 0 or url.len > url_bytes_max) return false;
        for (url) |byte| if (byte <= ' ' or byte >= 0x7f) return false;
        for (url_schemes) |scheme| {
            if (std.ascii.startsWithIgnoreCase(url, scheme)) return true;
        }
        return false;
    }

    /// Close the row opened by `begin` and record it under `anchor`.
    pub fn end(self: *Sink, anchor: Anchor) void {
        std.debug.assert(self.columns_written <= self.columns);
        // A row must close its own hyperlink. An open one makes every row under
        // it clickable.
        std.debug.assert(!self.link_open);
        const len = self.frame.blob.writer.end - self.offset;
        // A measure/render parity slip that overflows `beginFrame`'s row
        // reservation is loud in safe builds. In unsafe builds it is a dropped
        // row: a visible glitch, not an out-of-bounds write.
        std.debug.assert(self.frame.rows.items.len < self.rows_max);
        if (self.frame.rows.items.len == self.rows_max) return;
        self.frame.rows.appendAssumeCapacity(
            .{ .offset = self.offset, .len = len, .anchor = anchor },
        );
    }

    /// Place the caret at display `column` on the row under composition, the
    /// one opened by the most recent `begin`.
    pub fn setCaret(self: *Sink, column: usize) void {
        self.frame.caret = .{ .row = self.frame.rows.items.len, .column = column };
    }

    /// Write a zero-width guard before `bytes` when the seam can fuse. A seam
    /// fuses when the row ends on an open join, or when `bytes` starts with a
    /// code point that continues the cluster before it. A seam that cannot fuse
    /// stays bare, so a frame carries almost no guards. A terminal that gives a
    /// guard a column then does not shift the row. A row with no columns left
    /// can keep a guard whose fragment wrote nothing. That guard costs nothing.
    fn guard(self: *Sink, bytes: []const u8) !void {
        if (!self.has_text) return;
        if (!self.tail_joining and !grapheme.startsJoining(bytes)) return;
        try self.frame.blob.writer.writeAll("\u{200B}");
    }

    /// Classify the tail of the bytes written since `start`, so the next seam
    /// knows whether it can fuse. A fragment that the column budget dropped
    /// whole writes nothing and leaves the tail of the row as it was.
    fn trackTail(self: *Sink, start: usize) void {
        const written = self.frame.blob.writer.buffered()[start..];
        if (written.len == 0) return;
        self.tail_joining = grapheme.endsJoining(written);
        self.has_text = true;
    }
};

/// A frame's two reused buffers, caret, and printed top line. `blob` holds all
/// row bytes in screen order. `rows` indexes them with fixed capacity.
const Frame = struct {
    blob: std.Io.Writer.Allocating,
    rows: std.ArrayList(Row),
    caret: ?Caret,
    /// Screen line that contains row zero in the current reset epoch.
    top_line: usize,

    fn init(gpa: std.mem.Allocator) Frame {
        return .{ .blob = .init(gpa), .rows = .empty, .caret = null, .top_line = 0 };
    }

    fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        self.blob.deinit();
        self.rows.deinit(gpa);
    }

    fn reset(self: *Frame) void {
        self.blob.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.caret = null;
        self.top_line = 0;
    }

    fn dropLeadingRows(self: *Frame, count: usize) void {
        std.debug.assert(count <= self.rows.items.len);
        const kept = self.rows.items.len - count;
        std.mem.copyForwards(Row, self.rows.items[0..kept], self.rows.items[count..]);
        self.rows.shrinkRetainingCapacity(kept);
        if (self.caret) |*caret| {
            if (caret.row < count) {
                self.caret = null;
            } else {
                caret.row -= count;
            }
        }
    }

    fn bytes(self: *const Frame, row: Row) []const u8 {
        return self.blob.writer.buffered()[row.offset..][0..row.len];
    }
};

/// How `paint` positions the cursor before it reprints from its anchor row.
const Mode = enum {
    /// First frame: print from the current cursor, no clear.
    fresh,
    /// Clear the screen under the configured scrollback policy, then reprint.
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
        .screen_top_line = 0,
        .cursor_line = 0,
        .cursor_visible = false,
        .sink = undefined,
        .structural_change = false,
        .force_reset = false,
        .preserve_scrollback = false,
    };
}

pub fn deinit(self: *View) void {
    for (&self.frames) |*frame| frame.deinit(self.gpa);
}

/// Force the next `render` to clear and reprint under the configured scrollback
/// policy. Use this after external output has moved the terminal out from under
/// the diff. The caller has re-hidden the cursor, so tracking resets to match.
pub fn invalidate(self: *View) void {
    self.force_reset = true;
    self.cursor_visible = false;
}

/// Make visible-screen resets leave native scrollback intact.
pub fn preserveScrollback(self: *View) void {
    self.preserve_scrollback = true;
}

/// Forget both retained frames and write nothing to the terminal. The caller
/// has switched to a fresh screen before the next render.
pub fn forget(self: *View) void {
    for (&self.frames) |*frame| frame.reset();
    self.front = 0;
    self.columns = 0;
    self.rows = 0;
    self.pages = 0;
    self.screen_top_line = 0;
    self.cursor_line = 0;
    self.cursor_visible = false;
    self.structural_change = false;
    self.force_reset = false;
}

/// Begin the next frame at `size` and `pages`: reset the back frame and hand
/// back the `Sink` that composes rows into it. Pair every `beginFrame` with a
/// `render`, which diffs the composed frame against the one on screen.
pub fn beginFrame(self: *View, size: Size, pages: usize) !*Sink {
    const width_changed = self.columns != 0 and self.columns != size.columns;
    const height_changed = self.rows != 0 and self.rows != size.rows;
    const pages_changed = self.pages != 0 and self.pages != pages;
    if (height_changed) self.resizeHeight(size.rows);
    self.structural_change = width_changed or pages_changed;
    self.columns = size.columns;
    self.rows = size.rows;
    self.pages = pages;

    const back = &self.frames[self.front ^ 1];
    back.reset();
    const capacity = self.screenHeight() * @max(self.pages, 1);
    try back.rows.ensureTotalCapacity(self.gpa, capacity);
    self.sink = .{
        .frame = back,
        .columns = size.columns,
        .rows_max = capacity,
        .offset = 0,
        .columns_written = 0,
        .has_text = false,
        .tail_joining = false,
        .link_open = false,
    };
    return &self.sink;
}

/// Diff the frame just composed through the `Sink` against the one on screen,
/// repaint the smallest correct region, and swap frames. One row can carry the
/// caret. The view moves the real cursor there and shows it, or else hides it.
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
            try self.paintAligned(prev, back, alignment.prev_index);
        } else if (self.lineVisible(prev.top_line)) {
            // The previous top is still addressable. Reprint the backward slide there.
            back.top_line = prev.top_line;
            try self.paint(.incremental, back, .{ .line = prev.top_line });
        } else if (alignment.prev_index == 0) {
            // The producer pulled inaccessible history into the bounded frame.
            // Keep the printed top and discard that backward prefix.
            back.dropLeadingRows(alignment.back_index);
            try self.paintDroppedPrefix(prev, back);
        } else {
            try self.paint(.reset, back, .{});
        }
    } else {
        try self.paint(.reset, back, .{});
    }
    self.force_reset = false;
    self.front ^= 1;
}

/// Move the hardware cursor to the last frame row and show it. Call this at
/// shutdown, so the shell prompt continues below the interface. This is a no-op
/// when the frame has no addressable row.
pub fn parkCursor(self: *View) !void {
    const frame = &self.frames[self.front];
    const count = frame.rows.items.len;
    if (count == 0) return;
    const last_line = frame.top_line + count - 1;
    if (!self.lineVisible(last_line)) return;
    try self.moveCursor(last_line);
    const writer = self.writer;
    try writer.writeAll("\r");
    if (!self.cursor_visible) {
        try writer.writeAll(escape.cursor_show);
        self.cursor_visible = true;
    }
    try writer.flush();
}

/// Reconcile frames that share the new top row. `delta` locates that row in
/// `prev`.
fn paintAligned(self: *View, prev: *const Frame, back: *Frame, delta: usize) !void {
    const scrolled = back.rows.items.len + delta > prev.rows.items.len;
    const aligned_top = prev.top_line + delta;
    if (delta > 0 and !scrolled) {
        const printed_top = @max(prev.top_line, self.screen_top_line);
        if (aligned_top > printed_top) {
            // The producer removed rows that remain on screen. Move the tail to
            // the first tracked line and erase those rows without a reset.
            back.top_line = printed_top;
            try self.paint(.incremental, back, .{ .line = printed_top });
            return;
        }
    }

    back.top_line = aligned_top;
    const maybe_changed = firstChangeFrom(prev, back, .{
        .prev_start = delta,
        .back_start = 0,
    });
    if (maybe_changed) |changed| {
        try self.paintChangedSuffix(prev, back, .{ .changed = changed, .prev_start = delta });
    } else {
        try self.paintTailOrCaret(back);
    }
}

/// Reconcile a frame after the view discards its inaccessible backward prefix.
fn paintDroppedPrefix(self: *View, prev: *const Frame, back: *Frame) !void {
    back.top_line = prev.top_line;
    const visible_start = self.screen_top_line -| back.top_line;
    const maybe_changed = firstChangeFrom(prev, back, .{
        .prev_start = 0,
        .back_start = visible_start,
    });
    if (maybe_changed) |changed| {
        // The visible scan can start after a frame that ends in scrollback.
        if (changed >= back.rows.items.len) {
            // Keep the cleared rows blank instead of resurrecting scrollback with a reset.
            const screen_line = @max(back.top_line + changed, self.screen_top_line);
            std.debug.assert(self.lineVisible(screen_line));
            try self.paint(.incremental, back, .{
                .anchor = back.rows.items.len,
                .line = screen_line,
            });
            return;
        }

        try self.paintChangedSuffix(prev, back, .{ .changed = changed, .prev_start = 0 });
    } else {
        try self.paintTailOrCaret(back);
    }
}

/// Repaint an unchanged tail when a height loss moved it below the screen.
fn paintTailOrCaret(self: *View, frame: *Frame) !void {
    const screen_bottom = self.screen_top_line + self.screenHeight() - 1;
    const last_line = frame.top_line + frame.rows.items.len - 1;
    if (last_line <= screen_bottom) {
        try self.paintCaretOnly(frame);
        return;
    }
    if (frame.top_line > screen_bottom) {
        try self.paint(.reset, frame, .{});
        return;
    }
    const anchor = frame.rows.items.len - 1 - (last_line - screen_bottom);
    try self.paint(.incremental, frame, .{ .anchor = anchor, .line = screen_bottom });
}

/// Repaint a changed suffix. Start at the previous last row when output must scroll.
fn paintChangedSuffix(
    self: *View,
    prev: *const Frame,
    back: *Frame,
    options: struct { changed: usize, prev_start: usize },
) !void {
    std.debug.assert(options.changed <= back.rows.items.len);
    const deepest = @min(
        prev.rows.items.len - 1 - options.prev_start,
        back.rows.items.len - 1,
    );
    var anchor = @min(options.changed, deepest);
    var screen_line = back.top_line + anchor;
    if (!self.lineVisible(screen_line)) {
        // The previous last row entered scrollback. Start at the first changed row.
        // Every skipped row is then above the screen.
        anchor = options.changed;
        screen_line = back.top_line + anchor;
        if (!self.lineVisible(screen_line)) {
            // The changed suffix remains inaccessible. Reset so its new rows can appear.
            try self.paint(.reset, back, .{});
            return;
        }
    }
    try self.paint(.incremental, back, .{ .anchor = anchor, .line = screen_line });
}

/// Reprint `frame` from `options.anchor`. An incremental paint starts on
/// `options.line`. The caller sets `frame.top_line` only for incremental mode.
fn paint(self: *View, mode: Mode, frame: *Frame, options: struct {
    anchor: usize = 0,
    line: usize = 0,
}) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    switch (mode) {
        .fresh => frame.top_line = self.cursor_line,
        .reset => {
            try writer.writeAll(self.resetSequence());
            self.applyReset();
            frame.top_line = self.cursor_line;
        },
        .incremental => {
            std.debug.assert(options.anchor <= frame.rows.items.len);
            std.debug.assert(self.lineVisible(options.line));
            try self.moveCursor(options.line);
            try writer.writeAll("\r");
            try writer.writeAll(escape.screen_clear_below);
        },
    }

    const items = frame.rows.items;
    if (options.anchor < items.len) {
        std.debug.assert(self.cursor_line == frame.top_line + options.anchor);
        for (items[options.anchor..], options.anchor..) |row, index| {
            if (index > options.anchor) {
                try writer.writeAll("\r\n");
                self.advanceLine();
            }
            try writer.writeAll(frame.bytes(row));
        }
    }
    try self.restoreCursor(frame);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

/// The rows are unchanged. Only the caret or its visibility can differ.
fn paintCaretOnly(self: *View, frame: *const Frame) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    try self.restoreCursor(frame);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

/// Nothing to show: wipe the region and hide the cursor. The app always emits at
/// least the status line, so this only guards misuse.
fn paintEmpty(self: *View, prev_empty: bool) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    if (!prev_empty) {
        try writer.writeAll(self.resetSequence());
        self.applyReset();
    }
    if (self.cursor_visible) {
        try writer.writeAll(escape.cursor_hide);
        self.cursor_visible = false;
    }
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

fn resetSequence(self: *const View) []const u8 {
    return if (self.preserve_scrollback) escape.screen_repaint else escape.screen_reset;
}

fn applyReset(self: *View) void {
    if (self.preserve_scrollback) {
        self.cursor_line = self.screen_top_line;
    } else {
        self.screen_top_line = 0;
        self.cursor_line = 0;
    }
}

fn screenHeight(self: *const View) usize {
    return @max(self.rows, 1);
}

/// Keep the tracked cursor visible when the terminal loses rows. Added rows stay
/// below the current screen, so a later growth does not pull scrollback down.
fn resizeHeight(self: *View, rows: usize) void {
    const height = @max(rows, 1);
    if (height >= self.screenHeight()) return;
    const cursor_top = self.cursor_line -| (height - 1);
    self.screen_top_line = @max(self.screen_top_line, cursor_top);
}

fn advanceLine(self: *View) void {
    const screen_bottom = self.screen_top_line + self.screenHeight() - 1;
    if (self.cursor_line >= screen_bottom) self.screen_top_line += 1;
    self.cursor_line += 1;
}

fn lineVisible(self: *const View, screen_line: usize) bool {
    return screen_line >= self.screen_top_line and
        screen_line - self.screen_top_line < self.screenHeight();
}

fn moveCursor(self: *View, screen_line: usize) !void {
    std.debug.assert(self.lineVisible(self.cursor_line));
    std.debug.assert(self.lineVisible(screen_line));
    if (self.cursor_line >= screen_line) {
        try escape.cursorMove(self.writer, 'A', self.cursor_line - screen_line);
    } else {
        try escape.cursorMove(self.writer, 'B', screen_line - self.cursor_line);
    }
    self.cursor_line = screen_line;
}

/// Move the hardware cursor to the frame caret and show it. Hide it when the
/// caret is outside the screen.
fn restoreCursor(self: *View, frame: *const Frame) !void {
    const writer = self.writer;
    if (frame.caret) |caret| {
        const screen_line = frame.top_line + caret.row;
        if (self.lineVisible(screen_line)) {
            try self.moveCursor(screen_line);
            try writer.writeAll("\r");
            try escape.cursorMove(writer, 'C', caret.column);
            if (!self.cursor_visible) {
                try writer.writeAll(escape.cursor_show);
                self.cursor_visible = true;
            }
            return;
        }
    }
    if (self.cursor_visible) {
        try writer.writeAll(escape.cursor_hide);
        self.cursor_visible = false;
    }
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

/// Scan from `back_start` and compare `back[index]` with `prev[prev_start + index]`.
/// Return the first difference. A missing row counts as a difference. Return null
/// when both remaining suffixes are equal.
fn firstChangeFrom(
    prev: *const Frame,
    back: *const Frame,
    options: struct { prev_start: usize, back_start: usize },
) ?usize {
    const back_rows = back.rows.items;
    const prev_rows = prev.rows.items;
    var index = options.back_start;
    while (index < back_rows.len or options.prev_start + index < prev_rows.len) : (index += 1) {
        const back_present = index < back_rows.len;
        const prev_present = options.prev_start + index < prev_rows.len;
        if (!back_present or !prev_present) return index;
        const back_bytes = back.bytes(back_rows[index]);
        if (!std.mem.eql(u8, back_bytes, prev.bytes(prev_rows[options.prev_start + index]))) {
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
        self.emulator.columns = size.columns;
        self.emulator.resize(size.rows);
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
        try self.emulator.feed(bytes[self.consumed..]);
        self.consumed = bytes.len;
        try std.testing.expectEqual(self.view.screen_top_line, self.emulator.screen_top);
        try std.testing.expectEqual(self.view.cursor_line, self.emulator.cursor_row);
    }

    // Bytes emitted by the most recent `render`, to assert the repaint shape.
    fn lastBytes(self: *Harness) []const u8 {
        return self.out.written()[self.last_from..self.consumed];
    }
};

fn makeHarness(gpa: std.mem.Allocator, columns: usize) !*Harness {
    const self = try gpa.create(Harness);
    errdefer gpa.destroy(self);
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

// Regression: a transcript clear (a `/new`) removes the rows above the shared
// editor and status anchors while nothing has scrolled off. Those rows sit on
// screen, so the frame must reprint from row zero and erase them. It must not
// treat the removal as a forward slide and strand them above the tail.
test "a shrink to the tail with nothing scrolled off erases the rows above" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 20);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const full = [_]Line{
        line("m0", 0),
        line("m1", 1),
        line("m2", 2),
        caretLine("prompt", .{ .id = 1000, .column = 6 }),
        line("status", 1001),
    };
    try harness.render(&full, .{ .columns = 20, .rows = 24 }, 8);
    try harness.emulator.expectScreen(&.{ "m0", "m1", "m2", "prompt", "status" });

    const cleared = [_]Line{
        caretLine("P", .{ .id = 1000, .column = 1 }),
        line("status", 1001),
    };
    try harness.render(&cleared, .{ .columns = 20, .rows = 24 }, 8);
    try harness.emulator.expectScreen(&.{ "P", "status" });
    try std.testing.expect(harness.emulator.document.items.len == 2);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);
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

    // Append four rows to evict the top row and slide the window by one.
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
    // No reset: the append reprinted from the old last row. The Δ rebase keeps
    // the caret synced.
    try harness.emulator.expectCaret(.{ .frame_len = 6, .row = 5, .column = 1 });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);
}

test "a clipped backward slide preserves the printed top" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Window of four rows (two pages of two). The last four of six show.
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2),
        line("r3", 3), line("r4", 4), line("r5", 5),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "r2", "r3", "r4", "r5" });
    const screen_top = harness.emulator.screen_top;

    // The shrink pulls r0 and r1 into the bounded frame. They cannot re-enter
    // the screen, so the view discards them and clears the removed visible tail.
    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2) };
    try harness.render(&short, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    try std.testing.expectEqualStrings("r2", harness.emulator.document.items[0].items);
    try std.testing.expectEqualStrings("r3", harness.emulator.document.items[1].items);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);

    // Growth skips inaccessible new rows and starts at the first visible line.
    const grown = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r4", 4),
    };
    try harness.render(&grown, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "r4", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);
}

test "an unchanged backward prefix drops its caret" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const first = [_]Line{
        line("b", 1),
        line("c", 2),
        caretLine("d", .{ .id = 3, .column = 1 }),
        line("e", 4),
    };
    try harness.render(&first, .{ .columns = 10, .rows = 2 }, 3);
    try harness.emulator.expectScreen(&.{ "d", "e" });
    try std.testing.expect(harness.emulator.cursor_visible);

    const prefixed = [_]Line{
        caretLine("a", .{ .id = 0, .column = 1 }),
        line("b", 1),
        line("c", 2),
        line("d", 3),
        line("e", 4),
    };
    try harness.render(&prefixed, .{ .columns = 10, .rows = 2 }, 3);
    try harness.emulator.expectScreen(&.{ "d", "e" });
    try std.testing.expect(!harness.emulator.cursor_visible);
    try std.testing.expect(harness.view.frames[harness.view.front].caret == null);
    const last = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, last, escape.cursor_hide) != null);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_clear_below) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_reset) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, "a") == null);
}

test "a mixed backward jump resets" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const first = [_]Line{ line("a", 0), line("b", 1), line("c", 2), line("d", 3) };
    try harness.render(&first, .{ .columns = 10, .rows = 2 }, 3);
    try harness.emulator.expectScreen(&.{ "c", "d" });

    // The prefix starts before a shared inner row, not before the previous top.
    const mixed = [_]Line{ line("x", 10), line("c", 2), line("d", 3) };
    try harness.render(&mixed, .{ .columns = 10, .rows = 2 }, 3);
    try harness.emulator.expectScreen(&.{ "c", "d" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "a one-row editor shrink preserves clipped session scrollback" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 20);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const before_clip = [_]Line{
        line("history 0", 0),
        line("history 1", 1),
        line("body 0", 2),
        caretLine("edit", .{ .id = 4, .column = 4 }),
        line("wrap", 5),
        line("status", 6),
    };
    try harness.render(&before_clip, .{ .columns = 20, .rows = 3 }, 2);
    try harness.emulator.expectScreen(&.{ "edit", "wrap", "status" });

    // The next transcript row clips history 0 from the retained frame. Its
    // existing terminal row remains at the start of native scrollback.
    const expanded = [_]Line{
        line("history 0", 0),
        line("history 1", 1),
        line("body 0", 2),
        line("body 1", 3),
        caretLine("edit", .{ .id = 4, .column = 4 }),
        line("wrap", 5),
        line("status", 6),
    };
    try harness.render(&expanded, .{ .columns = 20, .rows = 3 }, 2);
    try harness.emulator.expectScreen(&.{ "edit", "wrap", "status" });
    const screen_top = harness.emulator.screen_top;
    try std.testing.expectEqualStrings("history 0", harness.emulator.document.items[0].items);

    // The bounded projection pulls history 0 into the frame when the editor
    // loses one row. The view discards that prefix and keeps history 1 intact.
    const shrunk = [_]Line{
        line("history 0", 0),
        line("history 1", 1),
        line("body 0", 2),
        line("body 1", 3),
        caretLine("edit", .{ .id = 4, .column = 4 }),
        line("status", 6),
    };
    try harness.render(&shrunk, .{ .columns = 20, .rows = 3 }, 2);
    try harness.emulator.expectScreen(&.{ "edit", "status", "" });
    try harness.emulator.expectCaret(.{ .frame_len = 5, .row = 3, .column = 4 });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    const document_shrunk = [_][]const u8{
        "history 0", "history 1", "body 0", "body 1", "edit", "status",
    };
    try std.testing.expectEqual(document_shrunk.len, harness.emulator.document.items.len);
    for (document_shrunk, harness.emulator.document.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual.items);
    }
    const shrink_bytes = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, shrink_bytes, escape.screen_repaint) == null);
    try std.testing.expect(std.mem.indexOf(u8, shrink_bytes, "\x1b[3J") == null);
    try std.testing.expect(std.mem.indexOf(u8, shrink_bytes, escape.screen_clear_below) != null);

    // Growth consumes the blank row without a reset or a forward scroll.
    try harness.render(&expanded, .{ .columns = 20, .rows = 3 }, 2);
    try harness.emulator.expectScreen(&.{ "edit", "wrap", "status" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    const document_expanded = [_][]const u8{
        "history 0", "history 1", "body 0", "body 1", "edit", "wrap", "status",
    };
    try std.testing.expectEqual(document_expanded.len, harness.emulator.document.items.len);
    for (document_expanded, harness.emulator.document.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual.items);
    }
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);
}

test "repeated shrinks accumulate blank rows below" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Eight rows in a four-row screen: r0..r3 scroll off and r4..r7 show. The
    // frame stays whole (well under the page budget), so its top anchor is
    // always shared and the diff takes the forward path.
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3),
        line("r4", 4), line("r5", 5), line("r6", 6), line("r7", 7),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r4", "r5", "r6", "r7" });

    // Drop a row from the tail. The view keeps r3 in scrollback and moves the
    // shorter tail up. The terminal leaves the row below it blank.
    const screen_top = harness.emulator.screen_top;
    const short = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3),
        line("r4", 4), line("r5", 5), line("r7", 7),
    };
    try harness.render(&short, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r4", "r5", "r7", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    try std.testing.expectEqualStrings("r3", harness.emulator.document.items[3].items);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);

    // Each additional shrink moves the tail up and adds another blank row.
    const shorter = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2),
        line("r3", 3), line("r4", 4), line("r7", 7),
    };
    try harness.render(&shorter, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r4", "r7", "", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);

    const shortest = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r7", 7),
    };
    try harness.render(&shortest, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r7", "", "", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);
}

test "a backward slide within one page reprints from row zero" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // Single-page window of three rows. The last three of five show.
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

    // Change the top row (its anchor is stable). It is above the viewport.
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

test "a width resize resets" {
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
}

test "a height resize preserves scrollback and leaves blank rows below" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 20);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const first = [_]Line{
        line("history", 0),
        line("thinking", 1),
        line("answer 0", 2),
        line("answer 1", 3),
        line("answer 2", 4),
        line("answer 3", 5),
        caretLine("editor", .{ .id = 10, .column = 6 }),
        line("status", 11),
    };
    try harness.render(&first, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectScreen(&.{ "answer 2", "answer 3", "editor", "status" });

    // Extend past the retained window. The thinking row now lives only in
    // native scrollback, so a bounded repaint cannot reconstruct it.
    const extended = [_]Line{
        line("history", 0),
        line("thinking", 1),
        line("answer 0", 2),
        line("answer 1", 3),
        line("answer 2", 4),
        line("answer 3", 5),
        line("answer 4", 6),
        line("answer 5", 7),
        line("answer 6", 8),
        line("answer 7", 9),
        caretLine("editor", .{ .id = 10, .column = 6 }),
        line("status", 11),
    };
    try harness.render(&extended, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectScreen(&.{ "answer 6", "answer 7", "editor", "status" });

    try harness.render(&extended, .{ .columns = 20, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "editor", "status" });
    const screen_top = harness.emulator.screen_top;
    const shrink = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, shrink, escape.screen_repaint) == null);
    try std.testing.expect(std.mem.indexOf(u8, shrink, "thinking") == null);

    try harness.render(&extended, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectScreen(&.{ "editor", "status", "", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    const expected = [_][]const u8{
        "history",  "thinking", "answer 0", "answer 1", "answer 2", "answer 3",
        "answer 4", "answer 5", "answer 6", "answer 7", "editor",   "status",
    };
    try std.testing.expectEqual(expected.len, harness.emulator.document.items.len);
    for (expected, harness.emulator.document.items) |text, row| {
        try std.testing.expectEqualStrings(text, row.items);
    }
    const growth = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, growth, escape.screen_repaint) == null);
    try std.testing.expect(std.mem.indexOf(u8, growth, "thinking") == null);
    try std.testing.expect(std.mem.indexOf(u8, growth, "editor") == null);
    try std.testing.expect(std.mem.indexOf(u8, growth, "status") == null);
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
    // "abc" is exactly three columns and leaves the terminal pending-wrap. The
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
    // A second fragment after the budget runs out adds no columns.
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

test "a fitted fragment preserves room for trailing cells" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 3);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const sink = try harness.view.beginFrame(.{ .columns = 3, .rows = 1 }, 1);
    sink.begin();
    try sink.textFitted("你", 1);
    try sink.text("|");
    sink.end(.{ .id = 0, .line = 0 });
    try harness.view.render();
    harness.emulator.rows = 1;
    try harness.emulator.feed(harness.out.written());
    try std.testing.expectEqual(@as(usize, 2), sink.columns_written);
    // The replacement brings its own boundaries and `|` joins nothing, so the
    // seam between the two fragments stays bare.
    try harness.emulator.expectVisible(&.{"\u{200B}�\u{200B}|"});
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

test "parkCursor moves the cursor to the last row below the caret" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    // The caret sits on the editor row, one row above the status line.
    const frame = [_]Line{
        line("body", 0),
        caretLine("prompt", .{ .id = 1, .column = 6 }),
        line("status", 2),
    };
    try harness.render(&frame, .{ .columns = 10, .rows = 24 }, 1);
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 1, .column = 6 });

    try harness.view.parkCursor();
    const bytes = harness.out.written();
    try harness.emulator.feed(bytes[harness.consumed..]);
    harness.consumed = bytes.len;

    // The cursor now sits on the last row (the status line), at column zero, so
    // the shell prompt after exit prints below the whole interface.
    try std.testing.expectEqual(
        harness.emulator.document.items.len - 1,
        harness.emulator.cursor_row,
    );
    try std.testing.expectEqual(@as(usize, 0), harness.emulator.cursor_column);
    try std.testing.expect(harness.emulator.cursor_visible);
}

test "parkCursor writes nothing for an empty frame" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = View.init(gpa, &out.writer);
    defer view.deinit();
    try view.parkCursor();
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
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
    // The caret was already visible, so the view emits no redundant show.
    try std.testing.expect(std.mem.indexOf(u8, last, escape.cursor_show) == null);
}

test "a top-trim with nothing scrolled off reprints from row zero" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const first = [_]Line{ line("a", 0), line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&first, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 2, .column = 1 });

    // The second frame removes the top row on screen (nothing scrolled off) and
    // keeps the remaining rows byte-identical. The view reprints from row zero
    // to erase it, with no full reset.
    const second = [_]Line{ line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&second, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectScreen(&.{ "b", "c" });
    try harness.emulator.expectCaret(.{ .frame_len = 2, .row = 1, .column = 1 });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);

    const third = [_]Line{ line("b", 1), line("c", 2), caretLine("d", .{ .id = 3, .column = 1 }) };
    try harness.render(&third, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectScreen(&.{ "b", "c", "d" });
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 2, .column = 1 });
}

test "a pure top-trim with rows scrolled off preserves the screen" {
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

    // Trim an inaccessible top row. The byte-identical visible tail stays in place.
    const second = [_]Line{
        line("r1", 1), line("r2", 2), caretLine("r3", .{ .id = 3, .column = 1 }),
    };
    try harness.render(&second, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "r2", "r3" });
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 2, .column = 1 });
    const last = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_reset) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_clear_below) == null);
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

    // External output scrolled the terminal. The same content must reprint from
    // a full clear rather than diff to a caret-only paint.
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

    // These fragments have adjacent edges that can fuse into different graphemes
    // (an emoji ZWJ join, a variation selector after a replacement, one after a
    // space). Each row must measure as the sum of its separately measured
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

test "a seam takes a guard only where the two fragments can fuse" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = View.init(gpa, &out.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 40, .rows = 4 }, 1);
    // Ordinary spans, spaces, and a rule cannot fuse, so this row holds no guard.
    sink.begin();
    try sink.text("model");
    try sink.spaces(1);
    try sink.text("(account)");
    try sink.repeat("─", 4);
    sink.end(.{ .id = 0, .line = 0 });
    const plain = sink.frame.bytes(sink.frame.rows.items[0]);
    try std.testing.expectEqualStrings("model (account)────", plain);
    try std.testing.expectEqual(sink.columns_written, width.ofText(plain));

    // A leading combining mark joins the text before it, and a trailing ZWJ
    // joins the emoji after it. Both seams take the guard.
    sink.begin();
    try sink.text("e");
    try sink.text("\u{0301}");
    try sink.text("👨\u{200D}");
    try sink.text("👩");
    sink.end(.{ .id = 1, .line = 0 });
    const joined = sink.frame.bytes(sink.frame.rows.items[1]);
    try std.testing.expectEqualStrings("e\u{200B}\u{0301}👨\u{200D}\u{200B}👩", joined);
    try std.testing.expectEqual(sink.columns_written, width.ofText(joined));

    // An open tail guards the run that `repeat` writes too, even though a space
    // and a rule dash join nothing on their own.
    sink.begin();
    try sink.text("👨\u{200D}");
    try sink.spaces(1);
    try sink.repeat("─", 2);
    sink.end(.{ .id = 2, .line = 0 });
    const run = sink.frame.bytes(sink.frame.rows.items[2]);
    try std.testing.expectEqualStrings("👨\u{200D}\u{200B} ──", run);
    try std.testing.expectEqual(sink.columns_written, width.ofText(run));
    try view.render();
}

// A hyperlink frames its own text and closes inside the row. The target rides
// in a string control, so the screen shows the text alone. A URL the sink
// refuses opens no link at all and loses only the target.
test "a hyperlink frames its text and closes within its row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = View.init(gpa, &out.writer);
    defer view.deinit();
    var emulator = try Emulator.init(gpa, 20);
    defer emulator.deinit();
    emulator.resize(4);

    const sink = try view.beginFrame(.{ .columns = 20, .rows = 4 }, 1);
    sink.begin();
    try sink.linkSet("https://example.com/a");
    try sink.text("docs");
    try sink.linkReset();
    try sink.linkSet("https://example.com/\x1b\\evil");
    try sink.text("!");
    try sink.linkReset();
    sink.end(.{ .id = 0, .line = 0 });
    try view.render();

    const framed = "\x1b]8;;https://example.com/a\x1b\\docs\x1b]8;;\x1b\\!";
    try std.testing.expect(std.mem.indexOf(u8, out.written(), framed) != null);
    try emulator.feed(out.written());
    try emulator.expectVisible(&.{"docs!"});

    // The URL must be bounded printable ASCII under a scheme a click can open.
    // The scheme reads case-insensitively, and every other one stays inert.
    try std.testing.expect(Sink.linkable("mailto:someone@example.com"));
    try std.testing.expect(Sink.linkable("HTTPS://X.Y/a"));
    try std.testing.expect(!Sink.linkable(""));
    try std.testing.expect(!Sink.linkable("https://example.com/a b"));
    try std.testing.expect(!Sink.linkable("https://example.com/\u{00e9}"));
    try std.testing.expect(!Sink.linkable("https://x.y/" ++ ("a" ** Sink.url_bytes_max)));
    try std.testing.expect(!Sink.linkable("javascript:alert(1)"));
    try std.testing.expect(!Sink.linkable("file:///etc/passwd"));
    try std.testing.expect(!Sink.linkable("./x.md"));
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
    // The row re-opens and closes its own SGR. It relies on no state from above.
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), styled) != null);
}
