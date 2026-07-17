//! Walks a directory tree collecting the regular files whose base-relative path
//! matches a glob, skipping version-control and build-cache directories. Shared
//! by the `find` and `grep` tools.

const std = @import("std");

const glob = @import("glob.zig");

const noise_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out" };

/// Regular-file paths under `options.base` whose base-relative path matches
/// `options.pattern`, returned sorted, relative to the working directory, and
/// owned by `arena`. An unreadable directory is skipped and the walk keeps
/// going; cancellation stops it at once, because Zig cancellation is one-shot,
/// so resuming the walk would perform real traversal I/O the aborted turn no
/// longer wants. Either way the walker's open directory handles are released
/// before returning — its `deinit` does not close them.
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
    walk: while (true) {
        const entry = (walker.next(io) catch |err| switch (err) {
            // Cancellation aborts the turn, so stop the walk at once: it is
            // one-shot, and resuming would do real traversal I/O. Any other
            // iteration error skips the bad directory (the walker has already
            // closed it) and keeps the walk resilient.
            error.Canceled => {
                failure = err;
                break :walk;
            },
            else => continue,
        }) orelse break;
        switch (entry.kind) {
            .directory => {
                if (isNoise(entry.basename)) continue;
                walker.enter(io, entry) catch |err| switch (err) {
                    error.Canceled => {
                        failure = err;
                        break :walk;
                    },
                    else => {},
                };
            },
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
    // Release directory handles still open on the walker stack: `deinit` frees
    // its memory but not its handles. A completed walk has already drained the
    // stack; a walk stopped by cancellation leaves entered subdirectories open,
    // so close them here. `leave` never closes the base directory, which `dir`
    // closes on return.
    while (walker.stack.items.len > 0) walker.leave(io);
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

// Wraps a real io, failing one directory syscall with an injected error to model
// a failure mid-walk, then counting the traversal opens and reads that follow
// it. Zig cancellation is one-shot: the injected error is delivered once, so a
// walk that keeps traversing afterward does real I/O the counter catches.
// Directory closes are cleanup and never counted, and the open/close balance
// proves every opened handle was released.
const FaultyIo = struct {
    backend: std.Io,
    vtable: std.Io.VTable,
    trigger: Trigger,
    inject: anyerror,
    opens: usize = 0,
    injected: bool = false,
    traversal_after_inject: usize = 0,
    open_handles: usize = 0,

    // Which syscall to fail, exercising each production cancellation site: the
    // `enter` open and the `next` read.
    const Trigger = union(enum) {
        // Fail the Nth `dirOpenDir` (1-based); the base opens first, so 2 is the
        // first entered subdirectory.
        open_call: usize,
        // Fail the first `dirRead` taken once at least this many directories are
        // open, i.e. while reading inside an entered subdirectory.
        subdir_read: usize,
    };

    fn init(backend: std.Io, options: struct {
        trigger: Trigger,
        inject: anyerror,
    }) FaultyIo {
        var vtable = backend.vtable.*;
        vtable.dirOpenDir = openDir;
        vtable.dirRead = read;
        vtable.dirClose = close;
        return .{
            .backend = backend,
            .vtable = vtable,
            .trigger = options.trigger,
            .inject = options.inject,
        };
    }

    fn io(self: *FaultyIo) std.Io {
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn openDir(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.OpenOptions,
    ) std.Io.Dir.OpenError!std.Io.Dir {
        const self: *FaultyIo = @ptrCast(@alignCast(userdata));
        self.opens += 1;
        if (self.injected) {
            self.traversal_after_inject += 1;
        } else switch (self.trigger) {
            .open_call => |n| if (self.opens == n) {
                self.injected = true;
                return @errorCast(self.inject);
            },
            .subdir_read => {},
        }
        const result = try self.backend.vtable.dirOpenDir(self.backend.userdata, dir, path, options);
        self.open_handles += 1;
        return result;
    }

    fn read(
        userdata: ?*anyopaque,
        reader: *std.Io.Dir.Reader,
        entries: []std.Io.Dir.Entry,
    ) std.Io.Dir.Reader.Error!usize {
        const self: *FaultyIo = @ptrCast(@alignCast(userdata));
        if (self.injected) {
            self.traversal_after_inject += 1;
        } else switch (self.trigger) {
            .subdir_read => |n| if (self.open_handles >= n) {
                self.injected = true;
                return @errorCast(self.inject);
            },
            .open_call => {},
        }
        return self.backend.vtable.dirRead(self.backend.userdata, reader, entries);
    }

    fn close(userdata: ?*anyopaque, dirs: []const std.Io.Dir) void {
        const self: *FaultyIo = @ptrCast(@alignCast(userdata));
        self.open_handles -= dirs.len;
        self.backend.vtable.dirClose(self.backend.userdata, dirs);
    }
};

test "collect stops walking when an entered directory is cancelled" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    // The base opens first; failing the second open cancels the first entered
    // subdirectory (the `enter` site) while its siblings still await traversal.
    var faulty: FaultyIo = .init(threaded.io(), .{
        .trigger = .{ .open_call = 2 },
        .inject = error.Canceled,
    });
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.Canceled, collect(
        faulty.io(),
        arena_state.allocator(),
        .{ .base = "lib", .pattern = "**" },
    ));
    try std.testing.expectEqual(@as(usize, 0), faulty.traversal_after_inject);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}

test "collect stops walking when a subdirectory read is cancelled" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    // Cancel a read taken with the base and one subdirectory open (the `next`
    // site), so an ancestor and unvisited siblings remain.
    var faulty: FaultyIo = .init(threaded.io(), .{
        .trigger = .{ .subdir_read = 2 },
        .inject = error.Canceled,
    });
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.Canceled, collect(
        faulty.io(),
        arena_state.allocator(),
        .{ .base = "lib", .pattern = "**" },
    ));
    try std.testing.expectEqual(@as(usize, 0), faulty.traversal_after_inject);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}

test "collect skips an unreadable directory and keeps walking" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var faulty: FaultyIo = .init(threaded.io(), .{
        .trigger = .{ .open_call = 2 },
        .inject = error.AccessDenied,
    });
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const files = try collect(
        faulty.io(),
        arena_state.allocator(),
        .{ .base = "lib", .pattern = "**/*.zig" },
    );
    // An ordinary error is not an abort: the walk skips the subtree, traverses
    // its siblings, and still returns their files with every handle released.
    try std.testing.expect(files.len > 0);
    try std.testing.expect(faulty.traversal_after_inject > 0);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}
