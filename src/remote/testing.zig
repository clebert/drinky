const std = @import("std");

const Attachment = @import("Attachment.zig");

const wait_steps_max = 500;
const wait_step_ms = 10;

pub const pace: Attachment.Pace = .{
    .drain_ms = 100,
    .send_spacing_ms = 5,
    .backoff = .{ .attempts_max = std.math.maxInt(u32), .backoff_ms_initial = 10, .backoff_ms_max = 20 },
    .outage_ms_min = 0,
};

pub const drain_half_ms = @divExact(pace.drain_ms, 2);

pub fn Collector(comptime Event: type, comptime Sink: type) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        events: std.ArrayList(Event) = .empty,
        mutex: std.Io.Mutex = .init,

        pub fn deinit(self: *@This()) void {
            for (self.events.items) |event| event.deinit(self.gpa);
            self.events.deinit(self.gpa);
        }

        pub fn sink(self: *@This()) Sink {
            return .{ .context = self, .emit = collect };
        }

        pub fn waitFor(self: *@This(), count: usize) !void {
            for (0..wait_steps_max) |_| {
                self.mutex.lockUncancelable(self.io);
                const reached = self.events.items.len >= count;
                self.mutex.unlock(self.io);
                if (reached) return;
                try self.io.sleep(.fromMilliseconds(wait_step_ms), .awake);
            }
            return error.TestTimedOut;
        }

        fn collect(context: *anyopaque, event: Event) error{Closed}!void {
            const self: *Collector(Event, Sink) = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.events.append(self.gpa, event) catch return error.Closed;
        }
    };
}

pub const Reply = struct {
    status: u16 = 200,
    body: []const u8,
    delay_ms: u64 = 0,
};

pub const Script = struct {
    method: []const u8,
    replies: []const Reply,
};

pub const Request = struct {
    path: []u8,
    body: []u8,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    listener: std.Io.net.Server,
    scripts: []const Script,
    served: []usize,
    held: std.ArrayList(std.Io.net.Stream),
    requests: std.ArrayList(Request),
    mutex: std.Io.Mutex,
    serve_future: ?std.Io.Future(void),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, scripts: []const Script) !Server {
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const served = try gpa.alloc(usize, scripts.len);
        errdefer gpa.free(served);
        @memset(served, 0);
        return .{
            .gpa = gpa,
            .io = io,
            .listener = try address.listen(io, .{ .reuse_address = true }),
            .scripts = scripts,
            .served = served,
            .held = .empty,
            .requests = .empty,
            .mutex = .init,
            .serve_future = null,
        };
    }

    pub fn start(self: *Server) !void {
        std.debug.assert(self.serve_future == null);
        self.serve_future = try self.io.concurrent(serve, .{self});
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        for (self.held.items) |stream| stream.close(self.io);
        self.held.deinit(self.gpa);
        for (self.requests.items) |request| {
            self.gpa.free(request.path);
            self.gpa.free(request.body);
        }
        self.requests.deinit(self.gpa);
        self.gpa.free(self.served);
        self.listener.deinit(self.io);
    }

    pub fn url(self: *const Server, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "http://127.0.0.1:{d}",
            .{self.listener.socket.address.getPort()},
        ) catch unreachable;
    }

    pub fn finish(self: *Server) !void {
        var total: usize = 0;
        for (self.scripts) |script| total += script.replies.len;
        for (0..wait_steps_max) |_| {
            self.mutex.lockUncancelable(self.io);
            var consumed: usize = 0;
            for (self.served) |count| consumed += count;
            self.mutex.unlock(self.io);
            if (consumed == total) {
                self.stop();
                return;
            }
            try self.io.sleep(.fromMilliseconds(wait_step_ms), .awake);
        }
        return error.TestTimedOut;
    }

    pub fn waitForLongPoll(self: *Server) !void {
        _ = try self.waitForRequest("/getUpdates", 1);
    }

    pub fn sendCount(self: *Server) usize {
        return self.countOf("/sendMessage");
    }

    pub fn countOf(self: *Server, path_suffix: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (std.mem.endsWith(u8, request.path, path_suffix)) count += 1;
        }
        return count;
    }

    pub fn waitForRequest(self: *Server, path_suffix: []const u8, index: usize) ![]const u8 {
        for (0..wait_steps_max) |_| {
            if (self.countOf(path_suffix) > index) break;
            try self.io.sleep(.fromMilliseconds(wait_step_ms), .awake);
        } else return error.TestTimedOut;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (!std.mem.endsWith(u8, request.path, path_suffix)) continue;
            if (count == index) return request.body;
            count += 1;
        }
        unreachable;
    }

    pub fn waitForSends(self: *Server, count: usize) !void {
        for (0..wait_steps_max) |_| {
            if (self.sendCount() >= count) return;
            try self.io.sleep(.fromMilliseconds(wait_step_ms), .awake);
        }
        return error.TestTimedOut;
    }

    pub fn sentBodies(self: *Server, buffer: [][]const u8) [][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (!std.mem.endsWith(u8, request.path, "/sendMessage")) continue;
            std.debug.assert(count < buffer.len);
            buffer[count] = request.body;
            count += 1;
        }
        return buffer[0..count];
    }

    pub fn waitForSend(self: *Server, index: usize) ![]const u8 {
        return self.waitForRequest("/sendMessage", index);
    }

    fn stop(self: *Server) void {
        if (self.serve_future) |*future| {
            future.cancel(self.io);
            self.serve_future = null;
        }
    }

    fn serve(self: *Server) void {
        while (true) self.serveOne() catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
    }

    fn readFailure(reader: *const std.Io.net.Stream.Reader, err: anyerror) anyerror {
        if (err != error.ReadFailed) return err;
        return reader.err orelse err;
    }

    fn writeFailure(writer: *const std.Io.net.Stream.Writer, err: anyerror) anyerror {
        if (err != error.WriteFailed) return err;
        return writer.err orelse err;
    }

    fn serveOne(self: *Server) !void {
        const io = self.io;
        const connection = try self.listener.accept(io);
        var keep = false;
        defer if (!keep) connection.close(io);

        const reply = try self.takeRequest(connection) orelse {
            keep = true;
            return;
        };
        if (reply.delay_ms > 0) try io.sleep(.fromMilliseconds(@intCast(reply.delay_ms)), .awake);
        var write_buffer: [512]u8 = undefined;
        var writer = connection.writer(io, &write_buffer);
        writer.interface.print(
            "HTTP/1.1 {d} X\r\ncontent-type: application/json\r\n" ++
                "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
            .{ reply.status, reply.body.len, reply.body },
        ) catch |err| return writeFailure(&writer, err);
        writer.interface.flush() catch |err| return writeFailure(&writer, err);
    }

    fn takeRequest(self: *Server, connection: std.Io.net.Stream) !?*const Reply {
        const io = self.io;
        var read_buffer: [8192]u8 = undefined;
        var reader = connection.reader(io, &read_buffer);
        const request_line = reader.interface.takeDelimiterInclusive('\n') catch |err|
            return readFailure(&reader, err);
        const path = try self.gpa.dupe(u8, requestPath(request_line));
        errdefer self.gpa.free(path);
        var content_length: usize = 0;
        var lines_left: usize = 64;
        while (lines_left > 0) : (lines_left -= 1) {
            const raw = reader.interface.takeDelimiterInclusive('\n') catch |err|
                return readFailure(&reader, err);
            const line = std.mem.trimEnd(u8, raw, "\r\n");
            if (line.len == 0) break;
            const label = "content-length:";
            if (std.ascii.startsWithIgnoreCase(line, label)) {
                const value = std.mem.trim(u8, line[label.len..], " \t");
                content_length = try std.fmt.parseInt(usize, value, 10);
            }
        }
        const body = try self.gpa.alloc(u8, content_length);
        errdefer self.gpa.free(body);
        reader.interface.readSliceAll(body) catch |err| return readFailure(&reader, err);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.held.ensureUnusedCapacity(self.gpa, 1);
        try self.requests.append(self.gpa, .{ .path = path, .body = body });
        const reply = self.nextReply(pathMethod(path)) orelse {
            self.held.appendAssumeCapacity(connection);
            return null;
        };
        return reply;
    }

    fn nextReply(self: *Server, method: []const u8) ?*const Reply {
        for (self.scripts, self.served) |*script, *count| {
            if (!std.mem.eql(u8, script.method, method)) continue;
            if (count.* >= script.replies.len) return null;
            count.* += 1;
            return &script.replies[count.* - 1];
        }
        return null;
    }

    fn requestPath(request_line: []const u8) []const u8 {
        const first_blank = std.mem.indexOfScalar(u8, request_line, ' ') orelse return "";
        const rest = request_line[first_blank + 1 ..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    }

    fn pathMethod(path: []const u8) []const u8 {
        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[last_slash + 1 ..];
    }
};
