const std = @import("std");
const Message = @import("Message.zig");

const Page = @This();

title: []const u8,
content: std.ArrayList(u8),
retry: ?Message = null,
notice: ?Message = null,
action: Action,

pub const Action = enum { close, discard, apply };
pub const Options = struct {
    title: []const u8,
    content: []const u8,
    action: Action = .close,
};

pub fn init(gpa: std.mem.Allocator, options: *const Options) error{OutOfMemory}!Page {
    const title = try gpa.dupe(u8, options.title);
    errdefer gpa.free(title);
    var content: std.ArrayList(u8) = .empty;
    try content.appendSlice(gpa, options.content);
    return .{ .title = title, .content = content, .action = options.action };
}

pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
    gpa.free(self.title);
    self.content.deinit(gpa);
    if (self.retry) |*message| message.deinit(gpa);
    if (self.notice) |*message| message.deinit(gpa);
}

pub fn text(self: *const Page) []const u8 {
    return self.content.items;
}

pub fn append(self: *Page, gpa: std.mem.Allocator, addition: []const u8) error{OutOfMemory}!void {
    try self.content.appendSlice(gpa, addition);
}

pub fn setRetry(
    self: *Page,
    gpa: std.mem.Allocator,
    message: *const Message,
) error{OutOfMemory}!void {
    const copy = try message.dupe(gpa);
    if (self.retry) |*previous| previous.deinit(gpa);
    self.retry = copy;
}

pub fn setNotice(
    self: *Page,
    gpa: std.mem.Allocator,
    message: *const Message,
) error{OutOfMemory}!void {
    const copy = try message.dupe(gpa);
    if (self.notice) |*previous| previous.deinit(gpa);
    self.notice = copy;
}
