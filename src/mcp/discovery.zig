const std = @import("std");
const builtin = @import("builtin");

pub const id_length = 12;
pub const Id = [id_length]u8;
pub const entries_max = 16;
pub const path_bytes_max = @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len - 1;
const scanned_names_max = 1024;
const socket_suffix = ".sock";
const lock_suffix = ".lock";
const directory_mode = 0o700;
const lock_mode = 0o600;
const shared_mode_bits = 0o077;

pub const OpenError = std.Io.Dir.OpenError || std.Io.Dir.StatError ||
    error{ DirectoryUnsafe, Unexpected };
pub const CreateError = OpenError || std.Io.Dir.CreateDirPathError || std.Io.Dir.CreateDirError;
pub const PublishError = CreateError || std.Io.File.OpenError || error{NameTooLong};
pub const SettleError = std.Io.File.OpenError || std.Io.Dir.DeleteFileError;
pub const CheckError = std.Io.Dir.StatFileError || error{NotSocket};

pub const Publication = struct {
    directory: std.Io.Dir,
    id: Id,
    lock: std.Io.File,
    path_buffer: [path_bytes_max]u8,
    path_length: usize,

    pub fn socketPath(self: *const Publication) []const u8 {
        return self.path_buffer[0..self.path_length];
    }
};

pub const Scan = struct {
    ids: [entries_max]Id,
    count: usize,
    more: bool,

    pub fn found(self: *const Scan) []const Id {
        return self.ids[0..self.count];
    }
};

pub const Settled = enum { alive, removed, orphaned };

pub fn directory(gpa: std.mem.Allocator, home: []const u8) error{OutOfMemory}![]u8 {
    return std.Io.Dir.path.join(gpa, &.{ home, ".drinky", "mcp" });
}

pub fn open(io: std.Io, path: []const u8) OpenError!std.Io.Dir {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.SymLinkLoop, error.NotDir => return error.DirectoryUnsafe,
        else => |other| return other,
    };
    errdefer dir.close(io);
    const stat = try dir.stat(io);
    if (stat.kind != .directory) return error.DirectoryUnsafe;
    if (stat.permissions.toMode() & shared_mode_bits != 0) return error.DirectoryUnsafe;
    if (try ownerOf(dir) != effectiveUser()) return error.DirectoryUnsafe;
    return dir;
}

pub fn publish(io: std.Io, path: []const u8) PublishError!Publication {
    if (std.Io.Dir.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    std.Io.Dir.cwd().createDir(io, path, .fromMode(directory_mode)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |other| return other,
    };
    var dir = try open(io, path);
    errdefer dir.close(io);
    var result: Publication = .{
        .directory = dir,
        .id = mint(io),
        .lock = undefined,
        .path_buffer = undefined,
        .path_length = 0,
    };
    result.path_length = (try socketPath(&result.path_buffer, path, &result.id)).len;
    const lock_name = entryName(&result.id, lock_suffix);
    result.lock = try dir.createFile(io, &lock_name, .{
        .exclusive = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = .fromMode(lock_mode),
    });
    return result;
}

pub fn withdraw(io: std.Io, publication: *Publication) std.Io.Dir.DeleteFileError!void {
    defer publication.directory.close(io);
    defer publication.lock.close(io);
    try deleteEntry(io, publication.directory, &entryName(&publication.id, socket_suffix));
    try deleteEntry(io, publication.directory, &entryName(&publication.id, lock_suffix));
}

pub fn parseId(text: []const u8) ?Id {
    if (text.len != id_length) return null;
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    return text[0..id_length].*;
}

pub fn socketPath(
    buffer: *[path_bytes_max]u8,
    directory_path: []const u8,
    id: *const Id,
) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}" ++ socket_suffix, .{ directory_path, id }) catch
        error.NameTooLong;
}

pub fn scan(io: std.Io, dir: std.Io.Dir) std.Io.Dir.Iterator.Error!Scan {
    var result: Scan = .{ .ids = undefined, .count = 0, .more = false };
    var iterator = dir.iterate();
    for (0..scanned_names_max) |_| {
        const entry = try iterator.next(io) orelse break;
        if (!std.mem.endsWith(u8, entry.name, socket_suffix)) continue;
        const id = parseId(entry.name[0 .. entry.name.len - socket_suffix.len]) orelse continue;
        if (result.count == entries_max) {
            result.more = true;
            break;
        }
        result.ids[result.count] = id;
        result.count += 1;
    } else result.more = true;
    std.mem.sortUnstable(Id, result.ids[0..result.count], {}, idLess);
    return result;
}

pub fn check(io: std.Io, dir: std.Io.Dir, id: *const Id) CheckError!void {
    const name = entryName(id, socket_suffix);
    const stat = try dir.statFile(io, &name, .{ .follow_symlinks = false });
    if (stat.kind != .unix_domain_socket) return error.NotSocket;
}

pub fn settle(io: std.Io, dir: std.Io.Dir, id: *const Id) SettleError!Settled {
    const lock_name = entryName(id, lock_suffix);
    var lock = dir.openFile(io, &lock_name, .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return .alive,
        error.FileNotFound => return .orphaned,
        else => |other| return other,
    };
    defer lock.close(io);
    try deleteEntry(io, dir, &entryName(id, socket_suffix));
    try deleteEntry(io, dir, &lock_name);
    return .removed;
}

fn mint(io: std.Io) Id {
    var bytes: [@divExact(id_length, 2)]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn entryName(id: *const Id, comptime suffix: []const u8) [id_length + suffix.len]u8 {
    var name: [id_length + suffix.len]u8 = undefined;
    @memcpy(name[0..id_length], id);
    @memcpy(name[id_length..], suffix);
    return name;
}

fn deleteEntry(io: std.Io, dir: std.Io.Dir, name: []const u8) std.Io.Dir.DeleteFileError!void {
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |other| return other,
    };
}

fn idLess(_: void, left: Id, right: Id) bool {
    return std.mem.lessThan(u8, &left, &right);
}

fn ownerOf(dir: std.Io.Dir) error{Unexpected}!u32 {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var statx: linux.Statx = undefined;
            const mask: linux.STATX = .{ .UID = true };
            const status = linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, mask, &statx);
            if (linux.errno(status) != .SUCCESS) return error.Unexpected;
            return statx.uid;
        },
        else => {
            var stat: std.c.Stat = undefined;
            if (std.c.fstat(dir.handle, &stat) != 0) return error.Unexpected;
            return stat.uid;
        },
    }
}

fn effectiveUser() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.geteuid(),
        else => std.c.geteuid(),
    };
}

test "a publication holds its lock until its withdrawal removes the entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try accounts.testing.tmpPath(&path_buffer, &tmp, "home/.drinky/mcp");
    var publication = try publish(io, path);
    const id = publication.id;
    try std.testing.expect(parseId(&id) != null);
    var socket_buffer: [path_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        try socketPath(&socket_buffer, path, &id),
        publication.socketPath(),
    );
    var dir = try open(io, path);
    defer dir.close(io);
    try std.testing.expectEqual(@as(u32, directory_mode), (try dir.stat(io)).permissions.toMode() &
        0o777);
    try dir.writeFile(io, .{ .sub_path = &entryName(&id, socket_suffix), .data = "" });
    try std.testing.expectEqual(Settled.alive, try settle(io, dir, &id));
    try std.testing.expectEqual(@as(usize, 1), (try scan(io, dir)).count);
    try withdraw(io, &publication);
    try std.testing.expectEqual(@as(usize, 0), (try scan(io, dir)).count);
    try std.testing.expectError(
        error.FileNotFound,
        dir.statFile(io, &entryName(&id, lock_suffix), .{}),
    );
}

test "the cleanup removes an entry whose owner ended and keeps live and unlocked entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try accounts.testing.tmpPath(&path_buffer, &tmp, "mcp");
    var live = try publish(io, path);
    defer withdraw(io, &live) catch {};
    var dir = try open(io, path);
    defer dir.close(io);
    const ended: Id = "aaaaaaaaaaaa".*;
    const orphan: Id = "bbbbbbbbbbbb".*;
    for ([_]Id{ live.id, ended, orphan }) |id|
        try dir.writeFile(io, .{ .sub_path = &entryName(&id, socket_suffix), .data = "" });
    try dir.writeFile(io, .{ .sub_path = &entryName(&ended, lock_suffix), .data = "" });
    try std.testing.expectEqual(Settled.removed, try settle(io, dir, &ended));
    try std.testing.expectEqual(Settled.alive, try settle(io, dir, &live.id));
    try std.testing.expectEqual(Settled.orphaned, try settle(io, dir, &orphan));
    const left = try scan(io, dir);
    try std.testing.expectEqual(@as(usize, 2), left.count);
    for (left.found()) |id| try std.testing.expect(!std.mem.eql(u8, &id, &ended));
}

test "a scan sorts valid entries, ignores other names, and marks entries over its limit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{
        "bbbbbbbbbbbb.sock", "aaaaaaaaaaaa.sock", "aaaaaaaaaaaa.lock",
        "short.sock",        "ABCDEF012345.sock", "aaaaaaaaaaaa.sock.tmp",
    }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    const found = try scan(io, dir);
    try std.testing.expectEqual(@as(usize, 2), found.count);
    try std.testing.expectEqualStrings("aaaaaaaaaaaa", &found.ids[0]);
    try std.testing.expectEqualStrings("bbbbbbbbbbbb", &found.ids[1]);
    try std.testing.expect(!found.more);
    for (0..entries_max) |index| {
        var name: [id_length + socket_suffix.len]u8 = undefined;
        _ = try std.fmt.bufPrint(&name, "c{x:0>11}" ++ socket_suffix, .{index});
        try tmp.dir.writeFile(io, .{ .sub_path = &name, .data = "" });
    }
    const full = try scan(io, dir);
    try std.testing.expectEqual(@as(usize, entries_max), full.count);
    try std.testing.expect(full.more);
}

test "the directory refuses a symlink, open permissions, and a socket path over the limit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const real = try accounts.testing.tmpPath(&path_buffer, &tmp, "real");
    var publication = try publish(io, real);
    try withdraw(io, &publication);
    try tmp.dir.symLink(io, "real", "linked", .{ .is_directory = true });
    var linked_buffer: [128]u8 = undefined;
    const linked = try accounts.testing.tmpPath(&linked_buffer, &tmp, "linked");
    try std.testing.expectError(error.DirectoryUnsafe, publish(io, linked));
    try tmp.dir.setFilePermissions(io, "real", .fromMode(0o755), .{});
    try std.testing.expectError(error.DirectoryUnsafe, publish(io, real));
    var long_buffer: [256]u8 = undefined;
    const long = try std.fmt.bufPrint(&long_buffer, "{s}/{s}", .{
        real,
        application.support.repeat("d", path_bytes_max - id_length),
    });
    try std.testing.expectError(error.NameTooLong, publish(io, long));
}

test "an instance id holds twelve lowercase hex digits and nothing else" {
    try std.testing.expect(parseId("0123456789ab") != null);
    for ([_][]const u8{ "0123456789a", "0123456789abc", "0123456789aB", "../../etc/pw" }) |text|
        try std.testing.expect(parseId(text) == null);
}

const accounts = @import("accounts");
const application = @import("application");
