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
- [ ] **Parallel tool calls.** Anthropic (and most providers) already emit multiple `tool_use`
      blocks in one assistant message when the calls are independent; `Agent.consume` collects them
      but runs them one after another. Execute independent calls concurrently instead. Depends on
      the off-thread networking work below; keep result ordering stable so each `tool_result` maps
      back to its `tool_use` id. Confirm we never send `disable_parallel_tool_use`.

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
      the command with the choice via `command.apply` — so the widget stays generic. Per-message cost
      attribution across a switch is still the open item below.
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
- [ ] **Networking off the UI thread.** The read loop blocks the event loop for the whole turn, so
      the UI is frozen while streaming. Move request/stream I/O onto its own thread and feed events
      back to a single-threaded renderer. Enables mid-stream cancellation, concurrent tool
      execution, and a live progress indicator.
- [ ] **Streaming cancellation.** Handle ctrl-c mid-stream to abort a turn cleanly — drop the
      partial assistant message and leave history a valid user/assistant alternation. Builds on
      off-thread networking; needed before long-running tools (bash) and subagents are comfortable.

## UI

- [ ] **Richer UI with dedicated components.** Move beyond the current log + single-line editor to
      composable components (tool-call panels, streaming status, a stats/context footer, a model/
      effort indicator, command palette). Keep the line/string render model. `tui.Picker` (the
      `/model` chooser) is the first such component: a single-choice list rendered into the live
      region, reusable by any command that returns a `pick` outcome.
- [ ] **Steering.** Let the user type and send while a turn is running, queuing messages the way pi
      does. Today the read loop is frozen for the whole blocking `agent.run()`, so the input box is
      visible but inert. Depends on the off-thread networking work ("Networking off the UI thread"):
      once stream I/O runs on its own thread, the event loop can keep reading keys, append submitted
      lines to a pending-message queue, and feed them into the current or next turn.
- [ ] **Smooth spinner animation.** Drive the `⠋ Working…` spinner from a timer
      (`requestRender`-style) so it animates independently of stream events. It currently advances
      one frame per stream event and freezes during the initial pre-first-token wait, because the
      loop is blocked for the whole turn. Depends on the off-thread networking work so the UI thread
      is free to tick a timer while the request is in flight.
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
