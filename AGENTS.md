# Drinky

Drinky is a dependency-free Zig coding agent that keeps the conversation in the terminal scrollback.

## Layers

`build.zig` declares the module graph, and a module imports only what the build names. `src` imports
every library. `lib/providers` and `lib/tools` import `lib/core`, and `lib/accounts` imports
`lib/core` and `lib/providers`. No other library imports another, and no library imports the app.

- `lib/terminal` reads the keyboard and paints the screen. It knows no model and no provider. It
  holds the device seam that the client reads and paints through, and `Tty` implements it.
- `lib/core` imports `std` alone. It holds the neutral conversation, the provider seam, the tool
  seam, the retry policy, and the session. It also holds the parts that the libraries share: the
  actor shell, the timeout race over `std.Io`, the compile-time check of an error set, and the
  plural suffix of a count. It names no vendor: an account is an opaque id, and a reasoning proof is
  that id with opaque payload bytes. The session is an actor. One task runs its command loop and
  owns its state. A client sends commands and receives events through a sink, and a turn runs as a
  child task. The actor shell holds the generic sink and the mailbox that starts, cancels, and reaps
  one child task.
- `lib/providers` implements the provider seam of the core. It holds the transport seam with its
  HTTP implementation, the SSE line engine, the JSON accessors, the credential seam, and one dialect
  per wire: Responses, Messages, and Gemini. A dialect builds the request, classifies a failure, and
  decodes the frames into the events of the core. A per-account switch is a dialect option.
- `lib/tools` implements the tool seam of the core. Its registry runs `read`, `write`, `edit`,
  `find`, `grep`, `bash`, and `describe_drinky`. It holds the skill guard that a call proves a skill
  against. An output is content for the model with the conditions and the measures that the client
  shows.
- `lib/accounts` holds the account table with its eleven rows, the credentials behind the credential
  seam, and the sign-in flows. It also holds the model catalog with the public metadata, the usage
  sources, and the state store. `Client` builds the provider of one row and reports its usage source
  before the stop of every reply. The account registry `Registry` runs a sign-in or a model fetch as
  a child task behind a command loop and a sink, like the session. A row is an index into the table.
- `src` is the client. `App.zig` holds the client loop, the input mode, and the key handling. A key
  becomes a command to the session or the account registry. An event becomes a change of
  `Screen.zig`, and `Screen.zig` paints the widgets that it holds. The client reads no session
  state, and `Choice.zig` holds the account, the model, and the effort that the client chose. `src`
  also holds the slash commands under `src/command/` and the instruction and skill discovery under
  `src/discovery/`. It holds the widgets under `src/ui/` and Herdr too. `headless.zig` answers
  `drinky run` and `drinky models` without a terminal. `Harness.zig` holds the setup that the client
  and the headless mode share: the config, the discovery, the system prompt, and the tools. `src`
  names no vendor, wire, or account row. It reads each such fact from `lib/accounts`.
- `src/ui/role.zig` maps a role to terminal colors. A widget names a role and writes no color of its
  own. `Message.zig` holds the severity that a notice and an event share.

A loop task lends state to its child task and touches none of it until the child ends. The child
returns its result with its end. A lock guards state that the tasks of two actors share.

## Interface

These rules outrank existing behavior and repository precedent.

- An exit ends one thing. An exit is Esc, Ctrl+C, or Ctrl+D. No exit reaches past the step, the
  page, or the turn that holds it.
- Drinky destroys nothing without a decision. If a key press has another meaning, Drinky warns
  first. A second press of the same key confirms the action.
- A failure is not a decision. Every draft and user message survives a failure.
- `user_note` is the role of a message that Drinky writes for the user. An event reports session
  state. A user box holds typed text alone.

## Code

- Drinky has no dependency but the Zig standard library. `build.zig.zon` names no package.
- Write no comment. A name or a test carries the intent, and a fact that matters goes into a test, a
  name, or the chat.
- Less code is better. Delete code without a caller. Add a seam, a pointer with a vtable in the
  shape of `std.mem.Allocator`, only when a second implementation or a test fake exists. A control
  that a user sets is no such code.
- Before you write a helper, search the modules that the build lets the module import. Move a second
  copy to the lowest module that both callers import.
- Production code holds no option, entry point, mode, or global that only a test uses. A test fakes
  the clock through an `Io` and the network through a `Transport`. A size cap stays an option when
  no test can reach its production value.
- Do not pass the implementation of a contract as `anytype`. A seam or a generic type states the
  contract.
- A branch that no production path reaches is an assert or `unreachable`. It holds no text for the
  user.
- Write a rule for each vendor, wire, or sign-in flow as an exhaustive switch over its enum.
- A seam, a callback, and a timed call declare their error set. Do not widen an error set to
  `anyerror`.
- The type that defines an event owns its `dupe` and its `deinit`. A sink takes `*const Event`,
  returns nothing, and copies what it keeps.
- A cancel must end every wait. Never run the work of a task in place of the task. When
  `io.concurrent` fails, report the failure. A zero window starts the task without a timer.
- The module graph is the architecture. A new module gets its row in `build.zig` and its line in the
  Layers section of this file.
- The development tools of the Zig code are the Zig toolchain alone. `zig fmt` formats every Zig
  file, and the check accepts no unformatted file.
- Follow `.agents/skills/zig-style/SKILL.md` for every Zig file.

## Tests

- Write a test for a contract at a module boundary, for a bug, or for a decision table.
- Write no test for what the compiler proves or for a framework.
- For a bug, write the regression test first and watch it fail. Then fix the bug.
- Test through commands and events with a hand-written fake. Use no network and no sleep. A test
  that needs a clock hands in an `Io` that controls it.
- A test takes `std.testing.io`. Build an `Io` only to set a limit or to control the clock.
- A fake that waits for a cancel waits on an event that no task sets. The test checks that the
  cancel ended the wait.
- A test that changes with every implementation change tests the implementation. Delete it or move
  it to the boundary.
- A test reaches a state through commands, events, keys, and options. It reads the state through
  public functions.
- A test calls a private pure function only when its input and its output are facts outside the
  code. A vendor date and its epoch seconds are such facts. A model before the catalog merge is not
  such a fact. Every other test calls the public function that gives the same fact.
- A test name states the behavior that its body checks.
- Put the shared test code of a module into its `testing.zig`. Put a private rig, fixture, or fake
  after the first test of its file.
- Zig runs a test only when an import chain from a module root reaches its file. The check counts
  the declared tests against the tests that ran, so an unreachable test fails the check.
- Note the runtime of each test binary when you start a feature, and compare it when the feature is
  complete. Investigate a repeatable increase of more than one second. A test that waits on the wall
  clock is the usual cause. Remove unnecessary waits and setup, not assertions or useful cases.

## Decisions

- Report every decision that the code does not force. A cut, a sentinel, a default, a rename, and a
  deferral are decisions.
- Write every deferral into `BACKLOG.md`, and name its trigger when an event must come first.
- A control that a user sets is never code without a caller. Never reduce its range.
- A recommendation names its evidence. A claim about a provider names the field, the endpoint, or
  the document that proves it.

## Review

A finding names a behavior defect, a rule in this file or a skill, or an error of a development
tool. Everything else is not a finding.

## Documents

`README.md`, `BACKLOG.md`, this file, and the skills under `.agents/skills/` are the documents.
Prettier formats every document, and `.prettierrc.json` configures it. `README.md` states the stable
product and stays concise. `BACKLOG.md` holds the open direction, and a line leaves it when its work
lands. `TODO.md` is its inbox, and Git ignores it. When a change alters a fact, update every
document and every text in the code that states the fact.

Write the documents and every text that Drinky shows to the user in ASD-STE100 Simplified Technical
English.

- Use active voice or a direct imperative. Put one topic in each sentence.
- Limit an instruction to 20 words and a description to 25 words.
- Use one noun for one concept. The type names are the vocabulary. Use at most three nouns in a
  chain.
- Keep the articles. Use `must` for a requirement and `can` for a capability.
- Do not use `should`, `may`, `might`, `would`, semicolons, or contractions.
- Prefer a finite verb to an `-ing` form.
- Use a complete sentence, sentence case, and end punctuation for an event, a result, or a required
  action. A label, a metric, or a control hint can be a fragment. Use a colon between a key and its
  value.
- Put a dynamic error name in a complete sentence:
  `Drinky could not open {path} because of error {name}.`
- Every text is timeless and impersonal. Use no name, no date, and no pointer to a session.

These rules do not apply to a literal technical identifier or a schema. Preserve the meaning and the
terminal-width limits when you reword a text.

## Name

Use `drinky` for a machine-parsed name and format it as code. Use `Drinky` for the product in prose
and in user-facing text, and never start a sentence with lowercase `drinky`. Reserve `DRINKY` for an
environment variable.

## Models vocabulary

- **author**: The slug before the slash in an OpenRouter model id, as in `openai` of
  `openai/gpt-5.6-sol`. OpenRouter keeps `provider` for the company that serves a request.
- **public metadata**: The price, window, effort, thinking, and tool facts of a model. Drinky stores
  them in `metadata.json`. Never write **OpenRouter** for that source.

`OpenRouter` names the provider alone.

## Accounts vocabulary

An account identifier reads `vendor-product`, as in `anthropic-plan`. A `-key` suffix marks a
credential that an environment variable holds or names, as in `anthropic-api-key`. An identifier
without it signs in through an OAuth login. The `id` field of a table row is the only spelling of an
identifier. A model under an account reads `account/model`.

- **vendor**: The `Account.Vendor` tag: `anthropic`, `openai`, `xai`, `openrouter`, `deepseek`, or
  `google`.
- **plan**: A consumer subscription, as in Claude Pro or Max, ChatGPT, and SuperGrok.
- **api**: The developer API of the vendor, billed per token.
- **cloud**: The cloud platform of the vendor, as in a Google Cloud project on the Agent Platform.
- **Agent Platform**: The short form of Gemini Enterprise Agent Platform, the Google Cloud platform
  that was Vertex AI. Name it in full with `(Vertex AI)` on the first mention of a document. Never
  write **Gemini Enterprise** alone, because that is another Google product.

## Checks

Run `sh scripts/check.sh` after a change. CI runs the same script and nothing else. The script
builds the binary and checks the format of the Zig code and of the documents. It fails on a code
comment and on a Zig line over 100 columns. It runs the tests with the reachability count. Its
summary prints the runtime of each test binary. The document check needs `npx`, which fetches
Prettier once into its cache.

`zig run scripts/comment_scan.zig -- --fix build.zig build.zig.zon src lib scripts` removes every
comment, and `zig fmt build.zig build.zig.zon src lib scripts` formats the Zig code.
`zig run scripts/width_scan.zig -- build.zig build.zig.zon src lib scripts` lists every Zig line
over 100 columns and wraps none, because `zig fmt` never wraps a line. `zig build unicode`
regenerates the Unicode data, its test corpus, and its license notice. It uses the network, so it
never joins the default build.

A rule that a tool can check belongs in `scripts/check.sh`, because an editor setting enforces
nothing. Add a check to `scripts/check.sh` for a problem that occurred.
