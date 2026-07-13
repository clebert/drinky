//! Row painters: the primitives that stream one styled row at a time straight
//! into the view's `Sink` through a `Placement`, dropping the clip's hidden top
//! rows so a clipped component never materializes its whole body. Shared by the
//! transcript `block`s and the chrome (the tool box, the spinner, the status
//! line) alike.

const std = @import("std");

const terminal = @import("terminal");

const color = @import("color.zig");

/// Braille frames for the "Working…" spinner, advanced one step per stream event.
const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Display width of the full `⠋ Working…` spinner: glyph, space, and message.
const spinner_columns = 10;

/// One cell of the purple rule that frames the input area, repeated to full width.
const rule_cell = "─";

pub const BoxStyle = struct { background: []const u8, foreground: []const u8 };

/// A notice's look: the SGR style opening every line and a prefix (an error tag,
/// or empty) printed before each line's text.
const Notice = struct { style: []const u8, prefix: []const u8 };

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
        const available = placement.columns - terminal.width.ofText(shown_prefix);
        const clipped = terminal.width.truncate(piece, available);
        const writer = placement.sink.begin();
        try writer.writeAll(look.style);
        try writer.writeAll(shown_prefix);
        try writer.writeAll(clipped);
        try writer.writeAll(color.reset);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
}

/// `text` wrapped to the terminal width as plain rows (the model reply),
/// streamed a row at a time so the clip never materializes its whole body. Each
/// row borrows `text`, so nothing is copied but the emitted bytes.
pub fn wrapped(placement: *const Placement, text: []const u8) !void {
    var iterator = terminal.width.wrapper(text, @max(placement.columns, 1));
    var index: usize = 0;
    while (iterator.next()) |content| : (index += 1) {
        const line = placement.base + index;
        if (line < placement.skip) continue;
        const writer = placement.sink.begin();
        try writer.writeAll(content);
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
fn boxPad(placement: *const Placement, line: *usize, background: []const u8) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    const writer = placement.sink.begin();
    try writer.writeAll(background);
    try writer.splatByteAll(' ', placement.columns);
    try writer.writeAll(color.reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// A box's content row: a one-space left pad, `content`, then the background
/// filled to full width. `content` is capped to leave room for the pad, so a
/// window too narrow for the wrap width still yields one physical row.
fn boxLine(placement: *const Placement, line: *usize, style: *const BoxStyle, content: []const u8) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    const shown = terminal.width.truncate(content, placement.columns -| 1);
    const writer = placement.sink.begin();
    try writer.writeAll(style.background);
    try writer.writeAll(style.foreground);
    try writer.writeByte(' ');
    try writer.writeAll(shown);
    try writer.splatByteAll(' ', placement.columns -| (1 + terminal.width.ofText(shown)));
    try writer.writeAll(color.reset);
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
    var index: usize = 0;
    while (iterator.next()) |content| : (index += 1) {
        if (index < framing.hidden_above) continue;
        if (index >= window_end) break;
        defer line += 1;
        if (line < placement.skip) continue;
        const writer = placement.sink.begin();
        try writer.writeAll(content);
        if (framing.caret) |caret| if (placement.base + caret.row == line) placement.sink.setCaret(caret.column);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
    try ruleRow(placement, &line, "↓", framing.hidden_below);
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
    const writer = placement.sink.begin();
    try writer.writeAll(color.rule);
    try ruleCells(writer, placement.columns, maybe_label);
    try writer.writeAll(color.rule_reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// Fill a rule row with `columns` rule cells, or — when `maybe_label` is set and
/// fits after a short lead with a trailing cell to spare — a lead, the spaced
/// label, then cells filling the rest.
fn ruleCells(writer: *std.Io.Writer, columns: usize, maybe_label: ?[]const u8) !void {
    const lead = 3;
    if (maybe_label) |label| {
        const used = lead + 1 + terminal.width.ofText(label) + 1;
        if (columns > used) {
            for (0..lead) |_| try writer.writeAll(rule_cell);
            try writer.writeByte(' ');
            try writer.writeAll(label);
            try writer.writeByte(' ');
            for (0..columns - used) |_| try writer.writeAll(rule_cell);
            return;
        }
    }
    for (0..columns) |_| try writer.writeAll(rule_cell);
}

/// The `⠋ Working…` spinner at `frame`: accent glyph, muted message. One content
/// row; on a window too narrow for the whole message it shows just the glyph.
pub fn spinner(placement: *const Placement, frame: usize) !void {
    if (placement.base < placement.skip) return;
    const glyph = spinner_frames[frame % spinner_frames.len];
    const writer = placement.sink.begin();
    try writer.writeAll(color.accent_fg);
    if (placement.columns >= spinner_columns) {
        try writer.writeAll(glyph);
        try writer.writeAll(color.reset);
        try writer.writeAll(" ");
        try writer.writeAll(color.muted_fg);
        try writer.writeAll("Working…");
    } else {
        try writer.writeAll(terminal.width.truncate(glyph, placement.columns));
    }
    try writer.writeAll(color.reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
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
