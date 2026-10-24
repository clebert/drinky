---
name: architecture
description:
  Detailed architecture contracts for controller integration, actors, native clients, and billing.
  Load before you change or review module ownership, public contracts, actors, concurrency,
  timeouts, frontend behavior or text, or billing.
---

# Architecture contracts

These contracts supplement the ownership and concurrency rules in `AGENTS.md`.

## Runtime

`Tty` implements the terminal device seam.

`lib/core` holds the shared actor shell, timeout race, error-set check, allocation panic, and text
helpers. A timed call with a zero timeout window starts its task without a timer.

For `lib/core`, an account is an opaque id. A reasoning proof holds that id and opaque payload
bytes. The session is an actor with one command loop and one child task for a turn or an aside. An
aside sends one request outside the conversation. It uses no tools and uses the model and the effort
of a turn.

The account registry is an actor with a child task for a sign-in or a model fetch. A row is an index
into the account table. The `Client` in `lib/accounts` builds the provider of one row. It reports
its usage source before the stop of every reply.

## Controller

The controller exposes an opaque handle with semantic commands, queries, synchronous responses,
events, and snapshots. A command names its target by an account, a model, a turn id, or an operation
id. No client repeats a turn rule on the records. The controller validates the target and the
current state of each command. It asks for no confirmation.

A refusal, a startup refusal, a notice, and a record event are typed facts with data fields. Each
client words them. A client dismisses a notice by its id. A stale notice id changes no state.

Each frontend supplies its output instructions and reference text as data. The controller requires
frontend text and copies it during creation. A frontend can release that text when creation returns.
The application composes those texts with the shared instructions and reference facts.

The public `support` namespace exposes helpers without a runtime owner or controller access.
`support.outOfMemory` exposes `core.fatal.outOfMemory`.

## Native clients

The terminal loop owns keys, editor mechanics, focus, and animation. It also owns slash-command
parsing, pickers, pages, drafts, confirmation policy, command descriptions, control hints, terminal
reference text, and terminal output instructions.

- `src/reference.zig` owns the command table and control hints.
- `src/describe.zig` owns the native reference text and output instructions.
- `src/format.zig` owns the native display helpers.
- `src/wording.zig` words the refusals and record events.
- `src/headless.zig` words the startup refusals.

The screen owns its layout caches. It applies states and snapshots through one path. A snapshot
keeps the local pickers and pages. The presentation copy applies record changes by id and groups
work runs for display. Routine repaints use the local copy without a snapshot. The UI fits and
paints Markdown through one shared layout walk. `Herdr.Endpoint` stays terminal integration data.

## Billing

A turn and an aside report the final available usage of each model attempt to the controller. The
controller adds each cost to the session total. `lib/application/billing.zig` holds the charge rule.
The runner reports tool costs through its own sink. A `drinky run` under the `bash` tool reports its
costs through a private pipe to that sink. The pipe ends with the `bash` invocation.
