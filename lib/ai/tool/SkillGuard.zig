//! The path-triggered skill guard. One rule pairs a path glob with a discovered
//! skill. When a tool touches a file that a rule matches, the guard proves that
//! the conversation carries the whole skill file. Without that proof it queues
//! the skill file for delivery, and it refuses a call that changes the file.
//!
//! A read is never refused. It only queues, so a role that reads and never
//! writes still receives the rules of the files it reads. The host delivers the
//! queue at the next round of the turn, as one message that carries the whole
//! skill file. The model therefore meets the rules one round after it first
//! touches such a file, and a refused write succeeds on its next try without a
//! read of its own.
//!
//! The proof is the history itself, never a flag that a tool sets. Every route
//! into a conversation carries the skill file verbatim: `read` returns the bytes
//! of a file as they are, a `/skill:name` line sends them as a user message, and
//! so does the delivery above. So the guard reads the skill file and searches
//! the history for that exact text. A conversation that Drinky loads from disk
//! proves itself the same way, and a history that loses the text queues the
//! skill again.
//!
//! The host owns the rules, because only the host knows the user configuration
//! and the discovered skills. The guard holds no memory of its own: every string
//! belongs to the host and must outlive the guard.
//!
//! A proof holds for the rest of the conversation, so each rule keeps one memo
//! and the search runs at most once per rule. The memo is only true for the
//! history it was proven against, so `forget` drops every memo whenever the
//! history loses items.
//!
//! Read-only tools run at the same time, so both flags of a rule are atomic.
//! The rules themselves never change after startup.

const std = @import("std");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const glob = @import("glob.zig");
const Result = @import("Result.zig");

const SkillGuard = @This();

/// The absolute working directory that a glob measures against. Empty leaves
/// every path in the form the tool received it.
working_directory: []const u8 = "",
rule_items: [rules_max]Rule = undefined,
rule_count: usize = 0,

/// The rules one session applies. The cap keeps the guard allocation-free, and
/// a session with more rules than this states more than a model can hold.
pub const rules_max = 64;

/// The largest skill file the guard reads for a proof. The skill scan refuses a
/// file above the window of one `read` call, which is far below this, so this
/// bound only stops a file that grew after that scan.
const source_bytes_max = 1 << 20;

/// One path-triggered skill.
pub const Rule = struct {
    /// The path glob that requires the skill.
    glob: []const u8,
    /// The name of the required skill.
    skill: []const u8,
    /// The absolute `SKILL.md` path of that skill, in resolved form.
    source: []const u8,
    /// Whether an earlier check found the whole skill file in this history. It
    /// is a memo of that search, never evidence of its own.
    loaded: std.atomic.Value(bool) = .init(false),
    /// Whether the skill file waits for delivery into the conversation. The
    /// host takes it at the next round of the turn.
    queued: std.atomic.Value(bool) = .init(false),
};

/// What one check found: the first rule of the file that the conversation
/// cannot prove. `failure` names the error that stopped Drinky from reading the
/// skill file, and it is null when the skill file waits for delivery instead.
pub const Demand = struct {
    rule: *const Rule,
    failure: ?anyerror = null,
};

/// One queued skill file, ready for the conversation. `text` is owned by the
/// caller. The names borrow their rule.
pub const Delivery = struct {
    skill: []const u8,
    source: []const u8,
    text: []u8,
};

/// What one check needs: the file the call writes, and the history that must
/// carry the proof.
pub const CheckOptions = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The path the call writes, as the model wrote it.
    path: []const u8,
    /// The history below the reply that asked for this call. The reply itself
    /// stays out, so a skill that one reply reads cannot license a write that
    /// the same reply already asked for.
    history: []const llm.Item,
};

/// Add one rule. The guard takes no copy, so every string of `rule` must
/// outlive the guard.
pub fn add(self: *SkillGuard, rule: Rule) error{TooManyRules}!void {
    if (self.rule_count == rules_max) return error.TooManyRules;
    self.rule_items[self.rule_count] = rule;
    self.rule_count += 1;
}

/// The rules of the session, in configured order. The system prompt names them,
/// so the model reads a skill before a write rather than after a refusal.
pub fn rules(self: *const SkillGuard) []const Rule {
    return self.rule_items[0..self.rule_count];
}

/// Drop every memo. A history that loses items can lose a proof with them, so
/// the next check searches again. A new conversation and a rolled-back turn
/// both pass through here. A queued skill file stays queued, because a
/// conversation that lost it needs it again.
pub fn forget(self: *SkillGuard) void {
    for (self.rule_items[0..self.rule_count]) |*rule| rule.loaded.store(false, .monotonic);
}

/// Prove every rule that `options.path` triggers, and queue the skill file of
/// each rule that this conversation cannot prove. A tool that only reads calls
/// this and goes ahead: the delivery reaches the model one round later.
pub fn require(self: *SkillGuard, options: *const CheckOptions) !void {
    _ = try self.demand(options);
}

/// The refusal for a call that changes `options.path`, or null when every rule
/// that matches the file has its skill in the history. The call queues what it
/// refuses, so the next try needs no read of its own. The caller hands the
/// result back to the model as it is.
pub fn refusal(self: *SkillGuard, options: *const CheckOptions) !?Result {
    const unproven = (try self.demand(options)) orelse return null;
    const gpa = options.gpa;
    const rule = unproven.rule;
    // The rule stands and its file is out of reach, so the call cannot go
    // ahead. The sentence names the error, because only the user can fix it.
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

/// Prove or queue every rule that `options.path` triggers, and report the first
/// rule that this conversation cannot prove.
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
        // A rule never guards its own skill file. A read of that file is the
        // load itself, and a change to it needs no rule of its own. Without
        // this skip, a pattern that covers the skill file sends it twice.
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
            // The proof arrived by another route, so drop a waiting delivery
            // rather than send the same text twice.
            rule.queued.store(false, .monotonic);
            continue;
        }
        rule.queued.store(true, .monotonic);
        if (first == null) first = .{ .rule = rule };
    }
    return first;
}

/// Take the next queued skill file as one message for the conversation. Null
/// reports that nothing waits. A rule whose proof already stands in `history`
/// leaves the queue without a message, so two rules that share one skill file
/// deliver it once, and a proof that arrived in the queued round is not sent
/// again. A skill file that Drinky cannot read now also leaves the queue
/// silently, because only a call that changes a file can report that failure
/// to the model.
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
        // The head reads the way a `/skill:name` line reads, and the file goes
        // in as it is, so one search of the history proves either route.
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

/// The whole skill file of one rule. The caller owns the bytes.
fn readSource(io: std.Io, gpa: std.mem.Allocator, rule: *const Rule) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, rule.source, gpa, .limited(source_bytes_max));
}

/// Whether the conversation carries `source` word for word. A tool result holds
/// the bytes of a file as `read` returned them, and a message holds them as a
/// `/skill:name` line sent them. Reasoning is opaque, and a tool call states
/// what a call asked for rather than what the model read.
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

/// Whether `pattern` covers one file. A glob measures against the path relative
/// to the working directory, so `**/*.zig` reads the way the user writes it. The
/// absolute path takes a second try, so an absolute pattern reaches a file
/// outside that directory too.
fn matches(pattern: []const u8, resolved: []const u8, maybe_relative: ?[]const u8) bool {
    if (maybe_relative) |relative| {
        if (glob.match(.{ .pattern = pattern, .path = relative })) return true;
    }
    return glob.match(.{ .pattern = pattern, .path = resolved });
}

/// `target` in absolute, normalized form. A relative path resolves against the
/// working directory. The result is owned.
fn resolve(self: *const SkillGuard, gpa: std.mem.Allocator, target: []const u8) ![]u8 {
    if (self.working_directory.len == 0 or std.fs.path.isAbsolute(target))
        return std.fs.path.resolve(gpa, &.{target});
    return std.fs.path.resolve(gpa, &.{ self.working_directory, target });
}

/// A guard over one Zig rule whose skill file lives in `tmp`, in the shape the
/// app builds at startup. The caller frees the returned source path.
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

    // An empty conversation proves nothing.
    const refused = (try fixture.check(gpa, &.{})).?;
    defer refused.deinit(gpa);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.content, "zig-style") != null);
    // The refusal states that the file follows, because the guard queued it.
    try std.testing.expect(std.mem.indexOf(u8, refused.content, "sends you") != null);
    // The box shows the sentence of the failure, so it wraps rather than cuts.
    try std.testing.expectEqual(Result.Summary.Kind.sentence, refused.summary.?.kind);

    // A `read` returns the bytes of the file as they are, so its result is the
    // proof. The history below it is not searched for anything else.
    const read_history = [_]llm.Item{
        .{ .message = .{ .role = .user, .text = "format this" } },
        .{ .tool_result = .{ .call_id = "1", .content = fixture.body, .is_error = false } },
    };
    try std.testing.expect((try fixture.check(gpa, &read_history)) == null);
    // The proof arrived by itself, so the delivery that the refusal queued
    // drops rather than repeat the text.
    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);

    // The memo holds for the rest of the conversation, so one search serves
    // every later call.
    try std.testing.expect((try fixture.check(gpa, &.{})) == null);

    // A history that lost items can have lost the proof with them.
    fixture.guard.forget();
    const again = (try fixture.check(gpa, &.{})).?;
    defer again.deinit(gpa);
    try std.testing.expect(again.is_error);
}

// A read is never refused. It queues the skill instead, so a role that reads
// and never writes still meets the rules of the files it reads.
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
    // The head names the pattern and the file, and the file goes in as it is,
    // so one search of the history proves this route too.
    try std.testing.expect(std.mem.indexOf(u8, delivery.text, "**/*.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, delivery.text, "Skill location: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, delivery.text, fixture.body));

    // One delivery per queued rule, and the delivered text is the proof.
    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);
    const history = [_]llm.Item{.{ .message = .{ .role = .user, .text = delivery.text } }};
    try std.testing.expect((try fixture.check(gpa, &history)) == null);

    // A file that no rule matches queues nothing.
    fixture.guard.forget();
    try fixture.guard.require(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "README.md",
        .history = &.{},
    });
    try std.testing.expect((try fixture.guard.takeQueued(gpa, std.testing.io, &.{})) == null);
}

// Two rules can share one skill file. One boundary delivers that file once,
// because the first delivery is the proof for the second rule.
test "two rules that share one skill file deliver it once" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);
    try fixture.guard.add(.{
        .glob = "src/**",
        .skill = "zig-style",
        .source = fixture.source,
    });

    // One touch of a file that both patterns match queues both rules.
    try fixture.guard.require(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/App.zig",
        .history = &.{},
    });

    const delivery = (try fixture.guard.takeQueued(gpa, std.testing.io, &.{})).?;
    defer gpa.free(delivery.text);
    // The first delivery stands in the history now, so the second rule proves
    // itself and sends nothing.
    const history = [_]llm.Item{.{ .message = .{ .role = .user, .text = delivery.text } }};
    try std.testing.expect(
        (try fixture.guard.takeQueued(gpa, std.testing.io, &history)) == null,
    );
    // The settled rule needs no later search either: a write of a file that
    // only the second pattern matches goes ahead.
    try std.testing.expect((try fixture.guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "src/data.json",
        .history = &.{},
    })) == null);
}

// A pattern can cover the skill file of its own rule. That file must not
// require itself, or Drinky sends the model a file it holds already.
test "a rule never guards its own skill file" {
    const gpa = std.testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer fixture.deinit(gpa);
    var guard: SkillGuard = .{ .working_directory = fixture.root };
    try guard.add(.{ .glob = "**/*.md", .skill = "docs-style", .source = fixture.source });

    // A read of the file is the load, so nothing queues.
    try guard.require(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = fixture.source,
        .history = &.{},
    });
    try std.testing.expect((try guard.takeQueued(gpa, std.testing.io, &.{})) == null);

    // A change to the file needs no rule of its own either.
    try std.testing.expect((try guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = fixture.source,
        .history = &.{},
    })) == null);

    // Every other file of the pattern still needs the skill.
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

// A queued file that Drinky cannot read leaves the queue with no message. Only a
// call that changes a file reports that failure, because only it stops.
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
        // A window over the file holds a part of it alone.
        &.{.{ .tool_result = .{
            .call_id = "1",
            .content = "---\nname: zig-style\n---\n",
            .is_error = false,
        } }},
        // A call that failed returned no file at all.
        &.{.{ .tool_result = .{
            .call_id = "1",
            .content = fixture.body,
            .is_error = true,
        } }},
        // A call states what the model asked for, not what it read.
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

    // A `/skill:name` line sends the file inside one user message, with a head
    // above it and a task below it.
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

    // A pattern that names a directory of the project cannot reach a file
    // outside it, because that file keeps its absolute path.
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

    // A pattern that starts with `**` covers every path, so it guards a file
    // outside the project too.
    const outside = (try fixture.guard.refusal(&.{
        .gpa = gpa,
        .io = std.testing.io,
        .path = "/other/src/App.zig",
        .history = &.{},
    })).?;
    defer outside.deinit(gpa);
    try std.testing.expect(outside.is_error);

    // An absolute pattern reads absolute paths alone.
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
