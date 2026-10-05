const std = @import("std");

const terminal = @import("terminal");

const Caption = @import("Caption.zig");
const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const testing = @import("testing.zig");

const Page = @This();

const hint = "↑/↓: Scroll · PgUp/PgDn: Page · Home/End: Jump";
const controls_markdown = "Esc: Close · M: Source · " ++ hint;
const controls_source = "Esc: Close · M: Render · " ++ hint;

gpa: std.mem.Allocator,
title: []const u8,
content: []const u8,
scroll: usize,
source_offset: ?usize,
presentation: Presentation,
layout_columns: usize,
layout_presentation: Presentation,
layout_rows: usize,

pub const Presentation = enum { markdown, source };

pub const Options = struct {
    title: []const u8,
    content: []const u8,
};

pub fn init(gpa: std.mem.Allocator, options: *const Options) !Page {
    const title = try gpa.dupe(u8, options.title);
    errdefer gpa.free(title);
    const content = try gpa.dupe(u8, options.content);
    return .{
        .gpa = gpa,
        .title = title,
        .content = content,
        .scroll = 0,
        .source_offset = 0,
        .presentation = .markdown,
        .layout_columns = 0,
        .layout_presentation = .markdown,
        .layout_rows = 0,
    };
}

pub fn deinit(self: *Page) void {
    self.gpa.free(self.title);
    self.gpa.free(self.content);
}

pub fn reflow(self: *Page, size: terminal.View.Size) void {
    const layout_changed = size.columns != self.layout_columns or
        self.presentation != self.layout_presentation;
    if (layout_changed) {
        const source_offset = self.sourceOffset();
        self.layout_columns = size.columns;
        self.layout_presentation = self.presentation;
        self.layout_rows = self.totalRows();
        self.scroll = self.rowAtSource(source_offset);
        self.source_offset = source_offset;
    }

    const scroll_max = self.scrollMax(size);
    if (self.scroll > scroll_max) {
        self.scroll = scroll_max;
        self.source_offset = null;
    }
}

pub fn moveUp(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.setScroll(size, self.scroll -| 1);
}

pub fn moveDown(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.setScroll(size, self.scroll +| 1);
}

pub fn pageUp(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.setScroll(size, self.scroll -| @max(self.bodyRows(size), 1));
}

pub fn pageDown(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.setScroll(size, self.scroll +| @max(self.bodyRows(size), 1));
}

pub fn moveHome(self: *Page) void {
    self.scroll = 0;
    self.source_offset = 0;
}

pub fn moveEnd(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.setScroll(size, self.scrollMax(size));
}

pub fn toggleSource(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.presentation = switch (self.presentation) {
        .markdown => .source,
        .source => .markdown,
    };
    self.reflow(size);
}

pub fn render(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
) !void {
    const caption_rows = try self.caption().render(placement);
    const head_rows = self.headRows(size);
    if (head_rows > caption_rows) {
        const line = placement.base + caption_rows;
        if (placement.begin(line)) placement.end(line);
    }
    switch (self.presentation) {
        .markdown => try self.renderMarkdown(placement, size, head_rows),
        .source => try self.renderSource(placement, size, head_rows),
    }
}

fn controls(self: *const Page) []const u8 {
    return switch (self.presentation) {
        .markdown => controls_markdown,
        .source => controls_source,
    };
}

fn caption(self: *const Page) Caption {
    return .{
        .title = self.title,
        .controls = self.controls(),
        .rows_max = 1,
    };
}

fn captionRows(self: *const Page, size: terminal.View.Size) usize {
    return self.caption().rows(size.columns);
}

fn headRows(self: *const Page, size: terminal.View.Size) usize {
    return @min(self.captionRows(size) + 1, size.rows);
}

fn renderMarkdown(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
    head_rows: usize,
) !void {
    const body_base = placement.base + head_rows;
    var body_placement = placement.*;
    body_placement.base = body_base;
    body_placement.skip = body_base + self.scroll;
    try markdown.renderWindow(&body_placement, self.content, &.{
        .rows_max = size.rows - head_rows,
    });
}

fn renderSource(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
    head_rows: usize,
) !void {
    const visible_rows = size.rows - head_rows;
    var iterator = terminal.width.wrapper(self.content, size.columns);
    var source_index: usize = 0;
    var shown: usize = 0;
    while (iterator.next()) |row| : (source_index += 1) {
        if (source_index < self.scroll) continue;
        if (shown >= visible_rows) break;
        shown += 1;
        const line = placement.base + head_rows + source_index;
        if (!placement.begin(line)) continue;
        try placement.sink.text(row);
        placement.end(line);
    }
}

fn bodyRows(self: *const Page, size: terminal.View.Size) usize {
    return size.rows - self.headRows(size);
}

fn totalRows(self: *const Page) usize {
    return switch (self.layout_presentation) {
        .markdown => markdown.rows(self.content, self.layout_columns),
        .source => terminal.width.rows(self.content, self.layout_columns),
    };
}

fn scrollMax(self: *const Page, size: terminal.View.Size) usize {
    std.debug.assert(self.layout_columns == size.columns);
    return self.layout_rows -| self.bodyRows(size);
}

fn setScroll(self: *Page, size: terminal.View.Size, row: usize) void {
    const scroll = @min(row, self.scrollMax(size));
    if (scroll == self.scroll) return;
    self.scroll = scroll;
    self.source_offset = null;
}

fn sourceOffset(self: *const Page) usize {
    return self.source_offset orelse self.sourceAtRow(self.scroll);
}

fn sourceAtRow(self: *const Page, row: usize) usize {
    return switch (self.layout_presentation) {
        .markdown => markdown.sourceAtRow(self.content, &.{
            .columns = self.layout_columns,
            .row = row,
        }),
        .source => self.sourceOffsetAtRow(row),
    };
}

fn rowAtSource(self: *const Page, source_offset: usize) usize {
    return switch (self.layout_presentation) {
        .markdown => markdown.rowAtSource(self.content, &.{
            .columns = self.layout_columns,
            .source_offset = source_offset,
        }),
        .source => self.sourceRowAtOffset(source_offset),
    };
}

fn sourceRowAtOffset(self: *const Page, source_offset: usize) usize {
    const target = @min(source_offset, self.content.len);
    var iterator = terminal.width.wrapper(self.content, self.layout_columns);
    var result: usize = 0;
    var index: usize = 0;
    while (iterator.nextSpan()) |span| : (index += 1) {
        if (span.start > target) break;
        result = index;
    }
    return result;
}

fn sourceOffsetAtRow(self: *const Page, target: usize) usize {
    var iterator = terminal.width.wrapper(self.content, self.layout_columns);
    var index: usize = 0;
    while (iterator.nextSpan()) |span| : (index += 1) {
        if (index == target) return span.start;
    }
    return self.content.len;
}

test "source navigation scrolls by wrapped body rows and clamps at both ends" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .title = "Test page",
        .content = "L0\nL1\nL2\nL3",
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.toggleSource(size);

    page.moveUp(size);
    try expectTopRow(&page, size, "L0");
    page.moveDown(size);
    try expectTopRow(&page, size, "L1");
    page.pageDown(size);
    try expectTopRow(&page, size, "L2");
    page.moveDown(size);
    try expectTopRow(&page, size, "L2");
    page.pageUp(size);
    try expectTopRow(&page, size, "L0");
    page.moveEnd(size);
    try expectTopRow(&page, size, "L2");
    page.moveHome();
    try expectTopRow(&page, size, "L0");

    page.moveEnd(size);
    const tall: terminal.View.Size = .{ .columns = 80, .rows = 6 };
    page.reflow(tall);
    try expectTopRow(&page, tall, "L0");
}

fn renderForTest(page: *const Page, size: terminal.View.Size) ![]u8 {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    var placement = try rig.begin(&.{ .columns = size.columns, .rows = size.rows });
    placement.id = 1;
    try page.render(&placement, size);
    return gpa.dupe(u8, try rig.painted());
}

fn plainForTest(page: *const Page, size: terminal.View.Size) ![]u8 {
    const gpa = std.testing.allocator;
    const painted = try renderForTest(page, size);
    defer gpa.free(painted);
    return terminal.testing.plainText(gpa, painted);
}

fn expectTopRow(page: *const Page, size: terminal.View.Size, expected: []const u8) !void {
    const plain = try plainForTest(page, size);
    defer std.testing.allocator.free(plain);
    var lines = std.mem.splitSequence(u8, plain, "\r\n");
    _ = lines.next();
    _ = lines.next();
    try std.testing.expectEqualStrings(expected, lines.next() orelse "");
}

test "source reflow preserves the byte location across width changes" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .title = "Test page",
        .content = "abcdefghij\nlast",
    });
    defer page.deinit();
    const narrow: terminal.View.Size = .{ .columns = 5, .rows = 3 };
    const wide: terminal.View.Size = .{ .columns = 10, .rows = 3 };
    page.toggleSource(narrow);

    page.moveDown(narrow);
    try expectTopRow(&page, narrow, "fghij");
    page.reflow(wide);
    try expectTopRow(&page, wide, "abcdefghij");
    page.reflow(narrow);
    try expectTopRow(&page, narrow, "fghij");
}

test "markdown is default and source toggles around the same logical line" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .title = "Test page",
        .content = "# Heading\n\n- item with **bold** text\nplain 1\nplain 2\nplain 3\nplain 4",
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 7 };
    page.reflow(size);

    const rendered = try renderForTest(&page, size);
    defer gpa.free(rendered);
    try testing.expectShows(rendered, &.{"M: Source"});
    try testing.expectHides(rendered, &.{"# Heading"});
    try testing.expectShows(rendered, &.{"Heading"});
    try testing.expectHides(rendered, &.{"**bold**"});

    page.moveEnd(size);
    const scrolled = try plainForTest(&page, size);
    defer gpa.free(scrolled);
    try testing.expectHides(scrolled, &.{"Heading"});
    page.toggleSource(size);
    const source = try renderForTest(&page, size);
    defer gpa.free(source);
    try testing.expectShows(source, &.{"M: Render"});
    try testing.expectShows(source, &.{"**bold**"});
    try testing.expectHides(source, &.{"# Heading"});

    const narrow: terminal.View.Size = .{ .columns = 20, .rows = 7 };
    page.reflow(narrow);
    page.toggleSource(narrow);
    page.reflow(size);
    const returned = try plainForTest(&page, size);
    defer gpa.free(returned);
    try std.testing.expectEqualStrings(scrolled, returned);
}

test "source rendering is bounded and sanitizes terminal controls" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .title = "Test page",
        .content = "first\nsecond\x1b[2J\nthird",
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.toggleSource(size);
    page.pageDown(size);

    const painted = try renderForTest(&page, size);
    defer gpa.free(painted);
    try testing.expectShows(painted, &.{"Esc: Close"});
    try testing.expectHides(painted, &.{"first"});
    try testing.expectShows(painted, &.{"second"});
    try testing.expectShows(painted, &.{"third"});
    try testing.expectHides(painted, &.{"\x1b[2J"});
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, painted, "\r\n"));
}

test "a blank row separates the caption from the body" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .title = "Test page",
        .content = "first\nsecond",
    });
    defer page.deinit();
    page.toggleSource(.{ .columns = 40, .rows = 4 });

    const painted = try renderForTest(&page, .{ .columns = 40, .rows = 4 });
    defer gpa.free(painted);
    const plain = try terminal.testing.plainText(gpa, painted);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        "Test page · Esc: Close · M: Render\r\n\r\nfirst\r\nsecond",
        plain,
    );

    const short = try renderForTest(&page, .{ .columns = 40, .rows = 2 });
    defer gpa.free(short);
    try testing.expectHides(short, &.{"first"});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, short, "\r\n"));
}

test "a one-row page renders only its caption" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "# Hidden" });
    defer page.deinit();
    const painted = try renderForTest(&page, .{ .columns = 80, .rows = 1 });
    defer gpa.free(painted);

    try testing.expectShows(painted, &.{"Test page"});
    try testing.expectShows(painted, &.{"Esc: Close"});
    try testing.expectHides(painted, &.{"Home/End: Jump"});
    try testing.expectHides(painted, &.{paint.ellipsis});
    try testing.expectHides(painted, &.{"Hidden"});
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, painted, "\r\n"));
}
