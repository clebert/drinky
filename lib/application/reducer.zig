const std = @import("std");
const core = @import("core");
const Record = @import("Record.zig");
const Surface = @import("Surface.zig");
const testing = @import("testing.zig");
const turn_text = @import("turn_text.zig");

const canceled_event = "You canceled the turn.";

pub fn apply(
    self: *Surface,
    event: *const core.Session.Event,
    time: Surface.Time,
) !?core.Session.Outcome {
    self.applyAccounting(event, time);
    const turn = self.activeTurn() orelse return null;
    switch (event.*) {
        .setup_dropped,
        .aside_text,
        .aside_reasoning,
        .aside_attempt_failed,
        .aside_ended,
        => unreachable,
        .text_started => {
            finishThinking(self);
            try beginText(self, turn);
        },
        .text => |delta| {
            if (turn.lastBlock(.text) == null) {
                finishThinking(self);
                try beginText(self, turn);
            }
            try self.transcript.appendStream(.model, delta);
            const block = turn.lastBlock(.text).?;
            if (block.transcript_index == null) {
                block.transcript_index = self.transcript.runIndex();
                if (block.transcript_index != null)
                    self.transcript.closeWork(&.{ .time_ms = time.awake_ms, .status = .complete });
            }
        },
        .reasoning_started => try beginThinking(self, turn, time.awake_ms),
        .reasoning => |delta| {
            if (turn.lastBlock(.reasoning) == null or self.thinking_active == null) {
                try beginThinking(self, turn, time.awake_ms);
            } else if (self.transcript.runIndex() != self.thinking_active) {
                _ = try openThinking(self, time.awake_ms);
            }
            try self.transcript.appendStream(.thinking, delta);
        },
        .tool_call_started => |name| {
            finishThinking(self);
            try startCall(self, turn, name, time.awake_ms);
        },
        .tool_call_arguments => |delta| growCall(turn, delta),
        .tool_started => |*call| {
            finishThinking(self);
            try runCall(self, turn, call, time);
        },
        .tool_result => |*result| {
            finishThinking(self);
            try settleCall(self, turn, result, time.awake_ms);
        },
        .committed => {
            finishThinking(self);
            self.transcript.endMessage();
            try self.transcript.writeAnswer(turn.committed, &self.answer);
            turn.committed = self.transcript.entries().len;
            turn.releaseBlocks(self.gpa, 0);
        },
        .tail_discarded => |count| try discardTail(self, turn, count),
        .usage, .cost, .quota, .credits, .context => {},
        .model_served => |served| try recordServed(self, turn, &served, time),
        .attempt_failed => |*attempt| {
            finishThinking(self);
            restoreThinking(self, turn);
            self.transcript.endMessage();
            const uncommitted = self.transcript.entries()[turn.committed..];
            const status: Record.Work.Status = for (uncommitted) |*entry| {
                if (entry.record.work != null) break .failed;
            } else .complete;
            const message = try Surface.attemptMessage(self.gpa, attempt);
            defer message.deinit(self.gpa);
            try self.transcript.append(
                &.{ .event = .{ .text = message.content, .severity = message.severity } },
                .{ .survives_discard = true },
            );
            self.transcript.closeWork(&.{ .time_ms = time.awake_ms, .status = status });
        },
        .skill_loaded => |*loaded| {
            finishThinking(self);
            self.transcript.endMessage();
            try self.transcript.append(&.{ .user_note = .{ .skill = loaded.* } }, .{});
            self.transcript.closeWork(&.{ .time_ms = time.awake_ms, .status = .complete });
        },
        .turn_ended => |outcome| {
            const status: Record.Work.Status = switch (outcome) {
                .stopped => |reason| switch (reason) {
                    .complete => .complete,
                    .truncated => .truncated,
                },
                .canceled => .canceled,
                .failed, .exhausted => .failed,
            };
            finishThinking(self);
            if (status != .complete) restoreThinking(self, turn);
            self.transcript.endMessage();
            try recordOutcome(self, &outcome);
            self.transcript.closeWork(&.{ .time_ms = time.awake_ms, .status = status });
            self.endTurn(&outcome);
            return outcome;
        },
    }
    return null;
}

fn beginThinking(self: *Surface, turn: *Surface.Turn, now_ms: i64) !void {
    try turn.blocks.ensureUnusedCapacity(self.gpa, 1);
    const index = try openThinking(self, now_ms);
    turn.blocks.appendAssumeCapacity(
        .{ .kind = .reasoning, .transcript_index = index, .call = null },
    );
}

fn openThinking(self: *Surface, now_ms: i64) !usize {
    const index = try self.transcript.beginThinking(now_ms);
    self.thinking_active = index;
    return index;
}

fn finishThinking(self: *Surface) void {
    self.thinking_active = null;
}

fn beginText(self: *Surface, turn: *Surface.Turn) !void {
    self.transcript.endMessage();
    try turn.blocks.append(self.gpa, .{ .kind = .text, .transcript_index = null, .call = null });
    self.transcript.beginRun(.model);
}

fn startCall(self: *Surface, turn: *Surface.Turn, name: []const u8, now_ms: i64) !void {
    self.transcript.endMessage();
    try self.reserveLive(turn.blocks.items.len + 1);
    try turn.blocks.ensureUnusedCapacity(self.gpa, 1);
    if (turn.firstCall(&.{.streaming})) |block| block.call.?.phase = .queued;
    const call = try Surface.Call.init(self.gpa, &.{
        .name = name,
        .record_id = self.transcript.allocateId(),
        .opened_ms = now_ms,
    });
    turn.blocks.appendAssumeCapacity(.{ .kind = .call, .transcript_index = null, .call = call });
}

fn growCall(turn: *Surface.Turn, delta: []const u8) void {
    const block = turn.firstCall(&.{.streaming}) orelse return;
    block.call.?.bytes += delta.len;
}

fn runCall(
    self: *Surface,
    turn: *Surface.Turn,
    started: *const core.Tool.Call,
    time: Surface.Time,
) !void {
    const block = turn.firstCall(&.{ .streaming, .queued }) orelse return;
    const call = &block.call.?;
    try self.describeCall(call, started);
    const id = try self.gpa.dupe(u8, started.id);
    self.gpa.free(call.id);
    call.id = id;
    call.phase = .running;
    call.started_ms = time.awake_ms;
    while (turn.firstCall(&.{.streaming})) |later| later.call.?.phase = .queued;
}

fn settleCall(
    self: *Surface,
    turn: *Surface.Turn,
    result: *const core.Session.Event.ToolResult,
    now_ms: i64,
) !void {
    const block = turn.callById(result.call.id) orelse
        turn.firstCall(&.{ .running, .queued, .streaming }) orelse
        return self.appendUnknownResult(result, now_ms);
    const call = &block.call.?;
    const ran = call.phase == .running;
    if (!ran) try self.describeCall(call, &result.call);
    const canceled = result.output.conditions.contains(.canceled);
    block.transcript_index = try self.appendCallResult(call, result, &.{
        .ran = ran,
        .now_ms = now_ms,
        .canceled = canceled,
    });
    call.phase = .done;
}

fn discardTail(self: *Surface, turn: *Surface.Turn, count: usize) !void {
    self.transcript.endMessage();
    const kept = turn.blocks.items.len -| count;
    var first: ?usize = null;
    for (turn.blocks.items[kept..]) |block| {
        const index = block.transcript_index orelse continue;
        first = if (first) |found| @min(found, index) else index;
    }
    if (first) |index| {
        const discarded = @max(index, turn.committed);
        try self.transcript.takeThinking(discarded, &turn.thinking_discarded);
        for (turn.blocks.items[0..kept]) |block| {
            if (block.kind != .call) continue;
            const retained = block.transcript_index orelse continue;
            if (retained >= discarded) self.transcript.list.items[retained].survives_discard = true;
        }
        for (turn.blocks.items[0..kept]) |*block| {
            const retained = block.transcript_index orelse continue;
            if (retained < discarded) continue;
            var removed: usize = 0;
            for (self.transcript.entries()[discarded..retained]) |*entry|
                removed += @intFromBool(!entry.survives_discard);
            block.transcript_index = retained - removed;
        }
        if (self.thinking_active) |active| if (active >= discarded) finishThinking(self);
        self.transcript.discard(discarded);
    }
    turn.releaseBlocks(self.gpa, kept);
}

fn restoreThinking(self: *Surface, turn: *Surface.Turn) void {
    self.transcript.restoreThinking(&turn.thinking_discarded);
}

fn recordServed(
    self: *Surface,
    turn: *Surface.Turn,
    served: *const core.Session.Event.ModelServed,
    time: Surface.Time,
) !void {
    if (self.chosenModel()) |model| {
        if (model.sameName(served.requested) and model.serves(served.served)) return;
    }
    const reported = turn.served_buffer[0..turn.served_length];
    const length = @min(served.served.len, turn.served_buffer.len);
    if (std.mem.eql(u8, reported, served.served[0..length])) return;
    @memcpy(turn.served_buffer[0..length], served.served[0..length]);
    turn.served_length = length;
    self.transcript.endMessage();
    const text = try self.gpa.print(
        "The provider answered with the model \"{s}\" instead of the requested model \"{s}\".",
        .{ served.served, served.requested },
    );
    defer self.gpa.free(text);
    try self.transcript.append(&.{ .event = .{ .text = text, .severity = .warning } }, .{});
    self.transcript.closeWork(&.{ .time_ms = time.awake_ms, .status = .complete });
}

fn recordOutcome(self: *Surface, outcome: *const core.Session.Outcome) !void {
    switch (outcome.*) {
        .stopped => |reason| switch (reason) {
            .complete => {},
            .truncated => try self.transcript.append(&.{ .event = .{
                .text = turn_text.truncated.content,
                .severity = turn_text.truncated.severity,
            } }, .{}),
        },
        .canceled => try self.transcript.append(&.{ .event = .{ .text = canceled_event } }, .{}),
        .exhausted => try appendFailure(self, turn_text.exhausted),
        .failed => |*failure| {
            const text = try turn_text.failureText(self.gpa, failure);
            defer self.gpa.free(text);
            try appendFailure(self, text);
        },
    }
}

fn appendFailure(self: *Surface, text: []const u8) !void {
    try self.transcript.append(&.{ .event = .{ .text = text, .severity = .failure } }, .{});
}

test "a turn reduction frees each partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkReductionAllocations,
        .{},
    );
}

fn checkReductionAllocations(gpa: std.mem.Allocator) error{OutOfMemory}!void {
    var reduction: testing.Reduction = undefined;
    reduction.init(gpa, .{ .effort = .high });
    defer reduction.deinit();
    try reduction.start("prompt");
    const call: core.Tool.Call = .{
        .id = "call",
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    };
    const events = [_]core.Session.Event{
        .reasoning_started,
        .{ .reasoning = "first" },
        .reasoning_started,
        .{ .reasoning = "discard" },
        .{ .tail_discarded = 1 },
        .reasoning_started,
        .{ .reasoning = "second" },
        .{ .tool_call_started = "read" },
        .{ .tool_call_arguments = call.arguments },
        .{ .tool_started = call },
        .{ .tool_result = .{ .call = call, .output = .{ .content = "text" } } },
        .text_started,
        .{ .text = "answer" },
        .{ .model_served = .{ .requested = "requested", .served = "served" } },
        .{ .attempt_failed = .{
            .attempt = 1,
            .failure = .{ .reason = .overloaded },
            .delay_ms = 0,
        } },
        .{ .text = "again" },
        .committed,
        .{ .turn_ended = .{ .stopped = .complete } },
    };
    for (&events) |*event| _ = try reduction.apply(event, .{ .awake_ms = 1, .boot_ms = 1 });
    try reduction.start("next");
    const canceled = [_]core.Session.Event{
        .reasoning_started,
        .{ .reasoning = "partial" },
        .{ .tail_discarded = 1 },
        .{ .turn_ended = .canceled },
    };
    for (&canceled) |*event| _ = try reduction.apply(event, .{ .awake_ms = 2, .boot_ms = 2 });
}
