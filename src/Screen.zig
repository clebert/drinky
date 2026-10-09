const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");
const terminal = @import("terminal");
const tools = @import("tools");

const Choice = @import("Choice.zig");
const command = @import("command/root.zig");
const format = @import("format.zig");
const layout = @import("layout.zig");
const Message = @import("Message.zig");
const project = @import("project.zig");
const testing = @import("testing.zig");
const tool_line = @import("tool_line.zig");
const Transcript = @import("Transcript.zig");
const turn_text = @import("turn_text.zig");
const Turns = @import("Turns.zig");
const ui = @import("ui/root.zig");

const Screen = @This();

const canceled_event = "You canceled the turn.";

pub const editor_caption_rows_max: usize = 3;

gpa: std.mem.Allocator,
transcript: Transcript,
notice: ?Message,
editor: ui.Editor,
view: terminal.View,
page_view: terminal.View,
widget: Widget,
columns: usize,
rows: usize,
statistics: Statistics,
choice: Choice,
directory_shown: []const u8,
branch_buffer: [project.head_bytes_max]u8,
branch_length: usize,
bash_timeout_ms: u64,
window_pages: usize,
gauge: ui.status.Gauge,
display_roots: format.Roots,
transcript_mode: ui.Block.Mode = .full,
repaint_transcript: bool = false,
thinking_active: ?usize = null,
thinking_joinable: bool = false,

pub const Time = struct {
    awake_ms: i64,
    boot_ms: i64,
};

const Statistics = struct {
    cost: f64 = 0,
    context_tokens: ?u64 = 0,
    cache_usage: core.Provider.Usage = .{},
    quota: ?core.Provider.Quota = null,
    quota_seen_ms: i64 = 0,
    credits: ?core.Provider.Credits = null,
    attempt_usage: ?core.Provider.Usage = null,

    fn forgetTurnEvidence(self: *Statistics) void {
        self.cache_usage = .{};
        self.quota_seen_ms = 0;
        self.attempt_usage = null;
        self.forgetBilling();
    }

    fn forgetBilling(self: *Statistics) void {
        self.quota = null;
        self.credits = null;
    }

    fn charge(self: *Statistics, maybe_model: ?*const accounts.Model) void {
        const usage = self.attempt_usage orelse return;
        self.attempt_usage = null;
        const model = maybe_model orelse return;
        const cost = usage.cost_usd orelse model.cost(&usage) orelse return;
        self.cost = @min(self.cost + cost, core.Provider.amount_usd_max);
    }
};

pub const Widget = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
    page: ui.Page,
};

const Turn = struct {
    committed: usize,
    blocks: std.ArrayList(Block),
    thinking_discarded: std.ArrayList(ui.Block),
    served_buffer: [accounts.Model.name_bytes_max]u8,
    served_length: usize,
    activity_tick: u64,
    progress_tick_last: u64,
    caret_tick: u64,
    box_view: std.ArrayList(ui.paint.Box),
    box_hashes: std.ArrayList(u64),
    box_tracks: std.ArrayList(layout.Track),

    fn init(committed: usize) Turn {
        return .{
            .committed = committed,
            .blocks = .empty,
            .thinking_discarded = .empty,
            .served_buffer = undefined,
            .served_length = 0,
            .activity_tick = 0,
            .progress_tick_last = 0,
            .caret_tick = 0,
            .box_view = .empty,
            .box_hashes = .empty,
            .box_tracks = .empty,
        };
    }

    fn deinit(self: *Turn, gpa: std.mem.Allocator) void {
        for (self.thinking_discarded.items) |*block| block.deinit(gpa);
        self.thinking_discarded.deinit(gpa);
        self.releaseBlocks(gpa, 0);
        self.blocks.deinit(gpa);
        self.box_view.deinit(gpa);
        self.box_hashes.deinit(gpa);
        self.box_tracks.deinit(gpa);
    }

    fn releaseBlocks(self: *Turn, gpa: std.mem.Allocator, kept: usize) void {
        for (self.blocks.items[kept..]) |*block| block.deinit(gpa);
        self.blocks.shrinkRetainingCapacity(kept);
    }

    fn activity(self: *const Turn) ui.paint.Activity {
        return .{
            .motion_tick = self.activity_tick,
            .progress_age_ticks = self.activity_tick -% self.progress_tick_last,
            .caret_tick = self.caret_tick,
        };
    }

    fn lastBlock(self: *Turn, kind: Block.Kind) ?*Block {
        const block = self.blocks.lastPtr() orelse return null;
        return if (block.kind == kind) block else null;
    }

    fn firstCall(self: *Turn, phases: []const Call.Phase) ?*Block {
        for (self.blocks.items) |*block| {
            const call = if (block.call) |*call| call else continue;
            for (phases) |phase| {
                if (call.phase == phase) return block;
            }
        }
        return null;
    }

    fn callById(self: *Turn, id: []const u8) ?*Block {
        for (self.blocks.items) |*block| {
            const call = if (block.call) |*call| call else continue;
            if (call.phase == .running and std.mem.eql(u8, call.id, id)) return block;
        }
        return null;
    }

    fn boxes(
        self: *Turn,
        gpa: std.mem.Allocator,
        options: struct { now_ms: i64, compact: bool },
    ) ![]const ui.paint.Box {
        self.box_view.clearRetainingCapacity();
        for (self.blocks.items) |*block| {
            const call = if (block.call) |*call| call else continue;
            if (call.phase == .done) continue;
            try self.box_view.append(gpa, .{
                .text = try call.text(gpa, options.now_ms),
                .fit = .head,
                .emphasis = .first_value,
                .compact = options.compact,
            });
        }
        return self.box_view.items;
    }

    fn trackBoxes(self: *Turn, gpa: std.mem.Allocator) ![]layout.Track {
        std.debug.assert(self.box_tracks.items.len == self.box_hashes.items.len);
        const count = self.box_view.items.len;
        try self.box_tracks.ensureTotalCapacity(gpa, count);
        try self.box_hashes.ensureTotalCapacity(gpa, count);
        for (self.box_view.items, 0..) |box, index| {
            const hash = std.hash.Wyhash.hash(0, box.text);
            if (index < self.box_hashes.items.len) {
                self.box_tracks.items[index].changed = self.box_hashes.items[index] != hash;
                self.box_hashes.items[index] = hash;
            } else {
                self.box_tracks.appendAssumeCapacity(.{ .changed = true });
                self.box_hashes.appendAssumeCapacity(hash);
            }
        }
        self.box_tracks.shrinkRetainingCapacity(count);
        self.box_hashes.shrinkRetainingCapacity(count);
        return self.box_tracks.items;
    }
};

const Block = struct {
    kind: Kind,
    transcript_index: ?usize,
    call: ?Call,

    const Kind = enum { text, reasoning, call };

    fn deinit(self: *Block, gpa: std.mem.Allocator) void {
        if (self.call) |*call| call.deinit(gpa);
    }
};

const Call = struct {
    name: []const u8,
    id: []const u8,
    phase: Phase,
    bytes: usize,
    box: std.ArrayList(u8),
    started_ms: i64,
    timeout_ms: ?u64,
    rows: std.ArrayList(u8),

    const Phase = enum { streaming, queued, running, done };

    fn init(gpa: std.mem.Allocator, name: []const u8) !Call {
        var call: Call = .{
            .name = try gpa.dupe(u8, name),
            .id = "",
            .phase = .streaming,
            .bytes = 0,
            .box = .empty,
            .started_ms = 0,
            .timeout_ms = null,
            .rows = .empty,
        };
        errdefer call.deinit(gpa);
        try call.refresh(gpa);
        return call;
    }

    fn deinit(self: *Call, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.id);
        self.box.deinit(gpa);
        self.rows.deinit(gpa);
    }

    fn refresh(self: *Call, gpa: std.mem.Allocator) !void {
        var bytes_buffer: [16]u8 = undefined;
        self.box.clearRetainingCapacity();
        try self.box.print(gpa, "Tool: {s} · Received: {s} · Status: {s}", .{
            self.name,
            format.bytes(&bytes_buffer, self.bytes),
            switch (self.phase) {
                .streaming, .queued => @tagName(self.phase),
                .running, .done => unreachable,
            },
        });
    }

    fn text(self: *Call, gpa: std.mem.Allocator, now_ms: i64) ![]const u8 {
        if (self.phase != .running) return self.box.items;
        const timeout_ms = self.timeout_ms orelse return self.box.items;
        var elapsed_buffer: [24]u8 = undefined;
        var limit_buffer: [24]u8 = undefined;
        const limit = format.durationSeconds(&limit_buffer, @intCast(timeout_ms), .up);
        self.rows.clearRetainingCapacity();
        try self.rows.print(gpa, "{s}\nTime: {s} · Timeout: {s}", .{
            self.box.items,
            format.durationSeconds(&elapsed_buffer, now_ms - self.started_ms, .down),
            limit,
        });
        return self.rows.items;
    }
};

const Picking = struct {
    picker: ui.Picker,
    selector: *const fn (
        *command.Context,
        command.Context.Outcome.Pick.Selection,
    ) command.Context.Error!command.Context.Outcome,
    payload: usize,
    cancellation_message: []const u8,
    reopen: ?command.Context.Outcome.Opener,
    trail: Trail,
    wait_tick: ?u64,

    pub fn select(
        self: *const Picking,
        context: *command.Context,
        row: usize,
    ) command.Context.Error!command.Context.Outcome {
        return self.selector(context, .{ .payload = self.payload, .row = row });
    }

    fn activity(self: *const Picking) ?ui.paint.Activity {
        const tick = self.wait_tick orelse return null;
        return .{ .motion_tick = tick, .progress_age_ticks = 0 };
    }
};

const Trail = struct {
    entries: [8]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        open: command.Context.Outcome.Opener,
        position: ui.Picker.Position,
    };

    fn push(
        self: *Trail,
        position: ui.Picker.Position,
        opener: ?command.Context.Outcome.Opener,
    ) void {
        const open = opener orelse {
            self.len = 0;
            return;
        };
        if (self.len == self.entries.len) {
            std.mem.copyForwards(
                Entry,
                self.entries[0 .. self.len - 1],
                self.entries[1..self.len],
            );
            self.len -= 1;
        }
        self.entries[self.len] = .{ .open = open, .position = position };
        self.len += 1;
    }

    fn last(self: *const Trail) ?Entry {
        return if (self.len == 0) null else self.entries[self.len - 1];
    }

    fn dropLast(self: *Trail) void {
        if (self.len > 0) self.len -= 1;
    }
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, effort: core.Provider.Effort) Screen {
    var self: Screen = .{
        .gpa = gpa,
        .transcript = Transcript.init(gpa),
        .notice = null,
        .editor = ui.Editor.init(gpa),
        .view = terminal.View.init(gpa, writer),
        .page_view = terminal.View.init(gpa, writer),
        .widget = .prompt,
        .columns = 80,
        .rows = 24,
        .statistics = .{},
        .choice = .{ .effort = effort },
        .directory_shown = "",
        .branch_buffer = undefined,
        .branch_length = 0,
        .bash_timeout_ms = (tools.Context.Bash{}).timeout_ms,
        .window_pages = layout.window_pages_default,
        .gauge = .{},
        .display_roots = .{},
    };
    self.page_view.preserveScrollback();
    return self;
}

pub fn deinit(self: *Screen) void {
    self.deinitWidget();
    self.clearNotice();
    self.transcript.deinit();
    self.page_view.deinit();
    self.view.deinit();
    self.editor.deinit();
}

pub fn toggleTranscript(self: *Screen) void {
    self.transcript_mode = switch (self.transcript_mode) {
        .full => .compact,
        .compact => .full,
    };
    self.repaint_transcript = true;
}

pub fn clearConversation(self: *Screen) void {
    std.debug.assert(self.widget == .prompt);
    self.clearNotice();
    self.transcript.truncate(0);
    self.statistics = .{};
    self.view.resetScreen();
}

pub fn showChoice(self: *Screen, choice: *const Choice) void {
    if (self.choice.account != choice.account) self.statistics.forgetBilling();
    self.choice = choice.*;
}

pub fn clearNotice(self: *Screen) void {
    if (self.notice) |notice| {
        notice.deinit(self.gpa);
        self.notice = null;
    }
}

pub fn setNotice(self: *Screen, notice: Message) void {
    self.clearNotice();
    self.notice = notice;
}

fn showNotice(self: *Screen, severity: Message.Severity, text: []const u8) !void {
    self.setNotice(.{ .content = try self.gpa.dupe(u8, text), .severity = severity });
}

fn deinitWidget(self: *Screen) void {
    switch (self.widget) {
        .prompt => {},
        .turn => |*turn| turn.deinit(self.gpa),
        .picking => |*picking| picking.picker.deinit(),
        .page => |*page| page.deinit(),
    }
}

pub fn beginTurn(self: *Screen) void {
    std.debug.assert(self.widget == .prompt);
    self.transcript.endMessage();
    self.statistics.forgetTurnEvidence();
    self.widget = .{ .turn = .init(self.transcript.blocks().len) };
}

pub fn rewind(self: *Screen, dropped: []const Turns.Turn) !void {
    std.debug.assert(self.widget == .prompt);
    try self.editor.prependText(dropped[0].line.?);
    for (0..dropped.len) |offset| self.transcript.remove(dropped[dropped.len - 1 - offset].range);
    self.view.resetScreen();
    self.markEdited();
}

pub fn apply(
    self: *Screen,
    event: *const core.Session.Event,
    time: Time,
) !?core.Session.Outcome {
    const turn = self.activeTurn() orelse return self.applyIdle(event, time);
    switch (event.*) {
        .setup_dropped => unreachable,
        .text_started => {
            self.finishThinking(time.awake_ms, .complete);
            try self.beginText(turn);
        },
        .text => |delta| {
            if (turn.lastBlock(.text) == null) {
                self.finishThinking(time.awake_ms, .complete);
                try self.beginText(turn);
            }
            try self.transcript.appendStream(.model, delta);
            const block = turn.lastBlock(.text).?;
            block.transcript_index = block.transcript_index orelse self.transcript.runIndex();
        },
        .reasoning_started => try self.beginThinking(turn, time.awake_ms),
        .reasoning => |delta| {
            if (turn.lastBlock(.reasoning) == null or self.thinking_active == null) {
                try self.beginThinking(turn, time.awake_ms);
            } else if (self.transcript.runIndex() != self.thinking_active) {
                _ = try self.openThinking(time.awake_ms);
            }
            try self.transcript.appendStream(.thinking, delta);
        },
        .tool_call_started => |name| {
            self.finishThinking(time.awake_ms, .complete);
            try self.startCall(turn, name);
        },
        .tool_call_arguments => |delta| try self.growCall(turn, delta),
        .tool_started => |*call| {
            self.finishThinking(time.awake_ms, .complete);
            try self.runCall(turn, call, time);
        },
        .tool_result => |*result| {
            self.finishThinking(time.awake_ms, .complete);
            try self.settleCall(turn, result);
        },
        .committed => {
            if (self.thinking_active) |index| {
                const thinking = &self.transcript.block_list.items[index].thinking.?;
                thinking.ended_ms = thinking.ended_ms orelse time.awake_ms;
                thinking.status = .complete;
            }
            self.thinking_joinable = false;
            self.statistics.charge(self.chosenModel());
            self.transcript.endMessage();
            turn.committed = self.transcript.blocks().len;
            turn.releaseBlocks(self.gpa, 0);
        },
        .tail_discarded => |count| try self.discardTail(turn, .{
            .count = count,
            .now_ms = time.awake_ms,
        }),
        .usage => |usage| {
            self.statistics.cache_usage = usage;
            self.statistics.attempt_usage = usage;
        },
        .quota => |quota| {
            self.statistics.quota = quota;
            self.statistics.quota_seen_ms = time.boot_ms;
        },
        .credits => |credits| self.statistics.credits = credits,
        .context => |tokens| self.statistics.context_tokens = tokens,
        .model_served => |served| try self.recordServed(turn, &served),
        .attempt_failed => |*attempt| {
            self.finishThinking(time.awake_ms, .failed);
            try self.restoreThinking(turn, time.awake_ms, .failed);
            self.statistics.charge(self.chosenModel());
            self.transcript.endMessage();
            const text = try attemptText(self.gpa, attempt);
            defer self.gpa.free(text);
            try self.transcript.append(&.{ .event = .{ .text = text, .survives_discard = true } });
        },
        .skill_loaded => |*loaded| {
            self.finishThinking(time.awake_ms, .complete);
            self.transcript.endMessage();
            try self.appendSkillNote(loaded);
        },
        .turn_ended => |outcome| {
            const status: ui.Block.Thinking.Status = switch (outcome) {
                .stopped => |reason| switch (reason) {
                    .complete => .complete,
                    .truncated => .truncated,
                },
                .canceled => .canceled,
                .failed, .exhausted => .failed,
            };
            self.finishThinking(time.awake_ms, status);
            if (status != .complete) try self.restoreThinking(turn, time.awake_ms, status);
            self.statistics.charge(self.chosenModel());
            self.transcript.endMessage();
            try self.recordOutcome(&outcome);
            self.endTurn();
            return outcome;
        },
    }
    turn.progress_tick_last = turn.activity_tick;
    return null;
}

fn applyIdle(
    self: *Screen,
    event: *const core.Session.Event,
    time: Time,
) !?core.Session.Outcome {
    switch (event.*) {
        .context => |tokens| self.statistics.context_tokens = tokens,
        .quota => |quota| {
            self.statistics.quota = quota;
            self.statistics.quota_seen_ms = time.boot_ms;
        },
        .credits => |credits| self.statistics.credits = credits,
        else => {},
    }
    return null;
}

fn chosenModel(self: *const Screen) ?*const accounts.Model {
    return if (self.choice.model) |*found| found else null;
}

fn beginThinking(self: *Screen, turn: *Turn, now_ms: i64) !void {
    try turn.blocks.ensureUnusedCapacity(self.gpa, 1);
    const index = try self.openThinking(now_ms);
    turn.blocks.appendAssumeCapacity(.{
        .kind = .reasoning,
        .transcript_index = index,
        .call = null,
    });
}

fn openThinking(self: *Screen, now_ms: i64) !usize {
    const joins_previous = self.thinking_joinable and
        self.transcript.runIndex() == self.thinking_active;
    self.finishThinking(now_ms, .complete);
    const index = try self.transcript.beginThinking(&.{
        .started_ms = now_ms,
        .ended_ms = null,
        .status = .streaming,
        .joins_previous = joins_previous,
    });
    self.thinking_active = index;
    self.thinking_joinable = true;
    return index;
}

fn finishThinking(self: *Screen, now_ms: i64, status: ui.Block.Thinking.Status) void {
    const index = self.thinking_active orelse return;
    const thinking = &self.transcript.block_list.items[index].thinking.?;
    if (thinking.ended_ms == null or status == .truncated) thinking.status = status;
    thinking.ended_ms = thinking.ended_ms orelse now_ms;
    self.thinking_active = null;
    self.thinking_joinable = false;
}

fn beginText(self: *Screen, turn: *Turn) !void {
    self.transcript.endMessage();
    try turn.blocks.append(self.gpa, .{
        .kind = .text,
        .transcript_index = null,
        .call = null,
    });
    self.transcript.beginRun(.model);
}

fn startCall(self: *Screen, turn: *Turn, name: []const u8) !void {
    self.transcript.endMessage();
    if (turn.firstCall(&.{.streaming})) |block| {
        block.call.?.phase = .queued;
        try block.call.?.refresh(self.gpa);
    }
    var call = try Call.init(self.gpa, name);
    errdefer call.deinit(self.gpa);
    try turn.blocks.append(self.gpa, .{ .kind = .call, .transcript_index = null, .call = call });
}

fn growCall(self: *Screen, turn: *Turn, delta: []const u8) !void {
    const block = turn.firstCall(&.{.streaming}) orelse return;
    block.call.?.bytes += delta.len;
    try block.call.?.refresh(self.gpa);
}

fn runCall(self: *Screen, turn: *Turn, started: *const core.Tool.Call, time: Time) !void {
    const block = turn.firstCall(&.{ .streaming, .queued }) orelse return;
    const call = &block.call.?;
    try self.describeCall(call, started);
    const id = try self.gpa.dupe(u8, started.id);
    self.gpa.free(call.id);
    call.id = id;
    call.phase = .running;
    call.started_ms = time.awake_ms;
    while (turn.firstCall(&.{.streaming})) |later| {
        later.call.?.phase = .queued;
        try later.call.?.refresh(self.gpa);
    }
}

fn settleCall(self: *Screen, turn: *Turn, result: *const core.Session.Event.ToolResult) !void {
    const block = turn.callById(result.call.id) orelse
        turn.firstCall(&.{ .running, .queued, .streaming }) orelse
        return self.appendUnknownResult(result);
    const call = &block.call.?;
    if (call.phase != .running) try self.describeCall(call, &result.call);
    call.phase = .done;
    block.transcript_index = try self.appendToolBlock(call.box.items, &result.output);
}

fn describeCall(self: *Screen, call: *Call, tool_call: *const core.Tool.Call) !void {
    const description = try tools.Registry.describe(self.gpa, tool_call, self.bash_timeout_ms);
    defer description.deinit(self.gpa);
    const head = try tool_line.head(self.gpa, tool_call.name, &description, &self.display_roots);
    defer self.gpa.free(head);
    call.box.clearRetainingCapacity();
    try call.box.appendSlice(self.gpa, head);
    call.timeout_ms = description.timeout_ms;
}

fn appendUnknownResult(self: *Screen, result: *const core.Session.Event.ToolResult) !void {
    const head = try self.gpa.print("Tool: {s}", .{result.call.name});
    defer self.gpa.free(head);
    _ = try self.appendToolBlock(head, &result.output);
}

fn appendToolBlock(self: *Screen, head: []const u8, output: *const core.Tool.Output) !usize {
    const failed = output.hasFailure();
    const line = try tool_line.render(self.gpa, output);
    defer line.deinit(self.gpa);
    switch (line) {
        .none => try self.transcript.append(&.{ .tool_result = .{
            .text = head,
            .failed = failed,
        } }),
        .measures => |detail| {
            const text = try self.gpa.print("{s}\n{s}", .{ head, detail });
            defer self.gpa.free(text);
            try self.transcript.append(&.{ .tool_result = .{ .text = text, .failed = failed } });
        },
        .sentence => |sentence| {
            const text = try self.gpa.print("{s}\nError: {s}", .{ head, sentence });
            defer self.gpa.free(text);
            try self.transcript.append(&.{ .tool_result = .{
                .text = text,
                .failed = failed,
                .fit = .wrap,
            } });
        },
    }
    return self.transcript.blocks().len - 1;
}

fn discardTail(
    self: *Screen,
    turn: *Turn,
    options: struct { count: usize, now_ms: i64 },
) !void {
    self.transcript.endMessage();
    const kept = turn.blocks.items.len -| options.count;
    var first: ?usize = null;
    for (turn.blocks.items[kept..]) |block| {
        const index = block.transcript_index orelse continue;
        first = if (first) |found| @min(found, index) else index;
    }
    if (first) |index| {
        const discarded = @max(index, turn.committed);
        const held = turn.thinking_discarded.items.len;
        try self.transcript.takeThinking(discarded, &turn.thinking_discarded);
        for (turn.thinking_discarded.items[held..]) |*block| {
            const thinking = &block.thinking.?;
            thinking.ended_ms = thinking.ended_ms orelse options.now_ms;
        }
        for (turn.blocks.items[0..kept]) |block| {
            if (block.kind != .call) continue;
            const retained = block.transcript_index orelse continue;
            const result = &self.transcript.block_list.items[retained].content.tool_result;
            if (retained >= discarded) result.survives_discard = true;
        }
        for (turn.blocks.items[0..kept]) |*block| {
            const retained = block.transcript_index orelse continue;
            if (retained < discarded) continue;
            var removed: usize = 0;
            for (self.transcript.blocks()[discarded..retained]) |*item|
                removed += @intFromBool(!item.survivesDiscard());
            block.transcript_index = retained - removed;
        }
        if (self.thinking_active) |active| if (active >= discarded) {
            self.thinking_active = null;
            self.thinking_joinable = false;
        };
        self.transcript.discard(discarded);
    }
    turn.releaseBlocks(self.gpa, kept);
}

fn restoreThinking(
    self: *Screen,
    turn: *Turn,
    now_ms: i64,
    status: ui.Block.Thinking.Status,
) error{OutOfMemory}!void {
    try self.transcript.block_list.ensureUnusedCapacity(
        self.gpa,
        turn.thinking_discarded.items.len,
    );
    for (turn.thinking_discarded.items) |*block| {
        const thinking = &block.thinking.?;
        if (thinking.status == .streaming) {
            thinking.ended_ms = thinking.ended_ms orelse now_ms;
            thinking.status = status;
        }
        self.transcript.block_list.appendAssumeCapacity(block.*);
    }
    turn.thinking_discarded.clearRetainingCapacity();
}

fn recordServed(self: *Screen, turn: *Turn, served: *const core.Session.Event.ModelServed) !void {
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
    try self.transcript.append(&.{ .event = .{ .text = text, .severity = .warning } });
}

fn recordOutcome(self: *Screen, outcome: *const core.Session.Outcome) !void {
    switch (outcome.*) {
        .stopped => |reason| switch (reason) {
            .complete => {},
            .truncated => try self.appendFailure(turn_text.truncated),
        },
        .canceled => try self.transcript.append(&.{ .event = .{ .text = canceled_event } }),
        .exhausted => try self.appendFailure(turn_text.exhausted),
        .failed => |*failure| {
            const text = try turn_text.failureText(self.gpa, failure);
            defer self.gpa.free(text);
            try self.appendFailure(text);
        },
    }
}

fn attemptText(gpa: std.mem.Allocator, attempt: *const core.Session.Event.Attempt) ![]u8 {
    var buffer: [24]u8 = undefined;
    const delay = tools.format.duration(&buffer, @intCast(@min(
        attempt.delay_ms,
        std.math.maxInt(i64),
    )));
    const sentence = turn_text.failureSentence(attempt.failure.reason);
    if (attempt.failure.message.len == 0) return gpa.print(
        "Attempt {d} failed. {s} Drinky tries again in {s}.",
        .{ attempt.attempt, sentence, delay },
    );
    return gpa.print(
        "Attempt {d} failed. {s} Drinky tries again in {s}. Details: {s}",
        .{ attempt.attempt, sentence, delay, attempt.failure.message },
    );
}

fn appendFailure(self: *Screen, text: []const u8) !void {
    try self.transcript.append(&.{ .event = .{ .text = text, .severity = .failure } });
}

pub fn appendEvent(self: *Screen, message: Message) !void {
    defer message.deinit(self.gpa);
    try self.transcript.append(&.{ .event = .{
        .text = message.content,
        .severity = message.severity,
    } });
}

pub fn appendUser(self: *Screen, text: []const u8) !void {
    try self.transcript.append(&.{ .user = text });
}

pub fn appendSkillNote(self: *Screen, skill: *const core.Session.Event.SkillLoaded) !void {
    const path = try format.path(self.gpa, skill.source, &self.display_roots);
    defer self.gpa.free(path);
    const text = try self.gpa.print("Skill: {s} · File: {s}", .{ skill.name, path });
    defer self.gpa.free(text);
    try self.appendNote(text);
}

pub fn appendNote(self: *Screen, text: []const u8) !void {
    try self.transcript.append(&.{ .user_note = text });
}

pub fn appendIntro(self: *Screen, text: []const u8) !void {
    try self.transcript.append(&.{ .intro = text });
}

pub fn replaceEvent(self: *Screen, index: usize, message: Message) !void {
    defer message.deinit(self.gpa);
    try self.transcript.replaceEvent(index, &.{
        .text = message.content,
        .severity = message.severity,
    });
}

pub fn setDraft(self: *Screen, text: []const u8) !void {
    self.editor.clear();
    try self.editor.insert(text);
    self.markEdited();
}

pub fn openPicker(self: *Screen, pick: *const command.Context.Outcome.Pick) !void {
    var trail: Trail = .{};
    if (self.widget == .picking) {
        trail = self.widget.picking.trail;
        if (!sameStep(&self.widget.picking.reopen, &pick.reopen))
            trail.push(self.widget.picking.picker.position(), self.widget.picking.reopen);
    }
    return self.enterPicker(pick, trail, null);
}

fn sameStep(
    step: *const ?command.Context.Outcome.Opener,
    other: *const ?command.Context.Outcome.Opener,
) bool {
    const step_open = step.* orelse return false;
    const other_open = other.* orelse return false;
    return step_open.eql(other_open);
}

pub fn openPickerAbove(self: *Screen, pick: *const command.Context.Outcome.Pick) !void {
    std.debug.assert(self.widget == .picking);
    var trail = self.widget.picking.trail;
    const entry = trail.last().?;
    trail.dropLast();
    return self.enterPicker(pick, trail, entry.position);
}

pub fn stepAbove(self: *const Screen) ?command.Context.Outcome.Opener {
    return switch (self.widget) {
        .picking => |*picking| if (picking.trail.last()) |entry| entry.open else null,
        else => null,
    };
}

fn enterPicker(
    self: *Screen,
    pick: *const command.Context.Outcome.Pick,
    trail: Trail,
    position: ?ui.Picker.Position,
) !void {
    errdefer freePickerOptions(self.gpa, pick.options);
    if (pick.report) |message| try self.appendEvent(message);
    const picker = try ui.Picker.init(self.gpa, pick.title, pick.options, &.{
        .current = pick.current,
        .preselected = pick.preselected,
        .position = position,
        .can_step_back = trail.len > 0,
    });
    self.deinitWidget();
    self.widget = .{ .picking = .{
        .picker = picker,
        .selector = pick.select,
        .payload = pick.payload,
        .cancellation_message = pick.cancellation_message,
        .reopen = pick.reopen,
        .trail = trail,
        .wait_tick = null,
    } };
}

fn freePickerOptions(gpa: std.mem.Allocator, options: []const ui.Picker.Option) void {
    for (options) |*option| option.deinit(gpa);
    gpa.free(options);
}

pub fn closePicker(self: *Screen) void {
    switch (self.widget) {
        .picking => |*picking| {
            picking.picker.deinit();
            self.widget = .prompt;
        },
        else => {},
    }
}

pub fn beginPickerWait(self: *Screen, text: []const u8) !void {
    const picking = &self.widget.picking;
    try picking.picker.beginWait(text);
    picking.wait_tick = 0;
}

pub fn cancelPicker(self: *Screen) !void {
    const cancellation_message = switch (self.widget) {
        .picking => |picking| picking.cancellation_message,
        else => return,
    };
    self.closePicker();
    try self.showNotice(.information, cancellation_message);
}

pub fn openPage(self: *Screen, options: *const ui.Page.Options) !void {
    std.debug.assert(self.widget == .prompt);
    var page = try ui.Page.init(self.gpa, options);
    page.reflow(.{ .columns = self.columns, .rows = self.rows });
    self.page_view.forget();
    self.page_view.resetScreen();
    self.widget = .{ .page = page };
}

pub fn closePage(self: *Screen) void {
    switch (self.widget) {
        .page => |*page| {
            page.deinit();
            self.widget = .prompt;
        },
        else => {},
    }
}

pub fn setBranch(self: *Screen, name: []const u8) void {
    std.debug.assert(name.len <= self.branch_buffer.len);
    if (std.mem.eql(u8, self.branch_buffer[0..self.branch_length], name)) return;
    @memcpy(self.branch_buffer[0..name.len], name);
    self.branch_length = name.len;
}

fn branch(self: *const Screen) ?[]const u8 {
    if (self.branch_length == 0) return null;
    return self.branch_buffer[0..self.branch_length];
}

fn endTurn(self: *Screen) void {
    if (self.activeTurn()) |turn| turn.deinit(self.gpa);
    self.clearNotice();
    self.widget = .prompt;
    self.transcript.endMessage();
}

pub fn paint(
    self: *Screen,
    window_size: terminal.View.Size,
    time: Time,
    caption: *const ?ui.Caption,
) !void {
    const size: terminal.View.Size = .{
        .columns = @max(window_size.columns, 1),
        .rows = @max(window_size.rows, 1),
    };
    self.columns = size.columns;
    self.rows = size.rows;
    switch (self.widget) {
        .page => |*page| {
            page.reflow(size);
            const scene: layout.Scene = .{ .page = page };
            try layout.project(self.gpa, &self.page_view, size, &scene);
            return;
        },
        else => {},
    }

    self.transcript.present(self.transcript_mode, time.awake_ms);
    const status = self.statusInfo(time.boot_ms);

    const tail: layout.Tail = switch (self.widget) {
        .prompt => prompt: {
            self.editor.reflow(size);
            break :prompt .{
                .prompt = .{
                    .caption = caption.*,
                    .editor = &self.editor,
                },
            };
        },
        .turn => |*turn| turn: {
            self.editor.reflow(size);
            const boxes = try turn.boxes(self.gpa, .{
                .now_ms = time.awake_ms,
                .compact = self.transcript_mode == .compact,
            });
            const tracks = try turn.trackBoxes(self.gpa);
            break :turn .{
                .turn = .{
                    .tools = boxes,
                    .tracks = tracks,
                    .activity = turn.activity(),
                    .editor = &self.editor,
                },
            };
        },
        .picking => |*picking| picking: {
            try picking.picker.reflow(size);
            break :picking .{ .picking = .{
                .picker = &picking.picker,
                .activity = picking.activity(),
            } };
        },
        .page => unreachable,
    };
    const scene: layout.Scene = .{ .conversation = .{
        .window_pages = self.window_pages,
        .repaint = self.repaint_transcript,
        .mode = self.transcript_mode,
        .transcript = self.transcript.block_list.items,
        .tail = tail,
        .status = &status,
    } };
    try layout.project(self.gpa, &self.view, size, &scene);
    self.repaint_transcript = false;
}

fn statusInfo(self: *const Screen, boot_ms: i64) ui.status.Info {
    return .{
        .directory = self.directory_shown,
        .branch = self.branch(),
        .context_tokens = self.statistics.context_tokens,
        .cache_usage = self.statistics.cache_usage,
        .cost = self.statistics.cost,
        .context_window = if (self.choice.model) |found| found.context_window else null,
        .model = if (self.choice.model) |*found| found.name() else null,
        .effort = @tagName(self.choice.effort),
        .account = self.choice.accountId(),
        .quota = self.statistics.quota,
        .quota_age_ms = boot_ms - self.statistics.quota_seen_ms,
        .credits = self.statistics.credits,
        .turn_active = self.widget == .turn,
        .gauge = self.gauge,
        .notice = self.notice,
    };
}

pub fn parkCursor(self: *Screen) !void {
    try self.view.parkCursor();
}

pub fn markEdited(self: *Screen) void {
    if (self.activeTurn()) |turn| turn.caret_tick = 0;
}

pub fn advanceFrame(self: *Screen) bool {
    var activity_changed = false;
    switch (self.widget) {
        .turn => |*turn| {
            turn.activity_tick +%= 1;
            turn.caret_tick +%= 1;
            const activity = turn.activity();
            activity_changed = ui.paint.activityChanged(&activity, self.columns);
        },
        .picking => |*picking| if (picking.wait_tick) |*tick| {
            tick.* +%= 1;
            const activity = picking.activity().?;
            activity_changed = ui.paint.activityChanged(&activity, self.columns);
        },
        .prompt, .page => {},
    }
    return activity_changed;
}

pub fn animating(self: *const Screen) bool {
    return switch (self.widget) {
        .turn => true,
        .picking => |*picking| picking.wait_tick != null,
        .prompt, .page => false,
    };
}

pub fn activePicker(self: *Screen) ?*ui.Picker {
    return switch (self.widget) {
        .picking => |*picking| &picking.picker,
        .prompt, .turn, .page => null,
    };
}

pub fn activePage(self: *Screen) ?*ui.Page {
    return switch (self.widget) {
        .page => |*page| page,
        .prompt, .turn, .picking => null,
    };
}

fn activeTurn(self: *Screen) ?*Turn {
    return switch (self.widget) {
        .turn => |*turn| turn,
        else => null,
    };
}

test "a turn streams reasoning and text into blocks, commits them, and ends at the prompt" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try std.testing.expect(rig.screen.widget == .turn);

    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "weigh " });
    try rig.apply(&.{ .reasoning = "it" });
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "hel" });
    try rig.apply(&.{ .text = "lo" });
    try rig.apply(&.{ .usage = .{ .input = 1_000_000, .output = 1_000_000 } });
    try rig.apply(&.{ .context = 2_000_000 });
    try rig.expectKinds(&.{ .user, .thinking, .model });
    try std.testing.expectEqualStrings("weigh it", rig.blocks()[1].content.thinking.items);
    try std.testing.expectEqualStrings("hello", rig.blocks()[2].content.model.items);
    try std.testing.expectEqual(@as(f64, 0), rig.screen.statusInfo(0).cost);

    try rig.apply(&.committed);
    try std.testing.expectApproxEqAbs(@as(f64, 18), rig.screen.statusInfo(0).cost, 1e-9);
    try std.testing.expectEqual(@as(?u64, 2_000_000), rig.screen.statusInfo(0).context_tokens);

    try rig.end(&.{ .stopped = .complete });
    try rig.expectKinds(&.{ .user, .thinking, .model });
    const painted = try rig.paintPlain(80);
    defer std.testing.allocator.free(painted);
    try testing.expectContains(painted, "hello");
    try testing.expectContains(painted, "weigh it");
}

fn testModel() accounts.Model {
    var model = accounts.Model.init("claude-sonnet-4-6") catch unreachable;
    model.context_window = 1_000_000;
    model.thinking = .supported;
    model.addEffort(.low);
    model.addEffort(.high);
    model.price = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 };
    return model;
}

const Rig = struct {
    out: std.Io.Writer.Allocating,
    screen: Screen,
    time: Time,

    fn init(self: *Rig) void {
        const gpa = std.testing.allocator;
        self.out = .init(gpa);
        self.screen = Screen.init(gpa, &self.out.writer, .high);
        self.screen.showChoice(&.{
            .account = accounts.testing.anthropic_plan,
            .model = testModel(),
            .effort = .high,
        });
        self.time = .{ .awake_ms = 0, .boot_ms = 0 };
    }

    fn deinit(self: *Rig) void {
        self.screen.deinit();
        self.out.deinit();
    }

    fn start(self: *Rig, text: []const u8) !void {
        try self.screen.appendUser(text);
        self.screen.beginTurn();
    }

    fn apply(self: *Rig, event: *const core.Session.Event) !void {
        try std.testing.expect((try self.screen.apply(event, self.time)) == null);
    }

    fn end(self: *Rig, outcome: *const core.Session.Outcome) !void {
        const ended = (try self.screen.apply(&.{ .turn_ended = outcome.* }, self.time)) orelse
            return error.TestExpectedTurnEnd;
        try std.testing.expectEqual(std.meta.activeTag(outcome.*), std.meta.activeTag(ended));
        try std.testing.expect(self.screen.widget == .prompt);
    }

    fn blocks(self: *const Rig) []const ui.Block {
        return self.screen.transcript.blocks();
    }

    fn expectKinds(self: *const Rig, expected: []const ui.Block.Kind) !void {
        const actual = self.blocks();
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |kind, block| {
            try std.testing.expectEqual(kind, std.meta.activeTag(block.content));
        }
    }

    fn eventText(self: *const Rig, index: usize) []const u8 {
        return self.blocks()[index].content.event.text.items;
    }

    fn paintPlain(self: *Rig, columns: usize) ![]u8 {
        self.out.clearRetainingCapacity();
        try self.screen.paint(.{ .columns = columns, .rows = 24 }, self.time, &no_caption);
        return terminal.testing.plainText(std.testing.allocator, self.out.written());
    }
};

const no_caption: ?ui.Caption = null;

fn expectSummary(painted: []const u8, rows: *const [2][]const u8) !void {
    var lines = std.mem.splitScalar(u8, painted, '\n');
    var previous: []const u8 = "";
    while (lines.next()) |line| {
        const row = std.mem.trim(u8, line, "\r ");
        if (std.mem.eql(u8, previous, rows[0]) and std.mem.eql(u8, row, rows[1])) return;
        previous = row;
    }
    std.debug.print("expected the rows \"{s}\" and \"{s}\" in:\n{s}\n", .{
        rows[0],
        rows[1],
        painted,
    });
    return error.TestExpectedSummary;
}

fn checkCompactAllocations(gpa: std.mem.Allocator) error{OutOfMemory}!void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var screen = Screen.init(gpa, &out.writer, .high);
    defer screen.deinit();
    screen.toggleTranscript();
    try screen.appendUser("prompt");
    screen.beginTurn();
    const call: core.Tool.Call = .{
        .id = "call",
        .name = "read",
        .arguments = "{\"path\":\"src/App.zig\"}",
    };
    var output: core.Tool.Output = .{ .content = "text" };
    output.measures.put(.lines, 1);
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
        .{ .tool_result = .{ .call = call, .output = output } },
        .committed,
        .{ .turn_ended = .{ .stopped = .complete } },
    };
    for (&events) |*event| _ = try screen.apply(event, .{ .awake_ms = 2_000, .boot_ms = 2_000 });
    try screen.appendUser("next");
    screen.beginTurn();
    const canceled = [_]core.Session.Event{
        .reasoning_started,
        .{ .reasoning = "partial" },
        .{ .tail_discarded = 1 },
        .{ .turn_ended = .canceled },
    };
    for (&canceled) |*event| _ = try screen.apply(event, .{ .awake_ms = 4_000, .boot_ms = 4_000 });
    screen.toggleTranscript();
}

test "compact reasoning and tool events free each partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkCompactAllocations,
        .{},
    );
}

test "an active thinking summary above the frame keeps its current measurements and final status" {
    const gpa = std.testing.allocator;
    const size: terminal.View.Size = .{ .columns = 80, .rows = 2 };
    var device: terminal.testing.FakeDevice = undefined;
    try device.init(gpa, std.testing.io, size);
    defer device.deinit();
    var screen = Screen.init(gpa, device.device().writer(), .high);
    defer screen.deinit();
    screen.window_pages = 1;
    screen.toggleTranscript();
    try screen.appendUser("prompt");
    screen.beginTurn();
    var time: Time = .{ .awake_ms = 0, .boot_ms = 0 };
    _ = try screen.apply(&.reasoning_started, time);
    _ = try screen.apply(&.{ .reasoning = "abc" }, time);
    try screen.paint(size, time, &no_caption);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const first = try device.snapshot(arena.allocator());
    try expectSummary(
        try std.mem.join(arena.allocator(), "\n", first.rows),
        &.{ "Thinking: streaming", "Received: 3 B · Time: 0s" },
    );
    time.awake_ms = 3_000;
    _ = try screen.apply(&.{ .reasoning = "def" }, time);
    try screen.paint(size, time, &no_caption);
    const active = try device.snapshot(arena.allocator());
    const active_rows = try std.mem.join(arena.allocator(), "\n", active.rows);
    try expectSummary(active_rows, &.{ "Thinking: streaming", "Received: 6 B · Time: 3s" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, active_rows, "Thinking:"));
    time.awake_ms = 4_000;
    _ = try screen.apply(&.committed, time);
    _ = try screen.apply(&.{ .turn_ended = .{ .stopped = .complete } }, time);
    try screen.paint(size, time, &no_caption);
    const complete = try device.snapshot(arena.allocator());
    const complete_rows = try std.mem.join(arena.allocator(), "\n", complete.rows);
    try expectSummary(complete_rows, &.{ "Thinking: complete", "Received: 6 B · Time: 4s" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, complete_rows, "Thinking:"));
}

test "a thinking update inside the frame keeps all history above the visible screen" {
    const gpa = std.testing.allocator;
    const size: terminal.View.Size = .{ .columns = 80, .rows = 8 };
    var device: terminal.testing.FakeDevice = undefined;
    try device.init(gpa, std.testing.io, size);
    defer device.deinit();
    var screen = Screen.init(gpa, device.device().writer(), .high);
    defer screen.deinit();
    for (0..100) |index| {
        const text = try gpa.print("message-{d}", .{index});
        defer gpa.free(text);
        try screen.appendUser(text);
    }
    try screen.setDraft("line1\nline2\nline3\nline4\nline5");
    screen.beginTurn();
    var time: Time = .{ .awake_ms = 0, .boot_ms = 0 };
    _ = try screen.apply(&.reasoning_started, time);
    _ = try screen.apply(&.{ .reasoning = "abc" }, time);
    screen.toggleTranscript();
    try screen.paint(size, time, &no_caption);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const first = try device.snapshot(arena.allocator());
    var first_count: usize = 0;
    for (first.rows) |row| first_count += @intFromBool(std.mem.startsWith(u8, row, "message-"));
    try std.testing.expectEqual(@as(usize, 100), first_count);
    time.awake_ms = 3_000;
    _ = try screen.apply(&.{ .reasoning = "def" }, time);
    try screen.paint(size, time, &no_caption);
    const active = try device.snapshot(arena.allocator());
    var active_count: usize = 0;
    for (active.rows) |row| {
        active_count += @intFromBool(std.mem.startsWith(u8, row, "message-"));
    }
    try std.testing.expectEqual(@as(usize, 100), active_count);
    try expectSummary(
        try std.mem.join(arena.allocator(), "\n", active.rows),
        &.{ "Thinking: streaming", "Received: 6 B · Time: 3s" },
    );
}

test "a mode toggle repaints the complete transcript beyond the window limit" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.window_pages = 1;
    for (0..60) |index| {
        const text = try gpa.print("message-{d}", .{index});
        defer gpa.free(text);
        try rig.screen.appendUser(text);
    }
    const recent = try rig.paintPlain(80);
    defer gpa.free(recent);
    try std.testing.expect(std.mem.find(u8, recent, "message-0") == null);
    for (0..2) |_| {
        rig.screen.toggleTranscript();
        const repainted = try rig.paintPlain(80);
        defer gpa.free(repainted);
        try std.testing.expectEqual(@as(usize, 60), std.mem.count(u8, repainted, "message-"));
        try testing.expectContains(repainted, "message-0");
        try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[3J") != null);
        const unchanged = try rig.paintPlain(80);
        defer gpa.free(unchanged);
        try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[3J") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), rig.screen.window_pages);
}

test "compact thinking joins consecutive blocks and keeps its text and final timer" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.toggleTranscript();
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    rig.time.awake_ms = 2_000;
    const empty = try rig.paintPlain(80);
    defer gpa.free(empty);
    try expectSummary(empty, &.{ "Thinking: streaming", "Received: 0 B · Time: 2s" });

    try rig.apply(&.{ .reasoning = "alpha" });
    rig.time.awake_ms = 3_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "βeta" });
    rig.time.awake_ms = 6_000;
    rig.screen.toggleTranscript();
    rig.screen.toggleTranscript();
    const active = try rig.paintPlain(80);
    defer gpa.free(active);
    try expectSummary(active, &.{ "Thinking: streaming", "Received: 10 B · Time: 6s" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, active, "Thinking:"));
    try std.testing.expect(std.mem.find(u8, active, "alpha") == null);
    try std.testing.expect(std.mem.find(u8, active, "βeta") == null);

    rig.time.awake_ms = 7_000;
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    rig.time.awake_ms = 90_000;
    rig.screen.toggleTranscript();
    rig.screen.toggleTranscript();
    const complete = try rig.paintPlain(80);
    defer gpa.free(complete);
    try expectSummary(complete, &.{ "Thinking: complete", "Received: 10 B · Time: 7s" });
    try testing.expectContains(complete, "answer");

    rig.screen.toggleTranscript();
    const full = try rig.paintPlain(80);
    defer gpa.free(full);
    try testing.expectContains(full, "alpha");
    try testing.expectContains(full, "βeta");
    try std.testing.expect(std.mem.find(u8, full, "Thinking:") == null);
}

test "full mode adds no rows for thinking without visible text" {
    const gpa = std.testing.allocator;
    var expected: ?[]u8 = null;
    defer if (expected) |text| gpa.free(text);
    for ([_]?[]const u8{ null, "", " \n" }) |maybe_thinking| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        try rig.start("prompt");
        if (maybe_thinking) |thinking| {
            try rig.apply(&.reasoning_started);
            try rig.apply(&.{ .reasoning = thinking });
        }
        try rig.apply(&.text_started);
        try rig.apply(&.{ .text = "answer" });
        try rig.apply(&.committed);
        try rig.end(&.{ .stopped = .complete });
        const painted = try rig.paintPlain(80);
        if (expected) |text| {
            defer gpa.free(painted);
            try std.testing.expectEqualStrings(text, painted);
        } else {
            expected = painted;
        }
    }
}

test "thinking reports each terminal outcome and freezes its measurements" {
    const outcomes = [_]core.Session.Outcome{
        .{ .stopped = .complete },
        .canceled,
        .{ .failed = .{ .reason = .empty_reply } },
        .exhausted,
        .{ .stopped = .truncated },
    };
    const statuses = [_][]const u8{ "complete", "canceled", "failed", "failed", "truncated" };
    for (&outcomes, statuses) |*outcome, status| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        rig.screen.toggleTranscript();
        try rig.start("prompt");
        rig.time.awake_ms = 1_000;
        try rig.apply(&.reasoning_started);
        try rig.apply(&.{ .reasoning = "abc" });
        rig.time.awake_ms = 4_000;
        if (outcome.* == .stopped and outcome.stopped == .complete) {
            try rig.apply(&.committed);
        } else {
            try rig.apply(&.{ .tail_discarded = 1 });
        }
        rig.time.awake_ms = 10_000;
        try rig.end(outcome);
        rig.time.awake_ms = 50_000;
        const painted = try rig.paintPlain(80);
        defer std.testing.allocator.free(painted);
        const expected = try std.testing.allocator.print("Thinking: {s}", .{status});
        defer std.testing.allocator.free(expected);
        try expectSummary(painted, &.{ expected, "Received: 3 B · Time: 3s" });
    }
}

test "a retry keeps the failed thinking summary separate from the new attempt" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.toggleTranscript();
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "first" });
    rig.time.awake_ms = 1_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "second" });
    rig.time.awake_ms = 2_000;
    try rig.apply(&.{ .tail_discarded = 2 });
    rig.time.awake_ms = 9_000;
    try rig.apply(&.{ .attempt_failed = .{
        .attempt = 1,
        .failure = .{ .reason = .overloaded },
        .delay_ms = 0,
    } });
    rig.time.awake_ms = 10_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "new" });
    rig.time.awake_ms = 12_000;
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try expectSummary(painted, &.{ "Thinking: failed", "Received: 11 B · Time: 2s" });
    try expectSummary(painted, &.{ "Thinking: complete", "Received: 3 B · Time: 2s" });
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, painted, "Thinking:"));
}

test "thinking groups stop at committed attempts and tool calls" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.toggleTranscript();
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "a" });
    rig.time.awake_ms = 2_000;
    try rig.apply(&.committed);
    rig.time.awake_ms = 5_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "bb" });
    rig.time.awake_ms = 6_000;
    try rig.apply(&.{ .tool_call_started = "read" });
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try expectSummary(painted, &.{ "Thinking: complete", "Received: 1 B · Time: 2s" });
    try expectSummary(painted, &.{ "Thinking: complete", "Received: 2 B · Time: 1s" });
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, painted, "Thinking:"));
}

test "a discard removes every part of a text run that a model notice split" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("prompt");
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "discard-before" });
    try rig.apply(&.{ .model_served = .{ .requested = "requested", .served = "served" } });
    try rig.apply(&.{ .text = "discard-after" });
    try rig.apply(&.{ .tail_discarded = 1 });
    try rig.end(&.{ .stopped = .complete });
    const painted = try rig.paintPlain(80);
    defer std.testing.allocator.free(painted);
    try testing.expectContains(painted, "prompt");
    try std.testing.expect(std.mem.find(u8, painted, "discard-before") == null);
    try std.testing.expect(std.mem.find(u8, painted, "discard-after") == null);
}

test "thinking after a model notice keeps its counter and terminal status" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.toggleTranscript();
    try rig.start("prompt");
    rig.time.awake_ms = 1_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "aaa" });
    rig.time.awake_ms = 2_000;
    try rig.apply(&.{ .model_served = .{ .requested = "requested", .served = "served" } });
    rig.time.awake_ms = 3_000;
    try rig.apply(&.{ .reasoning = "bbbb" });
    rig.time.awake_ms = 5_000;
    try rig.end(&.canceled);
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try expectSummary(painted, &.{ "Thinking: complete", "Received: 3 B · Time: 2s" });
    try expectSummary(painted, &.{ "Thinking: canceled", "Received: 4 B · Time: 2s" });
}

test "a discarded thinking block no longer contributes to its compact summary" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.toggleTranscript();
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "a" });
    rig.time.awake_ms = 2_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "discard" });
    const active = try rig.paintPlain(80);
    defer gpa.free(active);
    try testing.expectContains(active, "Received: 8 B");
    try rig.apply(&.{ .tail_discarded = 1 });
    rig.time.awake_ms = 8_000;
    try rig.end(&.{ .stopped = .complete });
    rig.screen.toggleTranscript();
    rig.screen.toggleTranscript();
    const complete = try rig.paintPlain(80);
    defer gpa.free(complete);
    try expectSummary(complete, &.{ "Thinking: complete", "Received: 1 B · Time: 2s" });
}

test "a tool call streams as a row, runs with its subject and timer, and ends as a block" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.bash_timeout_ms = 120_000;
    try rig.start("run it");

    try rig.apply(&.{ .tool_call_started = "bash" });
    try rig.apply(&.{ .tool_call_arguments = "{\"command\":" });
    try rig.apply(&.{ .tool_call_arguments = "\"zig build\"}" });
    const streamed = try rig.paintPlain(80);
    defer gpa.free(streamed);
    try testing.expectContains(streamed, "Tool: bash · Received: 23 B · Status: streaming");

    rig.time.awake_ms = 1_000;
    try rig.apply(&.{ .tool_started = .{
        .id = "c1",
        .name = "bash",
        .arguments = "{\"command\":\"zig build\"}",
    } });
    rig.time.awake_ms = 13_400;
    const running = try rig.paintPlain(80);
    defer gpa.free(running);
    try testing.expectContains(running, "Tool: bash · Command: zig build");
    try testing.expectContains(running, "Time: 12s · Timeout: 2m 0s");

    var output: core.Tool.Output = .{ .content = "ok\n" };
    output.measures.put(.duration_ms, 1500);
    output.measures.put(.exit_code, 0);
    output.measures.put(.lines, 1);
    try rig.apply(&.{ .tool_result = .{
        .call = .{ .id = "c1", .name = "bash", .arguments = "{\"command\":\"zig build\"}" },
        .output = output,
    } });
    try rig.expectKinds(&.{ .user, .tool_result });
    const block = rig.blocks()[1].content.tool_result;
    try std.testing.expectEqualStrings(
        "Tool: bash · Command: zig build\nTime: 1.5s · Exit code: 0 · Lines: 1",
        block.text.items,
    );
    try std.testing.expect(!block.failed);
    const done = try rig.paintPlain(80);
    defer gpa.free(done);
    try std.testing.expect(std.mem.find(u8, done, "Status: streaming") == null);

    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
}

test "a failed tool result keeps its sentence below the call row" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("read it");
    try rig.apply(&.{ .tool_call_started = "read" });
    const call: core.Tool.Call = .{
        .id = "c1",
        .name = "read",
        .arguments = "{\"path\":\"a.txt\"}",
    };
    try rig.apply(&.{ .tool_started = call });
    const sentence = "Drinky could not read a.txt because of error FileNotFound.";
    var output: core.Tool.Output = .{ .content = sentence };
    output.conditions.insert(.path_missing);
    try rig.apply(&.{ .tool_result = .{ .call = call, .output = output } });
    const block = rig.blocks()[1].content.tool_result;
    try std.testing.expectEqualStrings(
        "Tool: read · File: a.txt\nError: " ++ sentence,
        block.text.items,
    );
    try std.testing.expect(block.failed);
    try std.testing.expectEqual(ui.paint.Fit.wrap, block.fit);

    try rig.apply(&.{ .tool_call_started = "describe_drinky" });
    const describe: core.Tool.Call = .{ .id = "c2", .name = "describe_drinky", .arguments = "{}" };
    try rig.apply(&.{ .tool_started = describe });
    try rig.apply(&.{ .tool_result = .{ .call = describe, .output = .{ .content = "# Drinky" } } });
    try std.testing.expectEqualStrings(
        "Tool: describe_drinky",
        rig.blocks()[2].content.tool_result.text.items,
    );
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
}

test "queued calls read as queued until each one runs" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.{ .tool_call_started = "read" });
    try rig.apply(&.{ .tool_call_arguments = "{}" });
    try rig.apply(&.{ .tool_call_started = "write" });
    const two = try rig.paintPlain(80);
    defer gpa.free(two);
    try testing.expectContains(two, "Tool: read · Received: 2 B · Status: queued");
    try testing.expectContains(two, "Tool: write · Received: 0 B · Status: streaming");

    try rig.apply(&.{ .tool_started = .{ .id = "c1", .name = "read", .arguments = "{}" } });
    const one = try rig.paintPlain(80);
    defer gpa.free(one);
    try testing.expectContains(one, "Tool: read ");
    try std.testing.expect(std.mem.find(u8, one, "Tool: read ·") == null);
    try testing.expectContains(one, "Tool: write · Received: 0 B · Status: queued");
    try rig.apply(&.{ .tool_result = .{
        .call = .{ .id = "c1", .name = "read", .arguments = "{}" },
        .output = .{ .content = "x" },
    } });
    try rig.apply(&.{ .tool_started = .{ .id = "w1", .name = "write", .arguments = "{}" } });
    try rig.apply(&.{ .tool_result = .{
        .call = .{ .id = "w1", .name = "write", .arguments = "{}" },
        .output = .{ .content = "x" },
    } });
    try rig.expectKinds(&.{ .user, .tool_result, .tool_result });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
}

test "a reasoning discard keeps a retained call result that arrived after the reasoning" {
    for ([_]ui.Block.Mode{ .full, .compact }) |mode| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        if (mode == .compact) rig.screen.toggleTranscript();
        try rig.start("prompt");
        try rig.apply(&.reasoning_started);
        try rig.apply(&.{ .tool_call_started = "write" });
        try rig.apply(&.reasoning_started);
        try rig.apply(&.{ .tool_call_started = "read" });
        const call: core.Tool.Call = .{ .id = "first", .name = "write", .arguments = "{}" };
        try rig.apply(&.{ .tool_started = call });
        try rig.apply(&.{ .tool_result = .{
            .call = call,
            .output = .{ .content = "done" },
        } });
        try rig.apply(&.{ .tail_discarded = 2 });
        try rig.apply(&.committed);
        try rig.end(&.canceled);
        const painted = try rig.paintPlain(80);
        defer std.testing.allocator.free(painted);
        try testing.expectContains(painted, "Tool: write");
        try std.testing.expect(std.mem.find(u8, painted, "Tool: read") == null);
    }
}

test "a cancel preserves thinking from its discarded tail and the committed blocks" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "I read " });
    try rig.apply(&.{ .tool_call_started = "read" });
    try rig.apply(&.{ .tool_started = .{ .id = "c1", .name = "read", .arguments = "{}" } });
    try rig.apply(&.{ .tool_result = .{
        .call = .{ .id = "c1", .name = "read", .arguments = "{}" },
        .output = .{ .content = "x" },
    } });
    try rig.apply(&.{ .tool_call_started = "write" });
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "afterthought" });
    try rig.expectKinds(&.{ .user, .model, .tool_result, .thinking });

    try rig.apply(&.{ .tail_discarded = 2 });
    try rig.expectKinds(&.{ .user, .model, .tool_result });
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try std.testing.expect(std.mem.find(u8, painted, "Tool: write") == null);
    try std.testing.expect(std.mem.find(u8, painted, "afterthought") == null);

    try rig.apply(&.committed);
    try rig.end(&.canceled);
    try rig.expectKinds(&.{ .user, .model, .tool_result, .thinking, .event });
    try std.testing.expectEqualStrings("You canceled the turn.", rig.eventText(4));
    try std.testing.expectEqualStrings("I read ", rig.blocks()[1].content.model.items);
    const canceled = try rig.paintPlain(80);
    defer gpa.free(canceled);
    try testing.expectContains(canceled, "afterthought");
}

test "a rejected attempt drops its tail, records the retry, and the retry survives the discard" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "partial" });
    try rig.apply(&.{ .usage = .{ .input = 1_000_000 } });
    try rig.apply(&.{ .tail_discarded = 1 });
    try rig.apply(&.{ .attempt_failed = .{
        .attempt = 1,
        .failure = .{ .reason = .overloaded, .message = "529 Overloaded: busy" },
        .delay_ms = 1500,
    } });
    try rig.expectKinds(&.{ .user, .event });
    try std.testing.expectEqualStrings(
        "Attempt 1 failed. The provider is overloaded. Drinky tries again in 1.5s. " ++
            "Details: 529 Overloaded: busy",
        rig.eventText(1),
    );
    try std.testing.expectApproxEqAbs(@as(f64, 3), rig.screen.statusInfo(0).cost, 1e-9);

    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "again" });
    try rig.apply(&.{ .tail_discarded = 1 });
    try rig.apply(&.{ .attempt_failed = .{
        .attempt = 2,
        .failure = .{ .reason = .network },
        .delay_ms = 1000,
    } });
    try rig.expectKinds(&.{ .user, .event, .event });
    try std.testing.expectEqualStrings(
        "Attempt 2 failed. Drinky could not reach the provider. Drinky tries again in 1.0s.",
        rig.eventText(2),
    );

    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "done" });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    try rig.expectKinds(&.{ .user, .event, .event, .model });
}

test "every outcome states its end, and a failure names its details" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();

    try rig.start("a");
    try rig.end(&.{ .stopped = .truncated });
    try std.testing.expectEqualStrings(turn_text.truncated, rig.eventText(1));
    try std.testing.expectEqual(.failure, rig.blocks()[1].content.event.severity);

    try rig.start("b");
    try rig.end(&.exhausted);
    try std.testing.expectEqualStrings(turn_text.exhausted, rig.eventText(3));

    try rig.start("c");
    try rig.end(&.{ .failed = .{ .reason = .unauthorized, .message = "401 Unauthorized" } });
    try std.testing.expectEqualStrings(
        "The credential is missing or invalid. Details: 401 Unauthorized",
        rig.eventText(5),
    );

    try rig.start("d");
    try rig.end(&.{ .failed = .{ .reason = .empty_reply } });
    try std.testing.expectEqualStrings("The model returned an empty reply.", rig.eventText(7));
    try std.testing.expect(rig.screen.notice == null);
}

test "a served model records one warning per turn, and a skill a note" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.display_roots = .{ .working_directory = "/work" };
    try rig.start("hi");
    try rig.apply(&.{ .model_served = .{ .requested = "a", .served = "b" } });
    try rig.apply(&.{ .model_served = .{ .requested = "a", .served = "b" } });
    try rig.apply(&.{ .skill_loaded = .{
        .name = "zig-style",
        .source = "/work/skills/SKILL.md",
    } });
    try rig.expectKinds(&.{ .user, .event, .user_note });
    try std.testing.expectEqualStrings(
        "The provider answered with the model \"b\" instead of the requested model \"a\".",
        rig.eventText(1),
    );
    try std.testing.expectEqual(.warning, rig.blocks()[1].content.event.severity);
    try std.testing.expectEqualStrings(
        "Skill: zig-style · File: skills/SKILL.md",
        rig.blocks()[2].content.user_note.items,
    );
    try rig.end(&.{ .stopped = .complete });
}

test "a reply under the served name of the chosen model records no warning" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var alias = testModel();
    try alias.serveAs("claude-sonnet-4-6-20260101");
    rig.screen.showChoice(&.{
        .account = accounts.testing.anthropic_plan,
        .model = alias,
        .effort = .high,
    });
    try rig.start("hi");
    try rig.apply(&.{ .model_served = .{
        .requested = "claude-sonnet-4-6",
        .served = "claude-sonnet-4-6-20260101",
    } });
    try rig.expectKinds(&.{.user});
    try rig.apply(&.{ .model_served = .{
        .requested = "claude-opus-5",
        .served = "claude-sonnet-4-6-20260101",
    } });
    try rig.expectKinds(&.{ .user, .event });
    try rig.end(&.{ .stopped = .complete });
}

test "the statistics forget the evidence of the last turn and report the new one" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("before");
    try rig.apply(&.{ .usage = .{ .input = 10, .cache_read = 90 } });
    try rig.apply(&.{ .quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } } });
    try rig.apply(&.{ .credits = .{ .total = 10, .used = 2.86 } });
    try rig.end(&.{ .stopped = .complete });
    try std.testing.expect(rig.screen.statusInfo(0).credits != null);
    try rig.start("hi");
    const info = rig.screen.statusInfo(0);
    try std.testing.expect(info.turn_active);
    try std.testing.expectEqual(core.Provider.Usage{}, info.cache_usage);
    try std.testing.expect(info.quota == null);
    try std.testing.expect(info.credits == null);

    try rig.apply(&.{ .usage = .{ .input = 10, .cache_read = 90 } });
    try rig.apply(&.{ .quota = .{ .primary = .{ .used_percent = 12, .window_minutes = 300 } } });
    try rig.apply(&.{ .credits = .{ .total = 10, .used = 1 } });
    const reported = rig.screen.statusInfo(0);
    try std.testing.expectEqual(@as(u64, 90), reported.cache_usage.cache_read);
    try std.testing.expectEqual(@as(f64, 12), reported.quota.?.primary.?.used_percent);
    try std.testing.expectEqual(@as(f64, 10), reported.credits.?.total);
    try rig.end(&.{ .stopped = .complete });
    try std.testing.expectEqualStrings("anthropic-plan", rig.screen.statusInfo(0).account.?);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", rig.screen.statusInfo(0).model.?);
    try std.testing.expect(rig.screen.statusInfo(0).quota != null);

    rig.screen.showChoice(&.{ .account = accounts.testing.openai_api_key, .effort = .high });
    try std.testing.expect(rig.screen.statusInfo(0).quota == null);
    try std.testing.expect(rig.screen.statusInfo(0).credits == null);
}

test "the cost takes a reported charge over the estimate, skips an unpriced model, and caps" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("a");
    try rig.apply(&.{ .usage = .{ .input = 1_000_000, .cost_usd = 0.42 } });
    try rig.apply(&.committed);
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), rig.screen.statusInfo(0).cost, 1e-9);
    try rig.end(&.{ .stopped = .complete });

    var unpriced = testModel();
    unpriced.price = null;
    rig.screen.showChoice(&.{
        .account = accounts.testing.anthropic_plan,
        .model = unpriced,
        .effort = .high,
    });
    try rig.start("b");
    try rig.apply(&.{ .usage = .{ .input = 1_000_000 } });
    try rig.end(&.{ .stopped = .complete });
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), rig.screen.statusInfo(0).cost, 1e-9);

    try rig.start("c");
    try rig.apply(&.{ .usage = .{ .input = 1, .cost_usd = core.Provider.amount_usd_max - 1 } });
    try rig.apply(&.committed);
    try rig.apply(&.{ .usage = .{ .input = 1, .cost_usd = 5 } });
    try rig.end(&.canceled);
    try std.testing.expectEqual(core.Provider.amount_usd_max, rig.screen.statusInfo(0).cost);
}

test "an account switch keeps every block and the scrollback" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "weigh it" });
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });

    const own = try rig.paintPlain(80);
    defer gpa.free(own);
    try testing.expectContains(own, "weigh it");

    rig.screen.showChoice(&.{ .account = accounts.testing.openai_api_key, .effort = .high });
    const switched = try rig.paintPlain(80);
    defer gpa.free(switched);
    try std.testing.expect(
        std.mem.find(u8, rig.out.written(), terminal.escape.screen_reset) == null,
    );
    const wider = try rig.paintPlain(100);
    defer gpa.free(wider);
    try testing.expectContains(wider, "weigh it");
    try testing.expectContains(wider, "answer");
}

test "a notice replaces its predecessor, and a turn end drops it" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setNotice(try Message.print(std.testing.allocator, .information, "First.", .{}));
    rig.screen.setNotice(try Message.print(std.testing.allocator, .failure, "Second.", .{}));
    try std.testing.expectEqual(@as(usize, 0), rig.blocks().len);
    try std.testing.expectEqualStrings("Second.", rig.screen.notice.?.content);
    try std.testing.expectEqual(Message.Severity.failure, rig.screen.notice.?.severity);

    try rig.start("hi");
    rig.screen.setNotice(try Message.print(std.testing.allocator, .warning, "Turn notice.", .{}));
    try rig.end(&.{ .stopped = .complete });
    try std.testing.expect(rig.screen.notice == null);
}

test "a conversation clear drops every block and the statistics" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    try rig.apply(&.{ .usage = .{ .input = 1_000_000 } });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    try std.testing.expectApproxEqAbs(@as(f64, 3), rig.screen.statusInfo(0).cost, 1e-9);

    rig.screen.clearConversation();
    try std.testing.expectEqual(@as(usize, 0), rig.blocks().len);
    try std.testing.expectEqual(@as(f64, 0), rig.screen.statusInfo(0).cost);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", rig.screen.statusInfo(0).model.?);
}

fn openNothing(_: *command.Context, _: usize) command.Context.Error!command.Context.Outcome {
    unreachable;
}

fn openNothingElse(_: *command.Context, _: usize) command.Context.Error!command.Context.Outcome {
    unreachable;
}

fn pickForTest(
    gpa: std.mem.Allocator,
    names: []const []const u8,
    open: ?command.Context.Outcome.Opener,
) !command.Context.Outcome.Pick {
    const options = try gpa.alloc(ui.Picker.Option, names.len);
    errdefer gpa.free(options);
    for (names, options) |name, *option| option.* = .{ .name = try gpa.dupe(u8, name) };
    return .{
        .select = undefined,
        .title = "Step",
        .cancellation_message = "You canceled the selection.",
        .options = options,
        .current = null,
        .reopen = open,
    };
}

test "a picker keeps its trail, waits with animation, and a repeat of a step stays in place" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const account_step: command.Context.Outcome.Opener = .{ .open = openNothing };
    const model_step: command.Context.Outcome.Opener = .{ .open = openNothingElse, .payload = 3 };

    try rig.screen.openPicker(&try pickForTest(gpa, &.{"row"}, account_step));
    try std.testing.expect(rig.screen.stepAbove() == null);
    try rig.screen.openPicker(&try pickForTest(gpa, &.{"row"}, model_step));
    try std.testing.expect(rig.screen.stepAbove().?.eql(account_step));
    for (0..2) |_| {
        try rig.screen.openPicker(&try pickForTest(gpa, &.{"row"}, model_step));
        try std.testing.expect(rig.screen.stepAbove().?.eql(account_step));
    }
    try std.testing.expect(!rig.screen.animating());

    try rig.screen.beginPickerWait("Drinky fetches the model list.");
    try std.testing.expect(rig.screen.animating());
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try testing.expectContains(painted, "Drinky fetches");
    try std.testing.expect(std.mem.find(u8, painted, "> row") == null);

    try rig.screen.openPicker(&try pickForTest(gpa, &.{"row"}, model_step));
    try std.testing.expect(!rig.screen.animating());
    try std.testing.expect(rig.screen.stepAbove().?.eql(account_step));
    try rig.screen.cancelPicker();
    try std.testing.expect(rig.screen.widget == .prompt);
    try std.testing.expectEqualStrings("You canceled the selection.", rig.screen.notice.?.content);
}

test "the picker trail restores a position, bounds its depth, and ends at a step without return" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const rows = [_][]const u8{ "first", "second", "third" };
    const first_step: command.Context.Outcome.Opener = .{ .open = openNothing };
    const depth_max = (Trail{}).entries.len;

    var first = try pickForTest(gpa, &rows, first_step);
    first.preselected = 2;
    try rig.screen.openPicker(&first);
    try rig.screen.openPicker(&try pickForTest(gpa, &.{"next"}, null));
    try std.testing.expect(rig.screen.stepAbove().?.eql(first_step));
    try rig.screen.openPickerAbove(&try pickForTest(gpa, &rows, first_step));
    try std.testing.expect(rig.screen.stepAbove() == null);
    const restored = try rig.paintPlain(80);
    defer gpa.free(restored);
    try testing.expectContains(restored, "> third");

    for (1..depth_max + 2) |payload| {
        const step: command.Context.Outcome.Opener = .{
            .open = openNothingElse,
            .payload = payload,
        };
        try rig.screen.openPicker(&try pickForTest(gpa, &.{"row"}, step));
    }
    for (0..depth_max) |back| {
        const step: command.Context.Outcome.Opener = .{
            .open = openNothingElse,
            .payload = depth_max - back,
        };
        try std.testing.expect(rig.screen.stepAbove().?.eql(step));
        try rig.screen.openPickerAbove(&try pickForTest(gpa, &.{"row"}, step));
    }
    try std.testing.expect(rig.screen.stepAbove() == null);

    try rig.screen.openPicker(&try pickForTest(gpa, &.{"row"}, null));
    try rig.screen.openPicker(&try pickForTest(gpa, &.{"row"}, first_step));
    try std.testing.expect(rig.screen.stepAbove() == null);
    rig.screen.closePicker();
}

test "a picked line replaces the draft, and a page opens over the prompt" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.screen.editor.insert("draft");
    try rig.screen.setDraft("/skill:demo ");
    try std.testing.expectEqualStrings("/skill:demo ", rig.screen.editor.visible());

    try rig.screen.openPage(&.{ .title = "System prompt", .content = "# Prompt\n\nbody" });
    try std.testing.expect(rig.screen.widget == .page);
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try testing.expectContains(painted, "body");
    rig.screen.closePage();
    try std.testing.expect(rig.screen.widget == .prompt);
}

test "a page repaints the screen and keeps the scrollback" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.screen.openPage(&.{ .title = "Page", .content = "body" });
    try rig.screen.paint(.{ .columns = 80, .rows = 24 }, rig.time, &no_caption);
    const painted = rig.out.written();
    try std.testing.expect(std.mem.find(u8, painted, terminal.escape.screen_repaint) != null);
    try std.testing.expect(std.mem.find(u8, painted, "\x1b[3J") == null);
}

test "a window without a column or a row paints as one column and one row" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.{ .text = "an answer that needs more than one column" });
    try rig.screen.paint(.{ .columns = 0, .rows = 0 }, rig.time, &no_caption);
    try std.testing.expectEqual(@as(usize, 1), rig.screen.columns);
    try std.testing.expectEqual(@as(usize, 1), rig.screen.rows);
    try rig.end(&.{ .stopped = .complete });
    try rig.screen.openPage(&.{ .title = "Page", .content = "body" });
    try rig.screen.paint(.{ .columns = 0, .rows = 0 }, rig.time, &no_caption);
}
