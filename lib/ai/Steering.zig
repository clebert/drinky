//! A thread-safe queue of steering messages: text the user submits mid-turn,
//! handed from the UI thread to the turn worker. The queue owns each message
//! until taken. The UI thread pushes; either thread takes (drain into the turn,
//! recall, or cancel), so the mutex guards take against take, not just push.

const std = @import("std");

const Steering = @This();

gpa: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex,
messages: std.ArrayList([]u8),

pub fn init(gpa: std.mem.Allocator, io: std.Io) Steering {
    return .{ .gpa = gpa, .io = io, .mutex = .init, .messages = .empty };
}

pub fn deinit(self: *Steering) void {
    for (self.messages.items) |message| self.gpa.free(message);
    self.messages.deinit(self.gpa);
}

/// Queue a copy of `text`. Duplicated before the lock so only the append is held.
pub fn push(self: *Steering, text: []const u8) !void {
    const copy = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(copy);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.messages.append(self.gpa, copy);
}

/// Take every queued message, transferring ownership to the caller (free each
/// message and the returned slice with the same gpa) and emptying the queue.
pub fn take(self: *Steering) ![][]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.messages.toOwnedSlice(self.gpa);
}

/// Combine `messages` into one string, blank-line separated — the single form
/// the queue is delivered, edited, and re-sent in. Caller owns the result.
pub fn join(gpa: std.mem.Allocator, messages: []const []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    for (messages, 0..) |message, index| {
        if (index > 0) try buffer.appendSlice(gpa, "\n\n");
        try buffer.appendSlice(gpa, message);
    }
    return buffer.toOwnedSlice(gpa);
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
        const Located = struct { producer: usize, seq: usize };

        // Push uniquely tagged messages so the consumer can prove none are
        // lost, duplicated, or torn.
        fn produce(steering: *Steering, task: Task) error{OutOfMemory}!void {
            var buffer: [32]u8 = undefined;
            var seq: usize = 0;
            while (seq < task.count) : (seq += 1) {
                const text = std.fmt.bufPrint(&buffer, "steer p{d} #{d}", .{ task.producer, seq }) catch unreachable;
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
                .seq = std.fmt.parseInt(usize, tail[1..], 10) catch return error.Corrupt,
            };
        }
    };

    var steering = Steering.init(gpa, io);
    defer steering.deinit();

    // Force the mutex slow path: hold the lock until every producer parks
    // (state `.contended`), then unlock to run the wakeup — the contended path
    // the single-threaded tests never reach.
    steering.mutex.lockUncancelable(io);
    var futures: [producer_count]std.Io.Future(error{OutOfMemory}!void) = undefined;
    for (&futures, 0..) |*future, index| {
        future.* = try io.concurrent(work.produce, .{ &steering, work.Task{ .producer = index, .count = per_producer } });
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

    // Drain concurrently with the producers: `seen` catches loss and duplication,
    // `parse` corruption; the capped empty-spin fails a lost message rather than
    // hanging.
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
            try std.testing.expect(located.seq < per_producer);
            const slot = located.producer * per_producer + located.seq;
            try std.testing.expect(!seen[slot]);
            seen[slot] = true;
            collected += 1;
        }
    }

    for (&futures) |*future| try future.await(io);
    try std.testing.expectEqual(total, collected);
    for (seen) |flag| try std.testing.expect(flag);
}
