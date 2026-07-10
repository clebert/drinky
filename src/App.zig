//! The composition root and event loop. Wires the terminal, renderer, input
//! parser, editor, and agent together: ensures the user is authenticated, then
//! reads keys into the editor and drives one agent turn per submitted line,
//! streaming the reply into the live region. Presentation of agent events
//! (`onText`/`onToolStart`/`onToolResult`/`onError`) lives here.

const std = @import("std");

const Agent = @import("Agent.zig");
const anthropic = @import("anthropic/root.zig");
const command = @import("command/root.zig");
const models = @import("models.zig");
const provider = @import("provider.zig");
const terminal = @import("terminal/root.zig");
const tui = @import("tui/root.zig");

const App = @This();

const model = "claude-sonnet-4-6";
const model_info = models.get(.anthropic, model) orelse
    @compileError("default model \"" ++ model ++ "\" is not in the model table");
const system_prompt =
    "You are pith, a small coding assistant running in a terminal. Be concise. " ++
    "Explore the working directory with find (by name) and grep (literal text in file contents), read files " ++
    "with read, create or overwrite them with write, and change existing files with edit " ++
    "(give old_text that occurs exactly once).";

const dim = "\x1b[2m";
const red = "\x1b[31m";
const reset = "\x1b[0m";
const user_bg = "\x1b[48;2;52;53;65m";
const user_fg = "\x1b[38;2;212;212;212m";
const tool_fg = "\x1b[38;2;212;212;212m";
const tool_pending_bg = "\x1b[48;2;40;40;50m";
const tool_success_bg = "\x1b[48;2;40;50;40m";
const tool_error_bg = "\x1b[48;2;60;40;40m";
const accent_fg = "\x1b[38;2;138;190;183m";
const muted_fg = "\x1b[38;2;128;128;128m";

/// Braille frames for the "Working…" spinner, advanced one step per stream event.
const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Two Ctrl+C presses within this window quit; a lone press clears the editor.
const ctrl_c_window_ms = 500;

const Styled = struct { style: []const u8, prefix: []const u8, text: []const u8 };

/// The tool call currently running: its blue box shows in the live region for
/// the whole blocking call. Both strings are owned and freed on completion.
const ActiveTool = struct { name: []const u8, input_json: []const u8 };

const Picking = struct {
    picker: tui.Picker,
    /// Command re-run with the chosen option when the picker is confirmed.
    command: []const u8,
};

gpa: std.mem.Allocator,
io: std.Io,
tty: terminal.Tty,
renderer: tui.Renderer,
input: tui.Input,
editor: tui.Editor,
auth: anthropic.Auth,
agent: Agent,
pending: std.ArrayList(u8),
scratch: std.ArrayList(u8),
lines: std.ArrayList([]const u8),
/// The composed live region; owns each line so sections built into shared
/// scratch buffers can be reused between them.
live: std.ArrayList([]u8),
status_buffer: std.ArrayList(u8),
columns: usize,
running: bool,
/// A turn is streaming: show the spinner and keep the input box visible.
busy: bool,
spinner_frame: usize,
active_tool: ?ActiveTool,
/// The last committed row is a blank/padding row, so no extra gap is owed.
trailing_gap: bool,
/// Currently committing a run of assistant text, whose leading gap is emitted
/// once at the run's start.
in_text: bool,
last_ctrl_c: i64,
picking: ?Picking,

/// Authenticate (logging in if needed), then run the interactive loop until
/// the user quits or stdin closes. Pin the value: streams borrow its buffers.
pub fn run(self: *App, gpa: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    self.gpa = gpa;
    self.io = io;
    self.columns = 80;
    self.last_ctrl_c = 0;
    self.picking = null;
    self.busy = false;
    self.spinner_frame = 0;
    self.active_tool = null;
    self.trailing_gap = false;
    self.in_text = false;
    defer self.closePicker();
    defer self.clearActiveTool();
    self.pending = .empty;
    self.scratch = .empty;
    self.lines = .empty;
    self.live = .empty;
    self.status_buffer = .empty;
    defer self.pending.deinit(gpa);
    defer self.scratch.deinit(gpa);
    defer self.lines.deinit(gpa);
    defer self.live.deinit(gpa);
    defer self.clearLive();
    defer self.status_buffer.deinit(gpa);

    self.auth = try anthropic.Auth.init(gpa, io, home);
    defer self.auth.deinit();
    try self.ensureAuth();

    self.agent = Agent.init(gpa, io, provider.Client.init(.anthropic, gpa, io, &self.auth), .{ .model = model_info, .system = system_prompt });
    defer self.agent.deinit();

    try self.tty.init(io);
    defer self.tty.deinit();
    self.renderer = tui.Renderer.init(gpa, self.tty.writer());
    defer self.renderer.deinit();
    self.input = tui.Input.init(gpa);
    defer self.input.deinit();
    self.editor = tui.Editor.init(gpa);
    defer self.editor.deinit();

    try self.renderer.commit(&.{dim ++ "pith — enter: send · shift+enter: newline · esc: cancel · ctrl+c: clear (twice: quit) · ctrl+d: quit" ++ reset});
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

fn handleKey(self: *App, event: tui.Input.Key) !void {
    if (self.picking != null) return self.handlePickerKey(event);
    switch (event) {
        .char => |codepoint| try self.editor.insertCodepoint(codepoint),
        .paste => |text| try self.editor.insert(text),
        .backspace => self.editor.backspace(),
        .left => self.editor.moveLeft(),
        .right => self.editor.moveRight(),
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
        .escape, .up, .down, .unknown => return,
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

/// Recompose and repaint the live region from the current state. Idle shows the
/// input box; a picker replaces it; a turn stacks the in-progress output, the
/// active tool's blue box, and the spinner above the (inert) input box. The
/// status line stays pinned to the bottom in every phase.
fn refresh(self: *App) !void {
    self.columns = self.tty.size().columns;
    self.clearLive();
    if (self.picking) |*picking| {
        try picking.picker.render(self.columns, &self.scratch, &self.lines);
        try self.pushLiveLines(self.lines.items);
    } else {
        if (self.busy) {
            if (self.pending.items.len > 0) try self.pushLive(self.pending.items);
            if (self.active_tool) |*active| try self.pushToolBox(active);
            try self.pushSpinner();
        }
        try self.editor.render(self.columns, &self.scratch, &self.lines);
        try self.pushLiveLines(self.lines.items);
    }
    try self.pushLive(try self.statusLine());
    try self.renderer.render(self.live.items);
}

/// Free the composed live region.
fn clearLive(self: *App) void {
    for (self.live.items) |line| self.gpa.free(line);
    self.live.clearRetainingCapacity();
}

/// Copy `line` into an owned row of the live region.
fn pushLive(self: *App, line: []const u8) !void {
    try self.live.append(self.gpa, try self.gpa.dupe(u8, line));
}

fn pushLiveLines(self: *App, lines: []const []const u8) !void {
    for (lines) |line| try self.pushLive(line);
}

/// Push the running tool's blue box, showing the call and its arguments.
fn pushToolBox(self: *App, active: *const ActiveTool) !void {
    const text = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ active.name, active.input_json });
    defer self.gpa.free(text);
    try self.renderBox(.{ .background = tool_pending_bg, .foreground = tool_fg }, text, &self.scratch, &self.lines);
    try self.pushLiveLines(self.lines.items);
}

/// Push the `⠋ Working…` spinner: accent glyph, muted message.
fn pushSpinner(self: *App) !void {
    const gpa = self.gpa;
    const frame = spinner_frames[self.spinner_frame % spinner_frames.len];
    self.scratch.clearRetainingCapacity();
    try self.scratch.appendSlice(gpa, accent_fg);
    try self.scratch.appendSlice(gpa, frame);
    try self.scratch.appendSlice(gpa, reset);
    try self.scratch.appendSlice(gpa, " ");
    try self.scratch.appendSlice(gpa, muted_fg);
    try self.scratch.appendSlice(gpa, "Working…");
    try self.scratch.appendSlice(gpa, reset);
    try self.pushLive(self.scratch.items);
}

/// Advance the spinner one frame. The loop is blocked during a turn, so this
/// runs per stream event rather than on a timer.
fn advanceSpinner(self: *App) void {
    self.spinner_frame = (self.spinner_frame + 1) % spinner_frames.len;
}

fn statusLine(self: *App) ![]const u8 {
    const stats = self.agent.stats;
    return tui.status.render(.{
        .last = stats.last,
        .cost = stats.cost,
        .saved = stats.saved,
        .context_window = self.agent.model.context_window,
        .model = self.agent.model.name,
    }, self.columns, &self.status_buffer, self.gpa);
}

fn submit(self: *App) !void {
    const trimmed = std.mem.trim(u8, self.editor.content(), " \t\r\n");
    if (trimmed.len == 0) return;
    const text = try self.gpa.dupe(u8, trimmed);
    defer self.gpa.free(text);
    self.editor.clear();

    try self.refresh();
    try self.commitUserMessage(text);

    if (std.mem.startsWith(u8, text, "/")) {
        try self.runCommand(text);
    } else {
        try self.runTurn(text);
    }
    try self.refresh();
}

/// Drive one agent turn, streaming its reply into the live region while the
/// spinner and (inert) input box stay pinned below it.
fn runTurn(self: *App, text: []const u8) !void {
    self.busy = true;
    self.in_text = false;
    self.spinner_frame = 0;
    self.clearActiveTool();
    try self.refresh();
    self.agent.run(text, self) catch |err| {
        try self.flushPending();
        try self.emitError(@errorName(err));
    };
    try self.flushPending();
    self.clearActiveTool();
    self.busy = false;
}

/// Handle a slash command locally: either print its feedback or open a picker.
fn runCommand(self: *App, line: []const u8) !void {
    var context: command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    try self.handleOutcome(try command.run(&context, line));
}

/// Present a command outcome: print its feedback, or open its picker.
fn handleOutcome(self: *App, outcome: command.Outcome) !void {
    switch (outcome) {
        .feedback => |feedback| {
            defer self.gpa.free(feedback.content);
            try self.commitFeedback(feedback.content, feedback.is_error);
        },
        .pick => |pick| self.openPicker(pick),
    }
}

/// Commit a command's feedback one line per row, red when it reports failure.
fn commitFeedback(self: *App, content: []const u8, is_error: bool) !void {
    const style = if (is_error) red else dim;
    const prefix = if (is_error) "error: " else "  ";
    try self.gap();
    var feedback = std.mem.splitScalar(u8, content, '\n');
    while (feedback.next()) |feedback_line| {
        try self.commitLine(.{ .style = style, .prefix = prefix, .text = feedback_line });
    }
    self.trailing_gap = false;
}

/// Enter picker mode over a command's options; navigation and confirmation run
/// through `handlePickerKey`. Takes ownership of `pick.options`.
fn openPicker(self: *App, pick: command.Outcome.Pick) void {
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

fn handlePickerKey(self: *App, event: tui.Input.Key) !void {
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
    var context: command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    const outcome = try command.apply(&context, picking.command, picking.picker.choice());
    self.closePicker();
    try self.refresh();
    try self.handleOutcome(outcome);
    try self.refresh();
}

fn cancelPicker(self: *App) !void {
    self.closePicker();
    try self.refresh();
    try self.gap();
    try self.commitLine(.{ .style = dim, .prefix = "  ", .text = "cancelled" });
    self.trailing_gap = false;
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
    try self.pending.appendSlice(self.gpa, delta);
    while (true) {
        const line = self.pending.items;
        if (std.mem.indexOfScalar(u8, line, '\n')) |newline| {
            try self.beginText();
            try self.renderer.commit(&.{line[0..newline]});
            self.trailing_gap = newline == 0;
            self.dropPending(newline + 1);
            continue;
        }
        if (tui.width.display(line) <= self.columns) break;
        const fit = tui.width.truncate(line, self.columns).len;
        try self.beginText();
        try self.renderer.commit(&.{line[0..fit]});
        self.trailing_gap = false;
        self.dropPending(fit);
    }
    try self.refresh();
}

pub fn onToolStart(self: *App, name: []const u8, input_json: []const u8) !void {
    self.advanceSpinner();
    try self.flushPending();
    self.clearActiveTool();
    self.active_tool = .{
        .name = try self.gpa.dupe(u8, name),
        .input_json = try self.gpa.dupe(u8, input_json),
    };
    try self.refresh();
}

pub fn onToolResult(self: *App, name: []const u8, content: []const u8, is_error: bool) !void {
    self.advanceSpinner();
    const first = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    const background = if (is_error) tool_error_bg else tool_success_bg;
    const arguments = try self.gpa.dupe(u8, if (self.active_tool) |active| active.input_json else "");
    defer self.gpa.free(arguments);
    self.clearActiveTool();
    try self.refresh();
    const text = try std.fmt.allocPrint(self.gpa, "{s} {s}\n→ {s}", .{ name, arguments, first });
    defer self.gpa.free(text);
    try self.renderBox(.{ .background = background, .foreground = tool_fg }, text, &self.scratch, &self.lines);
    try self.renderer.commit(self.lines.items);
    self.trailing_gap = true;
}

pub fn onError(self: *App, text: []const u8) !void {
    self.advanceSpinner();
    try self.flushPending();
    try self.emitError(text);
    try self.refresh();
}

/// Commit an error line, separated from whatever precedes it.
fn emitError(self: *App, text: []const u8) !void {
    try self.gap();
    try self.commitLine(.{ .style = red, .prefix = "error: ", .text = text });
    self.trailing_gap = false;
}

/// End a run of assistant text: commit the trailing partial line, if any, and
/// drop it from the live region so it is not shown twice.
fn flushPending(self: *App) !void {
    if (self.pending.items.len > 0) {
        try self.beginText();
        const tail = try self.gpa.dupe(u8, self.pending.items);
        defer self.gpa.free(tail);
        self.pending.clearRetainingCapacity();
        try self.refresh();
        try self.renderer.commit(&.{tail});
        self.trailing_gap = false;
    }
    self.in_text = false;
}

fn dropPending(self: *App, count: usize) void {
    const kept = self.pending.items.len - count;
    std.mem.copyForwards(u8, self.pending.items[0..kept], self.pending.items[count..]);
    self.pending.shrinkRetainingCapacity(kept);
}

/// Commit the submitted message as a grey padded box filling the terminal width.
fn commitUserMessage(self: *App, text: []const u8) !void {
    try self.renderBox(.{ .background = user_bg, .foreground = user_fg }, text, &self.scratch, &self.lines);
    try self.renderer.commit(self.lines.items);
    self.trailing_gap = true;
}

/// Build a padded background block into `buffer`/`lines` (both cleared first): a
/// blank padding row, the `text` wrapped to the inner width with a one-space
/// left pad and the background filled to full width, and a blank padding row —
/// at least three rows. `lines` borrows from `buffer`, so keep it alive.
fn renderBox(
    self: *App,
    style: struct { background: []const u8, foreground: []const u8 },
    text: []const u8,
    buffer: *std.ArrayList(u8),
    lines: *std.ArrayList([]const u8),
) !void {
    const gpa = self.gpa;
    const columns = self.columns;
    buffer.clearRetainingCapacity();
    lines.clearRetainingCapacity();

    var content: std.ArrayList([]const u8) = .empty;
    defer content.deinit(gpa);
    try tui.width.wrap(text, @max(columns -| 2, 1), &content, gpa);

    // Build every row into `buffer`, then resolve the slices by offset only
    // after the last append: growth can move the backing store and invalidate a
    // slice taken earlier.
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(gpa);

    try offsets.append(gpa, buffer.items.len);
    try appendBlankRow(buffer, gpa, style.background, columns);
    for (content.items) |line| {
        try offsets.append(gpa, buffer.items.len);
        try buffer.appendSlice(gpa, style.background);
        try buffer.appendSlice(gpa, style.foreground);
        try buffer.append(gpa, ' ');
        try buffer.appendSlice(gpa, line);
        const used = 1 + tui.width.display(line);
        for (0..columns -| used) |_| try buffer.append(gpa, ' ');
        try buffer.appendSlice(gpa, reset);
    }
    try offsets.append(gpa, buffer.items.len);
    try appendBlankRow(buffer, gpa, style.background, columns);
    const end = buffer.items.len;

    for (offsets.items, 0..) |start, index| {
        const stop = if (index + 1 < offsets.items.len) offsets.items[index + 1] else end;
        try lines.append(gpa, buffer.items[start..stop]);
    }
}

fn appendBlankRow(
    buffer: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    background: []const u8,
    columns: usize,
) !void {
    try buffer.appendSlice(gpa, background);
    for (0..columns) |_| try buffer.append(gpa, ' ');
    try buffer.appendSlice(gpa, reset);
}

/// Commit a blank separator unless the last committed row already was one.
fn gap(self: *App) !void {
    if (!self.trailing_gap) {
        try self.renderer.commit(&.{""});
        self.trailing_gap = true;
    }
}

/// Emit the leading gap for a run of assistant text, once at the run's start.
fn beginText(self: *App) !void {
    if (!self.in_text) {
        try self.gap();
        self.in_text = true;
    }
}

fn clearActiveTool(self: *App) void {
    if (self.active_tool) |active| {
        self.gpa.free(active.name);
        self.gpa.free(active.input_json);
        self.active_tool = null;
    }
}

/// Commit a single styled status line, truncating `line.text` to fit.
fn commitLine(self: *App, line: Styled) !void {
    const available = self.columns -| tui.width.display(line.prefix);
    const clipped = tui.width.truncate(line.text, available);
    const composed = try std.fmt.allocPrint(self.gpa, "{s}{s}{s}{s}", .{ line.style, line.prefix, clipped, reset });
    defer self.gpa.free(composed);
    try self.renderer.commit(&.{composed});
}

// Mirrors the read loop's inner pipeline without a tty: one read chunk carries
// several keystrokes, which must decode, edit, and paint into the live region.
test "a read chunk drives the editor and paints the result" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var input = tui.Input.init(gpa);
    defer input.deinit();
    var editor = tui.Editor.init(gpa);
    defer editor.deinit();
    var renderer = tui.Renderer.init(gpa, &out.writer);
    defer renderer.deinit();
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
    try editor.render(80, &scratch, &lines);
    try renderer.render(lines.items);

    try std.testing.expectEqualStrings("hllo", editor.content());
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hllo") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.sync_set) != null);
}
