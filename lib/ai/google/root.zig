//! The Google Vertex AI provider. `Auth` reads a service account key file and
//! mints its own access token through a signed JWT (`rs256`). `wire` serializes
//! the native Gemini `generateContent` body, `Transport` decodes its SSE stream,
//! and `models` lists the Gemini models of the Google publisher.

const std = @import("std");

pub const Auth = @import("Auth.zig");
pub const models = @import("models.zig");
pub const rs256 = @import("rs256.zig");
pub const Transport = @import("Transport.zig");
pub const wire = @import("wire.zig");

test {
    std.testing.refAllDecls(@This());
}
