const std = @import("std");

const core = @import("core");

pub fn sentence(
    gpa: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!core.Tool.Output {
    return .{ .content = try std.fmt.allocPrint(gpa, format, args) };
}

pub fn failure(
    gpa: std.mem.Allocator,
    reason: core.Tool.Condition,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!core.Tool.Output {
    return .{
        .content = try std.fmt.allocPrint(gpa, format, args),
        .conditions = .initOne(reason),
    };
}

pub fn cannot(
    gpa: std.mem.Allocator,
    err: anyerror,
    comptime verb: []const u8,
    path: []const u8,
) error{ Canceled, OutOfMemory }!core.Tool.Output {
    if (err == error.Canceled) return error.Canceled;
    const shown = if (path.len == 0) "an empty path" else path;
    return failure(
        gpa,
        condition(err),
        "Drinky could not " ++ verb ++ " {s} because of error {s}.",
        .{ shown, @errorName(err) },
    );
}

fn condition(err: anyerror) core.Tool.Condition {
    return switch (err) {
        error.FileNotFound => .path_missing,
        error.IsDir, error.NotDir => .path_not_file,
        else => .failed,
    };
}

test "a failure carries its sentence and one failing condition" {
    const gpa = std.testing.allocator;
    const failed = try failure(gpa, .path_not_text, "Drinky cannot read {s}.", .{"a.bin"});
    defer failed.deinit(gpa);
    try std.testing.expect(failed.hasFailure());
    try std.testing.expectEqualStrings("Drinky cannot read a.bin.", failed.content);
    try std.testing.expect(failed.conditions.eql(.initOne(.path_not_text)));
    try std.testing.expectEqual(@as(usize, 0), failed.measures.count());

    const noted = try sentence(gpa, "Drinky wrote {s}.", .{"a.zig"});
    defer noted.deinit(gpa);
    try std.testing.expect(!noted.hasFailure());
    try std.testing.expectEqual(@as(usize, 0), noted.conditions.count());
}

test "cannot names an empty path and maps the error to a condition" {
    const gpa = std.testing.allocator;
    const missing = try cannot(gpa, error.FileNotFound, "read", "");
    defer missing.deinit(gpa);
    try std.testing.expectEqualStrings(
        "Drinky could not read an empty path because of error FileNotFound.",
        missing.content,
    );
    try std.testing.expect(missing.conditions.eql(.initOne(.path_missing)));

    const directory = try cannot(gpa, error.IsDir, "read", "src");
    defer directory.deinit(gpa);
    try std.testing.expect(directory.conditions.eql(.initOne(.path_not_file)));

    const denied = try cannot(gpa, error.AccessDenied, "write", "a.zig");
    defer denied.deinit(gpa);
    try std.testing.expect(denied.conditions.eql(.initOne(.failed)));

    try std.testing.expectError(error.Canceled, cannot(gpa, error.Canceled, "read", "a.zig"));
}
