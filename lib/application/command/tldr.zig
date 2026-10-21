const std = @import("std");

const Message = @import("../Message.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "tldr";
pub const summary = "Shorten the last answer with the current model";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    const answer = context.answer orelse return .{ .refusal = try Message.print(
        context.gpa,
        .warning,
        "No answer is in the conversation.",
        .{},
    ) };
    return .{ .shorten = answer };
}

test "a conversation without an answer refuses, and the last answer becomes the text to shorten" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();

    try testing.expectRefusal(try run(&context), .warning, "No answer is in the conversation.");
    context.answer = "The final text.";
    try std.testing.expectEqualStrings("The final text.", (try run(&context)).shorten);
}
