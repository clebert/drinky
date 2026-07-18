//! Incremental terminal-input parser: raw bytes in, `Key` events out.
//!
//! Bytes are fed in whatever chunks `read` returns; a single key or paste may
//! span several chunks. Unconsumed bytes are retained so a sequence split
//! across reads is decoded once the rest arrives.

const std = @import("std");

const escape = @import("escape.zig");

const Input = @This();

gpa: std.mem.Allocator,
pending: std.ArrayList(u8),
start: usize,
/// Set while an over-limit paste is being flushed in chunks: its begin marker
/// is consumed, but its terminator has not arrived yet.
in_paste: bool,

/// A single decoded input event from the terminal.
pub const Key = union(enum) {
    /// A printable Unicode codepoint the user typed.
    char: u21,
    /// A control combination, carrying the lowercase letter (`0x03` -> `'c'`).
    ctrl: u8,
    /// Bracketed-paste payload, borrowed from the parser's buffer for the call.
    paste: []const u8,
    enter,
    /// Shift+Enter (Kitty protocol): a literal newline that does not submit.
    newline,
    /// The Escape key (Kitty protocol reports it as `CSI 27 u`).
    escape,
    backspace,
    left,
    right,
    up,
    down,
    home,
    end,
    /// Alt+Up (Kitty legacy-modified arrow), decoded distinctly from a bare Up.
    alt_up,
    /// A recognized-but-unhandled sequence; callers ignore it.
    unknown,
};

const Decoded = struct { key: Key, consumed: usize, in_paste: bool = false };

/// Retained bytes at which an unterminated paste is flushed as a partial
/// payload, so a missing terminator cannot buffer unboundedly or wedge input.
const paste_flush_len = 1 << 20;

const escape_start = 0x1b;
const enter_key = 13;
const escape_key = 27;
const shift_bit = 0b001;
const alt_bit = 0b010;
const ctrl_bit = 0b100;

pub fn init(gpa: std.mem.Allocator) Input {
    return .{ .gpa = gpa, .pending = .empty, .start = 0, .in_paste = false };
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
pub fn next(self: *Input) ?Key {
    const data = self.pending.items[self.start..];
    if (data.len == 0) return null;
    const decoded = (if (self.in_paste) decodePasteBody(data) else decode(data)) orelse return null;
    self.in_paste = decoded.in_paste;
    self.start += decoded.consumed;
    return decoded.key;
}

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
        const decoded = decodePasteBody(data[body_start..]) orelse return null;
        return .{
            .key = decoded.key,
            .consumed = body_start + decoded.consumed,
            .in_paste = decoded.in_paste,
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

/// A paste body whose begin marker is already consumed: complete once the
/// terminator arrives, otherwise flushed as a bounded partial payload
/// (`in_paste` set) once it reaches `paste_flush_len`.
fn decodePasteBody(body: []const u8) ?Decoded {
    if (std.mem.indexOf(u8, body, escape.paste_end)) |end| {
        return .{ .key = .{ .paste = body[0..end] }, .consumed = end + escape.paste_end.len };
    }
    if (body.len < paste_flush_len) return null;
    // Hold back a partial terminator so a marker split across reads still ends the paste.
    const kept = escape.paste_end.len - 1;
    return .{ .key = .{ .paste = body[0 .. body.len - kept] }, .consumed = body.len - kept, .in_paste = true };
}

fn mapControlSequence(parameters: []const u8, final: u8) Key {
    if (final == '~') {
        if (std.mem.eql(u8, parameters, "1") or std.mem.eql(u8, parameters, "7")) return .home;
        if (std.mem.eql(u8, parameters, "4") or std.mem.eql(u8, parameters, "8")) return .end;
        return .unknown;
    }
    if (final == 'u') return mapCsiU(parameters);
    // A modified arrow arrives as `CSI 1 ; modifiers <final>` (Kitty leaves
    // these in the legacy encoding). Only plain Alt+Up is distinguished; any
    // other modifier combination decodes as the bare key.
    if (final == 'A' and modifiersOf(parameters) == alt_bit) return .alt_up;
    return mapFinal(final);
}

/// The modifier bitmask of a `row;modifiers` legacy sequence, zero when absent.
fn modifiersOf(parameters: []const u8) u21 {
    const semicolon = std.mem.indexOfScalar(u8, parameters, ';') orelse return 0;
    return (std.fmt.parseInt(u21, parameters[semicolon + 1 ..], 10) catch 1) -| 1;
}

/// Decode a Kitty-protocol `CSI codepoint;modifiers u` key. Only the events the
/// UI acts on are recognized; anything else is `.unknown`.
fn mapCsiU(parameters: []const u8) Key {
    var codepoint_field = parameters;
    var modifier_field: []const u8 = "1";
    if (std.mem.indexOfScalar(u8, parameters, ';')) |semicolon| {
        codepoint_field = parameters[0..semicolon];
        modifier_field = parameters[semicolon + 1 ..];
    }
    const codepoint = std.fmt.parseInt(u21, beforeColon(codepoint_field), 10) catch return .unknown;
    const modifiers = (std.fmt.parseInt(u21, beforeColon(modifier_field), 10) catch 1) -| 1;
    const shift = modifiers & shift_bit != 0;
    const ctrl = modifiers & ctrl_bit != 0;
    if (codepoint == enter_key and shift) return .newline;
    if (codepoint == escape_key) return .escape;
    if (ctrl) {
        const letter = asciiLetter(codepoint) orelse return .unknown;
        return .{ .ctrl = letter };
    }
    return .unknown;
}

fn beforeColon(field: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, field, ':') orelse return field;
    return field[0..colon];
}

fn asciiLetter(codepoint: u21) ?u8 {
    if (codepoint >= 'a' and codepoint <= 'z') return @intCast(codepoint);
    if (codepoint >= 'A' and codepoint <= 'Z') return @intCast(codepoint + 32);
    return null;
}

fn mapFinal(final: u8) Key {
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

fn expectKeys(bytes: []const u8, expected: []const Key) !void {
    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.feed(bytes);
    for (expected) |want| {
        const got = input.next() orelse return error.MissingKey;
        try std.testing.expectEqualDeep(want, got);
    }
    try std.testing.expectEqual(@as(?Key, null), input.next());
}

test "printable and control" {
    try expectKeys("hi", &.{ .{ .char = 'h' }, .{ .char = 'i' } });
    try expectKeys("\r", &.{.enter});
    try expectKeys("\x7f", &.{.backspace});
    try expectKeys("\x03", &.{.{ .ctrl = 'c' }});
    try expectKeys("\n", &.{.{ .ctrl = 'j' }});
}

test "kitty csi-u keys" {
    try expectKeys("\x1b[13;2u", &.{.newline});
    try expectKeys("\x1b[27u", &.{.escape});
    try expectKeys("\x1b[67;5u", &.{.{ .ctrl = 'c' }});
    try expectKeys("\x1b[106;5u", &.{.{ .ctrl = 'j' }});
    try expectKeys("\x1b[13u", &.{.unknown});
}

test "malformed or truncated utf-8 decodes as unknown with forward progress" {
    try expectKeys("\xffa", &.{ .unknown, .{ .char = 'a' } });
    try expectKeys("\xc3(x", &.{ .unknown, .{ .char = 'x' } });
    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.feed("\xe2\x82");
    try std.testing.expectEqual(@as(?Key, null), input.next());
    try input.feed("\xac");
    try std.testing.expectEqualDeep(Key{ .char = '€' }, input.next().?);
}

test "arrows and navigation" {
    try expectKeys("\x1b[A\x1b[D", &.{ .up, .left });
    try expectKeys("\x1bOC", &.{.right});
    try expectKeys("\x1b[H\x1b[4~", &.{ .home, .end });
}

test "alt+up decodes apart from a bare or otherwise-modified up" {
    try expectKeys("\x1b[1;3A", &.{.alt_up});
    // Other modifiers on Up (here Shift) fall back to the bare key.
    try expectKeys("\x1b[1;2A", &.{.up});
    // Alt on another arrow is not acted on.
    try expectKeys("\x1b[1;3B", &.{.down});
}

test "bracketed paste" {
    try expectKeys("\x1b[200~ab\ncd\x1b[201~", &.{.{ .paste = "ab\ncd" }});
}

test "an unterminated paste past the limit flushes and stays a paste" {
    const gpa = std.testing.allocator;
    var input = Input.init(gpa);
    defer input.deinit();
    const body = try gpa.alloc(u8, paste_flush_len);
    defer gpa.free(body);
    @memset(body, 'x');
    try input.feed(escape.paste_begin);
    try input.feed(body);
    const flushed = input.next() orelse return error.MissingKey;
    try std.testing.expectEqual(paste_flush_len - escape.paste_end.len + 1, flushed.paste.len);
    // Later bytes stay paste payload — not keystrokes — until the terminator.
    try input.feed("\rab");
    try std.testing.expectEqual(@as(?Key, null), input.next());
    try input.feed(escape.paste_end ++ "c");
    try std.testing.expectEqualDeep(Key{ .paste = "xxxxx\rab" }, input.next().?);
    try std.testing.expectEqualDeep(Key{ .char = 'c' }, input.next().?);
    try std.testing.expectEqual(@as(?Key, null), input.next());
}

test "split sequence waits for rest" {
    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.feed("a\x1b[");
    try std.testing.expectEqualDeep(Key{ .char = 'a' }, input.next().?);
    try std.testing.expectEqual(@as(?Key, null), input.next());
    try input.feed("A");
    try std.testing.expectEqualDeep(Key.up, input.next().?);
    try std.testing.expectEqual(@as(?Key, null), input.next());
}
