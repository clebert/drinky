const std = @import("std");

const ai = @import("ai");

const ui = @import("ui/root.zig");

const Transcript = @This();

gpa: std.mem.Allocator,
entries: std.ArrayList(ui.block.Entry),
projected: std.ArrayList(*ui.block.Entry),
current: ?struct { kind: ui.block.Entry.Kind, index: ?usize },
held: std.ArrayList(u8),
message_start: ?usize,

pub const Setup = struct {
    account: ?ai.llm.Account,
    replays_reasoning: bool,
};

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{
        .gpa = gpa,
        .entries = .empty,
        .projected = .empty,
        .current = null,
        .held = .empty,
        .message_start = null,
    };
}

pub fn deinit(self: *Transcript) void {
    for (self.entries.items) |*entry| entry.deinit(self.gpa);
    self.entries.deinit(self.gpa);
    self.projected.deinit(self.gpa);
    self.held.deinit(self.gpa);
}

pub fn append(
    self: *Transcript,
    kind: ui.block.Entry.Kind,
    options: ui.block.Entry.Options,
    text: []const u8,
) !void {
    self.endMessage();
    var entry = try ui.block.Entry.init(self.gpa, kind, options, text);
    errdefer entry.deinit(self.gpa);
    try self.entries.append(self.gpa, entry);
}

pub fn replaceEvent(
    self: *Transcript,
    index: usize,
    options: ui.block.Entry.Options,
    text: []const u8,
) !void {
    std.debug.assert(index < self.entries.items.len);
    try self.entries.items[index].replaceEvent(self.gpa, options, text);
}

pub fn producedBefore(self: *const Transcript, account: ai.llm.Account, index: usize) usize {
    std.debug.assert(index <= self.entries.items.len);
    var count: usize = 0;
    for (self.entries.items[0..index]) |*entry| count += @intFromBool(entry.account() == account);
    return count;
}

pub fn repeatEvent(
    self: *Transcript,
    options: ui.block.Entry.Options,
    text: []const u8,
) !bool {
    if (options.mirrored or self.streaming() or self.entries.items.len == 0) return false;
    const last = &self.entries.items[self.entries.items.len - 1];
    if (!last.statesEvent(options, text)) return false;
    try last.repeatEvent(self.gpa);
    return true;
}

pub fn appendStream(
    self: *Transcript,
    kind: ui.block.Entry.Kind,
    account: ?ai.llm.Account,
    delta: []const u8,
) !void {
    if (delta.len == 0) return;
    if (self.current == null or self.current.?.kind != kind) {
        self.current = .{ .kind = kind, .index = null };
        self.held.clearRetainingCapacity();
    }
    const run = &self.current.?;
    if (run.index == null) {
        if (ui.block.isBlank(delta)) return self.held.appendSlice(self.gpa, delta);
        run.index = try self.openRun(kind, account);
    }
    try self.entries.items[run.index.?].appendText(self.gpa, delta);
}

fn openRun(self: *Transcript, kind: ui.block.Entry.Kind, account: ?ai.llm.Account) !usize {
    var entry = try ui.block.Entry.init(self.gpa, kind, .{ .account = account }, self.held.items);
    errdefer entry.deinit(self.gpa);
    try self.entries.append(self.gpa, entry);
    self.held.clearRetainingCapacity();
    const index = self.entries.items.len - 1;
    if (self.message_start == null) self.message_start = index;
    return index;
}

pub fn streaming(self: *const Transcript) bool {
    return self.current != null;
}

pub fn endMessage(self: *Transcript) void {
    self.current = null;
    self.held.clearRetainingCapacity();
    self.message_start = null;
}

pub fn discardMessage(self: *Transcript) void {
    const maybe_start = self.message_start;
    self.endMessage();
    const start = maybe_start orelse return;
    for (self.entries.items[start..]) |*entry| entry.deinit(self.gpa);
    self.entries.shrinkRetainingCapacity(start);
}

pub fn truncate(self: *Transcript, entry_count: usize) void {
    std.debug.assert(entry_count <= self.entries.items.len);
    self.endMessage();
    for (self.entries.items[entry_count..]) |*entry| entry.deinit(self.gpa);
    self.entries.shrinkRetainingCapacity(entry_count);
}

pub fn rewind(self: *Transcript, entry_count: usize) void {
    std.debug.assert(entry_count <= self.entries.items.len);
    self.endMessage();
    var retained_count = entry_count;
    for (self.entries.items[entry_count..]) |*entry| {
        if (entry.survivesRewind()) {
            self.entries.items[retained_count] = entry.*;
            retained_count += 1;
        } else {
            entry.deinit(self.gpa);
        }
    }
    self.entries.shrinkRetainingCapacity(retained_count);
}

pub const Removal = struct {
    removed_count: usize,
    removed_before_cursor_count: usize,

    pub const Options = struct {
        range_base: usize,
        range_end: usize,
        mirror_cursor: usize,
    };
};

pub fn removeTurn(self: *Transcript, options: Removal.Options) Removal {
    std.debug.assert(options.range_base <= options.range_end);
    std.debug.assert(options.range_end <= self.entries.items.len);
    self.endMessage();
    const cursor = @min(options.mirror_cursor, self.entries.items.len);
    var removal: Removal = .{ .removed_count = 0, .removed_before_cursor_count = 0 };
    var retained_count = options.range_base;
    for (options.range_base..options.range_end) |index| {
        const entry = &self.entries.items[index];
        if (entry.turnOwned()) {
            entry.deinit(self.gpa);
            removal.removed_count += 1;
            if (index < cursor) removal.removed_before_cursor_count += 1;
            continue;
        }
        self.entries.items[retained_count] = entry.*;
        retained_count += 1;
    }
    const tail = self.entries.items[options.range_end..];
    std.mem.copyForwards(
        ui.block.Entry,
        self.entries.items[retained_count .. retained_count + tail.len],
        tail,
    );
    self.entries.shrinkRetainingCapacity(retained_count + tail.len);
    return removal;
}

pub fn blocks(self: *const Transcript) []const ui.block.Entry {
    return self.entries.items;
}

pub fn shows(producer: ?ai.llm.Account, setup: Setup) bool {
    const owner = producer orelse return true;
    const account = setup.account orelse return true;
    return owner == account and setup.replays_reasoning;
}

pub fn projection(self: *Transcript, setup: Setup) ![]const *ui.block.Entry {
    self.projected.clearRetainingCapacity();
    for (self.entries.items) |*entry| {
        if (shows(entry.account(), setup)) {
            try self.projected.append(self.gpa, entry);
        } else {
            entry.release(self.gpa);
        }
    }
    return self.projected.items;
}

pub fn projectionChanges(self: *const Transcript, previous: Setup, next: Setup) bool {
    for (self.entries.items) |*entry| {
        const producer = entry.account();
        if (shows(producer, previous) != shows(producer, next)) return true;
    }
    return false;
}

pub fn dropAccount(self: *Transcript, account: ai.llm.Account) usize {
    self.endMessage();
    var retained_count: usize = 0;
    for (self.entries.items) |*entry| {
        if (entry.account() == account) {
            entry.deinit(self.gpa);
            continue;
        }
        self.entries.items[retained_count] = entry.*;
        retained_count += 1;
    }
    const removed = self.entries.items.len - retained_count;
    self.entries.shrinkRetainingCapacity(retained_count);
    return removed;
}

const test_account: ai.llm.Account = .anthropic_plan;
const other_account: ai.llm.Account = .openai_api_key;

fn replaying(account: ?ai.llm.Account) Setup {
    return .{ .account = account, .replays_reasoning = true };
}

fn silent(account: ?ai.llm.Account) Setup {
    return .{ .account = account, .replays_reasoning = false };
}

test "streamed deltas collect into one block until a discrete block ends the run" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.model, null, "hel");
    try transcript.appendStream(.model, null, "lo");
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);
    try std.testing.expectEqualStrings("hello", transcript.entries.items[0].content.model.items);

    try transcript.append(.user, .{}, "hi");
    try transcript.appendStream(.model, null, "more");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries.items.len);
    try std.testing.expectEqualStrings("more", transcript.entries.items[2].content.model.items);
}

test "an empty delta opens no block and does not break a run" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, test_account, "");
    try transcript.appendStream(.model, null, "");
    try std.testing.expectEqual(@as(usize, 0), transcript.entries.items.len);

    try transcript.appendStream(.model, null, "he");
    try transcript.appendStream(.model, null, "");
    try transcript.appendStream(.model, null, "llo");
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);
    try std.testing.expectEqualStrings("hello", transcript.entries.items[0].content.model.items);
}

test "a run holds its whitespace until another byte opens the block" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, test_account, "\n");
    try transcript.appendStream(.thinking, test_account, " \t\r\n");
    try std.testing.expectEqual(@as(usize, 0), transcript.entries.items.len);
    try std.testing.expect(transcript.streaming());

    try transcript.appendStream(.model, null, "answer");
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);
    try std.testing.expectEqualStrings("answer", transcript.entries.items[0].content.model.items);

    transcript.endMessage();
    try transcript.appendStream(.thinking, test_account, "\n\n");
    try transcript.appendStream(.thinking, test_account, "weigh it");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    const reasoning = transcript.entries.items[1].content.thinking;
    try std.testing.expectEqualStrings("\n\nweigh it", reasoning.text.items);

    transcript.endMessage();
    try transcript.appendStream(.model, null, " ");
    transcript.discardMessage();
    try std.testing.expect(!transcript.streaming());
    try std.testing.expectEqual(@as(usize, 0), transcript.held.items.len);
    try transcript.appendStream(.model, null, " ");
    transcript.endMessage();
    try std.testing.expectEqual(@as(usize, 0), transcript.held.items.len);
    try transcript.appendStream(.model, null, "fresh");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries.items.len);
    try std.testing.expectEqualStrings("fresh", transcript.entries.items[2].content.model.items);
}

test "endMessage forces the next delta into a new block" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.model, null, "a");
    transcript.endMessage();
    try transcript.appendStream(.model, null, "b");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
}

test "discardMessage drops the open run so a retry starts clean" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.user, .{}, "hi");
    try transcript.appendStream(.model, null, "partial");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);

    transcript.discardMessage();
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);

    try transcript.appendStream(.model, null, "fresh");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings("fresh", transcript.entries.items[1].content.model.items);

    transcript.endMessage();
    transcript.discardMessage();
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
}

test "truncate removes optimistic tail blocks" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.user, .{}, "keep");
    try transcript.append(.user, .{}, "rollback");
    transcript.truncate(1);
    try std.testing.expectEqual(@as(usize, 1), transcript.blocks().len);
    try std.testing.expectEqualStrings("keep", transcript.blocks()[0].content.user.items);
}

test "rewind preserves only marked events after its checkpoint" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.event, .{}, "keep before checkpoint");
    try transcript.append(.user, .{}, "drop user prompt");
    try transcript.append(.event, .{ .survives_rewind = true }, "keep retry");
    try transcript.append(.event, .{}, "drop ordinary event");
    try transcript.appendStream(.model, null, "drop partial reply");
    transcript.rewind(1);

    const entries = transcript.blocks();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings(
        "keep before checkpoint",
        entries[0].content.event.text.items,
    );
    try std.testing.expectEqualStrings("keep retry", entries[1].content.event.text.items);
}

test "removeTurn takes the turn-owned blocks of its range and counts the cursor prefix" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.intro, .{}, "legend");
    try transcript.append(.user, .{}, "fix it");
    try transcript.appendStream(.thinking, test_account, "weigh it");
    try transcript.appendStream(.model, null, "answer");
    try transcript.append(.event, .{ .survives_rewind = true, .turn_owned = true }, "retry");
    try transcript.append(.event, .{ .survives_rewind = true }, "You attached @bot.");
    try transcript.append(.tool_result, .{}, "Tool: read");
    try transcript.append(.user_note, .{}, "Skill: demo");
    try transcript.append(.event, .{ .turn_owned = true }, "You canceled the turn.");
    try transcript.append(.event, .{}, "Drinky changed the model.");
    try std.testing.expectEqual(@as(usize, 10), transcript.blocks().len);

    const removal = transcript.removeTurn(.{ .range_base = 1, .range_end = 9, .mirror_cursor = 6 });
    try std.testing.expectEqual(@as(usize, 7), removal.removed_count);
    try std.testing.expectEqual(@as(usize, 4), removal.removed_before_cursor_count);
    try std.testing.expect(!transcript.streaming());

    const entries = transcript.blocks();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(entries[0].content == .intro);
    try std.testing.expectEqualStrings("You attached @bot.", entries[1].content.event.text.items);
    try std.testing.expectEqualStrings(
        "Drinky changed the model.",
        entries[2].content.event.text.items,
    );

    try transcript.append(.user, .{}, "again");
    const before = transcript.removeTurn(.{ .range_base = 3, .range_end = 4, .mirror_cursor = 1 });
    try std.testing.expectEqual(@as(usize, 1), before.removed_count);
    try std.testing.expectEqual(@as(usize, 0), before.removed_before_cursor_count);
    try transcript.append(.user, .{}, "once more");
    const after = transcript.removeTurn(.{ .range_base = 3, .range_end = 4, .mirror_cursor = 99 });
    try std.testing.expectEqual(@as(usize, 1), after.removed_count);
    try std.testing.expectEqual(@as(usize, 1), after.removed_before_cursor_count);
    const empty = transcript.removeTurn(.{ .range_base = 3, .range_end = 3, .mirror_cursor = 3 });
    try std.testing.expectEqual(@as(usize, 0), empty.removed_count);
    try std.testing.expectEqual(@as(usize, 3), transcript.blocks().len);
}

test "reasoning collects into a thinking block that the answer run does not extend" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, test_account, "weigh ");
    try transcript.appendStream(.thinking, test_account, "it");
    try transcript.appendStream(.model, null, "answer");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    const reasoning = transcript.entries.items[0].content.thinking;
    try std.testing.expectEqualStrings("weigh it", reasoning.text.items);
    try std.testing.expectEqualStrings("answer", transcript.entries.items[1].content.model.items);
}

test "discard drops a partial message's reasoning and answer together" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.user, .{}, "hi");
    try transcript.appendStream(.thinking, test_account, "thinking");
    try transcript.appendStream(.model, null, "partial");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries.items.len);

    transcript.discardMessage();
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);

    try transcript.appendStream(.thinking, test_account, "fresh");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    const reasoning = transcript.entries.items[1].content.thinking;
    try std.testing.expectEqualStrings("fresh", reasoning.text.items);
}

test "a projection holds the reasoning of its own account alone" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.event, .{}, "Drinky changed the model.");
    try transcript.appendStream(.thinking, test_account, "weigh it");
    try transcript.appendStream(.model, null, "answer");

    const own = try transcript.projection(replaying(test_account));
    try std.testing.expectEqual(@as(usize, 3), own.len);
    try std.testing.expectEqualStrings("weigh it", own[1].content.thinking.text.items);

    const other = try transcript.projection(replaying(other_account));
    try std.testing.expectEqual(@as(usize, 2), other.len);
    try std.testing.expect(other[0].content == .event);
    try std.testing.expectEqualStrings("answer", other[1].content.model.items);

    try std.testing.expectEqual(@as(usize, 3), transcript.blocks().len);
    const again = try transcript.projection(replaying(test_account));
    try std.testing.expectEqual(@as(usize, 3), again.len);
    const signed_out = try transcript.projection(replaying(null));
    try std.testing.expectEqual(@as(usize, 3), signed_out.len);
}

test "a projection hides its own reasoning when the request replays none" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, test_account, "weigh it");
    try transcript.appendStream(.model, null, "answer");

    const shown_blocks = try transcript.projection(silent(test_account));
    try std.testing.expectEqual(@as(usize, 1), shown_blocks.len);
    try std.testing.expectEqualStrings("answer", shown_blocks[0].content.model.items);
    try std.testing.expectEqual(@as(usize, 2), transcript.blocks().len);
    const replayed = try transcript.projection(replaying(test_account));
    try std.testing.expectEqual(@as(usize, 2), replayed.len);
}

test "projectionChanges reports only a switch that hides or restores a block" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    const own = replaying(test_account);
    const other = replaying(other_account);
    const signed_out = replaying(null);

    try transcript.appendStream(.model, null, "answer");
    try std.testing.expect(!transcript.projectionChanges(own, other));
    try std.testing.expect(!transcript.projectionChanges(own, silent(test_account)));

    try transcript.appendStream(.thinking, test_account, "weigh it");
    try std.testing.expect(transcript.projectionChanges(own, other));
    try std.testing.expect(transcript.projectionChanges(other, own));
    try std.testing.expect(!transcript.projectionChanges(own, own));
    try std.testing.expect(transcript.projectionChanges(own, silent(test_account)));
    try std.testing.expect(!transcript.projectionChanges(other, silent(test_account)));
    try std.testing.expect(!transcript.projectionChanges(signed_out, own));
    try std.testing.expect(transcript.projectionChanges(signed_out, other));
}

test "dropAccount removes the reasoning of one account for good" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, test_account, "weigh it");
    try transcript.appendStream(.model, null, "answer");
    try transcript.appendStream(.thinking, other_account, "another slot");

    try std.testing.expectEqual(@as(usize, 1), transcript.dropAccount(test_account));
    try std.testing.expectEqual(@as(usize, 2), transcript.blocks().len);
    try std.testing.expectEqualStrings("answer", transcript.blocks()[0].content.model.items);
    const reasoning = transcript.blocks()[1].content.thinking;
    try std.testing.expectEqualStrings("another slot", reasoning.text.items);
    const own = try transcript.projection(replaying(test_account));
    try std.testing.expectEqual(@as(usize, 1), own.len);
    try std.testing.expectEqual(@as(usize, 0), transcript.dropAccount(.anthropic_api));
    try std.testing.expectEqual(@as(usize, 2), transcript.blocks().len);
}
