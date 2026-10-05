const std = @import("std");

const core = @import("core");
const providers = @import("providers");
const tools = @import("tools");

const Client = @This();

const api_url = "https://api.telegram.org";

const response_bytes_max = 4 << 20;

const poll_margin_ms = 5_000;

pub const poll_connect_ms_min = 30_000;

gpa: std.mem.Allocator,
io: std.Io,
transport: ?providers.Transport,
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

pub const Class = union(enum) {
    canceled,
    permanent: Permanent,
    rate_limited,
    rejected,
    transient,

    pub const Permanent = enum { unauthorized, forbidden, conflict };

    pub fn of(err: Error) Class {
        return switch (err) {
            error.Canceled => .canceled,
            error.Unauthorized => .{ .permanent = .unauthorized },
            error.Forbidden => .{ .permanent = .forbidden },
            error.Conflict => .{ .permanent = .conflict },
            error.RateLimited => .rate_limited,
            error.Rejected => .rejected,
            error.Unavailable, error.MalformedReply, error.OutOfMemory => .transient,
        };
    }
};

pub const Me = struct {
    id: i64,
    username: []u8,

    pub fn deinit(self: *const Me, gpa: std.mem.Allocator) void {
        gpa.free(self.username);
    }
};

const Update = struct {
    update_id: i64,
    message: ?Message,
    callback: ?Callback,

    const Message = struct {
        message_id: i64,
        chat_id: i64,
        chat_private: bool,
        text: ?[]u8,
    };

    const Callback = struct {
        id: []u8,
        message_id: i64,
        chat_id: i64,
        data: []u8,
    };
};

const Updates = struct {
    items: []Update,

    const empty: Updates = .{ .items = &.{} };

    pub fn deinit(self: *const Updates, gpa: std.mem.Allocator) void {
        for (self.items) |update| freeUpdate(gpa, &update);
        gpa.free(self.items);
    }
};

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

const Target = struct {
    chat_id: i64,
    message_id: i64,
};

pub const Command = struct {
    command: []const u8,
    description: []const u8,
};

pub const Poll = struct {
    commands: ?[]const Command,
    step: Step = .webhook,
    offset: ?i64 = null,

    const Step = enum { webhook, commands, confirmation, updates };

    pub fn next(self: *Poll, client: *Client, timeout_s: u64) Error!Updates {
        switch (self.step) {
            .webhook => {
                try client.deleteWebhook();
                self.step = if (self.commands == null) .confirmation else .commands;
                return .empty;
            },
            .commands => {
                try client.setMyCommands(self.commands.?);
                self.step = .confirmation;
                return .empty;
            },
            .confirmation => {
                const newest = try client.getUpdates(-1, 0);
                defer newest.deinit(client.gpa);
                self.advance(&newest);
                self.step = .updates;
                return .empty;
            },
            .updates => {
                const updates = try client.getUpdates(self.offset, timeout_s);
                self.advance(&updates);
                return updates;
            },
        }
    }

    fn advance(self: *Poll, updates: *const Updates) void {
        if (updates.items.len == 0) return;
        self.offset = updates.items[updates.items.len - 1].update_id + 1;
    }
};

const Reply = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *const Reply) void {
        self.parsed.deinit();
    }

    fn result(self: *const Reply) Error!*const std.json.Value {
        const object = providers.json.object(&self.parsed.value) orelse return error.MalformedReply;
        return object.getPtr("result") orelse error.MalformedReply;
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

fn raw(maybe_bytes: ?[]const u8) ?providers.json.Raw {
    return .{ .bytes = maybe_bytes orelse return null };
}

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

pub fn retryAfterMs(self: *const Client, delay_ms_max: u64) u64 {
    return @min(self.retry_after_s *| std.time.ms_per_s, delay_ms_max);
}

pub fn getMe(self: *Client) Error!Me {
    const reply = try self.call(&.{ .method = "getMe", .body = "{}" });
    defer reply.deinit();
    const result = providers.json.object(try reply.result()) orelse return error.MalformedReply;
    const id = providers.json.integer(result.getPtr("id")) orelse return error.MalformedReply;
    const username = providers.json.string(result.getPtr("username")) orelse
        return error.MalformedReply;
    return .{ .id = id, .username = try self.gpa.dupe(u8, username) };
}

fn deleteWebhook(self: *Client) Error!void {
    const reply = try self.call(&.{ .method = "deleteWebhook", .body = "{}" });
    defer reply.deinit();
    _ = try reply.result();
}

fn getUpdates(self: *Client, offset: ?i64, timeout_s: u64) Error!Updates {
    const body = try std.json.Stringify.valueAlloc(self.gpa, .{
        .offset = offset,
        .timeout = timeout_s,
        .allowed_updates = [_][]const u8{ "message", "callback_query" },
    }, .{ .emit_null_optional_fields = false });
    defer self.gpa.free(body);
    const reply = try self.call(&.{ .method = "getUpdates", .body = body });
    defer reply.deinit();
    const list = providers.json.array(try reply.result()) orelse return error.MalformedReply;
    var updates: std.ArrayList(Update) = .empty;
    errdefer {
        for (updates.items) |*update| freeUpdate(self.gpa, update);
        updates.deinit(self.gpa);
    }
    try updates.ensureTotalCapacity(self.gpa, list.items.len);
    for (list.items) |*value| {
        const update = providers.json.object(value) orelse return error.MalformedReply;
        const update_id = providers.json.integer(update.getPtr("update_id")) orelse
            return error.MalformedReply;
        var message: ?Update.Message = null;
        if (providers.json.object(update.getPtr("message"))) |object| {
            const chat = providers.json.object(object.getPtr("chat")) orelse
                return error.MalformedReply;
            const maybe_text = providers.json.string(object.getPtr("text"));
            message = .{
                .message_id = providers.json.integer(object.getPtr("message_id")) orelse
                    return error.MalformedReply,
                .chat_id = providers.json.integer(chat.getPtr("id")) orelse
                    return error.MalformedReply,
                .chat_private = if (providers.json.string(chat.getPtr("type"))) |kind|
                    std.mem.eql(u8, kind, "private")
                else
                    false,
                .text = if (maybe_text) |text| try self.gpa.dupe(u8, text) else null,
            };
        }
        errdefer if (message) |found| if (found.text) |text| self.gpa.free(text);
        var callback: ?Update.Callback = null;
        if (providers.json.object(update.getPtr("callback_query"))) |object| {
            callback = try self.parseCallback(object);
        }
        updates.appendAssumeCapacity(.{
            .update_id = update_id,
            .message = message,
            .callback = callback,
        });
    }
    return .{ .items = try updates.toOwnedSlice(self.gpa) };
}

fn parseCallback(self: *Client, object: *const std.json.ObjectMap) Error!?Update.Callback {
    const id = providers.json.string(object.getPtr("id")) orelse return error.MalformedReply;
    const message = providers.json.object(object.getPtr("message")) orelse return null;
    const data = providers.json.string(object.getPtr("data")) orelse return null;
    const chat = providers.json.object(message.getPtr("chat")) orelse return error.MalformedReply;
    const id_copy = try self.gpa.dupe(u8, id);
    errdefer self.gpa.free(id_copy);
    return .{
        .id = id_copy,
        .message_id = providers.json.integer(message.getPtr("message_id")) orelse
            return error.MalformedReply,
        .chat_id = providers.json.integer(chat.getPtr("id")) orelse return error.MalformedReply,
        .data = try self.gpa.dupe(u8, data),
    };
}

fn setMyCommands(self: *Client, commands: []const Command) Error!void {
    const body = try std.json.Stringify.valueAlloc(self.gpa, .{ .commands = commands }, .{});
    defer self.gpa.free(body);
    const reply = try self.call(&.{ .method = "setMyCommands", .body = body });
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
    const reply = try self.call(&.{ .method = "sendMessage", .body = body });
    defer reply.deinit();
    const result = providers.json.object(try reply.result()) orelse return error.MalformedReply;
    return providers.json.integer(result.getPtr("message_id")) orelse error.MalformedReply;
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
    const reply = self.call(&.{
        .method = "editMessageText",
        .body = body,
    }) catch |err| switch (err) {
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
    const reply = try self.call(&.{ .method = "deleteMessage", .body = body });
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
    const reply = try self.call(&.{ .method = "answerCallbackQuery", .body = body });
    defer reply.deinit();
    _ = try reply.result();
}

fn call(
    self: *Client,
    method_call: *const struct { method: []const u8, body: []const u8 },
) Error!Reply {
    const url = try std.fmt.allocPrint(
        self.gpa,
        api_url ++ "/bot{s}/{s}",
        .{ self.token, method_call.method },
    );
    defer self.gpa.free(url);
    const request: providers.Transport.Request = .{ .url = url, .body = method_call.body };
    const response = core.timeout.run(
        self.io,
        self.connect_ms,
        post,
        .{ self.gpa, self.io, self.transport, &request },
        releaseResponse,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Unavailable,
    };
    defer self.gpa.free(response.body);
    return self.classify(&response);
}

fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    request: *const providers.Transport.Request,
) !providers.Http.Response {
    return providers.Http.fetch(gpa, io, transport, request, response_bytes_max);
}

fn releaseResponse(
    response: *const providers.Http.Response,
    args: *const std.meta.ArgsTuple(@TypeOf(post)),
) void {
    args[0].free(response.body);
}

fn classify(self: *Client, response: *const providers.Http.Response) Error!Reply {
    const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, response.body, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    if (response.status == .ok) {
        const reply: Reply = .{ .parsed = parsed orelse return error.MalformedReply };
        errdefer reply.deinit();
        const object = providers.json.object(&reply.parsed.value) orelse
            return error.MalformedReply;
        const ok = providers.json.boolean(object.getPtr("ok")) orelse return error.MalformedReply;
        if (!ok) return error.MalformedReply;
        return reply;
    }
    defer if (parsed) |value| value.deinit();
    const value: ?*const std.json.Value = if (parsed) |*reply| &reply.value else null;
    self.keepDescription(value);
    return switch (response.status) {
        .unauthorized => error.Unauthorized,
        .forbidden => error.Forbidden,
        .conflict => error.Conflict,
        .too_many_requests => {
            self.retry_after_s = retryAfter(value) orelse 1;
            return error.RateLimited;
        },
        else => if (response.status.class() == .client_error)
            error.Rejected
        else
            error.Unavailable,
    };
}

fn keepDescription(self: *Client, value: ?*const std.json.Value) void {
    self.description_length = 0;
    const object = providers.json.object(value) orelse return;
    const text = providers.json.string(object.getPtr("description")) orelse return;
    const kept = tools.format.truncate(text, self.description_buffer.len);
    @memcpy(self.description_buffer[0..kept.len], kept);
    self.description_length = kept.len;
}

fn retryAfter(value: ?*const std.json.Value) ?u64 {
    const object = providers.json.object(value) orelse return null;
    const parameters = providers.json.object(object.getPtr("parameters")) orelse return null;
    return providers.json.unsigned(parameters.getPtr("retry_after"));
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

fn testClient(telegram: *testing.Telegram) Client {
    return .{
        .gpa = telegram.gpa,
        .io = telegram.io,
        .transport = telegram.transport(),
        .token = "42:secret",
        .connect_ms = 5_000,
    };
}

test "each request error falls into the class that its retry follows" {
    const cases = [_]struct { err: Error, class: Class }{
        .{ .err = error.Canceled, .class = .canceled },
        .{ .err = error.Unauthorized, .class = .{ .permanent = .unauthorized } },
        .{ .err = error.Forbidden, .class = .{ .permanent = .forbidden } },
        .{ .err = error.Conflict, .class = .{ .permanent = .conflict } },
        .{ .err = error.RateLimited, .class = .rate_limited },
        .{ .err = error.Rejected, .class = .rejected },
        .{ .err = error.Unavailable, .class = .transient },
        .{ .err = error.MalformedReply, .class = .transient },
        .{ .err = error.OutOfMemory, .class = .transient },
    };
    for (cases) |case| try std.testing.expectEqual(case.class, Class.of(case.err));
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
    const io = std.testing.io;
    var telegram = try testing.Telegram.init(gpa, io, &.{.{ .method = "getMe", .replies = &.{
        .{
            .body = "{\"ok\":true," ++
                "\"result\":{\"id\":42,\"is_bot\":true,\"username\":\"drinky_bot\"}}",
        },
    } }});
    defer telegram.deinit();
    var client = testClient(&telegram);

    const me = try client.getMe();
    defer me.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 42), me.id);
    try std.testing.expectEqualStrings("drinky_bot", me.username);
    try telegram.finish();
    try std.testing.expectEqualStrings("/bot42:secret/getMe", telegram.requests.items[0].path);
    try std.testing.expectEqualStrings("{}", telegram.requests.items[0].body);
}

test "a poll reads a text message, a non-text message, a tap, and the chat type" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const reply_body =
        \\{"ok":true,"result":[
        \\{"update_id":7,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},
        \\"text":"hello"}},
        \\{"update_id":8,"message":{"message_id":2,"date":0,"chat":{"id":99,"type":"private"},
        \\"sticker":{}}},
        \\{"update_id":9,"message":{"message_id":3,"date":0,"chat":{"id":-5,"type":"group"},
        \\"text":"hi"}},
        \\{"update_id":10,"edited_message":{"message_id":1,"date":0,"chat":{"id":99,
        \\"type":"private"},"text":"hello!"}},
        \\{"update_id":11,"callback_query":{"id":"4407","from":{"id":5},"chat_instance":"c",
        \\"message":{"message_id":50,"date":0,"chat":{"id":99,"type":"private"},"text":"Thinking"},
        \\"data":"cancel:3"}},
        \\{"update_id":12,"callback_query":{"id":"4408","from":{"id":5},"chat_instance":"c",
        \\"inline_message_id":"i"}}
        \\]}
    ;
    var telegram = try testing.Telegram.init(gpa, io, &.{ testing.webhook_deleted, .{
        .method = "getUpdates",
        .replies = &.{
            .{ .body = "{\"ok\":true,\"result\":[{\"update_id\":6}]}" },
            .{ .body = reply_body },
        },
    } });
    defer telegram.deinit();
    var client = testClient(&telegram);

    var poll = try confirmedPoll(&client);
    const updates = try poll.next(&client, 25);
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
    try telegram.finish();
    try std.testing.expectEqualStrings(
        "{\"offset\":-1,\"timeout\":0,\"allowed_updates\":[\"message\",\"callback_query\"]}",
        telegram.requests.items[1].body,
    );
    try std.testing.expectEqualStrings(
        "{\"offset\":7,\"timeout\":25,\"allowed_updates\":[\"message\",\"callback_query\"]}",
        telegram.requests.items[2].body,
    );
}

fn confirmedPoll(client: *Client) Error!Poll {
    var poll: Poll = .{ .commands = null };
    for (0..2) |_| (try poll.next(client, 1)).deinit(client.gpa);
    return poll;
}

test "a malformed later update fails the poll without a leak" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const reply_body =
        \\{"ok":true,"result":[
        \\{"update_id":7,"message":{"message_id":1,"date":0,"chat":{"id":99,"type":"private"},
        \\"text":"kept"}},
        \\{"update_id":8,"message":{"message_id":2,"date":0,"chat":{"id":99,"type":"private"},
        \\"text":"kept too"}},
        \\{"message":{"message_id":3,"date":0,"chat":{"id":99,"type":"private"},"text":"no id"}}
        \\]}
    ;
    var telegram = try testing.Telegram.init(gpa, io, &.{ testing.webhook_deleted, .{
        .method = "getUpdates",
        .replies = &.{ .{ .body = testing.ok_empty }, .{ .body = reply_body } },
    } });
    defer telegram.deinit();
    var client = testClient(&telegram);

    var poll = try confirmedPoll(&client);
    try std.testing.expectError(error.MalformedReply, poll.next(&client, 1));
    try telegram.finish();
}

test "sendMessage returns the message id and states its options" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var telegram = try testing.Telegram.init(gpa, io, &.{.{ .method = "sendMessage", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
        .{ .body = "{\"ok\":true,\"result\":{\"message_id\":315}}" },
    } }});
    defer telegram.deinit();
    var client = testClient(&telegram);

    try std.testing.expectEqual(@as(i64, 314), try client.sendMessage(99, "hi", &.{}));
    try std.testing.expectEqual(@as(i64, 315), try client.sendMessage(99, "<b>x</b>", &.{
        .reply_to = 12,
        .disable_notification = true,
        .parse_mode = "HTML",
        .markup = "{\"inline_keyboard\":[[{\"text\":\"Cancel turn\"," ++
            "\"callback_data\":\"cancel:1\"}]]}",
    }));
    try telegram.finish();
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"hi\",\"disable_notification\":false}",
        telegram.requests.items[0].body,
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"text\":\"<b>x</b>\",\"disable_notification\":true," ++
            "\"parse_mode\":\"HTML\",\"reply_parameters\":{\"message_id\":12}," ++
            "\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"Cancel turn\"," ++
            "\"callback_data\":\"cancel:1\"}]]}}",
        telegram.requests.items[1].body,
    );
}

test "editMessageText states its target and keyboard, and an unchanged text counts as success" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const scripts = [_]testing.Script{.{ .method = "editMessageText", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
        .{ .body = "{\"ok\":true,\"result\":{\"message_id\":314}}" },
        .{
            .status = 400,
            .body = "{\"ok\":false,\"error_code\":400," ++
                "\"description\":\"Bad Request: message is not modified\"}",
        },
        .{
            .status = 400,
            .body = "{\"ok\":false,\"error_code\":400," ++
                "\"description\":\"Bad Request: message to edit not found\"}",
        },
    } }};
    var telegram = try testing.Telegram.init(gpa, io, &scripts);
    defer telegram.deinit();
    var client = testClient(&telegram);

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
    try telegram.finish();
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"Writing\"}",
        telegram.requests.items[0].body,
    );
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314,\"text\":\"<b>Writing</b>\",\"parse_mode\":\"HTML\"," ++
            "\"reply_markup\":{\"inline_keyboard\":[]}}",
        telegram.requests.items[1].body,
    );
}

test "deleteMessage names the message it takes out of the chat" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const scripts = [_]testing.Script{.{ .method = "deleteMessage", .replies = &.{
        .{ .body = "{\"ok\":true,\"result\":true}" },
        .{
            .status = 400,
            .body = "{\"ok\":false,\"error_code\":400," ++
                "\"description\":\"Bad Request: message to delete not found\"}",
        },
    } }};
    var telegram = try testing.Telegram.init(gpa, io, &scripts);
    defer telegram.deinit();
    var client = testClient(&telegram);

    try client.deleteMessage(.{ .chat_id = 99, .message_id = 314 });
    try std.testing.expectError(
        error.Rejected,
        client.deleteMessage(.{ .chat_id = 99, .message_id = 315 }),
    );
    try telegram.finish();
    try std.testing.expectEqualStrings(
        "{\"chat_id\":99,\"message_id\":314}",
        telegram.requests.items[0].body,
    );
}

test "answerCallbackQuery names the query alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var telegram = try testing.Telegram.init(gpa, io, &.{.{
        .method = "answerCallbackQuery",
        .replies = &.{.{ .body = "{\"ok\":true,\"result\":true}" }},
    }});
    defer telegram.deinit();
    var client = testClient(&telegram);

    try client.answerCallbackQuery("4407");
    try telegram.finish();
    try std.testing.expectEqualStrings(
        "{\"callback_query_id\":\"4407\"}",
        telegram.requests.items[0].body,
    );
}

test "a poll registers each command with its description after it deletes the webhook" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var telegram = try testing.Telegram.init(gpa, io, &.{
        testing.webhook_deleted,
        testing.commands_set,
    });
    defer telegram.deinit();
    var client = testClient(&telegram);

    var poll: Poll = .{ .commands = &.{
        .{ .command = "effort", .description = "set the reasoning-effort level" },
        .{ .command = "new", .description = "start a new conversation" },
    } };
    for (0..2) |_| (try poll.next(&client, 1)).deinit(gpa);
    try telegram.finish();
    try std.testing.expectEqualStrings(
        "/bot42:secret/deleteWebhook",
        telegram.requests.items[0].path,
    );
    try std.testing.expectEqualStrings(
        "{\"commands\":[{\"command\":\"effort\"," ++
            "\"description\":\"set the reasoning-effort level\"}," ++
            "{\"command\":\"new\",\"description\":\"start a new conversation\"}]}",
        telegram.requests.items[1].body,
    );
}

test "every status classifies, and a failure keeps its description and its wait" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const scripts = [_]testing.Script{.{ .method = "deleteWebhook", .replies = &.{
        .{
            .status = 401,
            .body = "{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}",
        },
        .{
            .status = 403,
            .body = "{\"ok\":false,\"error_code\":403," ++
                "\"description\":\"Forbidden: bot was blocked by the user\"}",
        },
        .{
            .status = 409,
            .body = "{\"ok\":false,\"error_code\":409," ++
                "\"description\":\"Conflict: terminated by other getUpdates request\"}",
        },
        .{
            .status = 429,
            .body = "{\"ok\":false,\"error_code\":429," ++
                "\"description\":\"Too Many Requests: retry after 7\"," ++
                "\"parameters\":{\"retry_after\":7}}",
        },
        .{
            .status = 400,
            .body = "{\"ok\":false,\"error_code\":400," ++
                "\"description\":\"Bad Request: can't parse entities\"}",
        },
        .{ .status = 502, .body = "<html>bad gateway</html>" },
        .{ .status = 200, .body = "{\"ok\":true}" },
        .{ .status = 200, .body = "not json" },
    } }};
    var telegram = try testing.Telegram.init(gpa, io, &scripts);
    defer telegram.deinit();
    var client = testClient(&telegram);
    var poll: Poll = .{ .commands = null };

    try std.testing.expectError(error.Unauthorized, poll.next(&client, 1));
    try std.testing.expectEqualStrings("Unauthorized", client.description());
    try std.testing.expectError(error.Forbidden, poll.next(&client, 1));
    try std.testing.expectEqualStrings(
        "Forbidden: bot was blocked by the user",
        client.description(),
    );
    try std.testing.expectError(error.Conflict, poll.next(&client, 1));
    try std.testing.expectError(error.RateLimited, poll.next(&client, 1));
    try std.testing.expectEqual(@as(u64, 7_000), client.retryAfterMs(std.math.maxInt(u64)));
    try std.testing.expectError(error.Rejected, poll.next(&client, 1));
    try std.testing.expectEqualStrings("Bad Request: can't parse entities", client.description());
    try std.testing.expectError(error.Unavailable, poll.next(&client, 1));
    try std.testing.expectEqualStrings("", client.description());
    try std.testing.expectError(error.MalformedReply, poll.next(&client, 1));
    try std.testing.expectError(error.MalformedReply, poll.next(&client, 1));
    try telegram.finish();
}

test "a long description cuts before a UTF-8 sequence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const body = "{\"ok\":false,\"error_code\":400,\"description\":\"" ++ "x" ** 198 ++ "€€\"}";
    const scripts = [_]testing.Script{.{ .method = "deleteWebhook", .replies = &.{
        .{ .status = 400, .body = body },
    } }};
    var telegram = try testing.Telegram.init(gpa, io, &scripts);
    defer telegram.deinit();
    var client = testClient(&telegram);
    var poll: Poll = .{ .commands = null };

    try std.testing.expectError(error.Rejected, poll.next(&client, 1));
    try std.testing.expectEqual(@as(usize, 198), client.description().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(client.description()));
    try telegram.finish();
}

test "a telegram that does not answer is unavailable, not a hang" {
    const gpa = std.testing.allocator;
    var clock: core.testing.ClockIo = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var telegram = try testing.Telegram.init(gpa, io, &.{});
    defer telegram.deinit();
    var client = testClient(&telegram);
    try std.testing.expectError(error.Unavailable, client.getMe());
    try telegram.finish();
    try std.testing.expectEqualSlices(u64, &.{5_000}, clock.slept());
}
