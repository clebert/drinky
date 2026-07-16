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

/// What a client needs to authenticate, tagged by the provider it belongs to.
/// Anthropic and Codex hold a subscription `Auth` (owned by the caller, refreshed
/// on demand); the API-key provider holds a bare key (owned by the caller). The
/// active tag picks the provider, so `Client.init` needs no separate selector.
pub const Credentials = union(llm.Provider) {
    anthropic: *anthropic.Auth,
    openai: []const u8,
    openai_codex: *openai.Auth,
};

pub const Client = union(llm.Provider) {
    anthropic: Anthropic,
    openai: Openai,
    openai_codex: Codex,

    const Anthropic = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        auth: *anthropic.Auth,
        timeouts: net.Timeouts,
    };

    const Openai = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        key: []const u8,
        timeouts: net.Timeouts,
    };

    const Codex = struct {
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
            .anthropic => |auth| .{ .anthropic = .{ .gpa = gpa, .io = io, .auth = auth, .timeouts = timeouts } },
            .openai => |key| .{ .openai = .{ .gpa = gpa, .io = io, .key = key, .timeouts = timeouts } },
            .openai_codex => |auth| .{ .openai_codex = .{ .gpa = gpa, .io = io, .auth = auth, .timeouts = timeouts } },
        };
    }

    /// The provider backing this client.
    pub fn kind(self: *const Client) llm.Provider {
        return std.meta.activeTag(self.*);
    }

    /// Open a streaming request for `request`, filling `out` in place. On
    /// success the caller owns `out` and must `deinit` it.
    pub fn send(self: *Client, out: *Stream, request: llm.Request) !void {
        switch (self.*) {
            .anthropic => |*client| {
                const token = try client.auth.accessToken();
                const body = try anthropic.wire.serialize(client.gpa, request);
                defer client.gpa.free(body);
                out.* = .{ .anthropic = undefined };
                var transport: anthropic.Transport = .{ .gpa = client.gpa, .io = client.io, .timeouts = client.timeouts };
                try transport.send(&out.anthropic, body, token);
            },
            .openai => |*client| {
                const body = try openai.wire.serialize(client.gpa, request, .openai);
                defer client.gpa.free(body);
                out.* = .{ .openai = undefined };
                var transport: openai.Transport = .{
                    .gpa = client.gpa,
                    .io = client.io,
                    .timeouts = client.timeouts,
                    .endpoint = openai_url,
                    .account_id = "",
                };
                try transport.send(&out.openai, body, client.key);
            },
            .openai_codex => |*client| {
                const token = try client.auth.accessToken();
                const body = try openai.wire.serialize(client.gpa, request, .openai_codex);
                defer client.gpa.free(body);
                out.* = .{ .openai_codex = undefined };
                var transport: openai.Transport = .{
                    .gpa = client.gpa,
                    .io = client.io,
                    .timeouts = client.timeouts,
                    .endpoint = codex_url,
                    .account_id = client.auth.accountId(),
                };
                try transport.send(&out.openai_codex, body, token);
            },
        }
    }
};

/// A single request in flight, decoding to neutral `llm.Event`s. The two openai
/// arms share the same transport stream — they differ only in how the request
/// was sent, not in how the response decodes.
pub const Stream = union(llm.Provider) {
    anthropic: anthropic.Transport.Stream,
    openai: openai.Transport.Stream,
    openai_codex: openai.Transport.Stream,

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

test "init selects the arm matching the credentials" {
    const gpa = std.testing.allocator;
    const anthropic_client = Client.init(gpa, std.testing.io, .{ .anthropic = undefined }, .{});
    try std.testing.expectEqual(llm.Provider.anthropic, anthropic_client.kind());
    const key_client = Client.init(gpa, std.testing.io, .{ .openai = "sk-test" }, .{});
    try std.testing.expectEqual(llm.Provider.openai, key_client.kind());
    const codex_client = Client.init(gpa, std.testing.io, .{ .openai_codex = undefined }, .{});
    try std.testing.expectEqual(llm.Provider.openai_codex, codex_client.kind());
}

test "usageSoFar reads accumulated usage through the stream seam" {
    var stream: Stream = .{ .anthropic = undefined };
    stream.anthropic.usage = .{ .input = 7, .output = 3, .cache_read = 90 };
    try std.testing.expectEqual(@as(u64, 7), stream.usageSoFar().input);
    try std.testing.expectEqual(@as(u64, 3), stream.usageSoFar().output);
    try std.testing.expectEqual(@as(u64, 90), stream.usageSoFar().cache_read);
}
