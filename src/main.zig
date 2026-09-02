const std = @import("std");

const App = @import("App.zig");
const Herdr = @import("Herdr.zig");

pub fn main(init: std.process.Init) !void {
    const home = init.environ_map.get("HOME") orelse return error.NoHomeDir;
    var app: App = undefined;
    try app.run(init.gpa, init.io, home, &.{
        .environ = init.minimal.environ,
        .credentials = .{
            .anthropic = init.environ_map.get("ANTHROPIC_API_KEY"),
            .openai = init.environ_map.get("OPENAI_API_KEY"),
            .google_key_path = init.environ_map.get("GOOGLE_APPLICATION_CREDENTIALS"),
            .google_location = init.environ_map.get("GOOGLE_CLOUD_LOCATION"),
        },
        .herdr = Herdr.fromEnviron(init.environ_map),
    });
}

test {
    std.testing.refAllDecls(@This());
}
