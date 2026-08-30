Drinky is a terminal-native coding agent that keeps the conversation in normal scrollback. It is a
dependency-free Zig program with a hand-written terminal renderer.

## Core rules

A core rule outranks every precedent in the repository and every consistency argument. An existing
behavior can be wrong. The judge of a review reads this list too.

- **An exit ends one thing.** No exit reaches past the step, the page, the turn, or the review that
  holds it.
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

Each module has one test artifact. A test runs only when its file is reachable from `root.zig` or an
analyzed test path. The `scripts/test-audit.sh` script fails if a source test does not run.

## Documents

`README.md` describes the stable user-facing product shape. Keep it concise and synchronized with
`FEATURES.md`. Keep roadmap and decision history out of the README.

`FEATURES.md` lists current capabilities with one short sentence each. It is an overview, not a
specification. Add a line when a capability lands. Delete the line when a capability goes away.

`BACKLOG.md` holds planned work in priority order. `TODO.md` is the git-ignored inbox that feeds it.
Delete a landed entry from `BACKLOG.md`. Read the `BACKLOG.md` header before you change either file.

## Name

- Use lowercase `drinky` for every machine-parsed name. Format it as code in Markdown.
- Use `Drinky` for the product in prose, comments, user-facing text, and titles.
- Never start a sentence with lowercase `drinky`.
- Reserve `DRINKY` for an environment variable. Do not use it in prose or code identifiers.

## Interface

`src/ui/role.zig` is the one seam from a semantic role to color bytes. A widget names a role and
writes no color of its own. The `colors` preview page is the one exception.

- A message that Drinky wrote for the user takes the user color and no box. The head of a loaded
  skill and the line of a retry attempt are such messages. Use the `user_note` block kind for each
  one, so no message box can forge it.
- An event block reports the state of the session, never a message. It stays muted, or it takes the
  error color for a failure.
- A user box holds typed text alone.
- Pin a new block kind in the role test of `src/ui/block.zig`, so no kind reaches a release
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

After code changes, always run:

```sh
zig build
zig fmt --check build.zig src lib scripts
sh scripts/test-audit.sh
```

`zig build unicode` regenerates `lib/terminal/unicode_data.zig` from the Unicode Character Database.
It uses the network. Run it manually, never as part of the default build.
