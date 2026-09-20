const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const Caption = @import("Caption.zig");
const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

const blank_bytes = " \t\r\n";

fn trimBlank(text: []const u8) []const u8 {
    const first = std.mem.indexOfNone(u8, text, blank_bytes) orelse return text[0..0];
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..first], '\n')) |newline|
        newline + 1
    else
        0;
    return std.mem.trimEnd(u8, text[line_start..], blank_bytes);
}

pub fn isBlank(text: []const u8) bool {
    return std.mem.indexOfNone(u8, text, blank_bytes) == null;
}

pub const Entry = struct {
    content: Content,
    cache: Cache = .{},

    pub const Content = union(enum) {
        intro: std.ArrayList(u8),
        user: std.ArrayList(u8),
        user_note: std.ArrayList(u8),
        thinking: Reasoning,
        model: std.ArrayList(u8),
        tool_result: Flagged,
        event: Flagged,
    };

    pub const Flagged = struct {
        text: std.ArrayList(u8),
        is_error: bool,
        is_warning: bool,
        fit: paint.Fit,
        survives_rewind: bool,
        mirrored: bool,
        repeats: usize = 1,
        base_len: usize,

        fn eventNotice(self: *const Flagged) paint.Notice {
            if (self.is_error) return .{
                .role = .@"error",
                .prefix = paint.warning_prefix,
            };
            if (self.is_warning) return .{
                .role = .warning,
                .prefix = paint.warning_prefix,
            };
            return .{
                .role = .accent,
                .prefix = paint.information_prefix,
            };
        }
    };

    pub const Reasoning = struct {
        text: std.ArrayList(u8),
        account: ?ai.llm.Account,
    };
    pub const Kind = std.meta.Tag(Content);

    pub const Options = struct {
        is_error: bool = false,
        is_warning: bool = false,
        fit: paint.Fit = .head,
        account: ?ai.llm.Account = null,
        survives_rewind: bool = false,
        mirrored: bool = true,
    };

    pub const Cache = struct {
        columns: usize = 0,
        lines: terminal.View.Lines = .empty,
        epoch: ?u64 = null,
        rewritten: bool = false,

        fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
            self.lines.deinit(gpa);
        }

        fn retained(self: *const Cache, columns: usize) ?*const terminal.View.Lines {
            if (self.columns != columns or self.lines.count() == 0) return null;
            return &self.lines;
        }

        fn retain(
            self: *Cache,
            gpa: std.mem.Allocator,
            sink: *const terminal.View.Sink,
            options: struct { columns: usize, first_row: usize },
        ) !void {
            self.columns = options.columns;
            self.lines.clearRetainingCapacity();
            try sink.capture(gpa, options.first_row, &self.lines);
        }

        fn forget(self: *Cache) void {
            self.lines.clearRetainingCapacity();
        }

        fn invalidate(self: *Cache) void {
            self.forget();
            self.rewritten = true;
        }
    };

    pub fn init(
        gpa: std.mem.Allocator,
        kind: Kind,
        options: Options,
        text: []const u8,
    ) !Entry {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, text);
        const flagged: Flagged = .{
            .text = list,
            .is_error = options.is_error,
            .is_warning = options.is_warning,
            .fit = options.fit,
            .survives_rewind = options.survives_rewind,
            .mirrored = options.mirrored,
            .base_len = text.len,
        };
        return .{ .content = switch (kind) {
            .tool_result => .{ .tool_result = flagged },
            .event => .{ .event = flagged },
            .thinking => .{ .thinking = .{ .text = list, .account = options.account } },
            inline else => |tag| @unionInit(Content, @tagName(tag), list),
        } };
    }

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        switch (self.content) {
            .intro, .user, .user_note, .model => |*text| text.deinit(gpa),
            .thinking => |*reasoning| reasoning.text.deinit(gpa),
            .tool_result, .event => |*flagged| flagged.text.deinit(gpa),
        }
        self.cache.deinit(gpa);
    }

    pub fn appendText(self: *Entry, gpa: std.mem.Allocator, delta: []const u8) !void {
        switch (self.content) {
            .model => |*list| try list.appendSlice(gpa, delta),
            .thinking => |*reasoning| try reasoning.text.appendSlice(gpa, delta),
            .intro, .user, .user_note, .tool_result, .event => unreachable,
        }
        self.cache.forget();
    }

    pub fn replaceEvent(
        self: *Entry,
        gpa: std.mem.Allocator,
        options: Options,
        text: []const u8,
    ) !void {
        std.debug.assert(self.content == .event);
        const flagged = &self.content.event;
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, text);
        flagged.text.deinit(gpa);
        flagged.text = list;
        flagged.is_error = options.is_error;
        flagged.is_warning = options.is_warning;
        flagged.fit = options.fit;
        flagged.survives_rewind = options.survives_rewind;
        flagged.mirrored = options.mirrored;
        flagged.repeats = 1;
        flagged.base_len = text.len;
        self.cache.invalidate();
    }

    pub fn release(self: *Entry, gpa: std.mem.Allocator) void {
        self.cache.lines.clear(gpa);
    }

    pub fn takeRewritten(self: *Entry, epoch: u64) bool {
        defer self.cache.rewritten = false;
        return self.cache.rewritten and self.cache.epoch == epoch;
    }

    pub fn stampEpoch(self: *Entry, epoch: u64) void {
        self.cache.epoch = epoch;
    }

    pub fn account(self: *const Entry) ?ai.llm.Account {
        return switch (self.content) {
            .thinking => |reasoning| reasoning.account,
            .intro, .user, .user_note, .model, .tool_result, .event => null,
        };
    }

    pub fn statesEvent(self: *const Entry, options: Options, text: []const u8) bool {
        const flagged = switch (self.content) {
            .event => |*flagged| flagged,
            else => return false,
        };
        if (flagged.is_error != options.is_error) return false;
        if (flagged.is_warning != options.is_warning) return false;
        if (flagged.survives_rewind != options.survives_rewind) return false;
        if (flagged.mirrored != options.mirrored) return false;
        return std.mem.eql(u8, eventText(flagged), text);
    }

    pub fn repeatEvent(self: *Entry, gpa: std.mem.Allocator) !void {
        const flagged = &self.content.event;
        const repeats = flagged.repeats + 1;
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        try text.appendSlice(gpa, eventText(flagged));
        try text.print(gpa, "{s}Repeats: {d}", .{ paint.separator, repeats });
        flagged.text.deinit(gpa);
        flagged.text = text;
        flagged.repeats = repeats;
        self.cache.invalidate();
    }

    fn eventText(flagged: *const Flagged) []const u8 {
        return flagged.text.items[0..flagged.base_len];
    }

    pub fn survivesRewind(self: *const Entry) bool {
        return switch (self.content) {
            .event => |event| event.survives_rewind,
            .intro, .user, .user_note, .thinking, .model, .tool_result => false,
        };
    }

    fn bytes(self: *const Entry) []const u8 {
        return switch (self.content) {
            .intro, .user, .user_note, .model => |list| list.items,
            .thinking => |reasoning| reasoning.text.items,
            .tool_result, .event => |flagged| flagged.text.items,
        };
    }

    fn notice(self: *const Entry) ?paint.Notice {
        return switch (self.content) {
            .user_note => .{ .role = .user_note, .prefix = paint.note_prefix },
            .event => |*flagged| flagged.eventNotice(),
            .intro, .user, .tool_result, .thinking, .model => null,
        };
    }

    fn introCaption(legend: []const u8) Caption {
        return .{ .title = "Drinky", .controls = legend };
    }

    fn boxRole(self: *const Entry) ?role.Name {
        return switch (self.content) {
            .user => .user,
            .tool_result => |flagged| if (flagged.is_error) .tool_error else .tool_success,
            .intro, .user_note, .thinking, .model, .event => null,
        };
    }

    pub fn rows(self: *const Entry, columns: usize) usize {
        if (self.cache.retained(columns)) |lines| return lines.count();
        return self.measure(columns);
    }

    fn measure(self: *const Entry, columns: usize) usize {
        if (self.notice()) |look| return paint.noticeRows(&look, self.bytes(), columns);
        return switch (self.content) {
            .intro => |list| introCaption(list.items).rows(columns),
            .user => |list| paint.boxRows(&.{ .text = list.items }, columns),
            .tool_result => |flagged| paint.boxRows(
                &.{ .text = flagged.text.items, .fit = flagged.fit },
                columns,
            ),
            .thinking => |reasoning| markdown.rows(trimBlank(reasoning.text.items), columns),
            .model => |list| markdown.rows(trimBlank(list.items), columns),
            .user_note, .event => unreachable,
        };
    }

    pub fn render(
        self: *Entry,
        gpa: std.mem.Allocator,
        placement: *const paint.Placement,
    ) !void {
        if (self.cache.retained(placement.columns)) |lines| return replay(placement, lines);
        const first_row = placement.sink.composed();
        try self.compose(placement);
        self.cache.rewritten = false;
        if (placement.skip > 0) return;
        self.cache.retain(gpa, placement.sink, .{
            .columns = placement.columns,
            .first_row = first_row,
        }) catch self.cache.forget();
    }

    fn replay(placement: *const paint.Placement, lines: *const terminal.View.Lines) !void {
        for (0..lines.count()) |index| {
            const line = placement.base + index;
            if (line < placement.skip) continue;
            placement.sink.begin();
            try placement.sink.replay(lines, index);
            placement.sink.end(.{ .id = placement.id, .line = line });
        }
    }

    fn compose(self: *const Entry, placement: *const paint.Placement) !void {
        if (self.notice()) |look| return paint.notice(placement, &look, self.bytes());
        const box = self.boxRole();
        switch (self.content) {
            .user_note, .event => unreachable,
            .intro => |list| _ = try introCaption(list.items).render(placement),
            .user => |list| try paint.box(placement, box.?, &.{ .text = list.items }),
            .tool_result => |flagged| try paint.box(
                placement,
                box.?,
                &.{
                    .text = flagged.text.items,
                    .fit = flagged.fit,
                    .emphasis = .first_value,
                },
            ),
            .thinking => |reasoning| try markdown.render(
                placement,
                .muted,
                trimBlank(reasoning.text.items),
            ),
            .model => |list| try markdown.render(placement, null, trimBlank(list.items)),
        }
    }
};

pub fn paintedRows(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\r\n") + 1;
}

pub fn numberedLines(gpa: std.mem.Allocator, count: usize) !std.ArrayList(u8) {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (0..count) |i| {
        if (i > 0) try text.append(gpa, '\n');
        var buffer: [8]u8 = undefined;
        try text.appendSlice(gpa, std.fmt.bufPrint(&buffer, "L{d}", .{i}) catch unreachable);
    }
    return text;
}

const markdown_reply =
    \\## Findings
    \\- one bullet with words enough to wrap
    \\  - a nested bullet
    \\
    \\> quoted
    \\
    \\```zig
    \\const answer = 42;
    \\```
    \\
    \\That is **it**.
;

fn rendered(gpa: std.mem.Allocator, entry: *Entry, columns: usize, skip: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 100 }, 8);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = skip,
    };
    try entry.render(gpa, &placement);
    try view.render();
    return gpa.dupe(u8, out.written());
}

fn renderedRows(gpa: std.mem.Allocator, entry: *Entry, columns: usize, skip: usize) !usize {
    const painted = try rendered(gpa, entry, columns, skip);
    defer gpa.free(painted);
    return paintedRows(painted);
}

test "each entry variant renders exactly the rows it counts" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { kind: Entry.Kind, options: Entry.Options, text: []const u8 }{
        .{ .kind = .intro, .options = .{}, .text = "a single intro line" },
        .{ .kind = .event, .options = .{}, .text = "first\nsecond\nthird" },
        .{ .kind = .event, .options = .{ .is_error = true }, .text = "boom" },
        .{ .kind = .user, .options = .{}, .text = "a user message long enough to wrap " ++
            "across the narrow test width more than once" },
        .{ .kind = .user_note, .options = .{}, .text = "Skill: zig-style · File: " ++
            ".agents/skills/zig-style/SKILL.md" },
        .{ .kind = .model, .options = .{}, .text = "model reply\nwith a blank\n\n" ++
            "then a long paragraph that must wrap several rows" },
        .{ .kind = .thinking, .options = .{}, .text = "reasoning that runs on\n\n" ++
            "long enough to wrap across the narrow test width more than once" },
        .{ .kind = .model, .options = .{}, .text = markdown_reply },
        .{ .kind = .thinking, .options = .{}, .text = markdown_reply },
        .{
            .kind = .tool_result,
            .options = .{ .is_error = true, .fit = .wrap },
            .text = "read foo.zig\n→ no such file",
        },
        .{
            .kind = .tool_result,
            .options = .{ .is_error = true },
            .text = "Tool: bash · Command: ls\nTime: 400ms · Exit code: 1",
        },
        .{ .kind = .tool_result, .options = .{}, .text = "Tool: describe_drinky" },
        .{ .kind = .user, .options = .{}, .text = "你好世界" },
    };
    const widths = [_]usize{ 16, 3, 2 };
    for (cases) |case| {
        var entry = try Entry.init(gpa, case.kind, case.options, case.text);
        defer entry.deinit(gpa);
        for (widths) |columns| {
            const counted = entry.rows(columns);
            try std.testing.expectEqual(counted, try renderedRows(gpa, &entry, columns, 0));
        }
    }
}

test "a streamed block drops the blank rows it ends on" {
    const gpa = std.testing.allocator;
    const columns = 20;
    for ([_]Entry.Kind{ .model, .thinking }) |kind| {
        var trailing = try Entry.init(gpa, kind, .{}, "the answer\n\n  \n");
        defer trailing.deinit(gpa);
        var tight = try Entry.init(gpa, kind, .{}, "the answer");
        defer tight.deinit(gpa);

        try std.testing.expectEqual(tight.rows(columns), trailing.rows(columns));
        const trailing_paint = try rendered(gpa, &trailing, columns, 0);
        defer gpa.free(trailing_paint);
        const tight_paint = try rendered(gpa, &tight, columns, 0);
        defer gpa.free(tight_paint);
        try std.testing.expectEqualStrings(tight_paint, trailing_paint);
    }

    var blanks_only = try Entry.init(gpa, .model, .{}, "\n\n");
    defer blanks_only.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), blanks_only.rows(columns));
    try std.testing.expectEqual(@as(usize, 1), try renderedRows(gpa, &blanks_only, columns, 0));
}

test "a streamed block drops the blank rows it starts on" {
    const gpa = std.testing.allocator;
    const columns = 20;
    for ([_]Entry.Kind{ .model, .thinking }) |kind| {
        var leading = try Entry.init(gpa, kind, .{}, "\n\n  \nthe answer");
        defer leading.deinit(gpa);
        var tight = try Entry.init(gpa, kind, .{}, "the answer");
        defer tight.deinit(gpa);

        try std.testing.expectEqual(tight.rows(columns), leading.rows(columns));
        const leading_paint = try rendered(gpa, &leading, columns, 0);
        defer gpa.free(leading_paint);
        const tight_paint = try rendered(gpa, &tight, columns, 0);
        defer gpa.free(tight_paint);
        try std.testing.expectEqualStrings(tight_paint, leading_paint);
    }
}

test trimBlank {
    try std.testing.expectEqualStrings("the answer", trimBlank("\n\n  \nthe answer\n\n  \n"));
    try std.testing.expectEqualStrings("    code", trimBlank("\n \n    code"));
    try std.testing.expectEqualStrings("  a\n  b", trimBlank("  a\n  b  "));
    try std.testing.expectEqualStrings("", trimBlank("\n\n  \n"));
    try std.testing.expectEqualStrings("", trimBlank(""));
}

test "no box carries a pad, so a copy of the rows lines up" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    var user = try Entry.init(gpa, .user, .{}, "a user message that wraps over two rows");
    defer user.deinit(gpa);
    var thinking = try Entry.init(gpa, .thinking, .{}, "reasoning that wraps over two rows");
    defer thinking.deinit(gpa);

    const columns = 20;
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 24 }, 8);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    };
    var second = placement;
    second.id = 1;
    second.base = user.rows(columns);
    try user.render(gpa, &placement);
    try thinking.render(gpa, &second);
    try view.render();

    const painted = out.written();
    try expectRowOpensOnText(painted, "a user message that");
    try expectRowOpensOnText(painted, "reasoning that wraps");
}

test "a tool box wraps a sentence and cuts a line of measures" {
    const gpa = std.testing.allocator;
    const columns = 20;
    const head = "Tool: edit · File: a.zig";
    const detail = "Error: Drinky found old_text more than once. Add more text around it.";
    const text = head ++ "\n" ++ detail;

    var wrapped = try Entry.init(gpa, .tool_result, .{ .is_error = true, .fit = .wrap }, text);
    defer wrapped.deinit(gpa);
    var cut = try Entry.init(gpa, .tool_result, .{ .is_error = true }, text);
    defer cut.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), cut.rows(columns));
    try std.testing.expect(wrapped.rows(columns) > cut.rows(columns));

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 24 }, 8);
    try wrapped.render(gpa, &.{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    });
    try view.render();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "around it.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\u{2026}") == null);
}

fn expectRowOpensOnText(painted: []const u8, row: []const u8) !void {
    const start = std.mem.indexOf(u8, painted, row) orelse return error.TestExpectedRow;
    const break_end = if (std.mem.lastIndexOf(u8, painted[0..start], "\r\n")) |cut|
        cut + 2
    else
        0;
    try std.testing.expect(start > break_end);
    try std.testing.expect(std.mem.indexOfScalar(u8, painted[break_end..start], ' ') == null);
}

test "a clipped block shows its bottom rows" {
    const gpa = std.testing.allocator;
    var text = try numberedLines(gpa, 40);
    defer text.deinit(gpa);
    var entry: Entry = .{ .content = .{ .model = text } };
    defer entry.cache.deinit(gpa);
    const columns = 20;
    try std.testing.expectEqual(@as(usize, 40), entry.rows(columns));
    try std.testing.expectEqual(@as(usize, 15), try renderedRows(gpa, &entry, columns, 25));
}

test "a block replays its rows until its text or its width changes" {
    const gpa = std.testing.allocator;
    var entry = try Entry.init(gpa, .model, .{}, markdown_reply);
    defer entry.deinit(gpa);

    const columns = 24;
    const first = try rendered(gpa, &entry, columns, 0);
    defer gpa.free(first);
    try std.testing.expectEqual(entry.cache.lines.count(), entry.rows(columns));
    try std.testing.expect(entry.cache.lines.count() > 0);

    const replayed = try rendered(gpa, &entry, columns, 0);
    defer gpa.free(replayed);
    try std.testing.expectEqualStrings(first, replayed);

    const narrow = try rendered(gpa, &entry, 16, 0);
    defer gpa.free(narrow);
    try std.testing.expect(!std.mem.eql(u8, first, narrow));
    try std.testing.expectEqual(@as(usize, 16), entry.cache.columns);

    try entry.appendText(gpa, "\n\nEpilogue\n");
    try std.testing.expectEqual(@as(usize, 0), entry.cache.lines.count());
    const grown = try rendered(gpa, &entry, 16, 0);
    defer gpa.free(grown);
    try std.testing.expect(std.mem.indexOf(u8, grown, "Epilogue") != null);
    try std.testing.expectEqual(entry.cache.lines.count(), entry.rows(16));
}

test "a replayed block drops the rows that the clip hides" {
    const gpa = std.testing.allocator;
    var text = try numberedLines(gpa, 40);
    defer text.deinit(gpa);
    const columns = 20;

    var fresh: Entry = .{ .content = .{ .model = text } };
    defer fresh.cache.deinit(gpa);
    const composed = try rendered(gpa, &fresh, columns, 25);
    defer gpa.free(composed);
    try std.testing.expectEqual(@as(usize, 0), fresh.cache.lines.count());

    var kept: Entry = .{ .content = .{ .model = text } };
    defer kept.cache.deinit(gpa);
    gpa.free(try rendered(gpa, &kept, columns, 0));
    const clipped = try rendered(gpa, &kept, columns, 25);
    defer gpa.free(clipped);
    try std.testing.expectEqualStrings(composed, clipped);
}

const Pinned = struct {
    kind: Entry.Kind,
    options: Entry.Options = .{},
    notice: ?role.Name = null,
    box: ?role.Name = null,
    caption: bool = false,
};

test "each block kind pins the role that it paints" {
    const gpa = std.testing.allocator;
    const pinned = [_]Pinned{
        .{ .kind = .intro, .caption = true },
        .{ .kind = .user_note, .notice = .user_note },
        .{ .kind = .event, .notice = .accent },
        .{ .kind = .event, .options = .{ .is_warning = true }, .notice = .warning },
        .{ .kind = .event, .options = .{ .is_error = true }, .notice = .@"error" },
        .{ .kind = .user, .box = .user },
        .{ .kind = .tool_result, .box = .tool_success },
        .{ .kind = .tool_result, .options = .{ .is_error = true }, .box = .tool_error },
        .{ .kind = .thinking },
        .{ .kind = .model },
    };
    var seen: std.EnumSet(Entry.Kind) = .initEmpty();
    for (pinned) |pin| {
        var entry = try Entry.init(gpa, pin.kind, pin.options, "one line");
        defer entry.deinit(gpa);
        const look = entry.notice();
        if (pin.notice) |name| {
            try std.testing.expectEqual(name, look.?.role);
        } else {
            try std.testing.expect(look == null);
        }
        try std.testing.expectEqual(pin.box, entry.boxRole());
        if (pin.caption) try std.testing.expect(pin.kind == .intro);
        seen.insert(pin.kind);
    }
    try std.testing.expectEqual(std.enums.values(Entry.Kind).len, seen.count());
}

test "the intro block paints the Drinky caption" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    var intro = try Entry.init(gpa, .intro, .{}, "Enter: Send · Ctrl+D: Quit");
    defer intro.deinit(gpa);

    const columns = 60;
    try std.testing.expectEqual(@as(usize, 1), intro.rows(columns));
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 24 }, 8);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    };
    try intro.render(gpa, &placement);
    try view.render();

    const painted = out.written();
    const title = comptime role.sequence(.accent) ++ "Drinky\x1b[0m";
    const legend = comptime role.sequence(.muted) ++ " · Enter: Send";
    try std.testing.expect(std.mem.indexOf(u8, painted, title) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[1m") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, legend) != null);

    try std.testing.expectEqual(@as(usize, 3), intro.rows(14));
}

test "each notice paints the symbol of its kind in its role" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    var failure = try Entry.init(gpa, .event, .{ .is_error = true }, "boom");
    defer failure.deinit(gpa);
    var warning = try Entry.init(gpa, .event, .{ .is_warning = true }, "pass this state");
    defer warning.deinit(gpa);
    var information = try Entry.init(gpa, .event, .{}, "all good");
    defer information.deinit(gpa);
    var note = try Entry.init(gpa, .user_note, .{}, "Skill: zig-style");
    defer note.deinit(gpa);

    const sink = try view.beginFrame(.{ .columns = 40, .rows = 100 }, 8);
    var placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 40,
        .base = 0,
        .skip = 0,
    };
    try failure.render(gpa, &placement);
    placement.id = 1;
    placement.base = 1;
    try warning.render(gpa, &placement);
    placement.id = 2;
    placement.base = 2;
    try information.render(gpa, &placement);
    placement.id = 3;
    placement.base = 3;
    try note.render(gpa, &placement);
    try view.render();

    const painted = out.written();
    const accent_sequence = comptime role.sequence(.accent);
    const warning_sequence = comptime role.sequence(.warning);
    const error_sequence = comptime role.sequence(.@"error");
    const note_sequence = comptime role.sequence(.user_note);
    try std.testing.expect(std.mem.indexOf(u8, painted, accent_sequence ++ "ℹ all good") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, warning_sequence ++ "⚠ pass this state") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, error_sequence ++ "⚠ boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, note_sequence ++ "→ Skill: zig-style") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, "ℹ "));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, painted, "⚠ "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, "→ "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, error_sequence));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, warning_sequence));
    try std.testing.expect(std.mem.indexOf(u8, painted, "Event: ") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Error: ") == null);
}

test "a repeated event states one count and matches its own text" {
    const gpa = std.testing.allocator;
    var entry = try Entry.init(gpa, .event, .{ .is_error = true }, "no route to host");
    defer entry.deinit(gpa);

    try std.testing.expect(entry.statesEvent(.{ .is_error = true }, "no route to host"));
    try std.testing.expect(!entry.statesEvent(.{ .is_error = true, .mirrored = false }, "no route to host"));
    try std.testing.expect(!entry.statesEvent(.{ .is_error = true, .is_warning = true }, "no route to host"));
    try std.testing.expect(!entry.statesEvent(.{ .is_error = true, .survives_rewind = true }, "no route to host"));
    try std.testing.expect(!entry.statesEvent(.{}, "no route to host"));
    try std.testing.expect(!entry.statesEvent(.{ .is_error = true }, "other"));

    for (0..9) |_| try entry.repeatEvent(gpa);
    try std.testing.expectEqualStrings(
        "no route to host · Repeats: 10",
        entry.content.event.text.items,
    );
    try std.testing.expectEqual(@as(usize, 10), entry.content.event.repeats);
    try std.testing.expect(entry.statesEvent(.{ .is_error = true }, "no route to host"));
}

test "a clipped block streams into a warmed frame without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    var text = try numberedLines(std.testing.allocator, 60);
    defer text.deinit(std.testing.allocator);
    try text.append(std.testing.allocator, '\n');
    try text.appendSlice(std.testing.allocator, markdown_reply);
    var entry: Entry = .{ .content = .{ .model = text } };
    defer entry.cache.deinit(gpa);
    const columns = 20;

    for (0..2) |_| {
        const sink = try view.beginFrame(.{ .columns = columns, .rows = 100 }, 8);
        const placement: paint.Placement = .{
            .sink = sink,
            .id = 0,
            .columns = columns,
            .base = 0,
            .skip = 0,
        };
        try entry.render(gpa, &placement);
        try view.render();
    }
    entry.release(gpa);
    out.clearRetainingCapacity();

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    const sink = try view.beginFrame(.{ .columns = columns, .rows = 100 }, 8);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 30,
    };
    try entry.render(gpa, &placement);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "L30") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "const answer = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L29") == null);
}
