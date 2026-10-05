const std = @import("std");

const core = @import("core");
const providers = @import("providers");

pub fn parse(gpa: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?core.Provider.Credits {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = (try providers.json.parseObject(arena.allocator(), body)) orelse return null;
    const data = providers.json.object(root.getPtr("data")) orelse return null;
    const total = providers.json.amountUsd(data.getPtr("total_credits")) orelse return null;
    const used = providers.json.amountUsd(data.getPtr("total_usage")) orelse return null;
    return .{ .total = total, .used = used };
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
    try std.testing.expectEqual(@as(f64, 5), (try parse(gpa, string_figures)).?.remaining());

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
