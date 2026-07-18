# Backlog

Planned features for pith, roughly ordered by dependency. Everything below builds on the current
base: a compiled-in model table (`/model` and `/effort` switch the account+model and reasoning
effort at runtime), a hardcoded system prompt, a fixed set of file/search tools, and slash commands
intercepted from the input line before it reaches the agent loop.

Extension seams referenced here:

- `lib/ai/tool/root.zig` — compile-time tool registry + dispatcher.
- `lib/ai/tool/Context.zig` — ambient tool state (the intended home for a working dir and a provider
  handle for subagents).
- `lib/ai/llm.zig` — provider-neutral data model (roles, reasoning-effort levels, blocks incl.
  thinking, requests, events).
- `lib/ai/provider.zig` — provider seam; `Client`/`Stream`/`Credentials` unions keyed by
  `llm.Account` (vendor × billing product), with `llm.Provider` the coarser vendor axis.
- `lib/ai/Accounts.zig` — the account registry: which accounts are authenticated (an env API key or
  a stored subscription) and the client to switch to for one.
- `lib/ai/anthropic/wire.zig` — request serializer.
- `lib/ai/anthropic/Transport.zig` — HTTP + SSE decode.
- `src/App.zig` — composition root, event loop, key handling, submit path.
- `lib/ai/Agent.zig` — the turn/tool-round loop.

## Tools

- [ ] **Bash tool.** Highest-leverage new tool. Add a module exposing `spec` + `run` and one line in
      the `lib/ai/tool/root.zig` registry. Needs a working directory (thread through
      `tool/Context.zig`) and a decision on output capture/truncation and timeouts. No sandboxing or
      permission model exists yet — decide whether that gates this or follows.
- [x] **Parallel tool calls.** Anthropic (and most providers) already emit multiple `tool_use`
      blocks in one assistant message when the calls are independent. `Agent.runTools` fans them out
      through an `std.Io.Group` — one concurrent task per call writing into its own slot — then
      collects the results in call order, so each `tool_result` still maps back to its `tool_use` id
      and the UI's name-FIFO box matching is unchanged. A mutating call (write/edit, flagged in the
      tool registry) is a barrier: it awaits every earlier read, runs alone, and completes before any
      later call, so no mutation overlaps a read or another mutation within a turn. A mid-turn cancel
      propagates through `group.await` to the running tools, preserving the interrupt-in-flight
      semantics the old sequential loop had.
      We never send `disable_parallel_tool_use`, so the provider is free to batch independent calls.

## Command surface

- [x] **Slash-command parsing.** Lines starting with `/` are intercepted in `App.submit` and routed
      to `command/root.zig` — a registry (name → handler) mirroring the tool registry, with a
      `command.Context` (gpa + `*Agent` + `*Accounts`) and a `command.Outcome` union (`feedback`
      text/`is_error`, or an interactive `pick` request). `command.run` parses and dispatches a
      typed line; `command.select` applies a chosen picker row by index. Everything below hangs off
      this.
- [x] **`/model`** — a picker-only chooser (↑/↓, enter, ctrl-c) over every account-qualified model
      the session is authenticated for (each authenticated account's models, labeled by account),
      with the active one marked; there is no typed form, since a model is always chosen together
      with its account. `Agent.switchTo` swaps the client and model together (takes effect next
      turn), the client built from the `Accounts` registry; `Accounts.isAuthenticated` /
      `models.list` back the list. A command returns a `command.Outcome` (`feedback` or `pick`); the app owns the reusable
      `ui.Picker` and, on selection, applies the chosen row index via `command.select`, which
      re-derives the list — so the widget stays generic. Per-message cost attribution across a
      switch is handled below.
- [ ] **Slash-command Tab completion.** Complete a partial slash command on Tab: while the line
      starts with `/` and no argument has been typed, match the prefix against the command registry
      and fill in the rest, cycling or listing the candidates when several match. Needs a Tab key
      (`Input` currently decodes it to `ctrl-i`) and a `command.complete(prefix)` seam beside
      `command.run`; the candidate list can reuse `ui.Picker`.
- [x] **`/effort`** — pick the reasoning-effort level from a picker over the levels with the current
      one marked (picker-only, mirroring `/model`); shown on the status line so the
      right side reads `model • effort` (e.g. `claude-opus-4-8 • xhigh`). `llm.Effort`
      (`none`/`low`/`medium`/`high`/`xhigh`/`max`) is threaded onto `llm.Request` and into
      `ui.status.Info`, with `Agent.setEffort` the live-reconfigure seam (takes effect next turn).
      The per-model level→provider-name mapping is a compiled `EffortMap` in `models.zig` (beside
      price and context window), resolved in `wire.zig` to Anthropic's `output_config.effort`: a
      level a model lacks folds onto the nearest it has (Sonnet 4.6 has no `xhigh`, so it maps to
      `high`), so the default effort works on every model without the user knowing.
- [ ] **`/cache-retention`** — expose the active account/model's prompt-cache retention choices
      rather than assuming providers share one TTL. Anthropic supports `5m` (default) and `1h`
      through each
      breakpoint's `cache_control.ttl`; use one TTL across all breakpoints to sidestep the
      "1h-before-5m ordering" rule. Its 1-hour write premium is 2x base input vs 1.25x for 5-minute,
      so `models.zig` needs a per-TTL write rate (`cache_write_1h` beside the current 5-minute
      `cache_write`). The payoff is narrow: 1-hour only helps a prefix reused after the 5-minute
      window but within the hour; otherwise it is a 2x write tax. OpenAI must be model-gated:
      GPT-5.6+ accepts request-wide `prompt_cache_options.ttl`, but `30m` is currently both its only
      value and its default minimum lifetime, so the built-in OpenAI models offer no actual choice.
      Earlier models use the deprecated `prompt_cache_retention` policy instead of an exact TTL,
      with model-dependent support for `in_memory` and `24h`; `in_memory` usually lasts 5–10 minutes
      of inactivity (at most 1 hour). Where both policies are supported, the omitted-field default
      is `24h` without ZDR and `in_memory` with ZDR. Encode model wire support separately from
      account-level policy, treat these durations as retention guarantees/policies rather than exact
      deletion deadlines, and never guess: when policy is unknown omit the field and report the
      provider default; when only one value is supported report it instead of opening a picker. The
      choice belongs only to the active account/model; `/model` resets it to the omitted provider
      default and reports that transition rather than translating a provider-specific value.
- [ ] **`/handoff`** — summarize/compact the current conversation and start fresh with the summary
      carried over, to reclaim context. Once **Commit partial turns to history on cancel** lands,
      compaction must also summarize cancelled turns and their synthesized "cancelled"
      `tool_result`s, which carry no completed answer.
- [ ] **`/stage`** — stage all changes in git (`git add -A` in the working directory), then let the
      agent know the working tree was staged so its next diff shows only its own new edits. When a
      turn is running this is a steering message (depends on **Steering** under UI); when the agent
      is idle it prefills the input line with the notice instead of sending, leaving the user to
      review and submit. Needs three seams: a way to run git — a subprocess helper shared with the
      **Bash tool** above, none exists yet — the working directory from `tool/Context.zig`, and a
      new `command.Outcome` arm for "prefill the editor" beside the current `feedback`/`pick`
      (routed in `App.submit`). The active-turn path also needs the steering message queue.
- [ ] **`/subagent`** (or `/agents`) — list, pick, and dispatch to a user-defined subagent. Depends
      on the subagent runtime below.
- [x] **`/login` and `/logout`.** Authenticate or drop credentials mid-session without a restart,
      both picker-driven, and the same login picker serves the first-run bootstrap and the
      fall-through after logging out the last account. `/login` lists every account: an
      unauthenticated subscription runs its OAuth flow (an already-listening loopback callback plus
      a best-effort browser launch, with a printed manual fallback) with the app suspending the tty —
      restoring cooked mode so the URL prints and the callback completes — and forcing a full
      repaint after, then switching to it on its
      default model; an environment API account reports which variable to set and to restart; an
      already-active account is marked and does nothing. `/logout` lists the logged-in subscriptions
      and drops the chosen one's `auth.json` entry (an `auth_store` remove that preserves every
      sibling account). `Agent.client` is optional: with no account signed in the session runs signed
      out (status reads "not signed in", a normal message is refused with a `/login` prompt) rather
      than forcing a login, and logging out the active account switches to the next authenticated
      account (enum order, its default model) or drops to that signed-out state with the login picker
      open. A picker cannot open mid-turn, so a logout never races a running turn. This makes an
      `openai_subscription` (Codex) account reachable. Command outcomes gained a `login`/`logout` arm
      the app executes (the command layer names the account; the app owns the tty and the account
      switch), and `firstAuthenticated` backs the fall-through.
- [ ] **API-key login by paste.** Let `/login` accept an API key typed or pasted in-session for an
      API account, rather than only pointing at the environment variable. Departs from today's
      env-only keys: the key would have to be stored (owner-only, likely in `auth.json` beside the
      subscription tokens), so it needs a deliberate on-disk shape and the same abort-rather-than-wipe
      save discipline.
- [ ] **Console/API OAuth (`platform.claude.com`).** Add the Anthropic Console OAuth flow (the
      developer-platform login that mints an API key or platform token) as a `/login` target, if the
      grant is available to this client — a third authentication mechanism beyond subscription OAuth
      and an environment key.

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
      `tool/Context.zig` (already anticipated there). Start with one nesting level: a bounded,
      non-recursive scheduler drives root and child loops from explicit task state rather than
      calling a child `Agent.run` from parent tool dispatch, and a child cannot invoke another
      subagent. Each child propagates usage/cost deltas that the parent folds exactly once, never a
      cumulative snapshot. Failed/cancelled runs contribute whatever usage the provider reported.
      Keep root-agent and subagent cost subtotals so status can show
      `$5.00 (+$2.00)` (root plus all subagents), and include both in aggregate cost, cache savings,
      and per-model totals without replacing the root request's context/cache gauges with a child's
      last usage. Backs `/subagent`.
- [ ] **Persist the active account and model across sessions.** `/model` switches and the startup
      account are session-only, so a restart falls back to the first authenticated account (enum
      order) and its configured/compiled default model. Remember the last-used account+model
      instead. This is mutable, machine-local state that does not belong in `config.json` (meant to
      be shared, e.g. committed across installations), so it wants a separate local state file — and
      a deliberate naming choice for the split (a shared `config` vs. a local `settings`/state
      file), not an ad-hoc second file.
- [ ] **Save and resume conversations.** Persist the durable agent history and conversation-owned
      metadata so a conversation can reopen after restart rather than starting empty. The OpenAI
      `prompt_cache_key` is part of that state: generate it exactly once for a new conversation,
      keep it stable across turns, retries, and account/model switches, serialize it beside the
      history, and restore it verbatim so resuming soon enough with the same OpenAI account and
      unchanged prefix can reuse the provider's cache. Rotate it only when intentionally starting a
      fresh conversation (including `/handoff`); an older save with no key gets a newly generated
      one. A saved provider/billing-product enum is not sufficient provenance for opaque reasoning:
      persist a durable, non-secret provider-principal identity and replay such blocks only when it
      matches, otherwise drop them. This is separate from the machine-local last-account/model
      preference above. Before implementation, define checkpoint timing, the storage location and
      resume-selection UX; the on-disk format must be versioned, atomic, and owner-only.

## Providers & efficiency

- [x] **Prompt caching.** Always-on for Anthropic and model-independent: `wire.zig` places
      `cache_control` breakpoints on the last system block, the last tool, and the last block of the
      last message (3 of the 4 allowed), so the stable prefix and the growing history are cached
      each turn. Anthropic applies its own per-model minimum-prefix rules server side.
- [x] **Usage & cost stats.** `Transport` folds `message_start` / `message_delta` usage into
      `llm.Usage`, carried on the `stop` event; `Agent.Stats` accumulates tokens and cost (priced by
      `models.zig`), and the `ui.status` line shows context fill, the last request's cache hit rate,
      session cost, and cumulative cache savings.
- [x] **Per-message cost attribution.** Each assistant message is priced against the model that
      produced it, not the session's live model: `fetchReply` captures the turn's model and threads
      it through `readReply` to `Agent.recordUsage`, so a mid-session `/model` switch can't reprice
      earlier turns (correctness is by construction, not by the old implicit "`self.model` is still
      the right model at fold time" timing). `Agent.Stats` keeps the running cost/savings plus a
      bounded per-model breakdown (cost, savings, tokens per model) — a plain value type that still
      copies cleanly across the UI channel. The status line is unchanged; the breakdown backs the
      `/session` summary below.
- [ ] **Per-turn / `/session` breakdown.** Accounting is cumulative plus last-request only. Keep a
      per-turn record and add a `/session` summary (tokens, cost, cache savings, split by model).
      Re-adds the cumulative token totals recently trimmed from `Agent.Stats`.
- [ ] **Runtime model catalog.** `models.zig` is a compiled-in table namespaced by provider
      (`get(kind, name)`) carrying price, context window, max output tokens, and a reasoning-effort
      map per model, with no fallback — an unknown model is unsupported. Load an optional
      `$HOME/.pith/models.json`, structured by provider
      (`{ "anthropic": { "claude-opus-4-8": { … } } }`), to override or extend the compiled defaults
      so users control pricing, context windows, output caps, and the per-model reasoning-effort
      maps (today compiled `EffortMap`s) without a rebuild. Compiled defaults stay authoritative, so
      a known model always has a known window; the file only patches or adds. Ties into
      `/cache-retention` (per-TTL write rates) and the `/model` / `/effort` commands.
- [x] **Other providers (OpenAI).** An `openai/` module (Responses wire + SSE transport) sits behind
      the two-axis provider seam; the neutral item model, `/model`, `/effort`, caching, and stats
      are provider-agnostic and reconcile with it. Two accounts share it: `openai_api` (env
      `OPENAI_API_KEY`, Bearer, `api.openai.com`) and `openai_subscription` (Codex OAuth), the
      latter reachable through the `/login` picker.
- [x] **Account switch: empty assistant content (Anthropic 400).** The Anthropic serializer skips an
      assistant envelope that would emit zero blocks — a reasoning-only run whose reasoning is
      dropped by exact-account replay (`origin != account`) or by disabled reasoning — instead of sending
      `"content":[]`, which Anthropic rejects with a 400. Two user runs left adjacent by such a skip
      merge into one envelope, and the history cache breakpoint moves to the last block actually
      emitted. Covered by a switch that drops a reasoning-only run.
- [x] **Account switch: corrupt `auth.json` clobbers a sibling account on save.**
      `auth_store.serializeMerged` / `save` return `error.BadCredentials` on an unparseable or
      non-object existing file instead of starting from a fresh object, so a token-refresh save can
      never wipe every other account's entry by rewriting a file it could not read back.

## Networking & resilience

- [x] **Request timeouts.** Each phase is bounded in `anthropic/Transport.zig`: `Transport.send`
      (connect + send + response head) by a connect timeout, and each streamed read by an idle
      timeout. Zig's `std.http` has no request deadline and owns its own socket reads, so a timeout
      can't attach to an operation directly; `net.withTimeout` instead races the operation against a
      timer as two concurrent `std.Io.Select` tasks and cancels the loser — the operation wins with
      its result, or the timer wins and the stalled operation is cancelled and reaped, surfacing the
      typed `error.Timeout` the retry path acts on. A streamed read skips the race when a full line
      is already buffered, so only a read that must wait on the socket spawns tasks. A user cancel
      of the turn stays distinct (`error.Canceled`). Defaults 30s connect / 60s idle, set via
      `config.json`.
- [x] **SSE keep-alive / stall handling.** Anthropic streams periodic `ping` events; a hiccup can
      stall the byte stream without closing it, and a per-read idle timeout that any arriving byte
      resets can't tell a stalled-but-pinging stream from a live one. Ported the `pi` container
      workaround's semantics: the idle window now counts only _real_ frames. `net.Deadline` fixes
      one instant and bounds each streamed read by the time left until it; `Transport.next` restarts
      the window on every non-ping frame but lets a `ping` (now classified apart from other frames)
      draw it down, so a stream that stalls or sends nothing but pings surfaces `error.Timeout` and
      the retry path engages. The buffered fast-path is unchanged — a read only consults the
      deadline when it must wait on the socket.
- [x] **Request retries.** `Agent.fetchReply` retries a whole request on a timeout, premature stream
      end, transient network fault, or retryable status (408 / 429 / 5xx, including Anthropic's 529
      overloaded), honoring `retry-after` when present, with a bounded attempt count (default 3) and
      exponential backoff. It sits above `Transport`, so it stays provider-neutral (the transport
      only classifies its own status via `Stream.retryable`/`retryAfterMs`). Only whole requests are
      safe to retry: the provider's authoritative terminal event commits the assistant message;
      EOF, `[DONE]`, or an error before it discards partial text and tool calls, and
      `handler.onStreamReset` clears displayed partial text before the next attempt re-streams. Tool
      execution runs only after that commit and is never retried; a user cancel or channel close is
      never retried.
- [x] **Networking off the UI thread.** The event loop is a single `std.Io.Queue(UiEvent)` consumer
      fed by `io.concurrent` producers — a long-lived stdin reader, the turn worker (`agent.run` off
      the UI thread), and a one-shot frame timer. The consumer solely owns the model and paints, so
      request/stream I/O no longer freezes the UI. Each turn worker captures an immutable generation;
      every event it produces carries that generation, and the consumer frees and drops an event
      unless its turn is still active, so queued stragglers cannot cross a cancel-and-resubmit
      boundary. This unblocked mid-stream cancellation and a live progress indicator; tool scheduling
      remains worker-side, where independent read-only calls can run concurrently without touching the
      consumer.
- [x] **Streaming cancellation.** Ctrl-c/esc mid-turn cancels the turn worker's `Future`; the cancel
      interrupts the blocking read, `Transport.next` maps it to `error.Canceled` via
      `connection.getReadError()`, and `Agent.run`'s `errdefer` shrinks `messages` back to the
      turn's base — dropping the partial assistant message and leaving a valid alternation. Tools
      propagate `error.Canceled` too, and mutating tools write atomically so a cancelled write can't
      truncate the target.
- [ ] **Commit partial turns to history on cancel.** Today `Agent.run` treats a turn as atomic: an
      `errdefer self.messages.shrinkRetainingCapacity(base)` rolls the whole message list back to
      the pre-turn length on any early exit, so a mid-turn cancel drops everything the turn produced
      — the user prompt, a completed assistant reply (thinking + text), the `tool_use` blocks, and
      the `tool_result`s already appended by `readReply`/`runTools`. When the model has already
      emitted completed request/response pairs or run tools, forgetting them is wrong on two counts.
      First, the work is real: a completed assistant turn is a valid history entry, and re-deriving
      it costs tokens. Second, and more seriously, mutating tools have side effects the rollback
      cannot undo — an edit/write has already hit disk, and a bash command (once the **Bash tool**
      lands) may have done anything at all. edit/write we could in principle reverse; arbitrary bash
      we cannot. So the only way to keep history honest with the world is to _keep the events_, not
      to unwind them: after a cancel, `messages` should retain every completed assistant message and
      its tool results (a valid user/assistant alternation) so the next turn's model knows what it
      already thought and did. The commit boundary should be the **last complete round** — only
      fully-drained `readReply` output is provider-valid. An in-flight partial cannot be committed
      as-is: a thinking block cancelled before its `thinking_signature` has an empty signature
      (Anthropic rejects that on replay with tool use), and a `tool_use` cancelled mid-`input_json`
      carries truncated JSON. So the boundary is the last `.stop`-terminated reply, not the byte the
      cancel landed on. This is an `error.Canceled`-only behavior: `run`'s single errdefer and
      `runTurnWorker` today treat user-cancel and `error.Closed`/shutdown identically, but "keep the
      events" applies only to a user cancel — shutdown is moot, and genuine errors already discard
      cleanly via `reportAndReset`, so the commit logic is an error-kind split, not a blanket
      errdefer change. It is also distinct from the retry path, which deliberately _discards_
      partials (`onStreamReset` → `discardMessage`; a failed attempt will re-run): a failed attempt
      discards, a user cancel keeps. Open questions remain: how to close a dangling `tool_use` whose
      result never came back (a synthesized "cancelled" `tool_result` keeps the alternation valid —
      note this history marker for the model is separate from the "cancelled" _feedback block_ the
      transcript shows the user). Landing this reverses the invariant stated in the DONE **Streaming
      cancellation** entry ("dropping the partial assistant message"), so update that entry and
      `FEATURES.md` when it ships. The joined `agent.messages` (`cancelTurn` already joins the
      worker before teardown) should be the single source of truth that both this commit and the
      transcript rewind derive from — a parallel UI-side heuristic would let the two disagree and
      reintroduce the divergence **Show only committed content in the transcript** exists to kill.
      Pairs with that item (the still-uncommitted tail is what gets rewound) and ties into the
      **Permission model** and **Bash tool**. Landing it needs test infrastructure that does not
      exist yet — a scripted stream that can raise the cancel at a chosen event, and a way to drive
      the tool-round loop against fake tools in isolation (today's tests exercise reply parsing
      directly, never the full turn loop) — so build those first and size the work to include them.
- [ ] **Configurable tool-round cap.** The per-turn tool-round loop is bounded by a compiled-in 50
      rounds (`rounds_max` in `lib/ai/Agent.zig`), failing cleanly on overrun. Expose it via
      `config.json` (folded through `src/Config.zig` like the `request` section) with 50 as the
      default, so deep tool chains can raise it and a runaway guard can lower it. Clamp to at least
      one round; ties into the **Config file** item.
- [ ] **Unify the two provider transports.** `lib/ai/anthropic/Transport.zig` and
      `lib/ai/openai/Transport.zig` share most of their structure: the `Stream` struct skeleton, the
      `next` read loop, `takeLine`/`readLine`/`readFailed`, the `net.Deadline`/`net.Budget` idle and
      byte bounds, `decompressBuffer`, `retryAfter`, the `ok`/`errorText`/`retryable`/`retryAfterMs`/
      `usageSoFar` accessors, the `send`/`connect` skeleton, the `asObject`/`asString`/`asU64` JSON
      helpers, the `Decoded` enum shape, and the `TickingIo`/`ChunkedReader` test doubles are all
      duplicated near-verbatim. Only the wire mapping (`decode`/`classify`), request building
      (headers, auth, endpoint, body), and a few provider quirks differ: Anthropic's terminal-delta /
      `message_stop` commit and `.ping` folding; OpenAI's `[DONE]` sentinel and runtime
      `header_buffer`. Extract the SSE transport core into one module (e.g. `lib/ai/sse.zig`)
      parameterized by a per-provider `decode` (comptime fn or vtable) and a request builder, leaving
      each `*/Transport.zig` with only its wire logic and auth. The trigger: each transport-hardening
      change to this layer (idle window, aggregate byte budget, per-frame allocation bound) had to be
      applied twice, identically, to both files, so the copy-paste surface now outweighs the
      parallel-file clarity. Do it after the current transport-hardening work settles so the
      extraction lands on stable, fully-bounded transports and preserves that hardening (the idle,
      byte, and per-frame bounds, plus the stream-completion and cancellation semantics) exactly;
      keep both the per-provider wire tests and the shared-core tests green.

## UI

- [x] **Accurate display widths (wide glyphs).** The differential renderer `View` counts _physical_
      terminal rows for every cursor move: each frame line spans `width.rows` rows — the number of
      pieces `width.wrap` produces, not `ceil(width / columns)`, since a wide cluster cannot
      straddle the margin — and `width.caret` maps a caret's display column to its physical row and
      column within a wrapped line. A single `paint` helper drives every mode (first frame, full
      reset, incremental) so all row arithmetic lives in one place, and `viewportTop` and the caret
      restore both measure physical rows. A line wider than `columns` can no longer desync
      `cursor_row`, so `View` is correct independently of the app pre-wrapping every line. A model
      terminal in the test suite replays the exact escapes `View` emits with real auto-wrap and
      asserts the reconstructed document and caret, covering the wide-line paths byte-level checks
      cannot express.
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

- [x] **Grapheme-cluster caret movement.** `Editor` follows the same canonical display boundaries as
      terminal width and emission: valid UTF-8 moves and backspaces by whole grapheme cluster — a
      combining sequence, ZWJ emoji (`👨‍👩‍👧‍👦`), regional-indicator flag, skin-tone modifier, or keycap
      — while each control or malformed-byte replacement remains a separate editable unit. Boundary
      lookup re-segments forward because UAX #29 depends on preceding context. Insertions and
      deletions re-clamp to the resulting boundary, so fusing neighboring text or turning malformed
      bytes into valid UTF-8 cannot leave the caret inside a rendered unit.

- [x] **Sticky goal column for vertical caret movement.** `Editor` carries an optional
      `goal_column`: the first `moveUp`/`moveDown` of a run captures the caret's display column into
      it, and every subsequent vertical step targets that column via `terminal.width.offsetAt`
      instead of the live one. A row shorter than the goal clamps the caret for display without
      overwriting the goal, so a later step onto a wider row restores the column — the way most
      editors behave. Any horizontal move or edit (`moveLeft`/`moveRight`/`moveHome`/`moveEnd`/
      `insert`/`backspace`/`clear`) resets the goal to null so the next vertical run recaptures it.
      A vertical move off the top or bottom row falls back to `moveHome`/`moveEnd`, so pressing up
      on the first row jumps to the start and down on the last row jumps to the end.

- [x] **Extract block rendering into a `ui` widget + shared color namespace.** Block rendering moved
      out of `src/App.zig` into two `ui` modules, and the SGR palette into a third. `ui/color.zig`
      is the one palette `App`, `paint`, `Picker`, `separator`, and `status` share. `ui/paint.zig`
      holds the row-painting primitives (`Placement`, `BoxStyle`,
      `box`/`notice`/`wrapped`/`spinner`/`row`, plus `boxRows`/`spinnerStep`), which stream one row
      at a time into the view sink — the streaming `Placement` contract, deliberately _not_ the
      `render(columns, …, buffer, lines)` contract `Editor`/`Picker` use, so a clipped block never
      materializes its hidden top. `ui/block.zig` is the transcript-block model (`Entry`, below),
      measuring and painting itself via `paint`. App shrank to state + event loop + orchestration +
      agent glue + the projection/layout pass, and the block renderers are now unit-tested in
      `block.zig`.
- [x] **Make `App.Entry` a `union(Kind)`.** `Entry` (now in `ui/block.zig`) is a tagged union: the
      `intro`/`user`/`model` blocks carry a byte buffer, `tool_result`/`feedback` a buffer plus an
      `is_error` flag (`Flagged`). Each variant carries exactly its data — the `is_error` that was
      dead for the plain blocks is gone — and `rows`/`render`/`deinit` switch on it exhaustively.
      `Entry.init` owns the single kind→variant mapping. Stateful blocks (a collapsible `thinking`
      run, a tool box tracking its own status) now have somewhere to live.
- [ ] **Richer UI with dedicated components.** Move beyond the current log + single-line editor to
      composable components (tool-call panels, streaming status, a stats/context footer, a model/
      effort indicator, command palette). Keep the line/string render model. `ui.Picker` (the
      `/model` chooser) is the first such component: a single-choice list rendered into the live
      region, reusable by any command that returns a `pick` outcome.
- [x] **Display model thinking.** The model's reasoning streams into the transcript dimmed, separate
      from the answer. `anthropic/wire.zig` sends adaptive thinking
      (`thinking:{type:adaptive,     display:summarized}`) and `Transport` decodes thinking deltas,
      signatures, and redacted reasoning; `llm.Block` and `llm.Event` gained a `thinking` variant;
      `Agent` buffers a reasoning run into a `thinking` block (carried back verbatim so the provider
      accepts the tool calls that followed) and reports it via `handler.onThinking`; `Transcript`
      collects a run into one growing dimmed `thinking` block that the answer run does not extend,
      painted by `ui/block`. Adaptive thinking lets the model size its own budget, so no client-side
      budget is set; `/effort` steers its depth.
- [x] **Steering.** The user types and submits while a turn runs, queuing messages the pi way. The
      editor stays live during a turn (it was inert by policy, not by blocking — the off-thread
      networking work had already unfrozen the read loop): `App.editKey` drives the editor in both
      prompt and turn modes, Enter queues a steering message, and Alt+Up recalls the whole queue
      into the editor. A queued message rides two representations — `Session.steering` (the
      UI-thread `Steering:` display rows) and `ai.Steering`, a thread-safe (`std.Io.Mutex`) FIFO the
      turn worker takes from — fed together on submit. `Agent.run` drains the channel at each round
      boundary (and when the model would otherwise end the turn, so a message still lands mid-turn),
      combines the pending messages into one blank-line-joined user message folded into the trailing
      user turn (keeping the user/assistant alternation valid), and reports it via
      `handler.onSteering`; the consumer shows it as one normal user block and drops those queue
      rows. A message that lands after the final drain starts the next turn on its own. Alt+Up and
      cancel recall pending steering from the channel (so a message already folded into the turn is
      not also handed back — it shows as sent instead), blank-line-joined, into the editor. Slash
      commands can't run mid-turn (a picker can't coexist with a turn), so a `/`-line stays in the
      editor to send once the turn ends.
- [x] **Smooth spinner animation.** The `⠋ Working…` spinner is driven by the frame timer: while a
      turn animates the consumer re-arms a tick each frame and `advanceFrame` steps the spinner even
      when the model is clean, so it animates independently of stream events and no longer freezes
      during the pre-first-token wait. Covered by the "a tick repaints and steps the spinner while a
      turn animates" regression test.
- [x] **Extract the render consumer into a `Session` struct.** `src/Session.zig` owns the
      consumer-side model and rendering — `Transcript`, live-tail `mode`, `editor`, `view`, the last
      laid-out dimensions, and displayed stats/model — plus the event-appliers (`applyTurnEvent`)
      and `paint`, io-/tty-/agent-free so the render loop has an isolated test surface built from a
      real `Session.init` rather than a partially-initialized `App`. `App` keeps the io/tasks/tty/
      agent wiring, the consumer loop, and the key/command/turn orchestration (which triggers io/
      agent inline), driving the `Session` through its methods; key decoding (`input`) stays with
      that orchestration in `App`.
- [x] **Signal-driven resize.** Terminal resizes arrive via `SIGWINCH`. Since a POSIX signal handler
      is async-signal-safe only and cannot take the channel lock, `terminal.Resize` uses the
      self-pipe trick: the handler writes one byte to a pipe (write end non-blocking so a full pipe
      drops the redundant wake) and `Resize.wait` blocks reading the other end (blocking end,
      through `io.operateTimeout`). A fourth `io.concurrent` producer (`readResize`) turns each wake
      into a `.resize` `UiEvent`; the consumer marks the session dirty, so even a fully idle
      interface reflows at the new size (`refresh` re-reads `Tty.size()` each frame). The watcher is
      cancelled and reaped before its pipe closes and its handler is uninstalled at shutdown.
- [ ] **Context-window pressure signal.** The status line shows `ctx%` but nothing reacts to it.
      Warn as context fills (e.g. color the gauge past a threshold) and wire a threshold into
      `/handoff` compaction. Thresholds configurable with good defaults. Two model-specific
      dimensions to fold in: tiered pricing (some models cost more above a context threshold — needs
      tiered rates in `models.zig`, cf. pi's per-model `tiers`) and the degradation of output
      quality as context fills. OpenAI subscription discovery also decodes
      `effective_context_window_percent` but does not retain or apply it yet; when pressure
      budgeting lands, retain it per account/model and use the effective window for warning and
      compaction thresholds while keeping the raw catalog window as the displayed model limit.
      Evidence-based numbers for quality degradation are unlikely, so expose it as a configurable
      soft warning rather than a hardcoded rule — an idea to revisit. Note that once
      **Commit partial turns to history on cancel** lands, cancelled turns consume context where
      they previously vanished, so pressure builds faster than the old drop-on-cancel behavior
      implied.
- [ ] **Offer partial reasoning/text as a citation on cancel.** A common workflow is to watch the
      model's streamed reasoning, spot a misunderstanding early, and cancel to correct it — often
      _instead_ of steering, precisely to cut off a long inner monologue once the user sees they can
      help. But a cancel mid-stream lands before `readReply` appends the assistant message, so the
      reasoning the user just read is never in history and the model can't see its own aborted train
      of thought. When a turn is cancelled while the model was mid-generation (partial thinking or
      text streamed but no `stop`), detect it and offer to fold that partial output into the next
      prompt as a quoted citation, so the user can hand the model back its own reasoning and comment
      on it ("you were about to X, but …"). The partial text already lives in the display transcript
      (streamed via `onThinking`/`onText`) and a cancel keeps it there today (`abortTurn` ends the
      run via `endMessage` without discarding it — unlike the retry path's `discardMessage`). So the
      capture is only needed once **Show only committed content in the transcript** starts rewinding
      that tail: snapshot the partial there before removing it, and present a prompt-line option to
      include it. Open questions: the affordance (a prompt on cancel, a key, or a command), how much
      to include (thinking vs. answer, truncation), and a citation format that reads well back to
      the model.
- [ ] **Show only committed content in the transcript.** `App.submit` appends the user's message to
      the display transcript immediately and synchronously, and the streamed reply renders into it
      as it arrives — but on a cancel before the turn commits anything (no completed assistant
      response), that content is left on screen even though history never kept it (`Agent.run`'s
      errdefer rolled `messages` back). The transcript then shows a prompt the model never answered
      and never will, diverging from what the model actually knows. The principle: the transcript
      should mirror committed state. Optimistic display _during_ a turn is fine — showing the prompt
      and the streaming reply while we assume they will commit — but once a cancel means they will
      not, un-persist them: remove the uncommitted **tail** — the user prompt _and_ the partial
      reply that streamed under it — from the transcript and return the prompt text to the editor
      (mirroring how `cancelTurn` already recalls pending steering into the editor, though the
      original prompt today is not), so the user can edit and resend. `discardMessage` already drops
      the streamed assistant tail (from `message_start`), but the user block index is not tracked,
      so rewinding the prompt needs a new bit of transcript state. Seams: `App.submit` (the
      optimistic append), `App.cancelTurn`/`Session.abortTurn` (the teardown that today appends a
      "cancelled" feedback block rather than rewinding), and the rewind-vs-keep decision, which
      should derive from the joined `agent.messages` (see **Commit partial turns to history on
      cancel**) rather than a parallel UI-side "at least one completed response" test, so the
      transcript and history can't disagree. Interacts with that item: once completed rounds are
      committed, only the still-uncommitted tail is rewound.
- [ ] **Account cancelled turns' token cost.** `recordUsage` fires only on the stream's `.stop`
      event, which a mid-stream cancel never reaches, so a cancelled turn's tokens go unrecorded in
      `Agent.Stats` — yet the provider still bills the full input prompt (and the output streamed so
      far). The session cost gauge therefore under-counts exactly the turns a user cancels most, and
      committing the partial to history (see **Commit partial turns to history on cancel**) without
      its cost widens that gap. Completed rounds are fine (they hit `.stop`); the hole is the
      in-flight request. `message_start`/`message_delta` already carry incremental usage the retry
      path ignores — capture it at cancel and fold it into `Agent.Stats` so the gauge reflects money
      actually spent.
- [ ] **Define editor composition on cancel.** After a cancel the editor can receive up to four
      writers: text the user was already typing, pending steering that `cancelTurn` recalls today,
      the original prompt returned by **Show only committed content in the transcript**, and the
      partial-reasoning citation from **Offer partial reasoning/text as a citation on cancel**.
      `appendToEditor` blank-line-joins in call order, and nothing defines which leads or how they
      separate — but they are not interchangeable: the returned prompt should precede recalled
      steering, the citation is the model's words (not the user's) and wants its own quoted framing,
      and in-progress typing must not be clobbered. Define the composition — order, separators, and
      framing per source — as one model rather than letting each feature append blindly. This is the
      underspecified linchpin of the cancel cluster.
- [ ] **Configurable transcript window.** The live view retains a compiled-in 8 pages (terminal
      heights) of the newest content (`window_pages` in `src/layout.zig`): the frame keeps
      `rows * window_pages` rows measured newest-first and clips the rest at the top. Expose it via
      `config.json` (folded through `src/Config.zig`) with 8 as the default, trading scrollback
      retention against per-frame measure and redraw cost. Clamp to at least one page; ties into the
      **Config file** item.

## Cross-cutting / open questions

- [ ] **Permission model.** No allow/deny concept exists. Bash, subagent tool allowlists, and
      write/edit gating all want a shared answer here.
- [ ] **Config file.** Format and location are settled: `$HOME/.pith/config.json`, loaded by
      `src/Config.zig` (typed `std.json` parse; a missing file, section, or field falls back to a
      built-in default and unknown keys are ignored, so it is optional, partial, and
      forward-compatible). It carries the `request` section (network timeouts + retry policy, folded
      into the neutral `ai.net.Timeouts`/`ai.net.Retry` structs) and `default_models` (a model name
      per account, resolved against the compiled table). API keys are deliberately env-only, never
      config — no secrets in a shareable file. Still to fold in as those features land: system
      prompt, skill/agent/prompt directories (see the `models.json` runtime catalog item, which may
      merge here), and the compiled-in limits exposed elsewhere in this backlog — the transcript
      window (UI) and the tool-round cap (Networking & resilience). Mutable machine-local state (the
      active account+model, see Configuration & context) belongs in a separate local file, not here.
