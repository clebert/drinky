const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const Account = @import("Account.zig");
const deepseek = @import("deepseek/root.zig");
const json = @import("json.zig");
const Model = @import("Model.zig");
const net = @import("net.zig");

const Metadata = @This();

const endpoint = "https://openrouter.ai/api/v1/models";
const body_bytes_max = 8 * 1024 * 1024;
const entry_count_max = 4096;

gpa: std.mem.Allocator,
entries: []Entry,

pub const FetchError = providers.Http.FetchError ||
    error{ MetadataRequestFailed, BadMetadata, Timeout, ConcurrencyUnavailable };

pub const Entry = struct {
    vendor: Account.Vendor,
    model: Model,
};

pub fn deinit(self: *const Metadata) void {
    self.gpa.free(self.entries);
}

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    deadline: *const core.timeout.Deadline,
) FetchError!Metadata {
    return deadline.run(io, request, .{ gpa, io, transport }, release);
}

fn request(gpa: std.mem.Allocator, io: std.Io, transport: ?providers.Transport) !Metadata {
    const body = net.getBody(gpa, io, transport, &.{
        .method = .GET,
        .url = endpoint,
        .user_agent = providers.Transport.client_name,
        .headers = &.{net.accept_json},
    }, body_bytes_max) catch |err| switch (err) {
        error.ModelListRequestFailed => return error.MetadataRequestFailed,
        else => |other| return other,
    };
    defer gpa.free(body);
    return parse(gpa, body);
}

fn release(metadata: *const Metadata, _: *const std.meta.ArgsTuple(@TypeOf(request))) void {
    metadata.deinit();
}

fn parse(gpa: std.mem.Allocator, body: []const u8) error{ OutOfMemory, BadMetadata }!Metadata {
    const envelope = json.envelope(gpa, body, &.{
        .field = "data",
        .entries_max = entry_count_max,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadModelList => error.BadMetadata,
    };
    defer envelope.deinit();

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    for (envelope.entries) |*value| {
        if (decodeVendor(value)) |entry| try entries.append(gpa, entry);
        if (decodeOpenRouter(value)) |model| try entries.append(gpa, .{
            .vendor = .openrouter,
            .model = model,
        });
    }
    return .{ .gpa = gpa, .entries = try entries.toOwnedSlice(gpa) };
}

pub fn lookup(self: *const Metadata, vendor: Account.Vendor, name: []const u8) ?Model {
    var buffer: [Model.name_bytes_max]u8 = undefined;
    const wanted = slug(name, &buffer);
    for (self.entries) |*entry| {
        if (entry.vendor != vendor) continue;
        if (entry.model.sameName(wanted)) return entry.model;
    }
    return switch (vendor) {
        .deepseek => self.newestDeepseekSpelling(wanted),
        .anthropic, .openai, .xai, .openrouter, .google => null,
    };
}

fn newestDeepseekSpelling(self: *const Metadata, wanted: []const u8) ?Model {
    var newest: ?Model = null;
    var newest_rank: deepseek.family.Rank = undefined;
    for (self.entries) |*entry| {
        if (entry.vendor != .deepseek) continue;
        const rank = deepseek.family.rank(wanted, entry.model.name()) orelse continue;
        if (newest != null and !newest_rank.less(rank)) continue;
        newest = entry.model;
        newest_rank = rank;
    }
    return newest;
}

fn slug(name: []const u8, buffer: []u8) []const u8 {
    const trimmed = withoutDate(name);
    std.debug.assert(trimmed.len <= buffer.len);
    @memcpy(buffer[0..trimmed.len], trimmed);
    const result = buffer[0..trimmed.len];
    if (result.len < 4) return result;
    for (1..result.len - 1) |index| {
        if (result[index] != '-') continue;
        if (!std.ascii.isDigit(result[index - 1])) continue;
        if (!std.ascii.isDigit(result[index + 1])) continue;
        if (index + 2 < result.len and std.ascii.isDigit(result[index + 2])) continue;
        result[index] = '.';
    }
    return result;
}

fn withoutDate(name: []const u8) []const u8 {
    const date_length = 8;
    if (name.len < date_length + 2) return name;
    const start = name.len - date_length;
    if (name[start - 1] != '-') return name;
    for (name[start..]) |byte| {
        if (!std.ascii.isDigit(byte)) return name;
    }
    return name[0 .. start - 1];
}

pub fn authorOf(name: []const u8) []const u8 {
    const separator = std.mem.indexOfScalar(u8, name, '/') orelse return name;
    return name[0..separator];
}

fn vendorAuthor(vendor: Account.Vendor) ?[]const u8 {
    return switch (vendor) {
        .anthropic => "anthropic",
        .openai => "openai",
        .xai => "x-ai",
        .google => "google",
        .deepseek => "deepseek",
        .openrouter => null,
    };
}

fn vendorOf(author: []const u8) ?Account.Vendor {
    for (std.enums.values(Account.Vendor)) |vendor| {
        const named = vendorAuthor(vendor) orelse continue;
        if (std.mem.eql(u8, named, author)) return vendor;
    }
    return null;
}

fn decodeVendor(value: *const std.json.Value) ?Entry {
    const object = providers.json.object(value) orelse return null;
    const id = providers.json.string(object.getPtr("id")) orelse return null;
    const separator = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    const vendor = vendorOf(id[0..separator]) orelse return null;
    const name = id[separator + 1 ..];
    if (std.mem.indexOfScalar(u8, name, ':') != null) return null;

    var model = Model.init(name) catch return null;
    fillShared(&model, object);
    if (providers.json.object(object.getPtr("top_provider"))) |top| {
        model.tokens_max = json.positive(u32, top.getPtr("max_completion_tokens"));
    }
    return .{ .vendor = vendor, .model = model };
}

fn decodeOpenRouter(value: *const std.json.Value) ?Model {
    const object = providers.json.object(value) orelse return null;
    const id = providers.json.string(object.getPtr("id")) orelse return null;
    if (std.mem.indexOfScalar(u8, id, ':') != null) return null;
    const separator = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    if (std.mem.indexOfScalar(u8, id[separator + 1 ..], '/') != null) return null;
    const author = id[0..separator];
    const name = id[separator + 1 ..];
    if (author.len == 0 or name.len == 0) return null;
    if (author[0] == '~') return null;
    if (std.mem.eql(u8, author, "openrouter")) return null;

    var model = Model.init(id) catch return null;
    model.serveAs(name) catch return null;
    fillShared(&model, object);
    if (model.tools != .supported) return null;
    return model;
}

fn fillShared(model: *Model, object: *const std.json.ObjectMap) void {
    model.context_window = json.positive(u64, object.getPtr("context_length"));
    model.price = price(object.getPtr("pricing"));
    reasoning(model, object.getPtr("reasoning"));
    tools(model, object.getPtr("supported_parameters"));
}

fn price(value: ?*const std.json.Value) ?Model.Price {
    const object = providers.json.object(value) orelse return null;
    const input = rate(object.getPtr("prompt")) orelse return null;
    const output = rate(object.getPtr("completion")) orelse return null;
    if (input == 0 and output == 0) return null;
    var priced: Model.Price = .{
        .input = input,
        .output = output,
        .cache_read = rate(object.getPtr("input_cache_read")) orelse 0,
        .cache_write = rate(object.getPtr("input_cache_write")) orelse 0,
    };
    priced.long_context = longContext(&priced, object.getPtr("overrides"));
    return priced;
}

fn longContext(
    standard: *const Model.Price,
    value: ?*const std.json.Value,
) ?Model.Price.LongContext {
    const listed = providers.json.array(value) orelse return null;
    for (listed.items) |*item| {
        const object = providers.json.object(item) orelse continue;
        const threshold = json.positive(u64, object.getPtr("min_prompt_tokens")) orelse continue;
        return .{
            .prompt_tokens_min = threshold,
            .input = rate(object.getPtr("prompt")) orelse standard.input,
            .output = rate(object.getPtr("completion")) orelse standard.output,
            .cache_read = rate(object.getPtr("input_cache_read")) orelse standard.cache_read,
            .cache_write = rate(object.getPtr("input_cache_write")) orelse standard.cache_write,
        };
    }
    return null;
}

fn rate(value: ?*const std.json.Value) ?f64 {
    const text = providers.json.string(value) orelse return null;
    const parsed = std.fmt.parseFloat(f64, text) catch return null;
    if (parsed < 0) return null;
    const scaled = parsed * Model.tokens_per_million;
    return if (std.math.isFinite(scaled)) scaled else null;
}

fn reasoning(model: *Model, value: ?*const std.json.Value) void {
    const object = providers.json.object(value orelse {
        model.thinking = .unsupported;
        return;
    }) orelse return;

    model.thinking = .supported;
    const levels = providers.json.array(object.getPtr("supported_efforts")) orelse return;
    for (levels.items) |*level| {
        const name = providers.json.string(level) orelse continue;
        model.addEffort(std.meta.stringToEnum(core.Provider.Effort, name) orelse continue);
    }
}

fn tools(model: *Model, value: ?*const std.json.Value) void {
    const listed = providers.json.array(value) orelse return;
    for (listed.items) |*item| {
        const name = providers.json.string(item) orelse continue;
        if (std.mem.eql(u8, name, "tools")) {
            model.tools = .supported;
            return;
        }
    }
    model.tools = .unsupported;
}

test "an expired deadline refuses the metadata without a request" {
    const io = std.testing.io;
    var transport: providers.testing.FakeTransport = .{ .gpa = std.testing.allocator };
    defer transport.deinit();
    const expired: core.timeout.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetch(std.testing.allocator, io, transport.transport(), &expired),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}

fn countVendor(self: *const Metadata, vendor: Account.Vendor) usize {
    var count: usize = 0;
    for (self.entries) |*entry| {
        if (entry.vendor == vendor) count += 1;
    }
    return count;
}

test slug {
    var buffer: [Model.name_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("claude-opus-4.8", slug("claude-opus-4-8", &buffer));
    try std.testing.expectEqualStrings("claude-sonnet-4.6", slug("claude-sonnet-4-6", &buffer));
    try std.testing.expectEqualStrings(
        "claude-opus-4.5",
        slug("claude-opus-4-5-20251101", &buffer),
    );
    try std.testing.expectEqualStrings(
        "claude-haiku-4.5",
        slug("claude-haiku-4-5-20251001", &buffer),
    );
    try std.testing.expectEqualStrings("claude-opus-5", slug("claude-opus-5", &buffer));
    try std.testing.expectEqualStrings("gpt-5.6-sol", slug("gpt-5.6-sol", &buffer));
    try std.testing.expectEqualStrings("gpt-5.6-luna", slug("gpt-5.6-luna", &buffer));
    try std.testing.expectEqualStrings("model-4-56", slug("model-4-56", &buffer));
    try std.testing.expectEqualStrings("model-2025110", slug("model-2025110", &buffer));
}

test "a versionless DeepSeek id takes the latest versioned family spelling" {
    var v4 = Model.init("deepseek-v4-flash") catch unreachable;
    v4.price = .{ .input = 1, .output = 1, .cache_read = 0, .cache_write = 0 };
    var v41 = Model.init("deepseek-v4.1-flash") catch unreachable;
    v41.price = .{ .input = 2, .output = 2, .cache_read = 0, .cache_write = 0 };
    var snapshot = Model.init("deepseek-v4-flash-0731") catch unreachable;
    snapshot.price = .{ .input = 9, .output = 9, .cache_read = 0, .cache_write = 0 };
    var vision = Model.init("deepseek-v4-flash-vision-exp") catch unreachable;
    vision.price = .{ .input = 3, .output = 3, .cache_read = 0, .cache_write = 0 };
    var pro = Model.init("deepseek-v4-pro") catch unreachable;
    pro.price = .{ .input = 4, .output = 4, .cache_read = 0, .cache_write = 0 };
    var pro_snapshot = Model.init("deepseek-v4-pro-0813") catch unreachable;
    pro_snapshot.price = .{ .input = 6, .output = 6, .cache_read = 0, .cache_write = 0 };
    var pro_new = Model.init("deepseek-v4.2-pro") catch unreachable;
    pro_new.price = .{ .input = 5, .output = 5, .cache_read = 0, .cache_write = 0 };
    var entries = [_]Entry{
        .{ .vendor = .deepseek, .model = v4 },
        .{ .vendor = .deepseek, .model = snapshot },
        .{ .vendor = .deepseek, .model = v41 },
        .{ .vendor = .deepseek, .model = vision },
        .{ .vendor = .deepseek, .model = pro },
        .{ .vendor = .deepseek, .model = pro_snapshot },
        .{ .vendor = .deepseek, .model = pro_new },
    };
    const metadata: Metadata = .{ .gpa = undefined, .entries = &entries };

    try std.testing.expectEqual(
        @as(f64, 2),
        metadata.lookup(.deepseek, "deepseek-flash").?.price.?.input,
    );
    try std.testing.expectEqualStrings(
        "deepseek-v4.1-flash",
        metadata.lookup(.deepseek, "deepseek-flash").?.name(),
    );
    try std.testing.expectEqual(
        @as(f64, 5),
        metadata.lookup(.deepseek, "deepseek-pro").?.price.?.input,
    );
    try std.testing.expectEqual(
        @as(f64, 3),
        metadata.lookup(.deepseek, "deepseek-flash-vision-exp").?.price.?.input,
    );
    try std.testing.expectEqualStrings(
        "deepseek-v4-flash",
        metadata.lookup(.deepseek, "deepseek-v4-flash").?.name(),
    );
    try std.testing.expectEqualStrings(
        "deepseek-v4-pro",
        metadata.lookup(.deepseek, "deepseek-v4-pro").?.name(),
    );
    try std.testing.expectEqualStrings(
        "deepseek-v4-pro-0813",
        metadata.lookup(.deepseek, "deepseek-v4-pro-0813").?.name(),
    );
    try std.testing.expect(metadata.lookup(.deepseek, "deepseek-v5-flash") == null);
    try std.testing.expect(metadata.lookup(.openrouter, "deepseek-flash") == null);
}

const sample =
    \\{ "data": [
    \\  { "id": "anthropic/claude-opus-4.8", "context_length": 1000000,
    \\    "pricing": { "prompt": "0.000005", "completion": "0.000025",
    \\                 "input_cache_read": "0.0000005", "input_cache_write": "0.00000625",
    \\                 "input_cache_write_1h": "0.00001" },
    \\    "reasoning": { "mandatory": false, "default_enabled": false,
    \\                   "supported_efforts": ["max", "xhigh", "high", "medium", "low"] } },
    \\  { "id": "anthropic/claude-fable-5", "context_length": 1000000,
    \\    "pricing": { "prompt": "0.00001", "completion": "0.00005" },
    \\    "reasoning": { "mandatory": true,
    \\                   "supported_efforts": ["max", "xhigh", "high", "medium", "low"] } },
    \\  { "id": "openai/gpt-5.6-sol", "context_length": 1050000,
    \\    "pricing": { "prompt": "0.000002", "completion": "0.00001" },
    \\    "reasoning": { "mandatory": false,
    \\                   "supported_efforts": ["ultra", "max", "xhigh", "high", "medium", "low",
    \\                                         "minimal", "none"] } },
    \\  { "id": "openai/gpt-4o", "context_length": 128000,
    \\    "pricing": { "prompt": "0.0000025", "completion": "0.00001" } },
    \\  { "id": "openai/gpt-5.6-sol:batch", "context_length": 1050000,
    \\    "pricing": { "prompt": "0.000001", "completion": "0.000005" } },
    \\  { "id": "google/gemini-3.7-flash", "context_length": 1048576,
    \\    "pricing": { "prompt": "0.0000004", "completion": "0.000002",
    \\                 "input_cache_read": "0.0000001", "input_cache_write": "0.000001",
    \\                 "overrides": [
    \\                   { "utc_days": ["saturday", "sunday"],
    \\                     "prompt": "0.0000002", "completion": "0.000001" },
    \\                   { "min_prompt_tokens": 200000,
    \\                     "prompt": "0.0000008", "completion": "0.000004",
    \\                     "input_cache_read": "0.0000002" } ] },
    \\    "reasoning": { "supported_efforts": ["high", "medium", "low", "minimal"] } },
    \\  { "id": "x-ai/grok-4.6", "context_length": 500000,
    \\    "pricing": { "prompt": "0.000002", "completion": "0.000006",
    \\                 "input_cache_read": "0.0000005",
    \\                 "overrides": [
    \\                   { "min_prompt_tokens": 200000,
    \\                     "prompt": "0.000004", "completion": "0.000012",
    \\                     "input_cache_read": "0.000001" } ] },
    \\    "reasoning": { "mandatory": true,
    \\                   "supported_efforts": ["xhigh", "high", "medium", "low"] } },
    \\  { "id": "mistralai/mistral-large", "context_length": 128000,
    \\    "pricing": { "prompt": "0.000002", "completion": "0.000006" } },
    \\  { "id": "openai/free-one", "pricing": { "prompt": "0", "completion": "0" } }
    \\] }
;

test parse {
    var metadata = try parse(std.testing.allocator, sample);
    defer metadata.deinit();

    try std.testing.expectEqual(@as(usize, 7), countVendor(&metadata, .anthropic) +
        countVendor(&metadata, .openai) +
        countVendor(&metadata, .xai) +
        countVendor(&metadata, .google));
    try std.testing.expectEqual(@as(usize, 0), countVendor(&metadata, .openrouter));
    try std.testing.expect(metadata.lookup(.openai, "gpt-5.6-sol:batch") == null);

    const grok = metadata.lookup(.xai, "grok-4.6").?;
    try std.testing.expectEqual(@as(?u64, 500_000), grok.context_window);
    try std.testing.expectEqual(@as(f64, 2), grok.price.?.input);
    try std.testing.expectEqual(@as(f64, 0.5), grok.price.?.cache_read);
    const grok_tier = grok.price.?.long_context.?;
    try std.testing.expectEqual(@as(u64, 200_000), grok_tier.prompt_tokens_min);
    try std.testing.expectEqual(@as(f64, 4), grok_tier.input);
    try std.testing.expectEqual(@as(f64, 12), grok_tier.output);
    try std.testing.expectEqual(@as(f64, 1), grok_tier.cache_read);
    try std.testing.expectEqual(@as(f64, 0), grok_tier.cache_write);
    try std.testing.expect(grok.efforts.contains(.xhigh));
    try std.testing.expectEqual(core.Provider.Effort.xhigh, grok.fold(.max).?);
    try std.testing.expect(metadata.lookup(.openai, "grok-4.6") == null);

    const gemini = metadata.lookup(.google, "gemini-3.7-flash").?;
    try std.testing.expectEqual(@as(?u64, 1_048_576), gemini.context_window);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), gemini.price.?.input, 1e-9);
    const gemini_tier = gemini.price.?.long_context.?;
    try std.testing.expectEqual(@as(u64, 200_000), gemini_tier.prompt_tokens_min);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), gemini_tier.input, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4), gemini_tier.output, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), gemini_tier.cache_read, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1), gemini_tier.cache_write, 1e-9);
    try std.testing.expect(gemini.efforts.contains(.medium));
    try std.testing.expect(!gemini.efforts.contains(.max));
    try std.testing.expect(metadata.lookup(.anthropic, "gemini-3.7-flash") == null);

    const opus = metadata.lookup(.anthropic, "claude-opus-4-8").?;
    try std.testing.expectEqual(@as(?u64, 1_000_000), opus.context_window);
    try std.testing.expectEqual(@as(f64, 5), opus.price.?.input);
    try std.testing.expectEqual(@as(f64, 25), opus.price.?.output);
    try std.testing.expectEqual(@as(f64, 0.5), opus.price.?.cache_read);
    try std.testing.expectEqual(@as(f64, 6.25), opus.price.?.cache_write);
    try std.testing.expect(opus.price.?.long_context == null);
    try std.testing.expectEqual(Model.Thinking.supported, opus.thinking);
    try std.testing.expect(opus.efforts.contains(.max));
    const fable = metadata.lookup(.anthropic, "claude-fable-5").?;
    try std.testing.expectEqual(@as(f64, 0), fable.price.?.cache_read);
    try std.testing.expectEqual(Model.Thinking.supported, fable.thinking);

    const sol = metadata.lookup(.openai, "gpt-5.6-sol").?;
    try std.testing.expectEqual(Model.Thinking.supported, sol.thinking);
    try std.testing.expectEqual(@as(usize, 5), sol.efforts.count());
    try std.testing.expect(sol.efforts.contains(.low));
    try std.testing.expect(sol.efforts.contains(.max));

    const legacy = metadata.lookup(.openai, "gpt-4o").?;
    try std.testing.expectEqual(Model.Thinking.unsupported, legacy.thinking);
    try std.testing.expect(legacy.fold(.high) == null);

    try std.testing.expect(metadata.lookup(.openai, "free-one").?.price == null);
    try std.testing.expect(metadata.lookup(.openai, "does-not-exist") == null);
}

test "a malformed envelope reports bad metadata, and a malformed entry is skipped" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadMetadata, parse(gpa, "not json"));

    var metadata = try parse(gpa,
        \\{ "data": [
        \\  { "id": "anthropic/ok", "context_length": 7 },
        \\  { "id": "no-vendor-separator" },
        \\  { "context_length": 5 },
        \\  { "id": "anthropic/", "context_length": 5 },
        \\  "not-an-object"
        \\] }
    );
    defer metadata.deinit();
    try std.testing.expectEqual(@as(usize, 1), countVendor(&metadata, .anthropic));
    try std.testing.expectEqual(@as(?u64, 7), metadata.lookup(.anthropic, "ok").?.context_window);
}

test "a bad number states no value rather than a wrong one" {
    var metadata = try parse(std.testing.allocator,
        \\{ "data": [
        \\  { "id": "anthropic/zero-window", "context_length": 0,
        \\    "pricing": { "prompt": "0.000005", "completion": "not-a-number" } },
        \\  { "id": "anthropic/negative", "context_length": -1,
        \\    "pricing": { "prompt": "-0.1", "completion": "0.1" } },
        \\  { "id": "anthropic/unpriced", "context_length": 10, "pricing": {} },
        \\  { "id": "anthropic/huge", "context_length": 10,
        \\    "pricing": { "prompt": "1e303", "completion": "0.1" } },
        \\  { "id": "anthropic/bad-tier", "context_length": 10,
        \\    "pricing": { "prompt": "0.000001", "completion": "0.000005",
        \\                 "overrides": [ "not-an-object",
        \\                                { "min_prompt_tokens": 0, "prompt": "0.000002" },
        \\                                { "min_prompt_tokens": "200000", "prompt": "0.000002" },
        \\                                { "utc_days": ["sunday"], "prompt": "0.000002" } ] } }
        \\] }
    );
    defer metadata.deinit();

    const zero = metadata.lookup(.anthropic, "zero-window").?;
    try std.testing.expectEqual(@as(?u64, null), zero.context_window);
    try std.testing.expect(zero.price == null);
    try std.testing.expect(metadata.lookup(.anthropic, "negative").?.price == null);
    try std.testing.expect(metadata.lookup(.anthropic, "unpriced").?.price == null);
    try std.testing.expect(metadata.lookup(.anthropic, "huge").?.price == null);
    const bad_tier = metadata.lookup(.anthropic, "bad-tier").?;
    try std.testing.expectEqual(@as(f64, 1), bad_tier.price.?.input);
    try std.testing.expect(bad_tier.price.?.long_context == null);
}

test "a parameter list without tools denies tools on the vendor model" {
    var metadata = try parse(std.testing.allocator,
        \\{ "data": [
        \\  { "id": "openai/with-tools", "supported_parameters": ["tools", "temperature"] },
        \\  { "id": "openai/no-tools", "supported_parameters": ["temperature"] },
        \\  { "id": "openai/silent" }
        \\] }
    );
    defer metadata.deinit();
    try std.testing.expectEqual(
        Model.Tools.supported,
        metadata.lookup(.openai, "with-tools").?.tools,
    );
    try std.testing.expectEqual(
        Model.Tools.unsupported,
        metadata.lookup(.openai, "no-tools").?.tools,
    );
    try std.testing.expectEqual(Model.Tools.unknown, metadata.lookup(.openai, "silent").?.tools);
}

test "the OpenRouter list keeps its tool models in source order and drops variants" {
    var metadata = try parse(std.testing.allocator,
        \\{ "data": [
        \\  { "id": "openai/gpt-new", "supported_parameters": ["tools"],
        \\    "top_provider": { "max_completion_tokens": 128000 } },
        \\  { "id": "qwen/qwen-new", "supported_parameters": ["tools"] },
        \\  { "id": "openai/gpt-mid", "supported_parameters": ["tools"] },
        \\  { "id": "openai/gpt-old", "supported_parameters": ["tools"] },
        \\  { "id": "qwen/qwen-mid", "supported_parameters": ["tools"] },
        \\  { "id": "openai/gpt-no-tools", "supported_parameters": ["temperature"] },
        \\  { "id": "openai/gpt:free", "supported_parameters": ["tools"] },
        \\  { "id": "~openai/alias", "supported_parameters": ["tools"] },
        \\  { "id": "openrouter/auto", "supported_parameters": ["tools"] },
        \\  { "id": "openai/gpt/extra", "supported_parameters": ["tools"] },
        \\  { "id": "anthropic/claude", "supported_parameters": ["tools"] }
        \\] }
    );
    defer metadata.deinit();

    try std.testing.expectEqual(@as(usize, 6), countVendor(&metadata, .openrouter));
    var names: [6][]const u8 = undefined;
    var index: usize = 0;
    for (metadata.entries) |*entry| {
        if (entry.vendor != .openrouter) continue;
        names[index] = entry.model.name();
        index += 1;
    }
    try std.testing.expectEqualStrings("openai/gpt-new", names[0]);
    try std.testing.expectEqualStrings("qwen/qwen-new", names[1]);
    try std.testing.expectEqualStrings("openai/gpt-mid", names[2]);
    try std.testing.expectEqualStrings("openai/gpt-old", names[3]);
    try std.testing.expectEqualStrings("qwen/qwen-mid", names[4]);
    try std.testing.expectEqualStrings("anthropic/claude", names[5]);

    const newest = metadata.lookup(.openrouter, "openai/gpt-new").?;
    try std.testing.expectEqualStrings("gpt-new", newest.servedName());
    try std.testing.expect(newest.serves("gpt-new"));
    try std.testing.expect(newest.serves("openai/gpt-new"));
}

test "the output limit reaches the vendor metadata and never the OpenRouter list" {
    var metadata = try parse(std.testing.allocator,
        \\{ "data": [
        \\  { "id": "anthropic/claude-new", "supported_parameters": ["tools"],
        \\    "top_provider": { "max_completion_tokens": 128000 } },
        \\  { "id": "anthropic/claude-zero", "supported_parameters": ["tools"],
        \\    "top_provider": { "max_completion_tokens": 0 } }
        \\] }
    );
    defer metadata.deinit();
    const vendor = metadata.lookup(.anthropic, "claude-new").?;
    try std.testing.expectEqual(@as(?u32, 128_000), vendor.tokens_max);
    const routed = metadata.lookup(.openrouter, "anthropic/claude-new").?;
    try std.testing.expectEqual(@as(?u32, null), routed.tokens_max);
    const zero = metadata.lookup(.anthropic, "claude-zero").?;
    try std.testing.expectEqual(@as(?u32, null), zero.tokens_max);
}
