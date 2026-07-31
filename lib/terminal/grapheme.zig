//! UAX #29 extended grapheme cluster segmentation and display width.
//!
//! A terminal with DECSET mode 2027 advances its cursor one grapheme cluster at
//! a time. Display width must thus be summed per cluster, not per code point.
//! This module segments UTF-8 text into clusters and measures each cluster's
//! column width. It applies the full Unicode Text Segmentation rules GB1–GB13,
//! including Indic conjunct breaks (GB9c) and emoji ZWJ sequences (GB11).
//!
//! The module offers only length: `stepAt` returns the next cluster's byte
//! length and column width. Terminal escape syntax is not this module's concern.
//! CR, LF, and the C0/C1 controls are their own `Control` clusters under the
//! rules. Display policy can thus classify them before it hands printable runs
//! here.

const std = @import("std");

const unicode_data = @import("unicode_data.zig");

pub const Step = struct { bytes: usize, columns: usize };

/// The next grapheme cluster at the start of `text`, which must be non-empty:
/// its byte length and its display width in terminal columns. Width is the
/// widest cell among the cluster's code points. A multi-code-point glyph —
/// skin-tone, ZWJ join, flag, keycap — thus measures as the one cell a
/// mode-2027 terminal renders, never the sum. Malformed or truncated UTF-8
/// yields a one-column replacement step so callers always advance.
pub fn stepAt(text: []const u8) Step {
    const first = decode(text);
    var columns = cellWidth(first.codepoint);
    var previous = classOf(first.codepoint);
    var offset = first.bytes;

    var state: State = .init(previous);
    while (offset < text.len) {
        const next = decode(text[offset..]);
        const class = classOf(next.codepoint);
        if (state.breaks(previous, class)) break;
        columns = @max(columns, cellWidth(next.codepoint));
        offset += next.bytes;
        previous = class;
        state.advance(class);
    }
    return .{ .bytes = offset, .columns = columns };
}

const replacement = 0xFFFD;

const Decoded = struct { codepoint: u21, bytes: usize };

/// The code point at the start of `text` and its byte length. A bad lead byte,
/// a sequence truncated by the buffer end, or an invalid encoding decodes to
/// the replacement character. The decode still advances at least one byte, so
/// callers never stall.
fn decode(text: []const u8) Decoded {
    const lead = text[0];
    if (lead < 0x80) return .{ .codepoint = lead, .bytes = 1 };
    const length = std.unicode.utf8ByteSequenceLength(lead) catch
        return .{ .codepoint = replacement, .bytes = 1 };
    if (text.len < length) return .{ .codepoint = replacement, .bytes = text.len };
    const codepoint = std.unicode.utf8Decode(text[0..length]) catch
        return .{ .codepoint = replacement, .bytes = length };
    return .{ .codepoint = codepoint, .bytes = length };
}

/// Terminal cell width of one code point: zero for C0/C1 controls and DEL, two
/// for East Asian wide/fullwidth and default-emoji code points, one otherwise.
/// The module forces U+FE0F to two because it promotes its cluster to emoji width.
fn cellWidth(codepoint: u21) usize {
    if (codepoint < 0x20 or codepoint == 0x7f) return 0;
    if (codepoint == 0xFE0F) return 2;
    if (codepoint < unicode_data.width_ranges[0].first) return 1;
    const range = search(unicode_data.WidthRange, &unicode_data.width_ranges, codepoint) orelse
        return 1;
    return range.columns;
}

/// Grapheme_Cluster_Break class of `codepoint`, or `.other` when it is in no
/// range of the generated table.
fn classOf(codepoint: u21) unicode_data.Class {
    // Printable ASCII carries no break class. Skip the search on the hot path.
    // The C0 controls and DEL sit below and above this range, so they still fall
    // through to the table.
    if (codepoint >= 0x20 and codepoint < 0x7f) return .other;
    const range = search(unicode_data.ClassRange, &unicode_data.class_ranges, codepoint) orelse
        return .other;
    return range.class;
}

/// The range in the sorted, non-overlapping `ranges` that contains `codepoint`,
/// or null when it falls in none.
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

/// The running state the stateful break rules need across a cluster: the length
/// of the trailing Regional_Indicator run (GB12/13), whether the tail is an
/// armed Indic conjunct with its Linker seen (GB9c), and the two stages of an
/// emoji sequence (GB11). The stages are a tail that matches
/// `Extended_Pictographic Extend*`, and that tail with one pivot `ZWJ` after it.
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

    /// Fold a code point that joined the cluster into the running state.
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
            // InCB=Extend and ZWJ can sit inside a conjunct and do not end it.
            .extend_incb, .zwj => {},
            else => {
                self.indic_armed = false;
                self.indic_linker = false;
            },
        }
        // `Extended_Pictographic Extend*` must immediately precede GB11's ZWJ,
        // so only a ZWJ folded while `pictographic` holds pivots. A second ZWJ
        // (or anything else) clears the pivot.
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

    /// Whether UAX #29 places a cluster boundary between `previous` and `next`.
    /// `self` describes the cluster up to and including `previous`.
    fn breaks(self: State, previous: unicode_data.Class, next: unicode_data.Class) bool {
        // GB3: CR × LF.
        if (previous == .cr and next == .lf) return false;
        // GB4/GB5: break around Control, CR, and LF.
        if (previous == .control or previous == .cr or previous == .lf) return true;
        if (next == .control or next == .cr or next == .lf) return true;
        // GB6/GB7/GB8: Hangul syllable composition.
        if (previous == .l and (next == .l or next == .v or next == .lv or next == .lvt))
            return false;
        if ((previous == .lv or previous == .v) and (next == .v or next == .t)) return false;
        if ((previous == .lvt or previous == .t) and next == .t) return false;
        // GB9/GB9a/GB9b: extending marks, spacing marks, prepend.
        if (isExtend(next) or next == .zwj) return false;
        if (next == .spacing_mark) return false;
        if (previous == .prepend) return false;
        // GB9c: Indic conjunct break.
        if (next == .consonant and self.indic_armed and self.indic_linker) return false;
        // GB11: emoji ZWJ sequence.
        if (self.pictographic_zwj and next == .extended_pictographic) return false;
        // GB12/GB13: keep Regional_Indicator pairs together.
        if (previous == .regional_indicator and next == .regional_indicator and
            (self.regional_indicators & 1) == 1) return false;
        // GB999.
        return true;
    }
};

test "stepAt measures single code points" {
    try std.testing.expectEqual(Step{ .bytes = 1, .columns = 1 }, stepAt("a"));
    try std.testing.expectEqual(Step{ .bytes = 2, .columns = 1 }, stepAt("é"));
    try std.testing.expectEqual(Step{ .bytes = 3, .columns = 2 }, stepAt("好"));
    try std.testing.expectEqual(Step{ .bytes = 4, .columns = 2 }, stepAt("😀"));
    // A C0 control and DEL are one-byte, zero-column clusters.
    try std.testing.expectEqual(Step{ .bytes = 1, .columns = 0 }, stepAt("\t"));
    try std.testing.expectEqual(Step{ .bytes = 1, .columns = 0 }, stepAt("\x7f"));
}

test "stepAt folds a multi-code-point cluster into one cell" {
    // Base plus combining mark: one column.
    try std.testing.expectEqual(Step{ .bytes = 3, .columns = 1 }, stepAt("e\u{0301}"));
    // Heart plus VS16 promotes to a two-cell emoji. VS15 keeps it at one.
    try std.testing.expectEqual(Step{ .bytes = 6, .columns = 2 }, stepAt("❤\u{FE0F}"));
    try std.testing.expectEqual(Step{ .bytes = 6, .columns = 1 }, stepAt("❤\u{FE0E}"));
    // A keycap — digit, VS16, enclosing keycap — is one two-column cluster.
    try std.testing.expectEqual(Step{ .bytes = 7, .columns = 2 }, stepAt("1\u{FE0F}\u{20E3}"));
    // Thumbs-up plus skin tone: eight bytes, one two-column glyph.
    try std.testing.expectEqual(Step{ .bytes = 8, .columns = 2 }, stepAt("👍\u{1F3FD}"));
    // A four-emoji ZWJ family folds into one cluster.
    const family = stepAt("👨\u{200D}👩\u{200D}👧\u{200D}👦");
    try std.testing.expectEqual(@as(usize, 2), family.columns);
    // GB11's ZWJ must sit right after the pictographic run: a doubled joiner
    // breaks, so only the first emoji and the two joiners form the cluster.
    try std.testing.expectEqual(@as(usize, 10), stepAt("😀\u{200D}\u{200D}😀").bytes);
    // Devanagari conjunct KA + virama + SSA is one cluster (GB9c).
    try std.testing.expectEqual(@as(usize, 9), stepAt("\u{0915}\u{094D}\u{0937}").bytes);
}

test "stepAt pairs regional indicators" {
    // A flag is one two-column cluster of two indicators.
    try std.testing.expectEqual(Step{ .bytes = 8, .columns = 2 }, stepAt("🇯🇵"));
    // A third indicator starts a fresh cluster after the pair.
    try std.testing.expectEqual(@as(usize, 8), stepAt("🇯🇵🇺").bytes);
}

test "stepAt survives malformed utf-8 by advancing" {
    try std.testing.expectEqual(Step{ .bytes = 1, .columns = 1 }, stepAt("\xff"));
    try std.testing.expectEqual(Step{ .bytes = 2, .columns = 1 }, stepAt("\xf0\x9f"));
    try std.testing.expectEqual(Step{ .bytes = 2, .columns = 1 }, stepAt("\xe4\xb8"));
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
        while (tokens.next()) |tok| {
            if (std.mem.eql(u8, tok, "÷")) {
                expected[expected_len] = length;
                expected_len += 1;
            } else if (std.mem.eql(u8, tok, "×")) {
                // No boundary here. The code points stay in one cluster.
            } else {
                const codepoint = try std.fmt.parseInt(u21, tok, 16);
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
    // Guard against a vacuous pass on a truncated or all-comment corpus.
    try std.testing.expect(checked > 400);
}
