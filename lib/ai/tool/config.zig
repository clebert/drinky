//! Hands the model the settings document that the host injects through
//! `Context`. The tool is read-only and does no io. The host writes the
//! document and owns the text, so this module keeps no knowledge of any
//! configuration key. The tool description is the always-present pointer, and
//! the document itself arrives only when the model calls the tool.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");

pub const spec: llm.Tool = .{
    .name = "config",
    .description = "Read the harness settings document. It names the settings file and lists " ++
        "every key with its type, its default, and its meaning. Read it before you change a " ++
        "setting, because the harness ignores a key that it does not know.",
    .parameters = &.{},
};

pub fn run(context: *const Context, input_json: []const u8) !Result {
    // The tool takes no arguments, so whatever the model sent says nothing.
    _ = input_json;
    const settings = context.settings;
    if (settings.document.len == 0) return Result.report(
        context.gpa,
        .err,
        "This harness exposes no settings document.",
        .{},
    );
    const content = try context.gpa.dupe(u8, settings.document);
    errdefer context.gpa.free(content);
    // The document runs to many lines, so the box needs the host's summary. The
    // first line of a document is a heading and tells the user nothing.
    const summary = try context.gpa.dupe(u8, settings.summary);
    return .{ .content = content, .summary = summary, .is_error = false };
}

test "the tool returns the injected document and its box summary" {
    const context: Context = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .settings = .{ .document = "# Settings\n", .summary = "File: /home/me/config.json" },
    };
    const result = try run(&context, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("# Settings\n", result.content);
    try std.testing.expectEqualStrings("File: /home/me/config.json", result.summary.?);
}

test "a host without a document reports an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}
