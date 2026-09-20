const std = @import("std");

const Emulator = @import("Emulator.zig");
const escape = @import("escape.zig");
const grapheme = @import("grapheme.zig");
const width = @import("width.zig");

const View = @This();

gpa: std.mem.Allocator,
writer: *std.Io.Writer,
frames: [2]Frame,
front: u1,
columns: usize,
rows: usize,
pages: usize,
screen_top_line: usize,
cursor_line: usize,
cursor_visible: bool,
sink: Sink,
structural_change: bool,
force_reset: bool,
reset_epoch: u64,
preserve_scrollback: bool,

pub const Size = struct { columns: usize, rows: usize };

pub const Anchor = struct {
    id: usize,
    line: usize,

    fn eql(a: Anchor, b: Anchor) bool {
        return a.id == b.id and a.line == b.line;
    }
};

const Row = struct { offset: usize, len: usize, columns: usize, anchor: Anchor };

pub const Lines = struct {
    blob: std.ArrayList(u8),
    spans: std.ArrayList(Span),

    const Span = struct { offset: usize, len: usize, columns: usize };

    pub const empty: Lines = .{ .blob = .empty, .spans = .empty };

    pub fn deinit(self: *Lines, gpa: std.mem.Allocator) void {
        self.blob.deinit(gpa);
        self.spans.deinit(gpa);
    }

    pub fn clear(self: *Lines, gpa: std.mem.Allocator) void {
        self.blob.clearAndFree(gpa);
        self.spans.clearAndFree(gpa);
    }

    pub fn clearRetainingCapacity(self: *Lines) void {
        self.blob.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
    }

    pub fn count(self: *const Lines) usize {
        return self.spans.items.len;
    }

    fn append(self: *Lines, gpa: std.mem.Allocator, row: []const u8, columns: usize) !void {
        const offset = self.blob.items.len;
        try self.blob.appendSlice(gpa, row);
        errdefer self.blob.shrinkRetainingCapacity(offset);
        try self.spans.append(gpa, .{ .offset = offset, .len = row.len, .columns = columns });
    }

    fn bytes(self: *const Lines, index: usize) []const u8 {
        const span = self.spans.items[index];
        return self.blob.items[span.offset..][0..span.len];
    }
};

pub const Caret = struct { row: usize, column: usize };

pub const Sink = struct {
    frame: *Frame,
    columns: usize,
    rows_max: usize,
    offset: usize,
    columns_written: usize,
    has_text: bool,
    tail_joining: bool,
    link_open: bool,

    pub const url_bytes_max = 2048;

    const url_schemes = [_][]const u8{ "http://", "https://", "mailto:" };

    pub fn begin(self: *Sink) void {
        self.offset = self.frame.blob.writer.end;
        self.columns_written = 0;
        self.has_text = false;
        self.tail_joining = false;
        self.link_open = false;
    }

    pub fn text(self: *Sink, bytes: []const u8) !void {
        return self.textFitted(bytes, self.columns -| self.columns_written);
    }

    fn textFitted(self: *Sink, bytes: []const u8, columns_max: usize) !void {
        if (bytes.len == 0) return;
        try self.guard(bytes);
        const available = @min(columns_max, self.columns -| self.columns_written);
        const start = self.frame.blob.writer.end;
        self.columns_written += try width.writeFitted(&self.frame.blob.writer, bytes, available);
        self.trackTail(start);
    }

    pub fn spaces(self: *Sink, count: usize) !void {
        return self.repeat(" ", count);
    }

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

    pub fn sgr(self: *Sink, comptime sequence: []const u8) !void {
        comptime if (!validSgr(sequence))
            @compileError("trusted style must be one complete SGR sequence");
        try self.frame.blob.writer.writeAll(sequence);
    }

    pub fn linkSet(self: *Sink, url: []const u8) !void {
        if (!linkable(url)) return;
        const writer = &self.frame.blob.writer;
        try writer.writeAll(escape.link_set);
        try writer.writeAll(url);
        try writer.writeAll(escape.string_end);
        self.link_open = true;
    }

    pub fn linkReset(self: *Sink) !void {
        if (!self.link_open) return;
        self.link_open = false;
        try self.frame.blob.writer.writeAll(escape.link_reset);
    }

    pub fn linkable(url: []const u8) bool {
        if (url.len == 0 or url.len > url_bytes_max) return false;
        for (url) |byte| if (byte <= ' ' or byte >= 0x7f) return false;
        for (url_schemes) |scheme| {
            if (std.ascii.startsWithIgnoreCase(url, scheme)) return true;
        }
        return false;
    }

    pub fn end(self: *Sink, anchor: Anchor) void {
        std.debug.assert(self.columns_written <= self.columns);
        std.debug.assert(!self.link_open);
        const len = self.frame.blob.writer.end - self.offset;
        std.debug.assert(self.frame.rows.items.len < self.rows_max);
        if (self.frame.rows.items.len == self.rows_max) return;
        self.frame.rows.appendAssumeCapacity(.{
            .offset = self.offset,
            .len = len,
            .columns = self.columns_written,
            .anchor = anchor,
        });
    }

    pub fn composed(self: *const Sink) usize {
        return self.frame.rows.items.len;
    }

    pub fn capture(self: *const Sink, gpa: std.mem.Allocator, first: usize, lines: *Lines) !void {
        for (self.frame.rows.items[first..]) |row| {
            try lines.append(gpa, self.frame.bytes(row), row.columns);
        }
    }

    pub fn replay(self: *Sink, lines: *const Lines, index: usize) !void {
        std.debug.assert(!self.has_text);
        const span = lines.spans.items[index];
        std.debug.assert(span.columns <= self.columns);
        try self.frame.blob.writer.writeAll(lines.bytes(index));
        self.columns_written = span.columns;
        self.has_text = true;
        self.tail_joining = true;
    }

    pub fn setCaret(self: *Sink, column: usize) void {
        self.frame.caret = .{ .row = self.frame.rows.items.len, .column = column };
    }

    fn guard(self: *Sink, bytes: []const u8) !void {
        if (!self.has_text) return;
        if (!self.tail_joining and !grapheme.startsJoining(bytes)) return;
        try self.frame.blob.writer.writeAll("\u{200B}");
    }

    fn trackTail(self: *Sink, start: usize) void {
        const written = self.frame.blob.writer.buffered()[start..];
        if (written.len == 0) return;
        self.tail_joining = grapheme.endsJoining(written);
        self.has_text = true;
    }
};

const Frame = struct {
    blob: std.Io.Writer.Allocating,
    rows: std.ArrayList(Row),
    caret: ?Caret,
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

const Mode = enum {
    fresh,
    reset,
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
        .reset_epoch = 0,
        .preserve_scrollback = false,
    };
}

pub fn deinit(self: *View) void {
    for (&self.frames) |*frame| frame.deinit(self.gpa);
}

pub fn resetScreen(self: *View) void {
    self.force_reset = true;
}

pub fn resetEpoch(self: *const View) u64 {
    return self.reset_epoch;
}

pub fn invalidate(self: *View) void {
    self.resetScreen();
    self.cursor_visible = false;
}

pub fn preserveScrollback(self: *View) void {
    self.preserve_scrollback = true;
}

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
            back.top_line = prev.top_line;
            try self.paint(.incremental, back, .{ .line = prev.top_line });
        } else if (alignment.prev_index == 0 and
            !self.staleAbove(prev, back, alignment.back_index))
        {
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

pub fn plainText(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var index: usize = 0;
    while (index < bytes.len) {
        if (std.mem.startsWith(u8, bytes[index..], escape.link_set)) {
            const rest = bytes[index + escape.link_set.len ..];
            const end = std.mem.indexOf(u8, rest, escape.string_end) orelse rest.len;
            index = bytes.len - rest.len + end + escape.string_end.len;
            continue;
        }
        if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '[') {
            index += 2;
            while (index < bytes.len and (bytes[index] < 0x40 or bytes[index] > 0x7e)) index += 1;
            if (index < bytes.len) index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, bytes[index..], "\u{200B}")) {
            index += "\u{200B}".len;
            continue;
        }
        try out.append(gpa, bytes[index]);
        index += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn paintAligned(self: *View, prev: *const Frame, back: *Frame, delta: usize) !void {
    const scrolled = back.rows.items.len + delta > prev.rows.items.len;
    const aligned_top = prev.top_line + delta;
    if (delta > 0 and !scrolled) {
        const printed_top = @max(prev.top_line, self.screen_top_line);
        if (aligned_top > printed_top) {
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

fn paintDroppedPrefix(self: *View, prev: *const Frame, back: *Frame) !void {
    back.top_line = prev.top_line;
    const visible_start = self.screen_top_line -| back.top_line;
    const maybe_changed = firstChangeFrom(prev, back, .{
        .prev_start = 0,
        .back_start = visible_start,
    });
    if (maybe_changed) |changed| {
        if (changed >= back.rows.items.len) {
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
        anchor = options.changed;
        screen_line = back.top_line + anchor;
        if (!self.lineVisible(screen_line)) {
            try self.paint(.reset, back, .{});
            return;
        }
    }
    try self.paint(.incremental, back, .{ .anchor = anchor, .line = screen_line });
}

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
            self.reset_epoch += 1;
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

fn paintCaretOnly(self: *View, frame: *const Frame) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    try self.restoreCursor(frame);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

fn paintEmpty(self: *View, prev_empty: bool) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    if (!prev_empty) {
        try writer.writeAll(self.resetSequence());
        self.applyReset();
        self.reset_epoch += 1;
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

fn staleAbove(self: *const View, prev: *const Frame, back: *const Frame, count: usize) bool {
    const prev_rows = prev.rows.items;
    const back_rows = back.rows.items;
    var index: usize = 0;
    while (prev.top_line + index < self.screen_top_line) : (index += 1) {
        if (index >= prev_rows.len or count + index >= back_rows.len) return false;
        const prev_bytes = prev.bytes(prev_rows[index]);
        if (!std.mem.eql(u8, prev_bytes, back.bytes(back_rows[count + index]))) return true;
    }
    return false;
}

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

    const rewound = [_]Line{
        caretLine("P", .{ .id = 1000, .column = 1 }),
        line("status", 1001),
    };
    try harness.render(&rewound, .{ .columns = 20, .rows = 24 }, 8);
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
    const first = [_]Line{ line("a", 0), line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&first, .{ .columns = 10, .rows = 3 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "b", "c" });
    try harness.emulator.expectCaret(.{ .frame_len = 3, .row = 2, .column = 1 });

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
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2),
        line("r3", 3), line("r4", 4), line("r5", 5),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "r2", "r3", "r4", "r5" });
    const screen_top = harness.emulator.screen_top;

    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2) };
    try harness.render(&short, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    try std.testing.expectEqualStrings("r2", harness.emulator.document.items[0].items);
    try std.testing.expectEqualStrings("r3", harness.emulator.document.items[1].items);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) == null);

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
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3),
        line("r4", 4), line("r5", 5), line("r6", 6), line("r7", 7),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r4", "r5", "r6", "r7" });

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
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r4", 4),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectVisible(&.{ "r2", "r3", "r4" });

    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2) };
    try harness.render(&short, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2" });
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
    const first = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try harness.render(&first, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3" });

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

test "a shrink above the screen top keeps the tail on screen" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 20);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const streaming = [_]Line{
        line("old 0", 0),
        line("old 1", 1),
        line("old 2", 2),
        line("old 3", 3),
        line("old 4", 4),
        line("old 5", 5),
        line("old 6", 6),
        line("old 7", 7),
        line("reply 0", 100),
        line("reply 1", 101),
        line("reply 2", 102),
        caretLine("editor", .{ .id = 200, .column = 6 }),
        line("status", 201),
    };
    try harness.render(&streaming, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectScreen(&.{ "reply 1", "reply 2", "editor", "status" });

    const discarded = [_]Line{
        line("old 0", 0),
        line("old 1", 1),
        line("old 2", 2),
        line("old 3", 3),
        line("old 4", 4),
        line("old 5", 5),
        line("old 6", 6),
        line("old 7", 7),
        caretLine("editor", .{ .id = 200, .column = 6 }),
        line("status", 201),
    };
    try harness.render(&discarded, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectScreen(&.{ "old 6", "old 7", "editor", "status" });
    try harness.emulator.expectCaret(.{ .frame_len = 8, .row = 6, .column = 6 });
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
    try sink.text("gh");
    sink.end(.{ .id = 0, .line = 0 });
    sink.begin();
    try sink.text("z");
    sink.setCaret(1);
    sink.end(.{ .id = 1, .line = 0 });
    try harness.view.render();
    harness.emulator.rows = 4;
    try harness.emulator.feed(harness.out.written());
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
    try harness.emulator.expectVisible(&.{"\u{200B}�\u{200B}|"});
}

test "a replayed capture composes the rows of the composition it captured" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    var lines: View.Lines = .empty;
    defer lines.deinit(gpa);

    const sink = try harness.view.beginFrame(.{ .columns = 10, .rows = 4 }, 1);
    const first = sink.composed();
    sink.begin();
    try sink.sgr("\x1b[1m");
    try sink.text("bold");
    try sink.sgr("\x1b[0m");
    sink.end(.{ .id = 0, .line = 0 });
    sink.begin();
    try sink.text("你好");
    sink.end(.{ .id = 0, .line = 1 });
    try sink.capture(gpa, first, &lines);
    try harness.view.render();
    harness.emulator.rows = 4;
    try harness.emulator.feed(harness.out.written());
    harness.consumed = harness.out.written().len;
    try harness.emulator.expectVisible(&.{ "bold", "你好" });
    try std.testing.expectEqual(@as(usize, 2), lines.count());

    harness.last_from = harness.consumed;
    const replayed = try harness.view.beginFrame(.{ .columns = 10, .rows = 4 }, 1);
    for (0..lines.count()) |index| {
        replayed.begin();
        try replayed.replay(&lines, index);
        replayed.end(.{ .id = 0, .line = index });
    }
    try harness.view.render();
    try harness.emulator.feed(harness.out.written()[harness.consumed..]);
    harness.consumed = harness.out.written().len;
    try harness.emulator.expectVisible(&.{ "bold", "你好" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), "bold") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), "你好") == null);
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
    try harness.render(&none, .{ .columns = 5, .rows = 2 }, 2);
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.cursor_hide) == null);

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

    const moved = [_]Line{caretLine("ab", .{ .id = 0, .column = 1 })};
    try harness.render(&moved, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectCaret(.{ .frame_len = 1, .row = 0, .column = 1 });
    const last = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_reset) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_clear_below) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, "ab") == null);
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
    const first = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), caretLine("r3", .{ .id = 3, .column = 1 }),
    };
    try harness.render(&first, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "r2", "r3" });

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

    harness.view.invalidate();
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "hello", "world" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), escape.screen_reset) != null);
}

test "a screen reset drops the scrollback and keeps the cursor visible" {
    const gpa = std.testing.allocator;
    const harness = try makeHarness(gpa, 10);
    defer {
        harness.deinit();
        gpa.destroy(harness);
    }
    const tall = [_]Line{
        line("r0", 0),
        line("r1", 1),
        line("r2", 2),
        line("r3", 3),
        caretLine("P", .{ .id = 100, .column = 1 }),
        line("status", 101),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 2 }, 4);
    try harness.emulator.expectScreen(&.{ "P", "status" });
    try std.testing.expectEqual(@as(usize, 6), harness.emulator.document.items.len);
    try std.testing.expect(harness.emulator.cursor_visible);

    harness.view.resetScreen();
    const cleared = [_]Line{
        caretLine("P", .{ .id = 100, .column = 1 }),
        line("status", 101),
    };
    try harness.render(&cleared, .{ .columns = 10, .rows = 2 }, 4);
    try harness.emulator.expectScreen(&.{ "P", "status" });
    try std.testing.expectEqual(@as(usize, 0), harness.emulator.screen_top);
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.document.items.len);
    const last = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "r0") == null);
    try std.testing.expect(harness.emulator.cursor_visible);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.cursor_show) == null);
}

test "canonical text boundaries survive separate sink writes" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = View.init(gpa, &out.writer);
    defer view.deinit();

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
    sink.begin();
    try sink.text("model");
    try sink.spaces(1);
    try sink.text("(account)");
    try sink.repeat("─", 4);
    sink.end(.{ .id = 0, .line = 0 });
    const plain = sink.frame.bytes(sink.frame.rows.items[0]);
    try std.testing.expectEqualStrings("model (account)────", plain);
    try std.testing.expectEqual(sink.columns_written, width.ofText(plain));

    sink.begin();
    try sink.text("e");
    try sink.text("\u{0301}");
    try sink.text("👨\u{200D}");
    try sink.text("👩");
    sink.end(.{ .id = 1, .line = 0 });
    const joined = sink.frame.bytes(sink.frame.rows.items[1]);
    try std.testing.expectEqualStrings("e\u{200B}\u{0301}👨\u{200D}\u{200B}👩", joined);
    try std.testing.expectEqual(sink.columns_written, width.ofText(joined));

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

    const second = [_]Line{ line("a", 0), boldLine("BOLD", 1) };
    try harness.render(&second, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "BOLD" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), styled) != null);
}

test "the plain text of painted bytes holds the rows alone" {
    const gpa = std.testing.allocator;
    const bytes = escape.sync_set ++ "\x1b[1mbold\x1b[0m\r\n" ++
        escape.link_set ++ "https://example.com" ++ escape.string_end ++ "link" ++
        escape.link_reset ++ "\u{200B}!" ++ escape.sync_reset;
    const plain = try plainText(gpa, bytes);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("bold\r\nlink!", plain);
}
