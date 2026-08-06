# FEATURES.md

What pith does, one short sentence per capability. It is an overview, not a specification: the _why_
and _how_ live in commit history, `BACKLOG.md` (planned work), and `docs/`.

pith is a terminal coding agent. You type a prompt. The model reads, searches, writes, and edits
files in the working directory while the conversation streams inline into your scrollback. It talks
to Anthropic and OpenAI, through either a subscription login or an API key.

## Talking to it

- A prompt runs a turn to completion: stream a reply, run its tools, feed the results back, repeat.
- At most 1000 tool rounds per turn, as a guard against a runaway loop.
- Read-only tool calls in one reply run in parallel. A mutating call — write, edit, or bash — runs
  alone, in call order.
- Enter during a turn queues a steering message that folds into the run at the next tool round.
- Alt+Up pulls messages the turn has not picked up yet back into the editor to keep editing.
- Steering left in the queue when a turn completes starts the next turn on its own.
- Esc or Ctrl+C cancels a turn. Canceled or failed turns keep finished rounds, drop the in-flight
  tail, and return uncommitted text to the editor.
- A tool call left unfinished is recorded as an error, so a canceled mutation is never lost
  silently.
- Timeouts and transient failures retry the whole request and clear the partial reply first.
- A reply cut short by the output cap is kept, and reported as cut short.
- Model-side failures — a refusal, an empty reply, the round cap — read as a plain sentence rather
  than an internal error.
- Reasoning streams into its own block. Encrypted reasoning shows as `[redacted thinking]`.

## Tools

- The model gets six tools: `read`, `write`, `edit`, `find`, `grep`, and `bash`.
- **read** — page a UTF-8 file from a 1-indexed line offset, 2000 lines or 50 KiB per call, with a
  next-offset hint.
- **write** — create or overwrite a file atomically.
- **edit** — replace one exact span, which must occur exactly once.
- **find** — glob search under a directory, sorted by path, 1000 hits by default.
- **grep** — literal search that prints `path:line:text` under a directory or in a single named
  file, with glob and case filters, 100 hits by default.
- **bash** — run a shell command in the working directory, preserve combined stdout and stderr
  order, and return a bounded tail. A non-zero exit is reported. Output caps and the timeout are
  configurable, and the timeout is also settable per call.
- Globs use `*` and `?` within a path segment and `**` across segments.
- Searches skip version-control and build directories.
- Binary files are skipped, oversized files are refused, and every result says when a limit cut it
  short.
- A failing tool returns an error the model can read, and a cancel stops it at once.

## Models & reasoning effort

- Anthropic supports `claude-fable-5`, `claude-opus-5`, `claude-opus-4-8`, `claude-sonnet-5`, and
  `claude-sonnet-4-6` with 1M tokens of context.
- OpenAI `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`, at 1.05M tokens of context.
- Output caps at 128k tokens per turn.
- A ChatGPT subscription learns its real context windows after login.
- Reasoning effort runs `none`, `low`, `medium`, `high`, `xhigh`, `max`, folded to what the model
  supports.
- A restart resumes on the account, model, and effort level this project used last.
- `/model` and `/effort` both refuse while signed out, since the status line hides both values then.
- Session cost and cache savings accumulate per model and count a canceled turn's billed usage.

## Accounts

- Anthropic and OpenAI, each reachable as a subscription account or a platform API-key account.
- The Anthropic Console account adds an OAuth login that mints and stores a platform key.
- Startup resumes on the account this project used last, else takes the first authenticated one
  and prefers a signed-in login over an API key.
- With no account at all, the login picker opens by itself.
- While signed out, pith refuses a message with a prompt to `/login`.
- Reasoning replays only to the account that produced it. A login or logout discards the rest.

## Signing in

- OAuth login uses PKCE (S256) with a loopback callback, and opens the system browser.
- The Anthropic Console login trades its grant for a minted platform key, stored like a token.
- When no browser opens, the printed URL still works, and the callback waits five minutes.
- The browser lands on a plain "Pith received authorization. Close this tab." page.
- Subscription tokens and the Console key live in `~/.pith/auth.json`, owner-only, one entry per
  account, saved atomically.
- Expired access tokens refresh and re-save automatically.
- A login whose save fails stays signed in until pith exits, and says so.

## Slash commands

- **/model** — switch account and model together, from the next turn on.
- **/effort** — set the reasoning-effort level, from the next turn on.
- **/login** — sign in, switch to an account already signed in, or name the API key to set.
- **/logout** — drop a signed-in account's credentials and hand the session to another account.
- **/new** — clear the conversation, usage stats, and steering without changing its configuration.
- **/system** — inspect the complete provider-neutral system prompt as rendered Markdown in a
  scrollable full-window page. `M` toggles its exact source.
- **/skill:name** — load a discovered skill explicitly, record a compact `Skill:` marker, and append
  any trailing text as its task.
- Successful model, effort, login, logout, and account changes are recorded as transcript events.
- Unknown commands and other local command failures temporarily replace the footer until the next
  user action, and never reach the model.
- A command typed during a turn stays in the editor until the turn ends.

## Providers

- Streams from Anthropic's Messages API and OpenAI's Responses API over SSE.
- A reply enters the conversation only once the provider reports it complete.
- Prompt caching is always on: explicit breakpoints for Anthropic, the automatic per-session cache
  for OpenAI.
- Reasoning is requested summarized at the resolved effort, and replayed verbatim on later turns.
- Anthropic Subscription and Anthropic Console requests carry the Claude Code client identity. A
  plain API key goes straight to the platform API.
- Requests time out after 30 s to the response head and 60 s between streamed events. Keepalive
  filler does not count as progress.
- A failed request retries up to 3 times with 500 ms–16 s backoff and honors a server's retry-after
  hint.

## The interface

- The conversation renders inline into the normal screen buffer and real scrollback. Temporary
  full-window pages use the alternate screen and restore the conversation on close.
- Repaints only the rows that changed, atomically. A resize or a change above the viewport reprints
  the window.
- Restores the terminal on exit, on a failed start, and around an interactive OAuth login.
- Parks the cursor below the interface on exit, so the shell prompt does not overwrite the last
  frame.
- Handles typing, streaming output, and resizes concurrently, so the interface never freezes
  mid-turn.
- Repaints are frame-limited at a fixed rate and scheduled only while something is dirty or
  animating.
- Answer text grows as one block, with reasoning collected into a separate one tinted grey and
  italic. Both render their markdown: headings, lists, blockquotes, code blocks, rules, and inline
  emphasis.
- A running tool shows a blue box with its name and arguments. It then turns green or red with a
  one-line stat summary (lines read, matches found, exit status), or its first output line when the
  tool gives no summary.
- A heavy accent segment orbits the input border while a turn is in flight. It grows as progress
  goes quiet without adding a layout row.
- Queued steering shows as `Queued message:` rows, and becomes one user message once consumed.
- The bottom line shows context fill, cost, cache-hit rate, quota, and `model (account) · effort`.
  At most one temporary notice replaces it until the next user action.
- A picker is a single-choice list that tags the current value. Enter confirms, and Esc, Ctrl+C, or
  Ctrl+D cancels.
- The closed input frame grows to about a quarter of the screen and labels hidden rows "↑ Hidden: N"
  and "↓ Hidden: N".
- Model, tool, and user text can never emit escapes: controls and malformed UTF-8 render as
  replacement characters.

## Editing & text

- Enter sends, Shift+Enter or Ctrl+J makes a newline, Esc cancels, Ctrl+C clears, Ctrl+D quits. An
  intro line shows the bindings at launch.
- A second Ctrl+C within 500 ms quits, as does Ctrl+D on an empty editor or a closed stdin.
- The caret moves by grapheme cluster, by wrapped row with a sticky column, and to the start or end
  of the input.
- A paste over 10 lines or 1000 bytes collapses to a `[Paste #N: L lines]` marker.
- A marker moves, deletes, and counts as one unit, and submits its exact bytes.
- Decodes the Kitty keyboard protocol and traditional escape sequences, including ones split across
  reads.
- A bracketed paste arrives as one unit, with controls and escapes inside kept as literal payload.
- Unrecognized sequences and stray control bytes are ignored and never leak into the text.
- Text is segmented per UAX #29, so an emoji family, a flag, or a Hangul syllable stays one glyph.
- A cluster measures 0, 1, or 2 columns, so CJK and emoji wrap, truncate, and place the caret
  correctly.
- Wrapping and truncation never split a cluster or let a wide one straddle the margin.
- Width and grapheme tables come from Unicode 17.0.0, regenerated with `zig build unicode` and
  checked against the official conformance corpus.

## Files & configuration

- The compiled core is minimal and mechanical, so the user owns the guidance that steers a turn.
- The system prompt adds the startup UTC date, the working directory, and the repository root. It
  also ranks the instruction sources it carries, so the model knows which one wins on a conflict.
- pith loads exact-case `AGENTS.md` files in path order.
- pith discovers skills recursively from `~/.agents/skills/` and project `.agents/skills/`
  directories and follows directory symlinks. Their names and descriptions are advertised while
  their instructions load on demand.
- pith loads the user instruction files that `config.json` names, in order.
- One startup line counts the instruction files that pith loaded and the skills that it found. A
  count of zero stays out of the line. Only a skipped file gets its own line, and `/system` shows
  every counted path.
- User and project instructions obey one policy: a regular UTF-8 file, with content, no NUL byte,
  and at most 32 KiB. Each source loads at most 32 files and 64 KiB, and one file loads once even
  when two paths or a symbolic link reach it. pith reports what it skips.
- `~/.pith/config.json` is optional: paths for user instructions, request and bash limits, a
  default model per account, and a default effort level.
- It holds no secrets. API keys come from `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`.
- A configured model that is not valid for its account is reported, and the compiled default used.
  An unknown effort level is reported the same way.
- `~/.pith/state.json` remembers per project which account, model, and effort level pith used last.
  It is machine-local, owner-only, and keeps the 1000 most recently changed projects. A repository
  is one project, keyed by its Git root.
- pith reads that file only at startup, so a change in one instance reaches only the next start.
  A file pith cannot save to is reported once and never stops the session.
- `HOME` must be set, since the config, the credentials, and the state all live under `~/.pith`.

## Keeping this file true

One short sentence per capability, at the concept level: what a user gets, not how the code spells
it. When a capability lands, add its line and tick the matching `BACKLOG.md` item. When one goes
away, delete the line. Merge a fact into a neighbouring line rather than add a new one. If a section
passes roughly a dozen lines, it is either two sections or too much detail.
