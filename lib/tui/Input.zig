//! Incremental terminal-input parser: raw bytes in, `key.Key` events out.
//!
//! Bytes are fed in whatever chunks `read` returns; a single key or paste may
//! span several chunks. Unconsumed bytes are retained so a sequence split
//! across reads is decoded once the rest arrives.

const std = @import("std");
const key = @import("key.zig");
const escape = @import("../terminal/escape.zig");

const Input = @This();

gpa: std.mem.Allocator,
pending: std.ArrayList(u8),
start: usize,

pub fn init(gpa: std.mem.Allocator) Input {
    return .{ .gpa = gpa, .pending = .empty, .start = 0 };
}

pub fn deinit(self: *Input) void {
    self.pending.deinit(self.gpa);
}

/// Append freshly read bytes, first dropping the consumed prefix.
pub fn feed(self: *Input, bytes: []const u8) !void {
    if (self.start > 0) {
        const kept = self.pending.items.len - self.start;
        std.mem.copyForwards(u8, self.pending.items[0..kept], self.pending.items[self.start..]);
        self.pending.shrinkRetainingCapacity(kept);
        self.start = 0;
    }
    try self.pending.appendSlice(self.gpa, bytes);
}

/// Next decoded event, or null when the remaining bytes are empty or form an
/// incomplete sequence awaiting more input. A returned `.paste` slice borrows
/// the internal buffer and is valid only until the next `feed`.
pub fn next(self: *Input) ?key.Key {
    const data = self.pending.items[self.start..];
    if (data.len == 0) return null;
    const decoded = decode(data) orelse return null;
    self.start += decoded.consumed;
    return decoded.key;
}

const Decoded = struct { key: key.Key, consumed: usize };

fn decode(data: []const u8) ?Decoded {
    const byte = data[0];
    switch (byte) {
        escape_start => return decodeEscape(data),
        '\r' => return .{ .key = .enter, .consumed = 1 },
        0x08, 0x7f => return .{ .key = .backspace, .consumed = 1 },
        0x01...0x07, 0x09...0x0c, 0x0e...0x1a => return .{ .key = .{ .ctrl = byte + 0x60 }, .consumed = 1 },
        0x00, 0x1c...0x1f => return .{ .key = .unknown, .consumed = 1 },
        else => {
            if (byte < 0x80) return .{ .key = .{ .char = byte }, .consumed = 1 };
            const length = std.unicode.utf8ByteSequenceLength(byte) catch {
                return .{ .key = .unknown, .consumed = 1 };
            };
            if (data.len < length) return null;
            const codepoint = std.unicode.utf8Decode(data[0..length]) catch {
                return .{ .key = .unknown, .consumed = length };
            };
            return .{ .key = .{ .char = codepoint }, .consumed = length };
        },
    }
}

fn decodeEscape(data: []const u8) ?Decoded {
    if (data.len < 2) return null;
    switch (data[1]) {
        '[' => return decodeControlSequence(data),
        'O' => {
            if (data.len < 3) return null;
            return .{ .key = mapFinal(data[2]), .consumed = 3 };
        },
        else => return .{ .key = .unknown, .consumed = 2 },
    }
}

fn decodeControlSequence(data: []const u8) ?Decoded {
    if (std.mem.startsWith(u8, data, escape.paste_begin)) {
        const body_start = escape.paste_begin.len;
        const relative = std.mem.indexOf(u8, data[body_start..], escape.paste_end) orelse return null;
        const body_end = body_start + relative;
        return .{
            .key = .{ .paste = data[body_start..body_end] },
            .consumed = body_end + escape.paste_end.len,
        };
    }
    var index: usize = 2;
    while (index < data.len) : (index += 1) {
        const final = data[index];
        if (final >= 0x40 and final <= 0x7e) {
            const parameters = data[2..index];
            return .{ .key = mapControlSequence(parameters, final), .consumed = index + 1 };
        }
    }
    return null;
}

fn mapControlSequence(parameters: []const u8, final: u8) key.Key {
    if (final == '~') {
        if (std.mem.eql(u8, parameters, "1") or std.mem.eql(u8, parameters, "7")) return .home;
        if (std.mem.eql(u8, parameters, "4") or std.mem.eql(u8, parameters, "8")) return .end;
        return .unknown;
    }
    return mapFinal(final);
}

fn mapFinal(final: u8) key.Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => .unknown,
    };
}

const escape_start = 0x1b;

fn expectKeys(bytes: []const u8, expected: []const key.Key) !void {
    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.feed(bytes);
    for (expected) |want| {
        const got = input.next() orelse return error.MissingKey;
        try std.testing.expectEqualDeep(want, got);
    }
    try std.testing.expectEqual(@as(?key.Key, null), input.next());
}

test "printable and control" {
    try expectKeys("hi", &.{ .{ .char = 'h' }, .{ .char = 'i' } });
    try expectKeys("\r", &.{.enter});
    try expectKeys("\x7f", &.{.backspace});
    try expectKeys("\x03", &.{.{ .ctrl = 'c' }});
    try expectKeys("\n", &.{.{ .ctrl = 'j' }});
}

test "arrows and navigation" {
    try expectKeys("\x1b[A\x1b[D", &.{ .up, .left });
    try expectKeys("\x1bOC", &.{.right});
    try expectKeys("\x1b[H\x1b[4~", &.{ .home, .end });
}

test "bracketed paste" {
    try expectKeys("\x1b[200~ab\ncd\x1b[201~", &.{.{ .paste = "ab\ncd" }});
}

test "split sequence waits for rest" {
    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.feed("\x1b[");
    try std.testing.expectEqual(@as(?key.Key, null), input.next());
    try input.feed("A");
    try std.testing.expectEqualDeep(key.Key.up, input.next().?);
}
