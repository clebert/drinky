const std = @import("std");
const application = @import("application");
const reference = @import("reference.zig");
const terminal = @import("terminal");
const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");
const tools = @import("tools");
const command = @import("command.zig");
const describe = @import("describe.zig");
const Flow = @import("Flow.zig");
const Herdr = @import("Herdr.zig");
const mcp = @import("mcp/root.zig");
const Screen = @import("Screen.zig");
const sources = @import("sources.zig");
const testing = @import("testing.zig");
const ui = @import("ui/root.zig");
const wording = @import("wording.zig");
const App = @This();
const turn_cancel_notice = "Press Esc again to cancel the turn. The draft stays.";
const turn_message_notice = "Drinky sends no message while a turn runs. The draft stays.";
const fetch_message_notice = "Drinky sends no message while a model fetch runs. The draft stays.";
const fetch_cancel_notice = "You canceled the model fetch.";
const login_callback_controls = "Enter: Replay callback URL · Esc: Cancel";
const cancel_controls = "Esc: Cancel";
const retry_caption: ui.Caption = .{
    .title = "Failed turn",
    .controls = "Ctrl+N: Try again · Esc: Dismiss",
    .rows_max = Screen.editor_caption_rows_max,
};
const removal_caption: ui.Caption = .{
    .title = "Canceled turn",
    .controls = "Ctrl+N: Remove and edit · Esc: Keep turn",
    .rows_max = Screen.editor_caption_rows_max,
};
const intro_text = blk: {
    var line: []const u8 = "";
    for (reference.key_hints) |hint| line = line ++ hint ++ ui.paint.separator;
    break :blk line ++ reference.line(.help) ++ ": Commands";
};
const escape_wait_ms = 50;
const work_title_bytes_max = 64;
const queue_capacity = 256;
const pending_max = 4;

gpa: std.mem.Allocator,
io: std.Io,
device: terminal.Device,
controller: *application.Controller,
screen: Screen,
input: terminal.Input,
work: application.State.Work = .idle,
offer: application.State.Offer = .none,
running: bool = false,
dirty: bool = false,
ctrl_c_ms_last: i64 = -reference.repeat_window_ms,
ctrl_d_ms_last: i64 = -reference.repeat_window_ms,
escape: ?PendingEscape = null,
queue: std.Io.Queue(UiEvent),
queue_buffer: [queue_capacity]UiEvent = undefined,
queue_closing: std.atomic.Value(bool) = .init(false),
input_future: ?std.Io.Future(void) = null,
resize_future: ?std.Io.Future(void) = null,
tick_future: ?std.Io.Future(void) = null,
frame_grid: FrameGrid = .reset(0),
herdr: Herdr,
confirmation: ?Confirmation = null,
flow: ?Flow = null,
pending: [pending_max]Transition = undefined,
pending_count: usize = 0,
edits: u64 = 0,
paste_edits: ?u64 = null,
working_directory: []const u8,
home_directory: []const u8 = "",
directory_label: []const u8 = "",
project_row: bool,
work_title: [work_title_bytes_max]u8 = undefined,
work_title_length: usize = 0,
endpoint: mcp.Endpoint,
serving_remote: bool = false,

const Options = struct {
    working_directory: []const u8,
    home: []const u8,
    mcp_directory: []const u8,
    device: terminal.Device,
    environment: *const std.process.Environ.Map,
    environ: std.process.Environ = .empty,
    herdr: ?Herdr.Endpoint = null,
    transport: ?application.Transport = null,
    browser: ?application.Browser = null,
    loopback: ?application.Loopback = null,
};
const UiEvent = union(enum) {
    keys: []u8,
    mail: application.Mail,
    remote: *mcp.Endpoint.Request,
    tick,
    resize,
    fn deinit(self: *const UiEvent, gpa: std.mem.Allocator, io: std.Io) void {
        switch (self.*) {
            .keys => |bytes| gpa.free(bytes),
            .mail => |*mail| mail.deinit(gpa),
            .remote => |request| request.release(gpa, io),
            .tick, .resize => {},
        }
    }
};
const FrameGrid = struct {
    deadline_ns: i96,

    const interval_ns = 16 * std.time.ns_per_ms;

    fn reset(now_ns: i96) FrameGrid {
        return .{ .deadline_ns = now_ns };
    }

    fn advance(self: *FrameGrid, now_ns: i96) void {
        const next_ns = self.deadline_ns + interval_ns;
        self.deadline_ns = if (next_ns <= now_ns) now_ns else next_ns;
    }
};

const Mode = union(enum) {
    prompt,
    turn: u64,
    fetch: application.State.Fetch,
    picker,
    picker_fetch,
    page,
    sign_in: application.State.SignIn,
};

const Origin = enum { line, help };

const PendingEscape = struct { deadline_ms: i64, mode: Mode };

const Exit = enum { escape, ctrl_c, ctrl_d };

const CheckedStep = enum { model, logout, rewind };

const Transition = union(enum) {
    sign_in: application.Event.SignInEnd,
    fetch: application.Event.FetchEnd,
    no_account,
    remote_clear,
};

const Confirmation = union(enum) {
    message,
    quit,
    removal: u64,
    rewind: u64,
    cancel,

    fn confirms(self: Confirmation, event: *const terminal.Input.Key) bool {
        return switch (self) {
            .message, .rewind => event.* == .enter,
            .quit => event.* == .ctrl and event.ctrl == 'd',
            .removal => event.* == .ctrl and event.ctrl == 'n',
            .cancel => event.* == .escape,
        };
    }
};

const sink_vtable: application.Sink.VTable = .{ .emit = emitApplicationEvent };
const mailbox_vtable: application.Mailbox.VTable = .{ .post = postMail };
const host_vtable: mcp.Endpoint.Host.VTable = .{ .post = postRemote };

fn emitApplicationEvent(ptr: *anyopaque, event: *const application.Event) void {
    const self: *App = @ptrCast(@alignCast(ptr));
    self.dirty = true;
    self.applyEvent(event) catch |err| switch (err) {
        error.OutOfMemory => application.support.outOfMemory(),
    };
}
fn postMail(ptr: *anyopaque, mail: application.Mail) void {
    const self: *App = @ptrCast(@alignCast(ptr));
    self.keep(.{ .mail = mail });
}
fn postRemote(ptr: *anyopaque, request: *mcp.Endpoint.Request) mcp.Endpoint.Host.PostError!void {
    const self: *App = @ptrCast(@alignCast(ptr));
    if (self.queue_closing.load(.acquire)) return error.Closed;
    const count = self.queue.putUncancelable(self.io, &.{.{ .remote = request }}, 0) catch
        return error.Closed;
    if (count == 0) return error.Full;
}
fn keep(self: *App, event: UiEvent) void {
    if (self.queue_closing.load(.acquire)) return event.deinit(self.gpa, self.io);
    self.queue.putOneUncancelable(self.io, event) catch {
        event.deinit(self.gpa, self.io);
        std.debug.assert(self.queue_closing.load(.acquire));
    };
}
pub fn init(self: *App, gpa: std.mem.Allocator, io: std.Io, options: *const Options) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .device = options.device,
        .controller = undefined,
        .screen = .init(gpa, options.device.writer(), application.reference.effort_default),
        .input = .init(gpa),
        .queue = undefined,
        .herdr = .init(io),
        .working_directory = options.working_directory,
        .project_row = options.herdr == null,
        .endpoint = .init(gpa, io, options.mcp_directory, .{ .ptr = self, .vtable = &host_vtable }),
    };
    self.screen.verbose = (application.Settings{}).verbose;
    self.screen.intro = intro_text;
    self.queue = .init(&self.queue_buffer);
    errdefer self.screen.deinit();
    errdefer self.input.deinit();
    const document = try describe.compose(gpa);
    defer gpa.free(document);
    const frontend: application.Frontend = .{
        .instructions = describe.terminal_instructions,
        .reference = document,
    };
    self.controller = try application.Controller.create(gpa, io, &.{
        .directories = .{ .working_directory = options.working_directory, .home = options.home },
        .environment = options.environment,
        .environ = options.environ,
        .startup = .session,
        .frontend = frontend,
        .transport = options.transport,
        .browser = options.browser,
        .loopback = options.loopback,
        .sink = .{ .ptr = self, .vtable = &sink_vtable },
        .mailbox = .{ .ptr = self, .vtable = &mailbox_vtable },
    });
    errdefer {
        self.stopQueue();
        self.closeFlow();
        self.controller.destroy();
        self.drainQueue();
        self.gpa.free(self.home_directory);
        self.gpa.free(self.directory_label);
    }
    errdefer self.herdr.deinit();
    self.herdr.start(options.herdr) catch |err| {
        const text = try gpa.print(
            "Drinky could not start the state reports to Herdr because of error {s}.",
            .{@errorName(err)},
        );
        defer gpa.free(text);
        try self.screen.setStartupFailure(text);
    };
    _ = self.controller.submit(&.snapshot);
    try self.settle();
}
pub fn deinit(self: *App) void {
    self.stopQueue();
    self.endpoint.deinit();
    self.closeFlow();
    self.controller.destroy();
    self.closeQueue();
    self.herdr.deinit();
    self.gpa.free(self.home_directory);
    self.gpa.free(self.directory_label);
    self.screen.deinit();
    self.input.deinit();
}
pub fn run(self: *App) !void {
    defer self.prepareTerminalExit();
    try self.refresh();
    self.frame_grid = .reset(self.nowNs());

    self.running = true;
    defer self.stopTasks();
    self.input_future = try self.io.concurrent(readInput, .{self});
    self.resize_future = try self.io.concurrent(readResize, .{self});

    try self.runLoop();
}

fn prepareTerminalExit(self: *App) void {
    self.device.setAlternateScreen(false) catch return;
    self.screen.parkCursor() catch {};
}

fn stopTasks(self: *App) void {
    self.stopQueue();
    self.cancelFuture(&self.input_future);
    self.cancelFuture(&self.resize_future);
    self.cancelFuture(&self.tick_future);
}

fn stopQueue(self: *App) void {
    self.queue_closing.store(true, .release);
    self.queue.close(self.io);
}

fn closeQueue(self: *App) void {
    self.stopQueue();
    self.drainQueue();
}

fn cancelFuture(self: *App, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.cancel(self.io);
        maybe_future.* = null;
    }
}

fn awaitFuture(self: *App, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.await(self.io);
        maybe_future.* = null;
    }
}

fn drainQueue(self: *App) void {
    var batch: [queue_capacity]UiEvent = undefined;
    while (true) {
        const count = self.queue.get(self.io, &batch, 0) catch break;
        if (count == 0) break;
        for (batch[0..count]) |event| event.deinit(self.gpa, self.io);
    }
}

fn runLoop(self: *App) !void {
    var batch: [queue_capacity]UiEvent = undefined;
    while (self.running) {
        const count = self.queue.get(self.io, &batch, 1) catch |err| switch (err) {
            error.Closed, error.Canceled => break,
        };
        const ticked = try self.applyBatch(batch[0..count]);
        try self.flushEscape();
        self.herdr.sync(if (self.working())
            .working
        else if (self.offer == .retry) .blocked else .idle);
        if (ticked) {
            self.awaitFuture(&self.tick_future);
            const activity_changed = self.screen.advanceFrame(self.nowMs());
            if (self.dirty or activity_changed) {
                try self.refresh();
                self.dirty = false;
            }
        }
        const waiting = self.dirty or
            self.screen.animating() or
            self.escape != null;
        if (waiting and self.tick_future == null) try self.armTick();
    }
}

fn working(self: *const App) bool {
    return self.work == .turn or self.work == .aside;
}

fn armTick(self: *App) !void {
    self.frame_grid.advance(self.nowNs());
    const deadline_ns = self.frame_grid.deadline_ns;
    self.tick_future = self.io.concurrent(frameTimer, .{ self, deadline_ns }) catch |err| {
        _ = self.controller.submit(&.{ .dismiss_notice = self.screen.notice_id });
        try self.reportNotice(
            .failure,
            "Drinky could not start the frame timer because of error {s}.",
            .{@errorName(err)},
        );
        try self.refresh();
        self.dirty = false;
        self.frame_grid = .reset(self.nowNs());
        return;
    };
}

fn frameTimer(self: *App, deadline_ns: i96) void {
    const deadline: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(deadline_ns),
        .clock = .awake,
    };
    deadline.wait(self.io) catch return;
    self.queue.putOne(self.io, .tick) catch {};
}

fn readResize(self: *App) void {
    while (true) {
        self.device.waitResize() catch return;
        self.queue.putOne(self.io, .resize) catch return;
    }
}

fn readInput(self: *App) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = self.device.read(&buffer) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                self.stopQueue();
                return;
            },
        };
        const copy = self.gpa.dupe(u8, buffer[0..count]) catch application.support.outOfMemory();
        self.queue.putOne(self.io, .{ .keys = copy }) catch {
            self.gpa.free(copy);
            return;
        };
    }
}

fn handleKeys(self: *App, bytes: []const u8) !void {
    try self.input.feed(bytes);
    while (self.input.next()) |event| {
        const before = std.meta.activeTag(self.mode());
        try self.handleKey(&event);
        try self.settle();
        if (before != std.meta.activeTag(self.mode()) and exitOf(&event) != null) {
            while (self.input.next()) |_| {}
            break;
        }
    }
    self.escape = if (self.input.pendingEscape())
        .{ .deadline_ms = self.nowMs() + escape_wait_ms, .mode = self.mode() }
    else
        null;
}

fn exitOf(event: *const terminal.Input.Key) ?Exit {
    return switch (event.*) {
        .escape => .escape,
        .ctrl => |letter| switch (letter) {
            'c' => .ctrl_c,
            'd' => .ctrl_d,
            else => null,
        },
        .char,
        .paste,
        .enter,
        .shift_enter,
        .tab,
        .backspace,
        .left,
        .right,
        .up,
        .down,
        .page_up,
        .page_down,
        .home,
        .end,
        .unknown,
        => null,
    };
}

fn flushEscape(self: *App) !void {
    const pending = self.escape orelse return;
    if (self.nowMs() < pending.deadline_ms) return;
    self.escape = null;
    if (!self.input.takeEscape()) return;
    if (!std.meta.eql(pending.mode, self.mode())) return;
    self.dirty = true;
    try self.handleKey(&.escape);
    try self.settle();
}

fn mode(self: *const App) Mode {
    if (self.flow) |*flow| return if (flow.fetch == null) .picker else .picker_fetch;
    if (self.screen.widget == .page) return .page;
    return switch (self.work) {
        .idle => .prompt,
        .turn => |operation| .{ .turn = operation },
        .fetch => |fetch| .{ .fetch = fetch },
        .sign_in => |sign_in| .{ .sign_in = sign_in },
        .aside => .page,
    };
}

fn armed(self: *const App, expected: Confirmation) bool {
    const current = self.confirmation orelse return false;
    return std.meta.eql(current, expected);
}

fn disarm(self: *App, event: *const terminal.Input.Key) void {
    const confirmation = self.confirmation orelse return;
    if (!confirmation.confirms(event)) self.confirmation = null;
}

fn confirm(self: *App, confirmation: Confirmation, notice: ui.Message) void {
    self.screen.confirm(switch (confirmation) {
        .message => .message,
        .removal => .removal,
        .rewind => .rewind,
        .quit, .cancel => unreachable,
    }, notice);
    self.confirmation = confirmation;
}

fn confirmTurn(self: *App, confirmation: Confirmation) !void {
    self.confirm(confirmation, try ui.Message.print(self.gpa, .warning, "", .{}));
}

fn draftEmpty(self: *const App) bool {
    return self.screen.editor.visible().len == 0;
}

fn clearDraft(self: *App) void {
    self.screen.editor.clear();
    self.screen.markEdited();
}

fn prependDraft(self: *App, text: []const u8) !void {
    try self.screen.editor.prependText(text);
    self.screen.markEdited();
}

fn editKey(self: *App, event: *const terminal.Input.Key) !bool {
    const editor = &self.screen.editor;
    switch (event.*) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .paste => |paste| try editor.paste(paste.bytes, paste.final),
        .backspace => editor.backspace(),
        .left => editor.moveLeft(),
        .right => editor.moveRight(),
        .up => editor.moveUp(self.screen.columns),
        .down => editor.moveDown(self.screen.columns),
        .home => editor.moveHome(),
        .end => editor.moveEnd(),
        .shift_enter => try editor.insert("\n"),
        .ctrl => |letter| switch (letter) {
            'j' => try editor.insert("\n"),
            else => return false,
        },
        .enter, .tab, .escape, .page_up, .page_down, .unknown => return false,
    }
    self.screen.markEdited();
    self.edits +%= 1;
    return true;
}

fn clearOrQuit(self: *App) void {
    const now = self.nowMs();
    if (now - self.ctrl_c_ms_last < reference.repeat_window_ms) {
        self.running = false;
    } else {
        self.clearDraft();
        self.ctrl_c_ms_last = now;
    }
}

fn quitOrWarn(self: *App) !void {
    const draft = !self.draftEmpty();
    const recent_exit = self.nowMs() - self.ctrl_d_ms_last < reference.repeat_window_ms;
    if (self.armed(.quit) or (!draft and !recent_exit)) {
        self.running = false;
        return;
    }
    if (draft) {
        try self.reportNotice(
            .warning,
            "Press Ctrl+D again to quit. The quit discards the draft.",
            .{},
        );
    } else {
        try self.reportNotice(.warning, "Press Ctrl+D again to quit.", .{});
    }
    self.confirmation = .quit;
}

fn refresh(self: *App) !void {
    const size: terminal.View.Size = self.device.size() orelse
        .{ .columns = self.screen.columns, .rows = self.screen.rows };
    try self.device.setAlternateScreen(self.mode() == .page);
    try self.screen.paint(size, self.screenTime(), &self.caption());
}

fn screenTime(self: *App) Screen.Time {
    return .{ .awake_ms = self.nowMs(), .boot_ms = self.nowBootMs() };
}

fn nowMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

fn nowBootMs(self: *App) i64 {
    return std.Io.Timestamp.now(self.io, .boot).toMilliseconds();
}

fn nowNs(self: *App) i96 {
    return std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
}

fn caption(self: *const App) ?ui.Caption {
    return switch (self.mode()) {
        .sign_in => |sign_in| .{
            .title = self.work_title[0..self.work_title_length],
            .controls = if (sign_in.callback) login_callback_controls else cancel_controls,
            .rows_max = Screen.editor_caption_rows_max,
        },
        .fetch => .{
            .title = self.work_title[0..self.work_title_length],
            .controls = cancel_controls,
            .rows_max = Screen.editor_caption_rows_max,
        },
        .prompt => switch (self.offer) {
            .none => null,
            .retry => retry_caption,
            .removal => removal_caption,
        },
        .turn, .picker, .picker_fetch, .page => null,
    };
}
fn applyBatch(self: *App, events: []const UiEvent) !bool {
    var applied_count: usize = 0;
    errdefer for (events[applied_count..]) |*event| event.deinit(self.gpa, self.io);
    var ticked = false;
    for (events) |event| {
        applied_count += 1;
        switch (event) {
            .tick => ticked = true,
            .resize => self.dirty = true,
            .keys => |bytes| {
                defer self.gpa.free(bytes);
                self.dirty = true;
                _ = self.controller.submit(&.refresh_project);
                try self.handleKeys(bytes);
            },
            .mail => |mail| {
                self.controller.receive(mail);
                try self.settle();
            },
            .remote => |request| {
                defer request.release(self.gpa, self.io);
                self.dirty = true;
                try self.serveRemote(request);
            },
        }
    }
    return ticked;
}
fn serveRemote(self: *App, request: *mcp.Endpoint.Request) !void {
    const instance = self.endpoint.published() orelse return;
    if (!self.endpoint.admit(request)) return;
    self.serving_remote = true;
    defer self.serving_remote = false;
    const reply = try mcp.catalog.answer(self.gpa, &.{
        .controller = self.controller,
        .instance = instance,
        .working_directory = self.working_directory,
        .interaction = switch (self.mode()) {
            .picker, .picker_fetch, .page, .sign_in => true,
            .prompt, .turn, .fetch => false,
        },
    }, request.line);
    request.deliver(self.gpa, self.io, reply);
    try self.settle();
}
fn applyEvent(self: *App, event: *const application.Event) !void {
    if (Screen.changeOf(event)) |*change| try self.screen.applyChange(change);
    switch (event.*) {
        .snapshot => |*snapshot| try self.applySnapshot(snapshot),
        .state => |*value| {
            self.adopt(value);
            try self.screen.applyState(value);
        },
        .paste_replayed => if (self.paste_edits == self.edits) self.clearDraft(),
        .sign_in_ended => |ended| self.postpone(.{ .sign_in = ended }),
        .fetch_ended => |ended| self.postpone(.{ .fetch = ended }),
        .no_account => self.postpone(.no_account),
        .clear_conversation => if (self.serving_remote) self.postpone(.remote_clear),
        .append_record,
        .record_text,
        .replace_record,
        .remove_records,
        .live,
        .statistics,
        .turn_ended,
        .charge,
        .startup_refused,
        => {},
    }
}
fn postpone(self: *App, transition: Transition) void {
    for (self.pending[0..self.pending_count]) |held| {
        if (std.meta.eql(held, transition)) return;
    }
    std.debug.assert(self.pending_count < pending_max);
    self.pending[self.pending_count] = transition;
    self.pending_count += 1;
}
fn settle(self: *App) !void {
    var index: usize = 0;
    while (index < self.pending_count) : (index += 1) {
        switch (self.pending[index]) {
            .sign_in => |ended| if (ended.signed_in) {
                try self.startFlow(Flow.forAccount(&self.controller.listAccounts(), ended.account));
            },
            .fetch => |ended| try self.finishFetch(&ended),
            .no_account => {
                self.closeFlow();
                try self.startFlow(.login);
            },
            .remote_clear => try self.reportNotice(
                .information,
                "An MCP client cleared the conversation.",
                .{},
            ),
        }
    }
    self.pending_count = 0;
}
fn finishFetch(self: *App, ended: *const application.Event.FetchEnd) !void {
    const flow = if (self.flow) |*flow| flow else return self.reportFetch(ended);
    const fetch = flow.fetch orelse return self.reportFetch(ended);
    if (fetch.operation != ended.operation) return;
    flow.fetch = null;
    const exit = fetch.exit orelse {
        if (ended.outcome == .listed) return self.showStep(flow.step, .{});
        return self.closeFlow();
    };
    switch (exit) {
        .command => try self.cancelFlow(),
        .step => {
            try self.showStep(flow.step, .{});
            try self.reportNotice(.information, fetch_cancel_notice, .{});
        },
    }
}
fn reportFetch(self: *App, ended: *const application.Event.FetchEnd) !void {
    switch (ended.outcome) {
        .listed => try self.reportNotice(
            .information,
            "Drinky fetched the model list of {s}.",
            .{application.query.accountId(ended.account)},
        ),
        .canceled, .failed => {},
    }
}
fn applySnapshot(self: *App, snapshot: *const application.Snapshot) !void {
    const initialize_roots = self.home_directory.len == 0;
    const home = if (initialize_roots)
        try self.gpa.dupe(u8, snapshot.home_directory)
    else
        self.home_directory;
    errdefer if (initialize_roots) self.gpa.free(home);
    const label = if (initialize_roots)
        try ui.status.directoryLabel(
            self.gpa,
            &.{ .path = self.working_directory, .home = home },
        )
    else
        self.directory_label;
    errdefer if (initialize_roots) self.gpa.free(label);
    if (initialize_roots) self.screen.verbose = snapshot.settings.verbose;
    try self.screen.restore(snapshot);
    self.home_directory = home;
    self.directory_label = label;
    self.screen.display_roots = .{
        .working_directory = self.working_directory,
        .home_directory = home,
    };
    self.screen.directory_shown = if (self.project_row) self.directory_label else "";
    self.adopt(&snapshot.state);
}
fn adopt(self: *App, value: *const application.State) void {
    if (value.notice_id != self.screen.notice_id) self.confirmation = null;
    if (value.work.operation() != self.work.operation() and self.confirmation != null) {
        self.confirmation = null;
        self.screen.clearNotice();
    }
    self.work = value.work;
    self.offer = value.offer;
    const title = switch (value.work) {
        .sign_in => |sign_in| std.fmt.bufPrint(
            &self.work_title,
            "Sign in: {s}",
            .{application.query.accountId(sign_in.account)},
        ),
        .fetch => |fetch| std.fmt.bufPrint(
            &self.work_title,
            "Model fetch: {s}",
            .{application.query.accountId(fetch.account)},
        ),
        .idle, .turn, .aside => return,
    };
    self.work_title_length = (title catch unreachable).len;
}
fn send(self: *App, value: *const application.Command) !application.Response {
    const response = self.controller.submit(value);
    const refusal = response.refusal orelse return response;
    const message = try wording.refusal(self.gpa, value, &refusal) orelse return response;
    defer message.deinit(self.gpa);
    try self.showMessage(&message);
    return response;
}
fn submit(self: *App) !void {
    const confirmed = self.armed(.message);
    self.confirmation = null;
    if (self.screen.editor.blank()) return;
    const text = try self.screen.editor.expanded();
    defer self.gpa.free(text);
    switch (self.mode()) {
        .sign_in => |sign_in| {
            const response = try self.send(&.{ .submit_callback = .{
                .operation = sign_in.operation,
                .line = text,
            } });
            if (response.accepted()) self.paste_edits = self.edits;
        },
        .turn => try self.submitDuringWork(text, .turn),
        .fetch => try self.submitDuringWork(text, .fetch),
        .prompt => if (confirmed) try self.sendMessage(text) else try self.submitLine(text),
        .picker, .picker_fetch, .page => unreachable,
    }
}
fn submitLine(self: *App, line: []const u8) !void {
    const command_name = command.name(line) orelse return self.sendMessage(line);
    if (try command.check(self.gpa, line, self.controller.listSkills())) |message|
        return self.confirm(.message, message);
    const tail = command.tail(line, command_name);
    if (command.skillName(command_name)) |skill| {
        const response = try self.send(&.{ .invoke_skill = .{
            .name = skill,
            .arguments = tail,
            .line = line,
        } });
        if (response.accepted()) self.clearDraft();
        return;
    }
    try self.runCommand(command.lookup(command_name).?, tail, .line);
}
fn submitDuringWork(self: *App, line: []const u8, work: command.Work) !void {
    const skills = self.controller.listSkills();
    if (try command.checkDuringWork(self.gpa, line, skills, work)) |message| {
        defer message.deinit(self.gpa);
        return self.showMessage(&message);
    }
    const command_name = command.name(line) orelse return self.sendMessage(line);
    try self.runCommand(command.lookup(command_name).?, command.tail(line, command_name), .line);
}
fn sendMessage(self: *App, line: []const u8) !void {
    const response = try self.send(&.{ .send_message = line });
    const refusal = response.refusal orelse return self.clearDraft();
    if (refusal != .busy) return;
    switch (self.mode()) {
        .turn => try self.reportNotice(.information, turn_message_notice, .{}),
        .fetch => try self.reportNotice(.information, fetch_message_notice, .{}),
        .prompt, .picker, .picker_fetch, .page, .sign_in => {},
    }
}
fn runCommand(
    self: *App,
    value: reference.Command,
    tail: []const u8,
    origin: Origin,
) !void {
    switch (value) {
        .effort => try self.openCommandStep(.effort, origin),
        .help => try self.openCommandStep(.help, origin),
        .login => try self.openCommandStep(.login, origin),
        .logout => try self.openCheckedStep(.logout, origin),
        .model => try self.openCheckedStep(.model, origin),
        .rewind => try self.openCheckedStep(.rewind, origin),
        .skill => {
            if (self.controller.listSkills().len > 0) return self.openCommandStep(.skill, origin);
            self.closeFlow();
            try self.reportNotice(.warning, "Drinky found no skill.", .{});
        },
        .handoff => {
            self.closeFlow();
            _ = try self.send(&.{ .prepare_handoff = tail });
            if (origin == .help) try self.screen.setDraft(reference.line(.handoff));
        },
        .tldr => {
            self.closeFlow();
            if ((try self.send(&.prepare_short_answer)).accepted()) self.clearDraft();
        },
        .new => {
            self.closeFlow();
            const accepted = (try self.send(&.new_conversation)).accepted();
            if (accepted and origin == .line) self.clearDraft();
        },
        .sources => {
            self.closeFlow();
            const page = try sources.compose(self.gpa, &.{
                .documents = &self.controller.documents(),
                .roots = self.screen.display_roots,
            });
            defer self.gpa.free(page);
            try self.screen.openPage(&.{ .title = "Sources", .content = page });
            if (origin == .line) self.clearDraft();
        },
        .system => {
            self.closeFlow();
            const prompt = self.controller.documents().system_prompt;
            try self.screen.openPage(&.{ .title = "System prompt", .content = prompt });
            if (origin == .line) self.clearDraft();
        },
        .verbose => {
            self.closeFlow();
            try self.toggleVerbose();
            if (origin == .line) self.clearDraft();
        },
        .mcp => {
            self.closeFlow();
            try self.toggleAccess();
            if (origin == .line) self.clearDraft();
        },
    }
}
fn openCommandStep(self: *App, step: Flow.Step, origin: Origin) !void {
    switch (origin) {
        .line => {
            try self.startFlow(step);
            self.clearDraft();
        },
        .help => try self.openStep(step),
    }
}
fn openCheckedStep(self: *App, checked: CheckedStep, origin: Origin) !void {
    if (self.work != .idle) return self.closeFlow();
    const step: Flow.Step = switch (checked) {
        .model => .vendor,
        .logout => .logout,
        .rewind => .rewind,
    };
    const missing = self.missingTarget(checked) orelse return self.openCommandStep(step, origin);
    self.closeFlow();
    try self.showMessage(&missing);
}
fn missingTarget(self: *App, checked: CheckedStep) ?ui.Message {
    const facts = self.controller.listAccounts();
    return switch (checked) {
        .model => for (&facts) |*fact| {
            if (fact.authenticated) break null;
        } else .{
            .severity = .failure,
            .content = "Sign in to an account before you select a model.",
        },
        .logout => for (&facts) |*fact| {
            if (fact.login and fact.authenticated) break null;
        } else .{ .severity = .failure, .content = "No accounts are signed in." },
        .rewind => if (self.controller.listTurns().len > 0)
            null
        else
            .{ .severity = .warning, .content = "No prompts are in the conversation." },
    };
}
fn toggleVerbose(self: *App) !void {
    self.screen.setVerbose(!self.screen.verbose);
    try self.reportNotice(
        .information,
        "Verbose output is {s}.",
        .{if (self.screen.verbose) "on" else "off"},
    );
}
fn toggleAccess(self: *App) !void {
    defer self.screen.mcp_access = self.endpoint.published() != null;
    if (self.endpoint.published()) |instance| {
        self.endpoint.disable() catch |err| return self.reportNotice(
            .failure,
            "MCP access is off for instance {s}. Drinky could not remove its entry because " ++
                "of error {s}.",
            .{ &instance, @errorName(err) },
        );
        return self.reportNotice(.information, "MCP access is off for instance {s}.", .{&instance});
    }
    const instance = self.endpoint.enable() catch |err| return self.reportNotice(
        .failure,
        "Drinky could not turn on MCP access because of error {s}.",
        .{@errorName(err)},
    );
    try self.reportNotice(.information, "MCP access is on. Instance: {s}.", .{&instance});
}
fn startFlow(self: *App, step: Flow.Step) !void {
    self.closeFlow();
    self.flow = .init(self.gpa);
    try self.showStep(Flow.resolve(self.controller, step), .{});
}
fn openStep(self: *App, step: Flow.Step) !void {
    const flow = &self.flow.?;
    const resolved = Flow.resolve(self.controller, step);
    if (!std.meta.eql(flow.step, resolved)) flow.push(self.screen.activePicker().?.cursor);
    try self.showStep(resolved, .{});
}
fn showStep(self: *App, step: Flow.Step, options: struct { cursor: ?usize = null }) !void {
    const flow = &self.flow.?;
    const shown = try flow.show(self.controller, &self.screen.choice, step);
    try self.screen.openPicker(&.{
        .title = shown.title,
        .options = shown.options,
        .current = shown.current,
        .preselected = shown.preselected,
        .cursor = options.cursor,
        .depth = flow.depth,
    });
}
fn closeFlow(self: *App) void {
    const flow = if (self.flow) |*flow| flow else return;
    flow.deinit();
    self.flow = null;
    self.screen.closePicker();
}
fn cancelFlow(self: *App) !void {
    const message = self.flow.?.step.cancellation();
    self.closeFlow();
    try self.reportNotice(.information, "{s}", .{message});
}
fn backFlow(self: *App) !void {
    const entry = self.flow.?.back() orelse return self.cancelFlow();
    try self.showStep(Flow.resolve(self.controller, entry.step), .{ .cursor = entry.cursor });
}
fn selectRow(self: *App) !void {
    const flow = &self.flow.?;
    const item = flow.target(self.screen.activePicker().?.cursor);
    switch (item) {
        .command => |value| try self.runCommand(value, "", .help),
        .vendor => |account| try self.openStep(.{ .account = account }),
        .account => |account| {
            try self.openStep(Flow.forAccount(&self.controller.listAccounts(), account));
        },
        .fetch => |account| {
            const response = try self.send(&.{ .fetch_models = account });
            const operation = response.operation orelse return;
            flow.fetch = .{ .operation = operation };
            try self.screen.beginPickerWait(Flow.fetch_wait_text);
        },
        .author => |named| {
            try flow.setAuthor(named.name);
            try self.openStep(.{ .author_models = named.account });
        },
        .model => |named| {
            const name = try self.gpa.dupe(u8, named.name);
            defer self.gpa.free(name);
            self.closeFlow();
            _ = try self.send(&.{ .select_model = .{ .account = named.account, .model = name } });
        },
        .effort => |level| {
            self.closeFlow();
            _ = try self.send(&.{ .set_effort = level });
        },
        .sign_in => |account| {
            self.closeFlow();
            _ = try self.send(&.{ .select_account = account });
        },
        .sign_out => |account| {
            self.closeFlow();
            _ = try self.send(&.{ .sign_out = account });
        },
        .skill => |name| {
            const line = try self.gpa.print(
                "{s}{s} ",
                .{ "/" ++ reference.skill_prefix, name },
            );
            defer self.gpa.free(line);
            self.closeFlow();
            try self.screen.setDraft(line);
        },
        .turn => |turn| {
            if (turn.mutated and !self.armed(.{ .rewind = turn.id }))
                return self.confirmTurn(.{ .rewind = turn.id });
            self.confirmation = null;
            self.closeFlow();
            const response = try self.send(&.{ .rewind = turn.id });
            if (response.recovered) |text| try self.prependDraft(text);
        },
    }
}
fn takeOffer(self: *App) !void {
    switch (self.offer) {
        .none => {},
        .retry => _ = try self.send(&.retry),
        .removal => |removal| {
            if (removal.mutated and !self.armed(.{ .removal = removal.turn }))
                return self.confirmTurn(.{ .removal = removal.turn });
            self.confirmation = null;
            const response = try self.send(&.{ .remove_canceled_turn = removal.turn });
            if (response.recovered) |text| try self.prependDraft(text);
        },
    }
}
fn cancelWork(self: *App, operation: u64) !void {
    _ = try self.send(&.{ .cancel = operation });
}
fn exitFetch(self: *App, exit: Flow.Fetch.Exit) !void {
    const fetch = &self.flow.?.fetch.?;
    if (fetch.exit != null) return;
    fetch.exit = exit;
    _ = try self.send(&.{ .cancel = fetch.operation });
}
fn closePage(self: *App) !void {
    const shown = self.screen.result_page orelse return self.screen.closePage();
    if (shown.phase == .generating) {
        _ = try self.send(&.{ .cancel = shown.id });
        return;
    }
    _ = try self.send(&.{ .discard_result = shown.id });
}
fn applyResult(self: *App) !void {
    const shown = self.screen.result_page.?;
    if ((try self.send(&.{ .apply_result = shown.id })).accepted()) self.clearDraft();
}
fn handleExit(self: *App, exit: Exit, notice_shown: bool) !void {
    const current = self.mode();
    if (exit == .ctrl_d and current != .prompt) self.ctrl_d_ms_last = self.nowMs();
    if (exit == .ctrl_c and
        (current == .prompt or current == .turn or current == .fetch or current == .sign_in) and
        !self.draftEmpty())
    {
        if (current == .prompt) self.clearOrQuit() else self.clearDraft();
        return;
    }
    if (exit == .escape) switch (current) {
        .turn => |operation| {
            if (notice_shown and !self.armed(.cancel)) return;
            if (!self.draftEmpty() and !self.armed(.cancel)) {
                try self.reportNotice(.warning, turn_cancel_notice, .{});
                self.confirmation = .cancel;
                return;
            }
            return self.cancelWork(operation);
        },
        .prompt, .fetch, .picker, .picker_fetch, .page, .sign_in => {},
    };
    switch (current) {
        .prompt => switch (exit) {
            .escape => _ = try self.send(&.dismiss_offer),
            .ctrl_c => self.clearOrQuit(),
            .ctrl_d => try self.quitOrWarn(),
        },
        .picker => if (exit == .escape) try self.backFlow() else try self.cancelFlow(),
        .picker_fetch => try self.exitFetch(if (exit == .escape) .step else .command),
        .fetch => |fetch| if ((try self.send(&.{ .cancel = fetch.operation })).accepted()) {
            try self.reportNotice(.information, fetch_cancel_notice, .{});
        },
        .turn => |operation| try self.cancelWork(operation),
        .sign_in => |sign_in| try self.cancelWork(sign_in.operation),
        .page => try self.closePage(),
    }
}
fn handleKey(self: *App, event: *const terminal.Input.Key) !void {
    self.disarm(event);
    const notice_shown = self.screen.notice != null;
    self.screen.clearNotice();
    if (notice_shown and self.confirmation == null)
        _ = self.controller.submit(&.{ .dismiss_notice = self.screen.notice_id });
    if (exitOf(event)) |exit| return self.handleExit(exit, notice_shown);
    switch (self.mode()) {
        .prompt, .turn, .fetch, .sign_in => {
            if (try self.editKey(event)) return;
            switch (event.*) {
                .enter => try self.submit(),
                .ctrl => |letter| if (letter == 'n' and self.mode() == .prompt) {
                    try self.takeOffer();
                },
                .char,
                .paste,
                .shift_enter,
                .tab,
                .backspace,
                .left,
                .right,
                .up,
                .down,
                .page_up,
                .page_down,
                .home,
                .end,
                .unknown,
                => {},
                .escape => unreachable,
            }
        },
        .picker => {
            const picker = self.screen.activePicker().?;
            switch (event.*) {
                .up => try picker.moveUp(),
                .down => try picker.moveDown(),
                .enter => try self.selectRow(),
                .escape => unreachable,
                .char,
                .ctrl,
                .paste,
                .shift_enter,
                .tab,
                .backspace,
                .left,
                .right,
                .page_up,
                .page_down,
                .home,
                .end,
                .unknown,
                => {},
            }
        },
        .picker_fetch => {},
        .page => {
            const page = self.screen.activePage() orelse return;
            const size: terminal.View.Size = .{
                .columns = self.screen.columns,
                .rows = self.screen.rows,
            };
            switch (event.*) {
                .enter => if (page.action == .apply) try self.applyResult(),
                .up => page.moveUp(size),
                .down => page.moveDown(size),
                .page_up => page.pageUp(size),
                .page_down => page.pageDown(size),
                .home => page.moveHome(),
                .end => page.moveEnd(size),
                .char => |codepoint| if (codepoint == 'm' or codepoint == 'M') {
                    page.toggleSource(size);
                },
                .escape => unreachable,
                .ctrl,
                .paste,
                .shift_enter,
                .tab,
                .backspace,
                .left,
                .right,
                .unknown,
                => {},
            }
        },
    }
}
fn reportNotice(
    self: *App,
    severity: ui.Message.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const notice = try ui.Message.print(self.gpa, severity, format, args);
    if (self.armed(.message)) self.confirmation = null;
    self.screen.setNotice(notice);
}
fn showMessage(self: *App, message: *const ui.Message) !void {
    try self.reportNotice(message.severity, "{s}", .{message.content});
}
test "a Herdr startup failure stays in the transcript across snapshots with the branch" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .concurrent_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var tree = try application.testing.Tree.init();
    defer tree.deinit();
    try tree.write(".git/HEAD", "ref: refs/heads/main\n");
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var device: terminal.testing.FakeDevice = undefined;
    try device.init(gpa, io, .{ .columns = 80, .rows = 24 });
    defer device.deinit();
    var app: App = undefined;
    try app.init(gpa, io, &.{
        .working_directory = tree.root,
        .home = tree.root,
        .mcp_directory = "unused",
        .environment = &environment,
        .device = device.device(),
        .herdr = .{ .socket_path = "/unused", .pane_id = "p1" },
    });
    defer app.deinit();
    for (0..2) |_| {
        const blocks = app.screen.transcript.block_list.items;
        const notice = &blocks[1].content.event;
        try std.testing.expectEqual(.failure, notice.severity);
        try std.testing.expectEqualStrings(
            "Drinky could not start the state reports to Herdr because of error " ++
                "ConcurrencyUnavailable.",
            notice.text.items,
        );
        try std.testing.expectEqualStrings("main", app.screen.branch().?);
        _ = app.controller.submit(&.snapshot);
    }
}

test "startup keeps shell scrollback, and a verbosity toggle clears it" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "key" }},
        .model = "gpt-5.6-sol",
        .history = core.text.repeat("Shell history line.\r\n", 60),
    });
    defer rig.deinit();
    try rig.waitFor(&.{.{ .status = "Model: openai-api-key/gpt-5.6-sol" }});
    try rig.expectSees(&.{.{ .text = "Shell history line." }});
    const output = try rig.device.outputBytes(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.find(u8, output, "\x1b[3J") == null);

    try rig.keys("/verbose\r");
    try rig.waitFor(&.{
        .{ .status = "Verbose output is on." },
        .{ .absent = "Shell history line." },
    });
}

test "terminal turns use frontend instructions and append replies to the transcript" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.reply_stream },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.waitFor(&.{.{ .status = "Model: openai-api-key/gpt-5.6-sol" }});

    try rig.keys("hello\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "hello", "done" } },
        .{ .activity = false },
        .{ .editor = "" },
        .{ .status = "(12/400k)" },
    });
    try rig.keys("again\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "hello", "done", "again", "done" } },
        .{ .activity = false },
    });
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
    try expectRequested(
        &rig,
        "## Frontend\\n\\nDrinky renders your answer as Markdown in a terminal",
    );
    try expectRequested(&rig, "keep it short");
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, rig.lastRequest(), "You run inside Drinky"),
    );
}

const sign_in_titles = blk: {
    var titles: [accounts.Account.table.len][]const u8 = undefined;
    for (&accounts.Account.table, 0..) |*row, index| titles[index] = "Sign in: " ++ row.id;
    break :blk titles;
};

const retry_note = "Drinky asked the model to continue from the committed work.";
const short_answer_title = "Short answer";
const removal_warning = "Press Ctrl+N again to remove the canceled turn. Tool changes stay.";
const rewind_warning = "Press Enter again to rewind. Tool changes stay.";

const Rig = struct {
    tmp: std.testing.TmpDir,
    directory: [:0]const u8,
    mcp_buffer: [128]u8,
    mcp_directory: []const u8,
    environment: std.process.Environ.Map,
    transport: providers.testing.FakeTransport,
    browser: accounts.testing.FakeBrowser,
    loopback: accounts.testing.FakeLoopback,
    clock: testing.Clock,
    device: terminal.testing.FakeDevice,
    app: App,
    run_future: ?std.Io.Future(RunResult),
    app_live: bool,
    delivery_thread: std.atomic.Value(std.Thread.Id),
    queue_waiting: std.Io.Event,

    const RunResult = @typeInfo(@TypeOf(App.run)).@"fn".return_type.?;

    const Sight = union(enum) {
        text: []const u8,
        absent: []const u8,
        line: []const u8,
        rows: []const []const u8,
        status: []const u8,
        editor: []const u8,
        alternate_screen: bool,
        activity: bool,
    };

    const Options = struct {
        allocator: std.mem.Allocator = std.testing.allocator,
        start: bool = true,
        history: []const u8 = "",
        variables: []const [2][]const u8 = &.{},
        store: ?[]const u8 = null,
        config: ?[]const u8 = null,
        files: []const [2][]const u8 = &.{},
        replies: []const providers.testing.FakeTransport.Reply = &.{},
        transport: ?providers.Transport = null,
        model: ?[]const u8 = null,
        model_accounts: []const usize = &.{accounts.testing.openai_api_key},
        window: terminal.View.Size = .{ .columns = 160, .rows = 40 },
        herdr: ?Herdr.Endpoint = null,
    };

    const frame_interval_ms = @divExact(FrameGrid.interval_ns, std.time.ns_per_ms);
    const frames_max = 1024;

    fn init(self: *Rig, options: *const Rig.Options) !void {
        const gpa = std.testing.allocator;
        self.clock.init(gpa);
        errdefer self.clock.deinit();
        self.delivery_thread = .init(0);
        self.queue_waiting = .unset;
        self.clock.vtable.futexWaitUncancelable = waitUncancelable;
        const io = self.clock.io();
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "" });
        self.directory = try self.tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(self.directory);
        self.environment = .init(gpa);
        errdefer self.environment.deinit();
        for (options.variables) |variable| try self.environment.put(variable[0], variable[1]);
        if (options.store) |data| try accounts.testing.writeStore(io, &self.tmp, data);
        try self.writeConfig(options);
        if (options.model) |name| try self.writeModel(name, options.model_accounts);
        for (options.files) |file| {
            const parent_path = std.Io.Dir.path.dirname(file[0]).?;
            var parent = try self.tmp.dir.createDirPathOpen(io, parent_path, .{});
            parent.close(io);
            try self.tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
        }
        self.transport = .{ .gpa = gpa, .replies = options.replies };
        errdefer self.transport.deinit();
        self.browser = .{};
        self.loopback = .{ .io = io };
        try self.device.init(gpa, io, options.window);
        errdefer self.device.deinit();
        try self.device.device().writer().writeAll(options.history);
        try self.device.device().writer().flush();

        self.mcp_directory = try accounts.testing.tmpPath(&self.mcp_buffer, &self.tmp, "mcp");
        try self.app.init(options.allocator, io, &.{
            .working_directory = self.directory,
            .home = self.directory,
            .mcp_directory = self.mcp_directory,
            .device = self.device.device(),
            .environment = &self.environment,
            .herdr = options.herdr,
            .transport = options.transport orelse self.transport.transport(),
            .browser = self.browser.browser(),
            .loopback = self.loopback.loopback(),
        });
        errdefer self.app.deinit();
        self.app_live = true;
        self.run_future = if (options.start) try io.concurrent(runThenStop, .{self}) else null;
    }

    fn waitUncancelable(userdata: ?*anyopaque, pointer: *const u32, expected: u32) void {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const clock: *testing.Clock = @fieldParentPtr("threaded", threaded);
        const self: *Rig = @alignCast(@fieldParentPtr("clock", clock));
        if (self.delivery_thread.load(.acquire) == std.Thread.getCurrentId())
            self.queue_waiting.set(std.testing.io);
        threaded.io().futexWaitUncancelable(u32, pointer, expected);
    }

    fn writeConfig(self: *Rig, options: *const Rig.Options) !void {
        const io = std.testing.io;
        var directory = try self.tmp.dir.createDirPathOpen(io, ".drinky", .{});
        defer directory.close(io);
        const data = options.config orelse
            "{\"request\":{\"attempts_max\":2,\"delay_ms_initial\":0,\"delay_ms_max\":0}}";
        try directory.writeFile(io, .{ .sub_path = "config.json", .data = data });
    }

    fn writeModel(self: *Rig, name: []const u8, model_accounts: []const usize) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var lists: std.Io.Writer.Allocating = .init(gpa);
        defer lists.deinit();
        var names: std.Io.Writer.Allocating = .init(gpa);
        defer names.deinit();
        for (model_accounts, 0..) |account, index| {
            const separator = if (index == 0) "" else ",";
            const id = accounts.Account.table[account].id;
            try lists.writer.print(
                "{s}\"{s}\":{{\"models\":[{{\"name\":\"{s}\",\"context_window\":400000," ++
                    "\"tokens_max\":32000,\"thinking\":\"supported\",\"efforts\":\"low,high\"}}]}}",
                .{ separator, id, name },
            );
            try names.writer.print("{s}\"{s}\":\"{s}\"", .{ separator, id, name });
        }
        const lists_data = try gpa.print("{{{s}}}", .{lists.written()});
        defer gpa.free(lists_data);
        try self.tmp.dir.writeFile(io, .{ .sub_path = ".drinky/models.json", .data = lists_data });
        const state_data = try gpa.print(
            "{{{f}:{{\"models\":{{{s}}}}}}}",
            .{ std.json.fmt(self.directory, .{}), names.written() },
        );
        defer gpa.free(state_data);
        try self.tmp.dir.writeFile(io, .{ .sub_path = ".drinky/state.json", .data = state_data });
    }

    fn deinit(self: *Rig) void {
        if (self.run_future) |*future| {
            self.device.close();
            future.await(self.clock.io()) catch {};
        }
        if (self.app_live) self.app.deinit();
        self.device.deinit();
        self.transport.deinit();
        self.environment.deinit();
        std.testing.allocator.free(self.directory);
        self.tmp.cleanup();
        self.clock.deinit();
    }

    fn runThenStop(self: *Rig) RunResult {
        defer self.device.stop();
        return self.app.run();
    }

    fn finish(self: *Rig) !void {
        try self.device.waitStop();
        defer self.run_future = null;
        try self.run_future.?.await(self.clock.io());
    }

    fn keys(self: *Rig, bytes: []const u8) !void {
        try self.device.press(bytes);
    }

    fn keyFrame(self: *Rig, bytes: []const u8) !void {
        const slept = self.clock.sleepCount();
        const painted = self.device.frameCount();
        try self.keys(bytes);
        self.advanceTo(try self.clock.waitSleep(slept));
        try self.device.waitFrame(painted);
    }

    fn advanceTo(self: *Rig, deadline_ms: i64) void {
        const now_ms = std.Io.Timestamp.now(self.clock.io(), .awake).toMilliseconds();
        self.clock.advance(@intCast(@max(0, deadline_ms - now_ms)));
    }

    fn waitFor(self: *Rig, sights: []const Sight) !void {
        self.paintUntil(sights) catch |err| {
            self.printMiss(sights);
            return err;
        };
    }

    fn expectSees(self: *Rig, sights: []const Sight) !void {
        if (try self.seesAll(sights)) return;
        self.printMiss(sights);
        return error.TestExpectedSight;
    }

    fn paintUntil(self: *Rig, sights: []const Sight) !void {
        for (0..frames_max) |_| {
            if (try self.seesAll(sights)) return;
            const seen = self.device.frameCount();
            try self.device.resize(self.device.window);
            self.clock.advance(frame_interval_ms);
            try self.device.waitFrame(seen);
        }
        return error.TestFrameNotReached;
    }

    fn seesAll(self: *Rig, sights: []const Sight) !bool {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const snapshot = try self.device.snapshot(arena.allocator());
        for (sights) |*sight| {
            if (!sees(&snapshot, sight)) return false;
        }
        return true;
    }

    fn printMiss(self: *Rig, sights: []const Sight) void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const snapshot = self.device.snapshot(arena.allocator()) catch return;
        std.debug.print("no frame shows every sight:\n", .{});
        for (sights) |*sight| {
            const mark = if (sees(&snapshot, sight)) "  " else "✗ ";
            switch (sight.*) {
                .text => |needle| std.debug.print("{s}text \"{s}\"\n", .{ mark, needle }),
                .absent => |needle| std.debug.print("{s}absent \"{s}\"\n", .{ mark, needle }),
                .line => |line| std.debug.print("{s}line \"{s}\"\n", .{ mark, line }),
                .rows => |needles| for (needles) |needle| {
                    std.debug.print("{s}row \"{s}\"\n", .{ mark, needle });
                },
                .status => |needle| std.debug.print("{s}status \"{s}\"\n", .{ mark, needle }),
                .editor => |text| std.debug.print("{s}editor \"{s}\"\n", .{ mark, text }),
                .alternate_screen => |enabled| {
                    std.debug.print("{s}alternate screen {}\n", .{ mark, enabled });
                },
                .activity => |active| std.debug.print("{s}activity {}\n", .{ mark, active }),
            }
        }
        if (snapshot.alternate) std.debug.print("(alternate screen)\n", .{});
        for (snapshot.rows) |row| std.debug.print("|{s}\n", .{row});
    }

    fn lastRequest(self: *const Rig) []const u8 {
        return self.transport.requests.last().?;
    }

    fn startLoginOf(self: *Rig, account: usize) !void {
        const gpa = std.testing.allocator;
        const id = accounts.Account.table[account].id;
        try self.waitFor(&.{.{ .text = "Sign in · ↑/↓" }});
        for (0..account) |_| try self.keys("\x1b[B");
        const cursor = try gpa.print(" > {s}", .{id});
        defer gpa.free(cursor);
        try self.waitFor(&.{.{ .line = cursor }});
        try self.keys("\r");
        const lead = try gpa.print(authorization_lead ++ "{s}:", .{id});
        defer gpa.free(lead);
        const caption_row = try gpa.print("{s} · ", .{sign_in_titles[account]});
        defer gpa.free(caption_row);
        try self.waitFor(&.{ .{ .text = lead }, .{ .text = caption_row } });
    }

    fn authorizationUrl(self: *Rig) ![]u8 {
        const gpa = std.testing.allocator;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const snapshot = try self.device.snapshot(arena.allocator());
        const start = rowWith(snapshot.rows, "https://") orelse return error.TestExpectedUrl;
        var url: std.ArrayList(u8) = .empty;
        errdefer url.deinit(gpa);
        for (snapshot.rows[start..]) |row| {
            const part = trimmed(row);
            if (part.len == 0) break;
            try url.appendSlice(gpa, part);
        }
        return url.toOwnedSlice(gpa);
    }
};

fn sees(snapshot: *const terminal.testing.FakeDevice.Snapshot, sight: *const Rig.Sight) bool {
    const rows = snapshot.rows;
    return switch (sight.*) {
        .text => |needle| rowWith(rows, needle) != null,
        .absent => |needle| rowWith(rows, needle) == null,
        .line => |line| for (rows) |row| {
            if (std.mem.eql(u8, trimmed(row), line)) break true;
        } else false,
        .rows => |needles| rowsInOrder(rows, needles),
        .status => |needle| statusHolds(rows, needle),
        .editor => |text| editorHolds(rows, text),
        .alternate_screen => |enabled| snapshot.alternate == enabled,
        .activity => |active| (rowWith(rows, "━") != null) == active,
    };
}

fn rowWith(rows: []const []const u8, needle: []const u8) ?usize {
    for (rows, 0..) |row, index| {
        if (std.mem.find(u8, row, needle) != null) return index;
    }
    return null;
}

fn rowsInOrder(rows: []const []const u8, needles: []const []const u8) bool {
    var start: usize = 0;
    for (needles) |needle| {
        const found = rowWith(rows[start..], needle) orelse return false;
        start += found + 1;
    }
    return true;
}

fn trimmed(row: []const u8) []const u8 {
    return std.mem.trimEnd(u8, row, " ");
}

fn borderAbove(rows: []const []const u8, end: usize) ?usize {
    var index = end;
    while (index > 0) {
        index -= 1;
        for ([_][]const u8{ "─", "━", "╼", "╾" }) |glyph| {
            if (std.mem.startsWith(u8, rows[index], glyph)) return index;
        }
    }
    return null;
}

fn statusHolds(rows: []const []const u8, needle: []const u8) bool {
    const bottom = borderAbove(rows, rows.len) orelse return false;
    var buffer: [4096]u8 = undefined;
    var status: std.Io.Writer = .fixed(&buffer);
    for (rows[bottom + 1 ..], 0..) |row, index| {
        if (index > 0) status.writeByte(' ') catch return false;
        status.writeAll(trimmed(row)) catch return false;
    }
    return std.mem.find(u8, status.buffered(), needle) != null;
}

fn editorHolds(rows: []const []const u8, text: []const u8) bool {
    const bottom = borderAbove(rows, rows.len) orelse return false;
    const top = borderAbove(rows, bottom) orelse return false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    for (rows[top + 1 .. bottom]) |row| {
        const line = lines.next() orelse return false;
        if (!std.mem.eql(u8, trimmed(row), line)) return false;
    }
    return lines.next() == null;
}

fn expectRequested(rig: *const Rig, needle: []const u8) !void {
    if (std.mem.find(u8, rig.lastRequest(), needle) != null) return;
    std.debug.print("the last request holds no {s}:\n{s}\n", .{ needle, rig.lastRequest() });
    return error.TestExpectedNeedle;
}

const retry_caption_row = retry_caption.title ++ " · " ++ retry_caption.controls;
const removal_caption_row = removal_caption.title ++ " · " ++ removal_caption.controls;
const canceled_turn_event = "You canceled the turn.";
const overloaded_event = "⚠ The provider is overloaded. Details: 500 Internal Server Error: down";

test "a failed turn ends at the prompt with its event, and the message stays" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{ failed_reply, failed_reply },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "hello", "ℹ Attempt 1 failed.", overloaded_event } },
        .{ .activity = false },
    });
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
}

test "normal shutdown releases a full terminal queue and ignores late mail" {
    var rig: Rig = undefined;
    try rig.init(&.{ .start = false });
    defer rig.deinit();
    const io = std.testing.io;
    const mailbox: application.Mailbox = .{ .ptr = &rig.app, .vtable = &mailbox_vtable };
    for (0..rig.app.queue.capacity()) |_| mailbox.post(.{ .session = .committed });
    var future = try io.concurrent(postBlockedMail, .{&rig});
    defer future.cancel(io);
    try rig.queue_waiting.wait(io);
    rig.app.deinit();
    rig.app_live = false;
    future.await(io);
    mailbox.post(.{ .accounts = .paste_replayed });
    try std.testing.expectError(error.Closed, rig.app.queue.getOne(io));
}

fn postBlockedMail(rig: *Rig) void {
    rig.delivery_thread.store(std.Thread.getCurrentId(), .release);
    defer rig.delivery_thread.store(0, .release);
    const mailbox: application.Mailbox = .{ .ptr = &rig.app, .vtable = &mailbox_vtable };
    mailbox.post(.{ .session = .committed });
}

const failed_reply: providers.testing.FakeTransport.Reply = .{
    .status = .internal_server_error,
    .body = "{\"error\":{\"message\":\"down\"}}",
};

test "a failed turn or retry offers a retry that Esc dismisses and Ctrl+N sends with the draft" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            failed_reply,
            failed_reply,
            failed_reply,
            failed_reply,
            failed_reply,
            failed_reply,
            .{ .body = providers.testing.reply_stream },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try rig.waitFor(&.{ .{ .text = retry_caption_row }, .{ .activity = false } });
    try rig.keys("draft\x1b");
    try rig.waitFor(&.{ .{ .absent = retry_caption_row }, .{ .editor = "draft" } });
    try rig.keys("\x03second\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "second", overloaded_event } },
        .{ .text = retry_caption_row },
        .{ .activity = false },
    });
    try std.testing.expectEqual(@as(usize, 4), rig.transport.requests.items.len);

    try rig.keys("draft\x0e");
    try rig.waitFor(&.{
        .{ .rows = &.{ "second", overloaded_event, retry_note, overloaded_event } },
        .{ .text = retry_caption_row },
        .{ .activity = false },
        .{ .editor = "draft" },
    });
    try expectRequested(
        &rig,
        "\"text\":\"<retry_request>\\nFailure: overloaded\\nDetails: 500 Internal Server " ++
            "Error: down\\nContinue from the last committed checkpoint.\\n</retry_request>\"",
    );
    try rig.keys("\x0e");
    try rig.waitFor(&.{
        .{ .rows = &.{ retry_note, retry_note, "done" } },
        .{ .absent = retry_caption_row },
        .{ .activity = false },
        .{ .editor = "draft" },
    });
    try std.testing.expectEqual(@as(usize, 7), rig.transport.requests.items.len);
}

test "Ctrl+N removes a canceled turn, keeps the later events, and returns its line to the editor" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .stall = &stall },
        .{ .body = providers.testing.reply_stream },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("fix it\r");
    try stall.reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.waitFor(&.{ .{ .text = removal_caption_row }, .{ .activity = false } });
    try rig.keys("/effort\r");
    try rig.waitFor(&.{.{ .text = effort_picker }});
    try rig.keys("\x1b[A\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "fix it", canceled_turn_event, "Drinky set the effort level to " } },
        .{ .text = removal_caption_row },
    });

    try rig.keys("\x0e");
    try rig.waitFor(&.{
        .{ .absent = removal_caption_row },
        .{ .absent = canceled_turn_event },
        .{ .text = "Drinky set the effort level to " },
        .{ .editor = "fix it" },
    });
    try rig.keys("\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "Drinky set the effort level to ", "fix it", "done" } },
        .{ .activity = false },
    });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rig.lastRequest(), "fix it"));
}

test "Ctrl+N warns before it removes a canceled turn that ran a mutating tool" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = application.testing.write_call_stream },
        .{ .stall = &stall },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("fix it\r");
    try stall.reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.waitFor(&.{ .{ .text = removal_caption_row }, .{ .activity = false } });
    try rig.keys("\x0e");
    try rig.waitFor(&.{.{ .status = removal_warning }});
    try rig.keys("x\x0e");
    try rig.waitFor(&.{
        .{ .status = removal_warning },
        .{ .editor = "x" },
        .{ .text = canceled_turn_event },
    });
    try rig.keys("\x0e");
    try rig.waitFor(&.{
        .{ .absent = canceled_turn_event },
        .{ .absent = removal_caption_row },
        .{ .editor = "fix it\nx" },
    });
}

test "a canceled retry offers no removal, and a new turn and /new drop the offer" {
    var stalls: [3]providers.testing.FakeTransport.Stall = @splat(.{ .io = std.testing.io });
    const replies = [_]providers.testing.FakeTransport.Reply{
        failed_reply,
        failed_reply,
        .{ .stall = &stalls[0] },
        .{ .stall = &stalls[1] },
        .{ .body = providers.testing.reply_stream },
        .{ .stall = &stalls[2] },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("first\r");
    try rig.waitFor(&.{ .{ .text = retry_caption_row }, .{ .activity = false } });
    try rig.keys("\x0e");
    try stalls[0].reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.waitFor(&.{
        .{ .rows = &.{ retry_note, canceled_turn_event } },
        .{ .activity = false },
        .{ .absent = removal_caption_row },
        .{ .absent = retry_caption_row },
    });

    try rig.keys("second\r");
    try stalls[1].reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.waitFor(&.{
        .{ .rows = &.{ "second", canceled_turn_event } },
        .{ .text = removal_caption_row },
    });
    try rig.keys("third\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "third", "done" } },
        .{ .activity = false },
        .{ .absent = removal_caption_row },
    });

    try rig.keys("fourth\r");
    try stalls[2].reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.waitFor(&.{
        .{ .rows = &.{ "fourth", canceled_turn_event } },
        .{ .text = removal_caption_row },
    });
    try rig.keys("/new\r");
    try rig.waitFor(&.{ .{ .absent = "fourth" }, .{ .absent = removal_caption_row } });
}

test "Ctrl+N returns the command line of a canceled skill turn" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{.{ .stall = &stall }};
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .files = &.{.{
            ".agents/skills/demo/SKILL.md",
            "---\nname: demo\ndescription: Demo.\n---\nBody.\n",
        }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("/skill:demo apply it\r");
    try stall.reached.wait(std.testing.io);
    try rig.keys("\x04");
    try rig.waitFor(&.{ .{ .text = removal_caption_row }, .{ .activity = false } });
    try rig.keys("\x0e");
    try rig.waitFor(&.{
        .{ .absent = canceled_turn_event },
        .{ .absent = removal_caption_row },
        .{ .editor = "/skill:demo apply it" },
    });
}

const rewind_picker = "Prompt · ↑/↓";
const effort_event = "Drinky set the effort level to ";

test "/rewind returns the chosen prompt to the editor and drops its turn and every later turn" {
    const replies: [4]providers.testing.FakeTransport.Reply =
        @splat(.{ .body = providers.testing.reply_stream });
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("first\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "first", "done" } }, .{ .activity = false } });
    try rig.keys("second\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "first", "second", "done" } }, .{ .activity = false } });
    try rig.keys("/effort\r");
    try rig.waitFor(&.{.{ .text = effort_picker }});
    try rig.keys("\x1b[A\r");
    try rig.waitFor(&.{.{ .text = effort_event }});
    try rig.keys("third\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "second", "done", effort_event, "third", "done" } },
        .{ .activity = false },
    });

    try rig.keys("/rewind\r");
    try rig.waitFor(&.{
        .{ .text = rewind_picker },
        .{ .rows = &.{ "   first", "   second", " > third" } },
    });
    try rig.keys("\x1b[A\r");
    try rig.waitFor(&.{
        .{ .absent = rewind_picker },
        .{ .absent = "third" },
        .{ .rows = &.{ "first", "done", effort_event } },
        .{ .editor = "second" },
    });
    try rig.keys("\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "first", "done", effort_event, "second", "done" } },
        .{ .activity = false },
    });
    try std.testing.expectEqual(@as(usize, 4), rig.transport.requests.items.len);
    try expectRequested(&rig, "\"text\":\"first\"");
    const request = rig.lastRequest();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, request, "\"text\":\"second\""));
    try std.testing.expect(std.mem.find(u8, request, "\"text\":\"third\"") == null);
}

test "/rewind warns before it drops a turn that ran a mutating tool" {
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = application.testing.write_call_stream },
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.reply_stream },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("fix it\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "fix it", "done" } }, .{ .activity = false } });
    try rig.keys("next\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "fix it", "next", "done" } }, .{ .activity = false } });

    try rig.keys("/rewind\r");
    try rig.waitFor(&.{.{ .text = rewind_picker }});
    try rig.keys("\x1b[A\r");
    try rig.waitFor(&.{ .{ .status = rewind_warning }, .{ .line = " > fix it" } });
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .absent = rewind_picker },
        .{ .status = "You canceled the prompt selection." },
        .{ .rows = &.{ "fix it", "next", "done" } },
    });

    try rig.keys("/rewind\r");
    try rig.waitFor(&.{.{ .text = rewind_picker }});
    try rig.keys("\x1b[A\r");
    try rig.waitFor(&.{ .{ .status = rewind_warning }, .{ .line = " > fix it" } });
    try rig.keys("\x1b[B\x1b[A");
    try rig.waitFor(&.{ .{ .absent = rewind_warning }, .{ .line = " > fix it" } });
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .status = rewind_warning }, .{ .text = rewind_picker } });
    try rig.keys("\r");
    try rig.waitFor(&.{
        .{ .absent = rewind_picker },
        .{ .absent = "next" },
        .{ .editor = "fix it" },
    });
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "fix it", "done" } }, .{ .activity = false } });
    try std.testing.expectEqual(@as(usize, 4), rig.transport.requests.items.len);
    try expectRequested(&rig, "\"text\":\"fix it\"");
    try std.testing.expect(std.mem.find(u8, rig.lastRequest(), "\"text\":\"next\"") == null);
}

test "a signed-out submit and a submit without a model are refused with a notice" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.waitFor(&.{.{ .text = "Sign in · ↑/↓" }});
    try rig.keys("\x03");
    try rig.waitFor(&.{.{ .status = "You canceled the sign-in selection." }});
    try rig.keys("hello\r");
    try rig.waitFor(&.{
        .{ .status = "Sign in with /login before you send a message." },
        .{ .editor = "hello" },
    });

    var keyed: Rig = undefined;
    try keyed.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer keyed.deinit();
    try keyed.waitFor(&.{.{ .status = "Model: openai-api-key/none" }});
    try keyed.keys("hello\r");
    try keyed.waitFor(&.{
        .{ .status = "Select a model with /model before you send a message." },
        .{ .editor = "hello" },
    });
}

const effort_picker = "Effort · ↑/↓";

test "a slash command opens its picker, a pick applies, and Esc leaves with a notice" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("/effort\r");
    try rig.waitFor(&.{.{ .text = effort_picker }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .absent = effort_picker },
        .{ .status = "You canceled the effort selection." },
    });

    try rig.keys("/effort\r");
    try rig.waitFor(&.{ .{ .text = effort_picker }, .{ .text = " > xhigh" } });
    try rig.keys(core.text.repeat("\x1b[A", 3) ++ "\x1b[B" ++ "\x1b[A");
    try rig.waitFor(&.{.{ .text = " > low" }});
    try rig.keys("\r");
    try rig.waitFor(&.{
        .{ .absent = effort_picker },
        .{ .status = "Effort: low" },
        .{ .text = "Drinky set the effort level to low." },
    });
    try rig.keys("hello\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "hello", "done" } }, .{ .activity = false } });
    try expectRequested(&rig, "\"effort\":\"low\"");
}

test "a pending callback submission cancels the active sign-in" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.startLoginOf(accounts.testing.anthropic_plan);
    try rig.keys("not a callback\r\x04");
    try rig.waitFor(&.{
        .{ .text = "You canceled the sign-in to anthropic-plan." },
        .{ .editor = "not a callback" },
    });
    try std.testing.expectEqual(@as(?u16, null), rig.loopback.listening());
}

test "a lone Esc waits 50 ms and repaints without a resize" {
    for ([_]i64{ 49, 50 }) |elapsed_ms| {
        var rig: Rig = undefined;
        try rig.init(&.{
            .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
            .model = "gpt-5.6-sol",
        });
        defer rig.deinit();
        try rig.keys("/effort\r");
        try rig.waitFor(&.{.{ .text = effort_picker }});
        try rig.keyFrame("\x00");

        rig.clock.advance(@intCast(4 * Rig.frame_interval_ms - elapsed_ms));
        const started_ms = std.Io.Timestamp.now(rig.clock.io(), .awake).toMilliseconds();
        var slept = rig.clock.sleepCount();
        try rig.keys("\x1b");
        var deadline_ms = try rig.clock.waitSleep(slept);
        for (0..3) |_| {
            slept = rig.clock.sleepCount();
            rig.advanceTo(deadline_ms);
            deadline_ms = try rig.clock.waitSleep(slept);
            try rig.expectSees(&.{.{ .text = effort_picker }});
        }
        try std.testing.expectEqual(elapsed_ms, deadline_ms - started_ms);

        slept = rig.clock.sleepCount();
        const painted = rig.device.frameCount();
        rig.advanceTo(deadline_ms);
        if (elapsed_ms == 49) {
            deadline_ms = try rig.clock.waitSleep(slept);
            try rig.expectSees(&.{.{ .text = effort_picker }});
            rig.advanceTo(deadline_ms);
        }
        try rig.device.waitFrame(painted);
        try rig.waitFor(&.{
            .{ .absent = effort_picker },
            .{ .status = "You canceled the effort selection." },
        });
    }
}

test "an arrow sequence split within the Esc delay stays one key" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("/effort\r");
    try rig.waitFor(&.{ .{ .text = effort_picker }, .{ .text = " > xhigh" } });
    try rig.keyFrame("\x00");

    var slept = rig.clock.sleepCount();
    try rig.keys("\x1b");
    var deadline_ms = try rig.clock.waitSleep(slept);
    slept = rig.clock.sleepCount();
    const painted = rig.device.frameCount();
    rig.advanceTo(deadline_ms);
    try rig.device.waitFrame(painted);
    deadline_ms = try rig.clock.waitSleep(slept);
    try rig.expectSees(&.{ .{ .text = effort_picker }, .{ .text = " > xhigh" } });

    const moved = rig.device.frameCount();
    try rig.keys("[A");
    rig.advanceTo(deadline_ms);
    try rig.device.waitFrame(moved);
    try rig.expectSees(&.{ .{ .text = effort_picker }, .{ .text = " > high" } });
    rig.clock.advance(50);
    try rig.keyFrame("\x00");
    try rig.expectSees(&.{ .{ .text = effort_picker }, .{ .text = " > high" } });
}

test "Ctrl+C and Ctrl+D in a picker end its command with its notice" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    for ([_][]const u8{ "\x03", "\x04" }) |exit_key| {
        try rig.keys("/effort\r");
        try rig.waitFor(&.{.{ .text = effort_picker }});
        try rig.keys(exit_key);
        try rig.waitFor(&.{
            .{ .absent = effort_picker },
            .{ .status = "You canceled the effort selection." },
        });
    }
    try rig.keys("x");
    try rig.waitFor(&.{.{ .editor = "x" }});
}

const refusal_offer = "Enter: Send as a message";

test "a refused command line reaches the model on the next Enter" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("/nope\r");
    try rig.waitFor(&.{
        .{ .status = refusal_offer ++ " · Drinky does not recognize the command" },
        .{ .editor = "/nope" },
    });
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "/nope", "done" } }, .{ .activity = false } });
    try expectRequested(&rig, "\"text\":\"/nope\"");
}

test "a dismissed command confirmation stays absent after a terminal snapshot" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "key" }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("/nope\r");
    try rig.waitFor(&.{.{ .status = refusal_offer }});
    try rig.keys("x");
    try rig.waitFor(&.{ .{ .editor = "/nopex" }, .{ .absent = refusal_offer } });
    try rig.keys("\x03\x04");
    try rig.finish();
    _ = rig.app.controller.submit(&.snapshot);
    try rig.app.screen.paint(rig.device.window, .{ .awake_ms = 0, .boot_ms = 0 }, &null);
    try rig.expectSees(&.{.{ .absent = refusal_offer }});
}

test "a command that its state refuses keeps its line" {
    const cases = [_]struct { line: []const u8, refusal: []const u8 }{
        .{ .line = "/model", .refusal = "Sign in to an account" },
        .{ .line = "/logout", .refusal = "No accounts are signed in." },
        .{ .line = "/skill", .refusal = "Drinky found no skill." },
        .{ .line = "/rewind", .refusal = "No prompts are in the conversation." },
    };
    for (&cases) |case| {
        var rig: Rig = undefined;
        try rig.init(&.{});
        defer rig.deinit();
        try rig.waitFor(&.{.{ .text = "Sign in · ↑/↓" }});
        try rig.keys("\x03");
        try rig.waitFor(&.{.{ .status = "You canceled the sign-in selection." }});
        try rig.keys(case.line);
        try rig.keys("\r");
        try rig.waitFor(&.{ .{ .status = case.refusal }, .{ .editor = case.line } });
    }
}

test "/new clears the conversation, and the next request starts fresh" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.reply_stream },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("first\r");
    try rig.waitFor(&.{
        .{ .rows = &.{ "first", "done" } },
        .{ .activity = false },
        .{ .status = "(12/400k)" },
    });

    try rig.keys("/new\r");
    try rig.waitFor(&.{
        .{ .absent = "first" },
        .{ .absent = "done" },
        .{ .text = "/help: Commands" },
        .{ .status = "(0/400k)" },
    });
    try rig.keys("/rewind\r");
    try rig.waitFor(&.{
        .{ .status = "No prompts are in the conversation." },
        .{ .editor = "/rewind" },
    });

    try rig.keys("\x03second\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "second", "done" } }, .{ .activity = false } });
    try std.testing.expect(std.mem.find(u8, rig.lastRequest(), "\"text\":\"first\"") == null);
    try expectRequested(&rig, "\"text\":\"second\"");
}

test "startup verbosity selects thinking text or summaries at the terminal boundary" {
    const body = "data: {\"type\":\"response.reasoning_summary_text.delta\"," ++
        "\"item_id\":\"rs_1\",\"summary_index\":0,\"delta\":\"visible thinking\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":" ++
        "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\"," ++
        "\"text\":\"visible thinking\"}],\"encrypted_content\":\"proof\"}}\n\n" ++
        providers.testing.reply_stream;
    const cases = [_]struct { config: []const u8, verbose: bool }{
        .{ .config = "{}", .verbose = false },
        .{ .config = "{\"interface\":{\"verbose\":true}}", .verbose = true },
        .{ .config = "{\"interface\":{\"verbose\":false}}", .verbose = false },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        try rig.init(&.{
            .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
            .config = case.config,
            .replies = &.{.{ .body = body }},
            .model = "gpt-5.6-sol",
        });
        defer rig.deinit();
        try rig.keys("hello\r");
        const shown = if (case.verbose) "visible thinking" else "Agent: work (complete)";
        const hidden = if (case.verbose) "Agent: work" else "visible thinking";
        try rig.waitFor(&.{
            .{ .rows = &.{ "hello", shown, "done" } },
            .{ .absent = hidden },
            .{ .activity = false },
        });
        try rig.keys("/verbose\r");
        try rig.waitFor(&.{
            .{ .rows = &.{ "hello", hidden, "done" } },
            .{ .absent = shown },
            .{ .editor = "" },
            .{ .activity = false },
        });
        try rig.keys("/rewind\r");
        try rig.waitFor(&.{.{ .text = rewind_picker }});
        try rig.keys("\r");
        try rig.waitFor(&.{
            .{ .absent = "visible thinking" },
            .{ .absent = "Agent: work" },
            .{ .absent = "done" },
            .{ .editor = "hello" },
        });
        try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
    }
}

test "verbose uses the startup config and toggles during a turn without sending a message" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{\"interface\":{\"verbose\":false}}",
        .replies = &.{.{ .body = providers.testing.reply_stream, .hold = &hold }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    defer hold.released.set(std.testing.io);
    try rig.keys("/verbose\r");
    try rig.waitFor(&.{ .{ .status = "Verbose output is on." }, .{ .editor = "" } });
    try rig.keys("hello\r");
    try hold.reached.wait(std.testing.io);
    try rig.keys("/verbose\r");
    try rig.waitFor(&.{
        .{ .status = "Verbose output is off." },
        .{ .editor = "" },
        .{ .activity = true },
    });
    try rig.keys("/verbose\r");
    try rig.waitFor(&.{
        .{ .status = "Verbose output is on." },
        .{ .editor = "" },
        .{ .activity = true },
    });
    hold.released.set(std.testing.io);
    try rig.waitFor(&.{ .{ .rows = &.{ "hello", "done" } }, .{ .activity = false } });
    try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
    try std.testing.expect(std.mem.find(u8, rig.lastRequest(), "\"text\":\"/verbose\"") == null);
    const configured = try rig.tmp.dir.readFileAlloc(
        rig.clock.io(),
        ".drinky/config.json",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(configured);
    try std.testing.expectEqualStrings(
        "{\"interface\":{\"verbose\":false}}",
        configured,
    );
}

test "command lines during a turn get a notice and keep the draft" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream, .hold = &hold }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    defer hold.released.set(std.testing.io);
    try rig.keys("hello\r");
    try hold.reached.wait(std.testing.io);
    try rig.keys("/verbose extra\r");
    try rig.waitFor(&.{
        .{ .status = "The command /verbose takes no argument." },
        .{ .editor = "/verbose extra" },
        .{ .activity = true },
    });
    try rig.keys("\x03/model\r");
    try rig.waitFor(&.{
        .{ .status = "The command /model cannot run while a turn runs." },
        .{ .editor = "/model" },
        .{ .activity = true },
    });
    try rig.keys("\x03/\r");
    try rig.waitFor(&.{
        .{ .status = "Commands during a turn: /mcp, /verbose." },
        .{ .editor = "/" },
        .{ .activity = true },
    });
}

test "Enter during a turn keeps the text, and Ctrl+D with a draft warns before it quits" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = providers.testing.reply_stream, .hold = &hold },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("hello\r");
    try hold.reached.wait(std.testing.io);
    try rig.keys("more\r");
    try rig.waitFor(&.{
        .{ .status = turn_message_notice },
        .{ .editor = "more" },
        .{ .activity = true },
    });
    hold.released.set(std.testing.io);
    try rig.waitFor(&.{
        .{ .rows = &.{ "hello", "done" } },
        .{ .activity = false },
        .{ .editor = "more" },
    });

    try rig.keys("\x04");
    try rig.waitFor(&.{.{ .status = "Press Ctrl+D again to quit. The quit discards the draft." }});
    try rig.keys("\x04");
    try rig.finish();
}

const quit_warning = "Press Ctrl+D again to quit.";

test "a Ctrl+D that ends a turn or closes a page warns before the next Ctrl+D quits" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = providers.testing.reply_stream, .hold = &hold },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try hold.reached.wait(std.testing.io);
    try rig.keys("\x04x");
    try rig.waitFor(&.{ .{ .editor = "x" }, .{ .activity = true } });
    hold.released.set(std.testing.io);
    try rig.waitFor(&.{ .{ .activity = false }, .{ .editor = "x" } });
    try rig.keys("\x7f");
    try rig.waitFor(&.{.{ .editor = "" }});
    try rig.keys("\x04");
    try rig.waitFor(&.{.{ .status = quit_warning }});
    try rig.keys("\x03");

    try rig.keys("/system\r");
    try rig.waitFor(&.{.{ .alternate_screen = true }});
    try rig.keys("\x04");
    try rig.waitFor(&.{.{ .alternate_screen = false }});
    try rig.keys("\x04");
    try rig.waitFor(&.{.{ .status = quit_warning }});
    try rig.keys("\x04");
    try rig.finish();
}

test "a notice that replaces the send offer of a refused command line withdraws the offer" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("/nope\r");
    try rig.waitFor(&.{.{ .status = refusal_offer }});
    try rig.keys("\x04");
    try rig.waitFor(&.{.{ .status = "Press Ctrl+D again to quit." }});
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .status = refusal_offer }, .{ .editor = "/nope" } });
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "/nope", "done" } }, .{ .activity = false } });
    try expectRequested(&rig, "\"text\":\"/nope\"");
}

const authorization_lead = "Open this URL to authorize the sign-in to ";
const denied_login_event = "The provider did not authorize Drinky. Start the sign-in again.";
const anthropic_plan_caption = "Sign in: anthropic-plan · ";

fn urlParameter(url: []const u8, comptime name: []const u8) ![]const u8 {
    const start = (std.mem.find(u8, url, "&" ++ name ++ "=") orelse
        return error.TestExpectedParameter) + name.len + 2;
    const end = std.mem.findScalarPos(u8, url, start, '&') orelse url.len;
    return url[start..end];
}

test "a sign-in shows its URL, and a pasted callback line reaches its listener" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();

    try rig.startLoginOf(anthropic_plan);
    try rig.waitFor(&.{
        .{ .rows = &.{
            "ℹ Open this URL to authorize the sign-in to anthropic-plan:",
            "https://claude.ai/oauth/authorize?",
            "paste the callback URL from its address bar and press Enter.",
        } },
        .{ .status = "Drinky could not open the browser for the sign-in to anthropic-plan." },
    });

    const wrong_line = "http://localhost:53692/callback?error=access_denied&state=unknown";
    try rig.keys(wrong_line);
    try rig.waitFor(&.{.{ .editor = wrong_line }});
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .editor = "" }, .{ .text = anthropic_plan_caption } });

    const url = try rig.authorizationUrl();
    defer std.testing.allocator.free(url);
    const line = try std.testing.allocator.print(
        "http://localhost:53692/callback?error=access_denied&state={s}\r",
        .{try urlParameter(url, "state")},
    );
    defer std.testing.allocator.free(line);
    try rig.keys(line);
    try rig.waitFor(&.{
        .{ .text = denied_login_event },
        .{ .absent = anthropic_plan_caption },
        .{ .editor = "" },
    });
}

test "a sign-in with a callback path takes a pasted line of that path alone" {
    const openrouter_login = accounts.Account.index("openrouter-api").?;
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();

    try rig.startLoginOf(openrouter_login);
    try rig.waitFor(&.{.{ .rows = &.{
        "ℹ Open this URL to authorize the sign-in to openrouter-api:",
        "https://openrouter.ai/auth?callback_url=",
    } }});
    const url = try rig.authorizationUrl();
    defer std.testing.allocator.free(url);
    const encoded_prefix = "localhost%3A53694%2F";
    const path_start = std.mem.find(u8, url, encoded_prefix).? + encoded_prefix.len;
    const after_prefix = url[path_start..];
    const hex_end = std.mem.findNone(u8, after_prefix, "0123456789abcdef") orelse
        after_prefix.len;
    const callback_hex = after_prefix[0..hex_end];

    try rig.keys("http://localhost:53694/elsewhere?error=access_denied\r");
    try rig.waitFor(&.{
        .{ .status = "The line is not the callback URL for the sign-in to openrouter-api." },
        .{ .text = "Sign in: openrouter-api · " },
    });

    const line = try std.testing.allocator.print(
        "\x03http://localhost:53694/{s}?error=access_denied\r",
        .{callback_hex},
    );
    defer std.testing.allocator.free(line);
    try rig.keys(line);
    try rig.waitFor(&.{
        .{ .text = denied_login_event },
        .{ .absent = "Sign in: openrouter-api · " },
    });
}

test "a completed sign-in reports a memory-only save and opens the model step" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    var rig: Rig = undefined;
    try rig.init(&.{
        .replies = &.{.{
            .body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":3600}",
        }},
        .window = .{ .columns = 400, .rows = 40 },
    });
    defer rig.deinit();
    var blocked = try rig.tmp.dir.createDirPathOpen(std.testing.io, ".drinky/auth.json", .{});
    blocked.close(std.testing.io);

    try rig.startLoginOf(anthropic_plan);
    const url = try rig.authorizationUrl();
    defer std.testing.allocator.free(url);
    const line = try std.testing.allocator.print(
        "http://localhost:53692/callback?code=abc&state={s}\r",
        .{try urlParameter(url, "state")},
    );
    defer std.testing.allocator.free(line);
    try rig.keys(line);
    try rig.waitFor(&.{
        .{ .text = "Drinky signed in to anthropic-plan." },
        .{ .text = "Drinky could not save the credentials for anthropic-plan to " },
        .{ .text = "The sign-in stays active until Drinky exits." },
        .{ .text = "Model: anthropic-plan · ↑/↓" },
    });
}

test "a paste after the listener closed clears the editor with a notice" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    rig.loopback.refuses = true;

    try rig.startLoginOf(anthropic_plan);
    try rig.keys("http://localhost:53692/callback?code=abc&state=any\r");
    try rig.waitFor(&.{
        .{ .status = "Drinky already received the response for the sign-in to anthropic-plan." },
        .{ .editor = "" },
        .{ .text = anthropic_plan_caption },
    });
}

test "an edit after a pasted callback keeps the draft when the callback arrives" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    rig.loopback.refuses = true;

    try rig.startLoginOf(anthropic_plan);
    const callback = "http://localhost:53692/callback?code=abc&state=any";
    try rig.keys(callback ++ "\rx");
    try rig.waitFor(&.{
        .{ .status = "Drinky already received the response for the sign-in to anthropic-plan." },
        .{ .editor = callback ++ "x" },
    });
}

test "Esc with a draft warns before it cancels the turn, and Ctrl+D cancels at once" {
    var stalls: [2]providers.testing.FakeTransport.Stall = @splat(.{ .io = std.testing.io });
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .stall = &stalls[0] },
        .{ .stall = &stalls[1] },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try stalls[0].reached.wait(std.testing.io);
    try rig.keys("draft\x1b");
    try rig.waitFor(&.{
        .{ .status = turn_cancel_notice },
        .{ .editor = "draft" },
        .{ .activity = true },
    });
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .rows = &.{ "hello", canceled_turn_event } },
        .{ .activity = false },
        .{ .editor = "draft" },
    });
    try std.testing.expect(stalls[0].canceled);

    try rig.keys("\r");
    try stalls[1].reached.wait(std.testing.io);
    try rig.keys("more\x04");
    try rig.waitFor(&.{
        .{ .rows = &.{ "draft", canceled_turn_event } },
        .{ .activity = false },
        .{ .editor = "more" },
    });
    try std.testing.expect(stalls[1].canceled);
}

test "Esc in a turn clears another notice first, and Ctrl+C clears a draft before it cancels" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{.{ .stall = &stall }};
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try stall.reached.wait(std.testing.io);
    try rig.keys("more\r");
    try rig.waitFor(&.{.{ .status = turn_message_notice }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{ .{ .status = "Model: openai-api-key/" }, .{ .activity = true } });
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .status = turn_cancel_notice }});
    try rig.keys("x\x1b");
    try rig.waitFor(&.{ .{ .status = turn_cancel_notice }, .{ .editor = "morex" } });

    try rig.keys("\x03");
    try rig.waitFor(&.{ .{ .editor = "" }, .{ .activity = true } });
    try rig.keys("\x03");
    try rig.waitFor(&.{ .{ .text = canceled_turn_event }, .{ .activity = false } });
    try std.testing.expect(stall.canceled);
}

test "Esc and Ctrl+D cancel a sign-in and keep the draft" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    for ([_][]const u8{ "\x1b", "\x04" }) |exit_key| {
        var rig: Rig = undefined;
        try rig.init(&.{});
        defer rig.deinit();
        try rig.startLoginOf(anthropic_plan);
        try rig.keys("draft");
        try rig.keys(exit_key);
        try rig.waitFor(&.{
            .{ .text = "You canceled the sign-in to anthropic-plan." },
            .{ .absent = anthropic_plan_caption },
            .{ .editor = "draft" },
        });
    }
}

test "Ctrl+C in a sign-in clears the draft first and cancels at an empty editor" {
    const anthropic_plan = accounts.Account.index("anthropic-plan").?;
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.startLoginOf(anthropic_plan);
    try rig.keys("draft");
    try rig.waitFor(&.{.{ .editor = "draft" }});
    try rig.keys("\x03");
    try rig.waitFor(&.{ .{ .editor = "" }, .{ .text = anthropic_plan_caption } });
    try rig.keys("\x03");
    try rig.waitFor(&.{
        .{ .text = "You canceled the sign-in to anthropic-plan." },
        .{ .absent = anthropic_plan_caption },
    });
}

test "exit keys during a slow cancel cannot block the end of the turn" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = providers.testing.reply_stream, .hold = &hold },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try hold.reached.wait(std.testing.io);
    try rig.keys(core.text.repeat("\x04", 65) ++ "x");
    try rig.waitFor(&.{ .{ .editor = "x" }, .{ .activity = true } });
    hold.released.set(std.testing.io);
    try rig.waitFor(&.{ .{ .activity = false }, .{ .editor = "x" } });
}

test "the login picker opens with the accounts, and a set key account switches at once" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{ .{ "OPENAI_API_KEY", "sk-openai" }, .{ "XAI_API_KEY", "xai" } },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("/login\r");
    try rig.waitFor(&.{ .{ .text = "Sign in · ↑/↓" }, .{ .text = " > openai-api-key" } });
    try rig.keys("\x1b[B\x1b[B\r");
    try rig.waitFor(&.{
        .{ .absent = "Sign in · ↑/↓" },
        .{ .status = "Model: xai-api-key/none" },
        .{ .text = "Drinky now uses xai-api-key. " ++
            "Fetch the model list of xai-api-key with /model." },
    });
}

test "the start reports each dropped config value and each notice" {
    const rule = "{\"glob\":\"*.md\",\"skill\":\"docs\"}";
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{\"default_effort\":\"turbo\",\"bash\":{\"timeout_ms\":1}," ++
            "\"interface\":{\"window_pages\":0,\"gauge_percent_warning\":90," ++
            "\"gauge_percent_error\":10},\"user_instructions\":[{\"path\":\"missing.md\"}]," ++
            "\"required_skills\":[" ++ core.text.repeat(rule ++ ",", tools.SkillGuard.rules_max) ++
            rule ++ "]," ++
            "\"mystery\":1}",
        .files = &.{
            .{ ".agents/skills/broken/SKILL.md", "no front matter" },
            .{
                ".agents/skills/docs/SKILL.md",
                "---\nname: docs\ndescription: Docs.\n---\nBody.\n",
            },
        },
        .window = .{ .columns = 400, .rows = 60 },
    });
    defer rig.deinit();
    try rig.waitFor(&.{
        .{ .absent = "↑/↓: Move" },
        .{ .text = "Drinky ignored the configured default effort level \"turbo\" because Drinky " ++
            "does not know that level. Drinky uses the effort level \"xhigh\"." },
        .{ .text = "Drinky ignored the configured command timeout 1 because" },
        .{ .text = "Drinky ignored the configured window page count 0 because the count must " ++
            "be from 1 to 64. Drinky uses the default count of 8 pages." },
        .{ .text = "Drinky ignored the gauge shares 90 and 10." },
        .{ .text = "Drinky ignored the unknown config key \"mystery\" in " },
        .{ .text = "missing.md" },
        .{ .text = "because the YAML front matter is missing." },
        .{ .text = "Drinky used only the first 64 required skills in " },
    });

    var corrupt: Rig = undefined;
    try corrupt.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{ not json",
        .window = .{ .columns = 400, .rows = 40 },
    });
    defer corrupt.deinit();
    try corrupt.waitFor(&.{
        .{ .text = "Drinky could not read the config file " },
        .{ .text = "Drinky uses the default value of each key." },
    });
}

test "the start escapes a control character in an unknown config key" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{\"\\u001b[2J\":1}",
    });
    defer rig.deinit();
    try rig.waitFor(&.{.{ .text = "Drinky ignored the unknown config key \"\\x1b[2J\" in " }});
}

test "a start without an account opens the sign-in picker with a notice" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.waitFor(&.{
        .{ .text = "Sign in · ↑/↓" },
        .{ .status = "Select an account to sign in." },
    });
}

test "an exit key that closes a page drops the rest of its read" {
    var rig: Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer rig.deinit();
    try rig.keys("/system\r");
    try rig.waitFor(&.{.{ .alternate_screen = true }});
    try rig.keys("\x04abc");
    try rig.waitFor(&.{ .{ .alternate_screen = false }, .{ .editor = "" } });
    try rig.keys("abc");
    try rig.waitFor(&.{.{ .editor = "abc" }});
}

test "Ctrl+C clears the draft, and a second Ctrl+C at once quits" {
    var rig: Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer rig.deinit();
    try rig.keys("draft");
    try rig.waitFor(&.{.{ .editor = "draft" }});
    try rig.keys("\x03");
    try rig.waitFor(&.{.{ .editor = "" }});
    try rig.keys("\x03");
    try rig.finish();
}

const model_picker = "Model: openai-api-key · ↑/↓";

test "Esc ends a model fetch at its step, and Ctrl+C ends the whole command" {
    var step_stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var command_stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{ .{ .stall = &step_stall }, .{ .stall = &command_stall } },
    });
    defer rig.deinit();

    try rig.keys("/model\r");
    try rig.waitFor(&.{.{ .text = model_picker }});
    try rig.keys("\r");
    try step_stall.reached.wait(std.testing.io);
    try rig.waitFor(&.{
        .{ .absent = model_picker },
        .{ .text = Flow.fetch_wait_text },
    });
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .text = model_picker },
        .{ .absent = Flow.fetch_wait_text },
        .{ .status = "You canceled the model fetch." },
    });
    try std.testing.expect(step_stall.canceled);

    try rig.keys("\r");
    try command_stall.reached.wait(std.testing.io);
    try rig.waitFor(&.{.{ .text = Flow.fetch_wait_text }});
    try rig.keys("\x03");
    try rig.waitFor(&.{
        .{ .absent = "Model: openai-api-key · " },
        .{ .absent = Flow.fetch_wait_text },
        .{ .status = "You canceled the model selection." },
    });
    try std.testing.expect(command_stall.canceled);
}

test "help keeps its command position across nested steps and fetch cancellations" {
    var stalls: [2]providers.testing.FakeTransport.Stall = @splat(.{ .io = std.testing.io });
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{ .{ .stall = &stalls[0] }, .{ .stall = &stalls[1] } },
    });
    defer rig.deinit();
    const help_caption = "Command · ↑/↓: Move · Enter: Select · Esc: Cancel";
    const model_caption = "Model: openai-api-key · ↑/↓: Move · Enter: Select · Esc: Back";
    try rig.keys("/help\r");
    try rig.waitFor(&.{.{ .text = help_caption }});
    try rig.keys(core.text.repeat("\x1b[B", 5));
    try rig.waitFor(&.{.{ .text = " > /model" }});
    try rig.keys("\r");
    try rig.waitFor(&.{.{ .text = model_caption }});
    for (&stalls) |*stall| {
        try rig.keys("\r");
        try stall.reached.wait(std.testing.io);
        try rig.waitFor(&.{.{ .text = Flow.fetch_wait_text }});
        try rig.keys("\x1b");
        try rig.waitFor(&.{
            .{ .text = model_caption },
            .{ .status = "You canceled the model fetch." },
        });
        try std.testing.expect(stall.canceled);
    }
    try rig.keys("\x1b");
    try rig.waitFor(&.{ .{ .text = help_caption }, .{ .text = " > /model" } });
    try rig.keys("\r");
    try rig.waitFor(&.{.{ .text = "Model: openai-api-key · ↑/↓" }});
    try rig.keys("\x03");
    try rig.waitFor(&.{
        .{ .absent = "Model: openai-api-key · " },
        .{ .status = "You canceled the model selection." },
    });
}

test "a completed model fetch reopens its step with the fetched models" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .store = accounts.testing.planStore("first"),
        .replies = &.{
            .{ .body = application.testing.plan_models_body },
            .{ .body = "{\"data\":[]}" },
        },
    });
    defer rig.deinit();
    try rig.waitFor(&.{.{ .status = "Model: openai-plan/none" }});
    try rig.keys("/model\r");
    try rig.waitFor(&.{
        .{ .text = "Model: openai-plan · ↑/↓" },
        .{ .line = " > Fetch the model list" },
    });
    try rig.keys("\r");
    try rig.waitFor(&.{
        .{ .text = "Model: openai-plan · ↑/↓" },
        .{ .rows = &.{ " > Refresh the model list", "   gpt-next" } },
    });
    try rig.keys("\x1b[B\r");
    try rig.waitFor(&.{
        .{ .absent = "Model: openai-plan · ↑/↓" },
        .{ .status = "Model: openai-plan/gpt-next" },
        .{ .text = "Drinky now uses openai-plan/gpt-next." },
    });
}

test "a model fetch that signs out the last account opens the sign-in picker" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .store = application.testing.expired_plan_store,
        .replies = &.{
            .{
                .status = .unauthorized,
                .body = "{\"error\":{\"code\":\"refresh_token_reused\"}}",
            },
            .{ .body = "{\"data\":[]}" },
        },
    });
    defer rig.deinit();
    try rig.keys("/model\r");
    try rig.waitFor(&.{.{ .text = "Model: openai-plan · ↑/↓" }});
    try rig.keys("\r");
    try rig.waitFor(&.{
        .{ .text = "Sign in · ↑/↓" },
        .{ .text = "Drinky signed out of openai-plan. Select an account to sign in." },
        .{ .status = "Model: signed out" },
    });
}

test "Esc on the models of an author returns to the author step at that author" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENROUTER_API_KEY", "sk-or" }},
        .files = &.{.{
            ".drinky/metadata.json",
            "{\"openrouter\":{\"models\":[" ++
                "{\"name\":\"qwen/qwen-new\",\"context_window\":1,\"tools\":\"supported\"}," ++
                "{\"name\":\"openai/gpt-new\",\"context_window\":1,\"tools\":\"supported\"}," ++
                "{\"name\":\"openai/gpt-old\",\"context_window\":1,\"tools\":\"supported\"}]}}",
        }},
    });
    defer rig.deinit();

    try rig.keys("/model\r");
    try rig.waitFor(&.{.{ .text = "Author: openrouter-api-key · " }});
    try rig.keys("\x1b[B\r");
    try rig.waitFor(&.{.{ .text = "Model: openrouter-api-key · " }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .text = "Author: openrouter-api-key · " },
        .{ .text = " > openai · " },
    });
}

test "/logout signs out of the chosen account and hands the session to the next one" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .store = accounts.testing.planStore("first"),
        .model = "gpt-5.6-sol",
        .model_accounts = &.{ accounts.testing.openai_plan, accounts.testing.openai_api_key },
    });
    defer rig.deinit();
    try rig.waitFor(&.{.{ .status = "Model: openai-plan/gpt-5.6-sol" }});

    try rig.keys("/logout\r");
    try rig.waitFor(&.{.{ .text = "Sign out · ↑/↓" }});
    try rig.keys("\r");
    try rig.waitFor(&.{
        .{ .absent = "Sign out · ↑/↓" },
        .{ .status = "Model: openai-api-key/gpt-5.6-sol" },
        .{ .text = "Drinky signed out of openai-plan. " ++
            "Drinky now uses openai-api-key/gpt-5.6-sol." },
    });
}

const system_lead = "You are a coding assistant.";

test "a page on the alternate screen scrolls, toggles the source, and closes on Esc" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{\"user_instructions\":[{\"path\":\"long.md\"}]}",
        .files = &.{.{
            ".drinky/long.md",
            core.text.repeat("Keep this line.\n\n", 40) ++ "Last line.\n",
        }},
    });
    defer rig.deinit();
    try rig.keys("/system\r");
    try rig.waitFor(&.{
        .{ .alternate_screen = true },
        .{ .text = "System prompt · Esc: Close · M: Source" },
        .{ .text = system_lead },
    });

    try rig.keys(core.text.repeat("\x1b[B", 3));
    try rig.waitFor(&.{.{ .absent = system_lead }});
    try rig.keys("\x1b[A");
    try rig.waitFor(&.{.{ .text = system_lead }});
    try rig.keys("\x1b[6~");
    try rig.waitFor(&.{.{ .absent = system_lead }});
    try rig.keys("\x1b[5~");
    try rig.waitFor(&.{.{ .text = system_lead }});
    try rig.keys("\x1b[4~");
    try rig.waitFor(&.{ .{ .text = "Last line." }, .{ .absent = system_lead } });
    try rig.keys("\x1b[H");
    try rig.waitFor(&.{ .{ .text = system_lead }, .{ .absent = "Last line." } });

    try rig.keys("m");
    try rig.waitFor(&.{.{ .text = "M: Render" }});
    try rig.keys("M");
    try rig.waitFor(&.{.{ .text = "M: Source" }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .alternate_screen = false },
        .{ .text = "/help: Commands" },
        .{ .absent = "System prompt" },
    });
}

const short_answer_caption = short_answer_title ++ " · Esc: Close";
const wait_line = "Agent: work (waiting) · Time: 0s · Received: 0 B";

test "/tldr opens a short-answer page and Esc restores the transcript" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.replyStream("Short version.") },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("hello\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "hello", "done" } }, .{ .activity = false } });
    try rig.keys("/tldr\r");
    try rig.waitFor(&.{
        .{ .alternate_screen = true },
        .{ .text = short_answer_caption },
        .{ .text = "Short version." },
    });
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .alternate_screen = false },
        .{ .rows = &.{ "hello", "done" } },
        .{ .absent = "Short version." },
        .{ .editor = "" },
    });
}

test "Esc stops the short answer before the page closes, and a failed or cut one is not kept" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = providers.testing.reply_stream },
        .{ .stall = &stall },
        .{ .body = partial_failure_stream },
        .{ .body = cut_stream },
        .{ .body = providers.testing.replyStream("Short version.") },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "hello", "done" } }, .{ .activity = false } });
    try rig.keys("/tldr\r");
    try stall.reached.wait(std.testing.io);
    try rig.waitFor(&.{ .{ .text = short_answer_caption }, .{ .text = wait_line } });
    try rig.keys("\x1b");
    try rig.waitFor(&.{ .{ .alternate_screen = false }, .{ .rows = &.{ "hello", "done" } } });
    try std.testing.expect(stall.canceled);

    try rig.keys("/tldr\r");
    try rig.waitFor(&.{
        .{ .alternate_screen = true },
        .{ .rows = &.{ "partial", "The provider is overloaded. Details: **down**" } },
    });
    try std.testing.expectEqual(@as(usize, 3), rig.transport.requests.items.len);
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .alternate_screen = false }});
    try rig.keys("/tldr\r");
    try rig.waitFor(&.{
        .{ .alternate_screen = true },
        .{ .rows = &.{ "cut", testing.truncated_text } },
    });
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .alternate_screen = false }});
    try rig.keys("/tldr\r");
    try rig.waitFor(&.{ .{ .alternate_screen = true }, .{ .text = "Short version." } });
}

const partial_failure_stream = "data: {\"type\":\"response.output_text.delta\"," ++
    "\"item_id\":\"msg_1\",\"delta\":\"partial\"}\n" ++
    "\n" ++
    "data: {\"type\":\"error\",\"code\":\"server_error\",\"message\":\"**down**\"}\n" ++
    "\n";

test "incomplete page replies use the transcript failure symbol and color" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "/tldr\r", "/handoff\r" }) |command_line| {
        var rig: Rig = undefined;
        try rig.init(&.{
            .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
            .replies = &.{
                .{ .body = providers.testing.reply_stream },
                .{ .body = cut_stream },
            },
            .model = "gpt-5.6-sol",
        });
        defer rig.deinit();
        try rig.keys("Task.\r");
        try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
        try rig.keys(command_line);
        try rig.waitFor(&.{
            .{ .alternate_screen = true },
            .{ .text = testing.truncated_text },
        });
        const output = try rig.device.outputBytes(gpa);
        defer gpa.free(output);
        try testing.expectContains(output, "\x1b[31m⚠ " ++ testing.truncated_text);
    }
}

test "a failed attempt adds its note below the wait line of the short answer until Esc" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .config = "{\"request\":{\"attempts_max\":2,\"delay_ms_initial\":60000," ++
            "\"delay_ms_max\":60000}}",
        .replies = &.{ .{ .body = providers.testing.reply_stream }, failed_reply },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "hello", "done" } }, .{ .activity = false } });
    try rig.keys("/tldr\r");
    try rig.waitFor(&.{
        .{ .text = short_answer_caption },
        .{ .text = wait_line },
        .{ .text = "Attempt 1 failed. The provider is overloaded. Drinky tries again in " },
    });
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .alternate_screen = false }});
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
}

test "/tldr after a sign-out asks for a sign-in to shorten the answer and sends no request" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .store = accounts.testing.planStore("first"),
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
        .model_accounts = &.{accounts.testing.openai_plan},
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "hello", "done" } }, .{ .activity = false } });
    try rig.keys("/logout\r");
    try rig.waitFor(&.{.{ .text = "Sign out · ↑/↓" }});
    try rig.keys("\r");
    try rig.waitFor(&.{.{ .text = "Sign in · ↑/↓" }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .absent = "Sign in · ↑/↓" }});
    try rig.keys("/tldr\r");
    try rig.waitFor(&.{
        .{ .status = "Sign in with /login before you shorten an answer." },
        .{ .editor = "/tldr" },
        .{ .alternate_screen = false },
    });
    try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
}

test "Herdr hears working while /tldr streams and idle after the page closes" {
    const gpa = std.testing.allocator;
    var herdr: testing.FakeHerdr = undefined;
    try herdr.init(gpa, std.testing.io);
    defer herdr.deinit();
    var serving = try std.testing.io.concurrent(testing.FakeHerdr.serve, .{ &herdr, 16 });
    defer _ = serving.cancel(std.testing.io) catch {};
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = providers.testing.reply_stream, .hold = &hold },
        .{ .stall = &stall },
    };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
        .herdr = herdr.endpoint(),
    });
    defer rig.deinit();

    try rig.keys("hello\r");
    try hold.reached.wait(std.testing.io);
    try expectHerdrState(&herdr, "working");
    hold.released.set(std.testing.io);
    try expectHerdrState(&herdr, "idle");
    try rig.keys("/tldr\r");
    try stall.reached.wait(std.testing.io);
    try expectHerdrState(&herdr, "working");
    try rig.waitFor(&.{.{ .text = short_answer_caption }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .alternate_screen = false }});
    try expectHerdrState(&herdr, "idle");
}

test "/handoff restores its command after discard and applies a preview with Enter" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.replyStream("First handoff.") },
            .{ .body = providers.testing.replyStream("Resume the task.") },
            .{ .body = providers.testing.replyStream("Continued.") },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();

    try rig.keys("Original task.\r");
    try rig.waitFor(&.{ .{ .rows = &.{ "Original task.", "done" } }, .{ .activity = false } });
    try rig.keys("/handoff Keep the constraints.\r");
    try rig.waitFor(&.{
        .{ .alternate_screen = true },
        .{ .text = "Handoff · Enter: Apply · Esc: Discard" },
        .{ .text = "First handoff." },
    });
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .alternate_screen = false },
        .{ .editor = "/handoff Keep the constraints." },
        .{ .rows = &.{ "Original task.", "done" } },
    });
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .text = "Resume the task." }, .{ .text = "Enter: Apply" } });
    try rig.keys("\r");
    try rig.waitFor(&.{
        .{ .alternate_screen = false },
        .{ .rows = &.{ "Resume the task.", "Continued." } },
        .{ .absent = "Original task." },
        .{ .editor = "" },
        .{ .activity = false },
    });
    try rig.keys("/rewind\r");
    try rig.waitFor(&.{.{ .text = rewind_picker }});
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .editor = "Resume the task." }, .{ .absent = "Continued." } });
}

test "a short answer from the command picker clears its line and returns to the prompt" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.replyStream("Short text.") },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("Task.\r");
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    try rig.keys("/help\r");
    try rig.waitFor(&.{.{ .text = "Command ·" }});
    for (0..11) |_| try rig.keys("\x1b[B");
    try rig.waitFor(&.{.{ .text = " > /tldr" }});
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .text = "Short text." }, .{ .alternate_screen = true } });
    try rig.keys("\x1b");
    try rig.waitFor(&.{ .{ .alternate_screen = false }, .{ .editor = "" } });
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
}

test "a handoff from the command picker restores its command after a discard" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.replyStream("Handoff text.") },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("Task.\r");
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    try rig.keys("/help\r");
    try rig.waitFor(&.{.{ .text = "Command ·" }});
    try rig.keys("\x1b[B\r");
    try rig.waitFor(&.{.{ .text = "Handoff · Enter: Apply" }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{ .{ .alternate_screen = false }, .{ .editor = "/handoff" } });
}

test "handoff exits cancel generation without applying it or losing the command" {
    for ([_][]const u8{ "\x1b", "\x03", "\x04" }) |exit| {
        var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
        var rig: Rig = undefined;
        try rig.init(&.{
            .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
            .replies = &.{
                .{ .body = providers.testing.reply_stream },
                .{ .stall = &stall },
                .{ .body = providers.testing.replyStream("Next answer.") },
            },
            .model = "gpt-5.6-sol",
        });
        defer rig.deinit();
        try rig.keys("Original task.\r");
        try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
        try rig.keys("/handoff Keep the goal.\r");
        try stall.reached.wait(std.testing.io);
        try rig.waitFor(&.{
            .{ .text = "Handoff · Esc: Discard" },
            .{ .absent = "Enter: Apply" },
        });
        try rig.keys("\r");
        try rig.keys(exit);
        try rig.waitFor(&.{
            .{ .alternate_screen = false },
            .{ .editor = "/handoff Keep the goal." },
            .{ .rows = &.{ "Original task.", "done" } },
        });
        try std.testing.expect(stall.canceled);
        try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
        try rig.keys("\x03Next prompt.\r");
        try rig.waitFor(&.{ .{ .text = "Next answer." }, .{ .activity = false } });
        try expectRequested(&rig, "Original task.");
        try expectRequested(&rig, "Next prompt.");
        try std.testing.expect(std.mem.find(u8, rig.lastRequest(), "Keep the goal.") == null);
    }
}

test "a failed or truncated handoff cannot apply, and its command survives" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = partial_failure_stream },
            .{ .body = cut_stream },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("Original task.\r");
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    try rig.keys("/handoff Keep checks.\r");
    try rig.waitFor(&.{
        .{ .text = "The provider is overloaded." },
        .{ .absent = "Enter: Apply" },
    });
    try rig.keys("\rM");
    try rig.waitFor(&.{ .{ .text = "M: Render" }, .{ .text = "partial" } });
    try rig.keys("\x1b");
    try rig.waitFor(&.{ .{ .alternate_screen = false }, .{ .editor = "/handoff Keep checks." } });
    try rig.keys("\r");
    try rig.waitFor(
        &.{ .{ .text = testing.truncated_text }, .{ .absent = "Enter: Apply" } },
    );
    try rig.keys("\r\x1b");
    try rig.waitFor(&.{
        .{ .alternate_screen = false },
        .{ .editor = "/handoff Keep checks." },
        .{ .rows = &.{ "Original task.", "done" } },
    });
    try std.testing.expectEqual(@as(usize, 3), rig.transport.requests.items.len);
}

test "an applied handoff has the normal canceled-turn edit action" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.replyStream("Resume this task.") },
            .{ .stall = &stall },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("Original task.\r");
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    try rig.keys("/handoff\r");
    try rig.waitFor(&.{.{ .text = "Handoff · Enter: Apply" }});
    try expectRequested(&rig, "\"text\":\"Prepare the handoff.\"");
    try rig.keys("\r");
    try stall.reached.wait(std.testing.io);
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .text = "Canceled turn" }});
    try rig.keys("\x0e");
    try rig.waitFor(&.{
        .{ .editor = "Resume this task." },
        .{ .absent = "Original task." },
        .{ .absent = "Canceled turn" },
    });
}

test "a handoff without a conversation refuses and keeps its command" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("/handoff Keep tests.\r");
    try rig.waitFor(&.{
        .{ .status = "No conversation is available for a handoff." },
        .{ .editor = "/handoff Keep tests." },
        .{ .alternate_screen = false },
    });
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

const cut_stream = "data: {\"type\":\"response.output_text.delta\"," ++
    "\"item_id\":\"msg_1\",\"delta\":\"cut\"}\n" ++
    "\n" ++
    "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n" ++
    "\n";

test "Herdr hears working during a turn, blocked at a retry offer, and idle after Esc" {
    const gpa = std.testing.allocator;
    var herdr: testing.FakeHerdr = undefined;
    try herdr.init(gpa, std.testing.io);
    defer herdr.deinit();
    var serving = try std.testing.io.concurrent(testing.FakeHerdr.serve, .{ &herdr, 16 });
    defer _ = serving.cancel(std.testing.io) catch {};
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var held_failure = failed_reply;
    held_failure.hold = &hold;
    const replies = [_]providers.testing.FakeTransport.Reply{ held_failure, failed_reply };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &replies,
        .model = "gpt-5.6-sol",
        .herdr = herdr.endpoint(),
    });
    defer rig.deinit();

    try expectHerdrState(&herdr, "idle");
    try rig.keys("hello\r");
    try hold.reached.wait(std.testing.io);
    try expectHerdrState(&herdr, "working");
    hold.released.set(std.testing.io);
    try expectHerdrState(&herdr, "blocked");
    try rig.waitFor(&.{.{ .text = retry_caption_row }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .absent = retry_caption_row }});
    try expectHerdrState(&herdr, "idle");
}

fn expectHerdrState(herdr: *testing.FakeHerdr, comptime state: []const u8) !void {
    const lines_max = 8;
    for (0..lines_max) |_| {
        const line = herdr.take() catch |err| {
            std.debug.print("Herdr heard no state \"{s}\": {s}\n", .{ state, @errorName(err) });
            return err;
        };
        defer std.testing.allocator.free(line);
        if (std.mem.find(u8, line, "\"state\":\"" ++ state ++ "\"") != null) return;
    }
    std.debug.print("Herdr heard {d} lines without the state \"{s}\"\n", .{ lines_max, state });
    return error.TestExpectedHerdrState;
}

test "Ctrl+D at an empty prompt ends the run" {
    var rig: Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer rig.deinit();
    try rig.waitFor(&.{.{ .text = "/help: Commands" }});
    try rig.keys("\x04");
    try rig.finish();
}

test "a closed input ends the run and leaves the alternate screen" {
    var rig: Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer rig.deinit();
    try rig.keys("/system\r");
    try rig.waitFor(&.{.{ .alternate_screen = true }});
    rig.device.close();
    try rig.finish();
    try rig.expectSees(&.{.{ .alternate_screen = false }});
}

test "a resize repaints the frame at the new width" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .window = .{ .columns = 80, .rows = 24 },
    });
    defer rig.deinit();
    try rig.waitFor(&.{ .{ .text = "Drinky · Enter: Send" }, .{ .absent = "/help: Commands" } });
    try rig.device.resize(.{ .columns = 120, .rows = 24 });
    try rig.waitFor(&.{.{ .text = intro_text }});
}

test "paste labels keep their sequence across an immediate new draft" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "key" }},
        .model = "gpt-5.6-sol",
        .replies = &.{.{ .body = providers.testing.reply_stream }},
    });
    defer rig.deinit();
    try rig.waitFor(&.{.{ .status = "Model: openai-api-key/gpt-5.6-sol" }});
    const paste = terminal.escape.paste_begin ++ core.text.repeat("a", 1001) ++
        terminal.escape.paste_end;
    try rig.keys(paste ++ "\r" ++ paste);
    try rig.waitFor(&.{.{ .text = "[Paste #2: 1001 bytes]" }});
}

test "Ctrl+D in the same input as a sign-in selection cancels it and guards the next quit" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.waitFor(&.{.{ .text = "Sign in · ↑/↓" }});
    try rig.keys("\r\x04");
    try rig.waitFor(&.{
        .{ .absent = anthropic_plan_caption },
        .{ .text = "You canceled the sign-in to anthropic-plan." },
        .{ .editor = "" },
    });
    try rig.keys("\x04");
    try rig.waitFor(&.{.{ .status = "Press Ctrl+D again to quit." }});
    try rig.keys("\x04");
    try rig.finish();
}

test "Ctrl+D during a sign-in cancels it instead of the terminal" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.startLoginOf(accounts.testing.anthropic_plan);
    try rig.keys("\x04");
    try rig.waitFor(&.{
        .{ .text = "You canceled the sign-in to anthropic-plan." },
        .{ .editor = "" },
    });
    try std.testing.expectEqual(@as(?u16, null), rig.loopback.listening());
    try rig.keys("\x04");
    try rig.waitFor(&.{.{ .status = "Press Ctrl+D again to quit." }});
}

test "exits after page and turn responses use the authoritative state" {
    for ([_]bool{ false, true }) |turn| {
        var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
        var rig: Rig = undefined;
        try rig.init(&.{
            .variables = &.{.{ "OPENAI_API_KEY", "key" }},
            .model = "gpt-5.6-sol",
            .replies = &.{.{ .stall = &stall }},
        });
        defer rig.deinit();
        try rig.waitFor(&.{.{ .status = "Model: openai-api-key/gpt-5.6-sol" }});
        try rig.keys(if (turn) "Task.\r" else "/system\r");
        if (turn) {
            try stall.reached.wait(std.testing.io);
            try rig.waitFor(&.{.{ .activity = true }});
        } else try rig.waitFor(&.{.{ .alternate_screen = true }});
        try rig.keys("\x04");
        try rig.waitFor(&.{
            .{ .alternate_screen = false },
            .{ .activity = false },
            .{ .editor = "" },
        });
        if (turn) try std.testing.expect(stall.canceled);
        try rig.keys("\x04");
        try rig.waitFor(&.{.{ .status = "Press Ctrl+D again to quit." }});
    }
}

test "a frame timer task failure withdraws the send as message confirmation" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "key" }},
        .model = "gpt-5.6-sol",
        .replies = &.{.{ .body = providers.testing.reply_stream }},
    });
    defer rig.deinit();
    try rig.waitFor(&.{.{ .status = "Model: openai-api-key/gpt-5.6-sol" }});
    try rig.keys("/nope\r");
    try rig.waitFor(&.{.{ .status = refusal_offer }});
    rig.clock.refuse_concurrency.store(true, .release);
    try rig.device.resize(.{ .columns = 120, .rows = 30 });
    try rig.waitFor(&.{.{ .status = "Drinky could not start the frame timer" }});
    rig.clock.refuse_concurrency.store(false, .release);
    try rig.keyFrame("\r");
    try rig.waitFor(&.{ .{ .status = refusal_offer }, .{ .editor = "/nope" } });
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

const access_on = "MCP access is on. Instance: ";

test "/mcp publishes the instance, and a second gateway reads the outcome of a remote turn" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    const sent = try remote.target("send_message", &instance, ",\"text\":\"Task.\"");
    defer sent.deinit();
    try std.testing.expect(!sent.failed);
    const operation = (try mcp.testing.member(sent.content, "operation")).string;
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    var restarted: mcp.testing.Client = undefined;
    restarted.init(rig.mcp_directory);
    defer restarted.deinit();
    try std.testing.expectEqualStrings(&instance, &try restarted.instance(rig.directory));
    const rest = try std.testing.allocator.print(",\"operation\":\"{s}\"", .{operation});
    defer std.testing.allocator.free(rest);
    const ended = try restarted.target("get_operation", &instance, rest);
    defer ended.deinit();
    const status = try mcp.testing.member(ended.content, "status");
    try std.testing.expectEqualStrings("ended", status.string);
    try std.testing.expectEqualStrings(
        "complete",
        (try mcp.testing.member(ended.content, "outcome")).string,
    );
    try std.testing.expectEqualStrings("done", try ended.text("answer"));
    const turns = try restarted.target("list_turns", &instance, "");
    defer turns.deinit();
    const turn = (try mcp.testing.member(turns.content, "turns")).array.items[0];
    try std.testing.expectEqualStrings("Task.", (try mcp.testing.member(turn, "prompt")).string);
    const turn_operation = try mcp.testing.member(turn, "operation");
    try std.testing.expectEqualStrings(operation, turn_operation.string);
}

test "remote reads keep the notice and the draft, and a second message is refused as busy" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream, .hold = &hold }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    defer hold.released.set(std.testing.io);
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    try rig.keys("draft");
    try rig.waitFor(&.{.{ .editor = "draft" }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    const initial = try remote.target("get_state", &instance, "");
    defer initial.deinit();
    const effort = (try mcp.testing.member(initial.content, "effort")).string;
    const rest = try std.testing.allocator.print(",\"effort\":\"{s}\"", .{effort});
    defer std.testing.allocator.free(rest);
    const unchanged = try remote.target("set_effort", &instance, rest);
    defer unchanged.deinit();
    try std.testing.expect(!unchanged.failed);
    var notices: [2][]const u8 = undefined;
    var reads: [2]mcp.testing.Client.Called = undefined;
    for (&notices, &reads) |*notice, *read| {
        read.* = try remote.target("get_state", &instance, "");
        const shown = try mcp.testing.member(read.content, "notice");
        notice.* = (try mcp.testing.member(shown, "text")).string;
    }
    defer for (&reads) |*read| read.deinit();
    try std.testing.expectEqualStrings(notices[0], notices[1]);
    try rig.waitFor(&.{ .{ .status = notices[0] }, .{ .editor = "draft" } });
    const sent = try remote.target("send_message", &instance, ",\"text\":\"Task.\"");
    defer sent.deinit();
    try std.testing.expect(!sent.failed);
    try hold.reached.wait(std.testing.io);
    const refused = try remote.target("send_message", &instance, ",\"text\":\"More.\"");
    defer refused.deinit();
    try std.testing.expect(refused.failed);
    const refusal = try mcp.testing.member(refused.content, "refusal");
    try std.testing.expectEqualStrings("busy", refusal.string);
    try rig.waitFor(&.{ .{ .activity = true }, .{ .editor = "draft" } });
    hold.released.set(std.testing.io);
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false }, .{ .editor = "draft" } });
}

test "the end of access keeps the accepted turn and revokes the instance id" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream, .hold = &hold }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    defer hold.released.set(std.testing.io);
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    const sent = try remote.target("send_message", &instance, ",\"text\":\"Task.\"");
    defer sent.deinit();
    try hold.reached.wait(std.testing.io);
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{ .{ .status = "MCP access is off for instance " }, .{ .activity = true } });
    const revoked = try remote.target("get_state", &instance, "");
    defer revoked.deinit();
    try std.testing.expectEqualStrings(
        "unknown_instance",
        (try mcp.testing.member(revoked.content, "failure")).string,
    );
    hold.released.set(std.testing.io);
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    try std.testing.expect(!std.mem.eql(u8, &instance, &try remote.instance(rig.directory)));
}

test "an Esc warning of an ended turn does not cancel a later remote turn at once" {
    var holds: [2]providers.testing.FakeTransport.Hold = @splat(.{ .io = std.testing.io });
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream, .hold = &holds[0] },
            .{ .body = providers.testing.reply_stream, .hold = &holds[1] },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    defer for (&holds) |*hold| hold.released.set(std.testing.io);
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    try rig.keys("Task.\r");
    try holds[0].reached.wait(std.testing.io);
    try rig.keys("draft");
    try rig.waitFor(&.{ .{ .editor = "draft" }, .{ .activity = true } });
    try rig.keys("\x1b");
    try rig.waitFor(&.{.{ .status = turn_cancel_notice }});
    holds[0].released.set(std.testing.io);
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    const sent = try remote.target("send_message", &instance, ",\"text\":\"More.\"");
    defer sent.deinit();
    try holds[1].reached.wait(std.testing.io);
    try rig.waitFor(&.{.{ .activity = true }});
    try rig.keys("\x1b");
    try rig.waitFor(&.{ .{ .status = turn_cancel_notice }, .{ .activity = true } });
}

test "a remote turn withdraws a quit warning and its confirmation" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream, .hold = &hold }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    defer hold.released.set(std.testing.io);
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    try rig.keys("draft\x04");
    const draft_quit_warning = "Press Ctrl+D again to quit. The quit discards the draft.";
    try rig.waitFor(&.{.{ .status = draft_quit_warning }});
    const sent = try remote.target("send_message", &instance, ",\"text\":\"Task.\"");
    defer sent.deinit();
    try hold.reached.wait(std.testing.io);
    try rig.waitFor(&.{ .{ .activity = true }, .{ .absent = draft_quit_warning } });
    hold.released.set(std.testing.io);
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false }, .{ .editor = "draft" } });
}

test "a remote notice that replaces a quit warning withdraws its confirmation" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    const draft_quit_warning = "Press Ctrl+D again to quit. The quit discards the draft.";
    try rig.keys("draft\x04");
    try rig.waitFor(&.{.{ .status = draft_quit_warning }});
    const unchanged = try remote.target("set_effort", &instance, ",\"effort\":\"xhigh\"");
    defer unchanged.deinit();
    try std.testing.expect(!unchanged.failed);
    try rig.waitFor(&.{ .{ .absent = draft_quit_warning }, .{ .editor = "draft" } });
    try rig.keys("\x04");
    try rig.waitFor(&.{ .{ .status = draft_quit_warning }, .{ .editor = "draft" } });
}

test "an Esc at the prompt does not reach a remote turn that starts within its wait" {
    var hold: providers.testing.FakeTransport.Hold = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .body = providers.testing.reply_stream, .hold = &hold }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    defer hold.released.set(std.testing.io);
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    try rig.keys("draft");
    try rig.waitFor(&.{ .{ .absent = access_on }, .{ .editor = "draft" } });
    try rig.keys("\x1b");
    const sent = try remote.target("send_message", &instance, ",\"text\":\"Task.\"");
    defer sent.deinit();
    try std.testing.expect(!sent.failed);
    try hold.reached.wait(std.testing.io);
    const painted = rig.device.frameCount();
    rig.clock.advance(escape_wait_ms * 2);
    try rig.device.waitFrame(painted);
    try rig.expectSees(&.{ .{ .absent = turn_cancel_notice }, .{ .editor = "draft" } });
    hold.released.set(std.testing.io);
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
}

test "remote changes fail while the terminal shows a picker, and remote reads still work" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    try rig.keys("/help\r");
    try rig.waitFor(&.{.{ .text = "Command · ↑/↓" }});
    for ([_][]const u8{ ",\"text\":\"Task.\"", ",\"effort\":\"low\"" }, 0..) |rest, index| {
        const refused = if (index == 0)
            try remote.target("send_message", &instance, rest)
        else
            try remote.target("set_effort", &instance, rest);
        defer refused.deinit();
        try std.testing.expectEqualStrings("terminal_interaction", try refused.text("failure"));
    }
    const read = try remote.target("get_state", &instance, "");
    defer read.deinit();
    try std.testing.expectEqualStrings("xhigh", try read.text("effort"));
    try rig.waitFor(&.{.{ .text = "Command · ↑/↓" }});
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "a remote model fetch shows its caption, refuses messages, and reports its end" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: Rig = undefined;
    try rig.init(&.{
        .store = accounts.testing.planStore("first"),
        .replies = &.{
            .{ .stall = &stall },
            .{ .body = application.testing.plan_models_body },
            .{ .body = "{\"data\":[]}" },
            .{ .status = .bad_request },
            .{ .body = "{\"data\":[]}" },
        },
    });
    defer rig.deinit();
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    const account = ",\"account\":\"openai-plan\"";
    const canceled = try remote.target("fetch_models", &instance, account);
    defer canceled.deinit();
    try stall.reached.wait(std.testing.io);
    const fetch_caption = "Model fetch: openai-plan · Esc: Cancel";
    try rig.keys("draft\r");
    try rig.waitFor(&.{
        .{ .text = fetch_caption },
        .{ .status = fetch_message_notice },
        .{ .editor = "draft" },
    });
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .absent = fetch_caption },
        .{ .status = fetch_cancel_notice },
        .{ .editor = "draft" },
    });
    try std.testing.expect(stall.canceled);
    try expectFetchOutcome(&remote, &instance, try canceled.text("operation"), &.{
        .outcome = "canceled",
    });
    const listed = try remote.target("fetch_models", &instance, account);
    defer listed.deinit();
    try rig.waitFor(&.{
        .{ .status = "Drinky fetched the model list of openai-plan." },
        .{ .editor = "draft" },
    });
    try expectFetchOutcome(&remote, &instance, try listed.text("operation"), &.{
        .outcome = "listed",
    });
    const models = try remote.target("list_models", &instance, account);
    defer models.deinit();
    const first = (try mcp.testing.member(models.content, "models")).array.items[0];
    try std.testing.expectEqualStrings("gpt-next", (try mcp.testing.member(first, "model")).string);
    const failed = try remote.target("fetch_models", &instance, account);
    defer failed.deinit();
    try rig.waitFor(&.{
        .{ .absent = fetch_caption },
        .{ .text = "Drinky could not fetch the model list of openai-plan" },
    });
    try expectFetchOutcome(&remote, &instance, try failed.text("operation"), &.{
        .outcome = "failed",
        .cause = "ModelListRequestFailed",
    });
}

fn expectFetchOutcome(
    remote: *mcp.testing.Client,
    instance: *const mcp.discovery.Id,
    operation: []const u8,
    expected: *const struct { outcome: []const u8, cause: ?[]const u8 = null },
) !void {
    const rest = try std.testing.allocator.print(",\"operation\":\"{s}\"", .{operation});
    defer std.testing.allocator.free(rest);
    const ended = try remote.target("get_operation", instance, rest);
    defer ended.deinit();
    try std.testing.expectEqualStrings("ended", try ended.text("status"));
    try std.testing.expectEqualStrings(expected.outcome, try ended.text("outcome"));
    const cause = expected.cause orelse
        return std.testing.expectError(error.TestExpectedMember, ended.text("cause"));
    try std.testing.expectEqualStrings(cause, try ended.text("cause"));
}

test "a remote clear keeps the draft and names the MCP client, and a terminal clear does not" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = providers.testing.reply_stream },
        },
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    const remote_clear_notice = "An MCP client cleared the conversation.";
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    var remote: mcp.testing.Client = undefined;
    remote.init(rig.mcp_directory);
    defer remote.deinit();
    const instance = try remote.instance(rig.directory);
    try rig.keys("First task.\r");
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    try rig.keys("/new\r");
    try rig.waitFor(&.{ .{ .absent = "done" }, .{ .absent = remote_clear_notice } });
    try rig.keys("Second task.\r");
    try rig.waitFor(&.{ .{ .text = "done" }, .{ .activity = false } });
    try rig.keys("draft");
    const cleared = try remote.target("new_conversation", &instance, "");
    defer cleared.deinit();
    try std.testing.expect(!cleared.failed);
    try rig.waitFor(&.{
        .{ .absent = "done" },
        .{ .status = remote_clear_notice },
        .{ .editor = "draft" },
    });
    const turns = try remote.target("list_turns", &instance, "");
    defer turns.deinit();
    const listed = (try mcp.testing.member(turns.content, "turns")).array.items;
    try std.testing.expectEqual(@as(usize, 0), listed.len);
}

test "the status line shows MCP access while it is on and keeps it across a snapshot" {
    var rig: Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENAI_API_KEY", "key" }},
        .model = "gpt-5.6-sol",
    });
    defer rig.deinit();
    const model_label = "Model: openai-api-key/gpt-5.6-sol";
    const access_label = "MCP: on · " ++ model_label;
    try rig.waitFor(&.{ .{ .status = model_label }, .{ .absent = "MCP:" } });
    try rig.keys("/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    try rig.keys("x");
    try rig.waitFor(&.{ .{ .status = access_label }, .{ .editor = "x" } });
    try rig.keys("\x7f/mcp\r");
    try rig.waitFor(&.{.{ .status = "MCP access is off for instance " }});
    try rig.keys("x");
    try rig.waitFor(&.{ .{ .status = model_label }, .{ .absent = "MCP:" } });
    try rig.keys("\x7f/mcp\r");
    try rig.waitFor(&.{.{ .status = access_on }});
    try rig.keys("\x04");
    try rig.finish();
    _ = rig.app.controller.submit(&.snapshot);
    try rig.app.screen.paint(rig.device.window, .{ .awake_ms = 0, .boot_ms = 0 }, &null);
    try rig.expectSees(&.{.{ .status = access_label }});
}
