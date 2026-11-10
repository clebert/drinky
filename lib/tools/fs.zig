const std = @import("std");

const core = @import("core");

const output = @import("output.zig");
const Sandbox = @import("Sandbox.zig");

pub const file_bytes_max = 16 << 20;
pub const timeout_ms = 10 * std.time.ms_per_s;

const timeout_seconds = @divExact(timeout_ms, std.time.ms_per_s);
const link_hops_max = 40;

const Options = struct {
    path: []const u8,
    data: []const u8,
    sandbox: ?*const Sandbox,
};

pub const ReadError = std.Io.Dir.ReadFileAllocError || Bound;

const WriteError = WholeWriteError || Bound;

const WholeWriteError = ResolveError ||
    std.Io.Dir.RealPathFileAllocError ||
    error{OutsideSandbox} ||
    std.Io.Dir.StatFileError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.SetPermissionsError ||
    std.Io.File.Atomic.ReplaceError;

const ResolveError = std.Io.Dir.ReadLinkError || error{ OutOfMemory, SymLinkLoop };

const Bound = error{ Timeout, ConcurrencyUnavailable };

pub fn readFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: *const core.timeout.Deadline,
    path: []const u8,
) ReadError![]u8 {
    return deadline.run(io, readWhole, .{ gpa, io, path }, releaseWhole);
}

pub fn readFailure(
    gpa: std.mem.Allocator,
    err: ReadError,
    comptime verb: []const u8,
    path: []const u8,
) error{ Canceled, OutOfMemory }!core.Tool.Output {
    return switch (err) {
        error.StreamTooLong => output.failure(
            gpa,
            .path_too_large,
            "Drinky cannot " ++ verb ++ " {s} because it is larger than {d} bytes.",
            .{ path, file_bytes_max },
        ),
        error.Timeout => output.failure(
            gpa,
            .timed_out,
            "Drinky could not read {s} because the file system did not respond within {d} " ++
                "seconds.",
            .{ path, timeout_seconds },
        ),
        else => output.cannot(gpa, err, "read", path),
    };
}

pub fn writeFailure(
    gpa: std.mem.Allocator,
    err: WriteError,
    path: []const u8,
) error{ Canceled, OutOfMemory }!core.Tool.Output {
    if (err == error.Timeout) return output.failure(
        gpa,
        .timed_out,
        "Drinky stopped the write of {s} after {d} seconds because the file system did not " ++
            "respond. The file can hold the old or the new content.",
        .{ path, timeout_seconds },
    );
    if (err == error.OutsideSandbox) return output.failure(
        gpa,
        .failed,
        "Drinky cannot write {s} because the path is outside the sandbox.",
        .{path},
    );
    return output.cannot(gpa, err, "write", path);
}

pub fn writeFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: *const core.timeout.Deadline,
    options: *const Options,
) WriteError!void {
    return deadline.run(io, writeWhole, .{ gpa, io, options }, null);
}

fn readWhole(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) std.Io.Dir.ReadFileAllocError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_bytes_max));
}

fn releaseWhole(data: *const []u8, args: *const std.meta.ArgsTuple(@TypeOf(readWhole))) void {
    args[0].free(data.*);
}

fn writeWhole(gpa: std.mem.Allocator, io: std.Io, options: *const Options) WholeWriteError!void {
    const dir = std.Io.Dir.cwd();
    const target = try resolveLinks(gpa, io, dir, options.path);
    defer gpa.free(target);
    if (options.sandbox) |sandbox| try checkSandbox(gpa, io, sandbox, target);
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

fn checkSandbox(
    gpa: std.mem.Allocator,
    io: std.Io,
    sandbox: *const Sandbox,
    target: []const u8,
) (std.Io.Dir.RealPathFileAllocError || error{OutsideSandbox})!void {
    const parent = std.Io.Dir.path.dirname(target) orelse ".";
    const real_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, parent, gpa);
    defer gpa.free(real_parent);
    const real_target = try std.Io.Dir.path.join(
        gpa,
        &.{ real_parent, std.Io.Dir.path.basename(target) },
    );
    defer gpa.free(real_target);
    if (!sandbox.allows(real_target)) return error.OutsideSandbox;
}

fn resolveLinks(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ResolveError![]u8 {
    var current = try gpa.dupe(u8, path);
    errdefer gpa.free(current);
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (0..link_hops_max) |_| {
        const link_len = dir.readLink(io, current, &link_buffer) catch |err| switch (err) {
            error.NotLink, error.FileNotFound => return current,
            else => |other| return other,
        };
        const link = link_buffer[0..link_len];
        const parent = if (std.Io.Dir.path.isAbsolute(link))
            ""
        else
            std.Io.Dir.path.dirname(current);
        const next = try std.Io.Dir.path.join(gpa, &.{ parent orelse "", link });
        gpa.free(current);
        current = next;
    }
    return error.SymLinkLoop;
}
