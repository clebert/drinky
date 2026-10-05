const std = @import("std");

const terminal = @import("terminal");

const App = @import("App.zig");
const escape = @import("escape.zig");
const Herdr = @import("Herdr.zig");

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

    var tty: terminal.Tty = undefined;
    try tty.init(io);
    defer tty.deinit();
    var app: App = undefined;
    try app.init(gpa, io, &.{
        .working_directory = cwd,
        .home = home,
        .writer = tty.writer(),
        .environment = init.environ_map,
        .environ = init.minimal.environ,
        .herdr = Herdr.fromEnviron(init.environ_map),
    });
    defer app.deinit();
    try app.run(&tty);
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
