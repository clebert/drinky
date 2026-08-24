//! Row painters: the primitives that stream one styled row at a time straight
//! into the view's `Sink` through a `Placement`. They drop the clip's hidden top
//! rows, so a clipped component never materializes its whole body. The
//! transcript `block`s and the chrome (the tool box, the input area, and the
//! status line) share them. Each painter names a `role.Name`, and that role
//! decides the color, so no painter holds a color value of its own.
//!
//! One wrap rule serves every notice: a row breaks at a separator first. A hint
//! that is still too wide keeps one row and marks its cut, so no hint splits. A
//! line that holds no separator is a sentence, and it breaks between its words.
//! Each painter states its rows through a count of its own, so a measure and a
//! paint cannot diverge.

const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const role = @import("role.zig");

const activity_length_default: usize = 6;
// At 16 ms per frame, wait about 500 ms. Then add one cell every 100 ms.
const activity_growth_delay_ticks: u64 = 31;
const activity_growth_interval_ticks: u64 = 6;
// At 16 ms per frame, show the caret about 600 ms and hide it about 600 ms.
const caret_blink_ticks: u64 = 37;

/// How a notice paints: the role that colors every row, the tag that opens it,
/// how a line wider than one row fits, and the rows the notice can take.
pub const Notice = struct {
    role: role.Name,
    /// An error tag, or empty. It stands on the first row of the notice alone.
    /// Two tags read as two errors, and an indent puts blanks into a copied row.
    prefix: []const u8 = "",
    fit: Fit = .wrap,
    /// The rows the notice can paint. A page header takes the height of its
    /// window, so a wrapped header can never outgrow the page.
    rows_max: usize = std.math.maxInt(usize),
};

/// The separator between two parts of a legend: a blank, a middle dot, and a
/// blank. A notice row breaks here first, and the break drops all three, so no
/// row starts or ends with a separator.
pub const separator = " \u{00B7} ";

/// One row of one logical line: where the content of the row ends, whether that
/// row cut a hint, and where the next row starts. A `next` at the end of the line
/// closes that line.
const Row = struct { end: usize, next: usize, marked: bool = false };

/// A notice as physical rows. Each row breaks at a separator first, so a legend
/// keeps every hint whole. A hint too wide for a row of its own keeps that row
/// and states its cut, so no hint ever splits over two rows. A line that holds no
/// separator is a sentence: it wraps between its words and keeps its tail. The
/// prefix takes room on the first row alone, and every later row starts at the
/// first column.
const Wrap = struct {
    rest: []const u8,
    columns: usize,
    /// The columns the prefix takes. The first row gives them up, and `next`
    /// then clears it.
    lead: usize,
    /// Whether the open logical line holds a separator. The whole line decides
    /// it, so the last hint of a legend cuts like every hint in front of it.
    legend: bool = false,
    /// Whether `rest` still starts at the head of a logical line, which is where
    /// `legend` reads that line.
    fresh: bool = true,
    done: bool = false,

    /// The cells of the next row and the mark of its cut, or null once the notice
    /// is complete. An empty notice yields one empty row, as an empty line does.
    fn next(self: *Wrap) ?Cut {
        if (self.done) return null;
        const lead = self.lead;
        self.lead = 0;
        // A prefix that fills the row leaves no cell for content. The row then
        // holds the prefix alone, and the text opens on the row under it. A row
        // that takes a cluster there loses it to the clip of the sink.
        if (lead > 0 and lead >= self.columns and self.rest.len > 0) {
            const break_at = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
            // The prefix row stands for the first line, so an empty first line
            // takes no row of its own behind it.
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

/// The row that `line` opens with at `room` columns. The row takes as many
/// separated pieces as it holds. A piece too wide for a row of its own cuts on a
/// `legend` line, and breaks between its words on a line that holds one sentence.
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
        // The break drops the separator in front of the piece, so the next row
        // opens on the piece itself, where the branches below cut or wrap it.
        if (index > 0) return .{ .end = end, .next = index };
        const behind = @min(piece_end + separator.len, line.len);
        if (legend) {
            // One hint keeps one row, and the mark states what the row dropped.
            // A hint that splits reads as two hints.
            const shown = cut(piece, room);
            return .{ .end = shown.kept.len, .next = behind, .marked = shown.marked };
        }
        var iterator = terminal.width.wrapper(piece, room);
        const span = iterator.nextSpan().?;
        // A piece that the word wrap takes whole still did not fit the measure
        // above, so the row ends on it and the next row opens behind it.
        if (span.end == piece.len) return .{ .end = piece_end, .next = behind };
        return .{ .end = span.end, .next = span.end };
    }
    return .{ .end = end, .next = line.len };
}

/// The physical rows `text` occupies as a notice at `columns`. Must equal
/// exactly what `notice` paints, because the window math relies on the parity.
pub fn noticeRows(look: *const Notice, text: []const u8, columns: usize) usize {
    if (look.fit == .head) return @min(1, look.rows_max);
    var wrap = noticeWrap(look, text, columns);
    var count: usize = 0;
    while (wrap.next()) |_| count += 1;
    return @min(count, look.rows_max);
}

fn noticeWrap(look: *const Notice, text: []const u8, columns: usize) Wrap {
    return .{
        .rest = text,
        .columns = columns,
        // Saturating: a cluster wider than the whole budget survives `truncate`
        // as a one-column replacement but measures its true width here. A prefix
        // that opens on one can then report more columns than the row has.
        .lead = terminal.width.ofText(terminal.width.truncate(look.prefix, columns)),
    };
}

/// One box content row: the text it paints, how that text fits the row, the
/// emphasized run inside it, and the role that colors it. The row applies that
/// role at its start, and again behind the run. The role is the one source of
/// the color of the row, so no caller states it twice.
const Line = struct {
    content: []const u8,
    fit: Fit,
    run: Run = .{},
    role: role.Name = .text,
};

/// An emphasized run of bytes, as offsets into the text that holds it. A row
/// paints the part of the run that it holds. An empty run paints nothing.
const Run = struct { start: usize = 0, end: usize = 0 };

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

/// How an element fits a logical line that is wider than one row.
pub const Fit = enum {
    /// Break the line across as many rows as it needs.
    wrap,
    /// Keep one row and show the start of the line. One `…` marks the cut. A
    /// caller picks this when the start of a line identifies it, so the cut
    /// falls on the detail behind that. A box keeps one row per line, and a
    /// notice keeps one row for the whole text.
    head,
};

/// The body of one box: its text, how a long line fits, and which part of the
/// text the paint emphasizes. The role that colors the box is a paint-time
/// choice, so the measure does not take it.
pub const Box = struct {
    text: []const u8,
    fit: Fit = .wrap,
    emphasis: Emphasis = .none,

    /// Which part of a box body the paint emphasizes. The caller names the part
    /// and never the byte range, so the text and the range cannot disagree.
    pub const Emphasis = enum {
        /// No part. Every row paints one style from end to end.
        none,
        /// The value of the first key in the head row, such as the name of a
        /// tool. That name then stands out from the keys around it.
        first_value,
    };
};

/// The run that `.first_value` names: the value of the first key of the head
/// row. The run ends at the blank behind the value, or at the end of the head
/// row. The run is empty for a head row that holds no key.
fn firstValue(text: []const u8) Run {
    const head = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const key_separator = ": ";
    const key_end = std.mem.indexOf(u8, head, key_separator) orelse return .{};
    const start = key_end + key_separator.len;
    const value = head[start..];
    const length = std.mem.indexOfScalar(u8, value, ' ') orelse value.len;
    return .{ .start = start, .end = start + length };
}

/// The physical rows a box occupies at `columns`: the two padding rows around
/// the body plus the body itself. A `wrap` body counts its wrapped rows, and a
/// `head` body counts one row per logical line.
pub fn boxRows(body: *const Box, columns: usize) usize {
    var count: usize = 2;
    var lines = std.mem.splitScalar(u8, body.text, '\n');
    while (lines.next()) |line| count += switch (body.fit) {
        .wrap => terminal.width.rows(lineText(line), contentColumns(columns)),
        .head => 1,
    };
    return count;
}

/// The animation of the live input while a turn runs: the tick that moves the
/// separator segment, the ticks since the last progress event, and the blink
/// clock of the caret.
pub const Activity = struct {
    motion_tick: u64,
    progress_age_ticks: u64,
    /// The blink clock of the caret. The producer restarts it at zero on each
    /// edit, so the caret stays visible while the user types.
    caret_tick: u64 = 0,
};

/// Whether `activity` changes the input area at this width: the separator
/// segment moves, or the caret blink flips.
pub fn activityChanged(activity: *const Activity, columns: usize) bool {
    if (caretBlinkChanged(activity.caret_tick)) return true;
    if (columns == 0) return false;
    return activityHead(activity.motion_tick, columns) !=
        activityHead(activity.motion_tick -% 1, columns);
}

/// The columns one row leaves to content: every column of the row.
pub fn contentColumns(columns: usize) usize {
    return @max(columns, 1);
}

/// The one character that marks a cut row.
pub const ellipsis = "…";

/// What a cut leaves of a row: the text that fits, and whether the cut dropped
/// anything. A caller that keeps `marked` writes `ellipsis` after `kept`.
pub const Cut = struct { kept: []const u8, marked: bool };

/// `text` cut to `columns_max`. A cut row reserves the one column that the mark
/// of the cut takes, so the row and its mark together hold the width. Every row
/// that states a measure or an option takes this rule, so one row stays one row.
pub fn cut(text: []const u8, columns_max: usize) Cut {
    const shown = terminal.width.truncate(text, columns_max);
    if (shown.len == text.len) return .{ .kept = shown, .marked = false };
    const room = columns_max -| 1;
    const kept = terminal.width.truncate(text, room);
    // Saturating: `truncate` keeps a cluster wider than its whole budget, because
    // a row that narrow shows it as a one-column replacement. A row of the full
    // width paints the real cells of that cluster instead, and the mark then
    // reaches no cell at all. Such a cluster opens the text and is the whole of
    // `kept`, so the cut drops it and the mark takes the row.
    if (terminal.width.ofText(kept) > room) return .{ .kept = "", .marked = true };
    return .{ .kept = kept, .marked = true };
}

/// One box line without the carriage return of a CRLF break. The split that
/// yields the line breaks on the line feed alone, so that byte stays on the end,
/// where a row paints it as a replacement glyph. It terminates the line and is
/// no content, so the row sheds it. A markdown block sheds it the same way.
fn lineText(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

/// `text` as a notice (a notice, an error, the intro, a hint, or a header): the
/// wrapped rows of every line, with the prefix on the first row alone. A hint
/// too wide for a row keeps that row and marks its cut. A `head` notice keeps one
/// row of the first line and marks the cut the same way.
pub fn notice(placement: *const Placement, look: *const Notice, text: []const u8) !void {
    if (look.fit == .head) return noticeHead(placement, look, text);
    const shown_prefix = terminal.width.truncate(look.prefix, placement.columns);
    var wrap = noticeWrap(look, text, placement.columns);
    var index: usize = 0;
    while (wrap.next()) |row| : (index += 1) {
        if (index >= look.rows_max) break;
        const line = placement.base + index;
        if (line < placement.skip) continue;
        placement.sink.begin();
        try role.apply(placement.sink, look.role);
        if (index == 0) try placement.sink.text(shown_prefix);
        try placement.sink.text(row.kept);
        if (row.marked) try placement.sink.text(ellipsis);
        try attribute.apply(placement.sink, .reset);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
}

/// What one row keeps of `text`: the head of its first line, and whether the row
/// dropped anything. A line break ends the row, so every line behind it is a cut
/// too, and the mark states it even where the first line fits whole.
fn headCut(text: []const u8, columns_max: usize) Cut {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = lineText(text[0..line_end]);
    if (line_end == text.len) return cut(line, columns_max);
    return .{ .kept = terminal.width.truncate(line, columns_max -| 1), .marked = true };
}

/// One row of a fixed label and the head of the text behind it: the label that
/// opens the row, the cells it leaves to the text, and the mark of the cut.
const Head = struct { label: []const u8, kept: []const u8, marked: bool };

/// The one row that `label` and `text` share at `columns`. The label comes first,
/// so a window narrower than the label can never overflow the row. The mark of a
/// cut takes the last column of the row, and a label that leaves no column for it
/// gives up its own last column. Every cut then states itself.
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

/// The one row of a `head` notice: the prefix, the head of its first line, and
/// one `…` where the row cut the rest. A caller takes this form where a taller
/// notice would move the interface around it.
fn noticeHead(placement: *const Placement, look: *const Notice, text: []const u8) !void {
    if (look.rows_max == 0 or placement.base < placement.skip) return;
    const row = headRow(look.prefix, text, placement.columns);
    placement.sink.begin();
    try role.apply(placement.sink, look.role);
    try placement.sink.text(row.label);
    try placement.sink.text(row.kept);
    if (row.marked) try placement.sink.text(ellipsis);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

/// A filled box in one role: a blank padding row, the body fitted to the row
/// width with the fill carried to full width, then a blank padding row. A box
/// role reverses the video, so the fill takes the color of the role and the text
/// keeps the terminal background. It streams one row at a time and separates
/// itself inside the block gap around it.
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
        // The line break the split consumed belongs to the offset of the next
        // line, so the run keeps its place in the whole text.
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

/// `run` in the coordinates of a row that starts at `offset` in the box text. A
/// row that starts in front of the run keeps its offsets. The row cuts its own
/// text later, so `boxLineText` alone drops what the row does not hold.
fn rowRun(run: Run, offset: usize) Run {
    return .{ .start = run.start -| offset, .end = run.end -| offset };
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

/// A box's content row: the text from the first column, then the fill carried to
/// full width.
fn boxLine(placement: *const Placement, line: *usize, row: *const Line) !void {
    defer line.* += 1;
    if (line.* < placement.skip) return;
    placement.sink.begin();
    try role.apply(placement.sink, row.role);
    try boxLineCells(placement.sink, placement.columns, row);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = line.* });
}

/// The cells of the first box content row, without the row bookkeeping. The
/// text wraps at the live box width. The row carries no emphasized run. The
/// caller opens the row, applies the box color, and closes the style. The color
/// preview page uses this fixed row.
pub fn boxCells(sink: *terminal.View.Sink, columns: usize, text: []const u8) !void {
    var iterator = terminal.width.wrapper(text, contentColumns(columns));
    try boxLineCells(sink, columns, &.{ .content = iterator.next().?, .fit = .wrap });
}

fn boxLineCells(sink: *terminal.View.Sink, columns: usize, row: *const Line) !void {
    const room = contentColumns(columns);
    switch (row.fit) {
        // The wrap already cut the row, so it needs no mark of its own.
        .wrap => try boxLineText(sink, terminal.width.truncate(row.content, room), row),
        .head => {
            const shown = cut(row.content, room);
            try boxLineText(sink, shown.kept, row);
            if (shown.marked) try sink.text(ellipsis);
        },
    }
    try sink.spaces(columns -| sink.columns_written);
}

/// The text of one box row, with the part of the run that `text` holds in the
/// emphasis of the box role. The reset that closes the emphasis also closes the
/// color, so the row applies that role again behind the run.
fn boxLineText(sink: *terminal.View.Sink, text: []const u8, row: *const Line) !void {
    // The row cuts its text after the run reaches it, so the clamp lives here
    // alone. A cut inside the run then emphasizes what the row kept of it. The
    // clamp keeps the order of the bounds, because `@min` is monotone.
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
    const content_columns = contentColumns(placement.columns);
    const maybe_activity = framing.activity;
    const separators: Separators = .{
        .columns = placement.columns,
        .activity = maybe_activity,
    };
    // Drinky blinks the caret itself while the input animates. A terminal holds
    // its own cursor solid under a continuous repaint, and an animated input
    // repaints about every 16 ms. An idle input writes nothing, so the terminal
    // blinks the caret there.
    const caret_shown = if (maybe_activity) |activity| caretVisible(activity.caret_tick) else true;
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
        // The span carries the bytes the row covers, so the paint takes the cells
        // out of it. A row that keeps the blanks it breaks at puts them in every
        // copy of the input.
        const content = terminal.width.rowText(framing.body[span.start..span.end]);
        try framedRow(placement, maybe_caret, &line, content, maybe_role);
        body_count += 1;
    }
    // The wrapper exhausts at `index == wrapped rows`, the trailing row's index.
    // Emit it when the window reaches it (a `break` above leaves it out of view).
    if (framing.trailing_row and index >= framing.hidden_above and index < window_end) {
        try framedRow(placement, maybe_caret, &line, "", null);
        body_count += 1;
    }
    std.debug.assert(body_count == framing.body_rows);
    try ruleRow(placement, &separators, &line, .bottom, "↓", framing.hidden_below);
}

/// One open body row. It adds no side glyphs or padding, and it ends on the last
/// cell it fills, so a terminal copy contains only the body text. The function
/// drops rows in the clipped top.
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

/// Whether the caret shows on this tick. The caret shows for one blink interval
/// and hides for the next.
fn caretVisible(caret_tick: u64) bool {
    return caret_tick % (2 * caret_blink_ticks) < caret_blink_ticks;
}

/// Whether the blink flips on this tick. Each half cycle starts on a multiple of
/// the blink interval, so tick zero shows the caret again after an edit.
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

/// Physical rows the steering queue occupies: one row per queued message plus a
/// hint row. Zero when the queue is empty, so it contributes no component. Every
/// row of the block keeps one row, so the count needs no width.
pub fn steeringRows(messages: []const []const u8) usize {
    if (messages.len == 0) return 0;
    return messages.len + 1;
}

/// The steering queue: a `Queued message: <message>` row per queued message
/// (each cut to its first line and the window width, with one `…` on either cut),
/// then a faint hint row. Every row of the block keeps one row, so the queue
/// never moves the editor under it.
pub fn steering(placement: *const Placement, messages: []const []const u8) !void {
    var line = placement.base;
    for (messages) |message| {
        defer line += 1;
        if (line < placement.skip) continue;
        // The row keeps the first line of the message, and the mark states both
        // the width it cut and the lines it left out. The label opens the row, and
        // it gives up its last column where the mark has nowhere else to stand.
        const row = headRow("Queued message: ", message, placement.columns);
        placement.sink.begin();
        try role.apply(placement.sink, .accent);
        try placement.sink.text(row.label);
        try attribute.apply(placement.sink, .reset);
        try role.apply(placement.sink, .muted);
        try placement.sink.text(row.kept);
        if (row.marked) try placement.sink.text(ellipsis);
        try attribute.apply(placement.sink, .reset);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
    var hint_placement = placement.*;
    hint_placement.base = line;
    // The key stands first, so a cut takes the explanation and never the key.
    const hint = "\u{21B3} Ctrl+P: Edit all queued messages";
    try notice(&hint_placement, &.{ .role = .muted, .fit = .head }, hint);
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

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "abcdefghij") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "abcdefghijk") == null);
}

// A box wraps its text between words, so a copy of its rows out of the terminal
// holds whole words.
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

// One rule everywhere: a box adds no pad of its own, so a box row and an input
// row both take every column and start at the first one.
test "every row leaves the complete width to content" {
    try std.testing.expectEqual(@as(usize, 1), contentColumns(0));
    try std.testing.expectEqual(@as(usize, 1), contentColumns(1));
    try std.testing.expectEqual(@as(usize, 2), contentColumns(2));
    try std.testing.expectEqual(@as(usize, 80), contentColumns(80));
}

// A paste from a CRLF source ends every line with a carriage return. That byte
// terminates the line and is no content, so the row sheds it instead of painting
// a replacement glyph at the end of every row.
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
    // Two padding rows and one row a line: the shed byte adds no row.
    try std.testing.expectEqual(@as(usize, 4), boxRows(&body, columns));
    try std.testing.expect(std.mem.indexOf(u8, painted, "first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "second line") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\u{FFFD}") == null);
}

// A one-row fit shows the head of a line and marks the cut with one ellipsis.
// The head of each line identifies it, so the cut falls on the detail behind it.
// Each logical line keeps its own row.
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
    // The summary line keeps its own row and fits whole.
    try std.testing.expect(std.mem.indexOf(u8, painted, "Lines: 1") != null);
}

// The head row of a tool box names the tool, and that name takes the emphasis of
// the box role. The reset that closes the emphasis also closes the color, so the
// row applies that role again behind the name. No other row emphasizes anything.
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

    // A terminal copy loses every style, so each row reads as one line of text.
    const plain = try terminal.View.plainText(gpa, painted);
    defer gpa.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Tool: read \u{00B7} File: a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Lines: 3") != null);
}

// A row cuts its text after the run reaches it. The row then emphasizes what it
// kept of the run, and a wrap carries the rest to the row below. Every row still
// carries its fill to the full width.
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
    // The name is wider than the row, so the row that opens it emphasizes every
    // cell, and the row below emphasizes the rest of the name alone.
    const opened = comptime role.sequence(.tool_pending) ++ "\x1b[1mread_the_fil";
    const carried = comptime "\x1b[1me\x1b[0m" ++ role.sequence(.tool_pending) ++
        " \u{00B7} File: a";
    try std.testing.expect(std.mem.indexOf(u8, painted, opened) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, carried) != null);

    // Two padding rows around three content rows, each one full row of fill.
    const plain = try terminal.View.plainText(gpa, painted);
    defer gpa.free(plain);
    var rows = std.mem.splitSequence(u8, plain, "\r\n");
    var count: usize = 0;
    while (rows.next()) |row| : (count += 1)
        try std.testing.expectEqual(columns, terminal.width.ofText(row));
    try std.testing.expectEqual(boxRows(&body, columns), count);
}

// The run covers the value of the first key of the head row. A body that holds no
// key states no run. A row keeps the offsets of the run, and only the paint
// clamps them to the text that the row shows.
test "the emphasized run covers the first value alone" {
    try std.testing.expectEqual(Run{ .start = 6, .end = 10 }, firstValue(
        "Tool: read \u{00B7} File: a.zig\nLines: 3",
    ));
    // A call with no subject is its name alone, and the name ends the row.
    try std.testing.expectEqual(Run{ .start = 6, .end = 21 }, firstValue("Tool: describe_drinky"));
    // A user message holds no key, so no part of the box takes the emphasis.
    try std.testing.expectEqual(Run{}, firstValue("please read a.zig"));

    const run: Run = .{ .start = 6, .end = 10 };
    // A row behind the run keeps no offset of it, so the paint shows no run.
    try std.testing.expectEqual(Run{ .start = 0, .end = 0 }, rowRun(run, 25));
    // A row in front of the run keeps every byte of it.
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

    // A flip repaints even where the separator segment cannot move.
    try std.testing.expect(activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 0, .caret_tick = caret_blink_ticks },
        0,
    ));
    try std.testing.expect(!activityChanged(
        &.{ .motion_tick = 1, .progress_age_ticks = 0, .caret_tick = caret_blink_ticks + 1 },
        0,
    ));
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

// The case the width of an error tag makes: the tag fills the row, so the
// sentence starts under it and keeps every word.
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

// One cut keeps the column of its mark, whatever the clusters of the text do. A
// row that paints a wide cluster in the cells of the mark cuts silently, and a
// silent cut is the one thing the mark exists to stop.
test "a cut always leaves the mark a column of its own" {
    try expectCut(cut("ab", 2), "ab", false);
    try expectCut(cut("abc", 2), "a", true);
    // A cluster that fits the room stays, and the mark takes the column behind it.
    try expectCut(cut("\u{4F60}ab", 3), "\u{4F60}", true);
    // A cluster wider than the room goes away whole, so the mark stands alone.
    try expectCut(cut("\u{4F60}x", 2), "", true);
    try expectCut(cut("\u{4F60}x", 1), "", true);
    // Every cut holds the width: the cells it keeps plus the one of the mark.
    for ([_][]const u8{ "abc", "\u{4F60}x", "a\u{4F60}b", "\u{4F60}\u{4F60}" }) |text| {
        for (1..6) |columns| {
            const shown = cut(text, columns);
            const columns_used = terminal.width.ofText(shown.kept) + @intFromBool(shown.marked);
            try std.testing.expect(columns_used <= columns);
        }
    }
}

// The rows one notice paints at `columns`, as one plain text the caller owns.
// Every style goes, so each row reads as one line of text.
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

// A legend breaks at its separators, so every hint stays whole and no row starts
// or ends with a separator. A hint too wide for a row of its own keeps one row
// and states its cut. The count and the paint agree at every width.
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
        // A row that holds the widest hint keeps every hint whole. A row too
        // narrow for one hint breaks that hint between its words instead.
        if (columns < 21) continue;
        for (parts) |part| try std.testing.expect(std.mem.indexOf(u8, plain, part) != null);
    }
    // A width that holds two hints and their separator holds no third one.
    const plain = try paintedNotice(gpa, &look, text, 40);
    defer gpa.free(plain);
    try std.testing.expect(std.mem.indexOf(
        u8,
        plain,
        "Enter: Send \u{00B7} Shift+Enter: New line\r\n",
    ) != null);

    // A hint wider than the whole row cuts, because a hint that splits over two
    // rows reads as two hints. Every hint then holds exactly one row.
    const narrow = try paintedNotice(gpa, &look, text, 12);
    defer gpa.free(narrow);
    var narrow_rows = std.mem.splitSequence(u8, narrow, "\r\n");
    try std.testing.expectEqualStrings("Enter: Send", narrow_rows.next().?);
    try std.testing.expectEqualStrings("Shift+Enter" ++ ellipsis, narrow_rows.next().?);
    try std.testing.expectEqualStrings("Esc: Cancel", narrow_rows.next().?);
    try std.testing.expectEqualStrings("/help: Comm" ++ ellipsis, narrow_rows.next().?);
    try std.testing.expect(narrow_rows.next() == null);
}

// A line that holds no separator is a sentence. It breaks between its words, as
// the plain wrap breaks one, so a notice never loses the tail of a sentence and
// never marks a cut it did not make.
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
    // A word wider than the whole row still breaks inside itself, as it must.
    const word = try paintedNotice(gpa, &look, "AccessDeniedError", 8);
    defer gpa.free(word);
    try std.testing.expectEqualStrings("AccessDe\r\nniedErro\r\nr", word);
}

// The tag of an error stands on the first row of one notice alone. Two tags read
// as two errors, and an indent puts blanks into a copied row.
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
        // Every row after the first one opens on its own first character.
        if (count > 0) try std.testing.expect(!std.mem.startsWith(u8, row, " "));
    }
    try std.testing.expectEqual(noticeRows(&look, text, 24), count);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Try again.") != null);
}

// A one-row notice keeps its height and marks what the row cut. The footer and
// the steering hint take this form, because a row that grows moves the interface
// under it.
test "a head notice keeps one row and marks its cut" {
    const gpa = std.testing.allocator;
    const look: Notice = .{ .role = .muted, .fit = .head };
    const text = "Ctrl+P: Edit all queued messages\nnot another row";
    try std.testing.expectEqual(@as(usize, 1), noticeRows(&look, text, 16));

    const plain = try paintedNotice(gpa, &look, text, 16);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Ctrl+P: Edit al" ++ ellipsis, plain);

    // A row that holds the whole text takes no mark.
    const short = try paintedNotice(gpa, &look, "Ctrl+P: Edit", 16);
    defer gpa.free(short);
    try std.testing.expectEqualStrings("Ctrl+P: Edit", short);

    // A first line that fits still hides every line behind it, so the mark
    // states that cut too.
    const dropped = try paintedNotice(gpa, &look, "boom\nmore", 16);
    defer gpa.free(dropped);
    try std.testing.expectEqualStrings("boom" ++ ellipsis, dropped);

    // A cluster wider than the room of the row would take the cells of the mark,
    // so the cut drops it and the mark states the row on its own.
    const wide = try paintedNotice(gpa, &look, "\u{4F60}x", 2);
    defer gpa.free(wide);
    try std.testing.expectEqualStrings(ellipsis, wide);

    // A prefix that fills the row gives up its last column to the mark, because
    // the mark states the cut of a row that shows no content at all.
    const tagged: Notice = .{ .role = .@"error", .prefix = "Error: ", .fit = .head };
    const filled = try paintedNotice(gpa, &tagged, "boom", 7);
    defer gpa.free(filled);
    try std.testing.expectEqualStrings("Error:" ++ ellipsis, filled);
    // A row that holds the whole text keeps the whole prefix.
    const fits = try paintedNotice(gpa, &tagged, "boom", 11);
    defer gpa.free(fits);
    try std.testing.expectEqualStrings("Error: boom", fits);
}

// A wrapped notice behind a full-width prefix opens on the row under the prefix.
// An empty first line needs no row there, because the prefix row is that line.
test "a notice prefix row stands for an empty first line" {
    const gpa = std.testing.allocator;
    const look: Notice = .{ .role = .@"error", .prefix = "Error: " };
    const plain = try paintedNotice(gpa, &look, "\nTry again.", 7);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Error: \r\nTry\r\nagain.", plain);
    try std.testing.expectEqual(@as(usize, 3), noticeRows(&look, "\nTry again.", 7));
}

// A prefix wider than the whole row takes that row for itself, and the text
// opens on the row under it. No row overflows the width, and no cluster of the
// text falls behind the prefix, where the clip of the sink would eat it.
test "a wide notice prefix fits in a one-column row" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();

    const look: Notice = .{ .role = .muted, .prefix = "你" };
    try std.testing.expectEqual(@as(usize, 3), noticeRows(&look, "hi", 1));
    // An empty notice states its prefix and needs no row of its own for content.
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
    // The prefix holds the first row, and the text follows it whole.
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
