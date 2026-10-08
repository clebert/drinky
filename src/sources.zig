const std = @import("std");

const tools = @import("tools");

const Config = @import("Config.zig");
const discovery = @import("discovery/root.zig");
const format = @import("format.zig");
const testing = @import("testing.zig");

const Options = struct {
    user_instructions: []const discovery.instructions.File,
    project_instructions: []const discovery.instructions.File,
    skills: *const discovery.skills.Registry,
    required_skills: []const tools.SkillGuard.Rule,
    required_missing: []const Config.RequiredSkill,
    roots: format.Roots,
};

const Section = struct {
    title: []const u8,
    empty: []const u8,
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
    try writer.writeAll(
        "Drinky reads these sources at startup alone. A new file waits for the next start.\n",
    );
    try writeFiles(gpa, writer, &options.roots, &.{
        .title = "User instructions",
        .empty = "Drinky loaded no user instruction file.",
        .files = options.user_instructions,
    });
    try writeFiles(gpa, writer, &options.roots, &.{
        .title = "Project instructions",
        .empty = "Drinky found no project instruction file.",
        .files = options.project_instructions,
    });
    try writeSkills(gpa, writer, options);
    try writeRequiredSkills(gpa, writer, options);
}

fn writeFiles(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    roots: *const format.Roots,
    section: *const Section,
) !void {
    try writer.print("\n## {s}\n\n", .{section.title});
    if (section.files.len == 0) return writer.print("{s}\n", .{section.empty});
    for (section.files) |file| {
        try writer.writeAll("- ");
        try writePath(gpa, writer, roots, file.path);
        try writer.writeByte('\n');
    }
}

fn writeSkills(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: *const Options) !void {
    try writer.writeAll("\n## Skills\n\n");
    const items = options.skills.items();
    if (items.len == 0) try writer.writeAll("Drinky found no skill.\n");
    for (items) |skill| {
        try writer.print("- `{s}` · Scope: {s}", .{ skill.name, @tagName(skill.scope) });
        if (skill.model_invocation_disabled) try writer.writeAll(" · Hidden from the model");
        if (skill.run_hidden) try writer.writeAll(" · Hidden in a run");
        try writer.writeAll(" · File: ");
        try writePath(gpa, writer, &options.roots, skill.path);
        if (skill.replaced_path) |replaced_path| {
            try writer.writeAll(" · Replaces: ");
            try writePath(gpa, writer, &options.roots, replaced_path);
        }
        try writer.writeByte('\n');
    }
}

fn writeRequiredSkills(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    options: *const Options,
) !void {
    try writer.writeAll("\n## Required skills\n\n");
    if (options.required_skills.len == 0 and options.required_missing.len == 0)
        return writer.writeAll("The config names no required skill.\n");
    for (options.required_skills) |rule| {
        try writer.print("- `{s}` · Skill: `{s}` · File: ", .{ rule.glob, rule.skill });
        try writePath(gpa, writer, &options.roots, rule.source);
        try writer.writeByte('\n');
    }
    for (options.required_missing) |required| try writer.print(
        "- `{s}` · Skill: `{s}` · No discovered skill carries this name.\n",
        .{ required.glob, required.skill },
    );
}

fn writePath(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    roots: *const format.Roots,
    path: []const u8,
) !void {
    const shown = try format.path(gpa, path, roots);
    defer gpa.free(shown);
    try writer.print("`{s}`", .{shown});
}

test "the page names every file behind the startup counts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.directory("work/.git");
    try tree.write("work/AGENTS.md", "Project.\n");
    try tree.write("home/first.md", "First.\n");
    try tree.skill("work/.agents/skills/demo", &.{ .name = "demo", .description = "a test skill" });
    try tree.write(
        "work/.agents/skills/hidden/SKILL.md",
        "---\nname: hidden\ndescription: a manual skill\n" ++
            "disable-model-invocation: true\n---\nbody\n",
    );
    try tree.write(
        "work/.agents/skills/review/SKILL.md",
        "---\nname: review\ndescription: a session skill\n" ++
            "metadata:\n  drinky-run: hidden\n---\nbody\n",
    );
    try tree.skill("home/.agents/skills/demo", &.{
        .name = "demo",
        .description = "the user copy",
    });
    try tree.skill(
        "home/.agents/skills/other",
        &.{ .name = "other", .description = "a user skill" },
    );
    const home = try tree.path("home");
    const work = try tree.path("work");
    const user_skills = try tree.path("home/.agents/skills");

    var user_instructions = try discovery.instructions.load(gpa, io, &.{
        .directory = home,
        .paths = &.{"first.md"},
    });
    defer user_instructions.deinit();
    var project_instructions = try discovery.instructions.discover(gpa, io, work);
    defer project_instructions.deinit();
    var registry = try discovery.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = work,
        .project_root = project_instructions.projectRoot(),
    });
    defer registry.deinit();
    const demo_path = try tree.path("work/.agents/skills/demo/SKILL.md");

    const page = try compose(gpa, &.{
        .user_instructions = user_instructions.files(),
        .project_instructions = project_instructions.files(),
        .skills = &registry,
        .required_skills = &.{
            .{ .glob = "**/*.zig", .skill = "demo", .source = demo_path },
        },
        .required_missing = &.{
            .{ .glob = "**/*.ts", .skill = "nonesuch" },
        },
        .roots = .{ .working_directory = work, .home_directory = home },
    });
    defer gpa.free(page);

    const user = std.mem.find(u8, page, "## User instructions").?;
    const project = std.mem.find(u8, page, "## Project instructions").?;
    const skills_index = std.mem.find(u8, page, "## Skills").?;
    const required = std.mem.find(u8, page, "## Required skills").?;
    try std.testing.expect(user < project);
    try std.testing.expect(project < skills_index);
    try std.testing.expect(skills_index < required);

    try std.testing.expect(std.mem.find(u8, page, "\n- `~/first.md`\n") != null);
    try std.testing.expect(std.mem.find(u8, page, "\n- `AGENTS.md`\n") != null);

    try std.testing.expect(std.mem.find(
        u8,
        page,
        "- `demo` · Scope: project · File: `.agents/skills/demo/SKILL.md` · Replaces: " ++
            "`~/.agents/skills/demo/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        page,
        "- `hidden` · Scope: project · Hidden from the model · File: " ++
            "`.agents/skills/hidden/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        page,
        "- `review` · Scope: project · Hidden in a run · File: " ++
            "`.agents/skills/review/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        page,
        "- `other` · Scope: user · File: `~/.agents/skills/other/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.find(u8, page, "the user copy") == null);

    try std.testing.expect(std.mem.find(
        u8,
        page,
        "- `**/*.zig` · Skill: `demo` · File: `.agents/skills/demo/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        page,
        "- `**/*.ts` · Skill: `nonesuch` · No discovered skill carries this name.\n",
    ) != null);
}

test "an empty source states its empty state" {
    const gpa = std.testing.allocator;
    var registry = discovery.skills.Registry.init(gpa);
    defer registry.deinit();
    const page = try compose(gpa, &.{
        .user_instructions = &.{},
        .project_instructions = &.{},
        .skills = &registry,
        .required_skills = &.{},
        .required_missing = &.{},
        .roots = .{},
    });
    defer gpa.free(page);
    try std.testing.expectEqualStrings(
        "Drinky reads these sources at startup alone. A new file waits for the next start.\n" ++
            "\n## User instructions\n\nDrinky loaded no user instruction file.\n" ++
            "\n## Project instructions\n\nDrinky found no project instruction file.\n" ++
            "\n## Skills\n\nDrinky found no skill.\n" ++
            "\n## Required skills\n\nThe config names no required skill.\n",
        page,
    );
}
