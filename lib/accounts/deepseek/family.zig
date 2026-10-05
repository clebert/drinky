const std = @import("std");

const prefix = "deepseek-";

pub const Rank = struct {
    major: u32,
    minor: u32,
    snapshot: u32,

    pub fn less(self: Rank, other: Rank) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.snapshot < other.snapshot;
    }
};

const Parsed = struct {
    family: []const u8,
    rank: ?Rank,
};

const Snapshot = struct {
    family: []const u8,
    snapshot: u32,
};

pub fn rank(wanted: []const u8, candidate: []const u8) ?Rank {
    const versionless = parse(wanted) orelse return null;
    if (versionless.rank != null) return null;
    const versioned = parse(candidate) orelse return null;
    const found = versioned.rank orelse return null;
    if (!std.mem.eql(u8, versioned.family, versionless.family)) return null;
    return found;
}

fn parse(name: []const u8) ?Parsed {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    if (rest.len == 0) return null;
    if (rest.len < 2 or rest[0] != 'v' or !std.ascii.isDigit(rest[1]))
        return .{ .family = rest, .rank = null };

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
        .rank = .{ .major = major, .minor = minor, .snapshot = split.snapshot },
    };
}

fn snapshotOf(family: []const u8) Snapshot {
    const dash = std.mem.lastIndexOfScalar(u8, family, '-') orelse
        return .{ .family = family, .snapshot = 0 };
    const tail = family[dash + 1 ..];
    if (tail.len == 0 or dash == 0) return .{ .family = family, .snapshot = 0 };
    for (tail) |byte| {
        if (!std.ascii.isDigit(byte)) return .{ .family = family, .snapshot = 0 };
    }
    const snapshot = std.fmt.parseInt(u32, tail, 10) catch
        return .{ .family = family, .snapshot = 0 };
    return .{ .family = family[0..dash], .snapshot = snapshot };
}

fn digits(text: []const u8, index: *usize) ?u32 {
    const start = index.*;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) index.* += 1;
    if (index.* == start) return null;
    return std.fmt.parseInt(u32, text[start..index.*], 10) catch null;
}
