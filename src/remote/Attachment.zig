const std = @import("std");

const ai = @import("ai");

const Client = @import("Client.zig");
const html = @import("html.zig");

const Attachment = @This();

pub const outbound_capacity = 256;

const drain_ms_default = 2_000;

const send_spacing_ms_default = 1_000;

const backoff_default: ai.net.Retry = .{
    .attempts_max = std.math.maxInt(u32),
    .backoff_ms_initial = 500,
    .backoff_ms_max = 16_000,
};

const outage_ms_min_default = 30_000;

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
pace: Pace,
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

pub const Options = struct {
    base_url: []const u8 = Client.api_url,
    token: []const u8,
    username: []const u8,
    chat_id: i64,
    connect_ms: u64,
    generation: u64,
    sink: Sink,
    pace: Pace = .{},
    commands: []const Client.Command = &.{},
};

pub const Pace = struct {
    drain_ms: u64 = drain_ms_default,
    send_spacing_ms: u64 = send_spacing_ms_default,
    backoff: ai.net.Retry = backoff_default,
    outage_ms_min: u64 = outage_ms_min_default,
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: Event) error{Closed}!void,
};

pub const Event = struct {
    generation: u64,
    payload: Payload,

    pub const Payload = union(enum) {
        message: Message,
        unreadable: i64,
        callback: Callback,
        failed: Failure,
        recovered: Side,
        send_rejected: Rejected,
        detach: Reason,
        drained,
    };

    pub const Message = struct {
        id: i64,
        text: []u8,
    };

    pub const Callback = struct {
        query_id: []u8,
        message_id: i64,
        data: []u8,
    };

    pub const Failure = struct {
        side: Side,
        name: []const u8,
    };

    pub const Rejected = struct {
        kind: Kind,
        description: []u8,

        pub const Kind = enum { message, edit, deletion };
    };

    pub const Side = enum { poll, send };

    pub const Reason = enum {
        unauthorized,
        forbidden,
        conflict,
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

    fn free(self: *const Tracked) bool {
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

pub fn start(self: *Attachment) !void {
    std.debug.assert(self.poll_future == null and self.send_future == null);
    std.debug.assert(self.answer_future == null);
    self.send_future = try self.io.concurrent(runSender, .{self});
    errdefer self.close(null) catch unreachable;
    self.answer_future = try self.io.concurrent(runAnswerer, .{self});
    self.poll_future = try self.io.concurrent(runPoller, .{self});
}

pub fn send(self: *Attachment, text: []const u8, options: *const Client.SendOptions) SendError!void {
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
        if (!slot.free()) continue;
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

pub const Final = struct {
    text: []const u8,
    parse_mode: ?[]const u8 = null,
};

pub fn close(self: *Attachment, final: ?Final) error{OutOfMemory}!void {
    if (self.closed()) return;
    defer {
        self.drain_deadline_ms.store(
            self.nowMs() + @as(i64, @intCast(self.pace.drain_ms)),
            .release,
        );
        self.outbound.close(self.io);
        self.answers.close(self.io);
        self.drain_future = self.io.concurrent(runDrain, .{self}) catch null;
        if (self.drain_future == null) self.runDrain();
    }
    const message = final orelse return;
    self.final = .{
        .text = try self.gpa.dupe(u8, message.text),
        .options = .{
            .disable_notification = true,
            .parse_mode = message.parse_mode,
        },
        .markup = null,
        .handle = null,
    };
}

pub fn abort(self: *Attachment) void {
    self.close(null) catch unreachable;
    self.drain_deadline_ms.store(@max(1, self.nowMs()), .release);
    if (self.drain_future) |*future| {
        future.cancel(self.io);
        self.drain_future = null;
    }
    self.destroy();
}

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

fn deliverFinal(self: *Attachment, final: *const Outbound.Send) void {
    const client = &self.send_client;
    var failures: u32 = 0;
    var delivery: Delivery = .{ .send = final.* };
    var maybe_plain: ?[]u8 = null;
    defer if (maybe_plain) |plain| self.gpa.free(plain);
    while (true) {
        const remaining = self.drainRemainingMs() orelse unreachable;
        if (remaining == 0) return;
        client.connect_ms = if (client.connect_ms == 0) remaining else @min(client.connect_ms, remaining);
        _ = client.sendMessage(
            self.chat_id,
            delivery.send.text,
            &delivery.send.options,
        ) catch |err| switch (err) {
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
            error.Rejected => {
                if (!rejectedParse(client)) return;
                maybe_plain = self.plainOf(&delivery) orelse return;
                continue;
            },
            error.Canceled,
            error.Unauthorized,
            error.Forbidden,
            error.Conflict,
            => return,
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

fn emit(self: *Attachment, payload: Event.Payload) error{Closed}!void {
    return self.sink.emit(self.sink.context, .{ .generation = self.generation, .payload = payload });
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
    self.io.sleep(.fromMilliseconds(@intCast(wait_ms)), .awake) catch return error.Canceled;
}

fn runPoller(self: *Attachment) void {
    self.pollUntilEnd() catch {};
}

fn pollUntilEnd(self: *Attachment) error{ Closed, Canceled }!void {
    var state: PollState = .{};
    var outage: Outage = .{};
    var failures: u32 = 0;
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
                if (outage.reports(self, @errorName(err)))
                    try self.emit(.{ .failed = .{ .side = .poll, .name = outage.name } });
                failures +|= 1;
                try self.pause(self.pace.backoff.backoffMs(.{ .attempt = failures }));
                continue;
            },
        };
        if (outage.ends()) try self.emit(.{ .recovered = .poll });
        failures = 0;
    }
}

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
        if (now_ms - started_ms < attachment.pace.outage_ms_min) return false;
        self.reported = true;
        return true;
    }

    fn ends(self: *Outage) bool {
        const reported = self.reported;
        self.* = .{};
        return reported;
    }
};

const PollState = struct {
    webhook_deleted: bool = false,
    commands_set: bool = false,
    confirmed: bool = false,
    offset: ?i64 = null,
};

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

fn runSender(self: *Attachment) void {
    var state: SendState = .{};
    self.sendUntilClosed(&state) catch {};
}

const SendState = struct {
    outage: Outage = .{},
    failures: u32 = 0,
    sent_ms: ?i64 = null,
};

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
        client.answerCallbackQuery(query_id) catch |err| switch (err) {
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
) error{ Closed, Canceled, Detached }!void {
    var delivery = delivery_in;
    var maybe_plain: ?[]u8 = null;
    defer if (maybe_plain) |plain| self.gpa.free(plain);
    const client = &self.send_client;
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
                if (rejectedParse(client)) {
                    if (self.plainOf(&delivery)) |plain| {
                        maybe_plain = plain;
                        state.sent_ms = self.nowMs();
                        continue;
                    }
                }
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
                if (state.outage.reports(self, @errorName(err)))
                    try self.emit(.{ .failed = .{ .side = .send, .name = state.outage.name } });
                state.failures +|= 1;
                try self.pause(self.pace.backoff.backoffMs(.{ .attempt = state.failures }));
                continue;
            },
        };
        state.sent_ms = self.nowMs();
        if (state.outage.ends()) try self.emit(.{ .recovered = .send });
        state.failures = 0;
        return;
    }
}

fn detach(self: *Attachment, reason: Event.Reason) error{ Closed, Detached } {
    try self.emit(.{ .detach = reason });
    return error.Detached;
}

const testing = @import("testing.zig");

const Collector = testing.Collector(Event, Sink);

const ok_true = "{\"ok\":true,\"result\":true}";
const ok_empty = "{\"ok\":true,\"result\":[]}";
const ok_sent = "{\"ok\":true,\"result\":{\"message_id\":1}}";

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
    return testAttachmentPaced(gpa, io, server, url_buffer, collector, testing.pace);
}

fn testAttachmentPaced(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *const testing.Server,
    url_buffer: []u8,
    collector: *Collector,
    pace: Pace,
) !*Attachment {
    return create(gpa, io, &.{
        .base_url = server.url(url_buffer),
        .token = "42:secret",
        .username = "drinky_bot",
        .chat_id = 99,
        .connect_ms = 60_000,
        .generation = 7,
        .sink = collector.sink(),
        .pace = pace,
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
    try std.testing.expectEqualStrings(
        "{\"offset\":41,\"timeout\":55,\"allowed_updates\":[\"message\",\"callback_query\"]}",
        server.requests.items[3].body,
    );
    const events = collector.events.items;
    try std.testing.expectEqual(@as(u64, 7), events[0].generation);
    try std.testing.expectEqual(@as(i64, 2), events[0].payload.message.id);
    try std.testing.expectEqualStrings("hello", events[0].payload.message.text);
    try std.testing.expectEqual(@as(i64, 4), events[1].payload.unreadable);
    try std.testing.expectEqualStrings("901", events[2].payload.callback.query_id);
    try std.testing.expectEqual(@as(i64, 50), events[2].payload.callback.message_id);
    try std.testing.expectEqualStrings("cancel:3", events[2].payload.callback.data);
}

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

    try server.waitForLongPoll();
    try server.finish();
    try std.testing.expectEqual(
        @as(u64, Client.poll_connect_ms_min),
        attachment.poll_client.connect_ms,
    );
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

test "a poll outage under the threshold reports nothing" {
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
            .{ .body = ok_empty },
            .{ .status = 409, .body = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict\"}" },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    var pace = testing.pace;
    pace.outage_ms_min = 60_000;
    const attachment = try testAttachmentPaced(gpa, io, &server, &url_buffer, &collector, pace);
    defer attachment.destroy();
    try attachment.start();

    try collector.waitFor(1);
    try server.finish();
    const events = collector.events.items;
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(Event.Reason.conflict, events[0].payload.detach);
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

const cannot_parse_reply: testing.Reply = .{
    .status = 400,
    .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: can't parse entities\"}",
};

const formatted_text = "<b>Telegram</b> rejected &lt;b&gt; &amp; more.";
const formatted_plain = "Telegram rejected <b> & more.";

test "a message whose formatting fails to parse goes again as plain text" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            cannot_parse_reply,
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

    const keyboard = "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:1\"}]]}";
    try attachment.send(formatted_text, &.{ .parse_mode = "HTML", .reply_to = 5, .markup = keyboard });
    try attachment.send("next", &.{});
    try server.waitForSends(3);
    try server.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"parse_mode\":\"HTML\"") != null);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"" ++ formatted_plain ++ "\",\"disable_notification\":false," ++
            "\"reply_parameters\":{\"message_id\":5},\"reply_markup\":" ++ keyboard ++ "}",
        sends[1],
    );
    try std.testing.expect(std.mem.indexOf(u8, sends[2], "\"text\":\"next\"") != null);
    try std.testing.expectEqual(@as(usize, 0), collector.events.items.len);
}

test "an edit whose formatting fails to parse goes again as plain text on the same message" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
        } },
        .{ .method = "editMessageText", .replies = &.{ cannot_parse_reply, .{ .body = ok_true } } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    const keyboard = "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\",\"callback_data\":\"cancel:1\"}]]}";
    const handle = try attachment.sendTracked("Thinking", &.{});
    try server.waitForSends(1);
    try attachment.edit(handle, formatted_text, &.{ .parse_mode = "HTML", .markup = keyboard });
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"" ++ formatted_text ++ "\"," ++
            "\"parse_mode\":\"HTML\",\"reply_markup\":" ++ keyboard ++ "}",
        try server.waitForRequest("/editMessageText", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"" ++ formatted_plain ++ "\"," ++
            "\"reply_markup\":" ++ keyboard ++ "}",
        try server.waitForRequest("/editMessageText", 1),
    );
    try server.finish();
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

    const keyboard = "{\"inline_keyboard\":[[{\"text\":\"Close\",\"callback_data\":\"close:1\"}]]}";
    const handle = try attachment.sendTracked("Thinking", &.{
        .disable_notification = true,
        .markup = keyboard,
    });
    try attachment.edit(handle, "Writing", &.{ .markup = keyboard });
    try attachment.edit(handle, "Running: bash", &.{ .markup = keyboard });
    _ = try server.waitForRequest("/editMessageText", 0);
    try attachment.edit(handle, "Tools: 1 call", &.{});
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

test "a deletion follows the edits of its message, and a later edit of it drops" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}", .delay_ms = 100 },
        } },
        .{ .method = "editMessageText", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    defer attachment.destroy();
    try attachment.start();

    const handle = try attachment.sendTracked("Effort", &.{ .disable_notification = true });
    try attachment.edit(handle, "Model", &.{});
    try attachment.delete(handle);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Model\"}",
        try server.waitForRequest("/editMessageText", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314}",
        try server.waitForRequest("/deleteMessage", 0),
    );

    try attachment.edit(handle, "late", &.{});
    try server.finish();
    try std.testing.expectEqual(@as(usize, 1), server.countOf("/editMessageText"));
}

test "a queued deletion keeps the slot of its message while the queue fills" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
            .{ .body = ok_sent },
            .{ .body = ok_sent },
            .{ .body = ok_sent, .delay_ms = 100 },
            .{ .body = ok_sent },
        } },
        .{ .method = "deleteMessage", .replies = &.{.{ .body = ok_true }} },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    var pace = testing.pace;
    pace.send_spacing_ms = 0;
    const attachment = try testAttachmentPaced(gpa, io, &server, &url_buffer, &collector, pace);
    defer attachment.destroy();
    try attachment.start();

    const picker = try attachment.sendTracked("Effort", &.{});
    for (0..2) |_| _ = try attachment.sendTracked("settled", &.{});
    _ = try attachment.sendTracked("slow", &.{});
    try server.waitForSends(4);
    try attachment.delete(picker);
    for (0..outbound_capacity - 1) |_| _ = try attachment.sendTracked("filler", &.{});

    _ = try server.waitForRequest("/sendMessage", 4);
    try std.testing.expectEqual(@as(usize, 1), server.countOf("/deleteMessage"));
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314}",
        try server.waitForRequest("/deleteMessage", 0),
    );
}

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
    var pace = testing.pace;
    pace.send_spacing_ms = 50;
    const attachment = try testAttachmentPaced(gpa, io, &server, &url_buffer, &collector, pace);
    defer attachment.destroy();
    try attachment.start();

    try attachment.send("slow", &.{});
    try server.waitForSends(1);
    try attachment.send("behind", &.{});
    try attachment.answer("900");
    try attachment.answer("901");
    try attachment.answer("902");
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\"}",
        try server.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"901\"}",
        try server.waitForRequest("/answerCallbackQuery", 1),
    );
    _ = try server.waitForRequest("/answerCallbackQuery", 2);
    try server.waitForSends(2);
    try server.finish();
    var last_answer: usize = 0;
    var second_send: usize = 0;
    for (server.requests.items, 0..) |request, index| {
        if (std.mem.endsWith(u8, request.path, "/answerCallbackQuery")) last_answer = index;
        if (std.mem.indexOf(u8, request.body, "\"text\":\"behind\"") != null) second_send = index;
    }
    try std.testing.expect(last_answer < second_send);
    try std.testing.expectEqual(@as(usize, 0), collector.events.items.len);
}

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
    try attachment.edit(handle, "Writing", &.{});
    _ = try server.waitForRequest("/editMessageText", 0);
    try attachment.send("answer", &.{});
    try attachment.edit(handle, "Tools: 0 calls", &.{});
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
    var pace = testing.pace;
    pace.send_spacing_ms = 0;
    const attachment = try testAttachmentPaced(gpa, io, &server, &url_buffer, &collector, pace);
    defer attachment.destroy();
    try attachment.start();

    const first = try attachment.sendTracked("Thinking", &.{});
    try attachment.edit(first, "Tools: 0 calls", &.{});
    for (0..later_sends) |_| _ = try attachment.sendTracked("Thinking", &.{});
    const summary = try server.waitForRequest("/editMessageText", 0);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Tools: 0 calls\"}",
        summary,
    );
    try server.finish();
}

test "an edit of a message that never went out drops" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
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

    const handle = try attachment.sendTracked("", &.{});
    try attachment.edit(handle, "Writing", &.{});
    try attachment.send("next", &.{});
    try collector.waitFor(1);
    try server.waitForSends(2);
    try server.finish();
    try std.testing.expectEqual(Event.Rejected.Kind.message, collector.events.items[0].payload.send_rejected.kind);
    var sends: usize = 0;
    for (server.requests.items) |request| {
        try std.testing.expect(!std.mem.endsWith(u8, request.path, "/editMessageText"));
        if (!std.mem.endsWith(u8, request.path, "/sendMessage")) continue;
        sends += 1;
        if (sends == 2) try std.testing.expect(std.mem.indexOf(u8, request.body, "\"text\":\"next\"") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), sends);
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
    var pace = testing.pace;
    pace.send_spacing_ms = 10 * testing.pace.drain_ms;
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
    try server.waitForLongPoll();

    try attachment.send("first", &.{});
    try server.waitForSends(1);
    try attachment.send("queued", &.{});
    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try attachment.close(.{ .text = "final" });
    try std.testing.expectError(error.Closed, attachment.send("too late", &.{}));
    try collector.waitFor(1);
    try std.testing.expect(collector.events.items[0].payload == .drained);
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms < testing.pace.drain_ms);
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
    try server.waitForLongPoll();

    try attachment.send("first", &.{});
    try server.waitForSends(1);
    for (0..outbound_capacity) |_| try attachment.send("ordinary", &.{});
    try std.testing.expectError(error.QueueFull, attachment.send("one too many", &.{}));

    try attachment.close(.{ .text = "final" });
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
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .body = ok_sent, .delay_ms = testing.drain_half_ms },
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
    try server.waitForLongPoll();

    try attachment.send("slow", &.{});
    try server.waitForSends(1);
    try attachment.close(.{ .text = "final" });
    destroyed = true;
    attachment.destroy();
    try server.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"slow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"text\":\"final\"") != null);
}

test "a final message whose formatting fails to parse goes again as plain text" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{ cannot_parse_reply, .{ .body = ok_sent } } },
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
    try server.waitForLongPoll();

    try attachment.close(.{ .text = formatted_text, .parse_mode = "HTML" });
    destroyed = true;
    attachment.destroy();
    try server.finish();
    var buffer: [4][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 2), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"parse_mode\":\"HTML\"") != null);
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"" ++ formatted_plain ++ "\",\"disable_notification\":true}",
        sends[1],
    );
}

test "a rejected final message that no parse failure caused goes out once" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &quiet_scripts ++ [_]testing.Script{
        .{ .method = "sendMessage", .replies = &.{
            .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: chat not found\"}" },
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
    try server.waitForLongPoll();

    try attachment.close(.{ .text = "<b>final</b>", .parse_mode = "HTML" });
    destroyed = true;
    attachment.destroy();
    try server.finish();
    try std.testing.expectEqual(@as(usize, 1), server.sendCount());
}

test "an abort ends the drain at once and sends no final message" {
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
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    var ended = false;
    defer if (!ended) attachment.destroy();
    try attachment.start();
    try attachment.send("in flight", &.{});
    try attachment.send("queued", &.{});
    try server.waitForSends(1);
    _ = try server.waitForRequest("/getUpdates", 0);

    try attachment.close(.{ .text = "final" });
    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    ended = true;
    attachment.abort();
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms < testing.drain_half_ms);
    try std.testing.expectEqual(@as(usize, 1), server.sendCount());
    try server.finish();
}

test "the default drain window is two seconds" {
    const pace: Pace = .{};
    try std.testing.expectEqual(@as(u64, 2_000), pace.drain_ms);
}

test "a dead network cannot hold the drain past its deadline" {
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
    const attachment = try testAttachment(gpa, io, &server, &url_buffer, &collector);
    var destroyed = false;
    defer if (!destroyed) attachment.destroy();
    try attachment.start();
    try attachment.send("never lands", &.{});
    try server.waitForLongPoll();

    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try attachment.close(.{ .text = "never lands either" });
    destroyed = true;
    attachment.destroy();
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms >= testing.pace.drain_ms - 10);
    try std.testing.expect(elapsed_ms < testing.pace.drain_ms + 500);
    try server.finish();
}
