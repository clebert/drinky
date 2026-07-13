# Backlog

Planned features for pith, roughly ordered by dependency. The harness today is intentionally
minimal: a single hardcoded model and system prompt, a fixed set of file/search tools, and a raw
line submitted straight to the agent loop. Everything below builds on that base.

Extension seams referenced here:

- `src/tool/root.zig` — compile-time tool registry + dispatcher.
- `src/tool/Context.zig` — ambient tool state (the intended home for a working dir and a provider
  handle for subagents).
- `src/llm.zig` — provider-neutral data model (roles, blocks, requests, events).
- `src/provider.zig` — provider seam; `Kind` enum + `Client`/`Stream` unions.
- `src/anthropic/wire.zig` — request serializer.
- `src/anthropic/Transport.zig` — HTTP + SSE decode.
- `src/App.zig` — composition root, event loop, key handling, submit path.
- `src/Agent.zig` — the turn/tool-round loop.

## Tools

- [ ] **Bash tool.** Highest-leverage new tool. Add a module exposing `spec` + `run` and one line in
      the `src/tool/root.zig` registry. Needs a working directory (thread through
      `tool/Context.zig`) and a decision on output capture/truncation and timeouts. No sandboxing or
      permission model exists yet — decide whether that gates this or follows.
- [x] **Parallel tool calls.** Anthropic (and most providers) already emit multiple `tool_use`
      blocks in one assistant message when the calls are independent. `Agent.runTools` fans them out
      through an `std.Io.Group` — one concurrent task per call writing into its own slot — then
      collects the results in call order, so each `tool_result` still maps back to its `tool_use`
      id and the UI's name-FIFO box matching is unchanged. Mutating calls (write/edit, flagged in
      the tool registry) instead run inline in call order, so two writes/edits to the same file
      can't race or lose an update within a turn. A mid-turn cancel propagates through `group.await`
      to the running tools, preserving the interrupt-in-flight semantics the old sequential loop
      had. We never send `disable_parallel_tool_use`, so the provider is free to batch independent
      calls.

## Command surface

- [x] **Slash-command parsing.** Lines starting with `/` are intercepted in `App.submit` and routed
      to `command/root.zig` — a registry (name → handler) mirroring the tool registry, with a
      `command.Context` (gpa + `*Agent`) and a `command.Outcome` union (`feedback` text/`is_error`,
      or an interactive `pick` request). `command.run` parses a typed line; `command.apply` runs a
      name + argument directly. Everything below hangs off this.
- [x] **`/model`** — switch the active model at runtime by name, or with no argument open an
      interactive picker (↑/↓, enter, ctrl-c) over the active provider's models with the current one
      marked. `Agent.setModel` is the live-reconfigure seam (takes effect next turn);
      `provider.Client.kind` and `models.list` back the list. A command returns a `command.Outcome`
      (`feedback` or `pick`); the app owns the reusable `tui.Picker` and, on selection, re-applies
      the command with the choice via `command.apply` — so the widget stays generic. Per-message
      cost attribution across a switch is still the open item below.
- [ ] **Slash-command Tab completion.** Complete a partial slash command on Tab: while the line
      starts with `/` and no argument has been typed, match the prefix against the command registry
      and fill in the rest, cycling or listing the candidates when several match. Needs a Tab key
      (`Input` currently decodes it to `ctrl-i`) and a `command.complete(prefix)` seam beside
      `command.apply`; the candidate list can reuse `tui.Picker`.
- [ ] **`/effort`** — set reasoning/effort level, and show it on the status line so the right side
      reads `model • effort` (e.g. `claude-opus-4-8 • xhigh`). Requires an effort field on
      `llm.Request`, per-provider mapping (Anthropic thinking budget, OpenAI reasoning effort), and
      threading `effort` into `tui.status.Info`. The per-model level→provider-value mapping (a
      thinking-level map) belongs in `models.zig` alongside price and context window.
- [ ] **`/cache-ttl`** — toggle the Anthropic cache write TTL between 5-minute (default) and 1-hour,
      gated on provider support. Threads a TTL choice into `wire.zig`'s `cache_control`
      (`{"type":"ephemeral","ttl":"1h"}`) and into the cost model: the 1-hour write premium is 2x
      base input vs 1.25x for 5-minute, so `models.zig` needs a per-TTL write rate (a
      `cache_write_1h` alongside the current 5-minute `cache_write`). A uniform TTL across
      breakpoints sidesteps the "1h-before-5min ordering" rule. Payoff is narrow: 1-hour only helps
      a prefix reused after the 5-minute window but within the hour; otherwise it is a 2x write tax.
- [ ] **`/handoff`** — summarize/compact the current conversation and start fresh with the summary
      carried over, to reclaim context.
- [ ] **`/subagent`** (or `/agents`) — list, pick, and dispatch to a user-defined subagent. Depends
      on the subagent runtime below.

## Configuration & context

- [ ] **Custom system prompt.** Replace the hardcoded string in `App.zig` with a loaded one; allow
      user override via a config file or path.
- [ ] **AGENTS.md / CLAUDE.md loading.** Discover and prepend project instructions from the working
      directory (and parents) into the system prompt or a leading context block.
- [ ] **Custom prompts.** User-maintained prompt templates, invokable (likely as slash commands)
      with argument substitution.
- [ ] **Skills (global + local).** On-demand instruction files. Advertise available skills (name +
      description) to the model and load a skill's body when triggered. Resolve global (user-level)
      and local (project) skill directories.
- [ ] **Subagents.** User-maintained agent definitions — each its own prompt and allowed-tools set.
      Needs: a nested agent loop reachable from a tool/command, agent definitions loaded from disk,
      per-agent tool allowlists enforced in dispatch, and a provider handle exposed via
      `tool/Context.zig` (already anticipated there). Backs `/subagent`.

## Providers & efficiency

- [x] **Prompt caching.** Always-on for Anthropic and model-independent: `wire.zig` places
      `cache_control` breakpoints on the last system block, the last tool, and the last block of the
      last message (3 of the 4 allowed), so the stable prefix and the growing history are cached
      each turn. Anthropic applies its own per-model minimum-prefix rules server side.
- [x] **Usage & cost stats.** `Transport` folds `message_start` / `message_delta` usage into
      `llm.Usage`, carried on the `stop` event; `Agent.Stats` accumulates tokens and cost (priced by
      `models.zig`), and the `tui.status` line shows context fill, the last request's cache hit
      rate, session cost, and cumulative cache savings.
- [ ] **Per-message cost attribution.** Cost and savings are priced with the session's single
      current model, so a mid-session `/model` switch misprices earlier turns (a switch is a
      one-turn cache rewrite that blends both models' rates). Record each assistant message's usage
      against the model that produced it — carry the model or its rates with the usage — so
      cumulative figures stay correct across a switch.
- [ ] **Per-turn / `/session` breakdown.** Accounting is cumulative plus last-request only. Keep a
      per-turn record and add a `/session` summary (tokens, cost, cache savings, split by model).
      Re-adds the cumulative token totals recently trimmed from `Agent.Stats`.
- [ ] **Runtime model catalog.** `models.zig` is a compiled-in table namespaced by provider
      (`get(kind, name)`) carrying price, context window, and max output tokens per model, with no
      fallback — an unknown model is unsupported. Load an optional `$HOME/.pith/models.json`,
      structured by provider (`{ "anthropic": { "claude-opus-4-8": { … } } }`), to override or
      extend the compiled defaults so users control pricing, context windows, output caps, and (with
      `/effort`) thinking-level maps without a rebuild. Compiled defaults stay authoritative, so a
      known model always has a known window; the file only patches or adds. Ties into `/cache-ttl`
      (per-TTL write rates) and the `/model` / `/effort` commands.
- [ ] **Other providers (OpenAI, …).** Add a `Kind` arm in `provider.zig` and an `openai/` module
      (wire + transport) mirroring `anthropic/`. Everything above `provider.zig` is already
      provider-agnostic. Reconciles with `/model`, `/effort`, caching, and stats.

## Networking & resilience

- [ ] **Request timeouts.** Nothing bounds a request today; a stalled connect, send, or read hangs
      the turn indefinitely. Bound each phase (connect / send / idle-read) in
      `anthropic/Transport.zig` with sensible defaults, surfaced as a typed error the retry and
      cancellation paths can act on.
- [ ] **SSE keep-alive / stall handling.** Anthropic streams periodic `ping` events; a hiccup can
      stall the byte stream without closing it. Port the ping/keep-alive workaround used for `pi` in
      our container (recover the exact behavior from that setup) — at minimum treat a ping gap
      longer than an idle bound as a stall so the timeout/retry path engages. `Transport.next`
      currently skips ping events silently.
- [ ] **Request retries.** Retry a failed request — timeout, stall, network error, or retryable HTTP
      status (429 / 5xx) — with bounded attempts and backoff (honor `retry-after` when present).
      Only whole requests are safe to retry, so a partially streamed assistant message must be
      discarded first. Sits above `Transport` (in `provider` / `Agent`) so it stays
      provider-neutral.
- [x] **Networking off the UI thread.** The event loop is a single `std.Io.Queue(UiEvent)` consumer
      fed by `io.concurrent` producers — a long-lived stdin reader, the turn worker (`agent.run` off
      the UI thread), and a one-shot frame timer. The consumer solely owns the model and paints, so
      request/stream I/O no longer freezes the UI. This unblocked mid-stream cancellation and a live
      progress indicator; concurrent tool execution stays future work (tools still run inline on the
      worker between rounds).
- [x] **Streaming cancellation.** Ctrl-c/esc mid-turn cancels the turn worker's `Future`; the cancel
      interrupts the blocking read, `Transport.next` maps it to `error.Canceled` via
      `connection.getReadError()`, and `Agent.run`'s `errdefer` shrinks `messages` back to the
      turn's base — dropping the partial assistant message and leaving a valid alternation. Tools
      propagate `error.Canceled` too, and mutating tools write atomically so a cancelled write can't
      truncate the target.

## UI

- [x] **Accurate display widths (wide glyphs).** The differential `Screen` (renamed from `Surface`)
      counts _physical_ terminal rows for every cursor move: each frame line spans `width.rows` rows
      — the number of pieces `width.wrap` produces, not `ceil(width / columns)`, since a wide
      cluster cannot straddle the margin — and `width.caret` maps a caret's display column to its
      physical row and column within a wrapped line. A single `paint` helper drives every mode
      (first frame, full reset, incremental) so all row arithmetic lives in one place, and
      `viewportTop` and the caret restore both measure physical rows. A line wider than `columns`
      can no longer desync `cursor_row`, so `Screen` is correct independently of the app
      pre-wrapping every line. A model terminal in the test suite replays the exact escapes `Screen`
      emits with real auto-wrap and asserts the reconstructed document and caret, covering the
      wide-line paths byte-level checks cannot express.
- [x] **Grapheme-cluster display widths.** `width.ofText`/`truncate`/`wrap` measure per UAX #29
      grapheme cluster via the `grapheme` module, so a glyph built from several code points — an
      emoji variation selector (`❤️`), a skin-tone modifier (`👍🏽`), a ZWJ sequence (`👨‍👩‍👧‍👦`), a
      regional-indicator flag — takes the single cell a mode-2027 terminal draws, and
      `truncate`/`wrap` never split a cluster. Mode-2027 runtimes only: on a per-codepoint terminal
      a cluster under-fills its row (safe) rather than overflowing, so there is no dual path.

      `zig build unicode` (`scripts/generate_unicode_data.zig`) derives two tables from the Unicode
      Character Database (pinned to 17.0.0) into `lib/terminal/unicode_data.zig`: the display-width
      intervals and the Grapheme_Cluster_Break class table, refined with Indic_Conjunct_Break (for
      rule GB9c) and Extended_Pictographic (for GB11). `grapheme.stepAt` implements the full GB1–GB13
      rule set and is verified against the vendored `GraphemeBreakTest.txt` conformance corpus.

- [x] **Grapheme-cluster caret movement.** `Editor` moves the caret and backspaces by grapheme
      cluster, matching the grapheme-cluster measurement rendering already uses (`terminal.width` +
      `grapheme`). `grapheme.stepAt` is forward-only and needs a known cluster start, and UAX #29
      breaking depends on preceding context, so backward movement re-segments forward from the start
      of `text` rather than scanning backward byte by byte: `grapheme.boundaryBefore` sits beside
      `stepAt` and backs `Editor.previousBoundary`, while `stepFrom` advances one cluster via
      `stepAt`. `moveLeft`/`moveRight`/`backspace` step by whole cluster — a combining mark, a ZWJ
      emoji (`👨‍👩‍👧‍👦`), a regional-indicator flag, a skin-tone modifier, a keycap — so the caret can no
      longer land inside a cluster and a backspace deletes the whole glyph, and `insert` advances the
      caret past any cluster its text fuses into. Editing and movement now keep the caret on cluster
      boundaries, so `width.caret`'s precondition tightened from codepoint to grapheme cluster.

- [x] **Sticky goal column for vertical caret movement.** `Editor` carries an optional
      `goal_column`: the first `moveUp`/`moveDown` of a run captures the caret's display column into
      it, and every subsequent vertical step targets that column via `terminal.width.offsetAt`
      instead of the live one. A row shorter than the goal clamps the caret for display without
      overwriting the goal, so a later step onto a wider row restores the column — the way most
      editors behave. Any horizontal move or edit (`moveLeft`/`moveRight`/`moveHome`/`moveEnd`/
      `insert`/`backspace`/`clear`) resets the goal to null so the next vertical run recaptures it. A
      vertical move off the top or bottom row falls back to `moveHome`/`moveEnd`, so pressing up on
      the first row jumps to the start and down on the last row jumps to the end.

- [x] **Extract block rendering into a `ui` widget + shared color namespace.** Block rendering moved
      out of `src/App.zig` into two `ui` modules, and the SGR palette into a third. `ui/color.zig` is
      the one palette `App`, `paint`, `Picker`, `separator`, and `status` share. `ui/paint.zig` holds
      the row-painting primitives (`Placement`, `BoxStyle`, `box`/`notice`/`wrapped`/`spinner`/`row`,
      plus `boxRows`/`spinnerStep`), which stream one row at a time into the view sink — the
      streaming `Placement` contract, deliberately *not* the `render(columns, …, buffer, lines)`
      contract `Editor`/`Picker` use, so a clipped block never materializes its hidden top.
      `ui/block.zig` is the transcript-block model (`Entry`, below), measuring and painting itself
      via `paint`. App shrank to state + event loop + orchestration + agent glue + the
      projection/layout pass, and the block renderers are now unit-tested in `block.zig`.
- [x] **Make `App.Entry` a `union(Kind)`.** `Entry` (now in `ui/block.zig`) is a tagged union: the
      `intro`/`user`/`model` blocks carry a byte buffer, `tool_result`/`feedback` a buffer plus an
      `is_error` flag (`Flagged`). Each variant carries exactly its data — the `is_error` that was
      dead for the plain blocks is gone — and `rows`/`render`/`deinit` switch on it exhaustively.
      `Entry.init` owns the single kind→variant mapping. Stateful blocks (a collapsible `thinking`
      run, a tool box tracking its own status) now have somewhere to live.
- [ ] **Richer UI with dedicated components.** Move beyond the current log + single-line editor to
      composable components (tool-call panels, streaming status, a stats/context footer, a model/
      effort indicator, command palette). Keep the line/string render model. `tui.Picker` (the
      `/model` chooser) is the first such component: a single-choice list rendered into the live
      region, reusable by any command that returns a `pick` outcome.
- [ ] **Display model thinking.** Show the model's reasoning/thinking stream in the transcript,
      visually distinct (dimmed) from the answer. Nothing decodes or renders it today: `llm.Block`
      has only `text`/`tool_use`/`tool_result` and `llm.Event` only `text`/`tool_use`/`input_json`/
      `stop`. Needs thinking-delta decode in `anthropic/wire.zig`, a thinking variant on `llm.Block`
      and `llm.Event`, an `Agent.consume` branch, and an `App` handler/render path (a dimmed run,
      separate from the answer text). Ties into `/effort`, which turns thinking on and sets its
      budget.
- [ ] **Steering.** Let the user type and send while a turn is running, queuing messages the way pi
      does. Today the read loop is frozen for the whole blocking `agent.run()`, so the input box is
      visible but inert. Depends on the off-thread networking work ("Networking off the UI thread"):
      once stream I/O runs on its own thread, the event loop can keep reading keys, append submitted
      lines to a pending-message queue, and feed them into the current or next turn.
- [x] **Smooth spinner animation.** The `⠋ Working…` spinner is driven by the frame timer: while a
      turn animates the consumer re-arms a tick each frame and `advanceFrame` steps the spinner even
      when the model is clean, so it animates independently of stream events and no longer freezes
      during the pre-first-token wait. Covered by the "a tick repaints and steps the spinner while a
      turn animates" regression test.
- [x] **Extract the render consumer into a `Session` struct.** `src/Session.zig` owns the
      consumer-side model and rendering — `Transcript`, live-tail `mode`, `editor`, `view`, the last
      laid-out dimensions, and displayed stats/model — plus the event-appliers (`applyStreamEvent`)
      and `paint`, io-/tty-/agent-free so the render loop has an isolated test surface built from a
      real `Session.init` rather than a partially-initialized `App`. `App` keeps the io/tasks/tty/
      agent wiring, the consumer loop, and the key/command/turn orchestration (which triggers io/
      agent inline), driving the `Session` through its methods; key decoding (`input`) stays with
      that orchestration in `App`.
- [ ] **Signal-driven resize.** React to terminal resizes via `SIGWINCH` rather than polling.
      Depends on the off-thread networking work: once the event loop is a channel consumer, a
      resize must arrive as a `UiEvent`, but a POSIX signal handler is async-signal-safe only and
      cannot take the channel lock to enqueue one — so this needs a signal-to-event bridge (a
      dedicated task awaiting the signal through an io primitive, or a self-pipe). Interim behavior
      is a `Tty.size()` check folded onto the frame tick while non-idle, which misses a resize that
      happens while the interface is fully idle until the next event.
- [ ] **Context-window pressure signal.** The status line shows `ctx%` but nothing reacts to it.
      Warn as context fills (e.g. color the gauge past a threshold) and wire a threshold into
      `/handoff` compaction. Thresholds configurable with good defaults. Two model-specific
      dimensions to fold in: tiered pricing (some models cost more above a context threshold — needs
      tiered rates in `models.zig`, cf. pi's per-model `tiers`) and the degradation of output
      quality as context fills. Evidence-based numbers for the latter are unlikely, so expose it as
      a configurable soft warning rather than a hardcoded rule — an idea to revisit.

## Cross-cutting / open questions

- [ ] **Permission model.** No allow/deny concept exists. Bash, subagent tool allowlists, and
      write/edit gating all want a shared answer here.
- [ ] **Config file.** Several items above (system prompt, model/effort defaults, provider keys,
      skill/agent/prompt directories) imply a single config source. Decide format and location.
