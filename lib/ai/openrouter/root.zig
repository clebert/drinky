//! The OpenRouter provider: credential lifecycle (`Auth`) for the OAuth login
//! and the PKCE flow (`oauth`) it drives. Both OpenRouter accounts share the
//! OpenAI Responses transport. Only the credential source differs.

const std = @import("std");

pub const Auth = @import("Auth.zig");
pub const credits = @import("credits.zig");
pub const oauth = @import("oauth.zig");

test {
    std.testing.refAllDecls(@This());
}
