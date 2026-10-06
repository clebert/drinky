const std = @import("std");

const tools = @import("tools");

const discovery = @import("discovery/root.zig");
const escape = @import("escape.zig");
const testing = @import("testing.zig");

const default_core =
    "# System prompt\n\n" ++
    "You are a coding assistant. You run inside Drinky, a terminal coding-agent harness.\n\n" ++
    "Complete the user's request.\n" ++
    "Use the available tools according to their schemas.\n" ++
    "Use the find tool and the grep tool to search files.\n" ++
    "Run a search in bash only when these tools cannot express it.\n" ++
    "Read a file before you change it, because an edit must match the current bytes.\n" ++
    "Answer a question about Drinky itself from the describe_drinky tool, and never from " ++
    "memory.\n" ++
    "Drinky renders your answer as Markdown in a terminal, so keep it short.";

const date_timestamp_nanoseconds_max: i96 =
    253_402_300_800 * std.time.ns_per_s - 1;

const Options = struct {
    current_time: std.Io.Timestamp,
    working_directory: []const u8,
    user_instructions: []const discovery.instructions.File,
    project_instructions: *const discovery.instructions.Result,
    skills: []const discovery.skills.Skill,
    required_skills: []const tools.SkillGuard.Rule,
    surface: discovery.skills.Skill.Surface,
};

const InstructionsOptions = struct {
    title: []const u8,
    tag: []const u8,
    files: []const discovery.instructions.File,
};

pub fn compose(gpa: std.mem.Allocator, options: *const Options) error{OutOfMemory}![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    write(gpa, &output.writer, options) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn write(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    options: *const Options,
) (std.Io.Writer.Error || error{OutOfMemory})!void {
    try writer.writeAll(default_core);
    try writeEnvironment(gpa, writer, options);
    const project_files = options.project_instructions.files();
    try writePrecedence(writer, options);
    if (options.user_instructions.len > 0) try writeInstructions(gpa, writer, &.{
        .title = "User instructions",
        .tag = "user_instructions",
        .files = options.user_instructions,
    });
    if (project_files.len > 0) try writeInstructions(gpa, writer, &.{
        .title = "Project instructions",
        .tag = "project_instructions",
        .files = project_files,
    });
    if (anyAdvertised(options)) try writeSkills(gpa, writer, options);
    if (options.required_skills.len > 0)
        try writeRequiredSkills(gpa, writer, options.required_skills);
}

fn writePrecedence(writer: *std.Io.Writer, options: *const Options) !void {
    const project_files = options.project_instructions.files();
    const has_skills = anyAdvertised(options);
    if (options.user_instructions.len == 0 and project_files.len == 0 and !has_skills) return;
    try writer.writeAll("\n\n## Instruction precedence\n\n" ++
        "Drinky gives you instructions from the sources below. Where two conflict, obey this " ++
        "order:\n\n" ++
        "1. The system prompt core.\n");
    var rank: usize = 1;
    if (options.user_instructions.len > 0) {
        rank += 1;
        try writer.print("{d}. The user instructions.\n", .{rank});
    }
    if (project_files.len > 0) {
        rank += 1;
        try writer.print("{d}. The project instructions.\n", .{rank});
    }
    if (has_skills) {
        rank += 1;
        try writer.print("{d}. The skills.\n", .{rank});
    }
    try writer.writeAll(
        "\nA request in the conversation wins over a conflicting instruction from these sources.",
    );
    if (project_files.len > 1) try writer.writeAll(
        "\nA more specific project instruction file wins in its own directory tree.",
    );
}

fn writeInstructions(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    options: *const InstructionsOptions,
) !void {
    try writer.print("\n\n## {s}\n\n<{s}>\n", .{ options.title, options.tag });
    for (options.files) |file| {
        try writer.writeAll("  <instruction_file path=\"");
        try writePath(gpa, writer, file.path);
        try writer.writeAll("\">\n");
        try writer.writeAll(file.content);
        if (!std.mem.endsWith(u8, file.content, "\n")) try writer.writeByte('\n');
        try writer.writeAll("  </instruction_file>\n");
    }
    try writer.print("</{s}>", .{options.tag});
}

fn dateUtc(timestamp: std.Io.Timestamp) ?[10]u8 {
    const timestamp_nanoseconds = timestamp.toNanoseconds();
    if (timestamp_nanoseconds < 0 or
        timestamp_nanoseconds > date_timestamp_nanoseconds_max)
    {
        return null;
    }
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = @intCast(@divFloor(timestamp_nanoseconds, std.time.ns_per_s)),
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var date: [10]u8 = undefined;
    const rendered = std.fmt.bufPrint(&date, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch unreachable;
    std.debug.assert(rendered.len == date.len);
    return date;
}

fn writeEnvironment(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    options: *const Options,
) !void {
    try writer.writeAll("\n\n## Environment\n\n<environment>\n");
    if (dateUtc(options.current_time)) |current_date| {
        try writer.writeAll("  <current_date>");
        try writer.writeAll(&current_date);
        try writer.writeAll("</current_date>\n");
    } else {
        try writer.writeAll("  <current_date />\n");
    }
    try writer.writeAll("  <working_directory>");
    try writePath(gpa, writer, options.working_directory);
    try writer.writeAll("</working_directory>\n");
    if (options.project_instructions.projectRoot()) |project_root| {
        try writer.writeAll("  <repository_root>");
        try writePath(gpa, writer, project_root);
        try writer.writeAll("</repository_root>\n");
    } else {
        try writer.writeAll("  <repository_root />\n");
    }
    try writer.writeAll("</environment>");
}

fn anyAdvertised(options: *const Options) bool {
    for (options.skills) |*skill| {
        if (skill.advertised(options.surface)) return true;
    }
    return false;
}

fn writeSkills(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: *const Options) !void {
    try writer.writeAll("\n\n## Skills\n\n");
    try writer.writeAll(
        "The skills below provide specialized instructions.\n" ++
            "When the user requests a skill or the task matches a skill description, read the " ++
            "skill file before you proceed.\n\n" ++
            "<skills>\n",
    );
    for (options.skills) |*skill| {
        if (!skill.advertised(options.surface)) continue;
        try writer.writeAll("  <skill_file path=\"");
        try writePath(gpa, writer, skill.path);
        try writer.writeAll("\">\n    <name>");
        try writeEscaped(writer, skill.name);
        try writer.writeAll("</name>\n    <description>");
        try writeEscaped(writer, skill.description);
        if (skill.description_truncated) try writer.writeAll("…");
        try writer.writeAll("</description>\n  </skill_file>\n");
    }
    try writer.writeAll("</skills>");
}

fn writeRequiredSkills(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    rules: []const tools.SkillGuard.Rule,
) !void {
    try writer.writeAll("\n\n## Required skills\n\n");
    try writer.writeAll(
        "A rule below pairs a path pattern with a skill file.\n" ++
            "Drinky sends you the whole skill file when a tool first touches a file that the " ++
            "pattern matches.\n" ++
            "Read that skill file, and follow it for every file of that pattern.\n" ++
            "Drinky refuses the write tool and the edit tool for a file of that pattern until " ++
            "the whole skill file is in this conversation.\n\n" ++
            "<required_skills>\n",
    );
    for (rules) |rule| {
        try writer.writeAll("  <required_skill pattern=\"");
        try writeEscaped(writer, rule.glob);
        try writer.writeAll("\" skill=\"");
        try writeEscaped(writer, rule.skill);
        try writer.writeAll("\" path=\"");
        try writePath(gpa, writer, rule.source);
        try writer.writeAll("\" />\n");
    }
    try writer.writeAll("</required_skills>");
}

fn writePath(gpa: std.mem.Allocator, writer: *std.Io.Writer, path: []const u8) !void {
    const display = try escape.display(gpa, path);
    defer gpa.free(display);
    try writeEscaped(writer, display);
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(byte),
    };
}

test "UTC date formatting handles bounds and a leap day" {
    const epoch_date = dateUtc(.zero).?;
    try std.testing.expectEqualStrings("1970-01-01", &epoch_date);

    const leap_date = dateUtc(.fromNanoseconds(951_782_400 * std.time.ns_per_s)).?;
    try std.testing.expectEqualStrings("2000-02-29", &leap_date);

    const final_date = dateUtc(.fromNanoseconds(date_timestamp_nanoseconds_max)).?;
    try std.testing.expectEqualStrings("9999-12-31", &final_date);
    try std.testing.expectEqual(@as(?[10]u8, null), dateUtc(.fromNanoseconds(-1)));
    try std.testing.expectEqual(
        @as(?[10]u8, null),
        dateUtc(.fromNanoseconds(date_timestamp_nanoseconds_max + 1)),
    );
}

const no_instructions: discovery.instructions.Result = .init(std.testing.allocator, .project);

fn emptyOptions() Options {
    return .{
        .current_time = .zero,
        .working_directory = "/work",
        .user_instructions = &.{},
        .project_instructions = &no_instructions,
        .skills = &.{},
        .required_skills = &.{},
        .surface = .session,
    };
}

fn testSkill(options: *const struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
    description_truncated: bool = false,
    model_invocation_disabled: bool = false,
    run_hidden: bool = false,
    scope: discovery.skills.Skill.Scope = .user,
}) discovery.skills.Skill {
    return .{
        .name = options.name,
        .description = options.description,
        .description_truncated = options.description_truncated,
        .path = options.path,
        .model_invocation_disabled = options.model_invocation_disabled,
        .run_hidden = options.run_hidden,
        .scope = options.scope,
    };
}

test "a wall clock outside the supported years empties the date but composes" {
    const gpa = std.testing.allocator;
    var options = emptyOptions();
    options.current_time = .fromNanoseconds(-1);
    const prompt = try compose(gpa, &options);
    defer gpa.free(prompt);
    try std.testing.expectEqualStrings(
        default_core ++ "\n\n## Environment\n\n<environment>\n" ++
            "  <current_date />\n" ++
            "  <working_directory>/work</working_directory>\n" ++
            "  <repository_root />\n</environment>",
        prompt,
    );
}

test "composition orders sections and preserves instruction Markdown" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    const broad = "# Broad\n\n```sh\nleft && printf '<tag>'\n```\n";
    try tree.directory("repo&root/.git");
    try tree.write("repo&root/AGENTS.md", broad);
    try tree.write("repo&root/package/AGENTS.md", "specific");
    const working_directory = try tree.path("repo&root/package");
    var discovered = try discovery.instructions.discover(gpa, io, working_directory);
    defer discovered.deinit();

    const skill_items = [_]discovery.skills.Skill{
        testSkill(&.{
            .name = "example",
            .description = "Use <this> & \"that\"",
            .path = "/skills/a'b/SKILL.md",
            .description_truncated = true,
        }),
        testSkill(&.{
            .name = "second",
            .description = "Use the second skill.",
            .path = "/skills/second/SKILL.md",
            .scope = .project,
        }),
        testSkill(&.{
            .name = "hidden",
            .description = "not shown",
            .path = "/skills/hidden/SKILL.md",
            .model_invocation_disabled = true,
        }),
    };
    var options = emptyOptions();
    options.working_directory = working_directory;
    options.project_instructions = &discovered;
    options.skills = &skill_items;
    const prompt = try compose(gpa, &options);
    defer gpa.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, default_core));
    const environment_index = std.mem.indexOf(u8, prompt, "## Environment").?;
    const precedence_index = std.mem.indexOf(u8, prompt, "## Instruction precedence").?;
    const project_index = std.mem.indexOf(u8, prompt, "## Project instructions").?;
    const skills_index = std.mem.indexOf(u8, prompt, "## Skills").?;
    try std.testing.expect(environment_index < precedence_index);
    try std.testing.expect(precedence_index < project_index);
    try std.testing.expect(project_index < skills_index);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "<current_date>1970-01-01</current_date>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "1. The system prompt core.\n" ++
            "2. The project instructions.\n" ++
            "3. The skills.\n\n" ++
            "A request in the conversation wins over a conflicting instruction from these " ++
            "sources.\n" ++
            "A more specific project instruction file wins in its own directory tree.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "The user instructions.") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "repo&amp;root/package") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, broad) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "left &amp;&amp;") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "Use &lt;this&gt; &amp; &quot;that&quot;…",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "The skills below provide specialized instructions.\n" ++
            "When the user requests a skill or the task matches a skill description, read the " ++
            "skill file before you proceed.\n\n" ++
            "<skills>\n  <skill_file path=\"/skills/a&apos;b/SKILL.md\">",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<location>") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "<skill_file path=\"/skills/second/SKILL.md\">\n" ++
            "    <name>second</name>\n" ++
            "    <description>Use the second skill.</description>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<name>hidden</name>") == null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, prompt, "<skill_file path="),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "## Project instructions\n\n" ++
            "<project_instructions>\n" ++
            "  <instruction_file path=\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "  </instruction_file>\n</project_instructions>\n\n## Skills",
    ) != null);
    const broad_index = std.mem.indexOf(u8, prompt, "# Broad").?;
    const specific_index = std.mem.indexOf(u8, prompt, "\">\nspecific\n").?;
    try std.testing.expect(broad_index < specific_index);
}

test "configured user instructions have their own section" {
    const gpa = std.testing.allocator;
    const user_instructions = [_]discovery.instructions.File{
        .{
            .path = "/home/a&b/first.md",
            .content = "# Tone\n\nKeep <xml> && shell operators.",
            .identity = "/home/a&b/first.md",
        },
        .{
            .path = "/home/second.md",
            .content = "Use direct language.\n",
            .identity = "/home/second.md",
        },
    };
    var options = emptyOptions();
    options.current_time = .fromNanoseconds(1_785_628_800 * std.time.ns_per_s);
    options.user_instructions = &user_instructions;
    const prompt = try compose(gpa, &options);
    defer gpa.free(prompt);

    try std.testing.expectEqualStrings(
        default_core ++ "\n\n## Environment\n\n<environment>\n" ++
            "  <current_date>2026-08-02</current_date>\n" ++
            "  <working_directory>/work</working_directory>\n" ++
            "  <repository_root />\n" ++
            "</environment>\n\n" ++
            "## Instruction precedence\n\n" ++
            "Drinky gives you instructions from the sources below. Where two conflict, obey " ++
            "this order:\n\n" ++
            "1. The system prompt core.\n" ++
            "2. The user instructions.\n\n" ++
            "A request in the conversation wins over a conflicting instruction from these " ++
            "sources.\n\n" ++
            "## User instructions\n\n" ++
            "<user_instructions>\n" ++
            "  <instruction_file path=\"/home/a&amp;b/first.md\">\n" ++
            "# Tone\n\nKeep <xml> && shell operators.\n" ++
            "  </instruction_file>\n" ++
            "  <instruction_file path=\"/home/second.md\">\n" ++
            "Use direct language.\n" ++
            "  </instruction_file>\n" ++
            "</user_instructions>",
        prompt,
    );
}

test "the required skills section names every rule and stays out without one" {
    const gpa = std.testing.allocator;
    const skill_items = [_]discovery.skills.Skill{
        testSkill(&.{
            .name = "zig-style",
            .description = "Zig conventions.",
            .path = "/work/.agents/skills/zig-style/SKILL.md",
            .scope = .project,
        }),
    };
    const rules = [_]tools.SkillGuard.Rule{
        .{
            .glob = "**/*.zig",
            .skill = "zig-style",
            .source = "/work/.agents/skills/zig-style/SKILL.md",
        },
        .{ .glob = "src/<b>/*.ts", .skill = "ts-style", .source = "/work/skills/ts/SKILL.md" },
    };
    var options = emptyOptions();
    options.skills = &skill_items;
    options.required_skills = &rules;
    const prompt = try compose(gpa, &options);
    defer gpa.free(prompt);

    const skills_index = std.mem.indexOf(u8, prompt, "## Skills").?;
    const required_index = std.mem.indexOf(u8, prompt, "## Required skills").?;
    try std.testing.expect(skills_index < required_index);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "Drinky refuses the write tool and the edit tool for a file of that pattern until " ++
            "the whole skill file is in this conversation.\n\n" ++
            "<required_skills>\n" ++
            "  <required_skill pattern=\"**/*.zig\" skill=\"zig-style\" " ++
            "path=\"/work/.agents/skills/zig-style/SKILL.md\" />\n" ++
            "  <required_skill pattern=\"src/&lt;b&gt;/*.ts\" skill=\"ts-style\" " ++
            "path=\"/work/skills/ts/SKILL.md\" />\n" ++
            "</required_skills>",
    ) != null);

    var plain_options = emptyOptions();
    plain_options.skills = &skill_items;
    const plain = try compose(gpa, &plain_options);
    defer gpa.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "## Required skills") == null);
}

test "generated paths cannot add prompt lines or controls" {
    const gpa = std.testing.allocator;
    var options = emptyOptions();
    options.working_directory = "/work\n```\x1b\xe2\x80\xae&\"'";
    const prompt = try compose(gpa, &options);
    defer gpa.free(prompt);

    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "  <working_directory>/work\\x0a```\\x1b\\xe2\\x80\\xae&amp;&quot;&apos;" ++
            "</working_directory>\n",
    ) != null);
}

test "a session lists a skill that its metadata hides from a run, and a run leaves it out" {
    const gpa = std.testing.allocator;
    const skill_items = [_]discovery.skills.Skill{
        testSkill(&.{
            .name = "review",
            .description = "Review through a second agent.",
            .path = "/skills/review/SKILL.md",
            .run_hidden = true,
        }),
    };
    var session_options = emptyOptions();
    session_options.skills = &skill_items;
    const session_prompt = try compose(gpa, &session_options);
    defer gpa.free(session_prompt);
    try std.testing.expect(std.mem.indexOf(u8, session_prompt, "<name>review</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_prompt, "2. The skills.") != null);

    var run_options = emptyOptions();
    run_options.skills = &skill_items;
    run_options.surface = .run;
    const run_prompt = try compose(gpa, &run_options);
    defer gpa.free(run_prompt);
    try std.testing.expectEqualStrings(
        default_core ++ "\n\n## Environment\n\n<environment>\n" ++
            "  <current_date>1970-01-01</current_date>\n" ++
            "  <working_directory>/work</working_directory>\n" ++
            "  <repository_root />\n</environment>",
        run_prompt,
    );
}

test "empty project and skill sections are omitted independently" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const hidden_items = [_]discovery.skills.Skill{
        testSkill(&.{
            .name = "hidden",
            .description = "manual only",
            .path = "/hidden/SKILL.md",
            .model_invocation_disabled = true,
        }),
    };
    var empty_options = emptyOptions();
    empty_options.working_directory = "/work&space";
    empty_options.skills = &hidden_items;
    const empty_prompt = try compose(gpa, &empty_options);
    defer gpa.free(empty_prompt);
    try std.testing.expectEqualStrings(
        default_core ++ "\n\n## Environment\n\n<environment>\n" ++
            "  <current_date>1970-01-01</current_date>\n" ++
            "  <working_directory>/work&amp;space</working_directory>\n" ++
            "  <repository_root />\n</environment>",
        empty_prompt,
    );

    const visible_items = [_]discovery.skills.Skill{
        testSkill(&.{ .name = "visible", .description = "shown", .path = "/visible/SKILL.md" }),
    };
    var skill_options = emptyOptions();
    skill_options.skills = &visible_items;
    const skill_prompt = try compose(gpa, &skill_options);
    defer gpa.free(skill_prompt);
    try std.testing.expect(std.mem.indexOf(u8, skill_prompt, "## Project instructions") == null);
    try std.testing.expect(std.mem.indexOf(u8, skill_prompt, "## Skills") != null);

    var tree: testing.Tree = try .init();
    defer tree.deinit();
    try tree.directory("repo/.git");
    try tree.write("repo/AGENTS.md", "project");
    const working_directory = try tree.path("repo");
    var project_instructions = try discovery.instructions.discover(gpa, io, working_directory);
    defer project_instructions.deinit();
    var project_options = emptyOptions();
    project_options.working_directory = working_directory;
    project_options.project_instructions = &project_instructions;
    project_options.skills = &hidden_items;
    const project_prompt = try compose(gpa, &project_options);
    defer gpa.free(project_prompt);
    try std.testing.expect(std.mem.indexOf(u8, project_prompt, "## Project instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_prompt, "## Skills") == null);
}
