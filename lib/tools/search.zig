const std = @import("std");

const core = @import("core");

pub const timeout_ms = 10 * std.time.ms_per_s;

pub const Timer = struct {
    io: std.Io,
    started_ms: i64,

    pub fn start(io: std.Io) Timer {
        return .{ .io = io, .started_ms = nowMs(io) };
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

pub fn matchNoun(count: usize) []const u8 {
    return if (count == 1) "match" else "matches";
}

pub fn timeoutNote(comptime narrowed: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "A search stops after {d} seconds and returns the matches that it found. Narrow the " ++
            "path or the {s} to search less.",
        .{ @divExact(timeout_ms, std.time.ms_per_s), narrowed },
    );
}

test "a timer is spent once the search timeout has passed" {
    var clock: core.testing.StepClock = undefined;
    clock.init(std.testing.allocator, timeout_ms - 1);
    defer clock.deinit();
    const stepped: Timer = .start(clock.io());
    try std.testing.expect(!stepped.spent());
    try std.testing.expect(stepped.spent());
}
