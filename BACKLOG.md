# Backlog

Four sections in priority order: bugs, improvements, features, ideas. A fix to existing behavior
outranks a new capability. Inside a section the top entry is the next one to do.

An entry is one line: a bold subject, an em dash, and one sentence. An italic note can follow it.
The note holds only what the implementer cannot re-derive from the code: an external constraint, a
decision already taken, or a dependency on another entry. Module layout and extension seams live in
`AGENTS.md`.

## How to maintain this file

- `TODO.md` is the inbox. It is git-ignored, and the user writes loose notes into it.
- Change this file only when the user asks for it, or to remove an entry that you landed. Never add,
  reorder, or reword an entry as a side task.
- Interview the user before you write. Use the `interview` skill and its form. Ask one question per
  message, and ask as many as you need. Stop when nothing is unclear. Never invent a priority.
- Delete an entry when it lands, and update `FEATURES.md`. Git history keeps the entry.
- Delete a promoted note from `TODO.md`, so the inbox holds unshaped notes alone.
- A feature line is the sentence that goes into `FEATURES.md` once it lands.
- An idea is one short line and carries no note. It is a placeholder against loss, not a plan.

## Bugs

## Improvements

- **Show a model that no source describes** — such a model takes a disabled picker row that names
  what it lacks, and its selection opens the hint for the config key. _`Catalog.merge` returns null
  and the caller drops the model today, so it leaves the picker with no line. A picker row carries
  the selection role or the muted role alone, so the row needs a third role, and the effort marker
  entry below needs it too. The hint names the config key of the model metadata feature, so land
  that feature first._
- **Mark an effort level that the model does not name** — the effort picker marks a level that
  folds, so the fold is visible before the choice. _The ladder prints the tag alone today._
- **Refresh the branch on input** — an input event that wakes the loop re-reads the repository head,
  so a checkout in another terminal shows without a turn. _An idle Drinky paints no frame, so the
  label stays stale until the next event. This limit is a decision, not a bug._

## Features

- **A herdr state socket** — Drinky reports a turn end and a failure over a socket, so herdr can
  notify the user. _The channel carries state outward alone, and nothing outside Drinky drives the
  session. Herdr holds a terminal open, so the work survives a closed lid. See <https://herdr.dev>._
- **Discussion mode** — a session mode switches the write tools off and allows the bash commands
  that the config lists, so a conversation cannot change the repository. _The bash tool holds deny
  patterns today, and this mode needs the opposite: an allow list that stands for the mode alone._
- **Headless mode** — Drinky answers a prompt with no terminal: text in, text out, with a session id
  to continue and flags for the model and the effort level. _This is the base for any agent that
  Drinky drives itself._
- **Model metadata in the config** — the config describes a model that no provider and no OpenRouter
  entry describes, so the user can unblock any model. _The provider wins every field it states, the
  config wins over OpenRouter, and OpenRouter fills the rest. It is the one metadata source for a
  local server. A later step can let Drinky write the entry for the user._
- **Save and resume conversations** — a conversation reopens after a restart and does not start
  empty. _This entry introduces the per-turn cost ledger and persists it, since history items carry
  no cost. The `/session` breakdown entry then reads that ledger. Generate the OpenAI cache key once
  per conversation and restore it verbatim. Rotate it only on a deliberately fresh start. A
  billing-product enum is not sufficient provenance for opaque reasoning. Persist a durable
  non-secret principal identity and replay only on a match. Versioned, atomic, owner-only._

## Ideas

- Restart the same prompt in a new session.
- Show tokens per second during a turn.
