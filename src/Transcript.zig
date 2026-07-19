//! The permanent blocks above the live tail, oldest first, plus the "model run"
//! invariant: a run of streamed reasoning collects into one growing thinking
//! block, then a run of streamed answer text into one growing model block, until
//! a tool call, a turn boundary, or any other block ends the message. Owns its
//! blocks' bytes (freed on `deinit`).

const std = @import("std");

const ui = @import("ui/root.zig");

const Transcript = @This();

gpa: std.mem.Allocator,
entries: std.ArrayList(ui.block.Entry),
/// Index and kind of the current run's streamed block, so deltas of that kind
/// keep appending to it; null when no run is open.
current: ?struct { index: usize, kind: ui.block.Entry.Kind },
/// Index of the first block streamed for the current assistant message
/// (reasoning or answer), so a retry can drop the whole partial message; null
/// when none is streaming.
message_start: ?usize,

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{ .gpa = gpa, .entries = .empty, .current = null, .message_start = null };
}

pub fn deinit(self: *Transcript) void {
    for (self.entries.items) |*entry| entry.deinit(self.gpa);
    self.entries.deinit(self.gpa);
}

/// Append a discrete block copying `text`; this ends any open streamed run, so
/// the next streamed delta opens a fresh block.
pub fn append(
    self: *Transcript,
    kind: ui.block.Entry.Kind,
    is_error: bool,
    text: []const u8,
) !void {
    self.endMessage();
    var entry = try ui.block.Entry.init(self.gpa, kind, is_error, text);
    errdefer entry.deinit(self.gpa);
    try self.entries.append(self.gpa, entry);
}

/// Append streamed text of `kind` (`.thinking` reasoning or `.model` answer),
/// opening a block of that kind on demand so a run of deltas collects into one
/// block; a kind change ends the previous run.
pub fn appendStream(self: *Transcript, kind: ui.block.Entry.Kind, delta: []const u8) !void {
    if (self.current == null or self.current.?.kind != kind)
        self.current = .{ .index = try self.openRun(kind), .kind = kind };
    switch (self.entries.items[self.current.?.index]) {
        .model, .thinking => |*list| try list.appendSlice(self.gpa, delta),
        else => unreachable,
    }
}

/// Open a streamed block of `kind` at the tail, recording it as the message's
/// first block when none has opened yet, and return its index.
fn openRun(self: *Transcript, kind: ui.block.Entry.Kind) !usize {
    var entry = try ui.block.Entry.init(self.gpa, kind, false, "");
    errdefer entry.deinit(self.gpa);
    try self.entries.append(self.gpa, entry);
    const index = self.entries.items.len - 1;
    if (self.message_start == null) self.message_start = index;
    return index;
}

/// End the current message's streamed runs so the next delta opens a new block.
pub fn endMessage(self: *Transcript) void {
    self.current = null;
    self.message_start = null;
}

/// Drop the open message's streamed blocks (reasoning and answer alike) so a
/// reply being retried leaves nothing partial behind. A no-op when none is
/// streaming. The blocks are the contiguous tail from `message_start`, since
/// nothing discrete has ended the message.
pub fn discardMessage(self: *Transcript) void {
    const start = self.message_start orelse return;
    self.endMessage();
    for (self.entries.items[start..]) |*entry| entry.deinit(self.gpa);
    self.entries.shrinkRetainingCapacity(start);
}

/// The blocks above the live tail, oldest first, for projection.
pub fn blocks(self: *const Transcript) []const ui.block.Entry {
    return self.entries.items;
}

test "streamed deltas collect into one block until a discrete block ends the run" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.model, "hel");
    try transcript.appendStream(.model, "lo");
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);
    try std.testing.expectEqualStrings("hello", transcript.entries.items[0].model.items);

    try transcript.append(.user, false, "hi");
    try transcript.appendStream(.model, "more");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries.items.len);
    try std.testing.expectEqualStrings("more", transcript.entries.items[2].model.items);
}

test "endMessage forces the next delta into a new block" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.model, "a");
    transcript.endMessage();
    try transcript.appendStream(.model, "b");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
}

test "discardMessage drops the open run so a retry starts clean" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.user, false, "hi");
    try transcript.appendStream(.model, "partial");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);

    transcript.discardMessage();
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);

    try transcript.appendStream(.model, "fresh");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings("fresh", transcript.entries.items[1].model.items);

    // A no-op when no run is open.
    transcript.endMessage();
    transcript.discardMessage();
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
}

test "reasoning collects into a thinking block that the answer run does not extend" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, "weigh ");
    try transcript.appendStream(.thinking, "it");
    try transcript.appendStream(.model, "answer");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings("weigh it", transcript.entries.items[0].thinking.items);
    try std.testing.expectEqualStrings("answer", transcript.entries.items[1].model.items);
}

test "discard drops a partial message's reasoning and answer together" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.user, false, "hi");
    try transcript.appendStream(.thinking, "thinking");
    try transcript.appendStream(.model, "partial");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries.items.len);

    transcript.discardMessage();
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);

    try transcript.appendStream(.thinking, "fresh");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings("fresh", transcript.entries.items[1].thinking.items);
}
