const std = @import("std");

gpa: std.mem.Allocator,
host: Host,

pub const Error = error{ Canceled, OutOfMemory, WriteFailed, InvalidArguments };

pub const Host = struct {
    io: std.Io,
    environ: std.process.Environ = .empty,
    bash: Bash = .{},
    search: Search = .{},
    document: []const u8 = "",
};

pub const Bash = struct {
    lines_max: usize = 2000,
    bytes_max: usize = 50 * 1024,
    timeout_ms: u64 = 120_000,

    pub const timeout_ms_min = 1_000;
    pub const timeout_ms_max = 60 * std.time.ms_per_min;
};

const Search = struct {
    entries_max: usize = 1_000_000,
    bytes_read_max: usize = 256 << 20,
};
