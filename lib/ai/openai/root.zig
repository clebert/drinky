//! The OpenAI Responses provider: credential lifecycle (`Auth`) for the
//! ChatGPT-subscription backend, the OAuth PKCE flow (`oauth`) it drives, the
//! Responses API transport (`Transport`), and request serialization (`wire`).
//! The API-key and subscription providers share `wire` and `Transport`; only
//! the endpoint and auth differ.

const std = @import("std");

pub const Auth = @import("Auth.zig");
pub const oauth = @import("oauth.zig");
pub const Transport = @import("Transport.zig");
pub const wire = @import("wire.zig");

test {
    std.testing.refAllDecls(@This());
}
