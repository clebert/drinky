# Backlog

Planned features for pith, roughly ordered by dependency. Each item leads with the sentence that
goes into `FEATURES.md` once it lands; the italic note after it records only what the implementer
cannot re-derive from the code — an external constraint, a decision already taken, or a dependency
on another item. Module layout and extension seams live in `AGENTS.md`.

## Tools & permissions

- [ ] **Permission model** — the user allows or denies what a tool may do. _Bash, subagent tool
      allowlists, and write/edit gating all want one shared answer here. Anthropic's
      mid-conversation tool changes (beta `mid-conversation-tool-changes-2026-07-01`, Opus 4.8 and
      Opus 5) add and withdraw tools through `tool_addition`/`tool_removal` blocks, so a permission
      change need not rewrite the `tools` array — which sits at the very front of the cache prefix
      and would invalidate the whole conversation._

## Slash commands

- [ ] **Tab completion** — Tab completes a partial slash command, listing the candidates when
      several match. _Tab currently decodes as ctrl-i._
- [ ] **`/handoff`** — compact the conversation into a summary and carry on with the context
      reclaimed. _Must also summarize cancelled turns and the synthesized tool results they leave
      behind._
- [ ] **`/stage`** — stage everything in git, so the agent's next diff shows only its own edits. _A
      steering message during a turn; when idle it prefills the editor instead of sending, so the
      user reviews first._
- [ ] **`/cache-retention`** — choose the active model's prompt-cache retention where the provider
      offers a real choice. _Anthropic offers 5m and 1h, the 1h write costing 2x base input against
      1.25x, so pricing needs a per-TTL write rate; one TTL across all breakpoints sidesteps the
      ordering rule. Current OpenAI models expose only 30m, so report it rather than opening a
      picker. Never guess: omit the field and report the provider default when the policy is
      unknown, and reset to that default on `/model`. Cache warming is the rival approach — replay
      the last request with `max_tokens: 1` just under the TTL, buying a near-free read instead of
      the 1h write premium. It only pays off once Subagents leaves the main agent idle for minutes
      (cf. claude-thermos)._
- [ ] **`/subagent`** — list, pick, and dispatch to a user-defined subagent. _Depends on Subagents._

## Instructions & subagents

- [ ] **Custom system prompt** — the authored core can be replaced or extended from explicitly
      configured files. _Generated environment, project-instruction, and skill sections remain._
- [ ] **Project instructions** — applicable `AGENTS.md` files are included in the system prompt.
      _At startup, load exact-case files from the nearest Git root through the working directory,
      broad-to-specific; outside Git inspect only the working directory. No global file or
      `CLAUDE.md` fallback; warn when `CLAUDE.md` or likely-misspelled `AGENT.md` would otherwise be
      silently ignored. Discovery, bounds, ordering, and diagnostics follow
      `docs/project-instructions.md`._
- [ ] **Custom prompts** — user-maintained prompt templates, invoked as slash commands with argument
      substitution.
- [x] **Skills** — on-demand instruction files: names and descriptions are advertised to the model,
      and a body loads when triggered. _Resolved from both a user-level and a project directory._
- [ ] **Subagents** — user-defined agents, each with its own prompt and allowed tools, dispatched
      from a tool or command. _One nesting level only, driven by a non-recursive scheduler rather
      than a child agent loop called from parent tool dispatch. Each child's usage folds into the
      parent exactly once, and root and subagent cost stay separable so status can read
      `$5.00 (+$2.00)`. Per-agent allowlists can ride mid-conversation tool changes instead of a
      per-agent `tools` array._

## Accounts & signing in

- [ ] **API-key login by paste** — `/login` accepts an API key pasted in-session, instead of only
      naming the variable to set. _Departs from env-only keys: needs a deliberate owner-only on-disk
      shape and the same abort-rather-than-wipe save discipline as the subscription tokens._
- [ ] **Console OAuth** — sign in through the Anthropic developer platform, a third mechanism beside
      subscription OAuth and an environment key. _Only if that grant is available to this client._

## Sessions & persistence

- [ ] **Remember the active account and model** — a restart resumes on the last-used account and
      model rather than the first authenticated one. _Mutable machine-local state, so it belongs in
      a separate local file, not the shareable `config.json`. The split wants a deliberate naming
      choice._
- [ ] **Save and resume conversations** — a conversation reopens after a restart instead of starting
      empty. _The per-turn cost ledger has to persist with it, since history items carry no cost.
      Generate the OpenAI cache key once per conversation and restore it verbatim, rotating only on
      a deliberately fresh start. A billing-product enum is not sufficient provenance for opaque
      reasoning: persist a durable non-secret principal identity and replay only on a match.
      Versioned, atomic, owner-only._

## Providers & cost

- [ ] **Steering as a system message** — a message sent mid-turn reaches the model as operator-level
      context, so it folds into the work in flight instead of redirecting it. _Anthropic's
      documented shape is a `{"role":"system"}` message directly after the tool-result turn, phrased
      as a fact ("the user sent the following while you were working: …") rather than a command, and
      placed exactly where the queue already drains. It sits after the cache breakpoint, so the
      prefix still hits. Unavailable on `claude-sonnet-5` and unlisted for `claude-sonnet-4-6`, so
      folding into the trailing user turn stays as the fallback._
- [ ] **`/session` breakdown** — a per-turn ledger backs a session summary of tokens, cost, and
      cache savings, split by model. _Cost belongs in the ledger, not in history items: billing is
      per request, history must stay byte-stable for cache hits, and a cancelled turn's reply is
      rolled back out of history. Cancelled and failed turns get their own entries, so cost survives
      `/handoff` compaction._
- [x] **Remaining subscription quota** — the status line shows how much of an OpenAI subscription's
      allowance is left.
- [ ] **Runtime model catalog** — an optional `~/.pith/models.json` overrides or extends the
      compiled model table without a rebuild. _Compiled defaults stay authoritative, so a known
      model always has a known context window; the file only patches or adds._

## Interface

- [ ] **Stream tool arguments into the box** — a tool call's arguments appear as the model writes
      them, so a long write or edit shows its content arriving rather than only a spinner. _Both
      transports already parse the argument fragments and know the tool name at block start; what is
      missing is a display-only delta beside streamed text and reasoning. Display only — the tool
      still runs after the reply commits, so nothing runs on half-received arguments. The
      provisional box must be dropped on a retry's stream reset, like partial answer text._
- [ ] **Re-read the last prompt during a turn** — see what was submitted without cancelling. _The
      submitted prompt's rich draft is already retained for the whole turn._
- [ ] **Context-window pressure signal** — the context gauge warns as it fills, and feeds a
      compaction threshold. _Thresholds configurable. Two model-specific dimensions to fold in:
      tiered pricing above a context threshold, and OpenAI's effective context window (decoded at
      login but unused), which should drive warnings while the catalog window stays the displayed
      limit. Quality degradation has no evidence-based number, so keep it a soft warning._
- [ ] **Richer UI components** — composable tool-call panels, streaming status, and a command
      palette, beyond today's log plus editor. _Keep the line/string render model._
- [ ] **Markdown tables and clickable links** — markdown tables render as box-drawing grids, and
      links become clickable terminal hyperlinks. _Both were deferred out of the markdown renderer.
      A table needs per-column width sizing and wrapping that still satisfies row parity at every
      width, down to the two-column edge; today a table falls through to plain paragraph text and a
      link shows as styled text with the URL appended. OSC-8 hyperlinks are a string control, not an
      SGR, so a clickable runtime URL means opening a trusted path through the sink's SGR-only
      control boundary._

## Configuration

- [ ] **Configurable tool-round cap** — the 50-round per-turn cap moves into `config.json`. _Clamp
      to at least one round._
- [ ] **Configurable transcript window** — the 8-page transcript window moves into `config.json`,
      trading scrollback retention against per-frame redraw cost. _Clamp to at least one page._
- [ ] **Fold new settings into `config.json`** — the system prompt path and the skill, agent, and
      prompt directories join it as they land. _API keys stay env-only; no secrets in a shareable
      file._
