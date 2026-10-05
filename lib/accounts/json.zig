const std = @import("std");

const providers = @import("providers");

const Model = @import("Model.zig");

const Envelope = struct {
    parsed: std.json.Parsed(std.json.Value),
    object: std.json.ObjectMap,
    entries: []const std.json.Value,

    const Options = struct {
        field: []const u8,
        entries_max: usize,
        field_optional: bool = false,
    };

    pub fn deinit(self: *const Envelope) void {
        self.parsed.deinit();
    }
};

pub fn positive(comptime T: type, value: ?*const std.json.Value) ?T {
    const found = providers.json.integer(value) orelse return null;
    if (found <= 0) return null;
    return std.math.cast(T, found);
}

pub fn envelope(
    gpa: std.mem.Allocator,
    body: []const u8,
    options: *const Envelope.Options,
) error{ OutOfMemory, BadModelList }!Envelope {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadModelList,
        };
    errdefer parsed.deinit();
    const object = providers.json.object(&parsed.value) orelse return error.BadModelList;
    const entries: []const std.json.Value = if (object.getPtr(options.field)) |value|
        (providers.json.array(value) orelse return error.BadModelList).items
    else if (options.field_optional)
        &.{}
    else
        return error.BadModelList;
    if (entries.len > options.entries_max) return error.BadModelList;
    return .{ .parsed = parsed, .object = object.*, .entries = entries };
}

pub fn models(
    gpa: std.mem.Allocator,
    entries: []const std.json.Value,
    comptime decode: fn (*const std.json.Value) ?Model,
) error{OutOfMemory}![]Model {
    var decoded: std.ArrayList(Model) = .empty;
    errdefer decoded.deinit(gpa);
    for (entries) |*value| {
        const model = decode(value) orelse continue;
        try decoded.append(gpa, model);
    }
    return decoded.toOwnedSlice(gpa);
}

test "a count that states a limit is positive and fits its type, and anything else states none" {
    try std.testing.expectEqual(@as(?u64, 7), positive(u64, &.{ .integer = 7 }));
    try std.testing.expectEqual(@as(?u64, null), positive(u64, &.{ .integer = 0 }));
    try std.testing.expectEqual(@as(?u64, null), positive(u64, &.{ .integer = -1 }));
    try std.testing.expectEqual(@as(?u64, null), positive(u64, &.{ .string = "7" }));
    try std.testing.expectEqual(@as(?u64, null), positive(u64, null));
    const over_u32: std.json.Value = .{ .integer = std.math.maxInt(u32) + 1 };
    try std.testing.expectEqual(@as(?u32, null), positive(u32, &over_u32));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u32) + 1), positive(u64, &over_u32));
}

test "an envelope bounds its entries and reports every malformed body as a bad model list" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"data\":{}}",
        "{\"data\":[1,2,3]}",
    }) |body| {
        try std.testing.expectError(
            error.BadModelList,
            envelope(gpa, body, &.{ .field = "data", .entries_max = 2 }),
        );
    }

    const at_max = try envelope(gpa, "{\"data\":[1,2],\"has_more\":true}", &.{
        .field = "data",
        .entries_max = 2,
    });
    defer at_max.deinit();
    try std.testing.expectEqual(@as(usize, 2), at_max.entries.len);
    try std.testing.expect(at_max.object.get("has_more").?.bool);

    const absent = try envelope(gpa, "{}", &.{
        .field = "data",
        .entries_max = 2,
        .field_optional = true,
    });
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 0), absent.entries.len);
    try std.testing.expectError(error.BadModelList, envelope(gpa, "{\"data\":7}", &.{
        .field = "data",
        .entries_max = 2,
        .field_optional = true,
    }));
}
