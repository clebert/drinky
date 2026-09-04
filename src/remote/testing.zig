//! The test scaffolding of the subsystem: a loopback stand-in for the Telegram
//! Bot API, the `Collector` that every task sink reports into, and the short
//! `pace` that keeps the suite fast. A test scripts the replies of each method,
//! the server answers every call with the next reply of its method, and the test
//! reads the requests back. A call to a method whose script ran out waits without
//! an answer, like a long poll that nothing wakes. No test reaches the network.

const std = @import("std");

const Attachment = @import("Attachment.zig");

/// How many steps a wait takes before it fails the test. Each step sleeps
/// `wait_step_ms`, so a stuck task fails after about five seconds.
const wait_steps_max = 500;
const wait_step_ms = 10;

/// The pace of the tests: every wait of an attachment short, so the suite stays
/// fast and the drain of a close still holds its order.
pub const pace: Attachment.Pace = .{
    .drain_ms = 300,
    .final_reserve_ms = 150,
    .send_spacing_ms = 20,
    .backoff = .{ .attempts_max = std.math.maxInt(u32), .backoff_ms_initial = 10, .backoff_ms_max = 20 },
};

/// A sink for the tests: every event lands in a list under a lock, because the
/// tasks of one owner emit concurrently. `Event` is the report of the task, and
/// `Sink` is the sink type that takes it.
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

        /// Wait until the list holds `count` events, with a bound so a stuck
        /// task fails the test.
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

/// One scripted reply.
pub const Reply = struct {
    status: u16 = 200,
    body: []const u8,
    /// The wait before the reply goes out, like a long poll that a late
    /// message wakes.
    delay_ms: u64 = 0,
};

/// The replies of one method, in the order the calls take them.
pub const Script = struct {
    method: []const u8,
    replies: []const Reply,
};

/// One received request: the path of the URL and the JSON body.
pub const Request = struct {
    path: []u8,
    body: []u8,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    listener: std.Io.net.Server,
    scripts: []const Script,
    /// How many replies of each script went out. One slot per script.
    served: []usize,
    /// The connections that wait for a reply that no script holds. The deinit
    /// closes them.
    held: std.ArrayList(std.Io.net.Stream),
    /// Every request received so far, in the order of the connections.
    requests: std.ArrayList(Request),
    /// The serve task appends to the lists above, so a reader takes the lock.
    mutex: std.Io.Mutex,
    serve_future: ?std.Io.Future(void),

    /// Listen on a loopback port. The server borrows `scripts`. Call `start`
    /// once the value is pinned.
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

    /// Start the serve task. It runs after the caller pinned the server, because
    /// the task reads the fields through the pointer.
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

    /// The origin of this server, as a client takes it.
    pub fn url(self: *const Server, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "http://127.0.0.1:{d}",
            .{self.listener.socket.address.getPort()},
        ) catch unreachable;
    }

    /// Wait until every scripted reply went out, then stop the serve task. A
    /// reply that never goes out fails the test instead of a hang.
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

    /// The number of requests received so far.
    pub fn requestCount(self: *Server) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.requests.items.len;
    }

    /// Wait until `count` requests arrived, so a test acts once the poller holds
    /// its long poll.
    pub fn waitForRequests(self: *Server, count: usize) !void {
        for (0..wait_steps_max) |_| {
            if (self.requestCount() >= count) return;
            try self.io.sleep(.fromMilliseconds(wait_step_ms), .awake);
        }
        return error.TestTimedOut;
    }

    /// How many `sendMessage` requests arrived so far.
    pub fn sendCount(self: *Server) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (std.mem.endsWith(u8, request.path, "/sendMessage")) count += 1;
        }
        return count;
    }

    /// Wait until `count` messages went out.
    pub fn waitForSends(self: *Server, count: usize) !void {
        for (0..wait_steps_max) |_| {
            if (self.sendCount() >= count) return;
            try self.io.sleep(.fromMilliseconds(wait_step_ms), .awake);
        }
        return error.TestTimedOut;
    }

    /// The bodies of every `sendMessage` request that arrived, in order.
    /// `buffer` must hold one slot per send.
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

    /// The body of the `sendMessage` request at `index`, once it arrived. The
    /// wait above proves that the send is there, and nothing drops a request.
    pub fn waitForSend(self: *Server, index: usize) ![]const u8 {
        try self.waitForSends(index + 1);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (!std.mem.endsWith(u8, request.path, "/sendMessage")) continue;
            if (count == index) return request.body;
            count += 1;
        }
        unreachable;
    }

    fn stop(self: *Server) void {
        if (self.serve_future) |*future| {
            future.cancel(self.io);
            self.serve_future = null;
        }
    }

    fn serve(self: *Server) void {
        // The accept loop ends when the test cancels it. A cancel that lands in a
        // read or a write of one connection surfaces as a stream failure, so the
        // loop reads the cause behind it. A thread that swallows its cancel
        // blocks in the next accept, beyond the reach of any signal.
        while (true) self.serveOne() catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
    }

    /// The cause behind a failed read of `reader`, so a cancel keeps its name.
    fn readFailure(reader: *const std.Io.net.Stream.Reader, err: anyerror) anyerror {
        if (err != error.ReadFailed) return err;
        return reader.err orelse err;
    }

    /// The cause behind a failed write of `writer`, so a cancel keeps its name.
    fn writeFailure(writer: *const std.Io.net.Stream.Writer, err: anyerror) anyerror {
        if (err != error.WriteFailed) return err;
        return writer.err orelse err;
    }

    /// Accept one connection, read its whole request, and answer with the next
    /// reply of its method, or hold the connection when the script ran out.
    fn serveOne(self: *Server) !void {
        const io = self.io;
        const connection = try self.listener.accept(io);
        var keep = false;
        defer if (!keep) connection.close(io);

        var read_buffer: [8192]u8 = undefined;
        var reader = connection.reader(io, &read_buffer);
        const request_line = reader.interface.takeDelimiterInclusive('\n') catch |err|
            return readFailure(&reader, err);
        const path = try self.gpa.dupe(u8, requestPath(request_line));
        errdefer self.gpa.free(path);
        var content_length: usize = 0;
        // The head of one request holds few lines, so the cap only stops a runaway.
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
        try self.requests.append(self.gpa, .{ .path = path, .body = body });
        const maybe_reply = self.nextReply(pathMethod(path));
        const reply = maybe_reply orelse {
            try self.held.append(self.gpa, connection);
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

    /// The next reply of `method`, or null when its script ran out or no script
    /// names it. The caller holds the lock.
    fn nextReply(self: *Server, method: []const u8) ?*const Reply {
        for (self.scripts, self.served) |*script, *count| {
            if (!std.mem.eql(u8, script.method, method)) continue;
            if (count.* >= script.replies.len) return null;
            count.* += 1;
            return &script.replies[count.* - 1];
        }
        return null;
    }

    /// The target of the request line `POST /bot<token>/<method> HTTP/1.1`.
    fn requestPath(request_line: []const u8) []const u8 {
        const first_blank = std.mem.indexOfScalar(u8, request_line, ' ') orelse return "";
        const rest = request_line[first_blank + 1 ..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    }

    /// The method at the end of `path`.
    fn pathMethod(path: []const u8) []const u8 {
        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[last_slash + 1 ..];
    }
};
