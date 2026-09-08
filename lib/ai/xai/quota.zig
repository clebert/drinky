//! The weekly plan allowance of the xAI subscription. The public Responses
//! endpoint states only burst TPM and RPM, so Drinky reads the CLI billing
//! surface. That surface is the same off-label client as the device login.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");

/// The Grok Build credits shape. The same URL without `format=credits` is the
/// legacy monthly API-credit body, which is empty for this plan.
const endpoint = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";

/// The plan allowance behind `token`, or null when the endpoint refuses the
/// request or the body names no used share. The caller owns nothing. Bearer
/// alone authorizes the proxy: `X-XAI-Token-Auth` is omitted, because any
/// value other than `xai-grok-cli` returns 401. A non-OK status, including
/// 401, returns null. `accessToken` already refreshed a locally expired
/// credential, so a 401 here is a token another instance rotated, and the
/// model request handles that renewal.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
) !?llm.Quota {
    const body = try net.getJson(gpa, io, &.{ .url = endpoint, .bearer = token }) orelse
        return null;
    defer gpa.free(body);
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return parse(gpa, body, now_ms);
}

/// Decode the credits body into one primary window. `prepaidBalance` and
/// `productUsage` are extra credits after the weekly pool, not a second
/// rolling window, so they stay out of the gauge. Null when the used share is
/// missing or not a percentage.
fn parse(gpa: std.mem.Allocator, body: []const u8, now_ms: i64) error{OutOfMemory}!?llm.Quota {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    defer parsed.deinit();
    const root = json.object(parsed.value) orelse return null;
    const config = json.object(root.get("config")) orelse return null;
    const used = usedPercent(config.get("creditUsagePercent")) orelse return null;
    var window: llm.Quota.Window = .{ .used_percent = used };
    const maybe_period = json.object(config.get("currentPeriod"));
    if (maybe_period) |period| {
        const maybe_start = json.string(period.get("start"));
        const maybe_end = json.string(period.get("end"));
        const start_seconds = if (maybe_start) |start| parseRfc3339(start) else null;
        const end_seconds = if (maybe_end) |end| parseRfc3339(end) else null;
        window.window_minutes = windowMinutes(start_seconds, end_seconds);
        window.reset_seconds = resetSeconds(end_seconds, now_ms);
    }
    return .{ .primary = window };
}

fn usedPercent(value: ?std.json.Value) ?f64 {
    const percent = switch (value orelse return null) {
        .integer => |found| @as(f64, @floatFromInt(found)),
        .float => |found| found,
        .number_string => |found| std.fmt.parseFloat(f64, found) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(percent) or percent < 0) return null;
    return @min(100.0, percent);
}

fn windowMinutes(start_seconds: ?i64, end_seconds: ?i64) ?u32 {
    const start = start_seconds orelse return null;
    const end = end_seconds orelse return null;
    const duration = std.math.sub(i64, end, start) catch return null;
    if (duration <= 0) return null;
    const minutes = @divFloor(duration, std.time.s_per_min);
    if (minutes > std.math.maxInt(u32)) return null;
    return @intCast(minutes);
}

fn resetSeconds(end_seconds: ?i64, now_ms: i64) ?u64 {
    const end = end_seconds orelse return null;
    const end_ms = std.math.mul(i64, end, std.time.ms_per_s) catch return null;
    const remaining_ms = std.math.sub(i64, end_ms, now_ms) catch return null;
    if (remaining_ms <= 0) return null;
    return @intCast(@divFloor(remaining_ms, std.time.ms_per_s));
}

/// Seconds since the Unix epoch. Fractional seconds truncate. Null when the
/// text is not an RFC 3339 timestamp with a time zone.
fn parseRfc3339(text: []const u8) ?i64 {
    var index: usize = 0;
    const year = takeDigits(text, &index, 4) orelse return null;
    if (!takeByte(text, &index, '-')) return null;
    const month = takeDigits(text, &index, 2) orelse return null;
    if (!takeByte(text, &index, '-')) return null;
    const day = takeDigits(text, &index, 2) orelse return null;
    if (index >= text.len or (text[index] != 'T' and text[index] != 't')) return null;
    index += 1;
    const hour = takeDigits(text, &index, 2) orelse return null;
    if (!takeByte(text, &index, ':')) return null;
    const minute = takeDigits(text, &index, 2) orelse return null;
    if (!takeByte(text, &index, ':')) return null;
    const second = takeDigits(text, &index, 2) orelse return null;
    if (index < text.len and (text[index] == '.' or text[index] == ',')) {
        index += 1;
        const fraction_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
        if (index == fraction_start) return null;
    }
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 60)
        return null;
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    if (year > std.math.maxInt(std.time.epoch.Year)) return null;
    const year_id: std.time.epoch.Year = @intCast(year);
    if (day > std.time.epoch.getDaysInMonth(year_id, month_enum)) return null;
    const offset_seconds = parseOffset(text, &index) orelse return null;
    if (index != text.len) return null;
    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    const time = hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
    const day_seconds = std.math.mul(i64, days, std.time.s_per_day) catch return null;
    const civil = std.math.add(i64, day_seconds, @intCast(time)) catch return null;
    return std.math.sub(i64, civil, offset_seconds) catch return null;
}

fn parseOffset(text: []const u8, index: *usize) ?i64 {
    if (index.* >= text.len) return null;
    const sign = text[index.*];
    if (sign == 'Z' or sign == 'z') {
        index.* += 1;
        return 0;
    }
    if (sign != '+' and sign != '-') return null;
    index.* += 1;
    const hours = takeDigits(text, index, 2) orelse return null;
    if (!takeByte(text, index, ':')) return null;
    const minutes = takeDigits(text, index, 2) orelse return null;
    if (hours > 23 or minutes > 59) return null;
    const magnitude: i64 = @intCast(hours * std.time.s_per_hour + minutes * std.time.s_per_min);
    return if (sign == '-') -magnitude else magnitude;
}

fn takeDigits(text: []const u8, index: *usize, count: usize) ?u64 {
    if (index.* + count > text.len) return null;
    const slice = text[index.* .. index.* + count];
    for (slice) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    index.* += count;
    return std.fmt.parseInt(u64, slice, 10) catch null;
}

fn takeByte(text: []const u8, index: *usize, byte: u8) bool {
    if (index.* >= text.len or text[index.*] != byte) return false;
    index.* += 1;
    return true;
}

/// Days since 1970-01-01 (Howard Hinnant).
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var civil_year = year;
    if (month <= 2) civil_year -= 1;
    const era = @divFloor(civil_year, 400);
    const year_of_era = civil_year - era * 400;
    const month_adj = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_adj + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

test "a credential that cannot be a header refuses the billing request" {
    try std.testing.expectError(
        error.BadCredentials,
        fetch(std.testing.allocator, std.testing.io, ""),
    );
    try std.testing.expectError(
        error.BadCredentials,
        fetch(std.testing.allocator, std.testing.io, "token\r\nleaked: value"),
    );
}

test parseRfc3339 {
    try std.testing.expectEqual(@as(i64, 0), parseRfc3339("1970-01-01T00:00:00Z").?);
    try std.testing.expectEqual(@as(i64, 1), parseRfc3339("1970-01-01T00:00:01Z").?);
    try std.testing.expectEqual(@as(i64, 1_622_924_906), parseRfc3339("2021-06-05T20:28:26Z").?);
    try std.testing.expectEqual(@as(i64, 1_622_924_906), parseRfc3339("2021-06-05T20:28:26z").?);
    try std.testing.expectEqual(
        @as(i64, 1_622_924_906),
        parseRfc3339("2021-06-05T20:28:26+00:00").?,
    );
    try std.testing.expectEqual(
        @as(i64, 1_622_924_906),
        parseRfc3339("2021-06-05T13:28:26-07:00").?,
    );
    try std.testing.expectEqual(
        @as(i64, 1_622_924_906),
        parseRfc3339("2021-06-05T20:28:26.123Z").?,
    );
    try std.testing.expectEqual(
        @as(i64, 1_622_924_906),
        parseRfc3339("2021-06-05t20:28:26,5Z").?,
    );
    try std.testing.expect(parseRfc3339("2021-06-05 20:28:26Z") == null);
    try std.testing.expect(parseRfc3339("2021-06-05T20:28:26") == null);
    try std.testing.expect(parseRfc3339("2021-06-05T20:28:26Z ") == null);
    try std.testing.expect(parseRfc3339("2021-02-30T00:00:00Z") == null);
    try std.testing.expect(parseRfc3339("2021-06-05T24:00:00Z") == null);
    try std.testing.expect(parseRfc3339("2021-06-05T20:28:26.") == null);
    try std.testing.expect(parseRfc3339("") == null);
}

test parse {
    const gpa = std.testing.allocator;
    // One hour before the end of a seven-day window that starts at the std
    // epoch-decoding sample instant.
    const now_ms: i64 = 1_623_526_106_000;
    const weekly =
        \\{"config":{"creditUsagePercent":1.0,"isUnifiedBillingUser":true,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2021-06-05T20:28:26Z","end":"2021-06-12T20:28:26Z"},"prepaidBalance":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":50.0}]}}
    ;
    const quota = (try parse(gpa, weekly, now_ms)).?;
    try std.testing.expectEqual(@as(f64, 1.0), quota.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, 10080), quota.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 3600), quota.primary.?.reset_seconds);
    try std.testing.expect(quota.secondary == null);

    const integer_share =
        \\{"config":{"creditUsagePercent":0,"currentPeriod":{"start":"2021-06-05T20:28:26Z","end":"2021-06-12T20:28:26Z"}}}
    ;
    try std.testing.expectEqual(
        @as(f64, 0),
        (try parse(gpa, integer_share, now_ms)).?.primary.?.used_percent,
    );

    const spent =
        \\{"config":{"creditUsagePercent":100.1,"currentPeriod":{"start":"2021-06-05T20:28:26Z","end":"2021-06-12T20:28:26Z"}}}
    ;
    try std.testing.expectEqual(
        @as(f64, 100),
        (try parse(gpa, spent, now_ms)).?.primary.?.used_percent,
    );

    const monthly =
        \\{"config":{"creditUsagePercent":12,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2021-06-05T20:28:26Z","end":"2021-07-05T20:28:26Z"}}}
    ;
    const monthly_quota = (try parse(gpa, monthly, now_ms)).?;
    // The status line labels 5h and weekly windows only, so a monthly length
    // stays hidden. This plan is weekly. Other plans can send this type.
    try std.testing.expectEqual(@as(?u32, 43200), monthly_quota.primary.?.window_minutes);

    const no_period = "{\"config\":{\"creditUsagePercent\":4}}";
    const partial = (try parse(gpa, no_period, now_ms)).?;
    try std.testing.expectEqual(@as(f64, 4), partial.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, null), partial.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, null), partial.primary.?.reset_seconds);

    const stale_end =
        \\{"config":{"creditUsagePercent":8,"currentPeriod":{"start":"2021-06-05T20:28:26Z","end":"2021-06-05T20:28:26Z"}}}
    ;
    const stale = (try parse(gpa, stale_end, now_ms)).?;
    try std.testing.expectEqual(@as(?u32, null), stale.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, null), stale.primary.?.reset_seconds);

    try std.testing.expect(try parse(gpa, "{}", now_ms) == null);
    try std.testing.expect(try parse(gpa, "not-json", now_ms) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"config\":{\"creditUsagePercent\":-1}}",
        now_ms,
    ) == null);
    try std.testing.expect(try parse(
        gpa,
        "{\"config\":{\"creditUsagePercent\":\"1\"}}",
        now_ms,
    ) == null);
}
