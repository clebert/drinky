//! The state that Herdr shows for this pane. Herdr holds a terminal pane open
//! and notifies the user when the agent inside it stops or waits. It detects
//! only the agents that its binary knows, so Drinky reports its own state over
//! the Herdr socket: `working` during a turn, `blocked` while a failed turn
//! waits for Ctrl+N, and `idle` otherwise. The channel carries state outward
//! alone. Every failure to deliver is silent, because the report is a courtesy
//! and no part of the work.

const std = @import("std");

const ai = @import("ai");

const Herdr = @This();

/// The states the loop handed over and the reporter has not taken yet. A human
/// drives every transition, so the reporter drains the queue far faster than the
/// loop fills it.
const queue_capacity = 16;
/// The bounds of one delivery: a fast first attempt, then one patient retry.
/// They mirror the hook that Herdr ships for its own agents.
const attempt_timeout_ms = [_]u64{ 500, 1500 };
/// The bytes of one request line and one response line. A response carries an
/// id, a result type, and an error message at most.
const line_bytes_max = 1024;
/// Herdr keys its authority over the pane by this pair, so both stay constant.
const source = "custom:drinky";
const agent_label = "drinky";

io: std.Io,
/// The reporter task, or null before the start and outside Herdr.
future: ?std.Io.Future(void),
/// The channel from the loop to the reporter. Backed by `queue_buffer`, so pin
/// the `Herdr`.
queue: std.Io.Queue(State),
queue_buffer: [queue_capacity]State,
/// The last state that entered the queue, or null before the start.
state_queued: ?State,
/// The exit sets it before it closes the queue, so the reporter skips a state
/// that still waits there. The release drops the authority anyway.
exiting: std.atomic.Value(bool),

/// What Herdr injects into a pane process. Both values borrow the process
/// environment.
pub const Env = struct {
    socket_path: []const u8,
    pane_id: []const u8,
};

/// The semantic state of the pane. Each tag name is the wire value.
pub const State = enum {
    idle,
    working,
    blocked,
};

const Request = union(enum) {
    report: State,
    release,
};

/// The `seq` of each request. Herdr ignores a request whose `seq` does not pass
/// the last one it accepted from the same source in the same pane. The wall
/// clock in microseconds floors every number, so a restart in the same pane
/// cannot fall behind the process before it.
const Sequence = struct {
    last: u64 = 0,

    fn next(self: *Sequence, io: std.Io) u64 {
        const now_us = std.Io.Timestamp.now(io, .real).toMicroseconds();
        const floor: u64 = if (now_us > 0) @intCast(now_us) else 0;
        self.last = @max(self.last +| 1, floor);
        return self.last;
    }
};

/// The pane environment, or null when this process runs outside a Herdr pane.
/// Herdr sets `HERDR_ENV=1` beside the two values, and its integration guide
/// reports only when all three are present.
pub fn fromEnviron(environ_map: *const std.process.Environ.Map) ?Env {
    const flag = environ_map.get("HERDR_ENV") orelse return null;
    if (!std.mem.eql(u8, flag, "1")) return null;
    const socket_path = environ_map.get("HERDR_SOCKET_PATH") orelse return null;
    const pane_id = environ_map.get("HERDR_PANE_ID") orelse return null;
    if (socket_path.len == 0 or socket_path.len > std.Io.net.UnixAddress.max_len) return null;
    if (pane_id.len == 0) return null;
    return .{ .socket_path = socket_path, .pane_id = pane_id };
}

/// An inert reporter. `start` makes it live inside a Herdr pane.
pub fn init(io: std.Io) Herdr {
    return .{
        .io = io,
        .future = null,
        // Taken in `start`, once the struct rests at its final address.
        .queue = undefined,
        .queue_buffer = undefined,
        .state_queued = null,
        .exiting = .init(false),
    };
}

/// Spawn the reporter, which announces the pane as idle at once. A null `env`
/// leaves the reporter inert, so every later call is a no-op. A spawn that fails
/// leaves it inert too, because no report is worth a stopped session.
pub fn start(self: *Herdr, maybe_env: ?Env) void {
    std.debug.assert(self.future == null);
    const env = maybe_env orelse return;
    self.queue = .init(&self.queue_buffer);
    self.state_queued = .idle;
    self.future = self.io.concurrent(run, .{ self, env }) catch null;
}

/// Hand the current state of the loop to the reporter. An unchanged state costs
/// one compare. A full queue keeps the old state, so the next call tries again.
pub fn sync(self: *Herdr, state: State) void {
    if (self.future == null) return;
    if (self.state_queued == state) return;
    const count = self.queue.put(self.io, &.{state}, 0) catch return;
    if (count == 1) self.state_queued = state;
}

/// Release the pane and reap the reporter. The reporter finishes the delivery it
/// is in, skips any state that still waits, and sends the release, each inside
/// its bounds, so a dead Herdr cannot hold the exit for long.
pub fn deinit(self: *Herdr) void {
    if (self.future) |*future| {
        self.exiting.store(true, .release);
        self.queue.close(self.io);
        future.await(self.io);
        self.future = null;
    }
}

/// The reporter task. It takes the queue in batches and delivers the newest
/// state of each batch, because an older state is history. The exit ends the
/// loop, and the release follows.
fn run(self: *Herdr, env: Env) void {
    var sequence: Sequence = .{};
    var batch: [queue_capacity]State = undefined;
    self.deliver(&env, .{ .report = .idle }, sequence.next(self.io));
    // The queue wakes this loop, and its close ends it.
    while (true) {
        const count = self.queue.get(self.io, &batch, 1) catch break;
        if (self.exiting.load(.acquire)) break;
        self.deliver(&env, .{ .report = batch[count - 1] }, sequence.next(self.io));
    }
    self.deliver(&env, .release, sequence.next(self.io));
}

/// Deliver one request inside its bounds. Every failure is silent, and an io
/// that cannot race the bound skips the attempt rather than run it unbounded.
fn deliver(self: *const Herdr, env: *const Env, request: Request, seq: u64) void {
    var line_buffer: [line_bytes_max]u8 = undefined;
    var line_writer: std.Io.Writer = .fixed(&line_buffer);
    writeRequest(&line_writer, env, request, seq) catch return;
    const line = line_writer.buffered();
    for (attempt_timeout_ms) |timeout_ms| {
        // The outer error is a race that could not spawn. The inner one is the
        // exchange itself or its timeout. Both fail the attempt alike.
        const outcome = ai.net.race(
            self.io,
            timeout_ms,
            exchange,
            .{ self.io, env.socket_path, line },
        ) catch continue;
        outcome catch continue;
        return;
    }
}

/// Write one request line. The JSON serializer writes every string, so no pane
/// id can inject a member.
fn writeRequest(
    writer: *std.Io.Writer,
    env: *const Env,
    request: Request,
    seq: u64,
) !void {
    var id_buffer: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buffer, "drinky:{d}", .{seq});
    switch (request) {
        .report => |state| try std.json.Stringify.value(.{
            .id = id,
            .method = "pane.report_agent",
            .params = .{
                .pane_id = env.pane_id,
                .source = source,
                .agent = agent_label,
                .state = state,
                .seq = seq,
            },
        }, .{}, writer),
        .release => try std.json.Stringify.value(.{
            .id = id,
            .method = "pane.release_agent",
            .params = .{
                .pane_id = env.pane_id,
                .source = source,
                .agent = agent_label,
                .seq = seq,
            },
        }, .{}, writer),
    }
    try writer.writeByte('\n');
}

/// One connection: send the line, then wait for the response line, so Herdr has
/// applied the request before the socket closes. The response decides nothing,
/// because no outcome of it changes what Drinky does.
fn exchange(io: std.Io, socket_path: []const u8, line: []const u8) !void {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var write_buffer: [line_bytes_max]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
    var read_buffer: [line_bytes_max]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    _ = try reader.interface.takeDelimiterInclusive('\n');
}

test "the environment gates the reporter on all three Herdr variables" {
    const gpa = std.testing.allocator;
    var environ_map: std.process.Environ.Map = .init(gpa);
    defer environ_map.deinit();

    try std.testing.expectEqual(null, fromEnviron(&environ_map));
    try environ_map.put("HERDR_SOCKET_PATH", "/tmp/herdr.sock");
    try environ_map.put("HERDR_PANE_ID", "w1:p1");
    // The flag is the switch. A pane that Herdr launched with the flag off must
    // stay silent, and an inherited path alone proves no pane.
    try std.testing.expectEqual(null, fromEnviron(&environ_map));
    try environ_map.put("HERDR_ENV", "0");
    try std.testing.expectEqual(null, fromEnviron(&environ_map));
    try environ_map.put("HERDR_ENV", "1");
    const env = fromEnviron(&environ_map).?;
    try std.testing.expectEqualStrings("/tmp/herdr.sock", env.socket_path);
    try std.testing.expectEqualStrings("w1:p1", env.pane_id);

    try environ_map.put("HERDR_PANE_ID", "");
    try std.testing.expectEqual(null, fromEnviron(&environ_map));
    try environ_map.put("HERDR_PANE_ID", "w1:p1");
    // A path past the socket address limit cannot connect, so it disables the
    // reporter at the gate.
    const long_path = "/" ++ "a" ** std.Io.net.UnixAddress.max_len;
    try environ_map.put("HERDR_SOCKET_PATH", long_path);
    try std.testing.expectEqual(null, fromEnviron(&environ_map));
}

test "a request line names the pane, the source, the agent, and the sequence" {
    const env: Env = .{ .socket_path = "/tmp/herdr.sock", .pane_id = "w1:p1" };
    var buffer: [line_bytes_max]u8 = undefined;

    var report_writer: std.Io.Writer = .fixed(&buffer);
    try writeRequest(&report_writer, &env, .{ .report = .working }, 7);
    try std.testing.expectEqualStrings(
        "{\"id\":\"drinky:7\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:drinky\",\"agent\":\"drinky\",\"state\":\"working\",\"seq\":7}}\n",
        report_writer.buffered(),
    );

    var release_writer: std.Io.Writer = .fixed(&buffer);
    try writeRequest(&release_writer, &env, .release, 8);
    try std.testing.expectEqualStrings(
        "{\"id\":\"drinky:8\",\"method\":\"pane.release_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:drinky\",\"agent\":\"drinky\",\"seq\":8}}\n",
        release_writer.buffered(),
    );

    // A pane id is a string on the wire, so a quote in it cannot close the member.
    const hostile: Env = .{ .socket_path = "/tmp/herdr.sock", .pane_id = "w1\",\"x\":\"" };
    var hostile_writer: std.Io.Writer = .fixed(&buffer);
    try writeRequest(&hostile_writer, &hostile, .release, 9);
    try std.testing.expect(
        std.mem.indexOf(u8, hostile_writer.buffered(), "\"pane_id\":\"w1\\\",\\\"x\\\":\\\"\"") != null,
    );
}

test "the sequence passes both the last number and the wall clock" {
    const io = std.testing.io;
    const before: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds());
    var sequence: Sequence = .{};
    const first = sequence.next(io);
    // The first number floors at the clock, so a restart passes every number of
    // the process that ended before it.
    try std.testing.expect(first >= before);
    // Two reports inside one microsecond still climb.
    try std.testing.expect(sequence.next(io) > first);
    // A clock that lags the counter never moves it back, and the top holds.
    var ahead: Sequence = .{ .last = std.math.maxInt(u64) };
    try std.testing.expectEqual(std.math.maxInt(u64), ahead.next(io));
}

/// Test scaffolding: a Herdr stand-in on a Unix socket in the test cache. It
/// answers each request line with a success line and hands the request to
/// `lines`, so a test can wait for one delivery before it changes the state.
/// Pinned: the queue borrows `lines_buffer`, and `env` borrows `path_buffer`.
const FakeHerdr = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    /// The socket address holds 108 bytes at most, and a temporary directory of
    /// the system can pass that. The test cache is relative and short.
    path_buffer: [128]u8,
    path_length: usize,
    server: std.Io.net.Server,
    lines_buffer: [8][]u8,
    lines: std.Io.Queue([]u8),

    fn init(self: *FakeHerdr, gpa: std.mem.Allocator, io: std.Io) !void {
        self.gpa = gpa;
        self.io = io;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const socket_path = try std.fmt.bufPrint(
            &self.path_buffer,
            ".zig-cache/tmp/{s}/herdr.sock",
            .{&self.tmp.sub_path},
        );
        self.path_length = socket_path.len;
        const address = try std.Io.net.UnixAddress.init(socket_path);
        self.server = try address.listen(io, .{});
        self.lines = .init(&self.lines_buffer);
    }

    fn deinit(self: *FakeHerdr) void {
        self.server.deinit(self.io);
        self.tmp.cleanup();
    }

    fn env(self: *const FakeHerdr) Env {
        return .{ .socket_path = self.path_buffer[0..self.path_length], .pane_id = "w1:p1" };
    }

    fn serve(self: *FakeHerdr, count: usize) !void {
        for (0..count) |_| {
            const stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            var read_buffer: [line_bytes_max]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            const line = try reader.interface.takeDelimiterInclusive('\n');
            const owned = try self.gpa.dupe(u8, line[0 .. line.len - 1]);
            errdefer self.gpa.free(owned);
            var write_buffer: [64]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);
            try writer.interface.writeAll("{\"id\":\"drinky\",\"result\":{\"type\":\"ok\"}}\n");
            try writer.interface.flush();
            try self.lines.putOne(self.io, owned);
        }
    }

    fn take(self: *FakeHerdr) ![]u8 {
        var taken: [1][]u8 = undefined;
        const count = try self.lines.get(self.io, &taken, 1);
        std.debug.assert(count == 1);
        return taken[0];
    }

    /// Whether no request waits that a test did not take.
    fn drained(self: *FakeHerdr) !bool {
        var taken: [1][]u8 = undefined;
        return try self.lines.get(self.io, &taken, 0) == 0;
    }
};

/// The `seq` of one recorded request line.
fn recordedSequence(line: []const u8) !u64 {
    const key = "\"seq\":";
    const at = std.mem.indexOf(u8, line, key) orelse return error.MissingSequence;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, ",}") orelse return error.MissingSequence;
    return std.fmt.parseInt(u64, rest[0..end], 10);
}

test "the reporter announces idle, forwards each change once, and releases on exit" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fake: FakeHerdr = undefined;
    try fake.init(gpa, io);
    defer fake.deinit();
    var serving = try io.concurrent(FakeHerdr.serve, .{ &fake, 4 });
    defer _ = serving.cancel(io) catch {};

    var herdr: Herdr = .init(io);
    herdr.start(fake.env());

    const idle = try fake.take();
    defer gpa.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "\"method\":\"pane.report_agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "\"state\":\"idle\"") != null);

    // The same state twice is one report, and the reporter waits for the first
    // reply before it takes the queue again.
    herdr.sync(.working);
    herdr.sync(.working);
    const working = try fake.take();
    defer gpa.free(working);
    try std.testing.expect(std.mem.indexOf(u8, working, "\"state\":\"working\"") != null);

    herdr.sync(.blocked);
    const blocked = try fake.take();
    defer gpa.free(blocked);
    try std.testing.expect(std.mem.indexOf(u8, blocked, "\"state\":\"blocked\"") != null);

    herdr.deinit();
    const release = try fake.take();
    defer gpa.free(release);
    try std.testing.expect(std.mem.indexOf(u8, release, "\"method\":\"pane.release_agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, release, "\"pane_id\":\"w1:p1\"") != null);
    try serving.await(io);

    try std.testing.expect(try recordedSequence(idle) < try recordedSequence(working));
    try std.testing.expect(try recordedSequence(working) < try recordedSequence(blocked));
    try std.testing.expect(try recordedSequence(blocked) < try recordedSequence(release));
    // The release ends the reporter, so a later state has no taker.
    try std.testing.expect(herdr.future == null);
}

test "the exit skips a state that still waits and sends the release alone" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fake: FakeHerdr = undefined;
    try fake.init(gpa, io);
    defer fake.deinit();
    var serving = try io.concurrent(FakeHerdr.serve, .{ &fake, 2 });
    defer _ = serving.cancel(io) catch {};

    // A reporter that the exit caught with a state in its queue. The test drives
    // `run` itself, so no delivery timing enters the outcome.
    var herdr: Herdr = .init(io);
    herdr.queue = .init(&herdr.queue_buffer);
    try herdr.queue.putOne(io, .working);
    herdr.exiting.store(true, .release);
    herdr.queue.close(io);
    run(&herdr, fake.env());

    const idle = try fake.take();
    defer gpa.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "\"state\":\"idle\"") != null);
    const release = try fake.take();
    defer gpa.free(release);
    try std.testing.expect(std.mem.indexOf(u8, release, "\"method\":\"pane.release_agent\"") != null);
    try serving.await(io);
    try std.testing.expect(try fake.drained());
}

test "a missing Herdr makes every call a silent no-op" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Outside Herdr, nothing spawns.
    var inert: Herdr = .init(io);
    inert.start(null);
    inert.sync(.working);
    inert.deinit();
    try std.testing.expect(inert.future == null);

    // Inside a pane whose Herdr is gone, every delivery fails at the connect and
    // the exit does not wait on it.
    var orphan: Herdr = .init(io);
    orphan.start(.{ .socket_path = "/nonexistent/herdr.sock", .pane_id = "w1:p1" });
    orphan.sync(.working);
    orphan.sync(.idle);
    orphan.deinit();
    try std.testing.expect(orphan.future == null);
}
