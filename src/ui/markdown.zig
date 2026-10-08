const std = @import("std");

const core = @import("core");
const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

const blanks = core.text.repeat(" ", 32);

const rule_cell = "─";

const rule_columns = 80;

const rule_cells = core.text.repeat(rule_cell, rule_columns);

const Look = struct {
    role: ?role.Name = null,
    url: []const u8 = "",
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
};

const accent_look: Look = .{ .role = .accent };
const inline_code_look: Look = .{ .role = .accent };
const code_look: Look = .{ .role = .code };
const heading_look: Look = .{ .role = .heading };
const muted_look: Look = .{ .role = .muted };
const quote_look: Look = .{ .role = .muted, .italic = true };
const link_look: Look = .{ .role = .link, .underline = true };

const RowOptions = struct {
    columns: usize,
    row: usize,
};

const SourceOptions = struct {
    columns: usize,
    source_offset: usize,
};

const WindowOptions = struct {
    rows_max: usize,
};

const Counter = struct {
    count: usize = 0,

    fn source(_: *Counter, _: usize) void {}
    fn begin(_: *Counter) void {}
    fn span(_: *Counter, _: *const Look, _: []const u8) !void {}
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
    fn span(_: *SourceAtRow, _: *const Look, _: []const u8) !void {}
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
    fn span(_: *RowAtSource, _: *const Look, _: []const u8) !void {}
    fn end(self: *RowAtSource) void {
        self.row += 1;
    }
};

const Painter = struct {
    placement: *const paint.Placement,
    tint: ?role.Name,
    line: usize,
    line_end: usize = std.math.maxInt(usize),
    hidden: bool = false,

    fn source(_: *Painter, _: usize) void {}

    fn begin(self: *Painter) void {
        self.hidden = self.line >= self.line_end or !self.placement.begin(self.line);
    }

    fn span(self: *Painter, look: *const Look, bytes: []const u8) !void {
        if (self.hidden or bytes.len == 0) return;
        const sink = self.placement.sink;
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
        try sink.linkSet(look.url);
        try sink.text(bytes);
        try sink.linkReset();
        if (role.paints(name) or emphasized or italic or look.underline or look.strike) {
            try attribute.apply(sink, .reset);
        }
    }

    fn end(self: *Painter) void {
        defer self.line += 1;
        if (!self.hidden) self.placement.end(self.line);
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
        if (marker == '`' and std.mem.findScalar(u8, line[length..], '`') != null) return null;
        return .{ .marker = marker, .length = length };
    }

    fn closes(self: Fence, line: []const u8) bool {
        if (line.len < self.length or line[0] != self.marker) return false;
        const length = markerLength(line, self.marker);
        return length >= self.length and paint.isBlank(line[length..]);
    }

    fn markerLength(line: []const u8, marker: u8) usize {
        var length: usize = 0;
        while (length < line.len and line[length] == marker) length += 1;
        return length;
    }
};

const Table = struct {
    count: usize,
    widths: [count_max]usize,
    indent: []const u8,

    const count_max = 16;

    const Border = struct { left: []const u8, joint: []const u8, right: []const u8 };

    const border_top: Border = .{ .left = "┌", .joint = "┬", .right = "┐" };
    const border_inner: Border = .{ .left = "├", .joint = "┼", .right = "┤" };
    const border_bottom: Border = .{ .left = "└", .joint = "┴", .right = "┘" };

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
            while (std.mem.findScalarPos(u8, self.rest, search_from, '|')) |pipe| {
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

    fn CellFlow(comptime Emitter: type) type {
        return struct {
            row: RowWriter(Emitter),
            scanner: InlineScanner,
            rest: []const u8 = "",
            look: Look = .{},
            done: bool = false,

            fn paintLine(self: *@This()) !void {
                self.row.reset();
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
                    const room = self.row.room();
                    const run = self.row.wordRun(self.rest);
                    if (run == 0 and self.row.used > 0) return;
                    const cut = if (run > 0) self.rest[0..run] else self.rest;
                    const shown = terminal.width.truncate(cut, room);
                    std.debug.assert(run > 0 or shown.len > 0);
                    if (terminal.width.ofText(shown) > room) {
                        if (self.row.used > 0) return;
                        try self.row.place(&self.look, paint.ellipsis);
                        self.rest = self.rest[terminal.width.boundaryAfter(self.rest, 0)..];
                        while (self.rest.len > 0) {
                            const cluster = terminal.width.boundaryAfter(self.rest, 0);
                            const cluster_columns = terminal.width.ofText(self.rest[0..cluster]);
                            if (cluster_columns <= self.row.width) break;
                            self.rest = self.rest[cluster..];
                        }
                        continue;
                    }
                    try self.row.place(&self.look, shown);
                    self.rest = self.rest[if (run > 0) run else shown.len..];
                }
            }
        };
    }

    fn fitted(header: []const u8, table_rows: *const Block.TableRows, columns: usize) ?Table {
        const indent = terminal.width.truncate(blank(leading(header)), prefixRoom(columns));
        const room = columns -| terminal.width.ofText(indent);
        if (1 + 4 * table_rows.count > room) return null;
        var table: Table = .{ .count = table_rows.count, .widths = @splat(1), .indent = indent };
        const widths = table.widths[0..table.count];
        measureRow(widths, header);
        var lines = table_rows.rows();
        while (lines.next()) |row| measureRow(widths, row);
        table.shareWidths(room);
        return table;
    }

    fn render(
        self: *const Table,
        comptime Emitter: type,
        emitter: *Emitter,
        blocks: *const Blocks,
        header: []const u8,
        table_rows: *const Block.TableRows,
    ) !void {
        try self.borderRow(Emitter, emitter, &border_top);
        try self.cellRow(Emitter, emitter, header, &.{ .bold = true });
        emitter.source(blocks.offset(table_rows.delimiter));
        var lines = table_rows.rows();
        var maybe_row = lines.next();
        const middle = if (maybe_row == null) &border_bottom else &border_inner;
        try self.borderRow(Emitter, emitter, middle);
        while (maybe_row) |row| {
            emitter.source(blocks.offset(row));
            try self.cellRow(Emitter, emitter, row, &.{});
            maybe_row = lines.next();
            if (maybe_row == null) try self.borderRow(Emitter, emitter, &border_bottom);
        }
    }

    fn measureRow(widths: []usize, row: []const u8) void {
        var cells = Cells.init(row);
        for (widths) |*width| {
            const cell = cells.next() orelse break;
            var scanner = InlineScanner.init(.{}, cell, .table);
            var columns: usize = 0;
            while (scanner.next()) |span| columns += terminal.width.ofText(span.bytes);
            width.* = @max(width.*, columns);
        }
    }

    fn isRow(line: []const u8) bool {
        const body = line[leading(line)..];
        return body.len > 0 and body[0] == '|';
    }

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

    fn shareWidths(self: *Table, columns: usize) void {
        const room = columns -| (1 + 3 * self.count);
        var low: usize = 1;
        var high: usize = @max(room, 1);
        while (low < high) {
            const cap = low + @divFloor(high - low + 1, 2);
            if (self.capped(cap) <= room) low = cap else high = cap - 1;
        }
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

    fn capped(self: *const Table, cap: usize) usize {
        var total: usize = 0;
        for (self.widths[0..self.count]) |width| total += @min(width, cap);
        return total;
    }

    fn borderRow(
        self: *const Table,
        comptime Emitter: type,
        emitter: *Emitter,
        border: *const Border,
    ) !void {
        emitter.begin();
        try emitter.span(&.{}, self.indent);
        try emitter.span(&muted_look, border.left);
        for (self.widths[0..self.count], 0..) |width, index| {
            if (index > 0) try emitter.span(&muted_look, border.joint);
            var remaining = width + 2;
            while (remaining > 0) {
                const chunk = @min(remaining, rule_columns);
                try emitter.span(&muted_look, rule_cells[0 .. rule_cell.len * chunk]);
                remaining -= chunk;
            }
        }
        try emitter.span(&muted_look, border.right);
        emitter.end();
    }

    fn cellRow(
        self: *const Table,
        comptime Emitter: type,
        emitter: *Emitter,
        row: []const u8,
        look: *const Look,
    ) !void {
        var flows: [count_max]CellFlow(Emitter) = undefined;
        var cells = Cells.init(row);
        for (flows[0..self.count], self.widths[0..self.count]) |*flow, width| {
            flow.* = .{
                .row = .{ .emitter = emitter, .width = width },
                .scanner = InlineScanner.init(look.*, cells.next() orelse "", .table),
            };
        }
        var more = true;
        while (more) {
            more = false;
            emitter.begin();
            try emitter.span(&.{}, self.indent);
            for (flows[0..self.count]) |*flow| {
                try emitter.span(&muted_look, "│");
                try emitter.span(&.{}, " ");
                try flow.paintLine();
                more = more or !flow.done;
                std.debug.assert(flow.row.painted <= flow.row.width);
                try writeBlanks(Emitter, emitter, &.{}, flow.row.width - flow.row.painted + 1);
            }
            try emitter.span(&muted_look, "│");
            emitter.end();
        }
    }
};

const Block = struct {
    line: []const u8,
    kind: Kind,

    const Kind = union(enum) {
        fence_open,
        fence_line,
        fence_close,
        blank,
        rule,
        table: TableRows,
        heading: Heading,
        quote: []const u8,
        list_item: ListItem,
        paragraph,
    };

    const Heading = struct {
        level: usize,
        body: []const u8,
    };

    const ListItem = struct {
        depth: usize,
        marker: Marker,
        task_box: ?[]const u8,
        body: []const u8,
    };

    const TableRows = struct {
        count: usize,
        delimiter: []const u8,
        body: []const u8,

        fn rows(self: *const TableRows) Rows {
            return .{ .rest = if (self.body.len == 0) null else self.body };
        }
    };

    const Rows = struct {
        rest: ?[]const u8,

        fn next(self: *Rows) ?[]const u8 {
            const rest = self.rest orelse return null;
            const end = std.mem.findScalar(u8, rest, '\n') orelse {
                self.rest = null;
                return rest;
            };
            self.rest = rest[end + 1 ..];
            return rest[0..end];
        }
    };
};

const Blocks = struct {
    text: []const u8,
    lines: std.mem.SplitIterator(u8, .scalar),
    fence: ?Fence = null,

    fn init(text: []const u8) Blocks {
        return .{ .text = text, .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    fn peek(self: *Blocks) ?[]const u8 {
        return self.lines.peek();
    }

    fn offset(self: *const Blocks, line: []const u8) usize {
        return @intFromPtr(line.ptr) - @intFromPtr(self.text.ptr);
    }

    fn next(self: *Blocks) ?Block {
        const line = std.mem.trimEnd(u8, self.lines.next() orelse return null, "\r");
        const indentation = leading(line);
        const rest = line[indentation..];
        if (self.fence) |fence| {
            if (indentation <= 3 and fence.closes(rest)) {
                self.fence = null;
                return .{ .line = line, .kind = .fence_close };
            }
            return .{ .line = line, .kind = .fence_line };
        }
        if (indentation <= 3) {
            if (Fence.open(rest)) |fence| {
                self.fence = fence;
                return .{ .line = line, .kind = .fence_open };
            }
        }
        if (paint.isBlank(rest)) return .{ .line = line, .kind = .blank };
        if (isRule(rest)) return .{ .line = line, .kind = .rule };
        if (self.table(rest)) |shape| return .{ .line = line, .kind = .{ .table = shape } };
        if (headingLevel(rest)) |level| return .{ .line = line, .kind = .{ .heading = .{
            .level = level,
            .body = std.mem.trimStart(u8, rest[level..], " "),
        } } };
        if (rest[0] == '>') return .{ .line = line, .kind = .{ .quote = quoteBody(rest) } };
        if (listMarker(rest)) |marker| {
            const body = rest[marker.source..];
            const task_box = taskBox(body);
            return .{ .line = line, .kind = .{ .list_item = .{
                .depth = @min(@divFloor(indentation, 2), 4),
                .marker = marker,
                .task_box = task_box,
                .body = if (task_box) |box| body[box.len..] else body,
            } } };
        }
        return .{ .line = line, .kind = .paragraph };
    }

    fn table(self: *Blocks, header: []const u8) ?Block.TableRows {
        if (header[0] != '|') return null;
        const delimiter = std.mem.trimEnd(u8, self.lines.peek() orelse return null, "\r");
        if (!Table.isDelimiter(delimiter)) return null;
        const count = Table.cellCount(header);
        if (count != Table.cellCount(delimiter) or count > Table.count_max) return null;
        _ = self.lines.next();
        var maybe_start: ?usize = null;
        var end: usize = 0;
        while (self.lines.peek()) |row| {
            if (!Table.isRow(row)) break;
            _ = self.lines.next();
            if (maybe_start == null) maybe_start = self.offset(row);
            end = self.offset(row) + row.len;
        }
        const start = maybe_start orelse end;
        return .{ .count = count, .delimiter = delimiter, .body = self.text[start..end] };
    }
};

const Prefix = struct {
    indent: []const u8 = "",
    marker: []const u8 = "",
    look: Look = .{},
};

const PlainRow = struct {
    columns: usize,
    indent: []const u8 = "",
    look: *const Look,
    bytes: []const u8,
};

const Event = struct {
    at: usize,
    style: Style,
    side: Side,

    const Style = enum { emphasis, strong, strike, link };
    const Side = enum { open, close };

    fn width(self: Event) usize {
        return switch (self.style) {
            .emphasis => 1,
            .strong, .strike => 2,
            .link => unreachable,
        };
    }

    fn before(_: void, left: Event, right: Event) bool {
        return left.at < right.at;
    }
};

const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
    after: usize,

    const Kind = enum { literal, escape, code, url };
};

const Destination = struct {
    url: []const u8,
    after: usize,
};

const Parser = struct {
    text: []const u8,
    events: *[events_max]Event,
    events_len: usize = 0,
    delimiters: [delimiters_max]Delimiter = undefined,
    delimiters_len: usize = 0,
    brackets: [brackets_max]Bracket = undefined,
    brackets_len: usize = 0,

    const Delimiter = struct {
        byte: u8,
        count: usize,
        start: usize,
        end: usize,
        can_open: bool,
        can_close: bool,
        removed: bool = false,
    };

    const Bracket = struct {
        at: usize,
        bottom: usize,
        active: bool = true,
    };

    fn run(self: *Parser) usize {
        const text = self.text;
        var index: usize = 0;
        while (std.mem.findAnyPos(u8, text, index, token_starts ++ "*_~[]")) |found| {
            index = switch (text[found]) {
                '*', '_', '~' => self.pushDelimiter(found),
                '[' => self.pushBracket(found),
                ']' => self.closeBracket(found),
                else => if (tokenAt(text, found)) |token| token.after else found + 1,
            };
        }
        self.emphasize(0);
        std.sort.insertion(Event, self.events[0..self.events_len], {}, Event.before);
        return self.events_len;
    }

    fn pushDelimiter(self: *Parser, at: usize) usize {
        const text = self.text;
        const byte = text[at];
        const end = runEnd(text, at, byte);
        if (byte == '~' and end - at != 2) return end;
        if (self.delimiters_len == delimiters_max) return end;
        const before: u8 = if (at > 0) text[at - 1] else ' ';
        const after: u8 = if (end < text.len) text[end] else ' ';
        const left = flanks(&.{ .inner = after, .outer = before });
        const right = flanks(&.{ .inner = before, .outer = after });
        const can_open = left and (byte != '_' or !right or std.ascii.isPunctuation(before));
        const can_close = right and (byte != '_' or !left or std.ascii.isPunctuation(after));
        if (!can_open and !can_close) return end;
        self.delimiters[self.delimiters_len] = .{
            .byte = byte,
            .count = end - at,
            .start = at,
            .end = end,
            .can_open = can_open,
            .can_close = can_close,
        };
        self.delimiters_len += 1;
        return end;
    }

    fn pushBracket(self: *Parser, at: usize) usize {
        if (self.brackets_len == brackets_max) {
            std.mem.copyForwards(Bracket, self.brackets[0 .. brackets_max - 1], self.brackets[1..]);
            self.brackets_len -= 1;
        }
        self.brackets[self.brackets_len] = .{ .at = at, .bottom = self.delimiters_len };
        self.brackets_len += 1;
        return at + 1;
    }

    fn closeBracket(self: *Parser, at: usize) usize {
        if (self.brackets_len == 0) return at + 1;
        self.brackets_len -= 1;
        const bracket = self.brackets[self.brackets_len];
        if (!bracket.active) return at + 1;
        const destination = destinationAt(self.text, at + 1) orelse return at + 1;
        const added = self.add(&.{
            .{ .at = bracket.at, .style = .link, .side = .open },
            .{ .at = at, .style = .link, .side = .close },
        });
        if (!added) return at + 1;
        self.emphasize(bracket.bottom);
        for (self.brackets[0..self.brackets_len]) |*earlier| earlier.active = false;
        return destination.after;
    }

    fn emphasize(self: *Parser, bottom: usize) void {
        var openers_bottom: [3][2][3]usize = @splat(@splat(@splat(bottom)));
        var closer_index = bottom;
        while (closer_index < self.delimiters_len) {
            const closer = &self.delimiters[closer_index];
            if (closer.removed or !closer.can_close) {
                closer_index += 1;
                continue;
            }
            const byte_index: usize = switch (closer.byte) {
                '*' => 0,
                '_' => 1,
                '~' => 2,
                else => unreachable,
            };
            const opens: usize = @intFromBool(closer.can_open);
            const lowest = &openers_bottom[byte_index][opens][closer.count % 3];
            if (self.openerFor(&.{ .closer = closer_index, .lowest = lowest.* })) |opener_index| {
                if (!self.pair(&.{ .opener = opener_index, .closer = closer_index })) break;
                if (closer.start == closer.end) {
                    closer.removed = true;
                    closer_index += 1;
                }
            } else {
                lowest.* = closer_index;
                if (!closer.can_open) closer.removed = true;
                closer_index += 1;
            }
        }
        self.delimiters_len = bottom;
    }

    fn openerFor(
        self: *const Parser,
        search: *const struct { closer: usize, lowest: usize },
    ) ?usize {
        const closer = &self.delimiters[search.closer];
        var index = search.closer;
        while (index > search.lowest) {
            index -= 1;
            const opener = &self.delimiters[index];
            if (opener.removed or !opener.can_open or opener.byte != closer.byte) continue;
            const both = closer.can_open or opener.can_close;
            const multiple = closer.count % 3 != 0 and (opener.count + closer.count) % 3 == 0;
            if (!(both and multiple)) return index;
        }
        return null;
    }

    fn pair(self: *Parser, indices: *const struct { opener: usize, closer: usize }) bool {
        const opener = &self.delimiters[indices.opener];
        const closer = &self.delimiters[indices.closer];
        const strong = opener.end - opener.start >= 2 and closer.end - closer.start >= 2;
        const style: Event.Style = if (opener.byte == '~')
            .strike
        else if (strong)
            .strong
        else
            .emphasis;
        const closed: Event = .{ .at = closer.start, .style = style, .side = .close };
        const width = closed.width();
        if (!self.add(&.{ .{ .at = opener.end - width, .style = style, .side = .open }, closed })) {
            return false;
        }
        opener.end -= width;
        closer.start += width;
        for (self.delimiters[indices.opener + 1 .. indices.closer]) |*between| {
            between.removed = true;
        }
        if (opener.start == opener.end) opener.removed = true;
        return true;
    }

    fn add(self: *Parser, events: *const [2]Event) bool {
        if (self.events_len + events.len > events_max) return false;
        self.events[self.events_len..][0..events.len].* = events.*;
        self.events_len += events.len;
        return true;
    }
};

const InlineScanner = struct {
    text: []const u8,
    base: Look,
    context: Context,
    events: [events_max]Event = undefined,
    events_len: usize = 0,
    event_index: usize = 0,
    styles: [3]usize = @splat(0),
    maybe_link: ?Link = null,
    maybe_code: ?Code = null,
    url_buffer: [terminal.View.Sink.url_bytes_max]u8 = undefined,
    url_used: usize = 0,
    start: usize = 0,
    index: usize = 0,
    done: bool = false,
    queue: [4]Span = undefined,
    queue_len: usize = 0,
    queue_head: usize = 0,

    const Context = enum { block, table };
    const Span = struct { look: Look, bytes: []const u8 };
    const Link = struct { look: Look, trailer: []const u8, after: usize };
    const Code = struct { end: usize, after: usize };

    fn init(base: Look, text: []const u8, context: Context) InlineScanner {
        var scanner: InlineScanner = .{ .text = text, .base = base, .context = context };
        var parser: Parser = .{ .text = text, .events = &scanner.events };
        scanner.events_len = parser.run();
        return scanner;
    }

    fn next(self: *InlineScanner) ?Span {
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

    fn step(self: *InlineScanner) void {
        if (self.maybe_code) |code| return self.stepCode(code);
        const text = self.text;
        const event_at = if (self.event_index < self.events_len)
            self.events[self.event_index].at
        else
            text.len;
        std.debug.assert(self.index <= event_at);
        if (self.index == event_at) {
            self.flush();
            if (self.event_index == self.events_len) {
                self.done = true;
                return;
            }
            self.apply(self.events[self.event_index]);
            self.event_index += 1;
            return;
        }
        const before_event = text[0..event_at];
        const candidate = std.mem.findAnyPos(u8, before_event, self.index, token_starts) orelse {
            self.index = event_at;
            return;
        };
        const token = tokenAt(text, candidate) orelse {
            self.index = candidate + 1;
            return;
        };
        self.index = candidate;
        if (token.kind == .literal) {
            self.index = token.after;
            return;
        }
        self.flush();
        switch (token.kind) {
            .literal => unreachable,
            .escape => self.start = token.start,
            .code => {
                self.maybe_code = .{ .end = token.end, .after = token.after };
                self.start = token.start;
            },
            .url => {
                const url = text[token.start..token.end];
                self.enqueue(merged(&self.currentLook(), &linkLook(url)), url);
                self.start = token.after;
            },
        }
        self.index = if (token.kind == .code) token.start else token.after;
    }

    fn stepCode(self: *InlineScanner, code: Code) void {
        const shown = merged(&self.currentLook(), &inline_code_look);
        const content = self.text[0..code.end];
        const maybe_pipe = if (self.context == .table)
            std.mem.findPos(u8, content, self.index, "\\|")
        else
            null;
        if (maybe_pipe) |pipe| {
            self.enqueue(shown, content[self.index..pipe]);
            self.enqueue(shown, "|");
            self.index = pipe + 2;
            return;
        }
        self.enqueue(shown, content[self.index..]);
        self.maybe_code = null;
        self.index = code.after;
        self.start = code.after;
    }

    fn apply(self: *InlineScanner, event: Event) void {
        switch (event.style) {
            .link => switch (event.side) {
                .open => self.openLink(event.at),
                .close => self.closeLink(),
            },
            .emphasis, .strong, .strike => {
                const count = &self.styles[@backingInt(event.style)];
                switch (event.side) {
                    .open => count.* += 1,
                    .close => count.* -= 1,
                }
                self.index = event.at + event.width();
                self.start = self.index;
            },
        }
    }

    fn openLink(self: *InlineScanner, at: usize) void {
        const text = self.text;
        const later = self.events[self.event_index + 1 .. self.events_len];
        const close_index = for (later, self.event_index + 1..) |event, index| {
            if (event.style == .link) break index;
        } else unreachable;
        const close = self.events[close_index].at;
        std.debug.assert(self.events[close_index].side == .close);
        const destination = destinationAt(text, close + 1) orelse unreachable;
        const label = text[at + 1 .. close];
        const url = self.unescaped(destination.url);
        const shown = linkLook(url);
        if (label.len == 0) {
            self.enqueue(merged(&self.currentLook(), &shown), url);
            self.event_index = close_index;
            self.index = destination.after;
            self.start = self.index;
            return;
        }
        const plain = shown.url.len > 0 or sameUnescaped(label, destination.url);
        self.maybe_link = .{
            .look = shown,
            .trailer = if (plain) "" else url,
            .after = destination.after,
        };
        self.index = at + 1;
        self.start = self.index;
    }

    fn closeLink(self: *InlineScanner) void {
        const link = self.maybe_link orelse unreachable;
        self.maybe_link = null;
        if (link.trailer.len > 0) {
            const shown = merged(&self.currentLook(), &muted_look);
            self.enqueue(shown, " (");
            self.enqueue(shown, link.trailer);
            self.enqueue(shown, ")");
        }
        self.index = link.after;
        self.start = link.after;
    }

    fn unescaped(self: *InlineScanner, url: []const u8) []const u8 {
        if (std.mem.findScalar(u8, url, '\\') == null) return url;
        const free = self.url_buffer[self.url_used..];
        var length: usize = 0;
        var index: usize = 0;
        while (index < url.len) : (index += 1) {
            if (url[index] == '\\' and escapeAt(url, index) != null) index += 1;
            if (length == free.len) return url;
            free[length] = url[index];
            length += 1;
        }
        self.url_used += length;
        return free[0..length];
    }

    fn currentLook(self: *const InlineScanner) Look {
        var look = self.base;
        look.italic = look.italic or self.styles[@backingInt(Event.Style.emphasis)] > 0;
        look.bold = look.bold or self.styles[@backingInt(Event.Style.strong)] > 0;
        look.strike = look.strike or self.styles[@backingInt(Event.Style.strike)] > 0;
        if (self.maybe_link) |link| return merged(&look, &link.look);
        return look;
    }

    fn flush(self: *InlineScanner) void {
        self.enqueue(self.currentLook(), self.text[self.start..self.index]);
        self.start = self.index;
    }

    fn enqueue(self: *InlineScanner, look: Look, bytes: []const u8) void {
        self.queue[self.queue_len] = .{ .look = look, .bytes = bytes };
        self.queue_len += 1;
    }
};

const Marker = struct { source: usize, shown: []const u8 };

pub fn rows(text: []const u8, columns: usize) usize {
    var counter: Counter = .{};
    walk(Counter, &counter, text, columns) catch unreachable;
    return counter.count;
}

pub fn sourceAtRow(text: []const u8, options: *const RowOptions) usize {
    var locator: SourceAtRow = .{ .target = options.row };
    walk(SourceAtRow, &locator, text, options.columns) catch unreachable;
    return locator.result;
}

pub fn rowAtSource(text: []const u8, options: *const SourceOptions) usize {
    var locator: RowAtSource = .{ .target = @min(options.source_offset, text.len) };
    walk(RowAtSource, &locator, text, options.columns) catch unreachable;
    return locator.result;
}

pub fn render(placement: *const paint.Placement, tint: ?role.Name, text: []const u8) !void {
    var painter: Painter = .{ .placement = placement, .tint = tint, .line = placement.base };
    try walk(Painter, &painter, text, placement.columns);
}

pub fn renderWindow(
    placement: *const paint.Placement,
    text: []const u8,
    options: *const WindowOptions,
) !void {
    var painter: Painter = .{
        .placement = placement,
        .tint = null,
        .line = placement.base,
        .line_end = placement.skip +| options.rows_max,
    };
    try walk(Painter, &painter, text, placement.columns);
}

fn isEscaped(text: []const u8, index: usize) bool {
    var backslashes: usize = 0;
    while (backslashes < index and text[index - 1 - backslashes] == '\\') : (backslashes += 1) {}
    return backslashes % 2 == 1;
}

fn quoteBody(rest: []const u8) []const u8 {
    var body = rest;
    while (body.len > 0 and body[0] == '>') {
        body = body[1..];
        if (body.len > 0 and body[0] == ' ') body = body[1..];
    }
    return body;
}

fn walk(comptime Emitter: type, emitter: *Emitter, text: []const u8, columns: usize) !void {
    var blocks: Blocks = .init(text);
    while (blocks.next()) |block| {
        emitter.source(blocks.offset(block.line));
        switch (block.kind) {
            .fence_open, .fence_close => {
                try plainRow(Emitter, emitter, &.{
                    .columns = columns,
                    .look = &muted_look,
                    .bytes = block.line,
                });
            },
            .fence_line => try plainRow(Emitter, emitter, &.{
                .columns = columns,
                .indent = blank(2),
                .look = &code_look,
                .bytes = block.line,
            }),
            .blank => {
                emitter.begin();
                emitter.end();
            },
            .rule => {
                const cells = rule_cells[0 .. rule_cell.len * @min(columns, rule_columns)];
                try plainRow(Emitter, emitter, &.{
                    .columns = columns,
                    .look = &muted_look,
                    .bytes = cells,
                });
            },
            .table => |*table_rows| if (Table.fitted(block.line, table_rows, columns)) |*table| {
                try table.render(Emitter, emitter, &blocks, block.line, table_rows);
            } else {
                try paragraph(Emitter, emitter, columns, block.line);
                emitter.source(blocks.offset(table_rows.delimiter));
                try paragraph(Emitter, emitter, columns, table_rows.delimiter);
                var lines = table_rows.rows();
                while (lines.next()) |row| {
                    emitter.source(blocks.offset(row));
                    try paragraph(Emitter, emitter, columns, row);
                }
            },
            .heading => |heading| {
                var flow = Flow(Emitter).init(emitter, columns, .{});
                var look = heading_look;
                look.bold = heading.level <= 2;
                look.underline = heading.level == 1;
                try inlines(Flow(Emitter), &flow, look, heading.body);
                try flow.finish();
                const parted = if (blocks.peek()) |next| paint.isBlank(next) else true;
                if (!parted) {
                    emitter.begin();
                    emitter.end();
                }
            },
            .quote => |body| {
                var flow = Flow(Emitter).init(emitter, columns, .{});
                try inlines(Flow(Emitter), &flow, quote_look, body);
                try flow.finish();
            },
            .list_item => |item| {
                var flow = Flow(Emitter).init(emitter, columns, .{
                    .indent = blank(item.depth * 4),
                    .marker = item.marker.shown,
                    .look = accent_look,
                });
                if (item.task_box) |box| try flow.write(&accent_look, box);
                try inlines(Flow(Emitter), &flow, .{}, item.body);
                try flow.finish();
            },
            .paragraph => try paragraph(Emitter, emitter, columns, block.line),
        }
    }
}

fn paragraph(comptime Emitter: type, emitter: *Emitter, columns: usize, line: []const u8) !void {
    var flow = Flow(Emitter).init(emitter, columns, .{});
    try inlines(Flow(Emitter), &flow, .{}, line);
    try flow.finish();
}

fn RowWriter(comptime Emitter: type) type {
    return struct {
        emitter: *Emitter,
        width: usize,
        used: usize = 0,
        painted: usize = 0,
        pending: usize = 0,
        pending_look: Look = .{},

        fn reset(self: *@This()) void {
            self.used = 0;
            self.painted = 0;
            self.pending = 0;
        }

        fn room(self: *const @This()) usize {
            return self.width -| self.used;
        }

        fn place(self: *@This(), look: *const Look, shown: []const u8) !void {
            const body = terminal.width.rowText(shown);
            if (body.len > 0) {
                try self.paintPending();
                self.painted += terminal.width.ofText(body);
                try self.emitter.span(look, body);
            }
            const trailing = terminal.width.ofText(shown[body.len..]);
            if (trailing > 0) {
                self.pending += trailing;
                self.pending_look = look.*;
            }
            self.used += terminal.width.ofText(body) + trailing;
        }

        fn paintPending(self: *@This()) !void {
            try writeBlanks(Emitter, self.emitter, &self.pending_look, self.pending);
            self.painted += self.pending;
            self.pending = 0;
        }

        fn wordRun(self: *const @This(), text: []const u8) usize {
            const room_columns = self.room();
            var bytes: usize = 0;
            var columns: usize = 0;
            while (bytes < text.len) {
                const word = terminal.width.nextWord(text[bytes..], self.width);
                std.debug.assert(word.bytes > 0);
                if (columns + word.columns > room_columns) break;
                bytes += word.bytes;
                columns = @min(columns + word.columns + word.blank_columns, room_columns);
            }
            return bytes;
        }
    };
}

fn writeBlanks(comptime Emitter: type, emitter: *Emitter, look: *const Look, count: usize) !void {
    var left = count;
    while (left > 0) {
        const chunk = @min(left, blanks.len);
        try emitter.span(look, blank(chunk));
        left -= chunk;
    }
}

fn Flow(comptime Emitter: type) type {
    return struct {
        prefix: Prefix,
        row: RowWriter(Emitter),
        prefix_owed: bool = false,
        open: bool = false,
        first: bool = true,

        const Form = enum { whole, alone };

        fn init(emitter: *Emitter, columns: usize, prefix: Prefix) @This() {
            var shown = prefix;
            shown.marker = terminal.width.truncate(prefix.marker, prefixRoom(columns));
            const left = prefixRoom(columns) -| terminal.width.ofText(shown.marker);
            shown.indent = terminal.width.truncate(prefix.indent, left);
            return .{
                .prefix = shown,
                .row = .{ .emitter = emitter, .width = @max(columns -| prefixColumns(&shown), 1) },
            };
        }

        fn write(self: *@This(), look: *const Look, bytes: []const u8) !void {
            var rest = bytes;
            while (rest.len > 0) {
                try self.openRow();
                const room = self.row.room();
                const run = self.row.wordRun(rest);
                if (run == 0) {
                    if (self.row.used > 0) {
                        try self.closeRow();
                        continue;
                    }
                    const cut = terminal.width.truncate(rest, room);
                    std.debug.assert(cut.len > 0);
                    try self.place(look, cut);
                    rest = rest[cut.len..];
                    continue;
                }
                try self.place(look, terminal.width.truncate(rest[0..run], room));
                rest = rest[run..];
            }
        }

        fn place(self: *@This(), look: *const Look, shown: []const u8) !void {
            if (terminal.width.rowText(shown).len > 0) try self.payPrefix(.whole);
            try self.row.place(look, shown);
        }

        fn finish(self: *@This()) !void {
            try self.openRow();
            try self.closeRow();
        }

        fn openRow(self: *@This()) !void {
            if (self.open) return;
            self.row.emitter.begin();
            self.open = true;
            self.row.reset();
            self.prefix_owed = true;
        }

        fn payPrefix(self: *@This(), form: Form) !void {
            if (!self.prefix_owed) return;
            self.prefix_owed = false;
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
            if (form == .alone and shown.len == 0) return;
            try self.row.emitter.span(&.{}, self.prefix.indent);
            try self.row.emitter.span(&look, shown);
        }

        fn closeRow(self: *@This()) !void {
            try self.payPrefix(.alone);
            self.row.emitter.end();
            self.open = false;
        }
    };
}

fn prefixRoom(columns: usize) usize {
    return columns -| @max(@divFloor(columns, 2), 1);
}

fn prefixColumns(prefix: *const Prefix) usize {
    return terminal.width.ofText(prefix.indent) + terminal.width.ofText(prefix.marker);
}

fn plainRow(comptime Emitter: type, emitter: *Emitter, row: *const PlainRow) !void {
    const shown = terminal.width.truncate(row.indent, prefixRoom(row.columns));
    const room = row.columns -| terminal.width.ofText(shown);
    std.debug.assert(room > 0);
    const content = paint.cut(row.bytes, room);
    emitter.begin();
    if (content.kept.len > 0) {
        try emitter.span(&.{}, shown);
        try emitter.span(row.look, content.kept);
    }
    if (content.shortened) try emitter.span(row.look, paint.ellipsis);
    emitter.end();
}

const events_max = 256;

const delimiters_max = 256;

const brackets_max = 64;

const code_run_max = 8;

const parentheses_max = 32;

const token_starts = "`\\<hH";

fn inlines(comptime Sink: type, sink: *Sink, base: Look, text: []const u8) !void {
    var scanner = InlineScanner.init(base, text, .block);
    while (scanner.next()) |span| try sink.write(&span.look, span.bytes);
}

fn tokenAt(text: []const u8, index: usize) ?Token {
    return switch (text[index]) {
        '`' => codeAt(text, index),
        '\\' => escapeAt(text, index),
        '<' => angleAt(text, index),
        'h', 'H' => urlAt(text, index),
        else => unreachable,
    };
}

fn codeAt(text: []const u8, index: usize) Token {
    const start = runEnd(text, index, '`');
    const plain: Token = .{ .kind = .literal, .start = index, .end = start, .after = start };
    if (start - index > code_run_max) return plain;
    var at = start;
    while (std.mem.findScalarPos(u8, text, at, '`')) |end| {
        const after = runEnd(text, end, '`');
        if (after - end == start - index) {
            const content = text[start..end];
            const padded = content[0] == ' ' and content[content.len - 1] == ' ' and
                std.mem.findNone(u8, content, " ") != null;
            const padding: usize = if (padded) 1 else 0;
            return .{
                .kind = .code,
                .start = start + padding,
                .end = end - padding,
                .after = after,
            };
        }
        at = after;
    }
    return plain;
}

fn escapeAt(text: []const u8, index: usize) ?Token {
    if (index + 1 >= text.len or !std.ascii.isPunctuation(text[index + 1])) return null;
    return .{ .kind = .escape, .start = index + 1, .end = index + 2, .after = index + 2 };
}

fn angleAt(text: []const u8, index: usize) ?Token {
    const start = index + 1;
    var at = start;
    while (at < text.len and isSchemeByte(text[at])) at += 1;
    const scheme = at - start;
    if (scheme < 2 or scheme > 32 or !std.ascii.isAlphabetic(text[start])) return null;
    if (at >= text.len or text[at] != ':') return null;
    while (at < text.len) : (at += 1) {
        const byte = text[at];
        if (byte == '>') return .{ .kind = .url, .start = start, .end = at, .after = at + 1 };
        if (byte == '<' or byte <= ' ') return null;
    }
    return null;
}

fn isSchemeByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '.' or byte == '-';
}

fn urlAt(text: []const u8, index: usize) ?Token {
    if (index > 0 and isWord(text[index - 1])) return null;
    const rest = text[index..];
    const scheme = for ([_][]const u8{ "https://", "http://" }) |candidate| {
        if (std.ascii.startsWithIgnoreCase(rest, candidate)) break candidate.len;
    } else return null;
    var span: usize = 0;
    var depth: usize = 0;
    while (span < rest.len and rest[span] > ' ' and rest[span] != '<') : (span += 1) {
        if (rest[span] == '[') depth += 1;
        if (rest[span] == ']') {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    const length = urlLength(rest[0..span]);
    if (length <= scheme) return null;
    return .{ .kind = .url, .start = index, .end = index + length, .after = index + length };
}

fn destinationAt(text: []const u8, index: usize) ?Destination {
    if (index >= text.len or text[index] != '(') return null;
    var at = blankEnd(text, index + 1);
    var url: []const u8 = undefined;
    if (at < text.len and text[at] == '<') {
        const start = at + 1;
        at = start;
        while (at < text.len and text[at] != '>') : (at += 1) {
            if (text[at] == '<') return null;
            if (text[at] == '\\' and escapeAt(text, at) != null) at += 1;
        }
        if (at >= text.len) return null;
        url = text[start..at];
        at += 1;
    } else {
        const start = at;
        var depth: usize = 0;
        while (at < text.len) : (at += 1) {
            const byte = text[at];
            if (byte <= ' ' or byte == 0x7f) break;
            if (byte == '\\' and escapeAt(text, at) != null) {
                at += 1;
            } else if (byte == '(') {
                depth += 1;
                if (depth > parentheses_max) return null;
            } else if (byte == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        if (depth > 0) return null;
        url = text[start..at];
    }
    const url_after = at;
    at = blankEnd(text, at);
    if (at > url_after and at < text.len) {
        if (titleEnd(text, at)) |title_after| at = blankEnd(text, title_after);
    }
    if (at >= text.len or text[at] != ')') return null;
    return .{ .url = url, .after = at + 1 };
}

fn titleEnd(text: []const u8, at: usize) ?usize {
    const closer: u8 = switch (text[at]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var index = at + 1;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\\') {
            index += 1;
        } else if (byte == closer) {
            return index + 1;
        } else if (closer == ')' and byte == '(') {
            return null;
        }
    }
    return null;
}

fn sameUnescaped(left: []const u8, right: []const u8) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        if (left[left_index] == '\\' and escapeAt(left, left_index) != null) left_index += 1;
        if (right[right_index] == '\\' and escapeAt(right, right_index) != null) right_index += 1;
        if (left[left_index] != right[right_index]) return false;
        left_index += 1;
        right_index += 1;
    }
    return left_index == left.len and right_index == right.len;
}

fn blankEnd(text: []const u8, at: usize) usize {
    return std.mem.findNonePos(u8, text, at, " \t") orelse text.len;
}

fn flanks(sides: *const struct { inner: u8, outer: u8 }) bool {
    if (std.ascii.isWhitespace(sides.inner)) return false;
    if (!std.ascii.isPunctuation(sides.inner)) return true;
    return std.ascii.isWhitespace(sides.outer) or std.ascii.isPunctuation(sides.outer);
}

fn runEnd(text: []const u8, at: usize, byte: u8) usize {
    return std.mem.findNonePos(u8, text, at, &.{byte}) orelse text.len;
}

const url_trailing = ".,:;!?'\"*_~";

fn urlLength(url: []const u8) usize {
    var opened: usize = 0;
    var closed: usize = 0;
    for (url) |byte| {
        if (byte == '(') opened += 1;
        if (byte == ')') closed += 1;
    }
    var length = url.len;
    while (length > 0) {
        const last = url[length - 1];
        if (last == ')') {
            if (closed <= opened) break;
            closed -= 1;
        } else if (std.mem.findScalar(u8, url_trailing, last) == null) {
            break;
        }
        length -= 1;
    }
    return length;
}

fn linkLook(url: []const u8) Look {
    var look = link_look;
    if (terminal.View.Sink.linkable(url)) look.url = url;
    return look;
}

fn merged(base: *const Look, over: *const Look) Look {
    return .{
        .role = over.role orelse base.role,
        .url = if (over.url.len > 0) over.url else base.url,
        .bold = base.bold or over.bold,
        .italic = base.italic or over.italic,
        .underline = base.underline or over.underline,
        .strike = base.strike or over.strike,
    };
}

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

fn taskBox(body: []const u8) ?[]const u8 {
    if (body.len < 3 or body[0] != '[' or body[2] != ']') return null;
    if (body[1] != ' ' and body[1] != 'x' and body[1] != 'X') return null;
    if (body.len > 3 and body[3] != ' ') return null;
    return body[0..@min(body.len, 4)];
}

fn headingLevel(rest: []const u8) ?usize {
    var level: usize = 0;
    while (level < rest.len and rest[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < rest.len and rest[level] != ' ') return null;
    return level;
}

fn isRule(rest: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, rest, " \t\r");
    if (trimmed.len < 3) return false;
    const mark = trimmed[0];
    if (mark != '-' and mark != '*' and mark != '_') return false;
    for (trimmed) |byte| if (byte != mark) return false;
    return true;
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn leading(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and line[index] == ' ') index += 1;
    return index;
}

fn blank(count: usize) []const u8 {
    return blanks[0..@min(count, blanks.len)];
}

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
                try std.testing.expectEqual(rows(text, columns), testing.paintedRows(bytes));
            }
        }
    }
}

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

const wide_tables =
    \\- item
    \\  | 你 | b |
    \\  | :-: | - |
    \\  | a你你 | bbbbbb |
    \\  | 😀 | 你 |
;

const partial_tables =
    \\| a | b |
    \\
    \\| a | b |
    \\| --
    \\
    \\| a | b |
    \\| - | -
;

fn painted(
    gpa: std.mem.Allocator,
    text: []const u8,
    columns: usize,
    tint: ?role.Name,
    skip: usize,
) ![]u8 {
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = columns, .rows = 2000, .skip = skip });
    try render(&placement, tint, text);
    return gpa.dupe(u8, try rig.painted());
}

const PaintedWindowOptions = struct {
    columns: usize,
    skip: usize,
    rows_max: usize,
};

fn paintedWindow(
    gpa: std.mem.Allocator,
    text: []const u8,
    options: *const PaintedWindowOptions,
) ![]u8 {
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{
        .columns = options.columns,
        .rows = options.rows_max,
        .skip = options.skip,
    });
    try renderWindow(&placement, text, &.{ .rows_max = options.rows_max });
    return gpa.dupe(u8, try rig.painted());
}

fn frameBody(bytes: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, bytes, terminal.escape.sync_set));
    std.debug.assert(std.mem.endsWith(u8, bytes, terminal.escape.sync_reset));
    return bytes[terminal.escape.sync_set.len .. bytes.len - terminal.escape.sync_reset.len];
}

fn expectPlainRows(
    gpa: std.mem.Allocator,
    text: []const u8,
    columns: usize,
    expected: []const []const u8,
) !void {
    const bytes = try painted(gpa, text, columns, null, 0);
    defer gpa.free(bytes);
    const body = try terminal.testing.plainText(gpa, frameBody(bytes));
    defer gpa.free(body);
    var actual = std.mem.splitSequence(u8, body, "\r\n");
    for (expected) |row| try std.testing.expectEqualStrings(row, actual.next() orelse "");
    try std.testing.expect(actual.next() == null);
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
                const bytes = try paintedWindow(gpa, sample, &.{
                    .columns = columns,
                    .skip = skip,
                    .rows_max = rows_max,
                });
                defer gpa.free(bytes);
                const expected_count = @min(rows_max, total - skip);
                try std.testing.expectEqual(expected_count, testing.paintedRows(bytes));

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
    try expectKinds("````markdown\n````", &.{ .fence_open, .fence_close });
    try expectKinds("````markdown\n```\n````tail\n~~~~\n`````  \nafter", &.{
        .fence_open, .fence_line, .fence_line, .fence_line, .fence_close, .paragraph,
    });
    try expectKinds("```lang`", &.{.paragraph});
    try expectKinds("~~~text\n```\n~~~~", &.{ .fence_open, .fence_line, .fence_close });
}

fn expectKinds(text: []const u8, expected: []const std.meta.Tag(Block.Kind)) !void {
    var blocks: Blocks = .init(text);
    for (expected) |kind| {
        try std.testing.expectEqual(kind, std.meta.activeTag(blocks.next().?.kind));
    }
    try std.testing.expect(blocks.next() == null);
}

test "longer and alternate fences retain inner backticks as code" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, literal_fences, 72, null, 0);
    defer gpa.free(bytes);

    try testing.expectShows(bytes, &.{"**literal backticks**"});
    try testing.expectShows(bytes, &.{"```literal inside tildes"});
    try testing.expectHides(bytes, &.{"after **bold**"});
    try testing.expectShows(bytes, &.{"after "});
    try testing.expectShows(bytes, &.{"\x1b[1mbold"});
}

test "fences accept at most three leading spaces" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, indented_fences, 72, null, 0);
    defer gpa.free(bytes);

    try testing.expectShows(bytes, &.{"**three-space literal**"});
    try testing.expectHides(bytes, &.{"after **four-space bold**"});
    try testing.expectShows(bytes, &.{"\x1b[1mfour-space bold"});
}

test "markdown paints each element in its own role" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, sample, 72, null, 0);
    defer gpa.free(bytes);
    const code = comptime role.sequence(.code);
    const muted = comptime role.sequence(.muted);
    const accent = comptime role.sequence(.accent);
    const heading = comptime role.sequence(.heading);
    const link = comptime role.sequence(.link);

    const first = heading ++ "\x1b[1m\x1b[4mHeading one";
    try testing.expectShows(bytes, &.{first});
    try std.testing.expect(std.mem.findScalar(u8, bytes, '#') == null);
    try testing.expectShows(bytes, &.{heading ++ "Heading three"});
    try testing.expectShows(bytes, &.{heading ++ "\x1b[1mtwo"});
    try testing.expectShows(bytes, &.{code});
    try testing.expectShows(bytes, &.{"  " ++ code});
    try testing.expectShows(bytes, &.{"const answer = 42;"});
    try testing.expectShows(bytes, &.{muted ++ "```zig"});
    try testing.expectShows(bytes, &.{accent ++ "- "});
    try testing.expectShows(bytes, &.{muted ++ "\x1b[3ma quoted"});
    try testing.expectShows(bytes, &.{"──"});
    try testing.expectShows(bytes, &.{"3. "});
    try testing.expectShows(bytes, &.{accent ++ "[ ]"});
    try testing.expectShows(bytes, &.{link ++ "\x1b[4m"});
    try testing.expectShows(bytes, &.{"https://example.com"});
    const markers = [_][]const u8{ "**", "~~", "*italic*", "`inline code`", "[labelled]" };
    for (markers) |mark| try testing.expectHides(bytes, &.{mark});
    try testing.expectShows(bytes, &.{"\x1b[1mbold"});
    try testing.expectShows(bytes, &.{"\x1b[1m\x1b[3mitalic"});
    try testing.expectShows(bytes, &.{"snake_case_name"});
}

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
    try testing.expectShows(bytes, &.{"\x1b[1mName"});
    try std.testing.expect(std.mem.find(
        u8,
        bytes,
        comptime role.sequence(.muted) ++ "┌",
    ) != null);
}

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

test "a code span outside a table keeps backslash before pipe" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "Use `cat \\| grep` here.", 40, &.{
        "Use cat \\| grep here.",
    });
}

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

test "a huge table cell wraps to its exact row count" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "| a |\n| - |\n| ");
    for (0..40_000) |_| try text.appendSlice(gpa, "word ");
    try text.appendSlice(gpa, "|");
    try std.testing.expectEqual(@as(usize, 13_338), rows(text.items, 20));

    text.clearRetainingCapacity();
    try text.appendSlice(gpa, "| a |\n| - |\n| ");
    try text.appendNTimes(gpa, 'a', 100_000);
    try text.appendSlice(gpa, " |");
    try std.testing.expectEqual(@as(usize, 6_254), rows(text.items, 20));
}

test "a cell wraps at a look boundary when the column fills" {
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

test "a narrow code row marks its cut" {
    const gpa = std.testing.allocator;
    const text =
        \\```zig
        \\const a = 1;
        \\```
    ;
    try expectPlainRows(gpa, text, 6, &.{ "```zig", "  con…", "```" });
    try expectPlainRows(gpa, text, 3, &.{ "``…", "…", "```" });
    try expectPlainRows(gpa, text, 1, &.{ "…", "…", "…" });

    const wide =
        \\```zig
        \\你x = 1;
        \\```
    ;
    try expectPlainRows(gpa, wide, 4, &.{ "```…", "…", "```" });
}

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

    const wrapped = try painted(gpa, "| a你你 | bbbbbb |\n| - | - |\n| c | d |", 16, null, 0);
    defer gpa.free(wrapped);
    try testing.expectShows(wrapped, &.{"\x1b[1m你"});

    for ([_][]const u8{ tables, wide_tables, partial_tables }) |text| {
        for ([_]usize{ 72, 40, 24, 16, 13, 11, 10, 9 }) |columns| {
            const bytes = try painted(gpa, text, columns, null, 0);
            defer gpa.free(bytes);
            const body = try terminal.testing.plainText(gpa, frameBody(bytes));
            defer gpa.free(body);
            var width: ?usize = null;
            var painted_rows = std.mem.splitSequence(u8, body, "\r\n");
            while (painted_rows.next()) |row| {
                const grid = std.mem.trimStart(u8, row, " ");
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

test "a table keeps the indentation of its source" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "  | a | b |\n  | - | - |\n  | c | d |", 12, &.{
        "  ┌───┬───┐",
        "  │ a │ b │",
        "  ├───┼───┤",
        "  │ c │ d │",
        "  └───┴───┘",
    });
    const bytes = try painted(gpa, "  | a | b |\n  | - | - |\n  | c | d |", 10, null, 0);
    defer gpa.free(bytes);
    try testing.expectHides(bytes, &.{"┌"});
}

test "a table below its narrowest grid stays prose" {
    const gpa = std.testing.allocator;
    const text = "| a | b |\n| - | - |\n| c | d |";
    const bytes = try painted(gpa, text, 8, null, 0);
    defer gpa.free(bytes);
    try testing.expectHides(bytes, &.{"┌"});
    try std.testing.expect(std.mem.findScalar(u8, bytes, '|') != null);
}

test "a table appears only when its delimiter row is complete" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "| a | b |", "| a | b |\n| --" }) |text| {
        const bytes = try painted(gpa, text, 40, null, 0);
        defer gpa.free(bytes);
        try testing.expectHides(bytes, &.{"┌"});
    }
    const bytes = try painted(gpa, "| a | b |\n| - | -", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{"┌"});
    try testing.expectShows(bytes, &.{"└"});
    try testing.expectHides(bytes, &.{"├"});
}

test "the column fit matches a cell-by-cell shrink" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7ab1e5);
    const random = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    for (0..2000) |_| {
        const count = random.intRangeAtMost(usize, 1, Table.count_max);
        var widths: [Table.count_max]usize = undefined;
        for (widths[0..count]) |*width| width.* = random.intRangeAtMost(usize, 1, 40);
        const floor = 1 + 4 * count;
        const columns = random.intRangeAtMost(usize, floor, floor + 60);

        text.clearRetainingCapacity();
        try text.append(gpa, '|');
        for (widths[0..count]) |width| {
            try text.append(gpa, ' ');
            try text.appendNTimes(gpa, 'a', width);
            try text.appendSlice(gpa, " |");
        }
        try text.appendSlice(gpa, "\n|");
        for (0..count) |_| try text.appendSlice(gpa, "-|");

        var total = 1 + 3 * count;
        for (widths[0..count]) |width| total += width;
        while (total > columns) : (total -= 1) {
            var widest: usize = 0;
            for (widths[0..count], 0..) |width, index| {
                if (width > widths[widest]) widest = index;
            }
            widths[widest] -= 1;
        }

        rig.out.clearRetainingCapacity();
        rig.view.forget();
        const placement = try rig.begin(&.{ .columns = columns, .rows = 1 });
        try renderWindow(&placement, text.items, &.{ .rows_max = 1 });
        const border = try terminal.testing.plainText(gpa, try rig.painted());
        defer gpa.free(border);
        const inner = border["┌".len .. border.len - "┐".len];
        var segments = std.mem.splitSequence(u8, inner, "┬");
        for (widths[0..count]) |width| {
            try std.testing.expectEqual(width + 2, terminal.width.ofText(segments.next().?));
        }
        try std.testing.expect(segments.next() == null);
    }
}

test "a delimiter row is dashes with optional alignment colons" {
    for ([_][]const u8{
        "| a |\n| --- |",
        "| a |\n|-|",
        "| a | b | c |\n  | :--- | ---: | :-: |",
    }) |text| try expectKinds(text, &.{.table});
    for ([_][]const u8{ "| a |\n| --x |", "| a |\n|  |", "| a |\n| :: |", "| a |\n|" }) |text| {
        try expectKinds(text, &.{ .paragraph, .paragraph });
    }
    try expectKinds("| a |\n---", &.{ .paragraph, .rule });

    const headers = [_]struct { text: []const u8, count: usize }{
        .{ .text = "| a | b |", .count = 2 },
        .{ .text = "| a | b", .count = 2 },
        .{ .text = "|", .count = 1 },
        .{ .text = "| `a \\| b` | c |", .count = 2 },
        .{ .text = "| a \\| b | c |", .count = 2 },
        .{ .text = "| a | b\\|", .count = 2 },
        .{ .text = "| a \\\\| b | c |", .count = 3 },
    };
    for (headers) |header| {
        var text_buffer: [64]u8 = undefined;
        var text: std.Io.Writer = .fixed(&text_buffer);
        try text.print("{s}\n|", .{header.text});
        for (0..header.count) |_| try text.writeAll("-|");
        var blocks: Blocks = .init(text.buffered());
        try std.testing.expectEqual(header.count, blocks.next().?.kind.table.count);
    }
}

test "a prefix leaves room for the body it pushes right" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "- abc", "    - abc", "12. abc" }) |text| {
        for ([_]usize{ 1, 2 }) |columns| {
            const bytes = try painted(gpa, text, columns, null, 0);
            defer gpa.free(bytes);
            for ("abc") |letter| {
                try std.testing.expect(std.mem.findScalar(u8, bytes, letter) != null);
            }
        }
    }
}

test "a block breaks its rows between words" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "one two three four", 12, &.{ "one two", "three four" });

    try expectPlainRows(gpa, "- alpha beta gamma", 12, &.{ "- alpha beta", "  gamma" });

    try expectPlainRows(gpa, "ab abcdefghijkl", 6, &.{ "ab", "abcdef", "ghijkl" });

    try expectPlainRows(gpa, "one **two** three four", 12, &.{ "one two", "three four" });
}

test "a row never ends on the blank it breaks at" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "aaa **bbbb**", 6, &.{ "aaa", "bbbb" });
    try expectPlainRows(gpa, "one two `code` three", 6, &.{ "one", "two", "code", "three" });
    try expectPlainRows(gpa, "- [ ] a task", 20, &.{"- [ ] a task"});
    try expectPlainRows(gpa, "a **b** c", 20, &.{"a b c"});

    try expectPlainRows(gpa, "- ", 20, &.{"-"});
    try expectPlainRows(gpa, "-   ", 20, &.{"-"});
    try expectPlainRows(gpa, "  - deep\n  - ", 20, &.{ "    - deep", "    -" });
    try expectPlainRows(gpa, "```\n\ncode\n\n```", 20, &.{ "```", "", "  code", "", "```" });
}

test "a word that crosses a look boundary breaks at the boundary" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "aaa **bb**bbbb", 6, &.{ "aaa bb", "bbbb" });
}

test "a styled wide glyph wraps rather than degrading" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "abc**你**", 4, null, 0);
    defer gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 2), testing.paintedRows(bytes));
    try testing.expectShows(bytes, &.{"你"});
    try testing.expectHides(bytes, &.{"�"});
}

test "a CRLF line sheds its carriage return" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "# Title\r\n\r\n**bold** text\r\n", 20, &.{
        "Title",
        "",
        "bold text",
        "",
    });

    const bytes = try painted(
        gpa,
        "```zig\r\nconst a = 1;\r\n```\r\n| a |\r\n| - |\r\n",
        20,
        null,
        0,
    );
    defer gpa.free(bytes);
    try testing.expectHides(bytes, &.{"�"});
    try testing.expectShows(bytes, &.{"const a = 1;"});
    try testing.expectShows(bytes, &.{"┌"});
}

test "a quote paints with no border glyph" {
    const gpa = std.testing.allocator;
    const text = "> **_Note:_** a quoted line\n> and its second line";
    try expectPlainRows(gpa, text, 30, &.{ "Note: a quoted line", "and its second line" });

    const bytes = try painted(gpa, text, 30, null, 0);
    defer gpa.free(bytes);
    try testing.expectHides(bytes, &.{"│"});
    const nested = comptime role.sequence(.muted) ++ "\x1b[4m\x1b[3mNote:";
    try testing.expectShows(bytes, &.{nested});
    const intensity_clash = comptime role.sequence(.muted) ++ "\x1b[1m";
    try testing.expectHides(bytes, &.{intensity_clash});
}

test "nested inline markers all shed their marks" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "**_both_** and *a **deep** run*", 40, &.{
        "both and a deep run",
    });
    try expectPlainRows(gpa, "***all three*** of them", 40, &.{"all three of them"});
    try expectPlainRows(gpa, "a **b _c** d_ e", 40, &.{"a b _c d_ e"});
    try expectPlainRows(gpa, "a *b\t*c* d", 40, &.{"a *b c d"});

    const bytes = try painted(gpa, "**_both_**", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{"\x1b[1m\x1b[3mboth"});
}

test "a code span hides an emphasis closer and a link label closer" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "**a `**` b** and `c`", 40, &.{"a ** b and c"});
    try expectPlainRows(gpa, "[a `]` b](https://x.y) and `c`", 40, &.{"a ] b and c"});
    try expectPlainRows(gpa, "[a`](b)`", 40, &.{"[a](b)"});
}

test "a code span closes only at a backtick run of its own length" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "a ``b`c`` d", 40, &.{"a b`c d"});
    try expectPlainRows(gpa, "``a`b", 40, &.{"``a`b"});
    try expectPlainRows(gpa, "[run ``x``](https://x.y) or `y`", 40, &.{"run x or y"});
}

test "a code span delimiter holds at most eight backticks" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "a ````````x```````` b", 40, &.{"a x b"});
    try expectPlainRows(gpa, "a `````````x````````` b", 40, &.{"a `````````x````````` b"});
}

test "a code span drops one padding space at each end" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "x `` `a` `` y", 40, &.{"x `a` y"});
    try expectPlainRows(gpa, "x ` a` y", 40, &.{"x  a y"});
    try expectPlainRows(gpa, "x ` ` y", 40, &.{"x   y"});
}

test "a URL keeps a backtick as literal text" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "[a](x`y) and `c`", 40, &.{"a (x`y) and c"});
    try expectPlainRows(gpa, "**see https://x.y/a`b** and `c`", 40, &.{
        "see https://x.y/a`b and c",
    });
    try expectPlainRows(gpa, "[https://x.y/a`b](c) and `d`", 40, &.{
        "https://x.y/a`b (c) and d",
    });
    try expectPlainRows(gpa, "[a https://x.y/b`c] and [d](e) `f`", 40, &.{
        "[a https://x.y/b`c] and d (e) f",
    });
    try expectPlainRows(gpa, "**see https://x.y/a`b**, and `c`", 40, &.{
        "see https://x.y/a`b, and c",
    });
    try expectPlainRows(gpa, "[**https://x.y/a`b**](u)", 40, &.{"https://x.y/a`b (u)"});
    try expectPlainRows(gpa, "_see https://x.y/a_b`c_ and `d`", 40, &.{
        "see https://x.y/a_b`c and d",
    });
    try expectPlainRows(gpa, "*see https://x.y/a**b`c* and `d`", 40, &.{
        "see https://x.y/a**b`c and d",
    });
}

test "an emphasis run closes after a URL in a link" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "[**https://x.y**](https://x.y)", 40, &.{"https://x.y"});
}

test "an emphasis run closes after a link URL" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "**[a](x`y)** and `c`", 40, &.{"a (x`y) and c"});
    try expectPlainRows(gpa, "**[a](https://x.y)`**` b** c", 40, &.{"a** b c"});
    try expectPlainRows(gpa, "**[a](https://x.y)**'s", 40, &.{"a's"});

    const bytes = try painted(gpa, "**[a](x`y)** and `c`", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{"\x1b[1m"});
}

test "an emphasis run crosses no link boundary" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "*a [b* c](https://x.y)", 40, &.{"*a b* c"});
}

test "a strong run nests inside an emphasis run" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "*foo**bar**baz*", 40, &.{"foobarbaz"});

    const bytes = try painted(gpa, "*foo**bar**baz*", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{"\x1b[1m\x1b[3mbar"});
}

test "a link label holds a balanced bracket pair" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "[a [b] c](https://x.y)", 40, &.{"a [b] c"});
}

test "a link destination follows the CommonMark rules" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "[w](https://x.y/a_(b)) and [t](https://x.y \"title\")", 40, &.{
        "w and t",
    });
    try expectPlainRows(gpa, "[a](b c) and [d](<e f>)", 40, &.{"[a](b c) and d (e f)"});

    const bytes = try painted(gpa, "[w](https://x.y/a_(b))", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{"\x1b]8;;https://x.y/a_(b)\x1b\\w"});
}

test "a link URL drops its backslash escapes" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "[a](https://x.y/a\\_b) and [c](./x\\_y.md)", 40, &.{
        "a and c (./x_y.md)",
    });

    const bytes = try painted(gpa, "[a](https://x.y/a\\_b)", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{terminal.escape.link_set ++ "https://x.y/a_b" ++
        terminal.escape.string_end});
}

test "a link keeps its own unescaped URL after a later link" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "[a ](https://x.y/a\\_b)[c](https://x.y/c\\_d)", 40, null, 0);
    defer gpa.free(bytes);
    const set = terminal.escape.link_set;
    const end = terminal.escape.string_end;
    try testing.expectShows(bytes, &.{set ++ "https://x.y/a_b" ++ end ++ " "});
    try testing.expectHides(bytes, &.{set ++ "https://x.y/c_d" ++ end ++ " "});
}

test "a long escaped link URL links to its unescaped address" {
    const gpa = std.testing.allocator;
    const escaped = "https://x.y/" ++ core.text.repeat("a\\_", 1000);
    const address = "https://x.y/" ++ core.text.repeat("a_", 1000);
    const bytes = try painted(gpa, "[a](" ++ escaped ++ ")", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{terminal.escape.link_set ++ address ++
        terminal.escape.string_end});
}

test "a link label that shows its URL hides the URL note" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "[a\\_b.md](a\\_b.md) and [a_b.md](a\\_b.md)", 40, &.{
        "a_b.md and a_b.md",
    });
}

test "a backslash escapes a punctuation mark" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "\\*a\\* and \\[b](c) and \\a", 40, &.{"*a* and [b](c) and \\a"});
}

test "an angle autolink paints as a hyperlink without its brackets" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "see <https://x.y/a> or <b> or a<c:d", 40, &.{
        "see https://x.y/a or <b> or a<c:d",
    });

    const bytes = try painted(gpa, "<https://x.y/a>", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{"\x1b]8;;https://x.y/a\x1b\\https://x.y/a"});
}

test "a full delimiter stack leaves later marks literal" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..delimiters_max) |_| try text.appendSlice(gpa, "*a ");
    try text.appendSlice(gpa, "*b*");

    const bytes = try painted(gpa, text.items, 2000, null, 0);
    defer gpa.free(bytes);
    try testing.expectHides(bytes, &.{"\x1b[3m"});
    const body = try terminal.testing.plainText(gpa, frameBody(bytes));
    defer gpa.free(body);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, body, " "), "*a *b*"));
    try std.testing.expectEqual(rows(text.items, 2000), testing.paintedRows(bytes));
}

test "a line with more links than the event buffer keeps its last links literal" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..@divExact(events_max, 2) + 2) |_| try text.appendSlice(gpa, "[a](b) ");

    const bytes = try painted(gpa, text.items, 3000, null, 0);
    defer gpa.free(bytes);
    const body = try terminal.testing.plainText(gpa, frameBody(bytes));
    defer gpa.free(body);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "[a](b)"));
    try std.testing.expect(std.mem.startsWith(u8, body, "a (b) "));
    const shown = std.mem.trimEnd(u8, body, " ");
    try std.testing.expect(std.mem.endsWith(u8, shown, "a (b) [a](b) [a](b)"));
    try std.testing.expectEqual(rows(text.items, 3000), testing.paintedRows(bytes));
}

test "a full bracket stack forgets its oldest open bracket" {
    const gpa = std.testing.allocator;
    const opened = core.text.repeat("[", brackets_max + 6);
    try expectPlainRows(gpa, opened ++ "[a](https://x.y)", 200, &.{opened ++ "a"});

    const bytes = try painted(gpa, opened ++ "[a](https://x.y)", 200, null, 0);
    defer gpa.free(bytes);
    const link = terminal.escape.link_set ++ "https://x.y" ++ terminal.escape.string_end ++ "a" ++
        terminal.escape.link_reset;
    try testing.expectShows(bytes, &.{link});
}

test "an open bracket before a link stays literal" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "The range [0, 1) holds it, see [docs](https://x.y).", 60, &.{
        "The range [0, 1) holds it, see docs.",
    });
    try expectPlainRows(gpa, "[a [b](https://x.y) c](https://z.w)", 60, &.{
        "[a b c](https://z.w)",
    });
    try expectPlainRows(gpa, "[a [(x)", 60, &.{"[a [(x)"});
}

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
    try testing.expectShows(bytes, &.{labelled});
    const bare = "\x1b]8;;https://example.com/b\x1b\\https://example.com/b\x1b]8;;\x1b\\";
    try testing.expectShows(bytes, &.{bare});
    try testing.expectHides(bytes, &.{"\x1b]8;;./x.md"});
    try testing.expectHides(bytes, &.{"\x1b]8;;javascript:"});

    const upper = try painted(gpa, "HTTPS://X.Y/a", 40, null, 0);
    defer gpa.free(upper);
    try testing.expectShows(upper, &.{"\x1b]8;;HTTPS://X.Y/a\x1b\\"});
}

test "a bare URL the sink refuses keeps its text and its look" {
    const gpa = std.testing.allocator;
    const text = "at https://x.y/\u{00e9}rest today";
    try expectPlainRows(gpa, text, 40, &.{"at https://x.y/érest today"});

    const bytes = try painted(gpa, text, 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectHides(bytes, &.{terminal.escape.link_set});
    const styled = comptime role.sequence(.link) ++
        "\x1b[4mhttps://x.y/\u{00e9}rest\x1b[0m";
    try testing.expectShows(bytes, &.{styled});
}

test "a wrapped link closes on each of its rows" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "[a long clickable label](https://example.com/a)", 10, null, 0);
    defer gpa.free(bytes);

    const opens = std.mem.count(u8, bytes, "\x1b]8;;https://example.com/a\x1b\\");
    try std.testing.expectEqual(testing.paintedRows(bytes), opens);
    try std.testing.expectEqual(opens, std.mem.count(u8, bytes, terminal.escape.link_reset));
}

test "a bare URL ends before the punctuation behind it" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { text: []const u8, url: []const u8 }{
        .{ .text = "https://x.y", .url = "https://x.y" },
        .{ .text = "https://x.y.", .url = "https://x.y" },
        .{ .text = "https://x.y),", .url = "https://x.y" },
        .{ .text = "https://x.y/(a)", .url = "https://x.y/(a)" },
        .{ .text = "https://x.y/(a))", .url = "https://x.y/(a)" },
    };
    for (cases) |case| {
        const bytes = try painted(gpa, case.text, 40, null, 0);
        defer gpa.free(bytes);
        var buffer: [64]u8 = undefined;
        const link = try std.mem.print(
            &buffer,
            terminal.escape.link_set ++ "{s}" ++ terminal.escape.string_end ++ "{s}" ++
                terminal.escape.link_reset,
            .{ case.url, case.url },
        );
        try testing.expectShows(bytes, &.{link});
    }
}

test "a bare URL keeps the brackets that it balances" {
    const gpa = std.testing.allocator;
    inline for ([_][]const u8{ "http://[::1]:8080/x", "https://x.y/?a[]=1" }) |url| {
        const bytes = try painted(gpa, "see " ++ url ++ " now", 40, null, 0);
        defer gpa.free(bytes);
        const link = terminal.escape.link_set ++ url ++ terminal.escape.string_end ++ url ++
            terminal.escape.link_reset;
        try testing.expectShows(bytes, &.{link});
    }
    try expectPlainRows(gpa, "[see https://x.y/a[1]](https://z.w)", 40, &.{"see https://x.y/a[1]"});
}

test "a heading with no body paints an empty row" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "###\ntext", 20, &.{ "", "", "text" });

    const bytes = try painted(gpa, "######", 20, null, 0);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), testing.paintedRows(bytes));
    try std.testing.expect(std.mem.findScalar(u8, bytes, '#') == null);
}

test "an unclosed bold marker stays literal" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "**bold", 40, null, 0);
    defer gpa.free(bytes);

    try testing.expectShows(bytes, &.{"**bold"});
    try testing.expectHides(bytes, &.{"\x1b[1m"});
    try testing.expectHides(bytes, &.{"\x1b[3m"});
}

test "an unequal opener and closer leave their extra marks literal" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "**bold*", 40, &.{"*bold"});
    try expectPlainRows(gpa, "*it**", 40, &.{"it*"});

    const bytes = try painted(gpa, "**bold*", 40, null, 0);
    defer gpa.free(bytes);
    try testing.expectShows(bytes, &.{"\x1b[3mbold"});
    try testing.expectHides(bytes, &.{"\x1b[1m"});
}

test "a line of unmatched brackets renders the rows it counts" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, '[', 20_000);
    for (0..10_000) |_| try text.appendSlice(gpa, "[](");

    const bytes = try painted(gpa, text.items, 80, null, 0);
    defer gpa.free(bytes);
    try std.testing.expectEqual(rows(text.items, 80), testing.paintedRows(bytes));
    try testing.expectShows(bytes, &.{"[[["});
}

test "a tinted block renders muted and italic throughout" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, sample, 72, .muted, 0);
    defer gpa.free(bytes);

    inline for ([_]role.Name{ .heading, .code, .accent, .link }) |name| {
        try testing.expectHides(bytes, &.{role.sequence(name)});
    }
    const muted = comptime role.sequence(.muted) ++ "\x1b[3m";
    try testing.expectShows(bytes, &.{muted});
    try testing.expectShows(bytes, &.{"- "});
    const emphasized = comptime role.sequence(.muted) ++ "\x1b[4m\x1b[3mHeading";
    const emphasized_underlined =
        comptime role.sequence(.muted) ++ "\x1b[21m\x1b[3mHeading one";
    try testing.expectShows(bytes, &.{emphasized});
    try testing.expectShows(bytes, &.{emphasized_underlined});
    const intensity_clash = comptime role.sequence(.muted) ++ "\x1b[1m";
    try testing.expectHides(bytes, &.{intensity_clash});
}

test "markdown holds row parity over arbitrary marker soup" {
    const gpa = std.testing.allocator;
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
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    for (0..400) |_| {
        text.clearRetainingCapacity();
        for (0..random.uintLessThan(usize, 40)) |_| {
            try text.appendSlice(gpa, tokens[random.uintLessThan(usize, tokens.len)]);
        }
        for ([_]usize{ 1, 2, 3, 5, 9, 40, 100 }) |columns| {
            rig.out.clearRetainingCapacity();
            rig.view.forget();
            const placement = try rig.begin(&.{ .columns = columns, .rows = 2000 });
            try render(&placement, null, text.items);
            try std.testing.expectEqual(
                rows(text.items, columns),
                testing.paintedRows(try rig.painted()),
            );
        }
    }
}

test "a clipped markdown block shows its bottom rows" {
    const gpa = std.testing.allocator;
    const columns = 40;
    const total = rows(sample, columns);
    const bytes = try painted(gpa, sample, columns, null, total - 4);
    defer gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 4), testing.paintedRows(bytes));
    try testing.expectHides(bytes, &.{"Heading one"});
}

test "the block iterator classifies each line once for every walker" {
    const text =
        \\```zig
        \\const a = 1;
        \\```
        \\
        \\---
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\| 3 | 4 |
        \\## Title
        \\> > quoted
        \\  - [x] done
        \\plain words
        \\```
        \\open
    ;
    var blocks: Blocks = .init(text);
    const expected = [_]std.meta.Tag(Block.Kind){
        .fence_open, .fence_line, .fence_close, .blank,     .rule,       .table,
        .heading,    .quote,      .list_item,   .paragraph, .fence_open, .fence_line,
    };
    for (expected) |kind| {
        const block = blocks.next().?;
        try std.testing.expectEqual(kind, std.meta.activeTag(block.kind));
        switch (block.kind) {
            .table => |*table_rows| {
                try std.testing.expectEqual(@as(usize, 2), table_rows.count);
                try std.testing.expectEqualStrings("|---|---|", table_rows.delimiter);
                var lines = table_rows.rows();
                try std.testing.expectEqualStrings("| 1 | 2 |", lines.next().?);
                try std.testing.expectEqualStrings("| 3 | 4 |", lines.next().?);
                try std.testing.expect(lines.next() == null);
            },
            .heading => |heading| {
                try std.testing.expectEqual(@as(usize, 2), heading.level);
                try std.testing.expectEqualStrings("Title", heading.body);
            },
            .quote => |body| try std.testing.expectEqualStrings("quoted", body),
            .list_item => |item| {
                try std.testing.expectEqual(@as(usize, 1), item.depth);
                try std.testing.expectEqualStrings("[x] ", item.task_box.?);
                try std.testing.expectEqualStrings("done", item.body);
            },
            else => {},
        }
    }
    try std.testing.expect(blocks.next() == null);

    var bare: Blocks = .init("| a |\n|---|");
    const shape = bare.next().?.kind.table;
    var empty = shape.rows();
    try std.testing.expect(empty.next() == null);
}

test "inline rendering matches the CommonMark example corpus" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const examples = try std.json.parseFromSliceLeaky(
        []const CorpusExample,
        arena,
        @embedFile("commonmark_spec.json"),
        .{ .ignore_unknown_fields = true },
    );
    var example_arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer example_arena_state.deinit();
    const example_arena = example_arena_state.allocator();
    var checked: usize = 0;
    var mismatches: usize = 0;
    for (examples) |*example| {
        defer _ = example_arena_state.reset(.retain_capacity);
        const line = corpusLine(example) orelse continue;
        const expected = try expectedInline(example_arena, &.{
            .html = example.html,
            .markdown = line,
        }) orelse continue;
        const actual = try renderedInline(example_arena, line);
        const deviates = std.mem.findScalar(usize, &corpus_deviations, example.example) != null;
        checked += 1;
        if (std.mem.eql(u8, expected, actual) != deviates) continue;
        mismatches += 1;
        std.debug.print("CommonMark example {d} {s}: {s}\n  expected: {s}\n  rendered: {s}\n", .{
            example.example,
            if (deviates) "matches but is a listed deviation" else "differs",
            line,
            expected,
            actual,
        });
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    try std.testing.expect(checked >= 200);
}

const corpus_deviations = space_is_ascii ++ empty_label_shows_url ++ empty_url_hides_target ++
    bare_url_links ++ email_autolink_missing;

const space_is_ascii = [_]usize{353};
const empty_label_shows_url = [_]usize{484};
const empty_url_hides_target = [_]usize{ 485, 486 };
const bare_url_links = [_]usize{ 602, 608, 611 };
const email_autolink_missing = [_]usize{ 604, 605 };

const corpus_sections = [_][]const u8{
    "Backslash escapes",
    "Code spans",
    "Emphasis and strong emphasis",
    "Links",
    "Autolinks",
    "Textual content",
    "Inlines",
};

const CorpusExample = struct {
    markdown: []const u8,
    html: []const u8,
    example: usize,
    section: []const u8,
};

const CorpusMarks = struct {
    href: ?[]const u8 = null,
    strong: bool = false,
    emphasis: bool = false,
    code: bool = false,

    fn eql(self: *const CorpusMarks, other: *const CorpusMarks) bool {
        const same_href = if (self.href) |href|
            other.href != null and std.mem.eql(u8, href, other.href.?)
        else
            other.href == null;
        return same_href and self.strong == other.strong and
            self.emphasis == other.emphasis and self.code == other.code;
    }
};

const CorpusWriter = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    marks: CorpusMarks = .{},

    fn text(self: *CorpusWriter, marks: *const CorpusMarks, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (!self.marks.eql(marks)) {
            try self.close();
            try self.open(marks);
        }
        try self.out.appendSlice(self.arena, bytes);
    }

    fn open(self: *CorpusWriter, marks: *const CorpusMarks) !void {
        if (marks.href) |href| try self.out.print(self.arena, "<a href=\"{s}\">", .{href});
        if (marks.strong) try self.out.appendSlice(self.arena, "<strong>");
        if (marks.emphasis) try self.out.appendSlice(self.arena, "<em>");
        if (marks.code) try self.out.appendSlice(self.arena, "<code>");
        self.marks = marks.*;
    }

    fn close(self: *CorpusWriter) !void {
        if (self.marks.code) try self.out.appendSlice(self.arena, "</code>");
        if (self.marks.emphasis) try self.out.appendSlice(self.arena, "</em>");
        if (self.marks.strong) try self.out.appendSlice(self.arena, "</strong>");
        if (self.marks.href != null) try self.out.appendSlice(self.arena, "</a>");
        self.marks = .{};
    }

    fn finish(self: *CorpusWriter) ![]const u8 {
        self.out.items.len = std.mem.trimEnd(u8, self.out.items, " ").len;
        try self.close();
        return self.out.items;
    }
};

fn corpusLine(example: *const CorpusExample) ?[]const u8 {
    for (corpus_sections) |section| {
        if (std.mem.eql(u8, section, example.section)) break;
    } else return null;
    const markdown = std.mem.trimEnd(u8, example.markdown, "\n");
    if (std.mem.findScalar(u8, markdown, '\n') != null) return null;
    const html = example.html;
    if (!std.mem.startsWith(u8, html, "<p>") or !std.mem.endsWith(u8, html, "</p>\n")) return null;
    if (std.mem.count(u8, html, "\n") != 1) return null;
    var search: usize = 0;
    while (std.mem.findScalarPos(u8, markdown, search, '&')) |ampersand| {
        search = ampersand + 1;
        const maybe_end = std.mem.findNonePos(u8, markdown, search, entity_name_bytes);
        const end = maybe_end orelse continue;
        if (end > search and markdown[end] == ';') return null;
    }
    return std.mem.trim(u8, markdown, " \t");
}

const entity_name_bytes = "#0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn expectedInline(
    arena: std.mem.Allocator,
    example: *const struct { html: []const u8, markdown: []const u8 },
) !?[]const u8 {
    const html = example.html;
    const inner = html["<p>".len .. html.len - "</p>\n".len];
    var writer: CorpusWriter = .{ .arena = arena };
    var marks: CorpusMarks = .{};
    var strong_depth: usize = 0;
    var emphasis_depth: usize = 0;
    var index: usize = 0;
    while (index < inner.len) {
        if (inner[index] == '<') {
            const close = std.mem.findScalarPos(u8, inner, index, '>') orelse return null;
            const tag = inner[index + 1 .. close];
            index = close + 1;
            if (std.mem.eql(u8, tag, "em")) {
                emphasis_depth += 1;
            } else if (std.mem.eql(u8, tag, "/em")) {
                emphasis_depth -= 1;
            } else if (std.mem.eql(u8, tag, "strong")) {
                strong_depth += 1;
            } else if (std.mem.eql(u8, tag, "/strong")) {
                strong_depth -= 1;
            } else if (std.mem.eql(u8, tag, "code")) {
                marks.code = true;
            } else if (std.mem.eql(u8, tag, "/code")) {
                marks.code = false;
            } else if (std.mem.startsWith(u8, tag, "a href=\"")) {
                if (std.mem.find(u8, example.markdown, tag) != null) return null;
                const start = "a href=\"".len;
                const end = std.mem.findScalarPos(u8, tag, start, '"') orelse return null;
                marks.href = try decodedHref(arena, tag[start..end]);
            } else if (std.mem.eql(u8, tag, "/a")) {
                marks.href = null;
            } else {
                return null;
            }
            marks.strong = strong_depth > 0;
            marks.emphasis = emphasis_depth > 0;
            continue;
        }
        const end = std.mem.findAnyPos(u8, inner, index, "<&\t") orelse inner.len;
        if (end > index) {
            try writer.text(&marks, inner[index..end]);
            index = end;
            continue;
        }
        if (inner[index] == '\t') {
            try writer.text(&marks, " ");
            index += 1;
            continue;
        }
        const entity = htmlEntity(inner[index..]) orelse return null;
        try writer.text(&marks, entity.shown);
        index += entity.source.len;
    }
    return try writer.finish();
}

const HtmlEntity = struct { source: []const u8, shown: []const u8 };

fn htmlEntity(text: []const u8) ?HtmlEntity {
    const entities = [_]HtmlEntity{
        .{ .source = "&amp;", .shown = "&" },
        .{ .source = "&lt;", .shown = "<" },
        .{ .source = "&gt;", .shown = ">" },
        .{ .source = "&quot;", .shown = "\"" },
    };
    for (entities) |entity| if (std.mem.startsWith(u8, text, entity.source)) return entity;
    return null;
}

fn decodedHref(arena: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < encoded.len) {
        if (htmlEntity(encoded[index..])) |entity| {
            try out.appendSlice(arena, entity.shown);
            index += entity.source.len;
        } else if (encoded[index] == '%' and index + 2 < encoded.len) {
            const byte = std.fmt.parseInt(u8, encoded[index + 1 .. index + 3], 16) catch {
                try out.append(arena, '%');
                index += 1;
                continue;
            };
            try out.append(arena, byte);
            index += 3;
        } else {
            try out.append(arena, encoded[index]);
            index += 1;
        }
    }
    return out.items;
}

fn renderedInline(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    const bytes = try painted(arena, line, corpus_columns, null, 0);
    const spans = try paintedSpans(arena, frameBody(bytes));
    var writer: CorpusWriter = .{ .arena = arena };
    var index: usize = 0;
    while (index < spans.len) {
        const span = spans[index];
        if (!span.link) {
            try writer.text(&.{
                .strong = span.strong,
                .emphasis = span.emphasis,
                .code = span.code,
            }, span.bytes);
            index += 1;
            continue;
        }
        var end = index;
        while (end < spans.len and spans[end].link and
            std.mem.eql(u8, spans[end].url, span.url)) end += 1;
        const trailer = end < spans.len and spans[end].muted;
        var href = span.url;
        if (href.len == 0) {
            if (trailer) {
                const shown = spans[end].bytes;
                href = shown[" (".len .. shown.len - ")".len];
            } else {
                var label: std.ArrayList(u8) = .empty;
                for (spans[index..end]) |label_span| try label.appendSlice(arena, label_span.bytes);
                href = label.items;
            }
        }
        for (spans[index..end]) |link_span| try writer.text(&.{
            .href = href,
            .strong = link_span.strong,
            .emphasis = link_span.emphasis,
            .code = link_span.code,
        }, link_span.bytes);
        index = if (trailer) end + 1 else end;
    }
    return try writer.finish();
}

const corpus_columns = 1000;

const PaintedSpan = struct {
    bytes: []const u8 = "",
    url: []const u8 = "",
    code: bool = false,
    link: bool = false,
    muted: bool = false,
    strong: bool = false,
    emphasis: bool = false,

    fn sameStyle(self: *const PaintedSpan, other: *const PaintedSpan) bool {
        return std.mem.eql(u8, self.url, other.url) and self.code == other.code and
            self.link == other.link and self.muted == other.muted and
            self.strong == other.strong and self.emphasis == other.emphasis;
    }
};

fn paintedSpans(arena: std.mem.Allocator, bytes: []const u8) ![]const PaintedSpan {
    var spans: std.ArrayList(PaintedSpan) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var style: PaintedSpan = .{};
    var shown: PaintedSpan = .{};
    var index: usize = 0;
    while (index < bytes.len) {
        const rest = bytes[index..];
        if (std.mem.startsWith(u8, rest, terminal.escape.link_set)) {
            const start = terminal.escape.link_set.len;
            const end = std.mem.find(u8, rest[start..], terminal.escape.string_end).?;
            style.url = rest[start..][0..end];
            index += start + end + terminal.escape.string_end.len;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "\x1b[")) {
            const end = std.mem.findNone(u8, rest[2..], "0123456789;?").? + 3;
            applySgr(&style, rest[0..end]);
            index += end;
            continue;
        }
        if (std.mem.startsWith(u8, rest, terminal.width.grapheme_boundary)) {
            index += terminal.width.grapheme_boundary.len;
            continue;
        }
        if (rest[0] == '\r' or rest[0] == '\n') {
            index += 1;
            continue;
        }
        if (!shown.sameStyle(&style) and text.items.len > 0) {
            shown.bytes = try text.toOwnedSlice(arena);
            try spans.append(arena, shown);
        }
        shown = style;
        try text.append(arena, rest[0]);
        index += 1;
    }
    if (text.items.len > 0) {
        shown.bytes = try text.toOwnedSlice(arena);
        try spans.append(arena, shown);
    }
    return spans.items;
}

fn applySgr(style: *PaintedSpan, sequence: []const u8) void {
    if (std.mem.eql(u8, sequence, comptime attribute.sequence(.reset))) {
        style.* = .{ .url = style.url };
    } else if (std.mem.eql(u8, sequence, comptime attribute.sequence(.bold))) {
        style.strong = true;
    } else if (std.mem.eql(u8, sequence, comptime attribute.sequence(.italic))) {
        style.emphasis = true;
    } else if (std.mem.eql(u8, sequence, comptime attribute.sequence(.underline))) {
        if (style.muted) style.strong = true else style.link = true;
    } else if (std.mem.eql(u8, sequence, comptime role.sequence(.accent))) {
        style.code = true;
    } else if (std.mem.eql(u8, sequence, comptime role.sequence(.link))) {
        style.link = true;
    } else if (std.mem.eql(u8, sequence, comptime role.sequence(.muted))) {
        style.muted = true;
    }
}
