//! The bottom status line. It shows the working directory with its branch, then
//! the session numbers, on the left. It shows the model, account, and effort on
//! the right. A notice temporarily replaces the line. The renderer uses a
//! caller-built `Info` snapshot.
//!
//! A narrow window first shortens fields in one fixed order. It then removes
//! complete parts in another fixed order. The context percentage never goes.

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
    /// Pith could not read. The caller bounds it at `ai.project.head_name_bytes_max`.
    branch: ?[]const u8,
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

/// The parts the line shows. `all` is what a wide window gets. Each reduction
/// selects a shorter form or removes one complete part.
const Parts = struct {
    place: Place,
    branch: Branch,
    context: Context,
    cost: bool,
    quota_primary: bool,
    quota_secondary: bool,
    cache: bool,
    account: bool,
    effort: bool,

    /// The directory: whole, its last component alone, or gone with its branch.
    const Place = enum { full, short, hidden };

    /// The branch: whole, or its first bounded prefix with an ellipsis.
    const Branch = enum { full, short };

    /// The context gauge: with its token counts, or the percentage alone. It has
    /// no hidden form, because the fill of the window drives what the user does
    /// next.
    const Context = enum { full, short };

    const all: Parts = .{
        .place = .full,
        .branch = .full,
        .context = .full,
        .cost = true,
        .quota_primary = true,
        .quota_secondary = true,
        .cache = true,
        .account = true,
        .effort = true,
    };
};

/// Shorten each field before any complete part goes. The cache rate goes first
/// after that. The cost goes before either quota because an allowance is a hard
/// stop. The account, place, and effort go after all session numbers.
const reductions = [_]Reduction{
    .shorten_directory,
    .shorten_branch,
    .shorten_context,
    .drop_cache,
    .drop_cost,
    .drop_quota_secondary,
    .drop_quota_primary,
    .drop_account,
    .drop_place,
    .drop_effort,
};

const Reduction = enum {
    shorten_directory,
    shorten_branch,
    shorten_context,
    drop_cache,
    drop_cost,
    drop_quota_secondary,
    drop_quota_primary,
    drop_account,
    drop_place,
    drop_effort,
};

fn reduce(parts: *Parts, reduction: Reduction) void {
    switch (reduction) {
        .shorten_directory => parts.place = .short,
        .shorten_branch => parts.branch = .short,
        .shorten_context => parts.context = .short,
        .drop_cache => parts.cache = false,
        .drop_cost => parts.cost = false,
        .drop_quota_secondary => parts.quota_secondary = false,
        .drop_quota_primary => parts.quota_primary = false,
        .drop_account => parts.account = false,
        .drop_place => parts.place = .hidden,
        .drop_effort => parts.effort = false,
    }
}

/// Stream the status line through `placement`. Put the place and the session
/// numbers on the left, and the agent on the right. Reduce the parts until both
/// sides fit. When even the reduced line is too wide, show the truncated left,
/// because the context gauge outranks every other part.
pub fn render(placement: *const paint.Placement, info: *const Info) !void {
    if (placement.base < placement.skip) return;
    if (info.notice) |notice| {
        const line_end = std.mem.indexOfScalar(u8, notice.text, '\n') orelse notice.text.len;
        const name: role.Name = switch (notice.severity) {
            .information => .muted,
            .warning => .warning,
            .failure => .@"error",
        };
        const prefix = if (notice.severity == .failure) "Error: " else "";
        return paint.notice(
            placement,
            &.{ .role = name, .prefix = prefix },
            notice.text[0..line_end],
        );
    }

    // Sized so `catch unreachable` is sound. The branch can fill one bounded
    // `HEAD` file. The remaining space holds the directory and every number.
    // The compiled tables bound the model name and the account label.
    var left_scratch: [ai.project.head_name_bytes_max + 512]u8 = undefined;
    var right_scratch: [192]u8 = undefined;
    var parts: Parts = .all;
    var left_line: []const u8 = "";
    var right_line: []const u8 = "";
    var left_columns: usize = 0;
    var right_columns: usize = 0;
    for (0..reductions.len + 1) |index| {
        var left: std.Io.Writer = .fixed(&left_scratch);
        var right: std.Io.Writer = .fixed(&right_scratch);
        writeLeft(&left, info, &parts) catch unreachable;
        writeRight(&right, info, &parts) catch unreachable;
        left_line = left.buffered();
        right_line = right.buffered();
        left_columns = terminal.width.ofText(left_line);
        right_columns = terminal.width.ofText(right_line);
        if (left_columns + right_columns + 1 <= placement.columns) break;
        if (index == reductions.len) break;
        reduce(&parts, reductions[index]);
    }

    placement.sink.begin();
    try role.apply(placement.sink, .muted);
    if (left_columns + right_columns + 1 <= placement.columns) {
        try placement.sink.text(left_line);
        try placement.sink.spaces(placement.columns - left_columns - right_columns);
        try placement.sink.text(right_line);
    } else {
        try placement.sink.text(terminal.width.truncate(left_line, placement.columns));
    }
    try attribute.apply(placement.sink, .reset);
    placement.sink.end(.{ .id = placement.id, .line = placement.base });
}

/// The agent: `model (account) · Effort: level`, or the signed-out indicator.
/// Each part carries its own label, so a part that goes away never leaves a bare
/// value behind.
fn writeRight(out: *std.Io.Writer, info: *const Info, parts: *const Parts) !void {
    const account = info.account orelse return out.writeAll(signed_out_label);
    try out.writeAll(info.model);
    if (parts.account) {
        try out.writeAll(account_open);
        try out.writeAll(account.label());
        try out.writeAll(account_close);
    }
    if (parts.effort) {
        try out.writeAll(separator);
        try out.print("Effort: {s}", .{info.effort});
    }
}

/// The place and the session numbers. The context gauge always comes, so every
/// later part can carry its own leading separator.
fn writeLeft(out: *std.Io.Writer, info: *const Info, parts: *const Parts) !void {
    if (parts.place != .hidden and info.directory.len > 0) {
        try writePlace(out, info, parts);
        try out.writeAll(separator);
    }
    try writeContext(out, info, parts.context);
    if (parts.cost) {
        // Session cost uses public API rates. It is an estimate because the login
        // type does not reveal billing.
        try out.print("{s}Cost: ${d:.2}", .{ separator, info.cost });
    }
    if (info.quota) |quota| {
        if (parts.quota_primary) try writeQuotaWindow(out, quota.primary);
        if (parts.quota_secondary) try writeQuotaWindow(out, quota.secondary);
    }
    if (parts.cache) try writeCache(out, info);
}

/// The working directory, and the branch that a command here acts on. A
/// path names itself, so it takes no label. The branch follows it in brackets,
/// the same shape the agent takes on the right.
fn writePlace(out: *std.Io.Writer, info: *const Info, parts: *const Parts) !void {
    try writeDirectory(out, info.directory, parts.place);
    if (info.branch) |branch| {
        try out.writeAll(" (");
        try writeBranch(out, branch, parts.branch);
        try out.writeByte(')');
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

/// Context now: the last request's whole prompt plus its output, against the
/// model's window. The one "now" number. The rest is session-cumulative.
fn writeContext(out: *std.Io.Writer, info: *const Info, form: Parts.Context) !void {
    const context = promptTokens(info) +| info.last.output;
    const percent = if (info.context_window > 0)
        asFloat(context) / asFloat(info.context_window) * 100.0
    else
        0.0;
    try out.print("Context: {d:.0}%", .{percent});
    if (form == .short) return;
    try out.writeAll(" (");
    try writeTokens(out, context);
    try out.writeByte('/');
    try writeTokens(out, info.context_window);
    try out.writeByte(')');
}

/// The last request's cache hit rate over the whole prompt. The value is zero
/// after a cold start, model switch, or cache expiry, and absent before the
/// first request, so the line never shows a 0/0 rate.
fn writeCache(out: *std.Io.Writer, info: *const Info) !void {
    const prompt = promptTokens(info);
    if (prompt == 0) return;
    const hit = asFloat(info.last.cache_read) / asFloat(prompt) * 100.0;
    try out.print("{s}Cache: {d:.0}%", .{ separator, hit });
}

/// The whole prompt of the last request. Saturating: the counts arrive from the
/// provider stream unchecked.
fn promptTokens(info: *const Info) u64 {
    return info.last.input +| info.last.cache_read +| info.last.cache_write;
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

/// The full set of parts, so a test can watch the line give them up.
const test_info: Info = .{
    .directory = "~/github/clebert/pith",
    .branch = "main",
    .last = .{ .input = 22, .output = 23_000, .cache_read = 160_000, .cache_write = 23_000 },
    .cost = 0.393,
    .context_window = 1_000_000,
    .model = "claude-opus-4-8",
    .effort = "xhigh",
    .account = .anthropic_subscription,
    .quota = .{
        .primary = .{ .used_percent = 11.6, .window_minutes = 300 },
        .secondary = .{ .used_percent = 73.6, .window_minutes = 10080 },
    },
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
        "~/github/clebert/pith (main)",
        "Context: 21% (206k/1.0M)",
        "Cost: $0.39",
        "5h quota: 88% remaining",
        "Weekly quota: 26% remaining",
        "Cache: 87%",
        "claude-opus-4-8 (Anthropic Subscription) · Effort: xhigh",
    });
    // The place anchors the left, and the agent anchors the right.
    const place = std.mem.indexOf(u8, painted, "~/github").?;
    const context = std.mem.indexOf(u8, painted, "Context:").?;
    try std.testing.expect(place < context);
    try std.testing.expect(context < std.mem.indexOf(u8, painted, "claude-opus-4-8").?);
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
            .columns = 190,
            .shows = &.{ "~/…/pith (main)", "Context: 21% (206k/1.0M)", "Cache: 87%" },
            .hides = &.{"~/github"},
        },
        .{
            // The context gauge shortens before any complete part goes.
            .columns = 170,
            .shows = &.{ "Context: 21%", "Cost: $0.39", "Weekly quota", "Cache: 87%" },
            .hides = &.{"(206k/1.0M)"},
        },
        .{
            .columns = 160,
            .shows = &.{ "Cost: $0.39", "5h quota", "Weekly quota" },
            .hides = &.{"Cache:"},
        },
        .{
            // Both quotas outlast the cost.
            .columns = 150,
            .shows = &.{ "5h quota", "Weekly quota" },
            .hides = &.{ "Cost:", "Cache:" },
        },
        .{
            .columns = 140,
            .shows = &.{ "5h quota", "Anthropic Subscription" },
            .hides = &.{ "Weekly quota", "Cost:", "Cache:" },
        },
        .{
            .columns = 110,
            .shows = &.{ "~/…/pith (main)", "Anthropic Subscription", "Effort: xhigh" },
            .hides = &.{"quota"},
        },
        .{
            .columns = 80,
            .shows = &.{ "~/…/pith (main)", "claude-opus-4-8", "Effort: xhigh" },
            .hides = &.{"Anthropic Subscription"},
        },
        .{
            .columns = 60,
            .shows = &.{ "Context: 21%", "claude-opus-4-8", "Effort: xhigh" },
            .hides = &.{"pith"},
        },
        .{
            .columns = 40,
            .shows = &.{ "Context: 21%", "claude-opus-4-8" },
            .hides = &.{ "pith", "Effort:" },
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
        // Below the width of the gauge itself only the truncation is left, and
        // the percentage is what it truncates toward.
        const expected = if (columns >= 12) "Context: 21%" else "Context:"[0..@min(8, columns)];
        try expectShows(out.written(), &.{expected});
    }
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
    try renderForTest(gpa, &info, 195, &out);

    const painted = out.written();
    try expectShows(painted, &.{
        "~/…/pith (feature/" ++ "🇩🇪" ** 4 ++ "…)",
        "Context: 21% (206k/1.0M)",
        "Cost: $0.39",
        "5h quota",
        "Weekly quota",
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
    try expectShows(painted, &.{"~/github/clebert/pith · Context:"});
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
    try expectShows(painted, &.{ "Error: ", "boom" });
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

test "a signed-out status shows the indicator in place of the model" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.account = null;
    info.last = .{};
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 120, &out);

    const painted = out.written();
    try expectShows(painted, &.{"Account: Signed out"});
    // No prompt tokens sent yet: the cache figure is absent, never a 0/0 rate.
    try expectHides(painted, &.{ "claude-opus-4-8", "Effort:", "Cache" });
}

test "quota windows show the remaining allowance, labeled by length" {
    const gpa = std.testing.allocator;
    var info = test_info;
    info.directory = "";
    info.model = "gpt-5.6-sol";
    info.account = .openai_subscription;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderForTest(gpa, &info, 160, &out);

    const painted = out.written();
    try expectShows(painted, &.{ "5h quota: 88% remaining", "Weekly quota: 26% remaining" });
    // An empty directory hides the whole place, separator and all.
    try expectHides(painted, &.{" · Context:"});
}

test "unidentified quota windows stay hidden beside a known window" {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var info = test_info;
    info.quota = .{
        .primary = .{ .used_percent = 77, .window_minutes = 10080 },
        .secondary = .{ .used_percent = 0 },
    };

    try writeLeft(&out, &info, &Parts.all);
    const written = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Weekly quota: 23% remaining") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "100% remaining") == null);
    try std.testing.expect(quotaLabel(null) == null);
    try std.testing.expect(quotaLabel(600) == null);
}
