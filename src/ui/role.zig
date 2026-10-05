const std = @import("std");

const terminal = @import("terminal");

const testing = @import("testing.zig");

pub const Name = enum {
    text,
    muted,
    accent,
    heading,
    code,
    link,
    warning,
    @"error",
    user,
    user_note,
    input_frame,
    activity,
    tool_pending,
    tool_success,
    tool_error,
    selection,
};

pub fn sequence(comptime name: Name) []const u8 {
    return switch (name) {
        .text => "",
        .muted => "\x1b[2;39m",
        .accent => "\x1b[22;36m",
        .heading => "\x1b[33m",
        .code => "\x1b[32m",
        .link => "\x1b[34m",
        .warning => "\x1b[33m",
        .@"error" => "\x1b[31m",
        .user => "\x1b[35;7m",
        .user_note => "\x1b[35m",
        .input_frame => "\x1b[35m",
        .activity => "\x1b[36m",
        .tool_pending => "\x1b[36;7m",
        .tool_success => "\x1b[32;7m",
        .tool_error => "\x1b[31;7m",
        .selection => "\x1b[7m",
    };
}

pub fn apply(sink: *terminal.View.Sink, name: Name) !void {
    switch (name) {
        .text => {},
        inline else => |tag| try sink.sgr(sequence(tag)),
    }
}

pub fn paints(name: Name) bool {
    return name != .text;
}

test "every role uses terminal colors and supported role attributes alone" {
    inline for (std.enums.values(Name)) |name| {
        const bytes = comptime sequence(name);
        try std.testing.expectEqual(paints(name), bytes.len > 0);
        if (comptime bytes.len > 0) {
            try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b["));
            try std.testing.expect(std.mem.endsWith(u8, bytes, "m"));
            var parameters = std.mem.splitScalar(u8, bytes[2 .. bytes.len - 1], ';');
            while (parameters.next()) |text| {
                try std.testing.expect(legalParameter(try std.fmt.parseInt(u16, text, 10)));
            }
        }
    }
}

fn legalParameter(parameter: u16) bool {
    if (parameter == 2 or parameter == 7 or parameter == 22) return true;
    return parameter >= 30 and parameter <= 39;
}

test "a role reaches the row as one SGR sequence, and the text role as none" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();

    const sink = (try rig.begin(&.{ .columns = 20, .rows = 2 })).sink;
    sink.begin();
    try apply(sink, .user);
    try sink.text("title");
    sink.end(.{ .id = 0, .line = 0 });
    sink.begin();
    try apply(sink, .text);
    try sink.text("plain");
    sink.end(.{ .id = 0, .line = 1 });

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{"\x1b[35;7mtitle"});
    try testing.expectShows(painted, &.{"title\r\nplain"});
}
