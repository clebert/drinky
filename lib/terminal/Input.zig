const std = @import("std");

const escape = @import("escape.zig");

const Input = @This();

gpa: std.mem.Allocator,
pending: std.ArrayList(u8),
start: usize,
in_paste: bool,

pub const Key = union(enum) {
    char: u21,
    ctrl: u8,
    paste: struct { bytes: []const u8, final: bool },
    enter,
    shift_enter,
    tab,
    escape,
    backspace,
    left,
    right,
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    unknown,
};

const Decoded = struct { key: Key, consumed: usize, in_paste: bool = false };

const paste_flush_len = 1 << 20;

const sequence_flush_len = 64;

const escape_start = 0x1b;
const tab_key = 9;
const enter_key = 13;
const escape_key = 27;
const shift_bit = 0b001;
const ctrl_bit = 0b100;

pub fn init(gpa: std.mem.Allocator) Input {
    return .{ .gpa = gpa, .pending = .empty, .start = 0, .in_paste = false };
}

pub fn deinit(self: *Input) void {
    self.pending.deinit(self.gpa);
}

pub fn feed(self: *Input, bytes: []const u8) !void {
    if (self.start > 0) {
        const kept = self.pending.items.len - self.start;
        std.mem.copyForwards(u8, self.pending.items[0..kept], self.pending.items[self.start..]);
        self.pending.shrinkRetainingCapacity(kept);
        self.start = 0;
    }
    try self.pending.appendSlice(self.gpa, bytes);
}

pub fn pendingEscape(self: *const Input) bool {
    if (self.in_paste) return false;
    const data = self.pending.items[self.start..];
    return data.len == 1 and data[0] == escape_start;
}

pub fn takeEscape(self: *Input) bool {
    if (!self.pendingEscape()) return false;
    self.start += 1;
    return true;
}

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
        '\t' => return .{ .key = .tab, .consumed = 1 },
        0x08, 0x7f => return .{ .key = .backspace, .consumed = 1 },
        0x01...0x07, 0x0a...0x0c, 0x0e...0x1a => return .{
            .key = .{ .ctrl = byte + 0x60 },
            .consumed = 1,
        },
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
        0x00...0x1f => return .{ .key = .escape, .consumed = 1 },
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
    if (data.len < sequence_flush_len) return null;
    return .{ .key = .unknown, .consumed = data.len };
}

fn decodePasteBody(body: []const u8) ?Decoded {
    if (std.mem.find(u8, body, escape.paste_end)) |end| {
        return .{
            .key = .{ .paste = .{ .bytes = body[0..end], .final = true } },
            .consumed = end + escape.paste_end.len,
        };
    }
    if (body.len < paste_flush_len) return null;
    const kept = escape.paste_end.len - 1;
    return .{
        .key = .{ .paste = .{ .bytes = body[0 .. body.len - kept], .final = false } },
        .consumed = body.len - kept,
        .in_paste = true,
    };
}

fn mapControlSequence(parameters: []const u8, final: u8) Key {
    if (final == '~') {
        if (std.mem.eql(u8, parameters, "1") or std.mem.eql(u8, parameters, "7")) return .home;
        if (std.mem.eql(u8, parameters, "4") or std.mem.eql(u8, parameters, "8")) return .end;
        if (std.mem.eql(u8, parameters, "5")) return .page_up;
        if (std.mem.eql(u8, parameters, "6")) return .page_down;
        return .unknown;
    }
    if (final == 'u') return mapCsiU(parameters);
    return mapFinal(final);
}

fn mapCsiU(parameters: []const u8) Key {
    var codepoint_field = parameters;
    var modifier_field: []const u8 = "1";
    if (std.mem.findScalar(u8, parameters, ';')) |semicolon| {
        codepoint_field = parameters[0..semicolon];
        modifier_field = parameters[semicolon + 1 ..];
    }
    const codepoint = std.fmt.parseInt(u21, beforeColon(codepoint_field), 10) catch return .unknown;
    const modifiers = (std.fmt.parseInt(u21, beforeColon(modifier_field), 10) catch 1) -| 1;
    const shift = modifiers & shift_bit != 0;
    const ctrl = modifiers & ctrl_bit != 0;
    if (codepoint == enter_key and shift) return .shift_enter;
    if (codepoint == escape_key) return .escape;
    if (codepoint == tab_key) return if (modifiers == 0) .tab else .unknown;
    if (ctrl) {
        const letter = asciiLetter(codepoint) orelse return .unknown;
        return .{ .ctrl = letter };
    }
    return .unknown;
}

fn beforeColon(field: []const u8) []const u8 {
    const colon = std.mem.findScalar(u8, field, ':') orelse return field;
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

test "a printable byte decodes as a char, and a control byte as its key or as unknown" {
    try expectKeys("hi", &.{ .{ .char = 'h' }, .{ .char = 'i' } });
    try expectKeys("\r", &.{.enter});
    try expectKeys("\x7f", &.{.backspace});
    try expectKeys("\x03", &.{.{ .ctrl = 'c' }});
    try expectKeys("\n", &.{.{ .ctrl = 'j' }});
    try expectKeys("\x00\x1c", &.{ .unknown, .unknown });
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

test "a csi-u sequence decodes as shift+enter, escape, a ctrl letter, or unknown" {
    try expectKeys("\x1b[13;2u", &.{.shift_enter});
    try expectKeys("\x1b[27u", &.{.escape});
    try expectKeys("\x1b[67;5u", &.{.{ .ctrl = 'c' }});
    try expectKeys("\x1b[106;5u", &.{.{ .ctrl = 'j' }});
    try expectKeys("\x1b[13u", &.{.unknown});
}

test "tab decodes as its own key, and a modified tab stays unknown" {
    try expectKeys("\t", &.{.tab});
    try expectKeys("\x1b[105;5u", &.{.{ .ctrl = 'i' }});
    try expectKeys("\x1b[9u", &.{.tab});
    try expectKeys("\x1b[Z", &.{.unknown});
    try expectKeys("\x1b[9;2u", &.{.unknown});
    for (2..257) |modifier| {
        var sequence_buffer: [16]u8 = undefined;
        const sequence = try std.mem.print(&sequence_buffer, "\x1b[9;{d}u", .{modifier});
        try expectKeys(sequence, &.{.unknown});
    }
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

test "a csi or ss3 sequence decodes as an arrow key or a navigation key" {
    try expectKeys("\x1b[A\x1b[D", &.{ .up, .left });
    try expectKeys("\x1bOC", &.{.right});
    try expectKeys("\x1b[H\x1b[1~\x1b[7~", &.{ .home, .home, .home });
    try expectKeys("\x1b[F\x1b[4~\x1b[8~", &.{ .end, .end, .end });
    try expectKeys("\x1b[5~\x1b[6~", &.{ .page_up, .page_down });
}

test "a modified arrow decodes as the bare key" {
    try expectKeys("\x1b[1;3A", &.{.up});
    try expectKeys("\x1b[1;2A", &.{.up});
    try expectKeys("\x1b[1;3B", &.{.down});
}

test "a complete paste is one final event" {
    try expectKeys(
        escape.paste_begin ++ escape.paste_end,
        &.{.{ .paste = .{ .bytes = "", .final = true } }},
    );
    try expectKeys(
        escape.paste_begin ++ "ab\ncd" ++ escape.paste_end ++ "Z",
        &.{ .{ .paste = .{ .bytes = "ab\ncd", .final = true } }, .{ .char = 'Z' } },
    );
}

test "a complete large paste in one feed is not capped" {
    const gpa = std.testing.allocator;
    var input = Input.init(gpa);
    defer input.deinit();
    const body = try gpa.alloc(u8, paste_flush_len + 100);
    defer gpa.free(body);
    @memset(body, 'x');
    try input.feed(escape.paste_begin);
    try input.feed(body);
    try input.feed(escape.paste_end);
    const key = input.next() orelse return error.MissingKey;
    try std.testing.expect(key.paste.final);
    try std.testing.expectEqual(body.len, key.paste.bytes.len);
    try std.testing.expectEqual(@as(?Key, null), input.next());
}

test "begin and end markers split at every byte boundary" {
    const gpa = std.testing.allocator;
    const full = escape.paste_begin ++ "ab\ncd" ++ escape.paste_end;
    var split: usize = 0;
    while (split <= full.len) : (split += 1) {
        var input = Input.init(gpa);
        defer input.deinit();
        try input.feed(full[0..split]);
        if (split < full.len) try std.testing.expectEqual(@as(?Key, null), input.next());
        try input.feed(full[split..]);
        try std.testing.expectEqualDeep(
            Key{ .paste = .{ .bytes = "ab\ncd", .final = true } },
            input.next().?,
        );
        try std.testing.expectEqual(@as(?Key, null), input.next());
    }
}

test "an unterminated paste flushes as a non-final continuation then terminates" {
    const gpa = std.testing.allocator;
    var input = Input.init(gpa);
    defer input.deinit();
    const body = try gpa.alloc(u8, paste_flush_len);
    defer gpa.free(body);
    @memset(body, 'x');
    try input.feed(escape.paste_begin);
    try input.feed(body);
    const flushed = input.next() orelse return error.MissingKey;
    try std.testing.expectEqual(false, flushed.paste.final);
    try std.testing.expectEqual(
        paste_flush_len - escape.paste_end.len + 1,
        flushed.paste.bytes.len,
    );
    try input.feed("\rab");
    try std.testing.expectEqual(@as(?Key, null), input.next());
    try input.feed(escape.paste_end ++ "c");
    try std.testing.expectEqualDeep(
        Key{ .paste = .{ .bytes = "xxxxx\rab", .final = true } },
        input.next().?,
    );
    try std.testing.expectEqualDeep(Key{ .char = 'c' }, input.next().?);
    try std.testing.expectEqual(@as(?Key, null), input.next());
}

test "a payload over multiple caps yields continuations then one final" {
    const gpa = std.testing.allocator;
    var input = Input.init(gpa);
    defer input.deinit();
    const kept = escape.paste_end.len - 1;
    const body = try gpa.alloc(u8, paste_flush_len);
    defer gpa.free(body);
    @memset(body, 'x');
    var total: usize = 0;

    try input.feed(escape.paste_begin);
    try input.feed(body);
    const first = input.next() orelse return error.MissingKey;
    try std.testing.expectEqual(false, first.paste.final);
    try std.testing.expectEqual(paste_flush_len - kept, first.paste.bytes.len);
    total += first.paste.bytes.len;

    try input.feed(body);
    const second = input.next() orelse return error.MissingKey;
    try std.testing.expectEqual(false, second.paste.final);
    try std.testing.expectEqual(paste_flush_len, second.paste.bytes.len);
    total += second.paste.bytes.len;

    try input.feed(escape.paste_end);
    const last = input.next() orelse return error.MissingKey;
    try std.testing.expect(last.paste.final);
    total += last.paste.bytes.len;

    try std.testing.expectEqual(2 * paste_flush_len, total);
    try std.testing.expectEqual(@as(?Key, null), input.next());
}

test "an exact-cap flush leaves an empty final chunk before the terminator" {
    const gpa = std.testing.allocator;
    var input = Input.init(gpa);
    defer input.deinit();
    const kept = escape.paste_end.len - 1;
    const body = try gpa.alloc(u8, paste_flush_len);
    defer gpa.free(body);
    @memset(body, 'x');
    @memcpy(body[body.len - kept ..], escape.paste_end[0..kept]);
    try input.feed(escape.paste_begin);
    try input.feed(body);
    const flushed = input.next() orelse return error.MissingKey;
    try std.testing.expectEqual(false, flushed.paste.final);
    try std.testing.expectEqual(paste_flush_len - kept, flushed.paste.bytes.len);
    try std.testing.expectEqual(@as(?Key, null), input.next());
    try input.feed(escape.paste_end[kept..]);
    const final = input.next() orelse return error.MissingKey;
    try std.testing.expect(final.paste.final);
    try std.testing.expectEqual(@as(usize, 0), final.paste.bytes.len);
    try std.testing.expectEqual(@as(?Key, null), input.next());
}

test "controls, cr, and escape inside a paste stay payload" {
    const payload = "a\r\nb\x1b[Ac\x03";
    try expectKeys(
        escape.paste_begin ++ payload ++ escape.paste_end,
        &.{.{ .paste = .{ .bytes = payload, .final = true } }},
    );
}

test "an unterminated csi past the limit is abandoned as unknown" {
    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.feed("\x1b[" ++ @as([sequence_flush_len]u8, @splat(';')));
    try std.testing.expectEqualDeep(Key.unknown, input.next().?);
    try input.feed("a");
    try std.testing.expectEqualDeep(Key{ .char = 'a' }, input.next().?);
    try std.testing.expectEqual(@as(?Key, null), input.next());
}

test "a legacy escape byte waits, then takes effect on its own" {
    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.feed("\x1b");
    try std.testing.expectEqual(@as(?Key, null), input.next());
    try std.testing.expect(input.pendingEscape());

    try std.testing.expect(input.takeEscape());
    try std.testing.expect(!input.pendingEscape());
    try std.testing.expect(!input.takeEscape());
    try std.testing.expectEqual(@as(?Key, null), input.next());

    try input.feed("\x1b");
    try std.testing.expect(input.pendingEscape());
    try input.feed("[A");
    try std.testing.expect(!input.pendingEscape());
    try std.testing.expectEqualDeep(Key.up, input.next().?);
}

test "a control byte after a legacy escape keeps both keys" {
    try expectKeys("\x1b\x03", &.{ .escape, .{ .ctrl = 'c' } });
    try expectKeys("\x1b\x04", &.{ .escape, .{ .ctrl = 'd' } });
    try expectKeys("\x1ba", &.{.unknown});

    var input = Input.init(std.testing.allocator);
    defer input.deinit();
    try input.feed("\x1b\x1b");
    try std.testing.expectEqualDeep(Key.escape, input.next().?);
    try std.testing.expectEqual(@as(?Key, null), input.next());
    try std.testing.expect(input.takeEscape());
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
