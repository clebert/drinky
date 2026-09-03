//! Every model Drinky knows, and the two caches behind it. No request runs here
//! and none runs at startup: `init` reads the files alone, and the user asks for
//! a fetch when a list is stale or empty.
//!
//! The two caches differ in what they belong to, so they never share a file.
//! `models.json` holds the list of each account, which belongs to the principal
//! behind that credential. A logout and a credential replacement drop that list
//! from memory, and a removal that fails leaves it in the file, so the next
//! start loads it again. An account that reads its key from the environment has
//! no such event, so its list stands until the next fetch. `metadata.json` holds
//! the public facts of a vendor model, which belong to nobody and survive every
//! logout.
//!
//! A merge joins them, and the vendor wins every field it states. Only the
//! aggregator prices a model.

const std = @import("std");

const json = @import("json.zig");
const json_store = @import("json_store.zig");
const llm = @import("llm.zig");
const Model = @import("Model.zig");
const OpenRouter = @import("OpenRouter.zig");

const Catalog = @This();

/// The longest effort list one model can encode: every rung and its separator.
const efforts_bytes_max = 64;
const models_key = "models";

gpa: std.mem.Allocator,
io: std.Io,
/// Where the account lists live. An empty path holds the catalog in memory
/// alone, which is what a test wants and what a store failure leaves behind.
models_path: []const u8,
/// Where the public metadata lives, under the same empty-path rule.
metadata_path: []const u8,
/// The vendor list of each account, exactly as the vendor stated it. An empty
/// list means the user has not fetched that account yet.
accounts: std.EnumArray(llm.Account, []Model),
/// The public metadata of every vendor model Drinky reaches.
metadata: []OpenRouter.Entry,

/// The stored shape of one model. The writer emits an optional field that no
/// source stated as a JSON null, so a reader cannot mistake a default for a
/// fact. A decoder takes that null as the absent value it is.
const Encoded = struct {
    name: []const u8,
    context_window: ?u64,
    tokens_max: ?u32,
    thinking: []const u8,
    /// The effort levels as one comma-separated list, which reads as a list in
    /// the file and needs no allocation to build.
    efforts: []const u8,
    /// Whether the vendor denied the effort control. An empty list is silent
    /// about that, so the denial needs a field of its own.
    efforts_denied: bool,
    price: ?Model.Price,
};

/// Open both caches. A file that is absent leaves its half empty, and a file
/// Drinky cannot read leaves it empty too, because a cache is a convenience and
/// never a reason to refuse a start.
pub fn init(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !Catalog {
    const models_path = try std.fs.path.join(gpa, &.{ home, ".drinky", "models.json" });
    errdefer gpa.free(models_path);
    const metadata_path = try std.fs.path.join(gpa, &.{ home, ".drinky", "metadata.json" });
    errdefer gpa.free(metadata_path);

    var catalog: Catalog = .{
        .gpa = gpa,
        .io = io,
        .models_path = models_path,
        .metadata_path = metadata_path,
        .accounts = .initFill(&.{}),
        .metadata = &.{},
    };
    catalog.loadAccounts();
    catalog.loadMetadata();
    return catalog;
}

pub fn deinit(self: *Catalog) void {
    for (std.enums.values(llm.Account)) |account| self.gpa.free(self.accounts.get(account));
    self.gpa.free(self.metadata);
    self.gpa.free(self.models_path);
    self.gpa.free(self.metadata_path);
}

/// Whether `account` has no model at all, so the user must fetch its list before
/// anything can run on it.
pub fn isEmpty(self: *const Catalog, account: llm.Account) bool {
    for (self.accounts.get(account)) |vendor| {
        if (self.merge(account, vendor) != null) return false;
    }
    return true;
}

/// Append every model `account` offers, in the order the vendor listed it. A
/// model that no source describes stays out, because a bare id states nothing
/// the user can choose by.
pub fn list(
    self: *const Catalog,
    account: llm.Account,
    out: *std.ArrayList(Model),
    gpa: std.mem.Allocator,
) !void {
    for (self.accounts.get(account)) |vendor| {
        const merged = self.merge(account, vendor) orelse continue;
        try out.append(gpa, merged);
    }
}

/// The model `name` of `account`, or null when the account does not offer it.
pub fn find(self: *const Catalog, account: llm.Account, name: []const u8) ?Model {
    for (self.accounts.get(account)) |vendor| {
        if (!vendor.sameName(name)) continue;
        return self.merge(account, vendor);
    }
    return null;
}

/// One vendor model under its public metadata, or null when the result
/// describes nothing. The vendor wins every field it states, so a subscription
/// keeps the window of its own backend even where the public API contradicts it.
fn merge(self: *const Catalog, account: llm.Account, vendor: Model) ?Model {
    var merged = vendor;
    const public = self.lookup(account.provider(), vendor.name());
    if (public) |extra| {
        merged.price = extra.price;
        if (merged.context_window == null) merged.context_window = extra.context_window;
        // A vendor that states no thinking at all takes the state of the
        // aggregator. A vendor that named a level proves that the model reasons,
        // so the aggregator can never deny the reasoning of such a model.
        const denies = extra.thinking == .unsupported and merged.efforts.count() != 0;
        if (merged.thinking == .unknown and !denies) merged.thinking = extra.thinking;
        // A model that takes no level keeps its empty list, so no aggregator can
        // name a control that the vendor refuses.
        if (merged.takesEffort() and merged.efforts.count() == 0) merged.efforts = extra.efforts;
    }
    const describes = merged.context_window != null or
        merged.efforts.count() != 0 or
        merged.price != null or
        merged.thinking != .unknown;
    return if (describes) merged else null;
}

fn lookup(self: *const Catalog, provider: llm.Provider, name: []const u8) ?Model {
    const metadata: OpenRouter = .{ .gpa = self.gpa, .entries = self.metadata };
    return metadata.lookup(provider, name);
}

/// Replace the list of `account` and write it through. The caller owns
/// `discovered` until this returns, because the catalog copies it.
pub fn setAccount(self: *Catalog, account: llm.Account, discovered: []const Model) !void {
    const copy = try self.gpa.dupe(Model, discovered);
    self.gpa.free(self.accounts.get(account));
    self.accounts.set(account, copy);
    try self.saveAccount(account);
}

/// Drop the list of `account` from memory, and remove it from the file. The
/// list belongs to the principal behind a credential, so a replaced credential
/// takes it along for this session in every case. A removal that fails leaves
/// the file as it stands, so the next start loads that list again.
pub fn dropAccount(self: *Catalog, account: llm.Account) void {
    self.gpa.free(self.accounts.get(account));
    self.accounts.set(account, &.{});
    if (self.models_path.len == 0) return;
    json_store.remove(self.gpa, self.io, self.models_path, @tagName(account)) catch {};
}

/// Replace the public metadata and write it through.
pub fn setMetadata(self: *Catalog, entries: []const OpenRouter.Entry) !void {
    const copy = try self.gpa.dupe(OpenRouter.Entry, entries);
    self.gpa.free(self.metadata);
    self.metadata = copy;
    try self.saveMetadata();
}

fn loadAccounts(self: *Catalog) void {
    if (self.models_path.len == 0) return;
    var file = (json_store.open(self.gpa, self.io, self.models_path) catch return) orelse return;
    defer file.deinit();
    for (std.enums.values(llm.Account)) |account| {
        const entry = file.entry(@tagName(account)) orelse continue;
        const listed = json.array(entry.get(models_key)) orelse continue;
        const models = self.decodeList(listed) catch continue;
        self.gpa.free(self.accounts.get(account));
        self.accounts.set(account, models);
    }
}

fn loadMetadata(self: *Catalog) void {
    if (self.metadata_path.len == 0) return;
    var file = (json_store.open(self.gpa, self.io, self.metadata_path) catch return) orelse return;
    defer file.deinit();

    var entries: std.ArrayList(OpenRouter.Entry) = .empty;
    defer entries.deinit(self.gpa);
    for (std.enums.values(llm.Provider)) |provider| {
        const entry = file.entry(@tagName(provider)) orelse continue;
        const listed = json.array(entry.get(models_key)) orelse continue;
        for (listed.items) |value| {
            const model = decodeModel(value) orelse continue;
            entries.append(self.gpa, .{ .provider = provider, .model = model }) catch return;
        }
    }
    const owned = entries.toOwnedSlice(self.gpa) catch return;
    self.gpa.free(self.metadata);
    self.metadata = owned;
}

fn decodeList(self: *Catalog, listed: std.json.Array) ![]Model {
    var models: std.ArrayList(Model) = .empty;
    errdefer models.deinit(self.gpa);
    for (listed.items) |value| {
        const model = decodeModel(value) orelse continue;
        try models.append(self.gpa, model);
    }
    return models.toOwnedSlice(self.gpa);
}

fn saveAccount(self: *Catalog, account: llm.Account) !void {
    if (self.models_path.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const encoded = try encodeList(arena.allocator(), self.accounts.get(account));
    try json_store.save(self.gpa, self.io, self.models_path, @tagName(account), .{
        .models = encoded,
    }, .{});
}

fn saveMetadata(self: *Catalog) !void {
    if (self.metadata_path.len == 0) return;
    for (std.enums.values(llm.Provider)) |provider| {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const gpa = arena.allocator();

        var models: std.ArrayList(Model) = .empty;
        for (self.metadata) |entry| {
            if (entry.provider != provider) continue;
            try models.append(gpa, entry.model);
        }
        const encoded = try encodeList(gpa, models.items);
        try json_store.save(self.gpa, self.io, self.metadata_path, @tagName(provider), .{
            .models = encoded,
        }, .{});
    }
}

fn encodeList(gpa: std.mem.Allocator, models: []const Model) ![]Encoded {
    const encoded = try gpa.alloc(Encoded, models.len);
    for (encoded, models) |*target, *model| target.* = try encode(gpa, model);
    return encoded;
}

fn encode(gpa: std.mem.Allocator, model: *const Model) !Encoded {
    var buffer: [efforts_bytes_max]u8 = undefined;
    var length: usize = 0;
    for (comptime std.enums.values(llm.Effort)) |level| {
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
        .context_window = model.context_window,
        .tokens_max = model.tokens_max,
        .thinking = @tagName(model.thinking),
        .efforts = try gpa.dupe(u8, buffer[0..length]),
        .efforts_denied = model.efforts_denied,
        .price = model.price,
    };
}

fn decodeModel(value: std.json.Value) ?Model {
    const object = json.object(value) orelse return null;
    const name = json.string(object.get("name")) orelse return null;
    var model = Model.init(name) catch return null;
    model.context_window = positive(object.get("context_window"));
    if (positive(object.get("tokens_max"))) |limit|
        model.tokens_max = std.math.cast(u32, limit);
    if (json.string(object.get("thinking"))) |thinking|
        model.thinking = std.meta.stringToEnum(Model.Thinking, thinking) orelse .unknown;
    if (json.string(object.get("efforts"))) |efforts| {
        var levels = std.mem.splitScalar(u8, efforts, ',');
        while (levels.next()) |level| {
            model.addEffort(std.meta.stringToEnum(llm.Effort, level) orelse continue);
        }
    }
    model.efforts_denied = boolean(object.get("efforts_denied"));
    model.price = decodePrice(object.get("price"));
    return model;
}

fn boolean(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .bool => |flag| flag,
        else => false,
    };
}

/// A count that states a limit, or null when it is absent or not one. A cached
/// limit reads like a fetched one, so a non-positive count states no limit.
fn positive(value: ?std.json.Value) ?u64 {
    const found = json.integer(value) orelse return null;
    return if (found > 0) @intCast(found) else null;
}

fn decodePrice(value: ?std.json.Value) ?Model.Price {
    const object = json.object(value orelse return null) orelse return null;
    return .{
        .input = number(object.get("input")) orelse return null,
        .output = number(object.get("output")) orelse return null,
        .cache_read = number(object.get("cache_read")) orelse 0,
        .cache_write = number(object.get("cache_write")) orelse 0,
    };
}

fn number(value: ?std.json.Value) ?f64 {
    return switch (value orelse return null) {
        .float => |found| found,
        .integer => |found| @floatFromInt(found),
        else => null,
    };
}

fn testCatalog(gpa: std.mem.Allocator) Catalog {
    return .{
        .gpa = gpa,
        .io = std.testing.io,
        .models_path = "",
        .metadata_path = "",
        .accounts = .initFill(&.{}),
        .metadata = &.{},
    };
}

fn vendorModel(name: []const u8, window: ?u64, level: ?llm.Effort) Model {
    var model = Model.init(name) catch unreachable;
    model.context_window = window;
    if (level) |found| model.addEffort(found);
    return model;
}

// A catalog with no path writes nothing, so a test and a failed store both keep
// their models in memory alone.
test "a catalog with no path holds its models in memory" {
    const gpa = std.testing.allocator;
    var catalog = testCatalog(gpa);
    defer gpa.free(catalog.accounts.get(.anthropic_api));

    const kept = [_]Model{vendorModel("kept", 10, .high)};
    try catalog.setAccount(.anthropic_api, &kept);
    try std.testing.expect(!catalog.isEmpty(.anthropic_api));
    catalog.dropAccount(.anthropic_api);
    try std.testing.expect(catalog.isEmpty(.anthropic_api));
}

test "the vendor wins every field it states and the aggregator fills the rest" {
    const gpa = std.testing.allocator;
    var catalog = testCatalog(gpa);

    // The subscription states a window of its own backend, which the public
    // metadata contradicts. The vendor wins.
    var vendor = vendorModel("gpt-5.6-sol", 272_000, .high);
    vendor.tokens_max = null;
    const vendor_models = [_]Model{vendor};
    catalog.accounts.set(.openai_subscription, try gpa.dupe(Model, &vendor_models));
    defer gpa.free(catalog.accounts.get(.openai_subscription));

    var public = Model.init("gpt-5.6-sol") catch unreachable;
    public.context_window = 1_050_000;
    public.thinking = .supported;
    public.addEffort(.low);
    public.price = .{ .input = 2, .output = 10, .cache_read = 0.2, .cache_write = 2.5 };
    const entries = [_]OpenRouter.Entry{.{ .provider = .openai, .model = public }};
    catalog.metadata = try gpa.dupe(OpenRouter.Entry, &entries);
    defer gpa.free(catalog.metadata);

    const merged = catalog.find(.openai_subscription, "gpt-5.6-sol").?;
    try std.testing.expectEqual(@as(?u64, 272_000), merged.context_window);
    // The vendor named a level, so its list stands whole.
    try std.testing.expect(merged.offers(.high));
    try std.testing.expect(!merged.offers(.low));
    // Only the aggregator prices a model. The Codex list states no thinking
    // state, so the aggregator fills it.
    try std.testing.expectEqual(@as(f64, 2), merged.price.?.input);
    try std.testing.expectEqual(Model.Thinking.supported, merged.thinking);
}

test "a vendor that states no reasoning keeps every aggregator level out" {
    const gpa = std.testing.allocator;
    var catalog = testCatalog(gpa);

    // The vendor states that the model never reasons, and it names no level.
    var vendor = vendorModel("claude-haiku-4-5-20251001", 200_000, null);
    vendor.thinking = .unsupported;
    const vendor_models = [_]Model{vendor};
    catalog.accounts.set(.anthropic_api, try gpa.dupe(Model, &vendor_models));
    defer gpa.free(catalog.accounts.get(.anthropic_api));

    var public = Model.init("claude-haiku-4.5") catch unreachable;
    public.thinking = .supported;
    public.addEffort(.low);
    public.addEffort(.high);
    const entries = [_]OpenRouter.Entry{.{ .provider = .anthropic, .model = public }};
    catalog.metadata = try gpa.dupe(OpenRouter.Entry, &entries);
    defer gpa.free(catalog.metadata);

    const merged = catalog.find(.anthropic_api, "claude-haiku-4-5-20251001").?;
    try std.testing.expectEqual(Model.Thinking.unsupported, merged.thinking);
    try std.testing.expectEqual(@as(usize, 0), merged.efforts.count());
    for (std.enums.values(llm.Effort)) |level| {
        try std.testing.expect(!merged.offers(level));
        try std.testing.expect(merged.reasoning(level) == .omitted);
    }
}

test "a vendor that denies the effort control keeps every aggregator level out" {
    const gpa = std.testing.allocator;
    var catalog = testCatalog(gpa);

    // The vendor states that the model reasons but takes no effort level.
    var vendor = vendorModel("claude-fable-5", 200_000, null);
    vendor.efforts_denied = true;
    const vendor_models = [_]Model{vendor};
    catalog.accounts.set(.anthropic_api, try gpa.dupe(Model, &vendor_models));
    defer gpa.free(catalog.accounts.get(.anthropic_api));

    var public = Model.init("claude-fable-5") catch unreachable;
    public.thinking = .supported;
    public.addEffort(.high);
    const entries = [_]OpenRouter.Entry{.{ .provider = .anthropic, .model = public }};
    catalog.metadata = try gpa.dupe(OpenRouter.Entry, &entries);
    defer gpa.free(catalog.metadata);

    const merged = catalog.find(.anthropic_api, "claude-fable-5").?;
    // The aggregator still states the thinking state.
    try std.testing.expectEqual(Model.Thinking.supported, merged.thinking);
    try std.testing.expect(!merged.offers(.high));
    try std.testing.expect(merged.reasoning(.high) == .omitted);
}

// A named level proves that the model reasons, so aggregator silence about the
// reasoning never takes that ladder away.
test "an aggregator that states no reasoning keeps the levels of the vendor" {
    const gpa = std.testing.allocator;
    var catalog = testCatalog(gpa);

    const vendor_models = [_]Model{vendorModel("claude-opus-4-8", 1_000_000, .high)};
    catalog.accounts.set(.anthropic_api, try gpa.dupe(Model, &vendor_models));
    defer gpa.free(catalog.accounts.get(.anthropic_api));

    var public = Model.init("claude-opus-4.8") catch unreachable;
    public.thinking = .unsupported;
    const entries = [_]OpenRouter.Entry{.{ .provider = .anthropic, .model = public }};
    catalog.metadata = try gpa.dupe(OpenRouter.Entry, &entries);
    defer gpa.free(catalog.metadata);

    const merged = catalog.find(.anthropic_api, "claude-opus-4-8").?;
    try std.testing.expectEqual(Model.Thinking.unknown, merged.thinking);
    try std.testing.expect(merged.offers(.high));
    try std.testing.expectEqual(llm.Effort.high, merged.reasoning(.high).named);
}

test "a model that no source describes is not offered" {
    const gpa = std.testing.allocator;
    var catalog = testCatalog(gpa);

    // An OpenAI key states an id and nothing else, so an embedding model and a
    // chat model arrive alike. Only the described one reaches the user.
    const vendor_models = [_]Model{
        vendorModel("text-embedding-3-large", null, null),
        vendorModel("gpt-5.6-sol", null, null),
    };
    catalog.accounts.set(.openai_api, try gpa.dupe(Model, &vendor_models));
    defer gpa.free(catalog.accounts.get(.openai_api));

    try std.testing.expect(catalog.isEmpty(.openai_api));

    var public = Model.init("gpt-5.6-sol") catch unreachable;
    public.context_window = 1_050_000;
    public.addEffort(.medium);
    const entries = [_]OpenRouter.Entry{.{ .provider = .openai, .model = public }};
    catalog.metadata = try gpa.dupe(OpenRouter.Entry, &entries);
    defer gpa.free(catalog.metadata);

    try std.testing.expect(!catalog.isEmpty(.openai_api));
    try std.testing.expect(catalog.find(.openai_api, "text-embedding-3-large") == null);

    var listed: std.ArrayList(Model) = .empty;
    defer listed.deinit(gpa);
    try catalog.list(.openai_api, &listed, gpa);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed.items[0].name());
    try std.testing.expectEqual(@as(?u64, 1_050_000), listed.items[0].context_window);
}

test "metadata of one vendor never reaches the account of another" {
    const gpa = std.testing.allocator;
    var catalog = testCatalog(gpa);

    const vendor_models = [_]Model{vendorModel("shared-name", null, .high)};
    catalog.accounts.set(.anthropic_api, try gpa.dupe(Model, &vendor_models));
    defer gpa.free(catalog.accounts.get(.anthropic_api));

    var public = Model.init("shared-name") catch unreachable;
    public.price = .{ .input = 1, .output = 2, .cache_read = 0, .cache_write = 0 };
    const entries = [_]OpenRouter.Entry{.{ .provider = .openai, .model = public }};
    catalog.metadata = try gpa.dupe(OpenRouter.Entry, &entries);
    defer gpa.free(catalog.metadata);

    try std.testing.expect(catalog.find(.anthropic_api, "shared-name").?.price == null);
}

test "a stored model survives a round trip through both files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var written = try init(gpa, io, home);
    defer written.deinit();

    var model = Model.init("claude-opus-4-8") catch unreachable;
    model.context_window = 1_000_000;
    model.tokens_max = 128_000;
    model.thinking = .supported;
    model.addEffort(.low);
    model.addEffort(.xhigh);
    model.price = .{ .input = 5, .output = 25, .cache_read = 0.5, .cache_write = 6.25 };
    try written.setAccount(.anthropic_subscription, &.{model});

    var bare = Model.init("public-only") catch unreachable;
    bare.context_window = 200_000;
    bare.efforts_denied = true;
    try written.setMetadata(&.{.{ .provider = .anthropic, .model = bare }});

    var read = try init(gpa, io, home);
    defer read.deinit();

    const restored = read.find(.anthropic_subscription, "claude-opus-4-8").?;
    try std.testing.expectEqual(@as(?u64, 1_000_000), restored.context_window);
    try std.testing.expectEqual(@as(?u32, 128_000), restored.tokens_max);
    try std.testing.expectEqual(Model.Thinking.supported, restored.thinking);
    try std.testing.expect(restored.offers(.low));
    try std.testing.expect(restored.offers(.xhigh));
    try std.testing.expect(!restored.offers(.high));
    try std.testing.expectEqual(@as(f64, 6.25), restored.price.?.cache_write);
    // The metadata file survives its own round trip, under its vendor.
    try std.testing.expectEqual(@as(usize, 1), read.metadata.len);
    try std.testing.expectEqual(llm.Provider.anthropic, read.metadata[0].provider);
    try std.testing.expectEqualStrings("public-only", read.metadata[0].model.name());
    // The denial of the effort control survives the file too.
    try std.testing.expect(read.metadata[0].model.efforts_denied);

    // A dropped account leaves the file without its key, and the metadata
    // stands, because it belongs to no principal.
    read.dropAccount(.anthropic_subscription);
    var reopened = try init(gpa, io, home);
    defer reopened.deinit();
    try std.testing.expect(reopened.isEmpty(.anthropic_subscription));
    try std.testing.expectEqual(@as(usize, 1), reopened.metadata.len);
}

// A cache write that failed leaves the fetched list in memory, so the account
// offers every model of this session and the caller reports a failed save
// rather than a failed fetch.
test "a locked cache file keeps the fetched list of this session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var catalog = try init(gpa, io, home);
    defer catalog.deinit();
    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    json_store.lock_policy = .{ .attempts_max = 2, .wait_ms = 0 };
    defer json_store.lock_policy = .{};

    // Another Drinky instance holds the lock of the models file.
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{catalog.models_path});
    defer gpa.free(lock_path);
    var held = try std.Io.Dir.cwd().createFile(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = @enumFromInt(0o600),
    });
    defer held.close(io);

    const fetched = [_]Model{vendorModel("claude-opus-4-8", 1_000_000, .high)};
    try std.testing.expectError(error.StoreBusy, catalog.setAccount(.anthropic_api, &fetched));
    try std.testing.expect(!catalog.isEmpty(.anthropic_api));
    try std.testing.expect(catalog.find(.anthropic_api, "claude-opus-4-8") != null);
}

// A cache holds what a vendor stated, so a limit that is not a count states
// nothing. A window of zero prints a percentage that Drinky cannot know, and an
// output limit of zero fails every turn at the provider.
test "a cached limit that is not a count reads as unstated" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[ { "name": "zero", "context_window": 0, "tokens_max": 0 },
        \\  { "name": "negative", "context_window": -1, "tokens_max": -1 },
        \\  { "name": "stated", "context_window": 200000, "tokens_max": 64000 } ]
    , .{});
    defer parsed.deinit();
    const listed = json.array(parsed.value).?;

    for (listed.items[0..2]) |value| {
        const model = decodeModel(value).?;
        try std.testing.expectEqual(@as(?u64, null), model.context_window);
        try std.testing.expectEqual(@as(?u32, null), model.tokens_max);
    }

    const stated = decodeModel(listed.items[2]).?;
    try std.testing.expectEqual(@as(?u64, 200_000), stated.context_window);
    try std.testing.expectEqual(@as(?u32, 64_000), stated.tokens_max);
}

test "a missing or unreadable cache leaves an empty catalog" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var missing = try init(gpa, io, home);
    for (std.enums.values(llm.Account)) |account| try std.testing.expect(missing.isEmpty(account));
    missing.deinit();

    var directory = try tmp.dir.createDirPathOpen(io, ".drinky", .{});
    directory.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/models.json", .data = "not json" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".drinky/metadata.json", .data = "[]" });

    // A cache is a convenience, so a broken one starts Drinky with no model
    // rather than with an error.
    var broken = try init(gpa, io, home);
    defer broken.deinit();
    try std.testing.expect(broken.isEmpty(.anthropic_api));
    try std.testing.expectEqual(@as(usize, 0), broken.metadata.len);
}
