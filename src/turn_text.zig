const std = @import("std");

const core = @import("core");

pub const truncated = "The reply is incomplete. The model reached an output or context limit.";
pub const exhausted = "The turn reached the limit for tool rounds.";

pub fn failureSentence(reason: core.Provider.Failure.Reason) []const u8 {
    return switch (reason) {
        .unauthorized => "The credential is missing or invalid.",
        .rate_limited => "The provider limits the request rate.",
        .quota_exhausted => "The account has no quota left.",
        .overloaded => "The provider is overloaded.",
        .invalid_request => "The request is invalid.",
        .context_overflow => "The conversation does not fit the context window of the model.",
        .network => "Drinky could not reach the provider.",
        .invalid_reply => "Drinky did not receive the complete reply of the model.",
        .empty_reply => "The model returned an empty reply.",
        .unsupported_reply => "Drinky cannot keep the reply because the model returned a " ++
            "refusal, a pause, or an unsupported result.",
        .too_many_tool_calls => "Drinky stopped the reply because it asked for too many tool " ++
            "calls.",
        .out_of_memory => "Drinky ran out of memory.",
    };
}

pub fn failureText(
    gpa: std.mem.Allocator,
    failure: *const core.Provider.Failure,
) error{OutOfMemory}![]u8 {
    const sentence = failureSentence(failure.reason);
    if (failure.message.len == 0) return gpa.dupe(u8, sentence);
    return gpa.print("{s} Details: {s}", .{ sentence, failure.message });
}

test "failure text keeps the reason sentence and adds nonempty details" {
    const cases = [_]struct { failure: core.Provider.Failure, text: []const u8 }{
        .{
            .failure = .{ .reason = .unauthorized },
            .text = "The credential is missing or invalid.",
        },
        .{
            .failure = .{ .reason = .network, .message = "Connection closed." },
            .text = "Drinky could not reach the provider. Details: Connection closed.",
        },
        .{
            .failure = .{ .reason = .out_of_memory },
            .text = "Drinky ran out of memory.",
        },
    };
    for (&cases) |*case| {
        const text = try failureText(std.testing.allocator, &case.failure);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.text, text);
    }
}
