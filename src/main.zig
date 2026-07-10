const std = @import("std");

const App = @import("App.zig");

pub fn main(init: std.process.Init) !void {
    const home = init.environ_map.get("HOME") orelse return error.NoHomeDir;
    var app: App = undefined;
    try app.run(init.gpa, init.io, home);
}

test {
    std.testing.refAllDecls(@This());
}
