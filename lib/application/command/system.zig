const Context = @import("Context.zig");

pub const name = "system";
pub const summary = "Show the complete system prompt";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    return .{ .page = .{ .title = "System prompt", .content = context.system_prompt } };
}
