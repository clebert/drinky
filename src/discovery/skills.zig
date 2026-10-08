const std = @import("std");

const core = @import("core");
const tools = @import("tools");

const escape = @import("../escape.zig");
const Message = @import("../Message.zig");
const Reports = @import("../Reports.zig");
const testing = @import("../testing.zig");
const front_matter = @import("front_matter.zig");

const entries_visited_max = 100_000;
const candidates_retained_max = 1024;
const skills_max = 1024;
const description_codepoints_max = 1024;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    description_truncated: bool,
    path: []const u8,
    model_invocation_disabled: bool,
    run_hidden: bool,
    scope: Scope,
    replaced_path: ?[]const u8 = null,

    pub const Scope = enum { user, project };

    pub const Surface = enum { session, run };

    pub fn advertised(self: *const Skill, surface: Surface) bool {
        if (self.model_invocation_disabled) return false;
        return switch (surface) {
            .session => true,
            .run => !self.run_hidden,
        };
    }

    fn deinit(self: *Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        gpa.free(self.path);
        if (self.replaced_path) |path| gpa.free(path);
        self.* = undefined;
    }

    pub fn invoke(
        self: *const Skill,
        gpa: std.mem.Allocator,
        io: std.Io,
        arguments: []const u8,
    ) tools.skill_file.ReadError![]u8 {
        const data = try tools.skill_file.read(gpa, io, self.path);
        defer gpa.free(data);

        var output: std.Io.Writer.Allocating = .init(gpa);
        errdefer output.deinit();
        writeInvocation(&output.writer, &.{
            .path = self.path,
            .content = data,
            .arguments = arguments,
        }) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    fn writeInvocation(
        writer: *std.Io.Writer,
        invocation: *const struct { path: []const u8, content: []const u8, arguments: []const u8 },
    ) std.Io.Writer.Error!void {
        try tools.skill_file.write(writer, &.{
            .path = invocation.path,
            .content = invocation.content,
        });
        if (invocation.arguments.len == 0) return;
        if (!std.mem.endsWith(u8, invocation.content, "\n")) try writer.writeByte('\n');
        try writer.writeByte('\n');
        try writer.writeAll(invocation.arguments);
    }
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    skill_items: std.ArrayList(Skill) = .empty,
    reports: Reports = .{ .subject = "skill files" },
    skills_capped: bool = false,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        for (self.skill_items.items) |*skill| skill.deinit(self.gpa);
        self.skill_items.deinit(self.gpa);
        self.reports.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn items(self: *const Registry) []const Skill {
        return self.skill_items.items;
    }

    pub fn get(self: *const Registry, name: []const u8) ?*const Skill {
        for (self.skill_items.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) return skill;
        }
        return null;
    }

    fn scanRoot(self: *Registry, io: std.Io, root: []const u8, scope: Skill.Scope) !void {
        var match = tools.walk.collect(io, self.gpa, &.{
            .base = root,
            .pattern = "**/SKILL.md",
            .retain = candidates_retained_max,
            .entries_max = entries_visited_max,
            .noise_pruning = .disabled,
            .links = .files_and_directories,
            .skips_max = Reports.count_max,
        }) catch |err| switch (err) {
            error.FileNotFound => return,
            error.Canceled, error.OutOfMemory => |known| return known,
            else => return self.report(
                .failure,
                "Drinky could not scan the skill directory {s} because of error {s}.",
                .{ root, @errorName(err) },
            ),
        };
        defer match.deinit(self.gpa);
        for (match.skips) |skip| switch (skip.kind) {
            .entry => try self.report(
                .failure,
                "Drinky skipped one entry in {s} because of error {s}.",
                .{ root, skip.error_name },
            ),
            .directory => try self.report(
                .failure,
                "Drinky could not scan the skill directory {s}/{s} because of error {s}.",
                .{ root, skip.path, skip.error_name },
            ),
            .link => try self.report(
                .failure,
                "Drinky could not resolve the symbolic link {s}/{s} because of error {s}.",
                .{ root, skip.path, skip.error_name },
            ),
            .followed_link => try self.report(
                .failure,
                "Drinky could not follow the symbolic link {s}/{s} because of error {s}.",
                .{ root, skip.path, skip.error_name },
            ),
        };
        if (match.stop == .entries) try self.report(
            .failure,
            "Drinky stopped the skill scan in {s} after {d} entries.",
            .{ root, entries_visited_max },
        );
        if (match.matched > match.paths.len) try self.report(
            .failure,
            "Drinky used only the first {d} SKILL.md paths in {s}.",
            .{ candidates_retained_max, root },
        );
        for (match.paths) |path| try self.loadPath(io, path, scope);
    }

    fn loadPath(self: *Registry, io: std.Io, path: []const u8, scope: Skill.Scope) !void {
        if (!std.unicode.utf8ValidateSlice(path)) {
            const safe = try escape.diagnostic(self.gpa, path);
            defer self.gpa.free(safe);
            try self.report(
                .failure,
                "Drinky skipped the skill path {s} because it is not valid UTF-8.",
                .{safe},
            );
            return;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.gpa,
            .limited(tools.read.bytes_max + 1),
        ) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |known| return known,
            error.StreamTooLong => return self.report(
                .failure,
                "Drinky skipped {s} because the skill file is larger than {d} bytes.",
                .{ path, tools.read.bytes_max },
            ),
            else => return self.report(
                .failure,
                "Drinky could not read the skill file {s} because of error {s}.",
                .{ path, @errorName(err) },
            ),
        };
        defer self.gpa.free(data);
        if (!tools.format.isText(data)) {
            try self.report(
                .failure,
                "Drinky skipped {s} because the skill file is not UTF-8 text.",
                .{path},
            );
            return;
        }
        if (tools.format.lines(data) > tools.read.lines_max) {
            try self.report(
                .failure,
                "Drinky skipped {s} because the skill file has more than {d} lines.",
                .{ path, tools.read.lines_max },
            );
            return;
        }

        var frontmatter = front_matter.parse(self.gpa, data) catch |err| switch (err) {
            error.MissingFrontmatter => {
                try self.report(
                    .failure,
                    "Drinky skipped {s} because the YAML front matter is missing.",
                    .{path},
                );
                return;
            },
            error.UnclosedFrontmatter => {
                try self.report(
                    .failure,
                    "Drinky skipped {s} because the YAML front matter is not closed.",
                    .{path},
                );
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer frontmatter.deinit(self.gpa);

        const description = std.mem.trim(u8, frontmatter.description orelse "", " \t\r\n");
        if (description.len == 0) {
            try self.report(
                .failure,
                "Drinky skipped {s} because the skill description is missing or empty.",
                .{path},
            );
            return;
        }
        if (std.mem.findScalar(u8, description, 0) != null) {
            try self.report(
                .failure,
                "Drinky skipped {s} because the skill description contains a NUL byte.",
                .{path},
            );
            return;
        }

        const directory_path = std.Io.Dir.path.dirname(path).?;
        const directory_name = std.Io.Dir.path.basename(directory_path);
        const name_source = if (frontmatter.name) |declared| name: {
            if (nameValid(declared)) break :name declared;
            const safe = try escape.diagnostic(self.gpa, declared);
            defer self.gpa.free(safe);
            try self.report(
                .warning,
                "Drinky used the directory name for {s} because the skill name \"{s}\" is not " ++
                    "valid.",
                .{ path, safe },
            );
            break :name directory_name;
        } else name: {
            try self.report(
                .warning,
                "Drinky used the directory name for {s} because the skill name is missing.",
                .{path},
            );
            break :name directory_name;
        };
        if (!nameValid(name_source)) {
            try self.report(
                .failure,
                "Drinky skipped {s} because the directory name \"{s}\" is not a valid skill name.",
                .{ path, directory_name },
            );
            return;
        }
        if (!std.mem.eql(u8, name_source, directory_name)) try self.report(
            .warning,
            "The skill name \"{s}\" in {s} differs from the directory name \"{s}\".",
            .{ name_source, path, directory_name },
        );
        const description_length = std.unicode.utf8CountCodepoints(description) catch unreachable;
        const description_truncated = description_length > description_codepoints_max;
        if (description_truncated) try self.report(
            .warning,
            "Drinky shortened the catalog description for {s} because it has more than " ++
                "{d} characters.",
            .{ path, description_codepoints_max },
        );
        if (frontmatter.metadata_inline) try self.report(
            .warning,
            "Drinky ignored the metadata in {s} because the value is not a block map.",
            .{path},
        );

        var skill: Skill = .{
            .name = try self.gpa.dupe(u8, name_source),
            .description = undefined,
            .description_truncated = description_truncated,
            .path = undefined,
            .model_invocation_disabled = frontmatter.model_invocation_disabled,
            .run_hidden = frontmatter.run_hidden,
            .scope = scope,
        };
        errdefer self.gpa.free(skill.name);
        skill.description = try self.gpa.dupe(u8, descriptionPrefix(description));
        errdefer self.gpa.free(skill.description);
        skill.path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(skill.path);
        try self.insert(&skill);
    }

    fn insert(self: *Registry, incoming: *Skill) !void {
        for (self.skill_items.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, incoming.name)) continue;
            if (incoming.scope == .project and existing.scope == .user) {
                std.debug.assert(existing.replaced_path == null);
                incoming.replaced_path = try self.gpa.dupe(u8, existing.path);
                existing.deinit(self.gpa);
                existing.* = incoming.*;
                incoming.* = undefined;
                return;
            }
            try self.report(
                .failure,
                "Drinky ignored the skill \"{s}\" at {s} because {s} has priority.",
                .{ incoming.name, incoming.path, existing.path },
            );
            incoming.deinit(self.gpa);
            return;
        }

        if (self.skill_items.items.len == skills_max) {
            if (!self.skills_capped) {
                try self.report(
                    .failure,
                    "Drinky loaded only the first {d} distinct skills.",
                    .{skills_max},
                );
                self.skills_capped = true;
            }
            incoming.deinit(self.gpa);
            return;
        }
        try self.skill_items.append(self.gpa, incoming.*);
        incoming.* = undefined;
    }

    fn report(
        self: *Registry,
        severity: Message.Severity,
        comptime template: []const u8,
        args: anytype,
    ) !void {
        try self.reports.add(self.gpa, severity, template, args);
    }
};

const DiscoverOptions = struct {
    user_root: []const u8,
    project_start: []const u8,
    project_root: ?[]const u8,
};

pub fn discover(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const DiscoverOptions,
) !Registry {
    std.debug.assert(std.Io.Dir.path.isAbsolute(options.user_root));
    std.debug.assert(std.Io.Dir.path.isAbsolute(options.project_start));
    const boundary = options.project_root orelse options.project_start;
    std.debug.assert(tools.format.contains(&.{
        .boundary = boundary,
        .target = options.project_start,
    }));

    var registry = Registry.init(gpa);
    errdefer registry.deinit();
    try registry.scanRoot(io, options.user_root, .user);
    const user_root_canonical = try canonicalPath(gpa, io, options.user_root);
    defer if (user_root_canonical) |path| gpa.free(path);

    var current = options.project_start;
    for (0..std.Io.Dir.max_path_bytes) |_| {
        const skills_root = try std.Io.Dir.path.join(gpa, &.{ current, ".agents", "skills" });
        defer gpa.free(skills_root);
        var matches_user_root = std.mem.eql(u8, skills_root, options.user_root);
        if (!matches_user_root and user_root_canonical != null) {
            const skills_root_canonical = try canonicalPath(gpa, io, skills_root);
            defer if (skills_root_canonical) |path| gpa.free(path);
            matches_user_root = if (skills_root_canonical) |path|
                std.mem.eql(u8, path, user_root_canonical.?)
            else
                false;
        }
        if (!matches_user_root) try registry.scanRoot(io, skills_root, .project);
        if (current.len <= boundary.len) break;
        const parent = std.Io.Dir.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return registry;
}

fn canonicalPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?[:0]u8 {
    return std.Io.Dir.realPathFileAbsoluteAlloc(io, path, gpa) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return null;
    };
}

fn nameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '-' or name[name.len - 1] == '-') return false;
    var previous_hyphen = false;
    for (name) |byte| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
        if (!valid or (byte == '-' and previous_hyphen)) return false;
        previous_hyphen = byte == '-';
    }
    return true;
}

fn descriptionPrefix(description: []const u8) []const u8 {
    var end: usize = 0;
    for (0..description_codepoints_max) |_| {
        if (end == description.len) return description;
        end += std.unicode.utf8ByteSequenceLength(description[end]) catch unreachable;
    }
    return description[0..end];
}

test "discovery is recursive and project skills shadow user and ancestor skills" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.skill("user/shared", &.{ .name = "shared", .description = "user copy" });
    try tree.skill(
        "repo/.agents/skills/shared",
        &.{ .name = "shared", .description = "ancestor copy" },
    );
    try tree.skill(
        "repo/work/.agents/skills/nested/shared",
        &.{ .name = "shared", .description = "nearest copy" },
    );
    try tree.skill(
        "repo/work/.agents/skills/nested/other",
        &.{ .name = "other", .description = "nested copy" },
    );
    try tree.skill(".agents/skills/outside", &.{
        .name = "outside",
        .description = "outside repo",
    });
    try tree.write("repo/work/.agents/skills/loose.md", "ignored");

    const user_root = try tree.path("user");
    const project_root = try tree.path("repo");
    const project_start = try tree.path("repo/work");
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = project_root,
    });
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 2), registry.items().len);
    try std.testing.expectEqualStrings("nearest copy", registry.get("shared").?.description);
    try std.testing.expect(registry.get("other") != null);
    try std.testing.expect(registry.get("outside") == null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        registry.get("shared").?.replaced_path.?,
        "user/shared/SKILL.md",
    ));
    try std.testing.expect(registry.get("other").?.replaced_path == null);
    try std.testing.expectEqual(@as(usize, 1), registry.reports.messages().len);
    try std.testing.expect(
        std.mem.find(u8, registry.reports.messages()[0].content, "has priority") != null,
    );
}

test "without a Git root the project scan covers only the working directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.skill("user/helper", &.{ .name = "helper", .description = "user copy" });
    try tree.skill(
        "parent/.agents/skills/ancestor",
        &.{ .name = "ancestor", .description = "one directory above" },
    );
    try tree.skill(
        "parent/work/.agents/skills/local",
        &.{ .name = "local", .description = "the working directory" },
    );

    const user_root = try tree.path("user");
    const project_start = try tree.path("parent/work");
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 2), registry.items().len);
    try std.testing.expect(registry.get("helper") != null);
    try std.testing.expect(registry.get("local") != null);
    try std.testing.expect(registry.get("ancestor") == null);
}

test "a skill file above the window of one read call is skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    const head = "---\nname: {s}\ndescription: a long skill\n---\n";
    const wide = try gpa.print(head ++ "{s}\n", .{
        "wide",
        core.text.repeat("x", tools.read.bytes_max + 1),
    });
    defer gpa.free(wide);
    try tree.write("user/wide/SKILL.md", wide);
    var tall: std.Io.Writer.Allocating = .init(gpa);
    defer tall.deinit();
    try tall.writer.print(head, .{"tall"});
    for (0..tools.read.lines_max) |_| try tall.writer.writeAll("body\n");
    try tree.write("user/tall/SKILL.md", tall.written());
    var edge: std.Io.Writer.Allocating = .init(gpa);
    defer edge.deinit();
    try edge.writer.print(head, .{"edge"});
    while (tools.format.lines(edge.written()) < tools.read.lines_max)
        try edge.writer.writeAll("body\n");
    try tree.write("user/edge/SKILL.md", edge.written());
    try tree.directory("work");

    const user_root = try tree.path("user");
    const project_start = try tree.path("work");
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    try std.testing.expect(registry.get("wide") == null);
    try std.testing.expect(registry.get("tall") == null);
    try std.testing.expect(registry.get("edge") != null);
    try std.testing.expectEqual(@as(usize, 2), registry.reports.messages().len);
    try std.testing.expect(std.mem.find(
        u8,
        registry.reports.messages()[1].content,
        "larger than",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        registry.reports.messages()[0].content,
        "more than",
    ) != null);
}

test "a skill that loads warns, and a skipped skill fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.skill("user/fallback", &.{ .name = "Bad_Name", .description = "use <this> & that" });
    try tree.write("user/empty/SKILL.md", "---\n" ++
        "name: empty\ndescription: \"   \"\n---\nbody\n");
    try tree.write("user/manual/SKILL.md", "---\nname: manual\n" ++
        "description: hidden from the model\n" ++
        "disable-model-invocation: true\n---\nbody\n");
    try tree.write("user/long/SKILL.md", "---\nname: long\ndescription: " ++
        core.text.repeat("x", description_codepoints_max + 1) ++ "\n---\nbody\n");
    try tree.write("user/Bad Name/SKILL.md", "---\n" ++
        "description: a directory name that is not a valid skill name\n---\nbody\n");
    try tree.directory("work");

    const user_root = try tree.path("user");
    const project_start = try tree.path("work");
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    try std.testing.expect(registry.get("fallback") != null);
    try std.testing.expect(registry.get("empty") == null);
    try std.testing.expect(registry.get("Bad Name") == null);
    try std.testing.expect(registry.get("manual") != null);
    const long = registry.get("long").?;
    try std.testing.expectEqual(@as(usize, description_codepoints_max), long.description.len);
    try std.testing.expect(long.description_truncated);
    try std.testing.expect(registry.get("manual").?.model_invocation_disabled);
    const reports = registry.reports.messages();
    try std.testing.expectEqual(@as(usize, 5), reports.len);
    for (reports) |report| {
        const skipped = std.mem.startsWith(u8, report.content, "Drinky skipped");
        const severity: Message.Severity = if (skipped) .failure else .warning;
        try std.testing.expectEqual(severity, report.severity);
    }

    const manual = registry.get("manual").?;
    const explicit = try manual.invoke(gpa, io, "");
    defer gpa.free(explicit);
    try std.testing.expect(std.mem.find(u8, explicit, manual.path) != null);
    try std.testing.expect(std.mem.find(u8, explicit, "body") != null);
}

test "an inline metadata value hides no skill from a run and warns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    try tree.write("user/inline/SKILL.md", "---\nname: inline\ndescription: an inline map\n" ++
        "metadata: {drinky-run: hidden}\n---\nbody\n");
    try tree.directory("work");

    const user_root = try tree.path("user");
    const project_start = try tree.path("work");
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    try std.testing.expect(registry.get("inline").?.advertised(.run));
    const reports = registry.reports.messages();
    try std.testing.expectEqual(@as(usize, 1), reports.len);
    try std.testing.expectEqual(Message.Severity.warning, reports[0].severity);
    const path = try tree.path("user/inline/SKILL.md");
    const expected = try gpa.print(
        "Drinky ignored the metadata in {s} because the value is not a block map.",
        .{path},
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, reports[0].content);
}

test "explicit invocation loads the full file and appends arguments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    const source = "---\nname: invoke\ndescription: invocation test\n---\n# Instructions\nDo it.\n";
    try tree.write("user/invoke/SKILL.md", source);
    try tree.directory("work");

    const user_root = try tree.path("user");
    const project_start = try tree.path("work");
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    const skill = registry.get("invoke").?;
    const prompt = try skill.invoke(gpa, io, "apply it to report.pdf");
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.startsWith(u8, prompt, "Skill location: "));
    try std.testing.expect(std.mem.find(u8, prompt, skill.path) != null);
    try std.testing.expect(std.mem.find(u8, prompt, source) != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "\napply it to report.pdf"));
}

test "discovery follows directory symlinks once and skips cycles" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.skill("external/pdf-tools", &.{ .name = "pdf-tools", .description = "linked skill" });
    try tree.directory("user");
    try tree.directory("work");

    const external = try tree.path("external/pdf-tools");
    const user_root = try tree.path("user");
    try tree.link(external, "user/pdf-tools", .{});
    try tree.link(user_root, "user/loop", .{});

    const project_start = try tree.path("work");
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 1), registry.items().len);
    try std.testing.expect(registry.get("pdf-tools") != null);
}

test "a skill whose path is not valid UTF-8 is skipped with a safe warning" {
    const gpa = std.testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();
    try registry.loadPath(undefined, "user/\xff\xfe/SKILL.md", .user);

    try std.testing.expectEqual(@as(usize, 0), registry.items().len);
    try std.testing.expectEqual(@as(usize, 1), registry.reports.messages().len);
    const notice = registry.reports.messages()[0];
    try std.testing.expectEqual(Message.Severity.failure, notice.severity);
    try std.testing.expect(std.mem.find(u8, notice.content, "not valid UTF-8") != null);
    try std.testing.expect(std.mem.find(u8, notice.content, "\\xff") != null);
}

fn checkDiscoverAllocationFailure(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const DiscoverOptions,
) !void {
    var registry = try discover(gpa, io, options);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 2), registry.items().len);
    try std.testing.expectEqualStrings("nearest copy", registry.get("shared").?.description);
    try std.testing.expect(registry.get("shared").?.replaced_path != null);
    const prompt = try registry.get("shared").?.invoke(gpa, io, "apply it");
    gpa.free(prompt);
}

test "a discovery and an invocation free every allocation and fail as OutOfMemory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tree: testing.Tree = try .init();
    defer tree.deinit();

    try tree.skill("user/shared", &.{ .name = "shared", .description = "user copy" });
    try tree.skill(
        "repo/.agents/skills/shared",
        &.{ .name = "shared", .description = "ancestor copy" },
    );
    try tree.skill(
        "repo/work/.agents/skills/shared",
        &.{ .name = "shared", .description = "nearest copy" },
    );
    try tree.skill(
        "repo/work/.agents/skills/renamed",
        &.{ .name = "other", .description = "a skill under another directory name" },
    );
    const options: DiscoverOptions = .{
        .user_root = try tree.path("user"),
        .project_start = try tree.path("repo/work"),
        .project_root = try tree.path("repo"),
    };

    try std.testing.checkAllAllocationFailures(
        gpa,
        checkDiscoverAllocationFailure,
        .{ io, &options },
    );
}
