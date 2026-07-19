//! What a tool handler returns: the text that becomes the matching
//! `tool_result` block, and whether it reports failure.

const std = @import("std");

const Result = @This();

/// Owned by the caller's allocator.
content: []const u8,
is_error: bool,

pub const Status = enum { ok, err };

/// Build a result whose content is `format` rendered with `args`.
pub fn report(
    gpa: std.mem.Allocator,
    status: Status,
    comptime format: []const u8,
    args: anytype,
) !Result {
    return .{ .content = try std.fmt.allocPrint(gpa, format, args), .is_error = status == .err };
}

/// Report an I/O failure as `cannot <verb> <path>: <error>` — except
/// cancellation, which propagates so the aborted turn stops at once.
pub fn cannot(
    gpa: std.mem.Allocator,
    err: anyerror,
    comptime verb: []const u8,
    path: []const u8,
) !Result {
    if (err == error.Canceled) return error.Canceled;
    return report(gpa, .err, "cannot " ++ verb ++ " {s}: {s}", .{ path, @errorName(err) });
}
