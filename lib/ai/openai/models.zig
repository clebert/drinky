//! The model lists of the two OpenAI accounts, which have nothing in common but
//! their vendor.
//!
//! The ChatGPT subscription reads the Codex catalog. It states a slug, a context
//! window that the public API contradicts, and the reasoning levels of that
//! backend, which include one the API never offers. It hides a model from its
//! own clients through `visibility`, and Drinky hides those too.
//!
//! The API key reads `GET /v1/models`, which states an id and nothing else. No
//! window, no level, and no price. Every other field of such a model comes from
//! an aggregator, so the caller merges before it offers the model to the user.

const std = @import("std");

const Auth = @import("Auth.zig");
const json = @import("../json.zig");
const llm = @import("../llm.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");

/// The numeric semantic version the Codex catalog uses for client filtering.
const client_version = "0.0.0";
const codex_endpoint = "https://chatgpt.com/backend-api/codex/models?client_version=" ++
    client_version;
const api_endpoint = "https://api.openai.com/v1/models";
const originator = "drinky";
const body_bytes_max = 4 * 1024 * 1024;
const entry_count_max = 1024;

/// Every model the ChatGPT subscription behind `auth` can run. The caller owns
/// the result. The `deadline` bounds the request and the token refresh inside it.
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

/// The extra headers of the Codex list request. A stored credential can carry
/// no account id, and the transport sends neither the account nor the
/// originator header there, so this request omits both too. `extra` backs the
/// result, so it must outlive the request.
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

/// Whether the credentials of the subscription can travel as header values. An
/// empty account id names no header at all, so it cannot split the request
/// head and the guard passes it.
fn validSubscriptionCredentials(access_token: []const u8, account_id: []const u8) bool {
    if (!net.validHeaderValue(access_token)) return false;
    return account_id.len == 0 or net.validHeaderValue(account_id);
}

/// Every model the API key `key` can name. The caller owns the result. The
/// `deadline` bounds the request.
pub fn fetchApi(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    key: []const u8,
) ![]Model {
    var collected: ?[]Model = null;
    deadline.call(io, requestApi, .{ gpa, io, key, &collected }) catch |err| {
        if (collected) |models| gpa.free(models);
        return err;
    };
    return collected orelse error.ModelListRequestFailed;
}

fn requestApi(gpa: std.mem.Allocator, io: std.Io, key: []const u8, out: *?[]Model) !void {
    if (!net.validHeaderValue(key)) return error.BadModelListCredentials;
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{key});
    defer gpa.free(authorization);

    const extra = [_]std.http.Header{.{ .name = "accept", .value = "application/json" }};
    const body = try get(gpa, io, api_endpoint, .{
        .headers = .{ .authorization = .{ .override = authorization } },
        .extra_headers = &extra,
        .redirect_behavior = .not_allowed,
    });
    defer gpa.free(body);

    out.* = try parseApi(gpa, body);
}

/// The body of one successful GET. The caller owns it.
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

/// Decode the Codex catalog. A model the backend hides from its own clients
/// stays out, because the picker must offer what the user can run.
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

    // The stated window wins. The maximum stands in only when the entry states
    // no window of its own.
    const maximum = positive(object.get("max_context_window"));
    model.context_window = switch (object.get("context_window") orelse std.json.Value.null) {
        .null => maximum,
        else => |stated| positive(stated) orelse maximum,
    };

    const levels = json.array(object.get("supported_reasoning_levels")) orelse return model;
    for (levels.items) |entry| {
        const level = json.object(entry) orelse continue;
        const name = json.string(level.get("effort")) orelse continue;
        addLevel(&model, name);
    }
    return model;
}

/// Whether the backend hides this model from its own clients.
fn hidden(value: ?std.json.Value) bool {
    const visibility = json.string(value orelse return false) orelse return false;
    return std.mem.eql(u8, visibility, "hide");
}

/// Decode `GET /v1/models`, which states an id and nothing more.
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
    }
    return models.toOwnedSlice(gpa);
}

/// Record one level name the provider stated. A provider that names `none` as a
/// level states that the reasoning can stop, which is a thinking state here and
/// no rung on the ladder. A name the ladder does not hold is dropped, so a new
/// provider level cannot reach a picker that has no order for it.
fn addLevel(model: *Model, name: []const u8) void {
    const level = std.meta.stringToEnum(llm.Effort, name) orelse return;
    if (level == .none) {
        model.thinking = .optional;
        return;
    }
    model.addEffort(level);
}

fn positive(value: ?std.json.Value) ?u64 {
    const found = json.integer(value) orelse return null;
    return if (found > 0) @intCast(found) else null;
}

// The live catalog shape, cut to the fields Drinky reads.
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
    \\    "supported_reasoning_levels": [ { "effort": "low" }, { "effort": "high" } ] },
    \\  { "slug": "gpt-reserve", "visibility": "hide",
    \\    "context_window": 272000, "max_context_window": 872000 }
    \\] }
;

// A stored credential can carry no account id, and the transport treats that
// state as valid: it omits the account headers there. The list request of the
// same account must follow that contract.
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

// Both lists share the deadline of the fetch around them, so a window that has
// closed refuses each request before it opens a socket.
test "an expired deadline refuses both lists without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetchApi(std.testing.allocator, io, expired, "sk-openai"),
    );
    // The subscription reads its token inside the request, so a refused request
    // never reaches this store. A signed-out store would answer with
    // `NotAuthenticated` if it did.
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

    // A credential that can split the request head is refused in both fields.
    try std.testing.expect(!validSubscriptionCredentials("", "account"));
    try std.testing.expect(!validSubscriptionCredentials("token\r\nx-injected: 1", "account"));
    try std.testing.expect(!validSubscriptionCredentials("token", "account\nx-injected: 1"));
}

test parseSubscription {
    const gpa = std.testing.allocator;
    const models = try parseSubscription(gpa, codex_sample);
    defer gpa.free(models);

    // The hidden model never reaches the picker.
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", models[0].name());
    try std.testing.expectEqualStrings("gpt-5.4", models[1].name());

    const sol = models[0];
    // The stated window wins over the maximum, and it contradicts the public API.
    try std.testing.expectEqual(@as(?u64, 272_000), sol.context_window);
    // The backend offers a level the public API never does.
    try std.testing.expect(sol.offers(.ultra));
    try std.testing.expect(sol.offers(.low));
    try std.testing.expect(!sol.offers(.minimal));
    // The catalog names no level that stops the reasoning, so none stays hidden.
    try std.testing.expectEqual(Model.Thinking.unknown, sol.thinking);
    try std.testing.expect(!sol.offers(.none));
    // The backend prices nothing and states no output limit.
    try std.testing.expect(sol.price == null);
    try std.testing.expectEqual(@as(?u32, null), sol.tokens_max);

    // A null window falls back to the maximum.
    try std.testing.expectEqual(@as(?u64, 1_000_000), models[1].context_window);
    try std.testing.expectEqual(llm.Effort.high, models[1].reasoning(.max).named);
}

test parseApi {
    const gpa = std.testing.allocator;
    const models = try parseApi(gpa,
        \\{ "object": "list", "data": [
        \\  { "id": "gpt-5.6-sol", "object": "model", "created": 1, "owned_by": "openai" },
        \\  { "id": "text-embedding-3-large", "object": "model", "created": 2 },
        \\  { "object": "model", "created": 3 },
        \\  "not-an-object"
        \\] }
    );
    defer gpa.free(models);

    // The list states an id and nothing else, so every other field stays unset
    // and the caller must merge before it offers the model.
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", models[0].name());
    try std.testing.expectEqual(@as(?u64, null), models[0].context_window);
    try std.testing.expect(models[0].price == null);
    try std.testing.expectEqual(Model.Thinking.unknown, models[0].thinking);
    try std.testing.expect(models[0].reasoning(.high) == .omitted);
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
