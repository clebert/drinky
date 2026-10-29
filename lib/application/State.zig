const std = @import("std");
const Choice = @import("Choice.zig");
const Record = @import("Record.zig");

const State = @This();

work: Work = .idle,
offer: Offer = .none,
notice: ?Record.Event = null,
notice_id: u64 = 0,
result: ?Result = null,
choice: Choice,
branch: ?[]const u8 = null,

pub const Work = union(enum) {
    idle,
    turn: u64,
    aside: u64,
    sign_in: SignIn,
    fetch: Fetch,

    pub fn operation(self: *const Work) ?u64 {
        return switch (self.*) {
            .idle => null,
            .turn, .aside => |id| id,
            .sign_in => |sign_in| sign_in.operation,
            .fetch => |fetch| fetch.operation,
        };
    }
};
pub const SignIn = struct { operation: u64, account: usize, callback: bool };
pub const Fetch = struct { operation: u64, account: usize };
pub const Offer = union(enum) {
    none,
    retry,
    removal: Removal,

    pub const Removal = struct { turn: u64, mutated: bool };
};
pub const Result = struct {
    id: u64,
    purpose: Purpose,
    phase: Phase,
    text: []const u8,

    pub const Purpose = enum { handoff, short_answer };
    pub const Phase = union(enum) {
        generating: Generating,
        complete,
        incomplete: Notice,
    };
    pub const Generating = struct {
        started_ms: i64,
        received_bytes: usize = 0,
        thinking: bool = false,
        retry: ?Record.Event.Attempt = null,
    };
    pub const Notice = union(enum) { truncated, failed: Record.Event.Failure };
};

pub fn dupe(self: *const State, gpa: std.mem.Allocator) error{OutOfMemory}!State {
    var result = self.*;
    result.branch = try Record.dupeData(gpa, self.branch);
    errdefer Record.freeData(gpa, &result.branch);
    result.notice = if (self.notice) |*notice| try notice.dupe(gpa) else null;
    errdefer if (result.notice) |*notice| notice.deinit(gpa);
    result.result = try Record.dupeData(gpa, self.result);
    return result;
}

pub fn deinit(self: *const State, gpa: std.mem.Allocator) void {
    Record.freeData(gpa, &self.branch);
    if (self.notice) |*notice| notice.deinit(gpa);
    Record.freeData(gpa, &self.result);
}
