const std = @import("std");

const Retry = @This();

failure: []const u8,

pub const note_text = "Drinky asked the model to continue from the committed work.";

const continuation = "Continue from the last committed checkpoint.";

pub fn deinit(self: *const Retry, gpa: std.mem.Allocator) void {
    gpa.free(self.failure);
}

pub fn compose(self: *const Retry, gpa: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "<retry_request>\n{s}\n" ++ continuation ++ "\n</retry_request>",
        .{self.failure},
    );
}

test "an attempt names the failure and carries no user text" {
    const gpa = std.testing.allocator;
    const retry: Retry = .{ .failure = "The provider did not respond in time." };

    const request = try retry.compose(gpa);
    defer gpa.free(request);
    try std.testing.expectEqualStrings(
        \\<retry_request>
        \\The provider did not respond in time.
        \\Continue from the last committed checkpoint.
        \\</retry_request>
    , request);
}
