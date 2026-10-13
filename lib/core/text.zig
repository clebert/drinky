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

pub fn validPrefix(bytes: []const u8) []const u8 {
    var length = bytes.len;
    for (0..4) |_| {
        if (std.unicode.utf8ValidateSlice(bytes[0..length])) return bytes[0..length];
        if (length == 0) break;
        length -= 1;
    }
    return bytes;
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

test "a cut text keeps its valid UTF-8 prefix" {
    try std.testing.expectEqualStrings("abc", validPrefix("abc"));
    try std.testing.expectEqualStrings("a", validPrefix("a\xe2\x82"));
    try std.testing.expectEqualStrings("a€", validPrefix("a€"));
    try std.testing.expectEqualStrings("\x80\x80\x80\x80\x80", validPrefix("\x80\x80\x80\x80\x80"));
}
