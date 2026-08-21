Drinky is a terminal-native coding agent that keeps the conversation in normal scrollback. It is a
dependency-free Zig program with a hand-written terminal renderer.

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

## Writing style

Use ASD-STE100 Simplified Technical English for Markdown, code comments, and Drinky-generated text.

- Use active voice or a direct imperative. Put one topic in each sentence.
- Limit an instruction to 20 words and a description to 25 words.
- Use the same noun for the same concept. Prefer simple technical nouns.
- Use at most three nouns in a chain.
- Keep the articles. Use `must` for requirements and `can` for capabilities.
- Do not use `should`, `may`, `might`, or `would`.
- Do not use semicolons or contractions. Prefer a finite verb to an `-ing` form.
- Use a complete sentence for an event, result, or required action. Use sentence case and end
  punctuation.
- A label, metric, or control hint can be a fragment. Use clear casing and a colon between its key
  and value.
- Wrap a dynamic error name in a complete sentence:
  `Drinky could not open {path} because of error {name}.`

The rules do not apply to literal technical identifiers or schemas. Preserve meaning and
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
