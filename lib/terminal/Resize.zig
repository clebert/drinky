//! A SIGWINCH watcher built on the self-pipe trick: a POSIX signal handler is
//! async-signal-safe only and cannot enqueue onto a locked channel, so the
//! handler just writes one byte to a pipe and `wait` blocks reading the other
//! end — turning a resize signal into an ordinary awaitable fd event a producer
//! task can relay as a `UiEvent`. The read end is blocking (so `wait` parks on it
//! through `io.operateTimeout(.none)`, whose single-fd path is a direct read) and
//! the write end is non-blocking (so a full pipe drops the redundant wake instead
//! of stalling the handler). Signals are process-wide, so at most one watcher is
//! live at a time.
//!
//! Everything here stays portable and libc-free where the platform allows it by
//! going through `std.Io.Threaded.pipe2` and `std.posix.system` rather than a
//! per-OS syscall layer; on macOS those route through libc, which Zig requires
//! there regardless.

const std = @import("std");

const Resize = @This();

/// The write end, reached only by the signal handler, which takes no context
/// argument — hence a process-global. `-1` while no watcher is installed.
var handler_pipe: std.atomic.Value(std.posix.fd_t) = .init(-1);

read_handle: std.posix.fd_t,
write_handle: std.posix.fd_t,
previous: std.posix.Sigaction,

/// The one async-signal-safe action: write a byte to wake `wait`. A dropped write
/// (pipe full, or no watcher) is fine — a pending wake already covers the resize.
fn handleWinch(_: std.posix.SIG) callconv(.c) void {
    const handle = handler_pipe.load(.seq_cst);
    if (handle < 0) return;
    const byte = [_]u8{0};
    _ = std.posix.system.write(handle, &byte, byte.len);
}

/// Open the self-pipe, make the write end non-blocking, point the handler at it,
/// and install the SIGWINCH handler, saving the prior disposition for `deinit`.
pub fn init(self: *Resize) !void {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    self.read_handle = fds[0];
    self.write_handle = fds[1];
    errdefer {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
    }

    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    switch (std.posix.errno(std.posix.system.fcntl(self.write_handle, std.posix.F.SETFL, nonblock))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }

    handler_pipe.store(self.write_handle, .seq_cst);
    std.posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = handleWinch },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &self.previous);
}

/// Restore the previous SIGWINCH disposition, then close the pipe. Call only once
/// the `wait` task is reaped, so nothing reads the pipe as it closes. A handler
/// firing at this instant may still write one byte to the closing fd; that write
/// is ignored (`EBADF`), so the only cost is a dropped, no-longer-wanted wake.
pub fn deinit(self: *Resize) void {
    std.posix.sigaction(.WINCH, &self.previous, null);
    handler_pipe.store(-1, .seq_cst);
    _ = std.posix.system.close(self.read_handle);
    _ = std.posix.system.close(self.write_handle);
}

/// Block until the next resize, draining the coalesced wake bytes. Surfaces
/// `error.Canceled` when the awaiting task is cancelled at shutdown.
pub fn wait(self: *Resize, io: std.Io) !void {
    var buffer: [64]u8 = undefined;
    var chunk: [1][]u8 = .{buffer[0..]};
    const result = try io.operateTimeout(.{ .file_read_streaming = .{
        .file = .{ .handle = self.read_handle, .flags = .{ .nonblocking = false } },
        .data = &chunk,
    } }, .none);
    _ = try result.file_read_streaming;
}

test "a sigwinch wakes wait and deinit restores the prior disposition" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.WINCH, null, &before);
    var resize: Resize = undefined;
    try resize.init();
    try std.posix.raise(.WINCH);
    try std.posix.raise(.WINCH);
    try resize.wait(io);
    resize.deinit();
    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(.WINCH, null, &after);
    try std.testing.expectEqual(before.handler.handler, after.handler.handler);
    try std.posix.raise(.WINCH);
}
