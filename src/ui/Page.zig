const std = @import("std");

const core = @import("core");
const terminal = @import("terminal");

const Message = @import("../Message.zig");

const Block = @import("Block.zig");
const Caption = @import("Caption.zig");
const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const testing = @import("testing.zig");

const Page = @This();

const hint = "↑/↓: Scroll · PgUp/PgDn: Page · Home/End: Jump";

gpa: std.mem.Allocator,
title: []const u8,
content: std.ArrayList(u8),
wait: ?Wait,
retry: ?Message,
notice: ?Message,
scroll: usize,
source_offset: ?SourceOffset,
presentation: Presentation,
layout_columns: usize,
layout_presentation: Presentation,
layout_rows: usize,
layout_bytes: usize,
action: Action,

pub const Action = enum { close, discard, apply };

pub const Presentation = enum { markdown, source };

pub const Wait = struct {
    elapsed_ms: i64,
    received_bytes: usize,
    thinking: bool,

    fn render(self: *const Wait, placement: *const paint.Placement) !void {
        const summary: Block.Work.Summary = .{
            .elapsed_ms = self.elapsed_ms,
            .tools = null,
            .received_bytes = self.received_bytes,
            .status = .running,
        };
        const row = summary.row(&.{ .thinking = self.thinking });
        const box = row.box();
        try paint.box(placement, .text, &box);
    }
};

pub const Options = struct {
    title: []const u8,
    content: []const u8,
    action: Action = .close,
};

const SourceOffset = union(enum) {
    body: usize,
    notice: usize,
    gap,
};

pub fn init(gpa: std.mem.Allocator, options: *const Options) !Page {
    const title = try gpa.dupe(u8, options.title);
    errdefer gpa.free(title);
    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(gpa, options.content);
    return .{
        .gpa = gpa,
        .title = title,
        .content = content,
        .wait = null,
        .retry = null,
        .notice = null,
        .scroll = 0,
        .source_offset = .{ .body = 0 },
        .presentation = .markdown,
        .layout_columns = 0,
        .layout_presentation = .markdown,
        .layout_rows = 0,
        .layout_bytes = 0,
        .action = options.action,
    };
}

pub fn deinit(self: *Page) void {
    self.gpa.free(self.title);
    if (self.retry) |*retry| retry.deinit(self.gpa);
    if (self.notice) |*notice| notice.deinit(self.gpa);
    self.content.deinit(self.gpa);
}

pub fn text(self: *const Page) []const u8 {
    return self.content.items;
}

fn waiting(self: *const Page) bool {
    return self.content.items.len == 0 and self.notice == null and self.wait != null;
}

fn displayedNotice(self: *const Page) ?Message {
    if (self.notice) |notice| return notice;
    return if (self.waiting()) self.retry else null;
}

pub fn append(self: *Page, addition: []const u8) error{OutOfMemory}!void {
    if (self.content.items.len == 0) self.restart();
    try self.content.appendSlice(self.gpa, addition);
}

pub fn refreshWait(self: *Page, wait: *const Wait) void {
    self.wait = wait.*;
}

pub fn setRetry(self: *Page, note: *const Message) error{OutOfMemory}!void {
    const copy = try note.dupe(self.gpa);
    if (self.retry) |*previous| previous.deinit(self.gpa);
    self.retry = copy;
    if (self.content.items.len == 0) self.restart();
}

pub fn setNotice(self: *Page, notice: *const Message) error{OutOfMemory}!void {
    const copy = try notice.dupe(self.gpa);
    const source_offset = self.sourceOffset();
    if (self.notice) |*previous| previous.deinit(self.gpa);
    self.notice = copy;
    self.source_offset = source_offset;
    self.layout_columns = 0;
    if (self.content.items.len == 0) self.restart();
}

fn restart(self: *Page) void {
    self.moveHome();
    self.layout_columns = 0;
}

pub fn reflow(self: *Page, size: terminal.View.Size) void {
    const layout_bytes = self.text().len + @intFromBool(self.waiting()) +
        if (self.displayedNotice()) |notice| notice.content.len else @as(usize, 0);
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
    body_placement.rows_max = size.rows - head_rows;
    if (self.waiting()) {
        try self.wait.?.render(&body_placement);
    } else if (self.content.items.len > 0 and self.presentation == .markdown) {
        try markdown.render(&body_placement, null, self.text());
    } else {
        try renderPlain(&body_placement, self.text());
    }
    if (self.displayedNotice()) |notice| {
        if (self.content.items.len > 0) {
            const gap = body_placement.base + self.mainRows();
            if (body_placement.begin(gap)) body_placement.end(gap);
        }
        body_placement.base += self.noticeStart();
        const style = paint.NoticeStyle.of(notice.severity);
        try paint.notice(&body_placement, &style, notice.content);
    }
}

fn controls(self: *const Page) []const u8 {
    return switch (self.action) {
        inline else => |action| switch (self.presentation) {
            inline else => |presentation| (switch (action) {
                .close => "Esc: Close",
                .discard => "Esc: Discard",
                .apply => "Enter: Apply · Esc: Discard",
            }) ++ " · " ++ (switch (presentation) {
                .markdown => "M: Source",
                .source => "M: Render",
            }) ++ " · " ++ hint,
        },
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

fn renderPlain(placement: *const paint.Placement, content: []const u8) !void {
    if (content.len == 0) return;
    var iterator = terminal.width.wrapper(content, placement.columns);
    var line = placement.base;
    while (iterator.next()) |row| : (line += 1) {
        if (line >= placement.skip +| placement.rows_max) break;
        if (!placement.begin(line)) continue;
        try placement.sink.text(row);
        placement.end(line);
    }
}

fn bodyRows(self: *const Page, size: terminal.View.Size) usize {
    return size.rows - self.headRows(size);
}

fn totalRows(self: *const Page) usize {
    const notice = self.displayedNotice() orelse return self.mainRows();
    const style = paint.NoticeStyle.of(notice.severity);
    return self.noticeStart() + paint.noticeRows(&style, notice.content, self.layout_columns);
}

fn mainRows(self: *const Page) usize {
    if (self.waiting()) return 1;
    const content = self.text();
    if (content.len == 0) return 0;
    if (self.layout_presentation == .source)
        return terminal.width.rows(content, self.layout_columns);
    return markdown.rows(content, self.layout_columns);
}

fn noticeStart(self: *const Page) usize {
    return self.mainRows() + @intFromBool(self.content.items.len > 0);
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
    if (self.displayedNotice()) |notice| {
        const start = self.noticeStart();
        const style = paint.NoticeStyle.of(notice.severity);
        if (row >= start) return .{ .notice = style.sourceAtRow(notice.content, &.{
            .columns = self.layout_columns,
            .row = row - start,
        }) };
        if (row == self.mainRows()) return .gap;
    }
    if (self.waiting()) return .{ .body = 0 };
    if (self.layout_presentation == .source)
        return .{ .body = self.sourceOffsetAtRow(self.text(), row) };
    return .{ .body = markdown.sourceAtRow(self.text(), &.{
        .columns = self.layout_columns,
        .row = row,
    }) };
}

fn rowAtSource(self: *const Page, source_offset: SourceOffset) usize {
    return switch (source_offset) {
        .body => |offset| if (self.waiting())
            0
        else if (self.layout_presentation == .source)
            self.sourceRowAtOffset(self.text(), offset)
        else
            markdown.rowAtSource(self.text(), &.{
                .columns = self.layout_columns,
                .source_offset = offset,
            }),
        .notice => |offset| row: {
            const notice = self.displayedNotice().?;
            const style = paint.NoticeStyle.of(notice.severity);
            break :row self.noticeStart() + style.rowAtSource(notice.content, &.{
                .columns = self.layout_columns,
                .source_offset = offset,
            });
        },
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
    try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, lines.next() orelse "", " "));
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

test "a wait line shows until the first model text replaces it" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "" });
    defer page.deinit();
    page.refreshWait(&.{ .elapsed_ms = 0, .received_bytes = 0, .thinking = false });
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.reflow(size);
    try expectTopRow(&page, size, "Agent: work (waiting) · Time: 0s · Received: 0 B");

    page.refreshWait(&.{ .elapsed_ms = 1_000, .received_bytes = 10, .thinking = true });
    page.reflow(size);
    try expectTopRow(&page, size, "Agent: work (thinking) · Time: 1s · Received: 10 B");
    try page.append("Answer");
    page.reflow(size);
    try expectTopRow(&page, size, "Answer");
    try std.testing.expectEqualStrings("Answer", page.text());
    page.refreshWait(&.{ .elapsed_ms = 2_000, .received_bytes = 20, .thinking = false });
    page.reflow(size);
    try expectTopRow(&page, size, "Answer");
}

test "page wait lines and transcript work rows use the same style and layout across widths" {
    const gpa = std.testing.allocator;
    for ([_]Presentation{ .markdown, .source }) |presentation| {
        for ([_]usize{ 1, 14, 15, 20, 30, 40, 80 }) |columns| {
            const size: terminal.View.Size = .{ .columns = columns, .rows = 100 };
            var page = try Page.init(gpa, &.{ .title = "Test page", .content = "" });
            defer page.deinit();
            page.refreshWait(&.{ .elapsed_ms = 3_000, .received_bytes = 2048, .thinking = false });
            if (presentation == .source) page.toggleSource(size);
            page.reflow(size);
            const painted = try renderForTest(&page, size);
            defer gpa.free(painted);
            var lines = std.mem.splitSequence(u8, painted, "\r\n");
            _ = lines.next();
            _ = lines.next();

            var block = try Block.init(gpa, &.{ .thinking = "Reasoning." });
            defer block.deinit(gpa);
            block.present(false);
            block.presentWork(&.{
                .elapsed_ms = 3_000,
                .tools = null,
                .received_bytes = 2048,
                .status = .running,
            });
            var rig: testing.Rig = undefined;
            rig.init(gpa);
            defer rig.deinit();
            const placement = try rig.begin(&.{ .columns = columns, .rows = size.rows });
            try block.render(gpa, &placement);
            const transcript = try rig.painted();
            try std.testing.expect(std.mem.startsWith(
                u8,
                transcript,
                terminal.escape.sync_set,
            ));
            try std.testing.expectEqualStrings(
                transcript[terminal.escape.sync_set.len..],
                lines.rest(),
            );
        }
    }
}

test "page notices and transcript events use the same style and layout across terminal widths" {
    const gpa = std.testing.allocator;
    const note = "Details: **é👩‍💻**\nNext line\x1b[2J";
    for ([_]Message.Severity{ .information, .warning, .failure }) |severity| {
        for ([_]Presentation{ .markdown, .source }) |presentation| {
            for ([_]usize{ 1, 5, 16, 80 }) |columns| {
                const size: terminal.View.Size = .{ .columns = columns, .rows = 100 };
                var page = try Page.init(gpa, &.{ .title = "Test page", .content = "" });
                defer page.deinit();
                try page.setNotice(&.{ .content = note, .severity = severity });
                if (presentation == .source) page.toggleSource(size);
                page.reflow(size);
                const painted = try renderForTest(&page, size);
                defer gpa.free(painted);
                var lines = std.mem.splitSequence(u8, painted, "\r\n");
                _ = lines.next();
                _ = lines.next();

                var block = try Block.init(gpa, &.{ .event = .{
                    .text = note,
                    .severity = severity,
                } });
                defer block.deinit(gpa);
                var rig: testing.Rig = undefined;
                rig.init(gpa);
                defer rig.deinit();
                const placement = try rig.begin(&.{ .columns = columns, .rows = size.rows });
                try block.render(gpa, &placement);
                const transcript = try rig.painted();
                try std.testing.expect(std.mem.startsWith(
                    u8,
                    transcript,
                    terminal.escape.sync_set,
                ));
                try std.testing.expectEqualStrings(
                    transcript[terminal.escape.sync_set.len..],
                    lines.rest(),
                );
            }
        }
    }
}

test "page notices fit the viewport and keep their final row reachable" {
    const gpa = std.testing.allocator;
    for ([_]Message.Severity{ .information, .warning, .failure }) |severity| {
        for ([_]Presentation{ .markdown, .source }) |presentation| {
            for ([_]usize{ 1, 5, 16, 80 }) |columns| {
                for ([_]usize{ 1, 2, 3, 4, 6 }) |rows| {
                    const size: terminal.View.Size = .{ .columns = columns, .rows = rows };
                    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "Text" });
                    defer page.deinit();
                    try page.setNotice(&.{
                        .content = "first\nsecond\nlast",
                        .severity = severity,
                    });
                    if (presentation == .source) page.toggleSource(size);
                    page.reflow(size);
                    const top = try renderForTest(&page, size);
                    defer gpa.free(top);
                    try std.testing.expect(testing.paintedRows(top) <= rows);
                    page.moveEnd(size);
                    const bottom = try plainForTest(&page, size);
                    defer gpa.free(bottom);
                    try std.testing.expect(testing.paintedRows(bottom) <= rows);
                    if (rows < 3) continue;
                    var lines = std.mem.splitSequence(u8, bottom, "\r\n");
                    var last: []const u8 = "";
                    while (lines.next()) |line| last = line;
                    try std.testing.expectEqualStrings(if (columns == 1) "t" else "last", last);
                }
            }
        }
    }
}

test "a notice keeps its prefix row separate from its first content row during navigation" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "" });
    defer page.deinit();
    try page.setNotice(&.{ .content = "A\nB", .severity = .information });
    const size: terminal.View.Size = .{ .columns = 1, .rows = 3 };
    page.reflow(size);
    try expectTopRow(&page, size, "ℹ");
    page.toggleSource(size);
    try expectTopRow(&page, size, "ℹ");
    page.moveDown(size);
    try expectTopRow(&page, size, "A");
    page.toggleSource(size);
    try expectTopRow(&page, size, "A");
    page.moveEnd(size);
    try expectTopRow(&page, size, "B");
    page.moveHome();
    try expectTopRow(&page, size, "ℹ");
}

test "page notes use the transcript symbols and severity colors in both presentations" {
    const gpa = std.testing.allocator;
    const size: terminal.View.Size = .{ .columns = 80, .rows = 6 };
    const cases = [_]struct { severity: Message.Severity, colored: []const u8 }{
        .{ .severity = .information, .colored = "\x1b[22;36mℹ # Details: **down**" },
        .{ .severity = .warning, .colored = "\x1b[33m⚠ # Details: **down**" },
        .{ .severity = .failure, .colored = "\x1b[31m⚠ # Details: **down**" },
    };
    for (cases) |case| {
        for ([_]Presentation{ .markdown, .source }) |presentation| {
            var page = try Page.init(gpa, &.{ .title = "Test page", .content = "**Answer**" });
            defer page.deinit();
            page.refreshWait(&.{ .elapsed_ms = 0, .received_bytes = 0, .thinking = false });
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
            try testing.expectHides(painted, &.{ "Agent: work", "\x1b[2J" });
            try std.testing.expectEqualStrings("**Answer**", page.text());
            try expectTopRow(&page, size, if (presentation == .source) "**Answer**" else "Answer");
        }
    }
}

test "a terminal note replaces a scrolled wait note when no model text arrived" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "" });
    defer page.deinit();
    page.refreshWait(&.{ .elapsed_ms = 0, .received_bytes = 0, .thinking = false });
    try page.setRetry(&.{ .content = "W0\nW1\nW2\nW3", .severity = .information });
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.moveEnd(size);
    try expectTopRow(&page, size, "W2");
    try page.setNotice(&.{ .content = "Failed.", .severity = .failure });
    page.reflow(size);
    try expectTopRow(&page, size, "⚠ Failed.");
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
    try expectTopRow(&page, narrow, "ij");
    page.moveUp(narrow);
    try expectTopRow(&page, narrow, "defgh");
    page.reflow(wide);
    try expectTopRow(&page, wide, "⚠ abcdefgh");
    page.toggleSource(wide);
    try expectTopRow(&page, wide, "⚠ abcdefgh");
    page.reflow(narrow);
    try expectTopRow(&page, narrow, "defgh");
    page.toggleSource(narrow);
    try expectTopRow(&page, narrow, "defgh");
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
    try expectTopRow(&page, size, "⚠ N0");
    page.toggleSource(size);
    try expectTopRow(&page, size, "⚠ N0");
}

test "a page owns its retry and terminal notes without leaks on allocation failures" {
    try std.testing.checkAllAllocationFailures(core.testing.no_resize_allocator, copyNotes, .{});
}

fn copyNotes(gpa: std.mem.Allocator) !void {
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "Answer" });
    defer page.deinit();
    page.refreshWait(&.{ .elapsed_ms = 0, .received_bytes = 0, .thinking = false });
    try page.setRetry(&.{ .content = "Retry.", .severity = .information });
    const size: terminal.View.Size = .{ .columns = 80, .rows = 6 };
    page.reflow(size);
    try page.setRetry(&.{ .content = "Again.", .severity = .information });
    {
        const notice = try Message.print(gpa, .failure, "Failed.", .{});
        defer notice.deinit(gpa);
        try page.setNotice(&notice);
    }
    page.reflow(size);
    const painted = try renderForTest(&page, size);
    defer std.testing.allocator.free(painted);
    try testing.expectShows(painted, &.{"Failed."});
    try page.setNotice(&.{ .content = "Warning.", .severity = .warning });
    page.reflow(size);
    try std.testing.expectEqualStrings("Answer", page.text());
}

test "a new retry note and the first model text each return the page to the top" {
    const gpa = std.testing.allocator;
    var page = try Page.init(gpa, &.{ .title = "Test page", .content = "" });
    defer page.deinit();
    page.refreshWait(&.{ .elapsed_ms = 0, .received_bytes = 0, .thinking = false });
    try page.setRetry(&.{ .content = "S0\nS1\nS2\nS3", .severity = .information });
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    page.toggleSource(size);
    page.moveDown(size);
    try expectTopRow(&page, size, "ℹ S0");

    try page.setRetry(&.{ .content = "T0\nT1\nT2", .severity = .information });
    page.reflow(size);
    try expectTopRow(&page, size, "Agent: work (waiting) · Time: 0s · Received: 0 B");
    page.moveDown(size);
    try expectTopRow(&page, size, "ℹ T0");
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
