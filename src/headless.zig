const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");

const command_line = @import("command_line.zig");
const escape = @import("escape.zig");
const Harness = @import("Harness.zig");
const project = @import("project.zig");
const Screen = @import("Screen.zig");
const testing = @import("testing.zig");
const tool_environment = @import("tool_environment.zig");

const nested_refusal = "Drinky cannot start drinky run inside another drinky run process.";
const prompt_missing = "Drinky received no prompt on stdin.";
const prompt_not_utf8 = "Drinky cannot use the prompt because it is not valid UTF-8.";
const models_missing = "No signed-in account has a saved model list. Sign in and fetch a " ++
    "list with /model in Drinky.";

const block_separator = "\n\n";

pub const Options = struct {
    directories: accounts.json_store.Directories,
    environment: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    transport: ?providers.Transport = null,
};

pub const Request = struct {
    run: command_line.Run,
    prompt: []const u8,
};

const Found = union(enum) {
    model: Target,
    unknown,
    unusable: usize,

    const Target = struct {
        account: usize,
        model: accounts.Model,
    };
};

const Listener = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    blocks: std.ArrayList(std.ArrayList(u8)) = .empty,
    final: std.ArrayList(u8) = .empty,
    lost: bool = false,
    outcome: ?core.Session.Outcome = null,
    ended: std.Io.Event = .unset,

    const vtable: core.Session.Sink.VTable = .{ .emit = emit };

    fn sink(self: *Listener) core.Session.Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *Listener) void {
        self.discard(self.blocks.items.len);
        self.blocks.deinit(self.gpa);
        self.final.deinit(self.gpa);
        if (self.outcome) |*outcome| outcome.deinit(self.gpa);
    }

    fn emit(ptr: *anyopaque, event: *const core.Session.Event) void {
        const self: *Listener = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (event.*) {
            .turn_ended => |*outcome| {
                self.outcome = outcome.dupe(self.gpa);
                self.ended.set(self.io);
            },
            else => if (!self.lost) self.apply(event) catch {
                self.lost = true;
            },
        }
    }

    fn apply(self: *Listener, event: *const core.Session.Event) error{OutOfMemory}!void {
        switch (event.*) {
            .text_started, .reasoning_started, .tool_call_started => {
                try self.blocks.append(self.gpa, .empty);
            },
            .text => |delta| {
                const blocks = self.blocks.items;
                try blocks[blocks.len - 1].appendSlice(self.gpa, delta);
            },
            .tail_discarded => |count| self.discard(count),
            .committed => try self.commit(),
            else => {},
        }
    }

    fn discard(self: *Listener, count: usize) void {
        std.debug.assert(count <= self.blocks.items.len);
        for (0..count) |_| {
            var block = self.blocks.pop().?;
            block.deinit(self.gpa);
        }
    }

    fn commit(self: *Listener) error{OutOfMemory}!void {
        self.final.clearRetainingCapacity();
        for (self.blocks.items) |block| {
            if (block.items.len == 0) continue;
            if (self.final.items.len > 0) try self.final.appendSlice(self.gpa, block_separator);
            try self.final.appendSlice(self.gpa, block.items);
        }
        self.discard(self.blocks.items.len);
    }

    fn report(self: *Listener, options: *const Options) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.lost) return refuseFailure(self.gpa, options, &.{ .reason = .out_of_memory });
        switch (self.outcome.?) {
            .stopped => |reason| {
                try self.writeFinal(options.stdout);
                return switch (reason) {
                    .complete => true,
                    .truncated => refuse(options.stderr, Screen.truncated_event),
                };
            },
            .exhausted => {
                try self.writeFinal(options.stdout);
                return refuse(options.stderr, Screen.exhausted_event);
            },
            .failed => |*failure| return refuseFailure(self.gpa, options, failure),
            .canceled => unreachable,
        }
    }

    fn writeFinal(self: *const Listener, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const text = self.final.items;
        if (text.len == 0) return;
        try writer.writeAll(text);
        if (text[text.len - 1] != '\n') try writer.writeByte('\n');
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    request: *const Request,
) !bool {
    const stderr = options.stderr;
    if (options.environment.get(tool_environment.nested) != null)
        return refuse(stderr, nested_refusal);
    if (!std.unicode.utf8ValidateSlice(request.prompt)) return refuse(stderr, prompt_not_utf8);
    if (std.mem.trim(u8, request.prompt, &std.ascii.whitespace).len == 0)
        return refuse(stderr, prompt_missing);

    var environment = try options.environment.clone(gpa);
    defer environment.deinit();
    try environment.put(tool_environment.nested, "1");
    const block = try environment.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);

    var harness: Harness = undefined;
    try harness.init(gpa, io, &.{
        .directories = options.directories,
        .environ = .{ .block = block },
        .surface = .run,
    });
    defer harness.deinit(gpa);
    var registry: accounts.Registry = undefined;
    try openRegistry(&registry, gpa, io, options, &harness.config.timeouts);
    defer registry.deinit();

    const target = switch (find(&registry, request.run.model)) {
        .model => |target| target,
        .unknown => return refuseModel(gpa, options, request.run.model),
        .unusable => |account| return refuseAccount(options, &registry, account),
    };
    var client: accounts.Client = undefined;
    registry.open(&client, target.account) catch |err| switch (err) {
        error.SignedOut => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer client.deinit();

    var listener: Listener = .{ .gpa = gpa, .io = io };
    defer listener.deinit();
    var session = harness.session(gpa, io, listener.sink());
    defer session.deinit();
    try session.start();
    const variables = tool_environment.variables(request.run.model, request.run.effort);
    try session.send(&.{ .configure = .{
        .provider = client.provider(),
        .account = accounts.Account.table[target.account].id,
        .model = target.model.name(),
        .effort = target.model.fold(request.run.effort),
        .tokens_max = target.model.tokens_max,
        .system = harness.system,
        .variables = &variables,
    } });
    try session.send(&.{ .prompt = request.prompt });
    listener.ended.waitUncancelable(io);
    return listener.report(options);
}

pub fn models(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !bool {
    var registry: accounts.Registry = undefined;
    try openRegistry(&registry, gpa, io, options, &accounts.Registry.timeouts_default);
    defer registry.deinit();

    var listed: std.ArrayList(accounts.Model) = .empty;
    defer listed.deinit(gpa);
    var count: usize = 0;
    for (&accounts.Account.table, 0..) |*row, index| {
        if (!registry.isAuthenticated(index)) continue;
        listed.clearRetainingCapacity();
        try registry.listModels(index, &listed, gpa);
        for (listed.items) |*model| {
            try options.stdout.print("{s}/{s}\n", .{ row.id, model.name() });
        }
        count += listed.items.len;
    }
    if (count == 0) return refuse(options.stderr, models_missing);
    return true;
}

const registry_sink_vtable: accounts.Registry.Sink.VTable = .{ .emit = emitRegistryEvent };

fn emitRegistryEvent(_: *anyopaque, _: *const accounts.Registry.Event) void {
    unreachable;
}

fn openRegistry(
    registry: *accounts.Registry,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    timeouts: *const accounts.Registry.Timeouts,
) !void {
    try registry.init(gpa, io, &.{
        .directories = options.directories,
        .environment = options.environment,
        .sink = .{ .ptr = registry, .vtable = &registry_sink_vtable },
        .timeouts = timeouts.*,
        .transport = options.transport,
    });
}

fn find(registry: *accounts.Registry, value: []const u8) Found {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return .unknown;
    const account = accounts.Account.index(value[0..slash]) orelse return .unknown;
    if (!registry.isAuthenticated(account)) return .{ .unusable = account };
    const model = registry.findModel(account, value[slash + 1 ..]) orelse return .unknown;
    return .{ .model = .{ .account = account, .model = model } };
}

fn refuse(writer: *std.Io.Writer, sentence: []const u8) std.Io.Writer.Error!bool {
    try writer.print("{s}\n", .{sentence});
    return false;
}

fn refuseFailure(
    gpa: std.mem.Allocator,
    options: *const Options,
    failure: *const core.Provider.Failure,
) !bool {
    const text = try Screen.failureText(gpa, failure);
    defer gpa.free(text);
    return refuse(options.stderr, text);
}

fn refuseModel(gpa: std.mem.Allocator, options: *const Options, value: []const u8) !bool {
    const shown = try escape.diagnostic(gpa, value);
    defer gpa.free(shown);
    try options.stderr.print(
        "Drinky does not know the model \"{s}\". Run drinky models for the valid values.\n",
        .{shown},
    );
    return false;
}

fn refuseAccount(
    options: *const Options,
    registry: *const accounts.Registry,
    account: usize,
) std.Io.Writer.Error!bool {
    const row = &accounts.Account.table[account];
    const stderr = options.stderr;
    if (registry.loadError(account)) |err| {
        try stderr.print("Drinky could not load the {s} account because of error {s}.\n", .{
            row.id,
            @errorName(err),
        });
        return false;
    }
    switch (row.credential) {
        .store => try stderr.print(
            "Drinky cannot use the account {s} because it is signed out. Sign in with /login " ++
                "in Drinky.\n",
            .{row.id},
        ),
        .environment, .key_file => try stderr.print(
            "Set {s} in the environment to use the account {s}.\n",
            .{ row.setting().?, row.id },
        ),
    }
    return false;
}

test "a run gives its tools its three variables and writes only the final reply to stdout" {
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = marker_call_stream },
        .{ .body = providers.testing.reply_stream },
    } });
    defer rig.deinit();

    try std.testing.expect(try rig.ask(.max, "openai-api-key/gpt-5.6-sol", "check"));
    try std.testing.expectEqualStrings("done\n", rig.stdout.written());
    try std.testing.expectEqualStrings("", rig.stderr.written());
    const requests = rig.transport.requests.items;
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try testing.expectContains(requests[1], "marker:1:openai-api-key/gpt-5.6-sol:max");
}

const Rig = struct {
    tmp: std.testing.TmpDir,
    directory: [:0]const u8,
    environment: std.process.Environ.Map,
    transport: providers.testing.FakeTransport,
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    const config = "{\"request\":{\"attempts_max\":2,\"delay_ms_initial\":0,\"delay_ms_max\":0}}";

    const Seed = struct {
        account: usize,
        names: []const []const u8,
    };

    const Fixture = struct {
        variables: []const [2][]const u8 = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        seeds: []const Seed = &.{
            .{ .account = accounts.testing.openai_api_key, .names = &.{"gpt-5.6-sol"} },
        },
        replies: []const providers.testing.FakeTransport.Reply = &.{},
    };

    fn init(self: *Rig, fixture: *const Fixture) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(io, .{ .sub_path = project.marker_name, .data = "" });
        var store = try self.tmp.dir.createDirPathOpen(io, ".drinky", .{});
        defer store.close(io);
        try store.writeFile(io, .{ .sub_path = "config.json", .data = config });
        self.directory = try self.tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(self.directory);
        for (fixture.seeds) |seed| {
            var catalog: accounts.testing.Rig = undefined;
            try catalog.init(gpa, io, &.{ .home = self.directory });
            defer catalog.deinit();
            try catalog.seed(seed.account, seed.names);
        }
        self.environment = .init(gpa);
        errdefer self.environment.deinit();
        for (fixture.variables) |variable| try self.environment.put(variable[0], variable[1]);
        self.transport = .{ .gpa = gpa, .replies = fixture.replies };
        self.stdout = .init(gpa);
        self.stderr = .init(gpa);
    }

    fn deinit(self: *Rig) void {
        self.stderr.deinit();
        self.stdout.deinit();
        self.transport.deinit();
        self.environment.deinit();
        std.testing.allocator.free(self.directory);
        self.tmp.cleanup();
    }

    fn setup(self: *Rig) Options {
        return .{
            .directories = .{ .working_directory = self.directory, .home = self.directory },
            .environment = &self.environment,
            .stdout = &self.stdout.writer,
            .stderr = &self.stderr.writer,
            .transport = self.transport.transport(),
        };
    }

    fn ask(self: *Rig, effort: core.Provider.Effort, model: []const u8, prompt: []const u8) !bool {
        return run(std.testing.allocator, std.testing.io, &self.setup(), &.{
            .run = .{ .model = model, .effort = effort },
            .prompt = prompt,
        });
    }

    fn listModels(self: *Rig) !bool {
        return models(std.testing.allocator, std.testing.io, &self.setup());
    }
};

fn frame(comptime payload: []const u8) []const u8 {
    return "data: " ++ providers.testing.oneLine(payload) ++ "\n\n";
}

const marker_call_stream = frame(
    \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"I check the marker."}
) ++ frame(
    \\{"type":"response.output_item.done","item":{"id":"msg_1","type":"message",
    \\"role":"assistant","content":[{"type":"output_text","text":"I check the marker."}]}}
) ++ frame(
    \\{"type":"response.output_item.done","item":{"id":"fc_1","type":"function_call",
    \\"status":"completed","call_id":"call_1","name":"bash",
    \\"arguments":"{\"command\":\"echo marker:$DRINKY_RUN:$DRINKY_MODEL:$DRINKY_EFFORT\"}"}}
) ++ frame(
    \\{"type":"response.completed","response":{"status":"completed"}}
);

const truncated_stream = frame(
    \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"partial"}
) ++ frame(
    \\{"type":"response.output_item.done","item":{"id":"msg_1","type":"message",
    \\"role":"assistant","status":"incomplete","content":[{"type":"output_text",
    \\"text":"partial"}]}}
) ++ frame(
    \\{"type":"response.incomplete","response":{"status":"incomplete"}}
);

test "a run leaves a skill out of its system prompt when the metadata hides it from a run" {
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{.{ .body = providers.testing.reply_stream }} });
    defer rig.deinit();
    try rig.tmp.dir.createDirPath(io, ".agents/skills/listed");
    try rig.tmp.dir.writeFile(io, .{
        .sub_path = ".agents/skills/listed/SKILL.md",
        .data = "---\nname: listed\ndescription: the listed skill\n---\nbody\n",
    });
    try rig.tmp.dir.createDirPath(io, ".agents/skills/review");
    try rig.tmp.dir.writeFile(io, .{
        .sub_path = ".agents/skills/review/SKILL.md",
        .data = "---\nname: review\ndescription: the review skill\n" ++
            "metadata:\n  drinky-run: hidden\n---\nbody\n",
    });

    try std.testing.expect(try rig.ask(.high, "openai-api-key/gpt-5.6-sol", "check"));
    const request = rig.transport.requests.items[0];
    try testing.expectContains(request, "the listed skill");
    try std.testing.expect(std.mem.indexOf(u8, request, "the review skill") == null);
}

test "a run asks for the effort level of the model that is nearest to the requested level" {
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{.{ .body = providers.testing.reply_stream }} });
    defer rig.deinit();

    try std.testing.expect(try rig.ask(.max, "openai-api-key/gpt-5.6-sol", "check"));
    try testing.expectContains(rig.transport.requests.items[0], "\"effort\":\"high\"");
}

test "a truncated final reply reaches stdout, and its event reaches stderr as a failure" {
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{.{ .body = truncated_stream }} });
    defer rig.deinit();

    try std.testing.expect(!try rig.ask(.high, "openai-api-key/gpt-5.6-sol", "review"));
    try std.testing.expectEqualStrings("partial\n", rig.stdout.written());
    try std.testing.expectEqualStrings(Screen.truncated_event ++ "\n", rig.stderr.written());
}

test "a failed turn writes its failure to stderr and nothing to stdout" {
    const down: providers.testing.FakeTransport.Reply = .{
        .status = .internal_server_error,
        .body = "{\"error\":{\"message\":\"down\"}}",
    };
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{ down, down } });
    defer rig.deinit();

    try std.testing.expect(!try rig.ask(.high, "openai-api-key/gpt-5.6-sol", "review"));
    try std.testing.expectEqualStrings("", rig.stdout.written());
    try testing.expectContains(rig.stderr.written(), ": down\n");
}

test "a run refuses a nested start, a blank prompt, and a prompt that is not UTF-8" {
    const Case = struct {
        variables: []const [2][]const u8 = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        prompt: []const u8,
        refusal: []const u8,
    };
    const cases = [_]Case{
        .{
            .variables = &.{
                .{ "OPENAI_API_KEY", "sk-openai" },
                .{ tool_environment.nested, "1" },
            },
            .prompt = "review",
            .refusal = nested_refusal,
        },
        .{ .prompt = " \n\t", .refusal = prompt_missing },
        .{ .prompt = "review \xff", .refusal = prompt_not_utf8 },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        try rig.init(&.{ .variables = case.variables });
        defer rig.deinit();
        try std.testing.expect(!try rig.ask(.high, "openai-api-key/gpt-5.6-sol", case.prompt));
        try std.testing.expectEqualStrings("", rig.stdout.written());
        try std.testing.expectEqualStrings(case.refusal, std.mem.trimEnd(
            u8,
            rig.stderr.written(),
            "\n",
        ));
        try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
    }
}

test "a run refuses an unknown model and names why it cannot use an account" {
    const Case = struct {
        variables: []const [2][]const u8 = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        model: []const u8,
        refusal: []const u8,
    };
    const cases = [_]Case{
        .{
            .model = "openai-api-key/gpt-9",
            .refusal = "Drinky does not know the model \"openai-api-key/gpt-9\". Run drinky " ++
                "models for the valid values.\n",
        },
        .{
            .model = "gpt-5.6-sol",
            .refusal = "Drinky does not know the model \"gpt-5.6-sol\". Run drinky models for " ++
                "the valid values.\n",
        },
        .{
            .model = "anthropic-plan/claude-opus-5",
            .refusal = "Drinky cannot use the account anthropic-plan because it is signed out. " ++
                "Sign in with /login in Drinky.\n",
        },
        .{
            .model = "anthropic-api-key/claude-opus-5",
            .refusal = "Set ANTHROPIC_API_KEY in the environment to use the account " ++
                "anthropic-api-key.\n",
        },
        .{
            .variables = &.{
                .{ "GOOGLE_APPLICATION_CREDENTIALS", "/missing/key.json" },
                .{ "GOOGLE_CLOUD_LOCATION", "eu" },
            },
            .model = "google-cloud-key/gemini-3.5-pro",
            .refusal = "Drinky could not load the google-cloud-key account because of error " ++
                "FileNotFound.\n",
        },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        try rig.init(&.{ .variables = case.variables });
        defer rig.deinit();
        try std.testing.expect(!try rig.ask(.high, case.model, "review"));
        try std.testing.expectEqualStrings(case.refusal, rig.stderr.written());
        try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
    }
}

test "the model list names each saved model of a signed-in account and fails when empty" {
    var rig: Rig = undefined;
    try rig.init(&.{ .seeds = &.{
        .{
            .account = accounts.testing.openai_api_key,
            .names = &.{ "gpt-5.6-sol", "gpt-5.6-luna" },
        },
        .{ .account = accounts.testing.anthropic_api_key, .names = &.{"claude-opus-5"} },
    } });
    defer rig.deinit();
    try std.testing.expect(try rig.listModels());
    try std.testing.expectEqualStrings(
        "openai-api-key/gpt-5.6-sol\nopenai-api-key/gpt-5.6-luna\n",
        rig.stdout.written(),
    );

    var empty: Rig = undefined;
    try empty.init(&.{ .seeds = &.{} });
    defer empty.deinit();
    try std.testing.expect(!try empty.listModels());
    try std.testing.expectEqualStrings("", empty.stdout.written());
    try std.testing.expectEqualStrings(models_missing ++ "\n", empty.stderr.written());
}
