//! Shared display formatting for the values that Drinky shows to the user. A value
//! that two callers report must read the same in both places.

const std = @import("std");

const project = @import("project.zig");

/// A compact byte size: bytes under 1 KB, else KB or MB to one decimal. Integer
/// math throughout. `buffer` needs only a dozen bytes, because the scale ends at
/// MB and the tenths scaling of a bounded file cannot overflow.
pub fn bytes(buffer: []u8, count: usize) []const u8 {
    if (count < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{count}) catch unreachable;
    const tenths_kb = @divFloor(count * 10, 1024);
    if (tenths_kb < 10 * 1024) return std.fmt.bufPrint(buffer, "{d}.{d} KB", .{
        @divFloor(tenths_kb, 10),
        @mod(tenths_kb, 10),
    }) catch unreachable;
    const tenths_mb = @divFloor(count * 10, 1024 * 1024);
    return std.fmt.bufPrint(buffer, "{d}.{d} MB", .{
        @divFloor(tenths_mb, 10),
        @mod(tenths_mb, 10),
    }) catch unreachable;
}

/// The two roots a shown path is measured against. Either can be empty when the
/// host does not know it, which leaves every path as it is.
pub const Roots = struct {
    working_directory: []const u8 = "",
    home_directory: []const u8 = "",
};

/// `path` as the interface shows it: relative to the working directory when it
/// sits below it, else with the home directory as `~`, else the path itself. The
/// result is owned.
///
/// A path under neither root keeps its whole absolute form. That is the path
/// worth a second look, so the short form never hides the reach the user wants
/// to see.
pub fn path(gpa: std.mem.Allocator, target: []const u8, roots: *const Roots) ![]u8 {
    if (relativeTo(&.{ .boundary = roots.working_directory, .target = target })) |relative|
        return gpa.dupe(u8, relative);
    if (relativeTo(&.{ .boundary = roots.home_directory, .target = target })) |relative|
        return std.fmt.allocPrint(gpa, "~/{s}", .{relative});
    return gpa.dupe(u8, target);
}

/// The target without its boundary prefix, or null when the boundary is empty,
/// does not contain the target, or is the target itself. A caller that must know
/// which root matched asks here rather than reading the result of `path`, whose
/// output cannot say whether a leading `~/` came from home or from the target.
///
/// The two paths take the same options struct `project.contains` takes, because
/// they are the same pair and a swap of them compiles.
pub fn relativeTo(options: *const project.ContainsOptions) ?[]const u8 {
    const boundary = options.boundary;
    if (boundary.len == 0) return null;
    if (!project.contains(options)) return null;
    const separated = std.fs.path.isSep(boundary[boundary.len - 1]);
    const cut = if (separated) boundary.len else boundary.len + 1;
    if (cut >= options.target.len) return null;
    return options.target[cut..];
}

test path {
    const gpa = std.testing.allocator;
    const roots: Roots = .{ .working_directory = "/home/you/work", .home_directory = "/home/you" };
    const cases = [_]struct { target: []const u8, expected: []const u8 }{
        // Below the working directory: the part that names the file is enough.
        .{ .target = "/home/you/work/src/App.zig", .expected = "src/App.zig" },
        // Below home but outside the work tree: `~` stands in for home.
        .{ .target = "/home/you/.drinky/config.json", .expected = "~/.drinky/config.json" },
        // Below neither root: the whole path stays, because that is the reach
        // the user must be able to see.
        .{ .target = "/etc/hosts", .expected = "/etc/hosts" },
        // A relative path names no root to measure against, so it stands as it is.
        .{ .target = "src/App.zig", .expected = "src/App.zig" },
    };
    for (cases) |case| {
        const shown = try path(gpa, case.target, &roots);
        defer gpa.free(shown);
        try std.testing.expectEqualStrings(case.expected, shown);
    }
    // With no roots known, every path stands as it is.
    const bare = try path(gpa, "/home/you/work/src/App.zig", &.{});
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("/home/you/work/src/App.zig", bare);
}

/// The lines `text` holds. A final line break closes the last line rather than
/// opening an empty one, so a file of three lines counts three whether or not it
/// ends with a break. Every tool that reports a line count uses this rule, so two
/// tools cannot report a different count for the same bytes.
pub fn lines(text: []const u8) usize {
    if (text.len == 0) return 0;
    const breaks = std.mem.count(u8, text, "\n");
    return if (text[text.len - 1] == '\n') breaks else breaks + 1;
}

test lines {
    try std.testing.expectEqual(@as(usize, 0), lines(""));
    try std.testing.expectEqual(@as(usize, 1), lines("a"));
    try std.testing.expectEqual(@as(usize, 1), lines("a\n"));
    try std.testing.expectEqual(@as(usize, 3), lines("a\nb\nc"));
    try std.testing.expectEqual(@as(usize, 3), lines("a\nb\nc\n"));
    // A blank line is a line: the break before it closed the line above.
    try std.testing.expectEqual(@as(usize, 2), lines("a\n\n"));
}

/// A compact wall-clock span: whole milliseconds below a second, seconds to one
/// decimal below a minute, else whole minutes and seconds. Integer math
/// throughout. `buffer` needs two dozen bytes, because a span of many minutes
/// prints every digit of its minute count. A negative span reads as zero, so a
/// clock that steps backward cannot print a span that runs the wrong way.
///
/// Every span in the interface takes this one shape, so no two spans read in
/// two vocabularies. Each tier measures in a unit that its spans fill: a search
/// that ends in 42 milliseconds states that span, rather than the `0.0s` that
/// tenths alone can offer it.
pub fn duration(buffer: []u8, milliseconds: i64) []const u8 {
    const total: u64 = @intCast(@max(milliseconds, 0));
    if (total < std.time.ms_per_s)
        return std.fmt.bufPrint(buffer, "{d}ms", .{total}) catch unreachable;
    if (total < std.time.ms_per_min) {
        const tenths = @divFloor(total, 100);
        return std.fmt.bufPrint(buffer, "{d}.{d}s", .{
            @divFloor(tenths, 10),
            @mod(tenths, 10),
        }) catch unreachable;
    }
    const seconds = @divFloor(total, std.time.ms_per_s);
    return std.fmt.bufPrint(buffer, "{d}m {d}s", .{
        @divFloor(seconds, std.time.s_per_min),
        @mod(seconds, std.time.s_per_min),
    }) catch unreachable;
}

test duration {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0ms", duration(&buffer, 0));
    try std.testing.expectEqualStrings("42ms", duration(&buffer, 42));
    try std.testing.expectEqualStrings("450ms", duration(&buffer, 450));
    // Each tier ends where the next one carries the same digits, so no span
    // reads in two shapes and no shape loses a digit at its edge.
    try std.testing.expectEqualStrings("999ms", duration(&buffer, 999));
    try std.testing.expectEqualStrings("1.0s", duration(&buffer, 1_000));
    try std.testing.expectEqualStrings("41.6s", duration(&buffer, 41_600));
    try std.testing.expectEqualStrings("59.9s", duration(&buffer, 59_999));
    try std.testing.expectEqualStrings("1m 0s", duration(&buffer, 60_000));
    try std.testing.expectEqualStrings("2m 5s", duration(&buffer, 125_400));
    // A backward clock step reads as no time at all, never as a negative span.
    try std.testing.expectEqualStrings("0ms", duration(&buffer, -1));
}

test bytes {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", bytes(&buffer, 0));
    try std.testing.expectEqualStrings("1023 B", bytes(&buffer, 1023));
    try std.testing.expectEqualStrings("1.0 KB", bytes(&buffer, 1024));
    try std.testing.expectEqualStrings("3.1 KB", bytes(&buffer, 3200));
    try std.testing.expectEqualStrings("1.0 MB", bytes(&buffer, 1024 * 1024));
}
