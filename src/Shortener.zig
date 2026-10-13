const std = @import("std");

const core = @import("core");

const testing = @import("testing.zig");

const Shortener = @This();

const mail_capacity = 16;

gpa: std.mem.Allocator,
io: std.Io,
model: Model,
sink: Sink,
mailbox: core.actor.Mailbox(Mail, mail_capacity),
loop: ?std.Io.Future(void),
current: ?Request,
next: ?Request,

pub const Options = struct {
    model: Model,
    sink: Sink,
};

pub const Model = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        shorten: *const fn (ptr: *anyopaque, answer: []const u8, sink: Model.Sink) Outcome,
    };

    pub const Sink = core.actor.Sink([]const u8);

    fn shorten(self: Model, answer: []const u8, sink: Model.Sink) Outcome {
        return self.vtable.shorten(self.ptr, answer, sink);
    }
};

pub const Outcome = union(enum) {
    finished,
    failed: Failure,
    canceled,
};

pub const Failure = struct {
    bytes: [bytes_max]u8,
    length: usize,

    const bytes_max = 512;

    pub fn print(comptime format: []const u8, args: anytype) Failure {
        var failure: Failure = .{ .bytes = undefined, .length = 0 };
        var writer: std.Io.Writer = .fixed(&failure.bytes);
        writer.print(format, args) catch {};
        failure.length = core.text.validPrefix(writer.buffered()).len;
        return failure;
    }

    fn text(self: *const Failure) []const u8 {
        return self.bytes[0..self.length];
    }
};

pub const Event = struct {
    request: u64,
    content: Content,

    pub const Content = union(enum) {
        text: []const u8,
        failed: []const u8,
        finished,
    };

    pub fn dupe(self: *const Event, gpa: std.mem.Allocator) error{OutOfMemory}!Event {
        return .{ .request = self.request, .content = switch (self.content) {
            .text => |text| .{ .text = try gpa.dupe(u8, text) },
            .failed => |message| .{ .failed = try gpa.dupe(u8, message) },
            .finished => .finished,
        } };
    }

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        switch (self.content) {
            .text, .failed => |bytes| gpa.free(bytes),
            .finished => {},
        }
    }
};

pub const Sink = core.actor.Sink(Event);

const Request = struct {
    number: u64,
    answer: []u8,
};

const Mail = union(enum) {
    shorten: Request,
    cancel,
    ended: Outcome,

    pub fn deinit(self: *const Mail, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .shorten => |request| gpa.free(request.answer),
            .cancel, .ended => {},
        }
    }
};

const Lent = struct {
    io: std.Io,
    model: Model,
    sink: Sink,
    request: u64,
    answer: []const u8,

    const vtable: Model.Sink.VTable = .{ .emit = relay };

    fn relay(ptr: *anyopaque, text: *const []const u8) void {
        const self: *const Lent = @ptrCast(@alignCast(ptr));
        self.sink.emit(self.io, &.{ .request = self.request, .content = .{ .text = text.* } });
    }
};

pub const Fm = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    const vtable: Model.VTable = .{ .shorten = shortenAnswer };

    const instructions = "You shorten an answer for a small phone screen. " ++
        "Write at most 6 bullet points with at most 15 words each. " ++
        "Put the direct answer first. " ++
        "Copy names, numbers, commands, and paths exactly. " ++
        "Add no fact that the answer does not state. " ++
        "Leave out tables, headings, and explanations.";

    const path = "/usr/bin/fm";
    const available_argv = [_][]const u8{ path, "available", "--model", "system" };
    const respond_argv = [_][]const u8{
        path,             "respond",
        "--stream",       "--greedy",
        "--guardrails",   "permissive-content-transformations",
        "--instructions", instructions,
    };

    const run_failure = "Drinky could not run `fm` because of error {s}.";
    const read_failure = "Drinky could not read the output of `fm` because of error {s}.";
    const oversized_failure = "Drinky stopped `fm` because it wrote more output than Drinky keeps.";

    const license_exit_code = 69;
    const report_bytes_max = 64 * 1024;
    const output_bytes_max = 1024 * 1024;
    const read_bytes_min = 4096;

    const Exit = struct {
        lead: []const u8,
        term: std.process.Child.Term,
        reports: []const []const u8,
    };

    pub fn model(self: *Fm) Model {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn shortenAnswer(ptr: *anyopaque, answer: []const u8, sink: Model.Sink) Outcome {
        const self: *Fm = @ptrCast(@alignCast(ptr));
        return self.stream(answer, sink) catch |err| switch (err) {
            error.Canceled => .canceled,
        };
    }

    fn stream(self: *Fm, answer: []const u8, sink: Model.Sink) std.Io.Cancelable!Outcome {
        if (try self.unavailability()) |failure| return .{ .failed = failure };
        return self.respond(answer, sink);
    }

    fn unavailability(self: *Fm) std.Io.Cancelable!?Failure {
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &available_argv,
            .stdout_limit = .limited(report_bytes_max),
            .stderr_limit = .limited(report_bytes_max),
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return Failure.print(run_failure, .{@errorName(err)}),
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term.success()) return null;
        return describe(&.{
            .lead = "The local model is not available.",
            .term = result.term,
            .reports = &.{ result.stderr, result.stdout },
        });
    }

    fn respond(self: *Fm, answer: []const u8, sink: Model.Sink) std.Io.Cancelable!Outcome {
        const io = self.io;
        var child = std.process.spawn(io, .{
            .argv = &respond_argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return .{ .failed = .print(run_failure, .{@errorName(err)}) },
        };
        defer child.kill(io);
        child.stdin.?.writeStreamingAll(io, answer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
        child.stdin.?.close(io);
        child.stdin = null;

        var streams: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(self.gpa, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();
        const output = multi_reader.reader(0);
        const reports = multi_reader.reader(1);
        var sent_bytes: usize = 0;
        while (multi_reader.fill(read_bytes_min, .none)) |_| {
            const ready = core.text.validPrefix(output.buffered());
            if (ready.len > 0) {
                sink.emit(io, &ready);
                sent_bytes += ready.len;
                output.toss(ready.len);
            }
            const oversized = sent_bytes > output_bytes_max or
                reports.bufferedLen() > report_bytes_max;
            if (oversized) return .{ .failed = .print(oversized_failure, .{}) };
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.Canceled => return error.Canceled,
            else => return .{ .failed = .print(read_failure, .{@errorName(err)}) },
        }
        multi_reader.checkAnyError() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return .{ .failed = .print(read_failure, .{@errorName(err)}) },
        };
        const rest = output.buffered();
        if (rest.len > 0) sink.emit(io, &rest);

        const term = child.wait(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return .{ .failed = .print(
                "Drinky could not wait for `fm` because of error {s}.",
                .{@errorName(err)},
            ) },
        };
        if (term.success()) return .finished;
        return .{ .failed = describe(&.{
            .lead = "The local model failed.",
            .term = term,
            .reports = &.{reports.buffered()},
        }) };
    }

    fn describe(exit: *const Exit) Failure {
        switch (exit.term) {
            .exited => |code| if (code == license_exit_code)
                return .print("Accept the terms of the local model with `sudo fm license`.", .{}),
            .signal, .stopped, .unknown => {},
        }
        for (exit.reports) |report| {
            const line = firstLine(report);
            if (line.len == 0) continue;
            return .print("{s} `fm` reports: {s}", .{ exit.lead, line });
        }
        return .print("{s} `fm` {f}.", .{ exit.lead, exit.term });
    }

    fn firstLine(report: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, report, " \t\r\n");
        const line_end = std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len;
        return std.mem.trimEnd(u8, trimmed[0..line_end], " \t\r");
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: *const Options) Shortener {
    return .{
        .gpa = gpa,
        .io = io,
        .model = options.model,
        .sink = options.sink,
        .mailbox = .init,
        .loop = null,
        .current = null,
        .next = null,
    };
}

pub fn start(self: *Shortener) std.Io.ConcurrentError!void {
    self.loop = try self.io.concurrent(run, .{self});
}

pub fn deinit(self: *Shortener) void {
    if (self.loop) |*loop| loop.cancel(self.io);
    self.loop = null;
    self.mailbox.close(self.io);
    self.mailbox.drain(self.io, self.gpa);
}

pub fn shorten(self: *Shortener, request: u64, answer: []const u8) error{OutOfMemory}!void {
    const mail: Mail = .{ .shorten = .{
        .number = request,
        .answer = try self.gpa.dupe(u8, answer),
    } };
    self.mailbox.send(self.io, mail) catch mail.deinit(self.gpa);
}

pub fn cancel(self: *Shortener) void {
    self.mailbox.send(self.io, .cancel) catch {};
}

fn run(self: *Shortener) void {
    self.serve() catch {};
    self.mailbox.cancel(self.io);
    self.mailbox.reap(self.io);
    self.drop(&self.current);
    self.drop(&self.next);
    self.mailbox.drain(self.io, self.gpa);
}

fn serve(self: *Shortener) core.actor.Mailbox(Mail, mail_capacity).Error!void {
    while (true) {
        switch (try self.mailbox.receive(self.io)) {
            .shorten => |request| self.accept(request),
            .cancel => self.stop(),
            .ended => |*outcome| self.end(outcome),
        }
    }
}

fn accept(self: *Shortener, request: Request) void {
    self.drop(&self.next);
    if (!self.mailbox.busy()) return self.begin(request);
    self.mailbox.cancel(self.io);
    self.next = request;
}

fn stop(self: *Shortener) void {
    self.drop(&self.next);
    self.mailbox.cancel(self.io);
}

fn begin(self: *Shortener, request: Request) void {
    self.current = request;
    const lent: Lent = .{
        .io = self.io,
        .model = self.model,
        .sink = self.sink,
        .request = request.number,
        .answer = request.answer,
    };
    self.mailbox.start(self.io, runModel, .{lent}) catch |err| {
        const failure: Failure = .print(
            "Drinky could not start the local model because of error {s}.",
            .{@errorName(err)},
        );
        self.emit(request.number, .{ .failed = failure.text() });
        self.drop(&self.current);
    };
}

fn runModel(lent: Lent) Mail {
    var held = lent;
    return .{ .ended = held.model.shorten(held.answer, .{ .ptr = &held, .vtable = &Lent.vtable }) };
}

fn end(self: *Shortener, outcome: *const Outcome) void {
    self.mailbox.reap(self.io);
    const request = self.current.?.number;
    switch (outcome.*) {
        .finished => self.emit(request, .finished),
        .failed => |*failure| self.emit(request, .{ .failed = failure.text() }),
        .canceled => {},
    }
    self.drop(&self.current);
    const next = self.next orelse return;
    self.next = null;
    self.begin(next);
}

fn drop(self: *Shortener, slot: *?Request) void {
    const request = slot.* orelse return;
    self.gpa.free(request.answer);
    slot.* = null;
}

fn emit(self: *Shortener, request: u64, content: Event.Content) void {
    self.sink.emit(self.io, &.{ .request = request, .content = content });
}

test "a request streams the text of the model and ends with its outcome under its number" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.model.chunks = &.{ "- Short ", "version." };

    try rig.shortener.shorten(1, "The long answer.");
    try rig.expect(1, .{ .text = "- Short " });
    try rig.expect(1, .{ .text = "version." });
    try rig.expect(1, .finished);
    try std.testing.expectEqualStrings("The long answer.", rig.model.answers.items[0]);

    rig.model.outcome = .{ .failed = .print("The local model failed.", .{}) };
    try rig.shortener.shorten(2, "Another answer.");
    try rig.expect(2, .{ .text = "- Short " });
    try rig.expect(2, .{ .text = "version." });
    try rig.expect(2, .{ .failed = "The local model failed." });
}

const Rig = struct {
    model: testing.FakeLocalModel,
    events: std.Io.Queue(Event),
    event_buffer: [64]Event,
    shortener: Shortener,

    const sink_vtable: Sink.VTable = .{ .emit = keep };

    fn init(self: *Rig) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        self.model = .{ .gpa = gpa, .io = io };
        self.events = .init(&self.event_buffer);
        self.shortener = .init(gpa, io, &.{
            .model = self.model.model(),
            .sink = .{ .ptr = self, .vtable = &sink_vtable },
        });
        try self.shortener.start();
    }

    fn deinit(self: *Rig) void {
        const io = std.testing.io;
        self.shortener.deinit();
        self.events.close(io);
        var batch: [8]Event = undefined;
        for (0..self.event_buffer.len) |_| {
            const count = self.events.get(io, &batch, 0) catch break;
            if (count == 0) break;
            for (batch[0..count]) |*event| event.deinit(std.testing.allocator);
        }
        self.model.deinit();
    }

    fn keep(ptr: *anyopaque, event: *const Event) void {
        const self: *Rig = @ptrCast(@alignCast(ptr));
        const owned = event.dupe(std.testing.allocator) catch return;
        self.events.putOne(std.testing.io, owned) catch owned.deinit(std.testing.allocator);
    }

    fn expect(self: *Rig, request: u64, content: Event.Content) !void {
        const event = try self.events.getOne(std.testing.io);
        defer event.deinit(std.testing.allocator);
        try std.testing.expectEqual(request, event.request);
        try std.testing.expectEqual(std.meta.activeTag(content), std.meta.activeTag(event.content));
        switch (content) {
            .text => |text| try std.testing.expectEqualStrings(text, event.content.text),
            .failed => |message| try std.testing.expectEqualStrings(message, event.content.failed),
            .finished => {},
        }
    }
};

test "a newer request cancels the running model and starts after its end" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.model.stalls = 1;

    try rig.shortener.shorten(1, "first");
    try rig.model.reached.wait(std.testing.io);
    try rig.shortener.shorten(2, "second");
    try rig.model.canceled.wait(std.testing.io);
    try rig.expect(2, .finished);
    try std.testing.expectEqual(@as(usize, 2), rig.model.answers.items.len);
    try std.testing.expectEqualStrings("second", rig.model.answers.items[1]);
}

test "a cancel ends the running model without an event, and a deinit ends the next one" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.model.stalls = 2;

    try rig.shortener.shorten(1, "first");
    try rig.model.reached.wait(std.testing.io);
    rig.model.reached.reset();
    rig.shortener.cancel();
    try rig.model.canceled.wait(std.testing.io);
    rig.model.canceled.reset();
    try rig.shortener.shorten(2, "second");
    try rig.model.reached.wait(std.testing.io);
    rig.shortener.deinit();
    try std.testing.expect(rig.model.canceled.isSet());
    var batch: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), try rig.events.get(std.testing.io, &batch, 0));
}

test "a copy of each event owns its bytes, and a failed copy leaks nothing" {
    const events = [_]Event{
        .{ .request = 1, .content = .{ .text = "delta" } },
        .{ .request = 2, .content = .{ .failed = "The local model failed." } },
        .{ .request = 3, .content = .finished },
    };
    try core.testing.checkCopyAllocationFailures(Event, &events);
}
