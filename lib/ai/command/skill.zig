const std = @import("std");

const skills = @import("../skills.zig");
const Context = @import("Context.zig");

pub const name = "skill";
pub const summary = "Pick a skill";

const whitespace = " \t\r\n";

pub fn run(context: *Context) !Context.Outcome {
    const gpa = context.gpa;
    const items = try sorted(gpa, context.skill_registry);
    defer gpa.free(items);
    if (items.len == 0)
        return Context.Outcome.reportNotice(gpa, .warning, "Drinky found no skills.", .{});
    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    for (items) |target| try options.addExtraPrint(
        false,
        "/{s}:{s}",
        .{ name, target.name },
        "{s}",
        .{firstSentence(target.description)},
    );
    return .{ .pick = .{
        .select = select,
        .title = "Skill",
        .cancellation_message = "You canceled the skill selection.",
        .options = try options.toOwnedSlice(),
        .current = null,
    } };
}

pub fn select(context: *Context, selection: Context.Outcome.Pick.Selection) !Context.Outcome {
    const gpa = context.gpa;
    const index = selection.row;
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

pub fn load(context: *Context, target: *const skills.Skill, arguments: []const u8) !Context.Outcome {
    const gpa = context.gpa;
    const content = target.invoke(gpa, context.io, arguments) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return .{ .refusal = try Context.Outcome.Message.print(
            gpa,
            .failure,
            "Drinky could not load the skill {s} because of error {s}.",
            .{ target.name, @errorName(err) },
        ) };
    };
    errdefer gpa.free(content);
    const name_copy = try gpa.dupe(u8, target.name);
    errdefer gpa.free(name_copy);
    const arguments_copy = try gpa.dupe(u8, arguments);
    errdefer gpa.free(arguments_copy);
    const source_copy = try gpa.dupe(u8, target.path);
    return .{ .prompt = .{
        .name = name_copy,
        .arguments = arguments_copy,
        .content = content,
        .source = source_copy,
    } };
}

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
                for (pick.options) |*option| option.deinit(gpa);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("Skill", pick.title);
            try std.testing.expectEqual(@as(usize, 2), pick.options.len);
            try std.testing.expectEqualStrings("/skill:alpha", pick.options[0].name);
            try std.testing.expectEqualStrings("The first skill.", pick.options[0].extra.?);
            try std.testing.expectEqualStrings("/skill:omega", pick.options[1].name);
            try std.testing.expectEqualStrings("The last skill.", pick.options[1].extra.?);
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

    switch (try select(&context, .ofRow(1))) {
        .editor_text => |text| {
            defer gpa.free(text);
            try std.testing.expectEqualStrings("/skill:omega ", text);
        },
        else => return error.ExpectedEditorText,
    }
    try Context.Outcome.expectNoticeContaining(
        try select(&context, .ofRow(2)),
        .failure,
        "valid skill",
    );
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
    try Context.Outcome.expectNoticeContaining(
        try select(&context, .ofRow(0)),
        .failure,
        "valid skill",
    );
}

test "a summary holds the first sentence of the description" {
    try std.testing.expectEqualStrings("One sentence.", firstSentence("One sentence."));
    try std.testing.expectEqualStrings("First.", firstSentence("First. Second."));
    try std.testing.expectEqualStrings("no end at all", firstSentence("no end at all"));
    try std.testing.expectEqualStrings(
        "Use e.g. this form.",
        firstSentence("Use e.g. this form. And not that one."),
    );
    try std.testing.expectEqualStrings(
        "First. second one.",
        firstSentence("First. second one."),
    );
}

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
