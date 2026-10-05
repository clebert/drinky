const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const testing = @import("testing.zig");

const lock_attempts_max = 50;
const lock_wait_ms = 10;

pub const FileError = std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.Atomic.ReplaceError;

pub const OpenError = std.Io.Dir.ReadFileAllocError || error{CorruptStore};

pub const SaveError = FileError || error{ StoreBusy, CorruptStore };

pub const File = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *File) void {
        self.parsed.deinit();
    }

    pub fn entry(self: *const File, key: []const u8) ?*const std.json.ObjectMap {
        return providers.json.object(self.parsed.value.object.getPtr(key));
    }
};

const Location = struct {
    path: []const u8,
    key: []const u8,
};

const SaveOptions = struct {
    keys_max: ?usize = null,
};

const RemoveCondition = struct {
    key: []const u8,
    field: []const u8,
    expected: []const u8,
};

pub const Directories = struct {
    working_directory: []const u8,
    home: []const u8,
};

pub fn locate(
    gpa: std.mem.Allocator,
    directories: *const Directories,
    name: []const u8,
) error{OutOfMemory}![]u8 {
    return std.fs.path.resolve(
        gpa,
        &.{ directories.working_directory, directories.home, ".drinky", name },
    );
}

pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) OpenError!?File {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err|
        switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    defer gpa.free(data);
    return try parse(gpa, data);
}

fn parse(gpa: std.mem.Allocator, data: []const u8) error{ OutOfMemory, CorruptStore }!File {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => |known| return known,
            else => return error.CorruptStore,
        };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.CorruptStore;
    return .{ .parsed = parsed };
}

pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    location: *const Location,
    entry: anytype,
    options: SaveOptions,
) SaveError!void {
    try rewrite(gpa, io, location, entry, options);
}

pub fn remove(gpa: std.mem.Allocator, io: std.Io, location: *const Location) SaveError!void {
    try rewrite(gpa, io, location, null, .{});
}

pub fn replace(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    value: anytype,
) SaveError!void {
    try ensureParent(io, path);
    var lock_file = try lockFile(gpa, io, path);
    defer lock_file.close(io);
    const body = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(body);
    try replaceFile(io, path, body);
}

pub fn removeMatchingString(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    condition: *const RemoveCondition,
) SaveError!bool {
    try ensureParent(io, path);
    var lock_file = try lockFile(gpa, io, path);
    defer lock_file.close(io);

    const existing = (try readExisting(gpa, io, path)) orelse return false;
    defer gpa.free(existing);
    if (!try stringMatches(gpa, existing, condition)) return false;

    const body = try serialize(gpa, existing, condition.key, null, .{});
    defer gpa.free(body);
    try replaceFile(io, path, body);
    return true;
}

fn rewrite(
    gpa: std.mem.Allocator,
    io: std.Io,
    location: *const Location,
    entry: anytype,
    options: SaveOptions,
) !void {
    const path = location.path;
    try ensureParent(io, path);
    var lock_file = try lockFile(gpa, io, path);
    defer lock_file.close(io);

    const existing = try readExisting(gpa, io, path);
    defer if (existing) |data| gpa.free(data);
    if (existing == null and @TypeOf(entry) == @TypeOf(null)) return;

    const body = try serialize(gpa, existing, location.key, entry, options);
    defer gpa.free(body);
    try replaceFile(io, path, body);
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| {
        std.Io.Dir.cwd().createDirPath(io, directory) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn lockFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !std.Io.File {
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
    defer gpa.free(lock_path);
    for (0..lock_attempts_max) |attempt| {
        const file = std.Io.Dir.cwd().createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = @enumFromInt(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock => {
                if (attempt + 1 == lock_attempts_max) return error.StoreBusy;
                try core.timeout.sleep(io, lock_wait_ms);
                continue;
            },
            else => return err,
        };
        return file;
    }
    unreachable;
}

fn readExisting(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn stringMatches(
    gpa: std.mem.Allocator,
    existing: []const u8,
    condition: *const RemoveCondition,
) error{ OutOfMemory, CorruptStore }!bool {
    var file = try parse(gpa, existing);
    defer file.deinit();
    const entry = file.entry(condition.key) orelse return false;
    const value = providers.json.string(entry.getPtr(condition.field)) orelse return false;
    return std.mem.eql(u8, value, condition.expected);
}

fn replaceFile(io: std.Io, path: []const u8, body: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = @enumFromInt(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, body);
    try atomic.replace(io);
}

fn serialize(
    gpa: std.mem.Allocator,
    existing: ?[]const u8,
    key: []const u8,
    entry: anytype,
    options: SaveOptions,
) error{ OutOfMemory, CorruptStore }![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeObject(gpa, &out.writer, existing, key, entry, options) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
    return out.toOwnedSlice();
}

fn writeObject(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    existing: ?[]const u8,
    key: []const u8,
    entry: anytype,
    options: SaveOptions,
) (std.Io.Writer.Error || error{ OutOfMemory, CorruptStore })!void {
    const writes_key = @TypeOf(entry) != @TypeOf(null);
    var stringify: std.json.Stringify = .{ .writer = writer };

    try stringify.beginObject();
    if (existing) |data| {
        var file = try parse(gpa, data);
        defer file.deinit();
        const object = &file.parsed.value.object;
        var dropped = dropCount(object, key, writes_key, options);
        var entries = object.iterator();
        while (entries.next()) |field| {
            if (std.mem.eql(u8, field.key_ptr.*, key)) continue;
            if (dropped > 0) {
                dropped -= 1;
                continue;
            }
            try stringify.objectField(field.key_ptr.*);
            try stringify.write(field.value_ptr.*);
        }
    }
    if (writes_key) {
        try stringify.objectField(key);
        try stringify.write(entry);
    }
    try stringify.endObject();
}

fn dropCount(
    object: *const std.json.ObjectMap,
    key: []const u8,
    writes_key: bool,
    options: SaveOptions,
) usize {
    const keys_max = options.keys_max orelse return 0;
    const kept = object.count() - @intFromBool(object.contains(key));
    const room = keys_max -| @intFromBool(writes_key);
    return kept -| room;
}

test "a store file lies in .drinky below the home, which resolves against the working directory" {
    const gpa = std.testing.allocator;
    for ([_]struct { home: []const u8, expected: []const u8 }{
        .{ .home = "/home/you", .expected = "/home/you/.drinky/auth.json" },
        .{ .home = "you", .expected = "/work/you/.drinky/auth.json" },
        .{ .home = "", .expected = "/work/.drinky/auth.json" },
    }) |case| {
        const directories: Directories = .{ .working_directory = "/work", .home = case.home };
        const located = try locate(gpa, &directories, "auth.json");
        defer gpa.free(located);
        try std.testing.expectEqualStrings(case.expected, located);
    }
}

const TestEntry = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,
};

test "serialize adds an entry, preserving other keys" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1234 };

    const merged = try serialize(
        gpa,
        "{\"openai-plan\":{\"access\":\"keep\"}}",
        "anthropic-plan",
        entry,
        .{},
    );
    defer gpa.free(merged);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, merged, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(
        "keep",
        root.get("openai-plan").?.object.get("access").?.string,
    );
    const added = root.get("anthropic-plan").?.object;
    try std.testing.expectEqualStrings("at", added.get("access").?.string);
    try std.testing.expectEqual(@as(i64, 1234), added.get("expires_ms").?.integer);
}

test "serialize from nothing writes just the entry, and replaces its own" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "new", .refresh = "rt", .expires_ms = 1 };

    const fresh = try serialize(gpa, null, "openai-plan", entry, .{});
    defer gpa.free(fresh);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fresh, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.count());
    try std.testing.expectEqualStrings(
        "new",
        parsed.value.object.get("openai-plan").?.object.get("access").?.string,
    );

    const replaced = try serialize(
        gpa,
        "{\"anthropic-plan\":{\"access\":\"keep\"}," ++
            "\"openai-plan\":{\"access\":\"old\"}}",
        "openai-plan",
        entry,
        .{},
    );
    defer gpa.free(replaced);
    const parsed_replaced = try std.json.parseFromSlice(std.json.Value, gpa, replaced, .{});
    defer parsed_replaced.deinit();
    try std.testing.expectEqualStrings(
        "keep",
        parsed_replaced.value.object.get("anthropic-plan").?.object.get("access").?.string,
    );
    try std.testing.expectEqualStrings(
        "new",
        parsed_replaced.value.object.get("openai-plan").?.object.get("access").?.string,
    );
}

test "serialize errors on an unparseable or non-object existing file" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try std.testing.expectError(
        error.CorruptStore,
        serialize(gpa, "{ not valid json", "openai-plan", entry, .{}),
    );
    try std.testing.expectError(
        error.CorruptStore,
        serialize(gpa, "[1,2,3]", "openai-plan", entry, .{}),
    );
}

test "serialize drops a key, preserving other keys" {
    const gpa = std.testing.allocator;
    const merged = try serialize(
        gpa,
        "{\"anthropic-plan\":{\"access\":\"a\"}," ++
            "\"openai-plan\":{\"access\":\"o\"}}",
        "openai-plan",
        null,
        .{},
    );
    defer gpa.free(merged);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, merged, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("openai-plan") == null);
    try std.testing.expectEqualStrings(
        "a",
        root.get("anthropic-plan").?.object.get("access").?.string,
    );

    const emptied = try serialize(gpa, merged, "anthropic-plan", null, .{});
    defer gpa.free(emptied);
    var parsed_empty = try std.json.parseFromSlice(std.json.Value, gpa, emptied, .{});
    defer parsed_empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_empty.value.object.count());
}

test "a key cap drops the oldest keys and keeps the saved one" {
    const gpa = std.testing.allocator;

    const capped = try serialize(
        gpa,
        "{\"first\":1,\"second\":2,\"third\":3}",
        "fourth",
        4,
        .{ .keys_max = 2 },
    );
    defer gpa.free(capped);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, capped, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());
    try std.testing.expectEqualStrings("third", parsed.value.object.keys()[0]);
    try std.testing.expectEqualStrings("fourth", parsed.value.object.keys()[1]);

    const rewritten = try serialize(
        gpa,
        "{\"first\":1,\"second\":2}",
        "first",
        9,
        .{ .keys_max = 2 },
    );
    defer gpa.free(rewritten);
    var parsed_rewritten = try std.json.parseFromSlice(std.json.Value, gpa, rewritten, .{});
    defer parsed_rewritten.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed_rewritten.value.object.count());
    try std.testing.expectEqual(@as(i64, 9), parsed_rewritten.value.object.get("first").?.integer);

    const only = try serialize(gpa, "{\"first\":1}", "second", 2, .{ .keys_max = 0 });
    defer gpa.free(only);
    var parsed_only = try std.json.parseFromSlice(std.json.Value, gpa, only, .{});
    defer parsed_only.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_only.value.object.count());
    try std.testing.expectEqualStrings("second", parsed_only.value.object.keys()[0]);
}

test "a busy store lock fails after its bounded retry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var clock: core.testing.ClockIo = undefined;
    clock.init(gpa);
    defer clock.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try testing.tmpPath(&path_buffer, &tmp, "auth.json");
    try ensureParent(io, path);
    var held = try lockFile(gpa, io, path);
    defer held.close(io);

    try std.testing.expectError(error.StoreBusy, lockFile(gpa, clock.io(), path));
    try std.testing.expectEqual(@as(usize, lock_attempts_max - 1), clock.sleep_count);
    try std.testing.expectEqual(@as(u64, lock_wait_ms), clock.slept()[0]);
}

test "save replaces the file atomically at owner-only permissions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try testing.tmpPath(&path_buffer, &tmp, "auth.json");
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try save(gpa, io, &.{ .path = path, .key = "openai-plan" }, entry, .{});
    const before = try tmp.dir.statFile(io, "auth.json", .{});
    try std.testing.expectEqual(
        @as(u32, 0o600),
        @as(u32, @intCast(@intFromEnum(before.permissions))) & 0o777,
    );

    try save(gpa, io, &.{ .path = path, .key = "anthropic-plan" }, entry, .{});
    const after = try tmp.dir.statFile(io, "auth.json", .{});
    try std.testing.expect(before.inode != after.inode);

    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings(
        "at",
        file.entry("openai-plan").?.get("access").?.string,
    );
    try std.testing.expectEqualStrings(
        "at",
        file.entry("anthropic-plan").?.get("access").?.string,
    );
}

test "remove drops only its key on disk, and a missing file opens as null" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try testing.tmpPath(&path_buffer, &tmp, "auth.json");
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try std.testing.expect((try open(gpa, io, path)) == null);

    try save(gpa, io, &.{ .path = path, .key = "openai-plan" }, entry, .{});
    try save(gpa, io, &.{ .path = path, .key = "anthropic-plan" }, entry, .{});
    try remove(gpa, io, &.{ .path = path, .key = "openai-plan" });

    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("openai-plan") == null);
    try std.testing.expectEqualStrings(
        "at",
        file.entry("anthropic-plan").?.get("access").?.string,
    );
}

test "a replacement writes the whole file over every key and over a corrupt file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try testing.tmpPath(&path_buffer, &tmp, "metadata.json");
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try save(gpa, io, &.{ .path = path, .key = "anthropic" }, entry, .{});
    try replace(gpa, io, path, .{ .openai = entry });
    {
        var file = (try open(gpa, io, path)).?;
        defer file.deinit();
        try std.testing.expect(file.entry("anthropic") == null);
        try std.testing.expectEqualStrings("at", file.entry("openai").?.get("access").?.string);
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "metadata.json", .data = "{ not json" });
    try replace(gpa, io, path, .{ .xai = entry });
    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("at", file.entry("xai").?.get("access").?.string);
}

test "a conditional removal keeps a replacement entry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try testing.tmpPath(&path_buffer, &tmp, "auth.json");
    const original: TestEntry = .{ .access = "a1", .refresh = "r1", .expires_ms = 1 };
    const replacement: TestEntry = .{ .access = "a2", .refresh = "r2", .expires_ms = 2 };

    try save(gpa, io, &.{ .path = path, .key = "anthropic-plan" }, original, .{});
    try save(gpa, io, &.{ .path = path, .key = "anthropic-plan" }, replacement, .{});
    const replacement_removed = try removeMatchingString(gpa, io, path, &.{
        .key = "anthropic-plan",
        .field = "refresh",
        .expected = "r1",
    });
    try std.testing.expect(!replacement_removed);

    {
        var file = (try open(gpa, io, path)).?;
        defer file.deinit();
        try std.testing.expectEqualStrings(
            "r2",
            file.entry("anthropic-plan").?.get("refresh").?.string,
        );
    }

    const removed = try removeMatchingString(gpa, io, path, &.{
        .key = "anthropic-plan",
        .field = "refresh",
        .expected = "r2",
    });
    try std.testing.expect(removed);
    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("anthropic-plan") == null);
}

test "open, save, and remove refuse a corrupt file, leaving it intact on disk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try testing.tmpPath(&path_buffer, &tmp, "auth.json");
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "{ not json" });
    try std.testing.expectError(error.CorruptStore, open(gpa, io, path));
    try std.testing.expectError(
        error.CorruptStore,
        save(gpa, io, &.{ .path = path, .key = "openai-plan" }, entry, .{}),
    );
    try std.testing.expectError(error.CorruptStore, remove(gpa, io, &.{
        .path = path,
        .key = "openai-plan",
    }));

    const data = try tmp.dir.readFileAlloc(io, "auth.json", gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);
}
