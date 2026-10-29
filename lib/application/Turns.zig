const std = @import("std");

const core = @import("core");

const Transcript = @import("Transcript.zig");

const Turns = @This();

gpa: std.mem.Allocator,
list: std.ArrayList(Turn),

pub const Turn = struct {
    id: u64,
    range: Transcript.Range,
    line: ?[]const u8,
    mutated: bool,
    end: ?End = null,
};

pub const End = struct {
    outcome: core.Session.Outcome,
    answer: []const u8,
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

pub fn find(self: *const Turns, id: u64) ?usize {
    for (self.list.items, 0..) |turn, index| {
        if (turn.id == id) return index;
    }
    return null;
}

pub fn begin(
    self: *Turns,
    options: *const struct { id: u64, start: usize, line: ?[]const u8 },
) error{OutOfMemory}!void {
    try self.list.ensureUnusedCapacity(self.gpa, 1);
    const line = if (options.line) |text| try self.gpa.dupe(u8, text) else null;
    self.list.appendAssumeCapacity(.{
        .id = options.id,
        .range = .{ .start = options.start, .end = options.start },
        .line = line,
        .mutated = false,
    });
}

pub fn markMutated(self: *Turns) void {
    self.last().mutated = true;
}

pub fn end(self: *Turns, block_count: usize, ended: *const End) error{OutOfMemory}!void {
    const turn = self.last();
    std.debug.assert(block_count >= turn.range.start);
    std.debug.assert(turn.end == null);
    const answer = try self.gpa.dupe(u8, ended.answer);
    errdefer self.gpa.free(answer);
    turn.end = .{ .outcome = try ended.outcome.dupe(self.gpa), .answer = answer };
    turn.range.end = block_count;
}

pub fn takeLine(self: *Turns, index: usize) []const u8 {
    const turn = &self.list.items[index];
    const line = turn.line.?;
    turn.line = null;
    return line;
}

pub fn truncate(self: *Turns, count: usize) void {
    std.debug.assert(count <= self.list.items.len);
    for (self.list.items[count..]) |turn| {
        if (turn.line) |line| self.gpa.free(line);
        const ended = turn.end orelse continue;
        ended.outcome.deinit(self.gpa);
        self.gpa.free(ended.answer);
    }
    self.list.shrinkRetainingCapacity(count);
}

fn last(self: *Turns) *Turn {
    return self.list.lastPtr().?;
}
