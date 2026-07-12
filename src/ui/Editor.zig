//! The input-line editing model: a UTF-8 text buffer with a grapheme-cluster caret.
//!
//! It owns editing state only. Submitting, quitting, and drawing are the
//! caller's job; `render` produces the display lines and, when focused, reports
//! the caret's `(sub-row, column)` within them so the caller can address the
//! real terminal cursor.

const std = @import("std");

const separator = @import("separator.zig");
const terminal = @import("terminal");

const Editor = @This();

gpa: std.mem.Allocator,
text: std.ArrayList(u8),
caret: usize,
/// Desired display column for vertical movement, remembered across consecutive
/// `moveUp`/`moveDown` so a step through a shorter row does not forget it. Null
/// until a vertical step captures the caret's column; a horizontal move, an
/// edit, or a vertical move off the top or bottom row (which falls back to
/// `moveHome`/`moveEnd`) clears it back to null.
goal_column: ?usize,

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{ .gpa = gpa, .text = .empty, .caret = 0, .goal_column = null };
}

pub fn deinit(self: *Editor) void {
    self.text.deinit(self.gpa);
}

pub fn content(self: *const Editor) []const u8 {
    return self.text.items;
}

pub fn clear(self: *Editor) void {
    self.text.clearRetainingCapacity();
    self.caret = 0;
    self.goal_column = null;
}

pub fn insertCodepoint(self: *Editor, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch return;
    try self.insert(buffer[0..length]);
}

pub fn insert(self: *Editor, bytes: []const u8) !void {
    self.goal_column = null;
    try self.text.insertSlice(self.gpa, self.caret, bytes);
    self.caret += bytes.len;
    // Inserted text can fuse with what follows into a single cluster; advance
    // the caret to that cluster's end so it stays on a grapheme boundary.
    var index = self.previousBoundary();
    while (index < self.caret) index += self.stepFrom(index);
    self.caret = index;
}

pub fn backspace(self: *Editor) void {
    self.goal_column = null;
    if (self.caret == 0) return;
    const previous = self.previousBoundary();
    const removed = self.caret - previous;
    std.mem.copyForwards(u8, self.text.items[previous..], self.text.items[self.caret..]);
    self.text.items.len -= removed;
    self.caret = previous;
}

pub fn moveLeft(self: *Editor) void {
    self.goal_column = null;
    if (self.caret > 0) self.caret = self.previousBoundary();
}

pub fn moveRight(self: *Editor) void {
    self.goal_column = null;
    if (self.caret < self.text.items.len) self.caret += self.stepFrom(self.caret);
}

pub fn moveHome(self: *Editor) void {
    self.goal_column = null;
    self.caret = 0;
}

pub fn moveEnd(self: *Editor) void {
    self.goal_column = null;
    self.caret = self.text.items.len;
}

/// Move the caret one wrapped row up, targeting the sticky goal column (the
/// column a run of vertical moves began at). On the top row it falls back to
/// `moveHome`, jumping to the start. The caret clamps to the target row's end
/// without disturbing the goal, so a later step onto a wider row restores the
/// column. `columns` is the wrap width `render` is given, so vertical steps
/// follow the same row layout.
pub fn moveUp(self: *Editor, columns: usize) void {
    const columns_max = @max(columns, 1);
    const position = terminal.width.caret(self.text.items[0..self.caret], columns_max);
    if (position.rows_before == 0) {
        self.moveHome();
        return;
    }
    const goal = self.goal_column orelse position.column;
    self.goal_column = goal;
    self.caret = terminal.width.offsetAt(self.text.items, columns_max, .{
        .rows_before = position.rows_before - 1,
        .column = goal,
    });
}

/// Move the caret one wrapped row down, targeting the sticky goal column; on the
/// bottom row it falls back to `moveEnd`, jumping to the end. See `moveUp` for
/// how the goal column persists.
pub fn moveDown(self: *Editor, columns: usize) void {
    const columns_max = @max(columns, 1);
    const position = terminal.width.caret(self.text.items[0..self.caret], columns_max);
    if (position.rows_before + 1 >= terminal.width.rows(self.text.items, columns_max)) {
        self.moveEnd();
        return;
    }
    const goal = self.goal_column orelse position.column;
    self.goal_column = goal;
    self.caret = terminal.width.offsetAt(self.text.items, columns_max, .{
        .rows_before = position.rows_before + 1,
        .column = goal,
    });
}

/// Build the wrapped display lines into `buffer`/`lines` (both cleared first),
/// returning the caret's `(sub-row, column)` within `lines` when `focused`, else
/// null. `sub-row` is an index into `lines`; the caller adds the block's base to
/// resolve the window-relative row. `lines` borrows from `buffer`, so keep
/// `buffer` alive while using them.
pub fn render(
    self: *const Editor,
    columns: usize,
    focused: bool,
    buffer: *std.ArrayList(u8),
    lines: *std.ArrayList([]const u8),
) !?terminal.View.Caret {
    buffer.clearRetainingCapacity();
    lines.clearRetainingCapacity();
    const gpa = self.gpa;
    const columns_max = @max(columns, 1);

    // Everything goes into `buffer` first; the separator and body slices are
    // resolved by offset only after the last append, since growth can move the
    // backing memory and invalidate a slice taken earlier.
    try separator.rule(buffer, gpa, columns);
    const separator_end = buffer.items.len;

    const body_start = buffer.items.len;
    try buffer.appendSlice(gpa, self.text.items);

    const separator_line = buffer.items[0..separator_end];
    const body = buffer.items[body_start..];
    try lines.append(gpa, separator_line);
    const body_row = lines.items.len;
    try terminal.width.wrap(body, columns_max, lines, gpa);
    try lines.append(gpa, separator_line);

    if (!focused) return null;
    // The caret's row and column are fixed by the body prefix before it (see
    // `width.caret`).
    const position = terminal.width.caret(body[0..self.caret], columns_max);
    return .{ .row = body_row + position.rows_before, .column = position.column };
}

fn stepFrom(self: *const Editor, index: usize) usize {
    return terminal.grapheme.stepAt(self.text.items[index..]).bytes;
}

fn previousBoundary(self: *const Editor) usize {
    return terminal.grapheme.boundaryBefore(self.text.items, self.caret);
}

test "insert and content" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abc");
    try std.testing.expectEqualStrings("abc", editor.content());
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
}

test "caret movement and backspace" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abc");
    editor.moveLeft();
    try editor.insertCodepoint('X');
    try std.testing.expectEqualStrings("abXc", editor.content());
    editor.backspace();
    try std.testing.expectEqualStrings("abc", editor.content());
    editor.moveHome();
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
    editor.moveEnd();
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
}

test "multibyte backspace deletes whole codepoint" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("é");
    try std.testing.expectEqual(@as(usize, 2), editor.text.items.len);
    editor.backspace();
    try std.testing.expectEqual(@as(usize, 0), editor.text.items.len);
}

test "backspace deletes a whole grapheme cluster" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Base emoji plus skin-tone modifier is one cluster.
    try editor.insert("👍\u{1F3FD}");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.content());
    // Base letter plus a combining mark.
    try editor.insert("e\u{0301}");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.content());
    // A regional-indicator flag is one cluster of two indicators.
    try editor.insert("🇯🇵");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.content());
    // A four-emoji ZWJ family folds into one cluster.
    try editor.insert("👨\u{200D}👩\u{200D}👧\u{200D}👦");
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.content());
}

test "backspace peels one cluster at a time and leaves neighbours intact" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a👍\u{1F3FD}b");
    editor.backspace();
    try std.testing.expectEqualStrings("a👍\u{1F3FD}", editor.content());
    editor.backspace();
    try std.testing.expectEqualStrings("a", editor.content());
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.content());
}

test "insert keeps the caret on a cluster boundary when text fuses" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Typing a base letter before a dangling combining mark lands the caret
    // after the completed cluster, not inside it.
    try editor.insert("\u{0301}");
    editor.moveHome();
    try editor.insert("e");
    try std.testing.expectEqualStrings("e\u{0301}", editor.content());
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
    editor.backspace();
    try std.testing.expectEqualStrings("", editor.content());
    // Typing one regional indicator before another completes a flag; the caret
    // sits after the whole two-column glyph.
    try editor.insert("🇵");
    editor.moveHome();
    try editor.insert("🇯");
    try std.testing.expectEqualStrings("🇯🇵", editor.content());
    try std.testing.expectEqual(@as(usize, 8), editor.caret);
}

test "left and right move by whole grapheme cluster" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // "a"(1) + skin-tone cluster(8) + "b"(1): boundaries at 0, 1, 9, 10.
    try editor.insert("a👍\u{1F3FD}b");
    try std.testing.expectEqual(@as(usize, 10), editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 10), editor.caret);
}

test render {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("hi");
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    const caret = try editor.render(80, true, &buffer, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqual(@as(usize, 80), terminal.width.ofText(lines.items[0]));
    try std.testing.expectEqual(@as(usize, 2), terminal.width.ofText(lines.items[1]));
    try std.testing.expectEqual(@as(usize, 80), terminal.width.ofText(lines.items[2]));
    // The caret is on the body row (index 1) at column 2, past "hi".
    try std.testing.expectEqual(@as(?terminal.View.Caret, .{ .row = 1, .column = 2 }), caret);

    try std.testing.expectEqual(@as(?terminal.View.Caret, null), try editor.render(80, false, &buffer, &lines));
}

test "caret sits on the empty row after a trailing newline" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n");
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    const caret = try editor.render(80, true, &buffer, &lines);
    // Separator, "a", the empty new line, separator.
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    try std.testing.expectEqual(@as(?terminal.View.Caret, .{ .row = 2, .column = 0 }), caret);
}

test "caret occupies a blank row between two newlines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n\nb");
    editor.moveLeft();
    editor.moveLeft();
    // The caret now sits just after the first newline, on the blank middle row.
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    const caret = try editor.render(80, true, &buffer, &lines);
    try std.testing.expectEqual(@as(usize, 5), lines.items.len);
    try std.testing.expectEqual(@as(?terminal.View.Caret, .{ .row = 2, .column = 0 }), caret);
}

test "consecutive newlines each add an occupiable row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("\n\n");
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    const caret = try editor.render(80, true, &buffer, &lines);
    try std.testing.expectEqual(@as(?terminal.View.Caret, .{ .row = 3, .column = 0 }), caret);
}

test "moveUp and moveDown across newline lines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("hello\nworld");
    editor.caret = 3; // Row 0, column 3, between the two 'l's.
    editor.moveDown(80);
    try std.testing.expectEqual(@as(usize, 9), editor.caret); // Row 1, column 3.
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 3), editor.caret);
}

test "moveDown clamps to a shorter target row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy");
    editor.caret = 5; // Row 0, column 5.
    editor.moveDown(80);
    // "xy" is only two columns wide, so the caret clamps to its end.
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
}

test "moveUp and moveDown across wrapped continuation rows" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef");
    editor.caret = 1; // Wrapped at width 3: row 0, column 1.
    editor.moveDown(3);
    try std.testing.expectEqual(@as(usize, 4), editor.caret); // Row 1, column 1.
    editor.moveUp(3);
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
}

test "moveUp off the top row jumps to the start and clears the goal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxyz\nghijkl");
    editor.caret = 16; // Row 2, column 5.
    editor.moveUp(80); // Row 1, clamped to column 3.
    editor.moveUp(80); // Row 0, back at column 5 via the goal.
    try std.testing.expectEqual(@as(usize, 5), editor.caret);
    try std.testing.expectEqual(@as(?usize, 5), editor.goal_column);
    editor.moveUp(80); // Top row: jump to the very start.
    try std.testing.expectEqual(@as(usize, 0), editor.caret);
    try std.testing.expectEqual(@as(?usize, null), editor.goal_column);
}

test "moveDown off the bottom row jumps to the end and clears the goal" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxyz\nghijkl");
    editor.caret = 1; // Row 0, column 1.
    editor.moveDown(80); // Row 1, column 1.
    editor.moveDown(80); // Row 2, column 1.
    try std.testing.expectEqual(@as(usize, 12), editor.caret);
    try std.testing.expectEqual(@as(?usize, 1), editor.goal_column);
    editor.moveDown(80); // Bottom row: jump to the very end.
    try std.testing.expectEqual(@as(usize, 17), editor.caret);
    try std.testing.expectEqual(@as(?usize, null), editor.goal_column);
}

test "moveDown lands on the visually adjacent row at the same column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("hello\nworld");
    editor.caret = 3;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    const before = try editor.render(80, true, &buffer, &lines);
    editor.moveDown(80);
    const after = try editor.render(80, true, &buffer, &lines);
    try std.testing.expectEqual(before.?.row + 1, after.?.row);
    try std.testing.expectEqual(before.?.column, after.?.column);
}

test "vertical movement keeps a sticky goal column across a shorter row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy\nghijkl");
    editor.caret = 5; // Row 0, column 5.
    editor.moveDown(80);
    // "xy" is only two columns, so the caret clamps to its end.
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveDown(80);
    // The goal column survives the short row and lands at column 5 again.
    try std.testing.expectEqual(@as(usize, 15), editor.caret);
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 9), editor.caret);
    editor.moveUp(80);
    try std.testing.expectEqual(@as(usize, 5), editor.caret);
}

test "a horizontal move resets the vertical goal column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy\nghijkl");
    editor.caret = 5; // Row 0, column 5.
    editor.moveDown(80); // Clamps to column 2 at the end of "xy".
    editor.moveLeft(); // Column 1, and the old goal is forgotten.
    editor.moveDown(80);
    // The recaptured goal is column 1, not the original 5.
    try std.testing.expectEqual(@as(usize, 11), editor.caret);
}

test "an edit resets the vertical goal column" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abcdef\nxy\nghijkl");
    editor.caret = 5; // Row 0, column 5.
    editor.moveDown(80); // Clamps to column 2 at the end of "xy".
    try editor.insert("z"); // "xyz"; the edit forgets the old goal.
    editor.moveDown(80);
    // The recaptured goal is column 3, after "xyz", not the original 5.
    try std.testing.expectEqual(@as(usize, 14), editor.caret);
}

test "moving right across blank lines does not skip rows" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n\nb");
    editor.moveHome();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    const expected_rows = [_]usize{ 1, 1, 2, 3, 3 };
    for (expected_rows) |row| {
        const caret = try editor.render(80, true, &buffer, &lines);
        try std.testing.expectEqual(row, caret.?.row);
        editor.moveRight();
    }
}
