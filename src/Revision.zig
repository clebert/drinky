//! The revision context of the latest canceled turn: where that turn stands in
//! the two canonical histories, and the user messages it took from the editor.
//! `App` owns at most one, only at the prompt, because the start of any turn
//! takes it. Only a turn that committed work leaves one, because an uncommitted
//! cancellation returns its prompt at once. Ctrl+N removes the turn from both
//! histories and puts the messages back into the editor as editable text. The
//! removal undoes no tool effect and no billed usage.

const std = @import("std");

const ai = @import("ai");

const ui = @import("ui/root.zig");

const Revision = @This();

/// Where the turn stands in the agent history: from the length before it
/// appended its first message to the length after the cancellation rolled it
/// back to its last checkpoint. The rewind expects the history to end there
/// still.
history: ai.Agent.HistorySpan,
/// The transcript length before the turn appended its first block.
transcript_base: usize,
/// The transcript length after the cancellation event. The blocks of the turn
/// stand in `[transcript_base, transcript_end)`.
transcript_end: usize,
/// The rich draft of the prompt that started the turn. Owned.
prompt: ui.Editor.Draft,
/// The rich drafts of the steering messages that the turn committed, in
/// submission order. Owned.
steering: std.ArrayList(ui.Editor.Draft),
/// Whether the turn committed a call of a tool that changes the system. Such a
/// call stays in effect after the removal, so the removal warns first.
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
