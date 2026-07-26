//! Ambient state handed to every tool handler. Grows as tools need more of the
//! session (a working directory, a provider handle for subagents, cancellation)
//! without changing any handler signature — a handler reads the fields it needs.

const std = @import("std");

gpa: std.mem.Allocator,
io: std.Io,
/// Bounds the bash tool: how much of a command's output survives, and how long
/// a command runs before it is killed. Defaults hold when no config overrides.
bash: Bash = .{},

pub const Bash = struct {
    /// Whole lines kept from the tail of a command's output.
    lines_max: usize = 2000,
    /// Bytes kept from the tail of a command's output.
    bytes_max: usize = 50 * 1024,
    /// Default wall-clock budget a command runs under, in milliseconds; a
    /// per-call `timeout_seconds` overrides it, and 0 means no limit.
    timeout_ms: u64 = 120_000,
};
