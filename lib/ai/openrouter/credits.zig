//! The credit pool of an OpenRouter account. The public Responses endpoint
//! states no balance, so Drinky reads the credits endpoint of the same key.
//! A key that the endpoint refuses states no pool, and the status line shows
//! none.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");

/// The endpoint states the pool and the spend of the account behind the key.
const endpoint = "https://openrouter.ai/api/v1/credits";

/// The credit pool behind `key`, or null when the endpoint refuses the
/// request or the body names no pool. The caller owns nothing. A non-OK
/// status, including 401 for a key another instance replaced, returns null.
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

/// Decode the credits body into one pool. Null when the body names no pool or
/// no spend, because a pool that states one of the two states no balance.
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

/// A pool figure in USD. A negative or non-finite value is no figure, and
/// neither is one past the money bound.
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

    // The endpoint states the spend of every key that draws on the pool, and a
    // pool can hold more spend than it purchased in the edge cases it states.
    const overdrawn = "{\"data\":{\"total_credits\":1,\"total_usage\":2}}";
    try std.testing.expectEqual(@as(f64, 0), (try parse(gpa, overdrawn)).?.remaining());

    // A figure spelled as a string is no figure, as in the xAI read.
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
    // The status line prints the amount into a fixed buffer, so a figure past
    // any real pool is no figure.
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
