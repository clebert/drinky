const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const net = @import("../net.zig");

const url = "https://openrouter.ai/api/v1/key";
const body_bytes_max = 64 * 1024;

pub const Error = providers.Http.FetchError ||
    error{ Timeout, ConcurrencyUnavailable, BadKey, KeyUnauthorized, KeyRequestFailed };

pub fn verify(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    deadline: *const core.timeout.Deadline,
    key: []const u8,
) Error!void {
    return deadline.run(io, request, .{ gpa, io, transport, key }, null);
}

fn request(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    key: []const u8,
) Error!void {
    if (!providers.Transport.validHeaderValue(key)) return error.BadKey;
    const authorization = try gpa.print("Bearer {s}", .{key});
    defer gpa.free(authorization);
    const response = try providers.Http.fetch(gpa, io, transport, &.{
        .method = .GET,
        .url = url,
        .authorization = authorization,
        .headers = &.{net.accept_json},
    }, body_bytes_max);
    gpa.free(response.body);
    return switch (response.status) {
        .ok => {},
        .unauthorized => error.KeyUnauthorized,
        else => error.KeyRequestFailed,
    };
}

test "a key check asks for the current key and names a rejected or a failed request" {
    const gpa = std.testing.allocator;
    var transport: providers.testing.FakeTransport = .{ .gpa = gpa, .replies = &.{
        .{ .body = "{\"data\":{\"label\":\"sk-or-v1-a\"}}" },
        .{ .status = .unauthorized, .body = "{\"error\":{\"code\":401}}" },
        .{ .status = .internal_server_error },
    } };
    defer transport.deinit();
    try verify(gpa, std.testing.io, transport.transport(), &.unbounded, "sk-or-v1-a");
    try std.testing.expectError(
        error.KeyUnauthorized,
        verify(gpa, std.testing.io, transport.transport(), &.unbounded, "sk-or-v1-b"),
    );
    try std.testing.expectError(
        error.KeyRequestFailed,
        verify(gpa, std.testing.io, transport.transport(), &.unbounded, "sk-or-v1-c"),
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.requests.items[0],
        "GET https://openrouter.ai/api/v1/key\nauthorization: Bearer sk-or-v1-a\n",
    ));
    try std.testing.expectError(
        error.BadKey,
        verify(gpa, std.testing.io, transport.transport(), &.unbounded, "sk\r\nx"),
    );
    try std.testing.expectEqual(@as(usize, 3), transport.requests.items.len);
}
