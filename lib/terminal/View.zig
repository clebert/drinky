const std = @import("std");

const escape = @import("escape.zig");
const grapheme = @import("grapheme.zig");
const testing = @import("testing.zig");
const width = @import("width.zig");

const View = @This();

gpa: std.mem.Allocator,
writer: *std.Io.Writer,
frame: Frame,
printed: std.ArrayList(Printed),
dropped: Lines,
origin_line: usize,
frame_start: usize,
columns: usize,
rows: usize,
pages: usize,
screen_top_line: usize,
cursor_line: usize,
cursor_visible: bool,
sink: Sink,
size_changed: bool,
force_reset: bool,
reset_epoch: u64,
preserve_scrollback: bool,

pub const Size = struct { columns: usize, rows: usize };

const Anchor = struct {
    id: usize,
    line: usize,

    fn eql(a: Anchor, b: Anchor) bool {
        return a.id == b.id and a.line == b.line;
    }
};

const Row = struct { offset: usize, len: usize, columns: usize, anchor: Anchor, hash: u64 };

const Printed = struct {
    anchor: Anchor,
    hash: u64,

    fn matches(self: *const Printed, row: *const Row) bool {
        return self.anchor.eql(row.anchor) and self.hash == row.hash;
    }
};

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

    const url_bytes_max = 2048;

    const url_schemes = [_][]const u8{ "http://", "https://", "mailto:" };

    pub fn begin(self: *Sink) void {
        self.offset = self.frame.blob.writer.end;
        self.columns_written = 0;
        self.has_text = false;
        self.tail_joining = false;
        self.link_open = false;
    }

    pub fn text(self: *Sink, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.guard(bytes);
        const available = self.columns -| self.columns_written;
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
        const bytes = self.frame.blob.writer.buffered()[self.offset..][0..len];
        self.frame.rows.appendAssumeCapacity(.{
            .offset = self.offset,
            .len = len,
            .columns = self.columns_written,
            .anchor = anchor,
            .hash = std.hash.Wyhash.hash(0, bytes),
        });
    }

    pub fn composed(self: *const Sink) usize {
        return self.frame.rows.items.len;
    }

    pub fn capture(self: *const Sink, gpa: std.mem.Allocator, first: usize, lines: *Lines) !void {
        for (self.frame.rows.items[first..]) |row| {
            try lines.append(gpa, self.frame.bytes(&row), row.columns);
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
        try self.frame.blob.writer.writeAll(width.grapheme_boundary);
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

    fn bytes(self: *const Frame, row: *const Row) []const u8 {
        return self.blob.writer.buffered()[row.offset..][0..row.len];
    }
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) View {
    return .{
        .gpa = gpa,
        .writer = writer,
        .frame = .init(gpa),
        .printed = .empty,
        .dropped = .empty,
        .origin_line = 0,
        .frame_start = 0,
        .columns = 0,
        .rows = 0,
        .pages = 0,
        .screen_top_line = 0,
        .cursor_line = 0,
        .cursor_visible = false,
        .sink = undefined,
        .size_changed = false,
        .force_reset = false,
        .reset_epoch = 0,
        .preserve_scrollback = false,
    };
}

pub fn deinit(self: *View) void {
    self.frame.deinit(self.gpa);
    self.printed.deinit(self.gpa);
    self.dropped.deinit(self.gpa);
}

pub fn resetScreen(self: *View) void {
    self.force_reset = true;
}

pub fn resetEpoch(self: *const View) u64 {
    return self.reset_epoch;
}

pub fn preserveScrollback(self: *View) void {
    self.preserve_scrollback = true;
}

pub fn forget(self: *View) void {
    self.frame.reset();
    self.printed.clearRetainingCapacity();
    self.dropped.clearRetainingCapacity();
    self.origin_line = 0;
    self.frame_start = 0;
    self.columns = 0;
    self.rows = 0;
    self.pages = 0;
    self.screen_top_line = 0;
    self.cursor_line = 0;
    self.cursor_visible = false;
    self.size_changed = false;
    self.force_reset = false;
}

pub fn beginFrame(self: *View, size: Size, pages: usize) !*Sink {
    self.size_changed = self.columns != 0 and
        (self.columns != size.columns or self.pages != pages);
    if (size.rows < self.rows) try self.shrinkHeight(size.rows);
    self.columns = size.columns;
    self.rows = size.rows;
    self.pages = pages;

    const frame = &self.frame;
    frame.reset();
    const capacity = self.screenHeight() * @max(self.pages, 1);
    try frame.rows.ensureTotalCapacity(self.gpa, capacity);
    self.sink = .{
        .frame = frame,
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
    defer self.force_reset = false;
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    if (self.frame.rows.items.len == 0) {
        if (self.printed.items.len > 0) try self.writeReset();
    } else if (self.force_reset or self.size_changed) {
        try self.writeReset();
        try self.paintRows(.{});
    } else if (self.printed.items.len == 0) {
        self.origin_line = self.cursor_line;
        self.frame_start = 0;
        try self.paintRows(.{});
    } else {
        try self.paintChanges();
    }
    try self.restoreCursor();
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

pub fn parkCursor(self: *View) !void {
    const count = self.printed.items.len;
    if (count == 0) return;
    const screen_bottom = self.screen_top_line + self.screenHeight() - 1;
    try self.moveCursor(@min(self.origin_line + count - 1, screen_bottom));
    const writer = self.writer;
    try writer.writeAll("\r");
    if (!self.cursor_visible) {
        try writer.writeAll(escape.cursor_show);
        self.cursor_visible = true;
    }
    try writer.flush();
}

fn paintChanges(self: *View) !void {
    try self.reprintDropped();
    const rows = self.frame.rows.items;
    const printed = self.printed.items;
    const start = self.frameStart();
    var same: usize = 0;
    while (same < rows.len and start + same < printed.len and
        printed[start + same].matches(&rows[same])) : (same += 1)
    {}
    self.frame_start = start;
    const changed = start + same;
    if (same == rows.len and changed == printed.len) return;
    const removes_only = same == rows.len;
    if (self.origin_line + changed - @intFromBool(removes_only) < self.screen_top_line) {
        try self.writeReset();
        return self.paintRows(.{});
    }
    try self.paintRows(.{ .printed_index = changed, .row_index = same });
}

fn frameStart(self: *const View) usize {
    const rows = self.frame.rows.items;
    if (rows.len < self.sink.rows_max) return 0;
    const first = rows[0].anchor;
    const printed = self.printed.items;
    var index = printed.len;
    while (index > 0) {
        index -= 1;
        if (printed[index].anchor.eql(first)) return index;
    }
    return 0;
}

fn paintRows(self: *View, options: struct {
    printed_index: usize = 0,
    row_index: usize = 0,
}) !void {
    const writer = self.writer;
    const frame = &self.frame;
    const start = options.printed_index;
    var separated = start > 0 and start == self.printed.items.len;
    if (separated) {
        try self.moveCursor(self.origin_line + start - 1);
    } else if (start < self.printed.items.len) {
        try self.moveCursor(self.origin_line + start);
        try writer.writeAll("\r");
        try writer.writeAll(escape.screen_clear_below);
    }
    self.printed.shrinkRetainingCapacity(start);
    const rows = frame.rows.items[options.row_index..];
    if (rows.len == 0) try self.moveCursor(self.origin_line + start - 1);
    try self.printed.ensureUnusedCapacity(self.gpa, rows.len);
    for (rows) |*row| {
        if (separated) {
            try writer.writeAll("\r\n");
            self.advanceLine();
        }
        separated = true;
        try writer.writeAll(frame.bytes(row));
        self.printed.appendAssumeCapacity(.{ .anchor = row.anchor, .hash = row.hash });
    }
}

fn writeReset(self: *View) !void {
    if (self.preserve_scrollback) {
        try self.writer.writeAll(escape.screen_repaint);
        self.cursor_line = self.screen_top_line;
    } else {
        try self.writer.writeAll(escape.screen_reset);
        self.screen_top_line = 0;
        self.cursor_line = 0;
    }
    self.origin_line = self.cursor_line;
    self.frame_start = 0;
    self.printed.clearRetainingCapacity();
    self.dropped.clearRetainingCapacity();
    self.reset_epoch += 1;
}

fn shrinkHeight(self: *View, rows: usize) !void {
    const height = @max(rows, 1);
    self.screen_top_line = @max(self.screen_top_line, self.cursor_line -| (height - 1));
    const kept = self.screen_top_line + height - self.origin_line;
    if (kept >= self.printed.items.len) return;
    const frame = &self.frame;
    for (frame.rows.items[kept - self.frame_start ..]) |*row| {
        try self.dropped.append(self.gpa, frame.bytes(row), row.columns);
    }
}

fn reprintDropped(self: *View) !void {
    const count = self.dropped.count();
    if (count == 0) return;
    try self.moveCursor(self.origin_line + self.printed.items.len - count - 1);
    for (0..count) |index| {
        try self.writer.writeAll("\r\n");
        self.advanceLine();
        try self.writer.writeAll(self.dropped.bytes(index));
    }
    self.dropped.clearRetainingCapacity();
}

fn screenHeight(self: *const View) usize {
    return @max(self.rows, 1);
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

fn restoreCursor(self: *View) !void {
    const writer = self.writer;
    if (self.frame.caret) |caret| {
        const screen_line = self.origin_line + self.frame_start + caret.row;
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

test "a shrink to the tail with nothing scrolled off erases the rows above" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 20);
    defer harness.destroy();
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
    try std.testing.expect(!harness.lastResets());
}

const Harness = struct {
    gpa: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    view: View,
    emulator: testing.Emulator,
    consumed: usize,
    last_from: usize,

    fn create(gpa: std.mem.Allocator, columns: usize) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .out = .init(gpa),
            .view = undefined,
            .emulator = try .init(gpa, columns),
            .consumed = 0,
            .last_from = 0,
        };
        self.view = View.init(gpa, &self.out.writer);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.view.deinit();
        self.emulator.deinit();
        self.out.deinit();
        self.gpa.destroy(self);
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
    }

    fn lastBytes(self: *Harness) []const u8 {
        return self.out.written()[self.last_from..self.consumed];
    }

    fn lastResets(self: *Harness) bool {
        return std.mem.indexOf(u8, self.lastBytes(), escape.screen_reset) != null;
    }
};

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
    const harness = try Harness.create(gpa, 80);
    defer harness.destroy();
    const frame = [_]Line{ line("hello", 0), line("world", 1) };
    try harness.render(&frame, .{ .columns = 80, .rows = 24 }, 4);
    try harness.emulator.expectVisible(&.{ "hello", "world" });
    try std.testing.expect(!harness.emulator.cursor_visible);
}

test "a sliding-window append repaints incrementally and keeps the caret synced" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const first = [_]Line{ line("a", 0), line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&first, .{ .columns = 10, .rows = 3 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "b", "c" });
    try harness.emulator.expectCaret(&.{ .frame_len = 3, .row = 2, .column = 1 });

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
    try harness.emulator.expectCaret(&.{ .frame_len = 6, .row = 5, .column = 1 });
    try std.testing.expect(!harness.lastResets());
}

test "a backward slide below the capacity repaints the whole content" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2),
        line("r3", 3), line("r4", 4), line("r5", 5),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "r2", "r3", "r4", "r5" });

    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2) };
    try harness.render(&short, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "r1", "r2" });
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2" });
    try std.testing.expectEqual(@as(usize, 3), harness.emulator.document.items.len);
    try std.testing.expect(harness.lastResets());

    const grown = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r4", 4),
    };
    try harness.render(&grown, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "r3", "r4" });
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3", "r4" });
    try std.testing.expect(!harness.lastResets());
}

test "a row that appears above the screen repaints the frame with it" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
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
    try harness.emulator.expectVisible(&.{ "a", "b", "c", "d", "e" });
    try std.testing.expect(!harness.emulator.cursor_visible);
    try std.testing.expect(harness.lastResets());
}

test "a mixed backward jump resets" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const first = [_]Line{ line("a", 0), line("b", 1), line("c", 2), line("d", 3) };
    try harness.render(&first, .{ .columns = 10, .rows = 2 }, 3);
    try harness.emulator.expectScreen(&.{ "c", "d" });

    const mixed = [_]Line{ line("x", 10), line("c", 2), line("d", 3) };
    try harness.render(&mixed, .{ .columns = 10, .rows = 2 }, 3);
    try harness.emulator.expectScreen(&.{ "c", "d" });
    try std.testing.expect(harness.lastResets());
}

test "a one-row editor shrink preserves clipped session scrollback" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 20);
    defer harness.destroy();
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
    try harness.emulator.expectCaret(&.{ .frame_len = 5, .row = 3, .column = 4 });
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
    try std.testing.expect(!harness.lastResets());
}

test "repeated shrinks accumulate blank rows below" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
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
    try std.testing.expect(!harness.lastResets());

    const shorter = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2),
        line("r3", 3), line("r4", 4), line("r7", 7),
    };
    try harness.render(&shorter, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r4", "r7", "", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    try std.testing.expect(!harness.lastResets());

    const shortest = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r7", 7),
    };
    try harness.render(&shortest, .{ .columns = 10, .rows = 4 }, 8);
    try harness.emulator.expectScreen(&.{ "r7", "", "", "" });
    try std.testing.expectEqual(screen_top, harness.emulator.screen_top);
    try std.testing.expect(!harness.lastResets());
}

test "a backward slide within one page reprints from row zero" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const tall = [_]Line{
        line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3), line("r4", 4),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectVisible(&.{ "r2", "r3", "r4" });

    const short = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2) };
    try harness.render(&short, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2" });
    const last = harness.lastBytes();
    try std.testing.expect(!harness.lastResets());
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_clear_below) != null);
}

test "a change above the viewport resets" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const first = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try harness.render(&first, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3" });

    const second = [_]Line{ line("R0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try harness.render(&second, .{ .columns = 10, .rows = 2 }, 2);
    try harness.emulator.expectVisible(&.{ "R0", "r1", "r2", "r3" });
    try std.testing.expect(harness.lastResets());
}

test "a page-count change resets" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const frame = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 3);
    try harness.emulator.expectVisible(&.{ "a", "b" });
    try std.testing.expect(harness.lastResets());
}

test "a width resize resets" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const frame = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.render(&frame, .{ .columns = 8, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "b" });
    try std.testing.expect(harness.lastResets());
}

test "a height resize preserves scrollback and leaves blank rows below" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 20);
    defer harness.destroy();
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
    const harness = try Harness.create(gpa, 20);
    defer harness.destroy();
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
    try harness.emulator.expectCaret(&.{ .frame_len = 8, .row = 6, .column = 6 });
    try std.testing.expect(harness.lastResets());
}

test "a height shrink that drops the rows below the caret leaves no stale row after a growth" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 20);
    defer harness.destroy();
    const wrapped = [_]Line{
        line("r3", 3),
        line("r4", 4),
        caretLine("edit", .{ .id = 5, .column = 4 }),
        line("wrap", 6),
    };
    try harness.render(&wrapped, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectScreen(&.{ "r3", "r4", "edit", "wrap" });

    const unwrapped = [_]Line{
        line("r2", 2),
        line("r3", 3),
        line("r4", 4),
        caretLine("edit", .{ .id = 5, .column = 4 }),
    };
    try harness.render(&unwrapped, .{ .columns = 20, .rows = 2 }, 2);
    try harness.emulator.expectScreen(&.{ "r4", "edit" });
    try harness.emulator.expectCaret(&.{ .frame_len = 4, .row = 3, .column = 4 });

    try harness.render(&unwrapped, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectScreen(&.{ "r4", "edit", "", "" });
    try harness.emulator.expectVisible(&.{ "r2", "r3", "r4", "edit" });
    try std.testing.expectEqual(@as(usize, 4), harness.emulator.document.items.len);
}

test "a height shrink prints the rows it dropped again and keeps the scrollback" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const rows = [_]Line{
        line("r0", 0),
        line("r1", 1),
        caretLine("r2", .{ .id = 2, .column = 1 }),
        line("r3", 3),
        line("r4", 4),
        line("r5", 5),
    };
    try harness.render(rows[0..4], .{ .columns = 10, .rows = 4 }, 1);
    try harness.render(rows[2..6], .{ .columns = 10, .rows = 4 }, 1);

    try harness.render(rows[4..6], .{ .columns = 10, .rows = 2 }, 1);
    try std.testing.expect(!harness.lastResets());
    try harness.emulator.expectScreen(&.{ "r4", "r5" });
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3", "r4", "r5" });

    try harness.render(rows[5..6], .{ .columns = 10, .rows = 1 }, 1);
    try std.testing.expect(!harness.lastResets());
    try harness.emulator.expectScreen(&.{"r5"});
    try harness.emulator.expectVisible(&.{ "r0", "r1", "r2", "r3", "r4", "r5" });
}

test "a resize of both width and height repaints the frame once" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 20);
    defer harness.destroy();
    const frame = [_]Line{
        line("r0", 0),
        caretLine("edit", .{ .id = 1, .column = 4 }),
        line("wrap", 2),
        line("status", 3),
    };
    try harness.render(&frame, .{ .columns = 20, .rows = 4 }, 1);
    try harness.render(frame[2..], .{ .columns = 18, .rows = 2 }, 1);
    try std.testing.expect(harness.lastResets());
    try harness.render(frame[2..], .{ .columns = 18, .rows = 2 }, 1);
    try harness.emulator.expectScreen(&.{ "wrap", "status" });
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.document.items.len);
}

test "a height shrink to one row after a removal keeps the tail on the screen" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    try harness.render(&.{ line("a", 0), line("b", 1) }, .{ .columns = 10, .rows = 5 }, 1);
    try harness.render(&.{line("a", 0)}, .{ .columns = 10, .rows = 5 }, 1);
    try harness.render(&.{line("a", 0)}, .{ .columns = 10, .rows = 1 }, 1);
    try harness.emulator.expectScreen(&.{"a"});
    try std.testing.expect(!harness.lastResets());
}

test "a frame without a shared anchor replaces a frame on the screen without a reset" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const first = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&first, .{ .columns = 10, .rows = 4 }, 2);
    const second = [_]Line{ line("c", 100), line("d", 101) };
    try harness.render(&second, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "c", "d" });
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.document.items.len);
    try std.testing.expect(!harness.lastResets());
}

test "a full-width row places the caret at the pending-wrap margin" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 3);
    defer harness.destroy();
    const frame = [_]Line{caretLine("abc", .{ .id = 0, .column = 3 })};
    try harness.render(&frame, .{ .columns = 3, .rows = 3 }, 1);
    try harness.emulator.expectVisible(&.{"abc"});
    try harness.emulator.expectCaret(&.{ .frame_len = 1, .row = 0, .column = 2 });
}

test "an over-wide row clips at the margin and keeps the cursor synced" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 3);
    defer harness.destroy();
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
    harness.emulator.resize(4);
    try harness.emulator.feed(harness.out.written());
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.document.items.len);
    const top_row = harness.emulator.document.items[0].items;
    try std.testing.expect(std.mem.indexOf(u8, top_row, "abc") != null);
    try std.testing.expect(std.mem.indexOfAny(u8, top_row, "defgh") == null);
    try harness.emulator.expectCaret(&.{ .frame_len = 2, .row = 1, .column = 1 });
}

test "a replayed capture composes the rows of the composition it captured" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
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
    harness.emulator.resize(4);
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
    const harness = try Harness.create(gpa, 5);
    defer harness.destroy();
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
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const frame = [_]Line{
        line("body", 0),
        caretLine("prompt", .{ .id = 1, .column = 6 }),
        line("status", 2),
    };
    try harness.render(&frame, .{ .columns = 10, .rows = 24 }, 1);
    try harness.emulator.expectCaret(&.{ .frame_len = 3, .row = 1, .column = 6 });

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

test "parkCursor after a height shrink without a paint parks on the last row of the screen" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const frame = [_]Line{
        caretLine("r0", .{ .id = 0, .column = 1 }), line("r1", 1), line("r2", 2), line("r3", 3),
    };
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 1);
    harness.emulator.resize(2);
    _ = try harness.view.beginFrame(.{ .columns = 10, .rows = 2 }, 1);

    try harness.view.parkCursor();
    try harness.emulator.feed(harness.out.written()[harness.consumed..]);
    try harness.emulator.expectScreen(&.{ "r0", "r1" });
    try std.testing.expectEqual(@as(usize, 1), harness.emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), harness.emulator.cursor_column);
    try std.testing.expect(harness.emulator.cursor_visible);
}

test "a view forgets the rows of a height shrink without a paint" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const frame = [_]Line{
        caretLine("r0", .{ .id = 0, .column = 1 }), line("r1", 1), line("r2", 2), line("r3", 3),
    };
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 1);
    _ = try harness.view.beginFrame(.{ .columns = 10, .rows = 2 }, 1);
    harness.view.forget();

    const fresh: testing.Emulator = try .init(gpa, 10);
    harness.emulator.deinit();
    harness.emulator = fresh;
    harness.consumed = harness.out.written().len;
    const size: Size = .{ .columns = 10, .rows = 2 };
    try harness.render(&.{ line("x0", 10), line("x1", 11) }, size, 1);
    try harness.render(&.{ line("x0", 10), line("x2", 12) }, size, 1);
    try harness.emulator.expectVisible(&.{ "x0", "x2" });
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.document.items.len);
}

test "an empty frame wipes the region and hides the cursor" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const frame = [_]Line{caretLine("x", .{ .id = 0, .column = 1 })};
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try std.testing.expect(harness.emulator.cursor_visible);

    try harness.render(&.{}, .{ .columns = 10, .rows = 4 }, 2);
    try std.testing.expect(!harness.emulator.cursor_visible);
    try std.testing.expect(harness.lastResets());
    try harness.emulator.expectScreen(&.{""});

    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectScreen(&.{"x"});
    try harness.emulator.expectCaret(&.{ .frame_len = 1, .row = 0, .column = 1 });
}

test "an unchanged frame emits only caret motion" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const first = [_]Line{ caretLine("ab", .{ .id = 0, .column = 2 }), line("cd", 1) };
    try harness.render(&first, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectCaret(&.{ .frame_len = 2, .row = 0, .column = 2 });

    const moved = [_]Line{ caretLine("ab", .{ .id = 0, .column = 1 }), line("cd", 1) };
    try harness.render(&moved, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectCaret(&.{ .frame_len = 2, .row = 0, .column = 1 });
    const last = harness.lastBytes();
    try std.testing.expect(!harness.lastResets());
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_clear_below) == null);
    try std.testing.expect(std.mem.indexOf(u8, last, "ab") == null);
    try std.testing.expect(std.mem.indexOf(u8, last, "cd") == null);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.cursor_show) == null);
}

test "a top-trim with nothing scrolled off reprints from row zero" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const first = [_]Line{ line("a", 0), line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&first, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectCaret(&.{ .frame_len = 3, .row = 2, .column = 1 });

    const second = [_]Line{ line("b", 1), caretLine("c", .{ .id = 2, .column = 1 }) };
    try harness.render(&second, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectScreen(&.{ "b", "c" });
    try harness.emulator.expectCaret(&.{ .frame_len = 2, .row = 1, .column = 1 });
    try std.testing.expect(!harness.lastResets());

    const third = [_]Line{ line("b", 1), line("c", 2), caretLine("d", .{ .id = 3, .column = 1 }) };
    try harness.render(&third, .{ .columns = 10, .rows = 3 }, 1);
    try harness.emulator.expectScreen(&.{ "b", "c", "d" });
    try harness.emulator.expectCaret(&.{ .frame_len = 3, .row = 2, .column = 1 });
}

test "a frame below the capacity that loses its first row removes it from the scrollback" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
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
    try harness.emulator.expectVisible(&.{ "r1", "r2", "r3" });
    try std.testing.expectEqual(@as(usize, 3), harness.emulator.document.items.len);
    try harness.emulator.expectCaret(&.{ .frame_len = 3, .row = 2, .column = 1 });
    try std.testing.expect(harness.lastResets());
}

test "a screen reset repaints a frame whose content is unchanged" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const frame = [_]Line{ line("hello", 0), line("world", 1) };
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "hello", "world" });

    harness.view.resetScreen();
    try harness.render(&frame, .{ .columns = 10, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "hello", "world" });
    try std.testing.expect(harness.lastResets());
}

test "a screen reset drops the scrollback and keeps the cursor visible" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
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
    try std.testing.expect(harness.lastResets());
    try std.testing.expect(std.mem.indexOf(u8, last, "r0") == null);
    try std.testing.expect(harness.emulator.cursor_visible);
    try std.testing.expect(std.mem.indexOf(u8, last, escape.cursor_show) == null);
}

test "a view that preserves the scrollback resets the screen alone and paints from its top" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    harness.view.preserveScrollback();
    const tall = [_]Line{
        line("r0", 0),
        line("r1", 1),
        line("r2", 2),
        line("r3", 3),
        caretLine("P", .{ .id = 100, .column = 1 }),
        line("status", 101),
    };
    try harness.render(&tall, .{ .columns = 10, .rows = 2 }, 4);
    try std.testing.expectEqual(@as(usize, 4), harness.emulator.screen_top);

    harness.view.resetScreen();
    const repainted = [_]Line{
        caretLine("Q", .{ .id = 100, .column = 1 }),
        line("state", 101),
    };
    try harness.render(&repainted, .{ .columns = 10, .rows = 2 }, 4);
    const last = harness.lastBytes();
    try std.testing.expect(std.mem.indexOf(u8, last, escape.screen_repaint) != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\x1b[3J") == null);
    try std.testing.expectEqual(@as(usize, 4), harness.emulator.screen_top);
    try harness.emulator.expectScreen(&.{ "Q", "state" });
    for ([_][]const u8{ "r0", "r1", "r2", "r3" }, 0..) |row, index| {
        try std.testing.expectEqualStrings(row, harness.emulator.document.items[index].items);
    }
    try harness.emulator.expectCaret(&.{ .frame_len = 2, .row = 0, .column = 1 });
}

test "a view that preserves the scrollback paints a frame after an empty frame at its top" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    harness.view.preserveScrollback();
    const tall = [_]Line{ line("r0", 0), line("r1", 1), line("r2", 2), line("r3", 3) };
    try harness.render(&tall, .{ .columns = 10, .rows = 2 }, 2);
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.screen_top);

    try harness.render(&.{}, .{ .columns = 10, .rows = 2 }, 2);
    const prompt = [_]Line{
        caretLine("P", .{ .id = 100, .column = 1 }),
        line("status", 101),
    };
    try harness.render(&prompt, .{ .columns = 10, .rows = 2 }, 2);
    try std.testing.expectEqual(@as(usize, 2), harness.emulator.screen_top);
    try harness.emulator.expectScreen(&.{ "P", "status" });
    try std.testing.expectEqualStrings("r0", harness.emulator.document.items[0].items);
    try std.testing.expectEqualStrings("r1", harness.emulator.document.items[1].items);
    try harness.emulator.expectCaret(&.{ .frame_len = 2, .row = 0, .column = 1 });
}

test "a row that changes its anchor keeps the rows above it in the scrollback" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    try harness.render(&.{ line("a", 1), line("b", 2) }, .{ .columns = 10, .rows = 2 }, 1);
    try harness.render(&.{ line("a", 1), line("b", 3) }, .{ .columns = 10, .rows = 2 }, 1);
    try harness.render(&.{ line("b", 3), line("c", 4) }, .{ .columns = 10, .rows = 2 }, 1);
    try harness.emulator.expectVisible(&.{ "a", "b", "c" });
    try std.testing.expectEqual(@as(usize, 3), harness.emulator.document.items.len);
    try std.testing.expect(!harness.lastResets());
}

test "a first row whose anchor repeats in the scrollback aligns with its latest row" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    const size: Size = .{ .columns = 10, .rows = 2 };
    try harness.render(&.{ line("x", 7), line("a", 1) }, size, 1);
    try harness.render(&.{ line("a", 1), line("y", 7) }, size, 1);
    try harness.render(&.{ line("y", 7), line("c", 4) }, size, 1);
    try harness.emulator.expectVisible(&.{ "x", "a", "y", "c" });
    try std.testing.expect(!harness.lastResets());
}

test "a view that preserves the scrollback repaints a shrunk screen from its top" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 10);
    defer harness.destroy();
    harness.view.preserveScrollback();
    const page = [_]Line{
        line("r0", 0),
        line("r1", 1),
        caretLine("r2", .{ .id = 2, .column = 1 }),
        line("r3", 3),
    };
    try harness.render(&page, .{ .columns = 10, .rows = 4 }, 1);
    try harness.render(page[2..], .{ .columns = 10, .rows = 2 }, 1);
    try harness.emulator.expectScreen(&.{ "r2", "r3" });
    try harness.emulator.expectCaret(&.{ .frame_len = 2, .row = 0, .column = 1 });
}

test "canonical text boundaries survive separate sink writes" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 9);
    defer harness.destroy();

    const sink = try harness.view.beginFrame(.{ .columns = 9, .rows = 4 }, 1);
    sink.begin();
    try sink.text("\x1b");
    try sink.text("\u{FE0F}");
    try sink.text("👨\u{200D}");
    try sink.text("👩");
    try sink.spaces(2);
    try sink.repeat("x", 9);
    sink.end(.{ .id = 0, .line = 0 });
    sink.begin();
    try sink.spaces(1);
    try sink.text("\u{FE0F}");
    try sink.repeat("x", 9);
    sink.end(.{ .id = 1, .line = 0 });
    try harness.view.render();
    harness.emulator.resize(4);
    try harness.emulator.feed(harness.out.written());

    const rows = harness.emulator.document.items;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| try std.testing.expectEqual(@as(usize, 9), width.ofText(row.items));
    try std.testing.expect(std.mem.indexOf(u8, harness.out.written(), "\u{200D}👩") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.out.written(), "\x1b\u{FE0F}") == null);
}

test "a fragment boundary takes a guard only where the two fragments can fuse" {
    const gpa = std.testing.allocator;
    const harness = try Harness.create(gpa, 40);
    defer harness.destroy();

    const sink = try harness.view.beginFrame(.{ .columns = 40, .rows = 4 }, 1);
    sink.begin();
    try sink.text("model");
    try sink.spaces(1);
    try sink.text("(account)");
    try sink.repeat("─", 4);
    try sink.repeat("x", 40);
    sink.end(.{ .id = 0, .line = 0 });

    sink.begin();
    try sink.text("e");
    try sink.text("\u{0301}");
    try sink.text("👨\u{200D}");
    try sink.text("👩");
    try sink.repeat("x", 40);
    sink.end(.{ .id = 1, .line = 0 });

    sink.begin();
    try sink.text("👨\u{200D}");
    try sink.spaces(1);
    try sink.repeat("─", 2);
    try sink.repeat("x", 40);
    sink.end(.{ .id = 2, .line = 0 });
    try harness.view.render();
    harness.emulator.resize(4);
    try harness.emulator.feed(harness.out.written());

    const rows = harness.emulator.document.items;
    const expected = [_][]const u8{
        "model (account)────",
        "e\u{200B}\u{0301}👨\u{200D}\u{200B}👩",
        "👨\u{200D}\u{200B} ──",
    };
    try std.testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |start, row| {
        try std.testing.expect(std.mem.startsWith(u8, row.items, start));
        try std.testing.expectEqual(@as(usize, 40), width.ofText(row.items));
    }
}

test "a hyperlink frames its text and closes within its row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = View.init(gpa, &out.writer);
    defer view.deinit();
    var emulator = try testing.Emulator.init(gpa, 20);
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
    const harness = try Harness.create(gpa, 20);
    defer harness.destroy();
    const styled = "\x1b[1mBOLD\x1b[0m";
    const first = [_]Line{ line("a", 0), line("b", 1) };
    try harness.render(&first, .{ .columns = 20, .rows = 4 }, 2);

    const second = [_]Line{ line("a", 0), boldLine("BOLD", 1) };
    try harness.render(&second, .{ .columns = 20, .rows = 4 }, 2);
    try harness.emulator.expectVisible(&.{ "a", "BOLD" });
    try std.testing.expect(std.mem.indexOf(u8, harness.lastBytes(), styled) != null);
}

test "a frame sequence keeps the scrollback seamless, the tail on screen, and the caret right" {
    for (0..2000) |seed| {
        errdefer std.debug.print("The scenario with seed {d} failed.\n", .{seed});
        try runScenario(std.testing.allocator, seed);
    }
}

const scenario_rows_max = 5;
const scenario_pages_max = 3;

const Transcript = struct {
    blocks: [blocks_max]Block = undefined,
    count: usize = 0,
    id_next: usize = 0,

    const blocks_max = 48;

    const Block = struct { id: usize, lines: usize, version: usize };

    fn rowCount(self: *const Transcript) usize {
        var total: usize = 0;
        for (self.blocks[0..self.count]) |block| total += block.lines;
        return total;
    }

    fn blockStart(self: *const Transcript, index: usize) usize {
        var total: usize = 0;
        for (self.blocks[0..index]) |block| total += block.lines;
        return total;
    }

    fn row(self: *const Transcript, buffer: []u8, index: usize) struct { []const u8, Anchor } {
        var remaining = index;
        for (self.blocks[0..self.count]) |block| {
            if (remaining < block.lines) {
                const text = std.fmt.bufPrint(buffer, "{d}.{d}v{d}", .{
                    block.id,
                    remaining,
                    block.version,
                }) catch unreachable;
                return .{ text, .{ .id = block.id, .line = remaining } };
            }
            remaining -= block.lines;
        }
        unreachable;
    }

    fn change(self: *Transcript, random: std.Random) ?usize {
        switch (random.intRangeLessThan(u8, 0, 6)) {
            0, 1 => if (self.count < blocks_max) {
                self.blocks[self.count] = .{
                    .id = self.id_next,
                    .lines = random.intRangeAtMost(usize, 1, 3),
                    .version = 0,
                };
                self.count += 1;
                self.id_next += 1;
            },
            2 => if (self.count > 0) {
                self.count -= 1;
            },
            3 => if (self.count > 0) {
                const index = self.count - 1 - random.uintLessThan(usize, @min(self.count, 3));
                self.blocks[index].lines = random.intRangeAtMost(usize, 1, 4);
                self.blocks[index].version += 1;
                return self.blockStart(index);
            },
            4 => if (self.count > 0) {
                const index = random.uintLessThan(usize, self.count);
                self.blocks[index].version += 1;
                return self.blockStart(index);
            },
            5 => if (self.count > 1) {
                const index = random.uintLessThan(usize, self.count - 1);
                const start = self.blockStart(index);
                const blocks = self.blocks[0..self.count];
                std.mem.copyForwards(Block, blocks[index .. blocks.len - 1], blocks[index + 1 ..]);
                self.count -= 1;
                return start;
            },
            else => unreachable,
        }
        return null;
    }
};

fn runScenario(gpa: std.mem.Allocator, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    const harness = try Harness.create(gpa, 12);
    defer harness.destroy();
    var transcript: Transcript = .{};
    var size: Size = .{
        .columns = 12,
        .rows = random.intRangeAtMost(usize, 1, scenario_rows_max),
    };
    var pages = random.intRangeAtMost(usize, 1, scenario_pages_max);
    var lines: [scenario_rows_max * scenario_pages_max]Line = undefined;
    var buffers: [lines.len][16]u8 = undefined;
    for (0..random.intRangeAtMost(usize, 1, 16)) |_| {
        const window_before = transcript.rowCount() -| size.rows * pages;
        const length_before = documentLength(&harness.emulator);
        const action = random.intRangeLessThan(u8, 0, 10);
        var maybe_changed_row: ?usize = null;
        switch (action) {
            0 => size.rows = random.intRangeAtMost(usize, 1, scenario_rows_max),
            1 => size.columns = random.intRangeAtMost(usize, 10, 12),
            2 => pages = random.intRangeAtMost(usize, 1, scenario_pages_max),
            3 => harness.view.resetScreen(),
            else => maybe_changed_row = transcript.change(random),
        }
        const total = transcript.rowCount();
        const shown = @min(total, size.rows * pages);
        const window = total - shown;
        if (maybe_changed_row) |changed_row| {
            if (changed_row < @max(window, window_before)) harness.view.resetScreen();
        }
        const caret_row = random.uintLessThan(usize, shown + 1);
        for (lines[0..shown], buffers[0..shown], window..) |*item, *buffer, index| {
            const text, const anchor = transcript.row(buffer, index);
            item.* = .{ .bytes = text, .anchor = anchor };
            if (index - window == caret_row) item.caret = random.uintAtMost(usize, 3);
        }
        try harness.render(lines[0..shown], size, pages);
        try expectConsistent(harness, &transcript, lines[0..shown]);
        if (action == 0) try std.testing.expect(documentLength(&harness.emulator) >= length_before);
    }
}

fn documentLength(emulator: *const testing.Emulator) usize {
    const document = emulator.document.items;
    var length = document.len;
    while (length > 0 and document[length - 1].items.len == 0) length -= 1;
    return length;
}

fn expectConsistent(harness: *Harness, transcript: *const Transcript, shown: []const Line) !void {
    const emulator = &harness.emulator;
    const document = emulator.document.items;
    const length = documentLength(emulator);
    const total = transcript.rowCount();
    try std.testing.expect(length >= shown.len);
    try std.testing.expect(length <= total);
    for (document[0..length], total - length..) |actual, index| {
        var buffer: [16]u8 = undefined;
        const expected, _ = transcript.row(&buffer, index);
        try std.testing.expectEqualStrings(expected, actual.items);
    }
    const height = @max(emulator.rows, 1);
    if (length > 0) {
        try std.testing.expect(length - 1 >= emulator.screen_top);
        try std.testing.expect(length - 1 < emulator.screen_top + height);
    }
    for (shown, length - shown.len..) |item, row| {
        const column = item.caret orelse continue;
        const visible = row >= emulator.screen_top and row < emulator.screen_top + height;
        try std.testing.expectEqual(visible, emulator.cursor_visible);
        if (!visible) return;
        try std.testing.expectEqual(row, emulator.cursor_row);
        try std.testing.expectEqual(column, emulator.cursor_column);
        return;
    }
    try std.testing.expect(!emulator.cursor_visible);
}
