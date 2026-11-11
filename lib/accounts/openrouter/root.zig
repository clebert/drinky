const std = @import("std");

pub const credits = @import("credits.zig");
pub const key = @import("key.zig");
pub const oauth = @import("oauth.zig");

test {
    std.testing.refAllDecls(@This());
}
