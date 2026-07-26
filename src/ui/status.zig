//! The bottom status line: a context-window gauge, session cost, and cache
//! savings on the left, the model and reasoning effort right-aligned. A pure
//! renderer — it holds no state and streams from a caller-built `Info` snapshot.

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
    effort: []const u8,
    /// Whether an account is active. When false the right side reads "not signed
    /// in" instead of the model and effort, which are then unusable.
    signed_in: bool,
};

/// The right-side indicator shown while no account is active.
const signed_out_label = "not signed in";

/// Separates the model name from its effort level on the right of the line.
const separator = " · ";

/// Stream the status line through `placement`: session stats on the left, the
/// `model · effort` indicator right-aligned to the terminal width. When they
/// cannot both fit, the stats alone, truncated.
pub fn render(placement: *const paint.Placement, info: *const Info) !void {
    if (placement.base < placement.skip) return;

    // Sized so `catch unreachable` is sound: the percent, token, and cost formats
    // produce at most a few dozen characters for any input.
    var scratch: [512]u8 = undefined;
    var stats: std.Io.Writer = .fixed(&scratch);
    writeStats(&stats, info) catch unreachable;
    const line = stats.buffered();
    const stats_columns = terminal.width.ofText(line);
    const right_columns = if (info.signed_in)
        terminal.width.ofText(info.model) + terminal.width.ofText(separator) +
            terminal.width.ofText(info.effort)
    else
        terminal.width.ofText(signed_out_label);

    placement.sink.begin();
    try color.apply(placement.sink, .dim);
    if (stats_columns + right_columns + 1 <= placement.columns) {
        try placement.sink.text(line);
        try placement.sink.spaces(placement.columns - stats_columns - right_columns);
        if (info.signed_in) {
            try placement.sink.text(info.model);
            try placement.sink.text(separator);
            try placement.sink.text(info.effort);
        } else {
            try placement.sink.text(signed_out_label);
        }
    } else {
        try placement.sink.text(terminal.width.truncate(line, placement.columns));
    }
    try color.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

fn writeStats(out: *std.Io.Writer, info: *const Info) !void {
    // Context now: the last request's whole prompt plus its output, against the
    // model's window. The one "now" number; the rest is session-cumulative.
    // Saturating: the counts arrive from the provider stream unchecked.
    const last_prompt = info.last.input +| info.last.cache_read +| info.last.cache_write;
    const context = last_prompt +| info.last.output;
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
    if (count < million) return out.print("{d}k", .{@divFloor(count +| 500, thousand)});
    if (count < 10 * million) return out.print("{d:.1}M", .{asFloat(count) / 1_000_000.0});
    return out.print("{d}M", .{@divFloor(count +| 500 * thousand, million)});
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
        .effort = "xhigh",
        .signed_in = true,
    };

    const sink = try view.beginFrame(.{ .columns = 120, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 120, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "ctx 21% (206k/1.0M)") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "cache 87%") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "$0.39 saved $0.82") != null);
    // The model and effort are right-aligned, so they land after the stats.
    const right = std.mem.indexOf(u8, painted, "claude-opus-4-8\u{200B} · \u{200B}xhigh").?;
    try std.testing.expect(right > std.mem.indexOf(u8, painted, "ctx 21%").?);
}

test "a signed-out status shows the indicator in place of the model" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const info: Info = .{
        .last = .{},
        .cost = 0,
        .saved = 0,
        .context_window = 200_000,
        .model = "claude-opus-4-8",
        .effort = "xhigh",
        .signed_in = false,
    };

    const sink = try view.beginFrame(.{ .columns = 120, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 120, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "not signed in") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "claude-opus-4-8") == null);
    // No prompt tokens sent yet: the cache figure is absent, never a 0/0 rate.
    try std.testing.expect(std.mem.indexOf(u8, painted, "cache") == null);
}
