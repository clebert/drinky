//! The bottom status line: a context-window gauge, session cost, and cache
//! savings on the left, the model right-aligned. A pure renderer — it holds no
//! state and streams from a caller-built `Info` snapshot.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const color = @import("color.zig");
const paint = @import("paint.zig");

pub const Info = struct {
    last: ai.llm.Usage,
    cost: f64,
    saved: f64,
    context_window: u64,
    model: []const u8,
};

/// Stream the status line through `placement`: session stats on the left, `model`
/// right-aligned to the terminal width. When they cannot both fit, the stats
/// alone, truncated.
pub fn render(placement: *const paint.Placement, info: *const Info) !void {
    if (placement.base < placement.skip) return;

    // Sized so `catch unreachable` is sound: the percent, token, and cost formats
    // produce at most a few dozen characters for any input.
    var scratch: [512]u8 = undefined;
    var stats: std.Io.Writer = .fixed(&scratch);
    writeStats(&stats, info) catch unreachable;
    const line = stats.buffered();
    const stats_columns = terminal.width.ofText(line);
    const model_columns = terminal.width.ofText(info.model);

    const writer = placement.sink.begin();
    try writer.writeAll(color.dim);
    if (stats_columns + model_columns + 1 <= placement.columns) {
        try writer.writeAll(line);
        try writer.splatByteAll(' ', placement.columns - stats_columns - model_columns);
        try writer.writeAll(info.model);
    } else {
        try writer.writeAll(terminal.width.truncate(line, placement.columns));
    }
    try writer.writeAll(color.reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

fn writeStats(out: *std.Io.Writer, info: *const Info) !void {
    // Context now: the last request's whole prompt plus its output, against the
    // model's window. The one "now" number; the rest is session-cumulative.
    const context = info.last.input + info.last.cache_read + info.last.cache_write + info.last.output;
    const percent = if (info.context_window > 0)
        asFloat(context) / asFloat(info.context_window) * 100.0
    else
        0.0;
    try out.print("ctx {d:.0}% (", .{percent});
    try writeTokens(out, context);
    try out.writeByte('/');
    try writeTokens(out, info.context_window);
    try out.writeByte(')');

    // Last request's cache hit rate over the whole prompt: another "now" number.
    // Zero on a cold start, model switch, or cache expiry, making a miss visible
    // where the cumulative "saved" figure cannot.
    const last_prompt = info.last.input + info.last.cache_read + info.last.cache_write;
    if (last_prompt > 0) {
        const hit = asFloat(info.last.cache_read) / asFloat(last_prompt) * 100.0;
        try out.print(" · cache {d:.0}%", .{hit});
    }

    // Session cost, then the dollars caching saved versus sending the same tokens
    // uncached. Both use public API rates (an estimate: login type does not
    // reveal billing). Shown once a cache read has actually paid off.
    try out.print(" · ${d:.2}", .{info.cost});
    if (info.saved > 0) try out.print(" saved ${d:.2}", .{info.saved});
}

/// `count` in `k`/`M` shorthand, matching pi's footer thresholds.
fn writeTokens(out: *std.Io.Writer, count: u64) !void {
    const thousand = 1000;
    const million = 1000 * thousand;
    if (count < thousand) return out.print("{d}", .{count});
    if (count < 10 * thousand) return out.print("{d:.1}k", .{asFloat(count) / 1000.0});
    if (count < million) return out.print("{d}k", .{@divFloor(count + 500, thousand)});
    if (count < 10 * million) return out.print("{d:.1}M", .{asFloat(count) / 1_000_000.0});
    return out.print("{d}M", .{@divFloor(count + 500 * thousand, million)});
}

fn asFloat(count: u64) f64 {
    return @floatFromInt(count);
}

fn expectTokens(expected: []const u8, count: u64) !void {
    var buffer: [48]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try writeTokens(&out, count);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test writeTokens {
    try expectTokens("22", 22);
    try expectTokens("6.7k", 6700);
    try expectTokens("160k", 160_000);
    try expectTokens("1.0M", 1_000_000);
}

test render {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const info: Info = .{
        .last = .{ .input = 22, .output = 23_000, .cache_read = 160_000, .cache_write = 23_000 },
        .cost = 0.393,
        .saved = 0.82,
        .context_window = 1_000_000,
        .model = "claude-opus-4-8",
    };

    const sink = try view.beginFrame(.{ .columns = 120, .rows = 24 }, 4);
    const placement: paint.Placement = .{ .sink = sink, .id = 0, .columns = 120, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "ctx 21% (206k/1.0M)") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "cache 87%") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "$0.39 saved $0.82") != null);
    // The model is right-aligned, so it lands after the left-hand stats.
    try std.testing.expect(std.mem.indexOf(u8, painted, "claude-opus-4-8").? > std.mem.indexOf(u8, painted, "ctx 21%").?);
}
