//! The prepaid USD balance of a DeepSeek API-key account. The Responses
//! endpoint states no pool, so Drinky reads `GET /user/balance` of the same
//! key. A key that the endpoint refuses states no pool, and the status line
//! shows none. A CNY row is not a dollar figure, so Drinky takes a USD row
//! alone.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");

const endpoint = "https://api.deepseek.com/user/balance";

/// The remaining USD balance behind `key`, or null when the endpoint refuses
/// the request or the body names no USD row. The caller owns nothing.
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

/// Decode the balance body into one remaining USD amount. Null when the body
/// names no USD row. The pool type stores spend as well, and this endpoint
/// states remaining funds alone, so `used` is zero.
fn parse(gpa: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?llm.Credits {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    defer parsed.deinit();
    const root = json.object(parsed.value) orelse return null;
    const listed = json.array(root.get("balance_infos")) orelse return null;
    for (listed.items) |item| {
        const object = json.object(item) orelse continue;
        const currency = json.string(object.get("currency")) orelse continue;
        if (!std.mem.eql(u8, currency, "USD")) continue;
        const total = amountUsd(object.get("total_balance")) orelse return null;
        return .{ .total = total, .used = 0 };
    }
    return null;
}

/// A remaining amount in USD. A negative or non-finite value is no figure, and
/// neither is one past the money bound. The endpoint spells the figure as a
/// decimal string.
fn amountUsd(value: ?std.json.Value) ?f64 {
    const amount = switch (value orelse return null) {
        .integer => |found| @as(f64, @floatFromInt(found)),
        .float => |found| found,
        .number_string => |found| std.fmt.parseFloat(f64, found) catch return null,
        .string => |found| std.fmt.parseFloat(f64, found) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(amount) or amount < 0 or amount > llm.amount_usd_max) return null;
    return amount;
}

test "a credential that cannot be a header refuses the balance request" {
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
    const usd =
        \\{"is_available":true,"balance_infos":[
        \\  {"currency":"CNY","total_balance":"110.00",
        \\   "granted_balance":"10.00","topped_up_balance":"100.00"},
        \\  {"currency":"USD","total_balance":"7.14",
        \\   "granted_balance":"0.00","topped_up_balance":"7.14"}]}
    ;
    const credits = (try parse(gpa, usd)).?;
    try std.testing.expectEqual(@as(f64, 7.14), credits.total);
    try std.testing.expectEqual(@as(f64, 0), credits.used);
    try std.testing.expectEqual(@as(f64, 7.14), credits.remaining());

    // A CNY row is not a dollar figure, so a body with no USD row states no pool.
    const cny_only =
        \\{"is_available":true,"balance_infos":[
        \\  {"currency":"CNY","total_balance":"110.00",
        \\   "granted_balance":"10.00","topped_up_balance":"100.00"}]}
    ;
    try std.testing.expect(try parse(gpa, cny_only) == null);

    const integer =
        \\{"balance_infos":[{"currency":"USD","total_balance":0}]}
    ;
    try std.testing.expectEqual(@as(f64, 0), (try parse(gpa, integer)).?.remaining());

    try std.testing.expect(try parse(gpa, "{}") == null);
    try std.testing.expect(try parse(gpa, "not-json") == null);
    try std.testing.expect(try parse(gpa, "{\"balance_infos\":[]}") == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"x\"}]}",
    ) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"-1\"}]}",
    ) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"1e308\"}]}",
    ) == null);
}
