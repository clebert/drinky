const std = @import("std");

const Conversation = @import("Conversation.zig");
const Tool = @import("Tool.zig");

const Provider = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    open: *const fn (ptr: *anyopaque, request: *const Request) Error!void,
    next: *const fn (ptr: *anyopaque) Error!?Event,
    close: *const fn (ptr: *anyopaque) void,
};

pub const Error = error{ Canceled, OutOfMemory };

pub const amount_usd_max: f64 = 1_000_000_000;

pub const Effort = enum { low, medium, high, xhigh, max };

pub const Request = struct {
    model: []const u8,
    system: []const u8,
    items: []const Conversation.Item,
    tools: []const Tool,
    tokens_max: ?u32,
    effort: ?Effort,
    cache_key: []const u8,
};

pub const Event = union(enum) {
    text: []const u8,
    reasoning_started,
    reasoning: []const u8,
    tool_call_started: []const u8,
    tool_call_arguments: []const u8,
    output: Output,
    usage: Usage,
    quota: Quota,
    credits: Credits,
    stopped: Stop,
    failed: Failure,
};

pub const Output = union(enum) {
    message: []const u8,
    reasoning: Conversation.Proof,
    tool_call: Tool.Call,
};

pub const Stop = struct {
    reason: Reason = .complete,
    model: []const u8 = "",

    pub const Reason = enum { complete, truncated };
};

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    cost_usd: ?f64 = null,

    pub fn total(self: *const Usage) u64 {
        return self.input +| self.output +| self.cache_read +| self.cache_write;
    }

    pub fn prompt(self: *const Usage) u64 {
        return self.input +| self.cache_read +| self.cache_write;
    }
};

pub const Quota = struct {
    primary: ?Window = null,
    secondary: ?Window = null,

    pub const Window = struct {
        used_percent: f64,
        window_minutes: ?u32 = null,
        reset_seconds: ?u64 = null,

        pub fn usedPercent(percent: f64) ?f64 {
            if (!std.math.isFinite(percent) or percent < 0) return null;
            return @min(100.0, percent);
        }
    };
};

pub const Credits = struct {
    total: f64,
    used: f64,

    pub fn remaining(self: Credits) f64 {
        return @max(0.0, self.total - self.used);
    }
};

pub const Failure = struct {
    reason: Reason,
    retry_after_ms: ?u64 = null,
    message: []const u8 = "",

    pub const Reason = enum {
        unauthorized,
        rate_limited,
        quota_exhausted,
        overloaded,
        invalid_request,
        context_overflow,
        network,
        invalid_reply,
        empty_reply,
        unsupported_reply,
        too_many_tool_calls,
        out_of_memory,
    };

    pub fn dupe(self: *const Failure, gpa: std.mem.Allocator) Failure {
        return .{
            .reason = self.reason,
            .retry_after_ms = self.retry_after_ms,
            .message = gpa.dupe(u8, self.message) catch "",
        };
    }

    pub fn deinit(self: *const Failure, gpa: std.mem.Allocator) void {
        gpa.free(self.message);
    }
};

pub fn open(self: Provider, request: *const Request) Error!void {
    return self.vtable.open(self.ptr, request);
}

pub fn next(self: Provider) Error!?Event {
    return self.vtable.next(self.ptr);
}

pub fn close(self: Provider) void {
    self.vtable.close(self.ptr);
}

test "the context measurement adds every token of a request and its reply" {
    const usage: Usage = .{ .input = 10, .output = 5, .cache_read = 90, .cache_write = 3 };
    try std.testing.expectEqual(@as(u64, 108), usage.total());
    try std.testing.expectEqual(@as(u64, 103), usage.prompt());

    const huge: Usage = .{ .input = std.math.maxInt(u64), .cache_read = 1 };
    try std.testing.expectEqual(std.math.maxInt(u64), huge.total());
    try std.testing.expectEqual(std.math.maxInt(u64), huge.prompt());
}

test "a used percent is a finite share that is not negative and caps at 100" {
    try std.testing.expectEqual(@as(?f64, 42.5), Quota.Window.usedPercent(42.5));
    try std.testing.expectEqual(@as(?f64, 0), Quota.Window.usedPercent(0));
    try std.testing.expectEqual(@as(?f64, 100), Quota.Window.usedPercent(250));
    try std.testing.expectEqual(@as(?f64, null), Quota.Window.usedPercent(-1));
    try std.testing.expectEqual(@as(?f64, null), Quota.Window.usedPercent(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?f64, null), Quota.Window.usedPercent(std.math.inf(f64)));
}

test "a credit pool never reports a negative remainder" {
    try std.testing.expectEqual(@as(f64, 7.5), (Credits{ .total = 10, .used = 2.5 }).remaining());
    try std.testing.expectEqual(@as(f64, 0), (Credits{ .total = 1, .used = 2 }).remaining());
}
