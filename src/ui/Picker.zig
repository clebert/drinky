//! A single-choice list for the live region: a responsive caption, then the
//! options. The options sit between the same open separators as the editor, so
//! the list takes the editor's place. Each option holds one row, the selected
//! one is highlighted, and a pre-existing choice is tagged "(Current)".
//!
//! The caption carries an accent title and a muted key hint above the frame. It
//! is chrome, not content. It stays outside the scrolled window, so the picker
//! window never scrolls it away. The hidden-row labels then count option rows
//! alone. The shared caption component owns every responsive split, and three
//! rows bound it, so chrome cannot crowd the options out of a narrow window.
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

const Caption = @import("Caption.zig");
const block = @import("block.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const terminal = @import("terminal");

const Picker = @This();

/// The key hint of a first step. Esc leaves the picker.
const hint_cancel = "↑/↓: Move · Enter: Select · Esc: Cancel";
/// The key hint of a later step. Esc opens the step above, and one Esc per step
/// leaves the picker.
const hint_back = "↑/↓: Move · Enter: Select · Esc: Back";
/// The key hint of a list that waits. It holds no row to move or select, and
/// Esc ends the wait alone.
const hint_wait = "Esc: Cancel";
/// The tag of the option that holds the value the picker starts on.
const tag_current = " (Current)";
/// The pad in front of a row: the marker column of the selection. The wait row
/// keeps it, so its text lines up with the rows it replaced.
const pad_selected = " > ";
const pad_plain = "   ";
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
/// Whether a step stands above this list. It selects the key hint alone. See
/// `Start`.
can_step_back: bool,
/// The text that stands in for the rows while the list waits, or null while the
/// list holds its rows. Borrowed. See `beginWait`.
wait: ?[]const u8,

/// Where a list sits: the highlighted row, and the first body row the window
/// shows. A caller that reopens a list hands both back, so the list looks as the
/// user left it. `reflow` corrects a pair that the live window cannot hold.
pub const Position = struct {
    cursor: usize = 0,
    scroll: usize = 0,
};

/// How a list opens.
pub const Start = struct {
    /// The row that holds the value already in use. It carries the tag, and the
    /// highlight opens on it. Null tags no row.
    current: ?usize = null,
    /// Where the user left this list, over `current`. Null opens the list on
    /// `current`, at the top.
    position: ?Position = null,
    /// Whether a step stands above this list. It selects the key hint alone, and
    /// the caller owns what Esc then does.
    can_step_back: bool = false,
};

/// What a paint passes to `render` beside the placement.
pub const RenderOptions = struct {
    viewport_rows: usize,
    /// The motion of the separators while the list waits. Null paints them
    /// still, as every list that holds its rows does.
    activity: ?paint.Activity = null,
};

/// Take ownership of `options` and compose the initial body. On failure the
/// caller still owns `options`.
pub fn init(
    gpa: std.mem.Allocator,
    title: []const u8,
    options: []const []const u8,
    start: Start,
) !Picker {
    // A rebuilt list can be shorter than the one the position came from.
    const rows_max = options.len -| 1;
    const opened: Position = start.position orelse .{ .cursor = start.current orelse 0 };
    var self: Picker = .{
        .gpa = gpa,
        .title = title,
        .options = options,
        .cursor = @min(opened.cursor, rows_max),
        .marked = start.current,
        .content = .empty,
        .line_roles = .empty,
        .scroll = @min(opened.scroll, rows_max),
        .cursor_offset = 0,
        .columns_max = unbounded,
        .can_step_back = start.can_step_back,
        .wait = null,
    };
    errdefer self.content.deinit(gpa);
    errdefer self.line_roles.deinit(gpa);
    try self.compose();
    return self;
}

pub fn deinit(self: *Picker) void {
    self.freeOptions();
    self.content.deinit(self.gpa);
    self.line_roles.deinit(self.gpa);
}

/// Drop every row and state `text` in their place, so no selection can land on
/// a row that a pending result replaces. The caller rebuilds the list from that
/// result, or reopens the step on a cancel. The list borrows `text`.
pub fn beginWait(self: *Picker, text: []const u8) !void {
    self.freeOptions();
    self.options = &.{};
    self.cursor = 0;
    self.marked = null;
    self.scroll = 0;
    self.wait = text;
    try self.compose();
}

fn freeOptions(self: *Picker) void {
    for (self.options) |option| self.gpa.free(option);
    self.gpa.free(self.options);
}

/// Where the list sits now. A caller that replaces this picker keeps it, so the
/// list it reopens later looks as the user left it.
pub fn position(self: *const Picker) Position {
    return .{ .cursor = self.cursor, .scroll = self.scroll };
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
    return self.captionRows(size.columns) +
        paint.framedRows(@min(total_body, paint.bodyLimit(size.rows)));
}

/// Stream the caption, then the option rows between their separators, through
/// `placement`. Window the list to its scroll limit for `options.viewport_rows`.
/// Assumes `reflow` set the scroll.
pub fn render(
    self: *const Picker,
    placement: *const paint.Placement,
    options: *const RenderOptions,
) !void {
    const caption_rows = try self.renderCaption(placement);
    const columns_max = paint.contentColumns(placement.columns);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    const visible_rows = @min(total_body, paint.bodyLimit(options.viewport_rows));
    // The derived placement copies its parent. Only the geometry changes.
    var frame_placement = placement.*;
    frame_placement.base = placement.base + caption_rows;
    try paint.framed(&frame_placement, &.{
        .body = self.content.items,
        .body_rows = visible_rows,
        .hidden_above = self.scroll,
        .hidden_below = total_body - self.scroll - visible_rows,
        .line_roles = self.line_roles.items,
        .activity = options.activity,
    });
}

/// Paint the responsive caption and return its occupied rows.
fn renderCaption(self: *const Picker, placement: *const paint.Placement) !usize {
    const chrome = self.caption();
    return chrome.render(placement);
}

/// Physical rows of the shared caption.
fn captionRows(self: *const Picker, columns: usize) usize {
    const chrome = self.caption();
    return chrome.rows(columns);
}

/// The semantic title and key hint of this list. Three rows bound the caption,
/// so narrow chrome stays predictable: the title row, then the control rows
/// that fit. A control segment past the bound drops whole.
fn caption(self: *const Picker) Caption {
    return .{
        .title = self.title,
        .controls = if (self.wait != null)
            hint_wait
        else if (self.can_step_back)
            hint_back
        else
            hint_cancel,
        .rows_max = 3,
    };
}

/// Rebuild `content`: one row per option, the selected one in the selection role
/// and any pre-existing choice tagged. Reverse video marks the selection with the
/// terminal foreground and background. Every row carries text, so the frame holds
/// no blank row. Rows are `\n`-separated and carry a three-column left pad for
/// the selection marker. The trusted role lives separately in `line_roles`.
///
/// A list that waits holds one muted row with its wait text in place of the
/// options. The row keeps the pad, so it lines up with the rows it replaced.
fn compose(self: *Picker) !void {
    self.content.clearRetainingCapacity();
    self.line_roles.clearRetainingCapacity();
    // Reset with the buffers it indexes into: a failure below must not leave the
    // offset past the shorter rebuilt content for `reflow` to slice.
    self.cursor_offset = 0;

    if (self.wait) |text| {
        try self.startLine(.muted);
        try self.content.appendSlice(self.gpa, pad_plain);
        try self.content.appendSlice(self.gpa, text);
        return self.cut(0, self.columns_max);
    }

    for (self.options, 0..) |option, index| {
        const chosen = index == self.cursor;
        const name: role.Name = if (chosen) .selection else .muted;
        try self.startLine(name);
        if (chosen) self.cursor_offset = self.content.items.len;
        const start = self.content.items.len;
        const tag = if (self.marked == index) tag_current else "";
        const tag_columns = terminal.width.ofText(tag);
        try self.content.appendSlice(self.gpa, if (chosen) pad_selected else pad_plain);
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
    var picker = try Picker.init(gpa, "Pick", options, .{ .current = 0 });
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

    // One caption row, two separators, and two option rows make five rows. A
    // short list wastes no row, so no blank row sits inside the frame.
    try std.testing.expectEqual(@as(usize, 1), picker.captionRows(size.columns));
    try std.testing.expectEqual(@as(usize, 5), picker.rows(size));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "\n\n") == null);
    try std.testing.expect(!std.mem.startsWith(u8, picker.content.items, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, picker.content.items, "\n"));
    // The caption is chrome, so neither the title nor the hint is a body row.
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Pick") == null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Esc: Cancel") == null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "alpha (Current)") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, picker.content.items, 0x1b) == null);
    try std.testing.expectEqual(role.Name.selection, picker.line_roles.items[1].?);

    // Painted order: the accent title and muted controls, then the frame.
    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    const title = comptime role.sequence(.accent) ++ "Pick\x1b[0m";
    const controls = comptime role.sequence(.muted) ++ " · ↑/↓: Move";
    try std.testing.expect(std.mem.indexOf(u8, painted, title) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, controls) != null);
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Pick").? < std.mem.indexOf(u8, painted, "─").?,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Esc: Cancel").? < std.mem.indexOf(u8, painted, "─").?,
    );
    try std.testing.expectEqual(@as(usize, 5), block.paintedRows(painted));
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
    try picker.render(&placement, &.{ .viewport_rows = size.rows });
    try view.render();
    return gpa.dupe(u8, out.written());
}

// A row that starts a fetch clears the list, so no selection can land on a row
// that the result replaces. The wait row takes the place of the options, the
// hint names the one key that still acts, and the separators move while the
// list waits.
test "a list that waits drops its rows, states the wait, and moves its separators" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "Refresh the model list", "claude-opus-5" }, 1);
    defer picker.deinit();
    picker.can_step_back = true;
    const size: terminal.View.Size = .{ .columns = 60, .rows = 24 };

    try picker.beginWait("Drinky fetches the model list.");
    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 0), picker.options.len);
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try std.testing.expect(picker.marked == null);
    // The one body row is the wait text in the muted role, padded like a row.
    try std.testing.expectEqualStrings("   Drinky fetches the model list.", picker.content.items);
    try std.testing.expectEqual(@as(usize, 1), picker.line_roles.items.len);
    try std.testing.expectEqual(role.Name.muted, picker.line_roles.items[0].?);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "claude") == null);
    // The caption, two separators, and the wait row make four rows.
    try std.testing.expectEqual(@as(usize, 4), picker.rows(size));

    // No row remains to move to, so a move changes nothing.
    try picker.moveDown();
    try picker.moveUp();
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);

    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Back") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Enter: Select") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Drinky fetches") != null);
    try std.testing.expectEqual(@as(usize, 4), block.paintedRows(painted));
    // The separators stand still without an activity.
    try std.testing.expect(std.mem.indexOf(u8, painted, "━") == null);

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
    try picker.render(&placement, &.{
        .viewport_rows = size.rows,
        .activity = .{ .motion_tick = 3, .progress_age_ticks = 0 },
    });
    try view.render();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "━") != null);
}

// A list that the user returns to opens on the row they left, over the row that
// carries the tag. The rebuilt list can be shorter, so the row clamps.
test "the opening row takes the cursor over the current value, inside the list" {
    const gpa = std.testing.allocator;
    const labels = [_][]const u8{ "alpha", "beta", "gamma" };

    for ([_]struct { start: Start, cursor: usize, scroll: usize = 0, marked: ?usize }{
        .{ .start = .{}, .cursor = 0, .marked = null },
        .{ .start = .{ .current = 2 }, .cursor = 2, .marked = 2 },
        .{
            .start = .{ .current = 2, .position = .{ .cursor = 1 } },
            .cursor = 1,
            .marked = 2,
        },
        .{
            .start = .{ .position = .{ .cursor = 1, .scroll = 1 } },
            .cursor = 1,
            .scroll = 1,
            .marked = null,
        },
        // A pair past the end of a shorter list falls back to the last row.
        .{
            .start = .{ .position = .{ .cursor = 99, .scroll = 99 } },
            .cursor = 2,
            .scroll = 2,
            .marked = null,
        },
    }) |case| {
        const options = try gpa.alloc([]const u8, labels.len);
        for (labels, 0..) |label, index| options[index] = try gpa.dupe(u8, label);
        var picker = try Picker.init(gpa, "Pick", options, case.start);
        defer picker.deinit();
        try std.testing.expectEqual(case.cursor, picker.cursor);
        try std.testing.expectEqual(case.scroll, picker.scroll);
        try std.testing.expectEqual(case.marked, picker.marked);
        try std.testing.expectEqual(case.cursor, picker.position().cursor);
        try std.testing.expectEqual(case.scroll, picker.position().scroll);
    }

    // An empty list holds no row at all.
    const no_rows = try gpa.alloc([]const u8, 0);
    var empty = try Picker.init(gpa, "Pick", no_rows, .{ .position = .{ .cursor = 4 } });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.cursor);
}

// A step above the list changes one word of the key hint, so the user reads what
// Esc does before pressing it.
test "the key hint states the step above a later step" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 0);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 60, .rows = 24 };
    try picker.reflow(size);

    const first_step = try renderForTest(gpa, &picker, size);
    defer gpa.free(first_step);
    try std.testing.expect(std.mem.indexOf(u8, first_step, "Esc: Cancel") != null);

    picker.can_step_back = true;
    const later_step = try renderForTest(gpa, &picker, size);
    defer gpa.free(later_step);
    try std.testing.expect(std.mem.indexOf(u8, later_step, "Esc: Back") != null);
    try std.testing.expect(std.mem.indexOf(u8, later_step, "Esc: Cancel") == null);
    // Both complete captions hold one row, so the frame keeps its place.
    try std.testing.expectEqual(@as(usize, 1), picker.captionRows(size.columns));
}

// Every option holds one row, whatever the width does. A row too wide for the
// window loses its tail to one `…`, so the highlight and the step of the
// selection keep one height.
test "a row too wide for the window is cut and marked" {
    const gpa = std.testing.allocator;
    // A long row and a current value, because only a list with a current value
    // carries the tag.
    var picker = try testPicker(gpa, &.{
        "claude-sonnet-5 (Anthropic Subscription)",
        "two\nrows in one option",
    }, 0);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 24, .rows = 24 };

    try picker.reflow(size);
    // Two options, so two rows. Three rows bound this narrow caption: the
    // title, then two control rows. With the two separators that makes five.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, picker.content.items, "\n") + 1);
    try std.testing.expectEqual(@as(usize, 3), picker.captionRows(size.columns));
    try std.testing.expectEqual(@as(usize, 7), picker.rows(size));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "…") != null);
    // The row break inside an option cannot open a row of its own.
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "rows in one option") == null);

    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    // The tag states what the row is, so the cut takes the text it marks and
    // never the tag itself.
    try std.testing.expect(std.mem.indexOf(u8, painted, " > claude-son… (Current)") != null);
    try std.testing.expectEqual(@as(usize, 7), block.paintedRows(painted));
    // The kept control rows hold whole segments, and the segment past the row
    // bound drops whole. Esc still cancels, so the drop costs no capability.
    for ([_][]const u8{ "↑/↓: Move", "Enter: Select" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, painted, part) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Cancel") == null);

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
    // and the two separators add three rows around it.
    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
    try std.testing.expectEqual(@as(usize, 9), picker.rows(size));

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
