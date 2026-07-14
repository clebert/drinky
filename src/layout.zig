//! Projection: fold the transcript and the live tail of one `Scene` onto the
//! bounded window and hand it to the `terminal.View`. Components stack in screen
//! order — the transcript blocks oldest first, then the tail (a running turn's
//! tool boxes and spinner, or a picker, then the input area and the status line).
//!
//! The tail is a tagged union, so exactly one input is ever live: the editor
//! while waiting or streaming, or a picker. Two passes: pass one measures newest
//! → oldest until the window is full, finding the topmost visible component (the
//! clip) and how many of its rows fall above the window; pass two composes clip →
//! newest into the view's sink, the clip alone dropping those top rows. Nothing
//! is cached between frames: layout is recomputed from the scene each time,
//! bounded to the window. A single blank line separates adjacent components;
//! boxes carry their own colored padding.

const std = @import("std");

const terminal = @import("terminal");

const ui = @import("ui/root.zig");

/// The view retains this many pages (terminal heights) of the newest content.
const window_pages = 8;

/// Anchor ids for the tail rows, from a reserved high range a growing transcript
/// index (a block's id) can never reach, so anchors never alias as the model
/// grows. The editor and picker share `id_input`: they occupy the same region,
/// so the diff repaints it in place when one replaces the other.
const id_reserved = std.math.maxInt(usize) - 255;
const id_status = id_reserved;
const id_input = id_reserved + 1;
const id_spinner = id_reserved + 2;

/// The anchor id of the tool box at `index` in the running turn.
fn idTool(index: usize) usize {
    return id_reserved + 3 + index;
}

const tool_box_style: ui.paint.BoxStyle = .{
    .background = ui.color.tool_pending_bg,
    .foreground = ui.color.tool_fg,
};

/// Everything one frame draws: the transcript blocks and the live tail below them.
pub const Scene = struct {
    transcript: []const ui.block.Entry,
    tail: Tail,
    status: *const ui.status.Info,
};

/// The live region below the transcript. A tagged union so exactly one input is
/// ever present and focused: the editor while `prompt`ing, the inert editor under
/// a streaming `turn`'s chrome, or a `picker` that owns the region.
pub const Tail = union(enum) {
    prompt: *const ui.Editor,
    turn: Turn,
    picking: *const ui.Picker,

    /// A streaming turn: the running tool calls, each shown as its own box, the
    /// spinner, then the editor kept visible but inert.
    pub const Turn = struct {
        tools: []const []const u8,
        spinner: usize,
        editor: *const ui.Editor,
    };
};

/// One screen component: a transcript block or a piece of the tail. Each variant
/// carries what `measure` and `render` need.
const Component = union(enum) {
    entry: *const ui.block.Entry,
    tool_box: []const u8,
    spinner: usize,
    editor: Prompt,
    picker: *const ui.Picker,
    status: *const ui.status.Info,

    const Prompt = struct { editor: *const ui.Editor, focused: bool };

    /// The physical rows this component occupies, its leading separator excluded.
    /// Must equal exactly what `render` emits — the parity the diff and window
    /// math rely on.
    fn measure(self: Component, columns: usize, viewport_rows: usize) usize {
        return switch (self) {
            .entry => |entry| entry.rows(columns),
            .tool_box => |text| ui.paint.boxRows(text, columns),
            .spinner, .status => 1,
            .editor => |prompt| prompt.editor.rows(columns, viewport_rows),
            .picker => |picker| picker.rows(columns, viewport_rows),
        };
    }

    /// Compose this component's rows through `placement`, dropping its top `skip`
    /// rows (nonzero only for the clip).
    fn render(self: Component, placement: *const ui.paint.Placement, viewport_rows: usize) !void {
        switch (self) {
            .entry => |entry| try entry.render(placement),
            .tool_box => |text| try ui.paint.box(placement, &tool_box_style, text),
            .spinner => |frame| try ui.paint.spinner(placement, frame),
            .status => |info| try ui.status.render(placement, info),
            .editor => |prompt| try prompt.editor.render(placement, viewport_rows, prompt.focused),
            .picker => |picker| try picker.render(placement, viewport_rows),
        }
    }
};

/// A component in screen order: its content, the stable anchor `id` its rows
/// carry, and whether a blank separator row precedes it as its line 0.
const Slot = struct { component: Component, id: usize, leading_blank: bool };

/// Project `scene` onto the window at `size` and hand it to `view`. See the file
/// comment for the two-pass measure/clip/compose.
pub fn project(view: *terminal.View, size: terminal.View.Size, scene: *const Scene) !void {
    const total = scene.transcript.len + tailCount(&scene.tail) + 1;
    const capacity = @max(size.rows, 1) * window_pages;

    var rows: usize = 0;
    var shown: usize = 0;
    while (shown < total) {
        const slot = slotAt(scene, total - 1 - shown);
        rows += slotRows(&slot, size.columns, size.rows);
        shown += 1;
        if (rows >= capacity) break;
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
            .base = if (slot.leading_blank) 1 else 0,
            .skip = if (index == start) skip else 0,
        };
        try paintSlot(&slot, &placement, size.rows);
    }
    try view.render();
}

/// How many components the tail contributes.
fn tailCount(tail: *const Tail) usize {
    return switch (tail.*) {
        .prompt, .picking => 1,
        .turn => |turn| turn.tools.len + 2,
    };
}

/// The component at screen index `index`: the transcript oldest first, then the
/// tail, then the status line.
fn slotAt(scene: *const Scene, index: usize) Slot {
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
/// then the spinner, then the inert editor; otherwise the sole input.
fn tailSlot(tail: *const Tail, offset: usize) Slot {
    switch (tail.*) {
        .prompt => |editor| return editorSlot(editor, true),
        .picking => |picker| return .{ .component = .{ .picker = picker }, .id = id_input, .leading_blank = true },
        .turn => |turn| {
            if (offset < turn.tools.len) return .{
                .component = .{ .tool_box = turn.tools[offset] },
                .id = idTool(offset),
                .leading_blank = true,
            };
            if (offset == turn.tools.len) return .{
                .component = .{ .spinner = turn.spinner },
                .id = id_spinner,
                .leading_blank = true,
            };
            return editorSlot(turn.editor, false);
        },
    }
}

fn editorSlot(editor: *const ui.Editor, focused: bool) Slot {
    return .{
        .component = .{ .editor = .{ .editor = editor, .focused = focused } },
        .id = id_input,
        .leading_blank = true,
    };
}

/// The physical rows `slot` occupies, its leading separator included.
fn slotRows(slot: *const Slot, columns: usize, viewport_rows: usize) usize {
    const lead: usize = if (slot.leading_blank) 1 else 0;
    return lead + slot.component.measure(columns, viewport_rows);
}

/// Compose `slot`'s rows through `placement`, its leading separator (when present
/// and not clipped) as line 0.
fn paintSlot(slot: *const Slot, placement: *const ui.paint.Placement, viewport_rows: usize) !void {
    if (slot.leading_blank and placement.skip == 0) {
        _ = placement.sink.begin();
        placement.sink.end(.{ .id = placement.id, .line = 0 });
    }
    try slot.component.render(placement, viewport_rows);
}

// Physical rows in a fresh paint: rows are joined by `\r\n` and a row never
// contains one (`Sink.end` rejects both bytes), so the separators count them.
fn paintedRows(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\r\n") + 1;
}

const test_status: ui.status.Info = .{
    .last = .{},
    .cost = 0,
    .saved = 0,
    .context_window = 1000,
    .model = "footerqq",
    .effort = "high",
};

// The whole projection end to end: a transcript plus the tail (the prompt editor
// and the status line) composed through a real view. Exercises the backward
// measure walk and the two-pass compose across transcript and tail together,
// screen order newest at the bottom.
test "projection stacks the transcript above the tail, newest at the bottom" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
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

    const scene: Scene = .{
        .transcript = entries.items,
        .tail = .{ .prompt = &editor },
        .status = &test_status,
    };
    try project(&view, .{ .columns = 40, .rows = 24 }, &scene);

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

// A streaming turn stacks its tool boxes above the spinner and the inert editor,
// then the status line — several tool boxes at once, not just one.
test "a turn tail stacks the tool boxes, spinner, and editor" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    const tools = [_][]const u8{ "readbox", "grepbox" };
    const scene: Scene = .{
        .transcript = &[_]ui.block.Entry{},
        .tail = .{ .turn = .{ .tools = &tools, .spinner = 0, .editor = &editor } },
        .status = &test_status,
    };
    try project(&view, .{ .columns = 40, .rows = 24 }, &scene);

    const painted = out.written();
    const first = std.mem.indexOf(u8, painted, "readbox").?;
    const second = std.mem.indexOf(u8, painted, "grepbox").?;
    const spin = std.mem.indexOf(u8, painted, "Working…").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(first < second);
    try std.testing.expect(second < spin);
    try std.testing.expect(spin < footer);
}

// When the transcript overflows the window, the oldest visible block is clipped
// to fill it exactly: the frame is `rows * window_pages` rows, that block's top
// rows dropped while its newest content and the tail below still show.
test "projection clips the oldest block to fill the window exactly" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..60) |i| {
        if (i > 0) try text.append(gpa, '\n');
        var buffer: [8]u8 = undefined;
        try text.appendSlice(gpa, std.fmt.bufPrint(&buffer, "L{d}", .{i}) catch unreachable);
    }
    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, false, text.items));

    const scene: Scene = .{
        .transcript = entries.items,
        .tail = .{ .prompt = &editor },
        .status = &test_status,
    };
    const rows: usize = 4;
    try project(&view, .{ .columns = 40, .rows = rows }, &scene);

    const painted = out.written();
    try std.testing.expectEqual(rows * window_pages, paintedRows(painted));
    // The clip drops its top rows: its last line shows, its first does not, and
    // the tail still sits at the bottom.
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "footerqq") != null);
}
