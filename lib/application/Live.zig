const std = @import("std");
const tools = @import("tools");
const Record = @import("Record.zig");

const Live = @This();

calls: []const Call = &.{},
thinking: bool = false,

pub const Call = struct {
    id: u64,
    name: []const u8,
    phase: Phase,
    argument_bytes: usize,
    opened_ms: i64,
    started_ms: i64,
    description: tools.Registry.Description,

    pub const Phase = enum { streaming, queued, running };
};

pub fn dupe(self: *const Live, gpa: std.mem.Allocator) error{OutOfMemory}!Live {
    const calls = try gpa.alloc(Call, self.calls.len);
    errdefer gpa.free(calls);
    var count: usize = 0;
    errdefer for (calls[0..count]) |*call| freeCall(gpa, call);
    for (self.calls, calls) |*source, *target| {
        target.* = source.*;
        target.name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(target.name);
        target.description = try Record.dupeDescription(gpa, &source.description);
        count += 1;
    }
    return .{ .calls = calls, .thinking = self.thinking };
}

pub fn deinit(self: *const Live, gpa: std.mem.Allocator) void {
    for (self.calls) |*call| freeCall(gpa, call);
    gpa.free(self.calls);
}

fn freeCall(gpa: std.mem.Allocator, call: *const Call) void {
    gpa.free(call.name);
    call.description.deinit(gpa);
}
