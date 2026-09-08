//! `/status`: ask the app to state the session as the status line states it, in
//! full. The command takes no argument. The app composes the answer, because
//! the place and the numbers live there, and it answers the channel that asked.

const std = @import("std");

const Context = @import("Context.zig");

pub const name = "status";
pub const summary = "state the session";

pub fn run(context: *Context) !Context.Outcome {
    _ = context;
    return .show_status;
}

test "run requests the status" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context)) == .show_status);
}
