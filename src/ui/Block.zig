const std = @import("std");
const application = @import("application");
const format = @import("../format.zig");

const core = @import("core");
const terminal = @import("terminal");
const Caption = @import("Caption.zig");
const markdown = @import("markdown.zig");
const Message = @import("Message.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

const Block = @This();

content: Content,
record_id: ?u64 = null,
cache: Cache = .{},
verbose: bool = true,
work: ?Work = null,
segment_ends: std.ArrayList(usize) = .empty,

pub const Work = struct {
    started_ms: i64,
    end: ?End = null,
    hidden: bool = false,
    summary: Row = .{},

    const identity_prefix = "Agent: work (";

    pub const End = struct {
        time_ms: i64,
        status: application.Record.Work.Status,
    };

    pub const Summary = struct {
        elapsed_ms: i64,
        tools: ?usize,
        received_bytes: usize,
        status: ?application.Record.Work.Status,

        pub const segment_count = 4;

        pub fn write(
            self: *const Summary,
            writer: *std.Io.Writer,
            options: *const struct { activity: []const u8, ends: *[segment_count]usize },
        ) std.Io.Writer.Error!void {
            const value = if (self.status) |status|
                @tagName(status)
            else if (options.activity.len > 0) options.activity else "waiting";
            try writer.print("{s}{s})", .{ identity_prefix, value });
            options.ends[0] = writer.buffered().len;
            var time_buffer: [24]u8 = undefined;
            const time = format.durationSeconds(
                &time_buffer,
                self.elapsed_ms,
                .down,
            );
            try writer.print("{s}Time: {s}", .{ paint.separator, time });
            options.ends[1] = writer.buffered().len;
            if (self.tools) |tools| try writer.print("{s}Tools: {d}", .{ paint.separator, tools });
            options.ends[2] = writer.buffered().len;
            var bytes_buffer: [16]u8 = undefined;
            const bytes = format.bytes(&bytes_buffer, self.received_bytes);
            try writer.print("{s}Received: {s}", .{ paint.separator, bytes });
            options.ends[3] = writer.buffered().len;
        }

        pub fn row(self: *const Summary, options: *const struct { thinking: bool }) Row {
            var result: Row = .{ .status = self.status };
            var writer: std.Io.Writer = .fixed(&result.buffer);
            self.write(&writer, &.{
                .activity = if (options.thinking) "thinking" else "",
                .ends = &result.ends,
            }) catch unreachable;
            result.length = writer.buffered().len;
            return result;
        }
    };

    pub const Row = struct {
        buffer: [128]u8 = undefined,
        length: usize = 0,
        ends: [Summary.segment_count]usize = @splat(0),
        status: ?application.Record.Work.Status = null,

        fn text(self: *const Row) []const u8 {
            return self.buffer[0..self.length];
        }

        pub fn box(self: *const Row) paint.Box {
            return Work.box(self.text(), &self.ends, self.status);
        }
    };

    pub fn box(
        text: []const u8,
        ends: []const usize,
        maybe_status: ?application.Record.Work.Status,
    ) paint.Box {
        return .{
            .text = text,
            .segment_ends = ends,
            .identity_value = .{ .start = identity_prefix.len, .end = ends[0] - 1 },
            .status = .{
                .start = 0,
                .end = ends[0],
                .dim = true,
                .role = if (maybe_status) |status| switch (status) {
                    .complete => .success,
                    .canceled, .truncated => .warning,
                    .failed => .@"error",
                } else .activity,
            },
        };
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
    user_note: Note,
    thinking: []const u8,
    model: []const u8,
    tool_result: ToolResult.Payload,
    event: Event.Payload,
};

pub const Note = struct {
    text: []const u8,
    segment_ends: []const usize = &.{},
};

const ToolResult = struct {
    text: std.ArrayList(u8),
    status: paint.Mark,
    qualifiers: std.ArrayList(paint.Mark),
    command: ?paint.Box.Range,
    received_bytes: usize,

    const Payload = struct {
        text: []const u8,
        segment_ends: []const usize = &.{},
        status: paint.Mark = .{ .start = 0, .end = 0, .role = .text },
        qualifiers: []const paint.Mark = &.{},
        command: ?paint.Box.Range = null,
        started_ms: i64 = 0,
        received_bytes: usize = 0,
    };
};

pub const Event = struct {
    text: std.ArrayList(u8),
    severity: Message.Severity,

    pub const Payload = struct {
        text: []const u8,
        severity: Message.Severity = .information,
    };

    fn init(gpa: std.mem.Allocator, payload: *const Payload) !Event {
        return .{ .text = try copy(gpa, payload.text), .severity = payload.severity };
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
    var ends: std.ArrayList(usize) = .empty;
    errdefer ends.deinit(gpa);
    var qualifiers: std.ArrayList(paint.Mark) = .empty;
    errdefer qualifiers.deinit(gpa);
    switch (source.*) {
        .tool_result => |*result| {
            try ends.appendSlice(gpa, result.segment_ends);
            try qualifiers.appendSlice(gpa, result.qualifiers);
        },
        .user_note => |*note| try ends.appendSlice(gpa, note.segment_ends),
        .intro, .user, .thinking, .model, .event => {},
    }
    return .{
        .work = switch (source.*) {
            .thinking => .{ .started_ms = 0 },
            .tool_result => |*result| .{ .started_ms = result.started_ms },
            .intro, .user, .user_note, .model, .event => null,
        },
        .segment_ends = ends,
        .content = switch (source.*) {
            .tool_result => |*result| .{ .tool_result = .{
                .text = try copy(gpa, result.text),
                .status = result.status,
                .qualifiers = qualifiers,
                .command = result.command,
                .received_bytes = result.received_bytes,
            } },
            .user_note => |*note| .{ .user_note = try copy(gpa, note.text) },
            .event => |*event| .{ .event = try Event.init(gpa, event) },
            inline else => |text, tag| @unionInit(Content, @tagName(tag), try copy(gpa, text)),
        },
    };
}

fn copy(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(gpa, text);
    return list;
}

pub fn deinit(self: *Block, gpa: std.mem.Allocator) void {
    switch (self.content) {
        .intro, .user, .user_note, .thinking, .model => |*text| text.deinit(gpa),
        .tool_result => |*result| {
            result.text.deinit(gpa);
            result.qualifiers.deinit(gpa);
        },
        .event => |*event| event.text.deinit(gpa),
    }
    self.cache.deinit(gpa);
    self.segment_ends.deinit(gpa);
}

pub fn appendText(self: *Block, gpa: std.mem.Allocator, delta: []const u8) !void {
    switch (self.content) {
        .thinking, .model => |*list| try list.appendSlice(gpa, delta),
        .intro, .user, .user_note, .tool_result, .event => unreachable,
    }
    self.cache.forget();
}

pub fn sameContent(self: *const Block, other: *const Block) bool {
    if (std.meta.activeTag(self.content) != std.meta.activeTag(other.content)) return false;
    return switch (self.content) {
        .tool_result => |*result| std.mem.eql(
            u8,
            result.text.items,
            other.content.tool_result.text.items,
        ),
        .event => |*event| event.severity == other.content.event.severity and
            std.mem.eql(u8, event.text.items, other.content.event.text.items),
        inline else => |list, tag| std.mem.eql(
            u8,
            list.items,
            @field(other.content, @tagName(tag)).items,
        ),
    };
}

pub fn adoptCache(self: *Block, previous: *const Block) void {
    self.cache.epoch = previous.cache.epoch;
    self.cache.rewritten = true;
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

pub fn receivedBytes(self: *const Block) usize {
    return self.content.tool_result.received_bytes;
}

pub fn present(self: *Block, verbose: bool) void {
    if (self.verbose == verbose) return;
    self.verbose = verbose;
    self.cache.forget();
}

pub fn presentWork(self: *Block, maybe_summary: ?*const Work.Summary) void {
    const work = &self.work.?;
    const hidden = maybe_summary == null;
    if (hidden != work.hidden) self.cache.invalidate();
    work.hidden = hidden;
    const summary = maybe_summary orelse return;
    const row = summary.row(&.{ .thinking = false });
    if (std.mem.eql(u8, work.summary.text(), row.text())) return;
    work.summary = row;
    self.cache.invalidate();
}

fn look(self: *const Block) Look {
    if (!self.verbose) {
        if (self.work) |*work| return .{ .box = .{
            .role = .text,
            .body = work.summary.box(),
        } };
    }
    return switch (self.content) {
        .intro => |list| .{ .caption = .{
            .title = "Drinky",
            .controls = list.items,
            .rows_max = 1,
        } },
        .user => |list| .{ .box = .{
            .role = .user,
            .body = .{ .text = list.items, .padded = true },
        } },
        .user_note => |list| .{ .notice = .{
            .style = .{
                .role = paint.NoticeStyle.note.role,
                .prefix = paint.NoticeStyle.note.prefix,
                .fit = .head,
                .segment_ends = self.segment_ends.items,
            },
            .text = list.items,
        } },
        .thinking => |list| .{ .markdown = .{ .role = .muted, .text = trimBlank(list.items) } },
        .model => |list| .{ .markdown = .{ .role = null, .text = trimBlank(list.items) } },
        .tool_result => |*result| .{ .box = .{
            .role = .text,
            .body = .{
                .text = result.text.items,
                .segment_ends = self.segment_ends.items,
                .status = result.status,
                .qualifiers = result.qualifiers.items,
                .command = result.command,
            },
        } },
        .event => |*event| .{ .notice = .{
            .style = .of(event.severity),
            .text = event.text.items,
        } },
    };
}

fn isHidden(self: *const Block) bool {
    if (!self.verbose) return if (self.work) |*work| work.hidden else false;
    return self.content == .thinking and paint.isBlank(self.content.thinking.items);
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
    try self.cache.retain(gpa, placement.sink, .{
        .columns = placement.columns,
        .first_row = first_row,
    });
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
    const first = std.mem.findNone(u8, text, application.reference.blank_bytes) orelse
        return text[0..0];
    const line_start = if (std.mem.findScalarLast(u8, text[0..first], '\n')) |newline|
        newline + 1
    else
        0;
    return std.mem.trimEnd(u8, text[line_start..], application.reference.blank_bytes);
}

test "each block variant renders exactly the rows it counts" {
    const gpa = std.testing.allocator;
    const cases = [_]Block.Source{
        .{ .intro = "a single intro line" },
        .{ .event = .{ .text = "first\nsecond\nthird" } },
        .{ .event = .{ .text = "boom", .severity = .failure } },
        .{ .user = "a user message long enough to wrap across the narrow test width more " ++
            "than once" },
        .{ .user_note = .{
            .text = "Skill: zig-style · File: .agents/skills/zig-style/SKILL.md",
        } },
        .{ .model = "model reply\nwith a blank\n\nthen a long paragraph that must wrap " ++
            "several rows" },
        .{ .thinking = "reasoning that runs on\n\nlong enough to wrap across the narrow " ++
            "test width more than once" },
        .{ .model = markdown_reply },
        .{ .thinking = markdown_reply },
        .{ .tool_result = .{
            .text = "Tool: read (failed)\nError: Drinky could not read foo.zig.",
        } },
        .{ .tool_result = .{
            .text = "Tool: bash · Command: ls\nTime: 400ms · Exit code: 1",
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

test "a render cache returns every allocation failure and releases each partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkRenderAllocations,
        .{},
    );
}

fn checkRenderAllocations(gpa: std.mem.Allocator) !void {
    var block = try Block.init(gpa, &.{ .model = "Answer." });
    defer block.deinit(gpa);
    var rig: testing.Rig = undefined;
    rig.init(std.testing.allocator);
    defer rig.deinit();
    const placement = try rig.begin(&.{ .columns = 80, .rows = 24 });
    try block.render(gpa, &placement);
    try testing.expectShows(try rig.painted(), &.{"Answer."});
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

test "user messages preserve blank lines and indentation in a padded purple box" {
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |verbose| {
        var block = try Block.init(gpa, &.{ .user = "\n  first\n\n    last\n" });
        defer block.deinit(gpa);
        block.present(verbose);
        const painted = try rendered(gpa, &block, 20, 0);
        defer gpa.free(painted);
        const plain = try terminal.testing.plainText(gpa, painted);
        defer gpa.free(plain);
        var lines = std.mem.splitSequence(u8, plain, "\r\n");
        for ([_][]const u8{ "", "", "  first", "", "    last", "", "" }) |expected|
            try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, lines.next().?, " "));
        try std.testing.expect(lines.next() == null);
        try testing.expectShows(painted, &.{"\x1b[35;7m  first"});
        try testing.expectHides(painted, &.{ "\x1b[7m", "\x1b[2m", "\x1b[2;39m" });
        try std.testing.expectEqual(@as(usize, 7), block.rows(20));
    }
}

test "command ranges keep every detail aligned through wrapping replay and clipping" {
    const gpa = std.testing.allocator;
    const command = "Command: git diff --check\n  你好👩‍💻 tail\n\nError: command text\nlast-line\n";
    const detail = "Error: Drinky could not run the command because of error AccessDenied.";
    for ([_][]const u8{ "Tool: bash (complete)", "Tool: 読む (complete)" }) |identity| {
        const head = try gpa.print("{s} · File: a/very/long/path.zig", .{identity});
        defer gpa.free(head);
        const text = try gpa.print("{s}\n{s}\n{s}", .{ head, command, detail });
        defer gpa.free(text);
        const source: Block.Source = .{ .tool_result = .{
            .text = text,
            .segment_ends = &.{ identity.len, head.len },
            .status = .{ .start = 0, .end = identity.len, .role = .success, .dim = true },
            .command = .{ .start = head.len + 1, .end = head.len + 1 + command.len },
        } };
        var block = try Block.init(gpa, &source);
        defer block.deinit(gpa);
        for ([_]usize{ 100, 40, 37, 36, 25, 24, 9, 1 }) |columns| {
            const indent: usize = if (columns >= 37) 24 else 0;
            const room = columns - indent;
            const expected_rows = block.rows(columns);
            const command_rows = expected_rows - 1 - terminal.width.rows(detail, room);
            try std.testing.expect(command_rows >= std.mem.count(u8, command, "\n") + 1);
            const painted = try rendered(gpa, &block, columns, 0);
            defer gpa.free(painted);
            try std.testing.expectEqual(expected_rows, testing.paintedRows(painted));
            var styled = std.mem.splitSequence(u8, painted, "\r\n");
            _ = styled.next().?;
            while (styled.next()) |row|
                try testing.expectShows(row, &.{"\x1b[2;39m"});
            const plain = try terminal.testing.plainText(gpa, painted);
            defer gpa.free(plain);
            var lines = std.mem.splitSequence(u8, plain, "\r\n");
            const header = lines.next().?;
            if (columns == 37) try testing.expectHides(header, &.{"File:"});
            var restored_error: std.ArrayList(u8) = .empty;
            defer restored_error.deinit(gpa);
            var index: usize = 0;
            while (lines.next()) |row| : (index += 1) {
                try std.testing.expect(std.mem.allEqual(u8, row[0..indent], ' '));
                try std.testing.expect(terminal.width.ofText(row) <= columns);
                if (index < command_rows) continue;
                for (row[indent..]) |byte|
                    if (byte != ' ') try restored_error.append(gpa, byte);
            }
            try std.testing.expectEqualStrings(
                "Error:DrinkycouldnotrunthecommandbecauseoferrorAccessDenied.",
                restored_error.items,
            );
            if (columns == 100) {
                try testing.expectShows(painted, &.{"\x1b[2;39mCommand:"});
                try testing.expectShows(painted, &.{
                    "\x1b[0m\r\n                        \x1b[2;39mError: Drinky",
                });
                try testing.expectShows(painted, &.{
                    "\x1b[2;39m  你好👩‍💻 tail",
                    "\x1b[2;39mError: command text",
                    "\x1b[2;39mlast-line",
                });
            }
            const replayed = try rendered(gpa, &block, columns, 0);
            defer gpa.free(replayed);
            try std.testing.expectEqualStrings(painted, replayed);
            const clipped = try rendered(gpa, &block, columns, 2);
            defer gpa.free(clipped);
            try std.testing.expectEqual(expected_rows - 2, testing.paintedRows(clipped));
            var fresh = try Block.init(gpa, &source);
            defer fresh.deinit(gpa);
            const clipped_fresh = try rendered(gpa, &fresh, columns, 2);
            defer gpa.free(clipped_fresh);
            try std.testing.expectEqualStrings(clipped_fresh, clipped);
        }
    }
}

test "user and thinking rows start at the left edge" {
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

test "a tool box removes optional metadata and wraps its complete error" {
    const gpa = std.testing.allocator;
    const columns = 20;
    const identity = "Tool: edit (failed)";
    const head = identity ++ " · File: a.zig";
    const detail = "Error: Drinky found old_text more than once. Add more text around it.";
    var block = try Block.init(gpa, &.{ .tool_result = .{
        .text = head ++ "\n" ++ detail,
        .segment_ends = &.{ identity.len, head.len },
    } });
    defer block.deinit(gpa);
    const painted = try rendered(gpa, &block, columns, 0);
    defer gpa.free(painted);
    const plain = try terminal.testing.plainText(gpa, painted);
    defer gpa.free(plain);
    try testing.expectShows(plain, &.{ identity, "around it." });
    try testing.expectHides(plain, &.{ "File:", "\u{2026}" });
    try std.testing.expectEqual(block.rows(columns), testing.paintedRows(painted));
}

test "tool errors stay dim with red identities and complete text across terminal widths" {
    const gpa = std.testing.allocator;
    const detail = "Error: Drinky could not read the file because of error AccessDenied.";
    for ([_][]const u8{ "Tool: read (failed)", "Tool: 読む (failed)" }) |identity| {
        const head = try gpa.print("{s} · File: src/App.zig", .{identity});
        defer gpa.free(head);
        const text = try gpa.print("{s}\n{s}", .{ head, detail });
        defer gpa.free(text);
        var block = try Block.init(gpa, &.{ .tool_result = .{
            .text = text,
            .segment_ends = &.{ identity.len, head.len },
            .status = .{ .start = 0, .end = identity.len, .role = .@"error", .dim = true },
        } });
        defer block.deinit(gpa);
        const widths = [_]usize{ 80, 40, 35, 34, 25, 23, 22, 20, 1 };
        for (widths) |columns| {
            const indent: usize = if (columns >= 35) 22 else 0;
            const painted = try rendered(gpa, &block, columns, 0);
            defer gpa.free(painted);
            var styled = std.mem.splitSequence(u8, painted, "\r\n");
            try testing.expectShows(styled.next().?, &.{"\x1b[31m\x1b[2m"});
            while (styled.next()) |row|
                try testing.expectShows(row, &.{"\x1b[2;39m"});
            const plain = try terminal.testing.plainText(gpa, painted);
            defer gpa.free(plain);
            if (columns == 80) try testing.expectShows(plain, &.{
                "                      Error: Drinky",
            });
            var restored: std.ArrayList(u8) = .empty;
            defer restored.deinit(gpa);
            var lines = std.mem.splitSequence(u8, plain, "\r\n");
            _ = lines.next().?;
            while (lines.next()) |row| {
                try std.testing.expect(row.len >= indent);
                try std.testing.expect(std.mem.allEqual(u8, row[0..indent], ' '));
                try std.testing.expect(terminal.width.ofText(row) <= columns);
                for (row[indent..]) |byte| if (byte != ' ') try restored.append(gpa, byte);
            }
            try std.testing.expectEqualStrings(
                "Error:DrinkycouldnotreadthefilebecauseoferrorAccessDenied.",
                restored.items,
            );
            const expected_rows = 1 + terminal.width.rows(detail, columns - indent);
            try std.testing.expectEqual(expected_rows, block.rows(columns));
            try std.testing.expectEqual(expected_rows, testing.paintedRows(painted));
            const clipped = try rendered(gpa, &block, columns, 2);
            defer gpa.free(clipped);
            try std.testing.expectEqual(expected_rows - 2, testing.paintedRows(clipped));
        }
    }
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
        .{ .source = .{ .user_note = .{ .text = "one line" } }, .role = .user_note },
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
        .{ .source = .{ .tool_result = .{ .text = "one line" } }, .role = .text },
        .{
            .source = .{ .tool_result = .{ .text = "one line" } },
            .role = .text,
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

    try std.testing.expectEqual(@as(usize, 1), intro.rows(14));
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
    var note = try Block.init(gpa, &.{ .user_note = .{ .text = "Skill: zig-style" } });
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

test "work summaries keep time before tools and bytes and reduce to one row" {
    const gpa = std.testing.allocator;
    var block = try Block.init(gpa, &.{ .tool_result = .{ .text = "Tool: read (complete)" } });
    defer block.deinit(gpa);
    block.present(false);
    block.presentWork(&.{
        .elapsed_ms = 3_000,
        .tools = 2,
        .received_bytes = 1024,
        .status = .complete,
    });
    const cases = [_]struct { columns: usize, expected: []const u8 }{
        .{
            .columns = 80,
            .expected = "Agent: work (complete) · Time: 3s · Tools: 2 · Received: 1.0 KiB",
        },
        .{ .columns = 63, .expected = "Agent: work (complete) · Time: 3s · Tools: 2" },
        .{ .columns = 43, .expected = "Agent: work (complete) · Time: 3s" },
        .{ .columns = 32, .expected = "Agent: work (complete)" },
        .{ .columns = 22, .expected = "Agent: work (complete)" },
        .{ .columns = 15, .expected = "Agent: work (…)" },
        .{ .columns = 1, .expected = "…" },
    };
    for (cases) |case| {
        const painted = try rendered(gpa, &block, case.columns, 0);
        defer gpa.free(painted);
        const plain = try terminal.testing.plainText(gpa, painted);
        defer gpa.free(plain);
        try std.testing.expectEqualStrings(case.expected, std.mem.trimEnd(u8, plain, " "));
        if (case.columns == 1) {
            try testing.expectShows(painted, &.{"\x1b[32m\x1b[2m…"});
        } else {
            try testing.expectShows(painted, &.{"\x1b[32m\x1b[2mAgent: work"});
        }
        try testing.expectHides(plain, &.{"Tool: read"});
        try std.testing.expectEqual(@as(usize, 1), block.rows(case.columns));
        try std.testing.expectEqual(@as(usize, 1), testing.paintedRows(painted));
    }

    block.presentWork(&.{ .elapsed_ms = 0, .tools = 1, .received_bytes = 5, .status = null });
    const running = try rendered(gpa, &block, 80, 0);
    defer gpa.free(running);
    const plain = try terminal.testing.plainText(gpa, running);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(
        "Agent: work (waiting) · Time: 0s · Tools: 1 · Received: 5 B",
        std.mem.trimEnd(u8, plain, " "),
    );
    try testing.expectShows(running, &.{"\x1b[36m\x1b[2mAgent: work (waiting)"});
}

test "user notes keep one row while session events can use multiple rows" {
    const gpa = std.testing.allocator;
    const identity = "Skill: zig-style";
    const text = identity ++ " · File: a long path · with a separator/SKILL.md";
    var note = try Block.init(gpa, &.{ .user_note = .{
        .text = text,
        .segment_ends = &.{ identity.len, text.len },
    } });
    defer note.deinit(gpa);
    var sentence = try Block.init(gpa, &.{ .user_note = .{
        .text = "Drinky asked the model to continue from the committed work.",
    } });
    defer sentence.deinit(gpa);
    var event = try Block.init(gpa, &.{ .event = .{
        .text = "Drinky could not complete the request. Details: a complete final-word.",
        .severity = .failure,
    } });
    defer event.deinit(gpa);
    for ([_]bool{ true, false }) |verbose| {
        note.present(verbose);
        sentence.present(verbose);
        event.present(verbose);
        const painted = try rendered(gpa, &note, 40, 0);
        defer gpa.free(painted);
        const plain = try terminal.testing.plainText(gpa, painted);
        defer gpa.free(plain);
        try std.testing.expectEqualStrings("→ Skill: zig-style", plain);
        try std.testing.expectEqual(@as(usize, 1), note.rows(40));
        const sentence_paint = try rendered(gpa, &sentence, 30, 0);
        defer gpa.free(sentence_paint);
        try testing.expectShows(sentence_paint, &.{"…"});
        try std.testing.expectEqual(@as(usize, 1), sentence.rows(30));
        const event_paint = try rendered(gpa, &event, 30, 0);
        defer gpa.free(event_paint);
        try testing.expectShows(event_paint, &.{"final-word."});
        try std.testing.expect(event.rows(30) > 1);
    }
}

test "metadata truncates only its mandatory segment across narrow Unicode widths" {
    const gpa = std.testing.allocator;
    const identity = "Tool: 読む (complete)";
    const file = identity ++ " · File: a · b.zig";
    const text = file ++ " · Lines: 3";
    var block = try Block.init(gpa, &.{ .tool_result = .{
        .text = text,
        .segment_ends = &.{ identity.len, file.len, text.len },
    } });
    defer block.deinit(gpa);
    for (1..80) |columns| {
        const painted = try rendered(gpa, &block, columns, 0);
        defer gpa.free(painted);
        const plain = try terminal.testing.plainText(gpa, painted);
        defer gpa.free(plain);
        try std.testing.expectEqual(@as(usize, 1), block.rows(columns));
        try std.testing.expectEqual(@as(usize, 1), testing.paintedRows(painted));
        const maybe_expected: ?[]const u8 = if (terminal.width.ofText(text) <= columns)
            text
        else if (terminal.width.ofText(file) <= columns)
            file
        else if (terminal.width.ofText(identity) <= columns)
            identity
        else
            null;
        if (maybe_expected) |expected| {
            try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, plain, " "));
        } else {
            try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, plain, " "), "…"));
        }
    }
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
