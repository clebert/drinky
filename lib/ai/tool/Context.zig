//! The ambient state handed to every tool handler. It grows as tools need more
//! of the session (a working directory, a provider handle for subagents,
//! cancellation) without a change to any handler signature. A handler reads the
//! fields it needs.

const std = @import("std");

const llm = @import("../llm.zig");
const SkillGuard = @import("SkillGuard.zig");

gpa: std.mem.Allocator,
io: std.Io,
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
    /// The literal patterns that deny a command. The bash tool refuses a
    /// command that contains one of them, so the user can fence off a habit
    /// such as `git add`. The host owns the strings.
    deny: []const []const u8 = &.{},

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

    /// The first configured pattern that `command` contains, or null when no
    /// pattern denies it. An empty pattern denies nothing, so a stray empty
    /// entry cannot deny every command.
    pub fn denies(self: *const Bash, command: []const u8) ?[]const u8 {
        for (self.deny) |pattern| {
            if (pattern.len == 0) continue;
            if (std.mem.indexOf(u8, command, pattern) != null) return pattern;
        }
        return null;
    }
};

test "denies reports the first matching pattern and skips an empty one" {
    const deny = [_][]const u8{ "", "git add", "git push" };
    const bash: Bash = .{ .deny = &deny };
    try std.testing.expectEqualStrings("git add", bash.denies("git add -A").?);
    try std.testing.expectEqualStrings("git push", bash.denies("git push --force").?);
    try std.testing.expect(bash.denies("git status") == null);
    // An empty pattern sits inside every command, so the match must skip it.
    try std.testing.expect(bash.denies("echo ok") == null);
    const unguarded: Bash = .{};
    try std.testing.expect(unguarded.denies("git add -A") == null);
}

test "clampTimeoutMs holds every value inside the legal window" {
    try std.testing.expectEqual(@as(u64, Bash.timeout_ms_min), Bash.clampTimeoutMs(0));
    try std.testing.expectEqual(@as(u64, Bash.timeout_ms_min), Bash.clampTimeoutMs(1));
    try std.testing.expectEqual(@as(u64, 5_000), Bash.clampTimeoutMs(5_000));
    try std.testing.expectEqual(
        @as(u64, Bash.timeout_ms_max),
        Bash.clampTimeoutMs(std.math.maxInt(u64)),
    );
}
