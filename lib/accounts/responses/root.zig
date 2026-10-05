const std = @import("std");

pub const models = @import("models.zig");

test {
    std.testing.refAllDecls(@This());
}
