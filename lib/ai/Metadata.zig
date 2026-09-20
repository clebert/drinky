const std = @import("std");

const json = @import("json.zig");
const llm = @import("llm.zig");
const Model = @import("Model.zig");
const net = @import("net.zig");

const Metadata = @This();

const endpoint = "https://openrouter.ai/api/v1/models";
const user_agent = "drinky";
const body_bytes_max = 8 * 1024 * 1024;
const entry_count_max = 4096;
const tokens_per_million = 1_000_000.0;

gpa: std.mem.Allocator,
entries: []Entry,

pub const Entry = struct {
    provider: llm.Provider,
    model: Model,
};

const Author = struct {
    count: usize,
    first: usize,
};

pub fn deinit(self: *Metadata) void {
    self.gpa.free(self.entries);
}

pub fn fetch(gpa: std.mem.Allocator, io: std.Io, deadline: net.Deadline) !Metadata {
    var maybe_metadata: ?Metadata = null;
    deadline.call(io, request, .{ gpa, io, &maybe_metadata }) catch |err| {
        if (maybe_metadata) |*metadata| metadata.deinit();
        return err;
    };
    return maybe_metadata orelse error.MetadataRequestFailed;
}

fn request(gpa: std.mem.Allocator, io: std.Io, out: *?Metadata) !void {
    const uri = try std.Uri.parse(endpoint);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var metadata_request = try client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        .redirect_behavior = .not_allowed,
    });
    defer metadata_request.deinit();

    try metadata_request.sendBodiless();

    var redirect_buffer: [4096]u8 = undefined;
    var response = try metadata_request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.MetadataRequestFailed;

    const decompress_buffer = try net.decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [16384]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const body = try reader.allocRemaining(gpa, .limited(body_bytes_max));
    defer gpa.free(body);

    out.* = try parse(gpa, body);
}

pub fn parse(gpa: std.mem.Allocator, body: []const u8) !Metadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const object = json.object(parsed.value) orelse return error.BadMetadata;
    const listed = json.array(object.get("data")) orelse return error.BadMetadata;
    if (listed.items.len > entry_count_max) return error.BadMetadata;

    var vendor_entries: std.ArrayList(Entry) = .empty;
    errdefer vendor_entries.deinit(gpa);
    var openrouter_models: std.ArrayList(Model) = .empty;
    defer openrouter_models.deinit(gpa);
    for (listed.items) |value| {
        if (decodeVendor(value)) |entry| try vendor_entries.append(gpa, entry);
        if (decodeOpenRouter(value)) |model| try openrouter_models.append(gpa, model);
    }

    const grouped = try groupOpenRouter(gpa, openrouter_models.items);
    defer gpa.free(grouped);
    try vendor_entries.ensureUnusedCapacity(gpa, grouped.len);
    for (grouped) |model| vendor_entries.appendAssumeCapacity(.{
        .provider = .openrouter,
        .model = model,
    });
    return .{ .gpa = gpa, .entries = try vendor_entries.toOwnedSlice(gpa) };
}

pub fn lookup(self: *const Metadata, provider: llm.Provider, name: []const u8) ?Model {
    var buffer: [Model.name_bytes_max]u8 = undefined;
    const wanted = slug(name, &buffer);
    for (self.entries) |entry| {
        if (entry.provider != provider) continue;
        if (entry.model.sameName(wanted)) return entry.model;
    }
    if (provider == .deepseek) return self.lookupDeepseekFamily(wanted);
    return null;
}

fn lookupDeepseekFamily(self: *const Metadata, name: []const u8) ?Model {
    const wanted = deepseekFamily(name) orelse return null;
    if (wanted.major != null) return null;

    var best: ?Model = null;
    var best_rank: Rank = undefined;
    for (self.entries) |entry| {
        if (entry.provider != .deepseek) continue;
        const found = deepseekFamily(entry.model.name()) orelse continue;
        if (found.major == null) continue;
        if (!std.mem.eql(u8, found.family, wanted.family)) continue;
        const rank: Rank = .{
            .major = found.major.?,
            .minor = found.minor,
            .snapshot = found.snapshot,
        };
        if (best != null and !best_rank.less(rank)) continue;
        best = entry.model;
        best_rank = rank;
    }
    return best;
}

const Rank = struct {
    major: u32,
    minor: u32,
    snapshot: u32,

    fn less(self: Rank, other: Rank) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.snapshot < other.snapshot;
    }
};

const DeepseekFamily = struct {
    family: []const u8,
    major: ?u32,
    minor: u32,
    snapshot: u32,
};

fn deepseekFamily(name: []const u8) ?DeepseekFamily {
    const prefix = "deepseek-";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    if (rest.len == 0) return null;
    if (rest.len < 2 or rest[0] != 'v' or !isDigit(rest[1]))
        return .{ .family = rest, .major = null, .minor = 0, .snapshot = 0 };

    var index: usize = 1;
    const major = digits(rest, &index) orelse return null;
    var minor: u32 = 0;
    if (index < rest.len and rest[index] == '.') {
        index += 1;
        minor = digits(rest, &index) orelse return null;
    }
    if (index >= rest.len or rest[index] != '-') return null;
    const remainder = rest[index + 1 ..];
    if (remainder.len == 0) return null;
    const split = snapshotOf(remainder);
    return .{
        .family = split.family,
        .major = major,
        .minor = minor,
        .snapshot = split.snapshot,
    };
}

const Snapshot = struct {
    family: []const u8,
    snapshot: u32,
};

fn snapshotOf(family: []const u8) Snapshot {
    const dash = std.mem.lastIndexOfScalar(u8, family, '-') orelse
        return .{ .family = family, .snapshot = 0 };
    const tail = family[dash + 1 ..];
    if (tail.len == 0 or dash == 0) return .{ .family = family, .snapshot = 0 };
    for (tail) |byte| {
        if (!isDigit(byte)) return .{ .family = family, .snapshot = 0 };
    }
    const snapshot = std.fmt.parseInt(u32, tail, 10) catch
        return .{ .family = family, .snapshot = 0 };
    return .{ .family = family[0..dash], .snapshot = snapshot };
}

fn digits(text: []const u8, index: *usize) ?u32 {
    const start = index.*;
    while (index.* < text.len and isDigit(text[index.*])) index.* += 1;
    if (index.* == start) return null;
    return std.fmt.parseInt(u32, text[start..index.*], 10) catch null;
}

fn slug(name: []const u8, buffer: []u8) []const u8 {
    const trimmed = withoutDate(name);
    if (trimmed.len > buffer.len) return trimmed;
    @memcpy(buffer[0..trimmed.len], trimmed);
    const result = buffer[0..trimmed.len];
    if (result.len < 4) return result;
    for (1..result.len - 1) |index| {
        if (result[index] != '-') continue;
        if (!isDigit(result[index - 1])) continue;
        if (!isDigit(result[index + 1])) continue;
        if (index + 2 < result.len and isDigit(result[index + 2])) continue;
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
        if (!isDigit(byte)) return name;
    }
    return name[0 .. start - 1];
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn positive(value: ?std.json.Value) ?u64 {
    const found = json.integer(value) orelse return null;
    return if (found > 0) @intCast(found) else null;
}

pub fn authorOf(name: []const u8) []const u8 {
    const separator = std.mem.indexOfScalar(u8, name, '/') orelse return name;
    return name[0..separator];
}

fn decodeVendor(value: std.json.Value) ?Entry {
    const object = json.object(value) orelse return null;
    const id = json.string(object.get("id")) orelse return null;
    const separator = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    const provider = providerOf(id[0..separator]) orelse return null;
    const name = id[separator + 1 ..];
    if (std.mem.indexOfScalar(u8, name, ':') != null) return null;

    var model = Model.init(name) catch return null;
    fillShared(&model, object);
    return .{ .provider = provider, .model = model };
}

fn decodeOpenRouter(value: std.json.Value) ?Model {
    const object = json.object(value) orelse return null;
    const id = json.string(object.get("id")) orelse return null;
    if (std.mem.indexOfScalar(u8, id, ':') != null) return null;
    const separator = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    if (std.mem.indexOfScalar(u8, id[separator + 1 ..], '/') != null) return null;
    const vendor = id[0..separator];
    const name = id[separator + 1 ..];
    if (vendor.len == 0 or name.len == 0) return null;
    if (vendor[0] == '~') return null;
    if (std.mem.eql(u8, vendor, "openrouter")) return null;

    var model = Model.init(id) catch return null;
    model.serveAs(name) catch return null;
    fillShared(&model, object);
    if (model.tools != .supported) return null;
    if (json.object(object.get("top_provider"))) |top| {
        if (positive(top.get("max_completion_tokens"))) |limit|
            model.tokens_max = std.math.cast(u32, limit);
    }
    return model;
}

fn fillShared(model: *Model, object: std.json.ObjectMap) void {
    model.context_window = positive(object.get("context_length"));
    model.price = price(object.get("pricing"));
    reasoning(model, object.get("reasoning"));
    tools(model, object.get("supported_parameters"));
}

fn providerOf(vendor: []const u8) ?llm.Provider {
    if (std.mem.eql(u8, vendor, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, vendor, "openai")) return .openai;
    if (std.mem.eql(u8, vendor, "x-ai")) return .xai;
    if (std.mem.eql(u8, vendor, "google")) return .google;
    if (std.mem.eql(u8, vendor, "deepseek")) return .deepseek;
    return null;
}

fn groupOpenRouter(gpa: std.mem.Allocator, models: []const Model) ![]Model {
    var authors: std.ArrayList(Author) = .empty;
    defer authors.deinit(gpa);
    for (models, 0..) |*model, index| {
        const name = authorOf(model.name());
        for (authors.items) |*author| {
            if (std.mem.eql(u8, authorOf(models[author.first].name()), name)) {
                author.count += 1;
                break;
            }
        } else try authors.append(gpa, .{ .count = 1, .first = index });
    }

    const used = try gpa.alloc(bool, authors.items.len);
    defer gpa.free(used);
    @memset(used, false);

    const grouped = try gpa.alloc(Model, models.len);
    var out: usize = 0;
    for (0..authors.items.len) |_| {
        var best: ?usize = null;
        for (authors.items, 0..) |author, index| {
            if (used[index]) continue;
            if (best) |found| {
                const current = authors.items[found];
                const more = author.count > current.count;
                const earlier = author.count == current.count and author.first < current.first;
                if (more or earlier) best = index;
            } else best = index;
        }
        const chosen = best.?;
        used[chosen] = true;
        const author = authors.items[chosen];
        const name = authorOf(models[author.first].name());
        for (models) |*model| {
            if (!std.mem.eql(u8, authorOf(model.name()), name)) continue;
            grouped[out] = model.*;
            out += 1;
        }
    }
    std.debug.assert(out == models.len);
    return grouped;
}

fn price(value: ?std.json.Value) ?Model.Price {
    const object = json.object(value orelse return null) orelse return null;
    const input = rate(object.get("prompt")) orelse return null;
    const output = rate(object.get("completion")) orelse return null;
    if (input == 0 and output == 0) return null;
    var priced: Model.Price = .{
        .input = input,
        .output = output,
        .cache_read = rate(object.get("input_cache_read")) orelse 0,
        .cache_write = rate(object.get("input_cache_write")) orelse 0,
    };
    priced.long_context = longContext(&priced, object.get("overrides"));
    return priced;
}

fn longContext(standard: *const Model.Price, value: ?std.json.Value) ?Model.Price.LongContext {
    const listed = json.array(value orelse return null) orelse return null;
    for (listed.items) |item| {
        const object = json.object(item) orelse continue;
        const threshold = positive(object.get("min_prompt_tokens")) orelse continue;
        return .{
            .prompt_tokens_min = threshold,
            .input = rate(object.get("prompt")) orelse standard.input,
            .output = rate(object.get("completion")) orelse standard.output,
            .cache_read = rate(object.get("input_cache_read")) orelse standard.cache_read,
            .cache_write = rate(object.get("input_cache_write")) orelse standard.cache_write,
        };
    }
    return null;
}

fn rate(value: ?std.json.Value) ?f64 {
    const text = json.string(value orelse return null) orelse return null;
    const parsed = std.fmt.parseFloat(f64, text) catch return null;
    if (parsed < 0) return null;
    const scaled = parsed * tokens_per_million;
    return if (std.math.isFinite(scaled)) scaled else null;
}

fn reasoning(model: *Model, value: ?std.json.Value) void {
    const object = json.object(value orelse {
        model.thinking = .unsupported;
        return;
    }) orelse return;

    model.thinking = .supported;
    const levels = json.array(object.get("supported_efforts")) orelse return;
    for (levels.items) |level| {
        const name = json.string(level) orelse continue;
        model.addEffort(std.meta.stringToEnum(llm.Effort, name) orelse continue);
    }
}

fn tools(model: *Model, value: ?std.json.Value) void {
    const listed = json.array(value orelse return) orelse return;
    for (listed.items) |item| {
        const name = json.string(item) orelse continue;
        if (std.mem.eql(u8, name, "tools")) {
            model.tools = .supported;
            return;
        }
    }
    model.tools = .unsupported;
}

fn countProvider(self: *const Metadata, provider: llm.Provider) usize {
    var count: usize = 0;
    for (self.entries) |entry| {
        if (entry.provider == provider) count += 1;
    }
    return count;
}

test "an expired deadline refuses the metadata without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(error.Timeout, fetch(std.testing.allocator, io, expired));
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
        .{ .provider = .deepseek, .model = v4 },
        .{ .provider = .deepseek, .model = snapshot },
        .{ .provider = .deepseek, .model = v41 },
        .{ .provider = .deepseek, .model = vision },
        .{ .provider = .deepseek, .model = pro },
        .{ .provider = .deepseek, .model = pro_snapshot },
        .{ .provider = .deepseek, .model = pro_new },
    };
    const metadata: Metadata = .{ .gpa = undefined, .entries = &entries };

    try std.testing.expectEqual(@as(f64, 2), metadata.lookup(.deepseek, "deepseek-flash").?.price.?.input);
    try std.testing.expectEqualStrings(
        "deepseek-v4.1-flash",
        metadata.lookup(.deepseek, "deepseek-flash").?.name(),
    );
    try std.testing.expectEqual(@as(f64, 5), metadata.lookup(.deepseek, "deepseek-pro").?.price.?.input);
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

    try std.testing.expectEqual(@as(usize, 7), countProvider(&metadata, .anthropic) +
        countProvider(&metadata, .openai) +
        countProvider(&metadata, .xai) +
        countProvider(&metadata, .google));
    try std.testing.expectEqual(@as(usize, 0), countProvider(&metadata, .openrouter));
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
    try std.testing.expect(grok.offers(.xhigh));
    try std.testing.expectEqual(llm.Effort.xhigh, grok.reasoning(.max).named);
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
    try std.testing.expect(gemini.offers(.medium));
    try std.testing.expect(!gemini.offers(.max));
    try std.testing.expect(metadata.lookup(.anthropic, "gemini-3.7-flash") == null);

    const opus = metadata.lookup(.anthropic, "claude-opus-4-8").?;
    try std.testing.expectEqual(@as(?u64, 1_000_000), opus.context_window);
    try std.testing.expectEqual(@as(f64, 5), opus.price.?.input);
    try std.testing.expectEqual(@as(f64, 25), opus.price.?.output);
    try std.testing.expectEqual(@as(f64, 0.5), opus.price.?.cache_read);
    try std.testing.expectEqual(@as(f64, 6.25), opus.price.?.cache_write);
    try std.testing.expect(opus.price.?.long_context == null);
    try std.testing.expectEqual(Model.Thinking.supported, opus.thinking);
    try std.testing.expect(opus.offers(.max));
    const fable = metadata.lookup(.anthropic, "claude-fable-5").?;
    try std.testing.expectEqual(@as(f64, 0), fable.price.?.cache_read);
    try std.testing.expectEqual(Model.Thinking.supported, fable.thinking);

    const sol = metadata.lookup(.openai, "gpt-5.6-sol").?;
    try std.testing.expectEqual(Model.Thinking.supported, sol.thinking);
    try std.testing.expectEqual(@as(usize, 5), sol.efforts.count());
    try std.testing.expect(sol.offers(.low));
    try std.testing.expect(sol.offers(.max));

    const legacy = metadata.lookup(.openai, "gpt-4o").?;
    try std.testing.expectEqual(Model.Thinking.unsupported, legacy.thinking);
    try std.testing.expect(legacy.reasoning(.high) == .omitted);

    try std.testing.expect(metadata.lookup(.openai, "free-one").?.price == null);
    try std.testing.expect(metadata.lookup(.openai, "does-not-exist") == null);
}

test "a malformed envelope is rejected and a malformed entry is skipped" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadMetadata, parse(gpa, "{}"));
    try std.testing.expectError(error.BadMetadata, parse(gpa, "[]"));
    try std.testing.expectError(error.BadMetadata, parse(gpa, "{\"data\":{}}"));

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
    try std.testing.expectEqual(@as(usize, 1), countProvider(&metadata, .anthropic));
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

test "parse bounds the entry count" {
    const gpa = std.testing.allocator;
    const at_max = "{\"data\":[{}" ++ (",{}" ** (entry_count_max - 1)) ++ "]}";
    var metadata = try parse(gpa, at_max);
    metadata.deinit();
    const over = "{\"data\":[{}" ++ (",{}" ** entry_count_max) ++ "]}";
    try std.testing.expectError(error.BadMetadata, parse(gpa, over));
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

test "the OpenRouter list keeps tool models, groups authors, and drops variants" {
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

    try std.testing.expectEqual(@as(usize, 6), countProvider(&metadata, .openrouter));
    var names: [6][]const u8 = undefined;
    var index: usize = 0;
    for (metadata.entries) |*entry| {
        if (entry.provider != .openrouter) continue;
        names[index] = entry.model.name();
        index += 1;
    }
    try std.testing.expectEqualStrings("openai/gpt-new", names[0]);
    try std.testing.expectEqualStrings("openai/gpt-mid", names[1]);
    try std.testing.expectEqualStrings("openai/gpt-old", names[2]);
    try std.testing.expectEqualStrings("qwen/qwen-new", names[3]);
    try std.testing.expectEqualStrings("qwen/qwen-mid", names[4]);
    try std.testing.expectEqualStrings("anthropic/claude", names[5]);

    const newest = metadata.lookup(.openrouter, "openai/gpt-new").?;
    try std.testing.expectEqualStrings("gpt-new", newest.servedName());
    try std.testing.expectEqual(@as(?u32, 128_000), newest.tokens_max);
    try std.testing.expect(newest.serves("gpt-new"));
    try std.testing.expect(newest.serves("openai/gpt-new"));
}

test "an author with the same count follows the first model of that author" {
    var metadata = try parse(std.testing.allocator,
        \\{ "data": [
        \\  { "id": "beta/one", "supported_parameters": ["tools"] },
        \\  { "id": "alpha/one", "supported_parameters": ["tools"] },
        \\  { "id": "beta/two", "supported_parameters": ["tools"] },
        \\  { "id": "alpha/two", "supported_parameters": ["tools"] }
        \\] }
    );
    defer metadata.deinit();
    var names: [4][]const u8 = undefined;
    var index: usize = 0;
    for (metadata.entries) |*entry| {
        if (entry.provider != .openrouter) continue;
        names[index] = entry.model.name();
        index += 1;
    }
    try std.testing.expectEqualStrings("beta/one", names[0]);
    try std.testing.expectEqualStrings("beta/two", names[1]);
    try std.testing.expectEqualStrings("alpha/one", names[2]);
    try std.testing.expectEqualStrings("alpha/two", names[3]);
}
