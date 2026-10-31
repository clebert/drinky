const std = @import("std");
const application = @import("application");
const reference = @import("reference.zig");

const accounts = @import("accounts");
const core = @import("core");

const ui = @import("ui/root.zig");

const WriteError = std.Io.Writer.Error || error{OutOfMemory};

const metadata_unsaved = " Drinky could not save the public metadata because of error {s}.";
const credential_reloaded = "Drinky reloaded the refresh credential that another Drinky " ++
    "instance saved. ";

pub fn event(
    gpa: std.mem.Allocator,
    value: *const application.Record.Event,
) error{OutOfMemory}!ui.Message {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    writeEvent(gpa, &text.writer, value) catch return error.OutOfMemory;
    const content = if (startupReport(value))
        try application.support.display(gpa, text.written())
    else
        try text.toOwnedSlice();
    return .{ .content = content, .severity = severity(value) };
}

fn writeFailure(
    writer: *std.Io.Writer,
    value: *const application.Record.Event.Failure,
) std.Io.Writer.Error!void {
    try writer.writeAll(failureSentence(value.reason));
    if (value.details) |details| try writer.print(" Details: {s}", .{details});
}

pub fn refusal(
    gpa: std.mem.Allocator,
    command: *const application.Command,
    value: *const application.Refusal,
) error{OutOfMemory}!?ui.Message {
    return switch (value.*) {
        .busy, .unknown_target, .stale, .unavailable => null,
        .signed_out => prerequisite(
            gpa,
            command,
            "Sign in with " ++ reference.line(.login),
        ),
        .no_model => prerequisite(
            gpa,
            command,
            "Select a model with " ++ reference.line(.model),
        ),
        .no_conversation => try ui.Message.print(
            gpa,
            .warning,
            "No conversation is available for a handoff.",
            .{},
        ),
        .skill_unreadable => |unreadable| try ui.Message.print(
            gpa,
            .failure,
            "Drinky could not load the skill {s} because of error {t}.",
            .{ unreadable.name, unreadable.cause },
        ),
        .account_unloaded => |unloaded| try ui.Message.print(
            gpa,
            .failure,
            "Drinky could not load the {s} account because of error {t}. " ++
                "Fix it and restart Drinky.",
            .{ application.query.accountId(unloaded.account), unloaded.cause },
        ),
        .credential_missing => |account| try ui.Message.print(
            gpa,
            .information,
            "Set {s} in the environment. Restart Drinky to use {s}.",
            .{
                application.query.accountSetting(account).?,
                application.query.accountId(account),
            },
        ),
    };
}

fn prerequisite(
    gpa: std.mem.Allocator,
    command: *const application.Command,
    comptime lead: []const u8,
) error{OutOfMemory}!?ui.Message {
    const action = switch (command.*) {
        .send_message, .invoke_skill, .retry, .apply_result => "send a message",
        .prepare_handoff => "prepare a handoff",
        .new_conversation,
        .select_account,
        .sign_out,
        .submit_callback,
        .fetch_models,
        .select_model,
        .set_effort,
        .remove_canceled_turn,
        .rewind,
        .discard_result,
        .cancel,
        .dismiss_offer,
        .dismiss_notice,
        .refresh_project,
        .snapshot,
        => return null,
    };
    return try ui.Message.print(gpa, .failure, lead ++ " before you {s}.", .{action});
}

fn startupReport(value: *const application.Record.Event) bool {
    return switch (value.*) {
        .effort_unknown,
        .bash_timeout_ignored,
        .window_pages_ignored,
        .gauge_ignored,
        .required_skills_capped,
        .config_unread,
        .config_key_unknown,
        .config_keys_omitted,
        .instruction_report,
        .skill_report,
        .reports_omitted,
        => true,
        .no_account,
        .account_active,
        .model_active,
        .effort_active,
        .use_changed,
        .effort_changed,
        .choices_busy,
        .choices_corrupt,
        .choices_unsaved,
        .signed_in,
        .sign_in_failed,
        .credentials_unsaved,
        .browser_unopened,
        .callback_unexpected,
        .callback_invalid,
        .callback_received,
        .callback_unreplayed,
        .sign_out_failed,
        .signed_out,
        .credential_unremoved,
        .credential_reloaded,
        .models_fetched,
        .models_unfetched,
        .attempt_failed,
        .model_substituted,
        .reply_truncated,
        .turn_canceled,
        .tool_rounds_exhausted,
        .request_failed,
        => false,
    };
}

fn severity(value: *const application.Record.Event) ui.Message.Severity {
    return switch (value.*) {
        .no_account,
        .account_active,
        .model_active,
        .effort_active,
        .use_changed,
        .effort_changed,
        .signed_in,
        .callback_received,
        .signed_out,
        .credential_reloaded,
        .attempt_failed,
        .turn_canceled,
        => .information,
        .browser_unopened,
        .callback_unexpected,
        .callback_invalid,
        .model_substituted,
        => .warning,
        .choices_busy,
        .choices_corrupt,
        .choices_unsaved,
        .credentials_unsaved,
        .callback_unreplayed,
        .sign_out_failed,
        .credential_unremoved,
        .models_unfetched,
        .reply_truncated,
        .tool_rounds_exhausted,
        .request_failed,
        .effort_unknown,
        .bash_timeout_ignored,
        .window_pages_ignored,
        .gauge_ignored,
        .required_skills_capped,
        .config_unread,
        .config_key_unknown,
        .config_keys_omitted,
        .reports_omitted,
        => .failure,
        .sign_in_failed => |sign_in| if (sign_in.reason == .canceled) .information else .failure,
        .models_fetched => |fetched| if (fetched.metadata_error != null or
            fetched.models_save_error != null or fetched.metadata_save_error != null)
            .failure
        else
            .warning,
        .instruction_report => |*report| switch (report.problem) {
            .empty => .information,
            .duplicate,
            .too_large,
            .not_text,
            .unread,
            .count_capped,
            .total_capped,
            .marker_uninspected,
            .directory_unscanned,
            .scan_stopped,
            .scan_capped,
            .claude_ignored,
            .agent_ignored,
            .uninspected,
            .link_target_missing,
            .link_uninspected,
            .link_target_irregular,
            .irregular,
            .unopened,
            .open_uninspected,
            .unresolved,
            .outside,
            .paths_capped,
            .missing,
            => .failure,
        },
        .skill_report => |*report| switch (report.*) {
            .name_invalid,
            .name_missing,
            .name_differs,
            .description_shortened,
            .metadata_ignored,
            => .warning,
            .root_unscanned,
            .entry_skipped,
            .directory_unscanned,
            .link_unresolved,
            .link_unfollowed,
            .scan_capped,
            .paths_capped,
            .path_invalid,
            .too_large,
            .unread,
            .not_text,
            .too_long,
            .front_matter_missing,
            .front_matter_unclosed,
            .description_missing,
            .description_nul,
            .directory_invalid,
            .shadowed,
            .count_capped,
            => .failure,
        },
    };
}

fn writeEvent(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: *const application.Record.Event,
) WriteError!void {
    switch (value.*) {
        .no_account => try writer.writeAll("Select an account to sign in."),
        .account_active => |account| try writer.print(
            "{s} is already the active account.",
            .{application.query.accountId(account)},
        ),
        .model_active => |choice| try writer.print(
            "Drinky already uses {s}/{s}.",
            .{ application.query.accountId(choice.account), choice.model },
        ),
        .effort_active => |level| try writer.print("The effort level is already {t}.", .{level}),
        .use_changed => |use| try writeUse(writer, &use),
        .effort_changed => |level| try writer.print(
            "Drinky set the effort level to {t}.",
            .{level},
        ),
        .choices_busy => try writer.writeAll(
            "Drinky could not save the choices of this project because another Drinky " ++
                "instance is writing the state file. Drinky tries again at the next save.",
        ),
        .choices_corrupt => |path| try writer.print(
            "Drinky stopped saving the choices of this project because Drinky cannot read the " ++
                "file {s} as a JSON object. Delete that file to let the next start save again.",
            .{path},
        ),
        .choices_unsaved => |unsaved| try writer.print(
            "Drinky stopped saving the choices of this project to {s} because of error {s}.",
            .{ unsaved.path, unsaved.cause },
        ),
        .signed_in => |signed_in| if (signed_in.model) |model| try writer.print(
            "Drinky signed in and now uses {s}/{s}.",
            .{ application.query.accountId(signed_in.account), model },
        ) else try writer.print(
            "Drinky signed in to {s}.",
            .{application.query.accountId(signed_in.account)},
        ),
        .sign_in_failed => |*sign_in| try writeSignInFailure(writer, sign_in),
        .credentials_unsaved => |unsaved| try writer.print(
            "Drinky could not save the credentials for {s}{s}{s} because of error {s}. " ++
                "The sign-in stays active until Drinky exits.",
            .{
                application.query.accountId(unsaved.account),
                if (unsaved.path == null) "" else " to ",
                unsaved.path orelse "",
                unsaved.cause,
            },
        ),
        .browser_unopened => |account| try writer.print(
            "Drinky could not open the browser for the sign-in to {s}. Open the URL above.",
            .{application.query.accountId(account)},
        ),
        .callback_unexpected => |account| try writer.print(
            "The sign-in to {s} does not accept a callback URL. Complete the sign-in in the " ++
                "browser.",
            .{application.query.accountId(account)},
        ),
        .callback_invalid => |account| try writer.print(
            "The line is not the callback URL for the sign-in to {s}. " ++
                "Paste the complete callback URL from the browser.",
            .{application.query.accountId(account)},
        ),
        .callback_received => |account| try writer.print(
            "Drinky already received the response for the sign-in to {s}.",
            .{application.query.accountId(account)},
        ),
        .callback_unreplayed => |unreplayed| try writer.print(
            "Drinky could not replay the callback URL for the sign-in to {s} " ++
                "because of error {s}.",
            .{ application.query.accountId(unreplayed.account), unreplayed.cause },
        ),
        .sign_out_failed => |cause| try writer.print(
            "Drinky could not sign out because of error {s}.",
            .{cause},
        ),
        .signed_out => |*signed_out| try writeSignedOut(writer, signed_out),
        .credential_unremoved => |unremoved| try writer.print(
            "Drinky could not remove the rejected credential for {s} because of error {s}.",
            .{ application.query.accountId(unremoved.account), unremoved.cause },
        ),
        .credential_reloaded => |reload| {
            try writer.writeAll(credential_reloaded);
            switch (reload.next) {
                .retry_turn => try writer.writeAll("Try the turn again."),
                .step => |step| try writeStep(writer, reload.account, step),
            }
        },
        .models_fetched => |*fetched| try writeFetched(writer, fetched),
        .models_unfetched => |unfetched| {
            try writer.print(
                "Drinky could not fetch the model list of {s} because of error {s}.",
                .{ application.query.accountId(unfetched.account), unfetched.cause },
            );
            const cause = unfetched.metadata_save_error orelse return;
            try writer.print(metadata_unsaved ++ " The metadata serves this session.", .{cause});
        },
        .attempt_failed => |attempt| {
            var buffer: [24]u8 = undefined;
            const delay = application.support.duration(&buffer, @intCast(@min(
                attempt.delay_ms,
                std.math.maxInt(i64),
            )));
            try writer.print("Attempt {d} failed. {s} Drinky tries again in {s}.", .{
                attempt.attempt,
                failureSentence(attempt.reason),
                delay,
            });
            if (attempt.details) |details| try writer.print(" Details: {s}", .{details});
        },
        .model_substituted => |substitution| try writer.print(
            "The provider answered with the model \"{s}\" instead of the requested model " ++
                "\"{s}\".",
            .{ substitution.served, substitution.requested },
        ),
        .reply_truncated => try writer.writeAll(
            "The reply is incomplete. The model reached an output or context limit.",
        ),
        .turn_canceled => try writer.writeAll("You canceled the turn."),
        .tool_rounds_exhausted => try writer.writeAll(
            "The turn reached the limit for tool rounds.",
        ),
        .request_failed => |*failure| try writeFailure(writer, failure),
        .effort_unknown => |unknown| try writer.print(
            "Drinky ignored the configured default effort level \"{s}\" because Drinky does " ++
                "not know that level. Drinky uses the effort level \"{t}\".",
            .{ unknown.value, unknown.used },
        ),
        .bash_timeout_ignored => |range| try writer.print(
            "Drinky ignored the configured command timeout {d} because the value must be from " ++
                "{d} to {d} milliseconds. Drinky uses the default timeout of {d} milliseconds.",
            .{ range.value, range.min, range.max, range.used },
        ),
        .window_pages_ignored => |range| try writer.print(
            "Drinky ignored the configured window page count {d} because the count must be " ++
                "from {d} to {d}. Drinky uses the default count of {d} pages.",
            .{ range.value, range.min, range.max, range.used },
        ),
        .gauge_ignored => |shares| try writer.print(
            "Drinky ignored the gauge shares {d} and {d}. A share must be from {d} to {d}, and " ++
                "the warning share must not pass the error share. Drinky uses the shares {d} " ++
                "and {d}.",
            .{
                shares.dropped.percent_warning,
                shares.dropped.percent_error,
                shares.min,
                shares.max,
                shares.used.percent_warning,
                shares.used.percent_error,
            },
        ),
        .required_skills_capped => |capped| try writer.print(
            "Drinky used only the first {d} required skills in {s}.",
            .{ capped.limit, capped.path },
        ),
        .config_unread => |unread| try writer.print(
            "Drinky could not read the config file {s} because of error {s}. Drinky uses " ++
                "the default value of each key.",
            .{ unread.path, unread.cause },
        ),
        .config_key_unknown => |unknown| try writer.print(
            "Drinky ignored the unknown config key \"{s}\" in {s}.",
            .{ unknown.key, unknown.path },
        ),
        .config_keys_omitted => |path| try writer.print(
            "Drinky omitted the remaining unknown config keys in {s}.",
            .{path},
        ),
        .instruction_report => |*report| try writeInstructionReport(writer, report),
        .skill_report => |*report| try writeSkillReport(gpa, writer, report),
        .reports_omitted => |subject| try writer.print(
            "Drinky omitted the remaining messages about the {s}.",
            .{switch (subject) {
                .config => "config file",
                .instructions => "instruction files",
                .skills => "skill files",
            }},
        ),
    }
}

fn writeUse(
    writer: *std.Io.Writer,
    use: *const application.Record.Event.Use,
) std.Io.Writer.Error!void {
    switch (use.*) {
        .model => |choice| try writer.print(
            "Drinky now uses {s}/{s}.",
            .{ application.query.accountId(choice.account), choice.model },
        ),
        .account => |next| {
            try writer.print(
                "Drinky now uses {s}. ",
                .{application.query.accountId(next.account)},
            );
            try writeStep(writer, next.account, next.step);
        },
    }
}

fn writeStep(
    writer: *std.Io.Writer,
    account: usize,
    step: application.Record.Event.Step,
) std.Io.Writer.Error!void {
    const id = application.query.accountId(account);
    switch (step) {
        .select_model => try writer.print(
            "Select a model of {s} with " ++ reference.line(.model) ++ ".",
            .{id},
        ),
        .fetch_models => try writer.print(
            "Fetch the model list of {s} with " ++ reference.line(.model) ++ ".",
            .{id},
        ),
    }
}

fn writeSignedOut(
    writer: *std.Io.Writer,
    signed_out: *const application.Record.Event.SignedOut,
) std.Io.Writer.Error!void {
    try writer.print(
        "Drinky signed out of {s}.",
        .{application.query.accountId(signed_out.account)},
    );
    switch (signed_out.next) {
        .unchanged => if (signed_out.rejected) try writer.writeAll(
            " Use " ++ reference.line(.login) ++ " to sign in again.",
        ),
        .none => try writer.writeAll(" Select an account to sign in."),
        .use => |*use| {
            try writer.writeByte(' ');
            try writeUse(writer, use);
        },
    }
}

fn writeSignInFailure(
    writer: *std.Io.Writer,
    sign_in: *const application.Record.Event.SignInFailure,
) std.Io.Writer.Error!void {
    try writer.writeAll(switch (sign_in.reason) {
        .canceled => return writer.print(
            "You canceled the sign-in to {s}.",
            .{application.query.accountId(sign_in.account)},
        ),
        .callback_timeout => "Drinky stopped the sign-in because the browser did not " ++
            "respond in time.",
        .callback_too_large => "Drinky could not sign in because the browser response was " ++
            "too large.",
        .callback_timeout_unavailable => "Drinky could not sign in because it could not set " ++
            "a browser time limit.",
        .not_authorized => "The provider did not authorize Drinky. Start the sign-in again.",
        .device_code_expired => "Drinky stopped the sign-in because the authorization did " ++
            "not arrive in time.",
        .state_mismatch => "The response belongs to another sign-in. Start the sign-in again.",
        .grant_rejected => "The provider rejected the authorization. Start the sign-in again.",
        .service_unavailable => "The provider credential service is not available. " ++
            "Try the sign-in again later.",
        .failed => return writer.print(
            "Drinky could not sign in because of error {s}.",
            .{sign_in.cause},
        ),
    });
}

fn writeFetched(
    writer: *std.Io.Writer,
    fetched: *const application.Record.Event.Fetch,
) std.Io.Writer.Error!void {
    try writer.print(
        "Drinky fetched the model list of {s}.",
        .{application.query.accountId(fetched.account)},
    );
    if (fetched.metadata_error) |cause| try writer.print(
        " Drinky could not fetch the public metadata because of error {s}.",
        .{cause},
    );
    if (fetched.models_save_error) |cause| try writer.print(
        " Drinky could not save the model list because of error {s}.",
        .{cause},
    );
    if (fetched.metadata_save_error) |cause| try writer.print(metadata_unsaved, .{cause});
    const list_unsaved = fetched.models_save_error != null;
    const metadata_kept = fetched.metadata_save_error != null;
    try writer.writeAll(if (list_unsaved and metadata_kept)
        " Both serve this session."
    else if (list_unsaved)
        " The list serves this session."
    else if (metadata_kept)
        " The metadata serves this session."
    else
        "");
    if (fetched.count == 0) return writer.writeAll(" The account offers no model now.");
    if (fetched.metadata_error != null and !list_unsaved) try writer.print(
        " The account offers {d} model{s} now.",
        .{ fetched.count, application.support.pluralSuffix(fetched.count) },
    );
}

fn writeInstructionReport(
    writer: *std.Io.Writer,
    report: *const application.Record.Event.InstructionReport,
) std.Io.Writer.Error!void {
    const noun = switch (report.scope) {
        .user => "user instruction",
        .project => "project instruction",
    };
    switch (report.problem) {
        .duplicate => |path| try writer.print(
            "Drinky skipped the {s} file {s} because Drinky already loaded the same file.",
            .{ noun, path },
        ),
        .empty => |path| try writer.print(
            "Drinky skipped the {s} file {s} because the file is empty.",
            .{ noun, path },
        ),
        .too_large => |capped| try writer.print(
            "Drinky skipped the {s} file {s} because the file is larger than {d} KiB.",
            .{ noun, capped.path, capped.limit },
        ),
        .not_text => |path| try writer.print(
            "Drinky skipped the {s} file {s} because the file is not UTF-8 text.",
            .{ noun, path },
        ),
        .unread => |failed| try writer.print(
            "Drinky could not read the {s} file {s} because of error {s}.",
            .{ noun, failed.path, failed.cause },
        ),
        .count_capped => |capped| try writer.print(
            "Drinky skipped the {s} file {s} because Drinky already loaded {d} files.",
            .{ noun, capped.path, capped.limit },
        ),
        .total_capped => |capped| try writer.print(
            "Drinky skipped the {s} file {s} to keep the total at or below {d} KiB.",
            .{ noun, capped.path, capped.limit },
        ),
        .marker_uninspected => |failed| try writer.print(
            "Drinky could not inspect the repository marker {s} because of error {s}.",
            .{ failed.path, failed.cause },
        ),
        .directory_unscanned => |failed| try writer.print(
            "Drinky could not scan the directory {s} for AGENTS.md because of error {s}.",
            .{ failed.path, failed.cause },
        ),
        .scan_stopped => |failed| try writer.print(
            "Drinky stopped the scan for AGENTS.md in {s} because of error {s}.",
            .{ failed.path, failed.cause },
        ),
        .scan_capped => |capped| try writer.print(
            "Drinky stopped the scan for AGENTS.md in {s} after {d} entries.",
            .{ capped.path, capped.limit },
        ),
        .claude_ignored => |path| try writer.print(
            "Drinky ignored the CLAUDE.md file {s}. Add or link a project instruction file " ++
                "named AGENTS.md in the same directory.",
            .{path},
        ),
        .agent_ignored => |path| try writer.print(
            "Drinky ignored the AGENT.md file {s}. Rename the file to AGENTS.md if the file " ++
                "contains project instructions.",
            .{path},
        ),
        .uninspected => |failed| try writer.print(
            "Drinky could not inspect the {s} path {s} because of error {s}.",
            .{ noun, failed.path, failed.cause },
        ),
        .link_target_missing => |path| try writer.print(
            "Drinky skipped the {s} file {s} because the symbolic-link target does not exist.",
            .{ noun, path },
        ),
        .link_uninspected => |failed| try writer.print(
            "Drinky could not inspect the symbolic-link target of the {s} file {s} because of " ++
                "error {s}.",
            .{ noun, failed.path, failed.cause },
        ),
        .link_target_irregular => |path| try writer.print(
            "Drinky skipped the {s} file {s} because the symbolic-link target is not a regular " ++
                "file.",
            .{ noun, path },
        ),
        .irregular => |path| try writer.print(
            "Drinky skipped the {s} path {s} because the path is not a regular file.",
            .{ noun, path },
        ),
        .unopened => |failed| try writer.print(
            "Drinky could not open the {s} file {s} because of error {s}.",
            .{ noun, failed.path, failed.cause },
        ),
        .open_uninspected => |failed| try writer.print(
            "Drinky could not inspect the open {s} file {s} because of error {s}.",
            .{ noun, failed.path, failed.cause },
        ),
        .unresolved => |failed| try writer.print(
            "Drinky could not resolve the {s} file {s} because of error {s}.",
            .{ noun, failed.path, failed.cause },
        ),
        .outside => |path| try writer.print(
            "Drinky skipped the {s} file {s} because the file resolves outside the project " ++
                "boundary.",
            .{ noun, path },
        ),
        .paths_capped => |limit| try writer.print(
            "Drinky skipped the remaining {s} files because Drinky already inspected {d} entries.",
            .{ noun, limit },
        ),
        .missing => |path| try writer.print(
            "Drinky skipped the {s} path {s} because the path does not exist.",
            .{ noun, path },
        ),
    }
}

fn writeSkillReport(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    report: *const application.Record.Event.SkillReport,
) WriteError!void {
    switch (report.*) {
        .root_unscanned => |failed| try writer.print(
            "Drinky could not scan the skill directory {s} because of error {s}.",
            .{ failed.path, failed.cause },
        ),
        .entry_skipped => |failed| try writer.print(
            "Drinky skipped one entry in {s} because of error {s}.",
            .{ failed.path, failed.cause },
        ),
        .directory_unscanned => |skip| try writer.print(
            "Drinky could not scan the skill directory {s}/{s} because of error {s}.",
            .{ skip.root, skip.path, skip.cause },
        ),
        .link_unresolved => |skip| try writer.print(
            "Drinky could not resolve the symbolic link {s}/{s} because of error {s}.",
            .{ skip.root, skip.path, skip.cause },
        ),
        .link_unfollowed => |skip| try writer.print(
            "Drinky could not follow the symbolic link {s}/{s} because of error {s}.",
            .{ skip.root, skip.path, skip.cause },
        ),
        .scan_capped => |capped| try writer.print(
            "Drinky stopped the skill scan in {s} after {d} entries.",
            .{ capped.path, capped.limit },
        ),
        .paths_capped => |capped| try writer.print(
            "Drinky used only the first {d} SKILL.md paths in {s}.",
            .{ capped.limit, capped.path },
        ),
        .path_invalid => |path| {
            const shown = try application.support.diagnostic(gpa, path);
            defer gpa.free(shown);
            try writer.print(
                "Drinky skipped the skill path {s} because it is not valid UTF-8.",
                .{shown},
            );
        },
        .too_large => |capped| try writer.print(
            "Drinky skipped {s} because the skill file is larger than {d} bytes.",
            .{ capped.path, capped.limit },
        ),
        .unread => |failed| try writer.print(
            "Drinky could not read the skill file {s} because of error {s}.",
            .{ failed.path, failed.cause },
        ),
        .not_text => |path| try writer.print(
            "Drinky skipped {s} because the skill file is not UTF-8 text.",
            .{path},
        ),
        .too_long => |capped| try writer.print(
            "Drinky skipped {s} because the skill file has more than {d} lines.",
            .{ capped.path, capped.limit },
        ),
        .front_matter_missing => |path| try writer.print(
            "Drinky skipped {s} because the YAML front matter is missing.",
            .{path},
        ),
        .front_matter_unclosed => |path| try writer.print(
            "Drinky skipped {s} because the YAML front matter is not closed.",
            .{path},
        ),
        .description_missing => |path| try writer.print(
            "Drinky skipped {s} because the skill description is missing or empty.",
            .{path},
        ),
        .description_nul => |path| try writer.print(
            "Drinky skipped {s} because the skill description contains a NUL byte.",
            .{path},
        ),
        .name_invalid => |named| {
            const shown = try application.support.diagnostic(gpa, named.name);
            defer gpa.free(shown);
            try writer.print(
                "Drinky used the directory name for {s} because the skill name \"{s}\" is not " ++
                    "valid.",
                .{ named.path, shown },
            );
        },
        .name_missing => |path| try writer.print(
            "Drinky used the directory name for {s} because the skill name is missing.",
            .{path},
        ),
        .directory_invalid => |named| try writer.print(
            "Drinky skipped {s} because the directory name \"{s}\" is not a valid skill name.",
            .{ named.path, named.name },
        ),
        .name_differs => |difference| try writer.print(
            "The skill name \"{s}\" in {s} differs from the directory name \"{s}\".",
            .{ difference.name, difference.path, difference.directory },
        ),
        .description_shortened => |capped| try writer.print(
            "Drinky shortened the catalog description for {s} because it has more than " ++
                "{d} characters.",
            .{ capped.path, capped.limit },
        ),
        .metadata_ignored => |path| try writer.print(
            "Drinky ignored the metadata in {s} because the value is not a block map.",
            .{path},
        ),
        .shadowed => |shadowed| try writer.print(
            "Drinky ignored the skill \"{s}\" at {s} because {s} has priority.",
            .{ shadowed.name, shadowed.path, shadowed.winner },
        ),
        .count_capped => |limit| try writer.print(
            "Drinky loaded only the first {d} distinct skills.",
            .{limit},
        ),
    }
}

fn failureSentence(reason: application.Failure.Reason) []const u8 {
    return switch (reason) {
        .unauthorized => "The credential is missing or invalid.",
        .rate_limited => "The provider limits the request rate.",
        .quota_exhausted => "The account has no quota left.",
        .overloaded => "The provider is overloaded.",
        .invalid_request => "The request is invalid.",
        .context_overflow => "The conversation does not fit the context window of the model.",
        .network => "Drinky could not reach the provider.",
        .invalid_reply => "Drinky did not receive the complete reply of the model.",
        .empty_reply => "The model returned an empty reply.",
        .unsupported_reply => "Drinky cannot keep the reply because the model returned a " ++
            "refusal, a pause, or an unsupported result.",
        .too_many_tool_calls => "Drinky stopped the reply because it asked for too many tool " ++
            "calls.",
        .concurrency_unavailable => "Drinky could not start a task.",
    };
}

test "every fetch report states the writes that failed and an empty list" {
    const account = accounts.testing.anthropic_api_key;
    const fetched = "Drinky fetched the model list of anthropic-api-key.";
    const cases = [_]struct {
        event: application.Record.Event,
        severity: ui.Message.Severity,
        text: []const u8,
    }{
        .{
            .event = .{ .models_fetched = .{ .account = account, .count = 0 } },
            .severity = .warning,
            .text = fetched ++ " The account offers no model now.",
        },
        .{
            .event = .{ .models_fetched = .{
                .account = account,
                .count = 2,
                .metadata_save_error = "StoreBusy",
            } },
            .severity = .failure,
            .text = fetched ++ " Drinky could not save the public metadata because of error " ++
                "StoreBusy. The metadata serves this session.",
        },
        .{
            .event = .{ .models_fetched = .{
                .account = account,
                .count = 0,
                .metadata_error = "Timeout",
                .models_save_error = "StoreBusy",
            } },
            .severity = .failure,
            .text = fetched ++ " Drinky could not fetch the public metadata because of error " ++
                "Timeout. Drinky could not save the model list because of error StoreBusy. The " ++
                "list serves this session. The account offers no model now.",
        },
        .{
            .event = .{ .models_fetched = .{
                .account = account,
                .count = 2,
                .models_save_error = "StoreBusy",
                .metadata_save_error = "AccessDenied",
            } },
            .severity = .failure,
            .text = fetched ++ " Drinky could not save the model list because of error " ++
                "StoreBusy. Drinky could not save the public metadata because of error " ++
                "AccessDenied. Both serve this session.",
        },
        .{
            .event = .{ .models_fetched = .{
                .account = account,
                .count = 1,
                .metadata_error = "Timeout",
            } },
            .severity = .failure,
            .text = fetched ++ " Drinky could not fetch the public metadata because of error " ++
                "Timeout. The account offers 1 model now.",
        },
        .{
            .event = .{ .models_fetched = .{
                .account = account,
                .count = 2,
                .metadata_error = "Timeout",
            } },
            .severity = .failure,
            .text = fetched ++ " Drinky could not fetch the public metadata because of error " ++
                "Timeout. The account offers 2 models now.",
        },
        .{
            .event = .{ .models_unfetched = .{ .account = account, .cause = "ConnectionRefused" } },
            .severity = .failure,
            .text = "Drinky could not fetch the model list of anthropic-api-key because of " ++
                "error ConnectionRefused.",
        },
        .{
            .event = .{ .models_unfetched = .{
                .account = account,
                .cause = "ConnectionRefused",
                .metadata_save_error = "StoreBusy",
            } },
            .severity = .failure,
            .text = "Drinky could not fetch the model list of anthropic-api-key because of " ++
                "error ConnectionRefused. Drinky could not save the public metadata because of " ++
                "error StoreBusy. The metadata serves this session.",
        },
    };
    for (&cases) |*case| try expectEvent(&case.event, case.severity, case.text);
}

fn expectEvent(
    value: *const application.Record.Event,
    expected_severity: ui.Message.Severity,
    text: []const u8,
) !void {
    const message = try event(std.testing.allocator, value);
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(text, message.content);
    try std.testing.expectEqual(expected_severity, message.severity);
}

test "an account change names the model, the model selection, or the model fetch" {
    const plan = accounts.testing.openai_plan;
    const key = accounts.testing.openai_api_key;
    const with_model: application.Record.Event.Use = .{ .model = .{
        .account = key,
        .model = "gpt-5.6-sol",
    } };
    const cases = [_]struct { event: application.Record.Event, text: []const u8 }{
        .{
            .event = .{ .use_changed = with_model },
            .text = "Drinky now uses openai-api-key/gpt-5.6-sol.",
        },
        .{
            .event = .{ .use_changed = .{ .account = .{ .account = key, .step = .select_model } } },
            .text = "Drinky now uses openai-api-key. Select a model of openai-api-key with /model.",
        },
        .{
            .event = .{ .signed_out = .{ .account = plan, .rejected = false, .next = .unchanged } },
            .text = "Drinky signed out of openai-plan.",
        },
        .{
            .event = .{ .signed_out = .{ .account = plan, .rejected = true, .next = .unchanged } },
            .text = "Drinky signed out of openai-plan. Use /login to sign in again.",
        },
        .{
            .event = .{ .signed_out = .{ .account = plan, .rejected = true, .next = .none } },
            .text = "Drinky signed out of openai-plan. Select an account to sign in.",
        },
        .{
            .event = .{ .signed_out = .{
                .account = plan,
                .rejected = false,
                .next = .{ .use = with_model },
            } },
            .text = "Drinky signed out of openai-plan. Drinky now uses openai-api-key/gpt-5.6-sol.",
        },
        .{
            .event = .{ .signed_out = .{
                .account = plan,
                .rejected = true,
                .next = .{ .use = .{ .account = .{ .account = key, .step = .fetch_models } } },
            } },
            .text = "Drinky signed out of openai-plan. Drinky now uses openai-api-key. " ++
                "Fetch the model list of openai-api-key with /model.",
        },
        .{
            .event = .{ .credential_reloaded = .{ .account = plan, .next = .retry_turn } },
            .text = credential_reloaded ++ "Try the turn again.",
        },
        .{
            .event = .{ .credential_reloaded = .{
                .account = plan,
                .next = .{ .step = .fetch_models },
            } },
            .text = credential_reloaded ++ "Fetch the model list of openai-plan with /model.",
        },
        .{
            .event = .{ .signed_in = .{ .account = plan, .model = null } },
            .text = "Drinky signed in to openai-plan.",
        },
    };
    for (&cases) |*case| try expectEvent(&case.event, .information, case.text);
}

test "an unsaved credential names its path only when the store has one" {
    const plan = accounts.testing.openai_plan;
    const tail = " because of error AccessDenied. The sign-in stays active until Drinky exits.";
    try expectEvent(
        &.{ .credentials_unsaved = .{ .account = plan, .path = null, .cause = "AccessDenied" } },
        .failure,
        "Drinky could not save the credentials for openai-plan" ++ tail,
    );
    try expectEvent(
        &.{ .credentials_unsaved = .{
            .account = plan,
            .path = "/auth.json",
            .cause = "AccessDenied",
        } },
        .failure,
        "Drinky could not save the credentials for openai-plan to /auth.json" ++ tail,
    );
}

test "a sign-in failure names its cause, and a canceled sign-in is information" {
    const plan = accounts.testing.anthropic_plan;
    const cases = [_]struct {
        failure: application.Record.Event.SignInFailure,
        severity: ui.Message.Severity,
        text: []const u8,
    }{
        .{
            .failure = .{ .account = plan, .reason = .canceled, .cause = "Canceled" },
            .severity = .information,
            .text = "You canceled the sign-in to anthropic-plan.",
        },
        .{
            .failure = .{
                .account = plan,
                .reason = .not_authorized,
                .cause = "AuthorizationDenied",
            },
            .severity = .failure,
            .text = "The provider did not authorize Drinky. Start the sign-in again.",
        },
        .{
            .failure = .{ .account = plan, .reason = .failed, .cause = "BadTokenResponse" },
            .severity = .failure,
            .text = "Drinky could not sign in because of error BadTokenResponse.",
        },
    };
    for (&cases) |*case|
        try expectEvent(&.{ .sign_in_failed = case.failure }, case.severity, case.text);
}

test "a failure and an attempt keep the reason sentence and add their details" {
    try expectEvent(
        &.{ .request_failed = .{ .reason = .unauthorized, .details = null } },
        .failure,
        "The credential is missing or invalid.",
    );
    try expectEvent(
        &.{ .request_failed = .{ .reason = .network, .details = "Connection closed." } },
        .failure,
        "Drinky could not reach the provider. Details: Connection closed.",
    );
    try expectEvent(
        &.{ .attempt_failed = .{
            .attempt = 2,
            .reason = .overloaded,
            .details = "529 Overloaded: busy",
            .delay_ms = 1500,
        } },
        .information,
        "Attempt 2 failed. The provider is overloaded. Drinky tries again in 1.5s. " ++
            "Details: 529 Overloaded: busy",
    );
}

test "each report kind takes its severity" {
    const cases = [_]struct {
        event: application.Record.Event,
        severity: ui.Message.Severity,
    }{
        .{
            .event = .{ .skill_report = .{ .name_missing = "/s/SKILL.md" } },
            .severity = .warning,
        },
        .{
            .event = .{ .skill_report = .{ .name_differs = .{
                .path = "/s/SKILL.md",
                .name = "a",
                .directory = "b",
            } } },
            .severity = .warning,
        },
        .{
            .event = .{ .skill_report = .{ .description_shortened = .{
                .path = "/s/SKILL.md",
                .limit = 1024,
            } } },
            .severity = .warning,
        },
        .{
            .event = .{ .skill_report = .{ .metadata_ignored = "/s/SKILL.md" } },
            .severity = .warning,
        },
        .{
            .event = .{ .skill_report = .{ .description_missing = "/s/SKILL.md" } },
            .severity = .failure,
        },
        .{
            .event = .{ .skill_report = .{ .directory_invalid = .{
                .path = "/s/SKILL.md",
                .name = "Bad Name",
            } } },
            .severity = .failure,
        },
        .{
            .event = .{ .instruction_report = .{
                .scope = .project,
                .problem = .{ .empty = "/a" },
            } },
            .severity = .information,
        },
        .{
            .event = .{ .instruction_report = .{
                .scope = .project,
                .problem = .{ .duplicate = "/a" },
            } },
            .severity = .failure,
        },
        .{ .event = .{ .reports_omitted = .skills }, .severity = .failure },
        .{ .event = .{ .config_keys_omitted = "/config.json" }, .severity = .failure },
    };
    for (&cases) |*case| {
        const message = try event(std.testing.allocator, &case.event);
        defer message.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.severity, message.severity);
    }
}

test "a refusal names the action of its command, and a silent refusal holds no text" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        command: application.Command,
        refusal: application.Refusal,
        text: ?[]const u8,
    }{
        .{
            .command = .{ .send_message = "Task." },
            .refusal = .signed_out,
            .text = "Sign in with /login before you send a message.",
        },
        .{
            .command = .{ .prepare_handoff = "" },
            .refusal = .no_model,
            .text = "Select a model with /model before you prepare a handoff.",
        },
        .{
            .command = .{ .invoke_skill = .{ .name = "other", .arguments = "", .line = "" } },
            .refusal = .{ .skill_unreadable = .{ .name = "demo", .cause = error.FileNotFound } },
            .text = "Drinky could not load the skill demo because of error FileNotFound.",
        },
        .{
            .command = .{ .select_account = accounts.testing.openai_plan },
            .refusal = .{ .credential_missing = accounts.testing.xai_api_key },
            .text = "Set XAI_API_KEY in the environment. Restart Drinky to use xai-api-key.",
        },
        .{
            .command = .{ .select_account = accounts.testing.openai_plan },
            .refusal = .{ .account_unloaded = .{
                .account = accounts.testing.google_cloud_key,
                .cause = error.FileNotFound,
            } },
            .text = "Drinky could not load the google-cloud-key account because of error " ++
                "FileNotFound. Fix it and restart Drinky.",
        },
        .{
            .command = .{ .fetch_models = accounts.testing.openai_plan },
            .refusal = .signed_out,
            .text = null,
        },
        .{ .command = .{ .send_message = "Task." }, .refusal = .busy, .text = null },
        .{ .command = .retry, .refusal = .stale, .text = null },
    };
    for (&cases) |*case| {
        const maybe_message = try refusal(gpa, &case.command, &case.refusal);
        defer if (maybe_message) |message| message.deinit(gpa);
        const text = case.text orelse {
            try std.testing.expect(maybe_message == null);
            continue;
        };
        try std.testing.expectEqualStrings(text, maybe_message.?.content);
    }
}

test "a startup report escapes control bytes, and an invalid skill path shows its bytes" {
    try expectEvent(
        &.{ .skill_report = .{ .path_invalid = "user/\xff/SKILL.md" } },
        .failure,
        "Drinky skipped the skill path user/\\xff/SKILL.md because it is not valid UTF-8.",
    );
    try expectEvent(
        &.{ .instruction_report = .{
            .scope = .user,
            .problem = .{ .empty = "/home/\x1b[31m.md" },
        } },
        .information,
        "Drinky skipped the user instruction file /home/\\x1b[31m.md because the file is empty.",
    );
}

test "an event text releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(core.testing.no_resize_allocator, checkEvent, .{});
}

fn checkEvent(gpa: std.mem.Allocator) !void {
    const message = try event(gpa, &.{ .skill_report = .{ .name_invalid = .{
        .path = "/skills/demo/SKILL.md",
        .name = "Bad\x00Name",
    } } });
    defer message.deinit(gpa);
    try std.testing.expectEqual(ui.Message.Severity.warning, message.severity);
}
