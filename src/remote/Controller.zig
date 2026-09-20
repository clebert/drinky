const std = @import("std");

const ai = @import("ai");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const html = @import("html.zig");
const keyboard = @import("keyboard.zig");
const Pairing = @import("Pairing.zig");
const Store = @import("Store.zig");

const Controller = @This();

const bot_commands = blk: {
    var count = 0;
    for (ai.command.summaries) |summary| {
        if (summary.remote and summary.tail.len == 0) count += 1;
    }
    var list: [count]Client.Command = undefined;
    var index = 0;
    for (ai.command.summaries) |summary| {
        if (!summary.remote or summary.tail.len != 0) continue;
        list[index] = .{ .command = summary.name, .description = summary.summary };
        index += 1;
    }
    break :blk list;
};

gpa: std.mem.Allocator,
io: std.Io,
store: Store,
mode: Mode,
generation: u64,
sink: Sink,
attachment_sink: Attachment.Sink,
pairing_sink: Pairing.Sink,
base_url: []const u8,
connect_ms: u64,
pace: Attachment.Pace,
code: ?Pairing.Code,
dropped_count: usize,

const Mode = union(enum) {
    idle,
    token_prompt,
    checking_token: *Pairing,
    pairing: *Pairing,
    attached: *Attachment,
    detaching: *Attachment,
};

pub const State = std.meta.Tag(Mode);

pub const Options = struct {
    store: Store,
    sink: Sink,
    attachment_sink: Attachment.Sink,
    pairing_sink: Pairing.Sink,
    base_url: []const u8 = Client.api_url,
    connect_ms: u64 = (ai.net.Timeouts{}).connect_ms,
    pace: Attachment.Pace = .{},
    code: ?Pairing.Code = null,
};

pub const Sink = struct {
    context: *anyopaque,
    act: *const fn (context: *anyopaque, action: Action) anyerror!void,
};

pub const Action = union(enum) {
    chat_message: ChatMessage,
    cancel_tap: CancelTap,
    report: Report,
    state_changed,
    pairing_changed: PairingChange,

    pub const ChatMessage = struct {
        id: i64,
        text: []const u8,
    };

    pub const CancelTap = struct {
        query_id: []const u8,
        serial: u64,
    };

    pub const Report = struct {
        kind: Kind,
        severity: ai.command.Outcome.Severity,
        text: []const u8,

        pub const Kind = enum {
            event,
            terminal_event,
            notice,
        };
    };

    pub const PairingChange = enum {
        check_started,
        code_ready,
        prompt_restored,
        ended,
    };
};

pub const DetachCause = union(enum) {
    user,
    exit,
    credential_rejected,
    failure: Attachment.Event.Reason,
};

pub const CancelScope = enum {
    step,
    command,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: *const Options) Controller {
    return .{
        .gpa = gpa,
        .io = io,
        .store = options.store,
        .mode = .idle,
        .generation = 0,
        .sink = options.sink,
        .attachment_sink = options.attachment_sink,
        .pairing_sink = options.pairing_sink,
        .base_url = options.base_url,
        .connect_ms = options.connect_ms,
        .pace = options.pace,
        .code = options.code,
        .dropped_count = 0,
    };
}

pub fn openStore(self: *Controller, home: []const u8) !void {
    const store = try Store.open(self.gpa, self.io, home);
    self.store.deinit();
    self.store = store;
}

pub fn shutdown(self: *Controller) void {
    self.detach(.exit) catch {};
    switch (self.mode) {
        .attached, .detaching => |attachment| attachment.destroy(),
        .checking_token, .pairing => |pairing| pairing.destroy(),
        .idle, .token_prompt => {},
    }
    self.mode = .idle;
}

pub fn deinit(self: *Controller) void {
    self.shutdown();
    self.store.deinit();
}

pub fn state(self: *const Controller) State {
    return self.mode;
}

pub fn pairs(self: *const Controller) bool {
    return switch (self.mode) {
        .checking_token, .pairing => true,
        else => false,
    };
}

pub fn usernames(self: *const Controller) []const []const u8 {
    return self.store.usernames.items;
}

pub fn loadError(self: *const Controller) ?anyerror {
    return self.store.load_error;
}

pub fn storePath(self: *const Controller) []const u8 {
    return self.store.path;
}

pub fn botUsername(self: *const Controller) ?[]const u8 {
    return switch (self.mode) {
        .attached, .detaching => |attachment| attachment.username,
        else => null,
    };
}

pub fn pairingCode(self: *const Controller) *const Pairing.Code {
    return &self.mode.pairing.code;
}

pub fn pairingUsername(self: *const Controller) []const u8 {
    return self.mode.pairing.username;
}

pub fn pairingLink(self: *const Controller, buffer: []u8) []const u8 {
    return self.mode.pairing.link(buffer);
}

pub fn beginTokenPrompt(self: *Controller) !void {
    std.debug.assert(self.mode == .idle);
    self.mode = .token_prompt;
    try self.showNotice(.information, "Paste the token that @BotFather gave you.", .{});
    try self.emit(.state_changed);
}

pub fn cancelTokenPrompt(self: *Controller) !void {
    std.debug.assert(self.mode == .token_prompt);
    self.mode = .idle;
    try self.showNotice(.information, "You canceled the bot token.", .{});
    try self.emit(.state_changed);
}

pub fn submitToken(self: *Controller, token: []const u8) !void {
    std.debug.assert(self.mode == .token_prompt);
    if (token.len == 0) return self.showNotice(.warning, "Type the bot token.", .{});
    if (!Client.validToken(token)) return self.showNotice(
        .failure,
        "A bot token holds digits, a colon, and the letters, digits, `_`, and `-` of its secret.",
        .{},
    );
    const pairing = try self.createPairing(token);
    errdefer pairing.destroy();
    self.mode = .{ .checking_token = pairing };
    errdefer {
        self.mode = .token_prompt;
        self.emit(.{ .pairing_changed = .prompt_restored }) catch {};
    }
    try self.emit(.{ .pairing_changed = .check_started });
    try pairing.startCheck();
    try self.emit(.state_changed);
}

pub fn cancelPairing(self: *Controller, scope: CancelScope) !void {
    switch (self.mode) {
        .checking_token => |pairing| {
            pairing.destroy();
            if (scope == .step) {
                self.mode = .token_prompt;
                try self.emit(.{ .pairing_changed = .prompt_restored });
                try self.showNotice(.information, "You canceled the token check.", .{});
            } else {
                self.mode = .idle;
                try self.emit(.{ .pairing_changed = .ended });
                try self.showNotice(.information, "You canceled the bot token.", .{});
            }
        },
        .pairing => |pairing| {
            const username = try self.gpa.dupe(u8, pairing.username);
            defer self.gpa.free(username);
            pairing.destroy();
            self.mode = .idle;
            try self.emit(.{ .pairing_changed = .ended });
            try self.recordEvent(.information, "You canceled the pairing of @{s}.", .{username});
        },
        else => unreachable,
    }
    try self.emit(.state_changed);
}

pub fn attachSaved(self: *Controller, index: usize) !void {
    const bot = self.store.get(index) orelse
        return self.showNotice(.failure, "Select a valid row.", .{});
    if (self.mode != .idle) return self.showNotice(.warning, "Drinky cannot attach a bot now.", .{});
    if (bot.chat_id == null) return self.startWait(bot);
    try self.startAttachment(bot);
}

pub fn removeBot(self: *Controller, index: usize) !void {
    const bot = self.store.get(index) orelse
        return self.showNotice(.failure, "Select a valid row.", .{});
    const username = try self.gpa.dupe(u8, bot.username);
    defer self.gpa.free(username);
    self.store.remove(index) catch |err| return self.showNotice(
        .failure,
        "Drinky could not remove the bot @{s} because of error {s}.",
        .{ username, @errorName(err) },
    );
    try self.recordEvent(.information, "Drinky removed the bot @{s}.", .{username});
}

pub fn detach(self: *Controller, cause: DetachCause) !void {
    const attachment = switch (self.mode) {
        .attached => |attachment| attachment,
        else => return,
    };
    const severity: ai.command.Outcome.Severity = switch (cause) {
        .user, .exit => .information,
        .credential_rejected, .failure => .failure,
    };
    const text = try self.detachText(cause, attachment.username);
    defer self.gpa.free(text);
    const line = try html.wrapAlloc(self.gpa, .of(severity), text);
    defer self.gpa.free(line);
    attachment.close(.{ .text = line, .parse_mode = html.parse_mode }) catch |err| switch (err) {
        error.OutOfMemory => {},
    };
    self.mode = .{ .detaching = attachment };
    try self.tell(.terminal_event, severity, text);
    try self.emit(.state_changed);
}

pub fn abortDetach(self: *Controller) !void {
    const attachment = switch (self.mode) {
        .detaching => |attachment| attachment,
        else => return,
    };
    attachment.abort();
    self.mode = .idle;
    try self.emit(.state_changed);
}

pub fn sendEvent(
    self: *Controller,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) !void {
    const line = try html.wrapAlloc(self.gpa, .of(severity), text);
    defer self.gpa.free(line);
    try self.send(line, &.{ .disable_notification = true, .parse_mode = html.parse_mode });
}

pub fn reply(
    self: *Controller,
    id: i64,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) !void {
    const line = try html.wrapAlloc(self.gpa, .of(severity), text);
    defer self.gpa.free(line);
    try self.send(line, &.{
        .reply_to = id,
        .disable_notification = true,
        .parse_mode = html.parse_mode,
    });
}

pub fn send(self: *Controller, text: []const u8, options: *const Client.SendOptions) !void {
    const attachment = self.attached() orelse return;
    try self.takeQueued(attachment, .message, attachment.send(text, options));
}

pub fn sendTracked(
    self: *Controller,
    text: []const u8,
    options: *const Client.SendOptions,
) !?Attachment.Handle {
    const attachment = self.attached() orelse return null;
    const handle = attachment.sendTracked(text, options) catch |err| {
        try self.takeQueued(attachment, .message, err);
        return null;
    };
    try self.reportDrops(attachment);
    return handle;
}

pub fn edit(
    self: *Controller,
    handle: Attachment.Handle,
    text: []const u8,
    options: *const Client.EditOptions,
) !void {
    const attachment = self.attached() orelse return;
    try self.takeQueued(attachment, .state, attachment.edit(handle, text, options));
}

pub fn delete(self: *Controller, handle: Attachment.Handle) !void {
    const attachment = self.attached() orelse return;
    try self.takeQueued(attachment, .state, attachment.delete(handle));
}

pub fn answer(self: *Controller, query_id: []const u8) !void {
    const attachment = self.attached() orelse return;
    try self.takeQueued(attachment, .state, attachment.answer(query_id));
}

pub fn listens(self: *const Controller) bool {
    return self.mode == .attached;
}

fn attached(self: *Controller) ?*Attachment {
    return switch (self.mode) {
        .attached => |attachment| attachment,
        else => null,
    };
}

const Put = enum { message, state };

fn takeQueued(
    self: *Controller,
    attachment: *Attachment,
    put: Put,
    result: Attachment.SendError!void,
) !void {
    result catch |err| switch (err) {
        error.Closed, error.Canceled => return,
        error.QueueFull => {
            if (put == .message) self.dropped_count += 1;
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    try self.reportDrops(attachment);
}

fn reportDrops(self: *Controller, attachment: *Attachment) !void {
    const count = self.dropped_count;
    if (count == 0) return;
    const text = try std.fmt.allocPrint(
        self.gpa,
        "Drinky dropped {d} message{s} while the send queue was full. " ++
            "The terminal holds the whole transcript.",
        .{ count, ai.format.pluralSuffix(count) },
    );
    defer self.gpa.free(text);
    const line = try html.wrapAlloc(self.gpa, .failure, text);
    defer self.gpa.free(line);
    attachment.send(line, &.{
        .disable_notification = true,
        .parse_mode = html.parse_mode,
    }) catch |err| switch (err) {
        error.Closed, error.Canceled, error.QueueFull => return,
        error.OutOfMemory => return error.OutOfMemory,
    };
    self.dropped_count = 0;
}

pub fn applyAttachmentEvent(self: *Controller, event: *const Attachment.Event) !void {
    defer event.deinit(self.gpa);
    if (event.payload == .drained) return self.finishDrain(event.generation);
    const attachment = switch (self.mode) {
        .attached => |attachment| attachment,
        else => return,
    };
    if (event.generation != attachment.generation) return;
    const username = attachment.username;
    switch (event.payload) {
        .message => |message| try self.emit(.{ .chat_message = .{
            .id = message.id,
            .text = message.text,
        } }),
        .callback => |callback| if (keyboard.parseCancel(callback.data)) |serial| {
            try self.emit(.{ .cancel_tap = .{ .query_id = callback.query_id, .serial = serial } });
        } else {
            try self.answer(callback.query_id);
        },
        .unreadable => |id| try self.reply(id, .warning, "Drinky reads text alone."),
        .failed => |failure| try self.recordTerminalEvent(
            .failure,
            "Drinky could not {s} @{s} because of error {s}. Drinky tries again.",
            .{ sideVerb(failure.side), username, failure.name },
        ),
        .recovered => |side| try self.recordTerminalEvent(
            .information,
            "Drinky can {s} @{s} again.",
            .{ sideVerb(side), username },
        ),
        .send_rejected => |rejected| if (rejected.description.len > 0) {
            try self.recordTerminalEvent(
                .failure,
                "Telegram rejected {s} @{s}: {s}.",
                .{ rejectedNoun(rejected.kind), username, rejected.description },
            );
        } else {
            try self.recordTerminalEvent(
                .failure,
                "Telegram rejected {s} @{s}.",
                .{ rejectedNoun(rejected.kind), username },
            );
        },
        .detach => |reason| try self.detach(.{ .failure = reason }),
        .drained => unreachable,
    }
}

fn rejectedNoun(kind: Attachment.Event.Rejected.Kind) []const u8 {
    return switch (kind) {
        .message => "a message to",
        .edit => "an edit in the chat of",
        .deletion => "a deletion in the chat of",
    };
}

pub fn applyPairingEvent(self: *Controller, event: *const Pairing.Event) !void {
    defer event.deinit(self.gpa);
    const pairing = switch (self.mode) {
        .checking_token, .pairing => |pairing| pairing,
        else => return,
    };
    if (event.generation != pairing.generation) return;
    switch (event.payload) {
        .token_checked => |check| switch (check) {
            .bot => |me| {
                pairing.cancel();
                {
                    const username = try self.gpa.dupe(u8, me.username);
                    errdefer self.gpa.free(username);
                    try pairing.startWait(me.id, username);
                }
                self.mode = .{ .pairing = pairing };
                const bot: Store.Bot = .{
                    .token = pairing.token,
                    .id = pairing.id,
                    .username = pairing.username,
                    .chat_id = null,
                };
                self.store.save(&bot) catch |err| try self.recordEvent(
                    .failure,
                    "Drinky could not save the bot @{s} to {s} because of error {s}.",
                    .{ bot.username, self.store.path, @errorName(err) },
                );
                try self.emit(.{ .pairing_changed = .code_ready });
                try self.emit(.state_changed);
            },
            .failed => |err| {
                pairing.destroy();
                self.mode = .token_prompt;
                try self.emit(.{ .pairing_changed = .prompt_restored });
                switch (err) {
                    error.Unauthorized => try self.showNotice(
                        .failure,
                        "Telegram rejected the bot token.",
                        .{},
                    ),
                    error.Unavailable => try self.showNotice(
                        .failure,
                        "Drinky could not reach Telegram. Try again.",
                        .{},
                    ),
                    else => try self.showNotice(
                        .failure,
                        "Drinky could not check the bot token because of error {s}.",
                        .{@errorName(err)},
                    ),
                }
                try self.emit(.state_changed);
            },
        },
        .paired => |chat_id| {
            defer pairing.destroy();
            const bot: Store.Bot = .{
                .token = pairing.token,
                .id = pairing.id,
                .username = pairing.username,
                .chat_id = chat_id,
            };
            const saved = self.store.save(&bot);
            self.mode = .idle;
            try self.emit(.{ .pairing_changed = .ended });
            saved catch |err| try self.recordEvent(
                .failure,
                "Drinky could not save the chat of @{s} to {s} because of error {s}. The next " ++
                    "attach pairs again.",
                .{ bot.username, self.store.path, @errorName(err) },
            );
            try self.startAttachment(&bot);
        },
        .ended => |end| {
            const username = try self.gpa.dupe(u8, pairing.username);
            defer self.gpa.free(username);
            pairing.destroy();
            self.mode = .idle;
            try self.emit(.{ .pairing_changed = .ended });
            switch (end) {
                .too_many_codes => try self.recordEvent(
                    .failure,
                    "Drinky ended the pairing of @{s} after {d} wrong codes.",
                    .{ username, Pairing.wrong_codes_max },
                ),
                .expired => try self.recordEvent(
                    .failure,
                    "Drinky ended the pairing of @{s} because no code arrived within five minutes.",
                    .{username},
                ),
                .failed => |err| switch (err) {
                    error.Unauthorized => try self.recordEvent(
                        .failure,
                        "Telegram no longer knows the token of @{s}, so Drinky ended the pairing.",
                        .{username},
                    ),
                    error.Conflict => try self.recordEvent(
                        .failure,
                        "Another instance polls @{s}, so Drinky ended the pairing.",
                        .{username},
                    ),
                    else => try self.recordEvent(
                        .failure,
                        "Drinky could not pair @{s} because of error {s}.",
                        .{ username, @errorName(err) },
                    ),
                },
            }
            try self.emit(.state_changed);
        },
    }
}

fn createPairing(self: *Controller, token: []const u8) !*Pairing {
    const generation = try reserveGeneration(&self.generation);
    return Pairing.create(self.gpa, self.io, &.{
        .base_url = self.base_url,
        .token = token,
        .code = self.code orelse Pairing.generateCode(self.io),
        .connect_ms = self.connect_ms,
        .generation = generation,
        .sink = self.pairing_sink,
    });
}

fn startWait(self: *Controller, bot: *const Store.Bot) !void {
    const pairing = try self.createPairing(bot.token);
    errdefer pairing.destroy();
    {
        const username = try self.gpa.dupe(u8, bot.username);
        errdefer self.gpa.free(username);
        try pairing.startWait(bot.id, username);
    }
    self.mode = .{ .pairing = pairing };
    errdefer {
        self.mode = .idle;
        self.emit(.{ .pairing_changed = .ended }) catch {};
    }
    try self.emit(.{ .pairing_changed = .check_started });
    try self.emit(.{ .pairing_changed = .code_ready });
    try self.emit(.state_changed);
}

fn startAttachment(self: *Controller, bot: *const Store.Bot) !void {
    std.debug.assert(self.mode == .idle);
    const generation = try reserveGeneration(&self.generation);
    const attachment = try Attachment.create(self.gpa, self.io, &.{
        .base_url = self.base_url,
        .token = bot.token,
        .username = bot.username,
        .chat_id = bot.chat_id.?,
        .connect_ms = self.connect_ms,
        .generation = generation,
        .sink = self.attachment_sink,
        .pace = self.pace,
        .commands = &bot_commands,
    });
    errdefer attachment.destroy();
    try attachment.start();
    self.mode = .{ .attached = attachment };
    errdefer self.mode = .idle;
    self.dropped_count = 0;
    try self.emit(.state_changed);
}

fn finishDrain(self: *Controller, generation: u64) !void {
    const attachment = switch (self.mode) {
        .detaching => |attachment| attachment,
        else => return,
    };
    if (attachment.generation != generation) return;
    attachment.destroy();
    self.mode = .idle;
    try self.emit(.state_changed);
}

fn detachText(self: *Controller, cause: DetachCause, username: []const u8) ![]u8 {
    return switch (cause) {
        .user => std.fmt.allocPrint(self.gpa, "You detached @{s}.", .{username}),
        .exit => std.fmt.allocPrint(
            self.gpa,
            "Drinky detached @{s} because Drinky exits.",
            .{username},
        ),
        .credential_rejected => std.fmt.allocPrint(
            self.gpa,
            "The provider rejected the credential, so Drinky detached @{s}. Sign in again in " ++
                "the terminal.",
            .{username},
        ),
        .failure => |reason| switch (reason) {
            .unauthorized => std.fmt.allocPrint(
                self.gpa,
                "Telegram no longer knows the token of @{s}, so Drinky detached it. Remove the " ++
                    "bot with /remote and add it again.",
                .{username},
            ),
            .forbidden => std.fmt.allocPrint(
                self.gpa,
                "The user blocked @{s}, so Drinky detached it.",
                .{username},
            ),
            .conflict => std.fmt.allocPrint(
                self.gpa,
                "Another instance polls @{s}, so Drinky detached it.",
                .{username},
            ),
            .poll_rejected => std.fmt.allocPrint(
                self.gpa,
                "Telegram rejected the poll of @{s}, so Drinky detached it.",
                .{username},
            ),
        },
    };
}

fn sideVerb(side: Attachment.Event.Side) []const u8 {
    return switch (side) {
        .poll => "poll",
        .send => "send to",
    };
}

fn emit(self: *Controller, action: Action) !void {
    try self.sink.act(self.sink.context, action);
}

fn tell(
    self: *Controller,
    kind: Action.Report.Kind,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) !void {
    try self.emit(.{ .report = .{ .kind = kind, .severity = severity, .text = text } });
}

fn recordEvent(
    self: *Controller,
    severity: ai.command.Outcome.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(self.gpa, format, args);
    defer self.gpa.free(text);
    try self.tell(.event, severity, text);
}

fn recordTerminalEvent(
    self: *Controller,
    severity: ai.command.Outcome.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(self.gpa, format, args);
    defer self.gpa.free(text);
    try self.tell(.terminal_event, severity, text);
}

fn showNotice(
    self: *Controller,
    severity: ai.command.Outcome.Severity,
    comptime format: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(self.gpa, format, args);
    defer self.gpa.free(text);
    try self.tell(.notice, severity, text);
}

fn reserveGeneration(counter: *u64) error{GenerationExhausted}!u64 {
    if (counter.* == std.math.maxInt(u64)) return error.GenerationExhausted;
    counter.* += 1;
    return counter.*;
}

const testing = @import("testing.zig");

const Owner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    actions: std.ArrayList(Recorded) = .empty,
    fail_at: ?usize = null,
    events_buffer: [64]Event = undefined,
    events: std.Io.Queue(Event) = undefined,

    const Event = union(enum) {
        attachment: Attachment.Event,
        pairing: Pairing.Event,
    };

    const Recorded = union(enum) {
        chat_message: struct { id: i64, text: []u8 },
        cancel_tap: struct { query_id: []u8, serial: u64 },
        report: struct { kind: Action.Report.Kind, severity: ai.command.Outcome.Severity, text: []u8 },
        state_changed,
        pairing_changed: Action.PairingChange,

        fn deinit(self: *const Recorded, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .chat_message => |message| gpa.free(message.text),
                .cancel_tap => |tap| gpa.free(tap.query_id),
                .report => |report| gpa.free(report.text),
                .state_changed, .pairing_changed => {},
            }
        }
    };

    fn init(self: *Owner) void {
        self.events = .init(&self.events_buffer);
    }

    fn deinit(self: *Owner) void {
        for (self.actions.items) |action| action.deinit(self.gpa);
        self.actions.deinit(self.gpa);
        var batch: [64]Event = undefined;
        while (true) {
            const count = self.events.get(self.io, &batch, 0) catch break;
            if (count == 0) break;
            for (batch[0..count]) |event| switch (event) {
                .attachment => |attachment_event| attachment_event.deinit(self.gpa),
                .pairing => |pairing_event| pairing_event.deinit(self.gpa),
            };
        }
    }

    fn options(self: *Owner, store: Store, server: *const testing.Server, url_buffer: []u8) Options {
        return .{
            .store = store,
            .sink = .{ .context = self, .act = act },
            .attachment_sink = .{ .context = self, .emit = emitAttachment },
            .pairing_sink = .{ .context = self, .emit = emitPairing },
            .base_url = server.url(url_buffer),
            .connect_ms = 60_000,
            .pace = testing.pace,
            .code = "x7kq4m2p".*,
        };
    }

    fn act(context: *anyopaque, action: Action) anyerror!void {
        const self: *Owner = @ptrCast(@alignCast(context));
        if (self.fail_at) |count| {
            if (self.actions.items.len == count) {
                self.fail_at = null;
                return error.SinkFailed;
            }
        }
        const recorded: Recorded = switch (action) {
            .chat_message => |message| .{ .chat_message = .{
                .id = message.id,
                .text = try self.gpa.dupe(u8, message.text),
            } },
            .cancel_tap => |tap| .{ .cancel_tap = .{
                .query_id = try self.gpa.dupe(u8, tap.query_id),
                .serial = tap.serial,
            } },
            .report => |report| .{ .report = .{
                .kind = report.kind,
                .severity = report.severity,
                .text = try self.gpa.dupe(u8, report.text),
            } },
            .state_changed => .state_changed,
            .pairing_changed => |change| .{ .pairing_changed = change },
        };
        try self.actions.append(self.gpa, recorded);
    }

    fn emitAttachment(context: *anyopaque, event: Attachment.Event) error{Closed}!void {
        const self: *Owner = @ptrCast(@alignCast(context));
        self.events.putOne(self.io, .{ .attachment = event }) catch return error.Closed;
    }

    fn emitPairing(context: *anyopaque, event: Pairing.Event) error{Closed}!void {
        const self: *Owner = @ptrCast(@alignCast(context));
        self.events.putOne(self.io, .{ .pairing = event }) catch return error.Closed;
    }

    fn pump(self: *Owner, controller: *Controller, count_min: usize) !void {
        var batch: [64]Event = undefined;
        var applied: usize = 0;
        for (0..500) |_| {
            const count = try self.events.get(self.io, &batch, 0);
            for (batch[0..count]) |*event| switch (event.*) {
                .attachment => |*attachment_event| try controller.applyAttachmentEvent(attachment_event),
                .pairing => |*pairing_event| try controller.applyPairingEvent(pairing_event),
            };
            applied += count;
            if (applied >= count_min) return;
            try self.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.TestTimedOut;
    }

    fn pumpUntil(self: *Owner, controller: *Controller, target: State) !void {
        var batch: [64]Event = undefined;
        for (0..500) |_| {
            if (controller.state() == target) return;
            const count = try self.events.get(self.io, &batch, 0);
            for (batch[0..count]) |*event| switch (event.*) {
                .attachment => |*attachment_event| try controller.applyAttachmentEvent(attachment_event),
                .pairing => |*pairing_event| try controller.applyPairingEvent(pairing_event),
            };
            try self.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.TestTimedOut;
    }

    fn lastReport(self: *const Owner) ![]const u8 {
        var index = self.actions.items.len;
        while (index > 0) : (index -= 1) {
            switch (self.actions.items[index - 1]) {
                .report => |report| return report.text,
                else => {},
            }
        }
        return error.TestExpectedReport;
    }

    fn countReports(self: *const Owner, needle: []const u8) usize {
        var count: usize = 0;
        for (self.actions.items) |action| switch (action) {
            .report => |report| if (std.mem.indexOf(u8, report.text, needle) != null) {
                count += 1;
            },
            else => {},
        };
        return count;
    }
};

const ok_true = "{\"ok\":true,\"result\":true}";
const ok_empty = "{\"ok\":true,\"result\":[]}";
const ok_sent = "{\"ok\":true,\"result\":{\"message_id\":1}}";

fn endTest(controller: *Controller) void {
    controller.detach(.exit) catch {};
    controller.abortDetach() catch {};
    controller.deinit();
}

test "a saved bot attaches, its messages and taps reach the owner, and a detach ends the chat" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = ok_empty },
            .{ .body =
            \\{"ok":true,"result":[
            \\{"update_id":1,"message":{"message_id":7,"date":0,"chat":{"id":99,"type":"private"},"text":"hello"}},
            \\{"update_id":2,"message":{"message_id":8,"date":0,"chat":{"id":99,"type":"private"},"sticker":{}}},
            \\{"update_id":3,"callback_query":{"id":"900","from":{"id":5},"chat_instance":"c","message":{"message_id":50,"date":0,"chat":{"id":99,"type":"private"}},"data":"cancel:2"}},
            \\{"update_id":4,"callback_query":{"id":"901","from":{"id":5},"chat_instance":"c","message":{"message_id":50,"date":0,"chat":{"id":99,"type":"private"}},"data":"not:ours"}}
            \\]}
            },
        } },
        .{ .method = "sendMessage", .replies = &.{ .{ .body = ok_sent }, .{ .body = ok_sent }, .{ .body = ok_sent } } },
        .{ .method = "answerCallbackQuery", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true } } },
    });
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var store = Store.inert(gpa, io);
    try store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    var controller = Controller.init(gpa, io, &owner.options(store, &server, &url_buffer));
    defer endTest(&controller);

    try controller.attachSaved(0);
    try std.testing.expectEqual(State.attached, controller.state());
    try std.testing.expectEqualStrings("drinky_bot", controller.botUsername().?);
    try std.testing.expect(owner.actions.items[0] == .state_changed);
    try server.waitForLongPoll();
    const registered = try server.waitForRequest("/setMyCommands", 0);
    try std.testing.expectEqualStrings(
        "{\"commands\":[{\"command\":\"new\",\"description\":\"Clear the conversation\"}]}",
        registered,
    );
    try controller.sendEvent(.information, "You attached @drinky_bot.");

    try owner.pump(&controller, 4);
    const message = owner.actions.items[1].chat_message;
    try std.testing.expectEqual(@as(i64, 7), message.id);
    try std.testing.expectEqualStrings("hello", message.text);
    try controller.reply(7, .warning, "The command /login runs in the terminal alone.");
    const tap = owner.actions.items[2].cancel_tap;
    try std.testing.expectEqualStrings("900", tap.query_id);
    try std.testing.expectEqual(@as(u64, 2), tap.serial);
    try std.testing.expectEqual(@as(usize, 3), owner.actions.items.len);
    try controller.answer("900");
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"901\"}",
        try server.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\"}",
        try server.waitForRequest("/answerCallbackQuery", 1),
    );

    try server.waitForSends(3);
    try controller.detach(.user);
    try std.testing.expectEqual(State.detaching, controller.state());
    try std.testing.expectEqualStrings("drinky_bot", controller.botUsername().?);
    try std.testing.expectEqualStrings("You detached @drinky_bot.", try owner.lastReport());
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);
    try controller.attachSaved(0);
    try std.testing.expect(std.mem.indexOf(u8, try owner.lastReport(), "cannot attach a bot now") != null);
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expect(controller.botUsername() == null);
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);
    try server.finish();
    var buffer: [8][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 4), sends.len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        sends[0],
        "\"text\":\"ℹ You attached @drinky_bot.\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        sends[1],
        "\"text\":\"⚠ Drinky reads text alone.\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"reply_parameters\":{\"message_id\":8}") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        sends[2],
        "\"text\":\"⚠ The command /login runs in the terminal alone.\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[2], "\"reply_parameters\":{\"message_id\":7}") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        sends[3],
        "\"text\":\"ℹ You detached @drinky_bot.\"",
    ) != null);
}

test "a run of dropped messages reports its count in the chat once the queue has room" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sends = [_]testing.Reply{.{ .body = ok_sent, .delay_ms = 100 }} ++
        [_]testing.Reply{.{ .body = ok_sent }} ** (Attachment.outbound_capacity + 2);
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = ok_empty }} },
        .{ .method = "sendMessage", .replies = &sends },
    });
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var store = Store.inert(gpa, io);
    try store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    var controller = Controller.init(gpa, io, &owner.options(store, &server, &url_buffer));
    defer endTest(&controller);
    controller.pace.send_spacing_ms = 0;
    try controller.attachSaved(0);
    try server.waitForLongPoll();

    try controller.send("slow", &.{});
    try server.waitForSends(1);
    for (0..Attachment.outbound_capacity) |_| try controller.send("fill", &.{});
    for (0..3) |_| try controller.send("lost", &.{});
    try std.testing.expectEqual(@as(usize, 0), owner.countReports("dropped"));

    try server.waitForSends(10);
    try controller.send("room", &.{});
    try server.finish();
    var buffer: [Attachment.outbound_capacity + 4][]const u8 = undefined;
    const bodies = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, Attachment.outbound_capacity + 3), bodies.len);
    try std.testing.expect(std.mem.indexOf(u8, bodies[bodies.len - 2], "\"text\":\"room\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        bodies[bodies.len - 1],
        "\"text\":\"⚠ Drinky dropped 3 messages while the send queue was full. " ++
            "The terminal holds the whole transcript.\"",
    ) != null);
    try std.testing.expectEqual(@as(usize, 0), owner.countReports("dropped"));
}

test "an abort of the detach frees the owner at once and drops the last message" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true } } },
        .{ .method = "setMyCommands", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true } } },
        .{ .method = "getUpdates", .replies = &.{ .{ .body = ok_empty }, .{ .body = ok_empty } } },
    });
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var store = Store.inert(gpa, io);
    try store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    var controller = Controller.init(gpa, io, &owner.options(store, &server, &url_buffer));
    defer endTest(&controller);

    try controller.attachSaved(0);
    try server.waitForLongPoll();
    try controller.detach(.user);
    try server.waitForSends(1);
    try std.testing.expectEqual(State.detaching, controller.state());

    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try controller.abortDetach();
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms < testing.drain_half_ms);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);

    const registrations = server.countOf("/setMyCommands");
    try controller.attachSaved(0);
    try std.testing.expectEqual(State.attached, controller.state());
    _ = try server.waitForRequest("/setMyCommands", registrations);
    try controller.applyAttachmentEvent(&.{ .generation = 1, .payload = .drained });
    try std.testing.expectEqual(State.attached, controller.state());
    try std.testing.expectEqual(@as(usize, 1), server.sendCount());
    try server.finish();
}

test "a token pairs a new bot, and a rejected token returns to the prompt" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "getMe", .replies = &.{
            .{ .status = 401, .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}" },
            .{ .body = "{\"ok\":true,\"result\":{\"id\":42,\"is_bot\":true,\"username\":\"drinky_bot\"}}" },
        } },
        .{ .method = "deleteWebhook", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true } } },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = ok_empty },
            .{ .body =
            \\{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"/start x7kq4m2p"}}]}
            },
            .{ .body = ok_empty },
        } },
    });
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var controller = Controller.init(gpa, io, &owner.options(Store.inert(gpa, io), &server, &url_buffer));
    defer endTest(&controller);

    try controller.beginTokenPrompt();
    try std.testing.expectEqual(State.token_prompt, controller.state());
    try controller.submitToken("");
    try std.testing.expectEqualStrings("Type the bot token.", try owner.lastReport());
    try controller.submitToken("not a token");
    try std.testing.expect(std.mem.indexOf(u8, try owner.lastReport(), "digits") != null);
    try std.testing.expectEqual(State.token_prompt, controller.state());

    try controller.submitToken("42:secret");
    try std.testing.expectEqual(State.checking_token, controller.state());
    try std.testing.expect(controller.pairs());
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.token_prompt, controller.state());
    try std.testing.expectEqualStrings("Telegram rejected the bot token.", try owner.lastReport());
    var restored = false;
    for (owner.actions.items) |action| {
        if (action == .pairing_changed and action.pairing_changed == .prompt_restored) restored = true;
    }
    try std.testing.expect(restored);

    try std.testing.expectEqual(@as(usize, 0), controller.usernames().len);
    try controller.submitToken("42:secret");
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.pairing, controller.state());
    try std.testing.expectEqualStrings("x7kq4m2p", controller.pairingCode());
    try std.testing.expectEqualStrings("drinky_bot", controller.pairingUsername());
    try std.testing.expectEqual(@as(usize, 1), controller.usernames().len);
    try std.testing.expect(controller.store.get(0).?.chat_id == null);
    var link_buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://t.me/drinky_bot?start=x7kq4m2p",
        controller.pairingLink(&link_buffer),
    );

    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.attached, controller.state());
    try std.testing.expectEqual(@as(usize, 1), controller.usernames().len);
    try std.testing.expectEqualStrings("drinky_bot", controller.usernames()[0]);
    const saved = controller.store.get(0).?;
    try std.testing.expectEqualStrings("42:secret", saved.token);
    try std.testing.expectEqual(@as(i64, 42), saved.id);
    try std.testing.expectEqual(@as(?i64, 99), saved.chat_id);
    try server.finish();
}

test "a cancel of the pairing keeps or drops the token by its scope" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{});
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var controller = Controller.init(gpa, io, &owner.options(Store.inert(gpa, io), &server, &url_buffer));
    defer endTest(&controller);

    try controller.beginTokenPrompt();
    try controller.submitToken("42:secret");
    try controller.cancelPairing(.step);
    try std.testing.expectEqual(State.token_prompt, controller.state());
    try std.testing.expectEqualStrings("You canceled the token check.", try owner.lastReport());

    try controller.submitToken("42:secret");
    try controller.cancelPairing(.command);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expectEqualStrings("You canceled the bot token.", try owner.lastReport());

    try controller.beginTokenPrompt();
    try controller.cancelTokenPrompt();
    try std.testing.expectEqual(State.idle, controller.state());
}

test "a saved bot without a chat waits for its code, and a cancel ends that wait" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = ok_empty }} },
    });
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var store = Store.inert(gpa, io);
    try store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = null });
    var controller = Controller.init(gpa, io, &owner.options(store, &server, &url_buffer));
    defer endTest(&controller);

    try controller.attachSaved(0);
    try std.testing.expectEqual(State.pairing, controller.state());
    try std.testing.expect(owner.actions.items[0].pairing_changed == .check_started);
    try std.testing.expect(owner.actions.items[1].pairing_changed == .code_ready);
    try controller.cancelPairing(.step);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expectEqualStrings("You canceled the pairing of @drinky_bot.", try owner.lastReport());

    try controller.removeBot(0);
    try std.testing.expectEqual(@as(usize, 0), controller.usernames().len);
    try std.testing.expectEqualStrings("Drinky removed the bot @drinky_bot.", try owner.lastReport());
}

test "a failure of the chat reports once per run, and a permanent one detaches" {
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
            .{ .status = 401, .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}" },
        } },
    });
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var store = Store.inert(gpa, io);
    try store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    var controller = Controller.init(gpa, io, &owner.options(store, &server, &url_buffer));
    defer endTest(&controller);

    try controller.attachSaved(0);
    try owner.pumpUntil(&controller, .detaching);
    try std.testing.expectEqual(@as(usize, 1), owner.countReports("could not poll @drinky_bot"));
    try std.testing.expectEqual(@as(usize, 1), owner.countReports("can poll @drinky_bot again"));
    try std.testing.expect(std.mem.indexOf(u8, try owner.lastReport(), "no longer knows the token") != null);
    try std.testing.expect(std.mem.indexOf(u8, try owner.lastReport(), "Remove the bot") != null);
    try owner.pumpUntil(&controller, .idle);
    try server.finish();
}

test "an action failure after an ownership transfer leaves the controller whole" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "getMe", .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":{\"id\":44,\"is_bot\":true,\"username\":\"new_bot\"}}" },
        } },
        .{ .method = "deleteWebhook", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true }, .{ .body = ok_true } } },
        .{ .method = "setMyCommands", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true } } },
        .{ .method = "getUpdates", .replies = &.{ .{ .body = ok_empty }, .{ .body = ok_empty }, .{ .body = ok_empty } } },
    });
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var store = Store.inert(gpa, io);
    try store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    try store.save(&.{ .token = "43:other", .id = 43, .username = "other_bot", .chat_id = null });
    var controller = Controller.init(gpa, io, &owner.options(store, &server, &url_buffer));
    defer endTest(&controller);

    try controller.beginTokenPrompt();
    try controller.submitToken("44:new");
    owner.fail_at = owner.actions.items.len;
    try std.testing.expectError(error.SinkFailed, owner.pump(&controller, 1));
    try std.testing.expectEqual(State.pairing, controller.state());
    try std.testing.expectEqualStrings("new_bot", controller.pairingUsername());
    try controller.cancelPairing(.step);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expectEqual(@as(usize, 3), controller.usernames().len);
    try std.testing.expectEqualStrings("new_bot", controller.usernames()[2]);

    owner.fail_at = owner.actions.items.len;
    try std.testing.expectError(error.SinkFailed, controller.attachSaved(1));
    try std.testing.expectEqual(State.idle, controller.state());

    owner.fail_at = owner.actions.items.len;
    try std.testing.expectError(error.SinkFailed, controller.attachSaved(0));
    try std.testing.expectEqual(State.idle, controller.state());

    const registrations = server.countOf("/setMyCommands");
    try controller.attachSaved(0);
    _ = try server.waitForRequest("/setMyCommands", registrations);
    owner.fail_at = owner.actions.items.len;
    try std.testing.expectError(error.SinkFailed, controller.detach(.user));
    try std.testing.expectEqual(State.detaching, controller.state());
    try owner.pumpUntil(&controller, .idle);
}

test "a shutdown closes the bot even when its report fails" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "setMyCommands", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{.{ .body = ok_empty }} },
    });
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var store = Store.inert(gpa, io);
    try store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    var controller = Controller.init(gpa, io, &owner.options(store, &server, &url_buffer));
    defer endTest(&controller);

    try controller.attachSaved(0);
    try server.waitForLongPoll();
    owner.fail_at = owner.actions.items.len;
    controller.shutdown();
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expectEqual(@as(usize, 0), owner.countReports("because Drinky exits"));
}
