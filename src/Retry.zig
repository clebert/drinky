//! The retry context of the latest failed turn: the failure sentence and the
//! request that one more attempt sends. `App` owns at most one, only at the
//! prompt, because the start of any turn takes it. Only a turn that committed
//! work leaves one, so the attempt asks the model to continue from that work.
//! The request carries no user text, because a network or provider failure is
//! nothing a user instruction prevents.

const std = @import("std");

const Retry = @This();

/// The latest complete failure sentence. Owned.
failure: []const u8,

/// The transcript line of one attempt. Drinky wrote the message, so the line
/// takes the user color and no box, and the request stays out of the transcript.
pub const note_text = "Drinky asked the model to continue from the committed work.";

const continuation = "Continue from the last committed checkpoint.";

pub fn deinit(self: *const Retry, gpa: std.mem.Allocator) void {
    gpa.free(self.failure);
}

/// The provider `user` message of one attempt. The tags mark the message as
/// one that Drinky wrote. Nothing parses it back.
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
