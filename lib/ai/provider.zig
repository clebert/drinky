//! The seam between the neutral agent loop and concrete model providers. A
//! `Client` is a live connection to whichever provider the session selected; it
//! serializes a neutral `llm.Request`, sends it, and hands back a `Stream` of
//! neutral `llm.Event`s. Each provider is a union arm, so adding one is a new
//! arm plus its module — the loop and tools never change.

const std = @import("std");

const anthropic = @import("anthropic/root.zig");
const llm = @import("llm.zig");
const net = @import("net.zig");

pub const Kind = enum { anthropic };

pub const Client = union(Kind) {
    anthropic: Anthropic,

    const Anthropic = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        auth: *anthropic.Auth,
        timeouts: net.Timeouts,
    };

    pub fn init(
        provider: Kind,
        gpa: std.mem.Allocator,
        io: std.Io,
        auth: *anthropic.Auth,
        timeouts: net.Timeouts,
    ) Client {
        return switch (provider) {
            .anthropic => .{ .anthropic = .{ .gpa = gpa, .io = io, .auth = auth, .timeouts = timeouts } },
        };
    }

    /// The provider backing this client.
    pub fn kind(self: *const Client) Kind {
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
        }
    }
};

/// A single request in flight, decoding to neutral `llm.Event`s.
pub const Stream = union(Kind) {
    anthropic: anthropic.Transport.Stream,

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
};
