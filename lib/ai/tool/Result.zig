const std = @import("std");

const Result = @This();

content: []const u8,
summary: ?Summary = null,
is_error: bool,
content_taken: bool = false,

pub const Status = enum { ok, err };

pub const Summary = struct {
    text: []const u8,
    kind: Kind = .measures,

    pub const Kind = enum { measures, sentence };
};

pub fn deinit(self: *const Result, gpa: std.mem.Allocator) void {
    if (!self.content_taken) gpa.free(self.content);
    if (self.summary) |summary| gpa.free(summary.text);
}

pub fn takeContent(self: *Result) []const u8 {
    std.debug.assert(!self.content_taken);
    self.content_taken = true;
    return self.content;
}

pub fn report(
    gpa: std.mem.Allocator,
    status: Status,
    comptime format: []const u8,
    args: anytype,
) !Result {
    const failed = status == .err;
    const content = try std.fmt.allocPrint(gpa, format, args);
    errdefer gpa.free(content);
    const summary: ?Summary = if (failed)
        .{ .text = try gpa.dupe(u8, content), .kind = .sentence }
    else
        null;
    return .{ .content = content, .summary = summary, .is_error = failed };
}

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

test "a failure reports its sentence as the box line and a success does not" {
    const gpa = std.testing.allocator;
    const failure = try report(gpa, .err, "Drinky could not read {s}.", .{"a.zig"});
    defer failure.deinit(gpa);
    try std.testing.expect(failure.is_error);
    try std.testing.expectEqualStrings("Drinky could not read a.zig.", failure.summary.?.text);
    try std.testing.expectEqual(Summary.Kind.sentence, failure.summary.?.kind);
    try std.testing.expect(failure.content.ptr != failure.summary.?.text.ptr);

    const success = try report(gpa, .ok, "Drinky wrote {s}.", .{"a.zig"});
    defer success.deinit(gpa);
    try std.testing.expect(!success.is_error);
    try std.testing.expectEqual(@as(?Summary, null), success.summary);
}

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
