//! Agent Skills discovery and progressive disclosure. A registry owns only skill
//! metadata and absolute `SKILL.md` paths. Instruction bodies remain on disk
//! until the model reads one or the user invokes it explicitly.

const std = @import("std");

const instructions = @import("instructions.zig");
const project = @import("project.zig");
const skill_header = @import("skill_header.zig");

const entries_visited_max = 100_000;
const candidates_retained_max = 1024;
const skills_max = 1024;
const notices_max = 1024;
const skill_file_bytes_max = 16 << 20;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    description_truncated: bool,
    path: []const u8,
    model_invocation_disabled: bool,
    scope: Scope,

    pub const Scope = enum { user, project };

    fn deinit(self: *Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        gpa.free(self.path);
        self.* = undefined;
    }

    /// One explicit invocation: the expanded request and the size of the file
    /// that it carries. The transcript marker reports that size, because the
    /// file itself never reaches the screen.
    pub const Invocation = struct {
        content: []u8,
        file_bytes: usize,
    };

    /// Load this skill's complete `SKILL.md`. Identify its base directory for
    /// relative resources. Append explicit invocation arguments. `gpa` owns
    /// the returned content.
    pub fn invoke(
        self: *const Skill,
        gpa: std.mem.Allocator,
        io: std.Io,
        arguments: []const u8,
    ) !Invocation {
        const data = try std.Io.Dir.cwd().readFileAlloc(
            io,
            self.path,
            gpa,
            .limited(skill_file_bytes_max),
        );
        defer gpa.free(data);
        if (data.len == 0 or std.mem.indexOfScalar(u8, data, 0) != null or
            !std.unicode.utf8ValidateSlice(data))
        {
            return error.InvalidSkillText;
        }
        const directory = std.fs.path.dirname(self.path) orelse return error.InvalidSkillPath;

        var output: std.Io.Writer.Allocating = .init(gpa);
        errdefer output.deinit();
        try output.writer.print(
            "Skill location: {s}\nResolve relative paths in this skill against: {s}\n\n",
            .{ self.path, directory },
        );
        try output.writer.writeAll(data);
        if (arguments.len > 0) {
            if (!std.mem.endsWith(u8, data, "\n")) try output.writer.writeByte('\n');
            try output.writer.writeByte('\n');
            try output.writer.writeAll(arguments);
        }
        return .{ .content = try output.toOwnedSlice(), .file_bytes = data.len };
    }
};

/// Read-only metadata for the skills advertised to the model. Skills disabled
/// for model invocation remain in the registry but never appear in this view.
pub const Catalog = struct {
    skill_items: []const Skill,
    visible_count: usize,

    pub const Iterator = struct {
        skill_items: []const Skill,
        index: usize = 0,

        pub fn next(self: *Iterator) ?*const Skill {
            for (self.skill_items[self.index..]) |*skill| {
                self.index += 1;
                if (!skill.model_invocation_disabled) return skill;
            }
            return null;
        }
    };

    pub fn init(skill_items: []const Skill) !Catalog {
        if (skill_items.len > skills_max) return error.TooManySkills;
        return initBounded(skill_items);
    }

    fn initBounded(skill_items: []const Skill) Catalog {
        var visible_count: usize = 0;
        for (skill_items) |skill| {
            if (!skill.model_invocation_disabled) visible_count += 1;
        }
        return .{
            .skill_items = skill_items,
            .visible_count = visible_count,
        };
    }

    pub fn count(self: *const Catalog) usize {
        return self.visible_count;
    }

    pub fn iterator(self: *const Catalog) Iterator {
        return .{ .skill_items = self.skill_items };
    }
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    skill_items: std.ArrayList(Skill) = .empty,
    /// The startup messages of the scan, in the shape every instruction source
    /// reports, so the app has one way to show them all.
    notice_items: std.ArrayList(instructions.Notice) = .empty,
    skills_capped: bool = false,
    notices_capped: bool = false,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        for (self.skill_items.items) |*skill| skill.deinit(self.gpa);
        self.skill_items.deinit(self.gpa);
        for (self.notice_items.items) |notice| self.gpa.free(notice.text);
        self.notice_items.deinit(self.gpa);
        self.* = undefined;
    }

    fn items(self: *const Registry) []const Skill {
        return self.skill_items.items;
    }

    pub fn catalog(self: *const Registry) Catalog {
        return Catalog.initBounded(self.skill_items.items);
    }

    pub fn notices(self: *const Registry) []const instructions.Notice {
        return self.notice_items.items;
    }

    pub fn get(self: *const Registry, name: []const u8) ?*const Skill {
        for (self.skill_items.items) |*skill| {
            if (std.mem.eql(u8, skill.name, name)) return skill;
        }
        return null;
    }

    fn scanRoot(self: *Registry, io: std.Io, root: []const u8, scope: Skill.Scope) !void {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.warn(
                "Pith could not scan the skill directory {s} because of error {s}.",
                .{ root, @errorName(err) },
            );
            return;
        };
        defer dir.close(io);

        var walker = try dir.walkSelectively(self.gpa);
        defer walker.deinit();
        defer while (walker.stack.items.len > 0) walker.leave(io);

        var paths: PathKeeper = .{};
        defer paths.deinit(self.gpa);

        // Canonical directories already entered. The walk does not follow a
        // symlink to the root or to another followed directory twice. The
        // root seeds the set. The traversal cap backstops any residual cycle.
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var keys = visited.keyIterator();
            while (keys.next()) |key| self.gpa.free(key.*);
            visited.deinit(self.gpa);
        }
        if (try canonicalPath(self.gpa, io, root)) |canonical| {
            defer self.gpa.free(canonical);
            const owned = try self.gpa.dupe(u8, canonical);
            visited.put(self.gpa, owned, {}) catch |err| {
                self.gpa.free(owned);
                return err;
            };
        }

        var traversal_capped = false;
        for (0..entries_visited_max + 1) |attempt| {
            const maybe_entry = walker.next(io) catch |err| {
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                if (attempt == entries_visited_max) traversal_capped = true;
                try self.warn(
                    "Pith skipped one entry in {s} because of error {s}.",
                    .{ root, @errorName(err) },
                );
                continue;
            };
            const entry = maybe_entry orelse break;
            if (attempt == entries_visited_max) {
                traversal_capped = true;
                break;
            }
            switch (entry.kind) {
                .directory => walker.enter(io, entry) catch |err| {
                    if (err == error.Canceled or err == error.OutOfMemory) return err;
                    try self.warn(
                        "Pith could not scan the skill directory {s}/{s} because of error {s}.",
                        .{ root, entry.path, @errorName(err) },
                    );
                },
                .file => {
                    if (!std.mem.eql(u8, entry.basename, "SKILL.md")) continue;
                    const path = try std.fs.path.join(self.gpa, &.{ root, entry.path });
                    defer self.gpa.free(path);
                    try paths.offer(self.gpa, path);
                },
                .sym_link => try self.followLink(io, root, &entry, &walker, &paths, &visited),
                else => {},
            }
        }
        if (traversal_capped) try self.warn(
            "Pith stopped the skill scan in {s} after {d} entries.",
            .{ root, entries_visited_max },
        );
        if (paths.matched > candidates_retained_max) try self.warn(
            "Pith used only the first {d} SKILL.md paths in {s}.",
            .{ candidates_retained_max, root },
        );

        std.mem.sort([]const u8, paths.heap.items, {}, pathLessThan);
        for (paths.heap.items) |path| try self.loadPath(io, path, scope);
    }

    /// Follow a symlink entry: enter a linked directory or offer a linked
    /// `SKILL.md`. Canonical paths dedupe linked directories, so the walk
    /// enters cycles and diamonds once. The walk skips dangling and
    /// unreadable links.
    fn followLink(
        self: *Registry,
        io: std.Io,
        root: []const u8,
        entry: *const std.Io.Dir.Walker.Entry,
        walker: *std.Io.Dir.SelectiveWalker,
        paths: *PathKeeper,
        visited: *std.StringHashMapUnmanaged(void),
    ) !void {
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            if (err != error.FileNotFound) try self.warn(
                "Pith could not resolve the symbolic link {s}/{s} because of error {s}.",
                .{ root, entry.path, @errorName(err) },
            );
            return;
        };
        switch (stat.kind) {
            .file => {
                if (!std.mem.eql(u8, entry.basename, "SKILL.md")) return;
                const path = try std.fs.path.join(self.gpa, &.{ root, entry.path });
                defer self.gpa.free(path);
                try paths.offer(self.gpa, path);
            },
            .directory => {
                const joined = try std.fs.path.join(self.gpa, &.{ root, entry.path });
                defer self.gpa.free(joined);
                if (try canonicalPath(self.gpa, io, joined)) |canonical| {
                    defer self.gpa.free(canonical);
                    if (visited.contains(canonical)) return;
                    const owned = try self.gpa.dupe(u8, canonical);
                    visited.put(self.gpa, owned, {}) catch |err| {
                        self.gpa.free(owned);
                        return err;
                    };
                }
                var link = entry.*;
                link.kind = .directory;
                walker.enter(io, link) catch |err| {
                    if (err == error.Canceled or err == error.OutOfMemory) return err;
                    try self.warn(
                        "Pith could not follow the symbolic link {s}/{s} because of error {s}.",
                        .{ root, entry.path, @errorName(err) },
                    );
                };
            },
            else => {},
        }
    }

    fn loadPath(self: *Registry, io: std.Io, path: []const u8, scope: Skill.Scope) !void {
        if (!std.unicode.utf8ValidateSlice(path)) {
            const safe = try diagnostic(self.gpa, path);
            defer self.gpa.free(safe);
            try self.warn(
                "Pith skipped the skill path {s} because it is not valid UTF-8.",
                .{safe},
            );
            return;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.gpa,
            .limited(skill_file_bytes_max),
        ) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            try self.warn(
                "Pith could not read the skill file {s} because of error {s}.",
                .{ path, @errorName(err) },
            );
            return;
        };
        defer self.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data)) {
            try self.warn(
                "Pith skipped {s} because the skill file is not UTF-8 text.",
                .{path},
            );
            return;
        }

        var frontmatter = skill_header.parse(self.gpa, data) catch |err| switch (err) {
            error.MissingFrontmatter => {
                try self.warn(
                    "Pith skipped {s} because the YAML front matter is missing.",
                    .{path},
                );
                return;
            },
            error.UnclosedFrontmatter => {
                try self.warn(
                    "Pith skipped {s} because the YAML front matter is not closed.",
                    .{path},
                );
                return;
            },
            else => return err,
        };
        defer frontmatter.deinit(self.gpa);

        const description_raw = frontmatter.description orelse {
            try self.warn(
                "Pith skipped {s} because the skill description is missing or empty.",
                .{path},
            );
            return;
        };
        const description = std.mem.trim(u8, description_raw, " \t\r\n");
        if (description.len == 0) {
            try self.warn(
                "Pith skipped {s} because the skill description is missing or empty.",
                .{path},
            );
            return;
        }
        // The check above rejects a raw NUL. An escape that decodes to one
        // still must not reach the catalog. This keeps the advertised text
        // NUL-free end to end.
        if (std.mem.indexOfScalar(u8, description, 0) != null) {
            try self.warn(
                "Pith skipped {s} because the skill description contains a NUL byte.",
                .{path},
            );
            return;
        }

        const directory_path = std.fs.path.dirname(path) orelse return error.InvalidSkillPath;
        const directory_name = std.fs.path.basename(directory_path);
        const name_source = if (frontmatter.name) |declared| name: {
            if (nameValid(declared)) break :name declared;
            const safe = try diagnostic(self.gpa, declared);
            defer self.gpa.free(safe);
            try self.warn(
                "Pith used the directory name for {s} because the skill name \"{s}\" is not valid.",
                .{ path, safe },
            );
            break :name directory_name;
        } else name: {
            try self.warn(
                "Pith used the directory name for {s} because the skill name is missing.",
                .{path},
            );
            break :name directory_name;
        };
        if (!nameValid(name_source)) {
            try self.warn(
                "Pith skipped {s} because the directory name \"{s}\" is not a valid skill name.",
                .{ path, directory_name },
            );
            return;
        }
        if (!std.mem.eql(u8, name_source, directory_name)) try self.warn(
            "The skill name \"{s}\" in {s} differs from the directory name \"{s}\".",
            .{ name_source, path, directory_name },
        );
        const description_length = std.unicode.utf8CountCodepoints(description) catch unreachable;
        if (description_length > 1024) try self.warn(
            "Pith shortened the catalog description for {s} because it has more than " ++
                "1024 characters.",
            .{path},
        );

        var skill: Skill = .{
            .name = try self.gpa.dupe(u8, name_source),
            .description = undefined,
            .description_truncated = description_length > 1024,
            .path = undefined,
            .model_invocation_disabled = frontmatter.model_invocation_disabled,
            .scope = scope,
        };
        errdefer self.gpa.free(skill.name);
        skill.description = try self.gpa.dupe(u8, descriptionPrefix(description));
        errdefer self.gpa.free(skill.description);
        skill.path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(skill.path);
        try self.insert(&skill);
    }

    /// Takes `incoming` on success. Leaves it untouched on error.
    fn insert(self: *Registry, incoming: *Skill) !void {
        for (self.skill_items.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, incoming.name)) continue;
            if (incoming.scope == .project and existing.scope == .user) {
                try self.warn(
                    "The project skill \"{s}\" at {s} replaces the user skill at {s}.",
                    .{ incoming.name, incoming.path, existing.path },
                );
                existing.deinit(self.gpa);
                existing.* = incoming.*;
                incoming.* = undefined;
                return;
            }
            try self.warn(
                "Pith ignored the skill \"{s}\" at {s} because {s} has priority.",
                .{ incoming.name, incoming.path, existing.path },
            );
            incoming.deinit(self.gpa);
            return;
        }

        if (self.skill_items.items.len == skills_max) {
            if (!self.skills_capped) {
                try self.warn("Pith loaded only the first {d} distinct skills.", .{skills_max});
                self.skills_capped = true;
            }
            incoming.deinit(self.gpa);
            return;
        }
        try self.skill_items.append(self.gpa, incoming.*);
        incoming.* = undefined;
    }

    /// Record one message about the scan. Every one of them reports something
    /// the user must fix, so they all carry `.failure`.
    fn warn(
        self: *Registry,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        if (self.notices_capped) return;
        if (self.notice_items.items.len == notices_max - 1) {
            const text = try self.gpa.dupe(u8, "Pith omitted the remaining messages about the " ++
                "skill files.");
            errdefer self.gpa.free(text);
            try self.notice_items.append(self.gpa, .{ .severity = .failure, .text = text });
            self.notices_capped = true;
            return;
        }
        const text = try std.fmt.allocPrint(self.gpa, format, args);
        errdefer self.gpa.free(text);
        try self.notice_items.append(self.gpa, .{ .severity = .failure, .text = text });
    }
};

pub const DiscoverOptions = struct {
    /// Absolute `~/.agents/skills` path.
    user_root: []const u8,
    /// The absolute, canonical working directory where the project ancestor scan
    /// starts. `instructions.discover` takes the same contract, so both scans
    /// read one directory the same way.
    project_start: []const u8,
    /// The highest directory the project scan reaches, which is the Git root that
    /// `project.findBoundary` reports. It must be absolute and canonical, and
    /// `project_start` must resolve inside it.
    ///
    /// Null means that the caller found no Git root, and then the scan covers
    /// `project_start` alone. The AGENTS.md scan applies that same rule. A
    /// caller that could not read a repository marker also passes null, so this
    /// scan then stops below an ancestor that the AGENTS.md scan still reads.
    /// That errs toward fewer skills, never toward another repository.
    project_root: ?[]const u8,
};

const PathKeeper = struct {
    heap: std.PriorityQueue([]const u8, void, pathGreaterThan) = .empty,
    matched: usize = 0,

    fn deinit(self: *PathKeeper, gpa: std.mem.Allocator) void {
        for (self.heap.items) |path| gpa.free(path);
        self.heap.deinit(gpa);
    }

    fn offer(self: *PathKeeper, gpa: std.mem.Allocator, path: []const u8) !void {
        self.matched += 1;
        if (self.heap.count() < candidates_retained_max) {
            const owned = try gpa.dupe(u8, path);
            errdefer gpa.free(owned);
            try self.heap.push(gpa, owned);
        } else if (std.mem.lessThan(u8, path, self.heap.peek().?)) {
            const owned = try gpa.dupe(u8, path);
            errdefer gpa.free(owned);
            gpa.free(self.heap.pop().?);
            try self.heap.push(gpa, owned);
        }
    }
};

/// Discover user skills, then project skills from `project_start` up to
/// `project_root`. A project skill replaces a user skill of the same name. Among
/// the project directories the skill closest to `project_start` wins. A null
/// `project_root` bounds the scan at `project_start`. See
/// `DiscoverOptions.project_root`.
pub fn discover(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const DiscoverOptions,
) !Registry {
    if (!std.fs.path.isAbsolute(options.user_root) or
        !std.fs.path.isAbsolute(options.project_start))
    {
        return error.SkillPathNotAbsolute;
    }
    if (options.project_root) |project_root| {
        if (!std.fs.path.isAbsolute(project_root)) return error.SkillPathNotAbsolute;
    }
    // The repository bounds the ancestor scan. Outside a repository the working
    // directory is the whole project, so the boundary is the start itself and the
    // loop stops after one pass.
    const boundary = options.project_root orelse options.project_start;
    if (!project.contains(&.{ .boundary = boundary, .target = options.project_start })) {
        return error.SkillProjectRootNotAncestor;
    }

    var registry = Registry.init(gpa);
    errdefer registry.deinit();
    try registry.scanRoot(io, options.user_root, .user);
    const user_root_canonical = try canonicalPath(gpa, io, options.user_root);
    defer if (user_root_canonical) |path| gpa.free(path);

    var current = options.project_start;
    for (0..std.fs.max_path_bytes) |_| {
        const skills_root = try std.fs.path.join(gpa, &.{ current, ".agents", "skills" });
        defer gpa.free(skills_root);
        // At the home directory the user and project conventions can resolve to
        // the same path. Do not rediscover every file as its own shadow.
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
        // `project_start` resolves inside `boundary`, and every step shortens the
        // path, so the length alone stops the walk at the boundary.
        if (current.len <= boundary.len) break;
        const parent = std.fs.path.dirname(current) orelse break;
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
    for (0..1024) |_| {
        if (end == description.len) return description;
        end += std.unicode.utf8ByteSequenceLength(description[end]) catch unreachable;
    }
    return description[0..end];
}

/// A bounded, transcript-safe rendering of an untrusted value for a warning.
/// It caps the source length and escapes control and non-UTF-8 bytes as
/// `\xNN`. Valid UTF-8 passes through so paths and names stay legible.
fn diagnostic(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const source_bytes_max = 96;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < text.len and index < source_bytes_max) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 0;
        const printable = length > 1 or (text[index] >= 0x20 and text[index] != 0x7f);
        if (length >= 1 and index + length <= text.len and printable and
            std.unicode.utf8ValidateSlice(text[index..][0..length]))
        {
            try out.writer.writeAll(text[index..][0..length]);
            index += length;
        } else {
            try out.writer.print("\\x{x:0>2}", .{text[index]});
            index += 1;
        }
    }
    if (index < text.len) try out.writer.writeAll("…");
    return out.toOwnedSlice();
}

fn pathGreaterThan(_: void, a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, b, a);
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

fn writeTestSkill(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    const parent = std.fs.path.dirname(path).?;
    var skill_dir = try dir.createDirPathOpen(io, parent, .{});
    skill_dir.close(io);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

test "an empty registry has an empty model catalog" {
    const gpa = std.testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();
    const catalog = registry.catalog();
    try std.testing.expectEqual(@as(usize, 0), catalog.count());
    var iterator = catalog.iterator();
    try std.testing.expect(iterator.next() == null);

    var too_many: [skills_max + 1]Skill = undefined;
    try std.testing.expectError(error.TooManySkills, Catalog.init(&too_many));
}

test "a failed insert leaves the complete skill with its caller" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const gpa = failing.allocator();
    var registry = Registry.init(gpa);
    var skill: Skill = .{
        .name = try gpa.dupe(u8, "demo"),
        .description = try gpa.dupe(u8, "test skill"),
        .description_truncated = false,
        .path = try gpa.dupe(u8, "/tmp/demo/SKILL.md"),
        .model_invocation_disabled = false,
        .scope = .user,
    };

    try std.testing.expectError(error.OutOfMemory, registry.insert(&skill));
    try std.testing.expectEqualStrings("/tmp/demo/SKILL.md", skill.path);
    skill.deinit(gpa);
    registry.deinit();
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "discovery is recursive and project skills shadow user and ancestor skills" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestSkill(io, tmp.dir, "user/shared/SKILL.md", "---\n" ++
        "name: shared\ndescription: user copy\n---\nuser\n");
    try writeTestSkill(io, tmp.dir, "repo/.agents/skills/shared/SKILL.md", "---\n" ++
        "name: shared\ndescription: ancestor copy\n---\nancestor\n");
    try writeTestSkill(io, tmp.dir, "repo/work/.agents/skills/nested/shared/SKILL.md", "---\n" ++
        "name: shared\ndescription: nearest copy\n---\nnearest\n");
    try writeTestSkill(io, tmp.dir, "repo/work/.agents/skills/nested/other/SKILL.md", "---\n" ++
        "name: other\ndescription: nested copy\n---\nother\n");
    try writeTestSkill(io, tmp.dir, ".agents/skills/outside/SKILL.md", "---\n" ++
        "name: outside\ndescription: outside repo\n---\noutside\n");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/work/.agents/skills/loose.md",
        .data = "ignored",
    });

    const user_root = try tmpPath(gpa, io, &tmp, "user");
    defer gpa.free(user_root);
    const project_root = try tmpPath(gpa, io, &tmp, "repo");
    defer gpa.free(project_root);
    const project_start = try tmpPath(gpa, io, &tmp, "repo/work");
    defer gpa.free(project_start);
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
    try std.testing.expect(registry.notices().len >= 2);
}

test "a path that is not absolute and a root that is not an ancestor both fail safely" {
    const gpa = std.testing.allocator;
    // Every case fails before the first directory read, so none of them uses io.
    try std.testing.expectError(error.SkillPathNotAbsolute, discover(gpa, undefined, &.{
        .user_root = "relative",
        .project_start = "/work",
        .project_root = null,
    }));
    try std.testing.expectError(error.SkillPathNotAbsolute, discover(gpa, undefined, &.{
        .user_root = "/home/.agents/skills",
        .project_start = "relative",
        .project_root = null,
    }));
    try std.testing.expectError(error.SkillPathNotAbsolute, discover(gpa, undefined, &.{
        .user_root = "/home/.agents/skills",
        .project_start = "/work",
        .project_root = "relative",
    }));
    // A root the start does not resolve inside lets the walk climb past it.
    try std.testing.expectError(error.SkillProjectRootNotAncestor, discover(gpa, undefined, &.{
        .user_root = "/home/.agents/skills",
        .project_start = "/work",
        .project_root = "/elsewhere",
    }));
    // A shared name prefix is not a directory boundary.
    try std.testing.expectError(error.SkillProjectRootNotAncestor, discover(gpa, undefined, &.{
        .user_root = "/home/.agents/skills",
        .project_start = "/workspace",
        .project_root = "/work",
    }));
}

test "without a Git root the project scan covers only the working directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestSkill(io, tmp.dir, "user/helper/SKILL.md", "---\n" ++
        "name: helper\ndescription: user copy\n---\nuser\n");
    try writeTestSkill(io, tmp.dir, "parent/.agents/skills/ancestor/SKILL.md", "---\n" ++
        "name: ancestor\ndescription: one directory above\n---\nancestor\n");
    try writeTestSkill(io, tmp.dir, "parent/work/.agents/skills/local/SKILL.md", "---\n" ++
        "name: local\ndescription: the working directory\n---\nlocal\n");

    const user_root = try tmpPath(gpa, io, &tmp, "user");
    defer gpa.free(user_root);
    const project_start = try tmpPath(gpa, io, &tmp, "parent/work");
    defer gpa.free(project_start);
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    // The user root still loads. Only the ancestor scan stops, so no directory
    // above the working directory can add or replace a skill.
    try std.testing.expectEqual(@as(usize, 2), registry.items().len);
    try std.testing.expect(registry.get("helper") != null);
    try std.testing.expect(registry.get("local") != null);
    try std.testing.expect(registry.get("ancestor") == null);
}

test "invalid names fall back, empty descriptions skip, and hidden skills stay out of catalog" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestSkill(io, tmp.dir, "user/fallback/SKILL.md", "---\n" ++
        "name: Bad_Name\ndescription: use <this> & that\n---\nbody\n");
    try writeTestSkill(io, tmp.dir, "user/empty/SKILL.md", "---\n" ++
        "name: empty\ndescription: \"   \"\n---\nbody\n");
    try writeTestSkill(io, tmp.dir, "user/manual/SKILL.md", "---\nname: manual\n" ++
        "description: hidden from the model\n" ++
        "disable-model-invocation: true\n---\nbody\n");
    try writeTestSkill(io, tmp.dir, "user/long/SKILL.md", "---\nname: long\ndescription: " ++
        "x" ** 1025 ++ "\n---\nbody\n");
    try writeTestSkill(io, tmp.dir, "user/Bad Name/SKILL.md", "---\n" ++
        "description: a directory name that is not a valid skill name\n---\nbody\n");
    // The working directory holds no skills, so every skill here is a user one.
    var work = try tmp.dir.createDirPathOpen(io, "work", .{});
    work.close(io);

    const user_root = try tmpPath(gpa, io, &tmp, "user");
    defer gpa.free(user_root);
    const project_start = try tmpPath(gpa, io, &tmp, "work");
    defer gpa.free(project_start);
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
    try std.testing.expectEqual(@as(usize, 1024), registry.get("long").?.description.len);
    try std.testing.expect(registry.get("long").?.description_truncated);
    const catalog = registry.catalog();
    try std.testing.expectEqual(@as(usize, 2), catalog.count());
    var iterator = catalog.iterator();
    for (0..skills_max) |_| {
        const maybe_skill = iterator.next();
        if (maybe_skill == null) break;
        try std.testing.expect(!std.mem.eql(u8, maybe_skill.?.name, "manual"));
    }

    const manual = registry.get("manual").?;
    const explicit = try manual.invoke(gpa, io, "");
    defer gpa.free(explicit.content);
    try std.testing.expect(std.mem.indexOf(u8, explicit.content, manual.path) != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit.content, "body") != null);
}

test "explicit invocation loads the full file and appends arguments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "---\nname: invoke\ndescription: invocation test\n---\n# Instructions\nDo it.\n";
    try writeTestSkill(io, tmp.dir, "user/invoke/SKILL.md", source);
    var work = try tmp.dir.createDirPathOpen(io, "work", .{});
    work.close(io);

    const user_root = try tmpPath(gpa, io, &tmp, "user");
    defer gpa.free(user_root);
    const project_start = try tmpPath(gpa, io, &tmp, "work");
    defer gpa.free(project_start);
    var registry = try discover(gpa, io, &.{
        .user_root = user_root,
        .project_start = project_start,
        .project_root = null,
    });
    defer registry.deinit();

    const skill = registry.get("invoke").?;
    const invocation = try skill.invoke(gpa, io, "apply it to report.pdf");
    defer gpa.free(invocation.content);
    const prompt = invocation.content;
    try std.testing.expect(std.mem.startsWith(u8, prompt, "Skill location: "));
    try std.testing.expect(std.mem.indexOf(u8, prompt, skill.path) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, source) != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "\napply it to report.pdf"));
    // The reported size is the file alone, without the header and the arguments
    // that the expansion adds around it.
    try std.testing.expectEqual(source.len, invocation.file_bytes);
    try std.testing.expect(invocation.file_bytes < prompt.len);
}

test "discovery follows directory symlinks once and skips cycles" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A skill body outside the skills root, linked in as a directory.
    try writeTestSkill(io, tmp.dir, "external/pdf-tools/SKILL.md", "---\n" ++
        "name: pdf-tools\ndescription: linked skill\n---\nbody\n");
    var user_dir = try tmp.dir.createDirPathOpen(io, "user", .{});
    user_dir.close(io);
    var work = try tmp.dir.createDirPathOpen(io, "work", .{});
    work.close(io);

    const external = try tmpPath(gpa, io, &tmp, "external/pdf-tools");
    defer gpa.free(external);
    const user_root = try tmpPath(gpa, io, &tmp, "user");
    defer gpa.free(user_root);
    try tmp.dir.symLink(io, external, "user/pdf-tools", .{});
    // The walk must not follow a symlink back to the skills root a second time.
    try tmp.dir.symLink(io, user_root, "user/loop", .{});

    const project_start = try tmpPath(gpa, io, &tmp, "work");
    defer gpa.free(project_start);
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
    // Host filesystems reject non-UTF-8 names, so exercise the guard directly.
    // loadPath validates the path before any I/O and so never touches `io`.
    var registry = Registry.init(gpa);
    defer registry.deinit();
    try registry.loadPath(undefined, "user/\xff\xfe/SKILL.md", .user);

    try std.testing.expectEqual(@as(usize, 0), registry.items().len);
    try std.testing.expectEqual(@as(usize, 1), registry.notices().len);
    const notice = registry.notices()[0];
    try std.testing.expectEqual(instructions.Notice.Severity.failure, notice.severity);
    try std.testing.expect(std.mem.indexOf(u8, notice.text, "not valid UTF-8") != null);
    // The raw bytes must not reach the transcript verbatim.
    try std.testing.expect(std.mem.indexOf(u8, notice.text, "\\xff") != null);
}
