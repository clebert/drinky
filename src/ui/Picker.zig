//! A single-choice list for the live region: a title and a key hint above the
//! options, each option on its own row with the selected one highlighted and any
//! pre-existing choice tagged "(current)". It renders in the same framed input
//! area as the editor, so it sits where the editor would. It owns its option
//! strings and the composed `content` buffer (freed on `deinit`) and borrows the
//! title. A pure view otherwise — navigation moves the selection; the caller
//! reads `choice` and acts on it.

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

/// The currently highlighted option.
pub fn choice(self: *const Picker) []const u8 {
    return self.options[self.cursor];
}

/// Physical rows the picker occupies: the two framing rules plus the body.
pub fn rows(self: *const Picker, columns: usize) usize {
    return paint.framedRows(terminal.width.rows(self.content.items, @max(columns, 1)));
}

/// Stream the framed picker — the rules and the wrapped body — through `placement`.
pub fn render(self: *const Picker, placement: *const paint.Placement) !void {
    try paint.framed(placement, &.{ .body = self.content.items });
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

test "navigation stays in bounds and choice tracks the selection" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 0);
    defer picker.deinit();

    try picker.moveUp();
    try std.testing.expectEqualStrings("alpha", picker.choice());
    try picker.moveDown();
    try std.testing.expectEqualStrings("beta", picker.choice());
    try picker.moveDown();
    try std.testing.expectEqualStrings("beta", picker.choice());
}

test "compose lays out the title, hint, options, and the current marker" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 1);
    defer picker.deinit();

    // Two rules, a blank, title, hint, two options, a blank: eight rows.
    try std.testing.expectEqual(@as(usize, 8), picker.rows(80));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Pick") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "esc cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "alpha (current)") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, color.highlight) != null);
}
