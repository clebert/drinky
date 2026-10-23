const std = @import("std");
const Live = @import("Live.zig");
const Record = @import("Record.zig");
const Settings = @import("Settings.zig");
const State = @import("State.zig");
const Surface = @import("Surface.zig");

const Snapshot = @This();

records: []const Record,
live: Live = .{},
statistics: Surface.Statistics,
state: State,
settings: Settings = .{},
working_directory: []const u8,
home_directory: []const u8,

pub fn dupe(self: *const Snapshot, gpa: std.mem.Allocator) error{OutOfMemory}!Snapshot {
    var result = self.*;
    result.records = try dupeRecords(gpa, self.records);
    errdefer freeRecords(gpa, result.records);
    result.live = try self.live.dupe(gpa);
    errdefer result.live.deinit(gpa);
    result.state = try self.state.dupe(gpa);
    errdefer result.state.deinit(gpa);
    result.working_directory = try gpa.dupe(u8, self.working_directory);
    errdefer gpa.free(result.working_directory);
    result.home_directory = try gpa.dupe(u8, self.home_directory);
    return result;
}

pub fn deinit(self: *const Snapshot, gpa: std.mem.Allocator) void {
    freeRecords(gpa, self.records);
    self.live.deinit(gpa);
    self.state.deinit(gpa);
    gpa.free(self.working_directory);
    gpa.free(self.home_directory);
}

fn dupeRecords(gpa: std.mem.Allocator, records: []const Record) error{OutOfMemory}![]Record {
    const owned = try gpa.alloc(Record, records.len);
    errdefer gpa.free(owned);
    var count: usize = 0;
    errdefer freeRecordItems(gpa, owned[0..count]);
    for (records, owned) |*source, *target| {
        target.* = try source.dupe(gpa);
        count += 1;
    }
    return owned;
}
fn freeRecordItems(gpa: std.mem.Allocator, records: []const Record) void {
    for (records) |record| {
        var owned = record;
        owned.deinit(gpa);
    }
}
fn freeRecords(gpa: std.mem.Allocator, records: []const Record) void {
    freeRecordItems(gpa, records);
    gpa.free(records);
}
