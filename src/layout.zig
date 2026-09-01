//! Projection of either the conversation interface or a temporary full-window
//! page onto the bounded terminal `View`. Conversation components stack in
//! screen order: transcript blocks oldest first, then the live tail and status.
//! A page is exclusive and emits only its fixed header and visible body window.
//!
//! Conversation layout uses two passes: measure newest → oldest to find the
//! bounded clip, then compose clip → newest. The layout holds nothing between
//! frames and projects the scene again at each size. Each transcript block
//! retains the rows of its own last paint, so a frame runs the markdown of the
//! blocks that changed alone and replays every other block. A single blank line
//! separates adjacent conversation components. Boxes carry their own colored
//! padding.

const std = @import("std");

const terminal = @import("terminal");

const ui = @import("ui/root.zig");

/// The pages (terminal heights) of the newest content that a frame retains when
/// the configuration names no count. A page more keeps more of the conversation
/// on the screen, and each frame emits every retained row again.
pub const window_pages_default: usize = 8;

/// The window that a configured page count falls in. One page retains the newest
/// content alone. The upper bound keeps the work of one frame inside the frame
/// interval, because the projection repeats that work at every frame.
pub const window_pages_min: usize = 1;
pub const window_pages_max: usize = 64;

/// Anchor ids for the tail rows. They come from a reserved high range a growing
/// transcript index (a block's id) can never reach, so anchors never alias as
/// the model grows. A block takes its index in the projection, and a projection
/// that hides a block moves every index behind it. Such a change repaints the
/// whole window, so no stale anchor survives it. The editor and picker share
/// `id_input`: they occupy the same region, so the diff repaints it in place
/// when one replaces the other.
const id_reserved = std.math.maxInt(usize) - 255;
const id_status = id_reserved;
const id_input = id_reserved + 1;
const id_page = id_reserved + 2;

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
        /// The pages of the newest content this frame retains. The driver passes
        /// the configured count, which `Config` resolves into the window above.
        window_pages: usize = window_pages_default,
        /// The transcript blocks the active account shows, oldest first. A
        /// projection hides the blocks of another account, so the scene borrows
        /// one pointer per shown block instead of a contiguous slice. A block
        /// retains the rows of its paint, so the pointer reaches the block.
        transcript: []const *ui.block.Entry,
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
    picking: Picking,

    /// An idle prompt: one editor with an optional semantic caption.
    pub const Prompt = struct {
        caption: ?ui.Caption,
        editor: *const ui.Editor,
    };

    /// A picker that owns the region. A list that waits for a fetch moves its
    /// separators as a turn does, so the wait reads as work in progress.
    pub const Picking = struct {
        picker: *const ui.Picker,
        activity: ?ui.paint.Activity,
    };

    /// A streaming turn: the running tool calls, then one editor with its
    /// optional caption and activity. No line of a tool box wraps, so a box
    /// takes one row per line it holds. A committed call names what it acts on.
    /// A streamed call counts its argument bytes. A timed call adds its time.
    pub const Turn = struct {
        tools: []const ui.paint.Box,
        activity: ui.paint.Activity,
        caption: ?ui.Caption,
        editor: *const ui.Editor,
    };
};

const EditorPresentation = struct {
    editor: *const ui.Editor,
    activity: ?ui.paint.Activity,
    caption: ?ui.Caption,

    fn rows(self: *const EditorPresentation, size: terminal.View.Size) usize {
        const caption_rows = if (self.caption) |caption| caption.rows(size.columns) else 0;
        return caption_rows + self.editor.rows(size);
    }

    fn render(
        self: *const EditorPresentation,
        placement: *const ui.paint.Placement,
        viewport_rows: usize,
    ) !void {
        const caption_rows = if (self.caption) |*caption|
            try caption.render(placement)
        else
            0;
        var editor_placement = placement.*;
        editor_placement.base = placement.base + caption_rows;
        try self.editor.render(&editor_placement, &.{
            .viewport_rows = viewport_rows,
            .activity = self.activity,
        });
    }
};

/// One screen component: a transcript block or a piece of the tail. Each variant
/// carries what `measure` and `render` need.
const Component = union(enum) {
    entry: *ui.block.Entry,
    tool_box: ui.paint.Box,
    editor: EditorPresentation,
    picker: Tail.Picking,
    status: *const ui.status.Info,

    /// The physical rows this component occupies, its leading separator excluded.
    /// Must equal exactly what `render` emits. The diff and window math rely on
    /// this parity.
    fn measure(self: *const Component, size: terminal.View.Size) usize {
        return switch (self.*) {
            .entry => |entry| entry.rows(size.columns),
            .tool_box => |box| ui.paint.boxRows(&box, size.columns),
            .editor => |presentation| presentation.rows(size),
            .status => 1,
            .picker => |picking| picking.picker.rows(size),
        };
    }

    /// Compose this component's rows through `placement` and drop its top `skip`
    /// rows (nonzero only for the clip). A block retains the rows of this paint,
    /// so `gpa` holds them.
    fn render(
        self: *const Component,
        gpa: std.mem.Allocator,
        placement: *const ui.paint.Placement,
        viewport_rows: usize,
    ) !void {
        switch (self.*) {
            .entry => |entry| try entry.render(gpa, placement),
            .tool_box => |box| try ui.paint.box(placement, .tool_pending, &box),
            .status => |info| try ui.status.render(placement, info),
            .editor => |presentation| try presentation.render(placement, viewport_rows),
            .picker => |picking| try picking.picker.render(placement, &.{
                .viewport_rows = viewport_rows,
                .activity = picking.activity,
            }),
        }
    }
};

/// A component in screen order: its content, the stable anchor `id` its rows
/// carry, and whether a blank separator row precedes it as its line 0.
const Slot = struct { component: Component, id: usize, leading_blank: bool };

/// Project `scene` onto the window at `size` and hand it to `view`. A shown
/// block retains the rows of its paint in `gpa`, and a block that the window
/// drops releases them again.
pub fn project(
    gpa: std.mem.Allocator,
    view: *terminal.View,
    size: terminal.View.Size,
    scene: *const Scene,
) !void {
    switch (scene.*) {
        .conversation => try projectConversation(gpa, view, size, &scene.conversation),
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
    gpa: std.mem.Allocator,
    view: *terminal.View,
    size: terminal.View.Size,
    scene: *const Scene.Conversation,
) !void {
    // `Config` reports and drops a count outside the window, so every caller
    // states a legal one. A count of zero would retain nothing, and a huge count
    // would overflow the capacity below.
    std.debug.assert(scene.window_pages >= window_pages_min);
    std.debug.assert(scene.window_pages <= window_pages_max);
    const total = scene.transcript.len + tailCount(&scene.tail) + 1;
    const capacity = @max(size.rows, 1) * scene.window_pages;

    var rows: usize = 0;
    var shown: usize = 0;
    while (shown < total and rows < capacity) : (shown += 1) {
        const slot = slotAt(scene, total - 1 - shown);
        rows += @intFromBool(slot.leading_blank) + slot.component.measure(size);
    }
    const skip = if (rows > capacity) rows - capacity else 0;
    const start = total - shown;
    // A block above the window paints nothing, so it retains no rows either.
    // The rows that every block retains then stay inside the window.
    for (scene.transcript[0..@min(start, scene.transcript.len)]) |entry| entry.release(gpa);

    const sink = try view.beginFrame(
        .{ .columns = size.columns, .rows = size.rows },
        scene.window_pages,
    );
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
        try slot.component.render(gpa, &placement, size.rows);
    }
    try view.render();
}

/// How many components the tail contributes.
fn tailCount(tail: *const Tail) usize {
    return switch (tail.*) {
        .prompt, .picking => 1,
        .turn => |turn| turn.tools.len + 1,
    };
}

/// The component at screen index `index`: the transcript oldest first, then the
/// tail, then the status line.
fn slotAt(scene: *const Scene.Conversation, index: usize) Slot {
    if (index < scene.transcript.len) return .{
        .component = .{ .entry = scene.transcript[index] },
        .id = index,
        .leading_blank = index > 0,
    };
    const offset = index - scene.transcript.len;
    if (offset < tailCount(&scene.tail)) return tailSlot(&scene.tail, offset);
    return .{ .component = .{ .status = scene.status }, .id = id_status, .leading_blank = false };
}

/// The tail component at `offset`, in screen order. A turn puts its tool boxes
/// before the captioned editor. A prompt and a picker each hold one input.
fn tailSlot(tail: *const Tail, offset: usize) Slot {
    switch (tail.*) {
        .prompt => |prompt| return editorSlot(&.{
            .editor = prompt.editor,
            .activity = null,
            .caption = prompt.caption,
        }),
        .picking => |picking| return .{
            .component = .{ .picker = picking },
            .id = id_input,
            .leading_blank = true,
        },
        .turn => |turn| {
            if (offset < turn.tools.len) return .{
                .component = .{ .tool_box = turn.tools[offset] },
                .id = idTool(offset),
                .leading_blank = true,
            };
            return editorSlot(&.{
                .editor = turn.editor,
                .activity = turn.activity,
                .caption = turn.caption,
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
    .context_tokens = 0,
    .cache_usage = .{},
    .cost = 0,
    .context_window = 1000,
    .model = "footerqq",
    .effort = "high",
    .account = .anthropic_subscription,
    .quota = null,
    .quota_age_ms = 0,
    .turn_active = false,
};

// The projection of `entries`: one borrowed pointer per shown block, as the
// session hands the layout its projected transcript. Caller-owned.
fn shownEntries(
    gpa: std.mem.Allocator,
    entries: []ui.block.Entry,
) !std.ArrayList(*ui.block.Entry) {
    var shown: std.ArrayList(*ui.block.Entry) = .empty;
    errdefer shown.deinit(gpa);
    for (entries) |*entry| try shown.append(gpa, entry);
    return shown;
}

// Projects `scene` into a fresh view at `size` and returns the frame's bytes,
// caller-owned.
fn projected(gpa: std.mem.Allocator, size: terminal.View.Size, scene: *const Scene) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    try project(gpa, &view, size, scene);
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
    try entries.append(gpa, try ui.block.Entry.init(gpa, .intro, .{}, "introxx"));
    try entries.append(gpa, try ui.block.Entry.init(gpa, .user, .{}, "useryy"));
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, .{}, "replyzz"));

    var shown = try shownEntries(gpa, entries.items);
    defer shown.deinit(gpa);

    const scene: Scene = .{ .conversation = .{
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
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
        .transcript = &.{},
        .tail = .{ .turn = .{
            .tools = &tools,
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .caption = null,
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
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    const turn: Scene = .{ .conversation = .{
        .transcript = &.{},
        .tail = .{ .turn = .{
            .tools = &.{},
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .caption = null,
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
        .transcript = &.{},
        .tail = .{ .turn = .{
            .tools = &tools,
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .caption = null,
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    gpa.free(try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene));

    try std.testing.expect(idTool(252) < id_reserved);
}

// A turn tail keeps the steering count and recall control in one caption that
// touches the editor frame. It shows no queued message content.
test "a turn tail shows its steering caption above the editor" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    const scene: Scene = .{ .conversation = .{
        .transcript = &.{},
        .tail = .{ .turn = .{
            .tools = &.{},
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .caption = .{
                .title = "Queued messages: 2",
                .controls = "Ctrl+P: Edit all",
            },
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    const painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const title = std.mem.indexOf(u8, painted, "Queued messages: 2").?;
    const control = std.mem.indexOf(u8, painted, "Ctrl+P: Edit all").?;
    const frame = std.mem.indexOf(u8, painted, "─").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(title < control);
    try std.testing.expect(control < frame);
    try std.testing.expect(frame < footer);
    try std.testing.expect(std.mem.indexOf(u8, painted, "fix the bug") == null);
}

// A prompt tail keeps a retry caption inside the editor component. A prompt
// without a caption contributes the editor alone.
test "a prompt tail shows its retry caption above the editor" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("draft text");

    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.append(
        gpa,
        try ui.block.Entry.init(gpa, .event, .{ .is_error = true }, "the turn failed"),
    );

    var shown = try shownEntries(gpa, entries.items);
    defer shown.deinit(gpa);

    const scene: Scene = .{ .conversation = .{
        .transcript = shown.items,
        .tail = .{ .prompt = .{
            .caption = .{
                .title = "Failed turn",
                .controls = "Ctrl+N: Try again · Esc: Dismiss",
            },
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    const painted = try projected(gpa, .{ .columns = 80, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const failure = std.mem.indexOf(u8, painted, "the turn failed").?;
    const title = std.mem.indexOf(u8, painted, "Failed turn").?;
    const control = std.mem.indexOf(u8, painted, "Ctrl+N: Try again").?;
    const draft = std.mem.indexOf(u8, painted, "draft text").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(failure < title);
    try std.testing.expect(title < control);
    try std.testing.expect(control < draft);
    try std.testing.expect(draft < footer);

    const bare: Scene = .{ .conversation = .{
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    const without = try projected(gpa, .{ .columns = 80, .rows = 24 }, &bare);
    defer gpa.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "Ctrl+N") == null);
    // The caption costs one row. It adds no blank before the editor frame.
    try std.testing.expectEqual(
        ui.block.paintedRows(painted),
        ui.block.paintedRows(without) + 1,
    );
}

// A narrow caption and its editor remain one bounded component. Every row fits
// the window after the title and an overwide control cut.
test "a narrow editor caption keeps every row inside the window" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    const scene: Scene = .{ .conversation = .{
        .transcript = &.{},
        .tail = .{ .turn = .{
            .tools = &.{},
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .caption = .{
                .title = "Queued messages: 1",
                .controls = "Ctrl+P: Edit all",
            },
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    const painted = try projected(gpa, .{ .columns = 8, .rows = 24 }, &scene);
    defer gpa.free(painted);
    const plain = try terminal.View.plainText(gpa, painted);
    defer gpa.free(plain);
    var lines = std.mem.splitSequence(u8, plain, "\r\n");
    while (lines.next()) |row| {
        const line = std.mem.trimEnd(u8, row, "\r");
        try std.testing.expect(terminal.width.ofText(line) <= 8);
    }
    try std.testing.expect(std.mem.indexOf(u8, plain, ui.paint.ellipsis) != null);
}

// When the transcript overflows the window, the projection clips the oldest
// visible block to fill it exactly. The frame is `rows * window_pages` rows.
// The clip drops that block's top rows while its newest content and the tail
// below still show.
//
// A scene that names no count retains the compiled pages.
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
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, .{}, text.items));

    var shown = try shownEntries(gpa, entries.items);
    defer shown.deinit(gpa);

    const scene: Scene = .{ .conversation = .{
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    const rows: usize = 4;
    const painted = try projected(gpa, .{ .columns = 40, .rows = rows }, &scene);
    defer gpa.free(painted);

    try std.testing.expectEqual(rows * window_pages_default, ui.block.paintedRows(painted));
    // The clip drops its top rows: its last line shows, its first does not, and
    // the tail still sits at the bottom.
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "footerqq") != null);
}

// Every shown block retains the rows of its paint, and a repeat of one scene
// replays them. The replayed rows must equal the composed ones, so the view
// finds no change and reprints nothing.
test "a repeated projection composes the rows of the first one" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.append(gpa, try ui.block.Entry.init(gpa, .user, .{}, "useryy"));
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, .{}, "## replyzz\n\nsome text"));

    var shown = try shownEntries(gpa, entries.items);
    defer shown.deinit(gpa);

    const scene: Scene = .{ .conversation = .{
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const size: terminal.View.Size = .{ .columns = 40, .rows = 24 };

    try project(gpa, &view, size, &scene);
    const composed = out.written().len;
    for (entries.items) |*entry| {
        try std.testing.expectEqual(size.columns, entry.cache.columns);
        try std.testing.expect(entry.cache.lines.count() > 0);
    }

    try project(gpa, &view, size, &scene);
    const replayed = out.written()[composed..];
    try std.testing.expect(std.mem.indexOf(u8, replayed, "useryy") == null);
    try std.testing.expect(std.mem.indexOf(u8, replayed, "replyzz") == null);

    // A streamed delta paints the block that grew, and no block above it.
    const streamed = out.written().len;
    try entries.items[1].appendText(gpa, "\n\ngrownxx");
    try project(gpa, &view, size, &scene);
    const grown = out.written()[streamed..];
    try std.testing.expect(std.mem.indexOf(u8, grown, "grownxx") != null);
    try std.testing.expect(std.mem.indexOf(u8, grown, "useryy") == null);
}

// The rows that every block retains stay inside the window that a frame paints.
// A block that the window leaves behind releases them, so a long conversation
// holds no rows that no frame shows.
test "a block outside the window releases the rows it retained" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    for (0..6) |index| {
        var buffer: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "block{d}", .{index}) catch unreachable;
        try entries.append(gpa, try ui.block.Entry.init(gpa, .model, .{}, text));
    }

    var shown = try shownEntries(gpa, entries.items);
    defer shown.deinit(gpa);

    const tall: Scene = .{ .conversation = .{
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    gpa.free(try projected(gpa, .{ .columns = 40, .rows = 24 }, &tall));
    for (entries.items) |*entry| try std.testing.expect(entry.cache.lines.count() > 0);

    // One page of eight rows holds the newest blocks alone.
    const short: Scene = .{ .conversation = .{
        .window_pages = window_pages_min,
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    const painted = try projected(gpa, .{ .columns = 40, .rows = 8 }, &short);
    defer gpa.free(painted);

    try std.testing.expect(std.mem.indexOf(u8, painted, "block0") == null);
    try std.testing.expectEqual(@as(usize, 0), entries.items[0].cache.lines.count());
    try std.testing.expect(entries.items[entries.items.len - 1].cache.lines.count() > 0);
    for (entries.items, 0..) |*entry, index| {
        var buffer: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "block{d}", .{index}) catch unreachable;
        if (std.mem.indexOf(u8, painted, text) != null) continue;
        try std.testing.expectEqual(@as(usize, 0), entry.cache.lines.count());
    }
}

// The configured count sets how much of the newest content one frame retains.
// A frame of more pages keeps more of the conversation on the screen, and it
// paints every one of those rows again.
test "the retained window follows the configured page count" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    var text = try ui.block.numberedLines(gpa, 200);
    defer text.deinit(gpa);
    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, .{}, text.items));

    var shown = try shownEntries(gpa, entries.items);
    defer shown.deinit(gpa);

    const rows: usize = 4;
    for ([_]usize{ window_pages_min, 3, 12 }) |pages| {
        const scene: Scene = .{ .conversation = .{
            .window_pages = pages,
            .transcript = shown.items,
            .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
            .status = &test_status,
        } };
        const painted = try projected(gpa, .{ .columns = 40, .rows = rows }, &scene);
        defer gpa.free(painted);
        try std.testing.expectEqual(rows * pages, ui.block.paintedRows(painted));
    }
}
