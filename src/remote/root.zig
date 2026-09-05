//! The Telegram remote control. `Controller` owns the state and is the one seam
//! the app talks to: the `Store` of saved bots, the `Pairing` that binds a chat,
//! and the live `Attachment` that polls the chat and sends to it. Each of the
//! three drives the Bot API through `Client`. `Mirror` sends the committed
//! transcript blocks through the controller, rendered by `html`, and holds the
//! keyboards of the turn. `Picker` holds the open command picker of the chat,
//! and `keyboard` names the buttons of both. The subsystem depends on `lib/ai`
//! for the HTTP helpers, the JSON store, and the commands, and on the block
//! model and the Markdown parser of the interface. It knows nothing of the
//! session.

const std = @import("std");

pub const Client = @import("Client.zig");
pub const Store = @import("Store.zig");
pub const Attachment = @import("Attachment.zig");
pub const Pairing = @import("Pairing.zig");
pub const Controller = @import("Controller.zig");
pub const Mirror = @import("Mirror.zig");
pub const Picker = @import("Picker.zig");
pub const html = @import("html.zig");
pub const keyboard = @import("keyboard.zig");

test {
    std.testing.refAllDecls(@This());
}
