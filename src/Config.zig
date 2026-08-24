//! The global configuration loaded from `<home>/.drinky/config.json`. The file is
//! optional and can be partial. An absent file, section, or field falls back to a
//! built-in default. Drinky ignores unknown keys, so an older binary can read a
//! newer file. The `File` struct below is the authoritative shape and default for
//! every key. More sections join it as the harness grows. It carries no secrets.
//! API keys come from the environment.
//!
//! The load also reads the user instruction files that the file names, through
//! `ai.instructions`, so the config owns their content for the session.

const std = @import("std");

const ai = @import("ai");

const layout = @import("layout.zig");
const ui = @import("ui/root.zig");

const Config = @This();

/// The absolute path of `config.json`, present whether or not the file exists.
/// The config document and the notices name it, so the user and the model both
/// read the same path. Owned. `deinit` frees it.
path: []const u8,
timeouts: ai.net.ProviderTimeouts = .{},
retry: ai.net.Retry = .{},
bash: ai.tool.Context.Bash = .{},
/// The pages of the newest conversation that one frame retains. A count outside
/// the window that the layout accepts falls back to the compiled count.
window_pages: usize = layout.window_pages_default,
/// The shares at which a status gauge takes the warning color and the error
/// color. A pair that names no valid shares falls back to the compiled pair.
gauge: ui.status.Gauge = .{},
default_models: DefaultModels = .{},
/// The configured default reasoning-effort level, or null when the file names
/// none or names an unknown level. The caller falls back to a compiled default.
default_effort: ?ai.llm.Effort = null,
/// The user instruction files that `config.json` names, in the configured order,
/// with the messages the load produced. Owned.
user_instructions: ai.instructions.Result,
/// The path-triggered skills that `config.json` names, in the configured order.
/// The load resolves no name here, because the skill scan runs later. The app
/// pairs each entry with a discovered skill and reports one it cannot pair.
/// Owned. `deinit` frees them.
required_skills: []const RequiredSkill = &.{},
/// The configured default-model names that did not resolve (unknown, or a model
/// of the wrong vendor for their account). The config keeps them so the app can
/// tell the user Drinky ignored their line. Empty on the built-in default. Owned.
/// `deinit` frees them.
dropped_models: []const DroppedModel = &.{},
/// The configured default effort level that did not resolve. The config keeps it
/// so the app can tell the user Drinky ignored their line. Owned. `deinit` frees
/// it.
dropped_effort: ?[]const u8 = null,
/// The configured command timeout that Drinky cannot use, in milliseconds. The
/// config keeps it so the app can tell the user Drinky ignored their line, and the
/// bash tool falls back to the built-in timeout. Null on a legal value.
dropped_bash_timeout_ms: ?u64 = null,
/// The configured page count that Drinky cannot use. The config keeps it so the
/// app can tell the user Drinky ignored their line, and the frame falls back to
/// the compiled count. Null on a legal value.
dropped_window_pages: ?usize = null,
/// The gauge shares that Drinky cannot use, as the load resolved them. The file
/// can state one share alone, and the other is then the compiled one. The config
/// keeps the pair so the app can tell the user Drinky ignored their line, and the
/// status line falls back to the compiled pair. The two shares hold one rule
/// between them, so they drop together. Null on a legal pair.
dropped_gauge: ?ui.status.Gauge = null,
/// Whether the file held an empty bash deny pattern. Drinky drops it, because an
/// empty pattern states no command. The config keeps the fact so the app can
/// tell the user Drinky ignored the entry.
dropped_deny_empty: bool = false,
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

/// One configured path-triggered skill: the path glob and the name of the skill
/// that a matching file requires. Owns both strings (duped out of the parsed
/// file).
pub const RequiredSkill = struct {
    glob: []const u8,
    skill: []const u8,
};

/// The on-disk shape. Each field defaults to the built-in, so any subset parses.
const File = struct {
    user_instructions: []const File.UserInstruction = &.{},
    required_skills: []const File.RequiredSkill = &.{},
    request: Request = .{},
    bash: Bash = .{},
    interface: Interface = .{},
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
    /// `<home>/.drinky/`.
    const UserInstruction = struct {
        path: JsonString,
    };

    /// One configured path-triggered skill. The glob measures against the path
    /// relative to the working directory.
    const RequiredSkill = struct {
        glob: JsonString,
        skill: JsonString,
    };

    const Request = struct {
        // The connect timeout depends on the network, not on the provider, so
        // both providers share it and either default serves.
        connect_timeout_ms: u64 = timeouts_default.anthropic.connect_ms,
        anthropic_idle_timeout_ms: u64 = timeouts_default.anthropic.idle_ms,
        openai_idle_timeout_ms: u64 = timeouts_default.openai.idle_ms,
        attempts_max: u32 = retry_default.attempts_max,
        backoff_ms_initial: u64 = retry_default.backoff_ms_initial,
        backoff_ms_max: u64 = retry_default.backoff_ms_max,
    };

    const Bash = struct {
        output_lines_max: usize = bash_default.lines_max,
        output_bytes_max: usize = bash_default.bytes_max,
        timeout_ms: u64 = bash_default.timeout_ms,
        deny: []const JsonString = &.{},
    };

    /// How much of the conversation one frame retains, and where a status gauge
    /// leaves the muted role. A value outside its window states an interface
    /// that Drinky cannot paint, so the load reports it and keeps the default.
    const Interface = struct {
        window_pages: usize = layout.window_pages_default,
        gauge_percent_warning: f64 = gauge_default.percent_warning,
        gauge_percent_error: f64 = gauge_default.percent_error,
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

const timeouts_default: ai.net.ProviderTimeouts = .{};
const retry_default: ai.net.Retry = .{};
const bash_default: ai.tool.Context.Bash = .{};
const gauge_default: ui.status.Gauge = .{};

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
            "The instruction files that Drinky loads into every system prompt, in this order. " ++
                "Drinky loads at most {d} files, {d} KiB in total, and {d} KiB from one file.",
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
        .path = "required_skills",
        .description = std.fmt.comptimePrint(
            "The skills that a file requires. Before the write tool or the edit tool " ++
                "changes a file that an entry matches, the whole skill file of that entry " ++
                "must be in the conversation. Drinky applies at most {d} entries.",
            .{ai.tool.SkillGuard.rules_max},
        ),
    },
    .{
        .path = "required_skills[].glob",
        .description = "The path pattern of one entry. Drinky measures it against the path " ++
            "relative to the working directory, and against the absolute path. A `*` and a " ++
            "`?` match inside one path segment, and a `**` segment matches across segments.",
    },
    .{
        .path = "required_skills[].skill",
        .description = "The name of the skill that the pattern requires. Drinky reports a " ++
            "name that no discovered skill carries, and applies no rule for it.",
    },
    .{
        .path = "request.connect_timeout_ms",
        .description = "The time that Drinky waits for the head of a provider response.",
    },
    .{
        .path = "request.anthropic_idle_timeout_ms",
        .description = "The time that Drinky waits between two streamed Anthropic events. A " ++
            "keepalive ping is not an event and does not restart the wait.",
    },
    .{
        .path = "request.openai_idle_timeout_ms",
        .description = "The time that Drinky waits between two streamed OpenAI events. The " ++
            "stream is silent while the model reasons privately, so the default matches " ++
            "the wait of the official client.",
    },
    .{
        .path = "request.attempts_max",
        .description = "The number of times that Drinky sends one request before it fails.",
    },
    .{
        .path = "request.backoff_ms_initial",
        .description = "The wait before the second attempt. Each further wait doubles it.",
    },
    .{
        .path = "request.backoff_ms_max",
        .description = "The upper bound on one wait between attempts. It caps the doubling " ++
            "above. Drinky does not retry when a retry-after header or an error body asks " ++
            "for a longer wait.",
    },
    .{
        .path = "bash.output_lines_max",
        .description = "The whole lines that Drinky keeps from the tail of a command's output.",
    },
    .{
        .path = "bash.output_bytes_max",
        .description = "The bytes that Drinky keeps from the tail of a command's output.",
    },
    .{
        .path = "bash.timeout_ms",
        .description = std.fmt.comptimePrint(
            "The time that a command runs before Drinky stops it. A per-call argument " ++
                "overrides it. Every command runs under a limit, so the value must be from " ++
                "{d} to {d}. Drinky reports a value it cannot use and keeps the default.",
            .{ ai.tool.Context.Bash.timeout_ms_min, ai.tool.Context.Bash.timeout_ms_max },
        ),
    },
    .{
        .path = "bash.deny",
        .description = "The literal patterns that deny a command. The bash tool refuses a " ++
            "command that contains one of the entries, and the refusal names that entry. " ++
            "Drinky ignores an empty entry and names each kept entry in the system prompt.",
    },
    .{
        .path = "interface.window_pages",
        .description = std.fmt.comptimePrint(
            "The pages of the newest conversation that Drinky keeps on the screen. One page " ++
                "is one window height. Every frame measures and paints each kept row again, " ++
                "so a higher count keeps more of the conversation and costs more work per " ++
                "frame. The count must be from {d} to {d}. Drinky reports a value it cannot " ++
                "use and keeps the default.",
            .{ layout.window_pages_min, layout.window_pages_max },
        ),
    },
    .{
        .path = "interface.gauge_percent_warning",
        .description = std.fmt.comptimePrint(
            "The used share at which the context gauge and a quota window take the warning " ++
                "color. The share must be from {d} to {d}, and it must not pass the error " ++
                "share. Drinky reports a pair it cannot use and keeps both compiled shares.",
            .{ ui.status.Gauge.percent_min, ui.status.Gauge.percent_max },
        ),
    },
    .{
        .path = "interface.gauge_percent_error",
        .description = std.fmt.comptimePrint(
            "The used share at which the context gauge and a quota window take the error " ++
                "color. The share must be from {d} to {d}. Drinky reports a pair it cannot " ++
                "use and keeps both compiled shares.",
            .{ ui.status.Gauge.percent_min, ui.status.Gauge.percent_max },
        ),
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
        .description = "The reasoning effort that a session starts on. Drinky folds a level " ++
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

/// The key list of the config document, rendered from `leaves` and `keys`. A
/// leaf with no entry, a duplicate entry, and an entry that names no leaf are
/// all compile errors.
const key_lines = blk: {
    // The walk pairs every leaf with every key, so its work grows with the
    // square of the key count. Each new key needs a little more room here.
    @setEvalBranchQuota(10_000);
    var text: []const u8 = "";
    var used = [_]bool{false} ** keys.len;
    for (leaves) |leaf| {
        var found = false;
        for (&keys, 0..) |key, index| {
            if (!std.mem.eql(u8, key.path, leaf.path)) continue;
            if (used[index]) @compileError("the config document repeats the key " ++ key.path);
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
            @compileError("the config document has no entry for the key " ++ leaf.path);
    }
    for (used, keys) |matched, key| {
        if (!matched)
            @compileError("the config document describes the unknown key " ++ key.path);
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
    \\  "required_skills": [{ "glob": "**/*.zig", "skill": "zig-style" }],
    \\  "request": { "anthropic_idle_timeout_ms": 90000 },
    \\  "bash": { "timeout_ms": 300000, "deny": ["git add"] },
    \\  "interface": { "window_pages": 12 },
    \\  "default_models": { "anthropic_subscription": "claude-opus-5" },
    \\  "default_effort": "high"
    \\}
;

/// The key list of the section. It is a compiled constant, so the section costs
/// no work at startup beyond one format call.
const keys_section = "\n### Keys\n\n" ++ key_lines;

const anthropic_names = joinNames(ai.models.names(.anthropic));
const openai_names = joinNames(ai.models.names(.openai));

/// The fallbacks that the app compiles in. A key that names none of them leaves
/// the value to these, so the document must state them. The app owns them,
/// because it owns the account and the effort level that a session starts on.
pub const DocumentOptions = struct {
    anthropic_model: []const u8,
    openai_model: []const u8,
    effort: ai.llm.Effort,
};

/// Build the configuration section of the document that the `describe_drinky`
/// tool returns: a compiled key list between a head and a part that states the
/// fallbacks the app compiles in. The head names the real file, so the model
/// edits the path that Drinky reads. The caller owns the text.
///
/// The tool shows no box line beside the call, so this measures nothing. The
/// document is the same text at every call, and a measure of it states nothing
/// that the user can act on.
pub fn document(
    self: *const Config,
    gpa: std.mem.Allocator,
    options: *const DocumentOptions,
) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\## Configuration
        \\
        \\Drinky reads {s} once, at startup. A change to that file applies at
        \\the next start of Drinky, and never to the session that runs now. Tell the user so.
        \\
        \\The file is optional, so create it when it is absent. Any subset of the keys below is
        \\valid, and an absent key keeps its default. A dot shows a nested JSON object. Empty
        \\brackets show each array entry. Drinky ignores a key that it does not know, so a typo has
        \\no effect. The next start still succeeds and shows a warning that names each ignored key.
        \\The file holds no secret. An API key comes from the ANTHROPIC_API_KEY or the
        \\OPENAI_API_KEY variable.
        \\{s}
        \\### Models and effort
        \\
        \\- An Anthropic account takes one of: {s}. Without a key, Drinky uses {s}.
        \\- An OpenAI account takes one of: {s}. Without a key, Drinky uses {s}.
        \\- `default_effort` takes one of: {s}. Without the key, Drinky uses {s}.
        \\- Drinky remembers the model and the effort level of each project in a separate state
        \\  file, and that memory outranks this file. Only the /model and the /effort command
        \\  change a project that Drinky already ran in.
        \\
        \\### Example
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

/// Free the path, the user instruction files, their messages, the required
/// skills, the bash deny patterns, the dropped-default names, and the unknown
/// keys.
pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
    gpa.free(self.path);
    self.user_instructions.deinit();
    for (self.required_skills) |required| {
        gpa.free(required.glob);
        gpa.free(required.skill);
    }
    gpa.free(self.required_skills);
    for (self.bash.deny) |pattern| gpa.free(pattern);
    gpa.free(self.bash.deny);
    for (self.dropped_models) |dropped| gpa.free(dropped.name);
    gpa.free(self.dropped_models);
    if (self.dropped_effort) |name| gpa.free(name);
    for (self.unknown_keys) |key| gpa.free(key);
    gpa.free(self.unknown_keys);
}

/// Load `<home>/.drinky/config.json`, or the built-in defaults when it is absent.
/// Every configured user instruction path resolves against `<home>/.drinky/`.
pub fn load(gpa: std.mem.Allocator, io: std.Io, options: *const LoadOptions) !Config {
    const directory = try std.fs.path.resolve(
        gpa,
        &.{ options.working_directory, options.home, ".drinky" },
    );
    defer gpa.free(directory);
    const path = try std.fs.path.join(gpa, &.{ directory, "config.json" });
    defer gpa.free(path);
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        // An absent file is the built-in default, and it still names its path.
        // The config document then tells the model where to create it.
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
/// file, so it needs `io`. Only a malformed file fails the load. A path Drinky
/// cannot use becomes a message, so a bad entry never stops Drinky.
fn loadFromData(gpa: std.mem.Allocator, io: std.Io, options: *const DataOptions) !Config {
    // Every number keeps its text, and the typed parse converts it exactly. A
    // dynamic parse would send a decimal or an exponent form through `f64`
    // first. The value `18446744073709551615.0` then rounds up past every
    // `u64`. The typed parse asserts that cast, so such a file would crash
    // Drinky. Drinky must report a value it cannot use instead.
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
    const interface = parsed.value.interface;
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

    var required: std.ArrayList(RequiredSkill) = .empty;
    errdefer {
        for (required.items) |item| {
            gpa.free(item.glob);
            gpa.free(item.skill);
        }
        required.deinit(gpa);
    }
    for (parsed.value.required_skills) |configured| {
        const owned_glob = try gpa.dupe(u8, configured.glob.value);
        errdefer gpa.free(owned_glob);
        const owned_skill = try gpa.dupe(u8, configured.skill.value);
        errdefer gpa.free(owned_skill);
        try required.append(gpa, .{ .glob = owned_glob, .skill = owned_skill });
    }

    var deny: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (deny.items) |pattern| gpa.free(pattern);
        deny.deinit(gpa);
    }
    var dropped_deny_empty = false;
    for (bash.deny) |configured| {
        // An empty pattern states no command, so it cannot deny one.
        if (configured.value.len == 0) {
            dropped_deny_empty = true;
            continue;
        }
        const owned = try gpa.dupe(u8, configured.value);
        errdefer gpa.free(owned);
        try deny.append(gpa, owned);
    }

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
    var dropped_bash_timeout_ms: ?u64 = null;
    const bash_timeout_ms = resolveBashTimeout(&dropped_bash_timeout_ms, bash.timeout_ms);
    var dropped_window_pages: ?usize = null;
    const window_pages = resolveWindowPages(&dropped_window_pages, interface.window_pages);
    var dropped_gauge: ?ui.status.Gauge = null;
    const gauge = resolveGauge(&dropped_gauge, &interface);
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
    errdefer {
        for (dropped_models) |item| gpa.free(item.name);
        gpa.free(dropped_models);
    }
    const required_skills = try required.toOwnedSlice(gpa);
    errdefer {
        for (required_skills) |item| {
            gpa.free(item.glob);
            gpa.free(item.skill);
        }
        gpa.free(required_skills);
    }
    const deny_patterns = try deny.toOwnedSlice(gpa);
    return .{
        .path = owned_path,
        .timeouts = .{
            .anthropic = .{
                .connect_ms = request.connect_timeout_ms,
                .idle_ms = request.anthropic_idle_timeout_ms,
            },
            .openai = .{
                .connect_ms = request.connect_timeout_ms,
                .idle_ms = request.openai_idle_timeout_ms,
            },
        },
        .retry = .{
            .attempts_max = request.attempts_max,
            .backoff_ms_initial = request.backoff_ms_initial,
            .backoff_ms_max = request.backoff_ms_max,
        },
        .bash = .{
            .lines_max = bash.output_lines_max,
            .bytes_max = bash.output_bytes_max,
            .timeout_ms = bash_timeout_ms,
            .deny = deny_patterns,
        },
        .window_pages = window_pages,
        .gauge = gauge,
        .default_models = default_models,
        .default_effort = default_effort,
        .user_instructions = user_instructions,
        .required_skills = required_skills,
        .dropped_models = dropped_models,
        .dropped_effort = dropped_effort,
        .dropped_bash_timeout_ms = dropped_bash_timeout_ms,
        .dropped_window_pages = dropped_window_pages,
        .dropped_gauge = dropped_gauge,
        .dropped_deny_empty = dropped_deny_empty,
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

/// Resolve the configured command timeout. Every command runs under a limit, so
/// a value outside the legal window states a wait that no command can take. Such
/// a value falls back to the built-in timeout, and the function records it in
/// `dropped` so the app can surface it.
fn resolveBashTimeout(dropped: *?u64, configured: u64) u64 {
    if (configured >= ai.tool.Context.Bash.timeout_ms_min and
        configured <= ai.tool.Context.Bash.timeout_ms_max)
        return configured;
    dropped.* = configured;
    return bash_default.timeout_ms;
}

/// Resolve the configured page count. A count of no page retains nothing, and a
/// count above the window costs work in every frame that no user sees. Such a
/// count falls back to the compiled count, and the function records it in
/// `dropped` so the app can surface it.
fn resolveWindowPages(dropped: *?usize, configured: usize) usize {
    if (configured >= layout.window_pages_min and configured <= layout.window_pages_max)
        return configured;
    dropped.* = configured;
    return layout.window_pages_default;
}

/// Resolve the configured gauge shares. Each share names a part of a limit, and
/// the warning color comes before the error color, so the warning share must not
/// pass the error share. A pair that breaks either rule falls back to the
/// compiled pair, and the function records it in `dropped` so the app can
/// surface it. The rule spans both shares, so the pair drops as one.
fn resolveGauge(dropped: *?ui.status.Gauge, configured: *const File.Interface) ui.status.Gauge {
    const gauge: ui.status.Gauge = .{
        .percent_warning = configured.gauge_percent_warning,
        .percent_error = configured.gauge_percent_error,
    };
    if (isShare(gauge.percent_warning) and isShare(gauge.percent_error) and
        gauge.percent_warning <= gauge.percent_error) return gauge;
    dropped.* = gauge;
    return gauge_default;
}

/// Whether `percent` names a share of a limit. A huge literal parses as an
/// infinity, and a quoted word can parse as a not-a-number value. Neither one
/// orders against a bound, so both fail here and drop.
fn isShare(percent: f64) bool {
    return percent >= ui.status.Gauge.percent_min and percent <= ui.status.Gauge.percent_max;
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
const document_options_for_test: DocumentOptions = .{
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
        \\{ "request": { "connect_timeout_ms": 1000, "anthropic_idle_timeout_ms": 2000,
        \\  "openai_idle_timeout_ms": 3000,
        \\  "attempts_max": 5, "backoff_ms_initial": 100, "backoff_ms_max": 900 } }
    );
    defer config.deinit(std.testing.allocator);
    // The shared connect bound reaches both providers.
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.anthropic.connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.openai.connect_ms);
    try std.testing.expectEqual(@as(u64, 2000), config.timeouts.anthropic.idle_ms);
    try std.testing.expectEqual(@as(u64, 3000), config.timeouts.openai.idle_ms);
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
    try std.testing.expect(config.dropped_bash_timeout_ms == null);
}

test "load reads the interface section" {
    var config = try loadDataForTest(
        \\{ "interface": { "window_pages": 3, "gauge_percent_warning": 60,
        \\  "gauge_percent_error": 80 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), config.window_pages);
    try std.testing.expectEqual(@as(f64, 60), config.gauge.percent_warning);
    try std.testing.expectEqual(@as(f64, 80), config.gauge.percent_error);
    try std.testing.expect(config.dropped_window_pages == null);
    try std.testing.expect(config.dropped_gauge == null);

    // Without the section the compiled interface applies.
    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(layout.window_pages_default, empty.window_pages);
    try std.testing.expectEqual(gauge_default.percent_warning, empty.gauge.percent_warning);
    try std.testing.expectEqual(gauge_default.percent_error, empty.gauge.percent_error);
    try std.testing.expect(empty.dropped_window_pages == null);
    try std.testing.expect(empty.dropped_gauge == null);
}

// A window of no page retains nothing, and a count above the window costs work
// in every frame that no user sees. Both keep the line for the report and fall
// back to the compiled count, as every other value Drinky cannot use does.
test "a page count Drinky cannot use falls back to the default and is reported" {
    const cases = [_]usize{ 0, layout.window_pages_max + 1, 100_000 };
    for (cases) |configured| {
        const data = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{ \"interface\": {{ \"window_pages\": {d} }} }}",
            .{configured},
        );
        defer std.testing.allocator.free(data);
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(layout.window_pages_default, config.window_pages);
        try std.testing.expectEqual(@as(?usize, configured), config.dropped_window_pages);
    }

    // Both edges of the window are legal counts, so neither is reported.
    const edges = [_]usize{ layout.window_pages_min, layout.window_pages_max };
    for (edges) |configured| {
        const data = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{ \"interface\": {{ \"window_pages\": {d} }} }}",
            .{configured},
        );
        defer std.testing.allocator.free(data);
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(configured, config.window_pages);
        try std.testing.expect(config.dropped_window_pages == null);
    }
}

// A share outside 0 to 100 names no part of a limit, and a warning share above
// the error share would hide the warning color. The pair holds one rule, so it
// drops as one and the report names both shares as the file states them.
test "gauge shares Drinky cannot use fall back to the compiled pair and are reported" {
    const cases = [_][]const u8{
        \\{ "interface": { "gauge_percent_warning": -20, "gauge_percent_error": 90 } }
        ,
        \\{ "interface": { "gauge_percent_warning": 75, "gauge_percent_error": 250 } }
        ,
        // A huge literal parses as an infinity, and a quoted word parses as a
        // not-a-number value. Neither one orders against a bound.
        \\{ "interface": { "gauge_percent_warning": 75, "gauge_percent_error": 1e999 } }
        ,
        \\{ "interface": { "gauge_percent_warning": "nan", "gauge_percent_error": 90 } }
        ,
        // The warning color comes first, so the warning share must not pass the
        // error share.
        \\{ "interface": { "gauge_percent_warning": 90, "gauge_percent_error": 40 } }
        ,
    };
    for (cases) |data| {
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(gauge_default.percent_warning, config.gauge.percent_warning);
        try std.testing.expectEqual(gauge_default.percent_error, config.gauge.percent_error);
        try std.testing.expect(config.dropped_gauge != null);
    }

    // The report names the pair the file states, so the user reads their own
    // line back.
    var config = try loadDataForTest(
        \\{ "interface": { "gauge_percent_warning": 90, "gauge_percent_error": 40 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 90), config.dropped_gauge.?.percent_warning);
    try std.testing.expectEqual(@as(f64, 40), config.dropped_gauge.?.percent_error);

    // Both edges and an equal pair are legal, so none of them is reported.
    var edges = try loadDataForTest(
        \\{ "interface": { "gauge_percent_warning": 0, "gauge_percent_error": 100 } }
    );
    defer edges.deinit(std.testing.allocator);
    try std.testing.expect(edges.dropped_gauge == null);
    var equal = try loadDataForTest(
        \\{ "interface": { "gauge_percent_warning": 50, "gauge_percent_error": 50 } }
    );
    defer equal.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 50), equal.gauge.percent_warning);
    try std.testing.expect(equal.dropped_gauge == null);
}

test "load reads the bash deny list and drops an empty pattern" {
    var config = try loadDataForTest(
        \\{ "bash": { "deny": ["git add", "", "git push"] } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), config.bash.deny.len);
    try std.testing.expectEqualStrings("git add", config.bash.deny[0]);
    try std.testing.expectEqualStrings("git push", config.bash.deny[1]);
    // The load keeps the fact, so the app can tell the user Drinky ignored the
    // empty entry.
    try std.testing.expect(config.dropped_deny_empty);

    // A pattern must be a JSON string.
    try std.testing.expectError(error.UnexpectedToken, loadDataForTest(
        \\{ "bash": { "deny": [3] } }
    ));
    try std.testing.expectError(error.UnexpectedToken, loadDataForTest(
        \\{ "bash": { "deny": "git add" } }
    ));

    // Without the key, no pattern denies a command.
    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.bash.deny.len);
    try std.testing.expect(!empty.dropped_deny_empty);
}

// Every command runs under a limit. A zero used to mean no limit, so a stale
// file still names one. The load keeps the line for the report and falls back to
// the built-in timeout.
test "a command timeout Drinky cannot use falls back to the default and is reported" {
    const cases = [_]u64{
        0,
        ai.tool.Context.Bash.timeout_ms_min - 1,
        ai.tool.Context.Bash.timeout_ms_max + 1,
    };
    for (cases) |configured| {
        const data = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{ \"bash\": {{ \"timeout_ms\": {d} }} }}",
            .{configured},
        );
        defer std.testing.allocator.free(data);
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(bash_default.timeout_ms, config.bash.timeout_ms);
        try std.testing.expectEqual(@as(?u64, configured), config.dropped_bash_timeout_ms);
    }

    // Both edges of the window are legal values, so neither is reported.
    const edges = [_]u64{ ai.tool.Context.Bash.timeout_ms_min, ai.tool.Context.Bash.timeout_ms_max };
    for (edges) |configured| {
        const data = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{ \"bash\": {{ \"timeout_ms\": {d} }} }}",
            .{configured},
        );
        defer std.testing.allocator.free(data);
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(configured, config.bash.timeout_ms);
        try std.testing.expect(config.dropped_bash_timeout_ms == null);
    }
}

// A count of milliseconds holds no sign, and one past the counter names a wait
// that no clock can hold. Such a file is malformed, so the load fails instead of
// a fallback that reports a value Drinky could not even read.
test "a configured number that no counter can hold fails the load" {
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "bash": { "timeout_ms": -1 } }
    ));
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "request": { "anthropic_idle_timeout_ms": 99999999999999999999 } }
    ));

    // A decimal or an exponent form counts milliseconds too. The load keeps the
    // text, so a value past the counter reports as one that Drinky cannot read.
    // Through a double it would round to 2^64 and crash the typed parse.
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "bash": { "timeout_ms": 1.8446744073709552e19 } }
    ));
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "request": { "openai_idle_timeout_ms": 18446744073709551616.0 } }
    ));

    // A whole count that such a form writes stays legal, and the bash timeout
    // holds it, because 300 seconds are inside the legal window.
    var config = try loadDataForTest(
        \\{ "bash": { "timeout_ms": 3e5 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 300_000), config.bash.timeout_ms);
    try std.testing.expect(config.dropped_bash_timeout_ms == null);
}

test "load fills missing fields and sections from defaults" {
    var partial = try loadDataForTest(
        \\{ "request": { "attempts_max": 7 } }
    );
    defer partial.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), partial.retry.attempts_max);
    try std.testing.expectEqual(
        timeouts_default.anthropic.connect_ms,
        partial.timeouts.anthropic.connect_ms,
    );
    try std.testing.expectEqual(retry_default.backoff_ms_initial, partial.retry.backoff_ms_initial);
    try std.testing.expectEqual(bash_default.lines_max, partial.bash.lines_max);
    try std.testing.expectEqual(bash_default.bytes_max, partial.bash.bytes_max);
    try std.testing.expectEqual(bash_default.timeout_ms, partial.bash.timeout_ms);

    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        timeouts_default.anthropic.idle_ms,
        empty.timeouts.anthropic.idle_ms,
    );
    try std.testing.expectEqual(timeouts_default.openai.idle_ms, empty.timeouts.openai.idle_ms);
    try std.testing.expectEqual(retry_default.attempts_max, empty.retry.attempts_max);
    try std.testing.expectEqual(@as(usize, 0), empty.user_instructions.files().len);
}

test "load reads the required skills in file order" {
    var config = try loadDataForTest(
        \\{ "required_skills": [{ "glob": "**/*.zig", "skill": "zig-style" },
        \\  { "glob": "src/**/*.ts", "skill": "ts-style" }] }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), config.required_skills.len);
    try std.testing.expectEqualStrings("**/*.zig", config.required_skills[0].glob);
    try std.testing.expectEqualStrings("zig-style", config.required_skills[0].skill);
    try std.testing.expectEqualStrings("src/**/*.ts", config.required_skills[1].glob);
    try std.testing.expectEqualStrings("ts-style", config.required_skills[1].skill);

    // An entry states both halves, and each one is a string. The load resolves
    // no name here, because the skill scan runs later.
    try std.testing.expectError(error.MissingField, loadDataForTest(
        \\{ "required_skills": [{ "glob": "**/*.zig" }] }
    ));
    try std.testing.expectError(error.UnexpectedToken, loadDataForTest(
        \\{ "required_skills": [{ "glob": "**/*.zig", "skill": ["zig-style"] }] }
    ));

    // Without the key no file requires a skill.
    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.required_skills.len);
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
    try std.testing.expectEqual(@as(u64, 42), config.timeouts.anthropic.connect_ms);
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

test "the config document describes every key of the file, and only those" {
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

test "the config document names the file and its own example loads clean" {
    const gpa = std.testing.allocator;
    var config = try loadDataForTest("{}");
    defer config.deinit(gpa);

    const text = try config.document(gpa, &document_options_for_test);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "/unused/config.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`bash.timeout_ms`") != null);
    // The compiled model table and effort enum feed the document, so a new model
    // or level cannot go missing from it.
    try std.testing.expect(std.mem.indexOf(u8, text, "claude-sonnet-4-6") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gpt-5.6-luna") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "none, low, medium, high") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "`user_instructions[].path` — string, required.",
    ) != null);

    // An unset key reads as "unset", never as "none". The word `none` is itself
    // an effort level, so it reads as a value rather than as no value.
    try std.testing.expect(std.mem.indexOf(u8, text, "`default_effort` — string, " ++
        "default: unset.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "default: none") == null);

    // The app's compiled fallbacks reach the document, so a key left out never
    // looks like it has no value at all.
    try std.testing.expect(std.mem.indexOf(u8, text, "Without a key, Drinky uses " ++
        "claude-opus-5.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Without a key, Drinky uses " ++
        "gpt-5.6-sol.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Without the key, Drinky uses " ++
        "xhigh.") != null);

    // An unknown key warns at the next start and never fails it. The document
    // states both facts, so the model does not have to guess which one holds.
    try std.testing.expect(std.mem.indexOf(u8, text, "still succeeds") != null);

    // The remembered per-project choice outranks the file, so the warning sits on
    // every key it governs. A reader that misses it promises an inert change.
    try std.testing.expect(std.mem.indexOf(u8, text, "outranks this file") != null);
    try std.testing.expectEqual(
        @as(usize, 6),
        std.mem.count(u8, text, new_project_only),
    );

    // A description states behavior that the key name does not imply, so a
    // reader never has to derive it and cannot derive it wrong.
    try std.testing.expect(std.mem.indexOf(u8, text, "retry-after") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "keepalive") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "folds a level") != null);
    // A bounded key states its window, so a reader knows which value Drinky
    // reports and drops.
    try std.testing.expect(std.mem.indexOf(u8, text, std.fmt.comptimePrint(
        "count must be from {d} to {d}",
        .{ layout.window_pages_min, layout.window_pages_max },
    )) != null);
    // The instruction caps come from the loader that enforces them.
    try std.testing.expect(std.mem.indexOf(u8, text, std.fmt.comptimePrint(
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
    try std.testing.expectEqual(@as(u64, 90_000), from_example.timeouts.anthropic.idle_ms);
    // The example touches one idle key, so the other keeps its own default.
    try std.testing.expectEqual(
        timeouts_default.openai.idle_ms,
        from_example.timeouts.openai.idle_ms,
    );
    try std.testing.expectEqual(@as(u64, 300_000), from_example.bash.timeout_ms);
    try std.testing.expectEqual(@as(usize, 12), from_example.window_pages);
    try std.testing.expectEqual(@as(usize, 1), from_example.bash.deny.len);
    try std.testing.expectEqualStrings("git add", from_example.bash.deny[0]);
    try std.testing.expect(!from_example.dropped_deny_empty);
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

    var drinky_directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer drinky_directory.close(io);
    // The `\u002e` escape is the `.` of `second.md`. It proves that the parsed
    // value and the typed parser preserve a decoded path.
    try drinky_directory.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{ "user_instructions": [
        \\  { "path": "second\u002emd" },
        \\  { "path": "first.md" },
        \\  { "path": "missing.md" }
        \\] }
        ,
    });
    try drinky_directory.writeFile(io, .{ .sub_path = "first.md", .data = "First.\n" });
    try drinky_directory.writeFile(io, .{ .sub_path = "second.md", .data = "Second.\n" });
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    const files = config.user_instructions.files();
    try std.testing.expectEqual(@as(usize, 2), files.len);
    const second_path = try std.fs.path.join(gpa, &.{ home, ".drinky", "second.md" });
    defer gpa.free(second_path);
    const first_path = try std.fs.path.join(gpa, &.{ home, ".drinky", "first.md" });
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

    var drinky_directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer drinky_directory.close(io);
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
    try drinky_directory.writeFile(io, .{ .sub_path = "config.json", .data = config_data });
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
    try std.testing.expectEqual(
        timeouts_default.anthropic.connect_ms,
        config.timeouts.anthropic.connect_ms,
    );
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
    try std.testing.expectEqual(@as(usize, 1), config.bash.deny.len);
    try std.testing.expect(config.dropped_deny_empty);
    try std.testing.expectEqual(@as(usize, 1), config.unknown_keys.len);
    const text = try config.document(gpa, &document_options_for_test);
    defer gpa.free(text);
}

test "the config load frees every partial allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var drinky_directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer drinky_directory.close(io);
    try drinky_directory.writeFile(io, .{ .sub_path = "first.md", .data = "First.\n" });
    try drinky_directory.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{ "user_instructions": [{ "path": "first.md" }, { "path": "missing.md" }],
        \\  "default_models": { "openai_api": "nope" }, "default_effort": "nope",
        \\  "bash": { "deny": ["git add", ""] }, "unknown": 1 }
        ,
    });
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    try std.testing.checkAllAllocationFailures(gpa, checkLoadAllocationFailure, .{ io, home });
}
