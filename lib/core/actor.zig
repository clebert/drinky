const std = @import("std");

pub fn Sink(comptime Event: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const Self = @This();

        pub const VTable = struct {
            emit: *const fn (ptr: *anyopaque, event: *const Event) void,
        };

        pub fn emit(self: Self, io: std.Io, event: *const Event) void {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            self.vtable.emit(self.ptr, event);
        }
    };
}

pub fn Mailbox(comptime Mail: type, comptime capacity: usize) type {
    return struct {
        mutex: std.Io.Mutex,
        buffer: [capacity + 1]Mail,
        head: usize,
        count: usize,
        closed: bool,
        arrivals: std.atomic.Value(u32),
        departures: std.atomic.Value(u32),
        child: ?std.Io.Future(void),

        const Self = @This();

        pub const Error = error{Closed} || std.Io.Cancelable;

        const Wait = enum { cancelable, uncancelable };

        pub const init: Self = .{
            .mutex = .init,
            .buffer = undefined,
            .head = 0,
            .count = 0,
            .closed = false,
            .arrivals = .init(0),
            .departures = .init(0),
            .child = null,
        };

        pub fn send(self: *Self, io: std.Io, mail: Mail) error{Closed}!void {
            self.put(io, mail, .uncancelable) catch |err| return switch (err) {
                error.Closed => error.Closed,
                error.Canceled => unreachable,
            };
        }

        pub fn post(self: *Self, io: std.Io, mail: Mail) Error!void {
            return self.put(io, mail, .cancelable);
        }

        pub fn receive(self: *Self, io: std.Io) Error!Mail {
            while (true) {
                self.mutex.lockUncancelable(io);
                if (self.count > 0) {
                    const mail = self.pop();
                    self.mutex.unlock(io);
                    io.futexWake(u32, &self.departures.raw, std.math.maxInt(u32));
                    return mail;
                }
                if (self.closed) {
                    self.mutex.unlock(io);
                    return error.Closed;
                }
                const seen = self.arrivals.load(.acquire);
                self.mutex.unlock(io);
                try io.futexWait(u32, &self.arrivals.raw, seen);
            }
        }

        pub fn close(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            self.closed = true;
            _ = self.arrivals.fetchAdd(1, .release);
            _ = self.departures.fetchAdd(1, .release);
            self.mutex.unlock(io);
            io.futexWake(u32, &self.arrivals.raw, std.math.maxInt(u32));
            io.futexWake(u32, &self.departures.raw, std.math.maxInt(u32));
        }

        pub fn drain(self: *Self, io: std.Io, gpa: std.mem.Allocator) void {
            for (0..self.buffer.len) |_| {
                self.mutex.lockUncancelable(io);
                const maybe_mail = if (self.count > 0) self.pop() else null;
                self.mutex.unlock(io);
                const mail = maybe_mail orelse return;
                mail.deinit(gpa);
            }
        }

        pub fn start(
            self: *Self,
            io: std.Io,
            comptime function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) std.Io.ConcurrentError!void {
            std.debug.assert(self.child == null);
            const Child = struct {
                fn run(mailbox: *Self, child_io: std.Io, child_args: @TypeOf(args)) void {
                    const mail: Mail = @call(.auto, function, child_args);
                    mailbox.end(child_io, mail);
                }
            };
            self.child = try io.concurrent(Child.run, .{ self, io, args });
        }

        pub fn busy(self: *const Self) bool {
            return self.child != null;
        }

        pub fn cancel(self: *Self, io: std.Io) void {
            if (self.child) |*child| child.cancel(io);
        }

        pub fn reap(self: *Self, io: std.Io) void {
            if (self.child) |*child| child.await(io);
            self.child = null;
        }

        fn put(self: *Self, io: std.Io, mail: Mail, wait: Wait) Error!void {
            while (true) {
                self.mutex.lockUncancelable(io);
                if (self.closed) {
                    self.mutex.unlock(io);
                    return error.Closed;
                }
                if (self.count < capacity) {
                    self.push(mail);
                    self.mutex.unlock(io);
                    io.futexWake(u32, &self.arrivals.raw, 1);
                    return;
                }
                const seen = self.departures.load(.acquire);
                self.mutex.unlock(io);
                switch (wait) {
                    .cancelable => try io.futexWait(u32, &self.departures.raw, seen),
                    .uncancelable => io.futexWaitUncancelable(u32, &self.departures.raw, seen),
                }
            }
        }

        fn end(self: *Self, io: std.Io, mail: Mail) void {
            self.mutex.lockUncancelable(io);
            std.debug.assert(self.count < self.buffer.len);
            self.push(mail);
            self.mutex.unlock(io);
            io.futexWake(u32, &self.arrivals.raw, 1);
        }

        fn push(self: *Self, mail: Mail) void {
            self.buffer[@mod(self.head + self.count, self.buffer.len)] = mail;
            self.count += 1;
            _ = self.arrivals.fetchAdd(1, .release);
        }

        fn pop(self: *Self) Mail {
            const mail = self.buffer[self.head];
            self.head = @mod(self.head + 1, self.buffer.len);
            self.count -= 1;
            _ = self.departures.fetchAdd(1, .release);
            return mail;
        }
    };
}

test "mails arrive in order, and a closed mailbox refuses a send and frees what it holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mailbox: TestMailbox = .init;
    try mailbox.send(io, .{ .number = 1 });
    try mailbox.send(io, .{ .text = try gpa.dupe(u8, "kept") });
    try std.testing.expectEqual(@as(u32, 1), (try mailbox.receive(io)).number);
    try mailbox.send(io, .{ .text = try gpa.dupe(u8, "dropped") });
    mailbox.close(io);
    const refused: TestMail = .{ .text = try gpa.dupe(u8, "refused") };
    defer refused.deinit(gpa);
    try std.testing.expectError(error.Closed, mailbox.send(io, refused));
    const kept = try mailbox.receive(io);
    defer kept.deinit(gpa);
    try std.testing.expectEqualStrings("kept", kept.text);
    mailbox.drain(io, gpa);
    try std.testing.expectError(error.Closed, mailbox.receive(io));
}

const TestMail = union(enum) {
    number: u32,
    text: []u8,
    ended: u32,

    fn deinit(self: *const TestMail, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text => |text| gpa.free(text),
            .number, .ended => {},
        }
    }
};

const TestMailbox = Mailbox(TestMail, 2);

fn receiveOne(mailbox: *TestMailbox, io: std.Io) TestMailbox.Error!TestMail {
    return mailbox.receive(io);
}

fn postOne(mailbox: *TestMailbox, io: std.Io) TestMailbox.Error!void {
    return mailbox.post(io, .{ .number = 3 });
}

fn endAt(number: u32) TestMail {
    return .{ .ended = number };
}

fn endAtCancel(io: std.Io) TestMail {
    var never: std.Io.Event = .unset;
    never.wait(io) catch return .{ .ended = 0 };
    unreachable;
}

test "a cancel ends a wait for a mail and a wait for room" {
    const io = std.testing.io;
    var empty: TestMailbox = .init;
    var receiving = try io.concurrent(receiveOne, .{ &empty, io });
    try std.testing.expectError(error.Canceled, receiving.cancel(io));

    var full: TestMailbox = .init;
    try full.send(io, .{ .number = 1 });
    try full.send(io, .{ .number = 2 });
    var posting = try io.concurrent(postOne, .{ &full, io });
    try std.testing.expectError(error.Canceled, posting.cancel(io));
    try std.testing.expectEqual(@as(u32, 1), (try full.receive(io)).number);
    try std.testing.expectEqual(@as(u32, 2), (try full.receive(io)).number);
}

test "the end mail of a child takes the kept slot of a full mailbox" {
    const io = std.testing.io;
    var mailbox: TestMailbox = .init;
    try mailbox.send(io, .{ .number = 1 });
    try mailbox.send(io, .{ .number = 2 });
    try mailbox.start(io, endAt, .{7});
    try std.testing.expect(mailbox.busy());
    mailbox.reap(io);
    try std.testing.expect(!mailbox.busy());
    try std.testing.expectEqual(@as(u32, 1), (try mailbox.receive(io)).number);
    try std.testing.expectEqual(@as(u32, 2), (try mailbox.receive(io)).number);
    try std.testing.expectEqual(@as(u32, 7), (try mailbox.receive(io)).ended);
}

test "a cancel ends the child once, and its end mail still arrives" {
    const io = std.testing.io;
    var mailbox: TestMailbox = .init;
    try mailbox.start(io, endAtCancel, .{io});
    mailbox.cancel(io);
    mailbox.cancel(io);
    try std.testing.expect(mailbox.busy());
    try std.testing.expectEqual(@as(u32, 0), (try mailbox.receive(io)).ended);
    mailbox.reap(io);
    try std.testing.expect(!mailbox.busy());
}
