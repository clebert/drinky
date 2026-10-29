const std = @import("std");
const application = @import("application");
const reference = @import("reference.zig");

const ui = @import("ui/root.zig");

const work_commands = list: {
    var text: []const u8 = "";
    var separator: []const u8 = "";
    for (std.enums.values(reference.Command)) |command| {
        if (!reference.commands.get(command).during_work) continue;
        text = text ++ separator ++ reference.line(command);
        separator = ", ";
    }
    break :list text;
};

pub const Work = enum {
    turn,
    fetch,

    fn noun(self: Work) []const u8 {
        return switch (self) {
            .turn => "a turn",
            .fetch => "a model fetch",
        };
    }
};

pub fn name(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/")) return null;
    const body = line[1..];
    const end = std.mem.findAny(u8, body, application.reference.blank_bytes) orelse body.len;
    return body[0..end];
}

pub fn skillName(command_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, command_name, reference.skill_prefix)) return null;
    const skill = command_name[reference.skill_prefix.len..];
    return if (skill.len == 0) null else skill;
}

pub fn lookup(command_name: []const u8) ?reference.Command {
    for (std.enums.values(reference.Command)) |command| {
        const alias = reference.commands.get(command).alias;
        if (alias.len > 0 and std.mem.eql(u8, alias[1..], command_name)) return command;
    }
    return std.meta.stringToEnum(reference.Command, command_name);
}

pub fn tail(line: []const u8, command_name: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, line[1..], command_name));
    return std.mem.trim(u8, line[1 + command_name.len ..], application.reference.blank_bytes);
}

pub fn check(
    gpa: std.mem.Allocator,
    line: []const u8,
    skills: []const application.query.Skill,
) error{OutOfMemory}!?ui.Message {
    const command_name = name(line) orelse return null;
    if (skillName(command_name)) |skill| {
        for (skills) |known| {
            if (std.mem.eql(u8, known.name, skill)) return null;
        }
        return try ui.Message.print(
            gpa,
            .warning,
            "Drinky does not recognize the skill {s}.",
            .{skill},
        );
    }
    const command = lookup(command_name) orelse return try ui.Message.print(
        gpa,
        .warning,
        "Drinky does not recognize the command /{s}.",
        .{command_name},
    );
    const takes_tail = reference.commands.get(command).tail.len > 0;
    if (!takes_tail and tail(line, command_name).len > 0)
        return try ui.Message.print(
            gpa,
            .warning,
            "The command /{s} takes no argument.",
            .{command_name},
        );
    return null;
}

pub fn checkDuringWork(
    gpa: std.mem.Allocator,
    line: []const u8,
    skills: []const application.query.Skill,
    work: Work,
) error{OutOfMemory}!?ui.Message {
    const command_name = name(line) orelse return null;
    if (try check(gpa, line, skills)) |refusal| return refusal;
    if (skillName(command_name) == null) {
        const command = lookup(command_name).?;
        if (reference.commands.get(command).during_work) return null;
        if (command == .help) return try ui.Message.print(
            gpa,
            .information,
            "Commands during {s}: " ++ work_commands ++ ".",
            .{work.noun()},
        );
    }
    return try ui.Message.print(
        gpa,
        .warning,
        "The command /{s} cannot run while {s} runs.",
        .{ command_name, work.noun() },
    );
}

test "check reports only what keeps a line unrunnable" {
    const gpa = std.testing.allocator;
    const skills = [_]application.query.Skill{.{ .name = "demo", .description = "Demo." }};
    for ([_][]const u8{ "/effort", "/effort \n ", "not a command", "", "/skill:demo it" }) |line|
        try std.testing.expect(try check(gpa, line, &skills) == null);
    const cases = [_]struct { line: []const u8, text: []const u8 }{
        .{ .line = "/nope", .text = "Drinky does not recognize the command /nope." },
        .{ .line = "/nope\n", .text = "Drinky does not recognize the command /nope." },
        .{ .line = "/compact", .text = "Drinky does not recognize the command /compact." },
        .{ .line = "/effort high", .text = "The command /effort takes no argument." },
        .{ .line = "/new\nmust go", .text = "The command /new takes no argument." },
        .{ .line = "/help me", .text = "The command /help takes no argument." },
        .{ .line = "/skill: do it", .text = "The command /skill: takes no argument." },
        .{ .line = "/skill:nope", .text = "Drinky does not recognize the skill nope." },
    };
    for (cases) |case| try expectMessage(try check(gpa, case.line, &skills), .warning, case.text);
}

const no_skills: []const application.query.Skill = &.{};

fn expectMessage(
    maybe_message: ?ui.Message,
    severity: ui.Message.Severity,
    text: []const u8,
) !void {
    const message = maybe_message orelse return error.TestExpectedMessage;
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqual(severity, message.severity);
    try std.testing.expectEqualStrings(text, message.content);
}

test "a command line during work gets a refusal that names the work, and a message gets none" {
    const gpa = std.testing.allocator;
    for (std.enums.values(Work)) |work| {
        try std.testing.expect(try checkDuringWork(gpa, "a message", no_skills, work) == null);
        try std.testing.expect(try checkDuringWork(gpa, "/verbose", no_skills, work) == null);
        try std.testing.expect(try checkDuringWork(gpa, "/mcp", no_skills, work) == null);
    }
    const cases = [_]struct {
        line: []const u8,
        work: Work,
        severity: ui.Message.Severity,
        text: []const u8,
    }{
        .{ .line = "/verbose extra", .work = .turn, .severity = .warning, .text = "The " ++
            "command /verbose takes no argument." },
        .{ .line = "/effort", .work = .turn, .severity = .warning, .text = "The command " ++
            "/effort cannot run while a turn runs." },
        .{ .line = "/handoff Keep it.", .work = .turn, .severity = .warning, .text = "The " ++
            "command /handoff cannot run while a turn runs." },
        .{ .line = "/model", .work = .fetch, .severity = .warning, .text = "The command " ++
            "/model cannot run while a model fetch runs." },
        .{ .line = "/nope", .work = .fetch, .severity = .warning, .text = "Drinky does not " ++
            "recognize the command /nope." },
        .{
            .line = "/",
            .work = .turn,
            .severity = .information,
            .text = "Commands during a turn: /mcp, /verbose.",
        },
        .{
            .line = "/help",
            .work = .fetch,
            .severity = .information,
            .text = "Commands during a model fetch: /mcp, /verbose.",
        },
    };
    for (cases) |case| try expectMessage(
        try checkDuringWork(gpa, case.line, no_skills, case.work),
        case.severity,
        case.text,
    );
}

test "a line resolves its command, its aliases, its skill, and its trimmed tail" {
    try std.testing.expect(name("just a message") == null);
    try std.testing.expect(name(" /new") == null);
    const cases = [_]struct { line: []const u8, command: reference.Command }{
        .{ .line = "/", .command = .help },
        .{ .line = "/skill:", .command = .skill },
        .{ .line = "/handoff x", .command = .handoff },
    };
    for (cases) |case| try std.testing.expectEqual(case.command, lookup(name(case.line).?).?);
    try std.testing.expectEqualStrings("alpha", skillName(name("/skill:alpha it").?).?);
    try std.testing.expect(skillName("skill:") == null);
    const line = "/handoff Keep decisions.\nPreserve the checks.\n";
    try std.testing.expectEqualStrings(
        "Keep decisions.\nPreserve the checks.",
        tail(line, name(line).?),
    );
}
