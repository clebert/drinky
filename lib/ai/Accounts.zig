//! The set of configured accounts and their live credentials: the OAuth login
//! stores and the two environment-sourced API keys. It owns what
//! a `provider.Client` points into: the `Auth` structs and (by borrow) the key
//! bytes. A client built here stays valid for the whole session. It reports
//! which accounts are authenticated and builds a client for one on demand. The
//! selection is always an explicit account, never inferred from a precedence.
//! It also owns best-effort account-specific model limits, so the
//! provider-wide compiled catalog remains immutable.

const std = @import("std");

const anthropic = @import("anthropic/root.zig");
const auth = @import("auth.zig");
const llm = @import("llm.zig");
const models = @import("models.zig");
const net = @import("net.zig");
const openai = @import("openai/root.zig");
const provider = @import("provider.zig");

const Accounts = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// One timeout pair per provider. Every auth store and every client of a
/// provider takes that provider's pair.
timeouts: net.ProviderTimeouts,
anthropic_auth: anthropic.Auth,
anthropic_console_auth: anthropic.ConsoleAuth,
openai_auth: openai.Auth,
keys: ApiKeys,
/// Whether each subscription store loaded a credential from `auth.json`.
anthropic_subscription_ready: bool,
openai_subscription_ready: bool,
/// Whether the Console store loaded a minted key from `auth.json`.
anthropic_console_ready: bool,
/// Valid account-specific context windows discovered for known OpenAI models.
/// Empty means every subscription model uses its compiled fallback.
openai_subscription_context_windows: std.ArrayList(ContextWindow),

const ContextWindow = struct {
    model: []const u8,
    tokens: u64,
};

/// The per-vendor API keys, each null when its environment variable is unset.
/// The keys are borrowed for the process lifetime (they point into the
/// environment), so they are never freed here.
pub const ApiKeys = struct {
    anthropic: ?[]const u8 = null,
    openai: ?[]const u8 = null,
};

/// A committed subscription login's persistence outcome. Both variants mean
/// the replacement credential is live. The caller owns the final presentation.
pub const Login = union(enum) {
    saved: []const u8,
    memory_only: struct {
        path: []const u8,
        save_error: anyerror,
    },
};

/// Open the OAuth login stores, load any stored credential, and take the
/// environment API keys. A malformed `auth.json` surfaces here and is not
/// silently ignored.
pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    timeouts: net.ProviderTimeouts,
    keys: ApiKeys,
) !Accounts {
    var anthropic_auth = try anthropic.Auth.init(gpa, io, home, timeouts.anthropic);
    errdefer anthropic_auth.deinit();
    var anthropic_console_auth = try anthropic.ConsoleAuth.init(gpa, io, home, timeouts.anthropic);
    errdefer anthropic_console_auth.deinit();
    var openai_auth = try openai.Auth.init(gpa, io, home, timeouts.openai);
    errdefer openai_auth.deinit();

    const anthropic_ready = try anthropic_auth.load();
    const anthropic_console_ready = try anthropic_console_auth.load();
    const openai_ready = try openai_auth.load();

    var accounts: Accounts = .{
        .gpa = gpa,
        .io = io,
        .timeouts = timeouts,
        .anthropic_auth = anthropic_auth,
        .anthropic_console_auth = anthropic_console_auth,
        .openai_auth = openai_auth,
        .keys = keys,
        .anthropic_subscription_ready = anthropic_ready,
        .openai_subscription_ready = openai_ready,
        .anthropic_console_ready = anthropic_console_ready,
        .openai_subscription_context_windows = .empty,
    };
    if (openai_ready) accounts.refreshOpenaiSubscriptionModels();
    return accounts;
}

pub fn deinit(self: *Accounts) void {
    self.openai_subscription_context_windows.deinit(self.gpa);
    self.anthropic_auth.deinit();
    self.anthropic_console_auth.deinit();
    self.openai_auth.deinit();
}

/// Whether `account` has a usable credential: an env key for an API account,
/// or a loaded credential for a login account.
pub fn isAuthenticated(self: *const Accounts, account: llm.Account) bool {
    return switch (account) {
        .anthropic_api => self.keys.anthropic != null,
        .anthropic_subscription => self.anthropic_subscription_ready,
        .openai_api => self.keys.openai != null,
        .openai_subscription => self.openai_subscription_ready,
        .anthropic_console => self.anthropic_console_ready,
    };
}

/// The first authenticated account, or null when none is. The session's active
/// account is chosen this way at startup (there is no configured active
/// account). A signed-in login is preferred over an environment API key, across
/// vendors. Within a tier, enum declaration order decides.
pub fn firstAuthenticated(self: *const Accounts) ?llm.Account {
    for (std.enums.values(llm.Account)) |account| {
        if (account.hasLogin() and self.isAuthenticated(account)) return account;
    }
    for (std.enums.values(llm.Account)) |account| {
        if (self.isAuthenticated(account)) return account;
    }
    return null;
}

/// A client for `account` that points into this registry's owned credentials,
/// or null when the account is not authenticated.
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
        .anthropic_console => if (self.anthropic_console_ready)
            .{ .anthropic_console = self.anthropic_console_auth.apiKey() orelse return null }
        else
            return null,
    };
    const timeouts = switch (account.provider()) {
        .anthropic => self.timeouts.anthropic,
        .openai => self.timeouts.openai,
    };
    return provider.Client.init(self.gpa, self.io, credentials, timeouts);
}

/// Overlay account-specific metadata onto a compiled or configured model.
/// API-key and Anthropic accounts always receive the model unchanged.
pub fn resolveModel(self: *const Accounts, account: llm.Account, base: models.Model) models.Model {
    if (account != .openai_subscription) return base;
    var resolved = base;
    for (self.openai_subscription_context_windows.items) |context_window| {
        if (!std.mem.eql(u8, context_window.model, base.name)) continue;
        resolved.context_window = context_window.tokens;
        break;
    }
    return resolved;
}

/// Append every compiled model offered to `account` and apply only that
/// account's valid metadata overlays.
pub fn listModels(
    self: *const Accounts,
    account: llm.Account,
    out: *std.ArrayList(models.Model),
    gpa: std.mem.Allocator,
) !void {
    const start = out.items.len;
    try models.list(account.provider(), out, gpa);
    for (out.items[start..]) |*model| model.* = self.resolveModel(account, model.*);
}

/// Run the interactive OAuth login for `account`, mark its committed
/// replacement authenticated, and return its persistence outcome. An
/// API account has no login (its key comes from the environment), so it is an
/// error. No error is returned after the credential has been replaced.
pub fn login(self: *Accounts, account: llm.Account, prompt: anytype) !Login {
    const provider_login: auth.Login = switch (account) {
        .anthropic_subscription => committed: {
            const committed_login = try self.anthropic_auth.login(prompt);
            self.anthropic_subscription_ready = true;
            break :committed committed_login;
        },
        .openai_subscription => committed: {
            const committed_login = try self.openai_auth.login(prompt);
            self.openai_subscription_ready = true;
            self.refreshOpenaiSubscriptionModels();
            break :committed committed_login;
        },
        .anthropic_console => committed: {
            const committed_login = try self.anthropic_console_auth.login(prompt);
            self.anthropic_console_ready = true;
            break :committed committed_login;
        },
        .anthropic_api, .openai_api => return error.ApiAccountHasNoLogin,
    };
    return switch (provider_login) {
        .saved => |path| .{ .saved = path },
        .memory_only => |failure| .{ .memory_only = .{
            .path = failure.path,
            .save_error = failure.save_error,
        } },
    };
}

/// Drop a login `account`'s stored credentials and mark it no longer
/// authenticated. An API account has no login to drop (its key comes from the
/// environment), so it is an error.
pub fn logout(self: *Accounts, account: llm.Account) !void {
    switch (account) {
        .anthropic_subscription => {
            try self.anthropic_auth.logout();
            self.anthropic_subscription_ready = false;
        },
        .openai_subscription => {
            try self.openai_auth.logout();
            self.openai_subscription_ready = false;
            self.openai_subscription_context_windows.clearAndFree(self.gpa);
        },
        .anthropic_console => {
            try self.anthropic_console_auth.logout();
            self.anthropic_console_ready = false;
        },
        .anthropic_api, .openai_api => return error.ApiAccountHasNoLogout,
    }
}

/// Forget a rejected subscription credential. Return true when another
/// instance replaced the stored token and this account reloaded it. The
/// discovered limits go in every case, because they belong to the principal
/// behind the replaced credential. Every model falls back to its compiled
/// limit until the next login or the next start.
pub fn invalidate(self: *Accounts, account: llm.Account) !bool {
    switch (account) {
        .anthropic_subscription => {
            const recovered = self.anthropic_auth.invalidate() catch |err| {
                self.anthropic_subscription_ready = false;
                return err;
            };
            self.anthropic_subscription_ready = recovered;
            return recovered;
        },
        .openai_subscription => {
            defer self.openai_subscription_context_windows.clearAndFree(self.gpa);
            const recovered = self.openai_auth.invalidate() catch |err| {
                self.openai_subscription_ready = false;
                return err;
            };
            self.openai_subscription_ready = recovered;
            return recovered;
        },
        .anthropic_console, .anthropic_api, .openai_api => {
            return error.AccountHasNoRefreshCredential;
        },
    }
}

/// Drop metadata that belongs to the principal behind a replaced credential.
/// Anthropic has no discovered metadata. OpenAI returns to compiled limits.
pub fn dropPrincipalMetadata(self: *Accounts, account: llm.Account) void {
    if (account == .openai_subscription)
        self.openai_subscription_context_windows.clearAndFree(self.gpa);
}

/// Replace this account's discovered limits. Any fetch, envelope, or
/// allocation failure leaves the override set empty and restores every
/// compiled fallback.
fn refreshOpenaiSubscriptionModels(self: *Accounts) void {
    self.replaceOpenaiSubscriptionCatalog(openai.ModelCatalog.fetch(
        self.gpa,
        self.io,
        self.timeouts.openai,
        &self.openai_auth,
    ));
}

fn replaceOpenaiSubscriptionCatalog(
    self: *Accounts,
    result: anyerror!openai.ModelCatalog,
) void {
    self.openai_subscription_context_windows.clearAndFree(self.gpa);

    var catalog = result catch return;
    defer catalog.deinit();

    var vendor_models: std.ArrayList(models.Model) = .empty;
    defer vendor_models.deinit(self.gpa);
    models.list(.openai, &vendor_models, self.gpa) catch return;

    for (vendor_models.items) |model| {
        const context_window = catalog.contextWindow(model.name) orelse continue;
        self.openai_subscription_context_windows.append(self.gpa, .{
            .model = model.name,
            .tokens = context_window,
        }) catch return self.openai_subscription_context_windows.clearAndFree(self.gpa);
    }
}

fn testAccounts(keys: ApiKeys, anthropic_ready: bool, openai_ready: bool) Accounts {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .anthropic_auth = undefined,
        .anthropic_console_auth = undefined,
        .openai_auth = undefined,
        .keys = keys,
        .anthropic_subscription_ready = anthropic_ready,
        .openai_subscription_ready = openai_ready,
        .anthropic_console_ready = false,
        .openai_subscription_context_windows = .empty,
    };
}

test "isAuthenticated and firstAuthenticated read keys and readiness, subscription first" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, true, false);
    try std.testing.expect(accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expect(accounts.isAuthenticated(.anthropic_api));
    try std.testing.expect(accounts.isAuthenticated(.openai_api));
    try std.testing.expect(!accounts.isAuthenticated(.openai_subscription));
    // Both anthropic credentials are present. The subscription precedes its API
    // key in enum order, so it is the active account.
    try std.testing.expectEqual(
        llm.Account.anthropic_subscription,
        accounts.firstAuthenticated().?,
    );

    // With only API keys, the first authenticated in enum order (anthropic) wins.
    var api_only = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    try std.testing.expectEqual(llm.Account.anthropic_api, api_only.firstAuthenticated().?);

    var cross_vendor = testAccounts(.{ .anthropic = "sk-ant" }, false, true);
    try std.testing.expectEqual(
        llm.Account.openai_subscription,
        cross_vendor.firstAuthenticated().?,
    );

    var console_first = testAccounts(.{}, false, true);
    console_first.anthropic_console_ready = true;
    try std.testing.expectEqual(llm.Account.anthropic_console, console_first.firstAuthenticated().?);

    var none = testAccounts(.{}, false, false);
    try std.testing.expect(none.firstAuthenticated() == null);
}

test "logout rejects api accounts, which are env-sourced" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant" }, false, false);
    try std.testing.expectError(error.ApiAccountHasNoLogout, accounts.logout(.anthropic_api));
    try std.testing.expectError(error.ApiAccountHasNoLogout, accounts.logout(.openai_api));
}

test "invalidation rejects accounts without a refresh credential" {
    var accounts = testAccounts(.{ .anthropic = "a", .openai = "o" }, false, false);
    for ([_]llm.Account{
        .anthropic_console,
        .anthropic_api,
        .openai_api,
    }) |account| {
        try std.testing.expectError(
            error.AccountHasNoRefreshCredential,
            accounts.invalidate(account),
        );
    }
}

test "client selects the arm for an authenticated account, null otherwise" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = null }, false, false);
    try std.testing.expectEqual(
        llm.Account.anthropic_api,
        accounts.client(.anthropic_api).?.account(),
    );
    try std.testing.expect(accounts.client(.openai_api) == null);
    try std.testing.expect(accounts.client(.anthropic_subscription) == null);
}

test "a client carries the timeout pair of its provider" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    accounts.timeouts = .{
        .anthropic = .{ .idle_ms = 1 },
        .openai = .{ .idle_ms = 2 },
    };
    try std.testing.expectEqual(
        @as(u64, 1),
        accounts.client(.anthropic_api).?.timeouts.idle_ms,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        accounts.client(.openai_api).?.timeouts.idle_ms,
    );
}

test "invalidation forgets a rejected credential when store removal fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buffer,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var accounts = try Accounts.init(gpa, io, home, .{}, .{});
    defer accounts.deinit();
    try std.testing.expect(accounts.isAuthenticated(.anthropic_subscription));

    // A corrupt file blocks removal. The rejected token must still leave memory.
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try std.testing.expectError(
        error.BadCredentials,
        accounts.invalidate(.anthropic_subscription),
    );
    try std.testing.expect(!accounts.isAuthenticated(.anthropic_subscription));
    try std.testing.expect(accounts.client(.anthropic_subscription) == null);
}

test "OpenAI invalidation clears context overrides when store removal fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai_subscription":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
        ,
    });
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buffer,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var accounts = testAccounts(.{}, false, true);
    defer accounts.openai_subscription_context_windows.deinit(gpa);
    accounts.openai_auth = try openai.Auth.init(gpa, io, home, .{});
    defer accounts.openai_auth.deinit();
    try std.testing.expect(try accounts.openai_auth.load());
    try accounts.openai_subscription_context_windows.append(gpa, .{
        .model = "gpt-5.6-sol",
        .tokens = 372_000,
    });

    // A failed removal must clear both the credential and its account metadata.
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try std.testing.expectError(
        error.BadCredentials,
        accounts.invalidate(.openai_subscription),
    );
    try std.testing.expect(!accounts.isAuthenticated(.openai_subscription));
    try std.testing.expect(accounts.openai_auth.tokens == null);
    try std.testing.expectEqual(
        @as(usize, 0),
        accounts.openai_subscription_context_windows.items.len,
    );
}

test "OpenAI invalidation reloads a replacement without its discovered limits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai_subscription":
        \\    { "access": "old_access", "refresh": "old_refresh",
        \\      "expires_ms": 4102444800000, "account_id": "account" } }
        ,
    });
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buffer,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var accounts = testAccounts(.{}, false, true);
    defer accounts.openai_subscription_context_windows.deinit(gpa);
    accounts.openai_auth = try openai.Auth.init(gpa, io, home, .{});
    defer accounts.openai_auth.deinit();
    try std.testing.expect(try accounts.openai_auth.load());
    try accounts.openai_subscription_context_windows.append(gpa, .{
        .model = "gpt-5.6-sol",
        .tokens = 372_000,
    });

    // Another instance saved a replacement. The reloaded credential can belong
    // to another principal, so its discovered limits go with the old one.
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai_subscription":
        \\    { "access": "new_access", "refresh": "new_refresh",
        \\      "expires_ms": 4102444800000, "account_id": "account" } }
        ,
    });
    try std.testing.expect(try accounts.invalidate(.openai_subscription));
    try std.testing.expect(accounts.isAuthenticated(.openai_subscription));
    try std.testing.expectEqualStrings(
        "new_refresh",
        accounts.openai_auth.tokens.?.refresh,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        accounts.openai_subscription_context_windows.items.len,
    );
}

test "a principal replacement drops only OpenAI subscription metadata" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{}, false, true);
    defer accounts.openai_subscription_context_windows.deinit(gpa);
    try accounts.openai_subscription_context_windows.append(gpa, .{
        .model = "gpt-5.6-sol",
        .tokens = 372_000,
    });

    accounts.dropPrincipalMetadata(.anthropic_subscription);
    try std.testing.expectEqual(
        @as(usize, 1),
        accounts.openai_subscription_context_windows.items.len,
    );
    accounts.dropPrincipalMetadata(.openai_subscription);
    try std.testing.expectEqual(
        @as(usize, 0),
        accounts.openai_subscription_context_windows.items.len,
    );
}

test "catalog limits apply to known subscription models only" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{ .openai = "sk-openai" }, false, true);
    defer accounts.openai_subscription_context_windows.deinit(gpa);

    const response =
        \\{ "models": [
        \\  { "slug": "gpt-5.6-sol", "context_window": 372000 },
        \\  { "slug": "not-compiled", "context_window": 999999 }
        \\] }
    ;
    accounts.replaceOpenaiSubscriptionCatalog(try openai.ModelCatalog.parse(gpa, response));

    const sol = models.get(.openai, "gpt-5.6-sol").?;
    const terra = models.get(.openai, "gpt-5.6-terra").?;
    try std.testing.expectEqual(
        @as(u64, 372_000),
        accounts.resolveModel(.openai_subscription, sol).context_window,
    );
    try std.testing.expectEqual(
        @as(u64, 1_050_000),
        accounts.resolveModel(.openai_subscription, terra).context_window,
    );
    try std.testing.expectEqual(
        @as(u64, 1_050_000),
        accounts.resolveModel(.openai_api, sol).context_window,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        accounts.openai_subscription_context_windows.items.len,
    );

    var listed: std.ArrayList(models.Model) = .empty;
    defer listed.deinit(gpa);
    try accounts.listModels(.openai_subscription, &listed, gpa);
    try std.testing.expectEqual(@as(u64, 372_000), listed.items[0].context_window);
}

test "catalog request failure restores compiled subscription defaults" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{}, false, true);
    defer accounts.openai_subscription_context_windows.deinit(gpa);

    const response =
        \\{ "models": [
        \\  { "slug": "gpt-5.6-sol", "context_window": 372000 }
        \\] }
    ;
    accounts.replaceOpenaiSubscriptionCatalog(try openai.ModelCatalog.parse(gpa, response));
    try std.testing.expectEqual(
        @as(usize, 1),
        accounts.openai_subscription_context_windows.items.len,
    );

    accounts.replaceOpenaiSubscriptionCatalog(
        @as(anyerror!openai.ModelCatalog, error.ConnectionRefused),
    );
    const sol = models.get(.openai, "gpt-5.6-sol").?;
    try std.testing.expectEqual(
        @as(u64, 1_050_000),
        accounts.resolveModel(.openai_subscription, sol).context_window,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        accounts.openai_subscription_context_windows.items.len,
    );
}
