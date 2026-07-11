//! Regenerates lib/terminal/unicode.zig from the Unicode Character Database.
//!
//! Fetches a pinned Unicode version's UCD files and emits one sorted, disjoint
//! interval table mapping code point ranges to a display width of zero or two;
//! a code point in no range is one column. Width zero is General_Category Mn,
//! Me, or Cf (minus U+00AD, plus U+1160..U+11FF and U+200B); width two is
//! East_Asian_Width Wide or Fullwidth plus Emoji_Presentation, minus the
//! width-zero set. Run with `zig build unicode`.

const std = @import("std");

const version = "17.0.0";
const base = "https://www.unicode.org/Public/" ++ version ++ "/ucd";
const output_path = "lib/terminal/unicode.zig";
const max_code_point = 0x10FFFF;

const Range = struct { first: u21, last: u21, width: u8 };
const Bounds = struct { first: u21, last: u21 };

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const categories = try fetch(arena, &client, "/extracted/DerivedGeneralCategory.txt");
    const east_asian = try fetch(arena, &client, "/EastAsianWidth.txt");
    const emoji = try fetch(arena, &client, "/emoji/emoji-data.txt");

    const zero = try arena.alloc(bool, max_code_point + 1);
    @memset(zero, false);
    mark(categories, &.{ "Mn", "Me", "Cf" }, zero);
    zero[0x00AD] = false;
    for (0x1160..0x1200) |code_point| zero[code_point] = true;
    zero[0x200B] = true;

    const wide = try arena.alloc(bool, max_code_point + 1);
    @memset(wide, false);
    mark(east_asian, &.{ "W", "F" }, wide);
    mark(emoji, &.{"Emoji_Presentation"}, wide);

    const ranges = try coalesce(arena, zero, wide);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(&out.writer, ranges);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = out.written() });

    std.debug.print("wrote {s}: {d} ranges from Unicode {s}\n", .{ output_path, ranges.len, version });
}

/// Body of `base ++ path`, or an error when the server does not answer with 200.
fn fetch(arena: std.mem.Allocator, client: *std.http.Client, path: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, path });
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

/// Sets `flags` true for every code point of a UCD data line whose property
/// value is one of `wanted`.
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
        for (bounds.first..bounds.last + 1) |code_point| flags[code_point] = true;
    }
}

/// Sorted, non-overlapping ranges of the code points that are not one column,
/// merging adjacent code points of the same width.
fn coalesce(arena: std.mem.Allocator, zero: []const bool, wide: []const bool) ![]Range {
    var ranges: std.ArrayList(Range) = .empty;
    var open: ?Range = null;
    for (0..max_code_point + 1) |code_point| {
        const width: u8 = if (zero[code_point]) 0 else if (wide[code_point]) 2 else 1;
        if (width == 1) {
            if (open) |range| try ranges.append(arena, range);
            open = null;
            continue;
        }
        if (open) |*range| {
            if (range.width == width) {
                range.last = @intCast(code_point);
                continue;
            }
            try ranges.append(arena, range.*);
        }
        open = .{ .first = @intCast(code_point), .last = @intCast(code_point), .width = width };
    }
    if (open) |range| try ranges.append(arena, range);
    return ranges.toOwnedSlice(arena);
}

fn emit(writer: *std.Io.Writer, ranges: []const Range) !void {
    try writer.print(header_prefix, .{version});
    try writer.writeAll(header_rest);
    for (ranges) |range| try writer.print(
        "    .{{ .first = 0x{x:0>4}, .last = 0x{x:0>4}, .width = {d} }},\n",
        .{ range.first, range.last, range.width },
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

const header_prefix =
    \\//! Display-width interval table generated from the Unicode Character Database,
    \\//! version {s}. Do not edit by hand; regenerate with `zig build unicode`.
    \\
;

const header_rest =
    \\//!
    \\//! The table below is derived from Unicode data files and is distributed under
    \\//! the Unicode License V3:
    \\//!
    \\//!   Copyright (c) 1991-2025 Unicode, Inc. All rights reserved.
    \\//!   Distributed under the Terms of Use at https://www.unicode.org/copyright.html
    \\//!
    \\//!   Permission is hereby granted, free of charge, to any person obtaining a
    \\//!   copy of the Unicode data files and any associated documentation (the "Data
    \\//!   Files") to deal in the Data Files without restriction, including without
    \\//!   limitation the rights to use, copy, modify, merge, publish, distribute,
    \\//!   and/or sell copies of the Data Files, and to permit persons to whom the
    \\//!   Data Files are furnished to do so, provided that this copyright and
    \\//!   permission notice appear with all copies of the Data Files.
    \\
    \\pub const Range = struct { first: u21, last: u21, width: u8 };
    \\
    \\/// Code points whose display width is not one column, sorted and
    \\/// non-overlapping. Width zero covers nonspacing and enclosing combining marks,
    \\/// format controls, Hangul Jamo medial and final letters, and the zero-width
    \\/// space. Width two covers East Asian Wide and Fullwidth code points and the
    \\/// code points with default emoji presentation. A code point in no range is one
    \\/// column.
    \\pub const widths = [_]Range{
    \\
;
