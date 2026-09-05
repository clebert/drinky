//! The open picker of the chat: one message whose inline keyboard holds one
//! button per row, a `✓` on the current row, and the `Cancel` button. A stepped
//! picker edits the same message per step and adds the `‹ Back` button, so a
//! `/model` flow walks the same steps as in the terminal.
//!
//! The picker holds the state alone. Its owner runs the selector of a tapped
//! row and applies the outcome, because the outcome reaches the session. Every
//! keyboard takes a fresh serial, so a tap on a step that an edit replaced, on
//! a picker that a newer one made stale, or on a picker the chat closed names a
//! serial the picker no longer holds, and the owner answers it as stale.

const std = @import("std");

const ai = @import("ai");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const keyboard = @import("keyboard.zig");

const Picker = @This();

/// The rows one keyboard shows. Telegram bounds a keyboard at 100 buttons, and
/// the two control buttons take the rest.
const rows_max = 98;

/// The steps a picker can return to. The deepest flow today is the command list
/// and the three steps of `/model`.
const trail_max = 8;

const back_label = "‹ Back";
const cancel_label = "Cancel";
const current_mark = "✓ ";

gpa: std.mem.Allocator,
/// The serial of the newest keyboard. Every keyboard takes the next one. The
/// owner seeds it per process, so a keyboard that an earlier process left in the
/// chat names no serial of this one.
serial: u64,
open: ?Open,

/// One picker message with its rows and the steps above it.
const Open = struct {
    /// The message, or null when the chat dropped the send.
    handle: ?Attachment.Handle,
    serial: u64,
    select: *const fn (*ai.command.Context, usize) anyerror!ai.command.Outcome,
    /// The rows. Owned.
    options: []const []const u8,
    /// Borrowed from the command, which names it in a literal.
    title: []const u8,
    cancellation_message: []const u8,
    reopen: ?ai.command.Outcome.Opener,
    /// The openers of the steps above this one, oldest first.
    trail: [trail_max]ai.command.Outcome.Opener,
    trail_len: usize,

    fn deinit(self: *const Open, gpa: std.mem.Allocator) void {
        for (self.options) |option| gpa.free(option);
        gpa.free(self.options);
    }
};

/// What a tap on the open picker asks for.
pub const Action = union(enum) {
    /// The selector of the picker runs with this row.
    row: usize,
    /// The step above builds itself again with this opener, and `replace` shows
    /// it.
    back: ai.command.Outcome.Opener,
    /// The picker ends with its cancellation message.
    close,
};

pub fn init(gpa: std.mem.Allocator) Picker {
    return .{ .gpa = gpa, .serial = 0, .open = null };
}

/// Start the serials at `seed`. The owner draws one random seed per process.
pub fn seedSerials(self: *Picker, seed: u64) void {
    self.serial = seed;
}

pub fn deinit(self: *Picker) void {
    self.close();
}

/// Whether a picker stands open in the chat.
pub fn isOpen(self: *const Picker) bool {
    return self.open != null;
}

/// The cancellation message of the open picker.
pub fn cancellationMessage(self: *const Picker) []const u8 {
    return self.open.?.cancellation_message;
}

/// Show `pick` as a new message. A picker that stands open becomes stale, and
/// its keyboard stays in the chat history. Takes ownership of `pick.options`.
pub fn show(self: *Picker, chat: anytype, pick: *const ai.command.Outcome.Pick) !void {
    self.close();
    var open = self.take(pick, &.{});
    errdefer open.deinit(self.gpa);
    const markup = try self.buildMarkup(&open, pick.current);
    defer self.gpa.free(markup);
    open.handle = try chat.sendTracked(open.title, &.{
        .disable_notification = true,
        .markup = markup,
    });
    self.open = open;
}

/// Show `pick` as the next step of the open picker: the same message takes the
/// new rows, and the open step goes on the trail, so `‹ Back` returns to it. A
/// step that rebuilds itself stays one step. Without an open picker the pick
/// shows as a new message. Takes ownership of `pick.options`.
pub fn step(self: *Picker, chat: anytype, pick: *const ai.command.Outcome.Pick) !void {
    const above = self.open orelse return self.show(chat, pick);
    var trail = above.trail[0..above.trail_len];
    var buffer: [trail_max]ai.command.Outcome.Opener = undefined;
    if (!sameStep(above.reopen, pick.reopen)) {
        if (above.reopen) |opener| {
            // A flow deeper than the trail drops its oldest step, so Back ends
            // the walk early and never returns to the wrong picker.
            const kept = if (trail.len == trail_max) trail[1..] else trail;
            @memcpy(buffer[0..kept.len], kept);
            buffer[kept.len] = opener;
            trail = buffer[0 .. kept.len + 1];
        } else {
            trail = &.{};
        }
    }
    try self.replace(chat, pick, trail);
}

/// Show `pick` in place of the open picker, after `‹ Back` rebuilt the step
/// above. The trail already lost the step that the tap left. Takes ownership of
/// `pick.options`.
pub fn replace(
    self: *Picker,
    chat: anytype,
    pick: *const ai.command.Outcome.Pick,
    trail: []const ai.command.Outcome.Opener,
) !void {
    const above = self.open orelse return self.show(chat, pick);
    var open = self.take(pick, trail);
    open.handle = above.handle;
    errdefer open.deinit(self.gpa);
    const markup = try self.buildMarkup(&open, pick.current);
    defer self.gpa.free(markup);
    if (open.handle) |handle| try chat.edit(handle, open.title, markup);
    above.deinit(self.gpa);
    self.open = open;
}

/// Whether two pickers are the same step: each step names the one opener that
/// builds it again.
fn sameStep(step_open: ?ai.command.Outcome.Opener, other: ?ai.command.Outcome.Opener) bool {
    const one = step_open orelse return false;
    const two = other orelse return false;
    return one == two;
}

/// The state of `pick` under a fresh serial and `trail`.
fn take(
    self: *Picker,
    pick: *const ai.command.Outcome.Pick,
    trail: []const ai.command.Outcome.Opener,
) Open {
    // A random seed can stand near the end of the range, so the count wraps
    // instead of an overflow.
    self.serial +%= 1;
    var open: Open = .{
        .handle = null,
        .serial = self.serial,
        .select = pick.select,
        .options = pick.options,
        .title = pick.title,
        .cancellation_message = pick.cancellation_message,
        .reopen = pick.reopen,
        .trail = undefined,
        .trail_len = trail.len,
    };
    @memcpy(open.trail[0..trail.len], trail);
    return open;
}

/// The action that `tap` asks of the open picker, or null for a tap on a
/// keyboard the picker no longer holds. A `‹ Back` tap takes its step off the
/// trail, and the owner shows the outcome of the opener with `replace`. The
/// trail of the open picker is then the one that `replace` takes.
pub fn resolve(self: *Picker, tap: keyboard.Tap) ?Action {
    const open = if (self.open) |*open| open else return null;
    switch (tap) {
        .row => |row| {
            if (row.serial != open.serial or row.index >= open.options.len) return null;
            return .{ .row = row.index };
        },
        .back => |serial| {
            if (serial != open.serial or open.trail_len == 0) return null;
            open.trail_len -= 1;
            return .{ .back = open.trail[open.trail_len] };
        },
        .close => |serial| {
            if (serial != open.serial) return null;
            return .close;
        },
        .cancel_turn, .withdraw, .retry, .dismiss => return null,
    }
}

/// Run the selector of the open picker over the row `index`, which `resolve`
/// named.
pub fn select(
    self: *const Picker,
    context: *ai.command.Context,
    index: usize,
) anyerror!ai.command.Outcome {
    return self.open.?.select(context, index);
}

/// The steps above the open picker, for the `replace` that follows a `‹ Back`.
pub fn openers(self: *const Picker) []const ai.command.Outcome.Opener {
    const open = if (self.open) |*open| open else return &.{};
    return open.trail[0..open.trail_len];
}

/// End the open picker: its message states `text` and loses its keyboard.
pub fn finish(self: *Picker, chat: anytype, text: []const u8) !void {
    const open = self.open orelse return;
    defer self.close();
    const handle = open.handle orelse return;
    try chat.edit(handle, text, null);
}

/// Forget the open picker without an edit. Its keyboard stays in the chat
/// history, and a tap on it answers as stale.
pub fn close(self: *Picker) void {
    const open = self.open orelse return;
    open.deinit(self.gpa);
    self.open = null;
}

/// The keyboard of `open`: one button per row, the current row marked, then
/// the `‹ Back` button where a step stands above, then `Cancel`. The result is
/// owned.
fn buildMarkup(self: *Picker, open: *const Open, current: ?usize) ![]u8 {
    var buttons: std.ArrayList(keyboard.Button) = .empty;
    defer {
        for (buttons.items) |button| {
            self.gpa.free(button.text);
            self.gpa.free(button.data);
        }
        buttons.deinit(self.gpa);
    }
    const shown = @min(open.options.len, rows_max);
    try buttons.ensureTotalCapacity(self.gpa, shown + 2);
    for (open.options[0..shown], 0..) |option, index| {
        const text = try std.fmt.allocPrint(
            self.gpa,
            "{s}{s}",
            .{ if (current == index) current_mark else "", option },
        );
        errdefer self.gpa.free(text);
        const data = try dataOf(self.gpa, .{ .row = .{ .serial = open.serial, .index = index } });
        buttons.appendAssumeCapacity(.{ .text = text, .data = data });
    }
    if (open.trail_len > 0) {
        const text = try self.gpa.dupe(u8, back_label);
        errdefer self.gpa.free(text);
        const data = try dataOf(self.gpa, .{ .back = open.serial });
        buttons.appendAssumeCapacity(.{ .text = text, .data = data });
    }
    {
        const text = try self.gpa.dupe(u8, cancel_label);
        errdefer self.gpa.free(text);
        const data = try dataOf(self.gpa, .{ .close = open.serial });
        buttons.appendAssumeCapacity(.{ .text = text, .data = data });
    }
    return keyboard.markup(self.gpa, buttons.items);
}

/// The callback data of `tap`, owned.
fn dataOf(gpa: std.mem.Allocator, tap: keyboard.Tap) ![]u8 {
    var buffer: [keyboard.data_bytes_max]u8 = undefined;
    return gpa.dupe(u8, tap.write(&buffer));
}

/// The chat of the tests: it records every send and every edit with the
/// keyboard of each.
const Recorder = struct {
    gpa: std.mem.Allocator,
    sends: std.ArrayList(Message) = .empty,
    edits: std.ArrayList(Message) = .empty,
    handle_next: Attachment.Handle = 1,

    const Message = struct {
        handle: ?Attachment.Handle,
        text: []u8,
        markup: ?[]u8,

        fn deinit(self: *const Message, gpa: std.mem.Allocator) void {
            gpa.free(self.text);
            if (self.markup) |markup| gpa.free(markup);
        }
    };

    fn deinit(self: *Recorder) void {
        for (self.sends.items) |message| message.deinit(self.gpa);
        self.sends.deinit(self.gpa);
        for (self.edits.items) |message| message.deinit(self.gpa);
        self.edits.deinit(self.gpa);
    }

    fn sendTracked(
        self: *Recorder,
        text: []const u8,
        options: *const Client.SendOptions,
    ) !?Attachment.Handle {
        const handle = self.handle_next;
        self.handle_next += 1;
        try self.sends.append(self.gpa, try self.record(handle, text, options.markup));
        return handle;
    }

    fn edit(
        self: *Recorder,
        handle: Attachment.Handle,
        text: []const u8,
        markup: ?[]const u8,
    ) !void {
        try self.edits.append(self.gpa, try self.record(handle, text, markup));
    }

    fn record(
        self: *Recorder,
        handle: ?Attachment.Handle,
        text: []const u8,
        markup: ?[]const u8,
    ) !Message {
        const text_copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(text_copy);
        const markup_copy: ?[]u8 = if (markup) |json| try self.gpa.dupe(u8, json) else null;
        return .{ .handle = handle, .text = text_copy, .markup = markup_copy };
    }

    fn lastEdit(self: *const Recorder) *const Message {
        return &self.edits.items[self.edits.items.len - 1];
    }
};

/// A pick of the tests over owned copies of `rows`.
fn testPick(
    gpa: std.mem.Allocator,
    rows: []const []const u8,
    current: ?usize,
    reopen: ?ai.command.Outcome.Opener,
) !ai.command.Outcome.Pick {
    var options: ai.command.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    for (rows) |row| try options.print("{s}", .{row});
    return .{
        .select = selectNothing,
        .title = "Effort",
        .cancellation_message = "You canceled the effort selection.",
        .options = try options.toOwnedSlice(),
        .current = current,
        .reopen = reopen,
    };
}

fn selectNothing(context: *ai.command.Context, index: usize) anyerror!ai.command.Outcome {
    _ = index;
    return ai.command.Outcome.reportNotice(context.gpa, .failure, "Select a valid row.", .{});
}

fn openFirst(context: *ai.command.Context) anyerror!ai.command.Outcome {
    return ai.command.Outcome.reportNotice(context.gpa, .information, "first", .{});
}

fn openSecond(context: *ai.command.Context) anyerror!ai.command.Outcome {
    return ai.command.Outcome.reportNotice(context.gpa, .information, "second", .{});
}

test "a picker shows its rows as buttons with the current mark and a cancel, and a pick states the result" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    try picker.show(&chat, &(try testPick(gpa, &.{ "low", "high" }, 1, null)));
    try std.testing.expect(picker.isOpen());
    try std.testing.expectEqualStrings("Effort", chat.sends.items[0].text);
    try std.testing.expectEqualStrings(
        "{\"inline_keyboard\":[[{\"text\":\"low\",\"callback_data\":\"row:1:0\"}]," ++
            "[{\"text\":\"✓ high\",\"callback_data\":\"row:1:1\"}]," ++
            "[{\"text\":\"Cancel\",\"callback_data\":\"close:1\"}]]}",
        chat.sends.items[0].markup.?,
    );
    try std.testing.expectEqual(@as(usize, 0), picker.resolve(.{ .row = .{ .serial = 1, .index = 0 } }).?.row);
    // A row past the list, a serial of another keyboard, and a back where no
    // step stands above all name nothing.
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1, .index = 2 } }) == null);
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 2, .index = 0 } }) == null);
    try std.testing.expect(picker.resolve(.{ .back = 1 }) == null);
    try std.testing.expect(picker.resolve(.{ .cancel_turn = 1 }) == null);
    try std.testing.expect(picker.resolve(.{ .close = 1 }).? == .close);
    try std.testing.expectEqualStrings("You canceled the effort selection.", picker.cancellationMessage());

    try picker.finish(&chat, "Drinky set the effort level to low.");
    try std.testing.expect(!picker.isOpen());
    try std.testing.expectEqual(@as(?Attachment.Handle, 1), chat.lastEdit().handle);
    try std.testing.expectEqualStrings("Drinky set the effort level to low.", chat.lastEdit().text);
    try std.testing.expect(chat.lastEdit().markup == null);
    try std.testing.expect(picker.resolve(.{ .close = 1 }) == null);
}

test "a step edits the same message, adds the back button, and a back takes the step off the trail" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    try picker.show(&chat, &(try testPick(gpa, &.{"Anthropic"}, null, openFirst)));
    try picker.step(&chat, &(try testPick(gpa, &.{ "Subscription", "API" }, null, openSecond)));
    try std.testing.expectEqual(@as(usize, 1), chat.sends.items.len);
    try std.testing.expectEqual(@as(?Attachment.Handle, 1), chat.lastEdit().handle);
    try std.testing.expectEqualStrings(
        "{\"inline_keyboard\":[[{\"text\":\"Subscription\",\"callback_data\":\"row:2:0\"}]," ++
            "[{\"text\":\"API\",\"callback_data\":\"row:2:1\"}]," ++
            "[{\"text\":\"‹ Back\",\"callback_data\":\"back:2\"}]," ++
            "[{\"text\":\"Cancel\",\"callback_data\":\"close:2\"}]]}",
        chat.lastEdit().markup.?,
    );
    // The replaced step is stale, and a step that rebuilds itself stays one step.
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1, .index = 0 } }) == null);
    try picker.step(&chat, &(try testPick(gpa, &.{"Subscription"}, null, openSecond)));
    try std.testing.expectEqual(@as(usize, 1), picker.openers().len);

    // Back names the step above and leaves the trail without it, so the
    // replacement stands at the top again.
    const action = picker.resolve(.{ .back = 3 }).?;
    try std.testing.expect(action.back == &openFirst);
    try std.testing.expectEqual(@as(usize, 0), picker.openers().len);
    try picker.replace(&chat, &(try testPick(gpa, &.{"Anthropic"}, 0, openFirst)), picker.openers());
    try std.testing.expect(std.mem.indexOf(u8, chat.lastEdit().markup.?, "‹ Back") == null);
    try std.testing.expect(std.mem.indexOf(u8, chat.lastEdit().markup.?, "\"text\":\"✓ Anthropic\",\"callback_data\":\"row:4:0\"") != null);
    try std.testing.expect(picker.resolve(.{ .back = 4 }) == null);
}

test "a newer picker makes the older one stale, and a close forgets the picker without an edit" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    try picker.show(&chat, &(try testPick(gpa, &.{"low"}, null, null)));
    try picker.show(&chat, &(try testPick(gpa, &.{"high"}, null, null)));
    try std.testing.expectEqual(@as(usize, 2), chat.sends.items.len);
    try std.testing.expectEqual(@as(usize, 0), chat.edits.items.len);
    try std.testing.expect(picker.resolve(.{ .close = 1 }) == null);
    try std.testing.expect(picker.resolve(.{ .close = 2 }) != null);

    picker.close();
    try std.testing.expect(!picker.isOpen());
    try std.testing.expect(picker.resolve(.{ .close = 2 }) == null);
    // A closed picker takes no edit.
    try picker.finish(&chat, "late");
    try std.testing.expectEqual(@as(usize, 0), chat.edits.items.len);
}

// A stale keyboard stays in the chat history, and a later process starts its
// count again, so a seed per process keeps the rows of one process apart from
// those of an earlier one.
test "a seed moves the serials past the keyboards of an earlier process" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();

    picker.seedSerials(1_000);
    try picker.show(&chat, &(try testPick(gpa, &.{"low"}, null, null)));
    try std.testing.expect(std.mem.indexOf(u8, chat.sends.items[0].markup.?, "\"callback_data\":\"row:1001:0\"") != null);
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1, .index = 0 } }) == null);
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1_001, .index = 0 } }) != null);

    picker.seedSerials(std.math.maxInt(u64));
    try picker.show(&chat, &(try testPick(gpa, &.{"low"}, null, null)));
    try std.testing.expect(std.mem.indexOf(u8, chat.sends.items[1].markup.?, "\"callback_data\":\"row:0:0\"") != null);
    try std.testing.expect(picker.resolve(.{ .close = 0 }) != null);
}

test "a long list shows the first rows alone, so the keyboard stays inside the bound" {
    const gpa = std.testing.allocator;
    var chat: Recorder = .{ .gpa = gpa };
    defer chat.deinit();
    var picker = Picker.init(gpa);
    defer picker.deinit();
    var rows: [rows_max + 5][]const u8 = undefined;
    for (&rows) |*row| row.* = "model";

    try picker.show(&chat, &(try testPick(gpa, &rows, null, null)));
    try std.testing.expectEqual(
        @as(usize, rows_max + 1),
        std.mem.count(u8, chat.sends.items[0].markup.?, "callback_data"),
    );
    try std.testing.expect(picker.resolve(.{ .row = .{ .serial = 1, .index = rows_max + 4 } }) != null);
}
