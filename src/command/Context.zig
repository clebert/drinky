//! Ambient state handed to every slash-command handler. Carries the session's
//! agent so a command can read and reconfigure it, mirroring the tool Context —
//! it grows as commands need more of the session without changing any handler
//! signature.

const std = @import("std");

const Agent = @import("../Agent.zig");

gpa: std.mem.Allocator,
agent: *Agent,
