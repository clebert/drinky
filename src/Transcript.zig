const std = @import("std");
const application = @import("application");

const ui = @import("ui/root.zig");

const Transcript = @This();

gpa: std.mem.Allocator,
block_list: std.ArrayList(ui.Block) = .empty,

pub const Run = struct {
    end: usize,
    started_ms: i64,
    tools: usize,
    received_bytes: usize,
};

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Transcript) void {
    for (self.block_list.items) |*block| block.deinit(self.gpa);
    self.block_list.deinit(self.gpa);
}

pub fn append(self: *Transcript, source: *const ui.Block.Source) !void {
    try self.block_list.ensureUnusedCapacity(self.gpa, 1);
    self.block_list.appendAssumeCapacity(try .init(self.gpa, source));
}

pub fn find(self: *const Transcript, id: u64) ?usize {
    var index = self.block_list.items.len;
    while (index > 0) {
        index -= 1;
        if (self.block_list.items[index].record_id == id) return index;
    }
    return null;
}

pub fn replace(self: *Transcript, index: usize, block: ui.Block) void {
    const previous = &self.block_list.items[index];
    var replacement = block;
    if (previous.sameContent(&replacement)) {
        defer replacement.deinit(self.gpa);
        const work = replacement.work orelse {
            previous.work = null;
            return;
        };
        if (previous.work) |*kept| {
            kept.started_ms = work.started_ms;
            kept.end = work.end;
        } else previous.work = work;
        return;
    }
    replacement.adoptCache(previous);
    previous.deinit(self.gpa);
    previous.* = replacement;
}

pub fn remove(self: *Transcript, ids: []const u64) void {
    var kept: usize = 0;
    for (self.block_list.items) |*block| {
        if (listed(block, ids)) {
            block.deinit(self.gpa);
        } else {
            self.block_list.items[kept] = block.*;
            kept += 1;
        }
    }
    self.block_list.shrinkRetainingCapacity(kept);
}

fn listed(block: *const ui.Block, ids: []const u64) bool {
    const id = block.record_id orelse return false;
    return std.mem.findScalar(u64, ids, id) != null;
}

pub fn truncate(self: *Transcript, count: usize) void {
    for (self.block_list.items[count..]) |*block| block.deinit(self.gpa);
    self.block_list.shrinkRetainingCapacity(count);
}

pub fn present(self: *Transcript, verbose: bool) void {
    for (self.block_list.items) |*block| block.present(verbose);
    if (verbose) return;
    const items = self.block_list.items;
    var index: usize = 0;
    while (index < items.len) {
        if (items[index].work == null) {
            index += 1;
            continue;
        }
        const run = runAt(items, index);
        for (items[index + 1 .. run.end]) |*block| block.presentWork(null);
        if (items[run.end - 1].work.?.end) |closed| {
            items[index].presentWork(&.{
                .elapsed_ms = closed.time_ms - run.started_ms,
                .tools = run.tools,
                .received_bytes = run.received_bytes,
                .status = closed.status,
            });
        } else {
            items[index].presentWork(null);
        }
        index = run.end;
    }
}

pub fn openWork(self: *const Transcript) ?Run {
    const items = self.block_list.items;
    var start = items.len;
    while (start > 0 and items[start - 1].work != null) start -= 1;
    if (start == items.len or items[items.len - 1].work.?.end != null) return null;
    return runAt(items, start);
}

fn runAt(items: []const ui.Block, start: usize) Run {
    var run: Run = .{
        .end = start,
        .started_ms = items[start].work.?.started_ms,
        .tools = 0,
        .received_bytes = 0,
    };
    while (run.end < items.len and items[run.end].work != null) : (run.end += 1) {
        const block = &items[run.end];
        run.started_ms = @min(run.started_ms, block.work.?.started_ms);
        switch (block.content) {
            .thinking => |list| run.received_bytes += list.items.len,
            .tool_result => {
                run.tools += 1;
                run.received_bytes += block.receivedBytes();
            },
            .intro, .user, .user_note, .model, .event => unreachable,
        }
    }
    return run;
}
