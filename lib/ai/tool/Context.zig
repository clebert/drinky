const std = @import("std");

const llm = @import("../llm.zig");
const SkillGuard = @import("SkillGuard.zig");

gpa: std.mem.Allocator,
io: std.Io,
environ: std.process.Environ = .empty,
bash: Bash = .{},
document: []const u8 = "",
skill_guard: ?*SkillGuard = null,
history: []const llm.Item = &.{},

pub const Bash = struct {
    lines_max: usize = 2000,
    bytes_max: usize = 50 * 1024,
    timeout_ms: u64 = 120_000,

    pub const timeout_ms_min = 1_000;
    pub const timeout_ms_max = 60 * std.time.ms_per_min;

    pub fn clampTimeoutMs(timeout_ms: u64) u64 {
        return std.math.clamp(timeout_ms, timeout_ms_min, timeout_ms_max);
    }
};

test "clampTimeoutMs holds every value inside the legal window" {
    try std.testing.expectEqual(@as(u64, Bash.timeout_ms_min), Bash.clampTimeoutMs(0));
    try std.testing.expectEqual(@as(u64, Bash.timeout_ms_min), Bash.clampTimeoutMs(1));
    try std.testing.expectEqual(@as(u64, 5_000), Bash.clampTimeoutMs(5_000));
    try std.testing.expectEqual(
        @as(u64, Bash.timeout_ms_max),
        Bash.clampTimeoutMs(std.math.maxInt(u64)),
    );
}
