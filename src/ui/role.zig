//! The app's presentation roles: the one seam from a semantic role to the SGR
//! bytes a row carries. A widget names a role and never writes a color of its
//! own.
//!
//! Drinky names no RGB value. A role emits the ANSI slots 0 to 7 and the default
//! colors alone, so the theme of the terminal decides every value. The bright
//! slots 8 to 15 stay out of the interface, because they do not read well in
//! every theme. The terminal can select values for a dark or light theme.
//! Drinky needs no palette or color configuration. Plain text writes no bytes,
//! so it keeps the terminal foreground. The muted role uses faint intensity with
//! the default foreground. The terminal derives this secondary tone from its own
//! theme. A terminal that ignores faint shows muted text at normal intensity.
//! Underline carries emphasis because bold and faint share one intensity. Double
//! underline keeps an existing underline distinct.
//!
//! A filled message box takes one foreground color plus reverse video. The
//! terminal swaps that color with its background. The box then keeps the
//! contrast that the palette slot has against the terminal background. The
//! color and the swap belong to one role, because either one alone can paint an
//! unreadable row. The box colors stay in the red-to-cyan slot range, because
//! black, white, and the bright slots do not read well in every theme.
//!
//! A picker selection uses reverse video with the default colors. The
//! `attribute` module owns inline bold, italic, underline, and strikethrough.
//! Its `reset` closes them. Every widget also carries a text label or a glyph,
//! so color is never the only signal of a state.

const std = @import("std");

const terminal = @import("terminal");

/// What a widget asks for. A role names the part of the interface, never a
/// color. This list is complete.
pub const Name = enum {
    /// Reply and prompt text, and the product title, in the terminal foreground.
    text,
    /// Secondary text, a source value, a key hint, and Markdown structure.
    muted,
    /// A caption title, a source label, a list marker, and an inline code span.
    /// A failed event takes the error role, and every other event takes this
    /// role.
    accent,
    /// A Markdown heading.
    heading,
    /// A fenced code block.
    code,
    /// A link. The caller adds the underline attribute.
    link,
    /// A warning that the user can pass now, or after the named state ends.
    warning,
    /// A failure.
    @"error",
    /// A user message box.
    user,
    /// A line that Drinky wrote about the conversation of the user, such as the
    /// head of a loaded skill. It takes the color of a user message without the
    /// swap, so no message can look like one.
    user_note,
    /// The editor and picker frame.
    input_frame,
    /// The moving segment on the input frame.
    activity,
    /// A running tool box.
    tool_pending,
    /// A finished tool box.
    tool_success,
    /// A failed tool box.
    tool_error,
    /// The selected row of a picker.
    selection,
};

/// The complete SGR sequence `name` paints, or an empty sequence for the plain
/// text role. This map is the only place where a role becomes bytes.
pub fn sequence(comptime name: Name) []const u8 {
    return switch (name) {
        .text => "",
        .muted => "\x1b[2;39m",
        // The `22` sets normal intensity, because a label takes this role
        // straight behind a faint body role, with no reset between them.
        .accent => "\x1b[22;36m",
        .heading => "\x1b[33m",
        .code => "\x1b[32m",
        .link => "\x1b[34m",
        .warning => "\x1b[33m",
        .@"error" => "\x1b[31m",
        .user => "\x1b[35;7m",
        .user_note => "\x1b[35m",
        .input_frame => "\x1b[35m",
        .activity => "\x1b[36m",
        .tool_pending => "\x1b[36;7m",
        .tool_success => "\x1b[32;7m",
        .tool_error => "\x1b[31;7m",
        .selection => "\x1b[7m",
    };
}

/// Apply `name` to `sink` through the compile-time-validated SGR path. The plain
/// text role writes nothing, so a row that shows it alone stays free of every
/// escape sequence.
pub fn apply(sink: *terminal.View.Sink, name: Name) !void {
    switch (name) {
        .text => {},
        inline else => |tag| try sink.sgr(sequence(tag)),
    }
}

/// Whether `name` writes any bytes. A row that paints no role needs no reset.
pub fn paints(name: Name) bool {
    return name != .text;
}

/// The SGR parameters that a role can carry: faint or normal intensity, reverse
/// video, the eight ANSI foreground slots, and the default foreground.
fn legalParameter(parameter: u16) bool {
    if (parameter == 2 or parameter == 7 or parameter == 22) return true;
    return parameter >= 30 and parameter <= 39;
}

const Pinned = struct { name: Name, sequence: []const u8 };

/// Assert the exact bytes of every role. A role the list leaves out fails, so a
/// new role cannot reach a release unpinned.
fn expectSequences(pinned: []const Pinned) !void {
    var seen: std.EnumSet(Name) = .initEmpty();
    inline for (std.enums.values(Name)) |name| {
        for (pinned) |entry| {
            if (entry.name != name) continue;
            try std.testing.expectEqualStrings(entry.sequence, sequence(name));
            seen.insert(name);
        }
    }
    try std.testing.expectEqual(std.enums.values(Name).len, seen.count());
}

test "the role map pins the SGR sequence for each role" {
    try expectSequences(&.{
        .{ .name = .text, .sequence = "" },
        .{ .name = .muted, .sequence = "\x1b[2;39m" },
        .{ .name = .accent, .sequence = "\x1b[22;36m" },
        .{ .name = .heading, .sequence = "\x1b[33m" },
        .{ .name = .code, .sequence = "\x1b[32m" },
        .{ .name = .link, .sequence = "\x1b[34m" },
        .{ .name = .warning, .sequence = "\x1b[33m" },
        .{ .name = .@"error", .sequence = "\x1b[31m" },
        // Each message box pairs one palette color with reverse video, so the
        // fill takes the color and the text keeps the terminal background.
        .{ .name = .user, .sequence = "\x1b[35;7m" },
        // A note of Drinky about that conversation keeps the color and drops the
        // swap, so a message box and a note never read alike.
        .{ .name = .user_note, .sequence = "\x1b[35m" },
        // The input frame uses the user's foreground slot without the swap.
        .{ .name = .input_frame, .sequence = "\x1b[35m" },
        .{ .name = .activity, .sequence = "\x1b[36m" },
        .{ .name = .tool_pending, .sequence = "\x1b[36;7m" },
        .{ .name = .tool_success, .sequence = "\x1b[32;7m" },
        .{ .name = .tool_error, .sequence = "\x1b[31;7m" },
        .{ .name = .selection, .sequence = "\x1b[7m" },
    });
}

test "every role uses terminal colors and supported role attributes alone" {
    inline for (std.enums.values(Name)) |name| {
        const bytes = comptime sequence(name);
        try std.testing.expectEqual(paints(name), bytes.len > 0);
        if (comptime bytes.len > 0) {
            try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b["));
            try std.testing.expect(std.mem.endsWith(u8, bytes, "m"));
            // No true color (38;2) and no 256-color (38;5) parameter can hide
            // here, so the terminal theme owns every value the interface shows.
            var parameters = std.mem.splitScalar(u8, bytes[2 .. bytes.len - 1], ';');
            while (parameters.next()) |text| {
                try std.testing.expect(legalParameter(try std.fmt.parseInt(u16, text, 10)));
            }
        }
    }
}

test "a role reaches the row as one SGR sequence, and the text role as none" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 20, .rows = 2 }, 1);
    sink.begin();
    try apply(sink, .user);
    try sink.text("title");
    sink.end(.{ .id = 0, .line = 0 });
    sink.begin();
    try apply(sink, .text);
    try sink.text("plain");
    sink.end(.{ .id = 0, .line = 1 });
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[35;7mtitle") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0mplain") == null);
    try std.testing.expect(paints(.user));
    try std.testing.expect(!paints(.text));
}
