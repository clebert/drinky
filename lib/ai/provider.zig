//! The seam between the neutral agent loop and concrete model providers. A
//! `Client` is a live connection to whichever provider the session selected.
//! It serializes a neutral `llm.Request`, sends it, and hands back a `Stream`
//! of neutral `llm.Event`s. Each provider account is a `Credentials`/`Stream`
//! union arm, so a new account is a new arm plus its module. The loop and
//! tools never change.

const std = @import("std");

const anthropic = @import("anthropic/root.zig");
const google = @import("google/root.zig");
const llm = @import("llm.zig");
const net = @import("net.zig");
const openai = @import("openai/root.zig");
const openrouter = @import("openrouter/root.zig");
const xai = @import("xai/root.zig");

const openai_url = "https://api.openai.com/v1/responses";
const codex_url = "https://chatgpt.com/backend-api/codex/responses";
/// Both xAI accounts reach the public Responses endpoint of xAI with a bearer
/// token, so the URL names no account.
const xai_url = "https://api.x.ai/v1/responses";
const openrouter_url = "https://openrouter.ai/api/v1/responses";

/// What a client needs to authenticate, tagged by the account it belongs to. A
/// subscription account holds an OAuth `Auth` (owned by the caller, refreshed on
/// demand). An API account holds a bare key (owned by the caller). The key file
/// account holds the `Auth` that mints its token from the key file. The active
/// tag picks the account, so `Client.init` needs no separate selector.
pub const Credentials = union(llm.Account) {
    anthropic_sub_login: *anthropic.Auth,
    anthropic_api_login: []const u8,
    anthropic_api_key: []const u8,
    openai_sub_login: *openai.Auth,
    openai_api_key: []const u8,
    xai_sub_login: *xai.Auth,
    xai_api_key: []const u8,
    openrouter_api_login: []const u8,
    openrouter_api_key: []const u8,
    google_cloud_keyfile: *google.Auth,
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

    /// The account that backs this client — vendor and billing product.
    pub fn account(self: *const Client) llm.Account {
        return std.meta.activeTag(self.credentials);
    }

    /// Renew this client's credential after the provider rejected it, and
    /// report whether the credential changed. A caller repeats a request only
    /// on a true result, because an unchanged credential fails the same way.
    ///
    /// An OAuth account and the key file account can renew themselves: the one
    /// refreshes its token, the other mints a new one from its key. An API key
    /// comes from the environment, and the Console key is minted once at login.
    /// Neither one rotates, so Drinky has nothing to take in their place.
    pub fn renewCredential(self: *Client) !bool {
        return switch (self.credentials) {
            inline .anthropic_sub_login,
            .openai_sub_login,
            .xai_sub_login,
            .google_cloud_keyfile,
            => |credential| credential.renew(),
            .anthropic_api_login,
            .anthropic_api_key,
            .openai_api_key,
            .xai_api_key,
            .openrouter_api_login,
            .openrouter_api_key,
            => false,
        };
    }

    /// The subscription allowance of this account when it lives outside the
    /// response head, or null when the account reports none here. The xAI
    /// subscription reads a billing endpoint. Anthropic and OpenAI state the
    /// allowance in the response head instead.
    pub fn fetchQuota(self: *Client) !?llm.Quota {
        switch (self.credentials) {
            .xai_sub_login => |auth| {
                const token = try auth.accessToken();
                return xai.quota.fetch(self.gpa, self.io, token);
            },
            else => return null,
        }
    }

    /// The credit pool of this account when it spends a prepaid pool, or null
    /// when it does not. Both OpenRouter accounts read the pool of their key.
    /// The subscription accounts state their allowance in the response head or
    /// on a billing endpoint instead.
    pub fn fetchCredits(self: *Client) !?llm.Credits {
        return switch (self.credentials) {
            .openrouter_api_login, .openrouter_api_key => |key| openrouter.credits.fetch(
                self.gpa,
                self.io,
                key,
            ),
            else => null,
        };
    }

    /// Open a streaming request for `request` and fill `out` in place. On
    /// success the caller owns `out` and must `deinit` it.
    pub fn send(self: *Client, out: *Stream, request: *const llm.Request) !void {
        switch (self.credentials) {
            inline .anthropic_sub_login,
            .anthropic_api_key,
            .anthropic_api_login,
            => |credential, tag| {
                const identity: anthropic.Transport.Identity = if (tag == .anthropic_sub_login)
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
            // The six Responses accounts share one transport and one wire.
            // Only the Codex backend takes an account header. The two xAI
            // accounts differ in the credential alone, so both reach the
            // public xAI endpoint the same way. The two OpenRouter accounts
            // differ in the credential alone as well, and both replay plain
            // reasoning.
            inline .openai_sub_login,
            .openai_api_key,
            .xai_sub_login,
            .xai_api_key,
            .openrouter_api_login,
            .openrouter_api_key,
            => |credential, tag| {
                const subscription = tag == .openai_sub_login or tag == .xai_sub_login;
                const token = if (subscription) try credential.accessToken() else credential;
                const body = try openai.wire.serialize(self.gpa, request, tag);
                defer self.gpa.free(body);
                out.* = @unionInit(Stream, @tagName(tag), undefined);
                var transport: openai.Transport = .{
                    .gpa = self.gpa,
                    .io = self.io,
                    .timeouts = self.timeouts,
                    .endpoint = responsesUrl(tag),
                    .account_id = if (tag == .openai_sub_login) credential.accountId() else "",
                    .plain_reasoning = tag.replaysPlainReasoning(),
                };
                try transport.send(&@field(out.*, @tagName(tag)), .{
                    .body = body,
                    .access_token = token,
                });
            },
            .google_cloud_keyfile => |credential| {
                const token = try credential.accessToken();
                const body = try google.wire.serialize(self.gpa, request);
                defer self.gpa.free(body);
                // The model names the endpoint, so the URL is built per request.
                const endpoint = try google.Transport.url(self.gpa, &.{
                    .project = credential.project,
                    .location = credential.location,
                    .model = request.model,
                });
                defer self.gpa.free(endpoint);
                out.* = .{ .google_cloud_keyfile = undefined };
                var transport: google.Transport = .{
                    .gpa = self.gpa,
                    .io = self.io,
                    .timeouts = self.timeouts,
                    .endpoint = endpoint,
                };
                try transport.send(
                    &out.google_cloud_keyfile,
                    &.{ .body = body, .access_token = token },
                );
            },
        }
    }
};

/// The Responses endpoint of one account of the OpenAI protocol. An account of
/// another protocol has none, and the compile fails where one asks.
fn responsesUrl(comptime account: llm.Account) []const u8 {
    return switch (account) {
        .openai_sub_login => codex_url,
        .openai_api_key => openai_url,
        .xai_sub_login, .xai_api_key => xai_url,
        .openrouter_api_login, .openrouter_api_key => openrouter_url,
        .anthropic_sub_login,
        .anthropic_api_login,
        .anthropic_api_key,
        .google_cloud_keyfile,
        => @compileError("the account speaks no Responses protocol"),
    };
}

/// A single request in flight that decodes to neutral `llm.Event`s. Both
/// accounts of a vendor share that vendor's transport stream. They differ only
/// in how the request was sent, not in how the response decodes.
pub const Stream = union(llm.Account) {
    anthropic_sub_login: anthropic.Transport.Stream,
    anthropic_api_login: anthropic.Transport.Stream,
    anthropic_api_key: anthropic.Transport.Stream,
    openai_sub_login: openai.Transport.Stream,
    openai_api_key: openai.Transport.Stream,
    xai_sub_login: openai.Transport.Stream,
    xai_api_key: openai.Transport.Stream,
    openrouter_api_login: openai.Transport.Stream,
    openrouter_api_key: openai.Transport.Stream,
    google_cloud_keyfile: google.Transport.Stream,

    pub fn deinit(self: *Stream) void {
        switch (self.*) {
            inline else => |*stream| stream.deinit(),
        }
    }

    /// Whether the request head reported success. A false result means the
    /// stream carries an error body, not events. Read it with `errorText`.
    pub fn ok(self: *const Stream) bool {
        return switch (self.*) {
            inline else => |*stream| stream.ok(),
        };
    }

    /// The error body text when the request failed, or empty otherwise.
    pub fn errorText(self: *const Stream) []const u8 {
        return switch (self.*) {
            inline else => |*stream| stream.errorText(),
        };
    }

    /// Whether the failed head reported that the provider rejected the
    /// credential.
    pub fn unauthorized(self: *const Stream) bool {
        return switch (self.*) {
            inline else => |*stream| stream.unauthorized(),
        };
    }

    /// Whether the current failure is worth a retry — a transient streamed
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

    /// The next decoded event, or null at the end of the stream.
    pub fn next(self: *Stream) !?llm.Event {
        return switch (self.*) {
            inline else => |*stream| stream.next(),
        };
    }

    /// Usage accumulated over this stream so far, before its stop event: whatever
    /// counts the provider has delivered up to now.
    pub fn usageSoFar(self: *const Stream) llm.Usage {
        return switch (self.*) {
            inline else => |*stream| stream.usageSoFar(),
        };
    }

    /// The subscription allowance the response head reported, or null when the
    /// account or backend sends none. It is valid as soon as the head is read,
    /// so it outlives a stream that errors or is canceled before its stop
    /// event.
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
        .{ .anthropic_sub_login = undefined },
        .{},
    );
    try std.testing.expectEqual(llm.Account.anthropic_sub_login, subscription.account());
    const anthropic_key = Client.init(gpa, std.testing.io, .{ .anthropic_api_key = "sk-ant" }, .{});
    try std.testing.expectEqual(llm.Account.anthropic_api_key, anthropic_key.account());
    const console = Client.init(
        gpa,
        std.testing.io,
        .{ .anthropic_api_login = "sk-ant-api03" },
        .{},
    );
    try std.testing.expectEqual(llm.Account.anthropic_api_login, console.account());
    const openai_key = Client.init(gpa, std.testing.io, .{ .openai_api_key = "sk-test" }, .{});
    try std.testing.expectEqual(llm.Account.openai_api_key, openai_key.account());
    const codex = Client.init(gpa, std.testing.io, .{ .openai_sub_login = undefined }, .{});
    try std.testing.expectEqual(llm.Account.openai_sub_login, codex.account());
    const grok = Client.init(gpa, std.testing.io, .{ .xai_sub_login = undefined }, .{});
    try std.testing.expectEqual(llm.Account.xai_sub_login, grok.account());
    const xai_key = Client.init(gpa, std.testing.io, .{ .xai_api_key = "xai-test" }, .{});
    try std.testing.expectEqual(llm.Account.xai_api_key, xai_key.account());
    const openrouter_key = Client.init(
        gpa,
        std.testing.io,
        .{ .openrouter_api_key = "sk-or" },
        .{},
    );
    try std.testing.expectEqual(llm.Account.openrouter_api_key, openrouter_key.account());
    const openrouter_login = Client.init(
        gpa,
        std.testing.io,
        .{ .openrouter_api_login = "sk-or" },
        .{},
    );
    try std.testing.expectEqual(llm.Account.openrouter_api_login, openrouter_login.account());
    const cloud = Client.init(gpa, std.testing.io, .{ .google_cloud_keyfile = undefined }, .{});
    try std.testing.expectEqual(llm.Account.google_cloud_keyfile, cloud.account());
}

// A key account holds one fixed secret, so a rejected request stands. An OAuth
// account and the key file account can take another token, and an OAuth account
// without a credential takes none.
test "an OAuth account and the key file account renew, a key account does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Credentials{
        .{ .anthropic_api_key = "sk-ant" },
        .{ .anthropic_api_login = "sk-ant-api03" },
        .{ .openai_api_key = "sk-test" },
        .{ .xai_api_key = "xai-test" },
        .{ .openrouter_api_key = "sk-or" },
        .{ .openrouter_api_login = "sk-or" },
    }) |credentials| {
        var client = Client.init(gpa, io, credentials, .{});
        try std.testing.expect(!try client.renewCredential());
    }

    var signed_out: anthropic.Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = "",
        .tokens = null,
    };
    var client = Client.init(gpa, io, .{ .anthropic_sub_login = &signed_out }, .{});
    try std.testing.expect(!try client.renewCredential());

    var signed_out_xai: xai.Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = "",
        .tokens = null,
    };
    var grok = Client.init(gpa, io, .{ .xai_sub_login = &signed_out_xai }, .{});
    try std.testing.expect(!try grok.renewCredential());
}

test "usageSoFar reads accumulated usage through the stream seam" {
    var stream: Stream = .{ .anthropic_sub_login = undefined };
    stream.anthropic_sub_login.usage = .{ .input = 7, .output = 3, .cache_read = 90 };
    try std.testing.expectEqual(@as(u64, 7), stream.usageSoFar().input);
    try std.testing.expectEqual(@as(u64, 3), stream.usageSoFar().output);
    try std.testing.expectEqual(@as(u64, 90), stream.usageSoFar().cache_read);
}

test "quotaSoFar reads the head allowance through the stream seam" {
    var codex: Stream = .{ .openai_sub_login = undefined };
    codex.openai_sub_login.quota = .{ .primary = .{ .used_percent = 40, .window_minutes = 300 } };
    try std.testing.expectEqual(@as(f64, 40), codex.quotaSoFar().?.primary.?.used_percent);

    // Both providers read their allowance out of the head, so the seam reports
    // each one the same way.
    var claude: Stream = .{ .anthropic_sub_login = undefined };
    claude.anthropic_sub_login.quota = .{
        .primary = .{ .used_percent = 6, .window_minutes = 300, .reset_seconds = 8600 },
    };
    try std.testing.expectEqual(@as(?u64, 8600), claude.quotaSoFar().?.primary.?.reset_seconds);

    // A head that stated none reports none.
    claude.anthropic_sub_login.quota = null;
    try std.testing.expect(claude.quotaSoFar() == null);
}

test "fetchQuota is a billing read of the xAI subscription alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Credentials{
        .{ .anthropic_api_key = "sk-ant" },
        .{ .anthropic_api_login = "sk-ant-api03" },
        .{ .openai_api_key = "sk-test" },
        .{ .xai_api_key = "xai-test" },
    }) |credentials| {
        var client = Client.init(gpa, io, credentials, .{});
        try std.testing.expect(try client.fetchQuota() == null);
    }

    var auth: xai.Auth = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .path = "",
        .tokens = .{
            .access = try gpa.dupe(u8, "token\r\nleaked"),
            .refresh = try gpa.dupe(u8, "rt"),
            .expires_ms = std.math.maxInt(i64),
        },
    };
    defer auth.tokens.?.deinit(gpa);
    var grok = Client.init(gpa, io, .{ .xai_sub_login = &auth }, .{});
    try std.testing.expectError(error.BadCredentials, grok.fetchQuota());
}

test "fetchCredits is a pool read of the OpenRouter accounts alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Credentials{
        .{ .anthropic_api_key = "sk-ant" },
        .{ .anthropic_api_login = "sk-ant-api03" },
        .{ .openai_api_key = "sk-test" },
        .{ .xai_api_key = "xai-test" },
    }) |credentials| {
        var client = Client.init(gpa, io, credentials, .{});
        try std.testing.expect(try client.fetchCredits() == null);
    }

    var key = Client.init(gpa, io, .{ .openrouter_api_key = "key\r\nleaked" }, .{});
    try std.testing.expectError(error.BadCredentials, key.fetchCredits());
    var login = Client.init(gpa, io, .{ .openrouter_api_login = "" }, .{});
    try std.testing.expectError(error.BadCredentials, login.fetchCredits());
}
