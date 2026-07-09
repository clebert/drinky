//! The input-line editing model: a UTF-8 text buffer with a codepoint cursor.
//!
//! It owns editing state only. Submitting, quitting, and drawing are the
//! caller's job; `render` produces the display lines with the cursor drawn as
//! a reverse-video cell so the terminal's own cursor can stay hidden.

const std = @import("std");
const width = @import("width.zig");

const Editor = @This();

const prompt = "> ";
const cursor_set = "\x1b[7m";
const cursor_reset = "\x1b[27m";

gpa: std.mem.Allocator,
text: std.ArrayList(u8),
cursor: usize,

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{ .gpa = gpa, .text = .empty, .cursor = 0 };
}

pub fn deinit(self: *Editor) void {
    self.text.deinit(self.gpa);
}

pub fn content(self: *const Editor) []const u8 {
    return self.text.items;
}

pub fn clear(self: *Editor) void {
    self.text.clearRetainingCapacity();
    self.cursor = 0;
}

pub fn insertCodepoint(self: *Editor, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch return;
    try self.insert(buffer[0..length]);
}

pub fn insert(self: *Editor, bytes: []const u8) !void {
    try self.text.insertSlice(self.gpa, self.cursor, bytes);
    self.cursor += bytes.len;
}

pub fn backspace(self: *Editor) void {
    if (self.cursor == 0) return;
    const previous = self.previousBoundary();
    const removed = self.cursor - previous;
    std.mem.copyForwards(u8, self.text.items[previous..], self.text.items[self.cursor..]);
    self.text.items.len -= removed;
    self.cursor = previous;
}

pub fn moveLeft(self: *Editor) void {
    if (self.cursor > 0) self.cursor = self.previousBoundary();
}

pub fn moveRight(self: *Editor) void {
    if (self.cursor < self.text.items.len) self.cursor += self.stepFrom(self.cursor);
}

pub fn moveHome(self: *Editor) void {
    self.cursor = 0;
}

pub fn moveEnd(self: *Editor) void {
    self.cursor = self.text.items.len;
}

/// Build the wrapped display lines into `buffer`/`lines` (both cleared first).
/// `lines` borrows from `buffer`, so keep `buffer` alive while using them.
pub fn render(
    self: *const Editor,
    columns: usize,
    buffer: *std.ArrayList(u8),
    lines: *std.ArrayList([]const u8),
) !void {
    buffer.clearRetainingCapacity();
    lines.clearRetainingCapacity();
    const gpa = self.gpa;
    try buffer.appendSlice(gpa, prompt);
    try buffer.appendSlice(gpa, self.text.items[0..self.cursor]);
    try buffer.appendSlice(gpa, cursor_set);
    if (self.cursor < self.text.items.len) {
        const stop = self.cursor + self.stepFrom(self.cursor);
        try buffer.appendSlice(gpa, self.text.items[self.cursor..stop]);
        try buffer.appendSlice(gpa, cursor_reset);
        try buffer.appendSlice(gpa, self.text.items[stop..]);
    } else {
        try buffer.appendSlice(gpa, " ");
        try buffer.appendSlice(gpa, cursor_reset);
    }
    const columns_min = 1;
    try width.wrap(buffer.items, @max(columns, columns_min), lines, gpa);
}

fn stepFrom(self: *const Editor, index: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(self.text.items[index]) catch return 1;
    return @min(length, self.text.items.len - index);
}

fn previousBoundary(self: *const Editor) usize {
    var index = self.cursor - 1;
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
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
}

test "cursor movement and backspace" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("abc");
    editor.moveLeft();
    try editor.insertCodepoint('X');
    try std.testing.expectEqualStrings("abXc", editor.content());
    editor.backspace();
    try std.testing.expectEqualStrings("abc", editor.content());
    editor.moveHome();
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    editor.moveEnd();
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
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
    try editor.render(80, &buffer, &lines);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 5), width.display(lines.items[0]));
}
