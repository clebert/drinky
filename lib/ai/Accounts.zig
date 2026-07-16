//! The set of configured accounts and their live credentials: the two OAuth
//! subscription stores and the two environment-sourced API keys. Owns what a
//! `provider.Client` points into — the `Auth` structs and (by borrow) the key
//! bytes — so a client built here stays valid for the whole session. Reports
//! which accounts are authenticated and builds a client for one on demand;
//! selection is always an explicit account, never inferred from a precedence.

const std = @import("std");

const anthropic = @import("anthropic/root.zig");
const llm = @import("llm.zig");
const net = @import("net.zig");
const openai = @import("openai/root.zig");
const provider = @import("provider.zig");

const Accounts = @This();

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
anthropic_auth: anthropic.Auth,
openai_auth: openai.Auth,
keys: ApiKeys,
/// Whether each subscription store loaded a credential from `auth.json`.
anthropic_subscription_ready: bool,
openai_subscription_ready: bool,

/// The per-vendor API keys, each null when its environment variable is unset.
/// Borrowed for the process lifetime (they point into the environment), so they
/// are never freed here.
pub const ApiKeys = struct {
    anthropic: ?[]const u8 = null,
    openai: ?[]const u8 = null,
};

/// Open both subscription stores (loading any stored credential) and take the
/// environment API keys. A malformed `auth.json` surfaces here rather than being
/// silently ignored.
pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    timeouts: net.Timeouts,
    keys: ApiKeys,
) !Accounts {
    var anthropic_auth = try anthropic.Auth.init(gpa, io, home);
    errdefer anthropic_auth.deinit();
    var openai_auth = try openai.Auth.init(gpa, io, home);
    errdefer openai_auth.deinit();

    const anthropic_ready = try anthropic_auth.load();
    const openai_ready = try openai_auth.load();

    return .{
        .gpa = gpa,
        .io = io,
        .timeouts = timeouts,
        .anthropic_auth = anthropic_auth,
        .openai_auth = openai_auth,
        .keys = keys,
        .anthropic_subscription_ready = anthropic_ready,
        .openai_subscription_ready = openai_ready,
    };
}

pub fn deinit(self: *Accounts) void {
    self.anthropic_auth.deinit();
    self.openai_auth.deinit();
}

/// Whether `account` has a usable credential: an env key for an API account, a
/// loaded subscription token for a subscription account.
pub fn isAuthenticated(self: *const Accounts, account: llm.Account) bool {
    return switch (account) {
        .anthropic_api => self.keys.anthropic != null,
        .anthropic_subscription => self.anthropic_subscription_ready,
        .openai_api => self.keys.openai != null,
        .openai_subscription => self.openai_subscription_ready,
    };
}

/// The first authenticated account in enum order, or null when none is — the
/// session's active account is chosen this way at startup (there is no configured
/// active account and no precedence beyond the declaration order).
pub fn firstAuthenticated(self: *const Accounts) ?llm.Account {
    for (std.enums.values(llm.Account)) |account| {
        if (self.isAuthenticated(account)) return account;
    }
    return null;
}

/// A client for `account`, pointing into this registry's owned credentials, or
/// null when the account is not authenticated.
pub fn client(self: *Accounts, account: llm.Account) ?provider.Client {
    const credentials: provider.Credentials = switch (account) {
        .anthropic_api => .{ .anthropic_api = self.keys.anthropic orelse return null },
        .anthropic_subscription => if (self.anthropic_subscription_ready)
            .{ .anthropic_subscription = &self.anthropic_auth }
        else
            return null,
        .openai_api => .{ .openai_api = self.keys.openai orelse return null },
        .openai_subscription => if (self.openai_subscription_ready)
            .{ .openai_subscription = &self.openai_auth }
        else
            return null,
    };
    return provider.Client.init(self.gpa, self.io, credentials, self.timeouts);
}

/// Run the interactive OAuth login for a subscription `account`, marking it
/// authenticated on success. An API account has no login (its key comes from the
/// environment), so it is an error.
pub fn login(self: *Accounts, account: llm.Account, out: *std.Io.Writer) !void {
    switch (account) {
        .anthropic_subscription => {
            try self.anthropic_auth.login(out);
            self.anthropic_subscription_ready = true;
        },
        .openai_subscription => {
            try self.openai_auth.login(out);
            self.openai_subscription_ready = true;
        },
        .anthropic_api, .openai_api => return error.ApiAccountHasNoLogin,
    }
}

fn testAccounts(keys: ApiKeys, anthropic_ready: bool, openai_ready: bool) Accounts {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .anthropic_auth = undefined,
        .openai_auth = undefined,
        .keys = keys,
        .anthropic_subscription_ready = anthropic_ready,
        .openai_subscription_ready = openai_ready,
    };
}

test "isAuthenticated and firstAuthenticated read keys and readiness, subscription first" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, true, false);
    try std.testing.expect(accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expect(accounts.isAuthenticated(.anthropic_api));
    try std.testing.expect(accounts.isAuthenticated(.openai_api));
    try std.testing.expect(!accounts.isAuthenticated(.openai_subscription));
    // Both anthropic credentials are present; the subscription precedes its API
    // key in enum order, so it is the active account.
    try std.testing.expectEqual(llm.Account.anthropic_subscription, accounts.firstAuthenticated().?);

    // With only API keys, the first authenticated in enum order (anthropic) wins.
    var api_only = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    try std.testing.expectEqual(llm.Account.anthropic_api, api_only.firstAuthenticated().?);

    var none = testAccounts(.{}, false, false);
    try std.testing.expect(none.firstAuthenticated() == null);
}

test "client selects the arm for an authenticated account, null otherwise" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = null }, false, false);
    try std.testing.expectEqual(llm.Account.anthropic_api, accounts.client(.anthropic_api).?.account());
    try std.testing.expect(accounts.client(.openai_api) == null);
    try std.testing.expect(accounts.client(.anthropic_subscription) == null);
}
