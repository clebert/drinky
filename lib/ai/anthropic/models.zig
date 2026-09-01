//! The model list of the Anthropic API, which every Anthropic account of Drinky
//! reads. `GET /v1/models` answers an OAuth subscription token and an API key
//! alike, so no account needs a private endpoint of its own.
//!
//! An entry states the id, the context window (`max_input_tokens`), the output
//! limit (`max_tokens`), and a capability object. The capability object names
//! the effort levels the model offers and whether it reasons at all. It never
//! states whether the reasoning can be stopped, so that one field stays unknown
//! here and an aggregator fills it.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");
const Transport = @import("Transport.zig");

const host = "https://api.anthropic.com/v1/models";
const anthropic_version = "2023-06-01";
const user_agent = "claude-cli/2.1.75";
const beta = "claude-code-20250219,oauth-2025-04-20";
const body_bytes_max = 2 * 1024 * 1024;
const entry_count_max = 1024;
/// The page size the request asks for, which is the maximum the API serves.
const page_size = 100;
/// The page cap. The list holds a few dozen models, so a request that keeps
/// reporting more pages is a server Drinky stops following.
const pages_max = 8;

/// One decoded page of the list.
pub const Page = struct {
    models: []Model,
    has_more: bool,

    pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
        gpa.free(self.models);
    }
};

/// Every model the credential behind `identity` can reach, in the order the API
/// lists it. The caller owns the result. One `deadline` bounds every page, so a
/// list that keeps reporting pages cannot hold the fetch open past it.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    identity: Transport.Identity,
) ![]Model {
    var collected: std.ArrayList(Model) = .empty;
    errdefer collected.deinit(gpa);

    var cursor: ?[]const u8 = null;
    for (0..pages_max) |_| {
        var page = try fetchPage(gpa, io, deadline, identity, cursor);
        defer page.deinit(gpa);
        try collected.appendSlice(gpa, page.models);
        if (!page.has_more or page.models.len == 0) break;
        if (collected.items.len > entry_count_max) return error.BadModelList;
        cursor = collected.items[collected.items.len - 1].name();
    }
    return collected.toOwnedSlice(gpa);
}

fn fetchPage(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    identity: Transport.Identity,
    cursor: ?[]const u8,
) !Page {
    var maybe_page: ?Page = null;
    deadline.call(io, request, .{
        gpa,
        io,
        identity,
        cursor,
        &maybe_page,
    }) catch |err| {
        if (maybe_page) |*page| page.deinit(gpa);
        return err;
    };
    return maybe_page orelse error.ModelListRequestFailed;
}

fn request(
    gpa: std.mem.Allocator,
    io: std.Io,
    identity: Transport.Identity,
    cursor: ?[]const u8,
    out: *?Page,
) !void {
    if (!validCredential(identity)) return error.BadModelListCredentials;

    const url = if (cursor) |after|
        try std.fmt.allocPrint(gpa, host ++ "?limit={d}&after_id={s}", .{ page_size, after })
    else
        try std.fmt.allocPrint(gpa, host ++ "?limit={d}", .{page_size});
    defer gpa.free(url);

    const authorization: []const u8 = switch (identity) {
        .subscription => |token| try std.fmt.allocPrint(gpa, "Bearer {s}", .{token}),
        // The key identity sends no `authorization` header at all.
        .api_key => &.{},
    };
    defer gpa.free(authorization);

    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var extra: [3]std.http.Header = undefined;
    var list_request = try client.request(.GET, uri, options(identity, authorization, &extra));
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
    const body = try reader.allocRemaining(gpa, .limited(body_bytes_max));
    defer gpa.free(body);

    out.* = try parse(gpa, body);
}

/// The request identity of the list, which mirrors the one the messages
/// endpoint uses. The subscription sends its Claude Code identity, and a key
/// sends itself. `extra` and `authorization` back the result, so both must
/// outlive the request.
fn options(
    identity: Transport.Identity,
    authorization: []const u8,
    extra: *[3]std.http.Header,
) std.http.Client.RequestOptions {
    switch (identity) {
        .subscription => {
            extra.* = .{
                .{ .name = "anthropic-version", .value = anthropic_version },
                .{ .name = "anthropic-beta", .value = beta },
                .{ .name = "x-app", .value = "cli" },
            };
            return .{
                .headers = .{
                    .authorization = .{ .override = authorization },
                    .user_agent = .{ .override = user_agent },
                },
                .extra_headers = extra,
                .redirect_behavior = .not_allowed,
            };
        },
        .api_key => |key| {
            extra[0] = .{ .name = "x-api-key", .value = key };
            extra[1] = .{ .name = "anthropic-version", .value = anthropic_version };
            extra[2] = .{ .name = "accept", .value = "application/json" };
            return .{ .extra_headers = extra, .redirect_behavior = .not_allowed };
        },
    }
}

/// Whether the credential of `identity` can travel as a header value. The
/// subscription sends its token in `authorization` and the key sends itself in
/// `x-api-key`, so the guard reads the credential rather than one composed
/// header.
fn validCredential(identity: Transport.Identity) bool {
    return net.validHeaderValue(switch (identity) {
        .subscription => |token| token,
        .api_key => |key| key,
    });
}

/// Decode one page. A malformed envelope rejects the page, while a malformed
/// entry is skipped so one bad model costs no other.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) !Page {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const object = json.object(parsed.value) orelse return error.BadModelList;
    const listed = json.array(object.get("data")) orelse return error.BadModelList;
    if (listed.items.len > entry_count_max) return error.BadModelList;

    var models: std.ArrayList(Model) = .empty;
    errdefer models.deinit(gpa);
    for (listed.items) |value| {
        const model = decode(value) orelse continue;
        try models.append(gpa, model);
    }
    return .{
        .models = try models.toOwnedSlice(gpa),
        .has_more = boolean(object.get("has_more")),
    };
}

fn decode(value: std.json.Value) ?Model {
    const object = json.object(value) orelse return null;
    const id = json.string(object.get("id")) orelse return null;
    var model = Model.init(id) catch return null;
    model.context_window = positive(object.get("max_input_tokens"));
    model.tokens_max = outputLimit(object.get("max_tokens"));
    capabilities(&model, object.get("capabilities"));
    return model;
}

/// The effort levels and the thinking state of one entry. A model that states no
/// capability object states nothing, so its levels stay empty and a request
/// carries no reasoning control. A model that states an unsupported effort
/// control denies the whole ladder, which no other source can reopen.
fn capabilities(model: *Model, value: ?std.json.Value) void {
    const object = json.object(value orelse return) orelse return;
    if (json.object(object.get("thinking"))) |thinking| {
        if (!boolean(thinking.get("supported"))) model.thinking = .unsupported;
    }
    const effort = json.object(object.get("effort")) orelse return;
    if (!boolean(effort.get("supported"))) {
        model.efforts_denied = true;
        return;
    }
    for (comptime std.enums.values(llm.Effort)) |level| {
        if (level == .none) continue;
        const named = json.object(effort.get(@tagName(level))) orelse continue;
        if (boolean(named.get("supported"))) model.addEffort(level);
    }
}

fn boolean(value: ?std.json.Value) bool {
    return switch (value orelse std.json.Value.null) {
        .bool => |flag| flag,
        else => false,
    };
}

fn positive(value: ?std.json.Value) ?u64 {
    const found = json.integer(value) orelse return null;
    return if (found > 0) @intCast(found) else null;
}

fn outputLimit(value: ?std.json.Value) ?u32 {
    const found = positive(value) orelse return null;
    return std.math.cast(u32, found);
}

// One entry of each shape the live list holds: an adaptive model with every
// level, a model without `xhigh`, and a model that names no level at all.
const sample =
    \\{ "data": [
    \\  { "type": "model", "id": "claude-opus-4-8", "display_name": "Claude Opus 4.8",
    \\    "max_input_tokens": 1000000, "max_tokens": 128000,
    \\    "capabilities": {
    \\      "effort": { "supported": true, "low": { "supported": true },
    \\                  "medium": { "supported": true }, "high": { "supported": true },
    \\                  "xhigh": { "supported": true }, "max": { "supported": true } },
    \\      "thinking": { "supported": true,
    \\                    "types": { "enabled": { "supported": false },
    \\                               "adaptive": { "supported": true } } } } },
    \\  { "type": "model", "id": "claude-sonnet-4-6", "display_name": "Claude Sonnet 4.6",
    \\    "max_input_tokens": 1000000, "max_tokens": 128000,
    \\    "capabilities": {
    \\      "effort": { "supported": true, "low": { "supported": true },
    \\                  "medium": { "supported": true }, "high": { "supported": true },
    \\                  "xhigh": { "supported": false }, "max": { "supported": true } },
    \\      "thinking": { "supported": true } } },
    \\  { "type": "model", "id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5",
    \\    "max_input_tokens": 200000, "max_tokens": 64000,
    \\    "capabilities": { "effort": { "supported": false },
    \\                      "thinking": { "supported": false } } }
    \\], "has_more": false, "first_id": "claude-opus-4-8", "last_id": "claude-haiku-4-5-20251001" }
;

// Both identities reach the same endpoint, so both must pass the guard. The key
// travels as `x-api-key` and the token as `authorization`, and a credential that
// holds CR or LF can split either head.
test "the credential guard reads the credential that each identity sends" {
    try std.testing.expect(validCredential(.{ .api_key = "sk-ant-key" }));
    try std.testing.expect(validCredential(.{ .subscription = "oauth-token" }));

    try std.testing.expect(!validCredential(.{ .api_key = "" }));
    try std.testing.expect(!validCredential(.{ .subscription = "" }));
    try std.testing.expect(!validCredential(.{ .api_key = "sk-ant\r\nx-injected: 1" }));
    try std.testing.expect(!validCredential(.{ .subscription = "token\nx-injected: 1" }));
}

// The deadline of a fetch is shared with the requests around it, so a page must
// take what is left of the window and not a window of its own. A window that has
// closed refuses the page before it opens a socket.
test "an expired deadline refuses the list without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetch(std.testing.allocator, io, expired, .{ .api_key = "sk-ant-key" }),
    );
}

test parse {
    const gpa = std.testing.allocator;
    var page = try parse(gpa, sample);
    defer page.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), page.models.len);
    try std.testing.expect(!page.has_more);

    const opus = page.models[0];
    try std.testing.expectEqualStrings("claude-opus-4-8", opus.name());
    try std.testing.expectEqual(@as(?u64, 1_000_000), opus.context_window);
    try std.testing.expectEqual(@as(?u32, 128_000), opus.tokens_max);
    for ([_]llm.Effort{ .low, .medium, .high, .xhigh, .max }) |level|
        try std.testing.expect(opus.offers(level));
    try std.testing.expect(!opus.offers(.minimal));
    try std.testing.expect(!opus.offers(.ultra));
    // The vendor never states whether the reasoning can stop, so the level that
    // stops it stays hidden until an aggregator states it.
    try std.testing.expectEqual(Model.Thinking.unknown, opus.thinking);
    try std.testing.expect(!opus.offers(.none));

    // A level the vendor marks unsupported folds onto the nearest one it names.
    const sonnet = page.models[1];
    try std.testing.expect(!sonnet.offers(.xhigh));
    try std.testing.expectEqual(llm.Effort.high, sonnet.reasoning(.xhigh).named);
    try std.testing.expectEqual(llm.Effort.max, sonnet.reasoning(.max).named);

    // A model that never reasons names no level and carries no control.
    const haiku = page.models[2];
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", haiku.name());
    try std.testing.expectEqual(Model.Thinking.unsupported, haiku.thinking);
    try std.testing.expect(haiku.reasoning(.high) == .omitted);
    // The denial of the effort control is a fact of its own, so no other source
    // can name a level for this model later.
    try std.testing.expect(haiku.efforts_denied);
    try std.testing.expectEqual(@as(?u32, 64_000), haiku.tokens_max);
    // The vendor prices nothing, so every model of the list arrives unpriced.
    try std.testing.expect(haiku.price == null);
}

test "a malformed envelope is rejected and a malformed entry is skipped" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadModelList, parse(gpa, "{}"));
    try std.testing.expectError(error.BadModelList, parse(gpa, "[]"));
    try std.testing.expectError(error.BadModelList, parse(gpa, "{\"data\":{}}"));

    var page = try parse(gpa,
        \\{ "data": [
        \\  { "id": "kept", "max_input_tokens": 10 },
        \\  { "display_name": "no id" },
        \\  { "id": "" },
        \\  "not-an-object"
        \\], "has_more": true }
    );
    defer page.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), page.models.len);
    try std.testing.expectEqualStrings("kept", page.models[0].name());
    try std.testing.expect(page.has_more);
    // A stated limit that is not a count leaves the field unstated.
    try std.testing.expectEqual(@as(?u32, null), page.models[0].tokens_max);
}

// The cursor of the next page is the name of the last model of this page, and
// that name lands in the query of the next request line. A name that splits the
// head or corrupts the query therefore never survives the decode.
test "an id that a request line cannot carry never becomes a cursor" {
    const gpa = std.testing.allocator;
    var page = try parse(gpa,
        \\{ "data": [
        \\  { "id": "claude-opus-4-8", "max_input_tokens": 10 },
        \\  { "id": "split\r\nx-injected: 1", "max_input_tokens": 10 },
        \\  { "id": "break\nx-injected: 1", "max_input_tokens": 10 },
        \\  { "id": "claude&limit=1", "max_input_tokens": 10 }
        \\], "has_more": true }
    );
    defer page.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), page.models.len);
    // The last model of the page is the cursor, so it holds the safe id alone.
    const cursor = page.models[page.models.len - 1].name();
    try std.testing.expectEqualStrings("claude-opus-4-8", cursor);
    try std.testing.expect(std.mem.indexOfAny(u8, cursor, "\r\n&?# ") == null);
}

test "parse bounds the entry count" {
    const gpa = std.testing.allocator;
    const at_max = "{\"data\":[{}" ++ (",{}" ** (entry_count_max - 1)) ++ "]}";
    var page = try parse(gpa, at_max);
    page.deinit(gpa);
    const over = "{\"data\":[{}" ++ (",{}" ** entry_count_max) ++ "]}";
    try std.testing.expectError(error.BadModelList, parse(gpa, over));
}
