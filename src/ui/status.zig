const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

pub const Info = struct {
    directory: []const u8,
    branch: ?[]const u8,
    context_tokens: ?u64,
    cache_usage: ai.llm.Usage,
    cost: f64,
    context_window: ?u64,
    model: ?[]const u8,
    effort: []const u8,
    account: ?ai.llm.Account,
    quota: ?ai.llm.Quota,
    quota_age_ms: i64,
    credits: ?ai.llm.Credits,
    turn_active: bool,
    gauge: Gauge = .{},
    notice: ?Notice = null,

    pub const Notice = struct {
        text: []const u8,
        severity: ai.command.Outcome.Severity,
    };
};

pub const Gauge = struct {
    percent_warning: f64 = 75,
    percent_error: f64 = 90,

    pub const percent_min: f64 = 0;
    pub const percent_max: f64 = 100;
};

pub const directory_bytes_max = 96;

const context_label = "Context: ";

const signed_out_value = "signed out";
const no_model_value = "none";

const account_model_separator = "/";

const separator = " · ";

const branch_prefix_columns_max = 16;

const Parts = struct {
    place: Place,
    branch: Branch,
    context: Context,
    quota_wait: bool,
    cost: bool,
    quota_short: bool,
    quota_long: bool,
    credits: bool,
    cache: bool,
    account: bool,
    effort: bool,

    const Place = enum { full, short, hidden };

    const Branch = enum { full, short, hidden };

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

const reductions = [_]Reduction{
    .shorten_directory,
    .shorten_branch,
    .shorten_context,
    .shorten_quota,
    .drop_cache,
    .drop_quota_long,
    .drop_quota_short,
    .drop_credits,
    .drop_cost,
    .drop_account,
    .drop_branch,
    .drop_place,
    .drop_effort,
};

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

const Run = struct { start: usize, end: usize, name: role.Name };

const runs_max = 3;

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

pub fn render(placement: *const paint.Placement, info: *const Info) !void {
    if (placement.base < placement.skip) return;
    if (info.notice) |notice| {
        const name: role.Name = switch (notice.severity) {
            .information => .accent,
            .warning => .warning,
            .failure => .@"error",
        };
        const prefix = switch (notice.severity) {
            .information => paint.information_prefix,
            .warning, .failure => paint.warning_prefix,
        };
        return paint.notice(
            placement,
            &.{ .role = name, .prefix = prefix, .fit = .head },
            notice.text,
        );
    }

    var left_scratch: [ai.project.head_name_bytes_max + 512]u8 = undefined;
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

    placement.sink.begin();
    try role.apply(placement.sink, .muted);
    if (left_columns + right_columns + 1 <= placement.columns) {
        try paintRuns(placement.sink, &left, left.text());
        try placement.sink.spaces(placement.columns - left_columns - right_columns);
        try paintRuns(placement.sink, &right, right.text());
    } else {
        const shown = paint.cut(left.text(), placement.columns);
        try paintRuns(placement.sink, &left, shown.kept);
        if (shown.marked) try placement.sink.text(paint.ellipsis);
    }
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

pub fn writeSummary(out: *std.Io.Writer, info: *const Info) !void {
    var scratch: [ai.project.head_name_bytes_max + 512 + separator.len + 192]u8 = undefined;
    var line: Line = .init(&scratch);
    try writeLeft(&line, info, &Parts.all);
    try line.out.writeAll(separator);
    try writeRight(&line, info, &Parts.all);
    try out.writeAll(line.text());
}

pub fn writeNumbers(out: *std.Io.Writer, info: *const Info) !void {
    var scratch: [128]u8 = undefined;
    var line: Line = .init(&scratch);
    try writeContext(&line, info, .short);
    try writeCost(&line, info);
    try out.writeAll(line.text());
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
        try line.out.writeAll(account.id());
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
        try line.out.writeAll(separator);
        try line.out.writeAll("Effort: ");
        const effort_start = line.offset();
        try line.out.writeAll(info.effort);
        line.mark(effort_start, .text);
    }
}

fn writeLeft(line: *Line, info: *const Info, parts: *const Parts) !void {
    if (parts.place != .hidden and info.directory.len > 0) {
        try writePlace(line, info, parts);
        try line.out.writeAll(separator);
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
    try line.out.print("{s}Credits: ", .{separator});
    try writeUsd(&line.out, credits.remaining());
}

fn orderedWindows(quota: *const ai.llm.Quota) [2]?ai.llm.Quota.Window {
    const maybe_first = labeledWindow(&quota.primary);
    const maybe_second = labeledWindow(&quota.secondary);
    const first = maybe_first orelse return .{ maybe_second, null };
    const second = maybe_second orelse return .{ first, null };
    if (windowMinutes(&second) < windowMinutes(&first)) return .{ second, first };
    return .{ first, second };
}

fn windowMinutes(window: *const ai.llm.Quota.Window) u32 {
    return window.window_minutes orelse 0;
}

fn labeledWindow(maybe_window: *const ?ai.llm.Quota.Window) ?ai.llm.Quota.Window {
    const window = maybe_window.* orelse return null;
    if (quotaLabel(window.window_minutes) == null) return null;
    return window;
}

fn writeQuotaPart(
    line: *Line,
    maybe_window: *const ?ai.llm.Quota.Window,
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

fn writeDirectory(out: *std.Io.Writer, directory: []const u8, place: Parts.Place) !void {
    const home_prefix = if (std.mem.startsWith(u8, directory, "~/")) "~/" else "";
    const mark = "…/";
    const base = std.fs.path.basename(directory);
    const short_columns = terminal.width.ofText(home_prefix) + terminal.width.ofText(mark) +
        terminal.width.ofText(base);
    if (place != .short or short_columns >= terminal.width.ofText(directory)) {
        return out.writeAll(directory);
    }
    try out.writeAll(home_prefix);
    try out.writeAll(mark);
    try out.writeAll(base);
}

fn writeBranch(out: *std.Io.Writer, branch: []const u8, form: Parts.Branch) !void {
    if (form != .short) return out.writeAll(branch);
    const prefix = terminal.width.truncate(branch, branch_prefix_columns_max);
    const mark = "…";
    const short_columns = terminal.width.ofText(prefix) + terminal.width.ofText(mark);
    if (prefix.len == branch.len or short_columns >= terminal.width.ofText(branch)) {
        return out.writeAll(branch);
    }
    try out.writeAll(prefix);
    try out.writeAll(mark);
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
    try line.out.print("{s}Cost: ~${d:.2}", .{ separator, cost });
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
    try line.out.print("{s}Cache: {d:.0}%", .{ separator, hit });
}

fn writeQuotaWindow(
    line: *Line,
    window: *const ai.llm.Quota.Window,
    gauge: Gauge,
    wait_seconds: ?u64,
) !void {
    const label = quotaLabel(window.window_minutes) orelse return;
    const used = @round(@max(0.0, @min(100.0, window.used_percent)));
    try line.out.print("{s}{s}: ", .{ separator, label });
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

fn quotaLabel(maybe_minutes: ?u32) ?[]const u8 {
    const minutes = maybe_minutes orelse return null;
    if (approxWindow(minutes, 300)) return "5h";
    if (approxWindow(minutes, 10080)) return "Week";
    return null;
}

fn approxWindow(minutes: u32, target: u32) bool {
    const tolerance = @divFloor(target, 20);
    return minutes >= target - tolerance and minutes <= target + tolerance;
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
    .account = .anthropic_plan,
    .quota = .{
        .primary = .{ .used_percent = 11.6, .window_minutes = 300, .reset_seconds = 3180 },
        .secondary = .{ .used_percent = 73.6, .window_minutes = 10080, .reset_seconds = 580_769 },
    },
    .quota_age_ms = 0,
    .credits = null,
    .turn_active = true,
};

fn expectSummary(expected: []const u8, info: *const Info) !void {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try writeSummary(&out, info);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "the summary states every part of the line in full, in the order of the line" {
    try expectSummary(
        "~/github/clebert/drinky (main) · Context: 21% (206k/1.0M) · Cost: ~$0.39 · " ++
            "5h: 12% (53m) · Week: 74% (6d) · Cache: 87% · " ++
            "Model: anthropic-plan/claude-opus-4-8 · Effort: xhigh",
        &test_info,
    );

    var idle = test_info;
    idle.turn_active = false;
    try expectSummary(
        "~/github/clebert/drinky (main) · Context: 21% (206k/1.0M) · Cost: ~$0.39 · " ++
            "Model: anthropic-plan/claude-opus-4-8 · Effort: xhigh",
        &idle,
    );

    var signed_out = idle;
    signed_out.account = null;
    signed_out.context_tokens = null;
    try expectSummary(
        "~/github/clebert/drinky (main) · Context: Unknown · Cost: ~$0.39 · " ++
            "Model: signed out · Effort: xhigh",
        &signed_out,
    );

    var no_model = idle;
    no_model.model = null;
    no_model.context_window = null;
    no_model.directory = "";
    try expectSummary(
        "Context: 206k · Cost: ~$0.39 · Model: anthropic-plan/none · Effort: xhigh",
        &no_model,
    );

    var empty = idle;
    empty.context_tokens = 0;
    empty.branch = null;
    try expectSummary(
        "~/github/clebert/drinky · Context: 0% (0/1.0M) · Cost: ~$0.39 · " ++
            "Model: anthropic-plan/claude-opus-4-8 · Effort: xhigh",
        &empty,
    );
}

test "the numbers state the gauge in its short form and the cost" {
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try writeNumbers(&out, &test_info);
    try std.testing.expectEqualStrings("Context: 21% · Cost: ~$0.39", out.buffered());

    var unknown = test_info;
    unknown.context_tokens = null;
    unknown.cost = 0;
    out = .fixed(&buffer);
    try writeNumbers(&out, &unknown);
    try std.testing.expectEqualStrings("Context: Unknown · Cost: ~$0.00", out.buffered());
}

test "a positive sub-cent cost never displays as zero" {
    const cases = [_]struct { cost: f64, expected: []const u8 }{
        .{ .cost = 0.000123, .expected = " · Cost: ~$0.01" },
        .{ .cost = 0.00999, .expected = " · Cost: ~$0.01" },
        .{ .cost = 1e-12, .expected = " · Cost: ~$0.01" },
        .{ .cost = 0, .expected = " · Cost: ~$0.00" },
        .{ .cost = 0.01, .expected = " · Cost: ~$0.01" },
        .{ .cost = 0.42, .expected = " · Cost: ~$0.42" },
    };
    for (cases) |case| {
        var info = test_info;
        info.cost = case.cost;
        var buffer: [64]u8 = undefined;
        var line: Line = .init(&buffer);
        try writeCost(&line, &info);
        try std.testing.expectEqualStrings(case.expected, line.text());
    }
}

fn renderForTest(
    gpa: std.mem.Allocator,
    info: *const Info,
    columns: usize,
    out: *std.Io.Writer.Allocating,
) !void {
    var view = terminal.View.init(gpa, &out.writer);
    defer view.deinit();
    const sink = try view.beginFrame(.{ .columns = columns, .rows = 24 }, 4);
    const placement: paint.Placement = .{
        .sink = sink,
        .id = 0,
        .columns = columns,
        .base = 0,
        .skip = 0,
    };
    try render(&placement, info);
    try view.render();
}

fn expectShows(painted: []const u8, texts: []const []const u8) !void {
    for (texts) |text| {
        if (std.mem.indexOf(u8, painted, text) == null) {
            std.debug.print("the status line does not show \"{s}\"\n", .{text});
            return error.TestExpectedShown;
        }
    }
}

fn expectHides(painted: []const u8, texts: []const []const u8) !void {
    for (texts) |text| {
        if (std.mem.indexOf(u8, painted, text) != null) {
            std.debug.print("the status line still shows \"{s}\"\n", .{text});
            return error.TestExpectedHidden;
        }
    }
}

fn expectNoColor(painted: []const u8) !void {
    inline for (comptime std.enums.values(role.Name)) |name| {
        if (comptime !role.paints(name) or name == .muted) continue;
        if (std.mem.indexOf(u8, painted, role.sequence(name)) != null) {
            std.debug.print("the status line took the {s} role\n", .{@tagName(name)});
            return error.TestExpectedColorless;
        }
    }
}

test render {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &test_info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{
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
    const place = std.mem.indexOf(u8, painted, "~/github").?;
    const context = std.mem.indexOf(u8, painted, "Context:").?;
    try std.testing.expect(place < context);
    try std.testing.expect(context < std.mem.indexOf(u8, painted, "claude-opus-4-8").?);
}

test "an unmeasured context reads as unknown, and an unmeasured rate hides" {
    const gpa = std.testing.allocator;

    var unknown = test_info;
    unknown.context_tokens = null;
    unknown.cache_usage = .{};
    var unknown_out: std.Io.Writer.Allocating = .init(gpa);
    defer unknown_out.deinit();
    try renderForTest(gpa, &unknown, 200, &unknown_out);
    try expectShows(unknown_out.written(), &.{"Context: Unknown"});
    try expectHides(unknown_out.written(), &.{ "Context: 21%", "(206k/1.0M)", "Cache:" });

    var empty = test_info;
    empty.context_tokens = 0;
    var empty_out: std.Io.Writer.Allocating = .init(gpa);
    defer empty_out.deinit();
    try renderForTest(gpa, &empty, 200, &empty_out);
    try expectShows(empty_out.written(), &.{"Context: 0% (0/1.0M)"});

    var narrow_out: std.Io.Writer.Allocating = .init(gpa);
    defer narrow_out.deinit();
    try renderForTest(gpa, &unknown, 20, &narrow_out);
    try expectShows(narrow_out.written(), &.{"Context: Unknown"});
}

test "a narrow window shortens fields before it gives up parts" {
    const gpa = std.testing.allocator;
    const steps = [_]struct {
        columns: usize,
        shows: []const []const u8,
        hides: []const []const u8,
        model: ?[]const u8 = test_info.model,
        account: ?ai.llm.Account = test_info.account,
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
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var info = test_info;
        info.model = step.model;
        info.account = step.account;
        try renderForTest(gpa, &info, step.columns, &out);
        const painted = out.written();
        try expectShows(painted, step.shows);
        try expectHides(painted, step.hides);
        try std.testing.expectEqual(
            std.mem.indexOf(u8, painted, "Effort:") != null,
            std.mem.indexOf(u8, painted, "xhigh") != null,
        );
    }
}

test "the context gauge survives every width" {
    const gpa = std.testing.allocator;
    var columns: usize = 8;
    while (columns <= 200) : (columns += 1) {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try renderForTest(gpa, &test_info, columns, &out);
        if (columns >= 12) {
            try expectShows(out.written(), &.{"Context: 21%"});
            continue;
        }
        try expectShows(out.written(), &.{ "Context: 21%"[0 .. columns - 1], paint.ellipsis });
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
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        comptime "Context: " ++ attribute.sequence(.reset) ++ role.sequence(.warning) ++
            "75% (750k/1.0M)" ++ role.sequence(.muted),
        comptime "5h: " ++ attribute.sequence(.reset) ++ role.sequence(.@"error") ++
            "90%" ++ role.sequence(.muted),
    });
    try expectHides(painted, &.{
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
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        comptime "Context: " ++ attribute.sequence(.reset) ++ role.sequence(.warning) ++ "21%",
        comptime "5h: " ++ attribute.sequence(.reset) ++ role.sequence(.@"error") ++ "50%",
    });
    try expectHides(painted, &.{comptime attribute.sequence(.reset) ++ "19%"});
}

test "the color follows the share that the line prints" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.context_tokens = 746_000;
    info.quota = .{
        .primary = .{ .used_percent = 89.6, .window_minutes = 300 },
        .secondary = null,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        comptime "Context: " ++ attribute.sequence(.reset) ++ role.sequence(.warning) ++ "75%",
        comptime "5h: " ++ attribute.sequence(.reset) ++ role.sequence(.@"error") ++ "90%",
    });
}

test "the model value and the effort level leave the faint intensity" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &test_info, 200, &out);

    const painted = out.written();
    const reset = comptime attribute.sequence(.reset);
    const muted = comptime role.sequence(.muted);
    try expectShows(painted, &.{
        reset ++ "anthropic-plan/claude-opus-4-8" ++ muted,
        reset ++ "xhigh" ++ muted,
    });
    try expectHides(painted, &.{
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
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, label_columns + 2, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        comptime role.sequence(.muted) ++ context_label ++ attribute.sequence(.reset) ++
            role.sequence(.@"error") ++ "9",
        comptime role.sequence(.muted) ++ paint.ellipsis,
    });

    var label_out: std.Io.Writer.Allocating = .init(gpa);
    defer label_out.deinit();
    try renderForTest(gpa, &info, label_columns + 1, &label_out);
    try expectShows(label_out.written(), &.{context_label});
    try expectNoColor(label_out.written());
}

test "shortening the directory never costs columns" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.directory = "~/a";
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 80, &out);

    const painted = out.written();
    try expectShows(painted, &.{"~/a (main)"});
    try expectHides(painted, &.{"…"});

    var plain = test_info;
    plain.directory = "/work";
    var plain_out: std.Io.Writer.Allocating = .init(gpa);
    defer plain_out.deinit();
    try renderForTest(gpa, &plain, 80, &plain_out);
    try expectShows(plain_out.written(), &.{"/work (main)"});
    try expectHides(plain_out.written(), &.{"…"});
}

test "a long branch keeps 16 columns and a whole grapheme" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.branch = "feature/" ++ "🇩🇪" ** 8;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 177, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        "~/…/drinky (feature/" ++ "🇩🇪" ** 4 ++ "…)",
        "Context: 21% (206k/1.0M)",
        "Cost: ~$0.39",
        "5h: 12% (53m)",
        "Week: 74% (6d)",
        "Cache: 87%",
    });
    try expectHides(painted, &.{ "~/github", "🇩🇪" ** 5 });
}

test "a directory outside a repository shows without a branch" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.branch = null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{"~/github/clebert/drinky · Context:"});
    try expectHides(painted, &.{"(main)"});
}

test "a notice replaces the status for exactly one row" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "hidden-model";
    info.notice = .{ .text = "boom\nnot another row", .severity = .failure };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 40, &out);

    const painted = out.written();
    try expectShows(painted, &.{comptime role.sequence(.@"error") ++ "⚠ boom" ++ paint.ellipsis});
    try expectHides(painted, &.{ "not another row", "hidden-model", "Error:" });
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, painted, "\r\n"));
}

test "a warning notice takes the warning symbol in the warning role" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.notice = .{ .text = "Enter: Send anyway", .severity = .warning };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 40, &out);

    const painted = out.written();
    try expectShows(painted, &.{comptime role.sequence(.warning) ++ "⚠ Enter: Send anyway"});
    try expectHides(painted, &.{ "Error:", comptime role.sequence(.@"error") });
}

test "an information notice takes the information symbol in the accent role" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.notice = .{ .text = "Drinky loaded every queued message.", .severity = .information };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 40, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        comptime role.sequence(.accent) ++ "ℹ Drinky loaded every queued message.",
    });
    try expectHides(painted, &.{ "Error:", "⚠" });
    try std.testing.expect(std.mem.indexOf(
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
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 120, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        "Model: ",
        comptime attribute.sequence(.reset) ++ role.sequence(.warning) ++ "signed out" ++
            role.sequence(.muted),
        " · Effort: ",
        "xhigh",
    });
    try expectHides(painted, &.{ "claude-opus-4-8", "Cache" });
}

test "an account with no model shows the value in the warning role" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = null;
    info.context_window = null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        "Model: ",
        comptime attribute.sequence(.reset) ++ role.sequence(.warning) ++
            "anthropic-plan/none" ++ role.sequence(.muted),
        " · Effort: ",
        "xhigh",
    });
    try expectHides(painted, &.{ "claude-opus-4-8", "signed out" });
}

test "an unknown context window shows the tokens with no share" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.context_window = null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{"Context: 206k"});
    try expectHides(painted, &.{ "Context: 21%", "206k/1.0M" });
}

test "quota windows show the used share, labeled by length" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.directory = "";
    info.model = "gpt-5.6-sol";
    info.account = .openai_plan;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 160, &out);

    const painted = out.written();
    try expectShows(painted, &.{ "5h: 12% (53m)", "Week: 74% (6d)" });
    try expectHides(painted, &.{" · Context:"});
}

test "the shortest window prints first, whatever slot carries it" {
    var buffer: [512]u8 = undefined;
    var line: Line = .init(&buffer);
    var info = test_info;
    info.quota = .{
        .primary = .{ .used_percent = 10, .window_minutes = 10080, .reset_seconds = 580_769 },
        .secondary = .{ .used_percent = 4, .window_minutes = 300, .reset_seconds = 8600 },
    };

    try writeLeft(&line, &info, &Parts.all);
    const written = line.text();
    const short = std.mem.indexOf(u8, written, "5h: 4% (2h)").?;
    const long = std.mem.indexOf(u8, written, "Week: 10% (6d)").?;
    try std.testing.expect(short < long);
}

test "unidentified quota windows stay hidden beside a known window" {
    var buffer: [512]u8 = undefined;
    var line: Line = .init(&buffer);
    var info = test_info;
    info.quota = .{
        .primary = .{ .used_percent = 77, .window_minutes = 10080 },
        .secondary = .{ .used_percent = 0 },
    };

    try writeLeft(&line, &info, &Parts.all);
    const written = line.text();
    try std.testing.expect(std.mem.indexOf(u8, written, "Week: 77% · Cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "0%") == null);
    try std.testing.expect(quotaLabel(null) == null);
    try std.testing.expect(quotaLabel(600) == null);
}

test "the credit pool shows the remaining amount while a turn runs" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = .openrouter_api_key;
    info.quota = null;
    info.credits = .{ .total = 10, .used = 2.864085024 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);
    try expectShows(out.written(), &.{ "Cost: ~$0.39", "Credits: $7.14", "Cache: 87%" });

    var idle = info;
    idle.turn_active = false;
    var idle_out: std.Io.Writer.Allocating = .init(gpa);
    defer idle_out.deinit();
    try renderForTest(gpa, &idle, 200, &idle_out);
    try expectHides(idle_out.written(), &.{"Credits:"});
}

test "the summary states the credit pool of a running turn" {
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = .openrouter_api_key;
    info.quota = null;
    info.credits = .{ .total = 10, .used = 2.864085024 };
    try expectSummary(
        "~/github/clebert/drinky (main) · Context: 21% (206k/1.0M) · Cost: ~$0.39 · " ++
            "Credits: $7.14 · Cache: 87% · Model: openrouter-api-key/openai/gpt-5.6-sol · " ++
            "Effort: xhigh",
        &info,
    );
}

test "a sub-cent credit pool never reads as an empty one" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = .openrouter_api_key;
    info.quota = null;
    info.credits = .{ .total = 0.02, .used = 0.015 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);
    try expectShows(out.written(), &.{"Credits: <$0.01"});
}

test "the credit pool takes no color at any used share" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = .openrouter_api_key;
    info.quota = null;
    for ([_]ai.llm.Credits{
        .{ .total = 10, .used = 9 },
        .{ .total = 1, .used = 2 },
        .{ .total = 0, .used = 0 },
    }) |credits| {
        info.credits = credits;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try renderForTest(gpa, &info, 200, &out);
        try expectShows(out.written(), &.{"Credits: $"});
        try expectNoColor(out.written());
    }
}

test "a narrow window drops the credit pool before the session cost" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.model = "openai/gpt-5.6-sol";
    info.account = .openrouter_api_key;
    info.quota = null;
    info.credits = .{ .total = 10, .used = 2.86 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 127, &out);
    try expectShows(out.written(), &.{ "Cost: ~$0.39", "Credits: $7.14" });
    try expectHides(out.written(), &.{"Cache:"});

    var out2: std.Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    try renderForTest(gpa, &info, 117, &out2);
    try expectShows(out2.written(), &.{ "~/…/drinky (main)", "Context: 21%", "Cost: ~$0.39" });
    try expectHides(out2.written(), &.{ "Credits:", "Cache:" });
}

test writeWait {
    const cases = [_]struct { seconds: u64, shown: []const u8 }{
        .{ .seconds = 0, .shown = "1m" },
        .{ .seconds = 59, .shown = "1m" },
        .{ .seconds = 60, .shown = "1m" },
        .{ .seconds = 3599, .shown = "59m" },
        .{ .seconds = 3600, .shown = "1h" },
        .{ .seconds = 86_399, .shown = "23h" },
        .{ .seconds = 86_400, .shown = "1d" },
        .{ .seconds = 580_769, .shown = "6d" },
    };
    for (cases) |case| {
        var buffer: [16]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try writeWait(&out, case.seconds);
        try std.testing.expectEqualStrings(case.shown, out.buffered());
    }
}

test waitSeconds {
    try std.testing.expectEqual(@as(?u64, 3180), waitSeconds(3180, 0));
    try std.testing.expectEqual(@as(?u64, 3120), waitSeconds(3180, 60_000));
    try std.testing.expect(waitSeconds(null, 0) == null);
    try std.testing.expect(waitSeconds(60, 60_000) == null);
    try std.testing.expect(waitSeconds(60, 600_000) == null);
    try std.testing.expectEqual(@as(?u64, 60), waitSeconds(60, -600_000));
}

test "the quota and the cache rate show while a turn runs alone" {
    const gpa = std.testing.allocator;
    var idle = test_info;
    idle.turn_active = false;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &idle, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{ "~/github/clebert/drinky (main)", "Context: 21%", "Cost: ~$0.39" });
    try expectHides(painted, &.{ "5h:", "Week:", "Cache:" });
}

test "a running turn hides the cache, quota, and credits until this turn reports them" {
    var info = test_info;
    info.cache_usage = .{};
    info.quota = null;
    info.credits = null;
    try expectSummary(
        "~/github/clebert/drinky (main) · Context: 21% (206k/1.0M) · Cost: ~$0.39 · " ++
            "Model: anthropic-plan/claude-opus-4-8 · Effort: xhigh",
        &info,
    );
}

test "a countdown that runs out drops its bracket and keeps its share" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.quota = .{
        .primary = .{ .used_percent = 12, .window_minutes = 300, .reset_seconds = 3180 },
        .secondary = null,
    };
    info.quota_age_ms = 3_600_000;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{"5h: 12% · Cache"});
    try expectHides(painted, &.{"(53m)"});
}
