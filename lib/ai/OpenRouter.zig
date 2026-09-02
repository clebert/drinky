//! The public model metadata of OpenRouter, which needs no credential. It is
//! the only source that states a price, so Drinky reads it for every account and
//! merges it under whatever the vendor itself stated.
//!
//! `GET https://openrouter.ai/api/v1/models` answers with every model of every
//! vendor. Drinky keeps a normalized subset: the vendors it reaches, and per
//! model the context window, the effort levels, the thinking state, and the four
//! rates. The endpoints of a model are deliberately ignored. They price service
//! tiers, regions, and resellers that Drinky never calls, while the top-level
//! `pricing` object states the standard rate of the vendor itself.

const std = @import("std");

const json = @import("json.zig");
const llm = @import("llm.zig");
const Model = @import("Model.zig");
const net = @import("net.zig");

const OpenRouter = @This();

const endpoint = "https://openrouter.ai/api/v1/models";
const user_agent = "drinky";
const body_bytes_max = 8 * 1024 * 1024;
const entry_count_max = 4096;
/// Rates arrive in dollars per token and Drinky states them per million.
const million = 1_000_000.0;

gpa: std.mem.Allocator,
entries: []Entry,

/// One model of one vendor, as the aggregator states it. The name is the
/// aggregator spelling, which is not always the id the vendor answers to, so a
/// lookup normalizes before it compares.
pub const Entry = struct {
    provider: llm.Provider,
    model: Model,
};

pub fn deinit(self: *OpenRouter) void {
    self.gpa.free(self.entries);
}

/// Fetch and decode the public list. The request carries no credential. The
/// `deadline` bounds it, and the account list before it shares that window.
pub fn fetch(gpa: std.mem.Allocator, io: std.Io, deadline: net.Deadline) !OpenRouter {
    var maybe_metadata: ?OpenRouter = null;
    deadline.call(io, request, .{ gpa, io, &maybe_metadata }) catch |err| {
        if (maybe_metadata) |*metadata| metadata.deinit();
        return err;
    };
    return maybe_metadata orelse error.MetadataRequestFailed;
}

fn request(gpa: std.mem.Allocator, io: std.Io, out: *?OpenRouter) !void {
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

/// Decode a complete response into the normalized subset. A malformed envelope
/// rejects the whole body. A malformed entry is skipped, because one bad model
/// must not cost the user every other price.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) !OpenRouter {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const object = json.object(parsed.value) orelse return error.BadMetadata;
    const listed = json.array(object.get("data")) orelse return error.BadMetadata;
    if (listed.items.len > entry_count_max) return error.BadMetadata;

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    for (listed.items) |value| {
        const entry = decode(value) orelse continue;
        try entries.append(gpa, entry);
    }
    return .{ .gpa = gpa, .entries = try entries.toOwnedSlice(gpa) };
}

/// The metadata of `name` under `provider`, or null when the list holds no such
/// model. The vendor id normalizes to the aggregator spelling first.
pub fn lookup(self: *const OpenRouter, provider: llm.Provider, name: []const u8) ?Model {
    var buffer: [Model.name_bytes_max]u8 = undefined;
    const wanted = slug(name, &buffer);
    for (self.entries) |entry| {
        if (entry.provider != provider) continue;
        if (entry.model.sameName(wanted)) return entry.model;
    }
    return null;
}

/// The aggregator spelling of a vendor id. The aggregator writes a version with
/// a dot where the vendor writes a dash, and it names no dated snapshot, so
/// `claude-opus-4-8` becomes `claude-opus-4.8` and a trailing date goes. An id
/// that needs no change comes back unchanged.
fn slug(name: []const u8, buffer: []u8) []const u8 {
    const trimmed = withoutDate(name);
    if (trimmed.len > buffer.len) return trimmed;
    @memcpy(buffer[0..trimmed.len], trimmed);
    const result = buffer[0..trimmed.len];
    // A version reads as `-<digit>-<digit>`. One pass covers every version in
    // one id, because the scan never revisits a byte it rewrote.
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

/// `name` without a trailing snapshot date, which is eight digits behind a dash.
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

/// A count that states a limit, or null when it is absent or not one. Zero
/// states no limit, so it reads as absent.
fn positive(value: ?std.json.Value) ?u64 {
    const found = json.integer(value) orelse return null;
    return if (found > 0) @intCast(found) else null;
}

/// One listed model, or null when it names no vendor Drinky reaches, when its
/// id is unusable, or when it is a variant that no vendor answers to. A `:`
/// marks such a variant, as in `:batch` and `:free`.
fn decode(value: std.json.Value) ?Entry {
    const object = json.object(value) orelse return null;
    const id = json.string(object.get("id")) orelse return null;
    const separator = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    const provider = providerOf(id[0..separator]) orelse return null;
    const name = id[separator + 1 ..];
    if (std.mem.indexOfScalar(u8, name, ':') != null) return null;

    var model = Model.init(name) catch return null;
    model.context_window = positive(object.get("context_length"));
    model.price = price(object.get("pricing"));
    reasoning(&model, object.get("reasoning"));
    return .{ .provider = provider, .model = model };
}

fn providerOf(vendor: []const u8) ?llm.Provider {
    if (std.mem.eql(u8, vendor, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, vendor, "openai")) return .openai;
    return null;
}

/// The four rates Drinky charges against, converted from dollars per token. A
/// model priced at zero is a free endpoint rather than a rate, so it states no
/// price. A missing input or output rate rejects the whole price, because a
/// half-priced model reports a cost that is wrong rather than absent.
fn price(value: ?std.json.Value) ?Model.Price {
    const object = json.object(value orelse return null) orelse return null;
    const input = rate(object.get("prompt")) orelse return null;
    const output = rate(object.get("completion")) orelse return null;
    if (input == 0 and output == 0) return null;
    return .{
        .input = input,
        .output = output,
        .cache_read = rate(object.get("input_cache_read")) orelse 0,
        // The 1-hour variant is deliberately ignored: Drinky writes 5-minute
        // ephemeral entries alone.
        .cache_write = rate(object.get("input_cache_write")) orelse 0,
    };
}

/// One rate, which arrives as a decimal string of dollars per token. The guard
/// tests the scaled number, because a finite rate can reach infinity at that
/// scale, and such a value prints as a cost and writes as invalid JSON.
fn rate(value: ?std.json.Value) ?f64 {
    const text = json.string(value orelse return null) orelse return null;
    const parsed = std.fmt.parseFloat(f64, text) catch return null;
    if (parsed < 0) return null;
    const scaled = parsed * million;
    return if (std.math.isFinite(scaled)) scaled else null;
}

/// The effort levels and the thinking state. A model with a reasoning object
/// reasons, and a model with none never reasons.
fn reasoning(model: *Model, value: ?std.json.Value) void {
    const object = json.object(value orelse {
        model.thinking = .unsupported;
        return;
    }) orelse return;

    model.thinking = .supported;
    const levels = json.array(object.get("supported_efforts")) orelse return;
    for (levels.items) |level| {
        const name = json.string(level) orelse continue;
        // A name the ladder does not hold drops. `none` is one such name.
        model.addEffort(std.meta.stringToEnum(llm.Effort, name) orelse continue);
    }
}

// The metadata request follows the account list inside one window. A window
// that the list spent refuses the request before it opens a socket.
test "an expired deadline refuses the metadata without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(error.Timeout, fetch(std.testing.allocator, io, expired));
}

test slug {
    var buffer: [Model.name_bytes_max]u8 = undefined;
    // A dashed version takes the dot of the aggregator.
    try std.testing.expectEqualStrings("claude-opus-4.8", slug("claude-opus-4-8", &buffer));
    try std.testing.expectEqualStrings("claude-sonnet-4.6", slug("claude-sonnet-4-6", &buffer));
    // A dated id drops its snapshot and then takes the dot.
    try std.testing.expectEqualStrings("claude-opus-4.5", slug("claude-opus-4-5-20251101", &buffer));
    try std.testing.expectEqualStrings(
        "claude-haiku-4.5",
        slug("claude-haiku-4-5-20251001", &buffer),
    );
    // An id that already reads like the aggregator stays as it is.
    try std.testing.expectEqualStrings("claude-opus-5", slug("claude-opus-5", &buffer));
    try std.testing.expectEqualStrings("gpt-5.6-sol", slug("gpt-5.6-sol", &buffer));
    try std.testing.expectEqualStrings("gpt-5.6-luna", slug("gpt-5.6-luna", &buffer));
    // A multi-digit group is a date-like number rather than a version.
    try std.testing.expectEqualStrings("model-4-56", slug("model-4-56", &buffer));
    // Only eight trailing digits behind a dash read as a date.
    try std.testing.expectEqualStrings("model-2025110", slug("model-2025110", &buffer));
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
    \\    "pricing": { "prompt": "0.0000004", "completion": "0.000002" } },
    \\  { "id": "openai/free-one", "pricing": { "prompt": "0", "completion": "0" } }
    \\] }
;

test parse {
    var metadata = try parse(std.testing.allocator, sample);
    defer metadata.deinit();

    // A vendor Drinky does not reach, and a variant that no vendor answers to,
    // both stay out of the subset.
    try std.testing.expectEqual(@as(usize, 5), metadata.entries.len);
    try std.testing.expect(metadata.lookup(.openai, "gpt-5.6-sol:batch") == null);

    // The vendor id normalizes onto the aggregator spelling.
    const opus = metadata.lookup(.anthropic, "claude-opus-4-8").?;
    try std.testing.expectEqual(@as(?u64, 1_000_000), opus.context_window);
    try std.testing.expectEqual(@as(f64, 5), opus.price.?.input);
    try std.testing.expectEqual(@as(f64, 25), opus.price.?.output);
    try std.testing.expectEqual(@as(f64, 0.5), opus.price.?.cache_read);
    // The 5-minute write rate wins, because Drinky writes no 1-hour entry.
    try std.testing.expectEqual(@as(f64, 6.25), opus.price.?.cache_write);
    try std.testing.expectEqual(Model.Thinking.supported, opus.thinking);
    try std.testing.expect(opus.offers(.max));
    // A model with a price but no cache rates charges nothing for a cache hit.
    const fable = metadata.lookup(.anthropic, "claude-fable-5").?;
    try std.testing.expectEqual(@as(f64, 0), fable.price.?.cache_read);
    // Whether the reasoning is mandatory changes nothing, because Drinky never
    // stops it.
    try std.testing.expectEqual(Model.Thinking.supported, fable.thinking);

    // A name outside the ladder, such as `ultra`, `minimal`, or `none`, drops,
    // so the model names the five rungs alone.
    const sol = metadata.lookup(.openai, "gpt-5.6-sol").?;
    try std.testing.expectEqual(Model.Thinking.supported, sol.thinking);
    try std.testing.expectEqual(@as(usize, 5), sol.efforts.count());
    try std.testing.expect(sol.offers(.low));
    try std.testing.expect(sol.offers(.max));

    // A model with no reasoning object never reasons, so it offers no level.
    const legacy = metadata.lookup(.openai, "gpt-4o").?;
    try std.testing.expectEqual(Model.Thinking.unsupported, legacy.thinking);
    try std.testing.expect(legacy.reasoning(.high) == .omitted);

    // A free endpoint states no rate, so it reports no price at all.
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
    try std.testing.expectEqual(@as(usize, 1), metadata.entries.len);
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
        \\    "pricing": { "prompt": "1e303", "completion": "0.1" } }
        \\] }
    );
    defer metadata.deinit();

    const zero = metadata.lookup(.anthropic, "zero-window").?;
    try std.testing.expectEqual(@as(?u64, null), zero.context_window);
    try std.testing.expect(zero.price == null);
    try std.testing.expect(metadata.lookup(.anthropic, "negative").?.price == null);
    try std.testing.expect(metadata.lookup(.anthropic, "unpriced").?.price == null);
    // A rate that the scale takes past the range of the type states no value,
    // because an infinite number prints as a cost and writes as invalid JSON.
    try std.testing.expect(metadata.lookup(.anthropic, "huge").?.price == null);
}

test "parse bounds the entry count" {
    const gpa = std.testing.allocator;
    const at_max = "{\"data\":[{}" ++ (",{}" ** (entry_count_max - 1)) ++ "]}";
    var metadata = try parse(gpa, at_max);
    metadata.deinit();
    const over = "{\"data\":[{}" ++ (",{}" ** entry_count_max) ++ "]}";
    try std.testing.expectError(error.BadMetadata, parse(gpa, over));
}
