//! Shared display formatting for the values that Pith shows to the user. A value
//! that two callers report must read the same in both places.

const std = @import("std");

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

test bytes {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", bytes(&buffer, 0));
    try std.testing.expectEqualStrings("1023 B", bytes(&buffer, 1023));
    try std.testing.expectEqualStrings("1.0 KB", bytes(&buffer, 1024));
    try std.testing.expectEqualStrings("3.1 KB", bytes(&buffer, 3200));
    try std.testing.expectEqualStrings("1.0 MB", bytes(&buffer, 1024 * 1024));
}
