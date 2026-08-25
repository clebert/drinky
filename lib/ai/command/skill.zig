//! `/skill` and `/skill:`: a picker over every discovered skill. A selection
//! writes the `/skill:name ` line into the editor, so the user can add the task
//! that the skill works on. The command takes no argument.
//!
//! The list holds every skill of the registry, not the catalog the model reads.
//! A skill that disables model invocation still loads by hand, so the user must
//! see it too.

const std = @import("std");

const skills = @import("../skills.zig");
const Context = @import("Context.zig");

pub const name = "skill";
pub const summary = "load one of the discovered skills";

const whitespace = " \t\r\n";

pub fn run(context: *Context) !Context.Outcome {
    const gpa = context.gpa;
    const items = try sorted(gpa, context.skill_registry);
    defer gpa.free(items);
    if (items.len == 0)
        return Context.Outcome.reportNotice(gpa, .warning, "Drinky found no skills.", .{});
    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    // The row shows the line it writes, so the user learns the typed form.
    for (items) |target| try options.print(
        "/{s}:{s} — {s}",
        .{ name, target.name, firstSentence(target.description) },
    );
    return .{ .pick = .{
        .select = select,
        .title = "Skill",
        .cancellation_message = "You canceled the skill selection.",
        .options = try options.toOwnedSlice(),
        .current = null,
    } };
}

/// Write the picked skill line into the editor. The trailing blank marks the
/// place where the task goes. The line runs on the next Enter, so a restriction
/// that blocks a skill turn still reports itself there.
pub fn select(context: *Context, index: usize) !Context.Outcome {
    const gpa = context.gpa;
    const items = try sorted(gpa, context.skill_registry);
    defer gpa.free(items);
    if (index >= items.len)
        return Context.Outcome.reportNotice(gpa, .failure, "Select a valid skill.", .{});
    return .{ .editor_text = try std.fmt.allocPrint(
        gpa,
        "/{s}:{s} ",
        .{ name, items[index].name },
    ) };
}

/// Every discovered skill, ordered by the name that the rows show. `run` and
/// `select` index the same order, so both build it here. The caller owns the
/// slice, and the registry owns the skills it points to.
fn sorted(
    gpa: std.mem.Allocator,
    maybe_registry: ?*const skills.Registry,
) ![]const *const skills.Skill {
    const registry = maybe_registry orelse return gpa.alloc(*const skills.Skill, 0);
    const items = registry.items();
    const list = try gpa.alloc(*const skills.Skill, items.len);
    for (items, 0..) |*target, index| list[index] = target;
    std.mem.sort(*const skills.Skill, list, {}, nameLessThan);
    return list;
}

fn nameLessThan(_: void, a: *const skills.Skill, b: *const skills.Skill) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The first sentence of `description`, or the whole text when it holds none. A
/// description can run several sentences, and one row states the summary alone.
/// The picker cuts what is still too wide for the window.
///
/// A sentence ends at a dot, a blank, and a word that does not start with a
/// lowercase letter. The lowercase test keeps a dotted abbreviation such as
/// `e.g.` inside its sentence. A second sentence that starts lowercase reads on,
/// and the width of the window then cuts the row.
fn firstSentence(description: []const u8) []const u8 {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, description, index, '.')) |stop| {
        const end = stop + 1;
        index = end;
        if (end == description.len) break;
        if (std.mem.indexOfScalar(u8, whitespace, description[end]) == null) continue;
        const next = std.mem.indexOfNone(u8, description[end..], whitespace) orelse break;
        const start = description[end + next];
        if (start < 'a' or start > 'z') return description[0..end];
    }
    return description;
}

test "the list shows one row per skill, ordered by name" {
    const gpa = std.testing.allocator;
    var discovered: Discovered = try .init(gpa);
    defer discovered.deinit();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .skill_registry = &discovered.registry,
    };

    const outcome = try run(&context);
    switch (outcome) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("Skill", pick.title);
            try std.testing.expectEqual(@as(usize, 2), pick.options.len);
            // The row holds the line it writes, and the summary stops at the
            // first sentence of the description.
            try std.testing.expectEqualStrings(
                "/skill:alpha — The first skill.",
                pick.options[0],
            );
            try std.testing.expectEqualStrings(
                "/skill:omega — The last skill.",
                pick.options[1],
            );
        },
        else => return error.ExpectedPick,
    }
}

test "a selection writes the skill line with a trailing blank" {
    const gpa = std.testing.allocator;
    var discovered: Discovered = try .init(gpa);
    defer discovered.deinit();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .skill_registry = &discovered.registry,
    };

    switch (try select(&context, 1)) {
        .editor_text => |text| {
            defer gpa.free(text);
            try std.testing.expectEqualStrings("/skill:omega ", text);
        },
        else => return error.ExpectedEditorText,
    }
    try Context.Outcome.expectNoticeContaining(try select(&context, 2), .failure, "valid skill");
}

test "an empty registry reports that no skill exists" {
    const gpa = std.testing.allocator;
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try Context.Outcome.expectNoticeContaining(try run(&context), .warning, "found no skills");
    try Context.Outcome.expectNoticeContaining(try select(&context, 0), .failure, "valid skill");
}

test "a summary holds the first sentence of the description" {
    try std.testing.expectEqualStrings("One sentence.", firstSentence("One sentence."));
    try std.testing.expectEqualStrings("First.", firstSentence("First. Second."));
    try std.testing.expectEqualStrings("no end at all", firstSentence("no end at all"));
    // A dotted abbreviation stays inside its sentence, because the word after it
    // starts lowercase.
    try std.testing.expectEqualStrings(
        "Use e.g. this form.",
        firstSentence("Use e.g. this form. And not that one."),
    );
    // A second sentence that starts lowercase reads on. The picker cuts the row.
    try std.testing.expectEqualStrings(
        "First. second one.",
        firstSentence("First. second one."),
    );
}

/// Test scaffolding: two discovered skills whose directory order is the reverse
/// of their name order, so the sort of the rows is visible. The temporary
/// directory holds the files that the registry points to.
const Discovered = struct {
    tmp: std.testing.TmpDir,
    registry: skills.Registry,

    fn init(gpa: std.mem.Allocator) !Discovered {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try write(io, &tmp, "user/01-omega", "omega", "The last skill. It sorts second.");
        try write(io, &tmp, "user/02-alpha", "alpha", "The first skill. It sorts first.");
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
        return .{
            .tmp = tmp,
            .registry = try skills.discover(gpa, io, &.{
                .user_root = user_root,
                .project_start = project_start,
                .project_root = null,
            }),
        };
    }

    fn deinit(self: *Discovered) void {
        self.registry.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn write(
        io: std.Io,
        tmp: *std.testing.TmpDir,
        directory: []const u8,
        skill_name: []const u8,
        description: []const u8,
    ) !void {
        var made = try tmp.dir.createDirPathOpen(io, directory, .{});
        made.close(io);
        var buffer: [256]u8 = undefined;
        const source = try std.fmt.bufPrint(
            &buffer,
            "---\nname: {s}\ndescription: {s}\n---\nFollow this skill.\n",
            .{ skill_name, description },
        );
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/SKILL.md", .{directory});
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = source });
    }
};
