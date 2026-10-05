const std = @import("std");

const core = @import("core");

const testing = @import("testing.zig");

const Sse = @This();

pub const bytes_max_default: usize = 256 << 20;

io: std.Io,
body: *std.Io.Reader,
idle_ms: u64,
deadline: core.timeout.Deadline,
budget: Budget,
line: std.Io.Writer.Allocating,

const Error = error{
    Canceled,
    OutOfMemory,
    Timeout,
    ConcurrencyUnavailable,
    TooLarge,
    Incomplete,
    ReadFailed,
};

const Options = struct {
    idle_ms: u64,
    bytes_max: usize = bytes_max_default,
};

const Budget = struct {
    used: usize = 0,
    max: usize,

    fn take(self: *Budget, bytes: usize) error{TooLarge}!void {
        self.used +|= bytes;
        if (self.used > self.max) return error.TooLarge;
    }

    pub fn remaining(self: Budget) usize {
        return self.max -| self.used;
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, body: *std.Io.Reader, options: Options) Sse {
    return .{
        .io = io,
        .body = body,
        .idle_ms = options.idle_ms,
        .deadline = .start(io, options.idle_ms),
        .budget = .{ .max = options.bytes_max },
        .line = .init(gpa),
    };
}

pub fn deinit(self: *Sse) void {
    self.line.deinit();
}

pub fn renewIdleWindow(self: *Sse) void {
    self.deadline = .start(self.io, self.idle_ms);
}

pub fn next(self: *Sse) Error!?[]const u8 {
    const lines_max = self.budget.remaining() + 1;
    for (0..lines_max) |_| {
        if (self.deadline.expired(self.io)) return error.Timeout;
        const line = (try self.takeLine()) orelse return null;
        try self.budget.take(line.len + 1);
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        return std.mem.trimStart(u8, trimmed["data:".len..], " ");
    }
    return error.TooLarge;
}

fn takeLine(self: *Sse) Error!?[]const u8 {
    if (std.mem.indexOfScalar(u8, self.body.buffered(), '\n') != null) return self.readLine();
    return self.deadline.run(self.io, readLine, .{self}, null);
}

fn readLine(self: *Sse) Error!?[]const u8 {
    self.line.clearRetainingCapacity();
    const cap: std.Io.Limit = .limited(self.budget.remaining());
    _ = self.body.streamDelimiterLimit(&self.line.writer, '\n', cap) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
    };
    const pending = self.body.peekByte() catch |err| switch (err) {
        error.EndOfStream => return if (self.line.written().len == 0) null else error.Incomplete,
        error.ReadFailed => return error.ReadFailed,
    };
    std.debug.assert(pending == '\n');
    self.body.toss(1);
    return self.line.written();
}

test "next yields the payload of each data line and skips every other line" {
    const lines = try drain(std.testing.allocator, std.testing.io, "event: message_start\r\n" ++
        "data: {\"type\":\"message_start\"}\r\n" ++
        "\r\n" ++
        ": keepalive comment\n" ++
        "data:{\"bare\":true}\n" ++
        "id: 7\n" ++
        "data:   [DONE]\n");
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqualStrings(
        "{\"type\":\"message_start\"}\n{\"bare\":true}\n[DONE]\n",
        lines,
    );
}

fn testSse(io: std.Io, body: *std.Io.Reader, options: Options) Sse {
    return .init(std.testing.allocator, io, body, options);
}

fn drain(gpa: std.mem.Allocator, io: std.Io, body: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(body);
    var sse = testSse(io, &reader, .{ .idle_ms = 60_000 });
    defer sse.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    while (try sse.next()) |payload| {
        try out.writer.print("{s}\n", .{payload});
        sse.renewIdleWindow();
    }
    return out.toOwnedSlice();
}

test "next ends at the end of the body and reads a line larger than the reader buffer" {
    const blob = "A" ** 4000;
    const body = "data: " ++ blob ++ "\ndata: tail\n";
    var buffer: [256]u8 = undefined;
    var chunked: std.testing.Reader = .init(&buffer, &.{.{ .buffer = body }});
    chunked.artificial_limit = .limited(64);
    var sse = testSse(std.testing.io, &chunked.interface, .{ .idle_ms = 60_000 });
    defer sse.deinit();

    try std.testing.expectEqualStrings(blob, (try sse.next()).?);
    try std.testing.expectEqualStrings("tail", (try sse.next()).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try sse.next());
    try std.testing.expectEqual(@as(?[]const u8, null), try sse.next());
}

test "a body cut inside a line is incomplete, never a frame" {
    var reader: std.Io.Reader = .fixed("data: {\"type\":\"response.out");
    var sse = testSse(std.testing.io, &reader, .{ .idle_ms = 60_000 });
    defer sse.deinit();
    try std.testing.expectError(error.Incomplete, sse.next());
}

test "the byte budget stops a stream once its lines pass the ceiling" {
    const frame = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"chunk\"}\n";
    const body = frame ** 5;
    var reader: std.Io.Reader = .fixed(body);
    var sse = testSse(std.testing.io, &reader, .{ .idle_ms = 60_000, .bytes_max = frame.len * 2 });
    defer sse.deinit();

    try std.testing.expect((try sse.next()) != null);
    try std.testing.expect((try sse.next()) != null);
    try std.testing.expectError(error.TooLarge, sse.next());
}

test "the byte budget counts the lines that carry no data too" {
    const frame = ": keepalive\n";
    const body = frame ** 100;
    var reader: std.Io.Reader = .fixed(body);
    var sse = testSse(std.testing.io, &reader, .{ .idle_ms = 60_000, .bytes_max = frame.len * 3 });
    defer sse.deinit();
    try std.testing.expectError(error.TooLarge, sse.next());
}

test "one line larger than the whole budget trips before it is buffered" {
    var reader: std.Io.Reader = .fixed(
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"chunk\"}\n",
    );
    var sse = testSse(std.testing.io, &reader, .{ .idle_ms = 60_000, .bytes_max = 32 });
    defer sse.deinit();
    try std.testing.expectError(error.TooLarge, sse.next());
}

test "buffered lines that make no progress draw the idle window down" {
    const body =
        ": keepalive comment\n" ++
        "data: {\"type\":\"surprise.new.event\"}\n" ++
        "data: {\"type\":\"surprise.new.event\"}\n" ++
        "data: {\"type\":\"surprise.new.event\"}\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"late\"}\n";
    var clock: core.testing.StepClock = undefined;
    clock.init(std.testing.allocator, 30);
    defer clock.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var sse = testSse(clock.io(), &reader, .{ .idle_ms = 100 });
    defer sse.deinit();

    try std.testing.expect((try sse.next()) != null);
    try std.testing.expect((try sse.next()) != null);
    try std.testing.expectError(error.Timeout, sse.next());
}

test "a renewal opens the idle window again" {
    const body =
        "data: {\"type\":\"a\"}\n" ++
        "data: {\"type\":\"b\"}\n" ++
        "data: {\"type\":\"c\"}\n" ++
        "data: {\"type\":\"d\"}\n" ++
        "data: {\"type\":\"e\"}\n" ++
        "data: {\"type\":\"f\"}\n";
    var clock: core.testing.StepClock = undefined;
    clock.init(std.testing.allocator, 30);
    defer clock.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var sse = testSse(clock.io(), &reader, .{ .idle_ms = 100 });
    defer sse.deinit();

    for (0..6) |_| {
        try std.testing.expect((try sse.next()) != null);
        sse.renewIdleWindow();
    }
}

test "a zero idle window never expires" {
    var clock: core.testing.StepClock = undefined;
    clock.init(std.testing.allocator, std.time.ms_per_hour);
    defer clock.deinit();
    var reader: std.Io.Reader = .fixed("data: a\ndata: b\ndata: c\n");
    var sse = testSse(clock.io(), &reader, .{ .idle_ms = 0 });
    defer sse.deinit();
    try std.testing.expectEqualStrings("a", (try sse.next()).?);
    try std.testing.expectEqualStrings("b", (try sse.next()).?);
    try std.testing.expectEqualStrings("c", (try sse.next()).?);
}

fn failRead(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
    return error.ReadFailed;
}

test "a failed read ends the stream as a read failure" {
    var buffer: [16]u8 = undefined;
    var reader: std.Io.Reader = .{
        .vtable = &.{ .stream = failRead },
        .buffer = &buffer,
        .seek = 0,
        .end = 0,
    };
    var sse = testSse(std.testing.io, &reader, .{ .idle_ms = 0 });
    defer sse.deinit();
    try std.testing.expectError(error.ReadFailed, sse.next());
}
