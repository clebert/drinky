const std = @import("std");

const core = @import("core");

const bash = @import("bash.zig");
const Context = @import("Context.zig");
const describe_drinky = @import("describe_drinky.zig");
const edit = @import("edit.zig");
const find = @import("find.zig");
const grep = @import("grep.zig");
const output = @import("output.zig");
const read = @import("read.zig");
const search = @import("search.zig");
const SkillGuard = @import("SkillGuard.zig");
const testing = @import("testing.zig");
const write = @import("write.zig");

const Registry = @This();

host: Context.Host,
skill_guard: ?*SkillGuard = null,

const Entry = struct {
    tool: core.Tool,
    run: *const fn (*const Context, []const u8) Context.Error!core.Tool.Output,
    subject: ?Subject = null,
    timeout: Timeout = .none,

    const Subject = struct {
        argument: []const u8,
        kind: Description.Kind,
    };

    const Timeout = union(enum) {
        none,
        argument: []const u8,
        fixed: u64,

        fn defaultMs(self: *const Timeout, timeout_ms_configured: u64) ?u64 {
            return switch (self.*) {
                .none => null,
                .argument => bash.timeoutMs(&.{
                    .timeout_seconds = null,
                    .timeout_ms_configured = timeout_ms_configured,
                }),
                .fixed => |fixed_ms| fixed_ms,
            };
        }
    };
};

pub const Description = struct {
    subject: ?Subject,
    timeout_ms: ?u64,

    pub const Subject = struct {
        kind: Kind,
        text: []const u8,
    };

    pub const Kind = enum { path, pattern, command };

    pub fn deinit(self: *const Description, gpa: std.mem.Allocator) void {
        if (self.subject) |subject| gpa.free(subject.text);
    }
};

const entries = [_]Entry{
    .{ .tool = read.spec, .run = read.run, .subject = .{ .argument = "path", .kind = .path } },
    .{ .tool = write.spec, .run = write.run, .subject = .{ .argument = "path", .kind = .path } },
    .{ .tool = edit.spec, .run = edit.run, .subject = .{ .argument = "path", .kind = .path } },
    .{
        .tool = find.spec,
        .run = find.run,
        .subject = .{ .argument = "pattern", .kind = .pattern },
        .timeout = .{ .fixed = search.timeout_ms },
    },
    .{
        .tool = grep.spec,
        .run = grep.run,
        .subject = .{ .argument = "pattern", .kind = .pattern },
        .timeout = .{ .fixed = search.timeout_ms },
    },
    .{
        .tool = bash.spec,
        .run = bash.run,
        .subject = .{ .argument = "command", .kind = .command },
        .timeout = .{ .argument = "timeout_seconds" },
    },
    .{ .tool = describe_drinky.spec, .run = describe_drinky.run },
};

pub const specs = blk: {
    var list: [entries.len]core.Tool = undefined;
    for (entries, 0..) |entry, index| list[index] = entry.tool;
    break :blk list;
};

const vtable: core.Runner.VTable = .{ .run = run, .takeSkill = takeSkill, .reset = reset };

pub fn runner(self: *Registry) core.Runner {
    return .{ .ptr = self, .vtable = &vtable };
}

fn run(
    ptr: *anyopaque,
    gpa: std.mem.Allocator,
    call: *const core.Tool.Call,
    items: []const core.Conversation.Item,
    variables: []const core.Runner.Variable,
) core.Runner.Error!core.Tool.Output {
    const self: *Registry = @ptrCast(@alignCast(ptr));
    const entry = entryNamed(call.name) orelse return output.failure(
        gpa,
        .unknown_tool,
        "Drinky does not recognize the tool {s}.",
        .{call.name},
    );
    const context: Context = .{ .gpa = gpa, .host = self.host, .variables = variables };
    const guard = self.skill_guard orelse return runEntry(&context, entry, call);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const path = (try guardedPath(arena.allocator(), entry, call.arguments)) orelse
        return runEntry(&context, entry, call);
    const check: SkillGuard.CheckOptions = .{
        .gpa = gpa,
        .io = self.host.io,
        .path = path,
        .history = items,
    };
    if (entry.tool.mutates) {
        if (try guard.refusal(&check)) |refused| return refused;
        return runEntry(&context, entry, call);
    }
    const result = try runEntry(&context, entry, call);
    errdefer result.deinit(gpa);
    if (!result.hasFailure()) try guard.queue(&check);
    return result;
}

fn runEntry(
    context: *const Context,
    entry: *const Entry,
    call: *const core.Tool.Call,
) core.Runner.Error!core.Tool.Output {
    return entry.run(context, call.arguments) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => |known| known,
        error.WriteFailed => error.OutOfMemory,
        error.InvalidArguments => output.failure(
            context.gpa,
            .invalid_arguments,
            "Drinky received invalid arguments for the {s} tool.",
            .{call.name},
        ),
    };
}

fn takeSkill(
    ptr: *anyopaque,
    gpa: std.mem.Allocator,
    items: []const core.Conversation.Item,
) core.Runner.Error!?core.Runner.Skill {
    const self: *Registry = @ptrCast(@alignCast(ptr));
    const guard = self.skill_guard orelse return null;
    return guard.takeQueued(gpa, self.host.io, items);
}

fn reset(ptr: *anyopaque) void {
    const self: *Registry = @ptrCast(@alignCast(ptr));
    if (self.skill_guard) |guard| guard.forget();
}

pub fn describe(
    gpa: std.mem.Allocator,
    call: *const core.Tool.Call,
    timeout_ms_configured: u64,
) error{OutOfMemory}!Description {
    const entry = entryNamed(call.name) orelse return .{ .subject = null, .timeout_ms = null };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const arguments = (try parseArguments(arena.allocator(), call.arguments)) orelse return .{
        .subject = null,
        .timeout_ms = entry.timeout.defaultMs(timeout_ms_configured),
    };
    const timeout_ms = readTimeoutMs(entry, arena.allocator(), &arguments, timeout_ms_configured);
    const subject = entry.subject orelse return .{ .subject = null, .timeout_ms = timeout_ms };
    const text = stringArgument(&arguments, subject.argument) orelse
        return .{ .subject = null, .timeout_ms = timeout_ms };
    return .{
        .subject = .{ .kind = subject.kind, .text = try gpa.dupe(u8, text) },
        .timeout_ms = timeout_ms,
    };
}

fn entryNamed(name: []const u8) ?*const Entry {
    for (&entries) |*entry| {
        if (std.mem.eql(u8, name, entry.tool.name)) return entry;
    }
    return null;
}

fn guardedPath(
    arena: std.mem.Allocator,
    entry: *const Entry,
    input_json: []const u8,
) error{OutOfMemory}!?[]const u8 {
    const subject = entry.subject orelse return null;
    if (subject.kind != .path) return null;
    const arguments = (try parseArguments(arena, input_json)) orelse return null;
    return stringArgument(&arguments, subject.argument);
}

fn parseArguments(
    arena: std.mem.Allocator,
    input_json: []const u8,
) error{OutOfMemory}!?std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        input_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn stringArgument(arguments: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (arguments.get(name) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn readTimeoutMs(
    entry: *const Entry,
    arena: std.mem.Allocator,
    arguments: *const std.json.ObjectMap,
    timeout_ms_configured: u64,
) ?u64 {
    const name = switch (entry.timeout) {
        .argument => |argument| argument,
        .none, .fixed => return entry.timeout.defaultMs(timeout_ms_configured),
    };
    const raw = arguments.get(name) orelse .null;
    const seconds: ?u64 = switch (raw) {
        .null => null,
        else => std.json.parseFromValueLeaky(u64, arena, raw, .{}) catch return null,
    };
    return bash.timeoutMs(&.{
        .timeout_seconds = seconds,
        .timeout_ms_configured = timeout_ms_configured,
    });
}

test "the specs mark the tools that change files or run commands" {
    const expected = [_]struct { name: []const u8, mutates: bool }{
        .{ .name = "read", .mutates = false },
        .{ .name = "write", .mutates = true },
        .{ .name = "edit", .mutates = true },
        .{ .name = "find", .mutates = false },
        .{ .name = "grep", .mutates = false },
        .{ .name = "bash", .mutates = true },
        .{ .name = "describe_drinky", .mutates = false },
    };
    try std.testing.expectEqual(expected.len, specs.len);
    for (expected, specs) |want, spec| {
        try std.testing.expectEqualStrings(want.name, spec.name);
        try std.testing.expectEqual(want.mutates, spec.mutates);
    }
}

test "an unknown tool and invalid arguments come back as failed outputs" {
    const gpa = std.testing.allocator;
    var registry: Registry = .{ .host = .{ .io = std.testing.io } };
    const tools = registry.runner();

    const unknown = try tools.run(
        gpa,
        &.{ .id = "1", .name = "nope", .arguments = "{}" },
        &.{},
        &.{},
    );
    defer unknown.deinit(gpa);
    try testing.expectConditions(&unknown, &.{.unknown_tool});
    try std.testing.expectEqualStrings("Drinky does not recognize the tool nope.", unknown.content);

    const invalid = try tools.run(
        gpa,
        &.{ .id = "2", .name = "read", .arguments = "{}" },
        &.{},
        &.{},
    );
    defer invalid.deinit(gpa);
    try testing.expectConditions(&invalid, &.{.invalid_arguments});
    try testing.expectMeasures(&invalid, &.{});
}

test "the runner hands a call to its tool with the state of the host" {
    const gpa = std.testing.allocator;
    var registry: Registry = .{ .host = .{ .io = std.testing.io, .document = "# Drinky\n" } };
    const tools = registry.runner();

    const described = try tools.run(gpa, &.{
        .id = "1",
        .name = "describe_drinky",
        .arguments = "{}",
    }, &.{}, &.{});
    defer described.deinit(gpa);
    try std.testing.expectEqualStrings("# Drinky\n", described.content);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo\n" });
    var arguments_buffer: [128]u8 = undefined;
    const arguments = try std.mem.print(&arguments_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    const shown = try tools.run(
        gpa,
        &.{ .id = "2", .name = "read", .arguments = arguments },
        &.{},
        &.{},
    );
    defer shown.deinit(gpa);
    try std.testing.expectEqualStrings("one\ntwo\n", shown.content);
    try testing.expectMeasures(&shown, &.{
        .{ .lines, 2 },
        .{ .line_first, 1 },
        .{ .lines_total, 2 },
    });
}

test "a command gets the variables of its call in place of the same names of the host" {
    const gpa = std.testing.allocator;
    const host_entries = [_:null]?[*:0]const u8{
        "PATH=/usr/local/bin:/bin:/usr/bin",
        "SHARED=host",
        "KEPT=host",
    };
    var registry: Registry = .{
        .host = .{ .io = std.testing.io, .environ = .{ .block = .{ .slice = &host_entries } } },
    };
    const variables = [_]core.Runner.Variable{
        .{ .name = "SHARED", .value = "call" },
        .{ .name = "ADDED", .value = "call" },
    };
    const result = try registry.runner().run(gpa, &.{
        .id = "1",
        .name = "bash",
        .arguments =
        \\{"command":"env | grep -E '^(SHARED|ADDED|KEPT)=' | sort"}
        ,
    }, &.{}, &variables);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("ADDED=call\nKEPT=host\nSHARED=call\n", result.content);
}

test "a guarded change waits for its skill, which a round boundary delivers and a reset forgets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "old.zig", .data = "const x = 1;\n" });
    var registry: Registry = .{ .host = .{ .io = io }, .skill_guard = &fixture.guard };
    const tools = registry.runner();

    const write_arguments = try gpa.print(
        "{{\"path\":\"{s}/new.zig\",\"content\":\"const y = 2;\\n\"}}",
        .{fixture.root},
    );
    defer gpa.free(write_arguments);
    const edit_arguments = try gpa.print(
        "{{\"path\":\"{s}/old.zig\",\"old_text\":\"1\",\"new_text\":\"2\"}}",
        .{fixture.root},
    );
    defer gpa.free(edit_arguments);
    const calls = [_]core.Tool.Call{
        .{ .id = "1", .name = "write", .arguments = write_arguments },
        .{ .id = "2", .name = "edit", .arguments = edit_arguments },
    };
    for (&calls) |*call| {
        const refused = try tools.run(gpa, call, &.{}, &.{});
        defer refused.deinit(gpa);
        try testing.expectConditions(&refused, &.{.skill_required});
    }
    try std.testing.expectError(
        error.FileNotFound,
        fixture.tmp.dir.readFileAlloc(io, "new.zig", gpa, .limited(64)),
    );
    const kept = try fixture.tmp.dir.readFileAlloc(io, "old.zig", gpa, .limited(64));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("const x = 1;\n", kept);

    const skill = (try tools.takeSkill(gpa, &.{})).?;
    defer skill.deinit(gpa);
    try std.testing.expectEqualStrings("zig-style", skill.name);
    try std.testing.expectEqualStrings(fixture.source, skill.source);
    try std.testing.expect(std.mem.endsWith(u8, skill.text, fixture.body));

    const history = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = skill.text } },
    };
    try std.testing.expect((try tools.takeSkill(gpa, &history)) == null);
    for (&calls) |*call| {
        const changed = try tools.run(gpa, call, &history, &.{});
        defer changed.deinit(gpa);
        try std.testing.expect(!changed.hasFailure());
    }
    const written = try fixture.tmp.dir.readFileAlloc(io, "new.zig", gpa, .limited(64));
    defer gpa.free(written);
    try std.testing.expectEqualStrings("const y = 2;\n", written);
    const edited = try fixture.tmp.dir.readFileAlloc(io, "old.zig", gpa, .limited(64));
    defer gpa.free(edited);
    try std.testing.expectEqualStrings("const x = 2;\n", edited);

    const proven = try tools.run(gpa, &calls[0], &.{}, &.{});
    defer proven.deinit(gpa);
    try std.testing.expect(!proven.hasFailure());
    tools.reset();
    const forgotten = try tools.run(gpa, &calls[0], &.{}, &.{});
    defer forgotten.deinit(gpa);
    try testing.expectConditions(&forgotten, &.{.skill_required});
}

test "a read of a guarded file queues its skill, and a failed read queues none" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });
    var registry: Registry = .{ .host = .{ .io = io }, .skill_guard = &fixture.guard };
    const tools = registry.runner();

    const missing_arguments = try gpa.print(
        "{{\"path\":\"{s}/missing.zig\"}}",
        .{fixture.root},
    );
    defer gpa.free(missing_arguments);
    const missing = try tools.run(gpa, &.{
        .id = "1",
        .name = "read",
        .arguments = missing_arguments,
    }, &.{}, &.{});
    defer missing.deinit(gpa);
    try testing.expectConditions(&missing, &.{.path_missing});
    try std.testing.expect((try tools.takeSkill(gpa, &.{})) == null);

    const arguments = try gpa.print("{{\"path\":\"{s}/a.zig\"}}", .{fixture.root});
    defer gpa.free(arguments);
    const shown = try tools.run(
        gpa,
        &.{ .id = "2", .name = "read", .arguments = arguments },
        &.{},
        &.{},
    );
    defer shown.deinit(gpa);
    try std.testing.expectEqualStrings("const x = 1;\n", shown.content);
    const skill = (try tools.takeSkill(gpa, &.{})).?;
    defer skill.deinit(gpa);
    try std.testing.expectEqualStrings("zig-style", skill.name);
    try std.testing.expect(std.mem.endsWith(u8, skill.text, fixture.body));
}

test "a registry without a guard queues no skill" {
    var registry: Registry = .{ .host = .{ .io = std.testing.io } };
    try std.testing.expect((try registry.runner().takeSkill(std.testing.allocator, &.{})) == null);
}

test describe {
    const gpa = std.testing.allocator;
    const Expected = struct { kind: Description.Kind, text: []const u8 };
    const cases = [_]struct { name: []const u8, input: []const u8, expected: ?Expected }{
        .{
            .name = "read",
            .input = "{\"path\":\"src/App.zig\"}",
            .expected = .{ .kind = .path, .text = "src/App.zig" },
        },
        .{
            .name = "write",
            .input = "{\"path\":\"a.zig\",\"content\":\"x\"}",
            .expected = .{ .kind = .path, .text = "a.zig" },
        },
        .{
            .name = "edit",
            .input = "{\"path\":\"a.zig\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            .expected = .{ .kind = .path, .text = "a.zig" },
        },
        .{
            .name = "find",
            .input = "{\"pattern\":\"*.zig\"}",
            .expected = .{ .kind = .pattern, .text = "*.zig" },
        },
        .{
            .name = "grep",
            .input = "{\"pattern\":\"  \"}",
            .expected = .{ .kind = .pattern, .text = "  " },
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"cat <<'EOF'\\n  one\\nEOF\"}",
            .expected = .{ .kind = .command, .text = "cat <<'EOF'\n  one\nEOF" },
        },
        .{ .name = "describe_drinky", .input = "{}", .expected = null },
        .{ .name = "write", .input = "{\"path\":\"a.zig\",\"conte", .expected = null },
        .{ .name = "read", .input = "{\"offset\":3}", .expected = null },
        .{ .name = "read", .input = "{\"path\":3}", .expected = null },
        .{ .name = "nonesuch", .input = "{\"path\":\"a.zig\"}", .expected = null },
    };
    for (cases) |case| {
        const description = try describe(gpa, &.{
            .id = "",
            .name = case.name,
            .arguments = case.input,
        }, 120_000);
        defer description.deinit(gpa);
        const expected = case.expected orelse {
            try std.testing.expect(description.subject == null);
            continue;
        };
        const subject = description.subject.?;
        try std.testing.expectEqual(expected.kind, subject.kind);
        try std.testing.expectEqualStrings(expected.text, subject.text);
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
            .expected = 5_000,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":5.0}",
            .expected = 5_000,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":null}",
            .expected = 120_000,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":1.5}",
            .expected = null,
        },
    };
    for (cases) |case| {
        const description = try describe(gpa, &.{
            .id = "",
            .name = case.name,
            .arguments = case.input,
        }, 120_000);
        defer description.deinit(gpa);
        try std.testing.expectEqual(case.expected, description.timeout_ms);
    }
}
