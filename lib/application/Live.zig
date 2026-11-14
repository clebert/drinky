const std = @import("std");

const core = @import("core");
const tools = @import("tools");

const Live = @This();

calls: []const Call = &.{},
thinking: bool = false,

pub const Call = struct {
    name: []const u8,
    argument_bytes: usize,
    opened_ms: i64,
    phase: Phase,

    pub const Phase = union(enum) {
        pending,
        running: Running,
    };

    pub const Running = struct {
        subject: ?tools.Registry.Description.Subject,
    };

    pub fn dupe(self: *const Call, gpa: std.mem.Allocator) error{OutOfMemory}!Call {
        const name = try gpa.dupe(u8, self.name);
        errdefer gpa.free(name);
        const phase: Phase = switch (self.phase) {
            .pending => .pending,
            .running => |running| .{ .running = .{
                .subject = if (running.subject) |subject| .{
                    .kind = subject.kind,
                    .text = try gpa.dupe(u8, subject.text),
                } else null,
            } },
        };
        return .{
            .name = name,
            .argument_bytes = self.argument_bytes,
            .opened_ms = self.opened_ms,
            .phase = phase,
        };
    }

    pub fn deinit(self: *const Call, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        switch (self.phase) {
            .pending => {},
            .running => |running| if (running.subject) |subject| gpa.free(subject.text),
        }
    }
};

pub fn dupe(self: *const Live, gpa: std.mem.Allocator) error{OutOfMemory}!Live {
    const calls = try gpa.alloc(Call, self.calls.len);
    errdefer gpa.free(calls);
    var count: usize = 0;
    errdefer for (calls[0..count]) |*call| call.deinit(gpa);
    for (self.calls, calls) |*source, *target| {
        target.* = try source.dupe(gpa);
        count += 1;
    }
    return .{ .calls = calls, .thinking = self.thinking };
}

pub fn deinit(self: *const Live, gpa: std.mem.Allocator) void {
    for (self.calls) |*call| call.deinit(gpa);
    gpa.free(self.calls);
}

test "a live copy releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkCopyAllocations,
        .{},
    );
}

fn checkCopyAllocations(gpa: std.mem.Allocator) !void {
    const live: Live = .{ .calls = &.{
        .{ .name = "read", .argument_bytes = 4, .opened_ms = 1, .phase = .pending },
        .{ .name = "bash", .argument_bytes = 9, .opened_ms = 2, .phase = .{ .running = .{
            .subject = .{ .kind = .command, .text = "git push" },
        } } },
    } };
    const copy = try live.dupe(gpa);
    defer copy.deinit(gpa);
    try std.testing.expectEqualStrings("git push", copy.calls[1].phase.running.subject.?.text);
}
