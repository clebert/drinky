const std = @import("std");

pub fn match(query: *const struct { pattern: []const u8, path: []const u8 }) bool {
    const matcher: Matcher(.segment) = .{ .pattern = query.pattern, .path = query.path };
    return matcher.match();
}

fn Matcher(comptime unit: enum { segment, byte }) type {
    return struct {
        pattern: []const u8,
        path: []const u8,

        const Self = @This();

        fn match(self: *const Self) bool {
            const counts = switch (unit) {
                .segment => .{
                    .pattern = segmentCount(self.pattern),
                    .path = segmentCount(self.path),
                },
                .byte => .{ .pattern = self.pattern.len, .path = self.path.len },
            };
            var pattern_index: usize = 0;
            var path_index: usize = 0;
            var star_pattern: ?usize = null;
            var star_path: usize = 0;

            while (path_index < counts.path) {
                if (pattern_index < counts.pattern) {
                    if (self.wild(pattern_index)) {
                        star_pattern = pattern_index + 1;
                        star_path = path_index;
                        pattern_index += 1;
                        continue;
                    }
                    if (self.eql(.{ .pattern = pattern_index, .path = path_index })) {
                        pattern_index += 1;
                        path_index += 1;
                        continue;
                    }
                }
                if (star_pattern) |resume_pattern| {
                    star_path += 1;
                    path_index = star_path;
                    pattern_index = resume_pattern;
                    continue;
                }
                return false;
            }

            while (pattern_index < counts.pattern and self.wild(pattern_index)) pattern_index += 1;
            return pattern_index == counts.pattern;
        }

        fn wild(self: *const Self, index: usize) bool {
            return switch (unit) {
                .segment => std.mem.eql(u8, segmentAt(self.pattern, index), "**"),
                .byte => self.pattern[index] == '*',
            };
        }

        fn eql(self: *const Self, indices: struct { pattern: usize, path: usize }) bool {
            return switch (unit) {
                .segment => match: {
                    const matcher: Matcher(.byte) = .{
                        .pattern = segmentAt(self.pattern, indices.pattern),
                        .path = segmentAt(self.path, indices.path),
                    };
                    break :match matcher.match();
                },
                .byte => self.pattern[indices.pattern] == '?' or
                    self.pattern[indices.pattern] == self.path[indices.path],
            };
        }
    };
}

fn segmentCount(text: []const u8) usize {
    return std.mem.count(u8, text, "/") + 1;
}

fn segmentAt(text: []const u8, index: usize) []const u8 {
    var segments = std.mem.splitScalar(u8, text, '/');
    var current: usize = 0;
    while (segments.next()) |segment| : (current += 1) {
        if (current == index) return segment;
    }
    unreachable;
}

test match {
    try std.testing.expect(match(&.{ .pattern = "*.zig", .path = "foo.zig" }));
    try std.testing.expect(!match(&.{ .pattern = "*.zig", .path = "foo.txt" }));
    try std.testing.expect(!match(&.{ .pattern = "*.zig", .path = "a/foo.zig" }));
    try std.testing.expect(match(&.{ .pattern = "**/*.zig", .path = "foo.zig" }));
    try std.testing.expect(match(&.{ .pattern = "**/*.zig", .path = "a/b/foo.zig" }));
    try std.testing.expect(match(&.{ .pattern = "src/**/*.zig", .path = "src/foo.zig" }));
    try std.testing.expect(match(&.{ .pattern = "src/**/*.zig", .path = "src/a/b/foo.zig" }));
    try std.testing.expect(!match(&.{ .pattern = "src/**/*.zig", .path = "lib/foo.zig" }));
    try std.testing.expect(match(&.{ .pattern = "**", .path = "a/b/c" }));
    try std.testing.expect(match(&.{ .pattern = "a?c.zig", .path = "abc.zig" }));
    try std.testing.expect(!match(&.{ .pattern = "a?c.zig", .path = "a/c.zig" }));
    try std.testing.expect(match(&.{ .pattern = "build.zig", .path = "build.zig" }));
}
