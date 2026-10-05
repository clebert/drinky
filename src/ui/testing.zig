const std = @import("std");

const terminal = @import("terminal");

const paint = @import("paint.zig");

pub const Rig = struct {
    gpa: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    view: terminal.View,
    frame_start: usize,
    rendered: bool,
    plain_texts: std.ArrayList([]u8),

    const Frame = struct {
        columns: usize,
        rows: usize,
        pages: usize = 1,
        skip: usize = 0,
    };

    pub fn init(self: *Rig, gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        self.out = .init(gpa);
        self.view = .init(gpa, &self.out.writer);
        self.frame_start = 0;
        self.rendered = false;
        self.plain_texts = .empty;
    }

    pub fn deinit(self: *Rig) void {
        for (self.plain_texts.items) |text| self.gpa.free(text);
        self.plain_texts.deinit(self.gpa);
        self.view.deinit();
        self.out.deinit();
    }

    pub fn begin(self: *Rig, frame: *const Frame) !paint.Placement {
        self.frame_start = self.out.written().len;
        self.rendered = false;
        const size: terminal.View.Size = .{ .columns = frame.columns, .rows = frame.rows };
        return .{
            .sink = try self.view.beginFrame(size, frame.pages),
            .id = 0,
            .columns = frame.columns,
            .base = 0,
            .skip = frame.skip,
        };
    }

    pub fn painted(self: *Rig) ![]const u8 {
        if (!self.rendered) try self.view.render();
        self.rendered = true;
        return self.out.written()[self.frame_start..];
    }

    pub fn plain(self: *Rig) ![]const u8 {
        const text = try terminal.testing.plainText(self.gpa, try self.painted());
        errdefer self.gpa.free(text);
        try self.plain_texts.append(self.gpa, text);
        return text;
    }
};

pub fn paintedRows(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\r\n") + 1;
}

pub fn numberedLines(gpa: std.mem.Allocator, count: usize) !std.ArrayList(u8) {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    for (0..count) |index| {
        if (index > 0) try text.append(gpa, '\n');
        try text.print(gpa, "L{d}", .{index});
    }
    return text;
}

pub fn expectShows(painted: []const u8, texts: []const []const u8) !void {
    for (texts) |text| {
        if (std.mem.indexOf(u8, painted, text) != null) continue;
        std.debug.print("The painted bytes do not show \"{s}\".\n", .{text});
        return error.TestExpectedShown;
    }
}

pub fn expectHides(painted: []const u8, texts: []const []const u8) !void {
    for (texts) |text| {
        if (std.mem.indexOf(u8, painted, text) == null) continue;
        std.debug.print("The painted bytes still show \"{s}\".\n", .{text});
        return error.TestExpectedHidden;
    }
}
