//! Terminal ownership: the raw-mode controlling terminal (`Tty`) and the ANSI
//! escape sequences (`escape`) used to drive it.

pub const Tty = @import("Tty.zig");
pub const escape = @import("escape.zig");
