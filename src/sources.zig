const std = @import("std");
const application = @import("application");
const format = @import("format.zig");

const Options = struct {
    documents: *const application.query.Documents,
    roots: format.Roots,
};

const Section = struct {
    title: []const u8,
    empty: []const u8,
    files: @FieldType(application.query.Documents, "user_instructions"),
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
    const documents = options.documents;
    try writer.writeAll(
        "Drinky reads these sources at startup alone. A new file waits for the next start.\n",
    );
    try writeFiles(gpa, writer, &options.roots, &.{
        .title = "User instructions",
        .empty = "Drinky loaded no user instruction file.",
        .files = documents.user_instructions,
    });
    try writeFiles(gpa, writer, &options.roots, &.{
        .title = "Project instructions",
        .empty = "Drinky found no project instruction file.",
        .files = documents.project_instructions,
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
    const items = options.documents.skills;
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
    const documents = options.documents;
    if (documents.required_skills.len == 0 and documents.required_missing.len == 0)
        return writer.writeAll("The config names no required skill.\n");
    for (documents.required_skills) |rule| {
        try writer.print("- `{s}` · Skill: `{s}` · File: ", .{ rule.glob, rule.skill });
        try writePath(gpa, writer, &options.roots, rule.source);
        try writer.writeByte('\n');
    }
    for (documents.required_missing) |required| try writer.print(
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

test "the page names every file, skill, and required skill with its flags" {
    const gpa = std.testing.allocator;
    const page = try compose(gpa, &.{
        .documents = &.{
            .system_prompt = "",
            .user_instructions = &.{.{ .path = "/home/first.md", .content = "", .identity = "" }},
            .project_instructions = &.{.{
                .path = "/work/AGENTS.md",
                .content = "",
                .identity = "",
            }},
            .skills = &.{
                .{
                    .name = "demo",
                    .description = "",
                    .description_truncated = false,
                    .path = "/work/.agents/skills/demo/SKILL.md",
                    .model_invocation_disabled = false,
                    .run_hidden = false,
                    .scope = .project,
                    .replaced_path = "/home/.agents/skills/demo/SKILL.md",
                },
                .{
                    .name = "hidden",
                    .description = "",
                    .description_truncated = false,
                    .path = "/work/.agents/skills/hidden/SKILL.md",
                    .model_invocation_disabled = true,
                    .run_hidden = true,
                    .scope = .user,
                },
            },
            .required_skills = &.{.{
                .glob = "**/*.zig",
                .skill = "demo",
                .source = "/work/.agents/skills/demo/SKILL.md",
            }},
            .required_missing = &.{.{ .glob = "**/*.ts", .skill = "nonesuch" }},
        },
        .roots = .{ .working_directory = "/work", .home_directory = "/home" },
    });
    defer gpa.free(page);
    try std.testing.expectEqualStrings(
        "Drinky reads these sources at startup alone. A new file waits for the next start.\n" ++
            "\n## User instructions\n\n- `~/first.md`\n" ++
            "\n## Project instructions\n\n- `AGENTS.md`\n" ++
            "\n## Skills\n\n" ++
            "- `demo` · Scope: project · File: `.agents/skills/demo/SKILL.md` · Replaces: " ++
            "`~/.agents/skills/demo/SKILL.md`\n" ++
            "- `hidden` · Scope: user · Hidden from the model · Hidden in a run · File: " ++
            "`.agents/skills/hidden/SKILL.md`\n" ++
            "\n## Required skills\n\n" ++
            "- `**/*.zig` · Skill: `demo` · File: `.agents/skills/demo/SKILL.md`\n" ++
            "- `**/*.ts` · Skill: `nonesuch` · No discovered skill carries this name.\n",
        page,
    );
}

test "an empty source states its empty state" {
    const gpa = std.testing.allocator;
    const page = try compose(gpa, &.{
        .documents = &.{
            .system_prompt = "",
            .user_instructions = &.{},
            .project_instructions = &.{},
            .skills = &.{},
            .required_skills = &.{},
            .required_missing = &.{},
        },
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
