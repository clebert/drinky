//! The app's terminal widgets, drawn on the `terminal` engine: the input-line
//! `Editor`, the single-choice `Picker`, the full-window read-only `Page`, the
//! bottom `status` line, the transcript `block` model, the `paint` row
//! primitives they stream through, the `role` map that owns every color, and the
//! `attribute` operations that carry no color.

pub const Editor = @import("Editor.zig");
pub const Page = @import("Page.zig");
pub const Picker = @import("Picker.zig");
pub const attribute = @import("attribute.zig");
pub const block = @import("block.zig");
pub const paint = @import("paint.zig");
pub const role = @import("role.zig");
pub const status = @import("status.zig");
