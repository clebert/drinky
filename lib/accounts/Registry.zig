const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Account = @import("Account.zig");
const anthropic = @import("anthropic/root.zig");
const Catalog = @import("Catalog.zig");
const Client = @import("Client.zig");
const google = @import("google/root.zig");
const json_store = @import("json_store.zig");
const Metadata = @import("Metadata.zig");
const Model = @import("Model.zig");
const oauth = @import("oauth/root.zig");
const openai = @import("openai/root.zig");
const openrouter = @import("openrouter/root.zig");
const paging = @import("paging.zig");
const responses = @import("responses/root.zig");
const testing = @import("testing.zig");
const xai = @import("xai/root.zig");

const Registry = @This();

const mail_capacity: usize = 16;
const key_file_path_variable = "GOOGLE_APPLICATION_CREDENTIALS";
const key_file_location_variable = "GOOGLE_CLOUD_LOCATION";

gpa: std.mem.Allocator,
io: std.Io,
timeouts: Timeouts,
transport: ?providers.Transport,
browser: ?oauth.login.Browser,
loopback: ?oauth.callback.Loopback,
opener: oauth.login.Opener,
socket: oauth.callback.Socket,
slots: [Account.table.len]Slot,
load_errors: [Account.table.len]?LoadError,
catalog: Catalog,
sink: Sink,
mailbox: core.actor.Mailbox(Mail, mail_capacity),
loop: ?std.Io.Future(void),
worker: ?Worker,

pub const LoadError = oauth.store.Error || google.Auth.InitError;

pub const FetchError = paging.Error ||
    Metadata.FetchError ||
    oauth.store.TokenError ||
    error{SignedOut};

pub const Timeouts = std.EnumArray(Account.Vendor, providers.Transport.Timeouts);

const Wait = struct {
    idle_ms: u64 = @as(providers.Transport.Timeouts, .{}).idle_ms,
    idle_note: []const u8,
};

pub const waits: std.EnumArray(Account.Vendor, Wait) = .init(.{
    .anthropic = .{
        .idle_note = "A keepalive ping is not an event and does not restart the wait.",
    },
    .openai = .{
        .idle_ms = 300_000,
        .idle_note = "The stream is silent while the model reasons privately, so the default " ++
            "matches the wait of the official client.",
    },
    .xai = .{
        .idle_ms = 300_000,
        .idle_note = "The stream can stay silent while the model reasons, so the default " ++
            "matches the OpenAI wait.",
    },
    .openrouter = .{
        .idle_ms = 300_000,
        .idle_note = "The stream can stay silent while the model reasons, so the default " ++
            "matches the OpenAI wait.",
    },
    .deepseek = .{
        .idle_ms = 300_000,
        .idle_note = "The first reasoning event can take a long time to arrive, so the " ++
            "default matches the OpenAI wait.",
    },
    .google = .{
        .idle_ms = 300_000,
        .idle_note = "The stream can stay silent while the model thinks, so the default " ++
            "matches the OpenAI wait.",
    },
});

pub const timeouts_default: Timeouts = timeouts: {
    var timeouts: Timeouts = undefined;
    for (std.enums.values(Account.Vendor)) |vendor| {
        timeouts.set(vendor, .{ .idle_ms = waits.get(vendor).idle_ms });
    }
    break :timeouts timeouts;
};

const Options = struct {
    directories: json_store.Directories,
    environment: *const std.process.Environ.Map,
    sink: Sink,
    timeouts: Timeouts = timeouts_default,
    transport: ?providers.Transport = null,
    browser: ?oauth.login.Browser = null,
    loopback: ?oauth.callback.Loopback = null,
};

pub const Sink = core.actor.Sink(Event);

const Command = union(enum) {
    login: usize,
    fetch: usize,
    paste: []const u8,
    cancel,

    fn dupe(self: *const Command, gpa: std.mem.Allocator) error{OutOfMemory}!Command {
        return switch (self.*) {
            .paste => |line| .{ .paste = try gpa.dupe(u8, line) },
            .login, .fetch, .cancel => self.*,
        };
    }

    fn deinit(self: *const Command, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .paste => |line| gpa.free(line),
            .login, .fetch, .cancel => {},
        }
    }
};

pub const Event = union(enum) {
    refused: Refusal,
    authorization: Authorization,
    browser_launch_failed: usize,
    paste_replayed,
    paste_refused: Paste,
    login_ended: LoginEnd,
    fetch_ended: FetchEnd,

    pub const Refusal = struct {
        account: usize,
        command: enum { login, fetch },
        reason: enum { busy, no_login, signed_out },
    };

    pub const Authorization = struct {
        account: usize,
        url: []const u8,
        code: ?[]const u8,
        callback_path: ?[]const u8,

        fn dupe(
            self: *const Authorization,
            gpa: std.mem.Allocator,
        ) error{OutOfMemory}!Authorization {
            const url = try gpa.dupe(u8, self.url);
            errdefer gpa.free(url);
            const code = if (self.code) |code| try gpa.dupe(u8, code) else null;
            errdefer if (code) |owned| gpa.free(owned);
            const callback_path = if (self.callback_path) |path| try gpa.dupe(u8, path) else null;
            return .{
                .account = self.account,
                .url = url,
                .code = code,
                .callback_path = callback_path,
            };
        }

        fn deinit(self: *const Authorization, gpa: std.mem.Allocator) void {
            gpa.free(self.url);
            if (self.code) |code| gpa.free(code);
            if (self.callback_path) |path| gpa.free(path);
        }
    };

    pub const Paste = union(enum) {
        not_waiting,
        not_a_redirect: usize,
        replay_failed: oauth.callback.Loopback.ReplayError,
    };

    pub const LoginEnd = struct {
        account: usize,
        outcome: oauth.store.SignInError!oauth.store.Commit,
    };

    pub const FetchEnd = struct {
        account: usize,
        refresh: Refresh,
    };

    pub fn dupe(self: *const Event, gpa: std.mem.Allocator) error{OutOfMemory}!Event {
        return switch (self.*) {
            .authorization => |*authorization| .{ .authorization = try authorization.dupe(gpa) },
            .login_ended => |ended| .{ .login_ended = .{
                .account = ended.account,
                .outcome = if (ended.outcome) |login| switch (login) {
                    .saved => |path| .{ .saved = gpa.dupe(u8, path) catch "" },
                    .memory_only => |failure| .{ .memory_only = .{
                        .path = gpa.dupe(u8, failure.path) catch "",
                        .save_error = failure.save_error,
                    } },
                } else |err| err,
            } },
            .refused,
            .browser_launch_failed,
            .paste_replayed,
            .paste_refused,
            .fetch_ended,
            => self.*,
        };
    }

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .authorization => |*authorization| authorization.deinit(gpa),
            .login_ended => |ended| {
                const login = ended.outcome catch return;
                switch (login) {
                    .saved => |path| gpa.free(path),
                    .memory_only => |failure| gpa.free(failure.path),
                }
            },
            .refused,
            .browser_launch_failed,
            .paste_replayed,
            .paste_refused,
            .fetch_ended,
            => {},
        }
    }
};

pub const Refresh = struct {
    count: usize = 0,
    models_error: ?FetchError = null,
    metadata_error: ?Metadata.FetchError = null,
    models_save_error: ?json_store.SaveError = null,
    metadata_save_error: ?json_store.SaveError = null,
};

const Callback = struct {
    port: u16,
    binding: oauth.callback.Binding,
};

const Slot = union(enum) {
    absent,
    key: Key,
    login: Login,
    google: google.Auth,

    fn deinit(self: *Slot) void {
        switch (self.*) {
            .absent, .key => {},
            .login => |*login| switch (login.*) {
                inline else => |*store| store.deinit(),
            },
            .google => |*auth| auth.deinit(),
        }
    }
};

const Login = union(Account.Login) {
    claude: oauth.Store(anthropic.oauth),
    console: oauth.Store(anthropic.console),
    chatgpt: oauth.Store(openai.oauth),
    grok: oauth.Store(xai.oauth),
    openrouter: oauth.Store(openrouter.oauth),
};

const Key = struct {
    value: []const u8,

    const vtable: providers.Credential.VTable = .{ .token = token, .renew = renew };

    fn credential(self: *Key) providers.Credential {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn token(ptr: *anyopaque, gpa: std.mem.Allocator) providers.Credential.Error!?[]const u8 {
        const self: *Key = @ptrCast(@alignCast(ptr));
        return try gpa.dupe(u8, self.value);
    }

    fn renew(ptr: *anyopaque) providers.Credential.Error!bool {
        _ = ptr;
        return false;
    }
};

const Mail = union(enum) {
    command: Command,
    shown: Event.Authorization,
    browser_launch_failed: usize,
    login_ended: oauth.store.SignInError!oauth.store.Commit,
    fetch_ended: Refresh,

    pub fn deinit(self: *const Mail, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .command => |*command| command.deinit(gpa),
            .shown => |*authorization| authorization.deinit(gpa),
            .browser_launch_failed, .login_ended, .fetch_ended => {},
        }
    }
};

const Worker = struct {
    kind: enum { login, fetch },
    account: usize,
    path_buffer: [oauth.callback.path_bytes_max]u8,
    path_length: usize,

    fn path(self: *const Worker) ?[]const u8 {
        return if (self.path_length == 0) null else self.path_buffer[0..self.path_length];
    }
};

const Prompt = struct {
    registry: *Registry,
    account: usize,

    const vtable: oauth.login.Prompt.VTable = .{
        .showAuthorization = showAuthorization,
        .showDeviceCode = showDeviceCode,
        .showBrowserLaunchFailed = showBrowserLaunchFailed,
    };

    fn prompt(self: *Prompt) oauth.login.Prompt {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn showAuthorization(
        ptr: *anyopaque,
        url: []const u8,
        callback_path: ?[]const u8,
    ) error{OutOfMemory}!void {
        const self: *Prompt = @ptrCast(@alignCast(ptr));
        try self.post(&.{
            .account = self.account,
            .url = url,
            .code = null,
            .callback_path = callback_path,
        });
    }

    fn showDeviceCode(
        ptr: *anyopaque,
        url: []const u8,
        code: []const u8,
    ) error{OutOfMemory}!void {
        const self: *Prompt = @ptrCast(@alignCast(ptr));
        try self.post(&.{
            .account = self.account,
            .url = url,
            .code = code,
            .callback_path = null,
        });
    }

    fn showBrowserLaunchFailed(ptr: *anyopaque) void {
        const self: *Prompt = @ptrCast(@alignCast(ptr));
        self.registry.post(.{ .browser_launch_failed = self.account });
    }

    fn post(self: *Prompt, authorization: *const Event.Authorization) error{OutOfMemory}!void {
        self.registry.post(.{ .shown = try authorization.dupe(self.registry.gpa) });
    }
};

pub fn init(self: *Registry, gpa: std.mem.Allocator, io: std.Io, options: *const Options) !void {
    self.gpa = gpa;
    self.io = io;
    self.timeouts = options.timeouts;
    self.transport = options.transport;
    self.browser = options.browser;
    self.loopback = options.loopback;
    self.opener = .{ .io = io };
    self.socket = .{ .io = io };
    self.sink = options.sink;
    self.loop = null;
    self.worker = null;
    self.load_errors = @splat(null);
    var loaded: usize = 0;
    errdefer for (self.slots[0..loaded]) |*slot| slot.deinit();
    for (&Account.table, &self.slots, &self.load_errors) |*row, *slot, *load_error| {
        slot.* = try self.load(row, options, load_error);
        loaded += 1;
    }
    self.catalog = try Catalog.init(gpa, io, &options.directories);
    self.mailbox = .init;
}

fn load(
    self: *Registry,
    row: *const Account,
    options: *const Options,
    load_error: *?LoadError,
) error{OutOfMemory}!Slot {
    const environment = options.environment;
    const link: oauth.wire.Link = .{
        .transport = self.transport,
        .timeouts = self.timeouts.get(row.vendor),
    };
    switch (row.credential) {
        .environment => |name| {
            const key = environment.get(name) orelse return .absent;
            return .{ .key = .{ .value = key } };
        },
        .key_file => {
            const key_path = environment.get(key_file_path_variable) orelse return .absent;
            const location = environment.get(key_file_location_variable) orelse return .absent;
            const auth = google.Auth.init(self.gpa, self.io, link, &.{
                .key_path = key_path,
                .location = location,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    load_error.* = err;
                    return .absent;
                },
            };
            return .{ .google = auth };
        },
        .store => |flow| return .{ .login = try self.openLogin(flow, &.{
            .directories = options.directories,
            .account = row.id,
            .link = link,
        }, load_error) },
    }
}

fn openLogin(
    self: *Registry,
    flow: Account.Login,
    options: *const oauth.store.Options,
    load_error: *?LoadError,
) error{OutOfMemory}!Login {
    switch (flow) {
        inline else => |tag| {
            var store = try @FieldType(Login, @tagName(tag)).init(self.gpa, self.io, options);
            if (store.load()) |_| {} else |err| switch (err) {
                error.OutOfMemory => {
                    store.deinit();
                    return error.OutOfMemory;
                },
                else => load_error.* = err,
            }
            return @unionInit(Login, @tagName(tag), store);
        },
    }
}

pub fn start(self: *Registry) std.Io.ConcurrentError!void {
    self.loop = try self.io.concurrent(run, .{self});
}

pub fn deinit(self: *Registry) void {
    if (self.loop) |*loop| loop.cancel(self.io);
    self.loop = null;
    self.mailbox.close(self.io);
    self.mailbox.drain(self.io, self.gpa);
    self.catalog.deinit();
    for (&self.slots) |*slot| slot.deinit();
}

pub fn send(self: *Registry, command: *const Command) error{OutOfMemory}!void {
    const mail: Mail = .{ .command = try command.dupe(self.gpa) };
    self.mailbox.send(self.io, mail) catch mail.deinit(self.gpa);
}

pub fn isAuthenticated(self: *Registry, index: usize) bool {
    return switch (self.slots[index]) {
        .absent => false,
        .key, .google => true,
        .login => |*login| switch (login.*) {
            inline else => |*store| store.signedIn(),
        },
    };
}

pub fn loadError(self: *const Registry, index: usize) ?LoadError {
    return self.load_errors[index];
}

pub fn firstAuthenticated(self: *Registry) ?usize {
    for (&Account.table, 0..) |*row, index| {
        if (row.hasLogin() and self.isAuthenticated(index)) return index;
    }
    for (&Account.table, 0..) |_, index| {
        if (self.isAuthenticated(index)) return index;
    }
    return null;
}

fn credential(self: *Registry, index: usize) ?providers.Credential {
    if (!self.isAuthenticated(index)) return null;
    return switch (self.slots[index]) {
        .absent => unreachable,
        .key => |*key| key.credential(),
        .login => |*login| switch (login.*) {
            inline else => |*store| store.credential(),
        },
        .google => |*auth| auth.credential(),
    };
}

pub fn open(self: *Registry, client: *Client, index: usize) error{ SignedOut, OutOfMemory }!void {
    const found = self.credential(index) orelse return error.SignedOut;
    var options: Client.Options = .{
        .account = &Account.table[index],
        .credential = found,
        .timeouts = self.timeoutsOf(index),
        .transport = self.transport,
    };
    var maybe_account_id: ?[]const u8 = null;
    defer if (maybe_account_id) |account_id| self.gpa.free(account_id);
    switch (self.slots[index]) {
        .login => |*login| switch (login.*) {
            .chatgpt => |*store| {
                maybe_account_id = try store.copyField("account_id", self.gpa);
                options.codex_account_id = maybe_account_id orelse "";
            },
            .claude, .console, .grok, .openrouter => {},
        },
        .google => |*auth| {
            options.project = auth.project;
            options.location = auth.location;
        },
        .absent, .key => {},
    }
    try client.init(self.gpa, self.io, &options);
}

fn timeoutsOf(self: *const Registry, index: usize) providers.Transport.Timeouts {
    return self.timeouts.get(Account.table[index].vendor);
}

pub fn takesPaste(account: *const Account) bool {
    return callback(account) != null;
}

fn callback(account: *const Account) ?Callback {
    const login = switch (account.credential) {
        .store => |flow| flow,
        .environment, .key_file => return null,
    };
    switch (login) {
        inline else => |tag| {
            const flow = @FieldType(Login, @tagName(tag)).flow;
            return switch (flow.sign_in) {
                .callback => |binding| .{ .port = flow.callback_port, .binding = binding },
                .device => null,
            };
        },
    }
}

pub fn logout(self: *Registry, index: usize) !void {
    switch (self.slots[index]) {
        .login => |*login| {
            switch (login.*) {
                inline else => |*store| try store.signOut(),
            }
            self.load_errors[index] = null;
            self.catalog.dropAccount(index);
        },
        .absent, .key, .google => return error.AccountHasNoLogout,
    }
}

pub fn invalidate(
    self: *Registry,
    index: usize,
) (oauth.store.Error || error{AccountHasNoRefreshCredential})!bool {
    const login = switch (self.slots[index]) {
        .login => |*login| login,
        .absent, .key, .google => return error.AccountHasNoRefreshCredential,
    };
    switch (login.*) {
        inline else => |*store| switch (comptime @TypeOf(store.*).flow.secret) {
            .access_token => {
                defer self.catalog.dropAccount(index);
                self.load_errors[index] = null;
                return store.invalidate();
            },
            .api_key => return error.AccountHasNoRefreshCredential,
        },
    }
}

pub fn findModel(self: *Registry, index: usize, name: []const u8) ?Model {
    return self.catalog.find(index, name);
}

pub fn offersModel(self: *Registry, index: usize) bool {
    return !self.catalog.isEmpty(index);
}

pub fn listModels(
    self: *Registry,
    index: usize,
    out: *std.ArrayList(Model),
    gpa: std.mem.Allocator,
) !void {
    try self.catalog.list(index, out, gpa);
}

fn run(self: *Registry) void {
    self.serve() catch {};
    self.mailbox.cancel(self.io);
    self.mailbox.reap(self.io);
    self.worker = null;
    self.mailbox.drain(self.io, self.gpa);
}

fn serve(self: *Registry) core.actor.Mailbox(Mail, mail_capacity).Error!void {
    while (true) {
        switch (try self.mailbox.receive(self.io)) {
            .command => |command| self.handle(command),
            .shown => |*authorization| self.show(authorization),
            .browser_launch_failed => |account| self.emit(&.{ .browser_launch_failed = account }),
            .login_ended => |outcome| self.endLogin(outcome),
            .fetch_ended => |result| self.endFetch(result),
        }
    }
}

fn handle(self: *Registry, command: Command) void {
    switch (command) {
        .login => |index| self.startLogin(index),
        .fetch => |index| self.startFetch(index),
        .paste => |line| {
            defer self.gpa.free(line);
            self.paste(line);
        },
        .cancel => self.mailbox.cancel(self.io),
    }
}

fn startLogin(self: *Registry, index: usize) void {
    if (self.worker != null) return self.refuse(index, .login, .busy);
    if (!Account.table[index].hasLogin()) return self.refuse(index, .login, .no_login);
    self.startWorker(.login, index, runLogin);
}

fn startFetch(self: *Registry, index: usize) void {
    if (self.worker != null) return self.refuse(index, .fetch, .busy);
    if (!self.isAuthenticated(index)) return self.refuse(index, .fetch, .signed_out);
    self.startWorker(.fetch, index, runFetch);
}

fn startWorker(
    self: *Registry,
    kind: @FieldType(Worker, "kind"),
    index: usize,
    comptime work: fn (*Registry, usize) Mail,
) void {
    self.worker = .{
        .kind = kind,
        .account = index,
        .path_buffer = undefined,
        .path_length = 0,
    };
    self.mailbox.start(self.io, work, .{ self, index }) catch |err| {
        self.worker = null;
        return switch (kind) {
            .login => self.emit(&.{ .login_ended = .{
                .account = index,
                .outcome = err,
            } }),
            .fetch => self.emit(&.{ .fetch_ended = .{
                .account = index,
                .refresh = .{ .models_error = err },
            } }),
        };
    };
}

fn refuse(
    self: *Registry,
    index: usize,
    command: @FieldType(Event.Refusal, "command"),
    reason: @FieldType(Event.Refusal, "reason"),
) void {
    self.emit(&.{ .refused = .{ .account = index, .command = command, .reason = reason } });
}

fn runLogin(self: *Registry, index: usize) Mail {
    var prompt: Prompt = .{ .registry = self, .account = index };
    const context: oauth.login.Context = .{
        .prompt = prompt.prompt(),
        .browser = self.browser orelse self.opener.browser(),
        .loopback = self.loopbackOf(),
    };
    return .{ .login_ended = switch (self.slots[index]) {
        .login => |*login| switch (login.*) {
            inline else => |*store| store.signIn(&context),
        },
        .absent, .key, .google => unreachable,
    } };
}

fn runFetch(self: *Registry, index: usize) Mail {
    return .{ .fetch_ended = self.refresh(index) };
}

fn endLogin(self: *Registry, outcome: oauth.store.SignInError!oauth.store.Commit) void {
    const account = self.reap() orelse return;
    self.emit(&.{ .login_ended = .{ .account = account, .outcome = outcome } });
}

fn endFetch(self: *Registry, result: Refresh) void {
    const account = self.reap() orelse return;
    self.emit(&.{ .fetch_ended = .{ .account = account, .refresh = result } });
}

fn reap(self: *Registry) ?usize {
    const worker = self.worker orelse return null;
    self.mailbox.reap(self.io);
    self.worker = null;
    return worker.account;
}

fn post(self: *Registry, mail: Mail) void {
    self.mailbox.post(self.io, mail) catch |err| {
        mail.deinit(self.gpa);
        if (err == error.Canceled) self.io.recancel();
    };
}

fn show(self: *Registry, authorization: *const Event.Authorization) void {
    defer authorization.deinit(self.gpa);
    if (authorization.callback_path) |path| self.recordPath(path);
    self.emit(&.{ .authorization = authorization.* });
}

fn recordPath(self: *Registry, found: []const u8) void {
    const worker = if (self.worker) |*worker| worker else return;
    std.debug.assert(found.len <= worker.path_buffer.len);
    @memcpy(worker.path_buffer[0..found.len], found);
    worker.path_length = found.len;
}

fn paste(self: *Registry, line: []const u8) void {
    const worker = if (self.worker) |*worker|
        worker
    else
        return self.emit(&.{ .paste_refused = .not_waiting });
    if (worker.kind != .login) return self.emit(&.{ .paste_refused = .not_waiting });
    const found = callback(&Account.table[worker.account]) orelse
        return self.emit(&.{ .paste_refused = .not_waiting });
    const accepted = switch (found.binding) {
        .state => oauth.callback.holdsStateRedirect(line),
        .path => if (worker.path()) |path|
            oauth.callback.holdsPathRedirect(&.{ .line = line, .path = path })
        else
            false,
    };
    if (!accepted) return self.emit(&.{ .paste_refused = .{ .not_a_redirect = worker.account } });
    self.loopbackOf().replay(found.port, line) catch |err| {
        return self.emit(&.{ .paste_refused = .{ .replay_failed = err } });
    };
    self.emit(&.paste_replayed);
}

fn loopbackOf(self: *Registry) oauth.callback.Loopback {
    return self.loopback orelse self.socket.loopback();
}

fn emit(self: *Registry, event: *const Event) void {
    self.sink.emit(self.io, event);
}

fn refresh(self: *Registry, index: usize) Refresh {
    const deadline = core.timeout.Deadline.start(self.io, self.timeoutsOf(index).connect_ms);
    var result: Refresh = .{};
    const public = Account.table[index].model_source == .public;

    if (!public) {
        if (self.fetchModels(index, &deadline)) |discovered| {
            defer self.gpa.free(discovered);
            recordSave(&result.models_save_error, self.catalog.setAccount(index, discovered));
        } else |err| {
            result.models_error = err;
        }
        if (isCanceled(FetchError, result.models_error)) return result;
        if (isCanceled(json_store.SaveError, result.models_save_error)) return result;
    }
    if (Metadata.fetch(self.gpa, self.io, self.transport, &deadline)) |metadata| {
        recordSave(&result.metadata_save_error, self.catalog.setMetadata(metadata));
    } else |err| {
        if (public) result.models_error = err else result.metadata_error = err;
    }

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(self.gpa);
    if (self.catalog.list(index, &listed, self.gpa)) {
        result.count = listed.items.len;
    } else |_| {}
    return result;
}

fn modelsUrl(gpa: std.mem.Allocator, row: *const Account) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/models", .{row.dialect.responses.base_url});
}

fn recordSave(target: *?json_store.SaveError, outcome: json_store.SaveError!void) void {
    outcome catch |err| {
        target.* = err;
    };
}

fn isCanceled(comptime Set: type, maybe_error: ?Set) bool {
    const err = maybe_error orelse return false;
    return err == error.Canceled;
}

fn fetchModels(
    self: *Registry,
    index: usize,
    deadline: *const core.timeout.Deadline,
) FetchError![]Model {
    const row = &Account.table[index];
    const slot = &self.slots[index];
    var secrets: std.heap.ArenaAllocator = .init(self.gpa);
    defer secrets.deinit();
    const copies = secrets.allocator();
    switch (row.model_source) {
        .messages => return anthropic.models.fetch(self.gpa, self.io, self.transport, deadline, &.{
            .identity = row.dialect.messages,
            .token = try self.fetchToken(index, deadline, copies),
        }),
        .codex => {
            const token = try self.fetchToken(index, deadline, copies);
            const account_id = (try slot.login.chatgpt.copyField("account_id", copies)) orelse "";
            return openai.models.fetchSubscription(self.gpa, self.io, self.transport, deadline, &.{
                .token = token,
                .account_id = account_id,
            });
        },
        .responses => {
            const endpoint = try modelsUrl(self.gpa, row);
            defer self.gpa.free(endpoint);
            return responses.models.fetch(self.gpa, self.io, self.transport, deadline, &.{
                .endpoint = endpoint,
                .token = try self.fetchToken(index, deadline, copies),
            });
        },
        .gemini => return google.models.fetch(self.gpa, self.io, self.transport, deadline, &.{
            .access_token = try self.fetchToken(index, deadline, copies),
            .location = slot.google.location,
        }),
        .public => unreachable,
    }
}

fn fetchToken(
    self: *Registry,
    index: usize,
    deadline: *const core.timeout.Deadline,
    copies: std.mem.Allocator,
) ![]const u8 {
    return switch (self.slots[index]) {
        .key => |key| key.value,
        .login => |*login| switch (login.*) {
            inline else => |*store| switch (comptime @TypeOf(store.*).flow.secret) {
                .access_token => deadline.run(
                    self.io,
                    @TypeOf(store.*).accessToken,
                    .{ store, copies },
                    null,
                ),
                .api_key => (try store.apiKey(copies)) orelse error.SignedOut,
            },
        },
        .google => |*auth| deadline.run(self.io, google.Auth.accessToken, .{ auth, copies }, null),
        .absent => unreachable,
    };
}

test "the environment keys authenticate their accounts, and a login account comes first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);

    var keys: testing.Rig = undefined;
    try keys.init(gpa, io, &.{ .home = home, .variables = &.{
        .{ "ANTHROPIC_API_KEY", "sk-ant" },
        .{ "OPENAI_API_KEY", "sk-openai" },
    } });
    defer keys.deinit();
    try std.testing.expect(keys.registry.isAuthenticated(testing.anthropic_api_key));
    try std.testing.expect(keys.registry.isAuthenticated(testing.openai_api_key));
    try std.testing.expect(!keys.registry.isAuthenticated(testing.anthropic_plan));
    try std.testing.expect(!keys.registry.isAuthenticated(testing.xai_api_key));
    try std.testing.expect(!keys.registry.isAuthenticated(testing.google_cloud_key));
    try std.testing.expectEqual(testing.anthropic_api_key, keys.registry.firstAuthenticated().?);
    try std.testing.expect(keys.registry.credential(testing.anthropic_api_key) != null);
    try std.testing.expect(keys.registry.credential(testing.openai_plan) == null);
    try expectToken("sk-ant", keys.registry.credential(testing.anthropic_api_key).?);
    try std.testing.expect(!try keys.registry.credential(testing.anthropic_api_key).?.renew());

    var none: testing.Rig = undefined;
    try none.init(gpa, io, &.{ .home = home });
    defer none.deinit();
    try std.testing.expect(none.registry.firstAuthenticated() == null);

    try testing.writeStore(io, &tmp,
        \\{ "openai-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
    );
    var signed_in: testing.Rig = undefined;
    try signed_in.init(gpa, io, &.{
        .home = home,
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
    });
    defer signed_in.deinit();
    try std.testing.expect(signed_in.registry.isAuthenticated(testing.openai_plan));
    try std.testing.expectEqual(testing.openai_plan, signed_in.registry.firstAuthenticated().?);
    try expectToken("a", signed_in.registry.credential(testing.openai_plan).?);
}

test "a malformed store leaves its accounts signed out, and the other accounts start" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);
    const variables = [_][2][]const u8{.{ "ANTHROPIC_API_KEY", "sk-ant" }};

    try testing.writeStore(io, &tmp,
        \\{ "openai-plan": { "access": "a" },
        \\  "xai-plan": { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
    );
    var entry: testing.Rig = undefined;
    try entry.init(gpa, io, &.{ .home = home, .variables = &variables });
    defer entry.deinit();
    try std.testing.expect(!entry.registry.isAuthenticated(testing.openai_plan));
    try std.testing.expectEqual(
        @as(?LoadError, error.BadCredentials),
        entry.registry.loadError(testing.openai_plan),
    );
    try std.testing.expect(entry.registry.isAuthenticated(testing.xai_plan));
    try std.testing.expect(entry.registry.loadError(testing.xai_plan) == null);
    try std.testing.expect(entry.registry.isAuthenticated(testing.anthropic_api_key));
    try entry.registry.logout(testing.openai_plan);
    try std.testing.expect(entry.registry.loadError(testing.openai_plan) == null);

    try testing.writeStore(io, &tmp, "not json");
    var file: testing.Rig = undefined;
    try file.init(gpa, io, &.{ .home = home, .variables = &variables });
    defer file.deinit();
    for (Account.table, 0..) |row, index| {
        if (row.credential != .store) continue;
        try std.testing.expect(!file.registry.isAuthenticated(index));
        try std.testing.expectEqual(
            @as(?LoadError, error.BadCredentials),
            file.registry.loadError(index),
        );
    }
    try std.testing.expectEqual(testing.anthropic_api_key, file.registry.firstAuthenticated().?);
}

test "a client opens for an authenticated account and not for a signed-out one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);

    var timeouts = timeouts_default;
    timeouts.set(.xai, .{ .idle_ms = 4 });
    var rig: testing.Rig = undefined;
    try rig.init(gpa, io, &.{
        .home = home,
        .timeouts = timeouts,
        .variables = &.{.{ "XAI_API_KEY", "xai-key" }},
    });
    defer rig.deinit();

    var client: Client = undefined;
    try rig.registry.open(&client, testing.xai_api_key);
    defer client.deinit();
    try expectRequestLine(&rig, &client, "POST https://api.x.ai/v1/responses\n");
    try std.testing.expectEqual(@as(u64, 4), rig.registry.timeoutsOf(testing.xai_api_key).idle_ms);

    var refused: Client = undefined;
    try std.testing.expectError(
        error.SignedOut,
        rig.registry.open(
            &refused,
            testing.openai_api_key,
        ),
    );
}

test "the key file account loads from the key file and records a failed load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);
    var key_buffer: [160]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, "{s}/key.json", .{home});

    var half: testing.Rig = undefined;
    try half.init(gpa, io, &.{
        .home = home,
        .variables = &.{.{ "GOOGLE_CLOUD_LOCATION", "global" }},
    });
    defer half.deinit();
    try std.testing.expect(!half.registry.isAuthenticated(testing.google_cloud_key));
    try std.testing.expect(half.registry.loadError(testing.google_cloud_key) == null);

    var missing: testing.Rig = undefined;
    try missing.init(gpa, io, &.{ .home = home, .variables = &.{
        .{ "GOOGLE_APPLICATION_CREDENTIALS", key_path },
        .{ "GOOGLE_CLOUD_LOCATION", "global" },
    } });
    defer missing.deinit();
    try std.testing.expect(!missing.registry.isAuthenticated(testing.google_cloud_key));
    try std.testing.expectEqual(
        @as(?LoadError, error.FileNotFound),
        missing.registry.loadError(testing.google_cloud_key),
    );
    try std.testing.expect(missing.registry.loadError(testing.openai_api_key) == null);
    try std.testing.expect(missing.registry.firstAuthenticated() == null);

    const file = try std.json.Stringify.valueAlloc(gpa, .{
        .type = "service_account",
        .project_id = "my-project",
        .private_key = testing.private_key_pem,
        .client_email = "robot@example.iam.gserviceaccount.com",
    }, .{});
    defer gpa.free(file);
    try tmp.dir.writeFile(io, .{ .sub_path = "key.json", .data = file });
    var ready: testing.Rig = undefined;
    try ready.init(gpa, io, &.{
        .home = home,
        .variables = &.{
            .{ "GOOGLE_APPLICATION_CREDENTIALS", key_path },
            .{ "GOOGLE_CLOUD_LOCATION", "eu" },
        },
        .replies = &.{.{ .body = "{\"access_token\":\"ya29.a\",\"expires_in\":3599}" }},
    });
    defer ready.deinit();
    try std.testing.expect(ready.registry.isAuthenticated(testing.google_cloud_key));
    try std.testing.expectEqual(testing.google_cloud_key, ready.registry.firstAuthenticated().?);
    var client: Client = undefined;
    try ready.registry.open(&client, testing.google_cloud_key);
    defer client.deinit();
    try expectRequestLine(
        &ready,
        &client,
        "POST https://aiplatform.eu.rep.googleapis.com/v1/projects/my-project/locations/eu/",
    );

    var bad_location: testing.Rig = undefined;
    try bad_location.init(gpa, io, &.{ .home = home, .variables = &.{
        .{ "ANTHROPIC_API_KEY", "sk-ant" },
        .{ "GOOGLE_APPLICATION_CREDENTIALS", key_path },
        .{ "GOOGLE_CLOUD_LOCATION", "europe-west4" },
    } });
    defer bad_location.deinit();
    try std.testing.expectEqual(
        @as(?LoadError, error.BadLocation),
        bad_location.registry.loadError(testing.google_cloud_key),
    );
    try std.testing.expectEqual(
        testing.anthropic_api_key,
        bad_location.registry.firstAuthenticated().?,
    );
}

test "an account has a callback listener exactly when it has a callback login" {
    for (&Account.table) |*account| {
        const callback_login = account.hasLogin() and account.credential.store != .grok;
        try std.testing.expectEqual(callback_login, callback(account) != null);
    }
    try std.testing.expectEqual(
        @as(u16, 53692),
        callback(&Account.table[testing.anthropic_plan]).?.port,
    );
    try std.testing.expectEqual(
        @as(u16, 53693),
        callback(&Account.table[testing.anthropic_api]).?.port,
    );
    try std.testing.expectEqual(
        @as(u16, 1455),
        callback(&Account.table[testing.openai_plan]).?.port,
    );
    try std.testing.expectEqual(
        @as(u16, 53694),
        callback(&Account.table[testing.openrouter_api]).?.port,
    );
    for ([_]usize{ testing.anthropic_plan, testing.anthropic_api, testing.openai_plan }) |index| {
        try std.testing.expectEqual(
            oauth.callback.Binding.state,
            callback(&Account.table[index]).?.binding,
        );
    }
    try std.testing.expectEqual(
        oauth.callback.Binding.path,
        callback(&Account.table[testing.openrouter_api]).?.binding,
    );
}

test "logout and invalidation refuse the accounts without a store credential" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);
    var rig: testing.Rig = undefined;
    try rig.init(gpa, io, &.{ .home = home, .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }} });
    defer rig.deinit();
    for ([_]usize{
        testing.anthropic_api_key,
        testing.openai_api_key,
        testing.xai_api_key,
        testing.openrouter_api_key,
        testing.deepseek_api_key,
        testing.google_cloud_key,
    }) |index| {
        try std.testing.expectError(error.AccountHasNoLogout, rig.registry.logout(index));
    }
    for ([_]usize{
        testing.anthropic_api,
        testing.anthropic_api_key,
        testing.openai_api_key,
        testing.xai_api_key,
        testing.openrouter_api,
        testing.openrouter_api_key,
        testing.deepseek_api_key,
        testing.google_cloud_key,
    }) |index| {
        try std.testing.expectError(
            error.AccountHasNoRefreshCredential,
            rig.registry.invalidate(index),
        );
    }
}

test "invalidation forgets a rejected credential when store removal fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);
    try testing.writeStore(io, &tmp,
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
    );

    var rig: testing.Rig = undefined;
    try rig.init(gpa, io, &.{ .home = home });
    defer rig.deinit();
    try std.testing.expect(rig.registry.isAuthenticated(testing.anthropic_plan));
    try rig.seed(testing.anthropic_plan, &.{"claude-opus-5"});
    try std.testing.expect(rig.registry.offersModel(testing.anthropic_plan));

    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = "not json" });
    try std.testing.expectError(
        error.BadCredentials,
        rig.registry.invalidate(testing.anthropic_plan),
    );
    try std.testing.expect(!rig.registry.isAuthenticated(testing.anthropic_plan));
    try std.testing.expect(rig.registry.credential(testing.anthropic_plan) == null);
    try std.testing.expect(!rig.registry.offersModel(testing.anthropic_plan));
}

test "an Anthropic stream keeps the shared window, and every other stream waits five minutes" {
    const shared: providers.Transport.Timeouts = .{};
    try std.testing.expectEqual(shared, timeouts_default.get(.anthropic));
    for ([_]Account.Vendor{ .openai, .xai, .openrouter, .deepseek, .google }) |vendor| {
        try std.testing.expectEqual(shared.connect_ms, timeouts_default.get(vendor).connect_ms);
        try std.testing.expectEqual(@as(u64, 300_000), timeouts_default.get(vendor).idle_ms);
    }
}

test "the model list of a Responses account is the models sibling of its base" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { id: []const u8, url: []const u8 }{
        .{ .id = "openai-api-key", .url = "https://api.openai.com/v1/models" },
        .{ .id = "xai-plan", .url = "https://api.x.ai/v1/models" },
        .{ .id = "xai-api-key", .url = "https://api.x.ai/v1/models" },
        .{ .id = "deepseek-api-key", .url = "https://api.deepseek.com/v1/models" },
    };
    for (cases) |case| {
        const url = try modelsUrl(gpa, &Account.table[Account.index(case.id).?]);
        defer gpa.free(url);
        try std.testing.expectEqualStrings(case.url, url);
    }
}

test "invalidation reloads a replacement without its model list and drops the account on a match" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);
    try testing.writeStore(io, &tmp,
        \\{ "xai-plan":
        \\    { "access": "old_access", "refresh": "old_refresh", "expires_ms": 4102444800000 } }
    );

    var rig: testing.Rig = undefined;
    try rig.init(gpa, io, &.{ .home = home });
    defer rig.deinit();
    try std.testing.expect(rig.registry.isAuthenticated(testing.xai_plan));
    try rig.seed(testing.xai_plan, &.{"grok-4.6"});
    try std.testing.expect(rig.registry.offersModel(testing.xai_plan));

    try tmp.dir.writeFile(io, .{
        .sub_path = ".drinky/auth.json",
        .data =
        \\{ "xai-plan":
        \\    { "access": "new_access", "refresh": "new_refresh", "expires_ms": 4102444800000 } }
        ,
    });
    try std.testing.expect(try rig.registry.invalidate(testing.xai_plan));
    try std.testing.expect(rig.registry.isAuthenticated(testing.xai_plan));
    try expectToken("new_access", rig.registry.credential(testing.xai_plan).?);
    try std.testing.expect(!rig.registry.offersModel(testing.xai_plan));

    try std.testing.expect(!try rig.registry.invalidate(testing.xai_plan));
    try std.testing.expect(!rig.registry.isAuthenticated(testing.xai_plan));
    var path_buffer: [160]u8 = undefined;
    const store_path = try testing.tmpPath(&path_buffer, &tmp, ".drinky/auth.json");
    var file = (try json_store.open(gpa, io, store_path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("xai-plan") == null);
}

test "a logout removes the store entry and the model list" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);
    try testing.writeStore(io, &tmp,
        \\{ "openrouter-api": { "api_key": "sk-or-v1-x" },
        \\  "anthropic-api": { "api_key": "sk-ant-api03-x" } }
    );

    var rig: testing.Rig = undefined;
    try rig.init(gpa, io, &.{ .home = home });
    defer rig.deinit();
    try std.testing.expect(rig.registry.isAuthenticated(testing.openrouter_api));
    try std.testing.expect(rig.registry.isAuthenticated(testing.anthropic_api));
    try expectToken("sk-or-v1-x", rig.registry.credential(testing.openrouter_api).?);

    try rig.registry.logout(testing.openrouter_api);
    try std.testing.expect(!rig.registry.isAuthenticated(testing.openrouter_api));
    try std.testing.expect(rig.registry.credential(testing.openrouter_api) == null);
    try std.testing.expect(rig.registry.isAuthenticated(testing.anthropic_api));
    var path_buffer: [160]u8 = undefined;
    const store_path = try testing.tmpPath(&path_buffer, &tmp, ".drinky/auth.json");
    var file = (try json_store.open(gpa, io, store_path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("openrouter-api") == null);
    try std.testing.expect(file.entry("anthropic-api") != null);
}

test "a failed cache write reports a failed save, not a failed fetch" {
    const gpa = std.testing.allocator;
    var clock: core.testing.ClockIo = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var rig: testing.Rig = undefined;
    try rig.init(gpa, io, &.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{
            .{ .body = "{\"data\":[{\"id\":\"gpt-5.6-sol\"}]}" },
            .{ .body = "{\"data\":[{\"id\":\"openai/gpt-5.6-sol\",\"context_length\":1050000}]}" },
        },
        .timeouts = .initFill(.{ .connect_ms = 0, .idle_ms = 0 }),
    });
    defer rig.deinit();
    try rig.tmp.?.dir.createDirPath(io, ".drinky");
    const lock_path = ".drinky/models.json.lock";
    var held = try rig.tmp.?.dir.createFile(io, lock_path, .{ .lock = .exclusive });
    defer held.close(io);
    try rig.registry.start();

    try rig.registry.send(&.{ .fetch = testing.openai_api_key });
    try rig.recorder.expect("fetch_ended:openai-api-key:1:save:StoreBusy");
    try std.testing.expect(rig.registry.offersModel(testing.openai_api_key));
}

test "an expired window ends both parts of a fetch without a request" {
    const gpa = std.testing.allocator;
    var clock: core.testing.StepClock = undefined;
    clock.init(gpa, std.time.ms_per_hour);
    defer clock.deinit();
    var rig: testing.Rig = undefined;
    try rig.init(gpa, clock.io(), &.{ .variables = &.{
        .{ "ANTHROPIC_API_KEY", "sk-ant" },
        .{ "OPENAI_API_KEY", "sk-openai" },
    } });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .fetch = testing.anthropic_api_key });
    try rig.recorder.expect("fetch_ended:anthropic-api-key:0:Timeout:metadata:Timeout");
    try rig.registry.send(&.{ .fetch = testing.openai_api_key });
    try rig.recorder.expect("fetch_ended:openai-api-key:0:Timeout:metadata:Timeout");
    try std.testing.expect(!rig.registry.offersModel(testing.anthropic_api_key));
    try std.testing.expect(!rig.registry.offersModel(testing.openai_api_key));
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "a canceled list ends the fetch before the metadata request" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: testing.Rig = undefined;
    try rig.init(std.testing.allocator, std.testing.io, &.{
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
        .replies = &.{.{ .stall = &stall }},
    });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .fetch = testing.anthropic_api_key });
    try stall.reached.wait(std.testing.io);
    try rig.registry.send(&.cancel);
    try rig.recorder.expect("fetch_ended:anthropic-api-key:0:Canceled");
    try std.testing.expect(stall.canceled);
    try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
}

test "a refused list still asks for the public metadata" {
    var rig: testing.Rig = undefined;
    try rig.init(std.testing.allocator, std.testing.io, &.{
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
        .replies = &.{
            .{ .fail = error.ConnectionRefused },
            .{ .status = .internal_server_error },
        },
    });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .fetch = testing.anthropic_api_key });
    try rig.recorder.expect(
        "fetch_ended:anthropic-api-key:0:ConnectionRefused:metadata:MetadataRequestFailed",
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        rig.transport.requests.items[1],
        "GET https://openrouter.ai/api/v1/models\n",
    ));
}

test "an OpenRouter fetch runs no list request and reports a failed body as the list" {
    var rig: testing.Rig = undefined;
    try rig.init(std.testing.allocator, std.testing.io, &.{
        .variables = &.{.{ "OPENROUTER_API_KEY", "sk-or" }},
        .replies = &.{
            .{ .status = .internal_server_error },
            .{ .body = "{\"data\":[{\"id\":\"openai/gpt-5.6-sol\"," ++
                "\"context_length\":1050000,\"supported_parameters\":[\"tools\"]}]}" },
        },
    });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .fetch = testing.openrouter_api_key });
    try rig.recorder.expect("fetch_ended:openrouter-api-key:0:MetadataRequestFailed");
    try rig.registry.send(&.{ .fetch = testing.openrouter_api_key });
    try rig.recorder.expect("fetch_ended:openrouter-api-key:1");
    try std.testing.expect(
        rig.registry.findModel(
            testing.openrouter_api_key,
            "openai/gpt-5.6-sol",
        ) != null,
    );
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
}

test "a command without its account or its sign-in is refused" {
    var rig: testing.Rig = undefined;
    try rig.init(std.testing.allocator, std.testing.io, &.{
        .variables = &.{.{ "XAI_API_KEY", "xai-key" }},
    });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .fetch = testing.anthropic_api_key });
    try rig.recorder.expect("refused:anthropic-api-key:fetch:signed_out");
    try rig.registry.send(&.{ .login = testing.xai_api_key });
    try rig.recorder.expect("refused:xai-api-key:login:no_login");
    try rig.registry.send(&.{ .paste = "code=a&state=b" });
    try rig.recorder.expect("paste_refused:not_waiting");
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "a fetch runs as a child task that a cancel ends, and a command meanwhile is refused" {
    var stall: providers.testing.FakeTransport.Stall = .{ .io = std.testing.io };
    var rig: testing.Rig = undefined;
    try rig.init(std.testing.allocator, std.testing.io, &.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        .replies = &.{.{ .stall = &stall }},
    });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .fetch = testing.openai_api_key });
    try stall.reached.wait(std.testing.io);
    try rig.registry.send(&.{ .login = testing.anthropic_plan });
    try rig.recorder.expect("refused:anthropic-plan:login:busy");
    try rig.registry.send(&.{ .fetch = testing.openai_api_key });
    try rig.recorder.expect("refused:openai-api-key:fetch:busy");
    try rig.registry.send(&.cancel);
    try rig.recorder.expect("fetch_ended:openai-api-key:0:Canceled");
    try std.testing.expect(stall.canceled);
    try std.testing.expect(!rig.registry.offersModel(testing.openai_api_key));
}

test "a worker task that cannot start ends its fetch or its sign-in with the failure" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    var rig: testing.Rig = undefined;
    try rig.init(gpa, threaded.io(), &.{
        .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
    });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .fetch = testing.openai_api_key });
    try rig.recorder.expect("fetch_ended:openai-api-key:0:ConcurrencyUnavailable");
    try rig.registry.send(&.{ .login = testing.anthropic_plan });
    try rig.recorder.expect("login_ended:anthropic-plan:failed:ConcurrencyUnavailable");
    try rig.registry.send(&.{ .fetch = testing.openai_api_key });
    try rig.recorder.expect("fetch_ended:openai-api-key:0:ConcurrencyUnavailable");
}

const token_body = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":3600}";

fn pastePlanRedirect(rig: *testing.Rig) !void {
    const shown = try rig.recorder.next();
    defer rig.gpa.free(shown);
    try std.testing.expect(std.mem.startsWith(u8, shown, "authorization:anthropic-plan:https://"));
    try rig.recorder.expect("browser_launch_failed:anthropic-plan");
    const state_at = std.mem.indexOf(u8, shown, "state=").? + "state=".len;
    const rest = shown[state_at..];
    const state = rest[0 .. std.mem.indexOfScalar(u8, rest, '&') orelse rest.len];
    var line_buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &line_buffer,
        "http://localhost:53692/callback?code=abc&state={s}",
        .{state},
    );
    try rig.registry.send(&.{ .paste = line });
}

test "a callback sign-in completes through a pasted redirect and saves the tokens" {
    var rig: testing.Rig = undefined;
    try rig.init(std.testing.allocator, std.testing.io, &.{
        .replies = &.{.{ .body = token_body }},
    });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .login = testing.anthropic_plan });
    try pastePlanRedirect(&rig);
    try rig.recorder.expect("paste_replayed");
    try rig.recorder.expect("login_ended:anthropic-plan:saved");
    try std.testing.expect(rig.registry.isAuthenticated(testing.anthropic_plan));
    try std.testing.expect(
        std.mem.indexOf(u8, rig.transport.requests.items[0], "\"code\":\"abc\"") != null,
    );
    try std.testing.expectEqual(@as(?u16, null), rig.loopback.listening());
}

test "a sign-in whose store save fails keeps its tokens in memory" {
    var rig: testing.Rig = undefined;
    try rig.init(std.testing.allocator, std.testing.io, &.{
        .replies = &.{.{ .body = token_body }},
    });
    defer rig.deinit();
    var blocked = try rig.tmp.?.dir.createDirPathOpen(std.testing.io, ".drinky/auth.json", .{});
    blocked.close(std.testing.io);
    try rig.registry.start();

    try rig.registry.send(&.{ .login = testing.anthropic_plan });
    try pastePlanRedirect(&rig);
    try rig.recorder.expect("paste_replayed");
    try rig.recorder.expect("login_ended:anthropic-plan:memory_only");
    try std.testing.expect(rig.registry.isAuthenticated(testing.anthropic_plan));
}

test "a paste that the listener refuses keeps the sign-in waiting until a cancel" {
    var rig: testing.Rig = undefined;
    try rig.init(std.testing.allocator, std.testing.io, &.{});
    defer rig.deinit();
    rig.loopback.refuses = true;
    try rig.registry.start();

    try rig.registry.send(&.{ .login = testing.anthropic_plan });
    try pastePlanRedirect(&rig);
    try rig.recorder.expect("paste_refused:replay_failed:ConnectionRefused");
    try rig.registry.send(&.cancel);
    try rig.recorder.expect("login_ended:anthropic-plan:failed:Canceled");
    try std.testing.expect(!rig.registry.isAuthenticated(testing.anthropic_plan));
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "a device sign-in polls until the grant and saves the tokens" {
    const gpa = std.testing.allocator;
    var clock: core.testing.ClockIo = undefined;
    clock.init(gpa);
    defer clock.deinit();
    var rig: testing.Rig = undefined;
    try rig.init(gpa, clock.io(), &.{
        .replies = &.{
            .{ .body = "{\"device_code\":\"dev-1\",\"user_code\":\"ABCD-EFGH\"," ++
                "\"verification_uri\":\"https://auth.x.ai/activate\"," ++
                "\"verification_uri_complete\":" ++
                "\"https://auth.x.ai/activate?user_code=ABCD-EFGH\"," ++
                "\"expires_in\":600,\"interval\":5}" },
            .{ .status = .bad_request, .body = "{\"error\":\"authorization_pending\"}" },
            .{ .body = token_body },
        },
        .timeouts = .initFill(.{ .connect_ms = 0, .idle_ms = 0 }),
    });
    defer rig.deinit();
    try rig.registry.start();

    try rig.registry.send(&.{ .login = testing.xai_plan });
    try rig.recorder.expect(
        "authorization:xai-plan:https://auth.x.ai/activate?user_code=ABCD-EFGH",
    );
    try rig.recorder.expect("browser_launch_failed:xai-plan");
    try rig.recorder.expect("login_ended:xai-plan:saved");
    try std.testing.expect(rig.registry.isAuthenticated(testing.xai_plan));
    try std.testing.expectEqualSlices(u64, &.{ 5_000, 5_000 }, clock.slept());
    try std.testing.expectEqual(@as(usize, 3), rig.transport.requests.items.len);
}

test "a copy of each event owns its bytes, and a failed copy leaks nothing" {
    const events = [_]Event{
        .{ .authorization = .{
            .account = 0,
            .url = "https://example.invalid/authorize",
            .code = "ABCD-1234",
            .callback_path = "/callback",
        } },
        .{ .authorization = .{ .account = 0, .url = "u", .code = null, .callback_path = null } },
        .{ .login_ended = .{ .account = 0, .outcome = error.Canceled } },
        .{ .refused = .{ .account = 0, .command = .login, .reason = .busy } },
    };
    try core.testing.checkCopyAllocationFailures(Event, &events);
}

test "a copy of a login end keeps its outcome, and a failed copy drops only the path" {
    const path = "/home/.drinky/auth.json";
    const saved: Event = .{ .login_ended = .{ .account = 3, .outcome = .{ .saved = path } } };
    const memory_only: Event = .{ .login_ended = .{ .account = 3, .outcome = .{ .memory_only = .{
        .path = path,
        .save_error = error.AccessDenied,
    } } } };
    const cases = [_]struct { fail_index: usize, kept: []const u8 }{
        .{ .fail_index = std.math.maxInt(usize), .kept = path },
        .{ .fail_index = 0, .kept = "" },
    };
    for (cases) |case| {
        var failing: std.testing.FailingAllocator = .init(
            std.testing.allocator,
            .{ .fail_index = case.fail_index },
        );
        const gpa = failing.allocator();
        const saved_copy = try saved.dupe(gpa);
        defer saved_copy.deinit(gpa);
        const memory_only_copy = try memory_only.dupe(gpa);
        defer memory_only_copy.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 3), saved_copy.login_ended.account);
        try std.testing.expectEqualStrings(case.kept, (try saved_copy.login_ended.outcome).saved);
        const failure = (try memory_only_copy.login_ended.outcome).memory_only;
        try std.testing.expectEqualStrings(case.kept, failure.path);
        try std.testing.expectEqual(error.AccessDenied, failure.save_error);
    }
}

fn expectRequestLine(rig: *testing.Rig, client: *Client, line: []const u8) !void {
    const reply = try providers.testing.trace(
        rig.gpa,
        client.provider(),
        &providers.testing.empty_request,
    );
    rig.gpa.free(reply);
    const requests = rig.transport.requests.items;
    try std.testing.expect(std.mem.startsWith(u8, requests[requests.len - 1], line));
}

fn expectToken(expected: []const u8, held: providers.Credential) !void {
    const token = (try held.token(std.testing.allocator)).?;
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings(expected, token);
}
