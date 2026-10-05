const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");

const Context = @import("Context.zig");
const format = @import("format.zig");
const output = @import("output.zig");
const parse = @import("parse.zig");
const testing = @import("testing.zig");

const capture_bytes_max = 8 << 20;

const read_buffer_bytes = 64 * 1024;

const child_setup_attempts_max = 64;

const child_error_exit_code = 1;

const ChildErrorInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);

const replacement = "\u{FFFD}";

pub const spec: core.Tool = .{
    .name = "bash",
    .description = "Run a bash command in the working directory and return its combined " ++
        "stdout and stderr. Drinky keeps a bounded tail of the output. The output states a " ++
        "non-zero exit code. A command that times out or writes too much output still returns " ++
        "the tail of its output. Give an optional timeout in seconds. The default comes from " ++
        "the config file. " ++
        "A command runs without a terminal, so an interactive prompt fails. " ++
        "Drinky has no web tool, so a network request also runs through this tool. " ++
        "Use the find and grep tools for normal file discovery and literal content searches. " ++
        "They skip noise directories and save time. Use this tool when they cannot express " ++
        "the search. Keep a recursive search narrow.",
    .parameters = &.{
        .{
            .name = "command",
            .type = .string,
            .required = true,
            .description = "The bash command line to run",
        },
        .{
            .name = "timeout_seconds",
            .type = .integer,
            .description = std.fmt.comptimePrint(
                "Seconds before Drinky stops the command (default: the configured limit). " ++
                    "Drinky holds the value from {d} to {d}.",
                .{
                    @divExact(Context.Bash.timeout_ms_min, std.time.ms_per_s),
                    @divExact(Context.Bash.timeout_ms_max, std.time.ms_per_s),
                },
            ),
        },
    },
    .mutates = true,
};

const Input = struct {
    command: []const u8,
    timeout_seconds: ?u64 = null,
};

comptime {
    parse.check(Input, spec.parameters);
}

const ChildSetup = struct {
    in_handle: std.posix.fd_t,
    out_handle: std.posix.fd_t,
    error_handle: std.posix.fd_t,
    argv: [*:null]const ?[*:0]const u8,
    environ: [*:null]const ?[*:0]const u8,
    path: []const u8,
};

const Duplication = struct { source: std.posix.fd_t, target: std.posix.fd_t };

const Stop = union(enum) {
    completed: std.process.Child.Term,
    timed_out: u64,
    oversized,
};

pub fn run(context: *const Context, input_json: []const u8) Context.Error!core.Tool.Output {
    const parsed = try parse.input(Input, context.gpa, input_json);
    defer parsed.deinit();
    return runWithTimeout(context, parsed.value.command, timeoutMs(&.{
        .timeout_seconds = parsed.value.timeout_seconds,
        .timeout_ms_configured = context.host.bash.timeout_ms,
    }));
}

pub fn timeoutMs(source: *const struct {
    timeout_seconds: ?u64,
    timeout_ms_configured: u64,
}) u64 {
    const timeout_ms = if (source.timeout_seconds) |seconds|
        seconds *| std.time.ms_per_s
    else
        source.timeout_ms_configured;
    return std.math.clamp(timeout_ms, Context.Bash.timeout_ms_min, Context.Bash.timeout_ms_max);
}

fn runWithTimeout(
    context: *const Context,
    command: []const u8,
    timeout_ms: u64,
) !core.Tool.Output {
    const gpa = context.gpa;
    const io = context.host.io;
    const limits = &context.host.bash;
    const started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var captured: std.Io.Writer.Allocating = .init(gpa);
    defer captured.deinit();
    const collected =
        core.timeout.run(io, timeout_ms, collect, .{ context, command, &captured }, null);
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started_ms;
    const stop: Stop = if (collected) |term| .{ .completed = term } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Timeout => .{ .timed_out = timeout_ms },
        error.StreamTooLong => .oversized,
        else => return output.failure(
            gpa,
            .failed,
            "Drinky could not run the command because of error {s}.",
            .{@errorName(err)},
        ),
    };
    const text = try sanitize(gpa, captured.written());
    defer gpa.free(text);
    return render(gpa, text, limits, stop, elapsed_ms);
}

fn collect(
    context: *const Context,
    command: []const u8,
    captured: *std.Io.Writer.Allocating,
) !std.process.Child.Term {
    const io = context.host.io;
    const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const output_files = [2]std.Io.File{
        .{ .handle = handles[0], .flags = .{ .nonblocking = false } },
        .{ .handle = handles[1], .flags = .{ .nonblocking = false } },
    };
    var pipe_owned = true;
    defer if (pipe_owned) std.Io.File.closeMany(io, &output_files);

    var child = try spawnCommand(context, command, output_files[1]);
    const process_group = child.id.?;
    errdefer stopAndReap(&child, io, process_group);

    output_files[1].close(io);
    defer output_files[0].close(io);
    pipe_owned = false;

    var read_buffer: [read_buffer_bytes]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(output_files[0], io, &read_buffer);
    while (captured.written().len <= capture_bytes_max) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return child.wait(io),
            error.ReadFailed => return reader.err orelse error.ReadFailed,
        };
        try captured.writer.writeAll(chunk);
        reader.interface.toss(chunk.len);
    }
    return error.StreamTooLong;
}

fn spawnCommand(
    context: *const Context,
    command: []const u8,
    output_file: std.Io.File,
) !std.process.Child {
    const io = context.host.io;
    var dev_null = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
    defer dev_null.close(io);
    const command_z = try context.gpa.dupeZ(u8, command);
    defer context.gpa.free(command_z);
    const argv = [_:null]?[*:0]const u8{ "bash", "-c", command_z.ptr };
    const path = context.host.environ.getPosix("PATH") orelse std.Io.Threaded.default_PATH;

    const error_handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const error_files = [2]std.Io.File{
        .{ .handle = error_handles[0], .flags = .{ .nonblocking = false } },
        .{ .handle = error_handles[1], .flags = .{ .nonblocking = false } },
    };
    var error_files_owned = true;
    defer if (error_files_owned) std.Io.File.closeMany(io, &error_files);

    const setup: ChildSetup = .{
        .in_handle = dev_null.handle,
        .out_handle = output_file.handle,
        .error_handle = error_files[1].handle,
        .argv = &argv,
        .environ = context.host.environ.block.slice.ptr,
        .path = path,
    };

    const fork_result = std.posix.system.fork();
    switch (std.posix.errno(fork_result)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        .NOSYS => return error.OperationUnsupported,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    const process_id: std.posix.pid_t = @intCast(fork_result);
    if (process_id == 0) runCommandChild(&setup);

    error_files[1].close(io);
    defer error_files[0].close(io);
    error_files_owned = false;
    const maybe_child_error = readCommandChildError(io, error_files[0]) catch |err| {
        killAndReapCommandChild(process_id);
        return err;
    };
    if (maybe_child_error) |child_error| {
        reapCommandChild(process_id);
        return child_error;
    }

    return .{
        .id = process_id,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
}

fn runCommandChild(setup: *const ChildSetup) noreturn {
    const duplications = [_]Duplication{
        .{ .source = setup.in_handle, .target = std.posix.STDIN_FILENO },
        .{ .source = setup.out_handle, .target = std.posix.STDOUT_FILENO },
        .{ .source = setup.out_handle, .target = std.posix.STDERR_FILENO },
    };
    for (duplications) |handles| duplicateCommandHandle(handles) catch |err|
        failCommandChild(setup.error_handle, err);
    createCommandSession() catch |err| failCommandChild(setup.error_handle, err);
    failCommandChild(setup.error_handle, execCommand(setup));
}

fn duplicateCommandHandle(handles: Duplication) !void {
    for (0..child_setup_attempts_max) |_| switch (std.posix.errno(
        std.posix.system.dup2(handles.source, handles.target),
    )) {
        .SUCCESS => return,
        .BUSY, .INTR => continue,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    };
    return error.SystemResources;
}

fn createCommandSession() !void {
    switch (std.posix.errno(std.posix.system.setsid())) {
        .SUCCESS => {},
        .PERM => return error.PermissionDenied,
        else => return error.Unexpected,
    }
}

fn execCommand(setup: *const ChildSetup) std.process.SpawnError {
    const name = std.mem.span(setup.argv[0].?);
    var path_buffer: [std.posix.PATH_MAX]u8 = undefined;
    var search = std.mem.tokenizeScalar(u8, setup.path, ':');
    var access_denied = false;
    while (search.next()) |directory| {
        const path_len = directory.len + name.len + 1;
        if (path_buffer.len < path_len + 1) return error.NameTooLong;
        @memcpy(path_buffer[0..directory.len], directory);
        path_buffer[directory.len] = '/';
        @memcpy(path_buffer[directory.len + 1 ..][0..name.len], name);
        path_buffer[path_len] = 0;
        const executable_path = path_buffer[0..path_len :0];
        const exec_error = commandExecError(std.posix.errno(std.posix.system.execve(
            executable_path,
            setup.argv,
            setup.environ,
        )));
        switch (exec_error) {
            error.AccessDenied => access_denied = true,
            error.FileNotFound, error.NotDir => {},
            else => return exec_error,
        }
    }
    if (access_denied) return error.AccessDenied;
    return error.FileNotFound;
}

fn commandExecError(err: std.posix.E) std.process.SpawnError {
    return switch (err) {
        .@"2BIG", .NOMEM => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NFILE => error.SystemFdQuotaExceeded,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .INVAL, .NOEXEC => error.InvalidExe,
        .IO, .LOOP => error.FileSystem,
        .ISDIR => error.IsDir,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .TXTBSY => error.FileBusy,
        else => switch (builtin.os.tag) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => switch (err) {
                .BADEXEC, .BADARCH => error.InvalidExe,
                else => error.Unexpected,
            },
            .linux => switch (err) {
                .LIBBAD => error.InvalidExe,
                else => error.Unexpected,
            },
            else => error.Unexpected,
        },
    };
}

fn failCommandChild(error_handle: std.posix.fd_t, child_error: std.process.SpawnError) noreturn {
    var buffer: [@sizeOf(ChildErrorInt)]u8 = undefined;
    std.mem.writeInt(ChildErrorInt, &buffer, @intFromError(child_error), .little);
    var offset: usize = 0;
    for (0..child_setup_attempts_max) |_| {
        const write_result = std.posix.system.write(
            error_handle,
            buffer[offset..].ptr,
            buffer.len - offset,
        );
        switch (std.posix.errno(write_result)) {
            .SUCCESS => {
                const count: usize = @intCast(write_result);
                offset += count;
                if (offset == buffer.len) break;
            },
            .INTR => continue,
            else => break,
        }
    }
    exitCommandChild(child_error_exit_code);
}

fn readCommandChildError(io: std.Io, error_file: std.Io.File) !?std.process.SpawnError {
    var buffer: [@sizeOf(ChildErrorInt)]u8 = undefined;
    var offset: usize = 0;
    for (0..child_setup_attempts_max) |_| {
        const count = error_file.readStreaming(io, &.{buffer[offset..]}) catch |err| switch (err) {
            error.EndOfStream => return if (offset == 0) null else error.Unexpected,
            else => |read_error| return read_error,
        };
        offset += count;
        if (offset == buffer.len) {
            const child_error: std.process.SpawnError = @errorCast(@errorFromInt(
                std.mem.readInt(ChildErrorInt, &buffer, .little),
            ));
            return @as(?std.process.SpawnError, child_error);
        }
    }
    return error.SystemResources;
}

fn reapCommandChild(process_id: std.posix.pid_t) void {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    for (0..child_setup_attempts_max) |_| switch (std.posix.errno(
        std.posix.system.waitpid(process_id, &status, 0),
    )) {
        .INTR => continue,
        else => return,
    };
}

fn killAndReapCommandChild(process_id: std.posix.pid_t) void {
    _ = std.posix.system.kill(-process_id, .KILL);
    _ = std.posix.system.kill(process_id, .KILL);
    reapCommandChild(process_id);
}

fn exitCommandChild(code: u8) noreturn {
    if (comptime builtin.link_libc) {
        std.c._exit(code);
    } else if (comptime builtin.os.tag == .linux) {
        std.os.linux.exit_group(code);
    } else {
        @compileError("The command child exit path needs a POSIX implementation.");
    }
}

fn stopAndReap(
    child: *std.process.Child,
    io: std.Io,
    process_group: std.posix.pid_t,
) void {
    std.posix.kill(-process_group, .KILL) catch {};
    if (child.id == null) child.id = process_group;
    child.kill(io);
}

fn sanitize(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var output_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer output_writer.deinit();
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte == '\n' or byte == '\t') {
            try output_writer.writer.writeByte(byte);
            index += 1;
        } else if (byte == 0x1b) {
            index = controlSequenceEnd(input, index) orelse index + 1;
        } else if (byte < 0x20 or byte == 0x7f) {
            index += 1;
        } else if (byte < 0x80) {
            try output_writer.writer.writeByte(byte);
            index += 1;
        } else if (decodeAt(input, index)) |length| {
            try output_writer.writer.writeAll(input[index .. index + length]);
            index += length;
        } else {
            try output_writer.writer.writeAll(replacement);
            index += 1;
        }
    }
    return output_writer.toOwnedSlice();
}

fn controlSequenceEnd(input: []const u8, start: usize) ?usize {
    std.debug.assert(start < input.len and input[start] == 0x1b);
    if (input.len - start < 3 or input[start + 1] != '[') return null;

    var index = start + 2;
    while (index < input.len and input[index] >= 0x30 and input[index] <= 0x3f) {
        index += 1;
    }
    while (index < input.len and input[index] >= 0x20 and input[index] <= 0x2f) {
        index += 1;
    }
    if (index < input.len and input[index] >= 0x40 and input[index] <= 0x7e) {
        return index + 1;
    }
    return null;
}

fn decodeAt(bytes: []const u8, index: usize) ?usize {
    const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return null;
    if (index + length > bytes.len) return null;
    const sequence = bytes[index .. index + length];
    _ = std.unicode.utf8Decode(sequence) catch return null;
    return length;
}

fn render(
    gpa: std.mem.Allocator,
    text: []const u8,
    limits: *const Context.Bash,
    stop: Stop,
    elapsed_ms: i64,
) !core.Tool.Output {
    const failed = switch (stop) {
        .completed => |term| switch (term) {
            .exited => |code| code != 0,
            else => true,
        },
        .timed_out, .oversized => true,
    };
    const start = tailStart(text, limits);
    const window = text[start..];

    var result_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer result_writer.deinit();
    if (start > 0) {
        if (text[start - 1] == '\n') {
            try result_writer.writer.print(
                "[Drinky omitted earlier output. Drinky shows the last {d} of {d} lines.]\n",
                .{ format.lines(window), format.lines(text) },
            );
        } else {
            try result_writer.writer.print(
                "[Drinky omitted earlier output. Drinky shows the last {d} byte{s}.]\n",
                .{ window.len, core.text.pluralSuffix(window.len) },
            );
        }
    }
    try result_writer.writer.writeAll(window);
    if (window.len == 0 and start == 0 and !failed)
        try result_writer.writer.writeAll("(No output)");
    if (failed) {
        if (result_writer.writer.buffered().len > 0) try result_writer.writer.writeAll("\n\n");
        switch (stop) {
            .completed => |term| switch (term) {
                .exited => |code| try result_writer.writer.print(
                    "[The command exited with code {d}.]",
                    .{code},
                ),
                else => try result_writer.writer.writeAll(
                    "[The command stopped before it completed.]",
                ),
            },
            .timed_out => |timeout_ms| {
                var limit_buffer: [24]u8 = undefined;
                try result_writer.writer.print("[The command timed out after {s}.]", .{
                    format.duration(&limit_buffer, @intCast(timeout_ms)),
                });
            },
            .oversized => try result_writer.writer.print(
                "[The command produced more than {d} MiB of output, so Drinky stopped it.]",
                .{capture_bytes_max >> 20},
            ),
        }
    }
    var result: core.Tool.Output = .{ .content = try result_writer.toOwnedSlice() };
    result.measures.put(.duration_ms, @intCast(@max(elapsed_ms, 0)));
    switch (stop) {
        .completed => |term| switch (term) {
            .exited => |code| {
                result.measures.put(.exit_code, code);
                if (code != 0) result.conditions.insert(.failed);
            },
            else => result.conditions.insert(.terminated),
        },
        .timed_out => result.conditions.insert(.timed_out),
        .oversized => result.conditions.insert(.overflowed),
    }
    const lines = format.lines(text);
    if (lines > 0) result.measures.put(.lines, lines);
    if (start > 0) result.conditions.insert(.output_truncated);
    return result;
}

fn tailStart(text: []const u8, limits: *const Context.Bash) usize {
    if (text.len == 0) return 0;
    if (limits.lines_max == 0 or limits.bytes_max == 0) return text.len;

    var start = text.len -| limits.bytes_max;
    while (start < text.len and text[start] & 0xC0 == 0x80) start += 1;
    if (start > 0 and text[start - 1] != '\n') {
        if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| {
            if (newline + 1 < text.len) start = newline + 1;
        }
    }

    var scan = text.len;
    if (text[scan - 1] == '\n') scan -= 1;
    var kept: usize = 0;
    while (scan > start) {
        const newline = std.mem.lastIndexOfScalar(u8, text[0..scan], '\n') orelse break;
        kept += 1;
        if (kept >= limits.lines_max) {
            if (newline + 1 > start) start = newline + 1;
            break;
        }
        scan = newline;
    }
    return start;
}

test "bash runs a command and returns its output" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"command":"echo hello"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("hello\n", result.content);
}

test "bash preserves stdout and stderr order" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"command":"printf out1; printf err1 >&2; printf out2; printf err2 >&2"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("out1err1out2err2", result.content);
}

test "bash starts a command in a separate session" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"command":"case $(ps -o stat= -p $$) in *s*) exit 0;; *) exit 1;; esac"}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("(No output)", result.content);
    try std.testing.expect(!result.hasFailure());
}

test "bash hands the environment of its host to the command" {
    const gpa = std.testing.allocator;
    const entries = [_:null]?[*:0]const u8{
        "PATH=/usr/local/bin:/bin:/usr/bin",
        "DRINKY_BASH_TEST=inherited",
    };
    const context: Context = .{
        .gpa = gpa,
        .host = .{ .io = std.testing.io, .environ = .{ .block = .{ .slice = &entries } } },
    };
    const result = try run(&context,
        \\{"command":"printf %s \"$DRINKY_BASH_TEST\""}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("inherited", result.content);
}

test "bash skips a directory with the executable name in PATH" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "bash", .default_dir);
    const path_entry = try std.fmt.allocPrintSentinel(
        gpa,
        "PATH=.zig-cache/tmp/{s}:/bin:/usr/bin",
        .{tmp.sub_path},
        0,
    );
    defer gpa.free(path_entry);
    const entries = [_:null]?[*:0]const u8{path_entry.ptr};
    const context: Context = .{
        .gpa = gpa,
        .host = .{ .io = io, .environ = .{ .block = .{ .slice = &entries } } },
    };
    const result = try run(&context,
        \\{"command":"printf ok"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("ok", result.content);
}

test "bash reports an executable search failure as a tool error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "bash", .default_dir);
    const path_entry = try std.fmt.allocPrintSentinel(
        gpa,
        "PATH=.zig-cache/tmp/{s}",
        .{tmp.sub_path},
        0,
    );
    defer gpa.free(path_entry);
    const entries = [_:null]?[*:0]const u8{path_entry.ptr};
    const context: Context = .{
        .gpa = gpa,
        .host = .{ .io = io, .environ = .{ .block = .{ .slice = &entries } } },
    };
    const result = try run(&context,
        \\{"command":"printf unreachable"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.hasFailure());
    try std.testing.expect(std.mem.indexOf(u8, result.content, "error AccessDenied") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "exit code") == null);
}

test "bash reports a non-zero exit as an error" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"command":"echo boom; exit 3"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.hasFailure());
    try std.testing.expect(std.mem.indexOf(u8, result.content, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "code 3") != null);
    try testing.expectTimed(&result, &.{ .{ .exit_code, 3 }, .{ .lines, 1 } });
    try testing.expectConditions(&result, &.{.failed});
}

test "a command reads its standard input from an empty source" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"command":"cat"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("(No output)", result.content);
}

test "bash reports empty successful output" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"command":"true"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expectEqualStrings("(No output)", result.content);
    try testing.expectTimed(&result, &.{.{ .exit_code, 0 }});
    try testing.expectConditions(&result, &.{});
}

test "bash rejects invalid input" {
    const context: Context = .{ .gpa = std.testing.allocator, .host = .{ .io = std.testing.io } };
    try std.testing.expectError(error.InvalidArguments, run(&context, "{}"));
}

test "the timeout of a call comes from either source and takes the clamp" {
    const minimum = Context.Bash.timeout_ms_min;
    const maximum = Context.Bash.timeout_ms_max;
    const cases = [_]struct { timeout_seconds: ?u64, timeout_ms_configured: u64, expected: u64 }{
        .{ .timeout_seconds = 2, .timeout_ms_configured = 5_000, .expected = 2_000 },
        .{ .timeout_seconds = null, .timeout_ms_configured = 5_000, .expected = 5_000 },
        .{ .timeout_seconds = 0, .timeout_ms_configured = 5_000, .expected = minimum },
        .{ .timeout_seconds = null, .timeout_ms_configured = 0, .expected = minimum },
        .{
            .timeout_seconds = std.math.maxInt(u64),
            .timeout_ms_configured = 5_000,
            .expected = maximum,
        },
        .{
            .timeout_seconds = null,
            .timeout_ms_configured = std.math.maxInt(u64),
            .expected = maximum,
        },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, timeoutMs(&.{
        .timeout_seconds = case.timeout_seconds,
        .timeout_ms_configured = case.timeout_ms_configured,
    }));
}

test "sanitize keeps text, drops controls, and replaces invalid bytes" {
    const gpa = std.testing.allocator;
    const input = [_]u8{ 'a', '\t', 'b', '\r', '\n', 0x1b, 0xff, '!' };
    const clean = try sanitize(gpa, &input);
    defer gpa.free(clean);
    try std.testing.expectEqualStrings("a\tb\n" ++ replacement ++ "!", clean);
}

test "sanitize strips complete terminal control sequences" {
    const gpa = std.testing.allocator;
    const input = "\x1b[1mBACKLOG.md:1:1: \x1b[31merror:\x1b[0m " ++
        "\x1b[?25lhidden cursor\x1b[2 q";
    const clean = try sanitize(gpa, input);
    defer gpa.free(clean);
    try std.testing.expectEqualStrings("BACKLOG.md:1:1: error: hidden cursor", clean);
}

test "sanitize preserves malformed terminal control sequence tails" {
    const gpa = std.testing.allocator;
    const clean = try sanitize(gpa, "\x1b[ 3m\n\x1b[31");
    defer gpa.free(clean);
    try std.testing.expectEqualStrings("[ 3m\n[31", clean);
}

test "render measures the whole output and marks a cut tail" {
    const gpa = std.testing.allocator;
    {
        const limits: Context.Bash = .{ .lines_max = 2 };
        const result =
            try render(gpa, "a\nb\nc\n", &limits, .{ .completed = .{ .exited = 0 } }, 1_500);
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(?u64, 1_500), result.measures.get(.duration_ms));
        try testing.expectMeasures(&result, &.{ .{ .exit_code, 0 }, .{ .lines, 3 } });
        try testing.expectConditions(&result, &.{.output_truncated});
    }
    {
        const limits: Context.Bash = .{ .lines_max = 1000, .bytes_max = 4 };
        const result =
            try render(gpa, "abcdef\n", &limits, .{ .completed = .{ .exited = 0 } }, 0);
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(?u64, 0), result.measures.get(.duration_ms));
        try testing.expectMeasures(&result, &.{ .{ .exit_code, 0 }, .{ .lines, 1 } });
        try testing.expectConditions(&result, &.{.output_truncated});
    }
    {
        const limits: Context.Bash = .{};
        const result = try render(gpa, "", &limits, .{ .completed = .{ .signal = .KILL } }, 10);
        defer result.deinit(gpa);
        try std.testing.expectEqualStrings(
            "[The command stopped before it completed.]",
            result.content,
        );
        try std.testing.expectEqual(@as(?u64, 10), result.measures.get(.duration_ms));
        try testing.expectMeasures(&result, &.{});
        try testing.expectConditions(&result, &.{.terminated});
    }
}

const test_timeout_ms = 200;

const OutputClock = struct {
    threaded: std.Io.Threaded,
    backend: *const std.Io.VTable,
    vtable: std.Io.VTable,
    marker: []const u8,
    fire_at: FireAt,
    seen: [seen_bytes_max]u8,
    seen_len: usize,
    marker_handle: ?std.posix.fd_t,
    fired: std.Io.Event,
    sleeps: [sleeps_max]u64,
    sleep_count: usize,

    const seen_bytes_max = 256;
    const sleeps_max = 4;

    const FireAt = enum { marker, end_after_marker };

    fn init(
        self: *OutputClock,
        gpa: std.mem.Allocator,
        options: *const struct { marker: []const u8, fire_at: FireAt = .marker },
    ) void {
        self.threaded = .init(gpa, .{});
        self.backend = self.threaded.io().vtable;
        self.vtable = self.backend.*;
        self.vtable.sleep = sleep;
        self.vtable.operate = operate;
        self.marker = options.marker;
        self.fire_at = options.fire_at;
        self.seen_len = 0;
        self.marker_handle = null;
        self.fired = .unset;
        self.sleep_count = 0;
    }

    fn deinit(self: *OutputClock) void {
        self.threaded.deinit();
    }

    fn io(self: *OutputClock) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    fn slept(self: *const OutputClock) []const u64 {
        return self.sleeps[0..@min(self.sleep_count, sleeps_max)];
    }

    fn of(userdata: ?*anyopaque) *OutputClock {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        return @fieldParentPtr("threaded", threaded);
    }

    fn backendIo(self: *OutputClock) std.Io {
        return .{ .userdata = &self.threaded, .vtable = self.backend };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self = of(userdata);
        const milliseconds: u64 = switch (timeout) {
            .duration => |duration| @intCast(duration.raw.toMilliseconds()),
            .none, .deadline => 0,
        };
        if (self.sleep_count < sleeps_max) self.sleeps[self.sleep_count] = milliseconds;
        self.sleep_count += 1;
        return self.fired.wait(self.backendIo());
    }

    fn operate(
        userdata: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        const self = of(userdata);
        const result = try self.backend.operate(userdata, operation);
        if (operation == .file_read_streaming) {
            self.watch(&operation.file_read_streaming, result.file_read_streaming);
        }
        return result;
    }

    fn watch(
        self: *OutputClock,
        read: *const std.Io.Operation.FileReadStreaming,
        result: std.Io.Operation.FileReadStreaming.Result,
    ) void {
        const count = result catch |err| {
            const at_end = err == error.EndOfStream and self.fire_at == .end_after_marker;
            if (at_end and self.marker_handle == read.file.handle) self.fired.set(self.backendIo());
            return;
        };
        var remaining = count;
        for (read.data) |chunk| {
            const taken = @min(chunk.len, remaining, seen_bytes_max - self.seen_len);
            @memcpy(self.seen[self.seen_len..][0..taken], chunk[0..taken]);
            self.seen_len += taken;
            remaining -= @min(chunk.len, remaining);
        }
        if (self.marker_handle != null) return;
        if (std.mem.indexOf(u8, self.seen[0..self.seen_len], self.marker) == null) return;
        self.marker_handle = read.file.handle;
        if (self.fire_at == .marker) self.fired.set(self.backendIo());
    }
};

test "a timed-out command keeps its output and states the stop" {
    const gpa = std.testing.allocator;
    var clock: OutputClock = undefined;
    clock.init(gpa, &.{ .marker = "started\n" });
    defer clock.deinit();
    const context: Context = .{ .gpa = gpa, .host = .{ .io = clock.io() } };
    const result = try runWithTimeout(&context, "echo started; sleep 5", test_timeout_ms);
    defer result.deinit(gpa);
    try std.testing.expect(result.hasFailure());
    try std.testing.expectEqualStrings(
        "started\n\n\n[The command timed out after 200ms.]",
        result.content,
    );
    try testing.expectTimed(&result, &.{.{ .lines, 1 }});
    try testing.expectConditions(&result, &.{.timed_out});
    try std.testing.expectEqualSlices(u64, &.{test_timeout_ms}, clock.slept());
}

test "bash timeout is absolute while output arrives" {
    const gpa = std.testing.allocator;
    var clock: OutputClock = undefined;
    clock.init(gpa, &.{ .marker = "tick\n" });
    defer clock.deinit();
    const context: Context = .{ .gpa = gpa, .host = .{ .io = clock.io() } };
    const result = try runWithTimeout(
        &context,
        "while true; do echo tick; sleep 0.01; done",
        test_timeout_ms,
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.hasFailure());
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 200ms") != null);
    try std.testing.expectEqualSlices(u64, &.{test_timeout_ms}, clock.slept());
}

test "bash timeout reaps a command after output closes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const command = try std.fmt.allocPrint(
        gpa,
        "echo $$ > .zig-cache/tmp/{s}/pid; echo closing; exec 1>&- 2>&-; sleep 5",
        .{tmp.sub_path},
    );
    defer gpa.free(command);
    var clock: OutputClock = undefined;
    clock.init(gpa, &.{ .marker = "closing\n", .fire_at = .end_after_marker });
    defer clock.deinit();
    const context: Context = .{ .gpa = gpa, .host = .{ .io = clock.io() } };
    const result = try runWithTimeout(&context, command, test_timeout_ms);
    defer result.deinit(gpa);
    try std.testing.expect(result.hasFailure());
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 200ms") != null);

    const process_id = try readProcessId(gpa, std.testing.io, &tmp);
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const wait_result = std.posix.system.waitpid(process_id, &status, std.posix.W.NOHANG);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(wait_result));
}

test "bash timeout kills descendant processes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const command = try std.fmt.allocPrint(
        gpa,
        "sleep 5 & echo $! > .zig-cache/tmp/{s}/pid; echo started; wait",
        .{tmp.sub_path},
    );
    defer gpa.free(command);
    var clock: OutputClock = undefined;
    clock.init(gpa, &.{ .marker = "started\n" });
    defer clock.deinit();
    const context: Context = .{ .gpa = gpa, .host = .{ .io = clock.io() } };
    const result = try runWithTimeout(&context, command, test_timeout_ms);
    defer result.deinit(gpa);
    try std.testing.expect(result.hasFailure());

    const process_id = try readProcessId(gpa, io, &tmp);
    var gone = false;
    for (0..200) |_| {
        std.posix.kill(process_id, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => {
                gone = true;
                break;
            },
            else => return err,
        };
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(gone);
}

fn readProcessId(gpa: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) !std.posix.pid_t {
    const text = try tmp.dir.readFileAlloc(io, "pid", gpa, .limited(64));
    defer gpa.free(text);
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trimEnd(u8, text, "\n"), 10);
}

test "an oversized command keeps its output tail and states the stop" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var command_buffer: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(
        &command_buffer,
        "{{\"command\":\"echo marker; yes x | head -c {d}\"}}",
        .{capture_bytes_max + (1 << 20)},
    );
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.hasFailure());
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.content,
        "[The command produced more than 8 MiB of output, so Drinky stopped it.]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Drinky omitted") != null);
    try std.testing.expect(result.measures.get(.duration_ms) != null);
    try std.testing.expect(result.measures.get(.lines) != null);
    try std.testing.expectEqual(@as(?u64, null), result.measures.get(.exit_code));
    try testing.expectConditions(&result, &.{ .overflowed, .output_truncated });
}

test "tailStart keeps the last lines within the line budget" {
    const text = "a\nb\nc\nd\n";
    const two_lines: Context.Bash = .{ .lines_max = 2 };
    const ten_lines: Context.Bash = .{ .lines_max = 10 };
    try std.testing.expectEqual(@as(usize, 4), tailStart(text, &two_lines));
    try std.testing.expectEqual(@as(usize, 0), tailStart(text, &ten_lines));
    try std.testing.expectEqualStrings("c\nd\n", text[tailStart(text, &two_lines)..]);
}

test "tailStart keeps the last lines within the byte budget" {
    const text = "aaaa\nbbbb\ncccc\n";
    const limits: Context.Bash = .{ .lines_max = 1000, .bytes_max = 6 };
    try std.testing.expectEqualStrings("cccc\n", text[tailStart(text, &limits)..]);
}

test "tailStart preserves a trailing line that exactly fits" {
    const text = "aaaa\nbbbb\ncccc\n";
    const limits: Context.Bash = .{ .lines_max = 1000, .bytes_max = 5 };
    try std.testing.expectEqualStrings("cccc\n", text[tailStart(text, &limits)..]);
}

test "tailStart cuts a newline-terminated oversized line" {
    const text = "abcdef\n";
    const limits: Context.Bash = .{ .lines_max = 1000, .bytes_max = 4 };
    try std.testing.expectEqualStrings("def\n", text[tailStart(text, &limits)..]);
}

test "tailStart cuts a lone oversized line on a codepoint boundary" {
    const text = "\u{00e9}\u{00e9}\u{00e9}\u{00e9}";
    const limits: Context.Bash = .{ .lines_max = 1000, .bytes_max = 3 };
    const start = tailStart(text, &limits);
    try std.testing.expect(start % 2 == 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text[start..]));
}

test "tailStart honors zero output limits" {
    const text = "a\nb\n";
    const no_lines: Context.Bash = .{ .lines_max = 0 };
    const no_bytes: Context.Bash = .{ .bytes_max = 0 };
    try std.testing.expectEqual(text.len, tailStart(text, &no_lines));
    try std.testing.expectEqual(text.len, tailStart(text, &no_bytes));
}
