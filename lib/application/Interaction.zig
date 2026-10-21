const std = @import("std");
const Choice = @import("Choice.zig");
const Message = @import("Message.zig");
const Picker = @import("Picker.zig");
const Settings = @import("Settings.zig");

const Interaction = @This();

mode: Mode = .prompt,
offer: Offer = .none,
working: bool = false,
sign_in_account: []const u8 = "",
takes_paste: bool = false,
notice: ?Message = null,
notice_id: u64 = 0,
picker: ?Picker = null,
page: ?Page = null,
choice: Choice,
branch: []const u8 = "",
settings: Settings = .{},

pub const Mode = enum { prompt, turn, picker, fetch, page, sign_in };
pub const Offer = enum { none, retry, removal };
pub const Page = struct {
    id: u64,
    title: []const u8,
    action: @import("Page.zig").Action,
    retry: ?Message = null,
    notice: ?Message = null,
    wait: ?Wait = null,

    pub const Wait = struct { started_ms: i64, received_bytes: usize = 0, thinking: bool = false };
};

pub fn dupe(self: *const Interaction, gpa: std.mem.Allocator) error{OutOfMemory}!Interaction {
    var result = self.*;
    result.sign_in_account = try gpa.dupe(u8, self.sign_in_account);
    errdefer gpa.free(result.sign_in_account);
    result.branch = try gpa.dupe(u8, self.branch);
    errdefer gpa.free(result.branch);
    result.notice = if (self.notice) |*notice| try notice.dupe(gpa) else null;
    errdefer if (result.notice) |*notice| notice.deinit(gpa);
    result.picker = if (self.picker) |*picker| try picker.dupe(gpa) else null;
    errdefer if (result.picker) |*picker| picker.deinit(gpa);
    result.page = if (self.page) |*page| try dupePage(gpa, page) else null;
    return result;
}

pub fn deinit(self: *const Interaction, gpa: std.mem.Allocator) void {
    gpa.free(self.sign_in_account);
    gpa.free(self.branch);
    if (self.notice) |*notice| notice.deinit(gpa);
    if (self.picker) |*picker| picker.deinit(gpa);
    if (self.page) |*page| freePage(gpa, page);
}

fn dupePage(gpa: std.mem.Allocator, page: *const Page) error{OutOfMemory}!Page {
    var result = page.*;
    result.title = try gpa.dupe(u8, page.title);
    errdefer gpa.free(result.title);
    result.retry = if (page.retry) |*message| try message.dupe(gpa) else null;
    errdefer if (result.retry) |*message| message.deinit(gpa);
    result.notice = if (page.notice) |*message| try message.dupe(gpa) else null;
    return result;
}

fn freePage(gpa: std.mem.Allocator, page: *const Page) void {
    gpa.free(page.title);
    if (page.retry) |*message| message.deinit(gpa);
    if (page.notice) |*message| message.deinit(gpa);
}
