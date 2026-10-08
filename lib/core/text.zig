const std = @import("std");

pub fn pluralSuffix(count: u64) []const u8 {
    return if (count == 1) "" else "s";
}

pub inline fn repeat(
    comptime fragment: []const u8,
    comptime count: usize,
) *const [fragment.len * count]u8 {
    const fragments: [count][fragment.len]u8 = @splat(fragment.*);
    return @ptrCast(&fragments);
}

test pluralSuffix {
    try std.testing.expectEqualStrings("s", pluralSuffix(0));
    try std.testing.expectEqualStrings("", pluralSuffix(1));
    try std.testing.expectEqualStrings("s", pluralSuffix(2));
}

test repeat {
    try std.testing.expectEqualStrings("", repeat("ab", 0));
    try std.testing.expectEqualStrings("é-é-é-", repeat("é-", 3));
}
