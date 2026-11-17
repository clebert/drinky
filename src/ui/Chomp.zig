const std = @import("std");

const paint = @import("paint.zig");
const role = @import("role.zig");

const Chomp = @This();

prng: std.Random.DefaultPrng,
frame: u64 = 0,
level: u32 = 1,
game_frames: u64 = 0,
chase_frames: u64 = 0,
bag: [kinds.len]Kind = kinds,
bag_length: usize = 0,
kind_last: ?Kind = null,
box_last: bool = false,
maybe_board: ?Board = null,

const columns_max = 512;

pub const Layout = struct {
    columns: usize,
    top_label_end: ?usize = null,
    bottom_label_end: ?usize = null,

    fn laneStart(self: *const Layout) usize {
        return if (self.bottom_label_end) |end| end + label_gap else 0;
    }

    fn laneStartSigned(self: *const Layout) isize {
        return @intCast(self.laneStart());
    }

    fn laneColumns(self: *const Layout) usize {
        return self.columns -| self.laneStart();
    }

    fn laneSpan(self: *const Layout, fraction: f64) isize {
        return @intFromFloat(@floor(@as(f64, @floatFromInt(self.laneColumns())) * fraction));
    }

    fn laneAt(self: *const Layout, fraction: f64) isize {
        return self.laneStartSigned() + self.laneSpan(fraction);
    }

    fn columnsSigned(self: *const Layout) isize {
        return @intCast(self.columns);
    }

    fn titleSpan(self: *const Layout, width: usize) ?Span {
        const left = if (self.top_label_end) |end| end + label_gap else 0;
        return centered(&.{ .width = width, .left = left, .columns = self.columns });
    }
};

pub const Edge = enum { top, bottom };

pub const Cell = struct {
    glyph: []const u8,
    role: role.Name,
};

const Board = struct {
    layout: Layout,
    phase: Phase,
};

const Phase = union(enum) {
    lap: Lap,
    flash: u32,
    game_over: u32,
};

const Lap = struct {
    chomper: Mover,
    hold: u32 = 0,
    eaten: Cells = .empty,
    item: ?Item = null,
    pickup: ?Pickup = null,
    event: ?Event = null,

    fn inTunnel(self: *const Lap, layout: *const Layout) bool {
        return self.chomper.position >= layout.columnsSigned() - 1;
    }

    fn markEaten(self: *Lap, layout: *const Layout, position: isize) void {
        if (position < 0 or position >= layout.columnsSigned()) return;
        self.eaten.set(@intCast(position));
    }

    fn caught(self: *const Lap) bool {
        const event = if (self.event) |*event| event else return false;
        return switch (event.*) {
            .chase => |*chase| switch (chase.*) {
                .hit, .dead => true,
                .wait, .rise, .alert, .run, .stop => false,
            },
            .hunt, .love, .nap, .hole, .music, .slot, .mirror => false,
        };
    }

    fn jackpotRole(self: *const Lap) ?role.Name {
        const event = if (self.event) |*event| event else return null;
        return switch (event.*) {
            .slot => |*slot| switch (slot.*) {
                .win => |*reels| if (reels.frames < win_symbol_frames)
                    winBlink(reels.frames)
                else if (reels.frames < win_frames) .score else null,
                .wait, .spin, .lose => null,
            },
            .hunt, .chase, .love, .nap, .hole, .music, .mirror => null,
        };
    }
};

const Cells = std.StaticBitSet(columns_max);

const Kind = enum { hunt, chase, love, nap, hole, music, slot, mirror };

const kinds = [_]Kind{ .hunt, .chase, .love, .nap, .hole, .music, .slot, .mirror };

const ItemKind = enum { pellet, heart, hole, note, moon, coin, mirror };

const box_kinds = [_]ItemKind{ .pellet, .heart, .note, .hole, .moon, .coin };

const Item = struct { column: isize, kind: ItemKind, box: bool };

const Pickup = struct { kind: ItemKind, frames: u32 };

const Mover = struct {
    position: isize,
    credit: u32 = 0,

    fn moves(self: *Mover, cost: u32) bool {
        self.credit += credit_per_frame;
        if (self.credit < cost) return false;
        self.credit = @min(self.credit - cost, cost);
        return true;
    }
};

const Ghost = struct { column: isize, frames: u32 = 0 };

const Look = union(enum) { default, hidden, cell: Cell };

const Step = enum { walks, waits, ends, clears_level, loses_game };

const LapStep = enum { walks, ends };

const Span = struct { start: usize, end: usize };

const Range = struct { low: isize, high: isize };

const Fade = struct { frames: u32, blink_below: u32 };

const Word = struct { text: *const [word_columns]u8, start: ?isize, role: role.Name };

const Event = union(Kind) {
    hunt: Hunt,
    chase: Chase,
    love: Love,
    nap: Nap,
    hole: Hole,
    music: Music,
    slot: Slot,
    mirror: Mirror,
};

const Hunt = union(enum) {
    roam: Roam,
    power: Power,
    burst: Burst,
    recover: Ghost,

    const Roam = struct { ghost: ?Mover, low: isize };

    const Power = struct { ghost: Mover, frames: u32 };

    const Burst = struct { column: isize, score_start: ?isize, frames: u32 = 0 };
};

const Chase = union(enum) {
    wait: isize,
    rise: Ghost,
    alert: Ghost,
    run: Run,
    stop: Ending,
    hit: Ghost,
    dead: Ending,

    const Ending = struct { column: isize, word_start: ?isize, frames: u32 = 0 };

    const Outcome = enum { escape, caught };

    const Run = struct {
        outcome: Outcome,
        ghost: isize,
        start: isize,
        span: u64,
        duration: u64,
        frames: u64 = 0,
    };
};

const Love = union(enum) {
    wait,
    partner: Mover,
    meet: Meet,

    const Meet = struct { position: isize, other: isize, frames: u32 = 0 };
};

const Nap = union(enum) {
    wait,
    yawn: u32,
    sleep: Sleep,
    wake: u32,
    hurry: u32,

    const Sleep = struct { length: u32, frames: u32 = 0 };
};

const Hole = union(enum) {
    wait,
    sink: Fall,
    crumble: Crumble,
    pop: Pop,

    const Fall = struct { entry: isize, exit: isize, frames: u32 = 0 };

    const Crumble = struct { entry: isize, exit: isize, wave: isize, frame_start: u64 };

    const Pop = struct { exit: isize, frames: u32 = 0 };
};

const Music = union(enum) {
    wait,
    trail: Trail,

    const Trail = struct {
        column: isize,
        born: [trail_slots]u64 = undefined,
        count: usize = 0,
    };
};

const Slot = union(enum) {
    wait,
    spin: Spin,
    win: Reels,
    lose: Reels,

    const Outcome = enum { win, near, miss };

    const Spin = struct {
        reels: Reels,
        symbols: [reel_count]usize,
        waits: [reel_count]u32 = @splat(0),

        fn suspense(self: *const Spin) bool {
            return self.symbols[0] == self.symbols[1];
        }

        fn stop(self: *const Spin, reel: usize) u32 {
            if (reel == reel_count - 1 and self.suspense()) return reel_suspense_stop_frames;
            return reel_stop_frames[reel];
        }

        fn period(self: *const Spin, reel: usize) u32 {
            const slowing = reel == reel_count - 1 and self.suspense();
            if (!slowing) return reel_period_frames;
            const late = self.reels.frames -| reel_stop_frames[reel_count - 2];
            return reel_period_frames + @divFloor(late, reel_slowing_frames);
        }
    };

    const Reels = struct { start: ?isize, shown: [reel_count]usize, frames: u32 = 0 };
};

const Mirror = union(enum) {
    wait,
    face: Glass,
    look: Glass,
    crack: Glass,

    const Glass = struct { column: isize, frames: u32 = 0 };
};

const catch_ms_median = @divExact(9 * std.time.ms_per_min, 2);
const danger_exponent = 2;

const credit_per_frame = 2;
const cost_walk = 4;
const cost_power = 3;
const cost_fast = 2;
const cost_ghost_roam = 14;
const cost_ghost_flee = 7;
const cost_nap_slowdown = 3;

const flee_away_chance = 0.7;
const box_odds = 6;

const line_cells_min = 8;
const label_gap = 1;
const event_lane_min = 40;
const item_offset_min = 6;
const tunnel_cells = 3;
const mouth_frames = 4;
const flash_frames = 56;
const flash_blink_start = 24;
const game_over_frames = 150;
const spin_frames = 34;
const pickup_frames = 30;
const catch_hold_frames = 28;
const fade_frames = 40;
const fade_blink_frames = 6;
const rise_frames = 24;
const alert_frames = 36;
const hit_frames = 32;
const curse_frames = 60;
const curse_swap_frames = 10;
const dead_frames = 130;
const grave_frames = 48;
const rip_frames = 60;
const meet_frames = 120;
const yawn_frames = 40;
const wake_frames = 44;
const sleep_cycle_frames = 96;
const drowsy_cells = 4;
const sink_frames = 14;
const crumble_cells_per_frame = 2;
const crumble_dot_frames = 8;
const power_flash_frames = 4;
const trail_slots = 12;
const reel_count = 3;
const reel_stop_frames = [reel_count]u32{ 24, 44, 64 };
const reel_suspense_stop_frames = 108;
const reel_period_frames = 2;
const reel_slowing_frames = 10;
const reel_settle_frames = 12;
const win_dance_frames = 48;
const win_blink_frames = 6;
const win_symbol_frames = 36;
const win_frames = 84;
const reels_fade_frames = 40;
const lose_frames = 30;
const mirror_reach = 12;
const face_frames = 36;
const look_frames = 40;
const crack_frames = 16;
const trail_spacing = 2;
const note_bright_frames = 18;
const note_fade_frames = 30;
const score_bright_frames = 44;
const score_fade_frames = 60;

const anchor_top = [_]isize{0};
const nap_top = [_]isize{ 0, 2, 3 };
const mirror_top = [_]isize{ -1, 1 };
const word_top = offsets: {
    var offsets: [word_columns]isize = undefined;
    for (&offsets, 0..) |*offset, index| offset.* = index;
    break :offsets offsets;
};

const word_columns = 3;
const score_text: *const [word_columns]u8 = "200";
const rip_text: *const [word_columns]u8 = "RIP";
const jackpot_text: *const [word_columns]u8 = "1UP";
const curse_texts = [_]*const [word_columns]u8{ "#@!", "@#$" };

const level_prefix = " Level ";
const game_over_text = " Game over ";
const digits = "0123456789";

const glyph_right = "ᗧ";
const glyph_left = "ᗤ";
const glyph_shut = "●";
const glyph_small = "•";
const glyph_hole = "○";
const glyph_heart = "♥";
const glyph_heart_hollow = "♡";
const glyph_note = "♪";
const glyph_notes = "♫";
const glyph_spark = "˙";
const glyph_dot = "·";
const glyph_ghost = "ᗣ";
const glyph_sleep = "ᶻ";
const glyph_moon = "☾";
const glyph_grave = "✝";
const glyph_coin = "$";
const glyph_mirror = "│";

const reel_glyphs = [_][]const u8{ glyph_shut, glyph_heart, glyph_note, glyph_moon, glyph_coin };

const frame_cell: Cell = .{ .glyph = "─", .role = .input_frame };
const blank_cell: Cell = .{ .glyph = " ", .role = .text };
const hole_cell: Cell = .{ .glyph = glyph_hole, .role = .text };
const ghost_cell: Cell = .{ .glyph = glyph_ghost, .role = .ghost };
const pellet_cell: Cell = .{ .glyph = glyph_shut, .role = .text };
const pellet_small_cell: Cell = .{ .glyph = glyph_small, .role = .text };
const moon_cell: Cell = .{ .glyph = glyph_moon, .role = .text };
const grave_cell: Cell = .{ .glyph = glyph_grave, .role = .text };
const mirror_cell: Cell = .{ .glyph = glyph_mirror, .role = .text };

pub fn init(seed: u64) Chomp {
    return .{ .prng = .init(seed) };
}

pub fn fit(self: *Chomp, layout: *const Layout) void {
    var next = layout.*;
    next.columns = @min(next.columns, columns_max);
    const board = if (self.maybe_board) |*board| board else {
        self.maybe_board = .{ .layout = next, .phase = .{ .lap = self.startLap(&next) } };
        return;
    };
    if (std.meta.eql(next, board.layout)) return;
    const resized = next.columns != board.layout.columns;
    board.layout = next;
    if (resized) {
        const lost = switch (board.phase) {
            .lap => |*lap| lap.caught(),
            .flash => false,
            .game_over => true,
        };
        if (lost) self.resetGame();
        board.phase = .{ .lap = self.startLap(&board.layout) };
        return;
    }
    switch (board.phase) {
        .lap => |*lap| {
            const lane_start = next.laneStartSigned();
            lap.chomper.position = @max(lap.chomper.position, lane_start - 1);
            if (lap.item) |item| {
                if (item.column < lane_start) lap.item = null;
            }
        },
        .flash, .game_over => {},
    }
}

pub fn reset(self: *Chomp) void {
    self.resetGame();
    const board = if (self.maybe_board) |*board| board else return;
    board.phase = .{ .lap = self.startLap(&board.layout) };
}

pub fn advance(self: *Chomp) void {
    const board = if (self.maybe_board) |*board| board else return;
    self.frame +%= 1;
    switch (board.phase) {
        .lap => |*lap| {
            self.game_frames += 1;
            self.advanceLap(board, lap);
        },
        .flash => |*frames| {
            self.game_frames += 1;
            frames.* += 1;
            if (frames.* >= flash_frames) board.phase = .{ .lap = self.startLap(&board.layout) };
        },
        .game_over => |*frames| {
            frames.* += 1;
            if (frames.* < game_over_frames) return;
            self.reset();
        },
    }
}

pub fn cell(self: *const Chomp, edge: Edge, column: usize) Cell {
    const board = if (self.maybe_board) |*board| board else return frame_cell;
    if (column >= board.layout.columns) return frame_cell;
    return switch (edge) {
        .top => self.topCell(board, column),
        .bottom => self.bottomCell(board, column),
    };
}

fn catchChance(frames: *const struct { previous: u64, now: u64 }) f64 {
    const median: f64 = @divExact(catch_ms_median, paint.frame_ms);
    const previous = @as(f64, @floatFromInt(frames.previous)) / median;
    const now = @as(f64, @floatFromInt(frames.now)) / median;
    const exponent = std.math.pow(f64, now, danger_exponent) -
        std.math.pow(f64, previous, danger_exponent);
    return 1 - std.math.pow(f64, 0.5, exponent);
}

fn advanceLap(self: *Chomp, board: *Board, lap: *Lap) void {
    const layout = &board.layout;
    if (lap.pickup) |*pickup| {
        pickup.frames += 1;
        if (pickup.frames >= spin_frames + pickup_frames) {
            lap.pickup = null;
            settleLap(lap, self.trigger(layout, lap));
        }
        return;
    }
    if (self.tickEvent(board, lap)) return;
    if (lap.hold > 0) {
        lap.hold -= 1;
        return;
    }
    if (!lap.chomper.moves(stepCost(lap))) return;
    if (lap.inTunnel(layout)) {
        const end = layout.columnsSigned() + tunnel_cells;
        if (lap.chomper.position < end) lap.chomper.position += 1;
        if (lap.chomper.position >= end and !eventBusy(lap)) self.nextLevel(board);
        return;
    }
    lap.chomper.position += 1;
    self.enter(layout, lap);
}

fn startLap(self: *Chomp, layout: *const Layout) Lap {
    var lap: Lap = .{ .chomper = .{ .position = layout.laneStartSigned() - 1 } };
    if (layout.laneColumns() >= event_lane_min) lap.event = self.chooseEvent(layout, &lap);
    return lap;
}

fn nextLevel(self: *Chomp, board: *Board) void {
    self.level +|= 1;
    board.phase = .{ .flash = 0 };
}

fn resetGame(self: *Chomp) void {
    self.level = 1;
    self.game_frames = 0;
    self.chase_frames = 0;
}

fn chooseEvent(self: *Chomp, layout: *const Layout, lap: *Lap) ?Event {
    const kind = self.nextKind();
    const boxable = switch (kind) {
        .hunt, .love, .nap, .hole, .music, .slot => true,
        .chase, .mirror => false,
    };
    const box = boxable and !self.box_last and self.random().uintLessThan(u8, box_odds) == 0;
    self.box_last = box;
    return switch (kind) {
        .hunt => .{ .hunt = self.startHunt(layout, lap, box) orelse return null },
        .chase => .{ .chase = .{ .wait = self.pickClear(layout, .{
            .low = layout.laneAt(0.15),
            .high = layout.laneAt(0.35),
        }, &anchor_top) orelse return null } },
        .love => if (self.placeItem(layout, lap, .heart, box)) |_| .{ .love = .wait } else null,
        .nap => if (self.placeItem(layout, lap, .moon, box)) |_| .{ .nap = .wait } else null,
        .hole => if (self.placeItem(layout, lap, .hole, box)) |_| .{ .hole = .wait } else null,
        .music => if (self.placeItem(layout, lap, .note, box)) |_| .{ .music = .wait } else null,
        .slot => if (self.placeItem(layout, lap, .coin, box)) |_| .{ .slot = .wait } else null,
        .mirror => if (self.placeItem(layout, lap, .mirror, false)) |_|
            .{ .mirror = .wait }
        else
            null,
    };
}

fn nextKind(self: *Chomp) Kind {
    if (self.bag_length == 0) {
        self.bag = kinds;
        self.random().shuffle(Kind, &self.bag);
        if (self.kind_last) |last| {
            if (self.bag[0] == last) std.mem.swap(Kind, &self.bag[0], &self.bag[1]);
        }
        self.bag_length = kinds.len;
    }
    const kind = self.bag[kinds.len - self.bag_length];
    self.bag_length -= 1;
    self.kind_last = kind;
    return kind;
}

fn startHunt(self: *Chomp, layout: *const Layout, lap: *Lap, box: bool) ?Hunt {
    const pellet = self.placeItem(layout, lap, .pellet, box) orelse return null;
    const low = pellet + 8;
    if (box) return .{ .roam = .{ .ghost = null, .low = low } };
    const first = pellet + 12;
    const column = self.pick(.{ .low = first, .high = first + layout.laneSpan(0.22) });
    const ghost: Mover = .{ .position = std.math.clamp(column, low, layout.columnsSigned() - 3) };
    return .{ .roam = .{ .ghost = ghost, .low = low } };
}

fn placeItem(self: *Chomp, layout: *const Layout, lap: *Lap, kind: ItemKind, box: bool) ?isize {
    const low = layout.laneStartSigned() + item_offset_min;
    const offsets: []const isize = switch (kind) {
        .moon => &nap_top,
        .mirror => &mirror_top,
        .pellet, .heart, .hole, .note, .coin => &anchor_top,
    };
    const fraction: f64 = switch (kind) {
        .pellet => 0.3,
        .heart => 0.35,
        .moon => 0.6,
        .hole, .note, .coin => 0.4,
        .mirror => 0.45,
    };
    const column = self.pickClear(layout, .{
        .low = low,
        .high = @max(low, layout.laneAt(fraction)),
    }, offsets) orelse return null;
    lap.item = .{ .column = column, .kind = kind, .box = box };
    return column;
}

fn pickClear(self: *Chomp, layout: *const Layout, range: Range, offsets: []const isize) ?isize {
    var count: usize = 0;
    var column = range.low;
    while (column <= range.high) : (column += 1)
        count += @intFromBool(self.topClear(layout, column, offsets));
    if (count == 0) return null;
    var chosen = self.random().uintLessThan(usize, count);
    column = range.low;
    while (column <= range.high) : (column += 1) {
        if (!self.topClear(layout, column, offsets)) continue;
        if (chosen == 0) return column;
        chosen -= 1;
    }
    unreachable;
}

fn topClear(self: *const Chomp, layout: *const Layout, anchor: isize, offsets: []const isize) bool {
    for (offsets) |offset| {
        if (!self.topFree(layout, anchor + offset)) return false;
    }
    return true;
}

fn nearestClear(
    self: *const Chomp,
    layout: *const Layout,
    anchor: isize,
    offsets: []const isize,
) ?isize {
    var distance: isize = 0;
    while (distance < layout.columnsSigned()) : (distance += 1) {
        for ([_]isize{ anchor - distance, anchor + distance }) |column| {
            if (self.topClear(layout, column, offsets)) return column;
        }
    }
    return null;
}

fn topFree(self: *const Chomp, layout: *const Layout, column: isize) bool {
    if (column < 0 or column >= layout.columnsSigned()) return false;
    const position: usize = @intCast(column);
    if (layout.top_label_end) |end| {
        if (position < end + label_gap) return false;
    }
    for ([_]u32{ self.level, self.level +| 1 }) |level| {
        const span = layout.titleSpan(levelLabelColumns(level)) orelse continue;
        if (position + 1 >= span.start and position <= span.end) return false;
    }
    return true;
}

fn random(self: *Chomp) std.Random {
    return self.prng.random();
}

fn chance(self: *Chomp, probability: f64) bool {
    return self.random().float(f64) < probability;
}

fn pick(self: *Chomp, range: Range) isize {
    if (range.high <= range.low) return range.low;
    return self.random().intRangeAtMost(isize, range.low, range.high);
}

fn enter(self: *Chomp, layout: *const Layout, lap: *Lap) void {
    const position = lap.chomper.position;
    lap.markEaten(layout, position);
    if (lap.item) |item| {
        if (item.column == position) {
            lap.item = null;
            const collected = switch (item.kind) {
                .pellet, .heart, .note, .moon, .coin => true,
                .hole => item.box,
                .mirror => false,
            };
            if (collected) {
                lap.pickup = .{ .kind = item.kind, .frames = if (item.box) 0 else spin_frames };
            } else settleLap(lap, self.trigger(layout, lap));
        }
    }
    const event = if (lap.event) |*event| event else return;
    const step: LapStep = switch (event.*) {
        .hunt, .love, .hole, .slot => .walks,
        .chase => |*chase| enterChase(layout, lap, chase),
        .nap => |*nap| enterNap(nap),
        .music => |*music| self.enterMusic(music, position),
        .mirror => |*mirror| enterMirror(lap, mirror),
    };
    settleLap(lap, step);
}

fn trigger(self: *Chomp, layout: *const Layout, lap: *Lap) LapStep {
    const event = if (lap.event) |*event| event else return .walks;
    switch (event.*) {
        .hunt => |*hunt| {
            const ghost: Mover = switch (hunt.*) {
                .roam => |*roam| roam.ghost orelse .{ .position = @min(
                    layout.columnsSigned() - 4,
                    lap.chomper.position + self.pick(.{ .low = 14, .high = 30 }),
                ) },
                .power, .burst, .recover => return .walks,
            };
            const frames = self.random().intRangeAtMost(u32, 210, 330);
            hunt.* = .{ .power = .{ .ghost = ghost, .frames = frames } };
        },
        .love => |*love| love.* = .{ .partner = .{ .position = layout.columnsSigned() } },
        .hole => |*hole| {
            const entry = lap.chomper.position;
            const distance = self.pick(.{
                .low = @max(6, layout.laneSpan(0.18)),
                .high = @max(8, layout.laneSpan(0.4)),
            });
            const exit = @min(layout.columnsSigned() - 3, entry + distance);
            if (exit <= entry + 3) return .ends;
            hole.* = .{ .sink = .{ .entry = entry, .exit = exit } };
        },
        .music => |*music| music.* = .{ .trail = .{ .column = lap.chomper.position } },
        .nap => |*nap| nap.* = .{ .yawn = 0 },
        .slot => |*slot| slot.* = .{ .spin = self.planSlot(layout, lap) },
        .chase, .mirror => {},
    }
    return .walks;
}

fn settleLap(lap: *Lap, step: LapStep) void {
    switch (step) {
        .walks => {},
        .ends => lap.event = null,
    }
}

fn settle(self: *Chomp, board: *Board, lap: *Lap, step: Step) bool {
    switch (step) {
        .walks => return false,
        .waits => return true,
        .ends => {
            lap.event = null;
            return true;
        },
        .clears_level => {
            self.nextLevel(board);
            return true;
        },
        .loses_game => {
            board.phase = .{ .game_over = 0 };
            return true;
        },
    }
}

fn tickEvent(self: *Chomp, board: *Board, lap: *Lap) bool {
    const layout = &board.layout;
    const event = if (lap.event) |*event| event else return false;
    const step = switch (event.*) {
        .hunt => |*hunt| self.tickHunt(layout, lap, hunt),
        .chase => |*chase| self.tickChase(layout, lap, chase),
        .love => |*love| tickLove(layout, lap, love),
        .nap => |*nap| self.tickNap(nap),
        .hole => |*hole| self.tickHole(layout, lap, hole),
        .music => .walks,
        .slot => |*slot| self.tickSlot(slot),
        .mirror => |*mirror| tickMirror(mirror),
    };
    return self.settle(board, lap, step);
}

fn stepCost(lap: *const Lap) u32 {
    const event = if (lap.event) |*event| event else return cost_walk;
    return switch (event.*) {
        .hunt => |*hunt| switch (hunt.*) {
            .power => cost_power,
            .roam, .burst, .recover => cost_walk,
        },
        .chase => |*chase| switch (chase.*) {
            .run => cost_power,
            .wait, .rise, .alert, .stop, .hit, .dead => cost_walk,
        },
        .nap => |*nap| switch (nap.*) {
            .wait => drowsyCost(lap),
            .hurry => cost_fast,
            .yawn, .sleep, .wake => cost_walk,
        },
        .love, .hole, .music, .slot, .mirror => cost_walk,
    };
}

fn drowsyCost(lap: *const Lap) u32 {
    const item = lap.item orelse return cost_walk;
    const distance = item.column - lap.chomper.position;
    if (item.box or distance < 1 or distance > drowsy_cells) return cost_walk;
    return cost_walk + cost_nap_slowdown * @as(u32, @intCast(drowsy_cells + 1 - distance));
}

fn eventBusy(lap: *const Lap) bool {
    const event = if (lap.event) |*event| event else return false;
    return switch (event.*) {
        .hunt => |*hunt| hunt.* == .burst,
        .chase => |*chase| chase.* == .stop,
        .slot => |*slot| switch (slot.*) {
            .win, .lose => true,
            .wait, .spin => false,
        },
        .love, .nap, .hole, .music, .mirror => false,
    };
}

fn planSlot(self: *Chomp, layout: *const Layout, lap: *const Lap) Slot.Spin {
    const outcome = self.random().enumValue(Slot.Outcome);
    const first = self.random().uintLessThan(usize, reel_glyphs.len);
    const other = (first + 1 + self.random().uintLessThan(usize, reel_glyphs.len - 1)) %
        reel_glyphs.len;
    const symbols: [reel_count]usize = switch (outcome) {
        .win => .{ first, first, first },
        .near => .{ first, first, other },
        .miss => .{ first, other, self.random().uintLessThan(usize, reel_glyphs.len) },
    };
    return .{
        .reels = .{
            .start = self.nearestClear(layout, lap.chomper.position - 1, &word_top),
            .shown = .{ 0, 2, 4 },
        },
        .symbols = symbols,
    };
}

fn tickSlot(self: *Chomp, slot: *Slot) Step {
    switch (slot.*) {
        .wait => return .walks,
        .spin => |*spin| {
            spin.reels.frames += 1;
            for (0..reel_count) |reel| {
                if (spin.reels.frames >= spin.stop(reel)) {
                    spin.reels.shown[reel] = spin.symbols[reel];
                } else if (spin.waits[reel] > 0) {
                    spin.waits[reel] -= 1;
                } else {
                    spin.reels.shown[reel] = (spin.reels.shown[reel] + 1) % reel_glyphs.len;
                    spin.waits[reel] = spin.period(reel);
                }
            }
            if (spin.reels.frames < spin.stop(reel_count - 1) + reel_settle_frames) return .waits;
            const reels: Slot.Reels = .{ .start = spin.reels.start, .shown = spin.symbols };
            const won = spin.symbols[0] == spin.symbols[1] and spin.symbols[1] == spin.symbols[2];
            slot.* = if (won) .{ .win = reels } else .{ .lose = reels };
            return .waits;
        },
        .win => |*reels| {
            reels.frames += 1;
            if (reels.frames == win_symbol_frames) self.level +|= 1;
            if (reels.frames >= win_frames + reels_fade_frames) return .ends;
            return if (reels.frames < win_dance_frames) .waits else .walks;
        },
        .lose => |*reels| {
            reels.frames += 1;
            return if (reels.frames >= lose_frames) .ends else .walks;
        },
    }
}

fn enterMirror(lap: *Lap, mirror: *Mirror) LapStep {
    switch (mirror.*) {
        .wait => {
            const item = lap.item orelse return .walks;
            if (item.column != lap.chomper.position + 1) return .walks;
            lap.item = null;
            mirror.* = .{ .face = .{ .column = item.column } };
        },
        .face, .look, .crack => {},
    }
    return .walks;
}

fn tickMirror(mirror: *Mirror) Step {
    switch (mirror.*) {
        .wait => return .walks,
        .face => |*glass| {
            glass.frames += 1;
            if (glass.frames >= face_frames) mirror.* = .{ .look = .{ .column = glass.column } };
            return .waits;
        },
        .look => |*glass| {
            glass.frames += 1;
            if (glass.frames >= look_frames) mirror.* = .{ .crack = .{ .column = glass.column } };
            return .waits;
        },
        .crack => |*glass| {
            glass.frames += 1;
            return if (glass.frames >= crack_frames) .ends else .walks;
        },
    }
}

fn reflectionColumn(lap: *const Lap, mirror: *const Mirror) ?isize {
    return switch (mirror.*) {
        .wait => {
            const item = lap.item orelse return null;
            const distance = item.column - lap.chomper.position;
            if (distance < 1 or distance > mirror_reach) return null;
            return item.column + distance;
        },
        .face, .look, .crack => |*glass| glass.column + 1,
    };
}

fn tickHunt(self: *Chomp, layout: *const Layout, lap: *Lap, hunt: *Hunt) Step {
    switch (hunt.*) {
        .roam => |*roam| {
            const ghost = if (roam.ghost) |*ghost| ghost else return .walks;
            if (ghost.moves(cost_ghost_roam)) {
                const delta: isize = if (self.random().boolean()) 1 else -1;
                ghost.position = std.math.clamp(
                    ghost.position + delta,
                    roam.low,
                    layout.columnsSigned() - 3,
                );
            }
            return .walks;
        },
        .power => |*power| {
            power.frames -|= 1;
            const ghost = &power.ghost;
            if (ghost.moves(cost_ghost_flee))
                ghost.position += if (self.chance(flee_away_chance)) 1 else -1;
            ghost.position = @max(ghost.position, lap.chomper.position + 1);
            const column = ghost.position;
            if (column >= layout.columnsSigned()) return .ends;
            if (column - lap.chomper.position <= 1) {
                lap.hold = catch_hold_frames;
                hunt.* = .{ .burst = .{
                    .column = column,
                    .score_start = self.nearestClear(layout, column - 1, &word_top),
                } };
            } else if (power.frames == 0) hunt.* = .{ .recover = .{ .column = column } };
            return .walks;
        },
        .burst => |*burst| {
            burst.frames += 1;
            return if (burst.frames >= score_fade_frames) .ends else .walks;
        },
        .recover => |*ghost| {
            ghost.frames += 1;
            return if (ghost.frames >= fade_frames) .ends else .walks;
        },
    }
}

fn enterChase(layout: *const Layout, lap: *const Lap, chase: *Chase) LapStep {
    switch (chase.*) {
        .wait => |spot| if (lap.chomper.position >= spot) {
            chase.* = .{ .rise = .{ .column = layout.laneStartSigned() } };
        },
        .rise, .alert, .run, .stop, .hit, .dead => {},
    }
    return .walks;
}

fn planChase(self: *Chomp, layout: *const Layout, lap: *const Lap, ghost: isize) Chase.Run {
    const caught = self.chance(catchChance(&.{
        .previous = self.chase_frames,
        .now = self.game_frames,
    }));
    self.chase_frames = self.game_frames;
    const chomper_position = lap.chomper.position;
    const target = if (caught) target: {
        const room: f64 = @floatFromInt(layout.columnsSigned() - chomper_position);
        const share = 0.4 + 0.45 * self.random().float(f64);
        break :target chomper_position + @as(isize, @intFromFloat(@floor(room * share)));
    } else layout.columnsSigned() + self.pick(.{ .low = 4, .high = 10 });
    return .{
        .outcome = if (caught) .caught else .escape,
        .ghost = ghost,
        .start = ghost,
        .span = @intCast(@max(0, target - 1 - ghost)),
        .duration = @intCast(@max(1, (target - chomper_position) * cost_power)),
    };
}

fn tickChase(self: *Chomp, layout: *const Layout, lap: *const Lap, chase: *Chase) Step {
    switch (chase.*) {
        .wait => return .walks,
        .rise => |*ghost| {
            ghost.frames += 1;
            if (ghost.frames >= rise_frames) {
                const column = ghost.column;
                chase.* = .{ .alert = .{ .column = column } };
            }
            return .waits;
        },
        .alert => |*ghost| {
            ghost.frames += 1;
            if (ghost.frames >= alert_frames) {
                const run = self.planChase(layout, lap, ghost.column);
                chase.* = .{ .run = run };
            }
            return .waits;
        },
        .run => |*run| {
            run.frames += 1;
            const progress = @divFloor(run.frames * credit_per_frame * run.span, run.duration);
            run.ghost = @min(run.start + @as(isize, @intCast(progress)), lap.chomper.position - 1);
            const ghost = run.ghost;
            switch (run.outcome) {
                .caught => if (ghost >= lap.chomper.position - 1) {
                    chase.* = .{ .hit = .{ .column = ghost } };
                    return .waits;
                },
                .escape => {},
            }
            if (lap.inTunnel(layout)) chase.* = .{ .stop = .{
                .column = ghost,
                .word_start = self.nearestClear(layout, ghost - 1, &word_top),
            } };
            return .walks;
        },
        .stop => |*ending| {
            ending.frames += 1;
            return if (ending.frames >= curse_frames + fade_frames) .ends else .walks;
        },
        .hit => |*ghost| {
            ghost.frames += 1;
            if (ghost.frames >= hit_frames) {
                const column = ghost.column;
                chase.* = .{ .dead = .{
                    .column = column,
                    .word_start = self.nearestClear(layout, lap.chomper.position - 1, &word_top),
                } };
            }
            return .waits;
        },
        .dead => |*ending| {
            ending.frames += 1;
            return if (ending.frames >= dead_frames) .loses_game else .waits;
        },
    }
}

fn tickLove(layout: *const Layout, lap: *Lap, love: *Love) Step {
    switch (love.*) {
        .wait => return .walks,
        .partner => |*partner| {
            if (partner.moves(cost_walk)) {
                partner.position -= 1;
                lap.markEaten(layout, partner.position);
            }
            const chomper_position = lap.chomper.position;
            if (partner.position - chomper_position > 1) return .walks;
            const other = @max(partner.position, chomper_position + 1);
            love.* = .{ .meet = .{ .position = chomper_position, .other = other } };
            return .waits;
        },
        .meet => |*meet| {
            meet.frames += 1;
            return if (meet.frames >= meet_frames) .clears_level else .waits;
        },
    }
}

fn enterNap(nap: *Nap) LapStep {
    switch (nap.*) {
        .hurry => |*left| {
            left.* -|= 1;
            if (left.* == 0) return .ends;
        },
        .wait, .yawn, .sleep, .wake => {},
    }
    return .walks;
}

fn tickNap(self: *Chomp, nap: *Nap) Step {
    switch (nap.*) {
        .wait, .hurry => return .walks,
        .yawn => |*frames| {
            frames.* += 1;
            if (frames.* >= yawn_frames) {
                const length = self.random().intRangeAtMost(u32, 220, 440);
                nap.* = .{ .sleep = .{ .length = length } };
            }
        },
        .sleep => |*sleep| {
            sleep.frames += 1;
            if (sleep.frames >= sleep.length) nap.* = .{ .wake = 0 };
        },
        .wake => |*frames| {
            frames.* += 1;
            if (frames.* >= wake_frames)
                nap.* = .{ .hurry = self.random().intRangeAtMost(u32, 16, 32) };
        },
    }
    return .waits;
}

fn tickHole(self: *const Chomp, layout: *const Layout, lap: *Lap, hole: *Hole) Step {
    switch (hole.*) {
        .wait => return .walks,
        .sink => |*fall| {
            fall.frames += 1;
            if (fall.frames >= sink_frames) {
                const crumble: Hole.Crumble = .{
                    .entry = fall.entry,
                    .exit = fall.exit,
                    .wave = fall.entry + 1,
                    .frame_start = self.frame,
                };
                hole.* = .{ .crumble = crumble };
            }
        },
        .crumble => |*crumble| {
            for (0..crumble_cells_per_frame) |_| {
                if (crumble.wave >= crumble.exit) break;
                lap.markEaten(layout, crumble.wave);
                crumble.wave += 1;
            }
            if (crumble.wave >= crumble.exit) {
                const pop: Hole.Pop = .{ .exit = crumble.exit };
                hole.* = .{ .pop = pop };
            }
        },
        .pop => |*fall| {
            fall.frames += 1;
            if (fall.frames >= sink_frames) {
                lap.chomper.position = fall.exit;
                lap.markEaten(layout, fall.exit);
                return .ends;
            }
        },
    }
    return .waits;
}

fn enterMusic(self: *const Chomp, music: *Music, position: isize) LapStep {
    switch (music.*) {
        .wait => {},
        .trail => |*trail| {
            const next: isize = @intCast(trail.count * trail_spacing);
            if (position - 1 >= trail.column + next) {
                trail.born[trail.count % trail_slots] = self.frame;
                trail.count += 1;
            }
        },
    }
    return .walks;
}

fn mouthOpen(self: *const Chomp) bool {
    return @divFloor(self.frame, mouth_frames) % 4 < 2;
}

fn chomperGlyph(self: *const Chomp) []const u8 {
    return if (self.mouthOpen()) glyph_right else glyph_shut;
}

fn alternate(options: *const struct {
    frames: u32,
    period: u32,
    odd: []const u8,
    even: []const u8,
}) []const u8 {
    return if (@divFloor(options.frames, options.period) % 2 == 1) options.odd else options.even;
}

fn chompGlyph(self: *const Chomp, glyph: []const u8, frames: u64) []const u8 {
    return if (@divFloor(self.frame, frames) % 2 == 1) glyph else glyph_shut;
}

fn lookOf(glyph: []const u8) Look {
    return .{ .cell = .{ .glyph = glyph, .role = .chomper } };
}

fn fading(fade: Fade) bool {
    return fade.frames < fade.blink_below and @divFloor(fade.frames, fade_blink_frames) % 2 == 0;
}

fn chomperLook(self: *const Chomp, lap: *const Lap) Look {
    if (lap.pickup) |pickup| {
        if (pickup.frames < spin_frames) return lookOf(glyph_right);
        return lookOf(alternate(&.{
            .frames = pickup.frames - spin_frames,
            .period = 5,
            .odd = glyph_shut,
            .even = glyph_right,
        }));
    }
    const event = if (lap.event) |*event| event else return .default;
    return switch (event.*) {
        .hunt => |*hunt| switch (hunt.*) {
            .power => |*power| .{ .cell = .{
                .glyph = self.chomperGlyph(),
                .role = if (!fading(.{ .frames = power.frames, .blink_below = 60 }) and
                    @divFloor(self.frame, power_flash_frames) % 2 == 1) .text else .chomper,
            } },
            .roam, .burst, .recover => .default,
        },
        .chase => |*chase| chaseChomper(chase),
        .love => |*love| switch (love.*) {
            .meet => |*meet| if (meetCell(meet, lap.chomper.position)) |found|
                .{ .cell = found }
            else
                .hidden,
            .wait, .partner => .default,
        },
        .nap => |*nap| switch (nap.*) {
            .wait => .default,
            .yawn => |frames| lookOf(if (frames < 28) glyph_right else glyph_shut),
            .sleep => lookOf(glyph_shut),
            .wake => |frames| lookOf(if (frames < 12)
                glyph_shut
            else if (@divFloor(frames - 12, 8) % 2 == 0) glyph_left else glyph_right),
            .hurry => lookOf(self.chompGlyph(glyph_right, 2)),
        },
        .hole => |*hole| switch (hole.*) {
            .wait => .default,
            .sink => |*fall| if (fall.frames < 5)
                lookOf(glyph_right)
            else if (fall.frames < 10)
                lookOf(glyph_small)
            else
                .{ .cell = hole_cell },
            .crumble, .pop => .{ .cell = hole_cell },
        },
        .music => .default,
        .slot => |*slot| switch (slot.*) {
            .spin => lookOf(glyph_right),
            .win => |*reels| if (reels.frames < win_dance_frames) lookOf(alternate(&.{
                .frames = reels.frames,
                .period = 6,
                .odd = glyph_left,
                .even = glyph_right,
            })) else .default,
            .wait, .lose => .default,
        },
        .mirror => |*mirror| switch (mirror.*) {
            .face => lookOf(glyph_right),
            .look => |*glass| lookOf(lookGlyph(glass.frames, &.{
                .odd = glyph_left,
                .even = glyph_right,
            })),
            .wait, .crack => .default,
        },
    };
}

fn lookGlyph(frames: u32, faces: *const struct { odd: []const u8, even: []const u8 }) []const u8 {
    return alternate(&.{ .frames = frames, .period = 8, .odd = faces.odd, .even = faces.even });
}

fn paleCell(glyph: []const u8) Cell {
    return .{ .glyph = glyph, .role = .muted };
}

fn mirrorBottom(self: *const Chomp, lap: *const Lap, mirror: *const Mirror, column: isize) ?Cell {
    switch (mirror.*) {
        .face, .look => |*glass| if (column == glass.column) return mirror_cell,
        .crack => |*glass| if (column == glass.column) return paleCell(glyph_spark),
        .wait => {},
    }
    if (reflectionColumn(lap, mirror) != column) return null;
    return switch (mirror.*) {
        .wait => {
            const item = lap.item orelse return null;
            const distance = item.column - lap.chomper.position;
            if (distance > mirror_reach - 2) return paleCell(glyph_spark);
            if (distance > mirror_reach - 4) return paleCell(glyph_dot);
            return paleCell(if (self.mouthOpen()) glyph_left else glyph_shut);
        },
        .face => paleCell(glyph_left),
        .look => |*glass| paleCell(lookGlyph(glass.frames, &.{
            .odd = glyph_right,
            .even = glyph_left,
        })),
        .crack => |*glass| paleCell(if (glass.frames < 8) glyph_dot else glyph_spark),
    };
}

fn winCell(reels: *const Slot.Reels, column: isize) ?Cell {
    const frames = reels.frames;
    if (frames < win_symbol_frames) return reelCell(reels, column, winBlink(frames));
    return wordCell(&.{
        .text = jackpot_text,
        .start = reels.start,
        .role = if (frames < win_frames) .score else .score_fading,
    }, column);
}

fn winBlink(frames: u32) role.Name {
    return if (@divFloor(frames, win_blink_frames) % 2 == 0) .score else .text;
}

fn reelCell(reels: *const Slot.Reels, column: isize, reel_role: role.Name) ?Cell {
    const start = reels.start orelse return null;
    if (column < start or column >= start + reel_count) return null;
    const index: usize = @intCast(column - start);
    return .{ .glyph = reel_glyphs[reels.shown[index]], .role = reel_role };
}

fn chaseChomper(chase: *const Chase) Look {
    return switch (chase.*) {
        .wait, .run, .stop => .default,
        .rise => lookOf(glyph_shut),
        .alert => |*ghost| lookOf(if (ghost.frames < 6) glyph_right else glyph_left),
        .hit => |*ghost| lookOf(alternate(&.{
            .frames = ghost.frames,
            .period = 4,
            .odd = glyph_left,
            .even = glyph_right,
        })),
        .dead => |*ending| if (ending.frames < 12)
            lookOf(glyph_shut)
        else if (ending.frames < 24)
            lookOf(glyph_small)
        else if (ending.frames < 36)
            lookOf(glyph_dot)
        else if (ending.frames < grave_frames)
            lookOf(glyph_spark)
        else
            .{ .cell = grave_cell },
    };
}

fn fadeCell(frames: u32) ?Cell {
    if (frames < 16) return ghost_cell;
    if (frames < 28) return .{ .glyph = glyph_dot, .role = .muted };
    if (frames < fade_frames) return .{ .glyph = glyph_spark, .role = .muted };
    return null;
}

fn scaredCell(fade: Fade) Cell {
    return .{
        .glyph = glyph_ghost,
        .role = if (fade.frames < fade.blink_below and @divFloor(fade.frames, 8) % 2 == 1)
            .text
        else
            .ghost_scared,
    };
}

fn pelletCell(self: *const Chomp) Cell {
    return if (self.frame % 16 < 8) pellet_cell else pellet_small_cell;
}

fn eventBottom(self: *const Chomp, lap: *const Lap, column: isize) ?Cell {
    const event = if (lap.event) |*event| event else return null;
    switch (event.*) {
        .hunt => |*hunt| switch (hunt.*) {
            .roam => |*roam| if (roam.ghost) |ghost| {
                if (ghost.position == column) return ghost_cell;
            },
            .power => |*power| if (power.ghost.position == column)
                return scaredCell(.{ .frames = power.frames, .blink_below = 60 }),
            .burst => |*burst| if (burst.column == column) return burstCell(burst.frames),
            .recover => |*ghost| if (ghost.column == column) return fadeCell(ghost.frames),
        },
        .chase => |*chase| return chaseBottom(chase, column),
        .love => |*love| switch (love.*) {
            .partner => |*partner| if (partner.position == column) return .{
                .glyph = if (self.mouthOpen()) glyph_left else glyph_shut,
                .role = .text,
            },
            .meet => |*meet| return meetCell(meet, column),
            .wait => {},
        },
        .nap => |*nap| switch (nap.*) {
            .sleep => |*sleep| if (column == lap.chomper.position + 1 and
                sleep.frames % sleep_cycle_frames < 32)
                return .{ .glyph = glyph_sleep, .role = .text },
            .wait, .yawn, .wake, .hurry => {},
        },
        .hole => |*hole| switch (hole.*) {
            .crumble => |*crumble| {
                if (column == crumble.exit) return hole_cell;
                return self.crumbleCell(crumble, column);
            },
            .pop => |*fall| if (column == fall.exit) return .{
                .glyph = if (fall.frames < 5)
                    glyph_small
                else if (fall.frames < 10) glyph_shut else self.chomperGlyph(),
                .role = .chomper,
            },
            .wait, .sink => {},
        },
        .music => |*music| switch (music.*) {
            .trail => |*trail| return self.trailCell(trail, column),
            .wait => {},
        },
        .mirror => |*mirror| return self.mirrorBottom(lap, mirror, column),
        .slot => {},
    }
    return null;
}

fn burstCell(frames: u32) ?Cell {
    if (frames < 12) return .{
        .glyph = glyph_ghost,
        .role = if (@divFloor(frames, 3) % 2 == 0) .text else .ghost_scared,
    };
    if (frames < 20) return .{ .glyph = glyph_dot, .role = .text };
    if (frames < catch_hold_frames) return .{ .glyph = glyph_spark, .role = .muted };
    return null;
}

fn trailCell(self: *const Chomp, trail: *const Music.Trail, column: isize) ?Cell {
    const offset = column - trail.column;
    if (offset < 0 or @mod(offset, trail_spacing) != 0) return null;
    const index: usize = @intCast(@divExact(offset, trail_spacing));
    if (index >= trail.count or trail.count - index > trail_slots) return null;
    const age = self.frame -% trail.born[index % trail_slots];
    if (age >= note_fade_frames) return null;
    return .{
        .glyph = if (index % 2 == 1) glyph_notes else glyph_note,
        .role = if (age < note_bright_frames) .text else .muted,
    };
}

fn chaseBottom(chase: *const Chase, column: isize) ?Cell {
    switch (chase.*) {
        .wait => {},
        .rise => |*ghost| if (ghost.column == column) {
            if (ghost.frames < 8) return .{ .glyph = glyph_spark, .role = .muted };
            if (ghost.frames < 16) return .{ .glyph = glyph_dot, .role = .muted };
            return ghost_cell;
        },
        .alert, .hit => |*ghost| if (ghost.column == column) return ghost_cell,
        .run => |*run| if (run.ghost == column) return ghost_cell,
        .stop => |*ending| if (ending.column == column)
            return fadeCell(ending.frames -| curse_frames),
        .dead => |*ending| if (ending.column == column) return fadeCell(ending.frames),
    }
    return null;
}

fn crumbleCell(self: *const Chomp, crumble: *const Hole.Crumble, column: isize) ?Cell {
    if (column <= crumble.entry or column >= crumble.wave) return null;
    const offset: u64 = @intCast(@divFloor(column - crumble.entry - 1, crumble_cells_per_frame));
    if (self.frame -| (crumble.frame_start + offset) >= crumble_dot_frames) return null;
    return .{ .glyph = glyph_dot, .role = .muted };
}

fn eventTop(lap: *const Lap, column: isize) ?Cell {
    const event = if (lap.event) |*event| event else return null;
    const chomper_position = lap.chomper.position;
    switch (event.*) {
        .chase => |*chase| switch (chase.*) {
            .alert => if (column == chomper_position) return .{ .glyph = "!", .role = .chomper },
            .stop => |*ending| if (ending.frames < curse_frames) return wordCell(&.{
                .text = curse_texts[@divFloor(ending.frames, curse_swap_frames) % curse_texts.len],
                .start = ending.word_start,
                .role = .ghost,
            }, column),
            .dead => |*ending| if (ending.frames >= rip_frames) return wordCell(&.{
                .text = rip_text,
                .start = ending.word_start,
                .role = .text,
            }, column),
            .wait, .rise, .run, .hit => {},
        },
        .nap => |*nap| switch (nap.*) {
            .yawn => if (column == chomper_position) return moon_cell,
            .sleep => |*sleep| {
                if (column == chomper_position) return moon_cell;
                const phase = sleep.frames % sleep_cycle_frames;
                if (column == chomper_position + 2 and phase >= 24 and phase < 60)
                    return .{ .glyph = "z", .role = .text };
                if (column == chomper_position + 3 and phase >= 48 and phase < 88)
                    return .{ .glyph = "Z", .role = .text };
            },
            .wake => |frames| if (column == chomper_position and frames < 28)
                return .{ .glyph = "!", .role = .chomper },
            .wait, .hurry => {},
        },
        .hunt => |*hunt| switch (hunt.*) {
            .burst => |*burst| return wordCell(&.{
                .text = score_text,
                .start = burst.score_start,
                .role = if (burst.frames < score_bright_frames) .score else .score_fading,
            }, column),
            .roam, .power, .recover => {},
        },
        .love, .hole, .music => {},
        .slot => |*slot| switch (slot.*) {
            .wait => {},
            .spin => |*spin| return reelCell(&spin.reels, column, .text),
            .win => |*reels| return winCell(reels, column),
            .lose => |*reels| return reelCell(reels, column, .muted),
        },
        .mirror => |*mirror| switch (mirror.*) {
            .face => |*glass| if (glass.frames < 28) {
                if (column == glass.column - 1) return .{ .glyph = "!", .role = .chomper };
                if (column == glass.column + 1) return paleCell("!");
            },
            .wait, .look, .crack => {},
        },
    }
    return null;
}

fn wordCell(word: *const Word, column: isize) ?Cell {
    const start = word.start orelse return null;
    if (column < start or column >= start + word_columns) return null;
    const index: usize = @intCast(column - start);
    return .{ .glyph = word.text[index..][0..1], .role = word.role };
}

fn meetCell(meet: *const Love.Meet, column: isize) ?Cell {
    const frames = meet.frames;
    if (frames < 18) {
        if (column == meet.position) return .{ .glyph = glyph_shut, .role = .chomper };
        if (column == meet.other) return .{ .glyph = glyph_shut, .role = .text };
        return null;
    }
    if (frames < 95) {
        if (column == meet.position) return .{
            .glyph = glyph_heart,
            .role = if (@divFloor(frames, 12) % 2 == 1) .love else .text,
        };
        if (column + 2 == meet.position or column == meet.position + 2) return .{
            .glyph = if (@divFloor(frames, 8) % 2 == 1) glyph_spark else glyph_dot,
            .role = .text,
        };
        return null;
    }
    if (column != meet.position) return null;
    return .{ .glyph = if (frames < 108) glyph_heart_hollow else glyph_dot, .role = .text };
}

fn itemGlyph(kind: ItemKind) []const u8 {
    return switch (kind) {
        .pellet => glyph_shut,
        .heart => glyph_heart,
        .hole => glyph_hole,
        .note => glyph_note,
        .moon => glyph_moon,
        .coin => glyph_coin,
        .mirror => glyph_mirror,
    };
}

fn itemCell(self: *const Chomp, item: Item) Cell {
    if (item.box) return .{ .glyph = "?", .role = .text };
    return switch (item.kind) {
        .pellet => self.pelletCell(),
        .heart, .hole, .note, .moon, .coin, .mirror => .{
            .glyph = itemGlyph(item.kind),
            .role = .text,
        },
    };
}

fn digitCount(value: u32) usize {
    var count: usize = 1;
    var rest = value;
    while (rest >= 10) : (count += 1) rest = @divFloor(rest, 10);
    return count;
}

fn digitGlyph(value: u32, index: usize) []const u8 {
    var rest = value;
    for (0..digitCount(value) - 1 - index) |_| rest = @divFloor(rest, 10);
    const digit: usize = rest % 10;
    return digits[digit..][0..1];
}

fn blinking(frames: u32) bool {
    return frames >= flash_blink_start and
        @divFloor(frames - flash_blink_start, 8) % 2 == 0;
}

fn levelLabelColumns(level: u32) usize {
    return level_prefix.len + digitCount(level) + 1;
}

fn labelSpan(self: *const Chomp, board: *const Board) ?Span {
    return board.layout.titleSpan(switch (board.phase) {
        .game_over => game_over_text.len,
        .lap, .flash => levelLabelColumns(self.level),
    });
}

fn labelCell(self: *const Chomp, board: *const Board, column: usize) ?Cell {
    const span = self.labelSpan(board) orelse return null;
    if (column < span.start or column >= span.end) return null;
    var index = column - span.start;
    const level_role: role.Name = switch (board.phase) {
        .game_over => |frames| {
            const shown = frames > flash_blink_start and @divFloor(frames, 10) % 2 == 0;
            return .{
                .glyph = game_over_text[index..][0..1],
                .role = if (shown) .text else .ghost,
            };
        },
        .flash => |frames| if (blinking(frames)) .text else .chomper,
        .lap => |*lap| lap.jackpotRole() orelse .chomper,
    };
    if (index < level_prefix.len)
        return .{ .glyph = level_prefix[index..][0..1], .role = level_role };
    index -= level_prefix.len;
    if (index < digitCount(self.level))
        return .{ .glyph = digitGlyph(self.level, index), .role = level_role };
    return .{ .glyph = " ", .role = level_role };
}

fn centered(options: *const struct { width: usize, left: usize, columns: usize }) ?Span {
    if (options.columns < options.width) return null;
    const start = @divFloor(options.columns - options.width, 2);
    const end = start + options.width;
    if (start < options.left + line_cells_min) return null;
    if (options.columns - end < line_cells_min) return null;
    return .{ .start = start, .end = end };
}

fn topCell(self: *const Chomp, board: *const Board, column: usize) Cell {
    if (self.labelCell(board, column)) |found| return found;
    const lap = switch (board.phase) {
        .lap => |*lap| lap,
        .flash, .game_over => return frame_cell,
    };
    const position: isize = @intCast(column);
    if (!self.topFree(&board.layout, position)) return frame_cell;
    return topProjection(lap, position) orelse frame_cell;
}

fn topProjection(lap: *const Lap, position: isize) ?Cell {
    if (lap.pickup) |pickup| {
        if (position == lap.chomper.position) {
            if (pickup.frames < spin_frames) return .{
                .glyph = itemGlyph(box_kinds[@divFloor(pickup.frames, 4) % box_kinds.len]),
                .role = .text,
            };
            if (@divFloor(pickup.frames - spin_frames, 6) % 2 == 1) return null;
            return .{ .glyph = itemGlyph(pickup.kind), .role = .text };
        }
    }
    return eventTop(lap, position);
}

fn bottomCell(self: *const Chomp, board: *const Board, column: usize) Cell {
    const layout = &board.layout;
    if (column < layout.laneStart()) return frame_cell;
    const lap = switch (board.phase) {
        .lap => |*lap| lap,
        .flash, .game_over => |frames| return regrowCell(layout, column, frames),
    };
    const position: isize = @intCast(column);
    if (position == lap.chomper.position) switch (self.chomperLook(lap)) {
        .default => return .{ .glyph = self.chomperGlyph(), .role = .chomper },
        .cell => |found| return found,
        .hidden => {},
    };
    if (self.eventBottom(lap, position)) |found| return found;
    if (lap.item) |item| {
        if (item.column == position) return self.itemCell(item);
    }
    if (lap.eaten.isSet(column)) return blank_cell;
    return frame_cell;
}

fn regrowCell(layout: *const Layout, column: usize, frames: u32) Cell {
    const grown_frames: usize = @min(frames, flash_blink_start);
    const regrown = @divFloor(grown_frames * layout.laneColumns(), flash_blink_start);
    if (column >= layout.laneStart() + regrown) return blank_cell;
    return if (blinking(frames)) .{ .glyph = "─", .role = .text } else frame_cell;
}

test "the chomper starts at once and eats one cell every two frames" {
    var chomp: Chomp = .init(1);
    chomp.fit(&.{ .columns = 80 });
    for (0..2) |_| chomp.advance();
    try std.testing.expectEqual(@as(?usize, 0), chomperColumn(&chomp, 80));
    for (0..2) |_| chomp.advance();
    try std.testing.expectEqualStrings(" ", chomp.cell(.bottom, 0).glyph);
    try std.testing.expectEqual(@as(?usize, 1), chomperColumn(&chomp, 80));
}

fn chomperColumn(chomp: *const Chomp, columns: usize) ?usize {
    for (0..columns) |column| {
        if (chomp.cell(.bottom, column).role == .chomper) return column;
    }
    return null;
}

fn glyphColumn(chomp: *const Chomp, options: *const struct {
    edge: Edge,
    columns: usize,
    glyph: []const u8,
}) ?usize {
    for (0..options.columns) |column| {
        if (std.mem.eql(u8, chomp.cell(options.edge, column).glyph, options.glyph)) return column;
    }
    return null;
}

fn edgeShows(chomp: *const Chomp, options: *const struct {
    edge: Edge,
    columns: usize,
    text: []const u8,
}) bool {
    var buffer: [columns_max * 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (0..options.columns) |column|
        writer.writeAll(chomp.cell(options.edge, column).glyph) catch unreachable;
    return std.mem.find(u8, writer.buffered(), options.text) != null;
}

const LapItem = struct { kind: ItemKind, box: bool };

const item_glyphs = [_]struct { kind: ItemKind, glyph: []const u8 }{
    .{ .kind = .pellet, .glyph = glyph_shut },
    .{ .kind = .pellet, .glyph = glyph_small },
    .{ .kind = .heart, .glyph = glyph_heart },
    .{ .kind = .moon, .glyph = glyph_moon },
    .{ .kind = .hole, .glyph = glyph_hole },
    .{ .kind = .note, .glyph = glyph_note },
    .{ .kind = .coin, .glyph = glyph_coin },
    .{ .kind = .mirror, .glyph = glyph_mirror },
};

fn shownKind(glyph: []const u8) ?ItemKind {
    for (item_glyphs) |entry| {
        if (std.mem.eql(u8, entry.glyph, glyph)) return entry.kind;
    }
    return null;
}

fn lapItem(chomp: *Chomp, columns: usize) !?LapItem {
    for (0..columns) |column| {
        const glyph = chomp.cell(.bottom, column).glyph;
        if (std.mem.eql(u8, glyph, "?"))
            return .{ .kind = try boxKind(chomp, column), .box = true };
        if (shownKind(glyph)) |kind| return .{ .kind = kind, .box = false };
    }
    return null;
}

fn boxKind(chomp: *Chomp, column: usize) !ItemKind {
    for (0..1000) |_| {
        chomp.advance();
        if (std.mem.eql(u8, chomp.cell(.top, column).glyph, frame_cell.glyph)) continue;
        for (0..spin_frames) |_| chomp.advance();
        return shownKind(chomp.cell(.top, column).glyph) orelse error.TestExpectedRevealedItem;
    }
    return error.TestExpectedRevealedItem;
}

fn repeats(maybe_previous: ?LapItem, maybe_next: ?LapItem) bool {
    const previous = maybe_previous orelse return maybe_next == null;
    const next = maybe_next orelse return false;
    return previous.kind == next.kind or (previous.box and next.box);
}

test "a hidden label keeps the line cell behind it, and the chomper starts after that cell" {
    var chomp: Chomp = .init(1);
    chomp.fit(&.{ .columns = 60, .bottom_label_end = 7 });
    for (0..2) |_| chomp.advance();
    for (0..8) |column| try std.testing.expectEqualStrings("─", chomp.cell(.bottom, column).glyph);
    const start = chomp.cell(.bottom, 8);
    try std.testing.expectEqualStrings(glyph_right, start.glyph);
    try std.testing.expectEqual(role.Name.chomper, start.role);
}

test "a new hidden label keeps the eaten cells and the place of the chomper" {
    var chomp: Chomp = .init(1);
    chomp.fit(&.{ .columns = 80 });
    for (0..4000) |_| {
        chomp.advance();
        if (chomperColumn(&chomp, 80) == 12) break;
    } else return error.TestExpectedChomper;
    var lane: [30]Cell = undefined;
    for (&lane, 0..) |*slot, column| slot.* = chomp.cell(.bottom, column);
    try std.testing.expectEqualStrings(" ", lane[8].glyph);
    chomp.fit(&.{ .columns = 80, .bottom_label_end = 7 });
    for (lane[8..], 8..) |wanted, column| {
        const shown = chomp.cell(.bottom, column);
        try std.testing.expectEqualStrings(wanted.glyph, shown.glyph);
        try std.testing.expectEqual(wanted.role, shown.role);
    }
}

test "every lap starts an event unlike the last, and a box never follows a box or hides a mirror" {
    var chomp: Chomp = .init(7);
    var items: [2400]?LapItem = undefined;
    for (&items, 0..) |*slot, lap| {
        const columns = 80 + lap % 2;
        chomp.fit(&.{ .columns = columns });
        slot.* = try lapItem(&chomp, columns);
    }
    for (items[0 .. items.len - 1], items[1..]) |previous, next| {
        try std.testing.expect(!repeats(previous, next));
    }
    var counts: std.EnumArray(ItemKind, usize) = .initFill(0);
    var chases: usize = 0;
    var boxes: usize = 0;
    for (items) |maybe_item| {
        const item = maybe_item orelse {
            chases += 1;
            continue;
        };
        counts.getPtr(item.kind).* += 1;
        boxes += @intFromBool(item.box);
        if (item.box) try std.testing.expect(item.kind != .mirror);
    }
    try std.testing.expectEqual(@as(usize, 300), chases);
    for (std.enums.values(ItemKind)) |kind| {
        try std.testing.expectEqual(@as(usize, 300), counts.get(kind));
    }
    try std.testing.expect(boxes > 150 and boxes < 350);
}

test "each event keeps its animation on the top edge clear of both labels" {
    const layouts = [_]Layout{
        .{ .columns = 50 },
        .{ .columns = 80 },
        .{ .columns = 83, .top_label_end = 7, .bottom_label_end = 7 },
        .{ .columns = 178 },
    };
    var event_cells: usize = 0;
    for (layouts) |layout| {
        for (0..3) |seed| {
            var chomp: Chomp = .init(seed);
            chomp.fit(&layout);
            for (0..12_000) |frame| {
                chomp.advance();
                if (frame % 5 == 0) event_cells += try expectTopClear(&chomp, &layout, .placed);
            }
        }
    }
    try std.testing.expect(event_cells > 0);
}

test "a top label that appears during a lap gets no animation under it or next to it" {
    const layout: Layout = .{ .columns = 80, .top_label_end = 14 };
    for (0..32) |seed| {
        var chomp: Chomp = .init(seed);
        chomp.fit(&.{ .columns = layout.columns });
        chomp.fit(&layout);
        for (0..1500) |frame| {
            chomp.advance();
            if (frame % 3 == 0) _ = try expectTopClear(&chomp, &layout, .shown);
        }
    }
}

const TopSource = enum { shown, placed };

fn expectTopClear(chomp: *const Chomp, layout: *const Layout, source: TopSource) !usize {
    var glyphs: [columns_max][]const u8 = undefined;
    const edge = glyphs[0..layout.columns];
    for (edge, 0..) |*glyph, column| glyph.* = chomp.cell(.top, column).glyph;
    const label = levelLabel(edge) orelse return 0;
    switch (source) {
        .shown => {},
        .placed => {
            const board = if (chomp.maybe_board) |*board| board else return 0;
            const lap = switch (board.phase) {
                .lap => |*lap| lap,
                .flash, .game_over => return 0,
            };
            for (edge, 0..) |*glyph, column| {
                if (column >= label.start and column < label.end) continue;
                const found = topProjection(lap, @intCast(column)) orelse frame_cell;
                glyph.* = found.glyph;
            }
        },
    }
    var count: usize = 0;
    for (edge, 0..) |glyph, column| {
        if (column >= label.start and column < label.end) continue;
        if (std.mem.eql(u8, glyph, frame_cell.glyph)) continue;
        try std.testing.expect(column + 1 < label.start or column > label.end);
        if (layout.top_label_end) |end| try std.testing.expect(column > end);
        count += 1;
    }
    return count;
}

fn levelLabel(edge: []const []const u8) ?Span {
    for (0..edge.len) |start| {
        if (!spells(edge[start..], level_prefix)) continue;
        var end = start + level_prefix.len;
        while (end < edge.len and std.ascii.isDigit(edge[end][0])) end += 1;
        return .{ .start = start, .end = end + 1 };
    }
    return null;
}

fn spells(glyphs: []const []const u8, text: []const u8) bool {
    if (glyphs.len < text.len) return false;
    for (glyphs[0..text.len], text) |glyph, byte| {
        if (!std.mem.eql(u8, glyph, &[_]u8{byte})) return false;
    }
    return true;
}

test "a moon puts the chomper to sleep on its cell below the moon, and the letters rise right" {
    var lap = try lapWith(glyph_moon);
    const chomp = &lap.chomp;
    var letters: [2]?usize = .{ null, null };
    for (0..4000) |_| {
        chomp.advance();
        if (glyphColumn(chomp, &.{ .edge = .top, .columns = 80, .glyph = "z" })) |column| {
            try std.testing.expectEqual(@as(?usize, lap.column), chomperColumn(chomp, 80));
            try std.testing.expectEqualStrings(glyph_moon, chomp.cell(.top, lap.column).glyph);
            letters[0] = column;
        }
        if (glyphColumn(chomp, &.{ .edge = .top, .columns = 80, .glyph = "Z" })) |column|
            letters[1] = column;
        if (letters[0] != null and letters[1] != null) break;
    }
    try std.testing.expectEqual(@as(?usize, lap.column + 2), letters[0]);
    try std.testing.expectEqual(@as(?usize, lap.column + 3), letters[1]);
}

test "a note leaves a fading note in every second cell behind the chomper" {
    var lap = try lapWith(glyph_note);
    const chomp = &lap.chomp;
    for (0..4000) |_| {
        chomp.advance();
        if (chomperColumn(chomp, 80) == lap.column + 6) break;
    } else return error.TestExpectedChomper;
    const notes = [_][]const u8{ glyph_note, " ", glyph_notes, " ", glyph_note, " " };
    for (notes, lap.column..) |glyph, column|
        try std.testing.expectEqualStrings(glyph, chomp.cell(.bottom, column).glyph);
    for (0..note_fade_frames) |_| chomp.advance();
    for (lap.column..lap.column + notes.len) |column|
        try std.testing.expectEqualStrings(" ", chomp.cell(.bottom, column).glyph);
}

test "a note trail reaches the right end of the bottom edge" {
    var lap = try lapWith(glyph_note);
    const chomp = &lap.chomp;
    for (0..4000) |_| {
        chomp.advance();
        if (chomperColumn(chomp, 80) == 79) break;
    } else return error.TestExpectedChomper;
    const last_notes = [_][]const u8{
        chomp.cell(.bottom, 77).glyph,
        chomp.cell(.bottom, 78).glyph,
    };
    const found = for (last_notes) |glyph| {
        if (std.mem.eql(u8, glyph, glyph_note) or std.mem.eql(u8, glyph, glyph_notes))
            break true;
    } else false;
    try std.testing.expect(found);
}

test "an eaten item blinks above the waiting chomper, but a hole without a box shows nothing" {
    for ([_][]const u8{ glyph_shut, glyph_heart, glyph_note, glyph_moon, glyph_coin }) |glyph| {
        var lap = try lapWith(glyph);
        const chomp = &lap.chomp;
        for (0..4000) |_| {
            chomp.advance();
            if (!std.mem.eql(u8, chomp.cell(.top, lap.column).glyph, frame_cell.glyph)) break;
        } else return error.TestExpectedPickup;
        var blinks = false;
        for (0..pickup_frames - 1) |_| {
            const shown = chomp.cell(.top, lap.column).glyph;
            if (std.mem.eql(u8, shown, frame_cell.glyph))
                blinks = true
            else
                try std.testing.expectEqualStrings(glyph, shown);
            const ahead = chomp.cell(.bottom, lap.column + 1).glyph;
            try std.testing.expectEqualStrings(frame_cell.glyph, ahead);
            chomp.advance();
        }
        try std.testing.expect(blinks);
    }
    var lap = try lapWith(glyph_hole);
    const chomp = &lap.chomp;
    for (0..4000) |_| {
        chomp.advance();
        if (chomperColumn(chomp, 80) == lap.column) break;
    } else return error.TestExpectedChomper;
    for (0..pickup_frames) |_| {
        const shown = chomp.cell(.top, lap.column).glyph;
        try std.testing.expectEqualStrings(frame_cell.glyph, shown);
        chomp.advance();
    }
}

test "the chomper waits on the coin, and only equal reels blink with the level and show 1UP" {
    var chomp: Chomp = .init(11);
    var wins: usize = 0;
    var losses: usize = 0;
    for (0..2000) |lap| {
        if (wins > 0 and losses > 0) break;
        const columns = 80 + lap % 2;
        chomp.fit(&.{ .columns = columns });
        const coin = glyphColumn(&chomp, &.{
            .edge = .bottom,
            .columns = columns,
            .glyph = glyph_coin,
        }) orelse continue;
        const reels = for (0..1000) |_| {
            chomp.advance();
            const slot = slotEvent(&chomp) orelse return error.TestExpectedSlot;
            switch (slot.*) {
                .wait => {},
                .spin => {
                    const column = chomperColumn(&chomp, columns);
                    try std.testing.expectEqual(@as(?usize, coin), column);
                },
                .win, .lose => |*reels| break reels,
            }
        } else return error.TestExpectedReels;
        const start: usize = @intCast(reels.start orelse return error.TestExpectedReels);
        const shown = [_][]const u8{
            chomp.cell(.top, start).glyph,
            chomp.cell(.top, start + 1).glyph,
            chomp.cell(.top, start + 2).glyph,
        };
        const equal = std.mem.eql(u8, shown[0], shown[1]) and std.mem.eql(u8, shown[1], shown[2]);
        const level = chomp.level;
        var jackpot = false;
        var blinks: usize = 0;
        for (0..win_frames - 1) |_| {
            chomp.advance();
            const label = glyphColumn(&chomp, &.{
                .edge = .top,
                .columns = columns,
                .glyph = "L",
            }) orelse return error.TestExpectedLabel;
            const label_role = chomp.cell(.top, label).role;
            if (!edgeShows(&chomp, &.{ .edge = .top, .columns = columns, .text = jackpot_text })) {
                if (equal) try std.testing.expectEqual(chomp.cell(.top, start).role, label_role);
                blinks += @intFromBool(label_role == .text);
                continue;
            }
            jackpot = true;
            try expectLevelLabel(&chomp, &.{ .columns = columns, .level = level + 1 });
            try std.testing.expectEqual(role.Name.score, label_role);
        }
        try std.testing.expectEqual(equal, blinks > 0);
        try std.testing.expectEqual(equal, jackpot);
        const cleared = level + @intFromBool(equal) + 1;
        for (0..4000) |_| {
            chomp.advance();
            if (chomp.maybe_board.?.phase == .flash) break;
        } else return error.TestExpectedFlash;
        try expectLevelLabel(&chomp, &.{ .columns = columns, .level = cleared });
        wins += @intFromBool(equal);
        losses += @intFromBool(!equal);
    }
    try std.testing.expect(wins > 0 and losses > 0);
}

fn expectLevelLabel(chomp: *const Chomp, options: *const struct {
    columns: usize,
    level: u32,
}) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "─ Level {d} ─", .{options.level});
    try std.testing.expect(edgeShows(chomp, &.{
        .edge = .top,
        .columns = options.columns,
        .text = text,
    }));
}

test "the top edge keeps a gap to the wider label that a jackpot at level 9 brings" {
    var chomp: Chomp = .init(1);
    chomp.level = 9;
    const layout: Layout = .{ .columns = 51 };
    try std.testing.expect(chomp.topFree(&layout, 18));
    try std.testing.expect(!chomp.topFree(&layout, 19));
    try std.testing.expect(chomp.topFree(&layout, 31));
}

fn slotEvent(chomp: *const Chomp) ?*const Slot {
    const event = lapEvent(chomp) orelse return null;
    return switch (event.*) {
        .slot => |*slot| slot,
        .hunt, .chase, .love, .nap, .hole, .music, .mirror => null,
    };
}

fn lapEvent(chomp: *const Chomp) ?*const Event {
    const board = if (chomp.maybe_board) |*board| board else return null;
    const lap = switch (board.phase) {
        .lap => |*lap| lap,
        .flash, .game_over => return null,
    };
    return if (lap.event) |*event| event else null;
}

test "a pale reflection meets the chomper at the mirror, and the chomper then breaks the mirror" {
    var lap = try lapWith(glyph_mirror);
    const chomp = &lap.chomp;
    const mirror = lap.column;
    for (0..4000) |_| {
        chomp.advance();
        if (chomperColumn(chomp, 80) == mirror - 4) break;
    } else return error.TestExpectedChomper;
    const reflection = chomp.cell(.bottom, mirror + 4);
    try std.testing.expectEqual(role.Name.muted, reflection.role);
    try std.testing.expect(std.mem.eql(u8, reflection.glyph, glyph_left) or
        std.mem.eql(u8, reflection.glyph, glyph_shut));
    for (0..4000) |_| {
        chomp.advance();
        if (std.mem.eql(u8, chomp.cell(.top, mirror - 1).glyph, "!")) break;
    } else return error.TestExpectedAlert;
    try std.testing.expectEqual(@as(?usize, mirror - 1), chomperColumn(chomp, 80));
    try std.testing.expectEqualStrings(glyph_mirror, chomp.cell(.bottom, mirror).glyph);
    try std.testing.expectEqualStrings(glyph_left, chomp.cell(.bottom, mirror + 1).glyph);
    try std.testing.expectEqual(role.Name.muted, chomp.cell(.bottom, mirror + 1).role);
    try std.testing.expectEqualStrings("!", chomp.cell(.top, mirror + 1).glyph);
    for (0..4000) |_| {
        chomp.advance();
        if (chomperColumn(chomp, 80) == mirror + 10) break;
    } else return error.TestExpectedChomper;
    for (mirror..mirror + 10) |column|
        try std.testing.expectEqualStrings(" ", chomp.cell(.bottom, column).glyph);
}

test "an eaten ghost shows the score on the top edge" {
    var lap = try lapWith(glyph_shut);
    const shown = for (0..2000) |_| {
        lap.chomp.advance();
        if (edgeShows(&lap.chomp, &.{ .edge = .top, .columns = 80, .text = score_text }))
            break true;
    } else false;
    try std.testing.expect(shown);
}

test "a ghost that misses the chomper curses above itself before it fades" {
    var chomp = try chaseLap();
    const stopped = for (0..4000) |_| {
        chomp.advance();
        if (chaseStage(&chomp) == .stop) break true;
    } else false;
    try std.testing.expect(stopped);
    const ghost = glyphColumn(&chomp, &.{
        .edge = .bottom,
        .columns = 80,
        .glyph = glyph_ghost,
    }) orelse return error.TestExpectedGhost;
    const curse = glyphColumn(&chomp, &.{
        .edge = .top,
        .columns = 80,
        .glyph = "#",
    }) orelse return error.TestExpectedCurse;
    try std.testing.expect(edgeShows(&chomp, &.{ .edge = .top, .columns = 80, .text = "#@!" }));
    try std.testing.expect(ghost >= curse and ghost < curse + word_columns);
    for (0..curse_frames - 1) |_| chomp.advance();
    try std.testing.expectEqualStrings(glyph_ghost, chomp.cell(.bottom, ghost).glyph);
    try std.testing.expect(edgeShows(&chomp, &.{ .edge = .top, .columns = 80, .text = "@" }));
    chomp.advance();
    try std.testing.expectEqual(@as(?std.meta.Tag(Chase), .stop), chaseStage(&chomp));
    try std.testing.expect(!edgeShows(&chomp, &.{ .edge = .top, .columns = 80, .text = "@" }));
}

test "a caught chomper leaves a grave under RIP on the top edge" {
    var chomp: Chomp = .init(0);
    chomp.fit(&.{ .columns = 80 });
    const caught = for (0..1_000_000) |_| {
        chomp.advance();
        if (chaseStage(&chomp) == .dead) break true;
    } else false;
    try std.testing.expect(caught);
    for (0..rip_frames) |_| chomp.advance();
    const grave = glyphColumn(&chomp, &.{
        .edge = .bottom,
        .columns = 80,
        .glyph = glyph_grave,
    }) orelse return error.TestExpectedGrave;
    const rip = glyphColumn(&chomp, &.{
        .edge = .top,
        .columns = 80,
        .glyph = "R",
    }) orelse return error.TestExpectedRip;
    try std.testing.expect(edgeShows(&chomp, &.{ .edge = .top, .columns = 80, .text = rip_text }));
    try std.testing.expect(grave >= rip and grave < rip + word_columns);
}

fn chaseLap() !Chomp {
    for (0..64) |seed| {
        var chomp: Chomp = .init(seed);
        chomp.fit(&.{ .columns = 80 });
        if (chaseStage(&chomp) == .wait) return chomp;
    }
    return error.TestExpectedChase;
}

fn lapWith(glyph: []const u8) !struct { chomp: Chomp, column: usize } {
    for (0..64) |seed| {
        var chomp: Chomp = .init(seed);
        chomp.fit(&.{ .columns = 80 });
        const column = glyphColumn(&chomp, &.{
            .edge = .bottom,
            .columns = 80,
            .glyph = glyph,
        }) orelse continue;
        return .{ .chomp = chomp, .column = column };
    }
    return error.TestExpectedItem;
}

test "the catch chance follows a survival curve whose median is four and a half minutes" {
    const median: u64 = @divExact(catch_ms_median, paint.frame_ms);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5),
        catchChance(&.{ .previous = 0, .now = median }),
        1e-9,
    );
    const half = @divFloor(median, 2);
    const first = catchChance(&.{ .previous = 0, .now = half });
    const second = catchChance(&.{ .previous = half, .now = median });
    try std.testing.expect(first < second);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), (1 - first) * (1 - second), 1e-9);
    try std.testing.expectEqual(@as(f64, 1), catchChance(&.{ .previous = 0, .now = median * 100 }));
}

test "a game ends with a game over label, and the next game starts at level 1" {
    var chomp: Chomp = .init(3);
    chomp.fit(&.{ .columns = 80 });
    var level_one_left = false;
    const ended = for (0..1_000_000) |frame| {
        chomp.advance();
        if (frame % game_over_frames != 0) continue;
        if (edgeShows(&chomp, &.{ .edge = .top, .columns = 80, .text = "Game over" })) break true;
        if (!edgeShows(&chomp, &.{ .edge = .top, .columns = 80, .text = " Level 1 " }))
            level_one_left = true;
    } else false;
    try std.testing.expect(ended and level_one_left);
    for (0..game_over_frames) |_| chomp.advance();
    try std.testing.expect(edgeShows(&chomp, &.{
        .edge = .top,
        .columns = 80,
        .text = "─ Level 1 ─",
    }));
}

test "the top edge names level 1 from the start and the next level after a cleared lap" {
    var chomp: Chomp = .init(5);
    chomp.fit(&.{ .columns = 80 });
    try std.testing.expect(edgeShows(&chomp, &.{
        .edge = .top,
        .columns = 80,
        .text = "─ Level 1 ─",
    }));
    const cleared = for (0..20_000) |_| {
        chomp.advance();
        if (edgeShows(&chomp, &.{ .edge = .top, .columns = 80, .text = "─ Level 2 ─" }))
            break true;
    } else false;
    try std.testing.expect(cleared);
}

test "a resize keeps the level and starts a new lap" {
    var chomp: Chomp = .init(5);
    chomp.fit(&.{ .columns = 80 });
    const eating = for (0..20_000) |_| {
        chomp.advance();
        if (edgeShows(&chomp, &.{ .edge = .top, .columns = 80, .text = "─ Level 2 ─" }) and
            std.mem.eql(u8, chomp.cell(.bottom, 0).glyph, " ") and
            std.mem.eql(u8, chomp.cell(.bottom, 79).glyph, "─")) break true;
    } else false;
    try std.testing.expect(eating);
    chomp.fit(&.{ .columns = 120 });
    try std.testing.expect(edgeShows(&chomp, &.{
        .edge = .top,
        .columns = 120,
        .text = "─ Level 2 ─",
    }));
    try std.testing.expect(!edgeShows(&chomp, &.{ .edge = .bottom, .columns = 120, .text = " " }));
    for (0..2) |_| chomp.advance();
    try std.testing.expectEqual(@as(?usize, 0), chomperColumn(&chomp, 120));
}

test "a change of the width after a catch starts the next game at level 1" {
    for ([_]std.meta.Tag(Chase){ .hit, .dead }) |stage| {
        var chomp: Chomp = .init(0);
        chomp.fit(&.{ .columns = 80 });
        const reached = for (0..1_000_000) |_| {
            chomp.advance();
            if (chaseStage(&chomp) == stage) break true;
        } else false;
        try std.testing.expect(reached and chomp.level > 1);
        chomp.fit(&.{ .columns = 90 });
        try std.testing.expect(edgeShows(&chomp, &.{
            .edge = .top,
            .columns = 90,
            .text = "─ Level 1 ─",
        }));
    }
}

fn chaseStage(chomp: *const Chomp) ?std.meta.Tag(Chase) {
    const event = lapEvent(chomp) orelse return null;
    return switch (event.*) {
        .chase => |*chase| std.meta.activeTag(chase.*),
        .hunt, .love, .nap, .hole, .music, .slot, .mirror => null,
    };
}

test "a game ends after about five minutes at the median on a narrow and on a wide terminal" {
    for ([_]usize{ 83, 178 }) |columns| {
        var minutes: [61]f64 = undefined;
        for (&minutes, 0..) |*slot, seed| {
            var chomp: Chomp = .init(seed);
            chomp.fit(&.{ .columns = columns });
            var frames: u64 = 0;
            while (frames < 1_000_000) : (frames += 1) {
                chomp.advance();
                if (frames % game_over_frames == 0 and edgeShows(&chomp, &.{
                    .edge = .top,
                    .columns = columns,
                    .text = "Game over",
                })) break;
            }
            slot.* = @as(f64, @floatFromInt(frames * paint.frame_ms)) / std.time.ms_per_min;
        }
        std.mem.sort(f64, &minutes, {}, std.sort.asc(f64));
        const median = minutes[@divFloor(minutes.len, 2)];
        try std.testing.expect(median > 4.5 and median < 6.5);
    }
}
