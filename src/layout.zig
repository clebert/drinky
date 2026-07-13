//! Projection: fold the transcript and chrome of one `Scene` onto the bounded
//! window and hand it to the `terminal.View`. Components stack in screen order —
//! the transcript blocks oldest first, then the chrome (a running tool's box and
//! the spinner during a turn, or a picker, then the editor and the status line).
//!
//! Two passes: pass one measures newest → oldest until the window is full,
//! finding the topmost visible component (the clip) and how many of its rows fall
//! above the window; pass two composes clip → newest into the view's sink, the
//! clip alone dropping those top rows. Nothing is cached between frames: layout
//! is recomputed from the scene each time, bounded to the window. A single blank
//! line separates adjacent components; boxes carry their own colored padding.

const std = @import("std");

const terminal = @import("terminal");

const ui = @import("ui/root.zig");

/// The view retains this many pages (terminal heights) of the newest content.
const window_pages = 8;

/// Ids for the chrome rows, from a reserved high range a growing transcript index
/// (a block's id) can never reach, so anchors never alias as the model grows.
const tool_box_id = std.math.maxInt(usize) - 4;
const spinner_id = std.math.maxInt(usize) - 3;
const picker_id = std.math.maxInt(usize) - 2;
const editor_id = std.math.maxInt(usize) - 1;
const status_id = std.math.maxInt(usize);

const tool_box_style: ui.paint.BoxStyle = .{
    .background = ui.color.tool_pending_bg,
    .foreground = ui.color.tool_fg,
};

/// Everything one frame draws: the transcript blocks and the chrome around the
/// input area. `picker` replaces the editor while a picker is open; `spinner` and
/// `tool_box` show only during a turn.
pub const Scene = struct {
    transcript: []const ui.block.Entry,
    status: *const ui.status.Info,
    picker: ?*const ui.Picker = null,
    editor: ?*const ui.Editor = null,
    focused: bool = false,
    tool_box: ?[]const u8 = null,
    spinner: ?usize = null,
};

/// One screen component: a transcript block or a piece of chrome. Each variant
/// carries what `measure` and `renderSlot` need.
const Component = union(enum) {
    entry: *const ui.block.Entry,
    tool_box: []const u8,
    spinner: usize,
    editor: Prompt,
    picker: *const ui.Picker,
    status: *const ui.status.Info,

    const Prompt = struct { editor: *const ui.Editor, focused: bool };
};

/// A component in screen order: its content, the stable anchor `id` its rows
/// carry, and whether a blank separator row precedes it as its line 0.
const Slot = struct { component: Component, id: usize, leading_blank: bool };

/// Project `scene` onto the window at `size` and hand it to `view`. See the file
/// comment for the two-pass measure/clip/compose.
pub fn project(view: *terminal.View, size: terminal.View.Size, scene: *const Scene) !void {
    var chrome: [4]Slot = undefined;
    const chrome_count = chromeSlots(scene, &chrome);
    const slots = chrome[0..chrome_count];
    const total_slots = scene.transcript.len + chrome_count;
    const capacity = @max(size.rows, 1) * window_pages;

    var total: usize = 0;
    var shown: usize = 0;
    while (shown < total_slots) {
        const slot = slotAt(slots, scene.transcript, shown);
        total += measure(&slot, size.columns, size.rows);
        shown += 1;
        if (total >= capacity) break;
    }
    const skip = if (total > capacity) total - capacity else 0;

    const sink = try view.beginFrame(.{ .columns = size.columns, .rows = size.rows }, window_pages);
    var reverse = shown;
    while (reverse > 0) {
        reverse -= 1;
        const slot = slotAt(slots, scene.transcript, reverse);
        const placement: ui.paint.Placement = .{
            .sink = sink,
            .id = slot.id,
            .columns = size.columns,
            .base = if (slot.leading_blank) 1 else 0,
            .skip = if (reverse == shown - 1) skip else 0,
        };
        try renderSlot(&slot, &placement, size.rows);
    }
    try view.render();
}

/// Build the chrome components (bounded) into `out` in screen order and return
/// how many.
fn chromeSlots(scene: *const Scene, out: *[4]Slot) usize {
    var count: usize = 0;
    if (scene.picker) |picker| {
        out[count] = .{ .component = .{ .picker = picker }, .id = picker_id, .leading_blank = true };
        count += 1;
    } else {
        if (scene.tool_box) |text| {
            out[count] = .{ .component = .{ .tool_box = text }, .id = tool_box_id, .leading_blank = true };
            count += 1;
        }
        if (scene.spinner) |frame| {
            out[count] = .{ .component = .{ .spinner = frame }, .id = spinner_id, .leading_blank = true };
            count += 1;
        }
        if (scene.editor) |editor| {
            out[count] = .{
                .component = .{ .editor = .{ .editor = editor, .focused = scene.focused } },
                .id = editor_id,
                .leading_blank = true,
            };
            count += 1;
        }
    }
    out[count] = .{ .component = .{ .status = scene.status }, .id = status_id, .leading_blank = false };
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
fn measure(slot: *const Slot, columns: usize, viewport_rows: usize) usize {
    const lead: usize = if (slot.leading_blank) 1 else 0;
    return lead + switch (slot.component) {
        .entry => |entry| entry.rows(columns),
        .tool_box => |text| ui.paint.boxRows(text, columns),
        .spinner, .status => 1,
        .editor => |prompt| prompt.editor.rows(columns, viewport_rows),
        .picker => |picker| picker.rows(columns),
    };
}

/// Compose `slot`'s rows through `placement`, dropping its top `skip` rows
/// (nonzero only for the clip). Its leading separator, when present, is line 0.
fn renderSlot(slot: *const Slot, placement: *const ui.paint.Placement, viewport_rows: usize) !void {
    if (slot.leading_blank and placement.skip == 0) {
        _ = placement.sink.begin();
        placement.sink.end(.{ .id = placement.id, .line = 0 });
    }
    switch (slot.component) {
        .entry => |entry| try entry.render(placement),
        .tool_box => |text| try ui.paint.box(placement, &tool_box_style, text),
        .spinner => |frame| try ui.paint.spinner(placement, frame),
        .status => |info| try ui.status.render(placement, info),
        .editor => |prompt| try prompt.editor.render(placement, viewport_rows, prompt.focused),
        .picker => |picker| try picker.render(placement),
    }
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
};

// The whole projection end to end: a transcript plus chrome (the editor and the
// status line) composed through a real view. Exercises the backward measure walk
// and the two-pass compose across transcript and chrome together, screen order
// newest at the bottom.
test "projection stacks the transcript above the chrome, newest at the bottom" {
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
        .status = &test_status,
        .editor = &editor,
        .focused = true,
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

// When the transcript overflows the window, the oldest visible block is clipped
// to fill it exactly: the frame is `rows * window_pages` rows, that block's top
// rows dropped while its newest content and the chrome below still show.
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
        .status = &test_status,
        .editor = &editor,
        .focused = true,
    };
    const rows: usize = 4;
    try project(&view, .{ .columns = 40, .rows = rows }, &scene);

    const painted = out.written();
    try std.testing.expectEqual(rows * window_pages, paintedRows(painted));
    // The clip drops its top rows: its last line shows, its first does not, and
    // the chrome still sits at the bottom.
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "footerqq") != null);
}
