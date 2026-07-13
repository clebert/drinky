//! Owns the controlling terminal for the session: enters raw mode on `init`,
//! restores it on `deinit`, exposes the window size, reads stdin with a timeout,
//! and hands out a buffered stdout stream. Pin the value (it is self-referential
//! through the output buffer) and call `init` on the pointer.

const std = @import("std");

const escape = @import("escape.zig");

const Tty = @This();

io: std.Io,
in_handle: std.posix.fd_t,
out_handle: std.posix.fd_t,
original: std.posix.termios,
out_buffer: [16384]u8,
out_stream: std.Io.File.Writer,

pub const Size = struct { columns: u16, rows: u16 };

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

    self.out_stream = stdout.writerStreaming(io, &self.out_buffer);

    const out = &self.out_stream.interface;
    try out.writeAll(escape.paste_set);
    try out.writeAll(escape.keyboard_set);
    try out.writeAll(escape.cursor_hide);
    try out.flush();
}

pub fn deinit(self: *Tty) void {
    const out = &self.out_stream.interface;
    out.writeAll(escape.keyboard_reset) catch {};
    out.writeAll(escape.paste_reset) catch {};
    out.writeAll(escape.cursor_show) catch {};
    out.writeAll("\r\n") catch {};
    out.flush() catch {};
    std.posix.tcsetattr(self.in_handle, .FLUSH, self.original) catch {};
}

pub fn writer(self: *Tty) *std.Io.Writer {
    return &self.out_stream.interface;
}

/// Read available input into `buffer`, blocking until some arrives or `timeout`
/// elapses — in which case it returns null, so an idle caller can react to a
/// resize between keystrokes. A closed input surfaces as `error.EndOfStream`.
pub fn read(self: *Tty, buffer: []u8, timeout: std.Io.Timeout) !?usize {
    var chunk: [1][]u8 = .{buffer};
    const result = self.io.operateTimeout(.{ .file_read_streaming = .{
        .file = .{ .handle = self.in_handle, .flags = .{ .nonblocking = false } },
        .data = &chunk,
    } }, timeout) catch |err| switch (err) {
        error.Timeout => return null,
        else => |other| return other,
    };
    return try result.file_read_streaming;
}

/// Current window size, or null when the terminal cannot report one.
pub fn size(self: *Tty) ?Size {
    var window: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = self.io.operate(.{ .device_io_control = .{
        .file = .{ .handle = self.out_handle, .flags = .{ .nonblocking = false } },
        .code = std.posix.T.IOCGWINSZ,
        .arg = &window,
    } }) catch return null;
    if (result.device_io_control < 0 or window.col == 0) return null;
    return .{ .columns = window.col, .rows = window.row };
}
