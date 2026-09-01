//! Slash-command registry that mirrors the tool registry. Each command module
//! exposes `name`, `summary`, and `run`, and appears in the list below.
//!
//! `/help` is the one exception. It lists the registry itself, so it lives here
//! with the table it reads. A module of its own would have to import this file,
//! which inverts the dependency of the subsystem.

const std = @import("std");

const skills = @import("../skills.zig");

pub const Context = @import("Context.zig");
pub const Outcome = Context.Outcome;

const effort = @import("effort.zig");
const login = @import("login.zig");
const logout = @import("logout.zig");
const model = @import("model.zig");
const new = @import("new.zig");
/// Public: the app opens the review setup pickers itself, because it seeds
/// their choices from its project state before the first step.
pub const review = @import("review.zig");
const skill = @import("skill.zig");
const system = @import("system.zig");
const testing = @import("testing.zig");

const Entry = struct {
    name: []const u8,
    /// What the command list shows after the name: the shortened sentence of
    /// this command in `FEATURES.md`.
    summary: []const u8,
    run: *const fn (*Context) anyerror!Outcome,
};

/// The command that lists every other command. The bare `/` opens it too. The
/// summary reaches no row, because the list leaves `/help` out. It states the
/// command in the table, where every other entry states one.
const help_name = "help";
const help_summary = "list every command";
/// The name prefix that loads a skill. It is the only command that takes an argument.
const skill_prefix = skill.name ++ ":";
/// Editor input can carry interior newlines (Shift+Enter, paste), so a newline
/// ends a command name like a space.
const whitespace = " \t\r\n";

/// Every command, in the order the command list shows them.
const commands = [_]Entry{
    .{ .name = effort.name, .summary = effort.summary, .run = effort.run },
    .{ .name = help_name, .summary = help_summary, .run = runHelp },
    .{ .name = login.name, .summary = login.summary, .run = login.run },
    .{ .name = logout.name, .summary = logout.summary, .run = logout.run },
    .{ .name = model.name, .summary = model.summary, .run = model.run },
    .{ .name = new.name, .summary = new.summary, .run = new.run },
    .{ .name = review.name, .summary = review.summary, .run = review.run },
    .{ .name = skill.name, .summary = skill.summary, .run = skill.run },
    .{ .name = system.name, .summary = system.summary, .run = system.run },
};

// The table is the order of the list, and the list reads best in one
// predictable order. A new command therefore takes its alphabetical place.
comptime {
    for (commands[1..], 0..) |entry, index| {
        if (!std.mem.lessThan(u8, commands[index].name, entry.name))
            @compileError("the command table must be sorted by name: " ++ entry.name);
    }
}

/// One command as a host that documents Drinky reads it: its name, its summary,
/// the line that opens it too, and the text it takes after its name.
pub const Summary = struct {
    name: []const u8,
    summary: []const u8,
    /// Another line that runs the same command, or empty for a command with one
    /// line alone. A line that carries no name at all opens a list.
    alias: []const u8 = "",
    /// What the command takes after its name, or empty for a command that takes
    /// no argument. Only a skill line carries one.
    tail: []const u8 = "",
};

/// The name and the summary of every command, in the order of the table. A host
/// that describes Drinky reads the registry from here, so its document and the
/// command list cannot drift.
pub const summaries = blk: {
    var list: [commands.len + 1]Summary = undefined;
    for (commands, 0..) |entry, index| list[index] = .{
        .name = entry.name,
        .summary = entry.summary,
        .alias = aliasOf(entry.name),
    };
    // The skill prefix is no table entry, because it takes an argument tail. Its
    // summary is its own on purpose: the `skill` entry states the list that the
    // bare name opens, and this row states the load of one named skill.
    list[commands.len] = .{
        .name = skill_prefix ++ "name",
        .summary = "load one named skill",
        .tail = "the task of the skill",
    };
    break :blk list;
};

/// The line that runs `name` beside `/name`, or empty when none does. A line
/// with no name at all is an alias of a list: `/` opens the command list, and
/// `/skill:` opens the skill list. `lookup` resolves both.
fn aliasOf(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, help_name)) return "/";
    if (std.mem.eql(u8, name, skill.name)) return "/" ++ skill_prefix;
    return "";
}

/// The rows of the command list: every command but `/help`, which names the
/// list that the user already reads.
const listed = blk: {
    var rows: [commands.len - 1]Entry = undefined;
    var count = 0;
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, help_name)) continue;
        rows[count] = entry;
        count += 1;
    }
    break :blk rows;
};

/// The command name in an input line, or null when the line is a plain message.
/// Every line that starts with a slash is a command line, because the registry must
/// read it first. The name ends at the first whitespace, and `check` refuses a tail
/// that the command does not take.
pub fn parse(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/")) return null;
    const body = line[1..];
    const end = std.mem.indexOfAny(u8, body, whitespace) orelse body.len;
    return body[0..end];
}

/// Whether `name` names the command that expands a skill into a generated request.
/// A caller that cannot host such a request refuses the line before it runs. The
/// bare prefix names no skill and opens the skill list, so it expands nothing.
/// `name` must come from `parse(line)`.
pub fn loadsSkill(name: []const u8) bool {
    return name.len > skill_prefix.len and std.mem.startsWith(u8, name, skill_prefix);
}

/// The text after the command name, without its edge whitespace. `name` must come
/// from `parse(line)`, so it starts at the second byte of the line.
fn tail(line: []const u8, name: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, line[1..], name));
    return std.mem.trim(u8, line[1 + name.len ..], whitespace);
}

/// The registry entry with `name`, or null when the registry holds no such command.
/// A `skill:name` never has an entry, because that prefix takes an argument tail.
///
/// The empty name and the bare `skill:` prefix are aliases of a list: `/` opens
/// the command list like `/help`, and `/skill:` opens the skill list like
/// `/skill`. Both carry no name at all, so the list is the answer.
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

/// The command list: one row per command, in the order of the table. A selection
/// runs that command, so a command that opens a picker of its own becomes the
/// second layer of the list.
fn runHelp(context: *Context) !Outcome {
    var options: Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (listed) |entry| try options.print("/{s} — {s}", .{ entry.name, entry.summary });
    // The list builds itself again, so Esc in the picker that a row opens
    // returns to the list.
    return .{ .pick = .{
        .select = selectCommand,
        .title = "Command",
        .cancellation_message = "You canceled the command selection.",
        .options = try options.toOwnedSlice(),
        .current = null,
        .reopen = runHelp,
    } };
}

fn selectCommand(context: *Context, index: usize) !Outcome {
    if (index >= listed.len)
        return Outcome.reportNotice(context.gpa, .failure, "Select a valid command.", .{});
    return listed[index].run(context);
}

/// The refusal that the registry produces for `line`, or null when the registry
/// can run the line as typed. `check` runs no command, so a caller that must
/// refuse a command for a state restriction can name the true reason first: an
/// unknown name and an unwanted tail never become runnable, but a restriction
/// ends. A line that is not a command line returns null too.
///
/// Every refusal here warns, because a slash line can be plain text. The caller
/// can offer to send the line to the model as typed.
pub fn check(context: *Context, line: []const u8) !?Outcome.Message {
    const name = parse(line) orelse return null;
    if (loadsSkill(name)) return try checkSkill(context, name);
    if (lookup(name) == null) return try unknownCommand(context.gpa, name);
    if (tail(line, name).len > 0) return try Outcome.Message.print(
        context.gpa,
        .warning,
        "The command /{s} takes no argument.",
        .{name},
    );
    return null;
}

/// Dispatch an input line to its command. Null reports that the line is not a
/// command, so the caller sends it to the model. A line that the registry cannot
/// run as typed returns the refusal of `check`, so the line stays local.
pub fn run(context: *Context, line: []const u8) !?Outcome {
    const name = parse(line) orelse return null;
    if (try check(context, line)) |refusal| return .{ .refusal = refusal };
    // `check` accepted the line, so every lookup below holds. This is the one place
    // that resolves a name, so no other function carries that invariant.
    if (loadsSkill(name)) {
        const target = context.skill_registry.?.get(name[skill_prefix.len..]).?;
        return try runSkill(context, target, tail(line, name));
    }
    return try lookup(name).?.run(context);
}

/// Refuse a parsed command that the active state does not allow. The caller keeps
/// the command text in the editor, sends nothing to the model, and opens no
/// picker. `restriction` names the active state and completes the sentence
/// `The command /name cannot run …`, as in `while a turn runs`.
///
/// The severity is a warning, not a failure: the line stays complete, and the next
/// Enter runs it once the restriction ends. A failure carries the red `Error:`
/// prefix, which reads as a broken turn while a reply streams.
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

/// The refusal for a `skill:` name that no discovered skill matches, or null when
/// the registry holds it. A load failure stays with `runSkill`, because only the
/// load itself can report one. The bare prefix never reaches here, because it
/// names the skill list rather than a skill.
fn checkSkill(context: *Context, command_name: []const u8) !?Outcome.Message {
    const name = command_name[skill_prefix.len..];
    const registry = context.skill_registry orelse return try unknownSkill(context.gpa, name);
    if (registry.get(name) == null) return try unknownSkill(context.gpa, name);
    return null;
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

/// Expand `target` with its optional task into a user turn. The caller resolved
/// the skill, so this function holds no name invariant.
fn runSkill(context: *Context, target: *const skills.Skill, arguments: []const u8) !Outcome {
    const content = target.invoke(context.gpa, context.io, arguments) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        // A failure, not a warning: the name is right and the load broke, so the
        // way forward is another try, not a send to the model.
        return .{ .refusal = try Outcome.Message.print(
            context.gpa,
            .failure,
            "Drinky could not load the skill {s} because of error {s}.",
            .{ target.name, @errorName(err) },
        ) };
    };
    errdefer context.gpa.free(content);
    const name_copy = try context.gpa.dupe(u8, target.name);
    errdefer context.gpa.free(name_copy);
    const arguments_copy = try context.gpa.dupe(u8, arguments);
    errdefer context.gpa.free(arguments_copy);
    const source_copy = try context.gpa.dupe(u8, target.path);
    return .{ .prompt = .{
        .name = name_copy,
        .arguments = arguments_copy,
        .content = content,
        .source = source_copy,
    } };
}

// A line that carries no name opens a list, so the registry states that line
// beside the command it runs. A host that documents Drinky then names it, and a
// reader learns what a bare `/` does.
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
    // The registry sends nothing, and `/new` never clears the conversation.
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

// A caller that must refuse a command for its own state restriction asks `check`
// first, so the reason it reports is the true one. `check` runs no command.
test "check reports only what keeps a line unrunnable" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    // The registry can run these, so the caller owns the refusal.
    try std.testing.expect((try check(&context, "/effort")) == null);
    try std.testing.expect((try check(&context, "not a command")) == null);

    // These never become runnable, whatever the state does.
    const unknown_name = (try check(&context, "/nope")).?;
    try unknown_name.expect(.warning, "does not recognize the command");
    const unwanted_tail = (try check(&context, "/effort high")).?;
    try unwanted_tail.expect(.warning, "takes no argument");
    const unknown_skill = (try check(&context, "/skill:nope")).?;
    try unknown_skill.expect(.warning, "does not recognize the skill");

    // No command ran, so `/effort` opened no picker and changed no level.
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
    // The registry reads the first byte. The app trims the prompt edges before
    // dispatch, so a leading blank is no user-facing escape from a command line.
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

// The list is the answer for a line that carries no name at all. `/` and `/help`
// open the command list, and `/skill` and `/skill:` open the skill list.
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
                    for (pick.options) |option| gpa.free(option);
                    gpa.free(pick.options);
                }
                try std.testing.expectEqualStrings("Command", pick.title);
                // The list builds itself again, so Esc in the picker that a row
                // opens returns to the list.
                try std.testing.expect(pick.reopen.? == &runHelp);
                try std.testing.expectEqual(commands.len - 1, pick.options.len);
                // Alphabetical, the summary after the name, and no `/help` row.
                try std.testing.expectEqualStrings(
                    "/effort — set the reasoning-effort level",
                    pick.options[0],
                );
                try std.testing.expectEqualStrings(
                    "/system — inspect the complete system prompt",
                    pick.options[pick.options.len - 1],
                );
                for (pick.options) |option|
                    try std.testing.expect(!std.mem.startsWith(u8, option, "/help"));
            },
            else => return error.ExpectedPick,
        }
    }

    // No skill exists here, so both skill lines report that instead of a list.
    for ([_][]const u8{ "/skill", "/skill:" }) |line|
        try Outcome.expectNoticeContaining((try run(&context, line)).?, .warning, "found no skills");

    // A list line takes no argument either.
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

// A row of the list runs the command it names, so a command with a picker of its
// own opens the second layer.
test "a command row runs its command" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    const rows = listed;
    const system_index = for (rows, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, system.name)) break index;
    } else return error.MissingSystemRow;
    try std.testing.expect((try selectCommand(&context, system_index)) == .show_system_prompt);

    const effort_index = for (rows, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, effort.name)) break index;
    } else return error.MissingEffortRow;
    switch (try selectCommand(&context, effort_index)) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expect(pick.select == &effort.select);
        },
        else => return error.ExpectedPick,
    }

    try Outcome.expectNoticeContaining(
        try selectCommand(&context, rows.len),
        .failure,
        "valid command",
    );
}
