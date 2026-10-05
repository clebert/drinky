const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const json_timeout_ms = 5_000;
const json_bytes_max = 256 * 1024;

const JsonError = providers.Http.FetchError ||
    error{ BadCredentials, Timeout, ConcurrencyUnavailable };

const Get = struct {
    url: []const u8,
    bearer: []const u8,
};

pub const accept_json: std.http.Header = .{ .name = "accept", .value = "application/json" };

pub fn getJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    get: *const Get,
) JsonError!?[]u8 {
    if (!providers.Transport.validHeaderValue(get.bearer)) return error.BadCredentials;
    return core.timeout.run(
        io,
        json_timeout_ms,
        requestJson,
        .{ gpa, io, transport, get },
        releaseJson,
    );
}

fn requestJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    get: *const Get,
) !?[]u8 {
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{get.bearer});
    defer gpa.free(authorization);
    const response = try providers.Http.fetch(gpa, io, transport, &.{
        .method = .GET,
        .url = get.url,
        .authorization = authorization,
        .headers = &.{accept_json},
    }, json_bytes_max);
    if (response.status == .ok) return response.body;
    gpa.free(response.body);
    return null;
}

fn releaseJson(body: *const ?[]u8, args: *const std.meta.ArgsTuple(@TypeOf(requestJson))) void {
    if (body.*) |bytes| args[0].free(bytes);
}

pub fn getBody(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    request: *const providers.Transport.Request,
    bytes_max: usize,
) (providers.Http.FetchError || error{ModelListRequestFailed})![]u8 {
    const response = try providers.Http.fetch(gpa, io, transport, request, bytes_max);
    if (response.status == .ok) return response.body;
    gpa.free(response.body);
    return error.ModelListRequestFailed;
}

test "getJson refuses a credential that cannot be a header before it opens" {
    var transport: providers.testing.FakeTransport = .{ .gpa = std.testing.allocator };
    defer transport.deinit();
    for ([_][]const u8{ "", "token\r\nleaked: value" }) |bearer| {
        try std.testing.expectError(error.BadCredentials, getJson(
            std.testing.allocator,
            std.testing.io,
            transport.transport(),
            &.{ .url = "https://example.invalid/", .bearer = bearer },
        ));
    }
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}
