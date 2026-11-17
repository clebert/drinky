const std = @import("std");

const core = @import("core");
const tools = @import("tools");

const reference = @import("reference.zig");
const testing = @import("testing.zig");

const Gists = @This();

const id_bytes = 6;
const listed_max = 100;
const text_bytes_max = 1024 * 1024;
const name_suffix = ".md";
const name_length = id_bytes * 2 + name_suffix.len;
const file_mode = 0o600;

gpa: std.mem.Allocator,
directory: []const u8,
names_scanned_max: usize,
arena: std.heap.ArenaAllocator,
candidates: std.ArrayList(Candidate),
entries: std.ArrayList(Entry),

pub const Options = struct { names_scanned_max: usize = 1 << 16 };

pub const Id = [id_bytes]u8;
pub const ListError = std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error || error{OutOfMemory};
pub const ReadError = std.Io.Dir.OpenError || std.Io.Dir.ReadFileAllocError;
pub const SaveError = std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.Atomic.LinkError;
pub const DeleteError = std.Io.Dir.OpenError || std.Io.Dir.DeleteFileError;
pub const Error = ListError || ReadError || SaveError || DeleteError;

pub const Entry = struct { id: Id, title: []const u8, saved_ms: i64 };

pub const Listing = struct {
    entries: []const Entry,
    older: usize,
    unreadable: usize,
    invalid: usize,
    scan_limit: ?usize,
};

pub const Parsed = struct { title: []const u8, body: []const u8 };

pub const Failure = struct { path: []const u8, cause: Error };

const Candidate = struct { id: Id, saved_ms: i64 };

const Found = union(enum) { gist: Entry, deleted, invalid, unreadable };

pub fn init(
    gpa: std.mem.Allocator,
    home_directory: []const u8,
    options: Options,
) error{OutOfMemory}!Gists {
    return .{
        .gpa = gpa,
        .directory = try std.Io.Dir.path.join(gpa, &.{ home_directory, ".drinky", "gists" }),
        .names_scanned_max = options.names_scanned_max,
        .arena = .init(gpa),
        .candidates = .empty,
        .entries = .empty,
    };
}

pub fn deinit(self: *Gists) void {
    self.entries.deinit(self.gpa);
    self.candidates.deinit(self.gpa);
    self.arena.deinit();
    self.gpa.free(self.directory);
}

pub fn path(self: *const Gists, gpa: std.mem.Allocator, id: *const Id) error{OutOfMemory}![]u8 {
    return std.Io.Dir.path.join(gpa, &.{ self.directory, &fileName(id) });
}

pub fn list(self: *Gists, io: std.Io) ListError!Listing {
    _ = self.arena.reset(.retain_capacity);
    self.candidates.clearRetainingCapacity();
    self.entries.clearRetainingCapacity();
    var dir = std.Io.Dir.cwd().openDir(io, self.directory, .{ .iterate = true }) catch |err|
        switch (err) {
            error.FileNotFound => return .{
                .entries = &.{},
                .older = 0,
                .unreadable = 0,
                .invalid = 0,
                .scan_limit = null,
            },
            else => |other| return other,
        };
    defer dir.close(io);
    var unreadable: usize = 0;
    var invalid: usize = 0;
    var iterator = dir.iterate();
    const scanned_all = for (0..self.names_scanned_max) |_| {
        const entry = try iterator.next(io) orelse break true;
        const id = parseName(entry.name) orelse continue;
        const stat = dir.statFile(io, entry.name, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.FileNotFound => continue,
            else => {
                unreadable += 1;
                continue;
            },
        };
        try self.candidates.append(self.gpa, .{
            .id = id,
            .saved_ms = stat.mtime.toMilliseconds(),
        });
    } else try iterator.next(io) == null;
    std.mem.sortUnstable(Candidate, self.candidates.items, {}, newerFirst);
    const older = for (self.candidates.items, 0..) |*candidate, index| {
        if (self.entries.items.len == listed_max) break self.candidates.items.len - index;
        switch (try self.readEntry(io, dir, candidate)) {
            .gist => |gist| try self.entries.append(self.gpa, gist),
            .deleted => {},
            .invalid => invalid += 1,
            .unreadable => unreadable += 1,
        }
    } else 0;
    return .{
        .entries = self.entries.items,
        .older = older,
        .unreadable = unreadable,
        .invalid = invalid,
        .scan_limit = if (scanned_all) null else self.names_scanned_max,
    };
}

pub fn read(self: *const Gists, gpa: std.mem.Allocator, io: std.Io, id: *const Id) ReadError![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, self.directory, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, &fileName(id), gpa, .limited(text_bytes_max));
}

pub fn save(self: *const Gists, io: std.Io, text: []const u8) SaveError!void {
    try std.Io.Dir.cwd().createDirPath(io, self.directory);
    var dir = try std.Io.Dir.cwd().openDir(io, self.directory, .{});
    defer dir.close(io);
    var id: Id = undefined;
    io.random(&id);
    var atomic = try dir.createFileAtomic(io, &fileName(&id), .{
        .permissions = .fromMode(file_mode),
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    try atomic.link(io);
}

pub fn delete(self: *const Gists, io: std.Io, id: *const Id) DeleteError!void {
    var dir = std.Io.Dir.cwd().openDir(io, self.directory, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |other| return other,
    };
    defer dir.close(io);
    dir.deleteFile(io, &fileName(id)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |other| return other,
    };
}

pub fn parse(text: []const u8) ?Parsed {
    if (!tools.format.isText(text)) return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, reference.blank_bytes);
        if (trimmed.len == 0) continue;
        const unmarked = std.mem.trimStart(u8, trimmed, "#");
        const heading = std.mem.trim(u8, unmarked, reference.blank_bytes);
        const rest = lines.rest();
        const first = std.mem.findNone(u8, rest, reference.blank_bytes) orelse rest.len;
        const start = if (std.mem.findScalarLast(u8, rest[0..first], '\n')) |end| end + 1 else 0;
        return .{
            .title = if (heading.len > 0) heading else trimmed,
            .body = std.mem.trimEnd(u8, rest[start..], reference.blank_bytes),
        };
    }
    return null;
}

fn readEntry(
    self: *Gists,
    io: std.Io,
    dir: std.Io.Dir,
    candidate: *const Candidate,
) error{ OutOfMemory, Canceled }!Found {
    const arena = self.arena.allocator();
    const name = fileName(&candidate.id);
    const text = dir.readFileAlloc(io, &name, arena, .limited(text_bytes_max)) catch |err|
        switch (err) {
            error.OutOfMemory, error.Canceled => |known| return known,
            error.FileNotFound => return .deleted,
            else => return .unreadable,
        };
    const parsed = parse(text) orelse return .invalid;
    return .{ .gist = .{
        .id = candidate.id,
        .title = parsed.title,
        .saved_ms = candidate.saved_ms,
    } };
}

fn fileName(id: *const Id) [name_length]u8 {
    return std.fmt.bytesToHex(id.*, .lower) ++ name_suffix.*;
}

fn parseName(name: []const u8) ?Id {
    if (name.len != name_length or !std.mem.endsWith(u8, name, name_suffix)) return null;
    const hex = name[0 .. id_bytes * 2];
    for (hex) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    var id: Id = undefined;
    _ = std.fmt.hexToBytes(&id, hex) catch unreachable;
    return id;
}

fn newerFirst(_: void, left: Candidate, right: Candidate) bool {
    if (left.saved_ms != right.saved_ms) return left.saved_ms > right.saved_ms;
    return std.mem.lessThan(u8, &left.id, &right.id);
}

test "the first line with text titles a gist, and a text without visible characters is none" {
    const cases = [_]struct { text: []const u8, parsed: ?Parsed }{
        .{
            .text = "Fix the picker\nBody.",
            .parsed = .{ .title = "Fix the picker", .body = "Body." },
        },
        .{
            .text = "\n  \r\n# Fix the picker  \r\n \t\r\n\n  Indented.\nLast. \n\n",
            .parsed = .{ .title = "Fix the picker", .body = "  Indented.\nLast." },
        },
        .{ .text = "#hashtag\nBody.", .parsed = .{ .title = "hashtag", .body = "Body." } },
        .{ .text = "### Deep", .parsed = .{ .title = "Deep", .body = "" } },
        .{ .text = "Title\n \t\r\n\n", .parsed = .{ .title = "Title", .body = "" } },
        .{ .text = "###\nBody.", .parsed = .{ .title = "###", .body = "Body." } },
        .{ .text = " \n\t\n", .parsed = null },
        .{ .text = "", .parsed = null },
    };
    for (cases) |case| try std.testing.expectEqualDeep(case.parsed, parse(case.text));
}

test "gist listings and reads release every partial allocation" {
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    var gists: Gists = try .init(std.testing.allocator, tree.root, .{});
    defer gists.deinit();
    try gists.save(std.testing.io, "Title");
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkStore,
        .{tree.root},
    );
}

fn checkStore(gpa: std.mem.Allocator, root: []const u8) !void {
    const io = std.testing.io;
    var gists: Gists = try .init(gpa, root, .{});
    defer gists.deinit();
    const listing = try gists.list(io);
    try std.testing.expectEqual(@as(usize, 1), listing.entries.len);
    const text = try gists.read(gpa, io, &listing.entries[0].id);
    defer gpa.free(text);
}

test "a listing reads the newest gists until the list is full and counts the older gists" {
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    for (1..listed_max + 3) |seconds| try writeGist(&tree, seconds, "Gist");
    try writeGist(&tree, 1000, " \n");
    var gists: Gists = try .init(std.testing.allocator, tree.root, .{});
    defer gists.deinit();
    const listing = try gists.list(std.testing.io);
    try std.testing.expectEqual(@as(usize, listed_max), listing.entries.len);
    for (listing.entries, 0..) |entry, index| {
        const seconds: i64 = @intCast(listed_max + 2 - index);
        try std.testing.expectEqual(seconds * std.time.ms_per_s, entry.saved_ms);
    }
    try std.testing.expectEqual(@as(usize, 2), listing.older);
    try std.testing.expectEqual(@as(usize, 1), listing.invalid);
    try std.testing.expectEqual(@as(usize, 0), listing.unreadable);
    try std.testing.expectEqual(@as(?usize, null), listing.scan_limit);
}

test "a listing reports the scan limit only when the directory holds more entries" {
    var tree: testing.Tree = try .init();
    defer tree.deinit();
    for (1..4) |seconds| try writeGist(&tree, seconds, "Gist");
    const cases = [_]struct { names_scanned_max: usize, listed: usize, scan_limit: ?usize }{
        .{ .names_scanned_max = 3, .listed = 3, .scan_limit = null },
        .{ .names_scanned_max = 2, .listed = 2, .scan_limit = 2 },
    };
    for (cases) |case| {
        var gists: Gists = try .init(std.testing.allocator, tree.root, .{
            .names_scanned_max = case.names_scanned_max,
        });
        defer gists.deinit();
        const listing = try gists.list(std.testing.io);
        try std.testing.expectEqual(case.listed, listing.entries.len);
        try std.testing.expectEqual(case.scan_limit, listing.scan_limit);
    }
}

fn writeGist(tree: *testing.Tree, seconds: usize, text: []const u8) !void {
    const io = std.testing.io;
    var buffer: [32]u8 = undefined;
    const sub_path = try std.mem.print(&buffer, ".drinky/gists/{x:0>12}.md", .{seconds});
    try tree.write(sub_path, text);
    var file = try tree.tmp.dir.openFile(io, sub_path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{
        .new = .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s),
    } });
}
