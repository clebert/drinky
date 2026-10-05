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
        variables: []const Variable,
    ) Error!Tool.Output,
    takeSkill: *const fn (
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        items: []const Conversation.Item,
    ) Error!?Skill,
    reset: *const fn (ptr: *anyopaque) void,
};

pub const Error = error{ Canceled, OutOfMemory };

pub const Variable = struct {
    name: []const u8,
    value: []const u8,

    pub fn dupeAll(
        gpa: std.mem.Allocator,
        variables: []const Variable,
    ) error{OutOfMemory}![]Variable {
        const copies = try gpa.alloc(Variable, variables.len);
        var count: usize = 0;
        errdefer {
            for (copies[0..count]) |*copy| copy.deinit(gpa);
            gpa.free(copies);
        }
        for (variables, copies) |*variable, *copy| {
            const name = try gpa.dupe(u8, variable.name);
            errdefer gpa.free(name);
            copy.* = .{ .name = name, .value = try gpa.dupe(u8, variable.value) };
            count += 1;
        }
        return copies;
    }

    pub fn freeAll(gpa: std.mem.Allocator, variables: []const Variable) void {
        for (variables) |*variable| variable.deinit(gpa);
        gpa.free(variables);
    }

    fn deinit(self: *const Variable, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.value);
    }
};

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
    variables: []const Variable,
) Error!Tool.Output {
    return self.vtable.run(self.ptr, gpa, call, items, variables);
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
