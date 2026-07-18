//! The provider-keyed `auth.json` both credential stores share: a top-level
//! object mapping each account key to that account's token entry. This module
//! owns the file shape — opening it and reading one account's entry, and a
//! load-merge-write that rewrites one entry while preserving every other
//! account's verbatim so a refresh never clobbers a sibling account. Each
//! provider owns its own entry fields (passed as `anytype`); nothing here knows
//! a token shape.

const std = @import("std");

/// A parsed `auth.json`, owning its backing memory, that answers entry lookups.
/// Open with `open`; free with `deinit`.
pub const File = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *File) void {
        self.parsed.deinit();
    }

    /// The entry object stored under `key`, or null when it is absent or not an
    /// object.
    pub fn entry(self: *const File, key: []const u8) ?std.json.ObjectMap {
        return switch (self.parsed.value.object.get(key) orelse return null) {
            .object => |object| object,
            else => null,
        };
    }
};

/// Open the `auth.json` at `path`, or null when it does not exist. A present
/// file that is not a JSON object is `error.BadCredentials`. Caller frees a
/// non-null result with `File.deinit`.
pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?File {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.BadCredentials;
    return .{ .parsed = parsed };
}

/// Persist `entry` under `key` in the `auth.json` at `path` (creating its parent
/// directory), preserving every other top-level key already present. Written at
/// owner-only permissions.
pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    key: []const u8,
    entry: anytype,
) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const existing: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |data| gpa.free(data);

    const body = try serializeMerged(gpa, existing, key, entry);
    defer gpa.free(body);
    try replaceFile(io, path, body);
}

/// Atomically replace the file at `path` with `body` at owner-only
/// permissions: a temp file in the same directory renamed over the
/// destination, so a crash or cancellation mid-save leaves the old file
/// intact rather than truncated.
fn replaceFile(io: std.Io, path: []const u8, body: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = @enumFromInt(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, body);
    try atomic.replace(io);
}

/// The whole `auth.json` with `key` set to `entry`, re-emitting every other
/// top-level key verbatim (except this `key`, always rewritten). An absent
/// `existing` starts from a fresh object; an unparseable or non-object
/// `existing` is `error.BadCredentials` rather than a fresh start, so a save can
/// never wipe a sibling account by starting over on a file it could not read.
/// Caller frees the result.
fn serializeMerged(
    gpa: std.mem.Allocator,
    existing: ?[]const u8,
    key: []const u8,
    entry: anytype,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try json.beginObject();
    if (existing) |data| {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.BadCredentials,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.BadCredentials;
        var entries = parsed.value.object.iterator();
        while (entries.next()) |field| {
            // Skip our own entry (rewritten fresh below); re-emit every sibling.
            if (std.mem.eql(u8, field.key_ptr.*, key)) continue;
            try json.objectField(field.key_ptr.*);
            try json.write(field.value_ptr.*);
        }
    }
    try json.objectField(key);
    try json.write(entry);
    try json.endObject();

    return out.toOwnedSlice();
}

/// Remove `key` from the `auth.json` at `path`, rewriting every other entry
/// verbatim. A missing file is a no-op — nothing to remove. An unparseable or
/// non-object file is `error.BadCredentials` rather than a destructive rewrite,
/// matching `save`.
pub fn remove(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    key: []const u8,
) !void {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(existing);

    const body = try serializeWithout(gpa, existing, key);
    defer gpa.free(body);
    try replaceFile(io, path, body);
}

/// The whole `auth.json` with `key` dropped, re-emitting every other top-level
/// key verbatim. An unparseable or non-object file is `error.BadCredentials`, so
/// a removal never wipes a sibling account by starting over on a file it could
/// not read. Caller frees the result.
fn serializeWithout(
    gpa: std.mem.Allocator,
    existing: []const u8,
    key: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, existing, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.BadCredentials,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadCredentials;

    try json.beginObject();
    var entries = parsed.value.object.iterator();
    while (entries.next()) |field| {
        if (std.mem.eql(u8, field.key_ptr.*, key)) continue;
        try json.objectField(field.key_ptr.*);
        try json.write(field.value_ptr.*);
    }
    try json.endObject();

    return out.toOwnedSlice();
}

const TestEntry = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,
};

test "File reads keyed entries" {
    const gpa = std.testing.allocator;

    var keyed: File = .{
        .parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"openai_subscription\":{\"access\":\"x\"}}", .{}),
    };
    defer keyed.deinit();
    try std.testing.expect(keyed.entry("absent") == null);
    try std.testing.expectEqualStrings("x", keyed.entry("openai_subscription").?.get("access").?.string);
}

test "serializeMerged adds an entry, preserving other accounts" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1234 };

    const merged = try serializeMerged(
        gpa,
        "{\"openai_subscription\":{\"access\":\"keep\"}}",
        "anthropic_subscription",
        entry,
    );
    defer gpa.free(merged);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, merged, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("keep", root.get("openai_subscription").?.object.get("access").?.string);
    const added = root.get("anthropic_subscription").?.object;
    try std.testing.expectEqualStrings("at", added.get("access").?.string);
    try std.testing.expectEqual(@as(i64, 1234), added.get("expires_ms").?.integer);
}

test "serializeMerged from nothing writes just the entry, and replaces its own" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "new", .refresh = "rt", .expires_ms = 1 };

    const fresh = try serializeMerged(gpa, null, "openai_subscription", entry);
    defer gpa.free(fresh);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fresh, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.count());
    try std.testing.expectEqualStrings("new", parsed.value.object.get("openai_subscription").?.object.get("access").?.string);

    // An existing entry under the same key is replaced, a sibling kept.
    const replaced = try serializeMerged(
        gpa,
        "{\"anthropic_subscription\":{\"access\":\"keep\"},\"openai_subscription\":{\"access\":\"old\"}}",
        "openai_subscription",
        entry,
    );
    defer gpa.free(replaced);
    const parsed_replaced = try std.json.parseFromSlice(std.json.Value, gpa, replaced, .{});
    defer parsed_replaced.deinit();
    try std.testing.expectEqualStrings("keep", parsed_replaced.value.object.get("anthropic_subscription").?.object.get("access").?.string);
    try std.testing.expectEqualStrings("new", parsed_replaced.value.object.get("openai_subscription").?.object.get("access").?.string);
}

test "serializeMerged errors on an unparseable or non-object existing file" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    // A corrupt existing file must not be silently overwritten — that would drop
    // every sibling account's entry on a refresh save. Both a syntactically
    // invalid file and a valid non-object value are rejected.
    try std.testing.expectError(
        error.BadCredentials,
        serializeMerged(gpa, "{ not valid json", "openai_subscription", entry),
    );
    try std.testing.expectError(
        error.BadCredentials,
        serializeMerged(gpa, "[1,2,3]", "openai_subscription", entry),
    );
}

test "serializeWithout drops a key, preserving other accounts" {
    const gpa = std.testing.allocator;
    const merged = try serializeWithout(
        gpa,
        "{\"anthropic_subscription\":{\"access\":\"a\"},\"openai_subscription\":{\"access\":\"o\"}}",
        "openai_subscription",
    );
    defer gpa.free(merged);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, merged, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("openai_subscription") == null);
    try std.testing.expectEqualStrings("a", root.get("anthropic_subscription").?.object.get("access").?.string);

    // Removing the last account leaves a valid empty object, not a wipe error.
    const emptied = try serializeWithout(gpa, merged, "anthropic_subscription");
    defer gpa.free(emptied);
    var parsed_empty = try std.json.parseFromSlice(std.json.Value, gpa, emptied, .{});
    defer parsed_empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_empty.value.object.count());
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

    try save(gpa, io, path, "openai_subscription", entry);
    const before = try tmp.dir.statFile(io, "auth.json", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@intFromEnum(before.permissions))) & 0o777);

    // A rewrite lands on a fresh inode — renamed over, never truncated in place.
    try save(gpa, io, path, "anthropic_subscription", entry);
    const after = try tmp.dir.statFile(io, "auth.json", .{});
    try std.testing.expect(before.inode != after.inode);

    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expectEqualStrings("at", file.entry("openai_subscription").?.get("access").?.string);
    try std.testing.expectEqualStrings("at", file.entry("anthropic_subscription").?.get("access").?.string);
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

    try save(gpa, io, path, "openai_subscription", entry);
    try save(gpa, io, path, "anthropic_subscription", entry);
    try remove(gpa, io, path, "openai_subscription");

    var file = (try open(gpa, io, path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("openai_subscription") == null);
    try std.testing.expectEqualStrings("at", file.entry("anthropic_subscription").?.get("access").?.string);
}

test "save and remove refuse a corrupt file, leaving it intact on disk" {
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
    try std.testing.expectError(error.BadCredentials, save(gpa, io, path, "openai_subscription", entry));
    try std.testing.expectError(error.BadCredentials, remove(gpa, io, path, "openai_subscription"));

    const data = try tmp.dir.readFileAlloc(io, "auth.json", gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);
}

test "serializeWithout errors on a corrupt file" {
    const gpa = std.testing.allocator;

    // A corrupt file is rejected rather than overwritten with a wipe.
    try std.testing.expectError(
        error.BadCredentials,
        serializeWithout(gpa, "{ not json", "openai_subscription"),
    );
}
