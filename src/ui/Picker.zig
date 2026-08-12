//! A single-choice list for the live region: a title and a key hint above the
//! options, each option on its own row with the selected one highlighted and any
//! pre-existing choice tagged "(Current)". It renders between the same open
//! separators as the editor, so it sits in the editor's place. It owns its option
//! strings and the composed `content` buffer (freed on `deinit`) and borrows the
//! title. Navigation moves the selection. `reflow` windows a tall list to keep
//! it in view. The caller reads `cursor` and acts on the selected row.

const std = @import("std");

const paint = @import("paint.zig");
const role = @import("role.zig");
const terminal = @import("terminal");

const Picker = @This();

const hint = "↑/↓: Move · Enter: Select · Esc: Cancel";

gpa: std.mem.Allocator,
title: []const u8,
options: []const []const u8,
/// The highlighted row. Navigation moves it.
cursor: usize,
/// The row to tag "(Current)", if any: a pre-existing choice, distinct from
/// where the cursor happens to sit.
marked: ?usize,
/// The body between the separators. A selection move rebuilds it.
/// Columns-independent, so `rows` and `render` only wrap it to fit.
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

/// Re-clamp the scroll offset so the highlighted option's wrapped row stays
/// inside the visible window. Call once per repaint. Pass the same `size` whose
/// columns and rows `render` and `rows` will use, so all three agree.
pub fn reflow(self: *Picker, size: terminal.View.Size) void {
    const columns_max = paint.frameColumns(size.columns);
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

/// Physical rows the picker occupies: two separators plus the wrapped body.
/// The body stops at its scroll limit for `size.rows`.
pub fn rows(self: *const Picker, size: terminal.View.Size) usize {
    const columns_max = paint.frameColumns(size.columns);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    return paint.framedRows(@min(total_body, paint.bodyLimit(size.rows)));
}

/// Stream the picker between its separators through `placement`. Window the
/// body to its scroll limit for `viewport_rows`. Assumes `reflow` set the scroll.
pub fn render(self: *const Picker, placement: *const paint.Placement, viewport_rows: usize) !void {
    const columns_max = paint.frameColumns(placement.columns);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    const visible_rows = @min(total_body, paint.bodyLimit(viewport_rows));
    try paint.framed(placement, &.{
        .body = self.content.items,
        .body_rows = visible_rows,
        .hidden_above = self.scroll,
        .hidden_below = total_body - self.scroll - visible_rows,
        .line_roles = self.line_roles.items,
    });
}

/// Rebuild `content`: a blank padding row, the muted title and key hint, one row
/// per option (the selected one in the selection role, any pre-existing choice
/// tagged), then a blank padding row. Reverse video marks the selection with the
/// terminal foreground and background. Rows are `\n`-separated and carry a
/// one-space left pad. The trusted role lives separately in `line_roles`.
fn compose(self: *Picker) !void {
    self.content.clearRetainingCapacity();
    self.line_roles.clearRetainingCapacity();
    // Reset with the buffers it indexes into: a failure below must not leave the
    // offset past the shorter rebuilt content for `reflow` to slice.
    self.cursor_offset = 0;

    try self.startLine(null);
    try self.startLine(.muted);
    try self.content.append(self.gpa, ' ');
    try self.appendText(self.title, .muted);
    try self.startLine(.muted);
    try self.content.append(self.gpa, ' ');
    try self.appendText(hint, .muted);

    for (self.options, 0..) |option, index| {
        const chosen = index == self.cursor;
        const name: role.Name = if (chosen) .selection else .muted;
        try self.startLine(name);
        if (chosen) self.cursor_offset = self.content.items.len;
        try self.content.appendSlice(self.gpa, if (chosen) " > " else "   ");
        try self.appendText(option, name);
        if (self.marked == index) try self.content.appendSlice(self.gpa, " (Current)");
    }

    try self.startLine(null);
}

fn startLine(self: *Picker, maybe_role: ?role.Name) !void {
    if (self.line_roles.items.len > 0) try self.content.append(self.gpa, '\n');
    try self.line_roles.append(self.gpa, maybe_role);
}

/// Append text to the current logical line and extend the role metadata when
/// untrusted text itself contains a row break.
fn appendText(self: *Picker, text: []const u8, name: role.Name) !void {
    var pieces = std.mem.splitScalar(u8, text, '\n');
    try self.content.appendSlice(self.gpa, pieces.next().?);
    while (pieces.next()) |piece| {
        try self.startLine(name);
        try self.content.appendSlice(self.gpa, piece);
    }
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
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.cursor);
}

test "compose lays out the title, hint, options, and the current marker" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 1);
    defer picker.deinit();

    // Two separators, a blank, title, hint, two options, and a blank make eight rows.
    try std.testing.expectEqual(@as(usize, 8), picker.rows(.{ .columns = 80, .rows = 24 }));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Pick") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Esc: Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "alpha (Current)") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, picker.content.items, 0x1b) == null);
    try std.testing.expectEqual(role.Name.selection, picker.line_roles.items[4].?);
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

    // A 20-row viewport caps the body at six rows. With the selection on the
    // first option the window sits at the top and nothing scrolls.
    picker.reflow(.{ .columns = 80, .rows = 20 });
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
    try std.testing.expectEqual(@as(usize, 8), picker.rows(.{ .columns = 80, .rows = 20 }));

    // A walk of the selection to the last option drags the window down after it.
    for (0..19) |_| try picker.moveDown();
    picker.reflow(.{ .columns = 80, .rows = 20 });
    try std.testing.expectEqual(@as(usize, 17), picker.scroll);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = 80, .rows = 20 }, 4);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 80,
        .base = 0,
        .skip = 0,
    };
    try picker.render(&placement, 20);
    try view.render();
    const painted = out.written();
    // The selected tail option shows in the selection role, the scrolled-off
    // head does not, and the top separator reports the rows hidden above the
    // window.
    const selected = comptime role.sequence(.selection) ++ " > row19\x1b[0m";
    try std.testing.expect(std.mem.indexOf(u8, painted, "row19") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, selected) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "row00") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "↑ Hidden: 17") != null);
}
