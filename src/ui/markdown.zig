//! Markdown rendering for transcript blocks and read-only pages. Measurement,
//! painting, and source mapping run one `walk` over the source with a comptime
//! emitter, so they break rows in exactly the same places. Nothing allocates:
//! every span is a source slice or a static literal that streams to the sink.

const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

/// Blanks to slice indents and marker-width continuations from. Its length caps
/// how far a nested list can push its body.
const blanks = " " ** 32;

const rule_cell = "─";

/// A horizontal rule draws at most this wide, however wide the terminal is.
const rule_columns = 80;

const rule_cells = rule_cell ** rule_columns;

/// One span's look: the element role a reasoning tint replaces, plus the
/// attributes that survive it. A span with no role of its own takes `text`, the
/// role of reply text. `url` makes the span a terminal hyperlink.
const Look = struct {
    role: ?role.Name = null,
    url: []const u8 = "",
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
};

const accent_look: Look = .{ .role = .accent };
const code_look: Look = .{ .role = .code };
const heading_look: Look = .{ .role = .heading };
const muted_look: Look = .{ .role = .muted };
const quote_look: Look = .{ .role = .muted, .italic = true };
const link_look: Look = .{ .role = .link, .underline = true };

/// Physical rows the markdown in `text` occupies at `columns`.
pub fn rows(text: []const u8, columns: usize) usize {
    var counter: Counter = .{};
    walk(Counter, &counter, text, @max(columns, 1)) catch unreachable;
    return counter.count;
}

pub const RowOptions = struct {
    columns: usize,
    row: usize,
};

pub const SourceOptions = struct {
    columns: usize,
    source_offset: usize,
};

/// Source logical-line offset associated with one rendered physical row.
pub fn sourceAtRow(text: []const u8, options: *const RowOptions) usize {
    var locator: SourceAtRow = .{ .target = options.row };
    walk(SourceAtRow, &locator, text, @max(options.columns, 1)) catch unreachable;
    return locator.result;
}

/// First rendered row associated with the logical line that contains a source offset.
pub fn rowAtSource(text: []const u8, options: *const SourceOptions) usize {
    var locator: RowAtSource = .{ .target = @min(options.source_offset, text.len) };
    walk(RowAtSource, &locator, text, @max(options.columns, 1)) catch unreachable;
    return locator.result;
}

/// Compose the markdown in `text` through `placement`. `tint` (set for
/// reasoning) replaces every span's role and italicizes the whole block. The
/// structure still reads while the color stays uniformly muted.
pub fn render(placement: *const paint.Placement, tint: ?role.Name, text: []const u8) !void {
    var painter: Painter = .{ .placement = placement, .tint = tint, .line = placement.base };
    try walk(Painter, &painter, text, @max(placement.columns, 1));
}

pub const WindowOptions = struct {
    tint: ?role.Name = null,
    rows_max: usize,
};

/// Compose a bounded row window after `placement.skip`.
pub fn renderWindow(
    placement: *const paint.Placement,
    text: []const u8,
    options: *const WindowOptions,
) !void {
    var painter: Painter = .{
        .placement = placement,
        .tint = options.tint,
        .line = placement.base,
        .line_end = placement.skip +| options.rows_max,
    };
    try walk(Painter, &painter, text, @max(placement.columns, 1));
}

/// Tallies rows for `rows`. It holds no sink, so nothing it does can fail.
const Counter = struct {
    count: usize = 0,

    fn source(_: *Counter, _: usize) void {}
    fn begin(_: *Counter) void {}
    fn span(_: *Counter, _: Look, _: []const u8) !void {}
    fn end(self: *Counter) void {
        self.count += 1;
    }
};

const SourceAtRow = struct {
    target: usize,
    source_offset: usize = 0,
    row: usize = 0,
    result: usize = 0,

    fn source(self: *SourceAtRow, source_offset: usize) void {
        self.source_offset = source_offset;
    }

    fn begin(_: *SourceAtRow) void {}
    fn span(_: *SourceAtRow, _: Look, _: []const u8) !void {}
    fn end(self: *SourceAtRow) void {
        if (self.row <= self.target) self.result = self.source_offset;
        self.row += 1;
    }
};

const RowAtSource = struct {
    target: usize,
    row: usize = 0,
    result: usize = 0,

    fn source(self: *RowAtSource, source_offset: usize) void {
        if (source_offset <= self.target) self.result = self.row;
    }

    fn begin(_: *RowAtSource) void {}
    fn span(_: *RowAtSource, _: Look, _: []const u8) !void {}
    fn end(self: *RowAtSource) void {
        self.row += 1;
    }
};

/// Paints rows for `render`. It drops rows in the clipped top the way
/// `paint.framedRow` does: it never opens the row, only counts past it.
const Painter = struct {
    placement: *const paint.Placement,
    tint: ?role.Name,
    line: usize,
    line_end: usize = std.math.maxInt(usize),
    hidden: bool = false,

    fn source(_: *Painter, _: usize) void {}

    fn begin(self: *Painter) void {
        self.hidden = self.line < self.placement.skip or self.line >= self.line_end;
        if (!self.hidden) self.placement.sink.begin();
    }

    fn span(self: *Painter, look: Look, bytes: []const u8) !void {
        if (self.hidden or bytes.len == 0) return;
        const sink = self.placement.sink;
        // A span with no element role of its own is reply text, which the `text`
        // role owns. That role keeps the terminal foreground, so a plain
        // paragraph stays free of every escape sequence.
        const name = self.tint orelse look.role orelse .text;
        const emphasized = look.bold;
        const emphasis_carries_underline = emphasized and name == .muted and look.underline;
        const italic = look.italic or self.tint != null;
        try role.apply(sink, name);
        if (emphasized) try attribute.emphasize(sink, name, look.underline);
        if (italic) try attribute.apply(sink, .italic);
        if (look.underline and !emphasis_carries_underline) {
            try attribute.apply(sink, .underline);
        }
        if (look.strike) try attribute.apply(sink, .strikethrough);
        // The link opens and closes inside this span, so it covers exactly the
        // text on this row and never leaks into the row under it.
        try sink.linkSet(look.url);
        try sink.text(bytes);
        try sink.linkReset();
        if (role.paints(name) or emphasized or italic or look.underline or look.strike) {
            try attribute.apply(sink, .reset);
        }
    }

    fn end(self: *Painter) void {
        defer self.line += 1;
        if (!self.hidden) self.placement.sink.end(.{ .id = self.placement.id, .line = self.line });
    }
};

const Fence = struct {
    marker: u8,
    length: usize,

    fn open(line: []const u8) ?Fence {
        if (line.len < 3) return null;
        const marker = line[0];
        if (marker != '`' and marker != '~') return null;
        const length = markerLength(line, marker);
        if (length < 3) return null;
        if (marker == '`' and std.mem.indexOfScalar(u8, line[length..], '`') != null) return null;
        return .{ .marker = marker, .length = length };
    }

    fn closes(self: Fence, line: []const u8) bool {
        if (line.len < self.length or line[0] != self.marker) return false;
        const length = markerLength(line, self.marker);
        return length >= self.length and isBlank(line[length..]);
    }

    fn markerLength(line: []const u8, marker: u8) usize {
        var length: usize = 0;
        while (length < line.len and line[length] == marker) length += 1;
        return length;
    }
};

/// Returns true when an odd number of backslashes immediately precedes `index`.
fn isEscaped(text: []const u8, index: usize) bool {
    var backslashes: usize = 0;
    while (backslashes < index and text[index - 1 - backslashes] == '\\') : (backslashes += 1) {}
    return backslashes % 2 == 1;
}

/// A pipe table's grid: the column count its header row sets, the display width
/// each column gets after the fit to the window, and the blanks that hold the
/// grid at the indentation of its source. Every row must open with a pipe, and
/// the alignment colons of the delimiter row parse but do not align.
const Table = struct {
    count: usize,
    widths: [count_max]usize,
    indent: []const u8,

    /// Columns a grid can hold. A wider header is no table at all.
    const count_max = 16;

    /// What `detect` reads: the header line, the source that follows it (the
    /// delimiter row first), the window, and the spaces the header indents by.
    const Options = struct {
        header: []const u8,
        tail: []const u8,
        columns: usize,
        indentation: usize,
    };

    /// The three glyphs one horizontal border row draws.
    const Border = struct { left: []const u8, joint: []const u8, right: []const u8 };

    const border_top: Border = .{ .left = "┌", .joint = "┬", .right = "┐" };
    const border_inner: Border = .{ .left = "├", .joint = "┼", .right = "┤" };
    const border_bottom: Border = .{ .left = "└", .joint = "┴", .right = "┘" };

    /// One row's cells: the outer pipes stripped and every cell trimmed. The
    /// measure pass and the paint share it, so their cells cannot diverge.
    const Cells = struct {
        rest: []const u8,
        done: bool = false,

        fn init(row: []const u8) Cells {
            var body = std.mem.trim(u8, row, " \t\r");
            if (body.len > 0 and body[0] == '|') body = body[1..];
            if (body.len > 0 and body[body.len - 1] == '|' and !isEscaped(body, body.len - 1)) {
                body = body[0 .. body.len - 1];
            }
            return .{ .rest = body };
        }

        fn next(self: *Cells) ?[]const u8 {
            if (self.done) return null;
            var search_from: usize = 0;
            while (std.mem.indexOfScalarPos(u8, self.rest, search_from, '|')) |pipe| {
                if (!isEscaped(self.rest, pipe)) {
                    defer self.rest = self.rest[pipe + 1 ..];
                    return std.mem.trim(u8, self.rest[0..pipe], " \t");
                }
                search_from = pipe + 1;
            }
            self.done = true;
            return std.mem.trim(u8, self.rest, " \t");
        }
    };

    /// One cell's wrap across the lines of its grid row, at the word-break
    /// policy of `Flow`. The inline scan and the span it left half-consumed
    /// carry from line to line, so each line consumes its own words alone and
    /// a long cell costs linear time. Every emitter runs the same code, so
    /// all of them break in the same places.
    fn CellFlow(comptime Emitter: type) type {
        return struct {
            emitter: *Emitter,
            scanner: InlineScanner,
            width: usize,
            /// The tail of the open span that the last line left unconsumed.
            rest: []const u8 = "",
            look: Look = .{},
            used: usize = 0,
            /// Display columns the open line streamed. The pad of the cell
            /// fills the rest of the column, so the grid stays one width.
            painted: usize = 0,
            /// Blank columns the open line owes (see `Flow.pending`).
            pending: usize = 0,
            pending_look: Look = .{},
            done: bool = false,

            /// Paint the next line of the cell: as many whole words as the
            /// column holds. The line ends where a word runs past the column,
            /// and `done` rises once the cell has no content left.
            fn paintLine(self: *@This()) !void {
                self.used = 0;
                self.painted = 0;
                self.pending = 0;
                // Bounded: every pass consumes bytes of the open span, pulls
                // the bounded scan forward, or ends the line.
                while (!self.done) {
                    if (self.rest.len == 0) {
                        const span = self.scanner.next() orelse {
                            self.done = true;
                            return;
                        };
                        self.rest = span.bytes;
                        self.look = span.look;
                        continue;
                    }
                    const room = self.width -| self.used;
                    const run = self.wordRun(self.rest);
                    // The next line takes the word whole, as the plain wrap
                    // does. A run of zero never opens on a blank, so no line
                    // of a cell opens on one either.
                    if (run == 0 and self.used > 0) return;
                    // A word too long for a line of its own breaks inside
                    // itself. A run of blanks against a full line truncates
                    // to nothing, which places nothing and still consumes it.
                    const cut = if (run > 0) self.rest[0..run] else self.rest;
                    const shown = terminal.width.truncate(cut, room);
                    std.debug.assert(run > 0 or shown.len > 0);
                    if (terminal.width.ofText(shown) > room) {
                        // A cluster wider than the room survives `truncate` as
                        // its one-column replacement. The cell cannot show a
                        // cluster wider than its whole column: it drops whole,
                        // and one `…` states the drop in its place.
                        if (self.used > 0) return;
                        try self.place(paint.ellipsis);
                        self.rest = self.rest[terminal.width.boundaryAfter(self.rest, 0)..];
                        // One mark covers the whole run: every following
                        // cluster that also outgrows the column drops behind
                        // the same mark, so the grid grows by one line per
                        // run, never by one line per glyph.
                        while (self.rest.len > 0) {
                            const cluster = terminal.width.boundaryAfter(self.rest, 0);
                            if (terminal.width.ofText(self.rest[0..cluster]) <= self.width) break;
                            self.rest = self.rest[cluster..];
                        }
                        continue;
                    }
                    try self.place(shown);
                    self.rest = self.rest[if (run > 0) run else shown.len..];
                }
            }

            /// Draw `shown` on the open line and charge every column it takes.
            /// The blanks it ends on wait as pending, the way `Flow.place`
            /// holds them, so no line of a cell ends on a painted blank.
            fn place(self: *@This(), shown: []const u8) !void {
                const body = terminal.width.rowText(shown);
                if (body.len > 0) {
                    try self.paintPending();
                    try self.stream(self.look, body);
                }
                const trailing = terminal.width.ofText(shown[body.len..]);
                if (trailing > 0) {
                    self.pending += trailing;
                    self.pending_look = self.look;
                }
                self.used += terminal.width.ofText(body) + trailing;
            }

            /// Paint the blanks the line owes, ahead of the content that pays
            /// them.
            fn paintPending(self: *@This()) !void {
                var left = self.pending;
                self.pending = 0;
                while (left > 0) {
                    const chunk = @min(left, blanks.len);
                    try self.stream(self.pending_look, blank(chunk));
                    left -= chunk;
                }
            }

            /// Emit `bytes` on the open line and measure it, so the pad fills
            /// exactly the columns the line does not take.
            fn stream(self: *@This(), look: Look, bytes: []const u8) !void {
                self.painted += terminal.width.ofText(bytes);
                try self.emitter.span(look, bytes);
            }

            /// Bytes of `text` the open line takes: as many whole words as the
            /// room left on it holds (see `Flow.wordRun`).
            fn wordRun(self: *const @This(), text: []const u8) usize {
                const room = self.width -| self.used;
                var bytes: usize = 0;
                var columns: usize = 0;
                while (bytes < text.len) {
                    const word = terminal.width.nextWord(text[bytes..], self.width);
                    std.debug.assert(word.bytes > 0);
                    if (columns + word.columns > room) break;
                    bytes += word.bytes;
                    columns = @min(columns + word.columns + word.blank_columns, room);
                }
                return bytes;
            }
        };
    }

    /// Tallies one cell's display columns for the measure pass.
    const Measure = struct {
        columns: usize = 0,

        fn write(self: *Measure, _: Look, bytes: []const u8) !void {
            self.columns += terminal.width.ofText(bytes);
        }
    };

    /// The table that opens at `options.header` when the first line after it is
    /// the delimiter row and the narrowest grid still fits the window. The
    /// widths come from a measure pass over the whole table before `fit`
    /// shrinks them. The decision depends only on the text and the width, so
    /// every emitter reaches the same grid.
    fn detect(options: *const Options) ?Table {
        if (options.header[0] != '|') return null;
        var lines = std.mem.splitScalar(u8, options.tail, '\n');
        const delimiter = lines.first();
        if (!isDelimiter(delimiter)) return null;
        const count = cellCount(options.header);
        if (count != cellCount(delimiter) or count > count_max) return null;
        // The grid keeps the indentation of its source, capped like any row
        // prefix, and fits into the columns that indentation leaves.
        const indent = terminal.width.truncate(
            blank(options.indentation),
            prefixRoom(options.columns),
        );
        const columns = options.columns -| terminal.width.ofText(indent);
        // The floor: every column one cell wide. Below it the table stays prose.
        if (1 + 4 * count > columns) return null;
        var table: Table = .{ .count = count, .widths = @splat(1), .indent = indent };
        table.measureRow(options.header);
        while (lines.next()) |line| {
            if (!isRow(line)) break;
            table.measureRow(line);
        }
        table.fit(columns);
        return table;
    }

    /// A line whose first byte after the indentation is a pipe.
    fn isRow(line: []const u8) bool {
        const body = line[leading(line)..];
        return body.len > 0 and body[0] == '|';
    }

    /// The `| --- | :-: |` row under a header: dashes with optional alignment
    /// colons in every cell.
    fn isDelimiter(line: []const u8) bool {
        if (!isRow(line)) return false;
        var cells = Cells.init(line);
        while (cells.next()) |cell| {
            var body = cell;
            if (body.len > 0 and body[0] == ':') body = body[1..];
            if (body.len > 0 and body[body.len - 1] == ':') body = body[0 .. body.len - 1];
            if (body.len == 0) return false;
            for (body) |byte| if (byte != '-') return false;
        }
        return true;
    }

    fn cellCount(row: []const u8) usize {
        var cells = Cells.init(row);
        var count: usize = 0;
        while (cells.next() != null) count += 1;
        return count;
    }

    /// Raise each column to the display width of its cell in `row`, with the
    /// inline markers already sliced away.
    fn measureRow(self: *Table, row: []const u8) void {
        var cells = Cells.init(row);
        for (self.widths[0..self.count]) |*width| {
            const cell = cells.next() orelse break;
            var measure: Measure = .{};
            inlines(Measure, &measure, .{}, cell) catch unreachable;
            width.* = @max(width.*, measure.columns);
        }
    }

    /// Shrink the columns until the grid fits `columns`. Every column above one
    /// cap gives its excess up, and the cells the cap leaves over go back from
    /// the last column down. This is where shrinking the widest column one cell
    /// at a time settles, and a search over the cap finds it in a bounded number
    /// of steps. A wide table costs the same as a narrow one, on a path that
    /// runs for every visible table on every frame.
    fn fit(self: *Table, columns: usize) void {
        const room = columns -| (1 + 3 * self.count);
        // The floor `detect` checked leaves one cell per column, so a cap of one
        // always fits and the search always ends on a usable grid.
        var low: usize = 1;
        var high: usize = @max(room, 1);
        while (low < high) {
            const cap = low + @divFloor(high - low + 1, 2);
            if (self.capped(cap) <= room) low = cap else high = cap - 1;
        }
        // The cap is the largest that fits, so fewer cells are left over than
        // there are columns above it. Every one of them lands.
        var leftover = room -| self.capped(low);
        var index = self.count;
        while (index > 0) {
            index -= 1;
            const width = &self.widths[index];
            const above = width.* > low;
            width.* = @min(width.*, low);
            if (above and leftover > 0) {
                width.* += 1;
                leftover -= 1;
            }
        }
    }

    /// Display columns the content takes with every column cut to `cap`.
    fn capped(self: *const Table, cap: usize) usize {
        var total: usize = 0;
        for (self.widths[0..self.count]) |width| total += @min(width, cap);
        return total;
    }

    /// One border row: a rule segment per column between the `border` glyphs.
    fn borderRow(
        self: *const Table,
        comptime Emitter: type,
        emitter: *Emitter,
        border: *const Border,
    ) !void {
        emitter.begin();
        try emitter.span(.{}, self.indent);
        try emitter.span(muted_look, border.left);
        for (self.widths[0..self.count], 0..) |width, index| {
            if (index > 0) try emitter.span(muted_look, border.joint);
            var remaining = width + 2;
            while (remaining > 0) {
                const chunk = @min(remaining, rule_columns);
                try emitter.span(muted_look, rule_cells[0 .. rule_cell.len * chunk]);
                remaining -= chunk;
            }
        }
        try emitter.span(muted_look, border.right);
        emitter.end();
    }

    /// One grid row: every cell under `look` wraps inside its column, and the
    /// row grows as tall as its tallest cell. Each line pads out to the column
    /// between pipe borders. Every cell carries its wrap state across the
    /// lines, so no line replays content an earlier line consumed and a long
    /// cell costs linear time. No allocation buffers a wrapped cell, and every
    /// emitter runs the same code, so the count and the paint cannot diverge.
    fn cellRow(
        self: *const Table,
        comptime Emitter: type,
        emitter: *Emitter,
        row: []const u8,
        look: Look,
    ) !void {
        var flows: [count_max]CellFlow(Emitter) = undefined;
        var cells = Cells.init(row);
        for (flows[0..self.count], self.widths[0..self.count]) |*flow, width| {
            flow.* = .{
                .emitter = emitter,
                .scanner = InlineScanner.init(look, cells.next() orelse "", .table),
                .width = width,
            };
        }
        var more = true;
        // Bounded: every line consumes words of at least one open cell, and
        // the first line paints even when every cell is empty.
        while (more) {
            more = false;
            emitter.begin();
            try emitter.span(.{}, self.indent);
            for (flows[0..self.count]) |*flow| {
                try emitter.span(muted_look, "│");
                try emitter.span(.{}, " ");
                try flow.paintLine();
                more = more or !flow.done;
                std.debug.assert(flow.painted <= flow.width);
                var remaining = flow.width -| flow.painted + 1;
                while (remaining > 0) {
                    const chunk = @min(remaining, blanks.len);
                    try emitter.span(.{}, blank(chunk));
                    remaining -= chunk;
                }
            }
            try emitter.span(muted_look, "│");
            emitter.end();
        }
    }
};

/// Emit `text` one physical row at a time. This function decides every row break
/// and the emitter merely follows, so the count and the paint cannot diverge.
fn walk(comptime Emitter: type, emitter: *Emitter, text: []const u8, columns: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var maybe_fence: ?Fence = null;
    while (lines.next()) |raw| {
        // A CRLF source ends every line with a carriage return. It terminates
        // the line and is no content, so a row that keeps it paints a
        // replacement glyph. The trim moves only the end, so the source offset
        // still points at the line.
        const line = std.mem.trimEnd(u8, raw, "\r");
        const source_offset = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
        emitter.source(source_offset);
        const indentation = leading(line);
        const rest = line[indentation..];
        const maybe_open_fence = if (indentation <= 3) Fence.open(rest) else null;
        if (maybe_fence) |fence| {
            if (indentation <= 3 and fence.closes(rest)) {
                maybe_fence = null;
                try plainRow(Emitter, emitter, columns, "", muted_look, line);
            } else {
                // Code keeps its alignment: indent and truncate, never re-wrap.
                try plainRow(Emitter, emitter, columns, blank(2), code_look, line);
            }
        } else if (maybe_open_fence) |fence| {
            maybe_fence = fence;
            try plainRow(Emitter, emitter, columns, "", muted_look, line);
        } else if (isBlank(rest)) {
            emitter.begin();
            emitter.end();
        } else if (isRule(rest)) {
            const cells = rule_cells[0 .. rule_cell.len * @min(columns, rule_columns)];
            try plainRow(Emitter, emitter, columns, "", muted_look, cells);
        } else if (Table.detect(&.{
            .header = rest,
            .tail = lines.rest(),
            .columns = columns,
            .indentation = indentation,
        })) |table| {
            // The header draws under a top border, every row the branch
            // consumes maps its own source line, and the last row closes the
            // grid. The delimiter row draws as the border below the header.
            try table.borderRow(Emitter, emitter, &Table.border_top);
            try table.cellRow(Emitter, emitter, rest, .{ .bold = true });
            const delimiter = lines.next().?;
            emitter.source(@intFromPtr(delimiter.ptr) - @intFromPtr(text.ptr));
            var more = Table.isRow(lines.peek() orelse "");
            const middle = if (more) &Table.border_inner else &Table.border_bottom;
            try table.borderRow(Emitter, emitter, middle);
            while (more) {
                const row = lines.next().?;
                emitter.source(@intFromPtr(row.ptr) - @intFromPtr(text.ptr));
                try table.cellRow(Emitter, emitter, row, .{});
                more = Table.isRow(lines.peek() orelse "");
                if (!more) try table.borderRow(Emitter, emitter, &Table.border_bottom);
            }
        } else if (headingLevel(rest)) |level| {
            // Every heading sheds its marker. The level changes the attributes:
            // the first underlines, the second stays bold, and deeper headings
            // keep the heading role alone.
            const body = std.mem.trimStart(u8, rest[level..], " ");
            var flow = Flow(Emitter).init(emitter, columns, .{});
            var look = heading_look;
            look.bold = level <= 2;
            look.underline = level == 1;
            try inlines(Flow(Emitter), &flow, look, body);
            try flow.finish();
            // Set a heading off from what follows, unless a blank already does.
            const parted = if (lines.peek()) |next| isBlank(next) else true;
            if (!parted) {
                emitter.begin();
                emitter.end();
            }
        } else if (rest[0] == '>') {
            // A quote sheds its markers and reads by its color alone. A border
            // glyph on every row rides into every copy of the text.
            var body = rest;
            while (body.len > 0 and body[0] == '>') {
                body = body[1..];
                if (body.len > 0 and body[0] == ' ') body = body[1..];
            }
            var flow = Flow(Emitter).init(emitter, columns, .{});
            try inlines(Flow(Emitter), &flow, quote_look, body);
            try flow.finish();
        } else if (listMarker(rest)) |marker| {
            // Sources nest a list two spaces a level. Pi indents four.
            const depth: usize = @min(@divFloor(leading(line), 2), 4);
            var flow = Flow(Emitter).init(emitter, columns, .{
                .indent = blank(depth * 4),
                .marker = marker.shown,
                .look = accent_look,
            });
            var body = rest[marker.source..];
            if (taskBox(body)) |box| {
                try flow.write(accent_look, box);
                body = body[box.len..];
            }
            try inlines(Flow(Emitter), &flow, .{}, body);
            try flow.finish();
        } else {
            // A paragraph keeps its own indentation. The walk strips only markers.
            var flow = Flow(Emitter).init(emitter, columns, .{});
            try inlines(Flow(Emitter), &flow, .{}, line);
            try flow.finish();
        }
    }
}

/// The prefix every physical row of one logical line carries: `indent` blank
/// columns, then `marker`. The marker draws on the first row alone. Blanks
/// replace it on the rows under it, so a wrapped list item stays aligned.
const Prefix = struct {
    indent: []const u8 = "",
    marker: []const u8 = "",
    look: Look = .{},
};

/// Streams one logical line's spans into physical rows: opens a row with the
/// prefix, fills the width left over, and reopens on the next row when a span
/// runs past it. The span keeps its style across the break.
fn Flow(comptime Emitter: type) type {
    return struct {
        emitter: *Emitter,
        /// The prefix as drawn, cut to `prefixRoom` up front. The columns the
        /// body budget gives up are columns the sink shows.
        prefix: Prefix,
        budget: usize,
        used: usize = 0,
        /// Blank columns the open row owes. The row measures them at once, and
        /// content later on the row paints them. A row that closes first drops
        /// them, so no copy of a row ends on a blank.
        pending: usize = 0,
        pending_look: Look = .{},
        /// Whether the open row still owes its prefix. A prefix decorates the cells
        /// behind it, so the row draws it with the first of those cells. A row that
        /// gets no cells draws it without its blanks (see `payPrefix`).
        prefix_owed: bool = false,
        open: bool = false,
        first: bool = true,

        /// How a row draws its prefix. A row that holds content keeps the prefix
        /// whole. A row that holds the prefix alone drops the blanks the prefix
        /// ends with, so no copy of the row ends on a blank.
        const Form = enum { whole, alone };

        fn init(emitter: *Emitter, columns: usize, prefix: Prefix) @This() {
            var shown = prefix;
            shown.marker = terminal.width.truncate(prefix.marker, prefixRoom(columns));
            const left = prefixRoom(columns) -| terminal.width.ofText(shown.marker);
            shown.indent = terminal.width.truncate(prefix.indent, left);
            // A prefix that still outgrows the window leaves no budget and
            // stalls the wrap. One column always carries the row forward.
            return .{
                .emitter = emitter,
                .prefix = shown,
                .budget = @max(columns -| prefixColumns(&shown), 1),
            };
        }

        /// Place `bytes` under `look` and continue on the next row when a word
        /// runs past the width. One row takes as many whole words as it holds and
        /// draws them in one span.
        ///
        /// A word that spans two looks, such as the `ld` of `**bo**ld`, breaks at
        /// that seam, because the row it opens is already painted.
        fn write(self: *@This(), look: Look, bytes: []const u8) !void {
            var rest = bytes;
            while (rest.len > 0) {
                try self.openRow();
                const room = self.budget -| self.used;
                const run = self.wordRun(rest);
                if (run == 0) {
                    // Give the word the next row whole, as the plain wrap does.
                    if (self.used > 0) {
                        try self.closeRow();
                        continue;
                    }
                    // A word too long for a row of its own breaks inside itself.
                    // So does a cluster wider than the whole row, which survives
                    // `truncate` as its one-column replacement. Against a room of
                    // one, `truncate` still yields a cluster, so the row advances.
                    const cut = terminal.width.truncate(rest, room);
                    std.debug.assert(cut.len > 0);
                    try self.place(look, cut);
                    rest = rest[cut.len..];
                    continue;
                }
                // The row shows its words whole and consumes the blanks behind
                // them too, even the ones past the margin that it leaves out.
                try self.place(look, terminal.width.truncate(rest[0..run], room));
                rest = rest[run..];
            }
        }

        /// Draw `shown` on the open row and charge every column it takes. The
        /// blanks it ends on wait: content later on the row paints them, and a row
        /// that closes first drops them. No copy of a row then ends on a blank,
        /// whatever look the break falls under. The blank columns count at once,
        /// so a later word cannot slip into the gap they hold.
        fn place(self: *@This(), look: Look, shown: []const u8) !void {
            const body = terminal.width.rowText(shown);
            if (body.len > 0) {
                try self.payPrefix(.whole);
                try self.paintPending();
                try self.emitter.span(look, body);
            }
            const trailing = terminal.width.ofText(shown[body.len..]);
            if (trailing > 0) {
                self.pending += trailing;
                self.pending_look = look;
            }
            self.used += terminal.width.ofText(body) + trailing;
        }

        /// Paint the blanks the row owes, ahead of the content that pays them.
        fn paintPending(self: *@This()) !void {
            var left = self.pending;
            self.pending = 0;
            while (left > 0) {
                const chunk = @min(left, blanks.len);
                try self.emitter.span(self.pending_look, blank(chunk));
                left -= chunk;
            }
        }

        /// Bytes of `text` one row takes: as many whole words as the room left on
        /// the row holds. Zero when the next word needs a row of its own. The
        /// blanks behind a word ride with it, so no row opens on a blank.
        fn wordRun(self: *const @This(), text: []const u8) usize {
            const room = self.budget -| self.used;
            var bytes: usize = 0;
            var columns: usize = 0;
            // A logical line carries no line break, so every word takes at least
            // one byte and the walk reaches the end of `text`.
            while (bytes < text.len) {
                const word = terminal.width.nextWord(text[bytes..], self.budget);
                std.debug.assert(word.bytes > 0);
                if (columns + word.columns > room) break;
                bytes += word.bytes;
                columns = @min(columns + word.columns + word.blank_columns, room);
            }
            return bytes;
        }

        /// Close the last row. A line with no content still occupies one.
        fn finish(self: *@This()) !void {
            try self.openRow();
            try self.closeRow();
        }

        fn openRow(self: *@This()) !void {
            if (self.open) return;
            self.emitter.begin();
            self.open = true;
            self.used = 0;
            self.prefix_owed = true;
        }

        /// Draw the prefix the open row owes, ahead of the cells that follow it.
        /// The `alone` form draws the prefix of a row that holds nothing else, so
        /// it drops the blanks the prefix ends with. An indent with no marker
        /// behind it then reaches no cell, and the row draws nothing.
        fn payPrefix(self: *@This(), form: Form) !void {
            if (!self.prefix_owed) return;
            self.prefix_owed = false;
            // The marker draws on the first row alone. Blanks replace it on the
            // rows under it, so a wrapped list item stays aligned.
            const marker = if (self.first)
                self.prefix.marker
            else
                blank(terminal.width.ofText(self.prefix.marker));
            const look: Look = if (self.first) self.prefix.look else .{};
            self.first = false;
            const shown = switch (form) {
                .whole => marker,
                .alone => terminal.width.rowText(marker),
            };
            // A whole prefix keeps the indent even where the marker is empty,
            // because the body budget already gave up those columns.
            if (form == .alone and shown.len == 0) return;
            try self.emitter.span(.{}, self.prefix.indent);
            try self.emitter.span(look, shown);
        }

        fn closeRow(self: *@This()) !void {
            // A row that closes with the prefix still owed holds nothing else, so
            // the prefix drops the blanks it ends with. The blanks the row owes
            // reach no cell either.
            try self.payPrefix(.alone);
            self.pending = 0;
            self.emitter.end();
            self.open = false;
        }
    };
}

/// Columns a row's prefix can take: never more than half of them, so the body it
/// pushes right keeps room the sink will actually show. Uncapped, a marker or
/// border as wide as a narrow window swallows the text behind it. The source
/// advances while the sink clips every byte of it.
fn prefixRoom(columns: usize) usize {
    return columns -| @max(@divFloor(columns, 2), 1);
}

fn prefixColumns(prefix: *const Prefix) usize {
    return terminal.width.ofText(prefix.indent) + terminal.width.ofText(prefix.marker);
}

/// One row that never wraps: `indent`, then `bytes` cut to the width left over,
/// with one `…` on the cut. Code keeps its alignment, so a code row cuts rather
/// than wraps: both a cut and a wrap break a copied line, and only the cut keeps
/// the alignment.
fn plainRow(
    comptime Emitter: type,
    emitter: *Emitter,
    columns: usize,
    indent: []const u8,
    look: Look,
    bytes: []const u8,
) !void {
    const shown = terminal.width.truncate(indent, prefixRoom(columns));
    const room = columns -| terminal.width.ofText(shown);
    // The prefix takes at most half of a row of one column or more, so content
    // always keeps a column and the mark of a cut always fits beside it.
    std.debug.assert(room > 0);
    const content = paint.cut(bytes, room);
    emitter.begin();
    // The indent decorates content. A row with no content drops it, so a copy of
    // an empty code row carries no blank.
    if (content.kept.len > 0) {
        try emitter.span(.{}, shown);
        try emitter.span(look, content.kept);
    }
    if (content.marked) try emitter.span(look, paint.ellipsis);
    emitter.end();
}

/// An inline run: where its content lies in the source, the look that content
/// takes, and where the scan continues after it. `nests` marks content that can
/// carry markers of its own. `url` is the target a link appends as text when the
/// terminal cannot make the label itself clickable. `code` marks a code span.
const Run = struct {
    look: Look,
    start: usize,
    end: usize,
    after: usize,
    nests: bool,
    url: []const u8 = "",
    code: bool = false,
};

/// One open run: what the scan restores when that run closes.
const Scope = struct {
    look: Look,
    end: usize,
    after: usize,
    url: []const u8,
    code: bool,
};

/// Levels of nested inline markers the scan follows. A deeper marker stays
/// literal, which bounds the scopes a marker can open.
const nesting_max = 4;

/// Inline markers, each longer form before the shorter one that prefixes it.
const marks = [_]struct { mark: []const u8, look: Look }{
    .{ .mark = "***", .look = .{ .bold = true, .italic = true } },
    .{ .mark = "___", .look = .{ .bold = true, .italic = true } },
    .{ .mark = "**", .look = .{ .bold = true } },
    .{ .mark = "__", .look = .{ .bold = true } },
    .{ .mark = "~~", .look = .{ .strike = true } },
    .{ .mark = "*", .look = .{ .italic = true } },
    .{ .mark = "_", .look = .{ .italic = true } },
};

/// Candidate closers one emphasis marker inspects before it gives up. A closer
/// that hides behind more of them leaves the marker literal, and the scan stays
/// linear in the length of the line.
const closers_max = 4;

/// A memoized forward scan for one closing byte. The scan visits openers in
/// source order, so the closer found for one still answers the next. A scan
/// that found nothing can never succeed later. Without the memo a line of
/// unmatched `[` rescans its tail once per bracket, and a long line costs
/// quadratic time every frame. Only a link needs this: a marker that closes on
/// the bytes it opens with runs out of openers as soon as one scan fails.
const Closer = struct {
    byte: u8,
    at: ?usize = null,
    spent: bool = false,

    fn find(self: *Closer, text: []const u8, from: usize) ?usize {
        if (self.spent) return null;
        if (self.at == null or self.at.? < from) {
            self.at = std.mem.indexOfScalarPos(u8, text, from, self.byte);
            self.spent = self.at == null;
        }
        return self.at;
    }
};

/// The two closers a `[label](url)` scan needs, memoized across one line.
const Link = struct { label: Closer = .{ .byte = ']' }, url: Closer = .{ .byte = ')' } };

/// A resumable scan over `text`'s inline runs that slices the markers away.
/// `next` yields one styled span at a time. A run that holds markers of its
/// own opens a scope, so `**_both_**` sheds both pairs. A marker whose closer
/// has not streamed in yet stays literal. `Table.CellFlow` pulls the spans one
/// line at a time, so a wrapped cell resumes where its last line ended.
const InlineScanner = struct {
    text: []const u8,
    base: Look,
    look: Look,
    context: Context,
    /// Scopes the open runs hold. A code scope can open at `nesting_max` and
    /// never nests further.
    stack: [nesting_max + 1]Scope = undefined,
    depth: usize = 0,
    link: Link = .{},
    start: usize = 0,
    index: usize = 0,
    done: bool = false,
    /// Spans one step settles ahead of `next`: at most a closing run, the
    /// content of a closed one, and the three parts of one URL trailer.
    queue: [5]Span = undefined,
    queue_len: usize = 0,
    queue_head: usize = 0,

    const Context = enum { block, table };
    const Span = struct { look: Look, bytes: []const u8 };

    fn init(base: Look, text: []const u8, context: Context) InlineScanner {
        return .{ .text = text, .base = base, .look = base, .context = context };
    }

    /// The next non-empty span, or null once the scan consumed `text`.
    fn next(self: *InlineScanner) ?Span {
        // Bounded: every queued span pops once, and every `step` advances the
        // bounded scan.
        while (true) {
            while (self.queue_head < self.queue_len) {
                const span = self.queue[self.queue_head];
                self.queue_head += 1;
                if (span.bytes.len > 0) return span;
            }
            if (self.done) return null;
            self.queue_head = 0;
            self.queue_len = 0;
            self.step();
        }
    }

    /// One step of the scan, which queues the spans it settles. Every step
    /// raises `index`, closes one scope, or finishes: a run opens after its
    /// own marker, a closed run resumes past its closer, and any other byte
    /// advances by one. The scan therefore reaches the end of `text` and
    /// stops there.
    fn step(self: *InlineScanner) void {
        const text = self.text;
        if (self.index >= text.len and self.depth == 0) {
            self.enqueue(self.look, text[self.start..]);
            self.done = true;
            return;
        }
        if (self.depth > 0 and self.index >= self.stack[self.depth - 1].end) {
            const scope = self.stack[self.depth - 1];
            // A closer is never stepped over: no doubled marker can straddle
            // one, so the scan lands on it exactly.
            std.debug.assert(self.index == scope.end);
            self.enqueue(self.look, text[self.start..self.index]);
            self.depth -= 1;
            self.look = if (self.depth > 0) self.stack[self.depth - 1].look else self.base;
            self.enqueueTrailer(scope.url);
            self.index = scope.after;
            self.start = self.index;
            return;
        }
        // A run must close inside the run that holds it. One that reaches past
        // it interleaves rather than nests, so its marker stays literal.
        const limit = if (self.depth > 0) self.stack[self.depth - 1].end else text.len;
        if (self.context == .table and
            self.index + 1 < limit and
            text[self.index] == '\\' and
            text[self.index + 1] == '|' and
            isEscaped(text, self.index + 1))
        {
            self.enqueue(self.look, text[self.start..self.index]);
            self.enqueue(self.look, text[self.index + 1 .. self.index + 2]);
            self.index += 2;
            self.start = self.index;
            return;
        }
        if (self.depth > 0 and self.stack[self.depth - 1].code) {
            const next_backslash = std.mem.indexOfScalarPos(
                u8,
                text[0..limit],
                self.index + 1,
                '\\',
            ) orelse limit;
            self.index = next_backslash;
            return;
        }
        if (runAt(text, self.index, &self.link)) |run| {
            if (run.after <= limit) {
                self.enqueue(self.look, text[self.start..self.index]);
                const inner = merged(self.look, run.look);
                // GFM unescapes a pipe in a code span only inside a table cell.
                // A code scope opens only when the span holds an escaped pipe.
                const has_pipe = self.context == .table and
                    run.code and
                    std.mem.indexOf(u8, text[run.start..run.end], "\\|") != null;
                const opens = (run.nests and self.depth < nesting_max) or has_pipe;
                if (opens) {
                    std.debug.assert(self.depth < self.stack.len);
                    self.stack[self.depth] = .{
                        .look = inner,
                        .end = run.end,
                        .after = run.after,
                        .url = run.url,
                        .code = run.code,
                    };
                    self.depth += 1;
                    self.look = inner;
                    self.index = run.start;
                } else {
                    self.enqueue(inner, text[run.start..run.end]);
                    self.enqueueTrailer(run.url);
                    self.index = run.after;
                }
                self.start = self.index;
                return;
            }
        }
        // A marker with no closer stays literal whole: a later byte of it must
        // not reopen as a shorter marker and split `**bold` into a stray
        // asterisk and an italic run mid-stream.
        self.index += literal(text, self.index);
    }

    fn enqueue(self: *InlineScanner, look: Look, bytes: []const u8) void {
        self.queue[self.queue_len] = .{ .look = look, .bytes = bytes };
        self.queue_len += 1;
    }

    /// Queue the URL a link shows as text, in the muted color of the context
    /// it closes into.
    fn enqueueTrailer(self: *InlineScanner, url: []const u8) void {
        if (url.len == 0) return;
        const shown = merged(self.look, muted_look);
        self.enqueue(shown, " (");
        self.enqueue(shown, url);
        self.enqueue(shown, ")");
    }
};

/// Place `text`'s inline runs into `sink` under `base`, one scanned span at a
/// time (see `InlineScanner`). The sink is a `Flow` for a wrapped block, or a
/// `Table.Measure` for one table cell.
fn inlines(comptime Sink: type, sink: *Sink, base: Look, text: []const u8) !void {
    const context: InlineScanner.Context = if (Sink == Table.Measure) .table else .block;
    var scanner = InlineScanner.init(base, text, context);
    while (scanner.next()) |span| try sink.write(span.look, span.bytes);
}

/// The inline run that opens at `index`, or null when none does.
fn runAt(text: []const u8, index: usize, link: *Link) ?Run {
    const rest = text[index..];
    if (rest[0] == '`') {
        const close = std.mem.indexOfScalarPos(u8, text, index + 1, '`') orelse return null;
        if (close == index + 1) return null;
        return .{
            .look = accent_look,
            .start = index + 1,
            .end = close,
            .after = close + 1,
            .nests = false,
            .code = true,
        };
    }
    if (rest[0] == '[') return linkAt(text, index, link);
    if (rest[0] == 'h' or rest[0] == 'H') return autolinkAt(text, index);
    for (marks) |entry| {
        if (!std.mem.startsWith(u8, rest, entry.mark)) continue;
        // A marker is a run of exactly its own length, so `***` opens the
        // bold-italic pair alone and neither `**` nor `*`. Both edges are one
        // byte each: a run of thousands must not cost its own length per byte.
        if (index > 0 and text[index - 1] == entry.mark[0]) continue;
        const open = index + entry.mark.len;
        if (open < text.len and text[open] == entry.mark[0]) continue;
        // An underscore inside a word is an identifier, not emphasis.
        if (entry.mark[0] == '_' and index > 0 and isWord(text[index - 1])) return null;
        // Emphasis opens tight, so spaced arithmetic stays literal.
        if (open >= text.len or isSpace(text[open])) continue;
        const close = closerAt(text, open, entry.mark) orelse continue;
        return .{
            .look = entry.look,
            .start = open,
            .end = close,
            .after = close + entry.mark.len,
            .nests = true,
        };
    }
    return null;
}

/// The closer of the emphasis that opened at `from`, or null when the line holds
/// none. A closer is a run of exactly the marker's own length that follows
/// content, so a run behind a blank opens the next emphasis instead of closing
/// this one. `*a **b** c*` then closes on the last marker, not inside the pair.
fn closerAt(text: []const u8, from: usize, mark: []const u8) ?usize {
    var at = from;
    for (0..closers_max) |_| {
        const close = std.mem.indexOfPos(u8, text, at, mark) orelse return null;
        const end = runEnd(text, close, mark[0]);
        at = end;
        if (end - close != mark.len) continue;
        if (isSpace(text[close - 1])) continue;
        // A closing underscore inside a word is an identifier.
        if (mark[0] == '_' and end < text.len and isWord(text[end])) continue;
        return close;
    }
    return null;
}

/// The end of the run of `byte` that starts at `at`.
fn runEnd(text: []const u8, at: usize, byte: u8) usize {
    var end = at;
    while (end < text.len and text[end] == byte) end += 1;
    return end;
}

/// Bytes the scan steps over when nothing opens at `index`: a whole marker, or
/// one byte. The marker keeps its bytes together, so the scan cannot re-read a
/// later byte of it as a shorter opener. It is always at least one byte, which
/// is what carries the scan forward.
fn literal(text: []const u8, index: usize) usize {
    for (marks) |entry| {
        if (entry.mark.len == 1) continue;
        if (std.mem.startsWith(u8, text[index..], entry.mark)) return entry.mark.len;
    }
    return 1;
}

/// The `[label](url)` link at `index`, or null when the shape is incomplete.
fn linkAt(text: []const u8, index: usize, link: *Link) ?Run {
    const close = link.label.find(text, index + 1) orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const end = link.url.find(text, close + 2) orelse return null;
    const label = text[index + 1 .. close];
    const url = text[close + 2 .. end];
    const look = linkLook(url);
    // A link with no label shows its own URL, and nothing follows it.
    if (label.len == 0) {
        return .{
            .look = look,
            .start = close + 2,
            .end = end,
            .after = end + 1,
            .nests = false,
        };
    }
    return .{
        .look = look,
        .start = index + 1,
        .end = close,
        .after = end + 1,
        .nests = true,
        // A clickable label carries the target already. Otherwise the URL
        // follows the label, unless the label is that URL.
        .url = if (look.url.len > 0 or std.mem.eql(u8, label, url)) "" else url,
    };
}

/// The bare `https://…` URL at `index`, or null when none starts there. The URL
/// runs to the first space and sheds the punctuation a sentence puts behind it.
/// The scheme reads case-insensitively, the same as the sink accepts it.
fn autolinkAt(text: []const u8, index: usize) ?Run {
    if (index > 0 and isWord(text[index - 1])) return null;
    const rest = text[index..];
    const scheme = for ([_][]const u8{ "https://", "http://" }) |candidate| {
        if (std.ascii.startsWithIgnoreCase(rest, candidate)) break candidate.len;
    } else return null;
    // The run covers the whole word, whatever bytes it holds. A byte the sink
    // refuses, such as a non-ASCII one, then costs the click alone. A run cut
    // at that byte instead sends a click to a target the row never showed.
    var span: usize = 0;
    while (span < rest.len and rest[span] > ' ') span += 1;
    const length = urlLength(rest[0..span]);
    // A scheme with no host behind it is not a URL.
    if (length <= scheme) return null;
    return .{
        .look = linkLook(rest[0..length]),
        .start = index,
        .end = index + length,
        .after = index + length,
        .nests = false,
    };
}

/// The punctuation that ends a sentence rather than a bare URL.
const url_trailing = ".,:;!?'\"*_~";

/// The length `url` keeps once the trailing sentence punctuation goes. A closing
/// parenthesis stays only while the URL opens one for it.
fn urlLength(url: []const u8) usize {
    var opened: usize = 0;
    var closed: usize = 0;
    for (url) |byte| {
        if (byte == '(') opened += 1;
        if (byte == ')') closed += 1;
    }
    var length = url.len;
    // Bounded: every step drops one byte from the end.
    while (length > 0) {
        const last = url[length - 1];
        if (last == ')') {
            if (closed <= opened) break;
            closed -= 1;
        } else if (std.mem.indexOfScalar(u8, url_trailing, last) == null) {
            break;
        }
        length -= 1;
    }
    return length;
}

/// The look a link takes. The label itself becomes clickable when the sink
/// accepts the target. Any other target, such as a relative path, shows as text.
fn linkLook(url: []const u8) Look {
    var look = link_look;
    if (terminal.View.Sink.linkable(url)) look.url = url;
    return look;
}

/// An element style over its context: the inner role and link target win, and
/// the attributes add up.
fn merged(base: Look, over: Look) Look {
    return .{
        .role = over.role orelse base.role,
        .url = if (over.url.len > 0) over.url else base.url,
        .bold = base.bold or over.bold,
        .italic = base.italic or over.italic,
        .underline = base.underline or over.underline,
        .strike = base.strike or over.strike,
    };
}

/// The list marker at the head of `rest`: the bytes it spans in the source and
/// what to draw. A bullet draws a normalized `- `. An ordered item draws the
/// source digits, so a list numbered from anything but one keeps its numbering.
const Marker = struct { source: usize, shown: []const u8 };

fn listMarker(rest: []const u8) ?Marker {
    if ((rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and
        (rest.len == 1 or rest[1] == ' '))
    {
        return .{ .source = @min(rest.len, 2), .shown = "- " };
    }
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits == 0 or digits == rest.len) return null;
    if (rest[digits] != '.' and rest[digits] != ')') return null;
    if (digits + 1 < rest.len and rest[digits + 1] != ' ') return null;
    const source = @min(rest.len, digits + 2);
    return .{ .source = source, .shown = rest[0..source] };
}

/// The `[ ] ` or `[x] ` checkbox that opens a task item's body.
fn taskBox(body: []const u8) ?[]const u8 {
    if (body.len < 3 or body[0] != '[' or body[2] != ']') return null;
    if (body[1] != ' ' and body[1] != 'x' and body[1] != 'X') return null;
    if (body.len > 3 and body[3] != ' ') return null;
    return body[0..@min(body.len, 4)];
}

/// The heading level `rest` opens with, or null when it opens none.
fn headingLevel(rest: []const u8) ?usize {
    var level: usize = 0;
    while (level < rest.len and rest[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < rest.len and rest[level] != ' ') return null;
    return level;
}

/// A `---`, `***`, or `___` rule: three or more of one mark and nothing else.
fn isRule(rest: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, rest, " \t\r");
    if (trimmed.len < 3) return false;
    const mark = trimmed[0];
    if (mark != '-' and mark != '*' and mark != '_') return false;
    for (trimmed) |byte| if (byte != mark) return false;
    return true;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

fn leading(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and line[index] == ' ') index += 1;
    return index;
}

fn blank(count: usize) []const u8 {
    return blanks[0..@min(count, blanks.len)];
}

// Every element of the supported subset. It ends on a heading no newline has
// followed yet: what a stream shows the instant the model writes one.
const sample =
    \\# Heading one
    \\Plain **bold**, *italic*, ~~struck~~, and `inline code` in a paragraph that
    \\runs past the narrow test widths.
    \\
    \\## Heading **two**
    \\### Heading three
    \\- first bullet
    \\  - nested bullet with enough words to wrap somewhere
    \\- [ ] a task
    \\3. numbered from three
    \\4. and on
    \\
    \\> a quoted line long enough to wrap over two rows
    \\
    \\---
    \\
    \\```zig
    \\const answer = 42;
    \\```
    \\
    \\| Name | Value |
    \\| :--- | ----: |
    \\| a | one |
    \\| b | **two** |
    \\
    \\A [labelled](https://example.com) link and a bare [x](x) one, plus a
    \\snake_case_name that is no emphasis.
    \\
    \\Nested **bold around _italic_** next to https://example.com/bare itself.
    \\
    \\#### heading with no trailing newline
;

// Markers a stream has not finished writing: the renderer must leave them
// literal rather than assert or miscount.
const partial =
    \\a dangling ** and a half-typed [link](
    \\```zig
    \\an unclosed fence runs to the end of the block
;

const literal_fences =
    \\````markdown
    \\```zig
    \\const nested = "**literal backticks**";
    \\```
    \\````
    \\~~~text
    \\```literal inside tildes
    \\~~~
    \\after **bold**
;

const indented_fences =
    \\   ```zig
    \\**three-space literal**
    \\   ```
    \\    ```zig
    \\after **four-space bold**
    \\    ```
;

// A table between paragraphs, with alignment colons and a styled cell.
const tables =
    \\Before.
    \\
    \\| Name | Value |
    \\| :--- | ----: |
    \\| a | one |
    \\| bb | **two** |
    \\
    \\After.
;

// Cells whose clusters take more than one column, indented under a list item.
// A narrow window shrinks a column below one cluster, which is where a naive
// wrap paints a column of the pad or counts more than it has.
const wide_tables =
    \\- item
    \\  | 你 | b |
    \\  | :-: | - |
    \\  | a你你 | bbbbbb |
    \\  | 😀 | 你 |
;

// Table shapes a stream leaves half-written: a header with no delimiter row
// yet, a delimiter whose cells do not match, and a head with no body rows.
const partial_tables =
    \\| a | b |
    \\
    \\| a | b |
    \\| --
    \\
    \\| a | b |
    \\| - | -
;

// Rows `text` paints into a fresh view. The paint drops its top `skip`. The
// caller owns the returned bytes. Fresh so the paint is a full reprint whose
// rows count.
fn painted(
    gpa: std.mem.Allocator,
    text: []const u8,
    columns: usize,
    tint: ?role.Name,
    skip: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 2000 }, 1);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = skip,
    };
    try render(&placement, tint, text);
    try view.render();
    return gpa.dupe(u8, out.written());
}

const PaintedWindowOptions = struct {
    columns: usize,
    skip: usize,
    rows_max: usize,
};

fn paintedWindow(
    gpa: std.mem.Allocator,
    text: []const u8,
    tint: ?role.Name,
    options: *const PaintedWindowOptions,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{
        .columns = options.columns,
        .rows = options.rows_max,
    }, 1);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = options.columns,
        .base = 0,
        .skip = options.skip,
    };
    try renderWindow(&placement, text, &.{
        .tint = tint,
        .rows_max = options.rows_max,
    });
    try view.render();
    return gpa.dupe(u8, out.written());
}

fn paintedRows(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\r\n") + 1;
}

fn frameBody(bytes: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, bytes, terminal.escape.sync_set));
    std.debug.assert(std.mem.endsWith(u8, bytes, terminal.escape.sync_reset));
    return bytes[terminal.escape.sync_set.len .. bytes.len - terminal.escape.sync_reset.len];
}

// Paint `text` and compare the visible rows, character for character.
fn expectPlainRows(
    gpa: std.mem.Allocator,
    text: []const u8,
    columns: usize,
    expected: []const []const u8,
) !void {
    const bytes = try painted(gpa, text, columns, null, 0);
    defer gpa.free(bytes);
    const body = try terminal.View.plainText(gpa, frameBody(bytes));
    defer gpa.free(body);
    var actual = std.mem.splitSequence(u8, body, "\r\n");
    for (expected) |row| try std.testing.expectEqualStrings(row, actual.next() orelse "");
    try std.testing.expect(actual.next() == null);
}

// The parity contract: what `rows` counts is exactly what `render` emits, at
// widths down to one column. At one column a list marker or a quote border
// alone already fills the row.
test "markdown renders exactly the rows it counts" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        sample,
        partial,
        literal_fences,
        indented_fences,
        tables,
        wide_tables,
        partial_tables,
        "",
        "\n\n",
    }) |text| {
        for ([_]usize{ 72, 40, 16, 10, 9, 3, 2, 1 }) |columns| {
            for ([_]?role.Name{ null, .muted }) |tint| {
                const bytes = try painted(gpa, text, columns, tint, 0);
                defer gpa.free(bytes);
                try std.testing.expectEqual(rows(text, columns), paintedRows(bytes));
            }
        }
    }
}

test "markdown windows emit exactly their bounded row slice" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 40, 1 }) |columns| {
        const total = rows(sample, columns);
        const full = try painted(gpa, sample, columns, null, 0);
        defer gpa.free(full);
        for ([_]usize{ 0, 1, @divFloor(total, 2) }) |skip| {
            if (skip >= total) continue;
            for ([_]usize{ 1, 3 }) |rows_max| {
                const bytes = try paintedWindow(gpa, sample, null, &.{
                    .columns = columns,
                    .skip = skip,
                    .rows_max = rows_max,
                });
                defer gpa.free(bytes);
                const expected_count = @min(rows_max, total - skip);
                try std.testing.expectEqual(expected_count, paintedRows(bytes));

                var expected = std.mem.splitSequence(u8, frameBody(full), "\r\n");
                for (0..skip) |_| _ = expected.next().?;
                var actual = std.mem.splitSequence(u8, frameBody(bytes), "\r\n");
                for (0..expected_count) |_| {
                    try std.testing.expectEqualStrings(expected.next().?, actual.next().?);
                }
                try std.testing.expect(actual.next() == null);
            }
        }
    }
}

test "rendered rows map back to their source logical line" {
    for ([_]usize{ 40, 7, 1 }) |columns| {
        const total = rows(sample, columns);
        // The first row of a logical line is a function of its source offset
        // alone, so the rows of one line share the lookup.
        var line_source: ?usize = null;
        var line_first: usize = 0;
        for (0..total) |row| {
            const source_offset = sourceAtRow(sample, &.{
                .columns = columns,
                .row = row,
            });
            if (line_source != source_offset) {
                line_source = source_offset;
                line_first = rowAtSource(sample, &.{
                    .columns = columns,
                    .source_offset = source_offset,
                });
                try std.testing.expectEqual(source_offset, sourceAtRow(sample, &.{
                    .columns = columns,
                    .row = line_first,
                }));
            }
            try std.testing.expect(line_first <= row);
        }
    }
}

test "fences close only with the same marker and enough characters" {
    const backticks = Fence.open("````markdown").?;
    try std.testing.expect(!backticks.closes("```"));
    try std.testing.expect(backticks.closes("````"));
    try std.testing.expect(backticks.closes("`````  "));
    try std.testing.expect(!backticks.closes("````tail"));
    try std.testing.expect(!backticks.closes("~~~~"));
    try std.testing.expect(Fence.open("```lang`") == null);

    const tildes = Fence.open("~~~text").?;
    try std.testing.expect(tildes.closes("~~~~"));
    try std.testing.expect(!tildes.closes("```"));
}

test "longer and alternate fences retain inner backticks as code" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, literal_fences, 72, null, 0);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "**literal backticks**") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "```literal inside tildes") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "after **bold**") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "after ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1mbold") != null);
}

test "fences accept at most three leading spaces" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, indented_fences, 72, null, 0);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "**three-space literal**") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "after **four-space bold**") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1mfour-space bold") != null);
}

// Each element carries its own look, and the markers that produced it are gone.
// Each expectation names a role and takes its bytes from the one role map.
test "markdown paints each element in its own role" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, sample, 72, null, 0);
    defer gpa.free(bytes);
    const code = comptime role.sequence(.code);
    const muted = comptime role.sequence(.muted);
    const accent = comptime role.sequence(.accent);
    const heading = comptime role.sequence(.heading);
    const link = comptime role.sequence(.link);

    // H1 is bold, underlined, and in the heading role. A deeper heading sheds
    // its marker too and keeps the heading role alone.
    const first = heading ++ "\x1b[1m\x1b[4mHeading one";
    try std.testing.expect(std.mem.indexOf(u8, bytes, first) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '#') == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, heading ++ "Heading three") != null);
    // A heading's emphasis is a span of its own, and the heading's own look
    // still carries it. The re-opened style marks the split.
    try std.testing.expect(std.mem.indexOf(u8, bytes, heading ++ "\x1b[1mtwo") != null);
    // Code keeps its two-space indent and its own role. The fence stays muted.
    try std.testing.expect(std.mem.indexOf(u8, bytes, code) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "  " ++ code) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "const answer = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, muted ++ "```zig") != null);
    // A bullet takes the accent, a quote the muted italic, and a rule its cells.
    try std.testing.expect(std.mem.indexOf(u8, bytes, accent ++ "- ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, muted ++ "\x1b[3ma quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "──") != null);
    // An ordered list keeps the number it started from, and a task its box. The
    // blank behind the box waits for the label, so it paints under its own span.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "3. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, accent ++ "[ ]") != null);
    // A link renders underlined in its own role and carries its own target.
    try std.testing.expect(std.mem.indexOf(u8, bytes, link ++ "\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "https://example.com") != null);
    // The render slices inline markers away, in a heading as much as a
    // paragraph, and a nested pair sheds both. A `_` inside a word is not
    // emphasis at all.
    const markers = [_][]const u8{ "**", "~~", "*italic*", "`inline code`", "[labelled]" };
    for (markers) |mark| try std.testing.expect(std.mem.indexOf(u8, bytes, mark) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1mbold") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1m\x1b[3mitalic") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "snake_case_name") != null);
}

// The grid draws each column at the width of its widest cell, pads every
// shorter cell out to it, bolds the header, and strips the inline markers and
// the source pipes away.
test "a table renders as a box grid with padded cells" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, tables, 40, &.{
        "Before.",
        "",
        "┌──────┬───────┐",
        "│ Name │ Value │",
        "├──────┼───────┤",
        "│ a    │ one   │",
        "│ bb   │ two   │",
        "└──────┴───────┘",
        "",
        "After.",
    });

    const bytes = try painted(gpa, tables, 40, null, 0);
    defer gpa.free(bytes);
    // The header row is bold and the borders take the muted role.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1mName") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        comptime role.sequence(.muted) ++ "┌",
    ) != null);
}

// An escaped pipe inside a cell does not split the cell. The renderer paints
// the escaped pipe as a literal pipe character.
test "a table preserves an escaped pipe in a cell" {
    const gpa = std.testing.allocator;
    const text =
        \\| Command | Description |
        \\| :--- | :--- |
        \\| `cat \| grep` | filter |
        \\| a \| b | plain text |
        \\| `\|` | lone pipe |
        \\| **_~~*`cat \| grep`*~~_** | deep |
    ;
    try expectPlainRows(gpa, text, 40, &.{
        "┌────────────┬─────────────┐",
        "│ Command    │ Description │",
        "├────────────┼─────────────┤",
        "│ cat | grep │ filter      │",
        "│ a | b      │ plain text  │",
        "│ |          │ lone pipe   │",
        "│ cat | grep │ deep        │",
        "└────────────┴─────────────┘",
    });
}

// CommonMark keeps a code span literal outside tables.
test "a code span outside a table keeps backslash before pipe" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "Use `cat \\| grep` here.", 40, &.{
        "Use cat \\| grep here.",
    });
}

// A cell wider than the window cannot widen the grid past it: the widest
// column gives up cells until the grid fits, and its content wraps inside the
// column. The grid row grows as tall as its tallest cell, and the pad fills
// the shorter cells beside it.
test "a table wraps a long cell and grows its grid row" {
    const gpa = std.testing.allocator;
    const text =
        \\| a | b |
        \\| - | - |
        \\| short | this cell is much longer than the window |
    ;
    try expectPlainRows(gpa, text, 30, &.{
        "┌───────┬────────────────────┐",
        "│ a     │ b                  │",
        "├───────┼────────────────────┤",
        "│ short │ this cell is much  │",
        "│       │ longer than the    │",
        "│       │ window             │",
        "└───────┴────────────────────┘",
    });
}

// A wide cluster that straddles the column's edge moves to the next line
// whole, so no line of a cell paints a broken glyph and no content is lost.
test "a wide glyph in a table cell wraps whole" {
    const gpa = std.testing.allocator;
    const text =
        \\| a | b |
        \\| - | - |
        \\| x你x | y |
    ;
    try expectPlainRows(gpa, text, 11, &.{
        "┌─────┬───┐",
        "│ a   │ b │",
        "├─────┼───┤",
        "│ x你 │ y │",
        "│ x   │   │",
        "└─────┴───┘",
    });
}

// A cluster wider than the whole column cannot show on any line. `truncate`
// keeps such a cluster as a one-column replacement, which a cell must not
// count as one column and must not draw. It drops whole, and one `…` states
// the drop in its place.
test "a cluster wider than its column drops from the cell" {
    const gpa = std.testing.allocator;
    const text =
        \\| 你 | b |
        \\| - | - |
        \\| c | d |
    ;
    try expectPlainRows(gpa, text, 9, &.{
        "┌───┬───┐",
        "│ … │ b │",
        "├───┼───┤",
        "│ c │ d │",
        "└───┴───┘",
    });
}

// A run of clusters wider than the whole column drops behind one mark: a
// second mark would state nothing new, and the grid must not grow by one line
// per glyph it cannot show. A cluster the column can show still wraps onto a
// line of its own behind the run.
test "one mark covers a whole run of dropped clusters" {
    const gpa = std.testing.allocator;
    const text = "| 你你你 | b |\n| - | - |\n| 你你a | d |";
    try expectPlainRows(gpa, text, 9, &.{
        "┌───┬───┐",
        "│ … │ b │",
        "├───┼───┤",
        "│ … │ d │",
        "│ a │   │",
        "└───┴───┘",
    });
}

// A styled span can fill the line exactly while the next span opens on a
// blank. The blank consumes against the full line and paints nothing, so the
// wrap advances to the word behind it instead of tripping on the blank.
test "a blank behind a full cell line starts no line of its own" {
    const gpa = std.testing.allocator;
    const text = "| a | b |\n| - | - |\n| **a** b | c |";
    try expectPlainRows(gpa, text, 9, &.{
        "┌───┬───┐",
        "│ a │ b │",
        "├───┼───┤",
        "│ a │ c │",
        "│ b │   │",
        "└───┴───┘",
    });
}

// Adversarial: a wrapped cell once replayed its whole content for every line
// it painted, so a long cell cost quadratic time on every frame. The scan
// carries its state from line to line, and each line consumes its own words
// alone. A replay turns this test from milliseconds to minutes.
test "a huge table cell wraps in linear time" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "| a |\n| - |\n| ");
    for (0..40_000) |_| try text.appendSlice(gpa, "word ");
    try text.appendSlice(gpa, "|");
    // Three words to a line in a column 16 cells wide, and the last word
    // alone on the final line: 13334 lines between three border rows and one
    // header row.
    try std.testing.expectEqual(@as(usize, 13_338), rows(text.items, 20));

    // One unbroken token: the word scan stops at the edge of the column, so a
    // giant token also costs each line only the line, not its own length.
    text.clearRetainingCapacity();
    try text.appendSlice(gpa, "| a |\n| - |\n| ");
    try text.appendNTimes(gpa, 'a', 100_000);
    try text.appendSlice(gpa, " |");
    try std.testing.expectEqual(@as(usize, 6_254), rows(text.items, 20));
}

// A cell can hold several styled spans, and one of them can fill the column
// before the next arrives. A word that spans two looks breaks at that seam,
// the way `Flow` breaks a row, so the later span continues on the next line.
test "a cell wraps at a look seam when the column fills" {
    const gpa = std.testing.allocator;
    const text =
        \\| a | b |
        \\| - | - |
        \\| **ab**c | y |
    ;
    try expectPlainRows(gpa, text, 10, &.{
        "┌────┬───┐",
        "│ a  │ b │",
        "├────┼───┤",
        "│ ab │ y │",
        "│ c  │   │",
        "└────┴───┘",
    });
}

// A code row keeps its alignment, so it cuts and marks the cut. The indent of a
// fenced row leaves the mark its column at every width.
test "a narrow code row marks its cut" {
    const gpa = std.testing.allocator;
    const text =
        \\```zig
        \\const a = 1;
        \\```
    ;
    try expectPlainRows(gpa, text, 6, &.{ "```zig", "  con…", "```" });
    // A row too narrow for the indent and one character drops both and states
    // the cut. No row of a code block ever paints as a blank row.
    try expectPlainRows(gpa, text, 3, &.{ "``…", "…", "```" });
    try expectPlainRows(gpa, text, 1, &.{ "…", "…", "…" });

    // A cluster wider than the room of the row would take the cell of the mark,
    // so the row drops the cluster and keeps the mark.
    const wide =
        \\```zig
        \\你x = 1;
        \\```
    ;
    try expectPlainRows(gpa, wide, 4, &.{ "```…", "…", "```" });
}

// Every row of one grid draws to the same width. A cell that wraps gives the
// columns each of its lines does not fill back to the pad, so the right border
// lines up on every line of the grid row.
test "a table draws every grid row to one width" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "| a你你 | bbbbbb |\n| - | - |\n| c | d |", 16, &.{
        "┌──────┬───────┐",
        "│ a你  │ bbbbb │",
        "│ 你   │ b     │",
        "├──────┼───────┤",
        "│ c    │ d     │",
        "└──────┴───────┘",
    });

    // The look of the row replays on every line of it, so the second line of a
    // wrapped header cell stays bold.
    const wrapped = try painted(gpa, "| a你你 | bbbbbb |\n| - | - |\n| c | d |", 16, null, 0);
    defer gpa.free(wrapped);
    try std.testing.expect(std.mem.indexOf(u8, wrapped, "\x1b[1m你") != null);

    for ([_][]const u8{ tables, wide_tables, partial_tables }) |text| {
        for ([_]usize{ 72, 40, 24, 16, 13, 11, 10, 9 }) |columns| {
            const bytes = try painted(gpa, text, columns, null, 0);
            defer gpa.free(bytes);
            const body = try terminal.View.plainText(gpa, frameBody(bytes));
            defer gpa.free(body);
            var width: ?usize = null;
            var painted_rows = std.mem.splitSequence(u8, body, "\r\n");
            while (painted_rows.next()) |row| {
                const grid = std.mem.trimStart(u8, row, " ");
                // A top border opens a grid of its own width.
                if (std.mem.startsWith(u8, grid, "┌")) width = null;
                for ([_][]const u8{ "┌", "│", "├", "└" }) |glyph| {
                    if (!std.mem.startsWith(u8, grid, glyph)) continue;
                    const row_width = terminal.width.ofText(row);
                    try std.testing.expect(row_width <= columns);
                    if (width) |first| try std.testing.expectEqual(first, row_width);
                    width = row_width;
                }
            }
        }
    }
}

// A grid holds the indentation of its source, the way a paragraph does, so a
// table under a list item lines up with the item text.
test "a table keeps the indentation of its source" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "  | a | b |\n  | - | - |\n  | c | d |", 12, &.{
        "  ┌───┬───┐",
        "  │ a │ b │",
        "  ├───┼───┤",
        "  │ c │ d │",
        "  └───┴───┘",
    });
    // The indentation the grid takes is width the columns no longer give it.
    const bytes = try painted(gpa, "  | a | b |\n  | - | - |\n  | c | d |", 10, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "┌") == null);
}

// Below one cell per column plus its borders, a grid cannot draw: the table
// falls back to the wrapped paragraph text it was before.
test "a table below its narrowest grid stays prose" {
    const gpa = std.testing.allocator;
    const text = "| a | b |\n| - | - |\n| c | d |";
    const bytes = try painted(gpa, text, 8, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "┌") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '|') != null);
}

// Mid-stream, a header without its delimiter row is still prose. A head with
// no body rows yet closes right under the header, with no inner border.
test "a table appears only when its delimiter row is complete" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "| a | b |", "| a | b |\n| --" }) |text| {
        const bytes = try painted(gpa, text, 40, null, 0);
        defer gpa.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "┌") == null);
    }
    const bytes = try painted(gpa, "| a | b |\n| - | -", 40, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "├") == null);
}

// The policy the cap search stands for: take one cell from the widest column,
// the lowest index first, until the grid fits. The search must land where that
// loop lands, at every shape a window and a measure pass can produce.
test "the column fit matches a cell-by-cell shrink" {
    var prng = std.Random.DefaultPrng.init(0x7ab1e5);
    const random = prng.random();
    for (0..2000) |_| {
        const count = random.intRangeAtMost(usize, 1, Table.count_max);
        var table: Table = .{ .count = count, .widths = @splat(1), .indent = "" };
        for (table.widths[0..count]) |*width| width.* = random.intRangeAtMost(usize, 1, 40);
        // Any window at or above the floor `detect` enforces.
        const floor = 1 + 4 * count;
        const columns = random.intRangeAtMost(usize, floor, floor + 60);

        var reference = table;
        var total = 1 + 3 * count;
        for (reference.widths[0..count]) |width| total += width;
        while (total > columns) : (total -= 1) {
            var widest: usize = 0;
            for (reference.widths[0..count], 0..) |width, index| {
                if (width > reference.widths[widest]) widest = index;
            }
            reference.widths[widest] -= 1;
        }

        table.fit(columns);
        try std.testing.expectEqualSlices(
            usize,
            reference.widths[0..count],
            table.widths[0..count],
        );
        // The grid fits the window and no column loses its last cell.
        var fitted = 1 + 3 * count;
        for (table.widths[0..count]) |width| {
            try std.testing.expect(width >= 1);
            fitted += width;
        }
        try std.testing.expect(fitted <= columns);
    }
}

test "a delimiter row is dashes with optional alignment colons" {
    try std.testing.expect(Table.isDelimiter("| --- |"));
    try std.testing.expect(Table.isDelimiter("|-|"));
    try std.testing.expect(Table.isDelimiter("  | :--- | ---: | :-: |"));
    try std.testing.expect(!Table.isDelimiter("| --x |"));
    try std.testing.expect(!Table.isDelimiter("|  |"));
    try std.testing.expect(!Table.isDelimiter("| :: |"));
    try std.testing.expect(!Table.isDelimiter("|"));
    try std.testing.expect(!Table.isDelimiter("---"));
    try std.testing.expectEqual(@as(usize, 2), Table.cellCount("| a | b |"));
    try std.testing.expectEqual(@as(usize, 2), Table.cellCount("| a | b"));
    try std.testing.expectEqual(@as(usize, 1), Table.cellCount("|"));
    try std.testing.expectEqual(@as(usize, 2), Table.cellCount("| `a \\| b` | c |"));
    try std.testing.expectEqual(@as(usize, 2), Table.cellCount("| a \\| b | c |"));
    try std.testing.expectEqual(@as(usize, 2), Table.cellCount("| a | b\\|"));
    try std.testing.expectEqual(@as(usize, 3), Table.cellCount("| a \\\\| b | c |"));
}

// A prefix never crowds the body out of the row: at two columns a bullet gives
// a column back, so the text still shows. The source does not advance behind a
// sink that clips every byte of it.
test "a prefix leaves room for the body it pushes right" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "- abc", "    - abc", "12. abc" }) |text| {
        // One column is the floor: the prefix drops away entirely rather than
        // take the only column the body has.
        for ([_]usize{ 1, 2 }) |columns| {
            const bytes = try painted(gpa, text, columns, null, 0);
            defer gpa.free(bytes);
            for ("abc") |letter| {
                try std.testing.expect(std.mem.indexOfScalar(u8, bytes, letter) != null);
            }
        }
    }
}

// A row ends between two words, so a copy of the rows out of the terminal holds
// whole words. The blanks at a break paint no cell and reach no row.
test "a block breaks its rows between words" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "one two three four", 12, &.{ "one two", "three four" });

    // A list item keeps its marker column and breaks its body the same way.
    try expectPlainRows(gpa, "- alpha beta gamma", 12, &.{ "- alpha beta", "  gamma" });

    // A word too long for a row of its own still breaks inside itself.
    try expectPlainRows(gpa, "ab abcdefghijkl", 6, &.{ "ab", "abcdef", "ghijkl" });

    // The break survives the inline markers: emphasis sheds its marks first, so
    // the row measures the words it shows.
    try expectPlainRows(gpa, "one **two** three four", 12, &.{ "one two", "three four" });
}

// No row ends on a blank, so a copy of the rows carries none. A blank inside a
// row still paints, whatever look holds it and whatever look follows it.
test "a row never ends on the blank it breaks at" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "aaa **bbbb**", 6, &.{ "aaa", "bbbb" });
    try expectPlainRows(gpa, "one two `code` three", 6, &.{ "one", "two", "code", "three" });
    try expectPlainRows(gpa, "- [ ] a task", 20, &.{"- [ ] a task"});
    try expectPlainRows(gpa, "a **b** c", 20, &.{"a b c"});

    // A row that holds nothing but its marker ends on that marker. An empty code
    // row drops the indent that a code line carries.
    try expectPlainRows(gpa, "- ", 20, &.{"-"});
    try expectPlainRows(gpa, "-   ", 20, &.{"-"});
    try expectPlainRows(gpa, "  - deep\n  - ", 20, &.{ "    - deep", "    -" });
    try expectPlainRows(gpa, "```\n\ncode\n\n```", 20, &.{ "```", "", "  code", "", "```" });
}

// A word that spans two looks breaks at that seam. The row it opens is painted
// already, so the wrap cannot move the whole word down.
test "a word that crosses a look seam breaks at the seam" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "aaa **bb**bbbb", 6, &.{ "aaa bb", "bbbb" });
}

// A wide cluster that will not fit the columns left takes the next row whole,
// as the plain wrap does, rather than the one-column replacement a fitted write
// leaves in its place.
test "a styled wide glyph wraps rather than degrading" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "abc**你**", 4, null, 0);
    defer gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 2), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "你") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "�") == null);
}

// A CRLF source ends every line with a carriage return. The line sheds it, so
// no row paints it as a replacement glyph and every block still parses.
test "a CRLF line sheds its carriage return" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "# Title\r\n\r\n**bold** text\r\n", 20, &.{
        "Title",
        "",
        "bold text",
        "",
    });

    const bytes = try painted(gpa, "```zig\r\nconst a = 1;\r\n```\r\n| a |\r\n| - |\r\n", 20, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "�") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "┌") != null);
}

// A quote reads by its color alone. A border glyph rides into every copy of the
// text a user takes out of the terminal.
test "a quote paints with no border glyph" {
    const gpa = std.testing.allocator;
    const text = "> **_Note:_** a quoted line\n> and its second line";
    try expectPlainRows(gpa, text, 30, &.{ "Note: a quoted line", "and its second line" });

    const bytes = try painted(gpa, text, 30, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "│") == null);
    // The quote is muted and italic. The nested bold pair sheds its marks and
    // uses underline, so it keeps both its emphasis and the faint tone.
    const nested = comptime role.sequence(.muted) ++ "\x1b[4m\x1b[3mNote:";
    try std.testing.expect(std.mem.indexOf(u8, bytes, nested) != null);
    const intensity_clash = comptime role.sequence(.muted) ++ "\x1b[1m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, intensity_clash) == null);
}

// Markers nest: an inner pair sheds its own markers instead of showing them as
// literal text. A pair that closes past the run holding it interleaves rather
// than nests, so it stays literal.
test "nested inline markers all shed their marks" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "**_both_** and *a **deep** run*", 40, &.{
        "both and a deep run",
    });
    try expectPlainRows(gpa, "***all three*** of them", 40, &.{"all three of them"});
    try expectPlainRows(gpa, "a **b _c** d_ e", 40, &.{"a b _c d_ e"});
    // A blank behind a marker opens the next emphasis, a tab as much as a
    // space. The emphasis reaches the closer behind `c`, and the tab itself
    // draws as one space.
    try expectPlainRows(gpa, "a *b\t*c* d", 40, &.{"a b *c d"});

    const bytes = try painted(gpa, "**_both_**", 40, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1m\x1b[3mboth") != null);
}

// A target a click can open makes the label itself the link, so no URL text
// follows it. A bare URL links to itself. Any other target keeps its URL as
// text, since a click cannot reach it.
test "a link paints as a terminal hyperlink" {
    const gpa = std.testing.allocator;
    const text = "see [docs](https://example.com/a) or https://example.com/b, " ++
        "[x](./x.md), [j](javascript:x)";
    try expectPlainRows(gpa, text, 90, &.{
        "see docs or https://example.com/b, x (./x.md), j (javascript:x)",
    });

    const bytes = try painted(gpa, text, 90, null, 0);
    defer gpa.free(bytes);
    const labelled = "\x1b]8;;https://example.com/a\x1b\\docs\x1b]8;;\x1b\\";
    try std.testing.expect(std.mem.indexOf(u8, bytes, labelled) != null);
    // The comma behind a bare URL ends the sentence, not the target.
    const bare = "\x1b]8;;https://example.com/b\x1b\\https://example.com/b\x1b]8;;\x1b\\";
    try std.testing.expect(std.mem.indexOf(u8, bytes, bare) != null);
    // The sink refuses a relative path and a scheme a click must not reach.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]8;;./x.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]8;;javascript:") == null);

    // The scheme of a bare URL reads case-insensitively, as a click does.
    const upper = try painted(gpa, "HTTPS://X.Y/a", 40, null, 0);
    defer gpa.free(upper);
    try std.testing.expect(std.mem.indexOf(u8, upper, "\x1b]8;;HTTPS://X.Y/a\x1b\\") != null);
}

// A bare URL the sink refuses keeps every byte the reader reads as the URL and
// loses the click alone, the way a relative target does. The sink takes
// printable ASCII, so a non-ASCII byte inside a URL costs its click.
test "a bare URL the sink refuses keeps its text and its look" {
    const gpa = std.testing.allocator;
    const text = "at https://x.y/\u{00e9}rest today";
    try expectPlainRows(gpa, text, 40, &.{"at https://x.y/érest today"});

    const bytes = try painted(gpa, text, 40, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, terminal.escape.link_set) == null);
    // The whole word still reads as a link, not the ASCII head of it.
    const styled = comptime role.sequence(.link) ++
        "\x1b[4mhttps://x.y/\u{00e9}rest\x1b[0m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, styled) != null);
}

// A label that wraps opens and closes its link on every row it covers. An open
// link makes the rows under it clickable too.
test "a wrapped link closes on each of its rows" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "[a long clickable label](https://example.com/a)", 10, null, 0);
    defer gpa.free(bytes);

    const opens = std.mem.count(u8, bytes, "\x1b]8;;https://example.com/a\x1b\\");
    try std.testing.expectEqual(paintedRows(bytes), opens);
    try std.testing.expectEqual(opens, std.mem.count(u8, bytes, terminal.escape.link_reset));
}

// The punctuation a sentence puts behind a bare URL is not part of its target.
// A closing parenthesis belongs to the URL only while the URL opens one.
test "a bare URL ends before the punctuation behind it" {
    try std.testing.expectEqual(@as(usize, 11), urlLength("https://x.y"));
    try std.testing.expectEqual(@as(usize, 11), urlLength("https://x.y."));
    try std.testing.expectEqual(@as(usize, 11), urlLength("https://x.y),"));
    try std.testing.expectEqual(@as(usize, 15), urlLength("https://x.y/(a)"));
    try std.testing.expectEqual(@as(usize, 15), urlLength("https://x.y/(a))"));
}

// A heading with no body is an empty heading, not literal text. It sheds its
// marker like any other and still takes the one row the count gives it.
test "a heading with no body paints an empty row" {
    const gpa = std.testing.allocator;
    // The heading row, the spacer that sets it off, and the paragraph.
    try expectPlainRows(gpa, "###\ntext", 20, &.{ "", "", "text" });

    const bytes = try painted(gpa, "######", 20, null, 0);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '#') == null);
}

// Mid-stream, `**bold` has not closed yet: it must stay literal whole rather
// than shed its first byte and flicker the rest as italic for a frame.
test "an unclosed bold marker stays literal" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "**bold*", 40, null, 0);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "**bold*") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[3m") == null);
}

// Adversarial: every `[` scans for a closer, so unmatched brackets once
// rescanned the tail one time each. That was quadratic in both passes, on every
// frame. The memo is what makes the scan linear, so pin it directly: a second
// call answers from the memo even when the text it receives says otherwise. The
// long line then renders as a canary. A rescan turns this test from
// milliseconds to minutes.
test "a line of unmatched brackets scans its tail once" {
    var missing: Closer = .{ .byte = ']' };
    try std.testing.expect(missing.find("[[[", 1) == null);
    try std.testing.expect(missing.find("[]]", 1) == null);
    var hit: Closer = .{ .byte = ']' };
    try std.testing.expectEqual(@as(?usize, 3), hit.find("[[[]", 1));
    try std.testing.expectEqual(@as(?usize, 3), hit.find("xxxx", 2));

    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, '[', 20_000);
    // `[](` reaches past the label to the url scan, whose closer is missing too.
    for (0..10_000) |_| try text.appendSlice(gpa, "[](");

    const bytes = try painted(gpa, text.items, 80, null, 0);
    defer gpa.free(bytes);
    try std.testing.expectEqual(rows(text.items, 80), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[[[") != null);
}

// Reasoning reads as one muted, italic block: the tint replaces every element
// role, while the structural markers stay. Underline carries bold emphasis.
// Double underline keeps an existing underline distinct.
test "a tinted block renders muted and italic throughout" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, sample, 72, .muted, 0);
    defer gpa.free(bytes);

    inline for ([_]role.Name{ .heading, .code, .accent, .link }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, role.sequence(name)) == null);
    }
    // Every span carries the muted italic tone, and the bullet is still there.
    const muted = comptime role.sequence(.muted) ++ "\x1b[3m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, muted) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "- ") != null);
    // An H2 uses underline for bold. An H1 uses double underline because its
    // source look already has underline.
    const emphasized = comptime role.sequence(.muted) ++ "\x1b[4m\x1b[3mHeading";
    const emphasized_underlined =
        comptime role.sequence(.muted) ++ "\x1b[21m\x1b[3mHeading one";
    try std.testing.expect(std.mem.indexOf(u8, bytes, emphasized) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, emphasized_underlined) != null);
    const intensity_clash = comptime role.sequence(.muted) ++ "\x1b[1m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, intensity_clash) == null);
}

// Parity again, over markers stitched together at random: the half-formed
// shapes a stream produces that a fixture never thinks to spell out. A row the
// count did not predict trips the sink's own assertions, so this pins the
// renderer against the input it cannot enumerate.
test "markdown holds row parity over arbitrary marker soup" {
    const gpa = std.testing.allocator;
    // Block markers, inline markers, and the text they wrap. The clusters wider
    // than one column are what a width budget has to saturate against.
    const tokens = [_][]const u8{
        "#",   "##",     "###### ", "- ",   "* ",  "1. ", "12) ", ">",           ">> ", "---",
        "```", "```zig", "**",      "*",    "_",   "__",  "~~",   "`",           "[",   "]",
        "(",   ")",      "[x] ",    "[ ] ", "\n",  " ",   "  ",   "https://x.y", "a",   "word",
        "\t",  "\x1b",   "\xff",    "|",    "|-|", "***", "___",  "http://",     "?",   ".",
    } ++ [_][]const u8{ "| --- |", "| a | b |", "你", "😀", "e\u{0301}" };
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..400) |_| {
        text.clearRetainingCapacity();
        for (0..random.uintLessThan(usize, 40)) |_| {
            try text.appendSlice(gpa, tokens[random.uintLessThan(usize, tokens.len)]);
        }
        for ([_]usize{ 1, 2, 3, 5, 9, 40, 100 }) |columns| {
            const bytes = try painted(gpa, text.items, columns, null, 0);
            defer gpa.free(bytes);
            try std.testing.expectEqual(rows(text.items, columns), paintedRows(bytes));
        }
    }
}

// The clip drops its top `skip` rows and never materializes them.
test "a clipped markdown block shows its bottom rows" {
    const gpa = std.testing.allocator;
    const columns = 40;
    const total = rows(sample, columns);
    const bytes = try painted(gpa, sample, columns, null, total - 4);
    defer gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 4), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Heading one") == null);
}
