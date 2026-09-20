const std = @import("std");

const ai = @import("ai");

const Store = @This();

gpa: std.mem.Allocator,
io: std.Io,
path: []const u8,
bots: std.ArrayList(Bot),
usernames: std.ArrayList([]const u8),
load_error: ?anyerror,

pub const Bot = struct {
    token: []const u8,
    id: i64,
    username: []const u8,
    chat_id: ?i64,

    fn deinit(self: *const Bot, gpa: std.mem.Allocator) void {
        gpa.free(self.token);
        gpa.free(self.username);
    }
};

pub fn open(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !Store {
    const path = try std.fs.path.join(gpa, &.{ home, ".drinky", "remote.json" });
    errdefer gpa.free(path);
    var store: Store = .{
        .gpa = gpa,
        .io = io,
        .path = path,
        .bots = .empty,
        .usernames = .empty,
        .load_error = null,
    };
    store.read() catch |err| {
        store.load_error = err;
    };
    return store;
}

pub fn inert(gpa: std.mem.Allocator, io: std.Io) Store {
    return .{
        .gpa = gpa,
        .io = io,
        .path = "",
        .bots = .empty,
        .usernames = .empty,
        .load_error = null,
    };
}

pub fn deinit(self: *Store) void {
    for (self.bots.items) |*bot| bot.deinit(self.gpa);
    self.bots.deinit(self.gpa);
    self.usernames.deinit(self.gpa);
    if (self.path.len > 0) self.gpa.free(self.path);
}

pub fn get(self: *const Store, index: usize) ?*const Bot {
    if (index >= self.bots.items.len) return null;
    return &self.bots.items[index];
}

pub fn save(self: *Store, bot: *const Bot) !void {
    const token = try self.gpa.dupe(u8, bot.token);
    errdefer self.gpa.free(token);
    const username = try self.gpa.dupe(u8, bot.username);
    errdefer self.gpa.free(username);
    try self.bots.ensureUnusedCapacity(self.gpa, 1);
    try self.usernames.ensureTotalCapacity(self.gpa, self.bots.items.len + 1);
    var key_buffer: [24]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buffer, "{d}", .{bot.id});
    if (self.path.len > 0) try ai.json_store.save(self.gpa, self.io, self.path, key, bot.*, .{});
    for (self.bots.items, 0..) |saved, index| {
        if (saved.id != bot.id) continue;
        saved.deinit(self.gpa);
        _ = self.bots.orderedRemove(index);
        break;
    }
    self.bots.appendAssumeCapacity(.{
        .token = token,
        .id = bot.id,
        .username = username,
        .chat_id = bot.chat_id,
    });
    self.refreshUsernames();
}

pub fn remove(self: *Store, index: usize) !void {
    std.debug.assert(index < self.bots.items.len);
    var key_buffer: [24]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buffer, "{d}", .{self.bots.items[index].id});
    if (self.path.len > 0) try ai.json_store.remove(self.gpa, self.io, self.path, key);
    const removed = self.bots.orderedRemove(index);
    removed.deinit(self.gpa);
    self.refreshUsernames();
}

fn read(self: *Store) !void {
    var file = (try ai.json_store.open(self.gpa, self.io, self.path)) orelse return;
    defer file.deinit();
    var loaded: std.ArrayList(Bot) = .empty;
    errdefer {
        for (loaded.items) |*bot| bot.deinit(self.gpa);
        loaded.deinit(self.gpa);
    }
    var entries = file.parsed.value.object.iterator();
    while (entries.next()) |field| {
        const entry = switch (field.value_ptr.*) {
            .object => |object| object,
            else => continue,
        };
        const token = readString(&entry, "token") orelse continue;
        const id = readInteger(&entry, "id") orelse continue;
        const username = readString(&entry, "username") orelse continue;
        const token_copy = try self.gpa.dupe(u8, token);
        errdefer self.gpa.free(token_copy);
        const username_copy = try self.gpa.dupe(u8, username);
        errdefer self.gpa.free(username_copy);
        try loaded.append(self.gpa, .{
            .token = token_copy,
            .id = id,
            .username = username_copy,
            .chat_id = readInteger(&entry, "chat_id"),
        });
    }
    try self.usernames.ensureTotalCapacity(self.gpa, loaded.items.len);
    std.debug.assert(self.bots.items.len == 0);
    self.bots.deinit(self.gpa);
    self.bots = loaded;
    self.refreshUsernames();
}

fn refreshUsernames(self: *Store) void {
    std.debug.assert(self.usernames.capacity >= self.bots.items.len);
    self.usernames.clearRetainingCapacity();
    for (self.bots.items) |bot| self.usernames.appendAssumeCapacity(bot.username);
}

fn readString(entry: *const std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (entry.get(field) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn readInteger(entry: *const std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (entry.get(field) orelse return null) {
        .integer => |value| value,
        else => null,
    };
}

fn testHome(buffer: []u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "a missing file opens as no bot, and a save then reads back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testHome(&home_buffer, &tmp);

    var store = try Store.open(gpa, io, home);
    defer store.deinit();
    try std.testing.expect(store.load_error == null);
    try std.testing.expectEqual(@as(usize, 0), store.bots.items.len);

    try store.save(&.{ .token = "123:abc", .id = 123, .username = "drinky_bot", .chat_id = null });
    try store.save(&.{ .token = "456:def", .id = 456, .username = "other_bot", .chat_id = 77 });
    try std.testing.expectEqual(@as(usize, 2), store.usernames.items.len);
    try std.testing.expectEqualStrings("drinky_bot", store.usernames.items[0]);

    try store.save(&.{ .token = "123:abc", .id = 123, .username = "drinky_bot", .chat_id = 42 });
    try std.testing.expectEqual(@as(usize, 2), store.bots.items.len);
    try std.testing.expectEqual(@as(?i64, 42), store.bots.items[1].chat_id);
    try std.testing.expectEqualStrings("other_bot", store.usernames.items[0]);

    var reopened = try Store.open(gpa, io, home);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.bots.items.len);
    try std.testing.expectEqualStrings("other_bot", reopened.get(0).?.username);
    try std.testing.expectEqualStrings("123:abc", reopened.bots.items[1].token);
    try std.testing.expectEqual(@as(i64, 123), reopened.bots.items[1].id);
    try std.testing.expectEqual(@as(?i64, 42), reopened.bots.items[1].chat_id);
    try std.testing.expect(reopened.get(2) == null);

    const stat = try tmp.dir.statFile(io, ".drinky/remote.json", .{});
    try std.testing.expectEqual(
        @as(u32, 0o600),
        @as(u32, @intCast(@intFromEnum(stat.permissions))) & 0o777,
    );
}

test "remove drops one bot from the file and the memory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testHome(&home_buffer, &tmp);

    var store = try Store.open(gpa, io, home);
    defer store.deinit();
    try store.save(&.{ .token = "1:a", .id = 1, .username = "first_bot", .chat_id = 5 });
    try store.save(&.{ .token = "2:b", .id = 2, .username = "second_bot", .chat_id = 6 });
    try store.remove(0);
    try std.testing.expectEqual(@as(usize, 1), store.bots.items.len);
    try std.testing.expectEqualStrings("second_bot", store.usernames.items[0]);

    var reopened = try Store.open(gpa, io, home);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), reopened.bots.items.len);
    try std.testing.expectEqual(@as(i64, 2), reopened.bots.items[0].id);
}

test "a corrupt file reads as no bot and keeps its error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testHome(&home_buffer, &tmp);
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/remote.json", .data = "{ not json" });

    var store = try Store.open(gpa, io, home);
    defer store.deinit();
    try std.testing.expectEqual(@as(?anyerror, error.CorruptStore), store.load_error);
    try std.testing.expectEqual(@as(usize, 0), store.bots.items.len);
    try std.testing.expectError(
        error.CorruptStore,
        store.save(&.{ .token = "1:a", .id = 1, .username = "bot", .chat_id = null }),
    );
    try std.testing.expectEqual(@as(usize, 0), store.bots.items.len);
}

test "an entry that lacks a field drops in silence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testHome(&home_buffer, &tmp);
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/remote.json",
        .data =
        \\{"1":{"token":"1:a","id":1},"2":{"token":"2:b","id":2,"username":"bot","chat_id":"x"},
        \\"3":7}
        ,
    });

    var store = try Store.open(gpa, io, home);
    defer store.deinit();
    try std.testing.expect(store.load_error == null);
    try std.testing.expectEqual(@as(usize, 1), store.bots.items.len);
    try std.testing.expectEqual(@as(i64, 2), store.bots.items[0].id);
    try std.testing.expect(store.bots.items[0].chat_id == null);
}

test "a read or a save that fails at any allocation leaks nothing and stays whole" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testHome(&home_buffer, &tmp);
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/remote.json",
        .data =
        \\{"1":{"token":"1:a","id":1,"username":"first_bot","chat_id":5},
        \\"2":{"token":"2:b","id":2,"username":"second_bot","chat_id":6}}
        ,
    });

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var store = Store.open(failing.allocator(), io, home) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer store.deinit();
        if (store.load_error == null) {
            try std.testing.expectEqual(@as(usize, 2), store.bots.items.len);
            break;
        }
        try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), store.load_error);
        try std.testing.expectEqual(@as(usize, 0), store.bots.items.len);
        try std.testing.expectEqual(@as(usize, 0), store.usernames.items.len);
    }
    try std.testing.expect(fail_index < 64);

    fail_index = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var store = try Store.open(failing.allocator(), io, home);
        defer store.deinit();
        try std.testing.expectEqual(@as(usize, 2), store.bots.items.len);
        failing.fail_index = failing.alloc_index + fail_index;
        failing.resize_fail_index = failing.resize_index + fail_index;
        const saved = store.save(&.{ .token = "3:c", .id = 3, .username = "third_bot", .chat_id = 7 });
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        saved catch {
            try std.testing.expectEqual(@as(usize, 2), store.bots.items.len);
            try std.testing.expectEqual(@as(usize, 2), store.usernames.items.len);
            var reread = try Store.open(std.testing.allocator, io, home);
            defer reread.deinit();
            try std.testing.expectEqual(@as(usize, 2), reread.bots.items.len);
            continue;
        };
        try std.testing.expectEqual(@as(usize, 3), store.bots.items.len);
        try std.testing.expectEqualStrings("third_bot", store.usernames.items[2]);
        break;
    }
    try std.testing.expect(fail_index < 64);
}

test "an inert store keeps bots in memory alone" {
    var store = Store.inert(std.testing.allocator, std.testing.io);
    defer store.deinit();
    try store.save(&.{ .token = "1:a", .id = 1, .username = "bot", .chat_id = null });
    try std.testing.expectEqual(@as(usize, 1), store.usernames.items.len);
    try store.remove(0);
    try std.testing.expectEqual(@as(usize, 0), store.bots.items.len);
}
