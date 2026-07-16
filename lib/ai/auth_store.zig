//! The provider-keyed `auth.json` both credential stores share: a top-level
//! object mapping each account key to that account's token entry. This module
//! owns the file shape — opening it and reading one account's entry, and a
//! load-merge-write that rewrites one entry while preserving every other
//! account's verbatim so a refresh never clobbers a sibling account. Each
//! provider owns its own entry fields (passed as `anytype`); nothing here knows
//! a token shape.

const std = @import("std");

/// The legacy flat-file keys, from before the keyed layout: a top-level `access`
/// object held a single (implicitly Anthropic subscription) credential. A store
/// migrating that file reads it through `File.legacyFlat` and rewrites keyed with
/// `drop_flat`, so these stale top-level keys do not linger beside the new entry.
const flat_keys = [_][]const u8{ "access", "refresh", "expires_ms" };

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

    /// The whole root read as one entry when the file is a legacy flat credential
    /// object (a top-level `access` key, from before the keyed layout), or null
    /// when it is already keyed.
    pub fn legacyFlat(self: *const File) ?std.json.ObjectMap {
        const root = self.parsed.value.object;
        return if (root.contains("access")) root else null;
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
/// directory), preserving every other top-level key already present. With
/// `.drop_flat`, the legacy flat-file keys are dropped instead of preserved —
/// used the first time a pre-keyed file is rewritten keyed. Written at owner-only
/// permissions.
pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    key: []const u8,
    entry: anytype,
    options: struct { drop_flat: bool = false },
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

    const body = try serializeMerged(gpa, existing, key, entry, options.drop_flat);
    defer gpa.free(body);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = body,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
}

/// The whole `auth.json` with `key` set to `entry`, re-emitting every other
/// top-level key verbatim (except this `key`, always rewritten, and the flat
/// keys when `drop_flat`). An absent `existing` starts from a fresh object; an
/// unparseable or non-object `existing` is `error.BadCredentials` rather than a
/// fresh start, so a save can never wipe a sibling account by starting over on a
/// file it could not read. Caller frees the result.
fn serializeMerged(
    gpa: std.mem.Allocator,
    existing: ?[]const u8,
    key: []const u8,
    entry: anytype,
    drop_flat: bool,
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
            // Skip our own entry (rewritten fresh below) and, when migrating, the
            // legacy flat keys.
            if (std.mem.eql(u8, field.key_ptr.*, key)) continue;
            if (drop_flat and isFlatKey(field.key_ptr.*)) continue;
            try json.objectField(field.key_ptr.*);
            try json.write(field.value_ptr.*);
        }
    }
    try json.objectField(key);
    try json.write(entry);
    try json.endObject();

    return out.toOwnedSlice();
}

fn isFlatKey(name: []const u8) bool {
    for (flat_keys) |flat| {
        if (std.mem.eql(u8, name, flat)) return true;
    }
    return false;
}

const TestEntry = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,
};

test "File reads keyed entries and legacy-flat roots" {
    const gpa = std.testing.allocator;

    var keyed: File = .{
        .parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"openai_subscription\":{\"access\":\"x\"}}", .{}),
    };
    defer keyed.deinit();
    try std.testing.expect(keyed.legacyFlat() == null);
    try std.testing.expect(keyed.entry("absent") == null);
    try std.testing.expectEqualStrings("x", keyed.entry("openai_subscription").?.get("access").?.string);

    var flat: File = .{
        .parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"access\":\"a\",\"refresh\":\"r\",\"expires_ms\":1}", .{}),
    };
    defer flat.deinit();
    try std.testing.expectEqualStrings("a", flat.legacyFlat().?.get("access").?.string);
}

test "serializeMerged adds an entry, preserving other accounts" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1234 };

    const merged = try serializeMerged(
        gpa,
        "{\"openai_subscription\":{\"access\":\"keep\"}}",
        "anthropic_subscription",
        entry,
        false,
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

    const fresh = try serializeMerged(gpa, null, "openai_subscription", entry, false);
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
        false,
    );
    defer gpa.free(replaced);
    const parsed_replaced = try std.json.parseFromSlice(std.json.Value, gpa, replaced, .{});
    defer parsed_replaced.deinit();
    try std.testing.expectEqualStrings("keep", parsed_replaced.value.object.get("anthropic_subscription").?.object.get("access").?.string);
    try std.testing.expectEqualStrings("new", parsed_replaced.value.object.get("openai_subscription").?.object.get("access").?.string);
}

test "drop_flat migrates a legacy flat Anthropic file beside an existing openai entry" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "migrated", .refresh = "rt", .expires_ms = 9 };

    // A legacy flat Anthropic credential (top-level access/refresh/expires_ms)
    // alongside a keyed openai entry: the flat keys are dropped, the openai entry
    // preserved, and the Anthropic subscription entry written fresh.
    const merged = try serializeMerged(
        gpa,
        "{\"access\":\"flat_at\",\"refresh\":\"flat_rt\",\"expires_ms\":5," ++
            "\"openai_subscription\":{\"access\":\"oa\",\"account_id\":\"acct_1\"}}",
        "anthropic_subscription",
        entry,
        true,
    );
    defer gpa.free(merged);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, merged, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("access") == null);
    try std.testing.expect(root.get("refresh") == null);
    try std.testing.expect(root.get("expires_ms") == null);
    try std.testing.expectEqualStrings("oa", root.get("openai_subscription").?.object.get("access").?.string);
    try std.testing.expectEqualStrings("migrated", root.get("anthropic_subscription").?.object.get("access").?.string);
}

test "serializeMerged errors on an unparseable or non-object existing file" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "at", .refresh = "rt", .expires_ms = 1 };

    // A corrupt existing file must not be silently overwritten — that would drop
    // every sibling account's entry on a refresh save. Both a syntactically
    // invalid file and a valid non-object value are rejected.
    try std.testing.expectError(
        error.BadCredentials,
        serializeMerged(gpa, "{ not valid json", "openai_subscription", entry, false),
    );
    try std.testing.expectError(
        error.BadCredentials,
        serializeMerged(gpa, "[1,2,3]", "openai_subscription", entry, false),
    );
}

test "serializeMerged without drop_flat keeps a legacy flat entry untouched" {
    const gpa = std.testing.allocator;
    const entry: TestEntry = .{ .access = "oa", .refresh = "rt", .expires_ms = 1 };

    // An openai save must not disturb the legacy flat keys — they are Anthropic's
    // to migrate, not to lose.
    const merged = try serializeMerged(
        gpa,
        "{\"access\":\"flat_at\",\"refresh\":\"flat_rt\",\"expires_ms\":5}",
        "openai_subscription",
        entry,
        false,
    );
    defer gpa.free(merged);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, merged, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("flat_at", root.get("access").?.string);
    try std.testing.expectEqualStrings("oa", root.get("openai_subscription").?.object.get("access").?.string);
}
