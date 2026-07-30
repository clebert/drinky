# FEATURES.md

What pith does, one short sentence per capability. It is an overview, not a specification: the _why_
and _how_ live in commit history, `BACKLOG.md` (planned work), and `docs/`.

pith is a terminal coding agent. You type a prompt; the model reads, searches, writes, and edits
files in the working directory while the conversation streams inline into your scrollback. It talks
to Anthropic and OpenAI, through either a subscription login or an API key.

## Talking to it

- A prompt runs a turn to completion: stream a reply, run its tools, feed the results back, repeat.
- At most 50 tool rounds per turn.
- Read-only tool calls in one reply run in parallel; a mutating call — write, edit, or bash — runs
  alone, in call order.
- Enter during a turn queues a steering message that folds into the run at the next tool round.
- Alt+Up pulls messages the turn has not picked up yet back into the editor to keep editing.
- Steering left in the queue when a turn completes starts the next turn on its own.
- Esc or Ctrl+C cancels a turn; cancelled or failed turns keep finished rounds, drop the in-flight
  tail, and return uncommitted text to the editor.
- A tool call left unfinished is recorded as an error, so a cancelled mutation is never lost
  silently.
- Timeouts and transient failures retry the whole request, clearing the partial reply first.
- A reply cut short by the output cap is kept, and reported as cut short.
- Model-side failures — a refusal, an empty reply, the round cap — read as a plain sentence rather
  than an internal error.
- Reasoning streams into its own block; encrypted reasoning shows as `[redacted thinking]`.

## Tools

- The model gets six tools: `read`, `write`, `edit`, `find`, `grep`, and `bash`.
- **read** — page a UTF-8 file from a 1-indexed line offset, 2000 lines or 50 KiB per call, with a
  next-offset hint.
- **write** — create or overwrite a file atomically.
- **edit** — replace one exact span, which must occur exactly once.
- **find** — glob search under a directory, sorted by path, 1000 hits by default.
- **grep** — literal search printing `path:line:text` under a directory or in a single named file,
  with glob and case filters, 100 hits by default.
- **bash** — run a shell command in the working directory, preserving combined stdout and stderr
  order and returning a bounded tail; a non-zero exit is reported, and output caps and the timeout
  are configurable, the timeout also settable per call.
- Globs use `*` and `?` within a path segment and `**` across segments.
- Searches skip version-control and build directories.
- Binary files are skipped, oversized files are refused, and every result says when a limit cut it
  short.
- A failing tool returns an error the model can read, and a cancel stops it at once.

## Models & reasoning effort

- Anthropic `claude-opus-4-8`, `claude-sonnet-5`, and `claude-sonnet-4-6`, at 1M tokens of context.
- OpenAI `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`, at 1.05M tokens of context.
- Output caps at 128k tokens per turn.
- A ChatGPT subscription learns its real context windows after login.
- Reasoning effort runs `none`, `low`, `medium`, `high`, `xhigh`, `max`, folded to what the model
  supports.
- Session cost and cache savings accumulate per model, counting a cancelled turn's billed usage.

## Accounts

- Anthropic and OpenAI, each reachable as a subscription account or a platform API-key account.
- Startup takes the first authenticated account, preferring a subscription over an API key.
- With no account at all, the login picker opens by itself.
- While signed out, a message is refused with a prompt to `/login`.
- Reasoning replays only to the account that produced it; a login or logout discards the rest.

## Signing in

- OAuth login uses PKCE (S256) with a loopback callback, and opens the system browser.
- When no browser opens the printed URL still works, and the callback waits five minutes.
- The browser lands on a plain "pith authorized — you can close this tab." page.
- Subscription tokens live in `~/.pith/auth.json`, owner-only, one entry per account, saved
  atomically.
- Expired access tokens refresh and re-save automatically.
- A login whose save fails stays signed in until pith exits, and says so.

## Slash commands

- **/model** — switch account and model together, from the next turn on.
- **/effort** — set the reasoning-effort level, from the next turn on.
- **/login** — sign in, switch to an account already signed in, or name the API key to set.
- **/logout** — drop a subscription's credentials and hand the session to another account.
- **/new** — clear the conversation, usage stats, and steering without changing its configuration.
- **/skill:name** — load a discovered skill explicitly, recording a compact `[skill]` marker and
  appending any trailing text as its task.
- Every other command answers with a line in the transcript, and an unknown one never reaches the
  model.
- A command typed during a turn stays in the editor until the turn ends.

## Providers

- Streams from Anthropic's Messages API and OpenAI's Responses API over SSE.
- A reply enters the conversation only once the provider reports it complete.
- Prompt caching is always on: explicit breakpoints for Anthropic, the automatic per-session cache
  for OpenAI.
- Reasoning is requested summarized at the resolved effort, and replayed verbatim on later turns.
- Subscription requests carry the vendor's first-party client identity; API keys go straight to the
  platform API.
- Requests time out after 30 s to the response head and 60 s between streamed events; keepalive
  filler does not count as progress.
- A failed request retries up to 3 times with 500 ms–16 s backoff, honoring a server's retry-after
  hint.

## The interface

- Renders inline into the normal screen buffer: settled rows scroll into your real scrollback, never
  an alternate screen.
- Repaints only the rows that changed, atomically; a resize or a change above the viewport reprints
  the window.
- Restores the terminal on exit, on a failed start, and around an interactive OAuth login.
- Typing, streaming output, and resizes are handled concurrently, so the interface never freezes
  mid-turn.
- Repaints are frame-limited and scheduled only while something is dirty or animating.
- Answer text grows as one block, with reasoning collected into a separate one tinted grey and
  italic; both render their markdown: headings, lists, blockquotes, code blocks, rules, and inline
  emphasis.
- A running tool shows a blue box with its name and arguments, then turns green or red with the
  first line of its output.
- A Braille "Working…" spinner runs while a turn is in flight.
- Queued steering shows as `Steering:` rows, and becomes one user message once consumed.
- The bottom line shows context fill, session cost, cache savings, the last request's cache-hit
  rate, and any OpenAI-subscription quota remaining, with `model · effort` right-aligned.
- A picker is a single-choice list tagging the current value; Enter confirms, Esc, Ctrl+C, or Ctrl+D
  cancels.
- The input frame grows to about a quarter of the screen and labels hidden rows "↑ N more" and "↓ N
  more".
- Model, tool, and user text can never emit escapes: controls and malformed UTF-8 render as
  replacement characters.

## Editing & text

- Enter sends, Shift+Enter or Ctrl+J makes a newline, Esc cancels, Ctrl+C clears, Ctrl+D quits; an
  intro line shows the bindings at launch.
- A second Ctrl+C within 500 ms quits, as does Ctrl+D on an empty editor or a closed stdin.
- The caret moves by grapheme cluster, by wrapped row with a sticky column, and to the start or end
  of the input.
- A paste over 10 lines or 1000 bytes collapses to a `[paste #N +L lines]` marker.
- A marker moves, deletes, and counts as one unit, and submits its exact bytes.
- Decodes the Kitty keyboard protocol and traditional escape sequences, including ones split across
  reads.
- A bracketed paste arrives as one unit, with controls and escapes inside kept as literal payload.
- Unrecognized sequences and stray control bytes are ignored rather than leaking into the text.
- Text is segmented per UAX #29, so an emoji family, a flag, or a Hangul syllable stays one glyph.
- A cluster measures 0, 1, or 2 columns, so CJK and emoji wrap, truncate, and place the caret
  correctly.
- Wrapping and truncation never split a cluster or let a wide one straddle the margin.
- Width and grapheme tables come from Unicode 17.0.0, regenerated with `zig build unicode` and
  checked against the official conformance corpus.

## Files & configuration

- Skills are discovered recursively from `~/.agents/skills/` and project `.agents/skills/`
  directories, following directory symlinks; their names and descriptions are advertised while their
  instructions load on demand.
- `~/.pith/config.json` is optional: request timeouts, retry policy, the bash output caps and
  timeout, and a default model per account.
- It holds no secrets — API keys come from `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`.
- A configured model that is not valid for its account is reported, and the compiled default used.
- `HOME` must be set, since both config and credentials live under `~/.pith`.

## Keeping this file true

One short sentence per capability, at the concept level — what a user gets, not how the code spells
it. When a capability lands, add its line and tick the matching `BACKLOG.md` item; when one goes
away, delete the line. Prefer merging a fact into a neighbouring line over adding a new one, and if
a section passes roughly a dozen lines it is either two sections or too much detail.
