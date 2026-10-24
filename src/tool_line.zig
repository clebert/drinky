const std = @import("std");
const application = @import("application");
const format = @import("format.zig");

const core = @import("core");
const tools = @import("tools");

const ui = @import("ui/root.zig");

pub const Line = struct {
    text: []u8,
    segment_ends: []usize,
    status: ui.paint.Mark,
    qualifiers: []ui.paint.Mark,
    command: ?ui.paint.Box.Range,

    pub fn deinit(self: *const Line, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.segment_ends);
        gpa.free(self.qualifiers);
    }
};

pub const Phase = enum { streaming, queued, running };

const State = enum { streaming, queued, running, complete, partial, canceled, failed };

pub const Options = struct {
    name: []const u8,
    phase: Phase = .running,
    subject: []const u8 = "",
    subject_kind: ?application.ToolDescription.Kind = null,
    output: ?*const application.ToolOutput = null,
    elapsed_ms: ?i64 = null,
    timeout_ms: ?u64 = null,
    received_bytes: ?usize = null,
};

const Parts = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    segment_ends: *std.ArrayList(usize),
    qualifiers: *std.ArrayList(ui.paint.Mark),
    status: ui.paint.Mark = undefined,
    command: ?ui.paint.Box.Range = null,

    fn print(self: *Parts, comptime template: []const u8, args: anytype) !void {
        if (self.segment_ends.items.len > 0) try self.writer.writeAll(ui.paint.separator);
        try self.writer.print(template, args);
        try self.segment_ends.append(self.gpa, self.writer.buffered().len);
    }

    fn warn(self: *Parts, comptime template: []const u8, args: anytype) !void {
        const start = self.writer.buffered().len +
            if (self.segment_ends.items.len > 0) ui.paint.separator.len else 0;
        try self.print(template, args);
        try self.qualifiers.append(self.gpa, .{
            .start = start,
            .end = self.writer.buffered().len,
            .role = .warning,
            .dim = true,
        });
    }
};

pub fn subject(
    gpa: std.mem.Allocator,
    description: *const application.ToolDescription,
    roots: *const format.Roots,
) error{OutOfMemory}![]u8 {
    const value = description.subject orelse return gpa.dupe(u8, "");
    if (value.kind == .command) return gpa.dupe(u8, value.text);
    const shown = switch (value.kind) {
        .path => try format.path(gpa, value.text, roots),
        .pattern => try gpa.dupe(u8, value.text),
        .command => unreachable,
    };
    defer gpa.free(shown);
    const line = format.singleLine(shown);
    if (line.len == 0) return gpa.dupe(u8, "");
    return gpa.print("{s}: {s}", .{
        switch (value.kind) {
            .path => "File",
            .pattern => "Pattern",
            .command => unreachable,
        },
        line,
    });
}

pub fn render(gpa: std.mem.Allocator, options: *const Options) error{OutOfMemory}!Line {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    var qualifiers: std.ArrayList(ui.paint.Mark) = .empty;
    defer qualifiers.deinit(gpa);
    var parts: Parts = .{
        .gpa = gpa,
        .writer = &out.writer,
        .segment_ends = &ends,
        .qualifiers = &qualifiers,
    };
    write(&parts, options) catch return error.OutOfMemory;
    const text = try out.toOwnedSlice();
    errdefer gpa.free(text);
    const segment_ends = try ends.toOwnedSlice(gpa);
    errdefer gpa.free(segment_ends);
    return .{
        .text = text,
        .segment_ends = segment_ends,
        .status = parts.status,
        .qualifiers = try qualifiers.toOwnedSlice(gpa),
        .command = parts.command,
    };
}

fn write(parts: *Parts, options: *const Options) !void {
    const state: State = if (options.output) |output|
        if (output.conditions.contains(.canceled))
            .canceled
        else if (output.hasFailure())
            .failed
        else if (partial(output)) .partial else .complete
    else switch (options.phase) {
        .streaming => .streaming,
        .queued => .queued,
        .running => .running,
    };
    const name = try parts.gpa.dupe(u8, options.name);
    defer parts.gpa.free(name);
    const shown_name = format.singleLine(name);
    try parts.print("Tool: {s} ({s})", .{ shown_name, @tagName(state) });
    parts.status = .{
        .start = 0,
        .end = parts.writer.buffered().len,
        .dim = true,
        .role = switch (state) {
            .streaming, .queued, .running => .activity,
            .complete => .success,
            .partial, .canceled => .warning,
            .failed => .@"error",
        },
    };
    if (options.elapsed_ms) |elapsed_ms| {
        var buffer: [24]u8 = undefined;
        const shown = if (options.output == null)
            format.durationSeconds(&buffer, elapsed_ms, .down)
        else
            application.support.duration(&buffer, elapsed_ms);
        try parts.print("Time: {s}", .{shown});
    } else if (options.output) |output| {
        if (output.measures.get(.duration_ms)) |duration_ms| {
            var buffer: [24]u8 = undefined;
            try parts.print(
                "Time: {s}",
                .{application.support.duration(&buffer, @intCast(duration_ms))},
            );
        }
    }
    if (options.output) |output| {
        if (output.measures.get(.exit_code)) |code| try parts.print("Exit code: {d}", .{code});
    }
    const command = options.subject_kind == .command;
    if (!command and options.subject.len > 0) try parts.print("{s}", .{options.subject});
    if (options.output) |output| {
        if (output.conditions.contains(.terminated)) try parts.print("Status: terminated", .{});
        if (output.conditions.contains(.timed_out)) try parts.print("Status: timed out", .{});
        if (output.conditions.contains(.overflowed)) try parts.print("Status: output limit", .{});
        try writeStops(parts, output);
        if (output.measures.get(.entries_unread)) |count| try parts.warn(
            "Unreadable: {d} {s}",
            .{ count, application.support.entryNoun(count) },
        );
        if (output.measures.get(.files_oversized)) |count| try parts.warn(
            "Skipped: {d} large file{s}",
            .{ count, application.support.pluralSuffix(count) },
        );
        if (output.conditions.contains(.line_truncated)) try parts.print("Line: truncated", .{});
        if (output.conditions.contains(.lines_truncated)) try parts.print("Lines: truncated", .{});
        if (output.conditions.contains(.output_truncated)) {
            try parts.print("Output: truncated", .{});
        }
        if (output.measures.get(.matches)) |count| try parts.print("Matches: {d}", .{count});
        try writeLines(parts, output);
        if (output.measures.get(.matches_omitted)) |count| {
            try parts.print("Omitted matches: {d}", .{count});
        }
    }
    if (options.received_bytes) |bytes| {
        var buffer: [16]u8 = undefined;
        try parts.print("Received: {s}", .{format.bytes(&buffer, bytes)});
    }
    if (options.timeout_ms) |timeout_ms| {
        var buffer: [24]u8 = undefined;
        try parts.print("Timeout: {s}", .{
            format.durationSeconds(&buffer, @intCast(timeout_ms), .up),
        });
    }
    if (command) {
        const start = parts.writer.buffered().len + 1;
        try parts.writer.print("\n{s}", .{options.subject});
        parts.command = .{ .start = start, .end = parts.writer.buffered().len };
    }
    if (options.output) |output| {
        if (state == .failed and output.measures.count() == 0) {
            try parts.writer.print("\nError: {s}", .{output.content});
        }
    }
}

const stops = [_]struct { condition: application.ToolCondition, name: []const u8 }{
    .{ .condition = .time_limit_reached, .name = "time limit" },
    .{ .condition = .tree_limit_reached, .name = "tree limit" },
    .{ .condition = .byte_limit_reached, .name = "byte limit" },
    .{ .condition = .match_limit_reached, .name = "match limit" },
};

fn partial(output: *const application.ToolOutput) bool {
    if (output.conditions.contains(.incomplete)) return true;
    for (stops) |stop| {
        if (output.conditions.contains(stop.condition)) return true;
    }
    return false;
}

fn writeStops(parts: *Parts, output: *const application.ToolOutput) !void {
    var buffer: [64]u8 = undefined;
    var names: std.Io.Writer = .fixed(&buffer);
    for (stops) |stop| {
        if (!output.conditions.contains(stop.condition)) continue;
        if (names.buffered().len > 0) names.writeAll(", ") catch unreachable;
        names.writeAll(stop.name) catch unreachable;
    }
    if (names.buffered().len > 0) try parts.warn("Stopped: {s}", .{names.buffered()});
}

fn writeLines(parts: *Parts, output: *const application.ToolOutput) !void {
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
        .expected = "Line: truncated \u{00B7} Lines: 2\u{2013}3 of 3",
    });
}

const Case = struct {
    name: []const u8 = "read",
    state: []const u8 = "complete",
    measures: []const struct { core.Tool.Measure, u64 } = &.{},
    conditions: []const core.Tool.Condition = &.{},
    expected: []const u8,
};

fn expectLine(case: *const Case) !void {
    const gpa = std.testing.allocator;
    var output: core.Tool.Output = .{};
    for (case.measures) |measure| output.measures.put(measure[0], measure[1]);
    for (case.conditions) |condition| output.conditions.insert(condition);
    const line = try render(gpa, &.{ .name = case.name, .output = &output });
    defer line.deinit(gpa);
    const expected = try gpa.print("Tool: {s} ({s}) · {s}", .{
        case.name,
        case.state,
        case.expected,
    });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, line.text);
}

test "a write counts its lines, and an edit the removed and the added ones" {
    try expectLine(&.{ .name = "write", .measures = &.{.{ .lines, 3 }}, .expected = "Lines: 3" });
    try expectLine(&.{
        .name = "edit",
        .measures = &.{ .{ .lines_removed, 2 }, .{ .lines_added, 1 } },
        .expected = "Lines: -2 +1",
    });
    try expectLine(&.{
        .name = "edit",
        .measures = &.{ .{ .lines_removed, 1 }, .{ .lines_added, 0 } },
        .expected = "Lines: -1 +0",
    });
}

test "a search reports its time, its matches, and every reached limit" {
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 1500 }, .{ .matches, 1 }, .{ .matches_omitted, 2 } },
        .name = "grep",
        .state = "partial",
        .conditions = &.{.time_limit_reached},
        .expected = "Time: 1.5s \u{00B7} Stopped: time limit \u{00B7} Matches: 1 \u{00B7} " ++
            "Omitted matches: 2",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 0 }, .{ .matches, 0 } },
        .name = "find",
        .state = "partial",
        .conditions = &.{.tree_limit_reached},
        .expected = "Time: 0ms \u{00B7} Stopped: tree limit \u{00B7} Matches: 0",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 42 }, .{ .matches, 2 } },
        .name = "grep",
        .state = "partial",
        .conditions = &.{ .match_limit_reached, .byte_limit_reached, .lines_truncated },
        .expected = "Time: 42ms \u{00B7} Stopped: byte limit, match limit \u{00B7} " ++
            "Lines: truncated \u{00B7} Matches: 2",
    });
    try expectLine(&.{
        .measures = &.{
            .{ .duration_ms, 42 },
            .{ .matches, 0 },
            .{ .entries_unread, 1 },
            .{ .files_oversized, 2 },
        },
        .name = "grep",
        .state = "partial",
        .conditions = &.{.incomplete},
        .expected = "Time: 42ms \u{00B7} Unreadable: 1 entry \u{00B7} " ++
            "Skipped: 2 large files \u{00B7} Matches: 0",
    });
    try expectLine(&.{
        .name = "find",
        .measures = &.{ .{ .duration_ms, 42 }, .{ .matches, 0 } },
        .expected = "Time: 42ms \u{00B7} Matches: 0",
    });
}

test "a search that stops early names its state in yellow" {
    const gpa = std.testing.allocator;
    var stopped: core.Tool.Output = .{ .content = "Drinky stopped the search." };
    stopped.measures.put(.duration_ms, 10_000);
    stopped.measures.put(.matches, 0);
    stopped.measures.put(.entries_unread, 3);
    stopped.conditions.insert(.time_limit_reached);
    stopped.conditions.insert(.incomplete);
    const line = try render(gpa, &.{
        .name = "grep",
        .subject = "Pattern: foobar",
        .output = &stopped,
    });
    defer line.deinit(gpa);
    try std.testing.expectEqualStrings(
        "Tool: grep (partial) · Time: 10.0s · Pattern: foobar · Stopped: time limit · " ++
            "Unreadable: 3 entries · Matches: 0",
        line.text,
    );
    try std.testing.expectEqual(.warning, line.status.role);
}

test "a command reports its time, its exit code or its status, and its output" {
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 1500 }, .{ .exit_code, 0 }, .{ .lines, 3 } },
        .name = "bash",
        .conditions = &.{.output_truncated},
        .expected = "Time: 1.5s \u{00B7} Exit code: 0 \u{00B7} Output: truncated \u{00B7} Lines: 3",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 10 }, .{ .exit_code, 3 }, .{ .lines, 1 } },
        .name = "bash",
        .conditions = &.{.failed},
        .state = "failed",
        .expected = "Time: 10ms \u{00B7} Exit code: 3 \u{00B7} Lines: 1",
    });
    try expectLine(&.{
        .measures = &.{ .{ .duration_ms, 120_000 }, .{ .lines, 1 } },
        .name = "bash",
        .conditions = &.{.timed_out},
        .state = "failed",
        .expected = "Time: 2m 0s \u{00B7} Status: timed out \u{00B7} Lines: 1",
    });
    try expectLine(&.{
        .measures = &.{.{ .duration_ms, 5 }},
        .name = "bash",
        .conditions = &.{.terminated},
        .state = "failed",
        .expected = "Time: 5ms \u{00B7} Status: terminated",
    });
    try expectLine(&.{
        .measures = &.{.{ .duration_ms, 5 }},
        .name = "bash",
        .conditions = &.{.overflowed},
        .state = "failed",
        .expected = "Time: 5ms \u{00B7} Status: output limit",
    });
}

test "a canceled call names its state in yellow and shows no error sentence" {
    const gpa = std.testing.allocator;
    var canceled: core.Tool.Output = .{ .content = "The user canceled the call." };
    canceled.conditions.insert(.canceled);
    const line = try render(gpa, &.{
        .name = "grep",
        .subject = "Pattern: x",
        .output = &canceled,
    });
    defer line.deinit(gpa);
    try std.testing.expectEqualStrings("Tool: grep (canceled) · Pattern: x", line.text);
    try std.testing.expectEqual(.warning, line.status.role);
}

test "a failed output keeps its error sentence and a bare output only its completed identity" {
    const gpa = std.testing.allocator;
    var failed: core.Tool.Output = .{ .content = "Drinky could not read a.txt." };
    failed.conditions.insert(.path_missing);
    const sentence = try render(gpa, &.{ .name = "read", .output = &failed });
    defer sentence.deinit(gpa);
    try std.testing.expectEqualStrings(
        "Tool: read (failed)\nError: Drinky could not read a.txt.",
        sentence.text,
    );

    const bare: core.Tool.Output = .{ .content = "# Drinky" };
    const line = try render(gpa, &.{ .name = "describe_drinky", .output = &bare });
    defer line.deinit(gpa);
    try std.testing.expectEqualStrings("Tool: describe_drinky (complete)", line.text);
}

test "a tool names its subject and preserves each command line below its metadata" {
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
            .expected = "Tool: read (running) · File: src/App.zig",
        },
        .{
            .name = "write",
            .subject = .{ .kind = .path, .text = "/home/you/.drinky/notes.md" },
            .expected = "Tool: write (running) · File: ~/.drinky/notes.md",
        },
        .{
            .name = "edit",
            .subject = .{ .kind = .path, .text = "/etc/hosts" },
            .expected = "Tool: edit (running) · File: /etc/hosts",
        },
        .{
            .name = "find",
            .subject = .{ .kind = .pattern, .text = "/home/you/work/**/*.zig" },
            .expected = "Tool: find (running) · Pattern: /home/you/work/**/*.zig",
        },
        .{
            .name = "bash",
            .subject = .{ .kind = .command, .text = "cat <<'EOF'\n  one\n\n  two\nEOF" },
            .expected = "Tool: bash (running)\ncat <<'EOF'\n  one\n\n  two\nEOF",
        },
        .{
            .name = "grep",
            .subject = .{ .kind = .pattern, .text = " \t " },
            .expected = "Tool: grep (running)",
        },
        .{
            .name = "describe_drinky",
            .subject = null,
            .expected = "Tool: describe_drinky (running)",
        },
    };
    for (cases) |case| {
        const description: tools.Registry.Description = .{
            .subject = case.subject,
            .timeout_ms = null,
        };
        const shown = try subject(gpa, &description, &roots);
        defer gpa.free(shown);
        const line = try render(gpa, &.{
            .name = case.name,
            .subject = shown,
            .subject_kind = if (case.subject) |value| value.kind else null,
        });
        defer line.deinit(gpa);
        try std.testing.expectEqualStrings(case.expected, line.text);
    }
}
