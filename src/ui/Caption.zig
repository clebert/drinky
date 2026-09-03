//! A semantic title and its control legend above an input or at the head of a
//! page. A title takes the accent role, and every control stays muted. The
//! product title takes the terminal foreground in bold instead.
//!
//! A caption that fits keeps the title and all controls on one row. A caption
//! bounded to one row keeps the title and the longest prefix of whole legend
//! segments that fits beside it. A dropped segment leaves no mark, and only a
//! title that alone overflows the row cuts with one `…`.
//!
//! A caption allowed to grow splits at the first overflow: the title takes one
//! row that never wraps and cuts with `…` when too wide. Control segments wrap
//! at their `·` boundaries under it. A segment alone on a row that still
//! overflows cuts with `…` and never wraps on. A segment past the row bound
//! drops whole. Measurement and painting share this one layout path.

const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

const Caption = @This();

/// The semantic name of the surface. It never takes more than one row.
title: []const u8,
/// Whether the title names the product. It then takes the terminal foreground in
/// bold, where every other title takes the accent role.
product: bool = false,
/// A separator-joined control legend, or empty when the title stands alone.
controls: []const u8 = "",
/// The rows this caption can occupy. A page pins its caption to one row. An
/// input caption takes three, and the intro legend keeps the default.
rows_max: usize = std.math.maxInt(usize),

/// One resolved arrangement. `rows` and `render` both read it, so the rows a
/// caption counts cannot diverge from the rows it paints.
const Layout = struct {
    mode: Mode,
    rows: usize,

    const Mode = enum { empty, row, split };
};

/// The control lines of a split caption: each line packs whole segments up to
/// the width, and a lone segment wider than the row takes that row for the cut
/// to state. A line is a contiguous span, so the separators inside it stay.
const ControlLines = struct {
    rest: []const u8,
    columns: usize,

    fn next(self: *ControlLines) ?[]const u8 {
        if (self.rest.len == 0) return null;
        var end = segmentEnd(self.rest, 0);
        // `end` grows by at least one separator per pass, so the walk ends at
        // the last segment of the legend.
        while (end < self.rest.len) {
            const extended = segmentEnd(self.rest, end + paint.separator.len);
            if (terminal.width.ofText(self.rest[0..extended]) > self.columns) break;
            end = extended;
        }
        const line = self.rest[0..end];
        self.rest = if (end == self.rest.len) "" else self.rest[end + paint.separator.len ..];
        return line;
    }
};

/// Physical rows this caption occupies at `columns`.
pub fn rows(self: *const Caption, columns: usize) usize {
    return self.layout(columns).rows;
}

/// Paint the caption through `placement` and return its occupied rows.
pub fn render(self: *const Caption, placement: *const paint.Placement) !usize {
    const columns_max = @max(placement.columns, 1);
    const arrangement = self.layout(placement.columns);
    switch (arrangement.mode) {
        .empty => {},
        .row => if (placement.base >= placement.skip) {
            placement.sink.begin();
            try self.renderRowCells(placement.sink, placement.columns);
            placement.sink.end(.{ .id = placement.id, .line = placement.base });
        },
        .split => {
            if (placement.base >= placement.skip) {
                placement.sink.begin();
                try self.renderTitle(placement.sink, columns_max);
                placement.sink.end(.{ .id = placement.id, .line = placement.base });
            }
            var index: usize = 0;
            var lines: ControlLines = .{ .rest = self.controls, .columns = columns_max };
            // `layout` counted `rows` on the same lines, so the walk is bounded
            // and every counted row yields a line.
            while (index < arrangement.rows - 1) : (index += 1) {
                const control_line = lines.next().?;
                const line = placement.base + 1 + index;
                if (line < placement.skip) continue;
                placement.sink.begin();
                try role.apply(placement.sink, .muted);
                try writeHeadText(placement.sink, control_line, columns_max);
                try attribute.apply(placement.sink, .reset);
                placement.sink.end(.{ .id = placement.id, .line = line });
            }
        },
    }
    return arrangement.rows;
}

/// Paint the one-row form inside an open sink row: the title, then the longest
/// prefix of whole control segments that fits beside it.
fn renderRowCells(
    self: *const Caption,
    sink: *terminal.View.Sink,
    columns: usize,
) !void {
    const columns_max = @max(columns, 1);
    try self.renderTitle(sink, columns_max);
    const title_columns = terminal.width.ofText(self.title);
    if (title_columns > columns_max or
        std.mem.indexOfScalar(u8, self.title, '\n') != null)
    {
        return;
    }

    const controls = self.rowControls(columns_max);
    if (controls.len != 0) {
        try role.apply(sink, .muted);
        try sink.text(paint.separator);
        try sink.text(controls);
        try attribute.apply(sink, .reset);
    }
}

/// Paint the title: the product title in the foreground in bold, every other
/// title in the accent role.
fn renderTitle(self: *const Caption, sink: *terminal.View.Sink, columns_max: usize) !void {
    if (self.product) {
        try attribute.emphasize(sink, .text, false);
    } else {
        try role.apply(sink, .accent);
    }
    try writeHeadText(sink, self.title, columns_max);
    try attribute.apply(sink, .reset);
}

/// Resolve one caption layout for both measurement and painting.
fn layout(self: *const Caption, columns: usize) Layout {
    if (self.rows_max == 0) return .{ .mode = .empty, .rows = 0 };
    if (self.rows_max == 1 or self.fitsOneRow(columns)) return .{ .mode = .row, .rows = 1 };

    const columns_max = @max(columns, 1);
    var count: usize = 0;
    var lines: ControlLines = .{ .rest = self.controls, .columns = columns_max };
    // Each line consumes at least one segment, so the count stops at the last
    // segment of the legend or at the row bound, whichever comes first.
    while (count < self.rows_max - 1 and lines.next() != null) count += 1;
    return .{ .mode = .split, .rows = 1 + count };
}

/// Whether the complete title and control legend fit on one physical row.
fn fitsOneRow(self: *const Caption, columns: usize) bool {
    if (std.mem.indexOfScalar(u8, self.title, '\n') != null or
        std.mem.indexOfScalar(u8, self.controls, '\n') != null)
    {
        return false;
    }

    const columns_max = @max(columns, 1);
    const separator_columns = terminal.width.ofText(paint.separator);
    var total = terminal.width.ofText(self.title);
    if (self.controls.len != 0) total += separator_columns + terminal.width.ofText(self.controls);
    return total <= columns_max;
}

/// The longest prefix of whole control segments beside the title on the
/// one-row form, or empty. Assumes a title that fits the row.
fn rowControls(self: *const Caption, columns_max: usize) []const u8 {
    const separator_columns = terminal.width.ofText(paint.separator);
    const room = columns_max - terminal.width.ofText(self.title);
    if (room <= separator_columns) return "";
    return packedSpan(self.controls, room - separator_columns);
}

/// The longest prefix of whole segments of `text` that fits `room` columns, or
/// empty. The prefix keeps its inner separators.
fn packedSpan(text: []const u8, room: usize) []const u8 {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '\n') != null) return "";
    var end: usize = 0;
    // `end` grows by at least one separator per pass, so the walk ends at the
    // last segment of the legend.
    while (end < text.len) {
        const start = if (end == 0) 0 else end + paint.separator.len;
        const extended = segmentEnd(text, start);
        if (terminal.width.ofText(text[0..extended]) > room) break;
        end = extended;
    }
    return text[0..end];
}

/// The end of the segment that starts at `start`.
fn segmentEnd(text: []const u8, start: usize) usize {
    return std.mem.indexOfPos(u8, text, start, paint.separator) orelse text.len;
}

/// Paint one row of `text` cut to `columns_max`, with one `…` on a cut.
fn writeHeadText(sink: *terminal.View.Sink, text: []const u8, columns_max: usize) !void {
    const shown = paint.headCut(text, columns_max);
    try sink.text(shown.kept);
    if (shown.marked) try sink.text(paint.ellipsis);
}

fn rendered(gpa: std.mem.Allocator, caption: *const Caption, columns: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 20 }, 1);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    };
    _ = try caption.render(&placement);
    try view.render();
    return gpa.dupe(u8, output.written());
}

fn plainRendered(gpa: std.mem.Allocator, caption: *const Caption, columns: usize) ![]u8 {
    const painted = try rendered(gpa, caption, columns);
    defer gpa.free(painted);
    return terminal.View.plainText(gpa, painted);
}

test "a wide caption keeps its accent title and muted controls on one row" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Effort",
        .controls = "↑/↓: Move · Enter: Select · Esc: Cancel",
    };
    try std.testing.expectEqual(@as(usize, 1), caption.rows(80));

    const painted = try rendered(gpa, &caption, 80);
    defer gpa.free(painted);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, painted, "\r\n"));
    const title = comptime role.sequence(.accent) ++ "Effort\x1b[0m";
    const controls = comptime role.sequence(.muted) ++ " · ↑/↓: Move";
    try std.testing.expect(std.mem.indexOf(u8, painted, title) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, controls) != null);
}

test "the first overflow separates the title from the complete control legend" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Effort",
        .controls = "↑/↓: Move · Enter: Select · Esc: Cancel",
    };
    // The controls fit together at this width. The title does not keep some of
    // them beside it when the complete caption cannot fit.
    try std.testing.expectEqual(@as(usize, 2), caption.rows(40));
    const plain = try plainRendered(gpa, &caption, 40);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        "Effort\r\n↑/↓: Move · Enter: Select · Esc: Cancel",
        plain,
    );
}

test "a narrow caption cuts its one-row title and packs whole controls" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Model: Anthropic Subscription",
        .controls = "↑/↓: Move · Enter: Select · Esc: Cancel",
    };
    try std.testing.expectEqual(@as(usize, 4), caption.rows(14));
    const plain = try plainRendered(gpa, &caption, 14);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        "Model: Anthro…\r\n↑/↓: Move\r\nEnter: Select\r\nEsc: Cancel",
        plain,
    );
}

// A control segment never wraps between its words. A segment alone on a row
// that still overflows cuts with one mark, so one control keeps one row.
test "a lone overwide control segment cuts and never wraps on" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Effort",
        .controls = "↑/↓: Move · Enter: Select · Esc: Cancel",
    };
    try std.testing.expectEqual(@as(usize, 4), caption.rows(8));
    const plain = try plainRendered(gpa, &caption, 8);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        "Effort\r\n↑/↓: Mo…\r\nEnter: …\r\nEsc: Ca…",
        plain,
    );
}

// A bounded split keeps the title row and the control rows that fit. A segment
// past the bound drops whole and leaves no mark.
test "a bounded split drops the control segments past its row bound" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Model: Anthropic Subscription",
        .controls = "↑/↓: Move · Enter: Select · Esc: Cancel",
        .rows_max = 3,
    };
    try std.testing.expectEqual(@as(usize, 3), caption.rows(14));
    const plain = try plainRendered(gpa, &caption, 14);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        "Model: Anthro…\r\n↑/↓: Move\r\nEnter: Select",
        plain,
    );
}

test "a bounded caption keeps one title row before the controls" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Model: Anthropic Subscription",
        .controls = "Esc: Close",
        .rows_max = 2,
    };
    try std.testing.expectEqual(@as(usize, 2), caption.rows(14));
    const plain = try plainRendered(gpa, &caption, 14);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Model: Anthro…\r\nEsc: Close", plain);
}

// One row sheds whole segments from the tail as the window narrows, keeps the
// title longest, and cuts the title only when it alone overflows the row.
test "a one-row caption drops whole segments and keeps the title longest" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "System prompt",
        .controls = "Esc: Close · M: Source · ↑/↓: Scroll · PgUp/PgDn: Page · Home/End: Jump",
        .rows_max = 1,
    };
    const ladder = [_]struct { columns: usize, row: []const u8 }{
        .{
            .columns = 87,
            .row = "System prompt · Esc: Close · M: Source · ↑/↓: Scroll · " ++
                "PgUp/PgDn: Page · Home/End: Jump",
        },
        .{
            .columns = 70,
            .row = "System prompt · Esc: Close · M: Source · ↑/↓: Scroll · PgUp/PgDn: Page",
        },
        .{ .columns = 52, .row = "System prompt · Esc: Close · M: Source · ↑/↓: Scroll" },
        .{ .columns = 38, .row = "System prompt · Esc: Close · M: Source" },
        .{ .columns = 26, .row = "System prompt · Esc: Close" },
        .{ .columns = 25, .row = "System prompt" },
        .{ .columns = 13, .row = "System prompt" },
        .{ .columns = 9, .row = "System p…" },
    };
    for (ladder) |step| {
        try std.testing.expectEqual(@as(usize, 1), caption.rows(step.columns));
        const plain = try plainRendered(gpa, &caption, step.columns);
        defer gpa.free(plain);
        try std.testing.expectEqualStrings(step.row, plain);
    }
}
