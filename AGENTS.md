# Drinky

Drinky is a dependency-free Zig coding agent that keeps the conversation in the terminal scrollback.
A Telegram bot can drive the session from its chat while the terminal shows the work.

## Reference

The Swift implementation of Drinky is a reference for design alone: what a core owns, what crosses a
layer, and how a client stays a client. Its names, its files, and its feature set carry no
authority, because it serves fewer providers. Read it for a shape, and copy no code.

## Layers

`build.zig` declares the module graph, and a module imports only what the build names. `src` imports
`lib/terminal` and `lib/ai`. The two libraries import neither each other nor the app.

- `lib/terminal` reads the keyboard and paints the screen. It knows no model and no provider.
- `lib/ai` runs the agent: the providers, the accounts, the tools, the skills, and the commands.
- `src` is the client: the app loop, the screen model, the widgets, the Telegram remote, and Herdr.
- The remote controller reports through its sink. It depends on neither `src/Session.zig` nor
  `ai.Agent`, and the client translates what it reports.
- `src/ui/role.zig` maps a role to terminal colors, and `src/remote/html.zig` maps a role to the
  look of a Telegram message. A widget names a role and writes no color of its own.

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
- Write no comment. A `zig fmt` directive is the one exception. A name or a test carries the intent,
  and a fact that matters goes into a test, a name, or the chat.
- Less code is better. Delete code without a caller. Add a seam, a pointer with a vtable in the
  shape of `std.mem.Allocator`, only when a second implementation or a test fake exists. A control
  that a user sets is no such code.
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
- A test that changes with every implementation change tests the implementation. Delete it or move
  it to the boundary.
- Zig runs a test only when an import chain from a module root reaches its file. The check counts
  the declared tests against the tests that ran, so an unreachable test fails the check.
- Note the runtime of each test binary when you start a feature, and compare it when the feature is
  complete. Investigate a repeatable increase of more than one second. A test that waits on the wall
  clock is the usual cause. Remove unnecessary waits and setup, not assertions or useful cases.

## Decisions

- Report every decision that the code does not force. A cut, a sentinel, a default, a rename, and a
  deferral are decisions.
- Name the trigger of every deferral, and write the deferral into `BACKLOG.md`.
- A control that a user sets is never code without a caller. Never reduce its range.
- A recommendation names its evidence. A claim about a provider names the field, the endpoint, or
  the document that proves it.

## Review

A finding names a behavior defect, a rule in this file or a skill, or an error of a development
tool. Everything else is not a finding.

## Documents

`README.md`, `BACKLOG.md`, this file, and the skills under `.agents/skills/` are the documents.
Prettier formats every document, and `.prettierrc.json` configures it. `README.md` states the stable
product and stays concise. `BACKLOG.md` holds the open direction, and a line leaves it when its
trigger fires. `TODO.md` is its inbox, and Git ignores it.

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

## Remote vocabulary

- **bot**: The Telegram account with its token.
- **chat**: The private exchange of Telegram messages between the bot and the user.
- **Telegram**: The source of messages, updates, and actions.

Reserve **conversation** for the model conversation that `/new` clears. Never write **bot** for a
message from the user, because a bot message reads as a message that the bot wrote.

## Models vocabulary

- **author**: The slug before the slash in an OpenRouter model id, as in `openai` of
  `openai/gpt-5.6-sol`. OpenRouter keeps `provider` for the company that serves a request.
- **engine**: The label of the weights behind a request id. A DwarfStar picker row shows it as
  `Weights:`. Empty when no source states one.
- **public metadata**: The price, window, effort, thinking, and tool facts of a model. Drinky stores
  them in `metadata.json`. Never write **OpenRouter** for that source.

`OpenRouter` names the provider alone.

## Accounts vocabulary

An account identifier reads `vendor-product`, as in `anthropic-plan`. A `-key` suffix marks a
credential that an environment variable holds or names, as in `anthropic-api-key`. An identifier
without it signs in through an OAuth login. The local `ds4` account is the exception: it has no
product tier and no `-key` suffix. `Account.id()` is the only spelling outside the enum tag. A model
under an account reads `account/model`.

- **vendor**: The `Provider` tag: `anthropic`, `openai`, `xai`, `openrouter`, `deepseek`, `google`,
  or `ds4`.
- **plan**: A consumer subscription, as in Claude Pro or Max, ChatGPT, and SuperGrok.
- **api**: The developer API of the vendor, billed per token.
- **cloud**: The cloud platform of the vendor, as in a Google Cloud project on the Agent Platform.
- **Agent Platform**: The short form of Gemini Enterprise Agent Platform, the Google Cloud platform
  that was Vertex AI. Name it in full with `(Vertex AI)` on the first mention of a document. Never
  write **Gemini Enterprise** alone, because that is another Google product.

## Checks

Run `sh scripts/check.sh` after a change. CI runs the same script and nothing else. The script
builds the binary, checks the format of the Zig code and of the documents, fails on a code comment,
and runs the tests with the reachability count. Its summary prints the runtime of each test binary.
The document check needs `npx`, which fetches Prettier once into its cache.

`zig run scripts/comment_scan.zig -- --fix build.zig src lib scripts` removes every comment, and
`zig fmt build.zig src lib scripts` formats the Zig code. `zig build unicode` regenerates the
Unicode data and its license notice. It uses the network, so it never joins the default build.

A rule that a tool can check belongs in `scripts/check.sh`, because an editor setting enforces
nothing. Add a mechanism for a problem that occurred. A risk without a case needs no machinery.
