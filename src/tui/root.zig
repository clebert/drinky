//! The terminal UI: the input-line `Editor`, the byte-to-`Input.Key` `Input`
//! parser, the single-choice `Picker`, the differential `Surface` renderer, the
//! `cursor` marker, the `status` line, the `separator` rule, and display-`width`
//! math.

pub const cursor = @import("cursor.zig");
pub const Editor = @import("Editor.zig");
pub const Input = @import("Input.zig");
pub const Picker = @import("Picker.zig");
pub const separator = @import("separator.zig");
pub const status = @import("status.zig");
pub const Surface = @import("Surface.zig");
pub const width = @import("width.zig");
