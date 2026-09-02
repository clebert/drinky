//! The model list of the Google publisher on Vertex AI. The list names every
//! publisher model of the location, so the decoder keeps the Gemini models of
//! the generation Drinky serves. An entry states the name and nothing else
//! Drinky reads, so `Catalog.merge` fills the facts from the public metadata.

const std = @import("std");

const json = @import("../json.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");
const Transport = @import("Transport.zig");

const body_bytes_max = 2 * 1024 * 1024;
const entry_count_max = 1024;
/// The page size the request asks for.
const page_size = 100;
/// The page cap. The list holds a few hundred models at most, so a server that
/// keeps reporting more pages is one Drinky stops following.
const pages_max = 8;
const name_prefix = "publishers/google/models/";
const id_prefix = "gemini-";
/// The first generation Drinky serves. Older ones take another thinking control
/// and stay out, whatever location lists them.
const generation_min = 3;

pub const Options = struct {
    access_token: []const u8,
    location: Transport.Location,
};

/// One decoded page of the list.
pub const Page = struct {
    models: []Model,
    /// The token of the next page, owned, or null on the last page.
    next_page_token: ?[]u8,

    pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
        gpa.free(self.models);
        if (self.next_page_token) |token| gpa.free(token);
    }
};

/// Every Gemini model the publisher lists, in list order. The caller owns the
/// result. One `deadline` bounds every page.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    options: *const Options,
) ![]Model {
    return fetchWith(gpa, io, deadline, options, fetchPage);
}

/// `fetch` over the page request `pageFn`. A test hands in a double, so it
/// reaches the paging without a socket.
fn fetchWith(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    options: *const Options,
    comptime pageFn: anytype,
) ![]Model {
    var collected: std.ArrayList(Model) = .empty;
    errdefer collected.deinit(gpa);

    var page_token: ?[]u8 = null;
    defer if (page_token) |token| gpa.free(token);
    for (0..pages_max) |_| {
        var page = try pageFn(gpa, io, deadline, options, page_token);
        defer page.deinit(gpa);
        try collected.appendSlice(gpa, page.models);
        if (collected.items.len > entry_count_max) return error.BadModelList;
        if (page_token) |token| gpa.free(token);
        page_token = page.next_page_token;
        page.next_page_token = null;
        if (page_token == null) break;
    }
    return collected.toOwnedSlice(gpa);
}

fn fetchPage(
    gpa: std.mem.Allocator,
    io: std.Io,
    deadline: net.Deadline,
    options: *const Options,
    page_token: ?[]const u8,
) !Page {
    var maybe_page: ?Page = null;
    deadline.call(io, request, .{ gpa, io, options, page_token, &maybe_page }) catch |err| {
        if (maybe_page) |*page| page.deinit(gpa);
        return err;
    };
    return maybe_page orelse error.ModelListRequestFailed;
}

fn request(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    page_token: ?[]const u8,
    out: *?Page,
) !void {
    if (!net.validHeaderValue(options.access_token)) return error.BadModelListCredentials;

    const url = try pageUrl(gpa, options.location, page_token);
    defer gpa.free(url);
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{options.access_token});
    defer gpa.free(authorization);

    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var list_request = try client.request(.GET, uri, .{
        .headers = .{ .authorization = .{ .override = authorization } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        .redirect_behavior = .not_allowed,
    });
    defer list_request.deinit();

    try list_request.sendBodiless();

    var redirect_buffer: [4096]u8 = undefined;
    var response = try list_request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.ModelListRequestFailed;

    const decompress_buffer = try net.decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [16384]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const body = try reader.allocRemaining(gpa, .limited(body_bytes_max));
    defer gpa.free(body);

    out.* = try parse(gpa, body);
}

/// The list URL of one page. The token is opaque, so it travels percent-encoded.
fn pageUrl(
    gpa: std.mem.Allocator,
    location: Transport.Location,
    page_token: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.print(
        "https://{s}/v1beta1/publishers/google/models?pageSize={d}&view=PUBLISHER_MODEL_VIEW_BASIC",
        .{ location.host(), page_size },
    );
    if (page_token) |token| {
        try out.writer.writeAll("&pageToken=");
        try std.Uri.Component.percentEncode(&out.writer, token, isUnreserved);
    }
    return out.toOwnedSlice();
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

/// Decode one page. A malformed envelope rejects the page, while a malformed
/// entry is skipped so one bad model costs no other.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) !Page {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadModelList,
        };
    defer parsed.deinit();

    const object = json.object(parsed.value) orelse return error.BadModelList;
    // A region with no listed model answers an empty object.
    var listed: []const std.json.Value = &.{};
    if (object.get("publisherModels")) |value| {
        listed = (json.array(value) orelse return error.BadModelList).items;
    }
    if (listed.len > entry_count_max) return error.BadModelList;

    var models: std.ArrayList(Model) = .empty;
    errdefer models.deinit(gpa);
    for (listed) |value| {
        const model = decode(value) orelse continue;
        try models.append(gpa, model);
    }
    const next_page_token = if (json.string(object.get("nextPageToken"))) |token|
        if (token.len == 0) null else try gpa.dupe(u8, token)
    else
        null;
    errdefer if (next_page_token) |token| gpa.free(token);
    return .{ .models = try models.toOwnedSlice(gpa), .next_page_token = next_page_token };
}

/// One Gemini model of a served generation, or null for every other entry.
fn decode(value: std.json.Value) ?Model {
    const object = json.object(value) orelse return null;
    const name = json.string(object.get("name")) orelse return null;
    if (!std.mem.startsWith(u8, name, name_prefix)) return null;
    const id = name[name_prefix.len..];
    if ((generation(id) orelse return null) < generation_min) return null;
    return Model.init(id) catch null;
}

/// The major version of a Gemini id: the digits behind `gemini-`. An id without
/// them, such as `gemini-embedding-2` or `gemini-live-2.5-flash`, names none.
fn generation(id: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, id, id_prefix)) return null;
    const rest = id[id_prefix.len..];
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

const sample =
    \\{ "publisherModels": [
    \\  { "name": "publishers/google/models/gemini-3.5-flash", "versionId": "default",
    \\    "openSourceCategory": "PROPRIETARY", "launchStage": "GA" },
    \\  { "name": "publishers/google/models/gemini-3.1-pro-preview", "launchStage": "PUBLIC_PREVIEW" },
    \\  { "name": "publishers/google/models/gemini-2.5-flash" },
    \\  { "name": "publishers/google/models/gemini-1.5-pro-002" },
    \\  { "name": "publishers/google/models/gemini-embedding-2" },
    \\  { "name": "publishers/google/models/gemini-live-2.5-flash-native-audio" },
    \\  { "name": "publishers/google/models/imagen-4.0-generate-001" },
    \\  { "name": "publishers/anthropic/models/claude-opus-4-8" },
    \\  { "name": "gemini-3.8-flash" },
    \\  { "versionId": "001" },
    \\  "not-an-object"
    \\], "nextPageToken": "abc/def==" }
;

test parse {
    const gpa = std.testing.allocator;
    var page = try parse(gpa, sample);
    defer page.deinit(gpa);

    // Only a Gemini model of a served generation under the Google publisher
    // survives the decode.
    try std.testing.expectEqual(@as(usize, 2), page.models.len);
    try std.testing.expectEqualStrings("gemini-3.5-flash", page.models[0].name());
    try std.testing.expectEqualStrings("gemini-3.1-pro-preview", page.models[1].name());
    // The list states no fact beyond the name.
    try std.testing.expect(page.models[0].context_window == null);
    try std.testing.expect(page.models[0].price == null);
    try std.testing.expectEqual(Model.Thinking.unknown, page.models[0].thinking);
    try std.testing.expectEqualStrings("abc/def==", page.next_page_token.?);

    var last = try parse(gpa,
        \\{ "publisherModels": [{ "name": "publishers/google/models/gemini-3.8-flash" }] }
    );
    defer last.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), last.models.len);
    try std.testing.expect(last.next_page_token == null);

    var empty = try parse(gpa, "{}");
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty.models.len);
}

test generation {
    try std.testing.expectEqual(@as(?u32, 3), generation("gemini-3-flash-preview"));
    try std.testing.expectEqual(@as(?u32, 3), generation("gemini-3.5-flash"));
    try std.testing.expectEqual(@as(?u32, 4), generation("gemini-4"));
    try std.testing.expectEqual(@as(?u32, 12), generation("gemini-12-pro"));
    try std.testing.expectEqual(@as(?u32, 2), generation("gemini-2.5-pro"));
    try std.testing.expectEqual(@as(?u32, 1), generation("gemini-1.5-pro-002"));
    try std.testing.expect(generation("gemini-embedding-2") == null);
    try std.testing.expect(generation("gemini-live-2.5-flash-native-audio") == null);
    try std.testing.expect(generation("gemini-") == null);
    try std.testing.expect(generation("gemma-3-27b-it") == null);
    try std.testing.expect(generation("gemini-99999999999") == null);
}

test "a malformed envelope is rejected" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadModelList, parse(gpa, "[]"));
    try std.testing.expectError(error.BadModelList, parse(gpa, "not json"));
    try std.testing.expectError(error.BadModelList, parse(gpa, "{\"publisherModels\":{}}"));
}

test "parse bounds the entry count" {
    const gpa = std.testing.allocator;
    const at_max = "{\"publisherModels\":[{}" ++ (",{}" ** (entry_count_max - 1)) ++ "]}";
    var page = try parse(gpa, at_max);
    page.deinit(gpa);
    const over = "{\"publisherModels\":[{}" ++ (",{}" ** entry_count_max) ++ "]}";
    try std.testing.expectError(error.BadModelList, parse(gpa, over));
}

test pageUrl {
    const gpa = std.testing.allocator;
    const first = try pageUrl(gpa, .eu, null);
    defer gpa.free(first);
    try std.testing.expectEqualStrings(
        "https://aiplatform.eu.rep.googleapis.com/v1beta1/publishers/google/models" ++
            "?pageSize=100&view=PUBLISHER_MODEL_VIEW_BASIC",
        first,
    );
    // The token is opaque, so every byte outside the unreserved set encodes.
    const paged = try pageUrl(gpa, .global, "abc/def==&x");
    defer gpa.free(paged);
    try std.testing.expectEqualStrings(
        "https://aiplatform.googleapis.com/v1beta1/publishers/google/models" ++
            "?pageSize=100&view=PUBLISHER_MODEL_VIEW_BASIC&pageToken=abc%2Fdef%3D%3D%26x",
        paged,
    );
}

// The deadline of a fetch is shared with the requests around it, so a page must
// take what is left of the window. A window that has closed refuses the page
// before it opens a socket.
test "an expired deadline refuses the list without a request" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const expired: net.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(error.Timeout, fetch(std.testing.allocator, io, expired, &.{
        .access_token = "token",
        .location = .global,
    }));
}

/// The scripted pages of the paging tests, and the token each request must carry.
var scripted_bodies: []const []const u8 = &.{};
var scripted_tokens: []const ?[]const u8 = &.{};
var scripted_index: usize = 0;

fn scriptedPage(
    gpa: std.mem.Allocator,
    _: std.Io,
    _: net.Deadline,
    _: *const Options,
    page_token: ?[]const u8,
) anyerror!Page {
    const expected = scripted_tokens[scripted_index] orelse "";
    if (!std.mem.eql(u8, page_token orelse "", expected)) return error.WrongPageToken;
    const body = scripted_bodies[scripted_index];
    scripted_index += 1;
    return parse(gpa, body);
}

test "fetch follows the page token to the last page" {
    const gpa = std.testing.allocator;
    scripted_bodies = &.{
        \\{ "publisherModels": [{ "name": "publishers/google/models/gemini-3.5-flash" }],
        \\  "nextPageToken": "p2" }
        ,
        \\{ "publisherModels": [{ "name": "publishers/google/models/imagen-4.0" }],
        \\  "nextPageToken": "p3" }
        ,
        \\{ "publisherModels": [{ "name": "publishers/google/models/gemini-3.8-flash" }] }
        ,
    };
    scripted_tokens = &.{ null, "p2", "p3" };
    scripted_index = 0;
    const models = try fetchWith(gpa, std.testing.io, .{ .at = null }, &.{
        .access_token = "t",
        .location = .global,
    }, scriptedPage);
    defer gpa.free(models);
    try std.testing.expectEqual(@as(usize, 3), scripted_index);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gemini-3.5-flash", models[0].name());
    try std.testing.expectEqualStrings("gemini-3.8-flash", models[1].name());
}

test "fetch stops following pages at the page cap" {
    const gpa = std.testing.allocator;
    const endless =
        \\{ "publisherModels": [{ "name": "publishers/google/models/gemini-3.5-flash" }],
        \\  "nextPageToken": "again" }
    ;
    scripted_bodies = &([_][]const u8{endless} ** pages_max);
    scripted_tokens = &([_]?[]const u8{null} ++ [_]?[]const u8{"again"} ** (pages_max - 1));
    scripted_index = 0;
    const models = try fetchWith(gpa, std.testing.io, .{ .at = null }, &.{
        .access_token = "t",
        .location = .global,
    }, scriptedPage);
    defer gpa.free(models);
    try std.testing.expectEqual(@as(usize, pages_max), scripted_index);
    try std.testing.expectEqual(@as(usize, pages_max), models.len);
}
