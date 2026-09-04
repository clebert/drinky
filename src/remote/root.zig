//! The Telegram remote control. `Controller` owns the state and is the one seam
//! the app talks to: the `Store` of saved bots, the `Pairing` that binds a chat,
//! and the live `Attachment` that polls the chat and sends to it. Each of the
//! three drives the Bot API through `Client`. The subsystem depends on `lib/ai`
//! for the HTTP helpers and the JSON store, and it knows nothing of the session.

const std = @import("std");

pub const Client = @import("Client.zig");
pub const Store = @import("Store.zig");
pub const Attachment = @import("Attachment.zig");
pub const Pairing = @import("Pairing.zig");
pub const Controller = @import("Controller.zig");

test {
    std.testing.refAllDecls(@This());
}
