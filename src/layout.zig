//! Projection of either the conversation interface or a temporary full-window
//! page onto the bounded terminal `View`. Conversation components stack in
//! screen order: transcript blocks oldest first, then the live tail and status.
//! A page is exclusive and emits only its fixed header and visible body window.
//!
//! Conversation layout uses two passes: measure newest → oldest to find the
//! bounded clip, then compose clip → newest. The layout caches nothing between
//! frames and projects the scene again at each size. A single blank line
//! separates adjacent conversation components. Boxes carry their own colored
//! padding.

const std = @import("std");

const terminal = @import("terminal");

const ui = @import("ui/root.zig");

/// The view retains this many pages (terminal heights) of the newest content.
const window_pages = 8;

/// Anchor ids for the tail rows. They come from a reserved high range a growing
/// transcript index (a block's id) can never reach, so anchors never alias as
/// the model grows. The editor and picker share `id_input`: they occupy the same
/// region, so the diff repaints it in place when one replaces the other.
const id_reserved = std.math.maxInt(usize) - 255;
const id_status = id_reserved;
const id_input = id_reserved + 1;
const id_steering = id_reserved + 2;
const id_page = id_reserved + 3;
const id_hint = id_reserved + 4;

/// The anchor id of the tool box at `index` in the running turn. Grows downward
/// from just below the fixed ids, so it never wraps past `maxInt` however many
/// boxes one turn shows.
fn idTool(index: usize) usize {
    return id_reserved - 1 - index;
}

/// Everything one frame draws: either the conversation or an exclusive page.
pub const Scene = union(enum) {
    conversation: Conversation,
    page: *const ui.Page,

    pub const Conversation = struct {
        transcript: []const ui.block.Entry,
        tail: Tail,
        status: *const ui.status.Info,
    };
};

/// The live region below the transcript. A tagged union so exactly one input is
/// ever present and focused: the editor during a `prompt`, the same editor kept
/// live under a streaming `turn`'s chrome (for steering), or a `picker` that owns
/// the region.
pub const Tail = union(enum) {
    prompt: Prompt,
    turn: Turn,
    picking: *const ui.Picker,

    /// An idle prompt: the editor, and above it one optional control hint, such
    /// as the hint of a waiting retry.
    pub const Prompt = struct {
        hint: ?[]const u8,
        editor: *const ui.Editor,
    };

    /// A streaming turn: the running tool calls, the steering queue, then the
    /// editor with activity that crosses its separators. No line of a tool box
    /// wraps, so a box takes one row per line it holds: a committed call names
    /// what it acts on, one the model still streams counts the argument bytes
    /// that have arrived, and a call under a timeout adds the row that reports
    /// its time.
    pub const Turn = struct {
        tools: []const ui.paint.Box,
        activity: ui.paint.Activity,
        steering: []const []const u8,
        editor: *const ui.Editor,
    };
};

const EditorPresentation = struct {
    editor: *const ui.Editor,
    activity: ?ui.paint.Activity,
};

/// One screen component: a transcript block or a piece of the tail. Each variant
/// carries what `measure` and `render` need.
const Component = union(enum) {
    entry: *const ui.block.Entry,
    tool_box: ui.paint.Box,
    steering: []const []const u8,
    /// A muted control-hint row above the input.
    hint: []const u8,
    editor: EditorPresentation,
    picker: *const ui.Picker,
    status: *const ui.status.Info,

    /// The physical rows this component occupies, its leading separator excluded.
    /// Must equal exactly what `render` emits. The diff and window math rely on
    /// this parity.
    fn measure(self: *const Component, size: terminal.View.Size) usize {
        return switch (self.*) {
            .entry => |entry| entry.rows(size.columns),
            .tool_box => |box| ui.paint.boxRows(&box, size.columns),
            .steering => |messages| ui.paint.steeringRows(messages),
            .hint => |text| std.mem.count(u8, text, "\n") + 1,
            .editor => |presentation| presentation.editor.rows(size),
            .status => 1,
            .picker => |picker| picker.rows(size),
        };
    }

    /// Compose this component's rows through `placement` and drop its top `skip`
    /// rows (nonzero only for the clip).
    fn render(
        self: *const Component,
        placement: *const ui.paint.Placement,
        viewport_rows: usize,
    ) !void {
        switch (self.*) {
            .entry => |entry| try entry.render(placement),
            .tool_box => |box| try ui.paint.box(placement, .tool_pending, &box),
            .steering => |messages| try ui.paint.steering(placement, messages),
            .hint => |text| try ui.paint.notice(placement, &.{
                .role = .muted,
                .prefix = "",
            }, text),
            .status => |info| try ui.status.render(placement, info),
            .editor => |presentation| try presentation.editor.render(placement, &.{
                .viewport_rows = viewport_rows,
                .activity = presentation.activity,
            }),
            .picker => |picker| try picker.render(placement, viewport_rows),
        }
    }
};

/// A component in screen order: its content, the stable anchor `id` its rows
/// carry, and whether a blank separator row precedes it as its line 0.
const Slot = struct { component: Component, id: usize, leading_blank: bool };

/// Project `scene` onto the window at `size` and hand it to `view`.
pub fn project(view: *terminal.View, size: terminal.View.Size, scene: *const Scene) !void {
    switch (scene.*) {
        .conversation => try projectConversation(view, size, &scene.conversation),
        .page => |page| try projectPage(view, size, page),
    }
}

fn projectPage(view: *terminal.View, size: terminal.View.Size, page: *const ui.Page) !void {
    const sink = try view.beginFrame(.{ .columns = size.columns, .rows = size.rows }, 1);
    const placement: ui.paint.Placement = .{
        .sink = sink,
        .id = id_page,
        .columns = size.columns,
        .base = 0,
        .skip = 0,
    };
    try page.render(&placement, size);
    try view.render();
}

/// Fold one conversation onto the retained multi-page window.
fn projectConversation(
    view: *terminal.View,
    size: terminal.View.Size,
    scene: *const Scene.Conversation,
) !void {
    const total = scene.transcript.len + tailCount(&scene.tail) + 1;
    const capacity = @max(size.rows, 1) * window_pages;

    var rows: usize = 0;
    var shown: usize = 0;
    while (shown < total and rows < capacity) : (shown += 1) {
        const slot = slotAt(scene, total - 1 - shown);
        rows += @intFromBool(slot.leading_blank) + slot.component.measure(size);
    }
    const skip = if (rows > capacity) rows - capacity else 0;

    const sink = try view.beginFrame(.{ .columns = size.columns, .rows = size.rows }, window_pages);
    const start = total - shown;
    var index = start;
    while (index < total) : (index += 1) {
        const slot = slotAt(scene, index);
        const placement: ui.paint.Placement = .{
            .sink = sink,
            .id = slot.id,
            .columns = size.columns,
            .base = @intFromBool(slot.leading_blank),
            .skip = if (index == start) skip else 0,
        };
        // The leading separator (when present and not clipped) is the slot's line 0.
        if (slot.leading_blank and placement.skip == 0) {
            sink.begin();
            sink.end(.{ .id = slot.id, .line = 0 });
        }
        try slot.component.render(&placement, size.rows);
    }
    try view.render();
}

/// How many components the tail contributes.
fn tailCount(tail: *const Tail) usize {
    return switch (tail.*) {
        .prompt => |prompt| 1 + @as(usize, @intFromBool(prompt.hint != null)),
        .picking => 1,
        .turn => |turn| turn.tools.len + 1 + @intFromBool(turn.steering.len > 0),
    };
}

/// The component at screen index `index`: the transcript oldest first, then the
/// tail, then the status line.
fn slotAt(scene: *const Scene.Conversation, index: usize) Slot {
    if (index < scene.transcript.len) return .{
        .component = .{ .entry = &scene.transcript[index] },
        .id = index,
        .leading_blank = index > 0,
    };
    const offset = index - scene.transcript.len;
    if (offset < tailCount(&scene.tail)) return tailSlot(&scene.tail, offset);
    return .{ .component = .{ .status = scene.status }, .id = id_status, .leading_blank = false };
}

/// The tail component at `offset`, in screen order: for a turn the tool boxes,
/// then the steering queue (when non-empty), then the live editor. For a prompt
/// its hint row (when present), then the editor. Otherwise the sole input.
fn tailSlot(tail: *const Tail, offset: usize) Slot {
    switch (tail.*) {
        .prompt => |prompt| {
            if (prompt.hint) |text| {
                if (offset == 0) return .{
                    .component = .{ .hint = text },
                    .id = id_hint,
                    .leading_blank = true,
                };
            }
            return editorSlot(&.{ .editor = prompt.editor, .activity = null });
        },
        .picking => |picker| return .{
            .component = .{ .picker = picker },
            .id = id_input,
            .leading_blank = true,
        },
        .turn => |turn| {
            if (offset < turn.tools.len) return .{
                .component = .{ .tool_box = turn.tools[offset] },
                .id = idTool(offset),
                .leading_blank = true,
            };
            if (turn.steering.len > 0 and offset == turn.tools.len) return .{
                .component = .{ .steering = turn.steering },
                .id = id_steering,
                .leading_blank = true,
            };
            return editorSlot(&.{
                .editor = turn.editor,
                .activity = turn.activity,
            });
        },
    }
}

fn editorSlot(presentation: *const EditorPresentation) Slot {
    return .{ .component = .{ .editor = presentation.* }, .id = id_input, .leading_blank = true };
}

const test_status: ui.status.Info = .{
    .directory = "~/work",
    .branch = "main",
    .last = .{},
    .cost = 0,
    .context_window = 1000,
    .model = "footerqq",
    .effort = "high",
    .account = .anthropic_subscription,
    .quota = null,
};

// Projects `scene` into a fresh view at `size` and returns the frame's bytes,
// caller-owned.
fn projected(gpa: std.mem.Allocator, size: terminal.View.Size, scene: *const Scene) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    try project(&view, size, scene);
    return gpa.dupe(u8, out.written());
}

// The whole projection end to end: a transcript plus the tail (the prompt editor
// and the status line) composed through a real view. Exercises the backward
// measure walk and the two-pass compose across the transcript and the tail
// together. Screen order: newest at the bottom.
test "projection stacks the transcript above the tail, newest at the bottom" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.append(gpa, try ui.block.Entry.init(gpa, .intro, false, "introxx"));
    try entries.append(gpa, try ui.block.Entry.init(gpa, .user, false, "useryy"));
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, false, "replyzz"));

    const scene: Scene = .{ .conversation = .{
        .transcript = entries.items,
        .tail = .{ .prompt = .{ .hint = null, .editor = &editor } },
        .status = &test_status,
    } };
    const painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const intro = std.mem.indexOf(u8, painted, "introxx").?;
    const user = std.mem.indexOf(u8, painted, "useryy").?;
    const reply = std.mem.indexOf(u8, painted, "replyzz").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    // Screen order top → bottom: intro, user box, model reply, then the footer.
    try std.testing.expect(intro < user);
    try std.testing.expect(user < reply);
    try std.testing.expect(reply < footer);
    // A small model in a tall window clips nothing, so the frame fits one page.
    try std.testing.expect(ui.block.paintedRows(painted) < 24);
}

// A streaming turn stacks its tool boxes above the active editor and then the
// status line. Several tool boxes show at once, not just one.
test "a turn tail stacks tool boxes above the active editor" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    const tools = [_]ui.paint.Box{
        .{ .text = "readbox" },
        .{ .text = "grepbox", .fit = .head },
    };
    const scene: Scene = .{ .conversation = .{
        .transcript = &[_]ui.block.Entry{},
        .tail = .{ .turn = .{
            .tools = &tools,
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .steering = &.{},
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    const painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const first = std.mem.indexOf(u8, painted, "readbox").?;
    const second = std.mem.indexOf(u8, painted, "grepbox").?;
    const activity = std.mem.indexOf(u8, painted, "━").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(first < second);
    try std.testing.expect(second < activity);
    try std.testing.expect(activity < footer);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Working…") == null);
}

test "separator activity does not change the input tail height" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    const prompt: Scene = .{ .conversation = .{
        .transcript = &.{},
        .tail = .{ .prompt = .{ .hint = null, .editor = &editor } },
        .status = &test_status,
    } };
    const turn: Scene = .{ .conversation = .{
        .transcript = &.{},
        .tail = .{ .turn = .{
            .tools = &.{},
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .steering = &.{},
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    const prompt_painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &prompt);
    defer gpa.free(prompt_painted);
    const turn_painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &turn);
    defer gpa.free(turn_painted);

    try std.testing.expectEqual(
        ui.block.paintedRows(prompt_painted),
        ui.block.paintedRows(turn_painted),
    );
}

// Regression: 253 concurrent tool boxes used to wrap the anchor-id arithmetic
// past maxInt(usize). The ids must stay unique and in range.
test "a turn with 253 tool boxes keeps its anchor ids from wrapping" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    const tools = [_]ui.paint.Box{.{ .text = "toolbox" }} ** 253;
    const scene: Scene = .{ .conversation = .{
        .transcript = &[_]ui.block.Entry{},
        .tail = .{ .turn = .{
            .tools = &tools,
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .steering = &.{},
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    gpa.free(try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene));

    try std.testing.expect(idTool(252) < id_reserved);
}

// A turn tail with queued steering shows each "Queued message:" row and the
// recall hint above the editor. A multi-line message shows only its first line.
test "a turn tail shows the steering queue above the editor" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    const queue = [_][]const u8{ "fix the bug", "then add a test\nnot this row" };
    const scene: Scene = .{ .conversation = .{
        .transcript = &[_]ui.block.Entry{},
        .tail = .{ .turn = .{
            .tools = &.{},
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .steering = &queue,
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    const painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const first = std.mem.indexOf(u8, painted, "fix the bug").?;
    const second = std.mem.indexOf(u8, painted, "then add a test").?;
    const hint = std.mem.indexOf(u8, painted, "Ctrl+P").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(std.mem.indexOf(u8, painted, "not this row") == null);
    try std.testing.expect(first < second);
    try std.testing.expect(second < hint);
    try std.testing.expect(hint < footer);
}

// A prompt tail with a hint shows that one row above the editor frame and keeps
// the transcript above it. A prompt without a hint contributes the editor alone.
test "a prompt tail shows its hint row above the editor" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("draft text");

    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.append(gpa, try ui.block.Entry.init(gpa, .event, true, "the turn failed"));

    const scene: Scene = .{ .conversation = .{
        .transcript = entries.items,
        .tail = .{ .prompt = .{
            .hint = "Ctrl+N: Try again · Esc: Dismiss",
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    const painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const failure = std.mem.indexOf(u8, painted, "the turn failed").?;
    const hint = std.mem.indexOf(u8, painted, "Ctrl+N: Try again").?;
    const draft = std.mem.indexOf(u8, painted, "draft text").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(failure < hint);
    try std.testing.expect(hint < draft);
    try std.testing.expect(draft < footer);

    const bare: Scene = .{ .conversation = .{
        .transcript = entries.items,
        .tail = .{ .prompt = .{ .hint = null, .editor = &editor } },
        .status = &test_status,
    } };
    const without = try projected(gpa, .{ .columns = 40, .rows = 24 }, &bare);
    defer gpa.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "Ctrl+N") == null);
    // The hint costs its own row and the blank that separates it.
    try std.testing.expectEqual(
        ui.block.paintedRows(painted),
        ui.block.paintedRows(without) + 2,
    );
}

// Regression: a window narrower than the "Queued message: " label must not emit
// a row wider than the width. The sink asserts every row fits.
test "a narrow window clips the steering rows to width" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    const queue = [_][]const u8{"a steering message wider than the window"};
    const scene: Scene = .{ .conversation = .{
        .transcript = &[_]ui.block.Entry{},
        .tail = .{ .turn = .{
            .tools = &.{},
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .steering = &queue,
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    gpa.free(try projected(gpa, .{ .columns = 8, .rows = 24 }, &scene));
}

// When the transcript overflows the window, the projection clips the oldest
// visible block to fill it exactly. The frame is `rows * window_pages` rows.
// The clip drops that block's top rows while its newest content and the tail
// below still show.
test "projection clips the oldest block to fill the window exactly" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    var text = try ui.block.numberedLines(gpa, 60);
    defer text.deinit(gpa);
    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, false, text.items));

    const scene: Scene = .{ .conversation = .{
        .transcript = entries.items,
        .tail = .{ .prompt = .{ .hint = null, .editor = &editor } },
        .status = &test_status,
    } };
    const rows: usize = 4;
    const painted = try projected(gpa, .{ .columns = 40, .rows = rows }, &scene);
    defer gpa.free(painted);

    try std.testing.expectEqual(rows * window_pages, ui.block.paintedRows(painted));
    // The clip drops its top rows: its last line shows, its first does not, and
    // the tail still sits at the bottom.
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "footerqq") != null);
}
