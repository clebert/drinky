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
      context. _The command must also summarize canceled turns and the synthesized tool results they
      leave behind._
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

- [x] **User instructions** — pith loads the configured files in order, counts them at startup, and
      reports each file it skipped. _Set `user_instructions` to an ordered array in
      `~/.pith/config.json`. Each item has one `path`. Resolve relative paths from `~/.pith/`. Each
      path must obey the same policy as a project instruction file: a regular UTF-8 file, with
      content, no NUL byte, and at most 32 KiB, inside a source total of 32 files and 64 KiB. pith
      reports the file it skips and the reason. pith inspects at most 32 entries and reports the
      rest. A repeated file loads once, because the canonical path is its identity. A bad entry
      never stops pith. The core always comes from the binary._
- [x] **Project instructions** — the system prompt includes the applicable `AGENTS.md` files. _At
      startup, load exact-case files from the nearest Git root through the working directory in path
      order. Outside Git, inspect only the working directory. There is no global file or `CLAUDE.md`
      fallback. Report the file that is not valid. Report an ignored `CLAUDE.md` or a
      likely-misspelled `AGENT.md`._
- [ ] **Custom prompts** — user-maintained prompt templates run as slash commands with argument
      substitution. _The whole-line rule special-cases the `skill:` prefix today. A second
      argument-taking command must move that rule into the registry `Entry`._
- [x] **Skills** — on-demand instruction files: pith advertises the names and descriptions to the
      model, and a body loads when triggered. _Pith resolves skills from both a user-level and a
      project directory._
- [ ] **Subagents** — a tool or command dispatches user-defined agents, each with its own prompt and
      allowed tools. _Allow one nesting level only. A non-recursive scheduler drives it, not a child
      agent loop called from parent tool dispatch. Each child's usage folds into the parent exactly
      once. Root and subagent cost stay separable, so status can read `$5.00 (+$2.00)`. Per-agent
      allowlists can ride mid-conversation tool changes instead of a per-agent `tools` array. A
      second concurrent agent also makes `auth.accessToken` unsafe. It returns a slice into the
      shared `Auth` tokens and frees the old tokens in place. A parallel refresh can then free the
      token that another task still sends. Guard the expiry check, the refresh, and the install with
      one lock. Re-check the expiry inside the lock. That also stops the second refresh, which
      rotates the single-use token again and kills the first task's credential. Today the two
      callers cannot overlap, because a turn cannot host a slash command._

## Accounts & signing in

- [ ] **API-key login by paste** — `/login` accepts an API key pasted in-session, instead of only
      naming the variable to set. _This departs from env-only keys. It needs a deliberate owner-only
      on-disk shape and the same abort-rather-than-wipe save discipline as the subscription tokens._
- [x] **Console OAuth** — sign in through the Anthropic developer platform. The login mints and
      stores a platform key that carries the Claude Code identity, so it reaches every model.

## Sessions & persistence

- [x] **Remember the active account and model** — a restart resumes on the account, model, and
      effort level this project used last, rather than the first authenticated one. _This is mutable
      machine-local state, so it lives in `~/.pith/state.json`, not the shareable `config.json`. The
      key is the project: the Git root, or the working directory outside a repository._
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
      per request. History must stay byte-stable for cache hits. A canceled turn's reply rolls back
      out of history. Canceled and failed turns get their own entries, so cost survives `/handoff`
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
- [x] **Terminal-owned colors** — the interface emits the default colors and the ANSI slots 0 to 15
      alone, so the theme of the terminal picks every value. _Pith carries no palette, no color
      configuration, and no third-party license. One role map turns a semantic role into its SGR
      bytes. A filled box takes one foreground color plus reverse video. This keeps the contrast
      between that palette slot and the terminal background. Every state also carries a text label
      or a glyph, so color is never the only signal._
- [ ] **Context-window pressure signal** — the context gauge warns as it fills, and feeds a
      compaction threshold. _The thresholds are configurable. Fold in two model-specific dimensions:
      tiered pricing above a context threshold, and OpenAI's effective context window (decoded at
      login but unused). The effective context window must drive warnings while the catalog window
      stays the displayed limit. Quality degradation has no evidence-based number, so keep it a soft
      warning._
- [ ] **Richer UI components** — composable tool-call panels, streaming status, and a command
      palette go beyond today's log plus editor. _Keep the line/string render model._
- [ ] **Carriage returns in tool output** — a tool result shows a progress line as its final state,
      not a replacement glyph for every carriage return. _Real tool output carries one: `curl` and
      `pip` redraw a line in place. The main seam is `paint.box`, which draws a user message too.
      In `markdown`, `walk` sheds the carriage return at the end of a CRLF line, so only one inside
      a line is left there. The sink turns a control byte into U+FFFD to keep its column math, so
      the text must lose the byte first. Keep only the text after the last carriage return in a
      line, because a terminal overwrote what came before it. `boxRows` and `box` must share the
      rule, or the row counts diverge._
- [x] **Emit the grapheme guard only where it can fuse** — `View.Sink` writes a U+200B break at a
      span seam only where the two fragments can join into one grapheme. _`grapheme` classifies both
      edges of the seam. The break goes in when the next fragment starts with a joining code point
      (Extend, ZWJ, SpacingMark, regional indicator, Hangul V or T). One flag adds the break when
      the row's tail leaves a join open (Prepend, ZWJ, an Indic linker, a Hangul L jamo). Real text
      carries almost no guard, so every frame shrinks and a terminal that gives U+200B a column,
      such as Apple Terminal, stops shifting each styled row. Such a terminal still shows wrong
      emoji widths, flicker, and approximate colors, which is acceptable. A startup guard that
      refused `TERM_PROGRAM=Apple_Terminal` was written and dropped: it detects almost nothing (a
      tmux pane, ssh, and every untested terminal pass it) and it blocks a terminal that mostly
      works._
- [x] **Markdown tables** — a pipe table renders as a box-drawing grid that sizes each column and
      fits the window. _A long cell truncates to its column instead of wrapping. A table falls back
      to plain paragraph text when the window is narrower than its smallest grid. The fallback
      keeps row parity at every width._
- [x] **Clickable links** — links become clickable terminal hyperlinks. _`View.Sink` owns the OSC-8
      string control, because a URL is the only runtime content in the terminal control channel. The
      sink is the one boundary that clears it: printable ASCII alone, at most 2048 bytes, and a
      scheme of `http`, `https`, or `mailto`. Nothing can then leave the URL field, and a click
      cannot reach a scheme the user does not expect. Any other target keeps its URL as text, and a
      row always closes its own link._

## Configuration

- [ ] **Configurable transcript window** — the 8-page transcript window moves into `config.json` and
      trades scrollback retention against per-frame redraw cost. _Clamp to at least one page._
- [ ] **Fold new settings into `config.json`** — the skill, agent, and prompt directories join it as
      they land. _API keys stay env-only. No secrets go into a shareable file._
