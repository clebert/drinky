const std = @import("std");

const core = @import("core");
const terminal = @import("terminal");

const format = @import("../format.zig");
const Message = @import("../Message.zig");
const project = @import("../project.zig");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");
const testing = @import("testing.zig");

pub const Info = struct {
    directory: []const u8,
    branch: ?[]const u8,
    context_tokens: ?u64,
    cache_usage: core.Provider.Usage,
    cost: f64,
    context_window: ?u64,
    model: ?[]const u8,
    effort: []const u8,
    account: ?[]const u8,
    quota: ?core.Provider.Quota,
    quota_age_ms: i64,
    credits: ?core.Provider.Credits,
    turn_active: bool,
    gauge: Gauge = .{},
    notice: ?Message = null,
};

pub const Gauge = struct {
    percent_warning: f64 = 75,
    percent_error: f64 = 90,

    pub const percent_min: f64 = 0;
    pub const percent_max: f64 = 100;
};

const Directory = struct {
    path: []const u8,
    home: []const u8,
};

const directory_bytes_max = 96;

const context_label = "Context: ";

const signed_out_value = "signed out";
const no_model_value = "none";

const account_model_separator = "/";

const branch_prefix_columns_max = 16;

const Parts = struct {
    place: Form,
    branch: Form,
    context: Context,
    quota_wait: bool,
    cost: bool,
    quota_short: bool,
    quota_long: bool,
    credits: bool,
    cache: bool,
    account: bool,
    effort: bool,

    const Form = enum { full, short, hidden };

    const Context = enum { full, short };

    const all: Parts = .{
        .place = .full,
        .branch = .full,
        .context = .full,
        .quota_wait = true,
        .cost = true,
        .quota_short = true,
        .quota_long = true,
        .credits = true,
        .cache = true,
        .account = true,
        .effort = true,
    };
};

const reductions = std.enums.values(Reduction);

const Reduction = enum {
    shorten_directory,
    shorten_branch,
    shorten_context,
    shorten_quota,
    drop_cache,
    drop_quota_long,
    drop_quota_short,
    drop_credits,
    drop_cost,
    drop_account,
    drop_branch,
    drop_place,
    drop_effort,
};

const Run = struct { start: usize, end: usize, name: role.Name };

const Line = struct {
    out: std.Io.Writer,
    runs: [runs_max]Run,
    count: usize,

    fn init(buffer: []u8) Line {
        return .{ .out = .fixed(buffer), .runs = undefined, .count = 0 };
    }

    fn text(self: *const Line) []const u8 {
        return self.out.buffered();
    }

    fn offset(self: *const Line) usize {
        return self.out.buffered().len;
    }

    fn mark(self: *Line, start: usize, name: role.Name) void {
        if (name == .muted or self.count == self.runs.len) return;
        self.runs[self.count] = .{ .start = start, .end = self.offset(), .name = name };
        self.count += 1;
    }

    fn marked(self: *const Line) []const Run {
        return self.runs[0..self.count];
    }
};

fn reduce(parts: *Parts, reduction: Reduction) void {
    switch (reduction) {
        .shorten_directory => parts.place = .short,
        .shorten_branch => parts.branch = .short,
        .shorten_context => parts.context = .short,
        .shorten_quota => parts.quota_wait = false,
        .drop_cache => parts.cache = false,
        .drop_cost => parts.cost = false,
        .drop_quota_long => parts.quota_long = false,
        .drop_quota_short => parts.quota_short = false,
        .drop_credits => parts.credits = false,
        .drop_account => parts.account = false,
        .drop_branch => parts.branch = .hidden,
        .drop_place => parts.place = .hidden,
        .drop_effort => parts.effort = false,
    }
}

const runs_max = 3;

fn pressureRole(gauge: Gauge, used_percent: f64) role.Name {
    if (used_percent >= gauge.percent_error) return .@"error";
    if (used_percent >= gauge.percent_warning) return .warning;
    return .muted;
}

fn paintRuns(sink: *terminal.View.Sink, line: *const Line, kept: []const u8) !void {
    var cursor: usize = 0;
    for (line.marked()) |run| {
        if (run.start >= kept.len) break;
        std.debug.assert(cursor <= run.start);
        try sink.text(kept[cursor..run.start]);
        try attribute.apply(sink, .reset);
        try role.apply(sink, run.name);
        cursor = @min(run.end, kept.len);
        try sink.text(kept[run.start..cursor]);
        try role.apply(sink, .muted);
    }
    try sink.text(kept[cursor..]);
}

pub fn directoryLabel(gpa: std.mem.Allocator, directory: *const Directory) ![]const u8 {
    const label = try format.path(gpa, directory.path, &.{ .home_directory = directory.home });
    if (label.len <= directory_bytes_max) return label;
    defer gpa.free(label);
    const budget = directory_bytes_max - paint.ellipsis.len;
    const start = terminal.width.boundaryAtOrAfter(label, label.len - budget);
    return gpa.print("{s}{s}", .{ paint.ellipsis, label[start..] });
}

pub fn render(placement: *const paint.Placement, info: *const Info) !void {
    if (info.notice) |notice| {
        var style: paint.NoticeStyle = .of(notice.severity);
        style.fit = .head;
        return paint.notice(placement, &style, notice.content);
    }
    if (!placement.begin(placement.base)) return;

    var left_scratch: [project.head_bytes_max + 512]u8 = undefined;
    var right_scratch: [192]u8 = undefined;
    var parts: Parts = .all;
    var left: Line = undefined;
    var right: Line = undefined;
    var left_columns: usize = 0;
    var right_columns: usize = 0;
    for (0..reductions.len + 1) |index| {
        left = .init(&left_scratch);
        right = .init(&right_scratch);
        writeLeft(&left, info, &parts) catch unreachable;
        writeRight(&right, info, &parts) catch unreachable;
        left_columns = terminal.width.ofText(left.text());
        right_columns = terminal.width.ofText(right.text());
        if (left_columns + right_columns + 1 <= placement.columns) break;
        if (index == reductions.len) break;
        reduce(&parts, reductions[index]);
    }

    try role.apply(placement.sink, .muted);
    if (left_columns + right_columns + 1 <= placement.columns) {
        try paintRuns(placement.sink, &left, left.text());
        try placement.sink.spaces(placement.columns - left_columns - right_columns);
        try paintRuns(placement.sink, &right, right.text());
    } else {
        const shown = paint.cut(left.text(), placement.columns);
        try paintRuns(placement.sink, &left, shown.kept);
        try shown.writeEllipsis(placement.sink);
    }
    try attribute.apply(placement.sink, .reset);
    placement.end(placement.base);
}

fn writeRight(line: *Line, info: *const Info, parts: *const Parts) !void {
    try line.out.writeAll("Model: ");
    const value_start = line.offset();
    const account = info.account orelse {
        try line.out.writeAll(signed_out_value);
        line.mark(value_start, .warning);
        return writeEffort(line, info, parts);
    };
    if (parts.account) {
        try line.out.writeAll(account);
        try line.out.writeAll(account_model_separator);
    }
    const model = info.model orelse {
        try line.out.writeAll(no_model_value);
        line.mark(value_start, .warning);
        return writeEffort(line, info, parts);
    };
    try line.out.writeAll(model);
    line.mark(value_start, .text);
    try writeEffort(line, info, parts);
}

fn writeEffort(line: *Line, info: *const Info, parts: *const Parts) !void {
    if (parts.effort) {
        try line.out.writeAll(paint.separator);
        try line.out.writeAll("Effort: ");
        const effort_start = line.offset();
        try line.out.writeAll(info.effort);
        line.mark(effort_start, .text);
    }
}

fn writeLeft(line: *Line, info: *const Info, parts: *const Parts) !void {
    if (parts.place != .hidden and info.directory.len > 0) {
        try writePlace(line, info, parts);
        try line.out.writeAll(paint.separator);
    }
    try writeContext(line, info, parts.context);
    if (parts.cost) try writeCost(line, info);
    if (!info.turn_active) return;
    if (info.quota) |quota| {
        const windows = orderedWindows(&quota);
        if (parts.quota_short) try writeQuotaPart(line, &windows[0], info, parts);
        if (parts.quota_long) try writeQuotaPart(line, &windows[1], info, parts);
    }
    if (parts.credits) try writeCredits(line, info);
    if (parts.cache) try writeCache(line, info);
}

fn writeCredits(line: *Line, info: *const Info) !void {
    const credits = info.credits orelse return;
    try line.out.print("{s}Credits: ", .{paint.separator});
    try writeUsd(&line.out, credits.remaining());
}

fn orderedWindows(quota: *const core.Provider.Quota) [2]?core.Provider.Quota.Window {
    const first = quota.primary orelse return .{ quota.secondary, null };
    const second = quota.secondary orelse return .{ first, null };
    if (sortMinutes(&second) < sortMinutes(&first)) return .{ second, first };
    return .{ first, second };
}

fn sortMinutes(window: *const core.Provider.Quota.Window) u32 {
    return window.window_minutes orelse std.math.maxInt(u32);
}

fn writeQuotaPart(
    line: *Line,
    maybe_window: *const ?core.Provider.Quota.Window,
    info: *const Info,
    parts: *const Parts,
) !void {
    const window = maybe_window.* orelse return;
    const wait_seconds = if (parts.quota_wait)
        waitSeconds(window.reset_seconds, info.quota_age_ms)
    else
        null;
    try writeQuotaWindow(line, &window, info.gauge, wait_seconds);
}

fn writePlace(line: *Line, info: *const Info, parts: *const Parts) !void {
    try writeDirectory(&line.out, info.directory, parts.place);
    if (parts.branch == .hidden) return;
    if (info.branch) |branch| {
        try line.out.writeAll(" (");
        try writeBranch(&line.out, branch, parts.branch);
        try line.out.writeByte(')');
    }
}

fn writeDirectory(out: *std.Io.Writer, directory: []const u8, place: Parts.Form) !void {
    const home_prefix = if (std.mem.startsWith(u8, directory, "~/")) "~/" else "";
    const mark = paint.ellipsis ++ "/";
    const base = std.Io.Dir.path.basename(directory);
    const short_columns = terminal.width.ofText(home_prefix) + terminal.width.ofText(mark) +
        terminal.width.ofText(base);
    if (place != .short or short_columns >= terminal.width.ofText(directory)) {
        return out.writeAll(directory);
    }
    try out.writeAll(home_prefix);
    try out.writeAll(mark);
    try out.writeAll(base);
}

fn writeBranch(out: *std.Io.Writer, branch: []const u8, form: Parts.Form) !void {
    if (form != .short) return out.writeAll(branch);
    const prefix = terminal.width.truncate(branch, branch_prefix_columns_max);
    const short_columns = terminal.width.ofText(prefix) + terminal.width.ofText(paint.ellipsis);
    if (prefix.len == branch.len or short_columns >= terminal.width.ofText(branch)) {
        return out.writeAll(branch);
    }
    try out.writeAll(prefix);
    try out.writeAll(paint.ellipsis);
}

fn writeContext(line: *Line, info: *const Info, form: Parts.Context) !void {
    const context = info.context_tokens orelse
        return line.out.writeAll(context_label ++ "Unknown");
    const window = info.context_window orelse {
        try line.out.writeAll(context_label);
        return writeTokens(&line.out, context);
    };
    const percent = if (window > 0)
        asFloat(context) / asFloat(window) * 100.0
    else
        0.0;
    const shown = @round(percent);
    try line.out.writeAll(context_label);
    const value_start = line.offset();
    try line.out.print("{d:.0}%", .{shown});
    if (form == .full) {
        try line.out.writeAll(" (");
        try writeTokens(&line.out, context);
        try line.out.writeByte('/');
        try writeTokens(&line.out, window);
        try line.out.writeByte(')');
    }
    line.mark(value_start, pressureRole(info.gauge, shown));
}

fn writeCost(line: *Line, info: *const Info) !void {
    const cost = if (info.cost > 0) @max(info.cost, 0.01) else info.cost;
    try line.out.print("{s}Cost: ~${d:.2}", .{ paint.separator, cost });
}

fn writeUsd(out: *std.Io.Writer, amount: f64) !void {
    if (amount > 0 and amount < 0.01) return out.writeAll("<$0.01");
    try out.print("${d:.2}", .{amount});
}

fn writeCache(line: *Line, info: *const Info) !void {
    const usage = &info.cache_usage;
    const prompt = usage.prompt();
    if (prompt == 0) return;
    const hit = asFloat(usage.cache_read) / asFloat(prompt) * 100.0;
    try line.out.print("{s}Cache: {d:.0}%", .{ paint.separator, hit });
}

fn writeQuotaWindow(
    line: *Line,
    window: *const core.Provider.Quota.Window,
    gauge: Gauge,
    wait_seconds: ?u64,
) !void {
    const used = @round(@max(0.0, @min(100.0, window.used_percent)));
    try line.out.writeAll(paint.separator);
    try writeQuotaLabel(&line.out, window.window_minutes);
    try line.out.writeAll(": ");
    const value_start = line.offset();
    try line.out.print("{d:.0}%", .{used});
    if (wait_seconds) |seconds| {
        try line.out.writeAll(" (");
        try writeWait(&line.out, seconds);
        try line.out.writeByte(')');
    }
    line.mark(value_start, pressureRole(gauge, used));
}

fn waitSeconds(reset_seconds: ?u64, age_ms: i64) ?u64 {
    const reset = reset_seconds orelse return null;
    const age = @max(0, age_ms);
    const left = reset -| @as(u64, @intCast(@divFloor(age, std.time.ms_per_s)));
    return if (left == 0) null else left;
}

fn writeWait(out: *std.Io.Writer, seconds: u64) !void {
    const minute = 60;
    const hour = 60 * minute;
    const day = 24 * hour;
    if (seconds < hour) return out.print("{d}m", .{@max(1, @divFloor(seconds, minute))});
    if (seconds < day) return out.print("{d}h", .{@divFloor(seconds, hour)});
    return out.print("{d}d", .{@divFloor(seconds, day)});
}

fn writeQuotaLabel(out: *std.Io.Writer, maybe_minutes: ?u32) !void {
    const minutes = maybe_minutes orelse return out.writeAll("Quota");
    const seconds = @as(u64, minutes) * std.time.s_per_min;
    const hours = roundedCount(&.{ .seconds = seconds, .unit_seconds = std.time.s_per_hour });
    if (hours * std.time.s_per_hour < std.time.s_per_day) {
        return out.print("{d}h", .{@max(1, hours)});
    }
    const days = roundedCount(&.{ .seconds = seconds, .unit_seconds = std.time.s_per_day });
    if (days * std.time.s_per_day == std.time.s_per_week) return out.writeAll("Week");
    return out.print("{d}d", .{days});
}

fn roundedCount(duration: *const struct { seconds: u64, unit_seconds: u64 }) u64 {
    const unit_seconds = duration.unit_seconds;
    return @divFloor(duration.seconds + @divFloor(unit_seconds, 2), unit_seconds);
}

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

test "a token count shows in thousands and millions" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { tokens: u64, shown: []const u8 }{
        .{ .tokens = 22, .shown = "Context: 22 · " },
        .{ .tokens = 6700, .shown = "Context: 6.7k · " },
        .{ .tokens = 160_000, .shown = "Context: 160k · " },
        .{ .tokens = 1_000_000, .shown = "Context: 1.0M · " },
    };
    for (cases) |case| {
        var info = test_info;
        info.context_tokens = case.tokens;
        info.context_window = null;
        var rig: testing.Rig = undefined;
        rig.init(gpa);
        defer rig.deinit();
        try renderForTest(&rig, &info, 200);
        try testing.expectShows(try rig.plain(), &.{case.shown});
    }
}

const test_info: Info = .{
    .directory = "~/github/clebert/drinky",
    .branch = "main",
    .context_tokens = 206_022,
    .cache_usage = .{
        .input = 22,
        .output = 23_000,
        .cache_read = 160_000,
        .cache_write = 23_000,
    },
    .cost = 0.393,
    .context_window = 1_000_000,
    .model = "claude-opus-4-8",
    .effort = "xhigh",
    .account = "anthropic-plan",
    .quota = .{
        .primary = .{ .used_percent = 11.6, .window_minutes = 300, .reset_seconds = 3180 },
        .secondary = .{ .used_percent = 73.6, .window_minutes = 10080, .reset_seconds = 580_769 },
    },
    .quota_age_ms = 0,
    .credits = null,
    .turn_active = true,
};

test "a positive sub-cent cost never displays as zero" {
    const cases = [_]struct { cost: f64, expected: []const u8 }{
        .{ .cost = 0.000123, .expected = " · Cost: ~$0.01 · " },
        .{ .cost = 0.00999, .expected = " · Cost: ~$0.01 · " },
        .{ .cost = 1e-12, .expected = " · Cost: ~$0.01 · " },
        .{ .cost = 0, .expected = " · Cost: ~$0.00 · " },
        .{ .cost = 0.01, .expected = " · Cost: ~$0.01 · " },
        .{ .cost = 0.42, .expected = " · Cost: ~$0.42 · " },
    };
    for (cases) |case| {
        var info = test_info;
        info.cost = case.cost;
        var rig: testing.Rig = undefined;
        rig.init(std.testing.allocator);
        defer rig.deinit();
        try renderForTest(&rig, &info, 200);
        try testing.expectShows(try rig.painted(), &.{case.expected});
    }
}

fn renderForTest(rig: *testing.Rig, info: *const Info, columns: usize) !void {
    const placement = try rig.begin(&.{ .columns = columns, .rows = 24, .pages = 4 });
    try render(&placement, info);
}

fn expectNoColor(painted: []const u8) !void {
    inline for (comptime std.enums.values(role.Name)) |name| {
        if (comptime !role.paints(name) or name == .muted) continue;
        if (std.mem.find(u8, painted, role.sequence(name)) != null) {
            std.debug.print("the status line took the {s} role\n", .{@tagName(name)});
            return error.TestExpectedColorless;
        }
    }
}

test render {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &test_info, 200);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        "~/github/clebert/drinky (main)",
        "Context: 21% (206k/1.0M)",
        "Cost: ~$0.39",
        "5h: 12% (53m) · Week: 74% (6d)",
        "Cache: 87%",
        "Model: ",
        "anthropic-plan/claude-opus-4-8",
        " · Effort: ",
        "xhigh",
    });
    const place = std.mem.find(u8, painted, "~/github").?;
    const context = std.mem.find(u8, painted, "Context:").?;
    try std.testing.expect(place < context);
    try std.testing.expect(context < std.mem.find(u8, painted, "claude-opus-4-8").?);
}

test "an unmeasured context reads as unknown, and an unmeasured rate hides" {
    const gpa = std.testing.allocator;

    var unknown = test_info;
    unknown.context_tokens = null;
    unknown.cache_usage = .{};
    var unknown_rig: testing.Rig = undefined;
    unknown_rig.init(gpa);
    defer unknown_rig.deinit();
    try renderForTest(&unknown_rig, &unknown, 200);
    try testing.expectShows(try unknown_rig.painted(), &.{"Context: Unknown"});
    try testing.expectHides(
        try unknown_rig.painted(),
        &.{ "Context: 21%", "(206k/1.0M)", "Cache:" },
    );

    var empty = test_info;
    empty.context_tokens = 0;
    var empty_rig: testing.Rig = undefined;
    empty_rig.init(gpa);
    defer empty_rig.deinit();
    try renderForTest(&empty_rig, &empty, 200);
    try testing.expectShows(try empty_rig.painted(), &.{"Context: 0% (0/1.0M)"});

    var narrow_rig: testing.Rig = undefined;
    narrow_rig.init(gpa);
    defer narrow_rig.deinit();
    try renderForTest(&narrow_rig, &unknown, 20);
    try testing.expectShows(try narrow_rig.painted(), &.{"Context: Unknown"});
}

test "a narrow window shortens fields before it gives up parts" {
    const gpa = std.testing.allocator;
    const steps = [_]struct {
        columns: usize,
        shows: []const []const u8,
        hides: []const []const u8,
        model: ?[]const u8 = test_info.model,
        account: ?[]const u8 = test_info.account,
    }{
        .{
            .columns = 167,
            .shows = &.{ "~/…/drinky (main)", "Context: 21% (206k/1.0M)", "Cache: 87%" },
            .hides = &.{"~/github"},
        },
        .{
            .columns = 152,
            .shows = &.{ "Context: 21%", "5h: 12% (53m)", "Week: 74% (6d)", "Cache: 87%" },
            .hides = &.{"(206k/1.0M)"},
        },
        .{
            .columns = 142,
            .shows = &.{ "Cost: ~$0.39", "5h: 12%", "Week: 74%", "Cache: 87%" },
            .hides = &.{ "(53m)", "(6d)" },
        },
        .{
            .columns = 132,
            .shows = &.{ "Cost: ~$0.39", "5h: 12%", "Week: 74%" },
            .hides = &.{"Cache:"},
        },
        .{
            .columns = 117,
            .shows = &.{ "Cost: ~$0.39", "5h: 12%" },
            .hides = &.{ "Week:", "Cache:" },
        },
        .{
            .columns = 107,
            .shows = &.{ "~/…/drinky (main)", "Cost: ~$0.39", "anthropic-plan/" },
            .hides = &.{ "5h:", "Week:", "Cache:" },
        },
        .{
            .columns = 82,
            .shows = &.{ "~/…/drinky (main)", "claude-opus-4-8", "Effort: " },
            .hides = &.{ "anthropic-plan", "Cost:" },
        },
        .{
            .columns = 67,
            .shows = &.{ "~/…/drinky · Context: 21%", "claude-opus-4-8", "Effort: " },
            .hides = &.{"(main)"},
        },
        .{
            .columns = 47,
            .shows = &.{ "Context: 21%", "claude-opus-4-8" },
            .hides = &.{ "drinky", "Effort:" },
        },
        .{
            .columns = 32,
            .model = null,
            .shows = &.{ "Context: 21%", "Model: ", "none" },
            .hides = &.{ "anthropic-plan", "Effort:" },
        },
        .{
            .columns = 32,
            .account = null,
            .shows = &.{ "Context: 21%", "Model: ", "signed out" },
            .hides = &.{"Effort:"},
        },
    };

    for (steps) |step| {
        var rig: testing.Rig = undefined;
        rig.init(gpa);
        defer rig.deinit();
        var info = test_info;
        info.model = step.model;
        info.account = step.account;
        try renderForTest(&rig, &info, step.columns);
        const painted = try rig.painted();
        try testing.expectShows(painted, step.shows);
        try testing.expectHides(painted, step.hides);
        try std.testing.expectEqual(
            std.mem.find(u8, painted, "Effort:") != null,
            std.mem.find(u8, painted, "xhigh") != null,
        );
    }
}

test "the context gauge survives every width" {
    const gpa = std.testing.allocator;
    var columns: usize = 8;
    while (columns <= 200) : (columns += 1) {
        var rig: testing.Rig = undefined;
        rig.init(gpa);
        defer rig.deinit();
        try renderForTest(&rig, &test_info, columns);
        if (columns >= 12) {
            try testing.expectShows(try rig.painted(), &.{"Context: 21%"});
            continue;
        }
        try testing.expectShows(
            try rig.painted(),
            &.{ "Context: 21%"[0 .. columns - 1], paint.ellipsis },
        );
    }
}

test "a gauge takes a color when it fills past its threshold" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.context_tokens = 750_000;
    info.quota = .{
        .primary = .{ .used_percent = 90, .window_minutes = 300 },
        .secondary = .{ .used_percent = 74, .window_minutes = 10080 },
    };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        comptime "Context: " ++ attribute.sequence(.reset) ++ role.sequence(.warning) ++
            "75% (750k/1.0M)" ++ role.sequence(.muted),
        comptime "5h: " ++ attribute.sequence(.reset) ++ role.sequence(.@"error") ++
            "90%" ++ role.sequence(.muted),
    });
    try testing.expectHides(painted, &.{
        comptime attribute.sequence(.reset) ++ "Context:",
        comptime attribute.sequence(.reset) ++ "5h:",
        comptime attribute.sequence(.reset) ++ "74%",
    });
}

test "a configured pair moves the shares at which a gauge takes a color" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.gauge = .{ .percent_warning = 20, .percent_error = 50 };
    info.quota = .{
        .primary = .{ .used_percent = 50, .window_minutes = 300 },
        .secondary = .{ .used_percent = 19, .window_minutes = 10080 },
    };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        comptime "Context: " ++ attribute.sequence(.reset) ++ role.sequence(.warning) ++ "21%",
        comptime "5h: " ++ attribute.sequence(.reset) ++ role.sequence(.@"error") ++ "50%",
    });
    try testing.expectHides(painted, &.{comptime attribute.sequence(.reset) ++ "19%"});
}

test "the color follows the share that the line prints" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.context_tokens = 746_000;
    info.quota = .{
        .primary = .{ .used_percent = 89.6, .window_minutes = 300 },
        .secondary = null,
    };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        comptime "Context: " ++ attribute.sequence(.reset) ++ role.sequence(.warning) ++ "75%",
        comptime "5h: " ++ attribute.sequence(.reset) ++ role.sequence(.@"error") ++ "90%",
    });
}

test "the model value and the effort level leave the faint intensity" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &test_info, 200);

    const painted = try rig.painted();
    const reset = comptime attribute.sequence(.reset);
    const muted = comptime role.sequence(.muted);
    try testing.expectShows(painted, &.{
        reset ++ "anthropic-plan/claude-opus-4-8" ++ muted,
        reset ++ "xhigh" ++ muted,
    });
    try testing.expectHides(painted, &.{
        reset ++ "Model",
        reset ++ "Effort",
        reset ++ "claude-opus-4-8",
    });
}

test "a cut keeps the color it lands in and drops the color it takes away" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.context_tokens = 950_000;
    const label_columns = terminal.width.ofText(context_label);
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, label_columns + 2);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        comptime role.sequence(.muted) ++ context_label ++ attribute.sequence(.reset) ++
            role.sequence(.@"error") ++ "9",
        comptime role.sequence(.muted) ++ paint.ellipsis,
    });

    var label_rig: testing.Rig = undefined;
    label_rig.init(gpa);
    defer label_rig.deinit();
    try renderForTest(&label_rig, &info, label_columns + 1);
    try testing.expectShows(try label_rig.painted(), &.{context_label});
    try expectNoColor(try label_rig.painted());
}

test "shortening the directory never costs columns" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.directory = "~/a";
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 80);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{"~/a (main)"});
    try testing.expectHides(painted, &.{"…"});

    var plain = test_info;
    plain.directory = "/work";
    var plain_rig: testing.Rig = undefined;
    plain_rig.init(gpa);
    defer plain_rig.deinit();
    try renderForTest(&plain_rig, &plain, 80);
    try testing.expectShows(try plain_rig.painted(), &.{"/work (main)"});
    try testing.expectHides(try plain_rig.painted(), &.{"…"});
}

test "a long branch keeps 16 columns and a whole grapheme" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.branch = "feature/" ++ core.text.repeat("🇩🇪", 8);
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 177);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        "~/…/drinky (feature/" ++ core.text.repeat("🇩🇪", 4) ++ "…)",
        "Context: 21% (206k/1.0M)",
        "Cost: ~$0.39",
        "5h: 12% (53m)",
        "Week: 74% (6d)",
        "Cache: 87%",
    });
    try testing.expectHides(painted, &.{ "~/github", core.text.repeat("🇩🇪", 5) });
}

test "a directory outside a repository shows without a branch" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.branch = null;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{"~/github/clebert/drinky · Context:"});
    try testing.expectHides(painted, &.{"(main)"});
}

test "a notice replaces the status for exactly one row" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "hidden-model";
    info.notice = .{ .content = "boom\nnot another row", .severity = .failure };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 40);

    const painted = try rig.painted();
    try testing.expectShows(
        painted,
        &.{comptime role.sequence(.@"error") ++ "⚠ boom" ++ paint.ellipsis},
    );
    try testing.expectHides(painted, &.{ "not another row", "hidden-model", "Error:" });
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, painted, "\r\n"));
}

test "a warning notice takes the warning symbol in the warning role" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.notice = .{ .content = "Enter: Send anyway", .severity = .warning };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 40);

    const painted = try rig.painted();
    try testing.expectShows(
        painted,
        &.{comptime role.sequence(.warning) ++ "⚠ Enter: Send anyway"},
    );
    try testing.expectHides(painted, &.{ "Error:", comptime role.sequence(.@"error") });
}

test "an information notice takes the information symbol in the accent role" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.notice = .{ .content = "You canceled the model fetch.", .severity = .information };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 40);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        comptime role.sequence(.accent) ++ "ℹ You canceled the model fetch.",
    });
    try testing.expectHides(painted, &.{ "Error:", "⚠" });
    try std.testing.expect(std.mem.find(
        u8,
        painted,
        comptime role.sequence(.muted),
    ) == null);
}

test "a signed-out status names the state in the model value and keeps the effort" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.account = null;
    info.cache_usage = .{};
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 120);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        "Model: ",
        comptime attribute.sequence(.reset) ++ role.sequence(.warning) ++ "signed out" ++
            role.sequence(.muted),
        " · Effort: ",
        "xhigh",
    });
    try testing.expectHides(painted, &.{ "claude-opus-4-8", "Cache" });
}

test "an account with no model shows the value in the warning role" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = null;
    info.context_window = null;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{
        "Model: ",
        comptime attribute.sequence(.reset) ++ role.sequence(.warning) ++
            "anthropic-plan/none" ++ role.sequence(.muted),
        " · Effort: ",
        "xhigh",
    });
    try testing.expectHides(painted, &.{ "claude-opus-4-8", "signed out" });
}

test "an unknown context window shows the tokens with no share" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.context_window = null;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{"Context: 206k"});
    try testing.expectHides(painted, &.{ "Context: 21%", "206k/1.0M" });
}

test "quota windows show the used share, labeled by length" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.directory = "";
    info.model = "gpt-5.6-sol";
    info.account = "openai-plan";
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 160);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{ "5h: 12% (53m)", "Week: 74% (6d)" });
    try testing.expectHides(painted, &.{" · Context:"});
}

test "the shortest window prints first, whatever slot carries it" {
    var info = test_info;
    info.quota = .{
        .primary = .{ .used_percent = 10, .window_minutes = 10080, .reset_seconds = 580_769 },
        .secondary = .{ .used_percent = 4, .window_minutes = 300, .reset_seconds = 8600 },
    };
    try expectPlainShows(&info, "· 5h: 4% (2h) · Week: 10% (6d) ·");
}

fn expectPlainShows(info: *const Info, shown: []const u8) !void {
    var rig: testing.Rig = undefined;
    rig.init(std.testing.allocator);
    defer rig.deinit();
    try renderForTest(&rig, info, 200);
    try testing.expectShows(try rig.plain(), &.{shown});
}

test "a lone quota window of any length shows under the label of its length" {
    const cases = [_]struct { minutes: ?u32, shown: []const u8 }{
        .{ .minutes = 300, .shown = "· 5h: 12% ·" },
        .{ .minutes = 10080, .shown = "· Week: 12% ·" },
        .{ .minutes = 10079, .shown = "· Week: 12% ·" },
        .{ .minutes = 20, .shown = "· 1h: 12% ·" },
        .{ .minutes = 720, .shown = "· 12h: 12% ·" },
        .{ .minutes = 1410, .shown = "· 1d: 12% ·" },
        .{ .minutes = 1440, .shown = "· 1d: 12% ·" },
        .{ .minutes = 43200, .shown = "· 30d: 12% ·" },
        .{ .minutes = 44640, .shown = "· 31d: 12% ·" },
        .{ .minutes = std.math.maxInt(u32), .shown = "· 2982616d: 12% ·" },
        .{ .minutes = null, .shown = "· Quota: 12% ·" },
    };
    for (cases) |case| {
        var info = test_info;
        info.quota = .{ .primary = .{ .used_percent = 12, .window_minutes = case.minutes } };
        try expectPlainShows(&info, case.shown);
    }
}

test "a window without a length prints after a window with a length" {
    var info = test_info;
    info.quota = .{
        .primary = .{ .used_percent = 0 },
        .secondary = .{ .used_percent = 77, .window_minutes = 10080 },
    };
    try expectPlainShows(&info, "· Week: 77% · Quota: 0% · Cache");
}

test "the credit pool shows the remaining amount while a turn runs" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = "openrouter-api-key";
    info.quota = null;
    info.credits = .{ .total = 10, .used = 2.864085024 };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);
    try testing.expectShows(
        try rig.painted(),
        &.{ "Cost: ~$0.39", "Credits: $7.14", "Cache: 87%" },
    );

    var idle = info;
    idle.turn_active = false;
    var idle_rig: testing.Rig = undefined;
    idle_rig.init(gpa);
    defer idle_rig.deinit();
    try renderForTest(&idle_rig, &idle, 200);
    try testing.expectHides(try idle_rig.painted(), &.{"Credits:"});
}

test "a sub-cent credit pool never reads as an empty one" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = "openrouter-api-key";
    info.quota = null;
    info.credits = .{ .total = 0.02, .used = 0.015 };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);
    try testing.expectShows(try rig.painted(), &.{"Credits: <$0.01"});
}

test "the credit pool takes no color at any used share" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = "openrouter-api-key";
    info.quota = null;
    for ([_]core.Provider.Credits{
        .{ .total = 10, .used = 9 },
        .{ .total = 1, .used = 2 },
        .{ .total = 0, .used = 0 },
    }) |credits| {
        info.credits = credits;
        var rig: testing.Rig = undefined;
        rig.init(gpa);
        defer rig.deinit();
        try renderForTest(&rig, &info, 200);
        try testing.expectShows(try rig.painted(), &.{"Credits: $"});
        try expectNoColor(try rig.painted());
    }
}

test "a narrow window drops the credit pool before the session cost" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = "openrouter-api-key";
    info.quota = null;
    info.credits = .{ .total = 10, .used = 2.86 };
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 127);
    try testing.expectShows(try rig.painted(), &.{ "Cost: ~$0.39", "Credits: $7.14" });
    try testing.expectHides(try rig.painted(), &.{"Cache:"});

    var narrow_rig: testing.Rig = undefined;
    narrow_rig.init(gpa);
    defer narrow_rig.deinit();
    try renderForTest(&narrow_rig, &info, 117);
    try testing.expectShows(
        try narrow_rig.painted(),
        &.{ "~/…/drinky (main)", "Context: 21%", "Cost: ~$0.39" },
    );
    try testing.expectHides(try narrow_rig.painted(), &.{ "Credits:", "Cache:" });
}

test "a quota countdown shows the time left in its largest unit and drops at its end" {
    const cases = [_]struct { reset_seconds: ?u64, age_ms: i64 = 0, shown: []const u8 }{
        .{ .reset_seconds = 59, .shown = "5h: 12% (1m) · Cache" },
        .{ .reset_seconds = 60, .shown = "5h: 12% (1m) · Cache" },
        .{ .reset_seconds = 3599, .shown = "5h: 12% (59m) · Cache" },
        .{ .reset_seconds = 3600, .shown = "5h: 12% (1h) · Cache" },
        .{ .reset_seconds = 86_399, .shown = "5h: 12% (23h) · Cache" },
        .{ .reset_seconds = 86_400, .shown = "5h: 12% (1d) · Cache" },
        .{ .reset_seconds = 580_769, .shown = "5h: 12% (6d) · Cache" },
        .{ .reset_seconds = 3180, .age_ms = 60_000, .shown = "5h: 12% (52m) · Cache" },
        .{ .reset_seconds = 60, .age_ms = -600_000, .shown = "5h: 12% (1m) · Cache" },
        .{ .reset_seconds = null, .shown = "5h: 12% · Cache" },
        .{ .reset_seconds = 60, .age_ms = 60_000, .shown = "5h: 12% · Cache" },
        .{ .reset_seconds = 60, .age_ms = 600_000, .shown = "5h: 12% · Cache" },
        .{ .reset_seconds = 3180, .age_ms = 3_600_000, .shown = "5h: 12% · Cache" },
    };
    for (cases) |case| {
        var info = test_info;
        info.quota = .{
            .primary = .{
                .used_percent = 12,
                .window_minutes = 300,
                .reset_seconds = case.reset_seconds,
            },
            .secondary = null,
        };
        info.quota_age_ms = case.age_ms;
        try expectPlainShows(&info, case.shown);
    }
}

test "the quota and the cache rate show while a turn runs alone" {
    const gpa = std.testing.allocator;
    var idle = test_info;
    idle.turn_active = false;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &idle, 200);

    const painted = try rig.painted();
    try testing.expectShows(
        painted,
        &.{ "~/github/clebert/drinky (main)", "Context: 21%", "Cost: ~$0.39" },
    );
    try testing.expectHides(painted, &.{ "5h:", "Week:", "Cache:" });
}

test "the status line hides a cache rate, a quota, and credits that it does not hold" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.cache_usage = .{};
    info.quota = null;
    info.credits = null;
    var rig: testing.Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    try renderForTest(&rig, &info, 200);

    const painted = try rig.painted();
    try testing.expectShows(painted, &.{"Context: 21% (206k/1.0M) · Cost: ~$0.39"});
    try testing.expectHides(painted, &.{ "5h:", "Week:", "Cache:", "Credits:" });
}

test "the directory label names the home with a tilde and keeps the tail of a long path" {
    const gpa = std.testing.allocator;
    const inside = try directoryLabel(gpa, &.{ .path = "/home/me/work", .home = "/home/me" });
    defer gpa.free(inside);
    try std.testing.expectEqualStrings("~/work", inside);
    const home = try directoryLabel(gpa, &.{ .path = "/home/me", .home = "/home/me" });
    defer gpa.free(home);
    try std.testing.expectEqualStrings("~", home);
    const outside = try directoryLabel(gpa, &.{ .path = "/srv/work", .home = "/home/me" });
    defer gpa.free(outside);
    try std.testing.expectEqualStrings("/srv/work", outside);

    const long_path = "/srv/" ++ core.text.repeat("a", 100) ++ "/tail";
    const cut = try directoryLabel(gpa, &.{ .path = long_path, .home = "/home/me" });
    defer gpa.free(cut);
    try std.testing.expect(cut.len <= directory_bytes_max);
    try std.testing.expect(std.mem.startsWith(u8, cut, "…"));
    try std.testing.expect(std.mem.endsWith(u8, cut, "/tail"));
}
