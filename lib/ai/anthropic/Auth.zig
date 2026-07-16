//! Credential lifecycle for subscription OAuth: load and persist tokens under
//! `<home>/.pith/auth.json`, refresh a stale access token on demand, and run
//! the interactive login (browser + loopback callback). Speaks the protocol
//! through `oauth`; the keyed on-disk store is shared through `auth_store`.
//!
//! Credentials live under `"anthropic_subscription"` in the shared keyed file, so
//! a save is a load-merge-write that never clobbers another account's entry. A
//! legacy flat file (a top-level `access`, from before the keyed layout) is read
//! as this account's entry — no forced re-login — and its stale top-level keys are
//! dropped the first time the file is rewritten keyed.

const std = @import("std");

const auth_store = @import("../auth_store.zig");
const oauth = @import("oauth.zig");

const Auth = @This();

/// Top-level key this account's credentials live under in `auth.json`.
const account_key = "anthropic_subscription";

const response_page = "pith authorized \xe2\x80\x94 you can close this tab.";

gpa: std.mem.Allocator,
io: std.Io,
path: []const u8,
tokens: ?oauth.Tokens,

pub fn init(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !Auth {
    const path = try std.fs.path.join(gpa, &.{ home, ".pith", "auth.json" });
    return .{ .gpa = gpa, .io = io, .path = path, .tokens = null };
}

pub fn deinit(self: *Auth) void {
    if (self.tokens) |tokens| tokens.deinit(self.gpa);
    self.gpa.free(self.path);
}

/// Load stored tokens. Returns false when the file is absent or holds no
/// Anthropic subscription credential (keyed or legacy-flat).
pub fn load(self: *Auth) !bool {
    var file = (try auth_store.open(self.gpa, self.io, self.path)) orelse return false;
    defer file.deinit();

    // The keyed entry, or a legacy flat file read whole as this account's entry.
    const entry = file.entry(account_key) orelse file.legacyFlat() orelse return false;

    const access = try self.gpa.dupe(u8, jsonString(entry, "access") orelse return error.BadCredentials);
    errdefer self.gpa.free(access);
    const refresh = try self.gpa.dupe(u8, jsonString(entry, "refresh") orelse return error.BadCredentials);
    errdefer self.gpa.free(refresh);
    const expires_ms = jsonInt(entry, "expires_ms") orelse return error.BadCredentials;

    self.tokens = .{ .access = access, .refresh = refresh, .expires_ms = expires_ms };
    return true;
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInt(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

/// A valid access token, refreshing and persisting it first if it has expired.
pub fn accessToken(self: *Auth) ![]const u8 {
    const tokens = self.tokens orelse return error.NotAuthenticated;
    const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    if (now_ms >= tokens.expires_ms) {
        const fresh = try oauth.refresh(self.gpa, self.io, tokens.refresh);
        tokens.deinit(self.gpa);
        self.tokens = fresh;
        try self.save();
    }
    return self.tokens.?.access;
}

/// Run the interactive OAuth login, writing user-facing prompts to `out`.
pub fn login(self: *Auth, out: *std.Io.Writer) !void {
    const pair = oauth.pkce(self.io);
    const url = try oauth.authorizeUrl(self.gpa, &pair);
    defer self.gpa.free(url);

    try out.print("Open this URL to authorize pith:\n\n{s}\n\nWaiting for the browser callback...\n", .{url});
    try out.flush();
    openBrowser(self.io, url);

    const callback = try self.awaitCallback();
    defer {
        self.gpa.free(callback.code);
        self.gpa.free(callback.state);
    }

    const tokens = try oauth.exchange(self.gpa, self.io, callback.code, callback.state, &pair.verifier);
    if (self.tokens) |old| old.deinit(self.gpa);
    self.tokens = tokens;
    try self.save();

    try out.print("Authorized. Credentials saved to {s}\n", .{self.path});
    try out.flush();
}

/// The on-disk shape of this account's entry.
const Entry = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64,
};

fn save(self: *Auth) !void {
    const tokens = self.tokens orelse return error.NotAuthenticated;
    try auth_store.save(self.gpa, self.io, self.path, account_key, Entry{
        .access = tokens.access,
        .refresh = tokens.refresh,
        .expires_ms = tokens.expires_ms,
    }, .{ .drop_flat = true });
}

const Callback = struct { code: []const u8, state: []const u8 };

fn awaitCallback(self: *Auth) !Callback {
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(oauth.callback_port) };
    var server = try address.listen(self.io, .{ .reuse_address = true });
    defer server.deinit(self.io);

    var stream = try server.accept(self.io);
    defer stream.close(self.io);

    var read_buffer: [8192]u8 = undefined;
    var stream_reader = stream.reader(self.io, &read_buffer);
    const request_line = try stream_reader.interface.takeDelimiterExclusive('\n');

    const code = try queryParam(self.gpa, request_line, "code");
    errdefer self.gpa.free(code);
    const state = try queryParam(self.gpa, request_line, "state");

    var write_buffer: [512]u8 = undefined;
    var stream_writer = stream.writer(self.io, &write_buffer);
    try stream_writer.interface.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ response_page.len, response_page },
    );
    try stream_writer.interface.flush();

    return .{ .code = code, .state = state };
}

fn openBrowser(io: std.Io, url: []const u8) void {
    var child = std.process.spawn(io, .{ .argv = &.{ "xdg-open", url } }) catch {
        var fallback = std.process.spawn(io, .{ .argv = &.{ "open", url } }) catch return;
        _ = fallback.wait(io) catch {};
        return;
    };
    _ = child.wait(io) catch {};
}

/// Value of query parameter `name` in an HTTP request line, owned by the caller.
fn queryParam(gpa: std.mem.Allocator, request_line: []const u8, name: []const u8) ![]const u8 {
    var needle_buffer: [16]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "{s}=", .{name}) catch return error.BadCallback;
    const at = std.mem.indexOf(u8, request_line, needle) orelse return error.MissingCallbackParam;
    const rest = request_line[at + needle.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] != '&' and rest[end] != ' ' and rest[end] != '\r') end += 1;
    return gpa.dupe(u8, rest[0..end]);
}

test queryParam {
    const line = "GET /callback?code=abc123&state=xyz HTTP/1.1\r";
    const code = try queryParam(std.testing.allocator, line, "code");
    defer std.testing.allocator.free(code);
    const state = try queryParam(std.testing.allocator, line, "state");
    defer std.testing.allocator.free(state);
    try std.testing.expectEqualStrings("abc123", code);
    try std.testing.expectEqualStrings("xyz", state);
}
