# FEATURES.md

The complete catalog of what pith does — one line per capability, grouped by area. It describes
features at the concept level: the observable behavior and the guarantee each upholds, so it reads
as a specification that could guide a reimplementation in any language. The _why_ and _how_ live in
commit history, `BACKLOG.md` (planned work), and `docs/`.

## Maintaining this file

- **Concept level only.** Describe what a capability does and the behavior it guarantees, never how
  the code spells it — no type, function, module, field, or test names, and no language- or
  library-specific APIs. Keep genuine domain facts that are part of the feature itself: user-facing
  command and file names, wire-protocol facts (SSE, HTTP status codes), model identifiers, numeric
  limits that define observable behavior, and recognized standards and protocols (e.g. UAX #29,
  OAuth PKCE, the Kitty keyboard protocol, ANSI escape classes such as CSI/OSC/APC/DCS).
- **Timeless.** State only what exists, as if written correctly from the start. No references to
  past or future implementations, no "previously / now / instead", no change history.
- **Concise.** One entry per capability, kept as terse as clarity allows; less is more. A capability
  with several tightly-coupled guarantees may bundle them in one entry rather than fragment them,
  and fine-grained sub-features (individual caret moves, specific limits, per-tool options) are
  welcome when worth guarding against regression. Trim redundancy; state each fact once.
- **Complete.** Every implemented behavior belongs here; a reader should be able to enumerate the
  whole feature set from this file alone. Planned or partial work stays in `BACKLOG.md` until it
  ships.
- **Keeping it true.** When a capability lands, add its line under the right group (create a group
  if none fits) and mark any matching `BACKLOG.md` item done. Before and after a refactor, treat the
  relevant group as the checklist that must not regress — a behavior that vanishes is a bug, not a
  cleanup. Use this file to review the implementation for drift.

---

## Terminal & rendering

### Terminal control

- Enters raw mode (no echo, canonical processing, signals, or flow control) and restores the
  original terminal state on exit.
- On start, enables bracketed paste, the Kitty keyboard protocol (disambiguate level), and cursor
  hiding; reverses all three on exit.
- Input reading and output writing proceed concurrently; output is buffered.
- Reads can time out, so a reader blocked on input can still react to events such as a resize.
- Queries the terminal window size, reporting absence rather than a fabricated default when
  unavailable.
- A terminal resize is delivered as an event that wakes an idle event loop; the prior signal
  handling is restored on exit.
- Escape-sequence support for synchronized-output bursts, bracketed-paste framing, cursor show/hide,
  erase-below, full screen-and-scrollback reset, and relative cursor motion (up/down/forward).

### Inline rendering

- Renders a bounded window of the newest content into the normal screen buffer, never the alternate
  screen.
- Diffs frames by stable content-anchor identity rather than screen position, so scrolled content
  reconciles correctly.
- Incremental forward repaint from the first changed row, scrolling settled rows into the terminal's
  native scrollback.
- Falls back to a single-page reprint or a full reset (clear screen and scrollback) when an
  incremental repaint cannot express the change: a change above the viewport, a resize, a page-count
  change, a shrunk tail, or no shared anchor.
- Repaints only the caret when rows are unchanged, and emits cursor show/hide only when visibility
  changes.
- Steady-state repaints allocate nothing.
- Wraps every repaint in a synchronized-output burst to prevent tearing.
- Keeps runtime terminal text — including user, model, tool, OAuth URL, and credential-path values —
  inert: newline remains a layout break, tab becomes one space, and terminal controls, malformed
  UTF-8, or a glyph wider than the whole terminal become visible replacement characters; trusted
  application SGR styling and renderer controls use separate channels.
- A line wider than the terminal never desyncs the cursor.

### Input decoding

- Incremental parsing that retains unconsumed bytes across reads, so a key sequence split across
  chunks still decodes.
- Decodes printable characters, ctrl-letters, Enter, Shift+Enter (newline), Escape, Backspace,
  arrows, Home, End, and bracketed-paste payloads.
- Decodes both encodings the terminal produces: the keys the Kitty protocol reports as unambiguous
  escape sequences (Escape, Shift+Enter, and ctrl-combinations, with modifiers), and the traditional
  encoding used for the rest — control bytes (carriage return as Enter, delete/backspace as
  Backspace, control codes as ctrl-letters) and arrow, navigation, and modified-arrow escape
  sequences.
- Alt+Up decodes as a distinct key (used for steering recall); other modifier combinations fall back
  to the bare arrow.
- Malformed or truncated UTF-8 decodes as an unknown key while always making forward progress.

### Grapheme segmentation

- Full extended grapheme cluster segmentation per the Unicode standard (UAX #29): CRLF, Hangul
  syllables, combining/joiner/prepend marks, Indic conjuncts, emoji ZWJ sequences, and
  regional-indicator (flag) pairs.
- Reports each cluster's byte length and display width, and finds the previous cluster boundary.
- Validated against the official Unicode grapheme-break conformance corpus.
- Malformed UTF-8 falls back to a one-column replacement step.

### Display width

- Measures inert text by the same canonical representation emitted to the terminal, so wrapping,
  truncation, caret placement, and output agree for controls and malformed UTF-8.
- Truncation and wrapping never split a cluster and never let a wide cluster straddle the margin.
- Counts physical rows for wrapped text and maps between a text offset and its (row, column)
  position in both directions.
- Printable cell widths: 0 for combining marks, 2 for East Asian wide/fullwidth and default-emoji
  characters (the emoji-presentation selector VS16 forces 2, the text selector VS15 keeps 1), 1
  otherwise.

### Unicode data

- Display-width and grapheme-break classification tables derived from the Unicode Character Database
  (pinned to version 17.0.0), including Indic conjunct-break and extended-pictographic refinements.
- Regenerated on demand from the published Unicode data (a manual, network-fetching step).

---

## Agent & conversation

### Agent loop

- Runs one user turn to completion: append the user message, stream the reply, run its tools, feed
  results back, and repeat until the model stops.
- Tool calls within one assistant message run concurrently: read-only calls in parallel, while
  mutating calls (write, edit) run serially in call order so two edits to the same file cannot race
  or lose an update. Results are collected in call order so each maps back to its call, and a
  mid-turn cancel propagates to running tools.
- Bounded tool-round loop (at most 50 rounds), failing cleanly on overrun.
- Holds the conversation history and reaches the model through a provider-neutral interface, so
  neither the loop nor its tools depend on a specific provider.
- Emits presentation events (text, reasoning, tool start, tool result, usage, error) for the
  presentation layer to render.
- Coalesces each streamed reasoning run into one entry — its text plus a verbatim opaque token, or a
  redacted payload — kept in stream order ahead of the text and tool calls that followed it, so a
  turn preserves reasoning interleaved with its tool calls; each entry is replayed unchanged in
  every later request so the provider still accepts those tool calls.
- Switches the active account, model, and reasoning-effort level mid-session; the change takes effect
  on the next turn and leaves history untouched.
- Messages queued during a turn are drained at each tool-round boundary (and when the model would
  otherwise end the turn), combined into one blank-line-joined user turn, appended to history, and
  reported to the presentation layer.
- Retries an entire request on a timeout, transient network fault, premature stream end, or
  retryable status (408, 429, 5xx, including Anthropic's 529), honoring the server's retry-after
  hint, with bounded attempts and exponential backoff. A reply commits only at its provider's
  terminal event; a failed attempt's partial text and tool calls are discarded, the presentation
  layer clears partial text before retrying, and tools execute only after a committed reply.
- On a stream failure or API error, discards the turn's items so history returns to where the turn
  began.
- A mid-turn cancel surfaces as a clean abort (the partial assistant message is dropped), not a
  network error.
- Accumulates cost and cache savings, pricing each message against the model that produced it so a
  mid-session model switch stays correctly priced; keeps a bounded per-model breakdown (cumulative
  totals stay exact past the bound) and the last request's usage.

### Conversation model

- The conversation is a flat, ordered sequence of items: user and assistant messages, reasoning
  runs, tool calls, and tool results.
- A reasoning run records the account that produced its opaque token; only that exact account
  replays it, so any account switch — even between two billing products of one vendor — drops the
  reasoning it did not itself produce, and an assistant turn left with nothing replayable is omitted
  rather than sent as an empty message.
- A provider-neutral interface every provider implements, producing a common stream of reply events
  (text, reasoning and its opaque token, redacted reasoning, tool-call starts, tool-argument chunks,
  completion) with usage-so-far readable mid-stream; each provider translates the item sequence to
  and from its own wire format, so nothing above depends on a specific provider.
- Implemented providers: Anthropic and OpenAI.

### Model catalog & reasoning effort

- Built-in model catalog: Anthropic `claude-opus-4-8`, `claude-sonnet-5`, and `claude-sonnet-4-6`
  (1,000,000-token context) and OpenAI `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`
  (1,050,000-token fallback context) — each with prices, maximum output tokens (128,000, with the
  effort level governing actual spend), and a reasoning-effort map.
- An authenticated OpenAI subscription refreshes its account-aware model context windows after
  login and on every startup; valid known-model limits replace only that account's fallback window,
  while request/schema failures and each missing or invalid model value retain compiled defaults.
- Reasoning-effort levels `none` / `low` / `medium` / `high` / `xhigh` / `max`, each mapping to what
  a given model supports: a level a model lacks folds to the nearest it offers (`claude-sonnet-4-6`
  folds `xhigh` to `high`), a model without reasoning maps every level to none, and a model that
  cannot disable reasoning raises `none` to its minimum.
- Cost and cache savings computed per model from its USD-per-million-token rates; an unknown model
  is rejected, not guessed.

### Networking policy

- Provider-neutral policy with configurable request timeouts and retry parameters.
- An operation that exceeds its timeout fails with a timeout error.
- A shared idle window bounds a run of reads: activity without progress cannot extend it, so a
  stalled read eventually times out.

### Anthropic transport

- Builds each request by grouping conversation items into alternating user and assistant messages:
  consecutive same-role items merge into one message (a tool result counts as user), each item maps
  to one content block in order, and reasoning stays first, never reordered or merged — so the
  serialized prefix stays byte-stable and server-side prompt-cache hits persist.
- Streams responses over SSE, decoding them into the neutral reply events plus usage, stop reason,
  and API errors; only the final `message_stop` completes a reply, after the preceding
  `message_delta` supplies its cumulative usage and stop reason.
- When reasoning is enabled, requests adaptive, summarized extended thinking at the resolved effort
  level so the model sizes its own budget while the output ceiling stays fixed; omitted when effort
  is none, the model has no reasoning, or the model is unknown.
- Forks by account: the subscription path adds the Claude Code identity (a leading system block and
  OAuth identity headers) and authorizes with a Bearer token; the API-key path omits both and
  authorizes with `x-api-key`. Both request an unencoded response so SSE frames arrive verbatim.
- Always-on prompt caching: cache breakpoints on the last system block, the last tool, and the last
  message block (3 of the 4 allowed).
- Usage from all streamed events is folded into one total.
- Each request phase is time-bounded: connecting and reading the response head by a connect timeout,
  and each streamed event by an idle window. Keepalive pings draw the idle window down without
  resetting it — only a real frame restarts it — so a stream that stalls or emits nothing but pings
  still times out. A failed response head reports whether it is retryable and the server's
  retry-after hint.
- A cancel during the read surfaces as a clean abort, distinct from a timeout.

### OpenAI transport

- Builds each request for the Responses API from the same conversation items, sending each item as
  its own input entry (never merged), with the system prompt as instructions and the tools as
  function tools.
- Streams responses over SSE, decoding them into the neutral reply events plus usage and stop
  reason; `response.completed` and `response.incomplete` are authoritative terminal events, usage
  is folded when their response object supplies it, and an optional `[DONE]` compatibility sentinel
  only ends the byte stream.
- When reasoning is enabled, requests a summarized reasoning stream at the resolved effort level and
  round-trips each reasoning item's encrypted payload and id verbatim so later turns replay it; no
  server-side conversation state is retained between requests.
- Relies on OpenAI's automatic server-side prompt caching (no per-block cache markers) and sends a
  stable per-conversation cache key so a session's growing requests route to one cache.
- Partitions the prompt token count into cache-read, cache-write, and uncached buckets, so each
  token is billed once at its bucket's rate.
- Authorized with a platform API key (Bearer).

### Authentication

- Two authentication mechanisms per provider: an interactive subscription OAuth login (at startup
  and mid-session), and a platform API key read from the environment (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`).
- Subscription credentials stored at `~/.pith/auth.json` with owner-only permissions, keyed by
  account so several coexist in one file; a token refresh rewrites only its own account's entry, and
  a save aborts rather than discarding the file's other accounts when it cannot be read back.
- OAuth login: PKCE (S256), a loopback callback listener ready before browser launch, and a
  best-effort launcher whose lifetime never blocks the callback; unavailable launchers warn while
  the printed URL remains usable for manual authorization. Callback acceptance and its first HTTP
  request line share a five-minute deadline; the request line is limited to 8 KiB including its
  newline, and timeout, oversize, or cancellation closes callback resources cleanly.
- Access tokens refreshed and re-persisted automatically when expired. Token exchange and refresh
  are bounded by the shared connect timeout and cap the response body at 256 KiB, so a stalled or
  oversized provider response cannot block or allocate without bound; a failed refresh leaves the
  stored credential intact.
- At startup the active account is the first authenticated one — a stored subscription or an
  available API key, preferring a subscription over a paid key when both are present; when none is
  available, the session starts signed out and the login picker opens.
- While signed out — no authenticated account, or after logging out the last one — the status line
  reads "not signed in" and a normal message is refused with a prompt to `/login`, while the login
  picker (the same one `/login` opens) lets the user sign in without a restart.

### Tools

- A tool registry advertises each tool's input schema, validates arguments against it, and marks
  whether the tool mutates the filesystem; every tool honors cancellation.
- **read** — paginated UTF-8 file read (1-indexed offset, with a line limit), truncated to 2000
  lines or 50 KB with a next-offset hint; rejects binary or oversized (over 16 MB) files.
- **write** — create or overwrite a UTF-8 file atomically.
- **edit** — replace one exact, unique text span; errors on an empty, missing, or non-unique match;
  written atomically.
- **find** — glob file search returning relative paths under a base path, bounded by a result limit
  (default 1000).
- **grep** — literal substring search reporting `path:line:text`, with a glob filter, optional
  case-insensitivity, and a result limit (default 100); skips binary and large (over 4 MB) files and
  caps reported line length (300 bytes).
- Glob patterns support `*`, `?`, and `**`; file searches walk directories recursively in sorted
  order and skip noise directories (version-control and build directories).

### Slash commands

- Slash commands dispatch to produce either feedback text or an interactive picker; an unknown
  command reports an error.
- **/model** — open a picker over every account-qualified model the session is authenticated for
  (each authenticated account's models, labeled by account), with the active one marked; selecting
  one switches the active account and model together.
- **/effort** — open a picker over the reasoning-effort levels with the active one marked.
- **/login** — open a picker over all accounts: an unauthenticated subscription runs its OAuth login
  and switches to it on its default model; an environment API account reports which variable to set
  and to restart; an already-active account is marked and does nothing. The same picker opens at
  startup and after logging out the last account.
- **/logout** — open a picker over the logged-in subscription accounts and drop the chosen one's
  credentials; logging out the active account switches to the next authenticated account, or drops
  to a signed-out state with the login picker open.

---

## Application & interface

### Startup & event loop

- Starts on the active account's model — named per account in configuration, or a compiled per-vendor
  default (`claude-opus-4-8` for Anthropic, `gpt-5.6-sol` for OpenAI) — at a fixed reasoning effort
  (`xhigh`), and sends a fixed system prompt describing the agent and its tools.
- On launch, shows an intro line summarizing the key bindings.
- The interface stays responsive throughout a turn: keyboard input, agent progress, frame ticks, and
  resizes are handled concurrently, so network and streaming I/O never freeze the interface.
- Turn progress and completion remain bound to their originating turn, so cancelling and immediately
  starting a successor cannot apply queued output or completion from the cancelled turn.
- Repaints are frame-rate-limited (~16 ms) and scheduled only while the interface is dirty or
  animating, so an idle interface does no work.
- A terminal resize marks the interface dirty and re-reads the size, so even an idle interface
  reflows to the new dimensions.
- Reads an optional configuration file at `~/.pith/config.json` — partial and forward-compatible —
  supplying request timeouts and retry policy (connect and idle timeouts, maximum attempts, and
  initial and maximum backoff) and a default model per account. It holds no secrets; API keys come
  from the environment. A configured model name that is not valid for its account's vendor is
  reported and falls back to the compiled default.
- When no account is authenticated, starts signed out and opens the login picker, so a first run
  signs in through the same interactive picker as a mid-session `/login`.
- Ctrl+C clears the editor, or quits on a second press in quick succession; Ctrl+D quits when the
  editor is empty.
- During a turn, Esc or Ctrl+C cancels it and drops the partial turn, returning any pending steering
  to the editor.
- The editor stays live during a turn: Enter queues a steering message, Alt+Up recalls the whole
  queue into the editor (blank-line-joined, after any in-progress text), and any steering still
  queued when a turn ends starts the next turn. Slash commands are disabled during a turn.
- Graceful shutdown cancels all background work and drains buffered events before restoring the
  terminal.

### Session state & transcript projection

- Rendering is a deterministic function of a state snapshot — transcript history, live-tail mode,
  editor contents, and the current stats, model, and effort — independent of I/O.
- The live tail always holds exactly one live input: the editor — at the idle prompt, or kept
  beneath a streaming turn's spinner, tool boxes, and steering rows so the turn can be steered — or
  a picker that replaces it.
- Streamed answer text accumulates into one growing block until a tool call, a distinct block, or
  the turn boundary ends it.
- Streamed reasoning accumulates into its own dimmed thinking block, kept separate from the answer.
- Multiple concurrent tool calls render as boxes during a turn — blue while running, replaced on
  completion by a green (success) or red (error) line.
- While a turn runs, the steering queue shows as `Steering:` rows with an Alt+Up recall hint; once
  consumed, the batch becomes one normal user block and its rows drop.
- The transcript and tail project onto a bounded window (8 pages), measured newest-first and clipped
  at the top, recomputed each frame.

### Input editor

- Text buffer with a display-unit caret: valid UTF-8 moves by grapheme cluster, while each control
  or malformed-byte replacement remains independently editable; insert, paste, and backspace preserve
  those boundaries.
- Horizontal movement by cluster (left/right) and to line start/end (home/end).
- Vertical movement (up/down) by wrapped row with a sticky goal column preserved across shorter rows
  and reset on any horizontal move or edit.
- Up on the first row jumps to the start, down on the last row jumps to the end.
- A caret at the end of a full-width line wraps onto an empty trailing row rather than clamping onto
  the last cell.
- Internally scrolled and windowed to keep the caret in view, with "↑ N more" / "↓ N more"
  hidden-row labels.

### Picker

- Single-choice list with a title, a key hint, inverse-video selection, and a "(current)" tag on the
  active choice.
- Bounded up/down navigation, internally scrolled to keep the selection visible.
- Dismissed by Esc, Ctrl+C, or Ctrl+D.

### Status line

- Bottom line showing context-window fill, session cost, and cumulative cache savings, with a
  `model • effort` indicator right-aligned.
- Last-request cache-hit rate shown once a request has sent prompt tokens; token counts in k/M
  shorthand.
- Truncates to stats-only when the model and effort will not fit.

### Transcript rendering

- Transcript entry kinds: intro, user, thinking (dimmed), answer, tool result, and feedback (the
  last two can carry error styling).
- Notice, box, and wrapped-text renderers, each drawn from one shared color palette.
- Blocks paint one physical row at a time, so a clipped block never renders its hidden portion.
- A framed input area (colored rules, windowed body, optional caret) shared by the editor and
  picker.
- A ten-frame Braille "Working…" spinner that advances on each frame tick, independent of stream
  events.
- One `Steering: <message>` row per queued message, showing its first line, truncated.
