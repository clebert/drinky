const std = @import("std");

const App = @import("App.zig");

pub fn main(init: std.process.Init) !void {
    const home = init.environ_map.get("HOME") orelse return error.NoHomeDir;
    var app: App = undefined;
    try app.run(init.gpa, init.io, home, &.{
        .environ = init.minimal.environ,
        .api_keys = .{
            .anthropic = init.environ_map.get("ANTHROPIC_API_KEY"),
            .openai = init.environ_map.get("OPENAI_API_KEY"),
        },
        .terminal_program = init.environ_map.get("TERM_PROGRAM"),
        .terminal_type = init.environ_map.get("TERM"),
        .tmux_session = init.environ_map.get("TMUX"),
        .screen_session = init.environ_map.get("STY"),
    });
}

test {
    std.testing.refAllDecls(@This());
}
