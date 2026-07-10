//! A single-choice list for the live region: a title and a key hint above the
//! options, each option on its own row with the selected one highlighted. It
//! owns its option strings (freed on `deinit`) and borrows the title. A pure
//! view otherwise — navigation moves the selection; the caller reads `choice`
//! and acts on it.

const std = @import("std");

const width = @import("width.zig");

const Picker = @This();

const dim = "\x1b[2m";
const reset = "\x1b[0m";
const highlight = "\x1b[7m";
const highlight_reset = "\x1b[27m";
const hint = "↑/↓ move · enter select · ctrl-c cancel";

gpa: std.mem.Allocator,
title: []const u8,
options: []const []const u8,
/// The highlighted row, moved by navigation.
cursor: usize,
/// The row to tag "(current)", if any — a pre-existing choice, distinct from
/// where the cursor happens to sit.
marked: ?usize,

pub fn deinit(self: *Picker) void {
    for (self.options) |option| self.gpa.free(option);
    self.gpa.free(self.options);
}

pub fn moveUp(self: *Picker) void {
    if (self.cursor > 0) self.cursor -= 1;
}

pub fn moveDown(self: *Picker) void {
    if (self.cursor + 1 < self.options.len) self.cursor += 1;
}

/// The currently highlighted option.
pub fn choice(self: *const Picker) []const u8 {
    return self.options[self.cursor];
}

/// Build the wrapped display lines into `buffer`/`lines` (both cleared first).
/// `lines` borrows from `buffer`, so keep `buffer` alive while using them.
pub fn render(
    self: *const Picker,
    columns: usize,
    buffer: *std.ArrayList(u8),
    lines: *std.ArrayList([]const u8),
) !void {
    buffer.clearRetainingCapacity();
    lines.clearRetainingCapacity();
    const gpa = self.gpa;

    try buffer.appendSlice(gpa, dim);
    try buffer.appendSlice(gpa, self.title);
    try buffer.appendSlice(gpa, reset);
    try buffer.appendSlice(gpa, "\n");
    try buffer.appendSlice(gpa, dim);
    try buffer.appendSlice(gpa, hint);
    try buffer.appendSlice(gpa, reset);

    for (self.options, 0..) |option, index| {
        const chosen = index == self.cursor;
        try buffer.appendSlice(gpa, "\n");
        try buffer.appendSlice(gpa, if (chosen) highlight else dim);
        try buffer.appendSlice(gpa, if (chosen) "> " else "  ");
        try buffer.appendSlice(gpa, option);
        if (self.marked == index) try buffer.appendSlice(gpa, " (current)");
        try buffer.appendSlice(gpa, if (chosen) highlight_reset else reset);
    }

    const columns_min = 1;
    try width.wrap(buffer.items, @max(columns, columns_min), lines, gpa);
}

fn testPicker(gpa: std.mem.Allocator, labels: []const []const u8, cursor: usize) !Picker {
    const options = try gpa.alloc([]const u8, labels.len);
    for (labels, 0..) |label, index| options[index] = try gpa.dupe(u8, label);
    return .{ .gpa = gpa, .title = "Pick", .options = options, .cursor = cursor, .marked = 0 };
}

test "navigation stays in bounds and choice tracks the selection" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 0);
    defer picker.deinit();

    picker.moveUp();
    try std.testing.expectEqualStrings("alpha", picker.choice());
    picker.moveDown();
    try std.testing.expectEqualStrings("beta", picker.choice());
    picker.moveDown();
    try std.testing.expectEqualStrings("beta", picker.choice());
}

test "render shows the title, hint, options, and the current marker" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 1);
    defer picker.deinit();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    try picker.render(80, &buffer, &lines);

    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Pick") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "ctrl-c cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "alpha (current)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, highlight) != null);
}
