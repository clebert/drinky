//! The transcript-block model. `Entry` is a tagged union that carries exactly
//! each block's data: the plain blocks a byte buffer, the flagged ones a buffer
//! plus an error flag. It owns its bytes (`init`/`deinit`), measures itself
//! (`rows`), and paints itself (`render`) with the shared `paint` primitives.
//! The model block grows in place as its reply streams, and its markdown
//! renders as it goes.

const std = @import("std");

const terminal = @import("terminal");

const markdown = @import("markdown.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

pub const Entry = union(enum) {
    intro: std.ArrayList(u8),
    user: std.ArrayList(u8),
    skill: std.ArrayList(u8),
    thinking: std.ArrayList(u8),
    model: std.ArrayList(u8),
    tool_result: Flagged,
    event: Flagged,

    pub const Flagged = struct { text: std.ArrayList(u8), is_error: bool };
    pub const Kind = std.meta.Tag(Entry);

    /// A new block that owns a copy of `text`. The plain variants ignore
    /// `is_error`.
    pub fn init(gpa: std.mem.Allocator, kind: Kind, is_error: bool, text: []const u8) !Entry {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, text);
        return switch (kind) {
            .tool_result => .{ .tool_result = .{ .text = list, .is_error = is_error } },
            .event => .{ .event = .{ .text = list, .is_error = is_error } },
            inline else => |tag| @unionInit(Entry, @tagName(tag), list),
        };
    }

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .intro, .user, .skill, .thinking, .model => |*text| text.deinit(gpa),
            .tool_result, .event => |*flagged| flagged.text.deinit(gpa),
        }
    }

    /// The physical rows this block wraps to at `columns`, its leading separator
    /// excluded. Must equal exactly what `render` emits: the parity the diff
    /// and window math rely on.
    pub fn rows(self: *const Entry, columns: usize) usize {
        return switch (self.*) {
            .intro, .skill => |text| std.mem.count(u8, text.items, "\n") + 1,
            .event => |flagged| std.mem.count(u8, flagged.text.items, "\n") + 1,
            .user => |text| paint.boxRows(&.{ .text = text.items }, columns),
            .tool_result => |flagged| paint.boxRows(
                &toolBox(flagged.text.items, flagged.is_error),
                columns,
            ),
            .thinking, .model => |text| markdown.rows(text.items, columns),
        };
    }

    /// Compose this block's rows through `placement` and drop its top `skip`
    /// rows (nonzero only for the clip).
    pub fn render(self: *const Entry, placement: *const paint.Placement) !void {
        switch (self.*) {
            .intro => |text| try paint.notice(placement, &.{
                .role = .muted,
                .prefix = "",
            }, text.items),
            .event => |flagged| try paint.notice(placement, &.{
                .role = if (flagged.is_error) .@"error" else .muted,
                .prefix = if (flagged.is_error) "Error: " else "",
            }, flagged.text.items),
            .user => |text| try paint.box(placement, .user, &.{ .text = text.items }),
            .skill => |text| try paint.notice(placement, &.{
                .role = .accent,
                .prefix = "Skill: ",
                // The head names the block once. Its later rows carry the source
                // and the size, so an indent groups them under that head.
                .continuation = "  ",
            }, text.items),
            .tool_result => |flagged| try paint.box(
                placement,
                if (flagged.is_error) .tool_error else .tool_success,
                &toolBox(flagged.text.items, flagged.is_error),
            ),
            .thinking => |text| try markdown.render(placement, .muted, text.items),
            .model => |text| try markdown.render(placement, null, text.items),
        }
    }
};

/// A finished tool call keeps its call row, and the line the tool decided below
/// it. A successful call cuts each line at the window, because the start of the
/// line carries what identifies it: the tool and its subject above, the leading
/// measures below.
///
/// A failed call wraps instead. Its detail is a whole sentence that names what
/// went wrong and what to do about it, and that instruction sits at the end. A
/// cut there takes the half the user needs and leaves it nowhere in the
/// interface. The cost is that a failed call with long arguments takes more
/// rows, which is the call whose arguments the user wants to read anyway.
fn toolBox(text: []const u8, is_error: bool) paint.Box {
    return .{ .text = text, .fit = if (is_error) .wrap else .head };
}

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
    const cases = [_]struct { kind: Entry.Kind, is_error: bool, text: []const u8 }{
        .{ .kind = .intro, .is_error = false, .text = "a single intro line" },
        .{ .kind = .event, .is_error = false, .text = "first\nsecond\nthird" },
        .{ .kind = .event, .is_error = true, .text = "boom" },
        .{ .kind = .user, .is_error = false, .text = "a user message long enough to wrap " ++
            "across the narrow test width more than once" },
        .{ .kind = .skill, .is_error = false, .text = "zig-style · Size: 3.1 KB\n" ++
            "Source: .agents/skills/zig-style/SKILL.md" },
        .{ .kind = .model, .is_error = false, .text = "model reply\nwith a blank\n\n" ++
            "then a long paragraph that must wrap several rows" },
        .{ .kind = .thinking, .is_error = false, .text = "reasoning that runs on\n\n" ++
            "long enough to wrap across the narrow test width more than once" },
        // Markdown, whose prefixes and indents can outgrow the narrow widths.
        .{ .kind = .model, .is_error = false, .text = markdown_reply },
        .{ .kind = .thinking, .is_error = false, .text = markdown_reply },
        .{ .kind = .tool_result, .is_error = true, .text = "read foo.zig\n→ no such file" },
        // A call whose tool decided no box line is the call row alone.
        .{ .kind = .tool_result, .is_error = false, .text = "Tool: describe_config" },
        // A wide-glyph box, to exercise the narrow-width row cap.
        .{ .kind = .user, .is_error = false, .text = "你好世界" },
    };
    // Includes widths narrower than a box's borders and the error prefix, where
    // `Sink.end`'s one-row assertion pins the renderers' clamps.
    const widths = [_]usize{ 16, 3, 2 };
    for (cases) |case| {
        var entry = try Entry.init(gpa, case.kind, case.is_error, case.text);
        defer entry.deinit(gpa);
        for (widths) |columns| {
            const painted = try renderedRows(gpa, &entry, columns, 0);
            try std.testing.expectEqual(entry.rows(columns), painted);
        }
    }
}

// The head names the marker once. The source row below it takes an indent, so no
// row repeats the tag and the two rows read as one block.
test "a skill entry names its head once and indents the rows below it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    var entry = try Entry.init(
        gpa,
        .skill,
        false,
        "zig-style · Size: 3.1 KB\nSource: .agents/skills/zig-style/SKILL.md",
    );
    defer entry.deinit(gpa);

    const sink = try view.beginFrame(.{ .columns = 40, .rows = 24 }, 8);
    try entry.render(&.{
        .sink = sink,
        .id = 0,
        .columns = 40,
        .base = 0,
        .skip = 0,
    });
    try view.render();

    try std.testing.expectEqual(@as(usize, 2), entry.rows(40));
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Skill: zig-style · Size: 3.1 KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "  Source: .agents/skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Skill: Source:") == null);
}

// The same padding everywhere: a copy of a reasoning row starts at the column a
// copy of a message box row starts at.
test "no box carries a pad, so a copy of the rows lines up" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    var user = try Entry.init(gpa, .user, false, "a user message that wraps over two rows");
    defer user.deinit(gpa);
    var thinking = try Entry.init(gpa, .thinking, false, "reasoning that wraps over two rows");
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

// A failed call names what went wrong and what to do about it, and the
// instruction sits at the end of that sentence. A cut there takes the half the
// user needs, so a failed box wraps while a successful one keeps one row a line.
test "a failed tool box wraps its detail and a successful one cuts it" {
    const gpa = std.testing.allocator;
    const columns = 20;
    const head = "Tool: edit · File: a.zig";
    const detail = "Error: Pith found old_text more than once. Add more text around it.";
    const text = head ++ "\n" ++ detail;

    var failed = try Entry.init(gpa, .tool_result, true, text);
    defer failed.deinit(gpa);
    var succeeded = try Entry.init(gpa, .tool_result, false, text);
    defer succeeded.deinit(gpa);

    // Two padding rows plus one row a line for the cut box.
    try std.testing.expectEqual(@as(usize, 4), succeeded.rows(columns));
    try std.testing.expect(failed.rows(columns) > succeeded.rows(columns));

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 24 }, 8);
    try failed.render(&.{ .sink = sink, .id = 0, .columns = columns, .base = 0, .skip = 0 });
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
    var failure = try Entry.init(gpa, .event, true, "boom");
    defer failure.deinit(gpa);
    var success = try Entry.init(gpa, .event, false, "all good");
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
