const std = @import("std");

const ai = @import("ai");

const PromptHistory = @This();

gpa: std.mem.Allocator,
io: std.Io,
path: []const u8,
enabled: bool,
entries: std.ArrayList([]const u8),

pub const entries_max = 100;
pub const entry_bytes_max = 8 * 1024;

const codec = std.base64.url_safe_no_pad;

const Entry = struct {
    prompt: []const u8,
};

pub const OpenOptions = struct {
    working_directory: []const u8,
    home: []const u8,
    enabled: bool,
};

pub fn deinit(self: *PromptHistory) void {
    self.clearEntries();
    self.entries.deinit(self.gpa);
    self.gpa.free(self.path);
}

pub fn inert(gpa: std.mem.Allocator, io: std.Io) PromptHistory {
    return .{ .gpa = gpa, .io = io, .path = "", .enabled = false, .entries = .empty };
}

pub fn open(gpa: std.mem.Allocator, io: std.Io, options: *const OpenOptions) !PromptHistory {
    const directory = try std.fs.path.resolve(
        gpa,
        &.{ options.working_directory, options.home, ".drinky" },
    );
    defer gpa.free(directory);
    const path = try std.fs.path.join(gpa, &.{ directory, "prompt_history.json" });
    return .{
        .gpa = gpa,
        .io = io,
        .path = path,
        .enabled = options.enabled,
        .entries = .empty,
    };
}

pub fn load(self: *PromptHistory) !void {
    self.clearEntries();
    if (!self.enabled) return;
    var file = (try ai.json_store.open(self.gpa, self.io, self.path)) orelse return;
    defer file.deinit();
    errdefer self.clearEntries();
    const keys = file.keys();
    const first = keys.len -| entries_max;
    const count = keys.len - first;
    try self.entries.ensureTotalCapacity(self.gpa, count);
    for (0..count) |offset| {
        const index = keys.len - 1 - offset;
        self.entries.appendAssumeCapacity(try promptAlloc(self.gpa, &file, keys[index]));
    }
}

pub fn record(self: *const PromptHistory, prompt: []const u8) !void {
    if (!self.enabled) return;
    if (prompt.len > entry_bytes_max) return error.PromptTooLarge;
    const normalized = try normalizeAlloc(self.gpa, prompt);
    defer self.gpa.free(normalized);
    const key = try normalizedKeyAlloc(self.gpa, normalized);
    defer self.gpa.free(key);
    const encoded_prompt = try encodeAlloc(self.gpa, prompt);
    defer self.gpa.free(encoded_prompt);
    try ai.json_store.save(
        self.gpa,
        self.io,
        self.path,
        key,
        Entry{ .prompt = encoded_prompt },
        .{ .keys_max = entries_max },
    );
}

fn clearEntries(self: *PromptHistory) void {
    for (self.entries.items) |entry| self.gpa.free(entry);
    self.entries.clearRetainingCapacity();
}

fn promptAlloc(
    gpa: std.mem.Allocator,
    file: *const ai.json_store.File,
    key: []const u8,
) ![]u8 {
    const entry = file.entry(key) orelse return error.CorruptStore;
    const value = entry.get("prompt") orelse return error.CorruptStore;
    return switch (value) {
        .string => |encoded| decodeAlloc(gpa, encoded) catch |err| switch (err) {
            error.PromptTooLarge => error.CorruptStore,
            else => err,
        },
        else => error.CorruptStore,
    };
}

fn normalizeAlloc(gpa: std.mem.Allocator, prompt: []const u8) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(gpa);
    try normalized.ensureTotalCapacity(gpa, prompt.len);

    var has_line = false;
    var blank_lines: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;
    while (index < prompt.len) {
        const byte = prompt[index];
        if (byte != '\r' and byte != '\n') {
            index += 1;
            continue;
        }
        try appendNormalizedLine(
            gpa,
            &normalized,
            prompt[line_start..index],
            &has_line,
            &blank_lines,
        );
        index += 1;
        if (byte == '\r' and index < prompt.len and prompt[index] == '\n') index += 1;
        line_start = index;
    }
    try appendNormalizedLine(
        gpa,
        &normalized,
        prompt[line_start..],
        &has_line,
        &blank_lines,
    );
    return normalized.toOwnedSlice(gpa);
}

fn appendNormalizedLine(
    gpa: std.mem.Allocator,
    normalized: *std.ArrayList(u8),
    raw_line: []const u8,
    has_line: *bool,
    blank_lines: *usize,
) !void {
    const line = std.mem.trimEnd(u8, raw_line, " \t");
    if (line.len == 0) {
        if (has_line.*) blank_lines.* += 1;
        return;
    }
    if (has_line.*) try normalized.appendNTimes(gpa, '\n', blank_lines.* + 1);
    try normalized.appendSlice(gpa, line);
    has_line.* = true;
    blank_lines.* = 0;
}

fn normalizedKeyAlloc(gpa: std.mem.Allocator, normalized: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized, &digest, .{});
    const key = try gpa.alloc(u8, codec.Encoder.calcSize(digest.len));
    _ = codec.Encoder.encode(key, &digest);
    return key;
}

fn encodeAlloc(gpa: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const key = try gpa.alloc(u8, codec.Encoder.calcSize(prompt.len));
    _ = codec.Encoder.encode(key, prompt);
    return key;
}

fn decodeAlloc(gpa: std.mem.Allocator, key: []const u8) ![]u8 {
    const size = try codec.Decoder.calcSizeForSlice(key);
    if (size > entry_bytes_max) return error.PromptTooLarge;
    const prompt = try gpa.alloc(u8, size);
    errdefer gpa.free(prompt);
    try codec.Decoder.decode(prompt, key);
    return prompt;
}

fn tmpHome(gpa: std.mem.Allocator, io: std.Io, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
}

fn openForTest(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    project: []const u8,
) !PromptHistory {
    return open(gpa, io, &.{ .working_directory = project, .home = home, .enabled = true });
}

fn writeForTest(io: std.Io, tmp: *const std.testing.TmpDir, data: []const u8) !void {
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = "prompt_history.json", .data = data });
}

fn readForTest(gpa: std.mem.Allocator, io: std.Io, tmp: *const std.testing.TmpDir) ![]u8 {
    return tmp.dir.readFileAlloc(io, ".drinky/prompt_history.json", gpa, .unlimited);
}

fn expectEntries(history: *const PromptHistory, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, history.entries.items.len);
    for (expected, history.entries.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "an absent file loads an empty list, and two projects share one file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var first = try openForTest(gpa, io, home, "/work/one");
    defer first.deinit();
    var second = try openForTest(gpa, io, home, "/work/two");
    defer second.deinit();
    try std.testing.expectEqualStrings(first.path, second.path);
    try std.testing.expect(std.mem.endsWith(u8, first.path, "/.drinky/prompt_history.json"));

    try first.load();
    try expectEntries(&first, &.{});
}

test "a record survives a reload byte for byte under its normalized key" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    const exact = "first line\r\nsecond line\n\ttab \x00\xff\xfe and \"quotes\" /not a command";

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    try history.record(exact);
    try history.load();
    try expectEntries(&history, &.{exact});

    var file = (try ai.json_store.open(gpa, io, history.path)).?;
    defer file.deinit();
    const keys = file.keys();
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqual(
        codec.Encoder.calcSize(std.crypto.hash.sha2.Sha256.digest_length),
        keys[0].len,
    );
    const encoded = file.entry(keys[0]).?.get("prompt").?.string;
    const decoded = try decodeAlloc(gpa, encoded);
    defer gpa.free(decoded);
    try std.testing.expectEqualStrings(exact, decoded);
}

test "a repeated record moves to the newest position without a second entry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    try history.record("one");
    try history.record("two");
    try history.record("three");
    try history.load();
    try expectEntries(&history, &.{ "three", "two", "one" });

    try history.record("one");
    try history.load();
    try expectEntries(&history, &.{ "one", "three", "two" });
}

test "a normalized repeat keeps the latest submitted text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    try history.record("\n\nalpha  \r\nbeta\t\r\n\t\r\n");
    try history.record("other");
    const latest = "alpha\nbeta\n\n";
    try history.record(latest);
    try history.load();
    try expectEntries(&history, &.{ latest, "other" });

    var file = (try ai.json_store.open(gpa, io, history.path)).?;
    defer file.deinit();
    try std.testing.expectEqual(@as(usize, 2), file.keys().len);
}

test "the entry past the count drops the least recently used one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var data: std.Io.Writer.Allocating = .init(gpa);
    defer data.deinit();
    try data.writer.writeByte('{');
    for (0..entries_max) |index| {
        if (index > 0) try data.writer.writeByte(',');
        var prompt_buffer: [16]u8 = undefined;
        const prompt = try std.fmt.bufPrint(&prompt_buffer, "prompt {d}", .{index});
        const key = try normalizedKeyAlloc(gpa, prompt);
        defer gpa.free(key);
        const encoded = try encodeAlloc(gpa, prompt);
        defer gpa.free(encoded);
        try data.writer.print("\"{s}\":{{\"prompt\":\"{s}\"}}", .{ key, encoded });
    }
    try data.writer.writeByte('}');
    try writeForTest(io, &tmp, data.written());

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    try history.load();
    try std.testing.expectEqual(entries_max, history.entries.items.len);
    try std.testing.expectEqualStrings("prompt 0", history.entries.items[entries_max - 1]);

    try history.record("one more");
    try history.load();
    try std.testing.expectEqual(entries_max, history.entries.items.len);
    try std.testing.expectEqualStrings("one more", history.entries.items[0]);
    try std.testing.expectEqualStrings("prompt 1", history.entries.items[entries_max - 1]);
    for (history.entries.items) |entry| try std.testing.expect(!std.mem.eql(u8, entry, "prompt 0"));
}

test "an entry of the limit is accepted and one above it is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    const largest = try gpa.alloc(u8, entry_bytes_max);
    defer gpa.free(largest);
    @memset(largest, 'x');
    try history.record(largest);
    try history.load();
    try expectEntries(&history, &.{largest});
    const before = try readForTest(gpa, io, &tmp);
    defer gpa.free(before);

    const oversized = try gpa.alloc(u8, entry_bytes_max + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'y');
    try std.testing.expectError(error.PromptTooLarge, history.record(oversized));
    const after = try readForTest(gpa, io, &tmp);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "an oversized stored prompt does not describe the next prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    const key = try normalizedKeyAlloc(gpa, "stored");
    defer gpa.free(key);
    const oversized = try gpa.alloc(u8, entry_bytes_max + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    const encoded = try encodeAlloc(gpa, oversized);
    defer gpa.free(encoded);
    const data = try std.fmt.allocPrint(
        gpa,
        "{{\"{s}\":{{\"prompt\":\"{s}\"}}}}",
        .{ key, encoded },
    );
    defer gpa.free(data);
    try writeForTest(io, &tmp, data);

    try history.record("valid");
    try std.testing.expectError(error.CorruptStore, history.load());
    try expectEntries(&history, &.{});
}

test "the fixed limits keep a Drinky-written file below the documented budget" {
    const key_bytes = codec.Encoder.calcSize(std.crypto.hash.sha2.Sha256.digest_length);
    const prompt_bytes = codec.Encoder.calcSize(entry_bytes_max);
    const entry_overhead_bytes = "\"\":{\"prompt\":\"\"},".len;
    const file_bytes_max = 2 + entries_max *
        (key_bytes + prompt_bytes + entry_overhead_bytes);
    try std.testing.expectEqual(@as(usize, 43), key_bytes);
    try std.testing.expectEqual(@as(usize, 10_923), prompt_bytes);
    try std.testing.expect(file_bytes_max < 1_100_000);
}

test "two instances merge their writes, and a reload sees the other one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var first = try openForTest(gpa, io, home, "/work/one");
    defer first.deinit();
    var second = try openForTest(gpa, io, home, "/work/two");
    defer second.deinit();
    try first.load();
    try expectEntries(&first, &.{});

    try first.record("from the first");
    try second.record("from the second");
    try first.record("first again");
    try first.load();
    try expectEntries(&first, &.{ "first again", "from the second", "from the first" });
    try second.load();
    try expectEntries(&second, &.{ "first again", "from the second", "from the first" });
}

test "lock contention reports the failure and a later record replays nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    try history.record("before");
    ai.json_store.lock_policy = .{ .attempts_max = 2, .wait_ms = 0 };
    defer ai.json_store.lock_policy = .{};
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{history.path});
    defer gpa.free(lock_path);
    {
        var held = try std.Io.Dir.cwd().createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = @enumFromInt(0o600),
        });
        defer held.close(io);
        try std.testing.expectError(error.StoreBusy, history.record("lost"));
    }

    try history.record("after");
    try history.load();
    try expectEntries(&history, &.{ "after", "before" });
}

test "a corrupt file fails every action and stays byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp, "{ not json");

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    try std.testing.expectError(error.CorruptStore, history.record("prompt"));
    try std.testing.expectError(error.CorruptStore, history.load());
    try expectEntries(&history, &.{});
    const data = try readForTest(gpa, io, &tmp);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);
}

test "invalid Base64 data fails the read and leaves no entry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var history = try openForTest(gpa, io, home, "/work");
    defer history.deinit();
    const key = try normalizedKeyAlloc(gpa, "valid");
    defer gpa.free(key);

    const invalid_character = try std.fmt.allocPrint(
        gpa,
        "{{\"{s}\":{{\"prompt\":\"not base64!\"}}}}",
        .{key},
    );
    defer gpa.free(invalid_character);
    try writeForTest(io, &tmp, invalid_character);
    try std.testing.expectError(error.InvalidCharacter, history.load());
    try expectEntries(&history, &.{});

    const invalid_padding = try std.fmt.allocPrint(
        gpa,
        "{{\"{s}\":{{\"prompt\":\"A\"}}}}",
        .{key},
    );
    defer gpa.free(invalid_padding);
    try writeForTest(io, &tmp, invalid_padding);
    try std.testing.expectError(error.InvalidPadding, history.load());
    try expectEntries(&history, &.{});
}

test "a disabled history reads nothing, records nothing, and touches no file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp, "{\"dmFsaWQ\":{}}");

    var history = try open(gpa, io, &.{
        .working_directory = "/work",
        .home = home,
        .enabled = false,
    });
    defer history.deinit();
    try std.testing.expect(!history.enabled);
    try history.record("prompt");
    try history.load();
    try expectEntries(&history, &.{});
    const data = try readForTest(gpa, io, &tmp);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{\"dmFsaWQ\":{}}", data);

    var idle: PromptHistory = .inert(gpa, io);
    defer idle.deinit();
    try std.testing.expect(!idle.enabled);
    try idle.record("prompt");
    try idle.load();
    try expectEntries(&idle, &.{});
}
