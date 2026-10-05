const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");

const Message = @import("../Message.zig");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const html = @import("html.zig");
const keyboard = @import("keyboard.zig");
const Mirror = @import("Mirror.zig");
const Pairing = @import("Pairing.zig");
const Store = @import("Store.zig");

const Controller = @This();

gpa: std.mem.Allocator,
io: std.Io,
store: Store,
mode: Mode,
generation: u64,
sink: Sink,
attachment_sink: Attachment.Sink,
pairing_sink: Pairing.Sink,
transport: ?providers.Transport,
connect_ms: u64,
bot_commands: []const Client.Command,
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

const Options = struct {
    directories: accounts.json_store.Directories,
    sink: Sink,
    attachment_sink: Attachment.Sink,
    pairing_sink: Pairing.Sink,
    transport: ?providers.Transport,
    connect_ms: u64,
    bot_commands: []const Client.Command,
};

pub const Sink = core.actor.Sink(Action);

pub const Action = union(enum) {
    chat_message: ChatMessage,
    cancel_tap: CancelTap,
    report: Report,
    state_changed,
    pairing_changed: PairingChange,

    const ChatMessage = struct {
        id: i64,
        text: []const u8,
    };

    const CancelTap = struct {
        query_id: []const u8,
        serial: u64,
    };

    const Report = struct {
        kind: Kind,
        severity: Message.Severity,
        text: []const u8,

        const Kind = enum {
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
    credential_rejected: Step,
    failure: Attachment.Event.Reason,

    pub const Step = enum { sign_in, model_selection };
};

const CancelScope = enum {
    step,
    command,
};

const Put = enum { message, state };

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !Controller {
    return .{
        .gpa = gpa,
        .io = io,
        .store = try Store.open(gpa, io, &options.directories),
        .mode = .idle,
        .generation = 0,
        .sink = options.sink,
        .attachment_sink = options.attachment_sink,
        .pairing_sink = options.pairing_sink,
        .transport = options.transport,
        .connect_ms = options.connect_ms,
        .bot_commands = options.bot_commands,
        .dropped_count = 0,
    };
}

pub fn shutdown(self: *Controller) void {
    self.detach(&.exit) catch {};
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

pub fn usernames(self: *const Controller) []const []const u8 {
    return self.store.usernames.items;
}

pub fn loadError(self: *const Controller) ?accounts.json_store.OpenError {
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

pub fn pairingLink(self: *const Controller, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return self.mode.pairing.link(gpa);
}

pub fn beginTokenPrompt(self: *Controller) !void {
    std.debug.assert(self.mode == .idle);
    self.mode = .token_prompt;
    try self.tell(.notice, .information, "Paste the token that @BotFather gave you.", .{});
    self.emit(&.state_changed);
}

pub fn cancelTokenPrompt(self: *Controller) !void {
    std.debug.assert(self.mode == .token_prompt);
    self.mode = .idle;
    try self.tell(.notice, .information, "You canceled the bot token.", .{});
    self.emit(&.state_changed);
}

pub fn submitToken(self: *Controller, token: []const u8) !void {
    std.debug.assert(self.mode == .token_prompt);
    if (token.len == 0) return self.tell(.notice, .warning, "Type the bot token.", .{});
    if (!Client.validToken(token)) return self.tell(
        .notice,
        .failure,
        "A bot token holds digits, a colon, and the letters, digits, `_`, and `-` of its secret.",
        .{},
    );
    const pairing = try self.createPairing(token);
    errdefer pairing.destroy();
    self.mode = .{ .checking_token = pairing };
    errdefer {
        self.mode = .token_prompt;
        self.emit(&.{ .pairing_changed = .prompt_restored });
    }
    self.emit(&.{ .pairing_changed = .check_started });
    try pairing.startCheck();
    self.emit(&.state_changed);
}

pub fn cancelPairing(self: *Controller, scope: CancelScope) !void {
    switch (self.mode) {
        .checking_token => |pairing| {
            pairing.destroy();
            if (scope == .step) {
                self.mode = .token_prompt;
                self.emit(&.{ .pairing_changed = .prompt_restored });
                try self.tell(.notice, .information, "You canceled the token check.", .{});
            } else {
                self.mode = .idle;
                self.emit(&.{ .pairing_changed = .ended });
                try self.tell(.notice, .information, "You canceled the bot token.", .{});
            }
        },
        .pairing => |pairing| {
            const username = try self.gpa.dupe(u8, pairing.username);
            defer self.gpa.free(username);
            pairing.destroy();
            self.mode = .idle;
            self.emit(&.{ .pairing_changed = .ended });
            try self.tell(.event, .information, "You canceled the pairing of @{s}.", .{username});
        },
        else => unreachable,
    }
    self.emit(&.state_changed);
}

pub fn attachSaved(self: *Controller, index: usize) !void {
    std.debug.assert(self.mode == .idle);
    const bot = self.store.get(index);
    if (bot.chat_id == null) return self.startWait(bot);
    try self.startAttachment(bot);
}

pub fn removeBot(self: *Controller, index: usize) !void {
    const bot = self.store.get(index);
    const username = try self.gpa.dupe(u8, bot.username);
    defer self.gpa.free(username);
    self.store.remove(index) catch |err| return self.tell(
        .notice,
        .failure,
        "Drinky could not remove the bot @{s} because of error {s}.",
        .{ username, @errorName(err) },
    );
    try self.tell(.event, .information, "Drinky removed the bot @{s}.", .{username});
}

pub fn detach(self: *Controller, cause: *const DetachCause) !void {
    const attachment = switch (self.mode) {
        .attached => |attachment| attachment,
        else => return,
    };
    const severity: Message.Severity = switch (cause.*) {
        .user, .exit => .information,
        .credential_rejected, .failure => .failure,
    };
    const text = try self.detachText(cause, attachment.username);
    defer self.gpa.free(text);
    const line = try html.noticeAlloc(self.gpa, .of(severity), text);
    defer self.gpa.free(line);
    var maybe_drain_error: ?std.Io.ConcurrentError = null;
    attachment.close(&.{ .text = line, .parse_mode = html.parse_mode }) catch |err| switch (err) {
        error.OutOfMemory => {},
        error.ConcurrencyUnavailable => |drain_error| maybe_drain_error = drain_error,
    };
    self.mode = if (maybe_drain_error == null) .{ .detaching = attachment } else .idle;
    defer if (maybe_drain_error != null) attachment.destroy();
    self.emitReport(.terminal_event, severity, text);
    if (maybe_drain_error) |drain_error| try self.tell(
        .terminal_event,
        .failure,
        "Drinky could not send the last message to @{s} because of error {s}.",
        .{ attachment.username, @errorName(drain_error) },
    );
    self.emit(&.state_changed);
}

pub fn abortDetach(self: *Controller) !void {
    const attachment = switch (self.mode) {
        .detaching => |attachment| attachment,
        else => return,
    };
    attachment.abort();
    self.mode = .idle;
    self.emit(&.state_changed);
}

pub fn sendEvent(
    self: *Controller,
    severity: Message.Severity,
    text: []const u8,
) !void {
    const line = try html.noticeAlloc(self.gpa, .of(severity), text);
    defer self.gpa.free(line);
    try self.send(line, &.{ .disable_notification = true, .parse_mode = html.parse_mode });
}

pub fn reply(
    self: *Controller,
    id: i64,
    severity: Message.Severity,
    text: []const u8,
) !void {
    const line = try html.noticeAlloc(self.gpa, .of(severity), text);
    defer self.gpa.free(line);
    try self.send(line, &.{
        .reply_to = id,
        .disable_notification = true,
        .parse_mode = html.parse_mode,
    });
}

fn send(
    self: *Controller,
    text: []const u8,
    options: *const Client.SendOptions,
) error{OutOfMemory}!void {
    const attachment = self.attached() orelse return;
    try self.handleQueued(attachment, .message, attachment.send(text, options));
}

pub fn answer(self: *Controller, query_id: []const u8) !void {
    const attachment = self.attached() orelse return;
    try self.handleQueued(attachment, .state, attachment.answer(query_id));
}

pub fn listens(self: *const Controller) bool {
    return self.mode == .attached;
}

const chat_vtable: Mirror.Chat.VTable = .{
    .listens = chatListens,
    .send = chatSend,
    .sendTracked = chatSendTracked,
    .edit = chatEdit,
    .delete = chatDelete,
};

pub fn chat(self: *Controller) Mirror.Chat {
    return .{ .ptr = self, .vtable = &chat_vtable };
}

fn chatListens(ptr: *anyopaque) bool {
    const self: *Controller = @ptrCast(@alignCast(ptr));
    return self.listens();
}

fn chatSend(
    ptr: *anyopaque,
    text: []const u8,
    options: *const Client.SendOptions,
) Mirror.Chat.Error!void {
    const self: *Controller = @ptrCast(@alignCast(ptr));
    try self.send(text, options);
}

fn chatSendTracked(
    ptr: *anyopaque,
    text: []const u8,
    options: *const Client.SendOptions,
) Mirror.Chat.Error!?Attachment.Handle {
    const self: *Controller = @ptrCast(@alignCast(ptr));
    const attachment = self.attached() orelse return null;
    const handle = attachment.sendTracked(text, options) catch |err| {
        try self.handleQueued(attachment, .message, err);
        return null;
    };
    try self.reportDrops(attachment);
    return handle;
}

fn chatEdit(
    ptr: *anyopaque,
    handle: Attachment.Handle,
    text: []const u8,
    options: *const Client.EditOptions,
) Mirror.Chat.Error!void {
    const self: *Controller = @ptrCast(@alignCast(ptr));
    const attachment = self.attached() orelse return;
    try self.handleQueued(attachment, .state, attachment.edit(handle, text, options));
}

fn chatDelete(ptr: *anyopaque, handle: Attachment.Handle) Mirror.Chat.Error!void {
    const self: *Controller = @ptrCast(@alignCast(ptr));
    const attachment = self.attached() orelse return;
    try self.handleQueued(attachment, .state, attachment.delete(handle));
}

fn attached(self: *Controller) ?*Attachment {
    return switch (self.mode) {
        .attached => |attachment| attachment,
        else => null,
    };
}

fn handleQueued(
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
        .{ count, core.text.pluralSuffix(count) },
    );
    defer self.gpa.free(text);
    const line = try html.noticeAlloc(self.gpa, .failure, text);
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
    if (event.payload == .drained) return self.finishDrain(event.generation);
    const attachment = switch (self.mode) {
        .attached => |attachment| attachment,
        else => return,
    };
    if (event.generation != attachment.generation) return;
    const username = attachment.username;
    switch (event.payload) {
        .message => |message| self.emit(&.{ .chat_message = .{
            .id = message.id,
            .text = message.text,
        } }),
        .callback => |callback| {
            const tap = keyboard.Tap.parse(callback.data) orelse
                return self.answer(callback.query_id);
            switch (tap) {
                .cancel => |serial| self.emit(&.{ .cancel_tap = .{
                    .query_id = callback.query_id,
                    .serial = serial,
                } }),
            }
        },
        .unreadable => |id| try self.reply(id, .warning, "Drinky reads text alone."),
        .failed => |failure| try self.tell(
            .terminal_event,
            .failure,
            "Drinky could not {s} @{s} because of error {s}. Drinky tries again.",
            .{ sideVerb(failure.side), username, failure.name },
        ),
        .recovered => |side| try self.tell(
            .terminal_event,
            .information,
            "Drinky can {s} @{s} again.",
            .{ sideVerb(side), username },
        ),
        .send_rejected => |rejected| if (rejected.description.len > 0) {
            try self.tell(
                .terminal_event,
                .failure,
                "Telegram rejected {s} @{s}: {s}.",
                .{ rejectedNoun(rejected.kind), username, rejected.description },
            );
        } else {
            try self.tell(
                .terminal_event,
                .failure,
                "Telegram rejected {s} @{s}.",
                .{ rejectedNoun(rejected.kind), username },
            );
        },
        .send_dropped => |kind| try self.tell(
            .terminal_event,
            .failure,
            "Drinky dropped {s} @{s} after {d} failed attempts.",
            .{ rejectedNoun(kind), username, Attachment.retry.attempts_max },
        ),
        .detach => |reason| try self.detach(&.{ .failure = reason }),
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
    const pairing = switch (self.mode) {
        .checking_token, .pairing => |pairing| pairing,
        else => return,
    };
    if (event.generation != pairing.generation) return;
    switch (event.payload) {
        .token_checked => |check| switch (check) {
            .bot => |me| {
                pairing.cancel();
                try pairing.startWait(me.id, me.username);
                self.mode = .{ .pairing = pairing };
                const bot: Store.Bot = .{
                    .token = pairing.token,
                    .id = pairing.id,
                    .username = pairing.username,
                    .chat_id = self.store.chatOf(pairing.id),
                };
                self.store.save(&bot) catch |err| try self.tell(
                    .event,
                    .failure,
                    "Drinky could not save the bot @{s} to {s} because of error {s}.",
                    .{ bot.username, self.store.path, @errorName(err) },
                );
                self.emit(&.{ .pairing_changed = .code_ready });
                self.emit(&.state_changed);
            },
            .failed => |err| {
                pairing.destroy();
                self.mode = .token_prompt;
                self.emit(&.{ .pairing_changed = .prompt_restored });
                switch (err) {
                    error.Unauthorized => try self.tell(
                        .notice,
                        .failure,
                        "Telegram rejected the bot token.",
                        .{},
                    ),
                    error.Unavailable => try self.tell(
                        .notice,
                        .failure,
                        "Drinky could not reach Telegram. Try again.",
                        .{},
                    ),
                    else => try self.tell(
                        .notice,
                        .failure,
                        "Drinky could not check the bot token because of error {s}.",
                        .{@errorName(err)},
                    ),
                }
                self.emit(&.state_changed);
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
            self.emit(&.{ .pairing_changed = .ended });
            saved catch |err| try self.tell(
                .event,
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
            self.emit(&.{ .pairing_changed = .ended });
            switch (end) {
                .too_many_codes => try self.tell(
                    .event,
                    .failure,
                    "Drinky ended the pairing of @{s} after {d} wrong codes.",
                    .{ username, Pairing.wrong_codes_max },
                ),
                .expired => {
                    const window_minutes = @divExact(Pairing.window_ms, std.time.ms_per_min);
                    try self.tell(
                        .event,
                        .failure,
                        "Drinky ended the pairing of @{s} because no code arrived within " ++
                            "{d} minute{s}.",
                        .{ username, window_minutes, core.text.pluralSuffix(window_minutes) },
                    );
                },
                .failed => |err| switch (err) {
                    error.Unauthorized => try self.tell(
                        .event,
                        .failure,
                        "Telegram no longer knows the token of @{s}, so Drinky ended the pairing.",
                        .{username},
                    ),
                    error.Conflict => try self.tell(
                        .event,
                        .failure,
                        "Another client polls @{s}, so Drinky ended the pairing.",
                        .{username},
                    ),
                    else => try self.tell(
                        .event,
                        .failure,
                        "Drinky could not pair @{s} because of error {s}.",
                        .{ username, @errorName(err) },
                    ),
                },
            }
            self.emit(&.state_changed);
        },
    }
}

fn createPairing(self: *Controller, token: []const u8) !*Pairing {
    const generation = try reserveGeneration(&self.generation);
    return Pairing.create(self.gpa, self.io, &.{
        .transport = self.transport,
        .token = token,
        .code = Pairing.generateCode(self.io),
        .connect_ms = self.connect_ms,
        .generation = generation,
        .sink = self.pairing_sink,
    });
}

fn startWait(self: *Controller, bot: *const Store.Bot) !void {
    const pairing = try self.createPairing(bot.token);
    errdefer pairing.destroy();
    try pairing.startWait(bot.id, bot.username);
    self.mode = .{ .pairing = pairing };
    errdefer {
        self.mode = .idle;
        self.emit(&.{ .pairing_changed = .ended });
    }
    self.emit(&.{ .pairing_changed = .check_started });
    self.emit(&.{ .pairing_changed = .code_ready });
    self.emit(&.state_changed);
}

fn startAttachment(self: *Controller, bot: *const Store.Bot) !void {
    std.debug.assert(self.mode == .idle);
    const generation = try reserveGeneration(&self.generation);
    const attachment = try Attachment.create(self.gpa, self.io, &.{
        .transport = self.transport,
        .token = bot.token,
        .username = bot.username,
        .chat_id = bot.chat_id.?,
        .connect_ms = self.connect_ms,
        .generation = generation,
        .sink = self.attachment_sink,
        .commands = self.bot_commands,
    });
    errdefer attachment.destroy();
    try attachment.start();
    self.mode = .{ .attached = attachment };
    errdefer self.mode = .idle;
    self.dropped_count = 0;
    self.emit(&.state_changed);
}

fn finishDrain(self: *Controller, generation: u64) !void {
    const attachment = switch (self.mode) {
        .detaching => |attachment| attachment,
        else => return,
    };
    if (attachment.generation != generation) return;
    attachment.destroy();
    self.mode = .idle;
    self.emit(&.state_changed);
}

fn detachText(self: *Controller, cause: *const DetachCause, username: []const u8) ![]u8 {
    return switch (cause.*) {
        .user => std.fmt.allocPrint(self.gpa, "You detached @{s}.", .{username}),
        .exit => std.fmt.allocPrint(
            self.gpa,
            "Drinky detached @{s} because Drinky exits.",
            .{username},
        ),
        .credential_rejected => |step| std.fmt.allocPrint(
            self.gpa,
            "The credential is missing or invalid, so Drinky detached @{s}. {s}",
            .{ username, switch (step) {
                .sign_in => "Sign in again in the terminal.",
                .model_selection => "Select a model in the terminal.",
            } },
        ),
        .failure => |reason| switch (reason) {
            .unauthorized => std.fmt.allocPrint(
                self.gpa,
                "Telegram no longer knows the token of @{s}, so Drinky detached it. Remove the " ++
                    "bot with /remote and add it again.",
                .{username},
            ),
            .forbidden => |description| if (description.len > 0) std.fmt.allocPrint(
                self.gpa,
                "Telegram rejected a request of @{s}: {s}. Drinky detached it.",
                .{ username, description },
            ) else std.fmt.allocPrint(
                self.gpa,
                "Telegram rejected a request of @{s}, so Drinky detached it.",
                .{username},
            ),
            .conflict => std.fmt.allocPrint(
                self.gpa,
                "Another client polls @{s}, so Drinky detached it.",
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

fn emit(self: *Controller, action: *const Action) void {
    self.sink.emit(self.io, action);
}

fn emitReport(
    self: *Controller,
    kind: Action.Report.Kind,
    severity: Message.Severity,
    text: []const u8,
) void {
    self.emit(&.{ .report = .{ .kind = kind, .severity = severity, .text = text } });
}

fn tell(
    self: *Controller,
    kind: Action.Report.Kind,
    severity: Message.Severity,
    comptime template: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(self.gpa, template, args);
    defer self.gpa.free(text);
    self.emitReport(kind, severity, text);
}

fn reserveGeneration(counter: *u64) error{GenerationExhausted}!u64 {
    if (counter.* == std.math.maxInt(u64)) return error.GenerationExhausted;
    counter.* += 1;
    return counter.*;
}

const testing = @import("testing.zig");

test "a saved bot attaches, the chat messages and taps reach the owner, and a detach ends it" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{
        testing.webhook_deleted,
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{ .body =
            \\{"ok":true,"result":[
            \\{"update_id":1,"message":{"message_id":7,"date":0,"chat":{"id":99,"type":"private"},
            \\"text":"hello"}},
            \\{"update_id":2,"message":{"message_id":8,"date":0,"chat":{"id":99,"type":"private"},
            \\"sticker":{}}},
            \\{"update_id":3,"callback_query":{"id":"900","from":{"id":5},"chat_instance":"c",
            \\"message":{"message_id":50,"date":0,"chat":{"id":99,"type":"private"}},
            \\"data":"cancel:2"}},
            \\{"update_id":4,"callback_query":{"id":"901","from":{"id":5},"chat_instance":"c",
            \\"message":{"message_id":50,"date":0,"chat":{"id":99,"type":"private"}},
            \\"data":"not:ours"}}
            \\]}
            },
        } },
        .{
            .method = "sendMessage",
            .replies = &([_]testing.Reply{.{ .body = testing.ok_sent }} ** 4),
        },
        .{
            .method = "answerCallbackQuery",
            .replies = &.{ .{ .body = testing.ok_true }, .{ .body = testing.ok_true } },
        },
    });
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = 99,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try controller.attachSaved(0);
    try std.testing.expectEqual(State.attached, controller.state());
    try std.testing.expectEqualStrings("drinky_bot", controller.botUsername().?);
    try std.testing.expect(owner.actions.items[0] == .state_changed);
    try owner.telegram.waitForLongPoll();
    const registered = try owner.telegram.waitForRequest("/setMyCommands", 0);
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
        try owner.telegram.waitForRequest("/answerCallbackQuery", 0),
    );
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"900\"}",
        try owner.telegram.waitForRequest("/answerCallbackQuery", 1),
    );

    for (0..2) |_| try clock.pass(Attachment.send_spacing_ms);
    try owner.telegram.waitForSends(3);
    try controller.detach(&.user);
    try std.testing.expectEqual(State.detaching, controller.state());
    try std.testing.expectEqualStrings("drinky_bot", controller.botUsername().?);
    try std.testing.expectEqualStrings("You detached @drinky_bot.", try owner.lastReport());
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expect(controller.botUsername() == null);
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);
    try owner.telegram.finish();
    var buffer: [8][]const u8 = undefined;
    const sends = owner.telegram.bodiesOf("sendMessage", &buffer);
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
    try std.testing.expect(
        std.mem.indexOf(u8, sends[1], "\"reply_parameters\":{\"message_id\":8}") != null,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        sends[2],
        "\"text\":\"⚠ The command /login runs in the terminal alone.\"",
    ) != null);
    try std.testing.expect(
        std.mem.indexOf(u8, sends[2], "\"reply_parameters\":{\"message_id\":7}") != null,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        sends[3],
        "\"text\":\"ℹ You detached @drinky_bot.\"",
    ) != null);
}

const Owner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    actions: std.ArrayList(Recorded) = .empty,
    events_buffer: [64]Event = undefined,
    events: std.Io.Queue(Event) = undefined,
    tmp: std.testing.TmpDir = undefined,
    home_buffer: [128]u8 = undefined,
    directories: accounts.json_store.Directories = undefined,
    telegram: testing.Telegram = undefined,

    const Event = union(enum) {
        attachment: Attachment.Event,
        pairing: Pairing.Event,

        fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .attachment => |*attachment_event| attachment_event.deinit(gpa),
                .pairing => |*pairing_event| pairing_event.deinit(gpa),
            }
        }
    };

    const action_vtable: Sink.VTable = .{ .emit = act };
    const attachment_vtable: Attachment.Sink.VTable = .{ .emit = emitAttachment };
    const pairing_vtable: Pairing.Sink.VTable = .{ .emit = emitPairing };

    const Recorded = union(enum) {
        chat_message: struct { id: i64, text: []u8 },
        cancel_tap: struct { query_id: []u8, serial: u64 },
        report: struct { kind: Action.Report.Kind, severity: Message.Severity, text: []u8 },
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

    fn init(self: *Owner, scripts: []const testing.Script) !void {
        self.events = .init(&self.events_buffer);
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.directories = .{
            .working_directory = ".",
            .home = try accounts.testing.tmpHome(&self.home_buffer, &self.tmp),
        };
        self.telegram = try .init(self.gpa, self.io, scripts);
    }

    fn deinit(self: *Owner) void {
        for (self.actions.items) |action| action.deinit(self.gpa);
        self.actions.deinit(self.gpa);
        var batch: [64]Event = undefined;
        while (true) {
            const count = self.events.get(self.io, &batch, 0) catch break;
            if (count == 0) break;
            for (batch[0..count]) |*event| event.deinit(self.gpa);
        }
        self.tmp.cleanup();
        self.telegram.deinit();
    }

    fn savedChat(self: *Owner, index: usize) !?i64 {
        var store = try Store.open(self.gpa, self.io, &self.directories);
        defer store.deinit();
        return store.get(index).chat_id;
    }

    fn saveBot(self: *Owner, bot: *const Store.Bot) !void {
        var store = try Store.open(self.gpa, self.io, &self.directories);
        defer store.deinit();
        try store.save(bot);
    }

    fn options(self: *Owner) Options {
        return .{
            .directories = self.directories,
            .sink = .{ .ptr = self, .vtable = &action_vtable },
            .attachment_sink = .{ .ptr = self, .vtable = &attachment_vtable },
            .pairing_sink = .{ .ptr = self, .vtable = &pairing_vtable },
            .transport = self.telegram.transport(),
            .connect_ms = 60_000,
            .bot_commands = &.{.{ .command = "new", .description = "Clear the conversation" }},
        };
    }

    fn act(ptr: *anyopaque, action: *const Action) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        const recorded = record(self.gpa, action) catch return;
        self.actions.append(self.gpa, recorded) catch recorded.deinit(self.gpa);
    }

    fn record(gpa: std.mem.Allocator, action: *const Action) error{OutOfMemory}!Recorded {
        return switch (action.*) {
            .chat_message => |message| .{ .chat_message = .{
                .id = message.id,
                .text = try gpa.dupe(u8, message.text),
            } },
            .cancel_tap => |tap| .{ .cancel_tap = .{
                .query_id = try gpa.dupe(u8, tap.query_id),
                .serial = tap.serial,
            } },
            .report => |report| .{ .report = .{
                .kind = report.kind,
                .severity = report.severity,
                .text = try gpa.dupe(u8, report.text),
            } },
            .state_changed => .state_changed,
            .pairing_changed => |change| .{ .pairing_changed = change },
        };
    }

    fn emitAttachment(ptr: *anyopaque, event: *const Attachment.Event) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        self.queue(.{ .attachment = event.dupe(self.gpa) catch return });
    }

    fn emitPairing(ptr: *anyopaque, event: *const Pairing.Event) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        self.queue(.{ .pairing = event.dupe(self.gpa) catch return });
    }

    fn queue(self: *Owner, event: Event) void {
        self.events.putOneUncancelable(self.io, event) catch event.deinit(self.gpa);
    }

    fn pump(self: *Owner, controller: *Controller, count_min: usize) !void {
        var applied: usize = 0;
        while (applied < count_min) applied += try self.pumpBatch(controller);
    }

    fn pumpUntil(self: *Owner, controller: *Controller, target: State) !void {
        while (controller.state() != target) _ = try self.pumpBatch(controller);
    }

    fn pumpBatch(self: *Owner, controller: *Controller) !usize {
        var batch: [64]Event = undefined;
        const count = try self.events.get(self.io, &batch, 1);
        var applied: usize = 0;
        defer for (batch[applied..count]) |*rest| rest.deinit(self.gpa);
        for (batch[0..count]) |*event| {
            applied += 1;
            defer event.deinit(self.gpa);
            switch (event.*) {
                .attachment => |*attachment_event| try controller.applyAttachmentEvent(
                    attachment_event,
                ),
                .pairing => |*pairing_event| try controller.applyPairingEvent(pairing_event),
            }
        }
        return count;
    }

    fn lastPairingChange(self: *const Owner) ?Action.PairingChange {
        var index = self.actions.items.len;
        while (index > 0) : (index -= 1) {
            switch (self.actions.items[index - 1]) {
                .pairing_changed => |change| return change,
                else => {},
            }
        }
        return null;
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

const reply_delay_ms = 100;

fn endTest(controller: *Controller) void {
    controller.detach(&.exit) catch {};
    controller.abortDetach() catch {};
    controller.deinit();
}

test "a run of dropped messages reports its count in the chat once the queue has room" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    const sends = [_]testing.Reply{.{ .body = testing.ok_sent, .delay_ms = reply_delay_ms }} ++
        [_]testing.Reply{.{ .body = testing.ok_sent }} ** (Attachment.outbound_capacity + 2);
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{
        testing.webhook_deleted,
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &.{.{ .body = testing.ok_empty }} },
        .{ .method = "sendMessage", .replies = &sends },
    });
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = 99,
    });
    var options = owner.options();
    options.connect_ms = std.time.ms_per_day;
    var controller = try Controller.init(gpa, io, &options);
    defer endTest(&controller);
    try controller.attachSaved(0);
    try owner.telegram.waitForLongPoll();

    try controller.sendEvent(.information, "slow");
    try owner.telegram.waitForSends(1);
    for (0..Attachment.outbound_capacity) |_| try controller.sendEvent(.information, "fill");
    for (0..3) |_| try controller.sendEvent(.information, "lost");
    try std.testing.expectEqual(@as(usize, 0), owner.countReports("dropped"));

    try clock.pass(reply_delay_ms);
    try clock.pass(Attachment.send_spacing_ms);
    try clock.waitForSleep(Attachment.send_spacing_ms);
    try controller.sendEvent(.information, "room");
    for (0..Attachment.outbound_capacity + 1) |_| try clock.pass(Attachment.send_spacing_ms);
    try owner.telegram.finish();
    var buffer: [Attachment.outbound_capacity + 4][]const u8 = undefined;
    const bodies = owner.telegram.bodiesOf("sendMessage", &buffer);
    try std.testing.expectEqual(@as(usize, Attachment.outbound_capacity + 3), bodies.len);
    try std.testing.expect(
        std.mem.indexOf(u8, bodies[bodies.len - 2], "\"text\":\"ℹ room\"") != null,
    );
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
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{
        .{
            .method = "deleteWebhook",
            .replies = &.{ .{ .body = testing.ok_true }, .{ .body = testing.ok_true } },
        },
        .{
            .method = "setMyCommands",
            .replies = &.{ .{ .body = testing.ok_true }, .{ .body = testing.ok_true } },
        },
        .{
            .method = "getUpdates",
            .replies = &.{ .{ .body = testing.ok_empty }, .{ .body = testing.ok_empty } },
        },
    });
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = 99,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try controller.attachSaved(0);
    try owner.telegram.waitForLongPoll();
    try controller.detach(&.user);
    try owner.telegram.waitForSends(1);
    try std.testing.expectEqual(State.detaching, controller.state());

    try controller.abortDetach();
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);

    const registrations = owner.telegram.countOf("/setMyCommands");
    try controller.attachSaved(0);
    try std.testing.expectEqual(State.attached, controller.state());
    _ = try owner.telegram.waitForRequest("/setMyCommands", registrations);
    try controller.applyAttachmentEvent(&.{ .generation = 1, .payload = .drained });
    try std.testing.expectEqual(State.attached, controller.state());
    try std.testing.expectEqual(@as(usize, 1), owner.telegram.sendCount());
    try owner.telegram.finish();
}

test "a token pairs a new bot, and a rejected token returns to the prompt" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    const unknown_code = "?" ** @sizeOf(Pairing.Code);
    var typed_code = ("{\"ok\":true,\"result\":[{\"update_id\":1,\"message\":{\"message_id\":1," ++
        "\"date\":0,\"chat\":{\"id\":99,\"type\":\"private\"},\"text\":\"/start " ++
        unknown_code ++ "\"}}]}").*;
    const polls = [_]testing.Reply{
        .{ .body = testing.ok_empty },
        .{ .body = &typed_code, .delay_ms = reply_delay_ms },
        .{ .body = testing.ok_empty },
    };
    const scripts = [_]testing.Script{
        .{ .method = "getMe", .replies = &.{
            .{
                .status = 401,
                .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}",
            },
            .{
                .body = "{\"ok\":true," ++
                    "\"result\":{\"id\":42,\"is_bot\":true,\"username\":\"drinky_bot\"}}",
            },
        } },
        .{
            .method = "deleteWebhook",
            .replies = &.{ .{ .body = testing.ok_true }, .{ .body = testing.ok_true } },
        },
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &polls },
    };
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&scripts);
    defer owner.deinit();
    var controller = try Controller.init(
        gpa,
        io,
        &owner.options(),
    );
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
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.token_prompt, controller.state());
    try std.testing.expectEqualStrings("Telegram rejected the bot token.", try owner.lastReport());
    var restored = false;
    for (owner.actions.items) |action| {
        if (action == .pairing_changed and action.pairing_changed == .prompt_restored) {
            restored = true;
        }
    }
    try std.testing.expect(restored);

    try std.testing.expectEqual(@as(usize, 0), controller.usernames().len);
    try controller.submitToken("42:secret");
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.pairing, controller.state());
    const code = controller.pairingCode();
    try std.testing.expectEqualStrings("drinky_bot", controller.pairingUsername());
    try std.testing.expectEqual(@as(usize, 1), controller.usernames().len);
    try std.testing.expect((try owner.savedChat(0)) == null);
    var expected_buffer: [96]u8 = undefined;
    const link = try controller.pairingLink(gpa);
    defer gpa.free(link);
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected_buffer, "https://t.me/drinky_bot?start={s}", .{code}),
        link,
    );

    const code_at = std.mem.indexOf(u8, &typed_code, unknown_code).?;
    typed_code[code_at..][0..code.len].* = code.*;
    try clock.pass(reply_delay_ms);
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.attached, controller.state());
    try std.testing.expectEqual(@as(usize, 1), controller.usernames().len);
    try std.testing.expectEqualStrings("drinky_bot", controller.usernames()[0]);
    var store = try Store.open(gpa, io, &owner.directories);
    defer store.deinit();
    const saved = store.get(0);
    try std.testing.expectEqualStrings("42:secret", saved.token);
    try std.testing.expectEqual(@as(i64, 42), saved.id);
    try std.testing.expectEqual(@as(?i64, 99), saved.chat_id);
    try owner.telegram.finish();
}

test "a cancel of the pairing keeps or drops the token by its scope" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{});
    defer owner.deinit();
    var controller = try Controller.init(
        gpa,
        io,
        &owner.options(),
    );
    defer endTest(&controller);

    try controller.beginTokenPrompt();
    try controller.submitToken("42:secret");
    try controller.cancelPairing(.step);
    try std.testing.expectEqual(State.token_prompt, controller.state());
    try std.testing.expectEqual(Action.PairingChange.prompt_restored, owner.lastPairingChange().?);
    try std.testing.expectEqualStrings("You canceled the token check.", try owner.lastReport());

    try controller.submitToken("42:secret");
    try controller.cancelPairing(.command);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expectEqual(Action.PairingChange.ended, owner.lastPairingChange().?);
    try std.testing.expectEqualStrings("You canceled the bot token.", try owner.lastReport());

    try controller.beginTokenPrompt();
    try controller.cancelTokenPrompt();
    try std.testing.expectEqual(State.idle, controller.state());
}

test "the token of a paired bot keeps its chat until a code arrives" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{
        .{ .method = "getMe", .replies = &.{.{
            .body = "{\"ok\":true," ++
                "\"result\":{\"id\":42,\"is_bot\":true,\"username\":\"drinky_bot\"}}",
        }} },
    });
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = 99,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try controller.beginTokenPrompt();
    try controller.submitToken("42:fresh");
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.pairing, controller.state());
    try controller.cancelPairing(.step);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expectEqual(@as(usize, 1), controller.usernames().len);
    var store = try Store.open(gpa, io, &owner.directories);
    defer store.deinit();
    const saved = store.get(0);
    try std.testing.expectEqualStrings("42:fresh", saved.token);
    try std.testing.expectEqual(@as(?i64, 99), saved.chat_id);

    try controller.attachSaved(0);
    try std.testing.expectEqual(State.attached, controller.state());
}

test "a saved bot without a chat waits for its code, and a cancel ends that wait" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{
        testing.webhook_deleted,
        .{ .method = "getUpdates", .replies = &.{.{ .body = testing.ok_empty }} },
    });
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = null,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try controller.attachSaved(0);
    try std.testing.expectEqual(State.pairing, controller.state());
    try std.testing.expect(owner.actions.items[0].pairing_changed == .check_started);
    try std.testing.expect(owner.actions.items[1].pairing_changed == .code_ready);
    try controller.cancelPairing(.step);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expectEqualStrings(
        "You canceled the pairing of @drinky_bot.",
        try owner.lastReport(),
    );

    try controller.removeBot(0);
    try std.testing.expectEqual(@as(usize, 0), controller.usernames().len);
    try std.testing.expectEqualStrings(
        "Drinky removed the bot @drinky_bot.",
        try owner.lastReport(),
    );
}

test "a wait that cannot start its task leaves the controller idle and frees the bot name once" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{});
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = null,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try std.testing.expectError(error.ConcurrencyUnavailable, controller.attachSaved(0));
    try std.testing.expectEqual(State.idle, controller.state());
}

test "a detach whose drain task cannot start ends at once and reports the lost last message" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .concurrent_limit = .limited(3) });
    defer threaded.deinit();
    const io = threaded.io();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{});
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = 99,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try controller.attachSaved(0);
    try std.testing.expectEqual(State.attached, controller.state());
    try controller.detach(&.user);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expectEqual(@as(usize, 1), owner.countReports("You detached @drinky_bot."));
    try std.testing.expectEqualStrings(
        "Drinky could not send the last message to @drinky_bot because of error " ++
            "ConcurrencyUnavailable.",
        try owner.lastReport(),
    );
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);
}

test "a failure of the chat reports once per run, and a permanent one detaches" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{
        testing.webhook_deleted,
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{ .status = 502, .body = "" },
            .{ .status = 502, .body = "" },
            .{ .body = testing.ok_empty },
            .{
                .status = 401,
                .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}",
            },
        } },
        .{ .method = "sendMessage", .replies = &.{.{ .body = testing.ok_sent }} },
    });
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = 99,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try controller.attachSaved(0);
    try clock.waitForSleep(Attachment.retry.backoff.delay(1));
    clock.advance(Attachment.outage_ms_min);
    try clock.pass(Attachment.retry.backoff.delay(2));
    try owner.pumpUntil(&controller, .detaching);
    try std.testing.expectEqual(@as(usize, 1), owner.countReports("could not poll @drinky_bot"));
    try std.testing.expectEqual(@as(usize, 1), owner.countReports("can poll @drinky_bot again"));
    try std.testing.expect(
        std.mem.indexOf(u8, try owner.lastReport(), "no longer knows the token") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, try owner.lastReport(), "Remove the bot") != null);
    try owner.pumpUntil(&controller, .idle);
    try owner.telegram.finish();
}

fn expectPollDetach(poll_reply: testing.Reply, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&.{
        testing.webhook_deleted,
        testing.commands_set,
        .{ .method = "getUpdates", .replies = &.{poll_reply} },
        .{ .method = "sendMessage", .replies = &.{.{ .body = testing.ok_sent }} },
    });
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = 99,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try controller.attachSaved(0);
    try owner.pumpUntil(&controller, .detaching);
    try std.testing.expectEqualStrings(expected, try owner.lastReport());
    try owner.pumpUntil(&controller, .idle);
    try owner.telegram.finish();
}

test "each permanent failure of the poll detaches with the text of its reason" {
    try expectPollDetach(.{
        .status = 401,
        .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}",
    }, "Telegram no longer knows the token of @drinky_bot, so Drinky detached it. Remove the " ++
        "bot with /remote and add it again.");
    try expectPollDetach(.{
        .status = 403,
        .body = "{\"ok\":false,\"error_code\":403," ++
            "\"description\":\"Forbidden: bot was blocked by the user\"}",
    }, "Telegram rejected a request of @drinky_bot: Forbidden: bot was blocked by the user. " ++
        "Drinky detached it.");
    try expectPollDetach(
        .{ .status = 403, .body = "" },
        "Telegram rejected a request of @drinky_bot, so Drinky detached it.",
    );
    try expectPollDetach(.{
        .status = 409,
        .body = "{\"ok\":false,\"error_code\":409," ++
            "\"description\":\"Conflict: terminated by other getUpdates request\"}",
    }, "Another client polls @drinky_bot, so Drinky detached it.");
    try expectPollDetach(.{
        .status = 400,
        .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request\"}",
    }, "Telegram rejected the poll of @drinky_bot, so Drinky detached it.");
}

test "a delivery event reports in the terminal alone, with the description that Telegram states" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner: Owner = .{ .gpa = gpa, .io = io };
    try owner.init(&testing.quiet_scripts);
    defer owner.deinit();
    try owner.saveBot(&.{
        .token = "42:secret",
        .id = 42,
        .username = "drinky_bot",
        .chat_id = 99,
    });
    var controller = try Controller.init(gpa, io, &owner.options());
    defer endTest(&controller);

    try controller.attachSaved(0);
    const cases = [_]struct { event: Attachment.Event, text: []const u8 }{
        .{
            .event = .{
                .generation = 1,
                .payload = .{ .failed = .{ .side = .send, .name = "Unavailable" } },
            },
            .text = "Drinky could not send to @drinky_bot because of error Unavailable. " ++
                "Drinky tries again.",
        },
        .{
            .event = .{ .generation = 1, .payload = .{ .recovered = .send } },
            .text = "Drinky can send to @drinky_bot again.",
        },
        .{
            .event = .{ .generation = 1, .payload = .{ .send_rejected = .{
                .kind = .message,
                .description = "Bad Request: chat not found",
            } } },
            .text = "Telegram rejected a message to @drinky_bot: Bad Request: chat not found.",
        },
        .{
            .event = .{ .generation = 1, .payload = .{ .send_rejected = .{
                .kind = .edit,
                .description = "",
            } } },
            .text = "Telegram rejected an edit in the chat of @drinky_bot.",
        },
        .{
            .event = .{ .generation = 1, .payload = .{ .send_dropped = .deletion } },
            .text = "Drinky dropped a deletion in the chat of @drinky_bot after 3 failed attempts.",
        },
    };
    for (cases) |case| {
        try controller.applyAttachmentEvent(&case.event);
        const report = owner.actions.items[owner.actions.items.len - 1].report;
        try std.testing.expectEqual(Action.Report.Kind.terminal_event, report.kind);
        try std.testing.expectEqualStrings(case.text, report.text);
    }
    try owner.telegram.finish();
}
