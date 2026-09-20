const std = @import("std");

const format = @import("../format.zig");
const json = @import("../json.zig");
const llm = @import("../llm.zig");

pub const Context = @import("Context.zig");
pub const Result = @import("Result.zig");
pub const SkillGuard = @import("SkillGuard.zig");

const read = @import("read.zig");
const write = @import("write.zig");
const edit = @import("edit.zig");
const find = @import("find.zig");
const grep = @import("grep.zig");
const bash = @import("bash.zig");
const describe_drinky = @import("describe_drinky.zig");
const search = @import("search.zig");

pub const read_lines_max = read.lines_max;
pub const read_bytes_max = read.bytes_max;

const Entry = struct {
    tool: llm.Tool,
    run: *const fn (*const Context, []const u8) anyerror!Result,
    mutates: bool,
    subject: []const u8 = "",
    subject_label: []const u8 = "",
    subject_is_path: bool = false,
    timeout: Timeout = .none,

    const Timeout = union(enum) {
        none,
        argument: []const u8,
        fixed: u64,

        fn defaultMs(self: Timeout, configured_ms: u64) ?u64 {
            return switch (self) {
                .none => null,
                .argument => Context.Bash.clampTimeoutMs(configured_ms),
                .fixed => |fixed_ms| fixed_ms,
            };
        }

        fn argumentName(self: Timeout) ?[]const u8 {
            return switch (self) {
                .argument => |name| name,
                else => null,
            };
        }
    };
};

const registry = [_]Entry{
    .{
        .tool = read.spec,
        .run = read.run,
        .mutates = false,
        .subject = "path",
        .subject_label = "File",
        .subject_is_path = true,
    },
    .{
        .tool = write.spec,
        .run = write.run,
        .mutates = true,
        .subject = "path",
        .subject_label = "File",
        .subject_is_path = true,
    },
    .{
        .tool = edit.spec,
        .run = edit.run,
        .mutates = true,
        .subject = "path",
        .subject_label = "File",
        .subject_is_path = true,
    },
    .{
        .tool = find.spec,
        .run = find.run,
        .mutates = false,
        .subject = "pattern",
        .subject_label = "Pattern",
        .timeout = .{ .fixed = search.timeout_ms },
    },
    .{
        .tool = grep.spec,
        .run = grep.run,
        .mutates = false,
        .subject = "pattern",
        .subject_label = "Pattern",
        .timeout = .{ .fixed = search.timeout_ms },
    },
    .{
        .tool = bash.spec,
        .run = bash.run,
        .mutates = true,
        .subject = "command",
        .subject_label = "Command",
        .timeout = .{ .argument = "timeout_seconds" },
    },
    .{ .tool = describe_drinky.spec, .run = describe_drinky.run, .mutates = false },
};

pub const specs = blk: {
    var list: [registry.len]llm.Tool = undefined;
    for (registry, 0..) |entry, index| list[index] = entry.tool;
    break :blk list;
};

pub fn mutates(name: []const u8) bool {
    for (registry) |entry| {
        if (std.mem.eql(u8, name, entry.tool.name)) return entry.mutates;
    }
    return false;
}

pub const Call = struct {
    label: []const u8,
    subject: []u8,
    timeout_ms: ?u64,

    pub fn deinit(self: *const Call, gpa: std.mem.Allocator) void {
        gpa.free(self.subject);
    }
};

pub fn describe(
    gpa: std.mem.Allocator,
    name: []const u8,
    input_json: []const u8,
    roots: *const format.Roots,
    default_timeout_ms: u64,
) !Call {
    const entry = for (registry) |candidate| {
        if (std.mem.eql(u8, name, candidate.tool.name)) break candidate;
    } else return unnamed(gpa, null);
    const default_ms = entry.timeout.defaultMs(default_timeout_ms);
    if (entry.subject.len == 0 and default_ms == null) return unnamed(gpa, null);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = (try json.parseObject(arena.allocator(), input_json)) orelse
        return unnamed(gpa, default_ms);

    const timeout_ms = readTimeoutMs(&entry, &parsed, default_timeout_ms);
    if (entry.subject.len == 0) return unnamed(gpa, timeout_ms);
    const value = json.string(parsed.get(entry.subject)) orelse return unnamed(gpa, timeout_ms);

    const text = if (entry.subject_is_path)
        try format.path(gpa, value, roots)
    else
        try gpa.dupe(u8, value);
    errdefer gpa.free(text);
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
    const subject = try gpa.realloc(text, length);
    return .{
        .label = if (subject.len == 0) "" else entry.subject_label,
        .subject = subject,
        .timeout_ms = timeout_ms,
    };
}

fn unnamed(gpa: std.mem.Allocator, timeout_ms: ?u64) !Call {
    return .{ .label = "", .subject = try gpa.dupe(u8, ""), .timeout_ms = timeout_ms };
}

fn readTimeoutMs(
    entry: *const Entry,
    parsed: *const std.json.ObjectMap,
    default_timeout_ms: u64,
) ?u64 {
    const default_ms = entry.timeout.defaultMs(default_timeout_ms);
    const argument = entry.timeout.argumentName() orelse return default_ms;
    const raw = parsed.get(argument) orelse return default_ms;
    if (raw == .null) return default_ms;
    const seconds = unsignedSeconds(raw) orelse return null;
    return Context.Bash.clampTimeoutMs(seconds *| std.time.ms_per_s);
}

fn unsignedSeconds(raw: std.json.Value) ?u64 {
    return switch (raw) {
        .integer => |found| if (found < 0) null else @intCast(found),
        .number_string => |found| std.fmt.parseInt(u64, found, 10) catch null,
        else => null,
    };
}

pub fn run(context: *const Context, name: []const u8, input_json: []const u8) !Result {
    for (registry) |entry| {
        if (!std.mem.eql(u8, name, entry.tool.name)) continue;
        return entry.run(context, input_json) catch |err| switch (err) {
            error.InvalidArguments => try Result.report(
                context.gpa,
                .err,
                "Drinky received invalid arguments for the {s} tool.",
                .{name},
            ),
            else => return err,
        };
    }
    return Result.report(
        context.gpa,
        .err,
        "Drinky does not recognize the tool {s}.",
        .{name},
    );
}

test "mutating tools are marked, read-only tools are not" {
    try std.testing.expect(mutates("write"));
    try std.testing.expect(mutates("edit"));
    try std.testing.expect(mutates("bash"));
    try std.testing.expect(!mutates("read"));
    try std.testing.expect(!mutates("grep"));
    try std.testing.expect(!mutates("nope"));
}

test "unknown tool is an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "nope", "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

test "invalid arguments are reported, not raised" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "read", "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

test describe {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        label: []const u8,
        subject: []const u8,
    }{
        .{
            .name = "read",
            .input = "{\"path\":\"src/App.zig\"}",
            .label = "File",
            .subject = "src/App.zig",
        },
        .{
            .name = "write",
            .input = "{\"path\":\"a.zig\",\"content\":\"x\"}",
            .label = "File",
            .subject = "a.zig",
        },
        .{
            .name = "edit",
            .input = "{\"path\":\"a.zig\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            .label = "File",
            .subject = "a.zig",
        },
        .{ .name = "find", .input = "{\"pattern\":\"*.zig\"}", .label = "Pattern", .subject = "*.zig" },
        .{
            .name = "grep",
            .input = "{\"pattern\":\"columns\"}",
            .label = "Pattern",
            .subject = "columns",
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"zig build\"}",
            .label = "Command",
            .subject = "zig build",
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"cat <<'EOF'\\n  one\\n\\n  two\\nEOF\"}",
            .label = "Command",
            .subject = "cat <<'EOF' one two EOF",
        },
        .{ .name = "describe_drinky", .input = "{}", .label = "", .subject = "" },
        .{ .name = "write", .input = "{\"path\":\"a.zig\",\"conte", .label = "", .subject = "" },
        .{ .name = "read", .input = "{\"offset\":3}", .label = "", .subject = "" },
        .{ .name = "nonesuch", .input = "{\"path\":\"a.zig\"}", .label = "", .subject = "" },
        .{ .name = "grep", .input = "{\"pattern\":\"  \"}", .label = "", .subject = "" },
    };
    for (cases) |case| {
        const call = try describe(gpa, case.name, case.input, &.{}, 120_000);
        defer call.deinit(gpa);
        try std.testing.expectEqualStrings(case.label, call.label);
        try std.testing.expectEqualStrings(case.subject, call.subject);
        try std.testing.expectEqual(call.subject.len == 0, call.label.len == 0);
    }
}

test "a path subject shortens, and a pattern or a command does not" {
    const gpa = std.testing.allocator;
    const roots: format.Roots = .{
        .working_directory = "/home/you/work",
        .home_directory = "/home/you",
    };
    const cases = [_]struct { name: []const u8, input: []const u8, expected: []const u8 }{
        .{
            .name = "read",
            .input = "{\"path\":\"/home/you/work/src/App.zig\"}",
            .expected = "src/App.zig",
        },
        .{
            .name = "write",
            .input = "{\"path\":\"/home/you/.drinky/notes.md\"}",
            .expected = "~/.drinky/notes.md",
        },
        .{ .name = "edit", .input = "{\"path\":\"/etc/hosts\"}", .expected = "/etc/hosts" },
        .{
            .name = "find",
            .input = "{\"pattern\":\"/home/you/work/**/*.zig\"}",
            .expected = "/home/you/work/**/*.zig",
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"ls /home/you/work\"}",
            .expected = "ls /home/you/work",
        },
    };
    for (cases) |case| {
        const call = try describe(gpa, case.name, case.input, &roots, 120_000);
        defer call.deinit(gpa);
        try std.testing.expectEqualStrings(case.expected, call.subject);
    }
}

test "a described call reports the timeout it runs under" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { name: []const u8, input: []const u8, expected: ?u64 }{
        .{ .name = "bash", .input = "{\"command\":\"true\"}", .expected = 120_000 },
        .{
            .name = "bash",
            .input = "{\"command\":\"true\",\"timeout_seconds\":5}",
            .expected = 5_000,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"true\",\"timeout_seconds\":0}",
            .expected = Context.Bash.timeout_ms_min,
        },
        .{ .name = "find", .input = "{\"pattern\":\"*.zig\"}", .expected = search.timeout_ms },
        .{
            .name = "grep",
            .input = "{\"pattern\":\"x\",\"timeout_seconds\":5}",
            .expected = search.timeout_ms,
        },
        .{ .name = "read", .input = "{\"path\":\"a\"}", .expected = null },
        .{ .name = "nonesuch", .input = "{}", .expected = null },
        .{ .name = "bash", .input = "{\"comm", .expected = 120_000 },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":-5}",
            .expected = null,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":\"5\"}",
            .expected = null,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":null}",
            .expected = 120_000,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":9223372036854775807}",
            .expected = Context.Bash.timeout_ms_max,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":18446744073709551615}",
            .expected = Context.Bash.timeout_ms_max,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":1.5}",
            .expected = null,
        },
    };
    for (cases) |case| {
        const call = try describe(gpa, case.name, case.input, &.{}, 120_000);
        defer call.deinit(gpa);
        try std.testing.expectEqual(case.expected, call.timeout_ms);
    }
}

test "an absurd configured timeout clamps on every fallback path" {
    const gpa = std.testing.allocator;
    const inputs = [_][]const u8{
        "{\"command\":\"x\"}",
        "{\"command\":\"x\",\"timeout_seconds\":null}",
        "{\"comm",
    };
    for (inputs) |input| {
        const call = try describe(gpa, "bash", input, &.{}, std.math.maxInt(u64));
        defer call.deinit(gpa);
        try std.testing.expectEqual(@as(?u64, Context.Bash.timeout_ms_max), call.timeout_ms);
    }
    const call = try describe(gpa, "bash", "{\"command\":\"x\"}", &.{}, 0);
    defer call.deinit(gpa);
    try std.testing.expectEqual(@as(?u64, Context.Bash.timeout_ms_min), call.timeout_ms);
}

test "every subject carries a label and every label a subject" {
    for (registry) |entry| {
        try std.testing.expectEqual(entry.subject.len == 0, entry.subject_label.len == 0);
    }
}
