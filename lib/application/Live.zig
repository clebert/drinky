const std = @import("std");

const Live = @This();

calls: []const Call = &.{},
thinking: bool = false,

pub const Call = struct {
    name: []const u8,
    argument_bytes: usize,
    opened_ms: i64,
};

pub fn dupe(self: *const Live, gpa: std.mem.Allocator) error{OutOfMemory}!Live {
    const calls = try gpa.alloc(Call, self.calls.len);
    errdefer gpa.free(calls);
    var count: usize = 0;
    errdefer for (calls[0..count]) |*call| gpa.free(call.name);
    for (self.calls, calls) |*source, *target| {
        target.* = source.*;
        target.name = try gpa.dupe(u8, source.name);
        count += 1;
    }
    return .{ .calls = calls, .thinking = self.thinking };
}

pub fn deinit(self: *const Live, gpa: std.mem.Allocator) void {
    for (self.calls) |*call| gpa.free(call.name);
    gpa.free(self.calls);
}
