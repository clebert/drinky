const std = @import("std");

const terminal = @import("terminal");

const ui = @import("ui/root.zig");

pub const window_pages_default: usize = 8;

pub const window_pages_min: usize = 1;
pub const window_pages_max: usize = 64;

const id_reserved = std.math.maxInt(usize) - 255;
const id_status = id_reserved;
const id_input = id_reserved + 1;
const id_page = id_reserved + 2;

fn idTool(index: usize) usize {
    return id_reserved - 1 - index;
}

pub const Scene = union(enum) {
    conversation: Conversation,
    page: *const ui.Page,

    pub const Conversation = struct {
        window_pages: usize = window_pages_default,
        transcript: []const *ui.block.Entry,
        tail: Tail,
        status: *const ui.status.Info,
    };
};

pub const Tail = union(enum) {
    prompt: Prompt,
    turn: Turn,
    picking: Picking,

    pub const Prompt = struct {
        caption: ?ui.Caption,
        editor: *const ui.Editor,
    };

    pub const Picking = struct {
        picker: *const ui.Picker,
        activity: ?ui.paint.Activity,
    };

    pub const Turn = struct {
        tools: []const ui.paint.Box,
        tracks: []Track = &.{},
        activity: ui.paint.Activity,
        caption: ?ui.Caption,
        editor: *const ui.Editor,
    };
};

pub const Track = struct {
    changed: bool = false,
    epoch: ?u64 = null,
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

const Component = union(enum) {
    entry: *ui.block.Entry,
    tool_box: ui.paint.Box,
    editor: EditorPresentation,
    picker: Tail.Picking,
    status: *const ui.status.Info,

    fn measure(self: *const Component, size: terminal.View.Size) usize {
        return switch (self.*) {
            .entry => |entry| entry.rows(size.columns),
            .tool_box => |box| ui.paint.boxRows(&box, size.columns),
            .editor => |presentation| presentation.rows(size),
            .status => 1,
            .picker => |picking| picking.picker.rows(size),
        };
    }

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

const Slot = struct { component: Component, id: usize, leading_blank: bool };

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

fn projectConversation(
    gpa: std.mem.Allocator,
    view: *terminal.View,
    size: terminal.View.Size,
    scene: *const Scene.Conversation,
) !void {
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
    const epoch = view.resetEpoch();
    for (0..start) |index| if (slotRewritten(scene, index, epoch)) view.resetScreen();
    if (skip > 0 and slotRewritten(scene, start, epoch)) view.resetScreen();
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
        if (slot.leading_blank and placement.skip == 0) {
            sink.begin();
            sink.end(.{ .id = slot.id, .line = 0 });
        }
        try slot.component.render(gpa, &placement, size.rows);
    }
    try view.render();
    for (start..total) |slot_index| stampSlot(scene, slot_index, view.resetEpoch());
}

fn slotRewritten(scene: *const Scene.Conversation, index: usize, epoch: u64) bool {
    if (index < scene.transcript.len) return scene.transcript[index].takeRewritten(epoch);
    const offset = index - scene.transcript.len;
    return switch (scene.tail) {
        .turn => |turn| offset < turn.tracks.len and
            turn.tracks[offset].changed and
            turn.tracks[offset].epoch == epoch,
        .prompt, .picking => false,
    };
}

fn stampSlot(scene: *const Scene.Conversation, index: usize, epoch: u64) void {
    if (index < scene.transcript.len) return scene.transcript[index].stampEpoch(epoch);
    const offset = index - scene.transcript.len;
    switch (scene.tail) {
        .turn => |turn| if (offset < turn.tracks.len) {
            turn.tracks[offset].epoch = epoch;
        },
        .prompt, .picking => {},
    }
}

fn tailCount(tail: *const Tail) usize {
    return switch (tail.*) {
        .prompt, .picking => 1,
        .turn => |turn| turn.tools.len + 1,
    };
}

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
    .account = .anthropic_plan,
    .quota = null,
    .quota_age_ms = 0,
    .credits = null,
    .turn_active = false,
};

fn shownEntries(
    gpa: std.mem.Allocator,
    entries: []ui.block.Entry,
) !std.ArrayList(*ui.block.Entry) {
    var shown: std.ArrayList(*ui.block.Entry) = .empty;
    errdefer shown.deinit(gpa);
    for (entries) |*entry| try shown.append(gpa, entry);
    return shown;
}

fn projected(gpa: std.mem.Allocator, size: terminal.View.Size, scene: *const Scene) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    try project(gpa, &view, size, scene);
    return gpa.dupe(u8, out.written());
}

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
    try std.testing.expect(intro < user);
    try std.testing.expect(user < reply);
    try std.testing.expect(reply < footer);
    try std.testing.expect(ui.block.paintedRows(painted) < 24);
}

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
    try std.testing.expectEqual(
        ui.block.paintedRows(painted),
        ui.block.paintedRows(without) + 1,
    );
}

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
    try std.testing.expect(std.mem.indexOf(u8, painted, "L59") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "L0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "footerqq") != null);
}

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

    const streamed = out.written().len;
    try entries.items[1].appendText(gpa, "\n\ngrownxx");
    try project(gpa, &view, size, &scene);
    const grown = out.written()[streamed..];
    try std.testing.expect(std.mem.indexOf(u8, grown, "grownxx") != null);
    try std.testing.expect(std.mem.indexOf(u8, grown, "useryy") == null);
}

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

fn resetSince(written: []const u8, painted: usize) bool {
    return std.mem.indexOf(u8, written[painted..], terminal.escape.screen_reset) != null;
}

test "a block that changes above the window forces a reset" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();
    const size: terminal.View.Size = .{ .columns = 40, .rows = 12 };

    var entries: std.ArrayList(ui.block.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.append(gpa, try ui.block.Entry.init(gpa, .event, .{}, "waiting"));
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, .{}, "block0"));
    var shown = try shownEntries(gpa, entries.items);
    defer shown.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const scene: Scene = .{ .conversation = .{
        .window_pages = window_pages_min,
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    try project(gpa, &view, size, &scene);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "waiting") != null);

    for (1..7) |index| {
        var buffer: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "block{d}", .{index}) catch unreachable;
        try entries.append(gpa, try ui.block.Entry.init(gpa, .model, .{}, text));
    }
    shown.deinit(gpa);
    shown = try shownEntries(gpa, entries.items);
    const slid: Scene = .{ .conversation = .{
        .window_pages = window_pages_min,
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    var painted = out.written().len;
    try project(gpa, &view, size, &slid);
    try std.testing.expect(std.mem.indexOf(u8, out.written()[painted..], "block6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written()[painted..], "block0") == null);
    try std.testing.expect(!resetSince(out.written(), painted));

    try entries.items[0].replaceEvent(gpa, .{}, "changed above");
    painted = out.written().len;
    try project(gpa, &view, size, &slid);
    try std.testing.expect(resetSince(out.written(), painted));
    painted = out.written().len;
    try project(gpa, &view, size, &slid);
    try std.testing.expect(!resetSince(out.written(), painted));

    try entries.items[0].replaceEvent(gpa, .{}, "changed again");
    painted = out.written().len;
    try project(gpa, &view, size, &slid);
    try std.testing.expect(!resetSince(out.written(), painted));

    var reply = try ui.block.numberedLines(gpa, 20);
    defer reply.deinit(gpa);
    try entries.append(gpa, try ui.block.Entry.init(gpa, .model, .{}, reply.items));
    shown.deinit(gpa);
    shown = try shownEntries(gpa, entries.items);
    const streaming: Scene = .{ .conversation = .{
        .window_pages = window_pages_min,
        .transcript = shown.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    try project(gpa, &view, size, &streaming);
    for (0..4) |_| {
        try entries.items[entries.items.len - 1].appendText(gpa, "\nmore");
        painted = out.written().len;
        try project(gpa, &view, size, &streaming);
        try std.testing.expect(std.mem.indexOf(u8, out.written()[painted..], "more") != null);
        try std.testing.expect(!resetSince(out.written(), painted));
    }

    var fresh_out: std.Io.Writer.Allocating = .init(gpa);
    defer fresh_out.deinit();
    var fresh_view = terminal.View.init(gpa, &fresh_out.writer);
    defer fresh_view.deinit();
    var unseen = try ui.block.Entry.init(gpa, .event, .{}, "unseen");
    defer unseen.deinit(gpa);
    var fresh: std.ArrayList(*ui.block.Entry) = .empty;
    defer fresh.deinit(gpa);
    try fresh.append(gpa, &unseen);
    for (entries.items[1..]) |*entry| try fresh.append(gpa, entry);
    const hidden: Scene = .{ .conversation = .{
        .window_pages = window_pages_min,
        .transcript = fresh.items,
        .tail = .{ .prompt = .{ .caption = null, .editor = &editor } },
        .status = &test_status,
    } };
    try project(gpa, &fresh_view, size, &hidden);
    try std.testing.expect(std.mem.indexOf(u8, fresh_out.written(), "unseen") == null);
    try unseen.replaceEvent(gpa, .{}, "changed unseen");
    painted = fresh_out.written().len;
    try project(gpa, &fresh_view, size, &hidden);
    try std.testing.expect(!resetSince(fresh_out.written(), painted));
}

test "a tool box that changes above the window forces a reset" {
    const gpa = std.testing.allocator;
    var editor = ui.Editor.init(gpa);
    defer editor.deinit();

    var tools: [6]ui.paint.Box = undefined;
    for (&tools, 0..) |*box, index| {
        var buffer: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "tool{d}", .{index}) catch unreachable;
        box.* = .{ .text = try gpa.dupe(u8, text), .fit = .head };
    }
    defer for (tools) |box| gpa.free(box.text);
    var tracks = [_]Track{.{}} ** tools.len;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const size: terminal.View.Size = .{ .columns = 40, .rows = 12 };
    const scene: Scene = .{ .conversation = .{
        .window_pages = window_pages_min,
        .transcript = &.{},
        .tail = .{ .turn = .{
            .tools = &tools,
            .tracks = &tracks,
            .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
            .caption = null,
            .editor = &editor,
        } },
        .status = &test_status,
    } };
    for (&tracks) |*track| track.epoch = view.resetEpoch();
    try project(gpa, &view, size, &scene);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tool0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tool5") != null);

    tracks[tools.len - 1].changed = true;
    var painted = out.written().len;
    try project(gpa, &view, size, &scene);
    try std.testing.expect(!resetSince(out.written(), painted));
    tracks[tools.len - 1].changed = false;

    tracks[0].changed = true;
    painted = out.written().len;
    try project(gpa, &view, size, &scene);
    try std.testing.expect(resetSince(out.written(), painted));
    for (0..3) |_| {
        painted = out.written().len;
        try project(gpa, &view, size, &scene);
        try std.testing.expect(!resetSince(out.written(), painted));
    }

    tracks[1] = .{ .changed = true };
    painted = out.written().len;
    try project(gpa, &view, size, &scene);
    try std.testing.expect(!resetSince(out.written(), painted));
}

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
