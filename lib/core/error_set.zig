const std = @import("std");

pub fn requireMember(comptime Set: type, comptime err: anyerror) void {
    @setEvalBranchQuota(100_000);
    for (@typeInfo(Set).error_set.?) |member| {
        if (std.mem.eql(u8, member.name, @errorName(err))) return;
    }
    @compileError("The error " ++ @errorName(err) ++ " needs its own arm.");
}

test "an arm that groups errors takes each member of its set" {
    try std.testing.expectEqual(.named, classify(error.Named));
    try std.testing.expectEqual(.grouped, classify(error.Grouped));
    try std.testing.expectEqual(.grouped, classify(error.Other));
}

fn classify(err: error{ Named, Grouped, Other }) enum { named, grouped } {
    switch (err) {
        error.Named => return .named,
        inline else => |cause| comptime requireMember(error{ Grouped, Other }, cause),
    }
    return .grouped;
}
