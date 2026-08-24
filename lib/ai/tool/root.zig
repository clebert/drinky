//! The tools the model can call. Each module exposes a `spec` and a `run`.
//! The registry pairs them.

const std = @import("std");

const format = @import("../format.zig");
const json = @import("../json.zig");
const llm = @import("../llm.zig");

pub const Context = @import("Context.zig");
pub const Result = @import("Result.zig");
pub const SkillGuard = @import("SkillGuard.zig");

const read = @import("read.zig");
const write = @import("write.zig");
const edit = @import("edit.zig");
const find = @import("find.zig");
const grep = @import("grep.zig");
const bash = @import("bash.zig");
const describe_drinky = @import("describe_drinky.zig");
const search = @import("search.zig");

/// The window of one `read` call: a file inside both bounds comes back whole.
/// The skill scan holds a skill file below it, so one call can put the whole
/// file in front of the model.
pub const read_lines_max = read.lines_max;
pub const read_bytes_max = read.bytes_max;

const Entry = struct {
    tool: llm.Tool,
    run: *const fn (*const Context, []const u8) anyerror!Result,
    mutates: bool,
    /// The argument that names what a call acts on, which is the one the
    /// transcript shows. Empty when a call has nothing to name, so its row is
    /// the tool name alone.
    subject: []const u8 = "",
    /// What the row calls the subject. Every fragment Drinky shows is a key and a
    /// value, so the subject carries its key too. It also says which kind of
    /// value follows, because a pattern and a file read alike on their own.
    subject_label: []const u8 = "",
    /// Whether `subject` names a file, so the row shortens it the way every
    /// other path in the interface reads. A pattern and a command are not paths,
    /// and a shortened one means something else.
    subject_is_path: bool = false,
    /// Where the wall-clock timeout of a call comes from. A tool with a timeout
    /// can run long enough that the user weighs whether to cancel it, so its row
    /// reports how long it has run and how long it can run.
    timeout: Timeout = .none,

    /// The source of the wall-clock timeout that one tool runs under.
    const Timeout = union(enum) {
        /// The tool runs under no timeout, so its row reports no time.
        none,
        /// The host configures the timeout, and the named argument overrides it
        /// per call, in seconds.
        argument: []const u8,
        /// The tool holds one built-in timeout, in milliseconds, and no call
        /// changes it.
        fixed: u64,

        /// The timeout of a call whose argument list states no override. Null
        /// when the tool runs under no timeout at all.
        fn defaultMs(self: Timeout, configured_ms: u64) ?u64 {
            return switch (self) {
                .none => null,
                // The configured value comes from a file the user writes, so it
                // takes the same clamp the argument takes.
                .argument => Context.Bash.clampTimeoutMs(configured_ms),
                .fixed => |fixed_ms| fixed_ms,
            };
        }

        /// The argument that overrides the timeout, or null when no call can
        /// change it.
        fn argumentName(self: Timeout) ?[]const u8 {
            return switch (self) {
                .argument => |name| name,
                else => null,
            };
        }
    };
};

const registry = [_]Entry{
    .{
        .tool = read.spec,
        .run = read.run,
        .mutates = false,
        .subject = "path",
        .subject_label = "File",
        .subject_is_path = true,
    },
    .{
        .tool = write.spec,
        .run = write.run,
        .mutates = true,
        .subject = "path",
        .subject_label = "File",
        .subject_is_path = true,
    },
    .{
        .tool = edit.spec,
        .run = edit.run,
        .mutates = true,
        .subject = "path",
        .subject_label = "File",
        .subject_is_path = true,
    },
    .{
        .tool = find.spec,
        .run = find.run,
        .mutates = false,
        .subject = "pattern",
        .subject_label = "Pattern",
        .timeout = .{ .fixed = search.timeout_ms },
    },
    .{
        .tool = grep.spec,
        .run = grep.run,
        .mutates = false,
        .subject = "pattern",
        .subject_label = "Pattern",
        .timeout = .{ .fixed = search.timeout_ms },
    },
    .{
        .tool = bash.spec,
        .run = bash.run,
        .mutates = true,
        .subject = "command",
        .subject_label = "Command",
        .timeout = .{ .argument = "timeout_seconds" },
    },
    .{ .tool = describe_drinky.spec, .run = describe_drinky.run, .mutates = false },
};

/// The schemas of every tool, advertised to the provider in a request.
pub const specs = blk: {
    var list: [registry.len]llm.Tool = undefined;
    for (registry, 0..) |entry, index| list[index] = entry.tool;
    break :blk list;
};

/// Whether tool `name` can have side effects, so the agent runs it as a barrier.
/// An unknown tool touches nothing, so it runs concurrently and just reports
/// the unknown-tool error.
pub fn mutates(name: []const u8) bool {
    for (registry) |entry| {
        if (std.mem.eql(u8, name, entry.tool.name)) return entry.mutates;
    }
    return false;
}

/// Everything the interface shows about one call, read from the registry and
/// the argument list in one pass. The caller owns `subject` and frees the whole
/// thing with `deinit`.
pub const Call = struct {
    /// What the row calls the subject: `File`, `Pattern`, or `Command`. Empty
    /// exactly when `subject` is empty, so a row never carries a dangling key
    /// or an unnamed value.
    label: []const u8,
    /// The argument that names the file, the pattern, or the command the call
    /// acts on.
    subject: []u8,
    /// The wall-clock timeout the call runs under, in milliseconds. Null means
    /// the tool runs under no timeout at all, so its row reports no time. A tool
    /// with a timeout always states one, because no call can run without a
    /// limit.
    timeout_ms: ?u64,

    pub fn deinit(self: *const Call, gpa: std.mem.Allocator) void {
        gpa.free(self.subject);
    }
};

/// Describe one call for the interface. One registry lookup and one parse of
/// `input_json` serve every field, so a starting call reads its arguments once.
///
/// The transcript shows the subject alone, never the argument list, because the
/// JSON around it carries no meaning for the reader. A `bash` row therefore
/// holds the command close to the form the user types.
///
/// Every subject collapses each run of whitespace and control bytes to one
/// space, so one call keeps one row: a command with a here-document reads as one
/// flowing line and the row truncates it. A path and a pattern take the same
/// rule. One rule for every subject beats a per-tool exception, and the value it
/// changes is a path or a pattern that already reads as two words.
///
/// An unknown tool, an unparsable list, and a missing subject all fall back to
/// the empty subject, so a caller always has a row to draw.
///
/// A `bash` call can override the configured timeout, so this reads that
/// argument and falls back to `default_timeout_ms`. Both take the clamp the tool
/// applies, so the row states the limit the command really runs under. An absurd
/// number from a model or a config file therefore cannot overflow the display
/// below it. A search holds its own built-in timeout, which no call changes.
pub fn describe(
    gpa: std.mem.Allocator,
    name: []const u8,
    input_json: []const u8,
    roots: *const format.Roots,
    default_timeout_ms: u64,
) !Call {
    const entry = for (registry) |candidate| {
        if (std.mem.eql(u8, name, candidate.tool.name)) break candidate;
    } else return unnamed(gpa, null);
    const default_ms = entry.timeout.defaultMs(default_timeout_ms);
    // A tool with no subject and no timeout has nothing to read arguments for.
    if (entry.subject.len == 0 and default_ms == null) return unnamed(gpa, null);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // An argument list the model cut short still runs under the configured
    // timeout once it completes.
    const parsed = (try json.parseObject(arena.allocator(), input_json)) orelse
        return unnamed(gpa, default_ms);

    const timeout_ms = readTimeoutMs(&entry, &parsed, default_timeout_ms);
    if (entry.subject.len == 0) return unnamed(gpa, timeout_ms);
    const value = json.string(parsed.get(entry.subject)) orelse return unnamed(gpa, timeout_ms);

    // A path reads the way every other path in the interface reads. A pattern
    // and a command pass through, because they are not paths.
    const text = if (entry.subject_is_path)
        try format.path(gpa, value, roots)
    else
        try gpa.dupe(u8, value);
    errdefer gpa.free(text);
    var length: usize = 0;
    var blank = false;
    for (text) |byte| {
        // A control byte reaches no cell of its own, so it joins the run of
        // blanks around it rather than becoming a replacement glyph.
        if (byte == ' ' or byte <= 0x1f or byte == 0x7f) {
            blank = length != 0;
            continue;
        }
        if (blank) {
            text[length] = ' ';
            length += 1;
            blank = false;
        }
        text[length] = byte;
        length += 1;
    }
    // A shrink, so the caller always frees a slice whose length matches its
    // allocation. A failure here frees the original through the guard above.
    const subject = try gpa.realloc(text, length);
    return .{
        // A subject that collapsed to nothing leaves no value for the key to name.
        .label = if (subject.len == 0) "" else entry.subject_label,
        .subject = subject,
        .timeout_ms = timeout_ms,
    };
}

/// A call whose row is the tool name alone. The subject is still owned, so every
/// caller frees one result the same way.
fn unnamed(gpa: std.mem.Allocator, timeout_ms: ?u64) !Call {
    return .{ .label = "", .subject = try gpa.dupe(u8, ""), .timeout_ms = timeout_ms };
}

fn readTimeoutMs(
    entry: *const Entry,
    parsed: *const std.json.ObjectMap,
    default_timeout_ms: u64,
) ?u64 {
    const default_ms = entry.timeout.defaultMs(default_timeout_ms);
    const argument = entry.timeout.argumentName() orelse return default_ms;
    // An absent argument, and a null one, both leave the configured timeout.
    const raw = parsed.get(argument) orelse return default_ms;
    if (raw == .null) return default_ms;
    // A value the typed parse rejects makes the call fail before it runs, so no
    // timeout applies to it. Reporting one states a wait for a call that never
    // starts. The two parses must agree on which values those are, or the row
    // reports no timeout for a call that runs under one.
    const seconds = unsignedSeconds(raw) orelse return null;
    return Context.Bash.clampTimeoutMs(seconds *| std.time.ms_per_s);
}

/// The seconds a timeout argument states, read the way the typed tool parse
/// reads it. `std.json` keeps a number above `maxInt(i64)` as a string, and the
/// unsigned field of a tool accepts it, so this accepts it too. A negative or
/// fractional value fails both.
fn unsignedSeconds(raw: std.json.Value) ?u64 {
    return switch (raw) {
        .integer => |found| if (found < 0) null else @intCast(found),
        .number_string => |found| std.fmt.parseInt(u64, found, 10) catch null,
        else => null,
    };
}

/// Execute tool `name` with `input_json`. The caller owns the result and frees
/// it with `Result.deinit`.
pub fn run(context: *const Context, name: []const u8, input_json: []const u8) !Result {
    for (registry) |entry| {
        if (!std.mem.eql(u8, name, entry.tool.name)) continue;
        return entry.run(context, input_json) catch |err| switch (err) {
            error.InvalidArguments => try Result.report(
                context.gpa,
                .err,
                "Drinky received invalid arguments for the {s} tool.",
                .{name},
            ),
            else => return err,
        };
    }
    return Result.report(
        context.gpa,
        .err,
        "Drinky does not recognize the tool {s}.",
        .{name},
    );
}

test "mutating tools are marked, read-only tools are not" {
    try std.testing.expect(mutates("write"));
    try std.testing.expect(mutates("edit"));
    try std.testing.expect(mutates("bash"));
    try std.testing.expect(!mutates("read"));
    try std.testing.expect(!mutates("grep"));
    try std.testing.expect(!mutates("nope"));
}

test "unknown tool is an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "nope", "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

test "invalid arguments are reported, not raised" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "read", "{}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

// Every tool with a subject names it, and the name says which kind of value
// follows. A file and a pattern read alike on their own, so the label is what
// tells them apart in a row.
test describe {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        label: []const u8,
        subject: []const u8,
    }{
        // The row names the file, the pattern, or the command, never the JSON.
        .{
            .name = "read",
            .input = "{\"path\":\"src/App.zig\"}",
            .label = "File",
            .subject = "src/App.zig",
        },
        .{
            .name = "write",
            .input = "{\"path\":\"a.zig\",\"content\":\"x\"}",
            .label = "File",
            .subject = "a.zig",
        },
        .{
            .name = "edit",
            .input = "{\"path\":\"a.zig\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            .label = "File",
            .subject = "a.zig",
        },
        .{ .name = "find", .input = "{\"pattern\":\"*.zig\"}", .label = "Pattern", .subject = "*.zig" },
        .{
            .name = "grep",
            .input = "{\"pattern\":\"columns\"}",
            .label = "Pattern",
            .subject = "columns",
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"zig build\"}",
            .label = "Command",
            .subject = "zig build",
        },
        // A here-document keeps one row: its line breaks read as single spaces.
        .{
            .name = "bash",
            .input = "{\"command\":\"cat <<'EOF'\\n  one\\n\\n  two\\nEOF\"}",
            .label = "Command",
            .subject = "cat <<'EOF' one two EOF",
        },
        // The tool takes no arguments, so its row is the name alone.
        .{ .name = "describe_drinky", .input = "{}", .label = "", .subject = "" },
        // A list the model cut short still yields a row.
        .{ .name = "write", .input = "{\"path\":\"a.zig\",\"conte", .label = "", .subject = "" },
        .{ .name = "read", .input = "{\"offset\":3}", .label = "", .subject = "" },
        .{ .name = "nonesuch", .input = "{\"path\":\"a.zig\"}", .label = "", .subject = "" },
        // A subject of blanks alone collapses away, and its key goes with it.
        .{ .name = "grep", .input = "{\"pattern\":\"  \"}", .label = "", .subject = "" },
    };
    for (cases) |case| {
        const call = try describe(gpa, case.name, case.input, &.{}, 120_000);
        defer call.deinit(gpa);
        try std.testing.expectEqualStrings(case.label, call.label);
        try std.testing.expectEqualStrings(case.subject, call.subject);
        // A label without a value, or a value without a label, leaves a row with
        // a dangling key or an unnamed value.
        try std.testing.expectEqual(call.subject.len == 0, call.label.len == 0);
    }
}

// A path in a row reads the way every path in the interface reads. A pattern and
// a command are not paths, and a shortened one means something else.
test "a path subject shortens, and a pattern or a command does not" {
    const gpa = std.testing.allocator;
    const roots: format.Roots = .{
        .working_directory = "/home/you/work",
        .home_directory = "/home/you",
    };
    const cases = [_]struct { name: []const u8, input: []const u8, expected: []const u8 }{
        .{
            .name = "read",
            .input = "{\"path\":\"/home/you/work/src/App.zig\"}",
            .expected = "src/App.zig",
        },
        .{
            .name = "write",
            .input = "{\"path\":\"/home/you/.drinky/notes.md\"}",
            .expected = "~/.drinky/notes.md",
        },
        // Outside both roots the whole path stays, because that is the reach the
        // user must be able to see.
        .{ .name = "edit", .input = "{\"path\":\"/etc/hosts\"}", .expected = "/etc/hosts" },
        // A pattern that looks like a path is still a pattern.
        .{
            .name = "find",
            .input = "{\"pattern\":\"/home/you/work/**/*.zig\"}",
            .expected = "/home/you/work/**/*.zig",
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"ls /home/you/work\"}",
            .expected = "ls /home/you/work",
        },
    };
    for (cases) |case| {
        const call = try describe(gpa, case.name, case.input, &roots, 120_000);
        defer call.deinit(gpa);
        try std.testing.expectEqualStrings(case.expected, call.subject);
    }
}

test "a described call reports the timeout it runs under" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { name: []const u8, input: []const u8, expected: ?u64 }{
        // A call takes the configured timeout unless it names its own.
        .{ .name = "bash", .input = "{\"command\":\"true\"}", .expected = 120_000 },
        .{
            .name = "bash",
            .input = "{\"command\":\"true\",\"timeout_seconds\":5}",
            .expected = 5_000,
        },
        // A call cannot ask for no limit. It gets the smallest legal window, so
        // the row states a real wait rather than an open one.
        .{
            .name = "bash",
            .input = "{\"command\":\"true\",\"timeout_seconds\":0}",
            .expected = Context.Bash.timeout_ms_min,
        },
        // A search holds its own timeout, and no argument of a call changes it.
        .{ .name = "find", .input = "{\"pattern\":\"*.zig\"}", .expected = search.timeout_ms },
        .{
            .name = "grep",
            .input = "{\"pattern\":\"x\",\"timeout_seconds\":5}",
            .expected = search.timeout_ms,
        },
        // Every other tool ends on its own, so its row states no wait.
        .{ .name = "read", .input = "{\"path\":\"a\"}", .expected = null },
        .{ .name = "nonesuch", .input = "{}", .expected = null },
        // An argument list the model cut short still yields the configured timeout.
        .{ .name = "bash", .input = "{\"comm", .expected = 120_000 },
        // A value the typed parse rejects reports no timeout, so the row cannot
        // state a wait for a call that fails before it starts.
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":-5}",
            .expected = null,
        },
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":\"5\"}",
            .expected = null,
        },
        // A null argument is the same as an absent one, which is what the typed
        // parse does with it too.
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":null}",
            .expected = 120_000,
        },
        // A timeout stated in absurd numbers falls back to the largest legal
        // window, rather than overflowing the signed span below it.
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":9223372036854775807}",
            .expected = Context.Bash.timeout_ms_max,
        },
        // Above `maxInt(i64)` the JSON parse keeps the number as a string. The
        // typed parse of the tool still takes it, so the row must report a
        // timeout rather than claim the call runs under none.
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":18446744073709551615}",
            .expected = Context.Bash.timeout_ms_max,
        },
        // A fractional value fails both parses, so the call never runs.
        .{
            .name = "bash",
            .input = "{\"command\":\"x\",\"timeout_seconds\":1.5}",
            .expected = null,
        },
    };
    for (cases) |case| {
        const call = try describe(gpa, case.name, case.input, &.{}, 120_000);
        defer call.deinit(gpa);
        try std.testing.expectEqual(case.expected, call.timeout_ms);
    }
}

// Regression: the configured timeout comes from a file the user writes, so it
// takes the same clamp the argument does. Without it the display cast below
// this panics on a number no argument could reach.
test "an absurd configured timeout clamps on every fallback path" {
    const gpa = std.testing.allocator;
    const inputs = [_][]const u8{
        "{\"command\":\"x\"}",
        "{\"command\":\"x\",\"timeout_seconds\":null}",
        "{\"comm",
    };
    for (inputs) |input| {
        const call = try describe(gpa, "bash", input, &.{}, std.math.maxInt(u64));
        defer call.deinit(gpa);
        try std.testing.expectEqual(@as(?u64, Context.Bash.timeout_ms_max), call.timeout_ms);
    }
    // A configured zero used to mean no limit. It now names the smallest legal
    // window, so the row cannot promise a wait the command does not take.
    const call = try describe(gpa, "bash", "{\"command\":\"x\"}", &.{}, 0);
    defer call.deinit(gpa);
    try std.testing.expectEqual(@as(?u64, Context.Bash.timeout_ms_min), call.timeout_ms);
}

// A label without a value, or a value without a label, leaves a row with a
// dangling key or an unnamed value.
test "every subject carries a label and every label a subject" {
    for (registry) |entry| {
        try std.testing.expectEqual(entry.subject.len == 0, entry.subject_label.len == 0);
    }
}
