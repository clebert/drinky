//! Hands the model the config document that the host injects through `Context`.
//! The tool describes the config file. It never reads the values in that file,
//! and it writes nothing. The host owns the text, so this module keeps no
//! knowledge of any config key. The tool description is the always-present
//! pointer, and the document itself arrives only when the model calls the tool.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");

pub const spec: llm.Tool = .{
    .name = "describe_config",
    .description = "Describe the harness config file. It names the file and lists every key " ++
        "with its type, its default, and its meaning. It reports no current value. Read it " ++
        "before you change a key, because the harness ignores a key that it does not know.",
    .parameters = &.{},
};

pub fn run(context: *const Context, input_json: []const u8) !Result {
    // The tool takes no arguments, so whatever the model sent says nothing.
    _ = input_json;
    const document = context.config_document;
    if (document.len == 0) return Result.report(
        context.gpa,
        .err,
        "This harness exposes no config document.",
        .{},
    );
    // The box keeps the call row alone. The document is the same text at every
    // call, so a measure of it states nothing that the user can act on. The
    // document names the config file, and that path belongs to the answer.
    return .{ .content = try context.gpa.dupe(u8, document), .is_error = false };
}

test "the tool returns the injected document and no box line" {
    const context: Context = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .config_document = "# Pith configuration\n",
    };
    const result = try run(&context, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("# Pith configuration\n", result.content);
    try std.testing.expectEqual(@as(?[]const u8, null), result.summary);
}

test "a host without a document reports an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}
