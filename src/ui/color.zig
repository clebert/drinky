//! The app's SGR palette: the colors and attributes the widgets and transcript
//! blocks draw with, in one place so the `paint` primitives, the transcript
//! `block`s, and the `Picker` share one definition instead of each redefining
//! their own. App style, hence the `ui` namespace rather than the generic
//! `terminal` engine.

/// Reset every attribute.
pub const reset = "\x1b[0m";
pub const dim = "\x1b[2m";
pub const red = "\x1b[31m";

/// Inverse video, for the picker's selected row, and its lone reset.
pub const highlight = "\x1b[7m";
pub const highlight_reset = "\x1b[27m";

/// The purple rule that frames the input area, and its foreground reset.
pub const rule = "\x1b[38;2;209;131;232m";
pub const rule_reset = "\x1b[39m";

/// The user message box.
pub const user_bg = "\x1b[48;2;52;53;65m";
pub const user_fg = "\x1b[38;2;212;212;212m";

/// The tool boxes: one foreground, a background per call status. A running call
/// is blue, a finished one green, a failed one red.
pub const tool_fg = "\x1b[38;2;212;212;212m";
pub const tool_pending_bg = "\x1b[48;2;38;48;82m";
pub const tool_success_bg = "\x1b[48;2;40;50;40m";
pub const tool_error_bg = "\x1b[48;2;60;40;40m";

/// The spinner: an accent glyph and a muted message.
pub const accent_fg = "\x1b[38;2;138;190;183m";
pub const muted_fg = "\x1b[38;2;128;128;128m";
