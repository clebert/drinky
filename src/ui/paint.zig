//! Row painters: the primitives that stream one styled row at a time straight
//! into the view's `Sink` through a `Placement`. They drop the clip's hidden top
//! rows, so a clipped component never materializes its whole body. The
//! transcript `block`s and the chrome (the tool box, the input area, and the
//! status line) share them. Each painter names a `role.Name`, and that role
//! decides the color, so no painter holds a color value of its own.

const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const role = @import("role.zig");

const activity_length_default: usize = 6;
// At 16 ms per frame, wait about 500 ms. Then add one cell every 100 ms.
const activity_growth_delay_ticks: u64 = 31;
const activity_growth_interval_ticks: u64 = 6;

/// A notice's look: the role that colors every line and a prefix (an error tag,
/// or empty) that prints before each line's text.
const Notice = struct { role: role.Name, prefix: []const u8 };

/// Where a component composes its rows: the sink to write into, the anchor `id`
/// its rows carry, the terminal width, the line its content starts at (`base`,
/// after any leading separator), and how many of its top rows to drop (`skip`,
/// nonzero only for the clip). A renderer that derives a placement copies its
/// parent and changes the geometry alone.
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

pub const Activity = struct {
    motion_tick: u64,
    progress_age_ticks: u64,
};

/// Whether `activity` moves the separator segment at this width.
pub fn activityChanged(activity: *const Activity, columns: usize) bool {
    if (columns == 0) return false;
    return activityHead(activity.motion_tick, columns) !=
        activityHead(activity.motion_tick -% 1, columns);
}

/// The complete row width available to content between the open separators.
pub fn frameColumns(columns: usize) usize {
    return @max(columns, 1);
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
        try role.apply(placement.sink, look.role);
        try placement.sink.text(shown_prefix);
        try placement.sink.text(clipped);
        try attribute.apply(placement.sink, .reset);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
}

/// A filled box in one role: a blank padding row, `text` wrapped to the inner
/// width with a one-space left pad and the fill carried to full width, then a
/// blank padding row. A box role reverses the video, so the fill takes the
/// color of the role and the text keeps the terminal background. It streams one
/// row at a time and separates itself inside the block gap around it.
pub fn box(placement: *const Placement, name: role.Name, text: []const u8) !void {
    var line = placement.base;
    try boxPad(placement, &line, name);
    var iterator = terminal.width.wrapper(text, boxInner(placement.columns));
    while (iterator.next()) |content| try boxLine(placement, &line, name, content);
    try boxPad(placement, &line, name);
}

/// A box's blank padding row: the fill carried to full width.
fn boxPad(placement: *const Placement, line: *usize, name: role.Name) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    try role.apply(placement.sink, name);
    try placement.sink.spaces(placement.columns);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// A box's content row: a one-space left pad, `content`, then the fill carried
/// to full width. A cap on `content` leaves room for the pad, so a window too
/// narrow for the wrap width still yields one physical row.
fn boxLine(
    placement: *const Placement,
    line: *usize,
    name: role.Name,
    content: []const u8,
) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    try role.apply(placement.sink, name);
    try boxLineCells(placement.sink, placement.columns, content);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// The cells of the first box content row, without the row bookkeeping. The
/// text wraps at the live box width. The caller opens the row, applies the box
/// color, and closes the style. The color preview page uses this fixed row.
pub fn boxCells(sink: *terminal.View.Sink, columns: usize, text: []const u8) !void {
    var iterator = terminal.width.wrapper(text, boxInner(columns));
    try boxLineCells(sink, columns, iterator.next().?);
}

fn boxLineCells(sink: *terminal.View.Sink, columns: usize, content: []const u8) !void {
    const shown = terminal.width.truncate(content, columns -| 1);
    try sink.text(" ");
    try sink.text(shown);
    try sink.spaces(columns -| (1 + terminal.width.ofText(shown)));
}

const frame_separator_rows = 2;

/// The physical rows an input area occupies: two separators plus `body_rows`.
pub fn framedRows(body_rows: usize) usize {
    return frame_separator_rows + body_rows;
}

/// The tallest a framed body can grow before it scrolls within its frame: about
/// a quarter of the viewport, never fewer than five rows nor more than fifteen.
/// The live input stays usable and does not crowd out the transcript. The
/// editor and the picker share it, so both window to the same limit.
pub fn bodyLimit(viewport_rows: usize) usize {
    return @min(@max(@divFloor(viewport_rows, 4) + 1, 5), 15);
}

/// An input area between two open separators. While `activity` is set, one
/// heavy segment moves across both separators as a loop. It grows when progress
/// is quiet.
pub const Framing = struct {
    body: []const u8,
    body_rows: usize,
    /// When set, places the terminal caret on the body row it names
    /// (component-local row 0 is the top separator). The row counts relative to
    /// the window.
    caret: ?terminal.View.Caret = null,
    /// Body rows dropped above the window, and the top separator's "N more" count.
    hidden_above: usize = 0,
    /// Body rows dropped below the window, and the bottom separator's "N more" count.
    hidden_below: usize = 0,
    /// An extra empty body row after the wrapped body: the row a caret at a
    /// full-width final line wraps onto, which the wrap itself never yields. It
    /// is the last body row, so it shows only when the window reaches it.
    trailing_row: bool = false,
    /// The role per logical `\n`-delimited body line (lines past the end are
    /// plain). Wrapped continuations retain their source line's role.
    line_roles: []const ?role.Name = &.{},
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

/// Optional activity and hidden-row label for a top separator.
pub const SeparatorOptions = struct {
    activity: ?Activity = null,
    hidden_above: usize = 0,
};

/// Stream the input area that `framing` describes. It contains a labelled top
/// separator, its open body rows, and a labelled bottom separator.
pub fn framed(placement: *const Placement, framing: *const Framing) !void {
    const content_columns = frameColumns(placement.columns);
    const separators: Separators = .{
        .columns = placement.columns,
        .activity = framing.activity,
    };
    var line = placement.base;
    try ruleRow(placement, &separators, &line, .top, "↑", framing.hidden_above);
    var iterator = terminal.width.wrapper(framing.body, content_columns);
    const window_end = framing.hidden_above +| framing.body_rows;
    var source_offset: usize = 0;
    var source_line: usize = 0;
    var body_count: usize = 0;
    var index: usize = 0;
    while (iterator.next()) |content| : (index += 1) {
        const content_offset = @intFromPtr(content.ptr) - @intFromPtr(framing.body.ptr);
        source_line += std.mem.count(u8, framing.body[source_offset..content_offset], "\n");
        source_offset = content_offset;
        if (index < framing.hidden_above) continue;
        if (index >= window_end) break;
        const roles = framing.line_roles;
        const maybe_role = if (source_line < roles.len) roles[source_line] else null;
        try framedRow(placement, framing.caret, &line, content, maybe_role);
        body_count += 1;
    }
    // The wrapper exhausts at `index == wrapped rows`, the trailing row's index.
    // Emit it when the window reaches it (a `break` above leaves it out of view).
    if (framing.trailing_row and index >= framing.hidden_above and index < window_end) {
        try framedRow(placement, framing.caret, &line, "", null);
        body_count += 1;
    }
    std.debug.assert(body_count == framing.body_rows);
    try ruleRow(placement, &separators, &line, .bottom, "↓", framing.hidden_below);
}

/// One open body row. It adds no side glyphs or padding, so a terminal copy
/// contains only the body text. The function drops rows in the clipped top.
fn framedRow(
    placement: *const Placement,
    maybe_caret: ?terminal.View.Caret,
    line: *usize,
    content: []const u8,
    maybe_role: ?role.Name,
) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    if (maybe_role) |name| try role.apply(placement.sink, name);
    try placement.sink.text(content);
    if (maybe_role != null) try attribute.apply(placement.sink, .reset);
    if (maybe_caret) |caret|
        if (placement.base + caret.row == line.*) placement.sink.setCaret(caret.column);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// One labelled horizontal separator. A label masks the moving segment, and the
/// segment never overwrites it. The label is secondary text, so it takes the
/// muted role while the glyphs around it keep the frame color. Narrow labels
/// compact to `↑N` or `↓N` before they hide.
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
        // Clear faint before the range applies its first frame or activity role.
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

/// One complete top input separator across `columns`. The options can add its
/// hidden-row label and the moving activity segment. The caller opens the row
/// and closes the style. The color preview page samples the live painter.
pub fn separatorCells(
    sink: *terminal.View.Sink,
    columns: usize,
    options: *const SeparatorOptions,
) !void {
    const separators: Separators = .{ .columns = columns, .activity = options.activity };
    try ruleCells(sink, &separators, .top, "↑", options.hidden_above);
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

/// Treat the top separator and then the bottom separator as one virtual line.
/// The segment moves right and crosses between opposite separator ends.
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

/// Place the initial segment at the start of the top separator. Move its head
/// one virtual cell per tick.
fn activityHead(motion_tick: u64, columns: usize) usize {
    std.debug.assert(columns > 0);
    const track_columns = 2 * columns;
    const track_columns_u64: u64 = @intCast(track_columns);
    const phase: usize = @intCast(motion_tick % track_columns_u64);
    const offset = @min(activity_length_default, columns) - 1;
    const wrap_at = track_columns - offset;
    return if (phase >= wrap_at) phase - wrap_at else phase + offset;
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

/// Physical rows the steering queue occupies: one row per queued message plus a
/// hint row. Zero when the queue is empty, so it contributes no component.
pub fn steeringRows(messages: []const []const u8) usize {
    if (messages.len == 0) return 0;
    return messages.len + 1;
}

/// The steering queue: a `Queued message: <message>` row per queued message
/// (each cut to its first line and the window width), then a faint hint row.
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
        try role.apply(placement.sink, .accent);
        try placement.sink.text(label);
        try attribute.apply(placement.sink, .reset);
        try role.apply(placement.sink, .muted);
        try placement.sink.text(shown);
        try attribute.apply(placement.sink, .reset);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
    var hint_placement = placement.*;
    hint_placement.base = line;
    const hint = "\u{21B3} Ctrl+P: Edit all queued messages";
    try notice(&hint_placement, &.{ .role = .muted, .prefix = "" }, hint);
}

test "box preview cells use the live wrap width" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 10, .rows = 1 }, 1);
    sink.begin();
    try boxCells(sink, 10, "abcdefghijk");
    try std.testing.expectEqual(@as(usize, 10), sink.columns_written);
    sink.end(.{ .id = 0, .line = 0 });
    try view.render();

    try std.testing.expect(std.mem.indexOf(u8, output.written(), " abcdefgh ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "abcdefghi") == null);
}

test "open separators leave the complete row available to content" {
    try std.testing.expectEqual(@as(usize, 1), frameColumns(0));
    try std.testing.expectEqual(@as(usize, 1), frameColumns(1));
    try std.testing.expectEqual(@as(usize, 2), frameColumns(2));
    try std.testing.expectEqual(@as(usize, 80), frameColumns(80));
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

    // The count is secondary text. The reset clears its faint intensity before
    // the frame color starts again behind it.
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
        &.{ .motion_tick = 1, .progress_age_ticks = 0 },
        5,
    ));
    try std.testing.expect(activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 31 },
        1,
    ));
    try std.testing.expect(!activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 31 },
        0,
    ));
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

test "a wide notice prefix fits in a one-column row" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var view = terminal.View.init(std.testing.allocator, &output.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 1, .rows = 1 }, 1);
    const placement: Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 1,
        .base = 0,
        .skip = 0,
    };
    try notice(&placement, &.{ .role = .muted, .prefix = "你" }, "hidden");
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
