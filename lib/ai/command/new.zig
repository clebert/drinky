const std = @import("std");

const Context = @import("Context.zig");

pub const name = "new";
pub const summary = "Clear the conversation";

pub fn run(context: *Context) !Context.Outcome {
    _ = context;
    return .new_conversation;
}

test "run requests a new conversation" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context)) == .new_conversation);
}
