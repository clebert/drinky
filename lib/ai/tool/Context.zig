//! The ambient state handed to every tool handler. It grows as tools need more
//! of the session (a working directory, a provider handle for subagents,
//! cancellation) without a change to any handler signature. A handler reads the
//! fields it needs.

const std = @import("std");

const llm = @import("../llm.zig");
const SkillGuard = @import("SkillGuard.zig");

gpa: std.mem.Allocator,
io: std.Io,
/// Each bash command inherits this process environment. The host owns it for the session.
/// Tests can use an empty environment.
environ: std.process.Environ = .empty,
/// Bounds the bash tool: how much of a command's output survives, and how long
/// a command runs before Drinky kills it. The defaults hold when no config
/// overrides them.
bash: Bash = .{},
/// The document that describes the harness itself, which the `describe_drinky`
/// tool hands back. The host writes it and owns it, so the tool stays free of
/// any app-specific knowledge. An empty document means the host describes
/// nothing, and the tool reports that.
document: []const u8 = "",
/// The path-triggered skill rules of the session, or null when the host applies
/// none. A tool that writes a file asks the guard first. The host owns the guard
/// and its rules.
skill_guard: ?*SkillGuard = null,
/// The conversation below the reply that asked for this call. The guard proves
/// a loaded skill against it. The reply itself stays out, so a skill that one
/// reply reads cannot license a write that the same reply already asked for.
/// The slice is valid for the duration of the call.
history: []const llm.Item = &.{},

pub const Bash = struct {
    /// The whole lines kept from the tail of a command's output.
    lines_max: usize = 2000,
    /// The bytes kept from the tail of a command's output.
    bytes_max: usize = 50 * 1024,
    /// The default wall-clock timeout a command runs under, in milliseconds. A
    /// per-call `timeout_seconds` overrides it, inside the window below.
    timeout_ms: u64 = 120_000,

    /// The smallest timeout a command can run under. A command that ends at once
    /// still needs a window that a slow start fits in.
    pub const timeout_ms_min = 1_000;
    /// The largest timeout a command can run under. Every command runs under a
    /// limit, because a command that never ends holds the turn and the user with
    /// it. One hour covers a long build and still ends by itself.
    pub const timeout_ms_max = 60 * std.time.ms_per_min;

    /// Hold a timeout inside the legal window. The config and the per-call
    /// argument both pass through this, so no path can disable the limit or
    /// state a span the display cannot measure.
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
