const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

const blanks = " " ** 32;

const rule_cell = "─";

const rule_columns = 80;

const rule_cells = rule_cell ** rule_columns;

pub const Look = struct {
    role: ?role.Name = null,
    url: []const u8 = "",
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    code: bool = false,
};

const accent_look: Look = .{ .role = .accent };
const inline_code_look: Look = .{ .role = .accent, .code = true };
const code_look: Look = .{ .role = .code };
const heading_look: Look = .{ .role = .heading };
const muted_look: Look = .{ .role = .muted };
const quote_look: Look = .{ .role = .muted, .italic = true };
const link_look: Look = .{ .role = .link, .underline = true };

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

pub fn sourceAtRow(text: []const u8, options: *const RowOptions) usize {
    var locator: SourceAtRow = .{ .target = options.row };
    walk(SourceAtRow, &locator, text, @max(options.columns, 1)) catch unreachable;
    return locator.result;
}

pub fn rowAtSource(text: []const u8, options: *const SourceOptions) usize {
    var locator: RowAtSource = .{ .target = @min(options.source_offset, text.len) };
    walk(RowAtSource, &locator, text, @max(options.columns, 1)) catch unreachable;
    return locator.result;
}

pub fn render(placement: *const paint.Placement, tint: ?role.Name, text: []const u8) !void {
    var painter: Painter = .{ .placement = placement, .tint = tint, .line = placement.base };
    try walk(Painter, &painter, text, @max(placement.columns, 1));
}

pub const WindowOptions = struct {
    tint: ?role.Name = null,
    rows_max: usize,
};

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
        if (!self.hidden) self.placement.sink.end(.{ .id = self.placement.id, .line = self.line });
    }
};

pub const Fence = struct {
    marker: u8,
    length: usize,

    pub fn open(line: []const u8) ?Fence {
        if (line.len < 3) return null;
        const marker = line[0];
        if (marker != '`' and marker != '~') return null;
        const length = markerLength(line, marker);
        if (length < 3) return null;
        if (marker == '`' and std.mem.indexOfScalar(u8, line[length..], '`') != null) return null;
        return .{ .marker = marker, .length = length };
    }

    pub fn closes(self: Fence, line: []const u8) bool {
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

fn isEscaped(text: []const u8, index: usize) bool {
    var backslashes: usize = 0;
    while (backslashes < index and text[index - 1 - backslashes] == '\\') : (backslashes += 1) {}
    return backslashes % 2 == 1;
}

pub const Table = struct {
    count: usize,
    widths: [count_max]usize,
    indent: []const u8,

    pub const count_max = 16;

    const Options = struct {
        header: []const u8,
        tail: []const u8,
        columns: usize,
        indentation: usize,
    };

    const Border = struct { left: []const u8, joint: []const u8, right: []const u8 };

    const border_top: Border = .{ .left = "┌", .joint = "┬", .right = "┐" };
    const border_inner: Border = .{ .left = "├", .joint = "┼", .right = "┤" };
    const border_bottom: Border = .{ .left = "└", .joint = "┴", .right = "┘" };

    pub const Cells = struct {
        rest: []const u8,
        done: bool = false,

        pub fn init(row: []const u8) Cells {
            var body = std.mem.trim(u8, row, " \t\r");
            if (body.len > 0 and body[0] == '|') body = body[1..];
            if (body.len > 0 and body[body.len - 1] == '|' and !isEscaped(body, body.len - 1)) {
                body = body[0 .. body.len - 1];
            }
            return .{ .rest = body };
        }

        pub fn next(self: *Cells) ?[]const u8 {
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

    fn CellFlow(comptime Emitter: type) type {
        return struct {
            emitter: *Emitter,
            scanner: InlineScanner,
            width: usize,
            rest: []const u8 = "",
            look: Look = .{},
            used: usize = 0,
            painted: usize = 0,
            pending: usize = 0,
            pending_look: Look = .{},
            done: bool = false,

            fn paintLine(self: *@This()) !void {
                self.used = 0;
                self.painted = 0;
                self.pending = 0;
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
                    if (run == 0 and self.used > 0) return;
                    const cut = if (run > 0) self.rest[0..run] else self.rest;
                    const shown = terminal.width.truncate(cut, room);
                    std.debug.assert(run > 0 or shown.len > 0);
                    if (terminal.width.ofText(shown) > room) {
                        if (self.used > 0) return;
                        try self.place(paint.ellipsis);
                        self.rest = self.rest[terminal.width.boundaryAfter(self.rest, 0)..];
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

            fn paintPending(self: *@This()) !void {
                var left = self.pending;
                self.pending = 0;
                while (left > 0) {
                    const chunk = @min(left, blanks.len);
                    try self.stream(self.pending_look, blank(chunk));
                    left -= chunk;
                }
            }

            fn stream(self: *@This(), look: Look, bytes: []const u8) !void {
                self.painted += terminal.width.ofText(bytes);
                try self.emitter.span(look, bytes);
            }

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

    const Measure = struct {
        columns: usize = 0,

        fn write(self: *Measure, _: Look, bytes: []const u8) !void {
            self.columns += terminal.width.ofText(bytes);
        }
    };

    fn detect(options: *const Options) ?Table {
        if (options.header[0] != '|') return null;
        var lines = std.mem.splitScalar(u8, options.tail, '\n');
        const delimiter = lines.first();
        if (!isDelimiter(delimiter)) return null;
        const count = cellCount(options.header);
        if (count != cellCount(delimiter) or count > count_max) return null;
        const indent = terminal.width.truncate(
            blank(options.indentation),
            prefixRoom(options.columns),
        );
        const columns = options.columns -| terminal.width.ofText(indent);
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

    pub fn isRow(line: []const u8) bool {
        const body = line[leading(line)..];
        return body.len > 0 and body[0] == '|';
    }

    pub fn isDelimiter(line: []const u8) bool {
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

    pub fn cellCount(row: []const u8) usize {
        var cells = Cells.init(row);
        var count: usize = 0;
        while (cells.next() != null) count += 1;
        return count;
    }

    fn measureRow(self: *Table, row: []const u8) void {
        var cells = Cells.init(row);
        for (self.widths[0..self.count]) |*width| {
            const cell = cells.next() orelse break;
            var measure: Measure = .{};
            inlines(Measure, &measure, .{}, cell) catch unreachable;
            width.* = @max(width.*, measure.columns);
        }
    }

    fn fit(self: *Table, columns: usize) void {
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

fn walk(comptime Emitter: type, emitter: *Emitter, text: []const u8, columns: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var maybe_fence: ?Fence = null;
    while (lines.next()) |raw| {
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
            const body = std.mem.trimStart(u8, rest[level..], " ");
            var flow = Flow(Emitter).init(emitter, columns, .{});
            var look = heading_look;
            look.bold = level <= 2;
            look.underline = level == 1;
            try inlines(Flow(Emitter), &flow, look, body);
            try flow.finish();
            const parted = if (lines.peek()) |next| isBlank(next) else true;
            if (!parted) {
                emitter.begin();
                emitter.end();
            }
        } else if (rest[0] == '>') {
            var body = rest;
            while (body.len > 0 and body[0] == '>') {
                body = body[1..];
                if (body.len > 0 and body[0] == ' ') body = body[1..];
            }
            var flow = Flow(Emitter).init(emitter, columns, .{});
            try inlines(Flow(Emitter), &flow, quote_look, body);
            try flow.finish();
        } else if (listMarker(rest)) |marker| {
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
            var flow = Flow(Emitter).init(emitter, columns, .{});
            try inlines(Flow(Emitter), &flow, .{}, line);
            try flow.finish();
        }
    }
}

const Prefix = struct {
    indent: []const u8 = "",
    marker: []const u8 = "",
    look: Look = .{},
};

fn Flow(comptime Emitter: type) type {
    return struct {
        emitter: *Emitter,
        prefix: Prefix,
        budget: usize,
        used: usize = 0,
        pending: usize = 0,
        pending_look: Look = .{},
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
                .emitter = emitter,
                .prefix = shown,
                .budget = @max(columns -| prefixColumns(&shown), 1),
            };
        }

        fn write(self: *@This(), look: Look, bytes: []const u8) !void {
            var rest = bytes;
            while (rest.len > 0) {
                try self.openRow();
                const room = self.budget -| self.used;
                const run = self.wordRun(rest);
                if (run == 0) {
                    if (self.used > 0) {
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

        fn paintPending(self: *@This()) !void {
            var left = self.pending;
            self.pending = 0;
            while (left > 0) {
                const chunk = @min(left, blanks.len);
                try self.emitter.span(self.pending_look, blank(chunk));
                left -= chunk;
            }
        }

        fn wordRun(self: *const @This(), text: []const u8) usize {
            const room = self.budget -| self.used;
            var bytes: usize = 0;
            var columns: usize = 0;
            while (bytes < text.len) {
                const word = terminal.width.nextWord(text[bytes..], self.budget);
                std.debug.assert(word.bytes > 0);
                if (columns + word.columns > room) break;
                bytes += word.bytes;
                columns = @min(columns + word.columns + word.blank_columns, room);
            }
            return bytes;
        }

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
            try self.emitter.span(.{}, self.prefix.indent);
            try self.emitter.span(look, shown);
        }

        fn closeRow(self: *@This()) !void {
            try self.payPrefix(.alone);
            self.pending = 0;
            self.emitter.end();
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
    std.debug.assert(room > 0);
    const content = paint.cut(bytes, room);
    emitter.begin();
    if (content.kept.len > 0) {
        try emitter.span(.{}, shown);
        try emitter.span(look, content.kept);
    }
    if (content.marked) try emitter.span(look, paint.ellipsis);
    emitter.end();
}

const Run = struct {
    look: Look,
    start: usize,
    end: usize,
    after: usize,
    nests: bool,
    url: []const u8 = "",
    code: bool = false,
};

const Scope = struct {
    look: Look,
    end: usize,
    after: usize,
    url: []const u8,
    code: bool,
};

const nesting_max = 4;

const marks = [_]struct { mark: []const u8, look: Look }{
    .{ .mark = "***", .look = .{ .bold = true, .italic = true } },
    .{ .mark = "___", .look = .{ .bold = true, .italic = true } },
    .{ .mark = "**", .look = .{ .bold = true } },
    .{ .mark = "__", .look = .{ .bold = true } },
    .{ .mark = "~~", .look = .{ .strike = true } },
    .{ .mark = "*", .look = .{ .italic = true } },
    .{ .mark = "_", .look = .{ .italic = true } },
};

const closers_max = 4;

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

const Link = struct { label: Closer = .{ .byte = ']' }, url: Closer = .{ .byte = ')' } };

pub const InlineScanner = struct {
    text: []const u8,
    base: Look,
    look: Look,
    context: Context,
    stack: [nesting_max + 1]Scope = undefined,
    depth: usize = 0,
    link: Link = .{},
    start: usize = 0,
    index: usize = 0,
    done: bool = false,
    queue: [5]Span = undefined,
    queue_len: usize = 0,
    queue_head: usize = 0,

    pub const Context = enum { block, table };
    pub const Span = struct { look: Look, bytes: []const u8 };

    pub fn init(base: Look, text: []const u8, context: Context) InlineScanner {
        return .{ .text = text, .base = base, .look = base, .context = context };
    }

    pub fn next(self: *InlineScanner) ?Span {
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
        const text = self.text;
        if (self.index >= text.len and self.depth == 0) {
            self.enqueue(self.look, text[self.start..]);
            self.done = true;
            return;
        }
        if (self.depth > 0 and self.index >= self.stack[self.depth - 1].end) {
            const scope = self.stack[self.depth - 1];
            std.debug.assert(self.index == scope.end);
            self.enqueue(self.look, text[self.start..self.index]);
            self.depth -= 1;
            self.look = if (self.depth > 0) self.stack[self.depth - 1].look else self.base;
            self.enqueueTrailer(scope.url);
            self.index = scope.after;
            self.start = self.index;
            return;
        }
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
        self.index += literal(text, self.index);
    }

    fn enqueue(self: *InlineScanner, look: Look, bytes: []const u8) void {
        self.queue[self.queue_len] = .{ .look = look, .bytes = bytes };
        self.queue_len += 1;
    }

    fn enqueueTrailer(self: *InlineScanner, url: []const u8) void {
        if (url.len == 0) return;
        const shown = merged(self.look, muted_look);
        self.enqueue(shown, " (");
        self.enqueue(shown, url);
        self.enqueue(shown, ")");
    }
};

fn inlines(comptime Sink: type, sink: *Sink, base: Look, text: []const u8) !void {
    const context: InlineScanner.Context = if (Sink == Table.Measure) .table else .block;
    var scanner = InlineScanner.init(base, text, context);
    while (scanner.next()) |span| try sink.write(span.look, span.bytes);
}

fn runAt(text: []const u8, index: usize, link: *Link) ?Run {
    const rest = text[index..];
    if (rest[0] == '`') {
        const close = std.mem.indexOfScalarPos(u8, text, index + 1, '`') orelse return null;
        if (close == index + 1) return null;
        return .{
            .look = inline_code_look,
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
        if (index > 0 and text[index - 1] == entry.mark[0]) continue;
        const open = index + entry.mark.len;
        if (open < text.len and text[open] == entry.mark[0]) continue;
        if (entry.mark[0] == '_' and index > 0 and isWord(text[index - 1])) return null;
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

fn closerAt(text: []const u8, from: usize, mark: []const u8) ?usize {
    var at = from;
    for (0..closers_max) |_| {
        const close = std.mem.indexOfPos(u8, text, at, mark) orelse return null;
        const end = runEnd(text, close, mark[0]);
        at = end;
        if (end - close != mark.len) continue;
        if (isSpace(text[close - 1])) continue;
        if (mark[0] == '_' and end < text.len and isWord(text[end])) continue;
        return close;
    }
    return null;
}

fn runEnd(text: []const u8, at: usize, byte: u8) usize {
    var end = at;
    while (end < text.len and text[end] == byte) end += 1;
    return end;
}

fn literal(text: []const u8, index: usize) usize {
    for (marks) |entry| {
        if (entry.mark.len == 1) continue;
        if (std.mem.startsWith(u8, text[index..], entry.mark)) return entry.mark.len;
    }
    return 1;
}

fn linkAt(text: []const u8, index: usize, link: *Link) ?Run {
    const close = link.label.find(text, index + 1) orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const end = link.url.find(text, close + 2) orelse return null;
    const label = text[index + 1 .. close];
    const url = text[close + 2 .. end];
    const look = linkLook(url);
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
        .url = if (look.url.len > 0 or std.mem.eql(u8, label, url)) "" else url,
    };
}

fn autolinkAt(text: []const u8, index: usize) ?Run {
    if (index > 0 and isWord(text[index - 1])) return null;
    const rest = text[index..];
    const scheme = for ([_][]const u8{ "https://", "http://" }) |candidate| {
        if (std.ascii.startsWithIgnoreCase(rest, candidate)) break candidate.len;
    } else return null;
    var span: usize = 0;
    while (span < rest.len and rest[span] > ' ') span += 1;
    const length = urlLength(rest[0..span]);
    if (length <= scheme) return null;
    return .{
        .look = linkLook(rest[0..length]),
        .start = index,
        .end = index + length,
        .after = index + length,
        .nests = false,
    };
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
        } else if (std.mem.indexOfScalar(u8, url_trailing, last) == null) {
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

fn merged(base: Look, over: Look) Look {
    return .{
        .role = over.role orelse base.role,
        .url = if (over.url.len > 0) over.url else base.url,
        .bold = base.bold or over.bold,
        .italic = base.italic or over.italic,
        .underline = base.underline or over.underline,
        .strike = base.strike or over.strike,
        .code = base.code or over.code,
    };
}

pub const Marker = struct { source: usize, shown: []const u8 };

pub fn listMarker(rest: []const u8) ?Marker {
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

pub fn taskBox(body: []const u8) ?[]const u8 {
    if (body.len < 3 or body[0] != '[' or body[2] != ']') return null;
    if (body[1] != ' ' and body[1] != 'x' and body[1] != 'X') return null;
    if (body.len > 3 and body[3] != ' ') return null;
    return body[0..@min(body.len, 4)];
}

pub fn headingLevel(rest: []const u8) ?usize {
    var level: usize = 0;
    while (level < rest.len and rest[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < rest.len and rest[level] != ' ') return null;
    return level;
}

pub fn isRule(rest: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, rest, " \t\r");
    if (trimmed.len < 3) return false;
    const mark = trimmed[0];
    if (mark != '-' and mark != '*' and mark != '_') return false;
    for (trimmed) |byte| if (byte != mark) return false;
    return true;
}

pub fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

pub fn leading(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and line[index] == ' ') index += 1;
    return index;
}

fn blank(count: usize) []const u8 {
    return blanks[0..@min(count, blanks.len)];
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, first) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '#') == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, heading ++ "Heading three") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, heading ++ "\x1b[1mtwo") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, code) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "  " ++ code) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "const answer = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, muted ++ "```zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, accent ++ "- ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, muted ++ "\x1b[3ma quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "──") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "3. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, accent ++ "[ ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, link ++ "\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "https://example.com") != null);
    const markers = [_][]const u8{ "**", "~~", "*italic*", "`inline code`", "[labelled]" };
    for (markers) |mark| try std.testing.expect(std.mem.indexOf(u8, bytes, mark) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1mbold") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1m\x1b[3mitalic") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "snake_case_name") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1mName") != null);
    try std.testing.expect(std.mem.indexOf(
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

test "a huge table cell wraps in linear time" {
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "┌") == null);
}

test "a table below its narrowest grid stays prose" {
    const gpa = std.testing.allocator;
    const text = "| a | b |\n| - | - |\n| c | d |";
    const bytes = try painted(gpa, text, 8, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "┌") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '|') != null);
}

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

test "the column fit matches a cell-by-cell shrink" {
    var prng = std.Random.DefaultPrng.init(0x7ab1e5);
    const random = prng.random();
    for (0..2000) |_| {
        const count = random.intRangeAtMost(usize, 1, Table.count_max);
        var table: Table = .{ .count = count, .widths = @splat(1), .indent = "" };
        for (table.widths[0..count]) |*width| width.* = random.intRangeAtMost(usize, 1, 40);
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

test "a prefix leaves room for the body it pushes right" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "- abc", "    - abc", "12. abc" }) |text| {
        for ([_]usize{ 1, 2 }) |columns| {
            const bytes = try painted(gpa, text, columns, null, 0);
            defer gpa.free(bytes);
            for ("abc") |letter| {
                try std.testing.expect(std.mem.indexOfScalar(u8, bytes, letter) != null);
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

test "a word that crosses a look seam breaks at the seam" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "aaa **bb**bbbb", 6, &.{ "aaa bb", "bbbb" });
}

test "a styled wide glyph wraps rather than degrading" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "abc**你**", 4, null, 0);
    defer gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 2), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "你") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "�") == null);
}

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

test "a quote paints with no border glyph" {
    const gpa = std.testing.allocator;
    const text = "> **_Note:_** a quoted line\n> and its second line";
    try expectPlainRows(gpa, text, 30, &.{ "Note: a quoted line", "and its second line" });

    const bytes = try painted(gpa, text, 30, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "│") == null);
    const nested = comptime role.sequence(.muted) ++ "\x1b[4m\x1b[3mNote:";
    try std.testing.expect(std.mem.indexOf(u8, bytes, nested) != null);
    const intensity_clash = comptime role.sequence(.muted) ++ "\x1b[1m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, intensity_clash) == null);
}

test "nested inline markers all shed their marks" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "**_both_** and *a **deep** run*", 40, &.{
        "both and a deep run",
    });
    try expectPlainRows(gpa, "***all three*** of them", 40, &.{"all three of them"});
    try expectPlainRows(gpa, "a **b _c** d_ e", 40, &.{"a b _c d_ e"});
    try expectPlainRows(gpa, "a *b\t*c* d", 40, &.{"a b *c d"});

    const bytes = try painted(gpa, "**_both_**", 40, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1m\x1b[3mboth") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, labelled) != null);
    const bare = "\x1b]8;;https://example.com/b\x1b\\https://example.com/b\x1b]8;;\x1b\\";
    try std.testing.expect(std.mem.indexOf(u8, bytes, bare) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]8;;./x.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]8;;javascript:") == null);

    const upper = try painted(gpa, "HTTPS://X.Y/a", 40, null, 0);
    defer gpa.free(upper);
    try std.testing.expect(std.mem.indexOf(u8, upper, "\x1b]8;;HTTPS://X.Y/a\x1b\\") != null);
}

test "a bare URL the sink refuses keeps its text and its look" {
    const gpa = std.testing.allocator;
    const text = "at https://x.y/\u{00e9}rest today";
    try expectPlainRows(gpa, text, 40, &.{"at https://x.y/érest today"});

    const bytes = try painted(gpa, text, 40, null, 0);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, terminal.escape.link_set) == null);
    const styled = comptime role.sequence(.link) ++
        "\x1b[4mhttps://x.y/\u{00e9}rest\x1b[0m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, styled) != null);
}

test "a wrapped link closes on each of its rows" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "[a long clickable label](https://example.com/a)", 10, null, 0);
    defer gpa.free(bytes);

    const opens = std.mem.count(u8, bytes, "\x1b]8;;https://example.com/a\x1b\\");
    try std.testing.expectEqual(paintedRows(bytes), opens);
    try std.testing.expectEqual(opens, std.mem.count(u8, bytes, terminal.escape.link_reset));
}

test "a bare URL ends before the punctuation behind it" {
    try std.testing.expectEqual(@as(usize, 11), urlLength("https://x.y"));
    try std.testing.expectEqual(@as(usize, 11), urlLength("https://x.y."));
    try std.testing.expectEqual(@as(usize, 11), urlLength("https://x.y),"));
    try std.testing.expectEqual(@as(usize, 15), urlLength("https://x.y/(a)"));
    try std.testing.expectEqual(@as(usize, 15), urlLength("https://x.y/(a))"));
}

test "a heading with no body paints an empty row" {
    const gpa = std.testing.allocator;
    try expectPlainRows(gpa, "###\ntext", 20, &.{ "", "", "text" });

    const bytes = try painted(gpa, "######", 20, null, 0);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '#') == null);
}

test "an unclosed bold marker stays literal" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "**bold*", 40, null, 0);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "**bold*") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[3m") == null);
}

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
    for (0..10_000) |_| try text.appendSlice(gpa, "[](");

    const bytes = try painted(gpa, text.items, 80, null, 0);
    defer gpa.free(bytes);
    try std.testing.expectEqual(rows(text.items, 80), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[[[") != null);
}

test "a tinted block renders muted and italic throughout" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, sample, 72, .muted, 0);
    defer gpa.free(bytes);

    inline for ([_]role.Name{ .heading, .code, .accent, .link }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, role.sequence(name)) == null);
    }
    const muted = comptime role.sequence(.muted) ++ "\x1b[3m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, muted) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "- ") != null);
    const emphasized = comptime role.sequence(.muted) ++ "\x1b[4m\x1b[3mHeading";
    const emphasized_underlined =
        comptime role.sequence(.muted) ++ "\x1b[21m\x1b[3mHeading one";
    try std.testing.expect(std.mem.indexOf(u8, bytes, emphasized) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, emphasized_underlined) != null);
    const intensity_clash = comptime role.sequence(.muted) ++ "\x1b[1m";
    try std.testing.expect(std.mem.indexOf(u8, bytes, intensity_clash) == null);
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
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    for (0..400) |_| {
        text.clearRetainingCapacity();
        for (0..random.uintLessThan(usize, 40)) |_| {
            try text.appendSlice(gpa, tokens[random.uintLessThan(usize, tokens.len)]);
        }
        for ([_]usize{ 1, 2, 3, 5, 9, 40, 100 }) |columns| {
            out.clearRetainingCapacity();
            view.forget();
            const sink = try view.beginFrame(.{ .columns = columns, .rows = 2000 }, 1);
            const placement: paint.Placement = .{
                .sink = sink,
                .id = 0,
                .columns = columns,
                .base = 0,
                .skip = 0,
            };
            try render(&placement, null, text.items);
            try view.render();
            try std.testing.expectEqual(rows(text.items, columns), paintedRows(out.written()));
        }
    }
}

test "a clipped markdown block shows its bottom rows" {
    const gpa = std.testing.allocator;
    const columns = 40;
    const total = rows(sample, columns);
    const bytes = try painted(gpa, sample, columns, null, total - 4);
    defer gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 4), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Heading one") == null);
}
