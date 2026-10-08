const std = @import("std");

const Cells = @This();

rest: []const u8,
done: bool = false,

pub fn init(row: []const u8) Cells {
    var body = std.mem.trim(u8, row, " \t\r");
    if (body.len > 0 and body[0] == '|') body = body[1..];
    if (body.len > 0 and body[body.len - 1] == '|' and !isEscaped(body, body.len - 1)) {
        body = body[0 .. body.len - 1];
    }
    return .{ .rest = body };
}

pub fn next(self: *Cells) ?[]const u8 {
    if (self.done) return null;
    var search_from: usize = 0;
    while (std.mem.findScalarPos(u8, self.rest, search_from, '|')) |pipe| {
        if (!isEscaped(self.rest, pipe)) {
            defer self.rest = self.rest[pipe + 1 ..];
            return std.mem.trim(u8, self.rest[0..pipe], " \t");
        }
        search_from = pipe + 1;
    }
    self.done = true;
    return std.mem.trim(u8, self.rest, " \t");
}

pub fn isRow(line: []const u8) bool {
    const body = std.mem.trimStart(u8, line, " ");
    return body.len > 0 and body[0] == '|';
}

pub fn isDelimiter(line: []const u8) bool {
    if (!isRow(line)) return false;
    var cells = Cells.init(line);
    while (cells.next()) |cell| {
        var body = cell;
        if (body.len > 0 and body[0] == ':') body = body[1..];
        if (body.len > 0 and body[body.len - 1] == ':') body = body[0 .. body.len - 1];
        if (body.len == 0) return false;
        for (body) |byte| if (byte != '-') return false;
    }
    return true;
}

pub fn count(row: []const u8) usize {
    var cells = Cells.init(row);
    var result: usize = 0;
    while (cells.next() != null) result += 1;
    return result;
}

fn isEscaped(text: []const u8, index: usize) bool {
    var backslashes: usize = 0;
    while (backslashes < index and text[index - 1 - backslashes] == '\\') : (backslashes += 1) {}
    return backslashes % 2 == 1;
}

test "cells retain escaped pipes and blank cells" {
    const row = "  | a \\| b | | c\\\\| d | ";
    var cells: Cells = .init(row);
    try std.testing.expectEqualStrings("a \\| b", cells.next().?);
    try std.testing.expectEqualStrings("", cells.next().?);
    try std.testing.expectEqualStrings("c\\\\", cells.next().?);
    try std.testing.expectEqualStrings("d", cells.next().?);
    try std.testing.expect(cells.next() == null);
    try std.testing.expectEqual(@as(usize, 4), count(row));
}
