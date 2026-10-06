const std = @import("std");

const Device = @import("Device.zig");
const escape = @import("escape.zig");
const Resize = @import("Resize.zig");
const View = @import("View.zig");

const Tty = @This();

var active: std.atomic.Value(?*Tty) = .init(null);

io: std.Io,
in_handle: std.posix.fd_t,
out_handle: std.posix.fd_t,
original: std.posix.termios,
raw_state: RawState,
resize: Resize,
out_buffer: [16384]u8,
out_stream: std.Io.File.Writer,

const RawState = struct {
    raw_owned: bool = false,
    resets_pending: std.EnumSet(Mode) = .initEmpty(),
    setup_complete: bool = false,

    fn set(self: *RawState, output: *std.Io.Writer, mode: Mode) std.Io.Writer.Error!void {
        self.resets_pending.insert(mode);
        try output.writeAll(mode.setSequence());
    }
};

const Mode = enum {
    paste,
    keyboard,
    grapheme,
    cursor,
    screen_alternate,
    scroll_alternate,
    keyboard_alternate,

    fn setSequence(self: Mode) []const u8 {
        return switch (self) {
            .paste => escape.paste_set,
            .keyboard, .keyboard_alternate => escape.keyboard_set,
            .grapheme => escape.grapheme_set,
            .cursor => escape.cursor_hide,
            .screen_alternate => escape.screen_alternate_set,
            .scroll_alternate => escape.scroll_alternate_set,
        };
    }

    fn resetSequence(self: Mode) []const u8 {
        return switch (self) {
            .paste => escape.paste_reset,
            .keyboard, .keyboard_alternate => escape.keyboard_reset,
            .grapheme => escape.grapheme_reset,
            .cursor => escape.cursor_show,
            .screen_alternate => escape.screen_alternate_reset,
            .scroll_alternate => escape.scroll_alternate_reset,
        };
    }
};

const Termios = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        setRaw: *const fn (ptr: *anyopaque) Error!void,
        restore: *const fn (ptr: *anyopaque) Error!void,
    };

    const Error = std.posix.TermiosSetError;

    fn setRaw(self: Termios) Error!void {
        return self.vtable.setRaw(self.ptr);
    }

    fn restore(self: Termios) Error!void {
        return self.vtable.restore(self.ptr);
    }
};

const PosixSetup = struct {
    in_handle: std.posix.fd_t,
    original: *const std.posix.termios,

    const vtable: Termios.VTable = .{ .setRaw = setRaw, .restore = restoreOriginal };

    fn termios(self: *PosixSetup) Termios {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setRaw(ptr: *anyopaque) Termios.Error!void {
        const self: *PosixSetup = @ptrCast(@alignCast(ptr));
        var raw = self.original.*;
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
    }

    fn restoreOriginal(ptr: *anyopaque) Termios.Error!void {
        const self: *PosixSetup = @ptrCast(@alignCast(ptr));
        try std.posix.tcsetattr(self.in_handle, .NOW, self.original.*);
    }
};

const RestoreSetup = struct {
    in_handle: std.posix.fd_t,
    original: *const std.posix.termios,

    const vtable: Termios.VTable = .{ .setRaw = setRaw, .restore = restoreOriginal };

    fn termios(self: *RestoreSetup) Termios {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setRaw(_: *anyopaque) Termios.Error!void {
        unreachable;
    }

    fn restoreOriginal(ptr: *anyopaque) Termios.Error!void {
        const self: *RestoreSetup = @ptrCast(@alignCast(ptr));
        std.posix.tcsetattr(self.in_handle, .NOW, self.original.*) catch {};
    }
};

const device_vtable: Device.VTable = .{
    .read = read,
    .waitResize = waitResize,
    .size = size,
    .setAlternateScreen = setAlternateScreen,
    .writer = writer,
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
    try self.resize.init();
    errdefer self.resize.deinit();
    var setup: PosixSetup = .{ .in_handle = self.in_handle, .original = &self.original };
    try enterWith(&self.raw_state, &self.out_stream.interface, setup.termios());
    active.store(self, .release);
}

pub fn deinit(self: *Tty) void {
    active.store(null, .release);
    var setup: PosixSetup = .{ .in_handle = self.in_handle, .original = &self.original };
    cleanupWith(&self.raw_state, &self.out_stream.interface, setup.termios());
    self.resize.deinit();
}

pub fn device(self: *Tty) Device {
    return .{ .ptr = self, .vtable = &device_vtable };
}

pub fn restore() void {
    const tty = active.swap(null, .acq_rel) orelse return;
    var buffer: [256]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    var setup: RestoreSetup = .{ .in_handle = tty.in_handle, .original = &tty.original };
    cleanupWith(&tty.raw_state, &output, setup.termios());
    writeHandle(tty.out_handle, output.buffered());
}

fn read(ptr: *anyopaque, buffer: []u8) std.Io.File.ReadStreamingError!usize {
    const self: *Tty = @ptrCast(@alignCast(ptr));
    const file: std.Io.File = .{ .handle = self.in_handle, .flags = .{ .nonblocking = false } };
    return file.readStreaming(self.io, &.{buffer});
}

fn waitResize(ptr: *anyopaque) std.Io.File.ReadStreamingError!void {
    const self: *Tty = @ptrCast(@alignCast(ptr));
    return self.resize.wait(self.io);
}

fn size(ptr: *anyopaque) ?View.Size {
    const self: *Tty = @ptrCast(@alignCast(ptr));
    var window: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result =
        std.posix.system.ioctl(self.out_handle, std.posix.T.IOCGWINSZ, @intFromPtr(&window));
    if (std.posix.errno(result) != .SUCCESS or window.col == 0) return null;
    return .{ .columns = window.col, .rows = window.row };
}

fn setAlternateScreen(ptr: *anyopaque, enabled: bool) std.Io.Writer.Error!void {
    const self: *Tty = @ptrCast(@alignCast(ptr));
    try setAlternateScreenWith(&self.raw_state, &self.out_stream.interface, enabled);
}

fn writer(ptr: *anyopaque) *std.Io.Writer {
    const self: *Tty = @ptrCast(@alignCast(ptr));
    return &self.out_stream.interface;
}

fn enterWith(state: *RawState, output: *std.Io.Writer, termios: Termios) !void {
    try termios.setRaw();
    state.raw_owned = true;
    errdefer cleanupWith(state, output, termios);

    for ([_]Mode{ .paste, .keyboard, .grapheme, .cursor }) |mode| try state.set(output, mode);
    try output.flush();
    state.setup_complete = true;
}

fn setAlternateScreenWith(state: *RawState, output: *std.Io.Writer, enabled: bool) !void {
    if (enabled) {
        if (state.resets_pending.contains(.screen_alternate)) return;
        for ([_]Mode{ .screen_alternate, .scroll_alternate, .keyboard_alternate }) |mode| {
            try state.set(output, mode);
        }
        try output.writeAll(escape.cursor_hide);
        try output.flush();
        return;
    }
    if (!state.resets_pending.contains(.screen_alternate)) return;
    for ([_]Mode{ .keyboard_alternate, .scroll_alternate }) |mode| {
        if (!state.resets_pending.contains(mode)) continue;
        try output.writeAll(mode.resetSequence());
        state.resets_pending.remove(mode);
    }
    try output.writeAll(Mode.screen_alternate.resetSequence());
    try output.writeAll(escape.cursor_show);
    try output.flush();
    state.resets_pending.remove(.screen_alternate);
}

fn cleanupWith(state: *RawState, output: *std.Io.Writer, termios: Termios) void {
    if (state.raw_owned) {
        termios.restore() catch return;
        state.raw_owned = false;
    }
    const flush_needed = state.setup_complete or state.resets_pending.count() > 0;
    var modes = std.mem.reverseIterator(std.enums.values(Mode));
    while (modes.next()) |mode| {
        if (!state.resets_pending.contains(mode)) continue;
        state.resets_pending.remove(mode);
        output.writeAll(mode.resetSequence()) catch {};
    }
    if (state.setup_complete) {
        state.setup_complete = false;
        output.writeAll("\r\n") catch {};
    }
    if (flush_needed) output.flush() catch {};
}

fn writeHandle(handle: std.posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const result = std.posix.system.write(handle, rest.ptr, rest.len);
        if (std.posix.errno(result) != .SUCCESS or result == 0) return;
        rest = rest[@intCast(result)..];
    }
}

test "read returns the waiting bytes, and a closed input ends the stream" {
    var tty: Tty = undefined;
    tty.io = std.testing.io;
    const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer _ = std.posix.system.close(handles[0]);
    tty.in_handle = handles[0];
    var buffer: [8]u8 = undefined;
    _ = std.posix.system.write(handles[1], "xy", 2);
    try std.testing.expectEqual(@as(usize, 2), try tty.device().read(&buffer));
    try std.testing.expectEqualStrings("xy", buffer[0..2]);
    _ = std.posix.system.close(handles[1]);
    try std.testing.expectError(error.EndOfStream, tty.device().read(&buffer));
}

const TestControl = struct {
    raw: bool = false,
    set_count: usize = 0,
    restore_count: usize = 0,
    restore_fails: bool = false,
    log: ?*TestWriter = null,

    const vtable: Termios.VTable = .{ .setRaw = setRaw, .restore = restoreOriginal };

    fn termios(self: *TestControl) Termios {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setRaw(ptr: *anyopaque) Termios.Error!void {
        const self: *TestControl = @ptrCast(@alignCast(ptr));
        self.set_count += 1;
        self.raw = true;
    }

    fn restoreOriginal(ptr: *anyopaque) Termios.Error!void {
        const self: *TestControl = @ptrCast(@alignCast(ptr));
        self.restore_count += 1;
        if (self.log) |recorder| recorder.record(.restore);
        if (self.restore_fails) return error.NotATerminal;
        self.raw = false;
    }
};

const TestWriter = struct {
    interface: std.Io.Writer = .{
        .vtable = &.{ .drain = drain, .flush = flush },
        .buffer = &.{},
    },
    operations: [32]Operation = undefined,
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
        grapheme_set,
        grapheme_reset,
        cursor_hide,
        cursor_show,
        screen_alternate_set,
        screen_alternate_reset,
        scroll_alternate_set,
        scroll_alternate_reset,
        keyboard_reset,
        paste_reset,
        newline,
        flush,
        restore,
    };

    fn record(self: *TestWriter, item: Operation) void {
        std.debug.assert(self.operations_len < self.operations.len);
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
        if (std.mem.eql(u8, bytes, escape.grapheme_set)) return .grapheme_set;
        if (std.mem.eql(u8, bytes, escape.grapheme_reset)) return .grapheme_reset;
        if (std.mem.eql(u8, bytes, escape.cursor_hide)) return .cursor_hide;
        if (std.mem.eql(u8, bytes, escape.cursor_show)) return .cursor_show;
        if (std.mem.eql(u8, bytes, escape.screen_alternate_set)) return .screen_alternate_set;
        if (std.mem.eql(u8, bytes, escape.screen_alternate_reset)) return .screen_alternate_reset;
        if (std.mem.eql(u8, bytes, escape.scroll_alternate_set)) return .scroll_alternate_set;
        if (std.mem.eql(u8, bytes, escape.scroll_alternate_reset)) return .scroll_alternate_reset;
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
        enterWith(&state, &output.interface, control.termios()),
    );
    cleanupWith(&state, &output.interface, control.termios());

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

test "a restore reverses each pending mode once, and a restore after deinit writes nothing" {
    const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (handles) |handle| {
        _ = std.posix.system.close(handle);
    };
    var tty: Tty = undefined;
    tty.in_handle = handles[0];
    tty.out_handle = handles[1];
    tty.original = std.mem.zeroes(std.posix.termios);
    try tty.resize.init();
    tty.raw_state = .{
        .raw_owned = true,
        .resets_pending = .initMany(&.{ .paste, .keyboard, .grapheme, .cursor, .screen_alternate }),
        .setup_complete = true,
    };
    active.store(&tty, .release);
    restore();
    restore();
    _ = std.posix.system.write(handles[1], "x", 1);

    try std.testing.expectEqual(RawState{}, tty.raw_state);
    var buffer: [256]u8 = undefined;
    const count = std.posix.system.read(handles[0], &buffer, buffer.len);
    try std.testing.expectEqualStrings(
        escape.screen_alternate_reset ++ escape.cursor_show ++ escape.grapheme_reset ++
            escape.keyboard_reset ++ escape.paste_reset ++ "\r\nx",
        buffer[0..@intCast(count)],
    );

    tty.raw_state = .{ .raw_owned = true, .resets_pending = .initOne(.cursor) };
    active.store(&tty, .release);
    tty.deinit();
    restore();
    _ = std.posix.system.write(handles[1], "y", 1);
    const rest = std.posix.system.read(handles[0], &buffer, buffer.len);
    try std.testing.expectEqualStrings("y", buffer[0..@intCast(rest)]);
}

test "size reports absence on a handle that is not a terminal" {
    const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (handles) |handle| {
        _ = std.posix.system.close(handle);
    };
    var tty: Tty = undefined;
    tty.out_handle = handles[1];
    try std.testing.expectEqual(@as(?View.Size, null), tty.device().size());
}

test "each alternate screen transition pairs its own keyboard and scroll modes" {
    {
        var output: TestWriter = .{};
        var state: RawState = .{};
        for ([_]bool{ true, true, false, false }) |enabled| {
            try setAlternateScreenWith(&state, &output.interface, enabled);
        }
        try std.testing.expectEqual(RawState{}, state);
        try std.testing.expectEqualSlices(
            TestWriter.Operation,
            &.{
                .screen_alternate_set,
                .scroll_alternate_set,
                .keyboard_set,
                .cursor_hide,
                .flush,
                .keyboard_reset,
                .scroll_alternate_reset,
                .screen_alternate_reset,
                .cursor_show,
                .flush,
            },
            output.operations[0..output.operations_len],
        );
    }
    {
        var output: TestWriter = .{};
        var control: TestControl = .{};
        var state: RawState = .{ .resets_pending = .initMany(&.{ .keyboard, .cursor }) };
        try setAlternateScreenWith(&state, &output.interface, true);
        cleanupWith(&state, &output.interface, control.termios());
        cleanupWith(&state, &output.interface, control.termios());
        try std.testing.expectEqual(RawState{}, state);
        try std.testing.expectEqualSlices(
            TestWriter.Operation,
            &.{
                .screen_alternate_set,
                .scroll_alternate_set,
                .keyboard_set,
                .cursor_hide,
                .flush,
                .keyboard_reset,
                .scroll_alternate_reset,
                .screen_alternate_reset,
                .cursor_show,
                .keyboard_reset,
                .flush,
            },
            output.operations[0..output.operations_len],
        );
    }
    {
        var output: TestWriter = .{ .drain_fail_at = 2 };
        var control: TestControl = .{};
        var state: RawState = .{ .resets_pending = .initMany(&.{ .keyboard, .cursor }) };
        try std.testing.expectError(
            error.WriteFailed,
            setAlternateScreenWith(&state, &output.interface, true),
        );
        cleanupWith(&state, &output.interface, control.termios());
        cleanupWith(&state, &output.interface, control.termios());
        try std.testing.expectEqual(RawState{}, state);
        try std.testing.expectEqualSlices(
            TestWriter.Operation,
            &.{
                .screen_alternate_set,
                .scroll_alternate_set,
                .scroll_alternate_reset,
                .screen_alternate_reset,
                .cursor_show,
                .keyboard_reset,
                .flush,
            },
            output.operations[0..output.operations_len],
        );
    }
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
            .grapheme_set,
            .grapheme_reset,
            .keyboard_reset,
            .paste_reset,
            .flush,
        },
        &.{ .drain_at = 3 },
    );
    try expectSetupFailure(
        &.{
            .paste_set,
            .keyboard_set,
            .grapheme_set,
            .cursor_hide,
            .cursor_show,
            .grapheme_reset,
            .keyboard_reset,
            .paste_reset,
            .flush,
        },
        &.{ .drain_at = 4, .drain_again_at = 5, .flush_at = 1 },
    );
    try expectSetupFailure(
        &.{
            .paste_set,
            .keyboard_set,
            .grapheme_set,
            .cursor_hide,
            .flush,
            .cursor_show,
            .grapheme_reset,
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
        enterWith(&state, &output.interface, control.termios()),
    );
    try std.testing.expect(control.raw);
    try std.testing.expect(state.raw_owned);
    try std.testing.expectEqual(@as(usize, 1), control.restore_count);

    control.restore_fails = false;
    cleanupWith(&state, &output.interface, control.termios());
    cleanupWith(&state, &output.interface, control.termios());
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

    try enterWith(&state, &output.interface, control.termios());

    try std.testing.expect(control.raw);
    try std.testing.expectEqual(@as(usize, 1), control.set_count);
    try std.testing.expectEqual(@as(usize, 0), control.restore_count);
    try std.testing.expectEqualSlices(
        TestWriter.Operation,
        &.{ .paste_set, .keyboard_set, .grapheme_set, .cursor_hide, .flush },
        output.operations[0..output.operations_len],
    );

    cleanupWith(&state, &output.interface, control.termios());
    cleanupWith(&state, &output.interface, control.termios());
    try std.testing.expect(!control.raw);
    try std.testing.expectEqual(@as(usize, 1), control.restore_count);
    try std.testing.expectEqual(RawState{}, state);
    try std.testing.expectEqualSlices(
        TestWriter.Operation,
        &.{
            .paste_set,
            .keyboard_set,
            .grapheme_set,
            .cursor_hide,
            .flush,
            .cursor_show,
            .grapheme_reset,
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

    try enterWith(&state, &output.interface, control.termios());
    cleanupWith(&state, &output.interface, control.termios());

    try std.testing.expect(!control.raw);
    try std.testing.expectEqual(RawState{}, state);
    try std.testing.expectEqualSlices(
        TestWriter.Operation,
        &.{
            .paste_set,
            .keyboard_set,
            .grapheme_set,
            .cursor_hide,
            .flush,
            .restore,
            .cursor_show,
            .grapheme_reset,
            .keyboard_reset,
            .paste_reset,
            .newline,
            .flush,
        },
        output.operations[0..output.operations_len],
    );
}

test "shutdown restores cooked mode even when presentation output fails" {
    var output: TestWriter = .{ .drain_fail_at = 5, .flush_fail_at = 2 };
    var control: TestControl = .{ .log = &output };
    var state: RawState = .{};

    try enterWith(&state, &output.interface, control.termios());
    cleanupWith(&state, &output.interface, control.termios());

    try std.testing.expect(!control.raw);
    try std.testing.expectEqual(@as(usize, 1), control.restore_count);
    try std.testing.expectEqual(RawState{}, state);
    const recorded = output.operations[0..output.operations_len];
    const restore_at = std.mem.indexOfScalar(TestWriter.Operation, recorded, .restore).?;
    const cursor_at = std.mem.indexOfScalar(TestWriter.Operation, recorded, .cursor_show).?;
    try std.testing.expect(restore_at < cursor_at);
}
