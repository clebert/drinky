//! Account-aware model limits from the ChatGPT Codex catalog. The catalog is a
//! best-effort supplement to pith's compiled model table: this module fetches and
//! decodes it, while the account registry decides which known models to overlay.

const std = @import("std");

const Auth = @import("Auth.zig");
const net = @import("../net.zig");

/// Numeric semantic version used by the Codex catalog for client filtering.
const client_version = "0.0.0";

const endpoint = "https://chatgpt.com/backend-api/codex/models?client_version=" ++ client_version;
const originator = "pith";
const body_bytes_max = 2 * 1024 * 1024;
const model_count_max = 1024;
const effective_context_window_percent_default = 95;

const ModelCatalog = @This();

parsed: std.json.Parsed(std.json.Value),

const Metadata = struct {
    context_window: u64,
    max_context_window: ?u64,
    effective_context_window_percent: ?u8,
};

pub fn deinit(self: *ModelCatalog) void {
    self.parsed.deinit();
}

/// Fetch and decode the catalog using the current OAuth token and account id.
/// Errors contain no server body, token, or account identifier.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    timeouts: net.Timeouts,
    auth: *Auth,
) !ModelCatalog {
    var maybe_catalog: ?ModelCatalog = null;
    net.withTimeout(io, timeouts.connect_ms, fetchInto, .{
        gpa,
        io,
        auth,
        &maybe_catalog,
    }) catch |err| {
        if (maybe_catalog) |*catalog| catalog.deinit();
        return err;
    };
    return maybe_catalog orelse error.ModelCatalogRequestFailed;
}

fn fetchInto(
    gpa: std.mem.Allocator,
    io: std.Io,
    auth: *Auth,
    out: *?ModelCatalog,
) !void {
    out.* = try request(gpa, io, try auth.accessToken(), auth.accountId());
}

fn request(
    gpa: std.mem.Allocator,
    io: std.Io,
    access_token: []const u8,
    account_id: []const u8,
) !ModelCatalog {
    if (!validHeaderValue(access_token) or !validHeaderValue(account_id))
        return error.BadModelCatalogCredentials;

    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{access_token});
    defer gpa.free(authorization);

    const uri = try std.Uri.parse(endpoint);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "chatgpt-account-id", .value = account_id },
        .{ .name = "originator", .value = originator },
    };
    var catalog_request = try client.request(.GET, uri, .{
        .headers = .{
            .authorization = .{ .override = authorization },
            .user_agent = .{ .override = originator },
        },
        .extra_headers = &extra_headers,
        .redirect_behavior = .not_allowed,
    });
    defer catalog_request.deinit();

    try catalog_request.sendBodiless();

    var redirect_buffer: [4096]u8 = undefined;
    var response = try catalog_request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.ModelCatalogRequestFailed;

    const decompress_buffer = try decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [16384]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const body = try reader.allocRemaining(gpa, .limited(body_bytes_max));
    defer gpa.free(body);

    return parse(gpa, body);
}

fn validHeaderValue(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, "\r\n") == null;
}

fn decompressBuffer(gpa: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .gzip, .deflate => gpa.alloc(u8, std.compress.flate.max_window_len),
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedContentEncoding,
    };
}

/// Decode a complete catalog response. Individual malformed entries remain
/// ignorable; a malformed envelope rejects the catalog as a whole.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) !ModelCatalog {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    errdefer parsed.deinit();

    const object = asObject(&parsed.value) orelse return error.BadModelCatalog;
    const entries = asArray(object.getPtr("models")) orelse return error.BadModelCatalog;
    if (entries.items.len > model_count_max) return error.BadModelCatalog;

    return .{ .parsed = parsed };
}

/// The raw context window for `slug`, preferring `context_window` and falling
/// back to `max_context_window` exactly when the former is absent. Null means the
/// entry is absent or its selected value is invalid.
pub fn contextWindow(self: *const ModelCatalog, slug: []const u8) ?u64 {
    const decoded = self.metadata(slug) orelse return null;
    return decoded.context_window;
}

fn metadata(self: *const ModelCatalog, slug: []const u8) ?Metadata {
    const object = asObject(&self.parsed.value) orelse unreachable;
    const entries = asArray(object.getPtr("models")) orelse unreachable;
    for (entries.items) |*entry| {
        const model = asObject(entry) orelse continue;
        const found_slug = asString(model.getPtr("slug")) orelse continue;
        if (!std.mem.eql(u8, found_slug, slug)) continue;

        const max_context_window = positiveInt(model.getPtr("max_context_window"));
        const maybe_context_window = model.getPtr("context_window");
        const context_window = if (maybe_context_window) |value| switch (value.*) {
            .null => max_context_window orelse return null,
            else => positiveInt(value) orelse return null,
        } else max_context_window orelse return null;
        const effective_context_window_percent: ?u8 =
            if (model.getPtr("effective_context_window_percent")) |value|
                percent(value)
            else
                effective_context_window_percent_default;
        return .{
            .context_window = context_window,
            .max_context_window = max_context_window,
            .effective_context_window_percent = effective_context_window_percent,
        };
    }
    return null;
}

fn asObject(value: *const std.json.Value) ?*const std.json.ObjectMap {
    return switch (value.*) {
        .object => |*object| object,
        else => null,
    };
}

fn asArray(maybe_value: ?*const std.json.Value) ?*const std.json.Array {
    const value = maybe_value orelse return null;
    return switch (value.*) {
        .array => |*array| array,
        else => null,
    };
}

fn asString(maybe_value: ?*const std.json.Value) ?[]const u8 {
    const value = maybe_value orelse return null;
    return switch (value.*) {
        .string => |string| string,
        else => null,
    };
}

fn positiveInt(maybe_value: ?*const std.json.Value) ?u64 {
    const value = maybe_value orelse return null;
    return switch (value.*) {
        .integer => |integer| if (integer > 0) @intCast(integer) else null,
        else => null,
    };
}

fn percent(value: *const std.json.Value) ?u8 {
    return switch (value.*) {
        .integer => |integer| if (integer > 0 and integer <= 100) @intCast(integer) else null,
        else => null,
    };
}

test "credential header values cannot inject another header" {
    try std.testing.expect(validHeaderValue("token.account"));
    try std.testing.expect(!validHeaderValue(""));
    try std.testing.expect(!validHeaderValue("token\r\nleaked: value"));
}

test "parse decodes raw, maximum, and effective context metadata" {
    var catalog = try parse(std.testing.allocator,
        \\{ "models": [
        \\  { "slug": "gpt-5.6-sol", "context_window": 372000,
        \\    "max_context_window": 400000, "effective_context_window_percent": 95 },
        \\  { "slug": "gpt-5.6-terra", "context_window": null,
        \\    "max_context_window": 300000 }
        \\] }
    );
    defer catalog.deinit();

    const sol = catalog.metadata("gpt-5.6-sol").?;
    try std.testing.expectEqual(@as(u64, 372_000), sol.context_window);
    try std.testing.expectEqual(@as(?u64, 400_000), sol.max_context_window);
    try std.testing.expectEqual(@as(?u8, 95), sol.effective_context_window_percent);

    const terra = catalog.metadata("gpt-5.6-terra").?;
    try std.testing.expectEqual(@as(u64, 300_000), terra.context_window);
    try std.testing.expectEqual(@as(?u8, 95), terra.effective_context_window_percent);
}

test "missing and malformed model fields do not produce context windows" {
    var catalog = try parse(std.testing.allocator,
        \\{ "models": [
        \\  { "slug": "missing" },
        \\  { "slug": "zero", "context_window": 0, "max_context_window": 10 },
        \\  { "slug": "string", "context_window": "372000" },
        \\  { "context_window": 123 },
        \\  { "slug": "valid", "context_window": 123,
        \\    "effective_context_window_percent": 101 }
        \\] }
    );
    defer catalog.deinit();

    try std.testing.expectEqual(@as(?u64, null), catalog.contextWindow("missing"));
    try std.testing.expectEqual(@as(?u64, null), catalog.contextWindow("zero"));
    try std.testing.expectEqual(@as(?u64, null), catalog.contextWindow("string"));
    try std.testing.expectEqual(@as(?u64, null), catalog.contextWindow("unknown"));
    try std.testing.expectEqual(@as(u64, 123), catalog.contextWindow("valid").?);
    try std.testing.expectEqual(
        @as(?u8, null),
        catalog.metadata("valid").?.effective_context_window_percent,
    );
}

test "malformed catalog envelopes are rejected" {
    try std.testing.expectError(error.BadModelCatalog, parse(std.testing.allocator, "{}"));
    try std.testing.expectError(error.BadModelCatalog, parse(std.testing.allocator, "[]"));
    try std.testing.expectError(
        error.BadModelCatalog,
        parse(std.testing.allocator, "{\"models\":{}}"),
    );
}

test "parse bounds the catalog's model count" {
    const at_max = "{\"models\":[{}" ++ (",{}" ** (model_count_max - 1)) ++ "]}";
    var catalog = try parse(std.testing.allocator, at_max);
    catalog.deinit();
    const over = "{\"models\":[{}" ++ (",{}" ** model_count_max) ++ "]}";
    try std.testing.expectError(error.BadModelCatalog, parse(std.testing.allocator, over));
}
