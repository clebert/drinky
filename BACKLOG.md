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

- **Re-sync the cursor after a resize** — the view queries the cursor position (`DSR 6`) after a
  resize and rebases its tracked screen top, so a tracking divergence cannot strand stale rows in
  the scrollback. _A height-only change never resets, so a divergence is permanent. Two causes
  exist: a resize that lands inside a frame burst, and a terminal that pulls scrollback down on
  height growth. Both are rare, and a forced reset is no fix, because it drops the scrollback.
  Accept `R` as a report only while a query is outstanding, because a modified F3 also ends in `R`.
  Give the `Emulator` a bottom-anchored resize mode for the regression test._
- **Paint a truncated reply as an error** — the event of a cut-short reply takes the error role,
  because an incomplete answer is a failed turn. _The session appends it with `is_error` false, and
  `block.zig` paints the error role from that flag alone._

## Improvements

- **Fetch the model list on a worker** — the fetch leaves the consumer thread, so the wait animates,
  Esc cancels it, and the picker clears its rows while it runs. _`Accounts.refresh` runs inside the
  command step today, so the frame timer never rearms and the interface paints zero frames._
- **Bound a model fetch with one deadline** — one deadline covers the whole fetch, so a hung
  provider cannot hold the fetch open without end. _A 30-second bound covers each request alone, and
  no idle bound reaches a model fetch. A list runs up to eight pages, and the OpenRouter request
  follows it, so the sum is minutes. `net.Deadline` exists for this. The entry above takes the
  freeze away, so this one guards the socket alone and waits for it._
- **Show a model that no source describes** — such a model takes a disabled picker row that names
  what it lacks, and its selection opens the hint for the config key. _`Catalog.merge` returns null
  and the caller drops the model today, so it leaves the picker with no line. A picker row carries
  the selection role or the muted role alone, so the row needs a third role. The `No model` row of
  the `/review` setup takes that same role, and the effort marker entry below needs it too. The hint
  names the config key of the model metadata feature, so land that feature first._
- **Mark an effort level that the model does not name** — the effort picker marks a level that
  folds, so the fold is visible before the choice. _The ladder prints the tag alone today._
- **Show tokens per second during a turn** — the status line states the rate of the running turn.
  _The provider counts the tokens at the end of a turn. The live figure estimates from the bytes of
  the stream and the ratio of the last turn._
- **Refresh the branch on input** — an input event that wakes the loop re-reads the repository head,
  so a checkout in another terminal shows without a turn. _An idle Drinky paints no frame, so the
  label stays stale until the next event. This limit is a decision, not a bug._

## Features

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
- **`/sources`** — a full-window page lists every instruction file, every skill, and every path rule
  that Drinky discovered at startup. _The page covers the guidance sources alone and holds no file
  content. It expands the startup counts line, and that line stays unchanged. It names each
  instruction file in load order, each skill, each replacement pair, each skipped file with its
  reason, and each path rule with its resolved skill or its missing name. It reports the startup
  discovery state, because every later skill load reads from that state. A run with no source opens
  the page too, and the page states that Drinky found nothing._
- **Discussion mode** — a session mode switches the write tools off and allows the bash commands
  that the config lists, so a conversation cannot change the repository. _The bash tool holds deny
  patterns today, and this mode needs the opposite: an allow list that stands for the mode alone._
- **llama.cpp server support** — Drinky reaches a local llama.cpp server and discovers its models
  from `/v1/models`. _The server speaks the chat/completions API, so this needs a third transport
  with its own stream shape and tool-call format. It depends on the config metadata entry, because
  `/v1/models` describes no model and prices none._
- **A herdr state socket** — Drinky reports a turn end, a failure, a review hold, and a settlement
  over a socket, so herdr can notify the user. _The channel carries state outward alone, and nothing
  outside Drinky drives the session. Herdr holds a terminal open, so the work survives a closed lid.
  See <https://herdr.dev>._
- **A review record** — Drinky writes each generated request and each role report into one
  plain-text file per review, so the prompts improve from real runs. _The file holds no tool call,
  no tool result, and no message of the user, because that traffic buries the material._

## Ideas

- Notify the user when a turn ends or fails and the terminal is not in the foreground.
- A picker layered over a live turn, so a command list opens mid-turn.
- Restart the same prompt in a new session.
- Benchmark models inside the Drinky harness.
- Separate the changes of the user from the changes of Drinky with a git snapshot.
- A rounds row in the `/review` setup, so a run picks its own ceiling.
