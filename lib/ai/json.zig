//! Shared JSON plumbing: the lenient body parse and the lenient
//! `std.json.Value` accessors for the wire decoders — a malformed body, an
//! absent value, or a mismatched type reads as null — plus the tool-parameters
//! JSON-schema writer both provider serializers emit.

const std = @import("std");

const llm = @import("llm.zig");

/// The object that `body` parses to, or null when the bytes are not JSON or
/// carry another kind of value. Only an allocation failure surfaces, so a
/// malformed body needs no error branch at the call site. The parse leaks into
/// `arena`, and the returned strings live until that arena resets.
pub fn parseObject(
    arena: std.mem.Allocator,
    body: []const u8,
) error{OutOfMemory}!?std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        body,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return object(value);
}

pub fn object(value: ?std.json.Value) ?std.json.ObjectMap {
    return switch (value orelse return null) {
        .object => |found| found,
        else => null,
    };
}

pub fn array(value: ?std.json.Value) ?std.json.Array {
    return switch (value orelse return null) {
        .array => |found| found,
        else => null,
    };
}

pub fn string(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |found| found,
        else => null,
    };
}

pub fn integer(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |found| found,
        else => null,
    };
}

/// A token count: a negative integer clamps to zero.
pub fn unsigned(value: ?std.json.Value) ?u64 {
    const found = integer(value) orelse return null;
    return if (found < 0) 0 else @intCast(found);
}

/// The `{"type":"object","properties":…,"required":…}` schema for a tool's
/// parameters.
pub fn writeParametersSchema(
    stringify: *std.json.Stringify,
    parameters: []const llm.Parameter,
) !void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write("object");
    try stringify.objectField("properties");
    try stringify.beginObject();
    for (parameters) |parameter| {
        try stringify.objectField(parameter.name);
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(@tagName(parameter.type));
        try stringify.objectField("description");
        try stringify.write(parameter.description);
        try stringify.endObject();
    }
    try stringify.endObject();
    try stringify.objectField("required");
    try stringify.beginArray();
    for (parameters) |parameter| {
        if (parameter.required) try stringify.write(parameter.name);
    }
    try stringify.endArray();
    try stringify.endObject();
}
