const Context = @import("Context.zig");

pub const name = "sources";
pub const summary = "Show the loaded instruction files and skills";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    return .{ .page = .{ .title = "Sources", .content = context.sources_page } };
}
