const std = @import("std");
const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");
const testing = @import("testing.zig");

pub const Options = struct {
    directories: accounts.json_store.Directories,
    environment: *const std.process.Environ.Map,
    transport: ?providers.Transport = null,
};

const sink_vtable: accounts.Registry.Sink.VTable = .{ .emit = ignore };

fn ignore(_: *anyopaque, _: *const accounts.Registry.Event) void {}

pub fn compose(gpa: std.mem.Allocator, io: std.Io, options: *const Options) ![]u8 {
    var registry: accounts.Registry = undefined;
    try registry.init(gpa, io, &.{
        .directories = options.directories,
        .environment = options.environment,
        .sink = .{ .ptr = &registry, .vtable = &sink_vtable },
        .transport = options.transport,
    });
    defer registry.deinit();
    var list: std.ArrayList(accounts.Model) = .empty;
    defer list.deinit(gpa);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (&accounts.Account.table, 0..) |*row, account| {
        if (!registry.isAuthenticated(account)) continue;
        list.clearRetainingCapacity();
        try registry.listModels(account, &list, gpa);
        for (list.items) |*model| output.writer.print("{s}/{s}\n", .{ row.id, model.name() }) catch
            return error.OutOfMemory;
    }
    return output.toOwnedSlice();
}

test "model listing names the saved models and starts no request" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .config = "not JSON" });
    defer rig.deinit();
    const list = try compose(std.testing.allocator, std.testing.io, &.{
        .directories = .{ .working_directory = rig.tree.root, .home = rig.tree.root },
        .environment = &rig.environment,
        .transport = rig.transport.transport(),
    });
    defer std.testing.allocator.free(list);
    try std.testing.expectEqualStrings("openai-api-key/gpt-5.6-sol\n", list);
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "model listing returns every allocation failure and releases every partial allocation" {
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    var catalog: accounts.testing.Rig = undefined;
    try catalog.init(std.testing.allocator, std.testing.io, &.{ .home = tree.root });
    try catalog.seed(accounts.testing.openai_api_key, &.{ "gpt-5.6-sol", "gpt-5.6-luna" });
    catalog.deinit();
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("OPENAI_API_KEY", "key");
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkComposition,
        .{ tree.root, &environment },
    );
}

fn checkComposition(
    gpa: std.mem.Allocator,
    directory: []const u8,
    environment: *const std.process.Environ.Map,
) !void {
    const list = try compose(gpa, std.testing.io, &.{
        .directories = .{ .working_directory = directory, .home = directory },
        .environment = environment,
    });
    defer gpa.free(list);
    try std.testing.expectEqualStrings(
        "openai-api-key/gpt-5.6-sol\nopenai-api-key/gpt-5.6-luna\n",
        list,
    );
}
