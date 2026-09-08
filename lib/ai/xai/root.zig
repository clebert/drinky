//! The xAI provider. Both accounts speak the OpenAI Responses protocol on the
//! public API at `api.x.ai`, so they share the `openai` transport and wire and
//! differ in the credential alone.
//!
//! `Auth` manages the subscription credential. `oauth` drives the device-code
//! login of the Grok Build client, which xAI does not document for third-party
//! clients and can change without notice. `models` reads the list of both
//! accounts.

const std = @import("std");

pub const Auth = @import("Auth.zig");
pub const models = @import("models.zig");
pub const oauth = @import("oauth.zig");

test {
    std.testing.refAllDecls(@This());
}
