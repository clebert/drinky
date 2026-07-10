//! Turns a tool's raw `tool_use` input JSON into its typed argument struct, and
//! guards at compile time that the struct and the tool's advertised parameters
//! describe the same arguments.

const std = @import("std");

const llm = @import("../llm.zig");

/// Parse `input_json` into `Args`. Any malformed or mistyped input becomes
/// `error.InvalidArguments`, which the dispatcher renders into a tool-error
/// result; `error.OutOfMemory` propagates.
pub fn input(comptime Args: type, gpa: std.mem.Allocator, input_json: []const u8) !std.json.Parsed(Args) {
    return std.json.parseFromSlice(Args, gpa, input_json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArguments,
    };
}

/// Compile-time guard that every `Args` field is an advertised parameter and
/// vice versa, that a field is required exactly when it has no default, and that
/// each field's type matches its parameter's advertised type.
pub fn check(comptime Args: type, comptime parameters: []const llm.Parameter) void {
    comptime {
        for (@typeInfo(Args).@"struct".fields) |field| {
            for (parameters) |parameter| {
                if (!std.mem.eql(u8, field.name, parameter.name)) continue;
                if ((field.default_value_ptr == null) != parameter.required) {
                    @compileError("field '" ++ field.name ++ "' required-ness disagrees with its parameter");
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

/// Whether a field of type `Field` can hold a `parameter_type` value, looking
/// through an optional so `?usize` still matches an integer parameter.
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
