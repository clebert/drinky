//! The app's inline text attributes. A span adds these operations to its semantic
//! role. The `role` map owns every color and the faint muted tone. This module
//! owns emphasis, italic, underline, and strikethrough. `reset` closes every
//! style.

const std = @import("std");

const terminal = @import("terminal");

const role = @import("role.zig");

/// One text attribute that does not depend on the active role, plus the `reset`
/// that closes every open attribute and color.
pub const Name = enum {
    reset,
    italic,
    underline,
    strikethrough,
};

const Emphasis = enum { bold, underline, double_underline };

/// Apply one role-independent attribute through the sink's validated SGR path.
pub fn apply(sink: *terminal.View.Sink, name: Name) !void {
    switch (name) {
        .reset => try sink.sgr("\x1b[0m"),
        .italic => try sink.sgr("\x1b[3m"),
        .underline => try sink.sgr("\x1b[4m"),
        .strikethrough => try sink.sgr("\x1b[9m"),
    }
}

/// Apply visible emphasis without replacing the faint intensity of muted text.
/// Other roles use bold. A muted span uses double underline when it already has
/// underline.
pub fn emphasize(sink: *terminal.View.Sink, name: role.Name, underlined: bool) !void {
    switch (emphasis(name, underlined)) {
        .bold => try sink.sgr("\x1b[1m"),
        .underline => try sink.sgr("\x1b[4m"),
        .double_underline => try sink.sgr("\x1b[21m"),
    }
}

fn emphasis(name: role.Name, underlined: bool) Emphasis {
    if (name != .muted) return .bold;
    return if (underlined) .double_underline else .underline;
}

test "muted emphasis stays distinct from an existing underline" {
    try std.testing.expectEqual(Emphasis.underline, emphasis(.muted, false));
    try std.testing.expectEqual(Emphasis.double_underline, emphasis(.muted, true));
    inline for (std.enums.values(role.Name)) |name| {
        if (name == .muted) continue;
        try std.testing.expectEqual(Emphasis.bold, emphasis(name, false));
        try std.testing.expectEqual(Emphasis.bold, emphasis(name, true));
    }
}
