const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");
const tools = @import("tools");

const discovery = @import("discovery/root.zig");
const layout = @import("layout.zig");
const Reports = @import("Reports.zig");
const testing = @import("testing.zig");
const ui = @import("ui/root.zig");

const Config = @This();

path: []const u8,
timeouts: accounts.Registry.Timeouts = accounts.Registry.timeouts_default,
retry: core.Retry = .{},
bash: tools.Context.Bash = .{},
window_pages: usize = layout.window_pages_default,
gauge: ui.status.Gauge = .{},
effort_default: ?core.Provider.Effort = null,
user_instructions: discovery.instructions.Result,
required_skills: []const RequiredSkill = &.{},
effort_dropped: ?[]const u8 = null,
bash_timeout_ms_dropped: ?u64 = null,
window_pages_dropped: ?usize = null,
gauge_dropped: ?ui.status.Gauge = null,
unknown_keys: []const []const u8 = &.{},
unknown_keys_omitted: bool = false,
load_error: ?LoadError = null,

pub const RequiredSkill = struct {
    glob: []const u8,
    skill: []const u8,
};

pub const ReportOptions = struct {
    effort: core.Provider.Effort,
    required_capped: bool,
};

const LoadError = std.Io.Dir.ReadFileAllocError || std.json.ParseError(std.json.Scanner) ||
    @typeInfo(@typeInfo(@TypeOf(discovery.instructions.load)).@"fn".return_type.?)
        .error_union.error_set;

const File = struct {
    user_instructions: []const File.UserInstruction = &.{},
    required_skills: []const File.RequiredSkill = &.{},
    request: Request = .{},
    bash: Bash = .{},
    interface: Interface = .{},
    default_effort: ?JsonString = null,

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
    };

    const UserInstruction = struct {
        path: JsonString,
    };

    const RequiredSkill = struct {
        glob: JsonString,
        skill: JsonString,
    };

    const Request = Section(request_fields);

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
};

const DataOptions = struct {
    directory: []const u8,
    path: []const u8,
    data: []const u8,
};

const SectionField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: *const anyopaque,
};

const transport_timeouts_default: providers.Transport.Timeouts = .{};
const retry_default: core.Retry = .{};
const bash_default: tools.Context.Bash = .{};
const gauge_default: ui.status.Gauge = .{};

const unknown_keys_max = 16;

const vendors = std.enums.values(accounts.Account.Vendor);

const request_fields: []const SectionField = fields: {
    var list: []const SectionField = &.{
        sectionField(u64, "connect_timeout_ms", transport_timeouts_default.connect_ms),
    };
    for (vendors) |vendor| {
        const idle_ms = accounts.Registry.waits.get(vendor).idle_ms;
        list = list ++ [_]SectionField{sectionField(u64, idleName(vendor), idle_ms)};
    }
    break :fields list ++ [_]SectionField{
        sectionField(u32, "attempts_max", retry_default.attempts_max),
        sectionField(u64, "delay_ms_initial", retry_default.backoff.delay_ms_initial),
        sectionField(u64, "delay_ms_max", retry_default.backoff.delay_ms_max),
    };
};

const Key = struct {
    path: []const u8,
    description: []const u8,
};

const vendor_keys: []const Key = keys: {
    var list: []const Key = &.{};
    for (vendors) |vendor| {
        list = list ++ [_]Key{.{
            .path = "request." ++ idleName(vendor),
            .description = "The time that Drinky waits between two streamed " ++
                vendor.label() ++ " events. " ++ accounts.Registry.waits.get(vendor).idle_note,
        }};
    }
    break :keys list;
};

const keys = [_]Key{
    .{
        .path = "user_instructions",
        .description = std.fmt.comptimePrint(
            "The instruction files that Drinky loads into every system prompt, in this order. " ++
                "Drinky loads at most {d} files, {d} KiB in total, and {d} KiB from one file.",
            .{
                discovery.instructions.files_max,
                discovery.instructions.source_kibibytes_max,
                discovery.instructions.file_kibibytes_max,
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
            .{tools.SkillGuard.rules_max},
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
        .description = "The time that Drinky waits for the head of a provider reply. " ++
            "One window of this size also bounds a model fetch.",
    },
    .{
        .path = "request.attempts_max",
        .description = "The number of times that Drinky sends one request before it fails.",
    },
    .{
        .path = "request.delay_ms_initial",
        .description = "The wait before the second attempt. Each further wait doubles it.",
    },
    .{
        .path = "request.delay_ms_max",
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
            .{ tools.Context.Bash.timeout_ms_min, tools.Context.Bash.timeout_ms_max },
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
} ++ vendor_keys;

const Leaf = struct {
    path: []const u8,
    type_name: []const u8,
    default_text: ?[]const u8,
};

fn idleName(comptime vendor: accounts.Account.Vendor) [:0]const u8 {
    return @tagName(vendor) ++ "_idle_timeout_ms";
}

fn sectionField(comptime T: type, comptime name: [:0]const u8, comptime default: T) SectionField {
    return .{ .name = name, .type = T, .default_value_ptr = &default };
}

fn Section(comptime fields: []const SectionField) type {
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attributes: [fields.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (fields, &names, &types, &attributes) |field, *name, *field_type, *attribute| {
        name.* = field.name;
        field_type.* = field.type;
        attribute.* = .{ .default_value_ptr = field.default_value_ptr };
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

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

fn maybeDefaultText(comptime T: type, comptime index: usize) ?[]const u8 {
    const info = @typeInfo(T).@"struct";
    const field_type = info.field_types[index];
    const value = info.field_attrs[index].defaultValue(field_type) orelse return null;
    return switch (@typeInfo(field_type)) {
        .bool => if (value) "true" else "false",
        .int, .float => std.fmt.comptimePrint("{d}", .{value}),
        .optional => if (value == null) "unset" else @compileError("expected a null default"),
        .pointer => if (value.len == 0) "empty" else @compileError("expected an empty default"),
        else => @compileError(
            "the config field " ++ info.field_names[index] ++ " has no printable default",
        ),
    };
}

fn defaultText(comptime T: type, comptime index: usize) []const u8 {
    return maybeDefaultText(T, index) orelse @compileError(
        "the config field " ++ @typeInfo(T).@"struct".field_names[index] ++ " declares no default",
    );
}

const leaves: []const Leaf = blk: {
    @setEvalBranchQuota(20_000);
    var list: []const Leaf = &.{};
    const file = @typeInfo(File).@"struct";
    for (file.field_names, file.field_types, 0..) |name, field_type, index| {
        if (isSection(field_type)) {
            const section = @typeInfo(field_type).@"struct";
            for (section.field_names, section.field_types, 0..) |leaf, leaf_type, leaf_index| {
                list = list ++ [_]Leaf{.{
                    .path = name ++ "." ++ leaf,
                    .type_name = jsonTypeName(leaf_type),
                    .default_text = defaultText(field_type, leaf_index),
                }};
            }
            continue;
        }
        list = list ++ [_]Leaf{.{
            .path = name,
            .type_name = jsonTypeName(field_type),
            .default_text = defaultText(File, index),
        }};
        if (isObjectSlice(field_type)) {
            const child = @typeInfo(field_type).pointer.child;
            const entry = @typeInfo(child).@"struct";
            for (entry.field_names, entry.field_types, 0..) |leaf, leaf_type, leaf_index| {
                list = list ++ [_]Leaf{.{
                    .path = name ++ "[]." ++ leaf,
                    .type_name = jsonTypeName(leaf_type),
                    .default_text = maybeDefaultText(child, leaf_index),
                }};
            }
        }
    }
    break :blk list;
};

const key_lines = blk: {
    @setEvalBranchQuota(20_000);
    var text: []const u8 = "";
    var used: [keys.len]bool = @splat(false);
    for (leaves) |leaf| {
        var found = false;
        for (keys, 0..) |key, index| {
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

const effort_levels = joinNames(@typeInfo(core.Provider.Effort).@"enum".field_names);

const settings_lines = lines: {
    var text: []const u8 = "";
    for (&accounts.Account.table) |*row| {
        const setting = row.setting() orelse continue;
        text = text ++ "- `" ++ row.id ++ "`: " ++ setting ++ "\n";
    }
    break :lines text;
};

const example =
    \\{
    \\  "user_instructions": [{ "path": "instructions.md" }],
    \\  "required_skills": [{ "glob": "**/*.zig", "skill": "zig-style" }],
    \\  "request": { "attempts_max": 5 },
    \\  "bash": { "timeout_ms": 300000 },
    \\  "interface": { "window_pages": 12 },
    \\  "default_effort": "high"
    \\}
;

const keys_section = "\n### Keys\n\n" ++ key_lines;

pub fn document(
    self: *const Config,
    gpa: std.mem.Allocator,
    effort_default: core.Provider.Effort,
) ![]u8 {
    return gpa.print(
        \\## Config file
        \\
        \\Drinky reads {s} once, at startup. A change to that file applies at
        \\the next start of Drinky, and never to the session that runs now. Tell the user so.
        \\
        \\The file is optional, so create it when it is absent. Any subset of the keys below is
        \\valid, and an absent key keeps its default. A dot shows a nested JSON object. Empty
        \\brackets show each array entry. Drinky ignores a key that it does not know, so a typo has
        \\no effect. The next start still succeeds and records an event that names each ignored
        \\key. A file that Drinky cannot parse also lets the start succeed. Drinky then uses the
        \\default value of each key and records an event that names the error. The file holds no
        \\secret.
        \\Each account without a login reads its setting from the environment:
        \\
        \\{s}{s}
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
        settings_lines,
        keys_section,
        effort_levels,
        @tagName(effort_default),
        example,
    });
}

pub fn keyPath(comptime path: []const u8) []const u8 {
    comptime for (leaves) |leaf| {
        if (std.mem.eql(u8, leaf.path, path)) break;
    } else @compileError("the config has no key " ++ path);
    return path;
}

pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
    gpa.free(self.path);
    self.user_instructions.deinit();
    for (self.required_skills) |required| {
        gpa.free(required.glob);
        gpa.free(required.skill);
    }
    gpa.free(self.required_skills);
    if (self.effort_dropped) |name| gpa.free(name);
    for (self.unknown_keys) |key| gpa.free(key);
    gpa.free(self.unknown_keys);
}

pub fn reports(
    self: *const Config,
    gpa: std.mem.Allocator,
    options: ReportOptions,
) error{OutOfMemory}!Reports {
    var result: Reports = .{ .subject = "config file" };
    errdefer result.deinit(gpa);
    if (self.effort_dropped) |dropped| try result.add(
        gpa,
        .failure,
        "Drinky ignored the configured default effort level \"{s}\" because Drinky does not " ++
            "know that level. Drinky uses the effort level \"{s}\".",
        .{ dropped, @tagName(options.effort) },
    );
    if (self.bash_timeout_ms_dropped) |dropped| try result.add(
        gpa,
        .failure,
        "Drinky ignored the configured command timeout {d} because the value must be from {d} " ++
            "to {d} milliseconds. Drinky uses the default timeout of {d} milliseconds.",
        .{
            dropped,
            tools.Context.Bash.timeout_ms_min,
            tools.Context.Bash.timeout_ms_max,
            self.bash.timeout_ms,
        },
    );
    if (self.window_pages_dropped) |dropped| try result.add(
        gpa,
        .failure,
        "Drinky ignored the configured window page count {d} because the count must be from " ++
            "{d} to {d}. Drinky uses the default count of {d} pages.",
        .{ dropped, layout.window_pages_min, layout.window_pages_max, self.window_pages },
    );
    if (self.gauge_dropped) |dropped| try result.add(
        gpa,
        .failure,
        "Drinky ignored the gauge shares {d} and {d}. A share must be from {d} to {d}, and " ++
            "the warning share must not pass the error share. Drinky uses the shares {d} " ++
            "and {d}.",
        .{
            dropped.percent_warning,
            dropped.percent_error,
            ui.status.Gauge.percent_min,
            ui.status.Gauge.percent_max,
            self.gauge.percent_warning,
            self.gauge.percent_error,
        },
    );
    if (options.required_capped) try result.add(
        gpa,
        .failure,
        "Drinky used only the first {d} required skills in {s}.",
        .{ tools.SkillGuard.rules_max, self.path },
    );
    if (self.load_error) |err| try result.add(
        gpa,
        .failure,
        "Drinky could not read the config file {s} because of error {s}. Drinky uses " ++
            "the default value of each key.",
        .{ self.path, @errorName(err) },
    );
    for (self.unknown_keys) |key| try result.add(
        gpa,
        .failure,
        "Drinky ignored the unknown config key \"{s}\" in {s}.",
        .{ key, self.path },
    );
    if (self.unknown_keys_omitted) try result.add(
        gpa,
        .failure,
        "Drinky omitted the remaining unknown config keys in {s}.",
        .{self.path},
    );
    return result;
}

pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    directories: *const accounts.json_store.Directories,
) !Config {
    const path = try accounts.json_store.locate(gpa, directories, "config.json");
    defer gpa.free(path);
    const directory = std.Io.Dir.path.dirname(path).?;
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return defaults(gpa, path, null),
        error.OutOfMemory => return error.OutOfMemory,
        else => return defaults(gpa, path, err),
    };
    defer gpa.free(data);
    const data_options: DataOptions = .{ .directory = directory, .path = path, .data = data };
    return loadFromData(gpa, io, &data_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return defaults(gpa, path, err),
    };
}

fn defaults(gpa: std.mem.Allocator, path: []const u8, load_error: ?LoadError) !Config {
    return .{
        .path = try gpa.dupe(u8, path),
        .user_instructions = .init(gpa, .user),
        .load_error = load_error,
    };
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

    var path_buffer: [discovery.instructions.files_max + 1][]const u8 = undefined;
    const path_count = @min(parsed.value.user_instructions.len, path_buffer.len);
    const configured_paths = parsed.value.user_instructions[0..path_count];
    for (path_buffer[0..path_count], configured_paths) |*path, configured| {
        path.* = configured.path.value;
    }
    var user_instructions = try discovery.instructions.load(gpa, io, &.{
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

    var effort_dropped: ?[]const u8 = null;
    errdefer if (effort_dropped) |name| gpa.free(name);
    const effort_default = try resolveEffort(
        gpa,
        &effort_dropped,
        if (parsed.value.default_effort) |name| name.value else null,
    );
    var bash_timeout_ms_dropped: ?u64 = null;
    const bash_timeout_ms = resolveBashTimeout(&bash_timeout_ms_dropped, bash.timeout_ms);
    var window_pages_dropped: ?usize = null;
    const window_pages = resolveWindowPages(&window_pages_dropped, interface.window_pages);
    var gauge_dropped: ?ui.status.Gauge = null;
    const gauge = resolveGauge(&gauge_dropped, &interface);
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
        .timeouts = timeoutsOf(&request),
        .retry = .{
            .attempts_max = request.attempts_max,
            .backoff = .{
                .delay_ms_initial = request.delay_ms_initial,
                .delay_ms_max = request.delay_ms_max,
            },
        },
        .bash = .{
            .lines_max = bash.output_lines_max,
            .bytes_max = bash.output_bytes_max,
            .timeout_ms = bash_timeout_ms,
        },
        .window_pages = window_pages,
        .gauge = gauge,
        .effort_default = effort_default,
        .user_instructions = user_instructions,
        .required_skills = required_skills,
        .effort_dropped = effort_dropped,
        .bash_timeout_ms_dropped = bash_timeout_ms_dropped,
        .window_pages_dropped = window_pages_dropped,
        .gauge_dropped = gauge_dropped,
        .unknown_keys = unknown_keys,
        .unknown_keys_omitted = unknown_keys_omitted,
    };
}

fn timeoutsOf(request: *const File.Request) accounts.Registry.Timeouts {
    var timeouts: accounts.Registry.Timeouts = undefined;
    inline for (vendors) |vendor| {
        timeouts.set(vendor, .{
            .connect_ms = request.connect_timeout_ms,
            .idle_ms = @field(request, idleName(vendor)),
        });
    }
    return timeouts;
}

fn collectUnknownKeys(
    gpa: std.mem.Allocator,
    source: *const std.json.Value,
    out: *std.ArrayList([]const u8),
) !bool {
    std.debug.assert(source.* == .object);
    for (source.object.keys(), source.object.values()) |name, *value| {
        var known = false;
        const file = @typeInfo(File).@"struct";
        inline for (file.field_names, file.field_types) |field_name, field_type| {
            if (std.mem.eql(u8, field_name, name)) {
                known = true;
                if (comptime isSection(field_type)) {
                    if (try collectUnknownSection(field_type, gpa, value, name, out)) return true;
                } else if (comptime isObjectSlice(field_type)) {
                    const child = @typeInfo(field_type).pointer.child;
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
    for (@typeInfo(T).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, field_name, name)) return true;
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
    const path = try gpa.print(format, args);
    errdefer gpa.free(path);
    try out.append(gpa, path);
    return false;
}

fn resolveEffort(
    gpa: std.mem.Allocator,
    dropped: *?[]const u8,
    name: ?[]const u8,
) !?core.Provider.Effort {
    const level = name orelse return null;
    if (std.meta.stringToEnum(core.Provider.Effort, level)) |resolved| return resolved;
    dropped.* = try gpa.dupe(u8, level);
    return null;
}

fn resolveBashTimeout(dropped: *?u64, configured: u64) u64 {
    if (configured >= tools.Context.Bash.timeout_ms_min and
        configured <= tools.Context.Bash.timeout_ms_max)
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

test "load reads the request section" {
    var config = try loadDataForTest(
        \\{ "request": { "connect_timeout_ms": 1000,
        \\  "anthropic_idle_timeout_ms": 2000, "openai_idle_timeout_ms": 3000,
        \\  "google_idle_timeout_ms": 4000, "xai_idle_timeout_ms": 4500,
        \\  "openrouter_idle_timeout_ms": 5500, "deepseek_idle_timeout_ms": 6000,
        \\  "attempts_max": 5, "delay_ms_initial": 100, "delay_ms_max": 900 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.get(.anthropic).connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.get(.openai).connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.get(.xai).connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.get(.google).connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.get(.deepseek).connect_ms);
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.get(.openrouter).connect_ms);
    try std.testing.expectEqual(@as(u64, 2000), config.timeouts.get(.anthropic).idle_ms);
    try std.testing.expectEqual(@as(u64, 3000), config.timeouts.get(.openai).idle_ms);
    try std.testing.expectEqual(@as(u64, 4500), config.timeouts.get(.xai).idle_ms);
    try std.testing.expectEqual(@as(u64, 4000), config.timeouts.get(.google).idle_ms);
    try std.testing.expectEqual(@as(u64, 5500), config.timeouts.get(.openrouter).idle_ms);
    try std.testing.expectEqual(@as(u64, 6000), config.timeouts.get(.deepseek).idle_ms);
    try std.testing.expectEqual(@as(u32, 5), config.retry.attempts_max);
    try std.testing.expectEqual(@as(u64, 100), config.retry.backoff.delay_ms_initial);
    try std.testing.expectEqual(@as(u64, 900), config.retry.backoff.delay_ms_max);
}

fn loadDataForTest(data: []const u8) !Config {
    var config = try loadFileForTest(data);
    errdefer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?LoadError, null), config.load_error);
    return config;
}

fn expectLoadError(expected: LoadError, data: []const u8) !void {
    var config = try loadFileForTest(data);
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?LoadError, expected), config.load_error);
}

fn loadFileForTest(data: []const u8) !Config {
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    try tree.write(".drinky/config.json", data);
    return loadForTest(std.testing.allocator, std.testing.io, tree.root);
}

fn loadForTest(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !Config {
    return load(gpa, io, &.{ .working_directory = home, .home = home });
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
    try std.testing.expect(config.bash_timeout_ms_dropped == null);
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
    try std.testing.expect(config.window_pages_dropped == null);
    try std.testing.expect(config.gauge_dropped == null);

    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(layout.window_pages_default, empty.window_pages);
    try std.testing.expectEqual(gauge_default.percent_warning, empty.gauge.percent_warning);
    try std.testing.expectEqual(gauge_default.percent_error, empty.gauge.percent_error);
    try std.testing.expect(empty.window_pages_dropped == null);
    try std.testing.expect(empty.gauge_dropped == null);
}

test "a page count Drinky cannot use falls back to the default and is reported" {
    const cases = [_]usize{ 0, layout.window_pages_max + 1, 100_000 };
    for (cases) |configured| {
        const data = try std.testing.allocator.print(
            "{{ \"interface\": {{ \"window_pages\": {d} }} }}",
            .{configured},
        );
        defer std.testing.allocator.free(data);
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(layout.window_pages_default, config.window_pages);
        try std.testing.expectEqual(@as(?usize, configured), config.window_pages_dropped);
    }

    const edges = [_]usize{ layout.window_pages_min, layout.window_pages_max };
    for (edges) |configured| {
        const data = try std.testing.allocator.print(
            "{{ \"interface\": {{ \"window_pages\": {d} }} }}",
            .{configured},
        );
        defer std.testing.allocator.free(data);
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(configured, config.window_pages);
        try std.testing.expect(config.window_pages_dropped == null);
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
        try std.testing.expect(config.gauge_dropped != null);
    }

    var config = try loadDataForTest(
        \\{ "interface": { "gauge_percent_warning": 90, "gauge_percent_error": 40 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 90), config.gauge_dropped.?.percent_warning);
    try std.testing.expectEqual(@as(f64, 40), config.gauge_dropped.?.percent_error);

    var edges = try loadDataForTest(
        \\{ "interface": { "gauge_percent_warning": 0, "gauge_percent_error": 100 } }
    );
    defer edges.deinit(std.testing.allocator);
    try std.testing.expect(edges.gauge_dropped == null);
    var equal = try loadDataForTest(
        \\{ "interface": { "gauge_percent_warning": 50, "gauge_percent_error": 50 } }
    );
    defer equal.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 50), equal.gauge.percent_warning);
    try std.testing.expect(equal.gauge_dropped == null);
}

test "a command timeout Drinky cannot use falls back to the default and is reported" {
    const cases = [_]u64{
        0,
        tools.Context.Bash.timeout_ms_min - 1,
        tools.Context.Bash.timeout_ms_max + 1,
    };
    for (cases) |configured| {
        const data = try std.testing.allocator.print(
            "{{ \"bash\": {{ \"timeout_ms\": {d} }} }}",
            .{configured},
        );
        defer std.testing.allocator.free(data);
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(bash_default.timeout_ms, config.bash.timeout_ms);
        try std.testing.expectEqual(@as(?u64, configured), config.bash_timeout_ms_dropped);
    }

    const edges = [_]u64{ tools.Context.Bash.timeout_ms_min, tools.Context.Bash.timeout_ms_max };
    for (edges) |configured| {
        const data = try std.testing.allocator.print(
            "{{ \"bash\": {{ \"timeout_ms\": {d} }} }}",
            .{configured},
        );
        defer std.testing.allocator.free(data);
        var config = try loadDataForTest(data);
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(configured, config.bash.timeout_ms);
        try std.testing.expect(config.bash_timeout_ms_dropped == null);
    }
}

test "a configured number that no counter can hold is a load error" {
    try expectLoadError(error.Overflow,
        \\{ "bash": { "timeout_ms": -1 } }
    );
    try expectLoadError(error.Overflow,
        \\{ "request": { "anthropic_idle_timeout_ms": 99999999999999999999 } }
    );
    try expectLoadError(error.Overflow,
        \\{ "bash": { "timeout_ms": 1.8446744073709552e19 } }
    );
    try expectLoadError(error.Overflow,
        \\{ "request": { "openai_idle_timeout_ms": 18446744073709551616.0 } }
    );

    var config = try loadDataForTest(
        \\{ "bash": { "timeout_ms": 3e5 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 300_000), config.bash.timeout_ms);
    try std.testing.expect(config.bash_timeout_ms_dropped == null);
}

test "load fills missing fields and sections from defaults" {
    var partial = try loadDataForTest(
        \\{ "request": { "attempts_max": 7 } }
    );
    defer partial.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), partial.retry.attempts_max);
    try std.testing.expectEqual(
        accounts.Registry.timeouts_default.get(.anthropic).connect_ms,
        partial.timeouts.get(.anthropic).connect_ms,
    );
    try std.testing.expectEqual(
        retry_default.backoff.delay_ms_initial,
        partial.retry.backoff.delay_ms_initial,
    );
    try std.testing.expectEqual(bash_default.lines_max, partial.bash.lines_max);
    try std.testing.expectEqual(bash_default.bytes_max, partial.bash.bytes_max);
    try std.testing.expectEqual(bash_default.timeout_ms, partial.bash.timeout_ms);

    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    for (std.enums.values(accounts.Account.Vendor)) |vendor| {
        try std.testing.expectEqual(
            accounts.Registry.timeouts_default.get(vendor),
            empty.timeouts.get(vendor),
        );
    }
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

    try expectLoadError(error.MissingField,
        \\{ "required_skills": [{ "glob": "**/*.zig" }] }
    );
    try expectLoadError(error.UnexpectedToken,
        \\{ "required_skills": [{ "glob": "**/*.zig", "skill": ["zig-style"] }] }
    );

    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.required_skills.len);
}

test "load resolves default_effort, dropping an unknown level" {
    var config = try loadDataForTest(
        \\{ "default_effort": "max" }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(core.Provider.Effort.max, config.effort_default.?);
    try std.testing.expect(config.effort_dropped == null);

    var dropped = try loadDataForTest(
        \\{ "default_effort": "enormous" }
    );
    defer dropped.deinit(std.testing.allocator);
    try std.testing.expect(dropped.effort_default == null);
    try std.testing.expectEqualStrings("enormous", dropped.effort_dropped.?);

    var empty = try loadDataForTest("{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(empty.effort_default == null);
    try std.testing.expect(empty.effort_dropped == null);
}

test "a configured name must be a JSON string" {
    try expectLoadError(error.UnexpectedToken,
        \\{ "user_instructions": { "path": "instructions.md" } }
    );
    try expectLoadError(error.UnexpectedToken,
        \\{ "user_instructions": [{ "path": ["one.md", "two.md"] }] }
    );
    try expectLoadError(error.UnexpectedToken,
        \\{ "user_instructions": [{ "path": [105, 110, 115, 116, 114] }] }
    );
    try expectLoadError(error.MissingField,
        \\{ "user_instructions": [{}] }
    );
}

test "load applies the known keys and reports the unknown ones" {
    var config = try loadDataForTest(
        \\{ "request": { "connect_timeout_ms": 42, "connect_timeout": 9 },
        \\  "user_instructions": [{ "path": "missing.md", "pth": "other.md" }],
        \\  "future": { "x": 1 }, "default_effot": "high" }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), config.timeouts.get(.anthropic).connect_ms);
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
    for (0..discovery.instructions.files_max + 1) |index| {
        try data.writer.print("{{\"path\":\"f{d}.md\"}},", .{index});
    }
    try data.writer.writeAll(
        \\{ "path": "last.md", "typo": 1 }] }
    );

    var config = try loadDataForTest(data.written());
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), config.unknown_keys.len);
    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint(
            "user_instructions[{d}].typo",
            .{discovery.instructions.files_max + 1},
        ),
        config.unknown_keys[0],
    );
    try std.testing.expect(!config.unknown_keys_omitted);
}

test "the config document names the file, each key, and each limit, and its example loads clean" {
    const gpa = std.testing.allocator;
    var config = try loadDataForTest("{}");
    defer config.deinit(gpa);

    const text = try config.document(gpa, .xhigh);
    defer gpa.free(text);
    try std.testing.expect(std.mem.find(u8, text, config.path) != null);
    for (leaves) |leaf| {
        const line = try gpa.print("- `{s}` — {s}", .{ leaf.path, leaf.type_name });
        defer gpa.free(line);
        try std.testing.expect(std.mem.find(u8, text, line) != null);
    }
    const stated_keys = [_][]const u8{
        std.fmt.comptimePrint(
            "- `bash.timeout_ms` — integer, default: {d}.",
            .{bash_default.timeout_ms},
        ),
        "- `default_effort` — string, default: unset.",
        "- `user_instructions[].path` — string, required.",
    };
    for (stated_keys) |line| try std.testing.expect(std.mem.find(u8, text, line) != null);
    try std.testing.expect(std.mem.find(u8, text, effort_levels) != null);
    try std.testing.expect(std.mem.find(u8, text, "uses xhigh.") != null);
    for (&accounts.Account.table) |*row| {
        const setting = row.setting() orelse continue;
        const line = try gpa.print("- `{s}`: {s}\n", .{ row.id, setting });
        defer gpa.free(line);
        try std.testing.expect(std.mem.find(u8, text, line) != null);
    }
    try std.testing.expect(std.mem.find(u8, text, std.fmt.comptimePrint(
        "count must be from {d} to {d}",
        .{ layout.window_pages_min, layout.window_pages_max },
    )) != null);
    try std.testing.expect(std.mem.find(u8, text, std.fmt.comptimePrint(
        "at most {d} files",
        .{discovery.instructions.files_max},
    )) != null);

    var from_example = try loadDataForTest(example);
    defer from_example.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), from_example.unknown_keys.len);
    try std.testing.expect(from_example.effort_dropped == null);
    try std.testing.expectEqual(core.Provider.Effort.high, from_example.effort_default.?);
    try std.testing.expectEqual(@as(u32, 5), from_example.retry.attempts_max);
    try std.testing.expectEqual(@as(u64, 300_000), from_example.bash.timeout_ms);
    try std.testing.expectEqual(@as(usize, 12), from_example.window_pages);
}

test "load resolves user instruction paths against the config directory in order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    var drinky_directory = try tree.tmp.dir.createDirPathOpen(io, ".drinky", .{});
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
    const home = tree.root;

    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    const files = config.user_instructions.files();
    try std.testing.expectEqual(@as(usize, 2), files.len);
    const second_path = try std.Io.Dir.path.join(gpa, &.{ home, ".drinky", "second.md" });
    defer gpa.free(second_path);
    const first_path = try std.Io.Dir.path.join(gpa, &.{ home, ".drinky", "first.md" });
    defer gpa.free(first_path);
    try std.testing.expectEqualStrings(second_path, files[0].path);
    try std.testing.expectEqualStrings("Second.\n", files[0].content);
    try std.testing.expectEqualStrings(first_path, files[1].path);
    try std.testing.expectEqualStrings("First.\n", files[1].content);
    try std.testing.expectEqual(@as(usize, 1), config.user_instructions.reports.messages().len);
    try std.testing.expect(std.mem.find(
        u8,
        config.user_instructions.reports.messages()[0].content,
        "missing.md",
    ) != null);
}

test "load accepts an absolute path to user instructions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    var drinky_directory = try tree.tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer drinky_directory.close(io);
    try tree.write("instructions.md", "Use the configured absolute path.");
    const instructions_path = try tree.path("instructions.md");
    const config_data = try std.json.Stringify.valueAlloc(gpa, .{
        .user_instructions = &.{.{ .path = instructions_path }},
    }, .{});
    defer gpa.free(config_data);
    try drinky_directory.writeFile(io, .{ .sub_path = "config.json", .data = config_data });
    const home = tree.root;

    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    const files = config.user_instructions.files();
    try std.testing.expectEqualStrings(instructions_path, files[0].path);
    try std.testing.expectEqualStrings("Use the configured absolute path.", files[0].content);
}

test "an absent config file loads the built-in defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    const home = tree.root;
    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    try std.testing.expectEqual(
        accounts.Registry.timeouts_default.get(.anthropic).connect_ms,
        config.timeouts.get(.anthropic).connect_ms,
    );
    try std.testing.expectEqual(@as(usize, 0), config.user_instructions.files().len);
    try std.testing.expectEqual(@as(usize, 0), config.user_instructions.reports.messages().len);
}

test "a file that Drinky cannot parse keeps every default and its error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    var drinky_directory = try tree.tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer drinky_directory.close(io);
    const home = tree.root;

    const cases = [_]struct { data: []const u8, err: LoadError }{
        .{ .data = "{ \"bash\": { \"timeout_ms\": 5000, } }", .err = error.SyntaxError },
        .{ .data = "{ \"bash\": { \"timeout_ms\": true } }", .err = error.UnexpectedToken },
        .{ .data = "{ \"bash\": { \"timeout_ms\": -1 } }", .err = error.Overflow },
    };
    for (cases) |case| {
        try drinky_directory.writeFile(io, .{ .sub_path = "config.json", .data = case.data });
        var config = try loadForTest(gpa, io, home);
        defer config.deinit(gpa);
        try std.testing.expectEqual(@as(?LoadError, case.err), config.load_error);
        try std.testing.expectEqual(bash_default.timeout_ms, config.bash.timeout_ms);
        try std.testing.expect(std.mem.endsWith(u8, config.path, "config.json"));
    }
}

fn checkLoadAllocationFailure(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !void {
    var config = try loadForTest(gpa, io, home);
    defer config.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), config.user_instructions.files().len);
    try std.testing.expectEqual(@as(usize, 1), config.user_instructions.reports.messages().len);
    try std.testing.expect(config.effort_dropped != null);
    try std.testing.expectEqual(@as(usize, 2), config.unknown_keys.len);
    const text = try config.document(gpa, .xhigh);
    defer gpa.free(text);
}

test "the config load frees every partial allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    var drinky_directory = try tree.tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer drinky_directory.close(io);
    try drinky_directory.writeFile(io, .{ .sub_path = "first.md", .data = "First.\n" });
    try drinky_directory.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{ "user_instructions": [{ "path": "first.md" }, { "path": "missing.md" }],
        \\  "future": { "openai-api-key": "nope" }, "default_effort": "nope",
        \\  "unknown": 1 }
        ,
    });
    const home = tree.root;

    try std.testing.checkAllAllocationFailures(gpa, checkLoadAllocationFailure, .{ io, home });
}
