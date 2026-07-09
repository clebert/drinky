const std = @import("std");

pub const version = "0.0.0";

pub const App = @import("App.zig");

pub const terminal = struct {
    pub const Terminal = @import("terminal/Terminal.zig");
    pub const escape = @import("terminal/escape.zig");
};

pub const tui = struct {
    pub const width = @import("tui/width.zig");
    pub const key = @import("tui/key.zig");
    pub const Input = @import("tui/Input.zig");
    pub const Editor = @import("tui/Editor.zig");
    pub const Renderer = @import("tui/Renderer.zig");
};

pub const anthropic = struct {
    pub const message = @import("anthropic/message.zig");
    pub const oauth = @import("anthropic/oauth.zig");
    pub const Auth = @import("anthropic/Auth.zig");
    pub const Client = @import("anthropic/Client.zig");
};

pub const agent = struct {
    pub const tools = @import("agent/tools.zig");
    pub const Agent = @import("agent/Agent.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = App;
    _ = anthropic.message;
    _ = anthropic.oauth;
    _ = anthropic.Auth;
    _ = anthropic.Client;
    _ = agent.tools;
    _ = agent.Agent;
    _ = tui.width;
    _ = tui.Input;
    _ = tui.Editor;
    _ = tui.Renderer;
}
