//! The terminal UI: the input-line `Editor`, the byte-to-`Input.Key` `Input`
//! parser, the live-region `Renderer`, and display-`width` math.

pub const Editor = @import("Editor.zig");
pub const Input = @import("Input.zig");
pub const Renderer = @import("Renderer.zig");
pub const width = @import("width.zig");
