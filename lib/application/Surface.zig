const std = @import("std");
const accounts = @import("accounts");
const core = @import("core");
const tools = @import("tools");
const billing = @import("billing.zig");
const Choice = @import("Choice.zig");
const Controller = @import("Controller.zig");
const Live = @import("Live.zig");
const Record = @import("Record.zig");
const reducer = @import("reducer.zig");
const State = @import("State.zig");
const Transcript = @import("Transcript.zig");
const Turns = @import("Turns.zig");
const Surface = @This();
gpa: std.mem.Allocator,
io: std.Io,
sink: Controller.Sink,
transcript: Transcript,
turn: ?Turn = null,
statistics: Statistics = .{},
statistics_published: Statistics = .{},
choice: Choice,
bash_timeout_ms: u64,
thinking_active: ?usize = null,
muted: bool = false,
answer: std.ArrayList(u8) = .empty,
live_calls: std.ArrayList(Live.Call) = .empty,
live_hash: u64,

pub const Time = struct { awake_ms: i64, boot_ms: i64 };
pub const Statistics = struct {
    cost: f64 = 0,
    context_tokens: ?u64 = 0,
    cache_usage: core.Provider.Usage = .{},
    quota: ?QuotaReading = null,
    credits: ?core.Provider.Credits = null,

    pub const QuotaReading = struct { windows: core.Provider.Quota, seen_ms: i64 };

    fn forgetTurnEvidence(self: *Statistics) void {
        self.cache_usage = .{};
        self.forgetBilling();
    }

    fn forgetBilling(self: *Statistics) void {
        self.quota = null;
        self.credits = null;
    }

    fn charge(
        self: *Statistics,
        usage: *const core.Provider.Usage,
        maybe_model: ?*const accounts.Model,
    ) void {
        const amount = billing.cost(usage, maybe_model) orelse return;
        self.addCost(amount);
    }

    fn addCost(self: *Statistics, amount: f64) void {
        std.debug.assert(std.math.isFinite(amount) and amount >= 0);
        self.cost = @min(self.cost + amount, core.Provider.amount_usd_max);
    }

    fn apply(self: *Statistics, event: *const core.Session.Event, options: *const struct {
        turn_active: bool,
        boot_ms: i64,
        model: ?*const accounts.Model,
    }) void {
        switch (event.*) {
            .context => |tokens| self.context_tokens = tokens,
            .usage => |usage| {
                if (options.turn_active) self.cache_usage = usage;
                self.charge(&usage, options.model);
            },
            .cost => |amount| self.addCost(amount),
            .quota => |quota| self.quota = .{ .windows = quota, .seen_ms = options.boot_ms },
            .credits => |credits| self.credits = credits,
            .setup_dropped,
            .text_started,
            .text,
            .aside_text,
            .aside_reasoning,
            .aside_attempt_failed,
            .aside_ended,
            .reasoning_started,
            .reasoning,
            .tool_call_started,
            .tool_call_arguments,
            .tool_started,
            .tool_result,
            .committed,
            .tail_discarded,
            .model_served,
            .attempt_failed,
            .skill_loaded,
            .turn_ended,
            => {},
        }
    }
};

pub const Turn = struct {
    committed: usize,
    canceled: bool = false,
    blocks: std.ArrayList(Block) = .empty,
    thinking_discarded: std.ArrayList(Transcript.Entry) = .empty,
    served_buffer: [accounts.Model.name_bytes_max]u8 = undefined,
    served_length: usize = 0,

    pub fn deinit(self: *Turn, gpa: std.mem.Allocator) void {
        for (self.thinking_discarded.items) |*entry| entry.deinit(gpa);
        self.thinking_discarded.deinit(gpa);
        self.releaseBlocks(gpa, 0);
        self.blocks.deinit(gpa);
    }

    pub fn releaseBlocks(self: *Turn, gpa: std.mem.Allocator, kept: usize) void {
        for (self.blocks.items[kept..]) |*block| block.deinit(gpa);
        self.blocks.shrinkRetainingCapacity(kept);
    }

    pub fn lastBlock(self: *Turn, kind: Block.Kind) ?*Block {
        const block = self.blocks.lastPtr() orelse return null;
        return if (block.kind == kind) block else null;
    }

    pub fn firstCall(self: *Turn, phases: []const std.meta.Tag(Call.Phase)) ?*Block {
        for (self.blocks.items) |*block| {
            const call = if (block.call) |*call| call else continue;
            for (phases) |phase| {
                if (call.phase == phase) return block;
            }
        }
        return null;
    }

    pub fn callById(self: *Turn, id: []const u8) ?*Block {
        for (self.blocks.items) |*block| {
            const call = if (block.call) |*call| call else continue;
            if (call.phase == .running and std.mem.eql(u8, call.id, id)) return block;
        }
        return null;
    }
};
pub const Block = struct {
    kind: Kind,
    transcript_index: ?usize,
    call: ?Call,

    const Kind = enum { text, reasoning, call };

    fn deinit(self: *Block, gpa: std.mem.Allocator) void {
        if (self.call) |*call| call.deinit(gpa);
    }
};

pub const Call = struct {
    name: []const u8,
    id: []const u8,
    record_id: u64,
    phase: Phase,
    bytes: usize = 0,
    opened_ms: i64,
    description: tools.Registry.Description = .{ .subject = null, .timeout_ms = null },

    pub const Phase = union(enum) { streaming, queued, running: Live.Call.Running, done };

    pub fn init(gpa: std.mem.Allocator, options: *const struct {
        name: []const u8,
        record_id: u64,
        opened_ms: i64,
    }) !Call {
        return .{
            .name = try gpa.dupe(u8, options.name),
            .id = "",
            .record_id = options.record_id,
            .phase = .streaming,
            .opened_ms = options.opened_ms,
        };
    }

    fn deinit(self: *Call, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.id);
        self.description.deinit(gpa);
    }
};
pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    sink: Controller.Sink,
    choice: Choice,
    bash_timeout_ms: u64,
) Surface {
    return .{
        .gpa = gpa,
        .io = io,
        .sink = sink,
        .choice = choice,
        .transcript = .init(gpa),
        .bash_timeout_ms = bash_timeout_ms,
        .live_hash = hashLive(&.{}),
    };
}
pub fn deinit(self: *Surface) void {
    if (self.turn) |*turn| turn.deinit(self.gpa);
    self.transcript.deinit();
    self.answer.deinit(self.gpa);
    self.live_calls.deinit(self.gpa);
}
fn emit(self: *Surface, event: *const Controller.Event) void {
    if (!self.muted) self.sink.emit(self.io, event);
}
pub fn flush(self: *Surface, sink: Controller.Sink, maybe_state: ?*const State) void {
    if (self.muted) {
        self.transcript.sync();
        self.live_hash = hashLive(&self.live());
        self.statistics_published = self.statistics;
        return;
    }
    self.transcript.flush(sink, self.io);
    if (!std.meta.eql(self.statistics, self.statistics_published)) {
        self.statistics_published = self.statistics;
        sink.emit(self.io, &.{ .statistics = self.statistics });
    }
    if (maybe_state) |value| sink.emit(self.io, &.{ .state = value.* });
    const live_now = self.live();
    const hash = hashLive(&live_now);
    if (hash != self.live_hash) {
        self.live_hash = hash;
        sink.emit(self.io, &.{ .live = live_now });
    }
}
pub fn live(self: *Surface) Live {
    self.live_calls.clearRetainingCapacity();
    const turn = self.activeTurn() orelse return .{};
    for (turn.blocks.items) |*block| {
        const call = if (block.call) |*call| call else continue;
        self.live_calls.appendAssumeCapacity(.{
            .id = call.record_id,
            .name = call.name,
            .phase = switch (call.phase) {
                .streaming => .streaming,
                .queued => .queued,
                .running => |running| .{ .running = running },
                .done => continue,
            },
            .argument_bytes = call.bytes,
            .opened_ms = call.opened_ms,
            .description = call.description,
        });
    }
    return .{ .calls = self.live_calls.items, .thinking = self.thinking_active != null };
}
pub fn reserveLive(self: *Surface, count: usize) error{OutOfMemory}!void {
    try self.live_calls.ensureTotalCapacity(self.gpa, count);
}
fn hashLive(state: *const Live) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    std.hash.autoHash(&hasher, state.thinking);
    for (state.calls) |*call| {
        std.hash.autoHash(&hasher, .{
            call.id,
            call.phase,
            call.argument_bytes,
            call.opened_ms,
            call.description.timeout_ms,
            call.name.len,
        });
        hasher.update(call.name);
        const subject = call.description.subject orelse continue;
        std.hash.autoHash(&hasher, .{ subject.kind, subject.text.len });
        hasher.update(subject.text);
    }
    return hasher.final();
}
pub fn beginTurn(self: *Surface) void {
    std.debug.assert(self.turn == null);
    self.transcript.endMessage();
    self.statistics.forgetTurnEvidence();
    self.answer.clearRetainingCapacity();
    self.turn = .{ .committed = self.transcript.entries().len };
}

pub fn applyAccounting(self: *Surface, event: *const core.Session.Event, time: Time) void {
    self.statistics.apply(event, &.{
        .turn_active = self.turn != null,
        .boot_ms = time.boot_ms,
        .model = self.chosenModel(),
    });
}

pub fn chosenModel(self: *const Surface) ?*const accounts.Model {
    return if (self.choice.model) |*found| found else null;
}

pub fn describeCall(self: *Surface, call: *Call, tool_call: *const core.Tool.Call) !void {
    const description = try tools.Registry.describe(self.gpa, tool_call, self.bash_timeout_ms);
    call.description.deinit(self.gpa);
    call.description = description;
    if (!std.mem.eql(u8, call.name, tool_call.name)) {
        const name = try self.gpa.dupe(u8, tool_call.name);
        self.gpa.free(call.name);
        call.name = name;
    }
}
pub fn appendUnknownResult(
    self: *Surface,
    result: *const core.Session.Event.ToolResult,
    now_ms: i64,
) !void {
    const description = try tools.Registry.describe(self.gpa, &result.call, self.bash_timeout_ms);
    defer description.deinit(self.gpa);
    try self.transcript.append(&.{ .tool_result = .{
        .name = result.call.name,
        .description = description,
        .output = result.output,
        .started_ms = now_ms,
        .received_bytes = result.call.arguments.len,
    } }, .{});
}

pub fn appendCallResult(
    self: *Surface,
    call: *const Call,
    result: *const core.Session.Event.ToolResult,
    options: *const struct { now_ms: i64, canceled: bool },
) !usize {
    const index = self.transcript.entries().len;
    try self.transcript.append(&.{ .tool_result = .{
        .name = call.name,
        .description = call.description,
        .output = result.output,
        .elapsed_ms = switch (call.phase) {
            .running => |running| if (options.canceled)
                options.now_ms - running.started_ms
            else
                null,
            .streaming, .queued, .done => null,
        },
        .started_ms = call.opened_ms,
        .received_bytes = result.call.arguments.len,
    } }, .{ .id = call.record_id });
    return index;
}

pub fn endTurn(self: *Surface, outcome: *const core.Session.Outcome) void {
    if (self.turn) |*turn| turn.deinit(self.gpa);
    self.transcript.retained = 0;
    self.turn = null;
    self.transcript.endMessage();
    self.thinking_active = null;
    self.emit(&.{ .turn_ended = .{ .outcome = outcome.*, .answer = self.answer.items } });
}

pub fn activeTurn(self: *Surface) ?*Turn {
    return if (self.turn) |*turn| turn else null;
}

pub fn clearConversation(self: *Surface) void {
    self.transcript.clear();
    self.statistics = .{};
    self.emit(&.clear_conversation);
}
pub fn showChoice(self: *Surface, choice: *const Choice) void {
    if (self.choice.account != choice.account) self.statistics.forgetBilling();
    self.choice = choice.*;
}
pub fn appendEvent(self: *Surface, event: *const Record.Event) !void {
    try self.transcript.append(&.{ .event = event.* }, .{ .survives_discard = true });
    self.transcript.closeWork(&.{
        .time_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds(),
        .status = .complete,
    });
}
pub fn appendAuthorization(self: *Surface, authorization: *const Record.Authorization) !void {
    try self.transcript.append(
        &.{ .authorization = authorization.* },
        .{ .survives_discard = true },
    );
    self.transcript.closeWork(&.{
        .time_ms = std.Io.Timestamp.now(self.io, .awake).toMilliseconds(),
        .status = .complete,
    });
}
pub fn appendUser(self: *Surface, text: []const u8) !void {
    try self.transcript.append(&.{ .user = text }, .{});
}
pub fn appendRetryNote(self: *Surface) !void {
    try self.transcript.append(&.{ .user_note = .retry }, .{});
}
pub fn appendSkillNote(self: *Surface, skill: *const core.Session.Event.SkillLoaded) !void {
    try self.transcript.append(&.{ .user_note = .{ .skill = skill.* } }, .{});
}
pub fn replaceEvent(self: *Surface, index: usize, event: *const Record.Event) !void {
    try self.transcript.replaceEvent(index, event);
}
pub fn rewind(self: *Surface, dropped: []const Turns.Turn) void {
    for (0..dropped.len) |offset| self.transcript.remove(dropped[dropped.len - 1 - offset].range);
}
pub fn apply(self: *Surface, event: *const core.Session.Event, time: Time) !?core.Session.Outcome {
    return reducer.apply(self, event, time);
}
