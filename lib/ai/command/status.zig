const std = @import("std");

const Context = @import("Context.zig");

pub const name = "status";
pub const summary = "State the session";

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
