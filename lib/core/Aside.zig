const std = @import("std");

const Conversation = @import("Conversation.zig");
const fatal = @import("fatal.zig");
const Provider = @import("Provider.zig");
const Session = @import("Session.zig");
const timeout = @import("timeout.zig");

const Aside = @This();

gpa: std.mem.Allocator,
io: std.Io,
options: Session.Options,
setup: *const Session.Setup,
request: *const Request,
conversation: *const Conversation,
turn_starts: []const Session.TurnStart,

pub const Request = struct {
    system: []const u8,
    text: []const u8,
    include_dialogue: bool = false,

    pub fn dupe(self: *const Request, gpa: std.mem.Allocator) error{OutOfMemory}!Request {
        const system = try gpa.dupe(u8, self.system);
        errdefer gpa.free(system);
        return .{
            .system = system,
            .text = try gpa.dupe(u8, self.text),
            .include_dialogue = self.include_dialogue,
        };
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
    const items = self.requestItems() catch fatal.outOfMemory();
    defer self.gpa.free(items);
    const setup = self.setup;
    const request: Provider.Request = .{
        .model = setup.model,
        .system = self.request.system,
        .items = items,
        .tools = &.{},
        .tokens_max = setup.tokens_max,
        .effort = setup.effort,
        .cache_key = "",
    };
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        var shown = false;
        const failure = switch (self.reply(&shown, &request)) {
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

fn requestItems(self: *const Aside) error{OutOfMemory}![]Conversation.Item {
    var items: std.ArrayList(Conversation.Item) = .empty;
    errdefer items.deinit(self.gpa);
    if (self.request.include_dialogue) {
        const history = self.conversation.items.items;
        for (self.turn_starts, 0..) |turn_start, index| {
            const end = if (index + 1 < self.turn_starts.len)
                self.turn_starts[index + 1].item
            else
                history.len;
            const prompt = history[turn_start.item];
            std.debug.assert(prompt == .message and prompt.message.role == .user);
            try items.append(self.gpa, prompt);
            const rounds = history[turn_start.item + 1 .. end];
            for (rounds[answerStart(rounds)..]) |item| {
                if (item == .message) try items.append(self.gpa, item);
            }
        }
    }
    try items.append(self.gpa, .{ .message = .{ .role = .user, .text = self.request.text } });
    return items.toOwnedSlice(self.gpa);
}

fn answerStart(items: []const Conversation.Item) usize {
    for (0..items.len) |offset| {
        const index = items.len - offset;
        switch (items[index - 1]) {
            .message => |message| if (message.role == .user) return index,
            .reasoning => {},
            .tool_call, .tool_result => return index,
        }
    }
    return 0;
}

fn reply(self: *const Aside, shown: *bool, request: *const Provider.Request) Reply {
    const provider = self.setup.provider;
    provider.open(request) catch |err| return switch (err) {
        error.Canceled => .canceled,
        error.OutOfMemory => fatal.outOfMemory(),
    };
    defer provider.close();
    var maybe_usage: ?Provider.Usage = null;
    defer if (maybe_usage) |usage| self.emit(&.{ .usage = usage });
    var streamed = false;
    var has_content = false;
    for (0..Provider.reply_events_max) |_| {
        const maybe_event = provider.next() catch |err| return switch (err) {
            error.Canceled => .canceled,
            error.OutOfMemory => fatal.outOfMemory(),
        };
        const event = maybe_event orelse return .{ .failed = .{ .reason = .invalid_reply } };
        switch (event) {
            .text => |delta| {
                streamed = true;
                has_content = self.show(shown, delta) or has_content;
            },
            .output => |*output| switch (output.*) {
                .message => |text| {
                    if (!streamed) has_content = self.show(shown, text) or has_content;
                    streamed = false;
                },
                .reasoning, .tool_call => {},
            },
            .reasoning => |delta| self.emit(&.{ .aside_reasoning = delta }),
            .usage => |usage| maybe_usage = usage,
            .quota => |quota| self.emit(&.{ .quota = quota }),
            .credits => |credits| self.emit(&.{ .credits = credits }),
            .stopped => |stop| {
                if (!has_content) return .{ .failed = .{ .reason = .empty_reply } };
                return .{ .stopped = stop.reason };
            },
            .failed => |*failure| return .{
                .failed = failure.dupe(self.gpa) catch fatal.outOfMemory(),
            },
            .reasoning_started, .tool_call_started, .tool_call_arguments => {},
        }
    }
    return .{ .failed = .{ .reason = .invalid_reply } };
}

fn show(self: *const Aside, shown: *bool, text: []const u8) bool {
    if (text.len == 0) return false;
    shown.* = true;
    self.emit(&.{ .aside_text = text });
    return std.mem.findNone(u8, text, " \t\r\n") != null;
}

fn emit(self: *const Aside, event: *const Session.Event) void {
    self.options.sink.emit(self.io, event);
}
