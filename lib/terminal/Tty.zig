//! Owns the controlling terminal for the session: enters raw mode on `init`,
//! restores it on `deinit`, exposes the window size, reads stdin with a timeout,
//! and hands out a buffered stdout stream. Pin the value (it is self-referential
//! through the output buffer) and call `init` on the pointer.

const std = @import("std");

const escape = @import("escape.zig");

const Tty = @This();

// The read path (`in_handle`) and the write path (`out_handle`, `out_stream`,
// `out_buffer`) share no mutable field, so an input-reader task blocked in `read`
// and a render consumer writing through `writer` can run concurrently without a
// lock. `original` and `raw_state` belong to the setup/teardown path alone and are
// never touched while a reader runs. Preserve that split: do not add a field both
// the read and write paths touch.
io: std.Io,
in_handle: std.posix.fd_t,
out_handle: std.posix.fd_t,
original: std.posix.termios,
raw_state: RawState,
out_buffer: [16384]u8,
out_stream: std.Io.File.Writer,

pub const Size = struct { columns: u16, rows: u16 };

const RawState = struct {
    raw_owned: bool = false,
    paste_reset_pending: bool = false,
    keyboard_reset_pending: bool = false,
    cursor_show_pending: bool = false,
    setup_complete: bool = false,
};

const PosixSetup = struct {
    in_handle: std.posix.fd_t,
    raw: *const std.posix.termios,
    original: *const std.posix.termios,

    fn setRaw(self: *const PosixSetup) !void {
        try std.posix.tcsetattr(self.in_handle, .FLUSH, self.raw.*);
    }

    fn restore(self: *const PosixSetup) !void {
        try std.posix.tcsetattr(self.in_handle, .FLUSH, self.original.*);
    }
};

const PosixRestore = struct {
    in_handle: std.posix.fd_t,
    original: *const std.posix.termios,

    fn restore(self: *const PosixRestore) !void {
        try std.posix.tcsetattr(self.in_handle, .FLUSH, self.original.*);
    }
};

pub fn init(self: *Tty, io: std.Io) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    self.io = io;
    self.in_handle = stdin.handle;
    self.out_handle = stdout.handle;
    self.raw_state = .{};
    self.original = try std.posix.tcgetattr(self.in_handle);
    self.out_stream = stdout.writerStreaming(io, &self.out_buffer);
    try self.enterRaw();
}

pub fn deinit(self: *Tty) void {
    self.leaveRaw();
}

/// Enter raw mode and enable the input/render escape modes. Used at startup and
/// to restore the interface after a suspend (`leaveRaw`).
pub fn enterRaw(self: *Tty) !void {
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
    var control: PosixSetup = .{
        .in_handle = self.in_handle,
        .raw = &raw,
        .original = &self.original,
    };
    try enterWith(&self.raw_state, &self.out_stream.interface, &control);
}

/// Reverse the escape modes and restore the terminal's original cooked state, so
/// plain output is readable. Used at shutdown (`deinit`) and to suspend the
/// interface for a mid-session login flow; pair with `enterRaw` to resume.
pub fn leaveRaw(self: *Tty) void {
    var control: PosixRestore = .{
        .in_handle = self.in_handle,
        .original = &self.original,
    };
    leaveWith(&self.raw_state, &self.out_stream.interface, &control);
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

fn enterWith(state: *RawState, output: *std.Io.Writer, control: anytype) !void {
    try control.setRaw();
    state.raw_owned = true;
    errdefer rollbackWith(state, output, control);

    state.paste_reset_pending = true;
    try output.writeAll(escape.paste_set);
    state.keyboard_reset_pending = true;
    try output.writeAll(escape.keyboard_set);
    state.cursor_show_pending = true;
    try output.writeAll(escape.cursor_hide);
    try output.flush();
    state.setup_complete = true;
}

fn rollbackWith(state: *RawState, output: *std.Io.Writer, control: anytype) void {
    cleanupWith(state, output, control, false);
}

fn leaveWith(state: *RawState, output: *std.Io.Writer, control: anytype) void {
    cleanupWith(state, output, control, true);
}

fn cleanupWith(
    state: *RawState,
    output: *std.Io.Writer,
    control: anytype,
    write_newline: bool,
) void {
    var flush_needed = false;
    if (state.cursor_show_pending) {
        state.cursor_show_pending = false;
        flush_needed = true;
        output.writeAll(escape.cursor_show) catch {};
    }
    if (state.keyboard_reset_pending) {
        state.keyboard_reset_pending = false;
        flush_needed = true;
        output.writeAll(escape.keyboard_reset) catch {};
    }
    if (state.paste_reset_pending) {
        state.paste_reset_pending = false;
        flush_needed = true;
        output.writeAll(escape.paste_reset) catch {};
    }
    if (state.setup_complete) {
        state.setup_complete = false;
        if (write_newline) {
            flush_needed = true;
            output.writeAll("\r\n") catch {};
        }
    }
    if (flush_needed) output.flush() catch {};
    if (state.raw_owned) {
        control.restore() catch return;
        state.raw_owned = false;
    }
}

const TestControl = struct {
    raw: bool = false,
    set_count: usize = 0,
    restore_count: usize = 0,
    restore_fails: bool = false,

    fn setRaw(self: *TestControl) !void {
        self.set_count += 1;
        self.raw = true;
    }

    fn restore(self: *TestControl) !void {
        self.restore_count += 1;
        if (self.restore_fails) return error.RestoreFailed;
        self.raw = false;
    }
};

const TestWriter = struct {
    interface: std.Io.Writer = .{
        .vtable = &.{ .drain = drain, .flush = flush },
        .buffer = &.{},
    },
    operations: [16]Operation = undefined,
    operations_len: usize = 0,
    drain_count: usize = 0,
    flush_count: usize = 0,
    drain_fail_at: ?usize = null,
    drain_fail_again_at: ?usize = null,
    flush_fail_at: ?usize = null,
    flush_fail_again_at: ?usize = null,

    const Operation = enum {
        paste_set,
        keyboard_set,
        cursor_hide,
        cursor_show,
        keyboard_reset,
        paste_reset,
        newline,
        flush,
    };

    fn record(self: *TestWriter, item: Operation) void {
        self.operations[self.operations_len] = item;
        self.operations_len += 1;
    }

    fn drain(
        interface: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *TestWriter = @alignCast(@fieldParentPtr("interface", interface));
        std.debug.assert(data.len == 1);
        std.debug.assert(splat == 1);
        self.drain_count += 1;
        self.record(operation(data[0]));
        if (self.drain_fail_at == self.drain_count or
            self.drain_fail_again_at == self.drain_count)
        {
            return error.WriteFailed;
        }
        return data[0].len;
    }

    fn flush(interface: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *TestWriter = @alignCast(@fieldParentPtr("interface", interface));
        self.flush_count += 1;
        self.record(.flush);
        if (self.flush_fail_at == self.flush_count or
            self.flush_fail_again_at == self.flush_count)
        {
            return error.WriteFailed;
        }
    }

    fn operation(bytes: []const u8) Operation {
        if (std.mem.eql(u8, bytes, escape.paste_set)) return .paste_set;
        if (std.mem.eql(u8, bytes, escape.keyboard_set)) return .keyboard_set;
        if (std.mem.eql(u8, bytes, escape.cursor_hide)) return .cursor_hide;
        if (std.mem.eql(u8, bytes, escape.cursor_show)) return .cursor_show;
        if (std.mem.eql(u8, bytes, escape.keyboard_reset)) return .keyboard_reset;
        if (std.mem.eql(u8, bytes, escape.paste_reset)) return .paste_reset;
        if (std.mem.eql(u8, bytes, "\r\n")) return .newline;
        unreachable;
    }
};

const FailureOptions = struct {
    drain_at: ?usize = null,
    drain_again_at: ?usize = null,
    flush_at: ?usize = null,
    flush_again_at: ?usize = null,
};

fn expectSetupFailure(
    expected: []const TestWriter.Operation,
    options: *const FailureOptions,
) !void {
    var output: TestWriter = .{
        .drain_fail_at = options.drain_at,
        .drain_fail_again_at = options.drain_again_at,
        .flush_fail_at = options.flush_at,
        .flush_fail_again_at = options.flush_again_at,
    };
    var control: TestControl = .{};
    var state: RawState = .{};

    try std.testing.expectError(
        error.WriteFailed,
        enterWith(&state, &output.interface, &control),
    );
    rollbackWith(&state, &output.interface, &control);

    try std.testing.expect(!control.raw);
    try std.testing.expectEqual(@as(usize, 1), control.set_count);
    try std.testing.expectEqual(@as(usize, 1), control.restore_count);
    try std.testing.expectEqual(RawState{}, state);
    try std.testing.expectEqualSlices(
        TestWriter.Operation,
        expected,
        output.operations[0..output.operations_len],
    );
}

test "setup failure restores cooked mode and only reverses attempted terminal modes" {
    try expectSetupFailure(
        &.{ .paste_set, .paste_reset, .flush },
        &.{ .drain_at = 1, .flush_at = 1 },
    );
    try expectSetupFailure(
        &.{ .paste_set, .keyboard_set, .keyboard_reset, .paste_reset, .flush },
        &.{ .drain_at = 2 },
    );
    try expectSetupFailure(
        &.{
            .paste_set,
            .keyboard_set,
            .cursor_hide,
            .cursor_show,
            .keyboard_reset,
            .paste_reset,
            .flush,
        },
        &.{ .drain_at = 3, .drain_again_at = 4, .flush_at = 1 },
    );
    try expectSetupFailure(
        &.{
            .paste_set,
            .keyboard_set,
            .cursor_hide,
            .flush,
            .cursor_show,
            .keyboard_reset,
            .paste_reset,
            .flush,
        },
        &.{ .flush_at = 1, .flush_again_at = 2 },
    );
}

test "setup rollback preserves the setup error when termios restoration fails" {
    var output: TestWriter = .{ .drain_fail_at = 1 };
    var control: TestControl = .{ .restore_fails = true };
    var state: RawState = .{};

    try std.testing.expectError(
        error.WriteFailed,
        enterWith(&state, &output.interface, &control),
    );
    try std.testing.expect(control.raw);
    try std.testing.expect(state.raw_owned);
    try std.testing.expectEqual(@as(usize, 1), control.restore_count);

    control.restore_fails = false;
    rollbackWith(&state, &output.interface, &control);
    rollbackWith(&state, &output.interface, &control);
    try std.testing.expect(!control.raw);
    try std.testing.expectEqual(@as(usize, 2), control.restore_count);
    try std.testing.expectEqual(RawState{}, state);
    try std.testing.expectEqualSlices(
        TestWriter.Operation,
        &.{ .paste_set, .paste_reset, .flush },
        output.operations[0..output.operations_len],
    );
}

test "successful setup and repeated cleanup manage every terminal mode once" {
    var output: TestWriter = .{};
    var control: TestControl = .{};
    var state: RawState = .{};

    try enterWith(&state, &output.interface, &control);

    try std.testing.expect(control.raw);
    try std.testing.expectEqual(@as(usize, 1), control.set_count);
    try std.testing.expectEqual(@as(usize, 0), control.restore_count);
    try std.testing.expectEqualSlices(
        TestWriter.Operation,
        &.{ .paste_set, .keyboard_set, .cursor_hide, .flush },
        output.operations[0..output.operations_len],
    );

    leaveWith(&state, &output.interface, &control);
    leaveWith(&state, &output.interface, &control);
    try std.testing.expect(!control.raw);
    try std.testing.expectEqual(@as(usize, 1), control.restore_count);
    try std.testing.expectEqual(RawState{}, state);
    try std.testing.expectEqualSlices(
        TestWriter.Operation,
        &.{
            .paste_set,
            .keyboard_set,
            .cursor_hide,
            .flush,
            .cursor_show,
            .keyboard_reset,
            .paste_reset,
            .newline,
            .flush,
        },
        output.operations[0..output.operations_len],
    );
}
