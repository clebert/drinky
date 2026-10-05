const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Account = @import("Account.zig");
const json = @import("json.zig");
const json_store = @import("json_store.zig");
const Metadata = @import("Metadata.zig");
const Model = @import("Model.zig");
const testing = @import("testing.zig");

const Catalog = @This();

const efforts_bytes_max = 64;
const models_key = "models";
const base_url_key = "base_url";

gpa: std.mem.Allocator,
io: std.Io,
models_path: []const u8,
metadata_path: []const u8,
lists: [Account.table.len][]Model,
base_urls: [Account.table.len]?[]const u8,
metadata: Metadata,
mutex: std.Io.Mutex,

const Replacement = struct {
    models: []const Model,
    base_url: ?[]const u8 = null,
};

const Encoded = struct {
    name: []const u8,
    engine: ?[]const u8,
    served_as: ?[]const u8,
    context_window: ?u64,
    tokens_max: ?u32,
    thinking: []const u8,
    tools: []const u8,
    efforts: []const u8,
    efforts_denied: bool,
    price: ?Model.Price,
};

const Stored = struct {
    models: []const Encoded,
};

const Offered = struct {
    catalog: *const Catalog,
    index: usize,
    position: usize,

    fn next(self: *Offered) ?Model {
        const catalog = self.catalog;
        if (Account.table[self.index].model_source == .public) {
            const entries = catalog.metadata.entries;
            while (self.position < entries.len) {
                const entry = &entries[self.position];
                self.position += 1;
                if (entry.vendor == .openrouter) return entry.model;
            }
            return null;
        }
        const listed = catalog.lists[self.index];
        while (self.position < listed.len) {
            const merged = catalog.merge(self.index, &listed[self.position]);
            self.position += 1;
            if (merged) |model| return model;
        }
        return null;
    }
};

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    directories: *const json_store.Directories,
) !Catalog {
    const models_path = try json_store.locate(gpa, directories, "models.json");
    errdefer gpa.free(models_path);
    const metadata_path = try json_store.locate(gpa, directories, "metadata.json");
    errdefer gpa.free(metadata_path);

    var catalog: Catalog = .{
        .gpa = gpa,
        .io = io,
        .models_path = models_path,
        .metadata_path = metadata_path,
        .lists = @splat(&.{}),
        .base_urls = @splat(null),
        .metadata = .{ .gpa = gpa, .entries = &.{} },
        .mutex = .init,
    };
    catalog.loadAccounts();
    catalog.loadMetadata();
    return catalog;
}

pub fn deinit(self: *Catalog) void {
    for (self.lists) |models| self.gpa.free(models);
    for (self.base_urls) |maybe_base_url| {
        if (maybe_base_url) |base_url| self.gpa.free(base_url);
    }
    self.metadata.deinit();
    self.gpa.free(self.models_path);
    self.gpa.free(self.metadata_path);
}

pub fn isEmpty(self: *Catalog, index: usize) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var iterator = self.offered(index);
    return iterator.next() == null;
}

pub fn list(
    self: *Catalog,
    index: usize,
    out: *std.ArrayList(Model),
    gpa: std.mem.Allocator,
) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var iterator = self.offered(index);
    while (iterator.next()) |model| try out.append(gpa, model);
}

pub fn find(self: *Catalog, index: usize, name: []const u8) ?Model {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var iterator = self.offered(index);
    while (iterator.next()) |model| {
        if (model.sameName(name)) return model;
    }
    return null;
}

fn offered(self: *const Catalog, index: usize) Offered {
    return .{ .catalog = self, .index = index, .position = 0 };
}

fn merge(self: *const Catalog, index: usize, listed: *const Model) ?Model {
    var merged = listed.*;
    const row = &Account.table[index];
    const public = if (row.model_source == .local)
        null
    else
        self.metadata.lookup(row.vendor, listed.name());
    if (public) |extra| {
        if (merged.price == null) merged.price = extra.price;
        if (merged.context_window == null) merged.context_window = extra.context_window;
        if (merged.tokens_max == null) merged.tokens_max = extra.tokens_max;
        const denies = extra.thinking == .unsupported and merged.efforts.count() != 0;
        if (merged.thinking == .unknown and !denies) merged.thinking = extra.thinking;
        if (merged.takesEffort() and merged.efforts.count() == 0) merged.efforts = extra.efforts;
        if (merged.tools == .unknown) merged.tools = extra.tools;
    }
    if (merged.tools == .unsupported) return null;
    const describes = merged.context_window != null or
        merged.efforts.count() != 0 or
        merged.price != null or
        merged.thinking != .unknown;
    return if (describes) merged else null;
}

pub fn setAccount(
    self: *Catalog,
    index: usize,
    replacement: *const Replacement,
) json_store.SaveError!void {
    const row = &Account.table[index];
    std.debug.assert(row.model_source != .public);
    std.debug.assert((row.model_source == .local) == (replacement.base_url != null));
    const models = try self.gpa.dupe(Model, replacement.models);
    var installed = false;
    errdefer if (!installed) self.gpa.free(models);
    const base_url = if (replacement.base_url) |source| try self.gpa.dupe(u8, source) else null;
    errdefer if (!installed) if (base_url) |url| self.gpa.free(url);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.gpa.free(self.lists[index]);
    if (self.base_urls[index]) |old| self.gpa.free(old);
    self.lists[index] = models;
    self.base_urls[index] = base_url;
    installed = true;
    try self.saveAccount(index);
}

pub fn dropAccountFromAnotherUrl(self: *Catalog, index: usize, base_url: []const u8) void {
    std.debug.assert(Account.table[index].model_source == .local);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.base_urls[index]) |stored| {
        if (std.mem.eql(u8, stored, base_url)) return;
    } else if (self.lists[index].len == 0) return;
    self.dropLocked(index);
}

pub fn dropAccount(self: *Catalog, index: usize) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.dropLocked(index);
}

fn dropLocked(self: *Catalog, index: usize) void {
    self.gpa.free(self.lists[index]);
    if (self.base_urls[index]) |base_url| self.gpa.free(base_url);
    self.lists[index] = &.{};
    self.base_urls[index] = null;
    json_store.remove(self.gpa, self.io, &.{
        .path = self.models_path,
        .key = Account.table[index].id,
    }) catch {};
}

pub fn setMetadata(self: *Catalog, metadata: Metadata) json_store.SaveError!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.metadata.deinit();
    self.metadata = metadata;
    try self.saveMetadata();
}

fn loadAccounts(self: *Catalog) void {
    var file = (json_store.open(self.gpa, self.io, self.models_path) catch return) orelse return;
    defer file.deinit();
    for (&Account.table, 0..) |*row, index| {
        const entry = file.entry(row.id) orelse continue;
        const listed = providers.json.array(entry.getPtr(models_key)) orelse continue;
        const models = json.models(self.gpa, listed.items, decodeModel) catch continue;
        const maybe_source = if (row.model_source == .local) providers.json.string(
            entry.getPtr(base_url_key),
        ) else null;
        const base_url = if (maybe_source) |source|
            self.gpa.dupe(u8, source) catch {
                self.gpa.free(models);
                continue;
            }
        else
            null;
        self.gpa.free(self.lists[index]);
        if (self.base_urls[index]) |old| self.gpa.free(old);
        self.lists[index] = models;
        self.base_urls[index] = base_url;
    }
}

fn loadMetadata(self: *Catalog) void {
    var file = (json_store.open(self.gpa, self.io, self.metadata_path) catch return) orelse return;
    defer file.deinit();

    var entries: std.ArrayList(Metadata.Entry) = .empty;
    defer entries.deinit(self.gpa);
    for (std.enums.values(Account.Vendor)) |vendor| {
        const entry = file.entry(@tagName(vendor)) orelse continue;
        const listed = providers.json.array(entry.getPtr(models_key)) orelse continue;
        for (listed.items) |*value| {
            const model = decodeModel(value) orelse continue;
            entries.append(self.gpa, .{ .vendor = vendor, .model = model }) catch return;
        }
    }
    const owned = entries.toOwnedSlice(self.gpa) catch return;
    self.metadata.deinit();
    self.metadata = .{ .gpa = self.gpa, .entries = owned };
}

fn saveAccount(self: *Catalog, index: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const encoded = try encodeList(arena.allocator(), self.lists[index]);
    const row = &Account.table[index];
    if (row.model_source == .local) {
        try json_store.save(self.gpa, self.io, &.{ .path = self.models_path, .key = row.id }, .{
            .base_url = self.base_urls[index].?,
            .models = encoded,
        }, .{});
        return;
    }
    try json_store.save(self.gpa, self.io, &.{
        .path = self.models_path,
        .key = row.id,
    }, .{ .models = encoded }, .{});
}

fn saveMetadata(self: *Catalog) !void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    var stored: std.json.ArrayHashMap(Stored) = .{};
    for (std.enums.values(Account.Vendor)) |vendor| {
        var encoded: std.ArrayList(Encoded) = .empty;
        for (self.metadata.entries) |*entry| {
            if (entry.vendor == vendor) try encoded.append(gpa, try encode(gpa, &entry.model));
        }
        if (encoded.items.len == 0) continue;
        try stored.map.put(gpa, @tagName(vendor), .{ .models = encoded.items });
    }
    try json_store.replace(self.gpa, self.io, self.metadata_path, stored);
}

fn encodeList(gpa: std.mem.Allocator, models: []const Model) ![]Encoded {
    const encoded = try gpa.alloc(Encoded, models.len);
    for (encoded, models) |*target, *model| target.* = try encode(gpa, model);
    return encoded;
}

fn encode(gpa: std.mem.Allocator, model: *const Model) !Encoded {
    var buffer: [efforts_bytes_max]u8 = undefined;
    var length: usize = 0;
    for (comptime std.enums.values(core.Provider.Effort)) |level| {
        if (!model.efforts.contains(level)) continue;
        const name = @tagName(level);
        if (length != 0) {
            buffer[length] = ',';
            length += 1;
        }
        @memcpy(buffer[length..][0..name.len], name);
        length += name.len;
    }
    return .{
        .name = try gpa.dupe(u8, model.name()),
        .engine = if (model.engineName().len != 0)
            try gpa.dupe(u8, model.engineName())
        else
            null,
        .served_as = if (model.servedName().len != 0)
            try gpa.dupe(u8, model.servedName())
        else
            null,
        .context_window = model.context_window,
        .tokens_max = model.tokens_max,
        .thinking = @tagName(model.thinking),
        .tools = @tagName(model.tools),
        .efforts = try gpa.dupe(u8, buffer[0..length]),
        .efforts_denied = model.efforts_denied,
        .price = model.price,
    };
}

fn decodeModel(value: *const std.json.Value) ?Model {
    const object = providers.json.object(value) orelse return null;
    const name = providers.json.string(object.getPtr("name")) orelse return null;
    var model = Model.init(name) catch return null;
    if (providers.json.string(object.getPtr("engine"))) |engine|
        model.setEngine(engine) catch return null;
    if (providers.json.string(object.getPtr("served_as"))) |served_as|
        model.serveAs(served_as) catch return null;
    model.context_window = json.positive(u64, object.getPtr("context_window"));
    model.tokens_max = json.positive(u32, object.getPtr("tokens_max"));
    if (providers.json.string(object.getPtr("thinking"))) |thinking|
        model.thinking = std.meta.stringToEnum(Model.Thinking, thinking) orelse .unknown;
    if (providers.json.string(object.getPtr("tools"))) |tools|
        model.tools = std.meta.stringToEnum(Model.Tools, tools) orelse .unknown;
    if (providers.json.string(object.getPtr("efforts"))) |efforts| {
        var levels = std.mem.splitScalar(u8, efforts, ',');
        while (levels.next()) |level| {
            model.addEffort(std.meta.stringToEnum(core.Provider.Effort, level) orelse continue);
        }
    }
    model.efforts_denied = providers.json.boolean(object.getPtr("efforts_denied")) orelse false;
    model.price = decodePrice(object.getPtr("price"));
    return model;
}

fn decodePrice(value: ?*const std.json.Value) ?Model.Price {
    const object = providers.json.object(value) orelse return null;
    return .{
        .input = providers.json.number(object.getPtr("input")) orelse return null,
        .output = providers.json.number(object.getPtr("output")) orelse return null,
        .cache_read = providers.json.number(object.getPtr("cache_read")) orelse 0,
        .cache_write = providers.json.number(object.getPtr("cache_write")) orelse 0,
        .long_context = decodeLongContext(object.getPtr("long_context")),
    };
}

fn decodeLongContext(value: ?*const std.json.Value) ?Model.Price.LongContext {
    const object = providers.json.object(value) orelse return null;
    return .{
        .prompt_tokens_min = json.positive(u64, object.getPtr("prompt_tokens_min")) orelse
            return null,
        .input = providers.json.number(object.getPtr("input")) orelse return null,
        .output = providers.json.number(object.getPtr("output")) orelse return null,
        .cache_read = providers.json.number(object.getPtr("cache_read")) orelse 0,
        .cache_write = providers.json.number(object.getPtr("cache_write")) orelse 0,
    };
}

test "a list makes an account nonempty, and a drop empties it" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const catalog = &rig.catalog;

    const kept = [_]Model{vendorModel("kept", 10, .high)};
    try catalog.setAccount(testing.anthropic_api_key, &.{ .models = &kept });
    try std.testing.expect(!catalog.isEmpty(testing.anthropic_api_key));
    catalog.dropAccount(testing.anthropic_api_key);
    try std.testing.expect(catalog.isEmpty(testing.anthropic_api_key));
}

const TestCatalog = struct {
    tmp: std.testing.TmpDir,
    home_buffer: [128]u8,
    catalog: Catalog,

    fn init(self: *TestCatalog, gpa: std.mem.Allocator) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const home = try testing.tmpHome(&self.home_buffer, &self.tmp);
        self.catalog = try Catalog.init(
            gpa,
            std.testing.io,
            &.{ .working_directory = ".", .home = home },
        );
    }

    fn deinit(self: *TestCatalog) void {
        self.catalog.deinit();
        self.tmp.cleanup();
    }

    fn reload(self: *TestCatalog, stored_models: []const u8) !void {
        const io = std.testing.io;
        try self.tmp.dir.createDirPath(io, ".drinky");
        try self.tmp.dir.writeFile(io, .{
            .sub_path = ".drinky/models.json",
            .data = stored_models,
        });
        const home = try testing.tmpHome(&self.home_buffer, &self.tmp);
        const reloaded = try Catalog.init(
            self.catalog.gpa,
            io,
            &.{ .working_directory = ".", .home = home },
        );
        self.catalog.deinit();
        self.catalog = reloaded;
    }
};

fn vendorModel(name: []const u8, window: ?u64, level: ?core.Provider.Effort) Model {
    var model = Model.init(name) catch unreachable;
    model.context_window = window;
    if (level) |found| model.addEffort(found);
    return model;
}

fn describe(catalog: *Catalog, entries: []const Metadata.Entry) !void {
    const owned = try catalog.gpa.dupe(Metadata.Entry, entries);
    try catalog.setMetadata(.{ .gpa = catalog.gpa, .entries = owned });
}

test "the vendor list wins every field it states, and the public metadata fills the rest" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const catalog = &rig.catalog;

    var vendor = vendorModel("gpt-5.6-sol", 272_000, .high);
    vendor.tokens_max = null;
    vendor.price = .{ .input = 1, .output = 4, .cache_read = 0.1, .cache_write = 1 };
    try catalog.setAccount(testing.openai_plan, &.{ .models = &.{vendor} });

    var public = Model.init("gpt-5.6-sol") catch unreachable;
    public.context_window = 1_050_000;
    public.tokens_max = 128_000;
    public.thinking = .supported;
    public.addEffort(.low);
    public.price = .{ .input = 2, .output = 10, .cache_read = 0.2, .cache_write = 2.5 };
    try describe(catalog, &.{.{ .vendor = .openai, .model = public }});

    const merged = catalog.find(testing.openai_plan, "gpt-5.6-sol").?;
    try std.testing.expectEqual(@as(?u64, 272_000), merged.context_window);
    try std.testing.expectEqual(@as(?u32, 128_000), merged.tokens_max);
    try std.testing.expect(merged.efforts.contains(.high));
    try std.testing.expect(!merged.efforts.contains(.low));
    try std.testing.expectEqual(@as(f64, 1), merged.price.?.input);
    try std.testing.expectEqual(Model.Thinking.supported, merged.thinking);
}

test "a vendor list that states no reasoning keeps every level of the public metadata out" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const catalog = &rig.catalog;

    var vendor = vendorModel("claude-haiku-4-5-20251001", 200_000, null);
    vendor.thinking = .unsupported;
    try catalog.setAccount(testing.anthropic_api_key, &.{ .models = &.{vendor} });

    var public = Model.init("claude-haiku-4.5") catch unreachable;
    public.thinking = .supported;
    public.addEffort(.low);
    public.addEffort(.high);
    try describe(catalog, &.{.{ .vendor = .anthropic, .model = public }});

    const merged = catalog.find(testing.anthropic_api_key, "claude-haiku-4-5-20251001").?;
    try std.testing.expectEqual(Model.Thinking.unsupported, merged.thinking);
    try std.testing.expectEqual(@as(usize, 0), merged.efforts.count());
    for (std.enums.values(core.Provider.Effort)) |level| {
        try std.testing.expect(merged.fold(level) == null);
    }
}

test "a vendor list that denies the effort control keeps every level of the public metadata out" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const catalog = &rig.catalog;

    var vendor = vendorModel("claude-fable-5", 200_000, null);
    vendor.efforts_denied = true;
    try catalog.setAccount(testing.anthropic_api_key, &.{ .models = &.{vendor} });

    var public = Model.init("claude-fable-5") catch unreachable;
    public.thinking = .supported;
    public.addEffort(.high);
    try describe(catalog, &.{.{ .vendor = .anthropic, .model = public }});

    const merged = catalog.find(testing.anthropic_api_key, "claude-fable-5").?;
    try std.testing.expectEqual(Model.Thinking.supported, merged.thinking);
    try std.testing.expectEqual(@as(usize, 0), merged.efforts.count());
    try std.testing.expect(merged.fold(.high) == null);
}

test "public metadata that states no reasoning keeps the levels of the vendor list" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const catalog = &rig.catalog;

    try catalog.setAccount(
        testing.anthropic_api_key,
        &.{ .models = &.{vendorModel("claude-opus-4-8", 1_000_000, .high)} },
    );

    var public = Model.init("claude-opus-4.8") catch unreachable;
    public.thinking = .unsupported;
    try describe(catalog, &.{.{ .vendor = .anthropic, .model = public }});

    const merged = catalog.find(testing.anthropic_api_key, "claude-opus-4-8").?;
    try std.testing.expectEqual(Model.Thinking.unknown, merged.thinking);
    try std.testing.expect(merged.efforts.contains(.high));
    try std.testing.expectEqual(@as(?core.Provider.Effort, .high), merged.fold(.high));
}

test "a model that no source describes is not offered" {
    const gpa = std.testing.allocator;
    var rig: TestCatalog = undefined;
    try rig.init(gpa);
    defer rig.deinit();
    const catalog = &rig.catalog;

    try catalog.setAccount(testing.openai_api_key, &.{ .models = &.{
        vendorModel("text-embedding-3-large", null, null),
        vendorModel("gpt-5.6-sol", null, null),
    } });
    try std.testing.expect(catalog.isEmpty(testing.openai_api_key));

    var public = Model.init("gpt-5.6-sol") catch unreachable;
    public.context_window = 1_050_000;
    public.addEffort(.medium);
    try describe(catalog, &.{.{ .vendor = .openai, .model = public }});

    try std.testing.expect(!catalog.isEmpty(testing.openai_api_key));
    try std.testing.expect(catalog.find(testing.openai_api_key, "text-embedding-3-large") == null);

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(gpa);
    try catalog.list(testing.openai_api_key, &listed, gpa);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed.items[0].name());
    try std.testing.expectEqual(@as(?u64, 1_050_000), listed.items[0].context_window);
}

test "metadata of one vendor never reaches the account of another" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const catalog = &rig.catalog;

    try catalog.setAccount(testing.anthropic_api_key, &.{
        .models = &.{vendorModel("shared-name", null, .high)},
    });
    var public = Model.init("shared-name") catch unreachable;
    public.price = .{ .input = 1, .output = 2, .cache_read = 0, .cache_write = 0 };
    try describe(catalog, &.{.{ .vendor = .openai, .model = public }});

    try std.testing.expect(catalog.find(testing.anthropic_api_key, "shared-name").?.price == null);
}

test "a stored model survives a round trip through both files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);

    var written = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer written.deinit();

    var model = Model.init("claude-opus-4-8") catch unreachable;
    model.context_window = 1_000_000;
    model.tokens_max = 128_000;
    try model.setEngine("Claude weights");
    model.thinking = .supported;
    model.tools = .supported;
    model.addEffort(.low);
    model.addEffort(.xhigh);
    model.price = .{
        .input = 5,
        .output = 25,
        .cache_read = 0.5,
        .cache_write = 6.25,
        .long_context = .{
            .prompt_tokens_min = 200_000,
            .input = 10,
            .output = 37.5,
            .cache_read = 1,
            .cache_write = 12.5,
        },
    };
    var alias = Model.init("grok-4.20") catch unreachable;
    alias.context_window = 256_000;
    alias.serveAs("grok-4.20-0309-reasoning") catch unreachable;
    try written.setAccount(testing.anthropic_plan, &.{ .models = &.{ model, alias } });

    var bare = Model.init("anthropic/public-only") catch unreachable;
    bare.context_window = 200_000;
    bare.efforts_denied = true;
    bare.price = .{ .input = 1, .output = 5, .cache_read = 0.1, .cache_write = 1.25 };
    try written.setMetadata(.{
        .gpa = gpa,
        .entries = try gpa.dupe(Metadata.Entry, &.{.{ .vendor = .openrouter, .model = bare }}),
    });

    var read = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer read.deinit();

    const restored = read.find(testing.anthropic_plan, "claude-opus-4-8").?;
    try std.testing.expectEqual(@as(?u64, 1_000_000), restored.context_window);
    try std.testing.expectEqual(@as(?u32, 128_000), restored.tokens_max);
    try std.testing.expectEqualStrings("Claude weights", restored.engineName());
    try std.testing.expectEqual(Model.Thinking.supported, restored.thinking);
    try std.testing.expectEqual(Model.Tools.supported, restored.tools);
    try std.testing.expect(restored.efforts.contains(.low));
    try std.testing.expect(restored.efforts.contains(.xhigh));
    try std.testing.expect(!restored.efforts.contains(.high));
    try std.testing.expectEqual(@as(f64, 6.25), restored.price.?.cache_write);
    const restored_tier = restored.price.?.long_context.?;
    try std.testing.expectEqual(@as(u64, 200_000), restored_tier.prompt_tokens_min);
    try std.testing.expectEqual(@as(f64, 10), restored_tier.input);
    try std.testing.expectEqual(@as(f64, 37.5), restored_tier.output);
    try std.testing.expectEqual(@as(f64, 1), restored_tier.cache_read);
    try std.testing.expectEqual(@as(f64, 12.5), restored_tier.cache_write);
    try std.testing.expectEqualStrings("", restored.servedName());
    try std.testing.expectEqualStrings(
        "grok-4.20-0309-reasoning",
        read.find(testing.anthropic_plan, "grok-4.20").?.servedName(),
    );
    const public = read.find(testing.openrouter_api, "anthropic/public-only").?;
    try std.testing.expectEqual(@as(?u64, 200_000), public.context_window);
    try std.testing.expect(public.efforts_denied);
    try std.testing.expectEqual(@as(f64, 1.25), public.price.?.cache_write);
    try std.testing.expect(public.price.?.long_context == null);

    read.dropAccount(testing.anthropic_plan);
    var reopened = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer reopened.deinit();
    try std.testing.expect(reopened.isEmpty(testing.anthropic_plan));
    try std.testing.expect(!reopened.isEmpty(testing.openrouter_api));
}

test "a metadata save replaces the entries of every vendor at once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/metadata.json", .data = "not json" });

    var written = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer written.deinit();
    const claude = vendorModel("claude-opus-4.8", 1_000_000, .high);
    const gpt = vendorModel("gpt-5.6-sol", 1_050_000, .high);
    try written.setAccount(testing.anthropic_api_key, &.{
        .models = &.{vendorModel(claude.name(), null, null)},
    });
    try written.setAccount(testing.openai_api_key, &.{
        .models = &.{vendorModel(gpt.name(), null, null)},
    });
    try written.setMetadata(.{ .gpa = gpa, .entries = try gpa.dupe(Metadata.Entry, &.{
        .{ .vendor = .anthropic, .model = claude },
        .{ .vendor = .openai, .model = gpt },
    }) });
    try written.setMetadata(.{ .gpa = gpa, .entries = try gpa.dupe(Metadata.Entry, &.{
        .{ .vendor = .openai, .model = gpt },
    }) });

    var read = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer read.deinit();
    try std.testing.expect(read.find(testing.anthropic_api_key, "claude-opus-4.8") == null);
    const described = read.find(testing.openai_api_key, "gpt-5.6-sol").?;
    try std.testing.expectEqual(@as(?u64, 1_050_000), described.context_window);
}

test "a DwarfStar list keeps its base URL and drops after an address change" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);

    var written = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer written.deinit();
    var model = vendorModel("deepseek-v4-pro", 1_048_576, .high);
    try model.setEngine("DeepSeek V4 Flash");
    model.tools = .supported;
    try written.setAccount(testing.ds4, &.{
        .models = &.{model},
        .base_url = "http://127.0.0.1:8000/v1",
    });

    var read = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer read.deinit();
    try std.testing.expectEqualStrings(
        "DeepSeek V4 Flash",
        read.find(testing.ds4, "deepseek-v4-pro").?.engineName(),
    );

    read.dropAccountFromAnotherUrl(testing.ds4, "http://127.0.0.1:8000/v1");
    try std.testing.expect(!read.isEmpty(testing.ds4));
    read.dropAccountFromAnotherUrl(testing.ds4, "http://127.0.0.1:9000/v1");
    try std.testing.expect(read.isEmpty(testing.ds4));
    var dropped = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer dropped.deinit();
    try std.testing.expect(dropped.isEmpty(testing.ds4));
}

test "a DwarfStar list with no stored URL is foreign" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.reload(
        \\{ "ds4": { "models": [ { "name": "deepseek-v4-pro", "context_window": 1048576 } ] } }
    );
    const catalog = &rig.catalog;
    try std.testing.expect(!catalog.isEmpty(testing.ds4));
    catalog.dropAccountFromAnotherUrl(testing.ds4, "http://127.0.0.1:8000/v1");
    try std.testing.expect(catalog.isEmpty(testing.ds4));
}

test "a locked cache file keeps the fetched list of this session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);

    var clock: core.testing.ClockIo = undefined;
    clock.init(gpa);
    defer clock.deinit();
    var catalog = try init(gpa, clock.io(), &.{ .working_directory = ".", .home = home });
    defer catalog.deinit();
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);

    var held = try tmp.dir.createFile(io, ".drinky/models.json.lock", .{ .lock = .exclusive });
    defer held.close(io);

    const fetched = [_]Model{vendorModel("claude-opus-4-8", 1_000_000, .high)};
    try std.testing.expectError(
        error.StoreBusy,
        catalog.setAccount(testing.anthropic_api_key, &.{ .models = &fetched }),
    );
    try std.testing.expect(!catalog.isEmpty(testing.anthropic_api_key));
    try std.testing.expect(catalog.find(testing.anthropic_api_key, "claude-opus-4-8") != null);
}

test "a cached limit that is not a count reads as unstated" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.reload(
        \\{ "anthropic-api-key": { "models": [
        \\  { "name": "zero", "context_window": 0, "tokens_max": 0, "thinking": "supported" },
        \\  { "name": "negative", "context_window": -1, "tokens_max": -1,
        \\    "thinking": "supported" },
        \\  { "name": "stated", "context_window": 200000, "tokens_max": 64000 } ] } }
    );
    const catalog = &rig.catalog;

    for ([_][]const u8{ "zero", "negative" }) |name| {
        const model = catalog.find(testing.anthropic_api_key, name).?;
        try std.testing.expectEqual(@as(?u64, null), model.context_window);
        try std.testing.expectEqual(@as(?u32, null), model.tokens_max);
    }

    const stated = catalog.find(testing.anthropic_api_key, "stated").?;
    try std.testing.expectEqual(@as(?u64, 200_000), stated.context_window);
    try std.testing.expectEqual(@as(?u32, 64_000), stated.tokens_max);
}

test "a cached tier that is not complete reads as no tier" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.reload(
        \\{ "anthropic-api-key": { "models": [
        \\  { "name": "zero-threshold", "price": { "input": 2, "output": 10,
        \\      "long_context": { "prompt_tokens_min": 0, "input": 4, "output": 20 } } },
        \\  { "name": "no-input", "price": { "input": 2, "output": 10,
        \\      "long_context": { "prompt_tokens_min": 200000, "output": 20 } } },
        \\  { "name": "not-an-object", "price": { "input": 2, "output": 10,
        \\      "long_context": "tiered" } },
        \\  { "name": "complete", "price": { "input": 2, "output": 10,
        \\      "long_context": { "prompt_tokens_min": 200000, "input": 4, "output": 20 } } } ] } }
    );
    const catalog = &rig.catalog;

    for ([_][]const u8{ "zero-threshold", "no-input", "not-an-object" }) |name| {
        const model = catalog.find(testing.anthropic_api_key, name).?;
        try std.testing.expectEqual(@as(f64, 2), model.price.?.input);
        try std.testing.expect(model.price.?.long_context == null);
    }

    const complete = catalog.find(testing.anthropic_api_key, "complete").?;
    const tier = complete.price.?.long_context.?;
    try std.testing.expectEqual(@as(u64, 200_000), tier.prompt_tokens_min);
    try std.testing.expectEqual(@as(f64, 4), tier.input);
    try std.testing.expectEqual(@as(f64, 0), tier.cache_read);
}

test "a missing or unreadable cache leaves an empty catalog" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try testing.tmpHome(&home_buffer, &tmp);

    var missing = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    for (0..Account.table.len) |index| try std.testing.expect(missing.isEmpty(index));
    missing.deinit();

    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/models.json", .data = "not json" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/metadata.json", .data = "[]" });

    var broken = try init(gpa, io, &.{ .working_directory = ".", .home = home });
    defer broken.deinit();
    try std.testing.expect(broken.isEmpty(testing.anthropic_api_key));
    try std.testing.expect(broken.isEmpty(testing.openrouter_api));
}

test "a merged model without tool support is not offered" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const catalog = &rig.catalog;

    try catalog.setAccount(testing.openai_api_key, &.{
        .models = &.{vendorModel("gpt-5.6-sol", 272_000, .high)},
    });
    var public = Model.init("gpt-5.6-sol") catch unreachable;
    public.tools = .unsupported;
    public.price = .{ .input = 2, .output = 10, .cache_read = 0.2, .cache_write = 2.5 };
    try describe(catalog, &.{.{ .vendor = .openai, .model = public }});

    try std.testing.expect(catalog.find(testing.openai_api_key, "gpt-5.6-sol") == null);
    try std.testing.expect(catalog.isEmpty(testing.openai_api_key));
}

test "a DeepSeek account takes public metadata by the vendor id" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    const catalog = &rig.catalog;

    try catalog.setAccount(testing.deepseek_api_key, &.{ .models = &.{
        vendorModel("deepseek-v4-pro", null, null),
        vendorModel("deepseek-flash", null, null),
    } });

    var public_pro = Model.init("deepseek-v4-pro") catch unreachable;
    public_pro.context_window = 1_048_576;
    public_pro.thinking = .supported;
    public_pro.tools = .supported;
    public_pro.price = .{ .input = 1.6, .output = 3.2, .cache_read = 0.135, .cache_write = 0 };
    var public_flash = Model.init("deepseek-v4.1-flash") catch unreachable;
    public_flash.context_window = 1_048_576;
    public_flash.thinking = .supported;
    public_flash.tools = .supported;
    public_flash.price = .{ .input = 0.15, .output = 0.6, .cache_read = 0.003, .cache_write = 0 };
    try describe(catalog, &.{
        .{ .vendor = .deepseek, .model = public_pro },
        .{ .vendor = .deepseek, .model = public_flash },
    });

    const merged = catalog.find(testing.deepseek_api_key, "deepseek-v4-pro").?;
    try std.testing.expectEqual(@as(f64, 1.6), merged.price.?.input);
    try std.testing.expectEqual(@as(?u64, 1_048_576), merged.context_window);
    const flash = catalog.find(testing.deepseek_api_key, "deepseek-flash").?;
    try std.testing.expectEqualStrings("deepseek-flash", flash.name());
    try std.testing.expectEqual(@as(f64, 0.15), flash.price.?.input);
}

test "an OpenRouter account reads the public list and never the account cache" {
    const gpa = std.testing.allocator;
    var rig: TestCatalog = undefined;
    try rig.init(gpa);
    defer rig.deinit();
    try rig.reload(
        \\{ "openrouter-api-key": { "models": [ { "name": "ignored", "context_window": 10 } ] },
        \\  "openrouter-api": { "models": [ { "name": "ignored", "context_window": 10 } ] } }
    );
    const catalog = &rig.catalog;

    try std.testing.expect(catalog.isEmpty(testing.openrouter_api_key));
    try std.testing.expect(catalog.isEmpty(testing.openrouter_api));

    var listed_model = Model.init("openai/gpt-5.6-sol") catch unreachable;
    listed_model.context_window = 1_050_000;
    listed_model.tools = .supported;
    try describe(catalog, &.{.{ .vendor = .openrouter, .model = listed_model }});

    try std.testing.expect(!catalog.isEmpty(testing.openrouter_api_key));
    try std.testing.expect(!catalog.isEmpty(testing.openrouter_api));
    try std.testing.expectEqualStrings(
        "openai/gpt-5.6-sol",
        catalog.find(testing.openrouter_api, "openai/gpt-5.6-sol").?.name(),
    );

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(gpa);
    try catalog.list(testing.openrouter_api_key, &listed, gpa);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("openai/gpt-5.6-sol", listed.items[0].name());
}

test "a stored model without a tools field is offered with unknown tool support" {
    var rig: TestCatalog = undefined;
    try rig.init(std.testing.allocator);
    defer rig.deinit();
    try rig.reload(
        \\{ "anthropic-api-key": { "models": [ { "name": "legacy", "context_window": 10 } ] } }
    );
    const model = rig.catalog.find(testing.anthropic_api_key, "legacy").?;
    try std.testing.expectEqual(Model.Tools.unknown, model.tools);
}
