//! The `/colors` preview page body. It shows every color pith can emit: the
//! ANSI slots 0 to 15 as foreground and as reverse-video fills, each in the
//! faint, normal, and bold intensities, every text color option on each
//! colored background, the default-color styles, the filled message boxes, the
//! text roles, and the input frames with an activity segment. The user judges
//! the theme of the terminal against these samples.
//!
//! Except for `role`, this module is the only place that writes color bytes,
//! and it writes them for the preview alone. Every sequence stays
//! terminal-owned: the ANSI slots, the default colors, intensity, and reverse
//! video. No RGB value and no 256-color value can appear here. A test pins
//! this set.
//!
//! Every item paints exactly one row, and a narrow window truncates each row.
//! The row count is a constant, so a scroll position survives a resize.

const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

/// One preview row. Every variant paints exactly one physical row.
const Item = union(enum) {
    /// An empty separator row.
    blank,
    /// A bold section title.
    title: []const u8,
    /// A muted label row above a sample group.
    note: []const u8,
    /// One ANSI palette slot: its label, a foreground sample, and a filled
    /// background sample.
    slot: u8,
    /// One ANSI slot as a background, with every terminal-owned text color on it.
    contrast: u8,
    /// A default-color style: its SGR parameters and a labelled sample.
    style: Style,
    /// One interface text role, with its attributes, applied to a sample.
    sample: Sample,
    /// A filled padding row of one live box role.
    box_fill: role.Name,
    /// A filled text row of one live box role.
    box_text: BoxText,
    /// An input separator, plain or with a still activity segment.
    separator: Separator,
    /// A body row between the input separators.
    framed: Framed,
};

const Style = struct { parameters: []const u8, label: []const u8 };

const Sample = struct {
    label: []const u8,
    name: role.Name,
    italic: bool = false,
    underline: bool = false,
    text: []const u8,
};

const BoxText = struct { name: role.Name, text: []const u8 };
const Separator = enum { plain, labelled };
const Framed = struct { name: ?role.Name = null, text: []const u8 = "" };

const slot_names = [16][]const u8{
    "black",
    "red",
    "green",
    "yellow",
    "blue",
    "magenta",
    "cyan",
    "white",
    "bright black",
    "bright red",
    "bright green",
    "bright yellow",
    "bright blue",
    "bright magenta",
    "bright cyan",
    "bright white",
};

/// The whole page, one item per row. The comptime table keeps every SGR
/// sequence compile-time-known for the sink's validated `sgr` path.
const items = blk: {
    var list: []const Item = &.{
        .{ .note = "Every value comes from the theme of the terminal." },
        .blank,
        .{ .title = "ANSI slots 0 to 15" },
        .blank,
        // The group labels line up with the two intensity groups of a slot row.
        .{ .note = (" " ** 19) ++ "Foreground" ++ (" " ** 10) ++ "Reverse background" },
    };
    for (0..slot_names.len) |index| list = list ++ &[_]Item{.{ .slot = index }};
    list = list ++ &[_]Item{
        .blank,
        .{ .title = "Text on colored backgrounds" },
        .blank,
        .{ .note = "Each word names its own foreground color." },
        .{ .note = "Reverse paints the text in the background color of the terminal." },
        .blank,
    };
    for (0..slot_names.len) |index| list = list ++ &[_]Item{.{ .contrast = index }};
    list = list ++ &[_]Item{
        .blank,
        .{ .title = "Default-color styles" },
        .blank,
        .{ .style = .{ .parameters = "39", .label = "Default foreground" } },
        .{ .style = .{ .parameters = "2;39", .label = "Faint default" } },
        .{ .style = .{ .parameters = "1;39", .label = "Bold default" } },
        .{ .style = .{ .parameters = "7", .label = "Reverse video" } },
        .{ .style = .{ .parameters = "2;7", .label = "Faint reverse" } },
        .{ .style = .{ .parameters = "1;7", .label = "Bold reverse" } },
        .{ .style = .{ .parameters = "39;100", .label = "Default on bright black" } },
        .{ .style = .{ .parameters = "2;39;100", .label = "Faint default on bright black" } },
        .{ .style = .{ .parameters = "1;39;100", .label = "Bold default on bright black" } },
        .blank,
        .{ .note = "Below: each interface element with its mapped colors." },
        .blank,
        .{ .title = "Message boxes" },
        .blank,
    };
    list = list ++ boxItems(.user, "user: Your message to the model.");
    list = list ++ &[_]Item{.blank};
    list = list ++ boxItems(.tool_pending, "tool_pending: A tool call that still runs.");
    list = list ++ &[_]Item{.blank};
    list = list ++ boxItems(.tool_success, "tool_success: A tool call that finished.");
    list = list ++ &[_]Item{.blank};
    list = list ++ boxItems(.tool_error, "tool_error: A tool call that failed.");
    list = list ++ &[_]Item{
        .blank,
        .{ .title = "Text roles" },
        .blank,
        .{ .sample = .{ .label = "Reply", .name = .text, .text = "A plain model reply." } },
        .{ .sample = .{
            .label = "Status",
            .name = .muted,
            .text = "~/pith (main) · Context: 42% · $0.14",
        } },
        .{ .sample = .{ .label = "Notice", .name = .muted, .text = "Selection canceled." } },
        .{ .sample = .{
            .label = "Thinking",
            .name = .muted,
            .italic = true,
            .text = "Reasoning streams in this tone.",
        } },
        .{ .sample = .{ .label = "Heading", .name = .heading, .text = "Findings" } },
        .{ .sample = .{ .label = "Code", .name = .code, .text = "const answer = 42;" } },
        .{ .sample = .{
            .label = "Link",
            .name = .link,
            .underline = true,
            .text = "https://example.com",
        } },
        .{ .sample = .{ .label = "Accent", .name = .accent, .text = "Skill: zig-style" } },
        .{ .sample = .{ .label = "Warning", .name = .warning, .text = "Enter: Send anyway" } },
        .{ .sample = .{ .label = "Error", .name = .@"error", .text = "Error: the tool failed." } },
        .blank,
        .{ .title = "Input frames" },
        .blank,
        .{ .note = "The editor with hidden rows during a running turn:" },
        .{ .separator = .labelled },
        .{ .framed = .{ .text = "A draft message" } },
        .{ .separator = .plain },
        .blank,
        .{ .note = "A picker with one selected row:" },
        .{ .separator = .plain },
        .{ .framed = .{} },
        .{ .framed = .{ .name = .muted, .text = " Select a model" } },
        .{ .framed = .{
            .name = .muted,
            .text = " ↑/↓: Move · Enter: Select · Esc: Cancel",
        } },
        .{ .framed = .{ .name = .muted, .text = "   Another option" } },
        .{ .framed = .{ .name = .selection, .text = " > The selected option (Current)" } },
        .{ .framed = .{} },
        .{ .separator = .plain },
    };
    break :blk list;
};

/// The three rows of one box sample: a padding row, the text row, a padding row.
fn boxItems(comptime name: role.Name, comptime text: []const u8) []const Item {
    return &[_]Item{
        .{ .box_fill = name },
        .{ .box_text = .{ .name = name, .text = text } },
        .{ .box_fill = name },
    };
}

/// Physical rows of the whole page body. The count is a compile-time constant,
/// so it never depends on the width.
pub fn rows() usize {
    return items.len;
}

/// Compose the rows whose lines land in `[placement.skip, placement.skip +
/// rows_max)`. Line 0 of the page body is `placement.base`.
pub fn renderWindow(placement: *const paint.Placement, rows_max: usize) !void {
    const line_end = placement.skip +| rows_max;
    inline for (items, 0..) |item, index| {
        const line = placement.base + index;
        if (line >= placement.skip and line < line_end) try renderItem(placement, item, line);
    }
}

fn renderItem(placement: *const paint.Placement, comptime item: Item, line: usize) !void {
    const sink = placement.sink;
    sink.begin();
    switch (item) {
        .blank => {},
        .title => |text| {
            try attribute.emphasize(sink, .text, false);
            try sink.text(text);
            try attribute.apply(sink, .reset);
        },
        .note => |text| {
            try role.apply(sink, .muted);
            try sink.text(text);
            try attribute.apply(sink, .reset);
        },
        .slot => |index| try renderSlot(sink, index),
        .contrast => |index| try renderContrast(sink, index),
        .style => |style| try renderStyle(sink, style),
        .sample => |sample| try renderSample(sink, sample),
        .box_fill => |name| try renderBoxFill(placement, name),
        .box_text => |box| try renderBoxText(placement, box),
        .separator => |separator| try renderSeparator(placement, separator),
        .framed => |framed| try renderFramed(sink, framed),
    }
    sink.end(.{ .id = placement.id, .line = line });
}

/// Get the standard foreground SGR parameter for one ANSI slot.
fn foregroundParameter(comptime index: u8) u16 {
    std.debug.assert(index < slot_names.len);
    return if (index < 8)
        30 + @as(u16, index)
    else
        90 + @as(u16, index - 8);
}

/// One palette row: the slot label, the foreground slot in every intensity on
/// the default background, then the slot as one reverse-video chip. The swap
/// fills the chip with the slot color and paints the text in the background
/// color of the terminal, in every intensity.
fn renderSlot(sink: *terminal.View.Sink, comptime index: u8) !void {
    const foreground = comptime foregroundParameter(index);
    try sink.text(std.fmt.comptimePrint("{d:>2} {s:<15}", .{ index, slot_names[index] }));
    try renderIntensities(sink, std.fmt.comptimePrint("{d}", .{foreground}));
    try sink.text(" ");
    try renderIntensities(sink, std.fmt.comptimePrint("7;{d}", .{foreground}));
}

/// One contrast row: the slot as one filled background chip, and on it every
/// terminal-owned text color option. Each word names its own foreground: the
/// default, black, white, bright black, and bright white. The reverse span sets
/// the slot as the foreground and swaps, so its text takes the background color
/// of the terminal and the fill joins the chip seamlessly.
fn renderContrast(sink: *terminal.View.Sink, comptime index: u8) !void {
    const foreground = comptime foregroundParameter(index);
    const background = std.fmt.comptimePrint("{d}", .{foreground + 10});
    try sink.text(std.fmt.comptimePrint("{d:>2} {s:<15}", .{ index, slot_names[index] }));
    try sink.sgr("\x1b[0;" ++ background ++ "m");
    try sink.text(" default ");
    try sink.sgr("\x1b[0;30;" ++ background ++ "m");
    try sink.text("black ");
    try sink.sgr("\x1b[0;37;" ++ background ++ "m");
    try sink.text("white ");
    try sink.sgr("\x1b[0;90;" ++ background ++ "m");
    try sink.text("bright black ");
    try sink.sgr("\x1b[0;97;" ++ background ++ "m");
    try sink.text("bright white ");
    try sink.sgr(std.fmt.comptimePrint("\x1b[0;7;{d}m", .{foreground}));
    try sink.text(" reverse ");
    try attribute.apply(sink, .reset);
}

/// The faint, normal, and bold variants of one color, each word in its own
/// intensity. Every span opens with a reset, so a background chip stays one
/// contiguous fill while the intensity changes inside it.
fn renderIntensities(sink: *terminal.View.Sink, comptime parameters: []const u8) !void {
    try sink.sgr("\x1b[0;2;" ++ parameters ++ "m");
    try sink.text(" faint ");
    try sink.sgr("\x1b[0;" ++ parameters ++ "m");
    try sink.text("normal ");
    try sink.sgr("\x1b[0;1;" ++ parameters ++ "m");
    try sink.text("bold ");
    try attribute.apply(sink, .reset);
}

fn renderStyle(sink: *terminal.View.Sink, comptime style: Style) !void {
    try sink.text(std.fmt.comptimePrint("{s:<9}{s:<30}", .{ style.parameters, style.label }));
    try sink.sgr("\x1b[" ++ style.parameters ++ "m");
    try sink.text("Sample text");
    try attribute.apply(sink, .reset);
}

fn renderSample(sink: *terminal.View.Sink, comptime sample: Sample) !void {
    try sink.text(std.fmt.comptimePrint("{s:<10}", .{sample.label ++ ":"}));
    try role.apply(sink, sample.name);
    if (sample.italic) try attribute.apply(sink, .italic);
    if (sample.underline) try attribute.apply(sink, .underline);
    try sink.text(sample.text);
    if (role.paints(sample.name) or sample.italic or sample.underline) {
        try attribute.apply(sink, .reset);
    }
}

/// A box padding row: the role's fill carried to the full width.
fn renderBoxFill(placement: *const paint.Placement, comptime name: role.Name) !void {
    const sink = placement.sink;
    try role.apply(sink, name);
    try sink.spaces(placement.columns);
    try attribute.apply(sink, .reset);
}

/// A box text row through the live box geometry. The row truncates where a
/// live box wraps, so the row count stays constant.
fn renderBoxText(placement: *const paint.Placement, comptime box: BoxText) !void {
    const sink = placement.sink;
    try role.apply(sink, box.name);
    try paint.boxCells(sink, placement.columns, box.text);
    try attribute.apply(sink, .reset);
}

/// An input separator across the full width, drawn by the live separator
/// painter. Active forms hold the moving segment at one fixed tick.
fn renderSeparator(placement: *const paint.Placement, comptime separator: Separator) !void {
    const options: paint.SeparatorOptions = switch (separator) {
        .plain => .{},
        .labelled => .{
            .activity = .{ .motion_tick = 20, .progress_age_ticks = 0 },
            .hidden_above = 3,
        },
    };
    try paint.separatorCells(placement.sink, placement.columns, &options);
    try attribute.apply(placement.sink, .reset);
}

fn renderFramed(sink: *terminal.View.Sink, comptime framed: Framed) !void {
    if (framed.name) |name| try role.apply(sink, name);
    try sink.text(framed.text);
    if (framed.name != null) try attribute.apply(sink, .reset);
}

fn collectRoles(comptime item: Item, names: *std.EnumSet(role.Name)) void {
    switch (item) {
        .sample => |sample| names.insert(sample.name),
        .box_fill => |name| names.insert(name),
        .box_text => |box| names.insert(box.name),
        .separator => |separator| {
            names.insert(.input_frame);
            if (separator == .labelled) {
                names.insert(.muted);
                names.insert(.activity);
            }
        },
        .framed => |framed| {
            if (framed.name != null) names.insert(framed.name.?);
        },
        else => {},
    }
}

/// The SGR parameters the preview can emit: the reset, the bold, faint, italic,
/// underline, and reverse styles, and the terminal-owned color slots.
fn legalParameter(parameter: u16) bool {
    return switch (parameter) {
        0, 1, 2, 3, 4, 7, 39, 49 => true,
        else => (parameter >= 30 and parameter <= 37) or
            (parameter >= 40 and parameter <= 47) or
            (parameter >= 90 and parameter <= 97) or
            (parameter >= 100 and parameter <= 107),
    };
}

/// Assert that every SGR sequence in `bytes` carries legal parameters alone.
/// Non-SGR control sequences (cursor moves, sync marks) pass through.
fn expectTerminalOwnedSgr(bytes: []const u8) !void {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, index, "\x1b[")) |start| {
        var cursor = start + 2;
        while (cursor < bytes.len and !std.ascii.isAlphabetic(bytes[cursor])) cursor += 1;
        try std.testing.expect(cursor < bytes.len);
        index = cursor + 1;
        if (bytes[cursor] != 'm') continue;
        var parameters = std.mem.splitScalar(u8, bytes[start + 2 .. cursor], ';');
        while (parameters.next()) |text| {
            try std.testing.expect(legalParameter(try std.fmt.parseInt(u16, text, 10)));
        }
    }
}

fn renderedWindow(
    gpa: std.mem.Allocator,
    columns: usize,
    skip: usize,
    rows_max: usize,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = rows_max }, 1);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = skip,
    };
    try renderWindow(&placement, rows_max);
    try view.render();
    return gpa.dupe(u8, output.written());
}

test "the preview paints one row per item at wide and narrow widths" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 80, 34, 8, 1 }) |columns| {
        const painted = try renderedWindow(gpa, columns, 0, rows());
        defer gpa.free(painted);
        try std.testing.expectEqual(rows(), std.mem.count(u8, painted, "\r\n") + 1);
    }
}

test "the preview item table covers every interface role" {
    var names: std.EnumSet(role.Name) = .initEmpty();
    inline for (items) |item| collectRoles(item, &names);
    try std.testing.expectEqual(std.enums.values(role.Name).len, names.count());
}

test "ANSI slots map to their standard foreground parameters" {
    try std.testing.expectEqual(@as(u16, 30), foregroundParameter(0));
    try std.testing.expectEqual(@as(u16, 37), foregroundParameter(7));
    try std.testing.expectEqual(@as(u16, 90), foregroundParameter(8));
    try std.testing.expectEqual(@as(u16, 97), foregroundParameter(15));
}

test "the preview shows the palette, the styles, the boxes, the roles, and the frames" {
    const gpa = std.testing.allocator;
    const painted = try renderedWindow(gpa, 80, 0, rows());
    defer gpa.free(painted);

    // The palette: every intensity of the magenta foreground, and the
    // reverse-video chip that fills with the slot and swaps the text.
    try std.testing.expect(std.mem.indexOf(u8, painted, "bright magenta") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0;2;35m faint") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0;35mnormal") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0;1;35mbold") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0;2;7;35m faint") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0;1;7;35mbold") != null);
    // The contrast rows: every text color option on the red background, and
    // the reverse span that swaps the red foreground.
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0;30;41mblack") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0;97;41mbright white") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0;7;31m reverse") != null);
    // The styles carry their exact parameters.
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[2;39mSample text") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[1;39;100mSample text") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[7mSample text") != null);
    // The boxes paint through the live role map and name their state inline.
    const user_row = comptime role.sequence(.user) ++ " user: Your message";
    try std.testing.expect(std.mem.indexOf(u8, painted, user_row) != null);
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "tool_error: A tool call that failed.") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, painted, "unused:") == null);
    // The text roles and the frames include plain reply text and a labelled
    // separator with its activity segment to the right of the label.
    try std.testing.expect(std.mem.indexOf(u8, painted, "A plain model reply.") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Thinking:") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "https://example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "↑ Hidden: 3") != null);
    const segment = comptime role.sequence(.activity) ++ "╼━━━━╾";
    try std.testing.expect(std.mem.indexOf(u8, painted, segment) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "(Current)") != null);
}

test "extended color selectors are not legal preview parameters" {
    try std.testing.expect(!legalParameter(38));
    try std.testing.expect(!legalParameter(48));
    try std.testing.expect(legalParameter(39));
    try std.testing.expect(legalParameter(49));
}

test "the preview emits terminal-owned SGR parameters alone" {
    const gpa = std.testing.allocator;
    const painted = try renderedWindow(gpa, 80, 0, rows());
    defer gpa.free(painted);
    try expectTerminalOwnedSgr(painted);
}

test "the window drops the rows outside its bounds" {
    const gpa = std.testing.allocator;
    const painted = try renderedWindow(gpa, 40, 5, 3);
    defer gpa.free(painted);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, painted, "\r\n") + 1);
    try std.testing.expect(std.mem.indexOf(u8, painted, "theme of the terminal") == null);
}
