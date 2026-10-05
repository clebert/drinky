const std = @import("std");

const core = @import("core");

pub fn input(
    comptime Args: type,
    gpa: std.mem.Allocator,
    input_json: []const u8,
) error{ InvalidArguments, OutOfMemory }!std.json.Parsed(Args) {
    return std.json.parseFromSlice(
        Args,
        gpa,
        input_json,
        .{ .ignore_unknown_fields = true },
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArguments,
    };
}

pub fn check(comptime Args: type, comptime parameters: []const core.Tool.Parameter) void {
    comptime {
        for (@typeInfo(Args).@"struct".fields) |field| {
            for (parameters) |parameter| {
                if (!std.mem.eql(u8, field.name, parameter.name)) continue;
                if ((field.default_value_ptr == null) != parameter.required) {
                    @compileError("field '" ++ field.name ++
                        "' required-ness disagrees with its parameter");
                }
                if (!typeMatches(field.type, parameter.type)) {
                    @compileError("field '" ++ field.name ++ "' type disagrees with its parameter");
                }
                break;
            } else @compileError("field '" ++ field.name ++ "' is not an advertised parameter");
        }
        for (parameters) |parameter| {
            for (@typeInfo(Args).@"struct".fields) |field| {
                if (std.mem.eql(u8, parameter.name, field.name)) break;
            } else @compileError("parameter '" ++ parameter.name ++ "' has no matching field");
        }
    }
}

fn typeMatches(comptime Field: type, comptime parameter_type: core.Tool.Parameter.Type) bool {
    const Value = switch (@typeInfo(Field)) {
        .optional => |optional| optional.child,
        else => Field,
    };
    return switch (parameter_type) {
        .string => Value == []const u8,
        .integer => @typeInfo(Value) == .int,
        .boolean => Value == bool,
    };
}

test "a malformed or mistyped argument list is invalid, not an error of the tool" {
    const Args = struct { path: []const u8, limit: ?usize = null };
    const parsed = try input(Args, std.testing.allocator, "{\"path\":\"a.zig\",\"limit\":3}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a.zig", parsed.value.path);
    try std.testing.expectEqual(@as(?usize, 3), parsed.value.limit);
    try std.testing.expectError(error.InvalidArguments, input(Args, std.testing.allocator, "{}"));
    try std.testing.expectError(
        error.InvalidArguments,
        input(Args, std.testing.allocator, "{\"path\":\"a.zig\",\"limit\":1.5}"),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        input(Args, std.testing.allocator, "{\"path\":\"a.zig\",\"limit\":-3}"),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        input(Args, std.testing.allocator, "{\"pa"),
    );
}

test "the typed parse takes a quoted or an integral number for an integer" {
    const Args = struct { limit: u64 };
    for ([_][]const u8{ "{\"limit\":\"3\"}", "{\"limit\":3.0}" }) |input_json| {
        const parsed = try input(Args, std.testing.allocator, input_json);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(u64, 3), parsed.value.limit);
    }
}
