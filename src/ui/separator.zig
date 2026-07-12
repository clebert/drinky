//! The purple horizontal rule that frames the input area. Shared by the editor
//! and the picker so both sit inside the same border.

const std = @import("std");

const color = @import("color.zig");

const cell = "─";

/// Append a full-width rule (color, `columns` cells, colour reset) into `buffer`.
pub fn rule(buffer: *std.ArrayList(u8), gpa: std.mem.Allocator, columns: usize) !void {
    try buffer.appendSlice(gpa, color.rule);
    for (0..columns) |_| try buffer.appendSlice(gpa, cell);
    try buffer.appendSlice(gpa, color.rule_reset);
}
