const std = @import("std");

const Transport = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const client_name = "drinky";

pub const Error = std.Uri.ParseError ||
    std.http.Client.RequestError ||
    std.http.Client.Request.ReceiveHeadError ||
    std.Io.Writer.Error ||
    error{ Timeout, ConcurrencyUnavailable };

pub const VTable = struct {
    open: *const fn (ptr: *anyopaque, request: *const Request) Error!Reply,
    close: *const fn (ptr: *anyopaque) void,
};

pub const Timeouts = struct {
    connect_ms: u64 = 30_000,
    idle_ms: u64 = 60_000,
};

pub const Request = struct {
    method: std.http.Method = .POST,
    url: []const u8,
    content_type: ?[]const u8 = "application/json",
    authorization: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
    timeout_ms: u64 = 0,
};

pub const Reply = struct {
    status: std.http.Status,
    headers: []const std.http.Header,
    body: *std.Io.Reader,

    pub fn header(self: *const Reply, name: []const u8) ?[]const u8 {
        for (self.headers) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) return candidate.value;
        }
        return null;
    }

    pub fn retryAfterMs(self: *const Reply) ?u64 {
        const value = self.header("retry-after") orelse return null;
        const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, value, " \t"), 10) catch return null;
        return seconds *| 1000;
    }
};

pub fn open(self: Transport, request: *const Request) Error!Reply {
    return self.vtable.open(self.ptr, request);
}

pub fn close(self: Transport) void {
    self.vtable.close(self.ptr);
}

pub fn validHeaderValue(value: []const u8) bool {
    return value.len != 0 and std.mem.findAny(u8, value, "\r\n") == null;
}

test "a header value cannot split the request head" {
    try std.testing.expect(validHeaderValue("token.account"));
    try std.testing.expect(!validHeaderValue(""));
    try std.testing.expect(!validHeaderValue("token\r\nleaked: value"));
}

test "the retry-after header parses whole seconds and nothing else" {
    var body: std.Io.Reader = .fixed("");
    var reply: Reply = .{
        .status = .too_many_requests,
        .headers = &.{.{ .name = "Retry-After", .value = " 7 " }},
        .body = &body,
    };
    try std.testing.expectEqual(@as(?u64, 7000), reply.retryAfterMs());

    reply.headers = &.{};
    try std.testing.expectEqual(@as(?u64, null), reply.retryAfterMs());

    reply.headers = &.{.{ .name = "retry-after", .value = "Wed, 21 Oct 2015 07:28:00 GMT" }};
    try std.testing.expectEqual(@as(?u64, null), reply.retryAfterMs());

    reply.headers = &.{.{ .name = "retry-after", .value = "99999999999999999" }};
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), reply.retryAfterMs());
}
