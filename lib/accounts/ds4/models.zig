const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const json = @import("../json.zig");
const Model = @import("../Model.zig");
const paging = @import("../paging.zig");
const responses = @import("../responses/root.zig");

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    deadline: *const core.timeout.Deadline,
    base_url: []const u8,
) paging.Error![]Model {
    const endpoint = try std.fmt.allocPrint(gpa, "{s}/models", .{base_url});
    defer gpa.free(endpoint);
    return responses.models.fetch(gpa, io, transport, deadline, &.{
        .endpoint = endpoint,
        .token = null,
        .decoder = parse,
    });
}

fn parse(gpa: std.mem.Allocator, body: []const u8) error{ OutOfMemory, BadModelList }![]Model {
    const envelope = try json.envelope(gpa, body, &.{
        .field = "data",
        .entries_max = paging.entries_max,
    });
    defer envelope.deinit();
    return json.models(gpa, envelope.entries, decode);
}

fn decode(value: *const std.json.Value) ?Model {
    const object = providers.json.object(value) orelse return null;
    const id = providers.json.string(object.getPtr("id")) orelse return null;
    var model = Model.init(id) catch return null;
    if (providers.json.string(object.getPtr("name"))) |engine| model.setEngine(engine) catch {};
    model.context_window = json.positive(u64, object.getPtr("context_length"));
    model.thinking = .supported;
    model.tools = .supported;
    model.addEffort(.high);
    model.addEffort(.max);
    return model;
}

test parse {
    const models = try parse(std.testing.allocator, sample);
    defer std.testing.allocator.free(models);

    try std.testing.expectEqual(@as(usize, 3), models.len);
    const flash = models[0];
    try std.testing.expectEqualStrings("deepseek-v4-flash", flash.name());
    try std.testing.expectEqualStrings("DeepSeek V4 Flash", flash.engineName());
    try std.testing.expectEqual(@as(?u64, 1_048_576), flash.context_window);
    try std.testing.expectEqual(@as(?u32, null), flash.tokens_max);
    try std.testing.expectEqual(Model.Thinking.supported, flash.thinking);
    try std.testing.expectEqual(Model.Tools.supported, flash.tools);
    try std.testing.expect(flash.efforts.contains(.high));
    try std.testing.expect(flash.efforts.contains(.max));
    try std.testing.expect(!flash.efforts.contains(.medium));
    try std.testing.expectEqualStrings("", flash.servedName());
    try std.testing.expect(flash.price == null);

    const pro = models[1];
    try std.testing.expectEqualStrings("deepseek-v4-pro", pro.name());
    try std.testing.expectEqual(@as(?u64, null), pro.context_window);
    try std.testing.expectEqual(@as(?u32, null), pro.tokens_max);

    try std.testing.expectEqualStrings("missing-name", models[2].name());
    try std.testing.expectEqualStrings("", models[2].engineName());
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

test "an expired deadline refuses the list without a request" {
    const io = std.testing.io;
    var transport: providers.testing.FakeTransport = .{ .gpa = std.testing.allocator };
    defer transport.deinit();
    const expired: core.timeout.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetch(
            std.testing.allocator,
            io,
            transport.transport(),
            &expired,
            "http://127.0.0.1:8000/v1",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}
