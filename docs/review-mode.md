# Review Mode

Status: Planned.

## Prerequisites

Land these shared features before review mode:

1. Active context projection.
2. Failure recovery and retry.
3. Conversation switching.

Each feature must use the normal app path. Review mode must not implement a private variant.

The command refusal path below already exists. Review mode uses it. Failure recovery and retry
landed too, so only active context projection and conversation switching remain.

### Active context projection

Drinky keeps complete provider-neutral history. It projects that history for the active account.

- User and assistant messages remain compatible.
- Opaque reasoning requires the exact account that created it.
- A tool call and its results form one linked group.
- Drinky includes a tool group only when the active provider can represent it correctly.
- Hidden items stay in canonical history and return after a compatible switch.
- A credential replacement permanently removes replay proofs from that account slot.

The model is not a projection dimension. Anthropic replays mixed-model reasoning in one account,
which its Fable fallback shows. Drinky records no producing model on a reasoning item, and every
`/model` switch already replays the previous model's reasoning. Whether OpenAI accepts a cross-model
replay of encrypted reasoning is unconfirmed. A rejection surfaces as a loud API error, so Drinky
does not filter on a guess.

The visible conversation blocks must match the projected model context. Drinky shows no marker for a
hidden item.

Local event blocks remain visible because they are not model context.

A model switch within one account hides nothing, so it needs no deep repaint. An account or
conversation switch performs one:

- Select the canonical history and its local events.
- Project compatible conversation items.
- Rebuild the transcript from that projection.
- Clear the prior screen and terminal scrollback.
- Render only the selected context.

Context fill holds the measurement of the last committed reply, so a switch reads as unknown until
the next reply measures the projected history. Usage and cost remain cumulative. The status uses the
active account allowance.

A switch clears the local cache-hit rate, because another account, model, or resolved effort reads
another cache. It does not claim to clear provider cache storage.

### Failure recovery and retry

Status: Landed, except the generated-request row below, which waits for `/review`.

A request enters recovery after its normal transport retries fail. A checkpoint contains committed
work from the failed turn.

| Failed input             | Checkpoint | Editor recovery                     | Ctrl+N                          | Non-blank Enter                   |
| ------------------------ | ---------- | ----------------------------------- | ------------------------------- | --------------------------------- |
| Human-authored request   | No         | Restore the request and steering.   | No action.                      | Send the editor as a normal turn. |
| Drinky-generated request | No         | Restore only human steering.        | Resend the generated request.   | Send the editor as a normal turn. |
| Any request              | Yes        | Restore uncommitted human steering. | Send a generated retry request. | Send the editor as a normal turn. |

An attempt never carries the editor text. A failure of the network or of the provider is nothing a
user instruction prevents, so the attempt asks for the committed work alone. Enter therefore keeps
its normal meaning, and the start of that turn drops the retry context, because the conversation
moved on. A user who wants both sends the message first, or steers the running attempt.

A `/skill:` line takes the human row, because that line reproduces its own request. The generated
row belongs to a request that no editor line holds, and `/review` is the first one.

A failed attempt keeps the retry, because the work that it continues from stays in history. Its own
failure sentence replaces the sentence before it. A canceled attempt ends the recovery instead,
because the user stopped that turn and a cancellation arms no retry.

Blank Enter has no action. Ctrl+N never sends the editor text and never clears it.

A non-blank Enter clears the editor only after the turn starts. If that turn fails before a
checkpoint, Drinky restores its human text. A generated request stays hidden.

If the turn commits a checkpoint, its human text remains in immutable history.

A generated request that has no checkpoint and no editor line stays outside the editor. This rule
applies to review requests and future generated workflows.

A committed retry uses this provider `user` message:

```text
<retry_request>
The latest complete failure sentence appears here.
Continue from the last committed checkpoint.
</retry_request>
```

The tags mark the message as one that Drinky wrote, because the user typed none of it. A retry
request contains only the latest error and never nests an older retry request.

Retry never rewrites committed conversation history. Earlier retry requests, tool calls, results,
reasoning, and human messages remain in order.

Each attempt records one local event that names what it sends. The complete request stays out of the
transcript, as a `/skill:` line keeps its expanded file out of it. An attempt that commits nothing
takes its own blocks out again, so the transcript keeps only the failure events.

Failure events are local transcript events. They remain visible after success and across model
switches. The model sees an error only through a generated retry request.

Another failure replaces the active retry context with the latest error. It does not remove prior
failure events or committed conversation items.

The main app remains in prompt mode. While retry context exists, it shows this hint above the
editor:

```text
Ctrl+N: Try again · Esc: Dismiss
```

An uncommitted human request returns to the editor and shows no retry hint.

Main prompt controls during retry are:

- Ctrl+N: Retry. The editor keeps its text.
- Enter: Send the editor text as a normal turn. That start drops the retry context.
- Esc: Discard retry context and preserve the editor.
- `/model`, `/effort`, `/login`, `/logout`, `/colors`, and `/system`: Run and preserve retry.
- `/new`: Clear the conversation and retry context.
- `/skill:` and `/review`: Run. Each one starts a turn, so that start drops the retry context.

A retry needs an active account, so a signed-out Ctrl+N names the sign-in and keeps the context.

Retry context survives an account, model, or effort switch. The next attempt uses the selected
configuration.

Every failed attempt and retry keeps its reported usage and cost. Drinky does not track retry
duration.

### Command refusal

Status: Landed.

Drinky uses one refusal path when a parsed slash command is unavailable in the active state:

- Keep the command text in the editor.
- Send nothing to the model.
- Open no picker.
- Show a local notice that names the command and restriction.

This path applies during an active normal turn, during retry restrictions, and throughout review
mode. The restriction text completes the sentence `The command /name cannot run …`. Such a notice
warns rather than reports a failure, because the line stays complete, and the next Enter runs it
after the restriction ends. Drinky runs no command on its own.

Every line that starts with a slash is a command line. The registry also refuses an unknown name,
and an argument that the command does not take. Such a line keeps its text and arms one Enter, which
sends the line to the active role as typed. The row names that action, as in
`Enter: Send as a message`. Every other key cancels the arm, so the send always belongs to the line
on screen. The row leaves with the arm, because a row that stays asks for an Enter that does
nothing. The line itself stays in the editor, and the next Enter arms it again.

A turn end cancels the arm too, and it clears the footer with it. Only a key that arrives during a
turn can raise a notice there, and every such notice names that turn.

The registry decides first. A caller applies its state restriction only to a line that the registry
can run as typed.

The severity follows the way out. A refusal that needs another try of the same command reports a
failure, as a broken skill load does. A refusal that an Enter can pass, or that ends with the active
state, warns.

Editor retention follows the text at risk. A refusal keeps its line, because that line can hold text
that the user wrote. A command that ran clears the editor, because the registry refuses every
argument, so that line held nothing but the command name. A `/skill:` line is the one line that
takes user text. A failed load is a refusal and keeps that text, and a load that ran moves it into
the turn as the task.

### Conversation switching

One shared operation switches a conversation context. It selects:

- The agent and its canonical history.
- The account, model, and effort.
- The filtered transcript and local events.
- The context fill, allowance, and cumulative cost.

The operation uses the deep repaint rule above. It never appends one context to another transcript.

## Concept

`/review` reviews all pending changes, applies accepted fixes, and repeats the review until it
settles or stops.

The command takes no argument. It runs one request at a time and has no nesting.

| Role     | Context                 | Work                                                           |
| -------- | ----------------------- | -------------------------------------------------------------- |
| Reviewer | Fresh per round         | Finds concrete defects in the current changes.                 |
| Judge    | Persistent per workflow | Validates findings, resolves disputes, and settles the review. |
| Fixer    | Fresh per pass          | Applies the judge report or disputes it with evidence.         |

The main conversation remains parked. Review roles receive no main-conversation content. Review
completion adds no model context to the main agent.

The user can steer the active role. The workflow can run without supervision while the editor is
empty.

`/review` cannot start while the main prompt shows `Ctrl+N: Try again`.

## Setup and round ceiling

`/review` opens this setup before the first request:

```text
Select a review setup                    Select the judge

 > Start review                           > Model: gpt-5.6-sol (OpenAI Subscription)
   Reviewer: claude-opus-5 (…) · high       Effort: high
   Judge: gpt-5.6-sol (…) · high
   Fixer: claude-opus-5 (…) · xhigh
```

- A role row opens its account, model, and effort menus.
- Esc returns one menu level.
- The top setup uses `Esc: Cancel`.
- An unavailable account blocks the start. Drinky selects no fallback.

Drinky saves an explicit role choice when the user confirms it. A project without stored choices
inherits the active session configuration and saves those choices when review starts.

The global config sets the reviewer-round ceiling:

```json
{
  "review": {
    "rounds_max": 4
  }
}
```

`review.rounds_max` defaults to 4 and must be positive. Drinky reports an invalid value and uses the
default.

Ctrl+E adds one round to the active workflow. It does not change `config.json`.

## Target and permissions

`/review` requires a Git worktree. Outside one, Drinky reports a notice and starts nothing.

The target is every staged, unstaged, and untracked change from `HEAD`. Staging never changes the
scope.

Drinky itself computes no diff and runs no Git command. The reviewer and judge run this path through
`bash`:

1. Run `git status --short --untracked-files=all`.
2. Run `git diff HEAD` for tracked changes.
3. Read every untracked file.
4. Read surrounding files when a change needs context.

Plain `git status` can collapse an untracked directory. `git diff HEAD` does not show untracked
files. If `HEAD` has no commit, the role reports the command failure and Drinky adds no special
path.

Drinky never stages, commits, restores, or changes the index.

Every role receives the normal environment, instruction, skill, and tool sections. Every role gets
the complete tool registry.

A path-triggered skill reaches every role through its reads. Drinky sends the skill file when a tool
first touches a file that a rule matches, so the reviewer and the judge hold the rules of the code
they read. Neither role writes, so a refusal never carries those rules to them.

The reviewer and judge:

- Can run required verification commands.
- Can let a build write its normal cache.
- Can use a temporary probe when evidence requires one.
- Must put the probe outside the repository or remove it before the report.
- Must not intentionally change source, documentation, tests, the index, or commits.

The fixer receives the normal main system core. It changes only files required by accepted findings
and their direct verification.

The reviewer and judge receive static role cores that contain the review and judgment rules below.
Their nonmutation rules are prompt instructions, not tool restrictions. Every role keeps `write`,
`edit`, and unrestricted `bash` access.

## Generated requests

Each automatic request is a Drinky-generated provider `user` message. The active transcript shows
the complete request.

Drinky inserts report and user text verbatim. Tags are prompt markers, not parsed XML. A body can
contain matching tags, so the prompt boundary is guidance rather than a security boundary. Drinky
controls all attribute values.

### Reviewer

Each round starts a fresh reviewer with this request:

```text
<reviewer_request round="{round}">
Review the current target from HEAD.
Inspect the current files and run required verification.
Return only the reviewer report.
</reviewer_request>
```

The reviewer receives no prior report, judge report, fixer report, or prior user message.

### Judge

A judge request uses this structure:

```text
<judge_request round="{round}">
<workflow_messages>
Pending reviewer and fixer user messages appear here.
</workflow_messages>

<fixer_report round="{source_round}" pass="{pass}">
The new fixer report appears here.
</fixer_report>

<reviewer_report>
The new reviewer report appears here.
</reviewer_report>
</judge_request>
```

Drinky omits unused blocks:

| Transition                     | Workflow messages | Fixer report | Reviewer report |
| ------------------------------ | ----------------- | ------------ | --------------- |
| Reviewer finished              | When pending      | No           | Yes             |
| Fixer then fresh reviewer      | When pending      | Yes          | Yes             |
| `Applied: none.` fixer dispute | When pending      | Yes          | No              |

The persistent judge already has every earlier judge request and response.

### Fixer

A fixer request uses this structure:

```text
<fixer_request round="{round}" pass="{pass}">
Apply every accepted finding in this judge report.
Do not apply a rejected finding or unrelated change.
{dispute_instruction}
Run the required verification.
Start the report with exactly one of these lines.
Applied: all.
Applied: partial.
Applied: none.
Return only the fixer report.

<judge_report>
The complete judge report appears here.
</judge_report>
</fixer_request>
```

The dispute instruction depends on the pass:

- Pass 1: `You can dispute the report only with concrete evidence.`
- Pass 2: `Do not repeat the dispute that this revised judge report rejected.`

### Judge report correction

A missing or invalid judge decision gets one automatic correction request:

```text
<judge_report_correction>
Your previous report did not start with a valid decision line.
Return the complete corrected judge report.
Start it with exactly one of these lines.
Decision: Fix required.
Decision: Review settled.
Decision: User decision required.
</judge_report_correction>
```

The latest complete report controls the transition. A second invalid report stops review mode.
Committed correction history remains unchanged.

## Workflow messages

A user message first belongs only to the active role context.

- A committed message sent directly to the judge stays in judge history.
- A committed reviewer or fixer message gets one pending judge copy.
- A fresh reviewer or fixer receives no prior user message.
- Uncommitted messages return through normal editor recovery.
- Text recalled with Ctrl+P remains a draft and is not forwarded.

A forwarded message keeps its source round and role:

```text
<user_message round="2" to="fixer">
Do not change the public configuration format.
</user_message>
```

When the next judge turn starts, Drinky moves pending copies into its generated request in user
order. The normal turn transaction then owns them. `Review` keeps no second copy.

Only human text can become a workflow message. Drinky never forwards a generated request or a retry
request.

Each `Decision: Fix required.` report is a self-contained fixer packet. It includes each finding
location, required result, user constraint, and required verification.

## Flow and round budget

```text
setup
  -> fresh reviewer
  -> persistent judge
       -> settled -> main conversation
       -> fix required -> fresh fixer pass 1
            -> applied all or partial -> fresh reviewer
            -> applied none -> persistent judge
                 -> fix still required -> fresh fixer pass 2 -> fresh reviewer
       -> user decision required -> judge hold
       -> ceiling blocks progress -> limit hold
            -> judge answer -> limit hold

completed phase + editor text -> user hold
failed request -> failure hold
```

Only a fresh reviewer starts a round. A retry, successor turn, judge reply, fixer pass, or hold does
not start one.

Drinky starts no fixer unless the ceiling permits a later reviewer round. The judge can settle after
any fresh review.

A rejected fixer dispute can add one final fixer pass. No automatic path adds another fixer before
the next reviewer.

The ceiling bounds unattended progress. The limit hold keeps all live contexts available for
questions or one more round.

Drinky tracks started and completed reviewer rounds separately. A canceled first reviewer reports
zero completed rounds.

## Editor and controls

The editor is both the steering channel and the brake.

- Empty editor: The workflow can continue automatically.
- Non-empty editor: The next phase boundary enters a user hold.
- Blank Enter: No action.
- Any preserved or restored text remains a brake.

Text that parses as a slash command is never steering. During review, Enter uses the shared command
refusal and keeps that text in the editor. Ctrl+C clears the refused command.

Ctrl+C clears a non-empty editor and never releases a hold. On an empty editor, it has the current
Esc action and never quits Drinky directly from review mode.

Ctrl+D has no action with editor text. On an empty editor, it cancels and joins any active request,
accounts for reported usage and cost, destroys review state, and exits Drinky. It writes no main
completion event.

A return from review mode resets the double-Ctrl+C timer. Normal double-Ctrl+C behavior starts fresh
at the main prompt.

### While a role runs

| Control | Action                                                        |
| ------- | ------------------------------------------------------------- |
| Enter   | Queue non-blank editor text as steering and clear the editor. |
| Ctrl+P  | Recall steering that the role has not consumed.               |
| Esc     | Stop review mode.                                             |

The role reads steering at its next tool boundary. If queued steering arrives after the role
finishes, Drinky returns it to the editor. The restored text is a brake. The same boundary enters a
user hold, so the user reviews the text before Drinky sends it.

A direct stop cancels and joins the active request. Drinky destroys every submitted review message
with the review context and does not add it to the main editor.

This rule covers steering, hold replies, judge questions, and retry additions. Drinky preserves all
text already visible in the editor, including text that failure recovery returned there.

Esc still reports a stopped outcome when the worker completed before the join. The active phase does
not transition or increment a completed counter. Provider usage, cost, and completed tool effects
remain.

### Holds

| Hold    | Cause                           | Enter                   | Other control                                 |
| ------- | ------------------------------- | ----------------------- | --------------------------------------------- |
| User    | A completed phase has text.     | Send to completed role. | Ctrl+N: Continue and preserve text.           |
| Judge   | The judge needs a decision.     | Answer the judge.       | None.                                         |
| Limit   | The ceiling blocks progress.    | Ask the judge.          | Ctrl+E: Add one round.                        |
| Failure | A request failed after retries. | Send the editor text.   | Ctrl+N: Retry when shown. Ctrl+S: Role setup. |

Esc stops a user, judge, or failure hold. Esc finishes a limit hold and claims settlement only when
the latest judge decision settled the review. These Esc paths restore the main conversation.

Ctrl+N and Ctrl+E preserve editor text. That text applies the normal brake at the next boundary.

Ctrl+P has no hold action. Drinky returns late steering to the editor before it enters a hold.

A failure hold uses the shared recovery rules:

- The frame shows Ctrl+N only for a committed checkpoint or an uncommitted generated request.
- A human request with no checkpoint returns to the editor and has no Ctrl+N action.
- Enter sends the editor text alone, as at the main prompt. A retry carries no editor text, and the
  turn that Enter starts drops the retry.
- Ctrl+S opens only the failed role account, model, and effort picker.
- A confirmed choice saves immediately and returns to the same failure hold.
- Picker Esc returns unchanged to the failure hold.
- The failure picker has no `Start review` action and starts no retry.
- Esc in the failure hold stops the workflow.

### Limit hold

The user can ask the judge any number of questions. An answer can replace the latest judge decision,
but every answer returns to the limit hold.

Ctrl+E raises the ceiling by one and resumes the latest judge decision:

- Fix required: Start the fixer.
- Review settled: Start another reviewer.
- User decision required: Enter a judge hold.

Esc finishes without claiming settlement unless the judge already settled the review.

## Review policy

The reviewer reports only defects in the target and its direct effects.

Each finding must include:

- A location.
- A concrete consequence.
- Supporting evidence.

The reviewer includes required tests, required documentation, and objective wording defects. It
excludes unrelated cleanup, speculative improvements, and valid design preferences.

A report contains at most eight findings in severity order. It reports no findings when none exist.

The judge checks current files before it accepts a finding. It can reject a finding or add a missed
one.

When the judge rejects a pass-1 fixer dispute, its revised report quotes that dispute and explains
why the finding still requires a fix.

The judge blocks settlement for:

- A correctness, security, or data-loss defect.
- A regression or missing required test.
- False or missing documentation required by project instructions.
- A concrete maintainability defect in changed code.
- An objective wording or terminology defect.

The judge does not block settlement for:

- A subjective refactor or valid internal alternative.
- An unrelated defect or speculative requirement.
- A duplicate or resolved finding.

Settlement requires a fresh review of the current target. No accepted finding, failed required
check, or pending user decision can remain.

The judge asks the user only when all conditions apply:

- The choice changes visible behavior, an interface, or a public contract.
- At least two outcomes are valid.
- Requirements, tests, and documentation select no outcome.
- Technical evidence cannot resolve the choice.

The judge resolves naming, internal architecture, test strategy, and clean-code disputes. A question
includes options, consequences, a recommendation, and the missing requirement.

## Judge and fixer reports

A judge report starts with exactly one of these lines:

```text
Decision: Fix required.
Decision: Review settled.
Decision: User decision required.
```

Drinky takes the first line that starts with `Decision:`. Markdown decoration and letter case do not
affect classification.

A fixer report starts with exactly one of these lines:

```text
Applied: all.
Applied: partial.
Applied: none.
```

Drinky takes the first line that starts with `Applied:`. Markdown decoration and letter case do not
affect classification.

- `Applied: all.`: The fixer applied every accepted finding.
- `Applied: partial.`: The fixer changed files but could not apply or disputes at least one finding.
- `Applied: none.`: The fixer changed no file and disputes the report with evidence.

`Applied: all.` and `Applied: partial.` start a fresh reviewer. The next judge request includes both
new reports.

`Applied: none.` from pass 1 returns directly to the judge. If the judge still requires a fix, one
final fixer gets the revised report.

The final fixer cannot repeat the dispute. Its result always starts a fresh reviewer. At most two
fixer passes occur between reviewer rounds.

An absent or unknown pass-1 application line takes the conservative path and starts a fresh
reviewer.

## Contexts and accounting

The workflow has these visible contexts:

- The parked main conversation.
- The current reviewer.
- The persistent judge.
- The current fixer.

A role switch uses the shared conversation-switch operation. It never mixes transcript blocks.

The reviewer and fixer reset before each fresh phase. Drinky banks their cost, clears their agent
history, and clears the matching transcript.

The judge keeps its history and transcript until the workflow ends. An account switch uses the
shared filtered projection.

Review histories, gauge measurements, and usage stay separate from the main agent. Review mode never
compacts or resets the main conversation.

A running phase uses this compact frame:

```text
Review mode: Round 2 of 4 · Judge
Reviewer → [Judge] → Fixer
Enter: Steer · Esc: Stop
─────────────────────────────────────────────────────
Type steering here, or leave the editor empty.
─────────────────────────────────────────────────────
```

A limit hold uses this frame:

```text
Review mode: Limit at round 4 · Judge
Enter: Ask judge · Ctrl+E: Add round · Esc: Finish
─────────────────────────────────────────────────────
Ask about the open finding.
─────────────────────────────────────────────────────
```

The review frame has no fixed row budget. A running phase uses three rows and shows the role
pipeline. A hold uses two rows and omits the pipeline. Drinky recalculates the transcript and editor
layout after the transition.

The status shows the active role account, model, effort, context fill, allowance, and total review
cost.

Each completed request records its phase and incremental cost as a local event. A canceled or failed
request keeps all provider-reported usage.

The review total includes every role request, retry, correction, and successor turn. Review mode
does not track duration.

## Completion

After the first reviewer starts, every workflow end that returns to the main prompt restores the
parked main transcript and preserves the editor exactly. Empty-editor Ctrl+D uses normal app
teardown instead. Drinky starts no main-agent turn and adds no main-model context.

Drinky appends one local completion event to the main transcript. It includes:

- The outcome or settlement status.
- The active role when review stopped.
- The latest failure sentence when review stopped on a failure.
- Completed reviewer rounds.
- Completed fixer passes.
- Total review cost.

A stopped event counts only phase transitions that Drinky applied before the active request. It
includes all provider-reported cost and does not report a raced response as completed.

Review agents, reports, role histories, pending workflow messages, and retry state are not copied to
the main conversation. Drinky destroys them after the completion event has the required accounting
data.

## Implementation invariants

- One app-owned `Review` state machine owns phases, holds, counters, reports, messages, and cost.
- `Review` owns one agent per role and one transcript per live role context.
- The states are setup, reviewer, judge, fixer, and held.
- One turn future runs at a time.
- The main agent and main history remain parked. The app-owned editor remains live.
- A direct stop preserves the current editor and discards every submitted review message.
- Clearing the editor never releases a hold. Only its explicit continue control does.
- Empty-editor Ctrl+D uses normal app teardown and writes no main completion event.
- A workflow return resets the double-Ctrl+C timer before the main prompt becomes active.
- Esc keeps a stopped outcome when the active worker wins the cancellation race.
- Review uses the shared retry, command-refusal, projection, and conversation-switch features.
- Human and generated request provenance remains distinct through rollback and retry.
- Committed history is immutable within a live context.
- Conversation reset and unsafe replay-proof removal are explicit exceptions.
- A phase can contain successor turns. Its latest complete assistant report controls the transition.
- Agent reset and transcript reset remain separate operations that Drinky calls together.
- `config.json` owns `review.rounds_max`.
- `state.json` owns reviewer, judge, and fixer choices.

Drinky resolves a completed phase in this order:

1. Return late steering to the editor.
2. Enter a user hold for editor text.
3. Request one complete correction for an invalid judge report.
4. Enter a judge hold for a required decision.
5. Enter a limit hold when the ceiling blocks progress.
6. Start the next phase or restore the main conversation.

A failed phase enters a failure hold through the shared recovery path.

## Test invariants

Tests cover:

- Retry ownership, rollback, provenance, controls, usage, and cost.
- Canonical history filtering, tool links, model switches, and deep repaint.
- Context isolation, fresh roles, persistent judge state, and complete tools.
- Request composition, provenance, and judge-only message forwarding.
- Editor brakes, steering recall, stop ownership, stop races, command refusal, and quit timer
  resets.
- Hold and quit controls, round limits, limit decisions, completion events, and raced-request
  accounting.
- Fixer disputes, bounded passes, report correction, parse leniency, and settlement.
- Initial and failure pickers, setup persistence, report destruction, failure, and accounting.
