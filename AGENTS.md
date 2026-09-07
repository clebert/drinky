Drinky is a dependency-free Zig coding agent that keeps the conversation in terminal scrollback.

## Core rules

Core rules outrank existing behavior and repository precedent.

- **An exit ends one thing.** An exit is Esc, Ctrl+C, or Ctrl+D. No exit reaches past the step, the
  page, or the turn that holds it.
- **Drinky destroys nothing without a decision.** If a key press has another meaning, Drinky warns
  first. A second press of the same key confirms the action.
- **A failure is not a decision.** Every draft and user message survives a failure.

## Architecture

Dependencies flow from `src/` to `lib/terminal/` and `lib/ai/` only. The libraries must not import
each other or the app. The remote controller reports through its sink and must not depend on the
session.

## Documents

Keep `README.md` concise and limited to the stable product. Keep `README.md` and `FEATURES.md`
synchronized when capabilities change. Follow the maintenance rules in the `FEATURES.md` header and
footer. Read the `BACKLOG.md` header before you change `BACKLOG.md` or its inbox, `TODO.md`.

## Name

- Use `drinky` for machine-parsed names and format it as code in Markdown.
- Use `Drinky` for the product in prose and user-facing text.
- Never start a sentence with lowercase `drinky`.
- Reserve `DRINKY` for environment variables.

## User interface

`src/ui/role.zig` maps a role to terminal colors. A widget names a role and writes no color of its
own. `src/remote/html.zig` maps a role to the look of a Telegram message. Use `user_note` for
messages that Drinky writes for the user. An event reports session state. A user box holds typed
text alone.

## Writing style

Use ASD-STE100 Simplified Technical English for Markdown, code comments, and Drinky-generated text.

- Use active voice or a direct imperative. Put one topic in each sentence.
- Limit instructions to 20 words and descriptions to 25 words.
- Use simple technical nouns consistently. Use at most three nouns in a chain.
- Keep the articles. Use `must` for requirements and `can` for capabilities.
- Do not use `should`, `may`, `might`, `would`, semicolons, or contractions.
- Prefer a finite verb to an `-ing` form.
- Use complete sentences, sentence case, and end punctuation for events, results, and required
  actions.
- Labels, metrics, and control hints can be fragments. Use a colon between a key and its value.
- Put dynamic error names in complete sentences:
  `Drinky could not open {path} because of error {name}.`

These rules do not apply to literal technical identifiers and schemas. Preserve the meaning and the
terminal-width limits when you reword text.

## Remote vocabulary

- **bot**: The Telegram account with its token.
- **chat**: The private exchange of Telegram messages between the bot and the user.
- **Telegram**: The source of messages, updates, and actions.

Reserve **conversation** for the model conversation that `/new` clears. Never write **bot** for a
message from the user, because a bot message reads as a message that the bot wrote.

## Checks

After a code change, run these commands:

```sh
zig build
zig fmt --check build.zig src lib scripts
sh scripts/test-audit.sh
```

The audit script runs `zig build test` and fails if a source test does not run. Its summary prints
the runtime of each test binary.

Note the runtimes when you start a feature, and compare them when the feature is complete.
Investigate a repeatable increase of more than one second. A test that waits on wall-clock time is
the usual cause. Remove unnecessary waits and setup, not assertions or useful cases.

Run `zig build unicode` manually to regenerate Unicode data. It uses the network, so never add it to
the default build.
