const std = @import("std");

const ai = @import("ai");

const State = @This();

gpa: std.mem.Allocator,
io: std.Io,
path: []const u8,
project: []const u8,
start: Start,
models: std.EnumArray(ai.llm.Account, ?ai.Model),
saved: ?Saved,
save_enabled: bool,
save_pending: bool,

pub const Start = struct {
    account: ?ai.llm.Account = null,
    effort: ?ai.llm.Effort = null,
};

const Saved = struct {
    account: ai.llm.Account,
    model: []const u8,
    effort: ai.llm.Effort,
};

const Entry = struct {
    account: []const u8,
    effort: []const u8,
    models: Models,

    const Models = struct {
        table: *const std.EnumArray(ai.llm.Account, ?ai.Model),

        pub fn jsonStringify(self: Models, stringify: anytype) !void {
            try stringify.beginObject();
            for (std.enums.values(ai.llm.Account)) |account| {
                const model = self.table.get(account) orelse continue;
                try stringify.objectField(account.id());
                try stringify.write(model.name());
            }
            try stringify.endObject();
        }
    };
};

pub const OpenOptions = struct {
    working_directory: []const u8,
    home: []const u8,
    project: []const u8,
};

const projects_max = 1000;

pub fn deinit(self: *State) void {
    if (self.saved) |saved| self.gpa.free(saved.model);
    self.gpa.free(self.project);
    self.gpa.free(self.path);
}

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

pub fn record(
    self: *State,
    account: ai.llm.Account,
    model: ?ai.Model,
    effort: ai.llm.Effort,
) !void {
    const kept = self.keepModel(account, model);
    if (!self.save_enabled) return;
    if (!self.save_pending and self.unchanged(account, kept, effort)) return;
    try self.save(account, effort);
    self.remember(account, kept, effort) catch |err| {
        self.save_enabled = false;
        return err;
    };
    self.save_pending = false;
}

fn save(self: *State, account: ai.llm.Account, effort: ai.llm.Effort) !void {
    ai.json_store.save(self.gpa, self.io, self.path, self.project, Entry{
        .account = account.id(),
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

fn read(self: *State) void {
    var file = (ai.json_store.open(self.gpa, self.io, self.path) catch return) orelse return;
    defer file.deinit();
    const entry = file.entry(self.project) orelse return;
    self.start = .{
        .account = ai.llm.Account.parse(readString(&entry, "account") orelse ""),
        .effort = readEnum(ai.llm.Effort, &entry, "effort"),
    };
    if (readObject(&entry, "models")) |listed| {
        for (std.enums.values(ai.llm.Account)) |account| {
            const name = readString(&listed, account.id()) orelse continue;
            self.models.set(account, ai.Model.init(name) catch continue);
        }
    }
}

fn keepModel(self: *State, account: ai.llm.Account, model: ?ai.Model) ?ai.Model {
    const named = model orelse return self.models.get(account);
    self.models.set(account, ai.Model.init(named.name()) catch null);
    return self.models.get(account);
}

fn readEnum(comptime Enum: type, entry: *const std.json.ObjectMap, field: []const u8) ?Enum {
    return std.meta.stringToEnum(Enum, readString(entry, field) orelse return null);
}

fn readObject(entry: *const std.json.ObjectMap, field: []const u8) ?std.json.ObjectMap {
    return switch (entry.get(field) orelse return null) {
        .object => |value| value,
        else => null,
    };
}

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

fn openForTest(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !State {
    const working_directory = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(working_directory);
    return open(gpa, io, &.{
        .working_directory = working_directory,
        .home = home,
        .project = "/work",
    });
}

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
        \\{ "/elsewhere": { "account": "openai-api-key", "effort": "low",
        \\    "models": { "openai-api-key": "gpt-5.6-luna" } },
        \\  "/work": { "account": "anthropic-plan", "effort": "max",
        \\    "models": { "anthropic-plan": "claude-opus-5",
        \\      "openai-api-key": "gpt-5.6-luna" } } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expectEqual(ai.llm.Account.anthropic_plan, state.start.account.?);
    try std.testing.expectEqual(ai.llm.Effort.max, state.start.effort.?);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        state.models.get(.anthropic_plan).?.name(),
    );
    try std.testing.expectEqualStrings("gpt-5.6-luna", state.models.get(.openai_api_key).?.name());
    try std.testing.expect(state.models.get(.anthropic_api_key) == null);
}

test "an unusable value reads as nothing remembered" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_][]const u8{
        "{ not json",
        "[1, 2, 3]",
        \\{ "/work": { "account": "nope",
        \\    "models": { "nope": "claude-opus-5" } } }
        ,
        \\{ "/work": { "effort": "max" } }
        ,
        \\{ "/work": { "account": 42, "models": 42 } }
        ,
        \\{ "/work": { "account": [], "models": { "anthropic-api-key": 42 } } }
        ,
        \\{ "/elsewhere": { "account": "anthropic-api-key",
        \\    "models": { "anthropic-api-key": "claude-opus-5" } } }
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic-api-key", "effort": "nope",
        \\    "models": { "anthropic-api-key": "claude-opus-5" } } }
    );
    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.start.account != null);
    try std.testing.expect(state.models.get(.anthropic_api_key) != null);
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
        \\{ "/elsewhere": { "account": "openai-api-key", "effort": "low",
        \\    "models": { "openai-api-key": "gpt-5.6-luna" } } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try state.seed(.anthropic_api_key, test_model, .xhigh);

    try state.record(.anthropic_api_key, test_model, .xhigh);
    var before = (try ai.json_store.open(gpa, io, state.path)).?;
    defer before.deinit();
    try std.testing.expect(before.entry("/work") == null);

    try state.record(.anthropic_api_key, test_model, .low);
    var after = (try ai.json_store.open(gpa, io, state.path)).?;
    defer after.deinit();
    const entry = after.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic-api-key", entry.get("account").?.string);
    try std.testing.expectEqualStrings("low", entry.get("effort").?.string);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        entry.get("models").?.object.get("anthropic-api-key").?.string,
    );
    try std.testing.expectEqual(@as(usize, 1), entry.get("models").?.object.count());
    try std.testing.expectEqualStrings(
        "gpt-5.6-luna",
        after.entry("/elsewhere").?.get("models").?.object.get("openai-api-key").?.string,
    );

    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        restarted.models.get(.anthropic_api_key).?.name(),
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
    try state.seed(.anthropic_api_key, test_model, .high);
    try state.record(.openai_api_key, openai_model, .high);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        state.models.get(.anthropic_api_key).?.name(),
    );
    try std.testing.expectEqualStrings("gpt-5.6-luna", state.models.get(.openai_api_key).?.name());

    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(ai.llm.Account.openai_api_key, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        restarted.models.get(.anthropic_api_key).?.name(),
    );
    try std.testing.expectEqualStrings(
        "gpt-5.6-luna",
        restarted.models.get(.openai_api_key).?.name(),
    );
}

test "the state keeps the model name that a command recorded" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const other_model = ai.testing.model("claude-opus-6");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(gpa, io, &tmp);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic-api-key", "effort": "low",
        \\    "models": { "anthropic-api-key": "claude-opus-5" } } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.models.get(.anthropic_api_key) != null);

    try state.record(.anthropic_api_key, other_model, .low);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        state.models.get(.anthropic_api_key).?.name(),
    );

    try state.record(.openai_api_key, null, .low);
    try std.testing.expect(state.models.get(.openai_api_key) == null);
    try state.record(.anthropic_api_key, null, .low);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        state.models.get(.anthropic_api_key).?.name(),
    );

    var file = (try ai.json_store.open(gpa, io, state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic-api-key", entry.get("account").?.string);
    try std.testing.expectEqualStrings("low", entry.get("effort").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqual(@as(usize, 1), listed.count());
    try std.testing.expectEqualStrings("claude-opus-6", listed.get("anthropic-api-key").?.string);

    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(ai.llm.Account.anthropic_api_key, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        restarted.models.get(.anthropic_api_key).?.name(),
    );
    try std.testing.expect(restarted.models.get(.openai_api_key) == null);
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
    try state.seed(.anthropic_api_key, test_model, .low);
    ai.json_store.lock_policy = .{ .attempts_max = 2, .wait_ms = 0 };
    defer ai.json_store.lock_policy = .{};
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
            state.record(.openai_api_key, openai_model, .high),
        );
        try std.testing.expect(state.save_enabled);
        try std.testing.expect(state.save_pending);
    }

    try state.record(.anthropic_api_key, test_model, .low);
    try std.testing.expect(!state.save_pending);
    var file = (try ai.json_store.open(gpa, io, state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic-api-key", entry.get("account").?.string);
    try std.testing.expectEqualStrings(
        openai_model.name(),
        entry.get("models").?.object.get("openai-api-key").?.string,
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
        state.record(.anthropic_api_key, test_model, .high),
    );
    const data = try std.Io.Dir.cwd().readFileAlloc(io, state.path, gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);

    try std.testing.expect(!state.save_enabled);
    try state.record(.anthropic_api_key, test_model, .low);
}

test "an inert state saves nothing and owns nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const openai_model = ai.testing.model("gpt-5.6-luna");

    var state: State = .inert(gpa, io);
    defer state.deinit();
    try std.testing.expect(state.start.account == null);
    try std.testing.expect(state.start.effort == null);
    try state.seed(.anthropic_api_key, test_model, .high);
    try state.record(.openai_api_key, openai_model, .low);
    try std.testing.expect(state.saved == null);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        state.models.get(.anthropic_api_key).?.name(),
    );
    try std.testing.expectEqualStrings("gpt-5.6-luna", state.models.get(.openai_api_key).?.name());
}
