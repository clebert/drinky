//! Walks a directory tree collecting the regular files whose base-relative path
//! matches a glob, skipping version-control and build-cache directories. Shared
//! by the `find` and `grep` tools.

const std = @import("std");

const glob = @import("glob.zig");

const noise_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out" };

/// Regular-file paths under `options.base` whose base-relative path matches
/// `options.pattern`, returned sorted, relative to the working directory, and
/// owned by `arena`. The walk always drains — even on I/O or allocation failure
/// — so the walker's open directory handles are released (its `deinit` does not
/// close them).
pub fn collect(
    io: std.Io,
    arena: std.mem.Allocator,
    options: struct { base: []const u8, pattern: []const u8 },
) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, options.base, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    var failure: ?anyerror = null;
    const at_root = std.mem.eql(u8, options.base, ".");
    // Drain the whole tree even on errors so the walker's directory handles are
    // released: `next` closes the directory it fails on, and skipping an
    // unreadable subdirectory leaves its ancestors on the stack to be closed as
    // the walk completes.
    while (true) {
        const entry = (walker.next(io) catch continue) orelse break;
        switch (entry.kind) {
            .directory => if (!isNoise(entry.basename)) walker.enter(io, entry) catch {},
            .file => {
                if (failure != null or !glob.match(.{ .pattern = options.pattern, .path = entry.path })) continue;
                const relative = if (at_root)
                    arena.dupe(u8, entry.path)
                else
                    std.fmt.allocPrint(arena, "{s}/{s}", .{ options.base, entry.path });
                const owned = relative catch |err| {
                    failure = err;
                    continue;
                };
                files.append(arena, owned) catch |err| {
                    failure = err;
                };
            },
            else => {},
        }
    }
    if (failure) |err| return err;
    const result = try files.toOwnedSlice(arena);
    std.mem.sort([]const u8, result, {}, lessThan);
    return result;
}

fn isNoise(basename: []const u8) bool {
    for (noise_dirs) |noise| {
        if (std.mem.eql(u8, basename, noise)) return true;
    }
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
