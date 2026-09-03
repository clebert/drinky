//! Runs a shell command in the working directory and returns its combined
//! stdout and stderr, bounded to a tail window and a wall-clock timeout.
//! Sanitizes the output to valid UTF-8 so it can serialize as a JSON tool result.

const std = @import("std");
const builtin = @import("builtin");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const parse = @import("parse.zig");

/// The hard cap on captured output. Beyond this, Drinky stops the command and
/// does not buffer without bound. The configured window keeps only the tail
/// below it.
const capture_bytes_max = 8 << 20;

/// The transfer buffer of one pipe read. One read takes up to this many bytes,
/// so the size bounds the syscall count and the copy count of a loud command
/// to a handful per megabyte.
const read_buffer_bytes = 64 * 1024;

/// A child setup step retries an interrupted or partial system call up to this count.
const child_setup_attempts_max = 64;

/// The child exits with this code after it sends a typed setup error to the parent.
const child_error_exit_code = 1;

/// The error pipe carries one child setup error as this integer.
const ChildErrorInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);

/// The UTF-8 replacement character, substituted for malformed input bytes.
const replacement = "\u{FFFD}";

pub const spec: llm.Tool = .{
    .name = "bash",
    .description = "Run a bash command in the working directory and return its combined " ++
        "stdout and stderr. Output is truncated to a bounded tail, and a non-zero exit is " ++
        "reported. A timed-out or oversized command still returns the tail of its output. " ++
        "Give an optional timeout in seconds; the default comes from configuration. " ++
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
        // Every command runs under a limit, so the bounds belong in the
        // description: they are what a caller needs to pick a value.
        .{
            .name = "timeout_seconds",
            .type = .integer,
            .description = std.fmt.comptimePrint(
                "Seconds before the command is killed (default: configured limit). " ++
                    "Drinky holds the value from {d} to {d}.",
                .{
                    Context.Bash.timeout_ms_min / std.time.ms_per_s,
                    Context.Bash.timeout_ms_max / std.time.ms_per_s,
                },
            ),
        },
    },
};

const Input = struct {
    command: []const u8,
    timeout_seconds: ?u64 = null,
};

/// The caller-owned state of one command run. The run races the timeout, and a
/// timeout cancels the collecting task. The output streams into this state as
/// it arrives, so a killed command still hands over the tail it printed. The
/// collector writes between io operations, and the race joins it before the
/// caller reads, so no read races a write.
const Execution = struct {
    output: std.Io.Writer.Allocating,
    term: ?std.process.Child.Term = null,

    fn deinit(self: *Execution) void {
        self.output.deinit();
    }
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const parsed = try parse.input(Input, context.gpa, input_json);
    defer parsed.deinit();
    return runWithTimeout(context, parsed.value.command, timeoutMs(&parsed.value, &context.bash));
}

/// The window a call runs under: its own `timeout_seconds`, else the configured
/// default. Both sources take the same clamp, so a command always runs under a
/// limit the interface can measure, and neither the model nor the config can
/// lift it.
fn timeoutMs(input: *const Input, limits: *const Context.Bash) u64 {
    return Context.Bash.clampTimeoutMs(if (input.timeout_seconds) |seconds|
        seconds *| std.time.ms_per_s
    else
        limits.timeout_ms);
}

/// Run `command` under `timeout_ms`, which `run` has clamped. A test passes a
/// window below the floor, so a stop costs it no full second.
fn runWithTimeout(context: *const Context, command: []const u8, timeout_ms: u64) !Result {
    const gpa = context.gpa;
    const limits = &context.bash;
    const started_ms = std.Io.Timestamp.now(context.io, .awake).toMilliseconds();
    var execution: Execution = .{ .output = .init(gpa) };
    defer execution.deinit();
    const executed = execute(context, command, timeout_ms, &execution);
    const elapsed_ms = std.Io.Timestamp.now(context.io, .awake).toMilliseconds() - started_ms;
    // Every end state that holds output renders it through one path, so a
    // stopped command reads like one that ran: the tail it printed, the notice
    // that names the stop, and the measures the box shows.
    const stop: Stop = if (executed) |term| .{ .completed = term } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        // A command that ran out of time reports that time the way a command
        // that finished does, because the row above it counted up to this
        // moment and the box must not drop the number the user watched.
        error.Timeout => .{ .timed_out = timeout_ms },
        error.StreamTooLong => .oversized,
        else => return Result.report(
            gpa,
            .err,
            "Drinky could not run the command because of error {s}.",
            .{@errorName(err)},
        ),
    };
    const output = try sanitize(gpa, execution.output.written());
    defer gpa.free(output);
    return render(gpa, output, limits, stop, elapsed_ms);
}

fn execute(
    context: *const Context,
    command: []const u8,
    timeout_ms: u64,
    execution: *Execution,
) !std.process.Child.Term {
    std.debug.assert(timeout_ms <= Context.Bash.timeout_ms_max);

    const work_result = net.race(
        context.io,
        timeout_ms,
        collect,
        .{ context, command, execution },
    ) catch return error.ConcurrencyUnavailable;
    try work_result;
    return execution.term.?;
}

fn collect(context: *const Context, command: []const u8, execution: *Execution) !void {
    const io = context.io;
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
    // `peekGreedy` commits after one arrival, so a cancel or an overflow keeps
    // every byte the pipe delivered before it. The direct routes (`stream`,
    // `sendFile`, `readSliceShort`) fill a fixed destination across reads
    // before they commit, and a cancel mid-fill takes the arrived bytes of
    // that pass with it. The loop ends at end of stream or past the capture
    // cap, so it is bounded.
    while (execution.output.written().len <= capture_bytes_max) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => {
                execution.term = try child.wait(io);
                return;
            },
            error.ReadFailed => return reader.err orelse error.ReadFailed,
        };
        try execution.output.writer.writeAll(chunk);
        reader.interface.toss(chunk.len);
    }
    return error.StreamTooLong;
}

/// Start the shell as a session leader without a controlling terminal. A command cannot open
/// `/dev/tty` or take terminal ownership from Drinky.
///
/// Zig 0.16 exposes no session option in `SpawnOptions`. This POSIX spawn mirrors the standard
/// library steps and adds `setsid`. The error pipe stays, so a child setup failure keeps its type.
/// The child calls raw system wrappers alone, so it needs no cancel guard of its own.
fn spawnCommand(
    context: *const Context,
    command: []const u8,
    output_file: std.Io.File,
) !std.process.Child {
    const io = context.io;
    var dev_null = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
    defer dev_null.close(io);
    const command_z = try context.gpa.dupeZ(u8, command);
    defer context.gpa.free(command_z);
    const argv = [_:null]?[*:0]const u8{ "bash", "-c", command_z.ptr };
    const path = context.environ.getPosix("PATH") orelse std.Io.Threaded.default_PATH;

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
        .environ = context.environ.block.slice.ptr,
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
    // The child holds its own copy of this frame, so the pointer stays valid across the fork.
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

/// Everything the child needs after the fork. A named field prevents a swap of two handles, or
/// of the two string vectors, at the call.
const ChildSetup = struct {
    /// The child reads standard input from this handle.
    in_handle: std.posix.fd_t,
    /// The child writes both standard output and standard error to this handle.
    out_handle: std.posix.fd_t,
    /// The child reports a setup failure on this handle and closes it at a successful exec.
    error_handle: std.posix.fd_t,
    argv: [*:null]const ?[*:0]const u8,
    environ: [*:null]const ?[*:0]const u8,
    /// The directory list that the executable search walks.
    path: []const u8,
};

/// This child path calls only async-signal-safe functions between fork and exec.
fn runCommandChild(setup: *const ChildSetup) noreturn {
    duplicateCommandHandle(setup.in_handle, std.posix.STDIN_FILENO) catch |err|
        failCommandChild(setup.error_handle, err);
    duplicateCommandHandle(setup.out_handle, std.posix.STDOUT_FILENO) catch |err|
        failCommandChild(setup.error_handle, err);
    duplicateCommandHandle(setup.out_handle, std.posix.STDERR_FILENO) catch |err|
        failCommandChild(setup.error_handle, err);
    createCommandSession() catch |err| failCommandChild(setup.error_handle, err);
    failCommandChild(setup.error_handle, execCommand(setup));
}

fn duplicateCommandHandle(old_handle: std.posix.fd_t, new_handle: std.posix.fd_t) !void {
    for (0..child_setup_attempts_max) |_| switch (std.posix.errno(
        std.posix.system.dup2(old_handle, new_handle),
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

/// The setup error that the child sent, or null when the pipe closed at a successful exec.
/// The io interface owns the read, so a canceled turn reaches the parent as `Canceled`.
fn readCommandChildError(io: std.Io, error_file: std.Io.File) !?std.process.SpawnError {
    var buffer: [@sizeOf(ChildErrorInt)]u8 = undefined;
    var offset: usize = 0;
    for (0..child_setup_attempts_max) |_| {
        const count = error_file.readStreaming(io, &.{buffer[offset..]}) catch |err| switch (err) {
            // The write end closes on exec, so a clean end of stream proves the exec.
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

/// Stop a child that never reported its setup. Both signals are needed: the group covers a child
/// that reached `setsid` and started work of its own, and the id covers the window before it.
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
    // A canceled `Child.wait` clears the id but does not reap. Restore the
    // saved group leader so the uncancelable kill path waits for it.
    if (child.id == null) child.id = process_group;
    child.kill(io);
}

/// Rewrite the output into valid UTF-8. Complete CSI terminal control sequences
/// and other control bytes drop. Newlines and tabs pass. Malformed bytes become
/// replacement characters.
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

/// The offset after a complete ESC-[ control sequence, or null when the bytes
/// at `start` are another escape form, malformed, or incomplete.
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

/// The byte length of the valid UTF-8 sequence that starts at `index`, or null
/// when the bytes there are not a complete, valid sequence.
fn decodeAt(bytes: []const u8, index: usize) ?usize {
    const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return null;
    if (index + length > bytes.len) return null;
    const sequence = bytes[index .. index + length];
    _ = std.unicode.utf8Decode(sequence) catch return null;
    return length;
}

/// How one command run ended. Every variant renders through the same path, so
/// a stopped command keeps the measures a finished one reports.
const Stop = union(enum) {
    /// The command ended on its own, with this term.
    completed: std.process.Child.Term,
    /// The wall killed the command at this clamped limit, in milliseconds.
    timed_out: u64,
    /// The capture cap killed the command.
    oversized,
};

/// Build the tool result: a truncation note when the tail was cut, the kept
/// window, and a status line when the command failed.
///
/// Every end state reports the same measures, so a command that exited with a
/// non-zero code, or one that a limit killed, reads as a command that ran, not
/// as a broken tool. The failure flag still reaches the model, and the box
/// still marks it.
fn render(
    gpa: std.mem.Allocator,
    output: []const u8,
    limits: *const Context.Bash,
    stop: Stop,
    /// The wall-clock time the command ran. A long command is the one whose cost
    /// the user weighs, so the box reports it beside the exit status.
    elapsed_ms: i64,
) !Result {
    const failed = switch (stop) {
        .completed => |term| switch (term) {
            .exited => |code| code != 0,
            else => true,
        },
        // A killed command never completed its work, so the flag reaches the
        // model even though the output above it stands.
        .timed_out, .oversized => true,
    };
    const start = tailStart(output, limits);
    const window = output[start..];

    var result_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer result_writer.deinit();
    if (start > 0) {
        if (output[start - 1] == '\n') {
            try result_writer.writer.print(
                "[Drinky omitted earlier output. Drinky shows the last {d} of {d} lines.]\n",
                .{ format.lines(window), format.lines(output) },
            );
        } else {
            try result_writer.writer.print(
                "[Drinky omitted earlier output. Drinky shows the last {d} bytes.]\n",
                .{window.len},
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
            // The notice states the limit to the model, and the summary
            // reports the run time instead.
            .timed_out => |timeout_ms| {
                var limit_buffer: [24]u8 = undefined;
                try result_writer.writer.print("[The command timed out after {s}.]", .{
                    format.duration(&limit_buffer, @intCast(timeout_ms)),
                });
            },
            .oversized => try result_writer.writer.print(
                "[The command produced more than {d} MB of output, so Drinky stopped it.]",
                .{capture_bytes_max >> 20},
            ),
        }
    }
    var summary_output: std.Io.Writer.Allocating = .init(gpa);
    errdefer summary_output.deinit();
    var elapsed_buffer: [24]u8 = undefined;
    // The run time comes first, because the row above counted up to it and a
    // narrow window cuts the tail of this row.
    try summary_output.writer.print("Time: {s}", .{
        format.duration(&elapsed_buffer, elapsed_ms),
    });
    // `code` is the number the command returned. `Status` names a state instead,
    // so a killed command cannot read as one that exited.
    switch (stop) {
        .completed => |term| switch (term) {
            .exited => |code| try summary_output.writer.print(" · Exit code: {d}", .{code}),
            else => try summary_output.writer.writeAll(" · Status: Terminated"),
        },
        .timed_out => try summary_output.writer.writeAll(" · Status: Timed out"),
        .oversized => try summary_output.writer.writeAll(" · Status: Output limit"),
    }
    // The line count names the whole output, not the tail the box keeps. A
    // command that printed nothing reports none, because a zero says less than
    // its absence. A failed command reports the same fields as one that worked.
    const lines = format.lines(output);
    if (lines > 0) try summary_output.writer.print(" · Lines: {d}", .{lines});
    if (start > 0) try summary_output.writer.writeAll(" · Output: Truncated");
    const summary = try summary_output.toOwnedSlice();
    errdefer gpa.free(summary);
    const content = try result_writer.toOwnedSlice();
    return .{ .content = content, .summary = .{ .text = summary }, .is_error = failed };
}

/// The offset of the largest tail within both configured limits. Prefer whole
/// lines. When no whole trailing line fits, retain a UTF-8-safe byte tail.
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
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try run(&context,
        \\{"command":"echo hello"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("hello\n", result.content);
}

test "bash preserves stdout and stderr order" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try run(&context,
        \\{"command":"printf out1; printf err1 >&2; printf out2; printf err2 >&2"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("out1err1out2err2", result.content);
}

test "bash starts a command in a separate session" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try run(&context,
        \\{"command":"case $(ps -o stat= -p $$) in *s*) exit 0;; *) exit 1;; esac"}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("(No output)", result.content);
    try std.testing.expect(!result.is_error);
}

test "bash inherits the process environment" {
    const gpa = std.testing.allocator;
    const entries = [_:null]?[*:0]const u8{
        "PATH=/usr/local/bin:/bin:/usr/bin",
        "DRINKY_BASH_TEST=inherited",
    };
    const context: Context = .{
        .gpa = gpa,
        .io = std.testing.io,
        .environ = .{ .block = .{ .slice = &entries } },
    };
    const result = try run(&context,
        \\{"command":"printf %s \"$DRINKY_BASH_TEST\""}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
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
        .io = io,
        .environ = .{ .block = .{ .slice = &entries } },
    };
    const result = try run(&context,
        \\{"command":"printf ok"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
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
        .io = io,
        .environ = .{ .block = .{ .slice = &entries } },
    };
    const result = try run(&context,
        \\{"command":"printf unreachable"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "error AccessDenied") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "exit code") == null);
}

test "bash reports a non-zero exit as an error" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try run(&context,
        \\{"command":"echo boom; exit 3"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "code 3") != null);
    // A real command takes a real, varying time, so the row's shape is what
    // this pins down. A non-zero exit states the measures a success states, and
    // the box shows them with no prefix of its own.
    try std.testing.expect(std.mem.startsWith(u8, result.summary.?.text, "Time: "));
    try std.testing.expect(
        std.mem.endsWith(u8, result.summary.?.text, " · Exit code: 3 · Lines: 1"),
    );
    try std.testing.expectEqual(Result.Summary.Kind.measures, result.summary.?.kind);
}

test "bash reports empty successful output" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try run(&context,
        \\{"command":"true"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("(No output)", result.content);
    try std.testing.expect(std.mem.startsWith(u8, result.summary.?.text, "Time: "));
    // A command that printed nothing reports no line count.
    try std.testing.expect(std.mem.endsWith(u8, result.summary.?.text, " · Exit code: 0"));
}

test "bash rejects invalid input" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try std.testing.expectError(error.InvalidArguments, run(&context, "{}"));
}

// A per-call value wins over the config, and both stay inside the legal window.
// A zero used to mean no limit, so a stale config file takes the floor.
test "the timeout of a call comes from either source and takes the clamp" {
    const defaults: Context.Bash = .{};
    const config: Context.Bash = .{ .timeout_ms = 5_000 };
    const stale: Context.Bash = .{ .timeout_ms = 0 };
    const two_seconds: Input = .{ .command = "", .timeout_seconds = 2 };
    const zero_seconds: Input = .{ .command = "", .timeout_seconds = 0 };
    const huge_seconds: Input = .{ .command = "", .timeout_seconds = std.math.maxInt(u64) };
    const no_seconds: Input = .{ .command = "" };

    try std.testing.expectEqual(@as(u64, 2_000), timeoutMs(&two_seconds, &config));
    try std.testing.expectEqual(@as(u64, 5_000), timeoutMs(&no_seconds, &config));
    try std.testing.expectEqual(@as(u64, defaults.timeout_ms), timeoutMs(&no_seconds, &defaults));
    try std.testing.expectEqual(Context.Bash.timeout_ms_min, timeoutMs(&zero_seconds, &config));
    try std.testing.expectEqual(Context.Bash.timeout_ms_min, timeoutMs(&no_seconds, &stale));
    try std.testing.expectEqual(Context.Bash.timeout_ms_max, timeoutMs(&huge_seconds, &config));
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

test "render summary discloses line and byte truncation" {
    const gpa = std.testing.allocator;
    {
        const limits: Context.Bash = .{ .lines_max = 2 };
        const result =
            try render(gpa, "a\nb\nc\n", &limits, .{ .completed = .{ .exited = 0 } }, 1_500);
        defer result.deinit(gpa);
        try std.testing.expectEqualStrings(
            "Time: 1.5s · Exit code: 0 · Lines: 3 · Output: Truncated",
            result.summary.?.text,
        );
    }
    {
        const limits: Context.Bash = .{ .lines_max = 1000, .bytes_max = 4 };
        const result =
            try render(gpa, "abcdef\n", &limits, .{ .completed = .{ .exited = 0 } }, 0);
        defer result.deinit(gpa);
        try std.testing.expectEqualStrings(
            "Time: 0ms · Exit code: 0 · Lines: 1 · Output: Truncated",
            result.summary.?.text,
        );
    }
}

// The timeout tests below run under a window that `run` never grants, so each
// stop costs a fraction of a second. A command that must act before the stop
// still has a wide margin for a slow start.
const test_timeout_ms = 200;

// A killed command keeps the tail it printed. The output is the evidence of
// where the time went, so the model does not retry blind.
test "a timed-out command keeps its output and states the stop" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try runWithTimeout(&context, "echo started; sleep 5", test_timeout_ms);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    // The output stands first, the shared separator follows, and the notice
    // closes the result.
    try std.testing.expectEqualStrings(
        "started\n\n\n[The command timed out after 200ms.]",
        result.content,
    );
    try std.testing.expect(std.mem.startsWith(u8, result.summary.?.text, "Time: "));
    try std.testing.expect(
        std.mem.endsWith(u8, result.summary.?.text, " · Status: Timed out · Lines: 1"),
    );
}

// The ticks arrive well inside the window, so an idle timeout would never fire.
test "bash timeout is absolute while output arrives" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try runWithTimeout(
        &context,
        "for i in {1..200}; do echo tick; sleep 0.02; done",
        test_timeout_ms,
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 200ms") != null);
}

test "bash timeout reaps a command after output closes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const command = try std.fmt.allocPrint(
        gpa,
        "echo $$ > .zig-cache/tmp/{s}/pid; exec 1>&- 2>&-; sleep 5",
        .{tmp.sub_path},
    );
    defer gpa.free(command);
    const context: Context = .{ .gpa = gpa, .io = io };
    const result = try runWithTimeout(&context, command, test_timeout_ms);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 200ms") != null);

    const process_id = try readProcessId(gpa, io, &tmp);
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const wait_result = std.posix.system.waitpid(process_id, &status, std.posix.W.NOHANG);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(wait_result));
}

// The stop reaches the whole process group, so a background child of the shell
// dies with it. Its parent is gone, so the system reaps it, and the probe polls
// for that moment inside a bound.
test "bash timeout kills descendant processes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const command = try std.fmt.allocPrint(
        gpa,
        "sleep 5 & echo $! > .zig-cache/tmp/{s}/pid; wait",
        .{tmp.sub_path},
    );
    defer gpa.free(command);
    const context: Context = .{ .gpa = gpa, .io = io };
    const result = try runWithTimeout(&context, command, test_timeout_ms);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);

    const process_id = try readProcessId(gpa, io, &tmp);
    var gone = false;
    for (0..200) |_| {
        // Signal zero probes for existence and delivers nothing.
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

/// The process id that a test command wrote to `pid` in its temporary directory.
fn readProcessId(gpa: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) !std.posix.pid_t {
    const text = try tmp.dir.readFileAlloc(io, "pid", gpa, .limited(64));
    defer gpa.free(text);
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trimEnd(u8, text, "\n"), 10);
}

// The capture cap kills the flood but keeps the window before it, so the last
// real step before the flood stays readable.
test "an oversized command keeps its output tail and states the stop" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var command_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(
        &command_buf,
        "{{\"command\":\"echo marker; yes x | head -c {d}\"}}",
        .{capture_bytes_max + (1 << 20)},
    );
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.content,
        "[The command produced more than 8 MB of output, so Drinky stopped it.]",
    ) != null);
    // The configured tail window keeps the flood, not the whole capture.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Drinky omitted") != null);
    try std.testing.expect(std.mem.startsWith(u8, result.summary.?.text, "Time: "));
    try std.testing.expect(
        std.mem.indexOf(u8, result.summary.?.text, " · Status: Output limit · Lines: ") != null,
    );
    try std.testing.expect(
        std.mem.endsWith(u8, result.summary.?.text, " · Output: Truncated"),
    );
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
