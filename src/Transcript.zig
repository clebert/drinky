//! The permanent blocks above the live tail, oldest first. The "model run"
//! invariant: a run of streamed reasoning collects into one growing thinking
//! block. Then a run of streamed answer text collects into one growing model
//! block. A tool call, a turn boundary, or any other block ends the message.
//! Owns its blocks' bytes (freed on `deinit`).
//!
//! The list is the one canonical record of the conversation. `projection` filters
//! it for the setup of the next request, because a provider replays stored
//! reasoning only to the exact account that produced it, and Anthropic replays it
//! only while the request names an effort. A hidden block stays in the list and
//! returns as soon as a setup carries it again.

const std = @import("std");

const ai = @import("ai");

const ui = @import("ui/root.zig");

const Transcript = @This();

gpa: std.mem.Allocator,
entries: std.ArrayList(ui.block.Entry),
/// The blocks of the last `projection`, in screen order. Each paint rebuilds
/// them, so the layout gets a `[]const *const ui.block.Entry` without a
/// per-repaint allocation. A projection hides the blocks of another account, and
/// a hidden block breaks a contiguous slice, so the list holds one pointer per
/// shown block.
projected: std.ArrayList(*const ui.block.Entry),
/// The index and kind of the current run's streamed block, so deltas of that
/// kind append to it. Null when no run is open.
current: ?struct { index: usize, kind: ui.block.Entry.Kind },
/// The index of the first block streamed for the current assistant message
/// (reasoning or answer), so a retry can drop the whole partial message. Null
/// when none is streaming.
message_start: ?usize,

/// What the next request carries of the stored reasoning, so the projection can
/// show that and nothing else. `Session` builds it from the account, the model,
/// and the effort level it shows.
pub const Setup = struct {
    /// The account slot that renders the next request. Null while signed out.
    account: ?ai.llm.Account,
    /// Whether a request of that account replays its stored reasoning. Anthropic
    /// drops every thinking block unless the request names an effort, so a model
    /// change or an effort change alone can take a block out of the prompt.
    replays_reasoning: bool,
};

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{
        .gpa = gpa,
        .entries = .empty,
        .projected = .empty,
        .current = null,
        .message_start = null,
    };
}

pub fn deinit(self: *Transcript) void {
    for (self.entries.items) |*entry| entry.deinit(self.gpa);
    self.entries.deinit(self.gpa);
    self.projected.deinit(self.gpa);
}

/// Append a discrete block that copies `text`. This ends any open streamed run,
/// so the next streamed delta opens a fresh block.
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

/// Append streamed text of `kind` (`.thinking` reasoning or `.model` answer).
/// Open a block of that kind on demand so a run of deltas collects into one
/// block. A kind change ends the previous run. A provider can stream a delta
/// with no bytes. Such a delta opens no block, because an empty block shows as
/// a blank row and its separator. It also leaves the open run alone, so the
/// deltas around it still collect into one block.
///
/// A new reasoning block records `account` as the slot that produced it, so the
/// projection of another account hides it. An answer block ignores `account`,
/// because every account shows a message.
pub fn appendStream(
    self: *Transcript,
    kind: ui.block.Entry.Kind,
    account: ?ai.llm.Account,
    delta: []const u8,
) !void {
    if (delta.len == 0) return;
    if (self.current == null or self.current.?.kind != kind)
        self.current = .{ .index = try self.openRun(kind, account), .kind = kind };
    switch (self.entries.items[self.current.?.index]) {
        .model => |*list| try list.appendSlice(self.gpa, delta),
        .thinking => |*reasoning| try reasoning.text.appendSlice(self.gpa, delta),
        else => unreachable,
    }
}

/// Open a streamed block of `kind` at the tail and return its index. Record it
/// as the message's first block when none has opened yet.
fn openRun(self: *Transcript, kind: ui.block.Entry.Kind, account: ?ai.llm.Account) !usize {
    var entry = try ui.block.Entry.init(self.gpa, kind, .{ .account = account }, "");
    errdefer entry.deinit(self.gpa);
    try self.entries.append(self.gpa, entry);
    const index = self.entries.items.len - 1;
    if (self.message_start == null) self.message_start = index;
    return index;
}

/// End the current message's streamed runs so the next delta opens a new block.
pub fn endMessage(self: *Transcript) void {
    self.current = null;
    self.message_start = null;
}

/// Drop the open message's streamed blocks (reasoning and answer alike) so a
/// retried reply leaves nothing partial behind. A no-op when none is
/// streaming. The blocks are the contiguous tail from `message_start`, because
/// nothing discrete has ended the message.
pub fn discardMessage(self: *Transcript) void {
    const start = self.message_start orelse return;
    self.endMessage();
    for (self.entries.items[start..]) |*entry| entry.deinit(self.gpa);
    self.entries.shrinkRetainingCapacity(start);
}

/// Drop every block from `entry_count` onward. This rolls back an optimistic
/// discrete append when the operation it represents fails to start.
pub fn truncate(self: *Transcript, entry_count: usize) void {
    std.debug.assert(entry_count <= self.entries.items.len);
    self.endMessage();
    for (self.entries.items[entry_count..]) |*entry| entry.deinit(self.gpa);
    self.entries.shrinkRetainingCapacity(entry_count);
}

/// Every block above the live tail, oldest first: the canonical record, hidden
/// blocks included.
pub fn blocks(self: *const Transcript) []const ui.block.Entry {
    return self.entries.items;
}

/// Whether the projection of `setup` shows a block that `producer` produced.
/// A local block has no producer, so every projection shows it. A produced block
/// needs a request that replays it, and only the exact slot that produced it
/// replays it. A signed-out Drinky sends no request, so it hides nothing.
pub fn shows(producer: ?ai.llm.Account, setup: Setup) bool {
    const owner = producer orelse return true;
    const account = setup.account orelse return true;
    return owner == account and setup.replays_reasoning;
}

/// The blocks `setup` shows, oldest first, for projection. Each paint rebuilds
/// the list. The pointers stay valid until the blocks next change.
pub fn projection(self: *Transcript, setup: Setup) ![]const *const ui.block.Entry {
    self.projected.clearRetainingCapacity();
    for (self.entries.items) |*entry| {
        if (shows(entry.account(), setup)) try self.projected.append(self.gpa, entry);
    }
    return self.projected.items;
}

/// Whether the projection of `previous` holds other blocks than the projection
/// of `next`. A change needs a deep repaint, because a block that leaves must
/// leave the terminal scrollback too, and a block that returns must return above
/// the window. The two projections differ or they do not, so the order of the two
/// setups cannot change the answer.
pub fn projectionChanges(self: *const Transcript, previous: Setup, next: Setup) bool {
    for (self.entries.items) |*entry| {
        const producer = entry.account();
        if (shows(producer, previous) != shows(producer, next)) return true;
    }
    return false;
}

/// Remove every block that `account` produced, and report whether one left. A
/// credential replacement drops the replay proofs of that account slot for good,
/// so the blocks that hold that reasoning go with them. This ends the open
/// message, because a removal moves the blocks behind it.
pub fn dropAccount(self: *Transcript, account: ai.llm.Account) bool {
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
    const removed = retained_count != self.entries.items.len;
    self.entries.shrinkRetainingCapacity(retained_count);
    return removed;
}

// The account slot the tests stream reasoning under, and the one that projects
// the same transcript without that reasoning.
const test_account: ai.llm.Account = .anthropic_subscription;
const other_account: ai.llm.Account = .openai_api;

// The setup of a request that `account` sends and that replays its reasoning.
fn replaying(account: ?ai.llm.Account) Setup {
    return .{ .account = account, .replays_reasoning = true };
}

// The setup of a request that `account` sends with no reasoning at all, as an
// Anthropic request that names no effort.
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
    try std.testing.expectEqualStrings("hello", transcript.entries.items[0].model.items);

    try transcript.append(.user, .{}, "hi");
    try transcript.appendStream(.model, null, "more");
    try std.testing.expectEqual(@as(usize, 3), transcript.entries.items.len);
    try std.testing.expectEqualStrings("more", transcript.entries.items[2].model.items);
}

// Regression: a provider can stream a delta with no bytes. It used to open a
// block, which showed as a blank row and its separator between the blocks
// around it.
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
    try std.testing.expectEqualStrings("hello", transcript.entries.items[0].model.items);
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
    try std.testing.expectEqualStrings("fresh", transcript.entries.items[1].model.items);

    // A no-op when no run is open.
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
    try std.testing.expectEqualStrings("keep", transcript.blocks()[0].user.items);
}

test "reasoning collects into a thinking block that the answer run does not extend" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, test_account, "weigh ");
    try transcript.appendStream(.thinking, test_account, "it");
    try transcript.appendStream(.model, null, "answer");
    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings("weigh it", transcript.entries.items[0].thinking.text.items);
    try std.testing.expectEqualStrings("answer", transcript.entries.items[1].model.items);
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
    try std.testing.expectEqualStrings("fresh", transcript.entries.items[1].thinking.text.items);
}

// One canonical record, one projection per account. A provider replays stored
// reasoning only to the account that produced it, so only that account shows the
// block. Every local block stays, because it is no model context.
test "a projection holds the reasoning of its own account alone" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.append(.event, .{}, "Drinky changed the model.");
    try transcript.appendStream(.thinking, test_account, "weigh it");
    try transcript.appendStream(.model, null, "answer");

    const own = try transcript.projection(replaying(test_account));
    try std.testing.expectEqual(@as(usize, 3), own.len);
    try std.testing.expectEqualStrings("weigh it", own[1].thinking.text.items);

    const other = try transcript.projection(replaying(other_account));
    try std.testing.expectEqual(@as(usize, 2), other.len);
    try std.testing.expect(other[0].* == .event);
    try std.testing.expectEqualStrings("answer", other[1].model.items);

    // The hidden block stays in the canonical record and returns with its
    // account.
    try std.testing.expectEqual(@as(usize, 3), transcript.blocks().len);
    const again = try transcript.projection(replaying(test_account));
    try std.testing.expectEqual(@as(usize, 3), again.len);
    // A signed-out Drinky sends no request, so no projection contradicts the
    // screen and nothing hides.
    const signed_out = try transcript.projection(replaying(null));
    try std.testing.expectEqual(@as(usize, 3), signed_out.len);
}

// The account is not the only dimension. Anthropic drops every thinking block
// unless the request names an effort, so a request of the producing account can
// carry no reasoning at all. The screen then holds none either.
test "a projection hides its own reasoning when the request replays none" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.appendStream(.thinking, test_account, "weigh it");
    try transcript.appendStream(.model, null, "answer");

    const shown_blocks = try transcript.projection(silent(test_account));
    try std.testing.expectEqual(@as(usize, 1), shown_blocks.len);
    try std.testing.expectEqualStrings("answer", shown_blocks[0].model.items);
    // The block waits for a setup that carries it again.
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
    // A transcript with no reasoning projects the same under every setup.
    try std.testing.expect(!transcript.projectionChanges(own, other));
    try std.testing.expect(!transcript.projectionChanges(own, silent(test_account)));

    try transcript.appendStream(.thinking, test_account, "weigh it");
    try std.testing.expect(transcript.projectionChanges(own, other));
    try std.testing.expect(transcript.projectionChanges(other, own));
    try std.testing.expect(!transcript.projectionChanges(own, own));
    // A request of the same account that replays no reasoning hides the block
    // too, so an effort change alone needs the deep repaint.
    try std.testing.expect(transcript.projectionChanges(own, silent(test_account)));
    try std.testing.expect(!transcript.projectionChanges(other, silent(test_account)));
    // Both a sign-out and a sign-in show every block, so neither hides one.
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

    try std.testing.expect(transcript.dropAccount(test_account));
    try std.testing.expectEqual(@as(usize, 2), transcript.blocks().len);
    try std.testing.expectEqualStrings("answer", transcript.blocks()[0].model.items);
    try std.testing.expectEqualStrings("another slot", transcript.blocks()[1].thinking.text.items);
    // The removal is permanent, so the projection of that account holds no
    // reasoning either.
    const own = try transcript.projection(replaying(test_account));
    try std.testing.expectEqual(@as(usize, 1), own.len);
    // A slot that produced no block leaves the record as it is.
    try std.testing.expect(!transcript.dropAccount(.anthropic_console));
    try std.testing.expectEqual(@as(usize, 2), transcript.blocks().len);
}
