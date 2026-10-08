const std = @import("std");

pub fn bytes(arena: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]const u8 {
    var response: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response.writer,
    });
    if (result.status != .ok) {
        std.debug.print("fetch {s} returned {d}\n", .{ url, @backingInt(result.status) });
        return error.FetchFailed;
    }
    return response.written();
}
