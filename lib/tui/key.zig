/// A single decoded input event from the terminal.
pub const Key = union(enum) {
    /// A printable Unicode codepoint the user typed.
    char: u21,
    /// A control combination, carrying the lowercase letter (`0x03` -> `'c'`).
    ctrl: u8,
    /// Bracketed-paste payload, borrowed from the parser's buffer for the call.
    paste: []const u8,
    enter,
    backspace,
    left,
    right,
    up,
    down,
    home,
    end,
    /// A recognized-but-unhandled sequence; callers ignore it.
    unknown,
};
