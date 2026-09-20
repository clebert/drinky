const std = @import("std");

const anthropic = @import("anthropic/root.zig");
const auth = @import("auth.zig");
const Catalog = @import("Catalog.zig");
const deepseek = @import("deepseek/root.zig");
const ds4 = @import("ds4/root.zig");
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
timeouts: net.ProviderTimeouts,
anthropic_auth: anthropic.Auth,
anthropic_console_auth: anthropic.ConsoleAuth,
openai_auth: openai.Auth,
xai_auth: xai.Auth,
openrouter_auth: openrouter.Auth,
google_auth: ?google.Auth,
google_error: ?anyerror,
ds4_base_url: ?[]const u8,
ds4_error: ?anyerror,
environment: Environment,
anthropic_plan_ready: bool,
openai_plan_ready: bool,
xai_plan_ready: bool,
anthropic_api_ready: bool,
openrouter_api_ready: bool,
catalog: Catalog,

pub const Refresh = struct {
    count: usize = 0,
    models_error: ?anyerror = null,
    metadata_error: ?anyerror = null,
    models_save_error: ?anyerror = null,
    metadata_save_error: ?anyerror = null,
};

pub const Reread = struct {
    changes: std.EnumArray(llm.Account, auth.Change) = .initFill(.unchanged),
    read_error: ?anyerror = null,
    entry_errors: std.EnumArray(llm.Account, ?anyerror) = .initFill(null),
};

pub const Environment = struct {
    anthropic: ?[]const u8 = null,
    openai: ?[]const u8 = null,
    xai: ?[]const u8 = null,
    openrouter: ?[]const u8 = null,
    deepseek: ?[]const u8 = null,
    google_key_path: ?[]const u8 = null,
    google_location: ?[]const u8 = null,
    ds4_base_url: ?[]const u8 = null,
};

pub const Login = union(enum) {
    saved: []const u8,
    memory_only: struct {
        path: []const u8,
        save_error: anyerror,
    },
};

pub const Callback = struct {
    port: u16,
    binding: oauth_callback.Binding,
};

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
    const anthropic_api_ready = try anthropic_console_auth.load();
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

    var ds4_base_url: ?[]const u8 = null;
    var ds4_error: ?anyerror = null;
    if (environment.ds4_base_url) |configured| {
        ds4_base_url = normalizeDs4BaseUrl(configured) catch |err| failed: {
            ds4_error = err;
            break :failed null;
        };
    }

    var catalog = try Catalog.init(gpa, io, home);
    errdefer catalog.deinit();
    if (ds4_base_url) |base_url| catalog.dropAccountFromAnotherUrl(.ds4, base_url);

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
        .ds4_base_url = ds4_base_url,
        .ds4_error = ds4_error,
        .environment = environment,
        .anthropic_plan_ready = anthropic_ready,
        .openai_plan_ready = openai_ready,
        .xai_plan_ready = xai_ready,
        .anthropic_api_ready = anthropic_api_ready,
        .openrouter_api_ready = openrouter_ready,
        .catalog = catalog,
    };
}

fn normalizeDs4BaseUrl(configured: []const u8) error{BadBaseUrl}![]const u8 {
    const base_url = std.mem.trimEnd(u8, configured, "/");
    const uri = std.Uri.parse(base_url) catch return error.BadBaseUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.BadBaseUrl;
    const host = uri.host orelse return error.BadBaseUrl;
    if (host.isEmpty()) return error.BadBaseUrl;
    if (uri.query != null or uri.fragment != null) return error.BadBaseUrl;
    if (!std.mem.endsWith(u8, base_url, "/v1")) return error.BadBaseUrl;
    return base_url;
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

pub fn isAuthenticated(self: *const Accounts, account: llm.Account) bool {
    return switch (account) {
        .anthropic_api_key => self.environment.anthropic != null,
        .anthropic_plan => self.anthropic_plan_ready,
        .openai_api_key => self.environment.openai != null,
        .openai_plan => self.openai_plan_ready,
        .xai_api_key => self.environment.xai != null,
        .xai_plan => self.xai_plan_ready,
        .anthropic_api => self.anthropic_api_ready,
        .openrouter_api_key => self.environment.openrouter != null,
        .openrouter_api => self.openrouter_api_ready,
        .deepseek_api_key => self.environment.deepseek != null,
        .google_cloud_key => self.google_auth != null,
        .ds4 => self.ds4_base_url != null,
    };
}

pub fn loadError(self: *const Accounts, account: llm.Account) ?anyerror {
    return switch (account) {
        .google_cloud_key => self.google_error,
        .ds4 => self.ds4_error,
        else => null,
    };
}

pub fn storePath(self: *const Accounts) []const u8 {
    return self.anthropic_auth.path;
}

pub fn reread(self: *Accounts) Reread {
    var report: Reread = .{};
    if (self.storePath().len == 0) return report;
    var maybe_file = auth.openStore(self.gpa, self.io, self.storePath()) catch |err| {
        report.read_error = err;
        return report;
    };
    defer if (maybe_file) |*file| file.deinit();
    const file: ?*const json_store.File = if (maybe_file) |*opened| opened else null;
    self.anthropic_plan_ready = self.rereadStore(
        &report,
        file,
        .anthropic_plan,
        &self.anthropic_auth,
        self.anthropic_plan_ready,
    );
    self.anthropic_api_ready = self.rereadStore(
        &report,
        file,
        .anthropic_api,
        &self.anthropic_console_auth,
        self.anthropic_api_ready,
    );
    self.openai_plan_ready = self.rereadStore(
        &report,
        file,
        .openai_plan,
        &self.openai_auth,
        self.openai_plan_ready,
    );
    self.xai_plan_ready = self.rereadStore(
        &report,
        file,
        .xai_plan,
        &self.xai_auth,
        self.xai_plan_ready,
    );
    self.openrouter_api_ready = self.rereadStore(
        &report,
        file,
        .openrouter_api,
        &self.openrouter_auth,
        self.openrouter_api_ready,
    );
    return report;
}

fn rereadStore(
    self: *Accounts,
    report: *Reread,
    file: ?*const json_store.File,
    account: llm.Account,
    store: anytype,
    ready: bool,
) bool {
    const change = store.reread(file) catch |err| failed: {
        report.entry_errors.set(account, err);
        break :failed .unchanged;
    };
    report.changes.set(account, change);
    switch (change) {
        .unchanged => return ready,
        .signed_in, .rotated => return true,
        .replaced => {
            self.catalog.dropAccount(account);
            return true;
        },
        .signed_out => {
            self.catalog.dropAccount(account);
            return false;
        },
    }
}

pub fn firstAuthenticated(self: *const Accounts) ?llm.Account {
    for (std.enums.values(llm.Account)) |account| {
        if (account.hasLogin() and self.isAuthenticated(account)) return account;
    }
    for (std.enums.values(llm.Account)) |account| {
        if (self.isAuthenticated(account)) return account;
    }
    return null;
}

pub fn client(self: *Accounts, account: llm.Account) ?provider.Client {
    const credentials: provider.Credentials = switch (account) {
        .anthropic_api_key => .{
            .anthropic_api_key = self.environment.anthropic orelse return null,
        },
        .anthropic_plan => if (self.anthropic_plan_ready)
            .{ .anthropic_plan = &self.anthropic_auth }
        else
            return null,
        .openai_api_key => .{ .openai_api_key = self.environment.openai orelse return null },
        .openai_plan => if (self.openai_plan_ready)
            .{ .openai_plan = &self.openai_auth }
        else
            return null,
        .xai_api_key => .{ .xai_api_key = self.environment.xai orelse return null },
        .xai_plan => if (self.xai_plan_ready)
            .{ .xai_plan = &self.xai_auth }
        else
            return null,
        .anthropic_api => if (self.anthropic_api_ready)
            .{ .anthropic_api = self.anthropic_console_auth.apiKey() orelse return null }
        else
            return null,
        .openrouter_api_key => .{
            .openrouter_api_key = self.environment.openrouter orelse return null,
        },
        .openrouter_api => if (self.openrouter_api_ready)
            .{ .openrouter_api = self.openrouter_auth.apiKey() orelse return null }
        else
            return null,
        .deepseek_api_key => .{
            .deepseek_api_key = self.environment.deepseek orelse return null,
        },
        .google_cloud_key => if (self.google_auth) |*cloud_auth|
            .{ .google_cloud_key = cloud_auth }
        else
            return null,
        .ds4 => .{ .ds4 = self.ds4_base_url orelse return null },
    };
    return provider.Client.init(self.gpa, self.io, credentials, self.timeoutsOf(account));
}

pub fn findModel(self: *const Accounts, account: llm.Account, name: []const u8) ?Model {
    return self.catalog.find(account, name);
}

pub fn offersModel(self: *const Accounts, account: llm.Account) bool {
    return !self.catalog.isEmpty(account);
}

pub fn listModels(
    self: *const Accounts,
    account: llm.Account,
    out: *std.ArrayList(Model),
    gpa: std.mem.Allocator,
) !void {
    try self.catalog.list(account, out, gpa);
}

pub fn refresh(self: *Accounts, account: llm.Account) Refresh {
    const deadline = net.Deadline.start(self.io, self.timeoutsOf(account).connect_ms);
    return self.refreshWithin(account, deadline, fetchModels, Metadata.fetch);
}

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
            recordSave(&result.models_save_error, self.storeModels(account, discovered));
        } else |err| {
            result.models_error = err;
        }
        if (isCanceled(result.models_error) or isCanceled(result.models_save_error)) return result;

        if (account != .ds4) {
            if (metadataFn(self.gpa, self.io, deadline)) |fetched| {
                var metadata = fetched;
                defer metadata.deinit();
                recordSave(&result.metadata_save_error, self.catalog.setMetadata(metadata.entries));
            } else |err| {
                result.metadata_error = err;
            }
        }
    }

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(self.gpa);
    if (self.catalog.list(account, &listed, self.gpa)) {
        result.count = listed.items.len;
    } else |_| {}
    return result;
}

fn storeModels(self: *Accounts, account: llm.Account, discovered: []const Model) !void {
    if (account != .ds4) return self.catalog.setAccount(account, discovered);
    try self.catalog.setAccountAt(.ds4, .{
        .models = discovered,
        .base_url = self.ds4_base_url orelse return error.SignedOut,
    });
}

fn recordSave(slot: *?anyerror, outcome: anyerror!void) void {
    outcome catch |err| {
        slot.* = err;
    };
}

fn isCanceled(slot: ?anyerror) bool {
    return (slot orelse return false) == error.Canceled;
}

fn fetchModels(self: *Accounts, account: llm.Account, deadline: net.Deadline) ![]Model {
    return switch (account) {
        .anthropic_plan => anthropic.models.fetch(
            self.gpa,
            self.io,
            deadline,
            .{ .subscription = try deadline.call(
                self.io,
                anthropic.Auth.accessToken,
                .{&self.anthropic_auth},
            ) },
        ),
        .anthropic_api => anthropic.models.fetch(
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
        .openai_plan => openai.models.fetchSubscription(
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
        .xai_plan => xai.models.fetch(
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
        .google_cloud_key => if (self.google_auth) |*cloud_auth| google.models.fetch(
            self.gpa,
            self.io,
            deadline,
            &.{
                .access_token = try deadline.call(self.io, google.Auth.accessToken, .{cloud_auth}),
                .location = cloud_auth.location,
            },
        ) else error.SignedOut,
        .openrouter_api, .openrouter_api_key => error.OpenRouterHasNoList,
        .deepseek_api_key => deepseek.models.fetch(
            self.gpa,
            self.io,
            deadline,
            self.environment.deepseek orelse return error.SignedOut,
        ),
        .ds4 => ds4.models.fetch(
            self.gpa,
            self.io,
            deadline,
            self.ds4_base_url orelse return error.SignedOut,
        ),
    };
}

fn timeoutsOf(self: *const Accounts, account: llm.Account) net.Timeouts {
    return switch (account.provider()) {
        .anthropic => self.timeouts.anthropic,
        .openai => self.timeouts.openai,
        .xai => self.timeouts.xai,
        .openrouter => self.timeouts.openrouter,
        .deepseek => self.timeouts.deepseek,
        .google => self.timeouts.google,
        .ds4 => self.timeouts.ds4,
    };
}

pub fn callback(account: llm.Account) ?Callback {
    return switch (account) {
        .anthropic_plan => callbackOf(anthropic.oauth),
        .anthropic_api => callbackOf(anthropic.console),
        .openai_plan => callbackOf(openai.oauth),
        .openrouter_api => callbackOf(openrouter.oauth),
        .xai_plan,
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_key,
        .deepseek_api_key,
        .google_cloud_key,
        .ds4,
        => null,
    };
}

fn callbackOf(comptime oauth: type) Callback {
    return .{ .port = oauth.callback_port, .binding = oauth_callback.bindingOf(oauth) };
}

pub fn login(self: *Accounts, account: llm.Account, prompt: anytype) !Login {
    const provider_login: auth.Login = switch (account) {
        .anthropic_plan => committed: {
            const committed_login = try self.anthropic_auth.login(prompt);
            self.anthropic_plan_ready = true;
            break :committed committed_login;
        },
        .openai_plan => committed: {
            const committed_login = try self.openai_auth.login(prompt);
            self.openai_plan_ready = true;
            break :committed committed_login;
        },
        .anthropic_api => committed: {
            const committed_login = try self.anthropic_console_auth.login(prompt);
            self.anthropic_api_ready = true;
            break :committed committed_login;
        },
        .xai_plan => committed: {
            const committed_login = try self.xai_auth.login(prompt);
            self.xai_plan_ready = true;
            break :committed committed_login;
        },
        .openrouter_api => committed: {
            const committed_login = try self.openrouter_auth.login(prompt);
            self.openrouter_api_ready = true;
            break :committed committed_login;
        },
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_key,
        .deepseek_api_key,
        .google_cloud_key,
        .ds4,
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

pub fn logout(self: *Accounts, account: llm.Account) !void {
    switch (account) {
        .anthropic_plan => {
            try self.anthropic_auth.logout();
            self.anthropic_plan_ready = false;
            self.catalog.dropAccount(account);
        },
        .openai_plan => {
            try self.openai_auth.logout();
            self.openai_plan_ready = false;
            self.catalog.dropAccount(account);
        },
        .anthropic_api => {
            try self.anthropic_console_auth.logout();
            self.anthropic_api_ready = false;
            self.catalog.dropAccount(account);
        },
        .xai_plan => {
            try self.xai_auth.logout();
            self.xai_plan_ready = false;
            self.catalog.dropAccount(account);
        },
        .openrouter_api => {
            try self.openrouter_auth.logout();
            self.openrouter_api_ready = false;
            self.catalog.dropAccount(account);
        },
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_key,
        .deepseek_api_key,
        .google_cloud_key,
        .ds4,
        => return error.ApiAccountHasNoLogout,
    }
}

pub fn invalidate(self: *Accounts, account: llm.Account) !bool {
    switch (account) {
        .anthropic_plan => {
            defer self.catalog.dropAccount(account);
            const recovered = self.anthropic_auth.invalidate() catch |err| {
                self.anthropic_plan_ready = false;
                return err;
            };
            self.anthropic_plan_ready = recovered;
            return recovered;
        },
        .openai_plan => {
            defer self.catalog.dropAccount(account);
            const recovered = self.openai_auth.invalidate() catch |err| {
                self.openai_plan_ready = false;
                return err;
            };
            self.openai_plan_ready = recovered;
            return recovered;
        },
        .xai_plan => {
            defer self.catalog.dropAccount(account);
            const recovered = self.xai_auth.invalidate() catch |err| {
                self.xai_plan_ready = false;
                return err;
            };
            self.xai_plan_ready = recovered;
            return recovered;
        },
        .anthropic_api,
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api,
        .openrouter_api_key,
        .deepseek_api_key,
        .google_cloud_key,
        .ds4,
        => {
            return error.AccountHasNoRefreshCredential;
        },
    }
}

pub fn dropPrincipalMetadata(self: *Accounts, account: llm.Account) void {
    self.catalog.dropAccount(account);
}

fn testAccounts(environment: Environment, anthropic_ready: bool, openai_ready: bool) Accounts {
    var accounts = testing.accounts(environment);
    accounts.anthropic_plan_ready = anthropic_ready;
    accounts.openai_plan_ready = openai_ready;
    return accounts;
}

fn seedModel(accounts: *Accounts, account: llm.Account, name: []const u8) !void {
    try testing.seedAccount(accounts, account, &.{name});
}

test "isAuthenticated and firstAuthenticated read keys and readiness, subscription first" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, true, false);
    try std.testing.expect(accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expect(accounts.isAuthenticated(.anthropic_api_key));
    try std.testing.expect(accounts.isAuthenticated(.openai_api_key));
    try std.testing.expect(!accounts.isAuthenticated(.openai_plan));
    try std.testing.expectEqual(
        llm.Account.anthropic_plan,
        accounts.firstAuthenticated().?,
    );

    var api_only = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    try std.testing.expectEqual(llm.Account.anthropic_api_key, api_only.firstAuthenticated().?);

    var cross_vendor = testAccounts(.{ .anthropic = "sk-ant" }, false, true);
    try std.testing.expectEqual(
        llm.Account.openai_plan,
        cross_vendor.firstAuthenticated().?,
    );

    var console_first = testAccounts(.{}, false, true);
    console_first.anthropic_api_ready = true;
    try std.testing.expectEqual(
        llm.Account.anthropic_api,
        console_first.firstAuthenticated().?,
    );

    var none = testAccounts(.{}, false, false);
    try std.testing.expect(none.firstAuthenticated() == null);
}

test "an account has a callback listener exactly when it has a callback login" {
    for (std.enums.values(llm.Account)) |account| {
        const callback_login = account.hasLogin() and account != .xai_plan;
        try std.testing.expectEqual(callback_login, callback(account) != null);
    }
    try std.testing.expectEqual(@as(u16, 53692), callback(.anthropic_plan).?.port);
    try std.testing.expectEqual(@as(u16, 53693), callback(.anthropic_api).?.port);
    try std.testing.expectEqual(@as(u16, 1455), callback(.openai_plan).?.port);
    try std.testing.expectEqual(@as(u16, 53694), callback(.openrouter_api).?.port);
    for ([_]llm.Account{
        .anthropic_plan,
        .anthropic_api,
        .openai_plan,
    }) |account| {
        try std.testing.expectEqual(oauth_callback.Binding.state, callback(account).?.binding);
    }
    try std.testing.expectEqual(
        oauth_callback.Binding.path,
        callback(.openrouter_api).?.binding,
    );
}

test "logout rejects the accounts whose credential is env-sourced" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant" }, false, false);
    for ([_]llm.Account{
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api_key,
        .deepseek_api_key,
        .google_cloud_key,
        .ds4,
    }) |account| {
        try std.testing.expectError(error.ApiAccountHasNoLogout, accounts.logout(account));
    }
}

test "invalidation rejects accounts without a refresh credential" {
    var accounts = testAccounts(.{ .anthropic = "a", .openai = "o" }, false, false);
    for ([_]llm.Account{
        .anthropic_api,
        .anthropic_api_key,
        .openai_api_key,
        .xai_api_key,
        .openrouter_api,
        .openrouter_api_key,
        .deepseek_api_key,
        .google_cloud_key,
        .ds4,
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
    try std.testing.expect(accounts.client(.anthropic_plan) == null);
    try std.testing.expect(accounts.client(.xai_plan) == null);
    try std.testing.expect(accounts.client(.google_cloud_key) == null);
    try std.testing.expect(!accounts.isAuthenticated(.google_cloud_key));

    var grok = testAccounts(.{ .xai = "xai-key" }, false, false);
    try std.testing.expect(grok.isAuthenticated(.xai_api_key));
    try std.testing.expectEqual(llm.Account.xai_api_key, grok.client(.xai_api_key).?.account());
    try std.testing.expectEqual(llm.Account.xai_api_key, grok.firstAuthenticated().?);
    grok.xai_plan_ready = true;
    try std.testing.expectEqual(llm.Account.xai_plan, grok.firstAuthenticated().?);
    try std.testing.expectEqual(
        llm.Account.xai_plan,
        grok.client(.xai_plan).?.account(),
    );
}

test "a client carries the timeout pair of its provider" {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    accounts.timeouts = .{
        .anthropic = .{ .idle_ms = 1 },
        .openai = .{ .idle_ms = 2 },
        .google = .{ .idle_ms = 3 },
        .xai = .{ .idle_ms = 4 },
        .deepseek = .{ .idle_ms = 5 },
        .ds4 = .{ .idle_ms = 6 },
    };
    try std.testing.expectEqual(
        @as(u64, 1),
        accounts.client(.anthropic_api_key).?.timeouts.idle_ms,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        accounts.client(.openai_api_key).?.timeouts.idle_ms,
    );
    try std.testing.expectEqual(@as(u64, 3), accounts.timeoutsOf(.google_cloud_key).idle_ms);
    try std.testing.expectEqual(@as(u64, 4), accounts.timeoutsOf(.xai_plan).idle_ms);
    try std.testing.expectEqual(@as(u64, 5), accounts.timeoutsOf(.deepseek_api_key).idle_ms);
    try std.testing.expectEqual(@as(u64, 6), accounts.timeoutsOf(.ds4).idle_ms);
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

    var half = try Accounts.init(gpa, io, home, .{}, .{ .google_location = "global" });
    defer half.deinit();
    try std.testing.expect(!half.isAuthenticated(.google_cloud_key));
    try std.testing.expect(half.google_error == null);

    var missing = try Accounts.init(gpa, io, home, .{}, .{
        .google_key_path = key_path,
        .google_location = "global",
    });
    defer missing.deinit();
    try std.testing.expect(!missing.isAuthenticated(.google_cloud_key));
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), missing.google_error);
    try std.testing.expectEqual(
        @as(?anyerror, error.FileNotFound),
        missing.loadError(.google_cloud_key),
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
    try std.testing.expect(ready.isAuthenticated(.google_cloud_key));
    try std.testing.expect(ready.google_error == null);
    try std.testing.expectEqual(llm.Account.google_cloud_key, ready.firstAuthenticated().?);
    try std.testing.expectEqual(
        llm.Account.google_cloud_key,
        ready.client(.google_cloud_key).?.account(),
    );
    try std.testing.expectEqualStrings("my-project", ready.google_auth.?.project);

    var bad_location = try Accounts.init(gpa, io, home, .{}, .{
        .anthropic = "sk-ant",
        .google_key_path = key_path,
        .google_location = "europe-west4",
    });
    defer bad_location.deinit();
    try std.testing.expectEqual(@as(?anyerror, error.BadLocation), bad_location.google_error);
    try std.testing.expectEqual(llm.Account.anthropic_api_key, bad_location.firstAuthenticated().?);
}

test "the DwarfStar account loads from DS4_BASE_URL and records a malformed URL" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var absent = try Accounts.init(gpa, io, home, .{}, .{});
    defer absent.deinit();
    try std.testing.expect(!absent.isAuthenticated(.ds4));
    try std.testing.expect(absent.loadError(.ds4) == null);

    var ready = try Accounts.init(gpa, io, home, .{}, .{
        .ds4_base_url = "http://127.0.0.1:8000/v1/",
    });
    defer ready.deinit();
    try std.testing.expect(ready.isAuthenticated(.ds4));
    try std.testing.expectEqualStrings("http://127.0.0.1:8000/v1", ready.ds4_base_url.?);
    try std.testing.expect(ready.loadError(.ds4) == null);
    try std.testing.expectEqual(llm.Account.ds4, ready.client(.ds4).?.account());

    for ([_][]const u8{
        "http://127.0.0.1:8000",
        "http://127.0.0.1:8000/v1?x=1",
        "http://127.0.0.1:8000/v1#frag",
        "ftp://127.0.0.1:8000/v1",
        "http:///v1",
    }) |configured| {
        var bad = try Accounts.init(gpa, io, home, .{}, .{ .ds4_base_url = configured });
        defer bad.deinit();
        try std.testing.expect(!bad.isAuthenticated(.ds4));
        try std.testing.expectEqual(@as(?anyerror, error.BadBaseUrl), bad.loadError(.ds4));
    }
}

test "startup drops a DwarfStar list that another URL stored" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var model = Model.init("deepseek-v4-pro") catch unreachable;
    model.thinking = .supported;
    model.tools = .supported;
    try model.setEngine("DeepSeek V4 Flash");

    var written = try Accounts.init(gpa, io, home, .{}, .{
        .ds4_base_url = "http://127.0.0.1:8000/v1",
    });
    try written.catalog.setAccountAt(.ds4, .{
        .models = &.{model},
        .base_url = written.ds4_base_url.?,
    });
    written.deinit();

    var same = try Accounts.init(gpa, io, home, .{}, .{
        .ds4_base_url = "http://127.0.0.1:8000/v1",
    });
    defer same.deinit();
    try std.testing.expect(!same.catalog.isEmpty(.ds4));

    var other = try Accounts.init(gpa, io, home, .{}, .{
        .ds4_base_url = "http://127.0.0.1:9000/v1",
    });
    defer other.deinit();
    try std.testing.expect(other.catalog.isEmpty(.ds4));
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
        \\{ "anthropic-plan":
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
    try std.testing.expect(accounts.isAuthenticated(.anthropic_plan));

    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try std.testing.expectError(
        error.BadCredentials,
        accounts.invalidate(.anthropic_plan),
    );
    try std.testing.expect(!accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expect(accounts.client(.anthropic_plan) == null);
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
        \\{ "openai-plan":
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
    defer gpa.free(accounts.catalog.accounts.get(.openai_plan));
    accounts.openai_auth = try openai.Auth.init(gpa, io, home, .{});
    defer accounts.openai_auth.deinit();
    try std.testing.expect(try accounts.openai_auth.load());
    try seedModel(&accounts, .openai_plan, "gpt-5.6-sol");
    try std.testing.expect(!accounts.catalog.isEmpty(.openai_plan));

    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try std.testing.expectError(
        error.BadCredentials,
        accounts.invalidate(.openai_plan),
    );
    try std.testing.expect(!accounts.isAuthenticated(.openai_plan));
    try std.testing.expect(accounts.openai_auth.tokens == null);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_plan));
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
        \\{ "openai-plan":
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
    defer gpa.free(accounts.catalog.accounts.get(.openai_plan));
    accounts.openai_auth = try openai.Auth.init(gpa, io, home, .{});
    defer accounts.openai_auth.deinit();
    try std.testing.expect(try accounts.openai_auth.load());
    try seedModel(&accounts, .openai_plan, "gpt-5.6-sol");

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "openai-plan":
        \\    { "access": "new_access", "refresh": "new_refresh",
        \\      "expires_ms": 4102444800000, "account_id": "account" } }
        ,
    });
    try std.testing.expect(try accounts.invalidate(.openai_plan));
    try std.testing.expect(accounts.isAuthenticated(.openai_plan));
    try std.testing.expectEqualStrings(
        "new_refresh",
        accounts.openai_auth.tokens.?.refresh,
    );
    try std.testing.expect(accounts.catalog.isEmpty(.openai_plan));
}

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
        \\{ "xai-plan":
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
    defer gpa.free(accounts.catalog.accounts.get(.xai_plan));
    accounts.xai_auth = try xai.Auth.init(gpa, io, home, .{});
    defer accounts.xai_auth.deinit();
    try std.testing.expect(try accounts.xai_auth.load());
    accounts.xai_plan_ready = true;
    try seedModel(&accounts, .xai_plan, "grok-4.6");

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "xai-plan":
        \\    { "access": "new_access", "refresh": "new_refresh",
        \\      "expires_ms": 4102444800000, "subject": "user-1" } }
        ,
    });
    try std.testing.expect(try accounts.invalidate(.xai_plan));
    try std.testing.expect(accounts.isAuthenticated(.xai_plan));
    try std.testing.expectEqualStrings("new_refresh", accounts.xai_auth.tokens.?.refresh);
    try std.testing.expect(accounts.catalog.isEmpty(.xai_plan));

    try seedModel(&accounts, .xai_plan, "grok-4.6");
    try std.testing.expect(!try accounts.invalidate(.xai_plan));
    try std.testing.expect(!accounts.isAuthenticated(.xai_plan));
    try std.testing.expect(accounts.client(.xai_plan) == null);
    try std.testing.expect(accounts.catalog.isEmpty(.xai_plan));
    var file = (try json_store.open(gpa, io, accounts.xai_auth.path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("xai-plan") == null);
}

test "a reread settles every login store and reports each change" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000,
        \\      "account_uuid": "user-1", "organization_uuid": "org-1" },
        \\  "anthropic-api": { "api_key": "minted" } }
        ,
    });
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var accounts = try Accounts.init(gpa, io, home, .{}, .{});
    defer accounts.deinit();
    try seedModel(&accounts, .anthropic_plan, "claude-opus-5");
    try seedModel(&accounts, .anthropic_api, "claude-opus-5");
    try seedModel(&accounts, .openai_plan, "gpt-5.6-sol");

    const same = accounts.reread();
    try std.testing.expect(same.read_error == null);
    for (std.enums.values(llm.Account)) |account|
        try std.testing.expectEqual(auth.Change.unchanged, same.changes.get(account));
    try std.testing.expect(!accounts.catalog.isEmpty(.anthropic_plan));

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "a2", "refresh": "r2", "expires_ms": 4102444800000,
        \\      "account_uuid": "user-1", "organization_uuid": "org-1" },
        \\  "openai-plan":
        \\    { "access": "o", "refresh": "or", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
        ,
    });
    const changed = accounts.reread();
    try std.testing.expect(changed.read_error == null);
    try std.testing.expectEqual(auth.Change.rotated, changed.changes.get(.anthropic_plan));
    try std.testing.expectEqual(auth.Change.signed_out, changed.changes.get(.anthropic_api));
    try std.testing.expectEqual(auth.Change.signed_in, changed.changes.get(.openai_plan));
    try std.testing.expectEqual(auth.Change.unchanged, changed.changes.get(.xai_plan));
    try std.testing.expect(accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expectEqualStrings("r2", accounts.anthropic_auth.tokens.?.refresh);
    try std.testing.expect(!accounts.isAuthenticated(.anthropic_api));
    try std.testing.expect(accounts.isAuthenticated(.openai_plan));
    try std.testing.expect(!accounts.catalog.isEmpty(.anthropic_plan));
    try std.testing.expect(accounts.catalog.isEmpty(.anthropic_api));
    try std.testing.expect(!accounts.catalog.isEmpty(.openai_plan));

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan":
        \\    { "access": "b", "refresh": "rb", "expires_ms": 4102444800000,
        \\      "account_uuid": "user-2", "organization_uuid": "org-2" } }
        ,
    });
    const replaced = accounts.reread();
    try std.testing.expectEqual(auth.Change.replaced, replaced.changes.get(.anthropic_plan));
    try std.testing.expectEqual(auth.Change.signed_out, replaced.changes.get(.openai_plan));
    try std.testing.expect(accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expect(accounts.catalog.isEmpty(.anthropic_plan));

    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    const failed = accounts.reread();
    try std.testing.expectEqual(@as(?anyerror, error.BadCredentials), failed.read_error);
    for (std.enums.values(llm.Account)) |account| {
        try std.testing.expectEqual(auth.Change.unchanged, failed.changes.get(account));
        try std.testing.expect(failed.entry_errors.get(account) == null);
    }
    try std.testing.expect(accounts.isAuthenticated(.anthropic_plan));
    try std.testing.expectEqualStrings("rb", accounts.anthropic_auth.tokens.?.refresh);

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "anthropic-plan": { "access": 1 },
        \\  "anthropic-api": { "api_key": "minted" } }
        ,
    });
    const partial = accounts.reread();
    try std.testing.expect(partial.read_error == null);
    try std.testing.expectEqual(
        @as(?anyerror, error.BadCredentials),
        partial.entry_errors.get(.anthropic_plan),
    );
    try std.testing.expect(partial.entry_errors.get(.anthropic_api) == null);
    try std.testing.expectEqual(auth.Change.unchanged, partial.changes.get(.anthropic_plan));
    try std.testing.expectEqual(auth.Change.signed_in, partial.changes.get(.anthropic_api));
    try std.testing.expectEqualStrings("rb", accounts.anthropic_auth.tokens.?.refresh);
    try std.testing.expect(accounts.isAuthenticated(.anthropic_api));
}

test "a registry with no store keeps its credentials in memory alone" {
    var accounts = testAccounts(.{}, true, false);
    const report = accounts.reread();
    try std.testing.expect(report.read_error == null);
    for (std.enums.values(llm.Account)) |account|
        try std.testing.expectEqual(auth.Change.unchanged, report.changes.get(account));
    try std.testing.expect(accounts.isAuthenticated(.anthropic_plan));
}

test "a principal replacement drops the list of that account alone" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{}, false, true);
    defer for (std.enums.values(llm.Account)) |account|
        gpa.free(accounts.catalog.accounts.get(account));

    try seedModel(&accounts, .openai_plan, "gpt-5.6-sol");
    try seedModel(&accounts, .anthropic_plan, "claude-opus-5");

    accounts.dropPrincipalMetadata(.anthropic_plan);
    try std.testing.expect(accounts.catalog.isEmpty(.anthropic_plan));
    try std.testing.expect(!accounts.catalog.isEmpty(.openai_plan));

    accounts.dropPrincipalMetadata(.openai_plan);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_plan));
}

test "a failed cache write reports a failed save, not a failed fetch" {
    var result: Refresh = .{};
    recordSave(&result.models_save_error, {});
    try std.testing.expect(result.models_save_error == null);

    recordSave(&result.models_save_error, error.StoreBusy);
    try std.testing.expectEqual(@as(?anyerror, error.StoreBusy), result.models_save_error);
    try std.testing.expect(result.models_error == null);
    try std.testing.expect(result.metadata_error == null);

    recordSave(&result.metadata_save_error, error.AccessDenied);
    try std.testing.expectEqual(@as(?anyerror, error.StoreBusy), result.models_save_error);
    try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), result.metadata_save_error);
}

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
        .openrouter_api,
        unbounded,
        refuseList,
        openrouterMetadata,
    );
    try std.testing.expect(arrived.models_error == null);
    try std.testing.expectEqual(@as(usize, 1), arrived.count);
}

test "a DwarfStar fetch skips public metadata" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{ .ds4_base_url = "http://127.0.0.1:8000/v1" }, false, false);
    defer {
        gpa.free(accounts.catalog.accounts.get(.ds4));
        if (accounts.catalog.base_urls.get(.ds4)) |base_url| gpa.free(base_url);
    }
    const unbounded: net.Deadline = .{ .at = null };

    const refused = accounts.refreshWithin(.ds4, unbounded, refuseList, refuseMetadata);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionRefused), refused.models_error);
    try std.testing.expect(refused.metadata_error == null);

    const arrived = accounts.refreshWithin(.ds4, unbounded, ds4List, refuseMetadata);
    try std.testing.expect(arrived.models_error == null);
    try std.testing.expect(arrived.metadata_error == null);
    try std.testing.expectEqual(@as(usize, 1), arrived.count);
}

fn ds4List(self: *Accounts, account: llm.Account, _: net.Deadline) ![]Model {
    std.debug.assert(account == .ds4);
    var model = try Model.init("deepseek-v4-pro");
    model.thinking = .supported;
    model.tools = .supported;
    try model.setEngine("DeepSeek V4 Flash");
    return try self.gpa.dupe(Model, &.{model});
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

    try std.testing.expect(accounts.catalog.isEmpty(.openai_plan));
    try std.testing.expect(!accounts.offersModel(.openai_plan));
    try seedModel(&accounts, .openai_plan, "gpt-5.6-sol");
    try std.testing.expect(accounts.offersModel(.openai_plan));

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(gpa);
    try accounts.listModels(.openai_plan, &listed, gpa);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed.items[0].name());
    try std.testing.expect(accounts.findModel(.openai_plan, "gpt-5.6-sol") != null);

    try std.testing.expect(accounts.findModel(.openai_api_key, "gpt-5.6-sol") == null);
    try std.testing.expect(accounts.catalog.isEmpty(.openai_api_key));
    try std.testing.expect(!accounts.offersModel(.openai_api_key));
}
