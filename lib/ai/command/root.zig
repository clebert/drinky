//! Slash-command registry that mirrors the tool registry. Each command module
//! exposes `name`/`run` and appears in the list below.

const std = @import("std");

const skills = @import("../skills.zig");

pub const Context = @import("Context.zig");
pub const Outcome = Context.Outcome;

const effort = @import("effort.zig");
const login = @import("login.zig");
const logout = @import("logout.zig");
const model = @import("model.zig");
const new = @import("new.zig");
const system = @import("system.zig");
const testing = @import("testing.zig");

const Entry = struct {
    name: []const u8,
    run: *const fn (*Context) anyerror!Outcome,
};

/// The name prefix that loads a skill. It is the only command that takes an argument.
const skill_prefix = "skill:";
/// Editor input can carry interior newlines (Shift+Enter, paste), so a newline
/// ends a command name like a space.
const whitespace = " \t\r\n";

const commands = [_]Entry{
    .{ .name = model.name, .run = model.run },
    .{ .name = effort.name, .run = effort.run },
    .{ .name = login.name, .run = login.run },
    .{ .name = logout.name, .run = logout.run },
    .{ .name = new.name, .run = new.run },
    .{ .name = system.name, .run = system.run },
};

/// The command name in an input line, or null when the line is a plain message.
/// A command name must fill the whole line, because a message can start with a
/// word like `/new`. Only a `/skill:` name takes an argument tail.
pub fn parse(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/")) return null;
    const body = line[1..];
    const end = std.mem.indexOfAny(u8, body, whitespace) orelse body.len;
    const name = body[0..end];
    if (std.mem.startsWith(u8, name, skill_prefix)) return name;
    if (std.mem.trim(u8, body[end..], whitespace).len > 0) return null;
    return name;
}

/// Dispatch an input line to its command. Null reports that the line is not a
/// command, so the caller sends it to the model. An unknown command returns a
/// notice.
pub fn run(context: *Context, line: []const u8) !?Outcome {
    const name = parse(line) orelse return null;
    if (std.mem.startsWith(u8, name, skill_prefix)) return try runSkill(context, line, name);
    for (&commands) |*entry| {
        if (std.mem.eql(u8, name, entry.name)) return try entry.run(context);
    }
    return try Outcome.reportNotice(
        context.gpa,
        .failure,
        "Pith does not recognize the command /{s}.",
        .{name},
    );
}

fn runSkill(context: *Context, line: []const u8, command_name: []const u8) !Outcome {
    const name = command_name[skill_prefix.len..];
    if (name.len == 0)
        return Outcome.reportNotice(
            context.gpa,
            .failure,
            "Enter a skill name after /skill:.",
            .{},
        );
    const registry = context.skill_registry orelse
        return Outcome.reportNotice(
            context.gpa,
            .failure,
            "Pith does not recognize the skill {s}.",
            .{name},
        );
    const skill = registry.get(name) orelse
        return Outcome.reportNotice(
            context.gpa,
            .failure,
            "Pith does not recognize the skill {s}.",
            .{name},
        );
    const body = line[1..];
    const arguments = std.mem.trim(u8, body[command_name.len..], whitespace);
    const content = skill.invoke(context.gpa, context.io, arguments) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return Outcome.reportNotice(
            context.gpa,
            .failure,
            "Pith could not load the skill {s} because of error {s}.",
            .{ name, @errorName(err) },
        );
    };
    errdefer context.gpa.free(content);
    const name_copy = try context.gpa.dupe(u8, name);
    errdefer context.gpa.free(name_copy);
    const arguments_copy = try context.gpa.dupe(u8, arguments);
    errdefer context.gpa.free(arguments_copy);
    return .{ .prompt = .{
        .name = name_copy,
        .arguments = arguments_copy,
        .content = content,
    } };
}

test "unknown command is reported" {
    var context: Context = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try Outcome.expectNotice((try run(&context, "/nope")).?, .failure);
}

test "a message that starts like a command is not dispatched" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context, "/new must clear the scrollback")) == null);
    try std.testing.expect((try run(&context, "just a message")) == null);
}

test "parse accepts a bare command name and rejects an argument tail" {
    try std.testing.expectEqualStrings("effort", parse("/effort").?);
    try std.testing.expectEqualStrings("effort", parse("/effort \n ").?);
    try std.testing.expectEqualStrings("", parse("/").?);
    try std.testing.expectEqualStrings("skill:demo", parse("/skill:demo apply it").?);
    try std.testing.expect(parse("/new must clear the scrollback") == null);
    try std.testing.expect(parse("/new\nmust clear the scrollback") == null);
    try std.testing.expect(parse("not a command") == null);
    try std.testing.expect(parse("") == null);
}

test "run routes a known command" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    switch ((try run(&context, "/effort")).?) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
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
        .notice => |notice| {
            defer gpa.free(notice.content);
            try std.testing.expectEqualStrings(
                "Pith does not recognize the command /nope.",
                notice.content,
            );
        },
        else => return error.ExpectedNotice,
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
}

test "skill prefix reports missing and unknown names" {
    var context: Context = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try Outcome.expectNoticeContaining((try run(&context, "/skill:")).?, .failure, "skill name");
    try Outcome.expectNoticeContaining(
        (try run(&context, "/skill:nope")).?,
        .failure,
        "does not recognize the skill",
    );
}
