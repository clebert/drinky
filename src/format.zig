const std = @import("std");

const tools = @import("tools");

pub const Roots = struct {
    working_directory: []const u8 = "",
    home_directory: []const u8 = "",
};

const Rounding = enum {
    down,
    up,
};

pub fn bytes(buffer: []u8, count: usize) []const u8 {
    if (count < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{count}) catch unreachable;
    const tenths_kib = @divFloor(count * 10, 1024);
    if (tenths_kib < 10 * 1024) return std.fmt.bufPrint(buffer, "{d}.{d} KiB", .{
        @divFloor(tenths_kib, 10),
        @mod(tenths_kib, 10),
    }) catch unreachable;
    const tenths_mib = @divFloor(count * 10, 1024 * 1024);
    return std.fmt.bufPrint(buffer, "{d}.{d} MiB", .{
        @divFloor(tenths_mib, 10),
        @mod(tenths_mib, 10),
    }) catch unreachable;
}

pub fn path(
    gpa: std.mem.Allocator,
    target: []const u8,
    roots: *const Roots,
) error{OutOfMemory}![]u8 {
    const working = roots.working_directory;
    const home = roots.home_directory;
    if (tools.format.relativeTo(&.{ .boundary = working, .target = target })) |relative|
        return gpa.dupe(u8, relative);
    if (tools.format.relativeTo(&.{ .boundary = home, .target = target })) |relative|
        return std.fmt.allocPrint(gpa, "~/{s}", .{relative});
    if (home.len > 0 and tools.format.contains(&.{ .boundary = home, .target = target }))
        return gpa.dupe(u8, "~");
    return gpa.dupe(u8, target);
}

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

test path {
    const gpa = std.testing.allocator;
    const roots: Roots = .{ .working_directory = "/home/you/work", .home_directory = "/home/you" };
    const cases = [_]struct { target: []const u8, expected: []const u8 }{
        .{ .target = "/home/you/work/src/App.zig", .expected = "src/App.zig" },
        .{ .target = "/home/you/.drinky/config.json", .expected = "~/.drinky/config.json" },
        .{ .target = "/home/you", .expected = "~" },
        .{ .target = "/home/yours/a.zig", .expected = "/home/yours/a.zig" },
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
    try std.testing.expectEqualStrings("1.0 KiB", bytes(&buffer, 1024));
    try std.testing.expectEqualStrings("3.1 KiB", bytes(&buffer, 3200));
    try std.testing.expectEqualStrings("1.0 MiB", bytes(&buffer, 1024 * 1024));
}
