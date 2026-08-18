//! The retry context of the latest failed turn. It holds the failure sentence
//! that the turn reported, and it composes the request that one more attempt
//! sends. `App` owns at most one context, and only at the prompt, because an
//! attempt takes the context with it.
//!
//! A context exists only for a turn that committed work. The attempt then asks
//! the model to continue from that work. A turn that committed nothing needs no
//! context, because its request returns to the editor.
//!
//! A context never wraps an older attempt: a retry request carries the latest
//! failure alone.

const std = @import("std");

const Retry = @This();

/// The latest complete failure sentence. Owned.
failure: []const u8,

/// The transcript event that reports one attempt. The request itself stays out
/// of the transcript, as a skill marker keeps its expanded file out of it.
pub const event_text = "Pith asked the model to continue from the committed work.";

/// The line that tells the model where to continue.
const continuation = "Continue from the last committed checkpoint.";

pub fn deinit(self: *const Retry, gpa: std.mem.Allocator) void {
    gpa.free(self.failure);
}

/// The provider `user` message of one attempt. `input` holds the editor text that
/// the user adds, and an empty `input` adds none. The result is owned.
///
/// The tags are prompt markers, not a parse boundary. Pith inserts the failure
/// sentence and the editor text verbatim, so a body that carries a matching tag
/// only blurs the guidance. Nothing parses this message back.
pub fn compose(self: *const Retry, gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) return std.fmt.allocPrint(
        gpa,
        "<retry_request>\n{s}\n" ++ continuation ++ "\n</retry_request>",
        .{self.failure},
    );
    return std.fmt.allocPrint(
        gpa,
        "<retry_request>\n{s}\n" ++ continuation ++
            "\n\n<retry_input>\n{s}\n</retry_input>\n</retry_request>",
        .{ self.failure, input },
    );
}

test "an attempt names the failure and carries the optional editor text" {
    const gpa = std.testing.allocator;
    const retry: Retry = .{ .failure = "The provider did not respond in time." };

    const alone = try retry.compose(gpa, "");
    defer gpa.free(alone);
    try std.testing.expectEqualStrings(
        \\<retry_request>
        \\The provider did not respond in time.
        \\Continue from the last committed checkpoint.
        \\</retry_request>
    , alone);

    const added = try retry.compose(gpa, "keep the public format");
    defer gpa.free(added);
    try std.testing.expectEqualStrings(
        \\<retry_request>
        \\The provider did not respond in time.
        \\Continue from the last committed checkpoint.
        \\
        \\<retry_input>
        \\keep the public format
        \\</retry_input>
        \\</retry_request>
    , added);
}

test "a newer failure replaces the sentence and never nests an older request" {
    const gpa = std.testing.allocator;
    const first: Retry = .{ .failure = "The provider is overloaded." };
    const older = try first.compose(gpa, "");
    defer gpa.free(older);

    // The context keeps a sentence, never a composed request, so the next attempt
    // cannot carry the wrapper of the attempt before it.
    const second: Retry = .{ .failure = "The model returned an empty response." };
    const newer = try second.compose(gpa, "");
    defer gpa.free(newer);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, newer, "<retry_request>"),
    );
    try std.testing.expect(std.mem.indexOf(u8, newer, "overloaded") == null);
    try std.testing.expect(std.mem.indexOf(u8, newer, "empty response") != null);
}
