const std = @import("std");

const Message = @import("Message.zig");

const Reports = @This();

subject: []const u8,
items: std.ArrayList(Message) = .empty,
capped: bool = false,

pub const count_max = 1024;

pub fn deinit(self: *Reports, gpa: std.mem.Allocator) void {
    for (self.items.items) |message| message.deinit(gpa);
    self.items.deinit(gpa);
    self.* = undefined;
}

pub fn messages(self: *const Reports) []const Message {
    return self.items.items;
}

pub fn add(
    self: *Reports,
    gpa: std.mem.Allocator,
    severity: Message.Severity,
    comptime template: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    if (self.capped) return;
    const omitting = self.items.items.len == count_max - 1;
    const message = if (omitting) try Message.print(
        gpa,
        .failure,
        "Drinky omitted the remaining messages about the {s}.",
        .{self.subject},
    ) else try Message.print(gpa, severity, template, args);
    errdefer message.deinit(gpa);
    try self.items.append(gpa, message);
    self.capped = omitting;
}

test "the reports stop at their cap with one message that names the omission" {
    const gpa = std.testing.allocator;
    var reports: Reports = .{ .subject = "skill files" };
    defer reports.deinit(gpa);
    for (0..count_max + 8) |index| try reports.add(gpa, .warning, "Message {d}.", .{index});

    try std.testing.expectEqual(@as(usize, count_max), reports.messages().len);
    try std.testing.expectEqual(Message.Severity.warning, reports.messages()[0].severity);
    const last = reports.messages()[count_max - 1];
    try std.testing.expectEqual(Message.Severity.failure, last.severity);
    try std.testing.expectEqualStrings(
        "Drinky omitted the remaining messages about the skill files.",
        last.content,
    );
}
