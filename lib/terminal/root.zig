//! The terminal rendering engine: raw-mode terminal ownership (`Tty`), the ANSI
//! escape sequences (`escape`) that drive it, the reconciling `View` renderer,
//! the byte-to-`Input.Key` parser, and grapheme-aware display-`width` math built
//! on the UAX #29 `grapheme` segmenter.

const std = @import("std");

pub const escape = @import("escape.zig");
pub const grapheme = @import("grapheme.zig");
pub const Input = @import("Input.zig");
pub const Tty = @import("Tty.zig");
pub const View = @import("View.zig");
pub const width = @import("width.zig");

test {
    std.testing.refAllDecls(@This());
}
