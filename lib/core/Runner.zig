const std = @import("std");

const Conversation = @import("Conversation.zig");
const Tool = @import("Tool.zig");

const Runner = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    run: *const fn (
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        call: *const Tool.Call,
        items: []const Conversation.Item,
    ) Error!Tool.Output,
    takeSkill: *const fn (
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        items: []const Conversation.Item,
    ) Error!?Skill,
    reset: *const fn (ptr: *anyopaque) void,
};

pub const Error = error{ Canceled, OutOfMemory };

pub const Skill = struct {
    name: []const u8,
    source: []const u8,
    text: []const u8,

    pub fn deinit(self: *const Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.source);
        gpa.free(self.text);
    }
};

pub fn run(
    self: Runner,
    gpa: std.mem.Allocator,
    call: *const Tool.Call,
    items: []const Conversation.Item,
) Error!Tool.Output {
    return self.vtable.run(self.ptr, gpa, call, items);
}

pub fn takeSkill(
    self: Runner,
    gpa: std.mem.Allocator,
    items: []const Conversation.Item,
) Error!?Skill {
    return self.vtable.takeSkill(self.ptr, gpa, items);
}

pub fn reset(self: Runner) void {
    self.vtable.reset(self.ptr);
}
