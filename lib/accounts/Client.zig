const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Account = @import("Account.zig");
const deepseek = @import("deepseek/root.zig");
const net = @import("net.zig");
const openrouter = @import("openrouter/root.zig");
const testing = @import("testing.zig");
const xai = @import("xai/root.zig");

const Client = @This();

gpa: std.mem.Allocator,
io: std.Io,
account: *const Account,
credential: providers.Credential,
endpoint: []const u8,
codex_account_id: []const u8,
dialect: Dialect,
transport: ?providers.Transport,
http: providers.Http,
inner: providers.Provider,
held: ?core.Provider.Event,

pub const Options = struct {
    account: *const Account,
    credential: providers.Credential,
    timeouts: providers.Transport.Timeouts = .{},
    codex_account_id: []const u8 = "",
    project: []const u8 = "",
    location: providers.Gemini.Location = .global,
    transport: ?providers.Transport = null,
};

const Dialect = union(enum) {
    responses: providers.Responses,
    messages: providers.Messages,
    gemini: providers.Gemini,

    fn dialect(self: *Dialect) providers.Dialect {
        return switch (self.*) {
            inline else => |*state| state.dialect(),
        };
    }

    fn deinit(self: *Dialect) void {
        switch (self.*) {
            inline else => |*state| state.deinit(),
        }
    }
};

const vtable: core.Provider.VTable = .{ .open = open, .next = next, .close = close };

pub fn init(
    self: *Client,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
) error{OutOfMemory}!void {
    const account = options.account;
    self.gpa = gpa;
    self.io = io;
    self.account = account;
    self.credential = options.credential;
    self.endpoint = "";
    self.codex_account_id = "";
    self.held = null;
    self.transport = options.transport;
    errdefer gpa.free(self.endpoint);
    errdefer gpa.free(self.codex_account_id);
    switch (account.dialect) {
        .responses => |responses| {
            self.endpoint = try std.fmt.allocPrint(gpa, "{s}/responses", .{responses.base_url});
            if (responses.codex) {
                self.codex_account_id = try gpa.dupe(u8, options.codex_account_id);
            }
            self.dialect = .{ .responses = .init(gpa, .{
                .account = account.id,
                .endpoint = self.endpoint,
                .codex_account_id = self.codex_account_id,
                .switches = responses.switches,
            }) };
        },
        .messages => |identity| {
            self.dialect = .{ .messages = .init(gpa, .{
                .account = account.id,
                .identity = identity,
            }) };
        },
        .gemini => {
            self.dialect = .{ .gemini = .init(gpa, .{
                .account = account.id,
                .project = options.project,
                .location = options.location,
            }) };
        },
    }
    self.http = .init(gpa, io);
    self.inner = .init(gpa, io, &.{
        .dialect = self.dialect.dialect(),
        .transport = options.transport orelse self.http.transport(),
        .credential = options.credential,
        .timeouts = options.timeouts,
    });
}

pub fn deinit(self: *Client) void {
    self.inner.deinit();
    self.http.deinit();
    self.dialect.deinit();
    self.gpa.free(self.endpoint);
    self.gpa.free(self.codex_account_id);
}

pub fn provider(self: *Client) core.Provider {
    return .{ .ptr = self, .vtable = &vtable };
}

fn open(ptr: *anyopaque, request: *const core.Provider.Request) core.Provider.Error!void {
    const self: *Client = @ptrCast(@alignCast(ptr));
    self.held = null;
    return self.inner.provider().open(request);
}

fn next(ptr: *anyopaque) core.Provider.Error!?core.Provider.Event {
    const self: *Client = @ptrCast(@alignCast(ptr));
    if (self.held) |event| {
        self.held = null;
        return event;
    }
    const event = (try self.inner.provider().next()) orelse return null;
    if (event != .stopped) return event;
    const report = (try self.usage()) orelse return event;
    self.held = event;
    return report;
}

fn close(ptr: *anyopaque) void {
    const self: *Client = @ptrCast(@alignCast(ptr));
    self.held = null;
    self.inner.provider().close();
}

fn usage(self: *Client) error{Canceled}!?core.Provider.Event {
    const url = switch (self.account.usage) {
        .none, .head => return null,
        .xai_billing, .openrouter_credits, .deepseek_balance => |url| url,
    };
    const token = (try settle(self.credential.token(self.gpa))) orelse return null;
    defer self.gpa.free(token);
    const body = (try settle(net.getJson(self.gpa, self.io, self.transport, &.{
        .url = url,
        .bearer = token,
    }))) orelse return null;
    defer self.gpa.free(body);
    return switch (self.account.usage) {
        .xai_billing => quotaEvent(xai.quota.parse(
            self.gpa,
            body,
            std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        )),
        .openrouter_credits => creditsEvent(openrouter.credits.parse(self.gpa, body)),
        .deepseek_balance => creditsEvent(deepseek.balance.parse(self.gpa, body)),
        .none, .head => unreachable,
    };
}

fn quotaEvent(parsed: error{OutOfMemory}!?core.Provider.Quota) ?core.Provider.Event {
    const quota = (parsed catch return null) orelse return null;
    return .{ .quota = quota };
}

fn creditsEvent(parsed: error{OutOfMemory}!?core.Provider.Credits) ?core.Provider.Event {
    const credits = (parsed catch return null) orelse return null;
    return .{ .credits = credits };
}

fn settle(fetched: anytype) error{Canceled}!@typeInfo(@TypeOf(fetched)).error_union.payload {
    return fetched catch |err| switch (err) {
        error.Canceled => error.Canceled,
        else => null,
    };
}

test "a client of a usage source reports the pool before the stop, and a failed read reports none" {
    const gpa = std.testing.allocator;
    const account = &Account.table[testing.deepseek_api_key];
    var transport: providers.testing.FakeTransport = .{
        .gpa = gpa,
        .replies = &.{
            .{ .body = providers.testing.reply_stream },
            .{ .body = "{\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"7.14\"}]}" },
            .{ .body = providers.testing.reply_stream },
            .{ .status = .internal_server_error },
        },
    };
    defer transport.deinit();
    var credential: providers.testing.FakeCredential = .{ .tokens = &.{"sk-deepseek"} };
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, &.{
        .account = account,
        .credential = credential.credential(),
        .transport = transport.transport(),
    });
    defer client.deinit();

    const first = try traceReply(gpa, &client);
    defer gpa.free(first);
    try std.testing.expectEqualStrings(
        \\text:done
        \\message:done
        \\usage:10/2/0/0
        \\credits:7.14/0
        \\stopped:complete|
        \\
    , first);
    try std.testing.expect(std.mem.indexOf(
        u8,
        transport.requests.items[0],
        "POST https://api.deepseek.com/v1/responses\n",
    ) != null);
    try std.testing.expectEqualStrings(
        "GET https://api.deepseek.com/user/balance\nauthorization: Bearer sk-deepseek\n" ++
            "accept: application/json\n\n",
        transport.requests.items[1],
    );

    const second = try traceReply(gpa, &client);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(
        \\text:done
        \\message:done
        \\usage:10/2/0/0
        \\stopped:complete|
        \\
    , second);
}

const HeldCredential = struct {
    io: std.Io,
    calls: u32 = 0,
    reached: std.Io.Event = .unset,
    canceled: bool = false,

    const token_vtable: providers.Credential.VTable = .{ .token = token, .renew = renew };

    fn credential(self: *HeldCredential) providers.Credential {
        return .{ .ptr = self, .vtable = &token_vtable };
    }

    fn token(ptr: *anyopaque, gpa: std.mem.Allocator) providers.Credential.Error!?[]const u8 {
        const self: *HeldCredential = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.calls == 1) return try gpa.dupe(u8, "sk-deepseek");
        self.reached.set(self.io);
        var never: std.Io.Event = .unset;
        never.wait(self.io) catch |err| {
            self.canceled = true;
            return err;
        };
        unreachable;
    }

    fn renew(ptr: *anyopaque) providers.Credential.Error!bool {
        _ = ptr;
        return false;
    }
};

fn traceReply(gpa: std.mem.Allocator, client: *Client) providers.testing.TraceError![]u8 {
    return providers.testing.trace(gpa, client.provider(), &providers.testing.empty_request);
}

test "a cancel during the usage read ends the reply without its stop" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var transport: providers.testing.FakeTransport = .{
        .gpa = gpa,
        .replies = &.{.{ .body = providers.testing.reply_stream }},
    };
    defer transport.deinit();
    var credential: HeldCredential = .{ .io = io };
    var client: Client = undefined;
    try client.init(gpa, io, &.{
        .account = &Account.table[testing.deepseek_api_key],
        .credential = credential.credential(),
        .transport = transport.transport(),
    });
    defer client.deinit();

    var reading = try io.concurrent(traceReply, .{ gpa, &client });
    try credential.reached.wait(io);
    const text = reading.cancel(io) catch |err| {
        try std.testing.expectEqual(error.Canceled, err);
        try std.testing.expect(credential.canceled);
        try std.testing.expectEqual(@as(u32, 2), credential.calls);
        return;
    };
    gpa.free(text);
    return error.TestExpectedCanceled;
}

test "a client without a usage source passes the stream through" {
    const gpa = std.testing.allocator;
    var transport: providers.testing.FakeTransport = .{
        .gpa = gpa,
        .replies = &.{.{ .body = providers.testing.reply_stream }},
    };
    defer transport.deinit();
    var credential: providers.testing.FakeCredential = .{ .tokens = &.{"sk-openai"} };
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, &.{
        .account = &Account.table[testing.openai_api_key],
        .credential = credential.credential(),
        .transport = transport.transport(),
    });
    defer client.deinit();

    const actual = try traceReply(gpa, &client);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(
        \\text:done
        \\message:done
        \\usage:10/2/0/0
        \\stopped:complete|
        \\
    , actual);
    try std.testing.expect(std.mem.indexOf(
        u8,
        transport.requests.items[0],
        "POST https://api.openai.com/v1/responses\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        transport.requests.items[0],
        "authorization: Bearer sk-openai\n",
    ) != null);
}

test "a Codex client names the account in its header and a Gemini client its project" {
    const gpa = std.testing.allocator;
    var transport: providers.testing.FakeTransport = .{
        .gpa = gpa,
        .replies = &.{ .{ .body = "data: [DONE]\n\n" }, .{ .body = "" } },
    };
    defer transport.deinit();
    var credential: providers.testing.FakeCredential = .{ .tokens = &.{"token"} };

    var codex: Client = undefined;
    try codex.init(gpa, std.testing.io, &.{
        .account = &Account.table[testing.openai_plan],
        .credential = credential.credential(),
        .codex_account_id = "account-1",
        .transport = transport.transport(),
    });
    defer codex.deinit();
    const codex_trace = try traceReply(gpa, &codex);
    defer gpa.free(codex_trace);
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.requests.items[0],
        "POST https://chatgpt.com/backend-api/codex/responses\n",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        transport.requests.items[0],
        "chatgpt-account-id: account-1\n",
    ) != null);

    var gemini: Client = undefined;
    try gemini.init(gpa, std.testing.io, &.{
        .account = &Account.table[testing.google_cloud_key],
        .credential = credential.credential(),
        .project = "my-project",
        .location = .eu,
        .transport = transport.transport(),
    });
    defer gemini.deinit();
    const gemini_trace = try traceReply(gpa, &gemini);
    defer gpa.free(gemini_trace);
    try std.testing.expect(std.mem.startsWith(
        u8,
        transport.requests.items[1],
        "POST https://aiplatform.eu.rep.googleapis.com/v1/projects/my-project/locations/eu/" ++
            "publishers/google/models/model-a:streamGenerateContent?alt=sse\n",
    ));
}
