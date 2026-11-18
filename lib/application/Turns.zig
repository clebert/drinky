const std = @import("std");

const core = @import("core");

const Transcript = @import("Transcript.zig");

const Turns = @This();

gpa: std.mem.Allocator,
list: std.ArrayList(Turn),

pub const Turn = struct {
    id: u64,
    range: Transcript.Range,
    prompt: ?Prompt,
    mutated: bool,
    joined: std.ArrayList([]const u8) = .empty,
    end: ?End = null,
};

pub const Prompt = union(enum) {
    line: []const u8,
    gist: Gist,

    pub const Gist = struct { title: []const u8, text: []const u8 };

    fn dupe(self: *const Prompt, gpa: std.mem.Allocator) error{OutOfMemory}!Prompt {
        return switch (self.*) {
            .line => |line| .{ .line = try gpa.dupe(u8, line) },
            .gist => |gist| {
                const title = try gpa.dupe(u8, gist.title);
                errdefer gpa.free(title);
                return .{ .gist = .{ .title = title, .text = try gpa.dupe(u8, gist.text) } };
            },
        };
    }

    pub fn deinit(self: *const Prompt, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .line => |line| gpa.free(line),
            .gist => |gist| {
                gpa.free(gist.title);
                gpa.free(gist.text);
            },
        }
    }
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
    options: *const struct { id: u64, start: usize, prompt: ?Prompt },
) error{OutOfMemory}!void {
    try self.list.ensureUnusedCapacity(self.gpa, 1);
    const prompt: ?Prompt = if (options.prompt) |*value| try value.dupe(self.gpa) else null;
    self.list.appendAssumeCapacity(.{
        .id = options.id,
        .range = .{ .start = options.start, .end = options.start },
        .prompt = prompt,
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

pub fn join(self: *Turns, text: []const u8) error{OutOfMemory}!void {
    const joined = &self.last().joined;
    try joined.ensureUnusedCapacity(self.gpa, 1);
    joined.appendAssumeCapacity(try self.gpa.dupe(u8, text));
}

pub fn takePrompt(self: *Turns, index: usize) ?Prompt {
    const turn = &self.list.items[index];
    defer turn.prompt = null;
    return turn.prompt;
}

pub fn takeJoined(self: *Turns, index: usize) std.ArrayList([]const u8) {
    const turn = &self.list.items[index];
    defer turn.joined = .empty;
    return turn.joined;
}

pub fn releaseJoined(gpa: std.mem.Allocator, joined: *std.ArrayList([]const u8)) void {
    for (joined.items) |text| gpa.free(text);
    joined.deinit(gpa);
    joined.* = .empty;
}

pub fn truncate(self: *Turns, count: usize) void {
    std.debug.assert(count <= self.list.items.len);
    for (self.list.items[count..]) |*turn| {
        if (turn.prompt) |*prompt| prompt.deinit(self.gpa);
        releaseJoined(self.gpa, &turn.joined);
        const ended = turn.end orelse continue;
        ended.outcome.deinit(self.gpa);
        self.gpa.free(ended.answer);
    }
    self.list.shrinkRetainingCapacity(count);
}

fn last(self: *Turns) *Turn {
    return self.list.lastPtr().?;
}

test "each joined message is freed after a take or a truncate, and a failed copy leaks nothing" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkJoinAllocations,
        .{},
    );
}

fn checkJoinAllocations(gpa: std.mem.Allocator) error{OutOfMemory}!void {
    var turns: Turns = .init(gpa);
    defer turns.deinit();
    try turns.begin(&.{ .id = 1, .start = 0, .prompt = .{ .line = "First." } });
    try turns.join("Also.");
    var taken = turns.takeJoined(0);
    releaseJoined(gpa, &taken);
    try turns.begin(&.{ .id = 2, .start = 0, .prompt = .{ .line = "Second." } });
    try turns.join("More.");
}
