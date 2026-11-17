const std = @import("std");
const application = @import("application");

const terminal = @import("terminal");

const App = @import("App.zig");
const command_line = @import("command_line.zig");
const headless = @import("headless.zig");
const Herdr = @import("Herdr.zig");
const mcp = @import("mcp/root.zig");

const failure_exit_code = 1;

pub const panic = std.debug.FullPanic(restoreAndPanic);

pub fn main(init: std.process.Init) !void {
    run(&init) catch |err| switch (err) {
        error.OutOfMemory => application.support.outOfMemory(),
        else => return err,
    };
}

fn run(init: *const std.process.Init) !void {
    std.posix.sigaction(.TERM, &.{
        .handler = .{ .handler = restoreAndTerminate },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESETHAND,
    }, null);
    const gpa = init.gpa;
    const io = init.io;
    const home = init.environ_map.get("HOME") orelse return error.NoHomeDir;
    const cwd = try workingDirectory(gpa, io);
    defer gpa.free(cwd);

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed = command_line.parse(arguments[@min(1, arguments.len)..]);
    const directories: application.Directories = .{
        .working_directory = cwd,
        .home = home,
    };
    if (parsed == .terminal) return runTerminal(init, &directories);
    if (parsed == .mcp) return runGateway(init, home);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const options: headless.Options = .{
        .directories = directories,
        .environment = init.environ_map,
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
    };
    const succeeded = switch (parsed) {
        .terminal, .mcp => unreachable,
        .models => try headless.models(gpa, io, &options),
        .run => |request| run: {
            var stdin_buffer: [4096]u8 = undefined;
            var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
            const prompt = try stdin.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(prompt);
            break :run try headless.run(gpa, io, &options, &.{ .run = request, .prompt = prompt });
        },
        .refused => |*refusal| refused: {
            try refusal.write(gpa, &stderr.interface);
            break :refused false;
        },
    };
    try stdout.interface.flush();
    try stderr.interface.flush();
    if (!succeeded) std.process.exit(failure_exit_code);
}

fn runGateway(init: *const std.process.Init, home: []const u8) !void {
    const gpa = init.gpa;
    const io = init.io;
    const directory = try mcp.discovery.directory(gpa, home);
    defer gpa.free(directory);
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    var gateway: mcp.Gateway = .{
        .gpa = gpa,
        .io = io,
        .directory = directory,
        .output = &stdout.interface,
    };
    try gateway.serve(&stdin.interface);
}

fn runTerminal(
    init: *const std.process.Init,
    directories: *const application.Directories,
) !void {
    var tty: terminal.Tty = undefined;
    try tty.init(init.io);
    defer tty.deinit();
    const mcp_directory = try mcp.discovery.directory(init.gpa, directories.home);
    defer init.gpa.free(mcp_directory);
    var app: App = undefined;
    try app.init(init.gpa, init.io, &.{
        .working_directory = directories.working_directory,
        .home = directories.home,
        .mcp_directory = mcp_directory,
        .device = tty.device(),
        .environment = init.environ_map,
        .environ = init.minimal.environ,
        .herdr = Herdr.fromEnviron(init.environ_map),
    });
    defer app.deinit();
    try app.run();
}

fn workingDirectory(gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    const path = try std.process.currentPathAlloc(io, gpa);
    errdefer gpa.free(path);
    if (std.unicode.utf8ValidateSlice(path)) return path;
    const safe_path = try application.support.diagnostic(gpa, path);
    defer gpa.free(safe_path);
    std.debug.print(
        "Drinky cannot use the working directory {s} because its path is not valid UTF-8.\n",
        .{safe_path},
    );
    return error.WorkingDirectoryNotUtf8;
}

fn restoreAndPanic(message: []const u8, first_trace_address: ?usize) noreturn {
    terminal.Tty.restore();
    std.debug.defaultPanic(message, first_trace_address);
}

fn restoreAndTerminate(signal: std.posix.SIG) callconv(.c) void {
    terminal.Tty.restore();
    std.posix.raise(signal) catch {};
}

test {
    std.testing.refAllDecls(@This());
}

test "the working directory is the current path when a sandbox denies its parent directories" {
    const gpa = std.testing.allocator;
    const sandboxed: SandboxedIo = .init();

    const working_directory = try workingDirectory(gpa, sandboxed.io());
    defer gpa.free(working_directory);

    try std.testing.expectEqualStrings(SandboxedIo.current_path, working_directory);
}

const SandboxedIo = struct {
    vtable: std.Io.VTable,

    const current_path = "/private/tmp/evaluation/work";

    fn init() SandboxedIo {
        var vtable = std.testing.io.vtable.*;
        vtable.processCurrentPath = currentPath;
        vtable.dirRealPathFile = realPathFile;
        return .{ .vtable = vtable };
    }

    fn io(self: *const SandboxedIo) std.Io {
        return .{ .userdata = std.testing.io.userdata, .vtable = &self.vtable };
    }

    fn currentPath(_: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
        @memcpy(buffer[0..current_path.len], current_path);
        return current_path.len;
    }

    fn realPathFile(
        _: ?*anyopaque,
        _: std.Io.Dir,
        _: []const u8,
        _: []u8,
    ) std.Io.Dir.RealPathFileError!usize {
        return error.Unexpected;
    }
};
