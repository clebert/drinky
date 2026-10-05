const std = @import("std");

const core = @import("core");

const Context = @import("Context.zig");
const output = @import("output.zig");
const testing = @import("testing.zig");

pub const spec: core.Tool = .{
    .name = "describe_drinky",
    .description = "Describe the Drinky harness itself. The document names the slash " ++
        "commands, every key of the config file, the key bindings, and the instruction and " ++
        "skill files that Drinky discovers. It reports no current value. Read it before you " ++
        "answer a question about Drinky. Read it before you change a config key too, because " ++
        "the harness ignores a key that it does not know.",
    .parameters = &.{},
};

pub fn run(context: *const Context, input_json: []const u8) Context.Error!core.Tool.Output {
    _ = input_json;
    const document = context.host.document;
    if (document.len == 0) return output.failure(
        context.gpa,
        .failed,
        "This harness exposes no document of itself.",
        .{},
    );
    return .{ .content = try context.gpa.dupe(u8, document) };
}

test "the tool returns the injected document and measures nothing" {
    const context: Context = .{
        .gpa = std.testing.allocator,
        .host = .{ .io = std.testing.io, .document = "# Drinky\n" },
    };
    const result = try run(&context, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("# Drinky\n", result.content);
    try testing.expectMeasures(&result, &.{});
    try testing.expectConditions(&result, &.{});
}

test "a host without a document reports an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .host = .{ .io = std.testing.io } };
    const result = try run(&context, "{}");
    defer result.deinit(std.testing.allocator);
    try testing.expectConditions(&result, &.{.failed});
}
