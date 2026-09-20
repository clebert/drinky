const std = @import("std");

const ai = @import("ai");

const Config = @import("Config.zig");

pub const Options = struct {
    user_instructions: []const ai.instructions.File,
    project_instructions: []const ai.instructions.File,
    skills: *const ai.skills.Registry,
    required_skills: []const ai.tool.SkillGuard.Rule,
    required_missing: []const Config.RequiredSkill,
    roots: ai.format.Roots,
};

const Section = struct {
    title: []const u8,
    empty: []const u8,
    files: []const ai.instructions.File,
};

pub fn compose(gpa: std.mem.Allocator, options: *const Options) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    const writer = &output.writer;
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
    return output.toOwnedSlice();
}

fn writeFiles(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    roots: *const ai.format.Roots,
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
    const skills = options.skills.items();
    if (skills.len == 0) try writer.writeAll("Drinky found no skill.\n");
    for (skills) |skill| {
        try writer.print("- `{s}` · Scope: {s}", .{ skill.name, @tagName(skill.scope) });
        if (skill.model_invocation_disabled) try writer.writeAll(" · Hidden from the model");
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
    roots: *const ai.format.Roots,
    path: []const u8,
) !void {
    const shown = try ai.format.path(gpa, path, roots);
    defer gpa.free(shown);
    try writer.print("`{s}`", .{shown});
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

test "the page names every file behind the startup counts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var git = try tmp.dir.createDirPathOpen(io, "work/.git", .{});
    git.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "work/AGENTS.md", .data = "Project.\n" });
    var home_dir = try tmp.dir.createDirPathOpen(io, "home", .{});
    home_dir.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "home/first.md", .data = "First.\n" });
    var demo = try tmp.dir.createDirPathOpen(io, "work/.agents/skills/demo", .{});
    demo.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "work/.agents/skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: a test skill\n---\nbody\n",
    });
    var hidden = try tmp.dir.createDirPathOpen(io, "work/.agents/skills/hidden", .{});
    hidden.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "work/.agents/skills/hidden/SKILL.md",
        .data = "---\nname: hidden\ndescription: a manual skill\n" ++
            "disable-model-invocation: true\n---\nbody\n",
    });
    var user_demo = try tmp.dir.createDirPathOpen(io, "home/.agents/skills/demo", .{});
    user_demo.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "home/.agents/skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: the user copy\n---\nbody\n",
    });
    var user_other = try tmp.dir.createDirPathOpen(io, "home/.agents/skills/other", .{});
    user_other.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "home/.agents/skills/other/SKILL.md",
        .data = "---\nname: other\ndescription: a user skill\n---\nbody\n",
    });
    const home = try tmpPath(gpa, io, &tmp, "home");
    defer gpa.free(home);
    const work = try tmpPath(gpa, io, &tmp, "work");
    defer gpa.free(work);
    const user_skills = try std.fs.path.join(gpa, &.{ home, ".agents", "skills" });
    defer gpa.free(user_skills);

    var user_instructions = try ai.instructions.load(gpa, io, &.{
        .directory = home,
        .paths = &.{"first.md"},
    });
    defer user_instructions.deinit();
    var project_instructions = try ai.instructions.discover(gpa, io, work);
    defer project_instructions.deinit();
    var skills = try ai.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = work,
        .project_root = project_instructions.projectRoot(),
    });
    defer skills.deinit();
    const demo_path = try std.fs.path.join(gpa, &.{ work, ".agents", "skills", "demo", "SKILL.md" });
    defer gpa.free(demo_path);

    const page = try compose(gpa, &.{
        .user_instructions = user_instructions.files(),
        .project_instructions = project_instructions.files(),
        .skills = &skills,
        .required_skills = &.{
            .{ .glob = "**/*.zig", .skill = "demo", .source = demo_path },
        },
        .required_missing = &.{
            .{ .glob = "**/*.ts", .skill = "nonesuch" },
        },
        .roots = .{ .working_directory = work, .home_directory = home },
    });
    defer gpa.free(page);

    const user = std.mem.indexOf(u8, page, "## User instructions").?;
    const project = std.mem.indexOf(u8, page, "## Project instructions").?;
    const skills_index = std.mem.indexOf(u8, page, "## Skills").?;
    const required = std.mem.indexOf(u8, page, "## Required skills").?;
    try std.testing.expect(user < project);
    try std.testing.expect(project < skills_index);
    try std.testing.expect(skills_index < required);

    try std.testing.expect(std.mem.indexOf(u8, page, "\n- `~/first.md`\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "\n- `AGENTS.md`\n") != null);

    try std.testing.expect(std.mem.indexOf(
        u8,
        page,
        "- `demo` · Scope: project · File: `.agents/skills/demo/SKILL.md` · Replaces: " ++
            "`~/.agents/skills/demo/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        page,
        "- `hidden` · Scope: project · Hidden from the model · File: " ++
            "`.agents/skills/hidden/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        page,
        "- `other` · Scope: user · File: `~/.agents/skills/other/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "the user copy") == null);

    try std.testing.expect(std.mem.indexOf(
        u8,
        page,
        "- `**/*.zig` · Skill: `demo` · File: `.agents/skills/demo/SKILL.md`\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        page,
        "- `**/*.ts` · Skill: `nonesuch` · No discovered skill carries this name.\n",
    ) != null);
}

test "an empty source states its empty state" {
    const gpa = std.testing.allocator;
    var skills = ai.skills.Registry.init(gpa);
    defer skills.deinit();
    const page = try compose(gpa, &.{
        .user_instructions = &.{},
        .project_instructions = &.{},
        .skills = &skills,
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
