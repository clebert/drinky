const std = @import("std");

const core = @import("core");

const testing = @import("testing.zig");

const CostPipe = @This();

reader: std.Io.File,
writer: ?std.Io.File,

pub const environment = "DRINKY_COST_FD";

const header = "drinky\x00\x01";
const record_bytes = header.len + @sizeOf(f64);
const system_attempts_max = 64;
const bytes_available_request: u32 = if (@hasDecl(std.posix.T, "FIONREAD"))
    std.posix.T.FIONREAD
else
    0x4004667f;

pub const Error = error{ InvalidCostReport, CostReportUnavailable };

pub const Writer = struct {
    file: std.Io.File,

    pub fn fromEnvironment(io: std.Io, value: []const u8) Error!Writer {
        const handle = std.fmt.parseInt(std.posix.fd_t, value, 10) catch
            return error.InvalidCostReport;
        if (handle <= std.posix.STDERR_FILENO) return error.InvalidCostReport;
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        const stat = file.stat(io) catch return error.CostReportUnavailable;
        if (stat.kind != .named_pipe) return error.InvalidCostReport;
        setFlags(handle, .{ .command = std.posix.F.SETFD, .flags = std.posix.FD_CLOEXEC }) catch
            return error.CostReportUnavailable;
        nonblocking(handle) catch return error.CostReportUnavailable;
        return .{ .file = file };
    }

    pub fn send(self: Writer, amount: f64) Error!void {
        if (!valid(amount)) return error.InvalidCostReport;
        var record: [record_bytes]u8 = undefined;
        @memcpy(record[0..header.len], header);
        std.mem.writeInt(u64, record[header.len..], @bitCast(amount), .little);
        for (0..system_attempts_max) |_| {
            const result = std.posix.system.write(self.file.handle, &record, record.len);
            switch (std.posix.errno(result)) {
                .SUCCESS => {
                    if (result != record.len) return error.CostReportUnavailable;
                    return;
                },
                .INTR => continue,
                else => return error.CostReportUnavailable,
            }
        }
        return error.CostReportUnavailable;
    }
};

pub const Decoder = struct {
    sink: core.Runner.Sink,
    buffer: [record_bytes]u8 = undefined,
    length: usize = 0,

    pub fn feed(self: *Decoder, io: std.Io, data: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < data.len) {
            const count = @min(data.len - offset, record_bytes - self.length);
            @memcpy(self.buffer[self.length..][0..count], data[offset..][0..count]);
            self.length += count;
            offset += count;
            if (self.length != record_bytes) continue;
            self.length = 0;
            if (!std.mem.eql(u8, self.buffer[0..header.len], header))
                return error.InvalidCostReport;
            const amount: f64 = @bitCast(std.mem.readInt(u64, self.buffer[header.len..], .little));
            if (!valid(amount)) return error.InvalidCostReport;
            self.sink.emit(io, &.{ .cost = amount });
        }
    }

    pub fn finish(self: *const Decoder) Error!void {
        if (self.length != 0) return error.InvalidCostReport;
    }
};

pub fn init() std.Io.Threaded.PipeError!CostPipe {
    const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    return .{
        .reader = .{ .handle = handles[0], .flags = .{ .nonblocking = false } },
        .writer = .{ .handle = handles[1], .flags = .{ .nonblocking = false } },
    };
}

pub fn closeWriter(self: *CostPipe, io: std.Io) void {
    if (self.writer) |file| file.close(io);
    self.writer = null;
}

pub fn deinit(self: *CostPipe, io: std.Io) void {
    self.closeWriter(io);
    self.reader.close(io);
}

pub fn inherit(handle: std.posix.fd_t) error{ SystemResources, Unexpected }!void {
    try setFlags(handle, .{ .command = std.posix.F.SETFD, .flags = 0 });
}

pub fn collect(
    self: *CostPipe,
    io: std.Io,
    decoder: *Decoder,
) (std.Io.File.ReadStreamingError || Error)!void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = self.reader.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => return decoder.finish(),
            else => |known| return known,
        };
        try decoder.feed(io, buffer[0..count]);
    }
}

pub fn drain(self: *CostPipe, io: std.Io, decoder: *Decoder) Error!void {
    nonblocking(self.reader.handle) catch return error.CostReportUnavailable;
    var remaining = try queuedBytes(self.reader.handle);
    var interrupted: usize = 0;
    var buffer: [4096]u8 = undefined;
    while (remaining > 0) {
        const result = std.posix.system.read(
            self.reader.handle,
            &buffer,
            @min(buffer.len, remaining),
        );
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.CostReportUnavailable;
                const count: usize = @intCast(result);
                remaining -= count;
                interrupted = 0;
                try decoder.feed(io, buffer[0..count]);
            },
            .INTR => {
                interrupted += 1;
                if (interrupted == system_attempts_max) return error.CostReportUnavailable;
            },
            else => return error.CostReportUnavailable,
        }
    }
}

fn queuedBytes(handle: std.posix.fd_t) Error!usize {
    var count: c_int = 0;
    for (0..system_attempts_max) |_| {
        const result = std.posix.system.ioctl(handle, bytes_available_request, @intFromPtr(&count));
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (count < 0) return error.CostReportUnavailable;
                return @intCast(count);
            },
            .INTR => continue,
            else => return error.CostReportUnavailable,
        }
    }
    return error.CostReportUnavailable;
}

fn valid(amount: f64) bool {
    return std.math.isFinite(amount) and amount >= 0 and amount <= core.Provider.amount_usd_max;
}

fn nonblocking(handle: std.posix.fd_t) error{ SystemResources, Unexpected }!void {
    const flags: std.posix.O = .{ .NONBLOCK = true };
    try setFlags(handle, .{ .command = std.posix.F.SETFL, .flags = @bitCast(flags) });
}

fn setFlags(
    handle: std.posix.fd_t,
    options: struct { command: i32, flags: u32 },
) error{ SystemResources, Unexpected }!void {
    for (0..system_attempts_max) |_| {
        const result = std.posix.system.fcntl(handle, options.command, options.flags);
        switch (std.posix.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    return error.SystemResources;
}

test "the cost pipe keeps charges separate from text and decodes split records" {
    const io = std.testing.io;
    var pipe = try init();
    defer pipe.deinit(io);
    var handle_buffer: [32]u8 = undefined;
    const value = try std.mem.print(&handle_buffer, "{d}", .{pipe.writer.?.handle});
    const writer = try Writer.fromEnvironment(io, value);
    try writer.send(0.42);
    try writer.send(1.5);
    pipe.closeWriter(io);

    var costs: testing.Costs = .{};
    defer costs.deinit();
    var decoder: Decoder = .{ .sink = costs.sink() };
    var buffer: [3]u8 = undefined;
    while (true) {
        const count = pipe.reader.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try decoder.feed(io, buffer[0..count]);
    }
    try decoder.finish();
    try costs.expect(&.{ 0.42, 1.5 });
}

test "a full or closed cost pipe fails without a wait" {
    const io = std.testing.io;
    var pipe = try init();
    defer pipe.deinit(io);
    var handle_buffer: [32]u8 = undefined;
    const value = try std.mem.print(&handle_buffer, "{d}", .{pipe.writer.?.handle});
    const writer = try Writer.fromEnvironment(io, value);
    var full = false;
    for (0..65_536) |_| {
        writer.send(1) catch |err| {
            try std.testing.expectEqual(error.CostReportUnavailable, err);
            full = true;
            break;
        };
    }
    try std.testing.expect(full);
    var decoder: Decoder = .{ .sink = testing.discard_sink };
    try pipe.drain(io, &decoder);
    try decoder.finish();
    try writer.send(2);
    pipe.closeWriter(io);
    try std.testing.expectError(error.CostReportUnavailable, writer.send(3));
}

test "a drain reports an invalid queued record" {
    const io = std.testing.io;
    var pipe = try init();
    defer pipe.deinit(io);
    try pipe.writer.?.writeStreamingAll(io, "malformed record");
    var decoder: Decoder = .{ .sink = testing.discard_sink };
    const result: Error!void = pipe.drain(io, &decoder);
    try std.testing.expectError(error.InvalidCostReport, result);
}

test "a drain leaves reports that arrive after its queued-byte snapshot" {
    const io = std.testing.io;
    var pipe = try init();
    defer pipe.deinit(io);
    var handle_buffer: [32]u8 = undefined;
    const value = try std.mem.print(&handle_buffer, "{d}", .{pipe.writer.?.handle});
    const writer = try Writer.fromEnvironment(io, value);
    try writer.send(1);
    var replenishing: Replenishing = .{ .writer = writer };
    var decoder: Decoder = .{ .sink = replenishing.sink() };
    try pipe.drain(io, &decoder);
    try decoder.finish();
    try std.testing.expectEqual(@as(usize, 1), replenishing.count);
}

const Replenishing = struct {
    writer: Writer,
    count: usize = 0,

    const vtable: core.Runner.Sink.VTable = .{ .emit = emit };

    fn sink(self: *Replenishing) core.Runner.Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn emit(ptr: *anyopaque, _: *const core.Runner.Event) void {
        const self: *Replenishing = @ptrCast(@alignCast(ptr));
        self.count += 1;
        if (self.count < 16) self.writer.send(1) catch unreachable;
    }
};

test "a cost descriptor cannot name a regular file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "report", .{});
    defer file.close(io);
    var handle_buffer: [32]u8 = undefined;
    const value = try std.mem.print(&handle_buffer, "{d}", .{file.handle});
    try std.testing.expectError(error.InvalidCostReport, Writer.fromEnvironment(io, value));
}

test "the cost pipe rejects invalid charges, descriptors, records, and incomplete records" {
    const io = std.testing.io;
    var pipe = try init();
    defer pipe.deinit(io);
    var handle_buffer: [32]u8 = undefined;
    const value = try std.mem.print(&handle_buffer, "{d}", .{pipe.writer.?.handle});
    const writer = try Writer.fromEnvironment(io, value);
    const invalid_amounts = [_]f64{
        -1, std.math.nan(f64), std.math.inf(f64), core.Provider.amount_usd_max + 1,
    };
    for (invalid_amounts) |amount| {
        try std.testing.expectError(error.InvalidCostReport, writer.send(amount));
        var record: [record_bytes]u8 = undefined;
        @memcpy(record[0..header.len], header);
        std.mem.writeInt(u64, record[header.len..], @bitCast(amount), .little);
        var decoder: Decoder = .{ .sink = testing.discard_sink };
        try std.testing.expectError(error.InvalidCostReport, decoder.feed(io, &record));
    }
    for ([_][]const u8{ "", "-1", "2", "text" }) |invalid| {
        try std.testing.expectError(error.InvalidCostReport, Writer.fromEnvironment(io, invalid));
    }
    var decoder: Decoder = .{ .sink = testing.discard_sink };
    try decoder.feed(io, "partial");
    try std.testing.expectError(error.InvalidCostReport, decoder.finish());
    try std.testing.expectError(error.InvalidCostReport, decoder.feed(io, "malformed record"));
}
