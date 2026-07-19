//! Owns the controlling terminal for the session: enters raw mode on `init`,
//! restores it on `deinit`, exposes the window size, reads stdin with a timeout,
//! and hands out a buffered stdout stream. Pin the value (it is self-referential
//! through the output buffer) and call `init` on the pointer.

const std = @import("std");

const escape = @import("escape.zig");

const Tty = @This();

// The read path (`in_handle`) and the write path (`out_*`) share no mutable
// field, so a blocked reader and a writer run concurrently without a lock;
// `original`/`raw_state` are setup/teardown-only. Preserve that split.
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

    // Entry flushes pending input (`.FLUSH`) for a clean raw-mode slate. Restore
    // uses `.NOW` so it applies immediately: `.FLUSH`/`.DRAIN` block until the
    // terminal's output queue transmits, which a wedged or flow-controlled
    // terminal never does, and that would strand the terminal in raw mode.
    fn setRaw(self: *const PosixSetup) !void {
        try std.posix.tcsetattr(self.in_handle, .FLUSH, self.raw.*);
    }

    fn restore(self: *const PosixSetup) !void {
        try std.posix.tcsetattr(self.in_handle, .NOW, self.original.*);
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

/// Restore the original cooked state first — a blocking or failing escape write
/// must not strand raw mode — then reverse the escape modes. Used at shutdown and
/// to suspend for a mid-session login flow; pair with `enterRaw` to resume.
pub fn leaveRaw(self: *Tty) void {
    // `raw` is unused on the restore path.
    var control: PosixSetup = .{
        .in_handle = self.in_handle,
        .raw = &self.original,
        .original = &self.original,
    };
    cleanupWith(&self.raw_state, &self.out_stream.interface, &control, true);
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

/// Window size, or null when the terminal cannot report one. `TIOCGWINSZ` is an
/// instantaneous kernel query with nothing to block or cancel on, so it bypasses
/// `io` — also sidestepping a `std.Io.Threaded` device-control path that returns
/// spurious `ENOTTY` on a valid tty under ReleaseSafe on aarch64-macOS
/// (codeberg.org/ziglang/zig/issues/36218).
pub fn size(self: *Tty) ?Size {
    var window: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.posix.system.ioctl(self.out_handle, std.posix.T.IOCGWINSZ, @intFromPtr(&window));
    if (std.posix.errno(rc) != .SUCCESS or window.col == 0) return null;
    return .{ .columns = window.col, .rows = window.row };
}

fn enterWith(state: *RawState, output: *std.Io.Writer, control: anytype) !void {
    try control.setRaw();
    state.raw_owned = true;
    errdefer cleanupWith(state, output, control, false);

    state.paste_reset_pending = true;
    try output.writeAll(escape.paste_set);
    state.keyboard_reset_pending = true;
    try output.writeAll(escape.keyboard_set);
    state.cursor_show_pending = true;
    try output.writeAll(escape.cursor_hide);
    try output.flush();
    state.setup_complete = true;
}

fn cleanupWith(
    state: *RawState,
    output: *std.Io.Writer,
    control: anytype,
    write_newline: bool,
) void {
    // Restore the OS terminal mode before any presentation output, so a write or
    // flush that blocks on a wedged or flow-controlled terminal cannot postpone it.
    // On restore failure keep raw ownership and every pending reset flag so a later
    // cleanup retries the restore, then writes the resets, exactly once.
    if (state.raw_owned) {
        control.restore() catch return;
        state.raw_owned = false;
    }
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
}

const TestControl = struct {
    raw: bool = false,
    set_count: usize = 0,
    restore_count: usize = 0,
    restore_fails: bool = false,
    log: ?*TestWriter = null,

    fn setRaw(self: *TestControl) !void {
        self.set_count += 1;
        self.raw = true;
    }

    fn restore(self: *TestControl) !void {
        self.restore_count += 1;
        if (self.log) |recorder| recorder.record(.restore);
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
        restore,
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
    cleanupWith(&state, &output.interface, &control, false);

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

test "read maps a timeout to null and a closed input to end of stream" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var tty: Tty = undefined;
    tty.io = threaded.io();
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer _ = std.posix.system.close(fds[0]);
    tty.in_handle = fds[0];
    var buffer: [8]u8 = undefined;
    const timeout: std.Io.Timeout =
        .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } };
    try std.testing.expectEqual(@as(?usize, null), try tty.read(&buffer, timeout));
    _ = std.posix.system.write(fds[1], "x", 1);
    try std.testing.expectEqual(@as(?usize, 1), try tty.read(&buffer, .none));
    _ = std.posix.system.close(fds[1]);
    try std.testing.expectError(error.EndOfStream, tty.read(&buffer, .none));
}

test "size reports absence on a handle that is not a terminal" {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (fds) |handle| {
        _ = std.posix.system.close(handle);
    };
    var tty: Tty = undefined;
    tty.out_handle = fds[1];
    try std.testing.expectEqual(@as(?Size, null), tty.size());
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
    cleanupWith(&state, &output.interface, &control, false);
    cleanupWith(&state, &output.interface, &control, false);
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

    cleanupWith(&state, &output.interface, &control, true);
    cleanupWith(&state, &output.interface, &control, true);
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

test "shutdown restores cooked mode before the potentially blocking presentation output" {
    var output: TestWriter = .{};
    var control: TestControl = .{ .log = &output };
    var state: RawState = .{};

    try enterWith(&state, &output.interface, &control);
    cleanupWith(&state, &output.interface, &control, true);

    try std.testing.expect(!control.raw);
    try std.testing.expectEqual(RawState{}, state);
    try std.testing.expectEqualSlices(
        TestWriter.Operation,
        &.{
            .paste_set,
            .keyboard_set,
            .cursor_hide,
            .flush,
            .restore,
            .cursor_show,
            .keyboard_reset,
            .paste_reset,
            .newline,
            .flush,
        },
        output.operations[0..output.operations_len],
    );
}

test "shutdown restores cooked mode even when presentation output fails" {
    var output: TestWriter = .{ .drain_fail_at = 4, .flush_fail_at = 2 };
    var control: TestControl = .{ .log = &output };
    var state: RawState = .{};

    try enterWith(&state, &output.interface, &control);
    cleanupWith(&state, &output.interface, &control, true);

    try std.testing.expect(!control.raw);
    try std.testing.expectEqual(@as(usize, 1), control.restore_count);
    try std.testing.expectEqual(RawState{}, state);
    try std.testing.expectEqual(TestWriter.Operation.restore, output.operations[4]);
}
