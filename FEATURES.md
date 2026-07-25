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
  original terminal state on exit or startup failure. Teardown restores the cooked terminal mode
  before (and independently of) any escape-reset output and applies it immediately, so a wedged,
  flow-controlled, or failing terminal write cannot strand the terminal in raw mode.
- On start, enables bracketed paste, the Kitty keyboard protocol (disambiguate level), and cursor
  hiding; reverses all three on exit and rolls back any partially applied setup.
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
  change, a shrunk tail, an external-output invalidation, or no shared anchor.
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
  arrows, Home, End, and bracketed-paste payloads. Each paste chunk is marked with whether it
  completes the bracketed paste, so one logical paste stays a single unit even when split across
  reads or a flush. An unterminated paste flushes as bounded partial paste payloads (1 MiB) instead
  of buffering without bound — retaining any partial terminator so it never splits across chunks —
  and later bytes stay paste payload until the terminator arrives. An escape sequence whose final
  byte never arrives is
  likewise abandoned as unhandled after 64 retained bytes, so it cannot wedge input.
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
- Tool calls within one assistant message run concurrently: each contiguous run of read-only calls
  executes in parallel, while a mutating call (write, edit) is a barrier -- it waits for all earlier
  reads to finish, runs alone, and completes before any later call begins -- so no mutation overlaps
  a read or another mutation and call order gives a coherent filesystem view. Results are collected
  in call order so each maps back to its call, and a mid-turn cancel propagates to running tools. A
  barrier drains and presents the reads before it ahead of announcing itself, so presentation never
  runs backwards in call order and a mutation cancelled at the barrier is never shown as started.
- Bounded tool-round loop (at most 50 rounds), failing cleanly on overrun.
- Holds the conversation history and reaches the model through a provider-neutral interface, so
  neither the loop nor its tools depend on a specific provider.
- Emits presentation events (text, reasoning, tool start, tool result, usage, error) for the
  presentation layer to render.
- Commits each transport-normalized reasoning completion as one entry — visible text plus a
  replay-proof union for an Anthropic signature/redacted payload or an OpenAI id/encrypted payload —
  kept in stream order ahead of the text and tool calls that followed it. The union is tagged with
  the exact producing account and replayed unchanged only to that account.
- Switches the active account, model, and reasoning-effort level mid-session; the change takes effect
  on the next turn and leaves history untouched.
- Messages queued during a turn are drained at each tool-round boundary (and when the model would
  otherwise end the turn), combined into one blank-line-joined user turn, appended to history, and
  reported to the presentation layer.
- Retries an entire request on a timeout, transient network fault, premature stream end, or
  retryable status (408, 429, 5xx, including Anthropic's 529), honoring the server's retry-after
  hint capped at the maximum backoff, with bounded attempts and exponential backoff. A reply
  commits only at its provider's terminal event; a failed attempt's partial text and tool calls
  are discarded, the presentation layer clears partial text before retrying, and tools execute
  only after a committed reply.
- A reply enters history only after a provider terminal event and validation that it is replayable.
  Transports own their native block/item lifecycles and emit only completed assistant messages,
  reasoning proofs, and tool calls; display deltas never become conversation state. The Agent binds
  each proof to the exact producing account, rejects empty or duplicate call ids, and requires final
  arguments to be empty (an empty object) or a valid top-level JSON object. Call ids need only be
  unique within one reply, which is what makes a reply answerable; a later round may reuse one,
  since it is already paired with its own result. A terminal response is complete or truncated: a
  truncated tool-free reply is retained as an authoritative answer whose cutoff the turn reports, so
  a partial answer never reads as a whole one, while truncation with a tool call and malformed,
  resumable, refused, or unrecognized outcomes reject. A terminal reply carrying no assistant item at
  all is rejected under its own name, so resampling stays worthwhile while the report says the model
  returned nothing rather than blaming the stream. Rejections detected before termination drain the
  bounded stream without retaining further content so terminal usage is counted; retryable cases
  resample within bounded retries, while unsupported outcomes fail the turn without spending retries,
  since resampling cannot turn an unretainable outcome into a retainable one.
- A tool-calling reply commits together with one reserved conservative error result per call before
  any tool is announced or dispatched, so a mutating tool can never change the world with no result
  recorded. Real results replace the reserved slots as calls finish; a cancelled or failed round
  keeps the honest reserved result — flagged as an error and noting side effects may have occurred —
  for any call that produced none.
- A turn is a checkpointed transaction, not one atomic unit: it maintains a replay-valid history
  checkpoint throughout, and every abnormal exit — user cancel, channel close, API error, exhausted
  retries, out-of-memory, an escaping tool error, or the tool-round cap — rolls history back to the
  latest checkpoint, retaining every completed round and its tool results rather than the whole
  turn. Only the in-flight tail beyond the checkpoint is dropped, so a mid-turn cancel is a clean
  abort that keeps the honest record of work already done. Each history item owns its memory, so
  repeated failed, retried, or cancelled turns keep retained memory bounded to the surviving
  history.
- Each turn yields a receipt — the committed history span, how far steering commitment advanced, and
  whether a committed reply was cut short — and a disposition (completed, cancelled, closed, or
  failed), so a caller resolves cancellation from the joined worker state rather than event timing.
- Accumulates cost and cache savings, including terminal usage from billed attempts whose reply is
  rejected by replay validation; prices each terminal attempt against the model that produced it so
  a mid-session model switch stays correctly priced, keeps a bounded per-model breakdown (cumulative
  totals stay exact past the bound), and records the last terminal attempt's usage. Usage reported
  only before cancellation or transport loss reaches a terminal event is excluded from accounting.

### Conversation model

- The conversation is a flat, ordered sequence of items: user and assistant messages, reasoning
  runs, tool calls, and tool results.
- A reasoning run's replay proof is a union tagged by the exact account slot that produced it; any
  account switch drops foreign reasoning, even between billing products of one vendor. Successful
  OAuth credential replacement or logout purges that slot's old proofs before another
  history-bearing request or fallible final presentation, and an assistant turn left with nothing
  replayable is omitted rather than sent empty.
- A provider-neutral interface every provider implements, producing a common stream of display-only
  text/reasoning deltas, completed assistant items in wire order, and a terminal event carrying
  usage, complete-or-truncated status, and any provider-detected invalid/unsupported rejection.
  Usage so far remains readable mid-stream. Provider-native correlation and assembly stay inside
  each transport; the Agent sees only completed messages, proofs, and tool calls and translates them
  into the shared history model.
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
- A shared idle window bounds a run of reads: activity that makes no progress cannot extend it —
  even buffered filler that never blocks a read draws it down — so a stalled or filler-only read
  eventually times out.
- A shared byte budget bounds one streamed response's total size: every line is charged (after
  decompression) across the whole stream, so a peer that makes frequent valid progress — restarting
  the idle window on every frame — still fails with a typed too-large error once it passes a hard
  ceiling (64 MiB, far above any real reply). Not retried, since the same request reproduces it.
- Each SSE line streams into a growable buffer bounded by the budget still remaining, so one frame
  larger than the whole stream may deliver fails with that same typed too-large error before it is
  fully buffered — while a legitimately large single frame (a terminal frame carrying the entire
  response, or a large reasoning blob) is read intact rather than being capped to a fixed reader
  buffer.
- JSON for each SSE frame is parsed in one reusable frame arena reset before the next frame,
  including eventless progress/filler consumed within one read. State that must cross frames remains
  explicitly stream-owned; allocation failure is propagated and leak-checked.

### Anthropic transport

- Builds each request by grouping conversation items into alternating user and assistant messages:
  consecutive same-role items merge into one message (a tool result counts as user), each item maps
  to one content block in order, and reasoning stays first, never reordered or merged — so the
  serialized prefix stays byte-stable and server-side prompt-cache hits persist.
- Streams responses over SSE, decoding them into the neutral reply events plus usage and API errors;
  only the final `message_stop` completes a reply, after the preceding `message_delta` supplies its
  cumulative usage and a stop reason (latched, last non-null writer wins) gating termination. The
  stop reason folds to a complete or truncated status — `end_turn`, `tool_use`, and `stop_sequence`
  complete, while `max_tokens` and `model_context_window_exceeded` truncate — or marks a
  `pause_turn`, `refusal`, or unrecognized outcome unsupported on the terminal event so its usage is
  still counted. One tagged open-block state correlates strictly nonnegative indexes and accumulates
  text, thinking signatures, redacted proofs, or tool arguments across frame resets. Text/thinking
  deltas remain display-only; a matching block stop emits one completed message, replay proof, or
  tool call, while a stop that closes no open block is invalid. Unknown native block types latch
  unsupported through their matching stop instead of silently omitting part of a response.
- When reasoning is enabled, requests adaptive, summarized extended thinking at the resolved effort
  level so the model sizes its own budget while the output ceiling stays fixed; omitted when effort
  is none (which also drops stored reasoning from the request), the model has no reasoning, or the
  model is unknown.
- Forks by account: the subscription path adds the Claude Code identity (a leading system block and
  OAuth identity headers) and authorizes with a Bearer token; the API-key path omits both and
  authorizes with `x-api-key`. Both request an unencoded response so SSE frames arrive verbatim.
- Always-on prompt caching: cache breakpoints on the last system block, the last tool, and the last
  message block (3 of the 4 allowed).
- Usage from all streamed events is folded into one total.
- Each request phase is time-bounded: connecting and reading the response head by a connect timeout,
  and each streamed event by an idle window. Only a recognized frame restarts the window; keepalive
  pings and any other filler (comments, blank lines, or frames the protocol does not define) draw it
  down instead, so a stream that stalls or sends only filler still times out. A failed response head
  reports whether it is retryable and the server's retry-after hint.
- A cancel during the read surfaces as a clean abort, distinct from a timeout.

### OpenAI transport

- Builds each request for the Responses API from the same conversation items, sending each item as
  its own input entry (never merged), with the system prompt as instructions and the tools as
  function tools.
- Streams responses over SSE, decoding display deltas separately from authoritative
  `response.output_item.done` payloads. Done messages, encrypted reasoning proofs, and function
  calls emit completed neutral items; function-argument deltas are progress only. Duplicate done ids
  are invalid, unknown completed item/content types and refusals are unsupported, and a terminal
  `response.output` snapshot — when present — must match the complete done-id set. One native
  message's ordered `output_text` parts join without a separator; separate message items stay
  separate. `response.completed` and `response.incomplete` map to complete/truncated stops, while
  `[DONE]` only closes the byte stream. An incomplete message survives only an incomplete terminal
  response; incomplete reasoning and function calls reject.
- When reasoning is enabled, requests a summarized reasoning stream at the resolved effort level.
  Summary deltas are display-only; the done item supplies the complete summary, required native id,
  and encrypted payload. Summary parts join with a blank line, and the id/payload round-trip
  verbatim on later turns without server-side conversation state.
- Relies on OpenAI's automatic server-side prompt caching (no per-block cache markers) and sends a
  stable per-conversation cache key so a session's growing requests route to one cache.
- Partitions the prompt token count into cache-read, cache-write, and uncached buckets, so each
  token is billed once at its bucket's rate.
- Forks by account: the subscription path targets the ChatGPT (Codex) backend and adds the client
  and account identity headers; the API-key path targets the platform API without them. Both
  authorize with a Bearer token.

### Authentication

- Two authentication mechanisms per provider: an interactive subscription OAuth login (at startup
  and mid-session), and a platform API key read from the environment (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`).
- Subscription credentials stored at `~/.pith/auth.json` with owner-only permissions, keyed by
  account so several coexist in one file; a token refresh rewrites only its own account's entry, and
  a save aborts rather than discarding the file's other accounts when it cannot be read back. Saves
  replace the file atomically, so an interrupted save leaves the previous contents intact. A login
  whose save fails remains authenticated for the process and reports that memory-only outcome only
  after account readiness and replay-proof invalidation are settled.
- OAuth login: PKCE (S256), a loopback callback listener ready before browser launch, and a
  best-effort launcher whose lifetime never blocks the callback; unavailable launchers warn while
  the printed URL remains usable for manual authorization. Callback acceptance and its first HTTP
  request line share a five-minute deadline; the request line is limited to 8 KiB including its
  newline, and timeout, oversize, or cancellation closes callback resources cleanly. Stray
  connections without callback parameters (probes, prefetches) are closed and ignored rather than
  consuming the wait.
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
  lines or 50 KB — even within a single line — with a next-offset hint; rejects binary or
  oversized (over 16 MB) files.
- **write** — create or overwrite a UTF-8 file atomically.
- **edit** — replace one exact, unique text span; errors on an empty, missing, or non-unique match
  and rejects oversized (over 16 MB) files; written atomically.
- **find** — glob file search returning matching paths relative to the working directory, the
  lexicographically-smallest first, bounded by a result limit (default 1000); reports how many more
  matched, and reports honestly when the tree was too large to scan fully.
- **grep** — literal substring search reporting `path:line:text`, with a glob filter, optional
  case-insensitivity, and a result limit (default 100); skips binary and large (over 4 MB) files,
  caps reported line length (300 bytes), reports text as valid UTF-8 (invalid bytes become
  replacement characters), and bounds work by reading at most 256 MB across at most 100,000
  candidate files, reporting honestly when a budget stopped it.
- Glob patterns support `*`, `?`, and `**`; file searches walk directories recursively and skip
  noise directories (version-control and build directories), returning matches sorted by path. The
  walk is bounded independent of tree size: it retains only the smallest matches the caller needs
  rather than the whole tree, and stops after a fixed number of visited entries (1,000,000). An
  unreadable directory is skipped rather than fatal, while cancellation stops the walk at once —
  without traversing the rest of the tree — and every exit releases every open directory handle.

### Slash commands

- Slash commands dispatch to produce either feedback text or an interactive picker; an unknown
  command reports an error.
- **/model** — open a picker over every account-qualified model the session is authenticated for
  (each authenticated account's models, labeled by account), with the active one marked; selecting
  one switches the active account and model together.
- **/effort** — open a picker over the reasoning-effort levels with the active one marked.
- **/login** — open a picker over all accounts: an unauthenticated subscription runs its OAuth login
  and switches to it on its default model; an environment API account reports which variable to set
  and to restart; an authenticated but inactive account switches to it on its default model without
  a login; the active
  account is marked and does nothing. The same picker opens at startup and after logging out the
  last account.
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
- During a turn, Esc or Ctrl+C cancels it, keeping every completed round at the latest checkpoint
  and dropping only the in-flight tail. Cancellation is resolved from the joined worker state, not
  event timing: a worker that already finished is presented as its completion, never a false
  cancellation. The joined future is the sole source of terminal data; after a late cancel its
  result moves to one pending App slot, while the queue carries only a payload-free generation
  fence. App retains that result until the fence has preserved all earlier progress, and if the
  worker's enqueue was interrupted App appends a replacement fence behind the queued prefix. A
  genuine cancel returns uncommitted plain/rich steering to the editor as live placeholder drafts;
  already-committed steering stays in history. It also ends the turn at once, so presentation events
  the worker had queued but the consumer had not yet applied are dropped at the generation gate: a
  round the checkpoint kept can therefore be in history without appearing in the transcript, which
  stays an optimistic event log until transcript rewind lands. A channel that closes under the worker
  ends the turn on the same receipt but reports nothing: teardown is neither a failure nor a
  cancellation to restore from.
- A turn the agent itself failed — a refusal or unrecognized provider outcome, an empty reply, a
  reply that never arrived complete, or the tool-round cap — is reported as a sentence, so ordinary
  model behavior never reads as an internal fault. A provider or API failure keeps the server's own
  message instead, and an unmapped failure still names itself rather than going silent.
- The editor stays live during a turn: Enter queues a steering message, Alt+Up recalls the pending
  queue into the editor as live drafts (blank-line-joined after any in-progress text, each queued
  paste restored as its placeholder marker with its exact payload), and any steering still queued
  when a turn ends starts the next turn. Slash commands are disabled during a turn.
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
  and reset on any horizontal move or edit. The goal column is logical: a paste marker counts as one
  cell however wide its label renders, so up/down never enter a marker and a marker at a line start
  never traps the caret at column zero.
- Up on the first row jumps to the start, down on the last row jumps to the end.
- A caret at the end of a full-width line wraps onto an empty trailing row rather than clamping onto
  the last cell.
- Internally scrolled and windowed to keep the caret in view, with "↑ N more" / "↓ N more"
  hidden-row labels.
- A bracketed paste of more than ten LF-delimited logical lines (one plus its LF-byte count) or more
  than a thousand raw bytes collapses to a compact `[paste #N +L lines]` or `[paste #N B bytes]`
  marker; the line form wins when both thresholds are crossed, while a smaller paste inserts
  literally. The exact payload bytes are kept verbatim with no newline, tab, or control
  normalization, and paste IDs are monotonic and never reused for the editor's lifetime.
- Each marker is one atomic editing unit: left/right cross it in a single step, backspace deletes
  the whole marker, and zero-width guards keep both edges on grapheme boundaries so adjacent
  combining text cannot fuse into it. Marker-looking text typed by the user remains ordinary text.
- A marker label wider than the terminal wraps across rows like ordinary text — unlike a grapheme
  cluster, which never splits — while remaining a single atom for movement and deletion.
- Separate visible and expanded views: rendering and compact rows show marker labels, while every
  semantic submission expands markers before whole-prompt trimming, so a label or edge guard never
  reaches blank checks, commands, the transcript, history, or a provider request. Steering delivers
  that expanded-and-trimmed text, while its rich recall draft trims only surrounding literal text
  and retains whitespace inside an edge paste.

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
