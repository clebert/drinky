const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const role = @import("role.zig");

const activity_length_default: usize = 6;
const activity_growth_delay_ticks: u64 = 31;
const activity_growth_interval_ticks: u64 = 6;
const caret_blink_ticks: u64 = 37;

pub const Notice = struct {
    role: role.Name,
    prefix: []const u8 = "",
    fit: Fit = .wrap,
};

pub const separator = " \u{00B7} ";

pub const information_prefix = "ℹ ";
pub const warning_prefix = "⚠ ";
pub const note_prefix = "→ ";

const Row = struct { end: usize, next: usize, marked: bool = false };

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
            return .{ .kept = "", .marked = false };
        }
        const room = @max(self.columns -| lead, 1);
        const line_end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
        const line = lineText(self.rest[0..line_end]);
        if (self.fresh) self.legend = std.mem.indexOf(u8, line, separator) != null;
        const row = nextRow(line, room, self.legend);
        self.fresh = row.next >= line.len;
        if (!self.fresh) {
            self.rest = self.rest[row.next..];
        } else if (line_end < self.rest.len) {
            self.rest = self.rest[line_end + 1 ..];
        } else {
            self.done = true;
        }
        return .{ .kept = terminal.width.rowText(line[0..row.end]), .marked = row.marked };
    }
};

fn nextRow(line: []const u8, room: usize, legend: bool) Row {
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
        if (legend) {
            const shown = cut(piece, room);
            return .{ .end = shown.kept.len, .next = behind, .marked = shown.marked };
        }
        var iterator = terminal.width.wrapper(piece, room);
        const span = iterator.nextSpan().?;
        if (span.end == piece.len) return .{ .end = piece_end, .next = behind };
        return .{ .end = span.end, .next = span.end };
    }
    return .{ .end = end, .next = line.len };
}

pub fn noticeRows(look: *const Notice, text: []const u8, columns: usize) usize {
    if (look.fit == .head) return 1;
    var wrap = noticeWrap(look, text, columns);
    var count: usize = 0;
    while (wrap.next()) |_| count += 1;
    return count;
}

fn noticeWrap(look: *const Notice, text: []const u8, columns: usize) Wrap {
    return .{
        .rest = text,
        .columns = columns,
        .lead = terminal.width.ofText(terminal.width.truncate(look.prefix, columns)),
    };
}

const Line = struct {
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
    url: ?[]const u8 = null,
    underline: bool = false,
};

pub const Placement = struct {
    sink: *terminal.View.Sink,
    id: usize,
    columns: usize,
    base: usize,
    skip: usize,
};

pub const Fit = enum {
    wrap,
    head,
};

pub const Box = struct {
    text: []const u8,
    fit: Fit = .wrap,
    emphasis: Emphasis = .none,

    pub const Emphasis = enum {
        none,
        first_value,
    };
};

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
        .wrap => terminal.width.rows(lineText(line), contentColumns(columns)),
        .head => 1,
    };
    return count;
}

pub const Activity = struct {
    motion_tick: u64,
    progress_age_ticks: u64,
    caret_tick: ?u64 = null,
};

pub fn activityChanged(activity: *const Activity, columns: usize) bool {
    if (activity.caret_tick) |caret_tick| if (caretBlinkChanged(caret_tick)) return true;
    if (columns == 0) return false;
    return activityHead(activity.motion_tick, columns) !=
        activityHead(activity.motion_tick -% 1, columns);
}

pub fn contentColumns(columns: usize) usize {
    return @max(columns, 1);
}

pub const ellipsis = "…";

pub const Cut = struct { kept: []const u8, marked: bool };

pub fn cut(text: []const u8, columns_max: usize) Cut {
    const shown = terminal.width.truncate(text, columns_max);
    if (shown.len == text.len) return .{ .kept = shown, .marked = false };
    const room = columns_max -| 1;
    const kept = terminal.width.truncate(text, room);
    if (terminal.width.ofText(kept) > room) return .{ .kept = "", .marked = true };
    return .{ .kept = kept, .marked = true };
}

fn lineText(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

pub fn notice(placement: *const Placement, look: *const Notice, text: []const u8) !void {
    if (look.fit == .head) return noticeHead(placement, look, text);
    const shown_prefix = terminal.width.truncate(look.prefix, placement.columns);
    var wrap = noticeWrap(look, text, placement.columns);
    var index: usize = 0;
    while (wrap.next()) |row| : (index += 1) {
        const line = placement.base + index;
        if (line < placement.skip) continue;
        placement.sink.begin();
        if (index == 0) try noticePrefix(placement.sink, look, shown_prefix);
        try noticeBody(placement.sink, look, row.kept, index == 0 and shown_prefix.len > 0);
        if (row.marked) try placement.sink.text(ellipsis);
        try attribute.apply(placement.sink, .reset);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
}

fn noticePrefix(sink: *terminal.View.Sink, look: *const Notice, prefix: []const u8) !void {
    if (prefix.len == 0) return;
    try role.apply(sink, look.role);
    try sink.text(prefix);
}

fn noticeBody(
    sink: *terminal.View.Sink,
    look: *const Notice,
    text: []const u8,
    role_active: bool,
) !void {
    if (!role_active) try role.apply(sink, look.role);
    try sink.text(text);
}

pub fn headCut(text: []const u8, columns_max: usize) Cut {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = lineText(text[0..line_end]);
    if (line_end == text.len) return cut(line, columns_max);
    return .{ .kept = terminal.width.truncate(line, columns_max -| 1), .marked = true };
}

const Head = struct { label: []const u8, kept: []const u8, marked: bool };

fn headRow(label: []const u8, text: []const u8, columns: usize) Head {
    const shown_label = terminal.width.truncate(label, columns);
    const room = columns -| terminal.width.ofText(shown_label);
    const shown = headCut(text, room);
    if (room > 0 or !shown.marked) return .{
        .label = shown_label,
        .kept = shown.kept,
        .marked = shown.marked,
    };
    return .{
        .label = terminal.width.truncate(shown_label, columns -| 1),
        .kept = "",
        .marked = true,
    };
}

fn noticeHead(placement: *const Placement, look: *const Notice, text: []const u8) !void {
    if (placement.base < placement.skip) return;
    const row = headRow(look.prefix, text, placement.columns);
    placement.sink.begin();
    try noticePrefix(placement.sink, look, row.label);
    try noticeBody(placement.sink, look, row.kept, row.label.len > 0);
    if (row.marked) try placement.sink.text(ellipsis);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

pub fn box(placement: *const Placement, name: role.Name, body: *const Box) !void {
    var line = placement.base;
    try boxPad(placement, &line, name);
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
                var iterator = terminal.width.wrapper(content, contentColumns(placement.columns));
                while (iterator.nextSpan()) |span| {
                    try boxLine(placement, &line, &.{
                        .content = terminal.width.rowText(content[span.start..span.end]),
                        .fit = .wrap,
                        .run = rowRun(run, offset + span.start),
                        .role = name,
                    });
                }
            },
            .head => try boxLine(placement, &line, &.{
                .content = content,
                .fit = .head,
                .run = rowRun(run, offset),
                .role = name,
            }),
        }
    }
    try boxPad(placement, &line, name);
}

fn rowRun(run: Run, offset: usize) Run {
    return .{ .start = run.start -| offset, .end = run.end -| offset };
}

fn boxPad(placement: *const Placement, line: *usize, name: role.Name) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    try role.apply(placement.sink, name);
    try placement.sink.spaces(placement.columns);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

fn boxLine(placement: *const Placement, line: *usize, row: *const Line) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    try role.apply(placement.sink, row.role);
    try boxLineCells(placement.sink, placement.columns, row);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

fn boxLineCells(sink: *terminal.View.Sink, columns: usize, row: *const Line) !void {
    const room = contentColumns(columns);
    switch (row.fit) {
        .wrap => try boxLineText(sink, terminal.width.truncate(row.content, room), row),
        .head => {
            const shown = cut(row.content, room);
            try boxLineText(sink, shown.kept, row);
            if (shown.marked) try sink.text(ellipsis);
        },
    }
    try sink.spaces(columns -| sink.columns_written);
}

fn boxLineText(sink: *terminal.View.Sink, text: []const u8, row: *const Line) !void {
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

const frame_separator_rows = 2;

pub fn framedRows(body_rows: usize) usize {
    return frame_separator_rows + body_rows;
}

pub fn bodyLimit(viewport_rows: usize) usize {
    return @min(@max(@divFloor(viewport_rows, 4) + 1, 5), 15);
}

pub const Framing = struct {
    body: []const u8,
    body_rows: usize,
    caret: ?terminal.View.Caret = null,
    hidden_above: usize = 0,
    hidden_below: usize = 0,
    trailing_row: bool = false,
    line_roles: []const ?role.Name = &.{},
    marks: []const Mark = &.{},
    activity: ?Activity = null,
};

const Rule = enum { top, bottom };

const SeparatorGlyph = enum {
    light,
    heavy,
    left_light_right_heavy,
    left_heavy_right_light,
};

const Separators = struct {
    columns: usize,
    activity: ?Activity,
};

const SeparatorCell = struct { glyph: SeparatorGlyph, active: bool };
const HorizontalWeights = struct { left: bool, right: bool };
const RuleRange = struct { rule: Rule, start: usize, end: usize };
const LabelOptions = struct { arrow: []const u8, more: usize, columns: usize };

pub fn framed(placement: *const Placement, framing: *const Framing) !void {
    const content_columns = contentColumns(placement.columns);
    const maybe_activity = framing.activity;
    const separators: Separators = .{
        .columns = placement.columns,
        .activity = maybe_activity,
    };
    const caret_shown = if (maybe_activity) |activity|
        caretVisible(activity.caret_tick orelse 0)
    else
        true;
    const maybe_caret = if (caret_shown) framing.caret else null;
    var line = placement.base;
    try ruleRow(placement, &separators, &line, .top, "↑", framing.hidden_above);
    var iterator = terminal.width.wrapper(framing.body, content_columns);
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
        try framedRow(placement, maybe_caret, &line, &.{
            .content = content,
            .offset = span.start,
            .role = maybe_role,
            .marks = framing.marks,
        });
        body_count += 1;
    }
    if (framing.trailing_row and index >= framing.hidden_above and index < window_end) {
        try framedRow(placement, maybe_caret, &line, &.{ .content = "" });
        body_count += 1;
    }
    std.debug.assert(body_count == framing.body_rows);
    try ruleRow(placement, &separators, &line, .bottom, "↓", framing.hidden_below);
}

const FramedRow = struct {
    content: []const u8,
    offset: usize = 0,
    role: ?role.Name = null,
    marks: []const Mark = &.{},
};

fn framedRow(
    placement: *const Placement,
    maybe_caret: ?terminal.View.Caret,
    line: *usize,
    row: *const FramedRow,
) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    if (row.role) |name| try role.apply(placement.sink, name);
    try framedRowText(placement.sink, row);
    if (row.role != null) try attribute.apply(placement.sink, .reset);
    if (maybe_caret) |caret|
        if (placement.base + caret.row == line.*) placement.sink.setCaret(caret.column);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
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
        if (mark.underline or mark.url != null) try attribute.apply(sink, .underline);
        if (mark.url) |url| {
            try sink.linkSet(url);
        }
        try sink.text(text[start..end]);
        try sink.linkReset();
        try attribute.apply(sink, .reset);
        if (row.role) |name| try role.apply(sink, name);
        position = end;
    }
    try sink.text(text[position..]);
}

fn ruleRow(
    placement: *const Placement,
    separators: *const Separators,
    line: *usize,
    rule: Rule,
    arrow: []const u8,
    more: usize,
) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    try ruleCells(placement.sink, separators, rule, arrow, more);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

fn ruleCells(
    sink: *terminal.View.Sink,
    separators: *const Separators,
    rule: Rule,
    arrow: []const u8,
    more: usize,
) !void {
    var buffer: [32]u8 = undefined;
    const maybe_label = moreLabel(&buffer, &.{
        .arrow = arrow,
        .more = more,
        .columns = separators.columns,
    });
    if (maybe_label) |label| {
        const label_start = 3;
        const label_end = label_start + 1 + terminal.width.ofText(label) + 1;
        try drawRuleRange(sink, separators, &.{
            .rule = rule,
            .start = 0,
            .end = label_start,
        });
        try role.apply(sink, .muted);
        try sink.text(" ");
        try sink.text(label);
        try sink.text(" ");
        try attribute.apply(sink, .reset);
        try drawRuleRange(sink, separators, &.{
            .rule = rule,
            .start = label_end,
            .end = separators.columns,
        });
    } else {
        try drawRuleRange(sink, separators, &.{
            .rule = rule,
            .start = 0,
            .end = separators.columns,
        });
    }
}

fn moreLabel(buffer: *[32]u8, options: *const LabelOptions) ?[]const u8 {
    if (options.more == 0) return null;
    const full = std.fmt.bufPrint(buffer, "{s} Hidden: {d}", .{
        options.arrow,
        options.more,
    }) catch return null;
    if (labelFits(options.columns, full)) return full;
    const compact = std.fmt.bufPrint(buffer, "{s}{d}", .{
        options.arrow,
        options.more,
    }) catch return null;
    return if (labelFits(options.columns, compact)) compact else null;
}

fn labelFits(columns: usize, label: []const u8) bool {
    const lead = 3;
    const used = lead + 1 + terminal.width.ofText(label) + 1;
    return columns > used;
}

fn drawRuleRange(
    sink: *terminal.View.Sink,
    separators: *const Separators,
    options: *const RuleRange,
) !void {
    std.debug.assert(options.start <= options.end and options.end <= separators.columns);
    var first = true;
    var active = false;
    var column = options.start;
    while (column < options.end) {
        const cell = separatorCell(separators, options.rule, column);
        if (first or cell.active != active) {
            first = false;
            active = cell.active;
            try role.apply(sink, if (active) .activity else .input_frame);
        }
        var run_end = column + 1;
        while (run_end < options.end) : (run_end += 1) {
            const next = separatorCell(separators, options.rule, run_end);
            if (next.active != cell.active or next.glyph != cell.glyph) break;
        }
        try writeSeparatorGlyph(sink, cell.glyph, run_end - column);
        column = run_end;
    }
}

fn separatorCell(separators: *const Separators, rule: Rule, column: usize) SeparatorCell {
    std.debug.assert(column < separators.columns);
    const active = activityAt(separators, rule, column);
    const left = active and column > 0 and activityAt(separators, rule, column - 1);
    const right = active and column + 1 < separators.columns and
        activityAt(separators, rule, column + 1);
    return .{
        .glyph = if (active)
            activityGlyph(.{ .left = left, .right = right })
        else
            .light,
        .active = active,
    };
}

fn activityAt(separators: *const Separators, rule: Rule, column: usize) bool {
    const maybe_activity = separators.activity;
    if (maybe_activity) |activity| {
        const position = switch (rule) {
            .top => column,
            .bottom => separators.columns + column,
        };
        const track_columns = 2 * separators.columns;
        const head = activityHead(activity.motion_tick, separators.columns);
        const distance = if (head >= position)
            head - position
        else
            track_columns - (position - head);
        return distance < activityLength(activity.progress_age_ticks, separators.columns);
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

fn activityGlyph(weights: HorizontalWeights) SeparatorGlyph {
    if (weights.left) return if (weights.right)
        .heavy
    else
        .left_heavy_right_light;
    return if (weights.right) .left_light_right_heavy else .heavy;
}

fn writeSeparatorGlyph(
    sink: *terminal.View.Sink,
    glyph: SeparatorGlyph,
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
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const text = "one two three four five";
    const columns = 14;
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 8 }, 1);
    try box(&.{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    }, .user, &.{ .text = text });
    try view.render();

    const painted = output.written();
    try std.testing.expectEqual(@as(usize, 4), boxRows(&.{ .text = text }, columns));
    try std.testing.expect(std.mem.indexOf(u8, painted, "one two three") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "four five") != null);
}

test "every row leaves the complete width to content" {
    try std.testing.expectEqual(@as(usize, 1), contentColumns(0));
    try std.testing.expectEqual(@as(usize, 1), contentColumns(1));
    try std.testing.expectEqual(@as(usize, 2), contentColumns(2));
    try std.testing.expectEqual(@as(usize, 80), contentColumns(80));
}

test "a box row sheds the carriage return of a CRLF break" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const columns = 20;
    const body: Box = .{ .text = "first line\r\nsecond line" };
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 8 }, 1);
    try box(&.{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    }, .user, &body);
    try view.render();

    const painted = output.written();
    try std.testing.expectEqual(@as(usize, 4), boxRows(&body, columns));
    try std.testing.expect(std.mem.indexOf(u8, painted, "first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "second line") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\u{FFFD}") == null);
}

test "a fitted box holds one row per line" {
    const gpa = std.testing.allocator;
    const columns = 20;
    const text = "Tool: write · File: src/App.zig\nLines: 1";
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const body: Box = .{ .text = text, .fit = .head };
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 8 }, 1);
    try box(&.{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    }, .tool_pending, &body);
    try view.render();

    const painted = output.written();
    try std.testing.expectEqual(@as(usize, 4), boxRows(&body, columns));
    try std.testing.expect(std.mem.indexOf(u8, painted, "Tool: write · File:\u{2026}") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Lines: 1") != null);
}

test "a box emphasizes the value of its first key" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const columns = 40;
    const body: Box = .{
        .text = "Tool: read \u{00B7} File: a.zig\nLines: 3",
        .fit = .head,
        .emphasis = .first_value,
    };
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 8 }, 1);
    try box(&.{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    }, .tool_success, &body);
    try view.render();

    const painted = output.written();
    const head = comptime "Tool: \x1b[1mread\x1b[0m" ++ role.sequence(.tool_success) ++
        " \u{00B7} File: a.zig";
    try std.testing.expect(std.mem.indexOf(u8, painted, head) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, "\x1b[1m"));

    const plain = try terminal.View.plainText(gpa, painted);
    defer gpa.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Tool: read \u{00B7} File: a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Lines: 3") != null);
}

test "a narrow box cuts its run and carries the rest to the next row" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const columns = 12;
    const body: Box = .{
        .text = "Tool: read_the_file \u{00B7} File: a",
        .emphasis = .first_value,
    };
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 8 }, 1);
    try box(&.{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    }, .tool_pending, &body);
    try view.render();

    const painted = output.written();
    const opened = comptime role.sequence(.tool_pending) ++ "\x1b[1mread_the_fil";
    const carried = comptime "\x1b[1me\x1b[0m" ++ role.sequence(.tool_pending) ++
        " \u{00B7} File: a";
    try std.testing.expect(std.mem.indexOf(u8, painted, opened) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, carried) != null);

    const plain = try terminal.View.plainText(gpa, painted);
    defer gpa.free(plain);
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    var count: usize = 0;
    while (rows.next()) |row| : (count += 1)
        try std.testing.expectEqual(columns, terminal.width.ofText(row));
    try std.testing.expectEqual(boxRows(&body, columns), count);
}

test "the emphasized run covers the first value alone" {
    try std.testing.expectEqual(Run{ .start = 6, .end = 10 }, firstValue(
        "Tool: read \u{00B7} File: a.zig\nLines: 3",
    ));
    try std.testing.expectEqual(Run{ .start = 6, .end = 21 }, firstValue("Tool: describe_drinky"));
    try std.testing.expectEqual(Run{}, firstValue("please read a.zig"));

    const run: Run = .{ .start = 6, .end = 10 };
    try std.testing.expectEqual(Run{ .start = 0, .end = 0 }, rowRun(run, 25));
    try std.testing.expectEqual(run, rowRun(run, 0));
}

test "activity at column zero emits no unused frame role" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 20, .rows = 1 }, 1);
    const placement: Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 20,
        .base = 0,
        .skip = 0,
    };
    const separators: Separators = .{
        .columns = 20,
        .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
    };
    var line: usize = 0;
    try ruleRow(&placement, &separators, &line, .top, "↑", 0);
    try view.render();

    const segment = comptime role.sequence(.activity) ++ "╼━━━━╾" ++
        role.sequence(.input_frame) ++ "─";
    try std.testing.expect(std.mem.indexOf(u8, output.written(), segment) != null);
    const unused = comptime role.sequence(.input_frame) ++ role.sequence(.activity);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), unused) == null);
}

test "a separator label reads as muted text between the frame glyphs" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 20, .rows = 1 }, 1);
    const placement: Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 20,
        .base = 0,
        .skip = 0,
    };
    const separators: Separators = .{ .columns = 20, .activity = null };
    var line: usize = 0;
    try ruleRow(&placement, &separators, &line, .top, "↑", 3);
    try view.render();

    const label = comptime role.sequence(.muted) ++ " ↑ Hidden: 3 \x1b[0m" ++
        role.sequence(.input_frame);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), label) != null);
}

test "a separator label resets faint before a right activity segment" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 20, .rows = 1 }, 1);
    const placement: Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 20,
        .base = 0,
        .skip = 0,
    };
    const separators: Separators = .{
        .columns = 20,
        .activity = .{ .motion_tick = 16, .progress_age_ticks = 0 },
    };
    var line: usize = 0;
    try ruleRow(&placement, &separators, &line, .top, "↑", 3);
    try view.render();

    const segment = comptime role.sequence(.muted) ++ " ↑ Hidden: 3 \x1b[0m" ++
        role.sequence(.activity) ++ "╼";
    try std.testing.expect(std.mem.indexOf(u8, output.written(), segment) != null);
}

test "one activity segment starts at the top left and crosses both separator seams" {
    const idle: Separators = .{ .columns = 20, .activity = null };
    try std.testing.expectEqual(.light, separatorCell(&idle, .top, 0).glyph);

    const first: Separators = .{
        .columns = 20,
        .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
    };
    try std.testing.expectEqual(.left_light_right_heavy, separatorCell(&first, .top, 0).glyph);
    try std.testing.expectEqual(.heavy, separatorCell(&first, .top, 1).glyph);
    try std.testing.expectEqual(.left_heavy_right_light, separatorCell(&first, .top, 5).glyph);
    try std.testing.expect(!activityAt(&first, .bottom, 0));

    const top_to_bottom: Separators = .{
        .columns = 20,
        .activity = .{ .motion_tick = 15, .progress_age_ticks = 0 },
    };
    try std.testing.expect(activityAt(&top_to_bottom, .top, 15));
    try std.testing.expect(activityAt(&top_to_bottom, .top, 19));
    try std.testing.expect(activityAt(&top_to_bottom, .bottom, 0));
    try std.testing.expect(!activityAt(&top_to_bottom, .bottom, 1));

    const bottom_to_top: Separators = .{
        .columns = 20,
        .activity = .{ .motion_tick = 35, .progress_age_ticks = 0 },
    };
    try std.testing.expect(activityAt(&bottom_to_top, .bottom, 15));
    try std.testing.expect(activityAt(&bottom_to_top, .bottom, 19));
    try std.testing.expect(activityAt(&bottom_to_top, .top, 0));
    try std.testing.expect(!activityAt(&bottom_to_top, .top, 1));

    for ([_]Separators{ top_to_bottom, bottom_to_top }) |crossing| {
        var active_count: usize = 0;
        for (0..20) |column| {
            active_count += @intFromBool(activityAt(&crossing, .top, column));
            active_count += @intFromBool(activityAt(&crossing, .bottom, column));
        }
        try std.testing.expectEqual(@as(usize, activity_length_default), active_count);
    }
}

test "activity moves across the complete virtual line" {
    const expected = [_]usize{ 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4 };
    for (expected, 0..) |column, tick|
        try std.testing.expectEqual(column, activityHead(tick, 5));

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

test "the caret blinks in equal halves and each flip repaints" {
    try std.testing.expect(caretVisible(0));
    try std.testing.expect(caretVisible(caret_blink_ticks - 1));
    try std.testing.expect(!caretVisible(caret_blink_ticks));
    try std.testing.expect(!caretVisible(2 * caret_blink_ticks - 1));
    try std.testing.expect(caretVisible(2 * caret_blink_ticks));

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

test "an animated input places its caret only on the visible half" {
    const gpa = std.testing.allocator;
    const samples = [_]struct { caret_tick: u64, shown: bool }{
        .{ .caret_tick = 0, .shown = true },
        .{ .caret_tick = caret_blink_ticks, .shown = false },
    };
    for (samples) |sample| {
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        var view = terminal.View.init(gpa, &output.writer);
        defer view.deinit();

        const sink = try view.beginFrame(.{ .columns = 20, .rows = 4 }, 1);
        const placement: Placement = .{
            .sink = sink,
            .id = 0,
            .columns = 20,
            .base = 0,
            .skip = 0,
        };
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
        try view.render();
        const shown = std.mem.indexOf(u8, output.written(), terminal.escape.cursor_show) != null;
        try std.testing.expectEqual(sample.shown, shown);
    }
}

fn paintedFramed(gpa: std.mem.Allocator, columns: usize, framing: *const Framing) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 8 }, 1);
    try framed(&.{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    }, framing);
    try view.render();
    return gpa.dupe(u8, output.written());
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
    try std.testing.expect(std.mem.indexOf(u8, painted, row) != null);
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
    try std.testing.expect(std.mem.indexOf(u8, painted, opened) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, carried) != null);
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
    try std.testing.expect(std.mem.indexOf(u8, painted, row) != null);
}

test "a line role resumes behind a mark" {
    const gpa = std.testing.allocator;
    const roles = [_]?role.Name{.muted};
    const painted = try paintedFramed(gpa, 40, &.{
        .body = "ab[x]cd",
        .body_rows = 1,
        .line_roles = &roles,
        .marks = &.{.{ .start = 2, .end = 5, .role = .accent }},
    });
    defer gpa.free(painted);
    const row = comptime "\r\n" ++ role.sequence(.muted) ++ "ab" ++ role.sequence(.accent) ++
        "[x]\x1b[0m" ++ role.sequence(.muted) ++ "cd\x1b[0m\r\n";
    try std.testing.expect(std.mem.indexOf(u8, painted, row) != null);
}

test "activity segment grows after a quiet grace period up to one separator" {
    try std.testing.expectEqual(@as(usize, 6), activityLength(0, 50));
    try std.testing.expectEqual(@as(usize, 6), activityLength(30, 50));
    try std.testing.expectEqual(@as(usize, 7), activityLength(31, 50));
    try std.testing.expectEqual(@as(usize, 7), activityLength(36, 50));
    try std.testing.expectEqual(@as(usize, 8), activityLength(37, 50));
    try std.testing.expectEqual(@as(usize, 49), activityLength(283, 50));
    try std.testing.expectEqual(@as(usize, 49), activityLength(288, 50));
    try std.testing.expectEqual(@as(usize, 50), activityLength(289, 50));
    try std.testing.expectEqual(@as(usize, 50), activityLength(300, 50));
    try std.testing.expectEqual(@as(usize, 4), activityLength(0, 4));
    try std.testing.expectEqual(@as(usize, 1), activityLength(0, 1));
}

test "overflow labels compact before disappearing" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("↑ Hidden: 17", moreLabel(&buffer, &.{
        .arrow = "↑",
        .more = 17,
        .columns = 18,
    }).?);
    try std.testing.expectEqualStrings("↑17", moreLabel(&buffer, &.{
        .arrow = "↑",
        .more = 17,
        .columns = 9,
    }).?);
    try std.testing.expect(moreLabel(&buffer, &.{
        .arrow = "↑",
        .more = 17,
        .columns = 8,
    }) == null);
}

test "a notice keeps its text where the prefix fills the row" {
    const gpa = std.testing.allocator;
    const look: Notice = .{ .role = .@"error", .prefix = "Error: " };
    const plain = try paintedNotice(gpa, &look, "boom", 7);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Error: \r\nboom", plain);
    try std.testing.expectEqual(@as(usize, 2), noticeRows(&look, "boom", 7));
}

fn expectCut(shown: Cut, kept: []const u8, marked: bool) !void {
    try std.testing.expectEqualStrings(kept, shown.kept);
    try std.testing.expectEqual(marked, shown.marked);
}

test "a cut always leaves the mark a column of its own" {
    try expectCut(cut("ab", 2), "ab", false);
    try expectCut(cut("abc", 2), "a", true);
    try expectCut(cut("\u{4F60}ab", 3), "\u{4F60}", true);
    try expectCut(cut("\u{4F60}x", 2), "", true);
    try expectCut(cut("\u{4F60}x", 1), "", true);
    for ([_][]const u8{ "abc", "\u{4F60}x", "a\u{4F60}b", "\u{4F60}\u{4F60}" }) |text| {
        for (1..6) |columns| {
            const shown = cut(text, columns);
            const columns_used = terminal.width.ofText(shown.kept) + @intFromBool(shown.marked);
            try std.testing.expect(columns_used <= columns);
        }
    }
}

fn paintedNotice(
    gpa: std.mem.Allocator,
    look: *const Notice,
    text: []const u8,
    columns: usize,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 100 }, 1);
    try notice(&.{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    }, look, text);
    try view.render();
    return terminal.View.plainText(gpa, output.written());
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
    const look: Notice = .{ .role = .muted };
    for ([_]usize{ 98, 60, 40, 22, 12 }) |columns| {
        const plain = try paintedNotice(gpa, &look, text, columns);
        defer gpa.free(plain);
        var rows = std.mem.splitSequence(u8, plain, "\r\n");
        var count: usize = 0;
        while (rows.next()) |row| : (count += 1) {
            try std.testing.expect(terminal.width.ofText(row) <= columns);
            try std.testing.expect(!std.mem.startsWith(u8, row, "\u{00B7}"));
            try std.testing.expect(!std.mem.endsWith(u8, row, "\u{00B7}"));
        }
        try std.testing.expectEqual(noticeRows(&look, text, columns), count);
        if (columns < 21) continue;
        for (parts) |part| try std.testing.expect(std.mem.indexOf(u8, plain, part) != null);
    }
    const plain = try paintedNotice(gpa, &look, text, 40);
    defer gpa.free(plain);
    try std.testing.expect(std.mem.indexOf(
        u8,
        plain,
        "Enter: Send \u{00B7} Shift+Enter: New line\r\n",
    ) != null);

    const narrow = try paintedNotice(gpa, &look, text, 12);
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
    const look: Notice = .{ .role = .muted };
    const text = "Drinky could not open the file because of error AccessDenied.";
    const plain = try paintedNotice(gpa, &look, text, 20);
    defer gpa.free(plain);

    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    while (rows.next()) |row| {
        try std.testing.expect(terminal.width.ofText(row) <= 20);
        try std.testing.expect(!std.mem.endsWith(u8, row, " "));
    }
    try std.testing.expect(std.mem.indexOf(u8, plain, "Drinky could not") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "AccessDenied.") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, ellipsis) == null);
    const word = try paintedNotice(gpa, &look, "AccessDeniedError", 8);
    defer gpa.free(word);
    try std.testing.expectEqualStrings("AccessDe\r\nniedErro\r\nr", word);
}

test "a notice prefix opens its first row alone" {
    const gpa = std.testing.allocator;
    const look: Notice = .{ .role = .@"error", .prefix = "Error: " };
    const text = "Drinky could not read the file.\nTry again.";
    const plain = try paintedNotice(gpa, &look, text, 24);
    defer gpa.free(plain);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "Error: "));
    try std.testing.expect(std.mem.startsWith(u8, plain, "Error: Drinky could"));
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    var count: usize = 0;
    while (rows.next()) |row| : (count += 1) {
        try std.testing.expect(terminal.width.ofText(row) <= 24);
        if (count > 0) try std.testing.expect(!std.mem.startsWith(u8, row, " "));
    }
    try std.testing.expectEqual(noticeRows(&look, text, 24), count);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Try again.") != null);
}

test "a head notice keeps one row and marks its cut" {
    const gpa = std.testing.allocator;
    const look: Notice = .{ .role = .muted, .fit = .head };
    const text = "Drinky returned every queued message\nnot another row";
    try std.testing.expectEqual(@as(usize, 1), noticeRows(&look, text, 16));

    const plain = try paintedNotice(gpa, &look, text, 16);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Drinky returned" ++ ellipsis, plain);

    const short = try paintedNotice(gpa, &look, "Ctrl+P: Edit", 16);
    defer gpa.free(short);
    try std.testing.expectEqualStrings("Ctrl+P: Edit", short);

    const dropped = try paintedNotice(gpa, &look, "boom\nmore", 16);
    defer gpa.free(dropped);
    try std.testing.expectEqualStrings("boom" ++ ellipsis, dropped);

    const wide = try paintedNotice(gpa, &look, "\u{4F60}x", 2);
    defer gpa.free(wide);
    try std.testing.expectEqualStrings(ellipsis, wide);

    const tagged: Notice = .{ .role = .@"error", .prefix = "Error: ", .fit = .head };
    const filled = try paintedNotice(gpa, &tagged, "boom", 7);
    defer gpa.free(filled);
    try std.testing.expectEqualStrings("Error:" ++ ellipsis, filled);
    const fits = try paintedNotice(gpa, &tagged, "boom", 11);
    defer gpa.free(fits);
    try std.testing.expectEqualStrings("Error: boom", fits);
}

test "a notice prefix row stands for an empty first line" {
    const gpa = std.testing.allocator;
    const look: Notice = .{ .role = .@"error", .prefix = "Error: " };
    const plain = try paintedNotice(gpa, &look, "\nTry again.", 7);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Error: \r\nTry\r\nagain.", plain);
    try std.testing.expectEqual(@as(usize, 3), noticeRows(&look, "\nTry again.", 7));
}

test "a wide notice prefix fits in a one-column row" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const look: Notice = .{ .role = .muted, .prefix = "你" };
    try std.testing.expectEqual(@as(usize, 3), noticeRows(&look, "hi", 1));
    try std.testing.expectEqual(@as(usize, 1), noticeRows(&look, "", 1));

    const sink = try view.beginFrame(.{ .columns = 1, .rows = 8 }, 1);
    const placement: Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 1,
        .base = 0,
        .skip = 0,
    };
    try notice(&placement, &look, "hi");
    try std.testing.expectEqual(@as(usize, 1), sink.columns_written);
    try view.render();

    const plain = try terminal.View.plainText(gpa, output.written());
    defer gpa.free(plain);
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    try std.testing.expectEqualStrings("\u{FFFD}", rows.next().?);
    try std.testing.expectEqualStrings("h", rows.next().?);
    try std.testing.expectEqualStrings("i", rows.next().?);
    try std.testing.expect(rows.next() == null);
}

test "the body limit tracks a quarter of the viewport, clamped to five and fifteen" {
    try std.testing.expectEqual(@as(usize, 5), bodyLimit(0));
    try std.testing.expectEqual(@as(usize, 5), bodyLimit(19));
    try std.testing.expectEqual(@as(usize, 6), bodyLimit(20));
    try std.testing.expectEqual(@as(usize, 6), bodyLimit(23));
    try std.testing.expectEqual(@as(usize, 7), bodyLimit(24));
    try std.testing.expectEqual(@as(usize, 15), bodyLimit(56));
    try std.testing.expectEqual(@as(usize, 15), bodyLimit(200));
}
