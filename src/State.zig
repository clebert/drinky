//! The machine-local startup state in `<home>/.drinky/state.json`: the account and
//! the effort level that each project used last, and the model that each account
//! ran there. It is mutable state, not configuration. `config.json` stays a
//! curated file the user can share, and this file holds what the interface
//! changes as the user works.
//!
//! The file is a keyed JSON object. Each key is a project: the Git root, or the
//! working directory when Drinky found no Git root. One project therefore keeps
//! its own entry, and two projects can run different accounts.
//!
//! A project runs one account at a time, but it keeps one model per account. A
//! model belongs to the account that ran it. A switch away and back returns to
//! that model, and so does the next start. The effort level is one per project,
//! not one per account. Startup applies it to the account it lands on, even
//! when the remembered account fell back.
//!
//! Drinky reads the file once, at startup. A change in another instance reaches
//! only the next start, never a running session. A write happens when the user
//! changes the account, the model, or the effort level. The write goes through
//! `ai.json_store`, so it is atomic, owner-only, and preserves every other
//! project. The file keeps the `projects_max` most recently written projects.
//!
//! Nothing here is authoritative. Every read failure reads as nothing
//! remembered. For the account and the effort level, the caller then falls back
//! to its configured or compiled default. A model the catalog does not resolve
//! leaves the account with none, and the user picks one. A failed write stops
//! every later write, so one broken file reports once instead of on every
//! change. Store contention is the one exception, because it clears by itself:
//! that snapshot stays pending, and the next write sends it even when the
//! choices went back to the saved ones.

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
/// The model each account ran last in this project. It starts from the file and
/// takes every later choice. An account therefore keeps its model for the rest
/// of the session and for the next start. Null for an account that ran none
/// here, and that account starts with no model until the user picks one.
///
/// An entry names a model and describes none, because the catalog says what a
/// name is and a stored description goes stale behind it. The name lives in the
/// model itself, so this allocates nothing.
models: std.EnumArray(ai.llm.Account, ?ai.Model),
/// The choices Drinky seeded or recorded last, so an unchanged choice writes
/// nothing. Null until the first `seed` or `record`.
saved: ?Saved,
/// True while Drinky still writes the file. A persistent failure clears it.
save_enabled: bool,
/// Whether temporary lock contention left a snapshot to save later.
save_pending: bool,

/// What the file held for the project. Each field is null when the file held no
/// usable value, so the caller applies its own default. The models the file held
/// live in `models`, because a session changes them and this does not.
pub const Start = struct {
    /// The account, when the file named a known one.
    account: ?ai.llm.Account = null,
    /// The effort level, when the file named a known level.
    effort: ?ai.llm.Effort = null,
};

/// The choices Drinky seeded or recorded last. `model` is an owned copy of the
/// model name.
const Saved = struct {
    account: ai.llm.Account,
    model: []const u8,
    effort: ai.llm.Effort,
};

/// The JSON shape of one project entry. It holds the account and the effort
/// level the project used last. It also holds the model of every account that
/// ran one there.
const Entry = struct {
    account: []const u8,
    effort: []const u8,
    models: Models,

    /// The `models` object. It writes one field per account that has a model, so
    /// an account that ran none here costs nothing in the file. It borrows the
    /// state's model table alone, because the JSON shape needs nothing else.
    const Models = struct {
        table: *const std.EnumArray(ai.llm.Account, ?ai.Model),

        pub fn jsonStringify(self: Models, stringify: anytype) !void {
            try stringify.beginObject();
            for (std.enums.values(ai.llm.Account)) |account| {
                const model = self.table.get(account) orelse continue;
                try stringify.objectField(@tagName(account));
                try stringify.write(model.name());
            }
            try stringify.endObject();
        }
    };
};

/// The inputs `open` needs to find `state.json` and its project key. `home` can
/// be relative, so it resolves against the working directory the app knows.
pub const OpenOptions = struct {
    working_directory: []const u8,
    home: []const u8,
    /// The project key: the Git root, or the working directory when Drinky found
    /// no Git root.
    project: []const u8,
};

/// The number of projects the file keeps. A save drops the least recently
/// written project.
///
/// The bound exists only to stop the file from growing without a limit over
/// years of directories. It is not a budget, so it sits far above normal use. A
/// project costs its path plus about 100 bytes, and about 45 more for each
/// account that ran a model there. That puts the whole file near 350 KB in the
/// worst case. Drinky reads it once and rewrites it only on a change, so that size
/// costs nothing a user can feel. A cap this loose also keeps the drop rule out
/// of the way: a project a user opens daily but never reconfigures needs 1000
/// other projects to change before it falls out.
const projects_max = 1000;

pub fn deinit(self: *State) void {
    if (self.saved) |saved| self.gpa.free(saved.model);
    self.gpa.free(self.project);
    self.gpa.free(self.path);
}

/// A state that names no file. It reads nothing, saves nothing, and owns no
/// memory. A holder that has no `state.json` can still keep a valid `State` and
/// call every method on it. It still holds the model of each account for the
/// session, because that memory does not depend on the file.
pub fn inert(gpa: std.mem.Allocator, io: std.Io) State {
    return .{
        .gpa = gpa,
        .io = io,
        .path = "",
        .project = "",
        .start = .{},
        .models = .initFill(null),
        .saved = null,
        .save_enabled = false,
        .save_pending = false,
    };
}

/// Resolve the paths and read what the file holds for `options.project`. Only
/// the path allocation can fail the open. The read itself never fails: an
/// absent, unreadable, or malformed file reads as nothing remembered, and so
/// does a failed allocation inside the read. Machine-local state never stops
/// Drinky.
pub fn open(gpa: std.mem.Allocator, io: std.Io, options: *const OpenOptions) !State {
    const directory = try std.fs.path.resolve(
        gpa,
        &.{ options.working_directory, options.home, ".drinky" },
    );
    defer gpa.free(directory);
    const path = try std.fs.path.join(gpa, &.{ directory, "state.json" });
    errdefer gpa.free(path);
    const project = try gpa.dupe(u8, options.project);
    errdefer gpa.free(project);
    var state: State = .{
        .gpa = gpa,
        .io = io,
        .path = path,
        .project = project,
        .start = .{},
        .models = .initFill(null),
        .saved = null,
        .save_enabled = true,
        .save_pending = false,
    };
    state.read();
    return state;
}

/// Adopt the choices the session starts on. It writes nothing: startup applies
/// what the file remembered or what the defaults gave, so it makes no new
/// choice to save.
pub fn seed(
    self: *State,
    account: ai.llm.Account,
    model: ?ai.Model,
    effort: ai.llm.Effort,
) !void {
    const kept = self.keepModel(account, model);
    if (!self.save_enabled) return;
    try self.remember(account, kept, effort);
}

/// Save the choices the project now uses. A choice equal to the seeded or last
/// recorded one writes nothing, so a command that changes neither the account,
/// the model, nor the effort level never touches the file. A persistent failure
/// stops later writes. Temporary lock contention leaves saving enabled.
///
/// The model of `account` changes first, so the write carries it and a state
/// that no longer saves still answers the rest of the session.
pub fn record(
    self: *State,
    account: ai.llm.Account,
    model: ?ai.Model,
    effort: ai.llm.Effort,
) !void {
    const kept = self.keepModel(account, model);
    if (!self.save_enabled) return;
    if (!self.save_pending and self.unchanged(account, kept, effort)) return;
    // A persistent failure stops later writes. StoreBusy keeps this snapshot
    // pending, even when the active choices later return to their saved values.
    try self.save(account, effort);
    self.remember(account, kept, effort) catch |err| {
        self.save_enabled = false;
        return err;
    };
    self.save_pending = false;
}

/// Write the whole project entry. A persistent failure stops later writes, and
/// store contention keeps a snapshot pending.
fn save(self: *State, account: ai.llm.Account, effort: ai.llm.Effort) !void {
    ai.json_store.save(self.gpa, self.io, self.path, self.project, Entry{
        .account = @tagName(account),
        .effort = @tagName(effort),
        .models = .{ .table = &self.models },
    }, .{ .keys_max = projects_max }) catch |err| {
        if (err == error.StoreBusy) {
            self.save_pending = true;
        } else {
            self.save_enabled = false;
        }
        return err;
    };
}

/// Read what the file holds for this project into `start` and `models`. Every
/// failure reads as nothing remembered.
fn read(self: *State) void {
    var file = (ai.json_store.open(self.gpa, self.io, self.path) catch return) orelse return;
    defer file.deinit();
    const entry = file.entry(self.project) orelse return;
    self.start = .{
        .account = readEnum(ai.llm.Account, &entry, "account"),
        .effort = readEnum(ai.llm.Effort, &entry, "effort"),
    };
    if (readObject(&entry, "models")) |listed| {
        for (std.enums.values(ai.llm.Account)) |account| {
            const name = readString(&listed, @tagName(account)) orelse continue;
            // The file names a model and nothing more. A name that the account
            // no longer offers resolves to nothing when the catalog reads it,
            // and that account then starts without a model.
            self.models.set(account, ai.Model.init(name) catch continue);
        }
    }
}

/// Adopt `model` as the one `account` ran here and return what the entry now
/// holds. The state keeps the name alone, because the catalog owns every other
/// field and a copy of it goes stale.
///
/// No model keeps the name the entry already holds. The catalog resolves a name
/// it has no list for to no model, and a logout, a replaced credential, and a
/// start before the first fetch each leave such a list empty. The account runs
/// with no model until then, and a later fetch returns it to the model it ran.
fn keepModel(self: *State, account: ai.llm.Account, model: ?ai.Model) ?ai.Model {
    const named = model orelse return self.models.get(account);
    self.models.set(account, ai.Model.init(named.name()) catch null);
    return self.models.get(account);
}

fn readEnum(comptime Enum: type, entry: *const std.json.ObjectMap, field: []const u8) ?Enum {
    return std.meta.stringToEnum(Enum, readString(entry, field) orelse return null);
}

/// The object at `field`. A value of another type reads as absent. The result
/// borrows from the open file, so a caller must resolve what it needs.
fn readObject(entry: *const std.json.ObjectMap, field: []const u8) ?std.json.ObjectMap {
    return switch (entry.get(field) orelse return null) {
        .object => |value| value,
        else => null,
    };
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
    model: ?ai.Model,
    effort: ai.llm.Effort,
) bool {
    const saved = self.saved orelse return false;
    if (saved.account != account or saved.effort != effort) return false;
    const named = model orelse return saved.model.len == 0;
    return named.sameName(saved.model);
}

/// Replace the comparison snapshot. The model name is copied, so it survives
/// every catalog the session later fetches. No model keeps an empty name, which
/// no model can carry.
fn remember(
    self: *State,
    account: ai.llm.Account,
    model: ?ai.Model,
    effort: ai.llm.Effort,
) !void {
    const name = try self.gpa.dupe(u8, if (model) |named| named.name() else "");
    if (self.saved) |saved| self.gpa.free(saved.model);
    self.saved = .{ .account = account, .model = name, .effort = effort };
}

const test_model = ai.testing.model("claude-opus-5");

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
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
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
    try std.testing.expect(state.start.account == null);
    try std.testing.expect(state.start.effort == null);
    for (state.models.values) |maybe_model| try std.testing.expect(maybe_model == null);
    try std.testing.expect(std.mem.endsWith(u8, state.path, "/.drinky/state.json"));
}

test "a stored entry reads back the account, the effort level, and one model per account" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/elsewhere": { "account": "openai_api", "effort": "low",
        \\    "models": { "openai_api": "gpt-5.6-luna" } },
        \\  "/work": { "account": "anthropic_subscription", "effort": "max",
        \\    "models": { "anthropic_subscription": "claude-opus-5",
        \\      "openai_api": "gpt-5.6-luna" } } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expectEqual(ai.llm.Account.anthropic_subscription, state.start.account.?);
    try std.testing.expectEqual(ai.llm.Effort.max, state.start.effort.?);
    // Every account the entry names keeps its own model, not only the active one.
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        state.models.get(.anthropic_subscription).?.name(),
    );
    try std.testing.expectEqualStrings("gpt-5.6-luna", state.models.get(.openai_api).?.name());
    // An account the entry does not name remembers no model.
    try std.testing.expect(state.models.get(.anthropic_api) == null);
}

test "an unusable value reads as nothing remembered" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_][]const u8{
        // A file that is not JSON, and one that is not an object.
        "{ not json",
        "[1, 2, 3]",
        // An unknown account, an unknown model, and a model of another vendor.
        \\{ "/work": { "account": "nope",
        \\    "models": { "nope": "claude-opus-5" } } }
        ,
        // A missing field, and a field of the wrong JSON type.
        \\{ "/work": { "effort": "max" } }
        ,
        \\{ "/work": { "account": 42, "models": 42 } }
        ,
        \\{ "/work": { "account": [], "models": { "anthropic_api": 42 } } }
        ,
        // Another project's entry never applies to this one.
        \\{ "/elsewhere": { "account": "anthropic_api",
        \\    "models": { "anthropic_api": "claude-opus-5" } } }
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
        try std.testing.expect(state.start.account == null);
        for (state.models.values) |maybe_model| try std.testing.expect(maybe_model == null);
    }

    // An unknown effort level drops that level alone. The rest stays usable.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic_api", "effort": "nope",
        \\    "models": { "anthropic_api": "claude-opus-5" } } }
    );
    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.start.account != null);
    try std.testing.expect(state.models.get(.anthropic_api) != null);
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
        \\{ "/elsewhere": { "account": "openai_api", "effort": "low",
        \\    "models": { "openai_api": "gpt-5.6-luna" } } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try state.seed(.anthropic_api, test_model, .xhigh);

    // The seeded choice is the current one, so neither call writes.
    try state.record(.anthropic_api, test_model, .xhigh);
    var before = (try ai.json_store.open(gpa, io, state.path)).?;
    defer before.deinit();
    try std.testing.expect(before.entry("/work") == null);

    // A changed effort level writes the whole entry and keeps the other project.
    try state.record(.anthropic_api, test_model, .low);
    var after = (try ai.json_store.open(gpa, io, state.path)).?;
    defer after.deinit();
    const entry = after.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic_api", entry.get("account").?.string);
    try std.testing.expectEqualStrings("low", entry.get("effort").?.string);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        entry.get("models").?.object.get("anthropic_api").?.string,
    );
    // Only the accounts that ran a model here reach the file.
    try std.testing.expectEqual(@as(usize, 1), entry.get("models").?.object.count());
    try std.testing.expectEqualStrings(
        "gpt-5.6-luna",
        after.entry("/elsewhere").?.get("models").?.object.get("openai_api").?.string,
    );

    // A restart reads back exactly what the record wrote.
    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(ai.llm.Account.anthropic_api, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        restarted.models.get(.anthropic_api).?.name(),
    );
    try std.testing.expectEqual(ai.llm.Effort.low, restarted.start.effort.?);
}

test "each account keeps its own model across a switch and a restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const openai_model = ai.testing.model("gpt-5.6-luna");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try state.seed(.anthropic_api, test_model, .high);
    // A switch to another account records that account's model. The model of the
    // account left behind stays, because a model belongs to the account that ran
    // it.
    try state.record(.openai_api, openai_model, .high);
    try std.testing.expectEqualStrings("claude-opus-5", state.models.get(.anthropic_api).?.name());
    try std.testing.expectEqualStrings("gpt-5.6-luna", state.models.get(.openai_api).?.name());

    // The next start reads both models back, so a switch there returns to the
    // model each account ran.
    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(ai.llm.Account.openai_api, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        restarted.models.get(.anthropic_api).?.name(),
    );
    try std.testing.expectEqualStrings("gpt-5.6-luna", restarted.models.get(.openai_api).?.name());
}

// The file names a model and describes none, so the state keeps whatever name a
// command recorded. The catalog decides at read time whether an account still
// offers it, and a name it does not know resolves to no model there.
test "the state keeps the model name that a command recorded" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const other_model = ai.testing.model("claude-opus-6");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic_api", "effort": "low",
        \\    "models": { "anthropic_api": "claude-opus-5" } } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.models.get(.anthropic_api) != null);

    // A recorded name replaces the one the file held.
    try state.record(.anthropic_api, other_model, .low);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        state.models.get(.anthropic_api).?.name(),
    );

    // No model keeps the name the entry holds, because a catalog that resolves
    // nothing must not erase the memory of the account. An account that ran none
    // here still names none.
    try state.record(.openai_api, null, .low);
    try std.testing.expect(state.models.get(.openai_api) == null);
    try state.record(.anthropic_api, null, .low);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        state.models.get(.anthropic_api).?.name(),
    );

    // The entry names that model alone. The account and the effort level reach
    // the file with it, so the next start resumes on them.
    var file = (try ai.json_store.open(gpa, io, state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic_api", entry.get("account").?.string);
    try std.testing.expectEqualStrings("low", entry.get("effort").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqual(@as(usize, 1), listed.count());
    try std.testing.expectEqualStrings("claude-opus-6", listed.get("anthropic_api").?.string);

    // A restart reads that entry back, so a later fetch returns the account to
    // the model it ran.
    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(ai.llm.Account.anthropic_api, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        restarted.models.get(.anthropic_api).?.name(),
    );
    try std.testing.expect(restarted.models.get(.openai_api) == null);
}

test "temporary store contention leaves project-state saving enabled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const openai_model = ai.testing.model("gpt-5.6-luna");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp, "{}");

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try state.seed(.anthropic_api, test_model, .low);
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{state.path});
    defer gpa.free(lock_path);
    {
        var held = try std.Io.Dir.cwd().createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = @enumFromInt(0o600),
        });
        defer held.close(io);
        try std.testing.expectError(
            error.StoreBusy,
            state.record(.openai_api, openai_model, .high),
        );
        try std.testing.expect(state.save_enabled);
        try std.testing.expect(state.save_pending);
    }

    // The choices return to the saved values. The pending snapshot still forces
    // this retry, so no earlier model-table change can stay only in memory.
    try state.record(.anthropic_api, test_model, .low);
    try std.testing.expect(!state.save_pending);
    var file = (try ai.json_store.open(gpa, io, state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic_api", entry.get("account").?.string);
    try std.testing.expectEqualStrings(
        openai_model.name(),
        entry.get("models").?.object.get("openai_api").?.string,
    );
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
        state.record(.anthropic_api, test_model, .high),
    );
    const data = try std.Io.Dir.cwd().readFileAlloc(io, state.path, gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);

    // The failure is the last write this state attempts, so the caller reports
    // one message rather than one per change.
    try std.testing.expect(!state.save_enabled);
    try state.record(.anthropic_api, test_model, .low);
}

test "an inert state saves nothing and owns nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const openai_model = ai.testing.model("gpt-5.6-luna");

    var state: State = .inert(gpa, io);
    defer state.deinit();
    try std.testing.expect(state.start.account == null);
    try std.testing.expect(state.start.effort == null);
    // Neither call writes: an inert state names no file. Both still take the
    // model, because the session memory does not depend on the file.
    try state.seed(.anthropic_api, test_model, .high);
    try state.record(.openai_api, openai_model, .low);
    try std.testing.expect(state.saved == null);
    try std.testing.expectEqualStrings("claude-opus-5", state.models.get(.anthropic_api).?.name());
    try std.testing.expectEqualStrings("gpt-5.6-luna", state.models.get(.openai_api).?.name());
}
