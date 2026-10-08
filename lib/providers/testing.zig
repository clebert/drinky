const std = @import("std");

const core = @import("core");

const Credential = @import("Credential.zig");
const Dialect = @import("Dialect.zig");
const Transport = @import("Transport.zig");

pub const tools = [_]core.Tool{
    .{ .name = "read", .description = "read a file", .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "the path" },
    } },
};

pub const empty_request: core.Provider.Request = .{
    .model = "model-a",
    .tokens_max = 8,
    .system = "s",
    .items = &.{},
    .tools = &.{},
    .effort = null,
    .cache_key = "",
};

pub const reply_stream =
    "data: {\"type\":\"response.output_text.delta\"," ++
    "\"item_id\":\"msg_1\",\"delta\":\"done\"}\n" ++
    "\n" ++
    "data: {\"type\":\"response.output_item.done\",\"item\":{" ++
    "\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"," ++
    "\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n" ++
    "\n" ++
    "data: {\"type\":\"response.completed\"," ++
    "\"response\":{\"status\":\"completed\",\"usage\":" ++
    "{\"input_tokens\":10,\"output_tokens\":2}}}\n" ++
    "\n";

pub const FakeTransport = struct {
    gpa: std.mem.Allocator,
    replies: []const Reply = &.{},
    index: usize = 0,
    reader: std.Io.Reader = undefined,
    requests: std.ArrayList([]u8) = .empty,
    open_count: usize = 0,

    pub const Reply = struct {
        status: std.http.Status = .ok,
        headers: []const std.http.Header = &.{},
        body: []const u8 = "",
        fail: ?Transport.Error = null,
        hold: ?*Hold = null,
        stall: ?*Stall = null,
    };

    pub const Hold = struct {
        io: std.Io,
        reached: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
    };

    pub const Stall = struct {
        io: std.Io,
        reached: std.Io.Event = .unset,
        canceled: bool = false,
    };

    const vtable: Transport.VTable = .{ .open = open, .close = close };

    pub fn deinit(self: *FakeTransport) void {
        for (self.requests.items) |request| self.gpa.free(request);
        self.requests.deinit(self.gpa);
    }

    pub fn transport(self: *FakeTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn open(ptr: *anyopaque, request: *const Transport.Request) Transport.Error!Transport.Reply {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        try self.requests.append(self.gpa, try renderRequest(self.gpa, request));
        const reply = if (self.index < self.replies.len) self.replies[self.index] else Reply{};
        self.index += 1;
        if (reply.hold) |hold| {
            hold.reached.set(hold.io);
            hold.released.waitUncancelable(hold.io);
        }
        if (reply.stall) |stall| {
            stall.reached.set(stall.io);
            var never: std.Io.Event = .unset;
            never.wait(stall.io) catch |err| {
                stall.canceled = true;
                return err;
            };
            unreachable;
        }
        if (reply.fail) |err| return err;
        self.open_count += 1;
        self.reader = .fixed(reply.body);
        return .{ .status = reply.status, .headers = reply.headers, .body = &self.reader };
    }

    fn close(ptr: *anyopaque) void {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        self.open_count -= 1;
    }
};

pub const FakeCredential = struct {
    tokens: []const ?[]const u8,
    index: usize = 0,
    token_fail: ?Credential.Error = null,
    renew_fail: ?Credential.Error = null,
    renewals: usize = 0,

    const vtable: Credential.VTable = .{ .token = token, .renew = renew };

    pub fn credential(self: *FakeCredential) Credential {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn token(ptr: *anyopaque, gpa: std.mem.Allocator) Credential.Error!?[]const u8 {
        const self: *FakeCredential = @ptrCast(@alignCast(ptr));
        if (self.token_fail) |err| return err;
        const value = self.tokens[self.index] orelse return null;
        return try gpa.dupe(u8, value);
    }

    fn renew(ptr: *anyopaque) Credential.Error!bool {
        const self: *FakeCredential = @ptrCast(@alignCast(ptr));
        self.renewals += 1;
        if (self.renew_fail) |err| return err;
        if (self.index + 1 >= self.tokens.len) return false;
        self.index += 1;
        return true;
    }
};

pub const TraceError = core.Provider.Error || std.Io.Writer.Error;

pub const Frames = struct {
    gpa: std.mem.Allocator,
    dialect: Dialect,
    arena: std.heap.ArenaAllocator,
    out: std.Io.Writer.Allocating,

    pub fn init(gpa: std.mem.Allocator, dialect: Dialect) Frames {
        dialect.reset();
        return .{ .gpa = gpa, .dialect = dialect, .arena = .init(gpa), .out = .init(gpa) };
    }

    pub fn deinit(self: *Frames) void {
        self.arena.deinit();
        self.out.deinit();
    }

    pub fn decode(self: *Frames, payload: []const u8) !Dialect.Decoded {
        _ = self.arena.reset(.retain_capacity);
        var events: Dialect.Events = .empty;
        const decoded = try self.dialect.decode(self.arena.allocator(), payload, &events);
        try self.record(events.items);
        return decoded;
    }

    pub fn finish(self: *Frames) !void {
        _ = self.arena.reset(.retain_capacity);
        var events: Dialect.Events = .empty;
        try self.dialect.finish(self.arena.allocator(), &events);
        try self.record(events.items);
    }

    pub fn feed(self: *Frames, payloads: []const []const u8) !void {
        for (payloads) |payload| _ = try self.decode(payload);
    }

    pub fn expect(self: *Frames, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, self.out.written());
        self.out.clearRetainingCapacity();
    }

    fn record(self: *Frames, events: []const core.Provider.Event) !void {
        for (events) |*event| {
            try writeEvent(&self.out.writer, event);
            try self.out.writer.writeByte('\n');
        }
    }
};

fn renderRequest(gpa: std.mem.Allocator, request: *const Transport.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print("{t} {s}\n", .{ request.method, request.url });
    if (request.method.requestHasBody()) {
        if (request.content_type) |value| try writer.print("content-type: {s}\n", .{value});
    }
    if (request.authorization) |value| try writer.print("authorization: {s}\n", .{value});
    if (request.user_agent) |value| try writer.print("user-agent: {s}\n", .{value});
    for (request.headers) |header| try writer.print("{s}: {s}\n", .{ header.name, header.value });
    try writer.print("\n{s}", .{request.body});
    return out.toOwnedSlice();
}

fn writeEvent(writer: *std.Io.Writer, event: *const core.Provider.Event) !void {
    switch (event.*) {
        .text => |delta| try writer.print("text:{s}", .{delta}),
        .reasoning_started => try writer.writeAll("reasoning_started"),
        .reasoning => |delta| try writer.print("reasoning:{s}", .{delta}),
        .tool_call_started => |name| try writer.print("tool_call_started:{s}", .{name}),
        .tool_call_arguments => |delta| try writer.print("tool_call_arguments:{s}", .{delta}),
        .output => |output| switch (output) {
            .message => |text| try writer.print("message:{s}", .{text}),
            .reasoning => |proof| try writer.print("proof:{s}:{s}", .{
                proof.account,
                proof.payload,
            }),
            .tool_call => |call| try writer.print("tool_call:{s}|{s}|{s}", .{
                call.id,
                call.name,
                call.arguments,
            }),
        },
        .usage => |usage| {
            try writer.print("usage:{d}/{d}/{d}/{d}", .{
                usage.input,
                usage.output,
                usage.cache_read,
                usage.cache_write,
            });
            if (usage.cost_usd) |cost| try writer.print("|{d}", .{cost});
        },
        .quota => |quota| {
            try writer.writeAll("quota:");
            try writeWindow(writer, &quota.primary);
            try writer.writeAll("|");
            try writeWindow(writer, &quota.secondary);
        },
        .credits => |credits| try writer.print("credits:{d}/{d}", .{ credits.total, credits.used }),
        .stopped => |stop| try writer.print("stopped:{s}|{s}", .{
            @tagName(stop.reason),
            stop.model,
        }),
        .failed => |failure| {
            try writer.print("failed:{s}|", .{@tagName(failure.reason)});
            if (failure.retry_after_ms) |ms| {
                try writer.print("{d}", .{ms});
            } else {
                try writer.writeAll("-");
            }
            try writer.print("|{s}", .{failure.message});
        },
    }
}

fn writeWindow(writer: *std.Io.Writer, maybe_window: *const ?core.Provider.Quota.Window) !void {
    const window = maybe_window.* orelse return writer.writeAll("-");
    try writer.print("{d}", .{window.used_percent});
    if (window.window_minutes) |minutes| try writer.print("/{d}m", .{minutes});
    if (window.reset_seconds) |seconds| try writer.print("/{d}s", .{seconds});
}

pub fn trace(
    gpa: std.mem.Allocator,
    provider: core.Provider,
    request: *const core.Provider.Request,
) TraceError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try provider.open(request);
    defer provider.close();
    for (0..1 << 16) |_| {
        const event = (try provider.next()) orelse break;
        try writeEvent(&out.writer, &event);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

pub fn DialectRig(comptime Wire: type) type {
    return struct {
        wire: Wire,
        frames: Frames,

        const Rig = @This();

        pub fn init(self: *Rig, options: Wire.Options) void {
            self.wire = .init(std.testing.allocator, options);
            self.frames = .init(std.testing.allocator, self.wire.dialect());
        }

        pub fn deinit(self: *Rig) void {
            self.frames.deinit();
            self.wire.deinit();
        }

        pub fn body(
            options: Wire.Options,
            request: *const core.Provider.Request,
        ) !std.json.Parsed(std.json.Value) {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var wire: Wire = .init(std.testing.allocator, options);
            defer wire.deinit();
            const bytes = try wire.body(arena.allocator(), request);
            return std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        }

        pub fn expectFailure(
            options: Wire.Options,
            failed: *const Dialect.Failed,
            expected: []const u8,
        ) !void {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var wire: Wire = .init(std.testing.allocator, options);
            defer wire.deinit();
            const failure = try wire.dialect().failure(arena.allocator(), failed);
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            try writeEvent(&out.writer, &.{ .failed = failure });
            try std.testing.expectEqualStrings(expected, out.written());
        }

        pub fn checkDecodeAllocationFailures(
            options: Wire.Options,
            payloads: []const []const u8,
        ) !void {
            try std.testing.checkAllAllocationFailures(
                std.testing.allocator,
                decodeAll,
                .{ options, payloads },
            );
        }

        fn decodeAll(
            gpa: std.mem.Allocator,
            options: Wire.Options,
            payloads: []const []const u8,
        ) !void {
            var wire: Wire = .init(gpa, options);
            defer wire.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const dialect = wire.dialect();
            dialect.reset();
            for (payloads) |payload| {
                _ = arena.reset(.free_all);
                var events: Dialect.Events = .empty;
                _ = try dialect.decode(arena.allocator(), payload, &events);
            }
            _ = arena.reset(.free_all);
            var events: Dialect.Events = .empty;
            try dialect.finish(arena.allocator(), &events);
        }
    };
}

pub fn oneLine(comptime text: []const u8) []const u8 {
    return comptime join: {
        @setEvalBranchQuota(2 * text.len);
        var bytes: [text.len]u8 = undefined;
        var len: usize = 0;
        for (text) |byte| {
            if (byte == '\n') continue;
            bytes[len] = byte;
            len += 1;
        }
        const joined = bytes[0..len].*;
        break :join &joined;
    };
}
