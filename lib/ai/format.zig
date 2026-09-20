const std = @import("std");

const project = @import("project.zig");

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

pub fn pluralSuffix(count: u64) []const u8 {
    return if (count == 1) "" else "s";
}

test pluralSuffix {
    try std.testing.expectEqualStrings("s", pluralSuffix(0));
    try std.testing.expectEqualStrings("", pluralSuffix(1));
    try std.testing.expectEqualStrings("s", pluralSuffix(2));
}

pub const Roots = struct {
    working_directory: []const u8 = "",
    home_directory: []const u8 = "",
};

pub fn path(gpa: std.mem.Allocator, target: []const u8, roots: *const Roots) ![]u8 {
    if (relativeTo(&.{ .boundary = roots.working_directory, .target = target })) |relative|
        return gpa.dupe(u8, relative);
    if (relativeTo(&.{ .boundary = roots.home_directory, .target = target })) |relative|
        return std.fmt.allocPrint(gpa, "~/{s}", .{relative});
    return gpa.dupe(u8, target);
}

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
        .{ .target = "/home/you/work/src/App.zig", .expected = "src/App.zig" },
        .{ .target = "/home/you/.drinky/config.json", .expected = "~/.drinky/config.json" },
        .{ .target = "/etc/hosts", .expected = "/etc/hosts" },
        .{ .target = "src/App.zig", .expected = "src/App.zig" },
    };
    for (cases) |case| {
        const shown = try path(gpa, case.target, &roots);
        defer gpa.free(shown);
        try std.testing.expectEqualStrings(case.expected, shown);
    }
    const bare = try path(gpa, "/home/you/work/src/App.zig", &.{});
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("/home/you/work/src/App.zig", bare);
}

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
    try std.testing.expectEqual(@as(usize, 2), lines("a\n\n"));
}

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
    return durationSeconds(buffer, milliseconds, .down);
}

pub const Rounding = enum {
    down,
    up,
};

pub fn durationSeconds(buffer: []u8, milliseconds: i64, rounding: Rounding) []const u8 {
    const total: u64 = @intCast(@max(milliseconds, 0));
    const seconds = switch (rounding) {
        .down => @divFloor(total, std.time.ms_per_s),
        .up => std.math.divCeil(u64, total, std.time.ms_per_s) catch unreachable,
    };
    if (seconds < std.time.s_per_min)
        return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
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
    try std.testing.expectEqualStrings("999ms", duration(&buffer, 999));
    try std.testing.expectEqualStrings("1.0s", duration(&buffer, 1_000));
    try std.testing.expectEqualStrings("41.6s", duration(&buffer, 41_600));
    try std.testing.expectEqualStrings("59.9s", duration(&buffer, 59_999));
    try std.testing.expectEqualStrings("1m 0s", duration(&buffer, 60_000));
    try std.testing.expectEqualStrings("2m 5s", duration(&buffer, 125_400));
    try std.testing.expectEqualStrings("0ms", duration(&buffer, -1));
}

test durationSeconds {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0s", durationSeconds(&buffer, 0, .down));
    try std.testing.expectEqualStrings("0s", durationSeconds(&buffer, 999, .down));
    try std.testing.expectEqualStrings("1s", durationSeconds(&buffer, 1_000, .down));
    try std.testing.expectEqualStrings("30s", durationSeconds(&buffer, 30_400, .down));
    try std.testing.expectEqualStrings("59s", durationSeconds(&buffer, 59_999, .down));
    try std.testing.expectEqualStrings("1m 0s", durationSeconds(&buffer, 60_000, .down));
    try std.testing.expectEqualStrings("2m 5s", durationSeconds(&buffer, 125_400, .down));
    try std.testing.expectEqualStrings("60m 0s", durationSeconds(&buffer, 3_600_000, .down));
    try std.testing.expectEqualStrings("0s", durationSeconds(&buffer, -1, .down));

    try std.testing.expectEqualStrings("0s", durationSeconds(&buffer, 0, .up));
    try std.testing.expectEqualStrings("1s", durationSeconds(&buffer, 1, .up));
    try std.testing.expectEqualStrings("2s", durationSeconds(&buffer, 1_500, .up));
    try std.testing.expectEqualStrings("30s", durationSeconds(&buffer, 30_000, .up));
    try std.testing.expectEqualStrings("1m 0s", durationSeconds(&buffer, 59_001, .up));
    try std.testing.expectEqualStrings("1m 31s", durationSeconds(&buffer, 90_500, .up));
    try std.testing.expectEqualStrings("0s", durationSeconds(&buffer, -1, .up));
}

test bytes {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", bytes(&buffer, 0));
    try std.testing.expectEqualStrings("1023 B", bytes(&buffer, 1023));
    try std.testing.expectEqualStrings("1.0 KB", bytes(&buffer, 1024));
    try std.testing.expectEqualStrings("3.1 KB", bytes(&buffer, 3200));
    try std.testing.expectEqualStrings("1.0 MB", bytes(&buffer, 1024 * 1024));
}
