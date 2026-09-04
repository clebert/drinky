//! The Telegram Bot API client: one HTTPS POST with a JSON body per call, and
//! the reply classified by its status. The client knows the four methods that
//! the transport needs and nothing of the session.
//!
//! The URL of every call carries the token, so no error, event, or log names a
//! URL. A failure reads as one of the `Error` names, and the description that
//! Telegram sent stays in `description` for the event that reports it.

const std = @import("std");

const ai = @import("ai");

const Client = @This();

/// The public API host. A test points `base_url` at a loopback server instead.
pub const api_url = "https://api.telegram.org";

/// The hard cap on one reply body. A `getUpdates` reply holds at most 100
/// updates, each under a few kilobytes, so the cap clears any real reply and
/// still bounds a body that never ends.
const response_bytes_max = 4 << 20;

/// The margin between the poll timeout and the head window, so the reply head
/// of an empty poll arrives inside the window.
const poll_margin_ms = 5_000;

/// The least head window of a long poll. The configured window bounds the head
/// of one provider request, and a long poll holds the connection open on
/// purpose, so a short configured window must not shorten the poll. A poll under
/// this floor returns at once and asks again every second, and Telegram answers
/// that with a 429. A zero configured window disables the bound, and the poll
/// still needs a finite wait, so it takes this window too.
pub const poll_connect_ms_min = 30_000;

gpa: std.mem.Allocator,
io: std.Io,
/// The API origin, without a trailing slash. Borrowed.
base_url: []const u8,
/// The bot token. Borrowed, and never part of any text this client produces.
token: []const u8,
/// The head window of one call, in milliseconds. It bounds the whole call, body
/// included, because every reply is small. Zero disables the bound.
connect_ms: u64,
/// The wait that the last `error.RateLimited` named, in seconds.
retry_after_s: u64 = 0,
/// The description of the last failure that Telegram described, cut to the
/// buffer. Empty after a failure without a description.
description_buffer: [200]u8 = undefined,
description_length: usize = 0,

pub const Error = error{
    /// 401: Telegram no longer knows the token.
    Unauthorized,
    /// 403: the user blocked the bot.
    Forbidden,
    /// 409: another client polls the same bot, or a webhook is active.
    Conflict,
    /// 429: `retry_after_s` names the wait.
    RateLimited,
    /// Any other 4xx: a repeat of the same request cannot succeed.
    Rejected,
    /// A 5xx, a network fault, or a timeout: a repeat can succeed.
    Unavailable,
    /// A 200 whose body is not the reply of the method.
    MalformedReply,
    OutOfMemory,
    Canceled,
};

/// The bot that a token names.
pub const Me = struct {
    id: i64,
    /// Owned by the caller.
    username: []u8,

    pub fn deinit(self: *const Me, gpa: std.mem.Allocator) void {
        gpa.free(self.username);
    }
};

/// One update of a poll. Only a message update carries a payload, because the
/// poll asks for messages alone.
pub const Update = struct {
    update_id: i64,
    message: ?Message,

    pub const Message = struct {
        message_id: i64,
        chat_id: i64,
        /// Whether the chat is a private chat with one user.
        chat_private: bool,
        /// The text, or null for a photo, a sticker, a voice note, or any other
        /// content. Owned by the list.
        text: ?[]u8,
    };
};

/// The updates of one poll, in the order Telegram sent them. The list owns
/// every text.
pub const Updates = struct {
    items: []Update,

    pub fn deinit(self: *const Updates, gpa: std.mem.Allocator) void {
        for (self.items) |update| {
            const message = update.message orelse continue;
            if (message.text) |text| gpa.free(text);
        }
        gpa.free(self.items);
    }
};

pub const SendOptions = struct {
    /// The message that the new one answers, or null for a plain message.
    reply_to: ?i64 = null,
    /// Whether the chat stays silent for this message.
    disable_notification: bool = false,
    /// `HTML` for a formatted text, or null for plain text.
    parse_mode: ?[]const u8 = null,
};

/// One reply body under its own arena.
const Reply = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *const Reply) void {
        self.parsed.deinit();
    }

    /// The `result` field of the reply.
    fn result(self: *const Reply) Error!std.json.Value {
        const object = switch (self.parsed.value) {
            .object => |object| object,
            else => return error.MalformedReply,
        };
        return object.get("result") orelse error.MalformedReply;
    }
};

/// The head window a long poll runs under, for a configured window of
/// `connect_ms`. A client that polls takes this window, and one that sends
/// keeps the configured one.
pub fn pollConnectMs(connect_ms: u64) u64 {
    return @max(connect_ms, poll_connect_ms_min);
}

/// The Telegram `timeout` parameter of a long poll for a head window of
/// `connect_ms`: five seconds under the window, with a floor of one second.
/// The caller passes a `pollConnectMs` window, so the floor only guards a
/// window that no poller uses.
pub fn pollTimeoutSeconds(connect_ms: u64) u64 {
    return @max(1, @divFloor(connect_ms -| poll_margin_ms, std.time.ms_per_s));
}

/// Whether `token` has the shape of a bot token: digits, a colon, and the
/// letters, digits, `_`, and `-` of the secret. Every byte outside that set
/// breaks the URL path that carries the token, so the check refuses it first.
pub fn validToken(token: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, token, ':') orelse return false;
    if (colon == 0 or colon + 1 == token.len) return false;
    for (token[0..colon]) |byte| if (!std.ascii.isDigit(byte)) return false;
    for (token[colon + 1 ..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

/// The description of the last failure, or empty when Telegram sent none.
pub fn description(self: *const Client) []const u8 {
    return self.description_buffer[0..self.description_length];
}

/// Prove the token and name the bot. The caller frees the result.
pub fn getMe(self: *Client) Error!Me {
    const reply = try self.call("getMe", "{}");
    defer reply.deinit();
    const result = objectOf(try reply.result()) orelse return error.MalformedReply;
    const id = integerOf(result.get("id")) orelse return error.MalformedReply;
    const username = stringOf(result.get("username")) orelse return error.MalformedReply;
    return .{ .id = id, .username = try self.gpa.dupe(u8, username) };
}

/// Remove an active webhook, because one blocks every poll.
pub fn deleteWebhook(self: *Client) Error!void {
    const reply = try self.call("deleteWebhook", "{}");
    defer reply.deinit();
    _ = try reply.result();
}

/// Poll for message updates from `offset` on, and wait at most `timeout_s` for
/// one. An `offset` of -1 confirms every waiting update and returns the newest
/// one alone. The caller frees the result.
pub fn getUpdates(self: *Client, offset: ?i64, timeout_s: u64) Error!Updates {
    const body = try std.json.Stringify.valueAlloc(self.gpa, .{
        .offset = offset,
        .timeout = timeout_s,
        .allowed_updates = [_][]const u8{"message"},
    }, .{ .emit_null_optional_fields = false });
    defer self.gpa.free(body);
    const reply = try self.call("getUpdates", body);
    defer reply.deinit();
    const list = switch (try reply.result()) {
        .array => |array| array,
        else => return error.MalformedReply,
    };
    var updates: std.ArrayList(Update) = .empty;
    errdefer {
        for (updates.items) |update| {
            const message = update.message orelse continue;
            if (message.text) |text| self.gpa.free(text);
        }
        updates.deinit(self.gpa);
    }
    try updates.ensureTotalCapacity(self.gpa, list.items.len);
    for (list.items) |value| {
        const update = objectOf(value) orelse return error.MalformedReply;
        const update_id = integerOf(update.get("update_id")) orelse return error.MalformedReply;
        var message: ?Update.Message = null;
        if (objectOf(update.get("message"))) |object| {
            const chat = objectOf(object.get("chat")) orelse return error.MalformedReply;
            const maybe_text = stringOf(object.get("text"));
            message = .{
                .message_id = integerOf(object.get("message_id")) orelse
                    return error.MalformedReply,
                .chat_id = integerOf(chat.get("id")) orelse return error.MalformedReply,
                .chat_private = if (stringOf(chat.get("type"))) |kind|
                    std.mem.eql(u8, kind, "private")
                else
                    false,
                .text = if (maybe_text) |text| try self.gpa.dupe(u8, text) else null,
            };
        }
        updates.appendAssumeCapacity(.{ .update_id = update_id, .message = message });
    }
    return .{ .items = try updates.toOwnedSlice(self.gpa) };
}

/// Send `text` to `chat_id` and return the id of the new message.
pub fn sendMessage(
    self: *Client,
    chat_id: i64,
    text: []const u8,
    options: *const SendOptions,
) Error!i64 {
    const ReplyParameters = struct { message_id: i64 };
    const body = try std.json.Stringify.valueAlloc(self.gpa, .{
        .chat_id = chat_id,
        .text = text,
        .disable_notification = options.disable_notification,
        .parse_mode = options.parse_mode,
        .reply_parameters = if (options.reply_to) |message_id|
            @as(?ReplyParameters, .{ .message_id = message_id })
        else
            null,
    }, .{ .emit_null_optional_fields = false });
    defer self.gpa.free(body);
    const reply = try self.call("sendMessage", body);
    defer reply.deinit();
    const result = objectOf(try reply.result()) orelse return error.MalformedReply;
    return integerOf(result.get("message_id")) orelse error.MalformedReply;
}

/// One POST of `body` to `method`, bounded by the head window. The reply parses
/// under its own arena, and the caller frees it.
fn call(self: *Client, method: []const u8, body: []const u8) Error!Reply {
    const url = try std.fmt.allocPrint(
        self.gpa,
        "{s}/bot{s}/{s}",
        .{ self.base_url, self.token, method },
    );
    defer self.gpa.free(url);
    var out: ?Response = null;
    ai.net.withTimeout(
        self.io,
        self.connect_ms,
        post,
        .{ self.gpa, self.io, url, body, &out },
    ) catch |err| {
        // The race can discard a response that arrived at the deadline.
        if (out) |response| self.gpa.free(response.body);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.Unavailable,
        };
    };
    const response = out orelse return error.Unavailable;
    defer self.gpa.free(response.body);
    return self.classify(&response);
}

/// The status and the body of one reply.
const Response = struct {
    status: std.http.Status,
    body: []u8,
};

fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    out: *?Response,
) !void {
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var request = try client.request(.POST, uri, .{
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    var send_body = try request.sendBodyUnflushed(&.{});
    try send_body.writer.writeAll(body);
    try send_body.end();
    try request.connection.?.flush();

    var redirect_buffer: [2048]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    const decompress_buffer = try ai.net.decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const bytes = try reader.allocRemaining(gpa, .limited(response_bytes_max));
    out.* = .{ .status = response.head.status, .body = bytes };
}

/// Read the status and the body of one reply. A failure keeps its description,
/// and a 429 keeps its wait.
fn classify(self: *Client, response: *const Response) Error!Reply {
    const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, response.body, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    if (response.status == .ok) {
        const reply: Reply = .{ .parsed = parsed orelse return error.MalformedReply };
        errdefer reply.deinit();
        const object = objectOf(reply.parsed.value) orelse return error.MalformedReply;
        const ok = switch (object.get("ok") orelse return error.MalformedReply) {
            .bool => |value| value,
            else => return error.MalformedReply,
        };
        if (!ok) return error.MalformedReply;
        return reply;
    }
    defer if (parsed) |value| value.deinit();
    self.keepDescription(parsed);
    return switch (response.status) {
        .unauthorized => error.Unauthorized,
        .forbidden => error.Forbidden,
        .conflict => error.Conflict,
        .too_many_requests => {
            self.retry_after_s = retryAfter(parsed) orelse 1;
            return error.RateLimited;
        },
        else => if (response.status.class() == .client_error)
            error.Rejected
        else
            error.Unavailable,
    };
}

/// Keep the `description` of a failed reply, or clear it for a reply without one.
/// The cut to the buffer falls before a UTF-8 sequence, never inside one, so the
/// event that reports the description stays valid text.
fn keepDescription(self: *Client, parsed: ?std.json.Parsed(std.json.Value)) void {
    self.description_length = 0;
    const reply = parsed orelse return;
    const object = objectOf(reply.value) orelse return;
    const text = stringOf(object.get("description")) orelse return;
    var length = @min(text.len, self.description_buffer.len);
    // A continuation byte reads `10xxxxxx`, and a sequence holds at most three.
    while (length > 0 and length < text.len and (text[length] & 0xC0) == 0x80) length -= 1;
    @memcpy(self.description_buffer[0..length], text[0..length]);
    self.description_length = length;
}

/// The `parameters.retry_after` of a 429 reply, in seconds.
fn retryAfter(parsed: ?std.json.Parsed(std.json.Value)) ?u64 {
    const reply = parsed orelse return null;
    const object = objectOf(reply.value) orelse return null;
    const parameters = objectOf(object.get("parameters")) orelse return null;
    const seconds = integerOf(parameters.get("retry_after")) orelse return null;
    if (seconds < 0) return null;
    return @intCast(seconds);
}

fn objectOf(maybe_value: ?std.json.Value) ?std.json.ObjectMap {
    return switch (maybe_value orelse return null) {
        .object => |object| object,
        else => null,
    };
}

fn integerOf(maybe_value: ?std.json.Value) ?i64 {
    return switch (maybe_value orelse return null) {
        .integer => |value| value,
        else => null,
    };
}

fn stringOf(maybe_value: ?std.json.Value) ?[]const u8 {
    return switch (maybe_value orelse return null) {
        .string => |value| value,
        else => null,
    };
}

const testing = @import("testing.zig");

test validToken {
    try std.testing.expect(validToken("123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"));
    try std.testing.expect(validToken("1:a_b-C"));
    try std.testing.expect(!validToken(""));
    try std.testing.expect(!validToken("123456789"));
    try std.testing.expect(!validToken(":secret"));
    try std.testing.expect(!validToken("123:"));
    try std.testing.expect(!validToken("12a:secret"));
    try std.testing.expect(!validToken("123:sec ret"));
    try std.testing.expect(!validToken("123:sec/ret"));
    try std.testing.expect(!validToken("123:sec\nret"));
}

test pollTimeoutSeconds {
    try std.testing.expectEqual(@as(u64, 25), pollTimeoutSeconds(30_000));
    try std.testing.expectEqual(@as(u64, 55), pollTimeoutSeconds(60_500));
    // No poller passes a window under the floor. The timeout stays positive
    // there too, so a direct caller gets a wait and never a zero.
    try std.testing.expectEqual(@as(u64, 1), pollTimeoutSeconds(5_000));
    try std.testing.expectEqual(@as(u64, 1), pollTimeoutSeconds(0));
}

// A short configured window must not turn the long poll into a busy poll, so
// the poll takes the floor and the timeout stays a real wait.
test pollConnectMs {
    try std.testing.expectEqual(@as(u64, 30_000), pollConnectMs(5_000));
    try std.testing.expectEqual(@as(u64, 30_000), pollConnectMs(0));
    try std.testing.expectEqual(@as(u64, 60_000), pollConnectMs(60_000));
    try std.testing.expectEqual(@as(u64, 25), pollTimeoutSeconds(pollConnectMs(5_000)));
}

test "getMe names the bot, and the request carries the token in the path alone" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "getMe", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":{\"id\":42,\"is_bot\":true,\"username\":\"drinky_bot\"}}" },
    } }});
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .base_url = server.url(&url_buffer),
        .token = "42:secret",
        .connect_ms = 5_000,
    };

    const me = try client.getMe();
    defer me.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 42), me.id);
    try std.testing.expectEqualStrings("drinky_bot", me.username);
    try server.finish();
    try std.testing.expectEqualStrings("/bot42:secret/getMe", server.requests.items[0].path);
    try std.testing.expectEqualStrings("{}", server.requests.items[0].body);
}

test "getUpdates reads a text message, a non-text message, and the chat type" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "getUpdates", .replies = &.{
        .{ .body =
        \\{"ok":true,"result":[
        \\{"update_id":7,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"hello"}},
        \\{"update_id":8,"message":{"message_id":2,"date":0,"chat":{"id":99,"type":"private"},"sticker":{}}},
        \\{"update_id":9,"message":{"message_id":3,"date":0,"chat":{"id":-5,"type":"group"},"text":"hi"}},
        \\{"update_id":10,"edited_message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"hello!"}}
        \\]}
        },
    } }});
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .base_url = server.url(&url_buffer),
        .token = "t",
        .connect_ms = 5_000,
    };

    const updates = try client.getUpdates(7, 25);
    defer updates.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), updates.items.len);
    try std.testing.expectEqual(@as(i64, 7), updates.items[0].update_id);
    try std.testing.expectEqualStrings("hello", updates.items[0].message.?.text.?);
    try std.testing.expect(updates.items[0].message.?.chat_private);
    try std.testing.expectEqual(@as(i64, 99), updates.items[0].message.?.chat_id);
    try std.testing.expect(updates.items[1].message.?.text == null);
    try std.testing.expect(!updates.items[2].message.?.chat_private);
    // An edit is no message, so the update carries no payload.
    try std.testing.expect(updates.items[3].message == null);
    try server.finish();
    try std.testing.expectEqualStrings(
        "{\"offset\":7,\"timeout\":25,\"allowed_updates\":[\"message\"]}",
        server.requests.items[0].body,
    );
}

// A later update that lacks its id fails the whole poll. The texts of the updates
// before it are owned by then, and the leak check of the test allocator proves
// that the failure frees each one and the list.
test "a malformed later update fails the poll without a leak" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "getUpdates", .replies = &.{
        .{ .body =
        \\{"ok":true,"result":[
        \\{"update_id":7,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"kept"}},
        \\{"update_id":8,"message":{"message_id":2,"date":0,"chat":{"id":99,"type":"private"},"text":"kept too"}},
        \\{"message":{"message_id":3,"date":0,"chat":{"id":99,"type":"private"},"text":"no id"}}
        \\]}
        },
    } }});
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .base_url = server.url(&url_buffer),
        .token = "t",
        .connect_ms = 5_000,
    };

    try std.testing.expectError(error.MalformedReply, client.getUpdates(null, 1));
    try server.finish();
}

test "sendMessage returns the message id and states its options" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "sendMessage", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
        .{ .body = "{\"ok\":true,\"result\":{\"message_id\":315}}" },
    } }});
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .base_url = server.url(&url_buffer),
        .token = "t",
        .connect_ms = 5_000,
    };

    try std.testing.expectEqual(@as(i64, 314), try client.sendMessage(99, "Event: hi", &.{}));
    try std.testing.expectEqual(@as(i64, 315), try client.sendMessage(99, "<b>x</b>", &.{
        .reply_to = 12,
        .disable_notification = true,
        .parse_mode = "HTML",
    }));
    try server.finish();
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"Event: hi\",\"disable_notification\":false}",
        server.requests.items[0].body,
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"<b>x</b>\",\"disable_notification\":true," ++
            "\"parse_mode\":\"HTML\",\"reply_parameters\":{\"message_id\":12}}",
        server.requests.items[1].body,
    );
}

test "every status classifies, and a failure keeps its description and its wait" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "deleteWebhook", .replies = &.{
        .{ .status = 401, .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}" },
        .{ .status = 403, .body = "{\"ok\":false,\"error_code\":403,\"description\":\"Forbidden: bot was blocked by the user\"}" },
        .{ .status = 409, .body = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict: terminated by other getUpdates request\"}" },
        .{ .status = 429, .body = "{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests: retry after 7\",\"parameters\":{\"retry_after\":7}}" },
        .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: can't parse entities\"}" },
        .{ .status = 502, .body = "<html>bad gateway</html>" },
        .{ .status = 200, .body = "{\"ok\":true}" },
        .{ .status = 200, .body = "not json" },
    } }});
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .base_url = server.url(&url_buffer),
        .token = "t",
        .connect_ms = 5_000,
    };

    try std.testing.expectError(error.Unauthorized, client.deleteWebhook());
    try std.testing.expectEqualStrings("Unauthorized", client.description());
    try std.testing.expectError(error.Forbidden, client.deleteWebhook());
    try std.testing.expectEqualStrings("Forbidden: bot was blocked by the user", client.description());
    try std.testing.expectError(error.Conflict, client.deleteWebhook());
    try std.testing.expectError(error.RateLimited, client.deleteWebhook());
    try std.testing.expectEqual(@as(u64, 7), client.retry_after_s);
    try std.testing.expectError(error.Rejected, client.deleteWebhook());
    try std.testing.expectEqualStrings("Bad Request: can't parse entities", client.description());
    try std.testing.expectError(error.Unavailable, client.deleteWebhook());
    // A body without a description clears the last one.
    try std.testing.expectEqualStrings("", client.description());
    try std.testing.expectError(error.MalformedReply, client.deleteWebhook());
    try std.testing.expectError(error.MalformedReply, client.deleteWebhook());
    try server.finish();
}

// The description buffer is smaller than a description can be. The cut must not
// leave half a UTF-8 sequence behind, because the text reaches an event.
test "a long description cuts before a UTF-8 sequence" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // 198 ASCII bytes, then a three-byte symbol that straddles the 200-byte cut.
    const body = "{\"ok\":false,\"error_code\":400,\"description\":\"" ++ "x" ** 198 ++ "€€\"}";
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "deleteWebhook", .replies = &.{
        .{ .status = 400, .body = body },
    } }});
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .base_url = server.url(&url_buffer),
        .token = "t",
        .connect_ms = 5_000,
    };

    try std.testing.expectError(error.Rejected, client.deleteWebhook());
    try std.testing.expectEqual(@as(usize, 198), client.description().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(client.description()));
    try server.finish();
}

test "a server that does not answer is unavailable, not a hang" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{});
    defer server.deinit();
    try server.start();
    var url_buffer: [64]u8 = undefined;
    var client: Client = .{
        .gpa = gpa,
        .io = io,
        .base_url = server.url(&url_buffer),
        .token = "t",
        .connect_ms = 50,
    };
    // No script answers, so the call waits for its head until the window closes.
    try std.testing.expectError(error.Unavailable, client.getMe());
    try server.finish();
}
