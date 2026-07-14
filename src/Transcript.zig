//! The permanent blocks above the live tail, oldest first, plus the "model run"
//! invariant: a run of streamed text collects into one growing model block until
//! a tool call, a turn boundary, or any other block ends it. Owns its blocks'
//! bytes (freed on `deinit`).

const std = @import("std");

const ui = @import("ui/root.zig");

const Transcript = @This();

gpa: std.mem.Allocator,
entries: std.ArrayList(ui.block.Entry),
/// Index of the model-text block for the current run, so streamed deltas keep
/// appending to it; null when no run is open.
current_model: ?usize,

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{ .gpa = gpa, .entries = .empty, .current_model = null };
}

pub fn deinit(self: *Transcript) void {
    for (self.entries.items) |*entry| entry.deinit(self.gpa);
    self.entries.deinit(self.gpa);
}

/// Append a discrete block copying `text`; this ends any open model run, so the
/// next streamed delta opens a fresh block.
pub fn append(self: *Transcript, kind: ui.block.Entry.Kind, is_error: bool, text: []const u8) !void {
    self.current_model = null;
    var entry = try ui.block.Entry.init(self.gpa, kind, is_error, text);
    errdefer entry.deinit(self.gpa);
    try self.entries.append(self.gpa, entry);
}

/// Append streamed model text, opening a model block on demand so a run of deltas
/// collects into one block until the run ends.
pub fn appendModelText(self: *Transcript, delta: []const u8) !void {
    if (self.current_model == null) {
        var entry = try ui.block.Entry.init(self.gpa, .model, false, "");
        errdefer entry.deinit(self.gpa);
        try self.entries.append(self.gpa, entry);
        self.current_model = self.entries.items.len - 1;
    }
    try self.entries.items[self.current_model.?].model.appendSlice(self.gpa, delta);
}

/// End the current model run so the next streamed delta opens a new block.
pub fn endModelRun(self: *Transcript) void {
    self.current_model = null;
}

/// Drop the open model run and free its block, so a reply being retried leaves
/// no partial text behind. A no-op when no run is open. The open run is always
/// the last entry, since nothing discrete has ended it.
pub fn discardModelRun(self: *Transcript) void {
    const index = self.current_model orelse return;
    self.current_model = null;
    var entry = self.entries.orderedRemove(index);
    entry.deinit(self.gpa);
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

test "endModelRun forces the next delta into a new block" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendModelText("a");
    transcript.endModelRun();
    try transcript.appendModelText("b");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
}

test "discardModelRun drops the open run so a retry starts clean" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.user, false, "hi");
    try transcript.appendModelText("partial");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);

    transcript.discardModelRun();
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);

    try transcript.appendModelText("fresh");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings("fresh", transcript.entries.items[1].model.items);

    // A no-op when no run is open.
    transcript.endModelRun();
    transcript.discardModelRun();
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
}
