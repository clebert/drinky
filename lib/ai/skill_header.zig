//! Parses the YAML front matter subset used by `SKILL.md` metadata. This is
//! intentionally not a general-purpose YAML parser.

const std = @import("std");

pub const Parsed = struct {
    /// Borrows the source passed to `parse`.
    name: ?[]const u8,
    /// Owned; released by `deinit`.
    description: ?[]u8,
    model_invocation_disabled: bool,

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        if (self.description) |description| gpa.free(description);
        self.* = undefined;
    }
};

pub fn parse(gpa: std.mem.Allocator, data: []const u8) !Parsed {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const first = trimLine(lines.next() orelse return error.MissingFrontmatter);
    if (!frontmatterFence(first)) return error.MissingFrontmatter;

    var name: ?[]const u8 = null;
    var description_seen = false;
    var model_invocation_disabled = false;
    var closed = false;
    var description: std.Io.Writer.Allocating = .init(gpa);
    errdefer description.deinit();

    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (frontmatterFence(line)) {
            closed = true;
            break;
        }
        // A description consumes its own continuation lines, so any blank or
        // indented line reaching the mapping loop belongs to nothing.
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;

        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (std.mem.eql(u8, key, "name")) {
            if (name == null and value.len > 0) name = scalarValue(value);
        } else if (std.mem.eql(u8, key, "description")) {
            if (description_seen) continue;
            description_seen = true;
            try collectDescription(&lines, value, &description.writer);
        } else if (std.mem.eql(u8, key, "disable-model-invocation")) {
            model_invocation_disabled = std.ascii.eqlIgnoreCase(scalarValue(value), "true");
        }
    }
    if (!closed) return error.UnclosedFrontmatter;

    return .{
        .name = name,
        .description = if (description_seen) try description.toOwnedSlice() else null,
        .model_invocation_disabled = model_invocation_disabled,
    };
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

const Scalar = struct {
    value: []const u8,
    quote: ?u8 = null,
};

fn frontmatterFence(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return false;
    return std.mem.eql(u8, scalarValue(std.mem.trimEnd(u8, line, " \t")), "---");
}

fn scalar(value: []const u8) Scalar {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return .{ .value = "" };
    const quote = trimmed[0];
    if (quote == '"' or quote == '\'') {
        var index: usize = 1;
        while (index < trimmed.len) {
            if (quote == '"' and trimmed[index] == '\\' and index + 1 < trimmed.len) {
                index += 2;
                continue;
            }
            if (trimmed[index] == quote) {
                if (quote == '\'' and index + 1 < trimmed.len and trimmed[index + 1] == '\'') {
                    index += 2;
                    continue;
                }
                return .{ .value = trimmed[1..index], .quote = quote };
            }
            index += 1;
        }
        return .{ .value = trimmed[1..], .quote = quote };
    }
    for (trimmed, 0..) |byte, index| {
        if (byte == '#' and (index == 0 or std.ascii.isWhitespace(trimmed[index - 1]))) {
            return .{ .value = std.mem.trimEnd(u8, trimmed[0..index], " \t") };
        }
    }
    return .{ .value = trimmed };
}

fn scalarValue(value: []const u8) []const u8 {
    return scalar(value).value;
}

const BlockHeader = struct {
    mode: Mode,
    indent: ?usize,

    const Mode = enum { literal, folded };
};

/// Parse a block scalar header — `|`/`>` with an optional 1-9 indentation
/// indicator and -/+ chomping indicator, each once, in either order. Returns
/// null when the value is a plain scalar that merely starts with `>` or `|`.
/// Only reached for unquoted values, so a quoted `"|"` is never a block header.
fn blockHeader(value: []const u8) ?BlockHeader {
    if (value.len == 0) return null;
    const mode: BlockHeader.Mode = switch (value[0]) {
        '|' => .literal,
        '>' => .folded,
        else => return null,
    };
    var indent: ?usize = null;
    var chomping_seen = false;
    for (value[1..]) |byte| switch (byte) {
        '1'...'9' => {
            if (indent != null) return null;
            indent = byte - '0';
        },
        '-', '+' => {
            if (chomping_seen) return null;
            chomping_seen = true;
        },
        else => return null,
    };
    return .{ .mode = mode, .indent = indent };
}

fn appendDescription(writer: *std.Io.Writer, raw: []const u8) !void {
    const part = scalar(raw);
    if (part.value.len == 0) return;
    if (writer.end > 0) try writer.writeByte(' ');
    switch (part.quote orelse return writer.writeAll(part.value)) {
        '"' => try writeDoubleQuoted(writer, part.value),
        '\'' => try writeSingleQuoted(writer, part.value),
        else => unreachable,
    }
}

/// Read a single front matter scalar into `out`, applying YAML line folding,
/// and leave `lines` positioned on the first line that is not part of the
/// scalar. Handles the scalar styles skill descriptions use — plain,
/// single/double quoted (each possibly multi-line), and literal/folded block —
/// and is not a general YAML parser.
fn collectDescription(
    lines: *std.mem.SplitIterator(u8, .scalar),
    first_value: []const u8,
    out: *std.Io.Writer,
) !void {
    if (first_value.len > 0 and (first_value[0] == '"' or first_value[0] == '\'')) {
        return collectQuoted(lines, first_value, out);
    }
    // Detect the block header on the comment-stripped value so a legal trailing
    // `# comment` on `|`/`>` is ignored rather than demoting it to a plain scalar.
    if (blockHeader(scalarValue(first_value))) |header| return collectBlock(lines, header, out);
    return collectPlain(lines, first_value, out);
}

fn collectPlain(
    lines: *std.mem.SplitIterator(u8, .scalar),
    first_value: []const u8,
    out: *std.Io.Writer,
) !void {
    try appendDescription(out, first_value);
    while (true) {
        const resume_index = lines.index;
        const line = trimLine(lines.next() orelse break);
        if (line.len == 0) continue;
        if (line[0] != ' ' and line[0] != '\t') {
            lines.index = resume_index;
            break;
        }
        const part = std.mem.trim(u8, line, " \t");
        if (part.len > 0 and part[0] != '#') try appendDescription(out, part);
    }
}

fn collectQuoted(
    lines: *std.mem.SplitIterator(u8, .scalar),
    first_value: []const u8,
    out: *std.Io.Writer,
) !void {
    const quote = first_value[0];
    const first_content = first_value[1..];
    if (flowClose(first_content, quote)) |end| {
        return writeQuoted(out, first_content[0..end], quote);
    }

    var started = false;
    var breaks: usize = 0;
    const opening = std.mem.trimEnd(u8, first_content, " \t");
    if (opening.len > 0) {
        try writeQuoted(out, opening, quote);
        started = true;
    }
    while (true) {
        const resume_index = lines.index;
        const line = trimLine(lines.next() orelse break);
        if (line.len == 0) {
            breaks += 1;
            continue;
        }
        if (line[0] != ' ' and line[0] != '\t') {
            // Unterminated quote: hand the mapping loop its key or closing fence
            // back and keep the partial value rather than reject the skill.
            lines.index = resume_index;
            break;
        }
        const content = std.mem.trimStart(u8, line, " \t");
        if (content.len == 0) {
            breaks += 1;
            continue;
        }
        if (flowClose(content, quote)) |end| {
            if (end > 0) {
                try foldSeparator(out, &started, &breaks);
                try writeQuoted(out, content[0..end], quote);
            }
            return;
        }
        try foldSeparator(out, &started, &breaks);
        try writeQuoted(out, std.mem.trimEnd(u8, content, " \t"), quote);
    }
}

fn collectBlock(
    lines: *std.mem.SplitIterator(u8, .scalar),
    header: BlockHeader,
    out: *std.Io.Writer,
) !void {
    var base_indent = header.indent;
    var started = false;
    while (true) {
        const resume_index = lines.index;
        const line = trimLine(lines.next() orelse break);
        const indent = leadingWhitespace(line);
        const blank = indent == line.len;
        if (!blank) {
            if (indent == 0) {
                lines.index = resume_index;
                break;
            }
            if (base_indent) |base| {
                if (indent < base) {
                    lines.index = resume_index;
                    break;
                }
            } else base_indent = indent;
        } else if (!started) continue;
        const strip = if (base_indent) |base| @min(base, indent) else 0;
        const content = if (blank) "" else line[strip..];
        if (started) switch (header.mode) {
            .literal => try out.writeByte('\n'),
            .folded => if (content.len == 0) {
                try out.writeByte('\n');
            } else if (out.end > 0 and out.buffer[out.end - 1] != '\n') {
                try out.writeByte(' ');
            },
        };
        try out.writeAll(content);
        started = true;
    }
}

/// Index of the closing `quote` in a quoted scalar's content, honoring `\`
/// escapes in double quotes and `''` in single quotes, or null when the quote
/// stays open past this line.
fn flowClose(content: []const u8, quote: u8) ?usize {
    var index: usize = 0;
    while (index < content.len) {
        const byte = content[index];
        if (quote == '"' and byte == '\\' and index + 1 < content.len) {
            index += 2;
            continue;
        }
        if (byte == quote) {
            if (quote == '\'' and index + 1 < content.len and content[index + 1] == '\'') {
                index += 2;
                continue;
            }
            return index;
        }
        index += 1;
    }
    return null;
}

/// Emit the fold between two flow-scalar lines: nothing before the first
/// content line, a space across a single line break, and one newline per blank
/// line otherwise.
fn foldSeparator(out: *std.Io.Writer, started: *bool, breaks: *usize) !void {
    if (!started.*) {
        started.* = true;
    } else if (breaks.* == 0) {
        try out.writeByte(' ');
    } else for (0..breaks.*) |_| try out.writeByte('\n');
    breaks.* = 0;
}

fn writeQuoted(out: *std.Io.Writer, value: []const u8, quote: u8) !void {
    switch (quote) {
        '"' => try writeDoubleQuoted(out, value),
        '\'' => try writeSingleQuoted(out, value),
        else => unreachable,
    }
}

fn leadingWhitespace(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
    return index;
}

fn writeDoubleQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (byte != '\\' or index + 1 == value.len) {
            try writer.writeByte(byte);
            index += 1;
            continue;
        }
        const escaped = value[index + 1];
        index += 2;
        switch (escaped) {
            '0' => try writer.writeByte(0),
            'a' => try writer.writeByte(0x07),
            'b' => try writer.writeByte(0x08),
            't' => try writer.writeByte('\t'),
            'n' => try writer.writeByte('\n'),
            'v' => try writer.writeByte(0x0b),
            'f' => try writer.writeByte(0x0c),
            'r' => try writer.writeByte('\r'),
            'e' => try writer.writeByte(0x1b),
            ' ' => try writer.writeByte(' '),
            '"' => try writer.writeByte('"'),
            '/' => try writer.writeByte('/'),
            '\\' => try writer.writeByte('\\'),
            'N' => try writer.writeAll("\u{85}"),
            '_' => try writer.writeAll("\u{a0}"),
            'L' => try writer.writeAll("\u{2028}"),
            'P' => try writer.writeAll("\u{2029}"),
            'x', 'u', 'U' => {
                const width: usize = switch (escaped) {
                    'x' => 2,
                    'u' => 4,
                    else => 8,
                };
                if (writeHexEscape(writer, value[index..], width)) |consumed| {
                    index += consumed;
                } else |_| {
                    // Malformed hex escape: keep the source bytes verbatim.
                    try writer.writeByte('\\');
                    try writer.writeByte(escaped);
                }
            },
            else => {
                try writer.writeByte('\\');
                try writer.writeByte(escaped);
            },
        }
    }
}

fn writeHexEscape(writer: *std.Io.Writer, rest: []const u8, width: usize) !usize {
    if (rest.len < width) return error.InvalidEscape;
    var codepoint: u32 = 0;
    for (rest[0..width]) |character| {
        const digit = std.fmt.charToDigit(character, 16) catch return error.InvalidEscape;
        codepoint = codepoint * 16 + digit;
    }
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff))
        return error.InvalidEscape;
    var buffer: [4]u8 = undefined;
    const encoded = std.unicode.utf8Encode(@intCast(codepoint), &buffer) catch
        return error.InvalidEscape;
    try writer.writeAll(buffer[0..encoded]);
    return width;
}

fn writeSingleQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '\'' and index + 1 < value.len and value[index + 1] == '\'') {
            try writer.writeByte('\'');
            index += 2;
        } else {
            try writer.writeByte(value[index]);
            index += 1;
        }
    }
}

test "parses multiline descriptions and invocation policy" {
    var parsed = try parse(std.testing.allocator, "---\r\n" ++
        "name: example-skill\r\n" ++
        "description:\r\n" ++
        "  Handles examples and\r\n" ++
        "  explains when to use them.\r\n" ++
        "disable-model-invocation: true\r\n" ++
        "---\r\n" ++
        "# Example\r\n");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("example-skill", parsed.name.?);
    try std.testing.expectEqualStrings(
        "Handles examples and explains when to use them.",
        parsed.description.?,
    );
    try std.testing.expect(parsed.model_invocation_disabled);
}

test "handles inline comments and quoted escapes" {
    var parsed = try parse(std.testing.allocator, "--- # frontmatter\n" ++
        "name: quoted\n" ++
        "description: \"Use # tags and \\\"quotes\\\".\" # metadata comment\n" ++
        "disable-model-invocation: true # explicit only\n" ++
        "--- # end\n" ++
        "body\n");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("quoted", parsed.name.?);
    try std.testing.expectEqualStrings("Use # tags and \"quotes\".", parsed.description.?);
    try std.testing.expect(parsed.model_invocation_disabled);
}

test "preserves block scalar content" {
    var literal = try parse(std.testing.allocator, "---\n" ++
        "name: literal\n" ++
        "description: |-\n" ++
        "  # literal heading\n" ++
        "  Use \"quotes\" # literally\n" ++
        "---\n");
    defer literal.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "# literal heading\nUse \"quotes\" # literally",
        literal.description.?,
    );

    var folded = try parse(std.testing.allocator, "---\n" ++
        "name: folded\n" ++
        "description: >-\n" ++
        "  First # literally\n" ++
        "  \"second\"\n" ++
        "---\n");
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("First # literally \"second\"", folded.description.?);
}

test "decodes unicode escapes and indented block headers" {
    var quoted = try parse(std.testing.allocator, "---\n" ++
        "name: escapes\n" ++
        "description: \"em\\u2014dash, tab\\tstop, and \\x41\"\n" ++
        "---\n");
    defer quoted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("em\u{2014}dash, tab\tstop, and A", quoted.description.?);

    var folded = try parse(std.testing.allocator, "---\n" ++
        "name: folded\n" ++
        "description: >2-\n" ++
        "  first\n" ++
        "  second\n" ++
        "---\n");
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("first second", folded.description.?);
}

test "folds multi-line flow scalars and never reads a quote as a block header" {
    const gpa = std.testing.allocator;

    var wrapped = try parse(gpa, "---\n" ++
        "name: wrapped\n" ++
        "description: \"Extract PDFs and\n" ++
        "  use when forms are mentioned.\"\n" ++
        "---\n");
    defer wrapped.deinit(gpa);
    try std.testing.expectEqualStrings(
        "Extract PDFs and use when forms are mentioned.",
        wrapped.description.?,
    );

    var pipe = try parse(gpa, "---\nname: pipe\ndescription: \"|\"\n---\n");
    defer pipe.deinit(gpa);
    try std.testing.expectEqualStrings("|", pipe.description.?);

    var single = try parse(gpa, "---\n" ++
        "name: single\n" ++
        "description: 'it''s a\n" ++
        "  multi-line value'\n" ++
        "---\n");
    defer single.deinit(gpa);
    try std.testing.expectEqualStrings("it's a multi-line value", single.description.?);
}

test "literal block scalars preserve relative indentation" {
    var parsed = try parse(std.testing.allocator, "---\n" ++
        "name: literal\n" ++
        "description: |-\n" ++
        "  line one\n" ++
        "    indented\n" ++
        "  line three\n" ++
        "---\n");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("line one\n  indented\nline three", parsed.description.?);
}

test "block headers tolerate a trailing comment" {
    var parsed = try parse(std.testing.allocator, "---\n" ++
        "name: commented\n" ++
        "description: |- # header comment\n" ++
        "  body line\n" ++
        "---\n");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("body line", parsed.description.?);
}

test "requires both fences" {
    try std.testing.expectError(
        error.MissingFrontmatter,
        parse(std.testing.allocator, "name: nope\n"),
    );
    try std.testing.expectError(
        error.UnclosedFrontmatter,
        parse(std.testing.allocator, "---\nname: nope\n"),
    );
}
