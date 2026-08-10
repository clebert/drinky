//! Row painters: the primitives that stream one styled row at a time straight
//! into the view's `Sink` through a `Placement`. They drop the clip's hidden top
//! rows, so a clipped component never materializes its whole body. The
//! transcript `block`s and the chrome (the tool box, the input frame, the
//! status line) share them.

const std = @import("std");

const terminal = @import("terminal");

const color = @import("color.zig");

const activity_length_default: usize = 6;
// At the 16 ms frame target, wait about 500 ms, then add one cell about every 100 ms.
const activity_growth_delay_ticks: u64 = 31;
const activity_growth_interval_ticks: u64 = 6;
const activity_vertical_ticks: usize = 2;

pub const BoxStyle = struct { background: color.Style, foreground: color.Style };

/// A notice's look: the SGR style that opens every line and a prefix (an error
/// tag, or empty) that prints before each line's text.
const Notice = struct { style: color.Style, prefix: []const u8 };

/// Where a component composes its rows: the sink to write into, the anchor `id`
/// its rows carry, the terminal width, the line its content starts at (`base`,
/// after any leading separator), and how many of its top rows to drop (`skip`,
/// nonzero only for the clip).
pub const Placement = struct {
    sink: *terminal.View.Sink,
    id: usize,
    columns: usize,
    base: usize,
    skip: usize,
};

/// The physical rows a box wraps `text` to at `columns`: the two padding rows
/// around the body plus the wrapped body itself.
pub fn boxRows(text: []const u8, columns: usize) usize {
    return 2 + terminal.width.rows(text, boxInner(columns));
}

/// Width and inset of framed content. Normal windows get a side, a one-cell
/// pad, content, another pad, and a side. Three- and four-column windows keep
/// their sides but shed the pads. Narrower windows fall back to open rows.
pub const FrameGeometry = struct {
    content_columns: usize,
    content_offset: usize,
    padding_columns: usize,
    closed: bool,
};

pub const Activity = struct {
    motion_tick: u64,
    progress_age_ticks: u64,
};

pub const ActivityGeometry = struct {
    columns: usize,
    body_rows: usize,
};

/// Whether `activity` changes the segment at this frame geometry.
pub fn activityChanged(activity: *const Activity, geometry: *const ActivityGeometry) bool {
    if (geometry.columns < 3) return false;
    const previous: Activity = .{
        .motion_tick = activity.motion_tick -% 1,
        .progress_age_ticks = activity.progress_age_ticks -| 1,
    };
    if (activityHead(activity.motion_tick, geometry) !=
        activityHead(previous.motion_tick, geometry)) return true;
    const perimeter = activityPerimeter(geometry);
    return activityLength(activity.progress_age_ticks, perimeter) !=
        activityLength(previous.progress_age_ticks, perimeter);
}

pub fn frameGeometry(columns: usize) FrameGeometry {
    if (columns >= 5) return .{
        .content_columns = columns - 4,
        .content_offset = 2,
        .padding_columns = 1,
        .closed = true,
    };
    if (columns >= 3) return .{
        .content_columns = columns - 2,
        .content_offset = 1,
        .padding_columns = 0,
        .closed = true,
    };
    return .{
        .content_columns = @max(columns, 1),
        .content_offset = 0,
        .padding_columns = 0,
        .closed = false,
    };
}

/// The wrap width inside a box: two columns narrower than the terminal, one for
/// the left pad and one to keep the fill off the last cell.
fn boxInner(columns: usize) usize {
    return @max(columns -| 2, 1);
}

/// Each `\n`-separated line of `text`, styled and truncated to one row, with the
/// notice's prefix on every line (a notice, error, or the intro).
pub fn notice(placement: *const Placement, look: *const Notice, text: []const u8) !void {
    var pieces = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (pieces.next()) |piece| : (index += 1) {
        const line = placement.base + index;
        if (line < placement.skip) continue;
        const shown_prefix = terminal.width.truncate(look.prefix, placement.columns);
        // Saturating: a cluster wider than the whole budget survives `truncate`
        // as a one-column replacement but measures its true width here. A prefix
        // that opens on one can then report more columns than the row has.
        const available = placement.columns -| terminal.width.ofText(shown_prefix);
        const clipped = terminal.width.truncate(piece, available);
        placement.sink.begin();
        try color.apply(placement.sink, look.style);
        try placement.sink.text(shown_prefix);
        try placement.sink.text(clipped);
        try color.apply(placement.sink, .reset);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
}

/// A padded background box: a blank padding row, `text` wrapped to the inner
/// width with a one-space left pad and the background filled to full width, then
/// a blank padding row. It streams a row at a time and self-separates inside the
/// block gap around it.
pub fn box(placement: *const Placement, style: *const BoxStyle, text: []const u8) !void {
    var line = placement.base;
    try boxPad(placement, &line, style.background);
    var iterator = terminal.width.wrapper(text, boxInner(placement.columns));
    while (iterator.next()) |content| try boxLine(placement, &line, style, content);
    try boxPad(placement, &line, style.background);
}

/// A box's blank padding row: the background filled to full width.
fn boxPad(placement: *const Placement, line: *usize, background: color.Style) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    try color.apply(placement.sink, background);
    try placement.sink.spaces(placement.columns);
    try color.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// A box's content row: a one-space left pad, `content`, then the background
/// filled to full width. A cap on `content` leaves room for the pad, so a
/// window too narrow for the wrap width still yields one physical row.
fn boxLine(
    placement: *const Placement,
    line: *usize,
    style: *const BoxStyle,
    content: []const u8,
) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    const shown = terminal.width.truncate(content, placement.columns -| 1);
    placement.sink.begin();
    try color.apply(placement.sink, style.background);
    try color.apply(placement.sink, style.foreground);
    try placement.sink.text(" ");
    try placement.sink.text(shown);
    try placement.sink.spaces(placement.columns -| (1 + terminal.width.ofText(shown)));
    try color.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

pub const frame_border_rows = 2;

/// The physical rows a framed area occupies: its two borders plus `body_rows`.
pub fn framedRows(body_rows: usize) usize {
    return frame_border_rows + body_rows;
}

/// The tallest a framed body can grow before it scrolls within its frame: about
/// a quarter of the viewport, never fewer than five rows nor more than fifteen.
/// The live input stays usable and does not crowd out the transcript. The
/// editor and the picker share it, so both window to the same limit.
pub fn bodyLimit(viewport_rows: usize) usize {
    return @min(@max(@divFloor(viewport_rows, 4) + 1, 5), 15);
}

/// A closed input area that contains a window of `body`'s wrapped rows. While
/// `activity` is set, a heavy segment travels around its border and grows as
/// progress goes quiet.
pub const Framing = struct {
    body: []const u8,
    body_rows: usize,
    /// When set, places the terminal caret on the body row it names
    /// (component-local row 0 is the top rule). The row counts relative to the
    /// window.
    caret: ?terminal.View.Caret = null,
    /// Body rows dropped above the window, and the top rule's "N more" count.
    hidden_above: usize = 0,
    /// Body rows dropped below the window, and the bottom rule's "N more" count.
    hidden_below: usize = 0,
    /// An extra empty body row after the wrapped body: the row a caret at a
    /// full-width final line wraps onto, which the wrap itself never yields. It
    /// is the last body row, so it shows only when the window reaches it.
    trailing_row: bool = false,
    /// Style per logical `\n`-delimited body line (lines past the end are plain).
    /// Wrapped continuations retain their source line's style.
    line_styles: []const ?color.Style = &.{},
    activity: ?Activity = null,
};

const Rule = enum { top, bottom };

const BorderShape = enum {
    top,
    right,
    bottom,
    left,
    top_left,
    top_right,
    bottom_right,
    bottom_left,
};

const BorderGlyph = enum {
    horizontal_light,
    horizontal_heavy,
    horizontal_left_light_right_heavy,
    horizontal_left_heavy_right_light,
    vertical_light,
    vertical_heavy,
    vertical_up_light_down_heavy,
    vertical_up_heavy_down_light,
    top_left_light,
    top_left_heavy,
    top_left_down_light_right_heavy,
    top_left_down_heavy_right_light,
    top_right_light,
    top_right_heavy,
    top_right_down_light_left_heavy,
    top_right_down_heavy_left_light,
    bottom_right_light,
    bottom_right_heavy,
    bottom_right_up_light_left_heavy,
    bottom_right_up_heavy_left_light,
    bottom_left_light,
    bottom_left_heavy,
    bottom_left_up_light_right_heavy,
    bottom_left_up_heavy_right_light,
};

const Border = struct {
    columns: usize,
    body_rows: usize,
    activity: ?Activity,

    fn perimeter(self: *const Border) usize {
        return 2 * self.columns + 2 * self.body_rows;
    }
};

const BorderCell = struct { glyph: BorderGlyph, accent: bool };
const PathWeights = struct { incoming: bool, outgoing: bool };
const HorizontalWeights = struct { left: bool, right: bool };
const VerticalWeights = struct { up: bool, down: bool };
const TopLeftWeights = struct { down: bool, right: bool };
const TopRightWeights = struct { down: bool, left: bool };
const BottomRightWeights = struct { up: bool, left: bool };
const BottomLeftWeights = struct { up: bool, right: bool };
const RuleRange = struct { rule: Rule, start: usize, end: usize };
const LabelOptions = struct { arrow: []const u8, more: usize, track_columns: usize };

/// Stream the framed area that `framing` describes: the labelled top border,
/// its windowed body rows, and the labelled bottom border.
pub fn framed(placement: *const Placement, framing: *const Framing) !void {
    const geometry = frameGeometry(placement.columns);
    const border: Border = .{
        .columns = placement.columns,
        .body_rows = framing.body_rows,
        .activity = if (geometry.closed) framing.activity else null,
    };
    var line = placement.base;
    try ruleRow(placement, &border, &line, .top, "↑", framing.hidden_above);
    var iterator = terminal.width.wrapper(framing.body, geometry.content_columns);
    const window_end = framing.hidden_above +| framing.body_rows;
    var source_offset: usize = 0;
    var source_line: usize = 0;
    var body_index: usize = 0;
    var index: usize = 0;
    while (iterator.next()) |content| : (index += 1) {
        const content_offset = @intFromPtr(content.ptr) - @intFromPtr(framing.body.ptr);
        source_line += std.mem.count(u8, framing.body[source_offset..content_offset], "\n");
        source_offset = content_offset;
        if (index < framing.hidden_above) continue;
        if (index >= window_end) break;
        const styles = framing.line_styles;
        const maybe_style = if (source_line < styles.len) styles[source_line] else null;
        try framedRow(
            placement,
            &geometry,
            &border,
            framing.caret,
            &line,
            body_index,
            content,
            maybe_style,
        );
        body_index += 1;
    }
    // The wrapper exhausts at `index == wrapped rows`, the trailing row's index.
    // Emit it when the window reaches it (a `break` above leaves it out of view).
    if (framing.trailing_row and index >= framing.hidden_above and index < window_end) {
        try framedRow(
            placement,
            &geometry,
            &border,
            framing.caret,
            &line,
            body_index,
            "",
            null,
        );
        body_index += 1;
    }
    std.debug.assert(body_index == framing.body_rows);
    try ruleRow(placement, &border, &line, .bottom, "↓", framing.hidden_below);
}

/// One wrapped body row inside the side walls, with the caret placed after the
/// left wall and padding. Advances `line` and drops the row in the clipped top.
fn framedRow(
    placement: *const Placement,
    geometry: *const FrameGeometry,
    border: *const Border,
    maybe_caret: ?terminal.View.Caret,
    line: *usize,
    body_index: usize,
    content: []const u8,
    maybe_style: ?color.Style,
) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    if (geometry.closed) {
        try writeBorderCell(placement.sink, sideCell(border, body_index, false));
        try color.apply(placement.sink, .reset);
        try placement.sink.spaces(geometry.padding_columns);
    }
    if (maybe_style) |style| try color.apply(placement.sink, style);
    const content_start = placement.sink.columns_written;
    try placement.sink.textFitted(content, geometry.content_columns);
    const content_columns = placement.sink.columns_written - content_start;
    if (maybe_style != null) try color.apply(placement.sink, .reset);
    try placement.sink.spaces(geometry.content_columns -| content_columns);
    if (geometry.closed) {
        try placement.sink.spaces(geometry.padding_columns);
        try writeBorderCell(placement.sink, sideCell(border, body_index, true));
        try color.apply(placement.sink, .reset);
    }
    if (maybe_caret) |caret|
        if (placement.base + caret.row == line.*) placement.sink.setCaret(caret.column);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// One labelled horizontal border. A label masks the moving segment, and the
/// segment never overwrites it. Narrow labels compact to `↑N` or `↓N` before
/// they hide.
fn ruleRow(
    placement: *const Placement,
    border: *const Border,
    line: *usize,
    rule: Rule,
    arrow: []const u8,
    more: usize,
) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    try color.apply(placement.sink, .rule);
    if (placement.columns < 3) {
        try placement.sink.repeat("─", placement.columns);
    } else {
        const track_columns = placement.columns - 2;
        var buffer: [32]u8 = undefined;
        const maybe_label = moreLabel(&buffer, &.{
            .arrow = arrow,
            .more = more,
            .track_columns = track_columns,
        });
        if (maybe_label) |label| {
            const label_start = 3;
            const label_end = label_start + 1 + terminal.width.ofText(label) + 1;
            try drawRuleRange(placement.sink, border, &.{
                .rule = rule,
                .start = 0,
                .end = label_start,
            });
            try placement.sink.text(" ");
            try placement.sink.text(label);
            try placement.sink.text(" ");
            try drawRuleRange(placement.sink, border, &.{
                .rule = rule,
                .start = label_end,
                .end = placement.columns,
            });
        } else {
            try drawRuleRange(placement.sink, border, &.{
                .rule = rule,
                .start = 0,
                .end = placement.columns,
            });
        }
    }
    try color.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

fn moreLabel(buffer: *[32]u8, options: *const LabelOptions) ?[]const u8 {
    if (options.more == 0) return null;
    const full = std.fmt.bufPrint(buffer, "{s} Hidden: {d}", .{
        options.arrow,
        options.more,
    }) catch return null;
    if (labelFits(options.track_columns, full)) return full;
    const compact = std.fmt.bufPrint(buffer, "{s}{d}", .{
        options.arrow,
        options.more,
    }) catch return null;
    return if (labelFits(options.track_columns, compact)) compact else null;
}

fn labelFits(track_columns: usize, label: []const u8) bool {
    const lead = 2;
    const used = lead + 1 + terminal.width.ofText(label) + 1;
    return track_columns > used;
}

fn drawRuleRange(
    sink: *terminal.View.Sink,
    border: *const Border,
    options: *const RuleRange,
) !void {
    std.debug.assert(options.start <= options.end and options.end <= border.columns);
    var accent = false;
    var column = options.start;
    while (column < options.end) {
        const cell = ruleCell(border, options.rule, column);
        if (cell.accent != accent) {
            accent = cell.accent;
            try color.apply(sink, if (accent) .accent_foreground else .rule);
        }
        var run_end = column + 1;
        while (run_end < options.end) : (run_end += 1) {
            const next = ruleCell(border, options.rule, run_end);
            if (next.accent != cell.accent or next.glyph != cell.glyph) break;
        }
        try writeBorderGlyph(sink, cell.glyph, run_end - column);
        column = run_end;
    }
    if (accent) try color.apply(sink, .rule);
}

fn ruleCell(border: *const Border, rule: Rule, column: usize) BorderCell {
    return switch (rule) {
        .top => if (column == 0)
            borderCell(border, 0, .top_left)
        else if (column + 1 == border.columns)
            borderCell(border, column, .top_right)
        else
            borderCell(border, column, .top),
        .bottom => bottom: {
            const position = border.columns + border.body_rows + border.columns - 1 - column;
            const shape: BorderShape = if (column == 0)
                .bottom_left
            else if (column + 1 == border.columns)
                .bottom_right
            else
                .bottom;
            break :bottom borderCell(border, position, shape);
        },
    };
}

fn sideCell(border: *const Border, body_index: usize, right: bool) BorderCell {
    if (right) return borderCell(border, border.columns + body_index, .right);
    const position = border.perimeter() - 1 - body_index;
    return borderCell(border, position, .left);
}

fn borderCell(border: *const Border, position: usize, shape: BorderShape) BorderCell {
    const active = activityAt(border, position);
    const perimeter = border.perimeter();
    const previous = if (position == 0) perimeter - 1 else position - 1;
    const next = if (position + 1 == perimeter) 0 else position + 1;
    return .{
        .glyph = borderGlyph(shape, .{
            .incoming = active and activityAt(border, previous),
            .outgoing = active and activityAt(border, next),
        }),
        .accent = active,
    };
}

fn activityAt(border: *const Border, position: usize) bool {
    const maybe_activity = border.activity;
    if (maybe_activity) |activity| {
        const geometry: ActivityGeometry = .{
            .columns = border.columns,
            .body_rows = border.body_rows,
        };
        const perimeter = activityPerimeter(&geometry);
        std.debug.assert(perimeter >= 8 and position < perimeter);
        const head = activityHead(activity.motion_tick, &geometry);
        const distance = if (head >= position)
            head - position
        else
            perimeter - (position - head);
        return distance < activityLength(activity.progress_age_ticks, perimeter);
    }
    return false;
}

fn activityPerimeter(geometry: *const ActivityGeometry) usize {
    return 2 * geometry.columns + 2 * geometry.body_rows;
}

/// Horizontal cells consume one tick. Vertical cells and corners consume two to
/// compensate for a terminal cell's greater physical height.
fn activityHead(motion_tick: u64, geometry: *const ActivityGeometry) usize {
    std.debug.assert(geometry.columns >= 3 and geometry.body_rows >= 1);
    const cycle_ticks = activityCycleTicks(geometry);
    const cycle_ticks_u64: u64 = @intCast(cycle_ticks);
    const offset = @divFloor(geometry.columns, 2) + 1;
    const phase_tick: usize = @intCast(motion_tick % cycle_ticks_u64);
    const phase = (phase_tick + offset) % cycle_ticks;
    return activityPosition(phase, geometry);
}

fn activityCycleTicks(geometry: *const ActivityGeometry) usize {
    return 2 * geometry.columns + 4 * geometry.body_rows + 4;
}

fn activityPosition(phase: usize, geometry: *const ActivityGeometry) usize {
    const horizontal_cells = geometry.columns - 2;
    const vertical_ticks = geometry.body_rows * activity_vertical_ticks;
    var remaining = phase;

    if (remaining < activity_vertical_ticks) return 0;
    remaining -= activity_vertical_ticks;
    if (remaining < horizontal_cells) return 1 + remaining;
    remaining -= horizontal_cells;
    if (remaining < activity_vertical_ticks) return geometry.columns - 1;
    remaining -= activity_vertical_ticks;
    if (remaining < vertical_ticks)
        return geometry.columns + @divFloor(remaining, activity_vertical_ticks);
    remaining -= vertical_ticks;
    if (remaining < activity_vertical_ticks) return geometry.columns + geometry.body_rows;
    remaining -= activity_vertical_ticks;
    if (remaining < horizontal_cells)
        return geometry.columns + geometry.body_rows + 1 + remaining;
    remaining -= horizontal_cells;
    if (remaining < activity_vertical_ticks)
        return 2 * geometry.columns + geometry.body_rows - 1;
    remaining -= activity_vertical_ticks;
    std.debug.assert(remaining < vertical_ticks);
    return 2 * geometry.columns + geometry.body_rows +
        @divFloor(remaining, activity_vertical_ticks);
}

fn activityLength(progress_age_ticks: u64, perimeter: usize) usize {
    const length_max = @divFloor(perimeter, 2);
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

fn borderGlyph(shape: BorderShape, weights: PathWeights) BorderGlyph {
    return switch (shape) {
        .top => horizontalGlyph(.{ .left = weights.incoming, .right = weights.outgoing }),
        .right => verticalGlyph(.{ .up = weights.incoming, .down = weights.outgoing }),
        .bottom => horizontalGlyph(.{ .left = weights.outgoing, .right = weights.incoming }),
        .left => verticalGlyph(.{ .up = weights.outgoing, .down = weights.incoming }),
        .top_left => topLeftGlyph(.{ .down = weights.incoming, .right = weights.outgoing }),
        .top_right => topRightGlyph(.{ .down = weights.outgoing, .left = weights.incoming }),
        .bottom_right => bottomRightGlyph(.{ .up = weights.incoming, .left = weights.outgoing }),
        .bottom_left => bottomLeftGlyph(.{ .up = weights.outgoing, .right = weights.incoming }),
    };
}

fn horizontalGlyph(weights: HorizontalWeights) BorderGlyph {
    if (weights.left) return if (weights.right)
        .horizontal_heavy
    else
        .horizontal_left_heavy_right_light;
    return if (weights.right) .horizontal_left_light_right_heavy else .horizontal_light;
}

fn verticalGlyph(weights: VerticalWeights) BorderGlyph {
    if (weights.up) return if (weights.down)
        .vertical_heavy
    else
        .vertical_up_heavy_down_light;
    return if (weights.down) .vertical_up_light_down_heavy else .vertical_light;
}

fn topLeftGlyph(weights: TopLeftWeights) BorderGlyph {
    if (weights.down) return if (weights.right)
        .top_left_heavy
    else
        .top_left_down_heavy_right_light;
    return if (weights.right) .top_left_down_light_right_heavy else .top_left_light;
}

fn topRightGlyph(weights: TopRightWeights) BorderGlyph {
    if (weights.down) return if (weights.left)
        .top_right_heavy
    else
        .top_right_down_heavy_left_light;
    return if (weights.left) .top_right_down_light_left_heavy else .top_right_light;
}

fn bottomRightGlyph(weights: BottomRightWeights) BorderGlyph {
    if (weights.up) return if (weights.left)
        .bottom_right_heavy
    else
        .bottom_right_up_heavy_left_light;
    return if (weights.left) .bottom_right_up_light_left_heavy else .bottom_right_light;
}

fn bottomLeftGlyph(weights: BottomLeftWeights) BorderGlyph {
    if (weights.up) return if (weights.right)
        .bottom_left_heavy
    else
        .bottom_left_up_heavy_right_light;
    return if (weights.right) .bottom_left_up_light_right_heavy else .bottom_left_light;
}

fn writeBorderCell(sink: *terminal.View.Sink, cell: BorderCell) !void {
    try color.apply(sink, if (cell.accent) .accent_foreground else .rule);
    try writeBorderGlyph(sink, cell.glyph, 1);
}

fn writeBorderGlyph(sink: *terminal.View.Sink, glyph: BorderGlyph, count: usize) !void {
    switch (glyph) {
        .horizontal_light => try sink.repeat("─", count),
        .horizontal_heavy => try sink.repeat("━", count),
        .horizontal_left_light_right_heavy => try sink.repeat("╼", count),
        .horizontal_left_heavy_right_light => try sink.repeat("╾", count),
        .vertical_light => try sink.repeat("│", count),
        .vertical_heavy => try sink.repeat("┃", count),
        .vertical_up_light_down_heavy => try sink.repeat("╽", count),
        .vertical_up_heavy_down_light => try sink.repeat("╿", count),
        .top_left_light => try sink.repeat("┌", count),
        .top_left_heavy => try sink.repeat("┏", count),
        .top_left_down_light_right_heavy => try sink.repeat("┍", count),
        .top_left_down_heavy_right_light => try sink.repeat("┎", count),
        .top_right_light => try sink.repeat("┐", count),
        .top_right_heavy => try sink.repeat("┓", count),
        .top_right_down_light_left_heavy => try sink.repeat("┑", count),
        .top_right_down_heavy_left_light => try sink.repeat("┒", count),
        .bottom_right_light => try sink.repeat("┘", count),
        .bottom_right_heavy => try sink.repeat("┛", count),
        .bottom_right_up_light_left_heavy => try sink.repeat("┙", count),
        .bottom_right_up_heavy_left_light => try sink.repeat("┚", count),
        .bottom_left_light => try sink.repeat("└", count),
        .bottom_left_heavy => try sink.repeat("┗", count),
        .bottom_left_up_light_right_heavy => try sink.repeat("┕", count),
        .bottom_left_up_heavy_right_light => try sink.repeat("┖", count),
    }
}

/// Physical rows the steering queue occupies: one row per queued message plus a
/// hint row. Zero when the queue is empty, so it contributes no component.
pub fn steeringRows(messages: []const []const u8) usize {
    if (messages.len == 0) return 0;
    return messages.len + 1;
}

/// The steering queue: a `Queued message: <message>` row per queued message
/// (each cut to its first line and the window width), then a dim hint row.
pub fn steering(placement: *const Placement, messages: []const []const u8) !void {
    var line = placement.base;
    for (messages) |message| {
        defer line += 1;
        if (line < placement.skip) continue;
        // Truncate the label first, then give the message whatever width is left.
        // A window narrower than the label can then never overflow the row.
        const label = terminal.width.truncate("Queued message: ", placement.columns);
        const first = message[0 .. std.mem.indexOfScalar(u8, message, '\n') orelse message.len];
        const room = placement.columns -| terminal.width.ofText(label);
        const shown = terminal.width.truncate(first, room);
        placement.sink.begin();
        try color.apply(placement.sink, .accent_foreground);
        try placement.sink.text(label);
        try color.apply(placement.sink, .reset);
        try color.apply(placement.sink, .muted_foreground);
        try placement.sink.text(shown);
        try color.apply(placement.sink, .reset);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
    var hint_placement = placement.*;
    hint_placement.base = line;
    const hint = "\u{21B3} Ctrl+P: Edit all queued messages";
    try notice(&hint_placement, &.{ .style = .dim, .prefix = "" }, hint);
}

test "frame geometry preserves content before decoration in narrow windows" {
    try std.testing.expectEqual(FrameGeometry{
        .content_columns = 1,
        .content_offset = 0,
        .padding_columns = 0,
        .closed = false,
    }, frameGeometry(0));
    try std.testing.expectEqual(FrameGeometry{
        .content_columns = 2,
        .content_offset = 0,
        .padding_columns = 0,
        .closed = false,
    }, frameGeometry(2));
    try std.testing.expectEqual(FrameGeometry{
        .content_columns = 1,
        .content_offset = 1,
        .padding_columns = 0,
        .closed = true,
    }, frameGeometry(3));
    try std.testing.expectEqual(FrameGeometry{
        .content_columns = 1,
        .content_offset = 2,
        .padding_columns = 1,
        .closed = true,
    }, frameGeometry(5));
}

test "activity segment blends into straight rails and corners" {
    const idle: Border = .{ .columns = 20, .body_rows = 3, .activity = null };
    try std.testing.expectEqual(.top_left_light, borderCell(&idle, 0, .top_left).glyph);
    try std.testing.expectEqual(.horizontal_light, borderCell(&idle, 1, .top).glyph);

    // Tick 9 reaches the top-right corner. Entry into the side makes the corner
    // fully heavy and tapers the head into the right rail.
    const corner_head: Border = .{
        .columns = 20,
        .body_rows = 3,
        .activity = .{ .motion_tick = 9, .progress_age_ticks = 0 },
    };
    const corner = borderCell(&corner_head, 19, .top_right);
    try std.testing.expect(corner.accent);
    try std.testing.expectEqual(.top_right_down_light_left_heavy, corner.glyph);

    const side_head: Border = .{
        .columns = 20,
        .body_rows = 3,
        .activity = .{ .motion_tick = 11, .progress_age_ticks = 0 },
    };
    try std.testing.expectEqual(.top_right_heavy, borderCell(&side_head, 19, .top_right).glyph);
    try std.testing.expectEqual(
        .vertical_up_heavy_down_light,
        borderCell(&side_head, 20, .right).glyph,
    );
}

test "activity timing compensates for taller vertical cells" {
    const geometry: ActivityGeometry = .{ .columns = 20, .body_rows = 3 };
    try std.testing.expectEqual(@as(usize, 10), activityHead(0, &geometry));
    try std.testing.expectEqual(@as(usize, 11), activityHead(1, &geometry));
    try std.testing.expectEqual(@as(usize, 19), activityHead(9, &geometry));
    try std.testing.expectEqual(@as(usize, 19), activityHead(10, &geometry));
    try std.testing.expectEqual(@as(usize, 20), activityHead(11, &geometry));
    try std.testing.expectEqual(@as(usize, 20), activityHead(12, &geometry));
    try std.testing.expect(activityChanged(
        &.{ .motion_tick = 9, .progress_age_ticks = 0 },
        &geometry,
    ));
    try std.testing.expect(!activityChanged(
        &.{ .motion_tick = 10, .progress_age_ticks = 0 },
        &geometry,
    ));
    try std.testing.expect(activityChanged(
        &.{ .motion_tick = 66, .progress_age_ticks = 31 },
        &geometry,
    ));
    // Tick 346 is the same vertical dwell after the segment has reached its cap.
    try std.testing.expect(!activityChanged(
        &.{ .motion_tick = 346, .progress_age_ticks = 290 },
        &geometry,
    ));
    try std.testing.expect(activityChanged(
        &.{ .motion_tick = 11, .progress_age_ticks = 0 },
        &geometry,
    ));
    try std.testing.expect(!activityChanged(
        &.{ .motion_tick = 12, .progress_age_ticks = 0 },
        &geometry,
    ));
}

test "aspect-aware timing covers the complete perimeter" {
    const geometry: ActivityGeometry = .{ .columns = 5, .body_rows = 2 };
    const expected = [_]usize{
        0, 0, 1, 2, 3,  4,  4,  5,  5,  6,  6,
        7, 7, 8, 9, 10, 11, 11, 12, 12, 13, 13,
    };
    try std.testing.expectEqual(expected.len, activityCycleTicks(&geometry));
    for (expected, 0..) |position, phase|
        try std.testing.expectEqual(position, activityPosition(phase, &geometry));
}

test "activity segment grows after a quiet grace period up to half the perimeter" {
    try std.testing.expectEqual(@as(usize, 6), activityLength(0, 100));
    try std.testing.expectEqual(@as(usize, 6), activityLength(30, 100));
    try std.testing.expectEqual(@as(usize, 7), activityLength(31, 100));
    try std.testing.expectEqual(@as(usize, 7), activityLength(36, 100));
    try std.testing.expectEqual(@as(usize, 8), activityLength(37, 100));
    try std.testing.expectEqual(@as(usize, 11), activityLength(55, 100));
    try std.testing.expectEqual(@as(usize, 49), activityLength(288, 100));
    try std.testing.expectEqual(@as(usize, 50), activityLength(289, 100));
    try std.testing.expectEqual(@as(usize, 50), activityLength(290, 100));
    try std.testing.expectEqual(@as(usize, 4), activityLength(0, 8));
}

test "overflow labels compact before disappearing" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("↑ Hidden: 17", moreLabel(&buffer, &.{
        .arrow = "↑",
        .more = 17,
        .track_columns = 17,
    }).?);
    try std.testing.expectEqualStrings("↑17", moreLabel(&buffer, &.{
        .arrow = "↑",
        .more = 17,
        .track_columns = 8,
    }).?);
    try std.testing.expect(moreLabel(&buffer, &.{
        .arrow = "↑",
        .more = 17,
        .track_columns = 7,
    }) == null);
}

test "a wide notice prefix fits in a one-column row" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var view = terminal.View.init(std.testing.allocator, &output.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 1, .rows = 1 }, 1);
    const placement: Placement =
        .{ .sink = sink, .id = 0, .columns = 1, .base = 0, .skip = 0 };
    try notice(&placement, &.{ .style = .dim, .prefix = "你" }, "hidden");
    try std.testing.expectEqual(@as(usize, 1), sink.columns_written);
    try view.render();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "hidden") == null);
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
