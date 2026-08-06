//! The machine-local startup state in `<home>/.pith/state.json`: the account,
//! the model, and the effort level that each project used last. It is mutable
//! state, not configuration. `config.json` stays a curated file the user can
//! share, and this file holds what the interface changes as the user works.
//!
//! The file is a keyed JSON object. Each key is a project: the Git root, or the
//! working directory when Pith found no Git root. One project therefore keeps
//! one choice, and two projects can run different accounts.
//!
//! Pith reads the file once, at startup. A change in another instance reaches
//! only the next start, never a running session. A write happens when the user
//! changes the account, the model, or the effort level. The write goes through
//! `ai.json_store`, so it is atomic, owner-only, and preserves every other
//! project. The file keeps the `projects_max` most recently written projects.
//!
//! Nothing here is authoritative. Every read failure reads as nothing
//! remembered, and the caller falls back to its configured or compiled default.
//! A failed write stops every later write, so one broken file reports once
//! instead of on every change.

const std = @import("std");

const ai = @import("ai");

const State = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// The `state.json` path. Owned.
path: []const u8,
/// The project this session reads and writes. Owned.
project: []const u8,
/// What the file held for the project at startup. It does not change after
/// `open`, because a running session never re-reads the file.
start: Start,
/// The choices Pith seeded or recorded last, so an unchanged choice writes
/// nothing. Null until the first `seed` or `record`.
saved: ?Saved,
/// True while Pith still writes the file. A failed write clears it, because a
/// broken file breaks every later write the same way.
save_enabled: bool,

/// What the file held for the project. Each field is null when the file held no
/// usable value, so the caller applies its own default. A resolved model points
/// into the compiled model table, so this owns no memory.
pub const Start = struct {
    /// The account and the model that ran on it. The two come as one value,
    /// because a model applies only to the account that ran it. Null when the
    /// file named no known account, or a model that the account's vendor does
    /// not offer.
    choice: ?Choice = null,
    /// The effort level, when the file named a known level.
    effort: ?ai.llm.Effort = null,

    pub const Choice = struct {
        account: ai.llm.Account,
        model: ai.models.Model,
    };
};

/// The choices Pith seeded or recorded last. `model` is an owned copy of the
/// model name.
const Saved = struct {
    account: ai.llm.Account,
    model: []const u8,
    effort: ai.llm.Effort,
};

/// The inputs `open` needs to find `state.json` and its project key. `home` can
/// be relative, so it resolves against the working directory the app knows.
pub const OpenOptions = struct {
    working_directory: []const u8,
    home: []const u8,
    /// The project key: the Git root, or the working directory when Pith found
    /// no Git root.
    project: []const u8,
};

/// The number of projects the file keeps. A save drops the least recently
/// written project.
///
/// The bound exists only to stop the file from growing without a limit over
/// years of directories. It is not a budget, so it sits far above normal use. A
/// project costs its path plus about 75 bytes, which puts the whole file near
/// 150 KB. Pith reads it once and rewrites it only on a change, so that size
/// costs nothing a user can feel. A cap this loose also keeps the drop rule out
/// of the way: a project a user opens daily but never reconfigures needs 1000
/// other projects to change before it falls out.
const projects_max = 1000;

pub fn deinit(self: *State) void {
    if (self.saved) |saved| self.gpa.free(saved.model);
    self.gpa.free(self.project);
    self.gpa.free(self.path);
}

/// A state that remembers nothing and saves nothing. It names no file and owns
/// no memory, so a holder that has no `state.json` can still keep a valid
/// `State` and call every method on it.
pub fn inert(gpa: std.mem.Allocator, io: std.Io) State {
    return .{
        .gpa = gpa,
        .io = io,
        .path = "",
        .project = "",
        .start = .{},
        .saved = null,
        .save_enabled = false,
    };
}

/// Resolve the paths and read what the file holds for `options.project`. Only
/// the path allocation can fail the open. The read itself never fails: an
/// absent, unreadable, or malformed file reads as nothing remembered, and so
/// does a failed allocation inside the read. Machine-local state never stops
/// pith.
pub fn open(gpa: std.mem.Allocator, io: std.Io, options: *const OpenOptions) !State {
    const directory = try std.fs.path.resolve(
        gpa,
        &.{ options.working_directory, options.home, ".pith" },
    );
    defer gpa.free(directory);
    const path = try std.fs.path.join(gpa, &.{ directory, "state.json" });
    errdefer gpa.free(path);
    const project = try gpa.dupe(u8, options.project);
    errdefer gpa.free(project);
    return .{
        .gpa = gpa,
        .io = io,
        .path = path,
        .project = project,
        .start = read(gpa, io, path, project),
        .saved = null,
        .save_enabled = true,
    };
}

/// Adopt the choices the session starts on. It writes nothing: startup applies
/// what the file remembered or what the defaults gave, so it makes no new
/// choice to save.
pub fn seed(
    self: *State,
    account: ai.llm.Account,
    model: *const ai.models.Model,
    effort: ai.llm.Effort,
) !void {
    if (!self.save_enabled) return;
    try self.remember(account, model, effort);
}

/// Save the choices the project now uses. A choice equal to the seeded or last
/// recorded one writes nothing, so a command that changes neither the account,
/// the model, nor the effort level never touches the file. A failed write is the
/// last one this state attempts, so the caller reports it once.
pub fn record(
    self: *State,
    account: ai.llm.Account,
    model: *const ai.models.Model,
    effort: ai.llm.Effort,
) !void {
    if (!self.save_enabled) return;
    if (self.unchanged(account, model, effort)) return;
    ai.json_store.save(self.gpa, self.io, self.path, self.project, .{
        .account = @tagName(account),
        .model = model.name,
        .effort = @tagName(effort),
    }, .{ .keys_max = projects_max }) catch |err| {
        self.save_enabled = false;
        return err;
    };
    try self.remember(account, model, effort);
}

/// What the file at `path` holds for `project`. Every failure reads as nothing
/// remembered.
fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8, project: []const u8) Start {
    var file = (ai.json_store.open(gpa, io, path) catch return .{}) orelse return .{};
    defer file.deinit();
    const entry = file.entry(project) orelse return .{};
    return .{
        .choice = readChoice(&entry),
        .effort = readEnum(ai.llm.Effort, &entry, "effort"),
    };
}

/// The account and its model, or null when either one is absent or unknown. The
/// account names the vendor, so the model resolves against that vendor's table.
fn readChoice(entry: *const std.json.ObjectMap) ?Start.Choice {
    const account = readEnum(ai.llm.Account, entry, "account") orelse return null;
    const name = readString(entry, "model") orelse return null;
    const model = ai.models.get(account.provider(), name) orelse return null;
    return .{ .account = account, .model = model };
}

fn readEnum(comptime Enum: type, entry: *const std.json.ObjectMap, field: []const u8) ?Enum {
    return std.meta.stringToEnum(Enum, readString(entry, field) orelse return null);
}

/// The string at `field`. A value of another type reads as absent. The result
/// points into the open file, so a caller must copy or resolve it.
fn readString(entry: *const std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (entry.get(field) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn unchanged(
    self: *const State,
    account: ai.llm.Account,
    model: *const ai.models.Model,
    effort: ai.llm.Effort,
) bool {
    const saved = self.saved orelse return false;
    return saved.account == account and saved.effort == effort and
        std.mem.eql(u8, saved.model, model.name);
}

/// Replace the comparison snapshot. The model name is copied, so it survives a
/// model table that a later feature builds at runtime.
fn remember(
    self: *State,
    account: ai.llm.Account,
    model: *const ai.models.Model,
    effort: ai.llm.Effort,
) !void {
    const name = try self.gpa.dupe(u8, model.name);
    if (self.saved) |saved| self.gpa.free(saved.model);
    self.saved = .{ .account = account, .model = name, .effort = effort };
}

const test_model = ai.models.get(.anthropic, "claude-opus-5") orelse
    @compileError("test model is not in the model table");

fn tmpHome(gpa: std.mem.Allocator, io: std.Io, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
}

/// Open the state of a temporary home directory for the project "/work".
fn openForTest(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !State {
    const working_directory = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(working_directory);
    return open(gpa, io, &.{
        .working_directory = working_directory,
        .home = home,
        .project = "/work",
    });
}

/// Write `data` as the `state.json` of a test temporary home directory. The
/// `App` tests build the same fixture, so this is shared, not private.
pub fn writeForTest(io: std.Io, tmp: *const std.testing.TmpDir, data: []const u8) !void {
    var directory = try tmp.dir.createDirPathOpen(io, ".pith", .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = "state.json", .data = data });
}

test "an absent file remembers nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.start.choice == null);
    try std.testing.expect(state.start.effort == null);
    try std.testing.expect(std.mem.endsWith(u8, state.path, "/.pith/state.json"));
}

test "a stored entry reads back the account, the model, and the effort level" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/elsewhere": { "account": "openai_api", "model": "gpt-5.6-luna", "effort": "low" },
        \\  "/work": { "account": "anthropic_subscription", "model": "claude-opus-5",
        \\    "effort": "max" } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expectEqual(
        ai.llm.Account.anthropic_subscription,
        state.start.choice.?.account,
    );
    try std.testing.expectEqualStrings("claude-opus-5", state.start.choice.?.model.name);
    try std.testing.expectEqual(ai.llm.Effort.max, state.start.effort.?);
}

test "an unusable value reads as nothing remembered" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_][]const u8{
        // A file that is not JSON, and one that is not an object.
        "{ not json",
        "[1, 2, 3]",
        // An unknown account, an unknown model, and a model of another vendor.
        \\{ "/work": { "account": "nope", "model": "claude-opus-5", "effort": "max" } }
        ,
        \\{ "/work": { "account": "anthropic_api", "model": "nope", "effort": "max" } }
        ,
        \\{ "/work": { "account": "anthropic_api", "model": "gpt-5.6-luna", "effort": "max" } }
        ,
        // A missing field, and a field of the wrong JSON type.
        \\{ "/work": { "effort": "max" } }
        ,
        \\{ "/work": { "account": "anthropic_api", "model": 42, "effort": "max" } }
        ,
        // Another project's entry never applies to this one.
        \\{ "/elsewhere": { "account": "anthropic_api", "model": "claude-opus-5" } }
        ,
    };

    for (cases) |data| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmpHome(gpa, io, &tmp);
        defer gpa.free(home);
        try writeForTest(io, &tmp, data);

        var state = try openForTest(gpa, io, home);
        defer state.deinit();
        try std.testing.expect(state.start.choice == null);
    }

    // An unknown effort level drops that level alone. The choice stays usable.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic_api", "model": "claude-opus-5", "effort": "nope" } }
    );
    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.start.choice != null);
    try std.testing.expect(state.start.effort == null);
}

test "only a change writes the file, and it keeps another project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/elsewhere": { "account": "openai_api", "model": "gpt-5.6-luna", "effort": "low" } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try state.seed(.anthropic_api, &test_model, .xhigh);

    // The seeded choice is the current one, so neither call writes.
    try state.record(.anthropic_api, &test_model, .xhigh);
    var before = (try ai.json_store.open(gpa, io, state.path)).?;
    defer before.deinit();
    try std.testing.expect(before.entry("/work") == null);

    // A changed effort level writes the whole entry and keeps the other project.
    try state.record(.anthropic_api, &test_model, .none);
    var after = (try ai.json_store.open(gpa, io, state.path)).?;
    defer after.deinit();
    const entry = after.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic_api", entry.get("account").?.string);
    try std.testing.expectEqualStrings("claude-opus-5", entry.get("model").?.string);
    try std.testing.expectEqualStrings("none", entry.get("effort").?.string);
    try std.testing.expectEqualStrings(
        "gpt-5.6-luna",
        after.entry("/elsewhere").?.get("model").?.string,
    );

    // A restart reads back exactly what the record wrote.
    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(ai.llm.Account.anthropic_api, restarted.start.choice.?.account);
    try std.testing.expectEqualStrings("claude-opus-5", restarted.start.choice.?.model.name);
    try std.testing.expectEqual(ai.llm.Effort.none, restarted.start.effort.?);
}

test "a corrupt file survives a refused write" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp, "{ not json");

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expectError(
        error.CorruptStore,
        state.record(.anthropic_api, &test_model, .high),
    );
    const data = try std.Io.Dir.cwd().readFileAlloc(io, state.path, gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);

    // The failure is the last write this state attempts, so the caller reports
    // one message rather than one per change.
    try std.testing.expect(!state.save_enabled);
    try state.record(.anthropic_api, &test_model, .low);
}

test "an inert state saves nothing and owns nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var state: State = .inert(gpa, io);
    defer state.deinit();
    try std.testing.expect(state.start.choice == null);
    try std.testing.expect(state.start.effort == null);
    // Both calls are silent no-ops: an inert state names no file to write.
    try state.seed(.anthropic_api, &test_model, .high);
    try state.record(.anthropic_api, &test_model, .low);
    try std.testing.expect(state.saved == null);
}
