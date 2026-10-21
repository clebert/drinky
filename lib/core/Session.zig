const std = @import("std");

const actor = @import("actor.zig");
const Aside = @import("Aside.zig");
const Conversation = @import("Conversation.zig");
const fatal = @import("fatal.zig");
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
turn_count: usize,
turn_starts: std.ArrayList(TurnStart),
setup: ?Setup,
next_setup: ?Setup,
clear_pending: bool,
measured: ?Turn.Measured,
aside: ?Aside.Request,
mailbox: actor.Mailbox(Mail, mail_capacity),
loop: ?std.Io.Future(void),

pub const Options = struct {
    sink: Sink,
    runner: Runner,
    tools: []const Tool,
    retry: Retry = .{},
};

pub const Sink = actor.Sink(Event);

pub const TurnStart = struct {
    turn: usize,
    item: usize,
};

pub const Setup = struct {
    provider: Provider,
    account: []const u8,
    model: []const u8,
    effort: ?Provider.Effort,
    tokens_max: ?u32,
    system: []const u8,
    variables: []const Runner.Variable,

    fn dupe(self: *const Setup, gpa: std.mem.Allocator) error{OutOfMemory}!Setup {
        const account = try gpa.dupe(u8, self.account);
        errdefer gpa.free(account);
        const model = try gpa.dupe(u8, self.model);
        errdefer gpa.free(model);
        const system = try gpa.dupe(u8, self.system);
        errdefer gpa.free(system);
        return .{
            .provider = self.provider,
            .account = account,
            .model = model,
            .effort = self.effort,
            .tokens_max = self.tokens_max,
            .system = system,
            .variables = try Runner.Variable.dupeAll(gpa, self.variables),
        };
    }

    fn deinit(self: *const Setup, gpa: std.mem.Allocator) void {
        gpa.free(self.account);
        gpa.free(self.model);
        gpa.free(self.system);
        Runner.Variable.freeAll(gpa, self.variables);
    }
};

pub const Command = union(enum) {
    prompt: []const u8,
    aside: Aside.Request,
    cancel,
    configure: Setup,
    clear,
    rewind: usize,

    fn dupe(self: *const Command, gpa: std.mem.Allocator) error{OutOfMemory}!Command {
        return switch (self.*) {
            .prompt => |text| .{ .prompt = try gpa.dupe(u8, text) },
            .aside => |*request| .{ .aside = try request.dupe(gpa) },
            .configure => |*setup| .{ .configure = try setup.dupe(gpa) },
            .cancel, .clear, .rewind => self.*,
        };
    }

    fn deinit(self: *const Command, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .prompt => |text| gpa.free(text),
            .aside => |*request| request.deinit(gpa),
            .configure => |*setup| setup.deinit(gpa),
            .cancel, .clear, .rewind => {},
        }
    }
};

pub const Event = union(enum) {
    setup_dropped: Provider,
    text_started,
    text: []const u8,
    aside_text: []const u8,
    aside_reasoning: []const u8,
    aside_attempt_failed: Attempt,
    aside_ended: Outcome,
    reasoning_started,
    reasoning: []const u8,
    tool_call_started: []const u8,
    tool_call_arguments: []const u8,
    tool_started: Tool.Call,
    tool_result: ToolResult,
    committed,
    tail_discarded: usize,
    usage: Provider.Usage,
    cost: f64,
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

        fn dupe(self: *const Attempt, gpa: std.mem.Allocator) error{OutOfMemory}!Attempt {
            return .{
                .attempt = self.attempt,
                .failure = try self.failure.dupe(gpa),
                .delay_ms = self.delay_ms,
            };
        }
    };

    pub const SkillLoaded = struct {
        name: []const u8,
        source: []const u8,
    };

    pub fn dupe(self: *const Event, gpa: std.mem.Allocator) error{OutOfMemory}!Event {
        return switch (self.*) {
            .text => |delta| .{ .text = try gpa.dupe(u8, delta) },
            .aside_text => |delta| .{ .aside_text = try gpa.dupe(u8, delta) },
            .aside_reasoning => |delta| .{ .aside_reasoning = try gpa.dupe(u8, delta) },
            .aside_ended => |*outcome| .{ .aside_ended = try outcome.dupe(gpa) },
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
            .attempt_failed => |*attempt| .{ .attempt_failed = try attempt.dupe(gpa) },
            .aside_attempt_failed => |*attempt| .{ .aside_attempt_failed = try attempt.dupe(gpa) },
            .skill_loaded => |skill| {
                const name = try gpa.dupe(u8, skill.name);
                errdefer gpa.free(name);
                return .{ .skill_loaded = .{
                    .name = name,
                    .source = try gpa.dupe(u8, skill.source),
                } };
            },
            .turn_ended => |*outcome| .{ .turn_ended = try outcome.dupe(gpa) },
            .setup_dropped,
            .text_started,
            .reasoning_started,
            .committed,
            .tail_discarded,
            .usage,
            .cost,
            .quota,
            .credits,
            .context,
            => self.*,
        };
    }

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text,
            .aside_text,
            .aside_reasoning,
            .reasoning,
            .tool_call_started,
            .tool_call_arguments,
            => |bytes| gpa.free(bytes),
            .aside_ended => |*outcome| outcome.deinit(gpa),
            .tool_started => |*call| call.deinit(gpa),
            .tool_result => |*result| {
                result.call.deinit(gpa);
                result.output.deinit(gpa);
            },
            .model_served => |served| {
                gpa.free(served.requested);
                gpa.free(served.served);
            },
            .attempt_failed, .aside_attempt_failed => |*attempt| attempt.failure.deinit(gpa),
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
            .cost,
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

    pub fn dupe(self: *const Outcome, gpa: std.mem.Allocator) error{OutOfMemory}!Outcome {
        return switch (self.*) {
            .failed => |*failure| .{ .failed = try failure.dupe(gpa) },
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
    aside_ended: Outcome,

    pub fn deinit(self: *const Mail, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .command => |*command| command.deinit(gpa),
            .ended => |*ended| ended.deinit(gpa),
            .aside_ended => |*outcome| outcome.deinit(gpa),
        }
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: *const Options) Session {
    return .{
        .gpa = gpa,
        .io = io,
        .options = options.*,
        .conversation = .init(io),
        .turn_count = 0,
        .turn_starts = .empty,
        .setup = null,
        .next_setup = null,
        .clear_pending = false,
        .measured = null,
        .aside = null,
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
    self.dropAside();
    self.turn_starts.deinit(self.gpa);
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
            .aside_ended => |outcome| self.endAside(outcome),
        }
    }
}

fn handle(self: *Session, command: Command) void {
    switch (command) {
        .prompt => |text| self.prompt(text),
        .aside => |request| self.ask(request),
        .cancel => self.mailbox.cancel(self.io),
        .configure => |setup| self.configure(setup),
        .clear => self.requestClear(),
        .rewind => |turn| self.rewind(turn),
    }
}

fn prompt(self: *Session, text: []const u8) void {
    std.debug.assert(!self.mailbox.busy());
    std.debug.assert(self.setup != null);
    const turn_index = self.turn_count;
    self.turn_count += 1;
    self.appendPrompt(turn_index, text) catch fatal.outOfMemory();
    const turn: Turn = .{
        .gpa = self.gpa,
        .io = self.io,
        .options = self.options,
        .conversation = &self.conversation,
        .setup = &self.setup.?,
        .measured = null,
    };
    self.mailbox.start(self.io, runTurn, .{turn}) catch
        self.emit(&.{ .turn_ended = .{ .failed = .{ .reason = .concurrency_unavailable } } });
}

fn appendPrompt(self: *Session, turn: usize, text: []const u8) error{OutOfMemory}!void {
    try self.turn_starts.ensureUnusedCapacity(self.gpa, 1);
    const item = self.conversation.items.items.len;
    try self.conversation.append(self.gpa, .{ .message = .{ .role = .user, .text = text } });
    self.turn_starts.appendAssumeCapacity(.{ .turn = turn, .item = item });
}

fn runTurn(lent: Turn) Mail {
    var turn = lent;
    return .{ .ended = turn.run() };
}

fn ask(self: *Session, request: Aside.Request) void {
    std.debug.assert(!self.mailbox.busy());
    std.debug.assert(self.setup != null);
    self.aside = request;
    const aside: Aside = .{
        .gpa = self.gpa,
        .io = self.io,
        .options = self.options,
        .setup = &self.setup.?,
        .request = &self.aside.?,
        .conversation = &self.conversation,
        .turn_starts = self.turn_starts.items,
    };
    self.mailbox.start(self.io, runAside, .{aside}) catch {
        self.dropAside();
        self.emit(&.{ .aside_ended = .{ .failed = .{ .reason = .concurrency_unavailable } } });
    };
}

fn runAside(aside: Aside) Mail {
    return .{ .aside_ended = aside.run() };
}

fn dropAside(self: *Session) void {
    if (self.aside) |*request| request.deinit(self.gpa);
    self.aside = null;
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
    self.turn_count = 0;
    self.turn_starts.clearRetainingCapacity();
    self.forgetMeasured();
    self.options.runner.reset();
    self.emit(&.{ .context = 0 });
}

fn rewind(self: *Session, turn: usize) void {
    std.debug.assert(!self.mailbox.busy());
    std.debug.assert(turn < self.turn_count);
    const kept = for (self.turn_starts.items, 0..) |turn_start, index| {
        if (turn_start.turn >= turn) break index;
    } else self.turn_starts.items.len;
    if (kept < self.turn_starts.items.len)
        self.conversation.truncate(self.gpa, self.turn_starts.items[kept].item);
    self.turn_starts.shrinkRetainingCapacity(kept);
    self.turn_count = turn;
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
    self.settle();
    self.emit(&.{ .turn_ended = ended.outcome });
    ended.outcome.deinit(self.gpa);
}

fn endAside(self: *Session, outcome: Outcome) void {
    self.mailbox.reap(self.io);
    self.dropAside();
    self.settle();
    self.emit(&.{ .aside_ended = outcome });
    outcome.deinit(self.gpa);
}

fn settle(self: *Session) void {
    if (self.next_setup) |setup| {
        self.next_setup = null;
        self.apply(setup);
    }
    if (self.clear_pending) {
        self.clear_pending = false;
        self.clear();
    }
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

test "tool charges reach the client before the result and survive cancellation" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();
    harness.runner.charges = &.{ 0.25, 0.5 };
    harness.runner.hook = .{
        .session = &harness.session,
        .command = .cancel,
        .after_cancel = .fail,
    };
    harness.provider.load(&.{.{ .done = &.{
        fixture.toolCall(fixture.write_call),
        fixture.stop_complete,
    } }});
    const expected = "tool_call_started:write\ntool_started:w1\ncost:0.25\ncost:0.5\n" ++
        "tool_result:w1:" ++ fixture.canceled_text ++ ":canceled\ncommitted\nturn_ended:canceled";
    try std.testing.expectEqualStrings(expected, try harness.turn("hi"));
}

test "a turn reports only the last usage of each attempt before it runs tools" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{
        .retry = .{ .attempts_max = 2, .backoff = .{ .delay_ms_initial = 0 } },
    });
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            .{ .usage = .{ .input = 1 } },
            .{ .usage = .{ .input = 2 } },
            .{ .failed = .{ .reason = .overloaded } },
        } },
        .{ .done = &.{
            .{ .usage = .{ .input = 3 } },
            fixture.toolCall(fixture.call),
            .{ .usage = .{ .input = 4 } },
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try std.testing.expectEqualStrings(
        \\usage:2/0/0/0
        \\attempt_failed:1:overloaded::0
        \\tool_call_started:read
        \\usage:4/0/0/0
        \\context:4
        \\tool_started:c1
        \\tool_result:c1:done
        \\committed
        \\text_started
        \\text:ok
        \\committed
        \\turn_ended:complete
    , try harness.turn("hi"));
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
    const canceled_text = "Drinky canceled the call before it received its result. " ++
        "The call can have completed some or all of its work.";
    const unstarted_text = "Drinky did not run the call because the turn ended.";
    const handoff: Aside.Request = .{
        .system = "Summarize the task.",
        .text = "Prepare a handoff.",
        .include_dialogue = true,
    };

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
            const id = std.mem.print(&ids[index], "r{d}", .{index}) catch unreachable;
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
            .{ .usage = .{ .input = 1200 } },
            .{ .text = "I read " },
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try harness.prompt("hi");
    try harness.expect("reasoning_started");
    try harness.expect("reasoning:Read the file");
    try harness.expect("text_started");
    try harness.expect("text:I read ");
    try harness.session.send(&.cancel);
    try std.testing.expectEqualStrings(
        \\usage:1200/0/0/0
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

test "a cancel while a tool call runs answers the next call as a call that did not run" {
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
        \\tool_result:c1:Drinky did not run the call because the turn ended.:canceled
        \\committed
        \\turn_ended:canceled
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(u32, 1), harness.runner.canceled);
    try std.testing.expectEqual(@as(usize, 1), harness.runner.calls.items.len);
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|call:w1:write:{}|call:c1:read:{\"path\":\"a.txt\"}|result:w1:done|" ++
            "result:c1:Drinky did not run the call because the turn ended.|user:next",
        harness.provider.requests.items[1],
    );
}

test "a cancel ends a running read-only call, and the call keeps a canceled result" {
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
        "tool_call_started:read\ntool_started:c1\ntool_result:c1:" ++ fixture.canceled_text ++
            ":canceled\ncommitted\nturn_ended:canceled",
        try harness.turn("hi"),
    );
    try std.testing.expectEqual(@as(u32, 1), harness.runner.canceled);
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|call:c1:read:{\"path\":\"a.txt\"}|result:c1:" ++ fixture.canceled_text ++
            "|user:next",
        harness.provider.requests.items[1],
    );
}

test "a cancel during a write answers the write as started and the next call as not run" {
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
    harness.runner.hook = .{
        .session = &harness.session,
        .command = .cancel,
        .after_cancel = .fail,
    };
    const events = try harness.turn("hi");
    try std.testing.expect(std.mem.find(u8, events, "user canceled") == null);
    try std.testing.expectEqualStrings(
        "tool_call_started:write\ntool_call_started:read\ntool_started:w1\ntool_result:w1:" ++
            fixture.canceled_text ++ ":canceled\ntool_result:c1:" ++ fixture.unstarted_text ++
            ":canceled\ncommitted\nturn_ended:canceled",
        events,
    );
    try std.testing.expectEqual(@as(u32, 1), harness.runner.canceled);
    _ = try harness.turn("next");
    const request = harness.provider.requests.items[1];
    try std.testing.expect(std.mem.find(u8, request, "user canceled") == null);
    try std.testing.expectEqualStrings(
        "model-a|user:hi|call:w1:write:{}|call:c1:read:{\"path\":\"a.txt\"}|result:w1:" ++
            fixture.canceled_text ++ "|result:c1:" ++ fixture.unstarted_text ++ "|user:next",
        request,
    );
}

test "a cancel while the model streams removes the tool calls of the unfinished reply" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .open = &.{
            .{ .tool_call_started = "read" },
            fixture.toolCall(fixture.call),
            .{ .text = "more" },
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    try harness.prompt("hi");
    try harness.expect("tool_call_started:read");
    try harness.expect("text_started");
    try harness.expect("text:more");
    try harness.session.send(&.cancel);
    try std.testing.expectEqualStrings(
        \\tail_discarded:2
        \\turn_ended:canceled
    , try harness.until("turn_ended"));
    try std.testing.expectEqual(@as(usize, 0), harness.runner.calls.items.len);
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|user:next",
        harness.provider.requests.items[1],
    );
}

test "a cancel keeps the result of a read-only call that completed before the cancel" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{
            fixture.toolCall(fixture.call),
            fixture.toolCall(fixture.next_call),
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
    });
    harness.runner.hook = .{
        .session = &harness.session,
        .command = .cancel,
        .after_cancel = .fail,
        .maybe_call_id = fixture.call.id,
    };
    try std.testing.expectEqualStrings(
        "tool_call_started:read\ntool_call_started:read\ntool_started:c1\ntool_started:c2\n" ++
            "tool_result:c2:done\ntool_result:c1:" ++ fixture.canceled_text ++
            ":canceled\ncommitted\nturn_ended:canceled",
        try harness.turn("hi"),
    );
    _ = try harness.turn("next");
    try std.testing.expectEqualStrings(
        "model-a|user:hi|call:c1:read:{\"path\":\"a.txt\"}|call:c2:read:{\"path\":\"b.txt\"}|" ++
            "result:c1:" ++ fixture.canceled_text ++ "|result:c2:done|user:next",
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

test "a tool call gets the variables of the setup that runs its turn" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{ fixture.toolCall(fixture.call), fixture.stop_complete } },
        .{ .done = &.{ fixture.toolCall(fixture.call), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("one"), fixture.stop_complete } },
    });
    harness.other.load(&.{
        .{ .done = &.{ fixture.toolCall(fixture.call), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("two"), fixture.stop_complete } },
    });
    var first = testing.Harness.setup(&harness.provider, "model-a");
    first.variables = &.{.{ .name = "MODEL", .value = "a" }};
    try harness.session.send(&.{ .configure = first });
    var second = testing.Harness.setup(&harness.other, "model-b");
    second.variables = &.{.{ .name = "MODEL", .value = "b" }};
    harness.runner.hook = .{ .session = &harness.session, .command = .{ .configure = second } };
    _ = try harness.turn("a");
    _ = try harness.turn("b");

    const calls = harness.runner.calls.items;
    try std.testing.expectEqual(@as(usize, 3), calls.len);
    try std.testing.expectEqualStrings("read:{\"path\":\"a.txt\"}|MODEL=a", calls[0]);
    try std.testing.expectEqualStrings("read:{\"path\":\"a.txt\"}|MODEL=a", calls[1]);
    try std.testing.expectEqualStrings("read:{\"path\":\"a.txt\"}|MODEL=b", calls[2]);
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

test "an aside streams its reply outside the conversation with its system text and setup effort" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{ fixture.message("ok"), fixture.stop_complete } },
        .{ .done = &.{
            .reasoning_started,
            .{ .reasoning = "Weigh it" },
            .{ .text = "Short " },
            .{ .text = "version." },
            fixture.message("Short version."),
            .{ .usage = .{ .input = 30, .output = 5 } },
            .{ .quota = .{ .primary = .{ .used_percent = 42 } } },
            fixture.stop_complete,
        } },
        .{ .done = &.{ fixture.message("Only the message."), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("two"), fixture.stop_complete } },
    });
    _ = try harness.turn("hi");
    try harness.ask("The long answer.");
    try std.testing.expectEqualStrings(
        \\aside_reasoning:Weigh it
        \\aside_text:Short 
        \\aside_text:version.
        \\quota:42
        \\usage:30/5/0/0
        \\aside_ended:complete
    , try harness.until("aside_ended"));
    try harness.ask("Another answer.");
    try std.testing.expectEqualStrings(
        \\aside_text:Only the message.
        \\aside_ended:complete
    , try harness.until("aside_ended"));
    _ = try harness.turn("next");

    const provider = &harness.provider;
    try std.testing.expectEqualStrings("model-a|user:The long answer.", provider.requests.items[1]);
    try std.testing.expectEqualStrings("Be brief.||4096|high", provider.settings.items[1]);
    try std.testing.expectEqualStrings("", provider.keys.items[1]);
    try std.testing.expectEqualStrings(
        "model-a|user:hi|assistant:ok|user:next",
        provider.requests.items[3],
    );
}

test "a handoff aside sends each prompt with the final answer of its turn and no tools" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();
    harness.runner.skills = &.{
        .{ .name = "zig-style", .source = "skills/zig/SKILL.md", .text = "Follow the style." },
    };
    harness.provider.load(&.{
        .{ .done = &.{
            .{ .text = "Let me check." },
            fixture.message("Let me check."),
            fixture.toolCall(fixture.call),
            fixture.stop_complete,
        } },
        .{ .done = &.{
            .{ .output = .{ .reasoning = fixture.proof } },
            fixture.message("Checked."),
            .{ .output = .{ .reasoning = fixture.proof } },
            fixture.message("Done."),
            fixture.stop_complete,
        } },
        .{ .done = &.{.{ .failed = .{ .reason = .network } }} },
        .{ .done = &.{ fixture.message("Handoff."), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("Next."), fixture.stop_complete } },
    });
    _ = try harness.turn("a");
    try std.testing.expect(std.mem.endsWith(u8, try harness.turn("b"), "failed:network:"));
    try harness.session.send(&.{ .aside = fixture.handoff });
    try std.testing.expectEqualStrings(
        \\aside_text:Handoff.
        \\aside_ended:complete
    , try harness.until("aside_ended"));
    _ = try harness.turn("c");

    const provider = &harness.provider;
    try std.testing.expectEqualStrings(
        "model-a|user:a|assistant:Checked.|assistant:Done.|user:b|user:Prepare a handoff.",
        provider.requests.items[3],
    );
    try std.testing.expectEqualStrings(
        "Summarize the task.||4096|high",
        provider.settings.items[3],
    );
    try std.testing.expectEqualStrings("", provider.keys.items[3]);
    try std.testing.expectEqualStrings(
        "model-a|user:a|assistant:Let me check.|call:c1:read:{\"path\":\"a.txt\"}|" ++
            "result:c1:done|user:Follow the style.|reasoning:account-a:p1|assistant:Checked.|" ++
            "reasoning:account-a:p1|assistant:Done.|user:b|user:c",
        provider.requests.items[4],
    );
    const requests = [_]Aside.Request{
        fixture.handoff,
        .{ .system = "Be brief.", .text = "The long answer." },
    };
    try testing.checkCopyAllocationFailures(Aside.Request, &requests);
}

test "an aside rejects a reply that contains only whitespace" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();
    harness.provider.load(&.{.{ .done = &.{
        .{ .text = " \n" },
        fixture.message(" \n"),
        fixture.stop_complete,
    } }});
    try harness.ask("Summarize.");
    try std.testing.expect(std.mem.endsWith(
        u8,
        try harness.until("aside_ended"),
        "aside_ended:failed:empty_reply:",
    ));
}

test "an aside repeats a failed attempt before its first text and ends at a failure after it" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{
        .retry = .{ .attempts_max = 3, .backoff = .{ .delay_ms_initial = 0, .delay_ms_max = 0 } },
    });
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{ .{ .usage = .{ .input = 7 } }, .{ .failed = .{ .reason = .overloaded } } } },
        .{ .done = &.{
            .{ .text = "Short" },
            .{ .failed = .{ .reason = .overloaded, .message = "The model is busy." } },
        } },
    });
    try harness.ask("The long answer.");
    try std.testing.expectEqualStrings(
        \\usage:7/0/0/0
        \\aside_attempt_failed:1:overloaded::0
        \\aside_text:Short
        \\aside_ended:failed:overloaded:The model is busy.
    , try harness.until("aside_ended"));
    try std.testing.expectEqual(@as(usize, 2), harness.provider.requests.items.len);
}

test "an aside whose task cannot start fails as unavailable concurrency and sends no request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .concurrent_limit = .limited(1),
    });
    defer threaded.deinit();
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, threaded.io(), &.{});
    defer harness.deinit();

    harness.provider.load(&.{.{ .done = &.{ fixture.message("ok"), fixture.stop_complete } }});
    try harness.ask("The long answer.");
    try harness.expect("aside_ended:failed:concurrency_unavailable:");
    try std.testing.expectEqual(@as(usize, 0), harness.provider.requests.items.len);
}

test "a cancel ends an aside, and a setup that arrives during it applies at its end" {
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, std.testing.io, &.{});
    defer harness.deinit();

    harness.provider.load(&.{
        .{ .done = &.{ fixture.message("one"), fixture.stop_complete } },
        .{ .open = &.{.{ .text = "Short" }} },
    });
    harness.other.load(&.{.{ .done = &.{ fixture.message("two"), fixture.stop_complete } }});
    _ = try harness.turn("a");
    try harness.ask("one");
    try harness.expect("aside_text:Short");
    try harness.configure(&harness.other, "model-b");
    try harness.session.send(&.cancel);
    try std.testing.expectEqualStrings(
        \\setup_dropped
        \\context:none
        \\aside_ended:canceled
    , try harness.until("aside_ended"));
    try std.testing.expectEqual(@as(u32, 1), harness.provider.canceled);
    _ = try harness.turn("b");
    try std.testing.expectEqualStrings(
        "model-b|user:a|assistant:one|user:b",
        harness.other.requests.items[0],
    );
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
        \\turn_ended:failed:concurrency_unavailable:
    , try harness.turn("hi"));
    try std.testing.expectEqual(@as(usize, 0), harness.runner.calls.items.len);
}

test "a turn whose task cannot start fails as unavailable concurrency and sends no request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .concurrent_limit = .limited(1),
    });
    defer threaded.deinit();
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, threaded.io(), &.{});
    defer harness.deinit();

    harness.provider.load(&.{.{ .done = &.{ fixture.message("ok"), fixture.stop_complete } }});
    try std.testing.expectEqualStrings(
        "turn_ended:failed:concurrency_unavailable:",
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

test "a rewind of the last turn drops its items, its measurement, and the skill evidence" {
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
    try harness.session.send(&.{ .rewind = 1 });
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
    try harness.session.send(&.{ .rewind = 0 });
    try harness.expect("context:0");
    try std.testing.expectEqual(@as(u32, 3), harness.runner.resets);
    _ = try harness.turn("e");
    try std.testing.expectEqualStrings("model-a|user:e", harness.provider.requests.items[5]);
}

test "a rewind drops the chosen turn and every later turn, and keeps the cache key" {
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
        .{ .done = &.{ fixture.message("four"), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("five"), fixture.stop_complete } },
        .{ .done = &.{ fixture.message("six"), fixture.stop_complete } },
    });
    _ = try harness.turn("a");
    _ = try harness.turn("b");
    _ = try harness.turn("c");
    try harness.session.send(&.{ .rewind = 1 });
    try harness.expect("context:none");
    try std.testing.expectEqual(@as(u32, 1), harness.runner.resets);
    _ = try harness.turn("d");
    try std.testing.expectEqualStrings(
        "model-a|user:a|assistant:one|user:d",
        harness.provider.requests.items[4],
    );

    try harness.session.send(&.{ .rewind = 1 });
    try harness.expect("context:none");
    _ = try harness.turn("e");
    try std.testing.expectEqualStrings(
        "model-a|user:a|assistant:one|user:e",
        harness.provider.requests.items[5],
    );

    try harness.session.send(&.{ .rewind = 0 });
    try harness.expect("context:0");
    _ = try harness.turn("f");
    try std.testing.expectEqualStrings("model-a|user:f", harness.provider.requests.items[6]);
    const keys = harness.provider.keys.items;
    for (keys[1..]) |key| try std.testing.expectEqualStrings(keys[0], key);
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
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .concurrent_limit = .limited(2),
    });
    defer threaded.deinit();
    var harness: testing.Harness = undefined;
    try harness.init(std.testing.allocator, threaded.io(), &.{});
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
    try std.testing.expectEqualStrings(
        \\reasoning_started
        \\tool_call_started:write
        \\reasoning_started
        \\tool_call_started:read
        \\tool_started:w1
        \\tool_result:w1:done
        \\tail_discarded:2
        \\committed
        \\turn_ended:failed:concurrency_unavailable:
    , try harness.turn("hi"));
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
    const failure: Provider.Failure = .{
        .reason = .rate_limited,
        .retry_after_ms = 7,
        .message = "slow",
    };
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
        .{ .turn_ended = .{ .failed = failure } },
        .{ .attempt_failed = .{ .attempt = 1, .failure = failure, .delay_ms = 0 } },
        .{ .aside_text = "delta" },
        .{ .aside_reasoning = "delta" },
        .{ .aside_ended = .canceled },
        .{ .aside_ended = .{ .failed = failure } },
        .{ .aside_attempt_failed = .{ .attempt = 1, .failure = failure, .delay_ms = 0 } },
        .committed,
    };
    try testing.checkCopyAllocationFailures(Event, &events);
}
