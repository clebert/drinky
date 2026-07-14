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
/// Index of the model-text block for the current run, so streamed deltas keep
/// appending to it; null when no run is open.
current_model: ?usize,
/// Index of the thinking block for the current run, so streamed reasoning keeps
/// appending to it; null when no run is open.
current_thinking: ?usize,
/// Index of the first block streamed for the current assistant message
/// (reasoning or answer), so a retry can drop the whole partial message; null
/// when none is streaming.
message_start: ?usize,

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{ .gpa = gpa, .entries = .empty, .current_model = null, .current_thinking = null, .message_start = null };
}

pub fn deinit(self: *Transcript) void {
    for (self.entries.items) |*entry| entry.deinit(self.gpa);
    self.entries.deinit(self.gpa);
}

/// Append a discrete block copying `text`; this ends any open streamed run, so
/// the next streamed delta opens a fresh block.
pub fn append(self: *Transcript, kind: ui.block.Entry.Kind, is_error: bool, text: []const u8) !void {
    self.endMessage();
    var entry = try ui.block.Entry.init(self.gpa, kind, is_error, text);
    errdefer entry.deinit(self.gpa);
    try self.entries.append(self.gpa, entry);
}

/// Append streamed answer text, opening a model block on demand so a run of
/// deltas collects into one block; ends any open reasoning run, since the answer
/// follows the reasoning.
pub fn appendModelText(self: *Transcript, delta: []const u8) !void {
    self.current_thinking = null;
    if (self.current_model == null) self.current_model = try self.openRun(.model);
    try self.entries.items[self.current_model.?].model.appendSlice(self.gpa, delta);
}

/// Append streamed reasoning text, opening a thinking block on demand so a run
/// of deltas collects into one block until the run ends.
pub fn appendThinkingText(self: *Transcript, delta: []const u8) !void {
    self.current_model = null;
    if (self.current_thinking == null) self.current_thinking = try self.openRun(.thinking);
    try self.entries.items[self.current_thinking.?].thinking.appendSlice(self.gpa, delta);
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
    self.current_model = null;
    self.current_thinking = null;
    self.message_start = null;
}

/// Drop the open message's streamed blocks (reasoning and answer alike) so a
/// reply being retried leaves nothing partial behind. A no-op when none is
/// streaming. The blocks are the contiguous tail from `message_start`, since
/// nothing discrete has ended the message.
pub fn discardMessage(self: *Transcript) void {
    const start = self.message_start orelse return;
    self.endMessage();
    var index = self.entries.items.len;
    while (index > start) : (index -= 1) self.entries.items[index - 1].deinit(self.gpa);
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

    try transcript.appendModelText("hel");
    try transcript.appendModelText("lo");
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);
    try std.testing.expectEqualStrings("hello", transcript.entries.items[0].model.items);

    try transcript.append(.user, false, "hi");
    try transcript.appendModelText("more");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries.items.len);
    try std.testing.expectEqualStrings("more", transcript.entries.items[2].model.items);
}

test "endMessage forces the next delta into a new block" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendModelText("a");
    transcript.endMessage();
    try transcript.appendModelText("b");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
}

test "discardMessage drops the open run so a retry starts clean" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.user, false, "hi");
    try transcript.appendModelText("partial");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);

    transcript.discardMessage();
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);

    try transcript.appendModelText("fresh");
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

    try transcript.appendThinkingText("weigh ");
    try transcript.appendThinkingText("it");
    try transcript.appendModelText("answer");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings("weigh it", transcript.entries.items[0].thinking.items);
    try std.testing.expectEqualStrings("answer", transcript.entries.items[1].model.items);
}

test "discard drops a partial message's reasoning and answer together" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.user, false, "hi");
    try transcript.appendThinkingText("thinking");
    try transcript.appendModelText("partial");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries.items.len);

    transcript.discardMessage();
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);

    try transcript.appendThinkingText("fresh");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings("fresh", transcript.entries.items[1].thinking.items);
}
