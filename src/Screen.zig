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
const tool_line = @import("tool_line.zig");
const Transcript = @import("Transcript.zig");
const ui = @import("ui/root.zig");

const Screen = @This();

const truncated_event =
    "The reply is incomplete. The model reached an output or context limit.";
const exhausted_event = "The turn reached the limit for tool rounds.";
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
dirty: bool,
statistics: Statistics,
choice: Choice,
directory_shown: []const u8,
branch_buffer: [project.head_bytes_max]u8,
branch_length: usize,
bash_timeout_ms: u64,
window_pages: usize,
gauge: ui.status.Gauge,
display_roots: format.Roots,

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

const Widget = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
    page: ui.Page,
};

const Turn = struct {
    start: usize,
    committed: usize,
    blocks: std.ArrayList(Block),
    served_buffer: [accounts.Model.name_bytes_max]u8,
    served_length: usize,
    activity_tick: u64,
    progress_tick_last: u64,
    caret_tick: u64,
    box_view: std.ArrayList(ui.paint.Box),
    box_hashes: std.ArrayList(u64),
    box_tracks: std.ArrayList(layout.Track),

    fn init(start: usize, committed: usize) Turn {
        return .{
            .start = start,
            .committed = committed,
            .blocks = .empty,
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
        if (self.blocks.items.len == 0) return null;
        const block = &self.blocks.items[self.blocks.items.len - 1];
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

    fn boxes(self: *Turn, gpa: std.mem.Allocator, now_ms: i64) ![]const ui.paint.Box {
        self.box_view.clearRetainingCapacity();
        for (self.blocks.items) |*block| {
            const call = if (block.call) |*call| call else continue;
            if (call.phase == .done) continue;
            try self.box_view.append(gpa, .{
                .text = try call.text(gpa, now_ms),
                .fit = .head,
                .emphasis = .first_value,
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
                .streaming => "Streaming",
                .queued => "Queued",
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
        .dirty = false,
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

pub fn clearConversation(self: *Screen) void {
    std.debug.assert(self.widget == .prompt);
    self.clearNotice();
    self.transcript.truncate(0);
    self.statistics = .{};
    self.view.resetScreen();
    self.dirty = true;
}

pub fn showChoice(self: *Screen, choice: *const Choice) void {
    if (self.choice.account != choice.account) self.statistics.forgetBilling();
    self.choice = choice.*;
    self.dirty = true;
}

pub fn clearNotice(self: *Screen) void {
    if (self.notice) |notice| {
        notice.deinit(self.gpa);
        self.notice = null;
        self.dirty = true;
    }
}

pub fn setNotice(self: *Screen, notice: Message) void {
    self.clearNotice();
    self.notice = notice;
    self.dirty = true;
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

pub fn beginTurn(self: *Screen, start: usize) void {
    std.debug.assert(self.widget == .prompt);
    std.debug.assert(start <= self.transcript.blocks().len);
    self.transcript.endMessage();
    self.statistics.forgetTurnEvidence();
    self.widget = .{ .turn = .init(start, self.transcript.blocks().len) };
    self.dirty = true;
}

pub fn withdrawTurn(self: *Screen) !void {
    const turn = self.activeTurn() orelse return;
    const start = turn.start;
    for (self.transcript.blocks()[start..]) |*block| switch (block.content) {
        .user => |*text| {
            try self.editor.prependText(text.items);
            break;
        },
        else => {},
    };
    self.endTurn();
    self.transcript.rewind(start);
    self.dirty = true;
}

pub fn apply(
    self: *Screen,
    event: *const core.Session.Event,
    time: Time,
) !?core.Session.Outcome {
    const turn = self.activeTurn() orelse return self.applyIdle(event, time);
    self.dirty = true;
    switch (event.*) {
        .prompt_refused, .setup_dropped => unreachable,
        .text_started => try self.beginBlock(turn, .text),
        .text => |delta| {
            if (turn.lastBlock(.text) == null) try self.beginBlock(turn, .text);
            try self.transcript.appendStream(.model, delta);
            turn.lastBlock(.text).?.transcript_index = self.transcript.runIndex();
        },
        .reasoning_started => try self.beginBlock(turn, .reasoning),
        .reasoning => |delta| {
            if (turn.lastBlock(.reasoning) == null) try self.beginBlock(turn, .reasoning);
            try self.transcript.appendStream(.thinking, delta);
            turn.lastBlock(.reasoning).?.transcript_index = self.transcript.runIndex();
        },
        .tool_call_started => |name| try self.startCall(turn, name),
        .tool_call_arguments => |delta| try self.growCall(turn, delta),
        .tool_started => |*call| try self.runCall(turn, call, time),
        .tool_result => |*result| try self.settleCall(turn, result),
        .committed => {
            self.statistics.charge(self.chosenModel());
            self.transcript.endMessage();
            turn.committed = self.transcript.blocks().len;
            turn.releaseBlocks(self.gpa, 0);
        },
        .tail_discarded => |count| try self.discardTail(turn, count),
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
            self.statistics.charge(self.chosenModel());
            self.transcript.endMessage();
            const text = try attemptText(self.gpa, attempt);
            defer self.gpa.free(text);
            try self.transcript.append(&.{ .event = .{ .text = text, .survives_rewind = true } });
        },
        .skill_loaded => |*loaded| {
            self.transcript.endMessage();
            try self.appendSkillNote(loaded);
        },
        .turn_ended => |outcome| {
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
    self.dirty = true;
    return null;
}

fn chosenModel(self: *const Screen) ?*const accounts.Model {
    return if (self.choice.model) |*found| found else null;
}

fn beginBlock(self: *Screen, turn: *Turn, kind: Block.Kind) !void {
    self.transcript.endMessage();
    try turn.blocks.append(self.gpa, .{ .kind = kind, .transcript_index = null, .call = null });
    self.transcript.beginRun(switch (kind) {
        .text => .model,
        .reasoning => .thinking,
        .call => unreachable,
    });
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
    const head = try std.fmt.allocPrint(self.gpa, "Tool: {s}", .{result.call.name});
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
            const text = try std.fmt.allocPrint(self.gpa, "{s}\n{s}", .{ head, detail });
            defer self.gpa.free(text);
            try self.transcript.append(&.{ .tool_result = .{ .text = text, .failed = failed } });
        },
        .sentence => |sentence| {
            const text = try std.fmt.allocPrint(self.gpa, "{s}\nError: {s}", .{ head, sentence });
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

fn discardTail(self: *Screen, turn: *Turn, count: usize) !void {
    self.transcript.endMessage();
    const kept = turn.blocks.items.len -| count;
    var first: ?usize = null;
    for (turn.blocks.items[kept..]) |block| {
        const index = block.transcript_index orelse continue;
        first = if (first) |found| @min(found, index) else index;
    }
    turn.releaseBlocks(self.gpa, kept);
    if (first) |index| self.transcript.rewind(@max(index, turn.committed));
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
    const text = try std.fmt.allocPrint(
        self.gpa,
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
            .truncated => try self.appendFailure(truncated_event),
        },
        .canceled => try self.transcript.append(&.{ .event = .{ .text = canceled_event } }),
        .exhausted => try self.appendFailure(exhausted_event),
        .failed => |*failure| {
            const text = try failureText(self.gpa, failure);
            defer self.gpa.free(text);
            try self.appendFailure(text);
        },
    }
}

fn failureSentence(reason: core.Provider.Failure.Reason) []const u8 {
    return switch (reason) {
        .unauthorized => "The credential is missing or invalid.",
        .rate_limited => "The provider limits the request rate.",
        .quota_exhausted => "The account has no quota left.",
        .overloaded => "The provider is overloaded.",
        .invalid_request => "The request is invalid.",
        .context_overflow => "The conversation does not fit the context window of the model.",
        .network => "Drinky could not reach the provider.",
        .invalid_reply => "Drinky did not receive the complete reply of the model.",
        .empty_reply => "The model returned an empty reply.",
        .unsupported_reply => "Drinky cannot keep the reply because the model returned a " ++
            "refusal, a pause, or an unsupported result.",
        .too_many_tool_calls => "Drinky stopped the reply because it asked for too many tool " ++
            "calls.",
        .out_of_memory => "Drinky ran out of memory.",
    };
}

fn failureText(gpa: std.mem.Allocator, failure: *const core.Provider.Failure) ![]u8 {
    const sentence = failureSentence(failure.reason);
    if (failure.message.len == 0) return gpa.dupe(u8, sentence);
    return std.fmt.allocPrint(gpa, "{s} Details: {s}", .{ sentence, failure.message });
}

fn attemptText(gpa: std.mem.Allocator, attempt: *const core.Session.Event.Attempt) ![]u8 {
    var buffer: [24]u8 = undefined;
    const delay = tools.format.duration(&buffer, @intCast(@min(
        attempt.delay_ms,
        std.math.maxInt(i64),
    )));
    const sentence = failureSentence(attempt.failure.reason);
    if (attempt.failure.message.len == 0) return std.fmt.allocPrint(
        gpa,
        "Attempt {d} failed. {s} Drinky tries again in {s}.",
        .{ attempt.attempt, sentence, delay },
    );
    return std.fmt.allocPrint(
        gpa,
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
    self.dirty = true;
}

pub fn appendUser(self: *Screen, text: []const u8) !void {
    try self.transcript.append(&.{ .user = text });
    self.dirty = true;
}

pub fn appendSkillNote(self: *Screen, skill: *const core.Session.Event.SkillLoaded) !void {
    const path = try format.path(self.gpa, skill.source, &self.display_roots);
    defer self.gpa.free(path);
    const text = try std.fmt.allocPrint(self.gpa, "Skill: {s} · File: {s}", .{ skill.name, path });
    defer self.gpa.free(text);
    try self.transcript.append(&.{ .user_note = text });
    self.dirty = true;
}

pub fn appendIntro(self: *Screen, text: []const u8) !void {
    try self.transcript.append(&.{ .intro = text });
    self.dirty = true;
}

pub fn replaceEvent(self: *Screen, index: usize, message: Message) !void {
    defer message.deinit(self.gpa);
    try self.transcript.replaceEvent(index, &.{
        .text = message.content,
        .severity = message.severity,
    });
    self.dirty = true;
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
    self.dirty = true;
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
            self.dirty = true;
        },
        else => {},
    }
}

pub fn beginPickerWait(self: *Screen, text: []const u8) !void {
    const picking = &self.widget.picking;
    try picking.picker.beginWait(text);
    picking.wait_tick = 0;
    self.dirty = true;
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
    self.dirty = true;
}

pub fn closePage(self: *Screen) void {
    switch (self.widget) {
        .page => |*page| {
            page.deinit();
            self.widget = .prompt;
            self.dirty = true;
        },
        else => {},
    }
}

pub fn setBranch(self: *Screen, name: []const u8) void {
    std.debug.assert(name.len <= self.branch_buffer.len);
    if (std.mem.eql(u8, self.branch_buffer[0..self.branch_length], name)) return;
    @memcpy(self.branch_buffer[0..name.len], name);
    self.branch_length = name.len;
    self.dirty = true;
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
            const boxes = try turn.boxes(self.gpa, time.awake_ms);
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
        .transcript = self.transcript.block_list.items,
        .tail = tail,
        .status = &status,
    } };
    try layout.project(self.gpa, &self.view, size, &scene);
}

pub fn statusInfo(self: *const Screen, boot_ms: i64) ui.status.Info {
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
    self.dirty = true;
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
    return self.dirty or activity_changed;
}

pub fn animating(self: *const Screen) bool {
    return switch (self.widget) {
        .turn => true,
        .picking => |*picking| picking.wait_tick != null,
        .prompt, .page => false,
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
    try expectContains(painted, "hello");
    try expectContains(painted, "weigh it");
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
        const base = self.screen.transcript.blocks().len;
        try self.screen.appendUser(text);
        self.screen.beginTurn(base);
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

fn expectContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) != null) return;
    std.debug.print("the text holds no \"{s}\":\n{s}\n", .{ needle, text });
    return error.TestExpectedNeedle;
}

const no_caption: ?ui.Caption = null;

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
    try expectContains(streamed, "Tool: bash · Received: 23 B · Status: Streaming");

    rig.time.awake_ms = 1_000;
    try rig.apply(&.{ .tool_started = .{
        .id = "c1",
        .name = "bash",
        .arguments = "{\"command\":\"zig build\"}",
    } });
    rig.time.awake_ms = 13_400;
    const running = try rig.paintPlain(80);
    defer gpa.free(running);
    try expectContains(running, "Tool: bash · Command: zig build");
    try expectContains(running, "Time: 12s · Timeout: 2m 0s");

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
    try std.testing.expect(std.mem.indexOf(u8, done, "Status: Streaming") == null);

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
    try expectContains(two, "Tool: read · Received: 2 B · Status: Queued");
    try expectContains(two, "Tool: write · Received: 0 B · Status: Streaming");

    try rig.apply(&.{ .tool_started = .{ .id = "c1", .name = "read", .arguments = "{}" } });
    const one = try rig.paintPlain(80);
    defer gpa.free(one);
    try expectContains(one, "Tool: read ");
    try std.testing.expect(std.mem.indexOf(u8, one, "Tool: read ·") == null);
    try expectContains(one, "Tool: write · Received: 0 B · Status: Queued");
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

test "a discarded tail leaves the screen with its rows, and a cancel keeps the rest" {
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
    try std.testing.expect(std.mem.indexOf(u8, painted, "Tool: write") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "afterthought") == null);

    try rig.apply(&.committed);
    try rig.end(&.canceled);
    try rig.expectKinds(&.{ .user, .model, .tool_result, .event });
    try std.testing.expectEqualStrings("You canceled the turn.", rig.eventText(3));
    try std.testing.expectEqualStrings("I read ", rig.blocks()[1].content.model.items);
}

test "a rejected attempt drops its tail, records the retry, and the retry survives a rewind" {
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
    try std.testing.expectEqualStrings(truncated_event, rig.eventText(1));
    try std.testing.expectEqual(.failure, rig.blocks()[1].content.event.severity);

    try rig.start("b");
    try rig.end(&.exhausted);
    try std.testing.expectEqualStrings(exhausted_event, rig.eventText(3));

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

test "a withdrawn turn leaves the transcript and returns its message to the editor" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("late");
    try rig.expectKinds(&.{.user});
    try rig.screen.withdrawTurn();
    try std.testing.expect(rig.screen.widget == .prompt);
    try rig.expectKinds(&.{});
    try std.testing.expectEqualStrings("late", rig.screen.editor.visible());
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
    try expectContains(own, "weigh it");

    rig.screen.showChoice(&.{ .account = accounts.testing.openai_api_key, .effort = .high });
    const switched = try rig.paintPlain(80);
    defer gpa.free(switched);
    try std.testing.expect(
        std.mem.indexOf(u8, rig.out.written(), terminal.escape.screen_reset) == null,
    );
    const wider = try rig.paintPlain(100);
    defer gpa.free(wider);
    try expectContains(wider, "weigh it");
    try expectContains(wider, "answer");
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
    try expectContains(painted, "Drinky fetches");
    try std.testing.expect(std.mem.indexOf(u8, painted, "> row") == null);

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
    try expectContains(restored, "> third");

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
    try expectContains(painted, "body");
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
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.screen_repaint) != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[3J") == null);
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
