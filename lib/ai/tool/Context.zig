//! Ambient state handed to every tool handler. Grows as tools need more of the
//! session (a working directory, a provider handle for subagents, cancellation)
//! without changing any handler signature — a handler reads the fields it needs.

const std = @import("std");

gpa: std.mem.Allocator,
io: std.Io,
