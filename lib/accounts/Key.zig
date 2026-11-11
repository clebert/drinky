const std = @import("std");

const providers = @import("providers");

const json_store = @import("json_store.zig");
const store = @import("oauth/store.zig");

const Key = @This();

gpa: std.mem.Allocator,
io: std.Io,
path: []const u8,
account: []const u8,
value: ?[]const u8,
mutex: std.Io.Mutex,

pub const Options = struct {
    directories: json_store.Directories,
    account: []const u8,
};

const Entry = struct { api_key: []const u8 };

const vtable: providers.Credential.VTable = .{ .token = token, .renew = renew };

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: *const Options) error{OutOfMemory}!Key {
    return .{
        .gpa = gpa,
        .io = io,
        .path = try json_store.locate(gpa, &options.directories, .auth),
        .account = options.account,
        .value = null,
        .mutex = .init,
    };
}

pub fn deinit(self: *Key) void {
    if (self.value) |value| self.gpa.free(value);
    self.gpa.free(self.path);
}

pub fn load(self: *Key) store.Error!void {
    const loaded = try self.read(self.gpa) orelse return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.value) |held| self.gpa.free(held);
    self.value = loaded;
}

pub fn signedIn(self: *Key) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.value != null;
}

pub fn holds(self: *Key, value: []const u8) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const held = self.value orelse return false;
    return std.mem.eql(u8, held, value);
}

pub fn copy(self: *Key, gpa: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const held = self.value orelse return null;
    return try gpa.dupe(u8, held);
}

pub fn stored(self: *Key, gpa: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    const maybe_read = self.read(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    return maybe_read orelse self.copy(gpa);
}

pub fn reload(self: *Key) error{OutOfMemory}!bool {
    const maybe_read = self.read(self.gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const fresh = maybe_read orelse return false;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.value) |held| {
        if (std.mem.eql(u8, held, fresh)) {
            self.gpa.free(fresh);
            return false;
        }
        self.gpa.free(held);
    }
    self.value = fresh;
    return true;
}

pub fn commit(self: *Key, value: []const u8) error{OutOfMemory}!store.Commit {
    const owned = try self.gpa.dupe(u8, value);
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.value) |held| self.gpa.free(held);
        self.value = owned;
    }
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    json_store.save(self.gpa, self.io, &.{
        .path = self.path,
        .key = self.account,
    }, Entry{ .api_key = value }, .{}) catch |err| {
        const save_error: store.Error = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CorruptStore => error.BadCredentials,
            else => |other| other,
        };
        return .{ .memory_only = .{ .path = self.path, .save_error = save_error } };
    };
    return .{ .saved = self.path };
}

pub fn remove(self: *Key) store.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    json_store.remove(self.gpa, self.io, &.{ .path = self.path, .key = self.account }) catch |err|
        switch (err) {
            error.CorruptStore => return error.BadCredentials,
            else => |other| return other,
        };
    if (self.value) |held| self.gpa.free(held);
    self.value = null;
}

pub fn credential(self: *Key) providers.Credential {
    return .{ .ptr = self, .vtable = &vtable };
}

fn read(self: *Key, gpa: std.mem.Allocator) store.Error!?[]u8 {
    var file = (json_store.open(self.gpa, self.io, self.path) catch |err| switch (err) {
        error.CorruptStore => return error.BadCredentials,
        else => |other| return other,
    }) orelse return null;
    defer file.deinit();
    const entry = file.entry(self.account) orelse return null;
    const value = providers.json.string(entry.getPtr("api_key")) orelse
        return error.BadCredentials;
    return try gpa.dupe(u8, value);
}

fn token(ptr: *anyopaque, gpa: std.mem.Allocator) providers.Credential.Error!?[]const u8 {
    const self: *Key = @ptrCast(@alignCast(ptr));
    return self.copy(gpa);
}

fn renew(ptr: *anyopaque) providers.Credential.Error!bool {
    _ = ptr;
    return false;
}
