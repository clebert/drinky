const std = @import("std");

const terminal = @import("terminal");

const format = @import("../format.zig");
const Message = @import("../Message.zig");

const Caption = @import("Caption.zig");
const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

const Block = @This();

content: Content,
cache: Cache = .{},
mode: Mode = .full,
thinking: ?Thinking = null,

pub const Mode = enum { full, compact };

pub const Thinking = struct {
    started_ms: i64 = 0,
    ended_ms: ?i64 = 0,
    joins_previous: bool = false,
    status: Status = .complete,
    hidden: bool = false,
    summary: [128]u8 = undefined,
    summary_length: usize = 0,
    summary_status: Status = .complete,

    pub const Status = enum { streaming, complete, canceled, failed, truncated };

    pub const Summary = struct {
        bytes: usize,
        elapsed_ms: i64,
        status: Status,
    };

    pub fn elapsed(self: *const Thinking, now_ms: i64) i64 {
        return @max((self.ended_ms orelse now_ms) - self.started_ms, 0);
    }
};

const Content = union(enum) {
    intro: std.ArrayList(u8),
    user: std.ArrayList(u8),
    user_note: std.ArrayList(u8),
    thinking: std.ArrayList(u8),
    model: std.ArrayList(u8),
    tool_result: ToolResult,
    event: Event,
};

pub const Kind = std.meta.Tag(Content);

pub const Source = union(Kind) {
    intro: []const u8,
    user: []const u8,
    user_note: []const u8,
    thinking: []const u8,
    model: []const u8,
    tool_result: ToolResult.Payload,
    event: Event.Payload,
};

const ToolResult = struct {
    text: std.ArrayList(u8),
    failed: bool,
    fit: paint.Fit,
    survives_discard: bool = false,

    const Payload = struct {
        text: []const u8,
        failed: bool = false,
        fit: paint.Fit = .head,
    };
};

pub const Event = struct {
    text: std.ArrayList(u8),
    severity: Message.Severity,
    survives_discard: bool,

    pub const Payload = struct {
        text: []const u8,
        severity: Message.Severity = .information,
        survives_discard: bool = false,
    };

    fn init(gpa: std.mem.Allocator, payload: *const Payload) !Event {
        return .{
            .text = try copy(gpa, payload.text),
            .severity = payload.severity,
            .survives_discard = payload.survives_discard,
        };
    }
};

const Look = union(enum) {
    caption: Caption,
    box: struct { role: role.Name, body: paint.Box },
    notice: struct { style: paint.NoticeStyle, text: []const u8 },
    markdown: struct { role: ?role.Name, text: []const u8 },
};

const Cache = struct {
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

pub fn init(gpa: std.mem.Allocator, source: *const Source) !Block {
    return .{ .thinking = if (source.* == .thinking) .{} else null, .content = switch (source.*) {
        .tool_result => |*result| .{ .tool_result = .{
            .text = try copy(gpa, result.text),
            .failed = result.failed,
            .fit = result.fit,
        } },
        .event => |*event| .{ .event = try Event.init(gpa, event) },
        inline else => |text, tag| @unionInit(Content, @tagName(tag), try copy(gpa, text)),
    } };
}

fn copy(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(gpa, text);
    return list;
}

pub fn deinit(self: *Block, gpa: std.mem.Allocator) void {
    switch (self.content) {
        .intro, .user, .user_note, .thinking, .model => |*text| text.deinit(gpa),
        .tool_result => |*result| result.text.deinit(gpa),
        .event => |*event| event.text.deinit(gpa),
    }
    self.cache.deinit(gpa);
}

pub fn appendText(self: *Block, gpa: std.mem.Allocator, delta: []const u8) !void {
    switch (self.content) {
        .thinking, .model => |*list| try list.appendSlice(gpa, delta),
        .intro, .user, .user_note, .tool_result, .event => unreachable,
    }
    self.cache.forget();
}

pub fn replaceEvent(
    self: *Block,
    gpa: std.mem.Allocator,
    payload: *const Event.Payload,
) !void {
    const event = try Event.init(gpa, payload);
    self.content.event.text.deinit(gpa);
    self.content.event = event;
    self.cache.invalidate();
}

pub fn release(self: *Block, gpa: std.mem.Allocator) void {
    self.cache.lines.clear(gpa);
}

pub fn takeRewritten(self: *Block, epoch: u64) bool {
    defer self.cache.rewritten = false;
    return self.cache.rewritten and self.cache.epoch == epoch;
}

pub fn stampEpoch(self: *Block, epoch: u64) void {
    self.cache.epoch = epoch;
}

pub fn survivesDiscard(self: *const Block) bool {
    return switch (self.content) {
        .event => |*event| event.survives_discard,
        .tool_result => |*result| result.survives_discard,
        .intro, .user, .user_note, .thinking, .model => false,
    };
}

pub fn present(self: *Block, mode: Mode) void {
    if (self.mode == mode) return;
    self.mode = mode;
    self.cache.forget();
}

pub fn presentThinking(self: *Block, maybe_summary: ?*const Thinking.Summary) void {
    const thinking = &self.thinking.?;
    const hidden = maybe_summary == null;
    if (hidden != thinking.hidden) self.cache.invalidate();
    thinking.hidden = hidden;
    const summary = maybe_summary orelse return;
    thinking.summary_status = summary.status;
    var bytes_buffer: [16]u8 = undefined;
    var time_buffer: [24]u8 = undefined;
    var buffer: [128]u8 = undefined;
    const text = std.mem.print(&buffer, "Thinking: {s}\nReceived: {s} · Time: {s}", .{
        @tagName(summary.status),
        format.bytes(&bytes_buffer, summary.bytes),
        format.durationSeconds(&time_buffer, summary.elapsed_ms, .down),
    }) catch unreachable;
    if (std.mem.eql(u8, thinking.summary[0..thinking.summary_length], text)) return;
    @memcpy(thinking.summary[0..text.len], text);
    thinking.summary_length = text.len;
    self.cache.invalidate();
}

fn look(self: *const Block) Look {
    const compact = self.mode == .compact;
    return switch (self.content) {
        .intro => |list| .{ .caption = .{ .title = "Drinky", .controls = list.items } },
        .user => |list| .{ .box = .{
            .role = .user,
            .body = .{ .text = list.items, .compact = compact },
        } },
        .user_note => |list| .{ .notice = .{ .style = .note, .text = list.items } },
        .thinking => |list| if (compact) .{ .box = .{
            .role = switch (self.thinking.?.summary_status) {
                .streaming, .canceled => .tool_pending,
                .complete => .tool_success,
                .failed, .truncated => .tool_error,
            },
            .body = .{
                .text = self.thinking.?.summary[0..self.thinking.?.summary_length],
                .fit = .head,
                .compact = true,
                .emphasis = .first_value,
            },
        } } else .{ .markdown = .{ .role = .muted, .text = trimBlank(list.items) } },
        .model => |list| .{ .markdown = .{ .role = null, .text = trimBlank(list.items) } },
        .tool_result => |*result| .{ .box = .{
            .role = if (result.failed) .tool_error else .tool_success,
            .body = .{
                .text = result.text.items,
                .fit = result.fit,
                .emphasis = .first_value,
                .compact = compact,
            },
        } },
        .event => |*event| .{ .notice = .{
            .style = .of(event.severity),
            .text = event.text.items,
        } },
    };
}

fn isHidden(self: *const Block) bool {
    if (self.thinking == null) return false;
    return switch (self.mode) {
        .full => paint.isBlank(self.content.thinking.items),
        .compact => self.thinking.?.hidden,
    };
}

pub fn rows(self: *const Block, columns: usize) usize {
    if (self.isHidden()) return 0;
    if (self.cache.retained(columns)) |lines| return lines.count();
    return switch (self.look()) {
        .caption => |caption| caption.rows(columns),
        .box => |*shown| paint.boxRows(&shown.body, columns),
        .notice => |*shown| paint.noticeRows(&shown.style, shown.text, columns),
        .markdown => |shown| markdown.rows(shown.text, columns),
    };
}

pub fn render(
    self: *Block,
    gpa: std.mem.Allocator,
    placement: *const paint.Placement,
) !void {
    if (self.isHidden()) {
        self.cache.rewritten = false;
        return;
    }
    if (self.cache.retained(placement.columns)) |lines| return replay(placement, lines);
    const first_row = placement.sink.composed();
    switch (self.look()) {
        .caption => |caption| _ = try caption.render(placement),
        .box => |*shown| try paint.box(placement, shown.role, &shown.body),
        .notice => |*shown| try paint.notice(placement, &shown.style, shown.text),
        .markdown => |shown| try markdown.render(placement, shown.role, shown.text),
    }
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
        if (!placement.begin(line)) continue;
        try placement.sink.replay(lines, index);
        placement.end(line);
    }
}

fn trimBlank(text: []const u8) []const u8 {
    const first = std.mem.findNone(u8, text, paint.blank_bytes) orelse return text[0..0];
    const line_start = if (std.mem.findScalarLast(u8, text[0..first], '\n')) |newline|
        newline + 1
    else
        0;
    return std.mem.trimEnd(u8, text[line_start..], paint.blank_bytes);
}

test "each block variant renders exactly the rows it counts" {
    const gpa = std.testing.allocator;
    const cases = [_]Block.Source{
        .{ .intro = "a single intro line" },
        .{ .event = .{ .text = "first\nsecond\nthird" } },
        .{ .event = .{ .text = "boom", .severity = .failure } },
        .{ .user = "a user message long enough to wrap across the narrow test width more " ++
            "than once" },
        .{ .user_note = "Skill: zig-style · File: .agents/skills/zig-style/SKILL.md" },
        .{ .model = "model reply\nwith a blank\n\nthen a long paragraph that must wrap " ++
            "several rows" },
        .{ .thinking = "reasoning that runs on\n\nlong enough to wrap across the narrow " ++
            "test width more than once" },
        .{ .model = markdown_reply },
        .{ .thinking = markdown_reply },
        .{ .tool_result = .{
            .text = "read foo.zig\n→ no such file",
            .failed = true,
            .fit = .wrap,
        } },
        .{ .tool_result = .{
            .text = "Tool: bash · Command: ls\nTime: 400ms · Exit code: 1",
            .failed = true,
        } },
        .{ .tool_result = .{ .text = "Tool: describe_drinky" } },
        .{ .user = "你好世界" },
    };
    const widths = [_]usize{ 16, 3, 2 };
    for (&cases) |*case| {
        var block = try Block.init(gpa, case);
        defer block.deinit(gpa);
        for (widths) |columns| {
            const counted = block.rows(columns);
            try std.testing.expectEqual(counted, try renderedRows(gpa, &block, columns, 0));
        }
    }
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

fn rendered(gpa: std.mem.Allocator, block: *Block, columns: usize, skip: usize) ![]u8 {
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{
        .columns = columns,
        .rows = 100,
        .pages = 8,
        .skip = skip,
    });
    try block.render(gpa, &placement);
    return gpa.dupe(u8, try rig.painted());
}

fn renderedRows(gpa: std.mem.Allocator, block: *Block, columns: usize, skip: usize) !usize {
    const painted = try rendered(gpa, block, columns, skip);
    defer gpa.free(painted);
    return testing.paintedRows(painted);
}

test "a streamed block drops the blank rows it ends on" {
    const gpa = std.testing.allocator;
    const columns = 20;
    const payloads = [_][2]Block.Source{
        .{ .{ .model = "the answer\n\n  \n" }, .{ .model = "the answer" } },
        .{ .{ .thinking = "the answer\n\n  \n" }, .{ .thinking = "the answer" } },
    };
    for (&payloads) |*pair| {
        var trailing = try Block.init(gpa, &pair[0]);
        defer trailing.deinit(gpa);
        var tight = try Block.init(gpa, &pair[1]);
        defer tight.deinit(gpa);

        try std.testing.expectEqual(tight.rows(columns), trailing.rows(columns));
        const trailing_paint = try rendered(gpa, &trailing, columns, 0);
        defer gpa.free(trailing_paint);
        const tight_paint = try rendered(gpa, &tight, columns, 0);
        defer gpa.free(tight_paint);
        try std.testing.expectEqualStrings(tight_paint, trailing_paint);
    }

    var blanks_only = try Block.init(gpa, &.{ .model = "\n\n" });
    defer blanks_only.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), blanks_only.rows(columns));
    try std.testing.expectEqual(@as(usize, 1), try renderedRows(gpa, &blanks_only, columns, 0));
}

test "a streamed block drops the blank rows it starts on" {
    const gpa = std.testing.allocator;
    const columns = 20;
    const payloads = [_][2]Block.Source{
        .{ .{ .model = "\n\n  \nthe answer" }, .{ .model = "the answer" } },
        .{ .{ .thinking = "\n\n  \nthe answer" }, .{ .thinking = "the answer" } },
    };
    for (&payloads) |*pair| {
        var leading = try Block.init(gpa, &pair[0]);
        defer leading.deinit(gpa);
        var tight = try Block.init(gpa, &pair[1]);
        defer tight.deinit(gpa);

        try std.testing.expectEqual(tight.rows(columns), leading.rows(columns));
        const leading_paint = try rendered(gpa, &leading, columns, 0);
        defer gpa.free(leading_paint);
        const tight_paint = try rendered(gpa, &tight, columns, 0);
        defer gpa.free(tight_paint);
        try std.testing.expectEqualStrings(tight_paint, leading_paint);
    }
}

test "a streamed block keeps the indentation of the first line it shows" {
    const gpa = std.testing.allocator;
    var block = try Block.init(gpa, &.{ .model = "\n \n  - nested item\n\n" });
    defer block.deinit(gpa);
    const painted = try rendered(gpa, &block, 40, 0);
    defer gpa.free(painted);
    const plain = try terminal.testing.plainText(gpa, painted);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("    - nested item", plain);
}

test "no box carries a pad, so a copy of the rows lines up" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    var user = try Block.init(gpa, &.{ .user = "a user message that wraps over two rows" });
    defer user.deinit(gpa);
    var thinking = try Block.init(gpa, &.{ .thinking = "reasoning that wraps over two rows" });
    defer thinking.deinit(gpa);

    const columns = 20;
    const placement = try rig.begin(&.{ .columns = columns, .rows = 24, .pages = 8 });
    var second = placement;
    second.id = 1;
    second.base = user.rows(columns);
    try user.render(gpa, &placement);
    try thinking.render(gpa, &second);

    const painted = try rig.painted();
    try expectRowOpensOnText(painted, "a user message that");
    try expectRowOpensOnText(painted, "reasoning that wraps");
}

test "a tool box wraps a sentence and cuts a line of measures" {
    const gpa = std.testing.allocator;
    const columns = 20;
    const head = "Tool: edit · File: a.zig";
    const detail = "Error: Drinky found old_text more than once. Add more text around it.";
    const text = head ++ "\n" ++ detail;

    var wrapped = try Block.init(gpa, &.{ .tool_result = .{
        .text = text,
        .failed = true,
        .fit = .wrap,
    } });
    defer wrapped.deinit(gpa);
    var cut = try Block.init(gpa, &.{ .tool_result = .{ .text = text, .failed = true } });
    defer cut.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), cut.rows(columns));
    try std.testing.expect(wrapped.rows(columns) > cut.rows(columns));

    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = columns, .rows = 24, .pages = 8 });
    try wrapped.render(gpa, &placement);
    try testing.expectShows(try rig.painted(), &.{"around it."});
    try testing.expectHides(try rig.painted(), &.{"\u{2026}"});
}

fn expectRowOpensOnText(painted: []const u8, row: []const u8) !void {
    const start = std.mem.find(u8, painted, row) orelse return error.TestExpectedRow;
    const break_end = if (std.mem.findLast(u8, painted[0..start], "\r\n")) |cut|
        cut + 2
    else
        0;
    try std.testing.expect(start > break_end);
    try std.testing.expect(std.mem.findScalar(u8, painted[break_end..start], ' ') == null);
}

test "a clipped block shows its bottom rows" {
    const gpa = std.testing.allocator;
    var text = try testing.numberedLines(gpa, 40);
    defer text.deinit(gpa);
    var block = try Block.init(gpa, &.{ .model = text.items });
    defer block.deinit(gpa);
    const columns = 20;
    try std.testing.expectEqual(@as(usize, 40), block.rows(columns));
    try std.testing.expectEqual(@as(usize, 15), try renderedRows(gpa, &block, columns, 25));
}

test "a block replays its rows until its text or its width changes" {
    const gpa = std.testing.allocator;
    var block = try Block.init(gpa, &.{ .model = markdown_reply });
    defer block.deinit(gpa);

    const columns = 24;
    const first = try rendered(gpa, &block, columns, 0);
    defer gpa.free(first);
    try std.testing.expectEqual(testing.paintedRows(first), block.rows(columns));

    const replayed = try rendered(gpa, &block, columns, 0);
    defer gpa.free(replayed);
    try std.testing.expectEqualStrings(first, replayed);

    const narrow = try rendered(gpa, &block, 16, 0);
    defer gpa.free(narrow);
    try std.testing.expect(!std.mem.eql(u8, first, narrow));
    try std.testing.expectEqual(testing.paintedRows(narrow), block.rows(16));

    try block.appendText(gpa, "\n\nEpilogue\n");
    const grown = try rendered(gpa, &block, 16, 0);
    defer gpa.free(grown);
    try testing.expectShows(grown, &.{"Epilogue"});
    try std.testing.expectEqual(testing.paintedRows(grown), block.rows(16));
}

test "a replayed block drops the rows that the clip hides" {
    const gpa = std.testing.allocator;
    var text = try testing.numberedLines(gpa, 40);
    defer text.deinit(gpa);
    const columns = 20;

    var fresh = try Block.init(gpa, &.{ .model = text.items });
    defer fresh.deinit(gpa);
    const composed = try rendered(gpa, &fresh, columns, 25);
    defer gpa.free(composed);

    var kept = try Block.init(gpa, &.{ .model = text.items });
    defer kept.deinit(gpa);
    gpa.free(try rendered(gpa, &kept, columns, 0));
    const clipped = try rendered(gpa, &kept, columns, 25);
    defer gpa.free(clipped);
    try std.testing.expectEqualStrings(composed, clipped);
}

const Pinned = struct {
    source: Block.Source,
    role: ?role.Name,
};

test "each block kind paints in the role of its kind" {
    const gpa = std.testing.allocator;
    const pinned = [_]Pinned{
        .{ .source = .{ .intro = "one line" }, .role = .accent },
        .{ .source = .{ .user_note = "one line" }, .role = .user_note },
        .{ .source = .{ .event = .{ .text = "one line" } }, .role = .accent },
        .{
            .source = .{ .event = .{ .text = "one line", .severity = .warning } },
            .role = .warning,
        },
        .{
            .source = .{ .event = .{ .text = "one line", .severity = .failure } },
            .role = .@"error",
        },
        .{ .source = .{ .user = "one line" }, .role = .user },
        .{ .source = .{ .tool_result = .{ .text = "one line" } }, .role = .tool_success },
        .{
            .source = .{ .tool_result = .{ .text = "one line", .failed = true } },
            .role = .tool_error,
        },
        .{ .source = .{ .thinking = "one line" }, .role = .muted },
        .{ .source = .{ .model = "one line" }, .role = null },
    };
    var seen: std.EnumSet(Block.Kind) = .empty;
    for (&pinned) |*pin| {
        var block = try Block.init(gpa, &pin.source);
        defer block.deinit(gpa);
        const painted = try rendered(gpa, &block, 40, 0);
        defer gpa.free(painted);
        inline for (comptime std.enums.values(role.Name)) |name| {
            const shown = std.mem.find(u8, painted, role.sequence(name)) != null;
            if (pin.role == name) try std.testing.expect(shown);
            if (pin.role == null and comptime role.paints(name)) try std.testing.expect(!shown);
        }
        seen.insert(pin.source);
    }
    try std.testing.expectEqual(std.enums.values(Block.Kind).len, seen.count());
}

test "the intro block paints the Drinky caption" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    var intro = try Block.init(gpa, &.{ .intro = "Enter: Send · Ctrl+D: Quit" });
    defer intro.deinit(gpa);

    const columns = 60;
    try std.testing.expectEqual(@as(usize, 1), intro.rows(columns));
    const placement = try rig.begin(&.{ .columns = columns, .rows = 24, .pages = 8 });
    try intro.render(gpa, &placement);

    const painted = try rig.painted();
    const title = comptime role.sequence(.accent) ++ "Drinky\x1b[0m";
    const legend = comptime role.sequence(.muted) ++ " · Enter: Send";
    try testing.expectShows(painted, &.{title});
    try testing.expectHides(painted, &.{"\x1b[1m"});
    try testing.expectShows(painted, &.{legend});

    try std.testing.expectEqual(@as(usize, 3), intro.rows(14));
}

test "each notice paints the symbol of its kind in its role" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    var failure = try Block.init(gpa, &.{ .event = .{ .text = "boom", .severity = .failure } });
    defer failure.deinit(gpa);
    var warning = try Block.init(gpa, &.{ .event = .{
        .text = "pass this state",
        .severity = .warning,
    } });
    defer warning.deinit(gpa);
    var information = try Block.init(gpa, &.{ .event = .{ .text = "all good" } });
    defer information.deinit(gpa);
    var note = try Block.init(gpa, &.{ .user_note = "Skill: zig-style" });
    defer note.deinit(gpa);

    var placement = try rig.begin(&.{ .columns = 40, .rows = 100, .pages = 8 });
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

    const painted = try rig.painted();
    const accent_sequence = comptime role.sequence(.accent);
    const warning_sequence = comptime role.sequence(.warning);
    const error_sequence = comptime role.sequence(.@"error");
    const note_sequence = comptime role.sequence(.user_note);
    try testing.expectShows(painted, &.{accent_sequence ++ "ℹ all good"});
    try testing.expectShows(painted, &.{warning_sequence ++ "⚠ pass this state"});
    try testing.expectShows(painted, &.{error_sequence ++ "⚠ boom"});
    try testing.expectShows(painted, &.{note_sequence ++ "→ Skill: zig-style"});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, "ℹ "));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, painted, "⚠ "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, "→ "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, error_sequence));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, warning_sequence));
    try testing.expectHides(painted, &.{"Event: "});
    try testing.expectHides(painted, &.{"Error: "});
}

test "a clipped block streams into a warmed frame without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();

    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    var text = try testing.numberedLines(std.testing.allocator, 60);
    defer text.deinit(std.testing.allocator);
    try text.append(std.testing.allocator, '\n');
    try text.appendSlice(std.testing.allocator, markdown_reply);
    var block = try Block.init(gpa, &.{ .model = text.items });
    defer block.deinit(gpa);
    const columns = 20;

    for (0..2) |_| {
        const placement = try rig.begin(&.{ .columns = columns, .rows = 100, .pages = 8 });
        try block.render(gpa, &placement);
        _ = try rig.painted();
    }
    block.release(gpa);
    rig.out.clearRetainingCapacity();

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    const placement = try rig.begin(&.{ .columns = columns, .rows = 100, .pages = 8, .skip = 30 });
    try block.render(gpa, &placement);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{"L30"});
    try testing.expectShows(painted, &.{"L59"});
    try testing.expectShows(painted, &.{"const answer = 42;"});
    try testing.expectHides(painted, &.{"L0"});
    try testing.expectHides(painted, &.{"L29"});
}
