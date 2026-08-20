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
- **A retry is recorded in the transcript** — a transcript event names each retry attempt and its
  cause, so a restarted reply never reads as a change of mind. _A permanent event block, like the
  model and login events, not a footer notice. It covers every attempt, including one that fails at
  the response head and shows nothing. A later refinement can narrow it to an attempt that discards
  streamed rows. `Agent.fetchReply` retries at four points and calls `onStreamReset` on every
  attempt after the first, so that callback needs a cause payload, not a second callback._
- **Context-window pressure signal** — the context gauge warns as it fills, and feeds a compaction
  threshold. _The thresholds are configurable. Color the gauge as it fills, and consider the same
  accent for the branch, the model, and the effort level. Fold in two model-specific dimensions:
  tiered pricing above a context threshold, and OpenAI's effective context window. The window that
  a ChatGPT login discovers already resolves the displayed limit. The unused parts are
  `max_context_window` and `effective_context_window_percent`, and that percent of the resolved
  window must drive the warning. Quality degradation has no evidence-based number, so keep it a soft
  warning._
- **A two-line status bar** — a narrow window falls back to two rows instead of dropping fields.
  _Shorter quota text and shorter labels are the cheaper first step._
- **A parked message and a message history** — the user parks the editor content to run a command,
  and walks earlier messages with the arrow keys. _Ctrl+P already recalls the steering queue._

## Features

- **Active context projection** — Pith filters one canonical history for the active account, then
  deeply repaints its transcript. _The model is not a dimension. Reasoning provenance is per exact
  account, and the Anthropic Fable fallback replays mixed-model reasoning in one account. The
  OpenAI cross-model replay is unconfirmed, but Pith already performs it on every `/model` switch,
  and a rejection fails loudly._
- **Conversation switching** — Pith selects the agent, history, transcript, and status through one
  shared operation, then applies active context projection.
- **`/review`** — a bounded workflow reviews pending changes with a fresh reviewer, a persistent
  judge, and a fixer, and it asks the user only about an open product choice. _The plan is
  `docs/review-mode.md`. It depends on the two preceding entries. Store three account-model-effort
  role choices per project. Every role keeps the complete tool registry. The reviewer and judge
  prompts prohibit mutation, but `bash` remains unrestricted. It is not a subagent system, so one
  request runs at a time with no nesting._
- **Save and resume conversations** — a conversation reopens after a restart and does not start
  empty. _This entry introduces the per-turn cost ledger and persists it, since history items carry
  no cost. The `/session` breakdown entry then reads that ledger. Persist the prompt-cache write
  times too, so a resume knows what retention is left. Generate the OpenAI cache key once per
  conversation and restore it verbatim. Rotate it only on a deliberately fresh start. A
  billing-product enum is not sufficient provenance for opaque reasoning. Persist a durable
  non-secret principal identity and replay only on a match. Versioned, atomic, owner-only._
- **Headless mode** — pith answers a prompt with no terminal: text in, text out, with a session id
  to continue and flags for the model and the effort level. _This is the base for any agent that
  pith drives itself._
- **Path-triggered skills** — pith makes sure the model loaded the required skill before a tool
  writes a matching file. _Config-driven: a glob maps to a skill name in `config.json`. Pith does
  not know the user's skills or the files the user edits, so nothing is hard-coded. Zig style is
  only the first case, and TypeScript and others follow._
- **A configurable bash guard** — `bash` refuses a command that matches a user pattern, and reports
  the refusal. _The user owns the pattern list, and `git add` is one example. There is no permission
  model and no prompt for consent._
- **Per-model instructions** — pith loads the instruction file that belongs to the active model, so
  guidance can differ per model. _A model switch reloads the file._
- **`/handoff`** — compact the conversation into a summary and continue with the reclaimed context.
  _The command must also summarize canceled turns and the synthesized tool results they leave
  behind._
- **`/session` breakdown** — a session summary of tokens, cost, and cache savings, split by model.
  _It reads the per-turn ledger that the save-and-resume entry introduces. Cost belongs in the
  ledger, not in history items. Billing is per request. History must stay byte-stable for cache
  hits. A canceled turn's reply rolls back out of history. Canceled and failed turns get their own
  entries, so cost survives `/handoff` compaction._
- **Runtime model overrides** — an optional `~/.pith/models.json` extends the compiled model table
  and adds an OpenAI-compatible endpoint, without a rebuild. _The noun `model catalog` belongs to
  the ChatGPT catalog in `lib/ai/openai/ModelCatalog.zig`, so this file is the model override file.
  Compiled defaults stay authoritative, so a known model always has a known context window. The file
  patches or adds alone. The endpoint form opens local and third-party models: ds4, qwen 3.6 27b,
  qwen 3.8 27b, gemma4, glimmer._

## Ideas

- A picker layered over a live turn, so a command list opens mid-turn.
- Subagents, in some shape: a subshell, or a scheduler inside one process.
- Restart the same prompt in a new session.
- Benchmark models inside the pith harness.
