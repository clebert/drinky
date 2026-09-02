//! The set of configured accounts and their live credentials: the OAuth login
//! stores, the two environment-sourced API keys, and the Google service account
//! key file. It owns what a `provider.Client` points into: the `Auth` structs
//! and (by borrow) the key bytes. A client built here stays valid for the whole
//! session. It reports which accounts are authenticated and builds a client for
//! one on demand. The selection is always an explicit account, never inferred
//! from a precedence. It also owns the model catalog, because a fetch needs the
//! credential of the account it fetches for. No fetch runs at startup: the user
//! asks for one.

const std = @import("std");

const anthropic = @import("anthropic/root.zig");
const auth = @import("auth.zig");
const Catalog = @import("Catalog.zig");
const google = @import("google/root.zig");
const llm = @import("llm.zig");
const Model = @import("Model.zig");
const net = @import("net.zig");
const openai = @import("openai/root.zig");
const OpenRouter = @import("OpenRouter.zig");
const provider = @import("provider.zig");
const testing = @import("testing.zig");

const Accounts = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// One timeout pair per provider. Every auth store and every client of a
/// provider takes that provider's pair.
timeouts: net.ProviderTimeouts,
anthropic_auth: anthropic.Auth,
anthropic_console_auth: anthropic.ConsoleAuth,
openai_auth: openai.Auth,
/// The Vertex credential, or null when the environment names no readable key
/// file beside a location Drinky serves.
google_auth: ?google.Auth,
/// Why the account that both variables name did not load, or null. Startup
/// reports nothing, because the key path is also the variable of every other
/// Google client. The login picker names the cause when the user picks the
/// account.
google_error: ?anyerror,
environment: Environment,
/// Whether each subscription store loaded a credential from `auth.json`.
anthropic_subscription_ready: bool,
openai_subscription_ready: bool,
/// Whether the Console store loaded a minted key from `auth.json`.
anthropic_console_ready: bool,
/// Every model Drinky knows, loaded from its caches. A fetch replaces the list
/// of one account, and the user asks for that fetch.
catalog: Catalog,

/// What one fetch achieved. A part that failed leaves the cached part of its
/// own kind untouched, so a user who fetches again keeps what already arrived.
pub const Refresh = struct {
    /// The models the account offers after the fetch.
    count: usize = 0,
    /// Why the account list did not arrive, or null when it did.
    models_error: ?anyerror = null,
    /// Why the public metadata did not arrive, or null when it did.
    metadata_error: ?anyerror = null,
    /// Why the fetched account list did not reach its cache file, or null when
    /// that write succeeded or never ran. The list serves this session in every
    /// case.
    models_save_error: ?anyerror = null,
    /// Why the fetched public metadata did not reach its cache file, or null
    /// when that write succeeded or never ran. The metadata serves this session
    /// in every case.
    metadata_save_error: ?anyerror = null,
};

/// The credentials of the accounts without a login, each null when its
/// environment variable is unset. The values are borrowed for the process
/// lifetime (they point into the environment), so they are never freed here.
pub const Environment = struct {
    anthropic: ?[]const u8 = null,
    openai: ?[]const u8 = null,
    /// `GOOGLE_APPLICATION_CREDENTIALS`, the path of the service account key file.
    google_key_path: ?[]const u8 = null,
    /// `GOOGLE_CLOUD_LOCATION`: `eu`, `us`, or `global`.
    google_location: ?[]const u8 = null,
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

/// Open the OAuth login stores, load any stored credential, take the
/// environment API keys, and read the Google key file. A malformed `auth.json`
/// surfaces here and is not silently ignored. A key file that does not load
/// leaves the Vertex account absent and records why, because the other accounts
/// must still serve.
pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    timeouts: net.ProviderTimeouts,
    environment: Environment,
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

    var google_auth: ?google.Auth = null;
    var google_error: ?anyerror = null;
    if (environment.google_key_path != null and environment.google_location != null) {
        google_auth = google.Auth.init(gpa, io, timeouts.google, &.{
            .key_path = environment.google_key_path.?,
            .location = environment.google_location.?,
        }) catch |err| failed: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            google_error = err;
            break :failed null;
        };
    }
    errdefer if (google_auth) |*vertex| vertex.deinit();

    var catalog = try Catalog.init(gpa, io, home);
    errdefer catalog.deinit();

    return .{
        .gpa = gpa,
        .io = io,
        .timeouts = timeouts,
        .anthropic_auth = anthropic_auth,
        .anthropic_console_auth = anthropic_console_auth,
        .openai_auth = openai_auth,
        .google_auth = google_auth,
        .google_error = google_error,
        .environment = environment,
        .anthropic_subscription_ready = anthropic_ready,
        .openai_subscription_ready = openai_ready,
        .anthropic_console_ready = anthropic_console_ready,
        .catalog = catalog,
    };
}

pub fn deinit(self: *Accounts) void {
    self.catalog.deinit();
    self.anthropic_auth.deinit();
    self.anthropic_console_auth.deinit();
    self.openai_auth.deinit();
    if (self.google_auth) |*vertex| vertex.deinit();
}

/// Whether `account` has a usable credential: an env key for an API account, a
/// loaded key file for the Vertex account, or a loaded credential for a login
/// account.
pub fn isAuthenticated(self: *const Accounts, account: llm.Account) bool {
    return switch (account) {
        .anthropic_api => self.environment.anthropic != null,
        .anthropic_subscription => self.anthropic_subscription_ready,
        .openai_api => self.environment.openai != null,
        .openai_subscription => self.openai_subscription_ready,
        .anthropic_console => self.anthropic_console_ready,
        .google_vertex => self.google_auth != null,
    };
}

/// Why the environment names `account` and the account still did not load, or
/// null. Only the Vertex account loads a file at startup, so only it can fail.
pub fn loadError(self: *const Accounts, account: llm.Account) ?anyerror {
    return switch (account) {
        .google_vertex => self.google_error,
        else => null,
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
        .anthropic_api => .{ .anthropic_api = self.environment.anthropic orelse return null },
        .anthropic_subscription => if (self.anthropic_subscription_ready)
            .{ .anthropic_subscription = &self.anthropic_auth }
        else
            return null,
        .openai_api => .{ .openai_api = self.environment.openai orelse return null },
        .openai_subscription => if (self.openai_subscription_ready)
            .{ .openai_subscription = &self.openai_auth }
        else
            return null,
        .anthropic_console => if (self.anthropic_console_ready)
            .{ .anthropic_console = self.anthropic_console_auth.apiKey() orelse return null }
        else
            return null,
        .google_vertex => if (self.google_auth) |*vertex|
            .{ .google_vertex = vertex }
        else
            return null,
    };
    return provider.Client.init(self.gpa, self.io, credentials, self.timeoutsOf(account));
}

/// The model `name` of `account`, or null when the account does not offer it.
pub fn findModel(self: *const Accounts, account: llm.Account, name: []const u8) ?Model {
    return self.catalog.find(account, name);
}

/// Whether `account` offers at least one model, so a pick can run without a
/// fetch. An account whose list no fetch cached offers none.
pub fn offersModel(self: *const Accounts, account: llm.Account) bool {
    return !self.catalog.isEmpty(account);
}

/// Append every model `account` offers, in the order its provider listed it.
pub fn listModels(
    self: *const Accounts,
    account: llm.Account,
    out: *std.ArrayList(Model),
    gpa: std.mem.Allocator,
) !void {
    try self.catalog.list(account, out, gpa);
}

/// Fetch the model list of `account` and the public metadata, and store both.
/// The two requests are independent, so a failure of one keeps the result of
/// the other. Only the user starts this.
///
/// One window bounds the whole fetch: the token refresh, every page of the
/// list, and the metadata request behind it. A list runs up to eight pages, so a
/// bound per request would let a hung provider hold the fetch open for minutes.
/// The window takes the connect bound of the provider, because no stream runs
/// here and no idle bound applies.
pub fn refresh(self: *Accounts, account: llm.Account) Refresh {
    const deadline = net.Deadline.start(self.io, self.timeoutsOf(account).connect_ms);
    return self.refreshWithin(account, deadline, fetchModels, OpenRouter.fetch);
}

/// `refresh` inside a window that the caller opened, over the list request
/// `listFn` and the metadata request `metadataFn`. A test hands in doubles, so
/// it reaches every exit without a socket.
fn refreshWithin(
    self: *Accounts,
    account: llm.Account,
    deadline: net.Deadline,
    comptime listFn: anytype,
    comptime metadataFn: anytype,
) Refresh {
    var result: Refresh = .{};

    if (listFn(self, account, deadline)) |discovered| {
        defer self.gpa.free(discovered);
        recordSave(&result.models_save_error, self.catalog.setAccount(account, discovered));
    } else |err| {
        result.models_error = err;
    }
    // A cancel is one-shot: the blocking call that took it acknowledged it, and
    // every later blocking call runs to its end. The metadata request would then
    // hold the join for the rest of the window, so the fetch ends here. The
    // caller discards the result of a canceled fetch.
    if (isCanceled(result.models_error) or isCanceled(result.models_save_error)) return result;

    if (metadataFn(self.gpa, self.io, deadline)) |fetched| {
        var metadata = fetched;
        defer metadata.deinit();
        recordSave(&result.metadata_save_error, self.catalog.setMetadata(metadata.entries));
    } else |err| {
        result.metadata_error = err;
    }

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(self.gpa);
    if (self.catalog.list(account, &listed, self.gpa)) {
        result.count = listed.items.len;
    } else |_| {}
    return result;
}

/// Fold the outcome of one cache write into `slot`. The catalog holds what
/// arrived before it writes the file, so a failed write is a failed save and
/// never a failed fetch. Each write owns its own slot, so a report names the
/// cache that failed.
fn recordSave(slot: *?anyerror, outcome: anyerror!void) void {
    outcome catch |err| {
        slot.* = err;
    };
}

/// Whether a cancel ended the part of a fetch that `slot` reports.
fn isCanceled(slot: ?anyerror) bool {
    return (slot orelse return false) == error.Canceled;
}

/// The vendor list of `account`, fetched with that account's own credential
/// inside `deadline`. The subscription token can need a refresh first, and that
/// request draws on the same window.
fn fetchModels(self: *Accounts, account: llm.Account, deadline: net.Deadline) ![]Model {
    return switch (account) {
        .anthropic_subscription => anthropic.models.fetch(
            self.gpa,
            self.io,
            deadline,
            .{ .subscription = try deadline.call(
                self.io,
                anthropic.Auth.accessToken,
                .{&self.anthropic_auth},
            ) },
        ),
        .anthropic_console => anthropic.models.fetch(
            self.gpa,
            self.io,
            deadline,
            .{ .api_key = self.anthropic_console_auth.apiKey() orelse return error.SignedOut },
        ),
        .anthropic_api => anthropic.models.fetch(
            self.gpa,
            self.io,
            deadline,
            .{ .api_key = self.environment.anthropic orelse return error.SignedOut },
        ),
        .openai_subscription => openai.models.fetchSubscription(
            self.gpa,
            self.io,
            deadline,
            &self.openai_auth,
        ),
        .openai_api => openai.models.fetchApi(
            self.gpa,
            self.io,
            deadline,
            self.environment.openai orelse return error.SignedOut,
        ),
        .google_vertex => if (self.google_auth) |*vertex| google.models.fetch(
            self.gpa,
            self.io,
            deadline,
            &.{
                .access_token = try deadline.call(self.io, google.Auth.accessToken, .{vertex}),
                .location = vertex.location,
            },
        ) else error.SignedOut,
    };
}

/// The timeout pair of the provider behind `account`.
fn timeoutsOf(self: *const Accounts, account: llm.Account) net.Timeouts {
    return switch (account.provider()) {
        .anthropic => self.timeouts.anthropic,
        .openai => self.timeouts.openai,
        .google => self.timeouts.google,
    };
}

/// The loopback port of the OAuth redirect listener for `account`, or null
/// for an account without a browser login. A pasted callback URL replays to
/// this port.
pub fn callbackPort(account: llm.Account) ?u16 {
    return switch (account) {
        .anthropic_subscription => anthropic.oauth.callback_port,
        .anthropic_console => anthropic.console.callback_port,
        .openai_subscription => openai.oauth.callback_port,
        .anthropic_api, .openai_api, .google_vertex => null,
    };
}

/// Run the interactive OAuth login for `account`, mark its committed
/// replacement authenticated, and return its persistence outcome. An account
/// without a login (its credential comes from the environment) is an error. No
/// error is returned after the credential has been replaced.
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
            break :committed committed_login;
        },
        .anthropic_console => committed: {
            const committed_login = try self.anthropic_console_auth.login(prompt);
            self.anthropic_console_ready = true;
            break :committed committed_login;
        },
        .anthropic_api, .openai_api, .google_vertex => return error.ApiAccountHasNoLogin,
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
/// authenticated. An account without a login has nothing to drop (its
/// credential comes from the environment), so it is an error.
pub fn logout(self: *Accounts, account: llm.Account) !void {
    switch (account) {
        .anthropic_subscription => {
            try self.anthropic_auth.logout();
            self.anthropic_subscription_ready = false;
            self.catalog.dropAccount(account);
        },
        .openai_subscription => {
            try self.openai_auth.logout();
            self.openai_subscription_ready = false;
            self.catalog.dropAccount(account);
        },
        .anthropic_console => {
            try self.anthropic_console_auth.logout();
            self.anthropic_console_ready = false;
            self.catalog.dropAccount(account);
        },
        .anthropic_api, .openai_api, .google_vertex => return error.ApiAccountHasNoLogout,
    }
}

/// Forget a rejected subscription credential. Return true when another
/// instance replaced the stored token and this account reloaded it. The model
/// list leaves this session in every case, because it belongs to the principal
/// behind the replaced credential. The account offers no model until the next
/// fetch. A cache file that Drinky cannot rewrite keeps that list, so the next
/// start loads it again.
pub fn invalidate(self: *Accounts, account: llm.Account) !bool {
    switch (account) {
        .anthropic_subscription => {
            defer self.catalog.dropAccount(account);
            const recovered = self.anthropic_auth.invalidate() catch |err| {
                self.anthropic_subscription_ready = false;
                return err;
            };
            self.anthropic_subscription_ready = recovered;
            return recovered;
        },
        .openai_subscription => {
            defer self.catalog.dropAccount(account);
            const recovered = self.openai_auth.invalidate() catch |err| {
                self.openai_subscription_ready = false;
                return err;
            };
            self.openai_subscription_ready = recovered;
            return recovered;
        },
        .anthropic_console, .anthropic_api, .openai_api, .google_vertex => {
            return error.AccountHasNoRefreshCredential;
        },
    }
}

/// Drop the data that belongs to the principal behind a replaced credential.
/// The model list of an account is such data, so the account offers no model
/// for the rest of this session, until the user fetches again.
pub fn dropPrincipalMetadata(self: *Accounts, account: llm.Account) void {
    self.catalog.dropAccount(account);
}

fn testAccounts(environment: Environment, anthropic_ready: bool, openai_ready: bool) Accounts {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .anthropic_auth = undefined,
        .anthropic_console_auth = undefined,
        .openai_auth = undefined,
        .google_auth = null,
        .google_error = null,
        .environment = environment,
        .anthropic_subscription_ready = anthropic_ready,
        .openai_subscription_ready = openai_ready,
        .anthropic_console_ready = false,
        .catalog = testCatalog(),
    };
}

/// A catalog with no file behind it, so a test reads and writes memory alone.
fn testCatalog() Catalog {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .models_path = "",
        .metadata_path = "",
        .accounts = .initFill(&.{}),
        .metadata = &.{},
    };
}

/// Give `account` one model, as a fetch does.
fn seedModel(accounts: *Accounts, account: llm.Account, name: []const u8) !void {
    const seeded = try accounts.gpa.dupe(Model, &.{testing.model(name)});
    accounts.gpa.free(accounts.catalog.accounts.get(account));
    accounts.catalog.accounts.set(account, seeded);
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

test "an account has a callback port exactly when it has a login" {
    for (std.enums.values(llm.Account)) |account| {
        try std.testing.expectEqual(account.hasLogin(), callbackPort(account) != null);
    }
    // The pinned ports keep the three listeners apart and match each provider
    // OAuth registration.
    try std.testing.expectEqual(@as(?u16, 53692), callbackPort(.anthropic_subscription));
    try std.testing.expectEqual(@as(?u16, 53693), callbackPort(.anthropic_console));
    try std.testing.expectEqual(@as(?u16, 1455), callbackPort(.openai_subscription));
}

test "logout rejects the accounts whose credential is env-sourced" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant" }, false, false);
    for ([_]llm.Account{ .anthropic_api, .openai_api, .google_vertex }) |account| {
        try std.testing.expectError(error.ApiAccountHasNoLogout, accounts.logout(account));
    }
}

test "invalidation rejects accounts without a refresh credential" {
    var accounts = testAccounts(.{ .anthropic = "a", .openai = "o" }, false, false);
    for ([_]llm.Account{
        .anthropic_console,
        .anthropic_api,
        .openai_api,
        .google_vertex,
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
    try std.testing.expect(accounts.client(.google_vertex) == null);
    try std.testing.expect(!accounts.isAuthenticated(.google_vertex));
}

test "a client carries the timeout pair of its provider" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    accounts.timeouts = .{
        .anthropic = .{ .idle_ms = 1 },
        .openai = .{ .idle_ms = 2 },
        .google = .{ .idle_ms = 3 },
    };
    try std.testing.expectEqual(
        @as(u64, 1),
        accounts.client(.anthropic_api).?.timeouts.idle_ms,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        accounts.client(.openai_api).?.timeouts.idle_ms,
    );
    try std.testing.expectEqual(@as(u64, 3), accounts.timeoutsOf(.google_vertex).idle_ms);
}

test "the Vertex account loads from the key file and records a failed load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var key_buffer: [160]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, "{s}/key.json", .{home});

    // One variable alone leaves the account absent with no failure to report.
    var half = try Accounts.init(gpa, io, home, .{}, .{ .google_location = "global" });
    defer half.deinit();
    try std.testing.expect(!half.isAuthenticated(.google_vertex));
    try std.testing.expect(half.google_error == null);

    // Both variables and no file: the account is absent and the error names why.
    var missing = try Accounts.init(gpa, io, home, .{}, .{
        .google_key_path = key_path,
        .google_location = "global",
    });
    defer missing.deinit();
    try std.testing.expect(!missing.isAuthenticated(.google_vertex));
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), missing.google_error);
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), missing.loadError(.google_vertex));
    try std.testing.expect(missing.loadError(.openai_api) == null);
    try std.testing.expect(missing.firstAuthenticated() == null);

    const file = try std.json.Stringify.valueAlloc(gpa, .{
        .type = "service_account",
        .project_id = "my-project",
        .private_key = google.rs256.fixture_pem,
        .client_email = "robot@example.iam.gserviceaccount.com",
    }, .{});
    defer gpa.free(file);
    try tmp.dir.writeFile(io, .{ .sub_path = "key.json", .data = file });
    var ready = try Accounts.init(gpa, io, home, .{}, .{
        .google_key_path = key_path,
        .google_location = "eu",
    });
    defer ready.deinit();
    try std.testing.expect(ready.isAuthenticated(.google_vertex));
    try std.testing.expect(ready.google_error == null);
    try std.testing.expectEqual(llm.Account.google_vertex, ready.firstAuthenticated().?);
    try std.testing.expectEqual(llm.Account.google_vertex, ready.client(.google_vertex).?.account());
    try std.testing.expectEqualStrings("my-project", ready.google_auth.?.project);

    // A region is a failed load too, and every other account still serves.
    var bad_location = try Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-ant",
        .google_key_path = key_path,
        .google_location = "europe-west4",
    });
    defer bad_location.deinit();
    try std.testing.expectEqual(@as(?anyerror, error.BadLocation), bad_location.google_error);
    try std.testing.expectEqual(llm.Account.anthropic_api, bad_location.firstAuthenticated().?);
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

test "OpenAI invalidation drops the model list when store removal fails" {
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
    defer gpa.free(accounts.catalog.accounts.get(.openai_subscription));
    accounts.openai_auth = try openai.Auth.init(gpa, io, home, .{});
    defer accounts.openai_auth.deinit();
    try std.testing.expect(try accounts.openai_auth.load());
    try seedModel(&accounts, .openai_subscription, "gpt-5.6-sol");
    try std.testing.expect(!accounts.catalog.isEmpty(.openai_subscription));

    // A failed removal must drop both the credential and the list behind it.
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try std.testing.expectError(
        error.BadCredentials,
        accounts.invalidate(.openai_subscription),
    );
    try std.testing.expect(!accounts.isAuthenticated(.openai_subscription));
    try std.testing.expect(accounts.openai_auth.tokens == null);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_subscription));
}

test "OpenAI invalidation reloads a replacement without its model list" {
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
    defer gpa.free(accounts.catalog.accounts.get(.openai_subscription));
    accounts.openai_auth = try openai.Auth.init(gpa, io, home, .{});
    defer accounts.openai_auth.deinit();
    try std.testing.expect(try accounts.openai_auth.load());
    try seedModel(&accounts, .openai_subscription, "gpt-5.6-sol");

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
    try std.testing.expect(accounts.catalog.isEmpty(.openai_subscription));
}

test "a principal replacement drops the list of that account alone" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{}, false, true);
    defer for (std.enums.values(llm.Account)) |account|
        gpa.free(accounts.catalog.accounts.get(account));

    try seedModel(&accounts, .openai_subscription, "gpt-5.6-sol");
    try seedModel(&accounts, .anthropic_subscription, "claude-opus-5");

    accounts.dropPrincipalMetadata(.anthropic_subscription);
    try std.testing.expect(accounts.catalog.isEmpty(.anthropic_subscription));
    try std.testing.expect(!accounts.catalog.isEmpty(.openai_subscription));

    accounts.dropPrincipalMetadata(.openai_subscription);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_subscription));
}

// A fetch that arrived serves this session, whatever the cache file did, so a
// failed write is a failed save and never a failed fetch. A picker that reads
// `models_error` must therefore stay open over the list that arrived.
test "a failed cache write reports a failed save, not a failed fetch" {
    var result: Refresh = .{};
    recordSave(&result.models_save_error, {});
    try std.testing.expect(result.models_save_error == null);

    // Another Drinky instance holds the lock of the cache file.
    recordSave(&result.models_save_error, error.StoreBusy);
    try std.testing.expectEqual(@as(?anyerror, error.StoreBusy), result.models_save_error);
    try std.testing.expect(result.models_error == null);
    try std.testing.expect(result.metadata_error == null);

    // Each write owns its own slot, so a report names the cache that failed and
    // no failure hides behind another.
    recordSave(&result.metadata_save_error, error.AccessDenied);
    try std.testing.expectEqual(@as(?anyerror, error.StoreBusy), result.models_save_error);
    try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), result.metadata_save_error);
}

// One window covers the list and the metadata, so a window that has closed
// refuses both requests before either opens a socket. Each part records the
// timeout as its own failure, so the report names what the user lost.
test "an expired window ends both parts of a fetch without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    accounts.io = io;

    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    for ([_]llm.Account{ .anthropic_api, .openai_api }) |account| {
        const result = accounts.refreshWithin(account, expired, fetchModels, OpenRouter.fetch);
        try std.testing.expectEqual(@as(?anyerror, error.Timeout), result.models_error);
        try std.testing.expectEqual(@as(?anyerror, error.Timeout), result.metadata_error);
        try std.testing.expectEqual(@as(usize, 0), result.count);
        try std.testing.expect(accounts.catalog.isEmpty(account));
    }
}

fn cancelList(_: *Accounts, _: llm.Account, _: net.Deadline) anyerror![]Model {
    return error.Canceled;
}

fn refuseList(_: *Accounts, _: llm.Account, _: net.Deadline) anyerror![]Model {
    return error.ConnectionRefused;
}

fn refuseMetadata(_: std.mem.Allocator, _: std.Io, _: net.Deadline) anyerror!OpenRouter {
    return error.MetadataRequestFailed;
}

// A cancel is one-shot: the blocking call that takes it acknowledges it, and
// every later blocking call runs to its end. A metadata request after a canceled
// list would therefore hold the join for the rest of the window, and the
// interface with it. The fetch must end on the cancel. An ordinary failure of
// the list keeps the metadata request, because the two are independent.
test "a canceled list ends the fetch before the metadata request" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant" }, false, false);
    const unbounded: net.Deadline = .{ .at = null };

    const canceled = accounts.refreshWithin(.anthropic_api, unbounded, cancelList, refuseMetadata);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), canceled.models_error);
    // The metadata double fails, so a null here proves that it never ran.
    try std.testing.expect(canceled.metadata_error == null);

    const refused = accounts.refreshWithin(.anthropic_api, unbounded, refuseList, refuseMetadata);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionRefused), refused.models_error);
    try std.testing.expectEqual(
        @as(?anyerror, error.MetadataRequestFailed),
        refused.metadata_error,
    );
}

test "an account lists the models of its own catalog entry" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{ .openai = "sk-openai" }, false, true);
    defer for (std.enums.values(llm.Account)) |account|
        gpa.free(accounts.catalog.accounts.get(account));

    try std.testing.expect(accounts.catalog.isEmpty(.openai_subscription));
    try std.testing.expect(!accounts.offersModel(.openai_subscription));
    try seedModel(&accounts, .openai_subscription, "gpt-5.6-sol");
    try std.testing.expect(accounts.offersModel(.openai_subscription));

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(gpa);
    try accounts.listModels(.openai_subscription, &listed, gpa);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed.items[0].name());
    try std.testing.expect(accounts.findModel(.openai_subscription, "gpt-5.6-sol") != null);

    // The list of one account never reaches another.
    try std.testing.expect(accounts.findModel(.openai_api, "gpt-5.6-sol") == null);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_api));
    try std.testing.expect(!accounts.offersModel(.openai_api));
}
