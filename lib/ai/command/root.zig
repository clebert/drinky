const std = @import("std");

const skills = @import("../skills.zig");

pub const Context = @import("Context.zig");
pub const Outcome = Context.Outcome;
pub const login = @import("login.zig");
pub const model = @import("model.zig");

const effort = @import("effort.zig");
const logout = @import("logout.zig");
const new = @import("new.zig");
const remote = @import("remote.zig");
const skill = @import("skill.zig");
const sources = @import("sources.zig");
const system = @import("system.zig");
const testing = @import("testing.zig");

const Entry = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (*Context) anyerror!Outcome,
    remote: bool,
};

const help_name = "help";
const help_summary = "List every command";
const skill_prefix = skill.name ++ ":";
const whitespace = " \t\r\n";

const commands = [_]Entry{
    .{
        .name = effort.name,
        .summary = effort.summary,
        .run = effort.run,
        .remote = false,
    },
    .{
        .name = help_name,
        .summary = help_summary,
        .run = runHelp,
        .remote = false,
    },
    .{
        .name = login.name,
        .summary = login.summary,
        .run = login.run,
        .remote = false,
    },
    .{
        .name = logout.name,
        .summary = logout.summary,
        .run = logout.run,
        .remote = false,
    },
    .{
        .name = model.name,
        .summary = model.summary,
        .run = model.run,
        .remote = false,
    },
    .{
        .name = new.name,
        .summary = new.summary,
        .run = new.run,
        .remote = true,
    },
    .{
        .name = remote.name,
        .summary = remote.summary,
        .run = remote.run,
        .remote = false,
    },
    .{
        .name = skill.name,
        .summary = skill.summary,
        .run = skill.run,
        .remote = false,
    },
    .{
        .name = sources.name,
        .summary = sources.summary,
        .run = sources.run,
        .remote = false,
    },
    .{
        .name = system.name,
        .summary = system.summary,
        .run = system.run,
        .remote = false,
    },
};

comptime {
    for (commands[1..], 0..) |entry, index| {
        if (!std.mem.lessThan(u8, commands[index].name, entry.name))
            @compileError("the command table must be sorted by name: " ++ entry.name);
    }
}

pub const Summary = struct {
    name: []const u8,
    summary: []const u8,
    alias: []const u8 = "",
    tail: []const u8 = "",
    remote: bool,
};

pub const summaries = blk: {
    var list: [commands.len + 1]Summary = undefined;
    for (commands, 0..) |entry, index| list[index] = .{
        .name = entry.name,
        .summary = entry.summary,
        .alias = aliasOf(entry.name),
        .remote = entry.remote,
    };
    list[commands.len] = .{
        .name = skill_prefix ++ "name",
        .summary = "load a skill",
        .tail = "the task of the skill",
        .remote = false,
    };
    break :blk list;
};

fn aliasOf(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, help_name)) return "/";
    if (std.mem.eql(u8, name, skill.name)) return "/" ++ skill_prefix;
    return "";
}

fn listed(out: *[commands.len]Entry) []const Entry {
    var count: usize = 0;
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, help_name)) continue;
        out[count] = entry;
        count += 1;
    }
    return out[0..count];
}

pub fn parse(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/")) return null;
    const body = line[1..];
    const end = std.mem.indexOfAny(u8, body, whitespace) orelse body.len;
    return body[0..end];
}

fn loadsSkill(name: []const u8) bool {
    return name.len > skill_prefix.len and std.mem.startsWith(u8, name, skill_prefix);
}

fn tail(line: []const u8, name: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, line[1..], name));
    return std.mem.trim(u8, line[1 + name.len ..], whitespace);
}

fn lookup(name: []const u8) ?*const Entry {
    const resolved = if (name.len == 0)
        help_name
    else if (std.mem.eql(u8, name, skill_prefix))
        skill.name
    else
        name;
    for (&commands) |*entry| {
        if (std.mem.eql(u8, resolved, entry.name)) return entry;
    }
    return null;
}

fn runHelp(context: *Context) !Outcome {
    var options: Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var rows: [commands.len]Entry = undefined;
    for (listed(&rows)) |entry| {
        try options.addExtraPrint(false, "/{s}", .{entry.name}, "{s}.", .{entry.summary});
    }
    return .{ .pick = .{
        .select = selectCommand,
        .title = "Command",
        .cancellation_message = "You canceled the command selection.",
        .options = try options.toOwnedSlice(),
        .current = null,
        .reopen = runHelp,
    } };
}

fn selectCommand(context: *Context, selection: Outcome.Pick.Selection) !Outcome {
    const index = selection.row;
    var rows: [commands.len]Entry = undefined;
    const entries = listed(&rows);
    if (index >= entries.len)
        return Outcome.reportNotice(context.gpa, .failure, "Select a valid command.", .{});
    return entries[index].run(context);
}

pub fn check(context: *Context, line: []const u8) !?Outcome.Message {
    const name = parse(line) orelse return null;
    if (loadsSkill(name)) {
        if (try checkSkill(context, name)) |refusal| return refusal;
        return if (context.remote) try terminalOnly(context.gpa, name) else null;
    }
    const entry = lookup(name) orelse return try unknownCommand(context.gpa, name);
    if (context.remote and !entry.remote) return try terminalOnly(context.gpa, entry.name);
    if (tail(line, name).len > 0) return try Outcome.Message.print(
        context.gpa,
        .warning,
        "The command /{s} takes no argument.",
        .{name},
    );
    return null;
}

pub fn run(context: *Context, line: []const u8) !?Outcome {
    const name = parse(line) orelse return null;
    if (try check(context, line)) |refusal| return .{ .refusal = refusal };
    if (loadsSkill(name)) {
        const target = context.skill_registry.?.get(name[skill_prefix.len..]).?;
        return try skill.load(context, target, tail(line, name));
    }
    return try lookup(name).?.run(context);
}

pub fn refuse(
    gpa: std.mem.Allocator,
    name: []const u8,
    restriction: []const u8,
) !Outcome.Message {
    return Outcome.Message.print(
        gpa,
        .warning,
        "The command /{s} cannot run {s}.",
        .{ name, restriction },
    );
}

fn checkSkill(context: *Context, command_name: []const u8) !?Outcome.Message {
    const name = command_name[skill_prefix.len..];
    const registry = context.skill_registry orelse return try unknownSkill(context.gpa, name);
    if (registry.get(name) == null) return try unknownSkill(context.gpa, name);
    return null;
}

fn terminalOnly(gpa: std.mem.Allocator, name: []const u8) !Outcome.Message {
    return Outcome.Message.print(
        gpa,
        .warning,
        "The command /{s} runs in the terminal alone.",
        .{name},
    );
}

fn unknownCommand(gpa: std.mem.Allocator, name: []const u8) !Outcome.Message {
    return Outcome.Message.print(
        gpa,
        .warning,
        "Drinky does not recognize the command /{s}.",
        .{name},
    );
}

fn unknownSkill(gpa: std.mem.Allocator, name: []const u8) !Outcome.Message {
    return Outcome.Message.print(
        gpa,
        .warning,
        "Drinky does not recognize the skill {s}.",
        .{name},
    );
}

test "the registry names the alias line of each list" {
    for (summaries) |command| {
        const expected = if (std.mem.eql(u8, command.name, help_name))
            "/"
        else if (std.mem.eql(u8, command.name, skill.name))
            "/skill:"
        else
            "";
        try std.testing.expectEqualStrings(expected, command.alias);
    }
}

test "unknown command is reported" {
    var context: Context = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try Outcome.expectRefusal((try run(&context, "/nope")).?, .warning);
}

test "a command that takes no argument refuses a tail instead of running" {
    var context: Context = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try Outcome.expectRefusalContaining(
        (try run(&context, "/new must clear the scrollback")).?,
        .warning,
        "The command /new takes no argument.",
    );
    try Outcome.expectRefusalContaining(
        (try run(&context, "/new\nmust clear the scrollback")).?,
        .warning,
        "The command /new takes no argument.",
    );
}

test "check reports only what keeps a line unrunnable" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    try std.testing.expect((try check(&context, "/effort")) == null);
    try std.testing.expect((try check(&context, "not a command")) == null);

    const unknown_name = (try check(&context, "/nope")).?;
    try unknown_name.expect(.warning, "does not recognize the command");
    const unwanted_tail = (try check(&context, "/effort high")).?;
    try unwanted_tail.expect(.warning, "takes no argument");
    const unknown_skill = (try check(&context, "/skill:nope")).?;
    try unknown_skill.expect(.warning, "does not recognize the skill");

    try std.testing.expect(agent.effort == .high);
}

test "a line without a leading slash is not dispatched" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context, "just a message")) == null);
    try std.testing.expect((try run(&context, " /new")) == null);
}

test "parse takes the command name from every slash line" {
    try std.testing.expectEqualStrings("effort", parse("/effort").?);
    try std.testing.expectEqualStrings("effort", parse("/effort \n ").?);
    try std.testing.expectEqualStrings("", parse("/").?);
    try std.testing.expectEqualStrings("skill:demo", parse("/skill:demo apply it").?);
    try std.testing.expectEqualStrings("new", parse("/new must clear the scrollback").?);
    try std.testing.expectEqualStrings("new", parse("/new\nmust clear the scrollback").?);
    try std.testing.expect(parse("not a command") == null);
    try std.testing.expect(parse("") == null);
}

test "run routes a known command" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    switch ((try run(&context, "/effort")).?) {
        .pick => |pick| {
            defer {
                for (pick.options) |*option| option.deinit(gpa);
                gpa.free(pick.options);
            }
            try std.testing.expect(pick.select == &effort.select);
        },
        else => return error.ExpectedPick,
    }
}

test "run routes system" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context, "/system")).? == .show_system_prompt);
}

test "run routes sources" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context, "/sources")).? == .show_sources);
}

test "trailing whitespace does not hide an unknown command name" {
    const gpa = std.testing.allocator;
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    const outcome = (try run(&context, "/nope\n")).?;
    switch (outcome) {
        .refusal => |refusal| {
            defer gpa.free(refusal.content);
            try std.testing.expectEqualStrings(
                "Drinky does not recognize the command /nope.",
                refusal.content,
            );
        },
        else => return error.ExpectedRefusal,
    }
}

test "skill prefix dispatch loads instructions and preserves trailing arguments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "---\nname: demo\ndescription: command test\n---\nFollow this skill.\n";
    var demo_dir = try tmp.dir.createDirPathOpen(io, "user/demo", .{});
    demo_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "user/demo/SKILL.md", .data = source });
    var work = try tmp.dir.createDirPathOpen(io, "work", .{});
    work.close(io);

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const base = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const user_root = try std.fs.path.join(gpa, &.{ base, "user" });
    defer gpa.free(user_root);
    const project_start = try std.fs.path.join(gpa, &.{ base, "work" });
    defer gpa.free(project_start);

    var registry = try skills.discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    var context: Context = .{
        .gpa = gpa,
        .io = io,
        .agent = undefined,
        .accounts = undefined,
        .skill_registry = &registry,
    };
    switch ((try run(&context, "/skill:demo apply it\nto this file")).?) {
        .prompt => |prompt| {
            defer prompt.deinit(gpa);
            try std.testing.expectEqualStrings("demo", prompt.name);
            try std.testing.expectEqualStrings("apply it\nto this file", prompt.arguments);
            try std.testing.expect(std.mem.indexOf(u8, prompt.content, "Skill location: ") != null);
            try std.testing.expect(std.mem.indexOf(u8, prompt.content, source) != null);
            try std.testing.expect(std.mem.endsWith(u8, prompt.content, "apply it\nto this file"));
        },
        else => return error.ExpectedPrompt,
    }

    context.remote = true;
    try Outcome.expectRefusalContaining(
        (try run(&context, "/skill:demo apply it")).?,
        .warning,
        "The command /skill:demo runs in the terminal alone.",
    );
}

test "skill prefix reports an unknown name" {
    var context: Context = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try Outcome.expectRefusalContaining(
        (try run(&context, "/skill:nope")).?,
        .warning,
        "does not recognize the skill",
    );
}

test "a line without a name opens its list" {
    const gpa = std.testing.allocator;
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };

    for ([_][]const u8{ "/", "/help" }) |line| {
        switch ((try run(&context, line)).?) {
            .pick => |pick| {
                defer {
                    for (pick.options) |*option| option.deinit(gpa);
                    gpa.free(pick.options);
                }
                try std.testing.expectEqualStrings("Command", pick.title);
                try std.testing.expect(pick.reopen.? == &runHelp);
                try std.testing.expectEqual(commands.len - 1, pick.options.len);
                try std.testing.expectEqualStrings("/effort", pick.options[0].name);
                try std.testing.expectEqualStrings("Set the reasoning effort.", pick.options[0].extra.?);
                try std.testing.expectEqualStrings("/system", pick.options[pick.options.len - 1].name);
                try std.testing.expectEqualStrings(
                    "Show the complete system prompt.",
                    pick.options[pick.options.len - 1].extra.?,
                );
                for (pick.options) |*option|
                    try std.testing.expect(!std.mem.startsWith(u8, option.name, "/help"));
            },
            else => return error.ExpectedPick,
        }
    }

    for ([_][]const u8{ "/skill", "/skill:" }) |line|
        try Outcome.expectNoticeContaining((try run(&context, line)).?, .warning, "found no skills");

    try Outcome.expectRefusalContaining(
        (try run(&context, "/skill: do it")).?,
        .warning,
        "The command /skill: takes no argument.",
    );
    try Outcome.expectRefusalContaining(
        (try run(&context, "/help me")).?,
        .warning,
        "The command /help takes no argument.",
    );
}

test "a command row runs its command" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    var buffer: [commands.len]Entry = undefined;
    const rows = listed(&buffer);
    const system_index = for (rows, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, system.name)) break index;
    } else return error.MissingSystemRow;
    try std.testing.expect((try selectCommand(&context, .{
        .payload = 0,
        .row = system_index,
    })) == .show_system_prompt);

    const effort_index = for (rows, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, effort.name)) break index;
    } else return error.MissingEffortRow;
    switch (try selectCommand(&context, .ofRow(effort_index))) {
        .pick => |pick| {
            defer {
                for (pick.options) |*option| option.deinit(gpa);
                gpa.free(pick.options);
            }
            try std.testing.expect(pick.select == &effort.select);
        },
        else => return error.ExpectedPick,
    }

    try Outcome.expectNoticeContaining(
        try selectCommand(&context, .ofRow(rows.len)),
        .failure,
        "valid command",
    );
}

test "a remote host runs /new alone" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = &agent,
        .accounts = undefined,
        .remote = true,
    };

    const terminal_lines = [_][]const u8{
        "/effort", "/help",  "/login",   "/logout", "/model",
        "/remote", "/skill", "/sources", "/system",
    };
    for (terminal_lines) |line| {
        const refusal = (try check(&context, line)).?;
        defer gpa.free(refusal.content);
        try std.testing.expectEqual(Outcome.Severity.warning, refusal.severity);
        try std.testing.expect(std.mem.endsWith(u8, refusal.content, "runs in the terminal alone."));
        try std.testing.expect(std.mem.startsWith(u8, refusal.content, "The command /"));
        try std.testing.expect(std.mem.indexOf(u8, refusal.content, line) != null);
    }
    try Outcome.expectRefusalContaining(
        (try run(&context, "/")).?,
        .warning,
        "The command /help runs in the terminal alone.",
    );
    try Outcome.expectRefusalContaining((try run(&context, "/nope")).?, .warning, "does not recognize");
    try Outcome.expectRefusalContaining(
        (try run(&context, "/skill:nope")).?,
        .warning,
        "does not recognize the skill",
    );
    try std.testing.expect((try check(&context, "/new")) == null);
    try std.testing.expect((try run(&context, "/new")).? == .new_conversation);

    var registered: usize = 0;
    for (summaries) |command| {
        if (command.remote and command.tail.len == 0) registered += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), registered);
}
