const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Account = @import("Account.zig");
const json_store = @import("json_store.zig");
const testing = @import("testing.zig");

const State = @This();

const projects_max = 1000;

gpa: std.mem.Allocator,
io: std.Io,
path: []const u8,
project: []const u8,
start: Start,
model_names: [Account.table.len]?[]const u8,
saved: ?Saved,
saving: Saving,

const Start = struct {
    account: ?usize = null,
    effort: ?core.Provider.Effort = null,
};

const OpenOptions = struct {
    directories: json_store.Directories,
    project: []const u8,
};

const Saved = struct {
    account: usize,
    model_name: []const u8,
    effort: core.Provider.Effort,
};

const Saving = enum { enabled, pending, disabled };

const Entry = struct {
    account: []const u8,
    effort: []const u8,
    models: Models,

    const Models = struct {
        names: []const ?[]const u8,

        pub fn jsonStringify(self: Models, stringify: anytype) !void {
            try stringify.beginObject();
            for (&Account.table, self.names) |*row, maybe_name| {
                const name = maybe_name orelse continue;
                try stringify.objectField(row.id);
                try stringify.write(name);
            }
            try stringify.endObject();
        }
    };
};

pub fn deinit(self: *State) void {
    if (self.saved) |saved| self.gpa.free(saved.model_name);
    for (self.model_names) |maybe_name| {
        if (maybe_name) |name| self.gpa.free(name);
    }
    self.gpa.free(self.project);
    self.gpa.free(self.path);
}

pub fn open(gpa: std.mem.Allocator, io: std.Io, options: *const OpenOptions) !State {
    const path = try json_store.locate(gpa, &options.directories, "state.json");
    errdefer gpa.free(path);
    const project = try gpa.dupe(u8, options.project);
    errdefer gpa.free(project);
    var state: State = .{
        .gpa = gpa,
        .io = io,
        .path = path,
        .project = project,
        .start = .{},
        .model_names = @splat(null),
        .saved = null,
        .saving = .enabled,
    };
    state.read();
    return state;
}

pub fn seed(
    self: *State,
    account: usize,
    model_name: ?[]const u8,
    effort: core.Provider.Effort,
) json_store.SaveError!void {
    const kept = try self.keep(account, model_name);
    if (self.saving == .disabled) return;
    try self.remember(account, kept, effort);
}

pub fn record(
    self: *State,
    account: usize,
    model_name: ?[]const u8,
    effort: core.Provider.Effort,
) json_store.SaveError!void {
    const kept = try self.keep(account, model_name);
    switch (self.saving) {
        .enabled => if (self.unchanged(account, kept, effort)) return,
        .pending => {},
        .disabled => return,
    }
    try self.save(account, effort);
    self.remember(account, kept, effort) catch |err| {
        self.saving = .disabled;
        return err;
    };
    self.saving = .enabled;
}

fn save(self: *State, account: usize, effort: core.Provider.Effort) json_store.SaveError!void {
    json_store.save(self.gpa, self.io, &.{ .path = self.path, .key = self.project }, Entry{
        .account = Account.table[account].id,
        .effort = @tagName(effort),
        .models = .{ .names = &self.model_names },
    }, .{ .keys_max = projects_max }) catch |err| {
        self.saving = if (err == error.StoreBusy) .pending else .disabled;
        return err;
    };
}

fn read(self: *State) void {
    var file = (json_store.open(self.gpa, self.io, self.path) catch return) orelse return;
    defer file.deinit();
    const entry = file.entry(self.project) orelse return;
    const account = providers.json.string(entry.getPtr("account")) orelse "";
    const effort = providers.json.string(entry.getPtr("effort")) orelse "";
    self.start = .{
        .account = Account.index(account),
        .effort = std.meta.stringToEnum(core.Provider.Effort, effort),
    };
    const listed = providers.json.object(entry.getPtr("models")) orelse return;
    for (&Account.table, &self.model_names) |*row, *slot| {
        const name = providers.json.string(listed.getPtr(row.id)) orelse continue;
        slot.* = self.gpa.dupe(u8, name) catch return;
    }
}

fn keep(self: *State, account: usize, maybe_name: ?[]const u8) error{OutOfMemory}!?[]const u8 {
    const name = maybe_name orelse return self.model_names[account];
    const owned = try self.gpa.dupe(u8, name);
    if (self.model_names[account]) |old| self.gpa.free(old);
    self.model_names[account] = owned;
    return owned;
}

fn unchanged(
    self: *const State,
    account: usize,
    maybe_name: ?[]const u8,
    effort: core.Provider.Effort,
) bool {
    const saved = self.saved orelse return false;
    if (saved.account != account or saved.effort != effort) return false;
    const name = maybe_name orelse return saved.model_name.len == 0;
    return std.mem.eql(u8, name, saved.model_name);
}

fn remember(
    self: *State,
    account: usize,
    maybe_name: ?[]const u8,
    effort: core.Provider.Effort,
) error{OutOfMemory}!void {
    const name = try self.gpa.dupe(u8, maybe_name orelse "");
    if (self.saved) |saved| self.gpa.free(saved.model_name);
    self.saved = .{ .account = account, .model_name = name, .effort = effort };
}

test "an absent file remembers nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.start.account == null);
    try std.testing.expect(state.start.effort == null);
    for (state.model_names) |maybe_name| try std.testing.expect(maybe_name == null);
    try std.testing.expect(std.mem.endsWith(u8, state.path, "/.drinky/state.json"));
}

fn openForTest(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !State {
    const working_directory = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(working_directory);
    return open(gpa, io, &.{
        .directories = .{ .working_directory = working_directory, .home = home },
        .project = "/work",
    });
}

fn writeForTest(io: std.Io, tmp: *const std.testing.TmpDir, data: []const u8) !void {
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = "state.json", .data = data });
}

test "a stored entry reads back the account, the effort level, and one model per account" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
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
    try std.testing.expectEqual(testing.anthropic_plan, state.start.account.?);
    try std.testing.expectEqual(core.Provider.Effort.max, state.start.effort.?);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        state.model_names[testing.anthropic_plan].?,
    );
    try std.testing.expectEqualStrings("gpt-5.6-luna", state.model_names[testing.openai_api_key].?);
    try std.testing.expect(state.model_names[testing.anthropic_api_key] == null);
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
        const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(home);
        try writeForTest(io, &tmp, data);

        var state = try openForTest(gpa, io, home);
        defer state.deinit();
        try std.testing.expect(state.start.account == null);
        for (state.model_names) |maybe_name| try std.testing.expect(maybe_name == null);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic-api-key", "effort": "nope",
        \\    "models": { "anthropic-api-key": "claude-opus-5" } } }
    );
    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.start.account != null);
    try std.testing.expect(state.model_names[testing.anthropic_api_key] != null);
    try std.testing.expect(state.start.effort == null);
}

test "only a change writes the file, and it keeps another project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/elsewhere": { "account": "openai-api-key", "effort": "low",
        \\    "models": { "openai-api-key": "gpt-5.6-luna" } } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try state.seed(testing.anthropic_api_key, "claude-opus-5", .xhigh);

    try state.record(testing.anthropic_api_key, "claude-opus-5", .xhigh);
    var before = (try json_store.open(gpa, io, state.path)).?;
    defer before.deinit();
    try std.testing.expect(before.entry("/work") == null);

    try state.record(testing.anthropic_api_key, "claude-opus-5", .low);
    var after = (try json_store.open(gpa, io, state.path)).?;
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
    try std.testing.expectEqual(testing.anthropic_api_key, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        restarted.model_names[testing.anthropic_api_key].?,
    );
    try std.testing.expectEqual(core.Provider.Effort.low, restarted.start.effort.?);
}

test "each account keeps its own model across a switch and a restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try state.seed(testing.anthropic_api_key, "claude-opus-5", .high);
    try state.record(testing.openai_api_key, "gpt-5.6-luna", .high);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        state.model_names[testing.anthropic_api_key].?,
    );
    try std.testing.expectEqualStrings("gpt-5.6-luna", state.model_names[testing.openai_api_key].?);

    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(testing.openai_api_key, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-5",
        restarted.model_names[testing.anthropic_api_key].?,
    );
    try std.testing.expectEqualStrings(
        "gpt-5.6-luna",
        restarted.model_names[testing.openai_api_key].?,
    );
}

test "the state keeps the model name that a command recorded" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    try writeForTest(io, &tmp,
        \\{ "/work": { "account": "anthropic-api-key", "effort": "low",
        \\    "models": { "anthropic-api-key": "claude-opus-5" } } }
    );

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expect(state.model_names[testing.anthropic_api_key] != null);

    try state.record(testing.anthropic_api_key, "claude-opus-6", .low);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        state.model_names[testing.anthropic_api_key].?,
    );

    try state.record(testing.openai_api_key, null, .low);
    try std.testing.expect(state.model_names[testing.openai_api_key] == null);
    try state.record(testing.anthropic_api_key, null, .low);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        state.model_names[testing.anthropic_api_key].?,
    );

    var file = (try json_store.open(gpa, io, state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic-api-key", entry.get("account").?.string);
    try std.testing.expectEqualStrings("low", entry.get("effort").?.string);
    const listed = entry.get("models").?.object;
    try std.testing.expectEqual(@as(usize, 1), listed.count());
    try std.testing.expectEqualStrings("claude-opus-6", listed.get("anthropic-api-key").?.string);

    var restarted = try openForTest(gpa, io, home);
    defer restarted.deinit();
    try std.testing.expectEqual(testing.anthropic_api_key, restarted.start.account.?);
    try std.testing.expectEqualStrings(
        "claude-opus-6",
        restarted.model_names[testing.anthropic_api_key].?,
    );
    try std.testing.expect(restarted.model_names[testing.openai_api_key] == null);
}

test "temporary store contention leaves project-state saving enabled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    try writeForTest(io, &tmp, "{}");

    var clock: core.testing.ClockIo = undefined;
    clock.init(gpa);
    defer clock.deinit();
    var state = try openForTest(gpa, clock.io(), home);
    defer state.deinit();
    try state.seed(testing.anthropic_api_key, "claude-opus-5", .low);
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
            state.record(testing.openai_api_key, "gpt-5.6-luna", .high),
        );
    }

    try state.record(testing.anthropic_api_key, "claude-opus-5", .low);
    var file = (try json_store.open(gpa, io, state.path)).?;
    defer file.deinit();
    const entry = file.entry("/work").?;
    try std.testing.expectEqualStrings("anthropic-api-key", entry.get("account").?.string);
    try std.testing.expectEqualStrings(
        "gpt-5.6-luna",
        entry.get("models").?.object.get("openai-api-key").?.string,
    );
}

test "a save beyond the project cap drops the oldest project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    var projects: std.Io.Writer.Allocating = .init(gpa);
    defer projects.deinit();
    try projects.writer.writeByte('{');
    for (0..projects_max) |index| {
        if (index > 0) try projects.writer.writeByte(',');
        try projects.writer.print("\"/p{d}\":{{}}", .{index});
    }
    try projects.writer.writeByte('}');
    try writeForTest(io, &tmp, projects.written());

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try state.record(testing.anthropic_api_key, "claude-opus-5", .high);
    var file = (try json_store.open(gpa, io, state.path)).?;
    defer file.deinit();
    try std.testing.expect(file.entry("/p0") == null);
    try std.testing.expect(file.entry("/p1") != null);
    try std.testing.expect(file.entry("/work") != null);
    try std.testing.expectEqual(@as(usize, projects_max), file.parsed.value.object.count());
}

test "a corrupt file survives a refused write" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    try writeForTest(io, &tmp, "{ not json");

    var state = try openForTest(gpa, io, home);
    defer state.deinit();
    try std.testing.expectError(
        error.CorruptStore,
        state.record(testing.anthropic_api_key, "claude-opus-5", .high),
    );
    try state.record(testing.anthropic_api_key, "claude-opus-5", .low);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, state.path, gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("{ not json", data);
}
