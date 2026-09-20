const std = @import("std");

const llm = @import("../llm.zig");

pub fn input(
    comptime Args: type,
    gpa: std.mem.Allocator,
    input_json: []const u8,
) !std.json.Parsed(Args) {
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

pub fn check(comptime Args: type, comptime parameters: []const llm.Parameter) void {
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

fn typeMatches(comptime Field: type, comptime parameter_type: llm.Parameter.Type) bool {
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
