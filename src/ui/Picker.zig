const std = @import("std");

const Caption = @import("Caption.zig");
const attribute = @import("attribute.zig");
const block = @import("block.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const terminal = @import("terminal");

const Picker = @This();

const hint_cancel = "↑/↓: Move · Enter: Select · Esc: Cancel";
const hint_back = "↑/↓: Move · Enter: Select · Esc: Back";
const hint_wait = "Esc: Cancel";
const tag_current = " (Current)";
const tag_open = " (";
const tag_close = ")";
const pad_selected = " > ";
const pad_plain = "   ";
const unbounded = std.math.maxInt(usize);

gpa: std.mem.Allocator,
title: []const u8,
options: []const Option,
cursor: usize,
marked: ?usize,
content: std.ArrayList(u8),
line_roles: std.ArrayList(?role.Name),
scroll: usize,
cursor_offset: usize,
columns_max: usize,
can_step_back: bool,
wait: ?[]const u8,
wait_link: ?[]const u8,
marks: std.ArrayList(paint.Mark),

pub const Position = struct {
    cursor: usize = 0,
    scroll: usize = 0,
};

pub const Start = struct {
    current: ?usize = null,
    preselected: ?usize = null,
    position: ?Position = null,
    can_step_back: bool = false,
};

pub const RenderOptions = struct {
    viewport_rows: usize,
    activity: ?paint.Activity = null,
};

pub const Option = struct {
    name: []const u8,
    extra: ?[]const u8 = null,
    extra_pressure: bool = false,
    tag: ?[]const u8 = null,
    tag_pressure: bool = false,

    pub fn deinit(self: *const Option, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.extra) |extra| gpa.free(extra);
        if (self.tag) |tag| gpa.free(tag);
    }
};

const RowMarks = struct {
    line_role: role.Name,
    in_use: bool,
    name_start: usize,
    name_end: usize,
    extra_start: usize,
    extra_end: usize,
    extra_pressure: bool,
    extra_present: bool,
    tag_start: usize,
    tag_end: usize,
    tag_pressure: bool,
    tag_present: bool,
};

const Occupancy = struct {
    start: usize,
    len: usize,
    pressure: bool,
    present: bool,
};

pub fn init(
    gpa: std.mem.Allocator,
    title: []const u8,
    options: []const Option,
    start: Start,
) !Picker {
    const rows_max = options.len -| 1;
    const opened: Position = start.position orelse .{
        .cursor = start.preselected orelse start.current orelse 0,
    };
    var self: Picker = .{
        .gpa = gpa,
        .title = title,
        .options = options,
        .cursor = @min(opened.cursor, rows_max),
        .marked = start.current,
        .content = .empty,
        .line_roles = .empty,
        .scroll = @min(opened.scroll, rows_max),
        .cursor_offset = 0,
        .columns_max = unbounded,
        .can_step_back = start.can_step_back,
        .wait = null,
        .wait_link = null,
        .marks = .empty,
    };
    errdefer self.content.deinit(gpa);
    errdefer self.line_roles.deinit(gpa);
    errdefer self.marks.deinit(gpa);
    try self.compose();
    return self;
}

pub fn deinit(self: *Picker) void {
    self.freeOptions();
    self.content.deinit(self.gpa);
    self.line_roles.deinit(self.gpa);
    self.marks.deinit(self.gpa);
}

pub fn beginWait(self: *Picker, text: []const u8) !void {
    return self.beginLinkedWait(text, null);
}

pub fn beginLinkedWait(self: *Picker, text: []const u8, url: ?[]const u8) !void {
    self.freeOptions();
    self.options = &.{};
    self.cursor = 0;
    self.marked = null;
    self.scroll = 0;
    self.wait = text;
    self.wait_link = url;
    errdefer {
        self.wait = null;
        self.wait_link = null;
        self.marks.clearRetainingCapacity();
        self.content.clearRetainingCapacity();
        self.line_roles.clearRetainingCapacity();
    }
    try self.compose();
}

fn freeOptions(self: *Picker) void {
    for (self.options) |*option| option.deinit(self.gpa);
    self.gpa.free(self.options);
}

pub fn position(self: *const Picker) Position {
    return .{ .cursor = self.cursor, .scroll = self.scroll };
}

pub fn moveUp(self: *Picker) !void {
    if (self.options.len == 0) return;
    self.cursor = if (self.cursor == 0) self.options.len - 1 else self.cursor - 1;
    try self.compose();
}

pub fn moveDown(self: *Picker) !void {
    if (self.options.len == 0) return;
    self.cursor = if (self.cursor + 1 >= self.options.len) 0 else self.cursor + 1;
    try self.compose();
}

pub fn reflow(self: *Picker, size: terminal.View.Size) !void {
    const columns_max = paint.contentColumns(size.columns);
    if (self.columns_max != columns_max) {
        self.columns_max = columns_max;
        try self.compose();
    }
    const total_body = terminal.width.rows(self.content.items, columns_max);
    const visible = @min(total_body, paint.bodyLimit(size.rows));
    const cursor_row = terminal.width.caret(self.content.items, .{
        .offset = self.cursor_offset,
        .columns_max = columns_max,
    }).rows_before;
    if (cursor_row < self.scroll) self.scroll = cursor_row;
    if (cursor_row >= self.scroll + visible) self.scroll = cursor_row - visible + 1;
    self.scroll = @min(self.scroll, total_body - visible);
}

pub fn rows(self: *const Picker, size: terminal.View.Size) usize {
    const columns_max = paint.contentColumns(size.columns);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    return self.captionRows(size.columns) +
        paint.framedRows(@min(total_body, paint.bodyLimit(size.rows)));
}

pub fn render(
    self: *const Picker,
    placement: *const paint.Placement,
    options: *const RenderOptions,
) !void {
    const caption_rows = try self.renderCaption(placement);
    const columns_max = paint.contentColumns(placement.columns);
    const total_body = terminal.width.rows(self.content.items, columns_max);
    const visible_rows = @min(total_body, paint.bodyLimit(options.viewport_rows));
    var frame_placement = placement.*;
    frame_placement.base = placement.base + caption_rows;
    try paint.framed(&frame_placement, &.{
        .body = self.content.items,
        .body_rows = visible_rows,
        .hidden_above = self.scroll,
        .hidden_below = total_body - self.scroll - visible_rows,
        .line_roles = self.line_roles.items,
        .marks = self.marks.items,
        .activity = options.activity,
    });
}

fn renderCaption(self: *const Picker, placement: *const paint.Placement) !usize {
    const chrome = self.caption();
    return chrome.render(placement);
}

fn captionRows(self: *const Picker, columns: usize) usize {
    const chrome = self.caption();
    return chrome.rows(columns);
}

fn caption(self: *const Picker) Caption {
    return .{
        .title = self.title,
        .controls = if (self.wait != null)
            hint_wait
        else if (self.can_step_back)
            hint_back
        else
            hint_cancel,
        .rows_max = 3,
    };
}

fn compose(self: *Picker) !void {
    self.content.clearRetainingCapacity();
    self.line_roles.clearRetainingCapacity();
    self.marks.clearRetainingCapacity();
    self.cursor_offset = 0;

    if (self.wait) |text| {
        try self.startLine(.muted);
        try self.content.appendSlice(self.gpa, pad_plain);
        try self.content.appendSlice(self.gpa, text);
        if (self.wait_link) |url| {
            try self.content.appendSlice(self.gpa, paint.separator);
            const start = self.content.items.len;
            try self.content.appendSlice(self.gpa, url);
            try self.marks.append(self.gpa, .{
                .start = start,
                .end = self.content.items.len,
                .role = .link,
                .url = url,
            });
        }
        return self.cut(0, self.columns_max);
    }

    for (self.options, 0..) |*option, index| {
        const chosen = index == self.cursor;
        const in_use = self.marked == index;
        const line_role: role.Name = if (chosen) .selection else .text;
        try self.startLine(line_role);
        if (chosen) self.cursor_offset = self.content.items.len;
        const tag_columns = occupancyColumns(in_use, option);
        const start = self.content.items.len;
        try self.content.appendSlice(self.gpa, if (chosen) pad_selected else pad_plain);
        const name_start = self.content.items.len;
        try self.content.appendSlice(self.gpa, option.name);
        const name_end = self.content.items.len;
        var extra_start: usize = 0;
        var extra_end: usize = 0;
        if (option.extra) |extra| {
            extra_start = self.content.items.len;
            try self.content.appendSlice(self.gpa, paint.separator);
            try self.content.appendSlice(self.gpa, extra);
            extra_end = self.content.items.len;
        }
        if (tag_columns < self.columns_max) {
            try self.cut(start, self.columns_max - tag_columns);
            try self.addRowMarks(&.{
                .line_role = line_role,
                .in_use = in_use,
                .name_start = name_start,
                .name_end = name_end,
                .extra_start = extra_start,
                .extra_end = extra_end,
                .extra_pressure = option.extra_pressure,
                .extra_present = option.extra != null,
                .tag_start = 0,
                .tag_end = 0,
                .tag_pressure = false,
                .tag_present = false,
            });
            const occupancy = try self.appendOccupancy(in_use, option);
            if (occupancy.present) try self.addMark(
                occupancy.start,
                self.content.items.len,
                if (occupancy.pressure) .warning else .muted,
                false,
            );
        } else {
            const occupancy = try self.appendOccupancy(in_use, option);
            try self.cut(start, self.columns_max);
            try self.addRowMarks(&.{
                .line_role = line_role,
                .in_use = in_use,
                .name_start = name_start,
                .name_end = name_end,
                .extra_start = extra_start,
                .extra_end = extra_end,
                .extra_pressure = option.extra_pressure,
                .extra_present = option.extra != null,
                .tag_start = occupancy.start,
                .tag_end = occupancy.start + occupancy.len,
                .tag_pressure = occupancy.pressure,
                .tag_present = occupancy.present,
            });
        }
    }
}

fn occupancyColumns(in_use: bool, option: *const Option) usize {
    if (in_use) return terminal.width.ofText(tag_current);
    const inner = option.tag orelse return 0;
    return terminal.width.ofText(tag_open) + terminal.width.ofText(inner) +
        terminal.width.ofText(tag_close);
}

fn appendOccupancy(self: *Picker, in_use: bool, option: *const Option) !Occupancy {
    if (in_use) {
        const start = self.content.items.len;
        try self.content.appendSlice(self.gpa, tag_current);
        return .{ .start = start, .len = tag_current.len, .pressure = false, .present = true };
    }
    const inner = option.tag orelse
        return .{ .start = 0, .len = 0, .pressure = false, .present = false };
    const start = self.content.items.len;
    try self.content.appendSlice(self.gpa, tag_open);
    try self.content.appendSlice(self.gpa, inner);
    try self.content.appendSlice(self.gpa, tag_close);
    return .{
        .start = start,
        .len = self.content.items.len - start,
        .pressure = option.tag_pressure,
        .present = true,
    };
}

fn addRowMarks(self: *Picker, row: *const RowMarks) !void {
    if (row.in_use) try self.addMark(row.name_start, row.name_end, row.line_role, true);
    if (row.extra_present) try self.addMark(
        row.extra_start,
        row.extra_end,
        if (row.extra_pressure) .warning else .muted,
        false,
    );
    if (row.tag_present) try self.addMark(
        row.tag_start,
        row.tag_end,
        if (row.tag_pressure) .warning else .muted,
        false,
    );
}

fn addMark(self: *Picker, start: usize, end: usize, name: role.Name, underline: bool) !void {
    const to = @min(end, self.content.items.len);
    if (start >= to) return;
    try self.marks.append(self.gpa, .{
        .start = start,
        .end = to,
        .role = name,
        .underline = underline,
    });
}

fn cut(self: *Picker, start: usize, columns_max: usize) !void {
    const shown = paint.cut(self.content.items[start..], columns_max);
    if (!shown.marked) return;
    self.content.shrinkRetainingCapacity(start + shown.kept.len);
    try self.content.appendSlice(self.gpa, paint.ellipsis);
}

fn startLine(self: *Picker, name: role.Name) !void {
    if (self.line_roles.items.len > 0) try self.content.append(self.gpa, '\n');
    try self.line_roles.append(self.gpa, name);
}

fn testPicker(gpa: std.mem.Allocator, labels: []const []const u8, cursor: usize) !Picker {
    const options = try gpa.alloc(Option, labels.len);
    for (labels, options) |label, *option| option.* = .{ .name = try gpa.dupe(u8, label) };
    var picker = try Picker.init(gpa, "Pick", options, .{ .current = 0 });
    picker.cursor = cursor;
    try picker.compose();
    return picker;
}

test "navigation rolls over at both ends and the cursor tracks the selection" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 0);
    defer picker.deinit();

    try picker.moveUp();
    try std.testing.expectEqual(@as(usize, 1), picker.cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
}

test "the frame holds the option rows alone and the caption stays above it" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 1);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 24 };

    try std.testing.expectEqual(@as(usize, 1), picker.captionRows(size.columns));
    try std.testing.expectEqual(@as(usize, 5), picker.rows(size));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "\n\n") == null);
    try std.testing.expect(!std.mem.startsWith(u8, picker.content.items, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, picker.content.items, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Pick") == null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "Esc: Cancel") == null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "alpha (Current)") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, picker.content.items, 0x1b) == null);
    try std.testing.expectEqual(role.Name.text, picker.line_roles.items[0].?);
    try std.testing.expectEqual(role.Name.selection, picker.line_roles.items[1].?);

    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    const title = comptime role.sequence(.accent) ++ "Pick\x1b[0m";
    const controls = comptime role.sequence(.muted) ++ " · ↑/↓: Move";
    try std.testing.expect(std.mem.indexOf(u8, painted, title) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, controls) != null);
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Pick").? < std.mem.indexOf(u8, painted, "─").?,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Esc: Cancel").? < std.mem.indexOf(u8, painted, "─").?,
    );
    try std.testing.expectEqual(@as(usize, 5), block.paintedRows(painted));
}

test "a current name is underlined, an extra is muted, and pressure is warning" {
    const gpa = std.testing.allocator;
    const options = try gpa.alloc(Option, 4);
    options[0] = .{ .name = try gpa.dupe(u8, "high") };
    options[1] = .{
        .name = try gpa.dupe(u8, "medium"),
        .extra = try gpa.dupe(u8, "The model folds this level to low."),
    };
    options[2] = .{
        .name = try gpa.dupe(u8, "max"),
        .extra = try gpa.dupe(u8, "The model drops this level."),
        .extra_pressure = true,
    };
    options[3] = .{
        .name = try gpa.dupe(u8, "google-cloud-key"),
        .tag = try gpa.dupe(u8, "Not loaded"),
        .tag_pressure = true,
    };
    var picker = try Picker.init(gpa, "Pick", options, .{ .current = 0 });
    picker.cursor = 1;
    try picker.compose();
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 24 };
    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);

    try std.testing.expectEqual(role.Name.text, picker.line_roles.items[0].?);
    try std.testing.expectEqual(role.Name.selection, picker.line_roles.items[1].?);
    const current_name = comptime attribute.sequence(.underline) ++ "high";
    const extra = comptime role.sequence(.muted) ++ " · The model folds this level to low.";
    const pressure = comptime role.sequence(.warning) ++ " · The model drops this level.";
    const occupancy = comptime role.sequence(.warning) ++ " (Not loaded)";
    try std.testing.expect(std.mem.indexOf(u8, painted, current_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, extra) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, pressure) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, occupancy) != null);
}

test "option text is not extra or occupancy chrome" {
    const gpa = std.testing.allocator;
    const labels = [_][]const u8{
        "Fix the bug (Current)",
        "Notes · The output limit is unknown.",
        "google-cloud-key (Not loaded)",
    };
    const options = try gpa.alloc(Option, labels.len);
    for (labels, options) |label, *option| option.* = .{ .name = try gpa.dupe(u8, label) };
    var picker = try Picker.init(gpa, "Prompt history", options, .{});
    defer picker.deinit();

    try std.testing.expectEqual(@as(usize, 0), picker.marks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, labels[0]) != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, labels[1]) != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, labels[2]) != null);
}

fn renderForTest(
    gpa: std.mem.Allocator,
    picker: *const Picker,
    size: terminal.View.Size,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(size, 4);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = size.columns,
        .base = 0,
        .skip = 0,
    };
    try picker.render(&placement, &.{ .viewport_rows = size.rows });
    try view.render();
    return gpa.dupe(u8, out.written());
}

test "a linked wait paints its link as a terminal hyperlink" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{"row"}, 0);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 24 };

    try picker.beginLinkedWait("Send the code x7kq4m2p to @bot", "https://t.me/bot?start=x7kq4m2p");
    try picker.reflow(size);
    try std.testing.expectEqualStrings(
        "   Send the code x7kq4m2p to @bot · https://t.me/bot?start=x7kq4m2p",
        picker.content.items,
    );
    try std.testing.expectEqual(@as(usize, 1), picker.marks.items.len);
    try std.testing.expectEqual(role.Name.link, picker.marks.items[0].role);
    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(
        u8,
        painted,
        "\x1b]8;;https://t.me/bot?start=x7kq4m2p\x1b\\https://t.me/bot?start=x7kq4m2p\x1b]8;;\x1b\\",
    ) != null);

    try picker.beginWait("Drinky checks the bot token.");
    try std.testing.expectEqual(@as(usize, 0), picker.marks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "·") == null);
}

test "a wait that cannot compose keeps no borrowed text" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var picker = try testPicker(gpa, &.{"row"}, 0);
    defer picker.deinit();

    const text = "x" ** 4096;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, picker.beginLinkedWait(text, "https://t.me/bot"));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);

    try std.testing.expect(picker.wait == null);
    try std.testing.expect(picker.wait_link == null);
    try std.testing.expectEqual(@as(usize, 0), picker.marks.items.len);
    try std.testing.expectEqual(@as(usize, 0), picker.content.items.len);
    const painted = try renderForTest(gpa, &picker, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
}

test "a list that waits drops its rows, states the wait, and moves its separators" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "Refresh the model list", "claude-opus-5" }, 1);
    defer picker.deinit();
    picker.can_step_back = true;
    const size: terminal.View.Size = .{ .columns = 60, .rows = 24 };

    try picker.beginWait("Drinky fetches the model list.");
    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 0), picker.options.len);
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try std.testing.expect(picker.marked == null);
    try std.testing.expectEqualStrings("   Drinky fetches the model list.", picker.content.items);
    try std.testing.expectEqual(@as(usize, 1), picker.line_roles.items.len);
    try std.testing.expectEqual(role.Name.muted, picker.line_roles.items[0].?);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "claude") == null);
    try std.testing.expectEqual(@as(usize, 4), picker.rows(size));

    try picker.moveDown();
    try picker.moveUp();
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);

    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Back") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Enter: Select") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Drinky fetches") != null);
    try std.testing.expectEqual(@as(usize, 4), block.paintedRows(painted));
    try std.testing.expect(std.mem.indexOf(u8, painted, "━") == null);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(size, 4);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = size.columns,
        .base = 0,
        .skip = 0,
    };
    try picker.render(&placement, &.{
        .viewport_rows = size.rows,
        .activity = .{ .motion_tick = 3, .progress_age_ticks = 0 },
    });
    try view.render();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "━") != null);
}

test "the opening row applies the preselection, current value, and saved position" {
    const gpa = std.testing.allocator;
    const labels = [_][]const u8{ "alpha", "beta", "gamma" };

    for ([_]struct { start: Start, cursor: usize, scroll: usize = 0, marked: ?usize }{
        .{ .start = .{}, .cursor = 0, .marked = null },
        .{ .start = .{ .current = 2 }, .cursor = 2, .marked = 2 },
        .{ .start = .{ .preselected = 1 }, .cursor = 1, .marked = null },
        .{
            .start = .{ .current = 2, .preselected = 1 },
            .cursor = 1,
            .marked = 2,
        },
        .{
            .start = .{ .current = 2, .position = .{ .cursor = 1 } },
            .cursor = 1,
            .marked = 2,
        },
        .{
            .start = .{ .position = .{ .cursor = 1, .scroll = 1 } },
            .cursor = 1,
            .scroll = 1,
            .marked = null,
        },
        .{
            .start = .{ .position = .{ .cursor = 99, .scroll = 99 } },
            .cursor = 2,
            .scroll = 2,
            .marked = null,
        },
    }) |case| {
        const options = try gpa.alloc(Option, labels.len);
        for (labels, options) |label, *option| option.* = .{ .name = try gpa.dupe(u8, label) };
        var picker = try Picker.init(gpa, "Pick", options, case.start);
        defer picker.deinit();
        try std.testing.expectEqual(case.cursor, picker.cursor);
        try std.testing.expectEqual(case.scroll, picker.scroll);
        try std.testing.expectEqual(case.marked, picker.marked);
        try std.testing.expectEqual(case.cursor, picker.position().cursor);
        try std.testing.expectEqual(case.scroll, picker.position().scroll);
    }

    const no_rows = try gpa.alloc(Option, 0);
    var empty = try Picker.init(gpa, "Pick", no_rows, .{ .position = .{ .cursor = 4 } });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.cursor);
}

test "the key hint states the step above a later step" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, 0);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 60, .rows = 24 };
    try picker.reflow(size);

    const first_step = try renderForTest(gpa, &picker, size);
    defer gpa.free(first_step);
    try std.testing.expect(std.mem.indexOf(u8, first_step, "Esc: Cancel") != null);

    picker.can_step_back = true;
    const later_step = try renderForTest(gpa, &picker, size);
    defer gpa.free(later_step);
    try std.testing.expect(std.mem.indexOf(u8, later_step, "Esc: Back") != null);
    try std.testing.expect(std.mem.indexOf(u8, later_step, "Esc: Cancel") == null);
    try std.testing.expectEqual(@as(usize, 1), picker.captionRows(size.columns));
}

test "a row too wide for the window is cut and marked" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{
        "anthropic-plan/claude-sonnet-5",
        "two\nrows in one option",
    }, 0);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 24, .rows = 24 };

    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, picker.content.items, "\n") + 1);
    try std.testing.expectEqual(@as(usize, 3), picker.captionRows(size.columns));
    try std.testing.expectEqual(@as(usize, 7), picker.rows(size));
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "…") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "rows in one option") == null);

    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, " > anthropic-… (Current)") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "anthropic-…") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "(Current)") != null);
    try std.testing.expectEqual(@as(usize, 7), block.paintedRows(painted));
    for ([_][]const u8{ "↑/↓: Move", "Enter: Select" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, painted, part) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Esc: Cancel") == null);

    for ([_]usize{ 24, 8, 3, 1 }) |columns| {
        try picker.reflow(.{ .columns = columns, .rows = 24 });
        var lines = std.mem.splitScalar(u8, picker.content.items, '\n');
        while (lines.next()) |line|
            try std.testing.expect(terminal.width.ofText(line) <= columns);
    }

    try picker.reflow(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "claude-sonnet-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker.content.items, "(Current)") != null);
}

test "a tall option list scrolls the window to keep the selection in view" {
    const gpa = std.testing.allocator;
    var storage: [20][8]u8 = undefined;
    var labels: [20][]const u8 = undefined;
    for (&labels, 0..) |*label, index| {
        label.* = std.fmt.bufPrint(&storage[index], "row{d:0>2}", .{index}) catch unreachable;
    }
    var picker = try testPicker(gpa, &labels, 0);
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 20 };

    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);
    try std.testing.expectEqual(@as(usize, 9), picker.rows(size));

    for (0..19) |_| {
        try picker.moveDown();
        try picker.reflow(size);
    }
    try std.testing.expectEqual(@as(usize, 19), picker.cursor);
    try std.testing.expectEqual(@as(usize, 14), picker.scroll);

    const bottom = try renderForTest(gpa, &picker, size);
    defer gpa.free(bottom);
    const selected = comptime role.sequence(.selection) ++ " > row19\x1b[0m";
    try std.testing.expect(std.mem.indexOf(u8, bottom, selected) != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "row00") == null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "↑ Hidden: 14") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "Pick") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "Esc: Cancel") != null);

    for (0..19) |_| {
        try picker.moveUp();
        try picker.reflow(size);
    }
    try std.testing.expectEqual(@as(usize, 0), picker.cursor);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll);

    const top = try renderForTest(gpa, &picker, size);
    defer gpa.free(top);
    try std.testing.expect(std.mem.indexOf(u8, top, "Pick") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "Esc: Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "row00") != null);
    try std.testing.expect(std.mem.indexOf(u8, top, "row19") == null);
    try std.testing.expect(std.mem.indexOf(u8, top, "↑ Hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, top, "↓ Hidden: 14") != null);

    try picker.moveUp();
    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 19), picker.cursor);
    try std.testing.expectEqual(@as(usize, 14), picker.scroll);
}
