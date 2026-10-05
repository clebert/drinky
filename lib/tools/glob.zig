const std = @import("std");

pub fn match(query: *const struct { pattern: []const u8, path: []const u8 }) bool {
    return backtrack(&struct {
        pattern: []const u8,
        path: []const u8,
        fn wild(self: *const @This(), index: usize) bool {
            return std.mem.eql(u8, segmentAt(self.pattern, index), "**");
        }
        fn eql(self: *const @This(), pattern_index: usize, path_index: usize) bool {
            return matchSegment(&.{
                .pattern = segmentAt(self.pattern, pattern_index),
                .name = segmentAt(self.path, path_index),
            });
        }
    }{
        .pattern = query.pattern,
        .path = query.path,
    }, .{ .pattern = segmentCount(query.pattern), .path = segmentCount(query.path) });
}

fn matchSegment(segment: *const struct { pattern: []const u8, name: []const u8 }) bool {
    return backtrack(&struct {
        pattern: []const u8,
        path: []const u8,
        fn wild(self: *const @This(), index: usize) bool {
            return self.pattern[index] == '*';
        }
        fn eql(self: *const @This(), pattern_index: usize, path_index: usize) bool {
            return self.pattern[pattern_index] == '?' or
                self.pattern[pattern_index] == self.path[path_index];
        }
    }{
        .pattern = segment.pattern,
        .path = segment.name,
    }, .{ .pattern = segment.pattern.len, .path = segment.name.len });
}

fn backtrack(matcher: anytype, counts: struct { pattern: usize, path: usize }) bool {
    var pattern_index: usize = 0;
    var path_index: usize = 0;
    var star_pattern: ?usize = null;
    var star_path: usize = 0;

    while (path_index < counts.path) {
        if (pattern_index < counts.pattern) {
            if (matcher.wild(pattern_index)) {
                star_pattern = pattern_index + 1;
                star_path = path_index;
                pattern_index += 1;
                continue;
            }
            if (matcher.eql(pattern_index, path_index)) {
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

    while (pattern_index < counts.pattern and matcher.wild(pattern_index)) pattern_index += 1;
    return pattern_index == counts.pattern;
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
