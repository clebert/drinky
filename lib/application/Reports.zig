const std = @import("std");

const Record = @import("Record.zig");

const Reports = @This();

subject: Record.Event.Subject,
items: std.ArrayList(Record.Event) = .empty,
capped: bool = false,

pub const count_max = 1024;

pub fn deinit(self: *Reports, gpa: std.mem.Allocator) void {
    for (self.items.items) |*event| event.deinit(gpa);
    self.items.deinit(gpa);
    self.* = undefined;
}

pub fn events(self: *const Reports) []const Record.Event {
    return self.items.items;
}

pub fn add(
    self: *Reports,
    gpa: std.mem.Allocator,
    event: *const Record.Event,
) error{OutOfMemory}!void {
    if (self.capped) return;
    const omitting = self.items.items.len == count_max - 1;
    const owned: Record.Event = if (omitting)
        .{ .reports_omitted = self.subject }
    else
        try event.dupe(gpa);
    errdefer owned.deinit(gpa);
    try self.items.append(gpa, owned);
    self.capped = omitting;
}

test "the reports stop at their cap with one event that names the omission" {
    const gpa = std.testing.allocator;
    var reports: Reports = .{ .subject = .skills };
    defer reports.deinit(gpa);
    for (0..count_max + 8) |_|
        try reports.add(gpa, &.{ .skill_report = .{ .not_text = "/skills/demo/SKILL.md" } });

    try std.testing.expectEqual(@as(usize, count_max), reports.events().len);
    try std.testing.expectEqualStrings(
        "/skills/demo/SKILL.md",
        reports.events()[0].skill_report.not_text,
    );
    try std.testing.expectEqual(
        Record.Event{ .reports_omitted = .skills },
        reports.events()[count_max - 1],
    );
}
