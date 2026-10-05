const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

const Caption = @This();

title: []const u8,
controls: []const u8 = "",
rows_max: usize = std.math.maxInt(usize),

const Layout = struct {
    mode: Mode,
    rows: usize,

    const Mode = enum { empty, row, split };
};

const ControlLines = struct {
    rest: []const u8,
    columns: usize,

    fn next(self: *ControlLines) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const row = paint.packRow(self.rest, self.columns, .keep);
        const line = self.rest[0..row.end];
        self.rest = self.rest[row.next..];
        return line;
    }
};

pub fn rows(self: *const Caption, columns: usize) usize {
    return self.layout(columns).rows;
}

pub fn render(self: *const Caption, placement: *const paint.Placement) !usize {
    const arrangement = self.layout(placement.columns);
    switch (arrangement.mode) {
        .empty => {},
        .row => if (placement.begin(placement.base)) {
            try self.renderRowCells(placement.sink, placement.columns);
            placement.end(placement.base);
        },
        .split => {
            if (placement.begin(placement.base)) {
                try self.renderTitle(placement.sink, placement.columns);
                placement.end(placement.base);
            }
            var index: usize = 0;
            var lines: ControlLines = .{ .rest = self.controls, .columns = placement.columns };
            while (index < arrangement.rows - 1) : (index += 1) {
                const control_line = lines.next().?;
                const line = placement.base + 1 + index;
                if (!placement.begin(line)) continue;
                try role.apply(placement.sink, .muted);
                try writeHeadText(placement.sink, control_line, placement.columns);
                try attribute.apply(placement.sink, .reset);
                placement.end(line);
            }
        },
    }
    return arrangement.rows;
}

fn renderRowCells(
    self: *const Caption,
    sink: *terminal.View.Sink,
    columns: usize,
) !void {
    try self.renderTitle(sink, columns);
    const title_columns = terminal.width.ofText(self.title);
    if (title_columns > columns or
        std.mem.indexOfScalar(u8, self.title, '\n') != null)
    {
        return;
    }

    const controls = self.rowControls(columns);
    if (controls.len != 0) {
        try role.apply(sink, .muted);
        try sink.text(paint.separator);
        try sink.text(controls);
        try attribute.apply(sink, .reset);
    }
}

fn renderTitle(self: *const Caption, sink: *terminal.View.Sink, columns_max: usize) !void {
    try role.apply(sink, .accent);
    try writeHeadText(sink, self.title, columns_max);
    try attribute.apply(sink, .reset);
}

fn layout(self: *const Caption, columns: usize) Layout {
    if (self.rows_max == 0) return .{ .mode = .empty, .rows = 0 };
    if (self.rows_max == 1 or self.fitsOneRow(columns)) return .{ .mode = .row, .rows = 1 };

    var count: usize = 0;
    var lines: ControlLines = .{ .rest = self.controls, .columns = columns };
    while (count < self.rows_max - 1 and lines.next() != null) count += 1;
    return .{ .mode = .split, .rows = 1 + count };
}

fn fitsOneRow(self: *const Caption, columns: usize) bool {
    if (std.mem.indexOfScalar(u8, self.title, '\n') != null or
        std.mem.indexOfScalar(u8, self.controls, '\n') != null)
    {
        return false;
    }

    const separator_columns = terminal.width.ofText(paint.separator);
    var total = terminal.width.ofText(self.title);
    if (self.controls.len != 0) total += separator_columns + terminal.width.ofText(self.controls);
    return total <= columns;
}

fn rowControls(self: *const Caption, columns: usize) []const u8 {
    const separator_columns = terminal.width.ofText(paint.separator);
    const room = columns - terminal.width.ofText(self.title);
    if (room <= separator_columns) return "";
    return packedSpan(self.controls, room - separator_columns);
}

fn packedSpan(text: []const u8, room: usize) []const u8 {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '\n') != null) return "";
    return text[0..paint.packRow(text, room, .drop).end];
}

fn writeHeadText(sink: *terminal.View.Sink, text: []const u8, columns_max: usize) !void {
    const shown = paint.headCut(text, columns_max);
    try sink.text(shown.kept);
    try shown.writeEllipsis(sink);
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
    try testing.expectShows(painted, &.{title});
    try testing.expectShows(painted, &.{controls});
}

fn rendered(gpa: std.mem.Allocator, caption: *const Caption, columns: usize) ![]u8 {
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = columns, .rows = 20 });
    _ = try caption.render(&placement);
    return gpa.dupe(u8, try rig.painted());
}

fn plainRendered(gpa: std.mem.Allocator, caption: *const Caption, columns: usize) ![]u8 {
    const painted = try rendered(gpa, caption, columns);
    defer gpa.free(painted);
    return terminal.testing.plainText(gpa, painted);
}

test "the first overflow separates the title from the complete control legend" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Effort",
        .controls = "↑/↓: Move · Enter: Select · Esc: Cancel",
    };
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
        .title = "Model: anthropic-plan",
        .controls = "↑/↓: Move · Enter: Select · Esc: Cancel",
    };
    try std.testing.expectEqual(@as(usize, 4), caption.rows(14));
    const plain = try plainRendered(gpa, &caption, 14);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        "Model: anthro…\r\n↑/↓: Move\r\nEnter: Select\r\nEsc: Cancel",
        plain,
    );
}

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

test "a bounded split drops the control segments past its row bound" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Model: anthropic-plan",
        .controls = "↑/↓: Move · Enter: Select · Esc: Cancel",
        .rows_max = 3,
    };
    try std.testing.expectEqual(@as(usize, 3), caption.rows(14));
    const plain = try plainRendered(gpa, &caption, 14);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        "Model: anthro…\r\n↑/↓: Move\r\nEnter: Select",
        plain,
    );
}

test "a bounded caption keeps one title row before the controls" {
    const gpa = std.testing.allocator;
    const caption: Caption = .{
        .title = "Model: anthropic-plan",
        .controls = "Esc: Close",
        .rows_max = 2,
    };
    try std.testing.expectEqual(@as(usize, 2), caption.rows(14));
    const plain = try plainRendered(gpa, &caption, 14);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Model: anthro…\r\nEsc: Close", plain);
}

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
