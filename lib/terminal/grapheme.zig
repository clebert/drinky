const std = @import("std");

const unicode_data = @import("unicode_data.zig");

const Step = struct { bytes: usize, columns: usize };

const malformed: Step = .{ .bytes = 1, .columns = 1 };

const Decoded = struct { codepoint: u21, bytes: usize };

const State = struct {
    regional_indicators: usize = 0,
    indic_armed: bool = false,
    indic_linker: bool = false,
    pictographic: bool = false,
    pictographic_zwj: bool = false,

    fn init(first: unicode_data.Class) State {
        var self: State = .{};
        self.advance(first);
        return self;
    }

    fn advance(self: *State, class: unicode_data.Class) void {
        self.regional_indicators =
            if (class == .regional_indicator) self.regional_indicators + 1 else 0;
        switch (class) {
            .consonant => {
                self.indic_armed = true;
                self.indic_linker = false;
            },
            .linker => if (self.indic_armed) {
                self.indic_linker = true;
            },
            .extend_incb, .zwj => {},
            else => {
                self.indic_armed = false;
                self.indic_linker = false;
            },
        }
        if (class == .extended_pictographic) {
            self.pictographic = true;
            self.pictographic_zwj = false;
        } else if (class == .zwj) {
            self.pictographic_zwj = self.pictographic;
            self.pictographic = false;
        } else if (self.pictographic and isExtend(class)) {
            self.pictographic_zwj = false;
        } else {
            self.pictographic = false;
            self.pictographic_zwj = false;
        }
    }

    fn breaks(self: State, previous: unicode_data.Class, next: unicode_data.Class) bool {
        if (previous == .cr and next == .lf) return false;
        if (previous == .control or previous == .cr or previous == .lf) return true;
        if (next == .control or next == .cr or next == .lf) return true;
        if (previous == .l and (next == .l or next == .v or next == .lv or next == .lvt))
            return false;
        if ((previous == .lv or previous == .v) and (next == .v or next == .t)) return false;
        if ((previous == .lvt or previous == .t) and next == .t) return false;
        if (isExtend(next) or next == .zwj) return false;
        if (next == .spacing_mark) return false;
        if (previous == .prepend) return false;
        if (next == .consonant and self.indic_armed and self.indic_linker) return false;
        if (self.pictographic_zwj and next == .extended_pictographic) return false;
        if (previous == .regional_indicator and next == .regional_indicator and
            (self.regional_indicators & 1) == 1) return false;
        return true;
    }
};

pub fn stepAt(text: []const u8) Step {
    const first = decode(text) orelse return malformed;
    var columns = cellWidth(first.codepoint);
    var previous = classOf(first.codepoint);
    var offset = first.bytes;

    var state: State = .init(previous);
    while (offset < text.len) {
        const next = decode(text[offset..]) orelse break;
        const class = classOf(next.codepoint);
        if (state.breaks(previous, class)) break;
        columns = @max(columns, cellWidth(next.codepoint));
        offset += next.bytes;
        previous = class;
        state.advance(class);
    }
    return .{ .bytes = offset, .columns = columns };
}

pub fn startsJoining(text: []const u8) bool {
    if (text.len == 0) return false;
    const first = decode(text) orelse return false;
    return switch (classOf(first.codepoint)) {
        .extend, .extend_incb, .linker, .zwj, .spacing_mark, .regional_indicator, .v, .t => true,
        else => false,
    };
}

pub fn endsJoining(text: []const u8) bool {
    var tail = text;
    while (decodeLast(tail)) |last| {
        switch (classOf(last.codepoint)) {
            .prepend, .zwj, .linker, .l => return true,
            .extend_incb => tail = tail[0 .. tail.len - last.bytes],
            else => return false,
        }
    }
    return false;
}

fn decodeLast(text: []const u8) ?Decoded {
    const limit = text.len -| 4;
    var offset = text.len;
    while (offset > limit) {
        offset -= 1;
        const lead = text[offset];
        if (lead & 0xc0 == 0x80) continue;
        const length = std.unicode.utf8ByteSequenceLength(lead) catch return null;
        if (offset + length != text.len) return null;
        const codepoint = std.unicode.utf8Decode(text[offset..]) catch return null;
        return .{ .codepoint = codepoint, .bytes = length };
    }
    return null;
}

fn decode(text: []const u8) ?Decoded {
    const lead = text[0];
    if (lead < 0x80) return .{ .codepoint = lead, .bytes = 1 };
    const length = std.unicode.utf8ByteSequenceLength(lead) catch return null;
    if (text.len < length) return null;
    const codepoint = std.unicode.utf8Decode(text[0..length]) catch return null;
    return .{ .codepoint = codepoint, .bytes = length };
}

fn cellWidth(codepoint: u21) usize {
    if (codepoint < 0x20 or codepoint == 0x7f) return 0;
    if (codepoint == 0xFE0F) return 2;
    if (codepoint < unicode_data.width_ranges[0].first) return 1;
    const range = search(unicode_data.WidthRange, &unicode_data.width_ranges, codepoint) orelse
        return 1;
    return range.columns;
}

fn classOf(codepoint: u21) unicode_data.Class {
    if (codepoint >= 0x20 and codepoint < 0x7f) return .other;
    const range = search(unicode_data.ClassRange, &unicode_data.class_ranges, codepoint) orelse
        return .other;
    return range.class;
}

fn search(comptime Range: type, ranges: []const Range, codepoint: u21) ?Range {
    const order = struct {
        fn order(context: u21, range: Range) std.math.Order {
            if (context < range.first) return .lt;
            return if (context > range.last) .gt else .eq;
        }
    }.order;
    const index = std.sort.binarySearch(Range, ranges, codepoint, order) orelse return null;
    return ranges[index];
}

fn isExtend(class: unicode_data.Class) bool {
    return class == .extend or class == .extend_incb or class == .linker;
}

test "stepAt measures single code points" {
    try std.testing.expectEqual(Step{ .bytes = 1, .columns = 1 }, stepAt("a"));
    try std.testing.expectEqual(Step{ .bytes = 2, .columns = 1 }, stepAt("é"));
    try std.testing.expectEqual(Step{ .bytes = 3, .columns = 2 }, stepAt("好"));
    try std.testing.expectEqual(Step{ .bytes = 4, .columns = 2 }, stepAt("😀"));
    try std.testing.expectEqual(Step{ .bytes = 1, .columns = 0 }, stepAt("\t"));
    try std.testing.expectEqual(Step{ .bytes = 1, .columns = 0 }, stepAt("\x7f"));
}

test "a soft hyphen keeps one column, and a joining jamo or a zero-width space takes none" {
    try std.testing.expectEqual(Step{ .bytes = 2, .columns = 1 }, stepAt("\u{00AD}"));
    try std.testing.expectEqual(Step{ .bytes = 3, .columns = 0 }, stepAt("\u{1160}"));
    try std.testing.expectEqual(Step{ .bytes = 3, .columns = 0 }, stepAt("\u{11FF}"));
    try std.testing.expectEqual(Step{ .bytes = 3, .columns = 0 }, stepAt("\u{200B}"));
}

test "stepAt folds a multi-code-point cluster into one cell" {
    try std.testing.expectEqual(Step{ .bytes = 3, .columns = 1 }, stepAt("e\u{0301}"));
    try std.testing.expectEqual(Step{ .bytes = 6, .columns = 2 }, stepAt("❤\u{FE0F}"));
    try std.testing.expectEqual(Step{ .bytes = 6, .columns = 1 }, stepAt("❤\u{FE0E}"));
    try std.testing.expectEqual(Step{ .bytes = 7, .columns = 2 }, stepAt("1\u{FE0F}\u{20E3}"));
    try std.testing.expectEqual(Step{ .bytes = 8, .columns = 2 }, stepAt("👍\u{1F3FD}"));
    const family = stepAt("👨\u{200D}👩\u{200D}👧\u{200D}👦");
    try std.testing.expectEqual(@as(usize, 2), family.columns);
    try std.testing.expectEqual(@as(usize, 10), stepAt("😀\u{200D}\u{200D}😀").bytes);
    try std.testing.expectEqual(@as(usize, 9), stepAt("\u{0915}\u{094D}\u{0937}").bytes);
}

test "stepAt pairs regional indicators" {
    try std.testing.expectEqual(Step{ .bytes = 8, .columns = 2 }, stepAt("🇯🇵"));
    try std.testing.expectEqual(@as(usize, 8), stepAt("🇯🇵🇺").bytes);
}

test "stepAt takes one byte for a malformed byte and ends a cluster before it" {
    try std.testing.expectEqual(malformed, stepAt("\xff"));
    try std.testing.expectEqual(malformed, stepAt("\xf0\x9f"));
    try std.testing.expectEqual(malformed, stepAt("\xe4\xb8"));
    try std.testing.expectEqual(malformed, stepAt("\xe4AB"));
    try std.testing.expectEqual(stepAt("\u{0D4E}"), stepAt("\u{0D4E}\xff"));
    try std.testing.expectEqual(@as(usize, 4), stepAt("\u{0D4E}a").bytes);
}

test startsJoining {
    try std.testing.expect(startsJoining("\u{0301}"));
    try std.testing.expect(startsJoining("\u{FE0F}"));
    try std.testing.expect(startsJoining("\u{200D}👩"));
    try std.testing.expect(startsJoining("\u{0903}"));
    try std.testing.expect(startsJoining("🇵🇹"));
    try std.testing.expect(startsJoining("\u{1160}"));
    try std.testing.expect(startsJoining("\u{11A8}"));
    try std.testing.expect(!startsJoining(""));
    try std.testing.expect(!startsJoining("a"));
    try std.testing.expect(!startsJoining("😀"));
    try std.testing.expect(!startsJoining("\u{200B}"));
    try std.testing.expect(!startsJoining("\u{1100}"));
}

test endsJoining {
    try std.testing.expect(endsJoining("\u{0D4E}"));
    try std.testing.expect(endsJoining("👨\u{200D}"));
    try std.testing.expect(endsJoining("\u{0915}\u{094D}"));
    try std.testing.expect(endsJoining("\u{1100}"));
    try std.testing.expect(endsJoining("\u{0915}\u{094D}\u{0300}"));
    try std.testing.expect(!endsJoining(""));
    try std.testing.expect(!endsJoining("ab"));
    try std.testing.expect(!endsJoining("👍\u{1F3FD}"));
    try std.testing.expect(!endsJoining("\u{200B}"));
    try std.testing.expect(!endsJoining("e\u{0301}"));
    try std.testing.expect(!endsJoining("❤\u{FE0F}"));
    try std.testing.expect(!endsJoining("\xf0\x9f"));
}

test "UAX #29 grapheme cluster boundaries match the conformance corpus" {
    const corpus = @embedFile("GraphemeBreakTest.txt");
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var line_number: usize = 0;
    var checked: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..hash], " \t\r");
        if (line.len == 0) continue;

        var text: [1024]u8 = undefined;
        var length: usize = 0;
        var expected: [128]usize = undefined;
        var expected_len: usize = 0;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                expected[expected_len] = length;
                expected_len += 1;
            } else if (std.mem.eql(u8, token, "×")) {} else {
                const codepoint = try std.fmt.parseInt(u21, token, 16);
                length += try std.unicode.utf8Encode(codepoint, text[length..]);
            }
        }

        var produced: [128]usize = undefined;
        var produced_len: usize = 0;
        produced[produced_len] = 0;
        produced_len += 1;
        var offset: usize = 0;
        while (offset < length) {
            offset += stepAt(text[offset..length]).bytes;
            produced[produced_len] = offset;
            produced_len += 1;
        }

        std.testing.expectEqualSlices(
            usize,
            expected[0..expected_len],
            produced[0..produced_len],
        ) catch |err| {
            std.debug.print("grapheme corpus line {d}: {s}\n", .{ line_number, line });
            return err;
        };
        checked += 1;
    }
    try std.testing.expect(checked > 400);
}
