//! A thread-safe queue of steering messages: text the user submits mid-turn,
//! handed from the UI thread to the turn worker. The queue owns each message
//! until taken. The UI thread pushes or recalls. The worker takes for delivery.
//! A failed delivery restores its whole batch as a queue prefix without an
//! allocation, ahead of messages submitted since the take.

const std = @import("std");

const Steering = @This();

gpa: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex,
/// A restored batch ahead of `messages` that retains its original outer
/// allocation. At most one exists because restoration ends the operation that
/// took it.
restored_prefix: std.ArrayList([]u8),
messages: std.ArrayList([]u8),

pub fn init(gpa: std.mem.Allocator, io: std.Io) Steering {
    return .{
        .gpa = gpa,
        .io = io,
        .mutex = .init,
        .restored_prefix = .empty,
        .messages = .empty,
    };
}

pub fn deinit(self: *Steering) void {
    freeMessages(self.gpa, &self.restored_prefix);
    freeMessages(self.gpa, &self.messages);
}

/// Atomically discard every queued message without an allocation. Messages
/// pushed after the swap remain queued. Callers still synchronize with any
/// producer whose earlier push must also be discarded.
pub fn clear(self: *Steering) void {
    self.mutex.lockUncancelable(self.io);
    var restored_prefix = self.restored_prefix;
    self.restored_prefix = .empty;
    var messages = self.messages;
    self.messages = .empty;
    self.mutex.unlock(self.io);

    freeMessages(self.gpa, &restored_prefix);
    freeMessages(self.gpa, &messages);
}

/// Queue a copy of `text`. The duplication runs before the lock, so only the
/// append is held.
pub fn push(self: *Steering, text: []const u8) !void {
    const copy = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(copy);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.messages.append(self.gpa, copy);
}

/// Take every queued message in logical order. The take transfers ownership to
/// the caller and empties both the restored prefix and ordinary queue.
pub fn take(self: *Steering) ![][]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.takeLocked();
}

/// Restore a previously taken batch as the queue prefix. The move of the
/// original outer allocation makes the whole batch visible at once, ahead of
/// messages queued since the take. The move leaves the source empty.
pub fn restoreTaken(self: *Steering, messages: *[][]u8) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    std.debug.assert(self.restored_prefix.items.len == 0);
    self.restored_prefix = .fromOwnedSlice(messages.*);
    messages.* = &.{};
}

/// Drain the restored prefix followed by ordinary messages. No ownership changes
/// until allocation succeeds, so an OOM leaves both queue segments intact.
fn takeLocked(self: *Steering) ![][]u8 {
    if (self.restored_prefix.items.len == 0) return self.messages.toOwnedSlice(self.gpa);
    if (self.messages.items.len == 0) return self.restored_prefix.toOwnedSlice(self.gpa);

    const length = try std.math.add(
        usize,
        self.restored_prefix.items.len,
        self.messages.items.len,
    );
    const combined = try self.gpa.alloc([]u8, length);
    @memcpy(combined[0..self.restored_prefix.items.len], self.restored_prefix.items);
    @memcpy(combined[self.restored_prefix.items.len..], self.messages.items);
    self.restored_prefix.deinit(self.gpa);
    self.restored_prefix = .empty;
    self.messages.deinit(self.gpa);
    self.messages = .empty;
    return combined;
}

fn freeMessages(gpa: std.mem.Allocator, messages: *std.ArrayList([]u8)) void {
    for (messages.items) |message| gpa.free(message);
    messages.deinit(gpa);
}

/// Combine `messages` into one string, blank-line separated. This is the
/// single form the queue is delivered, edited, and re-sent in. The caller owns
/// the result.
pub fn join(gpa: std.mem.Allocator, messages: []const []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    for (messages, 0..) |message, index| {
        if (index > 0) try buffer.appendSlice(gpa, "\n\n");
        try buffer.appendSlice(gpa, message);
    }
    return buffer.toOwnedSlice(gpa);
}

test "clear discards the queued messages" {
    const gpa = std.testing.allocator;
    var steering = Steering.init(gpa, std.testing.io);
    defer steering.deinit();

    try steering.push("foo");
    try steering.push("bar");
    steering.clear();

    const taken = try steering.take();
    defer gpa.free(taken);
    try std.testing.expectEqual(@as(usize, 0), taken.len);
}

test "push then take drains the queue in order" {
    const gpa = std.testing.allocator;
    var steering = Steering.init(gpa, std.testing.io);
    defer steering.deinit();

    try steering.push("foo");
    try steering.push("qux");
    const taken = try steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 2), taken.len);
    try std.testing.expectEqualStrings("foo", taken[0]);
    try std.testing.expectEqualStrings("qux", taken[1]);

    const empty = try steering.take();
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "a failed delivery restores ahead of messages queued after its take" {
    const gpa = std.testing.allocator;
    var steering = Steering.init(gpa, std.testing.io);
    defer steering.deinit();

    try steering.push("a");
    try steering.push("b");
    var delivery = try steering.take();
    defer {
        for (delivery) |message| gpa.free(message);
        gpa.free(delivery);
    }
    try steering.push("c");
    steering.restoreTaken(&delivery);
    try std.testing.expectEqual(@as(usize, 0), delivery.len);

    const taken = try steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 3), taken.len);
    try std.testing.expectEqualStrings("a", taken[0]);
    try std.testing.expectEqualStrings("b", taken[1]);
    try std.testing.expectEqualStrings("c", taken[2]);
}

test "a failed delivery becomes a prefix after an intervening recall" {
    const gpa = std.testing.allocator;
    var steering = Steering.init(gpa, std.testing.io);
    defer steering.deinit();

    try steering.push("a");
    try steering.push("b");
    var delivery = try steering.take();
    defer {
        for (delivery) |message| gpa.free(message);
        gpa.free(delivery);
    }
    try steering.push("c");

    const recalled = try steering.take();
    defer {
        for (recalled) |message| gpa.free(message);
        gpa.free(recalled);
    }
    try std.testing.expectEqual(@as(usize, 1), recalled.len);
    try std.testing.expectEqualStrings("c", recalled[0]);

    steering.restoreTaken(&delivery);
    try std.testing.expectEqual(@as(usize, 0), delivery.len);
    const restored = try steering.take();
    defer {
        for (restored) |message| gpa.free(message);
        gpa.free(restored);
    }
    try std.testing.expectEqual(@as(usize, 2), restored.len);
    try std.testing.expectEqualStrings("a", restored[0]);
    try std.testing.expectEqualStrings("b", restored[1]);
}

test "a failed combined take leaves restored and newer messages queued" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var steering = Steering.init(gpa, std.testing.io);
    defer steering.deinit();

    try steering.push("a");
    try steering.push("b");
    var delivery = try steering.take();
    defer {
        for (delivery) |message| gpa.free(message);
        gpa.free(delivery);
    }
    try steering.push("c");
    steering.restoreTaken(&delivery);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, steering.take());

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    const taken = try steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 3), taken.len);
    try std.testing.expectEqualStrings("a", taken[0]);
    try std.testing.expectEqualStrings("b", taken[1]);
    try std.testing.expectEqualStrings("c", taken[2]);
}

test "a taken delivery can be restored without allocation" {
    const gpa = std.testing.allocator;
    var steering = Steering.init(gpa, std.testing.io);
    defer steering.deinit();

    try steering.push("a");
    try steering.push("b");
    var delivery = try steering.take();
    defer {
        for (delivery) |message| gpa.free(message);
        gpa.free(delivery);
    }
    steering.restoreTaken(&delivery);
    try std.testing.expectEqual(@as(usize, 0), delivery.len);

    const taken = try steering.take();
    defer {
        for (taken) |message| gpa.free(message);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 2), taken.len);
    try std.testing.expectEqualStrings("a", taken[0]);
    try std.testing.expectEqualStrings("b", taken[1]);
}

test "join separates messages with a blank line" {
    const gpa = std.testing.allocator;
    const joined = try Steering.join(gpa, &.{ "foo", "qux" });
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("foo\n\nqux", joined);

    const one = try Steering.join(gpa, &.{"solo"});
    defer gpa.free(one);
    try std.testing.expectEqualStrings("solo", one);
}

test "push and take survive concurrent contention" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const producer_count = 8;
    const per_producer = 1000;
    const total = producer_count * per_producer;

    const work = struct {
        const Task = struct { producer: usize, count: usize };
        const Located = struct { producer: usize, sequence: usize };

        // Push uniquely tagged messages so the consumer can prove none are
        // lost, duplicated, or torn.
        fn produce(steering: *Steering, task: Task) error{OutOfMemory}!void {
            var buffer: [32]u8 = undefined;
            var sequence: usize = 0;
            while (sequence < task.count) : (sequence += 1) {
                const text = std.fmt.bufPrint(
                    &buffer,
                    "steer p{d} #{d}",
                    .{ task.producer, sequence },
                ) catch unreachable;
                try steering.push(text);
            }
        }

        fn parse(text: []const u8) !Located {
            const prefix = "steer p";
            if (!std.mem.startsWith(u8, text, prefix)) return error.Corrupt;
            const rest = text[prefix.len..];
            const gap = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.Corrupt;
            const tail = rest[gap + 1 ..];
            if (!std.mem.startsWith(u8, tail, "#")) return error.Corrupt;
            return .{
                .producer = std.fmt.parseInt(usize, rest[0..gap], 10) catch return error.Corrupt,
                .sequence = std.fmt.parseInt(usize, tail[1..], 10) catch return error.Corrupt,
            };
        }
    };

    var steering = Steering.init(gpa, io);
    defer steering.deinit();

    // Force the mutex slow path: hold the lock until every producer parks
    // (state `.contended`), then unlock to run the wakeup. This is the
    // contended path the single-threaded tests never reach.
    steering.mutex.lockUncancelable(io);
    var futures: [producer_count]std.Io.Future(error{OutOfMemory}!void) = undefined;
    for (&futures, 0..) |*future, index| {
        future.* = try io.concurrent(
            work.produce,
            .{ &steering, work.Task{ .producer = index, .count = per_producer } },
        );
    }
    // Reap producers before `steering.deinit`, so an early failure never frees
    // the queue mid-push.
    defer for (&futures) |*future| {
        _ = future.await(io) catch {};
    };

    var forced_contended = false;
    var poll: usize = 0;
    while (poll < 1000) : (poll += 1) {
        if (steering.mutex.state.load(.monotonic) == .contended) {
            forced_contended = true;
            break;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    steering.mutex.unlock(io);
    try std.testing.expect(forced_contended);

    // Drain concurrently with the producers: `seen` catches loss and
    // duplication, and `parse` catches corruption. The capped empty-spin fails
    // a lost message rather than hangs.
    const seen = try gpa.alloc(bool, total);
    defer gpa.free(seen);
    @memset(seen, false);

    var collected: usize = 0;
    var empty_streak: usize = 0;
    const empty_streak_max = 3000;
    while (collected < total) {
        if (empty_streak == empty_streak_max) break;
        const batch = try steering.take();
        defer {
            for (batch) |message| gpa.free(message);
            gpa.free(batch);
        }
        if (batch.len == 0) {
            empty_streak += 1;
            io.sleep(.fromMilliseconds(1), .awake) catch {};
            continue;
        }
        empty_streak = 0;
        for (batch) |message| {
            const located = try work.parse(message);
            try std.testing.expect(located.producer < producer_count);
            try std.testing.expect(located.sequence < per_producer);
            const slot = located.producer * per_producer + located.sequence;
            try std.testing.expect(!seen[slot]);
            seen[slot] = true;
            collected += 1;
        }
    }

    for (&futures) |*future| try future.await(io);
    try std.testing.expectEqual(total, collected);
    for (seen) |flag| try std.testing.expect(flag);
}
