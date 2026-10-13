const std = @import("std");

const core = @import("core");
const terminal = @import("terminal");

const Message = @import("../Message.zig");

const attribute = @import("attribute.zig");
const Caption = @import("Caption.zig");
const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

const Page = @This();

const hint = "↑/↓: Scroll · PgUp/PgDn: Page · Home/End: Jump";
const controls_markdown = "Esc: Close · M: Source · " ++ hint;
const controls_source = "Esc: Close · M: Render · " ++ hint;

gpa: std.mem.Allocator,
title: []const u8,
content: std.ArrayList(u8),
status: []const u8,
notice: ?Message,
scroll: usize,
source_offset: ?SourceOffset,
presentation: Presentation,
layout_columns: usize,
layout_presentation: Presentation,
layout_rows: usize,
layout_bytes: usize,

pub const Presentation = enum { markdown, source };

pub const Options = struct {
    title: []const u8,
    content: []const u8,
    status: []const u8 = "",
};

const SourceOffset = union(enum) {
    body: usize,
    notice: usize,
    gap,
};

pub fn init(gpa: std.mem.Allocator, options: *const Options) !Page {
    const title = try gpa.dupe(u8, options.title);
    errdefer gpa.free(title);
    const status = try gpa.dupe(u8, options.status);
    errdefer gpa.free(status);
    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(gpa, options.content);
    return .{
        .gpa = gpa,
        .title = title,
        .content = content,
        .status = status,
        .notice = null,
        .scroll = 0,
        .source_offset = .{ .body = 0 },
        .presentation = .markdown,
        .layout_columns = 0,
        .layout_presentation = .markdown,
        .layout_rows = 0,
        .layout_bytes = 0,
    };
}

pub fn deinit(self: *Page) void {
    self.gpa.free(self.title);
    self.gpa.free(self.status);
    if (self.notice) |*notice| notice.deinit(self.gpa);
    self.content.deinit(self.gpa);
}

pub fn text(self: *const Page) []const u8 {
    return self.content.items;
}

fn displayed(self: *const Page) []const u8 {
    if (self.content.items.len > 0) return self.content.items;
    return if (self.notice == null) self.status else "";
}

pub fn append(self: *Page, addition: []const u8) error{OutOfMemory}!void {
    if (self.content.items.len == 0) self.restart();
    try self.content.appendSlice(self.gpa, addition);
}

pub fn setStatus(self: *Page, status: []const u8) error{OutOfMemory}!void {
    const copy = try self.gpa.dupe(u8, status);
    self.gpa.free(self.status);
    self.status = copy;
    if (self.content.items.len == 0) self.restart();
}

pub fn setNotice(self: *Page, notice: *const Message) error{OutOfMemory}!void {
    const content = try self.gpa.dupe(u8, notice.content);
    const source_offset = self.sourceOffset();
    if (self.notice) |*previous| previous.deinit(self.gpa);
    self.notice = .{ .content = content, .severity = notice.severity };
    self.source_offset = source_offset;
    self.layout_columns = 0;
    if (self.content.items.len == 0) self.restart();
}

fn restart(self: *Page) void {
    self.moveHome();
    self.layout_columns = 0;
}

pub fn reflow(self: *Page, size: terminal.View.Size) void {
    const layout_bytes = self.displayed().len +
        if (self.notice) |notice| notice.content.len else @as(usize, 0);
    const layout_changed = size.columns != self.layout_columns or
        self.presentation != self.layout_presentation or
        layout_bytes != self.layout_bytes;
    if (layout_changed) {
        const source_offset = self.sourceOffset();
        self.layout_columns = size.columns;
        self.layout_presentation = self.presentation;
        self.layout_bytes = layout_bytes;
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
    self.source_offset = .{ .body = 0 };
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
    var body_placement = placement.*;
    body_placement.base += head_rows;
    body_placement.skip = body_placement.base + self.scroll;
    const rows_max = size.rows - head_rows;
    if (self.content.items.len > 0 and self.presentation == .markdown) {
        try markdown.renderWindow(&body_placement, self.text(), &.{ .rows_max = rows_max });
    } else {
        const name: role.Name = if (self.content.items.len == 0) .muted else .text;
        try renderPlain(&body_placement, self.displayed(), name, rows_max);
    }
    if (self.notice) |notice| {
        const gap = body_placement.base + self.mainRows();
        if (self.displayed().len > 0 and gap < body_placement.skip + rows_max) {
            if (body_placement.begin(gap)) body_placement.end(gap);
        }
        body_placement.base += self.noticeStart();
        const style = paint.NoticeStyle.of(notice.severity);
        try renderPlain(&body_placement, notice.content, style.role, rows_max);
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

fn renderPlain(
    placement: *const paint.Placement,
    content: []const u8,
    name: role.Name,
    rows_max: usize,
) !void {
    if (content.len == 0) return;
    var iterator = terminal.width.wrapper(content, placement.columns);
    var line = placement.base;
    while (iterator.next()) |row| : (line += 1) {
        if (line >= placement.skip + rows_max) break;
        if (!placement.begin(line)) continue;
        try role.apply(placement.sink, name);
        try placement.sink.text(row);
        if (role.paints(name)) try attribute.apply(placement.sink, .reset);
        placement.end(line);
    }
}

fn bodyRows(self: *const Page, size: terminal.View.Size) usize {
    return size.rows - self.headRows(size);
}

fn totalRows(self: *const Page) usize {
    const notice = self.notice orelse return self.mainRows();
    return self.noticeStart() + terminal.width.rows(notice.content, self.layout_columns);
}

fn mainRows(self: *const Page) usize {
    const content = self.displayed();
    if (content.len == 0) return 0;
    if (self.content.items.len == 0 or self.layout_presentation == .source)
        return terminal.width.rows(content, self.layout_columns);
    return markdown.rows(content, self.layout_columns);
}

fn noticeStart(self: *const Page) usize {
    return self.mainRows() + @intFromBool(self.displayed().len > 0);
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

fn sourceOffset(self: *const Page) SourceOffset {
    return self.source_offset orelse self.sourceAtRow(self.scroll);
}

fn sourceAtRow(self: *const Page, row: usize) SourceOffset {
    if (self.notice) |notice| {
        const start = self.noticeStart();
        if (row >= start) return .{
            .notice = self.sourceOffsetAtRow(notice.content, row - start),
        };
        if (row == self.mainRows()) return .gap;
    }
    const content = self.displayed();
    if (self.content.items.len == 0 or self.layout_presentation == .source)
        return .{ .body = self.sourceOffsetAtRow(content, row) };
    return .{ .body = markdown.sourceAtRow(content, &.{
        .columns = self.layout_columns,
        .row = row,
    }) };
}

fn rowAtSource(self: *const Page, source_offset: SourceOffset) usize {
    return switch (source_offset) {
        .body => |offset| if (self.content.items.len == 0 or self.layout_presentation == .source)
            self.sourceRowAtOffset(self.displayed(), offset)
        else
            markdown.rowAtSource(self.displayed(), &.{
                .columns = self.layout_columns,
                .source_offset = offset,
            }),
        .notice => |offset| self.noticeStart() +
            self.sourceRowAtOffset(self.notice.?.content, offset),
        .gap => self.mainRows(),
    };
}

fn sourceRowAtOffset(self: *const Page, content: []const u8, source_offset: usize) usize {
    const target = @min(source_offset, content.len);
    var iterator = terminal.width.wrapper(content, self.layout_columns);
    var result: usize = 0;
    var index: usize = 0;
    while (iterator.nextSpan()) |span| : (index += 1) {
        if (span.start > target) break;
        result = index;
    }
    return result;
}

fn sourceOffsetAtRow(self: *const Page, content: []const u8, target: usize) usize {
    var iterator = terminal.width.wrapper(content, self.layout_columns);
    var index: usize = 0;
    while (iterator.nextSpan()) |span| : (index += 1) {
        if (index == target) return span.start;
    }
    return content.len;
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

test "a status shows while the page holds no text, and the first text replaces it" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "", .status = "Wait." });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.reflow(size);
    try expectTopRow(&page, size, "Wait.");

    try page.setStatus("Again.");
    page.reflow(size);
    try expectTopRow(&page, size, "Again.");
    try page.append("Answer");
    page.reflow(size);
    try expectTopRow(&page, size, "Answer");
    try std.testing.expectEqualStrings("Answer", page.text());
    try page.setStatus("Late.");
    page.reflow(size);
    try expectTopRow(&page, size, "Answer");
}

test "wait and retry notes use muted plain text in both presentations" {
    const gpa = std.testing.allocator;
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    for ([_]Presentation{ .markdown, .source }) |presentation| {
        var page = try Page.init(gpa, &.{ .title = "Test page", .content = "", .status = "Wait." });
        defer page.deinit();
        if (presentation == .source) page.toggleSource(size);
        page.reflow(size);
        const waiting = try renderForTest(&page, size);
        defer gpa.free(waiting);
        try testing.expectShows(waiting, &.{"\x1b[2;39mWait."});

        try page.setStatus("**Retry.**");
        page.reflow(size);
        const retry = try renderForTest(&page, size);
        defer gpa.free(retry);
        try testing.expectShows(retry, &.{"\x1b[2;39m**Retry.**"});

        try page.append("Answer");
        page.reflow(size);
        const answer = try renderForTest(&page, size);
        defer gpa.free(answer);
        try testing.expectShows(answer, &.{"Answer"});
        try testing.expectHides(answer, &.{ "Retry.", "\x1b[2;39mAnswer" });
    }
}

test "terminal notes use severity colors without changing the model text in either presentation" {
    const gpa = std.testing.allocator;
    const size: terminal.View.Size = .{ .columns = 80, .rows = 6 };
    const cases = [_]struct { severity: Message.Severity, colored: []const u8 }{
        .{ .severity = .warning, .colored = "\x1b[33m# Details: **down**" },
        .{ .severity = .failure, .colored = "\x1b[31m# Details: **down**" },
    };
    for (cases) |case| {
        for ([_]Presentation{ .markdown, .source }) |presentation| {
            var page = try Page.init(gpa, &.{
                .title = "Test page",
                .content = "**Answer**",
                .status = "Wait.",
            });
            defer page.deinit();
            if (presentation == .source) page.toggleSource(size);
            page.reflow(size);
            try page.setNotice(&.{
                .content = "# Details: **down**\x1b[2J",
                .severity = case.severity,
            });
            page.reflow(size);
            const painted = try renderForTest(&page, size);
            defer gpa.free(painted);
            try testing.expectShows(painted, &.{case.colored});
            try testing.expectHides(painted, &.{ "Wait.", "\x1b[2J" });
            try std.testing.expectEqualStrings("**Answer**", page.text());
            try expectTopRow(&page, size, if (presentation == .source) "**Answer**" else "Answer");
        }
    }
}

test "a terminal note replaces a scrolled wait note when no model text arrived" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .title = "Test page",
        .content = "",
        .status = "W0\nW1\nW2\nW3",
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.moveEnd(size);
    try expectTopRow(&page, size, "W2");
    try page.setNotice(&.{ .content = "Failed.", .severity = .failure });
    page.reflow(size);
    try expectTopRow(&page, size, "Failed.");
    try std.testing.expectEqualStrings("", page.text());
}

test "a terminal note keeps its byte location across width and presentation changes" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "# Answer" });
    defer page.deinit();
    const narrow: terminal.View.Size = .{ .columns = 5, .rows = 3 };
    const wide: terminal.View.Size = .{ .columns = 10, .rows = 3 };
    page.reflow(narrow);
    try page.setNotice(&.{ .content = "abcdefghij\nlast", .severity = .failure });
    page.moveEnd(narrow);
    try expectTopRow(&page, narrow, "last");
    page.moveUp(narrow);
    try expectTopRow(&page, narrow, "fghij");
    page.reflow(wide);
    try expectTopRow(&page, wide, "abcdefghij");
    page.toggleSource(wide);
    try expectTopRow(&page, wide, "abcdefghij");
    page.reflow(narrow);
    try expectTopRow(&page, narrow, "fghij");
    page.toggleSource(narrow);
    try expectTopRow(&page, narrow, "fghij");
}

test "the gap before a terminal note stays separate across presentation changes" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "# Answer" });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 3 };
    page.toggleSource(size);
    try page.setNotice(&.{ .content = "N0\nN1", .severity = .warning });
    page.moveDown(size);
    try expectTopRow(&page, size, "");
    page.toggleSource(size);
    try expectTopRow(&page, size, "");
    page.moveDown(size);
    try expectTopRow(&page, size, "N0");
    page.toggleSource(size);
    try expectTopRow(&page, size, "N0");
}

test "a page owns its status and terminal notes without leaks on allocation failures" {
    try std.testing.checkAllAllocationFailures(core.testing.no_resize_allocator, copyNotes, .{});
}

fn copyNotes(gpa: std.mem.Allocator) !void {
    var page = try Page.init(gpa, &.{
        .title = "Test page",
        .content = "Answer",
        .status = "Wait.",
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 6 };
    page.reflow(size);
    try page.setStatus("Again.");
    {
        const notice = try Message.print(gpa, .failure, "Failed.", .{});
        defer notice.deinit(gpa);
        try page.setNotice(&notice);
    }
    page.reflow(size);
    const painted = try renderForTest(&page, size);
    defer std.testing.allocator.free(painted);
    try testing.expectShows(painted, &.{"Failed."});
    try page.setNotice(&.{ .content = "Incomplete.", .severity = .warning });
    page.reflow(size);
    try std.testing.expectEqualStrings("Answer", page.text());
}

test "a scrolled status hands the top of the page to a new status and to the first text" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{
        .title = "Test page",
        .content = "",
        .status = "S0\nS1\nS2\nS3",
    });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.toggleSource(size);
    page.moveDown(size);
    try expectTopRow(&page, size, "S1");

    try page.setStatus("T0\nT1\nT2");
    page.reflow(size);
    try expectTopRow(&page, size, "T0");
    page.moveDown(size);
    try expectTopRow(&page, size, "T1");
    try page.append("Answer");
    page.reflow(size);
    try expectTopRow(&page, size, "Answer");
}

test "appended text extends the page at the same width and keeps the scroll" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "" });
    defer page.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.toggleSource(size);
    try page.append("L0\nL1");
    page.reflow(size);
    try expectTopRow(&page, size, "L0");

    try page.append("\nL2\nL3");
    page.moveEnd(size);
    try expectTopRow(&page, size, "L2");
    try page.append("\nL4");
    page.reflow(size);
    try expectTopRow(&page, size, "L2");
    page.moveEnd(size);
    try expectTopRow(&page, size, "L3");
}
