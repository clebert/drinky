const std = @import("std");
const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");
const tools = @import("tools");
const Choice = @import("Choice.zig");
const Controller = @import("Controller.zig");
const Interaction = @import("Interaction.zig");
const Record = @import("Record.zig");
const Snapshot = @import("Snapshot.zig");
const Surface = @import("Surface.zig");

pub fn expectContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, text, needle) != null) return;
    std.debug.print("the text holds no \"{s}\":\n{s}\n", .{ needle, text });
    return error.TestExpectedNeedle;
}

pub fn expectUsers(records: []const Record, expected: []const []const u8) !void {
    var count: usize = 0;
    for (records) |*record| {
        const text = switch (record.content) {
            .user => |list| list.items,
            else => continue,
        };
        try std.testing.expect(count < expected.len);
        try std.testing.expectEqualStrings(expected[count], text);
        count += 1;
    }
    try std.testing.expectEqual(expected.len, count);
}

pub const Tree = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    paths: std.ArrayList([]u8),

    pub fn init() !Tree {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .tmp = tmp, .root = root, .paths = .empty };
    }

    pub fn deinit(self: *Tree) void {
        for (self.paths.items) |path_item| std.testing.allocator.free(path_item);
        self.paths.deinit(std.testing.allocator);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    pub fn path(self: *Tree, sub_path: []const u8) ![]const u8 {
        const gpa = std.testing.allocator;
        const joined = try std.Io.Dir.path.join(gpa, &.{ self.root, sub_path });
        errdefer gpa.free(joined);
        try self.paths.append(gpa, joined);
        return joined;
    }

    pub fn directory(self: *Tree, sub_path: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, sub_path);
    }

    pub fn write(self: *Tree, sub_path: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(sub_path)) |parent| try self.directory(parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    pub fn skill(
        self: *Tree,
        parent: []const u8,
        options: *const struct { name: []const u8, description: []const u8 },
    ) !void {
        var path_buffer: [256]u8 = undefined;
        const sub_path = try std.mem.print(&path_buffer, "{s}/SKILL.md", .{parent});
        var source_buffer: [512]u8 = undefined;
        const source = try std.mem.print(
            &source_buffer,
            "---\nname: {s}\ndescription: {s}\n---\nFollow this skill.\n",
            .{ options.name, options.description },
        );
        try self.write(sub_path, source);
    }

    pub fn link(
        self: *Tree,
        target: []const u8,
        sub_path: []const u8,
        flags: std.Io.Dir.SymLinkFlags,
    ) !void {
        self.tmp.dir.symLink(std.testing.io, target, sub_path, flags) catch |err| switch (err) {
            error.AccessDenied,
            error.PermissionDenied,
            error.ReadOnlyFileSystem,
            => return error.SkipZigTest,
            else => return err,
        };
    }
};

pub const Rig = struct {
    tree: Tree,
    environment: std.process.Environ.Map,
    transport: providers.testing.FakeTransport,
    browser: accounts.testing.FakeBrowser,
    loopback: accounts.testing.FakeLoopback,
    allocator: std.mem.Allocator,
    controller: *Controller.Handle,
    events: std.ArrayList(Controller.Event),
    taken: usize,
    mail: std.Io.Queue(Controller.Mail),
    mail_buffer: [256]Controller.Mail = undefined,

    const sink_vtable: Controller.Sink.VTable = .{ .emit = emit };
    const mailbox_vtable: Controller.Mailbox.VTable = .{ .post = post };

    pub const Options = struct {
        allocator: std.mem.Allocator = std.testing.allocator,
        startup: Controller.Startup = .terminal,
        replies: []const providers.testing.FakeTransport.Reply = &.{},
        transport: ?providers.Transport = null,
        config: []const u8 = "{\"request\":{\"delay_ms_initial\":0,\"delay_ms_max\":0}}",
        authenticated: bool = true,
        selected_account: usize = accounts.testing.openai_api_key,
        store: ?[]const u8 = null,
        variables: []const [2][]const u8 = &.{},
        models: []const struct { account: usize, names: []const []const u8 } = &.{.{
            .account = accounts.testing.openai_api_key,
            .names = &.{"gpt-5.6-sol"},
        }},
        files: []const [2][]const u8 = &.{},
    };

    pub fn init(self: *Rig, options: *const Options) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        self.allocator = options.allocator;
        self.events = .empty;
        self.taken = 0;
        self.tree = try .init();
        errdefer self.tree.deinit();
        try self.tree.write(".git/HEAD", "ref: refs/heads/main\n");
        try self.tree.write(".drinky/config.json", options.config);
        if (options.store) |store| try self.tree.write(".drinky/auth.json", store);
        for (options.files) |file| try self.tree.write(file[0], file[1]);
        self.environment = .init(gpa);
        errdefer self.environment.deinit();
        if (options.authenticated) try self.environment.put("OPENAI_API_KEY", "key");
        for (options.variables) |variable| try self.environment.put(variable[0], variable[1]);
        var catalog: accounts.testing.Rig = undefined;
        try catalog.init(gpa, io, &.{ .home = self.tree.root });
        defer catalog.deinit();
        var remembered: std.json.ObjectMap = .empty;
        defer remembered.deinit(gpa);
        for (options.models) |models| {
            try catalog.seed(models.account, models.names);
            if (models.names.len == 0) continue;
            try remembered.put(gpa, accounts.Account.table[models.account].id, .{
                .string = models.names[0],
            });
        }
        const selected_id = accounts.Account.table[options.selected_account].id;
        const data = try gpa.print(
            "{{{f}:{{\"account\":\"{s}\",\"models\":{f},\"effort\":\"high\"}}}}",
            .{
                std.json.fmt(self.tree.root, .{}),
                selected_id,
                std.json.fmt(std.json.Value{ .object = remembered }, .{}),
            },
        );
        defer gpa.free(data);
        try self.tree.write(".drinky/state.json", data);
        self.transport = .{ .gpa = gpa, .replies = options.replies };
        errdefer self.transport.deinit();
        self.browser = .{};
        self.loopback = .{ .io = io };
        self.mail = .init(&self.mail_buffer);
        errdefer self.closeMail();
        self.controller = try Controller.Handle.create(options.allocator, io, &.{
            .directories = .{ .working_directory = self.tree.root, .home = self.tree.root },
            .environment = &self.environment,
            .startup = options.startup,
            .transport = options.transport orelse self.transport.transport(),
            .browser = self.browser.browser(),
            .loopback = self.loopback.loopback(),
            .sink = .{ .ptr = self, .vtable = &sink_vtable },
            .mailbox = .{ .ptr = self, .vtable = &mailbox_vtable },
        });
    }
    pub fn deinit(self: *Rig) void {
        self.mail.close(std.testing.io);
        self.controller.destroy();
        self.closeMail();
        for (self.events.items[self.taken..]) |*event| event.deinit(std.testing.allocator);
        self.events.deinit(std.testing.allocator);
        self.transport.deinit();
        self.environment.deinit();
        self.tree.deinit();
    }
    fn closeMail(self: *Rig) void {
        self.mail.close(std.testing.io);
        var buffer: [16]Controller.Mail = undefined;
        while (true) {
            const count = self.mail.get(std.testing.io, &buffer, 0) catch break;
            if (count == 0) break;
            for (buffer[0..count]) |*mail| mail.deinit(self.allocator);
        }
    }
    fn emit(ptr: *anyopaque, event: *const Controller.Event) void {
        const self: *Rig = @ptrCast(@alignCast(ptr));
        const copy = event.dupe(std.testing.allocator) catch unreachable;
        self.events.append(std.testing.allocator, copy) catch unreachable;
    }
    fn post(ptr: *anyopaque, mail: Controller.Mail) void {
        const self: *Rig = @ptrCast(@alignCast(ptr));
        self.mail.putOneUncancelable(std.testing.io, mail) catch mail.deinit(self.allocator);
    }
    pub fn send(self: *Rig, command: *const Controller.Command) Controller.Response {
        return self.controller.submit(command);
    }
    pub fn select(self: *Rig, name: []const u8) !void {
        const current = try self.snapshot();
        defer current.deinit(std.testing.allocator);
        const picker = current.interaction.picker orelse return error.TestExpectedPicker;
        for (picker.options, 0..) |*option, cursor| {
            if (!std.mem.eql(u8, option.name, name)) continue;
            try std.testing.expect(self.send(&.{ .select = .{ .cursor = cursor } }).accepted);
            return;
        }
        return error.TestExpectedOption;
    }
    pub fn interaction(self: *Rig, mode: Interaction.Mode) !Interaction {
        for (0..4096) |_| {
            const event = try self.next();
            if (event == .interaction and event.interaction.mode == mode) return event.interaction;
            event.deinit(std.testing.allocator);
        }
        return error.TestExpectedInteraction;
    }
    pub fn page(self: *Rig) !Snapshot {
        for (0..4096) |_| {
            const event = try self.next();
            defer event.deinit(std.testing.allocator);
            if (event == .interaction and event.interaction.mode == .page and
                !event.interaction.working) return self.snapshot();
        }
        return error.TestExpectedPage;
    }
    pub fn next(self: *Rig) !Controller.Event {
        for (0..4096) |_| {
            if (self.taken < self.events.items.len) {
                defer self.taken += 1;
                return self.events.items[self.taken];
            }
            try self.pump();
        }
        return error.TestExpectedEvent;
    }
    fn pump(self: *Rig) !void {
        const mail = try core.timeout.run(std.testing.io, 5_000, take, .{self}, release);
        self.controller.receive(mail);
    }
    fn receivePosted(self: *Rig) void {
        var buffer: [1]Controller.Mail = undefined;
        for (0..self.mail_buffer.len) |_| {
            const count = self.mail.get(std.testing.io, &buffer, 0) catch return;
            if (count == 0) return;
            self.controller.receive(buffer[0]);
        }
    }
    fn take(self: *Rig) (std.Io.Cancelable || std.Io.QueueClosedError)!Controller.Mail {
        return self.mail.getOne(std.testing.io);
    }
    fn release(mail: *const Controller.Mail, context: *const struct { *Rig }) void {
        mail.deinit(context[0].allocator);
    }
    pub fn skip(self: *Rig) void {
        for (self.events.items[self.taken..]) |*event| event.deinit(std.testing.allocator);
        self.events.clearRetainingCapacity();
        self.taken = 0;
    }
    pub fn turnEnd(self: *Rig) !Controller.Event.TurnEnd {
        for (0..4096) |_| {
            const event = try self.next();
            if (event == .turn_ended) return event.turn_ended;
            event.deinit(std.testing.allocator);
        }
        return error.TestExpectedTurnEnd;
    }
    pub fn expectTurn(self: *Rig, outcome: std.meta.Tag(core.Session.Outcome)) !void {
        const ended = try self.turnEnd();
        defer ended.outcome.deinit(std.testing.allocator);
        defer std.testing.allocator.free(ended.answer);
        try std.testing.expectEqual(outcome, std.meta.activeTag(ended.outcome));
    }
    pub fn callbackUrl(self: *Rig) ![]u8 {
        for (0..4096) |_| {
            const event = try self.next();
            defer event.deinit(std.testing.allocator);
            if (event != .append_record or event.append_record.content != .event) continue;
            const text = event.append_record.content.event.text.items;
            const url_start = std.mem.find(u8, text, "https://") orelse continue;
            const url_end = std.mem.findScalarPos(u8, text, url_start, '\n') orelse text.len;
            const url = text[url_start..url_end];
            const state_start = (std.mem.find(u8, url, "&state=") orelse
                return error.TestExpectedState) + "&state=".len;
            const state_end = std.mem.findScalarPos(u8, url, state_start, '&') orelse url.len;
            return std.testing.allocator.print(
                "http://localhost:53692/callback?code=abc&state={s}",
                .{url[state_start..state_end]},
            );
        }
        return error.TestExpectedAuthorization;
    }

    pub fn expectMutatedTurn(self: *Rig) !void {
        _ = self.send(&.{ .submit = .{ .line = "/rewind" } });
        const response = self.send(&.{ .select = .{ .cursor = 0 } });
        try std.testing.expectEqual(.rewind, response.confirmation.?);
    }

    pub fn snapshot(self: *Rig) !Snapshot {
        self.receivePosted();
        self.skip();
        try std.testing.expect(self.send(&.snapshot).accepted);
        while (self.taken < self.events.items.len) {
            const event = self.events.items[self.taken];
            self.taken += 1;
            if (event == .snapshot) return event.snapshot;
            event.deinit(std.testing.allocator);
        }
        return error.TestExpectedSnapshot;
    }
};

pub const StreamTransport = struct {
    prefix: []const u8,
    tail: []const u8,
    reader: std.Io.Reader = undefined,
    storage: [4096]u8 = undefined,
    tail_index: usize = 0,
    reached: std.Io.Event = .unset,
    released: std.Io.Event = .unset,

    const vtable: providers.Transport.VTable = .{ .open = open, .close = close };
    const reader_vtable: std.Io.Reader.VTable = .{ .stream = stream };
    pub fn transport(self: *StreamTransport) providers.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn open(
        ptr: *anyopaque,
        _: *const providers.Transport.Request,
    ) providers.Transport.Error!providers.Transport.Reply {
        const self: *StreamTransport = @ptrCast(@alignCast(ptr));
        self.tail_index = 0;
        @memcpy(self.storage[0..self.prefix.len], self.prefix);
        self.reader = .{
            .vtable = &reader_vtable,
            .buffer = &self.storage,
            .seek = 0,
            .end = self.prefix.len,
        };
        return .{ .status = .ok, .headers = &.{}, .body = &self.reader };
    }
    fn close(_: *anyopaque) void {}
    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *StreamTransport = @fieldParentPtr("reader", reader);
        self.reached.set(std.testing.io);
        self.released.waitUncancelable(std.testing.io);
        if (self.tail_index == self.tail.len) return error.EndOfStream;
        const count = try writer.write(limit.sliceConst(self.tail[self.tail_index..]));
        self.tail_index += count;
        return count;
    }
};

pub const Reduction = struct {
    surface: Surface,
    events: std.ArrayList(Controller.Event) = .empty,
    revision: u64 = 0,

    const vtable: Controller.Sink.VTable = .{ .emit = publish };
    const changes_vtable: Controller.Sink.VTable = .{ .emit = emit };

    pub fn init(self: *Reduction, gpa: std.mem.Allocator, choice: Choice) void {
        self.* = .{ .surface = .init(
            gpa,
            std.testing.io,
            .{ .ptr = self, .vtable = &vtable },
            choice,
            (tools.Context.Bash{}).timeout_ms,
        ) };
    }

    pub fn deinit(self: *Reduction) void {
        self.clear();
        self.events.deinit(std.testing.allocator);
        self.surface.deinit();
    }

    pub fn clear(self: *Reduction) void {
        for (self.events.items) |*event| event.deinit(std.testing.allocator);
        self.events.clearRetainingCapacity();
    }

    pub fn start(self: *Reduction, text: []const u8) !void {
        try self.surface.appendUser(text);
        self.surface.beginTurn();
        self.flush();
    }

    pub fn apply(
        self: *Reduction,
        event: *const core.Session.Event,
        time: Surface.Time,
    ) error{OutOfMemory}!?core.Session.Outcome {
        const outcome = try self.surface.apply(event, time);
        self.flush();
        return outcome;
    }

    pub fn flush(self: *Reduction) void {
        const changed = self.revision != self.surface.revision;
        self.revision = self.surface.revision;
        const value: Interaction = .{
            .mode = std.meta.activeTag(self.surface.state),
            .working = self.surface.state == .turn,
            .notice = self.surface.notice,
            .notice_id = self.surface.notice_id,
            .choice = self.surface.choice,
        };
        const sink: Controller.Sink = .{ .ptr = self, .vtable = &changes_vtable };
        self.surface.flush(sink, if (changed) &value else null);
    }

    fn publish(ptr: *anyopaque, event: *const Controller.Event) void {
        const self: *Reduction = @ptrCast(@alignCast(ptr));
        self.flush();
        emit(ptr, event);
    }

    fn emit(ptr: *anyopaque, event: *const Controller.Event) void {
        const self: *Reduction = @ptrCast(@alignCast(ptr));
        const copy = event.dupe(std.testing.allocator) catch unreachable;
        self.events.append(std.testing.allocator, copy) catch unreachable;
    }
};
