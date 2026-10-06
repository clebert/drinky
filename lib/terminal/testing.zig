const std = @import("std");

const Device = @import("Device.zig");
const escape = @import("escape.zig");
const grapheme = @import("grapheme.zig");
const View = @import("View.zig");
const width = @import("width.zig");

const wait_ms_max = 5_000;
const wait_polls_max = 1024;

pub const FakeDevice = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    changes: std.atomic.Value(u32),
    window: View.Size,
    alternate: bool,
    conversation: Emulator,
    page: Emulator,
    frame_count: usize,
    keys_count: usize,
    keys_taken: usize,
    keys_delivered: usize,
    resize_count: usize,
    resize_taken: usize,
    resize_delivered: usize,
    stopped: bool,
    pending: std.ArrayList(u8),
    output: std.Io.Writer,
    keys: std.Io.Queue(u8),
    keys_buffer: [4096]u8,
    resizes: std.Io.Queue(u8),
    resizes_buffer: [64]u8,

    pub const Snapshot = struct {
        rows: []const []const u8,
        alternate: bool,
    };

    const WaitError = error{ TestDeviceStopped, TestDeviceTimeout };

    const vtable: Device.VTable = .{
        .read = read,
        .waitResize = waitResize,
        .size = size,
        .setAlternateScreen = setAlternateScreen,
        .writer = writer,
    };

    pub fn init(self: *FakeDevice, gpa: std.mem.Allocator, io: std.Io, window: View.Size) !void {
        var conversation: Emulator = try .init(gpa, window.columns);
        errdefer conversation.deinit();
        conversation.resize(window.rows);
        var page: Emulator = try .init(gpa, window.columns);
        errdefer page.deinit();
        page.resize(window.rows);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .mutex = .init,
            .changes = .init(0),
            .window = window,
            .alternate = false,
            .conversation = conversation,
            .page = page,
            .frame_count = 0,
            .keys_count = 0,
            .keys_taken = 0,
            .keys_delivered = 0,
            .resize_count = 0,
            .resize_taken = 0,
            .resize_delivered = 0,
            .stopped = false,
            .pending = .empty,
            .output = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = &.{} },
            .keys = undefined,
            .keys_buffer = undefined,
            .resizes = undefined,
            .resizes_buffer = undefined,
        };
        self.keys = .init(&self.keys_buffer);
        self.resizes = .init(&self.resizes_buffer);
    }

    pub fn deinit(self: *FakeDevice) void {
        self.pending.deinit(self.gpa);
        self.page.deinit();
        self.conversation.deinit();
    }

    pub fn device(self: *FakeDevice) Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn press(
        self: *FakeDevice,
        bytes: []const u8,
    ) (std.Io.QueueClosedError || WaitError)!void {
        self.mutex.lockUncancelable(self.io);
        self.keys_count += bytes.len;
        const target = self.keys_count;
        self.mutex.unlock(self.io);
        _ = try self.keys.putUncancelable(self.io, bytes, bytes.len);
        try self.waitUntil(target, keysDelivered);
    }

    pub fn close(self: *FakeDevice) void {
        self.keys.close(self.io);
    }

    pub fn resize(self: *FakeDevice, window: View.Size) WaitError!void {
        self.mutex.lockUncancelable(self.io);
        self.window = window;
        for ([_]*Emulator{ &self.conversation, &self.page }) |emulator| {
            emulator.columns = window.columns;
            emulator.resize(window.rows);
        }
        self.resize_count += 1;
        const target = self.resize_count;
        self.mutex.unlock(self.io);
        _ = self.resizes.putUncancelable(self.io, &.{0}, 1) catch unreachable;
        try self.waitUntil(target, resizeDelivered);
    }

    pub fn stop(self: *FakeDevice) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopped = true;
        self.notify();
    }

    pub fn waitStop(self: *FakeDevice) WaitError!void {
        try self.waitUntil(0, halted);
    }

    pub fn frameCount(self: *FakeDevice) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.frame_count;
    }

    pub fn waitFrame(self: *FakeDevice, seen: usize) WaitError!void {
        try self.waitUntil(seen, painted);
    }

    pub fn snapshot(self: *FakeDevice, arena: std.mem.Allocator) error{OutOfMemory}!Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const document = self.screen().document.items;
        const rows = try arena.alloc([]const u8, document.len);
        for (rows, document) |*row, source| row.* = try arena.dupe(u8, source.items);
        return .{ .rows = rows, .alternate = self.alternate };
    }

    fn screen(self: *FakeDevice) *Emulator {
        return if (self.alternate) &self.page else &self.conversation;
    }

    fn notify(self: *FakeDevice) void {
        _ = self.changes.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.changes.raw, std.math.maxInt(u32));
    }

    fn painted(self: *const FakeDevice, seen: usize) bool {
        return self.frame_count != seen;
    }

    fn halted(self: *const FakeDevice, _: usize) bool {
        return self.stopped;
    }

    fn keysDelivered(self: *const FakeDevice, target: usize) bool {
        return self.keys_delivered >= target;
    }

    fn resizeDelivered(self: *const FakeDevice, target: usize) bool {
        return self.resize_delivered >= target;
    }

    fn waitUntil(
        self: *FakeDevice,
        target: usize,
        reached: *const fn (device: *const FakeDevice, target: usize) bool,
    ) WaitError!void {
        const deadline = std.Io.Timestamp.now(std.testing.io, .awake)
            .addDuration(.fromMilliseconds(wait_ms_max));
        for (0..wait_polls_max) |_| {
            const observed = self.changes.load(.acquire);
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (reached(self, target)) return;
                if (self.stopped) return error.TestDeviceStopped;
            }
            const remaining = std.Io.Timestamp.now(std.testing.io, .awake).durationTo(deadline);
            if (remaining.nanoseconds <= 0) break;
            const timeout: std.Io.Timeout = .{ .duration = .{ .raw = remaining, .clock = .awake } };
            self.io.futexWaitTimeout(u32, &self.changes.raw, observed, timeout) catch |err|
                switch (err) {
                    error.Canceled => unreachable,
                };
        }
        return error.TestDeviceTimeout;
    }

    fn read(ptr: *anyopaque, buffer: []u8) std.Io.File.ReadStreamingError!usize {
        const self: *FakeDevice = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        self.keys_delivered = self.keys_taken;
        self.notify();
        self.mutex.unlock(self.io);
        const count = self.keys.get(self.io, buffer, 1) catch |err| {
            self.stop();
            return switch (err) {
                error.Canceled => error.Canceled,
                error.Closed => error.EndOfStream,
            };
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.keys_taken += count;
        return count;
    }

    fn waitResize(ptr: *anyopaque) std.Io.File.ReadStreamingError!void {
        const self: *FakeDevice = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        self.resize_delivered = self.resize_taken;
        self.notify();
        self.mutex.unlock(self.io);
        var buffer: [64]u8 = undefined;
        const count = self.resizes.get(self.io, &buffer, 1) catch |err| switch (err) {
            error.Canceled => {
                self.stop();
                return error.Canceled;
            },
            error.Closed => unreachable,
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.resize_taken += count;
    }

    fn size(ptr: *anyopaque) ?View.Size {
        const self: *FakeDevice = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.window;
    }

    fn setAlternateScreen(ptr: *anyopaque, enabled: bool) std.Io.Writer.Error!void {
        const self: *FakeDevice = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (enabled and !self.alternate) {
            var fresh = Emulator.init(self.gpa, self.window.columns) catch return error.WriteFailed;
            fresh.resize(self.window.rows);
            self.page.deinit();
            self.page = fresh;
        }
        self.alternate = enabled;
    }

    fn writer(ptr: *anyopaque) *std.Io.Writer {
        const self: *FakeDevice = @ptrCast(@alignCast(ptr));
        return &self.output;
    }

    fn drain(
        output: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *FakeDevice = @alignCast(@fieldParentPtr("output", output));
        std.debug.assert(output.end == 0);
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.pending.appendSlice(self.gpa, bytes) catch return error.WriteFailed;
            count += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.pending.appendSlice(self.gpa, last) catch return error.WriteFailed;
        }
        return count + last.len * splat;
    }

    fn flush(output: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *FakeDevice = @alignCast(@fieldParentPtr("output", output));
        defer self.pending.clearRetainingCapacity();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.screen().feed(self.pending.items) catch return error.WriteFailed;
        self.frame_count += std.mem.count(u8, self.pending.items, escape.sync_reset);
        self.notify();
    }
};

pub const Emulator = struct {
    gpa: std.mem.Allocator,
    columns: usize,
    rows: usize,
    document: std.ArrayList(std.ArrayList(u8)),
    screen_top: usize,
    cursor_row: usize,
    cursor_column: usize,
    cursor_visible: bool,

    pub fn init(gpa: std.mem.Allocator, columns: usize) !Emulator {
        var document: std.ArrayList(std.ArrayList(u8)) = .empty;
        try document.append(gpa, .empty);
        return .{
            .gpa = gpa,
            .columns = columns,
            .rows = 0,
            .document = document,
            .screen_top = 0,
            .cursor_row = 0,
            .cursor_column = 0,
            .cursor_visible = false,
        };
    }

    pub fn deinit(self: *Emulator) void {
        for (self.document.items) |*row| row.deinit(self.gpa);
        self.document.deinit(self.gpa);
    }

    pub fn resize(self: *Emulator, rows: usize) void {
        const height = @max(rows, 1);
        if (self.rows > 0 and height < @max(self.rows, 1)) {
            const cursor_top = self.cursor_row -| (height - 1);
            self.screen_top = @max(self.screen_top, cursor_top);
            while (self.document.items.len > self.screen_top + height) {
                var row = self.document.pop().?;
                row.deinit(self.gpa);
            }
        }
        self.rows = rows;
    }

    pub fn feed(self: *Emulator, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            if (byte == 0x1b) {
                index += try self.control(bytes[index..]);
                continue;
            }
            if (byte == '\r') {
                self.cursor_column = 0;
                index += 1;
                continue;
            }
            if (byte == '\n') {
                try self.lineFeed();
                index += 1;
                continue;
            }
            const step = grapheme.stepAt(bytes[index..]);
            try self.put(bytes[index .. index + step.bytes], step.columns);
            index += step.bytes;
        }
    }

    fn control(self: *Emulator, sequence: []const u8) !usize {
        if (sequence.len < 2) return sequence.len;
        if (sequence[1] == '[') return self.csi(sequence);
        if (sequence[1] == ']') return osc(sequence);
        return 2;
    }

    fn osc(sequence: []const u8) usize {
        var index: usize = 2;
        while (index < sequence.len) : (index += 1) {
            if (sequence[index] == 0x07) return index + 1;
            if (sequence[index] != 0x1b) continue;
            if (index + 1 < sequence.len and sequence[index + 1] == '\\') return index + 2;
            return index;
        }
        return sequence.len;
    }

    fn csi(self: *Emulator, sequence: []const u8) !usize {
        var index: usize = 2;
        while (index < sequence.len and (sequence[index] < 0x40 or sequence[index] > 0x7e)) {
            index += 1;
        }
        if (index >= sequence.len) return sequence.len;
        const parameters = sequence[2..index];
        switch (sequence[index]) {
            'A' => {
                std.debug.assert(self.cursor_row >= self.screen_top);
                const count = @max(csiValue(parameters, 1), 1);
                self.cursor_row -= @min(count, self.cursor_row - self.screen_top);
            },
            'B' => {
                const count = @max(csiValue(parameters, 1), 1);
                const screen_bottom = self.screen_top + @max(self.rows, 1) - 1;
                self.cursor_row = @min(self.cursor_row + count, screen_bottom);
                try self.ensureRow(self.cursor_row);
            },
            'C' => {
                const count = @max(csiValue(parameters, 1), 1);
                self.cursor_column = @min(self.cursor_column + count, self.columns - 1);
            },
            'H' => {
                self.cursor_row = self.screen_top;
                self.cursor_column = 0;
                self.trimBlankTail();
            },
            'J' => switch (csiValue(parameters, 0)) {
                0 => self.clearBelow(),
                2 => self.clearScreen(),
                3 => self.clearScrollback(),
                else => {},
            },
            'h' => if (std.mem.eql(u8, parameters, "?25")) {
                self.cursor_visible = true;
            },
            'l' => if (std.mem.eql(u8, parameters, "?25")) {
                self.cursor_visible = false;
            },
            else => {},
        }
        return index + 1;
    }

    fn clearScreen(self: *Emulator) void {
        const screen_end = @min(
            self.document.items.len,
            self.screen_top + @max(self.rows, 1),
        );
        for (self.document.items[self.screen_top..screen_end]) |*row| {
            row.clearRetainingCapacity();
        }
    }

    fn clearScrollback(self: *Emulator) void {
        std.debug.assert(self.cursor_row >= self.screen_top);
        const dropped = self.screen_top;
        if (dropped == 0) return;
        for (self.document.items[0..dropped]) |*row| row.deinit(self.gpa);
        const kept = self.document.items.len - dropped;
        std.mem.copyForwards(
            std.ArrayList(u8),
            self.document.items[0..kept],
            self.document.items[dropped..],
        );
        self.document.shrinkRetainingCapacity(kept);
        self.cursor_row -= dropped;
        self.screen_top = 0;
    }

    fn trimBlankTail(self: *Emulator) void {
        while (self.document.items.len > self.cursor_row + 1 and
            self.document.items[self.document.items.len - 1].items.len == 0)
        {
            var row = self.document.pop().?;
            row.deinit(self.gpa);
        }
    }

    fn lineFeed(self: *Emulator) !void {
        if (self.rows > 0 and self.cursor_row + 1 >= self.screen_top + self.rows) {
            self.screen_top += 1;
        }
        self.cursor_row += 1;
        try self.ensureRow(self.cursor_row);
    }

    fn clearBelow(self: *Emulator) void {
        while (self.document.items.len > self.cursor_row + 1) {
            var row = self.document.pop().?;
            row.deinit(self.gpa);
        }
        self.document.items[self.cursor_row].clearRetainingCapacity();
    }

    fn ensureRow(self: *Emulator, row: usize) !void {
        while (self.document.items.len <= row) try self.document.append(self.gpa, .empty);
    }

    fn put(self: *Emulator, bytes: []const u8, columns: usize) !void {
        if (self.cursor_column + columns > self.columns and self.cursor_column > 0) {
            try self.lineFeed();
            self.cursor_column = 0;
        }
        try self.ensureRow(self.cursor_row);
        try self.document.items[self.cursor_row].appendSlice(self.gpa, bytes);
        self.cursor_column += columns;
    }

    fn csiValue(parameters: []const u8, default: usize) usize {
        return std.fmt.parseInt(usize, parameters, 10) catch default;
    }

    pub fn expectVisible(self: *Emulator, frame: []const []const u8) !void {
        try std.testing.expect(self.document.items.len >= frame.len);
        const base = self.document.items.len - frame.len;
        for (frame, 0..) |row, index| {
            try std.testing.expectEqualStrings(row, self.document.items[base + index].items);
        }
    }

    pub fn expectCaret(
        self: *Emulator,
        expected: *const struct { frame_len: usize, row: usize, column: usize },
    ) !void {
        try std.testing.expect(self.cursor_visible);
        const row = self.document.items.len - expected.frame_len + expected.row;
        try std.testing.expectEqual(row, self.cursor_row);
        try std.testing.expectEqual(expected.column, self.cursor_column);
    }

    pub fn expectScreen(self: *Emulator, screen: []const []const u8) !void {
        for (screen, 0..) |row, index| {
            const at = self.screen_top + index;
            const actual = if (at < self.document.items.len) self.document.items[at].items else "";
            try std.testing.expectEqualStrings(row, actual);
        }
    }
};

pub fn plainText(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var index: usize = 0;
    while (index < bytes.len) {
        if (std.mem.startsWith(u8, bytes[index..], escape.link_set)) {
            const rest = bytes[index + escape.link_set.len ..];
            const end = std.mem.indexOf(u8, rest, escape.string_end) orelse rest.len;
            index = bytes.len - rest.len + end + escape.string_end.len;
            continue;
        }
        if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '[') {
            index += 2;
            while (index < bytes.len and (bytes[index] < 0x40 or bytes[index] > 0x7e)) index += 1;
            if (index < bytes.len) index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, bytes[index..], width.grapheme_boundary)) {
            index += width.grapheme_boundary.len;
            continue;
        }
        try out.append(gpa, bytes[index]);
        index += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "ED 2 preserves scrollback and ED 3 removes it" {
    const gpa = std.testing.allocator;
    var emulator = try Emulator.init(gpa, 20);
    defer emulator.deinit();
    emulator.resize(2);

    try emulator.feed("old\r\none\r\ntwo");
    try std.testing.expectEqual(@as(usize, 1), emulator.screen_top);
    try std.testing.expectEqualStrings("old", emulator.document.items[0].items);

    try emulator.feed("\x1b[2J");
    try std.testing.expectEqual(@as(usize, 1), emulator.screen_top);
    try std.testing.expectEqual(@as(usize, 2), emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), emulator.cursor_column);
    try std.testing.expectEqualStrings("old", emulator.document.items[0].items);
    try emulator.expectScreen(&.{ "", "" });

    try emulator.feed("\x1b[Hone\r\ntwo");
    try std.testing.expectEqualStrings("old", emulator.document.items[0].items);
    try emulator.expectScreen(&.{ "one", "two" });

    try emulator.feed("\x1b[3J");
    try std.testing.expectEqual(@as(usize, 0), emulator.screen_top);
    try std.testing.expectEqual(@as(usize, 1), emulator.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), emulator.document.items.len);
    try emulator.expectScreen(&.{ "one", "two" });
}

test "an OSC string ends at ST, at BEL, or on the escape that aborts it" {
    const gpa = std.testing.allocator;
    var emulator = try Emulator.init(gpa, 20);
    defer emulator.deinit();
    emulator.resize(1);

    try emulator.feed("a\x1b]8;;https://x.y\x1b\\b\x1b]0;title\x07c");
    try emulator.expectVisible(&.{"abc"});

    try emulator.feed("\x1b]8;;https://x.y\x1b[2Jd");
    try emulator.expectVisible(&.{"d"});

    try emulator.feed("\x1b]8;;unterminated");
    try emulator.expectVisible(&.{"d"});
}

test "the plain text of painted bytes holds the rows alone" {
    const gpa = std.testing.allocator;
    const bytes = escape.sync_set ++ "\x1b[1mbold\x1b[0m\r\n" ++
        escape.link_set ++ "https://example.com" ++ escape.string_end ++ "link" ++
        escape.link_reset ++ "\u{200B}!" ++ escape.sync_reset;
    const plain = try plainText(gpa, bytes);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("bold\r\nlink!", plain);
}
