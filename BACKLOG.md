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

## Command surface

- [ ] **Slash-command parsing.** Intercept lines starting with `/` in the submit path (`App.submit`)
      before they reach `Agent.run`. A small command registry (name → handler) parallel to the tool
      registry. Everything below hangs off this.
- [ ] **`/model`** — switch the active model at runtime. `Agent.init` already takes `model` as a
      param, so the seam is the hardcoded const in `App.zig` plus a live-reconfigure path.
- [ ] **`/effort`** — set reasoning/effort level, and show it on the status line so the right side
      reads `model • effort` (e.g. `claude-opus-4-8 • xhigh`). Requires an effort field on
      `llm.Request`, per-provider mapping (Anthropic thinking budget, OpenAI reasoning effort), and
      threading `effort` into `tui.status.Info`.
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
      last message (3 of the 4 allowed), so the stable prefix and the growing history are cached each
      turn. Anthropic applies its own per-model minimum-prefix rules server side.
- [x] **Usage & cost stats.** `Transport` folds `message_start` / `message_delta` usage into
      `llm.Usage`, carried on the `stop` event; `Agent.Stats` accumulates tokens and cost (priced by
      `pricing.zig`), and the `tui.status` line shows tokens, cache-hit rate, cost, and context-
      window fill. Remaining: prices are a small hardcoded table (grows per model); no per-turn /
      `/session` breakdown yet.
- [ ] **Other providers (OpenAI, …).** Add a `Kind` arm in `provider.zig` and an `openai/` module
      (wire + transport) mirroring `anthropic/`. Everything above `provider.zig` is already
      provider-agnostic. Reconciles with `/model`, `/effort`, caching, and stats.

## UI

- [ ] **Richer UI with dedicated components.** Move beyond the current log + single-line editor to
      composable components (tool-call panels, streaming status, a stats/context footer, a model/
      effort indicator, command palette). Keep the line/string render model.

## Cross-cutting / open questions

- [ ] **Streaming cancellation.** The read loop blocks during a turn; ctrl-c mid-stream is not
      handled. Needed before long-running tools (bash) and subagents are comfortable.
- [ ] **Permission model.** No allow/deny concept exists. Bash, subagent tool allowlists, and
      write/edit gating all want a shared answer here.
- [ ] **Config file.** Several items above (system prompt, model/effort defaults, provider keys,
      skill/agent/prompt directories) imply a single config source. Decide format and location.
