const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const layout = @import("layout.zig");
const Transcript = @import("Transcript.zig");
const ui = @import("ui/root.zig");

const Session = @This();

const truncated_event =
    "The response is incomplete. The model reached an output or context limit.";
const turn_event_options: ui.block.Entry.Options = .{};
const turn_failure_options: ui.block.Entry.Options = .{ .is_error = true };

pub const editor_caption_rows_max: usize = 3;

const StreamedTool = struct {
    name: []const u8,
    bytes: usize,
    phase: Phase,
    box: std.ArrayList(u8),

    const Phase = enum {
        streaming,
        queued,
        stale,
    };

    fn deinit(self: *StreamedTool, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.box.deinit(gpa);
    }

    fn refresh(self: *StreamedTool, gpa: std.mem.Allocator) !void {
        var bytes_buffer: [16]u8 = undefined;
        self.box.clearRetainingCapacity();
        try self.box.print(gpa, "Tool: {s} · Received: {s} · Status: {s}", .{
            self.name,
            ai.format.bytes(&bytes_buffer, self.bytes),
            switch (self.phase) {
                .streaming => "Streaming",
                .queued, .stale => "Queued",
            },
        });
    }
};

gpa: std.mem.Allocator,
transcript: Transcript,
notice: ?ai.command.Outcome.Message,
confirmations: std.EnumSet(Confirmation),
editor: ui.Editor,
view: terminal.View,
page_view: terminal.View,
mode: Mode,
columns: usize,
rows: usize,
dirty: bool,
stats_shown: ai.Agent.Stats,
model_shown: ?ai.Model,
effort_shown: ai.llm.Effort,
account_shown: ?ai.llm.Account,
directory_shown: []const u8,
branch_root: ?[]const u8,
branch_buffer: [ai.project.head_name_bytes_max]u8,
branch_length: usize,
pending_events: std.ArrayList(PendingEvent),
turn_prompt: ?TurnPrompt,
input: Input,
clock_ms: i64,
boot_clock_ms: i64,
bash_timeout_ms: u64,
window_pages: usize,
gauge: ui.status.Gauge,
display_roots: ai.format.Roots,

const Mode = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
    viewing: ui.Page,
};

const Turn = struct {
    generation: u64,
    progress_sequence_applied: u64,
    progress_sequence_checkpoint: u64,
    transcript_checkpoint: usize,
    activity_tick: u64,
    progress_tick_last: u64,
    caret_tick: u64,
    calls: usize,
    tools: std.ArrayList(ActiveTool),
    streamed_tools: std.ArrayList(StreamedTool),
    box_view: std.ArrayList(ui.paint.Box),
    box_hashes: std.ArrayList(u64),
    box_tracks: std.ArrayList(layout.Track),

    fn activity(self: *const Turn) ui.paint.Activity {
        return .{
            .motion_tick = self.activity_tick,
            .progress_age_ticks = self.activity_tick -% self.progress_tick_last,
            .caret_tick = self.caret_tick,
        };
    }

    fn boxes(self: *Turn, gpa: std.mem.Allocator, now_ms: i64) ![]const ui.paint.Box {
        self.box_view.clearRetainingCapacity();
        for (self.tools.items) |*tool| try self.box_view.append(gpa, .{
            .text = try tool.text(gpa, now_ms),
            .fit = .head,
            .emphasis = .first_value,
        });
        for (self.streamed_tools.items) |streamed| try self.box_view.append(gpa, .{
            .text = streamed.box.items,
            .fit = .head,
            .emphasis = .first_value,
        });
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

const ActiveTool = struct {
    name: []const u8,
    input_json: []const u8,
    box: []const u8,
    started_ms: i64,
    timeout_ms: ?u64,
    rows: std.ArrayList(u8),

    fn deinit(self: *ActiveTool, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.input_json);
        gpa.free(self.box);
        self.rows.deinit(gpa);
    }

    fn text(self: *ActiveTool, gpa: std.mem.Allocator, now_ms: i64) ![]const u8 {
        const timeout_ms = self.timeout_ms orelse return self.box;
        var elapsed_buffer: [24]u8 = undefined;
        var limit_buffer: [24]u8 = undefined;
        const limit = ai.format.durationSeconds(&limit_buffer, @intCast(timeout_ms), .up);
        self.rows.clearRetainingCapacity();
        try self.rows.print(gpa, "{s}\nTime: {s} · Timeout: {s}", .{
            self.box,
            ai.format.durationSeconds(&elapsed_buffer, now_ms - self.started_ms, .down),
            limit,
        });
        return self.rows.items;
    }
};

const Picking = struct {
    picker: ui.Picker,
    selector: *const fn (
        *ai.command.Context,
        ai.command.Outcome.Pick.Selection,
    ) anyerror!ai.command.Outcome,
    payload: usize,
    cancellation_message: []const u8,
    reopen: ?ai.command.Outcome.Opener,
    trail: Trail,
    wait_tick: ?u64,

    pub fn select(
        self: *const Picking,
        context: *ai.command.Context,
        row: usize,
    ) anyerror!ai.command.Outcome {
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
        open: ai.command.Outcome.Opener,
        position: ui.Picker.Position,
    };

    fn push(
        self: *Trail,
        position: ui.Picker.Position,
        opener: ?ai.command.Outcome.Opener,
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

pub const Input = struct {
    owner: Owner = .terminal,
    caption: ?ui.Caption = null,

    pub const Owner = enum {
        terminal,
        external,
        none,
    };
};

const PendingEvent = struct {
    message: ai.command.Outcome.Message,
    options: AsyncEventOptions,
};

pub const AsyncEventOptions = struct {
    mirrored: bool = true,
};

pub const LiveTail = struct {
    streaming: ?ui.block.Entry.Kind,
    tool: ?[]const u8,
    calls: usize,
};

pub const TurnPrompt = struct {
    draft: ui.Editor.Draft,
    source: Source = .terminal,

    pub const Source = union(enum) {
        terminal,
        external: i64,
    };

    fn deinit(self: *TurnPrompt, gpa: std.mem.Allocator) void {
        self.draft.deinit(gpa);
    }
};

pub const Confirmation = enum {
    message,
    turn_cancel,
    quit,
};

pub const TurnEvent = struct {
    generation: u64,
    progress_sequence: u64 = 0,
    progress_sequence_committed: u64 = 0,
    payload: Payload,

    pub const Payload = union(enum) {
        text: []u8,
        thinking: []u8,
        tool_name: []u8,
        tool_arguments: []u8,
        tool_start: Tool,
        tool_result: ToolResult,
        usage: ai.Agent.Stats,
        stream_reset: ai.Agent.RetryAttempt,
        model_mismatch: ModelMismatch,
        skill_loaded: SkillLoaded,
        turn_ended,

        pub const Tool = struct { name: []u8, input_json: []u8 };
        pub const ToolResult = struct {
            name: []u8,
            summary: ?ai.tool.Result.Summary = null,
            is_error: bool,
        };
        pub const SkillLoaded = struct { skill: []u8, source: []u8 };
        pub const ModelMismatch = struct { requested: []u8, served: []u8 };
    };

    pub fn deinit(self: *const TurnEvent, gpa: std.mem.Allocator) void {
        switch (self.payload) {
            .text, .thinking, .tool_name, .tool_arguments => |bytes| gpa.free(bytes),
            .tool_start => |tool| {
                gpa.free(tool.name);
                gpa.free(tool.input_json);
            },
            .tool_result => |result| {
                gpa.free(result.name);
                if (result.summary) |summary| gpa.free(summary.text);
            },
            .skill_loaded => |loaded| {
                gpa.free(loaded.skill);
                gpa.free(loaded.source);
            },
            .model_mismatch => |mismatch| {
                gpa.free(mismatch.requested);
                gpa.free(mismatch.served);
            },
            .stream_reset => |retry| switch (retry.cause) {
                .failure => {},
                .response => |response| gpa.free(response),
            },
            .usage, .turn_ended => {},
        }
    }
};

pub fn init(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    model: ?ai.Model,
    effort: ai.llm.Effort,
) Session {
    var self: Session = .{
        .gpa = gpa,
        .transcript = Transcript.init(gpa),
        .notice = null,
        .confirmations = .initEmpty(),
        .editor = ui.Editor.init(gpa),
        .view = terminal.View.init(gpa, writer),
        .page_view = terminal.View.init(gpa, writer),
        .mode = .prompt,
        .columns = 80,
        .rows = 24,
        .dirty = false,
        .stats_shown = .{},
        .model_shown = model,
        .effort_shown = effort,
        .account_shown = .anthropic_plan,
        .directory_shown = "",
        .branch_root = null,
        .branch_buffer = undefined,
        .branch_length = 0,
        .pending_events = .empty,
        .turn_prompt = null,
        .input = .{},
        .clock_ms = 0,
        .boot_clock_ms = 0,
        .bash_timeout_ms = (ai.tool.Context.Bash{}).timeout_ms,
        .window_pages = layout.window_pages_default,
        .gauge = .{},
        .display_roots = .{},
    };
    self.page_view.preserveScrollback();
    return self;
}

pub fn deinit(self: *Session) void {
    self.deinitMode();
    self.clearNotice();
    for (self.pending_events.items) |pending| self.gpa.free(pending.message.content);
    self.pending_events.deinit(self.gpa);
    self.transcript.deinit();
    self.page_view.deinit();
    self.view.deinit();
    self.editor.deinit();
}

pub fn clearConversation(self: *Session) void {
    std.debug.assert(self.mode == .prompt);
    self.clearNotice();
    self.confirmations = .initEmpty();
    self.transcript.truncate(0);
    self.stats_shown = .{};
    self.view.resetScreen();
    self.dirty = true;
}

pub fn showSetup(
    self: *Session,
    account: ?ai.llm.Account,
    model: ?ai.Model,
    effort: ai.llm.Effort,
) void {
    const previous = self.projectionSetup();
    self.account_shown = account;
    self.model_shown = model;
    self.effort_shown = effort;
    if (self.transcript.projectionChanges(previous, self.projectionSetup()))
        self.view.resetScreen();
    self.dirty = true;
}

fn projectionSetup(self: *const Session) Transcript.Setup {
    const account = self.account_shown orelse
        return .{ .account = null, .replays_reasoning = true };
    const model = self.model_shown orelse
        return .{ .account = account, .replays_reasoning = true };
    const reasoning = model.reasoning(self.effort_shown);
    return .{
        .account = account,
        .replays_reasoning = reasoning.replaysReasoning(account.provider()),
    };
}

pub fn dropAccountReasoning(self: *Session, account: ai.llm.Account) void {
    std.debug.assert(self.mode == .prompt);
    const was_shown = Transcript.shows(account, self.projectionSetup());
    if (self.transcript.dropAccount(account) == 0) return;
    if (was_shown) self.view.resetScreen();
    self.dirty = true;
}

pub fn clearNotice(self: *Session) void {
    if (self.notice) |notice| {
        self.gpa.free(notice.content);
        self.notice = null;
        self.dirty = true;
    }
}

pub fn armConfirmation(self: *Session, confirmation: Confirmation) void {
    switch (confirmation) {
        .quit => std.debug.assert(self.mode == .prompt),
        .message => std.debug.assert(self.mode == .prompt),
        .turn_cancel => std.debug.assert(self.mode == .turn),
    }
    self.confirmations.insert(confirmation);
}

pub fn cancelConfirmation(self: *Session, confirmation: Confirmation) void {
    self.confirmations.remove(confirmation);
}

pub fn takeConfirmation(self: *Session, confirmation: Confirmation) bool {
    const confirmed = self.confirmations.contains(confirmation);
    self.confirmations.remove(confirmation);
    return confirmed;
}

fn setNotice(self: *Session, notice: ai.command.Outcome.Message) void {
    self.cancelConfirmation(.message);
    self.clearNotice();
    self.notice = notice;
    self.dirty = true;
}

fn showNotice(
    self: *Session,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) !void {
    self.setNotice(.{ .content = try self.gpa.dupe(u8, text), .severity = severity });
}

fn deinitMode(self: *Session) void {
    switch (self.mode) {
        .prompt => {},
        .turn => |*turn| {
            self.freeTurn(turn);
            self.dropTurnPrompt();
        },
        .picking => |*picking| picking.picker.deinit(),
        .viewing => |*page| page.deinit(),
    }
}

fn retryEventText(gpa: std.mem.Allocator, retry: *const ai.Agent.RetryAttempt) ![]u8 {
    return switch (retry.cause) {
        .failure => |failure| std.fmt.allocPrint(
            gpa,
            "Drinky started retry attempt {d} because of error {s}.",
            .{ retry.attempt, @errorName(failure) },
        ),
        .response => |response| if (response.len == 0)
            std.fmt.allocPrint(
                gpa,
                "Drinky started retry attempt {d} because the provider rejected the " ++
                    "request without error text.",
                .{retry.attempt},
            )
        else
            std.fmt.allocPrint(
                gpa,
                "Drinky started retry attempt {d} because the provider reported \"{s}\".",
                .{ retry.attempt, response },
            ),
    };
}

fn acceptsCanceledTurnEvent(self: *const Session, event: *const TurnEvent) bool {
    const turn = switch (self.mode) {
        .turn => |*turn| turn,
        else => return false,
    };
    if (event.generation != turn.generation) return false;
    if (event.progress_sequence == 0) return true;
    if (turn.progress_sequence_applied == std.math.maxInt(u64)) return false;
    return event.progress_sequence == turn.progress_sequence_applied + 1;
}

pub fn applyTurnEvent(self: *Session, event: *const TurnEvent) !bool {
    defer event.deinit(self.gpa);
    const turn = self.activeTurn() orelse return false;
    if (event.generation != turn.generation) return false;
    if (event.progress_sequence != 0) {
        std.debug.assert(event.progress_sequence == turn.progress_sequence_applied + 1);
        std.debug.assert(event.progress_sequence_committed <= turn.progress_sequence_applied);
        if (event.progress_sequence_committed > turn.progress_sequence_checkpoint) {
            self.transcript.endMessage();
            turn.transcript_checkpoint = self.transcript.blocks().len;
            turn.progress_sequence_checkpoint = event.progress_sequence_committed;
        }
    }
    self.dirty = true;
    if (!self.transcript.streaming()) try self.flushPendingEvents();
    switch (event.payload) {
        .text => |delta| {
            self.dropStaleTools(turn);
            try self.transcript.appendStream(.model, null, delta);
        },
        .thinking => |delta| {
            self.dropStaleTools(turn);
            try self.transcript.appendStream(.thinking, self.account_shown, delta);
        },
        .tool_name => |name| {
            self.dropStaleTools(turn);
            try self.openStreamedTool(turn, name);
        },
        .tool_arguments => |delta| try self.growStreamedTool(turn, delta),
        .tool_start => |*tool| {
            self.transcript.endMessage();
            try self.flushPendingEvents();
            try self.pushTool(turn, tool);
            turn.calls += 1;
            try self.dropStreamedTool(turn, tool.name);
        },
        .tool_result => |result| try self.applyToolResult(result),
        .usage => |stats| self.stats_shown = stats,
        .stream_reset => |retry| {
            self.transcript.discardMessage();
            try self.flushPendingEvents();
            self.clearStreamedTools(turn);
            const text = try retryEventText(self.gpa, &retry);
            defer self.gpa.free(text);
            try self.transcript.append(
                .event,
                .{ .survives_rewind = true },
                text,
            );
        },
        .model_mismatch => |mismatch| {
            const text = try std.fmt.allocPrint(
                self.gpa,
                "The provider answered with the model \"{s}\" instead of the requested " ++
                    "model \"{s}\".",
                .{ mismatch.served, mismatch.requested },
            );
            defer self.gpa.free(text);
            try self.transcript.append(.event, .{ .is_warning = true }, text);
        },
        .skill_loaded => |loaded| {
            const source = try ai.format.path(self.gpa, loaded.source, &self.display_roots);
            defer self.gpa.free(source);
            const text = try std.fmt.allocPrint(
                self.gpa,
                "Skill: {s} · File: {s}",
                .{ loaded.skill, source },
            );
            defer self.gpa.free(text);
            try self.transcript.append(.user_note, .{}, text);
        },
        .turn_ended => {
            turn.progress_sequence_applied = event.progress_sequence;
            return true;
        },
    }
    turn.progress_tick_last = turn.activity_tick;
    if (event.progress_sequence != 0)
        turn.progress_sequence_applied = event.progress_sequence;
    return false;
}

pub fn applyCanceledTurnEvent(self: *Session, event: *const TurnEvent) !void {
    if (!self.acceptsCanceledTurnEvent(event)) {
        event.deinit(self.gpa);
        return;
    }
    _ = try self.applyTurnEvent(event);
}

fn applyToolResult(self: *Session, result: TurnEvent.Payload.ToolResult) !void {
    var finished = if (self.activeTurn()) |turn| takeTool(turn, result.name) else null;
    defer if (finished) |*tool| tool.deinit(self.gpa);
    if (finished) |tool| return self.appendToolBlock(&.{
        .head = tool.box,
        .detail = result.summary,
        .is_error = result.is_error,
    });
    const head = try toolRow(self.gpa, result.name, &.{
        .label = "",
        .subject = "",
        .timeout_ms = null,
    });
    defer self.gpa.free(head);
    try self.appendToolBlock(&.{
        .head = head,
        .detail = result.summary,
        .is_error = result.is_error,
    });
}

const ToolBlock = struct {
    head: []const u8,
    detail: ?ai.tool.Result.Summary,
    is_error: bool,
};

fn appendToolBlock(self: *Session, block: *const ToolBlock) !void {
    const detail = block.detail orelse
        return self.transcript.append(.tool_result, .{ .is_error = block.is_error }, block.head);
    const sentence = detail.kind == .sentence;
    const options: ui.block.Entry.Options = .{
        .is_error = block.is_error,
        .fit = if (sentence) .wrap else .head,
    };
    const text = if (sentence and block.is_error)
        try std.fmt.allocPrint(self.gpa, "{s}\nError: {s}", .{ block.head, detail.text })
    else
        try std.fmt.allocPrint(self.gpa, "{s}\n{s}", .{ block.head, detail.text });
    defer self.gpa.free(text);
    try self.transcript.append(.tool_result, options, text);
}

fn eventFlags(severity: ai.command.Outcome.Severity) ui.block.Entry.Options {
    return .{
        .is_error = severity == .failure,
        .is_warning = severity == .warning,
    };
}

fn appendEvent(self: *Session, message: ai.command.Outcome.Message) !void {
    defer self.gpa.free(message.content);
    try self.transcript.append(.event, eventFlags(message.severity), message.content);
}

pub fn replaceEvent(self: *Session, index: usize, message: ai.command.Outcome.Message) !void {
    defer self.gpa.free(message.content);
    try self.transcript.replaceEvent(index, eventFlags(message.severity), message.content);
    self.dirty = true;
}

pub fn recordAsyncEvent(
    self: *Session,
    message: ai.command.Outcome.Message,
    options: AsyncEventOptions,
) !void {
    const pending: PendingEvent = .{ .message = message, .options = options };
    if (!self.transcript.streaming()) {
        defer self.gpa.free(message.content);
        try self.appendAsyncEvent(&pending);
        self.dirty = true;
        return;
    }
    errdefer self.gpa.free(message.content);
    try self.pending_events.append(self.gpa, pending);
}

fn appendAsyncEvent(self: *Session, pending: *const PendingEvent) !void {
    var options = eventFlags(pending.message.severity);
    options.survives_rewind = true;
    options.mirrored = pending.options.mirrored;
    if (try self.transcript.repeatEvent(options, pending.message.content)) return;
    try self.transcript.append(.event, options, pending.message.content);
}

fn flushPendingEvents(self: *Session) !void {
    std.debug.assert(!self.transcript.streaming());
    while (self.pending_events.items.len > 0) {
        const pending = self.pending_events.items[0];
        try self.appendAsyncEvent(&pending);
        self.gpa.free(pending.message.content);
        _ = self.pending_events.orderedRemove(0);
    }
    self.dirty = true;
}

pub fn applyOutcome(self: *Session, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .notice, .refusal => |message| self.setNotice(message),
        .event => |event| try self.appendEvent(event),
        .pick => |*pick| try self.openPicker(pick),
        .editor_text => |text| {
            defer self.gpa.free(text);
            self.editor.clear();
            try self.editor.insert(text);
            self.markEdited();
        },
        .prompt,
        .login_picker,
        .login,
        .logout,
        .switch_account,
        .fetch,
        .new_conversation,
        .show_sources,
        .show_system_prompt,
        .remote_attach,
        .remote_add,
        .remote_remove,
        => unreachable,
    }
    self.dirty = true;
}

fn openPicker(self: *Session, pick: *const ai.command.Outcome.Pick) !void {
    var trail: Trail = .{};
    if (self.mode == .picking) {
        trail = self.mode.picking.trail;
        if (!sameStep(self.mode.picking.reopen, pick.reopen))
            trail.push(self.mode.picking.picker.position(), self.mode.picking.reopen);
    }
    return self.enterPicker(pick, trail, null);
}

fn sameStep(step: ?ai.command.Outcome.Opener, other: ?ai.command.Outcome.Opener) bool {
    const step_open = step orelse return false;
    const other_open = other orelse return false;
    return step_open == other_open;
}

pub fn openPickerAbove(self: *Session, pick: *const ai.command.Outcome.Pick) !void {
    std.debug.assert(self.mode == .picking);
    var trail = self.mode.picking.trail;
    const entry = trail.last().?;
    trail.dropLast();
    return self.enterPicker(pick, trail, entry.position);
}

pub fn stepAbove(self: *const Session) ?ai.command.Outcome.Opener {
    return switch (self.mode) {
        .picking => |*picking| if (picking.trail.last()) |entry| entry.open else null,
        else => null,
    };
}

fn enterPicker(
    self: *Session,
    pick: *const ai.command.Outcome.Pick,
    trail: Trail,
    position: ?ui.Picker.Position,
) !void {
    if (pick.report) |message| {
        errdefer freePickOptions(self.gpa, pick.options);
        try self.appendEvent(message);
    }
    const rows = blk: {
        errdefer freePickOptions(self.gpa, pick.options);
        break :blk try takePickerOptions(self.gpa, pick.options);
    };
    errdefer freePickerOptions(self.gpa, rows);
    const picker = try ui.Picker.init(self.gpa, pick.title, rows, .{
        .current = pick.current,
        .preselected = pick.preselected,
        .position = position,
        .can_step_back = trail.len > 0,
    });
    self.deinitMode();
    self.mode = .{ .picking = .{
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

pub fn closePicker(self: *Session) void {
    switch (self.mode) {
        .picking => |*picking| {
            picking.picker.deinit();
            self.mode = .prompt;
            self.dirty = true;
        },
        else => {},
    }
}

pub fn openWait(self: *Session, pick: *const ai.command.Outcome.Pick, text: []const u8) !void {
    std.debug.assert(pick.options.len == 0);
    try self.enterPicker(pick, .{}, null);
    try self.beginPickerWait(text);
}

pub fn setPickerWait(self: *Session, text: []const u8, url: ?[]const u8) !void {
    std.debug.assert(self.pickerWaits());
    try self.mode.picking.picker.beginLinkedWait(text, url);
    self.dirty = true;
}

pub fn beginPickerWait(self: *Session, text: []const u8) !void {
    std.debug.assert(self.mode == .picking);
    const picking = &self.mode.picking;
    try picking.picker.beginWait(text);
    picking.wait_tick = 0;
    self.dirty = true;
}

pub fn pickerWaits(self: *const Session) bool {
    return switch (self.mode) {
        .picking => |*picking| picking.wait_tick != null,
        else => false,
    };
}

pub fn cancelPicker(self: *Session) !void {
    const cancellation_message = switch (self.mode) {
        .picking => |picking| picking.cancellation_message,
        else => return,
    };
    self.closePicker();
    try self.showNotice(.information, cancellation_message);
}

pub fn openPage(self: *Session, options: *const ui.Page.Options) !void {
    std.debug.assert(self.mode == .prompt);
    var page = try ui.Page.init(self.gpa, options);
    page.reflow(.{ .columns = self.columns, .rows = self.rows });
    self.page_view.forget();
    self.page_view.invalidate();
    self.mode = .{ .viewing = page };
    self.dirty = true;
}

pub fn closePage(self: *Session) void {
    switch (self.mode) {
        .viewing => |*page| {
            page.deinit();
            self.mode = .prompt;
            self.dirty = true;
        },
        else => {},
    }
}

fn restorablePrompt(self: *Session) ?*ui.Editor.Draft {
    const prompt = if (self.turn_prompt) |*prompt| prompt else return null;
    if (prompt.source == .terminal or self.input.owner != .external) return &prompt.draft;
    return null;
}

fn markTurnBase(self: *Session, transcript_base: usize) void {
    const turn = self.activeTurn() orelse unreachable;
    std.debug.assert(transcript_base <= self.transcript.blocks().len);
    turn.transcript_checkpoint = transcript_base;
}

pub fn retainTurnPrompt(self: *Session, prompt: *ui.Editor.Draft, transcript_base: usize) void {
    std.debug.assert(self.turn_prompt == null);
    self.markTurnBase(transcript_base);
    self.turn_prompt = .{ .draft = prompt.* };
    prompt.* = .empty;
}

pub fn retainExternalTurnPrompt(
    self: *Session,
    prompt: *ui.Editor.Draft,
    transcript_base: usize,
    id: i64,
) void {
    std.debug.assert(self.turn_prompt == null);
    self.markTurnBase(transcript_base);
    self.turn_prompt = .{ .draft = prompt.*, .source = .{ .external = id } };
    prompt.* = .empty;
}

fn dropTurnPrompt(self: *Session) void {
    if (self.turn_prompt) |*prompt| {
        prompt.deinit(self.gpa);
        self.turn_prompt = null;
    }
}

pub fn reservePromptRestore(self: *Session) !void {
    const lead = self.restorablePrompt() orelse return;
    try self.editor.reserveDraft(lead);
}

pub fn reserveFailureRestore(self: *Session, receipt: *const ai.Agent.Receipt) !void {
    const committed = receipt.history_end != receipt.history_base;
    if (committed) return;
    try self.reservePromptRestore();
}

pub fn beginTurn(self: *Session, generation: u64) void {
    self.transcript.endMessage();
    self.confirmations = .initEmpty();
    self.stats_shown.forgetTurnEvidence();
    self.mode = .{ .turn = .{
        .generation = generation,
        .progress_sequence_applied = 0,
        .progress_sequence_checkpoint = 0,
        .transcript_checkpoint = self.transcript.blocks().len,
        .activity_tick = 0,
        .progress_tick_last = 0,
        .caret_tick = 0,
        .calls = 0,
        .tools = .empty,
        .streamed_tools = .empty,
        .box_view = .empty,
        .box_hashes = .empty,
        .box_tracks = .empty,
    } };
    self.dirty = true;
}

pub fn committedCount(self: *const Session) usize {
    return switch (self.mode) {
        .turn => |*turn| turn.transcript_checkpoint,
        else => self.transcript.blocks().len,
    };
}

pub fn liveTail(self: *const Session) ?LiveTail {
    const turn = switch (self.mode) {
        .turn => |*turn| turn,
        else => return null,
    };
    return .{
        .streaming = if (self.transcript.current) |current| current.kind else null,
        .tool = if (turn.tools.items.len > 0)
            turn.tools.items[turn.tools.items.len - 1].name
        else
            null,
        .calls = turn.calls,
    };
}

fn flushRunningTools(self: *Session) ?anyerror {
    const turn = self.activeTurn() orelse return null;
    var maybe_error: ?anyerror = null;
    for (turn.tools.items) |*tool| {
        self.appendToolBlock(&.{
            .head = tool.box,
            .detail = .{ .text = ai.Agent.unfinished_tool_result, .kind = .sentence },
            .is_error = true,
        }) catch |err| {
            if (maybe_error == null) maybe_error = err;
        };
        tool.deinit(self.gpa);
    }
    turn.tools.clearRetainingCapacity();
    return maybe_error;
}

pub fn abortTurn(self: *Session) !void {
    const maybe_flush_error = self.flushRunningTools();
    self.endTurn();
    self.dirty = true;
    try self.transcript.append(.event, turn_event_options, "You canceled the turn.");
    if (maybe_flush_error) |flush_error| return flush_error;
}

pub fn endTurnWithReceipt(self: *Session, receipt: *const ai.Agent.Receipt) !void {
    self.dropTurnPrompt();
    if (receipt.truncated)
        try self.transcript.append(.event, turn_failure_options, truncated_event);
    self.transcript.endMessage();
    self.endTurn();
}

pub fn failTurnWithReceipt(
    self: *Session,
    receipt: *const ai.Agent.Receipt,
    error_text: ?[]const u8,
) !void {
    self.reconcileAbnormalReceipt(receipt);
    const maybe_flush_error = self.flushRunningTools();
    if (receipt.truncated)
        try self.transcript.append(.event, turn_failure_options, truncated_event);
    if (error_text) |text| try self.transcript.append(.event, turn_failure_options, text);
    self.transcript.endMessage();
    self.endTurn();
    if (maybe_flush_error) |flush_error| return flush_error;
}

pub fn cancelReceipt(
    self: *Session,
    receipt: *const ai.Agent.Receipt,
    progress_sequence_committed: u64,
) void {
    const turn = self.activeTurn() orelse unreachable;
    if (progress_sequence_committed > turn.progress_sequence_checkpoint and
        progress_sequence_committed == turn.progress_sequence_applied)
    {
        self.transcript.endMessage();
        turn.transcript_checkpoint = self.transcript.blocks().len;
        turn.progress_sequence_checkpoint = progress_sequence_committed;
    }
    self.reconcileAbnormalReceipt(receipt);
}

fn reconcileAbnormalReceipt(self: *Session, receipt: *const ai.Agent.Receipt) void {
    const turn = self.activeTurn() orelse unreachable;
    self.transcript.rewind(turn.transcript_checkpoint);

    const committed = receipt.history_end != receipt.history_base;
    if (!committed) {
        if (self.restorablePrompt()) |lead| self.editor.prependDraft(lead);
    }
    self.dropTurnPrompt();
    self.dirty = true;
}

pub fn setBranch(self: *Session, name: []const u8) void {
    const value = if (name.len > self.branch_buffer.len) "" else name;
    if (std.mem.eql(u8, self.branch_buffer[0..self.branch_length], value)) return;
    @memcpy(self.branch_buffer[0..value.len], value);
    self.branch_length = value.len;
    self.dirty = true;
}

pub fn branch(self: *const Session) ?[]const u8 {
    if (self.branch_length == 0) return null;
    return self.branch_buffer[0..self.branch_length];
}

pub fn endTurn(self: *Session) void {
    if (self.activeTurn()) |turn| self.freeTurn(turn);
    self.dropTurnPrompt();
    self.clearNotice();
    self.confirmations = .initEmpty();
    self.mode = .prompt;
    self.transcript.endMessage();
    self.flushPendingEvents() catch {};
}

pub fn paint(self: *Session, size: terminal.View.Size) !void {
    self.columns = size.columns;
    self.rows = size.rows;
    switch (self.mode) {
        .viewing => |*page| {
            page.reflow(size);
            const scene: layout.Scene = .{ .page = page };
            try layout.project(self.gpa, &self.page_view, size, &scene);
            return;
        },
        else => {},
    }

    const status = self.statusInfo();

    const tail: layout.Tail = switch (self.mode) {
        .prompt => prompt: {
            self.editor.reflow(size);
            break :prompt .{
                .prompt = .{
                    .caption = self.input.caption,
                    .editor = &self.editor,
                },
            };
        },
        .turn => |*turn| turn: {
            self.editor.reflow(size);
            const tools = try turn.boxes(self.gpa, self.clock_ms);
            const tracks = try turn.trackBoxes(self.gpa);
            break :turn .{
                .turn = .{
                    .tools = tools,
                    .tracks = tracks,
                    .activity = turn.activity(),
                    .caption = self.input.caption,
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
        .viewing => unreachable,
    };
    const scene: layout.Scene = .{ .conversation = .{
        .window_pages = self.window_pages,
        .transcript = try self.transcript.projection(self.projectionSetup()),
        .tail = tail,
        .status = &status,
    } };
    try layout.project(self.gpa, &self.view, size, &scene);
}

pub fn statusInfo(self: *const Session) ui.status.Info {
    return .{
        .directory = self.directory_shown,
        .branch = self.branch(),
        .context_tokens = self.stats_shown.context_tokens,
        .cache_usage = self.stats_shown.cache_usage,
        .cost = self.stats_shown.cost,
        .context_window = if (self.model_shown) |model| model.context_window else null,
        .model = if (self.model_shown) |*model| model.name() else null,
        .effort = @tagName(self.effort_shown),
        .account = self.account_shown,
        .quota = self.stats_shown.quota,
        .quota_age_ms = self.boot_clock_ms - self.stats_shown.quota_seen_ms,
        .credits = self.stats_shown.credits,
        .turn_active = self.mode == .turn,
        .gauge = self.gauge,
        .notice = if (self.notice) |notice| .{
            .text = notice.content,
            .severity = notice.severity,
        } else null,
    };
}

pub fn parkCursor(self: *Session) !void {
    try self.view.parkCursor();
}

pub fn markEdited(self: *Session) void {
    self.dirty = true;
    if (self.activeTurn()) |turn| turn.caret_tick = 0;
}

pub fn advanceFrame(self: *Session) bool {
    var activity_changed = false;
    switch (self.mode) {
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
        .prompt, .viewing => {},
    }
    return self.dirty or activity_changed;
}

pub fn animating(self: *const Session) bool {
    return switch (self.mode) {
        .turn => true,
        .picking => |*picking| picking.wait_tick != null,
        .prompt, .viewing => false,
    };
}

fn activeTurn(self: *Session) ?*Turn {
    return switch (self.mode) {
        .turn => |*turn| turn,
        else => null,
    };
}

fn toolRow(gpa: std.mem.Allocator, name: []const u8, call: *const ai.tool.Call) ![]u8 {
    if (call.subject.len == 0) return std.fmt.allocPrint(gpa, "Tool: {s}", .{name});
    return std.fmt.allocPrint(gpa, "Tool: {s} · {s}: {s}", .{ name, call.label, call.subject });
}

fn pushTool(self: *Session, turn: *Turn, tool: *const TurnEvent.Payload.Tool) !void {
    const gpa = self.gpa;
    const call = try ai.tool.describe(
        gpa,
        tool.name,
        tool.input_json,
        &self.display_roots,
        self.bash_timeout_ms,
    );
    defer call.deinit(gpa);
    const box = try toolRow(gpa, tool.name, &call);
    errdefer gpa.free(box);
    const name_copy = try gpa.dupe(u8, tool.name);
    errdefer gpa.free(name_copy);
    const arguments = try gpa.dupe(u8, tool.input_json);
    errdefer gpa.free(arguments);
    try turn.tools.append(gpa, .{
        .name = name_copy,
        .input_json = arguments,
        .box = box,
        .started_ms = self.clock_ms,
        .timeout_ms = call.timeout_ms,
        .rows = .empty,
    });
}

fn openStreamedTool(self: *Session, turn: *Turn, name: []const u8) !void {
    if (turn.streamed_tools.items.len > 0) {
        const last = &turn.streamed_tools.items[turn.streamed_tools.items.len - 1];
        if (last.phase == .streaming) {
            last.phase = .queued;
            try last.refresh(self.gpa);
        }
    }
    var streamed: StreamedTool = .{
        .name = try self.gpa.dupe(u8, name),
        .bytes = 0,
        .phase = .streaming,
        .box = .empty,
    };
    errdefer streamed.deinit(self.gpa);
    try streamed.refresh(self.gpa);
    try turn.streamed_tools.append(self.gpa, streamed);
}

fn growStreamedTool(self: *Session, turn: *Turn, delta: []const u8) !void {
    if (turn.streamed_tools.items.len == 0) return;
    const streamed = &turn.streamed_tools.items[turn.streamed_tools.items.len - 1];
    if (streamed.phase != .streaming) return;
    streamed.bytes += delta.len;
    try streamed.refresh(self.gpa);
}

fn dropStreamedTool(self: *Session, turn: *Turn, name: []const u8) !void {
    for (turn.streamed_tools.items, 0..) |streamed, index| {
        if (!std.mem.eql(u8, streamed.name, name)) continue;
        var found = turn.streamed_tools.orderedRemove(index);
        found.deinit(self.gpa);
        break;
    }
    for (turn.streamed_tools.items) |*streamed| {
        if (streamed.phase == .stale) continue;
        streamed.phase = .stale;
        try streamed.refresh(self.gpa);
    }
}

fn dropStaleTools(self: *Session, turn: *Turn) void {
    var index: usize = 0;
    while (index < turn.streamed_tools.items.len) {
        if (turn.streamed_tools.items[index].phase != .stale) {
            index += 1;
            continue;
        }
        var stale = turn.streamed_tools.orderedRemove(index);
        stale.deinit(self.gpa);
    }
}

fn clearStreamedTools(self: *Session, turn: *Turn) void {
    for (turn.streamed_tools.items) |*streamed| streamed.deinit(self.gpa);
    turn.streamed_tools.clearRetainingCapacity();
}

fn takeTool(turn: *Turn, name: []const u8) ?ActiveTool {
    for (turn.tools.items, 0..) |tool, index| {
        if (std.mem.eql(u8, tool.name, name)) return turn.tools.orderedRemove(index);
    }
    if (turn.tools.items.len == 0) return null;
    return turn.tools.orderedRemove(0);
}

fn freeTurn(self: *Session, turn: *Turn) void {
    for (turn.tools.items) |*tool| tool.deinit(self.gpa);
    turn.tools.deinit(self.gpa);
    self.clearStreamedTools(turn);
    turn.streamed_tools.deinit(self.gpa);
    turn.box_view.deinit(self.gpa);
    turn.box_hashes.deinit(self.gpa);
    turn.box_tracks.deinit(self.gpa);
}

const test_model = ai.testing.model("claude-sonnet-4-6");

const test_model_openai = ai.testing.model("gpt-5.6-sol");

const replaying_effort: ai.llm.Effort = .high;

const test_model_closed = blk: {
    var model = test_model;
    model.efforts_denied = true;
    break :blk model;
};

fn applyEvent(session: *Session, generation: u64, payload: TurnEvent.Payload) !void {
    _ = try session.applyTurnEvent(&.{ .generation = generation, .payload = payload });
}

fn expectPainted(gpa: std.mem.Allocator, painted: []const u8, text: []const u8) !void {
    const plain = try terminal.View.plainText(gpa, painted);
    defer gpa.free(plain);
    if (std.mem.indexOf(u8, plain, text) != null) return;
    std.debug.print("the frame holds no row with \"{s}\":\n{s}\n", .{ text, plain });
    return error.TestExpectedRow;
}

fn applyFinishedToolRound(session: *Session) !void {
    const gpa = session.gpa;
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "answer") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "bash"),
            .input_json = try gpa.dupe(u8, "{}"),
        } },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_result = .{
            .name = try gpa.dupe(u8, "bash"),
            .summary = .{ .text = try gpa.dupe(u8, "Time: 0ms · Exit code: 0") },
            .is_error = false,
        } },
    });
}

fn finishTurn(session: *Session) !void {
    try session.endTurnWithReceipt(&.{ .history_base = 0, .history_end = 0 });
}

test "a read chunk drives the editor and paints the result" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var input = terminal.Input.init(gpa);
    defer input.deinit();
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    try input.feed("he\x7fllo");
    while (input.next()) |event| switch (event) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .backspace => editor.backspace(),
        else => {},
    };
    const sink = try view.beginFrame(.{ .columns = 80, .rows = 24 }, 4);
    const placement: ui.paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 80,
        .base = 0,
        .skip = 0,
    };
    try editor.render(&placement, &.{ .viewport_rows = 24 });
    try view.render();

    try std.testing.expectEqualStrings("hllo", editor.visible());
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hllo") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.sync_set) != null);
}

test "a bracketed paste cannot emit terminal controls" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var input = terminal.Input.init(gpa);
    defer input.deinit();
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    const payload = "paste\x1b[9A\x1b]52;c;cGFzdGU=\x07\x1bPdata\x1b\\done";
    try input.feed(terminal.escape.paste_begin ++ payload ++ terminal.escape.paste_end);
    const event = input.next().?;
    switch (event) {
        .paste => |paste| try editor.paste(paste.bytes, paste.final),
        else => return error.UnexpectedInput,
    }
    const sink = try view.beginFrame(.{ .columns = 120, .rows = 24 }, 4);
    const placement: ui.paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 120,
        .base = 0,
        .skip = 0,
    };
    try editor.render(&placement, &.{ .viewport_rows = 24 });
    try view.render();

    const painted = out.written();
    for ([_][]const u8{
        "paste", "[9A", "]52;c;cGFzdGU=", "Pdata", "done",
        "\u{200B}�\u{200B}",
    }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, painted, text) != null);
    }
    for ([_][]const u8{ "\x1b[9A", "\x1b]52;c;cGFzdGU=\x07", "\x1bPdata\x1b\\" }) |control| {
        try std.testing.expect(std.mem.indexOf(u8, painted, control) == null);
    }
}

test "a large bracketed paste collapses to a marker through the real pipeline" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var input = terminal.Input.init(gpa);
    defer input.deinit();
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    const payload = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk";
    try input.feed(terminal.escape.paste_begin ++ payload ++ terminal.escape.paste_end);
    while (input.next()) |event| switch (event) {
        .paste => |paste| try editor.paste(paste.bytes, paste.final),
        else => return error.UnexpectedInput,
    };
    try std.testing.expectEqualStrings("\u{200B}[Paste #1: 11 lines]\u{200B}", editor.visible());

    const sink = try view.beginFrame(.{ .columns = 80, .rows = 24 }, 4);
    const placement: ui.paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = 80,
        .base = 0,
        .skip = 0,
    };
    try editor.render(&placement, &.{ .viewport_rows = 24 });
    try view.render();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[Paste #1: 11 lines]") != null);

    const expanded = try editor.expanded(.whole_prompt);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(payload, expanded);
}

test "a turn end drops the notice of the turn" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.beginTurn(1);
    try session.applyOutcome(try ai.command.Outcome.reportNotice(
        gpa,
        .warning,
        "The command /model cannot run while a turn runs.",
        .{},
    ));
    try session.abortTurn();

    try std.testing.expect(session.mode == .prompt);
    try std.testing.expect(session.notice == null);
}

test "a turn boundary drops the turn-cancel confirmation" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.beginTurn(1);
    session.armConfirmation(.turn_cancel);
    session.endTurn();
    session.beginTurn(2);
    try std.testing.expect(!session.takeConfirmation(.turn_cancel));
    session.endTurn();
}

test "a new notice drops the send-as-a-message confirmation" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.armConfirmation(.message);
    try session.applyOutcome(try ai.command.Outcome.reportNotice(
        gpa,
        .failure,
        "Drinky could not read the file.",
        .{},
    ));

    try std.testing.expect(!session.takeConfirmation(.message));
    try std.testing.expectEqualStrings(
        "Drinky could not read the file.",
        session.notice.?.content,
    );
}

test "a notice replaces its predecessor without entering the transcript" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .information, "First notice.", .{}),
    );
    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "Second notice.", .{}),
    );

    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expectEqualStrings("Second notice.", session.notice.?.content);
    try std.testing.expectEqual(ai.command.Outcome.Severity.failure, session.notice.?.severity);
    session.clearNotice();
    try std.testing.expect(session.notice == null);
}

test "a picker that waits drops its rows, animates, and keeps its trail" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 24 };
    const account_step = struct {
        fn open(_: *ai.command.Context) anyerror!ai.command.Outcome {
            unreachable;
        }
    }.open;
    const model_step = struct {
        fn open(_: *ai.command.Context) anyerror!ai.command.Outcome {
            unreachable;
        }
    }.open;

    try session.applyOutcome(.{ .pick = try pickForTest(gpa, "Account", account_step) });
    try session.applyOutcome(.{ .pick = try pickForTest(gpa, "Model", model_step) });
    try std.testing.expect(!session.pickerWaits());
    try std.testing.expect(!session.animating());
    session.dirty = false;

    try session.beginPickerWait("Drinky fetches the model list.");
    try std.testing.expect(session.pickerWaits());
    try std.testing.expect(session.animating());
    try std.testing.expect(session.dirty);
    try std.testing.expectEqual(@as(usize, 1), session.mode.picking.trail.len);
    try std.testing.expectEqual(@as(usize, 0), session.mode.picking.picker.options.len);

    try session.paint(size);
    session.dirty = false;
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(u64, 1), session.mode.picking.wait_tick.?);
    try session.paint(size);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Drinky fetches") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Esc: Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "━") != null);

    try session.applyOutcome(.{ .pick = try pickForTest(gpa, "Model", model_step) });
    try std.testing.expect(!session.pickerWaits());
    try std.testing.expect(!session.animating());
    try std.testing.expectEqual(@as(usize, 1), session.mode.picking.trail.len);
    try std.testing.expect(session.mode.picking.trail.last().?.open == account_step);
    try std.testing.expectEqual(@as(usize, 1), session.mode.picking.picker.options.len);

    try session.beginPickerWait("Drinky fetches the model list.");
    session.closePicker();
    try std.testing.expect(!session.pickerWaits());
    try std.testing.expect(!session.animating());
}

test "a picker that reports records its line and still opens its list" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    const options = try gpa.alloc(ai.command.Outcome.Pick.Option, 1);
    options[0] = .{ .name = try gpa.dupe(u8, "claude-sonnet-4-6") };
    try session.applyOutcome(.{ .pick = .{
        .select = undefined,
        .title = "Model",
        .cancellation_message = "You canceled the model selection.",
        .options = options,
        .current = null,
        .report = .{
            .content = try gpa.dupe(u8, "Drinky could not save the list."),
            .severity = .failure,
        },
    } });

    try std.testing.expect(session.mode == .picking);
    try std.testing.expect(session.notice == null);
    const failure_blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), failure_blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky could not save the list.",
        failure_blocks[0].content.event.text.items,
    );
    try std.testing.expect(failure_blocks[0].content.event.is_error);
    try std.testing.expect(!failure_blocks[0].content.event.is_warning);

    session.closePicker();
    const empty_options = try gpa.alloc(ai.command.Outcome.Pick.Option, 1);
    empty_options[0] = .{ .name = try gpa.dupe(u8, "Fetch the model list") };
    try session.applyOutcome(.{ .pick = .{
        .select = undefined,
        .title = "Model",
        .cancellation_message = "You canceled the model selection.",
        .options = empty_options,
        .current = null,
        .report = .{
            .content = try gpa.dupe(u8, "The account offers no model now."),
            .severity = .warning,
        },
    } });

    try std.testing.expect(session.mode == .picking);
    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings(
        "The account offers no model now.",
        blocks[1].content.event.text.items,
    );
    try std.testing.expect(blocks[1].content.event.is_warning);
    try std.testing.expect(!blocks[1].content.event.is_error);
}

test "a notice replaces the footer and clearing restores the status" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try session.paint(.{ .columns = 80, .rows = 24 });
    const notice_start = out.written().len;
    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "Temporary notice.", .{}),
    );
    try session.paint(.{ .columns = 80, .rows = 24 });
    const notice_frame = out.written()[notice_start..];
    try std.testing.expect(std.mem.indexOf(u8, notice_frame, "⚠ Temporary notice.") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice_frame, test_model.name()) == null);

    const status_start = out.written().len;
    session.clearNotice();
    try session.paint(.{ .columns = 80, .rows = 24 });
    const status_frame = out.written()[status_start..];
    try std.testing.expect(std.mem.indexOf(u8, status_frame, test_model.name()) != null);
}

test "the status line borrows the model name of the session" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    const info = session.statusInfo();
    try std.testing.expectEqual(session.model_shown.?.name().ptr, info.model.?.ptr);
    try std.testing.expectEqualStrings(test_model.name(), info.model.?);

    session.model_shown = null;
    try std.testing.expect(session.statusInfo().model == null);
}

test "the status line states the billing reports of the shown stats" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try std.testing.expect(session.statusInfo().quota == null);
    try std.testing.expect(session.statusInfo().credits == null);

    session.stats_shown.quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };
    session.stats_shown.credits = .{ .total = 10, .used = 2.86 };
    const info = session.statusInfo();
    try std.testing.expectEqual(@as(f64, 25), info.quota.?.primary.?.used_percent);
    try std.testing.expectEqual(@as(f64, 10), info.credits.?.total);
    try std.testing.expectEqual(@as(f64, 2.86), info.credits.?.used);
}

test "a new turn hides the last turn's cache, quota, and credits" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.stats_shown.cache_usage = .{ .input = 10, .cache_read = 90 };
    session.stats_shown.quota = .{ .primary = .{ .used_percent = 25, .window_minutes = 300 } };
    session.stats_shown.credits = .{ .total = 10, .used = 2.86 };
    session.stats_shown.quota_seen_ms = 1;
    session.beginTurn(1);

    const info = session.statusInfo();
    try std.testing.expect(info.turn_active);
    try std.testing.expectEqual(ai.llm.Usage{}, info.cache_usage);
    try std.testing.expect(info.quota == null);
    try std.testing.expect(info.credits == null);
}

test "a confirmation is one-shot and separate from its notice" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .warning, "A warning.", .{}),
    );
    session.armConfirmation(.message);
    session.clearNotice();
    try std.testing.expect(session.takeConfirmation(.message));
    try std.testing.expect(!session.takeConfirmation(.message));

    session.armConfirmation(.message);
    session.cancelConfirmation(.message);
    try std.testing.expect(!session.takeConfirmation(.message));
}

test "an event survives notice clearing until a conversation clear discards it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try session.applyOutcome(
        try ai.command.Outcome.reportEvent(gpa, .information, "Drinky changed the model.", .{}),
    );
    try session.applyOutcome(
        try ai.command.Outcome.reportNotice(gpa, .failure, "Temporary notice.", .{}),
    );
    session.clearNotice();

    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        "Drinky changed the model.",
        session.transcript.blocks()[0].content.event.text.items,
    );
    session.dirty = false;
    session.clearConversation();
    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expect(session.notice == null);
    try std.testing.expect(session.dirty);
    try std.testing.expect(session.view.force_reset);
}

test "scripted stream events drive the model and one coalesced paint" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var session: Session = Session.init(gpa, &out.writer, test_model, replaying_effort);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .thinking = try gpa.dupe(u8, "reasoning") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "he") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "llo") });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"x\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .summary = .{ .text = try gpa.dupe(u8, "Lines: 2") },
        .is_error = false,
    } });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.tools.items.len);
    try applyEvent(&session, 1, .{ .usage = .{
        .cost = 1.5,
        .cache_usage = .{ .input = 10, .output = 20 },
    } });

    try std.testing.expect(session.dirty);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectEqual(@as(f64, 1.5), session.stats_shown.cost);

    try finishTurn(&session);
    try std.testing.expect(!session.animating());

    try session.paint(.{ .columns = 80, .rows = 24 });
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "reasoning") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Lines: 2") != null);
}

test "a tool result box shows the line the tool decided" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"x\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .summary = .{ .text = try gpa.dupe(u8, "Lines: 3") },
        .is_error = false,
    } });
    try finishTurn(&session);
    try session.paint(.{ .columns = 80, .rows = 24 });

    const painted = out.written();
    try std.testing.expectEqualStrings(
        "Tool: read · File: x\nLines: 3",
        session.transcript.blocks()[0].content.tool_result.text.items,
    );
    try std.testing.expect(std.mem.indexOf(u8, painted, "Lines: 3") != null);
}

test "a tool result without a box line keeps the call row alone" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "describe_drinky"),
        .input_json = try gpa.dupe(u8, "{}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "describe_drinky"),
        .is_error = false,
    } });
    try finishTurn(&session);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings(
        "Tool: describe_drinky",
        blocks[0].content.tool_result.text.items,
    );
    try std.testing.expectEqual(@as(usize, 3), blocks[0].rows(80));

    try session.paint(.{ .columns = 80, .rows = 24 });
    const painted = out.written();
    try expectPainted(gpa, painted, "Tool: describe_drinky");
}

test "a failed tool result keeps its sentence below the call row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const sentence = "Drinky could not read a.zig because of error FileNotFound.";
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a.zig\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .summary = .{ .text = try gpa.dupe(u8, sentence), .kind = .sentence },
        .is_error = true,
    } });
    try finishTurn(&session);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.tool_result.is_error);
    try std.testing.expectEqualStrings(
        "Tool: read · File: a.zig\nError: " ++ sentence,
        blocks[0].content.tool_result.text.items,
    );
    try std.testing.expectEqual(ui.paint.Fit.wrap, blocks[0].content.tool_result.fit);
}

test "a failed tool result that states measures takes no prefix" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"ls missing\"}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "bash"),
        .summary = .{
            .text = try gpa.dupe(u8, "Time: 400ms · Exit code: 1 · Lines: 1"),
            .kind = .measures,
        },
        .is_error = true,
    } });
    try finishTurn(&session);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].content.tool_result.is_error);
    try std.testing.expectEqualStrings(
        "Tool: bash · Command: ls missing\nTime: 400ms · Exit code: 1 · Lines: 1",
        blocks[0].content.tool_result.text.items,
    );
    try std.testing.expectEqual(ui.paint.Fit.head, blocks[0].content.tool_result.fit);
}

test "a streamed tool call counts its bytes until the call commits" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"src/") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "App.zig\",\"content\"") });
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqual(@as(usize, 31), session.mode.turn.streamed_tools.items[0].bytes);

    const size: terminal.View.Size = .{ .columns = 60, .rows = 24 };
    try session.paint(size);
    const streaming = out.written();
    try expectPainted(gpa, streaming, "Tool: write · Received: 31 B · Status: Streaming");
    try std.testing.expect(std.mem.indexOf(u8, streaming, "Size:") == null);
    try std.testing.expect(std.mem.indexOf(u8, streaming, "path") == null);
    try std.testing.expect(std.mem.indexOf(u8, streaming, "\u{2026}") == null);

    out.clearRetainingCapacity();
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "write"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"src/App.zig\",\"content\":\"x\"}"),
    } });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.tools.items.len);
    session.view.resetScreen();
    try session.paint(size);
    const committed = out.written();
    try expectPainted(gpa, committed, "Tool: write · File: src/App.zig");
    try std.testing.expect(std.mem.indexOf(u8, committed, "content") == null);
}

test "a committed call replaces its own streamed row and leaves its sibling" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"a\"}") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"b\"}") });
    try std.testing.expectEqual(@as(usize, 2), session.mode.turn.streamed_tools.items.len);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "write"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a\"}"),
    } });
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqualStrings("read", session.mode.turn.streamed_tools.items[0].name);

    try session.paint(.{ .columns = 60, .rows = 24 });
    const painted = out.written();
    try expectPainted(gpa, painted, "Tool: write · File: a");
    try expectPainted(gpa, painted, "Tool: read · Received: 12 B · Status: Queued");
}

test "a streamed row that stopped counting reads as queued" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"a\"}") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"bb\"}") });

    const rows = session.mode.turn.streamed_tools.items;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings(
        "Tool: write · Received: 12 B · Status: Queued",
        rows[0].box.items,
    );
    try std.testing.expectEqualStrings(
        "Tool: read · Received: 13 B · Status: Streaming",
        rows[1].box.items,
    );

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "and") });
    try std.testing.expectEqual(@as(usize, 2), session.mode.turn.streamed_tools.items.len);
}

test "a narrow window cuts the phase of a streamed row and keeps the count" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"a\"}") });

    try session.paint(.{ .columns = 40, .rows = 24 });
    const painted = out.written();
    try expectPainted(gpa, painted, "Tool: write · Received: 12 B");
    try std.testing.expect(std.mem.indexOf(u8, painted, "Streaming") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\u{2026}") != null);
}

test "a streamed row stays one short line however long the arguments run" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "write") });
    const chunk = "ä" ** 1024;
    for (0..8) |_|
        try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, chunk) });

    const streamed = &session.mode.turn.streamed_tools.items[0];
    try std.testing.expectEqual(@as(usize, 8 * 2048), streamed.bytes);
    try std.testing.expectEqualStrings(
        "Tool: write · Received: 16.0 KB · Status: Streaming",
        streamed.box.items,
    );
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, streamed.box.items, "\n"));
}

test "a stream reset drops the tool boxes of the discarded attempt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "partial") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\"") });
    try applyEvent(&session, 1, .{ .stream_reset = .{
        .attempt = 2,
        .cause = .{ .failure = error.Timeout },
    } });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
    {
        const blocks = session.transcript.blocks();
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        try std.testing.expectEqualStrings(
            "Drinky started retry attempt 2 because of error Timeout.",
            blocks[0].content.event.text.items,
        );
    }

    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "orphan") });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
    try session.paint(.{ .columns = 40, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "orphan") == null);
}

test "response-head retries remain after an abnormal rewind" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try session.transcript.append(.user, .{}, "try this");
    session.beginTurn(1);
    session.markTurnBase(0);
    try applyEvent(&session, 1, .{ .stream_reset = .{
        .attempt = 2,
        .cause = .{ .response = try gpa.dupe(u8, "Overloaded") },
    } });
    try applyEvent(&session, 1, .{ .stream_reset = .{
        .attempt = 3,
        .cause = .{ .failure = error.Timeout },
    } });
    try session.failTurnWithReceipt(
        &.{
            .history_base = 0,
            .history_end = 0,
        },
        "The request failed.",
    );

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky started retry attempt 2 because the provider reported \"Overloaded\".",
        blocks[0].content.event.text.items,
    );
    try std.testing.expectEqualStrings(
        "Drinky started retry attempt 3 because of error Timeout.",
        blocks[1].content.event.text.items,
    );
    try std.testing.expect(blocks[2].content.event.is_error);
    try std.testing.expectEqualStrings("The request failed.", blocks[2].content.event.text.items);
}

test "a model mismatch records a durable event beside the answer" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "answer") });
    try applyEvent(&session, 1, .{ .model_mismatch = .{
        .requested = try gpa.dupe(u8, "claude-fable-5"),
        .served = try gpa.dupe(u8, "claude-opus-5"),
    } });

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("answer", blocks[0].content.model.items);
    try std.testing.expect(blocks[1].content.event.is_warning);
    try std.testing.expect(!blocks[1].content.event.is_error);
    try std.testing.expectEqualStrings(
        "The provider answered with the model \"claude-opus-5\" instead of the " ++
            "requested model \"claude-fable-5\".",
        blocks[1].content.event.text.items,
    );
}

test "a truncated receipt appends an event after the answer" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "half an ans") });
    try session.endTurnWithReceipt(&.{
        .history_base = 0,
        .history_end = 2,
        .truncated = true,
    });

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("half an ans", blocks[0].content.model.items);
    try std.testing.expect(blocks[1].content.event.is_error);
    try std.testing.expectEqualStrings(truncated_event, blocks[1].content.event.text.items);

    session.beginTurn(2);
    const receipt: ai.Agent.Receipt = .{
        .history_base = 2,
        .history_end = 2,
        .truncated = true,
    };
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "boom");
    const after = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), after.len);
    try std.testing.expect(after[2].content.event.is_error);
    try std.testing.expectEqualStrings(truncated_event, after[2].content.event.text.items);
    try std.testing.expect(after[3].content.event.is_error);
    try std.testing.expectEqualStrings("boom", after[3].content.event.text.items);
}

test "streamed and tool text cannot emit terminal controls" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const streamed = "reply\x1b[8A\x1b]52;c;bW9kZWw=\x07\x1b_payload\x1b\\done";
    const tool = "tool\x1b]52;c;dG9vbA==\x1b\\\x1bPpayload\x1b\\\xc2\x9b2Jdone";
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, streamed) });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{}"),
    } });
    try applyEvent(&session, 1, .{ .tool_result = .{
        .name = try gpa.dupe(u8, "read"),
        .summary = .{ .text = try gpa.dupe(u8, tool) },
        .is_error = false,
    } });
    try finishTurn(&session);
    try session.paint(.{ .columns = 160, .rows = 24 });

    const painted = out.written();
    for ([_][]const u8{
        "reply",  "[8A", "]52;c;bW9kZWw=", "_payload", "tool", "]52;c;dG9vbA==", "Ppayload",
        "2Jdone",
        "\u{200B}�\u{200B}",
    }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, painted, text) != null);
    }
    for ([_][]const u8{
        "\x1b[8A",
        "\x1b]52;c;bW9kZWw=\x07",
        "\x1b_payload\x1b\\",
        "\x1b]52;c;dG9vbA==\x1b\\",
        "\x1bPpayload\x1b\\",
        "\xc2\x9b2J",
    }) |control| {
        try std.testing.expect(std.mem.indexOf(u8, painted, control) == null);
    }
}

test "stream events are dropped once the turn is over" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "straggler") });
    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expect(!session.dirty);
}

test "a canceled turn's stale output and completion cannot affect its successor" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.beginTurn(1);
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "turn A") });
    try session.abortTurn();
    session.beginTurn(2);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "stale A") });
    try std.testing.expect(!try session.applyTurnEvent(&.{
        .generation = 1,
        .payload = .turn_ended,
    }));
    try std.testing.expect(session.animating());

    try applyEvent(&session, 2, .{ .text = try gpa.dupe(u8, "turn B") });
    try std.testing.expect(try session.applyTurnEvent(&.{
        .generation = 2,
        .payload = .turn_ended,
    }));
    try finishTurn(&session);
    try std.testing.expect(!session.animating());
    try std.testing.expectEqual(@as(usize, 3), session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        "turn B",
        session.transcript.blocks()[2].content.model.items,
    );
}

test "markTurnBase moves the checkpoint to the base and a commit moves it forward" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    try session.transcript.append(.event, .{}, "before the turn");
    session.beginTurn(1);
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.transcript_checkpoint);
    session.markTurnBase(0);
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.transcript_checkpoint);

    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .progress_sequence_committed = 0,
        .payload = .{ .text = try gpa.dupe(u8, "answer") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "bash"),
            .input_json = try gpa.dupe(u8, "{\"command\":\"ls\"}"),
        } },
    });
    try std.testing.expect(session.mode.turn.transcript_checkpoint > 0);
    session.endTurn();
}

test "the caption of an input state paints above the editor during a turn" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.input = .{ .owner = .external, .caption = .{
        .title = "Remote: @drinky_bot",
        .controls = "Esc: Detach",
        .rows_max = editor_caption_rows_max,
    } };
    session.beginTurn(1);

    try session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Remote: @drinky_bot") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Esc: Detach") != null);
}

test "an external prompt returns after its source let go of the input" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    const receipt: ai.Agent.Receipt = .{
        .history_base = 0,
        .history_end = 0,
    };

    session.input = .{ .owner = .external, .caption = .{
        .title = "Remote: @drinky_bot",
        .controls = "Esc: Detach",
        .rows_max = editor_caption_rows_max,
    } };
    session.beginTurn(1);
    var held = try ui.Editor.Draft.fromText(gpa, "from the chat");
    session.retainExternalTurnPrompt(&held, 0, 7);
    try std.testing.expectEqual(@as(i64, 7), session.turn_prompt.?.source.external);
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "the turn failed");
    try std.testing.expectEqualStrings("", session.editor.visible());
    try std.testing.expect(session.turn_prompt == null);

    session.input = .{ .owner = .none, .caption = .{
        .title = "Remote: @drinky_bot",
        .controls = "Esc: Cancel",
        .rows_max = editor_caption_rows_max,
    } };
    session.beginTurn(2);
    var returned = try ui.Editor.Draft.fromText(gpa, "after the detach");
    session.retainExternalTurnPrompt(&returned, 0, 8);
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "the turn failed");
    try std.testing.expectEqualStrings("after the detach", session.editor.visible());
}

test "a pick that reopens its own step leaves the trail depth unchanged" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    const account_step = struct {
        fn open(_: *ai.command.Context) anyerror!ai.command.Outcome {
            unreachable;
        }
    }.open;
    const model_step = struct {
        fn open(_: *ai.command.Context) anyerror!ai.command.Outcome {
            unreachable;
        }
    }.open;

    try session.applyOutcome(.{ .pick = try pickForTest(gpa, "Account", account_step) });
    try std.testing.expectEqual(@as(usize, 0), session.mode.picking.trail.len);

    try session.applyOutcome(.{ .pick = try pickForTest(gpa, "Model", model_step) });
    try std.testing.expectEqual(@as(usize, 1), session.mode.picking.trail.len);

    for (0..2) |_| {
        try session.applyOutcome(.{ .pick = try pickForTest(gpa, "Model", model_step) });
        try std.testing.expectEqual(@as(usize, 1), session.mode.picking.trail.len);
    }
    try std.testing.expect(session.mode.picking.trail.last().?.open == account_step);
}

fn freePickOptions(gpa: std.mem.Allocator, options: []const ai.command.Outcome.Pick.Option) void {
    for (options) |*option| option.deinit(gpa);
    gpa.free(options);
}

fn freePickerOptions(gpa: std.mem.Allocator, options: []const ui.Picker.Option) void {
    for (options) |*option| option.deinit(gpa);
    gpa.free(options);
}

fn takePickerOptions(
    gpa: std.mem.Allocator,
    source: []const ai.command.Outcome.Pick.Option,
) ![]ui.Picker.Option {
    const rows = try gpa.alloc(ui.Picker.Option, source.len);
    for (source, rows) |*item, *target| {
        target.* = .{
            .name = item.name,
            .extra = item.extra,
            .extra_pressure = item.extra_pressure,
            .tag = item.tag,
            .tag_pressure = item.tag_pressure,
        };
    }
    gpa.free(source);
    return rows;
}

fn pickForTest(
    gpa: std.mem.Allocator,
    title: []const u8,
    open: ai.command.Outcome.Opener,
) !ai.command.Outcome.Pick {
    const options = try gpa.alloc(ai.command.Outcome.Pick.Option, 1);
    errdefer gpa.free(options);
    options[0] = .{ .name = try gpa.dupe(u8, "row") };
    return .{
        .select = undefined,
        .title = title,
        .cancellation_message = "You canceled the selection.",
        .options = options,
        .current = null,
        .reopen = open,
    };
}

test "the picker trail bounds its depth and ends where a picker cannot return" {
    const first = struct {
        fn open(_: *ai.command.Context) anyerror!ai.command.Outcome {
            unreachable;
        }
    }.open;
    const rest = struct {
        fn open(_: *ai.command.Context) anyerror!ai.command.Outcome {
            unreachable;
        }
    }.open;

    var trail: Trail = .{};
    try std.testing.expect(trail.last() == null);
    trail.dropLast();

    trail.push(.{ .cursor = 3, .scroll = 1 }, first);
    for (1..trail.entries.len) |_| trail.push(.{}, rest);
    try std.testing.expectEqual(trail.entries.len, trail.len);
    try std.testing.expect(trail.entries[0].open == first);
    try std.testing.expectEqual(@as(usize, 3), trail.entries[0].position.cursor);
    try std.testing.expectEqual(@as(usize, 1), trail.entries[0].position.scroll);

    trail.push(.{ .cursor = 7 }, rest);
    try std.testing.expectEqual(trail.entries.len, trail.len);
    try std.testing.expect(trail.entries[0].open == rest);
    try std.testing.expect(trail.last().?.open == rest);
    try std.testing.expectEqual(@as(usize, 7), trail.last().?.position.cursor);

    trail.push(.{}, null);
    try std.testing.expectEqual(@as(usize, 0), trail.len);
    try std.testing.expect(trail.last() == null);
}

test "a picked line replaces the draft in the editor" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try session.editor.insert("stale text");
    try session.applyOutcome(.{ .editor_text = try gpa.dupe(u8, "/skill:demo ") });
    try std.testing.expectEqualStrings("/skill:demo ", session.editor.visible());
    try std.testing.expect(session.mode == .prompt);

    try session.paint(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "/skill:demo") != null);
}

test "opening a picker over a turn releases its retained prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    var prompt = try ui.Editor.Draft.fromText(gpa, "first");
    session.retainTurnPrompt(&prompt, 0);
    const options = try gpa.alloc(ai.command.Outcome.Pick.Option, 1);
    options[0] = .{ .name = try gpa.dupe(u8, "choice") };
    try session.applyOutcome(.{ .pick = .{
        .select = undefined,
        .title = "Select an option",
        .cancellation_message = "You canceled the option selection.",
        .options = options,
        .current = null,
    } });
    try std.testing.expect(session.mode == .picking);
    try std.testing.expect(session.turn_prompt == null);

    session.closePicker();
    session.beginTurn(2);
    var next_prompt = try ui.Editor.Draft.fromText(gpa, "second");
    session.retainTurnPrompt(&next_prompt, 0);
    session.endTurn();
    try std.testing.expect(session.turn_prompt == null);
}

test "activity ticks repaint each separator step" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.beginTurn(1);
    session.dirty = false;
    session.mode.turn.activity_tick = 38;
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(u64, 39), session.mode.turn.activity_tick);
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(u64, 40), session.mode.turn.activity_tick);
    session.mode.turn.activity_tick = std.math.maxInt(u64);
    try std.testing.expect(session.advanceFrame());
    try std.testing.expectEqual(@as(u64, 0), session.mode.turn.activity_tick);
    session.deinitMode();

    session.mode = .prompt;
    session.dirty = false;
    try std.testing.expect(!session.advanceFrame());

    session.dirty = true;
    try std.testing.expect(session.advanceFrame());
}

test "an edit restarts the caret blink of a running turn" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.beginTurn(1);
    _ = session.advanceFrame();
    _ = session.advanceFrame();
    try std.testing.expectEqual(@as(u64, 2), session.mode.turn.caret_tick);

    session.dirty = false;
    session.markEdited();
    try std.testing.expect(session.dirty);
    try std.testing.expectEqual(@as(u64, 0), session.mode.turn.caret_tick);

    session.deinitMode();
    session.mode = .prompt;
    session.dirty = false;
    session.markEdited();
    try std.testing.expect(session.dirty);
}

test "a running turn hides and shows the hardware cursor of the input" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.beginTurn(1);
    try session.editor.insert("hi");

    var hidden = false;
    var shown_again = false;
    for (0..160) |_| {
        const start = out.written().len;
        _ = session.advanceFrame();
        try session.paint(.{ .columns = 40, .rows = 24 });
        const frame = out.written()[start..];
        if (!hidden) {
            hidden = std.mem.indexOf(u8, frame, terminal.escape.cursor_hide) != null;
        } else if (!shown_again) {
            shown_again = std.mem.indexOf(u8, frame, terminal.escape.cursor_show) != null;
        }
    }
    try std.testing.expect(hidden);
    try std.testing.expect(shown_again);
}

test "accepted turn progress restarts separator growth without resetting motion" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.beginTurn(7);
    session.mode.turn.activity_tick = 125;
    session.mode.turn.progress_tick_last = 5;

    try applyEvent(&session, 6, .{ .usage = .{} });
    try std.testing.expectEqual(@as(u64, 5), session.mode.turn.progress_tick_last);

    try applyEvent(&session, 7, .{ .usage = .{} });
    const activity = session.mode.turn.activity();
    try std.testing.expectEqual(@as(u64, 125), activity.motion_tick);
    try std.testing.expectEqual(@as(u64, 0), activity.progress_age_ticks);
}

test "a failure with nothing committed rewinds the tail and returns the prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try session.transcript.append(.event, .{}, "earlier");
    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "my prompt");
    try session.transcript.appendStream(.model, null, "partial reply");
    var prompt = try ui.Editor.Draft.fromText(gpa, "my prompt");
    session.retainTurnPrompt(&prompt, base);
    try session.editor.insert("typing");

    const receipt: ai.Agent.Receipt = .{
        .history_base = 0,
        .history_end = 0,
    };
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "Overloaded");

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("earlier", blocks[0].content.event.text.items);
    try std.testing.expect(blocks[1].content.event.is_error);
    try std.testing.expectEqualStrings("Overloaded", blocks[1].content.event.text.items);
    try std.testing.expectEqualStrings("my prompt\n\ntyping", session.editor.visible());
    try std.testing.expect(session.turn_prompt == null);
}

test "a failure after a committed round keeps it and returns no prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "round one") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "read"),
            .input_json = try gpa.dupe(u8, "{}"),
        } },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .text = try gpa.dupe(u8, "round two partial") },
    });

    const receipt: ai.Agent.Receipt = .{ .history_base = 0, .history_end = 2 };
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "boom");

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].content.user.items);
    try std.testing.expectEqualStrings("round one", blocks[1].content.model.items);
    try std.testing.expect(blocks[2].content.tool_result.is_error);
    try std.testing.expectEqualStrings(
        "Tool: read\nError: " ++ ai.Agent.unfinished_tool_result,
        blocks[2].content.tool_result.text.items,
    );
    try std.testing.expect(blocks[3].content.event.is_error);
    try std.testing.expectEqualStrings("boom", blocks[3].content.event.text.items);
    try std.testing.expectEqualStrings("", session.editor.visible());
    try std.testing.expect(session.turn_prompt == null);
}

test "a cancel with nothing committed rewinds the tail and returns the prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try session.transcript.append(.event, .{}, "earlier");
    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "my prompt");
    try session.transcript.appendStream(.model, null, "partial reply");

    var prompt = try ui.Editor.Draft.fromText(gpa, "my prompt");
    session.retainTurnPrompt(&prompt, base);
    try session.editor.insert("typing");

    try session.reservePromptRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 0,
    }, 0);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("earlier", blocks[0].content.event.text.items);
    try std.testing.expectEqualStrings("my prompt\n\ntyping", session.editor.visible());
    try std.testing.expect(session.turn_prompt == null);
}

test "a cancel with a committed round keeps it and drops the in-flight tail" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);

    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "round one") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "read"),
            .input_json = try gpa.dupe(u8, "{}"),
        } },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 3,
        .progress_sequence_committed = 1,
        .payload = .{ .text = try gpa.dupe(u8, "round two partial") },
    });

    try session.reservePromptRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 2,
    }, 1);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].content.user.items);
    try std.testing.expectEqualStrings("round one", blocks[1].content.model.items);
    try std.testing.expectEqualStrings("", session.editor.visible());
    try std.testing.expect(session.turn_prompt == null);
}

test "a cancel during a tool call keeps the call and shows it as failed" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);

    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .thinking = try gpa.dupe(u8, "I run one command.") },
    });
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 2,
        .progress_sequence_committed = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "bash"),
            .input_json = try gpa.dupe(u8, "{\"command\":\"sleep 600\"}"),
        } },
    });

    try session.reservePromptRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 3,
    }, 1);
    try session.abortTurn();

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("prompt", blocks[0].content.user.items);
    try std.testing.expectEqualStrings("I run one command.", blocks[1].content.thinking.text.items);
    try std.testing.expect(blocks[2].content.tool_result.is_error);
    try std.testing.expectEqualStrings(
        "Tool: bash · Command: sleep 600\nError: " ++ ai.Agent.unfinished_tool_result,
        blocks[2].content.tool_result.text.items,
    );
    try std.testing.expect(!blocks[3].content.event.is_error);
    try std.testing.expectEqualStrings(
        "You canceled the turn.",
        blocks[3].content.event.text.items,
    );
    try std.testing.expect(session.mode == .prompt);
}

test "running tool calls fail oldest first" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const names = [_][]const u8{ "read", "grep", "read" };
    const subjects = [_][]const u8{ "path", "pattern", "path" };
    const labels = [_][]const u8{ "File", "Pattern", "File" };
    for (names, subjects, 0..) |name, key, index| {
        _ = try session.applyTurnEvent(&.{
            .generation = 1,
            .progress_sequence = index + 1,
            .payload = .{ .tool_start = .{
                .name = try gpa.dupe(u8, name),
                .input_json = try std.fmt.allocPrint(
                    gpa,
                    "{{\"{s}\":\"item{d}\"}}",
                    .{ key, index },
                ),
            } },
        });
    }
    try session.abortTurn();

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(names.len + 1, blocks.len);
    for (names, labels, 0..) |name, label, index| {
        const head = try std.fmt.allocPrint(gpa, "Tool: {s} · {s}: item{d}\n", .{
            name,
            label,
            index,
        });
        defer gpa.free(head);
        try std.testing.expect(std.mem.startsWith(
            u8,
            blocks[index].content.tool_result.text.items,
            head,
        ));
    }
}

test "a finished tool block survives a cancel in the same round" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    try applyFinishedToolRound(&session);

    try session.reservePromptRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 3,
    }, 3);
    try session.abortTurn();

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expect(!blocks[2].content.tool_result.is_error);
    try std.testing.expect(
        std.mem.endsWith(
            u8,
            blocks[2].content.tool_result.text.items,
            "\nTime: 0ms · Exit code: 0",
        ),
    );
    try std.testing.expectEqualStrings(
        "You canceled the turn.",
        blocks[3].content.event.text.items,
    );
}

test "a finished tool block survives a failure in the same round" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    try applyFinishedToolRound(&session);
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 4,
        .progress_sequence_committed = 3,
        .payload = .turn_ended,
    });

    const receipt: ai.Agent.Receipt = .{
        .history_base = 0,
        .history_end = 3,
    };
    try session.reserveFailureRestore(&receipt);
    try session.failTurnWithReceipt(&receipt, "boom");

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expect(!blocks[2].content.tool_result.is_error);
    try std.testing.expect(
        std.mem.endsWith(
            u8,
            blocks[2].content.tool_result.text.items,
            "\nTime: 0ms · Exit code: 0",
        ),
    );
    try std.testing.expectEqualStrings("boom", blocks[3].content.event.text.items);
}

test "a final commit frontier keeps an open reply when no later event carries it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const base = session.transcript.blocks().len;
    try session.transcript.append(.user, .{}, "prompt");
    var prompt = try ui.Editor.Draft.fromText(gpa, "prompt");
    session.retainTurnPrompt(&prompt, base);
    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .text = try gpa.dupe(u8, "committed answer") },
    });

    try session.reservePromptRestore();
    session.cancelReceipt(&.{
        .history_base = 0,
        .history_end = 2,
    }, 1);

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("committed answer", blocks[1].content.model.items);
}

test "a delivered skill shows as a head line, not as a user box" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.display_roots = .{ .working_directory = "/work", .home_directory = "/home/you" };
    session.beginTurn(1);

    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .skill_loaded = .{
            .skill = try gpa.dupe(u8, "zig-style"),
            .source = try gpa.dupe(u8, "/work/.agents/skills/zig-style/SKILL.md"),
        } },
    });

    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    switch (blocks[0].content) {
        .user_note => |head| try std.testing.expectEqualStrings(
            "Skill: zig-style · File: .agents/skills/zig-style/SKILL.md",
            head.items,
        ),
        else => return error.ExpectedSkill,
    }
}

test "a normal completion frees the retained prompt" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    const payload = "line\n" ** 15;
    try session.editor.paste(payload, true);
    var prompt = session.editor.detachTrimmed();
    session.retainTurnPrompt(&prompt, 0);

    try finishTurn(&session);
    try std.testing.expect(session.turn_prompt == null);
}

test "a running command reports its run time against its timeout" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.bash_timeout_ms = 120_000;
    session.beginTurn(1);

    session.clock_ms = 1_000;
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"zig build test\"}"),
    } });

    session.clock_ms = 13_400;
    try session.paint(.{ .columns = 60, .rows = 24 });
    const painted = out.written();
    try expectPainted(gpa, painted, "Tool: bash · Command: zig build test");
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Time: 12s · Timeout: 2m 0s") != null,
    );
}

test "a running search reports its run time against its timeout" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.bash_timeout_ms = 120_000;
    session.beginTurn(1);

    session.clock_ms = 2_000;
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "grep"),
        .input_json = try gpa.dupe(u8, "{\"pattern\":\"columns\"}"),
    } });

    session.clock_ms = 6_500;
    try session.paint(.{ .columns = 60, .rows = 24 });
    const painted = out.written();
    try expectPainted(gpa, painted, "Tool: grep · Pattern: columns");
    try std.testing.expect(
        std.mem.indexOf(u8, painted, "Time: 4s · Timeout: 10s") != null,
    );
}

test "a command that names its own timeout reports it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.bash_timeout_ms = 120_000;
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"sleep 5\",\"timeout_seconds\":5}"),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Timeout: 5s") != null);
}

test "a fractional configured timeout rounds up to the whole second" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.bash_timeout_ms = 1_500;
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"sleep 2\"}"),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Timeout: 2s") != null);
}

test "a tool without a timeout keeps one row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"src/App.zig\"}"),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    const painted = out.written();
    try expectPainted(gpa, painted, "Tool: read · File: src/App.zig");
    try std.testing.expect(std.mem.indexOf(u8, painted, "Timeout:") == null);
}

test "an absurd timeout still paints its row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(
            u8,
            "{\"command\":\"x\",\"timeout_seconds\":9223372036854775807}",
        ),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Timeout: 60m 0s") != null);
}

test "an absurd configured timeout still paints its row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.bash_timeout_ms = std.math.maxInt(u64);
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"x\"}"),
    } });
    try session.paint(.{ .columns = 60, .rows = 24 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Timeout: 60m 0s") != null);
}

test "a command that asks for no limit reports the smallest one" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    session.clock_ms = 0;
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "bash"),
        .input_json = try gpa.dupe(u8, "{\"command\":\"tail -f log\",\"timeout_seconds\":0}"),
    } });
    session.clock_ms = 500;
    try session.paint(.{ .columns = 60, .rows = 24 });
    try std.testing.expect(
        std.mem.indexOf(u8, out.written(), "Time: 0s · Timeout: 1s") != null,
    );
}

test "a live tool row above the viewport holds its text for a whole second" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.bash_timeout_ms = 120_000;
    session.beginTurn(1);

    session.clock_ms = 0;
    for (0..8) |index| {
        var buffer: [40]u8 = undefined;
        const input_json = std.fmt.bufPrint(
            &buffer,
            "{{\"command\":\"sleep {d}\"}}",
            .{index},
        ) catch unreachable;
        try applyEvent(&session, 1, .{ .tool_start = .{
            .name = try gpa.dupe(u8, "bash"),
            .input_json = try gpa.dupe(u8, input_json),
        } });
    }

    const size: terminal.View.Size = .{ .columns = 40, .rows = 8 };
    session.clock_ms = 1_000;
    try session.paint(size);

    var painted = out.written().len;
    session.clock_ms = 1_900;
    try session.paint(size);
    try std.testing.expect(
        std.mem.indexOf(u8, out.written()[painted..], terminal.escape.screen_reset) == null,
    );

    painted = out.written().len;
    session.clock_ms = 2_000;
    try session.paint(size);
    try std.testing.expect(
        std.mem.indexOf(u8, out.written()[painted..], terminal.escape.screen_reset) != null,
    );
}

test "an unnamed fragment does not count against a stale row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "phantom") });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a\"}"),
    } });
    const stale = &session.mode.turn.streamed_tools.items[0];
    try std.testing.expectEqual(StreamedTool.Phase.stale, stale.phase);

    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"path\":\"b\"}") });
    try std.testing.expectEqual(@as(usize, 0), stale.bytes);
    try std.testing.expectEqualStrings(
        "Tool: phantom · Received: 0 B · Status: Queued",
        stale.box.items,
    );
}

test "a stale row that its reply never committed goes with that reply" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "read") });
    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "phantom") });
    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a\"}"),
    } });
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqual(
        StreamedTool.Phase.stale,
        session.mode.turn.streamed_tools.items[0].phase,
    );

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "next") });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
}

test "a committed call with no streamed row leaves its sibling's row alone" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .tool_name = try gpa.dupe(u8, "grep") });
    try applyEvent(&session, 1, .{ .tool_arguments = try gpa.dupe(u8, "{\"pattern\":\"x\"}") });
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "read"),
        .input_json = try gpa.dupe(u8, "{\"path\":\"a\"}"),
    } });
    try std.testing.expectEqual(@as(usize, 1), session.mode.turn.streamed_tools.items.len);
    try std.testing.expectEqualStrings("grep", session.mode.turn.streamed_tools.items[0].name);

    try applyEvent(&session, 1, .{ .tool_start = .{
        .name = try gpa.dupe(u8, "grep"),
        .input_json = try gpa.dupe(u8, "{\"pattern\":\"x\"}"),
    } });
    try std.testing.expectEqual(@as(usize, 0), session.mode.turn.streamed_tools.items.len);
}

test "an account switch hides the reasoning of the other account" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, replaying_effort);
    defer session.deinit();
    session.showSetup(.anthropic_plan, test_model, replaying_effort);
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .thinking = try gpa.dupe(u8, "weigh it") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "the answer") });
    try finishTurn(&session);
    try session.paint(.{ .columns = 80, .rows = 24 });
    try expectPainted(gpa, out.written(), "weigh it");

    const switched_start = out.written().len;
    session.showSetup(.openai_api_key, test_model_openai, replaying_effort);
    try std.testing.expect(session.view.force_reset);
    try session.paint(.{ .columns = 80, .rows = 24 });
    const switched = out.written()[switched_start..];
    try std.testing.expect(std.mem.indexOf(u8, switched, terminal.escape.screen_reset) != null);
    const shown = try terminal.View.plainText(gpa, switched);
    defer gpa.free(shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "weigh it") == null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "the answer") != null);
    try std.testing.expectEqual(@as(usize, 2), session.transcript.blocks().len);

    const restored_start = out.written().len;
    session.showSetup(.anthropic_plan, test_model, replaying_effort);
    try session.paint(.{ .columns = 80, .rows = 24 });
    try expectPainted(gpa, out.written()[restored_start..], "weigh it");
}

test "a model that replays no reasoning hides it" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, replaying_effort);
    defer session.deinit();
    session.showSetup(.anthropic_plan, test_model, replaying_effort);
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .thinking = try gpa.dupe(u8, "weigh it") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "the answer") });
    try finishTurn(&session);
    try session.paint(.{ .columns = 80, .rows = 24 });
    try expectPainted(gpa, out.written(), "weigh it");

    const silent_start = out.written().len;
    session.showSetup(.anthropic_plan, test_model_closed, replaying_effort);
    try std.testing.expect(session.view.force_reset);
    try session.paint(.{ .columns = 80, .rows = 24 });
    const silent = try terminal.View.plainText(gpa, out.written()[silent_start..]);
    defer gpa.free(silent);
    try std.testing.expect(std.mem.indexOf(u8, silent, "weigh it") == null);
    try std.testing.expect(std.mem.indexOf(u8, silent, "the answer") != null);
    const reasoning = &session.transcript.blocks()[0];
    try std.testing.expectEqual(@as(usize, 0), reasoning.cache.lines.count());

    const restored_start = out.written().len;
    session.showSetup(.anthropic_plan, test_model, .low);
    try std.testing.expect(session.view.force_reset);
    try session.paint(.{ .columns = 80, .rows = 24 });
    try expectPainted(gpa, out.written()[restored_start..], "weigh it");
    try std.testing.expect(reasoning.cache.lines.count() > 0);
}

test "a setup change that hides no block keeps the scrollback" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, replaying_effort);
    defer session.deinit();
    session.showSetup(.anthropic_plan, test_model, replaying_effort);
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "the answer") });
    try finishTurn(&session);
    try session.paint(.{ .columns = 80, .rows = 24 });

    session.showSetup(.openai_api_key, test_model_openai, .low);
    try std.testing.expect(!session.view.force_reset);
    try std.testing.expect(session.dirty);

    session.beginTurn(2);
    try applyEvent(&session, 2, .{ .thinking = try gpa.dupe(u8, "weigh it") });
    try finishTurn(&session);
    try session.paint(.{ .columns = 80, .rows = 24 });
    const other_openai = ai.testing.model("gpt-5.6-luna");
    session.showSetup(.openai_api_key, other_openai, .low);
    try std.testing.expect(!session.view.force_reset);
    const projected = try session.transcript.projection(session.projectionSetup());
    try std.testing.expectEqual(@as(usize, 2), projected.len);
    try std.testing.expectEqualStrings("weigh it", projected[1].content.thinking.text.items);
}

test "dropped account reasoning leaves the transcript for good" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, replaying_effort);
    defer session.deinit();
    session.showSetup(.anthropic_plan, test_model, replaying_effort);
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .thinking = try gpa.dupe(u8, "weigh it") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "the answer") });
    try finishTurn(&session);
    try session.paint(.{ .columns = 80, .rows = 24 });

    session.dropAccountReasoning(.anthropic_plan);
    try std.testing.expect(session.view.force_reset);
    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);

    const dropped_start = out.written().len;
    try session.paint(.{ .columns = 80, .rows = 24 });
    const dropped = try terminal.View.plainText(gpa, out.written()[dropped_start..]);
    defer gpa.free(dropped);
    try std.testing.expect(std.mem.indexOf(u8, dropped, "weigh it") == null);
    try std.testing.expect(std.mem.indexOf(u8, dropped, "the answer") != null);

    session.view.force_reset = false;
    session.dropAccountReasoning(.anthropic_plan);
    try std.testing.expect(!session.view.force_reset);
    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);
}

test "a conversation clear drops every block and keeps the request setup" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session: Session = Session.init(gpa, &out.writer, test_model, replaying_effort);
    defer session.deinit();
    session.showSetup(.anthropic_plan, test_model, replaying_effort);
    session.beginTurn(1);

    try applyEvent(&session, 1, .{ .thinking = try gpa.dupe(u8, "weigh it") });
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "the answer") });
    try finishTurn(&session);
    session.stats_shown.cost = 1.5;
    try session.paint(.{ .columns = 80, .rows = 24 });

    session.view.force_reset = false;
    session.clearConversation();
    try std.testing.expectEqual(@as(usize, 0), session.transcript.blocks().len);
    try std.testing.expect(session.view.force_reset);
    try std.testing.expectEqual(@as(f64, 0), session.stats_shown.cost);
    try std.testing.expectEqual(@as(?ai.llm.Account, .anthropic_plan), session.account_shown);
    try std.testing.expectEqualStrings(test_model.name(), session.model_shown.?.name());
    try std.testing.expectEqual(replaying_effort, session.effort_shown);

    const cleared_start = out.written().len;
    try session.paint(.{ .columns = 80, .rows = 24 });
    const cleared = try terminal.View.plainText(gpa, out.written()[cleared_start..]);
    defer gpa.free(cleared);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "weigh it") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "the answer") == null);
}

test "an async event that repeats states its count in the block it repeats" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    const text = "Drinky could not poll @drinky_bot.";
    for (0..3) |_| try session.recordAsyncEvent(
        try ai.command.Outcome.Message.print(gpa, .failure, text, .{}),
        .{ .mirrored = false },
    );
    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);
    try std.testing.expectEqualStrings(
        "Drinky could not poll @drinky_bot. · Repeats: 3",
        session.transcript.blocks()[0].content.event.text.items,
    );

    for (0..2) |_| try session.recordAsyncEvent(
        try ai.command.Outcome.Message.print(gpa, .failure, text, .{}),
        .{},
    );
    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings(
        "Drinky could not poll @drinky_bot. · Repeats: 3",
        blocks[0].content.event.text.items,
    );
    try std.testing.expectEqualStrings(text, blocks[1].content.event.text.items);
    try std.testing.expectEqualStrings(text, blocks[2].content.event.text.items);
}

test "an async event waits for the message boundary and survives a rewind" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    try session.recordAsyncEvent(try ai.command.Outcome.Message.print(
        gpa,
        .information,
        "idle report",
        .{},
    ), .{});
    try std.testing.expectEqual(@as(usize, 1), session.transcript.blocks().len);

    session.beginTurn(1);
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "partial ") });
    try session.recordAsyncEvent(try ai.command.Outcome.Message.print(
        gpa,
        .failure,
        "mid-stream report",
        .{},
    ), .{ .mirrored = false });
    try std.testing.expectEqual(@as(usize, 2), session.transcript.blocks().len);
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "answer") });
    try std.testing.expectEqualStrings(
        "partial answer",
        session.transcript.blocks()[1].content.model.items,
    );

    _ = try session.applyTurnEvent(&.{
        .generation = 1,
        .progress_sequence = 1,
        .payload = .{ .tool_start = .{
            .name = try gpa.dupe(u8, "bash"),
            .input_json = try gpa.dupe(u8, "{\"command\":\"true\"}"),
        } },
    });
    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("mid-stream report", blocks[2].content.event.text.items);
    try std.testing.expect(blocks[2].content.event.is_error);
    try std.testing.expect(blocks[2].content.event.survives_rewind);
    try std.testing.expect(!blocks[2].content.event.mirrored);
    try std.testing.expect(blocks[0].content.event.mirrored);

    try session.reserveFailureRestore(&.{
        .history_base = 0,
        .history_end = 0,
    });
    try session.failTurnWithReceipt(&.{
        .history_base = 0,
        .history_end = 0,
    }, "the turn failed");
    const rewound = session.transcript.blocks();
    try std.testing.expectEqualStrings("idle report", rewound[0].content.event.text.items);
    try std.testing.expectEqualStrings("mid-stream report", rewound[1].content.event.text.items);
}

test "the end of a turn lands the deferred events" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var session = Session.init(gpa, &out.writer, test_model, .low);
    defer session.deinit();

    session.beginTurn(1);
    try applyEvent(&session, 1, .{ .text = try gpa.dupe(u8, "answer") });
    try session.recordAsyncEvent(
        try ai.command.Outcome.Message.print(gpa, .information, "late", .{}),
        .{},
    );
    try finishTurn(&session);
    const blocks = session.transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("answer", blocks[0].content.model.items);
    try std.testing.expectEqualStrings("late", blocks[1].content.event.text.items);
}
