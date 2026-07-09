//! Inline renderer for a live region at the bottom of the normal terminal
//! buffer.
//!
//! `commit` prints permanent lines that scroll up into scrollback; `render`
//! repaints the live region below them. Each repaint moves to the region's
//! first row, clears to the end of the screen, and rewrites the lines inside a
//! synchronized-output burst so it lands without flicker. Callers pass lines
//! already wrapped to the terminal width; the renderer does no width math.

const std = @import("std");
const escape = @import("../terminal/escape.zig");

const Renderer = @This();

gpa: std.mem.Allocator,
writer: *std.Io.Writer,
live: std.ArrayList([]u8),

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer) Renderer {
    return .{ .gpa = gpa, .writer = writer, .live = .empty };
}

pub fn deinit(self: *Renderer) void {
    self.freeLive();
    self.live.deinit(self.gpa);
}

/// Replace the live region with `lines`.
pub fn render(self: *Renderer, lines: []const []const u8) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    try self.eraseRegion();
    try writeRegion(writer, lines);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
    try self.storeLive(lines);
}

/// Print `lines` permanently above the live region, then redraw the region.
pub fn commit(self: *Renderer, lines: []const []const u8) !void {
    const writer = self.writer;
    try writer.writeAll(escape.sync_set);
    try self.eraseRegion();
    for (lines) |line| {
        try writer.writeAll(line);
        try writer.writeAll("\r\n");
    }
    try writeRegion(writer, self.live.items);
    try writer.writeAll(escape.sync_reset);
    try writer.flush();
}

fn eraseRegion(self: *Renderer) !void {
    const writer = self.writer;
    try writer.writeAll("\r");
    if (self.live.items.len > 0) try escape.cursorUp(writer, self.live.items.len - 1);
    try writer.writeAll(escape.screen_clear_below);
}

fn writeRegion(writer: *std.Io.Writer, lines: []const []const u8) !void {
    for (lines, 0..) |line, index| {
        if (index > 0) try writer.writeAll("\r\n");
        try writer.writeAll(line);
    }
}

fn storeLive(self: *Renderer, lines: []const []const u8) !void {
    self.freeLive();
    self.live.clearRetainingCapacity();
    for (lines) |line| try self.live.append(self.gpa, try self.gpa.dupe(u8, line));
}

fn freeLive(self: *Renderer) void {
    for (self.live.items) |line| self.gpa.free(line);
}

test "commit prints above a retained live region" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var renderer = Renderer.init(std.testing.allocator, &out.writer);
    defer renderer.deinit();

    try renderer.render(&.{"> prompt"});
    try std.testing.expectEqual(@as(usize, 1), renderer.live.items.len);
    try renderer.commit(&.{"hello world"});

    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, escape.sync_set) != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "> prompt") != null);
}

test "shrinking region clears trailing rows" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var renderer = Renderer.init(std.testing.allocator, &out.writer);
    defer renderer.deinit();

    try renderer.render(&.{ "one", "two", "three" });
    try renderer.render(&.{"only"});
    try std.testing.expectEqual(@as(usize, 1), renderer.live.items.len);
    try std.testing.expectEqualStrings("only", renderer.live.items[0]);
}
