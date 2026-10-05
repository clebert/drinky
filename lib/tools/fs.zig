const std = @import("std");

const core = @import("core");

const output = @import("output.zig");

pub const file_bytes_max = 16 << 20;

const link_hops_max = 40;

const Options = struct {
    path: []const u8,
    data: []const u8,
};

pub fn readFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) std.Io.Dir.ReadFileAllocError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_bytes_max));
}

pub fn readFailure(
    gpa: std.mem.Allocator,
    err: std.Io.Dir.ReadFileAllocError,
    comptime verb: []const u8,
    path: []const u8,
) error{ Canceled, OutOfMemory }!core.Tool.Output {
    if (err == error.StreamTooLong) return output.failure(
        gpa,
        .path_too_large,
        "Drinky cannot " ++ verb ++ " {s} because it is larger than {d} bytes.",
        .{ path, file_bytes_max },
    );
    return output.cannot(gpa, err, "read", path);
}

pub fn writeFile(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !void {
    const dir = std.Io.Dir.cwd();
    const target = try resolveLinks(gpa, io, dir, options.path);
    defer gpa.free(target);
    const maybe_permissions: ?std.Io.File.Permissions = if (dir.statFile(io, target, .{})) |stat|
        stat.permissions
    else |err| switch (err) {
        error.FileNotFound => null,
        else => |other| return other,
    };
    var atomic = try dir.createFileAtomic(io, target, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, options.data);
    if (maybe_permissions) |permissions| try atomic.file.setPermissions(io, permissions);
    try atomic.replace(io);
}

fn resolveLinks(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var current = try gpa.dupe(u8, path);
    errdefer gpa.free(current);
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (0..link_hops_max) |_| {
        const link_len = dir.readLink(io, current, &link_buffer) catch |err| switch (err) {
            error.NotLink, error.FileNotFound => return current,
            else => |other| return other,
        };
        const link = link_buffer[0..link_len];
        const parent = if (std.fs.path.isAbsolute(link)) "" else std.fs.path.dirname(current);
        const next = try std.fs.path.join(gpa, &.{ parent orelse "", link });
        gpa.free(current);
        current = next;
    }
    return error.SymLinkLoop;
}
