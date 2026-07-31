//! Account-aware model limits from the ChatGPT Codex catalog. The catalog is a
//! best-effort supplement to pith's compiled model table. This module fetches
//! and decodes it, while the account registry decides which known models to
//! overlay.

const std = @import("std");

const Auth = @import("Auth.zig");
const json = @import("../json.zig");
const net = @import("../net.zig");

/// The numeric semantic version the Codex catalog uses for client filtering.
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

/// Fetch and decode the catalog with the current OAuth token and account id.
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
    out.* = try request(gpa, io, .{
        .access_token = try auth.accessToken(),
        .account_id = auth.accountId(),
    });
}

const Credentials = struct { access_token: []const u8, account_id: []const u8 };

fn request(gpa: std.mem.Allocator, io: std.Io, credentials: Credentials) !ModelCatalog {
    if (!net.validHeaderValue(credentials.access_token) or
        !net.validHeaderValue(credentials.account_id))
    {
        return error.BadModelCatalogCredentials;
    }

    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{credentials.access_token});
    defer gpa.free(authorization);

    const uri = try std.Uri.parse(endpoint);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "chatgpt-account-id", .value = credentials.account_id },
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

    const decompress_buffer = try net.decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [16384]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const body = try reader.allocRemaining(gpa, .limited(body_bytes_max));
    defer gpa.free(body);

    return parse(gpa, body);
}

/// Decode a complete catalog response. Individual malformed entries remain
/// ignorable. A malformed envelope rejects the catalog as a whole.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) !ModelCatalog {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    errdefer parsed.deinit();

    const object = json.object(parsed.value) orelse return error.BadModelCatalog;
    const entries = json.array(object.get("models")) orelse return error.BadModelCatalog;
    if (entries.items.len > model_count_max) return error.BadModelCatalog;

    return .{ .parsed = parsed };
}

/// The raw context window for `slug`. The lookup prefers `context_window` and
/// falls back to `max_context_window` exactly when `context_window` is absent.
/// Null means the entry is absent or its selected value is invalid.
pub fn contextWindow(self: *const ModelCatalog, slug: []const u8) ?u64 {
    const decoded = self.metadata(slug) orelse return null;
    return decoded.context_window;
}

fn metadata(self: *const ModelCatalog, slug: []const u8) ?Metadata {
    const object = json.object(self.parsed.value) orelse unreachable;
    const entries = json.array(object.get("models")) orelse unreachable;
    for (entries.items) |entry| {
        const model = json.object(entry) orelse continue;
        const found_slug = json.string(model.get("slug")) orelse continue;
        if (!std.mem.eql(u8, found_slug, slug)) continue;

        const max_context_window = positiveInt(model.get("max_context_window"));
        const context_window = if (model.get("context_window")) |value| switch (value) {
            .null => max_context_window orelse return null,
            else => positiveInt(value) orelse return null,
        } else max_context_window orelse return null;
        const effective_context_window_percent: ?u8 =
            if (model.get("effective_context_window_percent")) |value|
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

fn positiveInt(value: ?std.json.Value) ?u64 {
    const found = json.integer(value) orelse return null;
    return if (found > 0) @intCast(found) else null;
}

fn percent(value: std.json.Value) ?u8 {
    const found = json.integer(value) orelse return null;
    return if (found > 0 and found <= 100) @intCast(found) else null;
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
