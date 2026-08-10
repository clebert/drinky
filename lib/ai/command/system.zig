//! `/system`: ask the app to show its complete provider-neutral system prompt.
//! The command takes no argument.

const std = @import("std");

const Context = @import("Context.zig");

pub const name = "system";

pub fn run(context: *Context) !Context.Outcome {
    _ = context;
    return .show_system_prompt;
}

test "run requests the composed system prompt" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context)) == .show_system_prompt);
}
