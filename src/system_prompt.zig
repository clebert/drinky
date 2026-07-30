//! Pure composition of pith's provider-neutral system prompt.

const std = @import("std");

const ai = @import("ai");

pub const default_core =
    "# Pith\n\n" ++
    "You are a coding assistant operating inside pith, a terminal coding-agent harness.\n\n" ++
    "Follow the user's request and the applicable project instructions. Inspect relevant files before\n" ++
    "editing them, use the available tools according to their schemas, and be concise. After changing\n" ++
    "files, report what changed, the checks you ran, and any unresolved issues.";

const project_intro =
    "The following repository-controlled defaults apply to the working directory and are listed\n" ++
    "broad-to-specific. Pith's core and configured system additions take precedence. The user's " ++
    "explicit\n" ++
    "task wins over conflicting project guidance; when project files conflict, the more specific " ++
    "file\n" ++
    "wins within its subtree. Skill guidance is supplemental.\n\n";

const skills_intro =
    "The following skills provide specialized instructions. Skill guidance is supplemental: it does " ++
    "not\n" ++
    "override the pith core, configured system additions, the user's task, or applicable project\n" ++
    "instructions. When a task matches a skill's description, read its SKILL.md at the listed " ++
    "location\n" ++
    "before proceeding.\n\n";

pub const Options = struct {
    core: []const u8,
    working_directory: []const u8,
    instructions: *const ai.instructions.Result,
    skills: ai.skills.Catalog,
};

pub fn compose(gpa: std.mem.Allocator, options: *const Options) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    try output.writer.writeAll(options.core);
    try writeEnvironment(gpa, &output.writer, options.working_directory, options.instructions);
    if (options.instructions.entries().len > 0) {
        try writeProject(gpa, &output.writer, options.instructions.entries());
    }
    if (options.skills.count() > 0) try writeSkills(gpa, &output.writer, &options.skills);
    return output.toOwnedSlice();
}

fn writeEnvironment(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    working_directory: []const u8,
    instructions: *const ai.instructions.Result,
) !void {
    try writer.writeAll("\n\n## Environment\n\n<environment>\n  <working_directory>");
    try writePath(gpa, writer, working_directory);
    try writer.writeAll("</working_directory>\n");
    if (instructions.projectRoot()) |project_root| {
        try writer.writeAll("  <repository_root>");
        try writePath(gpa, writer, project_root);
        try writer.writeAll("</repository_root>\n");
    } else {
        try writer.writeAll("  <repository_root />\n");
    }
    try writer.writeAll("</environment>");
}

fn writeProject(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    entries: []const ai.instructions.Entry,
) !void {
    try writer.writeAll("\n\n## Project instructions\n\n");
    try writer.writeAll(project_intro);
    try writer.writeAll("<project_context>\n");
    for (entries) |entry| {
        try writer.writeAll("  <project_instructions path=\"");
        try writePath(gpa, writer, entry.path);
        try writer.writeAll("\">\n");
        try writer.writeAll(entry.content);
        if (!std.mem.endsWith(u8, entry.content, "\n")) try writer.writeByte('\n');
        try writer.writeAll("  </project_instructions>\n");
    }
    try writer.writeAll("</project_context>");
}

fn writeSkills(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    catalog: *const ai.skills.Catalog,
) !void {
    try writer.writeAll("\n\n## Skills\n\n");
    try writer.writeAll(skills_intro);
    try writer.writeAll("<available_skills>\n");
    var iterator = catalog.iterator();
    for (0..catalog.count()) |_| {
        const skill = iterator.next() orelse return error.InvalidSkillCatalog;
        try writer.writeAll("  <skill>\n    <name>");
        try writeEscaped(writer, skill.name);
        try writer.writeAll("</name>\n    <description>");
        try writeEscaped(writer, skill.description);
        if (skill.description_truncated) try writer.writeAll("…");
        try writer.writeAll("</description>\n    <location>");
        try writePath(gpa, writer, skill.path);
        try writer.writeAll("</location>\n  </skill>\n");
    }
    try writer.writeAll("</available_skills>");
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

test "the compiled core is stable" {
    try std.testing.expectEqualStrings(
        "# Pith\n\n" ++
            "You are a coding assistant operating inside pith, a terminal coding-agent harness.\n\n" ++
            "Follow the user's request and the applicable project instructions. Inspect relevant " ++
            "files before\n" ++
            "editing them, use the available tools according to their schemas, and be concise. " ++
            "After changing\n" ++
            "files, report what changed, the checks you ran, and any unresolved issues.",
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
        .working_directory = working_directory,
        .instructions = &instructions,
        .skills = catalog,
    });
    defer gpa.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, default_core));
    const environment_index = std.mem.indexOf(u8, prompt, "## Environment").?;
    const project_index = std.mem.indexOf(u8, prompt, "## Project instructions").?;
    const skills_index = std.mem.indexOf(u8, prompt, "## Skills").?;
    try std.testing.expect(environment_index < project_index);
    try std.testing.expect(project_index < skills_index);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "repo&amp;root/package") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, broad) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "left &amp;&amp;") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt,
        "Use &lt;this&gt; &amp; &quot;that&quot;…",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "/skills/a&apos;b/SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<name>hidden</name>") == null);
    const broad_index = std.mem.indexOf(u8, prompt, "# Broad").?;
    const specific_index = std.mem.indexOf(u8, prompt, "\">\nspecific\n").?;
    try std.testing.expect(broad_index < specific_index);
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
    var empty_instructions = ai.instructions.Result.init(gpa);
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
        .working_directory = "/work&space",
        .instructions = &empty_instructions,
        .skills = empty_catalog,
    });
    defer gpa.free(empty_prompt);
    try std.testing.expectEqualStrings(
        "core\n\n## Environment\n\n<environment>\n" ++
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
        .working_directory = "/work",
        .instructions = &empty_instructions,
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
        .working_directory = working_directory,
        .instructions = &project_instructions,
        .skills = empty_catalog,
    });
    defer gpa.free(project_prompt);
    try std.testing.expect(std.mem.indexOf(u8, project_prompt, "## Project instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_prompt, "## Skills") == null);
}
