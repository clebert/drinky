//! The model list of both xAI accounts. `GET /v1/models` answers in the OpenAI
//! list format under either credential: the subscription token and the API key
//! are both bearer tokens of the public API. Drinky reads the id and the aliases
//! alone, because the list holds image and video models beside the chat models,
//! and the aggregator names the chat models under one of those spellings.

const std = @import("std");

const Model = @import("../Model.zig");
const net = @import("../net.zig");
const openai_models = @import("../openai/models.zig");

const endpoint = "https://api.x.ai/v1/models";

/// Every model that the bearer `token` can name. The caller owns the result.
/// The `deadline` bounds the request.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    token: []const u8,
) ![]Model {
    return openai_models.fetchList(gpa, io, deadline, &.{ .endpoint = endpoint, .token = token });
}

// The list shares the deadline of the fetch around it, so a window that has
// closed refuses the request before it opens a socket.
test "an expired deadline refuses the list without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetch(std.testing.allocator, io, expired, "xai-key"),
    );
}
