//! A SIGWINCH watcher built on the self-pipe trick: a POSIX signal handler is
//! async-signal-safe only and cannot enqueue onto a locked channel, so the
//! handler just writes one byte to a pipe and `wait` blocks reading the other
//! end — turning a resize signal into an ordinary awaitable fd event a producer
//! task can relay as a `UiEvent`. The read end is blocking (so `wait` parks on it
//! through `io.operateTimeout(.none)`, whose single-fd path is a direct read) and
//! the write end is non-blocking (so a full pipe drops the redundant wake instead
//! of stalling the handler). Signals are process-wide, so at most one watcher is
//! live at a time, and the self-pipe is opened once and kept for the process
//! lifetime — never closed, so a handler preempted mid-write can never resume onto
//! a closed and possibly reused descriptor.
//!
//! Everything here stays portable and libc-free where the platform allows it by
//! going through `std.Io.Threaded.pipe2` and `std.posix.system` rather than a
//! per-OS syscall layer; on macOS those route through libc, which Zig requires
//! there regardless.

const std = @import("std");

const Resize = @This();

/// The write end, reached only by the signal handler, which takes no context
/// argument — hence a process-global. Holds the write fd while a watcher is
/// installed, `-1` otherwise.
var handler_pipe: std.atomic.Value(std.posix.fd_t) = .init(-1);

/// The process-lifetime self-pipe, opened once by `ensurePipe` and never closed:
/// leaving it open is what keeps a preempted handler's write off a closed—and
/// possibly reused—descriptor. Signals are process-wide (at most one watcher at a
/// time), so one shared pipe serves every watcher; only the serial control thread
/// that drives init/deinit touches it.
var shared_pipe: ?Pipe = null;

const Pipe = struct {
    read: std.posix.fd_t,
    write: std.posix.fd_t,
};

read_handle: std.posix.fd_t,
previous: std.posix.Sigaction,

/// The one async-signal-safe action: write a byte to wake `wait`. A dropped write
/// (pipe full, or no watcher) is fine — a pending wake already covers the resize.
fn handleWinch(_: std.posix.SIG) callconv(.c) void {
    const handle = handler_pipe.load(.seq_cst);
    if (handle < 0) return;
    const byte = [_]u8{0};
    _ = std.posix.system.write(handle, &byte, byte.len);
}

/// Return the process-lifetime self-pipe, opening it on first use: a CLOEXEC pipe
/// with a non-blocking write end (a full pipe drops the redundant wake instead of
/// stalling the handler). Never closed thereafter, so the handler's target fd is
/// always valid.
fn ensurePipe() !Pipe {
    if (shared_pipe) |pipe| return pipe;
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
    }
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    const result = std.posix.system.fcntl(fds[1], std.posix.F.SETFL, nonblock);
    switch (std.posix.errno(result)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    const pipe: Pipe = .{ .read = fds[0], .write = fds[1] };
    shared_pipe = pipe;
    return pipe;
}

/// Point the handler at the shared self-pipe and install the SIGWINCH handler,
/// saving the prior disposition for `deinit`.
pub fn init(self: *Resize) !void {
    const pipe = try ensurePipe();
    self.read_handle = pipe.read;
    handler_pipe.store(pipe.write, .seq_cst);
    std.posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = handleWinch },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &self.previous);
}

/// Restore the previous SIGWINCH disposition and disarm the handler. The self-pipe
/// is left open (it is process-lifetime), so a handler that already loaded the write
/// fd and is preempted here resumes into a still-valid pipe rather than a closed—and
/// possibly reused—descriptor. Call once the `wait` task is reaped, so nothing is
/// left blocked on the pipe.
pub fn deinit(self: *Resize) void {
    std.posix.sigaction(.WINCH, &self.previous, null);
    handler_pipe.store(-1, .seq_cst);
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

test "deinit keeps both self-pipe endpoints alive and reuses them" {
    // Keeping both self-pipe endpoints open for the process lifetime defuses both
    // teardown-race failure modes: an open write fd is never reused under a stale
    // handler write, and an open read end keeps that write off a reader-less pipe
    // (SIGPIPE). deinit must also disarm the handler (-1), and a later watcher must
    // reuse the one shared pipe rather than open another. F_GETFD reports EBADF on a
    // closed fd.
    var resize: Resize = undefined;
    try resize.init();
    const read_handle = resize.read_handle;
    const write_handle = handler_pipe.load(.seq_cst);
    resize.deinit();

    try std.testing.expectEqual(@as(std.posix.fd_t, -1), handler_pipe.load(.seq_cst));
    for ([_]std.posix.fd_t{ read_handle, write_handle }) |handle| {
        const flags = std.posix.system.fcntl(handle, std.posix.F.GETFD, @as(u32, 0));
        try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(flags));
    }

    var next: Resize = undefined;
    try next.init();
    defer next.deinit();
    try std.testing.expectEqual(read_handle, next.read_handle);
    try std.testing.expectEqual(write_handle, handler_pipe.load(.seq_cst));
}
