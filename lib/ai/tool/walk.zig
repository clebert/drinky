//! Walks a directory tree collecting the regular files whose base-relative path
//! matches a glob, skipping version-control and build-cache directories. Shared
//! by the `find` and `grep` tools.

const std = @import("std");

const glob = @import("glob.zig");

const noise_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out" };

/// Hard cap on directory entries examined in one walk, so an adversarial or
/// accidentally huge tree cannot make traversal run unbounded. High enough that
/// real repositories never reach it (noise directories are skipped), and each
/// visit is cheap, so erring high only risks time, never correctness.
pub const entries_visited_max = 1_000_000;

/// The matches a walk retained, owned by the caller's `gpa`.
pub const Match = struct {
    /// The lexicographically-smallest matches, sorted ascending, at most
    /// `retain` of them.
    paths: [][]const u8,
    /// Total matches seen — a lower bound when `capped`, since the walk stopped
    /// early. `matched > paths.len` means matches were found but not retained.
    matched: usize,
    /// Whether the walk stopped at its entry-visit cap (`entries_max`) before
    /// exhausting the tree, so `paths` depends on filesystem enumeration order
    /// and is incomplete.
    capped: bool,

    pub fn deinit(self: *Match, gpa: std.mem.Allocator) void {
        for (self.paths) |path| gpa.free(path);
        gpa.free(self.paths);
        self.* = undefined;
    }
};

/// The lexicographically-smallest matches under `options.base` whose
/// base-relative path matches `options.pattern`, each relative to the working
/// directory. Memory is bounded: only the smallest `options.retain` matches are
/// retained (via a max-heap that evicts and frees larger paths), while the
/// total is merely counted, so a caller needing only a few results never
/// retains the whole tree. Time is bounded by `options.entries_max`. When the
/// tree is fully traversed the result is byte-identical to sorting every match;
/// when the entry cap stops it first, the result is flagged `capped`.
///
/// An unreadable directory is skipped and the walk keeps going; cancellation
/// stops it at once, because Zig cancellation is one-shot, so resuming the walk
/// would perform real traversal I/O the aborted turn no longer wants. Every
/// exit — success, cancellation, or error — releases the walker's open
/// directory handles (its `deinit` does not close them) and frees any retained
/// paths.
pub fn collect(
    io: std.Io,
    gpa: std.mem.Allocator,
    options: struct {
        base: []const u8,
        pattern: []const u8,
        retain: usize,
        entries_max: usize = entries_visited_max,
    },
) !Match {
    var dir = try std.Io.Dir.cwd().openDir(io, options.base, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var keeper: Keeper = .{ .retain = options.retain };
    errdefer keeper.deinit(gpa);

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);

    const at_root = std.mem.eql(u8, options.base, ".");
    var failure: ?anyerror = null;
    var visited: usize = 0;
    var capped = false;
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
        // Stop only once a further entry proves the tree is not exhausted, so a
        // tree with exactly `entries_max` entries is not falsely flagged.
        if (visited >= options.entries_max) {
            capped = true;
            break :walk;
        }
        visited += 1;
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
                if (!glob.match(.{ .pattern = options.pattern, .path = entry.path })) continue;
                // Route allocation failure through `failure` rather than a bare
                // `try` so the stack-draining cleanup below still runs.
                record(gpa, &keeper, &path_buf, .{
                    .base = options.base,
                    .at_root = at_root,
                    .path = entry.path,
                }) catch |err| {
                    failure = err;
                    break :walk;
                };
            },
            else => {},
        }
    }
    // Release directory handles still open on the walker stack: `deinit` frees
    // its memory but not its handles. A completed walk has already drained the
    // stack; a walk stopped by cancellation or the entry cap leaves entered
    // subdirectories open, so close them here. `leave` never closes the base
    // directory, which `dir` closes on return.
    while (walker.stack.items.len > 0) walker.leave(io);
    if (failure) |err| return err;
    return .{
        .paths = try keeper.toOwnedSorted(gpa),
        .matched = keeper.matched,
        .capped = capped,
    };
}

/// Formats the working-directory-relative display path into `path_buf` and
/// offers it to `keeper`.
fn record(
    gpa: std.mem.Allocator,
    keeper: *Keeper,
    path_buf: *std.ArrayList(u8),
    options: struct { base: []const u8, at_root: bool, path: []const u8 },
) !void {
    path_buf.clearRetainingCapacity();
    if (!options.at_root) {
        try path_buf.appendSlice(gpa, options.base);
        try path_buf.append(gpa, '/');
    }
    try path_buf.appendSlice(gpa, options.path);
    try keeper.offer(gpa, path_buf.items);
}

/// Retains the lexicographically-smallest `retain` paths offered to it, freeing
/// larger ones as they are evicted, and counts every path offered. Grows lazily
/// to at most `retain` entries, so the caller's result size, not the tree size,
/// bounds memory.
const Keeper = struct {
    heap: Heap = .empty,
    retain: usize,
    matched: usize = 0,

    // Max-heap keyed on the path, so the root is the largest retained path — the
    // eviction candidate when a smaller match arrives.
    const Heap = std.PriorityQueue([]const u8, void, greater);

    fn greater(_: void, a: []const u8, b: []const u8) std.math.Order {
        return std.mem.order(u8, b, a);
    }

    fn deinit(self: *Keeper, gpa: std.mem.Allocator) void {
        for (self.heap.items) |path| gpa.free(path);
        self.heap.deinit(gpa);
    }

    fn offer(self: *Keeper, gpa: std.mem.Allocator, path: []const u8) !void {
        self.matched += 1;
        if (self.retain == 0) return;
        if (self.heap.count() < self.retain) {
            const owned = try gpa.dupe(u8, path);
            errdefer gpa.free(owned);
            try self.heap.push(gpa, owned);
        } else if (std.mem.lessThan(u8, path, self.heap.peek().?)) {
            const owned = try gpa.dupe(u8, path);
            errdefer gpa.free(owned);
            gpa.free(self.heap.pop().?);
            // The pop kept capacity, so this push cannot allocate or fail.
            try self.heap.push(gpa, owned);
        }
    }

    // Transfers the retained paths into a fresh, exactly-sized, sorted slice and
    // frees the heap's backing array (not the paths, whose ownership moves).
    fn toOwnedSorted(self: *Keeper, gpa: std.mem.Allocator) ![][]const u8 {
        const result = try gpa.alloc([]const u8, self.heap.count());
        @memcpy(result, self.heap.items);
        std.mem.sort([]const u8, result, {}, lessThan);
        self.heap.deinit(gpa);
        return result;
    }
};

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

    // The leak-detecting allocator also proves the cancel path frees every
    // retained path and the walker's memory.
    try std.testing.expectError(error.Canceled, collect(
        faulty.io(),
        std.testing.allocator,
        .{ .base = "lib", .pattern = "**", .retain = 1000 },
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

    try std.testing.expectError(error.Canceled, collect(
        faulty.io(),
        std.testing.allocator,
        .{ .base = "lib", .pattern = "**", .retain = 1000 },
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

    var matches = try collect(
        faulty.io(),
        std.testing.allocator,
        .{ .base = "lib", .pattern = "**/*.zig", .retain = 1000 },
    );
    defer matches.deinit(std.testing.allocator);
    // An ordinary error is not an abort: the walk skips the subtree, traverses
    // its siblings, and still returns their files with every handle released.
    try std.testing.expect(matches.paths.len > 0);
    try std.testing.expect(faulty.traversal_after_inject > 0);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}

fn makeTree(io: std.Io, dir: std.Io.Dir, dirs: usize, files: usize) !void {
    for (0..dirs) |d| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "d{d:0>3}", .{d});
        var sub = try dir.createDirPathOpen(io, name, .{});
        defer sub.close(io);
        for (0..files) |f| {
            var file_buf: [16]u8 = undefined;
            const file = try std.fmt.bufPrint(&file_buf, "f{d:0>3}.txt", .{f});
            try sub.writeFile(io, .{ .sub_path = file, .data = "hit\n" });
        }
    }
}

test "collect retains only the smallest matches and counts the rest" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(io, tmp.dir, 20, 10);
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collect(io, std.testing.allocator, .{ .base = base, .pattern = "**", .retain = 5 });
    defer matches.deinit(std.testing.allocator);

    // 200 files match, but memory holds only the 5 lexicographically smallest;
    // the whole tree is never retained.
    try std.testing.expectEqual(@as(usize, 200), matches.matched);
    try std.testing.expectEqual(@as(usize, 5), matches.paths.len);
    try std.testing.expect(!matches.capped);
    try std.testing.expect(std.mem.endsWith(u8, matches.paths[0], "/d000/f000.txt"));
    try std.testing.expect(std.mem.endsWith(u8, matches.paths[4], "/d000/f004.txt"));
}

test "collect stops at the entry-visit work cap" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(io, tmp.dir, 20, 10);
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collect(io, std.testing.allocator, .{
        .base = base,
        .pattern = "**",
        .retain = 1000,
        .entries_max = 10,
    });
    defer matches.deinit(std.testing.allocator);

    // The cap halts traversal long before the 220-entry tree is exhausted.
    try std.testing.expect(matches.capped);
    try std.testing.expect(matches.matched < 200);
    try std.testing.expect(matches.paths.len <= 10);
}
