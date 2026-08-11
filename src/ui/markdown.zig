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
        const italic = look.italic or self.tint != null;
        try role.apply(sink, name);
        if (look.bold) try attribute.apply(sink, .bold);
        if (italic) try attribute.apply(sink, .italic);
        if (look.underline) try attribute.apply(sink, .underline);
        if (look.strike) try attribute.apply(sink, .strikethrough);
        // The link opens and closes inside this span, so it covers exactly the
        // text on this row and never leaks into the row under it.
        try sink.linkSet(look.url);
        try sink.text(bytes);
        try sink.linkReset();
        if (role.paints(name) or look.bold or italic or look.underline or look.strike) {
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

/// A pipe table's grid: the column count its header row sets, the display width
/// each column gets after the fit to the window, and the blanks that hold the
/// grid at the indentation of its source. Every row must open with a pipe, an
/// escaped pipe gets no special treatment, and the alignment colons of the
/// delimiter row parse but do not align.
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
            if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];
            return .{ .rest = body };
        }

        fn next(self: *Cells) ?[]const u8 {
            if (self.done) return null;
            const pipe = std.mem.indexOfScalar(u8, self.rest, '|') orelse {
                self.done = true;
                return std.mem.trim(u8, self.rest, " \t");
            };
            defer self.rest = self.rest[pipe + 1 ..];
            return std.mem.trim(u8, self.rest[0..pipe], " \t");
        }
    };

    /// Truncates one cell's styled spans to the room its column gives. Once a
    /// span overflows, the cell is full: a later span must not slip into the
    /// gap a dropped cluster leaves. The room the content does not take stays
    /// for the pad, so every row of the grid draws to one width.
    fn Writer(comptime Emitter: type) type {
        return struct {
            emitter: *Emitter,
            room: usize,
            full: bool = false,

            fn write(self: *@This(), look: Look, bytes: []const u8) !void {
                if (self.full) return;
                const shown = terminal.width.truncate(bytes, self.room);
                const columns = terminal.width.ofText(shown);
                // Saturating: a cluster wider than the room survives
                // `truncate` as a one-column replacement. A cell cannot wrap,
                // so the cluster drops whole and the pad takes its columns.
                if (columns > self.room) {
                    self.full = true;
                    return;
                }
                if (shown.len > 0) {
                    try self.emitter.span(look, shown);
                    self.room -= columns;
                }
                if (shown.len < bytes.len) self.full = true;
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

    /// One content row: every cell under `look`, truncated to its column and
    /// padded out to it, between pipe borders.
    fn cellRow(
        self: *const Table,
        comptime Emitter: type,
        emitter: *Emitter,
        row: []const u8,
        look: Look,
    ) !void {
        emitter.begin();
        try emitter.span(.{}, self.indent);
        var cells = Cells.init(row);
        for (self.widths[0..self.count]) |width| {
            try emitter.span(muted_look, "│");
            try emitter.span(.{}, " ");
            var writer: Writer(Emitter) = .{ .emitter = emitter, .room = width };
            try inlines(Writer(Emitter), &writer, look, cells.next() orelse "");
            var remaining = writer.room + 1;
            while (remaining > 0) {
                const chunk = @min(remaining, blanks.len);
                try emitter.span(.{}, blank(chunk));
                remaining -= chunk;
            }
        }
        try emitter.span(muted_look, "│");
        emitter.end();
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
        open: bool = false,
        first: bool = true,

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

        /// Place `bytes` under `look` and continue on the next row when the
        /// width runs out. `truncate` always yields at least one cluster against
        /// a budget of one, so a row can never fail to advance.
        fn write(self: *@This(), look: Look, bytes: []const u8) !void {
            var rest = bytes;
            while (true) {
                try self.openRow();
                const room = self.budget -| self.used;
                const shown = terminal.width.truncate(rest, room);
                const shown_columns = terminal.width.ofText(shown);
                // Saturating: a cluster wider than `room` survives `truncate` as
                // a one-column replacement. Give it the next row whole first, as
                // the plain wrap does. Settle for the replacement only when a
                // row of its own is still too narrow.
                if (shown_columns > room and self.used > 0) {
                    self.closeRow();
                    continue;
                }
                if (shown.len > 0) {
                    try self.emitter.span(look, shown);
                    self.used += shown_columns;
                    rest = rest[shown.len..];
                }
                if (rest.len == 0) return;
                self.closeRow();
            }
        }

        /// Close the last row. A line with no content still occupies one.
        fn finish(self: *@This()) !void {
            try self.openRow();
            self.closeRow();
        }

        fn openRow(self: *@This()) !void {
            if (self.open) return;
            self.emitter.begin();
            self.open = true;
            self.used = 0;
            try self.emitter.span(.{}, self.prefix.indent);
            if (self.first) {
                try self.emitter.span(self.prefix.look, self.prefix.marker);
            } else {
                try self.emitter.span(.{}, blank(terminal.width.ofText(self.prefix.marker)));
            }
            self.first = false;
        }

        fn closeRow(self: *@This()) void {
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

/// One row that never wraps: `indent`, then `bytes` cut to the width left over.
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
    emitter.begin();
    try emitter.span(.{}, shown);
    try emitter.span(look, terminal.width.truncate(bytes, room));
    emitter.end();
}

/// An inline run: where its content lies in the source, the look that content
/// takes, and where the scan continues after it. `nests` marks content that can
/// carry markers of its own. `url` is the target a link appends as text when the
/// terminal cannot make the label itself clickable.
const Run = struct {
    look: Look,
    start: usize,
    end: usize,
    after: usize,
    nests: bool,
    url: []const u8 = "",
};

/// One open run: what the scan restores when that run closes.
const Scope = struct { look: Look, end: usize, after: usize, url: []const u8 };

/// Levels of nested inline markers the scan follows. A deeper marker stays
/// literal, which bounds the stack the scan carries.
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

/// Place `text`'s inline runs into `sink` under `base` and slice the markers
/// away. A run that holds markers of its own opens a scope, so `**_both_**`
/// sheds both pairs. A marker whose closer has not streamed in yet stays
/// literal. The sink is a `Flow` for a wrapped block, or a `Table.Writer` for
/// one table cell.
fn inlines(comptime Sink: type, sink: *Sink, base: Look, text: []const u8) !void {
    var stack: [nesting_max]Scope = undefined;
    var depth: usize = 0;
    var look = base;
    var link: Link = .{};
    var start: usize = 0;
    var index: usize = 0;
    // Bounded: every step raises `index`. A run opens after its own marker, a
    // closed run resumes past its closer, and any other byte advances by one.
    // The scan therefore reaches the end of `text` and stops there.
    while (index < text.len or depth > 0) {
        if (depth > 0 and index >= stack[depth - 1].end) {
            const scope = stack[depth - 1];
            // A closer is never stepped over: no doubled marker can straddle
            // one, so the scan lands on it exactly.
            std.debug.assert(index == scope.end);
            try sink.write(look, text[start..index]);
            depth -= 1;
            look = if (depth > 0) stack[depth - 1].look else base;
            try trailer(Sink, sink, look, scope.url);
            index = scope.after;
            start = index;
            continue;
        }
        // A run must close inside the run that holds it. One that reaches past
        // it interleaves rather than nests, so its marker stays literal.
        const limit = if (depth > 0) stack[depth - 1].end else text.len;
        if (runAt(text, index, &link)) |run| {
            if (run.after <= limit) {
                try sink.write(look, text[start..index]);
                const inner = merged(look, run.look);
                if (run.nests and depth < nesting_max) {
                    stack[depth] = .{
                        .look = inner,
                        .end = run.end,
                        .after = run.after,
                        .url = run.url,
                    };
                    depth += 1;
                    look = inner;
                    index = run.start;
                } else {
                    try sink.write(inner, text[run.start..run.end]);
                    try trailer(Sink, sink, look, run.url);
                    index = run.after;
                }
                start = index;
                continue;
            }
        }
        // A marker with no closer stays literal whole: a later byte of it must
        // not reopen as a shorter marker and split `**bold` into a stray
        // asterisk and an italic run mid-stream.
        index += literal(text, index);
    }
    try sink.write(look, text[start..]);
}

/// Place the URL a link shows as text, in the muted color of the context it
/// closes into.
fn trailer(comptime Sink: type, sink: *Sink, look: Look, url: []const u8) !void {
    if (url.len == 0) return;
    const shown = merged(look, muted_look);
    try sink.write(shown, " (");
    try sink.write(shown, url);
    try sink.write(shown, ")");
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
// truncation drops a column of the pad or counts more than it has.
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

// The frame's visible text: the CSI sequences, the hyperlink strings, and the
// sink's zero-width seam guards stripped away. The rows keep their `\r\n`
// separators. The caller owns the returned bytes.
fn plainBody(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var index: usize = 0;
    while (index < bytes.len) {
        if (std.mem.startsWith(u8, bytes[index..], terminal.escape.link_set)) {
            const rest = bytes[index + terminal.escape.link_set.len ..];
            const end = std.mem.indexOf(u8, rest, terminal.escape.string_end) orelse rest.len;
            index = bytes.len - rest.len + end + terminal.escape.string_end.len;
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

// Paint `text` and compare the visible rows, character for character.
fn expectPlainRows(
    gpa: std.mem.Allocator,
    text: []const u8,
    columns: usize,
    expected: []const []const u8,
) !void {
    const bytes = try painted(gpa, text, columns, null, 0);
    defer gpa.free(bytes);
    const body = try plainBody(gpa, frameBody(bytes));
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
        for (0..total) |row| {
            const source_offset = sourceAtRow(sample, &.{
                .columns = columns,
                .row = row,
            });
            const first = rowAtSource(sample, &.{
                .columns = columns,
                .source_offset = source_offset,
            });
            try std.testing.expect(first <= row);
            try std.testing.expectEqual(source_offset, sourceAtRow(sample, &.{
                .columns = columns,
                .row = first,
            }));
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
    // An ordered list keeps the number it started from, and a task its box.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "3. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[ ] ") != null);
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

// A cell wider than the window cannot widen the grid past it: the widest
// column gives up cells until the grid fits, and its content truncates.
test "a table shrinks its widest column to fit the window" {
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
        "└───────┴────────────────────┘",
    });
}

// A wide cluster that straddles the column's edge drops whole, and the pad
// keeps the grid aligned behind it.
test "a wide glyph in a table cell truncates whole" {
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
        "└─────┴───┘",
    });
}

// A cluster that is wider than the whole column drops as well. `truncate`
// keeps such a cluster as a one-column replacement, which a cell must not
// count as one column and must not draw.
test "a cluster wider than its column drops from the cell" {
    const gpa = std.testing.allocator;
    const text =
        \\| 你 | b |
        \\| - | - |
        \\| c | d |
    ;
    try expectPlainRows(gpa, text, 9, &.{
        "┌───┬───┐",
        "│   │ b │",
        "├───┼───┤",
        "│ c │ d │",
        "└───┴───┘",
    });
}

// Every row of one grid draws to the same width. A cell that truncates gives
// the columns it does not fill back to the pad, so the right border lines up.
test "a table draws every grid row to one width" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "| a你你 | bbbbbb |\n| - | - |\n| c | d |", 16, &.{
        "┌──────┬───────┐",
        "│ a你  │ bbbbb │",
        "├──────┼───────┤",
        "│ c    │ d     │",
        "└──────┴───────┘",
    });

    for ([_][]const u8{ tables, wide_tables, partial_tables }) |text| {
        for ([_]usize{ 72, 40, 24, 16, 13, 11, 10, 9 }) |columns| {
            const bytes = try painted(gpa, text, columns, null, 0);
            defer gpa.free(bytes);
            const body = try plainBody(gpa, frameBody(bytes));
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
    // The quote is muted and italic, and the nested pair adds its bold on top.
    const nested = comptime role.sequence(.muted) ++ "\x1b[1m\x1b[3mNote:";
    try std.testing.expect(std.mem.indexOf(u8, bytes, nested) != null);
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
// role, while the attributes and the structural markers stay.
test "a tinted block renders muted and italic throughout" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, sample, 72, .muted, 0);
    defer gpa.free(bytes);

    inline for ([_]role.Name{ .heading, .code, .accent, .link }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, role.sequence(name)) == null);
    }
    // A heading is still bold, and the bullet is still there — just muted.
    const muted = comptime role.sequence(.muted) ++ "\x1b[1m\x1b[3m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, muted) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "- ") != null);
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
