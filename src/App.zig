const std = @import("std");
const application = @import("application");
const terminal = @import("terminal");
const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");
const tools = @import("tools");
const Herdr = @import("Herdr.zig");
const Screen = @import("Screen.zig");
const testing = @import("testing.zig");
const ui = @import("ui/root.zig");
const App = @This();
const turn_cancel_notice = "Press Esc again to cancel the turn. The draft stays.";
const login_callback_controls = "Enter: Replay callback URL · Esc: Cancel";
const login_device_controls = "Esc: Cancel";
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
    for (application.reference.key_hints) |hint| line = line ++ hint ++ ui.paint.separator;
    break :blk line ++ "/help: Commands";
};
const escape_wait_ms = 50;
const sign_in_title_bytes_max = 64;
const queue_capacity = 256;

gpa: std.mem.Allocator,
io: std.Io,
device: terminal.Device,
controller: *application.Controller,
screen: Screen,
input: terminal.Input,
mode: application.Interaction.Mode = .prompt,
offer: application.Interaction.Offer = .none,
working: bool = false,
takes_paste: bool = false,
running: bool = false,
dirty: bool = false,
ctrl_c_ms_last: i64 = -application.reference.repeat_window_ms,
ctrl_d_ms_last: i64 = -application.reference.repeat_window_ms,
escape_deadline_ms: ?i64 = null,
queue: std.Io.Queue(UiEvent),
queue_buffer: [queue_capacity]UiEvent = undefined,
queue_closing: std.atomic.Value(bool) = .init(false),
input_future: ?std.Io.Future(void) = null,
resize_future: ?std.Io.Future(void) = null,
tick_future: ?std.Io.Future(void) = null,
frame_grid: FrameGrid = .reset(0),
herdr: Herdr,
confirmation: ?Confirmation = null,
edits: u64 = 0,
paste_edits: ?u64 = null,
working_directory: []const u8,
home_directory: []const u8 = "",
directory_label: []const u8 = "",
project_row: bool,
sign_in_title: [sign_in_title_bytes_max]u8 = undefined,
sign_in_title_length: usize = 0,

const Options = struct {
    working_directory: []const u8,
    home: []const u8,
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
    tick,
    resize,
    fn deinit(self: *const UiEvent, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .keys => |bytes| gpa.free(bytes),
            .mail => |*mail| mail.deinit(gpa),
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

const Confirmation = enum {
    message,
    quit,
    removal,
    rewind,
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
fn keep(self: *App, event: UiEvent) void {
    if (self.queue_closing.load(.acquire)) return event.deinit(self.gpa);
    self.queue.putOneUncancelable(self.io, event) catch {
        event.deinit(self.gpa);
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
    };
    self.screen.verbose = (application.Settings{}).verbose;
    self.screen.intro = intro_text;
    self.queue = .init(&self.queue_buffer);
    errdefer self.screen.deinit();
    errdefer self.input.deinit();
    self.controller = try application.Controller.create(gpa, io, &.{
        .directories = .{ .working_directory = options.working_directory, .home = options.home },
        .environment = options.environment,
        .environ = options.environ,
        .startup = .terminal,
        .transport = options.transport,
        .browser = options.browser,
        .loopback = options.loopback,
        .sink = .{ .ptr = self, .vtable = &sink_vtable },
        .mailbox = .{ .ptr = self, .vtable = &mailbox_vtable },
    });
    errdefer {
        self.stopQueue();
        self.controller.destroy();
        self.drainQueue();
        self.gpa.free(self.home_directory);
        self.gpa.free(self.directory_label);
    }
    _ = self.controller.submit(&.snapshot);
    self.herdr.start(options.herdr) catch |err| {
        const message = try application.Message.print(
            gpa,
            .failure,
            "Drinky could not start the state reports to Herdr because of error {s}.",
            .{@errorName(err)},
        );
        defer message.deinit(gpa);
        _ = self.controller.submit(&.{ .client_notice = message });
    };
}
pub fn deinit(self: *App) void {
    self.stopQueue();
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
        for (batch[0..count]) |event| event.deinit(self.gpa);
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
        self.herdr.sync(
            if (self.working) .working else if (self.offer == .retry) .blocked else .idle,
        );
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
            self.escape_deadline_ms != null;
        if (waiting and self.tick_future == null) try self.armTick();
    }
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
        const before = self.mode;
        try self.handleKey(&event);
        if (before != self.mode and isExitKey(&event)) {
            while (self.input.next()) |_| {}
            break;
        }
    }
    self.escape_deadline_ms = if (self.input.pendingEscape())
        self.nowMs() + escape_wait_ms
    else
        null;
}

fn isExitKey(event: *const terminal.Input.Key) bool {
    return switch (event.*) {
        .escape => true,
        .ctrl => |letter| letter == 'c' or letter == 'd',
        else => false,
    };
}

fn flushEscape(self: *App) !void {
    const deadline = self.escape_deadline_ms orelse return;
    if (self.nowMs() < deadline) return;
    self.escape_deadline_ms = null;
    if (!self.input.takeEscape()) return;
    self.dirty = true;
    try self.handleKey(&.escape);
}

fn disarm(self: *App, event: *const terminal.Input.Key) void {
    const confirmation = self.confirmation orelse return;
    if (!confirmation.confirms(event)) self.confirmation = null;
}

fn draftEmpty(self: *const App) bool {
    return self.screen.editor.visible().len == 0;
}

fn clearDraft(self: *App) void {
    self.screen.editor.clear();
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
        else => return false,
    }
    self.screen.markEdited();
    self.edits +%= 1;
    return true;
}

fn clearOrQuit(self: *App) void {
    const now = self.nowMs();
    if (now - self.ctrl_c_ms_last < application.reference.repeat_window_ms) {
        self.running = false;
    } else {
        self.clearDraft();
        self.ctrl_c_ms_last = now;
    }
}

fn quitOrWarn(self: *App) !void {
    const draft = !self.draftEmpty();
    const recent_exit = self.nowMs() - self.ctrl_d_ms_last < application.reference.repeat_window_ms;
    if (self.confirmation == .quit or (!draft and !recent_exit)) {
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
    try self.device.setAlternateScreen(self.mode == .page);
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
    if (self.mode == .sign_in) return .{
        .title = self.sign_in_title[0..self.sign_in_title_length],
        .controls = if (self.takes_paste) login_callback_controls else login_device_controls,
        .rows_max = Screen.editor_caption_rows_max,
    };
    if (self.mode != .prompt) return null;
    return switch (self.offer) {
        .none => null,
        .retry => retry_caption,
        .removal => removal_caption,
    };
}
fn applyBatch(self: *App, events: []const UiEvent) !bool {
    var applied_count: usize = 0;
    errdefer for (events[applied_count..]) |*event| event.deinit(self.gpa);
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
            .mail => |mail| self.controller.receive(mail),
        }
    }
    return ticked;
}
fn applyEvent(self: *App, event: *const application.Event) !void {
    switch (event.*) {
        .snapshot => |*snapshot| try self.applySnapshot(snapshot),
        .interaction => |*value| {
            const verbose = self.screen.verbose;
            self.adopt(value);
            try self.screen.applyInteraction(value);
            if (self.screen.verbose != verbose) try self.reportNotice(
                .information,
                "Verbose output is {s}.",
                .{if (self.screen.verbose) "on" else "off"},
            );
        },
        .append_record,
        .record_text,
        .replace_record,
        .remove_records,
        .live,
        .statistics,
        .page_text,
        .clear_conversation,
        => try self.screen.applyChange(event),
        .paste_replayed => if (self.paste_edits == self.edits) self.clearDraft(),
        .turn_ended, .charge, .startup_refused => {},
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
    try self.screen.restore(snapshot);
    self.home_directory = home;
    self.directory_label = label;
    self.screen.display_roots = .{
        .working_directory = self.working_directory,
        .home_directory = home,
    };
    self.screen.directory_shown = if (self.project_row) self.directory_label else "";
    self.adopt(&snapshot.interaction);
}
fn adopt(self: *App, value: *const application.Interaction) void {
    self.mode = value.mode;
    self.offer = value.offer;
    self.working = value.working;
    self.takes_paste = value.takes_paste;
    const title = std.fmt.bufPrint(&self.sign_in_title, "Sign in: {s}", .{value.sign_in_account});
    self.sign_in_title_length = (title catch unreachable).len;
}
fn send(self: *App, command: *const application.Command) !void {
    const response = self.controller.submit(command);
    if (command.* == .submit and self.mode == .sign_in and response.accepted)
        self.paste_edits = self.edits;
    try self.applyEditor(&response.editor);
    const kind = response.confirmation orelse return;
    self.confirmation = switch (kind) {
        .message => .message,
        .rewind => .rewind,
        .removal => .removal,
    };
}
fn applyEditor(self: *App, editor: *const application.Response.Editor) !void {
    switch (editor.*) {
        .keep => {},
        .clear => self.clearDraft(),
        .replace => |text| try self.screen.setDraft(text),
        .prepend => |text| {
            try self.screen.editor.prependText(text);
            self.screen.markEdited();
        },
    }
}
fn submit(self: *App) !void {
    const confirmed = self.confirmation == .message;
    self.confirmation = null;
    if (self.screen.editor.blank()) return;
    const text = try self.screen.editor.expanded();
    defer self.gpa.free(text);
    try self.send(&.{ .submit = .{ .line = text, .confirmed = confirmed } });
}
fn cancel(self: *App, step: bool) !void {
    try self.send(&.{ .cancel = .{ .step = step } });
}
fn handleExit(self: *App, event: *const terminal.Input.Key, notice_shown: bool) !void {
    if (event.* == .ctrl and event.ctrl == 'd' and self.mode != .prompt)
        self.ctrl_d_ms_last = self.nowMs();
    if (event.* == .ctrl and event.ctrl == 'c' and
        (self.mode == .prompt or self.mode == .turn or self.mode == .sign_in) and
        !self.draftEmpty())
    {
        if (self.mode == .prompt) self.clearOrQuit() else self.clearDraft();
        return;
    }
    if (event.* == .escape and self.mode == .turn) {
        if (notice_shown and self.confirmation != .cancel) return;
        if (!self.draftEmpty() and self.confirmation != .cancel) {
            try self.reportNotice(.warning, turn_cancel_notice, .{});
            self.confirmation = .cancel;
            return;
        }
        return self.cancel(false);
    }
    switch (self.mode) {
        .prompt => switch (event.*) {
            .escape => try self.send(&.dismiss_offer),
            .ctrl => |letter| switch (letter) {
                'c' => self.clearOrQuit(),
                'd' => try self.quitOrWarn(),
                else => unreachable,
            },
            else => unreachable,
        },
        .picker, .fetch => try self.cancel(event.* == .escape),
        .turn, .sign_in, .page => try self.cancel(false),
    }
}
fn handleKey(self: *App, event: *const terminal.Input.Key) !void {
    self.disarm(event);
    const notice_shown = self.screen.notice != null;
    self.screen.clearNotice();
    if (notice_shown and self.confirmation == null)
        _ = self.controller.submit(&.{ .dismiss_notice = self.screen.notice_id });
    if (isExitKey(event)) return self.handleExit(event, notice_shown);
    switch (self.mode) {
        .prompt, .turn, .sign_in => {
            if (try self.editKey(event)) return;
            switch (event.*) {
                .enter => try self.submit(),
                .ctrl => |letter| if (letter == 'n' and self.mode == .prompt) {
                    const confirmed = self.confirmation == .removal;
                    self.confirmation = null;
                    try self.send(&.{ .take_offer = .{ .confirmed = confirmed } });
                },
                else => {},
            }
        },
        .picker => {
            const picker = self.screen.activePicker() orelse return;
            switch (event.*) {
                .up => try picker.moveUp(),
                .down => try picker.moveDown(),
                .enter => {
                    const confirmed = self.confirmation == .rewind;
                    self.confirmation = null;
                    const cursor = picker.cursor;
                    try self.send(&.{ .select = .{ .cursor = cursor, .confirmed = confirmed } });
                },
                else => {},
            }
        },
        .fetch => {},
        .page => {
            const page = self.screen.activePage() orelse return;
            const size: terminal.View.Size = .{
                .columns = self.screen.columns,
                .rows = self.screen.rows,
            };
            switch (event.*) {
                .enter => if (page.action == .apply) try self.send(&.apply_preview),
                .up => page.moveUp(size),
                .down => page.moveDown(size),
                .page_up => page.pageUp(size),
                .page_down => page.pageDown(size),
                .home => page.moveHome(),
                .end => page.moveEnd(size),
                .char => |codepoint| if (codepoint == 'm' or codepoint == 'M') {
                    page.toggleSource(size);
                },
                else => {},
            }
        },
    }
}
fn reportNotice(
    self: *App,
    severity: application.Message.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const notice = try application.Message.print(self.gpa, severity, format, args);
    if (self.confirmation == .message) self.confirmation = null;
    self.screen.setNotice(notice);
}
test "a Herdr startup failure stays in canonical snapshots, and the branch stays known" {
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
        .environment = &environment,
        .device = device.device(),
        .herdr = .{ .socket_path = "/unused", .pane_id = "p1" },
    });
    defer app.deinit();
    const blocks = app.screen.transcript.block_list.items;
    const notice = &blocks[blocks.len - 1].content.event;
    try std.testing.expectEqual(.failure, notice.severity);
    try testing.expectContains(
        notice.text.items,
        "Drinky could not start the state reports to Herdr because of error " ++
            "ConcurrencyUnavailable.",
    );
    try std.testing.expectEqualStrings("main", app.screen.branch().?);
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

test "a prompt runs a turn through the session, and the answer joins the transcript" {
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
}

const sign_in_titles = blk: {
    var titles: [accounts.Account.table.len][]const u8 = undefined;
    for (&accounts.Account.table, 0..) |*row, index| titles[index] = "Sign in: " ++ row.id;
    break :blk titles;
};

const retry_note = "Drinky asked the model to continue from the committed work.";
const short_answer_title = "Short answer";
const turn_message_notice = "Drinky sends no message while a turn runs. The draft stays.";
const removal_warning = "Press Ctrl+N again to remove the canceled turn. Tool changes stay.";
const rewind_warning = "Press Enter again to rewind. Tool changes stay.";

const Rig = struct {
    tmp: std.testing.TmpDir,
    directory: [:0]const u8,
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

        try self.app.init(options.allocator, io, &.{
            .working_directory = self.directory,
            .home = self.directory,
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
        "\"text\":\"<retry_request>\\nThe provider is overloaded. Details: 500 Internal Server " ++
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

const write_call_stream =
    "data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"fc_1\"," ++
    "\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call_1\"," ++
    "\"name\":\"write\",\"arguments\":\"{}\"}}\n" ++
    "\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n" ++
    "\n";

test "Ctrl+N warns before it removes a canceled turn that ran a mutating tool" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    const replies = [_]providers.testing.FakeTransport.Reply{
        .{ .body = write_call_stream },
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
        .{ .body = write_call_stream },
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
        .{ .status = "Commands during a turn: /verbose." },
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
        .{ .text = application.reference.fetch_wait_text },
    });
    try rig.keys("\x1b");
    try rig.waitFor(&.{
        .{ .text = model_picker },
        .{ .absent = application.reference.fetch_wait_text },
        .{ .status = "You canceled the model fetch." },
    });
    try std.testing.expect(step_stall.canceled);

    try rig.keys("\r");
    try command_stall.reached.wait(std.testing.io);
    try rig.waitFor(&.{.{ .text = application.reference.fetch_wait_text }});
    try rig.keys("\x03");
    try rig.waitFor(&.{
        .{ .absent = "Model: openai-api-key · " },
        .{ .absent = application.reference.fetch_wait_text },
        .{ .status = "You canceled the model selection." },
    });
    try std.testing.expect(command_stall.canceled);
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
        .{ .rows = &.{ "cut", application.support.truncated.content } },
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
            .{ .text = application.support.truncated.content },
        });
        const output = try rig.device.outputBytes(gpa);
        defer gpa.free(output);
        try testing.expectContains(output, "\x1b[31m⚠ " ++ application.support.truncated.content);
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
    for (0..10) |_| try rig.keys("\x1b[B");
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
        &.{ .{ .text = application.support.truncated.content }, .{ .absent = "Enter: Apply" } },
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

fn verboseNotice(verbose: bool) []const u8 {
    return if (verbose) "Verbose output is on." else "Verbose output is off.";
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

test "exits after page and turn responses use the authoritative interaction" {
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
    try rig.keys("\r");
    try rig.waitFor(&.{ .{ .status = refusal_offer }, .{ .editor = "/nope" } });
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}
