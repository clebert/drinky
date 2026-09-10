//! The set of configured accounts and their live credentials: the OAuth login
//! stores, the three environment-sourced API keys, and the Google service
//! account key file. It owns what a `provider.Client` points into: the `Auth`
//! structs and (by borrow) the key bytes. A client built here stays valid for
//! the whole session. It reports which accounts are authenticated and builds a
//! client for one on demand. The selection is always an explicit account, never
//! inferred from a precedence. It also owns the model catalog, because a fetch
//! needs the credential of the account it fetches for. No fetch runs at startup:
//! the user asks for one.

const std = @import("std");

const anthropic = @import("anthropic/root.zig");
const auth = @import("auth.zig");
const Catalog = @import("Catalog.zig");
const google = @import("google/root.zig");
const json_store = @import("json_store.zig");
const llm = @import("llm.zig");
const Metadata = @import("Metadata.zig");
const Model = @import("Model.zig");
const net = @import("net.zig");
const oauth_callback = @import("oauth_callback.zig");
const openai = @import("openai/root.zig");
const openrouter = @import("openrouter/root.zig");
const provider = @import("provider.zig");
const testing = @import("testing.zig");
const xai = @import("xai/root.zig");

const Accounts = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// One timeout pair per provider. Every auth store and every client of a
/// provider takes that provider's pair.
timeouts: net.ProviderTimeouts,
anthropic_auth: anthropic.Auth,
anthropic_console_auth: anthropic.ConsoleAuth,
openai_auth: openai.Auth,
xai_auth: xai.Auth,
openrouter_auth: openrouter.Auth,
/// The key file credential, or null when the environment names no readable key
/// file beside a location Drinky serves.
google_auth: ?google.Auth,
/// Why the account that both variables name did not load, or null. Startup
/// reports nothing, because the key path is also the variable of every other
/// Google client. The login picker names the cause when the user picks the
/// account.
google_error: ?anyerror,
environment: Environment,
/// Whether each subscription store loaded a credential from `auth.json`.
anthropic_sub_login_ready: bool,
openai_sub_login_ready: bool,
xai_sub_login_ready: bool,
/// Whether the Console store loaded a minted key from `auth.json`.
anthropic_api_login_ready: bool,
/// Whether the OpenRouter OAuth store loaded a minted key from `auth.json`.
openrouter_api_login_ready: bool,
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
    xai: ?[]const u8 = null,
    openrouter: ?[]const u8 = null,
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

/// The OAuth redirect listener of one login: the loopback port it answers on,
/// and what binds a redirect to it.
pub const Callback = struct {
    port: u16,
    binding: oauth_callback.Binding,
};

/// Open the OAuth login stores, load any stored credential, take the
/// environment API keys, and read the Google key file. A malformed `auth.json`
/// surfaces here and is not silently ignored. A key file that does not load
/// leaves the key file account absent and records why, because the other accounts
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
    var xai_auth = try xai.Auth.init(gpa, io, home, timeouts.xai);
    errdefer xai_auth.deinit();
    var openrouter_auth = try openrouter.Auth.init(gpa, io, home, timeouts.openrouter);
    errdefer openrouter_auth.deinit();

    const anthropic_ready = try anthropic_auth.load();
    const anthropic_api_login_ready = try anthropic_console_auth.load();
    const openai_ready = try openai_auth.load();
    const xai_ready = try xai_auth.load();
    const openrouter_ready = try openrouter_auth.load();

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
    errdefer if (google_auth) |*cloud_auth| cloud_auth.deinit();

    var catalog = try Catalog.init(gpa, io, home);
    errdefer catalog.deinit();

    return .{
        .gpa = gpa,
        .io = io,
        .timeouts = timeouts,
        .anthropic_auth = anthropic_auth,
        .anthropic_console_auth = anthropic_console_auth,
        .openai_auth = openai_auth,
        .xai_auth = xai_auth,
        .openrouter_auth = openrouter_auth,
        .google_auth = google_auth,
        .google_error = google_error,
        .environment = environment,
        .anthropic_sub_login_ready = anthropic_ready,
        .openai_sub_login_ready = openai_ready,
        .xai_sub_login_ready = xai_ready,
        .anthropic_api_login_ready = anthropic_api_login_ready,
        .openrouter_api_login_ready = openrouter_ready,
        .catalog = catalog,
    };
}

pub fn deinit(self: *Accounts) void {
    self.catalog.deinit();
    self.anthropic_auth.deinit();
    self.anthropic_console_auth.deinit();
    self.openai_auth.deinit();
    self.xai_auth.deinit();
    self.openrouter_auth.deinit();
    if (self.google_auth) |*cloud_auth| cloud_auth.deinit();
}

/// Whether `account` has a usable credential: an env key for an API account, a
/// loaded key file for the key file account, or a loaded credential for a login
/// account.
pub fn isAuthenticated(self: *const Accounts, account: llm.Account) bool {
    return switch (account) {
        .anthropic_api_key => self.environment.anthropic != null,
        .anthropic_sub_login => self.anthropic_sub_login_ready,
        .openai_api_key => self.environment.openai != null,
        .openai_sub_login => self.openai_sub_login_ready,
        .xai_api_key => self.environment.xai != null,
        .xai_sub_login => self.xai_sub_login_ready,
        .anthropic_api_login => self.anthropic_api_login_ready,
        .openrouter_api_key => self.environment.openrouter != null,
        .openrouter_api_login => self.openrouter_api_login_ready,
        .google_cloud_keyfile => self.google_auth != null,
    };
}

/// Why the environment names `account` and the account still did not load, or
/// null. Only the key file account loads a file at startup, so only it can fail.
pub fn loadError(self: *const Accounts, account: llm.Account) ?anyerror {
    return switch (account) {
        .google_cloud_keyfile => self.google_error,
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
        .anthropic_api_key => .{
            .anthropic_api_key = self.environment.anthropic orelse return null,
        },
        .anthropic_sub_login => if (self.anthropic_sub_login_ready)
            .{ .anthropic_sub_login = &self.anthropic_auth }
        else
            return null,
        .openai_api_key => .{ .openai_api_key = self.environment.openai orelse return null },
        .openai_sub_login => if (self.openai_sub_login_ready)
            .{ .openai_sub_login = &self.openai_auth }
        else
            return null,
        .xai_api_key => .{ .xai_api_key = self.environment.xai orelse return null },
        .xai_sub_login => if (self.xai_sub_login_ready)
            .{ .xai_sub_login = &self.xai_auth }
        else
            return null,
        .anthropic_api_login => if (self.anthropic_api_login_ready)
            .{ .anthropic_api_login = self.anthropic_console_auth.apiKey() orelse return null }
        else
            return null,
        .openrouter_api_key => .{
            .openrouter_api_key = self.environment.openrouter orelse return null,
        },
        .openrouter_api_login => if (self.openrouter_api_login_ready)
            .{ .openrouter_api_login = self.openrouter_auth.apiKey() orelse return null }
        else
            return null,
        .google_cloud_keyfile => if (self.google_auth) |*cloud_auth|
            .{ .google_cloud_keyfile = cloud_auth }
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
    return self.refreshWithin(account, deadline, fetchModels, Metadata.fetch);
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

    if (account.provider() == .openrouter) {
        if (metadataFn(self.gpa, self.io, deadline)) |fetched| {
            var metadata = fetched;
            defer metadata.deinit();
            recordSave(&result.metadata_save_error, self.catalog.setMetadata(metadata.entries));
        } else |err| {
            result.models_error = err;
        }
    } else {
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
        .anthropic_sub_login => anthropic.models.fetch(
            self.gpa,
            self.io,
            deadline,
            .{ .subscription = try deadline.call(
                self.io,
                anthropic.Auth.accessToken,
                .{&self.anthropic_auth},
            ) },
        ),
        .anthropic_api_login => anthropic.models.fetch(
            self.gpa,
            self.io,
            deadline,
            .{ .api_key = self.anthropic_console_auth.apiKey() orelse return error.SignedOut },
        ),
        .anthropic_api_key => anthropic.models.fetch(
            self.gpa,
            self.io,
            deadline,
            .{ .api_key = self.environment.anthropic orelse return error.SignedOut },
        ),
        .openai_sub_login => openai.models.fetchSubscription(
            self.gpa,
            self.io,
            deadline,
            &self.openai_auth,
        ),
        .openai_api_key => openai.models.fetchApi(
            self.gpa,
            self.io,
            deadline,
            self.environment.openai orelse return error.SignedOut,
        ),
        .xai_sub_login => xai.models.fetch(
            self.gpa,
            self.io,
            deadline,
            try deadline.call(self.io, xai.Auth.accessToken, .{&self.xai_auth}),
        ),
        .xai_api_key => xai.models.fetch(
            self.gpa,
            self.io,
            deadline,
            self.environment.xai orelse return error.SignedOut,
        ),
        .google_cloud_keyfile => if (self.google_auth) |*cloud_auth| google.models.fetch(
            self.gpa,
            self.io,
            deadline,
            &.{
                .access_token = try deadline.call(self.io, google.Auth.accessToken, .{cloud_auth}),
                .location = cloud_auth.location,
            },
        ) else error.SignedOut,
        .openrouter_api_login, .openrouter_api_key => error.OpenRouterHasNoList,
    };
}

/// The timeout pair of the provider behind `account`.
fn timeoutsOf(self: *const Accounts, account: llm.Account) net.Timeouts {
    return switch (account.provider()) {
        .anthropic => self.timeouts.anthropic,
        .openai => self.timeouts.openai,
        .xai => self.timeouts.xai,
        .openrouter => self.timeouts.openrouter,
        .google => self.timeouts.google,
    };
}

/// The OAuth redirect listener for `account`, or null for an account without a
/// callback login. A pasted callback URL replays to this port, and the paste
/// filter demands this binding. The xAI subscription signs in with a device
/// code, so its login listens on no port.
pub fn callback(account: llm.Account) ?Callback {
    return switch (account) {
        .anthropic_sub_login => callbackOf(anthropic.oauth),
        .anthropic_api_login => callbackOf(anthropic.console),
        .openai_sub_login => callbackOf(openai.oauth),
        .openrouter_api_login => callbackOf(openrouter.oauth),
        .xai_sub_login,
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_key,
        .google_cloud_keyfile,
        => null,
    };
}

/// The listener of one OAuth protocol module, which states both parts of it.
fn callbackOf(comptime oauth: type) Callback {
    return .{ .port = oauth.callback_port, .binding = oauth_callback.bindingOf(oauth) };
}

/// Run the interactive OAuth login for `account`, mark its committed
/// replacement authenticated, and return its persistence outcome. An account
/// without a login (its credential comes from the environment) is an error. No
/// error is returned after the credential has been replaced.
pub fn login(self: *Accounts, account: llm.Account, prompt: anytype) !Login {
    const provider_login: auth.Login = switch (account) {
        .anthropic_sub_login => committed: {
            const committed_login = try self.anthropic_auth.login(prompt);
            self.anthropic_sub_login_ready = true;
            break :committed committed_login;
        },
        .openai_sub_login => committed: {
            const committed_login = try self.openai_auth.login(prompt);
            self.openai_sub_login_ready = true;
            break :committed committed_login;
        },
        .anthropic_api_login => committed: {
            const committed_login = try self.anthropic_console_auth.login(prompt);
            self.anthropic_api_login_ready = true;
            break :committed committed_login;
        },
        .xai_sub_login => committed: {
            const committed_login = try self.xai_auth.login(prompt);
            self.xai_sub_login_ready = true;
            break :committed committed_login;
        },
        .openrouter_api_login => committed: {
            const committed_login = try self.openrouter_auth.login(prompt);
            self.openrouter_api_login_ready = true;
            break :committed committed_login;
        },
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_key,
        .google_cloud_keyfile,
        => return error.ApiAccountHasNoLogin,
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
        .anthropic_sub_login => {
            try self.anthropic_auth.logout();
            self.anthropic_sub_login_ready = false;
            self.catalog.dropAccount(account);
        },
        .openai_sub_login => {
            try self.openai_auth.logout();
            self.openai_sub_login_ready = false;
            self.catalog.dropAccount(account);
        },
        .anthropic_api_login => {
            try self.anthropic_console_auth.logout();
            self.anthropic_api_login_ready = false;
            self.catalog.dropAccount(account);
        },
        .xai_sub_login => {
            try self.xai_auth.logout();
            self.xai_sub_login_ready = false;
            self.catalog.dropAccount(account);
        },
        .openrouter_api_login => {
            try self.openrouter_auth.logout();
            self.openrouter_api_login_ready = false;
            self.catalog.dropAccount(account);
        },
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_key,
        .google_cloud_keyfile,
        => return error.ApiAccountHasNoLogout,
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
        .anthropic_sub_login => {
            defer self.catalog.dropAccount(account);
            const recovered = self.anthropic_auth.invalidate() catch |err| {
                self.anthropic_sub_login_ready = false;
                return err;
            };
            self.anthropic_sub_login_ready = recovered;
            return recovered;
        },
        .openai_sub_login => {
            defer self.catalog.dropAccount(account);
            const recovered = self.openai_auth.invalidate() catch |err| {
                self.openai_sub_login_ready = false;
                return err;
            };
            self.openai_sub_login_ready = recovered;
            return recovered;
        },
        .xai_sub_login => {
            defer self.catalog.dropAccount(account);
            const recovered = self.xai_auth.invalidate() catch |err| {
                self.xai_sub_login_ready = false;
                return err;
            };
            self.xai_sub_login_ready = recovered;
            return recovered;
        },
        .anthropic_api_login,
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_login,
        .openrouter_api_key,
        .google_cloud_keyfile,
        => {
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
        .xai_auth = undefined,
        .openrouter_auth = undefined,
        .google_auth = null,
        .google_error = null,
        .environment = environment,
        .anthropic_sub_login_ready = anthropic_ready,
        .openai_sub_login_ready = openai_ready,
        .xai_sub_login_ready = false,
        .anthropic_api_login_ready = false,
        .openrouter_api_login_ready = false,
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
    try std.testing.expect(accounts.isAuthenticated(.anthropic_sub_login));
    try std.testing.expect(accounts.isAuthenticated(.anthropic_api_key));
    try std.testing.expect(accounts.isAuthenticated(.openai_api_key));
    try std.testing.expect(!accounts.isAuthenticated(.openai_sub_login));
    // Both anthropic credentials are present. The subscription precedes its API
    // key in enum order, so it is the active account.
    try std.testing.expectEqual(
        llm.Account.anthropic_sub_login,
        accounts.firstAuthenticated().?,
    );

    // With only API keys, the first authenticated in enum order (anthropic) wins.
    var api_only = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    try std.testing.expectEqual(llm.Account.anthropic_api_key, api_only.firstAuthenticated().?);

    var cross_vendor = testAccounts(.{ .anthropic = "sk-ant" }, false, true);
    try std.testing.expectEqual(
        llm.Account.openai_sub_login,
        cross_vendor.firstAuthenticated().?,
    );

    var console_first = testAccounts(.{}, false, true);
    console_first.anthropic_api_login_ready = true;
    try std.testing.expectEqual(
        llm.Account.anthropic_api_login,
        console_first.firstAuthenticated().?,
    );

    var none = testAccounts(.{}, false, false);
    try std.testing.expect(none.firstAuthenticated() == null);
}

test "an account has a callback listener exactly when it has a callback login" {
    for (std.enums.values(llm.Account)) |account| {
        const callback_login = account.hasLogin() and account != .xai_sub_login;
        try std.testing.expectEqual(callback_login, callback(account) != null);
    }
    // The pinned ports keep the four listeners apart and match each provider
    // OAuth registration. A grant of the OpenRouter login carries no state, so
    // its random callback path binds the redirect instead.
    try std.testing.expectEqual(@as(u16, 53692), callback(.anthropic_sub_login).?.port);
    try std.testing.expectEqual(@as(u16, 53693), callback(.anthropic_api_login).?.port);
    try std.testing.expectEqual(@as(u16, 1455), callback(.openai_sub_login).?.port);
    try std.testing.expectEqual(@as(u16, 53694), callback(.openrouter_api_login).?.port);
    for ([_]llm.Account{
        .anthropic_sub_login,
        .anthropic_api_login,
        .openai_sub_login,
    }) |account| {
        try std.testing.expectEqual(oauth_callback.Binding.state, callback(account).?.binding);
    }
    try std.testing.expectEqual(
        oauth_callback.Binding.path,
        callback(.openrouter_api_login).?.binding,
    );
}

test "logout rejects the accounts whose credential is env-sourced" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant" }, false, false);
    for ([_]llm.Account{
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_key,
        .google_cloud_keyfile,
    }) |account| {
        try std.testing.expectError(error.ApiAccountHasNoLogout, accounts.logout(account));
    }
}

test "invalidation rejects accounts without a refresh credential" {
    var accounts = testAccounts(.{ .anthropic = "a", .openai = "o" }, false, false);
    for ([_]llm.Account{
        .anthropic_api_login,
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_login,
        .openrouter_api_key,
        .google_cloud_keyfile,
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
        llm.Account.anthropic_api_key,
        accounts.client(.anthropic_api_key).?.account(),
    );
    try std.testing.expect(accounts.client(.openai_api_key) == null);
    try std.testing.expect(accounts.client(.anthropic_sub_login) == null);
    try std.testing.expect(accounts.client(.xai_sub_login) == null);
    try std.testing.expect(accounts.client(.google_cloud_keyfile) == null);
    try std.testing.expect(!accounts.isAuthenticated(.google_cloud_keyfile));

    var grok = testAccounts(.{ .xai = "xai-key" }, false, false);
    try std.testing.expect(grok.isAuthenticated(.xai_api_key));
    try std.testing.expectEqual(llm.Account.xai_api_key, grok.client(.xai_api_key).?.account());
    try std.testing.expectEqual(llm.Account.xai_api_key, grok.firstAuthenticated().?);
    grok.xai_sub_login_ready = true;
    try std.testing.expectEqual(llm.Account.xai_sub_login, grok.firstAuthenticated().?);
    try std.testing.expectEqual(
        llm.Account.xai_sub_login,
        grok.client(.xai_sub_login).?.account(),
    );
}

test "a client carries the timeout pair of its provider" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    accounts.timeouts = .{
        .anthropic = .{ .idle_ms = 1 },
        .openai = .{ .idle_ms = 2 },
        .google = .{ .idle_ms = 3 },
        .xai = .{ .idle_ms = 4 },
    };
    try std.testing.expectEqual(
        @as(u64, 1),
        accounts.client(.anthropic_api_key).?.timeouts.idle_ms,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        accounts.client(.openai_api_key).?.timeouts.idle_ms,
    );
    try std.testing.expectEqual(@as(u64, 3), accounts.timeoutsOf(.google_cloud_keyfile).idle_ms);
    try std.testing.expectEqual(@as(u64, 4), accounts.timeoutsOf(.xai_sub_login).idle_ms);
}

test "the key file account loads from the key file and records a failed load" {
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
    try std.testing.expect(!half.isAuthenticated(.google_cloud_keyfile));
    try std.testing.expect(half.google_error == null);

    // Both variables and no file: the account is absent and the error names why.
    var missing = try Accounts.init(gpa, io, home, .{}, .{
        .google_key_path = key_path,
        .google_location = "global",
    });
    defer missing.deinit();
    try std.testing.expect(!missing.isAuthenticated(.google_cloud_keyfile));
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), missing.google_error);
    try std.testing.expectEqual(
        @as(?anyerror, error.FileNotFound),
        missing.loadError(.google_cloud_keyfile),
    );
    try std.testing.expect(missing.loadError(.openai_api_key) == null);
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
    try std.testing.expect(ready.isAuthenticated(.google_cloud_keyfile));
    try std.testing.expect(ready.google_error == null);
    try std.testing.expectEqual(llm.Account.google_cloud_keyfile, ready.firstAuthenticated().?);
    try std.testing.expectEqual(
        llm.Account.google_cloud_keyfile,
        ready.client(.google_cloud_keyfile).?.account(),
    );
    try std.testing.expectEqualStrings("my-project", ready.google_auth.?.project);

    // A region is a failed load too, and every other account still serves.
    var bad_location = try Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-ant",
        .google_key_path = key_path,
        .google_location = "europe-west4",
    });
    defer bad_location.deinit();
    try std.testing.expectEqual(@as(?anyerror, error.BadLocation), bad_location.google_error);
    try std.testing.expectEqual(llm.Account.anthropic_api_key, bad_location.firstAuthenticated().?);
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
        \\{ "anthropic-sub-login":
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
    try std.testing.expect(accounts.isAuthenticated(.anthropic_sub_login));

    // A corrupt file blocks removal. The rejected token must still leave memory.
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try std.testing.expectError(
        error.BadCredentials,
        accounts.invalidate(.anthropic_sub_login),
    );
    try std.testing.expect(!accounts.isAuthenticated(.anthropic_sub_login));
    try std.testing.expect(accounts.client(.anthropic_sub_login) == null);
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
        \\{ "openai-sub-login":
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
    defer gpa.free(accounts.catalog.accounts.get(.openai_sub_login));
    accounts.openai_auth = try openai.Auth.init(gpa, io, home, .{});
    defer accounts.openai_auth.deinit();
    try std.testing.expect(try accounts.openai_auth.load());
    try seedModel(&accounts, .openai_sub_login, "gpt-5.6-sol");
    try std.testing.expect(!accounts.catalog.isEmpty(.openai_sub_login));

    // A failed removal must drop both the credential and the list behind it.
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try std.testing.expectError(
        error.BadCredentials,
        accounts.invalidate(.openai_sub_login),
    );
    try std.testing.expect(!accounts.isAuthenticated(.openai_sub_login));
    try std.testing.expect(accounts.openai_auth.tokens == null);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_sub_login));
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
        \\{ "openai-sub-login":
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
    defer gpa.free(accounts.catalog.accounts.get(.openai_sub_login));
    accounts.openai_auth = try openai.Auth.init(gpa, io, home, .{});
    defer accounts.openai_auth.deinit();
    try std.testing.expect(try accounts.openai_auth.load());
    try seedModel(&accounts, .openai_sub_login, "gpt-5.6-sol");

    // Another instance saved a replacement. The reloaded credential can belong
    // to another principal, so its discovered limits go with the old one.
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai-sub-login":
        \\    { "access": "new_access", "refresh": "new_refresh",
        \\      "expires_ms": 4102444800000, "account_id": "account" } }
        ,
    });
    try std.testing.expect(try accounts.invalidate(.openai_sub_login));
    try std.testing.expect(accounts.isAuthenticated(.openai_sub_login));
    try std.testing.expectEqualStrings(
        "new_refresh",
        accounts.openai_auth.tokens.?.refresh,
    );
    try std.testing.expect(accounts.catalog.isEmpty(.openai_sub_login));
}

// The xAI subscription runs the same lifecycle as the OpenAI one: a rejected
// credential leaves with its model list, and a replacement that another instance
// saved comes back without that list.
test "xAI invalidation forgets a rejected credential and reloads a replacement" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "xai-sub-login":
        \\    { "access": "old_access", "refresh": "old_refresh",
        \\      "expires_ms": 4102444800000, "subject": "user-1" } }
        ,
    });
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buffer,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var accounts = testAccounts(.{}, false, false);
    defer gpa.free(accounts.catalog.accounts.get(.xai_sub_login));
    accounts.xai_auth = try xai.Auth.init(gpa, io, home, .{});
    defer accounts.xai_auth.deinit();
    try std.testing.expect(try accounts.xai_auth.load());
    accounts.xai_sub_login_ready = true;
    try seedModel(&accounts, .xai_sub_login, "grok-4.6");

    // Another instance saved a replacement of the same user.
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "xai-sub-login":
        \\    { "access": "new_access", "refresh": "new_refresh",
        \\      "expires_ms": 4102444800000, "subject": "user-1" } }
        ,
    });
    try std.testing.expect(try accounts.invalidate(.xai_sub_login));
    try std.testing.expect(accounts.isAuthenticated(.xai_sub_login));
    try std.testing.expectEqualStrings("new_refresh", accounts.xai_auth.tokens.?.refresh);
    try std.testing.expect(accounts.catalog.isEmpty(.xai_sub_login));

    // Without a replacement, the rejected credential leaves the store and the
    // account signs out.
    try seedModel(&accounts, .xai_sub_login, "grok-4.6");
    try std.testing.expect(!try accounts.invalidate(.xai_sub_login));
    try std.testing.expect(!accounts.isAuthenticated(.xai_sub_login));
    try std.testing.expect(accounts.client(.xai_sub_login) == null);
    try std.testing.expect(accounts.catalog.isEmpty(.xai_sub_login));
    var file = (try json_store.open(gpa, io, accounts.xai_auth.path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("xai-sub-login") == null);
}

test "a principal replacement drops the list of that account alone" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{}, false, true);
    defer for (std.enums.values(llm.Account)) |account|
        gpa.free(accounts.catalog.accounts.get(account));

    try seedModel(&accounts, .openai_sub_login, "gpt-5.6-sol");
    try seedModel(&accounts, .anthropic_sub_login, "claude-opus-5");

    accounts.dropPrincipalMetadata(.anthropic_sub_login);
    try std.testing.expect(accounts.catalog.isEmpty(.anthropic_sub_login));
    try std.testing.expect(!accounts.catalog.isEmpty(.openai_sub_login));

    accounts.dropPrincipalMetadata(.openai_sub_login);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_sub_login));
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
    for ([_]llm.Account{ .anthropic_api_key, .openai_api_key }) |account| {
        const result = accounts.refreshWithin(account, expired, fetchModels, Metadata.fetch);
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

fn refuseMetadata(_: std.mem.Allocator, _: std.Io, _: net.Deadline) anyerror!Metadata {
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

    const canceled = accounts.refreshWithin(
        .anthropic_api_key,
        unbounded,
        cancelList,
        refuseMetadata,
    );
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), canceled.models_error);
    // The metadata double fails, so a null here proves that it never ran.
    try std.testing.expect(canceled.metadata_error == null);

    const refused = accounts.refreshWithin(
        .anthropic_api_key,
        unbounded,
        refuseList,
        refuseMetadata,
    );
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionRefused), refused.models_error);
    try std.testing.expectEqual(
        @as(?anyerror, error.MetadataRequestFailed),
        refused.metadata_error,
    );
}

test "an OpenRouter fetch runs no list request and reports a failed body as the list" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{ .openrouter = "sk-or" }, false, false);
    defer gpa.free(accounts.catalog.metadata);
    const unbounded: net.Deadline = .{ .at = null };

    const failed = accounts.refreshWithin(
        .openrouter_api_key,
        unbounded,
        refuseList,
        refuseMetadata,
    );
    try std.testing.expectEqual(@as(?anyerror, error.MetadataRequestFailed), failed.models_error);
    try std.testing.expect(failed.metadata_error == null);

    const arrived = accounts.refreshWithin(
        .openrouter_api_login,
        unbounded,
        refuseList,
        openrouterMetadata,
    );
    try std.testing.expect(arrived.models_error == null);
    try std.testing.expectEqual(@as(usize, 1), arrived.count);
}

fn openrouterMetadata(gpa: std.mem.Allocator, _: std.Io, _: net.Deadline) anyerror!Metadata {
    var model = try Model.init("openai/gpt-5.6-sol");
    model.tools = .supported;
    model.context_window = 1_050_000;
    const entries = try gpa.dupe(Metadata.Entry, &.{.{ .provider = .openrouter, .model = model }});
    return .{ .gpa = gpa, .entries = entries };
}

test "an account lists the models of its own catalog entry" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{ .openai = "sk-openai" }, false, true);
    defer for (std.enums.values(llm.Account)) |account|
        gpa.free(accounts.catalog.accounts.get(account));

    try std.testing.expect(accounts.catalog.isEmpty(.openai_sub_login));
    try std.testing.expect(!accounts.offersModel(.openai_sub_login));
    try seedModel(&accounts, .openai_sub_login, "gpt-5.6-sol");
    try std.testing.expect(accounts.offersModel(.openai_sub_login));

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(gpa);
    try accounts.listModels(.openai_sub_login, &listed, gpa);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed.items[0].name());
    try std.testing.expect(accounts.findModel(.openai_sub_login, "gpt-5.6-sol") != null);

    // The list of one account never reaches another.
    try std.testing.expect(accounts.findModel(.openai_api_key, "gpt-5.6-sol") == null);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_api_key));
    try std.testing.expect(!accounts.offersModel(.openai_api_key));
}
