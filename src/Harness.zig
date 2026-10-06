const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");
const tools = @import("tools");

const Config = @import("Config.zig");
const describe = @import("describe.zig");
const discovery = @import("discovery/root.zig");
const system_prompt = @import("system_prompt.zig");

const Harness = @This();

config: Config,
project_instructions: discovery.instructions.Result,
skill_registry: discovery.skills.Registry,
skill_guard: tools.SkillGuard,
required_missing: std.ArrayList(Config.RequiredSkill),
required_capped: bool,
system: []const u8,
document: []const u8,
tool_registry: tools.Registry,

pub const effort_default: core.Provider.Effort = .xhigh;

pub const key_hints = [_][]const u8{
    "Enter: Send",
    "Shift+Enter: New line",
    "Esc: Cancel",
    "Ctrl+C: Clear",
    "Ctrl+D: Quit",
};

pub const repeat_window_ms = 500;

pub const Options = struct {
    directories: accounts.json_store.Directories,
    environ: std.process.Environ,
    surface: discovery.skills.Skill.Surface,
};

pub fn init(self: *Harness, gpa: std.mem.Allocator, io: std.Io, options: *const Options) !void {
    const directories = &options.directories;
    const cwd = directories.working_directory;
    self.config = try Config.load(gpa, io, directories);
    errdefer self.config.deinit(gpa);
    self.project_instructions = try discovery.instructions.discover(gpa, io, cwd);
    errdefer self.project_instructions.deinit();

    const user_skills = try std.fs.path.resolve(
        gpa,
        &.{ cwd, directories.home, ".agents", "skills" },
    );
    defer gpa.free(user_skills);
    self.skill_registry = try discovery.skills.discover(gpa, io, &.{
        .user_root = user_skills,
        .project_start = cwd,
        .project_root = self.project_instructions.projectRoot(),
    });
    errdefer self.skill_registry.deinit();
    self.skill_guard = .{ .working_directory = cwd };
    self.required_missing = .empty;
    errdefer self.required_missing.deinit(gpa);
    self.required_capped = try self.resolveRequiredSkills(gpa);

    self.system = try system_prompt.compose(gpa, &.{
        .current_time = std.Io.Clock.real.now(io),
        .working_directory = cwd,
        .user_instructions = self.config.user_instructions.files(),
        .project_instructions = &self.project_instructions,
        .skills = self.skill_registry.items(),
        .required_skills = self.skill_guard.rules(),
        .surface = options.surface,
    });
    errdefer gpa.free(self.system);
    self.document = try describe.compose(gpa, &.{
        .config = &self.config,
        .effort_default = effort_default,
        .key_hints = &key_hints,
        .repeat_window_ms = repeat_window_ms,
    });
    self.tool_registry = .{
        .host = .{
            .io = io,
            .environ = options.environ,
            .bash = self.config.bash,
            .document = self.document,
        },
        .skill_guard = &self.skill_guard,
    };
}

pub fn deinit(self: *Harness, gpa: std.mem.Allocator) void {
    gpa.free(self.document);
    gpa.free(self.system);
    self.required_missing.deinit(gpa);
    self.skill_registry.deinit();
    self.project_instructions.deinit();
    self.config.deinit(gpa);
}

pub fn session(
    self: *Harness,
    gpa: std.mem.Allocator,
    io: std.Io,
    sink: core.Session.Sink,
) core.Session {
    return .init(gpa, io, &.{
        .sink = sink,
        .runner = self.tool_registry.runner(),
        .tools = &tools.Registry.specs,
        .retry = self.config.retry,
    });
}

fn resolveRequiredSkills(self: *Harness, gpa: std.mem.Allocator) error{OutOfMemory}!bool {
    for (self.config.required_skills) |required| {
        const target = self.skill_registry.get(required.skill) orelse {
            try self.required_missing.append(gpa, required);
            continue;
        };
        self.skill_guard.add(.{
            .glob = required.glob,
            .skill = target.name,
            .source = target.path,
        }) catch |err| switch (err) {
            error.TooManyRules => return true,
        };
    }
    return false;
}
