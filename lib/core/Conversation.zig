const std = @import("std");

const Tool = @import("Tool.zig");

const Conversation = @This();

const cache_key_length = 32;

items: std.ArrayList(Item),
cache_key: [cache_key_length]u8,

pub const Role = enum { user, assistant };

pub const Message = struct {
    role: Role,
    text: []const u8,
};

pub const Proof = struct {
    account: []const u8,
    payload: []const u8,

    pub fn dupe(self: *const Proof, gpa: std.mem.Allocator) error{OutOfMemory}!Proof {
        const account = try gpa.dupe(u8, self.account);
        errdefer gpa.free(account);
        return .{ .account = account, .payload = try gpa.dupe(u8, self.payload) };
    }

    pub fn deinit(self: *const Proof, gpa: std.mem.Allocator) void {
        gpa.free(self.account);
        gpa.free(self.payload);
    }
};

pub const Item = union(enum) {
    message: Message,
    reasoning: Proof,
    tool_call: Tool.Call,
    tool_result: Tool.Result,

    pub fn deinit(self: *const Item, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .message => |message| gpa.free(message.text),
            .reasoning => |proof| proof.deinit(gpa),
            .tool_call => |call| call.deinit(gpa),
            .tool_result => |result| result.deinit(gpa),
        }
    }
};

pub fn init(io: std.Io) Conversation {
    return .{ .items = .empty, .cache_key = newCacheKey(io) };
}

pub fn deinit(self: *Conversation, gpa: std.mem.Allocator) void {
    for (self.items.items) |item| item.deinit(gpa);
    self.items.deinit(gpa);
}

pub fn clear(self: *Conversation, gpa: std.mem.Allocator, io: std.Io) void {
    for (self.items.items) |item| item.deinit(gpa);
    self.items.clearRetainingCapacity();
    self.cache_key = newCacheKey(io);
}

pub fn append(self: *Conversation, gpa: std.mem.Allocator, item: Item) error{OutOfMemory}!void {
    try self.items.append(gpa, item);
}

fn newCacheKey(io: std.Io) [cache_key_length]u8 {
    var seed: [@divExact(cache_key_length, 2)]u8 = undefined;
    io.random(&seed);
    return std.fmt.bytesToHex(seed, .lower);
}

test "a clear frees every item and takes a new cache key" {
    const gpa = std.testing.allocator;
    var conversation: Conversation = .init(std.testing.io);
    defer conversation.deinit(gpa);
    const key = conversation.cache_key;

    try conversation.append(gpa, .{
        .message = .{ .role = .user, .text = try gpa.dupe(u8, "hi") },
    });
    try conversation.append(gpa, .{
        .reasoning = try (Proof{ .account = "a", .payload = "p" }).dupe(gpa),
    });
    try std.testing.expectEqual(@as(usize, 2), conversation.items.items.len);

    conversation.clear(gpa, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), conversation.items.items.len);
    try std.testing.expect(!std.mem.eql(u8, &key, &conversation.cache_key));
}
