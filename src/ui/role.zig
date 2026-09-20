const std = @import("std");

const terminal = @import("terminal");

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

fn legalParameter(parameter: u16) bool {
    if (parameter == 2 or parameter == 7 or parameter == 22) return true;
    return parameter >= 30 and parameter <= 39;
}

const Pinned = struct { name: Name, sequence: []const u8 };

fn expectSequences(pinned: []const Pinned) !void {
    var seen: std.EnumSet(Name) = .initEmpty();
    inline for (std.enums.values(Name)) |name| {
        for (pinned) |entry| {
            if (entry.name != name) continue;
            try std.testing.expectEqualStrings(entry.sequence, sequence(name));
            seen.insert(name);
        }
    }
    try std.testing.expectEqual(std.enums.values(Name).len, seen.count());
}

test "the role map pins the SGR sequence for each role" {
    try expectSequences(&.{
        .{ .name = .text, .sequence = "" },
        .{ .name = .muted, .sequence = "\x1b[2;39m" },
        .{ .name = .accent, .sequence = "\x1b[22;36m" },
        .{ .name = .heading, .sequence = "\x1b[33m" },
        .{ .name = .code, .sequence = "\x1b[32m" },
        .{ .name = .link, .sequence = "\x1b[34m" },
        .{ .name = .warning, .sequence = "\x1b[33m" },
        .{ .name = .@"error", .sequence = "\x1b[31m" },
        .{ .name = .user, .sequence = "\x1b[35;7m" },
        .{ .name = .user_note, .sequence = "\x1b[35m" },
        .{ .name = .input_frame, .sequence = "\x1b[35m" },
        .{ .name = .activity, .sequence = "\x1b[36m" },
        .{ .name = .tool_pending, .sequence = "\x1b[36;7m" },
        .{ .name = .tool_success, .sequence = "\x1b[32;7m" },
        .{ .name = .tool_error, .sequence = "\x1b[31;7m" },
        .{ .name = .selection, .sequence = "\x1b[7m" },
    });
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

test "a role reaches the row as one SGR sequence, and the text role as none" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();

    const sink = try view.beginFrame(.{ .columns = 20, .rows = 2 }, 1);
    sink.begin();
    try apply(sink, .user);
    try sink.text("title");
    sink.end(.{ .id = 0, .line = 0 });
    sink.begin();
    try apply(sink, .text);
    try sink.text("plain");
    sink.end(.{ .id = 0, .line = 1 });
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[35;7mtitle") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[0mplain") == null);
    try std.testing.expect(paints(.user));
    try std.testing.expect(!paints(.text));
}
