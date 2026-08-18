//! The ambient state handed to every tool handler. It grows as tools need more
//! of the session (a working directory, a provider handle for subagents,
//! cancellation) without a change to any handler signature. A handler reads the
//! fields it needs.

const std = @import("std");

gpa: std.mem.Allocator,
io: std.Io,
/// Bounds the bash tool: how much of a command's output survives, and how long
/// a command runs before Pith kills it. The defaults hold when no config
/// overrides them.
bash: Bash = .{},
/// The document that describes every config key, which the `describe_config`
/// tool hands back. The host writes it and owns it, so the tool stays free of
/// any app-specific knowledge. An empty document means the host exposes no
/// config, and the tool reports that.
config_document: []const u8 = "",

pub const Bash = struct {
    /// The whole lines kept from the tail of a command's output.
    lines_max: usize = 2000,
    /// The bytes kept from the tail of a command's output.
    bytes_max: usize = 50 * 1024,
    /// The default wall-clock timeout a command runs under, in milliseconds. A
    /// per-call `timeout_seconds` overrides it, and 0 means no limit.
    timeout_ms: u64 = 120_000,
};
