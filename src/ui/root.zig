//! The app's terminal widgets, drawn on the `terminal` engine: the input-line
//! `Editor`, the single-choice `Picker`, full-window read-only `Page`, the bottom
//! `status` line, the transcript `block` model, the `paint` row primitives they
//! stream through, and the shared `color` palette.

pub const Editor = @import("Editor.zig");
pub const Page = @import("Page.zig");
pub const Picker = @import("Picker.zig");
pub const block = @import("block.zig");
pub const color = @import("color.zig");
pub const paint = @import("paint.zig");
pub const status = @import("status.zig");
