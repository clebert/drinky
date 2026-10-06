const std = @import("std");

const core = @import("core");

const testing = @import("testing.zig");

const Herdr = @This();

const queue_capacity = 16;
const attempt_timeout_ms = [_]u64{ 500, 1500 };
pub const line_bytes_max = 1024;
const source = "custom:drinky";
const agent_label = "drinky";

io: std.Io,
future: ?std.Io.Future(void),
queue: std.Io.Queue(State),
queue_buffer: [queue_capacity]State,
state_queued: ?State,
exiting: std.atomic.Value(bool),

pub const Endpoint = struct {
    socket_path: []const u8,
    pane_id: []const u8,
};

pub const State = enum {
    idle,
    working,
    blocked,
};

const Request = union(enum) {
    report: State,
    release,
};

const Sequence = struct {
    last: u64 = 0,

    fn next(self: *Sequence, io: std.Io) u64 {
        const now_us = std.Io.Timestamp.now(io, .real).toMicroseconds();
        const floor: u64 = if (now_us > 0) @intCast(now_us) else 0;
        self.last = @max(self.last +| 1, floor);
        return self.last;
    }
};

pub fn fromEnviron(environ_map: *const std.process.Environ.Map) ?Endpoint {
    const flag = environ_map.get("HERDR_ENV") orelse return null;
    if (!std.mem.eql(u8, flag, "1")) return null;
    const socket_path = environ_map.get("HERDR_SOCKET_PATH") orelse return null;
    const pane_id = environ_map.get("HERDR_PANE_ID") orelse return null;
    if (socket_path.len == 0 or socket_path.len > std.Io.net.UnixAddress.max_len) return null;
    if (pane_id.len == 0) return null;
    return .{ .socket_path = socket_path, .pane_id = pane_id };
}

pub fn init(io: std.Io) Herdr {
    return .{
        .io = io,
        .future = null,
        .queue = undefined,
        .queue_buffer = undefined,
        .state_queued = null,
        .exiting = .init(false),
    };
}

pub fn start(self: *Herdr, maybe_endpoint: ?Endpoint) std.Io.ConcurrentError!void {
    std.debug.assert(self.future == null);
    const endpoint = maybe_endpoint orelse return;
    self.queue = .init(&self.queue_buffer);
    self.state_queued = .idle;
    self.future = try self.io.concurrent(run, .{ self, endpoint });
}

pub fn sync(self: *Herdr, state: State) void {
    if (self.future == null) return;
    if (self.state_queued == state) return;
    const count = self.queue.put(self.io, &.{state}, 0) catch return;
    if (count == 1) self.state_queued = state;
}

pub fn deinit(self: *Herdr) void {
    if (self.future) |*future| {
        self.exiting.store(true, .release);
        self.queue.close(self.io);
        future.await(self.io);
        self.future = null;
    }
}

fn run(self: *Herdr, endpoint: Endpoint) void {
    var sequence: Sequence = .{};
    var batch: [queue_capacity]State = undefined;
    self.deliver(&endpoint, .{ .report = .idle }, sequence.next(self.io));
    while (true) {
        const count = self.queue.get(self.io, &batch, 1) catch break;
        if (self.exiting.load(.acquire)) break;
        self.deliver(&endpoint, .{ .report = batch[count - 1] }, sequence.next(self.io));
    }
    self.deliver(&endpoint, .release, sequence.next(self.io));
}

fn deliver(
    self: *const Herdr,
    endpoint: *const Endpoint,
    request: Request,
    sequence_number: u64,
) void {
    var line_buffer: [line_bytes_max]u8 = undefined;
    var line_writer: std.Io.Writer = .fixed(&line_buffer);
    writeRequest(&line_writer, endpoint, request, sequence_number) catch return;
    const line = line_writer.buffered();
    for (attempt_timeout_ms) |timeout_ms| {
        core.timeout.run(
            self.io,
            timeout_ms,
            exchange,
            .{ self.io, endpoint, line },
            null,
        ) catch continue;
        return;
    }
}

fn writeRequest(
    writer: *std.Io.Writer,
    endpoint: *const Endpoint,
    request: Request,
    sequence_number: u64,
) !void {
    var id_buffer: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buffer, "drinky:{d}", .{sequence_number});
    switch (request) {
        .report => |state| try std.json.Stringify.value(.{
            .id = id,
            .method = "pane.report_agent",
            .params = .{
                .pane_id = endpoint.pane_id,
                .source = source,
                .agent = agent_label,
                .state = state,
                .seq = sequence_number,
            },
        }, .{}, writer),
        .release => try std.json.Stringify.value(.{
            .id = id,
            .method = "pane.release_agent",
            .params = .{
                .pane_id = endpoint.pane_id,
                .source = source,
                .agent = agent_label,
                .seq = sequence_number,
            },
        }, .{}, writer),
    }
    try writer.writeByte('\n');
}

fn exchange(io: std.Io, endpoint: *const Endpoint, line: []const u8) !void {
    const address = try std.Io.net.UnixAddress.init(endpoint.socket_path);
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
    try std.testing.expectEqual(null, fromEnviron(&environ_map));
    try environ_map.put("HERDR_ENV", "0");
    try std.testing.expectEqual(null, fromEnviron(&environ_map));
    try environ_map.put("HERDR_ENV", "1");
    const endpoint = fromEnviron(&environ_map).?;
    try std.testing.expectEqualStrings("/tmp/herdr.sock", endpoint.socket_path);
    try std.testing.expectEqualStrings("w1:p1", endpoint.pane_id);

    try environ_map.put("HERDR_PANE_ID", "");
    try std.testing.expectEqual(null, fromEnviron(&environ_map));
    try environ_map.put("HERDR_PANE_ID", "w1:p1");
    const long_path = "/" ++ "a" ** std.Io.net.UnixAddress.max_len;
    try environ_map.put("HERDR_SOCKET_PATH", long_path);
    try std.testing.expectEqual(null, fromEnviron(&environ_map));
}

test "the reporter numbers its lines from the clock, forwards each change once, and releases" {
    const gpa = std.testing.allocator;
    var clock: testing.Clock = undefined;
    clock.init(gpa);
    defer clock.deinit();
    clock.advance(std.time.ms_per_s);
    const io = clock.io();
    var fake: testing.FakeHerdr = undefined;
    try fake.init(gpa, std.testing.io);
    defer fake.deinit();
    var serving = try std.testing.io.concurrent(testing.FakeHerdr.serve, .{ &fake, 5 });
    defer _ = serving.cancel(std.testing.io) catch {};

    var herdr: Herdr = .init(io);
    try herdr.start(fake.endpoint());

    const idle = try fake.take();
    defer gpa.free(idle);
    try std.testing.expectEqualStrings(
        "{\"id\":\"drinky:1000000\",\"method\":\"pane.report_agent\"," ++
            "\"params\":{\"pane_id\":\"w1:p1\",\"source\":\"custom:drinky\"," ++
            "\"agent\":\"drinky\",\"state\":\"idle\",\"seq\":1000000}}",
        idle,
    );

    herdr.sync(.working);
    herdr.sync(.working);
    const working = try fake.take();
    defer gpa.free(working);
    try std.testing.expect(
        std.mem.indexOf(u8, working, "\"state\":\"working\",\"seq\":1000001}") != null,
    );

    herdr.sync(.blocked);
    const blocked = try fake.take();
    defer gpa.free(blocked);
    try std.testing.expect(
        std.mem.indexOf(u8, blocked, "\"state\":\"blocked\",\"seq\":1000002}") != null,
    );

    herdr.sync(.idle);
    const idle_again = try fake.take();
    defer gpa.free(idle_again);
    try std.testing.expect(
        std.mem.indexOf(u8, idle_again, "\"state\":\"idle\",\"seq\":1000003}") != null,
    );

    herdr.deinit();
    const release = try fake.take();
    defer gpa.free(release);
    try std.testing.expectEqualStrings(
        "{\"id\":\"drinky:1000004\",\"method\":\"pane.release_agent\"," ++
            "\"params\":{\"pane_id\":\"w1:p1\",\"source\":\"custom:drinky\"," ++
            "\"agent\":\"drinky\",\"seq\":1000004}}",
        release,
    );
    try serving.await(std.testing.io);
}

test "a hostile pane id stays inside its JSON string" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fake: testing.FakeHerdr = undefined;
    try fake.init(gpa, io);
    defer fake.deinit();
    var serving = try io.concurrent(testing.FakeHerdr.serve, .{ &fake, 2 });
    defer _ = serving.cancel(io) catch {};

    var endpoint = fake.endpoint();
    endpoint.pane_id = "w1\",\"x\":\"";
    var herdr: Herdr = .init(io);
    try herdr.start(endpoint);
    herdr.deinit();
    for (0..2) |_| {
        const line = try fake.take();
        defer gpa.free(line);
        try std.testing.expect(
            std.mem.indexOf(u8, line, "\"pane_id\":\"w1\\\",\\\"x\\\":\\\"\",") != null,
        );
    }
    try serving.await(io);
}

test "the exit skips a state that still waits and sends the release alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fake: testing.FakeHerdr = undefined;
    try fake.init(gpa, io);
    defer fake.deinit();
    var serving = try io.concurrent(testing.FakeHerdr.serve, .{ &fake, 2 });
    defer _ = serving.cancel(io) catch {};

    var herdr: Herdr = .init(io);
    herdr.queue = .init(&herdr.queue_buffer);
    try herdr.queue.putOne(io, .working);
    herdr.exiting.store(true, .release);
    herdr.queue.close(io);
    run(&herdr, fake.endpoint());

    const idle = try fake.take();
    defer gpa.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "\"state\":\"idle\"") != null);
    const release = try fake.take();
    defer gpa.free(release);
    try std.testing.expect(
        std.mem.indexOf(u8, release, "\"method\":\"pane.release_agent\"") != null,
    );
    try serving.await(io);
    try std.testing.expect(try fake.drained());
}

test "a missing Herdr makes every call a silent no-op" {
    const io = std.testing.io;
    var inert: Herdr = .init(io);
    try inert.start(null);
    inert.sync(.working);
    inert.deinit();

    var orphan: Herdr = .init(io);
    try orphan.start(.{ .socket_path = "/nonexistent/herdr.sock", .pane_id = "w1:p1" });
    orphan.sync(.working);
    orphan.sync(.idle);
    orphan.deinit();
}

test "a reporter whose task cannot start returns the failure and stays a no-op" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var herdr: Herdr = .init(threaded.io());
    try std.testing.expectError(
        error.ConcurrencyUnavailable,
        herdr.start(.{ .socket_path = "/tmp/herdr.sock", .pane_id = "w1:p1" }),
    );
    herdr.sync(.working);
    herdr.deinit();
}
