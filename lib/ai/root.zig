//! The provider-neutral agent core: the `Agent` turn loop, the neutral `llm`
//! wire types, the `Catalog` of discovered models, the `provider` client, the
//! `command` registry, Agent Skills discovery, the `tool` registry, and the
//! `anthropic`, `openai`, `xai`, `google`, `openrouter`, and `Metadata` modules.

const std = @import("std");

const jwt = @import("jwt.zig");
const oauth_login = @import("oauth_login.zig");

pub const Accounts = @import("Accounts.zig");
pub const Agent = @import("Agent.zig");
pub const anthropic = @import("anthropic/root.zig");
pub const json_store = @import("json_store.zig");
pub const Catalog = @import("Catalog.zig");
pub const command = @import("command/root.zig");
pub const format = @import("format.zig");
pub const google = @import("google/root.zig");
pub const instructions = @import("instructions.zig");
pub const llm = @import("llm.zig");
pub const Model = @import("Model.zig");
pub const net = @import("net.zig");
pub const oauth_callback = @import("oauth_callback.zig");
pub const Metadata = @import("Metadata.zig");
pub const openai = @import("openai/root.zig");
pub const openrouter = @import("openrouter/root.zig");
pub const project = @import("project.zig");
pub const provider = @import("provider.zig");
pub const skills = @import("skills.zig");
pub const Steering = @import("Steering.zig");
pub const testing = @import("testing.zig");
pub const tool = @import("tool/root.zig");
pub const xai = @import("xai/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = jwt;
    _ = oauth_login;
}
