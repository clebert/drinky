//! What a tool handler returns: the text that becomes the matching
//! `tool_result` block, and whether it reports failure.

const std = @import("std");

const Result = @This();

/// Owned by the caller's allocator.
content: []const u8,
is_error: bool,

pub const Outcome = enum { ok, err };

/// Build a result whose content is `format` rendered with `args`.
pub fn report(gpa: std.mem.Allocator, outcome: Outcome, comptime format: []const u8, args: anytype) !Result {
    return .{ .content = try std.fmt.allocPrint(gpa, format, args), .is_error = outcome == .err };
}
