//! What both search tools share: the wall itself, the timer of one run, and
//! the check that proves the box line of a finished search.

const std = @import("std");

const Result = @import("Result.zig");

/// The wall-clock timeout of one search, in milliseconds. A search of a whole
/// repository stays far below it. The interface reads the same value, because
/// neither a call nor the config changes it.
pub const timeout_ms = 30 * std.time.ms_per_s;

/// The clock of one run: when it started, and whether its time is spent.
///
/// The checks are cooperative and cheap: a walk checks the clock after a
/// filesystem step, and `grep` checks it before each file after the first. The
/// walk keeps its first entry and `grep` reads its first file, so a stopped
/// search still holds evidence. A filesystem operation that blocks inside a
/// system call escapes every cooperative check, and the turn ends when the
/// user cancels it, the way a blocked `read` ends.
///
/// The timer holds the io that started it, so every span of one run reads on
/// one clock.
pub const Timer = struct {
    io: std.Io,
    /// The time on the awake clock when the search started, in milliseconds.
    started_ms: i64,

    /// A timer that starts now.
    pub fn start(io: std.Io) Timer {
        return .{ .io = io, .started_ms = nowMs(io) };
    }

    /// A timer that started `elapsed_ms` ago. A caller states a span it wants to
    /// have passed already, rather than an instant on a clock it cannot see.
    pub fn startedAgo(io: std.Io, elapsed_ms: i64) Timer {
        return .{ .io = io, .started_ms = nowMs(io) - elapsed_ms };
    }

    /// The time the search has run, in milliseconds.
    pub fn elapsedMs(self: *const Timer) i64 {
        return nowMs(self.io) - self.started_ms;
    }

    /// Whether the timeout is spent.
    pub fn spent(self: *const Timer) bool {
        return self.elapsedMs() >= timeout_ms;
    }

    fn nowMs(io: std.Io) i64 {
        return std.Io.Timestamp.now(io, .awake).toMilliseconds();
    }
};

/// Prove the whole box line of a finished search. The run time varies with the
/// machine, so the check reads past that one field and pins every field behind
/// it.
pub fn expectMeasures(summary: Result.Summary, expected: []const u8) !void {
    const separator = " · ";
    try std.testing.expectEqual(Result.Summary.Kind.measures, summary.kind);
    try std.testing.expectStringStartsWith(summary.text, "Time: ");
    const gap = std.mem.indexOf(u8, summary.text, separator) orelse return error.MissingMeasures;
    try std.testing.expectEqualStrings(expected, summary.text[gap + separator.len ..]);
}

test Timer {
    const io = std.testing.io;
    const running: Timer = .start(io);
    try std.testing.expect(running.elapsedMs() >= 0);
    try std.testing.expect(!running.spent());

    // A search that started one full timeout ago sees a spent clock at its
    // first check.
    const stopped: Timer = .startedAgo(io, timeout_ms);
    try std.testing.expect(stopped.elapsedMs() >= timeout_ms);
    try std.testing.expect(stopped.spent());
}
