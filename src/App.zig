//! The composition root and event loop. Wires the terminal, reconciling view,
//! input parser, editor, and agent together: ensures the user is authenticated,
//! then reads keys into the editor and drives one agent turn per submitted line,
//! streaming the reply into the transcript.
//!
//! It owns the long-lived subsystems and the interaction state, but delegates the
//! two heavy jobs: `Transcript` holds the blocks above the live tail and the
//! "model run" invariant, and `layout` projects the visible scene onto the
//! bounded window. `refresh` is the seam — it snapshots the size and the agent's
//! status, assembles a plain `layout.Scene`, and hands it off, so the render path
//! is a pure function of the model with no live tty or agent needed.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");
const layout = @import("layout.zig");
const ui = @import("ui/root.zig");
const Transcript = @import("Transcript.zig");

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

/// Idle read timeout: how often the loop wakes to catch a terminal resize when
/// no key is pressed.
const resize_poll: std.Io.Timeout = .{
    .duration = .{ .raw = std.Io.Duration.fromMilliseconds(100), .clock = .awake },
};

gpa: std.mem.Allocator,
io: std.Io,
tty: terminal.Tty,
view: terminal.View,
input: terminal.Input,
editor: ui.Editor,
auth: ai.anthropic.Auth,
agent: ai.Agent,
transcript: Transcript,
columns: usize,
rows: usize,
running: bool,
last_ctrl_c: i64,
/// The current interaction: waiting for input, streaming a turn, or picking.
mode: Mode,

/// The current interaction. Exactly one input is live: the editor while waiting
/// (`prompt`) or streaming a turn (`turn`, where it is inert), or a `picker`.
const Mode = union(enum) {
    prompt,
    turn: Turn,
    picking: Picking,
};

/// A streaming turn: the spinner frame and the tool calls currently running,
/// each shown as its own box in the live tail.
const Turn = struct {
    spinner_frame: usize,
    tools: std.ArrayList(ActiveTool),
    /// `tools`' box text, rebuilt each frame so the tail gets a
    /// `[]const []const u8` without a fresh allocation per repaint.
    box_view: std.ArrayList([]const u8),

    fn boxes(self: *Turn, gpa: std.mem.Allocator) ![]const []const u8 {
        self.box_view.clearRetainingCapacity();
        for (self.tools.items) |tool| try self.box_view.append(gpa, tool.box);
        return self.box_view.items;
    }
};

/// One running tool call: its blue box shows in the live tail; `name` matches the
/// result to it and `input_json` labels that result. `box` is the box text
/// (`name input_json`). All owned, freed on completion.
const ActiveTool = struct { name: []const u8, input_json: []const u8, box: []const u8 };

const Picking = struct {
    picker: ui.Picker,
    /// Command re-run with the chosen option when the picker is confirmed.
    command: []const u8,
};

/// Authenticate (logging in if needed), then run the interactive loop until the
/// user quits or stdin closes. Pin the value: streams borrow its buffers.
pub fn run(self: *App, gpa: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    self.gpa = gpa;
    self.io = io;
    self.columns = 80;
    self.rows = 24;
    self.last_ctrl_c = 0;
    self.mode = .prompt;
    defer self.deinitMode();
    self.transcript = Transcript.init(gpa);
    defer self.transcript.deinit();

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

    try self.transcript.append(.intro, false, intro_text);
    try self.refresh();

    self.running = true;
    var read_buffer: [4096]u8 = undefined;
    while (self.running) {
        const count = (self.tty.read(&read_buffer, resize_poll) catch break) orelse {
            try self.resizeIfChanged();
            continue;
        };
        if (count == 0) continue;
        try self.input.feed(read_buffer[0..count]);
        while (self.input.next()) |event| try self.handleKey(event);
    }
}

/// Repaint if the terminal was resized while idle, so the frame follows the new
/// size without waiting for the next keystroke.
fn resizeIfChanged(self: *App) !void {
    const window = self.tty.size() orelse return;
    if (window.columns == self.columns and window.rows == self.rows) return;
    try self.refresh();
}

fn ensureAuth(self: *App) !void {
    if (try self.auth.load()) return;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(self.io, &buffer);
    try self.auth.login(&stdout.interface);
}

fn handleKey(self: *App, event: terminal.Input.Key) !void {
    switch (self.mode) {
        .picking => return self.handlePickerKey(event),
        .turn => return,
        .prompt => {},
    }
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
/// fails), snapshot the agent's status, assemble the visible scene, and hand it
/// to the layout projection.
fn refresh(self: *App) !void {
    const size: terminal.View.Size = if (self.tty.size()) |window|
        .{ .columns = window.columns, .rows = window.rows }
    else
        .{ .columns = self.columns, .rows = self.rows };
    self.columns = size.columns;
    self.rows = size.rows;

    const stats = self.agent.stats;
    const status: ui.status.Info = .{
        .last = stats.last,
        .cost = stats.cost,
        .saved = stats.saved,
        .context_window = self.agent.model.context_window,
        .model = self.agent.model.name,
    };

    const tail: layout.Tail = switch (self.mode) {
        .prompt => prompt: {
            self.editor.reflow(size.columns, size.rows);
            break :prompt .{ .prompt = &self.editor };
        },
        .turn => |*turn| turn: {
            self.editor.reflow(size.columns, size.rows);
            break :turn .{ .turn = .{
                .tools = try turn.boxes(self.gpa),
                .spinner = turn.spinner_frame,
                .editor = &self.editor,
            } };
        },
        .picking => |*picking| picking: {
            picking.picker.reflow(size.columns, size.rows);
            break :picking .{ .picking = &picking.picker };
        },
    };
    const scene: layout.Scene = .{
        .transcript = self.transcript.blocks(),
        .tail = tail,
        .status = &status,
    };
    try layout.project(&self.view, size, &scene);
}

/// Advance the spinner one frame. The loop is blocked during a turn, so this runs
/// per stream event rather than on a timer.
fn advanceSpinner(self: *App) void {
    switch (self.mode) {
        .turn => |*turn| turn.spinner_frame = ui.paint.spinnerStep(turn.spinner_frame),
        else => {},
    }
}

/// The running turn, if a turn is streaming.
fn activeTurn(self: *App) ?*Turn {
    return switch (self.mode) {
        .turn => |*turn| turn,
        else => null,
    };
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
        try self.transcript.append(.user, false, text);
        try self.runTurn(text);
    }
    try self.refresh();
}

/// Drive one agent turn, streaming its reply into the transcript while the
/// spinner and (inert) input box stay pinned below it.
fn runTurn(self: *App, text: []const u8) !void {
    self.transcript.endModelRun();
    self.mode = .{ .turn = .{ .spinner_frame = 0, .tools = .empty, .box_view = .empty } };
    try self.refresh();
    self.agent.run(text, self) catch |err| try self.emitError(@errorName(err));
    self.endTurn();
    self.transcript.endModelRun();
}

/// Free the finished turn's tool state and return to waiting for input.
fn endTurn(self: *App) void {
    if (self.activeTurn()) |turn| self.freeTurn(turn);
    self.mode = .prompt;
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
            try self.transcript.append(.feedback, feedback.is_error, feedback.content);
        },
        .pick => |pick| try self.openPicker(pick),
    }
}

/// Enter picker mode over a command's options; navigation and confirmation run
/// through `handlePickerKey`. Takes ownership of `pick.options`.
fn openPicker(self: *App, pick: ai.command.Outcome.Pick) !void {
    errdefer {
        for (pick.options) |option| self.gpa.free(option);
        self.gpa.free(pick.options);
    }
    self.mode = .{ .picking = .{
        .picker = try ui.Picker.init(self.gpa, pick.title, pick.options, pick.current),
        .command = pick.command,
    } };
}

fn handlePickerKey(self: *App, event: terminal.Input.Key) !void {
    const picker = &self.mode.picking.picker;
    switch (event) {
        .up => try picker.moveUp(),
        .down => try picker.moveDown(),
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
    const picking = &self.mode.picking;
    var context: ai.command.Context = .{ .gpa = self.gpa, .agent = &self.agent };
    const outcome = try ai.command.apply(&context, picking.command, picking.picker.choice());
    self.closePicker();
    try self.handleOutcome(outcome);
    try self.refresh();
}

fn cancelPicker(self: *App) !void {
    self.closePicker();
    try self.transcript.append(.feedback, false, "cancelled");
    try self.refresh();
}

fn closePicker(self: *App) void {
    switch (self.mode) {
        .picking => |*picking| {
            picking.picker.deinit();
            self.mode = .prompt;
        },
        else => {},
    }
}

pub fn onText(self: *App, delta: []const u8) !void {
    self.advanceSpinner();
    try self.transcript.appendModelText(delta);
    try self.refresh();
}

pub fn onToolStart(self: *App, name: []const u8, input_json: []const u8) !void {
    self.advanceSpinner();
    self.transcript.endModelRun();
    if (self.activeTurn()) |turn| try pushTool(turn, self.gpa, name, input_json);
    try self.refresh();
}

/// Allocate a running tool call's owned strings and record it on `turn`. Ends at
/// a committed append so a later fallible repaint can never orphan or double-free
/// the strings; on any failure here nothing is retained.
fn pushTool(turn: *Turn, gpa: std.mem.Allocator, name: []const u8, input_json: []const u8) !void {
    const box = try std.fmt.allocPrint(gpa, "{s} {s}", .{ name, input_json });
    errdefer gpa.free(box);
    const name_copy = try gpa.dupe(u8, name);
    errdefer gpa.free(name_copy);
    const arguments = try gpa.dupe(u8, input_json);
    errdefer gpa.free(arguments);
    try turn.tools.append(gpa, .{ .name = name_copy, .input_json = arguments, .box = box });
}

pub fn onToolResult(self: *App, name: []const u8, content: []const u8, is_error: bool) !void {
    self.advanceSpinner();
    const first = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    const finished = if (self.activeTurn()) |turn| takeTool(turn, name) else null;
    defer if (finished) |*tool| self.freeTool(tool);
    const arguments = if (finished) |tool| tool.input_json else "";
    const text = try std.fmt.allocPrint(self.gpa, "{s} {s}\n→ {s}", .{ name, arguments, first });
    defer self.gpa.free(text);
    try self.transcript.append(.tool_result, is_error, text);
    try self.refresh();
}

/// Remove the running tool matching `name` (or the oldest, if none matches) and
/// hand it to the caller to free.
fn takeTool(turn: *Turn, name: []const u8) ?ActiveTool {
    for (turn.tools.items, 0..) |tool, index| {
        if (std.mem.eql(u8, tool.name, name)) return turn.tools.orderedRemove(index);
    }
    if (turn.tools.items.len == 0) return null;
    return turn.tools.orderedRemove(0);
}

pub fn onError(self: *App, text: []const u8) !void {
    self.advanceSpinner();
    try self.emitError(text);
}

/// Record an error as a red transcript notice and repaint.
fn emitError(self: *App, text: []const u8) !void {
    try self.transcript.append(.feedback, true, text);
    try self.refresh();
}

fn freeTool(self: *App, tool: *const ActiveTool) void {
    self.gpa.free(tool.name);
    self.gpa.free(tool.input_json);
    self.gpa.free(tool.box);
}

fn freeTurn(self: *App, turn: *Turn) void {
    for (turn.tools.items) |*tool| self.freeTool(tool);
    turn.tools.deinit(self.gpa);
    turn.box_view.deinit(self.gpa);
}

/// Free whatever the current mode owns; called on shutdown.
fn deinitMode(self: *App) void {
    switch (self.mode) {
        .prompt => {},
        .turn => |*turn| self.freeTurn(turn),
        .picking => |*picking| picking.picker.deinit(),
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

    try input.feed("he\x7fllo");
    while (input.next()) |event| switch (event) {
        .char => |codepoint| try editor.insertCodepoint(codepoint),
        .backspace => editor.backspace(),
        else => {},
    };
    const sink = try view.beginFrame(.{ .columns = 80, .rows = 24 }, 4);
    const placement: ui.paint.Placement = .{ .sink = sink, .id = 0, .columns = 80, .base = 0, .skip = 0 };
    try editor.render(&placement, 24, true);
    try view.render();

    try std.testing.expectEqualStrings("hllo", editor.content());
    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "hllo") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.sync_set) != null);
}
