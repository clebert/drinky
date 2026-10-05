const std = @import("std");

const core = @import("core");
const providers = @import("providers");

const json = @import("../json.zig");
const Model = @import("../Model.zig");
const net = @import("../net.zig");
const paging = @import("../paging.zig");
const wire = @import("../oauth/wire.zig");

const body_bytes_max = 2 * 1024 * 1024;
const page_size = 100;
const name_prefix = "publishers/google/models/";
const id_prefix = "gemini-";
const generation_min = 3;

const Options = struct {
    access_token: []const u8,
    location: providers.Gemini.Location,
};

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    deadline: *const core.timeout.Deadline,
    options: *const Options,
) paging.Error![]Model {
    return paging.collect(Options, gpa, io, transport, deadline, options, request);
}

fn request(
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: ?providers.Transport,
    options: *const Options,
    page_token: ?[]const u8,
) paging.Error!paging.Page {
    if (!providers.Transport.validHeaderValue(
        options.access_token,
    )) return error.BadModelListCredentials;

    const url = try pageUrl(gpa, options.location, page_token);
    defer gpa.free(url);
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{options.access_token});
    defer gpa.free(authorization);

    const body = try net.getBody(gpa, io, transport, &.{
        .method = .GET,
        .url = url,
        .authorization = authorization,
        .headers = &.{net.accept_json},
    }, body_bytes_max);
    defer gpa.free(body);

    return parse(gpa, body);
}

fn pageUrl(
    gpa: std.mem.Allocator,
    location: providers.Gemini.Location,
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
        try wire.percentEncode(&out.writer, token);
    }
    return out.toOwnedSlice();
}

fn parse(gpa: std.mem.Allocator, body: []const u8) error{ OutOfMemory, BadModelList }!paging.Page {
    const envelope = try json.envelope(gpa, body, &.{
        .field = "publisherModels",
        .entries_max = paging.entries_max,
        .field_optional = true,
    });
    defer envelope.deinit();

    const models = try json.models(gpa, envelope.entries, decode);
    errdefer gpa.free(models);
    const cursor = if (providers.json.string(envelope.object.getPtr("nextPageToken"))) |token|
        if (token.len == 0) null else try gpa.dupe(u8, token)
    else
        null;
    return .{ .models = models, .cursor = cursor };
}

fn decode(value: *const std.json.Value) ?Model {
    const object = providers.json.object(value) orelse return null;
    const name = providers.json.string(object.getPtr("name")) orelse return null;
    if (!std.mem.startsWith(u8, name, name_prefix)) return null;
    const id = name[name_prefix.len..];
    if ((generation(id) orelse return null) < generation_min) return null;
    return Model.init(id) catch null;
}

fn generation(id: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, id, id_prefix)) return null;
    const rest = id[id_prefix.len..];
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

test parse {
    const gpa = std.testing.allocator;
    const page = try parse(gpa, sample);
    defer page.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), page.models.len);
    try std.testing.expectEqualStrings("gemini-3.5-flash", page.models[0].name());
    try std.testing.expectEqualStrings("gemini-3.1-pro-preview", page.models[1].name());
    try std.testing.expect(page.models[0].context_window == null);
    try std.testing.expect(page.models[0].price == null);
    try std.testing.expectEqual(Model.Thinking.unknown, page.models[0].thinking);
    try std.testing.expectEqualStrings("abc/def==", page.cursor.?);

    const last = try parse(gpa,
        \\{ "publisherModels": [{ "name": "publishers/google/models/gemini-3.8-flash" }] }
    );
    defer last.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), last.models.len);
    try std.testing.expect(last.cursor == null);

    const empty = try parse(gpa, "{}");
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty.models.len);
}

const sample =
    \\{ "publisherModels": [
    \\  { "name": "publishers/google/models/gemini-3.5-flash", "versionId": "default",
    \\    "openSourceCategory": "PROPRIETARY", "launchStage": "GA" },
    \\  { "name": "publishers/google/models/gemini-3.1-pro-preview",
    \\    "launchStage": "PUBLIC_PREVIEW" },
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

test pageUrl {
    const gpa = std.testing.allocator;
    const first = try pageUrl(gpa, .eu, null);
    defer gpa.free(first);
    try std.testing.expectEqualStrings(
        "https://aiplatform.eu.rep.googleapis.com/v1beta1/publishers/google/models" ++
            "?pageSize=100&view=PUBLISHER_MODEL_VIEW_BASIC",
        first,
    );
    const paged = try pageUrl(gpa, .global, "abc/def==&x");
    defer gpa.free(paged);
    try std.testing.expectEqualStrings(
        "https://aiplatform.googleapis.com/v1beta1/publishers/google/models" ++
            "?pageSize=100&view=PUBLISHER_MODEL_VIEW_BASIC&pageToken=abc%2Fdef%3D%3D%26x",
        paged,
    );
}

test "an expired deadline refuses the list without a request" {
    const io = std.testing.io;
    var transport: providers.testing.FakeTransport = .{ .gpa = std.testing.allocator };
    defer transport.deinit();
    const expired: core.timeout.Deadline = .{ .at = std.Io.Clock.awake.now(io) };
    try std.testing.expectError(
        error.Timeout,
        fetch(std.testing.allocator, io, transport.transport(), &expired, &.{
            .access_token = "token",
            .location = .global,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}

test "fetch follows the page token to the last page" {
    const gpa = std.testing.allocator;
    var transport: providers.testing.FakeTransport = .{ .gpa = gpa, .replies = &.{
        .{ .body =
        \\{ "publisherModels": [{ "name": "publishers/google/models/gemini-3.5-flash" }],
        \\  "nextPageToken": "p2" }
        },
        .{ .body =
        \\{ "publisherModels": [{ "name": "publishers/google/models/imagen-4.0" }],
        \\  "nextPageToken": "p3" }
        },
        .{ .body =
        \\{ "publisherModels": [{ "name": "publishers/google/models/gemini-3.8-flash" }] }
        },
    } };
    defer transport.deinit();
    const models = try fetch(gpa, std.testing.io, transport.transport(), &.unbounded, &.{
        .access_token = "t",
        .location = .global,
    });
    defer gpa.free(models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gemini-3.5-flash", models[0].name());
    try std.testing.expectEqualStrings("gemini-3.8-flash", models[1].name());
    try std.testing.expectEqual(@as(usize, 3), transport.requests.items.len);
    const requests = transport.requests.items;
    try std.testing.expect(std.mem.indexOf(u8, requests[0], "pageToken") == null);
    try std.testing.expect(std.mem.indexOf(u8, requests[1], "&pageToken=p2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, requests[2], "&pageToken=p3\n") != null);
}
