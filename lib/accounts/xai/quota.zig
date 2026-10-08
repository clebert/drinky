const std = @import("std");

const core = @import("core");
const providers = @import("providers");

pub fn parse(
    gpa: std.mem.Allocator,
    body: []const u8,
    now_ms: i64,
) error{OutOfMemory}!?core.Provider.Quota {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = (try providers.json.parseObject(arena.allocator(), body)) orelse return null;
    const config = providers.json.object(root.getPtr("config")) orelse return null;
    const percent = providers.json.number(config.getPtr("creditUsagePercent")) orelse return null;
    const used = core.Provider.Quota.Window.usedPercent(percent) orelse return null;
    var window: core.Provider.Quota.Window = .{ .used_percent = used };
    const maybe_period = providers.json.object(config.getPtr("currentPeriod"));
    if (maybe_period) |period| {
        const maybe_start = providers.json.string(period.getPtr("start"));
        const maybe_end = providers.json.string(period.getPtr("end"));
        const start_seconds = if (maybe_start) |start| parseRfc3339(start) else null;
        const end_seconds = if (maybe_end) |end| parseRfc3339(end) else null;
        window.window_minutes = windowMinutes(&.{
            .start_seconds = start_seconds,
            .end_seconds = end_seconds,
        });
        window.reset_seconds = resetSeconds(end_seconds, now_ms);
    }
    return .{ .primary = window };
}

fn windowMinutes(period: *const struct { start_seconds: ?i64, end_seconds: ?i64 }) ?u32 {
    const start = period.start_seconds orelse return null;
    const end = period.end_seconds orelse return null;
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
    const month_enum: std.time.epoch.Month = @fromBackingInt(@intCast(month));
    const year_epoch: std.time.epoch.Year = @intCast(year);
    if (day > std.time.epoch.getDaysInMonth(year_epoch, month_enum)) return null;
    const offset_seconds = parseOffset(text, &index) orelse return null;
    if (index != text.len) return null;
    const days = daysFromCivil(&.{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
    });
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

fn daysFromCivil(date: *const struct { year: i64, month: i64, day: i64 }) i64 {
    const month = date.month;
    var civil_year = date.year;
    if (month <= 2) civil_year -= 1;
    const era = @divFloor(civil_year, 400);
    const year_of_era = civil_year - era * 400;
    const month_shifted = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_shifted + 2, 5) + date.day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
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
    const now_ms: i64 = 1_623_526_106_000;
    const weekly =
        \\{"config":{"creditUsagePercent":1.0,"isUnifiedBillingUser":true,
        \\"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2021-06-05T20:28:26Z",
        \\"end":"2021-06-12T20:28:26Z"},"prepaidBalance":{"val":0},
        \\"productUsage":[{"product":"GrokBuild","usagePercent":50.0}]}}
    ;
    const quota = (try parse(gpa, weekly, now_ms)).?;
    try std.testing.expectEqual(@as(f64, 1.0), quota.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, 10080), quota.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 3600), quota.primary.?.reset_seconds);
    try std.testing.expect(quota.secondary == null);

    const integer_share =
        \\{"config":{"creditUsagePercent":0,"currentPeriod":{"start":"2021-06-05T20:28:26Z",
        \\"end":"2021-06-12T20:28:26Z"}}}
    ;
    try std.testing.expectEqual(
        @as(f64, 0),
        (try parse(gpa, integer_share, now_ms)).?.primary.?.used_percent,
    );

    const spent =
        \\{"config":{"creditUsagePercent":100.1,"currentPeriod":{"start":"2021-06-05T20:28:26Z",
        \\"end":"2021-06-12T20:28:26Z"}}}
    ;
    try std.testing.expectEqual(
        @as(f64, 100),
        (try parse(gpa, spent, now_ms)).?.primary.?.used_percent,
    );

    const monthly =
        \\{"config":{"creditUsagePercent":12,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY",
        \\"start":"2021-06-05T20:28:26Z","end":"2021-07-05T20:28:26Z"}}}
    ;
    const monthly_quota = (try parse(gpa, monthly, now_ms)).?;
    try std.testing.expectEqual(@as(?u32, 43200), monthly_quota.primary.?.window_minutes);

    const no_period = "{\"config\":{\"creditUsagePercent\":4}}";
    const partial = (try parse(gpa, no_period, now_ms)).?;
    try std.testing.expectEqual(@as(f64, 4), partial.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, null), partial.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, null), partial.primary.?.reset_seconds);

    const stale_end =
        \\{"config":{"creditUsagePercent":8,"currentPeriod":{"start":"2021-06-05T20:28:26Z",
        \\"end":"2021-06-05T20:28:26Z"}}}
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
