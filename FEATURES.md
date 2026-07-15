# FEATURES.md

An inventory of what pith supports today — one line per capability, grouped by module. This is not a
design doc: it records _what exists_ and may state the guarantee a capability upholds (the thing a
regression check asserts), but not the implementation rationale — for the _why_ and the _how_ see
the commit history, `BACKLOG.md` (planned work), and `docs/`.

## How to use this file

- **Adding a feature.** When you land a new capability, add a one-line entry under the right group
  (create a group if none fits). Keep it terse — a line, not a paragraph. Mark the matching
  `BACKLOG.md` item done in the same change, if one exists.
- **Refactoring.** Before and after a refactor, read the relevant group and confirm every listed
  capability still holds. This list is the checklist against which a refactor must not regress: if a
  behavior here disappears, that is a bug, not a cleanup.
- **Granularity.** Fine-grained sub-features are welcome (individual caret movements, specific
  escape sequences, per-tool options) when they are worth guarding against regression. Merge or drop
  entries that no longer earn their line.
- **Scope.** Only implemented behavior belongs here, stated as the capability and its guarantee, not
  the rationale. Planned or partial work stays in `BACKLOG.md` until it ships.

Groups mirror the module layout: the terminal engine (`lib/terminal/`), the agent core (`lib/ai/`),
and the app (`src/`).

---

## Terminal engine (`lib/terminal/`)

### TTY & terminal control (`Tty`, `escape`)

- Enters raw mode (no echo/canonical/signals/flow-control) and restores the original termios on
  exit.
- Enables bracketed paste, pushes the Kitty keyboard protocol, and hides the cursor on start;
  reverses all three on exit.
- Buffered stdout writer with split read/write handles so an input reader and the render writer run
  concurrently without a lock.
- Timed reads (returns null on timeout) so the caller can react to resize while otherwise blocked.
- Queries the window size via `TIOCGWINSZ`, reporting null (not a fake default) when unavailable.
- SIGWINCH watcher (`Resize`): a self-pipe turns the async-signal-safe handler into an awaitable fd
  event (blocking read end, non-blocking write end), so a resize wakes an idle event loop; restores
  the prior signal disposition on exit.
- Escape helpers for synchronized-output bursts, bracketed-paste framing, cursor show/hide,
  erase-below, full screen+scrollback reset, and relative cursor motion (CUU/CUD/CUF).

### Reconciling inline renderer (`View`)

- Draws a bounded window of the newest content into the normal buffer (never the alt screen).
- Diffs frames by opaque anchor identity (id + line), not screen position, so scrolled content
  reconciles correctly.
- Incremental forward-slide repaint from the first changed row, scrolling committed rows into native
  scrollback.
- Backward-slide single-page reprint and full reset (clear screen + scrollback) for the cases a
  slide cannot express (change above viewport, resize, page-count change, shrunk tail, no shared
  anchor).
- Caret-only repaint when rows are unchanged; emits cursor show/hide only on a visibility change.
- Double-buffered ping-pong frames with retained capacity, so steady-state repaints allocate
  nothing.
- Every repaint wrapped in a synchronized-output burst to avoid tearing.
- Counts physical terminal rows for wide glyphs so a line wider than the terminal never desyncs the
  cursor.
- A test model terminal (`Emulator`) replays the exact escapes `View` emits and reconstructs the
  document and caret for byte-level rendering assertions.

### Input decoding (`Input`)

- Incremental parser that retains unconsumed bytes across reads, so a key sequence split across
  chunks still decodes.
- Decodes printable codepoints, ctrl-letters, Enter, Shift+Enter (newline), Escape, Backspace,
  arrows, Home, End, and bracketed-paste payloads.
- Legacy control-byte mapping (CR→enter, DEL/BS→backspace, 0x01–0x1a→ctrl, LF→ctrl-j).
- Kitty `CSI u` decoding with modifiers, SS3 arrows, and `CSI ~` tilde keys.
- Plain Alt+Up (legacy modified arrow) decoded as a distinct key for steering recall; other
  modifier combinations fall back to the bare arrow.
- Malformed/truncated UTF-8 decodes as `unknown` while always making forward progress.

### Grapheme segmentation (`grapheme`)

- Full UAX #29 extended grapheme cluster rules GB1–GB13 (CRLF, Hangul,
  Extend/ZWJ/SpacingMark/Prepend, Indic conjunct GB9c, emoji-ZWJ GB11, regional-indicator pairs
  GB12/13).
- `stepAt` returns a cluster's byte length and display width; `boundaryBefore` finds the previous
  cluster boundary by forward re-segmentation.
- Validated against the vendored `GraphemeBreakTest.txt` conformance corpus.
- Malformed UTF-8 falls back to a one-column replacement step.

### Display width (`width`)

- Per-grapheme-cluster column measurement (`ofText`) that skips ANSI escape sequences.
- `truncate` and `wrap`/`wrapper` never split a cluster and never let a wide cluster straddle the
  margin.
- `rows` counts physical rows for wrapped text; `caret` maps a prefix to (row, column) and
  `offsetAt` inverts it.
- Cell widths follow mode-2027 semantics: 0 for control/combining, 2 for East Asian wide/fullwidth
  and default-emoji (VS16 forces 2), 1 otherwise.
- `escapeLength` measures CSI and string-terminated OSC/APC/DCS/PM/SOS as zero width.

### Generated Unicode tables (`unicode_data`)

- Display-width intervals and Grapheme_Cluster_Break class table derived from the Unicode Character
  Database (pinned to 17.0.0), refined with Indic_Conjunct_Break and Extended_Pictographic.
- Regenerated by `zig build unicode` (network fetch, run by hand).

---

## Agent core (`lib/ai/`)

### Agent loop (`Agent`)

- Runs one user turn to completion: append the user message, stream the reply, run its tools, feed
  results back, and repeat until the model stops.
- Tool calls in one assistant message run concurrently: read-only calls are fanned out through an
  `std.Io.Group`, while mutating calls (write/edit) run serially in call order so two writes/edits
  to the same file can't race or lose an update. Results are queued in call order so each
  `tool_result` maps back to its `tool_use` id, and a mid-turn cancel propagates to the running
  tools.
- Bounded tool-round loop (max 50) with a typed error on overrun.
- Owns the conversation history and an arena; provider-neutral via a `provider.Client` handle.
- Reports presentation through handler callbacks (text, thinking, tool start, tool result, usage,
  error) instead of drawing itself.
- Buffers a streamed reasoning run into a `thinking` block (text + verbatim signature, or a redacted
  payload) at the head of the assistant message, carried back unchanged on later turns so the
  provider accepts the tool calls that followed it.
- `setModel`/`setEffort` switch the active model and reasoning-effort level mid-session, taking
  effect next turn with history untouched.
- Steering: a thread-safe queue (`Steering`, `std.Io.Mutex`) the UI thread pushes onto and the turn
  worker drains at each round boundary (and when the model would end the turn), combining the pending
  messages into one blank-line-joined user message folded into the trailing user turn so alternation
  stays valid, reported via `handler.onSteering`.
- Retries a whole request on a timeout, transient network fault, or retryable status
  (408/429/5xx incl. Anthropic 529), honoring `retry-after`, with bounded attempts and exponential
  backoff; the partial reply of a failed attempt is discarded (never appended to history) and
  `handler.onStreamReset` clears the partial transcript text before the next attempt re-streams.
  Tool execution runs after the retried read and is never retried.
- On a stream failure or API error, rolls history back to the turn base so the user/assistant
  alternation stays valid.
- A mid-turn cancel is surfaced as a clean abort (partial assistant message dropped), not a network
  error.
- Accumulates cost and cache savings, pricing each message against the model that produced it (so a
  mid-session `/model` switch stays correctly priced) with a per-model breakdown, and carries the
  last request's usage.

### Provider-neutral model (`llm`, `provider`, `models`)

- Pure data model of roles, reasoning-effort levels, blocks (thinking/text/tool_use/tool_result),
  messages, tools, requests, usage, and stream events (text, thinking deltas, thinking signatures,
  redacted reasoning, tool_use, input-json, stop).
- Provider seam (`llm.Provider` enum, `Client`/`Stream` unions) with an Anthropic arm wired.
- Compiled-in model table (Anthropic `claude-opus-4-8`, `claude-sonnet-5`, `claude-sonnet-4-6`)
  carrying per-model prices, context window, maximum output tokens (sent in full as `max_tokens`,
  the effort level governing actual spend), and a reasoning-effort map.
- Per-model reasoning-effort map: each of our levels (`off`/`low`/`medium`/`high`/`xhigh`/`max`)
  resolves to the provider effort name the model accepts, or none. A level a model lacks folds onto
  the nearest it offers (Sonnet 4.6 maps `xhigh`→`high`); a model with no reasoning maps every level
  to none; a model that cannot disable reasoning maps `off` up to a floor.
- Per-model cost and cache-savings computation from USD-per-million rates; an unknown model is
  unsupported rather than guessed.
- Neutral networking policy (`net`): request `Timeouts`/`Retry` option structs (defaults live here),
  `withTimeout`, which bounds a blocking operation by racing it against a timer via `std.Io.Select`
  and reaping the loser (surfacing `error.Timeout`), and `Deadline`, a shared idle window that bounds
  a run of reads by the time left until one instant so activity without progress can't extend it.

### Anthropic transport (`anthropic/`)

- Streaming Messages API over SSE, decoding text deltas, thinking deltas and signatures, redacted
  reasoning, tool_use starts, input-json chunks, usage, stop reason, and API errors.
- Adaptive extended thinking: when reasoning is on, sends `thinking:{type:adaptive,
  display:summarized}` plus `output_config:{effort:…}` — the effort resolved through the model's
  effort map — so the model sizes its own budget; `max_tokens` stays the model's output ceiling. Off,
  an unknown model, or a model with no reasoning omits both.
- OAuth identity headers and `accept-encoding: identity` for verbatim SSE.
- Always-on prompt caching: ephemeral breakpoints on the last system block, the last tool, and the
  last message block (3 of 4 allowed).
- Usage folded across `message_start`/`message_delta` into a single `llm.Usage`.
- Request phases are timeout-bounded: `send` (connect + response head) by a connect timeout and the
  read of each streamed event by an idle window (a shared `net.Deadline`). Keepalive `ping` events
  draw the window down without resetting it — only a real frame restarts it — so a stream that stalls
  or sends nothing but pings still surfaces `error.Timeout`. A streamed read races the timer only
  when no full line is buffered; a failed head exposes a retryable classification and the parsed
  `retry-after`.
- A cancel during the read is mapped to a clean `error.Canceled` abort, distinct from a timeout.

### Authentication (`anthropic/Auth`, `oauth`)

- Credentials stored at `~/.pith/auth.json` with 0600 permissions.
- OAuth login: PKCE (S256), browser launch, and a loopback callback server to capture the code.
- Access tokens refreshed and re-persisted automatically when expired.

### Tools (`tool/`)

- Compile-time tool registry + dispatcher advertising typed schemas to the provider; JSON args
  parsed into typed structs with a compile-time schema-vs-struct consistency check. Each entry
  declares whether it mutates the filesystem, which the agent uses to serialize mutating calls
  within a turn.
- **read** — paginated UTF-8 file read (1-indexed offset + limit), truncated to 2000 lines / 50 KB,
  with a next-offset hint; rejects binary/oversized files.
- **write** — create/overwrite a UTF-8 file atomically (temp file + rename).
- **edit** — replace one exact, unique span; errors on empty, missing, or non-unique matches; atomic
  write.
- **find** — glob file search returning relative paths, with a base path and result limit.
- **grep** — literal substring search (`path:line:text`) with glob filter, case-insensitivity, and a
  result limit; skips binary files and caps line length.
- Internal helpers: glob matcher (`*`/`?`/`**`), sorted recursive tree walk skipping noise dirs,
  atomic-write filesystem helper, all propagating cancellation.

### Slash commands (`command/`)

- Registry-based command dispatch returning an outcome (feedback text or an interactive picker);
  unknown commands report an error.
- **/model** — switch model by name, or with no argument open a picker over the provider's models
  with the current one marked.
- **/effort** — set the reasoning-effort level by name, or with no argument open a picker over the
  levels with the current one marked; shown on the status line as `model • effort`.

---

## App (`src/`)

### Composition & event loop (`App`, `main`)

- Single event-queue consumer fed by four concurrent producers: a long-lived stdin reader, the turn
  worker (agent runs off the UI thread), a one-shot frame timer, and a SIGWINCH resize watcher.
- The consumer solely owns the model and painting, so network and stream I/O never freeze the UI.
- Frame-rate-limited repaints (~16 ms); a tick is armed only while dirty or animating, so a fully
  idle interface does no work.
- Repaints on terminal resize (SIGWINCH): the watcher marks the session dirty, so even a fully idle
  interface reflows at the new size; `refresh` re-reads the size each frame.
- Loads `$HOME/.pith/config.json` (`Config`) at startup — optional, partial, and
  forward-compatible — threading request timeouts and retry policy into the client and agent.
- Authenticates (logging in if needed) before wiring the loop.
- Ctrl+C clears the editor or quits on a double-press; Ctrl+D quits when the editor is empty.
- Mid-turn Esc/Ctrl+C cancels the turn worker and drops the partial turn, returning any pending
  steering to the editor.
- Steering: the editor stays live during a turn — Enter queues a steering message, Alt+Up recalls the
  whole queue into the editor (blank-line-joined, appended after any in-progress line), and steering
  left unqueued when a turn ends opens the next turn; slash commands are disabled mid-turn.
- Graceful shutdown cancels and reaps all tasks and drains buffered events before restoring the
  terminal.

### Render consumer (`Session`, `Transcript`, `layout`)

- `Session` owns the consumer-side model (transcript, live-tail mode, editor, view, stats/model/
  effort snapshots) and is io/tty/agent-free for scripted render tests.
- Live-tail modelled as a tagged union (prompt / streaming turn / picker) so exactly one live input
  is representable.
- Streamed model text collects into one growing transcript block until a discrete block, tool call,
  or turn boundary ends the run.
- Streamed reasoning collects into one growing dimmed `thinking` block, separate from the answer, so
  the answer run never extends it.
- Multiple concurrent tool boxes can render during a turn, colored by status: blue while the call
  runs, then replaced by a green (ok) or red (error) transcript line on completion.
- Steering queue shown as `Steering:` tail rows with an Alt+Up recall hint while a turn runs; a
  consumed batch becomes one normal user block and its rows drop.
- Layout projects transcript + tail onto a bounded window (8 pages), measuring newest-to-oldest and
  clipping the top, recomputed each frame.

### Input editor (`ui/Editor`)

- UTF-8 buffer with a grapheme-cluster caret; insert, paste, and backspace all operate on whole
  clusters.
- Horizontal movement by cluster (left/right) and to line start/end (home/end).
- Vertical movement (up/down) by wrapped row with a sticky goal column preserved across shorter rows
  and reset on any horizontal move or edit.
- Up on the first row jumps to start, down on the last row jumps to end.
- Internally scrolled and windowed to keep the caret in view, with "↑ N more" / "↓ N more"
  hidden-row labels.

### Picker (`ui/Picker`)

- Single-choice list with a title, key hint, inverse-video selection, and a "(current)" tag on the
  pre-existing choice.
- Bounded up/down navigation, internally scrolled to keep the selection visible.

### Status line (`ui/status`)

- Bottom line showing context-window fill, session cost, and cumulative cache savings, with the
  `model • effort` indicator right-aligned.
- Last-request cache-hit rate shown when the prompt is non-empty; token counts in k/M shorthand.
- Truncates to stats-only when the model and effort won't fit.

### Transcript blocks & paint primitives (`ui/block`, `ui/paint`, `ui/color`)

- Transcript entries as a tagged union: intro, user, thinking (dimmed), model, tool_result, and
  feedback (the last two flagged for error styling).
- Notice, box, and wrapped renderers, each styled from one shared SGR palette.
- Streaming row painters that emit one physical row at a time into the view sink, so a clipped block
  never materializes its hidden top.
- Framed input area (purple rules + windowed body + optional caret) shared by the editor and picker.
- A ten-frame Braille "Working…" spinner that advances per frame tick, independent of stream events.
- Steering-queue row painter: a `Steering: <message>` row per queued message (first line, truncated)
  plus a dim recall hint.
