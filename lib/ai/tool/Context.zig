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
/// What the `config` tool hands back. The host writes both strings and owns
/// them, so the tool stays free of any app-specific knowledge.
settings: Settings = .{},

pub const Settings = struct {
    /// The document that describes every setting. Empty means the host exposes
    /// no settings, and the tool reports that.
    document: []const u8 = "",
    /// The one-line box summary, a `Key: Value` fragment that names what the
    /// document covers. A multi-line result must carry one, because the box
    /// otherwise falls back to the first line of the document.
    summary: []const u8 = "",
};

pub const Bash = struct {
    /// The whole lines kept from the tail of a command's output.
    lines_max: usize = 2000,
    /// The bytes kept from the tail of a command's output.
    bytes_max: usize = 50 * 1024,
    /// The default wall-clock budget a command runs under, in milliseconds. A
    /// per-call `timeout_seconds` overrides it, and 0 means no limit.
    timeout_ms: u64 = 120_000,
};
