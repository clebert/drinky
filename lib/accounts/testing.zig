const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Account = @import("Account.zig");
const Catalog = @import("Catalog.zig");
const Metadata = @import("Metadata.zig");
const Model = @import("Model.zig");
const oauth = @import("oauth/root.zig");
const Registry = @import("Registry.zig");

const tmp_root = ".zig-cache/tmp/";

pub const anthropic_plan = Account.index("anthropic-plan").?;
pub const anthropic_api = Account.index("anthropic-api").?;
pub const anthropic_api_key = Account.index("anthropic-api-key").?;
pub const openai_plan = Account.index("openai-plan").?;
pub const openai_api_key = Account.index("openai-api-key").?;
pub const xai_plan = Account.index("xai-plan").?;
pub const xai_api_key = Account.index("xai-api-key").?;
pub const openrouter_api = Account.index("openrouter-api").?;
pub const openrouter_api_key = Account.index("openrouter-api-key").?;
pub const deepseek_api_key = Account.index("deepseek-api-key").?;
pub const google_cloud_key = Account.index("google-cloud-key").?;
pub const ds4 = Account.index("ds4").?;

const Recorder = core.testing.Recorder(Registry.Event, render);

pub const FakeBrowser = struct {
    opens: bool = false,
    launches: usize = 0,
    reaps: usize = 0,

    const vtable: oauth.login.Browser.VTable = .{ .launch = launch, .reap = reap };

    pub fn browser(self: *FakeBrowser) oauth.login.Browser {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn launch(ptr: *anyopaque, _: []const u8) error{Canceled}!bool {
        const self: *FakeBrowser = @ptrCast(@alignCast(ptr));
        self.launches += 1;
        return self.opens;
    }

    fn reap(ptr: *anyopaque) void {
        const self: *FakeBrowser = @ptrCast(@alignCast(ptr));
        self.reaps += 1;
    }
};

pub const FakeLoopback = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    port: ?u16 = null,
    refuses: bool = false,
    line_buffer: [oauth.callback.paste_bytes_max]u8 = undefined,
    line_length: usize = 0,
    arrived: std.Io.Event = .unset,

    const replays_max = 16;

    const vtable: oauth.callback.Loopback.VTable = .{
        .listen = listen,
        .receive = receive,
        .close = close,
        .replay = replay,
    };

    pub fn loopback(self: *FakeLoopback) oauth.callback.Loopback {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn listening(self: *FakeLoopback) ?u16 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.port;
    }

    fn listen(ptr: *anyopaque, port: u16) std.Io.net.IpAddress.ListenError!void {
        const self: *FakeLoopback = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.port = port;
        self.arrived.reset();
    }

    fn receive(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        expected: *const oauth.callback.Expected,
    ) oauth.callback.Loopback.ReceiveError!oauth.callback.Redirect {
        const self: *FakeLoopback = @ptrCast(@alignCast(ptr));
        for (0..replays_max) |_| {
            try self.arrived.wait(self.io);
            var request_buffer: [oauth.callback.paste_bytes_max + 16]u8 = undefined;
            const request_line = request: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.arrived.reset();
                const line = self.line_buffer[0..self.line_length];
                break :request std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.1", .{line}) catch
                    unreachable;
            };
            if (try oauth.callback.redirectOf(gpa, request_line, expected)) |redirect|
                return redirect;
        }
        return error.CallbackTimeout;
    }

    fn close(ptr: *anyopaque) void {
        const self: *FakeLoopback = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.port = null;
    }

    fn replay(
        ptr: *anyopaque,
        port: u16,
        line: []const u8,
    ) oauth.callback.Loopback.ReplayError!void {
        const self: *FakeLoopback = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.refuses or self.port != port) return error.ConnectionRefused;
        @memcpy(self.line_buffer[0..line.len], line);
        self.line_length = line.len;
        self.arrived.set(self.io);
    }
};

pub const Rig = struct {
    gpa: std.mem.Allocator,
    tmp: ?std.testing.TmpDir,
    home_buffer: [128]u8,
    environment: std.process.Environ.Map,
    transport: providers.testing.FakeTransport,
    browser: FakeBrowser,
    loopback: FakeLoopback,
    recorder: Recorder,
    registry: Registry,

    const Options = struct {
        home: ?[]const u8 = null,
        store: ?[]const u8 = null,
        variables: []const [2][]const u8 = &.{},
        replies: []const providers.testing.FakeTransport.Reply = &.{},
        timeouts: Registry.Timeouts = Registry.timeouts_default,
    };

    pub fn init(self: *Rig, gpa: std.mem.Allocator, io: std.Io, options: *const Options) !void {
        self.gpa = gpa;
        self.tmp = null;
        errdefer if (self.tmp) |*tmp| tmp.cleanup();
        std.debug.assert(options.home == null or options.store == null);
        const home = options.home orelse home: {
            self.tmp = std.testing.tmpDir(.{});
            if (options.store) |store| try writeStore(io, &self.tmp.?, store);
            break :home try tmpHome(&self.home_buffer, &self.tmp.?);
        };
        self.environment = .init(gpa);
        errdefer self.environment.deinit();
        for (options.variables) |variable| try self.environment.put(variable[0], variable[1]);
        self.transport = .{ .gpa = gpa, .replies = options.replies };
        errdefer self.transport.deinit();
        self.browser = .{};
        self.loopback = .{ .io = io };
        self.recorder.init(gpa, io);
        errdefer self.recorder.deinit();
        try self.registry.init(gpa, io, &.{
            .directories = .{ .working_directory = ".", .home = home },
            .environment = &self.environment,
            .sink = self.recorder.sink(),
            .timeouts = options.timeouts,
            .transport = self.transport.transport(),
            .browser = self.browser.browser(),
            .loopback = self.loopback.loopback(),
        });
    }

    pub fn deinit(self: *Rig) void {
        self.registry.deinit();
        self.transport.deinit();
        self.recorder.deinit();
        self.environment.deinit();
        if (self.tmp) |*tmp| tmp.cleanup();
    }

    pub fn seed(self: *Rig, account: usize, names: []const []const u8) !void {
        var models: [8]Model = undefined;
        std.debug.assert(names.len <= models.len);
        for (names, 0..) |name, index| {
            models[index] = try Model.init(name);
            models[index].context_window = 200_000;
            models[index].thinking = .supported;
            models[index].addEffort(.low);
            models[index].addEffort(.high);
        }
        try self.registry.catalog.setAccount(account, &.{ .models = models[0..names.len] });
    }
};

fn render(writer: *std.Io.Writer, event: *const Registry.Event) std.Io.Writer.Error!void {
    switch (event.*) {
        .refused => |refusal| try writer.print("refused:{s}:{t}:{t}", .{
            Account.table[refusal.account].id,
            refusal.command,
            refusal.reason,
        }),
        .authorization => |authorization| try writer.print("authorization:{s}:{s}", .{
            Account.table[authorization.account].id,
            authorization.url,
        }),
        .browser_launch_failed => |account| try writer.print("browser_launch_failed:{s}", .{
            Account.table[account].id,
        }),
        .paste_replayed => try writer.writeAll("paste_replayed"),
        .paste_refused => |refusal| switch (refusal) {
            .not_waiting => try writer.writeAll("paste_refused:not_waiting"),
            .not_a_redirect => |account| try writer.print(
                "paste_refused:not_a_redirect:{s}",
                .{Account.table[account].id},
            ),
            .replay_failed => |err| try writer.print("paste_refused:replay_failed:{t}", .{err}),
        },
        .login_ended => |ended| {
            const id = Account.table[ended.account].id;
            if (ended.outcome) |login| switch (login) {
                .saved => try writer.print("login_ended:{s}:saved", .{id}),
                .memory_only => try writer.print("login_ended:{s}:memory_only", .{id}),
            } else |err| try writer.print("login_ended:{s}:failed:{t}", .{ id, err });
        },
        .fetch_ended => |ended| {
            const id = Account.table[ended.account].id;
            try writer.print("fetch_ended:{s}:{d}", .{ id, ended.refresh.count });
            if (ended.refresh.models_error) |err| try writer.print(":{t}", .{err});
            if (ended.refresh.models_save_error) |err| try writer.print(":save:{t}", .{err});
            if (ended.refresh.metadata_error) |err| try writer.print(":metadata:{t}", .{err});
            if (ended.refresh.metadata_save_error) |err| try writer.print(
                ":metadata_save:{t}",
                .{err},
            );
        },
    }
}

pub const private_key_pem =
    "-----BEGIN PRIVATE KEY-----\n" ++
    "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCJKO7Ta0mj+Lutt13/EQ/MiETo\n" ++
    "Ct5d3dUY5VCO5KgYSeP3xcpIGiM/mYlQuzsk4ki8FapTEgWwd2dO50pZFUAjIwg0Oq6CPS+61b6t\n" ++
    "Gwo03JJwhp2qNKOZaabSAmjHXxKuwrG+yfJMbCdZyxzGvZQ1dxSXBDkI7eV+klJYu4AZUs2ryeYY\n" ++
    "E7kV2ZqkIrDH5adAJe1L41+QRrYE05wY+pjZ9KyVN3Uah7WSkEMBcA98i7ZOqSJnaP3pUWitgUYM\n" ++
    "t2K/l3+0oif7jF8frgOUQBqS/CnLgt1ryKMGB1vuvvszsdXt9noOM3hS7/gs6LBPuj6T+ooXrsjk\n" ++
    "58DDIL5j+vO5AgMBAAECggEAAK6vKHwFnY7tWm8ET6fACGnATldj1ZD21aUUvmSUEwHcGYWWrOmS\n" ++
    "CxJqbi1uR6/SAjsz3JkFJaR5w2Ovw/YbenPwSfflmhuFPHoCKmDimefOg92MP4ERSXWOzpzpNJ5h\n" ++
    "bLSRLI8wjnGGd8IvTOxQxlF8N7JIo9sbdmKdOFiKHxDKPJSMqhgFFXZjrMh7YH6UAdcKbS47VXZv\n" ++
    "KSG4Io9msKveeBLU5NA9i9wyYeco4RwcoBzPzynVlttRrc0O5xIF3yNYErOhjL/SNa8UmnsTM97n\n" ++
    "hq12Doi7vjO0jGdz0Qos4+4YhEbFUujFjZ3sJbFOCq0K/GE/VrkJGbwB6fhwkQKBgQC89QQiTSOQ\n" ++
    "PLf1BqB9jZLX0CcG++9UI8O6oumaLHa7PHdGqaLVeON4UJA5NV7s4IAKwWmGWKFP5pvW1cdbUtYL\n" ++
    "u8jKDjGvn/oA0MKoJQBKSUIUR6VpN0XlRnGUA6LPus5+ObRI+59guEIyUaoVXjT91dWhNWlSf7xi\n" ++
    "SlH8uS8fsQKBgQC50yyPwq4Qt8hSzrAa+Kpr6lCLhCQw1CxijHDIa1uobZSU2MtyqhMwphUtrF13\n" ++
    "2er3TwHWo2SENqsSnYkCvI5SA4o7x/noTnS6PD1pUscDqVYOH1cBPvsdES+TrwsdgkBG+BbJfzr+\n" ++
    "gDPF4OQJh7kWOjvQgYL1txcHGv4T5iBeiQKBgCMKKIcX2OVxbQeCABboPvfIQMR5yYrHyw78EOen\n" ++
    "ISldcBzpbim57iyse+Iv9HdmtjfIYAIqw1cmw3VWVU6pEMpCO1zEvw/7UYf/Lmmx2tjrttY95v2Y\n" ++
    "41w98OfquLFeydX8a2MxTf/Ii3X7UNf/jUIY+jGXzv0edNehQozj5koxAoGAbL298vaaw9+4U3Tu\n" ++
    "KypfGD2LGsmeIBDZVGYYzb+9aGePrjbbf2M1TZ+y/wJBxBP64vQSAFenR5NyMreLaNWMd0PpDait\n" ++
    "fpsCxcTgrxSor2TVnfgLAwinDFB1RfgGCiOhl6YwN4PDsxC0u1QqPcV1syMqw442Y7HbwOWzz1M4\n" ++
    "l/kCgYEAs+13PymPYIcmanpdieGhZRT3UvQbYFLd8PF4I84Cq8phyzGqRYZjVtOj7e6bY1zXr28i\n" ++
    "9Btq5CJgQ4X+eOVwI7zyz7LQjMEfz/vZRhPbpYM6ZOZQRkp+K6UAd9Y7z9nGwizbqkbDU9wiD+H0\n" ++
    "qz/S1W3Lemsig3n6+HIURz26LqU=\n" ++
    "-----END PRIVATE KEY-----\n";

pub fn fakeJwt(gpa: std.mem.Allocator, claims: []const u8) ![]u8 {
    var encoded: [1024]u8 = undefined;
    const middle = std.base64.url_safe_no_pad.Encoder.encode(&encoded, claims);
    return std.fmt.allocPrint(gpa, "e30.{s}.sig", .{middle});
}

pub fn tmpHome(buffer: []u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    return std.fmt.bufPrint(buffer, tmp_root ++ "{s}", .{tmp.sub_path});
}

pub fn tmpPath(buffer: []u8, tmp: *const std.testing.TmpDir, sub_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, tmp_root ++ "{s}/{s}", .{ tmp.sub_path, sub_path });
}

pub fn writeStore(io: std.Io, tmp: *const std.testing.TmpDir, data: []const u8) !void {
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/auth.json", .data = data });
}

pub fn seedMetadata(catalog: *Catalog, names: []const []const u8) !void {
    const gpa = catalog.gpa;
    const entries = try gpa.alloc(Metadata.Entry, names.len);
    {
        errdefer gpa.free(entries);
        for (entries, names) |*entry, name| {
            var model = try Model.init(name);
            model.context_window = 1;
            model.tools = .supported;
            entry.* = .{ .vendor = .openrouter, .model = model };
        }
    }
    try catalog.setMetadata(.{ .gpa = gpa, .entries = entries });
}
