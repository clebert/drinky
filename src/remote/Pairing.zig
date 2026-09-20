const std = @import("std");

const ai = @import("ai");

const Client = @import("Client.zig");

const Pairing = @This();

const code_alphabet = "23456789abcdefghjkmnpqrstuvwxyz";
const code_length = 8;
const window_ms_default = 5 * std.time.ms_per_min;
pub const wrong_codes_max = 3;

const backoff_default: ai.net.Retry = .{
    .attempts_max = std.math.maxInt(u32),
    .backoff_ms_initial = 500,
    .backoff_ms_max = 16_000,
};

pub const Code = [code_length]u8;

gpa: std.mem.Allocator,
io: std.Io,
token: []const u8,
id: i64,
username: []const u8,
code: Code,
generation: u64,
sink: Sink,
window_ms: u64,
backoff: ai.net.Retry,
client: Client,
poll_connect_ms: u64,
future: ?std.Io.Future(void),

pub const Options = struct {
    base_url: []const u8 = Client.api_url,
    token: []const u8,
    code: Code,
    connect_ms: u64,
    generation: u64,
    sink: Sink,
    window_ms: u64 = window_ms_default,
    backoff: ai.net.Retry = backoff_default,
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: Event) error{Closed}!void,
};

pub const Event = struct {
    generation: u64,
    payload: Payload,

    pub const Payload = union(enum) {
        token_checked: TokenCheck,
        paired: i64,
        ended: End,
    };

    pub const TokenCheck = union(enum) {
        bot: Client.Me,
        failed: Client.Error,
    };

    pub const End = union(enum) {
        too_many_codes,
        expired,
        failed: Client.Error,
    };

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
        .window_ms = options.window_ms,
        .backoff = options.backoff,
        .client = .{
            .gpa = gpa,
            .io = io,
            .base_url = options.base_url,
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
    self.id = id;
    self.username = username;
    self.poll_connect_ms = Client.pollConnectMs(self.client.connect_ms);
    self.client.connect_ms = self.poll_connect_ms;
    self.future = try self.io.concurrent(runWait, .{self});
}

pub fn link(self: *const Pairing, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "https://t.me/{s}?start={s}",
        .{ self.username, &self.code },
    ) catch unreachable;
}

fn matches(code: *const Code, text: []const u8) bool {
    var candidate = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, candidate, "/start")) {
        candidate = std.mem.trim(u8, candidate["/start".len..], " \t\r\n");
    }
    return std.ascii.eqlIgnoreCase(candidate, code);
}

fn emit(self: *Pairing, payload: Event.Payload) error{Closed}!void {
    return self.sink.emit(self.sink.context, .{ .generation = self.generation, .payload = payload });
}

fn runCheck(self: *Pairing) void {
    const me = self.client.getMe() catch |err| {
        self.emit(.{ .token_checked = .{ .failed = err } }) catch {};
        return;
    };
    self.emit(.{ .token_checked = .{ .bot = me } }) catch me.deinit(self.gpa);
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
    self.io.sleep(.fromMilliseconds(@intCast(bounded)), .awake) catch return error.Canceled;
}

fn waitForCode(self: *Pairing) error{ Closed, Canceled }!void {
    const deadline_ms = self.nowMs() + @as(i64, @intCast(self.window_ms));
    var state: WaitState = .{};
    var failures: u32 = 0;
    while (true) {
        if (self.nowMs() >= deadline_ms) return self.emit(.{ .ended = .expired });
        const step = self.waitOnce(&state, deadline_ms) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return error.Closed,
            error.RateLimited => {
                try self.pause(self.client.retry_after_s *| std.time.ms_per_s, deadline_ms);
                continue;
            },
            error.Unavailable, error.MalformedReply, error.OutOfMemory => {
                failures +|= 1;
                try self.pause(self.backoff.backoffMs(.{ .attempt = failures }), deadline_ms);
                continue;
            },
            error.Unauthorized,
            error.Forbidden,
            error.Conflict,
            error.Rejected,
            => |failure| return self.emit(.{ .ended = .{ .failed = failure } }),
        };
        failures = 0;
        switch (step) {
            .waiting => {},
            .paired => |chat_id| return self.emit(.{ .paired = chat_id }),
            .too_many_codes => return self.emit(.{ .ended = .too_many_codes }),
        }
    }
}

const WaitState = struct {
    webhook_deleted: bool = false,
    confirmed: bool = false,
    offset: ?i64 = null,
    wrong_codes: u32 = 0,
};

const Step = union(enum) {
    waiting,
    paired: i64,
    too_many_codes,
};

fn waitOnce(self: *Pairing, state: *WaitState, deadline_ms: i64) (Client.Error || error{Closed})!Step {
    const client = &self.client;
    const remaining_ms: u64 = @intCast(@max(1, deadline_ms - self.nowMs()));
    client.connect_ms = @min(self.poll_connect_ms, remaining_ms);
    if (!state.webhook_deleted) {
        try client.deleteWebhook();
        state.webhook_deleted = true;
        return .waiting;
    }
    if (!state.confirmed) {
        const newest = try client.getUpdates(-1, 0);
        defer newest.deinit(self.gpa);
        if (newest.items.len > 0) state.offset = newest.items[newest.items.len - 1].update_id + 1;
        state.confirmed = true;
        return .waiting;
    }
    const timeout_s = @max(1, @min(
        Client.pollTimeoutSeconds(self.poll_connect_ms),
        @divFloor(remaining_ms, std.time.ms_per_s),
    ));
    const updates = try client.getUpdates(state.offset, timeout_s);
    defer updates.deinit(self.gpa);
    if (self.nowMs() >= deadline_ms) return .waiting;
    for (updates.items) |update| {
        state.offset = update.update_id + 1;
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

const Collector = testing.Collector(Event, Sink);

const test_code: Code = "x7kq4m2p".*;
const ok_true = "{\"ok\":true,\"result\":true}";
const ok_empty = "{\"ok\":true,\"result\":[]}";

const test_window_ms = 100;

fn testPairing(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *const testing.Server,
    url_buffer: []u8,
    collector: *Collector,
    window_ms: u64,
) !*Pairing {
    return create(gpa, io, &.{
        .base_url = server.url(url_buffer),
        .token = "42:secret",
        .code = test_code,
        .connect_ms = 60_000,
        .generation = 3,
        .sink = collector.sink(),
        .window_ms = window_ms,
        .backoff = .{ .attempts_max = std.math.maxInt(u32), .backoff_ms_initial = 10, .backoff_ms_max = 20 },
    });
}

test generateCode {
    const code = generateCode(std.testing.io);
    for (code) |symbol| try std.testing.expect(std.mem.indexOfScalar(u8, code_alphabet, symbol) != null);
    try std.testing.expectEqual(@as(usize, 31), code_alphabet.len);
    for ("0o1il") |banned| try std.testing.expect(std.mem.indexOfScalar(u8, code_alphabet, banned) == null);
    for (code_alphabet) |symbol| try std.testing.expect(!std.ascii.isUpper(symbol));
}

test matches {
    try std.testing.expect(matches(&test_code, "x7kq4m2p"));
    try std.testing.expect(matches(&test_code, " X7kq4m2p\n"));
    try std.testing.expect(matches(&test_code, "/start x7kq4m2p"));
    try std.testing.expect(matches(&test_code, "/start"[0..6] ++ "   x7kq4m2p"));
    try std.testing.expect(!matches(&test_code, "/start"));
    try std.testing.expect(!matches(&test_code, "x7kq4m2"));
    try std.testing.expect(!matches(&test_code, "hello"));
}

test "the check names the bot, or reports why the token failed" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "getMe", .replies = &.{
        .{ .status = 401, .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}" },
        .{ .body = "{\"ok\":true,\"result\":{\"id\":42,\"is_bot\":true,\"username\":\"drinky_bot\"}}" },
    } }});
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;

    const rejected = try testPairing(gpa, io, &server, &url_buffer, &collector, window_ms_default);
    defer rejected.destroy();
    try rejected.startCheck();
    try collector.waitFor(1);
    try std.testing.expectEqual(@as(u64, 3), collector.events.items[0].generation);
    try std.testing.expectEqual(
        Client.Error.Unauthorized,
        collector.events.items[0].payload.token_checked.failed,
    );

    const accepted = try testPairing(gpa, io, &server, &url_buffer, &collector, window_ms_default);
    defer accepted.destroy();
    try accepted.startCheck();
    try collector.waitFor(2);
    try server.finish();
    const me = collector.events.items[1].payload.token_checked.bot;
    try std.testing.expectEqual(@as(i64, 42), me.id);
    try std.testing.expectEqualStrings("drinky_bot", me.username);
}

test "the wait binds the private chat that sends the code and ignores a group" {
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
            \\{"update_id":1,"message":{"message_id":1,"date":0,"chat":{"id":-5,"type":"group"},"text":"x7kq4m2p"}},
            \\{"update_id":2,"message":{"message_id":2,"date":0,"chat":{"id":77,"type":"private"},"text":"wrong"}},
            \\{"update_id":3,"message":{"message_id":3,"date":0,"chat":{"id":88,"type":"private"},"sticker":{}}},
            \\{"update_id":4,"message":{"message_id":4,"date":0,"chat":{"id":99,"type":"private"},"text":"/start x7kq4m2p"}}
            \\]}
            },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const pairing = try testPairing(gpa, io, &server, &url_buffer, &collector, window_ms_default);
    defer pairing.destroy();
    try pairing.startWait(42, try gpa.dupe(u8, "drinky_bot"));
    var link_buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://t.me/drinky_bot?start=x7kq4m2p",
        pairing.link(&link_buffer),
    );

    try collector.waitFor(1);
    try server.finish();
    try std.testing.expectEqual(@as(i64, 99), collector.events.items[0].payload.paired);
}

test "a short configured window does not shorten the wait poll" {
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
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const pairing = try create(gpa, io, &.{
        .base_url = server.url(&url_buffer),
        .token = "42:secret",
        .code = test_code,
        .connect_ms = 5_000,
        .generation = 3,
        .sink = collector.sink(),
    });
    defer pairing.destroy();
    try std.testing.expectEqual(@as(u64, 5_000), pairing.client.connect_ms);

    try pairing.startWait(42, try gpa.dupe(u8, "drinky_bot"));
    try std.testing.expectEqual(
        @as(u64, Client.poll_connect_ms_min),
        pairing.client.connect_ms,
    );
    try server.waitForLongPoll();
    try server.finish();
    try std.testing.expect(std.mem.indexOf(u8, server.requests.items[2].body, "\"timeout\":25,") != null);
}

test "three wrong codes end the wait, and so does a 409" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{ .{ .body = ok_true }, .{ .body = ok_true } } },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = ok_empty },
            .{ .status = 500, .body = "" },
            .{ .body =
            \\{"ok":true,"result":[
            \\{"update_id":1,"message":{"message_id":1,"date":0,"chat":{"id":77,"type":"private"},"text":"a"}},
            \\{"update_id":2,"message":{"message_id":2,"date":0,"chat":{"id":78,"type":"private"},"text":"b"}},
            \\{"update_id":3,"message":{"message_id":3,"date":0,"chat":{"id":79,"type":"private"},"text":"c"}},
            \\{"update_id":4,"message":{"message_id":4,"date":0,"chat":{"id":99,"type":"private"},"text":"x7kq4m2p"}}
            \\]}
            },
            .{ .body = ok_empty },
            .{ .status = 409, .body = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict\"}" },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;

    const bounded = try testPairing(gpa, io, &server, &url_buffer, &collector, window_ms_default);
    defer bounded.destroy();
    try bounded.startWait(42, try gpa.dupe(u8, "drinky_bot"));
    try collector.waitFor(1);
    try std.testing.expect(collector.events.items[0].payload.ended == .too_many_codes);

    const conflicted = try testPairing(gpa, io, &server, &url_buffer, &collector, window_ms_default);
    defer conflicted.destroy();
    try conflicted.startWait(42, try gpa.dupe(u8, "drinky_bot"));
    try collector.waitFor(2);
    try server.finish();
    try std.testing.expectEqual(
        Client.Error.Conflict,
        collector.events.items[1].payload.ended.failed,
    );
}

test "a code that arrives after the window does not bind" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = ok_empty },
            .{ .body =
            \\{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"x7kq4m2p"}}]}
            , .delay_ms = 3 * test_window_ms },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const pairing = try testPairing(gpa, io, &server, &url_buffer, &collector, test_window_ms);
    defer pairing.destroy();
    try pairing.startWait(42, try gpa.dupe(u8, "drinky_bot"));

    try collector.waitFor(1);
    try server.finish();
    try std.testing.expect(collector.events.items[0].payload == .ended);
    try std.testing.expect(collector.events.items[0].payload.ended == .expired);
}

test "a poll that never returns ends at the window, not at the poll head window" {
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
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const pairing = try testPairing(gpa, io, &server, &url_buffer, &collector, test_window_ms);
    defer pairing.destroy();
    try pairing.startWait(42, try gpa.dupe(u8, "drinky_bot"));

    try collector.waitFor(1);
    try server.finish();
    try std.testing.expect(collector.events.items[0].payload.ended == .expired);
}

test "a setup call that never returns ends at the window too" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{});
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const pairing = try testPairing(gpa, io, &server, &url_buffer, &collector, test_window_ms);
    defer pairing.destroy();
    try pairing.startWait(42, try gpa.dupe(u8, "drinky_bot"));

    try collector.waitFor(1);
    try server.finish();
    try std.testing.expect(collector.events.items[0].payload.ended == .expired);
}

test "the wait expires at its window and clamps the poll to it" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{
        .{ .method = "deleteWebhook", .replies = &.{.{ .body = ok_true }} },
        .{ .method = "getUpdates", .replies = &.{
            .{ .body = ok_empty },
            .{ .body = ok_empty, .delay_ms = 3 * test_window_ms },
        } },
    });
    defer server.deinit();
    try server.start();
    var collector: Collector = .{ .gpa = gpa, .io = io };
    defer collector.deinit();
    var url_buffer: [64]u8 = undefined;
    const pairing = try testPairing(gpa, io, &server, &url_buffer, &collector, test_window_ms);
    defer pairing.destroy();
    try pairing.startWait(42, try gpa.dupe(u8, "drinky_bot"));

    try collector.waitFor(1);
    try server.finish();
    try std.testing.expect(collector.events.items[0].payload.ended == .expired);
    try std.testing.expect(std.mem.indexOf(u8, server.requests.items[2].body, "\"timeout\":1,") != null);
}
