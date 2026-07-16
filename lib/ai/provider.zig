//! The seam between the neutral agent loop and concrete model providers. A
//! `Client` is a live connection to whichever provider the session selected; it
//! serializes a neutral `llm.Request`, sends it, and hands back a `Stream` of
//! neutral `llm.Event`s. Each provider is a union arm, so adding one is a new
//! arm plus its module — the loop and tools never change.

const std = @import("std");

const anthropic = @import("anthropic/root.zig");
const llm = @import("llm.zig");
const net = @import("net.zig");
const openai = @import("openai/root.zig");

const openai_url = "https://api.openai.com/v1/responses";
const codex_url = "https://chatgpt.com/backend-api/codex/responses";

/// What a client needs to authenticate, tagged by the account it belongs to. A
/// subscription account holds an OAuth `Auth` (owned by the caller, refreshed on
/// demand); an API account holds a bare key (owned by the caller). The active tag
/// picks the account, so `Client.init` needs no separate selector.
pub const Credentials = union(llm.Account) {
    anthropic_api: []const u8,
    anthropic_subscription: *anthropic.Auth,
    openai_api: []const u8,
    openai_subscription: *openai.Auth,
};

pub const Client = union(llm.Account) {
    anthropic_api: ApiKey,
    anthropic_subscription: AnthropicSubscription,
    openai_api: ApiKey,
    openai_subscription: OpenaiSubscription,

    const ApiKey = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        key: []const u8,
        timeouts: net.Timeouts,
    };

    const AnthropicSubscription = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        auth: *anthropic.Auth,
        timeouts: net.Timeouts,
    };

    const OpenaiSubscription = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        auth: *openai.Auth,
        timeouts: net.Timeouts,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        credentials: Credentials,
        timeouts: net.Timeouts,
    ) Client {
        return switch (credentials) {
            .anthropic_api => |key| .{ .anthropic_api = .{ .gpa = gpa, .io = io, .key = key, .timeouts = timeouts } },
            .anthropic_subscription => |auth| .{ .anthropic_subscription = .{ .gpa = gpa, .io = io, .auth = auth, .timeouts = timeouts } },
            .openai_api => |key| .{ .openai_api = .{ .gpa = gpa, .io = io, .key = key, .timeouts = timeouts } },
            .openai_subscription => |auth| .{ .openai_subscription = .{ .gpa = gpa, .io = io, .auth = auth, .timeouts = timeouts } },
        };
    }

    /// The account backing this client — vendor and billing product.
    pub fn account(self: *const Client) llm.Account {
        return std.meta.activeTag(self.*);
    }

    /// The vendor backing this client, keying the model table and the wire
    /// serializer both accounts of a vendor share.
    pub fn provider(self: *const Client) llm.Provider {
        return llm.provider(self.account());
    }

    /// Open a streaming request for `request`, filling `out` in place. On
    /// success the caller owns `out` and must `deinit` it.
    pub fn send(self: *Client, out: *Stream, request: llm.Request) !void {
        switch (self.*) {
            .anthropic_api => |*client| {
                const body = try anthropic.wire.serialize(client.gpa, request, .anthropic_api);
                defer client.gpa.free(body);
                out.* = .{ .anthropic_api = undefined };
                var transport: anthropic.Transport = .{
                    .gpa = client.gpa,
                    .io = client.io,
                    .timeouts = client.timeouts,
                    .identity = .{ .api_key = client.key },
                };
                try transport.send(&out.anthropic_api, body);
            },
            .anthropic_subscription => |*client| {
                const token = try client.auth.accessToken();
                const body = try anthropic.wire.serialize(client.gpa, request, .anthropic_subscription);
                defer client.gpa.free(body);
                out.* = .{ .anthropic_subscription = undefined };
                var transport: anthropic.Transport = .{
                    .gpa = client.gpa,
                    .io = client.io,
                    .timeouts = client.timeouts,
                    .identity = .{ .subscription = token },
                };
                try transport.send(&out.anthropic_subscription, body);
            },
            .openai_api => |*client| {
                const body = try openai.wire.serialize(client.gpa, request, .openai_api);
                defer client.gpa.free(body);
                out.* = .{ .openai_api = undefined };
                var transport: openai.Transport = .{
                    .gpa = client.gpa,
                    .io = client.io,
                    .timeouts = client.timeouts,
                    .endpoint = openai_url,
                    .account_id = "",
                };
                try transport.send(&out.openai_api, body, client.key);
            },
            .openai_subscription => |*client| {
                const token = try client.auth.accessToken();
                const body = try openai.wire.serialize(client.gpa, request, .openai_subscription);
                defer client.gpa.free(body);
                out.* = .{ .openai_subscription = undefined };
                var transport: openai.Transport = .{
                    .gpa = client.gpa,
                    .io = client.io,
                    .timeouts = client.timeouts,
                    .endpoint = codex_url,
                    .account_id = client.auth.accountId(),
                };
                try transport.send(&out.openai_subscription, body, token);
            },
        }
    }
};

/// A single request in flight, decoding to neutral `llm.Event`s. Both accounts of
/// a vendor share that vendor's transport stream — they differ only in how the
/// request was sent, not in how the response decodes.
pub const Stream = union(llm.Account) {
    anthropic_api: anthropic.Transport.Stream,
    anthropic_subscription: anthropic.Transport.Stream,
    openai_api: openai.Transport.Stream,
    openai_subscription: openai.Transport.Stream,

    pub fn deinit(self: *Stream) void {
        switch (self.*) {
            inline else => |*stream| stream.deinit(),
        }
    }

    /// Whether the request head reported success. A false result means the
    /// stream carries an error body, not events; read it with `errorText`.
    pub fn ok(self: *const Stream) bool {
        return switch (self.*) {
            inline else => |*stream| stream.ok(),
        };
    }

    /// Error body text when the request failed; empty otherwise.
    pub fn errorText(self: *const Stream) []const u8 {
        return switch (self.*) {
            inline else => |*stream| stream.errorText(),
        };
    }

    /// Whether a failed head (see `ok`) is worth retrying — a rate-limit or a
    /// transient server status the provider marks retryable.
    pub fn retryable(self: *const Stream) bool {
        return switch (self.*) {
            inline else => |*stream| stream.retryable(),
        };
    }

    /// The server's requested wait before a retry (`retry-after`) in
    /// milliseconds, or null when it gave none.
    pub fn retryAfterMs(self: *const Stream) ?u64 {
        return switch (self.*) {
            inline else => |*stream| stream.retryAfterMs(),
        };
    }

    /// Next decoded event, or null at end of stream.
    pub fn next(self: *Stream) !?llm.Event {
        return switch (self.*) {
            inline else => |*stream| stream.next(),
        };
    }

    /// Usage accumulated over this stream so far, before its stop event; whatever
    /// counts the provider has delivered up to now.
    pub fn usageSoFar(self: *const Stream) llm.Usage {
        return switch (self.*) {
            inline else => |*stream| stream.usageSoFar(),
        };
    }
};

test "init selects the arm matching the credentials, with the right vendor" {
    const gpa = std.testing.allocator;
    const subscription = Client.init(gpa, std.testing.io, .{ .anthropic_subscription = undefined }, .{});
    try std.testing.expectEqual(llm.Account.anthropic_subscription, subscription.account());
    try std.testing.expectEqual(llm.Provider.anthropic, subscription.provider());
    const anthropic_key = Client.init(gpa, std.testing.io, .{ .anthropic_api = "sk-ant" }, .{});
    try std.testing.expectEqual(llm.Account.anthropic_api, anthropic_key.account());
    try std.testing.expectEqual(llm.Provider.anthropic, anthropic_key.provider());
    const openai_key = Client.init(gpa, std.testing.io, .{ .openai_api = "sk-test" }, .{});
    try std.testing.expectEqual(llm.Account.openai_api, openai_key.account());
    try std.testing.expectEqual(llm.Provider.openai, openai_key.provider());
    const codex = Client.init(gpa, std.testing.io, .{ .openai_subscription = undefined }, .{});
    try std.testing.expectEqual(llm.Account.openai_subscription, codex.account());
    try std.testing.expectEqual(llm.Provider.openai, codex.provider());
}

test "usageSoFar reads accumulated usage through the stream seam" {
    var stream: Stream = .{ .anthropic_subscription = undefined };
    stream.anthropic_subscription.usage = .{ .input = 7, .output = 3, .cache_read = 90 };
    try std.testing.expectEqual(@as(u64, 7), stream.usageSoFar().input);
    try std.testing.expectEqual(@as(u64, 3), stream.usageSoFar().output);
    try std.testing.expectEqual(@as(u64, 90), stream.usageSoFar().cache_read);
}
