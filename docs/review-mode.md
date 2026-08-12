# Review Mode

Status: Plan.

## Scope

`/review` runs a bounded review, judgment, fix, and re-review workflow over pending changes. It asks
the user only for unresolved product choices.

This workflow is not a general subagent system. It has no nesting and runs one request at a time.

| Role       | Context             | Work                                                           |
| ---------- | ------------------- | -------------------------------------------------------------- |
| Main agent | Existing and paused | Keeps the original task conversation.                          |
| Reviewer   | Fresh each round    | Finds concrete defects in the current changes.                 |
| Judge      | Persistent          | Validates findings, resolves disputes, and settles the review. |
| Fixer      | Fresh each pass     | Applies the judge report or disputes it with evidence.         |

One selected account-model pair runs the reviewer and fixer. A second pair runs the judge. The same
account or model can fill both selections.

## Setup

`/review` opens this setup before it sends a request:

```text
Review setup

 > Start review
   Review and fix: claude-opus-5 (Anthropic Subscription)
   Judge: gpt-5.6-sol (OpenAI Subscription)
   Effort: high
```

Selecting a role opens the existing account-model picker and then returns to the setup. Both roles
use the displayed current effort level.

Pith stores the last confirmed pair per project in `state.json`. The next setup preselects that pair
and `Start review`. The common path needs one additional Enter press.

The first setup selects the active pair for both roles. An unavailable remembered pair disables
`Start review` until the user replaces it. Pith never selects a fallback silently. Setup never
changes the active main model.

## Target, context, and tools

The first version requires a Git worktree. Its target is every change from `HEAD`, including staged,
unstaged, and untracked files. Each reviewer inspects the target after the latest fixer pass.

Pith never stages, commits, restores, or changes the index. Staging has no effect on the target.

Every role receives the normal system prompt, instructions, and skill catalog. The reviewer and
judge do not receive the main conversation. Workflow user decisions become requirements for every
later role.

Review histories, cache keys, context gauges, and usage stay separate from the main agent. A fresh
fixer therefore works when the main context is full. Review mode does not compact that main context.

A role allowlist gates provider tool schemas and local dispatch. The reviewer and judge do not
receive `write` or `edit`. They receive `bash` for inspection and tests. Their prompts prohibit
mutating shell commands. Pith plans no permission model, so only the planned configurable bash guard
can enforce that restriction.

The fixer receives the normal tools and a compact packet with these items:

- The judge report, accepted findings, required results, evidence, and affected locations.
- All workflow user decisions.

The fixer reads the current worktree through tools. It receives no reviewer tool history or judge
reasoning.

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

The workflow permits at most four reviewer rounds. Pith does not start a fixer when no later review
round remains. Reaching the limit stops the workflow without settlement.

## Review policy

The reviewer reports only defects in the target and its direct effects. Each finding names a
location, consequence, and supporting evidence. Required tests, required documentation, and
objective wording defects are in scope.

The reviewer excludes unrelated cleanup, speculative improvements, and valid design preferences. It
reports no findings when none exist. One report contains at most eight findings.

The first judge line must be exactly one of these lines:

```text
Decision: Fix required.
Decision: Review settled.
Decision: User decision required.
```

Pith requests one correction after an invalid first line. A second invalid response stops the
workflow without settlement.

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

The workflow pauses after the judge request completes. No request remains active. The editor returns
with this purpose:

```text
Answer the review question
Enter: Continue · Shift+Enter: New line · Esc: Stop review
```

Pith records the answer as a workflow user decision. It sends the decision to the fresh fixer, all
later reviewers, and the persistent judge. The workflow then resumes automatically.

## Interface and input

Each phase adds a durable transcript marker:

```text
Review round 1 started with claude-opus-5 as the reviewer. Context: Fresh.
The judge started with gpt-5.6-sol.
Fix pass 1 started with claude-opus-5. Context: Fresh.
```

An automatic phase replaces the editor with a progress frame:

```text
Review: Round 1 of 4
Role: Reviewer
Esc/Ctrl+C: Stop review
```

The footer shows the role, round, account, model, effort, active context fill, and review cost. Main
and review usage remain separate. A narrow footer keeps the role and round before optional details.

Reports, reasoning, tool calls, and tool results remain visible. Internal role packets stay hidden.

Reviewer, judge, and fixer phases do not accept steering. Printable input and Enter do nothing.
Input never routes according to the active model. Esc or Ctrl+C stops the complete workflow.

A user-decision pause stops the activity indicator and shows `Review: Paused`. Normal input returns
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

The footer restores the main model, context, usage, and cache state. Existing cache-expiry handling
still applies. If the main context cannot hold the next request, the user must start a fresh
conversation.

## Implementation

Add one app-owned `Review` state machine. It owns the phase, selections, counters, judge agent,
fresh worker agent, pending question, decisions, and review totals.

Drive each phase through the existing event loop and one turn future. Do not call an agent loop from
another agent loop. Sequential requests avoid credential-refresh races and need no subagent
scheduler.

Tag turn events with their review role and generation. Add setup, automatic review, and
user-decision session modes. Reuse existing streams, tool boxes, pickers, cancellation, and
rendering.

Give `Agent` an immutable tool allowlist. Keep the complete registry as the fixer default. Extend
the project state with the confirmed account-model pair.

Required tests cover setup memory and invalid selections, state transitions, fresh contexts,
persistent judge history, packet ownership, decision parsing, pause and resume, cancellation, round
limits, target coverage, tool gating, accounting separation, and each UI state.
