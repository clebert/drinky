const std = @import("std");

const Conversation = @import("Conversation.zig");
const Provider = @import("Provider.zig");
const Session = @import("Session.zig");
const timeout = @import("timeout.zig");

const Aside = @This();

gpa: std.mem.Allocator,
io: std.Io,
options: Session.Options,
setup: *const Session.Setup,
request: *const Request,

pub const Request = struct {
    system: []const u8,
    text: []const u8,
    effort: ?Provider.Effort,

    pub fn dupe(self: *const Request, gpa: std.mem.Allocator) error{OutOfMemory}!Request {
        const system = try gpa.dupe(u8, self.system);
        errdefer gpa.free(system);
        return .{ .system = system, .text = try gpa.dupe(u8, self.text), .effort = self.effort };
    }

    pub fn deinit(self: *const Request, gpa: std.mem.Allocator) void {
        gpa.free(self.system);
        gpa.free(self.text);
    }
};

const Reply = union(enum) {
    stopped: Provider.Stop.Reason,
    canceled,
    failed: Provider.Failure,
};

pub fn run(self: *const Aside) Session.Outcome {
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        var shown = false;
        const failure = switch (self.reply(&shown)) {
            .stopped => |reason| return .{ .stopped = reason },
            .canceled => return .canceled,
            .failed => |failure| failure,
        };
        if (shown) return .{ .failed = failure };
        const delay_ms = self.options.retry.delay(attempt, &failure) orelse
            return .{ .failed = failure };
        self.emit(&.{ .aside_attempt_failed = .{
            .attempt = attempt,
            .failure = failure,
            .delay_ms = delay_ms,
        } });
        failure.deinit(self.gpa);
        timeout.sleep(self.io, delay_ms) catch return .canceled;
    }
}

fn reply(self: *const Aside, shown: *bool) Reply {
    const setup = self.setup;
    const items = [_]Conversation.Item{
        .{ .message = .{ .role = .user, .text = self.request.text } },
    };
    const request: Provider.Request = .{
        .model = setup.model,
        .system = self.request.system,
        .items = &items,
        .tools = &.{},
        .tokens_max = setup.tokens_max,
        .effort = self.request.effort,
        .cache_key = "",
    };
    setup.provider.open(&request) catch |err| return switch (err) {
        error.Canceled => .canceled,
        error.OutOfMemory => .{ .failed = .{ .reason = .out_of_memory } },
    };
    defer setup.provider.close();
    var maybe_usage: ?Provider.Usage = null;
    defer if (maybe_usage) |usage| self.emit(&.{ .usage = usage });
    var streamed = false;
    for (0..Provider.reply_events_max) |_| {
        const maybe_event = setup.provider.next() catch |err| return switch (err) {
            error.Canceled => .canceled,
            error.OutOfMemory => .{ .failed = .{ .reason = .out_of_memory } },
        };
        const event = maybe_event orelse return .{ .failed = .{ .reason = .invalid_reply } };
        switch (event) {
            .text => |delta| {
                streamed = true;
                self.show(shown, delta);
            },
            .output => |*output| switch (output.*) {
                .message => |text| {
                    if (!streamed) self.show(shown, text);
                    streamed = false;
                },
                .reasoning, .tool_call => {},
            },
            .usage => |usage| maybe_usage = usage,
            .quota => |quota| self.emit(&.{ .quota = quota }),
            .credits => |credits| self.emit(&.{ .credits = credits }),
            .stopped => |stop| {
                if (!shown.*) return .{ .failed = .{ .reason = .empty_reply } };
                return .{ .stopped = stop.reason };
            },
            .failed => |*failure| return .{ .failed = failure.dupe(self.gpa) },
            .reasoning_started, .reasoning, .tool_call_started, .tool_call_arguments => {},
        }
    }
    return .{ .failed = .{ .reason = .invalid_reply } };
}

fn show(self: *const Aside, shown: *bool, text: []const u8) void {
    if (text.len == 0) return;
    shown.* = true;
    self.emit(&.{ .aside_text = text });
}

fn emit(self: *const Aside, event: *const Session.Event) void {
    self.options.sink.emit(self.io, event);
}
