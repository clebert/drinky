const std = @import("std");

const core = @import("core");

const glob = @import("glob.zig");
const search = @import("search.zig");

const version_control_directories = [_][]const u8{
    ".bzr",
    ".git",
    ".hg",
    ".jj",
    ".pijul",
    ".sl",
    ".svn",
    "CVS",
    "_darcs",
};

const noise_directories = version_control_directories ++ [_][]const u8{
    ".dart_tool",
    ".direnv",
    ".pnpm-store",
    ".venv",
    "__pypackages__",
    "bower_components",
    "jspm_packages",
    "node_modules",
    "venv",
    "web_modules",
    ".aws-sam",
    ".build",
    ".cache",
    ".cdk.staging",
    ".gradle",
    ".mypy_cache",
    ".next",
    ".nox",
    ".nuxt",
    ".nyc_output",
    ".parcel-cache",
    ".pytest_cache",
    ".ruff_cache",
    ".serverless",
    ".sst",
    ".stack-work",
    ".svelte-kit",
    ".terraform",
    ".terragrunt-cache",
    ".terragrunt-stack",
    ".tox",
    ".turbo",
    ".vs",
    ".zig-cache",
    "CMakeFiles",
    "DerivedData",
    "__pycache__",
    "_build",
    "buck-out",
    "cdk.out",
    "cdktf.out",
    "dist-newstyle",
    "target",
    "zig-cache",
    "zig-out",
};

pub const noise_note = "The search skips common version-control stores, dependency " ++
    "directories, virtual environments, build outputs, and tool caches. When the path ends " ++
    "with a skipped directory name, the search covers that directory fully.";

const skipped_noise_names_max = 3;

const Options = struct {
    base: []const u8,
    pattern: []const u8,
    retain: usize,
    entries_max: usize,
    timer: ?search.Timer = null,
    noise_pruning: NoisePruning = .enabled,
    links: Links = .files,
    skips_max: usize = 0,
};

const NoisePruning = enum { disabled, enabled };

const Links = enum { files, files_and_directories };

const Skip = struct {
    kind: Kind,
    path: []const u8,
    error_name: []const u8,

    const Kind = enum { entry, directory, link, followed_link };
};

pub const Match = struct {
    paths: []const []const u8,
    matched: usize,
    stop: Stop,
    skipped_noise: SkippedNoise,
    skips: []const Skip,
    entries_unread: usize,

    const Stop = enum {
        none,
        entries,
        time,
    };

    const SkippedNoise = struct {
        names: []const []const u8,

        fn init(
            gpa: std.mem.Allocator,
            skipped: *const [noise_directories.len]bool,
        ) !SkippedNoise {
            var count: usize = 0;
            for (skipped) |was_skipped| {
                if (was_skipped) count += 1;
            }
            const names = try gpa.alloc([]const u8, count);
            var index: usize = 0;
            for (noise_directories, skipped) |name, was_skipped| {
                if (!was_skipped) continue;
                names[index] = name;
                index += 1;
            }
            std.mem.sort([]const u8, names, {}, lessThan);
            return .{ .names = names };
        }

        fn deinit(self: *SkippedNoise, gpa: std.mem.Allocator) void {
            gpa.free(self.names);
            self.* = undefined;
        }

        pub fn writeNotice(self: *const SkippedNoise, writer: *std.Io.Writer) !void {
            if (self.names.len == 0) return;
            const names_shown = @min(self.names.len, skipped_noise_names_max);
            try writer.writeAll(" Drinky skipped these noise directories: ");
            for (self.names[0..names_shown], 0..) |name, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.print("`{s}`", .{name});
            }
            const names_omitted = self.names.len - names_shown;
            if (names_omitted > 0) try writer.print(", and {d} more", .{names_omitted});
            try writer.writeAll(
                ". Set the path to a skipped directory to search that directory fully.",
            );
        }
    };

    pub fn deinit(self: *Match, gpa: std.mem.Allocator) void {
        for (self.paths) |path| gpa.free(path);
        gpa.free(self.paths);
        for (self.skips) |skip| gpa.free(skip.path);
        gpa.free(self.skips);
        self.skipped_noise.deinit(gpa);
        self.* = undefined;
    }
};

const Keeper = struct {
    base: []const u8,
    heap: Heap = .empty,
    buffer: std.ArrayList(u8) = .empty,
    retain: usize,
    matched: usize = 0,

    const Heap = std.PriorityQueue([]const u8, void, greater);

    fn greater(_: void, a: []const u8, b: []const u8) std.math.Order {
        return std.mem.order(u8, b, a);
    }

    fn deinit(self: *Keeper, gpa: std.mem.Allocator) void {
        for (self.heap.items) |path| gpa.free(path);
        self.heap.deinit(gpa);
        self.buffer.deinit(gpa);
    }

    fn offer(self: *Keeper, gpa: std.mem.Allocator, entry_path: []const u8) !void {
        self.matched += 1;
        self.buffer.clearRetainingCapacity();
        if (!std.mem.eql(u8, self.base, ".")) {
            try self.buffer.appendSlice(gpa, self.base);
            if (!std.mem.endsWith(u8, self.base, "/")) try self.buffer.append(gpa, '/');
        }
        try self.buffer.appendSlice(gpa, entry_path);
        const path = self.buffer.items;
        if (self.heap.count() < self.retain) {
            const owned = try gpa.dupe(u8, path);
            errdefer gpa.free(owned);
            try self.heap.push(gpa, owned);
        } else if (std.mem.lessThan(u8, path, self.heap.peek().?)) {
            const owned = try gpa.dupe(u8, path);
            errdefer gpa.free(owned);
            gpa.free(self.heap.pop().?);
            try self.heap.push(gpa, owned);
        }
    }

    fn toOwnedSorted(self: *Keeper, gpa: std.mem.Allocator) ![]const []const u8 {
        const paths = try gpa.alloc([]const u8, self.heap.count());
        @memcpy(paths, self.heap.items);
        std.mem.sort([]const u8, paths, {}, lessThan);
        self.heap.deinit(gpa);
        self.heap = .empty;
        return paths;
    }
};

const Skips = struct {
    items: std.ArrayList(Skip) = .empty,
    max: usize,
    count: usize = 0,

    fn deinit(self: *Skips, gpa: std.mem.Allocator) void {
        for (self.items.items) |skip| gpa.free(skip.path);
        self.items.deinit(gpa);
    }

    fn add(self: *Skips, gpa: std.mem.Allocator, skip: *const Skip) !void {
        self.count += 1;
        if (self.items.items.len == self.max) return;
        const owned = try gpa.dupe(u8, skip.path);
        errdefer gpa.free(owned);
        try self.items.append(gpa, .{
            .kind = skip.kind,
            .path = owned,
            .error_name = skip.error_name,
        });
    }
};

const Visited = struct {
    paths: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Visited, gpa: std.mem.Allocator) void {
        var keys = self.paths.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        self.paths.deinit(gpa);
    }

    fn seen(
        self: *Visited,
        gpa: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
    ) !bool {
        const canonical = dir.realPathFileAlloc(io, sub_path, gpa) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |known| return known,
            else => return false,
        };
        defer gpa.free(canonical);
        if (self.paths.contains(canonical)) return true;
        const owned = try gpa.dupe(u8, canonical);
        errdefer gpa.free(owned);
        try self.paths.put(gpa, owned, {});
        return false;
    }
};

pub fn collect(io: std.Io, gpa: std.mem.Allocator, options: *const Options) !Match {
    std.debug.assert(options.retain > 0);
    var dir = try std.Io.Dir.cwd().openDir(io, options.base, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    defer while (walker.stack.items.len > 0) walker.leave(io);

    var keeper: Keeper = .{ .base = options.base, .retain = options.retain };
    defer keeper.deinit(gpa);
    var skips: Skips = .{ .max = options.skips_max };
    defer skips.deinit(gpa);
    var visited: Visited = .{};
    defer visited.deinit(gpa);
    if (options.links == .files_and_directories) _ = try visited.seen(gpa, io, dir, ".");

    const noise_pruning = options.noise_pruning == .enabled and !baseNamesNoise(options.base);
    var noise_skipped: [noise_directories.len]bool = @splat(false);
    var stop: Match.Stop = .none;
    for (0..options.entries_max + 1) |attempt| {
        const maybe_entry = walker.next(io) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |known| return known,
            else => {
                try skips.add(gpa, &.{ .kind = .entry, .path = "", .error_name = @errorName(err) });
                if (attempt == options.entries_max) stop = .entries;
                continue;
            },
        };
        const entry = maybe_entry orelse break;
        if (attempt == options.entries_max) {
            stop = .entries;
            break;
        }
        const out_of_time = attempt > 0 and if (options.timer) |timer| timer.spent() else false;
        if (out_of_time) {
            stop = .time;
            break;
        }
        switch (entry.kind) {
            .directory => {
                if (noise_pruning) {
                    if (noiseIndex(entry.basename)) |noise_index| {
                        if (noise_index >= version_control_directories.len) {
                            noise_skipped[noise_index] = true;
                        }
                        continue;
                    }
                }
                walker.enter(io, entry) catch |err| switch (err) {
                    error.Canceled, error.OutOfMemory => |known| return known,
                    else => try skips.add(gpa, &.{
                        .kind = .directory,
                        .path = entry.path,
                        .error_name = @errorName(err),
                    }),
                };
            },
            .file => if (glob.match(&.{ .pattern = options.pattern, .path = entry.path })) {
                try keeper.offer(gpa, entry.path);
            },
            .sym_link => {
                const matched = glob.match(&.{ .pattern = options.pattern, .path = entry.path });
                if (!matched and options.links == .files) continue;
                const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.FileNotFound => continue,
                    else => {
                        try skips.add(gpa, &.{
                            .kind = .link,
                            .path = entry.path,
                            .error_name = @errorName(err),
                        });
                        continue;
                    },
                };
                switch (stat.kind) {
                    .file => if (matched) try keeper.offer(gpa, entry.path),
                    .directory => if (options.links == .files_and_directories) {
                        if (try visited.seen(gpa, io, entry.dir, entry.basename)) continue;
                        var link = entry;
                        link.kind = .directory;
                        walker.enter(io, link) catch |err| switch (err) {
                            error.Canceled, error.OutOfMemory => |known| return known,
                            else => try skips.add(gpa, &.{
                                .kind = .followed_link,
                                .path = entry.path,
                                .error_name = @errorName(err),
                            }),
                        };
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    var match: Match = .{
        .paths = &.{},
        .matched = keeper.matched,
        .stop = stop,
        .skipped_noise = .{ .names = &.{} },
        .skips = &.{},
        .entries_unread = skips.count,
    };
    errdefer match.deinit(gpa);
    match.skipped_noise = try .init(gpa, &noise_skipped);
    match.skips = try skips.items.toOwnedSlice(gpa);
    match.paths = try keeper.toOwnedSorted(gpa);
    return match;
}

pub fn writeUnread(writer: *std.Io.Writer, entries_unread: usize) !void {
    try writer.print("Drinky could not read {d} {s}.", .{
        entries_unread,
        if (entries_unread == 1) "entry" else "entries",
    });
}

fn noiseIndex(basename: []const u8) ?usize {
    for (noise_directories, 0..) |noise, index| {
        if (std.mem.eql(u8, basename, noise)) return index;
    }
    return null;
}

fn isNoise(basename: []const u8) bool {
    return noiseIndex(basename) != null;
}

fn baseNamesNoise(base: []const u8) bool {
    var basename: []const u8 = "";
    var segments = std.mem.splitScalar(u8, base, '/');
    while (segments.next()) |segment| {
        if (segment.len > 0 and !std.mem.eql(u8, segment, ".")) basename = segment;
    }
    return isNoise(basename);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "collect stops walking when an entered directory is canceled" {
    var tree: Tree = try .init();
    defer tree.deinit();
    var faulty: FaultyIo = .init(std.testing.io, &.{
        .trigger = .{ .open_call = 2 },
        .inject = error.Canceled,
    });

    try std.testing.expectError(error.Canceled, collect(
        faulty.io(),
        std.testing.allocator,
        &.{ .base = tree.base, .pattern = "**", .retain = 1000, .entries_max = entries_max },
    ));
    try std.testing.expectEqual(@as(usize, 0), faulty.traversal_after_inject);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}

const FaultyIo = struct {
    backend: std.Io,
    vtable: std.Io.VTable,
    trigger: Trigger,
    inject: Injected,
    opens: usize = 0,
    injected: bool = false,
    traversal_after_inject: usize = 0,
    open_handles: usize = 0,

    const Trigger = union(enum) {
        open_call: usize,
        subdir_read: usize,
    };

    const Injected = error{ Canceled, AccessDenied };

    fn init(backend: std.Io, options: *const struct {
        trigger: Trigger,
        inject: Injected,
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
            .open_call => |limit| if (self.opens == limit) {
                self.injected = true;
                return self.inject;
            },
            .subdir_read => {},
        }
        const result =
            try self.backend.vtable.dirOpenDir(self.backend.userdata, dir, path, options);
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
            .subdir_read => |limit| if (self.open_handles >= limit) {
                self.injected = true;
                return self.inject;
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

const entries_max = 1_000_000;

test "collect stops walking when a subdirectory read is canceled" {
    var tree: Tree = try .init();
    defer tree.deinit();
    var faulty: FaultyIo = .init(std.testing.io, &.{
        .trigger = .{ .subdir_read = 2 },
        .inject = error.Canceled,
    });

    try std.testing.expectError(error.Canceled, collect(
        faulty.io(),
        std.testing.allocator,
        &.{ .base = tree.base, .pattern = "**", .retain = 1000, .entries_max = entries_max },
    ));
    try std.testing.expectEqual(@as(usize, 0), faulty.traversal_after_inject);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}

test "collect reports an unreadable directory and keeps walking" {
    var tree: Tree = try .init();
    defer tree.deinit();
    var faulty: FaultyIo = .init(std.testing.io, &.{
        .trigger = .{ .open_call = 2 },
        .inject = error.AccessDenied,
    });

    var matches = try collect(faulty.io(), std.testing.allocator, &.{
        .base = tree.base,
        .pattern = "**/*.txt",
        .retain = 1000,
        .entries_max = entries_max,
        .skips_max = 8,
    });
    defer matches.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), matches.paths.len);
    try std.testing.expectEqual(@as(usize, 1), matches.skips.len);
    try std.testing.expectEqual(Skip.Kind.directory, matches.skips[0].kind);
    try std.testing.expectEqualStrings("AccessDenied", matches.skips[0].error_name);
    try std.testing.expect(faulty.traversal_after_inject > 0);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}

test "collect propagates an allocation failure from the walker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "hit\n" });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var failing: std.testing.FailingAllocator =
        .init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, collect(
        io,
        failing.allocator(),
        &.{ .base = base, .pattern = "**", .retain = 1000, .entries_max = entries_max },
    ));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn collectUnderAllocationFailure(
    gpa: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
) !void {
    var matches = try collect(
        io,
        gpa,
        &.{ .base = base, .pattern = "**", .retain = 1000, .entries_max = entries_max },
    );
    defer matches.deinit(gpa);
}

test "collect propagates every allocation failure from a deep walk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const deep_path = core.text.repeat("d/", 32) ++ "leaf";
    var leaf = try tmp.dir.createDirPathOpen(io, deep_path, .{});
    defer leaf.close(io);
    try leaf.writeFile(io, .{ .sub_path = "one.txt", .data = "hit\n" });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        collectUnderAllocationFailure,
        .{ io, base },
    );
}

const Tree = struct {
    tmp: std.testing.TmpDir,
    base: [:0]u8,

    fn init() !Tree {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try makeTree(std.testing.io, tmp.dir, .{ .directories = 3, .files = 2 });
        const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .tmp = tmp, .base = base };
    }

    fn deinit(self: *Tree) void {
        std.testing.allocator.free(self.base);
        self.tmp.cleanup();
    }
};

fn makeTree(
    io: std.Io,
    dir: std.Io.Dir,
    counts: struct { directories: usize, files: usize },
) !void {
    for (0..counts.directories) |directory_index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.mem.print(&name_buffer, "d{d:0>3}", .{directory_index});
        var subdirectory = try dir.createDirPathOpen(io, name, .{});
        defer subdirectory.close(io);
        for (0..counts.files) |file_index| {
            var file_buffer: [16]u8 = undefined;
            const file = try std.mem.print(&file_buffer, "f{d:0>3}.txt", .{file_index});
            try subdirectory.writeFile(io, .{ .sub_path = file, .data = "hit\n" });
        }
    }
}

test "collect retains only the smallest matches and counts the rest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(io, tmp.dir, .{ .directories = 20, .files = 10 });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collect(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 5,
        .entries_max = entries_max,
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 200), matches.matched);
    try std.testing.expectEqual(@as(usize, 5), matches.paths.len);
    try std.testing.expectEqual(Match.Stop.none, matches.stop);
    try std.testing.expect(std.mem.endsWith(u8, matches.paths[0], "/d000/f000.txt"));
    try std.testing.expect(std.mem.endsWith(u8, matches.paths[4], "/d000/f004.txt"));
}

test "collect stops at the entry-visit work cap" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(io, tmp.dir, .{ .directories = 20, .files = 10 });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collect(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 1000,
        .entries_max = 10,
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(Match.Stop.entries, matches.stop);
    try std.testing.expect(matches.matched < 200);
    try std.testing.expect(matches.paths.len <= 10);
}

test "collect stops when the search runs out of time" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(io, tmp.dir, .{ .directories = 20, .files = 10 });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var clock: core.testing.StepClock = undefined;
    clock.init(std.testing.allocator, search.timeout_ms);
    defer clock.deinit();
    var matches = try collect(clock.io(), std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 1000,
        .entries_max = entries_max,
        .timer = .start(clock.io()),
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(Match.Stop.time, matches.stop);
    try std.testing.expect(matches.matched < 200);
}

test "collect reports no stop for a tree it read whole" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "only.txt", .data = "hit\n" });
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var clock: core.testing.StepClock = undefined;
    clock.init(std.testing.allocator, search.timeout_ms);
    defer clock.deinit();
    var matches = try collect(clock.io(), std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 1000,
        .entries_max = entries_max,
        .timer = .start(clock.io()),
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(Match.Stop.none, matches.stop);
    try std.testing.expectEqual(@as(usize, 1), matches.paths.len);
}

test "baseNamesNoise only accepts the final path component" {
    try std.testing.expect(!baseNamesNoise("."));
    try std.testing.expect(!baseNamesNoise("lib/terminal"));
    try std.testing.expect(!baseNamesNoise("node_modules_backup"));
    try std.testing.expect(baseNamesNoise("node_modules"));
    try std.testing.expect(baseNamesNoise("./node_modules/"));
    try std.testing.expect(baseNamesNoise("packages/app/node_modules/."));
    try std.testing.expect(!baseNamesNoise("packages/app/node_modules/react"));
    try std.testing.expect(!baseNamesNoise("/home/user/.cache/project"));
    try std.testing.expect(!baseNamesNoise("/repo/target/src"));
    try std.testing.expect(!baseNamesNoise(".zig-cache/tmp/x"));
    try std.testing.expect(!baseNamesNoise("node_modules/.."));
}

test "noise list includes Zig and CDK output directories" {
    for ([_][]const u8{
        ".cdk.staging",
        ".zig-cache",
        "cdk.out",
        "cdktf.out",
        "zig-cache",
        "zig-out",
    }) |name| try std.testing.expect(isNoise(name));
}

test "noise list keeps Nx workflows visible" {
    try std.testing.expect(!isNoise(".nx"));
}

test "the notice of skipped noise caps the names and is empty without a skip" {
    const none: Match.SkippedNoise = .{ .names = &.{} };
    const skipped_noise: Match.SkippedNoise = .{ .names = &.{
        ".cache",
        ".tox",
        "node_modules",
        "target",
    } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try none.writeNotice(&out.writer);
    try skipped_noise.writeNotice(&out.writer);

    try std.testing.expectEqualStrings(
        " Drinky skipped these noise directories: `.cache`, `.tox`, `node_modules`, and 1 " ++
            "more. Set the path to a skipped directory to search that directory fully.",
        out.writer.buffered(),
    );
}

test "collect prunes noise directories in an isolated tree" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "keep\n" });
    for (noise_directories) |name| {
        var noise_directory = try tmp.dir.createDirPathOpen(io, name, .{});
        defer noise_directory.close(io);
        try noise_directory.writeFile(io, .{ .sub_path = "ignored.txt", .data = "ignore\n" });
    }
    var base_buffer: [128]u8 = undefined;
    const base = try std.mem.print(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collect(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 10,
        .entries_max = entries_max,
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), matches.matched);
    try std.testing.expect(std.mem.endsWith(u8, matches.paths[0], "/kept.txt"));
    try std.testing.expectEqual(
        noise_directories.len - version_control_directories.len,
        matches.skipped_noise.names.len,
    );
    for (matches.skipped_noise.names) |name| {
        try std.testing.expect(noiseIndex(name).? >= version_control_directories.len);
    }
}

test "collect keeps nested noise visible when the base names noise" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var package = try tmp.dir.createDirPathOpen(io, "node_modules/node_modules/pkg", .{});
    defer package.close(io);
    try package.writeFile(io, .{ .sub_path = "index.js", .data = "hit\n" });
    var base_buffer: [160]u8 = undefined;
    const base = try std.mem.print(
        &base_buffer,
        ".zig-cache/tmp/{s}/node_modules",
        .{tmp.sub_path},
    );

    var matches = try collect(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**/*.js",
        .retain = 10,
        .entries_max = entries_max,
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), matches.matched);
    try std.testing.expect(
        std.mem.endsWith(u8, matches.paths[0], "node_modules/node_modules/pkg/index.js"),
    );
    try std.testing.expectEqual(@as(usize, 0), matches.skipped_noise.names.len);
}
