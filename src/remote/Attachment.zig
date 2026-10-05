const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Client = @import("Client.zig");
const html = @import("html.zig");

const Attachment = @This();

pub const outbound_capacity = 256;

const drain_ms = 2_000;

pub const send_spacing_ms = 1_000;

pub const retry: core.Retry = .{};

pub const outage_ms_min = 30_000;

const tracked_capacity = outbound_capacity + 2;

const answers_capacity = 32;

const parse_failure_description = "can't parse entities";

gpa: std.mem.Allocator,
io: std.Io,
token: []const u8,
username: []const u8,
chat_id: i64,
generation: u64,
sink: Sink,
commands: []const Client.Command,
poll_client: Client,
send_client: Client,
answer_client: Client,
outbound_buffer: [outbound_capacity]Outbound,
outbound: std.Io.Queue(Outbound),
answers_buffer: [answers_capacity][]u8,
answers: std.Io.Queue([]u8),
tracked: [tracked_capacity]Tracked,
tracked_mutex: std.Io.Mutex,
tracked_next: usize,
handle_next: Handle,
poll_future: ?std.Io.Future(void),
send_future: ?std.Io.Future(void),
answer_future: ?std.Io.Future(void),
drain_future: ?std.Io.Future(void),
final: ?Outbound.Send,
drain_deadline_ms: std.atomic.Value(i64),

const Options = struct {
    transport: ?providers.Transport,
    token: []const u8,
    username: []const u8,
    chat_id: i64,
    connect_ms: u64,
    generation: u64,
    sink: Sink,
    commands: []const Client.Command,
};

pub const Sink = core.actor.Sink(Event);

pub const Event = struct {
    generation: u64,
    payload: Payload,

    const Payload = union(enum) {
        message: Message,
        unreadable: i64,
        callback: Callback,
        failed: Failure,
        recovered: Side,
        send_rejected: Rejected,
        send_dropped: Rejected.Kind,
        detach: Reason,
        drained,
    };

    const Message = struct {
        id: i64,
        text: []const u8,
    };

    const Callback = struct {
        query_id: []const u8,
        message_id: i64,
        data: []const u8,
    };

    const Failure = struct {
        side: Side,
        name: []const u8,
    };

    pub const Rejected = struct {
        kind: Kind,
        description: []const u8,

        pub const Kind = enum { message, edit, deletion };
    };

    pub const Side = enum { poll, send };

    pub const Reason = union(enum) {
        unauthorized,
        forbidden: []const u8,
        conflict,
        poll_rejected,

        fn of(client: *const Client, permanent: Client.Class.Permanent) Reason {
            return switch (permanent) {
                .unauthorized => .unauthorized,
                .forbidden => .{ .forbidden = client.description() },
                .conflict => .conflict,
            };
        }
    };

    pub fn dupe(self: *const Event, gpa: std.mem.Allocator) error{OutOfMemory}!Event {
        return .{ .generation = self.generation, .payload = switch (self.payload) {
            .message => |message| .{ .message = .{
                .id = message.id,
                .text = try gpa.dupe(u8, message.text),
            } },
            .callback => |callback| callback: {
                const query_id = try gpa.dupe(u8, callback.query_id);
                errdefer gpa.free(query_id);
                break :callback .{ .callback = .{
                    .query_id = query_id,
                    .message_id = callback.message_id,
                    .data = try gpa.dupe(u8, callback.data),
                } };
            },
            .send_rejected => |rejected| .{ .send_rejected = .{
                .kind = rejected.kind,
                .description = try gpa.dupe(u8, rejected.description),
            } },
            .detach => |reason| .{ .detach = switch (reason) {
                .forbidden => |description| .{ .forbidden = gpa.dupe(u8, description) catch "" },
                .unauthorized, .conflict, .poll_rejected => reason,
            } },
            .unreadable, .failed, .recovered, .send_dropped, .drained => self.payload,
        } };
    }

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        switch (self.payload) {
            .message => |message| gpa.free(message.text),
            .callback => |callback| {
                gpa.free(callback.query_id);
                gpa.free(callback.data);
            },
            .send_rejected => |rejected| gpa.free(rejected.description),
            .detach => |reason| switch (reason) {
                .forbidden => |description| gpa.free(description),
                .unauthorized, .conflict, .poll_rejected => {},
            },
            .unreadable, .failed, .recovered, .send_dropped, .drained => {},
        }
    }
};

pub const Handle = u64;

pub const SendError = error{ Closed, Canceled, QueueFull, OutOfMemory };

const Outbound = union(enum) {
    send: Send,
    edit: Handle,
    delete: Handle,

    const Send = struct {
        text: []u8,
        options: Client.SendOptions,
        markup: ?[]u8,
        handle: ?Handle,
    };
};

const Pending = struct {
    text: []u8,
    parse_mode: ?[]const u8,
    markup: ?[]u8,

    fn deinit(self: *const Pending, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.markup) |markup| gpa.free(markup);
    }
};

const Tracked = struct {
    handle: Handle,
    message_id: ?i64,
    edit: ?Pending,
    settled: bool,
    deleting: bool,

    const empty: Tracked = .{
        .handle = 0,
        .message_id = null,
        .edit = null,
        .settled = true,
        .deleting = false,
    };

    fn vacant(self: *const Tracked) bool {
        return self.settled and self.edit == null and !self.deleting;
    }
};

const Replace = enum {
    opened,
    replaced,
    stale,
};

const Edit = struct {
    message_id: i64,
    pending: Pending,
};

const Delivery = union(enum) {
    send: Outbound.Send,
    edit: Edit,
    delete: i64,

    fn kind(self: *const Delivery) Event.Rejected.Kind {
        return switch (self.*) {
            .send => .message,
            .edit => .edit,
            .delete => .deletion,
        };
    }
};

const Final = struct {
    text: []const u8,
    parse_mode: ?[]const u8 = null,
};

const Outage = struct {
    started_ms: ?i64 = null,
    name: []const u8 = "",
    reported: bool = false,

    fn reports(self: *Outage, attachment: *const Attachment, name: []const u8) bool {
        const now_ms = attachment.nowMs();
        const started_ms = self.started_ms orelse start: {
            self.started_ms = now_ms;
            self.name = name;
            break :start now_ms;
        };
        if (self.reported) return false;
        if (now_ms - started_ms < outage_ms_min) return false;
        self.reported = true;
        return true;
    }

    fn ends(self: *Outage) bool {
        const reported = self.reported;
        self.* = .{};
        return reported;
    }
};

const SendState = struct {
    outage: Outage = .{},
    failures: u32 = 0,
    sent_ms: ?i64 = null,
};

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
        .commands = options.commands,
        .poll_client = .{
            .gpa = gpa,
            .io = io,
            .transport = options.transport,
            .token = token,
            .connect_ms = Client.pollConnectMs(options.connect_ms),
        },
        .send_client = .{
            .gpa = gpa,
            .io = io,
            .transport = options.transport,
            .token = token,
            .connect_ms = options.connect_ms,
        },
        .answer_client = .{
            .gpa = gpa,
            .io = io,
            .transport = options.transport,
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

pub fn start(self: *Attachment) !void {
    std.debug.assert(self.poll_future == null and self.send_future == null);
    std.debug.assert(self.answer_future == null);
    self.send_future = try self.io.concurrent(runSender, .{self});
    errdefer self.close(null) catch {};
    self.answer_future = try self.io.concurrent(runAnswerer, .{self});
    self.poll_future = try self.io.concurrent(runPoller, .{self});
}

pub fn send(
    self: *Attachment,
    text: []const u8,
    options: *const Client.SendOptions,
) SendError!void {
    try self.queueSend(text, options, null);
}

pub fn answer(self: *Attachment, query_id: []const u8) SendError!void {
    const id_copy = try self.gpa.dupe(u8, query_id);
    errdefer self.gpa.free(id_copy);
    const items = [1][]u8{id_copy};
    const count = self.answers.put(self.io, &items, 0) catch |err| switch (err) {
        error.Closed => return error.Closed,
        error.Canceled => return error.Canceled,
    };
    if (count == 0) return error.QueueFull;
}

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

pub fn edit(
    self: *Attachment,
    handle: Handle,
    text: []const u8,
    options: *const Client.EditOptions,
) SendError!void {
    var pending: Pending = .{
        .text = try self.gpa.dupe(u8, text),
        .parse_mode = options.parse_mode,
        .markup = null,
    };
    pending.markup = if (options.markup) |json| self.gpa.dupe(u8, json) catch |err| {
        self.gpa.free(pending.text);
        return err;
    } else null;
    switch (self.replaceEdit(handle, &pending)) {
        .stale => return pending.deinit(self.gpa),
        .replaced => return,
        .opened => {},
    }
    self.queueOne(.{ .edit = handle }) catch |err| {
        if (self.takeEdit(handle)) |taken| taken.pending.deinit(self.gpa);
        return err;
    };
}

pub fn delete(self: *Attachment, handle: Handle) SendError!void {
    if (!self.markDeletion(handle)) return;
    self.queueOne(.{ .delete = handle }) catch |err| {
        self.unmarkDeletion(handle);
        return err;
    };
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

fn reserveHandle(self: *Attachment) Handle {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const handle = self.handle_next;
    self.handle_next += 1;
    for (0..tracked_capacity) |step| {
        const index = (self.tracked_next + step) % tracked_capacity;
        const slot = &self.tracked[index];
        if (!slot.vacant()) continue;
        slot.* = .{
            .handle = handle,
            .message_id = null,
            .edit = null,
            .settled = false,
            .deleting = false,
        };
        self.tracked_next = index + 1;
        return handle;
    }
    unreachable;
}

fn replaceEdit(self: *Attachment, handle: Handle, pending: *const Pending) Replace {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return .stale;
    const found: Replace = if (slot.edit != null) .replaced else .opened;
    if (slot.edit) |old| old.deinit(self.gpa);
    slot.edit = pending.*;
    return found;
}

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

fn markDeletion(self: *Attachment, handle: Handle) bool {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return false;
    slot.deleting = true;
    return true;
}

fn unmarkDeletion(self: *Attachment, handle: Handle) void {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return;
    slot.deleting = false;
}

fn takeDeletion(self: *Attachment, handle: Handle) ?i64 {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return null;
    slot.deleting = false;
    if (slot.edit) |pending| pending.deinit(self.gpa);
    slot.edit = null;
    const message_id = slot.message_id orelse return null;
    slot.message_id = null;
    return message_id;
}

fn recordMessageId(self: *Attachment, handle: Handle, message_id: i64) void {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return;
    slot.message_id = message_id;
}

fn settle(self: *Attachment, handle: Handle) void {
    self.tracked_mutex.lockUncancelable(self.io);
    defer self.tracked_mutex.unlock(self.io);
    const slot = self.slotOf(handle) orelse return;
    slot.settled = true;
}

fn slotOf(self: *Attachment, handle: Handle) ?*Tracked {
    for (&self.tracked) |*slot| if (slot.handle == handle) return slot;
    return null;
}

fn closed(self: *const Attachment) bool {
    return self.drain_deadline_ms.load(.acquire) != 0;
}

pub fn close(
    self: *Attachment,
    final: ?*const Final,
) error{ OutOfMemory, ConcurrencyUnavailable }!void {
    if (self.closed()) return;
    const kept = self.keepFinal(final);
    self.drain_deadline_ms.store(self.nowMs() + drain_ms, .release);
    const drain = self.startDrain();
    self.outbound.close(self.io);
    self.answers.close(self.io);
    try drain;
    try kept;
}

fn keepFinal(self: *Attachment, maybe_final: ?*const Final) error{OutOfMemory}!void {
    const final = maybe_final orelse return;
    self.final = .{
        .text = try self.gpa.dupe(u8, final.text),
        .options = .{
            .disable_notification = true,
            .parse_mode = final.parse_mode,
        },
        .markup = null,
        .handle = null,
    };
}

pub fn abort(self: *Attachment) void {
    self.close(null) catch {};
    self.drain_deadline_ms.store(@max(1, self.nowMs()), .release);
    self.cancelTask(&self.drain_future);
    self.destroy();
}

pub fn destroy(self: *Attachment) void {
    self.close(null) catch {};
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
    var answers: [answers_capacity][]u8 = undefined;
    while (true) {
        const count = self.answers.get(self.io, &answers, 0) catch break;
        if (count == 0) break;
        for (answers[0..count]) |query_id| self.gpa.free(query_id);
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
        .edit, .delete => {},
    }
}

fn cancelTask(self: *Attachment, maybe_future: *?std.Io.Future(void)) void {
    if (maybe_future.*) |*future| {
        future.cancel(self.io);
        maybe_future.* = null;
    }
}

fn startDrain(self: *Attachment) std.Io.ConcurrentError!void {
    self.drain_future = self.io.concurrent(runDrain, .{self}) catch |err| {
        self.cancelTask(&self.send_future);
        self.cancelTask(&self.answer_future);
        self.cancelTask(&self.poll_future);
        return err;
    };
}

fn runDrain(self: *Attachment) void {
    self.cancelTask(&self.send_future);
    self.cancelTask(&self.answer_future);
    if (self.final) |final| {
        self.final = null;
        defer self.gpa.free(final.text);
        self.deliverFinal(&final);
    }
    self.cancelTask(&self.poll_future);
    self.emit(.drained);
}

fn deliverFinal(self: *Attachment, final: *const Outbound.Send) void {
    const client = &self.send_client;
    var failures: u32 = 0;
    var delivery: Delivery = .{ .send = final.* };
    var maybe_plain: ?[]u8 = null;
    defer if (maybe_plain) |plain| self.gpa.free(plain);
    while (true) {
        const remaining = self.drainRemainingMs() orelse unreachable;
        if (remaining == 0) return;
        client.connect_ms = if (client.connect_ms == 0)
            remaining
        else
            @min(client.connect_ms, remaining);
        _ = client.sendMessage(
            self.chat_id,
            delivery.send.text,
            &delivery.send.options,
        ) catch |err| switch (Client.Class.of(err)) {
            .rate_limited => {
                self.pauseInDrain(client.retryAfterMs(drain_ms)) catch return;
                continue;
            },
            .transient => {
                failures +|= 1;
                self.pauseInDrain(retry.backoff.delay(failures)) catch return;
                continue;
            },
            .rejected => {
                if (!rejectedParse(client)) return;
                maybe_plain = self.plainOf(&delivery) orelse return;
                continue;
            },
            .canceled, .permanent => return,
        };
        return;
    }
}

fn plainOf(self: *Attachment, delivery: *Delivery) ?[]u8 {
    const text: *[]u8, const parse_mode: *?[]const u8 = switch (delivery.*) {
        .send => |*send_item| .{ &send_item.text, &send_item.options.parse_mode },
        .edit => |*taken| .{ &taken.pending.text, &taken.pending.parse_mode },
        .delete => return null,
    };
    if (parse_mode.* == null) return null;
    const plain = html.plainAlloc(self.gpa, text.*) catch return null;
    text.* = plain;
    parse_mode.* = null;
    return plain;
}

fn emit(self: *Attachment, payload: Event.Payload) void {
    self.sink.emit(self.io, &.{ .generation = self.generation, .payload = payload });
}

fn rejectedParse(client: *const Client) bool {
    return std.mem.indexOf(u8, client.description(), parse_failure_description) != null;
}

fn nowMs(self: *const Attachment) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

fn drainRemainingMs(self: *const Attachment) ?u64 {
    const deadline = self.drain_deadline_ms.load(.acquire);
    if (deadline == 0) return null;
    return @intCast(@max(0, deadline - self.nowMs()));
}

fn pause(self: *const Attachment, wait_ms: u64) error{Canceled}!void {
    try core.timeout.sleep(self.io, wait_ms);
}

fn pauseInDrain(self: *const Attachment, wait_ms: u64) error{Canceled}!void {
    const remaining = self.drainRemainingMs() orelse unreachable;
    try self.pause(@min(wait_ms, remaining));
}

fn runPoller(self: *Attachment) void {
    self.pollUntilEnd() catch {};
}

fn pollUntilEnd(self: *Attachment) error{Canceled}!void {
    var poll: Client.Poll = .{ .commands = self.commands };
    var outage: Outage = .{};
    var failures: u32 = 0;
    while (true) {
        self.pollOnce(&poll) catch |err| switch (Client.Class.of(err)) {
            .canceled => return error.Canceled,
            .permanent => |permanent| return self.emit(.{
                .detach = .of(&self.poll_client, permanent),
            }),
            .rejected => return self.emit(.{ .detach = .poll_rejected }),
            .rate_limited => {
                try self.pause(self.poll_client.retryAfterMs(retry.backoff.delay_ms_max));
                continue;
            },
            .transient => {
                if (outage.reports(self, @errorName(err)))
                    self.emit(.{ .failed = .{ .side = .poll, .name = outage.name } });
                failures +|= 1;
                try self.pause(retry.backoff.delay(failures));
                continue;
            },
        };
        if (outage.ends()) self.emit(.{ .recovered = .poll });
        failures = 0;
    }
}

fn pollOnce(self: *Attachment, poll: *Client.Poll) Client.Error!void {
    const client = &self.poll_client;
    const updates = try poll.next(client, Client.pollTimeoutSeconds(client.connect_ms));
    defer updates.deinit(self.gpa);
    for (updates.items) |update| {
        if (update.callback) |callback| {
            if (callback.chat_id != self.chat_id) continue;
            self.emit(.{ .callback = .{
                .query_id = callback.id,
                .message_id = callback.message_id,
                .data = callback.data,
            } });
            continue;
        }
        const message = update.message orelse continue;
        if (message.chat_id != self.chat_id) continue;
        const text = message.text orelse {
            self.emit(.{ .unreadable = message.message_id });
            continue;
        };
        self.emit(.{ .message = .{ .id = message.message_id, .text = text } });
    }
}

fn runSender(self: *Attachment) void {
    var state: SendState = .{};
    self.sendUntilClosed(&state) catch {};
}

fn sendUntilClosed(
    self: *Attachment,
    state: *SendState,
) error{ Closed, Canceled, Detached }!void {
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
                defer if (send_item.handle) |handle| self.settle(handle);
                try self.deliver(state, .{ .send = send_item });
            },
            .edit => |handle| if (self.takeEdit(handle)) |taken| {
                defer taken.pending.deinit(self.gpa);
                try self.deliver(state, .{ .edit = taken });
            },
            .delete => |handle| if (self.takeDeletion(handle)) |message_id| {
                try self.deliver(state, .{ .delete = message_id });
            },
        }
    }
}

fn runAnswerer(self: *Attachment) void {
    self.answerUntilClosed() catch {};
}

fn answerUntilClosed(self: *Attachment) error{ Closed, Canceled, Detached }!void {
    const client = &self.answer_client;
    while (true) {
        var batch: [1][]u8 = undefined;
        const count = self.answers.get(self.io, &batch, 1) catch |err| switch (err) {
            error.Closed => return error.Closed,
            error.Canceled => return error.Canceled,
        };
        std.debug.assert(count == 1);
        const query_id = batch[0];
        defer self.gpa.free(query_id);
        client.answerCallbackQuery(query_id) catch |err| switch (Client.Class.of(err)) {
            .canceled => return error.Canceled,
            .permanent => |permanent| return self.detach(.of(client, permanent)),
            .rate_limited, .rejected, .transient => {},
        };
    }
}

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
            .{ .chat_id = self.chat_id, .message_id = taken.message_id },
            taken.pending.text,
            &.{ .parse_mode = taken.pending.parse_mode, .markup = taken.pending.markup },
        ),
        .delete => |message_id| try client.deleteMessage(.{
            .chat_id = self.chat_id,
            .message_id = message_id,
        }),
    }
}

fn deliver(
    self: *Attachment,
    state: *SendState,
    delivery_in: Delivery,
) error{ Canceled, Detached }!void {
    var delivery = delivery_in;
    var maybe_plain: ?[]u8 = null;
    defer if (maybe_plain) |plain| self.gpa.free(plain);
    const client = &self.send_client;
    var attempts_failed: u32 = 0;
    while (attempts_failed < retry.attempts_max) {
        if (state.sent_ms) |last| {
            const elapsed: u64 = @intCast(@max(0, self.nowMs() - last));
            if (elapsed < send_spacing_ms) try self.pause(send_spacing_ms - elapsed);
        }
        self.callChat(&delivery) catch |err| switch (Client.Class.of(err)) {
            .canceled => return error.Canceled,
            .permanent => |permanent| return self.detach(.of(client, permanent)),
            .rate_limited => {
                attempts_failed += 1;
                try self.pause(client.retryAfterMs(retry.backoff.delay_ms_max));
                continue;
            },
            .rejected => {
                if (rejectedParse(client)) {
                    if (self.plainOf(&delivery)) |plain| {
                        maybe_plain = plain;
                        state.sent_ms = self.nowMs();
                        continue;
                    }
                }
                self.emit(.{ .send_rejected = .{
                    .kind = delivery.kind(),
                    .description = client.description(),
                } });
                return;
            },
            .transient => {
                if (state.outage.reports(self, @errorName(err)))
                    self.emit(.{ .failed = .{ .side = .send, .name = state.outage.name } });
                state.failures +|= 1;
                attempts_failed += 1;
                try self.pause(retry.backoff.delay(state.failures));
                continue;
            },
        };
        state.sent_ms = self.nowMs();
        if (state.outage.ends()) self.emit(.{ .recovered = .send });
        state.failures = 0;
        return;
    }
    self.emit(.{ .send_dropped = delivery.kind() });
}

fn detach(self: *Attachment, reason: Event.Reason) error{Detached} {
    self.emit(.{ .detach = reason });
    return error.Detached;
}

const testing = @import("testing.zig");

test "the poller sets the commands, confirms the old updates, and reports each message and tap" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        testing.commands_set,
        .{
            .method = "getUpdates",
            .replies = &.{
                .{ .body =
                \\{"ok":true,"result":[{"update_id":40,"message":{"message_id":1,"date":0,
                \\"chat":{"id":99,"type":"private"},"text":"old"}}]}
                },
                .{ .body =
                \\{"ok":true,"result":[
                \\{"update_id":41,"message":{"message_id":2,"date":0,"chat":{"id":99,
                \\"type":"private"},"text":"hello"}},
                \\{"update_id":42,"message":{"message_id":3,"date":0,"chat":{"id":-5,
                \\"type":"group"},"text":"other chat"}},
                \\{"update_id":43,"message":{"message_id":4,"date":0,"chat":{"id":99,
                \\"type":"private"},"sticker":{}}},
                \\{"update_id":44,"callback_query":{"id":"900","from":{"id":5},"chat_instance":"c",
                \\"message":{"message_id":9,"date":0,"chat":{"id":-5,"type":"group"}},
                \\"data":"row:1:0"}},
                \\{"update_id":45,"callback_query":{"id":"901","from":{"id":5},"chat_instance":"c",
                \\"message":{"message_id":50,"date":0,"chat":{"id":99,"type":"private"}},
                \\"data":"cancel:3"}}
                \\]}
                },
            },
        },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try rig.collector.waitFor(3);
    try attachment.close(null);
    try rig.telegram.finish();
    try std.testing.expectEqualStrings(
        "/bot42:secret/deleteWebhook",
        rig.telegram.requests.items[0].path,
    );
    try std.testing.expectEqualStrings(
        "{\"commands\":[{\"command\":\"new\",\"description\":\"start a new conversation\"}]}",
        rig.telegram.requests.items[1].body,
    );
    try std.testing.expectEqualStrings(
        "{\"offset\":-1,\"timeout\":0,\"allowed_updates\":[\"message\",\"callback_query\"]}",
        rig.telegram.requests.items[2].body,
    );
    try std.testing.expectEqualStrings(
        "{\"offset\":41,\"timeout\":55,\"allowed_updates\":[\"message\",\"callback_query\"]}",
        rig.telegram.requests.items[3].body,
    );
    const events = rig.collector.events.items;
    try std.testing.expectEqual(@as(u64, 7), events[0].generation);
    try std.testing.expectEqual(@as(i64, 2), events[0].payload.message.id);
    try std.testing.expectEqualStrings("hello", events[0].payload.message.text);
    try std.testing.expectEqual(@as(i64, 4), events[1].payload.unreadable);
    try std.testing.expectEqualStrings("901", events[2].payload.callback.query_id);
    try std.testing.expectEqual(@as(i64, 50), events[2].payload.callback.message_id);
    try std.testing.expectEqualStrings("cancel:3", events[2].payload.callback.data);
}

const Collector = testing.Collector(Event);
const Rig = testing.Rig(Event);

const reply_delay_ms = 100;

const rate_limited_reply: testing.Reply = .{
    .status = 429,
    .body = "{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":1}}",
};

fn testAttachment(rig: *Rig) !*Attachment {
    return create(std.testing.allocator, rig.telegram.io, &.{
        .transport = rig.telegram.transport(),
        .token = "42:secret",
        .username = "drinky_bot",
        .chat_id = 99,
        .connect_ms = 60_000,
        .generation = 7,
        .sink = rig.collector.sink(),
        .commands = &.{.{ .command = "new", .description = "start a new conversation" }},
    });
}

test "a short configured window does not shorten the long poll" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts);
    defer rig.deinit();
    const attachment = try create(gpa, io, &.{
        .transport = rig.telegram.transport(),
        .token = "42:secret",
        .username = "drinky_bot",
        .chat_id = 99,
        .connect_ms = 5_000,
        .generation = 7,
        .sink = rig.collector.sink(),
        .commands = &.{},
    });
    defer attachment.destroy();
    try attachment.start();

    try rig.telegram.waitForLongPoll();
    try rig.telegram.finish();
    try std.testing.expect(
        std.mem.indexOf(u8, rig.telegram.requests.items[3].body, "\"timeout\":25,") != null,
    );
}

test "a failed poll reports once, recovers once, and a 409 detaches" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{ .status = 502, .body = "" },
            .{ .status = 503, .body = "" },
            .{ .body = testing.ok_empty },
            .{
                .status = 409,
                .body = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict\"}",
            },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try clock.waitForSleep(retry.backoff.delay(1));
    clock.advance(outage_ms_min);
    try clock.pass(retry.backoff.delay(2));
    try rig.collector.waitFor(3);
    try rig.telegram.finish();
    const events = rig.collector.events.items;
    try std.testing.expectEqual(Event.Side.poll, events[0].payload.failed.side);
    try std.testing.expectEqualStrings("Unavailable", events[0].payload.failed.name);
    try std.testing.expectEqual(Event.Side.poll, events[1].payload.recovered);
    try std.testing.expectEqual(Event.Reason.conflict, events[2].payload.detach);
}

test "a poll outage under the threshold reports nothing" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{ .status = 502, .body = "" },
            .{ .status = 502, .body = "" },
            .{ .body = testing.ok_empty },
            .{
                .status = 409,
                .body = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict\"}",
            },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try clock.waitForSleep(retry.backoff.delay(1));
    clock.advance(outage_ms_min - 1);
    try clock.pass(retry.backoff.delay(2));
    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    const events = rig.collector.events.items;
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(Event.Reason.conflict, events[0].payload.detach);
}

test "a stated wait beyond the backoff maximum pauses the poll for the maximum" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{
                .status = 429,
                .body = "{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests\"," ++
                    "\"parameters\":{\"retry_after\":10000000000000000}}",
            },
            .{ .body =
            \\{"ok":true,"result":[{"update_id":41,"message":{"message_id":2,"date":0,
            \\"chat":{"id":99,"type":"private"},"text":"hello"}}]}
            },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try clock.pass(retry.backoff.delay_ms_max);
    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    try std.testing.expectEqualStrings("hello", rig.collector.events.items[0].payload.message.text);
}

test "a 429 pauses the poll and a send for the stated wait, and a rate-limited answer drops" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            rate_limited_reply,
            .{ .body =
            \\{"ok":true,"result":[{"update_id":41,"message":{"message_id":2,"date":0,
            \\"chat":{"id":99,"type":"private"},"text":"hello"}}]}
            },
        } },
        .{
            .method = "sendMessage",
            .replies = &.{ rate_limited_reply, .{ .body = testing.ok_sent } },
        },
        .{
            .method = "answerCallbackQuery",
            .replies = &.{ rate_limited_reply, .{ .body = testing.ok_true } },
        },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try clock.waitForSleep(std.time.ms_per_s);
    try std.testing.expectEqual(@as(usize, 2), rig.telegram.countOf("/getUpdates"));
    clock.advance(std.time.ms_per_s);
    try rig.collector.waitFor(1);
    try std.testing.expectEqualStrings("hello", rig.collector.events.items[0].payload.message.text);

    try attachment.send("paced", &.{});
    try clock.waitForSleep(std.time.ms_per_s);
    try std.testing.expectEqual(@as(usize, 1), rig.telegram.sendCount());
    clock.advance(std.time.ms_per_s);
    try rig.telegram.waitForSends(2);

    try attachment.answer("900");
    try attachment.answer("901");
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"901\"}",
        try rig.telegram.waitForRequest("/answerCallbackQuery", 1),
    );
    try rig.telegram.finish();
    try std.testing.expectEqual(@as(usize, 1), rig.collector.events.items.len);
}

test "the sender delivers in order, retries a transient failure, and drops a rejected message" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .status = 500, .body = "" },
            .{ .status = 500, .body = "" },
            .{ .body = testing.ok_sent },
            .{
                .status = 400,
                .body = "{\"ok\":false,\"error_code\":400," ++
                    "\"description\":\"Bad Request: message text is empty\"}",
            },
            .{ .body = testing.ok_sent },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try attachment.send("first", &.{ .disable_notification = true });
    try attachment.send("<b>second", &.{ .reply_to = 5 });
    try attachment.send("third", &.{});
    try clock.waitForSleep(retry.backoff.delay(1));
    clock.advance(outage_ms_min);
    try clock.pass(retry.backoff.delay(2));
    try clock.pass(send_spacing_ms);
    try rig.collector.waitFor(3);
    try rig.telegram.finish();
    var buffer: [5][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 5), sends.len);
    for (sends[0..3]) |body| {
        try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"first\"") != null);
    }
    try std.testing.expect(
        std.mem.indexOf(u8, sends[3], "\"reply_parameters\":{\"message_id\":5}") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, sends[4], "\"text\":\"third\"") != null);
    const events = rig.collector.events.items;
    try std.testing.expectEqual(Event.Side.send, events[0].payload.failed.side);
    try std.testing.expectEqual(Event.Side.send, events[1].payload.recovered);
    try std.testing.expectEqual(Event.Rejected.Kind.message, events[2].payload.send_rejected.kind);
    try std.testing.expectEqualStrings(
        "Bad Request: message text is empty",
        events[2].payload.send_rejected.description,
    );
}

test "a delivery that fails at each attempt drops with a report, and the next one goes out" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .status = 500, .body = "" },
            .{
                .status = 429,
                .body = "{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":1}}",
            },
            .{ .status = 502, .body = "" },
            .{ .body = testing.ok_sent },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try attachment.send("lost", &.{});
    try attachment.send("next", &.{});
    try clock.waitForSleep(retry.backoff.delay(1));
    clock.advance(outage_ms_min);
    try clock.pass(std.time.ms_per_s);
    try clock.pass(retry.backoff.delay(2));
    try rig.collector.waitFor(3);
    try rig.telegram.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 4), sends.len);
    for (sends[0..3]) |body| {
        try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"lost\"") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, sends[3], "\"text\":\"next\"") != null);
    const events = rig.collector.events.items;
    try std.testing.expectEqual(Event.Side.send, events[0].payload.failed.side);
    try std.testing.expectEqual(Event.Rejected.Kind.message, events[1].payload.send_dropped);
    try std.testing.expectEqual(Event.Side.send, events[2].payload.recovered);
}

const cannot_parse_reply: testing.Reply = .{
    .status = 400,
    .body = "{\"ok\":false,\"error_code\":400," ++
        "\"description\":\"Bad Request: can't parse entities\"}",
};

const formatted_text = "<b>Telegram</b> rejected &lt;b&gt; &amp; more.";
const formatted_plain = "Telegram rejected <b> & more.";

test "a message whose formatting fails to parse goes again as plain text" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            cannot_parse_reply,
            .{ .body = testing.ok_sent },
            .{ .body = testing.ok_sent },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    const keyboard = "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\"," ++
        "\"callback_data\":\"cancel:1\"}]]}";
    try attachment.send(
        formatted_text,
        &.{ .parse_mode = "HTML", .reply_to = 5, .markup = keyboard },
    );
    try attachment.send("next", &.{});
    try clock.pass(send_spacing_ms);
    try clock.pass(send_spacing_ms);
    try rig.telegram.waitForSends(3);
    try rig.telegram.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"parse_mode\":\"HTML\"") != null);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"" ++ formatted_plain ++ "\",\"disable_notification\":false," ++
            "\"reply_parameters\":{\"message_id\":5},\"reply_markup\":" ++ keyboard ++ "}",
        sends[1],
    );
    try std.testing.expect(std.mem.indexOf(u8, sends[2], "\"text\":\"next\"") != null);
    try std.testing.expectEqual(@as(usize, 0), rig.collector.events.items.len);
}

test "an edit whose formatting fails to parse goes again as plain text on the same message" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
        } },
        .{
            .method = "editMessageText",
            .replies = &.{ cannot_parse_reply, .{ .body = testing.ok_true } },
        },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    const keyboard = "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\"," ++
        "\"callback_data\":\"cancel:1\"}]]}";
    const handle = try attachment.sendTracked("Thinking", &.{});
    try rig.telegram.waitForSends(1);
    try attachment.edit(handle, formatted_text, &.{ .parse_mode = "HTML", .markup = keyboard });
    try clock.pass(send_spacing_ms);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"" ++ formatted_text ++ "\"," ++
            "\"parse_mode\":\"HTML\",\"reply_markup\":" ++ keyboard ++ "}",
        try rig.telegram.waitForRequest("/editMessageText", 0),
    );
    try clock.pass(send_spacing_ms);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"" ++ formatted_plain ++ "\"," ++
            "\"reply_markup\":" ++ keyboard ++ "}",
        try rig.telegram.waitForRequest("/editMessageText", 1),
    );
    try rig.telegram.finish();
    try std.testing.expectEqual(@as(usize, 0), rig.collector.events.items.len);
}

test "an edit waits behind its tracked send, and the newest text replaces a pending one" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{.{
            .body = "{\"ok\":true,\"result\":{\"message_id\":314}}",
            .delay_ms = reply_delay_ms,
        }} },
        .{
            .method = "editMessageText",
            .replies = &.{ .{ .body = testing.ok_true }, .{ .body = testing.ok_true } },
        },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    const keyboard = "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\"," ++
        "\"callback_data\":\"cancel:1\"}]]}";
    const handle = try attachment.sendTracked("Thinking", &.{
        .disable_notification = true,
        .markup = keyboard,
    });
    try attachment.edit(handle, "Writing", &.{ .markup = keyboard });
    try attachment.edit(handle, "Running: bash", &.{ .markup = keyboard });
    try clock.pass(reply_delay_ms);
    try clock.pass(send_spacing_ms);
    _ = try rig.telegram.waitForRequest("/editMessageText", 0);
    try attachment.edit(handle, "Tools: 1 call", &.{});
    try clock.pass(send_spacing_ms);
    _ = try rig.telegram.waitForRequest("/editMessageText", 1);
    try rig.telegram.finish();
    var buffer: [2][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 1), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"reply_markup\":" ++ keyboard) != null);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Running: bash\",\"reply_markup\":" ++
            keyboard ++ "}",
        try rig.telegram.waitForRequest("/editMessageText", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Tools: 1 call\"}",
        try rig.telegram.waitForRequest("/editMessageText", 1),
    );
    try std.testing.expectEqual(@as(usize, 2), rig.telegram.countOf("/editMessageText"));
}

test "a deletion follows the edits of its message, and a later edit of it drops" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{.{
            .body = "{\"ok\":true,\"result\":{\"message_id\":314}}",
            .delay_ms = reply_delay_ms,
        }} },
        .{ .method = "editMessageText", .replies = &.{.{ .body = testing.ok_true }} },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = testing.ok_true }} },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    const handle = try attachment.sendTracked("Effort", &.{ .disable_notification = true });
    try attachment.edit(handle, "Model", &.{});
    try attachment.delete(handle);
    try clock.pass(reply_delay_ms);
    try clock.pass(send_spacing_ms);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Model\"}",
        try rig.telegram.waitForRequest("/editMessageText", 0),
    );
    try clock.pass(send_spacing_ms);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314}",
        try rig.telegram.waitForRequest("/deleteMessage", 0),
    );

    try attachment.edit(handle, "late", &.{});
    try rig.telegram.finish();
    try std.testing.expectEqual(@as(usize, 1), rig.telegram.countOf("/editMessageText"));
}

test "a queued deletion keeps the slot of its message while the queue fills" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
            .{ .body = testing.ok_sent },
            .{ .body = testing.ok_sent },
            .{ .body = testing.ok_sent, .delay_ms = reply_delay_ms },
            .{ .body = testing.ok_sent },
        } },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = testing.ok_true }} },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    const picker = try attachment.sendTracked("Effort", &.{});
    for (0..2) |_| _ = try attachment.sendTracked("settled", &.{});
    _ = try attachment.sendTracked("slow", &.{});
    for (0..3) |_| try clock.pass(send_spacing_ms);
    try rig.telegram.waitForSends(4);
    try attachment.delete(picker);
    for (0..outbound_capacity - 1) |_| _ = try attachment.sendTracked("filler", &.{});

    try clock.pass(reply_delay_ms);
    try clock.pass(send_spacing_ms);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314}",
        try rig.telegram.waitForRequest("/deleteMessage", 0),
    );
    try clock.pass(send_spacing_ms);
    _ = try rig.telegram.waitForRequest("/sendMessage", 4);
    try std.testing.expectEqual(@as(usize, 1), rig.telegram.countOf("/deleteMessage"));
}

test "an answer leaves ahead of the paced sends, and a failed one drops in silence" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = testing.ok_sent, .delay_ms = reply_delay_ms },
            .{ .body = testing.ok_sent },
        } },
        .{ .method = "answerCallbackQuery", .replies = &.{
            .{ .body = testing.ok_true },
            .{
                .status = 400,
                .body = "{\"ok\":false,\"error_code\":400," ++
                    "\"description\":\"Bad Request: query is too old\"}",
            },
            .{ .body = testing.ok_true },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try attachment.send("slow", &.{});
    try rig.telegram.waitForSends(1);
    try attachment.send("behind", &.{});
    try attachment.answer("900");
    try attachment.answer("901");
    try attachment.answer("902");
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\"}",
        try rig.telegram.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"901\"}",
        try rig.telegram.waitForRequest("/answerCallbackQuery", 1),
    );
    _ = try rig.telegram.waitForRequest("/answerCallbackQuery", 2);
    try clock.pass(reply_delay_ms);
    try clock.pass(send_spacing_ms);
    try rig.telegram.waitForSends(2);
    try rig.telegram.finish();
    var last_answer: usize = 0;
    var second_send: usize = 0;
    for (rig.telegram.requests.items, 0..) |request, index| {
        if (std.mem.endsWith(u8, request.path, "/answerCallbackQuery")) last_answer = index;
        if (std.mem.indexOf(u8, request.body, "\"text\":\"behind\"") != null) second_send = index;
    }
    try std.testing.expect(last_answer < second_send);
    try std.testing.expectEqual(@as(usize, 0), rig.collector.events.items.len);
}

test "an edit that arrives during an edit keeps its place in the queue" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
            .{ .body = testing.ok_sent },
        } },
        .{ .method = "editMessageText", .replies = &.{
            .{ .body = testing.ok_true, .delay_ms = reply_delay_ms },
            .{ .body = testing.ok_true },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    const handle = try attachment.sendTracked("Thinking", &.{});
    try attachment.edit(handle, "Writing", &.{});
    try clock.pass(send_spacing_ms);
    _ = try rig.telegram.waitForRequest("/editMessageText", 0);
    try attachment.send("answer", &.{});
    try attachment.edit(handle, "Tools: 0 calls", &.{});
    try clock.pass(reply_delay_ms);
    try clock.pass(send_spacing_ms);
    try clock.pass(send_spacing_ms);
    _ = try rig.telegram.waitForRequest("/editMessageText", 1);
    try rig.telegram.finish();
    var order: [4][]const u8 = undefined;
    var count: usize = 0;
    for (rig.telegram.requests.items) |request| {
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

test "a tracked message with pending work keeps its slot through later tracked sends" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{.{
            .body = "{\"ok\":true,\"result\":{\"message_id\":314}}",
            .delay_ms = reply_delay_ms,
        }} },
        .{ .method = "editMessageText", .replies = &.{.{ .body = testing.ok_true }} },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    const first = try attachment.sendTracked("Thinking", &.{});
    try attachment.edit(first, "Tools: 0 calls", &.{});
    for (0..12) |_| _ = try attachment.sendTracked("Thinking", &.{});
    try clock.pass(reply_delay_ms);
    try clock.pass(send_spacing_ms);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Tools: 0 calls\"}",
        try rig.telegram.waitForRequest("/editMessageText", 0),
    );
    try rig.telegram.finish();
}

test "an edit of a message that never went out drops" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{
                .status = 400,
                .body = "{\"ok\":false,\"error_code\":400," ++
                    "\"description\":\"Bad Request: message text is empty\"}",
            },
            .{ .body = testing.ok_sent },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    const handle = try attachment.sendTracked("", &.{});
    try attachment.edit(handle, "Writing", &.{});
    try attachment.send("next", &.{});
    try rig.collector.waitFor(1);
    try rig.telegram.waitForSends(2);
    try rig.telegram.finish();
    try std.testing.expectEqual(
        Event.Rejected.Kind.message,
        rig.collector.events.items[0].payload.send_rejected.kind,
    );
    try std.testing.expectEqual(@as(usize, 0), rig.telegram.countOf("/editMessageText"));
    var buffer: [4][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"next\"") != null);
}

test "a 403 on a send detaches" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{
                .status = 403,
                .body = "{\"ok\":false,\"error_code\":403,\"description\":\"Forbidden\"}",
            },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    defer attachment.destroy();
    try attachment.start();

    try attachment.send("hello", &.{});
    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    try std.testing.expectEqualStrings(
        "Forbidden",
        rig.collector.events.items[0].payload.detach.forbidden,
    );
}

test "a close drops the queue, sends the final message alone, and then refuses a send" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{
            .method = "sendMessage",
            .replies = &.{ .{ .body = testing.ok_sent }, .{ .body = testing.ok_sent } },
        },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try rig.telegram.waitForLongPoll();

    try attachment.send("first", &.{});
    try rig.telegram.waitForSends(1);
    try attachment.send("queued", &.{});
    try clock.waitForSleep(send_spacing_ms);
    try attachment.close(&.{ .text = "final" });
    try std.testing.expectError(error.Closed, attachment.send("too late", &.{}));
    try rig.collector.waitFor(1);
    try std.testing.expect(rig.collector.events.items[0].payload == .drained);
    destroyed = true;
    attachment.destroy();
    try rig.telegram.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"disable_notification\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), rig.collector.events.items.len);
}

test "a full queue refuses a send, and the final message still ends the chat" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = testing.ok_sent, .delay_ms = reply_delay_ms },
            .{ .body = testing.ok_sent },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try rig.telegram.waitForLongPoll();

    try attachment.send("first", &.{});
    try rig.telegram.waitForSends(1);
    for (0..outbound_capacity) |_| try attachment.send("ordinary", &.{});
    try std.testing.expectError(error.QueueFull, attachment.send("one too many", &.{}));

    try attachment.close(&.{ .text = "final" });
    destroyed = true;
    attachment.destroy();
    try rig.telegram.finish();
    var buffer: [outbound_capacity + 2][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
}

test "a send in flight at the close cannot hold the final message back" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = testing.ok_sent, .delay_ms = reply_delay_ms },
            .{ .body = testing.ok_sent },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try rig.telegram.waitForLongPoll();

    try attachment.send("slow", &.{});
    try clock.waitForSleep(reply_delay_ms);
    try attachment.close(&.{ .text = "final" });
    destroyed = true;
    attachment.destroy();
    try rig.telegram.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"slow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
}

test "a final message whose formatting fails to parse goes again as plain text" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{
            .method = "sendMessage",
            .replies = &.{ cannot_parse_reply, .{ .body = testing.ok_sent } },
        },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try rig.telegram.waitForLongPoll();

    try attachment.close(&.{ .text = formatted_text, .parse_mode = "HTML" });
    destroyed = true;
    attachment.destroy();
    try rig.telegram.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"parse_mode\":\"HTML\"") != null);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"" ++ formatted_plain ++ "\",\"disable_notification\":true}",
        sends[1],
    );
}

test "a rejected final message that no parse failure caused goes out once" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{
                .status = 400,
                .body = "{\"ok\":false,\"error_code\":400," ++
                    "\"description\":\"Bad Request: chat not found\"}",
            },
        } },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try rig.telegram.waitForLongPoll();

    try attachment.close(&.{ .text = "<b>final</b>", .parse_mode = "HTML" });
    destroyed = true;
    attachment.destroy();
    try rig.telegram.finish();
    try std.testing.expectEqual(@as(usize, 1), rig.telegram.sendCount());
}

test "a 429 on the final message pauses the drain for the stated wait" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts ++ [_]testing.Script{
        .{
            .method = "sendMessage",
            .replies = &.{ rate_limited_reply, .{ .body = testing.ok_sent } },
        },
    });
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try rig.telegram.waitForLongPoll();

    try attachment.close(&.{ .text = "final" });
    try clock.waitForSleep(std.time.ms_per_s);
    try std.testing.expectEqual(@as(usize, 1), rig.telegram.sendCount());
    clock.advance(std.time.ms_per_s);
    try rig.collector.waitFor(1);
    try std.testing.expect(rig.collector.events.items[0].payload == .drained);
    destroyed = true;
    attachment.destroy();
    try rig.telegram.finish();
    try std.testing.expectEqual(@as(usize, 2), rig.telegram.sendCount());
}

test "an abort ends the drain at once and drops the final message in flight" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts);
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    var ended = false;
    defer if (!ended) attachment.destroy();
    try attachment.start();
    try attachment.send("in flight", &.{});
    try attachment.send("queued", &.{});
    try rig.telegram.waitForSends(1);
    _ = try rig.telegram.waitForRequest("/getUpdates", 0);

    try attachment.close(&.{ .text = "final" });
    try rig.telegram.waitForSends(2);
    ended = true;
    attachment.abort();
    try rig.telegram.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = rig.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
}

test "a task that cannot start ends the attachment at once, and the calling task emits no event" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 1, 3 }) |tasks_max| {
        var threaded: std.Io.Threaded = .init(gpa, .{ .concurrent_limit = .limited(tasks_max) });
        defer threaded.deinit();
        const io = threaded.io();
        var collector: Collector = .{ .gpa = gpa, .io = io };
        defer collector.deinit();
        var telegram = try testing.Telegram.init(gpa, io, &.{});
        defer telegram.deinit();
        const attachment = try create(gpa, io, &.{
            .transport = telegram.transport(),
            .token = "42:secret",
            .username = "drinky_bot",
            .chat_id = 99,
            .connect_ms = 60_000,
            .generation = 7,
            .sink = collector.sink(),
            .commands = &.{},
        });

        if (tasks_max == 1) {
            const started = attachment.start();
            attachment.destroy();
            try std.testing.expectError(error.ConcurrencyUnavailable, started);
        } else {
            try attachment.start();
            const ended = attachment.close(&.{ .text = "final" });
            attachment.destroy();
            try std.testing.expectError(error.ConcurrencyUnavailable, ended);
        }
        for (collector.events.items) |event| try std.testing.expect(event.payload == .failed);
    }
}

test "a held send cannot hold the drain past its deadline" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts);
    defer rig.deinit();
    const attachment = try testAttachment(&rig);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try attachment.send("never lands", &.{});
    try rig.telegram.waitForLongPoll();

    try attachment.close(&.{ .text = "never lands either" });
    try clock.pass(drain_ms);
    try rig.collector.waitFor(1);
    try std.testing.expect(rig.collector.events.items[0].payload == .drained);
    destroyed = true;
    attachment.destroy();
    try rig.telegram.finish();
}

test "a send in a zero window cannot hold the drain past its deadline" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &testing.quiet_scripts);
    defer rig.deinit();
    const attachment = try create(gpa, io, &.{
        .transport = rig.telegram.transport(),
        .token = "42:secret",
        .username = "drinky_bot",
        .chat_id = 99,
        .connect_ms = 0,
        .generation = 7,
        .sink = rig.collector.sink(),
        .commands = &.{},
    });
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try attachment.send("never lands", &.{});
    try rig.telegram.waitForSends(1);
    try rig.telegram.waitForLongPoll();

    try attachment.close(&.{ .text = "never lands either" });
    try clock.pass(drain_ms);
    try rig.collector.waitFor(1);
    try std.testing.expect(rig.collector.events.items[0].payload == .drained);
    destroyed = true;
    attachment.destroy();
    try rig.telegram.finish();
}

test "a copy of each event owns its bytes, and a failed copy leaks nothing" {
    const events = [_]Event{
        .{ .generation = 1, .payload = .{ .message = .{ .id = 2, .text = "hello" } } },
        .{ .generation = 1, .payload = .{ .callback = .{
            .query_id = "900",
            .message_id = 50,
            .data = "cancel:3",
        } } },
        .{ .generation = 1, .payload = .{ .send_rejected = .{
            .kind = .message,
            .description = "Bad Request",
        } } },
        .{ .generation = 1, .payload = .{ .detach = .conflict } },
        .{ .generation = 1, .payload = .drained },
    };
    try core.testing.checkCopyAllocationFailures(Event, &events);
}

test "a copy of a detach keeps its reason, and a failed copy drops only the description" {
    const description = "Forbidden: bot was blocked by the user";
    const event: Event = .{ .generation = 3, .payload = .{ .detach = .{
        .forbidden = description,
    } } };
    const cases = [_]struct { fail_index: usize, kept: []const u8 }{
        .{ .fail_index = std.math.maxInt(usize), .kept = description },
        .{ .fail_index = 0, .kept = "" },
    };
    for (cases) |case| {
        var failing: std.testing.FailingAllocator = .init(
            std.testing.allocator,
            .{ .fail_index = case.fail_index },
        );
        const gpa = failing.allocator();
        const copy = try event.dupe(gpa);
        defer copy.deinit(gpa);
        try std.testing.expectEqual(@as(u64, 3), copy.generation);
        try std.testing.expectEqualStrings(case.kept, copy.payload.detach.forbidden);
    }
}
