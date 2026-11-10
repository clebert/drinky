const std = @import("std");
const builtin = @import("builtin");

const accounts = @import("accounts");
const tools = @import("tools");

const project = @import("project.zig");
const testing = @import("testing.zig");

const shared_temporary_directory = "/tmp";

const home_caches = [_][]const u8{ ".cache/zig", ".npm" };

const Options = struct {
    directories: *const accounts.json_store.Directories,
    root: []const u8,
    environ: std.process.Environ,
};

const darwin = struct {
    const cs_darwin_user_cache_dir = 65538;

    extern "c" fn confstr(name: c_int, buffer: [*]u8, length: usize) usize;
};

pub fn policy(
    arena: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
) error{ OutOfMemory, Canceled }!?tools.Sandbox {
    if (!tools.Sandbox.available) return null;
    const cwd = options.directories.working_directory;
    var directories: std.ArrayList([]const u8) = .empty;
    try directories.append(arena, options.root);
    const maybe_git = try project.gitDirectory(arena, io, options.root);
    const maybe_temporary = options.environ.getPosix("TMPDIR");
    const maybe_cache = try userCacheDirectory(arena);
    for ([_]?[]const u8{ maybe_git, maybe_temporary, shared_temporary_directory, maybe_cache }) |
        maybe_directory,
    | {
        const directory = maybe_directory orelse continue;
        const real = try realPath(arena, io, directory) orelse continue;
        try directories.append(arena, real);
    }
    const home = try physicalPath(
        arena,
        io,
        try std.Io.Dir.path.resolve(arena, &.{ cwd, options.directories.home }),
    );
    for (home_caches) |cache| try directories.append(
        arena,
        try physicalPath(arena, io, try std.Io.Dir.path.join(arena, &.{ home, cache })),
    );

    var files: std.ArrayList([]const u8) = .empty;
    const located: accounts.json_store.Directories = .{ .working_directory = cwd, .home = home };
    for (std.enums.values(accounts.json_store.Name)) |name| {
        if (!savedByRun(name)) continue;
        const located_path = try accounts.json_store.locate(arena, &located, name);
        const parent = try physicalPath(arena, io, std.Io.Dir.path.dirname(located_path).?);
        const path = try std.Io.Dir.path.join(
            arena,
            &.{ parent, std.Io.Dir.path.basename(located_path) },
        );
        try files.appendSlice(arena, &.{ path, try accounts.json_store.lockPath(arena, path) });
    }
    return .{ .directories = directories.items, .files = files.items };
}

fn savedByRun(name: accounts.json_store.Name) bool {
    return switch (name) {
        .auth, .models => true,
        .config, .metadata, .state => false,
    };
}

fn userCacheDirectory(arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    switch (builtin.os.tag) {
        .macos => {},
        else => return null,
    }
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = darwin.confstr(darwin.cs_darwin_user_cache_dir, &buffer, buffer.len);
    if (length <= 1 or length > buffer.len) return null;
    return try arena.dupe(u8, buffer[0 .. length - 1]);
}

fn physicalPath(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) error{ OutOfMemory, Canceled }![]const u8 {
    var existing = path;
    for (0..std.Io.Dir.max_path_bytes) |_| {
        if (try realPath(arena, io, existing)) |real| {
            const rest = std.mem.trimStart(u8, path[existing.len..], "/");
            if (rest.len == 0) return real;
            return std.Io.Dir.path.join(arena, &.{ real, rest });
        }
        existing = std.Io.Dir.path.dirname(existing) orelse return path;
    }
    return path;
}

fn realPath(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) error{ OutOfMemory, Canceled }!?[]const u8 {
    if (path.len == 0) return null;
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => null,
    };
}

test "the sandbox of a worktree holds its root, its Git directory, caches, and run files" {
    if (!tools.Sandbox.available) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    try tree.write("repo/.git/worktrees/next/commondir", "../..\n");
    try tree.write("next/.git", "gitdir: ../repo/.git/worktrees/next\n");
    try tree.directory("home/.drinky");
    try tree.directory("temporary");
    const root = try tree.path("next");
    const temporary_entry =
        try arena.allocator().printSentinel("TMPDIR={s}/temporary/", .{tree.root}, 0);
    const entries = [_:null]?[*:0]const u8{temporary_entry.ptr};

    const sandbox = (try policy(arena.allocator(), std.testing.io, &.{
        .directories = &.{ .working_directory = root, .home = "../home" },
        .root = root,
        .environ = .{ .block = .{ .slice = &entries } },
    })).?;

    const real_temporary = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        shared_temporary_directory,
        arena.allocator(),
    );
    const expected_directories = [_]?[]const u8{
        root,
        try tree.path("repo/.git"),
        try tree.path("temporary"),
        real_temporary,
        null,
        try tree.path("home/.cache/zig"),
        try tree.path("home/.npm"),
    };
    try std.testing.expectEqual(expected_directories.len, sandbox.directories.len);
    for (expected_directories, sandbox.directories) |maybe_expected, directory| {
        const expected = maybe_expected orelse {
            try std.testing.expect(std.mem.startsWith(u8, directory, "/private/var/folders/"));
            try std.testing.expect(std.mem.endsWith(u8, directory, "/C"));
            continue;
        };
        try std.testing.expectEqualStrings(expected, directory);
    }
    const expected_files = [_][]const u8{
        try tree.path("home/.drinky/auth.json"),
        try tree.path("home/.drinky/auth.json.lock"),
        try tree.path("home/.drinky/models.json"),
        try tree.path("home/.drinky/models.json.lock"),
    };
    try std.testing.expectEqual(expected_files.len, sandbox.files.len);
    for (expected_files, sandbox.files) |expected, file|
        try std.testing.expectEqualStrings(expected, file);
}

test "an empty TMPDIR adds no writable directory" {
    if (!tools.Sandbox.available) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    try tree.directory("work");
    const root = try tree.path("work");
    const entries = [_:null]?[*:0]const u8{"TMPDIR="};
    const environs = [_]std.process.Environ{ .{ .block = .{ .slice = &entries } }, .empty };
    var lists: [environs.len][]const []const u8 = undefined;
    for (environs, &lists) |environ, *list| {
        const sandbox = (try policy(arena.allocator(), std.testing.io, &.{
            .directories = &.{ .working_directory = root, .home = root },
            .root = root,
            .environ = environ,
        })).?;
        list.* = sandbox.directories;
    }

    try std.testing.expectEqual(lists[1].len, lists[0].len);
    for (lists[1], lists[0]) |expected, directory|
        try std.testing.expectEqualStrings(expected, directory);
}

test "linked directories of the home become real paths, and a linked store file stays put" {
    if (!tools.Sandbox.available) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    try tree.directory("work");
    try tree.directory("store");
    try tree.directory("npm");
    try tree.directory("cache");
    try tree.directory("home");
    try tree.link("../store", "home/.drinky", .{ .is_directory = true });
    try tree.link("../npm", "home/.npm", .{ .is_directory = true });
    try tree.link("../cache", "home/.cache", .{ .is_directory = true });
    try tree.write("secret/auth.json", "{}");
    try tree.link("../secret/auth.json", "store/auth.json", .{});
    const root = try tree.path("work");

    const sandbox = (try policy(arena.allocator(), std.testing.io, &.{
        .directories = &.{ .working_directory = root, .home = try tree.path("home") },
        .root = root,
        .environ = .empty,
    })).?;

    try std.testing.expectEqualStrings(try tree.path("store/auth.json"), sandbox.files[0]);
    try std.testing.expectEqualStrings(try tree.path("store/auth.json.lock"), sandbox.files[1]);
    for ([_][]const u8{ try tree.path("npm"), try tree.path("cache/zig") }) |expected| {
        const listed = for (sandbox.directories) |directory| {
            if (std.mem.eql(u8, directory, expected)) break true;
        } else false;
        try std.testing.expect(listed);
    }
}

test "a cancel during the sandbox setup reaches the caller" {
    if (!tools.Sandbox.available) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const canceling: tools.testing.CancelIo = .init(.real_path);
    try std.testing.expectError(error.Canceled, policy(arena.allocator(), canceling.io(), &.{
        .directories = &.{ .working_directory = "/work", .home = "/home" },
        .root = "/work",
        .environ = .empty,
    }));
}
