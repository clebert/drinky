const Context = @import("Context.zig");

pub const name = "new";
pub const summary = "Clear the conversation";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    _ = context;
    return .new_conversation;
}
