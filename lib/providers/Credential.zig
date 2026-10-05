const std = @import("std");

const Credential = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    token: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) Error!?[]const u8,
    renew: *const fn (ptr: *anyopaque) Error!bool,
};

pub const Error = error{ Canceled, OutOfMemory, Rejected, Network };

pub fn token(self: Credential, gpa: std.mem.Allocator) Error!?[]const u8 {
    return self.vtable.token(self.ptr, gpa);
}

pub fn renew(self: Credential) Error!bool {
    return self.vtable.renew(self.ptr);
}
