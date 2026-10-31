const std = @import("std");

pub const repeat_window_ms = 500;
pub const key_hints = [_][]const u8{
    "Enter: Send",
    "Shift+Enter: New line",
    "Esc: Cancel",
    "Ctrl+C: Clear",
    "Ctrl+D: Quit",
};

pub const Command = enum {
    effort,
    handoff,
    help,
    login,
    logout,
    mcp,
    model,
    new,
    rewind,
    skill,
    sources,
    system,
    verbose,

    const Facts = struct {
        summary: []const u8,
        tail: []const u8 = "",
        during_work: bool = false,
        alias: []const u8 = "",
    };
};

pub const commands: std.enums.EnumArray(Command, Command.Facts) = .init(.{
    .effort = .{ .summary = "Set the reasoning effort" },
    .handoff = .{
        .summary = "Prepare a handoff for the current task",
        .tail = "an optional instruction",
    },
    .help = .{ .summary = "List every command", .alias = "/" },
    .login = .{ .summary = "Sign in or switch the account" },
    .logout = .{ .summary = "Drop the credentials of an account" },
    .mcp = .{ .summary = "Turn MCP access to this instance on or off", .during_work = true },
    .model = .{ .summary = "Switch the model" },
    .new = .{ .summary = "Clear the conversation" },
    .rewind = .{ .summary = "Return to an earlier prompt" },
    .skill = .{ .summary = "Pick a skill", .alias = "/" ++ skill_prefix },
    .sources = .{ .summary = "Show the loaded instruction files and skills" },
    .system = .{ .summary = "Show the complete system prompt" },
    .verbose = .{
        .summary = "Toggle thinking text, tool rows, and complete bash commands",
        .during_work = true,
    },
});

pub const skill_prefix = @tagName(Command.skill) ++ ":";

pub inline fn line(comptime command: Command) []const u8 {
    return "/" ++ @tagName(command);
}

const Summary = struct {
    name: []const u8,
    summary: []const u8,
    alias: []const u8 = "",
    tail: []const u8 = "",
};

pub const summaries = list: {
    const values = std.enums.values(Command);
    var result: [values.len + 1]Summary = undefined;
    for (values, 0..) |command, index| {
        const facts = commands.get(command);
        result[index] = .{
            .name = @tagName(command),
            .summary = facts.summary,
            .alias = facts.alias,
            .tail = facts.tail,
        };
    }
    result[values.len] = .{
        .name = skill_prefix ++ "name",
        .summary = "Load a skill",
        .tail = "the task of the skill",
    };
    break :list result;
};

comptime {
    const values = std.enums.values(Command);
    for (values[1..], 0..) |command, index| {
        if (!std.mem.lessThan(u8, @tagName(values[index]), @tagName(command)))
            @compileError("the command table must be sorted by name: " ++ @tagName(command));
    }
}
