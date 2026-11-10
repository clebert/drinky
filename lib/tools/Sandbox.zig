const std = @import("std");
const builtin = @import("builtin");

const Sandbox = @This();

directories: []const []const u8,
files: []const []const u8,

pub const available = switch (builtin.os.tag) {
    .macos => true,
    else => false,
};

const executable = "/usr/bin/sandbox-exec";

const devices = [_][]const u8{
    "/dev/null", "/dev/zero", "/dev/tty", "/dev/dtracehelper", "/dev/ptmx",
};

const device_patterns = [_][]const u8{ "^/dev/fd/", "^/dev/ttys[0-9]+$" };

const regex_special = "\\.^$|?*+()[]{}";

const replacement_name_digits = 2 * @sizeOf(@FieldType(std.Io.File.Atomic, "file_basename_hex"));

const darwin = struct {
    extern "c" fn sandbox_check(
        process_id: std.c.pid_t,
        operation: ?[*:0]const u8,
        filter: c_int,
        ...,
    ) c_int;
};

pub fn inherited() bool {
    return switch (builtin.os.tag) {
        .macos => darwin.sandbox_check(std.c.getpid(), null, 0) != 0,
        else => false,
    };
}

pub fn allows(self: *const Sandbox, path: []const u8) bool {
    for (self.directories) |directory| {
        if (contains(&.{ .directory = directory, .path = path })) return true;
    }
    for (self.files) |file| {
        if (std.mem.eql(u8, file, path)) return true;
    }
    return false;
}

pub fn argv(
    self: *const Sandbox,
    arena: std.mem.Allocator,
    command: [:0]const u8,
) error{OutOfMemory}![:null]?[*:0]const u8 {
    var profile: std.Io.Writer.Allocating = .init(arena);
    self.writeProfile(&profile.writer) catch return error.OutOfMemory;
    const text = try profile.toOwnedSliceSentinel(0);
    return arena.dupeSentinel(?[*:0]const u8, &[_]?[*:0]const u8{
        executable, "-p", text.ptr, "bash", "-c", command.ptr,
    }, null);
}

fn contains(options: *const struct { directory: []const u8, path: []const u8 }) bool {
    const directory = options.directory;
    const path = options.path;
    if (!std.mem.startsWith(u8, path, directory)) return false;
    if (path.len == directory.len) return true;
    return std.mem.endsWith(u8, directory, "/") or path[directory.len] == '/';
}

fn writeProfile(self: *const Sandbox, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*\n");
    for (devices) |device| try writeFilter(writer, "literal", device);
    for (device_patterns) |pattern| try writeFilter(writer, "regex", pattern);
    for (self.directories) |directory| try writeFilter(writer, "subpath", directory);
    for (self.files, 0..) |file, index| {
        try writeFilter(writer, "literal", file);
        const parent = std.Io.Dir.path.dirname(file).?;
        const repeated = for (self.files[0..index]) |earlier| {
            if (std.mem.eql(u8, std.Io.Dir.path.dirname(earlier).?, parent)) break true;
        } else false;
        if (repeated) continue;
        try writer.writeAll("  (regex \"^");
        try writeRegexQuoted(writer, std.mem.trimEnd(u8, parent, "/"));
        try writer.writeByte('/');
        for (0..replacement_name_digits) |_| try writer.writeAll("[0-9a-f]");
        try writer.writeAll("$\")\n");
    }
    try writer.writeAll(")\n");
}

fn writeFilter(
    writer: *std.Io.Writer,
    comptime kind: []const u8,
    path: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("  (" ++ kind ++ " \"");
    try writeQuoted(writer, path);
    try writer.writeAll("\")\n");
}

fn writeQuoted(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| {
        if (byte == '\\' or byte == '"') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
}

fn writeRegexQuoted(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| {
        if (std.mem.findScalar(u8, regex_special, byte) != null) try writer.writeAll("\\\\");
        try writeQuoted(writer, &.{byte});
    }
}

test "a sandbox allows a path inside its directories and its exact files" {
    const sandbox: Sandbox = .{
        .directories = &.{ "/work/repo", "/tmp/" },
        .files = &.{"/home/.drinky/auth.json"},
    };
    const cases = [_]struct { path: []const u8, allowed: bool }{
        .{ .path = "/work/repo", .allowed = true },
        .{ .path = "/work/repo/src/a.zig", .allowed = true },
        .{ .path = "/work/repository", .allowed = false },
        .{ .path = "/work", .allowed = false },
        .{ .path = "/tmp/a", .allowed = true },
        .{ .path = "/tmpa", .allowed = false },
        .{ .path = "/home/.drinky/auth.json", .allowed = true },
        .{ .path = "/home/.drinky/auth.json.bak", .allowed = false },
        .{ .path = "/home/.drinky", .allowed = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.allowed, sandbox.allows(case.path));
}
