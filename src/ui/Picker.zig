//! A single-choice list for the live region: a muted caption, then the options.
//! The options sit between the same open separators as the editor, so the list
//! takes the editor's place. Each option holds one row, the selected one is
//! highlighted, and a pre-existing choice is tagged "(Current)".
//!
//! The caption carries the title and the key hint above the frame. It is chrome,
//! not content. It stays outside the scrolled window, so the picker window never
//! scrolls it away. The hidden-row labels then count option rows alone. The page
//! header follows the same pattern.
//!
//! The picker owns its option strings and the composed `content` buffer (freed on
//! `deinit`) and borrows the title. Navigation moves the selection and rolls over
//! at both ends. `reflow` windows a tall list to keep it in view. The caller
//! reads `cursor` and acts on the selected row.
//!
//! Every option holds exactly one row: `compose` cuts a row that the window
//! cannot hold and marks the cut with one `…`. One row per option keeps the
//! highlight and the step of the selection the same height for every list.

const std = @import("std");

const block = @import("block.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const terminal = @import("terminal");

const Picker = @This();

const hint = "↑/↓: Move · Enter: Select · Esc: Cancel";
/// The tag of the option that holds the value the picker starts on.
const tag_current = " (Current)";
/// The width a picker composes its rows for before the first paint measures the
/// window. No row reaches it, so no row is cut at that point.
const unbounded = std.math.maxInt(usize);

gpa: std.mem.Allocator,
title: []const u8,
options: []const []const u8,
/// The highlighted row. Navigation moves it.
cursor: usize,
/// The row to tag "(Current)", if any: a pre-existing choice, distinct from
/// where the cursor happens to sit.
marked: ?usize,
/// The option rows between the separators. A selection move rebuilds them.
/// Columns-independent, so `rows` and `render` only wrap them to fit.
content: std.ArrayList(u8),
/// Trusted presentation metadata for each logical line in `content`. Role names
/// never share storage with option text.
line_roles: std.ArrayList(?role.Name),
/// The first wrapped body row shown when the body is taller than its slot. The
/// window scrolls to keep the selection in view. `reflow` maintains it.
scroll: usize,
/// Byte offset into `content` where the highlighted option's row begins.
/// `compose` sets it. `reflow` maps it to a wrapped row to keep the selection
/// in view.
cursor_offset: usize,
/// The columns the composed rows are cut to. It starts unbounded, because
/// `init` runs before the first paint. `reflow` sets the live width, so a width
/// change recomposes the rows.
columns_max: usize,

/// Take ownership of `options` and compose the initial body. `current`, if set,
/// is the row to mark and preselect. On failure the caller still owns `options`.
pub fn init(
    gpa: std.mem.Allocator,
    title: []const u8,
    options: []const []const u8,
    current: ?usize,
) !Picker {
    var self: Picker = .{
        .gpa = gpa,
        .title = title,
        .options = options,
        .cursor = current orelse 0,
        .marked = current,
        .content = .empty,
        .line_roles = .empty,
        .scroll = 0,
        .cursor_offset = 0,
        .columns_max = unbounded,
    };
    errdefer self.content.deinit(gpa);
    errdefer self.line_roles.deinit(gpa);
    try self.compose();
    return self;
}

pub fn deinit(self: *Picker) void {
    for (self.options) |option| self.gpa.free(option);
    self.gpa.free(self.options);
    self.content.deinit(self.gpa);
    self.line_roles.deinit(self.gpa);
}

/// Move the selection one row up. The first option rolls over to the last one.
pub fn moveUp(self: *Picker) !void {
    if (self.options.len == 0) return;
    self.cursor = if (self.cursor == 0) self.options.len - 1 else self.cursor - 1;
    try self.compose();
}

/// Move the selection one row down. The last option rolls over to the first one.
pub fn moveDown(self: *Picker) !void {
    if (self.options.len == 0) return;
    self.cursor = if (self.cursor + 1 >= self.options.len) 0 else self.cursor + 1;
    try self.compose();
}

/// Recompose the rows for the live width, then re-clamp the scroll offset so the
/// highlighted option's row stays inside the visible window. Call once per
/// repaint. Pass the same `size` whose columns and rows `render` and `rows` will
/// use, so all three agree.
///
/// The window holds option rows alone, so the first option sits at its top and a
/// step of one row reaches both ends of the list.
pub fn reflow(self: *Picker, size: terminal.View.Size) !void {
    const columns_max = paint.contentColumns(size.columns);
    if (self.columns_max != columns_max) {
        self.columns_max = columns_max;
        try self.compose();
    }
    const total_body = terminal.width.rows(self.content.items, columns_max);
    const visible = @min(total_body, paint.bodyLimit(size.rows));
    const cursor_row = terminal.width.caret(self.content.items, .{
        .offset = self.cursor_offset,
        .columns_max = columns_max,
    }).rows_before;
    if (cursor_row < self.scroll) self.scroll = cursor_row;
    if (cursor_row >= self.scroll + visible) self.scroll = cursor_row - visible + 1;
    self.scroll = @min(self.scroll, total_body - visible);
}

/// Physical rows the picker occupies: the caption, two separators, and the
/// wrapped option rows. The list stops at its scroll limit for `size.rows`.
pub fn rows(self: *const Picker, size: terminal.View.Size) usize {
    const columns_max = paint.contentColumns(size.columns);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    return self.captionRows() + paint.framedRows(@min(total_body, paint.bodyLimit(size.rows)));
}

/// Stream the caption, then the option rows between their separators, through
/// `placement`. Window the list to its scroll limit for `viewport_rows`. Assumes
/// `reflow` set the scroll.
pub fn render(self: *const Picker, placement: *const paint.Placement, viewport_rows: usize) !void {
    try self.renderCaption(placement);
    const columns_max = paint.contentColumns(placement.columns);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    const visible_rows = @min(total_body, paint.bodyLimit(viewport_rows));
    // The derived placement copies its parent. Only the geometry changes.
    var frame_placement = placement.*;
    frame_placement.base = placement.base + self.captionRows();
    try paint.framed(&frame_placement, &.{
        .body = self.content.items,
        .body_rows = visible_rows,
        .hidden_above = self.scroll,
        .hidden_below = total_body - self.scroll - visible_rows,
        .line_roles = self.line_roles.items,
    });
}

/// The muted caption above the frame: the title, then the key hint. Each row
/// truncates instead of wrapping, so the caption keeps its height at every width.
fn renderCaption(self: *const Picker, placement: *const paint.Placement) !void {
    try paint.notice(placement, &.{ .role = .muted, .prefix = "" }, self.title);
    // The derived placement copies its parent. Only the geometry changes.
    var hint_placement = placement.*;
    hint_placement.base = placement.base + titleRows(self.title);
    try paint.notice(&hint_placement, &.{ .role = .muted, .prefix = "" }, hint);
}

/// Physical rows of the caption: the title rows and the one key-hint row.
fn captionRows(self: *const Picker) usize {
    return titleRows(self.title) + 1;
}

/// Rows the title holds. A notice truncates each of its lines to one row, so only
/// a title with a line break takes more than one row.
fn titleRows(title: []const u8) usize {
    return 1 + std.mem.count(u8, title, "\n");
}

/// Rebuild `content`: one row per option, the selected one in the selection role
/// and any pre-existing choice tagged. Reverse video marks the selection with the
/// terminal foreground and background. Every row carries text, so the frame holds
/// no blank row. Rows are `\n`-separated and carry a three-column left pad for
/// the selection marker. The trusted role lives separately in `line_roles`.
fn compose(self: *Picker) !void {
    self.content.clearRetainingCapacity();
    self.line_roles.clearRetainingCapacity();
    // Reset with the buffers it indexes into: a failure below must not leave the
    // offset past the shorter rebuilt content for `reflow` to slice.
    self.cursor_offset = 0;

    for (self.options, 0..) |option, index| {
        const chosen = index == self.cursor;
        const name: role.Name = if (chosen) .selection else .muted;
        try self.startLine(name);
        if (chosen) self.cursor_offset = self.content.items.len;
        const start = self.content.items.len;
        const tag = if (self.marked == index) tag_current else "";
        const tag_columns = terminal.width.ofText(tag);
        try self.content.appendSlice(self.gpa, if (chosen) " > " else "   ");
        try self.content.appendSlice(self.gpa, option);
        if (tag_columns < self.columns_max) {
            // The tag states what the row is, so the cut takes the option text
            // and leaves the tag. The row then holds the width by construction.
            try self.cut(start, self.columns_max - tag_columns);
            try self.content.appendSlice(self.gpa, tag);
        } else {
            // The window is narrower than the tag, so one cut takes both.
            try self.content.appendSlice(self.gpa, tag);
            try self.cut(start, self.columns_max);
        }
    }
}

/// Cut the row that starts at `start` to `columns_max`, and mark the cut with
/// one `…`. A row that fits keeps every byte. The cut stops at a row break too,
/// so untrusted text that holds one cannot open a row of its own.
fn cut(self: *Picker, start: usize, columns_max: usize) !void {
    const shown = paint.cut(self.content.items[start..], columns_max);
    if (!shown.marked) return;
    self.content.shrinkRetainingCapacity(start + shown.kept.len);
    try self.content.appendSlice(self.gpa, paint.ellipsis);
}

/// Open the next logical body row and record its role. Every option row carries
/// one, so `line_roles` holds no null. The list keeps an optional role, because
/// the framed painter takes that form for a body whose rows can go unstyled.
fn startLine(self: *Picker, name: role.Name) !void {
    if (self.line_roles.items.len > 0) try self.content.append(self.gpa, '\n');
    try self.line_roles.append(self.gpa, name);
}

fn testPicker(gpa: std.mem.Allocator, labels: []const []const u8, cursor: usize) !Picker {
    const options = try gpa.alloc([]const u8, labels.len);
    for (labels, 0..) |label, index| options[index] = try gpa.dupe(u8, label);
    var picker = try Picker.init(gpa, "Pick", options, 0);
    picker.cursor = cursor;
    try picker.compose();
    return picker;
}

test "navigation rolls over at both ends and the cursor tracks the selection" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 0);
    defer picker.deinit();

    // The first option rolls up to the last one, and the last one rolls down to
    // the first one again.
    try picker.moveUp();
    try std.testing.expectEqual(@as(usize, 1), picker.cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
}

test "the frame holds the option rows alone and the caption stays above it" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 1);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 24 };

    // A title row, a hint row, two separators, and two option rows make six
    // rows. A short list wastes no row, so no blank row sits inside the frame.
    try std.testing.expectEqual(@as(usize, 2), picker.captionRows());
    try std.testing.expectEqual(@as(usize, 6), picker.rows(size));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "\n\n") == null);
    try std.testing.expect(!std.mem.startsWith(u8, picker.content.items, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, picker.content.items, "\n"));
    // The caption is chrome, so neither the title nor the hint is a body row.
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Pick") == null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Esc: Cancel") == null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "alpha (Current)") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, picker.content.items, 0x1b) == null);
    try std.testing.expectEqual(role.Name.selection, picker.line_roles.items[1].?);

    // Painted order: the muted caption, then the frame around the options.
    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    const title = comptime role.sequence(.muted) ++ "Pick\x1b[0m";
    try std.testing.expect(std.mem.indexOf(u8, painted, title) != null);
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Pick").? < std.mem.indexOf(u8, painted, "─").?,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Esc: Cancel").? < std.mem.indexOf(u8, painted, "─").?,
    );
    try std.testing.expectEqual(@as(usize, 6), block.paintedRows(painted));
}

fn renderForTest(
    gpa: std.mem.Allocator,
    picker: *const Picker,
    size: terminal.View.Size,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(size, 4);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = size.columns,
        .base = 0,
        .skip = 0,
    };
    try picker.render(&placement, size.rows);
    try view.render();
    return gpa.dupe(u8, out.written());
}

// Every option holds one row, whatever the width does. A row too wide for the
// window loses its tail to one `…`, so the highlight and the step of the
// selection keep one height.
test "a row too wide for the window is cut and marked" {
    const gpa = std.testing.allocator;
    // A `/model` row, because only a list with a current value carries the tag.
    var picker = try testPicker(gpa, &.{
        "claude-sonnet-5 (Anthropic Subscription)",
        "two\nrows in one option",
    }, 0);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 24, .rows = 24 };

    try picker.reflow(size);
    // Two options, so two rows: the caption and the two separators add four.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, picker.content.items, "\n") + 1);
    try std.testing.expectEqual(@as(usize, 6), picker.rows(size));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "…") != null);
    // The row break inside an option cannot open a row of its own.
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "rows in one option") == null);

    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    // The tag states what the row is, so the cut takes the text it marks and
    // never the tag itself.
    try std.testing.expect(std.mem.indexOf(u8, painted, " > claude-son… (Current)") != null);
    try std.testing.expectEqual(@as(usize, 6), block.paintedRows(painted));

    // Every row holds the width, even a window narrower than the tag.
    for ([_]usize{ 24, 8, 3, 1 }) |columns| {
        try picker.reflow(.{ .columns = columns, .rows = 24 });
        var lines = std.mem.splitScalar(u8, picker.content.items, '\n');
        while (lines.next()) |line|
            try std.testing.expect(terminal.width.ofText(line) <= columns);
    }

    // A wider window recomposes the rows and shows what the cut dropped.
    try picker.reflow(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Subscription") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "(Current)") != null);
}

test "a tall option list scrolls the window to keep the selection in view" {
    const gpa = std.testing.allocator;
    var storage: [20][8]u8 = undefined;
    var labels: [20][]const u8 = undefined;
    for (&labels, 0..) |*label, index| {
        label.* = std.fmt.bufPrint(&storage[index], "row{d:0>2}", .{index}) catch unreachable;
    }
    var picker = try testPicker(gpa, &labels, 0);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 20 };

    // A 20-row viewport caps the list at six rows. With the selection on the
    // first option the window sits at the top and nothing scrolls. The caption
    // and the two separators add four rows above and below it.
    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
    try std.testing.expectEqual(@as(usize, 10), picker.rows(size));

    // A walk of the selection to the last option drags the window down after it.
    for (0..19) |_| {
        try picker.moveDown();
        try picker.reflow(size);
    }
    try std.testing.expectEqual(@as(usize, 19), picker.cursor);
    try std.testing.expectEqual(@as(usize, 14), picker.scroll);

    const bottom = try renderForTest(gpa, &picker, size);
    defer gpa.free(bottom);
    // The selected tail option shows in the selection role, the scrolled-off
    // head does not, and the top separator reports the options hidden above the
    // window. The caption stays in view at the bottom of the list.
    const selected = comptime role.sequence(.selection) ++ " > row19\x1b[0m";
    try std.testing.expect(std.mem.indexOf(u8, bottom, selected) != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "row00") == null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "↑ Hidden: 14") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "Pick") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "Esc: Cancel") != null);

    // A walk back up drags the window with the selection, and the first option
    // sits at the top of the list again.
    for (0..19) |_| {
        try picker.moveUp();
        try picker.reflow(size);
    }
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);

    const top = try renderForTest(gpa, &picker, size);
    defer gpa.free(top);
    try std.testing.expect(std.mem.indexOf(u8, top, "Pick") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "Esc: Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "row00") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "row19") == null);
    try std.testing.expect(std.mem.indexOf(u8, top, "↑ Hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, top, "↓ Hidden: 14") != null);

    // A roll over off the first option shows the end of the list whole.
    try picker.moveUp();
    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 19), picker.cursor);
    try std.testing.expectEqual(@as(usize, 14), picker.scroll);
}
