const std = @import("std");

const Message = @This();

content: []const u8,
severity: Severity,

pub const Severity = enum { information, warning, failure };

pub fn print(
    gpa: std.mem.Allocator,
    severity: Severity,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!Message {
    return .{ .content = try gpa.print(format, args), .severity = severity };
}

pub fn dupe(self: *const Message, gpa: std.mem.Allocator) error{OutOfMemory}!Message {
    return .{ .content = try gpa.dupe(u8, self.content), .severity = self.severity };
}

pub fn deinit(self: *const Message, gpa: std.mem.Allocator) void {
    gpa.free(self.content);
}
