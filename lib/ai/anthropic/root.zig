//! The Anthropic provider.
//!
//! `Auth` manages subscription credentials. `ConsoleAuth` manages the API key from Console OAuth.
//! `oauth` and `console` reuse the Claude Code OAuth client and private endpoints.
//! Anthropic does not document these interfaces for third-party clients. They can change without
//! notice. Both login paths prepend the exact Claude Code identity in `wire`. The Console key needs
//! this identity to reach every model. A plain API key omits it. `Transport` sends Messages API
//! requests.

const std = @import("std");

pub const Auth = @import("Auth.zig");
pub const console = @import("console.zig");
pub const ConsoleAuth = @import("ConsoleAuth.zig");
pub const oauth = @import("oauth.zig");
pub const Transport = @import("Transport.zig");
pub const wire = @import("wire.zig");

test {
    std.testing.refAllDecls(@This());
}
