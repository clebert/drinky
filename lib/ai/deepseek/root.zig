//! The DeepSeek provider. The API-key account speaks the OpenAI Responses
//! protocol on `api.deepseek.com`. `models` reads the list. `balance` reads
//! the prepaid USD pool. Public metadata fills the rest, as it does for xAI.

const std = @import("std");

pub const balance = @import("balance.zig");
pub const models = @import("models.zig");

test {
    std.testing.refAllDecls(@This());
}
