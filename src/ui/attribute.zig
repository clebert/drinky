//! The app's text attributes: the SGR operations that carry no color. The `role`
//! map owns every color, and this module owns everything else a row can turn on.
//! `reset` closes whatever a row opened, so no style leaks into the row below.

const terminal = @import("terminal");

/// One text attribute, plus the `reset` that closes every open attribute and
/// color.
pub const Name = enum {
    reset,
    bold,
    italic,
    underline,
    strikethrough,
};

/// Apply one attribute through the sink's compile-time-validated SGR path.
pub fn apply(sink: *terminal.View.Sink, name: Name) !void {
    switch (name) {
        .reset => try sink.sgr("\x1b[0m"),
        .bold => try sink.sgr("\x1b[1m"),
        .italic => try sink.sgr("\x1b[3m"),
        .underline => try sink.sgr("\x1b[4m"),
        .strikethrough => try sink.sgr("\x1b[9m"),
    }
}
