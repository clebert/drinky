//! The bottom status line. It shows the working directory with its branch, then
//! the session numbers, on the left. It shows the model, account, and effort on
//! the right. A notice temporarily replaces the line. The renderer uses a
//! caller-built `Info` snapshot.
//!
//! A narrow window first shortens fields in one fixed order. It then removes
//! complete parts in another fixed order. The context gauge never goes.
//!
//! The line paints muted. Two kinds of field leave that role. A gauge takes a
//! color when it fills past a threshold, and an identity field takes the normal
//! intensity. Color means pressure. Intensity means identity. A notice takes the
//! role of its severity, and an information notice takes the normal intensity.

const std = @import("std");

const ai = @import("ai");
const terminal = @import("terminal");

const attribute = @import("attribute.zig");
const paint = @import("paint.zig");
const role = @import("role.zig");

pub const Info = struct {
    /// The working directory, with the home directory written as `~`. The caller
    /// keeps it short, at most `directory_bytes_max`, because the line shows an
    /// identity and not a whole path. Empty hides the directory and its branch.
    directory: []const u8,
    /// The branch of the repository, or null outside one and for a head that
    /// Drinky could not read. The caller bounds it at `ai.project.head_name_bytes_max`.
    branch: ?[]const u8,
    /// The conversation context the last committed reply measured. Null shows
    /// the unknown form, which happens before the first reply and after a
    /// change that renders the same history in another way.
    context_tokens: ?u64,
    /// The prompt usage of the last request under the active cache key. An
    /// all-zero prompt hides the cache rate.
    cache_usage: ai.llm.Usage,
    cost: f64,
    context_window: u64,
    model: []const u8,
    effort: []const u8,
    /// The active account. Null shows "Account: Signed out" instead of the
    /// model, account, and effort.
    account: ?ai.llm.Account,
    /// A subscription's allowance, or null when the active provider reports
    /// none (an API key, or a non-subscription turn). Each window whose duration
    /// identifies it shows on the left as `<label>: N% (<wait>)`.
    quota: ?ai.llm.Quota,
    /// The time since the response that carried the quota. The reset of a
    /// window ages with that response, so the line subtracts this to show the
    /// wait that is left now.
    quota_age_ms: i64,
    /// Whether a turn runs. The quota and the cache rate each measure one
    /// request, so both show while a turn runs and go when it ends. An idle
    /// Drinky paints no frame, which freezes a countdown on the screen. The
    /// share is no safer: another agent on the same account spends the same
    /// allowance, so an idle number can read too low, and it reads too high
    /// once the window starts again. Only a response head states the truth.
    turn_active: bool,
    /// A temporary notice replaces this footer until the next user action.
    notice: ?Notice = null,

    pub const Notice = struct {
        text: []const u8,
        severity: ai.command.Outcome.Severity,
    };
};

/// The longest directory the caller passes. It bounds the left scratch buffer,
/// so the whole line always fits and the writer can never fail.
pub const directory_bytes_max = 96;

/// The right-side indicator shown while no account is active.
const signed_out_label = "Account: Signed out";

const account_open = " (";
const account_close = ")";

/// Separates one part of the line from the next.
const separator = " · ";

/// The compact branch keeps at most this many display columns before its mark.
const branch_prefix_columns_max = 16;

/// A gauge that fills to this share of its limit takes the warning color, and
/// one that fills to `pressure_percent_error` takes the error color. A gauge
/// below the warning share keeps the muted role, so a color on this line always
/// means pressure. The shares are compiled, because no evidence supports one
/// number over another and a configurable pair helps nobody yet.
const pressure_percent_warning: f64 = 75;
const pressure_percent_error: f64 = 90;

/// The parts the line shows. `all` is what a wide window gets. Each reduction
/// selects a shorter form or removes one complete part.
const Parts = struct {
    place: Place,
    branch: Branch,
    context: Context,
    quota_wait: bool,
    cost: bool,
    quota_short: bool,
    quota_long: bool,
    cache: bool,
    account: bool,
    effort: bool,

    /// The directory: whole, its last component alone, or gone with its branch.
    const Place = enum { full, short, hidden };

    /// The branch: whole, its first bounded prefix with an ellipsis, or gone. A
    /// bracketed detail goes before the head that carries it, so the branch goes
    /// while the directory stays.
    const Branch = enum { full, short, hidden };

    /// The context gauge: with its token counts, or the percentage alone. An
    /// unknown measurement has one form. The gauge has no hidden form, because
    /// the fill of the window drives what the user does next.
    const Context = enum { full, short };

    const all: Parts = .{
        .place = .full,
        .branch = .full,
        .context = .full,
        .quota_wait = true,
        .cost = true,
        .quota_short = true,
        .quota_long = true,
        .cache = true,
        .account = true,
        .effort = true,
    };
};

/// Shorten each field before any complete part goes. The measurements of one
/// request go next, longest window first, because they leave the line when the
/// turn ends anyway. The session cost outlives them, so a narrow line holds the
/// same numbers whether a turn runs or not. Each side then gives up its
/// bracketed detail before the head that carries it: the account, then the
/// branch, then the place. The effort goes last.
const reductions = [_]Reduction{
    .shorten_directory,
    .shorten_branch,
    .shorten_context,
    .shorten_quota,
    .drop_cache,
    .drop_quota_long,
    .drop_quota_short,
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
        .drop_account => parts.account = false,
        .drop_branch => parts.branch = .hidden,
        .drop_place => parts.place = .hidden,
        .drop_effort => parts.effort = false,
    }
}

/// One painted run of a line: the bytes from `start` to `end`, and the role that
/// paints them. A line is muted outside every run.
const Run = struct { start: usize, end: usize, name: role.Name };

/// The runs one side can hold: the context gauge and the two quota windows on
/// the left, the model and the effort value on the right.
const runs_max = 3;

/// One side of the line under construction: its bytes, and the runs that leave
/// the muted role. A field marks its own run after it writes, so a field that
/// shortens or goes away needs no separate accounting.
///
/// A function that writes a whole field takes the line. A function that formats
/// one fragment, such as a token count, takes the writer alone and can mark
/// nothing.
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

    /// Paint the bytes from `start` to the end of the line with `name`. A muted
    /// field records nothing, because the whole line already paints muted. A
    /// line with no run left keeps the field muted, so one field more than
    /// `runs_max` loses a color and never writes past the array.
    fn mark(self: *Line, start: usize, name: role.Name) void {
        if (name == .muted or self.count == self.runs.len) return;
        self.runs[self.count] = .{ .start = start, .end = self.offset(), .name = name };
        self.count += 1;
    }

    fn marked(self: *const Line) []const Run {
        return self.runs[0..self.count];
    }
};

/// The role a gauge takes at `used_percent`. A gauge below the warning share
/// keeps the muted role of the line, so a color always means pressure.
///
/// The caller passes the used share that the printed number implies, not the
/// measured share. Two rows that print one number then always take one color,
/// and the color never contradicts the number beside it.
fn pressureRole(used_percent: f64) role.Name {
    if (used_percent >= pressure_percent_error) return .@"error";
    if (used_percent >= pressure_percent_warning) return .warning;
    return .muted;
}

/// Paint `kept` of `line`: each run in its own role, and the muted role around
/// them. A run opens with the reset, because the muted role holds the faint
/// intensity that an identity field must drop. The runs come in write order, so
/// they never overlap, and a cut drops a whole run or its tail alone.
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

/// Stream the status line through `placement`. Put the place and the session
/// numbers on the left, and the agent on the right. Reduce the parts until both
/// sides fit. When even the reduced line is too wide, show the truncated left,
/// because the context gauge outranks every other part.
pub fn render(placement: *const paint.Placement, info: *const Info) !void {
    if (placement.base < placement.skip) return;
    if (info.notice) |notice| {
        // An information notice takes the text role, not the muted role of the
        // line. The row must read as a new message and not as the status it
        // replaces. A warning and a failure carry their own color already.
        const name: role.Name = switch (notice.severity) {
            .information => .text,
            .warning => .warning,
            .failure => .@"error",
        };
        const prefix = if (notice.severity == .failure) "Error: " else "";
        // The footer keeps one row, because a footer that grows moves the editor,
        // and a moving interface is worse than a cut sentence.
        return paint.notice(
            placement,
            &.{ .role = name, .prefix = prefix, .fit = .head },
            notice.text,
        );
    }

    // Sized so `catch unreachable` is sound. The branch can fill one bounded
    // `HEAD` file. The remaining space holds the directory and every number.
    // The compiled tables bound the model name and the account label.
    var left_scratch: [ai.project.head_name_bytes_max + 512]u8 = undefined;
    var right_scratch: [192]u8 = undefined;
    var parts: Parts = .all;
    // The loop always runs, so it writes both sides before any read.
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

/// The agent: `model (account) · Effort: level`, or the signed-out indicator.
/// Each part carries its own label, so a part that goes away never leaves a bare
/// value behind. The model and the effort level are the two settings the user
/// changes, so both values take the normal intensity. The label and the
/// bracketed account stay muted.
fn writeRight(line: *Line, info: *const Info, parts: *const Parts) !void {
    const account = info.account orelse return line.out.writeAll(signed_out_label);
    const model_start = line.offset();
    try line.out.writeAll(info.model);
    line.mark(model_start, .text);
    if (parts.account) {
        try line.out.writeAll(account_open);
        try line.out.writeAll(account.label());
        try line.out.writeAll(account_close);
    }
    if (parts.effort) {
        try line.out.writeAll(separator);
        try line.out.writeAll("Effort: ");
        const effort_start = line.offset();
        try line.out.writeAll(info.effort);
        line.mark(effort_start, .text);
    }
}

/// The place and the session numbers. The context gauge always comes, so every
/// later part can carry its own leading separator.
fn writeLeft(line: *Line, info: *const Info, parts: *const Parts) !void {
    if (parts.place != .hidden and info.directory.len > 0) {
        try writePlace(line, info, parts);
        try line.out.writeAll(separator);
    }
    try writeContext(line, info, parts.context);
    if (parts.cost) {
        // Session cost uses public API rates. It is an estimate because the login
        // type does not reveal billing.
        try line.out.print("{s}Cost: ${d:.2}", .{ separator, info.cost });
    }
    // The quota and the cache rate each measure one request, so they belong to
    // a running turn alone. A spent OpenAI subscription still names its plan and
    // its wait in the failure message of the turn.
    if (!info.turn_active) return;
    if (info.quota) |quota| {
        const windows = orderedWindows(&quota);
        if (parts.quota_short) try writeQuotaPart(line, &windows[0], info, parts);
        if (parts.quota_long) try writeQuotaPart(line, &windows[1], info, parts);
    }
    if (parts.cache) try writeCache(line, info);
}

/// The windows of `quota`, shortest first, and null for a window the line
/// cannot label. The slots of the head carry no fixed window, so the length
/// orders the line and one account never reads in another order than the next.
fn orderedWindows(quota: *const ai.llm.Quota) [2]?ai.llm.Quota.Window {
    const maybe_first = labeledWindow(&quota.primary);
    const maybe_second = labeledWindow(&quota.secondary);
    const first = maybe_first orelse return .{ maybe_second, null };
    const second = maybe_second orelse return .{ first, null };
    if (windowMinutes(&second) < windowMinutes(&first)) return .{ second, first };
    return .{ first, second };
}

/// The length of a labeled window. `labeledWindow` passes a window whose length
/// identifies it, so the fallback never orders a line.
fn windowMinutes(window: *const ai.llm.Quota.Window) u32 {
    return window.window_minutes orelse 0;
}

/// `maybe_window` when its duration identifies it, and null otherwise. A window
/// that Drinky cannot name states an allowance that the user cannot act on.
fn labeledWindow(maybe_window: *const ?ai.llm.Quota.Window) ?ai.llm.Quota.Window {
    const window = maybe_window.* orelse return null;
    if (quotaLabel(window.window_minutes) == null) return null;
    return window;
}

/// Write one window of the ordered pair, with the wait that the parts allow.
/// An absent window writes nothing, so a provider that states one window alone
/// leaves no gap behind.
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
    try writeQuotaWindow(line, &window, wait_seconds);
}

/// The working directory, and the branch that a command here acts on. A
/// path names itself, so it takes no label. The branch follows it in brackets,
/// the same shape the agent takes on the right.
fn writePlace(line: *Line, info: *const Info, parts: *const Parts) !void {
    try writeDirectory(&line.out, info.directory, parts.place);
    if (parts.branch == .hidden) return;
    if (info.branch) |branch| {
        try line.out.writeAll(" (");
        try writeBranch(&line.out, branch, parts.branch);
        try line.out.writeByte(')');
    }
}

/// The short form keeps the last component alone, behind a `…/` mark and the home
/// `~` that the path carries. A path that the mark does not shorten stays whole,
/// so shortening never costs columns.
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

/// The short form keeps a bounded prefix and adds an ellipsis. A branch stays
/// whole when the marked form does not save columns. The prefix ends at a
/// grapheme boundary.
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

/// Context now: what the last committed reply measured, against the model's
/// window. The one "now" number. The rest is session-cumulative. A model switch
/// leaves no valid measurement, because a tokenizer belongs to its model.
fn writeContext(line: *Line, info: *const Info, form: Parts.Context) !void {
    const context = info.context_tokens orelse return line.out.writeAll("Context: Unknown");
    const percent = if (info.context_window > 0)
        asFloat(context) / asFloat(info.context_window) * 100.0
    else
        0.0;
    // The line prints the rounded share and colors that same number, so a row
    // never shows one figure and the color of another.
    const shown = @round(percent);
    const start = line.offset();
    try line.out.print("Context: {d:.0}%", .{shown});
    if (form == .full) {
        try line.out.writeAll(" (");
        try writeTokens(&line.out, context);
        try line.out.writeByte('/');
        try writeTokens(&line.out, info.context_window);
        try line.out.writeByte(')');
    }
    line.mark(start, pressureRole(shown));
}

/// The last request's cache hit rate over the whole prompt. An all-zero prompt
/// means no measurement describes the active account, model, and effort, so the
/// part goes rather than show a 0/0 rate.
fn writeCache(line: *Line, info: *const Info) !void {
    const usage = &info.cache_usage;
    const prompt = usage.input +| usage.cache_read +| usage.cache_write;
    if (prompt == 0) return;
    const hit = asFloat(usage.cache_read) / asFloat(prompt) * 100.0;
    try line.out.print("{s}Cache: {d:.0}%", .{ separator, hit });
}

/// Append one identified quota window as ` · <label>: N% (<wait>)`, or nothing
/// for an absent one. The used share drives the number and the color, so the
/// allowance and the context window read the same way. The bracket holds the
/// wait until the window starts again, the one figure the user cannot derive.
fn writeQuotaWindow(
    line: *Line,
    window: *const ai.llm.Quota.Window,
    wait_seconds: ?u64,
) !void {
    const label = quotaLabel(window.window_minutes) orelse return;
    const used = @round(@max(0.0, @min(100.0, window.used_percent)));
    try line.out.writeAll(separator);
    const start = line.offset();
    try line.out.print("{s}: {d:.0}%", .{ label, used });
    if (wait_seconds) |seconds| {
        try line.out.writeAll(" (");
        try writeWait(&line.out, seconds);
        try line.out.writeByte(')');
    }
    line.mark(start, pressureRole(used));
}

/// The seconds left on a window that stated `reset_seconds` when its response
/// arrived `age_ms` ago. Null when the head stated no reset, and null once the
/// wait has run out, because the next response states the window that follows.
fn waitSeconds(reset_seconds: ?u64, age_ms: i64) ?u64 {
    const reset = reset_seconds orelse return null;
    const age = @max(0, age_ms);
    const left = reset -| @as(u64, @intCast(@divFloor(age, std.time.ms_per_s)));
    return if (left == 0) null else left;
}

/// A wait in one unit: minutes below an hour, hours below a day, then days. It
/// rounds down, so the user checks a little early. A value that rounds down to
/// nothing still reads as `1m`, because the window is still closed.
fn writeWait(out: *std.Io.Writer, seconds: u64) !void {
    const minute = 60;
    const hour = 60 * minute;
    const day = 24 * hour;
    if (seconds < hour) return out.print("{d}m", .{@max(1, @divFloor(seconds, minute))});
    if (seconds < day) return out.print("{d}h", .{@divFloor(seconds, hour)});
    return out.print("{d}d", .{@divFloor(seconds, day)});
}

/// A compact label for a rolling window, keyed off its length in minutes. Both
/// subscription backends use a 5h and a weekly window. Unrecognized or absent
/// lengths stay hidden rather than show as an allowance we cannot identify.
fn quotaLabel(maybe_minutes: ?u32) ?[]const u8 {
    const minutes = maybe_minutes orelse return null;
    if (approxWindow(minutes, 300)) return "5h";
    if (approxWindow(minutes, 10080)) return "Week";
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

/// The full set of parts, so a test can watch the line give them up.
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
    .account = .anthropic_subscription,
    .quota = .{
        .primary = .{ .used_percent = 11.6, .window_minutes = 300, .reset_seconds = 3180 },
        .secondary = .{ .used_percent = 73.6, .window_minutes = 10080, .reset_seconds = 580_769 },
    },
    .quota_age_ms = 0,
    .turn_active = true,
};

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

test render {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &test_info, 200, &out);

    const painted = out.written();
    // The place and the agent read as the same shape: a thing, and the context
    // it belongs to.
    try expectShows(painted, &.{
        "~/github/clebert/drinky (main)",
        "Context: 21% (206k/1.0M)",
        "Cost: $0.39",
        // The shortest window prints first, each with the share it used and the
        // wait until it starts again.
        "5h: 12% (53m) · Week: 74% (6d)",
        "Cache: 87%",
        // The model and the effort value carry their own intensity, so a style
        // sequence sits between them and the muted text around them.
        "claude-opus-4-8",
        " (Anthropic Subscription) · Effort: ",
        "xhigh",
    });
    // The place anchors the left, and the agent anchors the right.
    const place = std.mem.indexOf(u8, painted, "~/github").?;
    const context = std.mem.indexOf(u8, painted, "Context:").?;
    try std.testing.expect(place < context);
    try std.testing.expect(context < std.mem.indexOf(u8, painted, "claude-opus-4-8").?);
}

// The two gauges answer different questions, so an absent measurement reads
// differently. The fill of the window drives what the user does next, so the
// gauge names the gap instead of showing a number it does not have. The rate is
// a secondary number that a narrow window drops first, so it just goes.
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

    // Empty history is a measurement, not a gap: it holds exactly zero tokens.
    var empty = test_info;
    empty.context_tokens = 0;
    var empty_out: std.Io.Writer.Allocating = .init(gpa);
    defer empty_out.deinit();
    try renderForTest(gpa, &empty, 200, &empty_out);
    try expectShows(empty_out.written(), &.{"Context: 0% (0/1.0M)"});

    // The gauge outranks every other part, so it survives the narrowest window.
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
    }{
        .{
            // The directory shortens before any complete part goes.
            .columns = 165,
            .shows = &.{ "~/…/drinky (main)", "Context: 21% (206k/1.0M)", "Cache: 87%" },
            .hides = &.{"~/github"},
        },
        .{
            // The context gauge shortens before any complete part goes.
            .columns = 150,
            .shows = &.{ "Context: 21%", "5h: 12% (53m)", "Week: 74% (6d)", "Cache: 87%" },
            .hides = &.{"(206k/1.0M)"},
        },
        .{
            // Both countdowns go together, so the two windows always read alike.
            .columns = 140,
            .shows = &.{ "Cost: $0.39", "5h: 12%", "Week: 74%", "Cache: 87%" },
            .hides = &.{ "(53m)", "(6d)" },
        },
        .{
            .columns = 130,
            .shows = &.{ "Cost: $0.39", "5h: 12%", "Week: 74%" },
            .hides = &.{"Cache:"},
        },
        .{
            // The longest window goes first.
            .columns = 115,
            .shows = &.{ "Cost: $0.39", "5h: 12%" },
            .hides = &.{ "Week:", "Cache:" },
        },
        .{
            // The session cost outlives every measurement of one request.
            .columns = 105,
            .shows = &.{ "~/…/drinky (main)", "Cost: $0.39", "Anthropic Subscription" },
            .hides = &.{ "5h:", "Week:", "Cache:" },
        },
        .{
            .columns = 80,
            .shows = &.{ "~/…/drinky (main)", "claude-opus-4-8", "Effort: " },
            .hides = &.{ "Anthropic Subscription", "Cost:" },
        },
        .{
            // The branch is a detail of the place, so it goes while the
            // directory stays.
            .columns = 60,
            .shows = &.{ "~/…/drinky · Context: 21%", "claude-opus-4-8", "Effort: " },
            .hides = &.{"(main)"},
        },
        .{
            .columns = 40,
            .shows = &.{ "Context: 21%", "claude-opus-4-8" },
            .hides = &.{ "drinky", "Effort:" },
        },
    };

    for (steps) |step| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try renderForTest(gpa, &test_info, step.columns, &out);
        const painted = out.written();
        try expectShows(painted, step.shows);
        try expectHides(painted, step.hides);
        // A part goes away whole. Its label and value always go together.
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
        // Below the width of the gauge itself only the cut is left, and the
        // percentage is what it cuts toward. The mark states that cut, and it
        // takes the last column of the row.
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
    // Each gauge sits on its own edge: 75% used takes the warning color, 90%
    // used takes the error color, and 74% used takes neither.
    info.context_tokens = 750_000;
    info.quota = .{
        .primary = .{ .used_percent = 90, .window_minutes = 300 },
        .secondary = .{ .used_percent = 74, .window_minutes = 10080 },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    // The color covers the whole field, so the label and the bracket carry it
    // too. The two gauges use one rule, and each one names its own fill.
    const painted = out.written();
    try expectShows(painted, &.{
        comptime role.sequence(.warning) ++ "Context: 75% (750k/1.0M)",
        comptime role.sequence(.@"error") ++ "5h: 90%",
    });
    // The weekly window stays under the warning share, so it keeps the muted
    // role of the line.
    try expectHides(painted, &.{
        comptime role.sequence(.warning) ++ "Week:",
        comptime role.sequence(.@"error") ++ "Week:",
    });
}

test "the color follows the share that the line prints" {
    const gpa = std.testing.allocator;
    var info = test_info;
    // The measured shares stay under both thresholds. The printed shares reach
    // them, so the row and its color must agree with the printed number.
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
        comptime role.sequence(.warning) ++ "Context: 75%",
        comptime role.sequence(.@"error") ++ "5h: 90%",
    });
}

test "the model and the effort value leave the faint intensity" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &test_info, 200, &out);

    // The reset opens each identity field, because the muted role holds the
    // faint intensity. The muted role closes it again.
    const painted = out.written();
    const reset = comptime attribute.sequence(.reset);
    const muted = comptime role.sequence(.muted);
    try expectShows(painted, &.{
        reset ++ "claude-opus-4-8" ++ muted,
        reset ++ "xhigh" ++ muted,
    });
    // The label and the account keep the muted role of the line.
    try expectHides(painted, &.{ reset ++ "Effort", reset ++ " (Anthropic" });
}

test "a cut keeps the color of the run it lands in" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.context_tokens = 950_000;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 10, &out);

    // Nine columns of the gauge stay, and the mark of the cut takes the last
    // column. The mark belongs to the line, so it paints muted.
    const painted = out.written();
    try expectShows(painted, &.{
        comptime role.sequence(.@"error") ++ "Context: ",
        comptime role.sequence(.muted) ++ paint.ellipsis,
    });
}

test "shortening the directory never costs columns" {
    const gpa = std.testing.allocator;
    var info = test_info;
    // The mark and the home prefix cost more than this path spends on its own
    // components, so the short form must not replace it.
    info.directory = "~/a";
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 80, &out);

    const painted = out.written();
    try expectShows(painted, &.{"~/a (main)"});
    try expectHides(painted, &.{"…"});

    // A path with no home prefix pays for the mark alone, and one component is
    // still not worth it.
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
    // Eight flags put this valid branch above the old 64-byte limit. Four flags
    // fill the compact prefix after `feature/` without splitting a flag.
    info.branch = "feature/" ++ "🇩🇪" ** 8;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // The width that the shortened branch needs, and one column less than the
    // whole branch needs.
    try renderForTest(gpa, &info, 174, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        "~/…/drinky (feature/" ++ "🇩🇪" ** 4 ++ "…)",
        "Context: 21% (206k/1.0M)",
        "Cost: $0.39",
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
    // The row keeps the first line, and the mark states the line it hides.
    try expectShows(painted, &.{ "Error: ", "boom" ++ paint.ellipsis });
    try expectHides(painted, &.{ "not another row", "hidden-model" });
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, painted, "\r\n"));
}

test "a warning notice uses the warning role without an error label" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.notice = .{ .text = "Enter: Send anyway", .severity = .warning };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 40, &out);

    const painted = out.written();
    try expectShows(painted, &.{"Enter: Send anyway"});
    try expectHides(painted, &.{"Error:"});
    try std.testing.expect(std.mem.indexOf(
        u8,
        painted,
        comptime role.sequence(.warning),
    ) != null);
}

test "an information notice reads at the normal intensity" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.notice = .{ .text = "Drinky loaded every queued message.", .severity = .information };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 40, &out);

    const painted = out.written();
    try expectShows(painted, &.{"Drinky loaded every queued message."});
    try expectHides(painted, &.{"Error:"});
    // The muted role belongs to the line that the notice replaces. The row drops
    // it, so a notice never reads as the status behind it.
    try std.testing.expect(std.mem.indexOf(
        u8,
        painted,
        comptime role.sequence(.muted),
    ) == null);
}

test "a signed-out status shows the indicator in place of the model" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.account = null;
    info.cache_usage = .{};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 120, &out);

    const painted = out.written();
    try expectShows(painted, &.{"Account: Signed out"});
    // No prompt tokens sent yet: the cache figure is absent, never a 0/0 rate.
    try expectHides(painted, &.{ "claude-opus-4-8", "Effort:", "Cache" });
}

test "quota windows show the used share, labeled by length" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.directory = "";
    info.model = "gpt-5.6-sol";
    info.account = .openai_subscription;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 160, &out);

    const painted = out.written();
    try expectShows(painted, &.{ "5h: 12% (53m)", "Week: 74% (6d)" });
    // An empty directory hides the whole place, separator and all.
    try expectHides(painted, &.{" · Context:"});
}

test "the shortest window prints first, whatever slot carries it" {
    var buffer: [512]u8 = undefined;
    var line: Line = .init(&buffer);
    var info = test_info;
    // The head of a real account carried the weekly window in the primary slot.
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
    // The weekly window keeps its place, and it shows no bracket because the
    // head stated no reset.
    try std.testing.expect(std.mem.indexOf(u8, written, "Week: 77% · Cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "0%") == null);
    try std.testing.expect(quotaLabel(null) == null);
    try std.testing.expect(quotaLabel(600) == null);
}

test writeWait {
    const cases = [_]struct { seconds: u64, shown: []const u8 }{
        // A window that is still closed never reads as no wait at all.
        .{ .seconds = 0, .shown = "1m" },
        .{ .seconds = 59, .shown = "1m" },
        .{ .seconds = 60, .shown = "1m" },
        .{ .seconds = 3599, .shown = "59m" },
        .{ .seconds = 3600, .shown = "1h" },
        .{ .seconds = 86_399, .shown = "23h" },
        .{ .seconds = 86_400, .shown = "1d" },
        // The reset that a real weekly window stated.
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
    // The wait ages with the response that stated it.
    try std.testing.expectEqual(@as(?u64, 3180), waitSeconds(3180, 0));
    try std.testing.expectEqual(@as(?u64, 3120), waitSeconds(3180, 60_000));
    // A head that stated no reset shows no wait, and neither does a window that
    // has already started again.
    try std.testing.expect(waitSeconds(null, 0) == null);
    try std.testing.expect(waitSeconds(60, 60_000) == null);
    try std.testing.expect(waitSeconds(60, 600_000) == null);
    // A clock that steps back never lengthens a wait.
    try std.testing.expectEqual(@as(?u64, 60), waitSeconds(60, -600_000));
}

test "the quota and the cache rate show while a turn runs alone" {
    const gpa = std.testing.allocator;
    var idle = test_info;
    idle.turn_active = false;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &idle, 200, &out);

    // Both measure one request. The place, the context gauge, and the session
    // cost describe a state that outlives the turn, so they stay.
    const painted = out.written();
    try expectShows(painted, &.{ "~/github/clebert/drinky (main)", "Context: 21%", "Cost: $0.39" });
    try expectHides(painted, &.{ "5h:", "Week:", "Cache:" });
}

test "a countdown that runs out drops its bracket and keeps its share" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.quota = .{
        .primary = .{ .used_percent = 12, .window_minutes = 300, .reset_seconds = 3180 },
        .secondary = null,
    };
    // The response that stated the reset is one hour old, so the 53-minute wait
    // has run out. The share still describes the last measured request.
    info.quota_age_ms = 3_600_000;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 200, &out);

    const painted = out.written();
    try expectShows(painted, &.{"5h: 12% · Cache"});
    try expectHides(painted, &.{"(53m)"});
}
