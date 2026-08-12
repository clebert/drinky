# Review Mode

Status: Plan.

## Scope

`/review` runs a bounded review, judgment, fix, and re-review workflow over pending changes. It asks
the user only for unresolved product choices. The command takes no argument.

This workflow is not a general subagent system. It has no nesting and runs one request at a time.

| Role       | Context             | Work                                                           |
| ---------- | ------------------- | -------------------------------------------------------------- |
| Main agent | Existing and paused | Keeps the original task conversation.                          |
| Reviewer   | Fresh each round    | Finds concrete defects in the current changes.                 |
| Judge      | Persistent          | Validates findings, resolves disputes, and settles the review. |
| Fixer      | Fresh each pass     | Applies the judge report or disputes it with evidence.         |

One selected account-model pair runs the reviewer and the fixer. A second pair runs the judge. The
same account or model can fill both selections.

## Setup

`/review` opens this setup before it sends a request:

```text
Select a review setup

 > Start review
   Review and fix: claude-opus-5 (Anthropic Subscription)
   Judge: gpt-5.6-sol (OpenAI Subscription)
```

The setup is the normal picker, so it keeps the standard key hint. A role row opens the existing
account-model picker and then returns to the setup. Both roles run at the effort level of the
session, which the status line already shows.

Pith stores the two confirmed pairs per project in `state.json`. The next setup preselects them and
puts the cursor on `Start review`. The common path needs one additional Enter press.

The first setup selects the active pair for both roles. `Start review` on an unavailable pair
reports a notice and starts nothing, so the picker needs no disabled row. Pith never selects a
fallback silently. Setup never changes the active main account, model, or effort level.

## Target, context, and tools

The first version requires a Git worktree. Its target is every change from `HEAD`, including staged,
unstaged, and untracked files. Each reviewer inspects the target after the latest fixer pass.
Outside a worktree `/review` reports a notice and starts nothing.

Pith computes no diff and runs no Git command of its own. Each role finds the target through its
tools, and its role prompt names the way: `git status` for the file list, `git diff HEAD` for the
tracked changes, and a `read` of each untracked file. `git diff HEAD` alone hides an untracked file,
so the file list must come first.

Pith never stages, commits, restores, or changes the index. Staging has no effect on the target.

Every role receives the normal environment, instruction, and skill sections. Only the system core
differs, so one composition call takes a role core in place of the default core. The precedence
section of the prompt then stays true, because it ranks the core first. A project instruction can
never outrank the review policy.

The reviewer core and the judge core carry the review policy of that role. The default core carries
none of it, because a user who runs no review must not carry review rules.

The fixer takes the main system prompt without a change. Its rules belong in the fix packet, because
they change with each pass. An identical prompt and tool list can also read the cached prefix of the
main agent, when the fixer runs on the same account and model.

The reviewer and the judge do not receive the main conversation. Workflow user decisions become
requirements for every later role.

Review histories, cache keys, context gauges, and usage stay separate from the main agent. A fresh
fixer therefore works when the main context is full. Review mode does not compact that main context.

A role tool profile gates the provider tool schemas and the local dispatch. The reviewer and the
judge receive `read`, `find`, `grep`, and `bash`. They receive no `write`, `edit`, or `config`.
Their role prompt prohibits a mutating shell command. Pith plans no permission model, so only the
planned configurable bash guard can enforce that restriction.

The fixer receives the complete tool registry and a compact packet with these items:

- The judge report, accepted findings, required results, evidence, and affected locations.
- All workflow user decisions.

The fixer reads the current worktree through tools. It receives no reviewer tool history and no
judge reasoning.

## Flow

```text
setup
  -> fresh reviewer
  -> persistent judge
       -> settled -> finish
       -> fix required -> fresh fixer -> fresh reviewer
       -> user decision required -> pause -> fresh fixer -> fresh reviewer
```

Pith discards each reviewer and fixer context after its phase. Every fixer pass gets a later fresh
review. The judge receives each reviewer report, the preceding fixer report, and all user decisions.

The workflow permits at most four reviewer rounds. Only a reviewer phase counts, so a judge phase, a
fix pass, and a pause add no round. Pith does not start a fixer when no later review round remains.
Reaching the limit stops the workflow without settlement.

A failed request stops the whole workflow without settlement. This covers a network failure, a dead
credential, and an exhausted allowance. Pith reports which phase failed.

## Review policy

The reviewer reports only defects in the target and its direct effects. Each finding names a
location, consequence, and supporting evidence. Required tests, required documentation, and
objective wording defects are in scope.

The reviewer excludes unrelated cleanup, speculative improvements, and valid design preferences. It
reports no findings when none exist. One report contains at most eight findings.

The judge report must carry one decision line. It must be one of these lines:

```text
Decision: Fix required.
Decision: Review settled.
Decision: User decision required.
```

Pith takes the first line that starts with `Decision:` and classifies it by its keyword. A report
with no such line stops the workflow without settlement. One tolerant parse rule replaces a
correction round-trip.

A tool call is the other way to carry a verdict. Pith does not take it. The tool profile can hide a
`verdict` tool from every other role, but a tool result starts one more request in the same phase,
and the report must stay visible prose for the fix packet. The parse rule needs neither.

The judge checks the current files and validates each finding. It can reject a finding or add a
missed finding. Its visible report becomes the next fix packet.

The judge blocks settlement for these findings:

- A correctness, security, or data-loss defect.
- A regression or a missing required test.
- False or missing documentation required by project instructions.
- A concrete maintainability defect in changed code.
- An objective wording or terminology defect.

The judge does not block settlement for subjective refactors, valid internal alternatives, unrelated
defects, speculative requirements, duplicates, or resolved findings.

A settlement is valid only after a fresh reviewer inspected the current target. No accepted finding,
failed required check, or pending user decision can remain. One valid settlement ends the workflow.

## User decisions

The judge asks the user only when all these conditions apply:

- The choice changes visible behavior, UI, UX, or a public interface.
- At least two outcomes are valid.
- Existing requirements, tests, and documentation do not select one.
- Technical evidence cannot resolve the choice.

The judge resolves naming, internal architecture, test strategy, and clean-code disputes. A user
question gives the options, consequences, recommendation, and missing requirement.

The workflow pauses after the judge request completes. No request remains active. The normal editor
returns, and one transcript event states the purpose:

```text
The judge needs one decision. Answer it in the editor. Enter: Continue · Esc: Stop review
```

The event is durable, so the hint survives every keystroke. During the pause, Enter sends the answer
to the workflow instead of the model, and no slash command runs.

Pith records the answer as a workflow user decision. It sends the decision to the fresh fixer, all
later reviewers, and the persistent judge. The workflow then resumes automatically.

## Interface and input

Each phase adds a durable transcript event:

```text
Review round 1 started. Reviewer: claude-opus-5.
The judge started. Judge: gpt-5.6-sol.
Fix pass 1 started. Fixer: claude-opus-5.
```

An automatic phase replaces the editor with a progress frame in the same place:

```text
Review: Round 1 of 4 · Role: Reviewer
Esc: Stop review
```

The frame keeps the separators of the editor, so the activity indicator keeps its normal motion. It
shows no caret, because the phase accepts no input.

The status line keeps its parts and its narrow-window order. While a review phase runs, it shows the
account, model, effort, context fill, and cost of the active role. The main numbers return when the
workflow ends. A subscription allowance belongs to the account, so it carries across in both
directions.

Reports, reasoning, tool calls, and tool results remain visible. Internal role packets stay hidden.

A reviewer, judge, or fixer phase accepts no steering. Printable input and Enter do nothing. Esc or
Ctrl+C stops the whole workflow.

A user-decision pause stops the activity indicator, because no request runs. Normal input returns
after settlement, failure, or cancellation.

A successful workflow adds this event:

```text
The review settled after 2 rounds and 1 fix pass. Review cost: $0.42.
```

A limit, failure, or cancellation uses distinct wording and never claims settlement. Completed file
changes remain after every stop.

## Main handoff

Pith gives the main agent one compact note before its next request. The note states the outcome and
whether a fixer ran. It excludes reports, reasoning, and tool history.

The status line restores the main model, context, usage, and cache state. Existing cache-expiry
handling still applies. If the main context cannot hold the next request, the user must start a
fresh conversation.

## Implementation

Add one app-owned `Review` state machine. It owns the phase, the selections, the counters, the two
review agents, the pending question, the decisions, and the review totals.

`/review` needs an entry in the `ai.command` registry and one new `Outcome` variant, because the
state machine is app-owned and `lib/ai` cannot reach it.

Create both review agents when the user starts the review, and destroy them when the workflow ends:

- The judge agent keeps its history for the whole workflow.
- One worker agent runs every reviewer and fixer phase. `Agent.resetConversation` gives the next
  phase a fresh context and a fresh cache key. It also clears the agent statistics, so `Review` must
  add the cost of a phase to the review total before each reset.

Compose the reviewer core and the judge core once when the review starts. The worker agent then
takes the reviewer prompt or the main prompt for its next phase, and it changes the prompt and the
tool profile together with the reset.

Drive each phase through the existing event loop and the one existing turn future. The turn worker
takes the agent to run. Do not call an agent loop from another agent loop. Sequential requests avoid
credential-refresh races and need no subagent scheduler.

Keep `Session.Mode.turn` for every review phase, so the progress sequences, the tool boxes, the
receipts, and the cancellation path stay as they are. Add one tail variant that puts the progress
frame where the editor sits, and build it with the existing framed-input primitive. The turn
generation already identifies the phase, so a turn event needs no role tag. A stop reuses the turn
cancellation path, so it needs its own event wording in place of the turn sentence.

Reuse the picker mode for the setup. A picker selects a command handler today, so it needs one
app-owned alternative. Expose the account-model row builder through `ai.command`, so `/model` and
the setup show identical rows.

Give `Agent` a tool profile: the complete registry, or the inspect profile of the reviewer and the
judge. Set it between turns like the effort level, and drop the cache evidence with it, because the
serialized request changes.

Read a report from the joined turn instead of the event stream. The receipt names the history span
of the turn, and the last assistant message in that span is the report.

Extend the project state with the two confirmed pairs. Keep them out of the per-account model map,
because that map holds what the main session runs.

Required tests cover setup memory and invalid selections, state transitions, fresh contexts,
persistent judge history, packet ownership, decision parsing, a report with no decision line, pause
and resume, cancellation, request failure, round limits, target coverage, tool gating, accounting
separation, and each UI state.
