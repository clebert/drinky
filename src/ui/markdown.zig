//! Markdown rendering for the model-authored transcript blocks. `rows` and
//! `render` run one `walk` over the source, parameterized on a comptime emitter,
//! so measure and paint break rows in exactly the same places — the parity the
//! window math asserts. Nothing allocates: every span is a slice of the source
//! or a static literal, streamed straight into the sink a row at a time.

const std = @import("std");

const terminal = @import("terminal");

const color = @import("color.zig");
const paint = @import("paint.zig");

/// Blanks to slice indents and marker-width continuations from; its length caps
/// how far a nested list can push its body.
const blanks = " " ** 32;

const rule_cell = "─";

/// How wide a horizontal rule is drawn at most, however wide the terminal is.
const rule_columns = 80;

const rule_cells = rule_cell ** rule_columns;

/// One span's look: the element foreground a reasoning tint replaces, plus the
/// attributes that survive it.
const Look = struct {
    foreground: ?color.Style = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
};

const accent_look: Look = .{ .foreground = .accent_foreground };
const code_look: Look = .{ .foreground = .code_block };
const muted_look: Look = .{ .foreground = .muted_foreground };
const quote_look: Look = .{ .foreground = .muted_foreground, .italic = true };
const link_look: Look = .{ .foreground = .link, .underline = true };

/// Physical rows the markdown in `text` occupies at `columns`.
pub fn rows(text: []const u8, columns: usize) usize {
    var counter: Counter = .{};
    walk(Counter, &counter, text, @max(columns, 1)) catch unreachable;
    return counter.count;
}

/// Compose the markdown in `text` through `placement`. `tint` — set for
/// reasoning — replaces every span's foreground and italicizes the whole block,
/// so the structure still reads while the color stays uniformly muted.
pub fn render(placement: *const paint.Placement, tint: ?color.Style, text: []const u8) !void {
    var painter: Painter = .{ .placement = placement, .tint = tint, .line = placement.base };
    try walk(Painter, &painter, text, @max(placement.columns, 1));
}

/// Tallies rows for `rows`. It holds no sink, so nothing it does can fail.
const Counter = struct {
    count: usize = 0,

    fn begin(_: *Counter) void {}
    fn span(_: *Counter, _: Look, _: []const u8) !void {}
    fn end(self: *Counter) void {
        self.count += 1;
    }
};

/// Paints rows for `render`, dropping those in the clipped top the way
/// `paint.framedRow` does: the row is never opened, only counted past.
const Painter = struct {
    placement: *const paint.Placement,
    tint: ?color.Style,
    line: usize,
    hidden: bool = false,

    fn begin(self: *Painter) void {
        self.hidden = self.line < self.placement.skip;
        if (!self.hidden) self.placement.sink.begin();
    }

    fn span(self: *Painter, look: Look, bytes: []const u8) !void {
        if (self.hidden or bytes.len == 0) return;
        const sink = self.placement.sink;
        const foreground = self.tint orelse look.foreground;
        const italic = look.italic or self.tint != null;
        if (foreground) |style| try color.apply(sink, style);
        if (look.bold) try color.apply(sink, .bold);
        if (italic) try color.apply(sink, .italic);
        if (look.underline) try color.apply(sink, .underline);
        if (look.strike) try color.apply(sink, .strikethrough);
        try sink.text(bytes);
        if (foreground != null or look.bold or italic or look.underline or look.strike) {
            try color.apply(sink, .reset);
        }
    }

    fn end(self: *Painter) void {
        defer self.line += 1;
        if (!self.hidden) self.placement.sink.end(.{ .id = self.placement.id, .line = self.line });
    }
};

/// Emit `text` one physical row at a time. Every row break is decided here and
/// the emitter merely follows, so the count and the paint cannot diverge.
fn walk(comptime Emitter: type, emitter: *Emitter, text: []const u8, columns: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var fenced = false;
    while (lines.next()) |line| {
        const rest = line[leading(line)..];
        if (std.mem.startsWith(u8, rest, "```")) {
            // A fence toggles the mode; an unclosed one just runs to the end.
            fenced = !fenced;
            try plainRow(Emitter, emitter, columns, "", muted_look, line);
        } else if (fenced) {
            // Code keeps its alignment: indent and truncate, never re-wrap.
            try plainRow(Emitter, emitter, columns, blank(2), code_look, line);
        } else if (isBlank(rest)) {
            emitter.begin();
            emitter.end();
        } else if (isRule(rest)) {
            const cells = rule_cells[0 .. rule_cell.len * @min(columns, rule_columns)];
            try plainRow(Emitter, emitter, columns, "", muted_look, cells);
        } else if (headingLevel(rest)) |level| {
            // H1 and H2 shed their marker; deeper ones keep it, as pi does.
            const body = if (level > 2) rest else std.mem.trimStart(u8, rest[level..], " ");
            var flow = Flow(Emitter).init(emitter, columns, .{});
            try inlines(Emitter, &flow, .{
                .foreground = .heading,
                .bold = true,
                .underline = level == 1,
            }, body);
            try flow.finish();
            // Set a heading off from what follows, unless a blank already does.
            const parted = if (lines.peek()) |next| isBlank(next) else true;
            if (!parted) {
                emitter.begin();
                emitter.end();
            }
        } else if (rest[0] == '>') {
            var body = rest;
            while (body.len > 0 and body[0] == '>') {
                body = body[1..];
                if (body.len > 0 and body[0] == ' ') body = body[1..];
            }
            var flow = Flow(Emitter).init(emitter, columns, .{
                .marker = "│ ",
                .look = muted_look,
                .repeat = true,
            });
            try inlines(Emitter, &flow, quote_look, body);
            try flow.finish();
        } else if (listMarker(rest)) |marker| {
            // Sources nest a list two spaces a level; pi indents four.
            const depth: usize = @min(@divFloor(leading(line), 2), 4);
            var flow = Flow(Emitter).init(emitter, columns, .{
                .indent = blank(depth * 4),
                .marker = marker.shown,
                .look = accent_look,
            });
            var body = rest[marker.source..];
            if (taskBox(body)) |box| {
                try flow.write(accent_look, box);
                body = body[box.len..];
            }
            try inlines(Emitter, &flow, .{}, body);
            try flow.finish();
        } else {
            // A paragraph keeps its own indentation; only markers are stripped.
            var flow = Flow(Emitter).init(emitter, columns, .{});
            try inlines(Emitter, &flow, .{}, line);
            try flow.finish();
        }
    }
}

/// The prefix every physical row of one logical line carries: `indent` blank
/// columns, then `marker` — drawn on the first row, on every row for a
/// blockquote's border (`repeat`), and replaced by blanks under a list bullet.
const Prefix = struct {
    indent: []const u8 = "",
    marker: []const u8 = "",
    look: Look = .{},
    repeat: bool = false,
};

/// Streams one logical line's spans into physical rows: opens a row with the
/// prefix, fills the width left over, and reopens on the next row when a span
/// runs past it, carrying its style along.
fn Flow(comptime Emitter: type) type {
    return struct {
        emitter: *Emitter,
        /// The prefix as it is actually drawn — cut to `prefixRoom` up front, so
        /// the columns the body budget gives up are columns the sink shows.
        prefix: Prefix,
        budget: usize,
        used: usize = 0,
        open: bool = false,
        first: bool = true,

        fn init(emitter: *Emitter, columns: usize, prefix: Prefix) @This() {
            var shown = prefix;
            shown.marker = terminal.width.truncate(prefix.marker, prefixRoom(columns));
            const left = prefixRoom(columns) -| terminal.width.ofText(shown.marker);
            shown.indent = terminal.width.truncate(prefix.indent, left);
            // A prefix that still outgrew the window would leave no budget and
            // stall the wrap; one column always carries the row forward.
            return .{
                .emitter = emitter,
                .prefix = shown,
                .budget = @max(columns -| prefixColumns(&shown), 1),
            };
        }

        /// Place `bytes` under `look`, continuing on the next row when the width
        /// runs out. `truncate` always yields at least one cluster against a
        /// budget of one, so a row can never fail to advance.
        fn write(self: *@This(), look: Look, bytes: []const u8) !void {
            var rest = bytes;
            while (true) {
                try self.openRow();
                const room = self.budget -| self.used;
                const shown = terminal.width.truncate(rest, room);
                const shown_columns = terminal.width.ofText(shown);
                // Saturating: a cluster wider than `room` survives `truncate` as
                // a one-column replacement. Give it the next row whole first, as
                // the plain wrap does, and settle for the replacement only once a
                // row of its own is still too narrow.
                if (shown_columns > room and self.used > 0) {
                    self.closeRow();
                    continue;
                }
                if (shown.len > 0) {
                    try self.emitter.span(look, shown);
                    self.used += shown_columns;
                    rest = rest[shown.len..];
                }
                if (rest.len == 0) return;
                self.closeRow();
            }
        }

        /// Close the last row; a line with no content still occupies one.
        fn finish(self: *@This()) !void {
            try self.openRow();
            self.closeRow();
        }

        fn openRow(self: *@This()) !void {
            if (self.open) return;
            self.emitter.begin();
            self.open = true;
            self.used = 0;
            try self.emitter.span(.{}, self.prefix.indent);
            if (self.first or self.prefix.repeat) {
                try self.emitter.span(self.prefix.look, self.prefix.marker);
            } else {
                try self.emitter.span(.{}, blank(terminal.width.ofText(self.prefix.marker)));
            }
            self.first = false;
        }

        fn closeRow(self: *@This()) void {
            self.emitter.end();
            self.open = false;
        }
    };
}

/// Columns a row's prefix may take: never more than half of them, so the body it
/// pushes right keeps room the sink will actually show. Uncapped, a marker or
/// border as wide as a narrow window would swallow the text behind it — the
/// source would advance while the sink clipped every byte of it.
fn prefixRoom(columns: usize) usize {
    return columns -| @max(@divFloor(columns, 2), 1);
}

fn prefixColumns(prefix: *const Prefix) usize {
    return terminal.width.ofText(prefix.indent) + terminal.width.ofText(prefix.marker);
}

/// One row that never wraps: `indent`, then `bytes` cut to the width left over.
fn plainRow(
    comptime Emitter: type,
    emitter: *Emitter,
    columns: usize,
    indent: []const u8,
    look: Look,
    bytes: []const u8,
) !void {
    const shown = terminal.width.truncate(indent, prefixRoom(columns));
    const room = columns -| terminal.width.ofText(shown);
    emitter.begin();
    try emitter.span(.{}, shown);
    try emitter.span(look, terminal.width.truncate(bytes, room));
    emitter.end();
}

/// An inline run: the styled slice its markers enclose, plus the URL a link
/// appends when its label does not already show it.
const Run = struct { look: Look, content: []const u8, url: []const u8 = "", end: usize };

/// Inline markers, each doubled form before the single one that prefixes it.
const marks = [_]struct { mark: []const u8, look: Look }{
    .{ .mark = "**", .look = .{ .bold = true } },
    .{ .mark = "__", .look = .{ .bold = true } },
    .{ .mark = "~~", .look = .{ .strike = true } },
    .{ .mark = "*", .look = .{ .italic = true } },
    .{ .mark = "_", .look = .{ .italic = true } },
};

/// A memoized forward scan for one closing byte. Openers are visited in source
/// order, so the closer found for one still answers the next, and a scan that
/// found nothing can never succeed later. Without the memo a line of unmatched
/// `[` rescans its tail once per bracket, and a long one costs quadratic time
/// every frame. Only a link needs this: a marker that closes on the bytes it
/// opens with runs out of openers as soon as one scan fails.
const Closer = struct {
    byte: u8,
    at: ?usize = null,
    spent: bool = false,

    fn find(self: *Closer, text: []const u8, from: usize) ?usize {
        if (self.spent) return null;
        if (self.at == null or self.at.? < from) {
            self.at = std.mem.indexOfScalarPos(u8, text, from, self.byte);
            self.spent = self.at == null;
        }
        return self.at;
    }
};

/// The two closers a `[label](url)` is scanned for, memoized across one line.
const Link = struct { label: Closer = .{ .byte = ']' }, url: Closer = .{ .byte = ')' } };

/// Place `text`'s inline runs into `flow` under `base`, slicing the markers away.
/// A marker whose closer has not streamed in yet stays literal.
fn inlines(comptime Emitter: type, flow: *Flow(Emitter), base: Look, text: []const u8) !void {
    var start: usize = 0;
    var index: usize = 0;
    var link: Link = .{};
    while (index < text.len) : (index += 1) {
        const run = runAt(text, index, &link) orelse {
            // A doubled marker with no closer stays literal whole: its second
            // byte must not reopen as a single one and split `**bold` into a
            // stray asterisk and an italic run mid-stream.
            if (doubled(text, index)) index += 1;
            continue;
        };
        try flow.write(base, text[start..index]);
        try flow.write(merged(base, run.look), run.content);
        if (run.url.len > 0) {
            const trailing = merged(base, muted_look);
            try flow.write(trailing, " (");
            try flow.write(trailing, run.url);
            try flow.write(trailing, ")");
        }
        index = run.end - 1;
        start = run.end;
    }
    try flow.write(base, text[start..]);
}

/// The inline run opening at `index`, or null when none does.
fn runAt(text: []const u8, index: usize, link: *Link) ?Run {
    const rest = text[index..];
    if (rest[0] == '`') {
        const close = std.mem.indexOfScalarPos(u8, text, index + 1, '`') orelse return null;
        if (close == index + 1) return null;
        return .{ .look = accent_look, .content = text[index + 1 .. close], .end = close + 1 };
    }
    if (rest[0] == '[') return linkAt(text, index, link);
    for (marks) |entry| {
        if (!std.mem.startsWith(u8, rest, entry.mark)) continue;
        // An underscore inside a word is an identifier, not emphasis.
        if (entry.mark[0] == '_' and index > 0 and isWord(text[index - 1])) return null;
        const open = index + entry.mark.len;
        const close = std.mem.indexOfPos(u8, text, open, entry.mark) orelse continue;
        const content = text[open..close];
        if (content.len == 0) continue;
        // Emphasis opens and closes tight, so spaced arithmetic stays literal.
        if (content[0] == ' ' or content[content.len - 1] == ' ') continue;
        const after = close + entry.mark.len;
        if (entry.mark[0] == '_' and after < text.len and isWord(text[after])) continue;
        return .{ .look = entry.look, .content = content, .end = after };
    }
    return null;
}

/// A doubled marker opening at `index`, whose second byte must not be re-read as
/// a single-byte opener.
fn doubled(text: []const u8, index: usize) bool {
    for (marks) |entry| {
        if (entry.mark.len == 2 and std.mem.startsWith(u8, text[index..], entry.mark)) return true;
    }
    return false;
}

/// The `[label](url)` link at `index`, or null when the shape is incomplete.
fn linkAt(text: []const u8, index: usize, link: *Link) ?Run {
    const close = link.label.find(text, index + 1) orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const end = link.url.find(text, close + 2) orelse return null;
    const label = text[index + 1 .. close];
    const url = text[close + 2 .. end];
    return .{
        .look = link_look,
        .content = if (label.len > 0) label else url,
        // The URL is worth appending only when the label is not already it.
        .url = if (label.len == 0 or std.mem.eql(u8, label, url)) "" else url,
        .end = end + 1,
    };
}

/// An element style over its context: the inner foreground wins, attributes add up.
fn merged(base: Look, over: Look) Look {
    return .{
        .foreground = over.foreground orelse base.foreground,
        .bold = base.bold or over.bold,
        .italic = base.italic or over.italic,
        .underline = base.underline or over.underline,
        .strike = base.strike or over.strike,
    };
}

/// The list marker at the head of `rest`: the bytes it spans in the source and
/// what to draw — a normalized `- ` for a bullet, the source digits for an
/// ordered item, so a list numbered from anything but one keeps its numbering.
const Marker = struct { source: usize, shown: []const u8 };

fn listMarker(rest: []const u8) ?Marker {
    if ((rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and
        (rest.len == 1 or rest[1] == ' '))
    {
        return .{ .source = @min(rest.len, 2), .shown = "- " };
    }
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits == 0 or digits == rest.len) return null;
    if (rest[digits] != '.' and rest[digits] != ')') return null;
    if (digits + 1 < rest.len and rest[digits + 1] != ' ') return null;
    const source = @min(rest.len, digits + 2);
    return .{ .source = source, .shown = rest[0..source] };
}

/// The `[ ] ` or `[x] ` checkbox opening a task item's body.
fn taskBox(body: []const u8) ?[]const u8 {
    if (body.len < 3 or body[0] != '[' or body[2] != ']') return null;
    if (body[1] != ' ' and body[1] != 'x' and body[1] != 'X') return null;
    if (body.len > 3 and body[3] != ' ') return null;
    return body[0..@min(body.len, 4)];
}

/// The heading level `rest` opens with, or null when it opens none.
fn headingLevel(rest: []const u8) ?usize {
    var level: usize = 0;
    while (level < rest.len and rest[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < rest.len and rest[level] != ' ') return null;
    return level;
}

/// A `---`, `***`, or `___` rule: three or more of one mark and nothing else.
fn isRule(rest: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, rest, " \t\r");
    if (trimmed.len < 3) return false;
    const mark = trimmed[0];
    if (mark != '-' and mark != '*' and mark != '_') return false;
    for (trimmed) |byte| if (byte != mark) return false;
    return true;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn leading(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and line[index] == ' ') index += 1;
    return index;
}

fn blank(count: usize) []const u8 {
    return blanks[0..@min(count, blanks.len)];
}

// Every element of the supported subset, ending on a heading no newline has
// followed yet — what a stream shows the instant the model writes one.
const sample =
    \\# Heading one
    \\Plain **bold**, *italic*, ~~struck~~, and `inline code` in a paragraph that
    \\runs past the narrow test widths.
    \\
    \\## Heading **two**
    \\### Heading three
    \\- first bullet
    \\  - nested bullet with enough words to wrap somewhere
    \\- [ ] a task
    \\3. numbered from three
    \\4. and on
    \\
    \\> a quoted line long enough to wrap under its border
    \\
    \\---
    \\
    \\```zig
    \\const answer = 42;
    \\```
    \\
    \\A [labelled](https://example.com) link and a bare [x](x) one, plus a
    \\snake_case_name that is no emphasis.
    \\
    \\#### heading with no trailing newline
;

// Markers a stream has not finished writing: the renderer must leave them
// literal rather than assert or miscount.
const partial =
    \\a dangling ** and a half-typed [link](
    \\```zig
    \\an unclosed fence runs to the end of the block
;

// Rows `text` paints into a fresh view, dropping its top `skip`; the caller owns
// the returned bytes. Fresh so the paint is a full reprint whose rows count.
fn painted(
    gpa: std.mem.Allocator,
    text: []const u8,
    columns: usize,
    tint: ?color.Style,
    skip: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 2000 }, 1);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = columns, .base = 0, .skip = skip };
    try render(&placement, tint, text);
    try view.render();
    return gpa.dupe(u8, out.written());
}

fn paintedRows(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\r\n") + 1;
}

// The parity contract: what `rows` counts is exactly what `render` emits, at
// widths down to one column — where a list marker or a quote border alone
// already fills the row.
test "markdown renders exactly the rows it counts" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ sample, partial, "", "\n\n" }) |text| {
        for ([_]usize{ 72, 40, 16, 3, 2, 1 }) |columns| {
            for ([_]?color.Style{ null, .muted_foreground }) |tint| {
                const bytes = try painted(gpa, text, columns, tint, 0);
                defer gpa.free(bytes);
                try std.testing.expectEqual(rows(text, columns), paintedRows(bytes));
            }
        }
    }
}

// Each element carries its own look, and the markers that produced it are gone.
test "markdown paints each element in its own style" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, sample, 72, null, 0);
    defer gpa.free(bytes);

    // H1 is a bold, underlined heading color with its marker gone; H3 keeps it.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;240;198;116m\x1b[1m\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Heading one") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "# Heading one") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "### Heading three") != null);
    // A heading's emphasis is a span of its own — the sink's boundary marks the
    // split — and the heading's own look still carries it.
    const emphasis = "\x1b[38;2;240;198;116m\x1b[1m\u{200b}two";
    try std.testing.expect(std.mem.indexOf(u8, bytes, emphasis) != null);
    // Code keeps its two-space indent and its own color; the fence stays muted.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;181;189;104m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "  \x1b[38;2;181;189;104m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "const answer = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;128;128;128m```zig") != null);
    // A bullet takes the accent, a quote its border, and a rule its cells.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;138;190;183m- ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;128;128;128m│ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "──") != null);
    // An ordered list keeps the number it started from, and a task its box.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "3. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[ ] ") != null);
    // A link is underlined in blue and appends the URL its label hides.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;129;162;190m\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "https://example.com") != null);
    // Inline markers are sliced away — in a heading as much as a paragraph —
    // while `_` inside a word is not emphasis at all.
    const literal = [_][]const u8{ "**", "~~", "*italic*", "`inline code`", "[labelled]" };
    for (literal) |mark| try std.testing.expect(std.mem.indexOf(u8, bytes, mark) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1m\u{200b}bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "snake_case_name") != null);
}

// A prefix never crowds the body out of the row: at two columns a bullet and a
// quote border give a column back, so the text still shows instead of the
// source advancing behind a sink that clips every byte of it.
test "a prefix leaves room for the body it pushes right" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "- abc", "> abc", "    - abc" }) |text| {
        // One column is the floor: the prefix drops away entirely rather than
        // take the only column the body has.
        for ([_]usize{ 1, 2 }) |columns| {
            const bytes = try painted(gpa, text, columns, null, 0);
            defer gpa.free(bytes);
            for ("abc") |letter| {
                try std.testing.expect(std.mem.indexOfScalar(u8, bytes, letter) != null);
            }
        }
    }
}

// A wide cluster that will not fit the columns left takes the next row whole,
// as the plain wrap does, rather than the one-column replacement a fitted write
// would leave in its place.
test "a styled wide glyph wraps rather than degrading" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "abc**你**", 4, null, 0);
    defer gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 2), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "你") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "�") == null);
}

// Mid-stream, `**bold` has not closed yet: it must stay literal whole rather
// than shed its first byte and flicker the rest as italic for a frame.
test "an unclosed bold marker stays literal" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, "**bold*", 40, null, 0);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "**bold*") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[3m") == null);
}

// Adversarial: every `[` scans for a closer, so unmatched brackets once rescanned
// the tail one time each — quadratic in both passes, on every frame. The memo is
// what makes the scan linear, so pin it directly: a second call is answered from
// the memo even when the text it is handed would say otherwise. The long line
// then renders as a canary — a rescan turns this test from milliseconds to
// minutes.
test "a line of unmatched brackets scans its tail once" {
    var missing: Closer = .{ .byte = ']' };
    try std.testing.expect(missing.find("[[[", 1) == null);
    try std.testing.expect(missing.find("[]]", 1) == null);
    var hit: Closer = .{ .byte = ']' };
    try std.testing.expectEqual(@as(?usize, 3), hit.find("[[[]", 1));
    try std.testing.expectEqual(@as(?usize, 3), hit.find("xxxx", 2));

    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, '[', 20_000);
    // `[](` reaches past the label to the url scan, whose closer is missing too.
    for (0..10_000) |_| try text.appendSlice(gpa, "[](");

    const bytes = try painted(gpa, text.items, 80, null, 0);
    defer gpa.free(bytes);
    try std.testing.expectEqual(rows(text.items, 80), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[[[") != null);
}

// Reasoning reads as one muted, italic block: the tint replaces every element
// color, while the attributes and the structural markers stay.
test "a tinted block renders grey and italic throughout" {
    const gpa = std.testing.allocator;
    const bytes = try painted(gpa, sample, 72, .muted_foreground, 0);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;240;198;116m") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;181;189;104m") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;138;190;183m") == null);
    // A heading is still bold, and the bullet is still there — just grey.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38;2;128;128;128m\x1b[1m\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "- ") != null);
}

// Parity again, over markers stitched together at random — the half-formed
// shapes a stream produces that a fixture never thinks to spell out. A row the
// count did not predict trips the sink's own assertions, so this pins the
// renderer against the input it cannot enumerate.
test "markdown holds row parity over arbitrary marker soup" {
    const gpa = std.testing.allocator;
    // Block markers, inline markers, and the text they wrap; the clusters wider
    // than one column are what a width budget has to saturate against.
    const tokens = [_][]const u8{
        "#",   "##",     "###### ", "- ",   "* ", "1. ", "12) ", ">",           ">> ", "---",
        "```", "```zig", "**",      "*",    "_",  "__",  "~~",   "`",           "[",   "]",
        "(",   ")",      "[x] ",    "[ ] ", "\n", " ",   "  ",   "https://x.y", "a",   "word",
        "\t",  "\x1b",   "\xff",
    } ++ [_][]const u8{ "你", "😀", "e\u{0301}" };
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..400) |_| {
        text.clearRetainingCapacity();
        for (0..random.uintLessThan(usize, 40)) |_| {
            try text.appendSlice(gpa, tokens[random.uintLessThan(usize, tokens.len)]);
        }
        for ([_]usize{ 1, 2, 3, 5, 9, 40, 100 }) |columns| {
            const bytes = try painted(gpa, text.items, columns, null, 0);
            defer gpa.free(bytes);
            try std.testing.expectEqual(rows(text.items, columns), paintedRows(bytes));
        }
    }
}

// The clip drops its top `skip` rows without materializing them.
test "a clipped markdown block shows its bottom rows" {
    const gpa = std.testing.allocator;
    const columns = 40;
    const total = rows(sample, columns);
    const bytes = try painted(gpa, sample, columns, null, total - 4);
    defer gpa.free(bytes);

    try std.testing.expectEqual(@as(usize, 4), paintedRows(bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Heading one") == null);
}
