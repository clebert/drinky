//! The composition root and event loop. Wires the terminal, reconciling view,
//! input parser, editor, and agent together: ensures the user is
//! authenticated, then reads keys into the editor and drives one agent turn per
//! submitted line, streaming the reply into the transcript.
//!
//! Rendering projects the model onto a bounded window. Each refresh walks the
//! components — the `Entry` transcript blocks (user messages, model text, tool
//! results, notices), then the chrome (a running tool's box and the spinner, or
//! a picker, then the editor and status line) — newest first to find the visible
//! tail, then composes that tail straight into the `View`'s sink, which diffs it
//! and repaints the smallest region it can. Nothing is cached between frames:
//! layout is recomputed from the model each time, bounded to the window. One
//! layout rule spaces the components: a single blank line separates adjacent
//! ones, and boxes carry their own colored padding.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");
const ui = @import("ui/root.zig");

const App = @This();

const model = "claude-sonnet-4-6";
const model_info = ai.models.get(.anthropic, model) orelse
    @compileError("default model \"" ++ model ++ "\" is not in the model table");
const system_prompt =
    "You are pith, a small coding assistant running in a terminal. Be concise. " ++
    "Explore the working directory with find (by name) and grep (literal text in file contents), read files " ++
    "with read, create or overwrite them with write, and change existing files with edit " ++
    "(give old_text that occurs exactly once).";

const intro_text = "pith — enter: send · shift+enter: newline · esc: cancel · ctrl+c: clear (twice: quit) · ctrl+d: quit";

/// Two Ctrl+C presses within this window quit; a lone press clears the editor.
const ctrl_c_window_ms = 500;

/// The view retains this many pages (terminal heights) of the newest content.
const window_pages = 8;

/// Ids for the footer and live-tail rows, from a reserved high range a growing
/// transcript index (a block's id) can never reach, so anchors never alias as
/// the model grows.
const tool_box_id = std.math.maxInt(usize) - 4;
const spinner_id = std.math.maxInt(usize) - 3;
const picker_id = std.math.maxInt(usize) - 2;
const editor_id = std.math.maxInt(usize) - 1;
const status_id = std.math.maxInt(usize);

/// One screen component: a transcript block or a piece of chrome (the running
/// tool's box, the spinner, the editor, the picker, or the status line). Laid
/// out by `measure` and `renderSlot`, which switch on the tag.
const Component = union(enum) {
    entry: *const ui.block.Entry,
    tool_box,
    spinner,
    editor,
    picker,
    status,
};

/// A component in screen order: its content, the stable anchor `id` its rows
/// carry, and whether a blank separator row precedes it as its line 0.
const Slot = struct { component: Component, id: usize, leading_blank: bool };

/// The tool call currently running: its blue box shows in the live tail for the
/// whole blocking call. Both strings are owned and freed on completion.
const ActiveTool = struct { name: []const u8, input_json: []const u8 };

const Picking = struct {
    picker: ui.Picker,
    /// Command re-run with the chosen option when the picker is confirmed.
    command: []const u8,
};

gpa: std.mem.Allocator,
io: std.Io,
tty: terminal.Tty,
view: terminal.View,
input: terminal.Input,
editor: ui.Editor,
auth: ai.anthropic.Auth,
agent: ai.Agent,
/// The permanent blocks above the live tail, oldest first.
transcript: std.ArrayList(ui.block.Entry),
/// Index into `transcript` of the model-text block for the current text run, so
/// streamed deltas keep appending to it until a tool call or turn boundary.
current_model: ?usize,
/// Scratch backing the editor's or picker's materialized rows: their bytes live
/// in `scratch`, their row slices in `lines`, both reused each frame.
scratch: std.ArrayList(u8),
lines: std.ArrayList([]const u8),
/// The caret the editor reported this frame, placed onto its row while
/// composing; null when the editor is not shown.
caret: ?terminal.View.Caret,
/// The running tool's box text (`name input_json`), composed once per frame and
/// read by both layout passes.
tool_buffer: std.ArrayList(u8),
status_buffer: std.ArrayList(u8),
columns: usize,
rows: usize,
running: bool,
/// A turn is streaming: show the spinner and keep the input box visible.
busy: bool,
spinner_frame: usize,
active_tool: ?ActiveTool,
last_ctrl_c: i64,
picking: ?Picking,

/// Authenticate (logging in if needed), then run the interactive loop until
/// the user quits or stdin closes. Pin the value: streams borrow its buffers.
pub fn run(self: *App, gpa: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    self.gpa = gpa;
    self.io = io;
    self.columns = 80;
    self.rows = 24;
    self.last_ctrl_c = 0;
    self.picking = null;
    self.busy = false;
    self.spinner_frame = 0;
    self.active_tool = null;
    self.current_model = null;
    defer self.closePicker();
    defer self.clearActiveTool();
    self.transcript = .empty;
    self.scratch = .empty;
    self.lines = .empty;
    self.tool_buffer = .empty;
    self.status_buffer = .empty;
    self.caret = null;
    defer self.transcript.deinit(gpa);
    defer self.freeTranscript();
    defer self.scratch.deinit(gpa);
    defer self.lines.deinit(gpa);
    defer self.tool_buffer.deinit(gpa);
    defer self.status_buffer.deinit(gpa);

    self.auth = try ai.anthropic.Auth.init(gpa, io, home);
    defer self.auth.deinit();
    try self.ensureAuth();

    self.agent = ai.Agent.init(gpa, io, ai.provider.Client.init(.anthropic, gpa, io, &self.auth), .{ .model = model_info, .system = system_prompt });
    defer self.agent.deinit();

    try self.tty.init(io);
    defer self.tty.deinit();
    self.view = terminal.View.init(gpa, self.tty.writer());
    defer self.view.deinit();
    self.input = terminal.Input.init(gpa);
    defer self.input.deinit();
    self.editor = ui.Editor.init(gpa);
    defer self.editor.deinit();

    try self.appendEntry(.intro, false, intro_text);
    try self.refresh();

    self.running = true;
    var read_buffer: [4096]u8 = undefined;
    while (self.running) {
        var chunk: [1][]u8 = .{&read_buffer};
        const count = self.tty.reader().readVec(&chunk) catch break;
        if (count == 0) break;
        try self.input.feed(read_buffer[0..count]);
        while (self.input.next()) |event| try self.handleKey(event);
    }
}

fn ensureAuth(self: *App) !void {
    if (try self.auth.load()) return;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(self.io, &buffer);
    try self.auth.login(&stdout.interface);
}

fn handleKey(self: *App, event: terminal.Input.Key) !void {
    if (self.picking != null) return self.handlePickerKey(event);
    switch (event) {
        .char => |codepoint| try self.editor.insertCodepoint(codepoint),
        .paste => |text| try self.editor.insert(text),
        .backspace => self.editor.backspace(),
        .left => self.editor.moveLeft(),
        .right => self.editor.moveRight(),
        .up => self.editor.moveUp(self.columns),
        .down => self.editor.moveDown(self.columns),
        .home => self.editor.moveHome(),
        .end => self.editor.moveEnd(),
        .enter => return self.submit(),
        .newline => try self.editor.insert("\n"),
        .ctrl => |letter| switch (letter) {
            'c' => {
                self.clearOrQuit();
                if (!self.running) return;
            },
            'd' => {
                if (self.editor.content().len == 0) {
                    self.running = false;
                    return;
                }
            },
            'j' => try self.editor.insert("\n"),
            else => return,
        },
        .escape, .unknown => return,
    }
    try self.refresh();
}

/// Ctrl+C: clear the editor, or quit when pressed twice inside the window.
fn clearOrQuit(self: *App) void {
    const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    if (now - self.last_ctrl_c < ctrl_c_window_ms) {
        self.running = false;
    } else {
        self.editor.clear();
        self.last_ctrl_c = now;
    }
}

/// Repaint: read the terminal size (keeping the last known one if the query
/// fails) and snapshot the agent's status, then project the model onto the
/// window with those as inputs. Keeping projection a pure function of the model,
/// the size, and that snapshot lets it be driven without a live tty or agent.
fn refresh(self: *App) !void {
    const stats = self.agent.stats;
    const size: terminal.View.Size = if (self.tty.size()) |window|
        .{ .columns = window.columns, .rows = window.rows }
    else
        .{ .columns = self.columns, .rows = self.rows };
    try self.project(size, .{
        .last = stats.last,
        .cost = stats.cost,
        .saved = stats.saved,
        .context_window = self.agent.model.context_window,
        .model = self.agent.model.name,
    });
}

/// Project the model onto the window at `size` and hand it to the view, drawing
/// the status line from `status`. Components stack in screen order — the
/// transcript blocks oldest first, then the chrome (a running tool's box and the
/// spinner during a turn, or a picker, then the editor and the status line). Two
/// passes: pass one measures newest → oldest until the window is full, finding
/// the topmost visible component (the clip) and how many of its rows fall above
/// the window; pass two composes clip → newest into the sink, the clip alone
/// dropping those top rows. A blank separator precedes every component but the
/// first and the status line.
fn project(self: *App, size: terminal.View.Size, status: ui.status.Info) !void {
    self.columns = size.columns;
    self.rows = size.rows;
    self.caret = null;

    var chrome: [4]Slot = undefined;
    const chrome_count = try self.chromeSlots(&chrome, status);
    const slots = chrome[0..chrome_count];
    const total_slots = self.transcript.items.len + chrome_count;
    const capacity = @max(self.rows, 1) * window_pages;

    var total: usize = 0;
    var shown: usize = 0;
    while (shown < total_slots) {
        total += self.measure(slotAt(slots, self.transcript.items, shown), self.columns);
        shown += 1;
        if (total >= capacity) break;
    }
    const skip = if (total > capacity) total - capacity else 0;

    const sink = try self.view.beginFrame(.{ .columns = self.columns, .rows = self.rows }, window_pages);
    var reverse = shown;
    while (reverse > 0) {
        reverse -= 1;
        const slot = slotAt(slots, self.transcript.items, reverse);
        const placement: ui.paint.Placement = .{
            .sink = sink,
            .id = slot.id,
            .columns = self.columns,
            .base = if (slot.leading_blank) 1 else 0,
            .skip = if (reverse == shown - 1) skip else 0,
        };
        try self.renderSlot(slot, &placement);
    }
    try self.view.render();
}

/// Build the chrome components (bounded) into `out` in screen order and return
/// how many. Materializes what both passes read: the editor's or picker's rows
/// (and the editor caret) into `scratch`/`lines`, the tool box text into
/// `tool_buffer`, and the status line into `status_buffer`.
fn chromeSlots(self: *App, out: *[4]Slot, status: ui.status.Info) !usize {
    var count: usize = 0;
    if (self.picking) |*picking| {
        try picking.picker.render(self.columns, &self.scratch, &self.lines);
        out[count] = .{ .component = .picker, .id = picker_id, .leading_blank = true };
        count += 1;
    } else {
        if (self.busy) {
            if (self.active_tool) |*active| {
                self.tool_buffer.clearRetainingCapacity();
                try self.tool_buffer.appendSlice(self.gpa, active.name);
                try self.tool_buffer.append(self.gpa, ' ');
                try self.tool_buffer.appendSlice(self.gpa, active.input_json);
                out[count] = .{ .component = .tool_box, .id = tool_box_id, .leading_blank = true };
                count += 1;
            }
            out[count] = .{ .component = .spinner, .id = spinner_id, .leading_blank = true };
            count += 1;
        }
        self.caret = try self.editor.render(self.columns, !self.busy, &self.scratch, &self.lines);
        out[count] = .{ .component = .editor, .id = editor_id, .leading_blank = true };
        count += 1;
    }
    _ = try ui.status.render(status, self.columns, &self.status_buffer, self.gpa);
    out[count] = .{ .component = .status, .id = status_id, .leading_blank = false };
    count += 1;
    return count;
}

/// The component `reverse` steps back from the newest: the chrome first (its
/// newest last), then the transcript newest → oldest.
fn slotAt(chrome: []const Slot, transcript: []const ui.block.Entry, reverse: usize) Slot {
    if (reverse < chrome.len) return chrome[chrome.len - 1 - reverse];
    const index = transcript.len - 1 - (reverse - chrome.len);
    return .{ .component = .{ .entry = &transcript[index] }, .id = index, .leading_blank = index > 0 };
}

/// The physical rows `slot` occupies, its leading separator included. Must equal
/// exactly what `renderSlot` emits — the parity the diff and window math rely on.
fn measure(self: *App, slot: Slot, columns: usize) usize {
    const lead: usize = if (slot.leading_blank) 1 else 0;
    return lead + switch (slot.component) {
        .entry => |entry| entry.rows(columns),
        .tool_box => ui.paint.boxRows(self.tool_buffer.items, columns),
        .spinner, .status => 1,
        .editor, .picker => self.lines.items.len,
    };
}

fn freeTranscript(self: *App) void {
    for (self.transcript.items) |*entry| entry.deinit(self.gpa);
}

/// Compose `slot`'s rows through `placement`, dropping its top `skip` rows
/// (nonzero only for the clip). Its leading separator, when present, is line 0
/// and content follows from `base`.
fn renderSlot(self: *App, slot: Slot, placement: *const ui.paint.Placement) !void {
    if (slot.leading_blank and placement.skip == 0) {
        _ = placement.sink.begin();
        placement.sink.end(.{ .id = placement.id, .line = 0 });
    }
    switch (slot.component) {
        .entry => |entry| try entry.render(placement),
        .tool_box => try ui.paint.box(
            placement,
            .{ .background = ui.color.tool_pending_bg, .foreground = ui.color.tool_fg },
            self.tool_buffer.items,
        ),
        .spinner => try ui.paint.spinner(placement, self.spinner_frame),
        .status => try ui.paint.row(placement, self.status_buffer.items),
        .editor => try self.renderLines(placement, true),
        .picker => try self.renderLines(placement, false),
    }
}

/// The editor's or picker's materialized rows (in `lines`), placing the editor
/// caret on its row when `with_caret`.
fn renderLines(self: *App, placement: *const ui.paint.Placement, with_caret: bool) !void {
    const sink = placement.sink;
    for (self.lines.items, 0..) |content, index| {
        const line = placement.base + index;
        if (line < placement.skip) continue;
        const writer = sink.begin();
        try writer.writeAll(content);
        if (with_caret) if (self.caret) |caret| if (caret.row == index) sink.setCaret(caret.column);
        sink.end(.{ .id = placement.id, .line = line });
    }
}

/// Advance the spinner one frame. The loop is blocked during a turn, so this
/// runs per stream event rather than on a timer.
fn advanceSpinner(self: *App) void {
    self.spinner_frame = ui.paint.spinnerStep(self.spinner_frame);
}

/// Append a new transcript block copying `text` as its source.
fn appendEntry(self: *App, kind: ui.block.Entry.Kind, is_error: bool, text: []const u8) !void {
    var entry = try ui.block.Entry.init(self.gpa, kind, is_error, text);
    errdefer entry.deinit(self.gpa);
    try self.transcript.append(self.gpa, entry);
}

/// The model-text block for the current run, appending a fresh one on demand so
/// a run of streamed text collects into a single block.
fn currentModel(self: *App) !*std.ArrayList(u8) {
    if (self.current_model == null) {
        try self.appendEntry(.model, false, "");
        self.current_model = self.transcript.items.len - 1;
    }
    return &self.transcript.items[self.current_model.?].model;
}

fn submit(self: *App) !void {
    const trimmed = std.mem.trim(u8, self.editor.content(), " \t\r\n");
    if (trimmed.len == 0) return;
    const text = try self.gpa.dupe(u8, trimmed);
    defer self.gpa.free(text);
    self.editor.clear();
    try self.refresh();

    if (std.mem.startsWith(u8, text, "/")) {
        try self.runCommand(text);
    } else {
        try self.appendEntry(.user, false, text);
        try self.runTurn(text);
    }
    try self.refresh();
}

/// Drive one agent turn, streaming its reply into the transcript while the
/// spinner and (inert) input box stay pinned below it.
fn runTurn(self: *App, text: []const u8) !void {
    self.busy = true;
    self.current_model = null;
    self.spinner_frame = 0;
    self.clearActiveTool();
    try self.refresh();
    self.agent.run(text, self) catch |err| try self.emitError(@errorName(err));
    self.clearActiveTool();
    self.busy = false;
    self.current_model = null;
}

/// Handle a slash command locally: either print its feedback or open a picker.
fn runCommand(self: *App, line: []const u8) !void {
    var context: ai.command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    try self.handleOutcome(try ai.command.run(&context, line));
    try self.refresh();
}

/// Apply a command outcome to the transcript state; the caller refreshes.
fn handleOutcome(self: *App, outcome: ai.command.Outcome) !void {
    switch (outcome) {
        .feedback => |feedback| {
            defer self.gpa.free(feedback.content);
            try self.appendEntry(.feedback, feedback.is_error, feedback.content);
        },
        .pick => |pick| self.openPicker(pick),
    }
}

/// Enter picker mode over a command's options; navigation and confirmation run
/// through `handlePickerKey`. Takes ownership of `pick.options`.
fn openPicker(self: *App, pick: ai.command.Outcome.Pick) void {
    self.picking = .{
        .picker = .{
            .gpa = self.gpa,
            .title = pick.title,
            .options = pick.options,
            .cursor = pick.current orelse 0,
            .marked = pick.current,
        },
        .command = pick.command,
    };
}

fn handlePickerKey(self: *App, event: terminal.Input.Key) !void {
    const picker = &self.picking.?.picker;
    switch (event) {
        .up => picker.moveUp(),
        .down => picker.moveDown(),
        .enter => return self.confirmPicker(),
        .escape => return self.cancelPicker(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => return self.cancelPicker(),
            else => return,
        },
        else => return,
    }
    try self.refresh();
}

/// Re-apply the picker's command with the highlighted option as its argument.
fn confirmPicker(self: *App) !void {
    const picking = &self.picking.?;
    var context: ai.command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    const outcome = try ai.command.apply(&context, picking.command, picking.picker.choice());
    self.closePicker();
    try self.handleOutcome(outcome);
    try self.refresh();
}

fn cancelPicker(self: *App) !void {
    self.closePicker();
    try self.appendEntry(.feedback, false, "cancelled");
    try self.refresh();
}

fn closePicker(self: *App) void {
    if (self.picking) |*picking| {
        picking.picker.deinit();
        self.picking = null;
    }
}

pub fn onText(self: *App, delta: []const u8) !void {
    self.advanceSpinner();
    const text = try self.currentModel();
    try text.appendSlice(self.gpa, delta);
    try self.refresh();
}

pub fn onToolStart(self: *App, name: []const u8, input_json: []const u8) !void {
    self.advanceSpinner();
    self.clearActiveTool();
    self.current_model = null;
    self.active_tool = .{
        .name = try self.gpa.dupe(u8, name),
        .input_json = try self.gpa.dupe(u8, input_json),
    };
    try self.refresh();
}

pub fn onToolResult(self: *App, name: []const u8, content: []const u8, is_error: bool) !void {
    self.advanceSpinner();
    const first = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    const arguments = if (self.active_tool) |active| active.input_json else "";
    const text = try std.fmt.allocPrint(self.gpa, "{s} {s}\n→ {s}", .{ name, arguments, first });
    defer self.gpa.free(text);
    self.clearActiveTool();
    self.current_model = null;
    try self.appendEntry(.tool_result, is_error, text);
    try self.refresh();
}

pub fn onError(self: *App, text: []const u8) !void {
    self.advanceSpinner();
    try self.emitError(text);
}

/// Record an error as a red transcript notice and repaint.
fn emitError(self: *App, text: []const u8) !void {
    self.current_model = null;
    try self.appendEntry(.feedback, true, text);
    try self.refresh();
}

fn clearActiveTool(self: *App) void {
    if (self.active_tool) |active| {
        self.gpa.free(active.name);
        self.gpa.free(active.input_json);
        self.active_tool = null;
    }
}

// Mirrors the read loop's inner pipeline without a tty: one read chunk carries
// several keystrokes, which must decode, edit, and paint into the frame.
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
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    try input.feed("he\x7fllo");
    while (input.next()) |event| switch (event) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .backspace => editor.backspace(),
        else => {},
    };
    const maybe_caret = try editor.render(80, true, &scratch, &lines);
    const sink = try view.beginFrame(.{ .columns = 80, .rows = 24 }, 4);
    for (lines.items, 0..) |item, index| {
        const writer = sink.begin();
        try writer.writeAll(item);
        if (maybe_caret) |caret| if (caret.row == index) sink.setCaret(caret.column);
        sink.end(.{ .id = 0, .line = index });
    }
    try view.render();

    try std.testing.expectEqualStrings("hllo", editor.content());
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hllo") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.sync_set) != null);
}

// Physical rows in a fresh paint: rows are joined by `\r\n` and a row never
// contains one (`Sink.end` rejects both bytes), so the separators count them.
fn paintedRows(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\r\n") + 1;
}

// Wires up an `App` with only what `project` touches — the buffers, a real view
// and editor, an empty transcript, and inert chrome — leaving the tty and agent
// undefined, so the projection path runs end to end without either.
fn projectionApp(app: *App, gpa: std.mem.Allocator, writer: *std.Io.Writer) void {
    app.gpa = gpa;
    app.view = terminal.View.init(gpa, writer);
    app.editor = ui.Editor.init(gpa);
    app.transcript = .empty;
    app.scratch = .empty;
    app.lines = .empty;
    app.tool_buffer = .empty;
    app.status_buffer = .empty;
    app.caret = null;
    app.picking = null;
    app.busy = false;
    app.active_tool = null;
    app.spinner_frame = 0;
}

fn deinitProjectionApp(app: *App, gpa: std.mem.Allocator) void {
    app.freeTranscript();
    app.transcript.deinit(gpa);
    app.scratch.deinit(gpa);
    app.lines.deinit(gpa);
    app.tool_buffer.deinit(gpa);
    app.status_buffer.deinit(gpa);
    app.editor.deinit();
    app.view.deinit();
}

const test_status: ui.status.Info = .{
    .last = .{},
    .cost = 0,
    .saved = 0,
    .context_window = 1000,
    .model = "footerqq",
};

// The whole projection end to end: a transcript plus chrome (the editor and the
// status line) composed through a real view. Exercises the backward measure
// walk and the two-pass compose across transcript and chrome together, screen
// order newest at the bottom — none of which the per-entry tests reach.
test "projection stacks the transcript above the chrome, newest at the bottom" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var app: App = undefined;
    projectionApp(&app, gpa, &out.writer);
    defer deinitProjectionApp(&app, gpa);

    try app.appendEntry(.intro, false, "introxx");
    try app.appendEntry(.user, false, "useryy");
    try app.appendEntry(.model, false, "replyzz");

    try app.project(.{ .columns = 40, .rows = 24 }, test_status);

    const painted = out.written();
    const intro = std.mem.indexOf(u8, painted, "introxx").?;
    const user = std.mem.indexOf(u8, painted, "useryy").?;
    const reply = std.mem.indexOf(u8, painted, "replyzz").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    // Screen order top → bottom: intro, user box, model reply, then the footer.
    try std.testing.expect(intro < user);
    try std.testing.expect(user < reply);
    try std.testing.expect(reply < footer);
    // A small model in a tall window clips nothing, so the frame fits one page.
    try std.testing.expect(paintedRows(painted) < 24);
}

// When the transcript overflows the window, the oldest visible block is clipped
// to fill it exactly: the frame is `rows * window_pages` rows, that block's top
// rows dropped while its newest content and the chrome below still show.
test "projection clips the oldest block to fill the window exactly" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var app: App = undefined;
    projectionApp(&app, gpa, &out.writer);
    defer deinitProjectionApp(&app, gpa);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..60) |i| {
        if (i > 0) try text.append(gpa, '\n');
        var buffer: [8]u8 = undefined;
        try text.appendSlice(gpa, std.fmt.bufPrint(&buffer, "L{d}", .{i}) catch unreachable);
    }
    try app.appendEntry(.model, false, text.items);

    const rows: usize = 4;
    try app.project(.{ .columns = 40, .rows = rows }, test_status);

    const painted = out.written();
    try std.testing.expectEqual(rows * window_pages, paintedRows(painted));
    // The clip drops its top rows: its last line shows, its first does not, and
    // the chrome still sits at the bottom.
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "footerqq") != null);
}
