const std = @import("std");
const accounts = @import("accounts");
const core = @import("core");
const tools = @import("tools");
const Settings = @import("Settings.zig");

const Record = @This();

id: u64,
content: Content,
work: ?Work = null,

pub const Work = struct {
    started_ms: i64,
    end: ?End = null,
    pub const Status = enum { complete, canceled, failed, truncated };
    pub const End = struct { time_ms: i64, status: Status };
};

pub const Content = union(enum) {
    user: std.ArrayList(u8),
    user_note: Note,
    thinking: std.ArrayList(u8),
    model: std.ArrayList(u8),
    tool_result: Result,
    event: Event,
    authorization: Authorization,
};
pub const Kind = std.meta.Tag(Content);
pub const Source = union(Kind) {
    user: []const u8,
    user_note: Note,
    thinking: []const u8,
    model: []const u8,
    tool_result: Result,
    event: Event,
    authorization: Authorization,
};

pub const Note = union(enum) {
    skill: core.Session.Event.SkillLoaded,
    retry,
};

pub const Result = struct {
    name: []const u8,
    description: tools.Registry.Description,
    output: core.Tool.Output,
    elapsed_ms: ?i64 = null,
    started_ms: i64,
    received_bytes: usize,
};

pub const Authorization = struct {
    account: usize,
    url: []const u8,
    code: ?[]const u8,
};

pub const Event = union(enum) {
    no_account,
    account_active: usize,
    model_active: ModelChoice,
    effort_active: core.Provider.Effort,
    use_changed: Use,
    effort_changed: core.Provider.Effort,
    choices_busy,
    choices_corrupt: []const u8,
    choices_unsaved: PathCause,
    signed_in: SignedIn,
    sign_in_failed: SignInFailure,
    credentials_unsaved: CredentialsUnsaved,
    browser_unopened: usize,
    callback_unexpected: usize,
    callback_invalid: usize,
    callback_received: usize,
    callback_unreplayed: AccountCause,
    sign_out_failed: []const u8,
    signed_out: SignedOut,
    credential_unremoved: AccountCause,
    credential_reloaded: Reload,
    models_fetched: Fetch,
    models_unfetched: FetchFailure,
    attempt_failed: Attempt,
    model_substituted: Substitution,
    reply_truncated,
    turn_canceled,
    tool_rounds_exhausted,
    request_failed: Failure,
    effort_unknown: EffortUnknown,
    bash_timeout_ignored: Range,
    window_pages_ignored: Range,
    gauge_ignored: GaugeShares,
    required_skills_capped: PathLimit,
    config_unread: PathCause,
    config_key_unknown: ConfigKey,
    config_keys_omitted: []const u8,
    instruction_report: InstructionReport,
    skill_report: SkillReport,
    reports_omitted: Subject,

    pub const ModelChoice = struct { account: usize, model: []const u8 };
    pub const Step = enum { select_model, fetch_models };
    pub const AccountStep = struct { account: usize, step: Step };
    pub const Use = union(enum) { model: ModelChoice, account: AccountStep };
    pub const PathCause = struct { path: []const u8, cause: []const u8 };
    pub const AccountCause = struct { account: usize, cause: []const u8 };
    pub const PathLimit = struct { path: []const u8, limit: usize };
    pub const SignedIn = struct { account: usize, model: ?[]const u8 };
    pub const SignInFailure = struct {
        account: usize,
        reason: Reason,
        cause: []const u8,

        pub const Reason = enum {
            canceled,
            callback_timeout,
            callback_too_large,
            callback_timeout_unavailable,
            not_authorized,
            device_code_expired,
            state_mismatch,
            grant_rejected,
            service_unavailable,
            failed,
        };

        pub fn from(account: usize, login_error: accounts.oauth.store.SignInError) SignInFailure {
            const reason: Reason = switch (login_error) {
                error.Canceled => .canceled,
                error.CallbackTimeout => .callback_timeout,
                error.CallbackRequestTooLarge => .callback_too_large,
                error.CallbackTimeoutUnavailable => .callback_timeout_unavailable,
                error.AuthorizationFailed, error.AuthorizationDenied => .not_authorized,
                error.DeviceCodeExpired => .device_code_expired,
                error.StateMismatch => .state_mismatch,
                error.TokenGrantRejected => .grant_rejected,
                error.TokenServiceUnavailable => .service_unavailable,
                error.OutOfMemory,
                error.TokenResponseTooLarge,
                error.TokenRequestFailed,
                error.AuthorizationPending,
                error.SlowDown,
                error.BadTokenResponse,
                error.BadDeviceResponse,
                error.BadCredentials,
                error.MissingAccessToken,
                error.MissingRefreshToken,
                error.MissingExpiry,
                error.MissingAccountId,
                error.MissingApiKey,
                => .failed,
                inline else => |cause| failed: {
                    comptime core.error_set.requireMember(accounts.oauth.login.NetworkError, cause);
                    break :failed .failed;
                },
            };
            return .{ .account = account, .reason = reason, .cause = @errorName(login_error) };
        }
    };
    pub const CredentialsUnsaved = struct {
        account: usize,
        path: ?[]const u8,
        cause: []const u8,

        pub fn from(
            account: usize,
            failure: *const @FieldType(accounts.oauth.store.Commit, "memory_only"),
        ) CredentialsUnsaved {
            return .{
                .account = account,
                .path = nonEmpty(failure.path),
                .cause = @errorName(failure.save_error),
            };
        }
    };
    pub const SignedOut = struct {
        account: usize,
        rejected: bool,
        next: Next,

        pub const Next = union(enum) { unchanged, none, use: Use };
    };
    pub const Reload = struct {
        account: usize,
        next: Next,

        pub const Next = union(enum) { retry_turn, step: Step };
    };
    pub const Fetch = struct {
        account: usize,
        count: usize,
        metadata_error: ?[]const u8 = null,
        models_save_error: ?[]const u8 = null,
        metadata_save_error: ?[]const u8 = null,
    };
    pub const FetchFailure = struct {
        account: usize,
        cause: []const u8,
        metadata_save_error: ?[]const u8 = null,
    };
    pub const Attempt = struct {
        attempt: u32,
        reason: core.Provider.Failure.Reason,
        details: ?[]const u8,
        delay_ms: u64,

        pub fn from(attempt: *const core.Session.Event.Attempt) Attempt {
            return .{
                .attempt = attempt.attempt,
                .reason = attempt.failure.reason,
                .details = nonEmpty(attempt.failure.message),
                .delay_ms = attempt.delay_ms,
            };
        }
    };
    pub const Failure = struct {
        reason: core.Provider.Failure.Reason,
        details: ?[]const u8,

        pub fn from(failure: *const core.Provider.Failure) Failure {
            return .{ .reason = failure.reason, .details = nonEmpty(failure.message) };
        }
    };
    pub const Substitution = struct { requested: []const u8, served: []const u8 };
    pub const EffortUnknown = struct { value: []const u8, used: core.Provider.Effort };
    pub const Range = struct { value: u64, min: u64, max: u64, used: u64 };
    pub const GaugeShares = struct {
        dropped: Settings.Gauge,
        used: Settings.Gauge,
        min: f64,
        max: f64,
    };
    pub const ConfigKey = struct { path: []const u8, key: []const u8 };
    pub const Subject = enum { config, instructions, skills };
    pub const InstructionReport = struct {
        scope: Scope,
        problem: Problem,

        pub const Scope = enum { user, project };
        pub const Problem = union(enum) {
            duplicate: []const u8,
            empty: []const u8,
            too_large: PathLimit,
            not_text: []const u8,
            unread: PathCause,
            count_capped: PathLimit,
            total_capped: PathLimit,
            marker_uninspected: PathCause,
            directory_unscanned: PathCause,
            scan_stopped: PathCause,
            scan_capped: PathLimit,
            claude_ignored: []const u8,
            agent_ignored: []const u8,
            uninspected: PathCause,
            link_target_missing: []const u8,
            link_uninspected: PathCause,
            link_target_irregular: []const u8,
            irregular: []const u8,
            unopened: PathCause,
            open_uninspected: PathCause,
            unresolved: PathCause,
            outside: []const u8,
            paths_capped: usize,
            missing: []const u8,
        };
    };
    pub const SkillReport = union(enum) {
        root_unscanned: PathCause,
        entry_skipped: PathCause,
        directory_unscanned: Skip,
        link_unresolved: Skip,
        link_unfollowed: Skip,
        scan_capped: PathLimit,
        paths_capped: PathLimit,
        path_invalid: []const u8,
        too_large: PathLimit,
        unread: PathCause,
        not_text: []const u8,
        too_long: PathLimit,
        front_matter_missing: []const u8,
        front_matter_unclosed: []const u8,
        description_missing: []const u8,
        description_nul: []const u8,
        name_invalid: PathName,
        name_missing: []const u8,
        directory_invalid: PathName,
        name_differs: NameDifference,
        description_shortened: PathLimit,
        metadata_ignored: []const u8,
        shadowed: Shadowed,
        count_capped: usize,

        pub const Skip = struct { root: []const u8, path: []const u8, cause: []const u8 };
        pub const PathName = struct { path: []const u8, name: []const u8 };
        pub const NameDifference = struct {
            path: []const u8,
            name: []const u8,
            directory: []const u8,
        };
        pub const Shadowed = struct { path: []const u8, name: []const u8, winner: []const u8 };
    };

    pub fn fromRefresh(account: usize, refresh: *const accounts.Registry.Refresh) ?Event {
        if (refresh.models_error) |err| return .{ .models_unfetched = .{
            .account = account,
            .cause = @errorName(err),
            .metadata_save_error = errorName(refresh.metadata_save_error),
        } };
        const failed = refresh.metadata_error != null or refresh.models_save_error != null or
            refresh.metadata_save_error != null;
        if (!failed and refresh.count > 0) return null;
        return .{ .models_fetched = .{
            .account = account,
            .count = refresh.count,
            .metadata_error = errorName(refresh.metadata_error),
            .models_save_error = errorName(refresh.models_save_error),
            .metadata_save_error = errorName(refresh.metadata_save_error),
        } };
    }

    fn errorName(maybe_error: anytype) ?[]const u8 {
        const err = maybe_error orelse return null;
        return @errorName(err);
    }

    fn nonEmpty(text: []const u8) ?[]const u8 {
        return if (text.len == 0) null else text;
    }

    pub fn dupe(self: *const Event, gpa: std.mem.Allocator) error{OutOfMemory}!Event {
        return dupeData(gpa, self.*);
    }

    pub fn deinit(self: *const Event, gpa: std.mem.Allocator) void {
        freeData(gpa, self);
    }
};

pub fn dupeData(gpa: std.mem.Allocator, value: anytype) error{OutOfMemory}!@TypeOf(value) {
    const T = @TypeOf(value);
    if (T == []const u8) return gpa.dupe(u8, value);
    switch (@typeInfo(T)) {
        .optional => return if (value) |inner| try dupeData(gpa, inner) else null,
        .@"struct" => |info| {
            var result = value;
            var count: usize = 0;
            errdefer {
                inline for (info.field_names, 0..) |name, index| {
                    if (index < count) freeData(gpa, &@field(result, name));
                }
            }
            inline for (info.field_names) |name| {
                @field(result, name) = try dupeData(gpa, @field(value, name));
                count += 1;
            }
            return result;
        },
        .@"union" => return switch (value) {
            inline else => |payload, tag| @unionInit(T, @tagName(tag), try dupeData(gpa, payload)),
        },
        .pointer => @compileError("event data must own its text or hold no pointer: " ++
            @typeName(T)),
        else => return value,
    }
}

pub fn freeData(gpa: std.mem.Allocator, value: anytype) void {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    if (T == []const u8) return gpa.free(value.*);
    switch (@typeInfo(T)) {
        .optional => if (value.*) |*inner| freeData(gpa, inner),
        .@"struct" => |info| inline for (info.field_names) |name| {
            freeData(gpa, &@field(value.*, name));
        },
        .@"union" => switch (value.*) {
            inline else => |*payload| freeData(gpa, payload),
        },
        .pointer => @compileError("event data must own its text or hold no pointer: " ++
            @typeName(T)),
        else => {},
    }
}

pub fn init(gpa: std.mem.Allocator, id: u64, source: *const Source) error{OutOfMemory}!Record {
    return .{
        .id = id,
        .work = switch (source.*) {
            .tool_result => |*result| .{ .started_ms = result.started_ms },
            .user, .user_note, .thinking, .model, .event, .authorization => null,
        },
        .content = switch (source.*) {
            .event => |*event| .{ .event = try event.dupe(gpa) },
            .user_note => |*note| .{ .user_note = try dupeNote(gpa, note) },
            .authorization => |*authorization| .{
                .authorization = try dupeAuthorization(gpa, authorization),
            },
            .tool_result => |*result| result: {
                var owned = result.*;
                owned.name = try gpa.dupe(u8, result.name);
                errdefer gpa.free(owned.name);
                owned.description = try dupeDescription(gpa, &result.description);
                errdefer owned.description.deinit(gpa);
                owned.output = try result.output.dupe(gpa);
                break :result .{ .tool_result = owned };
            },
            inline else => |text, tag| @unionInit(Content, @tagName(tag), try copy(gpa, text)),
        },
    };
}

fn dupeNote(gpa: std.mem.Allocator, note: *const Note) error{OutOfMemory}!Note {
    return switch (note.*) {
        .skill => |skill| skill: {
            const name = try gpa.dupe(u8, skill.name);
            errdefer gpa.free(name);
            break :skill .{ .skill = .{ .name = name, .source = try gpa.dupe(u8, skill.source) } };
        },
        .retry => .retry,
    };
}

fn dupeAuthorization(
    gpa: std.mem.Allocator,
    authorization: *const Authorization,
) error{OutOfMemory}!Authorization {
    const url = try gpa.dupe(u8, authorization.url);
    errdefer gpa.free(url);
    const code = if (authorization.code) |code| try gpa.dupe(u8, code) else null;
    return .{ .account = authorization.account, .url = url, .code = code };
}

pub fn dupeDescription(
    gpa: std.mem.Allocator,
    description: *const tools.Registry.Description,
) error{OutOfMemory}!tools.Registry.Description {
    var result = description.*;
    if (result.subject) |*subject| subject.text = try gpa.dupe(u8, subject.text);
    return result;
}

pub fn dupe(self: *const Record, gpa: std.mem.Allocator) error{OutOfMemory}!Record {
    var result = try init(gpa, self.id, &self.sourceValue());
    result.work = self.work;
    return result;
}

pub fn deinit(self: *Record, gpa: std.mem.Allocator) void {
    switch (self.content) {
        .event => |*event| event.deinit(gpa),
        .authorization => |*authorization| {
            gpa.free(authorization.url);
            if (authorization.code) |code| gpa.free(code);
        },
        .user_note => |*note| switch (note.*) {
            .skill => |skill| {
                gpa.free(skill.name);
                gpa.free(skill.source);
            },
            .retry => {},
        },
        .tool_result => |*result| {
            gpa.free(result.name);
            result.description.deinit(gpa);
            result.output.deinit(gpa);
        },
        inline else => |*list| list.deinit(gpa),
    }
}

pub fn appendText(
    self: *Record,
    gpa: std.mem.Allocator,
    delta: []const u8,
) error{OutOfMemory}!void {
    switch (self.content) {
        .thinking, .model => |*list| try list.appendSlice(gpa, delta),
        .user, .user_note, .tool_result, .event, .authorization => unreachable,
    }
}

pub fn replaceEvent(self: *Record, gpa: std.mem.Allocator, event: *const Event) !void {
    const copy_event = try event.dupe(gpa);
    self.deinit(gpa);
    self.content = .{ .event = copy_event };
}

pub fn streamedText(self: *const Record) ?[]const u8 {
    return switch (self.content) {
        .thinking, .model => |list| list.items,
        .user, .user_note, .tool_result, .event, .authorization => null,
    };
}

fn sourceValue(self: *const Record) Source {
    return switch (self.content) {
        .event => |*event| .{ .event = event.* },
        .user_note => |*note| .{ .user_note = note.* },
        .tool_result => |*result| .{ .tool_result = result.* },
        .authorization => |*authorization| .{ .authorization = authorization.* },
        inline else => |list, tag| @unionInit(Source, @tagName(tag), list.items),
    };
}

fn copy(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}!std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(gpa, text);
    return list;
}

test "an authorization record copy and its replacement release every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkAuthorization,
        .{},
    );
}

fn checkAuthorization(gpa: std.mem.Allocator) !void {
    var record = try init(gpa, 1, &.{ .authorization = .{
        .account = 3,
        .url = "https://auth.example/device",
        .code = "ABCD-1234",
    } });
    defer record.deinit(gpa);
    var duplicate = try record.dupe(gpa);
    defer duplicate.deinit(gpa);
    try std.testing.expectEqualStrings("ABCD-1234", duplicate.content.authorization.code.?);
    try duplicate.replaceEvent(gpa, &.{ .signed_in = .{ .account = 3, .model = "gpt-next" } });
    try std.testing.expectEqualStrings("gpt-next", duplicate.content.event.signed_in.model.?);
}

test "an event copy duplicates every text field and releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkEventCopy,
        .{},
    );
}

fn checkEventCopy(gpa: std.mem.Allocator) !void {
    const events = [_]Event{
        .{ .models_fetched = .{
            .account = 1,
            .count = 0,
            .metadata_error = "Timeout",
            .models_save_error = "StoreBusy",
            .metadata_save_error = "AccessDenied",
        } },
        .{ .skill_report = .{ .shadowed = .{
            .path = "/a/SKILL.md",
            .name = "demo",
            .winner = "/b/SKILL.md",
        } } },
        .{ .signed_out = .{
            .account = 2,
            .rejected = true,
            .next = .{ .use = .{ .model = .{ .account = 1, .model = "gpt-next" } } },
        } },
        .{ .instruction_report = .{
            .scope = .project,
            .problem = .{ .unread = .{ .path = "/AGENTS.md", .cause = "AccessDenied" } },
        } },
        .{ .choices_corrupt = "/state.json" },
        .turn_canceled,
    };
    for (&events) |*event| {
        const duplicate = try event.dupe(gpa);
        defer duplicate.deinit(gpa);
        try std.testing.expectEqualDeep(event.*, duplicate);
    }
}

test "a sign-in error maps to the reason of its words and keeps its error name" {
    const cases = [_]struct {
        err: accounts.oauth.store.SignInError,
        reason: Event.SignInFailure.Reason,
    }{
        .{ .err = error.Canceled, .reason = .canceled },
        .{ .err = error.AuthorizationDenied, .reason = .not_authorized },
        .{ .err = error.TokenGrantRejected, .reason = .grant_rejected },
        .{ .err = error.BadTokenResponse, .reason = .failed },
        .{ .err = error.ConnectionRefused, .reason = .failed },
    };
    for (cases) |case| {
        const failure = Event.SignInFailure.from(accounts.testing.anthropic_plan, case.err);
        try std.testing.expectEqual(case.reason, failure.reason);
        try std.testing.expectEqualStrings(@errorName(case.err), failure.cause);
    }
}

test "a model fetch reports a failed fetch, a failed write, and an empty list, and nothing else" {
    const account = accounts.testing.anthropic_api_key;
    try std.testing.expect(Event.fromRefresh(account, &.{ .count = 2 }) == null);
    try std.testing.expectEqualDeep(
        Event{ .models_fetched = .{ .account = account, .count = 0 } },
        Event.fromRefresh(account, &.{ .count = 0 }).?,
    );
    try std.testing.expectEqualDeep(
        Event{ .models_fetched = .{
            .account = account,
            .count = 2,
            .metadata_error = "Timeout",
            .metadata_save_error = "StoreBusy",
        } },
        Event.fromRefresh(account, &.{
            .count = 2,
            .metadata_error = error.Timeout,
            .metadata_save_error = error.StoreBusy,
        }).?,
    );
    try std.testing.expectEqualDeep(
        Event{ .models_unfetched = .{
            .account = account,
            .cause = "ConnectionRefused",
            .metadata_save_error = "StoreBusy",
        } },
        Event.fromRefresh(account, &.{
            .count = 2,
            .models_error = error.ConnectionRefused,
            .metadata_save_error = error.StoreBusy,
        }).?,
    );
}

test "a failure, an attempt, and an unsaved credential hold no empty text" {
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        Event.Failure.from(&.{ .reason = .network }).details,
    );
    try std.testing.expectEqualStrings(
        "Connection closed.",
        Event.Failure.from(&.{ .reason = .network, .message = "Connection closed." }).details.?,
    );
    const attempt: core.Session.Event.Attempt = .{
        .attempt = 1,
        .failure = .{ .reason = .overloaded },
        .delay_ms = 0,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), Event.Attempt.from(&attempt).details);
    const account = accounts.testing.anthropic_plan;
    const unknown = Event.CredentialsUnsaved.from(account, &.{
        .path = "",
        .save_error = error.StoreBusy,
    });
    try std.testing.expectEqual(@as(?[]const u8, null), unknown.path);
    try std.testing.expectEqualStrings(
        "/auth.json",
        Event.CredentialsUnsaved.from(account, &.{
            .path = "/auth.json",
            .save_error = error.StoreBusy,
        }).path.?,
    );
}
