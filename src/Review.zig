//! The `/review` workflow core: the roles, the report classification, the
//! generated requests, and the phase transitions. It owns no agent and runs no
//! turn. The app drives it: each complete role report goes in, and the machine
//! answers with the next step of the workflow.
//!
//! The workflow reviews every pending change from `HEAD` in bounded rounds. A
//! fresh reviewer starts a round and reports defects. The persistent judge
//! validates the findings and settles the review. A fresh fixer applies the
//! judge report, or disputes it with evidence. Only a fresh reviewer starts a
//! round, and the round ceiling bounds unattended progress.
//!
//! Every role report starts with its marker line, so a reply to the user can
//! never travel as a report. An unmarked reply gets one correction request,
//! and a second unmarked reply after that request stops the workflow.

const std = @import("std");

const Review = @This();

gpa: std.mem.Allocator,
/// The reviewer-round ceiling. A raise adds one round to the active workflow.
rounds_max: u64,
/// Rounds a fresh reviewer started. The count names the active round, and it
/// never falls back, so a canceled round still spent its number.
rounds_started: u64 = 0,
/// Rounds whose reviewer returned a complete report.
rounds_completed: u64 = 0,
/// Fixer passes whose fixer returned a complete report.
passes_completed: u64 = 0,
/// The active phase. The app maps it onto the interface.
phase: Phase = .setup,
/// The pass of the fixer that a `fix required` decision starts next. A
/// rejected pass-1 dispute moves it to `second`, and a fresh round resets it.
next_pass: Pass = .first,
/// The latest complete judge decision, or null before the first one. A raise
/// of the ceiling resumes it.
decision: ?Decision = null,
/// Whether an answer at a hold moved the judge past `decision`. A raise then
/// asks the judge to decide again, so every answer of the user reaches the next
/// generated request. A settled hold offers no step while the flag stands.
decision_stale: bool = false,
/// The latest reviewer report. The next judge request consumes it. Owned.
reviewer_report: ?[]u8 = null,
/// The latest fixer report with its source round and pass. The next judge
/// request consumes it. Owned.
fixer_report: ?FixerReport = null,
/// The latest `fix required` judge report. The next fixer request consumes
/// it. Owned.
judge_report: ?[]u8 = null,
/// Whether the machine already composed the one correction request of the
/// active phase reply. A second unmarked reply then stops the workflow. A
/// step that no compose follows leaves the budget whole.
correction_requested: bool = false,
/// Whether the active round already counted its reviewer report. A successor
/// turn replaces the report and counts no second completion.
round_reported: bool = false,
/// Whether the active pass already counted its fixer report, like
/// `round_reported`.
pass_reported: bool = false,
/// The committed workflow messages that wait for the next judge request, in
/// user order. Owned.
pending_messages: std.ArrayList(Message) = .empty,

/// The three roles of the workflow. The reviewer and the fixer run fresh per
/// phase, and the judge keeps its history until the workflow ends.
pub const Role = enum {
    reviewer,
    judge,
    fixer,

    /// The name of the role in the interface.
    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .reviewer => "Reviewer",
            .judge => "Judge",
            .fixer => "Fixer",
        };
    }
};

/// The two fixer passes of one round. At most two passes run between reviewer
/// rounds, because only a rejected pass-1 dispute adds the second pass.
pub const Pass = enum {
    first,
    second,

    /// The pass number that a generated request and its transcript line name.
    pub fn number(self: Pass) u64 {
        return switch (self) {
            .first => 1,
            .second => 2,
        };
    }
};

/// The decision line of a judge report.
pub const Decision = enum {
    fix_required,
    review_settled,
    user_decision_required,
};

/// The application line of a fixer report.
pub const Application = enum {
    all,
    partial,
    none,
};

/// The active phase, as the machine tracks it. Holds stay with the app,
/// because a hold reads the editor and the machine reads no interface.
pub const Phase = union(enum) {
    setup,
    reviewer,
    judge,
    fixer: Pass,
};

/// What the app does next after a complete role report.
pub const Step = union(enum) {
    /// Start a fresh reviewer round.
    start_reviewer,
    /// Start the persistent judge over the pending reports and messages.
    start_judge,
    /// Ask the judge to decide again, because an answer at the limit hold
    /// moved it past its latest decision.
    resume_judge,
    /// Start a fresh fixer over the stored judge report.
    start_fixer: Pass,
    /// The judge needs a user decision, so the workflow waits.
    hold_judge,
    /// The ceiling blocks progress, so the workflow waits.
    hold_limit,
    /// The judge settled the review, so the workflow waits.
    settled,
    /// The phase reply holds no valid marker line, so one correction request
    /// follows in the role context.
    request_correction,
    /// A second unmarked reply of the active phase stops the workflow.
    stop_invalid,
};

/// One committed workflow message: human text that the user sent to a fresh
/// role, copied once for the next judge request.
pub const Message = struct {
    round: u64,
    role: Role,
    /// Owned by the machine.
    text: []u8,
};

/// One fixer report with the round and the pass that produced it.
pub const FixerReport = struct {
    round: u64,
    pass: Pass,
    /// Owned by the machine.
    text: []u8,
};

/// The static core of the reviewer prompt. The environment, instruction,
/// skill, and tool sections join it, so the reviewer holds the same guidance
/// as a normal turn. The nonmutation rules are prompt instructions, not tool
/// restrictions.
pub const reviewer_core =
    \\You are the reviewer of one bounded review workflow. Drinky, a terminal coding-agent
    \\harness, drives this conversation with generated requests. The user of Drinky wrote none
    \\of them. A direct message is the one exception: the user typed it, and it steers your
    \\review.
    \\
    \\## Target
    \\
    \\The target is every staged, unstaged, and untracked change from `HEAD`. The staging state
    \\of a file has no effect on the target. Inspect the target through this path:
    \\
    \\1. Run `git status --short --untracked-files=all`.
    \\2. Run `git diff HEAD` for the tracked changes.
    \\3. Read every untracked file.
    \\4. Read surrounding files when a change needs context.
    \\
    \\If `HEAD` has no commit, report the command failure.
    \\
    \\## Permissions
    \\
    \\You can run required verification commands, and a build can write its normal cache. You
    \\can use a temporary probe when evidence requires one. Put the probe outside the
    \\repository, or remove it before the report. Do not intentionally change source,
    \\documentation, tests, the index, or commits. Never stage, commit, or restore a file.
    \\
    \\## Report
    \\
    \\Report only defects in the target and its direct effects. Each finding must include a
    \\location, a concrete consequence, and supporting evidence. Include required tests,
    \\required documentation, and objective wording defects. Exclude unrelated cleanup,
    \\speculative improvements, and valid design preferences.
    \\
    \\A report contains at most eight findings in severity order. Report no findings when none
    \\exist. Start every report with exactly one of these lines.
    \\
    \\Findings: none.
    \\Findings: {count}.
    \\
    \\Replace {count} with the number of findings. Return only the reviewer report.
;

/// The static core of the judge prompt. The judge validates findings, resolves
/// disputes, and settles the review, so its core carries the settlement rules
/// and the one path to a user question.
pub const judge_core =
    \\You are the judge of one bounded review workflow. Drinky, a terminal coding-agent
    \\harness, drives this conversation with generated requests. The user of Drinky wrote none
    \\of them. A `<user_message>` block and a direct answer to your question are the two
    \\exceptions: the user wrote those.
    \\
    \\## Work
    \\
    \\You validate reviewer findings, resolve disputes, and settle the review. Check the
    \\current files before you accept a finding. You can reject a finding, and you can add a
    \\missed one. Derive what the change implements from the diff and the repository alone. A
    \\change that resists a coherent picture is itself evidence of a defect.
    \\
    \\## Target
    \\
    \\The target is every staged, unstaged, and untracked change from `HEAD`. The staging state
    \\of a file has no effect on the target. Inspect the target through this path:
    \\
    \\1. Run `git status --short --untracked-files=all`.
    \\2. Run `git diff HEAD` for the tracked changes.
    \\3. Read every untracked file.
    \\4. Read surrounding files when a change needs context.
    \\
    \\If `HEAD` has no commit, report the command failure.
    \\
    \\## Permissions
    \\
    \\You can run required verification commands, and a build can write its normal cache. You
    \\can use a temporary probe when evidence requires one. Put the probe outside the
    \\repository, or remove it before the report. Do not intentionally change source,
    \\documentation, tests, the index, or commits. Never stage, commit, or restore a file.
    \\
    \\## Settlement
    \\
    \\Block settlement for:
    \\
    \\- A correctness, security, or data-loss defect.
    \\- A regression or a missing required test.
    \\- False or missing documentation that the project instructions require.
    \\- A concrete maintainability defect in changed code.
    \\- An objective wording or terminology defect.
    \\
    \\Do not block settlement for:
    \\
    \\- A subjective refactor or a valid internal alternative.
    \\- An unrelated defect or a speculative requirement.
    \\- A duplicate or resolved finding.
    \\
    \\Settlement requires a fresh review of the current target. No accepted finding, failed
    \\required check, or pending user decision can remain.
    \\
    \\## The user
    \\
    \\A review never comes from the user, so a finding is not necessarily aligned with the goal
    \\of the user. Ask the user only when all of these conditions apply:
    \\
    \\- The choice changes visible behavior, an interface, or a public contract.
    \\- At least two outcomes are valid.
    \\- Requirements, tests, and documentation select no outcome.
    \\- Technical evidence cannot resolve the choice.
    \\
    \\Resolve naming, internal architecture, test strategy, and clean-code disputes yourself.
    \\A question to the user includes the options, their consequences, one recommendation, and
    \\the missing requirement.
    \\
    \\## Report
    \\
    \\Start every report with exactly one of these lines.
    \\
    \\Decision: Fix required.
    \\Decision: Review settled.
    \\Decision: User decision required.
    \\
    \\Each `Decision: Fix required.` report is a self-contained fixer packet. It includes each
    \\finding location, the required result, every user constraint, and the required
    \\verification. When you reject a fixer dispute, quote that dispute and explain why the
    \\finding still requires a fix. Return only the judge report.
;

/// The correction request for a reviewer reply without a valid findings line.
/// It runs in the reviewer context, so the reviewer holds the reply it
/// corrects.
pub const reviewer_correction_request =
    \\<reviewer_report_correction>
    \\Your previous message was not a complete reviewer report.
    \\Return the complete reviewer report.
    \\Start it with exactly one of these lines.
    \\Findings: none.
    \\Findings: {count}.
    \\Replace {count} with the number of findings.
    \\</reviewer_report_correction>
;

/// The correction request for a judge report without a valid decision line.
/// It runs in the judge context, so the judge holds the report it corrects.
pub const judge_correction_request =
    \\<judge_report_correction>
    \\Your previous report did not start with a valid decision line.
    \\Return the complete corrected judge report.
    \\Start it with exactly one of these lines.
    \\Decision: Fix required.
    \\Decision: Review settled.
    \\Decision: User decision required.
    \\</judge_report_correction>
;

/// The correction request for a fixer reply without a valid application line.
/// It runs in the fixer context, so the fixer holds the reply it corrects.
pub const fixer_correction_request =
    \\<fixer_report_correction>
    \\Your previous message was not a complete fixer report.
    \\Return the complete fixer report.
    \\Start it with exactly one of these lines.
    \\Applied: all.
    \\Applied: partial.
    \\Applied: none.
    \\</fixer_report_correction>
;

pub fn init(gpa: std.mem.Allocator, rounds_max: u64) Review {
    std.debug.assert(rounds_max > 0);
    return .{ .gpa = gpa, .rounds_max = rounds_max };
}

pub fn deinit(self: *Review) void {
    if (self.reviewer_report) |report| self.gpa.free(report);
    if (self.fixer_report) |report| self.gpa.free(report.text);
    if (self.judge_report) |report| self.gpa.free(report);
    for (self.pending_messages.items) |message| self.gpa.free(message.text);
    self.pending_messages.deinit(self.gpa);
}

/// Start a fresh reviewer round and return its generated request. The round
/// number advances here, so only a fresh reviewer starts a round. The caller
/// owns the request.
pub fn composeReviewerRequest(self: *Review) ![]u8 {
    std.debug.assert(self.rounds_started < self.rounds_max);
    self.rounds_started += 1;
    self.next_pass = .first;
    self.round_reported = false;
    self.correction_requested = false;
    self.phase = .reviewer;
    return std.fmt.allocPrint(
        self.gpa,
        "<reviewer_request round=\"{d}\">\n" ++
            "Review the current target from HEAD.\n" ++
            "Inspect the current files and run required verification.\n" ++
            "Start the report with exactly one of these lines.\n" ++
            "Findings: none.\n" ++
            "Findings: {{count}}.\n" ++
            "Replace {{count}} with the number of findings.\n" ++
            "Return only the reviewer report.\n" ++
            "</reviewer_request>",
        .{self.rounds_started},
    );
}

/// Take the reviewer reply of the active round. A marked report goes to the
/// next judge request whole. A reply without a findings line is no report, so
/// it gets one correction request before the invalid stop.
pub fn finishReviewer(self: *Review, report: []const u8) !Step {
    std.debug.assert(self.phase == .reviewer);
    if (classifyFindings(report) == null) {
        if (self.correction_requested) return .stop_invalid;
        return .request_correction;
    }
    self.correction_requested = false;
    const copy = try self.gpa.dupe(u8, report);
    if (self.reviewer_report) |old| self.gpa.free(old);
    self.reviewer_report = copy;
    if (!self.round_reported) self.rounds_completed += 1;
    self.round_reported = true;
    return .start_judge;
}

/// Start the persistent judge and return its generated request. It consumes
/// the pending workflow messages and the stored reports, in the block order of
/// the request. The caller owns the request.
pub fn composeJudgeRequest(self: *Review) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    try out.writer.print("<judge_request round=\"{d}\">\n", .{self.rounds_started});
    if (self.pending_messages.items.len > 0) {
        try out.writer.writeAll("<workflow_messages>\n");
        for (self.pending_messages.items) |message| try out.writer.print(
            "<user_message round=\"{d}\" to=\"{s}\">\n{s}\n</user_message>\n",
            .{ message.round, @tagName(message.role), message.text },
        );
        try out.writer.writeAll("</workflow_messages>\n\n");
    }
    if (self.fixer_report) |report| try out.writer.print(
        "<fixer_report round=\"{d}\" pass=\"{d}\">\n{s}\n</fixer_report>\n\n",
        .{ report.round, report.pass.number(), report.text },
    );
    if (self.reviewer_report) |report| try out.writer.print(
        "<reviewer_report>\n{s}\n</reviewer_report>\n\n",
        .{report},
    );
    try out.writer.writeAll("</judge_request>");
    const request = try out.toOwnedSlice();
    // The request owns the content now, so the sources leave the machine. A
    // failed compose above leaves every source in place for another try.
    for (self.pending_messages.items) |message| self.gpa.free(message.text);
    self.pending_messages.clearRetainingCapacity();
    if (self.fixer_report) |report| self.gpa.free(report.text);
    self.fixer_report = null;
    if (self.reviewer_report) |report| self.gpa.free(report);
    self.reviewer_report = null;
    self.correction_requested = false;
    self.phase = .judge;
    return request;
}

/// Take the complete judge report and resolve the transition. An invalid
/// report gets one correction request, and an invalid report after that
/// request stops the workflow. A valid decision replaces the latest one.
pub fn finishJudge(self: *Review, report: []const u8) !Step {
    std.debug.assert(self.phase == .judge);
    const decision = classifyDecision(report) orelse {
        if (self.correction_requested) return .stop_invalid;
        return .request_correction;
    };
    self.correction_requested = false;
    try self.adoptDecision(decision, report);
    return switch (decision) {
        .review_settled => .settled,
        .user_decision_required => .hold_judge,
        .fix_required => self.fixStep(),
    };
}

/// Spend the one correction budget of the active phase reply and return the
/// request text. It runs in the role context, so the caller owns nothing. A
/// `request_correction` step that never reaches this leaves the budget whole.
pub fn composeCorrectionRequest(self: *Review) []const u8 {
    self.correction_requested = true;
    return switch (self.phase) {
        .setup => unreachable,
        .reviewer => reviewer_correction_request,
        .judge => judge_correction_request,
        .fixer => fixer_correction_request,
    };
}

/// Take a judge answer at a limit hold or at a settled hold. A valid decision
/// line replaces the latest decision, and a limit hold returns to itself either
/// way. An answer without a decision line leaves the latest decision stale.
/// Returns whether the answer replaced the decision.
pub fn adoptJudgeAnswer(self: *Review, report: []const u8) !bool {
    const decision = classifyDecision(report) orelse {
        self.decision_stale = true;
        return false;
    };
    try self.adoptDecision(decision, report);
    return true;
}

/// Raise the ceiling by one round and resume the workflow. A stale decision
/// goes back to the judge, because the answers of the user can change it. Only
/// a limit hold calls it, so a decision exists.
pub fn raiseCeiling(self: *Review) Step {
    self.rounds_max += 1;
    if (self.decision_stale) return .resume_judge;
    return switch (self.decision.?) {
        .fix_required => self.fixStep(),
        .review_settled => .start_reviewer,
        .user_decision_required => .hold_judge,
    };
}

/// The step that an answer at the settled hold left, or null while the judge
/// keeps its settlement. An answer without a decision line changes nothing, so
/// the hold stands. Only a settled hold calls it, so a decision exists.
pub fn settledStep(self: *Review) ?Step {
    if (self.decision_stale) return null;
    return switch (self.decision.?) {
        .review_settled => null,
        .fix_required => self.fixStep(),
        .user_decision_required => .hold_judge,
    };
}

/// Ask the judge to decide again over its own history, and return the
/// generated request. It consumes no stored report and no pending message,
/// because a later judge request still carries each one. The caller owns the
/// request.
pub fn composeResumeRequest(self: *Review) ![]u8 {
    const request = try std.fmt.allocPrint(
        self.gpa,
        "<judge_resume_request round=\"{d}\">\n" ++
            "The user added one round to the workflow.\n" ++
            "Decide again over your latest decision and the answers of the user.\n" ++
            "Inspect the current target again where an answer changes it.\n" ++
            "Start the report with exactly one of these lines.\n" ++
            "Decision: Fix required.\n" ++
            "Decision: Review settled.\n" ++
            "Decision: User decision required.\n" ++
            "Return only the judge report.\n" ++
            "</judge_resume_request>",
        .{self.rounds_started},
    );
    self.correction_requested = false;
    self.phase = .judge;
    return request;
}

/// The step of a `fix required` decision: the fixer of the armed pass, unless
/// the ceiling permits no later reviewer round.
fn fixStep(self: *Review) Step {
    if (self.rounds_started >= self.rounds_max) return .hold_limit;
    return .{ .start_fixer = self.next_pass };
}

/// Keep `decision` with its report. Only a `fix required` report feeds a next
/// request, so the machine stores that one alone. The decision covers the judge
/// conversation again, so it stops being stale. A failed copy adopts nothing.
fn adoptDecision(self: *Review, decision: Decision, report: []const u8) !void {
    if (decision == .fix_required) {
        const copy = try self.gpa.dupe(u8, report);
        if (self.judge_report) |old| self.gpa.free(old);
        self.judge_report = copy;
    }
    self.decision = decision;
    self.decision_stale = false;
}

/// Start a fresh fixer pass and return its generated request. It consumes the
/// stored judge report, because the request carries it whole and the judge
/// keeps its own history. The caller owns the request.
pub fn composeFixerRequest(self: *Review, pass: Pass) ![]u8 {
    const report = self.judge_report.?;
    const dispute_instruction = switch (pass) {
        .first => "You can dispute the report only with concrete evidence.",
        .second => "Do not repeat the dispute that this revised judge report rejected.",
    };
    const request = try std.fmt.allocPrint(
        self.gpa,
        "<fixer_request round=\"{d}\" pass=\"{d}\">\n" ++
            "Apply every accepted finding in this judge report.\n" ++
            "Do not apply a rejected finding or unrelated change.\n" ++
            "{s}\n" ++
            "Run the required verification.\n" ++
            "Start the report with exactly one of these lines.\n" ++
            "Applied: all.\n" ++
            "Applied: partial.\n" ++
            "Applied: none.\n" ++
            "Return only the fixer report.\n" ++
            "\n" ++
            "<judge_report>\n{s}\n</judge_report>\n" ++
            "</fixer_request>",
        .{ self.rounds_started, pass.number(), dispute_instruction, report },
    );
    self.gpa.free(report);
    self.judge_report = null;
    self.pass_reported = false;
    self.correction_requested = false;
    self.phase = .{ .fixer = pass };
    return request;
}

/// Take the fixer reply of the active pass and resolve the transition. The
/// next judge request carries a marked report, whether the dispute path or
/// the next round delivers it. A reply without an application line is no
/// report, so it gets one correction request before the invalid stop.
pub fn finishFixer(self: *Review, report: []const u8) !Step {
    const pass = self.phase.fixer;
    const application = classifyApplication(report) orelse {
        if (self.correction_requested) return .stop_invalid;
        return .request_correction;
    };
    self.correction_requested = false;
    const copy = try self.gpa.dupe(u8, report);
    if (self.fixer_report) |old| self.gpa.free(old.text);
    self.fixer_report = .{ .round = self.rounds_started, .pass = pass, .text = copy };
    if (!self.pass_reported) self.passes_completed += 1;
    self.pass_reported = true;
    if (pass == .second) return .start_reviewer;
    if (application != .none) return .start_reviewer;
    // The fixer changed no file and disputes the report, so the judge resolves
    // the dispute before any fresh review. A rejection arms the final pass.
    self.next_pass = .second;
    return .start_judge;
}

/// Queue one committed workflow message for the next judge request. Only
/// human text sent to a fresh role arrives here. A message sent to the judge
/// stays in judge history and needs no copy.
pub fn pushMessage(self: *Review, role: Role, text: []const u8) !void {
    std.debug.assert(role != .judge);
    const copy = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(copy);
    try self.pending_messages.append(self.gpa, .{
        .round = self.rounds_started,
        .role = role,
        .text = copy,
    });
}

/// The decision of a judge report: the first line that starts with
/// `Decision:`, or null when no line does or the value is unknown. Markdown
/// decoration and letter case do not affect classification.
pub fn classifyDecision(report: []const u8) ?Decision {
    const value = classifiedValue(report, "decision:") orelse return null;
    if (matchesValue(value, "fix required")) return .fix_required;
    if (matchesValue(value, "review settled")) return .review_settled;
    if (matchesValue(value, "user decision required")) return .user_decision_required;
    return null;
}

/// The findings count of a reviewer report: the first line that starts with
/// `Findings:`, or null when no line does or the value is unknown. The value
/// `none` counts as zero. Markdown decoration and letter case do not affect
/// classification.
pub fn classifyFindings(report: []const u8) ?u64 {
    const value = classifiedValue(report, "findings:") orelse return null;
    if (matchesValue(value, "none")) return 0;
    const body = if (std.mem.endsWith(u8, value, ".")) value[0 .. value.len - 1] else value;
    return std.fmt.parseInt(u64, body, 10) catch null;
}

/// The application of a fixer report: the first line that starts with
/// `Applied:`, or null when no line does or the value is unknown. Markdown
/// decoration and letter case do not affect classification.
pub fn classifyApplication(report: []const u8) ?Application {
    const value = classifiedValue(report, "applied:") orelse return null;
    if (matchesValue(value, "all")) return .all;
    if (matchesValue(value, "partial")) return .partial;
    if (matchesValue(value, "none")) return .none;
    return null;
}

/// The characters that markdown decoration puts around a report line: the
/// emphasis and code markers, the heading and quote markers, the list marker,
/// and the whitespace between them.
const decoration = "*_`#>- \t\r";

/// The value after `prefix` on the first report line that carries it, with the
/// decoration of both edges removed. Null when no line starts with `prefix`
/// under its decoration.
fn classifiedValue(report: []const u8, comptime prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const bare = std.mem.trim(u8, line, decoration);
        if (bare.len < prefix.len) continue;
        if (!std.ascii.eqlIgnoreCase(bare[0..prefix.len], prefix)) continue;
        return std.mem.trim(u8, bare[prefix.len..], decoration);
    }
    return null;
}

/// Whether `value` reads as `expected`, apart from letter case and the final
/// period. The templates state the period, so a report that keeps it and one
/// that drops it both classify.
fn matchesValue(value: []const u8, comptime expected: []const u8) bool {
    const body = if (std.mem.endsWith(u8, value, ".")) value[0 .. value.len - 1] else value;
    return std.ascii.eqlIgnoreCase(body, expected);
}

test "a decision line classifies through markdown decoration and letter case" {
    try std.testing.expectEqual(Decision.fix_required, classifyDecision(
        "Decision: Fix required.\nFinding 1 …",
    ).?);
    try std.testing.expectEqual(Decision.review_settled, classifyDecision(
        "**Decision: Review settled.**",
    ).?);
    try std.testing.expectEqual(Decision.user_decision_required, classifyDecision(
        "# decision: USER DECISION REQUIRED",
    ).?);
    try std.testing.expectEqual(Decision.fix_required, classifyDecision(
        "> `Decision: fix required`\r\nbody",
    ).?);
    // The first decision line controls, so a later one cannot replace it.
    try std.testing.expect(classifyDecision(
        "Decision: Maybe.\nDecision: Review settled.",
    ) == null);
    // Prose before the line does not hide it.
    try std.testing.expectEqual(Decision.review_settled, classifyDecision(
        "The target builds.\nDecision: Review settled.",
    ).?);
    try std.testing.expect(classifyDecision("No decision at all.") == null);
    try std.testing.expect(classifyDecision("") == null);
    // A decision value the workflow does not know stays invalid.
    try std.testing.expect(classifyDecision("Decision: Escalate.") == null);
}

test "an application line classifies through markdown decoration and letter case" {
    try std.testing.expectEqual(Application.all, classifyApplication("Applied: all.\nDetails").?);
    try std.testing.expectEqual(Application.partial, classifyApplication("**applied: Partial**").?);
    try std.testing.expectEqual(Application.none, classifyApplication("- Applied: NONE.").?);
    try std.testing.expect(classifyApplication("Applied: most.") == null);
    try std.testing.expect(classifyApplication("The fixer applied the findings.") == null);
}

test "a findings line classifies through markdown decoration and letter case" {
    try std.testing.expectEqual(@as(u64, 0), classifyFindings("Findings: none.\nAll clear.").?);
    try std.testing.expectEqual(@as(u64, 3), classifyFindings("**findings: 3**\nFinding 1 …").?);
    try std.testing.expectEqual(@as(u64, 12), classifyFindings("# FINDINGS: 12.").?);
    // Prose before the line does not hide it.
    try std.testing.expectEqual(@as(u64, 0), classifyFindings(
        "The target builds.\nFindings: none.",
    ).?);
    // A value the workflow cannot read as `none` or a count stays invalid.
    try std.testing.expect(classifyFindings("Findings: some.") == null);
    try std.testing.expect(classifyFindings("Findings:") == null);
    try std.testing.expect(classifyFindings("I found nothing.") == null);
    try std.testing.expect(classifyFindings("") == null);
}

test "the flow runs reviewer, judge, fixer, and a fresh round to settlement" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();

    // Round 1: the fresh reviewer request names its round.
    const first_request = try review.composeReviewerRequest();
    defer gpa.free(first_request);
    try std.testing.expectEqualStrings(
        "<reviewer_request round=\"1\">\n" ++
            "Review the current target from HEAD.\n" ++
            "Inspect the current files and run required verification.\n" ++
            "Start the report with exactly one of these lines.\n" ++
            "Findings: none.\n" ++
            "Findings: {count}.\n" ++
            "Replace {count} with the number of findings.\n" ++
            "Return only the reviewer report.\n" ++
            "</reviewer_request>",
        first_request,
    );
    try std.testing.expectEqual(@as(u64, 1), review.rounds_started);
    try std.testing.expectEqual(@as(u64, 0), review.rounds_completed);

    // The reviewer report goes to the judge whole.
    try std.testing.expectEqual(
        Step.start_judge,
        try review.finishReviewer("Findings: 1.\nFinding: a bug."),
    );
    try std.testing.expectEqual(@as(u64, 1), review.rounds_completed);
    const judge_request = try review.composeJudgeRequest();
    defer gpa.free(judge_request);
    try std.testing.expectEqualStrings(
        "<judge_request round=\"1\">\n" ++
            "<reviewer_report>\nFindings: 1.\nFinding: a bug.\n</reviewer_report>\n\n" ++
            "</judge_request>",
        judge_request,
    );

    // A fix decision starts the pass-1 fixer over the whole judge report.
    const fix = try review.finishJudge("Decision: Fix required.\nFix the bug in src/App.zig.");
    try std.testing.expectEqual(Step{ .start_fixer = .first }, fix);
    const fixer_request = try review.composeFixerRequest(.first);
    defer gpa.free(fixer_request);
    try std.testing.expectEqualStrings(
        "<fixer_request round=\"1\" pass=\"1\">\n" ++
            "Apply every accepted finding in this judge report.\n" ++
            "Do not apply a rejected finding or unrelated change.\n" ++
            "You can dispute the report only with concrete evidence.\n" ++
            "Run the required verification.\n" ++
            "Start the report with exactly one of these lines.\n" ++
            "Applied: all.\n" ++
            "Applied: partial.\n" ++
            "Applied: none.\n" ++
            "Return only the fixer report.\n" ++
            "\n" ++
            "<judge_report>\nDecision: Fix required.\nFix the bug in src/App.zig.\n" ++
            "</judge_report>\n" ++
            "</fixer_request>",
        fixer_request,
    );

    // An applied fix starts the fresh round, and the next judge request holds
    // the fixer report of round 1 beside the fresh reviewer report of round 2.
    const applied = try review.finishFixer("Applied: all.\nDone.");
    try std.testing.expectEqual(Step.start_reviewer, applied);
    try std.testing.expectEqual(@as(u64, 1), review.passes_completed);
    const second_request = try review.composeReviewerRequest();
    defer gpa.free(second_request);
    try std.testing.expectEqual(@as(u64, 2), review.rounds_started);
    try std.testing.expectEqual(Step.start_judge, try review.finishReviewer("Findings: none."));
    const second_judge = try review.composeJudgeRequest();
    defer gpa.free(second_judge);
    try std.testing.expectEqualStrings(
        "<judge_request round=\"2\">\n" ++
            "<fixer_report round=\"1\" pass=\"1\">\nApplied: all.\nDone.\n</fixer_report>\n\n" ++
            "<reviewer_report>\nFindings: none.\n</reviewer_report>\n\n" ++
            "</judge_request>",
        second_judge,
    );
    try std.testing.expectEqual(Step.settled, try review.finishJudge("Decision: Review settled."));
    try std.testing.expectEqual(@as(u64, 2), review.rounds_completed);
}

test "an applied-none dispute returns to the judge and bounds the passes" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    try std.testing.expectEqual(
        Step.start_judge,
        try review.finishReviewer("Findings: 1.\nFinding: a bug."),
    );
    gpa.free(try review.composeJudgeRequest());
    try std.testing.expectEqual(
        Step{ .start_fixer = .first },
        try review.finishJudge("Decision: Fix required.\nFix it."),
    );
    gpa.free(try review.composeFixerRequest(.first));

    // The dispute carries only the fixer report to the judge.
    try std.testing.expectEqual(
        Step.start_judge,
        try review.finishFixer("Applied: none.\nThe finding misreads the guard."),
    );
    const dispute_request = try review.composeJudgeRequest();
    defer gpa.free(dispute_request);
    try std.testing.expectEqualStrings(
        "<judge_request round=\"1\">\n" ++
            "<fixer_report round=\"1\" pass=\"1\">\nApplied: none.\n" ++
            "The finding misreads the guard.\n</fixer_report>\n\n" ++
            "</judge_request>",
        dispute_request,
    );

    // A rejected dispute arms the final pass, whose request forbids a repeat.
    try std.testing.expectEqual(
        Step{ .start_fixer = .second },
        try review.finishJudge("Decision: Fix required.\nThe guard reads as claimed."),
    );
    const final_request = try review.composeFixerRequest(.second);
    defer gpa.free(final_request);
    try std.testing.expect(std.mem.indexOf(
        u8,
        final_request,
        "Do not repeat the dispute that this revised judge report rejected.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, final_request, "pass=\"2\"") != null);

    // The final pass always starts a fresh reviewer, even on another dispute.
    try std.testing.expectEqual(
        Step.start_reviewer,
        try review.finishFixer("Applied: none.\nStill wrong."),
    );
    try std.testing.expectEqual(@as(u64, 2), review.passes_completed);
}

test "an unmarked reviewer reply gets one correction and a second one stops" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());

    // An answer to the user is no report, so it stores nothing for the judge
    // and counts no completion. Steps without a sent request spend no budget.
    try std.testing.expectEqual(
        Step.request_correction,
        try review.finishReviewer("Understood. I ignore the steering test."),
    );
    try std.testing.expect(review.reviewer_report == null);
    try std.testing.expectEqual(@as(u64, 0), review.rounds_completed);
    try std.testing.expectEqual(Step.request_correction, try review.finishReviewer("Noted."));
    try std.testing.expect(!review.correction_requested);

    // The sent correction spends the budget, and a marked report resets it,
    // so a later answer to the user gets a fresh correction.
    try std.testing.expectEqualStrings(
        reviewer_correction_request,
        review.composeCorrectionRequest(),
    );
    try std.testing.expectEqual(Step.start_judge, try review.finishReviewer("Findings: none."));
    try std.testing.expect(!review.correction_requested);
    try std.testing.expectEqual(
        Step.request_correction,
        try review.finishReviewer("You are welcome."),
    );

    // A second unmarked reply after a sent correction stops the workflow.
    _ = review.composeCorrectionRequest();
    try std.testing.expectEqual(Step.stop_invalid, try review.finishReviewer("Prose again."));
}

test "an unmarked fixer reply gets one correction and a second one stops" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: 1.\nFinding: a bug.");
    gpa.free(try review.composeJudgeRequest());
    _ = try review.finishJudge("Decision: Fix required.\nFix it.");
    gpa.free(try review.composeFixerRequest(.first));

    // A reply without an application line is no report, so it starts no fresh
    // round and stores nothing for the judge.
    try std.testing.expectEqual(
        Step.request_correction,
        try review.finishFixer("I fixed the bug."),
    );
    try std.testing.expect(review.fixer_report == null);
    try std.testing.expectEqual(@as(u64, 0), review.passes_completed);

    // The sent correction spends the budget, and the second unmarked reply
    // stops the workflow.
    try std.testing.expectEqualStrings(
        fixer_correction_request,
        review.composeCorrectionRequest(),
    );
    try std.testing.expectEqual(Step.stop_invalid, try review.finishFixer("Still prose."));
}

test "an invalid judge report gets one correction and a second one stops" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: 1.\nFinding: a bug.");
    gpa.free(try review.composeJudgeRequest());

    // A step that no compose follows sends no request, so the budget stays
    // whole and the next invalid report asks again.
    try std.testing.expectEqual(Step.request_correction, try review.finishJudge("Looks fine."));
    try std.testing.expect(!review.correction_requested);
    try std.testing.expectEqual(Step.request_correction, try review.finishJudge("Still fine."));

    // The composed request spends the budget.
    try std.testing.expectEqualStrings(
        judge_correction_request,
        review.composeCorrectionRequest(),
    );
    try std.testing.expect(review.correction_requested);
    // The corrected report controls the transition like any complete report.
    try std.testing.expectEqual(Step.settled, try review.finishJudge("Decision: Review settled."));

    // A fresh judge turn starts its correction budget again, and the invalid
    // report after the sent request stops the workflow.
    gpa.free(try review.composeJudgeRequest());
    try std.testing.expectEqual(Step.request_correction, try review.finishJudge("Hmm."));
    _ = review.composeCorrectionRequest();
    try std.testing.expectEqual(Step.stop_invalid, try review.finishJudge("Still no line."));
}

test "the ceiling holds progress and a raise resumes the latest decision" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 1);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: 1.\nFinding: a bug.");
    gpa.free(try review.composeJudgeRequest());

    // A fix at the ceiling cannot start a fixer, because no later reviewer
    // round could check its work.
    try std.testing.expectEqual(
        Step.hold_limit,
        try review.finishJudge("Decision: Fix required.\nFix it."),
    );

    // No answer moved the judge, so one added round resumes the fix and starts
    // the pass-1 fixer.
    try std.testing.expectEqual(Step{ .start_fixer = .first }, review.raiseCeiling());
    try std.testing.expectEqual(@as(u64, 2), review.rounds_max);
    gpa.free(try review.composeFixerRequest(.first));
    try std.testing.expectEqual(Step.start_reviewer, try review.finishFixer("Applied: all."));

    // A settled answer at the next hold resumes as one more reviewer round.
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: 1.\nFinding: another bug.");
    gpa.free(try review.composeJudgeRequest());
    try std.testing.expectEqual(Step.hold_limit, try review.finishJudge("Decision: Fix required."));
    try std.testing.expect(try review.adoptJudgeAnswer("Decision: Review settled."));
    try std.testing.expectEqual(Step.start_reviewer, review.raiseCeiling());
}

test "an answer without a decision sends the added round through the judge" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 1);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: 1.\nFinding: a bug.");
    gpa.free(try review.composeJudgeRequest());
    try std.testing.expectEqual(
        Step.hold_limit,
        try review.finishJudge("Decision: Fix required.\nFix it."),
    );

    // The answer holds no decision line, so the stored packet no longer covers
    // the judge conversation. The raise asks the judge instead of resuming it.
    try std.testing.expect(!try review.adoptJudgeAnswer("The finding rests on the diff alone."));
    try std.testing.expect(review.decision_stale);
    try std.testing.expectEqual(Step.resume_judge, review.raiseCeiling());
    try std.testing.expectEqual(@as(u64, 2), review.rounds_max);
    const request = try review.composeResumeRequest();
    defer gpa.free(request);
    try std.testing.expectEqualStrings(
        "<judge_resume_request round=\"1\">\n" ++
            "The user added one round to the workflow.\n" ++
            "Decide again over your latest decision and the answers of the user.\n" ++
            "Inspect the current target again where an answer changes it.\n" ++
            "Start the report with exactly one of these lines.\n" ++
            "Decision: Fix required.\n" ++
            "Decision: Review settled.\n" ++
            "Decision: User decision required.\n" ++
            "Return only the judge report.\n" ++
            "</judge_resume_request>",
        request,
    );

    // The fresh report controls the added round, so the fixer packet carries
    // what the answer changed.
    try std.testing.expectEqual(
        Step{ .start_fixer = .first },
        try review.finishJudge("Decision: Fix required.\nFix the parser instead."),
    );
    try std.testing.expect(!review.decision_stale);
    const fixer_request = try review.composeFixerRequest(.first);
    defer gpa.free(fixer_request);
    try std.testing.expect(std.mem.indexOf(u8, fixer_request, "parser") != null);

    // The added round holds the fresh reviewer that checks the fix.
    try std.testing.expectEqual(Step.start_reviewer, try review.finishFixer("Applied: all."));
    gpa.free(try review.composeReviewerRequest());
    try std.testing.expectEqual(@as(u64, 2), review.rounds_started);
}

test "an answer at the settled hold leaves a step only for a fresh decision" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: 1.\nFinding: a bug.");
    gpa.free(try review.composeJudgeRequest());
    try std.testing.expectEqual(Step.settled, try review.finishJudge("Decision: Review settled."));

    // An answer in prose changes no decision, so the settlement stands and the
    // hold offers no step.
    try std.testing.expect(!try review.adoptJudgeAnswer("The guard covers that path."));
    try std.testing.expect(review.settledStep() == null);

    // A repeated settlement stands too.
    try std.testing.expect(try review.adoptJudgeAnswer("Decision: Review settled."));
    try std.testing.expect(review.settledStep() == null);

    // An answer that convinces the judge leaves the step of the fresh
    // decision, and the fixer packet carries what the judge accepted.
    try std.testing.expect(try review.adoptJudgeAnswer(
        "Decision: Fix required.\nFix the parser.",
    ));
    try std.testing.expectEqual(Step{ .start_fixer = .first }, review.settledStep().?);
    const request = try review.composeFixerRequest(.first);
    defer gpa.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "parser") != null);
}

test "a settled hold at the ceiling sends a fresh fix decision to the limit" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 1);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: none.");
    gpa.free(try review.composeJudgeRequest());
    try std.testing.expectEqual(Step.settled, try review.finishJudge("Decision: Review settled."));

    // No later reviewer round could check a fix, so the fresh decision holds
    // at the limit instead of starting the fixer.
    try std.testing.expect(try review.adoptJudgeAnswer(
        "Decision: Fix required.\nFix the parser.",
    ));
    try std.testing.expectEqual(Step.hold_limit, review.settledStep().?);

    // A question that the judge turns back on the user holds too.
    try std.testing.expect(try review.adoptJudgeAnswer(
        "Decision: User decision required.\nKeep or rename the option?",
    ));
    try std.testing.expectEqual(Step.hold_judge, review.settledStep().?);
}

test "a successor report replaces its phase report and counts no second completion" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: 1.\nFinding: a bug.");
    // The user steered the completed reviewer, so its next marked reply
    // replaces the report. The round completed once.
    _ = try review.finishReviewer("Findings: 1.\nFinding: a bug in the parser.");
    try std.testing.expectEqual(@as(u64, 1), review.rounds_completed);
    const request = try review.composeJudgeRequest();
    defer gpa.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "parser") != null);
    _ = try review.finishJudge("Decision: Fix required.\nFix it.");
    gpa.free(try review.composeFixerRequest(.first));
    _ = try review.finishFixer("Applied: all.");
    _ = try review.finishFixer("Applied: all.\nAnd the docs.");
    try std.testing.expectEqual(@as(u64, 1), review.passes_completed);
}

test "workflow messages ride into the next judge request in user order" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    try review.pushMessage(.reviewer, "Check the config parser too.");
    _ = try review.finishReviewer("Findings: 1.\nFinding: a bug.");
    try review.pushMessage(.reviewer, "Ignore the generated file.");
    const request = try review.composeJudgeRequest();
    defer gpa.free(request);
    try std.testing.expectEqualStrings(
        "<judge_request round=\"1\">\n" ++
            "<workflow_messages>\n" ++
            "<user_message round=\"1\" to=\"reviewer\">\nCheck the config parser too.\n" ++
            "</user_message>\n" ++
            "<user_message round=\"1\" to=\"reviewer\">\nIgnore the generated file.\n" ++
            "</user_message>\n" ++
            "</workflow_messages>\n\n" ++
            "<reviewer_report>\nFindings: 1.\nFinding: a bug.\n</reviewer_report>\n\n" ++
            "</judge_request>",
        request,
    );
    // The judge owns the copies now, so a second request repeats none of them.
    _ = try review.finishJudge("Decision: Fix required.\nFix it.");
    gpa.free(try review.composeFixerRequest(.first));
    _ = try review.finishFixer("Applied: none.\nDispute.");
    const second = try review.composeJudgeRequest();
    defer gpa.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "workflow_messages") == null);
}

test "a user decision holds the workflow and the answer resolves it" {
    const gpa = std.testing.allocator;
    var review = Review.init(gpa, 4);
    defer review.deinit();
    gpa.free(try review.composeReviewerRequest());
    _ = try review.finishReviewer("Findings: 1.\nFinding: the flag renames a public option.");
    gpa.free(try review.composeJudgeRequest());
    try std.testing.expectEqual(
        Step.hold_judge,
        try review.finishJudge("Decision: User decision required.\nKeep or rename the option?"),
    );
    // The answer runs as a judge successor turn, so its report resolves the
    // same phase.
    try std.testing.expectEqual(
        Step{ .start_fixer = .first },
        try review.finishJudge("Decision: Fix required.\nKeep the option and fix the parser."),
    );
}

test "the role cores carry the shared rules and the report lines" {
    // Both roles inspect the same target through the same path, and neither
    // one may change a file on purpose.
    for ([_][]const u8{ reviewer_core, judge_core }) |core| {
        try std.testing.expect(std.mem.indexOf(
            u8,
            core,
            "git status --short --untracked-files=all",
        ) != null);
        try std.testing.expect(std.mem.indexOf(u8, core, "git diff HEAD") != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            core,
            "Do not intentionally change source",
        ) != null);
    }
    // The judge core states the three decision lines the classifier reads.
    try std.testing.expect(std.mem.indexOf(u8, judge_core, "Decision: Fix required.") != null);
    try std.testing.expect(std.mem.indexOf(u8, judge_core, "Decision: Review settled.") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        judge_core,
        "Decision: User decision required.",
    ) != null);
    // The reviewer core states the findings lines the classifier reads.
    try std.testing.expect(std.mem.indexOf(u8, reviewer_core, "Findings: none.") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewer_core, "Findings: {count}.") != null);
    // Each correction request repeats the lines of its role, so a corrected
    // report can classify.
    try std.testing.expect(std.mem.indexOf(
        u8,
        judge_correction_request,
        "Decision: User decision required.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        reviewer_correction_request,
        "Findings: none.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fixer_correction_request,
        "Applied: none.",
    ) != null);
    // The reviewer core bounds the report.
    try std.testing.expect(std.mem.indexOf(u8, reviewer_core, "at most eight findings") != null);
    // Only a judge request carries a `<user_message>` block, so the reviewer
    // core names no block that its own conversation never holds. A direct
    // message reaches the reviewer as plain text, and the core licenses it.
    try std.testing.expect(std.mem.indexOf(u8, judge_core, "<user_message>") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewer_core, "<user_message>") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        reviewer_core,
        "A direct message is the one exception",
    ) != null);
}
