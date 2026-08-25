//! A temporary full-window, read-only page: a one-row semantic caption above a
//! bounded body. The caption keeps an accent title and sheds whole muted
//! control segments as the window narrows. Pages own their title and source,
//! and can show rendered Markdown or the exact wrapped source. They preserve a
//! source location across reflow. The colors presentation shows the generated
//! color preview instead of a source.

const std = @import("std");

const terminal = @import("terminal");

const Caption = @import("Caption.zig");
const colors = @import("colors.zig");
const markdown = @import("markdown.zig");
const paint = @import("paint.zig");

const Page = @This();

const hint = "↑/↓: Scroll · PgUp/PgDn: Page · Home/End: Jump";
// Esc is the documented way out. Ctrl+C and Ctrl+D close the page too, but they
// stay off the caption. They are a fallback for a terminal that drops the Esc
// report, not a second binding to learn.
const controls_markdown = "Esc: Close · M: Source · " ++ hint;
const controls_source = "Esc: Close · M: Render · " ++ hint;
const controls_colors = "Esc: Close · " ++ hint;

gpa: std.mem.Allocator,
/// The semantic title in the fixed caption.
title: []const u8,
content: []const u8,
/// First rendered body row visible below the fixed caption.
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
    /// The semantic title in the fixed caption.
    title: []const u8,
    /// The page's source. The colors presentation generates its body, so it
    /// takes an empty content.
    content: []const u8,
    presentation: Presentation = .markdown,
};

/// Copy the title and content into a page owned by `gpa`.
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
        .presentation = options.presentation,
        .layout_columns = 0,
        .layout_presentation = options.presentation,
        .layout_rows = 0,
    };
}

pub fn deinit(self: *Page) void {
    self.gpa.free(self.title);
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

/// Render the fixed caption row and the active presentation's bounded body
/// window.
pub fn render(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
) !void {
    const caption_rows = try self.caption().render(placement);
    switch (self.presentation) {
        .markdown => try self.renderMarkdown(placement, size, caption_rows),
        .source => try self.renderSource(placement, size, caption_rows),
        .colors => try self.renderColors(placement, size, caption_rows),
    }
}

/// The key hints of the active presentation.
fn controls(self: *const Page) []const u8 {
    return switch (self.presentation) {
        .markdown => controls_markdown,
        .source => controls_source,
        .colors => controls_colors,
    };
}

/// The fixed title and controls at the head of this page. The caption keeps
/// one row at every width: it sheds whole control segments from the tail, and
/// only the title of a very narrow window cuts with one `…`.
fn caption(self: *const Page) Caption {
    return .{
        .title = self.title,
        .controls = self.controls(),
        .rows_max = 1,
    };
}

/// Physical rows the caption occupies: always one.
fn captionRows(self: *const Page, size: terminal.View.Size) usize {
    return self.caption().rows(@max(size.columns, 1));
}

fn renderMarkdown(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
    caption_rows: usize,
) !void {
    const body_base = placement.base + caption_rows;
    // The derived placement copies its parent. Only the geometry changes.
    var body_placement = placement.*;
    body_placement.base = body_base;
    body_placement.skip = body_base + self.scroll;
    try markdown.renderWindow(&body_placement, self.content, &.{
        .rows_max = @max(size.rows, 1) - caption_rows,
    });
}

fn renderColors(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
    caption_rows: usize,
) !void {
    const body_base = placement.base + caption_rows;
    // The derived placement copies its parent. Only the geometry changes.
    var body_placement = placement.*;
    body_placement.base = body_base;
    body_placement.skip = body_base + self.scroll;
    try colors.renderWindow(&body_placement, @max(size.rows, 1) - caption_rows);
}

fn renderSource(
    self: *const Page,
    placement: *const paint.Placement,
    size: terminal.View.Size,
    caption_rows: usize,
) !void {
    const visible_rows = @max(size.rows, 1) - caption_rows;
    const columns_max = @max(size.columns, 1);
    var iterator = terminal.width.wrapper(self.content, columns_max);
    var source_index: usize = 0;
    var shown: usize = 0;
    while (iterator.next()) |row| : (source_index += 1) {
        if (source_index < self.scroll) continue;
        if (shown >= visible_rows) break;
        shown += 1;
        // The anchor names the source row, as the markdown body names its own
        // row. One row then keeps one anchor across a scroll, and the clip reads
        // the same line that the anchor states.
        const line = placement.base + caption_rows + source_index;
        if (line < placement.skip) continue;
        placement.sink.begin();
        try placement.sink.text(row);
        placement.sink.end(.{ .id = placement.id, .line = line });
    }
}

/// Body rows the window leaves below the caption.
fn bodyRows(self: *const Page, size: terminal.View.Size) usize {
    return @max(size.rows, 1) - self.captionRows(size);
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
    return self.layout_rows -| self.bodyRows(size);
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
        .title = "Test page",
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
        .title = "Test page",
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
        .title = "Test page",
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
        .title = "Test page",
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
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "", .presentation = .colors });
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

    // A narrow reflow keeps the exact row, because the caption keeps one row
    // at every width and the preview row count is constant.
    const scroll = page.scroll;
    const narrow_size: terminal.View.Size = .{ .columns = 24, .rows = 12 };
    page.reflow(narrow_size);
    try std.testing.expectEqual(scroll, page.scroll);
    // The narrow caption sheds whole control segments from the tail and keeps
    // the close key, so the body loses no preview row to the caption.
    const narrow = try renderForTest(&page, narrow_size);
    defer gpa.free(narrow);
    try std.testing.expectEqual(@as(usize, 1), page.captionRows(narrow_size));
    try std.testing.expect(std.mem.indexOf(u8, narrow, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "PgUp/PgDn: Page") == null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "Home/End: Jump") == null);

    // The end of the narrow page shows the last preview rows again, and the
    // narrow window clips the tail label of the selected row.
    page.moveEnd(narrow_size);
    const tail = try renderForTest(&page, narrow_size);
    defer gpa.free(tail);
    try std.testing.expect(std.mem.indexOf(u8, tail, "The selected option") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "(Current)") == null);
}

// A one-row window holds the caption alone: the title, the close key, and the
// whole segments that fit. A dropped segment leaves no mark.
test "a one-row page renders only its caption" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "# Hidden" });
    defer page.deinit();
    const painted = try renderForTest(&page, .{ .columns = 80, .rows = 1 });
    defer gpa.free(painted);

    try std.testing.expect(std.mem.indexOf(u8, painted, "Test page") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Close") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Home/End: Jump") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, paint.ellipsis) == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Hidden") == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, painted, "\r\n"));
}
