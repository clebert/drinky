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

- **Pick the provider first, then the model** — so neither list grows too long. _`/model` lists one
  row per account-model pair today, up to 21 rows. `/login` lists accounts alone. A provider step
  does not name the account, because Anthropic has three, so the steps are provider, account, and
  model._
- **Configurable transcript window** — the 8-page transcript window moves into `config.json` and
  trades scrollback retention against per-frame redraw cost. _Clamp to at least one page._
- **Configurable gauge thresholds** — `config.json` sets the two shares at which a gauge takes the
  warning color and the error color. _The compiled pair is 75% and 90%, and it drives the context
  gauge and every quota window through one helper in `src/ui/status.zig`._

## Features

- **`/review`** — a bounded workflow reviews pending changes with a fresh reviewer, a persistent
  judge, and a fixer, and it asks the user only about an open product choice. _The plan is
  `docs/review-mode.md`. Store three account-model-effort role choices per project. Every role keeps
  the complete tool registry. The reviewer and judge prompts prohibit mutation, but `bash` remains
  unrestricted. It is not a subagent system, so one request runs at a time with no nesting._
- **Save and resume conversations** — a conversation reopens after a restart and does not start
  empty. _This entry introduces the per-turn cost ledger and persists it, since history items carry
  no cost. The `/session` breakdown entry then reads that ledger. Generate the OpenAI cache key once
  per conversation and restore it verbatim. Rotate it only on a deliberately fresh start. A
  billing-product enum is not sufficient provenance for opaque reasoning. Persist a durable
  non-secret principal identity and replay only on a match. Versioned, atomic, owner-only._
- **Headless mode** — Drinky answers a prompt with no terminal: text in, text out, with a session id
  to continue and flags for the model and the effort level. _This is the base for any agent that
  Drinky drives itself._
- **Per-model instructions** — Drinky loads the instruction file that belongs to the active model,
  so guidance can differ per model. _A model switch reloads the file._
- **`/handoff`** — compact the conversation into a summary and continue with the reclaimed context.
  _The command must also summarize canceled turns and the synthesized tool results they leave
  behind._
- **`/session` breakdown** — a session summary of tokens, cost, and cache savings, split by model.
  _It reads the per-turn ledger that the save-and-resume entry introduces. Cost belongs in the
  ledger, not in history items. Billing is per request. History must stay byte-stable for cache
  hits. A canceled turn's reply rolls back out of history. Canceled and failed turns get their own
  entries, so cost survives `/handoff` compaction._
- **Runtime model overrides** — an optional `~/.drinky/models.json` extends the compiled model table
  and adds an OpenAI-compatible endpoint, without a rebuild. _The noun `model catalog` belongs to
  the ChatGPT catalog in `lib/ai/openai/ModelCatalog.zig`, so this file is the model override file.
  Compiled defaults stay authoritative, so a known model always has a known context window. The file
  patches or adds alone. The endpoint form opens local and third-party models: ds4, qwen 3.6 27b,
  qwen 3.8 27b, gemma4, glimmer._
- **`/sources`** — a full-window page lists every instruction file, every skill, and every path rule
  that Drinky discovered at startup. _The page covers the guidance sources alone and holds no file
  content. It expands the startup counts line, and that line stays unchanged. It names each
  instruction file in load order, each skill, each replacement pair, each skipped file with its
  reason, and each path rule with its resolved skill or its missing name. It reports the startup
  discovery state, because every later skill load reads from that state. A run with no source opens
  the page too, and the page states that Drinky found nothing._

## Ideas

- Notify the user when a turn ends or fails and the terminal is not in the foreground.
- A picker layered over a live turn, so a command list opens mid-turn.
- Restart the same prompt in a new session.
- Benchmark models inside the Drinky harness.
