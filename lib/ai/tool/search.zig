const std = @import("std");

const Result = @import("Result.zig");

pub const timeout_ms = 10 * std.time.ms_per_s;

pub const Timer = struct {
    io: std.Io,
    started_ms: i64,

    pub fn start(io: std.Io) Timer {
        return .{ .io = io, .started_ms = nowMs(io) };
    }

    pub fn startedAgo(io: std.Io, elapsed_ms: i64) Timer {
        return .{ .io = io, .started_ms = nowMs(io) - elapsed_ms };
    }

    pub fn elapsedMs(self: *const Timer) i64 {
        return nowMs(self.io) - self.started_ms;
    }

    pub fn spent(self: *const Timer) bool {
        return self.elapsedMs() >= timeout_ms;
    }

    fn nowMs(io: std.Io) i64 {
        return std.Io.Timestamp.now(io, .awake).toMilliseconds();
    }
};

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

    const stopped: Timer = .startedAgo(io, timeout_ms);
    try std.testing.expect(stopped.elapsedMs() >= timeout_ms);
    try std.testing.expect(stopped.spent());
}
