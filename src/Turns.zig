const std = @import("std");

const Transcript = @import("Transcript.zig");

const Turns = @This();

gpa: std.mem.Allocator,
list: std.ArrayList(Turn),

pub const Turn = struct {
    range: Transcript.Range,
    line: ?[]const u8,
    mutated: bool,
};

pub fn init(gpa: std.mem.Allocator) Turns {
    return .{ .gpa = gpa, .list = .empty };
}

pub fn deinit(self: *Turns) void {
    self.truncate(0);
    self.list.deinit(self.gpa);
}

pub fn all(self: *const Turns) []const Turn {
    return self.list.items;
}

pub fn begin(self: *Turns, start: usize, maybe_line: ?[]const u8) error{OutOfMemory}!void {
    try self.list.ensureUnusedCapacity(self.gpa, 1);
    const line = if (maybe_line) |text| try self.gpa.dupe(u8, text) else null;
    self.list.appendAssumeCapacity(.{
        .range = .{ .start = start, .end = start },
        .line = line,
        .mutated = false,
    });
}

pub fn markMutated(self: *Turns) void {
    self.last().mutated = true;
}

pub fn end(self: *Turns, block_count: usize) void {
    std.debug.assert(block_count >= self.last().range.start);
    self.last().range.end = block_count;
}

pub fn mutatedFrom(self: *const Turns, index: usize) bool {
    for (self.list.items[index..]) |turn| {
        if (turn.mutated) return true;
    }
    return false;
}

pub fn truncate(self: *Turns, count: usize) void {
    std.debug.assert(count <= self.list.items.len);
    for (self.list.items[count..]) |turn| {
        if (turn.line) |line| self.gpa.free(line);
    }
    self.list.shrinkRetainingCapacity(count);
}

fn last(self: *Turns) *Turn {
    return self.list.lastPtr().?;
}
