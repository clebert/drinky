const std = @import("std");

const core = @import("core");

const escape = @import("escape.zig");

const usage = "Use drinky, drinky models, or drinky run --model account/model --effort level.";

pub const effort_levels = levels: {
    const names = std.meta.fieldNames(core.Provider.Effort);
    var text: []const u8 = "";
    for (names, 0..) |name, index| {
        const separator = if (index == 0) "" else if (index + 1 == names.len) ", or " else ", ";
        text = text ++ separator ++ name;
    }
    break :levels text;
};

pub const Parsed = union(enum) {
    terminal,
    models,
    run: Run,
    refused: Refusal,
};

pub const Run = struct {
    model: []const u8,
    effort: core.Provider.Effort,
};

pub const Refusal = union(enum) {
    unknown_argument: []const u8,
    value_missing: []const u8,
    model_missing,
    effort_missing,
    effort_unknown: []const u8,

    pub fn write(
        self: *const Refusal,
        gpa: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) (error{OutOfMemory} || std.Io.Writer.Error)!void {
        switch (self.*) {
            .unknown_argument => |argument| {
                const shown = try escape.diagnostic(gpa, argument);
                defer gpa.free(shown);
                try writer.print("Drinky does not know the argument \"{s}\". {s}\n", .{
                    shown,
                    usage,
                });
            },
            .value_missing => |flag| try writer.print("Add a value after the flag {s}.\n", .{flag}),
            .model_missing => try writer.writeAll(
                "Add the flag --model with an account/model value. Run drinky models for the " ++
                    "valid values.\n",
            ),
            .effort_missing => try writer.writeAll(
                "Add the flag --effort with one of the levels " ++ effort_levels ++ ".\n",
            ),
            .effort_unknown => |level| {
                const shown = try escape.diagnostic(gpa, level);
                defer gpa.free(shown);
                try writer.print("Drinky does not know the effort level \"{s}\". Use {s}.\n", .{
                    shown,
                    effort_levels,
                });
            },
        }
    }
};

pub fn parse(arguments: []const [:0]const u8) Parsed {
    if (arguments.len == 0) return .terminal;
    const name = arguments[0];
    const rest = arguments[1..];
    if (std.mem.eql(u8, name, "models")) {
        if (rest.len > 0) return .{ .refused = .{ .unknown_argument = rest[0] } };
        return .models;
    }
    if (std.mem.eql(u8, name, "run")) return parseRun(rest);
    return .{ .refused = .{ .unknown_argument = name } };
}

fn parseRun(arguments: []const [:0]const u8) Parsed {
    var maybe_model: ?[]const u8 = null;
    var maybe_level: ?[]const u8 = null;
    var index: usize = 0;
    while (index < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const slot = if (std.mem.eql(u8, flag, "--model"))
            &maybe_model
        else if (std.mem.eql(u8, flag, "--effort"))
            &maybe_level
        else
            return .{ .refused = .{ .unknown_argument = flag } };
        if (index + 1 == arguments.len) return .{ .refused = .{ .value_missing = flag } };
        slot.* = arguments[index + 1];
    }
    const model = maybe_model orelse return .{ .refused = .model_missing };
    const level = maybe_level orelse return .{ .refused = .effort_missing };
    const effort = std.meta.stringToEnum(core.Provider.Effort, level) orelse
        return .{ .refused = .{ .effort_unknown = level } };
    return .{ .run = .{ .model = model, .effort = effort } };
}

test "the arguments select the terminal, the model list, or a run, and refuse the rest" {
    const Case = struct { arguments: []const [:0]const u8, expected: Parsed };
    const cases = [_]Case{
        .{ .arguments = &.{}, .expected = .terminal },
        .{ .arguments = &.{"models"}, .expected = .models },
        .{
            .arguments = &.{ "run", "--model", "openai-api-key/gpt-5.6-sol", "--effort", "max" },
            .expected = .{ .run = .{ .model = "openai-api-key/gpt-5.6-sol", .effort = .max } },
        },
        .{
            .arguments = &.{ "run", "--effort", "low", "--model", "openrouter-api/openai/o5" },
            .expected = .{ .run = .{ .model = "openrouter-api/openai/o5", .effort = .low } },
        },
        .{ .arguments = &.{"chat"}, .expected = .{ .refused = .{ .unknown_argument = "chat" } } },
        .{
            .arguments = &.{ "models", "--all" },
            .expected = .{ .refused = .{ .unknown_argument = "--all" } },
        },
        .{
            .arguments = &.{ "run", "--model", "a/b", "--effort", "high", "review" },
            .expected = .{ .refused = .{ .unknown_argument = "review" } },
        },
        .{
            .arguments = &.{ "run", "--effort", "high", "--model" },
            .expected = .{ .refused = .{ .value_missing = "--model" } },
        },
        .{
            .arguments = &.{ "run", "--effort", "high" },
            .expected = .{ .refused = .model_missing },
        },
        .{
            .arguments = &.{ "run", "--model", "a/b" },
            .expected = .{ .refused = .effort_missing },
        },
        .{
            .arguments = &.{ "run", "--model", "a/b", "--effort", "extreme" },
            .expected = .{ .refused = .{ .effort_unknown = "extreme" } },
        },
    };
    for (cases) |case| {
        const parsed = parse(case.arguments);
        try std.testing.expectEqualDeep(case.expected, parsed);
    }
}
