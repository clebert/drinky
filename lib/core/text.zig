const std = @import("std");

pub fn pluralSuffix(count: u64) []const u8 {
    return if (count == 1) "" else "s";
}

test pluralSuffix {
    try std.testing.expectEqualStrings("s", pluralSuffix(0));
    try std.testing.expectEqualStrings("", pluralSuffix(1));
    try std.testing.expectEqualStrings("s", pluralSuffix(2));
}
