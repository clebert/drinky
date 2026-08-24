//! The retry context of the latest failed turn. It holds the failure sentence
//! that the turn reported, and it composes the request that one more attempt
//! sends. `App` owns at most one context, and only at the prompt, because the
//! start of any turn takes it.
//!
//! A context exists only for a turn that committed work. The attempt then asks
//! the model to continue from that work. A turn that committed nothing needs no
//! context, because its request returns to the editor.
//!
//! The request carries no user text. A failure of the network or of the provider
//! is nothing a user instruction prevents, so the attempt asks for the work alone.
//! The editor keeps what it holds, and the user sends that text as a message of
//! its own.
//!
//! A context never wraps an older attempt: a retry request carries the latest
//! failure alone.

const std = @import("std");

const Retry = @This();

/// The latest complete failure sentence. Owned.
failure: []const u8,

/// The transcript line that reports one attempt. Drinky wrote the message that
/// the attempt sends, so the line takes the user color and no box. The request
/// itself stays out of the transcript, as a skill marker keeps its expanded file
/// out of it.
pub const note_text = "Drinky asked the model to continue from the committed work.";

/// The line that tells the model where to continue.
const continuation = "Continue from the last committed checkpoint.";

pub fn deinit(self: *const Retry, gpa: std.mem.Allocator) void {
    gpa.free(self.failure);
}

/// The provider `user` message of one attempt. The result is owned.
///
/// The tags are prompt markers, not a parse boundary. They tell the model that
/// Drinky wrote this message, because the user typed none of it. Drinky inserts the
/// failure sentence verbatim, so a sentence that carries a matching tag only
/// blurs the guidance. Nothing parses this message back.
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

test "a newer failure replaces the sentence and never nests an older request" {
    const gpa = std.testing.allocator;
    const first: Retry = .{ .failure = "The provider is overloaded." };
    const older = try first.compose(gpa);
    defer gpa.free(older);

    // The context keeps a sentence, never a composed request, so the next attempt
    // cannot carry the wrapper of the attempt before it.
    const second: Retry = .{ .failure = "The model returned an empty response." };
    const newer = try second.compose(gpa);
    defer gpa.free(newer);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, newer, "<retry_request>"),
    );
    try std.testing.expect(std.mem.indexOf(u8, newer, "overloaded") == null);
    try std.testing.expect(std.mem.indexOf(u8, newer, "empty response") != null);
}
