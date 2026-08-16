//! A temporary full-window, read-only page: one muted key-hint row above a
//! bounded body. Pages own their source and can show rendered Markdown or the
//! exact wrapped source. They preserve a source location across reflow. The
//! colors presentation shows the generated color preview instead of a source.

const std = @import("std");

const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const colors = @import("colors.zig");
const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

const Page = @This();

const hint = "↑/↓: Scroll · PgUp/PgDn: Page · Home/End: Jump";
// Esc is the documented way out. Ctrl+C and Ctrl+D close the page too, but they
// stay off the header: they are a fallback for a terminal that drops the Esc
// report, not a second binding to learn.
const header_markdown = "Esc: Close · M: Source · " ++ hint;
const header_source = "Esc: Close · M: Render · " ++ hint;
const header_colors = "Esc: Close · " ++ hint;

gpa: std.mem.Allocator,
content: []const u8,
/// First rendered body row visible below the fixed header.
scroll: usize,
/// Source location of the top body row, retained across a width or presentation
/// change. Null after a scroll, which leaves the location unmapped: the map
/// costs one pass over the content, and only a reflow needs it.
source_offset: ?usize,
presentation: Presentation,
/// The width the cached row math below is laid out for. Zero before the first
/// reflow.
layout_columns: usize,
/// The presentation the cached row math below is laid out for.
layout_presentation: Presentation,
/// Body rows the content occupies in the laid-out width and presentation. It
/// costs one pass over the content, so a scroll step reads it from here.
layout_rows: usize,

pub const Presentation = enum { markdown, source, colors };

pub const Options = struct {
    /// The page's source. The colors presentation generates its body, so it
    /// takes an empty content.
    content: []const u8,
    presentation: Presentation = .markdown,
};

/// Copy the content into a page owned by `gpa`.
pub fn init(gpa: std.mem.Allocator, options: *const Options) !Page {
    const content = try gpa.dupe(u8, options.content);
    return .{
        .gpa = gpa,
        .content = content,
        .scroll = 0,
        .source_offset = 0,
        .presentation = options.presentation,
        .layout_columns = 0,
        .layout_presentation = options.presentation,
        .layout_rows = 0,
    };
}

pub fn deinit(self: *Page) void {
    self.gpa.free(self.content);
}

/// Preserve the current source location across width and presentation changes,
/// and clamp the window after height changes. Only a layout change passes over
/// the content, so one scroll step costs no pass. A fast scroll delivers many
/// steps per frame, and each one must stay cheap.
pub fn reflow(self: *Page, size: terminal.View.Size) void {
    const columns = @max(size.columns, 1);
    const layout_changed = columns != self.layout_columns or
        self.presentation != self.layout_presentation;
    if (layout_changed) {
        // Map the top row to a source location in the old layout, then find that
        // location again in the new one.
        const source_offset = self.sourceOffset();
        self.layout_columns = columns;
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
    self.setScroll(size, self.scroll -| @max(bodyRows(size), 1));
}

pub fn pageDown(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.setScroll(size, self.scroll +| @max(bodyRows(size), 1));
}

pub fn moveHome(self: *Page) void {
    self.scroll = 0;
    self.source_offset = 0;
}

pub fn moveEnd(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.setScroll(size, self.scrollMax(size));
}

/// Toggle between rendered Markdown and exact source around the same source
/// line. The colors presentation has no source, so it stays in place.
pub fn toggleSource(self: *Page, size: terminal.View.Size) void {
    self.reflow(size);
    self.presentation = switch (self.presentation) {
        .markdown => .source,
        .source => .markdown,
        .colors => return,
    };
    self.reflow(size);
}

/// Render the fixed header and the active presentation's bounded body window.
pub fn render(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
) !void {
    try self.renderHeader(placement);
    switch (self.presentation) {
        .markdown => try self.renderMarkdown(placement, size),
        .source => try self.renderSource(placement, size),
        .colors => try self.renderColors(placement, size),
    }
}

fn renderHeader(self: *const Page, placement: *const paint.Placement) !void {
    if (placement.base < placement.skip) return;
    const header = switch (self.presentation) {
        .markdown => header_markdown,
        .source => header_source,
        .colors => header_colors,
    };
    placement.sink.begin();
    try role.apply(placement.sink, .muted);
    try placement.sink.text(header);
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

fn renderMarkdown(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
) !void {
    const body_base = placement.base + 1;
    // The derived placement copies its parent. Only the geometry changes.
    var body_placement = placement.*;
    body_placement.base = body_base;
    body_placement.skip = body_base + self.scroll;
    try markdown.renderWindow(&body_placement, self.content, &.{
        .rows_max = bodyRows(size),
    });
}

fn renderColors(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
) !void {
    const body_base = placement.base + 1;
    // The derived placement copies its parent. Only the geometry changes.
    var body_placement = placement.*;
    body_placement.base = body_base;
    body_placement.skip = body_base + self.scroll;
    try colors.renderWindow(&body_placement, bodyRows(size));
}

fn renderSource(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
) !void {
    const visible_rows = bodyRows(size);
    const columns_max = @max(size.columns, 1);
    var iterator = terminal.width.wrapper(self.content, columns_max);
    var source_index: usize = 0;
    var shown: usize = 0;
    while (iterator.next()) |row| : (source_index += 1) {
        if (source_index < self.scroll) continue;
        if (shown >= visible_rows) break;
        const local_line = 1 + shown;
        shown += 1;
        if (placement.base + local_line < placement.skip) continue;
        placement.sink.begin();
        try placement.sink.text(row);
        placement.sink.end(.{
            .id = placement.id,
            .line = placement.base + 1 + source_index,
        });
    }
}

fn bodyRows(size: terminal.View.Size) usize {
    return @max(size.rows, 1) - 1;
}

/// Body rows the content occupies in the laid-out width and presentation.
fn totalRows(self: *const Page) usize {
    const columns = @max(self.layout_columns, 1);
    return switch (self.layout_presentation) {
        .markdown => markdown.rows(self.content, columns),
        .source => terminal.width.rows(self.content, columns),
        .colors => colors.rows(),
    };
}

fn scrollMax(self: *const Page, size: terminal.View.Size) usize {
    std.debug.assert(self.layout_columns == @max(size.columns, 1));
    return self.layout_rows -| bodyRows(size);
}

fn setScroll(self: *Page, size: terminal.View.Size, row: usize) void {
    const scroll = @min(row, self.scrollMax(size));
    if (scroll == self.scroll) return;
    self.scroll = scroll;
    self.source_offset = null;
}

/// The source location of the top body row in the laid-out width and
/// presentation. A scroll leaves the location unmapped, so this maps it.
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
        // A preview row maps to itself: the row count never depends on the
        // width, so the identity keeps the exact position across a reflow.
        .colors => row,
    };
}

fn rowAtSource(self: *const Page, source_offset: usize) usize {
    return switch (self.layout_presentation) {
        .markdown => markdown.rowAtSource(self.content, &.{
            .columns = self.layout_columns,
            .source_offset = source_offset,
        }),
        .source => self.sourceRowAtOffset(source_offset),
        .colors => @min(source_offset, colors.rows() -| 1),
    };
}

fn sourceRowAtOffset(self: *const Page, source_offset: usize) usize {
    const target = @min(source_offset, self.content.len);
    var iterator = terminal.width.wrapper(self.content, @max(self.layout_columns, 1));
    var result: usize = 0;
    var index: usize = 0;
    while (iterator.nextSpan()) |span| : (index += 1) {
        if (span.start > target) break;
        result = index;
    }
    return result;
}

fn sourceOffsetAtRow(self: *const Page, target: usize) usize {
    var iterator = terminal.width.wrapper(self.content, @max(self.layout_columns, 1));
    var index: usize = 0;
    while (iterator.nextSpan()) |span| : (index += 1) {
        if (index == target) return span.start;
    }
    return self.content.len;
}

fn renderForTest(page: *const Page, size: terminal.View.Size) ![]u8 {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var view = terminal.View.init(gpa, &output.writer);
    defer view.deinit();
    const sink = try view.beginFrame(size, 1);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 1,
        .columns = size.columns,
        .base = 0,
        .skip = 0,
    };
    try page.render(&placement, size);
    try view.render();
    return gpa.dupe(u8, output.written());
}

test "source navigation scrolls by wrapped body rows and clamps at both ends" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .content = "L0\nL1\nL2\nL3",
        .presentation = .source,
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 3 };

    page.moveUp(size);
    try std.testing.expectEqual(@as(usize, 0), page.scroll);
    page.moveDown(size);
    try std.testing.expectEqual(@as(usize, 1), page.scroll);
    page.pageDown(size);
    try std.testing.expectEqual(@as(usize, 2), page.scroll);
    page.moveDown(size);
    try std.testing.expectEqual(@as(usize, 2), page.scroll);
    page.pageUp(size);
    try std.testing.expectEqual(@as(usize, 0), page.scroll);
    page.moveEnd(size);
    try std.testing.expectEqual(@as(usize, 2), page.scroll);
    page.moveHome();
    try std.testing.expectEqual(@as(usize, 0), page.scroll);

    page.moveEnd(size);
    page.reflow(.{ .columns = 80, .rows = 5 });
    try std.testing.expectEqual(@as(usize, 0), page.scroll);
}

test "source reflow preserves the byte location across width changes" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .content = "abcdefghij\nlast",
        .presentation = .source,
    });
    defer page.deinit();
    const narrow: terminal.View.Size = .{ .columns = 5, .rows = 2 };

    // A scroll leaves the location unmapped, and the reflow into the new width
    // maps it back.
    page.moveDown(narrow);
    try std.testing.expectEqual(@as(usize, 1), page.scroll);
    try std.testing.expectEqual(@as(?usize, null), page.source_offset);
    page.reflow(.{ .columns = 10, .rows = 2 });
    try std.testing.expectEqual(@as(usize, 0), page.scroll);
    try std.testing.expectEqual(@as(?usize, 5), page.source_offset);
    page.reflow(narrow);
    try std.testing.expectEqual(@as(usize, 1), page.scroll);
    try std.testing.expectEqual(@as(?usize, 5), page.source_offset);
}

test "markdown is default and source toggles around the same logical line" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .content = "# Heading\n\n- item with **bold** text\nplain 1\nplain 2\nplain 3\nplain 4",
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 6 };
    page.reflow(size);

    const rendered = try renderForTest(&page, size);
    defer gpa.free(rendered);
    try std.testing.expect(page.presentation == .markdown);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "M: Source") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "# Heading") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "**bold**") == null);

    page.moveEnd(size);
    const source_offset = page.sourceOffset();
    try std.testing.expect(source_offset > 0);
    page.toggleSource(size);
    try std.testing.expect(page.presentation == .source);
    try std.testing.expectEqual(@as(?usize, source_offset), page.source_offset);
    const source = try renderForTest(&page, size);
    defer gpa.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "M: Render") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "**bold**") != null);

    const narrow: terminal.View.Size = .{ .columns = 20, .rows = 6 };
    page.reflow(narrow);
    try std.testing.expectEqual(@as(?usize, source_offset), page.source_offset);
    page.toggleSource(narrow);
    try std.testing.expect(page.presentation == .markdown);
    try std.testing.expectEqual(@as(?usize, source_offset), page.source_offset);
    page.reflow(size);
    try std.testing.expectEqual(@as(?usize, source_offset), page.source_offset);
}

test "source rendering is bounded and sanitizes terminal controls" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .content = "first\nsecond\x1b[2J\nthird",
        .presentation = .source,
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 3 };
    page.pageDown(size);

    const painted = try renderForTest(&page, size);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "first") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "third") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[2J") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, painted, "\r\n"));
}

test "a colors page scrolls the preview and ignores the source toggle" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .content = "", .presentation = .colors });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 12 };
    page.reflow(size);

    const top = try renderForTest(&page, size);
    defer gpa.free(top);
    try std.testing.expect(std.mem.indexOf(u8, top, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "M: Source") == null);
    try std.testing.expect(std.mem.indexOf(u8, top, "ANSI slots 0 to 15") != null);

    page.toggleSource(size);
    try std.testing.expect(page.presentation == .colors);

    page.moveEnd(size);
    try std.testing.expectEqual(colors.rows() - (size.rows - 1), page.scroll);
    const bottom = try renderForTest(&page, size);
    defer gpa.free(bottom);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "(Current)") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "ANSI slots") == null);

    // A narrow reflow keeps the exact row, because the row count is constant.
    // The narrow window truncates the selected row, so its tail label goes.
    const scroll = page.scroll;
    page.reflow(.{ .columns = 24, .rows = 12 });
    try std.testing.expectEqual(scroll, page.scroll);
    const narrow = try renderForTest(&page, .{ .columns = 24, .rows = 12 });
    defer gpa.free(narrow);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "The selected option") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "(Current)") == null);
}

test "a one-row page renders only its header" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .content = "# Hidden" });
    defer page.deinit();
    const painted = try renderForTest(&page, .{ .columns = 80, .rows = 1 });
    defer gpa.free(painted);

    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Hidden") == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, painted, "\r\n"));
}
