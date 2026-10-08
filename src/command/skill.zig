const std = @import("std");

const discovery = @import("../discovery/root.zig");
const Message = @import("../Message.zig");
const ui = @import("../ui/root.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "skill";
pub const summary = "Pick a skill";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    const gpa = context.gpa;
    const items = try sorted(gpa, context.skill_registry);
    defer gpa.free(items);
    if (items.len == 0)
        return .{ .refusal = try Message.print(gpa, .warning, "Drinky found no skill.", .{}) };
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

fn select(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    const gpa = context.gpa;
    const items = try sorted(gpa, context.skill_registry);
    defer gpa.free(items);
    return .{ .editor_text = try gpa.print(
        "/{s}:{s} ",
        .{ name, items[selection.row].name },
    ) };
}

pub fn load(
    context: *Context,
    target: *const discovery.skills.Skill,
    arguments: []const u8,
) !Context.Outcome {
    const gpa = context.gpa;
    const content = target.invoke(gpa, context.io, arguments) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return .{ .refusal = try Message.print(
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
    registry: *const discovery.skills.Registry,
) ![]const *const discovery.skills.Skill {
    const items = registry.items();
    const list = try gpa.alloc(*const discovery.skills.Skill, items.len);
    for (items, 0..) |*target, index| list[index] = target;
    std.mem.sort(*const discovery.skills.Skill, list, {}, nameLessThan);
    return list;
}

fn nameLessThan(_: void, a: *const discovery.skills.Skill, b: *const discovery.skills.Skill) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn firstSentence(description: []const u8) []const u8 {
    var index: usize = 0;
    while (std.mem.findScalarPos(u8, description, index, '.')) |stop| {
        const end = stop + 1;
        index = end;
        if (end == description.len) break;
        if (std.mem.findScalar(u8, ui.paint.blank_bytes, description[end]) == null) continue;
        const next = std.mem.findNone(u8, description[end..], ui.paint.blank_bytes) orelse break;
        const start = description[end + next];
        if (start < 'a' or start > 'z') return description[0..end];
    }
    return description;
}

test "the list shows one row per skill, ordered by name, and a selection writes the line" {
    const gpa = std.testing.allocator;
    var discovered: testing.Discovered = try .init();
    defer discovered.deinit();
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .skill_registry = &discovered.registry });
    defer rig.deinit();
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(gpa);
    try std.testing.expectEqualStrings("Skill", pick.title);
    try std.testing.expectEqual(@as(usize, 2), pick.options.len);
    try std.testing.expectEqualStrings("/skill:alpha", pick.options[0].name);
    try std.testing.expectEqualStrings("The first skill.", pick.options[0].extra.?);
    try std.testing.expectEqualStrings("/skill:omega", pick.options[1].name);
    try std.testing.expectEqualStrings("The last skill.", pick.options[1].extra.?);

    switch (try testing.selectRow(&pick, &context, 1)) {
        .editor_text => |text| {
            defer gpa.free(text);
            try std.testing.expectEqualStrings("/skill:omega ", text);
        },
        else => return error.ExpectedEditorText,
    }
}

test "an empty registry reports that no skill exists" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .skill_registry = &testing.no_skills });
    defer rig.deinit();
    var context = rig.context();
    try testing.expectRefusal(
        try run(&context),
        .warning,
        "Drinky found no skill.",
    );
}

test "a skill file that left after the discovery refuses the load and names the error" {
    var discovered: testing.Discovered = try .init();
    defer discovered.deinit();
    try discovered.tree.tmp.dir.deleteFile(std.testing.io, "user/02-alpha/SKILL.md");
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .skill_registry = &discovered.registry });
    defer rig.deinit();
    var context = rig.context();

    try testing.expectRefusal(
        try load(&context, discovered.registry.get("alpha").?, "apply it"),
        .failure,
        "Drinky could not load the skill alpha because of error FileNotFound.",
    );
}

test "a summary holds the first sentence of the description" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { name: []const u8, description: []const u8, summary: []const u8 }{
        .{ .name = "alpha", .description = "One sentence.", .summary = "One sentence." },
        .{ .name = "bravo", .description = "First. Second.", .summary = "First." },
        .{ .name = "charlie", .description = "no end at all", .summary = "no end at all" },
        .{
            .name = "delta",
            .description = "Use e.g. this form. And not that one.",
            .summary = "Use e.g. this form.",
        },
        .{ .name = "echo", .description = "First. second one.", .summary = "First. second one." },
    };
    var skills: [cases.len]testing.Discovered.Skill = undefined;
    for (&skills, cases) |*skill, case| skill.* = .{
        .name = case.name,
        .description = case.description,
    };
    var discovered: testing.Discovered = try .initWith(&skills);
    defer discovered.deinit();
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .skill_registry = &discovered.registry });
    defer rig.deinit();
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(gpa);
    try std.testing.expectEqual(cases.len, pick.options.len);
    for (cases, pick.options) |case, option| {
        try std.testing.expectEqualStrings(case.summary, option.extra.?);
    }
}
