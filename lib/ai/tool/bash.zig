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

/// The UTF-8 replacement character, substituted for malformed input bytes.
const replacement = "\u{FFFD}";

pub const spec: llm.Tool = .{
    .name = "bash",
    .description = "Run a bash command in the working directory and return its combined " ++
        "stdout and stderr. Output is truncated to a bounded tail, and a non-zero exit is " ++
        "reported. A timed-out or oversized command still returns the tail of its output. " ++
        "Give an optional timeout in seconds; the default comes from configuration. " ++
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
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const command = parsed.value.command;
    const limits = &context.bash;
    // The guard runs first, so a denied command never starts. The user owns
    // the pattern list. It is a tripwire against a configured habit, not a
    // permission model, and no prompt asks for consent.
    if (limits.denies(command)) |pattern| return Result.report(
        gpa,
        .err,
        "Drinky refused this command because it contains the denied pattern \"{s}\".",
        .{pattern},
    );
    // Both sources take the same clamp, so a command always runs under a limit
    // the interface can measure, and neither the model nor the config can lift
    // it.
    const timeout_ms = Context.Bash.clampTimeoutMs(if (parsed.value.timeout_seconds) |seconds|
        seconds *| std.time.ms_per_s
    else
        limits.timeout_ms);

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
    std.debug.assert(timeout_ms >= Context.Bash.timeout_ms_min);
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

    var child = try std.process.spawn(io, .{
        .argv = &.{ "bash", "-c", command },
        .stdin = .ignore,
        .stdout = .{ .file = output_files[1] },
        .stderr = .{ .file = output_files[1] },
        .pgid = 0,
    });
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

test "bash honors a per-call timeout" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try run(&context,
        \\{"command":"sleep 5","timeout_seconds":1}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 1.0s") != null);
    // Every command reports its run time, so a stopped one keeps that row too.
    try std.testing.expect(std.mem.startsWith(u8, result.summary.?.text, "Time: "));
    try std.testing.expect(std.mem.endsWith(u8, result.summary.?.text, " · Status: Timed out"));
}

// A command that asks for no limit still runs under the smallest legal one, so
// no call can hold the turn open.
test "bash holds a per-call timeout inside the legal window" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    const result = try run(&context,
        \\{"command":"sleep 5","timeout_seconds":0}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 1.0s") != null);
}

// A configured value outside the window cannot lift the limit either. Zero used
// to mean no limit, so this is the path a stale config file takes.
test "bash holds a configured timeout inside the legal window" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .gpa = gpa,
        .io = std.testing.io,
        .bash = .{ .timeout_ms = 0 },
    };
    const result = try run(&context,
        \\{"command":"sleep 5"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 1.0s") != null);
}

test "bash timeout is absolute while output arrives" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .gpa = gpa,
        .io = std.testing.io,
        .bash = .{ .timeout_ms = Context.Bash.timeout_ms_min },
    };
    const result = try run(&context,
        \\{"command":"for i in {1..40}; do echo tick; sleep 0.05; done"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 1.0s") != null);
}

test "bash timeout reaps a command after output closes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try std.fmt.allocPrint(
        gpa,
        "{{\"command\":\"echo $$ > .zig-cache/tmp/{s}/pid; exec 1>&- 2>&-; sleep 5\"}}",
        .{tmp.sub_path},
    );
    defer gpa.free(input);
    const context: Context = .{
        .gpa = gpa,
        .io = io,
        .bash = .{ .timeout_ms = Context.Bash.timeout_ms_min },
    };
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 1.0s") != null);

    const pid_text = try tmp.dir.readFileAlloc(io, "pid", gpa, .limited(64));
    defer gpa.free(pid_text);
    const process_id = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trimEnd(u8, pid_text, "\n"),
        10,
    );
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const wait_result = std.posix.system.waitpid(process_id, &status, std.posix.W.NOHANG);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(wait_result));
}

test "bash timeout kills descendant processes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try std.fmt.allocPrint(
        gpa,
        "{{\"command\":\"(sleep 1.5; touch .zig-cache/tmp/{s}/marker) & wait\"}}",
        .{tmp.sub_path},
    );
    defer gpa.free(input);
    const context: Context = .{
        .gpa = gpa,
        .io = io,
        .bash = .{ .timeout_ms = Context.Bash.timeout_ms_min },
    };
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try io.sleep(.fromMilliseconds(1_000), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "marker", .{}));
}

test "bash refuses a denied command before it runs" {
    const gpa = std.testing.allocator;
    const deny = [_][]const u8{"git add"};
    const context: Context = .{
        .gpa = gpa,
        .io = std.testing.io,
        .bash = .{ .deny = &deny },
    };
    const result = try run(&context,
        \\{"command":"echo forbidden_output; git add -A"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "\"git add\"") != null);
    // The refusal comes before the spawn, so no part of the command ran.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "forbidden_output") == null);
    // The box shows the sentence of the refusal, so it wraps rather than cuts.
    try std.testing.expectEqual(Result.Summary.Kind.sentence, result.summary.?.kind);

    // A command that no pattern matches still runs.
    const allowed = try run(&context,
        \\{"command":"echo ok"}
    );
    defer allowed.deinit(gpa);
    try std.testing.expect(!allowed.is_error);
    try std.testing.expectEqualStrings("ok\n", allowed.content);
}

test "bash rejects invalid input" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try std.testing.expectError(error.InvalidArguments, run(&context, "{}"));
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

// A killed command keeps the tail it printed. The output is the evidence of
// where the time went, so the model does not retry blind.
test "a timed-out command keeps its output and states the stop" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .gpa = gpa,
        .io = std.testing.io,
        .bash = .{ .timeout_ms = Context.Bash.timeout_ms_min },
    };
    const result = try run(&context,
        \\{"command":"echo started; sleep 5"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    // The output stands first, and the notice closes the result. The separator
    // between them belongs to the shared render path, which the exit-code
    // tests pin.
    try std.testing.expect(std.mem.startsWith(u8, result.content, "started\n"));
    try std.testing.expectStringEndsWith(result.content, "[The command timed out after 1.0s.]");
    try std.testing.expect(std.mem.startsWith(u8, result.summary.?.text, "Time: "));
    try std.testing.expect(
        std.mem.endsWith(u8, result.summary.?.text, " · Status: Timed out · Lines: 1"),
    );
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
