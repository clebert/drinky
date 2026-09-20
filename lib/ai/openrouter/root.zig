const std = @import("std");

pub const Auth = @import("Auth.zig");
pub const credits = @import("credits.zig");
pub const oauth = @import("oauth.zig");

test {
    std.testing.refAllDecls(@This());
}
