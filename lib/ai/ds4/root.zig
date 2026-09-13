//! The local DwarfStar provider. The credential-free account speaks the OpenAI
//! Responses protocol at the base URL in `DS4_BASE_URL`.

const std = @import("std");

pub const models = @import("models.zig");

test {
    std.testing.refAllDecls(@This());
}
