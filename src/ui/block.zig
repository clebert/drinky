//! The transcript-block model. `Entry` is a tagged union that carries exactly
//! each block's data: the plain blocks a byte buffer, the flagged ones a buffer
//! plus an error flag, the reasoning one a buffer plus the account that produced
//! it. It owns its bytes (`init`/`deinit`), measures itself (`rows`), and paints
//! itself (`render`) with the shared `paint` primitives. The model block grows in
//! place as its reply streams, and its markdown renders as it goes.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

pub const Entry = union(enum) {
    intro: std.ArrayList(u8),
    user: std.ArrayList(u8),
    /// What Drinky sent for the user, such as the head of a loaded skill. It is
    /// not a box, so a typed message cannot forge it.
    skill: std.ArrayList(u8),
    thinking: Reasoning,
    model: std.ArrayList(u8),
    tool_result: Flagged,
    event: Flagged,

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
    pub const Kind = std.meta.Tag(Entry);

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
        return switch (kind) {
            .tool_result => .{ .tool_result = flagged },
            .event => .{ .event = flagged },
            .thinking => .{ .thinking = .{ .text = list, .account = options.account } },
            inline else => |tag| @unionInit(Entry, @tagName(tag), list),
        };
    }

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .intro, .user, .skill, .model => |*text| text.deinit(gpa),
            .thinking => |*reasoning| reasoning.text.deinit(gpa),
            .tool_result, .event => |*flagged| flagged.text.deinit(gpa),
        }
    }

    /// The account slot whose model context holds this block, or null for a
    /// local block that every account shows. Only stored reasoning binds to one
    /// account, because only that account replays its proof.
    pub fn account(self: *const Entry) ?ai.llm.Account {
        return switch (self.*) {
            .thinking => |reasoning| reasoning.account,
            .intro, .user, .skill, .model, .tool_result, .event => null,
        };
    }

    /// Whether this event remains visible when an abnormal turn rewinds its
    /// model tail. Every other block follows the rewind checkpoint.
    pub fn survivesRewind(self: *const Entry) bool {
        return switch (self.*) {
            .event => |event| event.survives_rewind,
            .intro, .user, .skill, .thinking, .model, .tool_result => false,
        };
    }

    /// The bytes this block holds.
    fn bytes(self: *const Entry) []const u8 {
        return switch (self.*) {
            .intro, .user, .skill, .model => |list| list.items,
            .thinking => |reasoning| reasoning.text.items,
            .tool_result, .event => |flagged| flagged.text.items,
        };
    }

    /// How this block paints as a notice, or null for a block that paints a box
    /// or markdown. The measure and the paint share it, so the rows a block
    /// counts cannot diverge from the rows it paints.
    fn notice(self: *const Entry) ?paint.Notice {
        return switch (self.*) {
            .intro => .{ .role = .muted },
            .skill => .{ .role = .user_note },
            // An error event wraps like every other event. The transcript is the
            // place where the whole sentence must stay readable.
            .event => |flagged| .{
                .role = if (flagged.is_error) .@"error" else .muted,
                .prefix = if (flagged.is_error) "Error: " else "",
            },
            .user, .tool_result, .thinking, .model => null,
        };
    }

    /// The physical rows this block wraps to at `columns`, its leading separator
    /// excluded. Must equal exactly what `render` emits: the parity the diff
    /// and window math rely on.
    pub fn rows(self: *const Entry, columns: usize) usize {
        if (self.notice()) |look| return paint.noticeRows(&look, self.bytes(), columns);
        return switch (self.*) {
            .user => |list| paint.boxRows(&.{ .text = list.items }, columns),
            .tool_result => |flagged| paint.boxRows(
                &.{ .text = flagged.text.items, .fit = flagged.fit },
                columns,
            ),
            .thinking => |reasoning| markdown.rows(reasoning.text.items, columns),
            .model => |list| markdown.rows(list.items, columns),
            .intro, .skill, .event => unreachable,
        };
    }

    /// Compose this block's rows through `placement` and drop its top `skip`
    /// rows (nonzero only for the clip).
    pub fn render(self: *const Entry, placement: *const paint.Placement) !void {
        if (self.notice()) |look| return paint.notice(placement, &look, self.bytes());
        switch (self.*) {
            .intro, .skill, .event => unreachable,
            .user => |list| try paint.box(placement, .user, &.{ .text = list.items }),
            .tool_result => |flagged| try paint.box(
                placement,
                if (flagged.is_error) .tool_error else .tool_success,
                // The head row names the tool, so the box emphasizes that
                // name. A finished box then reads like the running one.
                &.{
                    .text = flagged.text.items,
                    .fit = flagged.fit,
                    .emphasis = .first_value,
                },
            ),
            .thinking => |reasoning| try markdown.render(placement, .muted, reasoning.text.items),
            .model => |list| try markdown.render(placement, null, list.items),
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

// Rows `entry` paints into a fresh view. The paint drops its top `skip`. Fresh
// so the paint is a full reprint whose rows `paintedRows` can count. The window
// is tall enough that only `skip` clips.
fn renderedRows(gpa: std.mem.Allocator, entry: *const Entry, columns: usize, skip: usize) !usize {
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
    try entry.render(&placement);
    try view.render();
    return paintedRows(out.written());
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
        .{ .kind = .skill, .options = .{}, .text = "Skill: zig-style · File: " ++
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
            const painted = try renderedRows(gpa, &entry, columns, 0);
            try std.testing.expectEqual(entry.rows(columns), painted);
        }
    }
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
    try user.render(&placement);
    try thinking.render(&second);
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
    try wrapped.render(&.{ .sink = sink, .id = 0, .columns = columns, .base = 0, .skip = 0 });
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
    const entry: Entry = .{ .model = text };
    const columns = 20;
    try std.testing.expectEqual(@as(usize, 40), entry.rows(columns));
    try std.testing.expectEqual(@as(usize, 15), try renderedRows(gpa, &entry, columns, 25));
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
    try failure.render(&placement);
    try success.render(&second);
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
    const entry: Entry = .{ .model = text };
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
        try entry.render(&placement);
        try view.render();
    }
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
    try entry.render(&placement);
    try view.render();

    // The paint emits only the visible rows. The clipped top never materializes.
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "L30") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "const answer = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L29") == null);
}
