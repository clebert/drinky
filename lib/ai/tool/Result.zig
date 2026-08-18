//! What a tool handler returns. The model reads the `content` as the
//! `tool_result` block. The transcript box shows the optional one-line
//! `summary` below the call row. A flag reports failure.

const std = @import("std");

const Result = @This();

/// The caller's allocator owns the content until `takeContent` transfers it.
content: []const u8,
/// The second line of the transcript box: a one-line stat — lines read, matches
/// found — or the sentence of a failure. Null leaves the box with its call row
/// alone. The tool decides this line, and Pith never derives it from the
/// content. The caller's allocator owns it.
summary: ?[]const u8 = null,
is_error: bool,
content_taken: bool = false,

pub const Status = enum { ok, err };

/// Free every allocation the result still owns.
pub fn deinit(self: *const Result, gpa: std.mem.Allocator) void {
    if (!self.content_taken) gpa.free(self.content);
    if (self.summary) |summary| gpa.free(summary);
}

/// Transfer content ownership. Every presentation-only allocation stays with
/// the result for `deinit`.
pub fn takeContent(self: *Result) []const u8 {
    std.debug.assert(!self.content_taken);
    self.content_taken = true;
    return self.content;
}

/// Build a result whose content is `format` rendered with `args`.
///
/// A failure states one sentence, and that sentence is what the box must show,
/// so an error result carries it as its own summary. A handler that sets a
/// summary of its own must build the result with `.ok`. An assignment over the
/// sentence of a failure leaks it.
pub fn report(
    gpa: std.mem.Allocator,
    status: Status,
    comptime format: []const u8,
    args: anytype,
) !Result {
    const content = try std.fmt.allocPrint(gpa, format, args);
    errdefer gpa.free(content);
    const summary = if (status == .err) try gpa.dupe(u8, content) else null;
    return .{ .content = content, .summary = summary, .is_error = status == .err };
}

/// Report an I/O failure as a complete sentence with the operation, path,
/// and error. Cancellation propagates so the aborted turn stops at once.
pub fn cannot(
    gpa: std.mem.Allocator,
    err: anyerror,
    comptime verb: []const u8,
    path: []const u8,
) !Result {
    if (err == error.Canceled) return error.Canceled;
    return report(
        gpa,
        .err,
        "Pith could not " ++ verb ++ " {s} because of error {s}.",
        .{ path, @errorName(err) },
    );
}

// The box shows the summary alone, so a failure carries its sentence there. A
// success states its own line, or none at all.
test "a failure reports its sentence as the box line and a success does not" {
    const gpa = std.testing.allocator;
    const failure = try report(gpa, .err, "Pith could not read {s}.", .{"a.zig"});
    defer failure.deinit(gpa);
    try std.testing.expect(failure.is_error);
    try std.testing.expectEqualStrings("Pith could not read a.zig.", failure.summary.?);
    // The two strings are separate allocations, so `deinit` frees both.
    try std.testing.expect(failure.content.ptr != failure.summary.?.ptr);

    const success = try report(gpa, .ok, "Pith wrote {s}.", .{"a.zig"});
    defer success.deinit(gpa);
    try std.testing.expect(!success.is_error);
    try std.testing.expectEqual(@as(?[]const u8, null), success.summary);
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
