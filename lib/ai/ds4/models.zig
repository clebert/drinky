//! The model list of a local DwarfStar server. The server answers in the
//! OpenRouter list shape, but its fields describe the local engine directly.

const std = @import("std");

const json = @import("../json.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");
const openai_models = @import("../openai/models.zig");

const entry_count_max = 1024;

/// Every model that the server at `base_url` offers. The caller owns the result.
/// The deadline bounds the credential-free request.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    base_url: []const u8,
) ![]Model {
    const endpoint = try std.fmt.allocPrint(gpa, "{s}/models", .{base_url});
    defer gpa.free(endpoint);
    return openai_models.fetchList(gpa, io, deadline, &.{
        .endpoint = endpoint,
        .token = null,
        .decoder = parse,
    });
}

/// Decode the local compatibility table. A malformed envelope rejects the
/// body. A malformed entry drops alone.
fn parse(gpa: std.mem.Allocator, body: []const u8) ![]Model {
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
    return models.toOwnedSlice(gpa);
}

fn decode(value: std.json.Value) ?Model {
    const object = json.object(value) orelse return null;
    const id = json.string(object.get("id")) orelse return null;
    var model = Model.init(id) catch return null;
    // A missing or unusable label still leaves the request id.
    if (json.string(object.get("name"))) |engine| model.setEngine(engine) catch {};
    model.context_window = positive(object.get("context_length"));
    if (json.object(object.get("top_provider"))) |top_provider| {
        if (positive(top_provider.get("max_completion_tokens"))) |limit|
            model.tokens_max = std.math.cast(u32, limit);
    }
    model.thinking = .supported;
    model.tools = .supported;
    model.addEffort(.high);
    model.addEffort(.max);
    return model;
}

fn positive(value: ?std.json.Value) ?u64 {
    const found = json.integer(value) orelse return null;
    return if (found > 0) @intCast(found) else null;
}

const sample =
    \\{ "data": [
    \\  { "id": "deepseek-v4-flash", "name": "DeepSeek V4 Flash",
    \\    "context_length": 1048576,
    \\    "top_provider": { "max_completion_tokens": 131072 },
    \\    "aliases": ["ignored-alias"], "pricing": { "prompt": "0" } },
    \\  { "id": "deepseek-v4-pro", "name": "DeepSeek V4 Flash",
    \\    "context_length": null, "top_provider": {} },
    \\  { "id": "missing-name", "context_length": 1 },
    \\  "not-an-object" ] }
;

test parse {
    const models = try parse(std.testing.allocator, sample);
    defer std.testing.allocator.free(models);

    try std.testing.expectEqual(@as(usize, 3), models.len);
    const flash = models[0];
    try std.testing.expectEqualStrings("deepseek-v4-flash", flash.name());
    try std.testing.expectEqualStrings("DeepSeek V4 Flash", flash.engineName());
    try std.testing.expectEqual(@as(?u64, 1_048_576), flash.context_window);
    try std.testing.expectEqual(@as(?u32, 131_072), flash.tokens_max);
    try std.testing.expectEqual(Model.Thinking.supported, flash.thinking);
    try std.testing.expectEqual(Model.Tools.supported, flash.tools);
    try std.testing.expect(flash.offers(.high));
    try std.testing.expect(flash.offers(.max));
    try std.testing.expect(!flash.offers(.medium));
    try std.testing.expectEqualStrings("", flash.servedName());
    try std.testing.expect(flash.price == null);

    // Missing limits state no fact. The local thinking and tool facts keep the row.
    const pro = models[1];
    try std.testing.expectEqualStrings("deepseek-v4-pro", pro.name());
    try std.testing.expectEqual(@as(?u64, null), pro.context_window);
    try std.testing.expectEqual(@as(?u32, null), pro.tokens_max);

    try std.testing.expectEqualStrings("missing-name", models[2].name());
    try std.testing.expectEqualStrings("", models[2].engineName());
}

test "a missing engine label still keeps the request id" {
    const models = try parse(std.testing.allocator,
        \\{ "data": [ { "id": "kept", "context_length": 1 } ] }
    );
    defer std.testing.allocator.free(models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("kept", models[0].name());
    try std.testing.expectEqualStrings("", models[0].engineName());
}

test "an engine label that the picker cannot show still keeps the row" {
    const long = "x" ** (Model.engine_bytes_max + 1);
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        \\{{ "data": [
        \\  {{ "id": "control", "name": "bad\nlabel" }},
        \\  {{ "id": "long", "name": "{s}" }} ] }}
    ,
        .{long},
    );
    defer std.testing.allocator.free(body);
    const models = try parse(std.testing.allocator, body);
    defer std.testing.allocator.free(models);

    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("control", models[0].name());
    try std.testing.expectEqualStrings("", models[0].engineName());
    try std.testing.expectEqualStrings("long", models[1].name());
    try std.testing.expectEqualStrings("", models[1].engineName());
    try std.testing.expectEqual(Model.Thinking.supported, models[0].thinking);
}

test "the decoder rejects a malformed envelope and bounds the entries" {
    try std.testing.expectError(error.BadModelList, parse(std.testing.allocator, "{}"));
    try std.testing.expectError(error.BadModelList, parse(std.testing.allocator, "[]"));
    const at_max = "{\"data\":[{}" ++ (",{}" ** (entry_count_max - 1)) ++ "]}";
    std.testing.allocator.free(try parse(std.testing.allocator, at_max));
    const over = "{\"data\":[{}" ++ (",{}" ** entry_count_max) ++ "]}";
    try std.testing.expectError(error.BadModelList, parse(std.testing.allocator, over));
}

test "an expired deadline refuses the list without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetch(std.testing.allocator, io, expired, "http://127.0.0.1:8000/v1"),
    );
}
