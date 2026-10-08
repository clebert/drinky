const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const json = @import("../json.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");
const paging = @import("../paging.zig");

const body_bytes_max = 4 * 1024 * 1024;

const List = struct {
    endpoint: []const u8,
    token: []const u8,
};

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    deadline: *const core.timeout.Deadline,
    list: *const List,
) paging.Error![]Model {
    return deadline.run(io, request, .{ gpa, io, transport, list }, release);
}

fn request(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    list: *const List,
) ![]Model {
    if (!providers.Transport.validHeaderValue(list.token)) return error.BadModelListCredentials;
    const authorization = try gpa.print("Bearer {s}", .{list.token});
    defer gpa.free(authorization);

    const body = try net.getBody(gpa, io, transport, &.{
        .method = .GET,
        .url = list.endpoint,
        .authorization = authorization,
        .headers = &.{net.accept_json},
    }, body_bytes_max);
    defer gpa.free(body);

    return parse(gpa, body);
}

fn release(models: *const []Model, args: *const std.meta.ArgsTuple(@TypeOf(request))) void {
    args[0].free(models.*);
}

fn parse(gpa: std.mem.Allocator, body: []const u8) error{ OutOfMemory, BadModelList }![]Model {
    const envelope = try json.envelope(gpa, body, &.{
        .field = "data",
        .entries_max = paging.entries_max,
    });
    defer envelope.deinit();

    var models: std.ArrayList(Model) = .empty;
    errdefer models.deinit(gpa);
    for (envelope.entries) |*value| {
        const entry = providers.json.object(value) orelse continue;
        const id = providers.json.string(entry.getPtr("id")) orelse continue;
        const model = Model.init(id) catch continue;
        try models.append(gpa, model);
        const aliases = providers.json.array(entry.getPtr("aliases")) orelse continue;
        for (aliases.items) |*alias_value| {
            const alias = providers.json.string(alias_value) orelse continue;
            if (std.mem.eql(u8, alias, id)) continue;
            var named = Model.init(alias) catch continue;
            named.serveAs(id) catch continue;
            try models.append(gpa, named);
        }
    }
    return models.toOwnedSlice(gpa);
}

test "an expired deadline refuses the list without a request" {
    const io = std.testing.io;
    var transport: providers.testing.FakeTransport = .{ .gpa = std.testing.allocator };
    defer transport.deinit();
    const expired: core.timeout.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetch(std.testing.allocator, io, transport.transport(), &expired, &.{
            .endpoint = "https://api.openai.com/v1/models",
            .token = "sk-openai",
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}

test parse {
    const gpa = std.testing.allocator;
    const models = try parse(gpa,
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
    try std.testing.expect(models[0].fold(.high) == null);
    try std.testing.expectEqual(@as(?u64, null), models[2].context_window);
    try std.testing.expectEqualStrings("grok-4.20-0309-reasoning", models[3].name());
    try std.testing.expectEqualStrings("", models[3].servedName());
    try std.testing.expectEqualStrings("grok-4.20", models[4].name());
    try std.testing.expectEqualStrings("grok-4.20-0309-reasoning", models[4].servedName());
}
