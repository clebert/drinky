const std = @import("std");
const application = @import("application");

pub const version = 1;
pub const line_bytes_max = 1 << 20;
const connect_timeout_ms = 1000;
const stream_buffer_bytes = 4096;

pub const TakeLineError = error{ OutOfMemory, ReadFailed, StreamTooLong };

pub const Exchange = union(enum) {
    reply: []u8,
    unsent: []const u8,
    unanswered: []const u8,
};

pub fn takeLine(gpa: std.mem.Allocator, reader: *std.Io.Reader) TakeLineError!?[]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    _ = reader.streamDelimiterLimit(&line.writer, '\n', .limited(line_bytes_max)) catch |err|
        switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed, error.StreamTooLong => |other| return other,
        };
    const terminated = if (reader.takeByte()) |_| true else |err| switch (err) {
        error.EndOfStream => false,
        error.ReadFailed => return error.ReadFailed,
    };
    if (!terminated and line.written().len == 0) return null;
    return try line.toOwnedSlice();
}

pub fn writeLine(
    io: std.Io,
    stream: std.Io.net.Stream,
    line: []const u8,
) std.Io.Writer.Error!void {
    var buffer: [stream_buffer_bytes]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(line);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

pub fn readLine(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
) (TakeLineError || error{EndOfStream})![]u8 {
    var buffer: [stream_buffer_bytes]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    return try takeLine(gpa, &reader.interface) orelse error.EndOfStream;
}

pub fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const struct { path: []const u8, request: []const u8, timeout_ms: u64 },
) error{ OutOfMemory, Canceled }!Exchange {
    const address = std.Io.net.UnixAddress.init(options.path) catch |err|
        return .{ .unsent = @errorName(err) };
    const stream = application.support.timeout(
        io,
        connect_timeout_ms,
        connect,
        .{ &address, io },
        closeStream,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |other| return .{ .unsent = @errorName(other) },
    };
    defer stream.close(io);
    const reply = application.support.timeout(
        io,
        options.timeout_ms,
        converse,
        .{ gpa, io, stream, options.request },
        freeReply,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |known| return known,
        error.ConcurrencyUnavailable => |unstarted| return .{ .unsent = @errorName(unstarted) },
        else => |other| return .{ .unanswered = @errorName(other) },
    };
    return .{ .reply = reply };
}

pub fn field(
    json: *std.json.Stringify,
    comptime name: []const u8,
    value: anytype,
) std.json.Stringify.Error!void {
    try json.objectField(name);
    try json.write(value);
}

pub fn writeRaw(json: *std.json.Stringify, raw: []const u8) std.json.Stringify.Error!void {
    try json.beginWriteRaw();
    try json.writer.writeAll(raw);
    json.endWriteRaw();
}

fn connect(
    address: *const std.Io.net.UnixAddress,
    io: std.Io,
) std.Io.net.UnixAddress.ConnectError!std.Io.net.Stream {
    return address.connect(io);
}

fn closeStream(
    stream: *const std.Io.net.Stream,
    args: *const struct { *const std.Io.net.UnixAddress, std.Io },
) void {
    stream.close(args[1]);
}

fn converse(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    request: []const u8,
) (std.Io.Writer.Error || TakeLineError || error{EndOfStream})![]u8 {
    try writeLine(io, stream, request);
    return readLine(gpa, io, stream);
}

fn freeReply(
    reply: *const []u8,
    args: *const struct { std.mem.Allocator, std.Io, std.Io.net.Stream, []const u8 },
) void {
    args[0].free(reply.*);
}

test "a line reader returns each line, the unterminated tail, and the end of the input" {
    const gpa = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("first\n\nlast");
    for ([_][]const u8{ "first", "", "last" }) |expected| {
        const line = (try takeLine(gpa, &reader)).?;
        defer gpa.free(line);
        try std.testing.expectEqualStrings(expected, line);
    }
    try std.testing.expect(try takeLine(gpa, &reader) == null);
}

test "a line over the size limit fails without an allocation leak" {
    const gpa = std.testing.allocator;
    const long = try gpa.alloc(u8, line_bytes_max + 1);
    defer gpa.free(long);
    @memset(long, 'x');
    var reader: std.Io.Reader = .fixed(long);
    try std.testing.expectError(error.StreamTooLong, takeLine(gpa, &reader));
}
