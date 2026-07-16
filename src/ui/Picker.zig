//! A single-choice list for the live region: a title and a key hint above the
//! options, each option on its own row with the selected one highlighted and any
//! pre-existing choice tagged "(current)". It renders in the same framed input
//! area as the editor, so it sits where the editor would. It owns its option
//! strings and the composed `content` buffer (freed on `deinit`) and borrows the
//! title. Navigation moves the selection; `reflow` windows a tall list to keep
//! it in view. The caller reads `selectedIndex` and acts on the selected row.

const std = @import("std");

const color = @import("color.zig");
const paint = @import("paint.zig");
const terminal = @import("terminal");

const Picker = @This();

const hint = "↑/↓ move · enter select · esc cancel";

gpa: std.mem.Allocator,
title: []const u8,
options: []const []const u8,
/// The highlighted row, moved by navigation.
cursor: usize,
/// The row to tag "(current)", if any — a pre-existing choice, distinct from
/// where the cursor happens to sit.
marked: ?usize,
/// The body between the framing rules, rebuilt whenever the selection moves.
/// Columns-independent, so `rows` and `render` only wrap it to fit.
content: std.ArrayList(u8),
/// The first wrapped body row shown when the body is taller than its slot; the
/// window scrolls to keep the selection in view. `reflow` maintains it.
scroll: usize,
/// Byte offset into `content` where the highlighted option's row begins, set by
/// `compose`; `reflow` maps it to a wrapped row to keep the selection in view.
cursor_offset: usize,

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
        .scroll = 0,
        .cursor_offset = 0,
    };
    errdefer self.content.deinit(gpa);
    try self.compose();
    return self;
}

pub fn deinit(self: *Picker) void {
    for (self.options) |option| self.gpa.free(option);
    self.gpa.free(self.options);
    self.content.deinit(self.gpa);
}

pub fn moveUp(self: *Picker) !void {
    if (self.cursor == 0) return;
    self.cursor -= 1;
    try self.compose();
}

pub fn moveDown(self: *Picker) !void {
    if (self.cursor + 1 >= self.options.len) return;
    self.cursor += 1;
    try self.compose();
}

/// The selected row's index, applied by the command that opened the picker.
pub fn selectedIndex(self: *const Picker) usize {
    return self.cursor;
}

/// Re-clamp the scroll offset so the highlighted option's wrapped row stays
/// inside the visible window. Call once per repaint, passing the same `columns`
/// and `viewport_rows` that `render` and `rows` will use, so all three agree.
pub fn reflow(self: *Picker, columns: usize, viewport_rows: usize) void {
    const columns_max = @max(columns, 1);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    const visible = @min(total_body, paint.bodyLimit(viewport_rows));
    const prefix = self.content.items[0..self.cursor_offset];
    const cursor_row = terminal.width.caret(prefix, columns_max).rows_before;
    if (cursor_row < self.scroll) self.scroll = cursor_row;
    if (cursor_row >= self.scroll + visible) self.scroll = cursor_row - visible + 1;
    self.scroll = @min(self.scroll, total_body - visible);
}

/// Physical rows the picker occupies: the two framing rules plus the wrapped
/// body, the body capped to its scroll limit for `viewport_rows`.
pub fn rows(self: *const Picker, columns: usize, viewport_rows: usize) usize {
    const total_body = terminal.width.rows(self.content.items, @max(columns, 1));
    return paint.framedRows(@min(total_body, paint.bodyLimit(viewport_rows)));
}

/// Stream the framed picker — the rules and the wrapped body, windowed to its
/// scroll limit for `viewport_rows` — through `placement`. Assumes `reflow` set
/// the scroll.
pub fn render(self: *const Picker, placement: *const paint.Placement, viewport_rows: usize) !void {
    const columns_max = @max(placement.columns, 1);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    const visible = @min(total_body, paint.bodyLimit(viewport_rows));
    try paint.framed(placement, &.{
        .body = self.content.items,
        .hidden_above = self.scroll,
        .shown = visible,
        .hidden_below = total_body - self.scroll - visible,
    });
}

/// Rebuild `content`: a blank padding row, the dimmed title and key hint, one
/// row per option (the selected one inverse-video, any pre-existing choice
/// tagged), then a blank padding row. Rows are `\n`-separated and carry a
/// one-space left pad; the framing rules are added by `render`.
fn compose(self: *Picker) !void {
    const gpa = self.gpa;
    self.content.clearRetainingCapacity();

    try self.content.append(gpa, '\n');
    try self.content.appendSlice(gpa, color.dim);
    try self.content.appendSlice(gpa, " ");
    try self.content.appendSlice(gpa, self.title);
    try self.content.appendSlice(gpa, color.reset);
    try self.content.append(gpa, '\n');
    try self.content.appendSlice(gpa, color.dim);
    try self.content.appendSlice(gpa, " ");
    try self.content.appendSlice(gpa, hint);
    try self.content.appendSlice(gpa, color.reset);

    for (self.options, 0..) |option, index| {
        const chosen = index == self.cursor;
        try self.content.append(gpa, '\n');
        if (chosen) self.cursor_offset = self.content.items.len;
        try self.content.appendSlice(gpa, if (chosen) color.highlight else color.dim);
        try self.content.appendSlice(gpa, if (chosen) " > " else "   ");
        try self.content.appendSlice(gpa, option);
        if (self.marked == index) try self.content.appendSlice(gpa, " (current)");
        try self.content.appendSlice(gpa, if (chosen) color.highlight_reset else color.reset);
    }

    try self.content.append(gpa, '\n');
}

fn testPicker(gpa: std.mem.Allocator, labels: []const []const u8, cursor: usize) !Picker {
    const options = try gpa.alloc([]const u8, labels.len);
    for (labels, 0..) |label, index| options[index] = try gpa.dupe(u8, label);
    var picker = try Picker.init(gpa, "Pick", options, 0);
    picker.cursor = cursor;
    try picker.compose();
    return picker;
}

test "navigation stays in bounds and the cursor tracks the selection" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 0);
    defer picker.deinit();

    try picker.moveUp();
    try std.testing.expectEqual(@as(usize, 0), picker.selectedIndex());
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.selectedIndex());
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.selectedIndex());
}

test "compose lays out the title, hint, options, and the current marker" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 1);
    defer picker.deinit();

    // Two rules, a blank, title, hint, two options, a blank: eight rows.
    try std.testing.expectEqual(@as(usize, 8), picker.rows(80, 24));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Pick") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "esc cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "alpha (current)") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, color.highlight) != null);
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

    // A 20-row viewport caps the body at six rows; with the selection on the
    // first option the window sits at the top and nothing scrolls.
    picker.reflow(80, 20);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
    try std.testing.expectEqual(@as(usize, 8), picker.rows(80, 20));

    // Walking the selection to the last option drags the window down after it.
    for (0..19) |_| try picker.moveDown();
    picker.reflow(80, 20);
    try std.testing.expectEqual(@as(usize, 17), picker.scroll);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = 80, .rows = 20 }, 4);
    const placement: paint.Placement = .{ .sink = sink, .id = 0, .columns = 80, .base = 0, .skip = 0 };
    try picker.render(&placement, 20);
    try view.render();
    const painted = out.written();
    // The selected tail option shows, the scrolled-off head does not, and the
    // top rule reports the rows hidden above the window.
    try std.testing.expect(std.mem.indexOf(u8, painted, "row19") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "row00") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "↑ 17 more") != null);
}
