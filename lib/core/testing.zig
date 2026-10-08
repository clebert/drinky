const std = @import("std");

const actor = @import("actor.zig");
const Conversation = @import("Conversation.zig");
const Provider = @import("Provider.zig");
const Retry = @import("Retry.zig");
const Runner = @import("Runner.zig");
const Session = @import("Session.zig");
const Tool = @import("Tool.zig");

const tools = [_]Tool{
    .{ .name = "read", .description = "Read a file.", .parameters = &.{} },
    .{ .name = "write", .description = "Write a file.", .parameters = &.{}, .mutates = true },
};

const lines_max = 1 << 16;
const rendezvous_timeout_ms = 5_000;
const rendezvous_polls_max = 1024;

pub const no_resize_allocator = no_resize_allocator_instance.allocator();
var no_resize_allocator_instance: std.testing.FailingAllocator = .init(std.testing.allocator, .{
    .resize_fail_index = 0,
});

pub const FakeProvider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    replies: []const Reply = &.{},
    index: usize = 0,
    position: usize = 0,
    requests: std.ArrayList([]u8) = .empty,
    settings: std.ArrayList([]u8) = .empty,
    keys: std.ArrayList([]u8) = .empty,
    canceled: u32 = 0,

    pub const Reply = union(enum) {
        done: []const Provider.Event,
        open: []const Provider.Event,
    };

    const vtable: Provider.VTable = .{ .open = open, .next = next, .close = close };

    fn deinit(self: *FakeProvider) void {
        for (self.requests.items) |request| self.gpa.free(request);
        self.requests.deinit(self.gpa);
        for (self.settings.items) |setting| self.gpa.free(setting);
        self.settings.deinit(self.gpa);
        for (self.keys.items) |key| self.gpa.free(key);
        self.keys.deinit(self.gpa);
    }

    pub fn load(self: *FakeProvider, replies: []const Reply) void {
        self.replies = replies;
        self.index = 0;
    }

    fn provider(self: *FakeProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn open(ptr: *anyopaque, request: *const Provider.Request) Provider.Error!void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        const rendered = try renderWith(self.gpa, request, writeRequest);
        errdefer self.gpa.free(rendered);
        try self.requests.append(self.gpa, rendered);
        const setting = try renderWith(self.gpa, request, writeSetting);
        errdefer self.gpa.free(setting);
        try self.settings.append(self.gpa, setting);
        const key = try self.gpa.dupe(u8, request.cache_key);
        errdefer self.gpa.free(key);
        try self.keys.append(self.gpa, key);
        self.position = 0;
    }

    fn next(ptr: *anyopaque) Provider.Error!?Provider.Event {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        if (self.index >= self.replies.len) return null;
        const reply = self.replies[self.index];
        const events = switch (reply) {
            inline else => |events| events,
        };
        if (self.position < events.len) {
            defer self.position += 1;
            return events[self.position];
        }
        switch (reply) {
            .done => return null,
            .open => {
                var never: std.Io.Event = .unset;
                never.wait(self.io) catch |err| {
                    self.canceled += 1;
                    return err;
                };
                unreachable;
            },
        }
    }

    fn close(ptr: *anyopaque) void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        self.index += 1;
    }
};

const FakeRunner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    calls: std.ArrayList([]u8) = .empty,
    history_items: usize = 0,
    hook: ?Hook = null,
    skills: []const Runner.Skill = &.{},
    skill_index: usize = 0,
    running: std.atomic.Value(u32) = .init(0),
    arrived: std.atomic.Value(u32) = .init(0),
    started: u32 = 0,
    peak: u32 = 0,
    rendezvous: u32 = 0,
    overlap: bool = false,
    timed_out: bool = false,
    canceled: u32 = 0,
    resets: u32 = 0,

    const Hook = struct {
        session: *Session,
        command: Session.Command,
        after_cancel: AfterCancel = .finish,

        const AfterCancel = enum { finish, fail };
    };

    const Recorded = struct {
        sequence: u32,
        fired: ?Hook,
    };

    const vtable: Runner.VTable = .{ .run = run, .takeSkill = takeSkill, .reset = reset };

    fn deinit(self: *FakeRunner) void {
        for (self.calls.items) |call| self.gpa.free(call);
        self.calls.deinit(self.gpa);
    }

    fn runner(self: *FakeRunner) Runner {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn run(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        call: *const Tool.Call,
        items: []const Conversation.Item,
        variables: []const Runner.Variable,
    ) Runner.Error!Tool.Output {
        const self: *FakeRunner = @ptrCast(@alignCast(ptr));
        const recorded = try self.record(call, items.len, variables);
        if (recorded.fired) |hook| {
            if (hook.command == .cancel) try self.awaitCancel(hook.after_cancel);
        }
        if (std.mem.eql(u8, call.name, "write")) {
            if (self.running.load(.acquire) != 0) self.overlap = true;
        } else {
            self.enter(recorded.sequence);
        }
        defer if (!std.mem.eql(u8, call.name, "write")) self.leave();
        return .{ .content = try gpa.dupe(u8, "done") };
    }

    fn record(
        self: *FakeRunner,
        call: *const Tool.Call,
        history_items: usize,
        variables: []const Runner.Variable,
    ) error{OutOfMemory}!Recorded {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.history_items = history_items;
        var rendered: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer rendered.deinit();
        const writer = &rendered.writer;
        writer.print("{s}:{s}", .{ call.name, call.arguments }) catch return error.OutOfMemory;
        for (variables) |variable| {
            writer.print("|{s}={s}", .{ variable.name, variable.value }) catch
                return error.OutOfMemory;
        }
        const text = try rendered.toOwnedSlice();
        errdefer self.gpa.free(text);
        try self.calls.append(self.gpa, text);
        const fired = self.hook;
        if (fired) |hook| {
            self.hook = null;
            hook.session.send(&hook.command) catch {};
        }
        defer self.started += 1;
        return .{ .sequence = self.started, .fired = fired };
    }

    fn awaitCancel(self: *FakeRunner, after_cancel: Hook.AfterCancel) Runner.Error!void {
        var never: std.Io.Event = .unset;
        never.wait(self.io) catch |err| {
            self.canceled += 1;
            switch (after_cancel) {
                .finish => return self.io.recancel(),
                .fail => return err,
            }
        };
        unreachable;
    }

    fn enter(self: *FakeRunner, sequence: u32) void {
        const running = self.running.fetchAdd(1, .acq_rel) + 1;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.peak = @max(self.peak, running);
        }
        _ = self.arrived.fetchAdd(1, .acq_rel);
        self.io.futexWake(u32, &self.arrived.raw, std.math.maxInt(u32));
        if (sequence >= self.rendezvous) return;
        const deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(
            .fromMilliseconds(rendezvous_timeout_ms),
        );
        for (0..rendezvous_polls_max) |_| {
            const seen = self.arrived.load(.acquire);
            if (seen >= self.rendezvous) return;
            if (std.Io.Timestamp.now(self.io, .awake).nanoseconds >= deadline.nanoseconds) break;
            self.io.futexWaitTimeout(u32, &self.arrived.raw, seen, .{ .duration = .{
                .raw = .fromMilliseconds(rendezvous_timeout_ms),
                .clock = .awake,
            } }) catch return;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.timed_out = true;
    }

    fn leave(self: *FakeRunner) void {
        _ = self.running.fetchSub(1, .acq_rel);
    }

    fn takeSkill(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        items: []const Conversation.Item,
    ) Runner.Error!?Runner.Skill {
        _ = items;
        const self: *FakeRunner = @ptrCast(@alignCast(ptr));
        if (self.skill_index >= self.skills.len) return null;
        const skill = self.skills[self.skill_index];
        self.skill_index += 1;
        const name = try gpa.dupe(u8, skill.name);
        errdefer gpa.free(name);
        const source = try gpa.dupe(u8, skill.source);
        errdefer gpa.free(source);
        return .{ .name = name, .source = source, .text = try gpa.dupe(u8, skill.text) };
    }

    fn reset(ptr: *anyopaque) void {
        const self: *FakeRunner = @ptrCast(@alignCast(ptr));
        self.resets += 1;
    }
};

pub const ClockIo = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    sleeps: [sleeps_max]u64,
    sleep_count: usize,

    const sleeps_max = 16;

    pub fn init(self: *ClockIo, gpa: std.mem.Allocator) void {
        self.threaded = .init(gpa, .{});
        self.vtable = self.threaded.io().vtable.*;
        self.vtable.sleep = sleep;
        self.sleep_count = 0;
    }

    pub fn deinit(self: *ClockIo) void {
        self.threaded.deinit();
    }

    pub fn io(self: *ClockIo) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    pub fn slept(self: *const ClockIo) []const u64 {
        return self.sleeps[0..@min(self.sleep_count, sleeps_max)];
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *ClockIo = @fieldParentPtr("threaded", threaded);
        const milliseconds = switch (timeout) {
            .none => 0,
            .duration => |duration| duration.raw.toMilliseconds(),
            .deadline => 0,
        };
        if (self.sleep_count < sleeps_max) self.sleeps[self.sleep_count] = @intCast(milliseconds);
        self.sleep_count += 1;
        return threaded.io().checkCancel();
    }
};

pub const StepClock = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    now_ns: i96,
    step_ns: i96,

    pub fn init(self: *StepClock, gpa: std.mem.Allocator, step_ms: u64) void {
        self.threaded = .init(gpa, .{});
        self.vtable = self.threaded.io().vtable.*;
        self.vtable.now = now;
        self.now_ns = 0;
        self.step_ns = @as(i96, step_ms) * std.time.ns_per_ms;
    }

    pub fn deinit(self: *StepClock) void {
        self.threaded.deinit();
    }

    pub fn io(self: *StepClock) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *StepClock = @alignCast(@fieldParentPtr("threaded", threaded));
        defer self.now_ns += self.step_ns;
        return .{ .nanoseconds = self.now_ns };
    }
};

pub const Harness = struct {
    gpa: std.mem.Allocator,
    provider: FakeProvider,
    other: FakeProvider,
    runner: FakeRunner,
    recorder: Recorder(Session.Event, writeEvent),
    session: Session,
    log: std.ArrayList(u8),

    const Options = struct {
        retry: Retry = .{
            .attempts_max = 1,
            .backoff = .{ .delay_ms_initial = 0, .delay_ms_max = 0 },
        },
    };

    pub fn init(self: *Harness, gpa: std.mem.Allocator, io: std.Io, options: *const Options) !void {
        self.gpa = gpa;
        self.provider = .{ .gpa = gpa, .io = io };
        self.other = .{ .gpa = gpa, .io = io };
        self.runner = .{ .gpa = gpa, .io = io };
        self.recorder.init(gpa, io);
        self.log = .empty;
        self.session = .init(gpa, io, &.{
            .sink = self.recorder.sink(),
            .runner = self.runner.runner(),
            .tools = &tools,
            .retry = options.retry,
        });
        try self.session.start();
        errdefer self.deinit();
        try self.configure(&self.provider, "model-a");
        try self.expect("context:0");
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        self.recorder.deinit();
        self.runner.deinit();
        self.provider.deinit();
        self.other.deinit();
        self.log.deinit(self.gpa);
    }

    pub fn setup(provider: *FakeProvider, model: []const u8) Session.Setup {
        return .{
            .provider = provider.provider(),
            .account = "account-a",
            .model = model,
            .effort = .high,
            .tokens_max = 4096,
            .system = "You are Drinky.",
            .variables = &.{},
        };
    }

    pub fn configure(self: *Harness, provider: *FakeProvider, model: []const u8) !void {
        try self.session.send(&.{ .configure = setup(provider, model) });
    }

    pub fn prompt(self: *Harness, text: []const u8) !void {
        try self.session.send(&.{ .prompt = text });
    }

    pub fn expect(self: *Harness, expected: []const u8) !void {
        try self.recorder.expect(expected);
    }

    pub fn until(self: *Harness, prefix: []const u8) ![]const u8 {
        self.log.clearRetainingCapacity();
        for (0..lines_max) |_| {
            const line = try self.recorder.next();
            defer self.gpa.free(line);
            if (self.log.items.len > 0) try self.log.append(self.gpa, '\n');
            try self.log.appendSlice(self.gpa, line);
            if (std.mem.startsWith(u8, line, prefix)) return self.log.items;
        }
        return error.TooManyLines;
    }

    pub fn turn(self: *Harness, text: []const u8) ![]const u8 {
        try self.prompt(text);
        return self.until("turn_ended");
    }
};

fn renderWith(
    gpa: std.mem.Allocator,
    request: *const Provider.Request,
    comptime write: fn (
        writer: *std.Io.Writer,
        request: *const Provider.Request,
    ) std.Io.Writer.Error!void,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    write(&out.writer, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSetting(writer: *std.Io.Writer, request: *const Provider.Request) std.Io.Writer.Error!void {
    try writer.print("{s}|", .{request.system});
    for (request.tools, 0..) |tool, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll(tool.name);
    }
    if (request.tokens_max) |tokens| {
        try writer.print("|{d}", .{tokens});
    } else try writer.writeAll("|none");
    if (request.effort) |effort| {
        try writer.print("|{t}", .{effort});
    } else try writer.writeAll("|none");
}

fn writeRequest(writer: *std.Io.Writer, request: *const Provider.Request) std.Io.Writer.Error!void {
    try writer.writeAll(request.model);
    for (request.items) |item| {
        try writer.writeByte('|');
        switch (item) {
            .message => |message| try writer.print("{s}:{s}", .{
                @tagName(message.role),
                message.text,
            }),
            .reasoning => |proof| try writer.print("reasoning:{s}:{s}", .{
                proof.account,
                proof.payload,
            }),
            .tool_call => |call| try writer.print("call:{s}:{s}:{s}", .{
                call.id,
                call.name,
                call.arguments,
            }),
            .tool_result => |result| try writer.print("result:{s}:{s}", .{
                result.call_id,
                result.output.content,
            }),
        }
    }
}

pub fn Recorder(
    comptime Event: type,
    comptime render: fn (writer: *std.Io.Writer, event: *const Event) std.Io.Writer.Error!void,
) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        buffer: [lines_buffered_max][]u8,
        queue: std.Io.Queue([]u8),

        const Self = @This();

        const lines_buffered_max = 256;

        const vtable: actor.Sink(Event).VTable = .{ .emit = emit };

        pub fn init(self: *Self, gpa: std.mem.Allocator, io: std.Io) void {
            self.gpa = gpa;
            self.io = io;
            self.queue = .init(&self.buffer);
        }

        pub fn deinit(self: *Self) void {
            self.queue.close(self.io);
            var lines: [lines_buffered_max][]u8 = undefined;
            const count = self.queue.getUncancelable(self.io, &lines, 0) catch 0;
            for (lines[0..count]) |line| self.gpa.free(line);
        }

        pub fn sink(self: *Self) actor.Sink(Event) {
            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn next(self: *Self) ![]u8 {
            return self.queue.getOne(self.io);
        }

        pub fn expect(self: *Self, expected: []const u8) !void {
            const line = try self.next();
            defer self.gpa.free(line);
            try std.testing.expectEqualStrings(expected, line);
        }

        fn emit(ptr: *anyopaque, event: *const Event) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            var out: std.Io.Writer.Allocating = .init(self.gpa);
            render(&out.writer, event) catch return out.deinit();
            const line = out.toOwnedSlice() catch return out.deinit();
            self.queue.putOneUncancelable(self.io, line) catch self.gpa.free(line);
        }
    };
}

pub fn checkCopyAllocationFailures(comptime Event: type, events: []const Event) !void {
    const Copy = struct {
        fn run(gpa: std.mem.Allocator, event: *const Event) error{OutOfMemory}!void {
            const copy = try event.dupe(gpa);
            copy.deinit(gpa);
        }
    };
    for (events) |*event| {
        try std.testing.checkAllAllocationFailures(no_resize_allocator, Copy.run, .{event});
    }
}

fn writeEvent(writer: *std.Io.Writer, event: *const Session.Event) std.Io.Writer.Error!void {
    switch (event.*) {
        .setup_dropped => try writer.writeAll("setup_dropped"),
        .text_started => try writer.writeAll("text_started"),
        .text => |delta| try writer.print("text:{s}", .{delta}),
        .reasoning_started => try writer.writeAll("reasoning_started"),
        .reasoning => |delta| try writer.print("reasoning:{s}", .{delta}),
        .tool_call_started => |name| try writer.print("tool_call_started:{s}", .{name}),
        .tool_call_arguments => |delta| try writer.print("tool_call_arguments:{s}", .{delta}),
        .tool_started => |call| try writer.print("tool_started:{s}", .{call.id}),
        .tool_result => |result| try writer.print("tool_result:{s}:{s}", .{
            result.call.id,
            result.output.content,
        }),
        .committed => try writer.writeAll("committed"),
        .tail_discarded => |blocks| try writer.print("tail_discarded:{d}", .{blocks}),
        .usage => |usage| try writer.print("usage:{d}/{d}/{d}/{d}", .{
            usage.input,
            usage.output,
            usage.cache_read,
            usage.cache_write,
        }),
        .quota => |quota| try writer.print("quota:{d}", .{
            if (quota.primary) |window| window.used_percent else -1,
        }),
        .credits => |credits| try writer.print("credits:{d}/{d}", .{ credits.total, credits.used }),
        .context => |maybe_tokens| if (maybe_tokens) |tokens|
            try writer.print("context:{d}", .{tokens})
        else
            try writer.writeAll("context:none"),
        .model_served => |served| try writer.print("model_served:{s}>{s}", .{
            served.requested,
            served.served,
        }),
        .attempt_failed => |attempt| try writer.print("attempt_failed:{d}:{s}:{s}:{d}", .{
            attempt.attempt,
            @tagName(attempt.failure.reason),
            attempt.failure.message,
            attempt.delay_ms,
        }),
        .skill_loaded => |skill| try writer.print("skill_loaded:{s}:{s}", .{
            skill.name,
            skill.source,
        }),
        .turn_ended => |outcome| switch (outcome) {
            .stopped => |reason| try writer.print("turn_ended:{s}", .{@tagName(reason)}),
            .canceled => try writer.writeAll("turn_ended:canceled"),
            .exhausted => try writer.writeAll("turn_ended:exhausted"),
            .failed => |failure| try writer.print("turn_ended:failed:{s}:{s}", .{
                @tagName(failure.reason),
                failure.message,
            }),
        },
    }
}
