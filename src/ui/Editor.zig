//! The input-line editing model: a UTF-8 text buffer with a codepoint caret.
//!
//! It owns editing state only. Submitting, quitting, and drawing are the
//! caller's job; `render` produces the display lines and, when focused, places
//! the `cursor` marker at the caret so the renderer can put the real terminal
//! cursor there.

const std = @import("std");

const separator = @import("separator.zig");
const terminal = @import("terminal");

const Editor = @This();

gpa: std.mem.Allocator,
text: std.ArrayList(u8),
caret: usize,

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{ .gpa = gpa, .text = .empty, .caret = 0 };
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
}

pub fn insertCodepoint(self: *Editor, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch return;
    try self.insert(buffer[0..length]);
}

pub fn insert(self: *Editor, bytes: []const u8) !void {
    try self.text.insertSlice(self.gpa, self.caret, bytes);
    self.caret += bytes.len;
}

pub fn backspace(self: *Editor) void {
    if (self.caret == 0) return;
    const previous = self.previousBoundary();
    const removed = self.caret - previous;
    std.mem.copyForwards(u8, self.text.items[previous..], self.text.items[self.caret..]);
    self.text.items.len -= removed;
    self.caret = previous;
}

pub fn moveLeft(self: *Editor) void {
    if (self.caret > 0) self.caret = self.previousBoundary();
}

pub fn moveRight(self: *Editor) void {
    if (self.caret < self.text.items.len) self.caret += self.stepFrom(self.caret);
}

pub fn moveHome(self: *Editor) void {
    self.caret = 0;
}

pub fn moveEnd(self: *Editor) void {
    self.caret = self.text.items.len;
}

/// Build the wrapped display lines into `buffer`/`lines` (both cleared first).
/// When `focused`, the caret marker is placed at the cursor so the renderer can
/// position the hardware cursor there. `lines` borrows from `buffer`, so keep
/// `buffer` alive while using them.
pub fn render(
    self: *const Editor,
    columns: usize,
    focused: bool,
    buffer: *std.ArrayList(u8),
    lines: *std.ArrayList([]const u8),
) !void {
    buffer.clearRetainingCapacity();
    lines.clearRetainingCapacity();
    const gpa = self.gpa;

    // Everything goes into `buffer` first; the separator and body slices are
    // resolved by offset only after the last append, since growth can move the
    // backing memory and invalidate a slice taken earlier.
    try separator.rule(buffer, gpa, columns);
    const separator_end = buffer.items.len;

    const body_start = buffer.items.len;
    try buffer.appendSlice(gpa, self.text.items[0..self.caret]);
    if (focused) try buffer.appendSlice(gpa, terminal.cursor.marker);
    try buffer.appendSlice(gpa, self.text.items[self.caret..]);

    const separator_line = buffer.items[0..separator_end];
    const body = buffer.items[body_start..];
    const columns_min = 1;
    try lines.append(gpa, separator_line);
    try terminal.width.wrap(body, @max(columns, columns_min), lines, gpa);
    try lines.append(gpa, separator_line);
}

fn stepFrom(self: *const Editor, index: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(self.text.items[index]) catch return 1;
    return @min(length, self.text.items.len - index);
}

fn previousBoundary(self: *const Editor) usize {
    var index = self.caret - 1;
    while (index > 0 and isContinuation(self.text.items[index])) index -= 1;
    return index;
}

fn isContinuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
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

test render {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("hi");
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    try editor.render(80, true, &buffer, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqual(@as(usize, 80), terminal.width.display(lines.items[0]));
    // The body is the text plus the zero-width caret marker at the cursor.
    try std.testing.expectEqual(@as(usize, 2), terminal.width.display(lines.items[1]));
    try std.testing.expectEqual(@as(?usize, 2), terminal.cursor.column(lines.items[1]));
    try std.testing.expectEqual(@as(usize, 80), terminal.width.display(lines.items[2]));

    try editor.render(80, false, &buffer, &lines);
    try std.testing.expectEqual(@as(?usize, null), terminal.cursor.column(lines.items[1]));
}
