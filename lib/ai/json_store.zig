//! A keyed JSON object file: one top-level object that maps each key to that
//! key's entry. The credential store uses the account as the key. The app state
//! store uses the project. This module owns the file shape only. The caller owns
//! its entry fields (passed as `anytype`), so nothing here knows an entry shape.
//!
//! Every write holds the owner-only `{path}.lock` sibling across its load,
//! merge, and atomic rename. Lock contention ends with `error.StoreBusy` after
//! a bounded wait. A corrupt file is never replaced.

const std = @import("std");

const json = @import("json.zig");

const LockPolicy = struct {
    /// The maximum number of nonblocking lock attempts.
    attempts_max: usize = 50,
    /// The wait between attempts. The default total wait is about 490 ms.
    wait_ms: u64 = 10,
};

/// A parsed store file that owns its backing memory and answers entry lookups.
/// Open with `open`. Free with `deinit`.
pub const File = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *File) void {
        self.parsed.deinit();
    }

    /// The entry object stored under `key`, or null when it is absent or not an
    /// object.
    pub fn entry(self: *const File, key: []const u8) ?std.json.ObjectMap {
        return json.object(self.parsed.value.object.get(key));
    }
};

/// How many keys a save can leave in the file.
pub const SaveOptions = struct {
    /// The number of top-level keys the file can hold after the save. The
    /// rewrite drops the oldest keys first, in the order the file holds them. A
    /// save appends its own key last, so the file order is the write order.
    /// Null keeps every key.
    keys_max: ?usize = null,
};

/// One string field that must still match before its complete entry is removed.
pub const RemoveCondition = struct {
    key: []const u8,
    field: []const u8,
    expected: []const u8,
};

/// Open the store file at `path`, or null when it does not exist. A present
/// file that Pith cannot parse as a JSON object is `error.CorruptStore`, the
/// same failure a rewrite reports. Caller frees a non-null result with
/// `File.deinit`.
pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?File {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err|
        switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    defer gpa.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => return error.CorruptStore,
        };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.CorruptStore;
    return .{ .parsed = parsed };
}

/// Persist `entry` under `key` in the store file at `path`. The save creates
/// the parent directory and preserves every other top-level key already
/// present, up to `options.keys_max`. The write uses owner-only permissions.
pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    key: []const u8,
    entry: anytype,
    options: SaveOptions,
) !void {
    try rewrite(gpa, io, path, key, entry, options);
}

/// Remove `key` and rewrite every other entry verbatim. A missing store leaves
/// no data file, but the operation creates its parent directory and lock file.
pub fn remove(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    key: []const u8,
) !void {
    try rewrite(gpa, io, path, key, null, .{});
}

/// Remove one entry only when its string field still has the expected value.
/// Return true only when the matching entry was removed. Every Pith writer
/// holds the same lock across the comparison and rewrite.
pub fn removeMatchingString(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    condition: *const RemoveCondition,
) !bool {
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

/// Load, merge, and replace while every Pith writer holds one stable lock file.
fn rewrite(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    key: []const u8,
    entry: anytype,
    options: SaveOptions,
) !void {
    try ensureParent(io, path);
    var lock_file = try lockFile(gpa, io, path);
    defer lock_file.close(io);

    const existing = try readExisting(gpa, io, path);
    defer if (existing) |data| gpa.free(data);
    if (existing == null and @TypeOf(entry) == @TypeOf(null)) return;

    const body = try serialize(gpa, existing, key, entry, options);
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

/// Open the stable sibling lock file and take its exclusive advisory lock.
fn lockFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !std.Io.File {
    return lockFileWithPolicy(gpa, io, path, .{});
}

fn lockFileWithPolicy(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    comptime policy: LockPolicy,
) !std.Io.File {
    comptime std.debug.assert(policy.attempts_max > 0);
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
    defer gpa.free(lock_path);
    for (0..policy.attempts_max) |attempt| {
        const file = std.Io.Dir.cwd().createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = @enumFromInt(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock => {
                if (attempt + 1 == policy.attempts_max) return error.StoreBusy;
                try io.sleep(.fromMilliseconds(policy.wait_ms), .awake);
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
) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, existing, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => return error.CorruptStore,
        };
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptStore;
    const entry = json.object(parsed.value.object.get(condition.key)) orelse return false;
    const value = json.string(entry.get(condition.field)) orelse return false;
    return std.mem.eql(u8, value, condition.expected);
}

/// Atomically replace the file at `path` with `body` at owner-only
/// permissions: rename a temp file in the same directory over the destination.
/// A crash or cancellation mid-save leaves the old file intact rather than
/// truncated.
fn replaceFile(io: std.Io, path: []const u8, body: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = @enumFromInt(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, body);
    try atomic.replace(io);
}

/// The whole store file with `key` set to `entry` — or dropped, for a null
/// `entry` — and every other top-level key verbatim. An absent `existing`
/// starts from a fresh object. An unparseable or non-object one is
/// `error.CorruptStore` rather than a fresh start: no rewrite can wipe a
/// sibling key with a fresh start on a file it could not read. A `keys_max`
/// drops the oldest keys, which are the ones the file holds first. The saved
/// key always survives. The caller frees the result.
fn serialize(
    gpa: std.mem.Allocator,
    existing: ?[]const u8,
    key: []const u8,
    entry: anytype,
    options: SaveOptions,
) ![]u8 {
    // True for a save, false for a removal. Comptime, because a null `entry` is
    // the null type rather than a runtime value.
    const writes_key = @TypeOf(entry) != @TypeOf(null);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };

    try stringify.beginObject();
    if (existing) |data| {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch |err|
            switch (err) {
                error.OutOfMemory => return err,
                else => return error.CorruptStore,
            };
        defer parsed.deinit();
        if (parsed.value != .object) return error.CorruptStore;
        var dropped = dropCount(&parsed.value.object, key, writes_key, options);
        var entries = parsed.value.object.iterator();
        while (entries.next()) |field| {
            // Skip our own entry (rewritten fresh below, or dropped).
            if (std.mem.eql(u8, field.key_ptr.*, key)) continue;
            // Skip the oldest entries the cap has no room for.
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

    return out.toOwnedSlice();
}

/// How many of the keys already in `object` the cap leaves no room for. Set
/// `writes_key` for a save and clear it for a removal, because a written key
/// takes one of the slots. The two saturating subtractions accept an over-full
/// file and a cap below one slot, which are both normal.
fn dropCount(
    object: *const std.json.ObjectMap,
    key: []const u8,
    writes_key: bool,
    options: SaveOptions,
) usize {
    const keys_max = options.keys_max orelse return 0;
    // A contained key counts toward `count`, so this cannot underflow.
    const kept = object.count() - @intFromBool(object.contains(key));
    const room = keys_max -| @intFromBool(writes_key);
    return kept -| room;
}

const TestEntry = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,
};

test "File reads keyed entries" {
    const gpa = std.testing.allocator;

    var keyed: File = .{
        .parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            "{\"openai_subscription\":{\"access\":\"x\"}}",
            .{},
        ),
    };
    defer keyed.deinit();
    try std.testing.expect(keyed.entry("absent") == null);
    try std.testing.expectEqualStrings(
        "x",
        keyed.entry("openai_subscription").?.get("access").?.string,
    );
}

test "serialize adds an entry, preserving other keys" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1234 };

    const merged = try serialize(
        gpa,
        "{\"openai_subscription\":{\"access\":\"keep\"}}",
        "anthropic_subscription",
        entry,
        .{},
    );
    defer gpa.free(merged);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, merged, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(
        "keep",
        root.get("openai_subscription").?.object.get("access").?.string,
    );
    const added = root.get("anthropic_subscription").?.object;
    try std.testing.expectEqualStrings("at", added.get("access").?.string);
    try std.testing.expectEqual(@as(i64, 1234), added.get("expires_ms").?.integer);
}

test "serialize from nothing writes just the entry, and replaces its own" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "new", .refresh = "rt", .expires_ms = 1 };

    const fresh = try serialize(gpa, null, "openai_subscription", entry, .{});
    defer gpa.free(fresh);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fresh, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.count());
    try std.testing.expectEqualStrings(
        "new",
        parsed.value.object.get("openai_subscription").?.object.get("access").?.string,
    );

    // `serialize` replaces an existing entry under the same key and keeps a sibling.
    const replaced = try serialize(
        gpa,
        "{\"anthropic_subscription\":{\"access\":\"keep\"}," ++
            "\"openai_subscription\":{\"access\":\"old\"}}",
        "openai_subscription",
        entry,
        .{},
    );
    defer gpa.free(replaced);
    const parsed_replaced = try std.json.parseFromSlice(std.json.Value, gpa, replaced, .{});
    defer parsed_replaced.deinit();
    try std.testing.expectEqualStrings(
        "keep",
        parsed_replaced.value.object.get("anthropic_subscription").?.object.get("access").?.string,
    );
    try std.testing.expectEqualStrings(
        "new",
        parsed_replaced.value.object.get("openai_subscription").?.object.get("access").?.string,
    );
}

test "serialize errors on an unparseable or non-object existing file" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try std.testing.expectError(
        error.CorruptStore,
        serialize(gpa, "{ not valid json", "openai_subscription", entry, .{}),
    );
    try std.testing.expectError(
        error.CorruptStore,
        serialize(gpa, "[1,2,3]", "openai_subscription", entry, .{}),
    );
}

test "serialize drops a key, preserving other keys" {
    const gpa = std.testing.allocator;
    const merged = try serialize(
        gpa,
        "{\"anthropic_subscription\":{\"access\":\"a\"}," ++
            "\"openai_subscription\":{\"access\":\"o\"}}",
        "openai_subscription",
        null,
        .{},
    );
    defer gpa.free(merged);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, merged, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("openai_subscription") == null);
    try std.testing.expectEqualStrings(
        "a",
        root.get("anthropic_subscription").?.object.get("access").?.string,
    );

    // The removal of the last key leaves a valid empty object, not a wipe error.
    const emptied = try serialize(gpa, merged, "anthropic_subscription", null, .{});
    defer gpa.free(emptied);
    var parsed_empty = try std.json.parseFromSlice(std.json.Value, gpa, emptied, .{});
    defer parsed_empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_empty.value.object.count());
}

test "a key cap drops the oldest keys and keeps the saved one" {
    const gpa = std.testing.allocator;

    // Three keys, a cap of two: the oldest key goes and the saved key lands last.
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

    // A rewrite of a key already present frees its own slot, so nothing drops.
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

    // The saved key survives a cap with no room at all.
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    try ensureParent(io, path);
    var held = try lockFile(gpa, io, path);
    defer held.close(io);

    try std.testing.expectError(
        error.StoreBusy,
        lockFileWithPolicy(gpa, io, path, .{ .attempts_max = 2, .wait_ms = 0 }),
    );
}

test "save replaces the file atomically at owner-only permissions" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try save(gpa, io, path, "openai_subscription", entry, .{});
    const before = try tmp.dir.statFile(io, "auth.json", .{});
    try std.testing.expectEqual(
        @as(u32, 0o600),
        @as(u32, @intCast(@intFromEnum(before.permissions))) & 0o777,
    );

    // A rewrite lands on a fresh inode — renamed over, never truncated in place.
    try save(gpa, io, path, "anthropic_subscription", entry, .{});
    const after = try tmp.dir.statFile(io, "auth.json", .{});
    try std.testing.expect(before.inode != after.inode);

    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings(
        "at",
        file.entry("openai_subscription").?.get("access").?.string,
    );
    try std.testing.expectEqualStrings(
        "at",
        file.entry("anthropic_subscription").?.get("access").?.string,
    );
}

test "remove drops only its key on disk, and a missing file opens as null" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try std.testing.expect((try open(gpa, io, path)) == null);

    try save(gpa, io, path, "openai_subscription", entry, .{});
    try save(gpa, io, path, "anthropic_subscription", entry, .{});
    try remove(gpa, io, path, "openai_subscription");

    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("openai_subscription") == null);
    try std.testing.expectEqualStrings(
        "at",
        file.entry("anthropic_subscription").?.get("access").?.string,
    );
}

test "a conditional removal keeps a replacement entry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/auth.json",
        .{tmp.sub_path},
    );
    const original: TestEntry = .{ .access = "a1", .refresh = "r1", .expires_ms = 1 };
    const replacement: TestEntry = .{ .access = "a2", .refresh = "r2", .expires_ms = 2 };

    try save(gpa, io, path, "anthropic_subscription", original, .{});
    try save(gpa, io, path, "anthropic_subscription", replacement, .{});
    const replacement_removed = try removeMatchingString(gpa, io, path, &.{
        .key = "anthropic_subscription",
        .field = "refresh",
        .expected = "r1",
    });
    try std.testing.expect(!replacement_removed);

    {
        var file = (try open(gpa, io, path)).?;
        defer file.deinit();
        try std.testing.expectEqualStrings(
            "r2",
            file.entry("anthropic_subscription").?.get("refresh").?.string,
        );
    }

    const removed = try removeMatchingString(gpa, io, path, &.{
        .key = "anthropic_subscription",
        .field = "refresh",
        .expected = "r2",
    });
    try std.testing.expect(removed);
    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("anthropic_subscription") == null);
}

test "open, save, and remove refuse a corrupt file, leaving it intact on disk" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/auth.json", .{tmp.sub_path});
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "{ not json" });
    // Every entry point reports the same failure, so a caller translates one name.
    try std.testing.expectError(error.CorruptStore, open(gpa, io, path));
    try std.testing.expectError(
        error.CorruptStore,
        save(gpa, io, path, "openai_subscription", entry, .{}),
    );
    try std.testing.expectError(error.CorruptStore, remove(gpa, io, path, "openai_subscription"));

    const data = try tmp.dir.readFileAlloc(io, "auth.json", gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);
}

test "serialize errors on a corrupt file" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(
        error.CorruptStore,
        serialize(gpa, "{ not json", "openai_subscription", null, .{}),
    );
}
