const std = @import("std");

const terminal = @import("terminal");

const Message = @import("../Message.zig");

const attribute = @import("attribute.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

const activity_length_default: usize = 6;
const activity_growth_delay_ticks: u64 = 31;
const activity_growth_interval_ticks: u64 = 6;
const caret_blink_ticks: u64 = 37;

pub const NoticeStyle = struct {
    role: role.Name,
    prefix: []const u8 = "",
    fit: Fit = .wrap,

    pub const note: NoticeStyle = .{ .role = .user_note, .prefix = "→ " };

    pub fn of(severity: Message.Severity) NoticeStyle {
        return switch (severity) {
            .information => .{ .role = .accent, .prefix = "ℹ " },
            .warning => .{ .role = .warning, .prefix = "⚠ " },
            .failure => .{ .role = .@"error", .prefix = "⚠ " },
        };
    }
};

pub const separator = " \u{00B7} ";

pub const blank_bytes = " \t\r\n";

const Row = struct { end: usize, next: usize, shortened: bool = false };

const Overwide = enum { keep, drop, cut, wrap };

const Wrap = struct {
    rest: []const u8,
    columns: usize,
    lead: usize,
    legend: bool = false,
    fresh: bool = true,
    done: bool = false,

    fn next(self: *Wrap) ?Cut {
        if (self.done) return null;
        const lead = self.lead;
        self.lead = 0;
        if (lead > 0 and lead >= self.columns and self.rest.len > 0) {
            const break_at = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
            if (break_at < self.rest.len and lineText(self.rest[0..break_at]).len == 0)
                self.rest = self.rest[break_at + 1 ..];
            return .{ .kept = "", .shortened = false };
        }
        const room = @max(self.columns -| lead, 1);
        const line_end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
        const line = lineText(self.rest[0..line_end]);
        if (self.fresh) self.legend = std.mem.indexOf(u8, line, separator) != null;
        const row = packRow(line, room, if (self.legend) .cut else .wrap);
        self.fresh = row.next >= line.len;
        if (!self.fresh) {
            self.rest = self.rest[row.next..];
        } else if (line_end < self.rest.len) {
            self.rest = self.rest[line_end + 1 ..];
        } else {
            self.done = true;
        }
        return .{ .kept = terminal.width.rowText(line[0..row.end]), .shortened = row.shortened };
    }
};

const BoxRow = struct {
    content: []const u8,
    fit: Fit,
    run: Run = .{},
    role: role.Name = .text,
};

const Run = struct { start: usize = 0, end: usize = 0 };

pub const Mark = struct {
    start: usize,
    end: usize,
    role: role.Name,
    underline: bool = false,
};

pub const Placement = struct {
    sink: *terminal.View.Sink,
    id: usize,
    columns: usize,
    base: usize,
    skip: usize,

    pub fn begin(self: *const Placement, line: usize) bool {
        if (line < self.skip) return false;
        self.sink.begin();
        return true;
    }

    pub fn end(self: *const Placement, line: usize) void {
        self.sink.end(.{ .id = self.id, .line = line });
    }
};

pub const Fit = enum {
    wrap,
    head,
};

pub const Box = struct {
    text: []const u8,
    fit: Fit = .wrap,
    emphasis: Emphasis = .none,

    const Emphasis = enum {
        none,
        first_value,
    };
};

pub const Activity = struct {
    motion_tick: u64,
    progress_age_ticks: u64,
    caret_tick: ?u64 = null,
};

const Cut = struct {
    kept: []const u8,
    shortened: bool,

    pub fn writeEllipsis(self: *const Cut, sink: *terminal.View.Sink) !void {
        if (self.shortened) try sink.text(ellipsis);
    }
};

const Head = struct { label: []const u8, shown: Cut };

pub const RenderOptions = struct {
    viewport_rows: usize,
    activity: ?Activity = null,
};

pub const Window = struct {
    scroll: usize = 0,

    pub const Extent = struct {
        body_rows: usize,
        viewport_rows: usize,

        fn visibleRows(self: Extent) usize {
            return @min(self.body_rows, bodyLimit(self.viewport_rows));
        }

        pub fn rows(self: Extent) usize {
            return frame_edge_rows + self.visibleRows();
        }
    };

    const Shown = struct {
        body_rows: usize,
        hidden_above: usize,
        hidden_below: usize,
    };

    pub fn follow(self: *Window, extent: Extent, row: usize) void {
        const visible = extent.visibleRows();
        if (row < self.scroll) self.scroll = row;
        if (row >= self.scroll + visible) self.scroll = row - visible + 1;
        self.scroll = @min(self.scroll, extent.body_rows - visible);
    }

    pub fn shown(self: Window, extent: Extent) Shown {
        const visible = extent.visibleRows();
        return .{
            .body_rows = visible,
            .hidden_above = self.scroll,
            .hidden_below = extent.body_rows - self.scroll - visible,
        };
    }
};

const Framing = struct {
    body: []const u8,
    body_rows: usize,
    caret: ?terminal.View.Caret = null,
    hidden_above: usize = 0,
    hidden_below: usize = 0,
    trailing_row: bool = false,
    line_roles: []const role.Name = &.{},
    marks: []const Mark = &.{},
    activity: ?Activity = null,
};

const FrameEdge = enum {
    top,
    bottom,

    fn arrow(self: FrameEdge) []const u8 {
        return switch (self) {
            .top => "↑",
            .bottom => "↓",
        };
    }
};

const FrameGlyph = enum {
    light,
    heavy,
    left_light_right_heavy,
    left_heavy_right_light,
};

const Frame = struct {
    columns: usize,
    activity: ?Activity,
};

const FrameCell = struct { glyph: FrameGlyph, active: bool };

const HorizontalWeights = struct { left: bool, right: bool };

const FrameRange = struct { edge: FrameEdge, start: usize, end: usize };

const LabelOptions = struct { edge: FrameEdge, more: usize, columns: usize };

const FramedRow = struct {
    content: []const u8,
    offset: usize = 0,
    role: ?role.Name = null,
    marks: []const Mark = &.{},
};

pub fn singleLine(text: []u8) []u8 {
    var length: usize = 0;
    var blank = false;
    for (text) |byte| {
        if (byte == ' ' or byte <= 0x1f or byte == 0x7f) {
            blank = length != 0;
            continue;
        }
        if (blank) {
            text[length] = ' ';
            length += 1;
            blank = false;
        }
        text[length] = byte;
        length += 1;
    }
    return text[0..length];
}

pub fn isBlank(text: []const u8) bool {
    return std.mem.indexOfNone(u8, text, blank_bytes) == null;
}

pub fn packRow(line: []const u8, room: usize, overwide: Overwide) Row {
    const separator_columns = terminal.width.ofText(separator);
    var index: usize = 0;
    var end: usize = 0;
    var columns: usize = 0;
    while (index < line.len) {
        const piece_end = std.mem.indexOfPos(u8, line, index, separator) orelse line.len;
        const piece = line[index..piece_end];
        const lead = if (index == 0) 0 else separator_columns;
        const piece_columns = terminal.width.ofText(piece);
        if (columns + lead + piece_columns <= room) {
            columns += lead + piece_columns;
            end = piece_end;
            index = @min(piece_end + separator.len, line.len);
            continue;
        }
        if (index > 0) return .{ .end = end, .next = index };
        const behind = @min(piece_end + separator.len, line.len);
        switch (overwide) {
            .keep => return .{ .end = piece_end, .next = behind },
            .drop => return .{ .end = 0, .next = behind },
            .cut => {
                const shown = cut(piece, room);
                return .{ .end = shown.kept.len, .next = behind, .shortened = shown.shortened };
            },
            .wrap => {
                var iterator = terminal.width.wrapper(piece, room);
                const span = iterator.nextSpan().?;
                if (span.end == piece.len) return .{ .end = piece_end, .next = behind };
                return .{ .end = span.end, .next = span.end };
            },
        }
    }
    return .{ .end = end, .next = line.len };
}

pub fn noticeRows(style: *const NoticeStyle, text: []const u8, columns: usize) usize {
    if (style.fit == .head) return 1;
    var wrap = noticeWrap(style, text, columns);
    var count: usize = 0;
    while (wrap.next()) |_| count += 1;
    return count;
}

fn noticeWrap(style: *const NoticeStyle, text: []const u8, columns: usize) Wrap {
    return .{
        .rest = text,
        .columns = columns,
        .lead = terminal.width.ofText(terminal.width.truncate(style.prefix, columns)),
    };
}

fn firstValue(text: []const u8) Run {
    const head = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const key_separator = ": ";
    const key_end = std.mem.indexOf(u8, head, key_separator) orelse return .{};
    const start = key_end + key_separator.len;
    const value = head[start..];
    const length = std.mem.indexOfScalar(u8, value, ' ') orelse value.len;
    return .{ .start = start, .end = start + length };
}

pub fn boxRows(body: *const Box, columns: usize) usize {
    var count: usize = 2;
    var lines = std.mem.splitScalar(u8, body.text, '\n');
    while (lines.next()) |line| count += switch (body.fit) {
        .wrap => terminal.width.rows(lineText(line), columns),
        .head => 1,
    };
    return count;
}

pub fn activityChanged(activity: *const Activity, columns: usize) bool {
    if (activity.caret_tick) |caret_tick| if (caretBlinkChanged(caret_tick)) return true;
    if (columns == 0) return false;
    return activityHead(activity.motion_tick, columns) !=
        activityHead(activity.motion_tick -% 1, columns);
}

pub const ellipsis = "…";

pub fn cut(text: []const u8, columns_max: usize) Cut {
    const shown = terminal.width.truncate(text, columns_max);
    if (shown.len == text.len) return .{ .kept = shown, .shortened = false };
    const room = columns_max -| 1;
    const kept = terminal.width.truncate(text, room);
    if (terminal.width.ofText(kept) > room) return .{ .kept = "", .shortened = true };
    return .{ .kept = kept, .shortened = true };
}

fn lineText(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

pub fn notice(placement: *const Placement, style: *const NoticeStyle, text: []const u8) !void {
    if (style.fit == .head) return noticeHead(placement, style, text);
    const shown_prefix = terminal.width.truncate(style.prefix, placement.columns);
    var wrap = noticeWrap(style, text, placement.columns);
    var index: usize = 0;
    while (wrap.next()) |row| : (index += 1) {
        const line = placement.base + index;
        if (!placement.begin(line)) continue;
        if (index == 0) try noticePrefix(placement.sink, style, shown_prefix);
        try noticeBody(placement.sink, style, row.kept, index == 0 and shown_prefix.len > 0);
        try row.writeEllipsis(placement.sink);
        try attribute.apply(placement.sink, .reset);
        placement.end(line);
    }
}

fn noticePrefix(sink: *terminal.View.Sink, style: *const NoticeStyle, prefix: []const u8) !void {
    if (prefix.len == 0) return;
    try role.apply(sink, style.role);
    try sink.text(prefix);
}

fn noticeBody(
    sink: *terminal.View.Sink,
    style: *const NoticeStyle,
    text: []const u8,
    role_active: bool,
) !void {
    if (!role_active) try role.apply(sink, style.role);
    try sink.text(text);
}

pub fn headCut(text: []const u8, columns_max: usize) Cut {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = lineText(text[0..line_end]);
    if (line_end == text.len) return cut(line, columns_max);
    return .{ .kept = terminal.width.truncate(line, columns_max -| 1), .shortened = true };
}

fn headRow(parts: *const struct { label: []const u8, text: []const u8, columns: usize }) Head {
    const columns = parts.columns;
    const shown_label = terminal.width.truncate(parts.label, columns);
    const room = columns -| terminal.width.ofText(shown_label);
    const shown = headCut(parts.text, room);
    if (room > 0 or !shown.shortened) return .{ .label = shown_label, .shown = shown };
    return .{
        .label = terminal.width.truncate(shown_label, columns -| 1),
        .shown = .{ .kept = "", .shortened = true },
    };
}

fn noticeHead(placement: *const Placement, style: *const NoticeStyle, text: []const u8) !void {
    if (!placement.begin(placement.base)) return;
    const row = headRow(&.{ .label = style.prefix, .text = text, .columns = placement.columns });
    try noticePrefix(placement.sink, style, row.label);
    try noticeBody(placement.sink, style, row.shown.kept, row.label.len > 0);
    try row.shown.writeEllipsis(placement.sink);
    try attribute.apply(placement.sink, .reset);
    placement.end(placement.base);
}

pub fn box(placement: *const Placement, name: role.Name, body: *const Box) !void {
    var line = placement.base;
    try boxEdge(placement, &line, name);
    const run: Run = switch (body.emphasis) {
        .none => .{},
        .first_value => firstValue(body.text),
    };
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, body.text, '\n');
    while (lines.next()) |source| {
        defer offset += source.len + 1;
        const content = lineText(source);
        switch (body.fit) {
            .wrap => {
                var iterator = terminal.width.wrapper(content, placement.columns);
                while (iterator.nextSpan()) |span| {
                    try boxRow(placement, &line, &.{
                        .content = terminal.width.rowText(content[span.start..span.end]),
                        .fit = .wrap,
                        .run = rowRun(run, offset + span.start),
                        .role = name,
                    });
                }
            },
            .head => try boxRow(placement, &line, &.{
                .content = content,
                .fit = .head,
                .run = rowRun(run, offset),
                .role = name,
            }),
        }
    }
    try boxEdge(placement, &line, name);
}

fn rowRun(run: Run, offset: usize) Run {
    return .{ .start = run.start -| offset, .end = run.end -| offset };
}

fn boxEdge(placement: *const Placement, line: *usize, name: role.Name) !void {
    defer line.* += 1;
    if (!placement.begin(line.*)) return;
    try role.apply(placement.sink, name);
    try placement.sink.spaces(placement.columns);
    try attribute.apply(placement.sink, .reset);
    placement.end(line.*);
}

fn boxRow(placement: *const Placement, line: *usize, row: *const BoxRow) !void {
    defer line.* += 1;
    if (!placement.begin(line.*)) return;
    try role.apply(placement.sink, row.role);
    try boxRowCells(placement.sink, placement.columns, row);
    try attribute.apply(placement.sink, .reset);
    placement.end(line.*);
}

fn boxRowCells(sink: *terminal.View.Sink, columns: usize, row: *const BoxRow) !void {
    switch (row.fit) {
        .wrap => try boxRowText(sink, terminal.width.truncate(row.content, columns), row),
        .head => {
            const shown = cut(row.content, columns);
            try boxRowText(sink, shown.kept, row);
            try shown.writeEllipsis(sink);
        },
    }
    try sink.spaces(columns -| sink.columns_written);
}

fn boxRowText(sink: *terminal.View.Sink, text: []const u8, row: *const BoxRow) !void {
    const start = @min(row.run.start, text.len);
    const end = @min(row.run.end, text.len);
    if (start == end) return sink.text(text);
    try sink.text(text[0..start]);
    try attribute.emphasize(sink, row.role, false);
    try sink.text(text[start..end]);
    try attribute.apply(sink, .reset);
    try role.apply(sink, row.role);
    try sink.text(text[end..]);
}

const frame_edge_rows = 2;
const label_lead_columns = 3;

fn bodyLimit(viewport_rows: usize) usize {
    return @min(@max(@divFloor(viewport_rows, 4) + 1, 5), 15);
}

pub fn framed(placement: *const Placement, framing: *const Framing) !void {
    const maybe_activity = framing.activity;
    const frame: Frame = .{
        .columns = placement.columns,
        .activity = maybe_activity,
    };
    const caret_shown = if (maybe_activity) |activity|
        caretVisible(activity.caret_tick orelse 0)
    else
        true;
    const maybe_caret = if (caret_shown) framing.caret else null;
    var line = placement.base;
    try frameEdgeRow(placement, &frame, &line, .top, framing.hidden_above);
    var iterator = terminal.width.wrapper(framing.body, placement.columns);
    const window_end = framing.hidden_above +| framing.body_rows;
    var source_offset: usize = 0;
    var source_line: usize = 0;
    var body_count: usize = 0;
    var index: usize = 0;
    while (iterator.nextSpan()) |span| : (index += 1) {
        source_line += std.mem.count(u8, framing.body[source_offset..span.start], "\n");
        source_offset = span.start;
        if (index < framing.hidden_above) continue;
        if (index >= window_end) break;
        const roles = framing.line_roles;
        const maybe_role = if (source_line < roles.len) roles[source_line] else null;
        const content = terminal.width.rowText(framing.body[span.start..span.end]);
        try framedRow(placement, &maybe_caret, &line, &.{
            .content = content,
            .offset = span.start,
            .role = maybe_role,
            .marks = framing.marks,
        });
        body_count += 1;
    }
    if (framing.trailing_row and index >= framing.hidden_above and index < window_end) {
        try framedRow(placement, &maybe_caret, &line, &.{ .content = "" });
        body_count += 1;
    }
    std.debug.assert(body_count == framing.body_rows);
    try frameEdgeRow(placement, &frame, &line, .bottom, framing.hidden_below);
}

fn framedRow(
    placement: *const Placement,
    maybe_caret: *const ?terminal.View.Caret,
    line: *usize,
    row: *const FramedRow,
) !void {
    defer line.* += 1;
    if (!placement.begin(line.*)) return;
    if (row.role) |name| try role.apply(placement.sink, name);
    try framedRowText(placement.sink, row);
    if (row.role != null) try attribute.apply(placement.sink, .reset);
    if (maybe_caret.*) |caret|
        if (placement.base + caret.row == line.*) placement.sink.setCaret(caret.column);
    placement.end(line.*);
}

fn framedRowText(sink: *terminal.View.Sink, row: *const FramedRow) !void {
    const text = row.content;
    var position: usize = 0;
    for (row.marks) |mark| {
        const start = @min(mark.start -| row.offset, text.len);
        const end = @min(mark.end -| row.offset, text.len);
        if (start == end) continue;
        std.debug.assert(start >= position);
        try sink.text(text[position..start]);
        try role.apply(sink, mark.role);
        if (mark.underline) try attribute.apply(sink, .underline);
        try sink.text(text[start..end]);
        try attribute.apply(sink, .reset);
        if (row.role) |name| try role.apply(sink, name);
        position = end;
    }
    try sink.text(text[position..]);
}

fn frameEdgeRow(
    placement: *const Placement,
    frame: *const Frame,
    line: *usize,
    edge: FrameEdge,
    more: usize,
) !void {
    defer line.* += 1;
    if (!placement.begin(line.*)) return;
    try frameEdgeCells(placement.sink, frame, edge, more);
    try attribute.apply(placement.sink, .reset);
    placement.end(line.*);
}

fn frameEdgeCells(
    sink: *terminal.View.Sink,
    frame: *const Frame,
    edge: FrameEdge,
    more: usize,
) !void {
    var buffer: [32]u8 = undefined;
    const maybe_label = moreLabel(&buffer, &.{
        .edge = edge,
        .more = more,
        .columns = frame.columns,
    });
    if (maybe_label) |label| {
        const label_end = label_lead_columns + 1 + terminal.width.ofText(label) + 1;
        try drawFrameRange(sink, frame, &.{
            .edge = edge,
            .start = 0,
            .end = label_lead_columns,
        });
        try role.apply(sink, .muted);
        try sink.text(" ");
        try sink.text(label);
        try sink.text(" ");
        try attribute.apply(sink, .reset);
        try drawFrameRange(sink, frame, &.{
            .edge = edge,
            .start = label_end,
            .end = frame.columns,
        });
    } else {
        try drawFrameRange(sink, frame, &.{
            .edge = edge,
            .start = 0,
            .end = frame.columns,
        });
    }
}

fn moreLabel(buffer: *[32]u8, options: *const LabelOptions) ?[]const u8 {
    if (options.more == 0) return null;
    const full = std.fmt.bufPrint(buffer, "{s} Hidden: {d}", .{
        options.edge.arrow(),
        options.more,
    }) catch return null;
    if (labelFits(options.columns, full)) return full;
    const compact = std.fmt.bufPrint(buffer, "{s}{d}", .{
        options.edge.arrow(),
        options.more,
    }) catch return null;
    return if (labelFits(options.columns, compact)) compact else null;
}

fn labelFits(columns: usize, label: []const u8) bool {
    const used = label_lead_columns + 1 + terminal.width.ofText(label) + 1;
    return columns > used;
}

fn drawFrameRange(
    sink: *terminal.View.Sink,
    frame: *const Frame,
    options: *const FrameRange,
) !void {
    std.debug.assert(options.start <= options.end and options.end <= frame.columns);
    var first = true;
    var active = false;
    var column = options.start;
    while (column < options.end) {
        const cell = frameCell(frame, options.edge, column);
        if (first or cell.active != active) {
            first = false;
            active = cell.active;
            try role.apply(sink, if (active) .activity else .input_frame);
        }
        var run_end = column + 1;
        while (run_end < options.end) : (run_end += 1) {
            const next = frameCell(frame, options.edge, run_end);
            if (next.active != cell.active or next.glyph != cell.glyph) break;
        }
        try writeFrameGlyph(sink, cell.glyph, run_end - column);
        column = run_end;
    }
}

fn frameCell(frame: *const Frame, edge: FrameEdge, column: usize) FrameCell {
    std.debug.assert(column < frame.columns);
    const active = activityAt(frame, edge, column);
    const left = active and column > 0 and activityAt(frame, edge, column - 1);
    const right = active and column + 1 < frame.columns and
        activityAt(frame, edge, column + 1);
    return .{
        .glyph = if (active)
            activityGlyph(.{ .left = left, .right = right })
        else
            .light,
        .active = active,
    };
}

fn activityAt(frame: *const Frame, edge: FrameEdge, column: usize) bool {
    const maybe_activity = frame.activity;
    if (maybe_activity) |activity| {
        const position = switch (edge) {
            .top => column,
            .bottom => frame.columns + column,
        };
        const track_columns = 2 * frame.columns;
        const head = activityHead(activity.motion_tick, frame.columns);
        const distance = if (head >= position)
            head - position
        else
            track_columns - (position - head);
        return distance < activityLength(activity.progress_age_ticks, frame.columns);
    }
    return false;
}

fn activityHead(motion_tick: u64, columns: usize) usize {
    std.debug.assert(columns > 0);
    const track_columns = 2 * columns;
    const track_columns_u64: u64 = @intCast(track_columns);
    const phase: usize = @intCast(motion_tick % track_columns_u64);
    const offset = @min(activity_length_default, columns) - 1;
    const wrap_at = track_columns - offset;
    return if (phase >= wrap_at) phase - wrap_at else phase + offset;
}

fn caretVisible(caret_tick: u64) bool {
    return caret_tick % (2 * caret_blink_ticks) < caret_blink_ticks;
}

fn caretBlinkChanged(caret_tick: u64) bool {
    return caret_tick % caret_blink_ticks == 0;
}

fn activityLength(progress_age_ticks: u64, columns: usize) usize {
    std.debug.assert(columns > 0);
    const length_max = columns;
    const length_base = @min(activity_length_default, length_max);
    const growth_max: u64 = @intCast(length_max - length_base);
    const growth_steps: u64 = if (progress_age_ticks < activity_growth_delay_ticks)
        0
    else
        1 + @divFloor(
            progress_age_ticks - activity_growth_delay_ticks,
            activity_growth_interval_ticks,
        );
    return length_base + @as(usize, @intCast(@min(growth_steps, growth_max)));
}

fn activityGlyph(weights: HorizontalWeights) FrameGlyph {
    if (weights.left) return if (weights.right)
        .heavy
    else
        .left_heavy_right_light;
    return if (weights.right) .left_light_right_heavy else .heavy;
}

fn writeFrameGlyph(
    sink: *terminal.View.Sink,
    glyph: FrameGlyph,
    count: usize,
) !void {
    switch (glyph) {
        .light => try sink.repeat("─", count),
        .heavy => try sink.repeat("━", count),
        .left_light_right_heavy => try sink.repeat("╼", count),
        .left_heavy_right_light => try sink.repeat("╾", count),
    }
}

test "a box breaks its rows between words" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    const text = "one two three four five";
    const columns = 14;
    const placement = try rig.begin(&.{ .columns = columns, .rows = 8 });
    try box(&placement, .user, &.{ .text = text });

    const painted = try rig.painted();
    try std.testing.expectEqual(@as(usize, 4), boxRows(&.{ .text = text }, columns));
    try testing.expectShows(painted, &.{"one two three"});
    try testing.expectShows(painted, &.{"four five"});
}

test "a box row sheds the carriage return of a CRLF break" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    const columns = 20;
    const body: Box = .{ .text = "first line\r\nsecond line" };
    const placement = try rig.begin(&.{ .columns = columns, .rows = 8 });
    try box(&placement, .user, &body);

    const painted = try rig.painted();
    try std.testing.expectEqual(@as(usize, 4), boxRows(&body, columns));
    try testing.expectShows(painted, &.{"first line"});
    try testing.expectShows(painted, &.{"second line"});
    try testing.expectHides(painted, &.{"\u{FFFD}"});
}

test "a fitted box holds one row per line" {
    const gpa = std.testing.allocator;
    const columns = 20;
    const text = "Tool: write · File: src/App.zig\nLines: 1";
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    const body: Box = .{ .text = text, .fit = .head };
    const placement = try rig.begin(&.{ .columns = columns, .rows = 8 });
    try box(&placement, .tool_pending, &body);

    const painted = try rig.painted();
    try std.testing.expectEqual(@as(usize, 4), boxRows(&body, columns));
    try testing.expectShows(painted, &.{"Tool: write · File:\u{2026}"});
    try testing.expectShows(painted, &.{"Lines: 1"});
}

test "a box emphasizes the value of its first key" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    const columns = 40;
    const body: Box = .{
        .text = "Tool: read \u{00B7} File: a.zig\nLines: 3",
        .fit = .head,
        .emphasis = .first_value,
    };
    const placement = try rig.begin(&.{ .columns = columns, .rows = 8 });
    try box(&placement, .tool_success, &body);

    const painted = try rig.painted();
    const head = comptime "Tool: \x1b[1mread\x1b[0m" ++ role.sequence(.tool_success) ++
        " \u{00B7} File: a.zig";
    try testing.expectShows(painted, &.{head});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, "\x1b[1m"));

    const plain = try rig.plain();
    try testing.expectShows(plain, &.{"Tool: read \u{00B7} File: a.zig"});
    try testing.expectShows(plain, &.{"Lines: 3"});
}

test "a narrow box cuts its run and carries the rest to the next row" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    const columns = 12;
    const body: Box = .{
        .text = "Tool: read_the_file \u{00B7} File: a",
        .emphasis = .first_value,
    };
    const placement = try rig.begin(&.{ .columns = columns, .rows = 8 });
    try box(&placement, .tool_pending, &body);

    const painted = try rig.painted();
    const opened = comptime role.sequence(.tool_pending) ++ "\x1b[1mread_the_fil";
    const carried = comptime "\x1b[1me\x1b[0m" ++ role.sequence(.tool_pending) ++
        " \u{00B7} File: a";
    try testing.expectShows(painted, &.{opened});
    try testing.expectShows(painted, &.{carried});

    const plain = try rig.plain();
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    var count: usize = 0;
    while (rows.next()) |row| : (count += 1)
        try std.testing.expectEqual(columns, terminal.width.ofText(row));
    try std.testing.expectEqual(boxRows(&body, columns), count);
}

test "the emphasized run covers the first value alone" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { text: []const u8, bold: ?[]const u8 }{
        .{ .text = "Tool: describe_drinky", .bold = "Tool: \x1b[1mdescribe_drinky\x1b[0m" },
        .{ .text = "please read a.zig", .bold = null },
    };
    for (cases) |case| {
        var rig: testing.Rig = undefined;
        rig.init(gpa);
        defer rig.deinit();
        const placement = try rig.begin(&.{ .columns = 40, .rows = 8 });
        try box(&placement, .tool_success, &.{
            .text = case.text,
            .fit = .head,
            .emphasis = .first_value,
        });
        const painted = try rig.painted();
        if (case.bold) |bold|
            try testing.expectShows(painted, &.{bold})
        else
            try testing.expectHides(painted, &.{"\x1b[1m"});
    }
}

test "activity at column zero emits no unused frame role" {
    const gpa = std.testing.allocator;
    const painted = try paintedFramed(gpa, 20, &.{
        .body = "x",
        .body_rows = 1,
        .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
    });
    defer gpa.free(painted);

    const segment = comptime role.sequence(.activity) ++ "╼━━━━╾" ++
        role.sequence(.input_frame) ++ "─";
    try testing.expectShows(painted, &.{segment});
    const unused = comptime role.sequence(.input_frame) ++ role.sequence(.activity);
    try testing.expectHides(painted, &.{unused});
}

test "a frame edge label reads as muted text between the frame glyphs" {
    const gpa = std.testing.allocator;
    const painted = try paintedFramed(gpa, 20, &.{
        .body = "a\n" ** 3 ++ "x",
        .body_rows = 1,
        .hidden_above = 3,
    });
    defer gpa.free(painted);

    const label = comptime role.sequence(.muted) ++ " ↑ Hidden: 3 \x1b[0m" ++
        role.sequence(.input_frame);
    try testing.expectShows(painted, &.{label});
}

test "a frame edge label resets faint before a right activity segment" {
    const gpa = std.testing.allocator;
    const painted = try paintedFramed(gpa, 20, &.{
        .body = "a\n" ** 3 ++ "x",
        .body_rows = 1,
        .hidden_above = 3,
        .activity = .{ .motion_tick = 16, .progress_age_ticks = 0 },
    });
    defer gpa.free(painted);

    const segment = comptime role.sequence(.muted) ++ " ↑ Hidden: 3 \x1b[0m" ++
        role.sequence(.activity) ++ "╼";
    try testing.expectShows(painted, &.{segment});
}

test "one activity segment starts at the top left and crosses both frame edge boundaries" {
    const light = "─" ** 15;
    try expectEdges(20, null, .{ "─" ** 20, "─" ** 20 });
    try expectEdges(20, .{ .motion_tick = 0, .progress_age_ticks = 0 }, .{
        "╼━━━━╾" ++ "─" ** 14,
        "─" ** 20,
    });
    try expectEdges(20, .{ .motion_tick = 15, .progress_age_ticks = 0 }, .{
        light ++ "╼━━━╾",
        "━" ++ "─" ** 19,
    });
    try expectEdges(20, .{ .motion_tick = 35, .progress_age_ticks = 0 }, .{
        "━" ++ "─" ** 19,
        light ++ "╼━━━╾",
    });
}

fn expectEdges(columns: usize, activity: ?Activity, edges: [2][]const u8) !void {
    const gpa = std.testing.allocator;
    const painted = try paintedFramed(gpa, columns, &.{
        .body = "x",
        .body_rows = 1,
        .activity = activity,
    });
    defer gpa.free(painted);
    const plain = try terminal.testing.plainText(gpa, painted);
    defer gpa.free(plain);
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    try std.testing.expectEqualStrings(edges[0], rows.next().?);
    try std.testing.expectEqualStrings("x", rows.next().?);
    try std.testing.expectEqualStrings(edges[1], rows.next().?);
}

test "activity moves across the complete virtual line" {
    const steps = [_][2][]const u8{
        .{ "╼━━━╾", "─────" },
        .{ "─╼━━╾", "━────" },
        .{ "──╼━╾", "╼╾───" },
        .{ "───╼╾", "╼━╾──" },
        .{ "────━", "╼━━╾─" },
        .{ "─────", "╼━━━╾" },
        .{ "━────", "─╼━━╾" },
        .{ "╼╾───", "──╼━╾" },
        .{ "╼━╾──", "───╼╾" },
        .{ "╼━━╾─", "────━" },
        .{ "╼━━━╾", "─────" },
    };
    for (steps, 0..) |edges, tick| {
        try expectEdges(5, .{ .motion_tick = tick, .progress_age_ticks = 0 }, edges);
    }

    try std.testing.expect(activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 0, .caret_tick = 1 },
        5,
    ));
    try std.testing.expect(activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 31, .caret_tick = 1 },
        1,
    ));
    try std.testing.expect(!activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 31, .caret_tick = 1 },
        0,
    ));
}

test "each flip of the caret blink repaints" {
    try std.testing.expect(activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 0, .caret_tick = caret_blink_ticks },
        0,
    ));
    try std.testing.expect(!activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 0, .caret_tick = caret_blink_ticks + 1 },
        0,
    ));
    try std.testing.expect(!activityChanged(&.{ .motion_tick = 0, .progress_age_ticks = 0 }, 0));
}

test "an animated input places its caret on the first of two equal halves alone" {
    const gpa = std.testing.allocator;
    const samples = [_]struct { caret_tick: u64, shown: bool }{
        .{ .caret_tick = 0, .shown = true },
        .{ .caret_tick = caret_blink_ticks - 1, .shown = true },
        .{ .caret_tick = caret_blink_ticks, .shown = false },
        .{ .caret_tick = 2 * caret_blink_ticks - 1, .shown = false },
        .{ .caret_tick = 2 * caret_blink_ticks, .shown = true },
    };
    for (samples) |sample| {
        var rig: testing.Rig = undefined;
        rig.init(gpa);
        defer rig.deinit();

        const placement = try rig.begin(&.{ .columns = 20, .rows = 4 });
        try framed(&placement, &.{
            .body = "hi",
            .body_rows = 1,
            .caret = .{ .row = 1, .column = 2 },
            .activity = .{
                .motion_tick = 0,
                .progress_age_ticks = 0,
                .caret_tick = sample.caret_tick,
            },
        });
        const shown = std.mem.indexOf(u8, try rig.painted(), terminal.escape.cursor_show) != null;
        try std.testing.expectEqual(sample.shown, shown);
    }
}

fn paintedFramed(gpa: std.mem.Allocator, columns: usize, framing: *const Framing) ![]u8 {
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = columns, .rows = 8 });
    try framed(&placement, framing);
    return gpa.dupe(u8, try rig.painted());
}

test "a framed row paints a mark in its role and keeps the rest plain" {
    const gpa = std.testing.allocator;
    const marker = "\u{200B}[Paste #1: 11 lines]\u{200B}";
    const body = "ab" ++ marker ++ "cd";
    const painted = try paintedFramed(gpa, 40, &.{
        .body = body,
        .body_rows = 1,
        .marks = &.{.{ .start = 2, .end = 2 + marker.len, .role = .accent }},
    });
    defer gpa.free(painted);
    const row = comptime "\r\nab" ++ role.sequence(.accent) ++ marker ++ "\x1b[0mcd\r\n";
    try testing.expectShows(painted, &.{row});
}

test "a mark that wraps keeps its role on every row it crosses" {
    const gpa = std.testing.allocator;
    const marker = "\u{200B}[Paste #1: 11 lines]\u{200B}";
    const painted = try paintedFramed(gpa, 12, &.{
        .body = marker,
        .body_rows = 2,
        .marks = &.{.{ .start = 0, .end = marker.len, .role = .accent }},
    });
    defer gpa.free(painted);
    const opened = comptime "\r\n" ++ role.sequence(.accent) ++ "\u{200B}[Paste #1:\x1b[0m\r\n";
    const carried = comptime "\r\n" ++ role.sequence(.accent) ++ "11 lines]\u{200B}\x1b[0m\r\n";
    try testing.expectShows(painted, &.{opened});
    try testing.expectShows(painted, &.{carried});
}

test "a mark can underline without a link" {
    const gpa = std.testing.allocator;
    const painted = try paintedFramed(gpa, 40, &.{
        .body = "ab",
        .body_rows = 1,
        .marks = &.{.{ .start = 0, .end = 2, .role = .text, .underline = true }},
    });
    defer gpa.free(painted);
    const row = comptime "\r\n" ++ attribute.sequence(.underline) ++ "ab\x1b[0m\r\n";
    try testing.expectShows(painted, &.{row});
}

test "a line role resumes behind a mark" {
    const gpa = std.testing.allocator;
    const roles = [_]role.Name{.muted};
    const painted = try paintedFramed(gpa, 40, &.{
        .body = "ab[x]cd",
        .body_rows = 1,
        .line_roles = &roles,
        .marks = &.{.{ .start = 2, .end = 5, .role = .accent }},
    });
    defer gpa.free(painted);
    const row = comptime "\r\n" ++ role.sequence(.muted) ++ "ab" ++ role.sequence(.accent) ++
        "[x]\x1b[0m" ++ role.sequence(.muted) ++ "cd\x1b[0m\r\n";
    try testing.expectShows(painted, &.{row});
}

test "activity segment grows after a quiet grace period up to one frame edge" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { age_ticks: u64, columns: usize, cells: usize }{
        .{ .age_ticks = 0, .columns = 50, .cells = 6 },
        .{ .age_ticks = 30, .columns = 50, .cells = 6 },
        .{ .age_ticks = 31, .columns = 50, .cells = 7 },
        .{ .age_ticks = 36, .columns = 50, .cells = 7 },
        .{ .age_ticks = 37, .columns = 50, .cells = 8 },
        .{ .age_ticks = 283, .columns = 50, .cells = 49 },
        .{ .age_ticks = 288, .columns = 50, .cells = 49 },
        .{ .age_ticks = 289, .columns = 50, .cells = 50 },
        .{ .age_ticks = 300, .columns = 50, .cells = 50 },
        .{ .age_ticks = 0, .columns = 4, .cells = 4 },
        .{ .age_ticks = 0, .columns = 1, .cells = 1 },
    };
    for (cases) |case| {
        const painted = try paintedFramed(gpa, case.columns, &.{
            .body = "x",
            .body_rows = 1,
            .activity = .{ .motion_tick = 0, .progress_age_ticks = case.age_ticks },
        });
        defer gpa.free(painted);
        var cells: usize = 0;
        for ([_][]const u8{ "━", "╼", "╾" }) |glyph| cells += std.mem.count(u8, painted, glyph);
        try std.testing.expectEqual(case.cells, cells);
    }
}

test "overflow labels compact before disappearing" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { columns: usize, label: ?[]const u8 }{
        .{ .columns = 18, .label = "↑ Hidden: 17" },
        .{ .columns = 9, .label = "↑17" },
        .{ .columns = 8, .label = null },
    };
    for (cases) |case| {
        const painted = try paintedFramed(gpa, case.columns, &.{
            .body = "a\n" ** 17 ++ "x",
            .body_rows = 1,
            .hidden_above = 17,
        });
        defer gpa.free(painted);
        if (case.label) |label|
            try testing.expectShows(painted, &.{label})
        else
            try testing.expectHides(painted, &.{"↑"});
    }
}

test "a notice keeps its text where the prefix fills the row" {
    const gpa = std.testing.allocator;
    const style: NoticeStyle = .{ .role = .@"error", .prefix = "Error: " };
    const plain = try paintedNotice(gpa, &style, "boom", 7);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Error: \r\nboom", plain);
    try std.testing.expectEqual(@as(usize, 2), noticeRows(&style, "boom", 7));
}

fn expectCut(shown: *const Cut, kept: []const u8, shortened: bool) !void {
    try std.testing.expectEqualStrings(kept, shown.kept);
    try std.testing.expectEqual(shortened, shown.shortened);
}

test "a cut always leaves the mark a column of its own" {
    try expectCut(&cut("ab", 2), "ab", false);
    try expectCut(&cut("abc", 2), "a", true);
    try expectCut(&cut("\u{4F60}ab", 3), "\u{4F60}", true);
    try expectCut(&cut("\u{4F60}x", 2), "", true);
    try expectCut(&cut("\u{4F60}x", 1), "", true);
    for ([_][]const u8{ "abc", "\u{4F60}x", "a\u{4F60}b", "\u{4F60}\u{4F60}" }) |text| {
        for (1..6) |columns| {
            const shown = cut(text, columns);
            const columns_used = terminal.width.ofText(shown.kept) + @intFromBool(shown.shortened);
            try std.testing.expect(columns_used <= columns);
        }
    }
}

fn paintedNotice(
    gpa: std.mem.Allocator,
    style: *const NoticeStyle,
    text: []const u8,
    columns: usize,
) ![]u8 {
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = columns, .rows = 100 });
    try notice(&placement, style, text);
    return terminal.testing.plainText(gpa, try rig.painted());
}

test "a notice breaks its rows at a separator" {
    const gpa = std.testing.allocator;
    const parts = [_][]const u8{
        "Enter: Send",
        "Shift+Enter: New line",
        "Esc: Cancel",
        "/help: Commands",
    };
    const text = parts[0] ++ separator ++ parts[1] ++ separator ++ parts[2] ++
        separator ++ parts[3];
    const style: NoticeStyle = .{ .role = .muted };
    for ([_]usize{ 98, 60, 40, 22, 12 }) |columns| {
        const plain = try paintedNotice(gpa, &style, text, columns);
        defer gpa.free(plain);
        var rows = std.mem.splitSequence(u8, plain, "\r\n");
        var count: usize = 0;
        while (rows.next()) |row| : (count += 1) {
            try std.testing.expect(terminal.width.ofText(row) <= columns);
            try std.testing.expect(!std.mem.startsWith(u8, row, "\u{00B7}"));
            try std.testing.expect(!std.mem.endsWith(u8, row, "\u{00B7}"));
        }
        try std.testing.expectEqual(noticeRows(&style, text, columns), count);
        if (columns < 21) continue;
        for (parts) |part| try testing.expectShows(plain, &.{part});
    }
    const plain = try paintedNotice(gpa, &style, text, 40);
    defer gpa.free(plain);
    try std.testing.expect(std.mem.indexOf(
        u8,
        plain,
        "Enter: Send \u{00B7} Shift+Enter: New line\r\n",
    ) != null);

    const narrow = try paintedNotice(gpa, &style, text, 12);
    defer gpa.free(narrow);
    var narrow_rows = std.mem.splitSequence(u8, narrow, "\r\n");
    try std.testing.expectEqualStrings("Enter: Send", narrow_rows.next().?);
    try std.testing.expectEqualStrings("Shift+Enter" ++ ellipsis, narrow_rows.next().?);
    try std.testing.expectEqualStrings("Esc: Cancel", narrow_rows.next().?);
    try std.testing.expectEqualStrings("/help: Comm" ++ ellipsis, narrow_rows.next().?);
    try std.testing.expect(narrow_rows.next() == null);
}

test "a notice sentence breaks between its words and keeps its tail" {
    const gpa = std.testing.allocator;
    const style: NoticeStyle = .{ .role = .muted };
    const text = "Drinky could not open the file because of error AccessDenied.";
    const plain = try paintedNotice(gpa, &style, text, 20);
    defer gpa.free(plain);

    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    while (rows.next()) |row| {
        try std.testing.expect(terminal.width.ofText(row) <= 20);
        try std.testing.expect(!std.mem.endsWith(u8, row, " "));
    }
    try testing.expectShows(plain, &.{"Drinky could not"});
    try testing.expectShows(plain, &.{"AccessDenied."});
    try testing.expectHides(plain, &.{ellipsis});
    const word = try paintedNotice(gpa, &style, "AccessDeniedError", 8);
    defer gpa.free(word);
    try std.testing.expectEqualStrings("AccessDe\r\nniedErro\r\nr", word);
}

test "a notice prefix opens its first row alone" {
    const gpa = std.testing.allocator;
    const style: NoticeStyle = .{ .role = .@"error", .prefix = "Error: " };
    const text = "Drinky could not read the file.\nTry again.";
    const plain = try paintedNotice(gpa, &style, text, 24);
    defer gpa.free(plain);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "Error: "));
    try std.testing.expect(std.mem.startsWith(u8, plain, "Error: Drinky could"));
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    var count: usize = 0;
    while (rows.next()) |row| : (count += 1) {
        try std.testing.expect(terminal.width.ofText(row) <= 24);
        if (count > 0) try std.testing.expect(!std.mem.startsWith(u8, row, " "));
    }
    try std.testing.expectEqual(noticeRows(&style, text, 24), count);
    try testing.expectShows(plain, &.{"Try again."});
}

test "a head notice keeps one row and marks its cut" {
    const gpa = std.testing.allocator;
    const style: NoticeStyle = .{ .role = .muted, .fit = .head };
    const text = "Drinky sends no message while a turn runs.\nnot another row";
    try std.testing.expectEqual(@as(usize, 1), noticeRows(&style, text, 16));

    const plain = try paintedNotice(gpa, &style, text, 16);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Drinky sends no" ++ ellipsis, plain);

    const short = try paintedNotice(gpa, &style, "Esc: Cancel", 16);
    defer gpa.free(short);
    try std.testing.expectEqualStrings("Esc: Cancel", short);

    const dropped = try paintedNotice(gpa, &style, "boom\nmore", 16);
    defer gpa.free(dropped);
    try std.testing.expectEqualStrings("boom" ++ ellipsis, dropped);

    const wide = try paintedNotice(gpa, &style, "\u{4F60}x", 2);
    defer gpa.free(wide);
    try std.testing.expectEqualStrings(ellipsis, wide);

    const tagged: NoticeStyle = .{ .role = .@"error", .prefix = "Error: ", .fit = .head };
    const filled = try paintedNotice(gpa, &tagged, "boom", 7);
    defer gpa.free(filled);
    try std.testing.expectEqualStrings("Error:" ++ ellipsis, filled);
    const fits = try paintedNotice(gpa, &tagged, "boom", 11);
    defer gpa.free(fits);
    try std.testing.expectEqualStrings("Error: boom", fits);
}

test "a notice prefix row stands for an empty first line" {
    const gpa = std.testing.allocator;
    const style: NoticeStyle = .{ .role = .@"error", .prefix = "Error: " };
    const plain = try paintedNotice(gpa, &style, "\nTry again.", 7);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Error: \r\nTry\r\nagain.", plain);
    try std.testing.expectEqual(@as(usize, 3), noticeRows(&style, "\nTry again.", 7));
}

test "a wide notice prefix fits in a one-column row" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    const style: NoticeStyle = .{ .role = .muted, .prefix = "你" };
    try std.testing.expectEqual(@as(usize, 3), noticeRows(&style, "hi", 1));
    try std.testing.expectEqual(@as(usize, 1), noticeRows(&style, "", 1));

    const placement = try rig.begin(&.{ .columns = 1, .rows = 8 });
    try notice(&placement, &style, "hi");

    const plain = try rig.plain();
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    try std.testing.expectEqualStrings("\u{FFFD}", rows.next().?);
    try std.testing.expectEqualStrings("h", rows.next().?);
    try std.testing.expectEqualStrings("i", rows.next().?);
    try std.testing.expect(rows.next() == null);
}

test "the body limit is a quarter of the viewport plus one, clamped to five and fifteen" {
    const cases = [_]struct { viewport_rows: usize, rows: usize }{
        .{ .viewport_rows = 0, .rows = 5 },
        .{ .viewport_rows = 19, .rows = 5 },
        .{ .viewport_rows = 20, .rows = 6 },
        .{ .viewport_rows = 23, .rows = 6 },
        .{ .viewport_rows = 24, .rows = 7 },
        .{ .viewport_rows = 56, .rows = 15 },
        .{ .viewport_rows = 200, .rows = 15 },
    };
    for (cases) |case| {
        const extent: Window.Extent = .{
            .body_rows = std.math.maxInt(usize),
            .viewport_rows = case.viewport_rows,
        };
        try std.testing.expectEqual(case.rows, extent.visibleRows());
    }
}
