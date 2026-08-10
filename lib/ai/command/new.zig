//! `/new`: ask the app to start an empty conversation while preserving the
//! active account, model, and configuration. The command takes no argument.

const std = @import("std");

const Context = @import("Context.zig");

pub const name = "new";

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
