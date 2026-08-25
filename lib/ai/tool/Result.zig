//! What a tool handler returns. The model reads the `content` as the
//! `tool_result` block. The transcript box shows the optional one-line
//! `summary` below the call row, in the shape that summary names. A flag reports
//! failure.

const std = @import("std");

const Result = @This();

/// The caller's allocator owns the content until `takeContent` transfers it.
content: []const u8,
/// The second line of the transcript box. Null leaves the box with its call row
/// alone. The tool decides this line, and Drinky never derives it from the
/// content.
summary: ?Summary = null,
is_error: bool,
content_taken: bool = false,

pub const Status = enum { ok, err };

/// The line below the call row: its text, and the shape that decides how the box
/// shows it. The two travel together, so no line can reach the box in a shape
/// that its text does not read in. The caller's allocator owns the text.
pub const Summary = struct {
    text: []const u8,
    kind: Kind = .measures,

    /// The two shapes a summary line can take.
    ///
    /// `measures` is a line of keys and values, such as `Exit code: 1`. It names
    /// its own state, so the box adds no prefix and cuts the line at the window,
    /// where the keys in front carry what identifies it.
    ///
    /// `sentence` is a whole sentence that ends on the instruction the user
    /// needs. The box wraps it and marks it with `Error: `, so no cut takes the
    /// half that says what to do.
    pub const Kind = enum { measures, sentence };
};

/// Free every allocation the result still owns.
pub fn deinit(self: *const Result, gpa: std.mem.Allocator) void {
    if (!self.content_taken) gpa.free(self.content);
    if (self.summary) |summary| gpa.free(summary.text);
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
    const failed = status == .err;
    const content = try std.fmt.allocPrint(gpa, format, args);
    errdefer gpa.free(content);
    // A success states no line of its own. A tool that adds one assigns the
    // whole summary, so it names the shape of that line in the same statement.
    const summary: ?Summary = if (failed)
        .{ .text = try gpa.dupe(u8, content), .kind = .sentence }
    else
        null;
    return .{ .content = content, .summary = summary, .is_error = failed };
}

/// Report an I/O failure as a complete sentence with the operation, path,
/// and error. Cancellation propagates so the aborted turn stops at once. An
/// empty path prints as `an empty path`, so the sentence keeps no invisible
/// hole.
pub fn cannot(
    gpa: std.mem.Allocator,
    err: anyerror,
    comptime verb: []const u8,
    path: []const u8,
) !Result {
    if (err == error.Canceled) return error.Canceled;
    const shown = if (path.len == 0) "an empty path" else path;
    return report(
        gpa,
        .err,
        "Drinky could not " ++ verb ++ " {s} because of error {s}.",
        .{ shown, @errorName(err) },
    );
}

// The box shows the summary alone, so a failure carries its sentence there. A
// success states its own line, or none at all.
test "a failure reports its sentence as the box line and a success does not" {
    const gpa = std.testing.allocator;
    const failure = try report(gpa, .err, "Drinky could not read {s}.", .{"a.zig"});
    defer failure.deinit(gpa);
    try std.testing.expect(failure.is_error);
    try std.testing.expectEqualStrings("Drinky could not read a.zig.", failure.summary.?.text);
    try std.testing.expectEqual(Summary.Kind.sentence, failure.summary.?.kind);
    // The two strings are separate allocations, so `deinit` frees both.
    try std.testing.expect(failure.content.ptr != failure.summary.?.text.ptr);

    const success = try report(gpa, .ok, "Drinky wrote {s}.", .{"a.zig"});
    defer success.deinit(gpa);
    try std.testing.expect(!success.is_error);
    try std.testing.expectEqual(@as(?Summary, null), success.summary);
}

// An empty path leaves an invisible hole in the sentence, so the report names
// it instead.
test "cannot names an empty path" {
    const gpa = std.testing.allocator;
    const result = try cannot(gpa, error.FileNotFound, "read", "");
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings(
        "Drinky could not read an empty path because of error FileNotFound.",
        result.content,
    );
}

test "takeContent transfers only content ownership" {
    const gpa = std.testing.allocator;
    const content = try gpa.dupe(u8, "content");
    const summary = gpa.dupe(u8, "summary") catch |err| {
        gpa.free(content);
        return err;
    };
    var result: Result = .{
        .content = content,
        .summary = .{ .text = summary },
        .is_error = false,
    };

    const taken = result.takeContent();
    defer gpa.free(taken);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("content", taken);
}
