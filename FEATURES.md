# FEATURES.md

What Drinky does, one short sentence per capability. This file is an overview, not a specification.
The tests define the behavior. The Git history keeps the decisions, and `BACKLOG.md` holds the
planned work.

Drinky is a terminal coding agent. You type a prompt. The model reads, searches, writes, and edits
files in the working directory, and the conversation streams into your scrollback. Drinky talks to
Anthropic and OpenAI through a subscription login, an Anthropic Console login, or an API key.

## Talking to it

- A prompt runs one turn to the end. Drinky streams the reply, runs the tool calls, and sends the
  results back until the model stops.
- A turn runs at most 1000 tool rounds, so a runaway loop ends.
- Read-only tool calls of one reply run in parallel. A `write`, `edit`, or `bash` call runs alone,
  in call order.
- Enter during a turn queues a steering message. The turn takes it at the next tool round.
- Ctrl+P moves the queued messages back into the editor. A message that the turn did not take
  returns to the editor when the turn ends.
- Esc or Ctrl+D cancels the turn and keeps the draft. Esc with a draft warns first and cancels on
  the second press. Ctrl+C clears the draft first and cancels only at an empty editor.
- A canceled or failed turn keeps the finished rounds, drops the unfinished tail, and returns
  uncommitted text to the editor.
- A refused send starts no turn, and the editor keeps the line for the next Enter.
- An unfinished tool call stays in the history as a failed call, so a canceled change is never
  hidden.
- A timeout or a transient failure retries the whole request. Drinky clears the partial reply and
  records each retry cause.
- A failed turn that committed work shows a `Failed turn` caption above the editor. Ctrl+N asks the
  model to continue, and Esc discards the retry. The retry never takes the editor text, and the
  start of any turn drops it.
- A reply that the output cap cuts short stays, and Drinky reports the cut.
- A refusal, an empty reply, and the round cap read as a plain sentence, not as an internal error.
- Reasoning streams into its own block. Encrypted reasoning shows as `[redacted thinking]`.

## Tools

- The model gets seven tools: `read`, `write`, `edit`, `find`, `grep`, `bash`, and
  `describe_drinky`.
- **read** — page through a UTF-8 file from a 1-indexed line, 2000 lines or 50 KiB per call, with
  the next offset.
- **write** — create or overwrite a file atomically.
- **edit** — replace one exact span that occurs exactly once.
- **find** — glob search under a directory, sorted by path, 1000 hits by default.
- **grep** — literal search under a directory or in one file. It prints `path:line:text`, filters by
  glob and case, and returns 100 hits by default.
- **bash** — run a shell command in the working directory and return the tail of its combined
  output. Drinky reports a non-zero exit. The output caps and the default timeout come from the
  config, and a call can set its own timeout. Every command runs under a timeout from 1 second to 1
  hour. A configured deny list refuses a command that contains one of its patterns, and the refusal
  names the pattern. A command runs without a controlling terminal, so it cannot take the terminal
  from Drinky. Drinky has no web tool, so a network request also runs through `bash`.
- **describe_drinky** — describe Drinky itself: every slash command, every `config.json` key, the
  key bindings, the discovery rules, and the repository. The model answers a question about Drinky
  from this document, not from memory. The command list, the config keys, and the key bindings come
  from the code, so they cannot drift. It reports no current value.
- A configured glob can require a skill. When a tool first touches a matching file, Drinky sends the
  whole skill file into the turn, and the transcript names it. A read is never refused. `write` and
  `edit` refuse until the whole skill file is in the conversation. A read of the `SKILL.md` file and
  a `/skill:name` line both count.
- A glob uses `*` and `?` inside a path segment and `**` across segments.
- A search skips common noise directories: version-control stores, dependency directories, and build
  caches. A path that ends with such a name searches it fully. An empty search names up to three
  skipped directories, but never a version-control store.
- `find` and `grep` run under a fixed 10-second timeout that no call and no config changes.
- A stopped search keeps the matches it found, and a stopped command keeps the tail of its output.
  Each one states the stop, so the model can narrow the next call.
- `grep` skips a binary file and an oversized file. `read` and `edit` refuse an oversized file.
  Every result states when a limit cut it short.
- A failing tool returns an error that the model can read. A cancel stops the tool at once.

## Models & reasoning effort

- Drinky compiles no model in. Every model, limit, effort level, and price comes from the provider
  and from OpenRouter. The user fetches that list from `/model`.
- No request runs at startup. A fetch runs on request, and Drinky caches the result in `models.json`
  per account and in `metadata.json` per vendor.
- A fetch runs beside the interface. The picker clears its rows, states the wait, and moves its
  separators. Esc cancels the fetch and returns the rows. A fetch with something to report records a
  transcript event.
- One window of `request.connect_timeout_ms` bounds a whole fetch: the token refresh, every page of
  the list, and the metadata request.
- The provider wins every field that it states. Only OpenRouter prices a model.
- A model that no source describes never reaches the picker. A Codex model that the backend hides
  stays hidden.
- An OpenAI API key states no model fact, so that account offers no model until OpenRouter describes
  one.
- An Anthropic request must name an output cap. A model that states no limit runs at a low default,
  and the model picker marks it, because that default can cut a reply short.
- The effort levels are `low`, `medium`, `high`, `xhigh`, and `max`. Every level is a wire spelling
  that a provider accepts, and a name outside the ladder drops when Drinky reads a list. The level
  states the intention of the user, so `/effort` offers every level at every time, with or without
  an account or a model.
- Drinky never asks a model to stop its reasoning. A model that reasons runs at a named level, and a
  model that takes no level runs with no control.
- Each request resolves the level against its model in silence. A level that the model does not name
  folds to the nearest one it names. A tie takes the lower level. A model that takes no level drops
  it. The effort picker marks each such level, so the fold is visible before the choice.
- An account with no model shows `No model` in the warning color. A send then refuses and names the
  command that fixes it.
- Each account keeps the model it ran in this project. A switch, a login, and a restart return to
  it. An account with no cached list returns to no model, and a model that the account no longer
  offers drops in silence.
- A restart resumes on the account, model, and effort level that this project used last.
- `/model` refuses while signed out, because the status line hides the model then. `/effort` works
  while signed out, and the next sign-in adopts the level.
- The session cost accumulates at public rates and counts the billed usage of a canceled turn. Every
  cost figure reads `~$0.42`, and the tilde marks the estimate.

## Accounts

- Drinky supports Anthropic and OpenAI, each as a subscription account or an API-key account. The
  Anthropic Console account adds an OAuth login that mints and stores a platform key.
- Startup resumes on the account that this project used last. Otherwise it takes the first
  authenticated account and prefers a login over an API key.
- With no account at all, the login picker opens by itself. While signed out, Drinky refuses a
  message and points to `/login`.
- Reasoning replays only to the account that produced it. A login, a logout, or a credential
  replacement discards the reasoning, cache-hit rate, and allowance of that account.
- Drinky shows only the conversation that the next request carries. A change that drops stored
  reasoning repaints the screen and the scrollback without it.

## Signing in

- An OAuth login uses PKCE (S256) with a loopback callback and opens the system browser. The
  Anthropic Console login trades its grant for a minted platform key that Drinky stores like a
  token.
- When no browser opens, the printed URL still works, and the callback waits five minutes. When the
  browser cannot reach the callback, a paste of the URL from its address bar completes the login.
- The browser lands on a plain page: "Drinky received authorization. Close this tab."
- The tokens and the Console key live in the owner-only `~/.drinky/auth.json`, one entry per
  account, saved atomically.
- Drinky refreshes and saves an expired access token. When the store is busy, Drinky keeps the
  refreshed token in memory and retries the save before the next request.
- An Anthropic subscription login saves stable account and organization IDs from the OAuth profile.
  When another Drinky instance saved a token for the same principal, Drinky takes that token and
  refreshes only an expired one. A different or unknown principal stops before the model request.
- A request that the provider rejects with 401 renews the credential once and repeats. The renewal
  takes the token that another instance saved, or refreshes the token in memory. An API-key account
  holds one fixed secret, so a rejected request ends the turn.
- When another instance saved a replacement, Drinky reloads it and keeps the account active. Without
  a replacement, Drinky removes the rejected credential and moves to another account or to the login
  picker.
- A token failure that is not a rejection ends the turn, names the reason, and keeps the account
  signed in.
- A login whose save fails stays signed in until Drinky exits, and says so.

## Slash commands

- **/help** — pick a command from an alphabetical list. Each row holds a name and a short summary.
  Enter runs the command at once, and a bare `/` opens the same list. Esc returns to the list from
  any picker that a row opened.
- **/model** — switch the account and the model together, from the next turn on. The picker steps
  through the provider, the account, and the model, and skips a step with one row. The model step
  starts with a row that fetches the list of that account.
- **/effort** — set the reasoning-effort level, from the next turn on. The picker lists every level
  and marks a level that the active model folds or drops.
- **/login** — sign in, switch to a signed-in account, or name the API key to set.
- **/logout** — drop the credentials of a signed-in account and hand the session to another account.
- **/new** — clear the conversation, the usage stats, and the steering. The configuration stays. The
  next paint clears the terminal scrollback, so the empty conversation starts on a clean screen. The
  intro line returns, and the source summary does not.
- **/system** — show the complete system prompt as rendered Markdown in a scrollable full-window
  page. `M` toggles the exact source.
- **/skill** — pick one of the discovered skills. Each row holds the first sentence of the
  description. Enter writes the `/skill:name ` line into the editor, so a task can follow. `/skill:`
  opens the same list.
- **/skill:name** — load one skill. Drinky records the head line `Skill: name · File: path` and the
  trailing text as the task in a user box below it.
- Every line that starts with a slash is a command line. Drinky reads it locally and sends it to the
  model only after a confirmation. A command that takes no argument refuses text after its name.
  `/skill:name` is the one exception, because the trailing text is its task.
- A refused line stays in the editor. The footer offers `Enter: Send as a message`, or
  `Enter: Queue as a message` during a turn. The next Enter sends the line as typed. Every other key
  cancels the offer, and so does the end of the turn.
- A command that ran clears the editor. A successful model, effort, login, logout, or account change
  records a transcript event.
- A local command failure replaces the footer until the next user action.
- No command runs during a turn. The command stays in the editor, a notice names the restriction,
  and the next Enter runs it after the turn.

## Providers

- Drinky streams from the Anthropic Messages API and the OpenAI Responses API over SSE. A reply
  enters the conversation only when the provider reports it complete.
- Prompt caching is always on: explicit breakpoints for Anthropic, the automatic per-session cache
  for OpenAI.
- Drinky requests summarized reasoning at the resolved effort and replays it verbatim on later
  turns.
- An Anthropic Subscription or Console request carries the Claude Code client identity. A plain API
  key goes straight to the platform API.
- Every Anthropic request asks for the input of a tool call as the model writes it.
- A request times out after 30 s to the response head. A streamed event must arrive within 60 s for
  Anthropic and 300 s for OpenAI, whose stream is silent while the model reasons. Keepalive filler
  does not count as progress. All three windows are configurable.
- A failed request runs up to 3 attempts with a backoff from 500 ms to 16 s, and it honors a
  retry-after hint. A wait longer than the backoff cap ends the request. A spent OpenAI plan states
  its reset in the error body, so Drinky reports it after one try.
- A stream frame that names a call or a block other than the open one ends the turn without a retry.
- A reply from a model other than the requested one records a transcript event with both names. An
  unchanged fallback reports once per turn. Drinky knows no rate for that model, so the reply
  carries no price.
- A failed request reports the message from the provider JSON error body, not the raw bytes. A
  failed response head names its status too. For a spent OpenAI subscription, the message names the
  plan and the wait.

## The interface

### Screen

- The conversation renders inline into the normal screen buffer and the real scrollback. A
  full-window page uses the alternate screen and restores the conversation on close.
- Drinky repaints only the rows that changed, atomically, at a fixed frame rate, and only while
  something is dirty or animates.
- A height change keeps the native scrollback intact and can leave blank rows below the interface. A
  width change or a change above the viewport reprints the window.
- Drinky redraws the newest eight window heights of the conversation, and the config sets that
  count. Older rows rest in the native scrollback. More pages keep more of the conversation live and
  cost more work per frame.
- Drinky restores the terminal on exit, on a failed start, and around an OAuth login. It parks the
  cursor below the interface on exit, so the shell prompt does not overwrite the last frame.
- Typing, streaming output, and resizes run concurrently, so the interface never freezes during a
  turn.
- A full-window page scrolls with the arrow keys, PgUp/PgDn, and Home/End. Its fixed caption names
  the page and its controls. Esc, Ctrl+C, and Ctrl+D close it.
- A page asks the terminal to send an arrow key for a wheel notch, so a trackpad scrolls the page
  and a drag still selects text.

### Captions and notices

- Every notice above the input wraps. It breaks at a `·` separator first. A hint too wide for one
  row keeps that row and marks the cut. A sentence breaks between words.
- One caption heads the intro line, a picker, an editor state, and a full-window page. Its accent
  title and muted controls share one row when they fit. On overflow the title takes one row and cuts
  with one `…`, and the control segments wrap at their `·` boundaries under it.
- A row bound caps each caption: one row for a page, three for a picker or an editor state, none for
  the intro line. A control segment past the bound drops whole, so the title survives longest.
- An element with a stable height keeps one row and marks its cut with one `…`: a tool box, a picker
  option, a code row, and the footer notice. The status line shortens its fields and then drops
  them.

### Text and markdown

- Answer text grows as one block. Reasoning grows in a separate muted and italic block. Both render
  their markdown: headings, lists, blockquotes, code blocks, rules, tables, and nested inline
  emphasis. A heading, a quote, and an emphasis span shed their markers. A quote has no border
  glyph, so a terminal copy holds the text alone. Both blocks drop the blank rows that they end on.
- A link becomes a clickable terminal hyperlink when a click can open its target, and a bare URL
  links to itself. Any other target, such as a relative path, shows its URL as text.
- A pipe table draws as a box grid that fits the window and keeps the indentation of its source. The
  alignment colons have no effect. A long cell wraps inside its column. A run wider than the column
  drops behind one `…`. A table stays plain text when the window is narrower than its smallest grid.
- Every box row, editor row, and reasoning row starts at the first column, so a terminal copy lines
  up. An indent appears only where it groups rows under a head, as in a markdown list.
- Model, tool, and user text never emit escapes. Controls and malformed UTF-8 render as replacement
  characters.

### Tool boxes

- A tool box that states measures wraps no line. Each line takes one row and marks a cut with one
  `…`, so the height of a call follows its state and never the length of its arguments. A box that
  holds the sentence of a failure wraps instead.
- The head row paints the tool name bold. A call names its subject as `File:`, `Pattern:`, or
  `Command:`, with each run of whitespace collapsed to one space. A path shows relative to the
  working directory, with `~` for the home directory, or whole when it sits under neither.
- While the model streams the arguments, the call reports `Received:` with the bytes so far and
  `Status: Streaming`. A call that waits for another call reports `Status: Queued`.
- A running command or search adds a row with its elapsed time and its timeout. Every other tool
  runs under no timeout, so its box keeps one row.
- A finished call keeps its call row and one line below it: a line of measures, or the sentence of a
  failure. A call with nothing to state, like `describe_drinky`, keeps the call row alone.
- `read` reports `Lines: 42`, or `Lines: 594–648 of 2868` when a window cut the file. `write`
  reports the lines it wrote, `edit` reports `Lines: -12 +8`, and `find` and `grep` report
  `Time: 420ms · Matches: 3`. Each line adds one qualifier for every bound that cut the result, such
  as `Output: Truncated` or `Search: Timed out`.
- `bash` reports `Time: 420ms · Exit code: 1 · Lines: 3`. A timeout or a kill replaces the code with
  `Status:`. A stopped command keeps the tail of its output below the measures. A non-zero exit
  takes no `Error:` prefix, because the line names its own state. The box still paints the failure,
  and the model still reads the result as one.
- Every duration in the interface takes one shape: whole milliseconds below a second, then seconds
  with one decimal, then whole minutes and seconds.

### Editor and status line

- One heavy activity segment moves along both input separators in a loop and grows while progress is
  quiet. It adds no layout row.
- Drinky blinks the input caret while a turn runs, because a terminal holds its cursor solid under a
  continuous repaint. An edit restarts the blink.
- Pending steering shows its message count and the Ctrl+P control in the editor caption. Its content
  becomes one user message once consumed.
- The open input area grows to about a quarter of the screen and labels hidden rows `↑ Hidden: N`
  and `↓ Hidden: N`.
- The bottom line shows `directory (branch)`, the context gauge, the cost, the quota, and the
  cache-hit rate on the left, and `model (account) · Effort: level` on the right. The model name and
  the effort value take the normal intensity, so the two settings that the user changes stand out.
- One temporary notice replaces the bottom line until the next user action. The notice keeps one
  row, so it never moves the editor. A warning and a failure carry their color.
- The context gauge holds what the last committed reply measured, and an empty history is 0. It
  reads `Context: Unknown` while the next request renders the history in another way: after a model
  switch, an account switch, or an effort change that stops a stored reasoning block from replaying.
  A switch back shows the count again. It reads `Context: 206k`, the tokens alone, when no source
  states the context window of the model.
- The cache-hit rate holds the last request of the active account, model, and resolved effort. A
  change to any of the three hides it. Two effort levels that resolve to one wire form share the
  cache. A canceled attempt still rates its own prompt.
- A subscription window reads `5h: 12% (53m)`: the share used, and the wait until it resets. The
  wait shows one unit and rounds down: `53m`, `22h`, `6d`. The shortest window prints first. Both
  subscription backends state the allowance in the response head.
- The quota and the cache-hit rate show while a turn runs. Each one measures one request.
- The context gauge and each quota window take the warning color from 75% used and the error color
  from 90% used. The config sets both shares. A color on this line always means pressure, and the
  color follows the printed share.
- A narrow window shortens the directory, the branch, the context gauge, and the countdowns before
  it removes parts, and it always keeps the context gauge. The per-request measurements go before
  the session cost, longest window first. A bracketed detail goes before its head: the account
  before the model, and the branch before the directory.
- The branch comes from the `HEAD` file of the repository, never from the git command. Drinky
  re-reads it on each key, when a turn starts, and when one ends, so a checkout in another terminal
  shows without a turn.

### Pickers

- A picker is a single-choice list that tags the current value. Enter confirms. Ctrl+C or Ctrl+D
  cancels from any step. The selection rolls over at both ends.
- A selection can open a second list, which replaces the first one. Esc returns to the list that the
  selection came from, and Esc at the first list cancels. The key hint states which one the Esc
  does. Drinky skips a list on the way back that it skipped on the way down, and it reopens each
  list at the row that the user left.
- Every option holds one row. A row too wide for the window cuts with one `…`. The cut takes the
  option text, so the tag stays.
- The picker caption stays outside the scrolled window.

### Colors

- The terminal supplies every color and the muted intensity. Drinky uses the default colors, ANSI
  slots 0 to 7, faint, and reverse video. A filled box keeps the terminal background for its text. A
  label or a glyph marks every state, so color is never the only signal.
- A source summary paints its `Instructions:` and `Skills:` labels in the accent color and keeps its
  values muted.
- A message that Drinky wrote for the user takes the user color and no box: the head of a loaded
  skill and the line of a retry attempt. A typed message cannot forge it.
- A failed event opens with `Error:` and paints its whole text in the error color. Every other event
  opens with `Event:` and paints its whole text in the accent color. An incomplete reply ends with
  an `Error:` event that states the output or context limit.

## Editing & text

- Enter sends. Shift+Enter or Ctrl+J makes a newline. Esc cancels, Ctrl+C clears, and Ctrl+D quits.
  The intro line shows these bindings under the bold accent `Drinky` title and closes with
  `/help: Commands`. It wraps with no row bound, so a narrow window keeps every hint.
- A second Ctrl+C within 500 ms quits. Ctrl+D quits at an empty editor or a closed stdin. Ctrl+D
  with a draft warns first and quits on the second press.
- The caret moves by grapheme cluster, by wrapped row with a sticky column, and to the start or end
  of the input.
- A paste over 10 lines or 1000 bytes collapses to a `[Paste #N: L lines]` marker. The marker moves,
  deletes, and counts as one unit, and it submits its exact bytes.
- Drinky decodes the Kitty keyboard protocol and traditional escape sequences, also when a sequence
  splits across reads. A terminal without the Kitty protocol reports Escape as one byte. That byte
  becomes the Escape key after a 50 ms wait, and a control byte right after it stays a key of its
  own.
- An exit key that returns the session to the prompt drops the rest of its input chunk. Esc and then
  Ctrl+D closes the page or cancels the turn, and never quits Drinky. Enter and typed text keep
  every key behind them.
- A bracketed paste arrives as one unit. Controls and escapes inside it stay literal payload.
- Drinky ignores an unrecognized sequence and a stray control byte, so neither reaches the text.
- Drinky segments text per UAX #29, so an emoji family, a flag, or a Hangul syllable stays one
  glyph. Drinky asks the terminal for grapheme cluster processing at startup, so the cursor advances
  one cluster at a time, the same as the Drinky measure of a row. An older terminal ignores the
  request.
- A cluster measures 0, 1, or 2 columns, so CJK and emoji wrap, truncate, and place the caret
  correctly. Wrapping and truncation never split a cluster or let a wide one straddle the margin.
- A row breaks between two words and paints no blank at the break, so a terminal copy holds whole
  words. Text with no blank, such as a URL or a CJK run, breaks inside itself.
- The width and grapheme tables come from Unicode 17.0.0. `zig build unicode` regenerates them, and
  the official conformance corpus checks them.

## Files & configuration

- The compiled core is minimal, so the user owns the guidance that steers a turn.
- The system prompt adds the startup UTC date, the working directory, and the repository root. It
  ranks the instruction sources, so the model knows which one wins on a conflict. It names each path
  pattern that requires a skill and each bash deny pattern, so the model knows the rules before it
  acts.
- Drinky loads the exact-case `AGENTS.md` files from the Git root down to the working directory, in
  that order. Outside a repository it reads that directory alone.
- Drinky looks for skills in `~/.agents/skills/` and in each `.agents/skills/` from the Git root
  down to the working directory. Outside a repository it looks in that directory alone.
- Drinky searches each skills directory at any depth for `SKILL.md` and follows directory symlinks.
  On a name clash a project skill wins over a user skill, and the closest copy wins over a copy
  farther up. Drinky advertises each name and description, and loads the instructions on demand.
  Drinky skips and reports a skill file above the window of one `read` call, 2000 lines or 50 KiB,
  so one call always shows the model a whole skill.
- Drinky loads the user instruction files that `config.json` names, in order.
- One source summary counts the loaded instruction files, the found skills, the user skills that a
  project skill replaced, and the required skills that this project does not carry. A count of zero
  stays out. Only a skipped file gets its own line, and `/system` shows every counted path.
- An instruction file is a regular UTF-8 file with content, no NUL byte, and at most 32 KiB. Each
  source loads at most 32 files and 64 KiB, and one file loads once even when two paths reach it.
  Drinky reports what it skips.
- `~/.drinky/config.json` is optional. It holds the user instruction paths, the request and bash
  limits, a bash deny list, a default effort level, the skills that a path requires, and the
  interface settings. Drinky reads it only at startup, so a change applies at the next start. It
  holds no secrets. API keys come from `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`.
- Drinky reports an unknown key, an unknown effort level, and an interface value that it cannot use,
  so a typo never looks like an applied setting.
- A required skill whose name no discovered skill carries guards nothing in that project. The source
  summary counts each such name once, because the global config serves every project.
- Drinky locks each JSON store with an owner-only sibling `.lock` file, so two instances write in
  turn.
- `~/.drinky/state.json` remembers per project the last account and effort level, and the model of
  each account. It is machine-local, owner-only, and keeps the 1000 most recently changed projects.
  A repository is one project, keyed by its Git root. Drinky reads the file only at startup, so a
  change in one instance reaches the next start. Drinky reports a persistent save failure once, and
  the failure never stops the session.
- `HOME` must be set, because the config, the credentials, and the state live under `~/.drinky`.

## Keeping this file true

Write one short sentence per capability at the concept level: what a user gets, not how the code
spells it. When a capability lands, add its line and delete the `BACKLOG.md` entry. When one goes
away, delete the line. Merge a fact into a related line before you add a new one. A section past
roughly a dozen lines is two sections or too much detail.
