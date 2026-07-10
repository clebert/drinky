//! The bottom status line: a context-window gauge, session cost, and cache
//! savings on the left, the model right-aligned. A pure renderer — it holds no
//! state and reads a caller-built `Info` snapshot.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const dim = "\x1b[2m";
const reset = "\x1b[0m";

pub const Info = struct {
    last: ai.llm.Usage,
    cost: f64,
    saved: f64,
    context_window: u64,
    model: []const u8,
};

/// Compose the status line into `buffer` (cleared first) and return it: stats on
/// the left, `model` right-aligned to `columns`. The result fits `columns`.
pub fn render(
    info: Info,
    columns: usize,
    buffer: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) ![]const u8 {
    buffer.clearRetainingCapacity();

    var stats: std.ArrayList(u8) = .empty;
    defer stats.deinit(gpa);
    try writeStats(&stats, gpa, info);

    const stats_columns = terminal.width.display(stats.items);
    const model_columns = terminal.width.display(info.model);

    try buffer.appendSlice(gpa, dim);
    if (stats_columns + model_columns + 1 <= columns) {
        try buffer.appendSlice(gpa, stats.items);
        try appendSpaces(buffer, gpa, columns - stats_columns - model_columns);
        try buffer.appendSlice(gpa, info.model);
    } else {
        try buffer.appendSlice(gpa, terminal.width.truncate(stats.items, columns));
    }
    try buffer.appendSlice(gpa, reset);
    return buffer.items;
}

fn writeStats(out: *std.ArrayList(u8), gpa: std.mem.Allocator, info: Info) !void {
    // Sized so `catch unreachable` in `format` is sound: the percent and cost
    // formats produce at most a few dozen characters for any f64.
    var scratch: [512]u8 = undefined;

    // Context now: the last request's whole prompt plus its output, against the
    // model's window. The one "now" number; everything else is session-cumulative.
    const context = info.last.input + info.last.cache_read + info.last.cache_write + info.last.output;
    const percent = if (info.context_window > 0)
        asFloat(context) / asFloat(info.context_window) * 100.0
    else
        0.0;
    try out.appendSlice(gpa, "ctx ");
    try out.appendSlice(gpa, format(&scratch, "{d:.0}% (", .{percent}));
    try out.appendSlice(gpa, formatTokens(&scratch, context));
    try out.appendSlice(gpa, "/");
    try out.appendSlice(gpa, formatTokens(&scratch, info.context_window));
    try out.appendSlice(gpa, ")");

    // Last request's cache hit rate: reads over the whole prompt. Another "now"
    // number, so it sits with ctx. Zero on a cold start, model switch, or cache
    // expiry, making a miss visible where the cumulative "saved" figure can't.
    const last_prompt = info.last.input + info.last.cache_read + info.last.cache_write;
    if (last_prompt > 0) {
        const hit = asFloat(info.last.cache_read) / asFloat(last_prompt) * 100.0;
        try out.appendSlice(gpa, format(&scratch, " · cache {d:.0}%", .{hit}));
    }

    // Session cost, then the dollars caching saved versus sending the same
    // tokens uncached. Both use public API rates (an estimate: login type does
    // not reveal billing). Shown once a cache read has actually paid off.
    try out.appendSlice(gpa, format(&scratch, " · ${d:.2}", .{info.cost}));
    if (info.saved > 0) {
        try out.appendSlice(gpa, format(&scratch, " saved ${d:.2}", .{info.saved}));
    }
}

/// `count` in `k`/`M` shorthand, matching pi's footer thresholds.
fn formatTokens(buffer: []u8, count: u64) []const u8 {
    const thousand = 1000;
    const million = 1000 * thousand;
    if (count < thousand) return format(buffer, "{d}", .{count});
    if (count < 10 * thousand) return format(buffer, "{d:.1}k", .{asFloat(count) / 1000.0});
    if (count < million) return format(buffer, "{d}k", .{@divFloor(count + 500, thousand)});
    if (count < 10 * million) return format(buffer, "{d:.1}M", .{asFloat(count) / 1_000_000.0});
    return format(buffer, "{d}M", .{@divFloor(count + 500 * thousand, million)});
}

/// `bufPrint` that cannot fail: callers pass a buffer sized for the values here.
fn format(buffer: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, fmt, args) catch unreachable;
}

fn appendSpaces(out: *std.ArrayList(u8), gpa: std.mem.Allocator, count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try out.append(gpa, ' ');
}

fn asFloat(count: u64) f64 {
    return @floatFromInt(count);
}

test formatTokens {
    var buffer: [48]u8 = undefined;
    try std.testing.expectEqualStrings("22", formatTokens(&buffer, 22));
    try std.testing.expectEqualStrings("6.7k", formatTokens(&buffer, 6700));
    try std.testing.expectEqualStrings("160k", formatTokens(&buffer, 160_000));
    try std.testing.expectEqualStrings("1.0M", formatTokens(&buffer, 1_000_000));
}

test render {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    const line = try render(.{
        .last = .{ .input = 22, .output = 23_000, .cache_read = 160_000, .cache_write = 23_000 },
        .cost = 0.393,
        .saved = 0.82,
        .context_window = 1_000_000,
        .model = "claude-opus-4-8",
    }, 120, &buffer, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 120), terminal.width.display(line));
    try std.testing.expect(std.mem.indexOf(u8, line, "ctx 21% (206k/1.0M)") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "cache 87%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "$0.39 saved $0.82") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "claude-opus-4-8") != null);
}
