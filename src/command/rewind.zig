const std = @import("std");

const Message = @import("../Message.zig");
const ui = @import("../ui/root.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "rewind";
pub const summary = "Return to an earlier prompt";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (context.turns.all()) |turn| {
        const line = try context.gpa.dupe(u8, turn.line orelse continue);
        defer context.gpa.free(line);
        try options.print("{s}", .{ui.paint.singleLine(line)});
    }
    if (options.rows.items.len == 0) return .{ .refusal = try Message.print(
        context.gpa,
        .warning,
        "No prompts are in the conversation.",
        .{},
    ) };
    const rows = try options.toOwnedSlice();
    return .{ .pick = .{
        .select = select,
        .title = "Prompt",
        .cancellation_message = "You canceled the prompt selection.",
        .options = rows,
        .current = null,
        .preselected = rows.len - 1,
    } };
}

fn select(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    var row: usize = 0;
    for (context.turns.all(), 0..) |turn, index| {
        if (turn.line == null) continue;
        if (row == selection.row) return .{ .rewind = index };
        row += 1;
    }
    unreachable;
}

test "an empty conversation refuses, and each typed prompt gets one row that rewinds to it" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();

    try testing.expectRefusal(try run(&context), .warning, "No prompts are in the conversation.");

    try rig.turns.begin(0, "first");
    try rig.turns.begin(2, null);
    try rig.turns.begin(4, "\n  look at this:  \n\n \t\n  the  file\r\n\n");
    try rig.turns.begin(6, "/skill:demo apply it");
    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(gpa);
    try std.testing.expectEqualStrings("Prompt", pick.title);
    try std.testing.expectEqualStrings(
        "You canceled the prompt selection.",
        pick.cancellation_message,
    );
    try std.testing.expectEqual(@as(?usize, null), pick.current);
    try std.testing.expectEqual(@as(?usize, 2), pick.preselected);
    try std.testing.expectEqual(@as(usize, 3), pick.options.len);
    try std.testing.expectEqualStrings("first", pick.options[0].name);
    try std.testing.expectEqualStrings("look at this: the file", pick.options[1].name);
    try std.testing.expectEqualStrings("/skill:demo apply it", pick.options[2].name);
    for ([_]usize{ 0, 2, 3 }, 0..) |turn, row| {
        try std.testing.expectEqual(turn, (try testing.selectRow(&pick, &context, row)).rewind);
    }
}
