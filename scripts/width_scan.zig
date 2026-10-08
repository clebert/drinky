const std = @import("std");

const zig_files = @import("zig_files.zig");

const columns_max = 100;

const Overflow = struct { line: usize, columns: usize };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var roots: std.ArrayList([]const u8) = .empty;
    var arguments = try init.minimal.args.iterateAllocator(arena);
    _ = arguments.skip();
    while (arguments.next()) |argument| try roots.append(arena, argument);
    if (roots.items.len == 0) std.process.fatal("usage: width_scan path...", .{});

    var found: std.ArrayList(Overflow) = .empty;
    var total: usize = 0;
    for (try zig_files.collect(arena, io, roots.items)) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        found.clearRetainingCapacity();
        try overflows(arena, source, &found);
        for (found.items) |overflow| {
            std.debug.print("{s}:{d}: {d} columns\n", .{ path, overflow.line, overflow.columns });
        }
        total += found.items.len;
    }
    if (total == 0) return;
    std.debug.print("width_scan: found {d} lines over {d} columns.\n", .{ total, columns_max });
    std.process.exit(1);
}

fn overflows(gpa: std.mem.Allocator, source: []const u8, found: *std.ArrayList(Overflow)) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line: usize = 0;
    while (lines.next()) |text| {
        line += 1;
        const width = columns(text);
        if (width > columns_max) try found.append(gpa, .{ .line = line, .columns = width });
    }
}

fn columns(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| count += @intFromBool(byte & 0xC0 != 0x80);
    return count;
}

test "a line with multi-byte characters at the width passes, and one more column fails" {
    const pairs: [50][5]u8 = @splat("·–".*);
    const at_width: *const [250]u8 = @ptrCast(&pairs);
    try std.testing.expect(at_width.len > columns_max);

    var found: std.ArrayList(Overflow) = .empty;
    defer found.deinit(std.testing.allocator);
    try overflows(std.testing.allocator, at_width ++ "\n" ++ at_width ++ "x\n", &found);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(Overflow{ .line = 2, .columns = 101 }, found.items[0]);
}

test {
    std.testing.refAllDecls(@This());
}
