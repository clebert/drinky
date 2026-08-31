# FEATURES.md

What Drinky does, one short sentence per capability. It is an overview, not a specification. Tests
define behavior. Git history preserves implementation decisions, and `BACKLOG.md` holds planned
work.

Drinky is a terminal coding agent. You type a prompt. The model reads, searches, writes, and edits
files in the working directory while the conversation streams inline into your scrollback. It talks
to Anthropic and OpenAI, through either a subscription login or an API key.

## Talking to it

- A prompt runs a turn to completion: stream a reply, run its tools, feed the results back, repeat.
- At most 1000 tool rounds per turn, as a guard against a runaway loop.
- Read-only tool calls in one reply run in parallel. A mutating call — write, edit, or bash — runs
  alone, in call order.
- Enter during a turn queues a steering message that folds into the run at the next tool round.
- Ctrl+P pulls messages the turn has not picked up yet back into the editor to keep editing.
- Steering left in the queue when a turn completes returns to the editor for review.
- Esc or Ctrl+D cancels a turn and keeps the draft. Esc with a draft warns first and cancels on the
  second press. Ctrl+C clears a draft in the editor first, and cancels only on an empty editor.
  Canceled or failed turns keep finished rounds, drop the in-flight tail, and return uncommitted
  text to the editor.
- A refused send starts no turn, so the editor keeps the typed line for the next Enter.
- Drinky records a tool call left unfinished as an error in the history. The transcript shows it as
  a failed call, so a canceled mutation is never hidden.
- Timeouts and transient failures retry the whole request, clear the partial reply, and record each
  retry cause.
- A failed turn that committed work shows a `Failed turn` caption above the editor. Ctrl+N asks the
  model to continue, and Esc discards the retry. The attempt never takes the editor text. The start
  of any turn drops the retry. Drinky wrote the attempt message, so its line takes the user color.
- A reply cut short by the output cap is kept, and reported as cut short.
- Model-side failures — a refusal, an empty reply, the round cap — read as a plain sentence rather
  than an internal error.
- Reasoning streams into its own block, with a blank line between its parts. Encrypted reasoning
  shows as `[redacted thinking]`.

## Tools

- The model gets seven tools: `read`, `write`, `edit`, `find`, `grep`, `bash`, and
  `describe_drinky`.
- **read** — page a UTF-8 file from a 1-indexed line offset, 2000 lines or 50 KiB per call, with a
  next-offset hint.
- **write** — create or overwrite a file atomically.
- **edit** — replace one exact span, which must occur exactly once.
- **find** — glob search under a directory, sorted by path, 1000 hits by default.
- **grep** — literal search that prints `path:line:text` under a directory or in a single named
  file, with glob and case filters, 100 hits by default.
- **bash** — run a shell command in the working directory, preserve combined stdout and stderr
  order, and return a bounded tail. A non-zero exit is reported. Output caps and the timeout are
  configurable, and the timeout is also settable per call. Every command runs under a timeout from 1
  second to 1 hour, so neither the config nor a call can lift the limit. A configured deny list
  refuses a command that contains one of its patterns, and the refusal names the pattern. Each
  command runs without a controlling terminal, so it cannot take terminal ownership from Drinky.
  Drinky has no web tool, so a network request also runs through bash.
- **describe_drinky** — describe the harness itself, so the model answers a question about Drinky
  from the tool and not from memory. One section per topic: every slash command, `config.json` with
  every key, the key bindings, the discovery rules of the instruction and skill files, and the
  repository. It reports no current value, because it reads no file. The command section comes from
  the command registry and the key bindings from the intro line, so neither can drift.
- A configured glob can require a skill. When a tool first touches a matching file, Drinky sends the
  whole skill file into the turn at the next tool round, and the transcript names it. A read is
  never refused. `write` and `edit` refuse until the whole skill file stands in the conversation,
  word for word, so the next try needs no read of its own.
- That proof is the conversation itself, so a resumed conversation proves itself. A read of its
  `SKILL.md` and a `/skill:name` line both count as the proof.
- Globs use `*` and `?` within a path segment and `**` across segments.
- Searches skip common noise directories: version-control stores, dependency directories, and build
  caches. A path that ends with a skipped directory name searches it fully. An empty search names up
  to three skipped noise directories, except version-control stores.
- `find` and `grep` run under a fixed 10-second timeout that neither a call nor the config changes.
  A search checks the clock between filesystem steps.
- A stopped search keeps the matches it found, and a stopped command keeps the tail of its output.
  Each one states the stop, so the model can narrow the next call on evidence.
- Binary files are skipped, oversized files are refused, and every result says when a limit cut it
  short.
- A failing tool returns an error the model can read, and a cancel stops it at once.

## Models & reasoning effort

- Drinky compiles no model in. Every model, limit, effort level, and price comes from the provider
  and from OpenRouter, and the user fetches that list from `/model`.
- No request runs at startup. A fetch runs when the user asks for one, and its result is cached in
  `models.json` per account and `metadata.json` per vendor.
- A fetch states its wait in the footer, because the interface stops until the provider answers.
- Drinky records a transcript event when a fetch has something to report, so a report of several
  sentences reads whole.
- The provider wins every field it states. Only OpenRouter prices a model, and for Anthropic only
  OpenRouter states whether the reasoning can stop.
- A model that no source describes never reaches the picker, and a Codex model that the backend
  hides stays hidden.
- An OpenAI API key states no model fact, so that account offers no model until OpenRouter describes
  one.
- Anthropic takes the output cap from the request, so a model that states no limit runs at a low
  default. Both model pickers mark such a model, because that default can cut a reply short.
- Reasoning effort runs `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, and `ultra`. The
  level states the intention of the user. Therefore `/effort` offers every level at every time, with
  an account or without one and with a model or without one.
- Each request resolves that level against its model, and every resolution is silent. A level the
  model does not name folds to the nearest one it names, which is a spelling that the provider
  knows. A tie between a lower and a higher level takes the lower one. A model that takes no level
  drops the level.
- An account with no model shows `No model` in the warning color, and a send refuses with the
  command that fixes it.
- A restart resumes on the account, model, and effort level this project used last. A model the
  account no longer offers drops in silence.
- Each account keeps the model it ran in this project. A switch, a login, and a restart return to
  it, and an account whose list is not cached returns to none.
- `/model` refuses while signed out, since the status line hides the model then. `/effort` stands,
  and the next sign-in adopts the level it set.
- Session cost accumulates at public rates and counts a canceled turn's billed usage. Every cost
  figure of Drinky reads `~$0.42`, and the tilde marks it as an estimate.

## Accounts

- Anthropic and OpenAI, each reachable as a subscription account or a platform API-key account.
- The Anthropic Console account adds an OAuth login that mints and stores a platform key.
- Startup resumes on the account this project used last, else takes the first authenticated one and
  prefers a signed-in login over an API key.
- With no account at all, the login picker opens by itself.
- While signed out, Drinky refuses a message with a prompt to `/login`.
- Reasoning replays only to the account that produced it. A login, a logout, or a credential
  replacement discards that account's reasoning, cache-hit rate, and allowance. A review workflow
  parks conversations, and each parked one discards the same reasoning.
- Drinky shows only the conversation that the next request carries, so a change that drops stored
  reasoning repaints the screen and the scrollback without it.
- A conversation switch swaps the agent, its history, and the interface together, so the worker and
  the screen never disagree or mix two conversations.

## Signing in

- OAuth login uses PKCE (S256) with a loopback callback, and opens the system browser.
- The Anthropic Console login trades its grant for a minted platform key, stored like a token.
- When no browser opens, the printed URL still works, and the callback waits five minutes.
- When the browser cannot reach the local callback, a paste of the URL from its address bar
  completes the same login.
- The browser lands on a plain "Drinky received authorization. Close this tab." page.
- Subscription tokens and the Console key live in the owner-only `~/.drinky/auth.json`, one entry
  per account, saved atomically.
- Expired access tokens refresh and re-save automatically.
- A busy credential store keeps a refreshed token in memory and retries its save before the next
  provider request.
- Anthropic subscription logins save stable account and organization IDs from the OAuth profile.
- If another Drinky instance saved a token for the same known principal, Drinky takes that token.
  The refresh happens only when the stored token has expired too. A different or unknown principal
  stops before the model request.
- A request that the provider rejects with 401 renews the credential once and repeats it. The
  renewal takes the token that another instance saved, or it refreshes the token in memory. An
  API-key account holds one fixed secret, so a rejected request ends the turn.
- If another Drinky instance saves a replacement before removal, Drinky reloads it and keeps the
  account active.
- Without a replacement, Drinky removes the rejected credential and moves the session to another
  account or the login picker.
- A token failure that is not a rejection ends the turn, names the reason, and keeps the account
  signed in.
- A login whose save fails stays signed in until Drinky exits, and says so.

## Slash commands

- **/help** — pick a command from an alphabetical list. Each row holds the name of one command and a
  short summary. Enter runs the picked command at once, and a bare `/` opens the same list. Esc
  returns to the list from any picker that a row of it opened, however deep.
- **/model** — switch account and model together, from the next turn on. The picker steps through
  the provider, the account, and the model, and it skips a step that offers one row alone. The model
  step leads with a row that fetches the list of that account, and the choice that follows a fetch
  cannot go stale.
- **/effort** — set the reasoning-effort level, from the next turn on. The picker lists every level,
  and the model of the turn resolves the picked one.
- **/login** — sign in, switch to an account already signed in, or name the API key to set.
- **/logout** — drop a signed-in account's credentials and hand the session to another account.
- **/review** — review every pending change from `HEAD` in bounded rounds: a fresh reviewer finds
  defects, a persistent judge validates and settles, and a fresh fixer applies the accepted
  findings.
- **/new** — clear the conversation, usage stats, and steering without changing its configuration.
  The next paint drops the terminal scrollback, so the empty conversation starts on a clean screen.
  The intro line returns with it, and the startup counts line does not.
- **/system** — inspect the complete provider-neutral system prompt as rendered Markdown in a
  scrollable full-window page. `M` toggles its exact source.
- **/colors** — preview ANSI slots 0 to 15, colored backgrounds, default styles, message boxes, text
  roles, and input frames in a scrollable full-window page.
- **/skill** — pick one of the discovered skills. Each row holds the first sentence of the skill
  description. Enter writes its `/skill:name ` line into the editor, so a task can follow. `/skill:`
  opens the same list.
- **/skill:name** — load a discovered skill explicitly, record one head line that reads
  `Skill: name · File: path`, and record any trailing text as its task in a user box below it. The
  head takes the user color and no box.
- Every line that starts with a slash is a command line, so Drinky reads it locally first and sends
  it only after a confirmation. A command that takes no argument refuses text after the name, as in
  `/new must clear the scrollback`. `/skill:name` is the one exception, because it takes its task as
  trailing text.
- Drinky keeps a refused line in the editor, so its text survives an unknown name or unwanted text
  after the name. A command that ran clears the editor. Only a `/skill:` line carries user text, and
  that text moves into the turn as the task.
- Drinky always offers a way out for a refused line: the footer offers `Enter: Send as a message`,
  and during a turn `Enter: Queue as a message`. The next Enter alone sends the line as typed. Every
  other key cancels the offer and its row. The end of the turn cancels them too, and the line waits
  in the editor for a new offer.
- Successful model, effort, login, logout, and account changes are recorded as transcript events.
- A local command failure temporarily replaces the footer until the next user action.
- A command that can run stays in the editor while a turn runs, and one notice names the command and
  the restriction. The next Enter runs it once the turn ends.

## Reviewing changes

- `/review` needs a Git worktree, and its target is every staged, unstaged, and untracked change
  from `HEAD`. Drinky itself runs no Git command and never touches the index.
- A role whose remembered model the account no longer offers names `No model`, and the start row
  refuses until the user picks one. Drinky substitutes no other model for that choice.
- The model step of a role leads with the same fetch row as `/model`, so a role reaches an account
  that no fetch ran for.
- The setup picker chooses the account, the model, and the effort level of each role, and the
  project remembers a confirmed choice. An unchosen role inherits the active session configuration.
  A role choice never replaces the project choices of the main conversation.
- Every role runs in its own conversation with the shared instructions, skills, and tools. The
  reviewer and the judge work under nonmutation prompts, and the fixer changes files like a normal
  turn.
- Each generated request records one head line that Drinky wrote, such as
  `Request: Fixer · Round: 2 of 10 · Pass: 1`. The request itself stays out of the transcript, like
  a loaded skill file and a retry request. A caption above the editor names the round, the active
  role, and the controls.
- The editor and the messages of the user are the brake. A phase runs unattended while the editor
  holds no text and the user sent nothing to the active role. An unattended phase starts the next
  phase by itself, and an attended phase holds at its boundary, so the reply waits for a read before
  the role resets. Enter steers the active role, and a message that reaches the reviewer or the
  fixer gets one judge copy, so a report never reads as a user instruction.
- Each reviewer and fixer report resolves every message of the user as accepted or dismissed with a
  reason. The judge checks each resolution against its verbatim copy.
- A mid-turn Ctrl+N makes a steered phase unattended again, so an empty editor lets it resume by
  itself. The running caption marks the next boundary as `Resume: Auto` or `Resume: Hold`, live
  against the editor and the messages. The held state takes the warning color, and every control row
  names Enter only while the editor holds something to send.
- A message that the user sends at a hold runs as its own turn under the round caption. A failure
  that commits nothing returns the text to the editor and the workflow to that hold.
- Every role reply must start with its marker line: `Findings:`, `Decision:`, or `Applied:`. A
  marked reply is a report, and every report is one of three kinds. A handover enables a transition
  to another role. A dispute is a handover from the fixer back to the judge. Only the judge can
  issue a question about an open product choice, and a question waits for the decision of the user.
  A settlement declares the review complete and waits for the user to finish it.
- The judge decides wording and technical matters. It asks the user before it selects interaction
  logic, observed behavior, a key binding, a default, a workflow step, or the interface shape.
- Each report leaves one pending outcome: a role transition, a required answer, or a review finish.
  A handover also carries what the next role needs, so Drinky stores it until that request goes out.
  A rejected dispute gets one more fixer pass while the pass budget has one left.
- The judge can name one closing fix on its decision line. Each closing pass returns directly to the
  judge, which verifies the fix and settles without a fresh reviewer round.
- A pass budget holds two fixer passes, and a closing fix spends the same two. The judge asks the
  user when both passes fail to complete the fix.
- A committed message to the judge refills a spent pass budget in the same reviewer round. Each
  later message can refill another spent budget, while an uncommitted message changes nothing.
- Drinky holds the review when the judge asks for another fix before a user message refills the
  spent pass budget.
- A message that reaches the active role consumes or invalidates the outcome of its previous report.
  It makes a handover stale, answers a question, or challenges a settlement. The role must produce a
  fresh report before the workflow proceeds.
- If a turn fails after the message commits, the message survives and the previous outcome stays
  discarded. The retry continues that role turn. If the turn commits nothing, the role never saw the
  message, so the previous report and its outcome remain valid.
- An unmarked reply is no report. A role that received a message of the user can answer in prose,
  and that answer sends no correction request. Without such a message, Drinky asks for the report
  once. A draft can brake that correction request before it goes out.
- A phase without a report holds in the role context, and no key continues the workflow there. The
  user asks the role for a report, and the next marked reply supplies a fresh outcome.
- The `review.rounds_max` ceiling defaults to ten and bounds unattended rounds. A fresh judge
  handover at the limit offers one added round, and that round applies the handover to the fixer.
- A failed role request holds the workflow: Ctrl+N retries the committed work or resends the request
  while one of the two stands behind it, and Ctrl+S reopens the setup of the failed role. A
  credential replacement and a credential rejection end a role turn in that same hold, and neither
  one changes a role choice.
- A user turn that starts from a failure hold returns there when canceled, so the failed generated
  request remains available for retry.
- Esc, Ctrl+C, and Ctrl+D cancel a running role turn. The cancel ends that turn alone, and every
  role conversation survives it. A worker that beats the cancel keeps its reply, and the phase then
  holds at its boundary.
- The same three keys end the workflow at a hold. At an unfinished hold each one warns first, and
  only the second press of the same key ends the review. The settlement over an empty editor ends on
  one press, and a draft there returns the warning for Esc and Ctrl+D. Ctrl+C clears that draft
  first. Neither Ctrl+C nor Ctrl+D quits Drinky while a review runs.
- The end restores the main conversation exactly and records one completion event with the rounds,
  the fixer passes, and the review cost. An end at the settlement reports it as settled.
- The end at the settlement moves the judge report into the editor as one `[Review: settled report]`
  marker, below an existing draft. The user sends that report to the main conversation, or deletes
  it with one keystroke. The transcript keeps no copy of it.

## Providers

- Streams from Anthropic's Messages API and OpenAI's Responses API over SSE.
- A reply enters the conversation only once the provider reports it complete.
- Prompt caching is always on: explicit breakpoints for Anthropic, the automatic per-session cache
  for OpenAI.
- Reasoning is requested summarized at the resolved effort, and replayed verbatim on later turns.
- Anthropic Subscription and Anthropic Console requests carry the Claude Code client identity. A
  plain API key goes straight to the platform API.
- Every Anthropic request asks for the input of a tool call as the model writes it.
- Requests time out after 30 s to the response head. A streamed event must arrive within 60 s for
  Anthropic and 300 s for OpenAI, whose stream is silent while the model reasons. Keepalive filler
  does not count as progress, and all three windows are configurable.
- A failed request retries up to 3 times with 500 ms–16 s backoff and honors a server's retry-after
  hint.
- A response that asks for a wait longer than the backoff cap ends the request. A spent OpenAI plan
  states its reset in the error body, so Drinky reports it after one try.
- A stream frame that names a call or a block other than the open one ends the turn without a retry.
- A reply that names a model other than the requested one records a durable transcript event with
  both names, so a fallback or a proxy substitution never passes silently. An unchanged fallback
  reports once per turn.
- Drinky knows no rate for a model it did not request. A switched reply therefore carries no price,
  and the session total counts nothing for it.
- A failed request reports the message from the provider JSON error body, not the raw bytes. A
  failed response head names its status too. For a spent OpenAI subscription, the message names the
  plan and the wait.

## The interface

- The conversation renders inline into the normal screen buffer and real scrollback. Temporary
  full-window pages use the alternate screen and restore the conversation on close.
- Every notice above the input wraps. It breaks at a `·` separator first. A hint too wide for one
  row keeps that row and marks its cut. A sentence breaks between words and keeps its tail.
- One semantic caption heads the intro line, a picker, an editor state, and a full-window page. Its
  accent title and muted controls share one row when they fit. At the first overflow, the title
  takes one row that never wraps and cuts with one `…` when too wide. The control segments wrap at
  their `·` boundaries under it, and a segment alone on a row that still overflows cuts with `…`.
- A caption can carry one state segment between its title and its controls. The segment takes its
  own color and packs before every control, so it survives them on a narrow row.
- A row bound caps each caption: one row for a page, three for a picker or an editor state, none for
  the intro line. A control segment past the bound drops whole and leaves no mark. A one-row caption
  keeps the title and the longest prefix of whole segments, so the title survives longest.
- An element whose height must stay stable keeps one row and marks its cut with one `…`: a tool box,
  a picker option, a code row, and the footer notice. The status line shortens its fields and then
  drops them instead.
- A page asks the terminal to send an arrow key for a wheel notch. A trackpad then scrolls the page,
  and a drag still selects text.
- Apple Terminal has no such mode. A page there takes mouse reports and the legacy alternate screen.
  A trackpad scrolls it, but a text selection needs the Fn key. The close reprints the conversation
  window.
- A full-window page scrolls with the arrow keys, PgUp/PgDn, and Home/End. Its fixed caption names
  the page and its controls. Esc, Ctrl+C, and Ctrl+D close it, so an exit attempt always works.
- Repaints only the rows that changed, atomically. A shrink or height change keeps native scrollback
  intact and can leave blank rows below the interface. A width change or a change above the viewport
  reprints the window.
- Drinky redraws the newest eight window heights of the conversation, and the configuration sets
  that count. Older rows rest in the native scrollback. A page more keeps more of the conversation
  live and costs more work in every frame.
- Each transcript block keeps the rows it painted at the current width, so a frame renders the
  markdown of the block that changed alone. A block that leaves the window drops those rows again.
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
  glyph, so a terminal copy holds the text alone. Both blocks drop the blank rows that they end on.
- A link becomes a clickable terminal hyperlink when a click can open its target, and a bare URL
  links to itself. Any other target, such as a relative path, shows its URL as text.
- A pipe table draws as a box grid that fits the window and keeps the indentation of its source. The
  alignment colons parse but do not align. A long cell wraps inside its column and grows the grid
  row. A run of clusters wider than the column drops behind one `…`. A table stays plain text when
  the window is narrower than its smallest grid.
- A tool box that states measures wraps no line. Each line takes one row and marks a cut with one
  `…`, so the rows a call occupies follow its state and never the length of its arguments. A box
  that holds the sentence of a failure wraps instead.
- The head row of a tool box paints the name of the tool bold, so the tool stands out from the keys
  around it.
- A call names what it acts on as `File:`, `Pattern:`, or `Command:`. A row holds the tool and its
  subject alone, with each run of whitespace collapsed to one space. A tool row shortens a path the
  way `Skill:` does: relative to the working directory below it, `~` for the home directory, and the
  whole path when it sits under neither.
- While the model streams the arguments, the call reports `Received:` with the bytes that arrived
  and `Status: Streaming`. The count measures the arguments the model has sent. A call can wait,
  because a later call streams or an earlier call runs. It then keeps its count and reports
  `Status: Queued`. A window too narrow for the row cuts the status and keeps the count.
- A running command or search adds a row with its elapsed time and timeout. A command names its
  clamped timeout, and a search names its fixed timeout. Every other tool runs under no timeout, so
  its box keeps one row.
- A finished call keeps its call row and one line below it: a line of measures, or the sentence of a
  failure. A call with nothing to state, like `describe_drinky`, keeps the call row alone.
- `read` reports `Lines: 42`, or `Lines: 594–648 of 2868` when a window cut the file. `write`
  reports the lines it wrote, `edit` reports `Lines: -12 +8`, and `find` and `grep` report
  `Time: 420ms · Matches: 3`. Each line adds one qualifier for every bound that cut the result, such
  as `Output: Truncated` or `Search: Timed out`.
- `bash` reports `Time: 420ms · Exit code: 1 · Lines: 3`, and it names a timeout or a kill as
  `Status:` in place of the code. A stopped command keeps the tail of its output below the same
  measures. A non-zero exit takes no `Error:` prefix, because the line names its own state. The box
  still paints the failure, and the model still reads the result as one.
- Every span in the interface takes one shape: whole milliseconds below a second, then seconds to
  one decimal, then whole minutes and seconds.
- Every box row starts at the first column, like an editor row and a reasoning row, so a terminal
  copy of them lines up. An indent appears only where it groups rows under a head, as in a markdown
  list.
- One heavy activity segment moves across both open input separators in a loop and grows as progress
  goes quiet without adding a layout row.
- Drinky blinks the input caret while a turn runs, because a terminal holds its own cursor solid
  under a continuous repaint. An edit restarts the blink, so the caret stays visible while the user
  types.
- Pending steering shows its message count and Ctrl+P control in the editor caption. Its content
  becomes one user message once consumed.
- The bottom line shows `directory (branch)`, context fill, cost, quota, and cache-hit rate on the
  left, and `model (account) · Effort: level` on the right. At most one temporary notice replaces it
  until the next user action. The notice keeps one row, so it never moves the editor above it. A
  warning and a failure carry their color, and an information notice reads at the normal intensity.
- The context gauge holds what the last committed reply measured. Empty history is exactly 0.
- The gauge reads `Context: Unknown` while the next request renders that history in another way. A
  model switch changes the tokenizer. An account renders the whole prompt around the history, so
  every account switch hides the count. An effort change hides it only when it stops a stored
  reasoning block from replaying. A switch back to the measured setup shows the count again.
- The gauge reads `Context: 206k`, the tokens alone with no share and no color, when no source
  states the context window of the model.
- The cache-hit rate holds the last request of the active account, model, and resolved effort. A
  change to any of the three hides it in the turns that follow. Two effort levels that resolve to
  one wire form share the cache, so the rate survives that change. A canceled attempt still rates
  its own prompt.
- A subscription window reads `5h: 12% (53m)`: the share it used, and the wait until it starts
  again. The wait shows one unit and rounds down: `53m`, `22h`, `6d`. The shortest window prints
  first, whatever slot the response head used.
- Both subscription backends state the allowance in the response head. OpenAI states the wait in
  seconds, and Anthropic states an absolute reset, which Drinky turns into the same wait.
- The quota and the cache-hit rate show while a turn runs. Each one measures one request, and only a
  response head states the truth.
- The context gauge and each quota window take the warning color from 75% used, and the error color
  from 90% used. The configuration sets both shares. A color on this line always means pressure. The
  color reads the share that the field prints, so the number and the color always agree.
- The model name and the effort value take the normal intensity in the muted line, so the two
  settings that the user changes stand out.
- A narrow window shortens the directory, branch, context gauge, and both countdowns before it
  removes parts, and it always keeps the context gauge. The measurements of one request go next,
  longest window first, and the session cost outlives them. A bracketed detail goes before the head
  that carries it. The account goes before the model, and the branch goes before the directory.
- The branch comes from the `HEAD` file of the repository, never from the git command. Drinky
  re-reads it when a turn starts and when one ends.
- A picker is a single-choice list that tags the current value. Enter confirms, and Ctrl+C or Ctrl+D
  cancels from any step. The selection rolls over at both ends of the list.
- A selection can open a second list, which replaces the first one. Esc returns to the list that the
  selection came from, so one Esc per list leaves the command, and Esc at a first list cancels. The
  key hint states which of the two the Esc does. Drinky skips a list on the way back that it skipped
  on the way down. Drinky reopens each list with the row and the window that the user left.
- Every option holds one row. Drinky cuts a row that is too wide for the window and marks the cut
  with one `…`. The cut takes the option text, so the tag of the row stays.
- The picker caption stays outside the scrolled window, so the picker never scrolls it away.
- The open input area grows to about a quarter of the screen and labels hidden rows "↑ Hidden: N"
  and "↓ Hidden: N".
- The terminal supplies every color and the muted intensity. Drinky uses the default colors, ANSI
  slots 0 to 15, faint, and reverse video. A filled box keeps the terminal background for its text.
  A label or a glyph marks every state, so color is never the only signal.
- A line that reports a message that Drinky wrote for the user takes the user color and no box. A
  typed message cannot forge it. The head of a loaded skill and the line of a retry attempt read
  this way. A muted event reports the state of the session instead.
- Model, tool, and user text can never emit escapes: controls and malformed UTF-8 render as
  replacement characters.

## Editing & text

- Enter sends, Shift+Enter or Ctrl+J makes a newline, Esc cancels, Ctrl+C clears, Ctrl+D quits. An
  intro line shows those bindings at launch under the `Drinky` title and closes with
  `/help: Commands`. It wraps without a row bound, so a narrow window keeps every hint.
- A second Ctrl+C within 500 ms quits, as does Ctrl+D on an empty editor or a closed stdin. Ctrl+D
  with a draft warns that the quit discards the draft, and quits on the second press.
- The caret moves by grapheme cluster, by wrapped row with a sticky column, and to the start or end
  of the input.
- A paste over 10 lines or 1000 bytes collapses to a `[Paste #N: L lines]` marker.
- A marker moves, deletes, and counts as one unit, and submits its exact bytes.
- Decodes the Kitty keyboard protocol and traditional escape sequences, including ones split across
  reads.
- A terminal without the Kitty protocol reports Escape as one byte. That byte becomes the Escape key
  after a 50 ms wait, and a control byte right after it stays a key of its own.
- An exit key that returns the session to the prompt drops the rest of its input chunk. Esc and then
  Ctrl+D closes the page or cancels the turn, and never quits Drinky. Enter and typed text keep
  every key behind them.
- A bracketed paste arrives as one unit, with controls and escapes inside kept as literal payload.
- Unrecognized sequences and stray control bytes are ignored and never leak into the text.
- Text is segmented per UAX #29, so an emoji family, a flag, or a Hangul syllable stays one glyph.
- Drinky asks the terminal for grapheme cluster processing at startup. The cursor then advances one
  grapheme cluster at a time, the same as the Drinky measure of a row. An older terminal ignores the
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
  also ranks the instruction sources it carries, so the model knows which one wins on a conflict. It
  names each path pattern that requires a skill, so the model knows the rule before it acts and
  knows that Drinky sends the skill file on the first touch. It names each bash deny pattern, so the
  model avoids a refused command.
- Drinky loads exact-case `AGENTS.md` files in path order, from the Git root down to the working
  directory. Outside a repository it reads that directory alone.
- Drinky looks for skills in `~/.agents/skills/`, and in `.agents/skills/` from the Git root down to
  the working directory. Outside a repository it looks in that directory alone.
- Drinky searches each skills directory at any depth for `SKILL.md` and follows directory symlinks.
  On a name clash a project skill has priority over a user skill, and the closest copy has priority
  over a copy farther up. Drinky advertises each skill name and description, and loads the
  instructions on demand. A skill file above the window of one `read` call, 2000 lines or 50 KiB, is
  skipped and reported, so one call always shows the model a whole skill.
- Drinky loads the user instruction files that `config.json` names, in order.
- One dense startup line counts the instruction files that Drinky loaded, the skills that it found,
  the user skills that a project skill replaced, and the required skills that this project does not
  carry. A count of zero stays out of the line. Only a skipped file gets its own line, and `/system`
  shows every counted path.
- User and project instructions obey one policy: a regular UTF-8 file, with content, no NUL byte,
  and at most 32 KiB. Each source loads at most 32 files and 64 KiB, and one file loads once even
  when two paths or a symbolic link reach it. Drinky reports what it skips.
- `~/.drinky/config.json` is optional: paths for user instructions, request and bash limits, a bash
  deny list, a default effort level, the review round ceiling, the skills that a path requires, and
  the interface settings. Drinky reads it only at startup, so a change applies at the next start.
- It holds no secrets. API keys come from `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`.
- An unknown effort level and an interface value Drinky cannot use are reported. A key that Drinky
  does not know is reported too, so a typo never looks like an applied setting.
- A required skill whose name no discovered skill carries guards nothing in that project. The
  startup line counts each such name once, because the global config serves every project.
- The configuration section of the `describe_drinky` document is generated from the struct that
  parses the file, so a new key that carries no description fails the build and the section cannot
  drift.
- JSON store writes use owner-only sibling `.lock` files to coordinate Drinky instances.
- `~/.drinky/state.json` remembers per project which account and effort level Drinky used last, the
  model of each account, and the review role choices. It is machine-local, owner-only, and keeps the
  1000 most recently changed projects. A repository is one project, keyed by its Git root.
- Drinky reads that file only at startup, so a change in one instance reaches only the next start. A
  persistent save failure is reported once and never stops the session.
- `HOME` must be set, since the config, the credentials, and the state all live under `~/.drinky`.

## Keeping this file true

One short sentence per capability, at the concept level: what a user gets, not how the code spells
it. When a capability lands, add its line and delete the matching `BACKLOG.md` entry. When one goes
away, delete the line. Merge a fact into a related line rather than add a new one. If a section
passes roughly a dozen lines, it is either two sections or too much detail.
