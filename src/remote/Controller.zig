//! The remote control of one session: the saved bots, the pairing of a new one,
//! the attached one, and the detached one whose sender still drains. It owns
//! every network task, every generation, and every Telegram id, and it is the
//! one source of truth for the remote state.
//!
//! The controller reports to its owner through a `Sink` of small actions, and it
//! exposes domain state alone. The owner maps that state to captions, pickers,
//! and the transcript, and it hands the reports of the tasks back through
//! `applyAttachmentEvent` and `applyPairingEvent`. The controller never waits on
//! the network: a detached bot drains in the `detaching` state until its sender
//! reports the end, or until the owner aborts the drain.

const std = @import("std");

const ai = @import("ai");

const Attachment = @import("Attachment.zig");
const Client = @import("Client.zig");
const Pairing = @import("Pairing.zig");
const Store = @import("Store.zig");

const Controller = @This();

gpa: std.mem.Allocator,
io: std.Io,
store: Store,
mode: Mode,
/// Last generation reserved for an attachment or a pairing. A report of one that
/// ended names a stale generation, so it drops.
generation: u64,
sink: Sink,
/// The sinks that the tasks report through. The owner routes them into its own
/// event channel and hands the events back to `applyAttachmentEvent` and
/// `applyPairingEvent`.
attachment_sink: Attachment.Sink,
pairing_sink: Pairing.Sink,
/// The API origin. A test points it at a loopback server.
base_url: []const u8,
/// The head window of one Telegram call.
connect_ms: u64,
pace: Attachment.Pace,
/// The code of the next pairing, or null for a fresh random one. A test fixes
/// it, so its scripted chat can send it.
code: ?Pairing.Code,
/// Whether the owner already learned that the send queue dropped a message. One
/// run of drops reports once, and the next send that the queue takes resets it.
drop_reported: bool,

/// Where the remote control stands. The tags are the `State` the owner reads.
const Mode = union(enum) {
    idle,
    /// The editor takes a token.
    token_prompt,
    /// The token check runs on the worker.
    checking_token: *Pairing,
    /// The wait for the code runs on the worker.
    pairing: *Pairing,
    attached: *Attachment,
    /// The detached bot sends the last message of its chat.
    detaching: *Attachment,
};

pub const State = std.meta.Tag(Mode);

pub const Options = struct {
    /// The saved bots. The controller takes ownership.
    store: Store,
    sink: Sink,
    attachment_sink: Attachment.Sink,
    pairing_sink: Pairing.Sink,
    base_url: []const u8 = Client.api_url,
    connect_ms: u64 = (ai.net.Timeouts{}).connect_ms,
    pace: Attachment.Pace = .{},
    code: ?Pairing.Code = null,
};

/// Where the controller reports. The owner acts on each action at once.
pub const Sink = struct {
    context: *anyopaque,
    act: *const fn (context: *anyopaque, action: Action) anyerror!void,
};

/// One report to the owner. Every text is borrowed for the call.
pub const Action = union(enum) {
    /// A text message from the bound chat. The owner runs it or queues it, and it
    /// answers with `reply`.
    chat_message: ChatMessage,
    /// One line for the owner to show.
    report: Report,
    /// The state changed. The owner reads `state` and the names it needs.
    state_changed,
    /// The pairing changed what the owner shows for it.
    pairing_changed: PairingChange,

    pub const ChatMessage = struct {
        id: i64,
        text: []const u8,
    };

    pub const Report = struct {
        kind: Kind,
        severity: ai.command.Outcome.Severity,
        text: []const u8,

        /// A durable event of the transcript, or a transient notice.
        pub const Kind = enum { event, notice };
    };

    pub const PairingChange = enum {
        /// The token check runs, so the owner shows a wait.
        check_started,
        /// The bot and the code are known, so the owner shows them.
        code_ready,
        /// The check ended without a bot, and the token prompt returns with the
        /// token, so the owner closes the wait alone.
        prompt_restored,
        /// The pairing ended, so the owner closes the wait and drops the token.
        ended,
    };
};

/// Why an attachment ends.
pub const DetachCause = union(enum) {
    user,
    exit,
    credential_rejected,
    failure: Attachment.Event.Reason,
};

/// How far a cancel of the pairing reaches.
pub const CancelScope = enum {
    /// Esc: a token check returns to the token prompt, and a code wait ends.
    step,
    /// Ctrl+C and Ctrl+D: the whole command ends.
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
        .drop_reported = false,
    };
}

/// Replace the store with the one at `home`. The startup calls it once the home
/// directory is known.
pub fn openStore(self: *Controller, home: []const u8) !void {
    const store = try Store.open(self.gpa, self.io, home);
    self.store.deinit();
    self.store = store;
}

/// End every task: detach with the exit event, end a pairing, and await the
/// sender inside its drain window. The owner calls it while it can still show
/// the reports, and `deinit` frees the rest later. The end of the tasks depends
/// on no report: a bot whose exit event cannot be written still closes.
pub fn shutdown(self: *Controller) void {
    self.detach(.exit) catch {};
    switch (self.mode) {
        // An attached bot here failed its detach before the close, so it closes
        // with no final message and drains like every other one.
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

/// Whether a pairing runs, so the owner routes the picker keys to it.
pub fn pairs(self: *const Controller) bool {
    return switch (self.mode) {
        .checking_token, .pairing => true,
        else => false,
    };
}

/// The username of every saved bot, in the order of the store.
pub fn usernames(self: *const Controller) []const []const u8 {
    return self.store.usernames.items;
}

/// The failure of the startup read of the store, or null when the file was
/// absent or read whole. The owner reports it once.
pub fn loadError(self: *const Controller) ?anyerror {
    return self.store.load_error;
}

/// The path of the store, for the report of a failed read.
pub fn storePath(self: *const Controller) []const u8 {
    return self.store.path;
}

/// The username of the attached or detaching bot, or null while there is none.
pub fn botUsername(self: *const Controller) ?[]const u8 {
    return switch (self.mode) {
        .attached, .detaching => |attachment| attachment.username,
        else => null,
    };
}

/// The code of the running pairing. The wait must have started.
pub fn pairingCode(self: *const Controller) *const Pairing.Code {
    return &self.mode.pairing.code;
}

/// The username of the bot that the running pairing waits for.
pub fn pairingUsername(self: *const Controller) []const u8 {
    return self.mode.pairing.username;
}

/// The link that sends the code of the running pairing with one click.
pub fn pairingLink(self: *const Controller, buffer: []u8) []const u8 {
    return self.mode.pairing.link(buffer);
}

/// Switch into the token prompt state. The owner cleared the editor.
pub fn beginTokenPrompt(self: *Controller) !void {
    std.debug.assert(self.mode == .idle);
    self.mode = .token_prompt;
    try self.showNotice(.information, "Paste the token that @BotFather gave you.", .{});
    try self.emit(.state_changed);
}

/// Leave the token prompt state without a bot. The owner cleared the editor.
pub fn cancelTokenPrompt(self: *Controller) !void {
    std.debug.assert(self.mode == .token_prompt);
    self.mode = .idle;
    try self.showNotice(.information, "You canceled the bot token.", .{});
    try self.emit(.state_changed);
}

/// Prove `token` on a worker. The owner keeps the token in the editor, so a
/// rejected token returns to it.
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
    // A failure below returns the prompt, and the owner learns that its wait is
    // over, so no picker outlives the check that it showed.
    errdefer {
        self.mode = .token_prompt;
        self.emit(.{ .pairing_changed = .prompt_restored }) catch {};
    }
    try self.emit(.{ .pairing_changed = .check_started });
    try pairing.startCheck();
    try self.emit(.state_changed);
}

/// Cancel the pairing and report the result.
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

/// Attach the saved bot at `index` of the store. A bot without a chat id pairs
/// first, and the bind attaches it.
pub fn attachSaved(self: *Controller, index: usize) !void {
    const bot = self.store.get(index) orelse
        return self.showNotice(.failure, "Select a valid row.", .{});
    if (self.mode != .idle) return self.showNotice(.warning, "Drinky cannot attach a bot now.", .{});
    if (bot.chat_id == null) return self.startWait(bot);
    try self.startAttachment(bot);
}

/// Remove the saved bot at `index` of the store and record it. One pick is the
/// decision, because BotFather restores a token.
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

/// Detach the bot: name the event as the final message of the chat, enter the
/// `detaching` state while the sender drains, and report the event. The sender
/// reports its end, or `abortDetach` ends it first. The close comes before every
/// report, so a failed report cannot leave a dead bot in the attached state. A
/// controller without an attached bot changes nothing.
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
    const line = try eventLine(self.gpa, severity, text);
    defer self.gpa.free(line);
    attachment.close(line) catch |err| switch (err) {
        error.OutOfMemory => {},
    };
    self.mode = .{ .detaching = attachment };
    try self.tell(.event, severity, text);
    try self.emit(.state_changed);
}

/// End the drain of the detached bot now, so the owner is free at once. The last
/// message of the chat drops with the queue. A controller without a detaching
/// bot changes nothing.
pub fn abortDetach(self: *Controller) !void {
    const attachment = switch (self.mode) {
        .detaching => |attachment| attachment,
        else => return,
    };
    attachment.abort();
    self.mode = .idle;
    try self.emit(.state_changed);
}

/// Queue one event line for the chat under its label. The owner sends the attach
/// event this way, because that event states the session.
pub fn sendEvent(
    self: *Controller,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) !void {
    const line = try eventLine(self.gpa, severity, text);
    defer self.gpa.free(line);
    try self.sendToChat(line, &.{ .disable_notification = true });
}

/// Answer the chat message `id` with `text`, silent.
pub fn reply(self: *Controller, id: i64, text: []const u8) !void {
    try self.sendToChat(text, &.{ .reply_to = id, .disable_notification = true });
}

/// Apply one report of an attachment. A report of the attached bot acts, a
/// `drained` report frees the detached bot it names, and every other report is
/// stale and drops.
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
        .unreadable => |id| try self.reply(id, "Drinky reads text alone."),
        .failed => |failure| try self.recordEvent(
            .failure,
            "Drinky could not {s} @{s} because of error {s}. Drinky tries again.",
            .{ sideVerb(failure.side), username, failure.name },
        ),
        .recovered => |side| try self.recordEvent(
            .information,
            "Drinky can {s} @{s} again.",
            .{ sideVerb(side), username },
        ),
        .send_rejected => |description| if (description.len > 0) {
            try self.recordEvent(
                .failure,
                "Telegram rejected a message to @{s}: {s}.",
                .{ username, description },
            );
        } else {
            try self.recordEvent(.failure, "Telegram rejected a message to @{s}.", .{username});
        },
        .detach => |reason| try self.detach(.{ .failure = reason }),
        .drained => unreachable,
    }
}

/// Apply one report of the pairing worker. A report of a canceled pairing names
/// a stale generation and drops.
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
                // The check task ended with its report, so the wait can start.
                pairing.cancel();
                {
                    // The pairing owns the username once the wait started, so
                    // the cleanup of the copy ends with this block.
                    const username = try self.gpa.dupe(u8, me.username);
                    errdefer self.gpa.free(username);
                    try pairing.startWait(me.id, username);
                }
                self.mode = .{ .pairing = pairing };
                // The token is proven, so the bot is saved now, without a chat.
                // A pairing that ends without a bind then keeps the bot in the
                // picker, and one pick starts the wait again.
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

/// Build the pairing worker for `token`.
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

/// Start the wait for the code of a saved bot that never paired. The bot is
/// borrowed.
fn startWait(self: *Controller, bot: *const Store.Bot) !void {
    const pairing = try self.createPairing(bot.token);
    errdefer pairing.destroy();
    {
        // The pairing owns the copy once the wait started, so the cleanup of the
        // copy ends with this block.
        const username = try self.gpa.dupe(u8, bot.username);
        errdefer self.gpa.free(username);
        try pairing.startWait(bot.id, username);
    }
    self.mode = .{ .pairing = pairing };
    // A failure below ends the pairing, and the owner learns that its wait is
    // over, so no picker outlives the pairing that it showed.
    errdefer {
        self.mode = .idle;
        self.emit(.{ .pairing_changed = .ended }) catch {};
    }
    try self.emit(.{ .pairing_changed = .check_started });
    try self.emit(.{ .pairing_changed = .code_ready });
    try self.emit(.state_changed);
}

/// Start the tasks of a paired bot and take the input. The bot is borrowed.
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
    });
    errdefer attachment.destroy();
    try attachment.start();
    self.mode = .{ .attached = attachment };
    // The destroy above runs after this, so no mode names the freed bot.
    errdefer self.mode = .idle;
    self.drop_reported = false;
    try self.emit(.state_changed);
}

/// Free the detached bot of `generation` once its sender ended, and hand the
/// input back. A report of a bot that an abort freed already names no bot.
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

/// Queue `text` for the chat without a wait. A full queue drops the message and
/// reports the first drop of a run. A closed or absent attachment takes nothing.
fn sendToChat(self: *Controller, text: []const u8, options: *const Client.SendOptions) !void {
    const attachment = switch (self.mode) {
        .attached => |attachment| attachment,
        else => return,
    };
    attachment.send(text, options) catch |err| switch (err) {
        error.Closed, error.Canceled => return,
        error.QueueFull => {
            if (self.drop_reported) return;
            self.drop_reported = true;
            return self.recordEvent(
                .failure,
                "Drinky dropped a message to @{s} because the send queue is full.",
                .{attachment.username},
            );
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    self.drop_reported = false;
}

/// The event of a detach. The result is owned.
fn detachText(self: *Controller, cause: DetachCause, username: []const u8) ![]u8 {
    return switch (cause) {
        .user => std.fmt.allocPrint(self.gpa, "You detached @{s}.", .{username}),
        .exit => std.fmt.allocPrint(
            self.gpa,
            "Drinky detached @{s} because Drinky exits.",
            .{username},
        ),
        // The repair is a login, and `/login` is terminal-only.
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

/// The chat line of one event: the text under its `Event:` or `Error:` label.
fn eventLine(
    gpa: std.mem.Allocator,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) ![]u8 {
    const label = if (severity == .failure) "Error: " else "Event: ";
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ label, text });
}

/// The verb of one side of the attachment in a failure or recovery event.
fn sideVerb(side: Attachment.Event.Side) []const u8 {
    return switch (side) {
        .poll => "poll",
        .send => "send to",
    };
}

fn emit(self: *Controller, action: Action) !void {
    try self.sink.act(self.sink.context, action);
}

/// Hand one line to the owner.
fn tell(
    self: *Controller,
    kind: Action.Report.Kind,
    severity: ai.command.Outcome.Severity,
    text: []const u8,
) !void {
    try self.emit(.{ .report = .{ .kind = kind, .severity = severity, .text = text } });
}

/// Hand one durable event to the owner.
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

/// Hand one transient notice to the owner.
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

/// Permanently reserve the next generation of `counter`.
fn reserveGeneration(counter: *u64) error{GenerationExhausted}!u64 {
    if (counter.* == std.math.maxInt(u64)) return error.GenerationExhausted;
    counter.* += 1;
    return counter.*;
}

const testing = @import("testing.zig");

/// The owner of the tests: it records every action with a copy of its text, and
/// it routes the reports of the tasks into one queue that the test drains into
/// the controller.
const Owner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    actions: std.ArrayList(Recorded) = .empty,
    /// The count of recorded actions at which the sink fails once, or null. A
    /// test sets it right after an ownership transfer, so the failure path of
    /// the controller runs with a live owner.
    fail_at: ?usize = null,
    events_buffer: [64]Event = undefined,
    events: std.Io.Queue(Event) = undefined,

    const Event = union(enum) {
        attachment: Attachment.Event,
        pairing: Pairing.Event,
    };

    const Recorded = union(enum) {
        chat_message: struct { id: i64, text: []u8 },
        report: struct { kind: Action.Report.Kind, severity: ai.command.Outcome.Severity, text: []u8 },
        state_changed,
        pairing_changed: Action.PairingChange,

        fn deinit(self: *const Recorded, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .chat_message => |message| gpa.free(message.text),
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

    /// Hand queued task reports to the controller until `count_min` of them
    /// applied, and wait up to about five seconds for them.
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

    /// Hand queued task reports to the controller until it reaches `target`, and
    /// wait up to about five seconds for it.
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

    /// The text of the last report, or an error when no action is a report.
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

    /// The report texts that contain `needle`, counted.
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

test "a saved bot attaches, its messages reach the owner, and a detach ends the chat" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = ok_empty },
            .{ .body =
            \\{"ok":true,"result":[
            \\{"update_id":1,"message":{"message_id":7,"date":0,"chat":{"id":99,"type":"private"},"text":"hello"}},
            \\{"update_id":2,"message":{"message_id":8,"date":0,"chat":{"id":99,"type":"private"},"sticker":{}}}
            \\]}
            },
        } },
        .{ .method = "sendMessage", .replies = &.{ .{ .body = ok_sent }, .{ .body = ok_sent }, .{ .body = ok_sent } } },
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
    defer controller.deinit();

    try controller.attachSaved(0);
    try std.testing.expectEqual(State.attached, controller.state());
    try std.testing.expectEqualStrings("drinky_bot", controller.botUsername().?);
    try std.testing.expect(owner.actions.items[0] == .state_changed);
    try server.waitForRequests(2);
    try controller.sendEvent(.information, "Remote: @drinky_bot · Context: 0");

    // The text message becomes an action, and the sticker gets its reply.
    try owner.pump(&controller, 2);
    const message = owner.actions.items[1].chat_message;
    try std.testing.expectEqual(@as(i64, 7), message.id);
    try std.testing.expectEqualStrings("hello", message.text);
    try controller.reply(7, "Sign in first.");

    try controller.detach(.user);
    // The bot drains its last message, and the owner learns the state first.
    try std.testing.expectEqual(State.detaching, controller.state());
    try std.testing.expectEqualStrings("drinky_bot", controller.botUsername().?);
    try std.testing.expectEqualStrings("You detached @drinky_bot.", try owner.lastReport());
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);
    try controller.attachSaved(0);
    try std.testing.expect(std.mem.indexOf(u8, try owner.lastReport(), "cannot attach a bot now") != null);
    // The sender reports its end, and the controller frees the bot.
    try owner.pump(&controller, 1);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expect(controller.botUsername() == null);
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);
    try server.finish();
    var buffer: [8][]const u8 = undefined;
    const sends = server.sentBodies(&buffer);
    try std.testing.expectEqual(@as(usize, 4), sends.len);
    try std.testing.expect(std.mem.indexOf(u8, sends[0], "\"text\":\"Event: Remote: @drinky_bot · Context: 0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "Drinky reads text alone.") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[1], "\"reply_parameters\":{\"message_id\":8}") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[2], "\"reply_parameters\":{\"message_id\":7}") != null);
    try std.testing.expect(std.mem.indexOf(u8, sends[3], "\"text\":\"Event: You detached @drinky_bot.\"") != null);
}

// An exit key during the drain hands the input back at once. The detach event
// then never reaches the chat, and the next attach starts without a wait,
// because no sender drains once the input is free.
test "an abort of the detach frees the owner at once and drops the last message" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // No script answers a send, so the detach event stays in flight.
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true } } },
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
    defer controller.deinit();

    try controller.attachSaved(0);
    try server.waitForRequests(2);
    try controller.detach(.user);
    try server.waitForSends(1);
    try std.testing.expectEqual(State.detaching, controller.state());

    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try controller.abortDetach();
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    try std.testing.expect(elapsed_ms < testing.pace.drain_ms - 100);
    try std.testing.expectEqual(State.idle, controller.state());
    try std.testing.expect(owner.actions.items[owner.actions.items.len - 1] == .state_changed);

    // The next attach starts at once, and the stale drain report of the freed
    // bot changes nothing.
    try controller.attachSaved(0);
    try std.testing.expectEqual(State.attached, controller.state());
    try server.waitForRequests(4);
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
    defer controller.deinit();

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

    // The rejected token saved nothing, and the proven one saves the bot with
    // no chat before the wait, so a pairing that ends without a bind keeps it.
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

    // The bind saves the chat of the bot and attaches it.
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
    // No script answers, so every check waits until the cancel.
    var server = try testing.Server.init(gpa, io, &.{});
    defer server.deinit();
    try server.start();
    var owner: Owner = .{ .gpa = gpa, .io = io };
    owner.init();
    defer owner.deinit();
    var url_buffer: [64]u8 = undefined;
    var controller = Controller.init(gpa, io, &owner.options(Store.inert(gpa, io), &server, &url_buffer));
    defer controller.deinit();

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
    defer controller.deinit();

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
    defer controller.deinit();

    try controller.attachSaved(0);
    try owner.pumpUntil(&controller, .detaching);
    try std.testing.expectEqual(@as(usize, 1), owner.countReports("could not poll @drinky_bot"));
    try std.testing.expectEqual(@as(usize, 1), owner.countReports("can poll @drinky_bot again"));
    try std.testing.expect(std.mem.indexOf(u8, try owner.lastReport(), "no longer knows the token") != null);
    try std.testing.expect(std.mem.indexOf(u8, try owner.lastReport(), "Remove the bot") != null);
    // The error event is the last message of the chat, and its end frees the input.
    try owner.pumpUntil(&controller, .idle);
    try server.finish();
}

// The owner can fail at any action, because its sink allocates. After each
// ownership transfer the controller alone frees what it holds, so a failure of
// the action that follows the transfer leaves no double owner, no dangling
// pointer, and no leak. The leak check of the test allocator proves the last part.
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
    defer controller.deinit();

    // The username moved into the pairing, and the `code_ready` action fails.
    // The bot is saved by then, so the cancel keeps it.
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

    // The pairing of a saved bot stands, and its first action fails: the pairing
    // ends and the owner learns it.
    owner.fail_at = owner.actions.items.len;
    try std.testing.expectError(error.SinkFailed, controller.attachSaved(1));
    try std.testing.expectEqual(State.idle, controller.state());

    // The attachment stands, and the `state_changed` action fails: no mode names
    // the freed bot.
    owner.fail_at = owner.actions.items.len;
    try std.testing.expectError(error.SinkFailed, controller.attachSaved(0));
    try std.testing.expectEqual(State.idle, controller.state());

    // The bot closed, and the detach event fails: the bot still drains in the
    // `detaching` state, so no dead bot stays attached, and its end still frees
    // the input.
    try controller.attachSaved(0);
    try server.waitForRequests(6);
    owner.fail_at = owner.actions.items.len;
    try std.testing.expectError(error.SinkFailed, controller.detach(.user));
    try std.testing.expectEqual(State.detaching, controller.state());
    try owner.pumpUntil(&controller, .idle);
}

// The exit must end the tasks of the bot whether or not the exit event can be
// written. A shutdown whose report fails still closes the bot, so no task holds
// the owner after its teardown. The leak check proves that the bot is freed.
test "a shutdown closes the bot even when its report fails" {
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
    try store.save(&.{ .token = "42:secret", .id = 42, .username = "drinky_bot", .chat_id = 99 });
    var controller = Controller.init(gpa, io, &owner.options(store, &server, &url_buffer));
    defer controller.deinit();

    try controller.attachSaved(0);
    try server.waitForRequests(2);
    owner.fail_at = owner.actions.items.len;
    controller.shutdown();
    try std.testing.expectEqual(State.idle, controller.state());
    // The report failed, so the exit event never reached the owner.
    try std.testing.expectEqual(@as(usize, 0), owner.countReports("because Drinky exits"));
}
