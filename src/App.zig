//! The composition root and event loop. Wires the terminal, renderer, input
//! parser, editor, and agent together: ensures the user is authenticated, then
//! reads keys into the editor and drives one agent turn per submitted line,
//! streaming the reply into the live region. Presentation of agent events
//! (`onText`/`onToolStart`/`onToolResult`/`onError`) lives here.

const std = @import("std");

const Agent = @import("agent/Agent.zig");
const Auth = @import("anthropic/Auth.zig");
const escape = @import("terminal/escape.zig");
const Terminal = @import("terminal/Terminal.zig");
const Editor = @import("tui/Editor.zig");
const Input = @import("tui/Input.zig");
const key = @import("tui/key.zig");
const Renderer = @import("tui/Renderer.zig");
const width = @import("tui/width.zig");

const App = @This();

const model = "claude-sonnet-4-6";
const system_prompt =
    "You are pith, a small coding assistant running in a terminal. Be concise. " ++
    "Read and write files in the working directory with the read and write tools.";

const dim = "\x1b[2m";
const red = "\x1b[31m";
const reset = "\x1b[0m";

gpa: std.mem.Allocator,
io: std.Io,
terminal: Terminal,
renderer: Renderer,
input: Input,
editor: Editor,
auth: Auth,
agent: Agent,
pending: std.ArrayList(u8),
scratch: std.ArrayList(u8),
lines: std.ArrayList([]const u8),
columns: usize,
running: bool,

/// Authenticate (logging in if needed), then run the interactive loop until
/// the user quits or stdin closes. Pin the value: streams borrow its buffers.
pub fn run(self: *App, gpa: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    self.gpa = gpa;
    self.io = io;
    self.columns = 80;
    self.pending = .empty;
    self.scratch = .empty;
    self.lines = .empty;
    defer self.pending.deinit(gpa);
    defer self.scratch.deinit(gpa);
    defer self.lines.deinit(gpa);

    self.auth = try Auth.init(gpa, io, home);
    defer self.auth.deinit();
    try self.ensureAuth();

    self.agent = Agent.init(gpa, io, &self.auth, model, system_prompt);
    defer self.agent.deinit();

    try self.terminal.init(io);
    defer self.terminal.deinit();
    self.renderer = Renderer.init(gpa, self.terminal.writer());
    defer self.renderer.deinit();
    self.input = Input.init(gpa);
    defer self.input.deinit();
    self.editor = Editor.init(gpa);
    defer self.editor.deinit();

    try self.renderer.commit(&.{dim ++ "pith — enter to send, ctrl-c to quit" ++ reset});
    try self.renderPrompt();

    self.running = true;
    var read_buffer: [4096]u8 = undefined;
    while (self.running) {
        var chunk: [1][]u8 = .{&read_buffer};
        const count = self.terminal.reader().readVec(&chunk) catch break;
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

fn handleKey(self: *App, event: key.Key) !void {
    switch (event) {
        .char => |codepoint| try self.editor.insertCodepoint(codepoint),
        .paste => |text| try self.editor.insert(text),
        .backspace => self.editor.backspace(),
        .left => self.editor.moveLeft(),
        .right => self.editor.moveRight(),
        .home => self.editor.moveHome(),
        .end => self.editor.moveEnd(),
        .enter => return self.submit(),
        .ctrl => |letter| switch (letter) {
            'c', 'd' => {
                self.running = false;
                return;
            },
            'j' => try self.editor.insert("\n"),
            else => return,
        },
        .up, .down, .unknown => return,
    }
    try self.renderPrompt();
}

fn renderPrompt(self: *App) !void {
    self.columns = self.terminal.size().columns;
    try self.editor.render(self.columns, &self.scratch, &self.lines);
    try self.renderer.render(self.lines.items);
}

fn submit(self: *App) !void {
    const trimmed = std.mem.trim(u8, self.editor.content(), " \t\r\n");
    if (trimmed.len == 0) return;
    const text = try self.gpa.dupe(u8, trimmed);
    defer self.gpa.free(text);
    self.editor.clear();

    try self.renderer.render(&.{});
    try self.commitWrapped(dim, "> ", text);
    try self.renderer.render(&.{dim ++ "…" ++ reset});

    self.agent.run(text, self) catch |err| {
        try self.flushPending();
        try self.commitLine(red, "error: ", @errorName(err));
    };
    try self.flushPending();
    try self.renderPrompt();
}

pub fn onText(self: *App, delta: []const u8) !void {
    try self.pending.appendSlice(self.gpa, delta);
    while (true) {
        const line = self.pending.items;
        if (std.mem.indexOfScalar(u8, line, '\n')) |newline| {
            try self.renderer.commit(&.{line[0..newline]});
            self.dropPending(newline + 1);
            continue;
        }
        if (width.display(line) <= self.columns) break;
        const fit = width.truncate(line, self.columns).len;
        try self.renderer.commit(&.{line[0..fit]});
        self.dropPending(fit);
    }
    try self.renderer.render(&.{self.pending.items});
}

pub fn onToolStart(self: *App, name: []const u8, input_json: []const u8) !void {
    try self.flushPending();
    try self.commitLine(dim, "· ", name);
    try self.commitLine(dim, "  ", input_json);
}

pub fn onToolResult(self: *App, name: []const u8, content: []const u8, is_error: bool) !void {
    _ = name;
    const first = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    const style = if (is_error) red else dim;
    try self.commitLine(style, "  → ", first);
}

pub fn onError(self: *App, text: []const u8) !void {
    try self.flushPending();
    try self.commitLine(red, "error: ", text);
}

/// Commit the in-progress assistant line, if any, and empty the live region.
fn flushPending(self: *App) !void {
    try self.renderer.render(&.{});
    if (self.pending.items.len > 0) {
        try self.renderer.commit(&.{self.pending.items});
        self.pending.clearRetainingCapacity();
    }
}

fn dropPending(self: *App, count: usize) void {
    const kept = self.pending.items.len - count;
    std.mem.copyForwards(u8, self.pending.items[0..kept], self.pending.items[count..]);
    self.pending.shrinkRetainingCapacity(kept);
}

/// Commit `text` wrapped to width, each line carrying `prefix` and `style`.
fn commitWrapped(self: *App, style: []const u8, prefix: []const u8, text: []const u8) !void {
    self.lines.clearRetainingCapacity();
    const available = self.columns -| width.display(prefix);
    try width.wrap(text, @max(available, 1), &self.lines, self.gpa);
    for (self.lines.items) |line| {
        const composed = try std.fmt.allocPrint(self.gpa, "{s}{s}{s}{s}", .{ style, prefix, line, reset });
        defer self.gpa.free(composed);
        try self.renderer.commit(&.{composed});
    }
}

/// Commit a single styled status line, truncating `text` to fit.
fn commitLine(self: *App, style: []const u8, prefix: []const u8, text: []const u8) !void {
    const available = self.columns -| width.display(prefix);
    const clipped = width.truncate(text, available);
    const composed = try std.fmt.allocPrint(self.gpa, "{s}{s}{s}{s}", .{ style, prefix, clipped, reset });
    defer self.gpa.free(composed);
    try self.renderer.commit(&.{composed});
}

// Mirrors the read loop's inner pipeline without a tty: one read chunk carries
// several keystrokes, which must decode, edit, and paint into the live region.
test "a read chunk drives the editor and paints the result" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var input = Input.init(gpa);
    defer input.deinit();
    var editor = Editor.init(gpa);
    defer editor.deinit();
    var renderer = Renderer.init(gpa, &out.writer);
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
    try std.testing.expect(std.mem.indexOf(u8, painted, escape.sync_set) != null);
}
