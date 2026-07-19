//! The input-line editing model: a text buffer whose caret follows rendered
//! units — grapheme clusters for valid UTF-8 and one unit per canonical
//! replacement for malformed or control input.
//!
//! It owns editing state only. Submitting, quitting, and drawing are the
//! caller's job; `render` produces the display lines and reports the caret's
//! `(sub-row, column)` within them so the caller can address the real terminal
//! cursor.

const std = @import("std");

const paint = @import("paint.zig");
const terminal = @import("terminal");

const Editor = @This();

gpa: std.mem.Allocator,
text: std.ArrayList(u8),
caret: usize,
/// The first wrapped body row shown when the body is taller than its slot; the
/// window scrolls to keep the caret in view. `reflow` maintains it and `clear`
/// resets it; the rows above it show as an "N more" label on the top rule.
scroll: usize,
/// Desired display column for vertical movement, remembered across consecutive
/// `moveUp`/`moveDown` so a step through a shorter row does not forget it. Null
/// until a vertical step captures the caret's column; a horizontal move, an
/// edit, or a vertical move off the top or bottom row clears it back to null.
goal_column: ?usize,

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{ .gpa = gpa, .text = .empty, .caret = 0, .scroll = 0, .goal_column = null };
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
    self.scroll = 0;
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
    // Inserted text can fuse with what follows into one rendered unit; advance
    // the caret to its end so it stays on a display boundary.
    self.caret = terminal.width.boundaryAtOrAfter(self.text.items, self.caret);
}

pub fn backspace(self: *Editor) void {
    self.goal_column = null;
    if (self.caret == 0) return;
    const previous = terminal.width.boundaryBefore(self.text.items, self.caret);
    const removed = self.caret - previous;
    std.mem.copyForwards(u8, self.text.items[previous..], self.text.items[self.caret..]);
    self.text.items.len -= removed;
    // The bytes on either side can become one grapheme or valid UTF-8 after the
    // deletion, so re-clamp the old position to the resulting display boundary.
    self.caret = terminal.width.boundaryAtOrAfter(self.text.items, previous);
}

pub fn moveLeft(self: *Editor) void {
    self.goal_column = null;
    if (self.caret > 0) self.caret = terminal.width.boundaryBefore(self.text.items, self.caret);
}

pub fn moveRight(self: *Editor) void {
    self.goal_column = null;
    if (self.caret < self.text.items.len)
        self.caret = terminal.width.boundaryAfter(self.text.items, self.caret);
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

/// Re-clamp the scroll offset so the caret's wrapped row stays inside the visible
/// window. Call once per repaint, passing the same `size` whose columns and rows
/// `render` and `rows` will use, so all three agree on the window.
pub fn reflow(self: *Editor, size: terminal.View.Size) void {
    const columns_max = @max(size.columns, 1);
    const total_body = self.bodyRows(columns_max);
    const visible = @min(total_body, paint.bodyLimit(size.rows));
    const caret_row = terminal.width.caret(self.text.items[0..self.caret], columns_max).rows_before;
    if (caret_row < self.scroll) self.scroll = caret_row;
    if (caret_row >= self.scroll + visible) self.scroll = caret_row - visible + 1;
    self.scroll = @min(self.scroll, total_body - visible);
}

/// Physical rows the editor occupies: the two framing rules plus the wrapped
/// body, the body capped to its scroll limit for `size.rows`.
pub fn rows(self: *const Editor, size: terminal.View.Size) usize {
    const total_body = self.bodyRows(@max(size.columns, 1));
    return paint.framedRows(@min(total_body, paint.bodyLimit(size.rows)));
}

/// Body rows the editor lays out: the wrapped text plus, when the caret has
/// wrapped past a full-width final line, the empty trailing row it sits on — a
/// row the wrap itself never yields (see `caretPosition`).
fn bodyRows(self: *const Editor, columns_max: usize) usize {
    const wrapped = terminal.width.rows(self.text.items, columns_max);
    const caret_row = terminal.width.caret(self.text.items[0..self.caret], columns_max).rows_before;
    return wrapped + @intFromBool(caret_row == wrapped);
}

/// Stream the framed input area — the rules and the wrapped text, windowed to
/// its scroll limit for `viewport_rows` — through `placement`, placing the
/// terminal caret on its row. Assumes `reflow` set the scroll.
pub fn render(self: *const Editor, placement: *const paint.Placement, viewport_rows: usize) !void {
    const columns_max = @max(placement.columns, 1);
    const total_body = self.bodyRows(columns_max);
    const visible = @min(total_body, paint.bodyLimit(viewport_rows));
    try paint.framed(placement, &.{
        .body = self.text.items,
        .caret = self.caretPosition(columns_max),
        .hidden_above = self.scroll,
        .shown = visible,
        .hidden_below = total_body - self.scroll - visible,
        .trailing_row = total_body > terminal.width.rows(self.text.items, columns_max),
    });
}

/// The caret's position within the rendered rows: row 0 is the top rule and the
/// scrolled-off rows above the window are hidden, so the caret sits one below the
/// top rule plus its wrapped row's offset from the top of the window. A caret at
/// a full-width line's end reports the empty trailing row `bodyRows` reserves.
fn caretPosition(self: *const Editor, columns_max: usize) terminal.View.Caret {
    const position = terminal.width.caret(self.text.items[0..self.caret], columns_max);
    return .{ .row = 1 + (position.rows_before - self.scroll), .column = position.column };
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

test "malformed bytes and controls move by displayed units" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("\xf0\x9f");
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), editor.caret);
    editor.moveEnd();
    editor.backspace();
    try std.testing.expectEqualStrings("\xf0", editor.content());

    editor.clear();
    try editor.insert("\r\n");
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), editor.caret);

    editor.clear();
    try editor.insert("e\r\u{0301}");
    editor.moveLeft();
    editor.backspace();
    try std.testing.expectEqualStrings("e\u{0301}", editor.content());
    try std.testing.expectEqual(editor.content().len, editor.caret);

    editor.clear();
    try editor.insert("\xc3\xff\xa9");
    editor.moveLeft();
    editor.backspace();
    try std.testing.expectEqualStrings("é", editor.content());
    try std.testing.expectEqual(editor.content().len, editor.caret);
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
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("hi");
    // Top rule, the body row, bottom rule.
    try std.testing.expectEqual(@as(usize, 3), editor.rows(.{ .columns = 80, .rows = 24 }));
    // The caret is on the body row (row 1, below the top rule) at column 2.
    try expectCaretAt(&editor, 80, .{ .row = 1, .column = 2 });

    const painted = try rendered(gpa, &editor, .{ .columns = 80, .rows = 24 });
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "hi") != null);
    // The live input, so the view shows the hardware cursor.
    try std.testing.expect(std.mem.indexOf(u8, painted, terminal.escape.cursor_show) != null);
}

test "a full-width line reserves an empty trailing row for the wrapped caret" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("abc"); // Fills a three-column row exactly.
    editor.reflow(.{ .columns = 3, .rows = 24 });

    // The caret wraps onto an empty trailing row: two rules, the full row, and it.
    try std.testing.expectEqual(@as(usize, 4), editor.rows(.{ .columns = 3, .rows = 24 }));
    try expectCaretAt(&editor, 3, .{ .row = 2, .column = 0 });
    try std.testing.expectEqual(@as(usize, 4), try renderedRows(gpa, &editor, 3));

    // Backing the caret off the margin drops the trailing row again.
    editor.moveLeft();
    editor.reflow(.{ .columns = 3, .rows = 24 });
    try std.testing.expectEqual(@as(usize, 3), editor.rows(.{ .columns = 3, .rows = 24 }));
    try expectCaretAt(&editor, 3, .{ .row = 1, .column = 2 });
    try std.testing.expectEqual(@as(usize, 3), try renderedRows(gpa, &editor, 3));
}

// Renders `editor` into a fresh view and returns the frame's bytes, caller-owned.
fn rendered(gpa: std.mem.Allocator, editor: *const Editor, size: terminal.View.Size) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(size, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = size.columns, .base = 0, .skip = 0 };
    try editor.render(&placement, size.rows);
    try view.render();
    return gpa.dupe(u8, out.written());
}

fn renderedRows(gpa: std.mem.Allocator, editor: *const Editor, columns: usize) !usize {
    const painted = try rendered(gpa, editor, .{ .columns = columns, .rows = 24 });
    defer gpa.free(painted);
    return std.mem.count(u8, painted, "\r\n") + 1;
}

fn expectCaretAt(editor: *const Editor, columns: usize, expected: terminal.View.Caret) !void {
    try std.testing.expectEqual(expected, editor.caretPosition(columns));
}

test "caret sits on the empty row after a trailing newline" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n");
    // Rules plus "a" plus the empty new line: four rows.
    try std.testing.expectEqual(@as(usize, 4), editor.rows(.{ .columns = 80, .rows = 24 }));
    try expectCaretAt(&editor, 80, .{ .row = 2, .column = 0 });
}

test "caret occupies a blank row between two newlines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("a\n\nb");
    editor.moveLeft();
    editor.moveLeft();
    // The caret now sits just after the first newline, on the blank middle row.
    try std.testing.expectEqual(@as(usize, 5), editor.rows(.{ .columns = 80, .rows = 24 }));
    try expectCaretAt(&editor, 80, .{ .row = 2, .column = 0 });
}

test "consecutive newlines each add an occupiable row" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("\n\n");
    try expectCaretAt(&editor, 80, .{ .row = 3, .column = 0 });
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
    const expected_rows = [_]usize{ 1, 1, 2, 3, 3 };
    for (expected_rows) |row| {
        try std.testing.expectEqual(row, editor.caretPosition(80).row);
        editor.moveRight();
    }
}

test "a tall body caps its rows and scrolls the window to keep the caret in view" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    // Ten single-column rows; a 20-row viewport caps the body at six.
    try editor.insert("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9");
    editor.reflow(.{ .columns = 80, .rows = 20 });
    // Two rules plus the six shown body rows, not the whole ten-row body.
    try std.testing.expectEqual(@as(usize, 8), editor.rows(.{ .columns = 80, .rows = 20 }));
    // The caret ends on the last row, so the window ends there.
    try std.testing.expectEqual(@as(usize, 4), editor.scroll);
    // Window-relative: below the top rule and the five earlier shown rows.
    try std.testing.expectEqual(@as(usize, 6), editor.caretPosition(80).row);

    // Climbing to the top drags the window back up with the caret.
    for (0..9) |_| editor.moveUp(80);
    editor.reflow(.{ .columns = 80, .rows = 20 });
    try std.testing.expectEqual(@as(usize, 0), editor.scroll);
    try std.testing.expectEqual(@as(usize, 1), editor.caretPosition(80).row);
}

test "the framing rules report the rows scrolled out of view" {
    const gpa = std.testing.allocator;
    var editor = Editor.init(gpa);
    defer editor.deinit();
    try editor.insert("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9");
    for (0..3) |_| editor.moveUp(80); // The caret climbs to row 6.
    editor.reflow(.{ .columns = 80, .rows = 20 });
    // The window shows rows 1..6: one row hidden above, three below.
    try std.testing.expectEqual(@as(usize, 1), editor.scroll);

    const painted = try rendered(gpa, &editor, .{ .columns = 40, .rows = 20 });
    defer gpa.free(painted);
    try std.testing.expect(std.mem.indexOf(u8, painted, "↑ 1 more") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "↓ 3 more") != null);
    // The shown window carries its rows; the scrolled-off ones do not.
    try std.testing.expect(std.mem.indexOf(u8, painted, "l6") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "l0") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "l9") == null);
}
