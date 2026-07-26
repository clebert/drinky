//! The app's SGR palette: the colors and attributes the widgets and transcript
//! blocks draw with, in one place so the `paint` primitives, the `Picker`, and
//! the status line share one definition instead of each redefining their own.

const terminal = @import("terminal");

pub const Style = enum {
    reset,
    dim,
    bold,
    italic,
    underline,
    strikethrough,
    red,
    highlight,
    rule,
    user_background,
    user_foreground,
    tool_foreground,
    tool_pending_background,
    tool_success_background,
    tool_error_background,
    accent_foreground,
    muted_foreground,
    heading,
    code_block,
    link,
};

/// Apply one palette entry through the sink's compile-time-validated SGR path.
pub fn apply(sink: *terminal.View.Sink, style: Style) !void {
    switch (style) {
        .reset => try sink.sgr("\x1b[0m"),
        .dim => try sink.sgr("\x1b[2m"),
        .bold => try sink.sgr("\x1b[1m"),
        .italic => try sink.sgr("\x1b[3m"),
        .underline => try sink.sgr("\x1b[4m"),
        .strikethrough => try sink.sgr("\x1b[9m"),
        .red => try sink.sgr("\x1b[31m"),
        .highlight => try sink.sgr("\x1b[7m"),
        .rule => try sink.sgr("\x1b[38;2;209;131;232m"),
        .user_background => try sink.sgr("\x1b[48;2;52;53;65m"),
        .user_foreground, .tool_foreground => try sink.sgr("\x1b[38;2;212;212;212m"),
        .tool_pending_background => try sink.sgr("\x1b[48;2;38;48;82m"),
        .tool_success_background => try sink.sgr("\x1b[48;2;40;50;40m"),
        .tool_error_background => try sink.sgr("\x1b[48;2;60;40;40m"),
        .accent_foreground => try sink.sgr("\x1b[38;2;138;190;183m"),
        .muted_foreground => try sink.sgr("\x1b[38;2;128;128;128m"),
        .heading => try sink.sgr("\x1b[38;2;240;198;116m"),
        .code_block => try sink.sgr("\x1b[38;2;181;189;104m"),
        .link => try sink.sgr("\x1b[38;2;129;162;190m"),
    }
}
