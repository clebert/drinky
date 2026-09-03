//! `/sources`: ask the app to show the instruction files, the skills, and the
//! required skills that it loaded at startup. The command takes no argument.

const std = @import("std");

const Context = @import("Context.zig");

pub const name = "sources";
pub const summary = "inspect the instruction files and the skills";

pub fn run(context: *Context) !Context.Outcome {
    _ = context;
    return .show_sources;
}

test "run requests the sources page" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context)) == .show_sources);
}
