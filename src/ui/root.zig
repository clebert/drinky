//! The app's terminal widgets, drawn on the `terminal` engine: the input-line
//! `Editor`, the single-choice `Picker`, the bottom `status` line, and the
//! `separator` rule the editor and picker share.

pub const Editor = @import("Editor.zig");
pub const Picker = @import("Picker.zig");
pub const separator = @import("separator.zig");
pub const status = @import("status.zig");
