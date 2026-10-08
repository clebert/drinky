const std = @import("std");

const core = @import("core");

const format = @import("format.zig");
const glob = @import("glob.zig");
const output = @import("output.zig");
const skill_file = @import("skill_file.zig");
const testing = @import("testing.zig");

const SkillGuard = @This();

working_directory: []const u8 = "",
rule_items: [rules_max]Rule = undefined,
rule_count: usize = 0,

pub const rules_max = 64;

pub const Rule = struct {
    glob: []const u8,
    skill: []const u8,
    source: []const u8,
    loaded: std.atomic.Value(bool) = .init(false),
    queued: std.atomic.Value(bool) = .init(false),
};

const Demand = struct {
    rule: *const Rule,
    failure: ?skill_file.ReadError = null,
};

pub const CheckOptions = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    history: []const core.Conversation.Item,
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
    for (self.rule_items[0..self.rule_count]) |*rule| {
        rule.loaded.store(false, .monotonic);
        rule.queued.store(false, .monotonic);
    }
}

pub fn queue(self: *SkillGuard, options: *const CheckOptions) core.Runner.Error!void {
    _ = try self.demand(options);
}

pub fn refusal(
    self: *SkillGuard,
    options: *const CheckOptions,
) core.Runner.Error!?core.Tool.Output {
    const unproven = (try self.demand(options)) orelse return null;
    const gpa = options.gpa;
    const rule = unproven.rule;
    if (unproven.failure) |err| return try output.failure(
        gpa,
        .skill_required,
        "Drinky refused this call because {s} needs the skill {s}, and Drinky could not read " ++
            "the skill file {s} because of error {s}.",
        .{ options.path, rule.skill, rule.source, @errorName(err) },
    );
    return try output.failure(
        gpa,
        .skill_required,
        "Drinky refused this call because {s} needs the skill {s}. Drinky sends you the whole " ++
            "skill file next, so read it and call the tool again.",
        .{ options.path, rule.skill },
    );
}

fn demand(self: *SkillGuard, options: *const CheckOptions) core.Runner.Error!?Demand {
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
        if (!matches(&.{
            .pattern = rule.glob,
            .resolved = resolved,
            .relative = maybe_relative,
        })) continue;
        const content = skill_file.read(gpa, options.io, rule.source) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |known| return known,
            else => |failure| {
                if (first == null) first = .{ .rule = rule, .failure = failure };
                continue;
            },
        };
        defer gpa.free(content);
        if (carries(options.history, content)) {
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
    history: []const core.Conversation.Item,
) core.Runner.Error!?core.Runner.Skill {
    for (self.rule_items[0..self.rule_count]) |*rule| {
        if (!rule.queued.load(.monotonic)) continue;
        rule.queued.store(false, .monotonic);
        const content = skill_file.read(gpa, io, rule.source) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |known| return known,
            else => continue,
        };
        defer gpa.free(content);
        if (carries(history, content)) {
            rule.loaded.store(true, .monotonic);
            continue;
        }
        var delivery: std.Io.Writer.Allocating = .init(gpa);
        errdefer delivery.deinit();
        delivery.writer.print(
            "Drinky sends you this skill because the pattern {s} requires it.\n",
            .{rule.glob},
        ) catch return error.OutOfMemory;
        skill_file.write(&delivery.writer, &.{ .path = rule.source, .content = content }) catch
            return error.OutOfMemory;
        const text = try delivery.toOwnedSlice();
        errdefer gpa.free(text);
        const name = try gpa.dupe(u8, rule.skill);
        errdefer gpa.free(name);
        return .{ .name = name, .source = try gpa.dupe(u8, rule.source), .text = text };
    }
    return null;
}

fn carries(history: []const core.Conversation.Item, content: []const u8) bool {
    if (content.len == 0) return false;
    for (history) |item| {
        const text = switch (item) {
            .message => |message| message.text,
            .tool_result => |result| if (result.output.hasFailure())
                continue
            else
                result.output.content,
            .reasoning, .tool_call => continue,
        };
        if (std.mem.find(u8, text, content) != null) return true;
    }
    return false;
}

fn matches(query: *const struct {
    pattern: []const u8,
    resolved: []const u8,
    relative: ?[]const u8,
}) bool {
    if (query.relative) |relative| {
        if (glob.match(&.{ .pattern = query.pattern, .path = relative })) return true;
    }
    return glob.match(&.{ .pattern = query.pattern, .path = query.resolved });
}

fn resolve(
    self: *const SkillGuard,
    gpa: std.mem.Allocator,
    target: []const u8,
) error{OutOfMemory}![]u8 {
    if (self.working_directory.len == 0 or std.Io.Dir.path.isAbsolute(target))
        return std.Io.Dir.path.resolve(gpa, &.{target});
    return std.Io.Dir.path.resolve(gpa, &.{ self.working_directory, target });
}

test "a rule refuses a matching write until the history carries the whole skill file" {
    const gpa = std.testing.allocator;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);

    const refused = (try refusalOf(&fixture, gpa, &.{})).?;
    defer refused.deinit(gpa);
    try testing.expectConditions(&refused, &.{.skill_required});
    try std.testing.expect(std.mem.find(u8, refused.content, "zig-style") != null);
    try std.testing.expect(std.mem.find(u8, refused.content, "sends you") != null);
    try testing.expectMeasures(&refused, &.{});

    const read_history = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "format this" } },
        .{ .tool_result = .{ .call_id = "1", .output = .{ .content = fixture.body } } },
    };
    try std.testing.expect((try refusalOf(&fixture, gpa, &read_history)) == null);
    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);

    try std.testing.expect((try refusalOf(&fixture, gpa, &.{})) == null);

    fixture.guard.forget();
    const again = (try refusalOf(&fixture, gpa, &.{})).?;
    defer again.deinit(gpa);
    try std.testing.expect(again.hasFailure());
}

fn refusalOf(
    fixture: *testing.SkillFixture,
    gpa: std.mem.Allocator,
    history: []const core.Conversation.Item,
) !?core.Tool.Output {
    return fixture.guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = history,
    });
}

test "a read of a matching path queues the skill file, and the delivery carries it whole" {
    const gpa = std.testing.allocator;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);

    try fixture.guard.queue(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = &.{},
    });

    const skill = (try fixture.guard.takeQueued(gpa, std.testing.io, &.{})).?;
    defer skill.deinit(gpa);
    try std.testing.expectEqualStrings("zig-style", skill.name);
    try std.testing.expectEqualStrings(fixture.source, skill.source);
    try std.testing.expect(std.mem.find(u8, skill.text, "**/*.zig") != null);
    try std.testing.expect(std.mem.find(u8, skill.text, "Skill location: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, skill.text, fixture.body));

    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);
    const history = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = skill.text } },
    };
    try std.testing.expect((try refusalOf(&fixture, gpa, &history)) == null);

    fixture.guard.forget();
    try fixture.guard.queue(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "README.md",
        .history = &.{},
    });
    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);
}

test "a forget drops a queued skill, so a new conversation receives none" {
    const gpa = std.testing.allocator;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);

    try fixture.guard.queue(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = &.{},
    });
    fixture.guard.forget();

    const maybe_skill = try fixture.guard.takeQueued(gpa, std.testing.io, &.{});
    defer if (maybe_skill) |skill| skill.deinit(gpa);
    try std.testing.expect(maybe_skill == null);
}

test "two rules that share one skill file deliver it once" {
    const gpa = std.testing.allocator;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);
    try fixture.guard.add(.{
        .glob = "src/**",
        .skill = "zig-style",
        .source = fixture.source,
    });

    try fixture.guard.queue(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = &.{},
    });

    const skill = (try fixture.guard.takeQueued(gpa, std.testing.io, &.{})).?;
    defer skill.deinit(gpa);
    const history = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = skill.text } },
    };
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
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);
    var guard: SkillGuard = .{ .working_directory = fixture.root };
    try guard.add(.{ .glob = "**/*.md", .skill = "docs-style", .source = fixture.source });

    try guard.queue(&.{
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

    const other = try std.Io.Dir.path.join(gpa, &.{ fixture.root, "README.md" });
    defer gpa.free(other);
    const refused = (try guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = other,
        .history = &.{},
    })).?;
    defer refused.deinit(gpa);
    try std.testing.expect(refused.hasFailure());
}

test "a skill file that vanished leaves the queue silently" {
    const gpa = std.testing.allocator;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);
    try fixture.guard.queue(&.{
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
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);
    const cases = [_][]const core.Conversation.Item{
        &.{.{ .tool_result = .{
            .call_id = "1",
            .output = .{ .content = "---\nname: zig-style\n---\n" },
        } }},
        &.{.{ .tool_result = .{
            .call_id = "1",
            .output = .{ .content = fixture.body, .conditions = .initOne(.failed) },
        } }},
        &.{.{ .tool_call = .{
            .id = "1",
            .name = "read",
            .arguments = "{\"path\":\"SKILL.md\"}",
        } }},
        &.{.{ .reasoning = .{ .account = "account-a", .payload = fixture.body } }},
    };
    for (cases) |history| {
        const refused = (try refusalOf(&fixture, gpa, history)).?;
        defer refused.deinit(gpa);
        try std.testing.expect(refused.hasFailure());
    }

    const invoked = try gpa.print(
        "Skill location: {s}\n\n{s}\nformat the file",
        .{ fixture.source, fixture.body },
    );
    defer gpa.free(invoked);
    const history = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = invoked } },
    };
    try std.testing.expect((try refusalOf(&fixture, gpa, &history)) == null);
}

test "a skill file Drinky cannot read refuses the call and names the error" {
    const gpa = std.testing.allocator;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);
    try fixture.tmp.dir.deleteFile(std.testing.io, "SKILL.md");

    const refused = (try refusalOf(&fixture, gpa, &.{})).?;
    defer refused.deinit(gpa);
    try testing.expectConditions(&refused, &.{.skill_required});
    try std.testing.expect(std.mem.find(u8, refused.content, "FileNotFound") != null);
    try std.testing.expect(std.mem.find(u8, refused.content, fixture.source) != null);
}

test "a glob measures against the working directory, and against the absolute path" {
    const gpa = std.testing.allocator;
    var fixture: testing.SkillFixture = try .init(gpa);
    defer fixture.deinit(gpa);

    var rooted: SkillGuard = .{ .working_directory = fixture.root };
    try rooted.add(.{ .glob = "src/**/*.zig", .skill = "zig-style", .source = fixture.source });
    const inside = try std.Io.Dir.path.join(gpa, &.{ fixture.root, "src", "App.zig" });
    defer gpa.free(inside);
    const refused = (try rooted.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = inside,
        .history = &.{},
    })).?;
    defer refused.deinit(gpa);
    try std.testing.expect(refused.hasFailure());
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
    try std.testing.expect(outside.hasFailure());

    var operations: SkillGuard = .{ .working_directory = fixture.root };
    try operations.add(.{ .glob = "/etc/**", .skill = "ops", .source = fixture.source });
    const hosts = (try operations.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "/etc/hosts",
        .history = &.{},
    })).?;
    defer hosts.deinit(gpa);
    try std.testing.expect(std.mem.find(u8, hosts.content, "skill ops") != null);
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
