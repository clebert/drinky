const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");

const endpoint = "https://openrouter.ai/api/v1/credits";

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    key: []const u8,
) !?llm.Credits {
    const body = try net.getJson(gpa, io, &.{ .url = endpoint, .bearer = key }) orelse
        return null;
    defer gpa.free(body);
    return parse(gpa, body);
}

fn parse(gpa: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?llm.Credits {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    defer parsed.deinit();
    const root = json.object(parsed.value) orelse return null;
    const data = json.object(root.get("data")) orelse return null;
    const total = amountUsd(data.get("total_credits")) orelse return null;
    const used = amountUsd(data.get("total_usage")) orelse return null;
    return .{ .total = total, .used = used };
}

fn amountUsd(value: ?std.json.Value) ?f64 {
    const amount = switch (value orelse return null) {
        .integer => |found| @as(f64, @floatFromInt(found)),
        .float => |found| found,
        .number_string => |found| std.fmt.parseFloat(f64, found) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(amount) or amount < 0 or amount > llm.amount_usd_max) return null;
    return amount;
}

test "a credential that cannot be a header refuses the pool request" {
    try std.testing.expectError(
        error.BadCredentials,
        fetch(std.testing.allocator, std.testing.io, ""),
    );
    try std.testing.expectError(
        error.BadCredentials,
        fetch(std.testing.allocator, std.testing.io, "key\r\nleaked: value"),
    );
}

test parse {
    const gpa = std.testing.allocator;
    const pool =
        \\{"data":{"total_credits":10,"total_usage":2.864085024}}
    ;
    const credits = (try parse(gpa, pool)).?;
    try std.testing.expectEqual(@as(f64, 10), credits.total);
    try std.testing.expectEqual(@as(f64, 2.864085024), credits.used);
    try std.testing.expectApproxEqAbs(@as(f64, 7.135914976), credits.remaining(), 1e-9);

    const integer = "{\"data\":{\"total_credits\":0,\"total_usage\":0}}";
    try std.testing.expectEqual(@as(f64, 0), (try parse(gpa, integer)).?.remaining());

    const overdrawn = "{\"data\":{\"total_credits\":1,\"total_usage\":2}}";
    try std.testing.expectEqual(@as(f64, 0), (try parse(gpa, overdrawn)).?.remaining());

    const string_figures = "{\"data\":{\"total_credits\":\"10\",\"total_usage\":5}}";
    try std.testing.expect(try parse(gpa, string_figures) == null);

    try std.testing.expect(try parse(gpa, "{}") == null);
    try std.testing.expect(try parse(gpa, "not-json") == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"data\":{\"total_credits\":1}}",
    ) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"data\":{\"total_usage\":1}}",
    ) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"data\":{\"total_credits\":-1,\"total_usage\":0}}",
    ) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"data\":{\"total_credits\":1e308,\"total_usage\":0}}",
    ) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"data\":{\"total_credits\":1,\"total_usage\":1e308}}",
    ) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"data\":{\"total_credits\":\"x\",\"total_usage\":0}}",
    ) == null);
}
