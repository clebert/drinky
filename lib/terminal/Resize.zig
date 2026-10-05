const std = @import("std");

const Resize = @This();

var handler_pipe: std.atomic.Value(std.posix.fd_t) = .init(-1);

var shared_pipe: ?Pipe = null;

read_handle: std.posix.fd_t,
previous: std.posix.Sigaction,

const Pipe = struct {
    read: std.posix.fd_t,
    write: std.posix.fd_t,
};

fn handleWinch(_: std.posix.SIG) callconv(.c) void {
    const handle = handler_pipe.load(.seq_cst);
    if (handle < 0) return;
    const byte = [_]u8{0};
    _ = std.posix.system.write(handle, &byte, byte.len);
}

fn ensurePipe() !Pipe {
    if (shared_pipe) |pipe| return pipe;
    const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer {
        _ = std.posix.system.close(handles[0]);
        _ = std.posix.system.close(handles[1]);
    }
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    const result = std.posix.system.fcntl(handles[1], std.posix.F.SETFL, nonblock);
    switch (std.posix.errno(result)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    const pipe: Pipe = .{ .read = handles[0], .write = handles[1] };
    shared_pipe = pipe;
    return pipe;
}

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

pub fn deinit(self: *Resize) void {
    std.posix.sigaction(.WINCH, &self.previous, null);
    handler_pipe.store(-1, .seq_cst);
}

pub fn wait(self: *Resize, io: std.Io) std.Io.File.ReadStreamingError!void {
    var buffer: [64]u8 = undefined;
    const file: std.Io.File = .{ .handle = self.read_handle, .flags = .{ .nonblocking = false } };
    _ = try file.readStreaming(io, &.{&buffer});
}

test "a sigwinch wakes wait and deinit restores the prior disposition" {
    const io = std.testing.io;
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
