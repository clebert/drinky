const std = @import("std");

const lib = @import("lib");

pub fn main(init: std.process.Init) !void {
    const home = init.environ_map.get("HOME") orelse return error.NoHomeDir;
    var app: lib.App = undefined;
    try app.run(init.gpa, init.io, home);
}
