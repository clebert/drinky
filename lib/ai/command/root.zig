//! Slash-command registry, mirroring the tool registry: each command module
//! exposes `name`/`run` and is registered below.

const std = @import("std");

pub const Context = @import("Context.zig");
pub const Outcome = Context.Outcome;

const skills = @import("../skills.zig");
const testing = @import("testing.zig");

const effort = @import("effort.zig");
const login = @import("login.zig");
const logout = @import("logout.zig");
const model = @import("model.zig");
const new = @import("new.zig");

const Entry = struct {
    name: []const u8,
    run: *const fn (*Context) anyerror!Outcome,
};

const commands = [_]Entry{
    .{ .name = model.name, .run = model.run },
    .{ .name = effort.name, .run = effort.run },
    .{ .name = login.name, .run = login.run },
    .{ .name = logout.name, .run = logout.run },
    .{ .name = new.name, .run = new.run },
};

/// Dispatch a `/`-prefixed input line to its command; an unknown command is an error.
pub fn run(context: *Context, line: []const u8) !Outcome {
    const body = line[1..];
    // Editor input can carry interior newlines (Shift+Enter, paste).
    const name = body[0 .. std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len];
    if (std.mem.startsWith(u8, name, "skill:")) return runSkill(context, line, name);
    for (&commands) |*entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.run(context);
    }
    return Outcome.report(context.gpa, .err, "unknown command: /{s}", .{name});
}

fn runSkill(context: *Context, line: []const u8, command_name: []const u8) !Outcome {
    const name = command_name["skill:".len..];
    if (name.len == 0)
        return Outcome.report(context.gpa, .err, "skill name is required", .{});
    const registry = context.skill_registry orelse
        return Outcome.report(context.gpa, .err, "unknown skill: {s}", .{name});
    const skill = registry.get(name) orelse
        return Outcome.report(context.gpa, .err, "unknown skill: {s}", .{name});
    const body = line[1..];
    const arguments = std.mem.trim(u8, body[command_name.len..], " \t\r\n");
    const content = skill.invoke(context.gpa, context.io, arguments) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return Outcome.report(context.gpa, .err, "cannot load skill {s}: {s}", .{
            name,
            @errorName(err),
        });
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
    try Outcome.expectFeedback(try run(&context, "/nope"), .err);
}

test "run routes a known command, ignoring the argument tail" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    switch (try run(&context, "/effort xhigh trailing")) {
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

test "a newline delimits the command name like a space" {
    const gpa = std.testing.allocator;
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    const outcome = try run(&context, "/nope\nfoo");
    switch (outcome) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expectEqualStrings("unknown command: /nope", feedback.content);
        },
        else => return error.ExpectedFeedback,
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
    var git = try tmp.dir.createDirPathOpen(io, "repo/.git", .{});
    git.close(io);

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const base = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(base);
    const user_root = try std.fs.path.join(gpa, &.{ base, "user" });
    defer gpa.free(user_root);
    const project_start = try std.fs.path.join(gpa, &.{ base, "repo" });
    defer gpa.free(project_start);

    var registry = try skills.discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
    });
    defer registry.deinit();

    var context: Context = .{
        .gpa = gpa,
        .io = io,
        .agent = undefined,
        .accounts = undefined,
        .skill_registry = &registry,
    };
    switch (try run(&context, "/skill:demo apply it\nto this file")) {
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
    try Outcome.expectFeedbackContaining(try run(&context, "/skill:"), .err, "required");
    try Outcome.expectFeedbackContaining(try run(&context, "/skill:nope"), .err, "unknown skill");
}
