//! One attached bot: the bound chat, the poller task that reads it, the sender
//! task that writes to it, and the answerer task that answers its taps. The
//! attachment reports to its owner through a `Sink`, so it knows nothing of the
//! session or the interface.
//!
//! The poller registers the commands, runs the long poll, and hands every
//! message and every tap of the bound chat to the sink. The sender drains the
//! outbound queue at the pace of the chat, so the owner never waits for
//! Telegram. The answerer drains the answers to the taps with no pace, because
//! a tap expires after a few seconds and an answer is no message of the chat.
//! Each task holds a client of its own, because a client keeps the description
//! of its last failure.
//!
//! A send returns at once, and the id of the new message arrives later on the
//! sender. A tracked send returns a handle, and an edit names that handle. The
//! queue holds the edit behind the send, and the newest text of a pending edit
//! replaces an older one, so a burst of state changes costs one edit. An edit
//! carries the keyboard of the message too, because an edit without one drops
//! it. A reaction names the id of a message of the chat.
//!
//! A close ends the sender and the answerer at once and drops what their queues
//! still hold, because the chat is the record of the session up to the close and
//! the terminal shows the rest. A drain task then sends the final message of the
//! close inside one bounded window, stops the poller, and reports `drained` to
//! the sink, so the owner learns the end without a wait. `destroy` awaits that
//! task, so the last message of the chat goes out before the memory does.
//! `abort` ends the drain at once instead, and the chat gets no last message.

const std = @import("std");

const ai = @import("ai");

const Client = @import("Client.zig");

const Attachment = @This();

/// The messages the queue holds before a send refuses. The sender runs at one
/// message per second, so this is minutes of backlog, and the owner never waits
/// on it.
const outbound_capacity = 256;

/// The time the close has for its final message. A dead network cannot hold the
/// owner past it, and a healthy one needs one call.
const drain_ms_default = 5_000;

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

/// The answers to taps the queue holds before one refuses. A tap is a human
/// action, and each answer leaves within a network round trip, so a small queue
/// never fills in use.
const answers_capacity = 32;

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
/// The commands the poller registers at the attach. Borrowed.
commands: []const Client.Command,
poll_client: Client,
send_client: Client,
answer_client: Client,
outbound_buffer: [outbound_capacity]Outbound,
outbound: std.Io.Queue(Outbound),
answers_buffer: [answers_capacity]Answer,
answers: std.Io.Queue(Answer),
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
answer_future: ?std.Io.Future(void),
/// The drain task of the close, or null before it. It owns the end of the sender.
drain_future: ?std.Io.Future(void),
/// The message that the close named as the last one of the chat, or null. The
/// close writes it before it starts the drain task, which alone reads it.
final: ?Outbound.Send,
/// The instant the close must end, in milliseconds on the awake clock, or zero
/// while the attachment is open.
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
    /// The commands the chat completes after a slash. Borrowed for the life of
    /// the attachment.
    commands: []const Client.Command = &.{},
};

/// The waits of the sender and the poller. The defaults fit Telegram, and a test
/// shortens them.
pub const Pace = struct {
    /// The window of the final message after a close.
    drain_ms: u64 = drain_ms_default,
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
        /// A tap on a keyboard in the bound chat. The owner answers it with
        /// `answer`.
        callback: Callback,
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

    pub const Callback = struct {
        /// The id of the query, which the answer names.
        query_id: []u8,
        /// The message that holds the keyboard.
        message_id: i64,
        /// The callback data of the button.
        data: []u8,
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
            .callback => |callback| {
                gpa.free(callback.query_id);
                gpa.free(callback.data);
            },
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
    /// A new message. The queue owns the text and the keyboard.
    send: Send,
    /// A pending edit of the tracked message with this handle. The text waits
    /// in the slot of the handle, so a later edit replaces it there and the
    /// sender takes the newest one.
    edit: Handle,
    react: Reaction,

    const Send = struct {
        text: []u8,
        /// The options without the keyboard, which `markup` owns.
        options: Client.SendOptions,
        /// The keyboard of the message as JSON, or null.
        markup: ?[]u8,
        /// The slot that takes the id of the new message, or null for a message
        /// that no edit names later.
        handle: ?Handle,
    };
};

/// One answer to a tap. The queue owns the strings.
const Answer = struct {
    query_id: []u8,
    /// The toast, or null for an answer that ends the wait of the button alone.
    text: ?[]u8,

    fn deinit(self: *const Answer, gpa: std.mem.Allocator) void {
        gpa.free(self.query_id);
        if (self.text) |text| gpa.free(text);
    }
};

/// The new state of an edited message: its text and its keyboard. Owned.
const Pending = struct {
    text: []u8,
    markup: ?[]u8,

    fn deinit(self: *const Pending, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.markup) |markup| gpa.free(markup);
    }
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
    /// The newest state of a pending edit, or null while none waits.
    edit: ?Pending,
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
    /// An older pending state gave its place up, and its marker stands.
    replaced,
    /// The slot belongs to another message, so the state drops.
    stale,
};

/// One edit that the sender resolved from its slot: the message and its state.
const Edit = struct {
    message_id: i64,
    pending: Pending,
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
        .commands = options.commands,
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
        .answer_client = .{
            .gpa = gpa,
            .io = io,
            .base_url = options.base_url,
            .token = token,
            .connect_ms = options.connect_ms,
        },
        .outbound_buffer = undefined,
        .outbound = undefined,
        .answers_buffer = undefined,
        .answers = undefined,
        .tracked = @splat(Tracked.empty),
        .tracked_mutex = .init,
        .tracked_next = 0,
        .handle_next = 1,
        .poll_future = null,
        .send_future = null,
        .answer_future = null,
        .drain_future = null,
        .final = null,
        .drain_deadline_ms = .init(0),
    };
    self.outbound = .init(&self.outbound_buffer);
    self.answers = .init(&self.answers_buffer);
    return self;
}

/// Start the sender, the answerer, and the poller.
pub fn start(self: *Attachment) !void {
    std.debug.assert(self.poll_future == null and self.send_future == null);
    std.debug.assert(self.answer_future == null);
    self.send_future = try self.io.concurrent(runSender, .{self});
    errdefer self.close(null) catch unreachable;
    self.answer_future = try self.io.concurrent(runAnswerer, .{self});
    self.poll_future = try self.io.concurrent(runPoller, .{self});
}

/// Queue one message for the chat without a wait. The attachment copies `text`
/// and the keyboard. A full queue refuses with `error.QueueFull`, so the owner
/// never blocks behind the pace of the chat, and a closed attachment takes
/// nothing.
pub fn send(self: *Attachment, text: []const u8, options: *const Client.SendOptions) SendError!void {
    try self.queueSend(text, options, null);
}

/// Queue the answer to the tap `query_id`, with `text` as a toast or with
/// nothing. The answerer sends it without a wait behind the messages.
pub fn answer(self: *Attachment, query_id: []const u8, text: ?[]const u8) SendError!void {
    const id_copy = try self.gpa.dupe(u8, query_id);
    errdefer self.gpa.free(id_copy);
    const text_copy: ?[]u8 = if (text) |toast| try self.gpa.dupe(u8, toast) else null;
    errdefer if (text_copy) |copy| self.gpa.free(copy);
    const items = [1]Answer{.{ .query_id = id_copy, .text = text_copy }};
    const count = self.answers.put(self.io, &items, 0) catch |err| switch (err) {
        error.Closed => return error.Closed,
        error.Canceled => return error.Canceled,
    };
    if (count == 0) return error.QueueFull;
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

/// Replace the text of the tracked message `handle` with `text` and its
/// keyboard with `markup`, once it and every item before it went out. A null
/// `markup` removes the keyboard. A pending edit of the same message gives its
/// state up for this one, so the chat sees the newest state and skips the older
/// ones. An edit of a message whose slot another message took drops in silence.
pub fn edit(
    self: *Attachment,
    handle: Handle,
    text: []const u8,
    markup: ?[]const u8,
) SendError!void {
    var pending: Pending = .{ .text = try self.gpa.dupe(u8, text), .markup = null };
    pending.markup = if (markup) |json| self.gpa.dupe(u8, json) catch |err| {
        self.gpa.free(pending.text);
        return err;
    } else null;
    // The slot owns the state from here on, and a failed put takes it back.
    switch (self.replaceEdit(handle, &pending)) {
        .stale => return pending.deinit(self.gpa),
        // The marker of the older state stands, and the sender takes the newest
        // state when it reaches it.
        .replaced => return,
        .opened => {},
    }
    self.queueOne(.{ .edit = handle }) catch |err| {
        if (self.takeEdit(handle)) |taken| taken.pending.deinit(self.gpa);
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
    const markup: ?[]u8 = if (options.markup) |json| try self.gpa.dupe(u8, json) else null;
    errdefer if (markup) |json| self.gpa.free(json);
    var plain = options.*;
    plain.markup = null;
    try self.queueOne(.{ .send = .{
        .text = copy,
        .options = plain,
        .markup = markup,
        .handle = handle,
    } });
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

/// Put `pending` into the slot of `handle` as its pending edit, and report what
/// it found there. The caller drops a stale state.
fn replaceEdit(self: *Attachment, handle: Handle, pending: *const Pending) Replace {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return .stale;
    const found: Replace = if (slot.edit != null) .replaced else .opened;
    if (slot.edit) |old| old.deinit(self.gpa);
    slot.edit = pending.*;
    return found;
}

/// Take the pending edit of `handle` with the id of its message, or null when
/// none waits or the message has no id. A state with no id to reach drops here,
/// because its send failed for good.
fn takeEdit(self: *Attachment, handle: Handle) ?Edit {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return null;
    const pending = slot.edit orelse return null;
    slot.edit = null;
    const message_id = slot.message_id orelse {
        pending.deinit(self.gpa);
        return null;
    };
    return .{ .message_id = message_id, .pending = pending };
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

/// End the attachment: the sender and the answerer stop, their queues drop, and
/// `final` goes out as the last message of the chat inside the drain window. The
/// attachment copies `final`, and a copy that fails closes without it. The drain
/// task does the rest and reports `drained`, so the owner never waits on a
/// cancel. A second close changes nothing.
pub fn close(self: *Attachment, final: ?[]const u8) error{OutOfMemory}!void {
    if (self.closed()) return;
    defer {
        self.drain_deadline_ms.store(
            self.nowMs() + @as(i64, @intCast(self.pace.drain_ms)),
            .release,
        );
        self.outbound.close(self.io);
        self.answers.close(self.io);
        // A drain task that cannot start runs inline, so the sender still ends
        // at the deadline and the owner still learns it.
        self.drain_future = self.io.concurrent(runDrain, .{self}) catch null;
        if (self.drain_future == null) self.runDrain();
    }
    const text = final orelse return;
    self.final = .{
        .text = try self.gpa.dupe(u8, text),
        .options = .{ .disable_notification = true },
        .markup = null,
        .handle = null,
    };
}

/// End the attachment now and free everything. The drain deadline moves to this
/// instant, so the final message never goes out. The chat then learns nothing of
/// the end.
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
/// drain window of the close, so a dead network cannot hold the exit.
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
    var answers: [answers_capacity]Answer = undefined;
    while (true) {
        const count = self.answers.get(self.io, &answers, 0) catch break;
        if (count == 0) break;
        for (answers[0..count]) |item| item.deinit(self.gpa);
    }
    for (&self.tracked) |*slot| if (slot.edit) |pending| pending.deinit(self.gpa);
    if (self.final) |final| self.gpa.free(final.text);
    self.gpa.free(self.username);
    self.gpa.free(self.token);
    self.gpa.destroy(self);
}

fn freeOutbound(gpa: std.mem.Allocator, item: *const Outbound) void {
    switch (item.*) {
        .send => |send_item| {
            gpa.free(send_item.text);
            if (send_item.markup) |markup| gpa.free(markup);
        },
        .edit, .react => {},
    }
}

/// The drain task: end the sender and the answerer, send the final message
/// inside the window, stop the poller, and report. The cancel ends a send in
/// flight, so nothing can hold the final message back. The poller stops last and
/// on this task, so its cancel never holds the owner or the final message.
fn runDrain(self: *Attachment) void {
    if (self.send_future) |*future| {
        future.cancel(self.io);
        self.send_future = null;
    }
    if (self.answer_future) |*future| {
        future.cancel(self.io);
        self.answer_future = null;
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
/// the pacing sleep, because the window is its whole room and a 429 answers a
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
                self.pause(@min(client.retry_after_s *| std.time.ms_per_s, remaining)) catch return;
                continue;
            },
            error.Unavailable, error.MalformedReply, error.OutOfMemory => {
                failures +|= 1;
                const wait = self.pace.backoff.backoffMs(.{ .attempt = failures });
                self.pause(@min(wait, remaining)) catch return;
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

/// The time left before the end of the close, or null while the attachment is
/// open. Zero once the deadline passed.
fn drainRemainingMs(self: *const Attachment) ?u64 {
    const deadline = self.drain_deadline_ms.load(.acquire);
    if (deadline == 0) return null;
    return @intCast(@max(0, deadline - self.nowMs()));
}

/// Sleep `wait_ms`. A cancel ends the task, so it propagates, and the close
/// cancels the sender, so no sleep of the sender outlives it.
fn pause(self: *const Attachment, wait_ms: u64) error{Canceled}!void {
    self.io.sleep(.fromMilliseconds(@intCast(wait_ms)), .awake) catch return error.Canceled;
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
                try self.pause(self.poll_client.retry_after_s *| std.time.ms_per_s);
                continue;
            },
            error.Unavailable, error.MalformedReply, error.OutOfMemory => {
                if (!failing) {
                    failing = true;
                    try self.emit(.{ .failed = .{ .side = .poll, .name = @errorName(err) } });
                }
                failures +|= 1;
                try self.pause(self.pace.backoff.backoffMs(.{ .attempt = failures }));
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
    commands_set: bool = false,
    confirmed: bool = false,
    offset: ?i64 = null,
};

/// One step of the poller: the webhook removal, the command registration, then
/// the confirmation of the waiting updates, then one long poll whose updates go
/// to the sink.
fn pollOnce(self: *Attachment, state: *PollState) (Client.Error || error{Closed})!void {
    const client = &self.poll_client;
    if (!state.webhook_deleted) {
        try client.deleteWebhook();
        state.webhook_deleted = true;
    }
    if (!state.commands_set) {
        try client.setMyCommands(self.commands);
        state.commands_set = true;
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
        if (update.callback) |callback| {
            // A tap from another chat cannot be answered, so it expires there.
            if (callback.chat_id != self.chat_id) continue;
            const query_id = try self.gpa.dupe(u8, callback.id);
            errdefer self.gpa.free(query_id);
            const data = try self.gpa.dupe(u8, callback.data);
            errdefer self.gpa.free(data);
            try self.emit(.{ .callback = .{
                .query_id = query_id,
                .message_id = callback.message_id,
                .data = data,
            } });
            continue;
        }
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
/// item with one report. A 401, a 403, and a 409 end the attachment. The close
/// cancels the sender, and the rest of the queue drops.
fn runSender(self: *Attachment) void {
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

/// The sender: every item of the queue, until a cancel or a permanent failure
/// ends it.
fn sendUntilClosed(
    self: *Attachment,
    state: *SendState,
) error{ Closed, Canceled, Detached }!void {
    // The loop ends on a cancel, a closed queue, or a permanent failure, and
    // every other pass waits on the queue or the network.
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
            // The marker stands for the newest state of the slot, and it takes
            // one state alone: an edit that arrives while this one goes out
            // opens a marker of its own, so it keeps its place behind the items
            // queued before it.
            .edit => |handle| if (self.takeEdit(handle)) |taken| {
                defer taken.pending.deinit(self.gpa);
                try self.deliver(state, .{ .edit = taken });
            },
            .react => |reaction| try self.deliver(state, .{ .react = reaction }),
        }
    }
}

/// The answerer: answer each tap as soon as it arrives. An answer that fails
/// drops, because a repeat lands after the tap expired and a toast is a
/// courtesy. A 401, a 403, and a 409 end the attachment like on every other
/// call.
fn runAnswerer(self: *Attachment) void {
    self.answerUntilClosed() catch {};
}

fn answerUntilClosed(self: *Attachment) error{ Closed, Canceled, Detached }!void {
    const client = &self.answer_client;
    // The loop ends when the queue closes, on a cancel, or on a permanent
    // failure, and every other pass waits on the queue or the network.
    while (true) {
        var batch: [1]Answer = undefined;
        const count = self.answers.get(self.io, &batch, 1) catch |err| switch (err) {
            error.Closed => return error.Closed,
            error.Canceled => return error.Canceled,
        };
        std.debug.assert(count == 1);
        const item = batch[0];
        defer item.deinit(self.gpa);
        client.answerCallbackQuery(item.query_id, item.text) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Unauthorized => return self.detach(.unauthorized),
            error.Forbidden => return self.detach(.forbidden),
            error.Conflict => return self.detach(.conflict),
            error.RateLimited,
            error.Rejected,
            error.Unavailable,
            error.MalformedReply,
            error.OutOfMemory,
            => {},
        };
    }
}

/// One call of the chat for `delivery`. A tracked send records the id of its
/// message, so a later edit finds it.
fn callChat(self: *Attachment, delivery: *const Delivery) Client.Error!void {
    const client = &self.send_client;
    switch (delivery.*) {
        .send => |send_item| {
            var options = send_item.options;
            options.markup = send_item.markup;
            const message_id = try client.sendMessage(self.chat_id, send_item.text, &options);
            if (send_item.handle) |handle| self.recordMessageId(handle, message_id);
        },
        .edit => |taken| try client.editMessageText(
            self.chat_id,
            taken.message_id,
            taken.pending.text,
            taken.pending.markup,
        ),
        .react => |reaction| try client.setMessageReaction(
            self.chat_id,
            reaction.message_id,
            reaction.mark.emoji(),
        ),
    }
}

/// Deliver one item, with the waits and the retries of the pace. The item drops
/// when Telegram rejects it for good. A message whose formatting Telegram cannot
/// parse goes again as plain text, so the ordered queue never stalls on one
/// block.
fn deliver(
    self: *Attachment,
    state: *SendState,
    delivery_in: Delivery,
) error{ Closed, Canceled, Detached }!void {
    var delivery = delivery_in;
    const client = &self.send_client;
    // The loop ends on a send, a drop, or an end of the task, and every other
    // pass waits on the network.
    while (true) {
        if (state.sent_ms) |last| {
            const elapsed: u64 = @intCast(@max(0, self.nowMs() - last));
            if (elapsed < self.pace.send_spacing_ms)
                try self.pause(self.pace.send_spacing_ms - elapsed);
        }
        self.callChat(&delivery) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Unauthorized => return self.detach(.unauthorized),
            error.Forbidden => return self.detach(.forbidden),
            error.Conflict => return self.detach(.conflict),
            error.RateLimited => {
                try self.pause(client.retry_after_s *| std.time.ms_per_s);
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
                try self.pause(self.pace.backoff.backoffMs(.{ .attempt = state.failures }));
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
    .{ .method = "setMyCommands", .replies = &.{.{ .body = ok_true }} },
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
        .commands = &.{.{ .command = "new", .description = "start a new conversation" }},
    });
}

test "the poller registers the commands, confirms the old updates, gates on the chat, and reports each message and tap" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = ok_true }} },
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
                \\{"update_id":43,"message":{"message_id":4,"date":0,"chat":{"id":99,"type":"private"},"sticker":{}}},
                \\{"update_id":44,"callback_query":{"id":"900","from":{"id":5},"chat_instance":"c","message":{"message_id":9,"date":0,"chat":{"id":-5,"type":"group"}},"data":"row:1:0"}},
                \\{"update_id":45,"callback_query":{"id":"901","from":{"id":5},"chat_instance":"c","message":{"message_id":50,"date":0,"chat":{"id":99,"type":"private"}},"data":"cancel:3"}}
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

    try collector.waitFor(3);
    try attachment.close(null);
    try server.finish();
    try std.testing.expectEqualStrings("/bot42:secret/deleteWebhook", server.requests.items[0].path);
    try std.testing.expectEqualStrings(
        "{\"commands\":[{\"command\":\"new\",\"description\":\"start a new conversation\"}]}",
        server.requests.items[1].body,
    );
    try std.testing.expectEqualStrings(
        "{\"offset\":-1,\"timeout\":0,\"allowed_updates\":[\"message\",\"callback_query\"]}",
        server.requests.items[2].body,
    );
    // The poll starts after the confirmed update, and it waits five seconds
    // under the head window.
    try std.testing.expectEqualStrings(
        "{\"offset\":41,\"timeout\":55,\"allowed_updates\":[\"message\",\"callback_query\"]}",
        server.requests.items[3].body,
    );
    const events = collector.events.items;
    try std.testing.expectEqual(@as(u64, 7), events[0].generation);
    try std.testing.expectEqual(@as(i64, 2), events[0].payload.message.id);
    try std.testing.expectEqualStrings("hello", events[0].payload.message.text);
    try std.testing.expectEqual(@as(i64, 4), events[1].payload.unreadable);
    // The tap of the bound chat reports with its query, and the tap of the
    // other chat drops.
    try std.testing.expectEqualStrings("901", events[2].payload.callback.query_id);
    try std.testing.expectEqual(@as(i64, 50), events[2].payload.callback.message_id);
    try std.testing.expectEqualStrings("cancel:3", events[2].payload.callback.data);
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

    // The webhook removal, the command registration, the confirmation, and
    // then the long poll.
    try server.waitForRequests(4);
    try server.finish();
    try std.testing.expectEqual(
        @as(u64, Client.poll_connect_ms_min),
        attachment.poll_client.connect_ms,
    );
    // A send and an answer keep the configured window, because both are short
    // calls.
    try std.testing.expectEqual(@as(u64, 5_000), attachment.send_client.connect_ms);
    try std.testing.expectEqual(@as(u64, 5_000), attachment.answer_client.connect_ms);
    try std.testing.expect(std.mem.indexOf(u8, server.requests.items[3].body, "\"timeout\":25,") != null);
}

test "a failed poll reports once, recovers once, and a 409 detaches" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = ok_true }} },
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

    const keyboard = "{\"inline_keyboard\":[[{\"text\":\"Withdraw\",\"callback_data\":\"withdraw:1\"}]]}";
    const handle = try attachment.sendTracked("Thinking", &.{
        .disable_notification = true,
        .markup = keyboard,
    });
    // Both edits queue while the send still waits for its reply, so one edit
    // goes out with the newest state, keyboard included.
    try attachment.edit(handle, "Writing", keyboard);
    try attachment.edit(handle, "Running: bash", keyboard);
    // The sender took that state once its edit arrived, so the next edit opens
    // a pending one of its own. The summary drops the keyboard.
    _ = try server.waitForRequest("/editMessageText", 0);
    try attachment.edit(handle, "Tools: 1 call", null);
    _ = try server.waitForRequest("/editMessageText", 1);
    try server.finish();
    var buffer: [2][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 1), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"reply_markup\":" ++ keyboard) != null);
    var edits: [2][]const u8 = undefined;
    var count: usize = 0;
    for (server.requests.items) |request| {
        if (!std.mem.endsWith(u8, request.path, "/editMessageText")) continue;
        edits[count] = request.body;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Running: bash\",\"reply_markup\":" ++ keyboard ++ "}",
        edits[0],
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Tools: 1 call\"}",
        edits[1],
    );
}

// A tap expires after a few seconds, so its answer cannot wait behind the
// messages of the chat. The answerer sends it at once, ahead of a send that
// holds the sender, and a failed answer drops without a report.
test "an answer leaves ahead of the paced sends, and a failed one drops in silence" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{ .{ .body = ok_sent, .delay_ms = 200 }, .{ .body = ok_sent } } },
        .{ .method = "answerCallbackQuery", .replies = &.{
            .{ .body = ok_true },
            .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: query is too old\"}" },
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

    // The first send holds the sender until its late reply, and the second
    // waits in the queue behind it.
    try attachment.send("slow", &.{});
    try server.waitForSends(1);
    try attachment.send("behind", &.{});
    try attachment.answer("900", "Nothing queued.");
    try attachment.answer("901", null);
    try attachment.answer("902", "This list is closed.");
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\",\"text\":\"Nothing queued.\"}",
        try server.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"901\"}",
        try server.waitForRequest("/answerCallbackQuery", 1),
    );
    _ = try server.waitForRequest("/answerCallbackQuery", 2);
    try server.waitForSends(2);
    try server.finish();
    // Every answer reached the server before the second send did.
    var last_answer: usize = 0;
    var second_send: usize = 0;
    for (server.requests.items, 0..) |request, index| {
        if (std.mem.endsWith(u8, request.path, "/answerCallbackQuery")) last_answer = index;
        if (std.mem.indexOf(u8, request.body, "\"text\":\"behind\"") != null) second_send = index;
    }
    try std.testing.expect(last_answer < second_send);
    try std.testing.expectEqual(@as(usize, 0), collector.events.items.len);
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
    try attachment.edit(handle, "Writing", null);
    // The first edit is in flight, and its reply waits.
    _ = try server.waitForRequest("/editMessageText", 0);
    try attachment.send("answer", &.{});
    try attachment.edit(handle, "Tools: 0 calls", null);
    _ = try server.waitForRequest("/editMessageText", 1);
    try server.finish();
    var order: [4][]const u8 = undefined;
    var count: usize = 0;
    for (server.requests.items) |request| {
        if (std.mem.endsWith(u8, request.path, "/getUpdates")) continue;
        if (std.mem.endsWith(u8, request.path, "/deleteWebhook")) continue;
        if (std.mem.endsWith(u8, request.path, "/setMyCommands")) continue;
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
    try attachment.edit(first, "Tools: 0 calls", null);
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
    try attachment.edit(handle, "Writing", null);
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

// The chat is the record of the session up to the close, and the terminal shows
// the rest, so the close sends the final message alone. A message that waits in
// the queue at the close drops, and a send after the close refuses.
test "a close drops the queue, sends the final message alone, and then refuses a send" {
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
    // The spacing outlasts the window, so the second message waits in its pacing
    // sleep when the close arrives.
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
    try server.waitForRequests(3);

    try attachment.send("first", &.{});
    try server.waitForSends(1);
    try attachment.send("queued", &.{});
    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try attachment.close("final");
    try std.testing.expectError(error.Closed, attachment.send("too late", &.{}));
    // The drain reports its end without a wait of the owner, and the destroy
    // then waits for nothing. The final message went out at once, because the
    // close ended the pacing sleep of the sender instead of a wait for it.
    try collector.waitFor(1);
    try std.testing.expect(collector.events.items[0].payload == .drained);
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms < test_drain_ms);
    destroyed = true;
    attachment.destroy();
    try server.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"disable_notification\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), collector.events.items.len);
}

test "a full queue refuses a send, and the final message still ends the chat" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The first reply waits, so the sender holds the first message while the
    // queue fills.
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
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try server.waitForRequests(3);

    try attachment.send("first", &.{});
    try server.waitForSends(1);
    // The sender took the first message, so the queue takes the capacity and
    // refuses the one after it without a wait.
    for (0..outbound_capacity) |_| try attachment.send("ordinary", &.{});
    try std.testing.expectError(error.QueueFull, attachment.send("one too many", &.{}));

    // The ordinary messages drop with the close, and the final message ends
    // the chat.
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
    // The reply to the first send comes late, so the sender still waits on it
    // when the close ends it.
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
    try server.waitForRequests(3);

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
