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

pub const none: Credential = .{ .ptr = undefined, .vtable = &none_vtable };

const none_vtable: VTable = .{ .token = noToken, .renew = noRenew };

fn noToken(ptr: *anyopaque, gpa: std.mem.Allocator) Error!?[]const u8 {
    _ = ptr;
    _ = gpa;
    return null;
}

fn noRenew(ptr: *anyopaque) Error!bool {
    _ = ptr;
    return false;
}

test "the credential of no account holds no token and renews nothing" {
    try std.testing.expectEqual(@as(?[]const u8, null), try none.token(std.testing.allocator));
    try std.testing.expect(!try none.renew());
}
