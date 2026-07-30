//! What a tool handler returns: the `content` the model reads as the
//! `tool_result` block, an optional one-line `summary` shown in the transcript
//! box in place of that content's first line, and whether it reports failure.

const std = @import("std");

const Result = @This();

/// Owned by the caller's allocator until `takeContent` transfers it.
content: []const u8,
/// A one-line stat for the transcript box — lines read, matches found — shown in
/// place of the content's first line; null shows that first line instead. Owned
/// by the caller's allocator.
summary: ?[]const u8 = null,
is_error: bool,
content_taken: bool = false,

pub const Status = enum { ok, err };

/// Free every allocation the result still owns.
pub fn deinit(self: *const Result, gpa: std.mem.Allocator) void {
    if (!self.content_taken) gpa.free(self.content);
    if (self.summary) |summary| gpa.free(summary);
}

/// Transfer content ownership while leaving every presentation-only allocation
/// with the result for `deinit`.
pub fn takeContent(self: *Result) []const u8 {
    std.debug.assert(!self.content_taken);
    self.content_taken = true;
    return self.content;
}

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

test "takeContent transfers only content ownership" {
    const gpa = std.testing.allocator;
    const content = try gpa.dupe(u8, "content");
    const summary = gpa.dupe(u8, "summary") catch |err| {
        gpa.free(content);
        return err;
    };
    var result: Result = .{ .content = content, .summary = summary, .is_error = false };

    const taken = result.takeContent();
    defer gpa.free(taken);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("content", taken);
}
