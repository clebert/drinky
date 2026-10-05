const std = @import("std");

const actor = @import("actor.zig");
const Conversation = @import("Conversation.zig");
const Provider = @import("Provider.zig");
const Retry = @import("Retry.zig");
const Runner = @import("Runner.zig");
const testing = @import("testing.zig");
const Tool = @import("Tool.zig");
const Turn = @import("Turn.zig");

const Session = @This();

const mail_capacity: usize = 64;

gpa: std.mem.Allocator,
io: std.Io,
options: Options,
conversation: Conversation,
turn_start: ?usize,
setup: ?Setup,
next_setup: ?Setup,
clear_pending: bool,
measured: ?Turn.Measured,
mailbox: actor.Mailbox(Mail, mail_capacity),
loop: ?std.Io.Future(void),

pub const Options = struct {
    sink: Sink,
    runner: Runner,
    tools: []const Tool,
    retry: Retry = .{},
};

pub const Sink = actor.Sink(Event);

pub const Setup = struct {
    provider: Provider,
    account: []const u8,
    model: []const u8,
    effort: ?Provider.Effort,
    tokens_max: ?u32,
    system: []const u8,

    fn dupe(self: *const Setup, gpa: std.mem.Allocator) error{OutOfMemory}!Setup {
        const account = try gpa.dupe(u8, self.account);
        errdefer gpa.free(account);
        const model = try gpa.dupe(u8, self.model);
        errdefer gpa.free(model);
        return .{
            .provider = self.provider,
            .account = account,
            .model = model,
            .effort = self.effort,
            .tokens_max = self.tokens_max,
            .system = try gpa.dupe(u8, self.system),
        };
    }

    fn deinit(self: *const Setup, gpa: std.mem.Allocator) void {
        gpa.free(self.account);
        gpa.free(self.model);
        gpa.free(self.system);
    }
};

pub const Command = union(enum) {
    prompt: []const u8,
    cancel,
    configure: Setup,
    clear,
    remove_turn,

    fn dupe(self: *const Command, gpa: std.mem.Allocator) error{OutOfMemory}!Command {
        return switch (self.*) {
            .prompt => |text| .{ .prompt = try gpa.dupe(u8, text) },
            .configure => |*setup| .{ .configure = try setup.dupe(gpa) },
            .cancel, .clear, .remove_turn => self.*,
        };
    }

    fn deinit(self: *const Command, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .prompt => |text| gpa.free(text),
            .configure => |*setup| setup.deinit(gpa),
            .cancel, .clear, .remove_turn => {},
        }
    }
};

pub const Event = union(enum) {
    setup_dropped: Provider,
    text_started,
    text: []const u8,
    reasoning_started,
    reasoning: []const u8,
    tool_call_started: []const u8,
    tool_call_arguments: []const u8,
    tool_started: Tool.Call,
    tool_result: ToolResult,
    committed,
    tail_discarded: usize,
    usage: Provider.Usage,
    quota: Provider.Quota,
    credits: Provider.Credits,
    context: ?u64,
    model_served: ModelServed,
    attempt_failed: Attempt,
    skill_loaded: SkillLoaded,
    turn_ended: Outcome,

    pub const ToolResult = struct {
        call: Tool.Call,
        output: Tool.Output,
    };

    pub const ModelServed = struct {
        requested: []const u8,
        served: []const u8,
    };

    pub const Attempt = struct {
        attempt: u32,
        failure: Provider.Failure,
        delay_ms: u64,
    };

    pub const SkillLoaded = struct {
        name: []const u8,
        source: []const u8,
    };

    pub fn dupe(self: *const Event, gpa: std.mem.Allocator) error{OutOfMemory}!Event {
        return switch (self.*) {
            .text => |delta| .{ .text = try gpa.dupe(u8, delta) },
            .reasoning => |delta| .{ .reasoning = try gpa.dupe(u8, delta) },
            .tool_call_started => |name| .{ .tool_call_started = try gpa.dupe(u8, name) },
            .tool_call_arguments => |delta| .{ .tool_call_arguments = try gpa.dupe(u8, delta) },
            .tool_started => |*call| .{ .tool_started = try call.dupe(gpa) },
            .tool_result => |*result| {
                const call = try result.call.dupe(gpa);
                errdefer call.deinit(gpa);
                return .{ .tool_result = .{ .call = call, .output = try result.output.dupe(gpa) } };
            },
            .model_served => |served| {
                const requested = try gpa.dupe(u8, served.requested);
                errdefer gpa.free(requested);
                return .{ .model_served = .{
                    .requested = requested,
                    .served = try gpa.dupe(u8, served.served),
                } };
            },
            .attempt_failed => |*attempt| .{ .attempt_failed = .{
                .attempt = attempt.attempt,
                .failure = attempt.failure.dupe(gpa),
                .delay_ms = attempt.delay_ms,
            } },
            .skill_loaded => |skill| {
                const name = try gpa.dupe(u8, skill.name);
                errdefer gpa.free(name);
                return .{ .skill_loaded = .{
                    .name = name,
                    .source = try gpa.dupe(u8, skill.source),
                } };
            },
            .turn_ended => |*outcome| .{ .turn_ended = outcome.dupe(gpa) },
            .setup_dropped,
            .text_started,
            .reasoning_started,
            .committed,
            .tail_discarded,
            .usage,
            .quota,
            .credits,
            .context,
            => self.*,
        };
    }

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text, .reasoning, .tool_call_started, .tool_call_arguments => |bytes| gpa.free(bytes),
            .tool_started => |*call| call.deinit(gpa),
            .tool_result => |*result| {
                result.call.deinit(gpa);
                result.output.deinit(gpa);
            },
            .model_served => |served| {
                gpa.free(served.requested);
                gpa.free(served.served);
            },
            .attempt_failed => |*attempt| attempt.failure.deinit(gpa),
            .skill_loaded => |skill| {
                gpa.free(skill.name);
                gpa.free(skill.source);
            },
            .turn_ended => |*outcome| outcome.deinit(gpa),
            .setup_dropped,
            .text_started,
            .reasoning_started,
            .committed,
            .tail_discarded,
            .usage,
            .quota,
            .credits,
            .context,
            => {},
        }
    }
};

pub const Outcome = union(enum) {
    stopped: Provider.Stop.Reason,
    canceled,
    exhausted,
    failed: Provider.Failure,

    pub fn dupe(self: *const Outcome, gpa: std.mem.Allocator) Outcome {
        return switch (self.*) {
            .failed => |*failure| .{ .failed = failure.dupe(gpa) },
            .stopped, .canceled, .exhausted => self.*,
        };
    }

    pub fn deinit(self: *const Outcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .failed => |*failure| failure.deinit(gpa),
            .stopped, .canceled, .exhausted => {},
        }
    }
};

const Mail = union(enum) {
    command: Command,
    ended: Turn.End,

    pub fn deinit(self: *const Mail, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .command => |*command| command.deinit(gpa),
            .ended => |*ended| ended.deinit(gpa),
        }
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: *const Options) Session {
    return .{
        .gpa = gpa,
        .io = io,
        .options = options.*,
        .conversation = .init(io),
        .turn_start = null,
        .setup = null,
        .next_setup = null,
        .clear_pending = false,
        .measured = null,
        .mailbox = .init,
        .loop = null,
    };
}

pub fn start(self: *Session) std.Io.ConcurrentError!void {
    self.loop = try self.io.concurrent(run, .{self});
}

pub fn deinit(self: *Session) void {
    if (self.loop) |*loop| loop.cancel(self.io);
    self.loop = null;
    self.mailbox.close(self.io);
    self.mailbox.drain(self.io, self.gpa);
    if (self.setup) |*setup| setup.deinit(self.gpa);
    if (self.next_setup) |*setup| setup.deinit(self.gpa);
    if (self.measured) |*measured| measured.deinit(self.gpa);
    self.conversation.deinit(self.gpa);
}

pub fn send(self: *Session, command: *const Command) error{OutOfMemory}!void {
    const mail: Mail = .{ .command = try command.dupe(self.gpa) };
    self.mailbox.send(self.io, mail) catch mail.deinit(self.gpa);
}

fn run(self: *Session) void {
    self.serve() catch {};
    self.mailbox.cancel(self.io);
    self.mailbox.reap(self.io);
    self.mailbox.drain(self.io, self.gpa);
}

fn serve(self: *Session) actor.Mailbox(Mail, mail_capacity).Error!void {
    while (true) {
        switch (try self.mailbox.receive(self.io)) {
            .command => |command| self.handle(command),
            .ended => |ended| self.end(ended),
        }
    }
}

fn handle(self: *Session, command: Command) void {
    switch (command) {
        .prompt => |text| self.prompt(text),
        .cancel => self.mailbox.cancel(self.io),
        .configure => |setup| self.configure(setup),
        .clear => self.requestClear(),
        .remove_turn => self.removeTurn(),
    }
}

fn prompt(self: *Session, text: []const u8) void {
    std.debug.assert(!self.mailbox.busy());
    std.debug.assert(self.setup != null);
    self.conversation.append(self.gpa, .{ .message = .{ .role = .user, .text = text } }) catch {
        self.gpa.free(text);
        self.emit(&.{ .turn_ended = .{ .failed = .{ .reason = .out_of_memory } } });
        return;
    };
    self.turn_start = self.conversation.items.items.len - 1;
    const turn: Turn = .{
        .gpa = self.gpa,
        .io = self.io,
        .options = self.options,
        .conversation = &self.conversation,
        .setup = &self.setup.?,
        .measured = null,
    };
    self.mailbox.start(self.io, runTurn, .{turn}) catch
        self.emit(&.{ .turn_ended = .{ .failed = .{ .reason = .out_of_memory } } });
}

fn runTurn(lent: Turn) Mail {
    var turn = lent;
    return .{ .ended = turn.run() };
}

fn configure(self: *Session, setup: Setup) void {
    if (!self.mailbox.busy()) return self.apply(setup);
    if (self.next_setup) |*previous| self.drop(previous);
    self.next_setup = setup;
}

fn requestClear(self: *Session) void {
    if (!self.mailbox.busy()) return self.clear();
    self.clear_pending = true;
}

fn apply(self: *Session, setup: Setup) void {
    const maybe_previous = self.setup;
    self.setup = setup;
    if (maybe_previous) |*previous| self.drop(previous);
    self.emit(&.{ .context = self.contextShown() });
}

fn drop(self: *Session, setup: *const Setup) void {
    const provider = setup.provider;
    setup.deinit(self.gpa);
    self.emit(&.{ .setup_dropped = provider });
}

fn clear(self: *Session) void {
    self.conversation.clear(self.gpa, self.io);
    self.turn_start = null;
    self.forgetMeasured();
    self.options.runner.reset();
    self.emit(&.{ .context = 0 });
}

fn removeTurn(self: *Session) void {
    std.debug.assert(!self.mailbox.busy());
    self.conversation.truncate(self.gpa, self.turn_start.?);
    self.turn_start = null;
    self.forgetMeasured();
    self.options.runner.reset();
    self.emit(&.{ .context = self.contextShown() });
}

fn forgetMeasured(self: *Session) void {
    if (self.measured) |*measured| measured.deinit(self.gpa);
    self.measured = null;
}

fn end(self: *Session, ended: Turn.End) void {
    self.mailbox.reap(self.io);
    if (ended.measured) |measured| {
        if (self.measured) |*previous| previous.deinit(self.gpa);
        self.measured = measured;
    }
    if (self.next_setup) |setup| {
        self.next_setup = null;
        self.apply(setup);
    }
    if (self.clear_pending) {
        self.clear_pending = false;
        self.clear();
    }
    self.emit(&.{ .turn_ended = ended.outcome });
    ended.outcome.deinit(self.gpa);
}

fn contextShown(self: *const Session) ?u64 {
    if (self.conversation.items.items.len == 0) return 0;
    const measured = self.measured orelse return null;
    const setup = self.setup orelse return null;
    return if (measured.matches(&setup)) measured.tokens else null;
}

fn emit(self: *Session, event: *const Event) void {
    self.options.sink.emit(self.io, event);
}

test "a turn streams the reply and keeps what the model completed" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .reasoning_started,
            .{ .reasoning = "Read the file" },
            .{ .output = .{ .reasoning = fixture.proof } },
            .{ .text = "I read " },
            .{ .text = "the file." },
            fixture.message("I read the file."),
            .{ .usage = .{ .input = 1200, .output = 48, .cache_read = 1000 } },
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\reasoning_started
        \\reasoning:Read the file
        \\text_started
        \\text:I read 
        \\text:the file.
        \\usage:1200/48/1000/0
        \\context:2248
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|reasoning:account-a:p1|assistant:I read the file.|user:next",
        harness.provider.requests.items[1],
    );
}

const fixture = struct {
    const proof: Conversation.Proof = .{ .account = "account-a", .payload = "p1" };
    const call: Tool.Call = .{ .id = "c1", .name = "read", .arguments = "{\"path\":\"a.txt\"}" };
    const next_call: Tool.Call = .{
        .id = "c2",
        .name = "read",
        .arguments = "{\"path\":\"b.txt\"}",
    };
    const write_call: Tool.Call = .{ .id = "w1", .name = "write", .arguments = "{}" };
    const stop_complete: Provider.Event = .{ .stopped = .{} };

    fn message(text: []const u8) Provider.Event {
        return .{ .output = .{ .message = text } };
    }

    fn toolCall(value: Tool.Call) Provider.Event {
        return .{ .output = .{ .tool_call = value } };
    }

    fn readCalls(
        comptime count: usize,
        ids: *[count][8]u8,
        events: *[count + 1]Provider.Event,
    ) void {
        for (0..count) |index| {
            const id = std.fmt.bufPrint(&ids[index], "r{d}", .{index}) catch unreachable;
            events[index] = toolCall(.{ .id = id, .name = "read", .arguments = "{}" });
        }
        events[count] = stop_complete;
    }
};

test "a tool call runs, its result joins the conversation, and the next reply follows" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .tool_call_started = "read" },
            .{ .tool_call_arguments = "{\"path\":\"a.txt\"}" },
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{
            .{ .text = "I read the file." },
            fixture.message("I read the file."),
            fixture.stop_complete,
        } },
    });
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tool_call_arguments:{"path":"a.txt"}
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:I read the file.
        \\committed
        \\turn_ended:complete
    , try harness.turn("read a.txt"));
    try std.testing.expectEqual(@as(usize, 2), harness.provider.requests.items.len);
    try std.testing.expectEqualStrings(
        "model-a|user:read a.txt|call:c1:read:{\"path\":\"a.txt\"}|result:c1:done",
        harness.provider.requests.items[1],
    );
    try std.testing.expectEqual(@as(usize, 1), harness.runner.calls.items.len);
    try std.testing.expectEqualStrings("read:{\"path\":\"a.txt\"}", harness.runner.calls.items[0]);
    try std.testing.expectEqual(@as(usize, 1), harness.runner.history_items);
}

test "a reply that completes no message keeps its text before the tool call" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .text = "I look first." },
            .{ .tool_call_started = "read" },
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("I read the file."), fixture.stop_complete } },
    });
    _ = try harness.turn("hi");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|assistant:I look first.|call:c1:read:{\"path\":\"a.txt\"}|result:c1:done",
        harness.provider.requests.items[1],
    );
}

test "a canceled turn keeps the partial answer on the screen and in the conversation" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .open = &.{
            .reasoning_started,
            .{ .reasoning = "Read the file" },
            .{ .output = .{ .reasoning = fixture.proof } },
            .{ .text = "I read " },
            .{ .usage = .{ .input = 1200 } },
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try harness.prompt("hi");
    try harness.expect("reasoning_started");
    try harness.expect("reasoning:Read the file");
    try harness.expect("text_started");
    try harness.expect("text:I read ");
    try harness.expect("usage:1200/0/0/0");
    try harness.session.send(&.cancel);
    try std.testing.expectEqualStrings(
        \\committed
        \\turn_ended:canceled
    , try harness.until("turn_ended"));
    try std.testing.expectEqual(@as(u32, 1), harness.provider.canceled);
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|reasoning:account-a:p1|assistant:I read |user:next",
        harness.provider.requests.items[1],
    );
}

test "a cut reasoning block leaves the screen and the conversation with the block before it" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .open = &.{
            .reasoning_started,
            .{ .reasoning = "First" },
            .{ .output = .{ .reasoning = fixture.proof } },
            .reasoning_started,
            .{ .reasoning = "Second" },
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try harness.prompt("hi");
    try harness.expect("reasoning_started");
    try harness.expect("reasoning:First");
    try harness.expect("reasoning_started");
    try harness.expect("reasoning:Second");
    try harness.session.send(&.cancel);
    try std.testing.expectEqualStrings(
        \\tail_discarded:2
        \\turn_ended:canceled
    , try harness.until("turn_ended"));
    try std.testing.expectEqual(@as(u32, 1), harness.provider.canceled);
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|user:next",
        harness.provider.requests.items[1],
    );
}

test "a cancel while a tool call runs leaves the next call unanswered" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .tool_call_started = "write" },
            fixture.toolCall(fixture.write_call),
            .{ .tool_call_started = "read" },
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    harness.runner.hook = .{ .session = &harness.session, .command = .cancel };
    try std.testing.expectEqualStrings(
        \\tool_call_started:write
        \\tool_call_started:read
        \\tool_started:w1
        \\tool_result:w1:done
        \\tail_discarded:1
        \\committed
        \\turn_ended:canceled
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(u32, 1), harness.runner.canceled);
    try std.testing.expectEqual(@as(usize, 1), harness.runner.calls.items.len);
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|call:w1:write:{}|result:w1:done|user:next",
        harness.provider.requests.items[1],
    );
}

test "a cancel ends a running read-only call, and the call stays unanswered" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .tool_call_started = "read" },
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    harness.runner.hook = .{
        .session = &harness.session,
        .command = .cancel,
        .after_cancel = .fail,
    };
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tool_started:c1
        \\tail_discarded:1
        \\turn_ended:canceled
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(u32, 1), harness.runner.canceled);
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|user:next",
        harness.provider.requests.items[1],
    );
}

test "a reasoning item with no output item behind it never enters the conversation" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .text = "ok" },
            fixture.message("ok"),
            .reasoning_started,
            .{ .reasoning = "afterthought" },
            .{ .output = .{ .reasoning = fixture.proof } },
            fixture.stop_complete,
        } },
        .{ .done = &.{
            .reasoning_started,
            .{ .output = .{ .reasoning = fixture.proof } },
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:ok
        \\reasoning_started
        \\reasoning:afterthought
        \\tail_discarded:1
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
    try std.testing.expectEqualStrings(
        \\reasoning_started
        \\tail_discarded:1
        \\turn_ended:failed:empty_reply:
    , try harness.turn("again"));
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|assistant:ok|user:again|user:next",
        harness.provider.requests.items[2],
    );
}

test "a rejected attempt discards its tail, waits, repeats the request, and leaves no item" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{
        .retry = .{ .attempts_max = 3, .backoff = .{ .delay_ms_initial = 0, .delay_ms_max = 0 } },
    });
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .text = "I read " },
            .{ .failed = .{ .reason = .overloaded, .message = "The model is busy." } },
        } },
        .{ .done = &.{
            .{ .text = "I read the file." },
            fixture.message("I read the file."),
            fixture.stop_complete,
        } },
    });
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:I read 
        \\tail_discarded:1
        \\attempt_failed:1:overloaded:The model is busy.:0
        \\text_started
        \\text:I read the file.
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(usize, 2), harness.provider.requests.items.len);
    try std.testing.expectEqualStrings("model-a|user:hi", harness.provider.requests.items[0]);
    try std.testing.expectEqualStrings("model-a|user:hi", harness.provider.requests.items[1]);
}

test "the session reports every rejected attempt and ends with the last failure" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{
        .retry = .{ .attempts_max = 3, .backoff = .{ .delay_ms_initial = 0, .delay_ms_max = 0 } },
    });
    defer harness.deinit();

    const network: Provider.Event = .{ .failed = .{ .reason = .network } };
    harness.provider.load(&.{
        .{ .done = &.{network} },
        .{ .done = &.{network} },
        .{ .done = &.{network} },
    });
    try std.testing.expectEqualStrings(
        \\attempt_failed:1:network::0
        \\attempt_failed:2:network::0
        \\turn_ended:failed:network:
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(usize, 3), harness.provider.requests.items.len);
}

test "a failure that the policy allows no repeat ends the turn and keeps its text" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{
        .retry = .{ .attempts_max = 3, .backoff = .{ .delay_ms_initial = 0, .delay_ms_max = 0 } },
    });
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .text = "I read " },
            .{ .failed = .{
                .reason = .rate_limited,
                .retry_after_ms = 2_000,
                .message = "Rate limit reached.",
            } },
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:I read 
        \\committed
        \\turn_ended:failed:rate_limited:Rate limit reached.
    , try harness.turn("hi"));
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|assistant:I read |user:next",
        harness.provider.requests.items[1],
    );
}

test "a cancel that arrives during the wait ends the turn as canceled" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{
        .retry = .{
            .attempts_max = 3,
            .backoff = .{ .delay_ms_initial = 60_000, .delay_ms_max = 60_000 },
        },
    });
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{ .{ .text = "I read " }, .{ .failed = .{ .reason = .overloaded } } } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try harness.prompt("hi");
    try harness.expect("text_started");
    try harness.expect("text:I read ");
    try harness.expect("tail_discarded:1");
    try harness.expect("attempt_failed:1:overloaded::60000");
    try harness.session.send(&.cancel);
    try harness.expect("turn_ended:canceled");
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|user:next",
        harness.provider.requests.items[1],
    );
}

test "a setup that arrives during a turn applies from the next turn on" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{ fixture.toolCall(fixture.call), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("one"), fixture.stop_complete } },
    });
    harness.other.load(&.{
        .{ .done = &.{ fixture.message("two"), fixture.stop_complete } },
    });
    harness.runner.hook = .{
        .session = &harness.session,
        .command = .{ .configure = testing.Harness.setup(&harness.other, "model-c") },
    };
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:one
        \\committed
        \\setup_dropped
        \\context:none
        \\turn_ended:complete
    , try harness.turn("a"));
    _ = try harness.turn("b");
    try std.testing.expectEqual(@as(usize, 2), harness.provider.requests.items.len);
    try std.testing.expectEqualStrings(
        "model-c|user:a|call:c1:read:{\"path\":\"a.txt\"}|result:c1:done|assistant:one|user:b",
        harness.other.requests.items[0],
    );
}

test "a newer setup drops a deferred one at once, and the setup of the turn drops at its end" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{.{ .open = &.{.{ .text = "I read " }} }});
    harness.other.load(&.{.{ .done = &.{ fixture.message("ok"), fixture.stop_complete } }});
    try harness.prompt("first");
    try harness.expect("text_started");
    try harness.expect("text:I read ");
    try harness.configure(&harness.other, "model-b");
    try harness.configure(&harness.other, "model-c");
    try harness.expect("setup_dropped");
    try harness.session.send(&.cancel);
    try std.testing.expectEqualStrings(
        \\committed
        \\setup_dropped
        \\context:none
        \\turn_ended:canceled
    , try harness.until("turn_ended"));
    _ = try harness.turn("second");
    try std.testing.expectEqualStrings(
        "model-c|user:first|assistant:I read |user:second",
        harness.other.requests.items[0],
    );
}

test "a turn that calls a tool in every round ends when it uses its rounds" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    const calling = [_]Provider.Event{ fixture.toolCall(fixture.call), fixture.stop_complete };
    const answering = [_]Provider.Event{ fixture.message("ok"), fixture.stop_complete };
    var replies: [Turn.rounds_max + 1]testing.FakeProvider.Reply = undefined;
    @memset(replies[0..Turn.rounds_max], .{ .done = &calling });
    replies[Turn.rounds_max] = .{ .done = &answering };
    harness.provider.load(&replies);
    const ended = try harness.turn("hi");
    try std.testing.expect(std.mem.endsWith(u8, ended,
        \\committed
        \\tool_call_started:read
        \\tail_discarded:1
        \\turn_ended:exhausted
    ));
    try std.testing.expectEqual(Turn.rounds_max - 1, harness.runner.calls.items.len);
    _ = try harness.turn("next");
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.provider.requests.items[Turn.rounds_max],
        "|call:c1:read:{\"path\":\"a.txt\"}|result:c1:done|user:next",
    ));
}

test "a request carries the system text, the tools, the limit, and the effort of its setup" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{ fixture.message("one"), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("two"), fixture.stop_complete } },
    });
    _ = try harness.turn("a");
    var bare = testing.Harness.setup(&harness.provider, "model-a");
    bare.system = "Be brief.";
    bare.tokens_max = null;
    bare.effort = null;
    try harness.session.send(&.{ .configure = bare });
    try harness.expect("setup_dropped");
    try harness.expect("context:none");
    _ = try harness.turn("b");
    try std.testing.expectEqualStrings(
        "You are Drinky.|read,write|4096|high",
        harness.provider.settings.items[0],
    );
    try std.testing.expectEqualStrings(
        "Be brief.|read,write|none|none",
        harness.provider.settings.items[1],
    );
}

test "a quota and the credits of a reply reach the sink as they stream" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{.{ .done = &.{
        .{ .quota = .{ .primary = .{ .used_percent = 42 } } },
        .{ .credits = .{ .total = 10, .used = 4 } },
        fixture.message("ok"),
        fixture.stop_complete,
    } }});
    try std.testing.expectEqualStrings(
        \\quota:42
        \\credits:10/4
        \\text_started
        \\text:ok
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
}

test "a served model that differs from the request arrives with every reply" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    const served: Provider.Event = .{ .stopped = .{ .model = "model-b" } };
    harness.provider.load(&.{
        .{ .done = &.{ fixture.toolCall(fixture.call), served } },
        .{ .done = &.{ fixture.message("ok"), served } },
        .{ .done = &.{ fixture.message("ok"), .{ .stopped = .{ .model = "model-a" } } } },
    });
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\model_served:model-a>model-b
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:ok
        \\model_served:model-a>model-b
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:ok
        \\committed
        \\turn_ended:complete
    , try harness.turn("again"));
}

test "a reply that holds a tool call and did not complete fails as an invalid reply" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .tool_call_started = "read" },
            fixture.toolCall(fixture.call),
            .{ .stopped = .{ .reason = .truncated } },
        } },
        .{ .done = &.{
            .{ .text = "I read " },
            fixture.message("I read "),
            .{ .stopped = .{ .reason = .truncated } },
        } },
    });
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tail_discarded:1
        \\turn_ended:failed:invalid_reply:
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(usize, 0), harness.runner.calls.items.len);
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:I read 
        \\committed
        \\turn_ended:truncated
    , try harness.turn("again"));
    try std.testing.expectEqualStrings(
        "model-a|user:hi|user:again",
        harness.provider.requests.items[1],
    );
}

test "a reply without a stop fails as an invalid reply and keeps its text" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{.{ .text = "I read " }} },
        .{ .done = &.{ .{ .usage = .{ .input = 5 } }, fixture.stop_complete } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:I read 
        \\committed
        \\turn_ended:failed:invalid_reply:
    , try harness.turn("hi"));
    try std.testing.expectEqualStrings(
        \\usage:5/0/0/0
        \\turn_ended:failed:empty_reply:
    , try harness.turn("again"));
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|assistant:I read |user:again|user:next",
        harness.provider.requests.items[2],
    );
}

test "an empty message, an incomplete proof, or a bad tool call makes the reply invalid" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            fixture.toolCall(.{ .id = "", .name = "read", .arguments = "{}" }),
            fixture.stop_complete,
        } },
        .{ .done = &.{
            fixture.toolCall(fixture.call),
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{
            fixture.toolCall(.{ .id = "c1", .name = "read", .arguments = "[1]" }),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message(""), fixture.stop_complete } },
        .{ .done = &.{
            .{ .output = .{ .reasoning = .{ .account = "", .payload = "p1" } } },
            fixture.stop_complete,
        } },
        .{ .done = &.{
            .{ .output = .{ .reasoning = .{ .account = "account-a", .payload = "" } } },
            fixture.stop_complete,
        } },
        .{ .done = &.{
            fixture.toolCall(.{ .id = "c1", .name = "read", .arguments = "" }),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tail_discarded:1
        \\turn_ended:failed:invalid_reply:
    , try harness.turn("a"));
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tool_call_started:read
        \\tail_discarded:2
        \\turn_ended:failed:invalid_reply:
    , try harness.turn("b"));
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tail_discarded:1
        \\turn_ended:failed:invalid_reply:
    , try harness.turn("c"));
    try std.testing.expectEqualStrings(
        "turn_ended:failed:invalid_reply:",
        try harness.turn("empty"),
    );
    for ([_][]const u8{ "account", "payload" }) |text| {
        try std.testing.expectEqualStrings(
            \\reasoning_started
            \\tail_discarded:1
            \\turn_ended:failed:invalid_reply:
        , try harness.turn(text));
    }
    try std.testing.expectEqual(@as(usize, 0), harness.runner.calls.items.len);
    _ = try harness.turn("d");
    try std.testing.expectEqualStrings("read:{}", harness.runner.calls.items[0]);
    try std.testing.expectEqualStrings(
        "model-a|user:a|user:b|user:c|user:empty|user:account|user:payload|user:d" ++
            "|call:c1:read:{}|result:c1:done",
        harness.provider.requests.items[7],
    );
}

test "a reply past the tool call bound fails the turn at once" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    var ids: [Turn.tool_calls_max + 1][8]u8 = undefined;
    var events: [Turn.tool_calls_max + 2]Provider.Event = undefined;
    fixture.readCalls(Turn.tool_calls_max + 1, &ids, &events);
    harness.provider.load(&.{.{ .done = &events }});
    const log = try harness.turn("hi");
    try std.testing.expect(std.mem.endsWith(u8, log, std.fmt.comptimePrint(
        "tool_call_started:read\ntail_discarded:{d}\nturn_ended:failed:too_many_tool_calls:",
        .{Turn.tool_calls_max},
    )));
    try std.testing.expectEqual(@as(usize, 0), harness.runner.calls.items.len);
}

test "read-only calls of one reply run at once, and a mutating call is a barrier" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.runner.rendezvous = 2;
    harness.provider.load(&.{
        .{ .done = &.{
            fixture.toolCall(fixture.call),
            fixture.toolCall(fixture.next_call),
            fixture.toolCall(fixture.write_call),
            fixture.toolCall(.{ .id = "c3", .name = "read", .arguments = "{}" }),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tool_call_started:read
        \\tool_call_started:write
        \\tool_call_started:read
        \\tool_started:c1
        \\tool_started:c2
        \\tool_result:c1:done
        \\tool_result:c2:done
        \\tool_started:w1
        \\tool_result:w1:done
        \\tool_started:c3
        \\tool_result:c3:done
        \\committed
        \\text_started
        \\text:ok
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
    try std.testing.expect(!harness.runner.timed_out);
    try std.testing.expect(!harness.runner.overlap);
    try std.testing.expectEqual(@as(u32, 2), harness.runner.peak);
    try std.testing.expectEqualStrings("write:{}", harness.runner.calls.items[2]);
    try std.testing.expectEqualStrings("read:{}", harness.runner.calls.items[3]);
    try std.testing.expectEqualStrings(
        "model-a|user:hi|call:c1:read:{\"path\":\"a.txt\"}|call:c2:read:{\"path\":\"b.txt\"}|" ++
            "call:w1:write:{}|call:c3:read:{}|result:c1:done|result:c2:done|result:w1:done|" ++
            "result:c3:done",
        harness.provider.requests.items[1],
    );
}

test "a burst of read-only calls runs at most the bound at a time" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    const count = Turn.read_only_calls_max + 2;
    var ids: [count][8]u8 = undefined;
    var events: [count + 1]Provider.Event = undefined;
    fixture.readCalls(count, &ids, &events);
    harness.runner.rendezvous = Turn.read_only_calls_max;
    harness.provider.load(&.{
        .{ .done = &events },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    _ = try harness.turn("hi");
    try std.testing.expect(!harness.runner.timed_out);
    try std.testing.expectEqual(@as(u32, Turn.read_only_calls_max), harness.runner.peak);
    try std.testing.expectEqual(count, harness.runner.calls.items.len);
}

test "a read-only call whose task cannot start fails the turn and stays unanswered" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .concurrent_limit = .limited(2),
    });
    defer threaded.deinit();
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, threaded.io(), &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .tool_call_started = "read" },
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
    });
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tail_discarded:1
        \\turn_ended:failed:out_of_memory:
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(usize, 0), harness.runner.calls.items.len);
}

test "a turn whose task cannot start fails as out of memory and sends no request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .concurrent_limit = .limited(1),
    });
    defer threaded.deinit();
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, threaded.io(), &.{});
    defer harness.deinit();

    harness.provider.load(&.{.{ .done = &.{ fixture.message("ok"), fixture.stop_complete } }});
    try std.testing.expectEqualStrings(
        "turn_ended:failed:out_of_memory:",
        try harness.turn("hi"),
    );
    try std.testing.expectEqual(@as(usize, 0), harness.provider.requests.items.len);
}

test "a clear empties the conversation and resets the runner, also at the end of a turn" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            fixture.message("one"),
            .{ .usage = .{ .input = 10, .output = 2 } },
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.toolCall(fixture.call), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("two"), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("three"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:one
        \\usage:10/2/0/0
        \\context:12
        \\committed
        \\turn_ended:complete
    , try harness.turn("a"));
    try harness.session.send(&.clear);
    try harness.expect("context:0");
    try std.testing.expectEqual(@as(u32, 1), harness.runner.resets);
    harness.runner.hook = .{ .session = &harness.session, .command = .clear };
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:two
        \\committed
        \\context:0
        \\turn_ended:complete
    , try harness.turn("b"));
    try std.testing.expectEqual(@as(u32, 2), harness.runner.resets);
    _ = try harness.turn("c");
    try std.testing.expectEqualStrings("model-a|user:b", harness.provider.requests.items[1]);
    try std.testing.expectEqualStrings("model-a|user:c", harness.provider.requests.items[3]);
}

test "a turn removal drops the items of the last turn, its measurement, and the skill evidence" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            fixture.message("one"),
            .{ .usage = .{ .input = 10, .output = 2 } },
            fixture.stop_complete,
        } },
        .{ .done = &.{
            fixture.toolCall(fixture.call),
            .{ .usage = .{ .input = 20, .output = 4 } },
            fixture.stop_complete,
        } },
        .{ .open = &.{.{ .text = "I read " }} },
        .{ .done = &.{ fixture.message("two"), fixture.stop_complete } },
        .{ .open = &.{.{ .text = "I write " }} },
        .{ .done = &.{ fixture.message("three"), fixture.stop_complete } },
    });
    _ = try harness.turn("a");
    try harness.prompt("b");
    try std.testing.expectEqualStrings(
        \\tool_call_started:read
        \\usage:20/4/0/0
        \\context:24
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:I read 
    , try harness.until("text:I read "));
    try harness.session.send(&.cancel);
    _ = try harness.until("turn_ended:canceled");
    try harness.session.send(&.remove_turn);
    try harness.expect("context:none");
    try std.testing.expectEqual(@as(u32, 1), harness.runner.resets);
    _ = try harness.turn("c");
    try std.testing.expectEqualStrings(
        "model-a|user:a|assistant:one|user:c",
        harness.provider.requests.items[3],
    );

    try harness.session.send(&.clear);
    try harness.expect("context:0");
    try harness.prompt("d");
    _ = try harness.until("text:I write ");
    try harness.session.send(&.cancel);
    _ = try harness.until("turn_ended:canceled");
    try harness.session.send(&.remove_turn);
    try harness.expect("context:0");
    try std.testing.expectEqual(@as(u32, 3), harness.runner.resets);
    _ = try harness.turn("e");
    try std.testing.expectEqualStrings("model-a|user:e", harness.provider.requests.items[5]);
}

test "the context gauge binds to the account, the model, and the effort of its request" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            fixture.message("one"),
            .{ .usage = .{ .input = 1000, .output = 20 } },
            fixture.stop_complete,
        } },
    });
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:one
        \\usage:1000/20/0/0
        \\context:1020
        \\committed
        \\turn_ended:complete
    , try harness.turn("a"));

    try harness.configure(&harness.provider, "model-b");
    try harness.expect("setup_dropped");
    try harness.expect("context:none");
    try harness.configure(&harness.provider, "model-a");
    try harness.expect("setup_dropped");
    try harness.expect("context:1020");

    var lower = testing.Harness.setup(&harness.provider, "model-a");
    lower.effort = .low;
    try harness.session.send(&.{ .configure = lower });
    try harness.expect("setup_dropped");
    try harness.expect("context:none");

    var other = testing.Harness.setup(&harness.other, "model-a");
    other.account = "account-b";
    try harness.session.send(&.{ .configure = other });
    try harness.expect("setup_dropped");
    try harness.expect("context:none");
    try harness.configure(&harness.other, "model-a");
    try harness.expect("setup_dropped");
    try harness.expect("context:1020");
}

test "a queued skill joins the conversation at the round boundary and starts a round" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.runner.skills = &.{
        .{ .name = "zig-style", .source = "skills/zig/SKILL.md", .text = "Follow the style." },
    };
    harness.provider.load(&.{
        .{ .done = &.{ fixture.message("one"), fixture.stop_complete } },
        .{ .done = &.{ fixture.toolCall(fixture.call), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("two"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:one
        \\committed
        \\skill_loaded:zig-style:skills/zig/SKILL.md
        \\tool_call_started:read
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:two
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
    try std.testing.expectEqualStrings(
        "model-a|user:hi|assistant:one|user:Follow the style.",
        harness.provider.requests.items[1],
    );
    try std.testing.expectEqual(@as(usize, 3), harness.runner.history_items);
}

test "every request carries the cache key of its conversation, and a clear takes a new one" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{ fixture.message("one"), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("two"), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("three"), fixture.stop_complete } },
    });
    _ = try harness.turn("first");
    _ = try harness.turn("second");
    try harness.session.send(&.clear);
    try harness.expect("context:0");
    _ = try harness.turn("third");
    const keys = harness.provider.keys.items;
    try std.testing.expectEqual(@as(usize, 32), keys[0].len);
    try std.testing.expectEqualStrings(keys[0], keys[1]);
    try std.testing.expect(!std.mem.eql(u8, keys[1], keys[2]));
}

test "a reply keeps its reasoning and tool calls in stream order" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    const second_proof: Conversation.Proof = .{ .account = "account-a", .payload = "p2" };
    harness.provider.load(&.{
        .{ .done = &.{
            .{ .output = .{ .reasoning = fixture.proof } },
            fixture.toolCall(fixture.call),
            .{ .output = .{ .reasoning = second_proof } },
            fixture.toolCall(fixture.next_call),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    _ = try harness.turn("hi");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|reasoning:account-a:p1|call:c1:read:{\"path\":\"a.txt\"}|" ++
            "reasoning:account-a:p2|call:c2:read:{\"path\":\"b.txt\"}|result:c1:done|" ++
            "result:c2:done",
        harness.provider.requests.items[1],
    );
}

test "a reasoning item whose own call stays unanswered leaves with the call" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    const second_proof: Conversation.Proof = .{ .account = "account-a", .payload = "p2" };
    harness.provider.load(&.{
        .{ .done = &.{
            .reasoning_started,
            .{ .output = .{ .reasoning = fixture.proof } },
            .{ .tool_call_started = "write" },
            fixture.toolCall(fixture.write_call),
            .reasoning_started,
            .{ .output = .{ .reasoning = second_proof } },
            .{ .tool_call_started = "read" },
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    harness.runner.hook = .{ .session = &harness.session, .command = .cancel };
    try std.testing.expectEqualStrings(
        \\reasoning_started
        \\tool_call_started:write
        \\reasoning_started
        \\tool_call_started:read
        \\tool_started:w1
        \\tool_result:w1:done
        \\tail_discarded:2
        \\committed
        \\turn_ended:canceled
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(u32, 1), harness.runner.canceled);
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|reasoning:account-a:p1|call:w1:write:{}|result:w1:done|user:next",
        harness.provider.requests.items[1],
    );
}

test "the session opens a block for a reasoning delta or an output that arrived without a start" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .reasoning = "Read the file" },
            .{ .output = .{ .reasoning = fixture.proof } },
            .{ .output = .{ .reasoning = fixture.proof } },
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\reasoning_started
        \\reasoning:Read the file
        \\reasoning_started
        \\tool_call_started:read
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:ok
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
}

test "a message output closes its block, and a message that streamed its text shows once" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .text = "a" },
            fixture.message("a"),
            .{ .text = "b" },
            .{ .output = .{ .reasoning = fixture.proof } },
            fixture.message("b"),
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\text_started
        \\text:a
        \\text_started
        \\text:b
        \\reasoning_started
        \\tool_call_started:read
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:ok
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
    try std.testing.expectEqualStrings(
        "model-a|user:hi|assistant:a|assistant:b|reasoning:account-a:p1|" ++
            "call:c1:read:{\"path\":\"a.txt\"}|result:c1:done",
        harness.provider.requests.items[1],
    );
}

test "a deinit during a turn cancels its stream and frees every item" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    {
        errdefer harness.deinit();
        harness.provider.load(&.{
            .{ .open = &.{
                .{ .text = "I read " },
                .{ .output = .{ .reasoning = fixture.proof } },
                fixture.toolCall(fixture.call),
            } },
        });
        try harness.prompt("hi");
        try harness.expect("text_started");
        try harness.expect("text:I read ");
        try harness.expect("reasoning_started");
        try harness.expect("tool_call_started:read");
    }
    harness.deinit();
    try std.testing.expectEqual(@as(u32, 1), harness.provider.canceled);
}

test "a copy of each event owns its bytes, and a failed copy leaks nothing" {
    const call: Tool.Call = .{ .id = "c1", .name = "read", .arguments = "{}" };
    const events = [_]Event{
        .{ .text = "delta" },
        .{ .reasoning = "delta" },
        .{ .tool_call_started = "read" },
        .{ .tool_call_arguments = "{}" },
        .{ .tool_started = call },
        .{ .tool_result = .{ .call = call, .output = .{ .content = "done" } } },
        .{ .model_served = .{ .requested = "a", .served = "b" } },
        .{ .skill_loaded = .{ .name = "zig-style", .source = "SKILL.md" } },
        .{ .turn_ended = .canceled },
        .committed,
    };
    try testing.checkCopyAllocationFailures(Event, &events);
}

test "a failure keeps its reason and its wait when the copy of its message fails" {
    const failure: Provider.Failure = .{
        .reason = .rate_limited,
        .retry_after_ms = 7,
        .message = "slow",
    };
    const events = [_]Event{
        .{ .attempt_failed = .{ .attempt = 1, .failure = failure, .delay_ms = 0 } },
        .{ .turn_ended = .{ .failed = failure } },
    };
    for (&events) |*event| {
        const owned = try event.dupe(std.testing.allocator);
        defer owned.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("slow", failureOf(&owned).message);

        var failing: std.testing.FailingAllocator = .init(
            std.testing.allocator,
            .{ .fail_index = 0 },
        );
        const bare = try event.dupe(failing.allocator());
        defer bare.deinit(failing.allocator());
        const kept = failureOf(&bare);
        try std.testing.expectEqual(failure.reason, kept.reason);
        try std.testing.expectEqual(failure.retry_after_ms, kept.retry_after_ms);
        try std.testing.expectEqualStrings("", kept.message);
    }
}

fn failureOf(event: *const Event) Provider.Failure {
    return switch (event.*) {
        .attempt_failed => |attempt| attempt.failure,
        .turn_ended => |outcome| outcome.failed,
        else => unreachable,
    };
}
