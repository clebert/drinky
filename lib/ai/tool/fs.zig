//! Filesystem helpers shared by the mutating tools.

const std = @import("std");

/// Create or replace `sub_path` with `data` atomically: the bytes are written
/// to a temporary file in the same directory that is then renamed over the
/// destination, so a cancelled or crashed write leaves the existing file
/// untouched rather than truncated.
pub fn writeFile(io: std.Io, dir: std.Io.Dir, options: Options) !void {
    var atomic = try dir.createFileAtomic(io, options.sub_path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, options.data);
    try atomic.replace(io);
}

pub const Options = struct {
    sub_path: []const u8,
    data: []const u8,
};
