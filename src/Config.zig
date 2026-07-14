//! Global configuration loaded from `<home>/.pith/config.json`. The file is
//! optional and may be partial: a missing file, a missing section, or a missing
//! field falls back to a built-in default, and unknown keys are ignored so an
//! older binary still reads a newer file. Today it configures request networking
//! (timeouts and retries); more sections join as the harness grows.
//!
//! Example:
//!   { "request": { "connect_timeout_ms": 30000, "idle_timeout_ms": 60000,
//!                  "attempts_max": 3, "backoff_ms_initial": 500,
//!                  "backoff_ms_max": 16000 } }

const std = @import("std");

const ai = @import("ai");

const Config = @This();

timeouts: ai.net.Timeouts,
retry: ai.net.Retry,

const timeouts_default: ai.net.Timeouts = .{};
const retry_default: ai.net.Retry = .{};
const default: Config = .{ .timeouts = timeouts_default, .retry = retry_default };

/// The on-disk shape. Each field defaults to the built-in, so any subset parses.
const File = struct {
    request: Request = .{},

    const Request = struct {
        connect_timeout_ms: u64 = timeouts_default.connect_ms,
        idle_timeout_ms: u64 = timeouts_default.idle_ms,
        attempts_max: u32 = retry_default.attempts_max,
        backoff_ms_initial: u64 = retry_default.backoff_ms_initial,
        backoff_ms_max: u64 = retry_default.backoff_ms_max,
    };
};

/// Load `<home>/.pith/config.json`, or the built-in defaults when it is absent.
pub fn load(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !Config {
    const path = try std.fs.path.join(gpa, &.{ home, ".pith", "config.json" });
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return default,
        else => return err,
    };
    defer gpa.free(data);
    return parse(gpa, data);
}

/// Parse config JSON, folding each section into the neutral option structs.
fn parse(gpa: std.mem.Allocator, data: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(File, gpa, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const request = parsed.value.request;
    return .{
        .timeouts = .{ .connect_ms = request.connect_timeout_ms, .idle_ms = request.idle_timeout_ms },
        .retry = .{
            .attempts_max = request.attempts_max,
            .backoff_ms_initial = request.backoff_ms_initial,
            .backoff_ms_max = request.backoff_ms_max,
        },
    };
}

test "parse reads the request section" {
    const config = try parse(std.testing.allocator,
        \\{ "request": { "connect_timeout_ms": 1000, "idle_timeout_ms": 2000,
        \\  "attempts_max": 5, "backoff_ms_initial": 100, "backoff_ms_max": 900 } }
    );
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.connect_ms);
    try std.testing.expectEqual(@as(u64, 2000), config.timeouts.idle_ms);
    try std.testing.expectEqual(@as(u32, 5), config.retry.attempts_max);
    try std.testing.expectEqual(@as(u64, 100), config.retry.backoff_ms_initial);
    try std.testing.expectEqual(@as(u64, 900), config.retry.backoff_ms_max);
}

test "parse fills missing fields and sections from defaults" {
    const partial = try parse(std.testing.allocator,
        \\{ "request": { "attempts_max": 7 } }
    );
    try std.testing.expectEqual(@as(u32, 7), partial.retry.attempts_max);
    try std.testing.expectEqual(timeouts_default.connect_ms, partial.timeouts.connect_ms);
    try std.testing.expectEqual(retry_default.backoff_ms_initial, partial.retry.backoff_ms_initial);

    const empty = try parse(std.testing.allocator, "{}");
    try std.testing.expectEqual(timeouts_default.idle_ms, empty.timeouts.idle_ms);
    try std.testing.expectEqual(retry_default.attempts_max, empty.retry.attempts_max);
}

test "parse ignores unknown keys" {
    const config = try parse(std.testing.allocator,
        \\{ "request": { "connect_timeout_ms": 42 }, "future": { "x": 1 } }
    );
    try std.testing.expectEqual(@as(u64, 42), config.timeouts.connect_ms);
}
