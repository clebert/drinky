//! The app's terminal widgets, drawn on the `terminal` engine: the semantic
//! `Caption`, the input-line `Editor`, the single-choice `Picker`, the
//! full-window read-only `Page`, the bottom `status` line, the transcript
//! `block` model, the `paint` row primitives they stream through, the `role`
//! map that owns every color, the `attribute` operations without color, and
//! the `markdown` parser that the remote mirror renders from too.

pub const Caption = @import("Caption.zig");
pub const Editor = @import("Editor.zig");
pub const Page = @import("Page.zig");
pub const Picker = @import("Picker.zig");
pub const attribute = @import("attribute.zig");
pub const block = @import("block.zig");
pub const markdown = @import("markdown.zig");
pub const paint = @import("paint.zig");
pub const role = @import("role.zig");
pub const status = @import("status.zig");
