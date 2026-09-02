const std = @import("std");

const App = @import("App.zig");
const Herdr = @import("Herdr.zig");

pub fn main(init: std.process.Init) !void {
    const home = init.environ_map.get("HOME") orelse return error.NoHomeDir;
    var app: App = undefined;
    try app.run(init.gpa, init.io, home, &.{
        .environ = init.minimal.environ,
        .api_keys = .{
            .anthropic = init.environ_map.get("ANTHROPIC_API_KEY"),
            .openai = init.environ_map.get("OPENAI_API_KEY"),
        },
        .herdr = Herdr.fromEnviron(init.environ_map),
    });
}

test {
    std.testing.refAllDecls(@This());
}
