//! Pure composition of Drinky's provider-neutral system prompt.

const std = @import("std");

const ai = @import("ai");

/// The core that Drinky compiles in. It states the mechanical facts of the
/// harness: the role, the tools, the edit contract, and the medium. Workflow,
/// tone, and review rules stay out, because the user cannot switch off what the
/// binary holds. The user instructions, the project instructions, and the skills
/// carry that guidance, and the user controls all three.
pub const default_core =
    "# System Prompt\n\n" ++
    "You are a coding assistant operating inside Drinky, a terminal coding-agent harness.\n\n" ++
    "Complete the user's request.\n" ++
    "Use the available tools according to their schemas.\n" ++
    "Read a file before you change it, because an edit must match the current bytes.\n" ++
    "Drinky renders your answer as Markdown in a terminal, so keep it short.";

/// The final nanosecond of 9999-12-31 UTC.
const date_timestamp_nanoseconds_max: i96 =
    253_402_300_800 * std.time.ns_per_s - 1;

pub const Options = struct {
    core: []const u8,
    /// The wall clock at startup. Drinky reads it once, so the prompt stays byte
    /// stable for the session and the provider can cache it. A session that runs
    /// past midnight therefore keeps the date it started on.
    current_time: std.Io.Timestamp,
    working_directory: []const u8,
    user_instructions: []const ai.instructions.File,
    project_instructions: *const ai.instructions.Result,
    skills: ai.skills.Catalog,
    /// The path-triggered skill rules of the session. Each one already names a
    /// discovered skill, so a configured rule that resolved to none states
    /// nothing here. An empty list leaves the section out.
    required_skills: []const ai.tool.SkillGuard.Rule = &.{},
};

const InstructionsOptions = struct {
    title: []const u8,
    tag: []const u8,
    files: []const ai.instructions.File,
};

pub fn compose(gpa: std.mem.Allocator, options: *const Options) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    try output.writer.writeAll(options.core);
    try writeEnvironment(gpa, &output.writer, options);
    const project_files = options.project_instructions.files();
    try writePrecedence(&output.writer, options);
    if (options.user_instructions.len > 0) try writeInstructions(gpa, &output.writer, &.{
        .title = "User instructions",
        .tag = "user_instructions",
        .files = options.user_instructions,
    });
    if (project_files.len > 0) try writeInstructions(gpa, &output.writer, &.{
        .title = "Project instructions",
        .tag = "project_instructions",
        .files = project_files,
    });
    if (options.skills.count() > 0) try writeSkills(gpa, &output.writer, &options.skills);
    if (options.required_skills.len > 0)
        try writeRequiredSkills(gpa, &output.writer, options.required_skills);
    return output.toOwnedSlice();
}

/// Rank the instruction sources for the model. Drinky lists only the sources that
/// this prompt carries, so the model never reads about a section it cannot see.
/// A prompt with no source at all gets no ranking.
fn writePrecedence(writer: *std.Io.Writer, options: *const Options) !void {
    const project_files = options.project_instructions.files();
    const has_skills = options.skills.count() > 0;
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

/// Write one instruction section. The user and the project sections differ only
/// in their title and their tag, so both stream through here.
///
/// The content goes in as it is, because escaping it corrupts the Markdown
/// the user wrote. The tags mark the bounds, so a heading inside a file cannot
/// end the section. A file that forges a closing tag can still claim a higher
/// rank, which is why Drinky trusts only what the user and the repository own.
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

/// Render the UTC date of `timestamp`. Null reports a wall clock outside the
/// years 1970 through 9999, which must not stop Drinky from starting.
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

fn writeSkills(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    catalog: *const ai.skills.Catalog,
) !void {
    try writer.writeAll("\n\n## Skills\n\n");
    try writer.writeAll(
        "The following skills provide specialized instructions.\n" ++
            "When the user requests a skill or the task matches a skill description, read that " ++
            "skill's SKILL.md before you proceed.\n\n" ++
            "<skills>\n",
    );
    var iterator = catalog.iterator();
    for (0..catalog.count()) |_| {
        const skill = iterator.next() orelse return error.InvalidSkillCatalog;
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

/// Name every path-triggered skill rule, so the model reads a skill before a
/// write rather than after a refusal. The guard stays the backstop: it refuses
/// the call whatever this section says.
fn writeRequiredSkills(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    rules: []const ai.tool.SkillGuard.Rule,
) !void {
    try writer.writeAll("\n\n## Required skills\n\n");
    try writer.writeAll(
        "A rule below pairs a path pattern with a skill file.\n" ++
            "Drinky sends you the whole skill file when a tool first touches a file that the " ++
            "pattern matches.\n" ++
            "Read that skill file, and follow it for every file of that pattern.\n" ++
            "Drinky refuses a write and an edit until the whole skill file is in this " ++
            "conversation.\n\n" ++
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
    const display = try ai.instructions.displayAlloc(gpa, path);
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

fn tmpPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    tmp: *const std.testing.TmpDir,
    suffix: []const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, suffix });
}

const TestFileOptions = struct {
    path: []const u8,
    data: []const u8,
};

fn writeTestFile(io: std.Io, dir: std.Io.Dir, options: *const TestFileOptions) !void {
    if (std.fs.path.dirname(options.path)) |parent| {
        var directory = try dir.createDirPathOpen(io, parent, .{});
        directory.close(io);
    }
    try dir.writeFile(io, .{ .sub_path = options.path, .data = options.data });
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

test "a wall clock outside the supported years empties the date but composes" {
    const gpa = std.testing.allocator;
    var empty_instructions = ai.instructions.Result.init(gpa, .project);
    defer empty_instructions.deinit();
    const prompt = try compose(gpa, &.{
        .core = "core",
        .current_time = .fromNanoseconds(-1),
        .working_directory = "/work",
        .user_instructions = &.{},
        .project_instructions = &empty_instructions,
        .skills = try ai.skills.Catalog.init(&.{}),
    });
    defer gpa.free(prompt);
    try std.testing.expectEqualStrings(
        "core\n\n## Environment\n\n<environment>\n" ++
            "  <current_date />\n" ++
            "  <working_directory>/work</working_directory>\n" ++
            "  <repository_root />\n</environment>",
        prompt,
    );
}

test "the compiled core is stable" {
    try std.testing.expectEqualStrings(
        "# System Prompt\n\n" ++
            "You are a coding assistant operating inside Drinky, a terminal coding-agent " ++
            "harness.\n\n" ++
            "Complete the user's request.\n" ++
            "Use the available tools according to their schemas.\n" ++
            "Read a file before you change it, because an edit must match the current bytes.\n" ++
            "Drinky renders your answer as Markdown in a terminal, so keep it short.",
        default_core,
    );
}

test "composition orders sections and preserves instruction Markdown" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const broad = "# Broad\n\n```sh\nleft && printf '<tag>'\n```\n";
    var git = try tmp.dir.createDirPathOpen(io, "repo&root/.git", .{});
    git.close(io);
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo&root/AGENTS.md",
        .data = broad,
    });
    try writeTestFile(io, tmp.dir, &.{
        .path = "repo&root/package/AGENTS.md",
        .data = "specific",
    });
    const working_directory = try tmpPath(gpa, io, &tmp, "repo&root/package");
    defer gpa.free(working_directory);
    var instructions = try ai.instructions.discover(gpa, io, working_directory);
    defer instructions.deinit();

    const skill_items = [_]ai.skills.Skill{
        .{
            .name = "example",
            .description = "Use <this> & \"that\"",
            .description_truncated = true,
            .path = "/skills/a'b/SKILL.md",
            .model_invocation_disabled = false,
            .scope = .user,
        },
        .{
            .name = "second",
            .description = "Use the second skill.",
            .description_truncated = false,
            .path = "/skills/second/SKILL.md",
            .model_invocation_disabled = false,
            .scope = .project,
        },
        .{
            .name = "hidden",
            .description = "not shown",
            .description_truncated = false,
            .path = "/skills/hidden/SKILL.md",
            .model_invocation_disabled = true,
            .scope = .user,
        },
    };
    const catalog = try ai.skills.Catalog.init(&skill_items);
    const prompt = try compose(gpa, &.{
        .core = default_core,
        .current_time = .zero,
        .working_directory = working_directory,
        .user_instructions = &.{},
        .project_instructions = &instructions,
        .skills = catalog,
    });
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
    // This prompt carries no user instructions, so the ranking skips that source
    // and the skills take rank 3.
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
        "The following skills provide specialized instructions.\n" ++
            "When the user requests a skill or the task matches a skill description, read that " ++
            "skill's SKILL.md before you proceed.\n\n" ++
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
    var empty_instructions = ai.instructions.Result.init(gpa, .project);
    defer empty_instructions.deinit();
    const empty_catalog = try ai.skills.Catalog.init(&.{});
    const user_instructions = [_]ai.instructions.File{
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
    const prompt = try compose(gpa, &.{
        .core = "core",
        .current_time = .fromNanoseconds(1_785_628_800 * std.time.ns_per_s),
        .working_directory = "/work",
        .user_instructions = &user_instructions,
        .project_instructions = &empty_instructions,
        .skills = empty_catalog,
    });
    defer gpa.free(prompt);

    try std.testing.expectEqualStrings(
        "core\n\n## Environment\n\n<environment>\n" ++
            "  <current_date>2026-08-02</current_date>\n" ++
            "  <working_directory>/work</working_directory>\n" ++
            "  <repository_root />\n" ++
            "</environment>\n\n" ++
            // The user files are the only source here, so the ranking names
            // them alone and drops the subtree rule of the project files.
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

// The model reads a required skill before a write, rather than after a
// refusal, so the prompt must name every rule the guard applies.
test "the required skills section names every rule and stays out without one" {
    const gpa = std.testing.allocator;
    var empty_instructions = ai.instructions.Result.init(gpa, .project);
    defer empty_instructions.deinit();
    const skill_items = [_]ai.skills.Skill{.{
        .name = "zig-style",
        .description = "Zig conventions.",
        .description_truncated = false,
        .path = "/work/.agents/skills/zig-style/SKILL.md",
        .model_invocation_disabled = false,
        .scope = .project,
    }};
    const rules = [_]ai.tool.SkillGuard.Rule{
        .{
            .glob = "**/*.zig",
            .skill = "zig-style",
            .source = "/work/.agents/skills/zig-style/SKILL.md",
        },
        .{ .glob = "src/<b>/*.ts", .skill = "ts-style", .source = "/work/skills/ts/SKILL.md" },
    };
    const prompt = try compose(gpa, &.{
        .core = "core",
        .current_time = .zero,
        .working_directory = "/work",
        .user_instructions = &.{},
        .project_instructions = &empty_instructions,
        .skills = try ai.skills.Catalog.init(&skill_items),
        .required_skills = &rules,
    });
    defer gpa.free(prompt);

    // The rules follow the catalog, because a rule names a skill of it.
    const skills_index = std.mem.indexOf(u8, prompt, "## Skills").?;
    const required_index = std.mem.indexOf(u8, prompt, "## Required skills").?;
    try std.testing.expect(skills_index < required_index);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "Drinky refuses a write and an edit until the whole skill file is in this " ++
            "conversation.\n\n" ++
            "<required_skills>\n" ++
            "  <required_skill pattern=\"**/*.zig\" skill=\"zig-style\" " ++
            "path=\"/work/.agents/skills/zig-style/SKILL.md\" />\n" ++
            "  <required_skill pattern=\"src/&lt;b&gt;/*.ts\" skill=\"ts-style\" " ++
            "path=\"/work/skills/ts/SKILL.md\" />\n" ++
            "</required_skills>",
    ) != null);

    // A session with no rule at all carries no section.
    const plain = try compose(gpa, &.{
        .core = "core",
        .current_time = .zero,
        .working_directory = "/work",
        .user_instructions = &.{},
        .project_instructions = &empty_instructions,
        .skills = try ai.skills.Catalog.init(&skill_items),
    });
    defer gpa.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "## Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "## Required skills") == null);
}

test "generated paths cannot add prompt lines or controls" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    try writePath(gpa, &output.writer, "/work\n```\x1b\xe2\x80\xae&\"'");

    try std.testing.expectEqualStrings(
        "/work\\x0a```\\x1b\\xe2\\x80\\xae&amp;&quot;&apos;",
        output.written(),
    );
}

test "empty project and skill sections are omitted independently" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var empty_instructions = ai.instructions.Result.init(gpa, .project);
    defer empty_instructions.deinit();
    const hidden_items = [_]ai.skills.Skill{.{
        .name = "hidden",
        .description = "manual only",
        .description_truncated = false,
        .path = "/hidden/SKILL.md",
        .model_invocation_disabled = true,
        .scope = .user,
    }};
    const empty_catalog = try ai.skills.Catalog.init(&hidden_items);
    const empty_prompt = try compose(gpa, &.{
        .core = "core",
        .current_time = .zero,
        .working_directory = "/work&space",
        .user_instructions = &.{},
        .project_instructions = &empty_instructions,
        .skills = empty_catalog,
    });
    defer gpa.free(empty_prompt);
    try std.testing.expectEqualStrings(
        "core\n\n## Environment\n\n<environment>\n" ++
            "  <current_date>1970-01-01</current_date>\n" ++
            "  <working_directory>/work&amp;space</working_directory>\n" ++
            "  <repository_root />\n</environment>",
        empty_prompt,
    );

    const visible_items = [_]ai.skills.Skill{.{
        .name = "visible",
        .description = "shown",
        .description_truncated = false,
        .path = "/visible/SKILL.md",
        .model_invocation_disabled = false,
        .scope = .user,
    }};
    const skill_prompt = try compose(gpa, &.{
        .core = "core",
        .current_time = .zero,
        .working_directory = "/work",
        .user_instructions = &.{},
        .project_instructions = &empty_instructions,
        .skills = try ai.skills.Catalog.init(&visible_items),
    });
    defer gpa.free(skill_prompt);
    try std.testing.expect(std.mem.indexOf(u8, skill_prompt, "## Project instructions") == null);
    try std.testing.expect(std.mem.indexOf(u8, skill_prompt, "## Skills") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var git = try tmp.dir.createDirPathOpen(io, "repo/.git", .{});
    git.close(io);
    try writeTestFile(io, tmp.dir, &.{ .path = "repo/AGENTS.md", .data = "project" });
    const working_directory = try tmpPath(gpa, io, &tmp, "repo");
    defer gpa.free(working_directory);
    var project_instructions = try ai.instructions.discover(gpa, io, working_directory);
    defer project_instructions.deinit();
    const project_prompt = try compose(gpa, &.{
        .core = "core",
        .current_time = .zero,
        .working_directory = working_directory,
        .user_instructions = &.{},
        .project_instructions = &project_instructions,
        .skills = empty_catalog,
    });
    defer gpa.free(project_prompt);
    try std.testing.expect(std.mem.indexOf(u8, project_prompt, "## Project instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_prompt, "## Skills") == null);
}
