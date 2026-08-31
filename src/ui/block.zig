//! The transcript-block model. `Entry.Content` is a tagged union that carries
//! exactly each block's data: the plain blocks a byte buffer, the flagged ones a
//! buffer plus an error flag, the reasoning one a buffer plus the account that
//! produced it. A block owns its bytes (`init`/`deinit`), measures itself
//! (`rows`), and paints itself (`render`) with the shared `paint` primitives. The
//! model block grows in place as its reply streams, and its markdown renders as
//! it goes.
//!
//! Each block also retains the rows of its last paint. A frame replays those
//! rows and runs the markdown of the blocks that changed alone. A block is
//! append-only, so `appendText` drops the rows of the streaming tail and every
//! block above it retains its own.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const Caption = @import("Caption.zig");
const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

pub const Entry = struct {
    content: Content,
    /// The rows this block painted last, so the frames that follow replay them.
    cache: Cache = .{},

    pub const Content = union(enum) {
        intro: std.ArrayList(u8),
        user: std.ArrayList(u8),
        /// A line that reports a message that Drinky wrote for the user. The
        /// head of a loaded skill and the line of a retry attempt read this way.
        /// It is not a box, so a typed message cannot forge it.
        user_note: std.ArrayList(u8),
        thinking: Reasoning,
        model: std.ArrayList(u8),
        tool_result: Flagged,
        event: Flagged,
    };

    pub const Flagged = struct {
        text: std.ArrayList(u8),
        is_error: bool,
        /// How a line wider than the window fits. Only a tool box reads it. An
        /// event renders as a notice, which always wraps.
        fit: paint.Fit,
        /// Whether an event stays when an abnormal turn rewinds its model tail.
        /// Other flagged blocks ignore this field.
        survives_rewind: bool,
    };

    /// One run of model reasoning and the account slot that produced it. Only
    /// that slot replays the stored proof of that reasoning, so only that slot
    /// shows the block. Null marks a block that no account claims, and every
    /// projection shows such a block.
    pub const Reasoning = struct {
        text: std.ArrayList(u8),
        account: ?ai.llm.Account,
    };
    pub const Kind = std.meta.Tag(Content);

    /// What a block carries beyond its text. A variant that ignores a field
    /// takes its default, so a plain block states nothing.
    pub const Options = struct {
        /// Whether the block reports a failure. It paints the error role, and
        /// it gives an event its prefix. The plain variants ignore it.
        is_error: bool = false,
        /// How a tool box fits a line that is wider than the window. A call row
        /// and a measures line cut, because the start of each identifies it. The
        /// sentence of a failure wraps, because its instruction sits at the end,
        /// and a cut there takes the half the user needs.
        fit: paint.Fit = .head,
        /// The account slot that produced a reasoning block. Every other variant
        /// ignores it.
        account: ?ai.llm.Account = null,
        /// Whether an event survives an abnormal turn rewind. Every other
        /// variant ignores it.
        survives_rewind: bool = false,
    };

    /// The composed rows of one block at one width. A frame that painted the
    /// block whole retained them, and their count is the measure of the block.
    /// A clipped block retains nothing, so the rows stay inside the window.
    /// Every block paints at least one row, so an empty store means that no
    /// frame retained one.
    pub const Cache = struct {
        /// The width the retained rows fit.
        columns: usize = 0,
        /// Every row the block paints at `columns`.
        lines: terminal.View.Lines = .empty,

        fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
            self.lines.deinit(gpa);
        }

        /// The rows retained for `columns`, or null when the cache holds none.
        fn retained(self: *const Cache, columns: usize) ?*const terminal.View.Lines {
            if (self.columns != columns or self.lines.count() == 0) return null;
            return &self.lines;
        }

        /// Retain the rows that `sink` composed from `options.first_row` on.
        /// They fit `options.columns`, so a frame at another width composes the
        /// block again.
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

        /// Drop the retained rows and hold their buffers for the next paint.
        fn invalidate(self: *Cache) void {
            self.lines.clearRetainingCapacity();
        }
    };

    /// A new block that owns a copy of `text`.
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
            .fit = options.fit,
            .survives_rewind = options.survives_rewind,
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

    /// Append `delta` to the text of a streamed block, and drop the rows that
    /// held the text before it. Only a block that a run streams accepts text.
    pub fn appendText(self: *Entry, gpa: std.mem.Allocator, delta: []const u8) !void {
        switch (self.content) {
            .model => |*list| try list.appendSlice(gpa, delta),
            .thinking => |*reasoning| try reasoning.text.appendSlice(gpa, delta),
            .intro, .user, .user_note, .tool_result, .event => unreachable,
        }
        self.cache.invalidate();
    }

    /// Free the rows this block retains. A block that a frame does not paint
    /// retains none, so the retained rows stay inside the window.
    pub fn release(self: *Entry, gpa: std.mem.Allocator) void {
        self.cache.lines.clear(gpa);
    }

    /// The account slot whose model context holds this block, or null for a
    /// local block that every account shows. Only stored reasoning binds to one
    /// account, because only that account replays its proof.
    pub fn account(self: *const Entry) ?ai.llm.Account {
        return switch (self.content) {
            .thinking => |reasoning| reasoning.account,
            .intro, .user, .user_note, .model, .tool_result, .event => null,
        };
    }

    /// Whether this event remains visible when an abnormal turn rewinds its
    /// model tail. Every other block follows the rewind checkpoint.
    pub fn survivesRewind(self: *const Entry) bool {
        return switch (self.content) {
            .event => |event| event.survives_rewind,
            .intro, .user, .user_note, .thinking, .model, .tool_result => false,
        };
    }

    /// The bytes this block holds.
    fn bytes(self: *const Entry) []const u8 {
        return switch (self.content) {
            .intro, .user, .user_note, .model => |list| list.items,
            .thinking => |reasoning| reasoning.text.items,
            .tool_result, .event => |flagged| flagged.text.items,
        };
    }

    /// `text` with the blank rows it ends on dropped. A provider can end a
    /// reply or a run of reasoning on blank lines, and the markdown walk counts
    /// a row for each one. The block then holds empty rows over the block under
    /// it.
    fn trimBlankTail(text: []const u8) []const u8 {
        return std.mem.trimEnd(u8, text, " \t\r\n");
    }

    /// How this block paints as a notice, or null for a block that paints a box
    /// or markdown. The measure and the paint share it, so the rows a block
    /// counts cannot diverge from the rows it paints.
    fn notice(self: *const Entry) ?paint.Notice {
        return switch (self.content) {
            .user_note => .{ .role = .user_note },
            // An error event wraps like every other event. The transcript is the
            // place where the whole sentence must stay readable.
            .event => |flagged| .{
                .role = if (flagged.is_error) .@"error" else .muted,
                .prefix = if (flagged.is_error) "Error: " else "",
            },
            .intro, .user, .tool_result, .thinking, .model => null,
        };
    }

    /// The intro line as the caption of the interface: the product title, then
    /// the legend this block carries. It keeps the default row bound, because a
    /// transcript block scrolls away and moves no input around.
    fn introCaption(legend: []const u8) Caption {
        return .{ .title = "Drinky", .controls = legend };
    }

    /// The role of the box this block paints, or null for a block that paints a
    /// notice or markdown. A failed call takes the error color, so the state of
    /// a call decides the color of its box.
    fn boxRole(self: *const Entry) ?role.Name {
        return switch (self.content) {
            .user => .user,
            .tool_result => |flagged| if (flagged.is_error) .tool_error else .tool_success,
            .intro, .user_note, .thinking, .model, .event => null,
        };
    }

    /// The physical rows this block wraps to at `columns`, its leading separator
    /// excluded. Must equal exactly what `render` emits: the parity the diff
    /// and window math rely on. The rows of the last paint state that count, so
    /// a block that painted whole at this width measures itself again for free.
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
            .thinking => |reasoning| markdown.rows(trimBlankTail(reasoning.text.items), columns),
            .model => |list| markdown.rows(trimBlankTail(list.items), columns),
            .user_note, .event => unreachable,
        };
    }

    /// Compose this block's rows through `placement` and drop its top `skip`
    /// rows (nonzero only for the clip). The rows of the last paint at this
    /// width replay as they are, so an unchanged block runs no markdown.
    ///
    /// A paint that composed the block whole retains its rows for the frames
    /// that follow. A clipped block composes its visible rows alone and retains
    /// none, so its hidden top never materializes and the retained rows stay
    /// inside the window. Rows that Drinky cannot hold cost the frame nothing,
    /// because the paint below already wrote every one of them.
    pub fn render(
        self: *Entry,
        gpa: std.mem.Allocator,
        placement: *const paint.Placement,
    ) !void {
        if (self.cache.retained(placement.columns)) |lines| return replay(placement, lines);
        const first_row = placement.sink.composed();
        try self.compose(placement);
        if (placement.skip > 0) return;
        self.cache.retain(gpa, placement.sink, .{
            .columns = placement.columns,
            .first_row = first_row,
        }) catch self.cache.invalidate();
    }

    /// Compose the retained rows through `placement`, its clipped top dropped.
    /// The rows carry the anchors of a fresh paint, so the diff of the frame
    /// cannot tell the two apart.
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
                // The head row names the tool, so the box emphasizes that
                // name. A finished box then reads like the running one.
                &.{
                    .text = flagged.text.items,
                    .fit = flagged.fit,
                    .emphasis = .first_value,
                },
            ),
            .thinking => |reasoning| try markdown.render(
                placement,
                .muted,
                trimBlankTail(reasoning.text.items),
            ),
            .model => |list| try markdown.render(placement, null, trimBlankTail(list.items)),
        }
    }
};

/// Physical rows in a fresh paint: the view joins its inert rows with `\r\n`,
/// and row text cannot emit those separators, so they count physical rows.
pub fn paintedRows(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\r\n") + 1;
}

/// A `\n`-joined `L0`..`L<count-1>` test fixture, tall enough to overflow a
/// window so clipping tests can pin which numbered rows survive.
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

// A reply that carries the markdown shapes that reflow: a heading, a fenced
// block, a nested list, a quote, and inline emphasis.
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

// The bytes `entry` paints into a fresh view. The paint drops its top `skip`.
// Fresh so the paint is a full reprint whose rows `paintedRows` can count. The
// window is tall enough that only `skip` clips. Caller-owned.
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

// Rows `entry` paints into a fresh view, through `rendered`.
fn renderedRows(gpa: std.mem.Allocator, entry: *Entry, columns: usize, skip: usize) !usize {
    const painted = try rendered(gpa, entry, columns, skip);
    defer gpa.free(painted);
    return paintedRows(painted);
}

// The parity contract: what `rows` counts is exactly what `render` emits. Here
// per entry variant, with content that wraps and carries blank lines.
test "each entry variant renders exactly the rows it counts" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { kind: Entry.Kind, options: Entry.Options, text: []const u8 }{
        .{ .kind = .intro, .options = .{}, .text = "a single intro line" },
        .{ .kind = .event, .options = .{}, .text = "first\nsecond\nthird" },
        .{ .kind = .event, .options = .{ .is_error = true }, .text = "boom" },
        .{ .kind = .user, .options = .{}, .text = "a user message long enough to wrap " ++
            "across the narrow test width more than once" },
        // The head of a skill invocation: one line that no box holds.
        .{ .kind = .user_note, .options = .{}, .text = "Skill: zig-style · File: " ++
            ".agents/skills/zig-style/SKILL.md" },
        .{ .kind = .model, .options = .{}, .text = "model reply\nwith a blank\n\n" ++
            "then a long paragraph that must wrap several rows" },
        .{ .kind = .thinking, .options = .{}, .text = "reasoning that runs on\n\n" ++
            "long enough to wrap across the narrow test width more than once" },
        // Markdown, whose prefixes and indents can outgrow the narrow widths.
        .{ .kind = .model, .options = .{}, .text = markdown_reply },
        .{ .kind = .thinking, .options = .{}, .text = markdown_reply },
        .{
            .kind = .tool_result,
            .options = .{ .is_error = true, .fit = .wrap },
            .text = "read foo.zig\n→ no such file",
        },
        // A failure that states measures cuts its lines like a success does.
        .{
            .kind = .tool_result,
            .options = .{ .is_error = true },
            .text = "Tool: bash · Command: ls\nTime: 400ms · Exit code: 1",
        },
        // A call whose tool decided no box line is the call row alone.
        .{ .kind = .tool_result, .options = .{}, .text = "Tool: describe_drinky" },
        // A wide-glyph box, to exercise the narrow-width row cap.
        .{ .kind = .user, .options = .{}, .text = "你好世界" },
    };
    // Includes widths narrower than a box's borders and the error prefix, where
    // `Sink.end`'s one-row assertion pins the renderers' clamps.
    const widths = [_]usize{ 16, 3, 2 };
    for (cases) |case| {
        var entry = try Entry.init(gpa, case.kind, case.options, case.text);
        defer entry.deinit(gpa);
        for (widths) |columns| {
            // The measure runs ahead of the paint, so it walks the content of
            // the block and never reads the rows of the paint before it.
            const counted = entry.rows(columns);
            try std.testing.expectEqual(counted, try renderedRows(gpa, &entry, columns, 0));
        }
    }
}

// Regression: a provider can end a reply or a run of reasoning on blank lines.
// The markdown walk counted a row for each one, so empty rows opened under the
// block.
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

    // Blank lines alone still hold the one row that every block paints.
    var blanks_only = try Entry.init(gpa, .model, .{}, "\n\n");
    defer blanks_only.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), blanks_only.rows(columns));
    try std.testing.expectEqual(@as(usize, 1), try renderedRows(gpa, &blanks_only, columns, 0));
}

// The same padding everywhere: a copy of a reasoning row starts at the column a
// copy of a message box row starts at.
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

    // Every row opens on its own first character.
    const painted = out.written();
    try expectRowOpensOnText(painted, "a user message that");
    try expectRowOpensOnText(painted, "reasoning that wraps");
}

// A sentence names what went wrong and what to do about it, and the instruction
// sits at its end. A cut there takes the half the user needs, so a box that
// holds a sentence wraps while every other box keeps one row a line. The failure
// flag decides the color alone, never the fit.
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

    // Two padding rows plus one row a line for the cut box.
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
    // The tail of the sentence reaches the interface, and no row cut it.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "around it.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\u{2026}") == null);
}

// A row that starts with a blank puts that blank in every copy of it. The style
// of the row is the only thing in front of its first character, so no space at
// all separates the start of the row from its text. Both blocks meeting this
// start at the same column.
fn expectRowOpensOnText(painted: []const u8, row: []const u8) !void {
    const start = std.mem.indexOf(u8, painted, row) orelse return error.TestExpectedRow;
    const break_end = if (std.mem.lastIndexOf(u8, painted[0..start], "\r\n")) |cut|
        cut + 2
    else
        0;
    try std.testing.expect(start > break_end);
    try std.testing.expect(std.mem.indexOfScalar(u8, painted[break_end..start], ' ') == null);
}

// The clip drops its top `skip` rows and shows the rest.
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

// A block that painted whole retains its rows, so every frame that follows runs
// no markdown for it. The replay must paint exactly the bytes of that first
// paint, and a change of the text or of the width must reach the screen.
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

    // Another width composes the block again, and its rows replace the old ones.
    const narrow = try rendered(gpa, &entry, 16, 0);
    defer gpa.free(narrow);
    try std.testing.expect(!std.mem.eql(u8, first, narrow));
    try std.testing.expectEqual(@as(usize, 16), entry.cache.columns);

    // Streamed text drops the retained rows, so the next paint carries it.
    try entry.appendText(gpa, "\n\nEpilogue\n");
    try std.testing.expectEqual(@as(usize, 0), entry.cache.lines.count());
    const grown = try rendered(gpa, &entry, 16, 0);
    defer gpa.free(grown);
    try std.testing.expect(std.mem.indexOf(u8, grown, "Epilogue") != null);
    try std.testing.expectEqual(entry.cache.lines.count(), entry.rows(16));
}

// A clip reads the retained rows the way the paint does: it drops the same top
// rows and shows the same tail. A clipped paint retains no rows, because the
// window holds no whole block then.
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

/// One pinned block, and the role it paints as a notice or as a box. A caption
/// block owns the accent title and the muted legend of the shared caption. A
/// block that paints markdown carries no name at all.
const Pinned = struct {
    kind: Entry.Kind,
    options: Entry.Options = .{},
    notice: ?role.Name = null,
    box: ?role.Name = null,
    caption: bool = false,
};

// The color of a block states who wrote it. A line that reports a message that
// Drinky wrote for the user takes the user color. It never reads as a report
// about the state of the session. A kind that the list leaves out fails, so a
// new kind cannot reach a release unclassified.
test "each block kind pins the role that it paints" {
    const gpa = std.testing.allocator;
    const pinned = [_]Pinned{
        .{ .kind = .intro, .caption = true },
        // Every message that Drinky wrote for the user reports in this color.
        .{ .kind = .user_note, .notice = .user_note },
        .{ .kind = .event, .notice = .muted },
        .{ .kind = .event, .options = .{ .is_error = true }, .notice = .@"error" },
        .{ .kind = .user, .box = .user },
        .{ .kind = .tool_result, .box = .tool_success },
        .{ .kind = .tool_result, .options = .{ .is_error = true }, .box = .tool_error },
        // Reasoning and a reply paint markdown, which owns its own colors.
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

// The intro block paints the shared caption: the accent product title, then
// the muted legend beside it. A narrow window splits the legend under the
// title, and the block still counts exactly the rows it paints.
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
    try std.testing.expect(std.mem.indexOf(u8, painted, legend) != null);

    // A window narrower than the joined row splits the legend under the title.
    try std.testing.expectEqual(@as(usize, 3), intro.rows(14));
}

// An error event must be visibly distinct: the error role and an "Error: "
// prefix, both absent from an informational event.
test "an error event paints the error role and its prefix" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    var failure = try Entry.init(gpa, .event, .{ .is_error = true }, "boom");
    defer failure.deinit(gpa);
    var success = try Entry.init(gpa, .event, .{}, "all good");
    defer success.deinit(gpa);

    const sink = try view.beginFrame(.{ .columns = 40, .rows = 100 }, 8);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 40,
        .base = 0,
        .skip = 0,
    };
    var second = placement;
    second.id = 1;
    try failure.render(gpa, &placement);
    try success.render(gpa, &second);
    try view.render();

    const painted = out.written();
    const error_sequence = comptime role.sequence(.@"error");
    try std.testing.expect(std.mem.indexOf(u8, painted, error_sequence ++ "Error: ") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, "Error: "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, painted, error_sequence));
}

// Bounded memory: a clipped block composes only its visible rows into a frame
// warmed to the block's full size. The smaller clip reuses the warmed buffers
// with no allocation and never materializes its hidden top. The visible rows
// carry markdown, so the renderer's own paths run under the armed allocator too.
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

    // Warm both frames and the output at the block's full size.
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
    // The window holds no whole block here, so the block retains no rows. The
    // clipped paint below then runs the renderer, not a replay.
    entry.release(gpa);
    // Drop the accumulated output so the arm measures only the clipped render.
    // Its bytes fit the buffer the full-size warm already grew.
    out.clearRetainingCapacity();

    // Arm: any further allocation or growth now fails.
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

    // The paint emits only the visible rows. The clipped top never materializes.
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "L30") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "const answer = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L29") == null);
}
