const std = @import("std");
const application = @import("application");
const format = @import("format.zig");

const accounts = @import("accounts");
const core = @import("core");
const terminal = @import("terminal");

const Flow = @import("Flow.zig");
const layout = @import("layout.zig");
const testing = @import("testing.zig");
const tool_line = @import("tool_line.zig");
const Transcript = @import("Transcript.zig");
const ui = @import("ui/root.zig");
const wording = @import("wording.zig");

const Screen = @This();

pub const editor_caption_rows_max: usize = 3;
const picker_scrolls_max = 8;
const retry_note = "Drinky asked the model to continue from the committed work.";

gpa: std.mem.Allocator,
transcript: Transcript,
notice: ?ui.Message,
editor: ui.Editor,
view: terminal.View,
page_view: terminal.View,
widget: Widget,
columns: usize,
rows: usize,
statistics: application.Statistics,
choice: application.Choice,
directory_shown: []const u8,
mcp_access: bool = false,
branch_buffer: [application.branch_bytes_max]u8,
branch_length: ?usize,
window_pages: usize,
gauge: application.Settings.Gauge,
display_roots: format.Roots,
intro: []const u8 = "",
startup_failure: ?[]const u8 = null,
verbose: bool = true,
repaint_transcript: bool = false,
page_wait: ?PageWait = null,
result_page: ?ResultPage = null,
confirmation: ?ui.status.Confirmation = null,
notice_id: u64 = 0,
picker_depth: usize = 0,
picker_scrolls: [picker_scrolls_max]usize = undefined,

pub const Time = struct {
    awake_ms: i64,
    boot_ms: i64,
};

const PageWait = struct {
    started_ms: i64,
    received_bytes: usize = 0,
    thinking: bool = false,
    seconds_shown: ?i64 = null,

    fn seconds(self: *const PageWait, now_ms: i64) i64 {
        return @divFloor(@max(now_ms - self.started_ms, 0), std.time.ms_per_s);
    }
};

pub const ResultPage = struct {
    id: u64,
    phase: std.meta.Tag(application.State.Result.Phase),
};

pub const PickerOptions = struct {
    title: []const u8,
    options: []const ui.Picker.Option,
    current: ?usize = null,
    preselected: ?usize = null,
    cursor: ?usize = null,
    depth: usize = 0,
};

pub const Change = union(enum) {
    append_record: *const application.Record,
    record_text: application.Event.RecordText,
    replace_record: *const application.Record,
    remove_records: []const u64,
    live: *const application.Live,
    statistics: application.Statistics,
    clear_conversation,
};

pub const Widget = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
    page: ui.Page,
};

pub const Turn = struct {
    calls: std.ArrayList(Call),
    thinking: bool,
    activity_tick: u64,
    progress_tick_last: u64,
    caret_tick: u64,
    box_view: std.ArrayList(ui.paint.Box),
    box_hashes: std.ArrayList(u64),
    box_tracks: std.ArrayList(layout.Track),
    work_line: std.ArrayList(u8),
    work_ends: [ui.Block.Work.Summary.segment_count]usize,

    const empty: Turn = .{
        .calls = .empty,
        .thinking = false,
        .activity_tick = 0,
        .progress_tick_last = 0,
        .caret_tick = 0,
        .box_view = .empty,
        .box_hashes = .empty,
        .box_tracks = .empty,
        .work_line = .empty,
        .work_ends = undefined,
    };

    fn deinit(self: *Turn, gpa: std.mem.Allocator) void {
        self.releaseCalls(gpa);
        self.calls.deinit(gpa);
        self.box_view.deinit(gpa);
        self.box_hashes.deinit(gpa);
        self.box_tracks.deinit(gpa);
        self.work_line.deinit(gpa);
    }

    fn releaseCalls(self: *Turn, gpa: std.mem.Allocator) void {
        for (self.calls.items) |*call| call.deinit(gpa);
        self.calls.clearRetainingCapacity();
    }

    fn activity(self: *const Turn) ui.paint.Activity {
        return .{
            .motion_tick = self.activity_tick,
            .progress_age_ticks = self.activity_tick -% self.progress_tick_last,
            .caret_tick = self.caret_tick,
        };
    }

    fn boxes(self: *Turn, gpa: std.mem.Allocator, now_ms: i64) ![]const ui.paint.Box {
        self.box_view.clearRetainingCapacity();
        for (self.calls.items) |*call| {
            try self.box_view.append(gpa, .{
                .text = try call.text(gpa, now_ms),
                .segment_ends = call.line.?.segment_ends,
                .status = call.line.?.status,
                .qualifiers = call.line.?.qualifiers,
                .command = call.line.?.command,
            });
        }
        return self.box_view.items;
    }

    fn workBoxes(
        self: *Turn,
        gpa: std.mem.Allocator,
        options: *const struct { now_ms: i64, open: ?Transcript.Run },
    ) ![]const ui.paint.Box {
        self.box_view.clearRetainingCapacity();
        var started_ms: ?i64 = null;
        var summary: ui.Block.Work.Summary = .{
            .elapsed_ms = 0,
            .tools = 0,
            .received_bytes = 0,
            .status = null,
        };
        if (options.open) |run| {
            started_ms = run.started_ms;
            summary.tools = run.tools;
            summary.received_bytes = run.received_bytes;
        }
        var activity_text: std.ArrayList(u8) = .empty;
        defer activity_text.deinit(gpa);
        if (self.thinking) try activity_text.appendSlice(gpa, "thinking");
        for (self.calls.items, 0..) |*call, index| {
            started_ms = @min(started_ms orelse call.opened_ms, call.opened_ms);
            if (self.thinking or self.liveCallBefore(index, call.name)) continue;
            if (activity_text.items.len > 0) try activity_text.appendSlice(gpa, ", ");
            const name_start = activity_text.items.len;
            try activity_text.appendSlice(gpa, call.name);
            const shown = format.singleLine(activity_text.items[name_start..]);
            activity_text.shrinkRetainingCapacity(name_start + shown.len);
        }
        summary.elapsed_ms = options.now_ms - (started_ms orelse return &.{});
        self.work_line.clearRetainingCapacity();
        var out: std.Io.Writer.Allocating = .fromArrayList(gpa, &self.work_line);
        defer self.work_line = out.toArrayList();
        summary.write(&out.writer, &.{
            .activity = activity_text.items,
            .ends = &self.work_ends,
        }) catch return error.OutOfMemory;
        try self.box_view.append(
            gpa,
            ui.Block.Work.box(out.written(), &self.work_ends, null),
        );
        return self.box_view.items;
    }

    fn liveCallBefore(self: *const Turn, index: usize, name: []const u8) bool {
        for (self.calls.items[0..index]) |*call| {
            if (std.mem.eql(u8, call.name, name)) return true;
        }
        return false;
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

pub const Call = struct {
    name: []const u8,
    phase: application.Live.Call.Phase,
    subject: []const u8,
    subject_kind: ?application.ToolDescription.Kind,
    opened_ms: i64,
    timeout_ms: ?u64,
    line: ?tool_line.Line,
    elapsed_seconds: ?i64,

    fn init(
        gpa: std.mem.Allocator,
        live: *const application.Live.Call,
        roots: *const format.Roots,
    ) !Call {
        const name = try gpa.dupe(u8, live.name);
        errdefer gpa.free(name);
        const subject = try tool_line.subject(gpa, &live.description, roots);
        errdefer gpa.free(subject);
        const subject_kind = if (live.description.subject) |value| value.kind else null;
        const line = try tool_line.render(gpa, &.{
            .name = live.name,
            .phase = switch (live.phase) {
                .streaming => .streaming,
                .queued => .queued,
                .running => .running,
            },
            .subject = subject,
            .subject_kind = subject_kind,
            .timeout_ms = switch (live.phase) {
                .running => live.description.timeout_ms,
                .streaming, .queued => null,
            },
            .received_bytes = switch (live.phase) {
                .running => null,
                .streaming, .queued => live.argument_bytes,
            },
        });
        return .{
            .name = name,
            .phase = live.phase,
            .subject = subject,
            .subject_kind = subject_kind,
            .opened_ms = live.opened_ms,
            .timeout_ms = live.description.timeout_ms,
            .line = line,
            .elapsed_seconds = null,
        };
    }

    fn deinit(self: *Call, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.subject);
        if (self.line) |*line| line.deinit(gpa);
    }

    fn text(self: *Call, gpa: std.mem.Allocator, now_ms: i64) ![]const u8 {
        const running = switch (self.phase) {
            .running => |running| running,
            .streaming, .queued => return self.line.?.text,
        };
        const timeout_ms = self.timeout_ms orelse return self.line.?.text;
        const seconds = @divFloor(@max(now_ms - running.started_ms, 0), std.time.ms_per_s);
        if (self.elapsed_seconds == seconds) return self.line.?.text;
        const line = try tool_line.render(gpa, &.{
            .name = self.name,
            .phase = .running,
            .subject = self.subject,
            .subject_kind = self.subject_kind,
            .elapsed_ms = seconds * std.time.ms_per_s,
            .timeout_ms = timeout_ms,
        });
        if (self.line) |*previous| previous.deinit(gpa);
        self.line = line;
        self.elapsed_seconds = seconds;
        return line.text;
    }
};

const Picking = struct {
    picker: ui.Picker,
    title: []const u8,
    wait_text: []const u8 = "",
    wait_tick: ?u64,

    fn deinit(self: *Picking, gpa: std.mem.Allocator) void {
        self.picker.deinit();
        gpa.free(self.title);
        gpa.free(self.wait_text);
    }

    fn activity(self: *const Picking) ?ui.paint.Activity {
        const tick = self.wait_tick orelse return null;
        return .{ .motion_tick = tick, .progress_age_ticks = 0 };
    }
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, effort: application.Effort) Screen {
    var self: Screen = .{
        .gpa = gpa,
        .transcript = .init(gpa),
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
        .branch_length = null,
        .window_pages = application.Settings.window_pages_default,
        .gauge = .{},
        .display_roots = .{},
    };
    self.page_view.preserveScrollback();
    return self;
}

pub fn deinit(self: *Screen) void {
    if (self.startup_failure) |text| self.gpa.free(text);
    self.deinitWidget();
    self.clearNotice();
    self.transcript.deinit();
    self.page_view.deinit();
    self.view.deinit();
    self.editor.deinit();
}

pub fn setVerbose(self: *Screen, verbose: bool) void {
    if (self.verbose == verbose) return;
    self.verbose = verbose;
    self.repaint_transcript = true;
}

pub fn clearNotice(self: *Screen) void {
    self.confirmation = null;
    if (self.notice) |notice| {
        notice.deinit(self.gpa);
        self.notice = null;
    }
}

pub fn setNotice(self: *Screen, notice: ui.Message) void {
    self.clearNotice();
    self.notice = notice;
}

pub fn confirm(
    self: *Screen,
    confirmation: ui.status.Confirmation,
    notice: ui.Message,
) void {
    self.setNotice(notice);
    self.confirmation = confirmation;
}

fn deinitWidget(self: *Screen) void {
    switch (self.widget) {
        .prompt => {},
        .turn => |*turn| turn.deinit(self.gpa),
        .picking => |*picking| picking.deinit(self.gpa),
        .page => |*page| page.deinit(),
    }
}

pub fn changeOf(event: *const application.Event) ?Change {
    return switch (event.*) {
        .append_record => |*record| .{ .append_record = record },
        .record_text => |text| .{ .record_text = text },
        .replace_record => |*record| .{ .replace_record = record },
        .remove_records => |ids| .{ .remove_records = ids },
        .live => |*live| .{ .live = live },
        .statistics => |statistics| .{ .statistics = statistics },
        .clear_conversation => .clear_conversation,
        .snapshot,
        .state,
        .paste_replayed,
        .turn_ended,
        .sign_in_ended,
        .fetch_ended,
        .no_account,
        .charge,
        .startup_refused,
        => null,
    };
}

pub fn applyChange(self: *Screen, change: *const Change) !void {
    switch (change.*) {
        .append_record => |record| {
            var block = try self.blockFrom(record);
            errdefer block.deinit(self.gpa);
            try self.transcript.block_list.append(self.gpa, block);
        },
        .record_text => |value| {
            const block = &self.transcript.block_list.items[self.transcript.find(value.id).?];
            try block.appendText(self.gpa, value.text);
        },
        .replace_record => |record| {
            const index = self.transcript.find(record.id).?;
            self.transcript.replace(index, try self.blockFrom(record));
        },
        .remove_records => |ids| {
            self.transcript.remove(ids);
            if (self.widget != .turn) {
                self.view.resetScreen();
                self.markEdited();
            }
        },
        .live => |live| try self.showLive(live),
        .statistics => |statistics| self.statistics = statistics,
        .clear_conversation => try self.clearConversation(),
    }
    if (self.activeTurn()) |turn| turn.progress_tick_last = turn.activity_tick;
}

fn blockFrom(self: *Screen, record: *const application.Record) !ui.Block {
    var block: ui.Block = switch (record.content) {
        .user => |text| try .init(self.gpa, &.{ .user = text.items }),
        .user_note => |*note| switch (note.*) {
            .skill => |*skill| try self.skillBlock(skill),
            .retry => try .init(self.gpa, &.{ .user_note = .{ .text = retry_note } }),
        },
        .model => |text| try .init(self.gpa, &.{ .model = text.items }),
        .thinking => |text| try .init(self.gpa, &.{ .thinking = text.items }),
        .event => |*event| event: {
            const message = try wording.event(self.gpa, event);
            defer message.deinit(self.gpa);
            break :event try .init(self.gpa, &.{ .event = .{
                .text = message.content,
                .severity = message.severity,
            } });
        },
        .tool_result => |*result| try self.toolBlock(result),
        .authorization => |*authorization| try authorizationBlock(self.gpa, authorization),
    };
    block.record_id = record.id;
    if (record.work) |work| block.work = .{
        .started_ms = work.started_ms,
        .end = if (work.end) |end| .{ .time_ms = end.time_ms, .status = end.status } else null,
    };
    return block;
}

fn authorizationBlock(
    gpa: std.mem.Allocator,
    authorization: *const application.Record.Authorization,
) !ui.Block {
    const lead = "Open this URL to authorize the sign-in to {s}:\n\n{s}\n\n";
    const account = application.query.accountId(authorization.account);
    const text = if (authorization.code) |code| try gpa.print(
        lead ++ "Enter this code if the page asks for one: {s}",
        .{ account, authorization.url, code },
    ) else try gpa.print(
        lead ++ "If the browser shows an error, paste the callback URL from its address bar " ++
            "and press Enter.",
        .{ account, authorization.url },
    );
    defer gpa.free(text);
    return .init(gpa, &.{ .event = .{ .text = text, .severity = .information } });
}

fn skillBlock(self: *Screen, skill: *const application.SkillLoaded) !ui.Block {
    const path = try format.path(self.gpa, skill.source, &self.display_roots);
    defer self.gpa.free(path);
    const name = try self.gpa.dupe(u8, skill.name);
    defer self.gpa.free(name);
    const shown_name = format.singleLine(name);
    const text = try self.gpa.print("Skill: {s} · File: {s}", .{
        shown_name,
        format.singleLine(path),
    });
    defer self.gpa.free(text);
    return .init(self.gpa, &.{ .user_note = .{
        .text = text,
        .segment_ends = &.{ "Skill: ".len + shown_name.len, text.len },
    } });
}

fn toolBlock(self: *Screen, result: *const application.Record.Result) !ui.Block {
    const subject = try tool_line.subject(self.gpa, &result.description, &self.display_roots);
    defer self.gpa.free(subject);
    const line = try tool_line.render(self.gpa, &.{
        .name = result.name,
        .subject = subject,
        .subject_kind = if (result.description.subject) |value| value.kind else null,
        .output = &result.output,
        .elapsed_ms = result.elapsed_ms,
    });
    defer line.deinit(self.gpa);
    return .init(self.gpa, &.{ .tool_result = .{
        .text = line.text,
        .segment_ends = line.segment_ends,
        .status = line.status,
        .qualifiers = line.qualifiers,
        .command = line.command,
        .started_ms = result.started_ms,
        .received_bytes = result.received_bytes,
    } });
}

fn showLive(self: *Screen, live: *const application.Live) !void {
    const turn = self.activeTurn() orelse {
        std.debug.assert(live.calls.len == 0 and !live.thinking);
        return;
    };
    var calls: std.ArrayList(Call) = .empty;
    errdefer {
        for (calls.items) |*call| call.deinit(self.gpa);
        calls.deinit(self.gpa);
    }
    try calls.ensureTotalCapacity(self.gpa, live.calls.len);
    for (live.calls) |*call|
        calls.appendAssumeCapacity(try .init(self.gpa, call, &self.display_roots));
    turn.releaseCalls(self.gpa);
    turn.calls.deinit(self.gpa);
    turn.calls = calls;
    turn.thinking = live.thinking;
}

fn clearConversation(self: *Screen) !void {
    std.debug.assert(self.widget == .prompt);
    self.clearNotice();
    if (self.startup_failure) |text| self.gpa.free(text);
    self.startup_failure = null;
    self.transcript.truncate(0);
    try self.appendIntro();
    self.view.resetScreen();
}

pub fn setStartupFailure(self: *Screen, text: []const u8) error{OutOfMemory}!void {
    const owned = try self.gpa.dupe(u8, text);
    if (self.startup_failure) |previous| self.gpa.free(previous);
    self.startup_failure = owned;
}

fn appendIntro(self: *Screen) !void {
    try self.transcript.append(&.{ .intro = self.intro });
    const failure = self.startup_failure orelse return;
    try self.transcript.append(&.{ .event = .{ .text = failure, .severity = .failure } });
}

fn beginTurn(self: *Screen) void {
    std.debug.assert(self.widget == .prompt);
    self.widget = .{ .turn = .empty };
}

fn endTurn(self: *Screen) void {
    if (self.activeTurn()) |turn| turn.deinit(self.gpa);
    self.clearNotice();
    self.widget = .prompt;
}

pub fn applyState(self: *Screen, value: *const application.State) !void {
    self.choice = value.choice;
    self.setBranch(value.branch);
    if (value.work == .turn) {
        if (self.widget != .turn) {
            self.leaveWidget();
            self.beginTurn();
        }
    } else if (self.widget == .turn) self.endTurn();
    try self.showResult(if (value.result) |*result| result else null);
    if (value.notice_id != self.notice_id) {
        const notice = if (value.notice) |*event| try wording.event(self.gpa, event) else null;
        self.notice_id = value.notice_id;
        if (notice) |message| self.setNotice(message) else self.clearNotice();
    }
}

fn leaveWidget(self: *Screen) void {
    switch (self.widget) {
        .prompt => {},
        .turn => self.endTurn(),
        .picking => self.closePicker(),
        .page => self.closePage(),
    }
}

fn showResult(self: *Screen, maybe_result: ?*const application.State.Result) !void {
    const result = maybe_result orelse {
        if (self.result_page != null) self.closePage();
        return;
    };
    if (self.result_page == null or self.result_page.?.id != result.id) {
        self.leaveWidget();
        try self.openPage(&.{
            .title = switch (result.purpose) {
                .handoff => "Handoff",
                .short_answer => "Short answer",
            },
            .content = "",
        });
    }
    self.result_page = .{ .id = result.id, .phase = result.phase };
    const page = self.activePage().?;
    const shown_text = page.text();
    if (result.text.len > shown_text.len) try page.append(result.text[shown_text.len..]);
    page.action = switch (result.purpose) {
        .handoff => if (result.phase == .complete) .apply else .discard,
        .short_answer => .close,
    };
    switch (result.phase) {
        .generating => |*generating| try self.showGenerating(page, generating),
        .complete => self.endPageWait(page),
        .incomplete => |notice| {
            self.endPageWait(page);
            const message = try wording.event(self.gpa, &switch (notice) {
                .truncated => .reply_truncated,
                .failed => |failure| .{ .request_failed = failure },
            });
            defer message.deinit(self.gpa);
            if (!sameMessage(&page.notice, &message)) try page.setNotice(&message);
        },
    }
}

fn endPageWait(self: *Screen, page: *ui.Page) void {
    self.page_wait = null;
    page.endWait();
}

fn showGenerating(
    self: *Screen,
    page: *ui.Page,
    generating: *const application.State.Result.Generating,
) !void {
    if (generating.retry) |attempt| {
        const message = try wording.event(self.gpa, &.{ .attempt_failed = attempt });
        defer message.deinit(self.gpa);
        if (!sameMessage(&page.retry, &message)) try page.setRetry(&message);
    }
    if (self.page_wait == null) self.page_wait = .{ .started_ms = generating.started_ms };
    const shown = &self.page_wait.?;
    if (shown.received_bytes == generating.received_bytes and
        shown.thinking == generating.thinking) return;
    shown.received_bytes = generating.received_bytes;
    shown.thinking = generating.thinking;
    shown.seconds_shown = null;
}

fn sameMessage(maybe_shown: *const ?ui.Message, message: *const ui.Message) bool {
    const shown = maybe_shown.* orelse return false;
    return shown.severity == message.severity and std.mem.eql(u8, shown.content, message.content);
}

pub fn setDraft(self: *Screen, text: []const u8) !void {
    var editor = ui.Editor.init(self.gpa);
    errdefer editor.deinit();
    try editor.insert(text);
    self.editor.deinit();
    self.editor = editor;
    self.markEdited();
}

pub fn openPicker(self: *Screen, options: *const PickerOptions) !void {
    const scroll = self.stepScroll(options.depth);
    const title = try self.gpa.dupe(u8, options.title);
    errdefer self.gpa.free(title);
    const owned = try self.gpa.alloc(ui.Picker.Option, options.options.len);
    var count: usize = 0;
    errdefer {
        for (owned[0..count]) |*option| option.deinit(self.gpa);
        self.gpa.free(owned);
    }
    for (options.options, owned) |*source, *target| {
        target.* = try source.dupe(self.gpa);
        count += 1;
    }
    const picker = try ui.Picker.init(self.gpa, title, owned, &.{
        .current = options.current,
        .preselected = options.preselected,
        .position = if (options.cursor) |cursor| .{ .cursor = cursor, .scroll = scroll } else null,
        .can_step_back = options.depth > 0,
    });
    self.leaveWidget();
    self.widget = .{ .picking = .{ .picker = picker, .title = title, .wait_tick = null } };
    self.picker_depth = options.depth;
}

fn stepScroll(self: *Screen, depth: usize) usize {
    const previous = self.activePicker() orelse return 0;
    if (depth > self.picker_depth) {
        if (self.picker_depth < picker_scrolls_max)
            self.picker_scrolls[self.picker_depth] = previous.window.scroll;
        return 0;
    }
    if (depth < self.picker_depth and depth < picker_scrolls_max) return self.picker_scrolls[depth];
    return 0;
}

pub fn closePicker(self: *Screen) void {
    switch (self.widget) {
        .picking => |*picking| {
            picking.deinit(self.gpa);
            self.widget = .prompt;
        },
        .prompt, .turn, .page => {},
    }
}

pub fn beginPickerWait(self: *Screen, text: []const u8) !void {
    const picking = &self.widget.picking;
    const owned = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(owned);
    try picking.picker.beginWait(owned);
    self.gpa.free(picking.wait_text);
    picking.wait_text = owned;
    picking.wait_tick = 0;
}

pub fn openPage(self: *Screen, options: *const ui.Page.Options) !void {
    std.debug.assert(self.widget == .prompt);
    var page = try ui.Page.init(self.gpa, options);
    page.reflow(.{ .columns = self.columns, .rows = self.rows });
    self.page_view.forget();
    self.page_view.resetScreen();
    self.widget = .{ .page = page };
}

fn pageWaiting(self: *const Screen, page: *const ui.Page) bool {
    return self.page_wait != null and page.text().len == 0 and page.notice == null;
}

fn showPageWait(self: *Screen, page: *ui.Page, now_ms: i64) void {
    if (!self.pageWaiting(page)) return;
    const wait = &self.page_wait.?;
    const seconds = wait.seconds(now_ms);
    if (wait.seconds_shown == seconds) return;
    page.refreshWait(&.{
        .elapsed_ms = seconds * std.time.ms_per_s,
        .received_bytes = wait.received_bytes,
        .thinking = wait.thinking,
    });
    wait.seconds_shown = seconds;
}

pub fn closePage(self: *Screen) void {
    self.page_wait = null;
    self.result_page = null;
    switch (self.widget) {
        .page => |*page| {
            page.deinit();
            self.widget = .prompt;
        },
        .prompt, .turn, .picking => {},
    }
}

fn setBranch(self: *Screen, maybe_name: ?[]const u8) void {
    if (self.branch()) |shown| if (maybe_name) |name| if (std.mem.eql(u8, shown, name)) return;
    self.branch_length = if (maybe_name) |name| length: {
        std.debug.assert(name.len <= self.branch_buffer.len);
        @memcpy(self.branch_buffer[0..name.len], name);
        break :length name.len;
    } else null;
}

pub fn branch(self: *const Screen) ?[]const u8 {
    const length = self.branch_length orelse return null;
    return self.branch_buffer[0..length];
}

pub fn restore(self: *Screen, snapshot: *const application.Snapshot) !void {
    const state = &snapshot.state;
    var restored = Screen.init(self.gpa, self.view.writer, state.choice.effort);
    errdefer restored.deinit();
    restored.intro = self.intro;
    restored.startup_failure = self.startup_failure;
    self.startup_failure = null;
    restored.repaint_transcript = self.repaint_transcript or
        self.transcript.block_list.items.len > 0;
    restored.verbose = self.verbose;
    restored.window_pages = snapshot.settings.window_pages;
    restored.gauge = snapshot.settings.gauge;
    restored.display_roots = .{
        .working_directory = snapshot.working_directory,
        .home_directory = snapshot.home_directory,
    };
    restored.directory_shown = self.directory_shown;
    restored.mcp_access = self.mcp_access;
    restored.statistics = snapshot.statistics;
    restored.picker_scrolls = self.picker_scrolls;
    restored.picker_depth = self.picker_depth;
    try restored.appendIntro();
    try restored.transcript.block_list.ensureUnusedCapacity(self.gpa, snapshot.records.len);
    for (snapshot.records) |*record|
        restored.transcript.block_list.appendAssumeCapacity(try restored.blockFrom(record));
    try restored.applyState(state);
    if (state.work == .turn) try restored.showLive(&snapshot.live);
    if (restored.result_page) |shown| {
        const page = restored.activePage().?;
        if (self.result_page) |previous| if (previous.id == shown.id) {
            page.restorePosition(self.activePage().?);
        };
    }
    const local = switch (self.widget) {
        .picking => true,
        .page => self.result_page == null,
        .prompt, .turn => false,
    };
    if (self.notice != null and self.notice_id == state.notice_id) {
        restored.clearNotice();
        restored.notice = self.notice;
        restored.confirmation = self.confirmation;
        self.notice = null;
    }
    if (local and restored.widget == .prompt) {
        restored.widget = self.widget;
        self.widget = .prompt;
        std.mem.swap(terminal.View, &self.page_view, &restored.page_view);
    }
    const editor = self.editor;
    self.editor = restored.editor;
    restored.editor = editor;
    std.mem.swap(terminal.View, &self.view, &restored.view);
    const roots = self.display_roots;
    self.deinit();
    self.* = restored;
    self.display_roots = roots;
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
            self.showPageWait(page, time.awake_ms);
            page.reflow(size);
            const scene: layout.Scene = .{ .page = page };
            try layout.project(self.gpa, &self.page_view, size, &scene);
            return;
        },
        .prompt, .turn, .picking => {},
    }

    self.transcript.present(self.verbose);
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
            const boxes = if (self.verbose)
                try turn.boxes(self.gpa, time.awake_ms)
            else
                try turn.workBoxes(self.gpa, &.{
                    .now_ms = time.awake_ms,
                    .open = self.transcript.openWork(),
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
        .quota = if (self.statistics.quota) |reading|
            .{ .windows = reading.windows, .age_ms = boot_ms - reading.seen_ms }
        else
            null,
        .credits = self.statistics.credits,
        .turn_active = self.widget == .turn,
        .mcp_access = self.mcp_access,
        .gauge = self.gauge,
        .notice = self.notice,
        .confirmation = self.confirmation,
    };
}

pub fn parkCursor(self: *Screen) !void {
    try self.view.parkCursor();
}

pub fn markEdited(self: *Screen) void {
    if (self.activeTurn()) |turn| turn.caret_tick = 0;
}

pub fn advanceFrame(self: *Screen, now_ms: i64) bool {
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
        .page => |*page| if (self.pageWaiting(page)) {
            const wait = &self.page_wait.?;
            activity_changed = wait.seconds_shown != wait.seconds(now_ms);
        },
        .prompt => {},
    }
    return activity_changed;
}

pub fn animating(self: *const Screen) bool {
    return switch (self.widget) {
        .turn => true,
        .picking => |*picking| picking.wait_tick != null,
        .page => |*page| self.pageWaiting(page),
        .prompt => false,
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
        .prompt, .picking, .page => null,
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
    try std.testing.expectApproxEqAbs(@as(f64, 18), rig.screen.statusInfo(0).cost, 1e-9);

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
    reduction: application.testing.Reduction,
    time: Time,

    fn init(self: *Rig) void {
        self.initWith(std.testing.allocator, null);
    }

    fn initWith(self: *Rig, gpa: std.mem.Allocator, writer: ?*std.Io.Writer) void {
        self.out = .init(gpa);
        self.screen = Screen.init(gpa, writer orelse &self.out.writer, .high);
        const choice: application.Choice = .{
            .account = accounts.testing.anthropic_plan,
            .model = testModel(),
            .effort = .high,
        };
        self.screen.choice = choice;
        self.reduction.init(std.testing.allocator, choice);
        self.time = .{ .awake_ms = 0, .boot_ms = 0 };
    }

    fn deinit(self: *Rig) void {
        self.reduction.deinit();
        self.screen.deinit();
        self.out.deinit();
    }

    fn forward(self: *Rig) error{OutOfMemory}!void {
        defer self.reduction.clear();
        for (self.reduction.events.items) |*event| try self.mirror(event);
    }

    fn choose(self: *Rig, choice: *const application.Choice) error{OutOfMemory}!void {
        self.reduction.surface.showChoice(choice);
        self.reduction.flush();
        try self.forward();
    }

    fn start(self: *Rig, text: []const u8) error{OutOfMemory}!void {
        try self.reduction.start(text);
        try self.forward();
    }

    fn addUser(self: *Rig, text: []const u8) error{OutOfMemory}!void {
        try self.reduction.surface.appendUser(text);
        self.reduction.flush();
        try self.forward();
    }

    fn addSkill(self: *Rig, skill: *const application.SkillLoaded) error{OutOfMemory}!void {
        try self.reduction.surface.appendSkillNote(skill);
        self.reduction.flush();
        try self.forward();
    }

    fn step(self: *Rig, event: *const core.Session.Event) error{OutOfMemory}!?core.Session.Outcome {
        const outcome = try self.reduction.apply(event, .{
            .awake_ms = self.time.awake_ms,
            .boot_ms = self.time.boot_ms,
        });
        try self.forward();
        return outcome;
    }

    fn mirror(self: *Rig, event: *const application.Event) !void {
        if (changeOf(event)) |*change| try self.screen.applyChange(change);
        if (event.* == .state) try self.screen.applyState(&self.shown(&event.state));
    }

    fn shown(self: *const Rig, value: *const application.State) application.State {
        var result = value.*;
        result.branch = self.screen.branch();
        return result;
    }

    fn showResult(self: *Rig, result: *const application.State.Result) !void {
        try self.screen.applyState(&self.shown(&.{
            .work = if (result.phase == .generating) .{ .aside = result.id } else .idle,
            .result = result.*,
            .notice_id = self.screen.notice_id,
            .choice = self.screen.choice,
        }));
    }

    fn setRetry(self: *Rig, text: []const u8) !void {
        try self.screen.activePage().?.setRetry(&.{ .content = text, .severity = .information });
    }

    fn apply(self: *Rig, event: *const core.Session.Event) !void {
        try std.testing.expect(try self.step(event) == null);
    }

    fn end(self: *Rig, outcome: *const core.Session.Outcome) !void {
        const ended = try self.step(&.{ .turn_ended = outcome.* }) orelse
            return error.TestExpectedTurnEnd;
        try std.testing.expectEqual(std.meta.activeTag(outcome.*), std.meta.activeTag(ended));
        try std.testing.expect(self.screen.widget == .prompt);
    }

    fn blocks(self: *const Rig) []const ui.Block {
        return self.screen.transcript.block_list.items;
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

    fn paintInto(self: *Rig, emulator: *terminal.testing.Emulator, size: terminal.View.Size) !void {
        self.out.clearRetainingCapacity();
        try self.screen.paint(size, self.time, &no_caption);
        try emulator.feed(self.out.written());
    }

    fn paintPlain(self: *Rig, columns: usize) ![]u8 {
        self.out.clearRetainingCapacity();
        try self.screen.paint(.{ .columns = columns, .rows = 24 }, self.time, &no_caption);
        return terminal.testing.plainText(std.testing.allocator, self.out.written());
    }
};

const no_caption: ?ui.Caption = null;
const overloaded_attempt: application.Record.Event.Attempt = .{
    .attempt = 1,
    .reason = .overloaded,
    .details = null,
    .delay_ms = 0,
};

test "tool metadata keeps its state and removes whole segments during and after a call" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("prompt");
    const call: core.Tool.Call = .{
        .id = "read",
        .name = "read",
        .arguments = "{\"path\":\"a very long path with a · separator.zig\"}",
    };
    try rig.apply(&.{ .tool_call_started = call.name });
    try rig.apply(&.{ .tool_call_arguments = call.arguments });
    const streamed = try rig.paintPlain(80);
    defer gpa.free(streamed);
    try testing.expectContains(streamed, "Tool: read (streaming) · Received:");
    try rig.apply(&.{ .tool_started = call });
    const running = try rig.paintPlain(30);
    defer gpa.free(running);
    try testing.expectContains(running, "Tool: read (running)");
    try std.testing.expect(std.mem.find(u8, running, "File:") == null);
    var output: core.Tool.Output = .{};
    output.measures.put(.lines, 120);
    try rig.apply(&.{ .tool_result = .{ .call = call, .output = output } });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    for ([_]usize{ 40, 60 }) |columns| {
        const narrow = try rig.paintPlain(columns);
        defer gpa.free(narrow);
        try testing.expectContains(narrow, "Tool: read (complete)");
        try std.testing.expect(std.mem.find(u8, narrow, "File:") == null);
        try std.testing.expect(std.mem.find(u8, narrow, "Lines:") == null);
        try std.testing.expect(std.mem.find(u8, narrow, "Time:") == null);
        try std.testing.expectEqual(
            @as(usize, 1),
            rig.blocks()[1].rows(columns),
        );
    }
    const wide = try rig.paintPlain(120);
    defer gpa.free(wide);
    try testing.expectContains(wide, "Tool: read (complete) · File: " ++
        "a very long path with a · separator.zig · Lines: 120");
}

test "a verbose command keeps its gutter rows when its call completes" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("prompt");
    const call: core.Tool.Call = .{
        .id = "bash",
        .name = "bash",
        .arguments = "{\"command\":\"cat <<'EOF'\\n  first\\n\\n" ++
            "a long command line that must wrap and keep its final-word\\nEOF\"}",
    };
    try rig.apply(&.{ .tool_call_started = call.name });
    try rig.apply(&.{ .tool_started = call });
    rig.time.awake_ms = 3_000;
    const expected = [_][]const u8{
        "$ cat <<'EOF'",
        "    first",
        "",
        "  a long command line that must wrap and keep",
        "↪ its final-word",
        "  EOF",
    };
    for ([_][]const u8{ "Tool: bash (running)", "Tool: bash (complete)" }, 0..) |identity, stage| {
        const painted = try rig.paintPlain(48);
        defer gpa.free(painted);
        var rows = std.mem.splitSequence(u8, painted, "\r\n");
        while (rows.next()) |row| {
            if (std.mem.startsWith(u8, row, identity)) break;
        } else return error.TestUnexpectedResult;
        for (expected) |line| {
            try std.testing.expectEqualStrings(line, std.mem.trimEnd(u8, rows.next().?, " "));
        }
        if (stage == 0) {
            var output: core.Tool.Output = .{};
            output.measures.put(.duration_ms, 3_000);
            output.measures.put(.exit_code, 0);
            output.measures.put(.lines, 1);
            try rig.apply(&.{ .tool_result = .{ .call = call, .output = output } });
            try rig.apply(&.committed);
            try rig.end(&.{ .stopped = .complete });
        }
    }
}

test "a running tool uses the final call name instead of the streamed name" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("prompt");
    try rig.apply(&.{ .tool_call_started = "partial" });
    try rig.apply(&.{ .tool_started = .{
        .id = "call",
        .name = "write",
        .arguments = "{\"path\":\"a.zig\",\"content\":\"text\"}",
    } });
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try testing.expectContains(
        painted,
        "Tool: write (running) · Time: 0s · File: a.zig · Timeout: 10s",
    );
    try std.testing.expect(std.mem.find(u8, painted, "Tool: partial") == null);
}

test "a canceled call shows the time that it ran, and a call that never ran shows none" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("prompt");
    const grep: core.Tool.Call = .{
        .id = "grep",
        .name = "grep",
        .arguments = "{\"pattern\":\"needle\"}",
    };
    const read: core.Tool.Call = .{
        .id = "read",
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    };
    try rig.apply(&.{ .tool_call_started = grep.name });
    try rig.apply(&.{ .tool_call_started = read.name });
    try rig.apply(&.{ .tool_started = grep });
    rig.time.awake_ms += 4_200;
    for ([_]core.Tool.Call{ grep, read }) |call| {
        try rig.apply(&.{ .tool_result = .{
            .call = call,
            .output = .{ .content = "x", .conditions = .initOne(.canceled) },
        } });
    }
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try testing.expectContains(painted, "Tool: grep (canceled) · Time: 4.2s · Pattern: needle");
    try testing.expectContains(painted, "Tool: read (canceled) · File: a.zig");
    try std.testing.expect(std.mem.find(u8, painted, "Tool: read (canceled) · Time") == null);
}

test "a search that stops early reads as partial and puts its limit before its counts" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("prompt");
    const call: core.Tool.Call = .{
        .id = "grep",
        .name = "grep",
        .arguments = "{\"pattern\":\"needle\"}",
    };
    try rig.apply(&.{ .tool_call_started = call.name });
    try rig.apply(&.{ .tool_started = call });
    var output: core.Tool.Output = .{};
    output.measures.put(.duration_ms, 500);
    output.measures.put(.matches, 8);
    output.conditions.insert(.time_limit_reached);
    try rig.apply(&.{ .tool_result = .{ .call = call, .output = output } });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    const wide = try rig.paintPlain(120);
    defer gpa.free(wide);
    try testing.expectContains(wide, "Tool: grep (partial) · Time: 500ms · Pattern: needle · " ++
        "Stopped: time limit · Matches: 8");
    const narrow = try rig.paintPlain(25);
    defer gpa.free(narrow);
    try testing.expectContains(narrow, "Tool: grep (partial)");
    try std.testing.expect(std.mem.find(u8, narrow, "Stopped:") == null);
}

test "omitted find matches keep a complete outcome without a condition" {
    var output: core.Tool.Output = .{};
    output.measures.put(.duration_ms, 0);
    output.measures.put(.matches, 1);
    output.measures.put(.matches_omitted, 1);
    try expectCompleteResult(&.{
        .id = "find",
        .name = "find",
        .arguments = "{\"pattern\":\"*.zig\",\"limit\":1}",
    }, &output);
}

test "a partial read window keeps a complete outcome without a condition" {
    var output: core.Tool.Output = .{};
    output.measures.put(.lines, 50);
    output.measures.put(.line_first, 1);
    output.measures.put(.lines_total, 300);
    try expectCompleteResult(&.{
        .id = "read",
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    }, &output);
}

fn expectCompleteResult(call: *const core.Tool.Call, output: *const core.Tool.Output) !void {
    const gpa = std.testing.allocator;
    const expected = try gpa.print("Tool: {s} (complete)", .{call.name});
    defer gpa.free(expected);
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("prompt");
    try rig.apply(&.{ .tool_call_started = call.name });
    try rig.apply(&.{ .tool_started = call.* });
    try rig.apply(&.{ .tool_result = .{ .call = call.*, .output = output.* } });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    const narrow = try rig.paintPlain(25);
    defer gpa.free(narrow);
    try testing.expectContains(narrow, expected);
    try std.testing.expect(std.mem.find(u8, narrow, "Lines:") == null);
    try std.testing.expect(std.mem.find(u8, narrow, "Matches:") == null);
}

fn expectSummary(painted: []const u8, expected: []const u8) !void {
    var lines = std.mem.splitScalar(u8, painted, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, "\r "), expected)) return;
    }
    std.debug.print("expected the row \"{s}\" in:\n{s}\n", .{ expected, painted });
    return error.TestExpectedSummary;
}

fn checkWorkAllocations(gpa: std.mem.Allocator) error{OutOfMemory}!void {
    var rig: Rig = undefined;
    rig.initWith(gpa, null);
    defer rig.deinit();
    const screen = &rig.screen;
    screen.setVerbose(!screen.verbose);
    try rig.start("prompt");
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
    rig.time = .{ .awake_ms = 2_000, .boot_ms = 2_000 };
    for (&events) |*event| _ = try rig.step(event);
    try rig.start("next");
    const canceled = [_]core.Session.Event{
        .reasoning_started,
        .{ .reasoning = "partial" },
        .{ .tail_discarded = 1 },
        .{ .turn_ended = .canceled },
    };
    rig.time = .{ .awake_ms = 4_000, .boot_ms = 4_000 };
    for (&canceled) |*event| _ = try rig.step(event);
    screen.setVerbose(!screen.verbose);
}

test "work summaries and tool events free each partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkWorkAllocations,
        .{},
    );
}

test "tool commands and metadata release each partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkToolAllocations,
        .{},
    );
}

fn checkToolAllocations(gpa: std.mem.Allocator) !void {
    var output_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_buffer.deinit();
    var rig: Rig = undefined;
    rig.initWith(gpa, &output_buffer.writer);
    defer rig.deinit();
    const screen = &rig.screen;
    screen.setVerbose(!screen.verbose);
    try rig.start("prompt");
    const call: core.Tool.Call = .{
        .id = "bash",
        .name = "bash",
        .arguments = "{\"command\":\"printf first\\n  printf a-long-final-word\"}",
    };
    const events = [_]core.Session.Event{
        .{ .tool_call_started = "bash" },
        .{ .tool_call_arguments = call.arguments },
        .{ .tool_call_started = "read" },
        .{ .tool_started = call },
    };
    for (&events) |*event| _ = try rig.step(event);
    for ([_]usize{ 80, 20 }) |columns| {
        rig.time.awake_ms += 1_000;
        try screen.paint(.{ .columns = columns, .rows = 24 }, rig.time, &no_caption);
    }
    var output: core.Tool.Output = .{};
    output.measures.put(.duration_ms, 2_000);
    output.measures.put(.exit_code, 0);
    output.conditions.insert(.output_truncated);
    _ = try rig.step(&.{ .tool_result = .{ .call = call, .output = output } });
    const read: core.Tool.Call = .{
        .id = "read",
        .name = "read",
        .arguments = "{\"path\":\"a · b.zig\"}",
    };
    _ = try rig.step(&.{ .tool_started = read });
    var failure: core.Tool.Output = .{ .content = "Drinky could not read the complete file." };
    failure.conditions.insert(.path_missing);
    _ = try rig.step(&.{ .tool_result = .{ .call = read, .output = failure } });
    const grep: core.Tool.Call = .{
        .id = "grep",
        .name = "grep",
        .arguments = "{\"pattern\":\"needle\"}",
    };
    _ = try rig.step(&.{ .tool_call_started = grep.name });
    _ = try rig.step(&.{ .tool_started = grep });
    var partial: core.Tool.Output = .{};
    partial.conditions.insert(.time_limit_reached);
    partial.conditions.insert(.match_limit_reached);
    partial.conditions.insert(.byte_limit_reached);
    partial.conditions.insert(.incomplete);
    _ = try rig.step(&.{ .tool_result = .{ .call = grep, .output = partial } });
    try rig.addSkill(&.{ .name = "zig-style", .source = "a · b/SKILL.md" });
    screen.setVerbose(!screen.verbose);
    try screen.paint(.{ .columns = 30, .rows = 24 }, rig.time, &no_caption);
}

test "a device write failure stays distinct from an allocation failure" {
    var writer: std.Io.Writer = .failing;
    var screen = Screen.init(std.testing.allocator, &writer, .high);
    defer screen.deinit();
    try std.testing.expectError(
        error.WriteFailed,
        screen.paint(.{ .columns = 80, .rows = 24 }, .{ .awake_ms = 0, .boot_ms = 0 }, &no_caption),
    );
}

test "a work row in a small window keeps its current measurements and final status" {
    const gpa = std.testing.allocator;
    const size: terminal.View.Size = .{ .columns = 80, .rows = 2 };
    var device: terminal.testing.FakeDevice = undefined;
    try device.init(gpa, std.testing.io, size);
    defer device.deinit();
    var rig: Rig = undefined;
    rig.initWith(gpa, device.device().writer());
    defer rig.deinit();
    const screen = &rig.screen;
    screen.window_pages = 1;
    screen.setVerbose(!screen.verbose);
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "abc" });
    try screen.paint(size, rig.time, &no_caption);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const first = try device.snapshot(arena.allocator());
    try expectSummary(
        try std.mem.join(arena.allocator(), "\n", first.rows),
        "Agent: work (thinking) · Time: 0s · Tools: 0 · Received: 3 B",
    );
    rig.time.awake_ms = 3_000;
    try rig.apply(&.{ .reasoning = "def" });
    try screen.paint(size, rig.time, &no_caption);
    const active = try device.snapshot(arena.allocator());
    const active_rows = try std.mem.join(arena.allocator(), "\n", active.rows);
    try expectSummary(
        active_rows,
        "Agent: work (thinking) · Time: 3s · Tools: 0 · Received: 6 B",
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, active_rows, "Agent: work"));
    rig.time.awake_ms = 4_000;
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    try screen.paint(size, rig.time, &no_caption);
    const complete = try device.snapshot(arena.allocator());
    const complete_rows = try std.mem.join(arena.allocator(), "\n", complete.rows);
    try expectSummary(
        complete_rows,
        "Agent: work (complete) · Time: 4s · Tools: 0 · Received: 6 B",
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, complete_rows, "Agent: work"));
}

test "a work update inside the frame keeps all history above the visible screen" {
    const gpa = std.testing.allocator;
    const size: terminal.View.Size = .{ .columns = 80, .rows = 8 };
    var device: terminal.testing.FakeDevice = undefined;
    try device.init(gpa, std.testing.io, size);
    defer device.deinit();
    var rig: Rig = undefined;
    rig.initWith(gpa, device.device().writer());
    defer rig.deinit();
    const screen = &rig.screen;
    for (0..99) |index| {
        const text = try gpa.print("message-{d}", .{index});
        defer gpa.free(text);
        try rig.addUser(text);
    }
    try screen.setDraft("line1\nline2\nline3\nline4\nline5");
    try rig.start("message-99");
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "abc" });
    screen.setVerbose(!screen.verbose);
    try screen.paint(size, rig.time, &no_caption);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const first = try device.snapshot(arena.allocator());
    var first_count: usize = 0;
    for (first.rows) |row| first_count += @intFromBool(std.mem.startsWith(u8, row, "message-"));
    try std.testing.expectEqual(@as(usize, 100), first_count);
    rig.time.awake_ms = 3_000;
    try rig.apply(&.{ .reasoning = "def" });
    try screen.paint(size, rig.time, &no_caption);
    const active = try device.snapshot(arena.allocator());
    var active_count: usize = 0;
    for (active.rows) |row| {
        active_count += @intFromBool(std.mem.startsWith(u8, row, "message-"));
    }
    try std.testing.expectEqual(@as(usize, 100), active_count);
    try expectSummary(
        try std.mem.join(arena.allocator(), "\n", active.rows),
        "Agent: work (thinking) · Time: 3s · Tools: 0 · Received: 6 B",
    );
}

test "a verbose work end above the window keeps the scrollback" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.window_pages = 1;
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    var reasoning = try ui.testing.numberedLines(gpa, 40);
    defer reasoning.deinit(gpa);
    try rig.apply(&.{ .reasoning = reasoning.items });
    const before = try rig.paintPlain(80);
    defer gpa.free(before);
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    const after = try rig.paintPlain(80);
    defer gpa.free(after);
    try testing.expectContains(after, "answer");
    try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[3J") == null);
}

test "a verbosity toggle repaints the complete transcript beyond the window limit" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.window_pages = 1;
    for (0..60) |index| {
        const text = try gpa.print("message-{d}", .{index});
        defer gpa.free(text);
        try rig.addUser(text);
    }
    const recent = try rig.paintPlain(80);
    defer gpa.free(recent);
    try std.testing.expect(std.mem.find(u8, recent, "message-0") == null);
    for (0..2) |_| {
        rig.screen.setVerbose(!rig.screen.verbose);
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

test "a work summary joins consecutive thinking blocks and keeps their text and final timer" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    rig.time.awake_ms = 2_000;
    const empty = try rig.paintPlain(80);
    defer gpa.free(empty);
    try expectSummary(
        empty,
        "Agent: work (thinking) · Time: 2s · Tools: 0 · Received: 0 B",
    );
    try testing.expectContains(rig.out.written(), "\x1b[36m\x1b[2mAgent: work (thinking)\x1b[0m");
    try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[36;7m") == null);

    try rig.apply(&.{ .reasoning = "alpha" });
    rig.time.awake_ms = 3_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "βeta" });
    rig.time.awake_ms = 6_000;
    rig.screen.setVerbose(!rig.screen.verbose);
    rig.screen.setVerbose(!rig.screen.verbose);
    const active = try rig.paintPlain(80);
    defer gpa.free(active);
    try expectSummary(
        active,
        "Agent: work (thinking) · Time: 6s · Tools: 0 · Received: 10 B",
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, active, "Agent: work"));
    try std.testing.expect(std.mem.find(u8, active, "alpha") == null);
    try std.testing.expect(std.mem.find(u8, active, "βeta") == null);

    rig.time.awake_ms = 7_000;
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    rig.time.awake_ms = 90_000;
    rig.screen.setVerbose(!rig.screen.verbose);
    rig.screen.setVerbose(!rig.screen.verbose);
    const complete = try rig.paintPlain(80);
    defer gpa.free(complete);
    try expectSummary(complete, "Agent: work (complete) · Time: 7s · Tools: 0 · Received: 10 B");
    try testing.expectContains(complete, "answer");

    rig.screen.setVerbose(!rig.screen.verbose);
    const full = try rig.paintPlain(80);
    defer gpa.free(full);
    try testing.expectContains(full, "alpha");
    try testing.expectContains(full, "βeta");
    try std.testing.expect(std.mem.find(u8, full, "Agent: work") == null);
}

test "verbose on adds no rows for thinking without visible text" {
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

test "work reports each terminal outcome and freezes its measurements" {
    const outcomes = [_]core.Session.Outcome{
        .{ .stopped = .complete },
        .canceled,
        .{ .failed = .{ .reason = .empty_reply } },
        .exhausted,
        .{ .stopped = .truncated },
    };
    const statuses = [_][]const u8{ "complete", "canceled", "failed", "failed", "truncated" };
    const colors = [_][]const u8{ "\x1b[32m", "\x1b[33m", "\x1b[31m", "\x1b[31m", "\x1b[33m" };
    for (&outcomes, statuses, colors) |*outcome, status, color| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        rig.screen.setVerbose(!rig.screen.verbose);
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
        const expected = try std.testing.allocator.print(
            "Agent: work ({s}) · Time: 9s · Tools: 0 · Received: 3 B",
            .{status},
        );
        defer std.testing.allocator.free(expected);
        try expectSummary(painted, expected);
        const colored = try std.testing.allocator.print(
            "{s}\x1b[2mAgent: work ({s})\x1b[0m",
            .{ color, status },
        );
        defer std.testing.allocator.free(colored);
        try testing.expectContains(rig.out.written(), colored);
        try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[32;7m") == null);
        try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[31;7m") == null);
        try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[36;7m") == null);
        rig.screen.setVerbose(!rig.screen.verbose);
        const thinking = try rig.paintPlain(80);
        defer std.testing.allocator.free(thinking);
        try testing.expectContains(thinking, "abc");
        try std.testing.expect(std.mem.find(u8, thinking, "Agent: work") == null);
    }
}

test "a retry keeps the failed work summary separate from the new attempt" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
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
    try expectSummary(painted, "Agent: work (failed) · Time: 9s · Tools: 0 · Received: 11 B");
    try expectSummary(painted, "Agent: work (complete) · Time: 2s · Tools: 0 · Received: 3 B");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, painted, "Agent: work"));
}

test "a work row folds thinking and finished calls across steps until agent text ends it" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    const read: core.Tool.Call = .{
        .id = "r1",
        .name = "read",
        .arguments = "{\"path\":\"a.zig\"}",
    };
    const bash: core.Tool.Call = .{
        .id = "b1",
        .name = "bash",
        .arguments = "{\"command\":\"zig build\"}",
    };
    rig.time.awake_ms = 1_000;
    try rig.apply(&.{ .tool_call_started = "read" });
    rig.time.awake_ms = 2_000;
    try rig.apply(&.{ .tool_started = read });
    try rig.apply(&.{ .tool_result = .{ .call = read, .output = .{ .content = "x" } } });
    try rig.apply(&.committed);
    rig.time.awake_ms = 3_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "plan" });
    try rig.apply(&.{ .tool_call_started = "bash" });
    try rig.apply(&.{ .tool_started = bash });
    rig.time.awake_ms = 5_000;
    const running = try rig.paintPlain(80);
    defer gpa.free(running);
    try expectSummary(
        running,
        "Agent: work (bash) · Time: 4s · Tools: 1 · Received: 20 B",
    );
    try std.testing.expect(std.mem.find(u8, running, "Tool:") == null);

    try rig.apply(&.{ .tool_result = .{ .call = bash, .output = .{} } });
    try rig.apply(&.committed);
    rig.time.awake_ms = 6_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "done" });
    rig.time.awake_ms = 8_000;
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    rig.time.awake_ms = 9_000;
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    const complete = try rig.paintPlain(80);
    defer gpa.free(complete);
    try expectSummary(complete, "Agent: work (complete) · Time: 7s · Tools: 2 · Received: 47 B");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, complete, "Agent: work"));
    try std.testing.expect(std.mem.find(u8, complete, "Tool:") == null);
    try testing.expectContains(complete, "answer");

    rig.screen.setVerbose(!rig.screen.verbose);
    const full = try rig.paintPlain(80);
    defer gpa.free(full);
    for ([_][]const u8{ "Tool: read (complete)", "Tool: bash (complete)", "plan", "done" }) |part|
        try testing.expectContains(full, part);
    try std.testing.expect(std.mem.find(u8, full, "Agent: work") == null);
}

test "verbose off names the work that runs now and hides the rows of running calls" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    const idle = try rig.paintPlain(80);
    defer gpa.free(idle);
    try std.testing.expect(std.mem.find(u8, idle, "Agent: work") == null);

    rig.time.awake_ms = 1_000;
    try rig.apply(&.{ .tool_call_started = "read" });
    try rig.apply(&.{ .tool_call_arguments = "{}" });
    try rig.apply(&.{ .tool_call_started = "grep" });
    try rig.apply(&.{ .tool_call_started = "read" });
    rig.time.awake_ms = 3_000;
    const streamed = try rig.paintPlain(80);
    defer gpa.free(streamed);
    try expectSummary(
        streamed,
        "Agent: work (read, grep) · Time: 2s · Tools: 0 · Received: 0 B",
    );
    try std.testing.expect(std.mem.find(u8, streamed, "Tool:") == null);

    const calls = [_]core.Tool.Call{
        .{ .id = "r1", .name = "read", .arguments = "{}" },
        .{ .id = "g1", .name = "grep", .arguments = "{}" },
        .{ .id = "r2", .name = "read", .arguments = "{}" },
    };
    for (&calls) |*call| try rig.apply(&.{ .tool_started = call.* });
    for (&calls) |*call| {
        try rig.apply(&.{ .tool_result = .{ .call = call.*, .output = .{ .content = "x" } } });
    }
    try rig.apply(&.committed);
    rig.time.awake_ms = 4_000;
    const waiting = try rig.paintPlain(80);
    defer gpa.free(waiting);
    try expectSummary(waiting, "Agent: work (waiting) · Time: 3s · Tools: 3 · Received: 6 B");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, waiting, "Agent: work"));

    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "next" });
    const thinking = try rig.paintPlain(80);
    defer gpa.free(thinking);
    try expectSummary(
        thinking,
        "Agent: work (thinking) · Time: 3s · Tools: 3 · Received: 10 B",
    );
    try rig.apply(&.committed);
    const prepared = try rig.paintPlain(80);
    defer gpa.free(prepared);
    try expectSummary(prepared, "Agent: work (waiting) · Time: 3s · Tools: 3 · Received: 10 B");
    try rig.end(&.canceled);
    const canceled = try rig.paintPlain(80);
    defer gpa.free(canceled);
    try expectSummary(canceled, "Agent: work (canceled) · Time: 3s · Tools: 3 · Received: 10 B");
}

test "work activities keep unfinished tools, isolate thinking, and wait between steps" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    const calls = [_]core.Tool.Call{
        .{ .id = "r1", .name = "read", .arguments = "{}" },
        .{ .id = "g1", .name = "grep", .arguments = "{}" },
        .{ .id = "r2", .name = "read", .arguments = "{}" },
    };
    for (&calls) |*call| {
        try rig.apply(&.{ .tool_call_started = call.name });
        try rig.apply(&.{ .tool_call_arguments = call.arguments });
    }
    const streamed = try rig.paintPlain(80);
    defer gpa.free(streamed);
    try expectSummary(streamed, "Agent: work (read, grep) · Time: 0s · Tools: 0 · Received: 0 B");
    try std.testing.expect(std.mem.find(u8, streamed, "Now:") == null);

    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "plan" });
    const thinking = try rig.paintPlain(80);
    defer gpa.free(thinking);
    try expectSummary(thinking, "Agent: work (thinking) · Time: 0s · Tools: 0 · Received: 4 B");
    for (&calls) |*call| try rig.apply(&.{ .tool_started = call.* });
    const running = try rig.paintPlain(80);
    defer gpa.free(running);
    try expectSummary(running, "Agent: work (read, grep) · Time: 0s · Tools: 0 · Received: 4 B");

    for ([_]usize{ 0, 2 }) |index| {
        try rig.apply(&.{ .tool_result = .{ .call = calls[index], .output = .{} } });
        const active = try rig.paintPlain(80);
        defer gpa.free(active);
        try expectSummary(active, if (index == 0)
            "Agent: work (grep, read) · Time: 0s · Tools: 1 · Received: 6 B"
        else
            "Agent: work (grep) · Time: 0s · Tools: 2 · Received: 8 B");
    }
    try rig.apply(&.{ .tool_result = .{ .call = calls[1], .output = .{} } });
    try rig.apply(&.committed);
    rig.time.awake_ms = 1_000;
    const waiting = try rig.paintPlain(80);
    defer gpa.free(waiting);
    try expectSummary(waiting, "Agent: work (waiting) · Time: 1s · Tools: 3 · Received: 10 B");
    try rig.end(&.{ .stopped = .complete });
    const complete = try rig.paintPlain(80);
    defer gpa.free(complete);
    try expectSummary(complete, "Agent: work (complete) · Time: 1s · Tools: 3 · Received: 10 B");
    rig.screen.setVerbose(!rig.screen.verbose);
    const full = try rig.paintPlain(80);
    defer gpa.free(full);
    try testing.expectContains(full, "plan");
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, full, "Tool:"));
}

test "work activities remove optional metrics before truncating inside the parentheses" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    for ([_][]const u8{ "read", "write", "edit", "find", "grep", "bash", "describe_drinky" }) |name|
        try rig.apply(&.{ .tool_call_started = name });
    const identity = "Agent: work (read, write, edit, find, grep, bash, describe_drinky)";
    const cases = [_]struct { columns: usize, expected: []const u8 }{
        .{ .columns = 80, .expected = identity ++ " · Time: 0s" },
        .{ .columns = 66, .expected = identity },
        .{ .columns = 30, .expected = "Agent: work (read, write, ed…)" },
        .{ .columns = 20, .expected = "Agent: work (read,…)" },
        .{ .columns = 15, .expected = "Agent: work (…)" },
        .{ .columns = 14, .expected = "Agent: work (…" },
        .{ .columns = 1, .expected = "…" },
    };
    for (cases) |case| {
        const painted = try rig.paintPlain(case.columns);
        defer gpa.free(painted);
        try expectSummary(painted, case.expected);
        var rows = std.mem.splitScalar(u8, painted, '\n');
        while (rows.next()) |row|
            try std.testing.expect(terminal.width.ofText(std.mem.trimEnd(u8, row, "\r")) <=
                case.columns);
        if (case.columns >= 15)
            try testing.expectContains(rig.out.written(), "\x1b[36m\x1b[2mAgent: work (");
    }
}

test "work activities keep complete Unicode graphemes and the closing parenthesis" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    try rig.apply(&.{ .tool_call_started = "読む👩‍💻" });
    const cases = [_]struct { columns: usize, expected: []const u8 }{
        .{ .columns = 80, .expected = "Agent: work (読む👩‍💻) · Time: 0s · Tools: 0 · Received: 0 B" },
        .{ .columns = 31, .expected = "Agent: work (読む👩‍💻) · Time: 0s" },
        .{ .columns = 20, .expected = "Agent: work (読む👩‍💻)" },
        .{ .columns = 19, .expected = "Agent: work (読む…)" },
        .{ .columns = 18, .expected = "Agent: work (読…)" },
        .{ .columns = 16, .expected = "Agent: work (…)" },
    };
    for (cases) |case| {
        const painted = try rig.paintPlain(case.columns);
        defer gpa.free(painted);
        try expectSummary(painted, case.expected);
        try testing.expectContains(rig.out.written(), "\x1b[36m\x1b[2mAgent: work (");
    }
}

test "work activities keep the closing parenthesis for a single overwide grapheme" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "読", "👩‍💻", "🇩🇪" }) |name| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        rig.screen.setVerbose(!rig.screen.verbose);
        try rig.start("prompt");
        try rig.apply(&.{ .tool_call_started = name });
        const painted = try rig.paintPlain(15);
        defer gpa.free(painted);
        try expectSummary(painted, "Agent: work (…)");
        try testing.expectContains(rig.out.written(), "\x1b[36m\x1b[2m…)");
    }
}

test "an attempt that fails without work closes the committed work row as complete" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    const call: core.Tool.Call = .{ .id = "c1", .name = "read", .arguments = "{}" };
    try rig.apply(&.{ .tool_call_started = "read" });
    try rig.apply(&.{ .tool_started = call });
    try rig.apply(&.{ .tool_result = .{ .call = call, .output = .{ .content = "x" } } });
    try rig.apply(&.committed);
    rig.time.awake_ms = 3_000;
    try rig.apply(&.{ .tail_discarded = 0 });
    try rig.apply(&.{ .attempt_failed = .{
        .attempt = 1,
        .failure = .{ .reason = .overloaded },
        .delay_ms = 0,
    } });
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try expectSummary(painted, "Agent: work (complete) · Time: 3s · Tools: 1 · Received: 2 B");
}

test "agent text, a notice, and a skill note end a work run, and a commit or blank text does not" {
    const call: core.Tool.Call = .{ .id = "c1", .name = "read", .arguments = "{}" };
    const cases = [_]struct { between: []const core.Session.Event, runs: usize }{
        .{ .between = &.{.committed}, .runs = 1 },
        .{ .between = &.{
            .{ .tool_call_started = "read" },
            .{ .tool_started = call },
            .{ .tool_result = .{ .call = call, .output = .{ .content = "x" } } },
        }, .runs = 1 },
        .{ .between = &.{ .text_started, .{ .text = " \n" } }, .runs = 1 },
        .{ .between = &.{ .text_started, .{ .text = "said" } }, .runs = 2 },
        .{ .between = &.{.{ .model_served = .{ .requested = "a", .served = "b" } }}, .runs = 2 },
        .{
            .between = &.{.{ .skill_loaded = .{ .name = "zig-style", .source = "/SKILL.md" } }},
            .runs = 2,
        },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        rig.screen.setVerbose(!rig.screen.verbose);
        try rig.start("prompt");
        try rig.apply(&.reasoning_started);
        try rig.apply(&.{ .reasoning = "a" });
        for (case.between) |*event| try rig.apply(event);
        try rig.apply(&.reasoning_started);
        try rig.apply(&.{ .reasoning = "b" });
        try rig.apply(&.committed);
        try rig.end(&.{ .stopped = .complete });
        const painted = try rig.paintPlain(80);
        defer std.testing.allocator.free(painted);
        try std.testing.expectEqual(case.runs, std.mem.count(u8, painted, "Agent: work"));
    }
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

test "work after a model notice keeps its counter and terminal status" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
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
    try expectSummary(painted, "Agent: work (complete) · Time: 1s · Tools: 0 · Received: 3 B");
    try expectSummary(painted, "Agent: work (canceled) · Time: 2s · Tools: 0 · Received: 4 B");
}

test "a discarded thinking block no longer contributes to its work summary" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "a" });
    rig.time.awake_ms = 2_000;
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "discard" });
    const active = try rig.paintPlain(80);
    defer gpa.free(active);
    try expectSummary(active, "Agent: work (thinking) · Time: 2s · Tools: 0 · Received: 8 B");
    try rig.apply(&.{ .tail_discarded = 1 });
    rig.time.awake_ms = 8_000;
    try rig.end(&.{ .stopped = .complete });
    rig.screen.setVerbose(!rig.screen.verbose);
    rig.screen.setVerbose(!rig.screen.verbose);
    const complete = try rig.paintPlain(80);
    defer gpa.free(complete);
    try expectSummary(complete, "Agent: work (complete) · Time: 8s · Tools: 0 · Received: 1 B");
}

test "a canceled run that drops a streaming call keeps the received bytes of its open row" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setVerbose(!rig.screen.verbose);
    try rig.start("prompt");
    try rig.apply(&.reasoning_started);
    try rig.apply(&.{ .reasoning = "abc" });
    try rig.apply(&.{ .tool_call_started = "read" });
    try rig.apply(&.{ .tool_call_arguments = "{\"path\":\"a\"}" });
    const open = try rig.paintPlain(80);
    defer gpa.free(open);
    try expectSummary(open, "Agent: work (read) · Time: 0s · Tools: 0 · Received: 3 B");
    try rig.apply(&.{ .tail_discarded = 2 });
    try rig.end(&.canceled);
    const canceled = try rig.paintPlain(80);
    defer gpa.free(canceled);
    try expectSummary(canceled, "Agent: work (canceled) · Time: 0s · Tools: 0 · Received: 3 B");
}

test "a tool call streams as a row, runs with its subject and timer, and ends as a block" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("run it");

    try rig.apply(&.{ .tool_call_started = "bash" });
    try rig.apply(&.{ .tool_call_arguments = "{\"command\":" });
    try rig.apply(&.{ .tool_call_arguments = "\"zig build\"}" });
    const streamed = try rig.paintPlain(80);
    defer gpa.free(streamed);
    try testing.expectContains(streamed, "Tool: bash (streaming) · Received: 23 B");

    rig.time.awake_ms = 1_000;
    try rig.apply(&.{ .tool_started = .{
        .id = "c1",
        .name = "bash",
        .arguments = "{\"command\":\"zig build\"}",
    } });
    rig.time.awake_ms = 13_400;
    const running = try rig.paintPlain(80);
    defer gpa.free(running);
    try testing.expectContains(running, "Tool: bash (running) · Time: 12s · Timeout: 2m 0s");
    try testing.expectContains(running, "\r\n$ zig build");

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
        "Tool: bash (complete) · Time: 1.5s · Exit code: 0 · Lines: 1\nzig build",
        block.text.items,
    );
    try std.testing.expect(block.status.role == .success);
    const done = try rig.paintPlain(80);
    defer gpa.free(done);
    try std.testing.expect(std.mem.find(u8, done, "(streaming)") == null);

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
        "Tool: read (failed) · File: a.txt\nError: " ++ sentence,
        block.text.items,
    );
    try std.testing.expect(block.status.role == .@"error");

    try rig.apply(&.{ .tool_call_started = "describe_drinky" });
    const describe: core.Tool.Call = .{ .id = "c2", .name = "describe_drinky", .arguments = "{}" };
    try rig.apply(&.{ .tool_started = describe });
    try rig.apply(&.{ .tool_result = .{ .call = describe, .output = .{ .content = "# Drinky" } } });
    try std.testing.expectEqualStrings(
        "Tool: describe_drinky (complete)",
        rig.blocks()[2].content.tool_result.text.items,
    );
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
}

test "pending and completed calls keep the draft and show the command in the gutter" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.screen.setDraft("draft");
    try rig.start("prompt");
    const call: core.Tool.Call = .{
        .id = "bash",
        .name = "bash",
        .arguments = "{\"command\":\"git diff --check\\n  second\\n\\nlast-line\"}",
    };
    try rig.apply(&.{ .tool_call_started = call.name });
    try rig.apply(&.{ .tool_started = call });
    for (0..2) |stage| {
        const painted = try rig.paintPlain(40);
        defer gpa.free(painted);
        try testing.expectContains(painted, "\r\n$ git diff --check");
        try testing.expectContains(painted, "\r\n  last-line");
        rig.screen.setVerbose(!rig.screen.verbose);
        rig.screen.setVerbose(!rig.screen.verbose);
        const draft = try rig.screen.editor.expanded();
        defer gpa.free(draft);
        try std.testing.expectEqualStrings("draft", draft);
        if (stage == 0) {
            try std.testing.expect(rig.screen.widget == .turn);
            try rig.apply(&.{ .tool_result = .{ .call = call, .output = .{} } });
            try rig.apply(&.committed);
            try rig.end(&.{ .stopped = .complete });
        }
    }
}

test "verbose off hides each command, and verbose on keeps its complete text" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { arguments: []const u8, hidden: []const u8 }{
        .{
            .arguments = "{\"command\":\"echo abcdefghijklmnopqrstuvwxyz0123456789\"}",
            .hidden = "rstuvwxyz0123456789",
        },
        .{
            .arguments = "{\"command\":\"echo first\\nError: command text\\nlast-line\\n\"}",
            .hidden = "last-line",
        },
        .{
            .arguments = "{\"command\":\"echo 你好\\r\\nlast-line\"}",
            .hidden = "last-line",
        },
    };
    const sentence = "Drinky could not run the command because of error AccessDenied.";
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        rig.screen.setVerbose(!rig.screen.verbose);
        try rig.start("prompt");
        try rig.apply(&.{ .tool_call_started = "bash" });
        const call: core.Tool.Call = .{
            .id = "bash",
            .name = "bash",
            .arguments = case.arguments,
        };
        try rig.apply(&.{ .tool_started = call });
        const running = try rig.paintPlain(80);
        defer gpa.free(running);
        try expectSummary(running, "Agent: work (bash) · Time: 0s · Tools: 0 · Received: 0 B");
        try std.testing.expect(std.mem.find(u8, running, "$ echo") == null);
        try std.testing.expect(std.mem.find(u8, running, case.hidden) == null);

        var output: core.Tool.Output = .{ .content = sentence };
        output.conditions.insert(.failed);
        try rig.apply(&.{ .tool_result = .{ .call = call, .output = output } });
        try rig.apply(&.committed);
        try rig.end(&.{ .stopped = .complete });
        const complete = try rig.paintPlain(56);
        defer gpa.free(complete);
        try testing.expectContains(complete, "Agent: work (complete)");
        try std.testing.expect(std.mem.find(u8, complete, "$ echo") == null);
        try std.testing.expect(std.mem.find(u8, complete, "Error:") == null);

        rig.screen.setVerbose(!rig.screen.verbose);
        const full = try rig.paintPlain(100);
        defer gpa.free(full);
        try testing.expectContains(full, case.hidden);
        try testing.expectContains(full, sentence);
        try std.testing.expect(std.mem.find(u8, full, "…") == null);
        try testing.expectContains(rig.out.written(), "\x1b[31m\x1b[2mTool: bash (failed)");
        try testing.expectContains(rig.out.written(), "\x1b[2;39m$ echo");
        try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[7m") == null);
        if (std.mem.find(u8, case.arguments, "Error:") != null)
            try testing.expectContains(rig.out.written(), "\x1b[2;39m  Error: command text");
        try testing.expectContains(rig.out.written(), "\x1b[0m\r\n\x1b[2;39mError: Drinky");

        rig.screen.setVerbose(!rig.screen.verbose);
        const restored = try rig.paintPlain(56);
        defer gpa.free(restored);
        try testing.expectContains(restored, "Agent: work (complete)");
        try std.testing.expect(std.mem.find(u8, restored, "$ echo") == null);
    }
}

test "verbose tools color each identity by its status and mark search limits in yellow" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        name: []const u8,
        conditions: []const core.Tool.Condition = &.{},
        measures: []const struct { core.Tool.Measure, u64 } = &.{},
        status: []const u8 = "complete",
        qualifier: []const u8,
        warning: bool = false,
    }{
        .{
            .name = "read",
            .measures = &.{ .{ .lines, 50 }, .{ .line_first, 1 }, .{ .lines_total, 300 } },
            .qualifier = "Lines: 1–50 of 300",
        },
        .{
            .name = "bash",
            .conditions = &.{.output_truncated},
            .measures = &.{ .{ .exit_code, 0 }, .{ .lines, 3 } },
            .qualifier = "Output: truncated",
        },
        .{ .name = "read", .conditions = &.{.line_truncated}, .qualifier = "Line: truncated" },
        .{ .name = "grep", .conditions = &.{.lines_truncated}, .qualifier = "Lines: truncated" },
        .{
            .name = "find",
            .measures = &.{ .{ .matches, 1 }, .{ .matches_omitted, 2 } },
            .qualifier = "Omitted matches: 2",
        },
        .{
            .name = "grep",
            .conditions = &.{.incomplete},
            .measures = &.{.{ .entries_unread, 2 }},
            .status = "partial",
            .qualifier = "Unreadable: 2 entries",
            .warning = true,
        },
        .{
            .name = "find",
            .conditions = &.{.time_limit_reached},
            .status = "partial",
            .qualifier = "Stopped: time limit",
            .warning = true,
        },
        .{
            .name = "grep",
            .conditions = &.{.match_limit_reached},
            .status = "partial",
            .qualifier = "Stopped: match limit",
            .warning = true,
        },
        .{
            .name = "grep",
            .conditions = &.{.byte_limit_reached},
            .status = "partial",
            .qualifier = "Stopped: byte limit",
            .warning = true,
        },
        .{
            .name = "grep",
            .conditions = &.{
                .time_limit_reached,
                .match_limit_reached,
                .byte_limit_reached,
                .incomplete,
            },
            .status = "partial",
            .qualifier = "Stopped: time limit, byte limit, match limit",
            .warning = true,
        },
        .{
            .name = "bash",
            .conditions = &.{.failed},
            .measures = &.{.{ .exit_code, 2 }},
            .status = "failed",
            .qualifier = "Exit code: 2",
        },
        .{
            .name = "grep",
            .conditions = &.{ .failed, .incomplete },
            .measures = &.{ .{ .matches, 0 }, .{ .entries_unread, 1 } },
            .status = "failed",
            .qualifier = "Unreadable: 1 entry",
            .warning = true,
        },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        try rig.start("prompt");
        const call: core.Tool.Call = .{ .id = "c1", .name = case.name, .arguments = "{}" };
        try rig.apply(&.{ .tool_call_started = call.name });
        try rig.apply(&.{ .tool_started = call });
        var output: core.Tool.Output = .{};
        for (case.conditions) |condition| output.conditions.insert(condition);
        for (case.measures) |measure| output.measures.put(measure[0], measure[1]);
        try rig.apply(&.{ .tool_result = .{ .call = call, .output = output } });
        try rig.apply(&.committed);
        try rig.end(&.{ .stopped = .complete });
        const partial = std.mem.eql(u8, case.status, "partial");
        const color = if (std.mem.eql(u8, case.status, "failed"))
            "\x1b[31m"
        else if (partial) "\x1b[33m" else "\x1b[32m";
        for ([_]usize{ 120, 8, 1, 120 }) |columns| {
            const plain = try rig.paintPlain(columns);
            defer gpa.free(plain);
            if (columns <= 8) {
                const shortened = try gpa.print("{s}\x1b[2m{s}", .{
                    color,
                    if (columns == 1) "…" else "Tool:",
                });
                defer gpa.free(shortened);
                try testing.expectContains(rig.out.written(), shortened);
                if (!partial)
                    try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[33m") == null);
                continue;
            }
            const identity = try gpa.print("Tool: {s} ({s})", .{ case.name, case.status });
            defer gpa.free(identity);
            try testing.expectContains(plain, identity);
            try testing.expectContains(plain, case.qualifier);
            const colored = try gpa.print("{s}\x1b[2m{s}\x1b[0m", .{ color, identity });
            defer gpa.free(colored);
            try testing.expectContains(rig.out.written(), colored);
            if (case.warning) {
                const qualifier = try gpa.print("\x1b[33m\x1b[2m{s}", .{case.qualifier});
                defer gpa.free(qualifier);
                try testing.expectContains(rig.out.written(), qualifier);
            } else try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[33m") == null);
        }
    }
}

test "tool results keep file metadata neutral across terminal widths" {
    const cases = [_]struct {
        condition: ?core.Tool.Condition,
        state: []const u8,
        color: []const u8,
    }{
        .{ .condition = null, .state = "complete", .color = "\x1b[32m" },
        .{ .condition = .incomplete, .state = "partial", .color = "\x1b[33m" },
        .{ .condition = .failed, .state = "failed", .color = "\x1b[31m" },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        try rig.start("prompt");
        try rig.apply(&.{ .tool_call_started = "read" });
        const call: core.Tool.Call = .{
            .id = "read",
            .name = "read",
            .arguments = "{\"path\":\"a.zig\"}",
        };
        try rig.apply(&.{ .tool_started = call });
        var output: core.Tool.Output = .{};
        output.measures.put(.lines, 1);
        if (case.condition) |condition| output.conditions.insert(condition);
        try rig.apply(&.{ .tool_result = .{ .call = call, .output = output } });
        try rig.apply(&.committed);
        try rig.end(&.{ .stopped = .complete });
        const plain = try rig.paintPlain(80);
        defer std.testing.allocator.free(plain);
        const identity = try std.testing.allocator.print(
            "{s}\x1b[2mTool: read ({s})\x1b[0m",
            .{ case.color, case.state },
        );
        defer std.testing.allocator.free(identity);
        try testing.expectContains(rig.out.written(), identity);
        try testing.expectContains(rig.out.written(), "\x1b[2;39m · File: a.zig");
        try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[32;7m") == null);
        try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[31;7m") == null);

        const narrow = try rig.paintPlain(1);
        defer std.testing.allocator.free(narrow);
        const ellipsis = try std.testing.allocator.print("{s}\x1b[2m…", .{case.color});
        defer std.testing.allocator.free(ellipsis);
        try testing.expectContains(rig.out.written(), ellipsis);
    }
}

test "active calls color their complete identities" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("prompt");
    try rig.apply(&.{ .tool_call_started = "read" });
    try rig.apply(&.{ .tool_call_arguments = "{}" });
    try rig.apply(&.{ .tool_call_started = "write" });
    const queued = try rig.paintPlain(80);
    defer std.testing.allocator.free(queued);
    try testing.expectContains(rig.out.written(), "\x1b[36m\x1b[2mTool: read (queued)\x1b[0m");
    try testing.expectContains(rig.out.written(), "\x1b[36m\x1b[2mTool: write (streaming)\x1b[0m");
    try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[36;7m") == null);
    try rig.apply(&.{ .tool_started = .{ .id = "read", .name = "read", .arguments = "{}" } });
    const running = try rig.paintPlain(80);
    defer std.testing.allocator.free(running);
    try testing.expectContains(rig.out.written(), "\x1b[36m\x1b[2mTool: read (running)\x1b[0m");
    try std.testing.expect(std.mem.find(u8, rig.out.written(), "\x1b[36;7m") == null);
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
    try testing.expectContains(two, "Tool: read (queued) · Received: 2 B");
    try testing.expectContains(two, "Tool: write (streaming) · Received: 0 B");

    try rig.apply(&.{ .tool_started = .{ .id = "c1", .name = "read", .arguments = "{}" } });
    const one = try rig.paintPlain(80);
    defer gpa.free(one);
    try testing.expectContains(one, "Tool: read (running) · Time: 0s · Timeout: 10s");
    try std.testing.expect(std.mem.find(u8, one, "Received: 2 B") == null);
    try testing.expectContains(one, "Tool: write (queued) · Received: 0 B");
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
    for ([_]bool{ true, false }) |verbose| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        if (!verbose) rig.screen.setVerbose(!rig.screen.verbose);
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
        try testing.expectContains(painted, if (verbose) "Tool: write" else "Tools: 1 ·");
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
    try std.testing.expectEqualStrings(testing.truncated_text, rig.eventText(1));
    try std.testing.expectEqual(.failure, rig.blocks()[1].content.event.severity);

    try rig.start("b");
    try rig.end(&.exhausted);
    try std.testing.expectEqualStrings(
        "The turn reached the limit for tool rounds.",
        rig.eventText(3),
    );

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
    try rig.choose(&.{
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
    try std.testing.expectEqual(@as(f64, 12), reported.quota.?.windows.primary.?.used_percent);
    try std.testing.expectEqual(@as(f64, 10), reported.credits.?.total);
    try rig.end(&.{ .stopped = .complete });
    try std.testing.expectEqualStrings("anthropic-plan", rig.screen.statusInfo(0).account.?);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", rig.screen.statusInfo(0).model.?);
    try std.testing.expect(rig.screen.statusInfo(0).quota != null);

    try rig.choose(&.{ .account = accounts.testing.openai_api_key, .effort = .high });
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
    try rig.choose(&.{
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

test "a child charge changes only the session cost and adds no transcript block" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.{ .context = 123 });
    try rig.apply(&.{ .usage = .{ .input = 10, .cache_read = 90 } });
    try rig.apply(&.text_started);
    try rig.apply(&.{ .text = "answer" });
    const before = rig.screen.statusInfo(0);
    const count = rig.blocks().len;

    try rig.apply(&.{ .cost = 2.5 });
    const after = rig.screen.statusInfo(0);
    try std.testing.expectApproxEqAbs(before.cost + 2.5, after.cost, 1e-9);
    try std.testing.expectEqual(before.context_tokens, after.context_tokens);
    try std.testing.expectEqualDeep(before.cache_usage, after.cache_usage);
    try std.testing.expectEqualStrings(before.model.?, after.model.?);
    try std.testing.expectEqual(count, rig.blocks().len);
    try rig.apply(&.committed);
    try rig.end(&.canceled);
    try std.testing.expectApproxEqAbs(after.cost, rig.screen.statusInfo(0).cost, 1e-9);
    try rig.apply(&.{ .cost = core.Provider.amount_usd_max });
    try std.testing.expectEqual(core.Provider.amount_usd_max, rig.screen.statusInfo(0).cost);
}

test "a reported charge does not require model prices or a selected model" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.choose(&.{ .effort = .high });
    try rig.apply(&.{ .usage = .{ .cost_usd = 0.42 } });
    try std.testing.expectApproxEqAbs(@as(f64, 0.42), rig.screen.statusInfo(0).cost, 1e-9);
}

test "a finished attempt adds its cost before tools and charges it only once" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.{ .usage = .{ .input = 1_000_000 } });
    try std.testing.expectApproxEqAbs(@as(f64, 3), rig.screen.statusInfo(0).cost, 1e-9);
    try rig.apply(&.committed);
    try rig.end(&.canceled);
    try std.testing.expectApproxEqAbs(@as(f64, 3), rig.screen.statusInfo(0).cost, 1e-9);
}

test "a usage between turns adds its cost at once and keeps the cache figure of the last turn" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.start("hi");
    try rig.apply(&.{ .usage = .{ .input = 10, .cache_read = 90 } });
    try rig.apply(&.committed);
    try rig.end(&.{ .stopped = .complete });
    const cost = rig.screen.statusInfo(0).cost;

    try rig.apply(&.{ .usage = .{ .input = 1_000_000 } });
    const info = rig.screen.statusInfo(0);
    try std.testing.expectApproxEqAbs(cost + 3, info.cost, 1e-9);
    try std.testing.expectEqual(@as(u64, 90), info.cache_usage.cache_read);
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

    try rig.choose(&.{ .account = accounts.testing.openai_api_key, .effort = .high });
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

test "the authorization record renders its URL with a device code or a callback hint" {
    const cases = [_]struct { code: ?[]const u8, text: []const u8 }{
        .{
            .code = "ABCD-1234",
            .text = "Open this URL to authorize the sign-in to openai-plan:\n\n" ++
                "https://auth.example/device\n\nEnter this code if the page asks for one: " ++
                "ABCD-1234",
        },
        .{
            .code = null,
            .text = "Open this URL to authorize the sign-in to openai-plan:\n\n" ++
                "https://auth.example/device\n\nIf the browser shows an error, paste the " ++
                "callback URL from its address bar and press Enter.",
        },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        try rig.screen.applyChange(&.{ .append_record = &.{
            .id = 7,
            .content = .{ .authorization = .{
                .account = accounts.testing.openai_plan,
                .url = "https://auth.example/device",
                .code = case.code,
            } },
        } });
        const block = rig.blocks()[0];
        try std.testing.expectEqual(@as(?u64, 7), block.record_id);
        try std.testing.expectEqual(.information, block.content.event.severity);
        try std.testing.expectEqualStrings(case.text, block.content.event.text.items);
    }
}

test "a notice replaces its predecessor, and a turn end drops it" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    rig.screen.setNotice(
        try ui.Message.print(std.testing.allocator, .information, "First.", .{}),
    );
    rig.screen.setNotice(
        try ui.Message.print(std.testing.allocator, .failure, "Second.", .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), rig.blocks().len);
    try std.testing.expectEqualStrings("Second.", rig.screen.notice.?.content);
    try std.testing.expectEqual(ui.Message.Severity.failure, rig.screen.notice.?.severity);

    try rig.start("hi");
    rig.screen.setNotice(
        try ui.Message.print(std.testing.allocator, .warning, "Turn notice.", .{}),
    );
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

    rig.reduction.surface.clearConversation();
    try rig.forward();
    try rig.expectKinds(&.{.intro});
    try std.testing.expectEqual(@as(f64, 0), rig.screen.statusInfo(0).cost);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", rig.screen.statusInfo(0).model.?);
}

test "a picker displays public options and waits with animation" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const options = [_]ui.Picker.Option{.{ .name = "row" }};
    try rig.screen.openPicker(&.{ .title = "Step", .options = &options, .depth = 1 });
    try std.testing.expect(!rig.screen.animating());
    try rig.screen.beginPickerWait(Flow.fetch_wait_text);
    try std.testing.expect(rig.screen.animating());
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try testing.expectContains(painted, "Drinky fetches");
    try std.testing.expect(std.mem.find(u8, painted, "> row") == null);
    try rig.screen.openPicker(&.{ .title = "Step", .options = &options });
    try std.testing.expect(!rig.screen.animating());
    rig.screen.closePicker();
    try std.testing.expect(rig.screen.widget == .prompt);
}

test "a picker opening releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkPickerOpening,
        .{},
    );
}

fn checkPickerOpening(gpa: std.mem.Allocator) !void {
    var rig: Rig = undefined;
    rig.initWith(gpa, null);
    defer rig.deinit();
    const options = [_]ui.Picker.Option{
        .{ .name = "first", .extra = "Extra.", .tag = "Set" },
        .{ .name = "second" },
    };
    try rig.screen.openPicker(&.{ .title = "Step", .options = &options, .current = 0 });
    try rig.screen.openPicker(&.{ .title = "Child", .options = options[1..], .depth = 1 });
}

test "a picker wait keeps its text after the event text is gone and the next paint composes it" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const options = [_]ui.Picker.Option{.{ .name = "row" }};
    try rig.screen.openPicker(&.{ .title = "Step", .options = &options });
    const text = try gpa.dupe(u8, Flow.fetch_wait_text);
    try rig.screen.beginPickerWait(text);
    @memset(text, 'x');
    gpa.free(text);
    const painted = try rig.paintPlain(60);
    defer gpa.free(painted);
    try testing.expectContains(painted, Flow.fetch_wait_text);
}

test "a waiting page ticks its time, counts reasoning bytes, adds a note, and stops at text" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    try rig.showResult(&.{
        .id = 1,
        .purpose = .short_answer,
        .text = "",
        .phase = .{ .generating = .{ .started_ms = 1_000 } },
    });
    rig.time.awake_ms = 1_000;
    try std.testing.expect(rig.screen.animating());
    const waiting = try rig.paintPlain(80);
    defer gpa.free(waiting);
    try testing.expectContains(waiting, "Agent: work (waiting) · Time: 0s · Received: 0 B");
    try std.testing.expect(!rig.screen.advanceFrame(1_999));
    try std.testing.expect(rig.screen.advanceFrame(3_000));

    rig.time.awake_ms = 3_000;
    try rig.showResult(&.{
        .id = 1,
        .purpose = .short_answer,
        .text = "",
        .phase = .{ .generating = .{
            .started_ms = 1_000,
            .received_bytes = 2048,
            .thinking = true,
            .retry = overloaded_attempt,
        } },
    });
    const thinking = try rig.paintPlain(80);
    defer gpa.free(thinking);
    try testing.expectContains(thinking, "Agent: work (thinking) · Time: 2s · Received: 2.0 KiB");
    try testing.expectContains(thinking, "Attempt 1 failed.");

    try rig.screen.activePage().?.append("Handoff.");
    try std.testing.expect(!rig.screen.animating());
    try std.testing.expect(!rig.screen.advanceFrame(9_000));
    const answered = try rig.paintPlain(80);
    defer gpa.free(answered);
    try testing.expectContains(answered, "Handoff.");
    try std.testing.expect(std.mem.find(u8, answered, "Agent: work") == null);
    rig.screen.closePage();
}

test "page wait lines keep one adaptive row with the transcript work style" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { columns: usize, waiting: []const u8, thinking: []const u8 }{
        .{
            .columns = 80,
            .waiting = "Agent: work (waiting) · Time: 0s · Received: 0 B",
            .thinking = "Agent: work (thinking) · Time: 0s · Received: 2.0 KiB",
        },
        .{
            .columns = 40,
            .waiting = "Agent: work (waiting) · Time: 0s",
            .thinking = "Agent: work (thinking) · Time: 0s",
        },
        .{
            .columns = 30,
            .waiting = "Agent: work (waiting)",
            .thinking = "Agent: work (thinking)",
        },
        .{ .columns = 20, .waiting = "Agent: work (waiti…)", .thinking = "Agent: work (think…)" },
        .{ .columns = 15, .waiting = "Agent: work (…)", .thinking = "Agent: work (…)" },
        .{ .columns = 14, .waiting = "Agent: work (…", .thinking = "Agent: work (…" },
        .{ .columns = 1, .waiting = "…", .thinking = "…" },
    };
    for ([_]ui.Page.Presentation{ .markdown, .source }) |presentation| {
        for (cases) |case| {
            for ([_]bool{ false, true }) |thinking| {
                var rig: Rig = undefined;
                rig.init();
                defer rig.deinit();
                try rig.showResult(&.{
                    .id = 1,
                    .purpose = .short_answer,
                    .text = "",
                    .phase = .{ .generating = .{
                        .started_ms = 0,
                        .received_bytes = if (thinking) 2048 else 0,
                        .thinking = thinking,
                    } },
                });
                if (presentation == .source) rig.screen.activePage().?.toggleSource(.{
                    .columns = case.columns,
                    .rows = 24,
                });
                const plain = try rig.paintPlain(case.columns);
                defer gpa.free(plain);
                const expected = if (thinking) case.thinking else case.waiting;
                try expectSummary(plain, expected);
                try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, plain, "\r\n"));
                const colored = try gpa.print(
                    "\x1b[36m\x1b[2m{s}",
                    .{expected[0..@min(expected.len, "Agent: work (".len)]},
                );
                defer gpa.free(colored);
                try testing.expectContains(rig.out.written(), colored);
                if (case.columns >= 40)
                    try testing.expectContains(rig.out.written(), "\x1b[2;39m · Time: 0s");
            }
        }
    }
}

test "page retry notes use the transcript information symbol and color in both presentations" {
    const gpa = std.testing.allocator;
    for ([_]ui.Page.Presentation{ .markdown, .source }) |presentation| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        try rig.showResult(&.{
            .id = 1,
            .purpose = .short_answer,
            .text = "",
            .phase = .{ .generating = .{
                .started_ms = 0,
                .retry = .{
                    .attempt = 1,
                    .reason = .overloaded,
                    .details = "**down**",
                    .delay_ms = 0,
                },
            } },
        });
        if (presentation == .source)
            rig.screen.activePage().?.toggleSource(.{ .columns = 80, .rows = 24 });
        const plain = try rig.paintPlain(80);
        defer gpa.free(plain);
        try testing.expectContains(rig.out.written(), "\x1b[22;36mℹ Attempt 1 failed.");
        try testing.expectContains(plain, "**down**");
        try rig.screen.activePage().?.append("Answer");
        const answer = try rig.paintPlain(80);
        defer gpa.free(answer);
        try testing.expectContains(answer, "Answer");
        try std.testing.expect(std.mem.find(u8, answer, "Attempt 1 failed.") == null);
    }
}

test "a result that completes without text ends its wait line" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var emulator = try terminal.testing.Emulator.init(gpa, 80);
    defer emulator.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 6 };
    emulator.resize(size.rows);
    try rig.showResult(&.{
        .id = 1,
        .purpose = .short_answer,
        .text = "",
        .phase = .{ .generating = .{ .started_ms = 0 } },
    });
    try rig.paintInto(&emulator, size);
    try expectBodyRows(&emulator, &.{"Agent: work (waiting) · Time: 0s · Received: 0 B"});
    try rig.showResult(&.{ .id = 1, .purpose = .short_answer, .phase = .complete, .text = "" });
    try std.testing.expect(!rig.screen.animating());
    try rig.paintInto(&emulator, size);
    try expectBodyRows(&emulator, &.{""});
}

test "a tick of the wait line keeps the scroll position, and a new note returns to the top" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var emulator = try terminal.testing.Emulator.init(gpa, 80);
    defer emulator.deinit();
    const size: terminal.View.Size = .{ .columns = 80, .rows = 4 };
    emulator.resize(size.rows);
    try rig.showResult(&.{
        .id = 1,
        .purpose = .short_answer,
        .text = "",
        .phase = .{ .generating = .{ .started_ms = 0 } },
    });
    try rig.setRetry("N1\nN2\nN3");
    try rig.paintInto(&emulator, size);
    rig.screen.activePage().?.moveDown(size);
    try rig.paintInto(&emulator, size);
    try expectBodyRows(&emulator, &.{ "ℹ N1", "N2" });

    rig.time.awake_ms = 1_000;
    try rig.paintInto(&emulator, size);
    try expectBodyRows(&emulator, &.{ "ℹ N1", "N2" });

    try rig.setRetry("M1");
    try rig.paintInto(&emulator, size);
    try expectBodyRows(&emulator, &.{ "Agent: work (waiting) · Time: 1s · Received: 0 B", "ℹ M1" });
    rig.screen.closePage();
}

fn expectBodyRows(emulator: *const terminal.testing.Emulator, expected: []const []const u8) !void {
    const body_top = emulator.screen_top + 2;
    for (expected, body_top..) |row, index| {
        try std.testing.expectEqualStrings(row, std.mem.trimEnd(
            u8,
            emulator.document.items[index].items,
            " ",
        ));
    }
}

test "a step back restores the scroll row of the parent picker" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var names: [40][5]u8 = undefined;
    var options: [40]ui.Picker.Option = undefined;
    for (&options, &names, 0..) |*option, *name, index|
        option.* = .{ .name = try std.fmt.bufPrint(name, "row{d:0>2}", .{index}) };
    try rig.screen.openPicker(&.{ .title = "Parent", .options = &options });
    for (0..30) |_| try rig.screen.activePicker().?.moveDown();
    gpa.free(try rig.paintPlain(80));
    for (0..10) |_| try rig.screen.activePicker().?.moveUp();
    gpa.free(try rig.paintPlain(80));
    const scroll = rig.screen.activePicker().?.window.scroll;
    try std.testing.expect(scroll > 0);
    try rig.screen.openPicker(&.{ .title = "Child", .options = options[0..2], .depth = 1 });
    try rig.screen.openPicker(&.{ .title = "Parent", .options = &options, .cursor = 20 });
    gpa.free(try rig.paintPlain(80));
    try std.testing.expectEqual(scroll, rig.screen.activePicker().?.window.scroll);
}

test "a picker position restores the selected row" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const options = [_]ui.Picker.Option{
        .{ .name = "first" },
        .{ .name = "second" },
        .{ .name = "third" },
    };
    try rig.screen.openPicker(&.{ .title = "Step", .options = &options, .cursor = 2 });
    const painted = try rig.paintPlain(80);
    defer gpa.free(painted);
    try testing.expectContains(painted, "> third");
    try rig.screen.openPicker(&.{ .title = "Step", .options = &options });
    try std.testing.expectEqual(@as(usize, 0), rig.screen.activePicker().?.cursor);
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

test "snapshot restoration releases every partial allocation and keeps the draft" {
    var controller: application.testing.Rig = undefined;
    try controller.init(&.{});
    defer controller.deinit();
    const initial = try controller.snapshot();
    defer initial.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkSnapshotRestore,
        .{&initial},
    );
}

fn checkSnapshotRestore(gpa: std.mem.Allocator, snapshot: *const application.Snapshot) !void {
    var rig: Rig = undefined;
    rig.initWith(gpa, null);
    defer rig.deinit();
    const screen = &rig.screen;
    try rig.addUser("Kept user message.");
    try screen.setDraft("Kept draft.");
    screen.verbose = true;
    screen.window_pages = application.Settings.window_pages_min;
    try screen.restore(snapshot);
    try std.testing.expectEqualStrings("Kept draft.", screen.editor.visible());
    try std.testing.expect(screen.verbose);
    try std.testing.expectEqual(snapshot.settings.window_pages, screen.window_pages);
}

test "a snapshot keeps a local picker with its position and its wait" {
    var names: [20][8]u8 = undefined;
    var options: [names.len]ui.Picker.Option = undefined;
    for (&names, &options, 0..) |*buffer, *option, index| {
        option.* = .{ .name = try std.mem.print(buffer, "row{d:0>2}", .{index}) };
    }
    const snapshot: application.Snapshot = .{
        .records = &.{},
        .statistics = .{},
        .state = .{ .choice = .{ .effort = .high } },
        .working_directory = "/work",
        .home_directory = "/home",
    };
    for ([_]usize{ 24, 80 }) |columns| {
        var rig: Rig = undefined;
        rig.init();
        defer rig.deinit();
        const size: terminal.View.Size = .{ .columns = columns, .rows = 8 };
        try rig.screen.openPicker(&.{ .title = "Pick", .options = &options, .preselected = 2 });
        for (2..names.len - 1) |_| try rig.screen.activePicker().?.moveDown();
        try rig.screen.paint(size, rig.time, &no_caption);
        const scroll = rig.screen.activePicker().?.window.scroll;
        try std.testing.expect(scroll > 0);
        try rig.screen.restore(&snapshot);
        try std.testing.expectEqual(names.len - 1, rig.screen.activePicker().?.cursor);
        try rig.screen.paint(size, rig.time, &no_caption);
        try std.testing.expectEqual(scroll, rig.screen.activePicker().?.window.scroll);
        try testing.expectContains(rig.screen.activePicker().?.content.items, " > row19");
        try rig.screen.beginPickerWait(Flow.fetch_wait_text);
        try rig.screen.restore(&snapshot);
        try std.testing.expect(rig.screen.animating());
        const painted = try rig.paintPlain(columns);
        defer std.testing.allocator.free(painted);
        try testing.expectContains(painted, "Drinky fetches");
    }
}

test "page snapshots keep the source position and start new content at its first row" {
    const snapshot: application.Snapshot = .{
        .records = &.{},
        .statistics = .{},
        .state = .{
            .result = .{
                .id = 1,
                .purpose = .short_answer,
                .phase = .complete,
                .text = application.support.repeat(
                    "# Heading\n\nA long paragraph with **bold text**.\n\n",
                    40,
                ),
            },
            .choice = .{ .effort = .high },
        },
        .working_directory = "/work",
        .home_directory = "/home",
    };
    for (std.enums.values(ui.Page.Presentation)) |presentation| {
        for ([_]usize{ 24, 80 }) |columns| {
            var rig: Rig = undefined;
            rig.init();
            defer rig.deinit();
            const size: terminal.View.Size = .{ .columns = columns, .rows = 24 };
            try rig.screen.restore(&snapshot);
            try rig.screen.paint(size, rig.time, &no_caption);
            const page = rig.screen.activePage().?;
            if (presentation == .source) page.toggleSource(size);
            page.moveEnd(size);
            const scroll = page.scroll;
            try std.testing.expect(scroll > 0);
            try rig.screen.restore(&snapshot);
            try rig.screen.paint(size, rig.time, &no_caption);
            try std.testing.expectEqual(presentation, rig.screen.activePage().?.presentation);
            try std.testing.expectEqual(scroll, rig.screen.activePage().?.scroll);
            const resized: terminal.View.Size = .{
                .columns = if (columns == 24) 80 else 24,
                .rows = size.rows,
            };
            const restored = rig.screen.activePage().?;
            restored.reflow(resized);
            const resized_scroll = restored.scroll;
            restored.reflow(size);
            try rig.screen.restore(&snapshot);
            try rig.screen.paint(resized, rig.time, &no_caption);
            try std.testing.expectEqual(resized_scroll, rig.screen.activePage().?.scroll);
        }
    }
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var waiting = snapshot;
    waiting.state.result.?.text = "";
    waiting.state.result.?.phase = .{ .generating = .{
        .started_ms = 0,
        .retry = .{
            .attempt = 1,
            .reason = .overloaded,
            .details = application.support.repeat("The attempt failed. ", 100),
            .delay_ms = 0,
        },
    } };
    const size: terminal.View.Size = .{ .columns = 24, .rows = 24 };
    try rig.screen.restore(&waiting);
    try rig.screen.paint(size, rig.time, &no_caption);
    rig.screen.activePage().?.moveEnd(size);
    try std.testing.expect(rig.screen.activePage().?.scroll > 0);
    try rig.screen.restore(&snapshot);
    try rig.screen.paint(size, rig.time, &no_caption);
    try std.testing.expectEqual(@as(usize, 0), rig.screen.activePage().?.scroll);
}

test "a streaming snapshot continues the current text record after restoration" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var transport: application.testing.StreamTransport = .{
        .prefix = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\"" ++
            ",\"delta\":\"partial\"}\n\n",
        .tail = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\"" ++
            ",\"delta\":\" answer\"}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"" ++
            "m1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"" ++
            "type\":\"output_text\",\"text\":\"partial answer\"}]}}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
    };
    var controller: application.testing.Rig = undefined;
    try controller.init(&.{ .transport = transport.transport() });
    defer controller.deinit();
    defer transport.released.set(std.testing.io);
    const initial = try controller.snapshot();
    initial.deinit(gpa);
    _ = controller.send(&.{ .send_message = "Task." });
    try transport.reached.wait(std.testing.io);
    const snapshot = try controller.snapshot();
    defer snapshot.deinit(gpa);
    try rig.screen.restore(&snapshot);
    transport.released.set(std.testing.io);
    for (0..4096) |_| {
        const event = try controller.next();
        defer event.deinit(gpa);
        try rig.mirror(&event);
        if (event == .turn_ended) break;
    } else return error.TestExpectedEnd;
    try rig.expectKinds(&.{ .intro, .user, .model });
    try std.testing.expectEqualStrings("partial answer", rig.blocks()[2].content.model.items);
}
