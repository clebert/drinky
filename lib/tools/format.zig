const std = @import("std");

const Containment = struct {
    boundary: []const u8,
    target: []const u8,
};

pub fn relativeTo(options: *const Containment) ?[]const u8 {
    const boundary = options.boundary;
    if (boundary.len == 0) return null;
    if (!contains(options)) return null;
    const separated = std.Io.Dir.path.isSep(boundary[boundary.len - 1]);
    const cut = if (separated) boundary.len else boundary.len + 1;
    if (cut >= options.target.len) return null;
    return options.target[cut..];
}

pub fn contains(options: *const Containment) bool {
    const boundary = options.boundary;
    const target = options.target;
    if (std.mem.eql(u8, boundary, target)) return true;
    if (boundary.len == 0 or target.len <= boundary.len) return false;
    if (!std.mem.startsWith(u8, target, boundary)) return false;
    if (std.Io.Dir.path.isSep(boundary[boundary.len - 1])) return true;
    return std.Io.Dir.path.isSep(target[boundary.len]);
}

pub fn isText(bytes: []const u8) bool {
    return std.mem.findScalar(u8, bytes, 0) == null and std.unicode.utf8ValidateSlice(bytes);
}

pub fn truncate(text: []const u8, bytes_max: usize) []const u8 {
    var end = @min(text.len, bytes_max);
    while (end > 0 and end < text.len and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

pub fn lines(text: []const u8) usize {
    if (text.len == 0) return 0;
    const breaks = std.mem.count(u8, text, "\n");
    return if (text[text.len - 1] == '\n') breaks else breaks + 1;
}

pub fn duration(buffer: []u8, milliseconds: i64) []const u8 {
    const total: u64 = @intCast(@max(milliseconds, 0));
    if (total < std.time.ms_per_s)
        return std.mem.print(buffer, "{d}ms", .{total}) catch unreachable;
    if (total < std.time.ms_per_min) {
        const tenths = @divFloor(total, 100);
        return std.mem.print(buffer, "{d}.{d}s", .{
            @divFloor(tenths, 10),
            @mod(tenths, 10),
        }) catch unreachable;
    }
    const seconds = @divFloor(total, std.time.ms_per_s);
    return std.mem.print(buffer, "{d}m {d}s", .{
        @divFloor(seconds, std.time.s_per_min),
        @mod(seconds, std.time.s_per_min),
    }) catch unreachable;
}

test relativeTo {
    try std.testing.expectEqualStrings(
        "src/App.zig",
        relativeTo(&.{ .boundary = "/work", .target = "/work/src/App.zig" }).?,
    );
    try std.testing.expectEqualStrings(
        "src/App.zig",
        relativeTo(&.{ .boundary = "/work/", .target = "/work/src/App.zig" }).?,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        relativeTo(&.{ .boundary = "/work", .target = "/workspace/App.zig" }),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        relativeTo(&.{ .boundary = "/work", .target = "/work" }),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        relativeTo(&.{ .boundary = "", .target = "/work/App.zig" }),
    );
}

test contains {
    try std.testing.expect(contains(&.{ .boundary = "/repo", .target = "/repo" }));
    try std.testing.expect(contains(&.{ .boundary = "/repo", .target = "/repo/file" }));
    try std.testing.expect(!contains(&.{ .boundary = "/repo", .target = "/repository/file" }));
    try std.testing.expect(contains(&.{ .boundary = "/", .target = "/outside" }));
    try std.testing.expect(!contains(&.{ .boundary = "", .target = "/outside" }));
}

test isText {
    try std.testing.expect(isText(""));
    try std.testing.expect(isText("caf\xC3\xA9\n"));
    try std.testing.expect(!isText("a\x00b"));
    try std.testing.expect(!isText("caf\xE9"));
}

test truncate {
    try std.testing.expectEqualStrings("a", truncate("a\xC3\xA9", 2));
    try std.testing.expectEqualStrings("a\xC3\xA9", truncate("a\xC3\xA9", 3));
    try std.testing.expectEqualStrings("a\xC3\xA9", truncate("a\xC3\xA9", 10));
    try std.testing.expectEqualStrings("", truncate("", 5));
}

test lines {
    try std.testing.expectEqual(@as(usize, 0), lines(""));
    try std.testing.expectEqual(@as(usize, 1), lines("a"));
    try std.testing.expectEqual(@as(usize, 1), lines("a\n"));
    try std.testing.expectEqual(@as(usize, 3), lines("a\nb\nc"));
    try std.testing.expectEqual(@as(usize, 3), lines("a\nb\nc\n"));
    try std.testing.expectEqual(@as(usize, 2), lines("a\n\n"));
}

test duration {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0ms", duration(&buffer, 0));
    try std.testing.expectEqualStrings("42ms", duration(&buffer, 42));
    try std.testing.expectEqualStrings("999ms", duration(&buffer, 999));
    try std.testing.expectEqualStrings("1.0s", duration(&buffer, 1_000));
    try std.testing.expectEqualStrings("41.6s", duration(&buffer, 41_600));
    try std.testing.expectEqualStrings("59.9s", duration(&buffer, 59_999));
    try std.testing.expectEqualStrings("1m 0s", duration(&buffer, 60_000));
    try std.testing.expectEqualStrings("2m 5s", duration(&buffer, 125_400));
    try std.testing.expectEqualStrings("0ms", duration(&buffer, -1));
}
