//! The transcript-block model. `Entry` is a tagged union carrying exactly each
//! block's data: the plain blocks a byte buffer, the flagged ones a buffer plus
//! an error flag. It owns its bytes (`init`/`deinit`), measures itself (`rows`),
//! and paints itself (`render`) with the shared `paint` primitives. The model
//! block grows in place as its reply streams.

const std = @import("std");

const terminal = @import("terminal");

const paint = @import("paint.zig");

pub const Entry = union(enum) {
    intro: std.ArrayList(u8),
    user: std.ArrayList(u8),
    thinking: std.ArrayList(u8),
    model: std.ArrayList(u8),
    tool_result: Flagged,
    feedback: Flagged,

    pub const Flagged = struct { text: std.ArrayList(u8), is_error: bool };
    pub const Kind = std.meta.Tag(Entry);

    /// A new block owning a copy of `text`; `is_error` is ignored by the plain
    /// variants.
    pub fn init(gpa: std.mem.Allocator, kind: Kind, is_error: bool, text: []const u8) !Entry {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, text);
        return switch (kind) {
            .intro => .{ .intro = list },
            .user => .{ .user = list },
            .thinking => .{ .thinking = list },
            .model => .{ .model = list },
            .tool_result => .{ .tool_result = .{ .text = list, .is_error = is_error } },
            .feedback => .{ .feedback = .{ .text = list, .is_error = is_error } },
        };
    }

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .intro, .user, .thinking, .model => |*text| text.deinit(gpa),
            .tool_result, .feedback => |*flagged| flagged.text.deinit(gpa),
        }
    }

    /// The physical rows this block wraps to at `columns`, its leading separator
    /// excluded. Must equal exactly what `render` emits — the parity the diff
    /// and window math rely on.
    pub fn rows(self: *const Entry, columns: usize) usize {
        return switch (self.*) {
            .intro => |text| std.mem.count(u8, text.items, "\n") + 1,
            .feedback => |flagged| std.mem.count(u8, flagged.text.items, "\n") + 1,
            .user => |text| paint.boxRows(text.items, columns),
            .tool_result => |flagged| paint.boxRows(flagged.text.items, columns),
            .thinking, .model => |text| terminal.width.rows(text.items, @max(columns, 1)),
        };
    }

    /// Compose this block's rows through `placement`, dropping its top `skip`
    /// rows (nonzero only for the clip).
    pub fn render(self: *const Entry, placement: *const paint.Placement) !void {
        switch (self.*) {
            .intro => |text| try paint.notice(placement, &.{ .style = .dim, .prefix = "" }, text.items),
            .feedback => |flagged| try paint.notice(placement, &.{
                .style = if (flagged.is_error) .red else .dim,
                .prefix = if (flagged.is_error) "error: " else "",
            }, flagged.text.items),
            .user => |text| try paint.box(placement, &.{
                .background = .user_background,
                .foreground = .user_foreground,
            }, text.items),
            .tool_result => |flagged| try paint.box(placement, &.{
                .background = if (flagged.is_error) .tool_error_background else .tool_success_background,
                .foreground = .tool_foreground,
            }, flagged.text.items),
            .thinking => |text| try paint.wrapped(placement, .dim, text.items),
            .model => |text| try paint.wrapped(placement, null, text.items),
        }
    }
};

// Physical rows in a fresh paint: the view joins its inert rows with `\r\n`,
// and row text cannot emit those separators, so they count physical rows.
fn paintedRows(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\r\n") + 1;
}

// Rows `entry` paints into a fresh view, dropping its top `skip`. Fresh so the
// paint is a full reprint whose rows `paintedRows` can count. The window is tall
// enough that only `skip` clips.
fn renderedRows(gpa: std.mem.Allocator, entry: *const Entry, columns: usize, skip: usize) !usize {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 100 }, 8);
    const placement: paint.Placement = .{ .sink = sink, .id = 0, .columns = columns, .base = 0, .skip = skip };
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
        .{ .kind = .feedback, .is_error = false, .text = "first\nsecond\nthird" },
        .{ .kind = .feedback, .is_error = true, .text = "boom" },
        .{ .kind = .user, .is_error = false, .text = "a user message long enough to wrap across the narrow test width more than once" },
        .{ .kind = .model, .is_error = false, .text = "model reply\nwith a blank\n\nthen a long paragraph that must wrap several rows" },
        .{ .kind = .thinking, .is_error = false, .text = "reasoning that runs on\n\nlong enough to wrap across the narrow test width more than once" },
        .{ .kind = .tool_result, .is_error = true, .text = "read foo.zig\n→ no such file" },
        // A wide-glyph box, to exercise the narrow-width row cap.
        .{ .kind = .user, .is_error = false, .text = "你好世界" },
    };
    // Includes widths narrower than a box's borders and the error prefix, where
    // `Sink.end`'s one-row assertion pins the renderers' clamps.
    const widths = [_]usize{ 16, 3, 2 };
    for (cases) |case| {
        var entry = try Entry.init(gpa, case.kind, case.is_error, case.text);
        defer entry.deinit(gpa);
        for (widths) |columns|
            try std.testing.expectEqual(entry.rows(columns), try renderedRows(gpa, &entry, columns, 0));
    }
}

// The clip drops its top `skip` rows and shows the rest; skip 0 shows all.
test "a clipped block shows its bottom rows" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..40) |i| {
        if (i > 0) try text.append(gpa, '\n');
        var buffer: [8]u8 = undefined;
        try text.appendSlice(gpa, std.fmt.bufPrint(&buffer, "L{d}", .{i}) catch unreachable);
    }
    const entry: Entry = .{ .model = text };
    const columns = 20;
    try std.testing.expectEqual(@as(usize, 40), entry.rows(columns));
    try std.testing.expectEqual(@as(usize, 40), try renderedRows(gpa, &entry, columns, 0));
    try std.testing.expectEqual(@as(usize, 15), try renderedRows(gpa, &entry, columns, 25));
}

// Bounded memory: streaming a clipped block into a frame warmed to its full
// size neither allocates nor grows a buffer — the clip's hidden top is never
// materialized.
test "a clipped block streams into a warmed frame without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..60) |i| {
        if (i > 0) try text.append(std.testing.allocator, '\n');
        var buffer: [8]u8 = undefined;
        try text.appendSlice(std.testing.allocator, std.fmt.bufPrint(&buffer, "L{d}", .{i}) catch unreachable);
    }
    const entry: Entry = .{ .model = text };
    const columns = 20;

    // Warm both frames and the output at the block's full size.
    for (0..2) |_| {
        const sink = try view.beginFrame(.{ .columns = columns, .rows = 100 }, 8);
        const placement: paint.Placement = .{ .sink = sink, .id = 0, .columns = columns, .base = 0, .skip = 0 };
        try entry.render(&placement);
        try view.render();
    }

    // Arm: any further allocation or growth now fails.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    const sink = try view.beginFrame(.{ .columns = columns, .rows = 100 }, 8);
    const placement: paint.Placement = .{ .sink = sink, .id = 0, .columns = columns, .base = 0, .skip = 30 };
    try entry.render(&placement);
    try view.render();
}
