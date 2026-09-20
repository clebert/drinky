const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

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
        var end = segmentEnd(self.rest, 0);
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

pub fn rows(self: *const Caption, columns: usize) usize {
    return self.layout(columns).rows;
}

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

fn renderTitle(self: *const Caption, sink: *terminal.View.Sink, columns_max: usize) !void {
    try role.apply(sink, .accent);
    try writeHeadText(sink, self.title, columns_max);
    try attribute.apply(sink, .reset);
}

fn layout(self: *const Caption, columns: usize) Layout {
    if (self.rows_max == 0) return .{ .mode = .empty, .rows = 0 };
    if (self.rows_max == 1 or self.fitsOneRow(columns)) return .{ .mode = .row, .rows = 1 };

    const columns_max = @max(columns, 1);
    var count: usize = 0;
    var lines: ControlLines = .{ .rest = self.controls, .columns = columns_max };
    while (count < self.rows_max - 1 and lines.next() != null) count += 1;
    return .{ .mode = .split, .rows = 1 + count };
}

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

fn rowControls(self: *const Caption, columns_max: usize) []const u8 {
    const separator_columns = terminal.width.ofText(paint.separator);
    const room = columns_max - terminal.width.ofText(self.title);
    if (room <= separator_columns) return "";
    return packedSpan(self.controls, room - separator_columns);
}

fn packedSpan(text: []const u8, room: usize) []const u8 {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '\n') != null) return "";
    var end: usize = 0;
    while (end < text.len) {
        const start = if (end == 0) 0 else end + paint.separator.len;
        const extended = segmentEnd(text, start);
        if (terminal.width.ofText(text[0..extended]) > room) break;
        end = extended;
    }
    return text[0..end];
}

fn segmentEnd(text: []const u8, start: usize) usize {
    return std.mem.indexOfPos(u8, text, start, paint.separator) orelse text.len;
}

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
