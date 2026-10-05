const std = @import("std");

const core = @import("core");
const providers = @import("providers");

pub fn parse(gpa: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?core.Provider.Credits {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = (try providers.json.parseObject(arena.allocator(), body)) orelse return null;
    const listed = providers.json.array(root.getPtr("balance_infos")) orelse return null;
    for (listed.items) |*item| {
        const object = providers.json.object(item) orelse continue;
        const currency = providers.json.string(object.getPtr("currency")) orelse continue;
        if (!std.mem.eql(u8, currency, "USD")) continue;
        const total = providers.json.amountUsd(object.getPtr("total_balance")) orelse return null;
        return .{ .total = total, .used = 0 };
    }
    return null;
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
