const std = @import("std");

const ui = @import("ui/root.zig");

const Transcript = @This();

gpa: std.mem.Allocator,
block_list: std.ArrayList(ui.Block),
current: ?struct { kind: ui.Block.Kind, index: ?usize },
held: std.ArrayList(u8),

pub const Range = struct {
    start: usize,
    end: usize,
};

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{
        .gpa = gpa,
        .block_list = .empty,
        .current = null,
        .held = .empty,
    };
}

pub fn deinit(self: *Transcript) void {
    for (self.block_list.items) |*block| block.deinit(self.gpa);
    self.block_list.deinit(self.gpa);
    self.held.deinit(self.gpa);
}

pub fn append(self: *Transcript, source: *const ui.Block.Source) !void {
    self.endMessage();
    var block = try ui.Block.init(self.gpa, source);
    errdefer block.deinit(self.gpa);
    try self.block_list.append(self.gpa, block);
}

pub fn replaceEvent(
    self: *Transcript,
    index: usize,
    payload: *const ui.Block.Event.Payload,
) !void {
    try self.block_list.items[index].replaceEvent(self.gpa, payload);
}

pub fn beginRun(self: *Transcript, kind: ui.Block.Kind) void {
    self.current = .{ .kind = kind, .index = null };
    self.held.clearRetainingCapacity();
}

pub fn beginThinking(self: *Transcript, thinking: *const ui.Block.Thinking) !usize {
    self.beginRun(.thinking);
    const index = try self.openRun(.thinking);
    self.current.?.index = index;
    self.block_list.items[index].thinking = thinking.*;
    return index;
}

pub fn present(self: *Transcript, mode: ui.Block.Mode, now_ms: i64) void {
    for (self.block_list.items) |*block| block.present(mode);
    if (mode == .full) return;
    var index: usize = 0;
    while (index < self.block_list.items.len) {
        const first = &self.block_list.items[index];
        if (first.thinking == null) {
            index += 1;
            continue;
        }
        var summary: ui.Block.Thinking.Summary = .{
            .bytes = first.content.thinking.items.len,
            .elapsed_ms = first.thinking.?.elapsed(now_ms),
            .status = first.thinking.?.status,
        };
        var end = index + 1;
        while (end < self.block_list.items.len) : (end += 1) {
            const block = &self.block_list.items[end];
            const thinking = block.thinking orelse break;
            if (!thinking.joins_previous) break;
            summary.bytes += block.content.thinking.items.len;
            summary.elapsed_ms += thinking.elapsed(now_ms);
            summary.status = thinking.status;
            block.presentThinking(null);
        }
        first.presentThinking(&summary);
        index = end;
    }
}

pub fn runIndex(self: *const Transcript) ?usize {
    const run = self.current orelse return null;
    return run.index;
}

pub fn appendStream(self: *Transcript, kind: ui.Block.Kind, delta: []const u8) !void {
    if (delta.len == 0) return;
    if (self.current == null or self.current.?.kind != kind) self.beginRun(kind);
    const run = &self.current.?;
    if (run.index == null) {
        if (ui.paint.isBlank(delta)) return self.held.appendSlice(self.gpa, delta);
        run.index = try self.openRun(kind);
    }
    try self.block_list.items[run.index.?].appendText(self.gpa, delta);
}

fn openRun(self: *Transcript, kind: ui.Block.Kind) !usize {
    const source: ui.Block.Source = switch (kind) {
        .thinking => .{ .thinking = self.held.items },
        .model => .{ .model = self.held.items },
        .intro, .user, .user_note, .tool_result, .event => unreachable,
    };
    var block = try ui.Block.init(self.gpa, &source);
    errdefer block.deinit(self.gpa);
    try self.block_list.append(self.gpa, block);
    self.held.clearRetainingCapacity();
    return self.block_list.items.len - 1;
}

pub fn endMessage(self: *Transcript) void {
    self.current = null;
    self.held.clearRetainingCapacity();
}

pub fn truncate(self: *Transcript, block_count: usize) void {
    self.remove(.{ .start = block_count, .end = self.block_list.items.len });
}

pub fn remove(self: *Transcript, range: Range) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= self.block_list.items.len);
    self.endMessage();
    for (self.block_list.items[range.start..range.end]) |*block| block.deinit(self.gpa);
    self.block_list.replaceRangeAssumeCapacity(range.start, range.end - range.start, &.{});
}

pub fn takeThinking(
    self: *Transcript,
    block_count: usize,
    held: *std.ArrayList(ui.Block),
) error{OutOfMemory}!void {
    const tail = self.block_list.items[block_count..];
    var count: usize = 0;
    for (tail) |block| count += @intFromBool(block.thinking != null);
    try held.ensureUnusedCapacity(self.gpa, count);
    for (tail) |*block| {
        if (block.thinking == null) continue;
        held.appendAssumeCapacity(block.*);
        block.* = .{ .content = .{ .thinking = .empty }, .thinking = .{} };
    }
}

pub fn discard(self: *Transcript, block_count: usize) void {
    std.debug.assert(block_count <= self.block_list.items.len);
    self.endMessage();
    var retained_count = block_count;
    for (self.block_list.items[block_count..]) |*block| {
        if (block.survivesDiscard()) {
            self.block_list.items[retained_count] = block.*;
            retained_count += 1;
        } else {
            block.deinit(self.gpa);
        }
    }
    self.block_list.shrinkRetainingCapacity(retained_count);
}

pub fn blocks(self: *const Transcript) []const ui.Block {
    return self.block_list.items;
}

test "streamed deltas collect into one block until a discrete block ends the run" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.model, "hel");
    try transcript.appendStream(.model, "lo");
    try std.testing.expectEqual(@as(usize, 1), transcript.blocks().len);
    try std.testing.expectEqualStrings("hello", transcript.blocks()[0].content.model.items);

    try transcript.append(&.{ .user = "hi" });
    try transcript.appendStream(.model, "more");
    try std.testing.expectEqual(@as(usize, 3), transcript.blocks().len);
    try std.testing.expectEqualStrings("more", transcript.blocks()[2].content.model.items);
}

test "an empty delta opens no block and does not break a run" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, "");
    try transcript.appendStream(.model, "");
    try std.testing.expectEqual(@as(usize, 0), transcript.blocks().len);

    try transcript.appendStream(.model, "he");
    try transcript.appendStream(.model, "");
    try transcript.appendStream(.model, "llo");
    try std.testing.expectEqual(@as(usize, 1), transcript.blocks().len);
    try std.testing.expectEqualStrings("hello", transcript.blocks()[0].content.model.items);
}

test "a run holds its whitespace until another byte opens the block" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, "\n");
    try transcript.appendStream(.thinking, " \t\r\n");
    try std.testing.expectEqual(@as(usize, 0), transcript.blocks().len);

    try transcript.appendStream(.model, "answer");
    try std.testing.expectEqual(@as(usize, 1), transcript.blocks().len);
    try std.testing.expectEqualStrings("answer", transcript.blocks()[0].content.model.items);

    transcript.endMessage();
    try transcript.appendStream(.thinking, "\n\n");
    try transcript.appendStream(.thinking, "weigh it");
    try std.testing.expectEqual(@as(usize, 2), transcript.blocks().len);
    const reasoning = transcript.blocks()[1].content.thinking;
    try std.testing.expectEqualStrings("\n\nweigh it", reasoning.items);

    transcript.endMessage();
    try transcript.appendStream(.model, " ");
    transcript.endMessage();
    try transcript.appendStream(.model, " ");
    transcript.endMessage();
    try transcript.appendStream(.model, "fresh");
    try std.testing.expectEqual(@as(usize, 3), transcript.blocks().len);
    try std.testing.expectEqualStrings("fresh", transcript.blocks()[2].content.model.items);
}

test "endMessage and beginRun force the next delta into a new block" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.model, "a");
    transcript.endMessage();
    try transcript.appendStream(.model, "b");
    try std.testing.expectEqual(@as(usize, 2), transcript.blocks().len);
    try std.testing.expectEqual(@as(?usize, 1), transcript.runIndex());

    transcript.beginRun(.model);
    try std.testing.expect(transcript.runIndex() == null);
    try transcript.appendStream(.model, "c");
    try std.testing.expectEqual(@as(usize, 3), transcript.blocks().len);
    try std.testing.expectEqual(@as(?usize, 2), transcript.runIndex());
    try std.testing.expectEqualStrings("c", transcript.blocks()[2].content.model.items);
}

test "truncate removes optimistic tail blocks" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(&.{ .user = "keep" });
    try transcript.append(&.{ .user = "rollback" });
    transcript.truncate(1);
    try std.testing.expectEqual(@as(usize, 1), transcript.blocks().len);
    try std.testing.expectEqualStrings("keep", transcript.blocks()[0].content.user.items);
}

test "remove drops the blocks of its range and keeps the blocks around it" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(&.{ .intro = "keep intro" });
    try transcript.append(&.{ .user = "drop prompt" });
    try transcript.appendStream(.model, "drop reply");
    try transcript.append(&.{ .event = .{ .text = "drop retry", .survives_discard = true } });
    try transcript.append(&.{ .event = .{ .text = "keep later event" } });
    transcript.remove(.{ .start = 1, .end = 4 });

    const kept = transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("keep intro", kept[0].content.intro.items);
    try std.testing.expectEqualStrings("keep later event", kept[1].content.event.text.items);
}

test "a discard preserves only marked events after its checkpoint" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(&.{ .event = .{ .text = "keep before checkpoint" } });
    try transcript.append(&.{ .user = "drop user prompt" });
    try transcript.append(&.{ .event = .{ .text = "keep retry", .survives_discard = true } });
    try transcript.append(&.{ .event = .{ .text = "drop ordinary event" } });
    try transcript.appendStream(.model, "drop partial reply");
    transcript.discard(1);

    const kept = transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings(
        "keep before checkpoint",
        kept[0].content.event.text.items,
    );
    try std.testing.expectEqualStrings("keep retry", kept[1].content.event.text.items);
}

test "reasoning collects into a thinking block that the answer run does not extend" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, "weigh ");
    try transcript.appendStream(.thinking, "it");
    try transcript.appendStream(.model, "answer");
    try std.testing.expectEqual(@as(usize, 2), transcript.blocks().len);
    const reasoning = transcript.blocks()[0].content.thinking;
    try std.testing.expectEqualStrings("weigh it", reasoning.items);
    try std.testing.expectEqualStrings("answer", transcript.blocks()[1].content.model.items);
}
