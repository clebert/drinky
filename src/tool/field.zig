//! Reads named fields from a parsed JSON object, returning null when the value
//! is missing or the wrong type. Tool handlers use these to pull typed
//! arguments out of the raw `tool_use` input.

const std = @import("std");

pub fn string(value: std.json.Value, name: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const found = object.get(name) orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

pub fn uint(value: std.json.Value, name: []const u8) ?usize {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const found = object.get(name) orelse return null;
    return switch (found) {
        .integer => |integer| if (integer < 0) null else std.math.cast(usize, integer),
        else => null,
    };
}

pub fn boolean(value: std.json.Value, name: []const u8) ?bool {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const found = object.get(name) orelse return null;
    return switch (found) {
        .bool => |flag| flag,
        else => null,
    };
}
