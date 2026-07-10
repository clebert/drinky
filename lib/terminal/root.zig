//! The terminal rendering engine: raw-mode terminal ownership (`Tty`), the ANSI
//! escape sequences (`escape`) that drive it, the differential `Surface`
//! renderer, the byte-to-`Input.Key` parser, the caret `cursor` marker,
//! display-`width` math, and an in-memory `Emulator` used to test the renderer.

const std = @import("std");

pub const cursor = @import("cursor.zig");
pub const Emulator = @import("Emulator.zig");
pub const escape = @import("escape.zig");
pub const Input = @import("Input.zig");
pub const Surface = @import("Surface.zig");
pub const Tty = @import("Tty.zig");
pub const width = @import("width.zig");

test {
    std.testing.refAllDecls(@This());
}
