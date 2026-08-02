# Backlog

Planned features for pith, roughly ordered by dependency. Each item leads with the sentence that
goes into `FEATURES.md` once it lands. The italic note after it records only what the implementer
cannot re-derive from the code. This is an external constraint, a decision already taken, or a
dependency on another item. Module layout and extension seams live in `AGENTS.md`.

## Tools & permissions

- [ ] **Permission model** — the user allows or denies what a tool can do. _Bash, subagent tool
      allowlists, and write/edit gating all want one shared answer here. Anthropic's
      mid-conversation tool changes (beta `mid-conversation-tool-changes-2026-07-01`, Opus 4.8 and
      Opus 5) add and withdraw tools through `tool_addition`/`tool_removal` blocks. A permission
      change then does not need to rewrite the `tools` array. The `tools` array sits at the very
      front of the cache prefix. A rewrite there invalidates the whole conversation._

## Slash commands

- [ ] **Tab completion** — Tab completes a partial slash command and lists the candidates when
      several match. _Tab currently decodes as ctrl-i._
- [ ] **`/handoff`** — compact the conversation into a summary and continue with the reclaimed
      context. _The command must also summarize cancelled turns and the synthesized tool results
      they leave behind._
- [ ] **`/stage`** — stage everything in git, so the agent's next diff shows only its own edits.
      _During a turn this is a steering message. When idle, the command prefills the editor and does
      not send, so the user reviews first._
- [ ] **`/cache-retention`** — choose the active model's prompt-cache retention where the provider
      offers a real choice. _Anthropic offers 5m and 1h. The 1h write costs 2x base input against
      1.25x, so pricing needs a per-TTL write rate. One TTL across all breakpoints sidesteps the
      ordering rule. Current OpenAI models expose only 30m, so report it and do not open a picker.
      Never guess. When the policy is unknown, omit the field and report the provider default. Reset
      to that default on `/model`. Cache warming is the rival approach. Replay the last request with
      `max_tokens: 1` just under the TTL. This buys a near-free read instead of the 1h write
      premium. It only pays off once Subagents leaves the main agent idle for minutes (cf.
      claude-thermos)._
- [ ] **`/subagent`** — list, pick, and dispatch to a user-defined subagent. _This depends on
      Subagents._

## Instructions & subagents

- [ ] **Custom system prompt** — explicitly configured files can replace or extend the authored
      core. _Generated environment, project-instruction, and skill sections remain._
- [x] **Project instructions** — the system prompt includes the applicable `AGENTS.md` files. _At
      startup, load exact-case files from the nearest Git root through the working directory,
      broad-to-specific. Outside Git, inspect only the working directory. There is no global file or
      `CLAUDE.md` fallback. Warn when pith finds and ignores `CLAUDE.md` or a likely-misspelled
      `AGENT.md`. Discovery, bounds, ordering, and diagnostics follow
      `docs/project-instructions.md`._
- [ ] **Custom prompts** — user-maintained prompt templates run as slash commands with argument
      substitution.
- [x] **Skills** — on-demand instruction files: pith advertises the names and descriptions to the
      model, and a body loads when triggered. _Pith resolves skills from both a user-level and a
      project directory._
- [ ] **Subagents** — a tool or command dispatches user-defined agents, each with its own prompt and
      allowed tools. _Allow one nesting level only. A non-recursive scheduler drives it, not a child
      agent loop called from parent tool dispatch. Each child's usage folds into the parent exactly
      once. Root and subagent cost stay separable, so status can read `$5.00 (+$2.00)`. Per-agent
      allowlists can ride mid-conversation tool changes instead of a per-agent `tools` array._

## Accounts & signing in

- [ ] **API-key login by paste** — `/login` accepts an API key pasted in-session, instead of only
      naming the variable to set. _This departs from env-only keys. It needs a deliberate owner-only
      on-disk shape and the same abort-rather-than-wipe save discipline as the subscription tokens._
- [x] **Console OAuth** — sign in through the Anthropic developer platform. The login mints and
      stores a platform key that carries the Claude Code identity, so it reaches every model.

## Sessions & persistence

- [ ] **Remember the active account and model** — a restart resumes on the last-used account and
      model rather than the first authenticated one. _This is mutable machine-local state, so it
      belongs in a separate local file, not the shareable `config.json`. The split wants a
      deliberate naming choice._
- [ ] **Save and resume conversations** — a conversation reopens after a restart and does not start
      empty. _The per-turn cost ledger must persist with it, since history items carry no cost.
      Generate the OpenAI cache key once per conversation and restore it verbatim. Rotate it only on
      a deliberately fresh start. A billing-product enum is not sufficient provenance for opaque
      reasoning. Persist a durable non-secret principal identity and replay only on a match.
      Versioned, atomic, owner-only._

## Providers & cost

- [ ] **Steering as a system message** — a message sent mid-turn reaches the model as operator-level
      context, so it folds into the work in flight and does not redirect it. _Anthropic's documented
      shape is a `{"role":"system"}` message directly after the tool-result turn. Phrase it as a
      fact ("the user sent the following while you were working: …") rather than a command. Place it
      exactly where the queue already drains. It sits after the cache breakpoint, so the prefix
      still hits. It is unavailable on `claude-sonnet-5` and unlisted for `claude-sonnet-4-6`, so
      folding into the trailing user turn stays as the fallback._
- [ ] **`/session` breakdown** — a per-turn ledger backs a session summary of tokens, cost, and
      cache savings, split by model. _Cost belongs in the ledger, not in history items. Billing is
      per request. History must stay byte-stable for cache hits. A cancelled turn's reply rolls back
      out of history. Cancelled and failed turns get their own entries, so cost survives `/handoff`
      compaction._
- [x] **Remaining subscription quota** — the status line shows how much of an OpenAI subscription's
      allowance remains.
- [ ] **Runtime model catalog** — an optional `~/.pith/models.json` overrides or extends the
      compiled model table without a rebuild. _Compiled defaults stay authoritative, so a known
      model always has a known context window. The file only patches or adds._

## Interface

- [ ] **Stream tool arguments into the box** — a tool call's arguments appear as the model writes
      them, so a long write or edit shows its content instead of only a spinner. _Both transports
      already parse the argument fragments and know the tool name at block start. The missing piece
      is a display-only delta beside streamed text and reasoning. This is display only. The tool
      still runs after the reply commits, so nothing runs on half-received arguments. Drop the
      provisional box on a retry's stream reset, like partial answer text._
- [ ] **Re-read the last prompt during a turn** — see the submitted prompt with no need to cancel.
      _Pith already retains the submitted prompt's rich draft for the whole turn._
- [ ] **Context-window pressure signal** — the context gauge warns as it fills, and feeds a
      compaction threshold. _The thresholds are configurable. Fold in two model-specific dimensions:
      tiered pricing above a context threshold, and OpenAI's effective context window (decoded at
      login but unused). The effective context window must drive warnings while the catalog window
      stays the displayed limit. Quality degradation has no evidence-based number, so keep it a soft
      warning._
- [ ] **Richer UI components** — composable tool-call panels, streaming status, and a command
      palette go beyond today's log plus editor. _Keep the line/string render model._
- [ ] **Markdown tables and clickable links** — markdown tables render as box-drawing grids, and
      links become clickable terminal hyperlinks. _Both were deferred out of the markdown renderer.
      A table needs per-column width sizing and wrapping that still satisfies row parity at every
      width, down to the two-column edge. Today a table falls through to plain paragraph text. A
      link shows as styled text with the URL appended. OSC-8 hyperlinks are a string control, not an
      SGR, so a clickable runtime URL needs a trusted path through the sink's SGR-only control
      boundary._

## Configuration

- [ ] **Configurable tool-round cap** — the 50-round per-turn cap moves into `config.json`. _Clamp
      to at least one round._
- [ ] **Configurable transcript window** — the 8-page transcript window moves into `config.json` and
      trades scrollback retention against per-frame redraw cost. _Clamp to at least one page._
- [ ] **Fold new settings into `config.json`** — the system prompt path and the skill, agent, and
      prompt directories join it as they land. _API keys stay env-only. No secrets go into a
      shareable file._
