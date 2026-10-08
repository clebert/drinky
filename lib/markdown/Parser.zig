const std = @import("std");

const Parser = @This();

text: []const u8,
events: *[events_max]Event,
events_len: usize = 0,
delimiters: [delimiters_max]Delimiter = undefined,
delimiters_len: usize = 0,
brackets: [brackets_max]Bracket = undefined,
brackets_len: usize = 0,

pub const Event = struct {
    at: usize,
    style: Style,
    side: Side,

    pub const Style = enum { emphasis, strong, strike, link };
    pub const Side = enum { open, close };

    pub fn width(self: Event) usize {
        return switch (self.style) {
            .emphasis => 1,
            .strong, .strike => 2,
            .link => unreachable,
        };
    }

    fn before(_: void, left: Event, right: Event) bool {
        return left.at < right.at;
    }
};

pub const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
    after: usize,

    pub const Kind = enum { literal, escape, code, url };
};

pub const Destination = struct {
    url: []const u8,
    after: usize,
};

pub const events_max = 256;

const delimiters_max = 256;

const brackets_max = 64;

const code_run_max = 8;

const parentheses_max = 32;

pub const token_starts = "`\\<hH";

const Delimiter = struct {
    byte: u8,
    count: usize,
    start: usize,
    end: usize,
    can_open: bool,
    can_close: bool,
    removed: bool = false,
};

const Bracket = struct {
    at: usize,
    bottom: usize,
    active: bool = true,
};

pub fn run(self: *Parser) usize {
    const text = self.text;
    var index: usize = 0;
    while (std.mem.findAnyPos(u8, text, index, token_starts ++ "*_~[]")) |found| {
        index = switch (text[found]) {
            '*', '_', '~' => self.pushDelimiter(found),
            '[' => self.pushBracket(found),
            ']' => self.closeBracket(found),
            else => if (tokenAt(text, found)) |token| token.after else found + 1,
        };
    }
    self.emphasize(0);
    std.sort.insertion(Event, self.events[0..self.events_len], {}, Event.before);
    return self.events_len;
}

fn pushDelimiter(self: *Parser, at: usize) usize {
    const text = self.text;
    const byte = text[at];
    const end = runEnd(text, at, byte);
    if (byte == '~' and end - at != 2) return end;
    if (self.delimiters_len == delimiters_max) return end;
    const before: u8 = if (at > 0) text[at - 1] else ' ';
    const after: u8 = if (end < text.len) text[end] else ' ';
    const left = flanks(&.{ .inner = after, .outer = before });
    const right = flanks(&.{ .inner = before, .outer = after });
    const can_open = left and (byte != '_' or !right or std.ascii.isPunctuation(before));
    const can_close = right and (byte != '_' or !left or std.ascii.isPunctuation(after));
    if (!can_open and !can_close) return end;
    self.delimiters[self.delimiters_len] = .{
        .byte = byte,
        .count = end - at,
        .start = at,
        .end = end,
        .can_open = can_open,
        .can_close = can_close,
    };
    self.delimiters_len += 1;
    return end;
}

fn pushBracket(self: *Parser, at: usize) usize {
    if (self.brackets_len == brackets_max) {
        std.mem.copyForwards(Bracket, self.brackets[0 .. brackets_max - 1], self.brackets[1..]);
        self.brackets_len -= 1;
    }
    self.brackets[self.brackets_len] = .{ .at = at, .bottom = self.delimiters_len };
    self.brackets_len += 1;
    return at + 1;
}

fn closeBracket(self: *Parser, at: usize) usize {
    if (self.brackets_len == 0) return at + 1;
    self.brackets_len -= 1;
    const bracket = self.brackets[self.brackets_len];
    if (!bracket.active) return at + 1;
    const destination = destinationAt(self.text, at + 1) orelse return at + 1;
    const added = self.add(&.{
        .{ .at = bracket.at, .style = .link, .side = .open },
        .{ .at = at, .style = .link, .side = .close },
    });
    if (!added) return at + 1;
    self.emphasize(bracket.bottom);
    for (self.brackets[0..self.brackets_len]) |*earlier| earlier.active = false;
    return destination.after;
}

fn emphasize(self: *Parser, bottom: usize) void {
    var openers_bottom: [3][2][3]usize = @splat(@splat(@splat(bottom)));
    var closer_index = bottom;
    while (closer_index < self.delimiters_len) {
        const closer = &self.delimiters[closer_index];
        if (closer.removed or !closer.can_close) {
            closer_index += 1;
            continue;
        }
        const byte_index: usize = switch (closer.byte) {
            '*' => 0,
            '_' => 1,
            '~' => 2,
            else => unreachable,
        };
        const opens: usize = @intFromBool(closer.can_open);
        const lowest = &openers_bottom[byte_index][opens][closer.count % 3];
        if (self.openerFor(&.{ .closer = closer_index, .lowest = lowest.* })) |opener_index| {
            if (!self.pair(&.{ .opener = opener_index, .closer = closer_index })) break;
            if (closer.start == closer.end) {
                closer.removed = true;
                closer_index += 1;
            }
        } else {
            lowest.* = closer_index;
            if (!closer.can_open) closer.removed = true;
            closer_index += 1;
        }
    }
    self.delimiters_len = bottom;
}

fn openerFor(
    self: *const Parser,
    search: *const struct { closer: usize, lowest: usize },
) ?usize {
    const closer = &self.delimiters[search.closer];
    var index = search.closer;
    while (index > search.lowest) {
        index -= 1;
        const opener = &self.delimiters[index];
        if (opener.removed or !opener.can_open or opener.byte != closer.byte) continue;
        const both = closer.can_open or opener.can_close;
        const multiple = closer.count % 3 != 0 and (opener.count + closer.count) % 3 == 0;
        if (!(both and multiple)) return index;
    }
    return null;
}

fn pair(self: *Parser, indices: *const struct { opener: usize, closer: usize }) bool {
    const opener = &self.delimiters[indices.opener];
    const closer = &self.delimiters[indices.closer];
    const strong = opener.end - opener.start >= 2 and closer.end - closer.start >= 2;
    const style: Event.Style = if (opener.byte == '~')
        .strike
    else if (strong)
        .strong
    else
        .emphasis;
    const closed: Event = .{ .at = closer.start, .style = style, .side = .close };
    const width = closed.width();
    if (!self.add(&.{ .{ .at = opener.end - width, .style = style, .side = .open }, closed })) {
        return false;
    }
    opener.end -= width;
    closer.start += width;
    for (self.delimiters[indices.opener + 1 .. indices.closer]) |*between| {
        between.removed = true;
    }
    if (opener.start == opener.end) opener.removed = true;
    return true;
}

fn add(self: *Parser, events: *const [2]Event) bool {
    if (self.events_len + events.len > events_max) return false;
    self.events[self.events_len..][0..events.len].* = events.*;
    self.events_len += events.len;
    return true;
}

pub fn tokenAt(text: []const u8, index: usize) ?Token {
    return switch (text[index]) {
        '`' => codeAt(text, index),
        '\\' => escapeAt(text, index),
        '<' => angleAt(text, index),
        'h', 'H' => urlAt(text, index),
        else => unreachable,
    };
}

fn codeAt(text: []const u8, index: usize) Token {
    const start = runEnd(text, index, '`');
    const plain: Token = .{ .kind = .literal, .start = index, .end = start, .after = start };
    if (start - index > code_run_max) return plain;
    var at = start;
    while (std.mem.findScalarPos(u8, text, at, '`')) |end| {
        const after = runEnd(text, end, '`');
        if (after - end == start - index) {
            const content = text[start..end];
            const padded = content[0] == ' ' and content[content.len - 1] == ' ' and
                std.mem.findNone(u8, content, " ") != null;
            const padding: usize = if (padded) 1 else 0;
            return .{
                .kind = .code,
                .start = start + padding,
                .end = end - padding,
                .after = after,
            };
        }
        at = after;
    }
    return plain;
}

pub fn escapeAt(text: []const u8, index: usize) ?Token {
    if (index + 1 >= text.len or !std.ascii.isPunctuation(text[index + 1])) return null;
    return .{ .kind = .escape, .start = index + 1, .end = index + 2, .after = index + 2 };
}

fn angleAt(text: []const u8, index: usize) ?Token {
    const start = index + 1;
    var at = start;
    while (at < text.len and isSchemeByte(text[at])) at += 1;
    const scheme = at - start;
    if (scheme < 2 or scheme > 32 or !std.ascii.isAlphabetic(text[start])) return null;
    if (at >= text.len or text[at] != ':') return null;
    while (at < text.len) : (at += 1) {
        const byte = text[at];
        if (byte == '>') return .{ .kind = .url, .start = start, .end = at, .after = at + 1 };
        if (byte == '<' or byte <= ' ') return null;
    }
    return null;
}

fn isSchemeByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '.' or byte == '-';
}

fn urlAt(text: []const u8, index: usize) ?Token {
    if (index > 0 and isWord(text[index - 1])) return null;
    const rest = text[index..];
    const scheme = for ([_][]const u8{ "https://", "http://" }) |candidate| {
        if (std.ascii.startsWithIgnoreCase(rest, candidate)) break candidate.len;
    } else return null;
    var span: usize = 0;
    var depth: usize = 0;
    while (span < rest.len and rest[span] > ' ' and rest[span] != '<') : (span += 1) {
        if (rest[span] == '[') depth += 1;
        if (rest[span] == ']') {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    const length = urlLength(rest[0..span]);
    if (length <= scheme) return null;
    return .{ .kind = .url, .start = index, .end = index + length, .after = index + length };
}

pub fn destinationAt(text: []const u8, index: usize) ?Destination {
    if (index >= text.len or text[index] != '(') return null;
    var at = blankEnd(text, index + 1);
    var url: []const u8 = undefined;
    if (at < text.len and text[at] == '<') {
        const start = at + 1;
        at = start;
        while (at < text.len and text[at] != '>') : (at += 1) {
            if (text[at] == '<') return null;
            if (text[at] == '\\' and escapeAt(text, at) != null) at += 1;
        }
        if (at >= text.len) return null;
        url = text[start..at];
        at += 1;
    } else {
        const start = at;
        var depth: usize = 0;
        while (at < text.len) : (at += 1) {
            const byte = text[at];
            if (byte <= ' ' or byte == 0x7f) break;
            if (byte == '\\' and escapeAt(text, at) != null) {
                at += 1;
            } else if (byte == '(') {
                depth += 1;
                if (depth > parentheses_max) return null;
            } else if (byte == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        if (depth > 0) return null;
        url = text[start..at];
    }
    const url_after = at;
    at = blankEnd(text, at);
    if (at > url_after and at < text.len) {
        if (titleEnd(text, at)) |title_after| at = blankEnd(text, title_after);
    }
    if (at >= text.len or text[at] != ')') return null;
    return .{ .url = url, .after = at + 1 };
}

fn titleEnd(text: []const u8, at: usize) ?usize {
    const closer: u8 = switch (text[at]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var index = at + 1;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\\') {
            index += 1;
        } else if (byte == closer) {
            return index + 1;
        } else if (closer == ')' and byte == '(') {
            return null;
        }
    }
    return null;
}

fn blankEnd(text: []const u8, at: usize) usize {
    return std.mem.findNonePos(u8, text, at, " \t") orelse text.len;
}

fn flanks(sides: *const struct { inner: u8, outer: u8 }) bool {
    if (std.ascii.isWhitespace(sides.inner)) return false;
    if (!std.ascii.isPunctuation(sides.inner)) return true;
    return std.ascii.isWhitespace(sides.outer) or std.ascii.isPunctuation(sides.outer);
}

fn runEnd(text: []const u8, at: usize, byte: u8) usize {
    return std.mem.findNonePos(u8, text, at, &.{byte}) orelse text.len;
}

const url_trailing = ".,:;!?'\"*_~";

fn urlLength(url: []const u8) usize {
    var opened: usize = 0;
    var closed: usize = 0;
    for (url) |byte| {
        if (byte == '(') opened += 1;
        if (byte == ')') closed += 1;
    }
    var length = url.len;
    while (length > 0) {
        const last = url[length - 1];
        if (last == ')') {
            if (closed <= opened) break;
            closed -= 1;
        } else if (std.mem.findScalar(u8, url_trailing, last) == null) {
            break;
        }
        length -= 1;
    }
    return length;
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
