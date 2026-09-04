//! One attached bot: the bound chat, the poller task that reads it, and the
//! sender task that writes to it. The attachment reports to its owner through a
//! `Sink`, so it knows nothing of the session or the interface.
//!
//! The poller runs the long poll and hands every update of the bound chat to the
//! sink. The sender drains the outbound queue at the pace of the chat, so the
//! owner never waits for Telegram. Each task holds a client of its own, because
//! a client keeps the description of its last failure.
//!
//! A send returns at once, and the id of the new message arrives later on the
//! sender. A tracked send returns a handle, and an edit names that handle. The
//! queue holds the edit behind the send, and the newest text of a pending edit
//! replaces an older one, so a burst of state changes costs one edit. A
//! reaction names the id of a message of the chat.
//!
//! A close closes the queue, and the sender then drains what the queue still
//! holds inside the drain window less a reserve. A drain task watches it, ends
//! it at that point, sends the final message of the close inside the reserve on
//! its own, stops the poller, and reports `drained` to the sink, so the owner
//! learns the end without a wait. `destroy` awaits that task, so the last
//! message of the chat goes out before the memory does. `abort` ends the drain
//! at once instead, and the chat gets no last message.

const std = @import("std");

const ai = @import("ai");

const Client = @import("Client.zig");

const Attachment = @This();

/// The messages the queue holds before a send refuses. The sender runs at one
/// message per second, so this is minutes of backlog, and the owner never waits
/// on it.
const outbound_capacity = 256;

/// The time the sender has after a close to send what the queue still holds.
/// It covers the detach event and a few pending replies at one send per second.
const drain_ms_default = 5_000;

/// The part of the drain window that the final message of the close keeps for
/// itself. The sender ends at its start, so neither a full queue nor a send in
/// flight can hold the final message out of the chat.
const final_reserve_ms_default = 2_000;

/// The least time between two sends to one chat, because Telegram allows about
/// one message per second there.
const send_spacing_ms_default = 1_000;

/// The backoff of a failed poll or send: the initial wait doubled per failure
/// and capped. Every attempt is allowed, because the attachment stays until a
/// permanent failure or a detach ends it.
const backoff_default: ai.net.Retry = .{
    .attempts_max = std.math.maxInt(u32),
    .backoff_ms_initial = 500,
    .backoff_ms_max = 16_000,
};

/// The tracked messages the attachment remembers at once. A slot stays taken
/// while its send waits in the queue or in flight, or while an edit of its
/// message waits in the queue. One slot per queue item and one for the send in
/// flight cover every taken slot, and one more keeps a free slot for the next
/// reservation, so a reservation never fails and never takes a slot with work.
const tracked_capacity = outbound_capacity + 2;

/// The description Telegram sends for a text whose formatting it cannot parse.
const parse_failure_description = "can't parse entities";

gpa: std.mem.Allocator,
io: std.Io,
/// The bot token. Owned, and never part of any text this attachment produces.
token: []const u8,
/// The bot username without the `@`. Owned.
username: []const u8,
chat_id: i64,
/// The generation that every event of this attachment carries, so the owner
/// drops an event of an attachment that ended.
generation: u64,
sink: Sink,
pace: Pace,
poll_client: Client,
send_client: Client,
outbound_buffer: [outbound_capacity]Outbound,
outbound: std.Io.Queue(Outbound),
/// The messages that an edit can name. The owner and the sender both touch them,
/// so the mutex guards every access.
tracked: [tracked_capacity]Tracked,
tracked_mutex: std.Io.Mutex,
/// The slot after the last reserved one. A reservation scans from here, so the
/// slots take turns and a freed slot rests before the next message takes it.
tracked_next: usize,
/// The handle of the next tracked send. It starts at one, so no handle is zero.
handle_next: Handle,
poll_future: ?std.Io.Future(void),
send_future: ?std.Io.Future(void),
/// The drain task of the close, or null before it. It owns the end of the sender.
drain_future: ?std.Io.Future(void),
/// The message that the close named as the last one of the chat, or null. The
/// close writes it before it starts the drain task, which alone reads it.
final: ?Outbound.Send,
/// Whether the sender task ended. `destroy` polls it, so a sender stuck in a
/// call past the drain deadline gets canceled instead of awaited.
send_done: std.atomic.Value(bool),
/// The instant the sender must stop after a close, in milliseconds on the awake
/// clock, or zero while the attachment is open.
drain_deadline_ms: std.atomic.Value(i64),

/// What the attachment needs to start. It borrows every string and copies what
/// it keeps.
pub const Options = struct {
    /// The API origin. A test points it at a loopback server.
    base_url: []const u8 = Client.api_url,
    token: []const u8,
    username: []const u8,
    chat_id: i64,
    /// The head window of one call, and the source of the poll timeout.
    connect_ms: u64,
    generation: u64,
    sink: Sink,
    pace: Pace = .{},
};

/// The waits of the sender and the poller. The defaults fit Telegram, and a test
/// shortens them.
pub const Pace = struct {
    /// The drain window after a close.
    drain_ms: u64 = drain_ms_default,
    /// The part of the drain window kept for the final message.
    final_reserve_ms: u64 = final_reserve_ms_default,
    /// The least time between two sends.
    send_spacing_ms: u64 = send_spacing_ms_default,
    /// The backoff of a failed poll or send.
    backoff: ai.net.Retry = backoff_default,
};

/// Where the tasks report. The owner wraps each event into its own queue.
pub const Sink = struct {
    context: *anyopaque,
    /// Take one event. `error.Closed` tells the task that no one listens, so it
    /// ends.
    emit: *const fn (context: *anyopaque, event: Event) error{Closed}!void,
};

/// One report of the poller or the sender. The event owns its payload.
pub const Event = struct {
    generation: u64,
    payload: Payload,

    pub const Payload = union(enum) {
        /// A text message from the bound chat.
        message: Message,
        /// A message from the bound chat that holds no text: the id to answer.
        unreadable: i64,
        /// The first failure of a run of failures on one side.
        failed: Failure,
        /// The first success after a run of failures on one side.
        recovered: Side,
        /// Telegram refused one item for good, and the sender dropped it.
        send_rejected: Rejected,
        /// A permanent condition that ends the attachment.
        detach: Reason,
        /// The sender ended after a close, so a `destroy` waits for nothing.
        drained,
    };

    pub const Message = struct {
        id: i64,
        text: []u8,
    };

    pub const Failure = struct {
        side: Side,
        /// The name of the error.
        name: []const u8,
    };

    pub const Rejected = struct {
        kind: Kind,
        /// The description of Telegram, or empty.
        description: []u8,

        /// What the sender tried: a new message, an edit, or a reaction.
        pub const Kind = enum { message, edit, reaction };
    };

    pub const Side = enum { poll, send };

    pub const Reason = enum {
        /// 401: Telegram no longer knows the token.
        unauthorized,
        /// 403: the user blocked the bot.
        forbidden,
        /// 409: another instance polls the same bot.
        conflict,
        /// Any other 4xx on the poll: a repeat of the same request cannot succeed.
        poll_rejected,
    };

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        switch (self.payload) {
            .message => |message| gpa.free(message.text),
            .send_rejected => |rejected| gpa.free(rejected.description),
            .unreadable, .failed, .recovered, .detach, .drained => {},
        }
    }
};

/// The name of a tracked message on the side of the owner. The sender learns the
/// id of the message later, and an edit reaches it through the handle.
pub const Handle = u64;

/// One reaction of the bot on a message of the chat.
pub const Reaction = struct {
    message_id: i64,
    mark: Mark,

    /// The state of a Telegram message in the transcript, as the emoji that
    /// shows it. Telegram allows a fixed emoji list for a bot, and that list
    /// holds neither ✅ nor ❌.
    pub const Mark = enum {
        /// Received and not yet committed.
        seen,
        committed,
        dropped,

        fn emoji(self: Mark) []const u8 {
            return switch (self) {
                .seen => "👀",
                .committed => "👍",
                .dropped => "👎",
            };
        }
    };
};

/// The errors of a put into the outbound queue.
pub const SendError = error{ Closed, Canceled, QueueFull, OutOfMemory };

/// One item on its way to the chat.
const Outbound = union(enum) {
    /// A new message. The queue owns the text.
    send: Send,
    /// A pending edit of the tracked message with this handle. The text waits
    /// in the slot of the handle, so a later edit replaces it there and the
    /// sender takes the newest one.
    edit: Handle,
    react: Reaction,

    const Send = struct {
        text: []u8,
        options: Client.SendOptions,
        /// The slot that takes the id of the new message, or null for a message
        /// that no edit names later.
        handle: ?Handle,
    };
};

/// One message that an edit can name. The owner fills the handle, the sender
/// fills the id once the send returned it, and the pending edit waits between
/// them.
const Tracked = struct {
    /// The handle of the message, or zero for a slot no message took yet.
    handle: Handle,
    /// The id of the message, or null before the send returned or after it
    /// failed for good.
    message_id: ?i64,
    /// The newest text of a pending edit, or null while none waits. Owned.
    edit: ?[]u8,
    /// Whether the send of the message left the sender, delivered or dropped.
    settled: bool,

    const empty: Tracked = .{ .handle = 0, .message_id = null, .edit = null, .settled = true };

    /// Whether the next reservation can take this slot: no send waits for it,
    /// and no edit of its message waits in the queue.
    fn free(self: *const Tracked) bool {
        return self.settled and self.edit == null;
    }
};

/// What a pending edit found in its slot.
const Replace = enum {
    /// No edit waited, so the queue needs a marker for this one.
    opened,
    /// An older pending text gave its place up, and its marker stands.
    replaced,
    /// The slot belongs to another message, so the text drops.
    stale,
};

/// One edit that the sender resolved from its slot: the message and the text.
const Edit = struct {
    message_id: i64,
    text: []u8,
};

/// One call of the chat, as the sender delivers it.
const Delivery = union(enum) {
    send: Outbound.Send,
    edit: Edit,
    react: Reaction,

    fn kind(self: *const Delivery) Event.Rejected.Kind {
        return switch (self.*) {
            .send => .message,
            .edit => .edit,
            .react => .reaction,
        };
    }
};

/// Build an attachment on the heap, because the queue borrows its buffer. The
/// tasks start in `start`, after the owner recorded the pointer.
pub fn create(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !*Attachment {
    const self = try gpa.create(Attachment);
    errdefer gpa.destroy(self);
    const token = try gpa.dupe(u8, options.token);
    errdefer gpa.free(token);
    const username = try gpa.dupe(u8, options.username);
    errdefer gpa.free(username);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .token = token,
        .username = username,
        .chat_id = options.chat_id,
        .generation = options.generation,
        .sink = options.sink,
        .pace = options.pace,
        // The poll holds its connection open on purpose, so it takes the poll
        // window and not the configured one.
        .poll_client = .{
            .gpa = gpa,
            .io = io,
            .base_url = options.base_url,
            .token = token,
            .connect_ms = Client.pollConnectMs(options.connect_ms),
        },
        .send_client = .{
            .gpa = gpa,
            .io = io,
            .base_url = options.base_url,
            .token = token,
            .connect_ms = options.connect_ms,
        },
        .outbound_buffer = undefined,
        .outbound = undefined,
        .tracked = @splat(Tracked.empty),
        .tracked_mutex = .init,
        .tracked_next = 0,
        .handle_next = 1,
        .poll_future = null,
        .send_future = null,
        .drain_future = null,
        .final = null,
        .send_done = .init(false),
        .drain_deadline_ms = .init(0),
    };
    self.outbound = .init(&self.outbound_buffer);
    return self;
}

/// Start the poller and the sender.
pub fn start(self: *Attachment) !void {
    std.debug.assert(self.poll_future == null and self.send_future == null);
    self.send_future = try self.io.concurrent(runSender, .{self});
    errdefer self.close(null) catch unreachable;
    self.poll_future = try self.io.concurrent(runPoller, .{self});
}

/// Queue one message for the chat without a wait. The attachment copies `text`.
/// A full queue refuses with `error.QueueFull`, so the owner never blocks behind
/// the pace of the chat, and a closed attachment takes nothing.
pub fn send(self: *Attachment, text: []const u8, options: *const Client.SendOptions) SendError!void {
    try self.queueSend(text, options, null);
}

/// Queue one message that a later edit names, and return its handle. The sender
/// records the id of the message under the handle once the send returned it.
pub fn sendTracked(
    self: *Attachment,
    text: []const u8,
    options: *const Client.SendOptions,
) SendError!Handle {
    const handle = self.reserveHandle();
    self.queueSend(text, options, handle) catch |err| {
        self.settle(handle);
        return err;
    };
    return handle;
}

/// Replace the text of the tracked message `handle` with `text`, once it and
/// every item before it went out. A pending edit of the same message gives its
/// text up for this one, so the chat sees the newest state and skips the older
/// ones. An edit of a message whose slot another message took drops in silence.
pub fn edit(self: *Attachment, handle: Handle, text: []const u8) SendError!void {
    const copy = try self.gpa.dupe(u8, text);
    switch (self.replaceEdit(handle, copy)) {
        .stale => return self.gpa.free(copy),
        // The marker of the older text stands, and the sender takes the newest
        // text when it reaches it.
        .replaced => return,
        .opened => {},
    }
    self.queueOne(.{ .edit = handle }) catch |err| {
        if (self.takeEdit(handle)) |pending| self.gpa.free(pending.text);
        return err;
    };
}

/// Queue one reaction on the message `message_id` of the chat.
pub fn react(self: *Attachment, message_id: i64, mark: Reaction.Mark) SendError!void {
    try self.queueOne(.{ .react = .{ .message_id = message_id, .mark = mark } });
}

fn queueSend(
    self: *Attachment,
    text: []const u8,
    options: *const Client.SendOptions,
    handle: ?Handle,
) SendError!void {
    const copy = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(copy);
    try self.queueOne(.{ .send = .{ .text = copy, .options = options.*, .handle = handle } });
}

fn queueOne(self: *Attachment, item: Outbound) SendError!void {
    const items = [1]Outbound{item};
    const count = self.outbound.put(self.io, &items, 0) catch |err| switch (err) {
        error.Closed => return error.Closed,
        error.Canceled => return error.Canceled,
    };
    if (count == 0) return error.QueueFull;
}

/// Take the next handle and give it the next free slot. A slot with a send or an
/// edit still waiting stays with its message, so a fast run of turns cannot
/// leave an older activity message without its summary.
fn reserveHandle(self: *Attachment) Handle {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const handle = self.handle_next;
    self.handle_next += 1;
    for (0..tracked_capacity) |step| {
        const index = (self.tracked_next + step) % tracked_capacity;
        const slot = &self.tracked[index];
        if (!slot.free()) continue;
        slot.* = .{ .handle = handle, .message_id = null, .edit = null, .settled = false };
        self.tracked_next = index + 1;
        return handle;
    }
    // The slots outnumber the items that can hold one, so the scan always ends
    // on a free slot while the sender runs.
    unreachable;
}

/// Put `text` into the slot of `handle` as its pending edit, and report what it
/// found there. The caller drops a stale text.
fn replaceEdit(self: *Attachment, handle: Handle, text: []u8) Replace {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return .stale;
    const found: Replace = if (slot.edit != null) .replaced else .opened;
    if (slot.edit) |old| self.gpa.free(old);
    slot.edit = text;
    return found;
}

/// Take the pending edit of `handle` with the id of its message, or null when
/// none waits or the message has no id. A text with no id to reach drops here,
/// because its send failed for good.
fn takeEdit(self: *Attachment, handle: Handle) ?Edit {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return null;
    const text = slot.edit orelse return null;
    slot.edit = null;
    const message_id = slot.message_id orelse {
        self.gpa.free(text);
        return null;
    };
    return .{ .message_id = message_id, .text = text };
}

/// Record the id that the send of `handle` returned.
fn recordMessageId(self: *Attachment, handle: Handle, message_id: i64) void {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return;
    slot.message_id = message_id;
}

/// Record that the send of `handle` left the sender, delivered or dropped, so a
/// slot with no pending edit is free again.
fn settle(self: *Attachment, handle: Handle) void {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return;
    slot.settled = true;
}

/// The slot that `handle` holds, or null once another message took it. The
/// caller holds the lock.
fn slotOf(self: *Attachment, handle: Handle) ?*Tracked {
    for (&self.tracked) |*slot| if (slot.handle == handle) return slot;
    return null;
}

/// Whether `close` ran.
fn closed(self: *const Attachment) bool {
    return self.drain_deadline_ms.load(.acquire) != 0;
}

/// End the attachment: let the sender drain the queue inside the drain window
/// less the reserve, then send `final` as the last message of the chat inside
/// the reserve. The attachment copies `final`, and a copy that fails closes
/// without it. The drain task does the rest and reports `drained`, so the owner
/// never waits on a cancel. A second close changes nothing.
pub fn close(self: *Attachment, final: ?[]const u8) error{OutOfMemory}!void {
    if (self.closed()) return;
    defer {
        self.drain_deadline_ms.store(
            self.nowMs() + @as(i64, @intCast(self.pace.drain_ms)),
            .release,
        );
        self.outbound.close(self.io);
        // A drain task that cannot start runs inline, so the sender still ends
        // at the deadline and the owner still learns it.
        self.drain_future = self.io.concurrent(runDrain, .{self}) catch null;
        if (self.drain_future == null) self.runDrain();
    }
    const text = final orelse return;
    self.final = .{
        .text = try self.gpa.dupe(u8, text),
        .options = .{ .disable_notification = true },
        .handle = null,
    };
}

/// End the attachment now and free everything. The drain deadline moves to this
/// instant, so the sender drops what the queue holds and the final message never
/// goes out, and the cancel ends a send in flight. The chat then learns nothing
/// of the end.
pub fn abort(self: *Attachment) void {
    self.close(null) catch unreachable;
    self.drain_deadline_ms.store(@max(1, self.nowMs()), .release);
    if (self.drain_future) |*future| {
        future.cancel(self.io);
        self.drain_future = null;
    }
    self.destroy();
}

/// Wait for the drain task, then free everything. The wait is bounded by the
/// drain window from the close, so a dead network cannot hold the exit.
pub fn destroy(self: *Attachment) void {
    self.close(null) catch unreachable;
    if (self.drain_future) |*future| {
        future.await(self.io);
        self.drain_future = null;
    }
    var batch: [outbound_capacity]Outbound = undefined;
    while (true) {
        const count = self.outbound.get(self.io, &batch, 0) catch break;
        if (count == 0) break;
        for (batch[0..count]) |item| freeOutbound(self.gpa, &item);
    }
    for (&self.tracked) |*slot| if (slot.edit) |text| self.gpa.free(text);
    if (self.final) |final| self.gpa.free(final.text);
    self.gpa.free(self.username);
    self.gpa.free(self.token);
    self.gpa.destroy(self);
}

fn freeOutbound(gpa: std.mem.Allocator, item: *const Outbound) void {
    switch (item.*) {
        .send => |send_item| gpa.free(send_item.text),
        .edit, .react => {},
    }
}

/// The drain task: wait for the sender until the reserve of the final message
/// starts, end it, send the final message inside the reserve, stop the poller,
/// and report. A sender still in a call at the reserve is canceled, so a send in
/// flight at the close cannot hold the final message back. The poller stops last
/// and on this task, so its cancel never holds the owner or the final message.
fn runDrain(self: *Attachment) void {
    // The poll bounds the lag after the sender ends. A send takes network time,
    // so 50 ms costs nothing perceptible.
    while (!self.send_done.load(.acquire)) {
        const remaining = self.drainRemainingMs() orelse 0;
        if (remaining <= self.pace.final_reserve_ms) break;
        const wait = @min(remaining - self.pace.final_reserve_ms, 50);
        self.io.sleep(.fromMilliseconds(@intCast(wait)), .awake) catch break;
    }
    if (self.send_future) |*future| {
        future.cancel(self.io);
        self.send_future = null;
    }
    if (self.final) |final| {
        self.final = null;
        defer self.gpa.free(final.text);
        self.deliverFinal(&final);
    }
    if (self.poll_future) |*future| {
        future.cancel(self.io);
        self.poll_future = null;
    }
    self.emit(.drained) catch {};
}

/// Send the final message of the close inside the time left. The sender ended,
/// so this task alone uses its client, and every call is bounded by that time. A
/// 429 and a transient failure wait and try again inside it. The message skips
/// the pacing sleep, because the reserve is its whole room and a 429 answers a
/// send that came early.
fn deliverFinal(self: *Attachment, final: *const Outbound.Send) void {
    const client = &self.send_client;
    var failures: u32 = 0;
    // The loop ends on a send, a permanent failure, or the end of the window,
    // and every other pass waits on the network.
    while (true) {
        const remaining = self.drainRemainingMs() orelse unreachable;
        if (remaining == 0) return;
        client.connect_ms = if (client.connect_ms == 0) remaining else @min(client.connect_ms, remaining);
        _ = client.sendMessage(self.chat_id, final.text, &final.options) catch |err| switch (err) {
            error.RateLimited => {
                self.pause(.{ .wait_ms = client.retry_after_s *| std.time.ms_per_s }) catch return;
                continue;
            },
            error.Unavailable, error.MalformedReply, error.OutOfMemory => {
                failures +|= 1;
                self.pause(.{ .wait_ms = self.pace.backoff.backoffMs(.{ .attempt = failures }) }) catch return;
                continue;
            },
            error.Canceled,
            error.Rejected,
            error.Unauthorized,
            error.Forbidden,
            error.Conflict,
            => return,
        };
        return;
    }
}

fn emit(self: *Attachment, payload: Event.Payload) error{Closed}!void {
    return self.sink.emit(self.sink.context, .{ .generation = self.generation, .payload = payload });
}

fn nowMs(self: *const Attachment) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

/// The time left before the drain deadline, or null while the attachment is
/// open. Zero once the deadline passed.
fn drainRemainingMs(self: *const Attachment) ?u64 {
    const deadline = self.drain_deadline_ms.load(.acquire);
    if (deadline == 0) return null;
    return @intCast(@max(0, deadline - self.nowMs()));
}

/// The longest sleep between two reads of the drain deadline. A close during a
/// long backoff then wakes the sender inside this bound instead of after the
/// whole window.
const pause_step_ms = 100;

/// One sleep of a task: how long, and how much of the drain window it must leave
/// for the final message.
const Pause = struct {
    wait_ms: u64,
    reserve_ms: u64 = 0,
};

/// Sleep `wait_ms`, or less when the drain deadline less `reserve_ms` comes
/// first, also when the close arrives during the sleep. A cancel ends the task,
/// so it propagates.
fn pause(self: *const Attachment, options: Pause) error{Canceled}!void {
    var left = options.wait_ms;
    while (left > 0) {
        var step = @min(left, pause_step_ms);
        if (self.drainRemainingMs()) |remaining| step = @min(step, remaining -| options.reserve_ms);
        if (step == 0) return;
        self.io.sleep(.fromMilliseconds(@intCast(step)), .awake) catch return error.Canceled;
        left -= step;
    }
}

/// The poller: confirm the updates from before the attach, then read the chat
/// until a cancel or a permanent failure. An update from another chat drops in
/// silence. A failed poll waits and tries again, and the first failure and the
/// recovery each report once.
fn runPoller(self: *Attachment) void {
    self.pollUntilEnd() catch {};
}

fn pollUntilEnd(self: *Attachment) error{ Closed, Canceled }!void {
    var state: PollState = .{};
    var failing = false;
    var failures: u32 = 0;
    // The loop ends on a cancel, a closed sink, or a permanent failure, and
    // every other pass waits on the network.
    while (true) {
        self.pollOnce(&state) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return error.Closed,
            error.Unauthorized => return self.emit(.{ .detach = .unauthorized }),
            error.Forbidden => return self.emit(.{ .detach = .forbidden }),
            error.Conflict => return self.emit(.{ .detach = .conflict }),
            error.Rejected => return self.emit(.{ .detach = .poll_rejected }),
            error.RateLimited => {
                try self.pause(.{ .wait_ms = self.poll_client.retry_after_s *| std.time.ms_per_s });
                continue;
            },
            error.Unavailable, error.MalformedReply, error.OutOfMemory => {
                if (!failing) {
                    failing = true;
                    try self.emit(.{ .failed = .{ .side = .poll, .name = @errorName(err) } });
                }
                failures +|= 1;
                try self.pause(.{ .wait_ms = self.pace.backoff.backoffMs(.{ .attempt = failures }) });
                continue;
            },
        };
        if (failing) {
            failing = false;
            failures = 0;
            try self.emit(.{ .recovered = .poll });
        }
    }
}

/// Where the poller stands: the steps before the first long poll, and the
/// offset of the next one.
const PollState = struct {
    webhook_deleted: bool = false,
    confirmed: bool = false,
    offset: ?i64 = null,
};

/// One step of the poller: the webhook removal, then the confirmation of the
/// waiting updates, then one long poll whose updates go to the sink.
fn pollOnce(self: *Attachment, state: *PollState) (Client.Error || error{Closed})!void {
    const client = &self.poll_client;
    if (!state.webhook_deleted) {
        try client.deleteWebhook();
        state.webhook_deleted = true;
    }
    if (!state.confirmed) {
        const newest = try client.getUpdates(-1, 0);
        defer newest.deinit(self.gpa);
        if (newest.items.len > 0) state.offset = newest.items[newest.items.len - 1].update_id + 1;
        state.confirmed = true;
        return;
    }
    const updates = try client.getUpdates(state.offset, Client.pollTimeoutSeconds(client.connect_ms));
    defer updates.deinit(self.gpa);
    for (updates.items) |update| {
        state.offset = update.update_id + 1;
        const message = update.message orelse continue;
        if (message.chat_id != self.chat_id) continue;
        const text = message.text orelse {
            try self.emit(.{ .unreadable = message.message_id });
            continue;
        };
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        try self.emit(.{ .message = .{ .id = message.message_id, .text = copy } });
    }
}

/// The sender: take one item at a time and deliver it. A 429 waits the named
/// seconds. A transient failure waits and tries the same item again, and the
/// first failure and the recovery each report once. Any other 4xx drops the
/// item with one report. A 401, a 403, and a 409 end the attachment. After a
/// close the queue drains inside the window less the reserve of the final
/// message, and the rest drops.
fn runSender(self: *Attachment) void {
    defer self.send_done.store(true, .release);
    var state: SendState = .{};
    self.sendUntilClosed(&state) catch {};
}

/// The state of the sender across its messages: the failure run and the pace.
const SendState = struct {
    failing: bool = false,
    failures: u32 = 0,
    /// When the last send went out, or null before the first.
    sent_ms: ?i64 = null,
};

/// The sender before the close: every item of the queue, until the queue closes
/// and drains, a cancel, or a permanent failure ends it.
fn sendUntilClosed(
    self: *Attachment,
    state: *SendState,
) error{ Closed, Canceled, Detached }!void {
    // The loop ends when the queue closes and drains, on a cancel, or on a
    // permanent failure, and every other pass waits on the queue or the network.
    while (true) {
        var batch: [1]Outbound = undefined;
        const count = self.outbound.get(self.io, &batch, 1) catch |err| switch (err) {
            error.Closed => return error.Closed,
            error.Canceled => return error.Canceled,
        };
        std.debug.assert(count == 1);
        const item = batch[0];
        defer freeOutbound(self.gpa, &item);
        switch (item) {
            .send => |send_item| {
                // The slot settles whether the send went out or dropped, so a
                // failed send cannot pin it.
                defer if (send_item.handle) |handle| self.settle(handle);
                try self.deliver(state, .{ .send = send_item });
            },
            // The marker stands for the newest text of the slot, and it takes
            // one text alone: an edit that arrives while this one goes out
            // opens a marker of its own, so it keeps its place behind the items
            // queued before it.
            .edit => |handle| if (self.takeEdit(handle)) |pending| {
                defer self.gpa.free(pending.text);
                try self.deliver(state, .{ .edit = pending });
            },
            .react => |reaction| try self.deliver(state, .{ .react = reaction }),
        }
    }
}

/// One call of the chat for `delivery`. A tracked send records the id of its
/// message, so a later edit finds it.
fn callChat(self: *Attachment, delivery: *const Delivery) Client.Error!void {
    const client = &self.send_client;
    switch (delivery.*) {
        .send => |send_item| {
            const message_id = try client.sendMessage(self.chat_id, send_item.text, &send_item.options);
            if (send_item.handle) |handle| self.recordMessageId(handle, message_id);
        },
        .edit => |pending| try client.editMessageText(self.chat_id, pending.message_id, pending.text),
        .react => |reaction| try client.setMessageReaction(
            self.chat_id,
            reaction.message_id,
            reaction.mark.emoji(),
        ),
    }
}

/// Deliver one item, with the waits and the retries of the pace. The item drops
/// when Telegram rejects it for good, or when the drain window less the reserve
/// of the final message leaves no room for it. No sleep reaches into that
/// reserve. A message whose formatting Telegram cannot parse goes again as plain
/// text, so the ordered queue never stalls on one block.
fn deliver(
    self: *Attachment,
    state: *SendState,
    delivery_in: Delivery,
) error{ Closed, Canceled, Detached }!void {
    var delivery = delivery_in;
    const client = &self.send_client;
    const reserve = self.pace.final_reserve_ms;
    // The loop ends on a send, a drop, or an end of the task, and every other
    // pass waits on the network.
    while (true) {
        if (state.sent_ms) |last| {
            const elapsed: u64 = @intCast(@max(0, self.nowMs() - last));
            if (elapsed < self.pace.send_spacing_ms)
                try self.pause(.{ .wait_ms = self.pace.send_spacing_ms - elapsed, .reserve_ms = reserve });
        }
        // The check comes after the pacing sleep, so a message that waited up to
        // the reserve drops instead of eating into it.
        if (self.drainRemainingMs()) |remaining| {
            if (remaining <= reserve) return;
        }
        self.callChat(&delivery) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Unauthorized => return self.detach(.unauthorized),
            error.Forbidden => return self.detach(.forbidden),
            error.Conflict => return self.detach(.conflict),
            error.RateLimited => {
                try self.pause(.{ .wait_ms = client.retry_after_s *| std.time.ms_per_s, .reserve_ms = reserve });
                continue;
            },
            error.Rejected => {
                if (delivery == .send and delivery.send.options.parse_mode != null and
                    std.mem.indexOf(u8, client.description(), parse_failure_description) != null)
                {
                    delivery.send.options.parse_mode = null;
                    state.sent_ms = self.nowMs();
                    continue;
                }
                // A copy that fails costs the description alone, not the report.
                const text: []u8 = self.gpa.dupe(u8, client.description()) catch &.{};
                self.emit(.{ .send_rejected = .{
                    .kind = delivery.kind(),
                    .description = text,
                } }) catch |emit_error| {
                    self.gpa.free(text);
                    return emit_error;
                };
                return;
            },
            error.Unavailable, error.MalformedReply, error.OutOfMemory => {
                if (!state.failing) {
                    state.failing = true;
                    try self.emit(.{ .failed = .{ .side = .send, .name = @errorName(err) } });
                }
                state.failures +|= 1;
                try self.pause(.{
                    .wait_ms = self.pace.backoff.backoffMs(.{ .attempt = state.failures }),
                    .reserve_ms = reserve,
                });
                continue;
            },
        };
        state.sent_ms = self.nowMs();
        if (state.failing) {
            state.failing = false;
            state.failures = 0;
            try self.emit(.{ .recovered = .send });
        }
        return;
    }
}

/// Report a permanent condition and end the sender.
fn detach(self: *Attachment, reason: Event.Reason) error{ Closed, Detached } {
    try self.emit(.{ .detach = reason });
    return error.Detached;
}

const testing = @import("testing.zig");

const Collector = testing.Collector(Event, Sink);

const ok_true = "{\"ok\":true,\"result\":true}";
const ok_empty = "{\"ok\":true,\"result\":[]}";
const ok_sent = "{\"ok\":true,\"result\":{\"message_id\":1}}";

const test_drain_ms = testing.pace.drain_ms;

/// The poller script of a quiet chat: the webhook goes, the confirmation finds
/// nothing, and the long poll then waits without an answer.
const quiet_scripts = [_]testing.Script{
    .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
    .{ .method = "getUpdates", .replies = &.{.{ .body = ok_empty }} },
};

fn testAttachment(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *const testing.Server,
    url_buffer: []u8,
    collector: *Collector,
) !*Attachment {
    return create(gpa, io, &.{
        .base_url = server.url(url_buffer),
        .token = "42:secret",
        .username = "drinky_bot",
        .chat_id = 99,
        .connect_ms = 60_000,
        .generation = 7,
        .sink = collector.sink(),
        .pace = testing.pace,
    });
}

test "the poller confirms the old updates, gates on the chat, and reports each message" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{
            .method = "getUpdates",
            .replies = &.{
                // The confirmation returns the newest waiting update alone.
                .{ .body =
                \\{"ok":true,"result":[{"update_id":40,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"old"}}]}
                },
                .{ .body =
                \\{"ok":true,"result":[
                \\{"update_id":41,"message":{"message_id":2,"date":0,"chat":{"id":99,"type":"private"},"text":"hello"}},
                \\{"update_id":42,"message":{"message_id":3,"date":0,"chat":{"id":-5,"type":"group"},"text":"other chat"}},
                \\{"update_id":43,"message":{"message_id":4,"date":0,"chat":{"id":99,"type":"private"},"sticker":{}}}
                \\]}
                },
            },
        },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    try collector.waitFor(2);
    try attachment.close(null);
    try server.finish();
    try std.testing.expectEqualStrings("/bot42:secret/deleteWebhook", server.requests.items[0].path);
    try std.testing.expectEqualStrings(
        "{\"offset\":-1,\"timeout\":0,\"allowed_updates\":[\"message\"]}",
        server.requests.items[1].body,
    );
    // The poll starts after the confirmed update, and it waits five seconds
    // under the head window.
    try std.testing.expectEqualStrings(
        "{\"offset\":41,\"timeout\":55,\"allowed_updates\":[\"message\"]}",
        server.requests.items[2].body,
    );
    const events = collector.events.items;
    try std.testing.expectEqual(@as(u64, 7), events[0].generation);
    try std.testing.expectEqual(@as(i64, 2), events[0].payload.message.id);
    try std.testing.expectEqualStrings("hello", events[0].payload.message.text);
    try std.testing.expectEqual(@as(i64, 4), events[1].payload.unreadable);
}

// The configured head window bounds the head of one provider request. A long
// poll holds its connection open on purpose, so a short configured window must
// not shorten it: a poll that returns at once asks again every second, and
// Telegram answers that with a 429.
test "a short configured window does not shorten the long poll" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts);
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try create(gpa, io, &.{
        .base_url = server.url(&url_buffer),
        .token = "42:secret",
        .username = "drinky_bot",
        .chat_id = 99,
        .connect_ms = 5_000,
        .generation = 7,
        .sink = collector.sink(),
        .pace = testing.pace,
    });
    defer attachment.destroy();
    try attachment.start();

    // The webhook removal, the confirmation, and then the long poll.
    try server.waitForRequests(3);
    try server.finish();
    try std.testing.expectEqual(
        @as(u64, Client.poll_connect_ms_min),
        attachment.poll_client.connect_ms,
    );
    // The send keeps the configured window, because a send is a short call.
    try std.testing.expectEqual(@as(u64, 5_000), attachment.send_client.connect_ms);
    try std.testing.expect(std.mem.indexOf(u8, server.requests.items[2].body, "\"timeout\":25,") != null);
}

test "a failed poll reports once, recovers once, and a 409 detaches" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = ok_empty },
            .{ .status = 502, .body = "" },
            .{ .status = 503, .body = "" },
            .{ .body = ok_empty },
            .{ .status = 409, .body = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict\"}" },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    try collector.waitFor(3);
    try server.finish();
    const events = collector.events.items;
    try std.testing.expectEqual(Event.Side.poll, events[0].payload.failed.side);
    try std.testing.expectEqualStrings("Unavailable", events[0].payload.failed.name);
    try std.testing.expectEqual(Event.Side.poll, events[1].payload.recovered);
    try std.testing.expectEqual(Event.Reason.conflict, events[2].payload.detach);
}

test "the sender delivers in order, retries a transient failure, and drops a rejected message" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .status = 500, .body = "" },
            .{ .body = ok_sent },
            .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: message text is empty\"}" },
            .{ .body = ok_sent },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    try attachment.send("first", &.{ .disable_notification = true });
    try attachment.send("<b>second", &.{ .reply_to = 5 });
    try attachment.send("third", &.{});
    try collector.waitFor(3);
    try server.finish();
    var sends: [4][]const u8 = undefined;
    var count: usize = 0;
    for (server.requests.items) |request| {
        if (!std.mem.endsWith(u8, request.path, "/sendMessage")) continue;
        sends[count] = request.body;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"first\"") != null);
    // The same message goes again after the transient failure.
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[2], "\"reply_parameters\":{\"message_id\":5}") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[3], "\"text\":\"third\"") != null);
    const events = collector.events.items;
    try std.testing.expectEqual(Event.Side.send, events[0].payload.failed.side);
    try std.testing.expectEqual(Event.Side.send, events[1].payload.recovered);
    try std.testing.expectEqual(Event.Rejected.Kind.message, events[2].payload.send_rejected.kind);
    try std.testing.expectEqualStrings(
        "Bad Request: message text is empty",
        events[2].payload.send_rejected.description,
    );
}

// A formatted block that Telegram cannot parse must not stall the queue behind
// it, and the chat must still get its text. The same bytes go again without a
// parse mode, and the block behind it follows.
test "a message whose formatting fails to parse goes again as plain text" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: can't parse entities\"}" },
            .{ .body = ok_sent },
            .{ .body = ok_sent },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    try attachment.send("<b>broken", &.{ .parse_mode = "HTML" });
    try attachment.send("next", &.{});
    try server.waitForSends(3);
    try server.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"parse_mode\":\"HTML\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"<b>broken\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "parse_mode") == null);
    try std.testing.expect(std.mem.indexOf(u8, sends[2], "\"text\":\"next\"") != null);
    // The resend is no rejection, so nothing reports.
    try std.testing.expectEqual(@as(usize, 0), collector.events.items.len);
}

test "an edit waits behind its tracked send, and the newest text replaces a pending one" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}", .delay_ms = 100 },
        } },
        .{ .method = "editMessageText", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true } } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    const handle = try attachment.sendTracked("Thinking", &.{ .disable_notification = true });
    // Both edits queue while the send still waits for its reply, so one edit
    // goes out with the newest text.
    try attachment.edit(handle, "Writing");
    try attachment.edit(handle, "Running: bash");
    // The sender took that text once its edit arrived, so the next edit opens
    // a pending one of its own.
    _ = try server.waitForRequest("/editMessageText", 0);
    try attachment.edit(handle, "Tools: 1 call");
    _ = try server.waitForRequest("/editMessageText", 1);
    try server.finish();
    var edits: [2][]const u8 = undefined;
    var count: usize = 0;
    for (server.requests.items) |request| {
        if (!std.mem.endsWith(u8, request.path, "/editMessageText")) continue;
        edits[count] = request.body;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Running: bash\"}",
        edits[0],
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Tools: 1 call\"}",
        edits[1],
    );
}

// The marker of an edit takes one text alone. An edit that arrives while the
// marker goes out queues behind the items before it, so an answer that queued
// before the summary of its turn reaches the chat before that summary.
test "an edit that arrives during an edit keeps its place in the queue" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
            .{ .body = ok_sent },
        } },
        .{ .method = "editMessageText", .replies = &.{
            .{ .body = ok_true, .delay_ms = 150 },
            .{ .body = ok_true },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    const handle = try attachment.sendTracked("Thinking", &.{});
    try attachment.edit(handle, "Writing");
    // The first edit is in flight, and its reply waits.
    _ = try server.waitForRequest("/editMessageText", 0);
    try attachment.send("answer", &.{});
    try attachment.edit(handle, "Tools: 0 calls");
    _ = try server.waitForRequest("/editMessageText", 1);
    try server.finish();
    var order: [4][]const u8 = undefined;
    var count: usize = 0;
    for (server.requests.items) |request| {
        if (std.mem.endsWith(u8, request.path, "/getUpdates")) continue;
        if (std.mem.endsWith(u8, request.path, "/deleteWebhook")) continue;
        order[count] = request.body;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expect(std.mem.indexOf(u8, order[0], "\"text\":\"Thinking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, order[1], "\"text\":\"Writing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, order[2], "\"text\":\"answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, order[3], "\"text\":\"Tools: 0 calls\"") != null);
}

// A slot with a send or an edit still waiting stays with its message, however
// many tracked sends follow. The summary of a turn then reaches its activity
// message after a fast run of later turns.
test "a tracked message with pending work keeps its slot through later tracked sends" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const later_sends = 12;
    var replies: [later_sends + 1]testing.Reply = undefined;
    replies[0] = .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}", .delay_ms = 100 };
    for (replies[1..]) |*reply| reply.* = .{ .body = ok_sent };
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &replies },
        .{ .method = "editMessageText", .replies = &.{.{ .body = ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    const first = try attachment.sendTracked("Thinking", &.{});
    try attachment.edit(first, "Tools: 0 calls");
    for (0..later_sends) |_| _ = try attachment.sendTracked("Thinking", &.{});
    const summary = try server.waitForRequest("/editMessageText", 0);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Tools: 0 calls\"}",
        summary,
    );
    try server.finish();
}

// An edit can name a message whose send Telegram refused, so no id exists for
// it. The edit drops in silence, because the report of the send already told the
// owner, and the item behind it still goes out.
test "an edit of a message that never went out drops" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: message text is empty\"}" },
        } },
        .{ .method = "setMessageReaction", .replies = &.{.{ .body = ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    const handle = try attachment.sendTracked("", &.{});
    try attachment.edit(handle, "Writing");
    try attachment.react(7, .seen);
    try collector.waitFor(1);
    try server.finish();
    try std.testing.expectEqual(Event.Rejected.Kind.message, collector.events.items[0].payload.send_rejected.kind);
    var reactions: usize = 0;
    for (server.requests.items) |request| {
        try std.testing.expect(!std.mem.endsWith(u8, request.path, "/editMessageText"));
        if (!std.mem.endsWith(u8, request.path, "/setMessageReaction")) continue;
        reactions += 1;
        try std.testing.expectEqualStrings(
            "{\"chat_id\":99,\"message_id\":7,\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"👀\"}]}",
            request.body,
        );
    }
    try std.testing.expectEqual(@as(usize, 1), reactions);
}

test "a 403 on a send detaches" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .status = 403, .body = "{\"ok\":false,\"error_code\":403,\"description\":\"Forbidden\"}" },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    try attachment.send("hello", &.{});
    try collector.waitFor(1);
    try server.finish();
    try std.testing.expectEqual(Event.Reason.forbidden, collector.events.items[0].payload.detach);
}

test "a close drains the queue, sends the final message last, and then refuses a send" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{ .{ .body = ok_sent }, .{ .body = ok_sent } } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try server.waitForRequests(2);

    try attachment.send("queued", &.{});
    try attachment.close("final");
    try std.testing.expectError(error.Closed, attachment.send("too late", &.{}));
    // The drain reports its end without a wait of the owner, and the destroy
    // then waits for nothing. Both messages went out in order before it.
    try collector.waitFor(1);
    try std.testing.expect(collector.events.items[0].payload == .drained);
    destroyed = true;
    attachment.destroy();
    try server.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"queued\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"disable_notification\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), collector.events.items.len);
}

test "a message whose pacing sleep crosses into the reserve drops" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{ .{ .body = ok_sent }, .{ .body = ok_sent } } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    // The spacing after the first send ends inside the reserve of the drain, so
    // the second message must drop after its sleep, not go out inside the reserve.
    var pace = testing.pace;
    pace.send_spacing_ms = test_drain_ms - 100;
    const attachment = try create(gpa, io, &.{
        .base_url = server.url(&url_buffer),
        .token = "42:secret",
        .username = "drinky_bot",
        .chat_id = 99,
        .connect_ms = 60_000,
        .generation = 7,
        .sink = collector.sink(),
        .pace = pace,
    });
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try server.waitForRequests(2);

    try attachment.send("first", &.{});
    try server.waitForSends(1);
    try attachment.send("second", &.{});
    try attachment.close("final");
    destroyed = true;
    attachment.destroy();
    try server.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
}

test "a full queue refuses a send, and the final message keeps its reserve of the drain" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The first reply waits, so the sender holds the first message while the
    // queue fills, and no ordinary message after it can end its pacing sleep
    // before the reserve of the final message.
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = ok_sent, .delay_ms = 200 },
            .{ .body = ok_sent },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    var pace = testing.pace;
    pace.send_spacing_ms = 10 * test_drain_ms;
    const attachment = try create(gpa, io, &.{
        .base_url = server.url(&url_buffer),
        .token = "42:secret",
        .username = "drinky_bot",
        .chat_id = 99,
        .connect_ms = 60_000,
        .generation = 7,
        .sink = collector.sink(),
        .pace = pace,
    });
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try server.waitForRequests(2);

    try attachment.send("first", &.{});
    try server.waitForSends(1);
    // The sender took the first message, so the queue takes the capacity and
    // refuses the one after it without a wait.
    for (0..outbound_capacity) |_| try attachment.send("ordinary", &.{});
    try std.testing.expectError(error.QueueFull, attachment.send("one too many", &.{}));

    // The ordinary messages cannot go out inside the window less the reserve,
    // so they drop, and the final message still ends the chat.
    try attachment.close("final");
    destroyed = true;
    attachment.destroy();
    try server.finish();
    var buffer: [outbound_capacity + 2][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
}

test "a send in flight at the close cannot hold the final message back" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The reply to the first send comes after the reserve of the final message
    // started, so the sender still waits on it when the drain must end it.
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = ok_sent, .delay_ms = test_drain_ms - 100 },
            .{ .body = ok_sent },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try server.waitForRequests(2);

    try attachment.send("slow", &.{});
    try server.waitForSends(1);
    try attachment.close("final");
    destroyed = true;
    attachment.destroy();
    try server.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"slow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
}

// An exit key during the drain must free the terminal at once. The abort ends a
// send in flight, drops the queue, and sends no final message, so no message can
// reach the chat after it.
test "an abort ends the drain at once and sends no final message" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The reply to the first send never comes, so the sender holds it when the
    // abort arrives.
    var server = try testing.Server.init(gpa, io, &quiet_scripts);
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    var ended = false;
    defer if (!ended) attachment.destroy();
    try attachment.start();
    try attachment.send("in flight", &.{});
    try attachment.send("queued", &.{});
    try server.waitForSends(1);
    // The poller made its scripted calls, so the abort cannot leave one unmade.
    _ = try server.waitForRequest("/getUpdates", 0);

    try attachment.close("final");
    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    ended = true;
    attachment.abort();
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    // The drain window is 300 ms in the tests, and the abort ends well inside it.
    try std.testing.expect(elapsed_ms < test_drain_ms - 100);
    try std.testing.expectEqual(@as(usize, 1), server.sendCount());
    try server.finish();
}

test "a dead network cannot hold the drain past its deadline" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // No script answers a send, so the call waits for its head.
    var server = try testing.Server.init(gpa, io, &quiet_scripts);
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try attachment.send("never lands", &.{});
    try server.waitForRequests(3);

    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try attachment.close("never lands either");
    destroyed = true;
    attachment.destroy();
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms >= test_drain_ms - 50);
    try std.testing.expect(elapsed_ms < test_drain_ms + 2_000);
    try server.finish();
}
