const std = @import("std");
const application = @import("application");
const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");
const tools = @import("tools");
const command_line = @import("command_line.zig");
const testing = @import("testing.zig");
pub const Options = struct {
    directories: application.Directories,
    environment: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    transport: ?application.Transport = null,
};
pub const Request = struct { run: command_line.Run, prompt: []const u8 };
const queue_capacity = 64;
const Listener = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    reporter: ?application.CostReporter,
    cost_error: ?application.CostReportError = null,
    final: std.ArrayList(u8) = .empty,
    outcome: ?application.Outcome = null,
    refusal: ?application.Message = null,
    mail: std.Io.Queue(application.Mail),
    mail_buffer: [queue_capacity]application.Mail = undefined,

    const sink_vtable: application.Sink.VTable = .{ .emit = emit };
    const mailbox_vtable: application.Mailbox.VTable = .{ .post = post };

    fn init(
        self: *Listener,
        gpa: std.mem.Allocator,
        io: std.Io,
        reporter: ?application.CostReporter,
    ) void {
        self.* = .{ .gpa = gpa, .io = io, .reporter = reporter, .mail = undefined };
        self.mail = .init(&self.mail_buffer);
    }

    fn deinit(self: *Listener) void {
        self.closeMail();
        self.final.deinit(self.gpa);
        if (self.outcome) |*outcome| outcome.deinit(self.gpa);
        if (self.refusal) |*refusal| refusal.deinit(self.gpa);
    }

    fn closeMail(self: *Listener) void {
        self.mail.close(self.io);
        var buffer: [queue_capacity]application.Mail = undefined;
        while (true) {
            const count = self.mail.get(self.io, &buffer, 0) catch return;
            if (count == 0) return;
            for (buffer[0..count]) |*mail| mail.deinit(self.gpa);
        }
    }

    fn ended(self: *const Listener) bool {
        return self.outcome != null or self.refusal != null;
    }

    fn wait(self: *Listener, controller: *application.Controller) void {
        while (!self.ended()) {
            const mail = self.mail.getOneUncancelable(self.io) catch return;
            controller.receive(mail);
        }
    }

    fn emit(ptr: *anyopaque, message: *const application.Event) void {
        const self: *Listener = @ptrCast(@alignCast(ptr));
        switch (message.*) {
            .charge => |amount| self.charge(amount),
            .startup_refused => |*refusal| {
                self.refusal = refusal.dupe(self.gpa) catch application.support.outOfMemory();
            },
            .turn_ended => |*turn| {
                self.outcome = turn.outcome.dupe(self.gpa) catch application.support.outOfMemory();
                self.final.appendSlice(self.gpa, turn.answer) catch
                    application.support.outOfMemory();
            },
            else => {},
        }
    }

    fn post(ptr: *anyopaque, mail: application.Mail) void {
        const self: *Listener = @ptrCast(@alignCast(ptr));
        self.mail.putOneUncancelable(self.io, mail) catch mail.deinit(self.gpa);
    }

    fn charge(self: *Listener, amount: f64) void {
        const reporter = self.reporter orelse return;
        reporter.send(amount) catch |err| {
            self.cost_error = err;
        };
    }

    fn report(self: *Listener, options: *const Options) !bool {
        if (self.refusal) |refusal| return refuse(options.stderr, refusal.content);
        const succeeded = switch (self.outcome.?) {
            .stopped => |reason| stopped: {
                try self.writeFinal(options.stdout);
                break :stopped switch (reason) {
                    .complete => true,
                    .truncated => try refuse(options.stderr, application.support.truncated.content),
                };
            },
            .exhausted => exhausted: {
                try self.writeFinal(options.stdout);
                break :exhausted try refuse(options.stderr, application.support.exhausted);
            },
            .failed => |*failure| try refuseFailure(self.gpa, options, failure),
            .canceled => unreachable,
        };
        if (self.cost_error) |err| return refuseCostReport(options.stderr, err);
        return succeeded;
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
    const reporter = if (options.environment.get(application.cost_report_environment)) |value|
        application.CostReporter.fromEnvironment(io, value) catch |err|
            return refuseCostReport(options.stderr, err)
    else
        null;
    var listener: Listener = undefined;
    listener.init(gpa, io, reporter);
    defer listener.deinit();
    const controller = try application.Controller.create(gpa, io, &.{
        .directories = options.directories,
        .environment = options.environment,
        .transport = options.transport,
        .startup = .{ .run = .{
            .model = request.run.model,
            .effort = request.run.effort,
            .prompt = request.prompt,
        } },
        .sink = .{ .ptr = &listener, .vtable = &Listener.sink_vtable },
        .mailbox = .{ .ptr = &listener, .vtable = &Listener.mailbox_vtable },
    });
    defer {
        listener.closeMail();
        controller.destroy();
    }
    listener.wait(controller);
    return listener.report(options);
}

pub fn models(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !bool {
    const list = try application.model_list.compose(gpa, io, &.{
        .directories = options.directories,
        .environment = options.environment,
        .transport = options.transport,
    });
    defer gpa.free(list);
    if (list.len == 0) return refuse(options.stderr, application.reference.models_missing);
    try options.stdout.writeAll(list);
    return true;
}
fn refuse(writer: *std.Io.Writer, sentence: []const u8) std.Io.Writer.Error!bool {
    try writer.print("{s}\n", .{sentence});
    return false;
}

fn refuseCostReport(
    writer: *std.Io.Writer,
    err: application.CostReportError,
) std.Io.Writer.Error!bool {
    try writer.print("Drinky could not report the run cost because of error {s}.\n", .{
        @errorName(err),
    });
    return false;
}

fn refuseFailure(
    gpa: std.mem.Allocator,
    options: *const Options,
    failure: *const application.Failure,
) !bool {
    const text = try application.support.failureText(gpa, failure);
    defer gpa.free(text);
    return refuse(options.stderr, text);
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

test "a run reports its charge internally and keeps its answer output unchanged" {
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{.{ .body = charged_stream }} });
    defer rig.deinit();
    var pipe = try tools.CostPipe.init();
    defer pipe.deinit(std.testing.io);
    try rig.reportTo(&pipe);

    try std.testing.expect(try rig.ask(.high, "openai-api-key/gpt-5.6-sol", "check"));
    try std.testing.expectEqualStrings("done\n", rig.stdout.written());
    try std.testing.expectEqualStrings("", rig.stderr.written());
    try expectCosts(&pipe, &.{0.42});
}

test "a run reports a failed attempt before the next attempt ends" {
    const io = std.testing.io;
    var hold: providers.testing.FakeTransport.Hold = .{ .io = io };
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = charged_empty_stream },
        .{ .body = charged_stream, .hold = &hold },
    } });
    defer rig.deinit();
    var pipe = try tools.CostPipe.init();
    defer pipe.deinit(io);
    try rig.reportTo(&pipe);
    var future = try io.concurrent(Rig.ask, .{
        &rig, .high, "openai-api-key/gpt-5.6-sol", "check",
    });
    var joined = false;
    defer if (!joined) {
        hold.released.set(io);
        _ = future.await(io) catch {};
    };
    try hold.reached.wait(io);
    try expectFirstCost(&pipe, 0.1);
    try std.testing.expectEqualStrings("", rig.stdout.written());
    hold.released.set(io);
    const succeeded = future.await(io);
    joined = true;
    try std.testing.expect(try succeeded);
    try expectCosts(&pipe, &.{0.42});
    try std.testing.expectEqualStrings("done\n", rig.stdout.written());
}

test "a failed run keeps every reported attempt charge" {
    var rig: Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = charged_empty_stream },
        .{ .body = charged_empty_stream },
    } });
    defer rig.deinit();
    var pipe = try tools.CostPipe.init();
    defer pipe.deinit(std.testing.io);
    try rig.reportTo(&pipe);
    try std.testing.expect(!try rig.ask(.high, "openai-api-key/gpt-5.6-sol", "check"));
    try expectCosts(&pipe, &.{ 0.1, 0.1 });
    try std.testing.expectEqualStrings("", rig.stdout.written());
    try std.testing.expect(rig.stderr.written().len > 0);
}

test "a run estimates each charge from its own model prices and skips unknown prices" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]?accounts.Model.Price{
        null,
        .{ .input = 2, .output = 4, .cache_read = 0, .cache_write = 0 },
        .{ .input = 8, .output = 6, .cache_read = 0, .cache_write = 0 },
    }, [_]?f64{ null, 0.000028, 0.000092 }) |price, expected| {
        var rig: Rig = undefined;
        try rig.init(&.{ .replies = &.{.{ .body = providers.testing.reply_stream }} });
        defer rig.deinit();
        var catalog: accounts.testing.Rig = undefined;
        try catalog.init(gpa, io, &.{ .home = rig.directory });
        defer catalog.deinit();
        var model = try accounts.Model.init("priced-child");
        model.context_window = 1000;
        model.price = price;
        try catalog.registry.catalog.setAccount(accounts.testing.openai_api_key, &.{model});
        var pipe = try tools.CostPipe.init();
        defer pipe.deinit(io);
        try rig.reportTo(&pipe);
        try std.testing.expect(try rig.ask(.high, "openai-api-key/priced-child", "check"));
        if (expected) |amount| {
            try expectCosts(&pipe, &.{amount});
        } else try expectCosts(&pipe, &.{});
    }
}

test "an invalid cost channel refuses the run before it sends a request" {
    var rig: Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    try rig.environment.put(tools.CostPipe.environment, "2");
    try std.testing.expect(!try rig.ask(.high, "openai-api-key/gpt-5.6-sol", "check"));
    try testing.expectContains(rig.stderr.written(), "error InvalidCostReport.");
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

fn expectFirstCost(pipe: *tools.CostPipe, expected: f64) !void {
    var buffer: [64]u8 = undefined;
    const count = try core.timeout.run(std.testing.io, 5_000, readPipe, .{ pipe, &buffer }, null);
    var costs: tools.testing.Costs = .{};
    defer costs.deinit();
    var decoder: tools.CostPipe.Decoder = .{ .sink = costs.sink() };
    try decoder.feed(std.testing.io, buffer[0..count]);
    try costs.expect(&.{expected});
}

fn readPipe(pipe: *tools.CostPipe, buffer: *[64]u8) std.Io.File.ReadStreamingError!usize {
    return pipe.reader.readStreaming(std.testing.io, &.{buffer});
}

fn expectCosts(pipe: *tools.CostPipe, expected: []const f64) !void {
    var costs: tools.testing.Costs = .{};
    defer costs.deinit();
    var decoder: tools.CostPipe.Decoder = .{ .sink = costs.sink() };
    try pipe.drain(std.testing.io, &decoder);
    try decoder.finish();
    try costs.expect(expected);
}

const charged_empty_stream = frame(
    \\{"type":"response.completed","response":{"status":"completed","usage":{"cost":0.1}}}
);

const charged_stream = frame(
    \\{"type":"response.output_item.done","item":{"id":"msg_1","type":"message",
    \\"role":"assistant","content":[{"type":"output_text","text":"done"}]}}
) ++ frame(
    \\{"type":"response.completed","response":{"status":"completed","usage":{
    \\"input_tokens":1000000,"output_tokens":1000000,"cost":0.42}}}
);

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
        try self.tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "" });
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

    fn reportTo(self: *Rig, pipe: *const tools.CostPipe) !void {
        const value = try std.testing.allocator.print("{d}", .{pipe.writer.?.handle});
        defer std.testing.allocator.free(value);
        try self.environment.put(tools.CostPipe.environment, value);
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
    try std.testing.expect(std.mem.find(u8, request, "the review skill") == null);
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
    try std.testing.expectEqualStrings(
        application.support.truncated.content ++ "\n",
        rig.stderr.written(),
    );
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

test "a run refuses a nested start, then a blank or non-UTF-8 prompt, before it checks the model" {
    const Case = struct {
        variables: []const [2][]const u8 = &.{.{ "OPENAI_API_KEY", "sk-openai" }},
        prompt: []const u8,
        refusal: []const u8,
    };
    const cases = [_]Case{
        .{
            .variables = &.{
                .{ "OPENAI_API_KEY", "sk-openai" },
                .{ application.reference.nested, "1" },
            },
            .prompt = " \n\t",
            .refusal = application.reference.nested_refusal,
        },
        .{ .prompt = " \n\t", .refusal = application.reference.prompt_missing },
        .{ .prompt = "review \xff", .refusal = application.reference.prompt_not_utf8 },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        try rig.init(&.{ .variables = case.variables });
        defer rig.deinit();
        try std.testing.expect(!try rig.ask(.high, "openai-api-key/gpt-9", case.prompt));
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
    try std.testing.expectEqualStrings(
        application.reference.models_missing ++ "\n",
        empty.stderr.written(),
    );
}
