const std = @import("std");

const Tool = @This();

name: []const u8,
description: []const u8,
parameters: []const Parameter,
mutates: bool = false,

pub const Parameter = struct {
    name: []const u8,
    type: Type,
    description: []const u8,
    required: bool = false,

    pub const Type = enum { string, integer, boolean };
};

pub const Call = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,

    pub fn dupe(self: *const Call, gpa: std.mem.Allocator) error{OutOfMemory}!Call {
        const id = try gpa.dupe(u8, self.id);
        errdefer gpa.free(id);
        const name = try gpa.dupe(u8, self.name);
        errdefer gpa.free(name);
        return .{ .id = id, .name = name, .arguments = try gpa.dupe(u8, self.arguments) };
    }

    pub fn deinit(self: *const Call, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.arguments);
    }

    pub fn argumentsJson(self: *const Call) []const u8 {
        return if (self.arguments.len == 0) "{}" else self.arguments;
    }
};

pub const Result = struct {
    call_id: []const u8,
    output: Output,

    pub fn deinit(self: *const Result, gpa: std.mem.Allocator) void {
        gpa.free(self.call_id);
        self.output.deinit(gpa);
    }
};

pub const Output = struct {
    content: []const u8 = "",
    conditions: std.EnumSet(Condition) = .initEmpty(),
    measures: std.EnumMap(Measure, u64) = .init(.{}),

    pub fn dupe(self: *const Output, gpa: std.mem.Allocator) error{OutOfMemory}!Output {
        return .{
            .content = try gpa.dupe(u8, self.content),
            .conditions = self.conditions,
            .measures = self.measures,
        };
    }

    pub fn deinit(self: *const Output, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
    }

    pub fn hasFailure(self: *const Output) bool {
        var conditions = self.conditions.iterator();
        while (conditions.next()) |condition| {
            if (condition.isFailure()) return true;
        }
        return false;
    }
};

pub const Condition = enum {
    line_truncated,
    lines_truncated,
    output_truncated,
    incomplete,
    time_limit_reached,
    match_limit_reached,
    byte_limit_reached,
    unknown_tool,
    invalid_arguments,
    skill_required,
    path_missing,
    path_not_file,
    path_not_text,
    path_too_large,
    target_missing,
    target_ambiguous,
    timed_out,
    terminated,
    overflowed,
    failed,

    fn isFailure(self: Condition) bool {
        return switch (self) {
            .line_truncated,
            .lines_truncated,
            .output_truncated,
            .incomplete,
            .time_limit_reached,
            .match_limit_reached,
            .byte_limit_reached,
            => false,
            .unknown_tool,
            .invalid_arguments,
            .skill_required,
            .path_missing,
            .path_not_file,
            .path_not_text,
            .path_too_large,
            .target_missing,
            .target_ambiguous,
            .timed_out,
            .terminated,
            .overflowed,
            .failed,
            => true,
        };
    }
};

pub const Measure = enum {
    lines,
    line_first,
    lines_total,
    lines_removed,
    lines_added,
    matches,
    matches_omitted,
    bytes,
    duration_ms,
    exit_code,
};

pub fn mutating(tools: []const Tool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool.mutates;
    }
    return false;
}

test "an output fails on a failure condition and not on a note" {
    var output: Output = .{};
    try std.testing.expect(!output.hasFailure());
    output.conditions.insert(.output_truncated);
    output.conditions.insert(.time_limit_reached);
    try std.testing.expect(!output.hasFailure());
    output.conditions.insert(.path_missing);
    try std.testing.expect(output.hasFailure());
}

test "a call copies every field and frees them" {
    const gpa = std.testing.allocator;
    const source: Call = .{ .id = "c1", .name = "read", .arguments = "{\"path\":\"a.txt\"}" };
    const copy = try source.dupe(gpa);
    defer copy.deinit(gpa);
    try std.testing.expectEqualStrings("c1", copy.id);
    try std.testing.expectEqualStrings("read", copy.name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", copy.arguments);
    try std.testing.expect(copy.arguments.ptr != source.arguments.ptr);
}
