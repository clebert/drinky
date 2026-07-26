//! Row painters: the primitives that stream one styled row at a time straight
//! into the view's `Sink` through a `Placement`, dropping the clip's hidden top
//! rows so a clipped component never materializes its whole body. Shared by the
//! transcript `block`s and the chrome (the tool box, the spinner, the status
//! line) alike.

const std = @import("std");

const terminal = @import("terminal");

const color = @import("color.zig");

/// Braille frames for the "Working…" spinner, advanced one step per frame tick.
const spinner_frames =
    [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Display width of the full `⠋ Working…` spinner: glyph, space, and message.
const spinner_columns = 10;

/// One cell of the purple rule that frames the input area, repeated to full width.
const rule_cell = "─";

pub const BoxStyle = struct { background: color.Style, foreground: color.Style };

/// A notice's look: the SGR style opening every line and a prefix (an error tag,
/// or empty) printed before each line's text.
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

/// The next spinner frame after `frame`, wrapping within the frame set.
pub fn spinnerStep(frame: usize) usize {
    return (frame + 1) % spinner_frames.len;
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
        // Saturating: a cluster wider than the whole budget survives `truncate` as
        // a one-column replacement but measures its true width here, so a prefix
        // opening on one can report more columns than the row has.
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
/// a blank padding row. Streamed a row at a time, self-separating inside the
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
/// filled to full width. `content` is capped to leave room for the pad, so a
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

/// The physical rows a framed area occupies: its two rules plus `body_rows`.
pub fn framedRows(body_rows: usize) usize {
    return 2 + body_rows;
}

/// The tallest a framed body may grow before it scrolls within its frame: about
/// a quarter of the viewport, never fewer than five rows nor more than fifteen,
/// so the live input stays usable without crowding out the transcript. Shared by
/// the editor and the picker so both window to the same limit.
pub fn bodyLimit(viewport_rows: usize) usize {
    return @min(@max(@divFloor(viewport_rows, 4) + 1, 5), 15);
}

/// A framed input area — a full-width rule, a window of `body`'s wrapped rows,
/// then a closing rule — streamed a row at a time. Shared by the editor and the
/// picker so both sit in one border.
pub const Framing = struct {
    body: []const u8,
    /// When set, places the terminal caret on the body row it names
    /// (component-local row 0 is the top rule), reported relative to the window.
    caret: ?terminal.View.Caret = null,
    /// Body rows dropped above the window; also the top rule's "N more" count.
    hidden_above: usize = 0,
    /// Body rows to show from `hidden_above` on; null shows all that remain.
    shown: ?usize = null,
    /// Body rows dropped below the window; also the bottom rule's "N more" count.
    hidden_below: usize = 0,
    /// An extra empty body row after the wrapped body — the row a caret sitting at
    /// a full-width final line wraps onto, which the wrap itself never yields. It
    /// is the last body row, so it shows only when the window reaches it.
    trailing_row: bool = false,
    /// Style per logical `\n`-delimited body line (lines past the end are plain).
    /// Wrapped continuations retain their source line's style.
    line_styles: []const ?color.Style = &.{},
};

/// Stream the framed area described by `framing`: the top rule (labelled with the
/// rows hidden above), the windowed body rows, then the bottom rule (labelled
/// with the rows hidden below). A body no taller than its slot leaves both counts
/// zero, so the rules stay plain and the whole body shows.
pub fn framed(placement: *const Placement, framing: *const Framing) !void {
    var line = placement.base;
    try ruleRow(placement, &line, "↑", framing.hidden_above);
    var iterator = terminal.width.wrapper(framing.body, @max(placement.columns, 1));
    const window_end = framing.hidden_above +| (framing.shown orelse std.math.maxInt(usize));
    var source_offset: usize = 0;
    var source_line: usize = 0;
    var index: usize = 0;
    while (iterator.next()) |content| : (index += 1) {
        const content_offset = @intFromPtr(content.ptr) - @intFromPtr(framing.body.ptr);
        source_line += std.mem.count(u8, framing.body[source_offset..content_offset], "\n");
        source_offset = content_offset;
        if (index < framing.hidden_above) continue;
        if (index >= window_end) break;
        const styles = framing.line_styles;
        const maybe_style = if (source_line < styles.len) styles[source_line] else null;
        try framedRow(placement, framing.caret, &line, content, maybe_style);
    }
    // The wrapper exhausts at `index == wrapped rows`, the trailing row's index;
    // emit it when the window reaches it (a `break` above leaves it out of view).
    if (framing.trailing_row and index >= framing.hidden_above and index < window_end) {
        try framedRow(placement, framing.caret, &line, "", null);
    }
    try ruleRow(placement, &line, "↓", framing.hidden_below);
}

/// One wrapped body row: the styled `content`, then the caret when it names this
/// row. Advances `line` and drops the row in the clipped top.
fn framedRow(
    placement: *const Placement,
    maybe_caret: ?terminal.View.Caret,
    line: *usize,
    content: []const u8,
    maybe_style: ?color.Style,
) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    if (maybe_style) |style| try color.apply(placement.sink, style);
    try placement.sink.text(content);
    if (maybe_style != null) try color.apply(placement.sink, .reset);
    if (maybe_caret) |caret|
        if (placement.base + caret.row == line.*) placement.sink.setCaret(caret.column);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// One rule row of a framed area: a full-width purple rule, or — when `more` rows
/// are hidden past it — that rule with an `arrow N more` label set into it.
/// Advances `line` and drops the row when it falls in the clipped top.
fn ruleRow(placement: *const Placement, line: *usize, arrow: []const u8, more: usize) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    var buffer: [32]u8 = undefined;
    const maybe_label: ?[]const u8 = if (more > 0)
        (std.fmt.bufPrint(&buffer, "{s} {d} more", .{ arrow, more }) catch null)
    else
        null;
    placement.sink.begin();
    try color.apply(placement.sink, .rule);
    try ruleCells(placement.sink, placement.columns, maybe_label);
    try color.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// Fill a rule row with `columns` rule cells, or — when `maybe_label` is set and
/// fits after a short lead with a trailing cell to spare — a lead, the spaced
/// label, then cells filling the rest.
fn ruleCells(sink: *terminal.View.Sink, columns: usize, maybe_label: ?[]const u8) !void {
    const lead = 3;
    if (maybe_label) |label| {
        const used = lead + 1 + terminal.width.ofText(label) + 1;
        if (columns > used) {
            try sink.repeat(rule_cell, lead);
            try sink.text(" ");
            try sink.text(label);
            try sink.text(" ");
            try sink.repeat(rule_cell, columns - used);
            return;
        }
    }
    try sink.repeat(rule_cell, columns);
}

/// The `⠋ Working…` spinner at `frame`: accent glyph, muted message. One content
/// row; on a window too narrow for the whole message it shows just the glyph.
pub fn spinner(placement: *const Placement, frame: usize) !void {
    if (placement.base < placement.skip) return;
    const glyph = spinner_frames[frame % spinner_frames.len];
    placement.sink.begin();
    try color.apply(placement.sink, .accent_foreground);
    if (placement.columns >= spinner_columns) {
        try placement.sink.text(glyph);
        try color.apply(placement.sink, .reset);
        try placement.sink.text(" ");
        try color.apply(placement.sink, .muted_foreground);
        try placement.sink.text("Working…");
    } else {
        try placement.sink.text(terminal.width.truncate(glyph, placement.columns));
    }
    try color.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

/// Physical rows the steering queue occupies: one row per queued message plus a
/// hint row. Zero when the queue is empty, so it contributes no component.
pub fn steeringRows(messages: []const []const u8) usize {
    if (messages.len == 0) return 0;
    return messages.len + 1;
}

/// The steering queue: a `Steering: <message>` row per queued message (each cut
/// to its first line and the window width), then a dim hint row.
pub fn steering(placement: *const Placement, messages: []const []const u8) !void {
    var line = placement.base;
    for (messages) |message| {
        defer line += 1;
        if (line < placement.skip) continue;
        // Truncate the label first, then give the message whatever width is left,
        // so a window narrower than the label can never overflow the row.
        const label = terminal.width.truncate("Steering: ", placement.columns);
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
    const hint = "\u{21B3} Alt+Up to edit all queued messages";
    try notice(&hint_placement, &.{ .style = .dim, .prefix = "" }, hint);
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
