//! The composition root and event loop. Wires the terminal, differential
//! surface, input parser, editor, and agent together: ensures the user is
//! authenticated, then reads keys into the editor and drives one agent turn per
//! submitted line, streaming the reply into the transcript.
//!
//! Rendering is a single model: the whole frame is a list of lines, and every
//! refresh rebuilds it and hands it to the `Surface`, which diffs and repaints
//! the smallest region it can. The transcript is a list of `Entry` blocks (user
//! messages, model text, tool results, notices), each caching its own rendered
//! lines so only a changed block re-wraps; below it sit the live tail (a running
//! tool's box and the spinner) and the footer (the editor or picker, with the
//! status line). One layout rule spaces them: a single blank line separates
//! adjacent blocks, and boxes carry their own colored padding.

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

const intro_text = "pith — enter: send · shift+enter: newline · esc: cancel · ctrl+c: clear (twice: quit) · ctrl+d: quit";

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

const BoxStyle = struct { background: []const u8, foreground: []const u8 };

/// One transcript block. `text` is the source; `lines` caches its rendering at
/// width `columns` so a refresh re-wraps a block only when the width changes or
/// the block is invalidated (`columns = 0`). The model-text block grows in place
/// as its reply streams and is invalidated on each delta.
const Entry = struct {
    kind: Kind,
    is_error: bool,
    text: std.ArrayList(u8),
    lines: std.ArrayList([]u8),
    columns: usize,

    const Kind = enum { intro, user, model, tool_result, feedback };
};

/// The tool call currently running: its blue box shows in the live tail for the
/// whole blocking call. Both strings are owned and freed on completion.
const ActiveTool = struct { name: []const u8, input_json: []const u8 };

const Picking = struct {
    picker: tui.Picker,
    /// Command re-run with the chosen option when the picker is confirmed.
    command: []const u8,
};

gpa: std.mem.Allocator,
io: std.Io,
tty: terminal.Tty,
surface: tui.Surface,
input: tui.Input,
editor: tui.Editor,
auth: anthropic.Auth,
agent: Agent,
/// The permanent blocks above the live tail, oldest first.
transcript: std.ArrayList(Entry),
/// Index into `transcript` of the model-text block for the current text run, so
/// streamed deltas keep appending to it until a tool call or turn boundary.
current_model: ?usize,
/// The composed frame handed to the surface: borrowed slices into the entry
/// caches, the shared empty string for gaps, and `tail`. Rebuilt each refresh.
frame: std.ArrayList([]const u8),
/// Owns the live tail and footer lines for the current frame (freed each
/// refresh); the transcript's own lines are owned by their entries.
tail: std.ArrayList([]u8),
/// Scratch reused to build one line before it is copied into a cache or `tail`;
/// `lines` borrows it while a widget's rows are copied out.
scratch: std.ArrayList(u8),
lines: std.ArrayList([]const u8),
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
    self.frame = .empty;
    self.tail = .empty;
    self.scratch = .empty;
    self.lines = .empty;
    self.status_buffer = .empty;
    defer self.transcript.deinit(gpa);
    defer self.freeTranscript();
    defer self.frame.deinit(gpa);
    defer self.tail.deinit(gpa);
    defer self.clearTail();
    defer self.scratch.deinit(gpa);
    defer self.lines.deinit(gpa);
    defer self.status_buffer.deinit(gpa);

    self.auth = try anthropic.Auth.init(gpa, io, home);
    defer self.auth.deinit();
    try self.ensureAuth();

    self.agent = Agent.init(gpa, io, provider.Client.init(.anthropic, gpa, io, &self.auth), .{ .model = model_info, .system = system_prompt });
    defer self.agent.deinit();

    try self.tty.init(io);
    defer self.tty.deinit();
    self.surface = tui.Surface.init(gpa, self.tty.writer());
    defer self.surface.deinit();
    self.input = tui.Input.init(gpa);
    defer self.input.deinit();
    self.editor = tui.Editor.init(gpa);
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

/// Rebuild the whole frame and hand it to the surface, which diffs and repaints.
/// The transcript stacks first, each block from its own cache; then, unless a
/// picker has taken over the footer, the live tail (a running tool's box and the
/// spinner during a turn) and the footer (editor plus status). One blank line
/// separates adjacent blocks.
fn refresh(self: *App) !void {
    const size = self.tty.size();
    self.columns = size.columns;
    self.rows = size.rows;
    self.frame.clearRetainingCapacity();
    self.clearTail();

    for (self.transcript.items) |*entry| {
        try self.gap();
        try self.ensureEntry(entry);
        for (entry.lines.items) |line| try self.frame.append(self.gpa, line);
    }

    if (self.picking) |*picking| {
        try self.gap();
        try picking.picker.render(self.columns, &self.scratch, &self.lines);
        for (self.lines.items) |line| try self.pushTail(line);
        try self.pushTail(try self.statusLine());
    } else {
        if (self.busy) {
            if (self.active_tool) |*active| {
                try self.gap();
                try self.tailBox(.{ .background = tool_pending_bg, .foreground = tool_fg }, active);
            }
            try self.gap();
            try self.pushTail(try self.spinnerLine());
        }
        try self.gap();
        try self.editor.render(self.columns, !self.busy, &self.scratch, &self.lines);
        for (self.lines.items) |line| try self.pushTail(line);
        try self.pushTail(try self.statusLine());
    }

    try self.surface.render(self.frame.items, .{ .columns = self.columns, .rows = self.rows });
}

/// The single layout rule: one blank line before every block but the first. The
/// gap borrows a shared empty string, so it costs no allocation.
fn gap(self: *App) !void {
    if (self.frame.items.len > 0) try self.frame.append(self.gpa, "");
}

/// Copy `line` into a live-tail row, owned by `tail` and borrowed by `frame`.
fn pushTail(self: *App, line: []const u8) !void {
    const owned = try self.gpa.dupe(u8, line);
    try self.tail.append(self.gpa, owned);
    try self.frame.append(self.gpa, owned);
}

fn clearTail(self: *App) void {
    for (self.tail.items) |line| self.gpa.free(line);
    self.tail.clearRetainingCapacity();
}

fn freeTranscript(self: *App) void {
    for (self.transcript.items) |*entry| {
        entry.text.deinit(self.gpa);
        for (entry.lines.items) |line| self.gpa.free(line);
        entry.lines.deinit(self.gpa);
    }
}

/// Rebuild `entry.lines` for the current width unless the cache is already valid.
fn ensureEntry(self: *App, entry: *Entry) !void {
    if (entry.columns == self.columns) return;
    for (entry.lines.items) |line| self.gpa.free(line);
    entry.lines.clearRetainingCapacity();
    // Invalidate up front so a failed rebuild is retried, never left half-built
    // behind a width that happens to match again later.
    entry.columns = 0;
    const text = entry.text.items;
    switch (entry.kind) {
        .intro => try self.renderStyledLines(&entry.lines, dim, "", text),
        .feedback => try self.renderStyledLines(
            &entry.lines,
            if (entry.is_error) red else dim,
            if (entry.is_error) "error: " else "",
            text,
        ),
        .user => try self.renderBox(&entry.lines, .{ .background = user_bg, .foreground = user_fg }, text),
        .model => try self.renderWrapped(&entry.lines, text),
        .tool_result => try self.renderBox(&entry.lines, .{
            .background = if (entry.is_error) tool_error_bg else tool_success_bg,
            .foreground = tool_fg,
        }, text),
    }
    entry.columns = self.columns;
}

/// Copy `line` into an owned row of `out`.
fn pushLine(self: *App, out: *std.ArrayList([]u8), line: []const u8) !void {
    try out.append(self.gpa, try self.gpa.dupe(u8, line));
}

/// Append `text` wrapped to the terminal width as plain lines (the model reply).
fn renderWrapped(self: *App, out: *std.ArrayList([]u8), text: []const u8) !void {
    var wrapped: std.ArrayList([]const u8) = .empty;
    defer wrapped.deinit(self.gpa);
    try tui.width.wrap(text, @max(self.columns, 1), &wrapped, self.gpa);
    for (wrapped.items) |line| try self.pushLine(out, line);
}

/// Append each `\n`-separated line of `text`, styled and truncated to fit, with
/// `prefix` on every line (a notice, error, or the intro).
fn renderStyledLines(self: *App, out: *std.ArrayList([]u8), style: []const u8, prefix: []const u8, text: []const u8) !void {
    var pieces = std.mem.splitScalar(u8, text, '\n');
    while (pieces.next()) |piece| {
        const available = self.columns -| tui.width.display(prefix);
        const clipped = tui.width.truncate(piece, available);
        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(self.gpa, style);
        try self.scratch.appendSlice(self.gpa, prefix);
        try self.scratch.appendSlice(self.gpa, clipped);
        try self.scratch.appendSlice(self.gpa, reset);
        try self.pushLine(out, self.scratch.items);
    }
}

/// Render the running tool's blue pending box into the live tail.
fn tailBox(self: *App, style: BoxStyle, active: *const ActiveTool) !void {
    const text = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ active.name, active.input_json });
    defer self.gpa.free(text);
    const start = self.tail.items.len;
    try self.renderBox(&self.tail, style, text);
    for (self.tail.items[start..]) |line| try self.frame.append(self.gpa, line);
}

/// Append a padded background box: a blank padding row, `text` wrapped to the
/// inner width with a one-space left pad and the background filled to full
/// width, then a blank padding row. Self-separating, so it carries its own
/// vertical breathing room inside the one-blank-line block gap around it.
fn renderBox(self: *App, out: *std.ArrayList([]u8), style: BoxStyle, text: []const u8) !void {
    var content: std.ArrayList([]const u8) = .empty;
    defer content.deinit(self.gpa);
    try tui.width.wrap(text, @max(self.columns -| 2, 1), &content, self.gpa);

    try self.pushBoxBlank(out, style.background);
    for (content.items) |line| try self.pushBoxLine(out, style, line);
    try self.pushBoxBlank(out, style.background);
}

fn pushBoxBlank(self: *App, out: *std.ArrayList([]u8), background: []const u8) !void {
    self.scratch.clearRetainingCapacity();
    try self.scratch.appendSlice(self.gpa, background);
    for (0..self.columns) |_| try self.scratch.append(self.gpa, ' ');
    try self.scratch.appendSlice(self.gpa, reset);
    try self.pushLine(out, self.scratch.items);
}

fn pushBoxLine(self: *App, out: *std.ArrayList([]u8), style: BoxStyle, line: []const u8) !void {
    self.scratch.clearRetainingCapacity();
    try self.scratch.appendSlice(self.gpa, style.background);
    try self.scratch.appendSlice(self.gpa, style.foreground);
    try self.scratch.append(self.gpa, ' ');
    try self.scratch.appendSlice(self.gpa, line);
    const used = 1 + tui.width.display(line);
    for (0..self.columns -| used) |_| try self.scratch.append(self.gpa, ' ');
    try self.scratch.appendSlice(self.gpa, reset);
    try self.pushLine(out, self.scratch.items);
}

/// Build the `⠋ Working…` spinner line into `self.scratch`: accent glyph, muted
/// message. Returns the composed slice, valid until `self.scratch` next changes.
fn spinnerLine(self: *App) ![]const u8 {
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
    return self.scratch.items;
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

/// Append a new transcript block copying `text` as its source.
fn appendEntry(self: *App, kind: Entry.Kind, is_error: bool, text: []const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(self.gpa);
    try list.appendSlice(self.gpa, text);
    try self.transcript.append(self.gpa, .{
        .kind = kind,
        .is_error = is_error,
        .text = list,
        .lines = .empty,
        .columns = 0,
    });
}

/// The model-text block for the current run, appending a fresh one on demand so
/// a run of streamed text collects into a single block.
fn currentModel(self: *App) !*Entry {
    if (self.current_model == null) {
        try self.appendEntry(.model, false, "");
        self.current_model = self.transcript.items.len - 1;
    }
    return &self.transcript.items[self.current_model.?];
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
    var context: command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    try self.handleOutcome(try command.run(&context, line));
    try self.refresh();
}

/// Apply a command outcome to the transcript state; the caller refreshes.
fn handleOutcome(self: *App, outcome: command.Outcome) !void {
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
    const entry = try self.currentModel();
    try entry.text.appendSlice(self.gpa, delta);
    entry.columns = 0;
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

    var input = tui.Input.init(gpa);
    defer input.deinit();
    var editor = tui.Editor.init(gpa);
    defer editor.deinit();
    var surface = tui.Surface.init(gpa, &out.writer);
    defer surface.deinit();
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
    try editor.render(80, true, &scratch, &lines);
    try surface.render(lines.items, .{ .columns = 80, .rows = 24 });

    try std.testing.expectEqualStrings("hllo", editor.content());
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hllo") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.sync_set) != null);
}
