const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const json = @import("../json.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");
const paging = @import("../paging.zig");

const client_version = "0.0.0";
const codex_endpoint = "https://chatgpt.com/backend-api/codex/models?client_version=" ++
    client_version;
const body_bytes_max = 4 * 1024 * 1024;

const Subscription = struct {
    token: []const u8,
    account_id: []const u8,
};

pub fn fetchSubscription(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    deadline: *const core.timeout.Deadline,
    subscription: *const Subscription,
) paging.Error![]Model {
    return deadline.run(
        io,
        requestSubscription,
        .{ gpa, io, transport, subscription },
        releaseSubscription,
    );
}

fn requestSubscription(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    subscription: *const Subscription,
) ![]Model {
    if (!validSubscriptionCredentials(subscription))
        return error.BadModelListCredentials;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var list: providers.Transport.Request = .{
        .method = .GET,
        .url = codex_endpoint,
        .headers = &.{net.accept_json},
    };
    try providers.Responses.identify(arena.allocator(), &list, &.{
        .token = subscription.token,
        .codex_account_id = subscription.account_id,
    });
    const body = try net.getBody(gpa, io, transport, &list, body_bytes_max);
    defer gpa.free(body);

    return parseSubscription(gpa, body);
}

fn releaseSubscription(
    models: *const []Model,
    args: *const std.meta.ArgsTuple(@TypeOf(requestSubscription)),
) void {
    args[0].free(models.*);
}

fn validSubscriptionCredentials(subscription: *const Subscription) bool {
    if (!providers.Transport.validHeaderValue(subscription.token)) return false;
    return subscription.account_id.len == 0 or
        providers.Transport.validHeaderValue(subscription.account_id);
}

fn parseSubscription(
    gpa: std.mem.Allocator,
    body: []const u8,
) error{ OutOfMemory, BadModelList }![]Model {
    const envelope = try json.envelope(gpa, body, &.{
        .field = "models",
        .entries_max = paging.entries_max,
    });
    defer envelope.deinit();
    return json.models(gpa, envelope.entries, decodeSubscription);
}

fn decodeSubscription(value: *const std.json.Value) ?Model {
    const object = providers.json.object(value) orelse return null;
    if (hidden(object.getPtr("visibility"))) return null;
    const slug = providers.json.string(object.getPtr("slug")) orelse return null;
    var model = Model.init(slug) catch return null;

    model.context_window = json.positive(u64, object.getPtr("context_window")) orelse
        json.positive(u64, object.getPtr("max_context_window"));

    const levels = providers.json.array(object.getPtr("supported_reasoning_levels")) orelse
        return model;
    for (levels.items) |*entry| {
        const level = providers.json.object(entry) orelse continue;
        const name = providers.json.string(level.getPtr("effort")) orelse continue;
        model.addEffort(std.meta.stringToEnum(core.Provider.Effort, name) orelse continue);
    }
    return model;
}

fn hidden(value: ?*const std.json.Value) bool {
    const visibility = providers.json.string(value) orelse return false;
    return std.mem.eql(u8, visibility, "hide");
}

test "an expired deadline refuses the list without a request" {
    const io = std.testing.io;
    var transport: providers.testing.FakeTransport = .{ .gpa = std.testing.allocator };
    defer transport.deinit();
    const expired: core.timeout.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetchSubscription(std.testing.allocator, io, transport.transport(), &expired, &.{
            .token = "token",
            .account_id = "account",
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
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

test "the Codex list sends the Codex identity and omits the account headers without one" {
    const gpa = std.testing.allocator;
    var transport: providers.testing.FakeTransport = .{
        .gpa = gpa,
        .replies = &.{ .{ .body = codex_sample }, .{ .body = codex_sample } },
    };
    defer transport.deinit();

    const named = try fetchSubscription(gpa, std.testing.io, transport.transport(), &.unbounded, &.{
        .token = "token",
        .account_id = "account",
    });
    defer gpa.free(named);
    try std.testing.expectEqualStrings(
        "GET " ++ codex_endpoint ++ "\nauthorization: Bearer token\nuser-agent: drinky\n" ++
            "accept: application/json\nchatgpt-account-id: account\noriginator: drinky\n\n",
        transport.requests.items[0],
    );

    const anonymous = try fetchSubscription(
        gpa,
        std.testing.io,
        transport.transport(),
        &.unbounded,
        &.{ .token = "token", .account_id = "" },
    );
    defer gpa.free(anonymous);
    try std.testing.expectEqualStrings(
        "GET " ++ codex_endpoint ++ "\nauthorization: Bearer token\nuser-agent: drinky\n" ++
            "accept: application/json\n\n",
        transport.requests.items[1],
    );
}

test "the Codex guard accepts a credential that names no account" {
    const cases = [_]struct { subscription: Subscription, valid: bool }{
        .{ .subscription = .{ .token = "token", .account_id = "account" }, .valid = true },
        .{ .subscription = .{ .token = "token", .account_id = "" }, .valid = true },
        .{ .subscription = .{ .token = "", .account_id = "account" }, .valid = false },
        .{
            .subscription = .{ .token = "token\r\nx-injected: 1", .account_id = "account" },
            .valid = false,
        },
        .{
            .subscription = .{ .token = "token", .account_id = "account\nx-injected: 1" },
            .valid = false,
        },
    };
    for (&cases) |*case| {
        try std.testing.expectEqual(case.valid, validSubscriptionCredentials(&case.subscription));
    }
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
    try std.testing.expect(sol.efforts.contains(.low));
    try std.testing.expect(sol.efforts.contains(.max));
    try std.testing.expectEqual(Model.Thinking.unknown, sol.thinking);
    try std.testing.expect(sol.price == null);
    try std.testing.expectEqual(@as(?u32, null), sol.tokens_max);

    try std.testing.expectEqual(@as(?u64, 1_000_000), models[1].context_window);
    try std.testing.expectEqual(core.Provider.Effort.high, models[1].fold(.max).?);
    try std.testing.expectEqual(@as(usize, 2), models[1].efforts.count());
}

test "a malformed entry is skipped" {
    const gpa = std.testing.allocator;
    const models = try parseSubscription(gpa,
        \\{ "models": [ { "slug": "kept" }, { "display_name": "no slug" }, 7 ] }
    );
    defer gpa.free(models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("kept", models[0].name());
    try std.testing.expectEqual(@as(?u64, null), models[0].context_window);
}
