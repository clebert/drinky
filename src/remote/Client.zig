const std = @import("std");

const ai = @import("ai");

const Client = @This();

pub const api_url = "https://api.telegram.org";

const response_bytes_max = 4 << 20;

const poll_margin_ms = 5_000;

pub const poll_connect_ms_min = 30_000;

gpa: std.mem.Allocator,
io: std.Io,
base_url: []const u8,
token: []const u8,
connect_ms: u64,
retry_after_s: u64 = 0,
description_buffer: [200]u8 = undefined,
description_length: usize = 0,

pub const Error = error{
    Unauthorized,
    Forbidden,
    Conflict,
    RateLimited,
    Rejected,
    Unavailable,
    MalformedReply,
    OutOfMemory,
    Canceled,
};

pub const Me = struct {
    id: i64,
    username: []u8,

    pub fn deinit(self: *const Me, gpa: std.mem.Allocator) void {
        gpa.free(self.username);
    }
};

pub const Update = struct {
    update_id: i64,
    message: ?Message,
    callback: ?Callback,

    pub const Message = struct {
        message_id: i64,
        chat_id: i64,
        chat_private: bool,
        text: ?[]u8,
    };

    pub const Callback = struct {
        id: []u8,
        message_id: i64,
        chat_id: i64,
        data: []u8,
    };
};

pub const Updates = struct {
    items: []Update,

    pub fn deinit(self: *const Updates, gpa: std.mem.Allocator) void {
        for (self.items) |update| freeUpdate(gpa, &update);
        gpa.free(self.items);
    }
};

fn freeUpdate(gpa: std.mem.Allocator, update: *const Update) void {
    if (update.message) |message| {
        if (message.text) |text| gpa.free(text);
    }
    if (update.callback) |callback| {
        gpa.free(callback.id);
        gpa.free(callback.data);
    }
}

pub const SendOptions = struct {
    reply_to: ?i64 = null,
    disable_notification: bool = false,
    parse_mode: ?[]const u8 = null,
    markup: ?[]const u8 = null,
};

pub const EditOptions = struct {
    parse_mode: ?[]const u8 = null,
    markup: ?[]const u8 = null,
};

pub const Target = struct {
    chat_id: i64,
    message_id: i64,
};

pub const Command = struct {
    command: []const u8,
    description: []const u8,
};

const Raw = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: Raw, jws: anytype) !void {
        try jws.print("{s}", .{self.bytes});
    }
};

fn raw(maybe_bytes: ?[]const u8) ?Raw {
    return .{ .bytes = maybe_bytes orelse return null };
}

const Reply = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *const Reply) void {
        self.parsed.deinit();
    }

    fn result(self: *const Reply) Error!std.json.Value {
        const object = switch (self.parsed.value) {
            .object => |object| object,
            else => return error.MalformedReply,
        };
        return object.get("result") orelse error.MalformedReply;
    }
};

pub fn pollConnectMs(connect_ms: u64) u64 {
    return @max(connect_ms, poll_connect_ms_min);
}

pub fn pollTimeoutSeconds(connect_ms: u64) u64 {
    return @max(1, @divFloor(connect_ms -| poll_margin_ms, std.time.ms_per_s));
}

pub fn validToken(token: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, token, ':') orelse return false;
    if (colon == 0 or colon + 1 == token.len) return false;
    for (token[0..colon]) |byte| if (!std.ascii.isDigit(byte)) return false;
    for (token[colon + 1 ..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

pub fn description(self: *const Client) []const u8 {
    return self.description_buffer[0..self.description_length];
}

pub fn getMe(self: *Client) Error!Me {
    const reply = try self.call("getMe", "{}");
    defer reply.deinit();
    const result = objectOf(try reply.result()) orelse return error.MalformedReply;
    const id = integerOf(result.get("id")) orelse return error.MalformedReply;
    const username = stringOf(result.get("username")) orelse return error.MalformedReply;
    return .{ .id = id, .username = try self.gpa.dupe(u8, username) };
}

pub fn deleteWebhook(self: *Client) Error!void {
    const reply = try self.call("deleteWebhook", "{}");
    defer reply.deinit();
    _ = try reply.result();
}

pub fn getUpdates(self: *Client, offset: ?i64, timeout_s: u64) Error!Updates {
    const body = try std.json.Stringify.valueAlloc(self.gpa, .{
        .offset = offset,
        .timeout = timeout_s,
        .allowed_updates = [_][]const u8{ "message", "callback_query" },
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
        for (updates.items) |*update| freeUpdate(self.gpa, update);
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
        errdefer if (message) |found| if (found.text) |text| self.gpa.free(text);
        var callback: ?Update.Callback = null;
        if (objectOf(update.get("callback_query"))) |object| callback = try self.parseCallback(object);
        updates.appendAssumeCapacity(.{
            .update_id = update_id,
            .message = message,
            .callback = callback,
        });
    }
    return .{ .items = try updates.toOwnedSlice(self.gpa) };
}

fn parseCallback(self: *Client, object: std.json.ObjectMap) Error!?Update.Callback {
    const id = stringOf(object.get("id")) orelse return error.MalformedReply;
    const message = objectOf(object.get("message")) orelse return null;
    const data = stringOf(object.get("data")) orelse return null;
    const chat = objectOf(message.get("chat")) orelse return error.MalformedReply;
    const id_copy = try self.gpa.dupe(u8, id);
    errdefer self.gpa.free(id_copy);
    return .{
        .id = id_copy,
        .message_id = integerOf(message.get("message_id")) orelse return error.MalformedReply,
        .chat_id = integerOf(chat.get("id")) orelse return error.MalformedReply,
        .data = try self.gpa.dupe(u8, data),
    };
}

pub fn setMyCommands(self: *Client, commands: []const Command) Error!void {
    const body = try std.json.Stringify.valueAlloc(self.gpa, .{ .commands = commands }, .{});
    defer self.gpa.free(body);
    const reply = try self.call("setMyCommands", body);
    defer reply.deinit();
    _ = try reply.result();
}

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
        .reply_markup = raw(options.markup),
    }, .{ .emit_null_optional_fields = false });
    defer self.gpa.free(body);
    const reply = try self.call("sendMessage", body);
    defer reply.deinit();
    const result = objectOf(try reply.result()) orelse return error.MalformedReply;
    return integerOf(result.get("message_id")) orelse error.MalformedReply;
}

pub fn editMessageText(
    self: *Client,
    target: Target,
    text: []const u8,
    options: *const EditOptions,
) Error!void {
    const body = try std.json.Stringify.valueAlloc(self.gpa, .{
        .chat_id = target.chat_id,
        .message_id = target.message_id,
        .text = text,
        .parse_mode = options.parse_mode,
        .reply_markup = raw(options.markup),
    }, .{ .emit_null_optional_fields = false });
    defer self.gpa.free(body);
    const reply = self.call("editMessageText", body) catch |err| switch (err) {
        error.Rejected => {
            if (std.mem.indexOf(u8, self.description(), "message is not modified") != null) return;
            return err;
        },
        else => return err,
    };
    defer reply.deinit();
    _ = try reply.result();
}

pub fn deleteMessage(self: *Client, target: Target) Error!void {
    const body = try std.json.Stringify.valueAlloc(
        self.gpa,
        .{ .chat_id = target.chat_id, .message_id = target.message_id },
        .{},
    );
    defer self.gpa.free(body);
    const reply = try self.call("deleteMessage", body);
    defer reply.deinit();
    _ = try reply.result();
}

pub fn answerCallbackQuery(self: *Client, query_id: []const u8) Error!void {
    const body = try std.json.Stringify.valueAlloc(
        self.gpa,
        .{ .callback_query_id = query_id },
        .{},
    );
    defer self.gpa.free(body);
    const reply = try self.call("answerCallbackQuery", body);
    defer reply.deinit();
    _ = try reply.result();
}

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

fn keepDescription(self: *Client, parsed: ?std.json.Parsed(std.json.Value)) void {
    self.description_length = 0;
    const reply = parsed orelse return;
    const object = objectOf(reply.value) orelse return;
    const text = stringOf(object.get("description")) orelse return;
    var length = @min(text.len, self.description_buffer.len);
    while (length > 0 and length < text.len and (text[length] & 0xC0) == 0x80) length -= 1;
    @memcpy(self.description_buffer[0..length], text[0..length]);
    self.description_length = length;
}

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
    try std.testing.expectEqual(@as(u64, 1), pollTimeoutSeconds(5_000));
    try std.testing.expectEqual(@as(u64, 1), pollTimeoutSeconds(0));
}

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

test "getUpdates reads a text message, a non-text message, a tap, and the chat type" {
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
        \\{"update_id":10,"edited_message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},"text":"hello!"}},
        \\{"update_id":11,"callback_query":{"id":"4407","from":{"id":5},"chat_instance":"c","message":{"message_id":50,"date":0,"chat":{"id":99,"type":"private"},"text":"Thinking"},"data":"cancel:3"}},
        \\{"update_id":12,"callback_query":{"id":"4408","from":{"id":5},"chat_instance":"c","inline_message_id":"i"}}
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
    try std.testing.expectEqual(@as(usize, 6), updates.items.len);
    try std.testing.expectEqual(@as(i64, 7), updates.items[0].update_id);
    try std.testing.expectEqualStrings("hello", updates.items[0].message.?.text.?);
    try std.testing.expect(updates.items[0].message.?.chat_private);
    try std.testing.expectEqual(@as(i64, 99), updates.items[0].message.?.chat_id);
    try std.testing.expect(updates.items[0].callback == null);
    try std.testing.expect(updates.items[1].message.?.text == null);
    try std.testing.expect(!updates.items[2].message.?.chat_private);
    try std.testing.expect(updates.items[3].message == null);
    try std.testing.expect(updates.items[3].callback == null);
    const tap = updates.items[4].callback.?;
    try std.testing.expectEqualStrings("4407", tap.id);
    try std.testing.expectEqual(@as(i64, 50), tap.message_id);
    try std.testing.expectEqual(@as(i64, 99), tap.chat_id);
    try std.testing.expectEqualStrings("cancel:3", tap.data);
    try std.testing.expect(updates.items[4].message == null);
    try std.testing.expect(updates.items[5].callback == null);
    try server.finish();
    try std.testing.expectEqualStrings(
        "{\"offset\":7,\"timeout\":25,\"allowed_updates\":[\"message\",\"callback_query\"]}",
        server.requests.items[0].body,
    );
}

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
        .markup = "{\"inline_keyboard\":[[{\"text\":\"Cancel\",\"callback_data\":\"close:1\"}]]}",
    }));
    try server.finish();
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"Event: hi\",\"disable_notification\":false}",
        server.requests.items[0].body,
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"<b>x</b>\",\"disable_notification\":true," ++
            "\"parse_mode\":\"HTML\",\"reply_parameters\":{\"message_id\":12}," ++
            "\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"Cancel\",\"callback_data\":\"close:1\"}]]}}",
        server.requests.items[1].body,
    );
}

test "editMessageText states its target and keyboard, and an unchanged text counts as success" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "editMessageText", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
        .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
        .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: message is not modified\"}" },
        .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: message to edit not found\"}" },
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

    const target: Target = .{ .chat_id = 99, .message_id = 314 };
    try client.editMessageText(target, "Writing", &.{});
    try client.editMessageText(target, "<b>Writing</b>", &.{
        .parse_mode = "HTML",
        .markup = "{\"inline_keyboard\":[]}",
    });
    try client.editMessageText(target, "Writing", &.{});
    try std.testing.expectError(
        error.Rejected,
        client.editMessageText(.{ .chat_id = 99, .message_id = 315 }, "Writing", &.{}),
    );
    try server.finish();
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Writing\"}",
        server.requests.items[0].body,
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"<b>Writing</b>\",\"parse_mode\":\"HTML\"," ++
            "\"reply_markup\":{\"inline_keyboard\":[]}}",
        server.requests.items[1].body,
    );
}

test "deleteMessage names the message it takes out of the chat" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "deleteMessage", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":true}" },
        .{ .status = 400, .body = "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: message to delete not found\"}" },
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

    try client.deleteMessage(.{ .chat_id = 99, .message_id = 314 });
    try std.testing.expectError(
        error.Rejected,
        client.deleteMessage(.{ .chat_id = 99, .message_id = 315 }),
    );
    try server.finish();
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314}",
        server.requests.items[0].body,
    );
}

test "answerCallbackQuery names the query alone" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "answerCallbackQuery", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":true}" },
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

    try client.answerCallbackQuery("4407");
    try server.finish();
    try std.testing.expectEqualStrings("{\"callback_query_id\":\"4407\"}", server.requests.items[0].body);
}

test "setMyCommands registers each command with its description" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testing.Server.init(gpa, io, &.{.{ .method = "setMyCommands", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":true}" },
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

    try client.setMyCommands(&.{
        .{ .command = "effort", .description = "set the reasoning-effort level" },
        .{ .command = "new", .description = "start a new conversation" },
    });
    try server.finish();
    try std.testing.expectEqualStrings(
        "{\"commands\":[{\"command\":\"effort\",\"description\":\"set the reasoning-effort level\"}," ++
            "{\"command\":\"new\",\"description\":\"start a new conversation\"}]}",
        server.requests.items[0].body,
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
    try std.testing.expectEqualStrings("", client.description());
    try std.testing.expectError(error.MalformedReply, client.deleteWebhook());
    try std.testing.expectError(error.MalformedReply, client.deleteWebhook());
    try server.finish();
}

test "a long description cuts before a UTF-8 sequence" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
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
    try std.testing.expectError(error.Unavailable, client.getMe());
    try server.finish();
}
