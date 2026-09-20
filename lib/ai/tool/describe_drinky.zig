const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");

pub const spec: llm.Tool = .{
    .name = "describe_drinky",
    .description = "Describe the Drinky harness itself: its slash commands, its config file " ++
        "with every key, its key bindings, and the instruction and skill files that it " ++
        "discovers. It reports no current value. Read it before you answer a question about " ++
        "Drinky, and before you change a config key, because the harness ignores a key that " ++
        "it does not know.",
    .parameters = &.{},
};

pub fn run(context: *const Context, input_json: []const u8) !Result {
    _ = input_json;
    const document = context.document;
    if (document.len == 0) return Result.report(
        context.gpa,
        .err,
        "This harness exposes no document of itself.",
        .{},
    );
    return .{ .content = try context.gpa.dupe(u8, document), .is_error = false };
}

test "the tool returns the injected document and no box line" {
    const context: Context = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .document = "# Drinky\n",
    };
    const result = try run(&context, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("# Drinky\n", result.content);
    try std.testing.expectEqual(@as(?Result.Summary, null), result.summary);
}

test "a host without a document reports an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}
