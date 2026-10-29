const std = @import("std");
const discovery = @import("discovery.zig");
const Gateway = @import("Gateway.zig");

const rpc_meta = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"," ++
    "\"io.modelcontextprotocol/clientCapabilities\":{}}";
const call_head = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{" ++
    rpc_meta ++ ",\"name\":\"";

pub fn rpc(comptime method: []const u8, comptime params: []const u8) []const u8 {
    const separator = if (params.len == 0) "" else ",";
    return "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"" ++ method ++ "\",\"params\":{" ++
        rpc_meta ++ separator ++ params ++ "}}";
}

pub fn toolCall(comptime name: []const u8, comptime arguments: []const u8) []const u8 {
    return call_head ++ name ++ "\",\"arguments\":" ++ arguments ++ "}}";
}

pub fn member(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.TestExpectedObject;
    return value.object.get(name) orelse error.TestExpectedMember;
}

pub const Client = struct {
    output: std.Io.Writer.Allocating,
    gateway: Gateway,

    pub const Called = struct {
        parsed: std.json.Parsed(std.json.Value),
        content: std.json.Value,
        failed: bool,

        pub fn deinit(self: *const Called) void {
            self.parsed.deinit();
        }

        pub fn text(self: *const Called, name: []const u8) ![]const u8 {
            const value = try member(self.content, name);
            if (value != .string) return error.TestExpectedString;
            return value.string;
        }
    };

    pub fn init(self: *Client, directory: []const u8) void {
        self.output = .init(std.testing.allocator);
        self.gateway = .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .directory = directory,
            .output = &self.output.writer,
        };
    }

    pub fn deinit(self: *Client) void {
        self.output.deinit();
    }

    pub fn send(self: *Client, line: []const u8) !std.json.Parsed(std.json.Value) {
        self.output.clearRetainingCapacity();
        try self.gateway.handle(line);
        const written = self.output.written();
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\n"));
        try std.testing.expectEqual('\n', written[written.len - 1]);
        return std.json.parseFromSlice(std.json.Value, std.testing.allocator, written, .{
            .allocate = .alloc_always,
        });
    }

    pub fn call(self: *Client, comptime name: []const u8, arguments: []const u8) !Called {
        const line = try std.mem.concat(std.testing.allocator, u8, &.{
            call_head ++ name ++ "\",\"arguments\":",
            arguments,
            "}}",
        });
        defer std.testing.allocator.free(line);
        return self.result(line);
    }

    pub fn target(
        self: *Client,
        comptime name: []const u8,
        id: *const discovery.Id,
        rest: []const u8,
    ) !Called {
        const arguments = try std.mem.concat(std.testing.allocator, u8, &.{
            "{\"instance_id\":\"",
            id,
            "\"",
            rest,
            "}",
        });
        defer std.testing.allocator.free(arguments);
        return self.call(name, arguments);
    }

    pub fn result(self: *Client, line: []const u8) !Called {
        const parsed = try self.send(line);
        errdefer parsed.deinit();
        const outcome = try member(parsed.value, "result");
        const kind = try member(outcome, "resultType");
        try std.testing.expectEqualStrings("complete", kind.string);
        const blocks = (try member(outcome, "content")).array.items;
        try std.testing.expectEqualStrings("text", (try member(blocks[0], "type")).string);
        return .{
            .parsed = parsed,
            .content = try member(outcome, "structuredContent"),
            .failed = (try member(outcome, "isError")).bool,
        };
    }

    pub fn instance(self: *Client, working_directory: []const u8) !discovery.Id {
        const listed = try self.call("list_instances", "{}");
        defer listed.deinit();
        const instances = (try member(listed.content, "instances")).array.items;
        try std.testing.expectEqual(@as(usize, 1), instances.len);
        const entry = instances[0];
        try std.testing.expectEqualStrings("available", (try member(entry, "status")).string);
        try std.testing.expectEqualStrings(
            working_directory,
            (try member(entry, "working_directory")).string,
        );
        return discovery.parseId((try member(entry, "instance_id")).string) orelse
            error.TestExpectedInstance;
    }
};
