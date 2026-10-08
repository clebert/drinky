const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Model = @import("Model.zig");

const pages_max = 8;
pub const entries_max = 1024;

pub const Error = providers.Http.FetchError || error{
    Timeout,
    ConcurrencyUnavailable,
    BadModelListCredentials,
    ModelListRequestFailed,
    BadModelList,
};

pub const Page = struct {
    models: []Model,
    cursor: ?[]u8,

    pub fn deinit(self: *const Page, gpa: std.mem.Allocator) void {
        gpa.free(self.models);
        if (self.cursor) |cursor| gpa.free(cursor);
    }
};

fn Request(comptime Options: type) type {
    return fn (
        std.mem.Allocator,
        std.Io,
        ?providers.Transport,
        *const Options,
        ?[]const u8,
    ) Error!Page;
}

pub fn collect(
    comptime Options: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    deadline: *const core.timeout.Deadline,
    options: *const Options,
    comptime request: Request(Options),
) Error![]Model {
    const Release = struct {
        fn release(page: *const Page, args: *const std.meta.ArgsTuple(Request(Options))) void {
            page.deinit(args[0]);
        }
    };
    var collected: std.ArrayList(Model) = .empty;
    errdefer collected.deinit(gpa);
    var cursor: ?[]u8 = null;
    defer if (cursor) |bytes| gpa.free(bytes);
    for (0..pages_max) |_| {
        const page = try deadline.run(
            io,
            request,
            .{ gpa, io, transport, options, cursor },
            Release.release,
        );
        defer gpa.free(page.models);
        if (cursor) |bytes| gpa.free(bytes);
        cursor = page.cursor;
        if (collected.items.len + page.models.len > entries_max) return error.BadModelList;
        try collected.appendSlice(gpa, page.models);
        if (cursor == null) break;
    }
    return collected.toOwnedSlice(gpa);
}

test "the pages follow the cursor of each page to the last page" {
    const gpa = std.testing.allocator;
    var trace: std.ArrayList(u8) = .empty;
    defer trace.deinit(gpa);
    const models = try collect(FakePages, gpa, std.testing.io, null, &.unbounded, &.{
        .scripts = &.{
            .{ .count = 1, .cursor = "second" },
            .{ .count = 2, .cursor = "third" },
            .{ .count = 1, .cursor = null },
        },
        .trace = &trace,
    }, FakePages.request);
    defer gpa.free(models);

    try std.testing.expectEqual(@as(usize, 4), models.len);
    try std.testing.expectEqualStrings("-|second|third|", trace.items);
}

const FakePages = struct {
    scripts: []const Script,
    trace: *std.ArrayList(u8),

    const Script = struct {
        count: usize,
        cursor: ?[]const u8,
    };

    fn request(
        gpa: std.mem.Allocator,
        _: std.Io,
        _: ?providers.Transport,
        self: *const FakePages,
        cursor: ?[]const u8,
    ) Error!Page {
        const script = self.scripts[std.mem.count(u8, self.trace.items, "|")];
        try self.trace.print(gpa, "{s}|", .{cursor orelse "-"});
        const models = try gpa.alloc(Model, script.count);
        errdefer gpa.free(models);
        for (models) |*model| model.* = Model.init("model") catch unreachable;
        const next = if (script.cursor) |bytes| try gpa.dupe(u8, bytes) else null;
        return .{ .models = models, .cursor = next };
    }
};

test "the pages stop at the page cap" {
    const gpa = std.testing.allocator;
    var trace: std.ArrayList(u8) = .empty;
    defer trace.deinit(gpa);
    const scripts: [pages_max + 1]FakePages.Script = @splat(.{ .count = 1, .cursor = "again" });
    const models = try collect(FakePages, gpa, std.testing.io, null, &.unbounded, &.{
        .scripts = &scripts,
        .trace = &trace,
    }, FakePages.request);
    defer gpa.free(models);

    try std.testing.expectEqual(@as(usize, pages_max), std.mem.count(u8, trace.items, "|"));
    try std.testing.expectEqual(@as(usize, pages_max), models.len);
}

test "the entries of every page count against one bound" {
    const gpa = std.testing.allocator;
    var trace: std.ArrayList(u8) = .empty;
    defer trace.deinit(gpa);
    const models = try collect(FakePages, gpa, std.testing.io, null, &.unbounded, &.{
        .scripts = &.{
            .{ .count = entries_max - 1, .cursor = "last" },
            .{ .count = 1, .cursor = null },
        },
        .trace = &trace,
    }, FakePages.request);
    defer gpa.free(models);
    try std.testing.expectEqual(@as(usize, entries_max), models.len);

    trace.clearRetainingCapacity();
    try std.testing.expectError(error.BadModelList, collect(
        FakePages,
        gpa,
        std.testing.io,
        null,
        &.unbounded,
        &.{
            .scripts = &.{
                .{ .count = entries_max - 1, .cursor = "last" },
                .{ .count = 2, .cursor = null },
            },
            .trace = &trace,
        },
        FakePages.request,
    ));
}
