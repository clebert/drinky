//! Owns the controlling terminal for the session: enters raw mode on `init`,
//! restores it on `deinit`, exposes the window size, and hands out buffered
//! stdin/stdout streams. Pin the value (it is self-referential through the
//! stream buffers) and call `init` on the pointer.

const std = @import("std");

const escape = @import("escape.zig");

const Tty = @This();

pub const Size = struct { rows: u16, columns: u16 };

io: std.Io,
in_handle: std.posix.fd_t,
out_handle: std.posix.fd_t,
original: std.posix.termios,
in_buffer: [4096]u8,
out_buffer: [16384]u8,
in_stream: std.Io.File.Reader,
out_stream: std.Io.File.Writer,

pub fn init(self: *Tty, io: std.Io) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    self.io = io;
    self.in_handle = stdin.handle;
    self.out_handle = stdout.handle;
    self.original = try std.posix.tcgetattr(self.in_handle);

    var raw = self.original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(self.in_handle, .FLUSH, raw);

    self.in_stream = stdin.readerStreaming(io, &self.in_buffer);
    self.out_stream = stdout.writerStreaming(io, &self.out_buffer);

    const out = &self.out_stream.interface;
    try out.writeAll(escape.paste_set);
    try out.writeAll(escape.cursor_hide);
    try out.flush();
}

pub fn deinit(self: *Tty) void {
    const out = &self.out_stream.interface;
    out.writeAll(escape.paste_reset) catch {};
    out.writeAll(escape.cursor_show) catch {};
    out.writeAll("\r\n") catch {};
    out.flush() catch {};
    std.posix.tcsetattr(self.in_handle, .FLUSH, self.original) catch {};
}

pub fn writer(self: *Tty) *std.Io.Writer {
    return &self.out_stream.interface;
}

pub fn reader(self: *Tty) *std.Io.Reader {
    return &self.in_stream.interface;
}

/// Current window size, falling back to 80x24 if the query fails.
pub fn size(self: *Tty) Size {
    var window: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = self.io.operate(.{ .device_io_control = .{
        .file = .{ .handle = self.out_handle, .flags = .{ .nonblocking = false } },
        .code = std.posix.T.IOCGWINSZ,
        .arg = &window,
    } }) catch return .{ .rows = 24, .columns = 80 };
    if (result.device_io_control < 0 or window.col == 0) return .{ .rows = 24, .columns = 80 };
    return .{ .rows = window.row, .columns = window.col };
}
