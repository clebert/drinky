# FEATURES.md

What pith does, one short sentence per capability. It is an overview, not a specification: the _why_
and _how_ live in commit history, `BACKLOG.md` (planned work), and `docs/`.

pith is a terminal coding agent. You type a prompt. The model reads, searches, writes, and edits
files in the working directory while the conversation streams inline into your scrollback. It talks
to Anthropic and OpenAI, through either a subscription login or an API key.

## Talking to it

- A prompt runs a turn to completion: stream a reply, run its tools, feed the results back, repeat.
- At most 1000 tool rounds per turn, as a guard against a runaway loop.
- Read-only tool calls in one reply run in parallel. A mutating call — write, edit, or bash — runs
  alone, in call order.
- Enter during a turn queues a steering message that folds into the run at the next tool round.
- Ctrl+P pulls messages the turn has not picked up yet back into the editor to keep editing.
- Steering left in the queue when a turn completes starts the next turn on its own.
- Esc or Ctrl+D cancels a turn and keeps the draft. Ctrl+C clears a draft in the editor first, and
  cancels only on an empty editor. Canceled or failed turns keep finished rounds, drop the in-flight
  tail, and return uncommitted text to the editor.
- A tool call left unfinished is recorded as an error, so a canceled mutation is never lost
  silently.
- Timeouts and transient failures retry the whole request and clear the partial reply first.
- A reply cut short by the output cap is kept, and reported as cut short.
- Model-side failures — a refusal, an empty reply, the round cap — read as a plain sentence rather
  than an internal error.
- Reasoning streams into its own block, with a blank line between its parts. Encrypted reasoning
  shows as `[redacted thinking]`.

## Tools

- The model gets seven tools: `read`, `write`, `edit`, `find`, `grep`, `bash`, and `config`.
- **read** — page a UTF-8 file from a 1-indexed line offset, 2000 lines or 50 KiB per call, with a
  next-offset hint.
- **write** — create or overwrite a file atomically.
- **edit** — replace one exact span, which must occur exactly once.
- **find** — glob search under a directory, sorted by path, 1000 hits by default.
- **grep** — literal search that prints `path:line:text` under a directory or in a single named
  file, with glob and case filters, 100 hits by default.
- **bash** — run a shell command in the working directory, preserve combined stdout and stderr
  order, and return a bounded tail. A non-zero exit is reported. Output caps and the timeout are
  configurable, and the timeout is also settable per call.
- **config** — return the settings document, so the model can change `config.json` for the user. It
  names the file and lists every key with its type, its default, and its meaning, plus the legal
  model names, the effort levels, the compiled fallbacks, and the memory that outranks the file.
- Globs use `*` and `?` within a path segment and `**` across segments.
- Searches skip version-control and build directories.
- Binary files are skipped, oversized files are refused, and every result says when a limit cut it
  short.
- A failing tool returns an error the model can read, and a cancel stops it at once.

## Models & reasoning effort

- Anthropic supports `claude-fable-5`, `claude-opus-5`, `claude-opus-4-8`, `claude-sonnet-5`, and
  `claude-sonnet-4-6` with 1M tokens of context.
- OpenAI `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`, at 1.05M tokens of context.
- Output caps at 128k tokens per turn.
- A ChatGPT subscription learns its real context windows after login.
- Reasoning effort runs `none`, `low`, `medium`, `high`, `xhigh`, `max`, folded to what the model
  supports.
- A restart resumes on the account, model, and effort level this project used last.
- Each account keeps the model it ran in this project. A switch, a login, and a restart all return
  to it.
- `/model` and `/effort` both refuse while signed out, since the status line hides both values then.
- Session cost and cache savings accumulate per model and count a canceled turn's billed usage.

## Accounts

- Anthropic and OpenAI, each reachable as a subscription account or a platform API-key account.
- The Anthropic Console account adds an OAuth login that mints and stores a platform key.
- Startup resumes on the account this project used last, else takes the first authenticated one and
  prefers a signed-in login over an API key.
- With no account at all, the login picker opens by itself.
- While signed out, pith refuses a message with a prompt to `/login`.
- Reasoning replays only to the account that produced it. A login, a logout, or a credential
  replacement discards that account's reasoning, cache evidence, and allowance.

## Signing in

- OAuth login uses PKCE (S256) with a loopback callback, and opens the system browser.
- The Anthropic Console login trades its grant for a minted platform key, stored like a token.
- When no browser opens, the printed URL still works, and the callback waits five minutes.
- The browser lands on a plain "Pith received authorization. Close this tab." page.
- Subscription tokens and the Console key live in the owner-only `~/.pith/auth.json`, one entry
  per account, saved atomically.
- Expired access tokens refresh and re-save automatically.
- A busy credential store keeps a refreshed token in memory and retries its save before the next
  provider request.
- Anthropic subscription logins save stable account and organization IDs from the OAuth profile.
- If another pith instance saved a token for the same known principal, pith reloads it and retries
  once. A different or unknown principal stops before the model request.
- If another pith instance saves a replacement before removal, pith reloads it and keeps the
  account active.
- Without a replacement, pith removes the rejected credential and moves the session to another
  account or the login picker.
- A token failure that is not a rejection ends the turn, names the reason, and keeps the account
  signed in.
- A login whose save fails stays signed in until pith exits, and says so.

## Slash commands

- **/model** — switch account and model together, from the next turn on.
- **/effort** — set the reasoning-effort level, from the next turn on.
- **/login** — sign in, switch to an account already signed in, or name the API key to set.
- **/logout** — drop a signed-in account's credentials and hand the session to another account.
- **/new** — clear the conversation, usage stats, and steering without changing its configuration.
  The next paint drops the terminal scrollback, so the empty conversation starts on a clean screen.
- **/system** — inspect the complete provider-neutral system prompt as rendered Markdown in a
  scrollable full-window page. `M` toggles its exact source.
- **/colors** — preview ANSI slots 0 to 15, colored backgrounds, default styles, message boxes,
  text roles, and input frames in a scrollable full-window page.
- **/skill:name** — load a discovered skill explicitly, record a compact `Skill:` marker, and append
  any trailing text as its task.
- Every line that starts with a slash is a command line, so Pith reads it locally first and sends it
  only after a confirmation. A command that takes no argument refuses text after the name, as in
  `/new must clear the scrollback`. `/skill:name` is the one exception, because it takes its task as
  trailing text.
- Pith keeps a refused line in the editor, so its text survives an unknown name or unwanted text
  after the name. A command that ran clears the editor. Only a `/skill:` line carries user text, and
  that text moves into the turn as the task.
- Pith always offers a way out for a refused line: the footer offers `Enter: Send as a message`, and
  during a turn `Enter: Queue as a message`. The next Enter alone sends the line as typed. Every
  other key cancels the offer and its row. The end of the turn cancels them too, and the line waits
  in the editor for a new offer.
- Successful model, effort, login, logout, and account changes are recorded as transcript events.
- A local command failure temporarily replaces the footer until the next user action.
- A command that can run stays in the editor while a turn runs, and one notice names the command and
  the restriction. The next Enter runs it after the turn ends.

## Providers

- Streams from Anthropic's Messages API and OpenAI's Responses API over SSE.
- A reply enters the conversation only once the provider reports it complete.
- Prompt caching is always on: explicit breakpoints for Anthropic, the automatic per-session cache
  for OpenAI.
- A stale prompt cache blocks the first submit, estimates the extra input cost, and lets the next
  Enter continue.
- The assumed cache retention per provider and the cost that arms this warning are configurable.
- Reasoning is requested summarized at the resolved effort, and replayed verbatim on later turns.
- Anthropic Subscription and Anthropic Console requests carry the Claude Code client identity. A
  plain API key goes straight to the platform API.
- Requests time out after 30 s to the response head and 60 s between streamed events. Keepalive
  filler does not count as progress.
- A failed request retries up to 3 times with 500 ms–16 s backoff and honors a server's retry-after
  hint.
- A failed request reports the message from the provider JSON error body, not the raw bytes. A
  failed response head names its status too. For a spent OpenAI subscription, the message names the
  plan and the wait.

## The interface

- The conversation renders inline into the normal screen buffer and real scrollback. Temporary
  full-window pages use the alternate screen and restore the conversation on close.
- A page asks the terminal to send an arrow key for a wheel notch. A trackpad then scrolls the page,
  and a drag still selects text.
- Apple Terminal has no such mode. A page there takes mouse reports and the legacy alternate screen.
  A trackpad scrolls it, but a text selection needs the Fn key. The close reprints the conversation
  window.
- A full-window page scrolls with the arrow keys, PgUp/PgDn, and Home/End. Esc closes it, and its
  header says so. Ctrl+C and Ctrl+D close it too, so an exit attempt always works.
- Repaints only the rows that changed, atomically. A shrink or height change keeps native scrollback
  intact and can leave blank rows below the interface. A width change or a change above the viewport
  reprints the window.
- A span seam takes a zero-width guard only where the two fragments can fuse into one grapheme, so
  almost no seam carries one.
- Restores the terminal on exit, on a failed start, and around an interactive OAuth login.
- Parks the cursor below the interface on exit, so the shell prompt does not overwrite the last
  frame.
- Handles typing, streaming output, and resizes concurrently, so the interface never freezes
  mid-turn.
- Repaints are frame-limited at a fixed rate and scheduled only while something is dirty or
  animating.
- Answer text grows as one block. Reasoning grows in a separate muted and italic block. Both render
  their markdown: headings, lists, blockquotes, code blocks, rules, tables, and nested inline
  emphasis. A heading, a quote, and an emphasis span shed their markers. A quote has no border
  glyph, so a terminal copy holds the text alone.
- A link becomes a clickable terminal hyperlink when a click can open its target, and a bare URL
  links to itself. Any other target, such as a relative path, shows its URL as text.
- A pipe table draws as a box grid that fits the window and keeps the indentation of its source. The
  alignment colons parse but do not align. A long cell truncates to its column. A table stays plain
  text when the window is narrower than its smallest grid.
- A running tool shows a pending box with its name and arguments. It then becomes a success or error
  box with a one-line stat summary. It shows the first output line when the tool gives no summary.
- One heavy activity segment moves across both open input separators in a loop and grows as progress
  goes quiet without adding a layout row.
- Pith blinks the input caret while a turn runs, because a terminal holds its own cursor solid under
  a continuous repaint. An edit restarts the blink, so the caret stays visible while the user types.
- Queued steering shows as `Queued message:` rows, and becomes one user message once consumed.
- The bottom line shows `directory (branch)`, context fill, cost, quota, and cache-hit rate on the
  left, and `model (account) · Effort: level` on the right. At most one temporary notice replaces it
  until the next user action.
- A narrow window shortens the directory, branch, and context gauge before it removes parts, and it
  always keeps the context percentage.
- The branch comes from the `HEAD` file of the repository, never from the git command. pith re-reads
  it when a turn starts and when one ends.
- A picker is a single-choice list that tags the current value. Enter confirms, and Esc, Ctrl+C, or
  Ctrl+D cancels.
- The open input area grows to about a quarter of the screen and labels hidden rows "↑ Hidden: N"
  and "↓ Hidden: N".
- The terminal supplies every color and the muted intensity. Pith uses the default colors, ANSI
  slots 0 to 15, faint, and reverse video. A filled box keeps the terminal background for its text.
  A label or a glyph marks every state, so color is never the only signal.
- Model, tool, and user text can never emit escapes: controls and malformed UTF-8 render as
  replacement characters.

## Editing & text

- Enter sends, Shift+Enter or Ctrl+J makes a newline, Esc cancels, Ctrl+C clears, Ctrl+D quits. An
  intro line shows the bindings at launch.
- A second Ctrl+C within 500 ms quits, as does Ctrl+D on an empty editor or a closed stdin.
- The caret moves by grapheme cluster, by wrapped row with a sticky column, and to the start or end
  of the input.
- A paste over 10 lines or 1000 bytes collapses to a `[Paste #N: L lines]` marker.
- A marker moves, deletes, and counts as one unit, and submits its exact bytes.
- Decodes the Kitty keyboard protocol and traditional escape sequences, including ones split across
  reads.
- A terminal without the Kitty protocol reports Escape as one byte. That byte becomes the Escape key
  after a 50 ms wait, and a control byte right after it stays a key of its own.
- An exit key that returns the session to the prompt drops the rest of its input chunk. Esc and then
  Ctrl+D closes the page or cancels the turn, and never quits pith. Enter and typed text keep every
  key behind them.
- A bracketed paste arrives as one unit, with controls and escapes inside kept as literal payload.
- Unrecognized sequences and stray control bytes are ignored and never leak into the text.
- Text is segmented per UAX #29, so an emoji family, a flag, or a Hangul syllable stays one glyph.
- Pith asks the terminal for grapheme cluster processing at startup. The cursor then advances one
  grapheme cluster at a time, the same as the pith measure of a row. An older terminal ignores the
  request.
- A cluster measures 0, 1, or 2 columns, so CJK and emoji wrap, truncate, and place the caret
  correctly.
- A row breaks between two words and paints no blank at the break. A terminal copy of the rows thus
  holds whole words. Text with no blank, such as a URL or a CJK run, breaks inside itself.
- Wrapping and truncation never split a cluster or let a wide one straddle the margin.
- Width and grapheme tables come from Unicode 17.0.0, regenerated with `zig build unicode` and
  checked against the official conformance corpus.

## Files & configuration

- The compiled core is minimal and mechanical, so the user owns the guidance that steers a turn.
- The system prompt adds the startup UTC date, the working directory, and the repository root. It
  also ranks the instruction sources it carries, so the model knows which one wins on a conflict.
- pith loads exact-case `AGENTS.md` files in path order, from the Git root down to the working
  directory. Outside a repository it reads that directory alone.
- pith looks for skills in `~/.agents/skills/`, and in `.agents/skills/` from the Git root down to
  the working directory. Outside a repository it looks in that directory alone.
- pith searches each skills directory at any depth for `SKILL.md` and follows directory symlinks. On
  a name clash a project skill has priority over a user skill, and the closest copy has priority
  over a copy farther up. pith advertises each skill name and description, and loads the
  instructions on demand.
- pith loads the user instruction files that `config.json` names, in order.
- One startup line counts the instruction files that pith loaded and the skills that it found. A
  count of zero stays out of the line. Only a skipped file gets its own line, and `/system` shows
  every counted path.
- User and project instructions obey one policy: a regular UTF-8 file, with content, no NUL byte,
  and at most 32 KiB. Each source loads at most 32 files and 64 KiB, and one file loads once even
  when two paths or a symbolic link reach it. pith reports what it skips.
- `~/.pith/config.json` is optional: paths for user instructions, request and bash limits, the
  prompt-cache warning, a default model per account, and a default effort level. pith reads it only
  at startup, so a change applies at the next start.
- It holds no secrets. API keys come from `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`.
- A configured model that is not valid for its account is reported, and the compiled default used.
  An unknown effort level and a cache warning cost that pith cannot use are reported the same way. A
  key that pith does not know is reported too, so a typo never looks like an applied setting.
- The settings document is generated from the struct that parses the file, so a new key that carries
  no description fails the build and the document cannot drift.
- JSON store writes use owner-only sibling `.lock` files to coordinate pith instances.
- `~/.pith/state.json` remembers per project which account and effort level pith used last, and the
  model of each account. It is machine-local, owner-only, and keeps the 1000 most recently changed
  projects. A repository is one project, keyed by its Git root.
- pith reads that file only at startup, so a change in one instance reaches only the next start. A
  persistent save failure is reported once and never stops the session.
- `HOME` must be set, since the config, the credentials, and the state all live under `~/.pith`.

## Keeping this file true

One short sentence per capability, at the concept level: what a user gets, not how the code spells
it. When a capability lands, add its line and tick the matching `BACKLOG.md` item. When one goes
away, delete the line. Merge a fact into a neighbouring line rather than add a new one. If a section
passes roughly a dozen lines, it is either two sections or too much detail.
