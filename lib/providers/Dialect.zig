const std = @import("std");

const core = @import("core");

const Transport = @import("Transport.zig");

const Dialect = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    prepare: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        request: *const core.Provider.Request,
        token: []const u8,
    ) Error!Transport.Request,
    failure: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        failed: *const Failed,
    ) error{OutOfMemory}!core.Provider.Failure,
    quota: *const fn (
        ptr: *anyopaque,
        headers: []const std.http.Header,
        now_seconds: i64,
    ) ?core.Provider.Quota,
    reset: *const fn (ptr: *anyopaque) void,
    decode: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        payload: []const u8,
        events: *Events,
    ) error{OutOfMemory}!Decoded,
    finish: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        events: *Events,
    ) error{OutOfMemory}!void,
};

pub const Error = error{ OutOfMemory, OrphanToolResult };

pub const Events = std.ArrayList(core.Provider.Event);

pub const Decoded = enum { progress, ignored, done };

pub const Failed = struct {
    status: std.http.Status,
    retry_after_ms: ?u64,
    body: []const u8,

    pub const Parsed = struct {
        reason: ?core.Provider.Failure.Reason = null,
        retry_after_ms: ?u64 = null,
        detail: ?[]const u8 = null,
    };

    pub fn failure(
        self: *const Failed,
        arena: std.mem.Allocator,
        parsed: *const Parsed,
    ) error{OutOfMemory}!core.Provider.Failure {
        return .{
            .reason = parsed.reason orelse reason(self.status),
            .retry_after_ms = self.retry_after_ms orelse parsed.retry_after_ms,
            .message = try describe(arena, self.status, parsed.detail orelse self.body),
        };
    }
};

const Rejection = enum {
    invalid,
    unsupported,
    uncorrelated,

    fn outranks(self: Rejection, other: Rejection) bool {
        return self != .invalid and other == .invalid;
    }

    fn latch(self: Rejection, slot: *?Rejection) void {
        const latched = slot.* orelse {
            slot.* = self;
            return;
        };
        if (self.outranks(latched)) slot.* = self;
    }

    fn failure(self: Rejection) core.Provider.Failure {
        return switch (self) {
            .invalid => .{ .reason = .invalid_reply },
            .unsupported => .{
                .reason = .unsupported_reply,
                .message = "The reply holds content that Drinky cannot keep.",
            },
            .uncorrelated => .{
                .reason = .unsupported_reply,
                .message = "The stream named a block other than the open one.",
            },
        };
    }
};

pub const Reply = struct {
    rejection: ?Rejection = null,
    served_model: std.ArrayList(u8) = .empty,
    usage: core.Provider.Usage = .{},

    pub fn deinit(self: *Reply, gpa: std.mem.Allocator) void {
        self.served_model.deinit(gpa);
    }

    pub fn reset(self: *Reply) void {
        self.rejection = null;
        self.served_model.clearRetainingCapacity();
        self.usage = .{};
    }

    pub fn reject(self: *Reply, rejection: Rejection) void {
        rejection.latch(&self.rejection);
    }

    pub fn serve(self: *Reply, gpa: std.mem.Allocator, model: []const u8) error{OutOfMemory}!void {
        self.served_model.clearRetainingCapacity();
        try self.served_model.appendSlice(gpa, model);
    }

    pub fn end(
        self: *const Reply,
        arena: std.mem.Allocator,
        events: *Events,
        stop_reason: core.Provider.Stop.Reason,
    ) error{OutOfMemory}!void {
        if (self.rejection) |rejection| {
            return events.append(arena, .{ .failed = rejection.failure() });
        }
        try events.append(arena, .{ .stopped = .{
            .reason = stop_reason,
            .model = self.served_model.items,
        } });
    }
};

pub fn prepare(
    self: Dialect,
    arena: std.mem.Allocator,
    request: *const core.Provider.Request,
    token: []const u8,
) Error!Transport.Request {
    return self.vtable.prepare(self.ptr, arena, request, token);
}

pub fn failure(
    self: Dialect,
    arena: std.mem.Allocator,
    failed: *const Failed,
) error{OutOfMemory}!core.Provider.Failure {
    return self.vtable.failure(self.ptr, arena, failed);
}

pub fn quota(
    self: Dialect,
    headers: []const std.http.Header,
    now_seconds: i64,
) ?core.Provider.Quota {
    return self.vtable.quota(self.ptr, headers, now_seconds);
}

pub fn reset(self: Dialect) void {
    self.vtable.reset(self.ptr);
}

pub fn decode(
    self: Dialect,
    arena: std.mem.Allocator,
    payload: []const u8,
    events: *Events,
) error{OutOfMemory}!Decoded {
    return self.vtable.decode(self.ptr, arena, payload, events);
}

pub fn finish(self: Dialect, arena: std.mem.Allocator, events: *Events) error{OutOfMemory}!void {
    return self.vtable.finish(self.ptr, arena, events);
}

pub fn encodeProof(
    comptime Stored: type,
    arena: std.mem.Allocator,
    account: []const u8,
    stored: *const Stored,
) error{OutOfMemory}!core.Conversation.Proof {
    return .{
        .account = account,
        .payload = try std.json.Stringify.valueAlloc(arena, stored.*, .{}),
    };
}

pub fn decodeProof(
    comptime Stored: type,
    arena: std.mem.Allocator,
    account: []const u8,
    proof: *const core.Conversation.Proof,
) error{OutOfMemory}!?Stored {
    if (!std.mem.eql(u8, proof.account, account)) return null;
    return std.json.parseFromSliceLeaky(Stored, arena, proof.payload, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

pub fn reason(status: std.http.Status) core.Provider.Failure.Reason {
    return switch (status) {
        .unauthorized => .unauthorized,
        .payment_required => .quota_exhausted,
        .request_timeout => .network,
        .too_many_requests => .rate_limited,
        else => if (@divFloor(@backingInt(status), 100) == 5) .overloaded else .invalid_request,
    };
}

fn describe(
    arena: std.mem.Allocator,
    status: std.http.Status,
    detail: []const u8,
) error{OutOfMemory}![]const u8 {
    const phrase = status.phrase() orelse "";
    return arena.print("{d}{s}{s}{s}{s}", .{
        @backingInt(status),
        if (phrase.len == 0) "" else " ",
        phrase,
        if (detail.len == 0) "" else ": ",
        detail,
    });
}

test "a reply fails with its first rejection that a retry cannot clear, or else as invalid" {
    const unsupported = "The reply holds content that Drinky cannot keep.";
    const uncorrelated = "The stream named a block other than the open one.";
    const cases = [_]struct {
        rejections: []const Rejection,
        reason: core.Provider.Failure.Reason,
        message: []const u8,
    }{
        .{ .rejections = &.{ .invalid, .invalid }, .reason = .invalid_reply, .message = "" },
        .{
            .rejections = &.{ .invalid, .unsupported, .invalid },
            .reason = .unsupported_reply,
            .message = unsupported,
        },
        .{
            .rejections = &.{ .invalid, .uncorrelated, .unsupported, .invalid },
            .reason = .unsupported_reply,
            .message = uncorrelated,
        },
        .{
            .rejections = &.{ .unsupported, .uncorrelated },
            .reason = .unsupported_reply,
            .message = unsupported,
        },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        var reply: Reply = .{};
        for (case.rejections) |rejection| reply.reject(rejection);
        var events: Events = .empty;
        try reply.end(arena.allocator(), &events, .complete);
        try std.testing.expectEqual(@as(usize, 1), events.items.len);
        const failed = events.items[0].failed;
        try std.testing.expectEqual(case.reason, failed.reason);
        try std.testing.expectEqualStrings(case.message, failed.message);
    }
}

test "a head status maps to the failure reason of the core" {
    const cases = [_]struct { status: std.http.Status, reason: core.Provider.Failure.Reason }{
        .{ .status = .unauthorized, .reason = .unauthorized },
        .{ .status = .payment_required, .reason = .quota_exhausted },
        .{ .status = .request_timeout, .reason = .network },
        .{ .status = .too_many_requests, .reason = .rate_limited },
        .{ .status = .internal_server_error, .reason = .overloaded },
        .{ .status = @fromBackingInt(529), .reason = .overloaded },
        .{ .status = .forbidden, .reason = .invalid_request },
        .{ .status = .bad_request, .reason = .invalid_request },
        .{ .status = @fromBackingInt(999), .reason = .invalid_request },
    };
    for (cases) |case| try std.testing.expectEqual(case.reason, reason(case.status));
}

test "describe names the status, its phrase, and the detail that exists" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings(
        "429 Too Many Requests: too slow",
        try describe(allocator, .too_many_requests, "too slow"),
    );
    try std.testing.expectEqualStrings(
        "429 Too Many Requests",
        try describe(allocator, .too_many_requests, ""),
    );
    try std.testing.expectEqualStrings(
        "999: raw",
        try describe(allocator, @fromBackingInt(999), "raw"),
    );
}
