//! The provider-neutral agent core: the `Agent` turn loop, the neutral `llm`
//! wire types, the `models` table, the `provider` client, the `command`
//! registry, Agent Skills discovery, the `tool` registry, and the `anthropic`
//! and `openai` provider transports.

const std = @import("std");

const oauth_callback = @import("oauth_callback.zig");
const oauth_login = @import("oauth_login.zig");

pub const Accounts = @import("Accounts.zig");
pub const Agent = @import("Agent.zig");
pub const anthropic = @import("anthropic/root.zig");
pub const json_store = @import("json_store.zig");
pub const command = @import("command/root.zig");
pub const instructions = @import("instructions.zig");
pub const llm = @import("llm.zig");
pub const models = @import("models.zig");
pub const net = @import("net.zig");
pub const openai = @import("openai/root.zig");
pub const provider = @import("provider.zig");
pub const skills = @import("skills.zig");
pub const Steering = @import("Steering.zig");
pub const tool = @import("tool/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = oauth_callback;
    _ = oauth_login;
}
