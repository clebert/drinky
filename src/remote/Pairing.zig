const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Client = @import("Client.zig");

const Pairing = @This();

const code_alphabet = "23456789abcdefghjkmnpqrstuvwxyz";
const code_length = 8;
pub const window_ms = 5 * std.time.ms_per_min;
pub const wrong_codes_max = 3;

const backoff: core.Retry.Backoff = .{};

gpa: std.mem.Allocator,
io: std.Io,
token: []const u8,
id: i64,
username: []const u8,
code: Code,
generation: u64,
sink: Sink,
client: Client,
poll_connect_ms: u64,
future: ?std.Io.Future(void),

pub const Code = [code_length]u8;

const Options = struct {
    transport: ?providers.Transport,
    token: []const u8,
    code: Code,
    connect_ms: u64,
    generation: u64,
    sink: Sink,
};

pub const Sink = core.actor.Sink(Event);

pub const Event = struct {
    generation: u64,
    payload: Payload,

    const Payload = union(enum) {
        token_checked: TokenCheck,
        paired: i64,
        ended: End,
    };

    const TokenCheck = union(enum) {
        bot: Client.Me,
        failed: Client.Error,
    };

    const End = union(enum) {
        too_many_codes,
        expired,
        failed: Client.Error,
    };

    pub fn dupe(self: *const Event, gpa: std.mem.Allocator) error{OutOfMemory}!Event {
        return .{ .generation = self.generation, .payload = switch (self.payload) {
            .token_checked => |check| .{ .token_checked = switch (check) {
                .bot => |me| if (gpa.dupe(u8, me.username)) |username|
                    .{ .bot = .{ .id = me.id, .username = username } }
                else |err|
                    .{ .failed = err },
                .failed => check,
            } },
            .paired, .ended => self.payload,
        } };
    }

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        switch (self.payload) {
            .token_checked => |check| switch (check) {
                .bot => |me| me.deinit(gpa),
                .failed => {},
            },
            .paired, .ended => {},
        }
    }
};

const WaitState = struct {
    poll: Client.Poll = .{ .commands = null },
    wrong_codes: u32 = 0,
};

const Step = union(enum) {
    waiting,
    paired: i64,
    too_many_codes,
};

pub fn generateCode(io: std.Io) Code {
    var bytes: Code = undefined;
    io.random(&bytes);
    var code: Code = undefined;
    for (bytes, &code) |byte, *symbol| symbol.* = code_alphabet[byte % code_alphabet.len];
    return code;
}

pub fn create(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !*Pairing {
    const self = try gpa.create(Pairing);
    errdefer gpa.destroy(self);
    const token = try gpa.dupe(u8, options.token);
    errdefer gpa.free(token);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .token = token,
        .id = 0,
        .username = "",
        .code = options.code,
        .generation = options.generation,
        .sink = options.sink,
        .client = .{
            .gpa = gpa,
            .io = io,
            .transport = options.transport,
            .token = token,
            .connect_ms = options.connect_ms,
        },
        .poll_connect_ms = 0,
        .future = null,
    };
    return self;
}

pub fn destroy(self: *Pairing) void {
    self.cancel();
    if (self.username.len > 0) self.gpa.free(self.username);
    self.gpa.free(self.token);
    self.gpa.destroy(self);
}

pub fn cancel(self: *Pairing) void {
    if (self.future) |*future| {
        future.cancel(self.io);
        self.future = null;
    }
}

pub fn startCheck(self: *Pairing) !void {
    std.debug.assert(self.future == null);
    self.future = try self.io.concurrent(runCheck, .{self});
}

pub fn startWait(self: *Pairing, id: i64, username: []const u8) !void {
    std.debug.assert(self.future == null);
    std.debug.assert(self.username.len == 0);
    const owned = try self.gpa.dupe(u8, username);
    errdefer self.gpa.free(owned);
    self.id = id;
    self.username = owned;
    errdefer self.username = "";
    self.poll_connect_ms = Client.pollConnectMs(self.client.connect_ms);
    self.client.connect_ms = self.poll_connect_ms;
    self.future = try self.io.concurrent(runWait, .{self});
}

pub fn link(self: *const Pairing, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa, "https://t.me/{s}?start={s}", .{ self.username, &self.code });
}

fn matches(code: *const Code, text: []const u8) bool {
    var candidate = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, candidate, "/start")) {
        candidate = std.mem.trim(u8, candidate["/start".len..], " \t\r\n");
    }
    return std.ascii.eqlIgnoreCase(candidate, code);
}

fn emit(self: *Pairing, payload: Event.Payload) void {
    self.sink.emit(self.io, &.{ .generation = self.generation, .payload = payload });
}

fn runCheck(self: *Pairing) void {
    const me = self.client.getMe() catch |err| {
        return self.emit(.{ .token_checked = .{ .failed = err } });
    };
    defer me.deinit(self.gpa);
    self.emit(.{ .token_checked = .{ .bot = me } });
}

fn runWait(self: *Pairing) void {
    self.waitForCode() catch {};
}

fn nowMs(self: *const Pairing) i64 {
    return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
}

fn pause(self: *const Pairing, wait_ms: u64, deadline_ms: i64) error{Canceled}!void {
    const remaining: u64 = @intCast(@max(0, deadline_ms - self.nowMs()));
    const bounded = @min(wait_ms, remaining);
    if (bounded == 0) return;
    try core.timeout.sleep(self.io, bounded);
}

fn waitForCode(self: *Pairing) error{Canceled}!void {
    const deadline_ms = self.nowMs() + window_ms;
    var state: WaitState = .{};
    var failures: u32 = 0;
    while (true) {
        if (self.nowMs() >= deadline_ms) return self.emit(.{ .ended = .expired });
        const step = self.waitOnce(&state, deadline_ms) catch |err| switch (Client.Class.of(err)) {
            .canceled => return error.Canceled,
            .rate_limited => {
                try self.pause(self.client.retryAfterMs(backoff.delay_ms_max), deadline_ms);
                continue;
            },
            .transient => {
                failures +|= 1;
                try self.pause(backoff.delay(failures), deadline_ms);
                continue;
            },
            .permanent, .rejected => return self.emit(.{ .ended = .{ .failed = err } }),
        };
        failures = 0;
        switch (step) {
            .waiting => {},
            .paired => |chat_id| return self.emit(.{ .paired = chat_id }),
            .too_many_codes => return self.emit(.{ .ended = .too_many_codes }),
        }
    }
}

fn waitOnce(
    self: *Pairing,
    state: *WaitState,
    deadline_ms: i64,
) Client.Error!Step {
    const client = &self.client;
    const remaining_ms: u64 = @intCast(@max(1, deadline_ms - self.nowMs()));
    client.connect_ms = @min(self.poll_connect_ms, remaining_ms);
    const timeout_s = @max(1, @min(
        Client.pollTimeoutSeconds(self.poll_connect_ms),
        @divFloor(remaining_ms, std.time.ms_per_s),
    ));
    const updates = try state.poll.next(client, timeout_s);
    defer updates.deinit(self.gpa);
    if (self.nowMs() >= deadline_ms) return .waiting;
    for (updates.items) |update| {
        const message = update.message orelse continue;
        if (!message.chat_private) continue;
        const text = message.text orelse continue;
        if (matches(&self.code, text)) return .{ .paired = message.chat_id };
        state.wrong_codes += 1;
        if (state.wrong_codes >= wrong_codes_max) return .too_many_codes;
    }
    return .waiting;
}

const testing = @import("testing.zig");

test generateCode {
    const code = generateCode(std.testing.io);
    for (code) |symbol| try std.testing.expect(
        std.mem.indexOfScalar(u8, code_alphabet, symbol) != null,
    );
    try std.testing.expectEqual(@as(usize, 31), code_alphabet.len);
    for ("0o1il") |banned| try std.testing.expect(
        std.mem.indexOfScalar(u8, code_alphabet, banned) == null,
    );
    for (code_alphabet) |symbol| try std.testing.expect(!std.ascii.isUpper(symbol));
}

const Rig = testing.Rig(Event);

const test_code: Code = "x7kq4m2p".*;

const connect_ms_long = 2 * window_ms;

fn testPairing(rig: *Rig, connect_ms: u64) !*Pairing {
    return create(std.testing.allocator, rig.telegram.io, &.{
        .transport = rig.telegram.transport(),
        .token = "42:secret",
        .code = test_code,
        .connect_ms = connect_ms,
        .generation = 3,
        .sink = rig.collector.sink(),
    });
}

test "a code binds with or without /start, in any case, and between blanks" {
    const cases = [_]struct { text: []const u8, binds: bool }{
        .{ .text = "x7kq4m2p", .binds = true },
        .{ .text = " X7kq4m2p\n", .binds = true },
        .{ .text = "/start x7kq4m2p", .binds = true },
        .{ .text = "/start   x7kq4m2p", .binds = true },
        .{ .text = "/start", .binds = false },
        .{ .text = "x7kq4m2", .binds = false },
        .{ .text = "hello", .binds = false },
    };
    for (cases) |case| {
        var body_buffer: [1024]u8 = undefined;
        var body: std.Io.Writer = .fixed(&body_buffer);
        try body.writeAll("{\"ok\":true,\"result\":[");
        const copies: usize = if (case.binds) 1 else wrong_codes_max;
        for (1..copies + 1) |id| {
            if (id > 1) try body.writeByte(',');
            try body.print("{{\"update_id\":{d},\"message\":{{\"message_id\":{d},\"date\":0," ++
                "\"chat\":{{\"id\":99,\"type\":\"private\"}},\"text\":{f}}}}}", .{
                id,
                id,
                std.json.fmt(case.text, .{}),
            });
        }
        try body.writeAll("]}");
        const replies = [_]testing.Reply{
            .{ .body = testing.ok_empty },
            .{ .body = body.buffered() },
        };
        const scripts = [_]testing.Script{
            testing.webhook_deleted,
            .{ .method = "getUpdates", .replies = &replies },
        };
        var rig: Rig = undefined;
        try rig.init(std.testing.io, &scripts);
        defer rig.deinit();
        const pairing = try testPairing(&rig, 60_000);
        defer pairing.destroy();
        try pairing.startWait(42, "drinky_bot");

        try rig.collector.waitFor(1);
        try rig.telegram.finish();
        const payload = rig.collector.events.items[0].payload;
        if (case.binds)
            try std.testing.expectEqual(@as(i64, 99), payload.paired)
        else
            try std.testing.expect(payload.ended == .too_many_codes);
    }
}

test "the check names the bot, or reports why the token failed" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &.{.{ .method = "getMe", .replies = &.{
        .{
            .status = 401,
            .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}",
        },
        .{
            .body = "{\"ok\":true," ++
                "\"result\":{\"id\":42,\"is_bot\":true,\"username\":\"drinky_bot\"}}",
        },
    } }});
    defer rig.deinit();

    const rejected = try testPairing(&rig, 60_000);
    defer rejected.destroy();
    try rejected.startCheck();
    try rig.collector.waitFor(1);
    try std.testing.expectEqual(@as(u64, 3), rig.collector.events.items[0].generation);
    try std.testing.expectEqual(
        Client.Error.Unauthorized,
        rig.collector.events.items[0].payload.token_checked.failed,
    );

    const accepted = try testPairing(&rig, 60_000);
    defer accepted.destroy();
    try accepted.startCheck();
    try rig.collector.waitFor(2);
    try rig.telegram.finish();
    const me = rig.collector.events.items[1].payload.token_checked.bot;
    try std.testing.expectEqual(@as(i64, 42), me.id);
    try std.testing.expectEqualStrings("drinky_bot", me.username);
}

test "the wait binds the private chat that sends the code and ignores a group" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{ .body =
            \\{"ok":true,"result":[
            \\{"update_id":1,"message":{"message_id":1,"date":0,"chat":{"id":-5,"type":"group"},
            \\"text":"x7kq4m2p"}},
            \\{"update_id":2,"message":{"message_id":2,"date":0,"chat":{"id":77,"type":"private"},
            \\"text":"wrong"}},
            \\{"update_id":3,"message":{"message_id":3,"date":0,"chat":{"id":88,"type":"private"},
            \\"sticker":{}}},
            \\{"update_id":4,"message":{"message_id":4,"date":0,"chat":{"id":99,"type":"private"},
            \\"text":"/start x7kq4m2p"}}
            \\]}
            },
        } },
    });
    defer rig.deinit();
    const pairing = try testPairing(&rig, 60_000);
    defer pairing.destroy();
    try pairing.startWait(42, "drinky_bot");
    const url = try pairing.link(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://t.me/drinky_bot?start=x7kq4m2p", url);

    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    try std.testing.expectEqual(@as(i64, 99), rig.collector.events.items[0].payload.paired);
}

test "a short configured window does not shorten the wait poll" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        .{ .method = "getUpdates", .replies = &.{.{ .body = testing.ok_empty }} },
    });
    defer rig.deinit();
    const pairing = try testPairing(&rig, 5_000);
    defer pairing.destroy();

    try pairing.startWait(42, "drinky_bot");
    try rig.telegram.waitForLongPoll();
    try rig.telegram.finish();
    try std.testing.expect(
        std.mem.indexOf(u8, rig.telegram.requests.items[2].body, "\"timeout\":25,") != null,
    );
}

test "three wrong codes end the wait, and so does a 409" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{
        .{
            .method = "deleteWebhook",
            .replies = &.{ .{ .body = testing.ok_true }, .{ .body = testing.ok_true } },
        },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{ .status = 500, .body = "" },
            .{ .body =
            \\{"ok":true,"result":[
            \\{"update_id":1,"message":{"message_id":1,"date":0,"chat":{"id":77,"type":"private"},
            \\"text":"a"}},
            \\{"update_id":2,"message":{"message_id":2,"date":0,"chat":{"id":78,"type":"private"},
            \\"text":"b"}},
            \\{"update_id":3,"message":{"message_id":3,"date":0,"chat":{"id":79,"type":"private"},
            \\"text":"c"}},
            \\{"update_id":4,"message":{"message_id":4,"date":0,"chat":{"id":99,"type":"private"},
            \\"text":"x7kq4m2p"}}
            \\]}
            },
            .{ .body = testing.ok_empty },
            .{
                .status = 409,
                .body = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict\"}",
            },
        } },
    });
    defer rig.deinit();

    const bounded = try testPairing(&rig, 60_000);
    defer bounded.destroy();
    try bounded.startWait(42, "drinky_bot");
    try clock.pass(backoff.delay(1));
    try rig.collector.waitFor(1);
    try std.testing.expect(rig.collector.events.items[0].payload.ended == .too_many_codes);

    const conflicted = try testPairing(&rig, 60_000);
    defer conflicted.destroy();
    try conflicted.startWait(42, "drinky_bot");
    try rig.collector.waitFor(2);
    try rig.telegram.finish();
    try std.testing.expectEqual(
        Client.Error.Conflict,
        rig.collector.events.items[1].payload.ended.failed,
    );
}

test "a 429 pauses the wait for the stated wait" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{
                .status = 429,
                .body = "{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":1}}",
            },
            .{ .body =
            \\{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"date":0,
            \\"chat":{"id":99,"type":"private"},"text":"x7kq4m2p"}}]}
            },
        } },
    });
    defer rig.deinit();
    const pairing = try testPairing(&rig, 60_000);
    defer pairing.destroy();
    try pairing.startWait(42, "drinky_bot");

    try clock.waitForSleep(std.time.ms_per_s);
    try std.testing.expectEqual(@as(usize, 2), rig.telegram.countOf("/getUpdates"));
    clock.advance(std.time.ms_per_s);
    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    try std.testing.expectEqual(@as(i64, 99), rig.collector.events.items[0].payload.paired);
}

test "a code that arrives after the window does not bind" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty },
            .{ .body =
            \\{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"date":0,
            \\"chat":{"id":99,"type":"private"},"text":"x7kq4m2p"}}]}
            , .delay_ms = 2 * window_ms },
        } },
    });
    defer rig.deinit();
    const pairing = try testPairing(&rig, connect_ms_long);
    defer pairing.destroy();
    try pairing.startWait(42, "drinky_bot");

    _ = try rig.telegram.waitForRequest("/getUpdates", 1);
    try clock.pass(window_ms);
    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    try std.testing.expect(rig.collector.events.items[0].payload == .ended);
    try std.testing.expect(rig.collector.events.items[0].payload.ended == .expired);
}

test "a poll that never returns ends at the window, not at the poll head window" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        .{ .method = "getUpdates", .replies = &.{.{ .body = testing.ok_empty }} },
    });
    defer rig.deinit();
    const pairing = try testPairing(&rig, connect_ms_long);
    defer pairing.destroy();
    try pairing.startWait(42, "drinky_bot");

    _ = try rig.telegram.waitForRequest("/getUpdates", 1);
    try clock.pass(window_ms);
    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    try std.testing.expect(rig.collector.events.items[0].payload.ended == .expired);
}

test "a setup call that never returns ends at the window too" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: Rig = undefined;
    try rig.init(io, &.{});
    defer rig.deinit();
    const pairing = try testPairing(&rig, connect_ms_long);
    defer pairing.destroy();
    try pairing.startWait(42, "drinky_bot");

    _ = try rig.telegram.waitForRequest("/deleteWebhook", 0);
    try clock.pass(window_ms);
    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    try std.testing.expect(rig.collector.events.items[0].payload.ended == .expired);
}

test "the wait expires at its window and clamps the poll to it" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    const rest_ms = 1_500;
    var rig: Rig = undefined;
    try rig.init(io, &.{
        testing.webhook_deleted,
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = testing.ok_empty, .delay_ms = window_ms - rest_ms },
        } },
    });
    defer rig.deinit();
    const pairing = try testPairing(&rig, connect_ms_long);
    defer pairing.destroy();
    try pairing.startWait(42, "drinky_bot");

    try clock.pass(window_ms - rest_ms);
    _ = try rig.telegram.waitForRequest("/getUpdates", 1);
    try clock.pass(rest_ms);
    try rig.collector.waitFor(1);
    try rig.telegram.finish();
    try std.testing.expect(rig.collector.events.items[0].payload.ended == .expired);
    try std.testing.expect(
        std.mem.indexOf(u8, rig.telegram.requests.items[2].body, "\"timeout\":1,") != null,
    );
}

test "a copy of a token check owns its username, and a failed copy reports OutOfMemory" {
    var username = "drinky_bot".*;
    const event: Event = .{ .generation = 4, .payload = .{ .token_checked = .{ .bot = .{
        .id = 42,
        .username = &username,
    } } } };
    const copy = try event.dupe(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("drinky_bot", copy.payload.token_checked.bot.username);

    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const failed = try event.dupe(failing.allocator());
    try std.testing.expectEqual(@as(u64, 4), failed.generation);
    try std.testing.expectEqual(error.OutOfMemory, failed.payload.token_checked.failed);
}
