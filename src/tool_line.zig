const std = @import("std");

const core = @import("core");
const tools = @import("tools");

const format = @import("format.zig");
const ui = @import("ui/root.zig");

const mebibyte = 1024 * 1024;

const Line = union(enum) {
    measures: []u8,
    sentence: []const u8,
    none,

    pub fn deinit(self: *const Line, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .measures => |text| gpa.free(text),
            .sentence, .none => {},
        }
    }
};

const Parts = struct {
    writer: *std.Io.Writer,
    count: usize = 0,

    fn print(self: *Parts, comptime template: []const u8, args: anytype) !void {
        if (self.count > 0) try self.writer.writeAll(ui.paint.separator);
        try self.writer.print(template, args);
        self.count += 1;
    }
};

pub fn head(
    gpa: std.mem.Allocator,
    name: []const u8,
    description: *const tools.Registry.Description,
    roots: *const format.Roots,
) error{OutOfMemory}![]u8 {
    const subject = description.subject orelse return std.fmt.allocPrint(gpa, "Tool: {s}", .{name});
    const shown = switch (subject.kind) {
        .path => try format.path(gpa, subject.text, roots),
        .pattern, .command => try gpa.dupe(u8, subject.text),
    };
    defer gpa.free(shown);
    const line = singleLine(shown);
    if (line.len == 0) return std.fmt.allocPrint(gpa, "Tool: {s}", .{name});
    return std.fmt.allocPrint(gpa, "Tool: {s} · {s}: {s}", .{ name, label(subject.kind), line });
}

fn label(kind: tools.Registry.Description.Kind) []const u8 {
    return switch (kind) {
        .path => "File",
        .pattern => "Pattern",
        .command => "Command",
    };
}

fn singleLine(text: []u8) []u8 {
    var length: usize = 0;
    var blank = false;
    for (text) |byte| {
        if (byte == ' ' or byte <= 0x1f or byte == 0x7f) {
            blank = length != 0;
            continue;
        }
        if (blank) {
            text[length] = ' ';
            length += 1;
            blank = false;
        }
        text[length] = byte;
        length += 1;
    }
    return text[0..length];
}

pub fn render(gpa: std.mem.Allocator, output: *const core.Tool.Output) error{OutOfMemory}!Line {
    if (output.measures.count() > 0) return .{ .measures = try measures(gpa, output) };
    if (output.hasFailure()) return .{ .sentence = output.content };
    return .none;
}

fn measures(gpa: std.mem.Allocator, output: *const core.Tool.Output) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    write(&out.writer, output) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(writer: *std.Io.Writer, output: *const core.Tool.Output) !void {
    var parts: Parts = .{ .writer = writer };
    if (output.measures.get(.duration_ms)) |duration_ms| {
        var buffer: [24]u8 = undefined;
        try parts.print("Time: {s}", .{tools.format.duration(&buffer, @intCast(duration_ms))});
    }
    if (output.measures.get(.exit_code)) |code| try parts.print("Exit code: {d}", .{code});
    if (output.conditions.contains(.terminated)) try parts.print("Status: Terminated", .{});
    if (output.conditions.contains(.timed_out)) try parts.print("Status: Timed out", .{});
    if (output.conditions.contains(.overflowed)) try parts.print("Status: Output limit", .{});
    if (output.measures.get(.matches)) |count| try parts.print("Matches: {d}", .{count});
    try writeLines(&parts, output);
    if (output.conditions.contains(.time_limit_reached)) try parts.print("Search: Timed out", .{});
    if (output.conditions.contains(.match_limit_reached)) try parts.print("Limit: Reached", .{});
    if (output.conditions.contains(.byte_limit_reached)) {
        const bytes = output.measures.get(.bytes) orelse 0;
        try parts.print("Stopped at: {d} MiB", .{@divFloor(bytes, mebibyte)});
    }
    if (output.conditions.contains(.incomplete)) try parts.print("Search: Incomplete", .{});
    if (output.measures.get(.matches_omitted)) |count| {
        try parts.print("Omitted matches: {d}", .{count});
    }
    if (output.conditions.contains(.line_truncated)) try parts.print("Line: Truncated", .{});
    if (output.conditions.contains(.lines_truncated)) try parts.print("Lines: Truncated", .{});
    if (output.conditions.contains(.output_truncated)) try parts.print("Output: Truncated", .{});
}

fn writeLines(parts: *Parts, output: *const core.Tool.Output) !void {
    const removed = output.measures.get(.lines_removed);
    const added = output.measures.get(.lines_added);
    if (removed != null or added != null) {
        return parts.print("Lines: -{d} +{d}", .{ removed orelse 0, added orelse 0 });
    }
    const lines = output.measures.get(.lines) orelse return;
    const first = output.measures.get(.line_first) orelse 1;
    const total = output.measures.get(.lines_total) orelse lines;
    if (first == 1 and lines == total) return parts.print("Lines: {d}", .{lines});
    const last = first + lines -| 1;
    return parts.print("Lines: {d}\u{2013}{d} of {d}", .{ first, @max(first, last), total });
}

test "a read names its window, and a whole file or an empty file its count alone" {
    try expectLine(&.{
        .measures = &.{ .{ .lines, 1 }, .{ .line_first, 1 }, .{ .lines_total, 3 } },
        .expected = "Lines: 1\u{2013}1 of 3",
    });
    try expectLine(&.{
        .measures = &.{ .{ .lines, 50 }, .{ .line_first, 1 }, .{ .lines_total, 300 } },
        .expected = "Lines: 1\u{2013}50 of 300",
    });
    try expectLine(&.{
        .measures = &.{ .{ .lines, 3 }, .{ .line_first, 1 }, .{ .lines_total, 3 } },
        .expected = "Lines: 3",
    });
    try expectLine(&.{
        .measures = &.{ .{ .lines, 0 }, .{ .line_first, 1 }, .{ .lines_total, 0 } },
        .expected = "Lines: 0",
    });
    try expectLine(&.{
        .measures = &.{ .{ .lines, 2 }, .{ .line_first, 2 }, .{ .lines_total, 3 } },
        .conditions = &.{.line_truncated},
        .expected = "Lines: 2\u{2013}3 of 3 \u{00B7} Line: Truncated",
    });
}

const Case = struct {
    measures: []const struct { core.Tool.Measure, u64 } = &.{},
    conditions: []const core.Tool.Condition = &.{},
    expected: []const u8,
};

fn expectLine(case: *const Case) !void {
    const gpa = std.testing.allocator;
    var output: core.Tool.Output = .{};
    for (case.measures) |measure| output.measures.put(measure[0], measure[1]);
    for (case.conditions) |condition| output.conditions.insert(condition);
    const line = try render(gpa, &output);
    defer line.deinit(gpa);
    try std.testing.expectEqualStrings(case.expected, line.measures);
}

test "a write counts its lines, and an edit the removed and the added ones" {
    try expectLine(&.{ .measures = &.{.{ .lines, 3 }}, .expected = "Lines: 3" });
    try expectLine(&.{
        .measures = &.{ .{ .lines_removed, 2 }, .{ .lines_added, 1 } },
        .expected = "Lines: -2 +1",
    });
    try expectLine(&.{
        .measures = &.{ .{ .lines_removed, 1 }, .{ .lines_added, 0 } },
        .expected = "Lines: -1 +0",
    });
}

test "a search reports its time, its matches, and every reached limit" {
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 1500 }, .{ .matches, 1 }, .{ .matches_omitted, 2 } },
        .conditions = &.{.time_limit_reached},
        .expected = "Time: 1.5s \u{00B7} Matches: 1 \u{00B7} Search: Timed out \u{00B7} " ++
            "Omitted matches: 2",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 0 }, .{ .matches, 0 } },
        .conditions = &.{.incomplete},
        .expected = "Time: 0ms \u{00B7} Matches: 0 \u{00B7} Search: Incomplete",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 42 }, .{ .matches, 2 }, .{ .bytes, 300 * mebibyte } },
        .conditions = &.{ .match_limit_reached, .byte_limit_reached, .lines_truncated },
        .expected = "Time: 42ms \u{00B7} Matches: 2 \u{00B7} Limit: Reached \u{00B7} " ++
            "Stopped at: 300 MiB \u{00B7} Lines: Truncated",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 42 }, .{ .matches, 0 }, .{ .bytes, 5 } },
        .expected = "Time: 42ms \u{00B7} Matches: 0",
    });
}

test "a command reports its time, its exit code or its status, and its output" {
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 1500 }, .{ .exit_code, 0 }, .{ .lines, 3 } },
        .conditions = &.{.output_truncated},
        .expected = "Time: 1.5s \u{00B7} Exit code: 0 \u{00B7} Lines: 3 \u{00B7} Output: Truncated",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 10 }, .{ .exit_code, 3 }, .{ .lines, 1 } },
        .conditions = &.{.failed},
        .expected = "Time: 10ms \u{00B7} Exit code: 3 \u{00B7} Lines: 1",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 120_000 }, .{ .lines, 1 } },
        .conditions = &.{.timed_out},
        .expected = "Time: 2m 0s \u{00B7} Status: Timed out \u{00B7} Lines: 1",
    });
    try expectLine(&.{
        .measures = &.{.{ .duration_ms, 5 }},
        .conditions = &.{.terminated},
        .expected = "Time: 5ms \u{00B7} Status: Terminated",
    });
    try expectLine(&.{
        .measures = &.{.{ .duration_ms, 5 }},
        .conditions = &.{.overflowed},
        .expected = "Time: 5ms \u{00B7} Status: Output limit",
    });
}

test "a failed output without measures shows its sentence, and a bare output no line" {
    const gpa = std.testing.allocator;
    var failed: core.Tool.Output = .{ .content = "Drinky could not read a.txt." };
    failed.conditions.insert(.path_missing);
    const sentence = try render(gpa, &failed);
    defer sentence.deinit(gpa);
    try std.testing.expectEqualStrings("Drinky could not read a.txt.", sentence.sentence);

    const bare: core.Tool.Output = .{ .content = "# Drinky" };
    const none = try render(gpa, &bare);
    defer none.deinit(gpa);
    try std.testing.expect(none == .none);
}

test "a head names the subject of a call on one line" {
    const gpa = std.testing.allocator;
    const roots: format.Roots = .{
        .working_directory = "/home/you/work",
        .home_directory = "/home/you",
    };
    const cases = [_]struct {
        name: []const u8,
        subject: ?tools.Registry.Description.Subject,
        expected: []const u8,
    }{
        .{
            .name = "read",
            .subject = .{ .kind = .path, .text = "/home/you/work/src/App.zig" },
            .expected = "Tool: read · File: src/App.zig",
        },
        .{
            .name = "write",
            .subject = .{ .kind = .path, .text = "/home/you/.drinky/notes.md" },
            .expected = "Tool: write · File: ~/.drinky/notes.md",
        },
        .{
            .name = "edit",
            .subject = .{ .kind = .path, .text = "/etc/hosts" },
            .expected = "Tool: edit · File: /etc/hosts",
        },
        .{
            .name = "find",
            .subject = .{ .kind = .pattern, .text = "/home/you/work/**/*.zig" },
            .expected = "Tool: find · Pattern: /home/you/work/**/*.zig",
        },
        .{
            .name = "bash",
            .subject = .{ .kind = .command, .text = "cat <<'EOF'\n  one\n\n  two\nEOF" },
            .expected = "Tool: bash · Command: cat <<'EOF' one two EOF",
        },
        .{
            .name = "grep",
            .subject = .{ .kind = .pattern, .text = " \t " },
            .expected = "Tool: grep",
        },
        .{ .name = "describe_drinky", .subject = null, .expected = "Tool: describe_drinky" },
    };
    for (cases) |case| {
        const description: tools.Registry.Description = .{
            .subject = case.subject,
            .timeout_ms = null,
        };
        const text = try head(gpa, case.name, &description, &roots);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}
