//! The bottom status line shows context fill, cache-hit rate, session cost, and quota on the left.
//! It shows the model, account, and effort on the right. A notice temporarily replaces the line.
//! The renderer uses a caller-built `Info` snapshot.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const color = @import("color.zig");
const paint = @import("paint.zig");

pub const Info = struct {
    last: ai.llm.Usage,
    cost: f64,
    context_window: u64,
    model: []const u8,
    effort: []const u8,
    /// The active account. Null shows "Account: Signed out" instead of the
    /// model, account, and effort.
    account: ?ai.llm.Account,
    /// A subscription's remaining allowance, or null when the active provider
    /// reports none (an API key, or a non-subscription turn). Each window whose
    /// duration identifies it shows on the left as `<label>: N% remaining`.
    quota: ?ai.llm.Quota,
    /// A temporary notice replaces this footer until the next user action.
    notice: ?Notice = null,

    pub const Notice = struct {
        text: []const u8,
        is_error: bool,
    };
};

/// The right-side indicator shown while no account is active.
const signed_out_label = "Account: Signed out";

const account_open = " (";
const account_close = ")";

/// Separates the account from its effort level on the right of the line.
const separator = " · ";

/// Stream the status line through `placement`. Put session stats on the left.
/// Put `model (account) · effort` on the right. When both do not fit, show only
/// the right indicator. If that does not fit, show the truncated stats.
pub fn render(placement: *const paint.Placement, info: *const Info) !void {
    if (placement.base < placement.skip) return;
    if (info.notice) |notice| {
        const line_end = std.mem.indexOfScalar(u8, notice.text, '\n') orelse notice.text.len;
        return paint.notice(placement, &.{
            .style = if (notice.is_error) .red else .dim,
            .prefix = if (notice.is_error) "Error: " else "",
        }, notice.text[0..line_end]);
    }

    // Sized so `catch unreachable` is sound: the percent, token, cost, and quota
    // formats produce at most a few dozen characters for any input.
    var scratch: [512]u8 = undefined;
    var stats: std.Io.Writer = .fixed(&scratch);
    writeStats(&stats, info) catch unreachable;
    const line = stats.buffered();
    const stats_columns = terminal.width.ofText(line);
    const right_columns = if (info.account) |account|
        terminal.width.ofText(info.model) + terminal.width.ofText(account_open) +
            terminal.width.ofText(account.label()) + terminal.width.ofText(account_close) +
            terminal.width.ofText(separator) + terminal.width.ofText(info.effort)
    else
        terminal.width.ofText(signed_out_label);

    placement.sink.begin();
    try color.apply(placement.sink, .dim);
    if (stats_columns + right_columns + 1 <= placement.columns) {
        try placement.sink.text(line);
        try placement.sink.spaces(placement.columns - stats_columns - right_columns);
        try writeRight(placement.sink, info);
    } else if (right_columns <= placement.columns) {
        try placement.sink.spaces(placement.columns - right_columns);
        try writeRight(placement.sink, info);
    } else {
        try placement.sink.text(terminal.width.truncate(line, placement.columns));
    }
    try color.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

fn writeRight(sink: *terminal.View.Sink, info: *const Info) !void {
    if (info.account) |account| {
        try sink.text(info.model);
        try sink.text(account_open);
        try sink.text(account.label());
        try sink.text(account_close);
        try sink.text(separator);
        try sink.text(info.effort);
    } else {
        try sink.text(signed_out_label);
    }
}

fn writeStats(out: *std.Io.Writer, info: *const Info) !void {
    // Context now: the last request's whole prompt plus its output, against the
    // model's window. The one "now" number. The rest is session-cumulative.
    // Saturating: the counts arrive from the provider stream unchecked.
    const last_prompt = info.last.input +| info.last.cache_read +| info.last.cache_write;
    const context = last_prompt +| info.last.output;
    const percent = if (info.context_window > 0)
        asFloat(context) / asFloat(info.context_window) * 100.0
    else
        0.0;
    try out.print("Context: {d:.0}% (", .{percent});
    try writeTokens(out, context);
    try out.writeByte('/');
    try writeTokens(out, info.context_window);
    try out.writeByte(')');

    // Last request's cache hit rate over the whole prompt. The value is zero
    // after a cold start, model switch, or cache expiry.
    if (last_prompt > 0) {
        const hit = asFloat(info.last.cache_read) / asFloat(last_prompt) * 100.0;
        try out.print(" · Cache: {d:.0}%", .{hit});
    }

    // Session cost uses public API rates. It is an estimate because the login
    // type does not reveal billing.
    try out.print(" · Cost: ${d:.2}", .{info.cost});

    // A subscription's remaining allowance, one segment per window identified
    // by its length, as the share left rather than used.
    if (info.quota) |quota| {
        try writeQuotaWindow(out, quota.primary);
        try writeQuotaWindow(out, quota.secondary);
    }
}

/// Append one identified quota window as ` · <label>: N% remaining`, or nothing when
/// absent or when its duration does not identify it.
fn writeQuotaWindow(out: *std.Io.Writer, maybe_window: ?ai.llm.Quota.Window) !void {
    const window = maybe_window orelse return;
    const label = quotaLabel(window.window_minutes) orelse return;
    const remaining = @max(0.0, @min(100.0, 100.0 - window.used_percent));
    try out.print(" · {s}: {d:.0}% remaining", .{ label, remaining });
}

/// A human label for a rolling window, keyed off its length in minutes. The
/// ChatGPT plans use 5h and weekly windows. Unrecognized or absent lengths stay
/// hidden rather than show as an allowance we cannot identify.
fn quotaLabel(maybe_minutes: ?u32) ?[]const u8 {
    const minutes = maybe_minutes orelse return null;
    if (approxWindow(minutes, 300)) return "5h quota";
    if (approxWindow(minutes, 10080)) return "Weekly quota";
    return null;
}

/// Whether `minutes` falls within 5% of `target`. This matches how the
/// backend's window lengths drift slightly around their nominal values.
fn approxWindow(minutes: u32, target: u32) bool {
    const tolerance = @divFloor(target, 20);
    return minutes >= target - tolerance and minutes <= target + tolerance;
}

/// `count` in `k`/`M` shorthand. The thresholds match pi's footer.
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
        .context_window = 1_000_000,
        .model = "claude-opus-4-8",
        .effort = "xhigh",
        .account = .anthropic_subscription,
        .quota = null,
    };

    const sink = try view.beginFrame(.{ .columns = 160, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 160, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Context: 21% (206k/1.0M)") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Cache: 87%") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Cost: $0.39") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Saved:") == null);
    const right = std.mem.indexOf(
        u8,
        painted,
        "claude-opus-4-8\u{200B} (\u{200B}Anthropic Subscription\u{200B})" ++
            "\u{200B} · \u{200B}xhigh",
    ).?;
    try std.testing.expect(right > std.mem.indexOf(u8, painted, "Context: 21%").?);
}

test "the account indicator replaces stats when both do not fit" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const info: Info = .{
        .last = .{},
        .cost = 0,
        .context_window = 200_000,
        .model = "claude-opus-4-8",
        .effort = "xhigh",
        .account = .anthropic_subscription,
        .quota = null,
    };

    const sink = try view.beginFrame(.{ .columns = 80, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 80, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "claude-opus-4-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Anthropic Subscription") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Context:") == null);
}

test "a narrow status shows truncated stats when the account does not fit" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const info: Info = .{
        .last = .{},
        .cost = 0,
        .context_window = 200_000,
        .model = "claude-opus-4-8",
        .effort = "xhigh",
        .account = .anthropic_subscription,
        .quota = null,
    };

    const sink = try view.beginFrame(.{ .columns = 32, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 32, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Context:") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "claude-opus-4-8") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Anthropic Subscription") == null);
}

test "a notice replaces the status for exactly one row" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const info: Info = .{
        .last = .{},
        .cost = 0,
        .context_window = 200_000,
        .model = "hidden-model",
        .effort = "high",
        .account = .anthropic_subscription,
        .quota = null,
        .notice = .{ .text = "boom\nnot another row", .is_error = true },
    };

    const sink = try view.beginFrame(.{ .columns = 40, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 40, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Error: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "not another row") == null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "hidden-model") == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, painted, "\r\n"));
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
        .context_window = 200_000,
        .model = "claude-opus-4-8",
        .effort = "xhigh",
        .account = null,
        .quota = null,
    };

    const sink = try view.beginFrame(.{ .columns = 120, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 120, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Account: Signed out") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "claude-opus-4-8") == null);
    // No prompt tokens sent yet: the cache figure is absent, never a 0/0 rate.
    try std.testing.expect(std.mem.indexOf(u8, painted, "Cache") == null);
}

test "quota windows show the remaining allowance, labeled by length" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const info: Info = .{
        .last = .{},
        .cost = 0,
        .context_window = 400_000,
        .model = "gpt-5.6-sol",
        .effort = "medium",
        .account = .openai_subscription,
        .quota = .{
            .primary = .{ .used_percent = 11.6, .window_minutes = 300 },
            .secondary = .{ .used_percent = 73.6, .window_minutes = 10080 },
        },
    };

    const sink = try view.beginFrame(.{ .columns = 160, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 160, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "5h quota: 88% remaining") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "Weekly quota: 26% remaining") != null);
}

test "a quota with a single window omits the absent one" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const info: Info = .{
        .last = .{},
        .cost = 0,
        .context_window = 400_000,
        .model = "gpt-5.6-sol",
        .effort = "medium",
        .account = .openai_subscription,
        .quota = .{ .secondary = .{ .used_percent = 73.6, .window_minutes = 10080 } },
    };

    const sink = try view.beginFrame(.{ .columns = 160, .rows = 24 }, 4);
    const placement: paint.Placement =
        .{ .sink = sink, .id = 0, .columns = 160, .base = 0, .skip = 0 };
    try render(&placement, &info);
    try view.render();

    const painted = out.written();
    try std.testing.expect(std.mem.indexOf(u8, painted, "Weekly quota: 26% remaining") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "5h quota") == null);
}

test "unidentified quota windows stay hidden beside a known window" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const info: Info = .{
        .last = .{},
        .cost = 0,
        .context_window = 400_000,
        .model = "gpt-5.6-sol",
        .effort = "medium",
        .account = .openai_subscription,
        .quota = .{
            .primary = .{ .used_percent = 77, .window_minutes = 10080 },
            .secondary = .{ .used_percent = 0 },
        },
    };

    try writeStats(&out, &info);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Weekly quota: 23% remaining") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "100% remaining") == null);
    try std.testing.expect(quotaLabel(null) == null);
    try std.testing.expect(quotaLabel(600) == null);
}
