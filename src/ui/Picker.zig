const std = @import("std");

const terminal = @import("terminal");

const Caption = @import("Caption.zig");
const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

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
current: ?usize,
content: std.ArrayList(u8),
line_roles: std.ArrayList(role.Name),
window: paint.Window,
cursor_offset: usize,
columns: usize,
can_step_back: bool,
wait: ?[]const u8,
marks: std.ArrayList(paint.Mark),

pub const Position = struct {
    cursor: usize = 0,
    scroll: usize = 0,
};

const Start = struct {
    current: ?usize = null,
    preselected: ?usize = null,
    position: ?Position = null,
    can_step_back: bool = false,
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

const Range = struct {
    start: usize,
    end: usize,
};

const RowMarks = struct {
    line_role: role.Name,
    current: bool,
    name: Range,
    extra: ?Range,
    extra_pressure: bool,
    tag: ?Tag = null,

    fn clamp(self: *RowMarks, len: usize) void {
        self.name.end = @min(self.name.end, len);
        if (self.extra) |*extra| extra.end = @min(extra.end, len);
        if (self.tag) |*tag| tag.range.end = @min(tag.range.end, len);
    }
};

const Tag = struct {
    range: Range,
    pressure: bool,
};

pub fn init(
    gpa: std.mem.Allocator,
    title: []const u8,
    options: []const Option,
    start: *const Start,
) !Picker {
    const index_max = options.len -| 1;
    const opened: Position = start.position orelse .{
        .cursor = start.preselected orelse start.current orelse 0,
    };
    var self: Picker = .{
        .gpa = gpa,
        .title = title,
        .options = options,
        .cursor = @min(opened.cursor, index_max),
        .current = start.current,
        .content = .empty,
        .line_roles = .empty,
        .window = .{ .scroll = @min(opened.scroll, index_max) },
        .cursor_offset = 0,
        .columns = unbounded,
        .can_step_back = start.can_step_back,
        .wait = null,
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
    self.freeOptions();
    self.options = &.{};
    self.cursor = 0;
    self.current = null;
    self.window = .{};
    self.wait = text;
    errdefer {
        self.wait = null;
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
    return .{ .cursor = self.cursor, .scroll = self.window.scroll };
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
    if (self.columns != size.columns) {
        self.columns = size.columns;
        try self.compose();
    }
    const cursor_row = terminal.width.caret(self.content.items, .{
        .offset = self.cursor_offset,
        .columns_max = size.columns,
    }).row;
    self.window.follow(self.extent(size), cursor_row);
}

pub fn rows(self: *const Picker, size: terminal.View.Size) usize {
    return self.captionRows(size.columns) + self.extent(size).rows();
}

fn extent(self: *const Picker, size: terminal.View.Size) paint.Window.Extent {
    return .{
        .body_rows = terminal.width.rows(self.content.items, size.columns),
        .viewport_rows = size.rows,
    };
}

pub fn render(
    self: *const Picker,
    placement: *const paint.Placement,
    options: *const paint.RenderOptions,
) !void {
    const caption_rows = try self.renderCaption(placement);
    const shown = self.window.shown(self.extent(.{
        .columns = placement.columns,
        .rows = options.viewport_rows,
    }));
    var frame_placement = placement.*;
    frame_placement.base = placement.base + caption_rows;
    try paint.framed(&frame_placement, &.{
        .body = self.content.items,
        .body_rows = shown.body_rows,
        .hidden_above = shown.hidden_above,
        .hidden_below = shown.hidden_below,
        .line_roles = self.line_roles.items,
        .marks = self.marks.items,
        .activity = options.activity,
    });
}

fn renderCaption(self: *const Picker, placement: *const paint.Placement) !usize {
    return self.caption().render(placement);
}

fn captionRows(self: *const Picker, columns: usize) usize {
    return self.caption().rows(columns);
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
        return self.cut(.{ .start = 0, .columns_max = self.columns });
    }

    for (self.options, 0..) |*option, index| {
        const chosen = index == self.cursor;
        const current = self.current == index;
        const line_role: role.Name = if (chosen) .selection else .text;
        try self.startLine(line_role);
        if (chosen) self.cursor_offset = self.content.items.len;
        const tag_columns = tagColumns(current, option);
        const start = self.content.items.len;
        try self.content.appendSlice(self.gpa, if (chosen) pad_selected else pad_plain);
        const name_start = self.content.items.len;
        try self.content.appendSlice(self.gpa, option.name);
        var row: RowMarks = .{
            .line_role = line_role,
            .current = current,
            .name = .{ .start = name_start, .end = self.content.items.len },
            .extra = try self.appendExtra(option),
            .extra_pressure = option.extra_pressure,
        };
        if (tag_columns < self.columns) {
            try self.cut(.{ .start = start, .columns_max = self.columns - tag_columns });
            row.clamp(self.content.items.len);
            row.tag = try self.appendTag(current, option);
        } else {
            row.tag = try self.appendTag(current, option);
            try self.cut(.{ .start = start, .columns_max = self.columns });
            row.clamp(self.content.items.len);
        }
        try self.addRowMarks(&row);
    }
}

fn appendExtra(self: *Picker, option: *const Option) !?Range {
    const extra = option.extra orelse return null;
    const start = self.content.items.len;
    try self.content.appendSlice(self.gpa, paint.separator);
    try self.content.appendSlice(self.gpa, extra);
    return .{ .start = start, .end = self.content.items.len };
}

fn tagColumns(current: bool, option: *const Option) usize {
    if (current) return terminal.width.ofText(tag_current);
    const inner = option.tag orelse return 0;
    return terminal.width.ofText(tag_open) + terminal.width.ofText(inner) +
        terminal.width.ofText(tag_close);
}

fn appendTag(self: *Picker, current: bool, option: *const Option) !?Tag {
    const start = self.content.items.len;
    if (current) {
        try self.content.appendSlice(self.gpa, tag_current);
    } else {
        const inner = option.tag orelse return null;
        try self.content.appendSlice(self.gpa, tag_open);
        try self.content.appendSlice(self.gpa, inner);
        try self.content.appendSlice(self.gpa, tag_close);
    }
    return .{
        .range = .{ .start = start, .end = self.content.items.len },
        .pressure = !current and option.tag_pressure,
    };
}

fn addRowMarks(self: *Picker, row: *const RowMarks) !void {
    if (row.current) try self.addMark(row.name, row.line_role, true);
    if (row.extra) |extra| try self.addMark(extra, pressureRole(row.extra_pressure), false);
    if (row.tag) |tag| try self.addMark(tag.range, pressureRole(tag.pressure), false);
}

fn pressureRole(pressure: bool) role.Name {
    return if (pressure) .warning else .muted;
}

fn addMark(self: *Picker, range: Range, name: role.Name, underline: bool) !void {
    if (range.start >= range.end) return;
    try self.marks.append(self.gpa, .{
        .start = range.start,
        .end = range.end,
        .role = name,
        .underline = underline,
    });
}

fn cut(self: *Picker, tail: struct { start: usize, columns_max: usize }) !void {
    const shown = paint.cut(self.content.items[tail.start..], tail.columns_max);
    if (!shown.shortened) return;
    self.content.shrinkRetainingCapacity(tail.start + shown.kept.len);
    try self.content.appendSlice(self.gpa, paint.ellipsis);
}

fn startLine(self: *Picker, name: role.Name) !void {
    if (self.line_roles.items.len > 0) try self.content.append(self.gpa, '\n');
    try self.line_roles.append(self.gpa, name);
}

test "navigation rolls over at both ends and the cursor tracks the selection" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, &.{ .current = 0 });
    defer picker.deinit();

    try picker.moveUp();
    try std.testing.expectEqual(@as(usize, 1), picker.position().cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 0), picker.position().cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.position().cursor);
    try picker.moveDown();
    try std.testing.expectEqual(@as(usize, 0), picker.position().cursor);
}

fn testPicker(gpa: std.mem.Allocator, labels: []const []const u8, start: *const Start) !Picker {
    const options = try gpa.alloc(Option, labels.len);
    for (labels, options) |label, *option| option.* = .{ .name = try gpa.dupe(u8, label) };
    return Picker.init(gpa, "Pick", options, start);
}

test "the frame holds the option rows alone and the caption stays above it" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "alpha", "beta" }, &.{ .current = 0, .preselected = 1 });
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 24 };

    try std.testing.expectEqual(@as(usize, 5), picker.rows(size));
    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    const title = comptime role.sequence(.accent) ++ "Pick\x1b[0m";
    const controls = comptime role.sequence(.muted) ++ " · ↑/↓: Move";
    const selected = comptime role.sequence(.selection) ++ " > beta";
    try testing.expectShows(painted, &.{ title, controls, selected });
    try testing.expectHides(painted, &.{comptime role.sequence(.selection) ++ " > alpha"});
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Pick").? < std.mem.indexOf(u8, painted, "─").?,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Esc: Cancel").? < std.mem.indexOf(u8, painted, "─").?,
    );
    try std.testing.expectEqual(@as(usize, 5), testing.paintedRows(painted));

    const plain = try terminal.testing.plainText(gpa, painted);
    defer gpa.free(plain);
    var lines = std.mem.splitSequence(u8, plain, "\r\n");
    try std.testing.expectEqualStrings(
        "Pick · ↑/↓: Move · Enter: Select · Esc: Cancel",
        lines.next().?,
    );
    _ = lines.next();
    try std.testing.expectEqualStrings("   alpha (Current)", lines.next().?);
    try std.testing.expectEqualStrings(" > beta", lines.next().?);
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
    var picker = try Picker.init(gpa, "Pick", options, &.{ .current = 0, .preselected = 1 });
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 24 };
    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);

    const selected = comptime role.sequence(.selection) ++ " > medium";
    const current_name = comptime attribute.sequence(.underline) ++ "high";
    const extra = comptime role.sequence(.muted) ++ " · The model folds this level to low.";
    const pressure = comptime role.sequence(.warning) ++ " · The model drops this level.";
    const tag = comptime role.sequence(.warning) ++ " (Not loaded)";
    try testing.expectShows(painted, &.{ selected, current_name, extra, pressure, tag });
}

test "option text is not extra or tag chrome" {
    const gpa = std.testing.allocator;
    const labels = [_][]const u8{
        "Fix the bug (Current)",
        "Notes · The output limit is unknown.",
        "google-cloud-key (Not loaded)",
    };
    const options = try gpa.alloc(Option, labels.len);
    for (labels, options) |label, *option| option.* = .{ .name = try gpa.dupe(u8, label) };
    var picker = try Picker.init(gpa, "Skill", options, &.{});
    defer picker.deinit();

    const painted = try renderForTest(gpa, &picker, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try testing.expectShows(painted, &labels);
}

fn renderForTest(
    gpa: std.mem.Allocator,
    picker: *const Picker,
    size: terminal.View.Size,
) ![]u8 {
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = size.columns, .rows = size.rows, .pages = 4 });
    try picker.render(&placement, &.{ .viewport_rows = size.rows });
    return gpa.dupe(u8, try rig.painted());
}

test "a wait that cannot compose keeps no borrowed text" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var picker = try testPicker(gpa, &.{"row"}, &.{ .current = 0 });
    defer picker.deinit();

    const text = "x" ** 4096;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, picker.beginWait(text));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);

    const painted = try renderForTest(gpa, &picker, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try testing.expectShows(painted, &.{"Esc: Cancel"});
    try testing.expectHides(painted, &.{ "xxxx", "row" });
}

test "a list that waits drops its rows, states the wait, and moves its frame edges" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{ "Refresh the model list", "claude-opus-5" }, &.{
        .current = 0,
        .preselected = 1,
        .can_step_back = true,
    });
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 60, .rows = 24 };

    try picker.beginWait("Drinky fetches the model list.");
    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 0), picker.position().cursor);
    try std.testing.expectEqual(@as(usize, 4), picker.rows(size));

    try picker.moveDown();
    try picker.moveUp();
    try std.testing.expectEqual(@as(usize, 0), picker.position().cursor);

    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    try testing.expectShows(painted, &.{
        "Esc: Cancel",
        comptime role.sequence(.muted) ++ "   Drinky fetches the model list.",
    });
    try testing.expectHides(painted, &.{ "Esc: Back", "Enter: Select", "claude", "Refresh" });
    try testing.expectHides(painted, &.{"(Current)"});
    try std.testing.expectEqual(@as(usize, 4), testing.paintedRows(painted));
    try testing.expectHides(painted, &.{"━"});

    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = size.columns, .rows = size.rows, .pages = 4 });
    try picker.render(&placement, &.{
        .viewport_rows = size.rows,
        .activity = .{ .motion_tick = 3, .progress_age_ticks = 0 },
    });
    try testing.expectShows(try rig.painted(), &.{"━"});
}

test "the opening row applies the preselection, current value, and saved position" {
    const gpa = std.testing.allocator;
    const labels = [_][]const u8{ "alpha", "beta", "gamma" };

    for ([_]struct { start: Start, cursor: usize, scroll: usize = 0, current: bool }{
        .{ .start = .{}, .cursor = 0, .current = false },
        .{ .start = .{ .current = 2 }, .cursor = 2, .current = true },
        .{ .start = .{ .preselected = 1 }, .cursor = 1, .current = false },
        .{
            .start = .{ .current = 2, .preselected = 1 },
            .cursor = 1,
            .current = true,
        },
        .{
            .start = .{ .current = 2, .position = .{ .cursor = 1 } },
            .cursor = 1,
            .current = true,
        },
        .{
            .start = .{ .position = .{ .cursor = 1, .scroll = 1 } },
            .cursor = 1,
            .scroll = 1,
            .current = false,
        },
        .{
            .start = .{ .position = .{ .cursor = 99, .scroll = 99 } },
            .cursor = 2,
            .scroll = 2,
            .current = false,
        },
    }) |case| {
        var picker = try testPicker(gpa, &labels, &case.start);
        defer picker.deinit();
        try std.testing.expectEqual(case.cursor, picker.position().cursor);
        try std.testing.expectEqual(case.scroll, picker.position().scroll);
        const size: terminal.View.Size = .{ .columns = 80, .rows = 24 };
        try picker.reflow(size);
        const painted = try renderForTest(gpa, &picker, size);
        defer gpa.free(painted);
        const plain = try terminal.testing.plainText(gpa, painted);
        defer gpa.free(plain);
        if (case.current)
            try testing.expectShows(plain, &.{"gamma (Current)"})
        else
            try testing.expectHides(plain, &.{"(Current)"});
    }

    var empty = try testPicker(gpa, &.{}, &.{ .position = .{ .cursor = 4 } });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.position().cursor);
}

test "the key hint states the step above a later step" {
    const gpa = std.testing.allocator;
    const size: terminal.View.Size = .{ .columns = 60, .rows = 24 };
    var first = try testPicker(gpa, &.{ "alpha", "beta" }, &.{ .current = 0 });
    defer first.deinit();
    try first.reflow(size);
    const first_step = try renderForTest(gpa, &first, size);
    defer gpa.free(first_step);
    try testing.expectShows(first_step, &.{"Esc: Cancel"});

    var later = try testPicker(gpa, &.{ "alpha", "beta" }, &.{
        .current = 0,
        .can_step_back = true,
    });
    defer later.deinit();
    try later.reflow(size);
    const later_step = try renderForTest(gpa, &later, size);
    defer gpa.free(later_step);
    const later_plain = try terminal.testing.plainText(gpa, later_step);
    defer gpa.free(later_plain);
    try std.testing.expect(std.mem.startsWith(
        u8,
        later_plain,
        "Pick · ↑/↓: Move · Enter: Select · Esc: Back\r\n",
    ));
    try testing.expectHides(later_step, &.{"Esc: Cancel"});
}

test "a row too wide for the window is cut and ends in an ellipsis" {
    const gpa = std.testing.allocator;
    var picker = try testPicker(gpa, &.{
        "anthropic-plan/claude-sonnet-5",
        "two\nrows in one option",
    }, &.{ .current = 0 });
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 24, .rows = 24 };

    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 7), picker.rows(size));

    const painted = try renderForTest(gpa, &picker, size);
    defer gpa.free(painted);
    const plain = try terminal.testing.plainText(gpa, painted);
    defer gpa.free(plain);
    try std.testing.expect(
        std.mem.startsWith(u8, plain, "Pick\r\n↑/↓: Move\r\nEnter: Select\r\n─"),
    );
    try testing.expectShows(plain, &.{ " > anthropic-… (Current)", "   two…" });
    try testing.expectHides(plain, &.{"rows in one option"});
    try std.testing.expectEqual(@as(usize, 7), testing.paintedRows(painted));
    for ([_][]const u8{ "↑/↓: Move", "Enter: Select" }) |part|
        try testing.expectShows(painted, &.{part});
    try testing.expectHides(painted, &.{"Esc: Cancel"});

    for ([_]usize{ 24, 8, 3, 1 }) |columns| {
        const narrow: terminal.View.Size = .{ .columns = columns, .rows = 24 };
        try picker.reflow(narrow);
        const narrow_painted = try renderForTest(gpa, &picker, narrow);
        defer gpa.free(narrow_painted);
        const narrow_plain = try terminal.testing.plainText(gpa, narrow_painted);
        defer gpa.free(narrow_plain);
        var lines = std.mem.splitSequence(u8, narrow_plain, "\r\n");
        while (lines.next()) |line|
            try std.testing.expect(terminal.width.ofText(line) <= columns);
    }

    const wide: terminal.View.Size = .{ .columns = 80, .rows = 24 };
    try picker.reflow(wide);
    const whole = try renderForTest(gpa, &picker, wide);
    defer gpa.free(whole);
    try testing.expectShows(whole, &.{ "claude-sonnet-5", "(Current)" });
}

test "a tall option list scrolls the window to keep the selection in view" {
    const gpa = std.testing.allocator;
    var storage: [20][8]u8 = undefined;
    var labels: [20][]const u8 = undefined;
    for (&labels, 0..) |*label, index| {
        label.* = std.fmt.bufPrint(&storage[index], "row{d:0>2}", .{index}) catch unreachable;
    }
    var picker = try testPicker(gpa, &labels, &.{ .current = 0 });
    defer picker.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 20 };

    try picker.reflow(size);
    try std.testing.expectEqual(@as(usize, 0), picker.position().scroll);
    try std.testing.expectEqual(@as(usize, 9), picker.rows(size));

    for (0..19) |_| {
        try picker.moveDown();
        try picker.reflow(size);
    }
    try std.testing.expectEqual(Position{ .cursor = 19, .scroll = 14 }, picker.position());

    const bottom = try renderForTest(gpa, &picker, size);
    defer gpa.free(bottom);
    const selected = comptime role.sequence(.selection) ++ " > row19\x1b[0m";
    try testing.expectShows(bottom, &.{selected});
    try testing.expectHides(bottom, &.{"row00"});
    try testing.expectShows(bottom, &.{"↑ Hidden: 14"});
    try testing.expectShows(bottom, &.{"Pick"});
    try testing.expectShows(bottom, &.{"Esc: Cancel"});

    for (0..19) |_| {
        try picker.moveUp();
        try picker.reflow(size);
    }
    try std.testing.expectEqual(Position{ .cursor = 0, .scroll = 0 }, picker.position());

    const top = try renderForTest(gpa, &picker, size);
    defer gpa.free(top);
    try testing.expectShows(top, &.{"Pick"});
    try testing.expectShows(top, &.{"Esc: Cancel"});
    try testing.expectShows(top, &.{"row00"});
    try testing.expectHides(top, &.{"row19"});
    try testing.expectHides(top, &.{"↑ Hidden"});
    try testing.expectShows(top, &.{"↓ Hidden: 14"});

    try picker.moveUp();
    try picker.reflow(size);
    try std.testing.expectEqual(Position{ .cursor = 19, .scroll = 14 }, picker.position());
}
