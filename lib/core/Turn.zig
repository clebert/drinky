const std = @import("std");

const Conversation = @import("Conversation.zig");
const Provider = @import("Provider.zig");
const Runner = @import("Runner.zig");
const Session = @import("Session.zig");
const timeout = @import("timeout.zig");
const Tool = @import("Tool.zig");

const Turn = @This();

pub const tool_calls_max: usize = 64;
pub const read_only_calls_max: usize = 32;
pub const rounds_max: usize = 1000;
const events_max: usize = 1 << 20;
const skills_max: usize = 64;

gpa: std.mem.Allocator,
io: std.Io,
options: Session.Options,
conversation: *Conversation,
setup: *const Session.Setup,
measured: ?Measured,

pub const End = struct {
    outcome: Session.Outcome,
    measured: ?Measured,

    pub fn deinit(self: *const End, gpa: std.mem.Allocator) void {
        self.outcome.deinit(gpa);
        if (self.measured) |*measured| measured.deinit(gpa);
    }
};

pub const Measured = struct {
    tokens: u64,
    account: []const u8,
    model: []const u8,
    effort: ?Provider.Effort,

    pub fn deinit(self: *const Measured, gpa: std.mem.Allocator) void {
        gpa.free(self.account);
        gpa.free(self.model);
    }

    pub fn matches(self: *const Measured, setup: *const Session.Setup) bool {
        return std.mem.eql(u8, self.account, setup.account) and
            std.mem.eql(u8, self.model, setup.model) and
            self.effort == setup.effort;
    }
};

const Step = union(enum) {
    reply: Provider.Stop.Reason,
    ended: Session.Outcome,
};

const Reply = union(enum) {
    accepted: Provider.Stop.Reason,
    canceled,
    failed: Provider.Failure,
};

const Read = union(enum) {
    stopped: Provider.Stop,
    canceled,
    failed: Provider.Failure,
};

const Batch = struct {
    start: usize,
    end: usize,
};

const Staging = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    text: std.ArrayList(u8),
    failure_message: std.ArrayList(u8),
    text_slot: ?usize,
    open_block: ?Block,
    blocks: usize,
    usage: ?Provider.Usage,

    const Entry = struct {
        kind: Kind,
        block_end: usize,

        const Kind = union(enum) {
            item: Conversation.Item,
            text,
            call: Pending,
        };

        fn deinit(self: *const Entry, gpa: std.mem.Allocator) void {
            switch (self.kind) {
                .item => |item| item.deinit(gpa),
                .text => {},
                .call => |pending| {
                    pending.call.deinit(gpa);
                    if (pending.output) |output| output.deinit(gpa);
                },
            }
        }
    };

    const Pending = struct {
        call: Tool.Call,
        output: ?Tool.Output,
    };

    const Block = enum { text, reasoning, call };

    const Kept = struct {
        count: usize,
        blocks: usize,

        fn empty(self: *const Kept) bool {
            return self.count == 0;
        }
    };

    fn init(gpa: std.mem.Allocator) Staging {
        return .{
            .gpa = gpa,
            .entries = .empty,
            .text = .empty,
            .failure_message = .empty,
            .text_slot = null,
            .open_block = null,
            .blocks = 0,
            .usage = null,
        };
    }

    fn deinit(self: *Staging) void {
        self.discard();
        self.entries.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.failure_message.deinit(self.gpa);
    }

    fn discard(self: *Staging) void {
        self.release(0);
        self.failure_message.clearRetainingCapacity();
        self.text_slot = null;
        self.open_block = null;
        self.blocks = 0;
        self.usage = null;
    }

    fn release(self: *Staging, kept_count: usize) void {
        for (self.entries.items[kept_count..]) |entry| entry.deinit(self.gpa);
        self.entries.clearRetainingCapacity();
        self.text.clearRetainingCapacity();
    }

    fn openBlock(self: *Staging, block: Block) void {
        self.blocks += 1;
        self.open_block = block;
    }

    fn closeBlock(self: *Staging, block: Block) void {
        if (self.open_block == block) self.open_block = null;
    }

    fn appendText(self: *Staging, delta: []const u8) error{OutOfMemory}!bool {
        const started = self.open_block != .text;
        if (started) {
            try self.flushText();
            self.openBlock(.text);
        }
        if (self.text_slot == null) try self.placeText();
        try self.text.appendSlice(self.gpa, delta);
        return started;
    }

    fn placeText(self: *Staging) error{OutOfMemory}!void {
        try self.entries.append(self.gpa, .{ .kind = .text, .block_end = self.blocks });
        self.text_slot = self.entries.items.len - 1;
    }

    fn flushText(self: *Staging) error{OutOfMemory}!void {
        const slot = self.text_slot orelse return;
        if (self.text.items.len == 0) {
            self.text_slot = null;
            _ = self.entries.orderedRemove(slot);
            return;
        }
        const text = try self.text.toOwnedSlice(self.gpa);
        self.entries.items[slot].kind = .{
            .item = .{ .message = .{ .role = .assistant, .text = text } },
        };
        self.text_slot = null;
    }

    fn keep(self: *Staging, output: *const Provider.Output) error{ Invalid, OutOfMemory }!void {
        switch (output.*) {
            .message => |text| {
                if (text.len == 0) return error.Invalid;
                const copy = try self.gpa.dupe(u8, text);
                errdefer self.gpa.free(copy);
                const item: Conversation.Item = .{
                    .message = .{ .role = .assistant, .text = copy },
                };
                self.closeBlock(.text);
                const slot = self.text_slot orelse {
                    try self.entries.append(self.gpa, .{
                        .kind = .{ .item = item },
                        .block_end = self.blocks,
                    });
                    return;
                };
                self.text_slot = null;
                self.text.clearRetainingCapacity();
                self.entries.items[slot].kind = .{ .item = item };
            },
            .reasoning => |*proof| {
                if (proof.account.len == 0 or proof.payload.len == 0) return error.Invalid;
                const copy = try proof.dupe(self.gpa);
                errdefer copy.deinit(self.gpa);
                try self.entries.append(self.gpa, .{
                    .kind = .{ .item = .{ .reasoning = copy } },
                    .block_end = self.blocks,
                });
                self.closeBlock(.reasoning);
            },
            .tool_call => |*call| {
                if (call.id.len == 0 or self.duplicate(call.id)) return error.Invalid;
                const arguments = call.argumentsJson();
                if (!try objectJson(self.gpa, arguments)) return error.Invalid;
                const source: Tool.Call = .{
                    .id = call.id,
                    .name = call.name,
                    .arguments = arguments,
                };
                const copy = try source.dupe(self.gpa);
                errdefer copy.deinit(self.gpa);
                try self.entries.append(self.gpa, .{
                    .kind = .{ .call = .{ .call = copy, .output = null } },
                    .block_end = self.blocks,
                });
                self.closeBlock(.call);
            },
        }
    }

    fn duplicate(self: *const Staging, id: []const u8) bool {
        for (self.entries.items) |entry| switch (entry.kind) {
            .call => |pending| if (std.mem.eql(u8, pending.call.id, id)) return true,
            .item, .text => {},
        };
        return false;
    }

    fn hasCalls(self: *const Staging) bool {
        for (self.entries.items) |entry| {
            if (entry.kind == .call) return true;
        }
        return false;
    }

    fn callIndexes(self: *const Staging, buffer: *[tool_calls_max]usize) []const usize {
        var count: usize = 0;
        for (self.entries.items, 0..) |entry, index| {
            if (entry.kind != .call) continue;
            buffer[count] = index;
            count += 1;
        }
        return buffer[0..count];
    }

    fn pendingAt(self: *Staging, index: usize) *Pending {
        return &self.entries.items[index].kind.call;
    }

    fn keepFailure(self: *Staging, failure: *const Provider.Failure) Provider.Failure {
        self.failure_message.clearRetainingCapacity();
        self.failure_message.appendSlice(self.gpa, failure.message) catch {};
        return .{
            .reason = failure.reason,
            .retry_after_ms = failure.retry_after_ms,
            .message = self.failure_message.items,
        };
    }

    fn resolve(self: *Staging) error{OutOfMemory}!Kept {
        try self.flushText();
        const entries = self.entries.items;
        var count = entries.len;
        for (entries, 0..) |entry, index| {
            if (entry.kind == .call and entry.kind.call.output == null) {
                count = index;
                break;
            }
        }
        while (count > 0 and entries[count - 1].kind == .item and
            entries[count - 1].kind.item == .reasoning) count -= 1;
        return .{ .count = count, .blocks = if (count > 0) entries[count - 1].block_end else 0 };
    }
};

pub fn run(self: *Turn) End {
    const outcome = self.rounds();
    return .{ .outcome = outcome, .measured = self.measured };
}

fn emit(self: *Turn, event: *const Session.Event) void {
    self.options.sink.emit(self.io, event);
}

fn rounds(self: *Turn) Session.Outcome {
    var staging: Staging = .init(self.gpa);
    defer staging.deinit();
    var round: usize = 0;
    while (round < rounds_max) : (round += 1) {
        const reason = switch (self.step(&staging)) {
            .reply => |reason| reason,
            .ended => |outcome| return outcome,
        };
        const calls = staging.hasCalls();
        if (calls and round + 1 == rounds_max) {
            self.commit(&staging) catch return outOfMemory();
            return .exhausted;
        }
        if (calls) self.answer(&staging) catch |err| {
            self.commit(&staging) catch return outOfMemory();
            return switch (err) {
                error.Canceled => .canceled,
                error.OutOfMemory => outOfMemory(),
            };
        };
        self.commit(&staging) catch return outOfMemory();
        const loaded = self.loadSkills() catch |err| return switch (err) {
            error.Canceled => .canceled,
            error.OutOfMemory => outOfMemory(),
        };
        if (!calls and !loaded) return .{ .stopped = reason };
    }
    return .exhausted;
}

fn outOfMemory() Session.Outcome {
    return .{ .failed = .{ .reason = .out_of_memory } };
}

fn step(self: *Turn, staging: *Staging) Step {
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        switch (self.reply(staging)) {
            .accepted => |reason| return .{ .reply = reason },
            .canceled => return self.endCanceled(staging),
            .failed => |failure| {
                const delay_ms = self.options.retry.delay(attempt, &failure) orelse
                    return self.endFailed(staging, &failure);
                if (staging.blocks > 0) self.emit(&.{ .tail_discarded = staging.blocks });
                self.emit(&.{ .attempt_failed = .{
                    .attempt = attempt,
                    .failure = failure,
                    .delay_ms = delay_ms,
                } });
                staging.discard();
                timeout.sleep(self.io, delay_ms) catch return .{ .ended = .canceled };
            },
        }
    }
}

fn endCanceled(self: *Turn, staging: *Staging) Step {
    self.commit(staging) catch return .{ .ended = outOfMemory() };
    return .{ .ended = .canceled };
}

fn endFailed(self: *Turn, staging: *Staging, failure: *const Provider.Failure) Step {
    const outcome: Session.Outcome = .{ .failed = failure.dupe(self.gpa) };
    self.commit(staging) catch {
        outcome.deinit(self.gpa);
        return .{ .ended = outOfMemory() };
    };
    return .{ .ended = outcome };
}

fn reply(self: *Turn, staging: *Staging) Reply {
    staging.discard();
    const setup = self.setup;
    const request: Provider.Request = .{
        .model = setup.model,
        .system = setup.system,
        .items = self.conversation.items.items,
        .tools = self.options.tools,
        .tokens_max = setup.tokens_max,
        .effort = setup.effort,
        .cache_key = &self.conversation.cache_key,
    };
    setup.provider.open(&request) catch |err| return switch (err) {
        error.Canceled => .canceled,
        error.OutOfMemory => .{ .failed = .{ .reason = .out_of_memory } },
    };
    defer setup.provider.close();
    const stop = switch (self.read(staging, setup.provider)) {
        .stopped => |stop| stop,
        .canceled => return .canceled,
        .failed => |failure| return .{ .failed = failure },
    };
    const calls = staging.hasCalls();
    if (calls and stop.reason != .complete) return .{ .failed = .{ .reason = .invalid_reply } };
    const kept = staging.resolve() catch return .{ .failed = .{ .reason = .out_of_memory } };
    if (!calls and kept.empty()) return .{ .failed = .{ .reason = .empty_reply } };
    if (staging.usage) |usage| self.measure(usage.total(), setup);
    if (stop.model.len != 0 and !std.mem.eql(u8, stop.model, setup.model)) {
        self.emit(&.{ .model_served = .{ .requested = setup.model, .served = stop.model } });
    }
    return .{ .accepted = stop.reason };
}

fn read(self: *Turn, staging: *Staging, provider: Provider) Read {
    var invalid = false;
    var tool_calls: usize = 0;
    for (0..events_max) |_| {
        const maybe_event = provider.next() catch |err| return switch (err) {
            error.Canceled => .canceled,
            error.OutOfMemory => .{ .failed = .{ .reason = .out_of_memory } },
        };
        const event = maybe_event orelse return .{ .failed = .{ .reason = .invalid_reply } };
        switch (event) {
            .stopped => |stop| {
                if (invalid) return .{ .failed = .{ .reason = .invalid_reply } };
                return .{ .stopped = stop };
            },
            .failed => |*failure| return .{ .failed = staging.keepFailure(failure) },
            .output => |*output| {
                if (output.* == .tool_call) {
                    if (tool_calls == tool_calls_max) {
                        return .{ .failed = .{ .reason = .too_many_tool_calls } };
                    }
                    tool_calls += 1;
                }
                if (invalid) continue;
                switch (output.*) {
                    .reasoning => if (staging.open_block != .reasoning)
                        self.startReasoning(staging),
                    .tool_call => |*call| if (staging.open_block != .call)
                        self.startCall(staging, call.name),
                    .message => |text| if (staging.text_slot == null and text.len != 0)
                        self.showMessage(staging, text),
                }
                staging.keep(output) catch |err| switch (err) {
                    error.Invalid => invalid = true,
                    error.OutOfMemory => return .{ .failed = .{ .reason = .out_of_memory } },
                };
            },
            .text => |delta| {
                const started = staging.appendText(delta) catch
                    return .{ .failed = .{ .reason = .out_of_memory } };
                if (started) self.emit(&.text_started);
                self.emit(&.{ .text = delta });
            },
            .reasoning_started => self.startReasoning(staging),
            .reasoning => |delta| {
                if (staging.open_block != .reasoning) self.startReasoning(staging);
                self.emit(&.{ .reasoning = delta });
            },
            .tool_call_started => |name| self.startCall(staging, name),
            .tool_call_arguments => |delta| self.emit(&.{ .tool_call_arguments = delta }),
            .usage => |usage| {
                staging.usage = usage;
                self.emit(&.{ .usage = usage });
            },
            .quota => |quota| self.emit(&.{ .quota = quota }),
            .credits => |credits| self.emit(&.{ .credits = credits }),
        }
    }
    return .{ .failed = .{ .reason = .invalid_reply } };
}

fn startReasoning(self: *Turn, staging: *Staging) void {
    staging.openBlock(.reasoning);
    self.emit(&.reasoning_started);
}

fn startCall(self: *Turn, staging: *Staging, name: []const u8) void {
    staging.openBlock(.call);
    self.emit(&.{ .tool_call_started = name });
}

fn showMessage(self: *Turn, staging: *Staging, text: []const u8) void {
    staging.openBlock(.text);
    self.emit(&.text_started);
    self.emit(&.{ .text = text });
}

fn measure(self: *Turn, tokens: u64, setup: *const Session.Setup) void {
    const account = self.gpa.dupe(u8, setup.account) catch return;
    const model = self.gpa.dupe(u8, setup.model) catch {
        self.gpa.free(account);
        return;
    };
    if (self.measured) |*measured| measured.deinit(self.gpa);
    self.measured = .{
        .tokens = tokens,
        .account = account,
        .model = model,
        .effort = setup.effort,
    };
    self.emit(&.{ .context = tokens });
}

fn answer(self: *Turn, staging: *Staging) Runner.Error!void {
    var buffer: [tool_calls_max]usize = undefined;
    const calls = staging.callIndexes(&buffer);
    var position: usize = 0;
    while (position < calls.len) {
        try self.io.checkCancel();
        const pending = staging.pendingAt(calls[position]);
        if (self.mutates(pending.call.name)) {
            self.emit(&.{ .tool_started = pending.call });
            const output = try self.options.runner.run(self.gpa, &pending.call, self.history());
            self.settle(staging, calls[position], output);
            position += 1;
            continue;
        }
        var batch: Batch = .{ .start = position, .end = position + 1 };
        while (batch.end < calls.len and batch.end - batch.start < read_only_calls_max and
            !self.mutates(staging.pendingAt(calls[batch.end]).call.name)) batch.end += 1;
        position += try self.answerBatch(staging, calls, batch);
    }
}

fn answerBatch(
    self: *Turn,
    staging: *Staging,
    calls: []const usize,
    batch: Batch,
) Runner.Error!usize {
    var futures: [read_only_calls_max]std.Io.Future(Runner.Error!Tool.Output) = undefined;
    var spawned: usize = 0;
    const items = self.history();
    for (calls[batch.start..batch.end]) |index| {
        const call = &staging.pendingAt(index).call;
        const arguments = .{ self.options.runner, self.gpa, call, items };
        futures[spawned] = self.io.concurrent(runCall, arguments) catch break;
        spawned += 1;
        self.emit(&.{ .tool_started = call.* });
    }
    if (spawned == 0) return error.OutOfMemory;
    var joined: usize = 0;
    defer for (futures[joined..spawned]) |*future| {
        if (future.cancel(self.io)) |output| output.deinit(self.gpa) else |_| {}
    };
    while (joined < spawned) : (joined += 1) {
        const output = try futures[joined].await(self.io);
        self.settle(staging, calls[batch.start + joined], output);
    }
    return spawned;
}

fn runCall(
    runner: Runner,
    gpa: std.mem.Allocator,
    call: *const Tool.Call,
    items: []const Conversation.Item,
) Runner.Error!Tool.Output {
    return runner.run(gpa, call, items);
}

fn history(self: *const Turn) []const Conversation.Item {
    return self.conversation.items.items;
}

fn settle(self: *Turn, staging: *Staging, index: usize, output: Tool.Output) void {
    const pending = staging.pendingAt(index);
    pending.output = output;
    self.emit(&.{ .tool_result = .{ .call = pending.call, .output = output } });
}

fn mutates(self: *const Turn, name: []const u8) bool {
    for (self.options.tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool.mutates;
    }
    return false;
}

fn loadSkills(self: *Turn) Runner.Error!bool {
    var loaded = false;
    for (0..skills_max) |_| {
        const items = self.conversation.items.items;
        const skill = (try self.options.runner.takeSkill(self.gpa, items)) orelse break;
        defer {
            self.gpa.free(skill.name);
            self.gpa.free(skill.source);
        }
        self.conversation.append(self.gpa, .{
            .message = .{ .role = .user, .text = skill.text },
        }) catch |err| {
            self.gpa.free(skill.text);
            return err;
        };
        self.emit(&.{ .skill_loaded = .{ .name = skill.name, .source = skill.source } });
        loaded = true;
    }
    return loaded;
}

fn commit(self: *Turn, staging: *Staging) error{OutOfMemory}!void {
    defer staging.discard();
    const kept = try staging.resolve();
    const dropped = staging.blocks - kept.blocks;
    if (dropped > 0) self.emit(&.{ .tail_discarded = dropped });
    const entries = staging.entries.items[0..kept.count];
    var call_count: usize = 0;
    for (entries) |entry| call_count += @intFromBool(entry.kind == .call);
    const count = kept.count + call_count;
    if (count == 0) return;

    var ids: std.ArrayList([]u8) = .empty;
    defer ids.deinit(self.gpa);
    errdefer for (ids.items) |id| self.gpa.free(id);
    try ids.ensureTotalCapacity(self.gpa, call_count);
    for (entries) |entry| switch (entry.kind) {
        .call => |pending| ids.appendAssumeCapacity(try self.gpa.dupe(u8, pending.call.id)),
        .item, .text => {},
    };
    const items = &self.conversation.items;
    try items.ensureUnusedCapacity(self.gpa, count);

    for (entries) |entry| switch (entry.kind) {
        .item => |item| items.appendAssumeCapacity(item),
        .call => |pending| items.appendAssumeCapacity(.{ .tool_call = pending.call }),
        .text => unreachable,
    };
    var id_index: usize = 0;
    for (entries) |entry| switch (entry.kind) {
        .call => |pending| {
            items.appendAssumeCapacity(.{
                .tool_result = .{ .call_id = ids.items[id_index], .output = pending.output.? },
            });
            id_index += 1;
        },
        .item, .text => {},
    };
    staging.release(kept.count);
    self.emit(&.committed);
}

fn objectJson(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!bool {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return false;
    return std.json.validate(gpa, trimmed);
}
