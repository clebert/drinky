Drinky is a terminal-native coding agent that keeps the conversation in normal scrollback. It is a
dependency-free Zig program with a hand-written terminal renderer.

## Core rules

A core rule outranks every precedent in the repository and every consistency argument. An existing
behavior can be wrong.

- **An exit ends one thing.** An exit is Esc, Ctrl+C, or Ctrl+D. No exit reaches past the step, the
  page, or the turn that holds it.
- **Drinky destroys nothing without a decision.** Where a press can mean something else, Drinky
  warns, and the second press of the same key is the decision.
- **A failure is not a decision.** Every draft and every message of the user survives it.

## Architecture

`build.zig` defines three modules. Dependencies flow from the app to the libraries only.

- `lib/terminal/` contains reusable terminal rendering, input, grapheme segmentation, and display
  width code. It knows nothing about the app or the agent.
- `lib/ai/` contains the provider-neutral agent core, provider transports, commands, and tools.
- `src/` contains the composition root, event loop, transcript, layout, and UI.

The libraries never import each other or the app. Only the `root.zig` file in a module can re-export
names.

Each module has one test binary. Zig compiles a test only when an import chain from the module root
reaches its file.

## Documents

`README.md` describes the stable product as a user sees it. Keep it concise and synchronized with
`FEATURES.md`. Keep the roadmap and the decision history out of `README.md`.

`FEATURES.md` lists current capabilities with one short sentence each. It is an overview, not a
specification. Add a line for a new capability. Delete the line of a removed capability.

`BACKLOG.md` holds planned work in priority order. `TODO.md` is the git-ignored inbox that feeds it.
Read the `BACKLOG.md` header before you change either file. Delete an entry from `BACKLOG.md` when
its work is done.

## Name

- Use lowercase `drinky` for every machine-parsed name. Format it as code in Markdown.
- Use `Drinky` for the product in prose, comments, user-facing text, and titles.
- Never start a sentence with lowercase `drinky`.
- Reserve `DRINKY` for an environment variable. Do not use it in prose or code identifiers.

## User interface

`src/ui/role.zig` is the one seam from a semantic role to color bytes. A widget names a role and
writes no color of its own.

- A message that Drinky wrote for the user takes the user color and no box. The head of a loaded
  skill and the line of a retry attempt are such messages. Use the `user_note` block kind for each
  one, so no message box can forge it.
- An event block reports the state of the session, never a message.
- A failed event paints its complete text in the error color. Every other event paints its complete
  text in the accent color.
- A source summary is not an event. Its labels take the accent color, and its values stay muted.
- A user box holds typed text alone.
- Add a new block kind to the role test of `src/ui/block.zig`, so no kind reaches a release
  unclassified.

## Writing style

Use ASD-STE100 Simplified Technical English for Markdown, code comments, and Drinky-generated text.

- Use active voice or a direct imperative. Put one topic in each sentence.
- Limit an instruction to 20 words and a description to 25 words.
- Use the same noun for the same concept. Prefer simple technical nouns.
- Use at most three nouns in a chain.
- Keep the articles. Use `must` for requirements and `can` for capabilities.
- Do not use `should`, `may`, `might`, or `would`.
- Do not use semicolons or contractions. Prefer a finite verb to an `-ing` form.
- Use a complete sentence for an event, a result, or a required action. Use sentence case and end
  punctuation.
- A label, a metric, or a control hint can be a fragment. Use clear casing and a colon between its
  key and its value.
- Wrap a dynamic error name in a complete sentence:
  `Drinky could not open {path} because of error {name}.`

The rules do not apply to literal technical identifiers or schemas. Preserve the meaning and the
terminal-width limits when you reword text.

## Checks

After a code change, run these commands:

```sh
zig build
zig fmt --check build.zig src lib scripts
sh scripts/test-audit.sh
```

The audit script runs `zig build test` and fails if a source test does not run.

`zig build unicode` regenerates `lib/terminal/unicode_data.zig` from the Unicode Character Database.
It uses the network. Run it manually, never as part of the default build.
