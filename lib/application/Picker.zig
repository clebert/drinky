const std = @import("std");

const Picker = @This();

id: u64 = 0,
title: []const u8,
options: []const Option,
current: ?usize = null,
preselected: ?usize = null,
cursor: ?usize = null,
depth: usize = 0,

pub const Option = struct {
    name: []const u8,
    extra: ?[]const u8 = null,
    extra_pressure: bool = false,
    tag: ?[]const u8 = null,
    tag_pressure: bool = false,

    pub fn dupe(self: *const Option, gpa: std.mem.Allocator) error{OutOfMemory}!Option {
        var result = self.*;
        result.name = try gpa.dupe(u8, self.name);
        errdefer gpa.free(result.name);
        result.extra = if (self.extra) |extra| try gpa.dupe(u8, extra) else null;
        errdefer if (result.extra) |extra| gpa.free(extra);
        result.tag = if (self.tag) |tag| try gpa.dupe(u8, tag) else null;
        return result;
    }

    pub fn deinit(self: *const Option, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.extra) |extra| gpa.free(extra);
        if (self.tag) |tag| gpa.free(tag);
    }
};

pub fn dupe(self: *const Picker, gpa: std.mem.Allocator) error{OutOfMemory}!Picker {
    var result = self.*;
    result.title = try gpa.dupe(u8, self.title);
    errdefer gpa.free(result.title);
    const options = try gpa.alloc(Option, self.options.len);
    errdefer gpa.free(options);
    var count: usize = 0;
    errdefer for (options[0..count]) |*option| option.deinit(gpa);
    for (self.options, options) |*source, *target| {
        target.* = try source.dupe(gpa);
        count += 1;
    }
    result.options = options;
    return result;
}

pub fn deinit(self: *const Picker, gpa: std.mem.Allocator) void {
    gpa.free(self.title);
    for (self.options) |*option| option.deinit(gpa);
    gpa.free(self.options);
}
