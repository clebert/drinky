const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const json = @import("../json.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");
const paging = @import("../paging.zig");

const endpoint = "https://api.anthropic.com/v1/models";
const body_bytes_max = 2 * 1024 * 1024;
const page_size = 100;

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    deadline: *const core.timeout.Deadline,
    access: *const providers.Messages.IdentifyOptions,
) paging.Error![]Model {
    return paging.collect(
        providers.Messages.IdentifyOptions,
        gpa,
        io,
        transport,
        deadline,
        access,
        request,
    );
}

fn request(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    access: *const providers.Messages.IdentifyOptions,
    cursor: ?[]const u8,
) paging.Error!paging.Page {
    if (!providers.Transport.validHeaderValue(access.token)) return error.BadModelListCredentials;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: providers.Transport.Request = .{
        .method = .GET,
        .url = if (cursor) |after| try std.fmt.allocPrint(
            arena,
            endpoint ++ "?limit={d}&after_id={s}",
            .{ page_size, after },
        ) else try std.fmt.allocPrint(arena, endpoint ++ "?limit={d}", .{page_size}),
        .headers = &.{net.accept_json},
    };
    try providers.Messages.identify(arena, &list, access);
    const body = try net.getBody(gpa, io, transport, &list, body_bytes_max);
    defer gpa.free(body);

    return parse(gpa, body);
}

fn parse(gpa: std.mem.Allocator, body: []const u8) error{ OutOfMemory, BadModelList }!paging.Page {
    const envelope = try json.envelope(gpa, body, &.{
        .field = "data",
        .entries_max = paging.entries_max,
    });
    defer envelope.deinit();

    const models = try json.models(gpa, envelope.entries, decode);
    errdefer gpa.free(models);
    const has_more = providers.json.boolean(envelope.object.getPtr("has_more")) orelse false;
    const cursor = if (has_more and models.len != 0)
        try gpa.dupe(u8, models[models.len - 1].name())
    else
        null;
    return .{ .models = models, .cursor = cursor };
}

fn decode(value: *const std.json.Value) ?Model {
    const object = providers.json.object(value) orelse return null;
    const id = providers.json.string(object.getPtr("id")) orelse return null;
    var model = Model.init(id) catch return null;
    model.context_window = json.positive(u64, object.getPtr("max_input_tokens"));
    model.tokens_max = json.positive(u32, object.getPtr("max_tokens"));
    capabilities(&model, object.getPtr("capabilities"));
    return model;
}

fn capabilities(model: *Model, value: ?*const std.json.Value) void {
    const object = providers.json.object(value) orelse return;
    if (providers.json.object(object.getPtr("thinking"))) |thinking| {
        const thinking_supported =
            providers.json.boolean(thinking.getPtr("supported")) orelse false;
        model.thinking = if (thinking_supported) .supported else .unsupported;
    }
    const effort = providers.json.object(object.getPtr("effort")) orelse return;
    const effort_supported = providers.json.boolean(effort.getPtr("supported")) orelse false;
    if (!effort_supported) {
        model.efforts_denied = true;
        return;
    }
    for (comptime std.enums.values(core.Provider.Effort)) |level| {
        const named = providers.json.object(effort.getPtr(@tagName(level))) orelse continue;
        if (providers.json.boolean(named.getPtr("supported")) orelse false) model.addEffort(level);
    }
}

test "the list sends the identity of the Messages wire" {
    const gpa = std.testing.allocator;
    var transport: providers.testing.FakeTransport = .{
        .gpa = gpa,
        .replies = &.{ .{ .body = sample }, .{ .body = sample } },
    };
    defer transport.deinit();

    const plan = try fetch(gpa, std.testing.io, transport.transport(), &.unbounded, &.{
        .identity = .subscription,
        .token = "oauth-token",
    });
    defer gpa.free(plan);
    try std.testing.expectEqualStrings(
        "GET https://api.anthropic.com/v1/models?limit=100\n" ++
            "authorization: Bearer oauth-token\n" ++
            "user-agent: claude-cli/2.1.75\n" ++
            "accept: application/json\n" ++
            "anthropic-version: 2023-06-01\n" ++
            "anthropic-beta: claude-code-20250219,oauth-2025-04-20\n" ++
            "x-app: cli\n\n",
        transport.requests.items[0],
    );

    const console = try fetch(gpa, std.testing.io, transport.transport(), &.unbounded, &.{
        .identity = .console,
        .token = "sk-ant-key",
    });
    defer gpa.free(console);
    try std.testing.expectEqualStrings(
        "GET https://api.anthropic.com/v1/models?limit=100\n" ++
            "accept: application/json\n" ++
            "x-api-key: sk-ant-key\n" ++
            "anthropic-version: 2023-06-01\n\n",
        transport.requests.items[1],
    );
}

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

test "the list follows the last id to the next page and bounds the entries of every page" {
    const gpa = std.testing.allocator;
    const first_page = "{\"data\":[" ++ ("{\"id\":\"claude-a\"}," ** 999) ++
        "{\"id\":\"claude-b\"}],\"has_more\":true}";
    const last_page = "{\"data\":[" ++ ("{\"id\":\"claude-c\"}," ** 99) ++
        "{\"id\":\"claude-c\"}],\"has_more\":false}";
    var transport: providers.testing.FakeTransport = .{
        .gpa = gpa,
        .replies = &.{ .{ .body = first_page }, .{ .body = last_page } },
    };
    defer transport.deinit();

    try std.testing.expectError(
        error.BadModelList,
        fetch(gpa, std.testing.io, transport.transport(), &.unbounded, &.{
            .identity = .api_key,
            .token = "sk-ant-key",
        }),
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.requests.items[1],
        "GET https://api.anthropic.com/v1/models?limit=100&after_id=claude-b\n",
    ));
}

test "a credential that cannot be a header refuses the list without a request" {
    const gpa = std.testing.allocator;
    var transport: providers.testing.FakeTransport = .{ .gpa = gpa };
    defer transport.deinit();
    for ([_]providers.Messages.Identity{ .subscription, .api_key }) |identity| {
        for ([_][]const u8{ "", "sk-ant\r\nx-injected: 1" }) |token| {
            try std.testing.expectError(
                error.BadModelListCredentials,
                fetch(gpa, std.testing.io, transport.transport(), &.unbounded, &.{
                    .identity = identity,
                    .token = token,
                }),
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}

test "an expired deadline refuses the list without a request" {
    const io = std.testing.io;
    var transport: providers.testing.FakeTransport = .{ .gpa = std.testing.allocator };
    defer transport.deinit();
    const expired: core.timeout.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetch(std.testing.allocator, io, transport.transport(), &expired, &.{
            .identity = .api_key,
            .token = "sk-ant-key",
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}

test parse {
    const gpa = std.testing.allocator;
    const page = try parse(gpa, sample);
    defer page.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), page.models.len);
    try std.testing.expect(page.cursor == null);

    const opus = page.models[0];
    try std.testing.expectEqualStrings("claude-opus-4-8", opus.name());
    try std.testing.expectEqual(@as(?u64, 1_000_000), opus.context_window);
    try std.testing.expectEqual(@as(?u32, 128_000), opus.tokens_max);
    for (comptime std.enums.values(core.Provider.Effort)) |level|
        try std.testing.expect(opus.efforts.contains(level));
    try std.testing.expectEqual(Model.Thinking.supported, opus.thinking);

    const sonnet = page.models[1];
    try std.testing.expect(!sonnet.efforts.contains(.xhigh));
    try std.testing.expectEqual(@as(?core.Provider.Effort, .high), sonnet.fold(.xhigh));
    try std.testing.expectEqual(@as(?core.Provider.Effort, .max), sonnet.fold(.max));

    const haiku = page.models[2];
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", haiku.name());
    try std.testing.expectEqual(Model.Thinking.unsupported, haiku.thinking);
    try std.testing.expect(haiku.fold(.high) == null);
    try std.testing.expect(haiku.efforts_denied);
    try std.testing.expectEqual(@as(?u32, 64_000), haiku.tokens_max);
    try std.testing.expect(haiku.price == null);
}

test "a malformed entry is skipped" {
    const gpa = std.testing.allocator;
    const page = try parse(gpa,
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
    try std.testing.expectEqualStrings("kept", page.cursor.?);
    try std.testing.expectEqual(@as(?u32, null), page.models[0].tokens_max);
}

test "an id that a request line cannot carry never becomes a cursor" {
    const gpa = std.testing.allocator;
    const page = try parse(gpa,
        \\{ "data": [
        \\  { "id": "claude-opus-4-8", "max_input_tokens": 10 },
        \\  { "id": "split\r\nx-injected: 1", "max_input_tokens": 10 },
        \\  { "id": "break\nx-injected: 1", "max_input_tokens": 10 },
        \\  { "id": "claude&limit=1", "max_input_tokens": 10 }
        \\], "has_more": true }
    );
    defer page.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), page.models.len);
    const cursor = page.cursor.?;
    try std.testing.expectEqualStrings("claude-opus-4-8", cursor);
    try std.testing.expect(std.mem.indexOfAny(u8, cursor, "\r\n&?# ") == null);
}
