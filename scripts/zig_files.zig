const std = @import("std");

const entries_max = 10_000;

pub fn collect(
    arena: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (roots) |root| try collectRoot(arena, io, root, &paths);
    std.mem.sort([]const u8, paths.items, {}, pathLessThan);
    return paths.items;
}

fn collectRoot(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    paths: *std.ArrayList([]const u8),
) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, root, .{});
    if (stat.kind != .directory) return paths.append(arena, root);

    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    for (0..entries_max) |_| {
        const entry = (try walker.next(io)) orelse return;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        try paths.append(arena, try std.Io.Dir.path.join(arena, &.{ root, entry.path }));
    }
    return error.TooManyEntries;
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
