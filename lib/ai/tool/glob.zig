//! Glob matching for `/`-separated paths. Within a segment `*` matches any run
//! of characters and `?` matches a single character; neither crosses `/`. A
//! whole segment of `**` matches zero or more path segments. Matching is
//! iterative with single-slot backtracking at both the segment and byte level.

const std = @import("std");

/// Whether `query.path` matches `query.pattern`. Both use `/` as the separator.
pub fn match(query: struct { pattern: []const u8, path: []const u8 }) bool {
    return backtrack(struct {
        pattern: []const u8,
        path: []const u8,
        fn wild(self: @This(), index: usize) bool {
            return std.mem.eql(u8, segmentAt(self.pattern, index), "**");
        }
        fn eql(self: @This(), pattern_index: usize, path_index: usize) bool {
            return matchSegment(
                segmentAt(self.pattern, pattern_index),
                segmentAt(self.path, path_index),
            );
        }
    }{
        .pattern = query.pattern,
        .path = query.path,
    }, segmentCount(query.pattern), segmentCount(query.path));
}

/// Match one segment: `*` spans any run, `?` one character, neither has `/`.
fn matchSegment(pattern: []const u8, name: []const u8) bool {
    return backtrack(struct {
        pattern: []const u8,
        path: []const u8,
        fn wild(self: @This(), index: usize) bool {
            return self.pattern[index] == '*';
        }
        fn eql(self: @This(), pattern_index: usize, path_index: usize) bool {
            return self.pattern[pattern_index] == '?' or
                self.pattern[pattern_index] == self.path[path_index];
        }
    }{ .pattern = pattern, .path = name }, pattern.len, name.len);
}

/// The single-slot backtracking loop both granularities share: `matcher.wild`
/// marks the any-run wildcard and `matcher.eql` tests one element pair.
fn backtrack(matcher: anytype, pattern_count: usize, path_count: usize) bool {
    var pattern_index: usize = 0;
    var path_index: usize = 0;
    var star_pattern: ?usize = null;
    var star_path: usize = 0;

    while (path_index < path_count) {
        if (pattern_index < pattern_count) {
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

    while (pattern_index < pattern_count and matcher.wild(pattern_index)) pattern_index += 1;
    return pattern_index == pattern_count;
}

fn segmentCount(text: []const u8) usize {
    return std.mem.count(u8, text, "/") + 1;
}

fn segmentAt(text: []const u8, index: usize) []const u8 {
    var it = std.mem.splitScalar(u8, text, '/');
    var i: usize = 0;
    while (it.next()) |segment| : (i += 1) {
        if (i == index) return segment;
    }
    unreachable;
}

test match {
    try std.testing.expect(match(.{ .pattern = "*.zig", .path = "foo.zig" }));
    try std.testing.expect(!match(.{ .pattern = "*.zig", .path = "foo.txt" }));
    try std.testing.expect(!match(.{ .pattern = "*.zig", .path = "a/foo.zig" }));
    try std.testing.expect(match(.{ .pattern = "**/*.zig", .path = "foo.zig" }));
    try std.testing.expect(match(.{ .pattern = "**/*.zig", .path = "a/b/foo.zig" }));
    try std.testing.expect(match(.{ .pattern = "src/**/*.zig", .path = "src/foo.zig" }));
    try std.testing.expect(match(.{ .pattern = "src/**/*.zig", .path = "src/a/b/foo.zig" }));
    try std.testing.expect(!match(.{ .pattern = "src/**/*.zig", .path = "lib/foo.zig" }));
    try std.testing.expect(match(.{ .pattern = "**", .path = "a/b/c" }));
    try std.testing.expect(match(.{ .pattern = "a?c.zig", .path = "abc.zig" }));
    try std.testing.expect(!match(.{ .pattern = "a?c.zig", .path = "a/c.zig" }));
    try std.testing.expect(match(.{ .pattern = "build.zig", .path = "build.zig" }));
}
