//! Runs a shell command in the working directory and returns its combined
//! stdout and stderr, bounded to a tail window and a wall-clock timeout.
//! Sanitizes the output to valid UTF-8 so it can serialize as a JSON tool result.

const std = @import("std");
const builtin = @import("builtin");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const Context = @import("Context.zig");
const parse = @import("parse.zig");
const Result = @import("Result.zig");

/// The hard cap on captured output. Beyond this, Pith stops the command and
/// does not buffer without bound. The configured window keeps only the tail
/// below it.
const capture_bytes_max = 8 << 20;

/// The UTF-8 replacement character, substituted for malformed input bytes.
const replacement = "\u{FFFD}";

pub const spec: llm.Tool = .{
    .name = "bash",
    .description = "Run a bash command in the working directory and return its combined " ++
        "stdout and stderr. Output is truncated to a bounded tail, and a non-zero exit is " ++
        "reported. Give an optional timeout in seconds; the default comes from configuration.",
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
            .description = "Seconds before the command is killed (default: configured limit)",
        },
    },
};

const Input = struct {
    command: []const u8,
    timeout_seconds: ?u64 = null,
};

const Completed = struct {
    output: []u8,
    term: std.process.Child.Term,
};

const Execution = struct {
    gpa: std.mem.Allocator,
    completed: ?Completed = null,

    fn deinit(self: *Execution) void {
        if (self.completed) |completed| self.gpa.free(completed.output);
    }

    fn take(self: *Execution) Completed {
        const completed = self.completed.?;
        self.completed = null;
        return completed;
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
    const timeout_ms = if (parsed.value.timeout_seconds) |seconds|
        seconds *| 1000
    else
        limits.timeout_ms;

    const started_ms = std.Io.Timestamp.now(context.io, .awake).toMilliseconds();
    const completed = execute(context, command, timeout_ms) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // A command that ran out of time reports that time the way a command
        // that finished does, because the row above it counted up to this
        // moment and the box must not drop the number the user watched.
        error.Timeout => return timedOut(
            gpa,
            std.Io.Timestamp.now(context.io, .awake).toMilliseconds() - started_ms,
            timeout_ms,
        ),
        error.StreamTooLong => return Result.report(
            gpa,
            .err,
            "The command produced more than {d} bytes of output and stopped. " ++
                "Reduce the output or redirect it to a file.",
            .{capture_bytes_max},
        ),
        else => return Result.report(
            gpa,
            .err,
            "Pith could not run the command because of error {s}.",
            .{@errorName(err)},
        ),
    };
    defer gpa.free(completed.output);

    const output = try sanitize(gpa, completed.output);
    defer gpa.free(output);

    const failed = switch (completed.term) {
        .exited => |code| code != 0,
        else => true,
    };
    const elapsed_ms = std.Io.Timestamp.now(context.io, .awake).toMilliseconds() - started_ms;
    return render(gpa, output, limits, completed.term, failed, elapsed_ms);
}

/// The result of a command the timeout stopped. Both spans read in the units the
/// interface uses, never in raw milliseconds, and the summary carries the run
/// time so every command reports one.
fn timedOut(gpa: std.mem.Allocator, elapsed_ms: i64, timeout_ms: u64) !Result {
    var limit: [24]u8 = undefined;
    var scale: [24]u8 = undefined;
    // Built field by field: the content states the limit to the model, and the
    // box reports the run time instead. An assignment over a report would leak
    // the sentence that the report put in the summary.
    const content = try std.fmt.allocPrint(gpa, "The command timed out after {s}.", .{
        format.duration(&limit, @intCast(@min(timeout_ms, std.math.maxInt(i64)))),
    });
    errdefer gpa.free(content);
    const summary = try std.fmt.allocPrint(gpa, "Time: {s} · Status: Timed out", .{
        format.duration(&scale, elapsed_ms),
    });
    return .{ .content = content, .summary = .{ .text = summary }, .is_error = true };
}

fn execute(context: *const Context, command: []const u8, timeout_ms: u64) !Completed {
    if (timeout_ms == 0) return collect(context, command);

    var execution: Execution = .{ .gpa = context.gpa };
    defer execution.deinit();
    const work_result = net.race(
        context.io,
        timeout_ms,
        collectInto,
        .{ context, command, &execution },
    ) catch return error.ConcurrencyUnavailable;
    try work_result;
    return execution.take();
}

fn collectInto(context: *const Context, command: []const u8, execution: *Execution) !void {
    execution.completed = try collect(context, command);
}

fn collect(context: *const Context, command: []const u8) !Completed {
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

    var read_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(output_files[0], io, &read_buffer);
    const output = reader.interface.allocRemaining(
        context.gpa,
        .limited(capture_bytes_max + 1),
    ) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.ReadFailed,
        else => |other| return other,
    };
    errdefer context.gpa.free(output);
    if (output.len > capture_bytes_max) return error.StreamTooLong;

    return .{ .output = output, .term = try child.wait(io) };
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

/// Build the tool result: a truncation note when the tail was cut, the kept
/// window, and a status line when the command failed.
///
/// Every end state reports the same measures, so a command that exited with a
/// non-zero code reads as a command that ran, not as a broken tool. The failure
/// flag still reaches the model, and the box still marks it.
fn render(
    gpa: std.mem.Allocator,
    output: []const u8,
    limits: *const Context.Bash,
    term: std.process.Child.Term,
    failed: bool,
    /// The wall-clock time the command ran. A long command is the one whose cost
    /// the user weighs, so the box reports it beside the exit status.
    elapsed_ms: i64,
) !Result {
    const start = tailStart(output, limits);
    const window = output[start..];

    var result_writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer result_writer.deinit();
    if (start > 0) {
        if (output[start - 1] == '\n') {
            try result_writer.writer.print(
                "[Pith omitted earlier output. Pith shows the last {d} of {d} lines.]\n",
                .{ format.lines(window), format.lines(output) },
            );
        } else {
            try result_writer.writer.print(
                "[Pith omitted earlier output. Pith shows the last {d} bytes.]\n",
                .{window.len},
            );
        }
    }
    try result_writer.writer.writeAll(window);
    if (window.len == 0 and start == 0 and !failed)
        try result_writer.writer.writeAll("(No output)");
    if (failed) {
        if (result_writer.writer.buffered().len > 0) try result_writer.writer.writeAll("\n\n");
        switch (term) {
            .exited => |code| try result_writer.writer.print(
                "[The command exited with code {d}.]",
                .{code},
            ),
            else => try result_writer.writer.writeAll("[The command stopped before it completed.]"),
        }
    }
    var summary_output: std.Io.Writer.Allocating = .init(gpa);
    errdefer summary_output.deinit();
    var scale: [24]u8 = undefined;
    // The run time comes first, because the row above counted up to it and a
    // narrow window cuts the tail of this row.
    try summary_output.writer.print("Time: {s}", .{format.duration(&scale, elapsed_ms)});
    // `code` is the number the command returned. `Status` names a state instead,
    // so a killed command cannot read as one that exited.
    switch (term) {
        .exited => |code| try summary_output.writer.print(" · Exit code: {d}", .{code}),
        else => try summary_output.writer.writeAll(" · Status: Terminated"),
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

test "bash timeout is absolute while output arrives" {
    const gpa = std.testing.allocator;
    const context: Context = .{
        .gpa = gpa,
        .io = std.testing.io,
        .bash = .{ .timeout_ms = 100 },
    };
    const result = try run(&context,
        \\{"command":"for i in {1..10}; do echo tick; sleep 0.05; done"}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 0.1s") != null);
}

test "bash timeout reaps a command after output closes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try std.fmt.allocPrint(
        gpa,
        "{{\"command\":\"echo $$ > .zig-cache/tmp/{s}/pid; exec 1>&- 2>&-; sleep 0.5\"}}",
        .{tmp.sub_path},
    );
    defer gpa.free(input);
    const context: Context = .{
        .gpa = gpa,
        .io = io,
        .bash = .{ .timeout_ms = 100 },
    };
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "timed out after 0.1s") != null);

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
        "{{\"command\":\"(sleep 0.3; touch .zig-cache/tmp/{s}/marker) & wait\"}}",
        .{tmp.sub_path},
    );
    defer gpa.free(input);
    const context: Context = .{
        .gpa = gpa,
        .io = io,
        .bash = .{ .timeout_ms = 100 },
    };
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try io.sleep(.fromMilliseconds(400), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "marker", .{}));
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
        const result = try render(gpa, "a\nb\nc\n", &limits, .{ .exited = 0 }, false, 1_500);
        defer result.deinit(gpa);
        try std.testing.expectEqualStrings(
            "Time: 1.5s · Exit code: 0 · Lines: 3 · Output: Truncated",
            result.summary.?.text,
        );
    }
    {
        const limits: Context.Bash = .{ .lines_max = 1000, .bytes_max = 4 };
        const result = try render(gpa, "abcdef\n", &limits, .{ .exited = 0 }, false, 0);
        defer result.deinit(gpa);
        try std.testing.expectEqualStrings(
            "Time: 0.0s · Exit code: 0 · Lines: 1 · Output: Truncated",
            result.summary.?.text,
        );
    }
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
