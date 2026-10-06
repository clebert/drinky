const std = @import("std");

const accounts = @import("accounts");
const terminal = @import("terminal");

const App = @import("App.zig");
const command_line = @import("command_line.zig");
const escape = @import("escape.zig");
const headless = @import("headless.zig");
const Herdr = @import("Herdr.zig");

const failure_exit_code = 1;

pub const panic = std.debug.FullPanic(restoreAndPanic);

pub fn main(init: std.process.Init) !void {
    std.posix.sigaction(.TERM, &.{
        .handler = .{ .handler = restoreAndTerminate },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESETHAND,
    }, null);
    const gpa = init.gpa;
    const io = init.io;
    const home = init.environ_map.get("HOME") orelse return error.NoHomeDir;
    const cwd_source = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_source);
    const cwd = try std.Io.Dir.realPathFileAbsoluteAlloc(io, cwd_source, gpa);
    defer gpa.free(cwd);
    try validateWorkingDirectory(gpa, cwd);

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed = command_line.parse(arguments[@min(1, arguments.len)..]);
    const directories: accounts.json_store.Directories = .{
        .working_directory = cwd,
        .home = home,
    };
    if (parsed == .terminal) return runTerminal(&init, &directories);

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
        .terminal => unreachable,
        .models => try headless.models(gpa, io, &options),
        .run => |run| run: {
            var stdin_buffer: [4096]u8 = undefined;
            var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
            const prompt = try stdin.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(prompt);
            break :run try headless.run(gpa, io, &options, &.{ .run = run, .prompt = prompt });
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

fn runTerminal(
    init: *const std.process.Init,
    directories: *const accounts.json_store.Directories,
) !void {
    var tty: terminal.Tty = undefined;
    try tty.init(init.io);
    defer tty.deinit();
    var app: App = undefined;
    try app.init(init.gpa, init.io, &.{
        .working_directory = directories.working_directory,
        .home = directories.home,
        .device = tty.device(),
        .environment = init.environ_map,
        .environ = init.minimal.environ,
        .herdr = Herdr.fromEnviron(init.environ_map),
    });
    defer app.deinit();
    try app.run();
}

fn validateWorkingDirectory(gpa: std.mem.Allocator, path: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(path)) return;
    const safe_path = try escape.diagnostic(gpa, path);
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
