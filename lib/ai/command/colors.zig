//! `/colors`: ask the app to show its terminal color preview page. The command
//! takes no argument.

const std = @import("std");

const Context = @import("Context.zig");

pub const name = "colors";
pub const summary = "preview every color and text style";

pub fn run(context: *Context) !Context.Outcome {
    _ = context;
    return .show_colors;
}

test "run requests the color preview page" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context)) == .show_colors);
}
