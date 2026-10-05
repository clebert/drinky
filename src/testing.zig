const std = @import("std");

pub const Tree = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    paths: std.ArrayList([]u8),

    pub fn init() !Tree {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .tmp = tmp, .root = root, .paths = .empty };
    }

    pub fn deinit(self: *Tree) void {
        for (self.paths.items) |path_item| std.testing.allocator.free(path_item);
        self.paths.deinit(std.testing.allocator);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    pub fn path(self: *Tree, sub_path: []const u8) ![]const u8 {
        const gpa = std.testing.allocator;
        const joined = try std.fs.path.join(gpa, &.{ self.root, sub_path });
        errdefer gpa.free(joined);
        try self.paths.append(gpa, joined);
        return joined;
    }

    pub fn directory(self: *Tree, sub_path: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, sub_path);
    }

    pub fn write(self: *Tree, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent| try self.directory(parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    pub fn skill(
        self: *Tree,
        parent: []const u8,
        options: *const struct { name: []const u8, description: []const u8 },
    ) !void {
        var path_buffer: [256]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&path_buffer, "{s}/SKILL.md", .{parent});
        var source_buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(
            &source_buffer,
            "---\nname: {s}\ndescription: {s}\n---\nFollow this skill.\n",
            .{ options.name, options.description },
        );
        try self.write(sub_path, source);
    }

    pub fn link(
        self: *Tree,
        target: []const u8,
        sub_path: []const u8,
        flags: std.Io.Dir.SymLinkFlags,
    ) !void {
        self.tmp.dir.symLink(std.testing.io, target, sub_path, flags) catch |err| switch (err) {
            error.AccessDenied,
            error.PermissionDenied,
            error.ReadOnlyFileSystem,
            => return error.SkipZigTest,
            else => return err,
        };
    }
};
