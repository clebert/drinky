const std = @import("std");

const ai = @import("ai");

const ui = @import("ui/root.zig");

const Revision = @This();

history: ai.Agent.HistorySpan,
transcript_base: usize,
transcript_end: usize,
prompt: ui.Editor.Draft,
steering: std.ArrayList(ui.Editor.Draft),
mutated: bool,

pub fn deinit(self: *Revision, gpa: std.mem.Allocator) void {
    self.prompt.deinit(gpa);
    for (self.steering.items) |*draft| draft.deinit(gpa);
    self.steering.deinit(gpa);
}

test "the context frees its prompt and every steering draft" {
    const gpa = std.testing.allocator;
    var steering: std.ArrayList(ui.Editor.Draft) = .empty;
    try steering.append(gpa, try ui.Editor.Draft.fromText(gpa, "and test"));
    var revision: Revision = .{
        .history = .{ .base = 1, .end = 4 },
        .transcript_base = 2,
        .transcript_end = 6,
        .prompt = try ui.Editor.Draft.fromText(gpa, "fix it"),
        .steering = steering,
        .mutated = false,
    };
    defer revision.deinit(gpa);
    try std.testing.expectEqualStrings("fix it", revision.prompt.visible.items);
    try std.testing.expectEqual(@as(usize, 1), revision.steering.items.len);
}
