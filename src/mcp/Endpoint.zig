const std = @import("std");
const application = @import("application");
const catalog = @import("catalog.zig");
const discovery = @import("discovery.zig");
const protocol = @import("protocol.zig");

const Endpoint = @This();

const connections_max = 4;
const read_timeout_ms = 1000;
const reply_timeout_ms = 5000;
const write_timeout_ms = 1000;
const accept_retry_ms = 100;

gpa: std.mem.Allocator,
io: std.Io,
directory: []const u8,
host: Host,
generation: u64 = 0,
publication: ?Publication = null,

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const PostError = std.Io.QueueClosedError || error{Full};
    pub const VTable = struct {
        post: *const fn (ptr: *anyopaque, request: *Request) PostError!void,
    };

    pub fn post(self: Host, request: *Request) PostError!void {
        return self.vtable.post(self.ptr, request);
    }
};

pub const Request = struct {
    line: []u8,
    generation: u64,
    mutex: std.Io.Mutex = .init,
    phase: Phase = .queued,
    owners: u8 = 2,
    delivered: std.Io.Event = .unset,

    const Phase = union(enum) { queued, claimed, delivered: []u8, abandoned, answered };

    pub fn deliver(self: *Request, gpa: std.mem.Allocator, io: std.Io, reply: []u8) void {
        self.mutex.lockUncancelable(io);
        const claimed = self.phase == .claimed;
        if (claimed) self.phase = .{ .delivered = reply };
        self.mutex.unlock(io);
        if (!claimed) return gpa.free(reply);
        self.delivered.set(io);
    }

    pub fn release(self: *Request, gpa: std.mem.Allocator, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.owners -= 1;
        const last = self.owners == 0;
        self.mutex.unlock(io);
        if (!last) return;
        gpa.free(self.line);
        switch (self.phase) {
            .delivered => |reply| gpa.free(reply),
            .queued, .claimed, .abandoned, .answered => {},
        }
        gpa.destroy(self);
    }

    fn claim(self: *Request, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.phase != .queued) return false;
        self.phase = .claimed;
        return true;
    }

    fn abandon(self: *Request, io: std.Io) ?Abandoned {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const abandoned: Abandoned = switch (self.phase) {
            .queued => .unclaimed,
            .claimed => .claimed,
            .delivered => return null,
            .abandoned, .answered => unreachable,
        };
        self.phase = .abandoned;
        return abandoned;
    }

    fn takeReply(self: *Request, io: std.Io) []u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const reply = switch (self.phase) {
            .delivered => |reply| reply,
            .queued, .claimed, .abandoned, .answered => unreachable,
        };
        self.phase = .answered;
        return reply;
    }

    fn waitDelivered(self: *Request, io: std.Io) std.Io.Cancelable!void {
        try self.delivered.wait(io);
    }
};

const Abandoned = enum { unclaimed, claimed };
const Session = struct { generation: u64, instance: discovery.Id };

const Publication = struct {
    entry: discovery.Publication,
    server: std.Io.net.Server,
    futures: [connections_max]?std.Io.Future(void),
};

pub const EnableError = discovery.PublishError || std.Io.net.UnixAddress.ListenError ||
    std.Io.ConcurrentError;

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    host: Host,
) Endpoint {
    return .{ .gpa = gpa, .io = io, .directory = directory, .host = host };
}

pub fn deinit(self: *Endpoint) void {
    self.disable() catch {};
}

pub fn published(self: *const Endpoint) ?discovery.Id {
    const publication = if (self.publication) |*publication| publication else return null;
    return publication.entry.id;
}

pub fn enable(self: *Endpoint) EnableError!discovery.Id {
    std.debug.assert(self.publication == null);
    var entry = try discovery.publish(self.io, self.directory);
    errdefer discovery.withdraw(self.io, &entry) catch {};
    const address = std.Io.net.UnixAddress.init(entry.socketPath()) catch unreachable;
    const server = try address.listen(self.io, .{});
    self.generation += 1;
    self.publication = .{ .entry = entry, .server = server, .futures = @splat(null) };
    const publication = &self.publication.?;
    errdefer _ = self.stop();
    for (&publication.futures) |*future| future.* = try self.io.concurrent(serve, .{
        self,
        &publication.server,
        Session{ .generation = self.generation, .instance = entry.id },
    });
    return entry.id;
}

pub fn disable(self: *Endpoint) std.Io.Dir.DeleteFileError!void {
    if (self.publication == null) return;
    var entry = self.stop();
    try discovery.withdraw(self.io, &entry);
}

pub fn admit(self: *const Endpoint, request: *Request) bool {
    if (self.publication == null or request.generation != self.generation) return false;
    return request.claim(self.io);
}

fn stop(self: *Endpoint) discovery.Publication {
    const publication = &self.publication.?;
    for (&publication.futures) |*maybe_future| {
        if (maybe_future.*) |*future| future.cancel(self.io);
        maybe_future.* = null;
    }
    publication.server.deinit(self.io);
    const entry = publication.entry;
    self.publication = null;
    return entry;
}

fn serve(self: *Endpoint, server: *std.Io.net.Server, session: Session) void {
    while (true) {
        const stream = server.accept(self.io) catch |err| switch (err) {
            error.Canceled => return,
            error.ConnectionAborted => continue,
            else => {
                self.io.sleep(.fromMilliseconds(accept_retry_ms), .awake) catch return;
                continue;
            },
        };
        defer stream.close(self.io);
        self.answer(stream, &session) catch |err| switch (err) {
            error.Canceled => return,
            error.OutOfMemory => application.support.outOfMemory(),
        };
    }
}

fn answer(
    self: *Endpoint,
    stream: std.Io.net.Stream,
    session: *const Session,
) error{ Canceled, OutOfMemory }!void {
    const line = application.support.timeout(
        self.io,
        read_timeout_ms,
        protocol.readLine,
        .{ self.gpa, self.io, stream },
        freeLine,
    ) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => |known| return known,
        error.StreamTooLong => return self.refuse(stream, session, &.{
            .kind = .invalid_request,
            .message = "The request exceeds the size limit.",
        }),
        else => return,
    };
    const request = self.gpa.create(Request) catch |err| {
        self.gpa.free(line);
        return err;
    };
    request.* = .{ .line = line, .generation = session.generation };
    self.host.post(request) catch |err| {
        request.owners = 1;
        request.release(self.gpa, self.io);
        return self.refuse(stream, session, &switch (err) {
            error.Full => catalog.Failure{
                .kind = .busy,
                .message = "The instance has too much pending work. Nothing ran.",
            },
            error.Closed => catalog.Failure{
                .kind = .not_accepted,
                .message = "The instance is closing. Nothing ran.",
            },
        });
    };
    defer request.release(self.gpa, self.io);
    const waited = application.support.timeout(
        self.io,
        reply_timeout_ms,
        Request.waitDelivered,
        .{ request, self.io },
        null,
    );
    waited catch |err| switch (err) {
        error.Canceled => {
            _ = request.abandon(self.io);
            return error.Canceled;
        },
        error.Timeout, error.ConcurrencyUnavailable => {
            const abandoned = request.abandon(self.io) orelse return self.send(stream, request);
            return self.refuse(stream, session, &switch (abandoned) {
                .unclaimed => catalog.Failure{
                    .kind = .not_accepted,
                    .message = "The instance did not take the request in time. Nothing ran.",
                },
                .claimed => catalog.Failure{
                    .kind = .unknown_outcome,
                    .message = "The instance did not answer in time. The request can have run.",
                },
            });
        },
    };
    try self.send(stream, request);
}

fn send(self: *Endpoint, stream: std.Io.net.Stream, request: *Request) error{Canceled}!void {
    const reply = request.takeReply(self.io);
    defer self.gpa.free(reply);
    try self.write(stream, reply);
}

fn refuse(
    self: *Endpoint,
    stream: std.Io.net.Stream,
    session: *const Session,
    reason: *const catalog.Failure,
) error{ Canceled, OutOfMemory }!void {
    const reply = try catalog.failure(self.gpa, &session.instance, reason);
    defer self.gpa.free(reply);
    try self.write(stream, reply);
}

fn write(self: *Endpoint, stream: std.Io.net.Stream, line: []const u8) error{Canceled}!void {
    application.support.timeout(
        self.io,
        write_timeout_ms,
        protocol.writeLine,
        .{ self.io, stream, line },
        null,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Timeout, error.ConcurrencyUnavailable, error.WriteFailed => {},
    };
}

fn freeLine(
    line: *const []u8,
    args: *const struct { std.mem.Allocator, std.Io, std.Io.net.Stream },
) void {
    args[0].free(line.*);
}

test "a published endpoint answers through the host and its withdrawal removes the entry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const socket = try rig.enable();
    var client = try io.concurrent(Rig.ask, .{ socket, "{\"question\":1}" });
    const request = try rig.take();
    defer request.release(gpa, io);
    try std.testing.expectEqualStrings("{\"question\":1}", request.line);
    try std.testing.expect(rig.endpoint.admit(request));
    request.deliver(gpa, io, try gpa.dupe(u8, "{\"answer\":1}"));
    const reply = try client.await(io);
    defer gpa.free(reply.reply);
    try std.testing.expectEqualStrings("{\"answer\":1}", reply.reply);
    try rig.endpoint.disable();
    try std.testing.expect(rig.endpoint.published() == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, socket, .{}));
}

const Rig = struct {
    tmp: std.testing.TmpDir,
    path_buffer: [128]u8,
    socket_buffer: [discovery.path_bytes_max]u8,
    queue: std.Io.Queue(*Request),
    queue_buffer: [connections_max]*Request,
    endpoint: Endpoint,

    const vtable: Host.VTable = .{ .post = post };

    fn init(self: *Rig) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.queue = .init(&self.queue_buffer);
        const path = try accounts.testing.tmpPath(&self.path_buffer, &self.tmp, "mcp");
        self.endpoint = .init(std.testing.allocator, std.testing.io, path, .{
            .ptr = self,
            .vtable = &vtable,
        });
    }

    fn deinit(self: *Rig) void {
        self.endpoint.deinit();
        self.queue.close(std.testing.io);
        var left: [connections_max]*Request = undefined;
        const count = self.queue.get(std.testing.io, &left, 0) catch 0;
        for (left[0..count]) |request| request.release(std.testing.allocator, std.testing.io);
        self.tmp.cleanup();
    }

    fn enable(self: *Rig) ![]const u8 {
        const id = try self.endpoint.enable();
        return discovery.socketPath(&self.socket_buffer, self.endpoint.directory, &id);
    }

    fn post(ptr: *anyopaque, request: *Request) Host.PostError!void {
        const self: *Rig = @ptrCast(@alignCast(ptr));
        const count = try self.queue.putUncancelable(std.testing.io, &.{request}, 0);
        if (count == 0) return error.Full;
    }

    fn take(self: *Rig) !*Request {
        return application.support.timeout(std.testing.io, 5000, takeRequest, .{self}, null);
    }

    fn takeRequest(self: *Rig) (std.Io.QueueClosedError || std.Io.Cancelable)!*Request {
        return self.queue.getOne(std.testing.io);
    }

    fn ask(socket: []const u8, line: []const u8) !protocol.Exchange {
        return protocol.exchange(std.testing.allocator, std.testing.io, &.{
            .path = socket,
            .request = line,
            .timeout_ms = 5000,
        });
    }
};

test "a request that waits across a disable and an enable is never admitted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const socket = try rig.enable();
    var client = try io.concurrent(Rig.ask, .{ socket, "{}" });
    const request = try rig.take();
    defer request.release(gpa, io);
    try rig.endpoint.disable();
    try std.testing.expect(try client.await(io) == .unanswered);
    _ = try rig.enable();
    try std.testing.expect(!rig.endpoint.admit(request));
}

test "an idle client blocks neither another client nor the end of access" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const socket = try rig.enable();
    const address = try std.Io.net.UnixAddress.init(socket);
    const idle = try address.connect(io);
    defer idle.close(io);
    var client = try io.concurrent(Rig.ask, .{ socket, "{}" });
    const request = try rig.take();
    defer request.release(gpa, io);
    try std.testing.expect(rig.endpoint.admit(request));
    request.deliver(gpa, io, try gpa.dupe(u8, "{}"));
    const reply = try client.await(io);
    gpa.free(reply.reply);
    try rig.endpoint.disable();
}

test "an abandoned request never runs, and a reply after the abandon is freed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.enable();
    const Case = struct { claim: bool, deliver: bool, abandoned: ?Abandoned };
    for ([_]Case{
        .{ .claim = false, .deliver = false, .abandoned = .unclaimed },
        .{ .claim = true, .deliver = false, .abandoned = .claimed },
        .{ .claim = true, .deliver = true, .abandoned = null },
    }) |case| {
        const request = try gpa.create(Request);
        request.* = .{ .line = try gpa.dupe(u8, "{}"), .generation = rig.endpoint.generation };
        defer request.release(gpa, io);
        defer request.release(gpa, io);
        if (case.claim) try std.testing.expect(rig.endpoint.admit(request));
        if (case.deliver) request.deliver(gpa, io, try gpa.dupe(u8, "{}"));
        try std.testing.expectEqual(case.abandoned, request.abandon(io));
        try std.testing.expect(!rig.endpoint.admit(request));
        if (!case.deliver) request.deliver(gpa, io, try gpa.dupe(u8, "{}"));
        try std.testing.expectEqual(case.deliver, request.phase == .delivered);
    }
}

const accounts = @import("accounts");
