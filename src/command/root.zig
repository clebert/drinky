const std = @import("std");

const core = @import("core");

const Message = @import("../Message.zig");
const ui = @import("../ui/root.zig");

pub const Context = @import("Context.zig");
pub const login = @import("login.zig");
pub const model = @import("model.zig");

const effort = @import("effort.zig");
const logout = @import("logout.zig");
const new = @import("new.zig");
const rewind = @import("rewind.zig");
const skill = @import("skill.zig");
const sources = @import("sources.zig");
const system = @import("system.zig");
const testing = @import("testing.zig");

const Entry = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (*Context) Context.Error!Context.Outcome,
};

const help_name = "help";
const help_summary = "List every command";
const skill_prefix = skill.name ++ ":";

const help_opener: Context.Outcome.Opener = .{ .open = reopenHelp };

const commands = [_]Entry{
    .{ .name = effort.name, .summary = effort.summary, .run = effort.run },
    .{ .name = help_name, .summary = help_summary, .run = runHelp },
    .{ .name = login.name, .summary = login.summary, .run = login.run },
    .{ .name = logout.name, .summary = logout.summary, .run = logout.run },
    .{ .name = model.name, .summary = model.summary, .run = model.run },
    .{ .name = new.name, .summary = new.summary, .run = new.run },
    .{ .name = rewind.name, .summary = rewind.summary, .run = rewind.run },
    .{ .name = skill.name, .summary = skill.summary, .run = skill.run },
    .{ .name = sources.name, .summary = sources.summary, .run = sources.run },
    .{ .name = system.name, .summary = system.summary, .run = system.run },
};

comptime {
    for (commands[1..], 0..) |entry, index| {
        if (!std.mem.lessThan(u8, commands[index].name, entry.name))
            @compileError("the command table must be sorted by name: " ++ entry.name);
    }
}

const Summary = struct {
    name: []const u8,
    summary: []const u8,
    alias: []const u8 = "",
    tail: []const u8 = "",
};

pub const summaries = blk: {
    var list: [commands.len + 1]Summary = undefined;
    for (commands, 0..) |entry, index| list[index] = .{
        .name = entry.name,
        .summary = entry.summary,
        .alias = aliasOf(entry.name),
    };
    list[commands.len] = .{
        .name = skill_prefix ++ "name",
        .summary = "Load a skill",
        .tail = "the task of the skill",
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

fn parse(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/")) return null;
    const body = line[1..];
    const end = std.mem.indexOfAny(u8, body, ui.paint.blank_bytes) orelse body.len;
    return body[0..end];
}

fn loadsSkill(name: []const u8) bool {
    return name.len > skill_prefix.len and std.mem.startsWith(u8, name, skill_prefix);
}

fn tail(line: []const u8, name: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, line[1..], name));
    return std.mem.trim(u8, line[1 + name.len ..], ui.paint.blank_bytes);
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

fn runHelp(context: *Context) Context.Error!Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
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
        .reopen = help_opener,
    } };
}

fn reopenHelp(context: *Context, payload: usize) Context.Error!Context.Outcome {
    _ = payload;
    return runHelp(context);
}

fn selectCommand(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    var rows: [commands.len]Entry = undefined;
    return listed(&rows)[selection.row].run(context);
}

pub fn check(context: *Context, line: []const u8) !?Message {
    const name = parse(line) orelse return null;
    if (loadsSkill(name)) return checkSkill(context, name);
    if (lookup(name) == null) return try unknownCommand(context.gpa, name);
    if (tail(line, name).len > 0) return try Message.print(
        context.gpa,
        .warning,
        "The command /{s} takes no argument.",
        .{name},
    );
    return null;
}

pub fn run(context: *Context, line: []const u8) !?Context.Outcome {
    const name = parse(line) orelse return null;
    if (try check(context, line)) |refusal| return .{ .refusal = refusal };
    if (loadsSkill(name)) {
        const target = context.skill_registry.get(name[skill_prefix.len..]).?;
        return try skill.load(context, target, tail(line, name));
    }
    return try lookup(name).?.run(context);
}

pub fn checkDuringTurn(context: *Context, line: []const u8) !?Message {
    const name = parse(line) orelse return null;
    if (try check(context, line)) |refusal| return refusal;
    return try Message.print(
        context.gpa,
        .warning,
        "The command /{s} cannot run while a turn runs.",
        .{name},
    );
}

fn checkSkill(context: *Context, command_name: []const u8) !?Message {
    const name = command_name[skill_prefix.len..];
    if (context.skill_registry.get(name) == null) return try unknownSkill(context.gpa, name);
    return null;
}

fn unknownCommand(gpa: std.mem.Allocator, name: []const u8) !Message {
    return Message.print(gpa, .warning, "Drinky does not recognize the command /{s}.", .{name});
}

fn unknownSkill(gpa: std.mem.Allocator, name: []const u8) !Message {
    return Message.print(gpa, .warning, "Drinky does not recognize the skill {s}.", .{name});
}

test "check reports only what keeps a line unrunnable" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();

    try std.testing.expect((try check(&context, "/effort")) == null);
    try std.testing.expect((try check(&context, "/effort \n ")) == null);
    try std.testing.expect((try check(&context, "not a command")) == null);
    try std.testing.expect((try check(&context, "")) == null);
    const unknown_command = (try check(&context, "/nope")).?;
    try testing.expectMessage(&unknown_command, .warning, "does not recognize the command");
    const argument = (try check(&context, "/effort high")).?;
    try testing.expectMessage(&argument, .warning, "takes no argument");
    const unknown_skill = (try check(&context, "/skill:nope")).?;
    try testing.expectMessage(&unknown_skill, .warning, "does not recognize the skill");
    try testing.expectRefusal(
        (try run(&context, "/new\nmust clear the scrollback")).?,
        .warning,
        "The command /new takes no argument.",
    );
    try testing.expectRefusal((try run(&context, "/nope\n")).?, .warning, "/nope.");
    try std.testing.expectEqual(core.Provider.Effort.high, rig.choice.effort);
}

test "a command line during a turn gets a refusal, and a message line gets none" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();

    try std.testing.expect((try checkDuringTurn(&context, "a message")) == null);
    const known = (try checkDuringTurn(&context, "/effort")).?;
    try testing.expectMessage(
        &known,
        .warning,
        "The command /effort cannot run while a turn runs.",
    );
    const unknown = (try checkDuringTurn(&context, "/nope")).?;
    try testing.expectMessage(&unknown, .warning, "Drinky does not recognize the command /nope.");
}

test "a line without a leading slash is not dispatched" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();
    try std.testing.expect((try run(&context, "just a message")) == null);
    try std.testing.expect((try run(&context, " /new")) == null);
}

test "run routes a known command" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();

    const pick = try testing.expectPick((try run(&context, "/effort")).?);
    defer pick.deinit(gpa);
    try std.testing.expectEqualStrings("Effort", pick.title);
    context.system_prompt = "You are Drinky.";
    context.sources_page = "# Sources";
    const system_page = (try run(&context, "/system")).?.page;
    try std.testing.expectEqualStrings("System prompt", system_page.title);
    try std.testing.expectEqualStrings("You are Drinky.", system_page.content);
    const sources_page = (try run(&context, "/sources")).?.page;
    try std.testing.expectEqualStrings("Sources", sources_page.title);
    try std.testing.expectEqualStrings("# Sources", sources_page.content);
    try std.testing.expect((try run(&context, "/new")).? == .new_conversation);
}

test "skill prefix dispatch loads instructions and preserves trailing arguments" {
    const gpa = std.testing.allocator;
    var discovered: testing.Discovered = try .init();
    defer discovered.deinit();
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();
    context.skill_registry = &discovered.registry;

    switch ((try run(&context, "/skill:alpha apply it\nto this file")).?) {
        .prompt => |prompt| {
            defer prompt.deinit(gpa);
            try std.testing.expectEqualStrings("alpha", prompt.name);
            try std.testing.expectEqualStrings("apply it\nto this file", prompt.arguments);
            try std.testing.expect(std.mem.indexOf(u8, prompt.content, "Skill location: ") != null);
            const body = std.mem.indexOf(u8, prompt.content, "Follow this skill.");
            try std.testing.expect(body != null);
            try std.testing.expect(std.mem.endsWith(u8, prompt.content, "apply it\nto this file"));
        },
        else => return error.ExpectedPrompt,
    }
    try testing.expectRefusal(
        (try run(&context, "/skill:nope")).?,
        .warning,
        "does not recognize the skill",
    );
}

test "a line without a name opens its list, and a command row runs its command" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();

    for ([_][]const u8{ "/", "/help" }) |line| {
        const pick = try testing.expectPick((try run(&context, line)).?);
        defer pick.deinit(gpa);
        try std.testing.expectEqualStrings("Command", pick.title);
        try testing.expectReopen(&context, &pick);
        try std.testing.expectEqual(commands.len - 1, pick.options.len);
        try std.testing.expectEqualStrings("/effort", pick.options[0].name);
        try std.testing.expectEqualStrings("Set the reasoning effort.", pick.options[0].extra.?);
        try std.testing.expectEqualStrings("/system", pick.options[pick.options.len - 1].name);
        for (pick.options) |*option|
            try std.testing.expect(!std.mem.startsWith(u8, option.name, "/help"));
        const last = pick.options.len - 1;
        try std.testing.expect((try testing.selectRow(&pick, &context, last)) == .page);
    }

    for ([_][]const u8{ "/skill", "/skill:" }) |line| {
        const outcome = (try run(&context, line)).?;
        try testing.expectRefusal(outcome, .warning, "Drinky found no skill.");
    }
    try testing.expectRefusal(
        (try run(&context, "/skill: do it")).?,
        .warning,
        "The command /skill: takes no argument.",
    );
    try testing.expectRefusal(
        (try run(&context, "/help me")).?,
        .warning,
        "The command /help takes no argument.",
    );
}
