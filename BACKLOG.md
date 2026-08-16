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

- **A full-window page cannot close in Apple Terminal** — Esc does not leave `/colors` or `/system`,
  the trackpad does not scroll, and the page leaves the scrollback in place. _The user must close
  the terminal to escape the page. Ghostty works. Degraded colors and widths in Apple Terminal stay
  acceptable, but a page that traps the user does not._
- **A slash line with extra text reaches the model** — a line that starts with a command name plus
  more text goes to the provider. _No line that starts with a slash must reach the model. The
  whole-line rule went too far, so report the line locally instead. This entry implements the
  Command refusal prerequisite: keep unavailable command text in the editor and name the active
  restriction during a turn, retry, or review. `/skill:name` keeps its trailing task text._
- **The picker cannot scroll up** — the selection does not move back into the rows above the
  viewport.
- **A picker wastes rows on a short list** — blank rows appear when the list fits the window. The
  `/colors` page has the same defect.

## Improvements

- **A tool call holds one row** — the row truncates the arguments with an ellipsis instead of a
  wrap, and it slides while the arguments stream, so the newest token stays visible. _A finished
  call keeps two rows: the arguments, then the result. The row snaps back to the start of the
  arguments once the call commits, because the head names the file or the command. Use one `…`
  character inside the row width. A user message box keeps its wrap. Today a pending `write` or
  `edit` box grows its spinner alone, so a long call shows no progress. A streamed token must reset
  the spinner width too. Both transports already parse the argument fragments and know the tool name
  at block start, so the missing piece is a display-only delta beside streamed text and reasoning.
  The tool still runs after the reply commits, so nothing runs on half-received arguments. Drop the
  provisional box on a retry's stream reset. The diff view for an edit must fit this one-row rule
  later._
- **Carriage returns in tool output** — a result row shows a progress line as its final state, not a
  replacement glyph for every carriage return. _Real tool output carries one: `curl` and `pip`
  redraw a line in place. Keep only the text after the last carriage return in a line, because a
  terminal overwrote what came before it. The main seam is `paint.box`, which draws a user message
  too. In `markdown`, `walk` sheds the carriage return at the end of a CRLF line, so only one inside
  a line is left there. The sink turns a control byte into U+FFFD to keep its column math, so the
  text must lose the byte first. `boxRows` and `box` must share the rule, or the row counts
  diverge._
- **The same padding everywhere** — the editor and the reasoning block carry the padding of a
  message box, so a copy of the rows matches the boxes at the same window width. _Pith cannot
  intercept a terminal copy, so the painted rows must line up._
- **A reworked picker** — the picker rolls over from the last row to the first and keeps one clear
  scroll rule.
- **An unknown command opens the command picker** — instead of a footer notice alone. _This depends
  on the slash-line bug, which routes every slash line locally._
- **Pick the provider first, then the model** — so neither list grows too long. _`/model` and
  `/login` list account and model together today._
- **A parked message and a message history** — the user parks the editor content to run a command,
  and walks earlier messages with the arrow keys. _Ctrl+P already recalls the steering queue._
- **Context-window pressure signal** — the context gauge warns as it fills, and feeds a compaction
  threshold. _The thresholds are configurable. Color the gauge as it fills, and consider the same
  accent for the branch, the model, and the effort level. Fold in two model-specific dimensions:
  tiered pricing above a context threshold, and OpenAI's effective context window (decoded at login
  but unused). The effective window must drive the warning while the catalog window stays the
  displayed limit. Quality degradation has no evidence-based number, so keep it a soft warning._
- **A two-line status bar** — a narrow window falls back to two rows instead of dropping fields.
  _Shorter quota text and shorter labels are the cheaper first step._
- **Read the last prompt and the last answer during a turn** — a full-window page shows the
  submitted prompt or the last answer, with no need to cancel. _Pith already retains the submitted
  prompt's rich draft for the whole turn._
- **A diff view for an edit** — an `edit` result shows what changed instead of a stat line alone.
- **Tab completion** — Tab completes a partial slash command and lists the candidates when several
  match. _Tab currently decodes as ctrl-i._
- **Configurable transcript window** — the 8-page transcript window moves into `config.json` and
  trades scrollback retention against per-frame redraw cost. _Clamp to at least one page._
- **A retry is recorded in the transcript** — a transcript event names each retry attempt and its
  cause, so a restarted reply never reads as a change of mind. _A permanent event block, like the
  model and login events, not a footer notice. It covers every attempt, including one that fails at
  the response head and shows nothing. A later refinement can narrow it to an attempt that discards
  streamed rows. `Agent.fetchReply` retries at four points but reports only `onStreamReset`, which
  runs on a discarded partial reply alone, so the handler needs one more callback._

## Features

- **Active context projection** — Pith filters one canonical history for the active account and
  model, then deeply repaints its transcript.
- **Failure recovery and retry** — Ctrl+N retries committed work or a generated request without
  sending editor text, and Enter can add that text to the retry.
- **Conversation switching** — Pith selects the agent, history, transcript, and status through one
  shared operation, then applies active context projection.
- **`/review`** — a bounded workflow reviews pending changes with a fresh reviewer, a persistent
  judge, and a fixer, and it asks the user only about an open product choice. _The plan is
  `docs/review-mode.md`. It depends on the three preceding entries and the slash-line bug. Store
  three account-model-effort role choices per project. Every role keeps the complete tool registry.
  The reviewer and judge prompts prohibit mutation, but `bash` remains unrestricted. It is not a
  subagent system, so one request runs at a time with no nesting._
- **Save and resume conversations** — a conversation reopens after a restart and does not start
  empty. _Persist the per-turn cost ledger with it, since history items carry no cost. Persist the
  prompt-cache write times too, so a resume knows what retention is left. Generate the OpenAI cache
  key once per conversation and restore it verbatim. Rotate it only on a deliberately fresh start. A
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
- **`/session` breakdown** — a per-turn ledger backs a session summary of tokens, cost, and cache
  savings, split by model. _Cost belongs in the ledger, not in history items. Billing is per
  request. History must stay byte-stable for cache hits. A canceled turn's reply rolls back out of
  history. Canceled and failed turns get their own entries, so cost survives `/handoff` compaction._
- **`/handoff`** — compact the conversation into a summary and continue with the reclaimed context.
  _The command must also summarize canceled turns and the synthesized tool results they leave
  behind._
- **`/cache-retention`** — choose the active model's prompt-cache retention where the provider
  offers a real choice. _Anthropic offers 5m and 1h. The 1h write costs 2x base input against 1.25x,
  so pricing needs a per-TTL write rate. One TTL across all breakpoints sidesteps the ordering rule.
  Current OpenAI models expose only 30m, so report it and do not open a picker. Never guess. When
  the policy is unknown, omit the field and report the provider default. Reset to that default on
  `/model`. Cache warming is the rival approach: replay the last request with `max_tokens: 1` just
  under the TTL. This buys a near-free read instead of the 1h write premium, and it pays off once
  the main agent sits idle for minutes (cf. claude-thermos)._
- **Custom prompts** — user-maintained prompt templates run as slash commands with argument
  substitution. _The whole-line rule special-cases the `skill:` prefix today. A second
  argument-taking command must move that rule into the registry `Entry`._
- **Runtime model catalog** — an optional `~/.pith/models.json` extends the compiled model table and
  adds an OpenAI-compatible endpoint, without a rebuild. _Compiled defaults stay authoritative, so a
  known model always has a known context window. The file patches or adds alone. The endpoint form
  opens local and third-party models: ds4, qwen 3.6 27b, qwen 3.8 27b, gemma4, glimmer._
- **Per-model instructions** — pith loads the instruction file that belongs to the active model, so
  guidance can differ per model. _A model switch reloads the file._

## Ideas

- Subagents, in some shape: a subshell, or a scheduler inside one process.
- Restart the same prompt in a new session.
- Benchmark models inside the pith harness.
