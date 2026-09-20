const std = @import("std");

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

const entries_visited_max = 1_000_000;
const skipped_noise_names_max = 3;

pub const Options = struct {
    base: []const u8,
    pattern: []const u8,
    retain: usize,
    entries_max: usize = entries_visited_max,
    timer: ?search.Timer = null,
};

const NoisePruning = enum { disabled, enabled };

pub const Match = struct {
    paths: [][]const u8,
    matched: usize,
    stop: Stop,
    skipped_noise: SkippedNoise,

    pub const Stop = enum {
        none,
        entries,
        time,
    };

    pub const SkippedNoise = struct {
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

        pub fn isEmpty(self: *const SkippedNoise) bool {
            return self.names.len == 0;
        }

        pub fn writeNotice(self: *const SkippedNoise, writer: *std.Io.Writer) !void {
            std.debug.assert(!self.isEmpty());
            const names_shown = @min(self.names.len, skipped_noise_names_max);
            try writer.writeAll("Drinky skipped these noise directories: ");
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
        self.skipped_noise.deinit(gpa);
        self.* = undefined;
    }
};

pub fn collect(io: std.Io, gpa: std.mem.Allocator, options: *const Options) !Match {
    const noise_pruning: NoisePruning = if (baseNamesNoise(options.base)) .disabled else .enabled;
    return collectWithNoisePruning(io, gpa, options, noise_pruning);
}

fn collectWithNoisePruning(
    io: std.Io,
    gpa: std.mem.Allocator,
    options: *const Options,
    noise_pruning: NoisePruning,
) !Match {
    var dir = try std.Io.Dir.cwd().openDir(io, options.base, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    defer while (walker.stack.items.len > 0) walker.leave(io);

    var keeper: Keeper = .{ .retain = options.retain };
    errdefer keeper.deinit(gpa);

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);

    var noise_skipped: [noise_directories.len]bool = @splat(false);
    const at_root = std.mem.eql(u8, options.base, ".");
    var visited: usize = 0;
    var stop: Match.Stop = .none;
    while (true) {
        const entry = (walker.next(io) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => continue,
        }) orelse break;
        if (visited >= options.entries_max) {
            stop = .entries;
            break;
        }
        const out_of_time = visited > 0 and if (options.timer) |timer| timer.spent() else false;
        if (out_of_time) {
            stop = .time;
            break;
        }
        visited += 1;
        switch (entry.kind) {
            .directory => {
                if (noise_pruning == .enabled) {
                    const maybe_noise_index = noiseIndex(entry.basename);
                    if (maybe_noise_index) |noise_index| {
                        if (noise_index >= version_control_directories.len) {
                            noise_skipped[noise_index] = true;
                        }
                        continue;
                    }
                }
                walker.enter(io, entry) catch |err| switch (err) {
                    error.Canceled, error.OutOfMemory => return err,
                    else => {},
                };
            },
            .file => {
                if (!glob.match(.{ .pattern = options.pattern, .path = entry.path })) continue;
                path_buf.clearRetainingCapacity();
                if (!at_root) {
                    try path_buf.appendSlice(gpa, options.base);
                    try path_buf.append(gpa, '/');
                }
                try path_buf.appendSlice(gpa, entry.path);
                try keeper.offer(gpa, path_buf.items);
            },
            else => {},
        }
    }
    var skipped_noise = try Match.SkippedNoise.init(gpa, &noise_skipped);
    errdefer skipped_noise.deinit(gpa);
    return .{
        .paths = try keeper.toOwnedSorted(gpa),
        .matched = keeper.matched,
        .stop = stop,
        .skipped_noise = skipped_noise,
    };
}

const Keeper = struct {
    heap: Heap = .empty,
    retain: usize,
    matched: usize = 0,

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
            try self.heap.push(gpa, owned);
        }
    }

    fn toOwnedSorted(self: *Keeper, gpa: std.mem.Allocator) ![][]const u8 {
        const result = try gpa.alloc([]const u8, self.heap.count());
        @memcpy(result, self.heap.items);
        std.mem.sort([]const u8, result, {}, lessThan);
        self.heap.deinit(gpa);
        return result;
    }
};

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

const FaultyIo = struct {
    backend: std.Io,
    vtable: std.Io.VTable,
    trigger: Trigger,
    inject: anyerror,
    opens: usize = 0,
    injected: bool = false,
    traversal_after_inject: usize = 0,
    open_handles: usize = 0,

    const Trigger = union(enum) {
        open_call: usize,
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

test "collect stops walking when an entered directory is canceled" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var faulty: FaultyIo = .init(threaded.io(), .{
        .trigger = .{ .open_call = 2 },
        .inject = error.Canceled,
    });

    try std.testing.expectError(error.Canceled, collect(
        faulty.io(),
        std.testing.allocator,
        &.{ .base = "lib", .pattern = "**", .retain = 1000 },
    ));
    try std.testing.expectEqual(@as(usize, 0), faulty.traversal_after_inject);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}

test "collect stops walking when a subdirectory read is canceled" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var faulty: FaultyIo = .init(threaded.io(), .{
        .trigger = .{ .subdir_read = 2 },
        .inject = error.Canceled,
    });

    try std.testing.expectError(error.Canceled, collect(
        faulty.io(),
        std.testing.allocator,
        &.{ .base = "lib", .pattern = "**", .retain = 1000 },
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
        &.{ .base = "lib", .pattern = "**/*.zig", .retain = 1000 },
    );
    defer matches.deinit(std.testing.allocator);
    try std.testing.expect(matches.paths.len > 0);
    try std.testing.expect(faulty.traversal_after_inject > 0);
    try std.testing.expectEqual(@as(usize, 0), faulty.open_handles);
}

test "collect propagates an allocation failure from the walker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "hit\n" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var failing: std.testing.FailingAllocator =
        .init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, collect(
        io,
        failing.allocator(),
        &.{ .base = base, .pattern = "**", .retain = 1000 },
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
        &.{ .base = base, .pattern = "**", .retain = 1000 },
    );
    defer matches.deinit(gpa);
}

test "collect propagates every allocation failure from a deep walk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const deep_path = "d/" ** 32 ++ "leaf";
    var leaf = try tmp.dir.createDirPathOpen(io, deep_path, .{});
    defer leaf.close(io);
    try leaf.writeFile(io, .{ .sub_path = "one.txt", .data = "hit\n" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        collectUnderAllocationFailure,
        .{ io, base },
    );
}

fn makeTree(io: std.Io, dir: std.Io.Dir, counts: struct { dirs: usize, files: usize }) !void {
    for (0..counts.dirs) |d| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "d{d:0>3}", .{d});
        var sub = try dir.createDirPathOpen(io, name, .{});
        defer sub.close(io);
        for (0..counts.files) |f| {
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
    try makeTree(io, tmp.dir, .{ .dirs = 20, .files = 10 });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collect(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 5,
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 200), matches.matched);
    try std.testing.expectEqual(@as(usize, 5), matches.paths.len);
    try std.testing.expectEqual(Match.Stop.none, matches.stop);
    try std.testing.expect(std.mem.endsWith(u8, matches.paths[0], "/d000/f000.txt"));
    try std.testing.expect(std.mem.endsWith(u8, matches.paths[4], "/d000/f004.txt"));
}

test "collect stops at the entry-visit work cap" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(io, tmp.dir, .{ .dirs = 20, .files = 10 });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

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
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(io, tmp.dir, .{ .dirs = 20, .files = 10 });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collect(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 1000,
        .timer = .startedAgo(io, search.timeout_ms),
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(Match.Stop.time, matches.stop);
    try std.testing.expect(matches.matched < 200);
}

test "collect reports no stop for a tree it read whole" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "only.txt", .data = "hit\n" });
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collect(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 1000,
        .timer = .startedAgo(io, search.timeout_ms),
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

test "skipped noise notice caps directory names" {
    const skipped_noise: Match.SkippedNoise = .{ .names = &.{
        ".cache",
        ".tox",
        "node_modules",
        "target",
    } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try skipped_noise.writeNotice(&out.writer);

    try std.testing.expectEqualStrings(
        "Drinky skipped these noise directories: `.cache`, `.tox`, `node_modules`, and 1 " ++
            "more. Set the path to a skipped directory to search that directory fully.",
        out.writer.buffered(),
    );
}

test "collect prunes noise directories in an isolated tree" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "keep\n" });
    for (noise_directories) |name| {
        var noise_directory = try tmp.dir.createDirPathOpen(io, name, .{});
        defer noise_directory.close(io);
        try noise_directory.writeFile(io, .{ .sub_path = "ignored.txt", .data = "ignore\n" });
    }
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var matches = try collectWithNoisePruning(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**",
        .retain = 10,
    }, .enabled);
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
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pkg = try tmp.dir.createDirPathOpen(io, "node_modules/node_modules/pkg", .{});
    defer pkg.close(io);
    try pkg.writeFile(io, .{ .sub_path = "index.js", .data = "hit\n" });
    var base_buf: [160]u8 = undefined;
    const base = try std.fmt.bufPrint(
        &base_buf,
        ".zig-cache/tmp/{s}/node_modules",
        .{tmp.sub_path},
    );

    var matches = try collect(io, std.testing.allocator, &.{
        .base = base,
        .pattern = "**/*.js",
        .retain = 10,
    });
    defer matches.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), matches.matched);
    try std.testing.expect(
        std.mem.endsWith(u8, matches.paths[0], "node_modules/node_modules/pkg/index.js"),
    );
    try std.testing.expect(matches.skipped_noise.isEmpty());
}
