//! The seam between the neutral agent loop and concrete model providers. A
//! `Client` is a live connection to whichever provider the session selected; it
//! serializes a neutral `llm.Request`, sends it, and hands back a `Stream` of
//! neutral `llm.Event`s. Each provider account is a `Credentials`/`Stream` union
//! arm, so adding one is a new arm plus its module — the loop and tools never
//! change.

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
    anthropic_subscription: *anthropic.Auth,
    anthropic_api: []const u8,
    openai_subscription: *openai.Auth,
    openai_api: []const u8,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    credentials: Credentials,
    timeouts: net.Timeouts,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        credentials: Credentials,
        timeouts: net.Timeouts,
    ) Client {
        return .{ .gpa = gpa, .io = io, .credentials = credentials, .timeouts = timeouts };
    }

    /// The account backing this client — vendor and billing product.
    pub fn account(self: *const Client) llm.Account {
        return std.meta.activeTag(self.credentials);
    }

    /// Open a streaming request for `request`, filling `out` in place. On
    /// success the caller owns `out` and must `deinit` it.
    pub fn send(self: *Client, out: *Stream, request: *const llm.Request) !void {
        switch (self.credentials) {
            inline .anthropic_subscription, .anthropic_api => |credential, tag| {
                const identity: anthropic.Transport.Identity = if (tag == .anthropic_subscription)
                    .{ .subscription = try credential.accessToken() }
                else
                    .{ .api_key = credential };
                const body = try anthropic.wire.serialize(self.gpa, request, tag);
                defer self.gpa.free(body);
                out.* = @unionInit(Stream, @tagName(tag), undefined);
                var transport: anthropic.Transport = .{
                    .gpa = self.gpa,
                    .io = self.io,
                    .timeouts = self.timeouts,
                    .identity = identity,
                };
                try transport.send(&@field(out.*, @tagName(tag)), body);
            },
            inline .openai_subscription, .openai_api => |credential, tag| {
                const subscription = tag == .openai_subscription;
                const token = if (subscription) try credential.accessToken() else credential;
                const body = try openai.wire.serialize(self.gpa, request, tag);
                defer self.gpa.free(body);
                out.* = @unionInit(Stream, @tagName(tag), undefined);
                var transport: openai.Transport = .{
                    .gpa = self.gpa,
                    .io = self.io,
                    .timeouts = self.timeouts,
                    .endpoint = if (subscription) codex_url else openai_url,
                    .account_id = if (subscription) credential.accountId() else "",
                };
                try transport.send(&@field(out.*, @tagName(tag)), .{
                    .body = body,
                    .access_token = token,
                });
            },
        }
    }
};

/// A single request in flight, decoding to neutral `llm.Event`s. Both accounts of
/// a vendor share that vendor's transport stream — they differ only in how the
/// request was sent, not in how the response decodes.
pub const Stream = union(llm.Account) {
    anthropic_subscription: anthropic.Transport.Stream,
    anthropic_api: anthropic.Transport.Stream,
    openai_subscription: openai.Transport.Stream,
    openai_api: openai.Transport.Stream,

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

    /// Whether the current failure is worth retrying — a transient streamed
    /// error, rate limit, or server status the provider marks retryable.
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

    /// The subscription allowance the response head reported, or null when the
    /// account or backend sends none. Valid as soon as the head is read, so it
    /// outlives a stream that errors or is cancelled before its stop event.
    pub fn quotaSoFar(self: *const Stream) ?llm.Quota {
        return switch (self.*) {
            inline else => |*stream| stream.quotaSoFar(),
        };
    }
};

test "init selects the arm matching the credentials" {
    const gpa = std.testing.allocator;
    const subscription = Client.init(
        gpa,
        std.testing.io,
        .{ .anthropic_subscription = undefined },
        .{},
    );
    try std.testing.expectEqual(llm.Account.anthropic_subscription, subscription.account());
    const anthropic_key = Client.init(gpa, std.testing.io, .{ .anthropic_api = "sk-ant" }, .{});
    try std.testing.expectEqual(llm.Account.anthropic_api, anthropic_key.account());
    const openai_key = Client.init(gpa, std.testing.io, .{ .openai_api = "sk-test" }, .{});
    try std.testing.expectEqual(llm.Account.openai_api, openai_key.account());
    const codex = Client.init(gpa, std.testing.io, .{ .openai_subscription = undefined }, .{});
    try std.testing.expectEqual(llm.Account.openai_subscription, codex.account());
}

test "usageSoFar reads accumulated usage through the stream seam" {
    var stream: Stream = .{ .anthropic_subscription = undefined };
    stream.anthropic_subscription.usage = .{ .input = 7, .output = 3, .cache_read = 90 };
    try std.testing.expectEqual(@as(u64, 7), stream.usageSoFar().input);
    try std.testing.expectEqual(@as(u64, 3), stream.usageSoFar().output);
    try std.testing.expectEqual(@as(u64, 90), stream.usageSoFar().cache_read);
}

test "quotaSoFar reads the head allowance through the stream seam" {
    var codex: Stream = .{ .openai_subscription = undefined };
    codex.openai_subscription.quota = .{ .primary = .{ .used_percent = 40, .window_minutes = 300 } };
    try std.testing.expectEqual(@as(f64, 40), codex.quotaSoFar().?.primary.?.used_percent);

    // Anthropic surfaces no subscription allowance through the seam.
    const claude: Stream = .{ .anthropic_subscription = undefined };
    try std.testing.expect(claude.quotaSoFar() == null);
}
