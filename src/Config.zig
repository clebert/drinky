const std = @import("std");

const ai = @import("ai");

const layout = @import("layout.zig");
const ui = @import("ui/root.zig");

const Config = @This();

path: []const u8,
timeouts: ai.net.ProviderTimeouts = .{},
retry: ai.net.Retry = .{},
bash: ai.tool.Context.Bash = .{},
window_pages: usize = layout.window_pages_default,
gauge: ui.status.Gauge = .{},
default_effort: ?ai.llm.Effort = null,
prompt_history_enabled: bool = false,
user_instructions: ai.instructions.Result,
required_skills: []const RequiredSkill = &.{},
dropped_effort: ?[]const u8 = null,
dropped_bash_timeout_ms: ?u64 = null,
dropped_window_pages: ?usize = null,
dropped_gauge: ?ui.status.Gauge = null,
unknown_keys: []const []const u8 = &.{},
unknown_keys_omitted: bool = false,

pub const RequiredSkill = struct {
    glob: []const u8,
    skill: []const u8,
};

const File = struct {
    user_instructions: []const File.UserInstruction = &.{},
    required_skills: []const File.RequiredSkill = &.{},
    request: Request = .{},
    bash: Bash = .{},
    interface: Interface = .{},
    default_effort: ?JsonString = null,
    prompt_history: PromptHistory = .{},

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

    const UserInstruction = struct {
        path: JsonString,
    };

    const RequiredSkill = struct {
        glob: JsonString,
        skill: JsonString,
    };

    const Request = struct {
        connect_timeout_ms: u64 = timeouts_default.anthropic.connect_ms,
        ds4_connect_timeout_ms: u64 = timeouts_default.ds4.connect_ms,
        anthropic_idle_timeout_ms: u64 = timeouts_default.anthropic.idle_ms,
        openai_idle_timeout_ms: u64 = timeouts_default.openai.idle_ms,
        xai_idle_timeout_ms: u64 = timeouts_default.xai.idle_ms,
        google_idle_timeout_ms: u64 = timeouts_default.google.idle_ms,
        openrouter_idle_timeout_ms: u64 = timeouts_default.openrouter.idle_ms,
        deepseek_idle_timeout_ms: u64 = timeouts_default.deepseek.idle_ms,
        ds4_idle_timeout_ms: u64 = timeouts_default.ds4.idle_ms,
        attempts_max: u32 = retry_default.attempts_max,
        backoff_ms_initial: u64 = retry_default.backoff_ms_initial,
        backoff_ms_max: u64 = retry_default.backoff_ms_max,
    };

    const Bash = struct {
        output_lines_max: usize = bash_default.lines_max,
        output_bytes_max: usize = bash_default.bytes_max,
        timeout_ms: u64 = bash_default.timeout_ms,
    };

    const Interface = struct {
        window_pages: usize = layout.window_pages_default,
        gauge_percent_warning: f64 = gauge_default.percent_warning,
        gauge_percent_error: f64 = gauge_default.percent_error,
    };

    const PromptHistory = struct {
        enabled: bool = false,
    };
};

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

const unknown_keys_max = 16;

const Key = struct {
    path: []const u8,
    description: []const u8,
};

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
        .description = "The time that Drinky waits for the head of a remote provider response. " ++
            "One window of this size also bounds a remote model fetch.",
    },
    .{
        .path = "request.ds4_connect_timeout_ms",
        .description = "The time that Drinky waits for a DwarfStar response head. One window " ++
            "of this size also bounds its model fetch.",
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
        .path = "request.xai_idle_timeout_ms",
        .description = "The time that Drinky waits between two streamed xAI events. The " ++
            "stream can stay silent while the model reasons, so the default matches the " ++
            "OpenAI wait.",
    },
    .{
        .path = "request.google_idle_timeout_ms",
        .description = "The time that Drinky waits between two streamed Google events. " ++
            "The stream can stay silent while the model thinks, so the default matches the " ++
            "OpenAI wait.",
    },
    .{
        .path = "request.openrouter_idle_timeout_ms",
        .description = "The time that Drinky waits between two streamed OpenRouter events. " ++
            "The stream can stay silent while the model reasons, so the default matches the " ++
            "OpenAI wait.",
    },
    .{
        .path = "request.deepseek_idle_timeout_ms",
        .description = "The time that Drinky waits between two streamed DeepSeek events. " ++
            "The first reasoning event can take a long time to arrive, so the default matches " ++
            "the OpenAI wait.",
    },
    .{
        .path = "request.ds4_idle_timeout_ms",
        .description = "The time that Drinky waits between two streamed DwarfStar events. A " ++
            "local prefill can take many minutes.",
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
        .path = "default_effort",
        .description = "The reasoning effort that a session starts on. Drinky folds a level " ++
            "that the model does not support onto the nearest one it does. Only a new " ++
            "project reads it.",
    },
    .{
        .path = "prompt_history.enabled",
        .description = "Whether Drinky records and opens the global prompt history. A false " ++
            "value leaves the saved history unchanged.",
    },
};

const Leaf = struct {
    path: []const u8,
    type_name: []const u8,
    default_text: ?[]const u8,
};

fn isSection(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and T != File.JsonString;
}

fn isObjectSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and isSection(pointer.child),
        else => false,
    };
}

fn jsonTypeName(comptime T: type) []const u8 {
    const inner = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    const unsupported = "the config field type " ++ @typeName(inner) ++ " has no JSON type";
    return switch (@typeInfo(inner)) {
        .bool => "boolean",
        .int => "integer",
        .float => "number",
        .pointer => "array",
        .@"struct" => if (inner == File.JsonString) "string" else @compileError(unsupported),
        else => @compileError(unsupported),
    };
}

fn maybeDefaultText(comptime field: std.builtin.Type.StructField) ?[]const u8 {
    const pointer = field.default_value_ptr orelse return null;
    const value = @as(*const field.type, @ptrCast(@alignCast(pointer))).*;
    return switch (@typeInfo(field.type)) {
        .bool => if (value) "true" else "false",
        .int, .float => std.fmt.comptimePrint("{d}", .{value}),
        .optional => if (value == null) "unset" else @compileError("expected a null default"),
        .pointer => if (value.len == 0) "empty" else @compileError("expected an empty default"),
        else => @compileError("the config field " ++ field.name ++ " has no printable default"),
    };
}

fn defaultText(comptime field: std.builtin.Type.StructField) []const u8 {
    return maybeDefaultText(field) orelse
        @compileError("the config field " ++ field.name ++ " declares no default");
}

const leaves: []const Leaf = blk: {
    @setEvalBranchQuota(20_000);
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

const key_lines = blk: {
    @setEvalBranchQuota(20_000);
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

const example =
    \\{
    \\  "user_instructions": [{ "path": "instructions.md" }],
    \\  "required_skills": [{ "glob": "**/*.zig", "skill": "zig-style" }],
    \\  "request": { "anthropic_idle_timeout_ms": 90000 },
    \\  "bash": { "timeout_ms": 300000 },
    \\  "interface": { "window_pages": 12 },
    \\  "default_effort": "high"
    \\}
;

const keys_section = "\n### Keys\n\n" ++ key_lines;

pub fn document(
    self: *const Config,
    gpa: std.mem.Allocator,
    effort_default: ai.llm.Effort,
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
        \\The file holds no secret. An API key comes from the ANTHROPIC_API_KEY, the
        \\OPENAI_API_KEY, the XAI_API_KEY, the OPENROUTER_API_KEY, or the
        \\DEEPSEEK_API_KEY variable. The
        \\google-cloud-key account reads the service account key file that
        \\GOOGLE_APPLICATION_CREDENTIALS names.
        \\GOOGLE_CLOUD_LOCATION is eu, us, or global. DS4_BASE_URL enables the
        \\credential-free ds4 account and ends at /v1.
        \\{s}
        \\### Models and effort
        \\
        \\- This file names no model. Drinky learns every model from the provider, and the user
        \\  fetches that list from the /model command. Drinky remembers the model of each
        \\  account per project in a separate state file.
        \\- `default_effort` takes one of: {s}. Without the key, Drinky uses {s}.
        \\- Drinky remembers the effort level of each project in that same state file, and that
        \\  memory outranks this file. Only the /effort command changes a project that Drinky
        \\  already ran in.
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
        effort_levels,
        @tagName(effort_default),
        example,
    });
}

pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
    gpa.free(self.path);
    self.user_instructions.deinit();
    for (self.required_skills) |required| {
        gpa.free(required.glob);
        gpa.free(required.skill);
    }
    gpa.free(self.required_skills);
    if (self.dropped_effort) |name| gpa.free(name);
    for (self.unknown_keys) |key| gpa.free(key);
    gpa.free(self.unknown_keys);
}

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
        error.FileNotFound => return .{
            .path = try gpa.dupe(u8, path),
            .user_instructions = .init(gpa, .user),
        },
        else => return err,
    };
    defer gpa.free(data);
    return loadFromData(gpa, io, &.{ .directory = directory, .path = path, .data = data });
}

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
    const interface = parsed.value.interface;

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
    const unknown_keys = try unknown.toOwnedSlice(gpa);
    errdefer {
        for (unknown_keys) |key| gpa.free(key);
        gpa.free(unknown_keys);
    }
    const required_skills = try required.toOwnedSlice(gpa);
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
            .xai = .{
                .connect_ms = request.connect_timeout_ms,
                .idle_ms = request.xai_idle_timeout_ms,
            },
            .google = .{
                .connect_ms = request.connect_timeout_ms,
                .idle_ms = request.google_idle_timeout_ms,
            },
            .openrouter = .{
                .connect_ms = request.connect_timeout_ms,
                .idle_ms = request.openrouter_idle_timeout_ms,
            },
            .deepseek = .{
                .connect_ms = request.connect_timeout_ms,
                .idle_ms = request.deepseek_idle_timeout_ms,
            },
            .ds4 = .{
                .connect_ms = request.ds4_connect_timeout_ms,
                .idle_ms = request.ds4_idle_timeout_ms,
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
        },
        .window_pages = window_pages,
        .gauge = gauge,
        .default_effort = default_effort,
        .prompt_history_enabled = parsed.value.prompt_history.enabled,
        .user_instructions = user_instructions,
        .required_skills = required_skills,
        .dropped_effort = dropped_effort,
        .dropped_bash_timeout_ms = dropped_bash_timeout_ms,
        .dropped_window_pages = dropped_window_pages,
        .dropped_gauge = dropped_gauge,
        .unknown_keys = unknown_keys,
        .unknown_keys_omitted = unknown_keys_omitted,
    };
}

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

fn hasField(comptime T: type, name: []const u8) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

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

fn resolveBashTimeout(dropped: *?u64, configured: u64) u64 {
    if (configured >= ai.tool.Context.Bash.timeout_ms_min and
        configured <= ai.tool.Context.Bash.timeout_ms_max)
        return configured;
    dropped.* = configured;
    return bash_default.timeout_ms;
}

fn resolveWindowPages(dropped: *?usize, configured: usize) usize {
    if (configured >= layout.window_pages_min and configured <= layout.window_pages_max)
        return configured;
    dropped.* = configured;
    return layout.window_pages_default;
}

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

fn isShare(percent: f64) bool {
    return percent >= ui.status.Gauge.percent_min and percent <= ui.status.Gauge.percent_max;
}

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
        \\{ "request": { "connect_timeout_ms": 1000, "ds4_connect_timeout_ms": 1500,
        \\  "anthropic_idle_timeout_ms": 2000, "openai_idle_timeout_ms": 3000,
        \\  "google_idle_timeout_ms": 4000, "xai_idle_timeout_ms": 4500,
        \\  "ds4_idle_timeout_ms": 5000, "attempts_max": 5,
        \\  "backoff_ms_initial": 100, "backoff_ms_max": 900 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.anthropic.connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.openai.connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.xai.connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.google.connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.deepseek.connect_ms);
    try std.testing.expectEqual(@as(u64, 1500), config.timeouts.ds4.connect_ms);
    try std.testing.expectEqual(@as(u64, 2000), config.timeouts.anthropic.idle_ms);
    try std.testing.expectEqual(@as(u64, 3000), config.timeouts.openai.idle_ms);
    try std.testing.expectEqual(@as(u64, 4500), config.timeouts.xai.idle_ms);
    try std.testing.expectEqual(@as(u64, 4000), config.timeouts.google.idle_ms);
    try std.testing.expectEqual(@as(u64, 5000), config.timeouts.ds4.idle_ms);
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

    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(layout.window_pages_default, empty.window_pages);
    try std.testing.expectEqual(gauge_default.percent_warning, empty.gauge.percent_warning);
    try std.testing.expectEqual(gauge_default.percent_error, empty.gauge.percent_error);
    try std.testing.expect(empty.dropped_window_pages == null);
    try std.testing.expect(empty.dropped_gauge == null);
}

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

test "gauge shares Drinky cannot use fall back to the compiled pair and are reported" {
    const cases = [_][]const u8{
        \\{ "interface": { "gauge_percent_warning": -20, "gauge_percent_error": 90 } }
        ,
        \\{ "interface": { "gauge_percent_warning": 75, "gauge_percent_error": 250 } }
        ,
        \\{ "interface": { "gauge_percent_warning": 75, "gauge_percent_error": 1e999 } }
        ,
        \\{ "interface": { "gauge_percent_warning": "nan", "gauge_percent_error": 90 } }
        ,
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

    var config = try loadDataForTest(
        \\{ "interface": { "gauge_percent_warning": 90, "gauge_percent_error": 40 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 90), config.dropped_gauge.?.percent_warning);
    try std.testing.expectEqual(@as(f64, 40), config.dropped_gauge.?.percent_error);

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

test "a configured number that no counter can hold fails the load" {
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "bash": { "timeout_ms": -1 } }
    ));
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "request": { "anthropic_idle_timeout_ms": 99999999999999999999 } }
    ));

    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "bash": { "timeout_ms": 1.8446744073709552e19 } }
    ));
    try std.testing.expectError(error.Overflow, loadDataForTest(
        \\{ "request": { "openai_idle_timeout_ms": 18446744073709551616.0 } }
    ));

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
    try std.testing.expectEqual(timeouts_default.xai.idle_ms, empty.timeouts.xai.idle_ms);
    try std.testing.expectEqual(timeouts_default.google.idle_ms, empty.timeouts.google.idle_ms);
    try std.testing.expectEqual(
        timeouts_default.openrouter.idle_ms,
        empty.timeouts.openrouter.idle_ms,
    );
    try std.testing.expectEqual(
        timeouts_default.deepseek.idle_ms,
        empty.timeouts.deepseek.idle_ms,
    );
    try std.testing.expectEqual(timeouts_default.ds4.connect_ms, empty.timeouts.ds4.connect_ms);
    try std.testing.expectEqual(timeouts_default.ds4.idle_ms, empty.timeouts.ds4.idle_ms);
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

    try std.testing.expectError(error.MissingField, loadDataForTest(
        \\{ "required_skills": [{ "glob": "**/*.zig" }] }
    ));
    try std.testing.expectError(error.UnexpectedToken, loadDataForTest(
        \\{ "required_skills": [{ "glob": "**/*.zig", "skill": ["zig-style"] }] }
    ));

    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.required_skills.len);
}

test "a stale default_models key reads as an unknown key" {
    var config = try loadDataForTest(
        \\{ "default_models": { "anthropic-plan": "claude-sonnet-5" } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), config.unknown_keys.len);
    try std.testing.expectEqualStrings("default_models", config.unknown_keys[0]);
}

test "load reads prompt_history.enabled and documents it last" {
    var absent = try loadDataForTest("{}");
    defer absent.deinit(std.testing.allocator);
    try std.testing.expect(!absent.prompt_history_enabled);

    var enabled = try loadDataForTest(
        \\{ "prompt_history": { "enabled": true } }
    );
    defer enabled.deinit(std.testing.allocator);
    try std.testing.expect(enabled.prompt_history_enabled);

    var disabled = try loadDataForTest(
        \\{ "prompt_history": { "enabled": false } }
    );
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expect(!disabled.prompt_history_enabled);

    const row = "- `prompt_history.enabled` — boolean, default: false.";
    const row_index = std.mem.indexOf(u8, key_lines, row) orelse return error.MissingRow;
    try std.testing.expect(std.mem.indexOfPos(u8, key_lines, row_index + row.len, "\n- `") == null);
    try std.testing.expect(isLeafPath("prompt_history.enabled"));

    var typo = try loadDataForTest(
        \\{ "prompt_history": { "enabld": false } }
    );
    defer typo.deinit(std.testing.allocator);
    try std.testing.expect(!typo.prompt_history_enabled);
    try std.testing.expectEqual(@as(usize, 1), typo.unknown_keys.len);
    try std.testing.expectEqualStrings("prompt_history.enabld", typo.unknown_keys[0]);
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
    try std.testing.expectError(
        error.UnexpectedToken,
        loadDataForTest(
            \\{ "user_instructions": [{ "path": [105, 110, 115, 116, 114] }] }
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
    try std.testing.expectEqual(@as(u64, 42), config.timeouts.anthropic.connect_ms);
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
    try std.testing.expectEqual(@as(usize, keys.len), leaves.len);
    try std.testing.expect(isLeafPath("bash.timeout_ms"));
    try std.testing.expect(isLeafPath("default_effort"));
    try std.testing.expect(isLeafPath("user_instructions[].path"));
    try std.testing.expect(!isLeafPath("bash"));
    try std.testing.expect(!isLeafPath("nope"));
    try std.testing.expect(hasField(File.Request, "attempts_max"));
    try std.testing.expect(!hasField(File.Request, "nope"));

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

    const text = try config.document(gpa, .xhigh);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "/unused/config.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`bash.timeout_ms`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "low, medium, high, xhigh, max") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "This file names no model") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "`user_instructions[].path` — string, required.",
    ) != null);

    try std.testing.expect(std.mem.indexOf(u8, text, "`default_effort` — string, " ++
        "default: unset.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "default: none") == null);

    try std.testing.expect(std.mem.indexOf(u8, text, "Without the key, Drinky uses " ++
        "xhigh.") != null);

    try std.testing.expect(std.mem.indexOf(u8, text, "still succeeds") != null);

    try std.testing.expect(std.mem.indexOf(u8, text, "outranks this file") != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, text, "Only a new project reads it."),
    );

    try std.testing.expect(std.mem.indexOf(u8, text, "retry-after") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "keepalive") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "folds a level") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, std.fmt.comptimePrint(
        "count must be from {d} to {d}",
        .{ layout.window_pages_min, layout.window_pages_max },
    )) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, std.fmt.comptimePrint(
        "at most {d} files",
        .{ai.instructions.files_max},
    )) != null);

    var from_example = try loadDataForTest(example);
    defer from_example.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), from_example.unknown_keys.len);
    try std.testing.expect(from_example.dropped_effort == null);
    try std.testing.expectEqual(ai.llm.Effort.high, from_example.default_effort.?);
    try std.testing.expectEqual(@as(u64, 90_000), from_example.timeouts.anthropic.idle_ms);
    try std.testing.expectEqual(
        timeouts_default.openai.idle_ms,
        from_example.timeouts.openai.idle_ms,
    );
    try std.testing.expectEqual(@as(u64, 300_000), from_example.bash.timeout_ms);
    try std.testing.expectEqual(@as(usize, 12), from_example.window_pages);
}

test "load resolves user instruction paths against the config directory in order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var drinky_directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer drinky_directory.close(io);
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
}

fn checkLoadAllocationFailure(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), config.user_instructions.files().len);
    try std.testing.expectEqual(@as(usize, 1), config.user_instructions.notices().len);
    try std.testing.expect(config.dropped_effort != null);
    try std.testing.expectEqual(@as(usize, 2), config.unknown_keys.len);
    const text = try config.document(gpa, .xhigh);
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
        \\  "default_models": { "openai-api-key": "nope" }, "default_effort": "nope",
        \\  "unknown": 1 }
        ,
    });
    const home = try tmpPath(gpa, io, &tmp, "");
    defer gpa.free(home);

    try std.testing.checkAllAllocationFailures(gpa, checkLoadAllocationFailure, .{ io, home });
}
