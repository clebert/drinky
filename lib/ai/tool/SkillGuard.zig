const std = @import("std");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const glob = @import("glob.zig");
const Result = @import("Result.zig");

const SkillGuard = @This();

working_directory: []const u8 = "",
rule_items: [rules_max]Rule = undefined,
rule_count: usize = 0,

pub const rules_max = 64;

const source_bytes_max = 1 << 20;

pub const Rule = struct {
    glob: []const u8,
    skill: []const u8,
    source: []const u8,
    loaded: std.atomic.Value(bool) = .init(false),
    queued: std.atomic.Value(bool) = .init(false),
};

pub const Demand = struct {
    rule: *const Rule,
    failure: ?anyerror = null,
};

pub const Delivery = struct {
    skill: []const u8,
    source: []const u8,
    text: []u8,
};

pub const CheckOptions = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    history: []const llm.Item,
};

pub fn add(self: *SkillGuard, rule: Rule) error{TooManyRules}!void {
    if (self.rule_count == rules_max) return error.TooManyRules;
    self.rule_items[self.rule_count] = rule;
    self.rule_count += 1;
}

pub fn rules(self: *const SkillGuard) []const Rule {
    return self.rule_items[0..self.rule_count];
}

pub fn forget(self: *SkillGuard) void {
    for (self.rule_items[0..self.rule_count]) |*rule| rule.loaded.store(false, .monotonic);
}

pub fn require(self: *SkillGuard, options: *const CheckOptions) !void {
    _ = try self.demand(options);
}

pub fn refusal(self: *SkillGuard, options: *const CheckOptions) !?Result {
    const unproven = (try self.demand(options)) orelse return null;
    const gpa = options.gpa;
    const rule = unproven.rule;
    if (unproven.failure) |err| return try Result.report(
        gpa,
        .err,
        "Drinky refused this call because {s} needs the skill {s}, and Drinky could not read " ++
            "the skill file {s} because of error {s}.",
        .{ options.path, rule.skill, rule.source, @errorName(err) },
    );
    return try Result.report(
        gpa,
        .err,
        "Drinky refused this call because {s} needs the skill {s}. Drinky sends you the whole " ++
            "skill file next, so read it and call the tool again.",
        .{ options.path, rule.skill },
    );
}

fn demand(self: *SkillGuard, options: *const CheckOptions) !?Demand {
    if (self.rule_count == 0) return null;
    const gpa = options.gpa;
    const resolved = try self.resolve(gpa, options.path);
    defer gpa.free(resolved);
    const maybe_relative = format.relativeTo(&.{
        .boundary = self.working_directory,
        .target = resolved,
    });
    var first: ?Demand = null;
    for (self.rule_items[0..self.rule_count]) |*rule| {
        if (rule.loaded.load(.monotonic)) continue;
        if (std.mem.eql(u8, rule.source, resolved)) continue;
        if (!matches(rule.glob, resolved, maybe_relative)) continue;
        const source = readSource(options.io, gpa, rule) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            if (first == null) first = .{ .rule = rule, .failure = err };
            continue;
        };
        defer gpa.free(source);
        if (carries(options.history, source)) {
            rule.loaded.store(true, .monotonic);
            rule.queued.store(false, .monotonic);
            continue;
        }
        rule.queued.store(true, .monotonic);
        if (first == null) first = .{ .rule = rule };
    }
    return first;
}

pub fn takeQueued(
    self: *SkillGuard,
    gpa: std.mem.Allocator,
    io: std.Io,
    history: []const llm.Item,
) !?Delivery {
    for (self.rule_items[0..self.rule_count]) |*rule| {
        if (!rule.queued.load(.monotonic)) continue;
        rule.queued.store(false, .monotonic);
        const source = readSource(io, gpa, rule) catch |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
            continue;
        };
        defer gpa.free(source);
        if (carries(history, source)) {
            rule.loaded.store(true, .monotonic);
            continue;
        }
        const directory = std.fs.path.dirname(rule.source) orelse rule.source;
        var text: std.Io.Writer.Allocating = .init(gpa);
        errdefer text.deinit();
        try text.writer.print(
            "Drinky sends you this skill because the pattern {s} requires it.\n" ++
                "Skill location: {s}\nResolve relative paths in this skill against: {s}\n\n",
            .{ rule.glob, rule.source, directory },
        );
        try text.writer.writeAll(source);
        return .{
            .skill = rule.skill,
            .source = rule.source,
            .text = try text.toOwnedSlice(),
        };
    }
    return null;
}

fn readSource(io: std.Io, gpa: std.mem.Allocator, rule: *const Rule) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, rule.source, gpa, .limited(source_bytes_max));
}

fn carries(history: []const llm.Item, source: []const u8) bool {
    if (source.len == 0) return false;
    for (history) |item| {
        const text = switch (item) {
            .message => |message| message.text,
            .tool_result => |result| if (result.is_error) continue else result.content,
            else => continue,
        };
        if (std.mem.indexOf(u8, text, source) != null) return true;
    }
    return false;
}

fn matches(pattern: []const u8, resolved: []const u8, maybe_relative: ?[]const u8) bool {
    if (maybe_relative) |relative| {
        if (glob.match(.{ .pattern = pattern, .path = relative })) return true;
    }
    return glob.match(.{ .pattern = pattern, .path = resolved });
}

fn resolve(self: *const SkillGuard, gpa: std.mem.Allocator, target: []const u8) ![]u8 {
    if (self.working_directory.len == 0 or std.fs.path.isAbsolute(target))
        return std.fs.path.resolve(gpa, &.{target});
    return std.fs.path.resolve(gpa, &.{ self.working_directory, target });
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    guard: SkillGuard,
    root: []u8,
    source: []u8,
    body: []const u8 = "---\nname: zig-style\n---\nUse four spaces.\n",

    fn init(gpa: std.mem.Allocator) !Fixture {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var fixture: Fixture = .{
            .tmp = tmp,
            .guard = undefined,
            .root = undefined,
            .source = undefined,
        };
        try tmp.dir.writeFile(io, .{ .sub_path = "SKILL.md", .data = fixture.body });
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        fixture.root = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
        errdefer gpa.free(fixture.root);
        fixture.source = try std.fs.path.join(gpa, &.{ fixture.root, "SKILL.md" });
        errdefer gpa.free(fixture.source);
        fixture.guard = .{ .working_directory = fixture.root };
        try fixture.guard.add(.{
            .glob = "**/*.zig",
            .skill = "zig-style",
            .source = fixture.source,
        });
        return fixture;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        gpa.free(self.root);
        gpa.free(self.source);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn check(self: *Fixture, gpa: std.mem.Allocator, history: []const llm.Item) !?Result {
        return self.guard.refusal(&.{
            .gpa = gpa,
            .io = std.testing.io,
            .path = "src/App.zig",
            .history = history,
        });
    }
};

test "a rule refuses a matching write until the history carries the whole skill file" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    const refused = (try fixture.check(gpa, &.{})).?;
    defer refused.deinit(gpa);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.content, "zig-style") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused.content, "sends you") != null);
    try std.testing.expectEqual(Result.Summary.Kind.sentence, refused.summary.?.kind);

    const read_history = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "format this" } },
        .{ .tool_result = .{ .call_id = "1", .content = fixture.body, .is_error = false } },
    };
    try std.testing.expect((try fixture.check(gpa, &read_history)) == null);
    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);

    try std.testing.expect((try fixture.check(gpa, &.{})) == null);

    fixture.guard.forget();
    const again = (try fixture.check(gpa, &.{})).?;
    defer again.deinit(gpa);
    try std.testing.expect(again.is_error);
}

test "a read queues the skill file, and the delivery carries it whole" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    try fixture.guard.require(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = &.{},
    });

    const delivery = (try fixture.guard.takeQueued(gpa, std.testing.io, &.{})).?;
    defer gpa.free(delivery.text);
    try std.testing.expectEqualStrings("zig-style", delivery.skill);
    try std.testing.expectEqualStrings(fixture.source, delivery.source);
    try std.testing.expect(std.mem.indexOf(u8, delivery.text, "**/*.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, delivery.text, "Skill location: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, delivery.text, fixture.body));

    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);
    const history = [_]llm.Item{.{ .message = .{ .role = .user, .text = delivery.text } }};
    try std.testing.expect((try fixture.check(gpa, &history)) == null);

    fixture.guard.forget();
    try fixture.guard.require(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "README.md",
        .history = &.{},
    });
    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);
}

test "two rules that share one skill file deliver it once" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);
    try fixture.guard.add(.{
        .glob = "src/**",
        .skill = "zig-style",
        .source = fixture.source,
    });

    try fixture.guard.require(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = &.{},
    });

    const delivery = (try fixture.guard.takeQueued(gpa, std.testing.io, &.{})).?;
    defer gpa.free(delivery.text);
    const history = [_]llm.Item{.{ .message = .{ .role = .user, .text = delivery.text } }};
    try std.testing.expect(
        (try fixture.guard.takeQueued(gpa, std.testing.io, &history)) == null,
    );
    try std.testing.expect((try fixture.guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/data.json",
        .history = &.{},
    })) == null);
}

test "a rule never guards its own skill file" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);
    var guard: SkillGuard = .{ .working_directory = fixture.root };
    try guard.add(.{ .glob = "**/*.md", .skill = "docs-style", .source = fixture.source });

    try guard.require(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = fixture.source,
        .history = &.{},
    });
    try std.testing.expect((try guard.takeQueued(gpa, std.testing.io, &.{})) == null);

    try std.testing.expect((try guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = fixture.source,
        .history = &.{},
    })) == null);

    const other = try std.fs.path.join(gpa, &.{ fixture.root, "README.md" });
    defer gpa.free(other);
    const refused = (try guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = other,
        .history = &.{},
    })).?;
    defer refused.deinit(gpa);
    try std.testing.expect(refused.is_error);
}

test "a skill file that vanished leaves the queue silently" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);
    try fixture.guard.require(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = &.{},
    });
    try fixture.tmp.dir.deleteFile(std.testing.io, "SKILL.md");

    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);
}

test "a partial file, a failed call, and opaque items prove nothing" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);
    const cases = [_][]const llm.Item{
        &.{.{ .tool_result = .{
            .call_id = "1",
            .content = "---\nname: zig-style\n---\n",
            .is_error = false,
        } }},
        &.{.{ .tool_result = .{
            .call_id = "1",
            .content = fixture.body,
            .is_error = true,
        } }},
        &.{.{ .tool_call = .{
            .call_id = "1",
            .name = "read",
            .arguments_json = "{\"path\":\"SKILL.md\"}",
        } }},
    };
    for (cases) |history| {
        const refused = (try fixture.check(gpa, history)).?;
        defer refused.deinit(gpa);
        try std.testing.expect(refused.is_error);
    }

    const invoked = try std.fmt.allocPrint(
        gpa,
        "Skill location: {s}\n\n{s}\nformat the file",
        .{ fixture.source, fixture.body },
    );
    defer gpa.free(invoked);
    const history = [_]llm.Item{.{ .message = .{ .role = .user, .text = invoked } }};
    try std.testing.expect((try fixture.check(gpa, &history)) == null);
}

test "a skill file Drinky cannot read refuses the call and names the error" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);
    try fixture.tmp.dir.deleteFile(std.testing.io, "SKILL.md");

    const refused = (try fixture.check(gpa, &.{})).?;
    defer refused.deinit(gpa);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.content, "FileNotFound") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused.content, fixture.source) != null);
}

test "a glob measures against the working directory, and against the absolute path" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);

    var rooted: SkillGuard = .{ .working_directory = fixture.root };
    try rooted.add(.{ .glob = "src/**/*.zig", .skill = "zig-style", .source = fixture.source });
    const inside = try std.fs.path.join(gpa, &.{ fixture.root, "src", "App.zig" });
    defer gpa.free(inside);
    const refused = (try rooted.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = inside,
        .history = &.{},
    })).?;
    defer refused.deinit(gpa);
    try std.testing.expect(refused.is_error);
    try std.testing.expect((try rooted.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "/other/src/App.zig",
        .history = &.{},
    })) == null);

    const outside = (try fixture.guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "/other/src/App.zig",
        .history = &.{},
    })).?;
    defer outside.deinit(gpa);
    try std.testing.expect(outside.is_error);

    var operations: SkillGuard = .{ .working_directory = fixture.root };
    try operations.add(.{ .glob = "/etc/**", .skill = "ops", .source = fixture.source });
    const hosts = (try operations.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "/etc/hosts",
        .history = &.{},
    })).?;
    defer hosts.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, hosts.content, "skill ops") != null);
}

test "an empty guard blocks nothing and the rule count is capped" {
    const gpa = std.testing.allocator;
    var guard: SkillGuard = .{ .working_directory = "/work" };
    try std.testing.expectEqual(@as(usize, 0), guard.rules().len);
    try std.testing.expect((try guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = &.{},
    })) == null);

    for (0..rules_max) |_| {
        try guard.add(.{ .glob = "**", .skill = "any", .source = "/skills/any/SKILL.md" });
    }
    try std.testing.expectError(error.TooManyRules, guard.add(.{
        .glob = "**",
        .skill = "any",
        .source = "/skills/any/SKILL.md",
    }));
    try std.testing.expectEqual(@as(usize, rules_max), guard.rules().len);
}
