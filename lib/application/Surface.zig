const std = @import("std");
const accounts = @import("accounts");
const core = @import("core");
const tools = @import("tools");
const billing = @import("billing.zig");
const Choice = @import("Choice.zig");
const command = @import("command/root.zig");
const Controller = @import("Controller.zig");
const Interaction = @import("Interaction.zig");
const Live = @import("Live.zig");
const Message = @import("Message.zig");
const Page = @import("Page.zig");
const Picker = @import("Picker.zig");
const project = @import("project.zig");
const reducer = @import("reducer.zig");
const testing = @import("testing.zig");
const Transcript = @import("Transcript.zig");
const turn_text = @import("turn_text.zig");
const Turns = @import("Turns.zig");
const Surface = @This();
gpa: std.mem.Allocator,
io: std.Io,
sink: Controller.Sink,
transcript: Transcript,
notice: ?Message = null,
state: State = .prompt,
statistics: Statistics = .{},
statistics_published: Statistics = .{},
choice: Choice,
branch_buffer: [project.head_bytes_max]u8 = undefined,
branch_length: usize = 0,
bash_timeout_ms: u64,
thinking_active: ?usize = null,
page_wait: ?Interaction.Page.Wait = null,
picker_id: u64 = 0,
page_id: u64 = 0,
page_published: usize = 0,
notice_id: u64 = 0,
revision: u64 = 0,
muted: bool = false,
answer: std.ArrayList(u8) = .empty,
live_calls: std.ArrayList(Live.Call) = .empty,
live_hash: u64,

pub const Time = struct { awake_ms: i64, boot_ms: i64 };
pub const Statistics = struct {
    cost: f64 = 0,
    context_tokens: ?u64 = 0,
    cache_usage: core.Provider.Usage = .{},
    quota: ?core.Provider.Quota = null,
    quota_seen_ms: i64 = 0,
    credits: ?core.Provider.Credits = null,

    fn forgetTurnEvidence(self: *Statistics) void {
        self.cache_usage = .{};
        self.quota_seen_ms = 0;
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
            .quota => |quota| {
                self.quota = quota;
                self.quota_seen_ms = options.boot_ms;
            },
            .credits => |credits| self.credits = credits,
            else => {},
        }
    }
};

pub const State = union(Interaction.Mode) {
    prompt,
    turn: Turn,
    picker: Picking,
    fetch: Fetch,
    page: Page,
    sign_in: SignIn,
};
pub const Fetch = struct {
    account: usize,
    picking: Picking,
    exit: ?Exit = null,

    pub const Exit = enum { step, command };
};
pub const SignIn = struct {
    account: usize,
    takes_paste: bool,
    event_index: ?usize = null,
    canceled: bool = false,
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

    pub fn firstCall(self: *Turn, phases: []const Call.Phase) ?*Block {
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
    started_ms: i64 = 0,
    description: tools.Registry.Description = .{ .subject = null, .timeout_ms = null },

    pub const Phase = enum { streaming, queued, running, done };

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
const Picking = struct {
    picker: Picker,
    selector: *const fn (
        *command.Context,
        command.Context.Outcome.Pick.Selection,
    ) command.Context.Error!command.Context.Outcome,
    payload: usize,
    cancellation_message: []const u8,
    reopen: ?command.Context.Outcome.Opener,
    trail: Trail,

    pub fn select(
        self: *const Picking,
        context: *command.Context,
        row: usize,
    ) command.Context.Error!command.Context.Outcome {
        return self.selector(context, .{ .payload = self.payload, .row = row });
    }
};

const Trail = struct {
    entries: [8]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        open: command.Context.Outcome.Opener,
        cursor: usize,
    };

    fn push(self: *Trail, cursor: usize, opener: ?command.Context.Outcome.Opener) void {
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
        self.entries[self.len] = .{ .open = open, .cursor = cursor };
        self.len += 1;
    }

    fn last(self: *const Trail) ?Entry {
        return if (self.len == 0) null else self.entries[self.len - 1];
    }

    fn dropLast(self: *Trail) void {
        if (self.len > 0) self.len -= 1;
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
    self.deinitState();
    if (self.notice) |*message| message.deinit(self.gpa);
    self.transcript.deinit();
    self.answer.deinit(self.gpa);
    self.live_calls.deinit(self.gpa);
}
fn emit(self: *Surface, event: *const Controller.Event) void {
    if (!self.muted) self.sink.emit(self.io, event);
}
pub fn flush(self: *Surface, sink: Controller.Sink, maybe_interaction: ?*const Interaction) void {
    const page_length = if (self.activePage()) |page| page.text().len else 0;
    if (self.muted) {
        self.transcript.sync();
        self.live_hash = hashLive(&self.live());
        self.statistics_published = self.statistics;
        self.page_published = page_length;
        return;
    }
    self.transcript.flush(sink, self.io);
    if (!std.meta.eql(self.statistics, self.statistics_published)) {
        self.statistics_published = self.statistics;
        sink.emit(self.io, &.{ .statistics = self.statistics });
    }
    if (maybe_interaction) |value| sink.emit(self.io, &.{ .interaction = value.* });
    const live_now = self.live();
    const hash = hashLive(&live_now);
    if (hash != self.live_hash) {
        self.live_hash = hash;
        sink.emit(self.io, &.{ .live = live_now });
    }
    if (page_length > self.page_published) {
        const text = self.activePage().?.text();
        sink.emit(self.io, &.{ .page_text = text[self.page_published..] });
        self.page_published = page_length;
    }
}
pub fn branch(self: *const Surface) []const u8 {
    return self.branch_buffer[0..self.branch_length];
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
                .running => .running,
                .done => continue,
            },
            .argument_bytes = call.bytes,
            .opened_ms = call.opened_ms,
            .started_ms = call.started_ms,
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
            call.started_ms,
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
fn deinitState(self: *Surface) void {
    switch (self.state) {
        .prompt, .sign_in => {},
        .turn => |*turn| turn.deinit(self.gpa),
        .picker => |*picking| picking.picker.deinit(self.gpa),
        .fetch => |*fetch| fetch.picking.picker.deinit(self.gpa),
        .page => |*page| page.deinit(self.gpa),
    }
}

pub fn beginTurn(self: *Surface) void {
    std.debug.assert(self.state == .prompt);
    self.transcript.endMessage();
    self.statistics.forgetTurnEvidence();
    self.answer.clearRetainingCapacity();
    self.state = .{ .turn = .{ .committed = self.transcript.entries().len } };
    self.revision +%= 1;
}

pub fn applyAccounting(self: *Surface, event: *const core.Session.Event, time: Time) void {
    self.statistics.apply(event, &.{
        .turn_active = self.state == .turn,
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
    options: *const struct { ran: bool, now_ms: i64, canceled: bool },
) !usize {
    const index = self.transcript.entries().len;
    try self.transcript.append(&.{ .tool_result = .{
        .name = call.name,
        .description = call.description,
        .output = result.output,
        .elapsed_ms = if (options.ran and options.canceled)
            options.now_ms - call.started_ms
        else
            null,
        .started_ms = call.opened_ms,
        .received_bytes = result.call.arguments.len,
    } }, .{ .id = call.record_id });
    return index;
}

pub fn attemptMessage(
    gpa: std.mem.Allocator,
    attempt: *const core.Session.Event.Attempt,
) error{OutOfMemory}!Message {
    var buffer: [24]u8 = undefined;
    const delay = tools.format.duration(&buffer, @intCast(@min(
        attempt.delay_ms,
        std.math.maxInt(i64),
    )));
    const sentence = turn_text.failureSentence(attempt.failure.reason);
    const content = if (attempt.failure.message.len == 0)
        try gpa.print(
            "Attempt {d} failed. {s} Drinky tries again in {s}.",
            .{ attempt.attempt, sentence, delay },
        )
    else
        try gpa.print(
            "Attempt {d} failed. {s} Drinky tries again in {s}. Details: {s}",
            .{ attempt.attempt, sentence, delay, attempt.failure.message },
        );
    return .{ .content = content, .severity = .information };
}

pub fn endTurn(self: *Surface, outcome: *const core.Session.Outcome) void {
    if (self.activeTurn()) |turn| turn.deinit(self.gpa);
    self.transcript.retained = 0;
    self.state = .prompt;
    self.revision +%= 1;
    self.transcript.endMessage();
    self.thinking_active = null;
    if (self.notice != null) self.clearNotice();
    self.emit(&.{ .turn_ended = .{ .outcome = outcome.*, .answer = self.answer.items } });
}

pub fn activeTurn(self: *Surface) ?*Turn {
    return switch (self.state) {
        .turn => |*turn| turn,
        else => null,
    };
}

pub fn clearConversation(self: *Surface) void {
    self.transcript.clear();
    self.statistics = .{};
    self.emit(&.clear_conversation);
}
pub fn showChoice(self: *Surface, choice: *const Choice) void {
    if (self.choice.account != choice.account) self.statistics.forgetBilling();
    const changed = !self.choice.eql(choice);
    self.choice = choice.*;
    if (changed) self.revision +%= 1;
}
pub fn clearNotice(self: *Surface) void {
    if (self.notice) |*message| message.deinit(self.gpa);
    self.notice = null;
    self.notice_id +%= 1;
    self.revision +%= 1;
}
pub fn setNotice(self: *Surface, message: Message) void {
    if (self.notice) |*previous| previous.deinit(self.gpa);
    self.notice = message;
    self.notice_id +%= 1;
    self.revision +%= 1;
}
pub fn appendEvent(self: *Surface, message: Message) !void {
    defer message.deinit(self.gpa);
    try self.transcript.append(
        &.{ .event = .{ .text = message.content, .severity = message.severity } },
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
pub fn appendNote(self: *Surface, text: []const u8) !void {
    try self.transcript.append(&.{ .user_note = .{ .text = text } }, .{});
}
pub fn appendSkillNote(self: *Surface, skill: *const core.Session.Event.SkillLoaded) !void {
    try self.transcript.append(&.{ .user_note = .{ .skill = skill.* } }, .{});
}
pub fn replaceEvent(self: *Surface, index: usize, message: Message) !void {
    defer message.deinit(self.gpa);
    try self.transcript.replaceEvent(index, &.{
        .text = message.content,
        .severity = message.severity,
    });
}
pub fn rewind(self: *Surface, dropped: []const Turns.Turn) void {
    for (0..dropped.len) |offset| self.transcript.remove(dropped[dropped.len - 1 - offset].range);
}
pub fn setBranch(self: *Surface, name: []const u8) void {
    std.debug.assert(name.len <= self.branch_buffer.len);
    if (std.mem.eql(u8, self.branch_buffer[0..self.branch_length], name)) return;
    @memcpy(self.branch_buffer[0..name.len], name);
    self.branch_length = name.len;
    self.revision +%= 1;
}
pub fn openPage(self: *Surface, options: *const Page.Options) !void {
    const page = try Page.init(self.gpa, options);
    self.state = .{ .page = page };
    self.page_id +%= 1;
    self.page_published = 0;
    self.revision +%= 1;
}
pub fn waitOnPage(self: *Surface, now_ms: i64) void {
    self.page_wait = .{ .started_ms = now_ms };
    self.revision +%= 1;
}
pub fn receiveOnPage(self: *Surface, bytes: usize) void {
    self.page_wait.?.thinking = true;
    self.page_wait.?.received_bytes +|= bytes;
    self.revision +%= 1;
}
pub fn noteOnPage(self: *Surface, message: *const Message) !void {
    try self.state.page.setRetry(self.gpa, message);
    self.revision +%= 1;
}
pub fn appendToPage(self: *Surface, text: []const u8) !void {
    try self.state.page.append(self.gpa, text);
}
pub fn activePage(self: *Surface) ?*Page {
    return if (self.state == .page) &self.state.page else null;
}
pub fn closePage(self: *Surface) void {
    if (self.state != .page) return;
    self.state.page.deinit(self.gpa);
    self.state = .prompt;
    self.page_wait = null;
    self.page_published = 0;
    self.revision +%= 1;
}
pub fn publishPage(self: *Surface) void {
    self.revision +%= 1;
}
pub fn openPicker(self: *Surface, pick: *const command.Context.Outcome.Pick) !void {
    var trail: Trail = .{};
    if (self.activePicker()) |picking| {
        trail = picking.trail;
        if (!sameStep(&picking.reopen, &pick.reopen))
            trail.push(picking.picker.cursor orelse 0, picking.reopen);
    }
    try self.enterPicker(pick, trail, null);
}
fn sameStep(
    step: *const ?command.Context.Outcome.Opener,
    other: *const ?command.Context.Outcome.Opener,
) bool {
    const step_open = step.* orelse return false;
    const other_open = other.* orelse return false;
    return step_open.eql(other_open);
}

pub fn openPickerAbove(self: *Surface, pick: *const command.Context.Outcome.Pick) !void {
    var trail = self.activePicker().?.trail;
    const entry = trail.last().?;
    trail.dropLast();
    try self.enterPicker(pick, trail, entry.cursor);
}
pub fn stepAbove(self: *const Surface) ?command.Context.Outcome.Opener {
    const trail = switch (self.state) {
        .picker => |*picking| &picking.trail,
        .fetch => |*fetch| &fetch.picking.trail,
        else => return null,
    };
    return if (trail.last()) |entry| entry.open else null;
}
fn enterPicker(
    self: *Surface,
    pick: *const command.Context.Outcome.Pick,
    trail: Trail,
    cursor: ?usize,
) !void {
    defer {
        for (pick.options) |*option| option.deinit(self.gpa);
        self.gpa.free(pick.options);
    }
    if (pick.report) |message| try self.appendEvent(message);
    self.picker_id +%= 1;
    const data: Picker = .{
        .id = self.picker_id,
        .title = pick.title,
        .options = pick.options,
        .current = pick.current,
        .preselected = pick.preselected,
        .cursor = cursor,
        .depth = trail.len,
    };
    const copy = try data.dupe(self.gpa);
    self.deinitState();
    self.state = .{ .picker = .{
        .picker = copy,
        .selector = pick.select,
        .payload = pick.payload,
        .cancellation_message = pick.cancellation_message,
        .reopen = pick.reopen,
        .trail = trail,
    } };
    self.revision +%= 1;
}
pub fn closePicker(self: *Surface) void {
    const picking = self.activePicker() orelse return;
    picking.picker.deinit(self.gpa);
    self.state = .prompt;
    self.revision +%= 1;
}
pub fn cancelPicker(self: *Surface) !void {
    const message = self.activePicker().?.cancellation_message;
    self.closePicker();
    self.setNotice(try Message.print(self.gpa, .information, "{s}", .{message}));
}
pub fn activePicker(self: *Surface) ?*Picking {
    return switch (self.state) {
        .picker => |*picking| picking,
        .fetch => |*fetch| &fetch.picking,
        else => null,
    };
}
pub fn beginPickerWait(self: *Surface, account: usize) void {
    const picking = self.state.picker;
    self.state = .{ .fetch = .{ .account = account, .picking = picking } };
    self.revision +%= 1;
}

pub fn apply(self: *Surface, event: *const core.Session.Event, time: Time) !?core.Session.Outcome {
    return reducer.apply(self, event, time);
}

test "the picker trail bounds its depth and ends at a step without return" {
    const gpa = std.testing.allocator;
    var reduction: testing.Reduction = undefined;
    reduction.init(gpa, .{ .effort = .high });
    defer reduction.deinit();
    const surface = &reduction.surface;
    const depth_max = (Trail{}).entries.len;

    for (0..depth_max + 2) |payload| {
        const step: command.Context.Outcome.Opener = .{ .open = openNothing, .payload = payload };
        try surface.openPicker(&try pickForTest(gpa, step));
    }
    for (0..depth_max) |back| {
        const step: command.Context.Outcome.Opener = .{
            .open = openNothing,
            .payload = depth_max - back,
        };
        try std.testing.expect(surface.stepAbove().?.eql(step));
        try surface.openPickerAbove(&try pickForTest(gpa, step));
    }
    try std.testing.expect(surface.stepAbove() == null);

    try surface.openPicker(&try pickForTest(gpa, null));
    try surface.openPicker(&try pickForTest(gpa, .{ .open = openNothing }));
    try std.testing.expect(surface.stepAbove() == null);
}

fn openNothing(_: *command.Context, _: usize) command.Context.Error!command.Context.Outcome {
    unreachable;
}

fn pickForTest(
    gpa: std.mem.Allocator,
    open: ?command.Context.Outcome.Opener,
) !command.Context.Outcome.Pick {
    const options = try gpa.alloc(Picker.Option, 1);
    errdefer gpa.free(options);
    options[0] = .{ .name = try gpa.dupe(u8, "row") };
    return .{
        .select = undefined,
        .title = "Step",
        .cancellation_message = "You canceled the selection.",
        .options = options,
        .current = null,
        .reopen = open,
    };
}
