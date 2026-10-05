const std = @import("std");

const terminal = @import("terminal");

const ui = @import("ui/root.zig");

pub const window_pages_default: usize = 8;

pub const window_pages_min: usize = 1;
pub const window_pages_max: usize = 64;

const id_page = std.math.maxInt(usize);
const id_input = id_page - 1;
const id_status = id_page - 2;

pub const Scene = union(enum) {
    conversation: Conversation,
    page: *const ui.Page,

    const Conversation = struct {
        window_pages: usize,
        transcript: []ui.Block,
        tail: Tail,
        status: *const ui.status.Info,
    };
};

pub const Tail = union(enum) {
    prompt: Prompt,
    turn: Turn,
    picking: Picking,

    const Prompt = struct {
        caption: ?ui.Caption,
        editor: *const ui.Editor,
    };

    const Picking = struct {
        picker: *const ui.Picker,
        activity: ?ui.paint.Activity,
    };

    const Turn = struct {
        tools: []const ui.paint.Box,
        tracks: []Track,
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
    block: *ui.Block,
    tool_box: ui.paint.Box,
    editor: EditorPresentation,
    picker: Tail.Picking,
    status: *const ui.status.Info,

    fn measure(self: *const Component, size: terminal.View.Size) usize {
        return switch (self.*) {
            .block => |block| block.rows(size.columns),
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
            .block => |block| try block.render(gpa, placement),
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

fn idTool(index: usize) usize {
    return id_status - 1 - index;
}

pub fn project(
    gpa: std.mem.Allocator,
    view: *terminal.View,
    size: terminal.View.Size,
    scene: *const Scene,
) !void {
    std.debug.assert(size.columns > 0 and size.rows > 0);
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
    const capacity = size.rows * scene.window_pages;

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
    for (scene.transcript[0..@min(start, scene.transcript.len)]) |*block| block.release(gpa);

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
        .component = .{ .block = &scene.transcript[index] },
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

test "projection stacks the transcript above the tail, newest at the bottom" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    try rig.add(&.{ .intro = "introxx" });
    try rig.add(&.{ .user = "useryy" });
    try rig.add(&.{ .model = "replyzz" });

    const scene = rig.prompt(&.{});
    const painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const intro = std.mem.indexOf(u8, painted, "introxx").?;
    const user = std.mem.indexOf(u8, painted, "useryy").?;
    const reply = std.mem.indexOf(u8, painted, "replyzz").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(intro < user);
    try std.testing.expect(user < reply);
    try std.testing.expect(reply < footer);
    try std.testing.expect(ui.testing.paintedRows(painted) < 24);
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
    .account = "anthropic-plan",
    .quota = null,
    .quota_age_ms = 0,
    .credits = null,
    .turn_active = false,
};

fn projected(gpa: std.mem.Allocator, size: terminal.View.Size, scene: *const Scene) ![]u8 {
    var screen: ui.testing.Rig = undefined;
    screen.init(gpa);
    defer screen.deinit();
    try project(gpa, &screen.view, size, scene);
    return gpa.dupe(u8, screen.out.written());
}

const Rig = struct {
    editor: ui.Editor,
    blocks: std.ArrayList(ui.Block),

    const PromptOptions = struct {
        window_pages: usize = window_pages_default,
        caption: ?ui.Caption = null,
    };

    const TurnOptions = struct {
        window_pages: usize = window_pages_default,
        tools: []const ui.paint.Box = &.{},
        tracks: []Track = &.{},
        caption: ?ui.Caption = null,
    };

    fn init() Rig {
        return .{ .editor = .init(std.testing.allocator), .blocks = .empty };
    }

    fn deinit(self: *Rig) void {
        for (self.blocks.items) |*block| block.deinit(std.testing.allocator);
        self.blocks.deinit(std.testing.allocator);
        self.editor.deinit();
    }

    fn add(self: *Rig, source: *const ui.Block.Source) !void {
        const gpa = std.testing.allocator;
        var block: ui.Block = try .init(gpa, source);
        errdefer block.deinit(gpa);
        try self.blocks.append(gpa, block);
    }

    fn addModels(self: *Rig, first: usize, end: usize) !void {
        for (first..end) |index| {
            var buffer: [16]u8 = undefined;
            try self.add(&.{ .model = try std.fmt.bufPrint(&buffer, "block{d}", .{index}) });
        }
    }

    fn prompt(self: *Rig, options: *const PromptOptions) Scene {
        return .{ .conversation = .{
            .window_pages = options.window_pages,
            .transcript = self.blocks.items,
            .tail = .{ .prompt = .{ .caption = options.caption, .editor = &self.editor } },
            .status = &test_status,
        } };
    }

    fn turn(self: *Rig, options: *const TurnOptions) Scene {
        return .{ .conversation = .{
            .window_pages = options.window_pages,
            .transcript = self.blocks.items,
            .tail = .{ .turn = .{
                .tools = options.tools,
                .tracks = options.tracks,
                .activity = .{ .motion_tick = 0, .progress_age_ticks = 0 },
                .caption = options.caption,
                .editor = &self.editor,
            } },
            .status = &test_status,
        } };
    }
};

test "a turn tail stacks tool boxes above the active editor" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    const tools = [_]ui.paint.Box{
        .{ .text = "readbox" },
        .{ .text = "grepbox", .fit = .head },
    };
    const scene = rig.turn(&.{ .tools = &tools });
    const painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const first = std.mem.indexOf(u8, painted, "readbox").?;
    const second = std.mem.indexOf(u8, painted, "grepbox").?;
    const activity = std.mem.indexOf(u8, painted, "━").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(first < second);
    try std.testing.expect(second < activity);
    try std.testing.expect(activity < footer);
    try ui.testing.expectHides(painted, &.{"Working…"});
}

test "frame edge activity does not change the input tail height" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    const prompt = rig.prompt(&.{});
    const turn = rig.turn(&.{});
    const prompt_painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &prompt);
    defer gpa.free(prompt_painted);
    const turn_painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &turn);
    defer gpa.free(turn_painted);

    try std.testing.expectEqual(
        ui.testing.paintedRows(prompt_painted),
        ui.testing.paintedRows(turn_painted),
    );
}

test "a turn tail shows its input caption above the editor" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    const scene = rig.turn(&.{ .caption = .{
        .title = "Remote: @drinky_bot",
        .controls = "Esc: Detach",
    } });
    const painted = try projected(gpa, .{ .columns = 40, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const title = std.mem.indexOf(u8, painted, "Remote: @drinky_bot").?;
    const control = std.mem.indexOf(u8, painted, "Esc: Detach").?;
    const frame = std.mem.indexOf(u8, painted, "─").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(title < control);
    try std.testing.expect(control < frame);
    try std.testing.expect(frame < footer);
}

test "a prompt tail shows its input caption above the editor" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();
    try rig.editor.insert("draft text");

    try rig.add(&.{ .event = .{
        .text = "the turn failed",
        .severity = .failure,
    } });

    const scene = rig.prompt(&.{ .caption = .{
        .title = "Sign in: anthropic-plan",
        .controls = "Enter: Replay callback URL · Esc: Cancel",
    } });
    const painted = try projected(gpa, .{ .columns = 80, .rows = 24 }, &scene);
    defer gpa.free(painted);

    const failure = std.mem.indexOf(u8, painted, "the turn failed").?;
    const title = std.mem.indexOf(u8, painted, "Sign in: anthropic-plan").?;
    const control = std.mem.indexOf(u8, painted, "Enter: Replay callback URL").?;
    const draft = std.mem.indexOf(u8, painted, "draft text").?;
    const footer = std.mem.indexOf(u8, painted, "footerqq").?;
    try std.testing.expect(failure < title);
    try std.testing.expect(title < control);
    try std.testing.expect(control < draft);
    try std.testing.expect(draft < footer);

    const bare = rig.prompt(&.{});
    const without = try projected(gpa, .{ .columns = 80, .rows = 24 }, &bare);
    defer gpa.free(without);
    try ui.testing.expectHides(without, &.{"Sign in"});
    try std.testing.expectEqual(
        ui.testing.paintedRows(painted),
        ui.testing.paintedRows(without) + 1,
    );
}

test "a narrow editor caption keeps every row inside the window" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    const scene = rig.turn(&.{ .caption = .{
        .title = "Remote: @drinky_bot",
        .controls = "Esc: Detach",
    } });
    const painted = try projected(gpa, .{ .columns = 8, .rows = 24 }, &scene);
    defer gpa.free(painted);
    const plain = try terminal.testing.plainText(gpa, painted);
    defer gpa.free(plain);
    var lines = std.mem.splitSequence(u8, plain, "\r\n");
    while (lines.next()) |row| {
        const line = std.mem.trimEnd(u8, row, "\r");
        try std.testing.expect(terminal.width.ofText(line) <= 8);
    }
    try ui.testing.expectShows(plain, &.{ui.paint.ellipsis});
}

test "projection clips the oldest block to fill the window exactly" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    var text = try ui.testing.numberedLines(gpa, 60);
    defer text.deinit(gpa);
    try rig.add(&.{ .model = text.items });

    const scene = rig.prompt(&.{});
    const rows: usize = 4;
    const painted = try projected(gpa, .{ .columns = 40, .rows = rows }, &scene);
    defer gpa.free(painted);

    try std.testing.expectEqual(rows * window_pages_default, ui.testing.paintedRows(painted));
    try ui.testing.expectShows(painted, &.{"L59"});
    try ui.testing.expectHides(painted, &.{"L0"});
    try ui.testing.expectShows(painted, &.{"footerqq"});
}

test "a repeated projection composes the rows of the first one" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    try rig.add(&.{ .user = "useryy" });
    try rig.add(&.{ .model = "## replyzz\n\nsome text" });

    const scene = rig.prompt(&.{});
    var screen: ui.testing.Rig = undefined;
    screen.init(gpa);
    defer screen.deinit();
    const size: terminal.View.Size = .{ .columns = 40, .rows = 24 };

    try project(gpa, &screen.view, size, &scene);
    const composed = screen.out.written().len;
    for (rig.blocks.items) |*block| {
        try std.testing.expectEqual(size.columns, block.cache.columns);
        try std.testing.expect(block.cache.lines.count() > 0);
    }

    try project(gpa, &screen.view, size, &scene);
    const replayed = screen.out.written()[composed..];
    try ui.testing.expectHides(replayed, &.{"useryy"});
    try ui.testing.expectHides(replayed, &.{"replyzz"});

    const streamed = screen.out.written().len;
    try rig.blocks.items[1].appendText(gpa, "\n\ngrownxx");
    try project(gpa, &screen.view, size, &scene);
    const grown = screen.out.written()[streamed..];
    try ui.testing.expectShows(grown, &.{"grownxx"});
    try ui.testing.expectHides(grown, &.{"useryy"});
}

test "a block outside the window releases the rows it retained" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    try rig.addModels(0, 6);

    const tall = rig.prompt(&.{});
    gpa.free(try projected(gpa, .{ .columns = 40, .rows = 24 }, &tall));
    for (rig.blocks.items) |*block| try std.testing.expect(block.cache.lines.count() > 0);

    const short = rig.prompt(&.{ .window_pages = window_pages_min });
    const painted = try projected(gpa, .{ .columns = 40, .rows = 8 }, &short);
    defer gpa.free(painted);

    try ui.testing.expectHides(painted, &.{"block0"});
    try std.testing.expectEqual(@as(usize, 0), rig.blocks.items[0].cache.lines.count());
    try std.testing.expect(rig.blocks.items[rig.blocks.items.len - 1].cache.lines.count() > 0);
    for (rig.blocks.items, 0..) |*block, index| {
        var buffer: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "block{d}", .{index});
        if (std.mem.indexOf(u8, painted, text) != null) continue;
        try std.testing.expectEqual(@as(usize, 0), block.cache.lines.count());
    }
}

fn resetSince(written: []const u8, painted: usize) bool {
    return std.mem.indexOf(u8, written[painted..], terminal.escape.screen_reset) != null;
}

test "a block that changes above the window forces a reset" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();
    const size: terminal.View.Size = .{ .columns = 40, .rows = 12 };

    try rig.add(&.{ .event = .{ .text = "waiting" } });
    try rig.add(&.{ .model = "block0" });

    var screen: ui.testing.Rig = undefined;
    screen.init(gpa);
    defer screen.deinit();
    const scene = rig.prompt(&.{ .window_pages = window_pages_min });
    try project(gpa, &screen.view, size, &scene);
    try ui.testing.expectShows(screen.out.written(), &.{"waiting"});

    try rig.addModels(1, 7);
    const slid = rig.prompt(&.{ .window_pages = window_pages_min });
    var painted = screen.out.written().len;
    try project(gpa, &screen.view, size, &slid);
    try ui.testing.expectShows(screen.out.written()[painted..], &.{"block6"});
    try ui.testing.expectHides(screen.out.written()[painted..], &.{"block0"});
    try std.testing.expect(!resetSince(screen.out.written(), painted));

    try rig.blocks.items[0].replaceEvent(gpa, &.{ .text = "changed above" });
    painted = screen.out.written().len;
    try project(gpa, &screen.view, size, &slid);
    try std.testing.expect(resetSince(screen.out.written(), painted));
    painted = screen.out.written().len;
    try project(gpa, &screen.view, size, &slid);
    try std.testing.expect(!resetSince(screen.out.written(), painted));

    try rig.blocks.items[0].replaceEvent(gpa, &.{ .text = "changed again" });
    painted = screen.out.written().len;
    try project(gpa, &screen.view, size, &slid);
    try std.testing.expect(!resetSince(screen.out.written(), painted));

    var reply = try ui.testing.numberedLines(gpa, 20);
    defer reply.deinit(gpa);
    try rig.add(&.{ .model = reply.items });
    const streaming = rig.prompt(&.{ .window_pages = window_pages_min });
    try project(gpa, &screen.view, size, &streaming);
    for (0..4) |_| {
        try rig.blocks.items[rig.blocks.items.len - 1].appendText(gpa, "\nmore");
        painted = screen.out.written().len;
        try project(gpa, &screen.view, size, &streaming);
        try ui.testing.expectShows(screen.out.written()[painted..], &.{"more"});
        try std.testing.expect(!resetSince(screen.out.written(), painted));
    }

    var fresh_screen: ui.testing.Rig = undefined;
    fresh_screen.init(gpa);
    defer fresh_screen.deinit();
    var fresh_rig: Rig = .init();
    defer fresh_rig.deinit();
    try fresh_rig.add(&.{ .event = .{ .text = "unseen" } });
    for (rig.blocks.items[1..]) |*block| {
        const text = block.content.model.items;
        try fresh_rig.add(&.{ .model = text });
    }
    const hidden = fresh_rig.prompt(&.{ .window_pages = window_pages_min });
    try project(gpa, &fresh_screen.view, size, &hidden);
    try ui.testing.expectHides(fresh_screen.out.written(), &.{"unseen"});
    try fresh_rig.blocks.items[0].replaceEvent(gpa, &.{ .text = "changed unseen" });
    painted = fresh_screen.out.written().len;
    try project(gpa, &fresh_screen.view, size, &hidden);
    try std.testing.expect(!resetSince(fresh_screen.out.written(), painted));
}

test "a tool box that changes above the window forces a reset" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    var tools: [6]ui.paint.Box = undefined;
    for (&tools, 0..) |*box, index| {
        var buffer: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "tool{d}", .{index});
        box.* = .{ .text = try gpa.dupe(u8, text), .fit = .head };
    }
    defer for (tools) |box| gpa.free(box.text);
    var tracks = [_]Track{.{}} ** tools.len;

    var screen: ui.testing.Rig = undefined;
    screen.init(gpa);
    defer screen.deinit();
    const size: terminal.View.Size = .{ .columns = 40, .rows = 12 };
    const scene = rig.turn(
        &.{ .window_pages = window_pages_min, .tools = &tools, .tracks = &tracks },
    );
    for (&tracks) |*track| track.epoch = screen.view.resetEpoch();
    try project(gpa, &screen.view, size, &scene);
    try ui.testing.expectHides(screen.out.written(), &.{"tool0"});
    try ui.testing.expectShows(screen.out.written(), &.{"tool5"});

    tracks[tools.len - 1].changed = true;
    var painted = screen.out.written().len;
    try project(gpa, &screen.view, size, &scene);
    try std.testing.expect(!resetSince(screen.out.written(), painted));
    tracks[tools.len - 1].changed = false;

    tracks[0].changed = true;
    painted = screen.out.written().len;
    try project(gpa, &screen.view, size, &scene);
    try std.testing.expect(resetSince(screen.out.written(), painted));
    for (0..3) |_| {
        painted = screen.out.written().len;
        try project(gpa, &screen.view, size, &scene);
        try std.testing.expect(!resetSince(screen.out.written(), painted));
    }

    tracks[1] = .{ .changed = true };
    painted = screen.out.written().len;
    try project(gpa, &screen.view, size, &scene);
    try std.testing.expect(!resetSince(screen.out.written(), painted));
}

test "the retained window follows the configured page count" {
    const gpa = std.testing.allocator;
    var rig: Rig = .init();
    defer rig.deinit();

    var text = try ui.testing.numberedLines(gpa, 200);
    defer text.deinit(gpa);
    try rig.add(&.{ .model = text.items });

    const rows: usize = 4;
    for ([_]usize{ window_pages_min, 3, 12 }) |pages| {
        const scene = rig.prompt(&.{ .window_pages = pages });
        const painted = try projected(gpa, .{ .columns = 40, .rows = rows }, &scene);
        defer gpa.free(painted);
        try std.testing.expectEqual(rows * pages, ui.testing.paintedRows(painted));
    }
}
