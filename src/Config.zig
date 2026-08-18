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

/// The absolute path of `config.json`, present whether or not the file exists.
/// The settings document and the notices name it, so the user and the model both
/// read the same path. Owned. `deinit` frees it.
path: []const u8,
timeouts: ai.net.Timeouts = .{},
retry: ai.net.Retry = .{},
bash: ai.tool.Context.Bash = .{},
cache: ai.Agent.CachePolicy = .{},
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
/// The configured cache warning cost that Pith cannot use, as the user wrote it.
/// The config keeps it so the app can tell the user Pith ignored their line, and
/// the policy falls back to the built-in floor. Null on a legal value. Owned.
/// `deinit` frees it.
dropped_cost: ?[]const u8 = null,
/// The keys of `config.json` that no field of `File` matches, as paths in file
/// order. The parse ignores them, so the app reports them and a typo does not
/// disappear silently. Owned. `deinit` frees them.
unknown_keys: []const []const u8 = &.{},
/// Whether more unknown keys followed the retained keys. The app reports the
/// omission once, so the diagnostic cap never hides silently.
unknown_keys_omitted: bool = false,

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
    cache: Cache = .{},
    default_models: DefaultModelsFile = .{},
    default_effort: ?JsonString = null,

    /// A JSON value that must be a string. The default parser for `[]const u8`
    /// also accepts an array of numbers, which turns a mistyped path into bytes
    /// without a complaint. This parser rejects every value that is not a string.
    const JsonString = struct {
        value: []const u8,

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !JsonString {
            _ = options;
            return switch (source) {
                .string => |value| .{ .value = try allocator.dupe(u8, value) },
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

    const Cache = struct {
        anthropic_retention_ms: ?u64 = cache_default.anthropic_retention_ms,
        openai_retention_ms: ?u64 = cache_default.openai_retention_ms,
        warning_min_cost: f64 = cache_default.warning_min_cost,
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
    path: []const u8,
    data: []const u8,
};

const timeouts_default: ai.net.Timeouts = .{};
const retry_default: ai.net.Retry = .{};
const bash_default: ai.tool.Context.Bash = .{};
const cache_default: ai.Agent.CachePolicy = .{};

/// A malformed file must not fill the startup transcript with one event per
/// key. Sixteen paths identify a broad shape mismatch. One final event reports
/// that the cap omitted the remaining paths.
const unknown_keys_max = 16;

/// The prose for one leaf key of `File`. The `keys` table below must hold one
/// entry per leaf, and `leaves` turns a missing or a stale entry into a compile
/// error. The type and the default are read off `File`, so a default can never
/// drift out of the document.
const Key = struct {
    path: []const u8,
    description: []const u8,
};

/// The caveat on the keys that a remembered per-project choice outranks. One
/// constant states it on every such key, so the trap sits where the reader
/// decides rather than in a later section.
const new_project_only = " Only a new project reads it.";

const keys = [_]Key{
    .{
        .path = "user_instructions",
        .description = std.fmt.comptimePrint(
            "The instruction files that Pith loads into every system prompt, in this order. " ++
                "Pith loads at most {d} files, {d} KiB in total, and {d} KiB from one file.",
            .{
                ai.instructions.files_max,
                ai.instructions.source_kibibytes_max,
                ai.instructions.file_kibibytes_max,
            },
        ),
    },
    .{
        .path = "user_instructions[].path",
        .description = "The path of one instruction file. A relative path resolves against " ++
            "the directory of this file.",
    },
    .{
        .path = "request.connect_timeout_ms",
        .description = "The time that Pith waits for the head of a provider response.",
    },
    .{
        .path = "request.idle_timeout_ms",
        .description = "The time that Pith waits between two streamed events. A keepalive " ++
            "ping is not an event and does not restart the wait.",
    },
    .{
        .path = "request.attempts_max",
        .description = "The number of times that Pith sends one request before it fails.",
    },
    .{
        .path = "request.backoff_ms_initial",
        .description = "The wait before the second attempt. Each further wait doubles it.",
    },
    .{
        .path = "request.backoff_ms_max",
        .description = "The upper bound on one wait between attempts. It caps the doubling " ++
            "above. Pith does not retry when a retry-after header or an error body asks " ++
            "for a longer wait.",
    },
    .{
        .path = "bash.output_lines_max",
        .description = "The whole lines that Pith keeps from the tail of a command's output.",
    },
    .{
        .path = "bash.output_bytes_max",
        .description = "The bytes that Pith keeps from the tail of a command's output.",
    },
    .{
        .path = "bash.timeout_ms",
        .description = "The time that a command runs before Pith stops it. A per-call " ++
            "argument overrides it, and 0 means no limit.",
    },
    .{
        .path = "cache.anthropic_retention_ms",
        .description = "The prompt-cache retention that Pith assumes for an Anthropic model. " ++
            "Without the key, each model states its own, today 5 minutes. A value of 0 " ++
            "turns the stale-cache warning off.",
    },
    .{
        .path = "cache.openai_retention_ms",
        .description = "The prompt-cache retention that Pith assumes for an OpenAI model. " ++
            "Without the key, each model states its own, today 30 minutes. A value of 0 " ++
            "turns the stale-cache warning off.",
    },
    .{
        .path = "cache.warning_min_cost",
        .description = "The smallest extra input cost, in dollars, that arms the stale-cache " ++
            "warning. Pith starts a cheaper turn without a warning. The value must be a " ++
            "finite number of zero or more. A value that is too large for a double is not " ++
            "finite. Pith reports a value it cannot use and warns about every risk.",
    },
    .{
        .path = "default_models.anthropic_api",
        .description = "The model of the Anthropic API account. Use an Anthropic name." ++ new_project_only,
    },
    .{
        .path = "default_models.anthropic_subscription",
        .description = "The model of the Anthropic Subscription account. Use an Anthropic name." ++ new_project_only,
    },
    .{
        .path = "default_models.openai_api",
        .description = "The model of the OpenAI API account. Use an OpenAI name." ++ new_project_only,
    },
    .{
        .path = "default_models.openai_subscription",
        .description = "The model of the OpenAI Subscription account. Use an OpenAI name." ++ new_project_only,
    },
    .{
        .path = "default_models.anthropic_console",
        .description = "The model of the Anthropic Console account. Use an Anthropic name." ++ new_project_only,
    },
    .{
        .path = "default_effort",
        .description = "The reasoning effort that a session starts on. Pith folds a level " ++
            "that the model does not support onto the nearest one it does." ++ new_project_only,
    },
};

/// One leaf key of `File`, with its JSON type and its default. A null default
/// marks a required field inside an array entry.
const Leaf = struct {
    path: []const u8,
    type_name: []const u8,
    default_text: ?[]const u8,
};

/// Whether a field is a nested object rather than a leaf value. Every struct is
/// an object except `JsonString`, which is one string on the wire.
fn isSection(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and T != File.JsonString;
}

/// Whether a field is an array whose entries are objects with their own keys.
fn isObjectSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and isSection(pointer.child),
        else => false,
    };
}

/// The JSON type of a leaf field of `File`.
fn jsonTypeName(comptime T: type) []const u8 {
    const inner = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    const unsupported = "the config field type " ++ @typeName(inner) ++ " has no JSON type";
    return switch (@typeInfo(inner)) {
        .int => "integer",
        .float => "number",
        .pointer => "array",
        .@"struct" => if (inner == File.JsonString) "string" else @compileError(unsupported),
        else => @compileError(unsupported),
    };
}

/// The default of a leaf field, rendered for the document. A required field in
/// an array entry has no default and returns null.
fn maybeDefaultText(comptime field: std.builtin.Type.StructField) ?[]const u8 {
    const pointer = field.default_value_ptr orelse return null;
    const value = @as(*const field.type, @ptrCast(@alignCast(pointer))).*;
    return switch (@typeInfo(field.type)) {
        .int, .float => std.fmt.comptimePrint("{d}", .{value}),
        // "unset", never "none": `none` is itself a legal effort level, so that
        // word reads as a value rather than as the absence of one.
        .optional => if (value == null) "unset" else @compileError("expected a null default"),
        .pointer => if (value.len == 0) "empty" else @compileError("expected an empty default"),
        else => @compileError("the config field " ++ field.name ++ " has no printable default"),
    };
}

/// Every field in `File` and its object sections needs a default, because a
/// partial file must parse. Only a field inside an array entry can be required.
fn defaultText(comptime field: std.builtin.Type.StructField) []const u8 {
    return maybeDefaultText(field) orelse
        @compileError("the config field " ++ field.name ++ " declares no default");
}

/// Every leaf key of `File`, in declaration order. This walk is the drift guard:
/// it reads the shape off the struct that parses the file, so a new field cannot
/// reach a release undocumented.
const leaves: []const Leaf = blk: {
    var list: []const Leaf = &.{};
    for (@typeInfo(File).@"struct".fields) |field| {
        if (isSection(field.type)) {
            for (@typeInfo(field.type).@"struct".fields) |leaf| {
                list = list ++ [_]Leaf{.{
                    .path = field.name ++ "." ++ leaf.name,
                    .type_name = jsonTypeName(leaf.type),
                    .default_text = defaultText(leaf),
                }};
            }
            continue;
        }
        list = list ++ [_]Leaf{.{
            .path = field.name,
            .type_name = jsonTypeName(field.type),
            .default_text = defaultText(field),
        }};
        if (isObjectSlice(field.type)) {
            const child = @typeInfo(field.type).pointer.child;
            for (@typeInfo(child).@"struct".fields) |leaf| {
                list = list ++ [_]Leaf{.{
                    .path = field.name ++ "[]." ++ leaf.name,
                    .type_name = jsonTypeName(leaf.type),
                    .default_text = maybeDefaultText(leaf),
                }};
            }
        }
    }
    break :blk list;
};

/// The key list of the settings document, rendered from `leaves` and `keys`. A
/// leaf with no entry, a duplicate entry, and an entry that names no leaf are
/// all compile errors.
const key_lines = blk: {
    var text: []const u8 = "";
    var used = [_]bool{false} ** keys.len;
    for (leaves) |leaf| {
        var found = false;
        for (&keys, 0..) |key, index| {
            if (!std.mem.eql(u8, key.path, leaf.path)) continue;
            if (used[index]) @compileError("the settings document repeats the key " ++ key.path);
            used[index] = true;
            found = true;
            const requirement = if (leaf.default_text) |default|
                ", default: " ++ default ++ "."
            else
                ", required.";
            text = text ++ "- `" ++ leaf.path ++ "` — " ++ leaf.type_name ++
                requirement ++ " " ++ key.description ++ "\n";
        }
        if (!found)
            @compileError("the settings document has no entry for the key " ++ leaf.path);
    }
    for (used, keys) |matched, key| {
        if (!matched)
            @compileError("the settings document describes the unknown key " ++ key.path);
    }
    break :blk text;
};

/// Join `list` into one comma-separated line for the document.
fn joinNames(comptime list: []const []const u8) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (list, 0..) |name, index| {
            if (index > 0) text = text ++ ", ";
            text = text ++ name;
        }
        return text;
    }
}

const effort_levels = blk: {
    var list: []const []const u8 = &.{};
    for (@typeInfo(ai.llm.Effort).@"enum".fields) |field| {
        list = list ++ [_][]const u8{field.name};
    }
    break :blk joinNames(list);
};

/// The example that the document carries. A test parses it back through the
/// loader and proves that every key resolves, so the example cannot go stale.
const example =
    \\{
    \\  "user_instructions": [{ "path": "instructions.md" }],
    \\  "request": { "idle_timeout_ms": 90000 },
    \\  "bash": { "timeout_ms": 300000 },
    \\  "cache": { "openai_retention_ms": 600000, "warning_min_cost": 0.05 },
    \\  "default_models": { "anthropic_subscription": "claude-opus-5" },
    \\  "default_effort": "high"
    \\}
;

/// The key list of the document. It is a compiled constant, so the document
/// costs no work at startup beyond one format call.
const keys_section = "\n## Keys\n\n" ++ key_lines;

const anthropic_names = joinNames(ai.models.names(.anthropic));
const openai_names = joinNames(ai.models.names(.openai));

/// The fallbacks that the app compiles in. A key that names none of them leaves
/// the value to these, so the document must state them. The app owns them,
/// because it owns the account and the effort level that a session starts on.
pub const SettingsOptions = struct {
    anthropic_model: []const u8,
    openai_model: []const u8,
    effort: ai.llm.Effort,
};

/// Build what the `config` tool returns. The document names the real file, so
/// the model edits the path that Pith reads, and the summary names that same
/// file in the transcript box. The caller owns both strings and frees them with
/// `freeSettings`.
pub fn settings(
    self: *const Config,
    gpa: std.mem.Allocator,
    options: *const SettingsOptions,
) !ai.tool.Context.Settings {
    const document = try self.settingsDocument(gpa, options);
    errdefer gpa.free(document);
    return .{ .document = document, .summary = try std.fmt.allocPrint(
        gpa,
        "File: {s}",
        .{self.path},
    ) };
}

/// Free what `settings` returned.
pub fn freeSettings(gpa: std.mem.Allocator, value: *const ai.tool.Context.Settings) void {
    gpa.free(value.document);
    gpa.free(value.summary);
}

/// Render the settings document: a compiled key list between a header that names
/// the real file and a section that states the fallbacks the app compiles in.
fn settingsDocument(
    self: *const Config,
    gpa: std.mem.Allocator,
    options: *const SettingsOptions,
) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\# Pith settings
        \\
        \\Pith reads {s} once, at startup. A change to that file applies at
        \\the next start of Pith, and never to the session that runs now. Tell the user so.
        \\
        \\The file is optional, so create it when it is absent. Any subset of the keys below is
        \\valid, and an absent key keeps its default. A dot shows a nested JSON object. Empty
        \\brackets show each array entry. Pith ignores a key that it does not know, so a typo has
        \\no effect. The next start still succeeds and shows a warning that names each ignored key.
        \\The file holds no secret. An API key comes from the ANTHROPIC_API_KEY or the
        \\OPENAI_API_KEY variable.
        \\{s}
        \\## Models and effort
        \\
        \\- An Anthropic account takes one of: {s}. Without a key, Pith uses {s}.
        \\- An OpenAI account takes one of: {s}. Without a key, Pith uses {s}.
        \\- `default_effort` takes one of: {s}. Without the key, Pith uses {s}.
        \\- Pith remembers the model and the effort level of each project in a separate state
        \\  file, and that memory outranks this file. Only the /model and the /effort command
        \\  change a project that Pith already ran in.
        \\
        \\## Example
        \\
        \\```json
        \\{s}
        \\```
        \\
    , .{
        self.path,
        keys_section,
        anthropic_names,
        options.anthropic_model,
        openai_names,
        options.openai_model,
        effort_levels,
        @tagName(options.effort),
        example,
    });
}

/// Free the path, the user instruction files, their messages, the
/// dropped-default names, and the unknown keys.
pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
    gpa.free(self.path);
    self.user_instructions.deinit();
    for (self.dropped_models) |dropped| gpa.free(dropped.name);
    gpa.free(self.dropped_models);
    if (self.dropped_effort) |name| gpa.free(name);
    if (self.dropped_cost) |text| gpa.free(text);
    for (self.unknown_keys) |key| gpa.free(key);
    gpa.free(self.unknown_keys);
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
        // An absent file is the built-in default, and it still names its path.
        // The settings document then tells the model where to create it.
        error.FileNotFound => return .{
            .path = try gpa.dupe(u8, path),
            .user_instructions = .init(gpa, .user),
        },
        else => return err,
    };
    defer gpa.free(data);
    return loadFromData(gpa, io, &.{ .directory = directory, .path = path, .data = data });
}

/// Build the config from the bytes of `config.json` and fold each section into
/// the neutral option structs. This also reads every configured user instruction
/// file, so it needs `io`. Only a malformed file fails the load. A path Pith
/// cannot use becomes a message, so a bad entry never stops pith.
fn loadFromData(gpa: std.mem.Allocator, io: std.Io, options: *const DataOptions) !Config {
    const source = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        options.data,
        .{ .parse_numbers = false },
    );
    defer source.deinit();
    const parsed = try std.json.parseFromValue(
        File,
        gpa,
        source.value,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const request = parsed.value.request;
    const bash = parsed.value.bash;
    const cache = parsed.value.cache;
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
    var dropped_cost: ?[]const u8 = null;
    errdefer if (dropped_cost) |text| gpa.free(text);
    const warning_min_cost = try resolveCost(
        gpa,
        &dropped_cost,
        &source.value,
        cache.warning_min_cost,
    );
    var unknown: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unknown.items) |key| gpa.free(key);
        unknown.deinit(gpa);
    }
    const unknown_keys_omitted = try collectUnknownKeys(gpa, &source.value, &unknown);
    const owned_path = try gpa.dupe(u8, options.path);
    errdefer gpa.free(owned_path);
    // Take the owned slices before the literal. A `try` inside it can fail after
    // an earlier field already took its list, and that list frees nothing then.
    const unknown_keys = try unknown.toOwnedSlice(gpa);
    errdefer {
        for (unknown_keys) |key| gpa.free(key);
        gpa.free(unknown_keys);
    }
    const dropped_models = try dropped.toOwnedSlice(gpa);
    return .{
        .path = owned_path,
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
        .cache = .{
            .anthropic_retention_ms = cache.anthropic_retention_ms,
            .openai_retention_ms = cache.openai_retention_ms,
            .warning_min_cost = warning_min_cost,
        },
        .default_models = default_models,
        .default_effort = default_effort,
        .user_instructions = user_instructions,
        .dropped_models = dropped_models,
        .dropped_effort = dropped_effort,
        .dropped_cost = dropped_cost,
        .unknown_keys = unknown_keys,
        .unknown_keys_omitted = unknown_keys_omitted,
    };
}

/// Collect every object key that the typed config ignores. The parsed value is
/// also the source of the typed config, so syntax and allocation errors cannot
/// disappear in a diagnostic-only parse. Returns true after the retained-key
/// cap hides at least one key.
fn collectUnknownKeys(
    gpa: std.mem.Allocator,
    source: *const std.json.Value,
    out: *std.ArrayList([]const u8),
) !bool {
    std.debug.assert(source.* == .object);
    for (source.object.keys(), source.object.values()) |name, *value| {
        var known = false;
        inline for (@typeInfo(File).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                known = true;
                if (comptime isSection(field.type)) {
                    if (try collectUnknownSection(field.type, gpa, value, name, out)) return true;
                } else if (comptime isObjectSlice(field.type)) {
                    const child = @typeInfo(field.type).pointer.child;
                    if (try collectUnknownEntries(child, gpa, value, name, out)) return true;
                }
            }
        }
        if (!known and try appendUnknownKey(gpa, out, "{s}", .{name})) return true;
    }
    return false;
}

/// Collect unknown direct fields from one configured object section.
fn collectUnknownSection(
    comptime T: type,
    gpa: std.mem.Allocator,
    source: *const std.json.Value,
    name: []const u8,
    out: *std.ArrayList([]const u8),
) !bool {
    std.debug.assert(source.* == .object);
    for (source.object.keys()) |field| {
        if (hasField(T, field)) continue;
        if (try appendUnknownKey(gpa, out, "{s}.{s}", .{ name, field })) return true;
    }
    return false;
}

/// Collect unknown direct fields from every object in one configured array. The
/// typed parse validated the array, so its length bounds the loop and every
/// entry is an object, even one past the instruction-file cap.
fn collectUnknownEntries(
    comptime T: type,
    gpa: std.mem.Allocator,
    source: *const std.json.Value,
    name: []const u8,
    out: *std.ArrayList([]const u8),
) !bool {
    std.debug.assert(source.* == .array);
    for (source.array.items, 0..) |*entry, index| {
        std.debug.assert(entry.* == .object);
        for (entry.object.keys()) |field| {
            if (hasField(T, field)) continue;
            if (try appendUnknownKey(
                gpa,
                out,
                "{s}[{d}].{s}",
                .{ name, index, field },
            )) return true;
        }
    }
    return false;
}

/// Whether `T` has the configured field `name`.
fn hasField(comptime T: type, name: []const u8) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

/// Retain one formatted unknown key. Returns true instead when the cap is full.
fn appendUnknownKey(
    gpa: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    comptime format: []const u8,
    args: anytype,
) !bool {
    if (out.items.len == unknown_keys_max) return true;
    const path = try std.fmt.allocPrint(gpa, format, args);
    errdefer gpa.free(path);
    try out.append(gpa, path);
    return false;
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

/// Resolve the configured cache warning cost. A floor below zero states nothing,
/// and an unbounded one (a literal like 1e400 parses to infinity) silences every
/// warning. Both fall back to the built-in floor. The function also records the
/// line in `dropped` so the app can surface it.
fn resolveCost(
    gpa: std.mem.Allocator,
    dropped: *?[]const u8,
    source: *const std.json.Value,
    configured: f64,
) !f64 {
    if (std.math.isFinite(configured) and configured >= 0) return configured;
    dropped.* = try dupeConfiguredCost(gpa, source, configured);
    return cache_default.warning_min_cost;
}

/// The text of `cache.warning_min_cost` as the user wrote it, duped for the
/// report. The load keeps every number as text, so the report can quote the line
/// instead of a value that already rounded to `inf`. A value the walk cannot
/// find falls back to the parsed number.
fn dupeConfiguredCost(
    gpa: std.mem.Allocator,
    source: *const std.json.Value,
    configured: f64,
) ![]const u8 {
    const maybe_written: ?[]const u8 = written: {
        if (source.* != .object) break :written null;
        const section = source.object.get("cache") orelse break :written null;
        if (section != .object) break :written null;
        const value = section.object.get("warning_min_cost") orelse break :written null;
        break :written switch (value) {
            .number_string => |text| text,
            else => null,
        };
    };
    if (maybe_written) |written| return gpa.dupe(u8, written);
    return std.fmt.allocPrint(gpa, "{d}", .{configured});
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

/// The compiled fallbacks that the app passes in. The values only have to be
/// legal, because the document quotes them and never resolves them.
const settings_options_for_test: SettingsOptions = .{
    .anthropic_model = "claude-opus-5",
    .openai_model = "gpt-5.6-sol",
    .effort = .xhigh,
};

/// Whether `path` names a leaf key of `File`. Only the tests read `leaves`
/// through it, to prove the walk reached sections and array entries.
fn isLeafPath(path: []const u8) bool {
    for (leaves) |leaf| {
        if (std.mem.eql(u8, leaf.path, path)) return true;
    }
    return false;
}

fn loadDataForTest(data: []const u8) !Config {
    return loadFromData(std.testing.allocator, std.testing.io, &.{
        .directory = "/unused",
        .path = "/unused/config.json",
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

test "load reads the cache section" {
    var config = try loadDataForTest(
        \\{ "cache": { "anthropic_retention_ms": 0, "openai_retention_ms": 600000,
        \\  "warning_min_cost": 0.05 } }
    );
    defer config.deinit(std.testing.allocator);
    // Zero is a real override that turns the warning off, so it must survive as
    // a value and not read as an unset key.
    try std.testing.expectEqual(@as(?u64, 0), config.cache.anthropic_retention_ms);
    try std.testing.expectEqual(@as(?u64, 600_000), config.cache.openai_retention_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), config.cache.warning_min_cost, 1e-9);

    // Without the section, no retention is overridden and every risk warns.
    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(empty.cache.anthropic_retention_ms == null);
    try std.testing.expect(empty.cache.openai_retention_ms == null);
    try std.testing.expectEqual(@as(f64, 0), empty.cache.warning_min_cost);
}

test "a cost floor Pith cannot use falls back to zero and is reported" {
    // A negative floor states nothing, so the load keeps the line for the report
    // and warns about every risk again.
    var negative = try loadDataForTest(
        \\{ "cache": { "warning_min_cost": -0.5 } }
    );
    defer negative.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0), negative.cache.warning_min_cost);
    try std.testing.expectEqualStrings("-0.5", negative.dropped_cost.?);

    // An infinite one suppresses every warning in silence, which is the opposite
    // of what the key is for. The report quotes the line, not the parsed `inf`.
    var unbounded = try loadDataForTest(
        \\{ "cache": { "warning_min_cost": 1e400 } }
    );
    defer unbounded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0), unbounded.cache.warning_min_cost);
    try std.testing.expectEqualStrings("1e400", unbounded.dropped_cost.?);

    // A retention counts milliseconds, so the parse itself refuses a negative
    // one and one past the counter.
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "cache": { "anthropic_retention_ms": -1 } }
    ));
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "cache": { "openai_retention_ms": 99999999999999999999 } }
    ));

    // Zero stays legal on both keys, and it drops nothing.
    var config = try loadDataForTest(
        \\{ "cache": { "anthropic_retention_ms": 0, "warning_min_cost": 0 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 0), config.cache.anthropic_retention_ms);
    try std.testing.expectEqual(@as(f64, 0), config.cache.warning_min_cost);
    try std.testing.expect(config.dropped_cost == null);
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

test "load applies the known keys and reports the unknown ones" {
    var config = try loadDataForTest(
        \\{ "request": { "connect_timeout_ms": 42, "connect_timeout": 9 },
        \\  "user_instructions": [{ "path": "missing.md", "pth": "other.md" }],
        \\  "future": { "x": 1 }, "default_effot": "high" }
    );
    defer config.deinit(std.testing.allocator);
    // An unknown key never stops the load, so every known key still applies.
    try std.testing.expectEqual(@as(u64, 42), config.timeouts.connect_ms);
    // Misspelled section, entry, and top-level keys all report. An unknown
    // section reports once, not once per nested key.
    try std.testing.expectEqual(@as(usize, 4), config.unknown_keys.len);
    try std.testing.expectEqualStrings("request.connect_timeout", config.unknown_keys[0]);
    try std.testing.expectEqualStrings("user_instructions[0].pth", config.unknown_keys[1]);
    try std.testing.expectEqualStrings("future", config.unknown_keys[2]);
    try std.testing.expectEqualStrings("default_effot", config.unknown_keys[3]);
    try std.testing.expect(!config.unknown_keys_omitted);
}

test "the unknown-key report is bounded" {
    var data: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data.deinit();
    try data.writer.writeAll("{");
    for (0..unknown_keys_max + 5) |index| {
        if (index > 0) try data.writer.writeAll(",");
        try data.writer.print("\"key{d}\":1", .{index});
    }
    try data.writer.writeAll("}");

    var config = try loadDataForTest(data.written());
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, unknown_keys_max), config.unknown_keys.len);
    try std.testing.expect(config.unknown_keys_omitted);
}

test "the scan reaches an entry past the instruction-file cap" {
    var data: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data.deinit();
    try data.writer.writeAll(
        \\{ "user_instructions": [
    );
    // The loader inspects at most `files_max + 1` entries. One entry past that
    // cap carries the only typo, so it reports only when the scan is unbounded.
    for (0..ai.instructions.files_max + 1) |index| {
        try data.writer.print("{{\"path\":\"f{d}.md\"}},", .{index});
    }
    try data.writer.writeAll(
        \\{ "path": "last.md", "typo": 1 }] }
    );

    var config = try loadDataForTest(data.written());
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), config.unknown_keys.len);
    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint("user_instructions[{d}].typo", .{ai.instructions.files_max + 1}),
        config.unknown_keys[0],
    );
    try std.testing.expect(!config.unknown_keys_omitted);
}

test "the settings document describes every key of the file, and only those" {
    // `leaves` walks `File` and `key_lines` pairs each leaf with its prose, so
    // both are compile errors when they disagree. This test proves the walk
    // reached object sections and array entries.
    try std.testing.expectEqual(@as(usize, keys.len), leaves.len);
    try std.testing.expect(isLeafPath("bash.timeout_ms"));
    try std.testing.expect(isLeafPath("default_effort"));
    try std.testing.expect(isLeafPath("user_instructions[].path"));
    try std.testing.expect(!isLeafPath("bash"));
    try std.testing.expect(!isLeafPath("nope"));
    try std.testing.expect(hasField(File.Request, "attempts_max"));
    try std.testing.expect(!hasField(File.Request, "nope"));

    // Every documented default is the one the struct declares.
    try std.testing.expect(std.mem.indexOf(
        u8,
        key_lines,
        std.fmt.comptimePrint("integer, default: {d}", .{bash_default.timeout_ms}),
    ) != null);
}

test "the settings document names the file and its own example loads clean" {
    const gpa = std.testing.allocator;
    var config = try loadDataForTest("{}");
    defer config.deinit(gpa);

    const value = try config.settings(gpa, &settings_options_for_test);
    defer freeSettings(gpa, &value);
    const document = value.document;
    try std.testing.expect(std.mem.indexOf(u8, document, "/unused/config.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "`bash.timeout_ms`") != null);
    // A multi-line document needs a box summary, because the first line of the
    // document is a heading and says nothing to the user.
    try std.testing.expectEqualStrings("File: /unused/config.json", value.summary);
    // The compiled model table and effort enum feed the document, so a new model
    // or level cannot go missing from it.
    try std.testing.expect(std.mem.indexOf(u8, document, "claude-sonnet-4-6") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "gpt-5.6-luna") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "none, low, medium, high") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        document,
        "`user_instructions[].path` — string, required.",
    ) != null);

    // An unset key reads as "unset", never as "none". The word `none` is itself
    // an effort level, so it reads as a value rather than as no value.
    try std.testing.expect(std.mem.indexOf(u8, document, "`default_effort` — string, " ++
        "default: unset.") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "default: none") == null);

    // The app's compiled fallbacks reach the document, so a key left out never
    // looks like it has no value at all.
    try std.testing.expect(std.mem.indexOf(u8, document, "Without a key, Pith uses " ++
        "claude-opus-5.") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "Without a key, Pith uses " ++
        "gpt-5.6-sol.") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "Without the key, Pith uses " ++
        "xhigh.") != null);

    // An unknown key warns at the next start and never fails it. The document
    // states both facts, so the model does not have to guess which one holds.
    try std.testing.expect(std.mem.indexOf(u8, document, "still succeeds") != null);

    // The remembered per-project choice outranks the file, so the warning sits on
    // every key it governs. A reader that misses it promises an inert change.
    try std.testing.expect(std.mem.indexOf(u8, document, "outranks this file") != null);
    try std.testing.expectEqual(
        @as(usize, 6),
        std.mem.count(u8, document, new_project_only),
    );

    // A description states behavior that the key name does not imply, so a
    // reader never has to derive it and cannot derive it wrong.
    try std.testing.expect(std.mem.indexOf(u8, document, "retry-after") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "keepalive") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "folds a level") != null);
    // The instruction caps come from the loader that enforces them.
    try std.testing.expect(std.mem.indexOf(u8, document, std.fmt.comptimePrint(
        "at most {d} files",
        .{ai.instructions.files_max},
    )) != null);

    // The example the document shows must load with nothing unknown and nothing
    // dropped, so the model never copies a stale shape out of it.
    var from_example = try loadDataForTest(example);
    defer from_example.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), from_example.unknown_keys.len);
    try std.testing.expectEqual(@as(usize, 0), from_example.dropped_models.len);
    try std.testing.expect(from_example.dropped_effort == null);
    try std.testing.expectEqual(ai.llm.Effort.high, from_example.default_effort.?);
    try std.testing.expectEqual(@as(u64, 90_000), from_example.timeouts.idle_ms);
    try std.testing.expectEqual(@as(u64, 300_000), from_example.bash.timeout_ms);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        from_example.default_models.get(.anthropic_subscription).?.name,
    );
}

test "load resolves user instruction paths against the config directory in order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pith_directory = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    defer pith_directory.close(io);
    // The `\u002e` escape is the `.` of `second.md`. It proves that the parsed
    // value and the typed parser preserve a decoded path.
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
    try std.testing.expect(config.dropped_cost != null);
    try std.testing.expectEqual(@as(usize, 1), config.unknown_keys.len);
    const value = try config.settings(gpa, &settings_options_for_test);
    defer freeSettings(gpa, &value);
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
        \\  "default_models": { "openai_api": "nope" }, "default_effort": "nope",
        \\  "cache": { "warning_min_cost": -1 }, "unknown": 1 }
        ,
    });
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    try std.testing.checkAllAllocationFailures(gpa, checkLoadAllocationFailure, .{ io, home });
}
