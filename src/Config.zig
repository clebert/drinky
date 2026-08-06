//! The global configuration loaded from `<home>/.pith/config.json`. The file is
//! optional and can be partial. An absent file, section, or field falls back to a
//! built-in default. Pith ignores unknown keys, so an older binary can read a
//! newer file. The `File` struct below is the authoritative shape and default for
//! every key. More sections join it as the harness grows. It carries no secrets.
//! API keys come from the environment.
//!
//! The load also reads the user instruction files that the file names, through
//! `ai.instructions`, so the config owns their content for the session.

const std = @import("std");

const ai = @import("ai");

const Config = @This();

timeouts: ai.net.Timeouts = .{},
retry: ai.net.Retry = .{},
bash: ai.tool.Context.Bash = .{},
default_models: DefaultModels = .{},
/// The configured default reasoning-effort level, or null when the file names
/// none or names an unknown level. The caller falls back to a compiled default.
default_effort: ?ai.llm.Effort = null,
/// The user instruction files that `config.json` names, in the configured order,
/// with the messages the load produced. Owned.
user_instructions: ai.instructions.Result,
/// The configured default-model names that did not resolve (unknown, or a model
/// of the wrong vendor for their account). The config keeps them so the app can
/// tell the user Pith ignored their line. Empty on the built-in default. Owned.
/// `deinit` frees them.
dropped_models: []const DroppedModel = &.{},
/// The configured default effort level that did not resolve. The config keeps it
/// so the app can tell the user Pith ignored their line. Owned. `deinit` frees
/// it.
dropped_effort: ?[]const u8 = null,

/// The configured default model per account, resolved against the compiled model
/// table. An unset or unknown name is null, so the caller falls back to a
/// compiled default. A resolved model's name points into the static table, so
/// this outlives the parse with no owned memory.
pub const DefaultModels = struct {
    anthropic_api: ?ai.models.Model = null,
    anthropic_subscription: ?ai.models.Model = null,
    openai_api: ?ai.models.Model = null,
    openai_subscription: ?ai.models.Model = null,
    anthropic_console: ?ai.models.Model = null,

    pub fn get(self: *const DefaultModels, account: ai.llm.Account) ?ai.models.Model {
        return switch (account) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

/// A configured default-model name that did not resolve, with the account the
/// user wrote it under. Owns `name` (duped out of the parsed file).
pub const DroppedModel = struct {
    account: ai.llm.Account,
    name: []const u8,
};

/// The on-disk shape. Each field defaults to the built-in, so any subset parses.
const File = struct {
    user_instructions: []const File.UserInstruction = &.{},
    request: Request = .{},
    bash: Bash = .{},
    default_models: DefaultModelsFile = .{},
    default_effort: ?JsonString = null,

    /// A JSON value that must be a string. The default parser for `[]const u8`
    /// also accepts an array of numbers, which turns a mistyped path into bytes
    /// without a complaint. This parser rejects every token that is not a string.
    const JsonString = struct {
        value: []const u8,

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !JsonString {
            // Both options are null when the caller parses a `std.json.Value`,
            // which has no input buffer to borrow from and no token length.
            const token = try source.nextAllocMax(
                allocator,
                options.allocate orelse .alloc_always,
                options.max_value_len orelse std.json.default_max_value_len,
            );
            return switch (token) {
                inline .string, .allocated_string => |value| .{ .value = value },
                else => error.UnexpectedToken,
            };
        }

        fn get(maybe_string: ?JsonString) ?[]const u8 {
            const string = maybe_string orelse return null;
            return string.value;
        }
    };

    /// One configured user instruction file. A relative path resolves against
    /// `<home>/.pith/`.
    const UserInstruction = struct {
        path: JsonString,
    };

    const Request = struct {
        connect_timeout_ms: u64 = timeouts_default.connect_ms,
        idle_timeout_ms: u64 = timeouts_default.idle_ms,
        attempts_max: u32 = retry_default.attempts_max,
        backoff_ms_initial: u64 = retry_default.backoff_ms_initial,
        backoff_ms_max: u64 = retry_default.backoff_ms_max,
    };

    const Bash = struct {
        output_lines_max: usize = bash_default.lines_max,
        output_bytes_max: usize = bash_default.bytes_max,
        timeout_ms: u64 = bash_default.timeout_ms,
    };

    /// Model names keyed by account tag. Each resolves to a compiled model.
    const DefaultModelsFile = struct {
        anthropic_api: ?JsonString = null,
        anthropic_subscription: ?JsonString = null,
        openai_api: ?JsonString = null,
        openai_subscription: ?JsonString = null,
        anthropic_console: ?JsonString = null,
    };
};

/// The inputs `load` needs to find `config.json`. `home` can be relative, so it
/// resolves against the working directory the app already knows.
pub const LoadOptions = struct {
    working_directory: []const u8,
    home: []const u8,
};

const DataOptions = struct {
    directory: []const u8,
    data: []const u8,
};

const timeouts_default: ai.net.Timeouts = .{};
const retry_default: ai.net.Retry = .{};
const bash_default: ai.tool.Context.Bash = .{};

/// Free the user instruction files, their messages, and the dropped-default
/// names.
pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
    self.user_instructions.deinit();
    for (self.dropped_models) |dropped| gpa.free(dropped.name);
    gpa.free(self.dropped_models);
    if (self.dropped_effort) |name| gpa.free(name);
}

/// Load `<home>/.pith/config.json`, or the built-in defaults when it is absent.
/// Every configured user instruction path resolves against `<home>/.pith/`.
pub fn load(gpa: std.mem.Allocator, io: std.Io, options: *const LoadOptions) !Config {
    const directory = try std.fs.path.resolve(
        gpa,
        &.{ options.working_directory, options.home, ".pith" },
    );
    defer gpa.free(directory);
    const path = try std.fs.path.join(gpa, &.{ directory, "config.json" });
    defer gpa.free(path);
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{ .user_instructions = .init(gpa, .user) },
        else => return err,
    };
    defer gpa.free(data);
    return loadFromData(gpa, io, &.{ .directory = directory, .data = data });
}

/// Build the config from the bytes of `config.json` and fold each section into
/// the neutral option structs. This also reads every configured user instruction
/// file, so it needs `io`. Only a malformed file fails the load. A path Pith
/// cannot use becomes a message, so a bad entry never stops pith.
fn loadFromData(gpa: std.mem.Allocator, io: std.Io, options: *const DataOptions) !Config {
    const parsed = try std.json.parseFromSlice(
        File,
        gpa,
        options.data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const request = parsed.value.request;
    const bash = parsed.value.bash;
    const names = parsed.value.default_models;

    // The paths borrow the parsed arena, and the loader dupes what it keeps. The
    // loader inspects at most `files_max` entries, and one entry past that cap
    // is enough to make it report the rest. A long list therefore cannot grow
    // this buffer.
    var path_buffer: [ai.instructions.files_max + 1][]const u8 = undefined;
    const path_count = @min(parsed.value.user_instructions.len, path_buffer.len);
    const configured_paths = parsed.value.user_instructions[0..path_count];
    for (path_buffer[0..path_count], configured_paths) |*path, configured| {
        path.* = configured.path.value;
    }
    var user_instructions = try ai.instructions.load(gpa, io, &.{
        .directory = options.directory,
        .paths = path_buffer[0..path_count],
    });
    errdefer user_instructions.deinit();

    var dropped: std.ArrayList(DroppedModel) = .empty;
    errdefer {
        for (dropped.items) |item| gpa.free(item.name);
        dropped.deinit(gpa);
    }
    const default_models: DefaultModels = .{
        .anthropic_api = try resolveModel(
            gpa,
            &dropped,
            .anthropic_api,
            File.JsonString.get(names.anthropic_api),
        ),
        .anthropic_subscription = try resolveModel(
            gpa,
            &dropped,
            .anthropic_subscription,
            File.JsonString.get(names.anthropic_subscription),
        ),
        .openai_api = try resolveModel(
            gpa,
            &dropped,
            .openai_api,
            File.JsonString.get(names.openai_api),
        ),
        .openai_subscription = try resolveModel(
            gpa,
            &dropped,
            .openai_subscription,
            File.JsonString.get(names.openai_subscription),
        ),
        .anthropic_console = try resolveModel(
            gpa,
            &dropped,
            .anthropic_console,
            File.JsonString.get(names.anthropic_console),
        ),
    };
    var dropped_effort: ?[]const u8 = null;
    errdefer if (dropped_effort) |name| gpa.free(name);
    const default_effort = try resolveEffort(
        gpa,
        &dropped_effort,
        File.JsonString.get(parsed.value.default_effort),
    );
    return .{
        .timeouts = .{
            .connect_ms = request.connect_timeout_ms,
            .idle_ms = request.idle_timeout_ms,
        },
        .retry = .{
            .attempts_max = request.attempts_max,
            .backoff_ms_initial = request.backoff_ms_initial,
            .backoff_ms_max = request.backoff_ms_max,
        },
        .bash = .{
            .lines_max = bash.output_lines_max,
            .bytes_max = bash.output_bytes_max,
            .timeout_ms = bash.timeout_ms,
        },
        .default_models = default_models,
        .default_effort = default_effort,
        .user_instructions = user_instructions,
        .dropped_models = try dropped.toOwnedSlice(gpa),
        .dropped_effort = dropped_effort,
    };
}

/// Resolve the configured default effort level. An unknown name resolves to
/// null. The function also records it in `dropped` so the app can surface it. An
/// unset name is just null.
fn resolveEffort(
    gpa: std.mem.Allocator,
    dropped: *?[]const u8,
    name: ?[]const u8,
) !?ai.llm.Effort {
    const level = name orelse return null;
    if (std.meta.stringToEnum(ai.llm.Effort, level)) |resolved| return resolved;
    dropped.* = try gpa.dupe(u8, level);
    return null;
}

/// Resolve a configured model name for `account` against the compiled table for
/// that account's vendor. A name that is unknown or belongs to another vendor
/// resolves to null. The function also records it in `dropped` so the app can
/// surface it. An unset name is just null.
fn resolveModel(
    gpa: std.mem.Allocator,
    dropped: *std.ArrayList(DroppedModel),
    account: ai.llm.Account,
    name: ?[]const u8,
) !?ai.models.Model {
    const model_name = name orelse return null;
    if (ai.models.get(account.provider(), model_name)) |model| return model;
    const owned = try gpa.dupe(u8, model_name);
    errdefer gpa.free(owned);
    try dropped.append(gpa, .{ .account = account, .name = owned });
    return null;
}

fn loadDataForTest(data: []const u8) !Config {
    return loadFromData(std.testing.allocator, std.testing.io, &.{
        .directory = "/unused",
        .data = data,
    });
}

/// Load the config of a temporary home directory. The working directory only
/// matters for a relative home, which the tests never build.
fn loadForTest(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !Config {
    const working_directory = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(working_directory);
    return load(gpa, io, &.{ .working_directory = working_directory, .home = home });
}

fn tmpPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    tmp: *const std.testing.TmpDir,
    suffix: []const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, suffix });
}

test "load reads the request section" {
    var config = try loadDataForTest(
        \\{ "request": { "connect_timeout_ms": 1000, "idle_timeout_ms": 2000,
        \\  "attempts_max": 5, "backoff_ms_initial": 100, "backoff_ms_max": 900 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.connect_ms);
    try std.testing.expectEqual(@as(u64, 2000), config.timeouts.idle_ms);
    try std.testing.expectEqual(@as(u32, 5), config.retry.attempts_max);
    try std.testing.expectEqual(@as(u64, 100), config.retry.backoff_ms_initial);
    try std.testing.expectEqual(@as(u64, 900), config.retry.backoff_ms_max);
}

test "load reads the bash section" {
    var config = try loadDataForTest(
        \\{ "bash": { "output_lines_max": 17, "output_bytes_max": 4096,
        \\  "timeout_ms": 1500 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 17), config.bash.lines_max);
    try std.testing.expectEqual(@as(usize, 4096), config.bash.bytes_max);
    try std.testing.expectEqual(@as(u64, 1500), config.bash.timeout_ms);
}

test "load fills missing fields and sections from defaults" {
    var partial = try loadDataForTest(
        \\{ "request": { "attempts_max": 7 } }
    );
    defer partial.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), partial.retry.attempts_max);
    try std.testing.expectEqual(timeouts_default.connect_ms, partial.timeouts.connect_ms);
    try std.testing.expectEqual(retry_default.backoff_ms_initial, partial.retry.backoff_ms_initial);
    try std.testing.expectEqual(bash_default.lines_max, partial.bash.lines_max);
    try std.testing.expectEqual(bash_default.bytes_max, partial.bash.bytes_max);
    try std.testing.expectEqual(bash_default.timeout_ms, partial.bash.timeout_ms);

    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(timeouts_default.idle_ms, empty.timeouts.idle_ms);
    try std.testing.expectEqual(retry_default.attempts_max, empty.retry.attempts_max);
    try std.testing.expectEqual(@as(usize, 0), empty.user_instructions.files().len);
}

test "load resolves default_models to compiled models, dropping unknown names" {
    var config = try loadDataForTest(
        \\{ "default_models": { "anthropic_subscription": "claude-sonnet-5",
        \\  "anthropic_api": "gpt-5.6-sol", "openai_api": "nope" } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "claude-sonnet-5",
        config.default_models.get(.anthropic_subscription).?.name,
    );
    // A wrong-vendor name (an openai model under an anthropic account) does not
    // resolve, so it falls back to null.
    try std.testing.expect(config.default_models.get(.anthropic_api) == null);
    // An unknown name and an unset account both resolve to null.
    try std.testing.expect(config.default_models.get(.openai_api) == null);
    try std.testing.expect(config.default_models.get(.openai_subscription) == null);

    // The parse records the two present-but-unresolved names for the app to
    // surface. It does not record the valid one or the unset ones.
    try std.testing.expectEqual(@as(usize, 2), config.dropped_models.len);
    try std.testing.expectEqual(ai.llm.Account.anthropic_api, config.dropped_models[0].account);
    try std.testing.expectEqualStrings("gpt-5.6-sol", config.dropped_models[0].name);
    try std.testing.expectEqual(ai.llm.Account.openai_api, config.dropped_models[1].account);
    try std.testing.expectEqualStrings("nope", config.dropped_models[1].name);
}

test "load resolves default_effort, dropping an unknown level" {
    var config = try loadDataForTest(
        \\{ "default_effort": "max" }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(ai.llm.Effort.max, config.default_effort.?);
    try std.testing.expect(config.dropped_effort == null);

    var dropped = try loadDataForTest(
        \\{ "default_effort": "enormous" }
    );
    defer dropped.deinit(std.testing.allocator);
    try std.testing.expect(dropped.default_effort == null);
    try std.testing.expectEqualStrings("enormous", dropped.dropped_effort.?);

    // An unset level is null, with nothing dropped.
    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(empty.default_effort == null);
    try std.testing.expect(empty.dropped_effort == null);
}

test "a configured name must be a JSON string" {
    try std.testing.expectError(
        error.UnexpectedToken,
        loadDataForTest(
            \\{ "user_instructions": { "path": "instructions.md" } }
        ),
    );
    try std.testing.expectError(
        error.UnexpectedToken,
        loadDataForTest(
            \\{ "user_instructions": [{ "path": ["one.md", "two.md"] }] }
        ),
    );
    // The default parser for `[]const u8` reads an array of numbers as bytes.
    // Both the paths and the model names reject it.
    try std.testing.expectError(
        error.UnexpectedToken,
        loadDataForTest(
            \\{ "user_instructions": [{ "path": [105, 110, 115, 116, 114] }] }
        ),
    );
    try std.testing.expectError(
        error.UnexpectedToken,
        loadDataForTest(
            \\{ "default_models": { "openai_api": [103, 112, 116] } }
        ),
    );
    try std.testing.expectError(
        error.MissingField,
        loadDataForTest(
            \\{ "user_instructions": [{}] }
        ),
    );
}

test "load ignores unknown keys" {
    var config = try loadDataForTest(
        \\{ "request": { "connect_timeout_ms": 42 }, "future": { "x": 1 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), config.timeouts.connect_ms);
}

test "load resolves user instruction paths against the config directory in order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pith_directory = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    defer pith_directory.close(io);
    // The `\u002e` escape is the `.` of `second.md`. It makes the JSON parser
    // build the path in the arena, which covers the allocated branch of the
    // custom string parser. The plain `first.md` covers the borrowed branch.
    try pith_directory.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{ "user_instructions": [
        \\  { "path": "second\u002emd" },
        \\  { "path": "first.md" },
        \\  { "path": "missing.md" }
        \\] }
        ,
    });
    try pith_directory.writeFile(io, .{ .sub_path = "first.md", .data = "First.\n" });
    try pith_directory.writeFile(io, .{ .sub_path = "second.md", .data = "Second.\n" });
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    const files = config.user_instructions.files();
    try std.testing.expectEqual(@as(usize, 2), files.len);
    const second_path = try std.fs.path.join(gpa, &.{ home, ".pith", "second.md" });
    defer gpa.free(second_path);
    const first_path = try std.fs.path.join(gpa, &.{ home, ".pith", "first.md" });
    defer gpa.free(first_path);
    try std.testing.expectEqualStrings(second_path, files[0].path);
    try std.testing.expectEqualStrings("Second.\n", files[0].content);
    try std.testing.expectEqualStrings(first_path, files[1].path);
    try std.testing.expectEqualStrings("First.\n", files[1].content);
    // The loader reports a path it cannot use, and the config carries it through.
    try std.testing.expectEqual(@as(usize, 1), config.user_instructions.notices().len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        config.user_instructions.notices()[0].text,
        "missing.md",
    ) != null);
}

test "load accepts an absolute path to user instructions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pith_directory = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    defer pith_directory.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "instructions.md",
        .data = "Use the configured absolute path.",
    });
    const instructions_path = try tmpPath(gpa, io, &tmp, "instructions.md");
    defer gpa.free(instructions_path);
    const config_data = try std.json.Stringify.valueAlloc(gpa, .{
        .user_instructions = &.{.{ .path = instructions_path }},
    }, .{});
    defer gpa.free(config_data);
    try pith_directory.writeFile(io, .{ .sub_path = "config.json", .data = config_data });
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    const files = config.user_instructions.files();
    try std.testing.expectEqualStrings(instructions_path, files[0].path);
    try std.testing.expectEqualStrings("Use the configured absolute path.", files[0].content);
}

test "an absent config file loads the built-in defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);
    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    try std.testing.expectEqual(timeouts_default.connect_ms, config.timeouts.connect_ms);
    try std.testing.expectEqual(@as(usize, 0), config.user_instructions.files().len);
    try std.testing.expectEqual(@as(usize, 0), config.user_instructions.notices().len);
    try std.testing.expectEqual(@as(usize, 0), config.dropped_models.len);
}

fn checkLoadAllocationFailure(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), config.user_instructions.files().len);
    try std.testing.expectEqual(@as(usize, 1), config.user_instructions.notices().len);
    try std.testing.expectEqual(@as(usize, 1), config.dropped_models.len);
    try std.testing.expect(config.dropped_effort != null);
}

test "the config load frees every partial allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pith_directory = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    defer pith_directory.close(io);
    try pith_directory.writeFile(io, .{ .sub_path = "first.md", .data = "First.\n" });
    try pith_directory.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{ "user_instructions": [{ "path": "first.md" }, { "path": "missing.md" }],
        \\  "default_models": { "openai_api": "nope" }, "default_effort": "nope" }
        ,
    });
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    try std.testing.checkAllAllocationFailures(gpa, checkLoadAllocationFailure, .{ io, home });
}
