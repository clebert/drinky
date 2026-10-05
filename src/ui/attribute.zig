const std = @import("std");

const terminal = @import("terminal");

const role = @import("role.zig");
const testing = @import("testing.zig");

const Name = enum {
    reset,
    bold,
    italic,
    underline,
    double_underline,
    strikethrough,
};

pub fn sequence(comptime name: Name) []const u8 {
    return switch (name) {
        .reset => "\x1b[0m",
        .bold => "\x1b[1m",
        .italic => "\x1b[3m",
        .underline => "\x1b[4m",
        .double_underline => "\x1b[21m",
        .strikethrough => "\x1b[9m",
    };
}

pub fn apply(sink: *terminal.View.Sink, name: Name) !void {
    switch (name) {
        inline else => |tag| try sink.sgr(sequence(tag)),
    }
}

pub fn emphasize(sink: *terminal.View.Sink, name: role.Name, underlined: bool) !void {
    try apply(sink, emphasis(name, underlined));
}

fn emphasis(name: role.Name, underlined: bool) Name {
    if (name != .muted) return .bold;
    return if (underlined) .double_underline else .underline;
}

test "muted emphasis stays distinct from an existing underline" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const names = comptime std.enums.values(role.Name);
    const sink = (try rig.begin(&.{ .columns = 40, .rows = 2 * names.len })).sink;
    var line: usize = 0;
    inline for (names) |name| {
        for ([_]bool{ false, true }) |underlined| {
            sink.begin();
            try emphasize(sink, name, underlined);
            try sink.text(@tagName(name) ++ ".");
            sink.end(.{ .id = 0, .line = line });
            line += 1;
        }
    }

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        comptime sequence(.underline) ++ "muted.",
        comptime sequence(.double_underline) ++ "muted.",
    });
    inline for (names) |name| {
        if (name == .muted) continue;
        const bold = comptime sequence(.bold) ++ @tagName(name) ++ ".";
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, painted, bold));
    }
}
