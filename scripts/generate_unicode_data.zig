const std = @import("std");

const version = "17.0.0";
const base = "https://www.unicode.org/Public/" ++ version ++ "/ucd";
const license_url = "https://www.unicode.org/license.txt";
const output_path = "lib/terminal/unicode_data.zig";
const test_output_path = "lib/terminal/GraphemeBreakTest.txt";
const license_output_path = "lib/terminal/UNICODE_LICENSE";
const codepoint_max = 0x10FFFF;

const WidthRange = struct { first: u21, last: u21, columns: u8 };
const Bounds = struct { first: u21, last: u21 };

const Class = enum {
    other,
    cr,
    lf,
    control,
    extend,
    extend_incb,
    linker,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
    extended_pictographic,
    consonant,
};
const ClassRange = struct { first: u21, last: u21, class: Class };

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const categories = try fetch(arena, &client, base ++ "/extracted/DerivedGeneralCategory.txt");
    const east_asian = try fetch(arena, &client, base ++ "/EastAsianWidth.txt");
    const emoji = try fetch(arena, &client, base ++ "/emoji/emoji-data.txt");

    const zero = try arena.alloc(bool, codepoint_max + 1);
    @memset(zero, false);
    mark(categories, &.{ "Mn", "Me", "Cf" }, zero);
    zero[0x00AD] = false;
    for (0x1160..0x1200) |codepoint| zero[codepoint] = true;
    zero[0x200B] = true;

    const wide = try arena.alloc(bool, codepoint_max + 1);
    @memset(wide, false);
    mark(east_asian, &.{ "W", "F" }, wide);
    mark(emoji, &.{"Emoji_Presentation"}, wide);

    const width_ranges = try coalesce(arena, zero, wide);

    const grapheme_break = try fetch(
        arena,
        &client,
        base ++ "/auxiliary/GraphemeBreakProperty.txt",
    );
    const derived = try fetch(arena, &client, base ++ "/DerivedCoreProperties.txt");

    const classes = try arena.alloc(Class, codepoint_max + 1);
    @memset(classes, .other);
    assignGraphemeBreak(grapheme_break, classes);
    const pictographic = try arena.alloc(bool, codepoint_max + 1);
    @memset(pictographic, false);
    mark(emoji, &.{"Extended_Pictographic"}, pictographic);
    for (0..codepoint_max + 1) |codepoint| {
        if (pictographic[codepoint] and classes[codepoint] == .other) {
            classes[codepoint] = .extended_pictographic;
        }
    }
    assignIndicConjunct(derived, classes);
    const class_ranges = try coalesceClasses(arena, classes);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(&out.writer, width_ranges, class_ranges);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });

    const break_test = try fetch(arena, &client, base ++ "/auxiliary/GraphemeBreakTest.txt");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = test_output_path, .data = break_test });

    const license = try fetch(arena, &client, license_url);
    var notice: std.Io.Writer.Allocating = .init(arena);
    try notice.writer.print(license_header, .{version});
    try notice.writer.writeAll(license);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = license_output_path,
        .data = notice.written(),
    });

    std.debug.print(
        "wrote {s}: {d} width ranges, {d} grapheme classes from Unicode {s}\n",
        .{ output_path, width_ranges.len, class_ranges.len, version },
    );
    std.debug.print("wrote {s}\n", .{test_output_path});
    std.debug.print("wrote {s}\n", .{license_output_path});
}

fn fetch(arena: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]const u8 {
    var response: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response.writer,
    });
    if (result.status != .ok) {
        std.debug.print("fetch {s} returned {d}\n", .{ url, @intFromEnum(result.status) });
        return error.FetchFailed;
    }
    return response.written();
}

fn mark(text: []const u8, wanted: []const []const u8, flags: []bool) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, before(raw, '#'), " \t\r");
        if (line.len == 0) continue;
        const semicolon = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const field = std.mem.trim(u8, line[0..semicolon], " \t");
        const value = token(std.mem.trim(u8, line[semicolon + 1 ..], " \t"));
        if (!contains(wanted, value)) continue;
        const bounds = parseRange(field) orelse continue;
        if (bounds.first > codepoint_max) continue;
        const last = @min(bounds.last, codepoint_max);
        for (bounds.first..last + 1) |codepoint| flags[codepoint] = true;
    }
}

fn coalesce(arena: std.mem.Allocator, zero: []const bool, wide: []const bool) ![]WidthRange {
    var width_ranges: std.ArrayList(WidthRange) = .empty;
    var open: ?WidthRange = null;
    for (0..codepoint_max + 1) |codepoint| {
        const columns: u8 = if (zero[codepoint]) 0 else if (wide[codepoint]) 2 else 1;
        if (columns == 1) {
            if (open) |range| try width_ranges.append(arena, range);
            open = null;
            continue;
        }
        if (open) |*range| {
            if (range.columns == columns) {
                range.last = @intCast(codepoint);
                continue;
            }
            try width_ranges.append(arena, range.*);
        }
        open = .{ .first = @intCast(codepoint), .last = @intCast(codepoint), .columns = columns };
    }
    if (open) |range| try width_ranges.append(arena, range);
    return width_ranges.toOwnedSlice(arena);
}

fn assignGraphemeBreak(text: []const u8, classes: []Class) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, before(raw, '#'), " \t\r");
        if (line.len == 0) continue;
        const semicolon = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const field = std.mem.trim(u8, line[0..semicolon], " \t");
        const value = token(std.mem.trim(u8, line[semicolon + 1 ..], " \t"));
        const class = graphemeBreakClass(value) orelse continue;
        const bounds = parseRange(field) orelse continue;
        if (bounds.first > codepoint_max) continue;
        const last = @min(bounds.last, codepoint_max);
        for (bounds.first..last + 1) |codepoint| classes[codepoint] = class;
    }
}

fn graphemeBreakClass(value: []const u8) ?Class {
    const table = .{
        .{ "CR", Class.cr },
        .{ "LF", Class.lf },
        .{ "Control", Class.control },
        .{ "Extend", Class.extend },
        .{ "ZWJ", Class.zwj },
        .{ "Regional_Indicator", Class.regional_indicator },
        .{ "Prepend", Class.prepend },
        .{ "SpacingMark", Class.spacing_mark },
        .{ "L", Class.l },
        .{ "V", Class.v },
        .{ "T", Class.t },
        .{ "LV", Class.lv },
        .{ "LVT", Class.lvt },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, value, entry[0])) return entry[1];
    }
    return null;
}

fn assignIndicConjunct(text: []const u8, classes: []Class) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, before(raw, '#'), " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const field = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const property = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const value = std.mem.trim(u8, fields.next() orelse continue, " \t");
        if (!std.mem.eql(u8, property, "InCB")) continue;
        const bounds = parseRange(field) orelse continue;
        if (bounds.first > codepoint_max) continue;
        const last = @min(bounds.last, codepoint_max);
        for (bounds.first..last + 1) |codepoint| {
            if (std.mem.eql(u8, value, "Linker")) {
                if (classes[codepoint] == .extend) classes[codepoint] = .linker;
            } else if (std.mem.eql(u8, value, "Extend")) {
                if (classes[codepoint] == .extend) classes[codepoint] = .extend_incb;
            } else if (std.mem.eql(u8, value, "Consonant")) {
                if (classes[codepoint] == .other) classes[codepoint] = .consonant;
            }
        }
    }
}

fn coalesceClasses(arena: std.mem.Allocator, classes: []const Class) ![]ClassRange {
    var ranges: std.ArrayList(ClassRange) = .empty;
    var open: ?ClassRange = null;
    for (0..codepoint_max + 1) |codepoint| {
        const class = classes[codepoint];
        if (class == .other) {
            if (open) |range| try ranges.append(arena, range);
            open = null;
            continue;
        }
        if (open) |*range| {
            if (range.class == class) {
                range.last = @intCast(codepoint);
                continue;
            }
            try ranges.append(arena, range.*);
        }
        open = .{ .first = @intCast(codepoint), .last = @intCast(codepoint), .class = class };
    }
    if (open) |range| try ranges.append(arena, range);
    return ranges.toOwnedSlice(arena);
}

fn emit(
    writer: *std.Io.Writer,
    width_ranges: []const WidthRange,
    class_ranges: []const ClassRange,
) !void {
    try writer.writeAll(width_section);
    for (width_ranges) |range| try writer.print(
        "    .{{ .first = 0x{x:0>4}, .last = 0x{x:0>4}, .columns = {d} }},\n",
        .{ range.first, range.last, range.columns },
    );
    try writer.writeAll("};\n");
    try writer.writeAll(class_section);
    for (class_ranges) |range| try writer.print(
        "    .{{ .first = 0x{x:0>4}, .last = 0x{x:0>4}, .class = .{s} }},\n",
        .{ range.first, range.last, @tagName(range.class) },
    );
    try writer.writeAll("};\n");
}

fn before(text: []const u8, byte: u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, byte) orelse text.len];
}

fn token(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfAny(u8, text, " \t") orelse text.len];
}

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn parseRange(field: []const u8) ?Bounds {
    if (std.mem.indexOf(u8, field, "..")) |dots| {
        const first = parseHex(field[0..dots]) orelse return null;
        const last = parseHex(field[dots + 2 ..]) orelse return null;
        return .{ .first = first, .last = last };
    }
    const only = parseHex(field) orelse return null;
    return .{ .first = only, .last = only };
}

fn parseHex(text: []const u8) ?u21 {
    return std.fmt.parseInt(u21, std.mem.trim(u8, text, " \t"), 16) catch null;
}

const license_header =
    \\The tables in unicode_data.zig and the corpus in GraphemeBreakTest.txt derive from the Unicode
    \\Character Database, version {s}. Unicode, Inc. distributes the data under the license below.
    \\
    \\
;

const width_section =
    \\pub const WidthRange = struct { first: u21, last: u21, columns: u8 };
    \\
    \\pub const width_ranges = [_]WidthRange{
    \\
;

const class_section =
    \\
    \\pub const Class = enum {
    \\    other,
    \\    cr,
    \\    lf,
    \\    control,
    \\    extend,
    \\    extend_incb,
    \\    linker,
    \\    zwj,
    \\    regional_indicator,
    \\    prepend,
    \\    spacing_mark,
    \\    l,
    \\    v,
    \\    t,
    \\    lv,
    \\    lvt,
    \\    extended_pictographic,
    \\    consonant,
    \\};
    \\
    \\pub const ClassRange = struct { first: u21, last: u21, class: Class };
    \\
    \\pub const class_ranges = [_]ClassRange{
    \\
;
