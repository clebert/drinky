const std = @import("std");

const core = @import("core");

pub const Raw = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: @This(), stringify: anytype) !void {
        try stringify.beginWriteRaw();
        try stringify.writer.writeAll(self.bytes);
        stringify.endWriteRaw();
    }
};

pub fn parseObject(
    arena: std.mem.Allocator,
    body: []const u8,
) error{OutOfMemory}!?*const std.json.ObjectMap {
    const value = try arena.create(std.json.Value);
    value.* = std.json.parseFromSliceLeaky(
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

pub fn object(value: ?*const std.json.Value) ?*const std.json.ObjectMap {
    return switch ((value orelse return null).*) {
        .object => |*found| found,
        else => null,
    };
}

pub fn array(value: ?*const std.json.Value) ?*const std.json.Array {
    return switch ((value orelse return null).*) {
        .array => |*found| found,
        else => null,
    };
}

pub fn string(value: ?*const std.json.Value) ?[]const u8 {
    return switch ((value orelse return null).*) {
        .string => |found| found,
        else => null,
    };
}

pub fn integer(value: ?*const std.json.Value) ?i64 {
    return switch ((value orelse return null).*) {
        .integer => |found| found,
        else => null,
    };
}

pub fn number(value: ?*const std.json.Value) ?f64 {
    return switch ((value orelse return null).*) {
        .float => |found| found,
        .integer => |found| @floatFromInt(found),
        .number_string => |found| std.fmt.parseFloat(f64, found) catch null,
        else => null,
    };
}

pub fn boolean(value: ?*const std.json.Value) ?bool {
    return switch ((value orelse return null).*) {
        .bool => |found| found,
        else => null,
    };
}

pub fn unsigned(value: ?*const std.json.Value) ?u64 {
    const found = integer(value) orelse return null;
    return if (found < 0) null else @intCast(found);
}

pub fn writeParametersSchema(
    stringify: *std.json.Stringify,
    parameters: []const core.Tool.Parameter,
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

pub fn amountUsd(value: ?*const std.json.Value) ?f64 {
    const found = value orelse return null;
    const amount = switch (found.*) {
        .string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => number(found) orelse return null,
    };
    if (!std.math.isFinite(amount) or amount < 0 or amount > core.Provider.amount_usd_max)
        return null;
    return amount;
}

test "a number reads an integer, a float, or a number string, and never a string" {
    try std.testing.expectEqual(@as(?f64, 7), number(&.{ .integer = 7 }));
    try std.testing.expectEqual(@as(?f64, 2.5), number(&.{ .float = 2.5 }));
    const beyond_i64: std.json.Value = .{ .number_string = "100000000000000000000" };
    try std.testing.expectEqual(@as(?f64, 1e20), number(&beyond_i64));
    try std.testing.expectEqual(@as(?f64, null), number(&.{ .string = "7" }));
    try std.testing.expectEqual(@as(?f64, null), number(null));
}

test "an unsigned value is a JSON integer that is not negative" {
    try std.testing.expectEqual(@as(?u64, 7), unsigned(&.{ .integer = 7 }));
    try std.testing.expectEqual(@as(?u64, 0), unsigned(&.{ .integer = 0 }));
    try std.testing.expectEqual(@as(?u64, null), unsigned(&.{ .integer = -1 }));
    try std.testing.expectEqual(@as(?u64, null), unsigned(&.{ .float = 7 }));
    try std.testing.expectEqual(@as(?u64, null), unsigned(&.{ .string = "7" }));
    try std.testing.expectEqual(@as(?u64, null), unsigned(null));
}

test "an amount in US dollars reads a number or a numeric string within its bound" {
    try std.testing.expectEqual(@as(?f64, 2.5), amountUsd(&.{ .float = 2.5 }));
    try std.testing.expectEqual(@as(?f64, 7), amountUsd(&.{ .integer = 7 }));
    try std.testing.expectEqual(@as(?f64, 7.14), amountUsd(&.{ .string = "7.14" }));
    try std.testing.expectEqual(@as(?f64, 0), amountUsd(&.{ .string = "0" }));
    try std.testing.expectEqual(@as(?f64, null), amountUsd(&.{ .string = "x" }));
    try std.testing.expectEqual(@as(?f64, null), amountUsd(&.{ .string = "-1" }));
    try std.testing.expectEqual(@as(?f64, null), amountUsd(&.{ .string = "nan" }));
    try std.testing.expectEqual(@as(?f64, null), amountUsd(&.{ .string = "inf" }));
    const above: std.json.Value = .{ .float = core.Provider.amount_usd_max * 2 };
    try std.testing.expectEqual(@as(?f64, null), amountUsd(&above));
    try std.testing.expectEqual(@as(?f64, null), amountUsd(&.{ .bool = true }));
    try std.testing.expectEqual(@as(?f64, null), amountUsd(null));
}
