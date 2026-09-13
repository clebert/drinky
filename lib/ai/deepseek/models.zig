//! The model list of the DeepSeek API-key account. `GET /v1/models` answers in
//! the OpenAI list format under a bearer key. Drinky reads the id alone. Every
//! other field of such a model comes from the public metadata.

const std = @import("std");

const Model = @import("../Model.zig");
const net = @import("../net.zig");
const openai_models = @import("../openai/models.zig");

const endpoint = "https://api.deepseek.com/v1/models";

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
        fetch(std.testing.allocator, io, expired, "sk-deepseek"),
    );
}
