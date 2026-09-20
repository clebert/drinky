const std = @import("std");

const Auth = @import("Auth.zig");
const json = @import("../json.zig");
const llm = @import("../llm.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");

const client_version = "0.0.0";
const codex_endpoint = "https://chatgpt.com/backend-api/codex/models?client_version=" ++
    client_version;
const api_endpoint = "https://api.openai.com/v1/models";
const originator = "drinky";
const body_bytes_max = 4 * 1024 * 1024;
const entry_count_max = 1024;

pub fn fetchSubscription(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    auth: *Auth,
) ![]Model {
    var collected: ?[]Model = null;
    deadline.call(io, requestSubscription, .{
        gpa,
        io,
        auth,
        &collected,
    }) catch |err| {
        if (collected) |models| gpa.free(models);
        return err;
    };
    return collected orelse error.ModelListRequestFailed;
}

fn requestSubscription(
    gpa: std.mem.Allocator,
    io: std.Io,
    auth: *Auth,
    out: *?[]Model,
) !void {
    const access_token = try auth.accessToken();
    const account_id = auth.accountId();
    if (!validSubscriptionCredentials(access_token, account_id))
        return error.BadModelListCredentials;

    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{access_token});
    defer gpa.free(authorization);

    var extra: [3]std.http.Header = undefined;
    const body = try get(gpa, io, codex_endpoint, .{
        .headers = .{
            .authorization = .{ .override = authorization },
            .user_agent = .{ .override = originator },
        },
        .extra_headers = subscriptionHeaders(account_id, &extra),
        .redirect_behavior = .not_allowed,
    });
    defer gpa.free(body);

    out.* = try parseSubscription(gpa, body);
}

fn subscriptionHeaders(
    account_id: []const u8,
    extra: *[3]std.http.Header,
) []const std.http.Header {
    extra[0] = .{ .name = "accept", .value = "application/json" };
    if (account_id.len == 0) return extra[0..1];
    extra[1] = .{ .name = "chatgpt-account-id", .value = account_id };
    extra[2] = .{ .name = "originator", .value = originator };
    return extra[0..3];
}

fn validSubscriptionCredentials(access_token: []const u8, account_id: []const u8) bool {
    if (!net.validHeaderValue(access_token)) return false;
    return account_id.len == 0 or net.validHeaderValue(account_id);
}

pub const List = struct {
    endpoint: []const u8,
    token: ?[]const u8,
    decoder: *const fn (std.mem.Allocator, []const u8) anyerror![]Model = parseApi,
};

pub fn fetchApi(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    key: []const u8,
) ![]Model {
    return fetchList(gpa, io, deadline, &.{ .endpoint = api_endpoint, .token = key });
}

pub fn fetchList(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    list: *const List,
) ![]Model {
    var collected: ?[]Model = null;
    deadline.call(io, requestList, .{ gpa, io, list, &collected }) catch |err| {
        if (collected) |models| gpa.free(models);
        return err;
    };
    return collected orelse error.ModelListRequestFailed;
}

fn requestList(gpa: std.mem.Allocator, io: std.Io, list: *const List, out: *?[]Model) !void {
    var maybe_authorization: ?[]u8 = null;
    if (list.token) |token| {
        if (!net.validHeaderValue(token)) return error.BadModelListCredentials;
        maybe_authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    }
    defer if (maybe_authorization) |authorization| gpa.free(authorization);

    const extra = [_]std.http.Header{.{ .name = "accept", .value = "application/json" }};
    const body = try get(gpa, io, list.endpoint, .{
        .headers = .{ .authorization = if (maybe_authorization) |authorization|
            .{ .override = authorization }
        else
            .omit },
        .extra_headers = &extra,
        .redirect_behavior = .not_allowed,
    });
    defer gpa.free(body);

    out.* = try list.decoder(gpa, body);
}

fn get(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    options: std.http.Client.RequestOptions,
) ![]u8 {
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var list_request = try client.request(.GET, uri, options);
    defer list_request.deinit();

    try list_request.sendBodiless();

    var redirect_buffer: [4096]u8 = undefined;
    var response = try list_request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.ModelListRequestFailed;

    const decompress_buffer = try net.decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [16384]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(body_bytes_max));
}

fn parseSubscription(gpa: std.mem.Allocator, body: []const u8) ![]Model {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const object = json.object(parsed.value) orelse return error.BadModelList;
    const listed = json.array(object.get("models")) orelse return error.BadModelList;
    if (listed.items.len > entry_count_max) return error.BadModelList;

    var models: std.ArrayList(Model) = .empty;
    errdefer models.deinit(gpa);
    for (listed.items) |value| {
        const model = decodeSubscription(value) orelse continue;
        try models.append(gpa, model);
    }
    return models.toOwnedSlice(gpa);
}

fn decodeSubscription(value: std.json.Value) ?Model {
    const object = json.object(value) orelse return null;
    if (hidden(object.get("visibility"))) return null;
    const slug = json.string(object.get("slug")) orelse return null;
    var model = Model.init(slug) catch return null;

    const maximum = positive(object.get("max_context_window"));
    model.context_window = switch (object.get("context_window") orelse std.json.Value.null) {
        .null => maximum,
        else => |stated| positive(stated) orelse maximum,
    };

    const levels = json.array(object.get("supported_reasoning_levels")) orelse return model;
    for (levels.items) |entry| {
        const level = json.object(entry) orelse continue;
        const name = json.string(level.get("effort")) orelse continue;
        model.addEffort(std.meta.stringToEnum(llm.Effort, name) orelse continue);
    }
    return model;
}

fn hidden(value: ?std.json.Value) bool {
    const visibility = json.string(value orelse return false) orelse return false;
    return std.mem.eql(u8, visibility, "hide");
}

fn parseApi(gpa: std.mem.Allocator, body: []const u8) ![]Model {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const object = json.object(parsed.value) orelse return error.BadModelList;
    const listed = json.array(object.get("data")) orelse return error.BadModelList;
    if (listed.items.len > entry_count_max) return error.BadModelList;

    var models: std.ArrayList(Model) = .empty;
    errdefer models.deinit(gpa);
    for (listed.items) |value| {
        const entry = json.object(value) orelse continue;
        const id = json.string(entry.get("id")) orelse continue;
        const model = Model.init(id) catch continue;
        try models.append(gpa, model);
        const aliases = json.array(entry.get("aliases")) orelse continue;
        for (aliases.items) |alias_value| {
            const alias = json.string(alias_value) orelse continue;
            if (std.mem.eql(u8, alias, id)) continue;
            var named = Model.init(alias) catch continue;
            named.serveAs(id) catch continue;
            try models.append(gpa, named);
        }
    }
    return models.toOwnedSlice(gpa);
}

fn positive(value: ?std.json.Value) ?u64 {
    const found = json.integer(value) orelse return null;
    return if (found > 0) @intCast(found) else null;
}

const codex_sample =
    \\{ "models": [
    \\  { "slug": "gpt-5.6-sol", "display_name": "GPT-5.6-Sol", "visibility": "list",
    \\    "context_window": 272000, "max_context_window": 872000,
    \\    "default_reasoning_level": "low",
    \\    "supported_reasoning_levels": [
    \\      { "effort": "low", "description": "Fast responses" },
    \\      { "effort": "medium", "description": "Balances speed and depth" },
    \\      { "effort": "high", "description": "Greater depth" },
    \\      { "effort": "xhigh", "description": "Extra high depth" },
    \\      { "effort": "max", "description": "Maximum depth" },
    \\      { "effort": "ultra", "description": "Maximum with delegation" } ] },
    \\  { "slug": "gpt-5.4", "visibility": "list",
    \\    "context_window": null, "max_context_window": 1000000,
    \\    "supported_reasoning_levels": [ { "effort": "none" }, { "effort": "low" },
    \\                                    { "effort": "high" } ] },
    \\  { "slug": "gpt-reserve", "visibility": "hide",
    \\    "context_window": 272000, "max_context_window": 872000 }
    \\] }
;

test "the Codex list omits the account headers when the credential names none" {
    var extra: [3]std.http.Header = undefined;

    const named = subscriptionHeaders("account", &extra);
    try std.testing.expectEqual(@as(usize, 3), named.len);
    try std.testing.expectEqualStrings("accept", named[0].name);
    try std.testing.expectEqualStrings("chatgpt-account-id", named[1].name);
    try std.testing.expectEqualStrings("account", named[1].value);
    try std.testing.expectEqualStrings("originator", named[2].name);
    try std.testing.expectEqualStrings(originator, named[2].value);

    const anonymous = subscriptionHeaders("", &extra);
    try std.testing.expectEqual(@as(usize, 1), anonymous.len);
    try std.testing.expectEqualStrings("accept", anonymous[0].name);
}

test "an expired deadline refuses both lists without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetchApi(std.testing.allocator, io, expired, "sk-openai"),
    );
    var signed_out: Auth = .{
        .gpa = std.testing.allocator,
        .io = io,
        .timeouts = .{},
        .path = "",
        .tokens = null,
    };
    try std.testing.expectError(
        error.Timeout,
        fetchSubscription(std.testing.allocator, io, expired, &signed_out),
    );
}

test "the Codex guard accepts a credential that names no account" {
    try std.testing.expect(validSubscriptionCredentials("token", "account"));
    try std.testing.expect(validSubscriptionCredentials("token", ""));

    try std.testing.expect(!validSubscriptionCredentials("", "account"));
    try std.testing.expect(!validSubscriptionCredentials("token\r\nx-injected: 1", "account"));
    try std.testing.expect(!validSubscriptionCredentials("token", "account\nx-injected: 1"));
}

test parseSubscription {
    const gpa = std.testing.allocator;
    const models = try parseSubscription(gpa, codex_sample);
    defer gpa.free(models);

    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", models[0].name());
    try std.testing.expectEqualStrings("gpt-5.4", models[1].name());

    const sol = models[0];
    try std.testing.expectEqual(@as(?u64, 272_000), sol.context_window);
    try std.testing.expectEqual(@as(usize, 5), sol.efforts.count());
    try std.testing.expect(sol.offers(.low));
    try std.testing.expect(sol.offers(.max));
    try std.testing.expectEqual(Model.Thinking.unknown, sol.thinking);
    try std.testing.expect(sol.price == null);
    try std.testing.expectEqual(@as(?u32, null), sol.tokens_max);

    try std.testing.expectEqual(@as(?u64, 1_000_000), models[1].context_window);
    try std.testing.expectEqual(llm.Effort.high, models[1].reasoning(.max).named);
    try std.testing.expectEqual(@as(usize, 2), models[1].efforts.count());
}

test parseApi {
    const gpa = std.testing.allocator;
    const models = try parseApi(gpa,
        \\{ "object": "list", "data": [
        \\  { "id": "gpt-5.6-sol", "object": "model", "created": 1, "owned_by": "openai" },
        \\  { "id": "text-embedding-3-large", "object": "model", "created": 2 },
        \\  { "id": "grok-imagine-image", "object": "model", "owned_by": "xai",
        \\    "context_length": 1024, "image_price": 200000000 },
        \\  { "id": "grok-4.20-0309-reasoning", "object": "model", "owned_by": "xai",
        \\    "aliases": ["grok-4.20", "grok-4.20-0309-reasoning", 7, "bad name"] },
        \\  { "object": "model", "created": 3 },
        \\  "not-an-object"
        \\] }
    );
    defer gpa.free(models);

    try std.testing.expectEqual(@as(usize, 5), models.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", models[0].name());
    try std.testing.expectEqual(@as(?u64, null), models[0].context_window);
    try std.testing.expect(models[0].price == null);
    try std.testing.expectEqual(Model.Thinking.unknown, models[0].thinking);
    try std.testing.expect(models[0].reasoning(.high) == .omitted);
    try std.testing.expectEqual(@as(?u64, null), models[2].context_window);
    try std.testing.expectEqualStrings("grok-4.20-0309-reasoning", models[3].name());
    try std.testing.expectEqualStrings("", models[3].servedName());
    try std.testing.expectEqualStrings("grok-4.20", models[4].name());
    try std.testing.expectEqualStrings("grok-4.20-0309-reasoning", models[4].servedName());
}

test "a malformed envelope is rejected and a malformed entry is skipped" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadModelList, parseSubscription(gpa, "{}"));
    try std.testing.expectError(error.BadModelList, parseSubscription(gpa, "{\"models\":{}}"));
    try std.testing.expectError(error.BadModelList, parseApi(gpa, "{}"));
    try std.testing.expectError(error.BadModelList, parseApi(gpa, "[]"));

    const models = try parseSubscription(gpa,
        \\{ "models": [ { "slug": "kept" }, { "display_name": "no slug" }, 7 ] }
    );
    defer gpa.free(models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("kept", models[0].name());
    try std.testing.expectEqual(@as(?u64, null), models[0].context_window);
}

test "both parsers bound the entry count" {
    const gpa = std.testing.allocator;
    const codex_at_max = "{\"models\":[{}" ++ (",{}" ** (entry_count_max - 1)) ++ "]}";
    gpa.free(try parseSubscription(gpa, codex_at_max));
    const codex_over = "{\"models\":[{}" ++ (",{}" ** entry_count_max) ++ "]}";
    try std.testing.expectError(error.BadModelList, parseSubscription(gpa, codex_over));

    const api_at_max = "{\"data\":[{}" ++ (",{}" ** (entry_count_max - 1)) ++ "]}";
    gpa.free(try parseApi(gpa, api_at_max));
    const api_over = "{\"data\":[{}" ++ (",{}" ** entry_count_max) ++ "]}";
    try std.testing.expectError(error.BadModelList, parseApi(gpa, api_over));
}

test "a list without a credential omits the Authorization header" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const endpoint = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.1:{d}/v1/models",
        .{server.socket.address.getPort()},
    );
    defer gpa.free(endpoint);

    var has_authorization = false;
    var serve = try io.concurrent(serveModelList, .{ io, &server, &has_authorization });
    var reaped = false;
    defer if (!reaped) {
        _ = serve.cancel(io) catch {};
    };

    const models = try fetchList(gpa, io, .{ .at = null }, &.{
        .endpoint = endpoint,
        .token = null,
    });
    defer gpa.free(models);
    reaped = true;
    try serve.await(io);
    try std.testing.expect(!has_authorization);
    try std.testing.expectEqual(@as(usize, 0), models.len);
}

fn serveModelList(io: std.Io, server: *std.Io.net.Server, has_authorization: *bool) !void {
    const body = "{\"object\":\"list\",\"data\":[]}";
    var connection = try server.accept(io);
    defer connection.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &read_buffer);
    var lines_left: usize = 64;
    while (lines_left > 0) : (lines_left -= 1) {
        const raw = try reader.interface.takeDelimiterInclusive('\n');
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "authorization:")) has_authorization.* = true;
    }

    var write_buffer: [512]u8 = undefined;
    var writer = connection.writer(io, &write_buffer);
    try writer.interface.print(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" ++
            "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    try writer.interface.flush();
}
