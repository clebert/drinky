Pith is a minimal, dependency-free coding-agent harness in Zig, inspired by pi. Its focus is a
hand-rolled terminal UI renderer for modern terminals such as Ghostty.

### Layout

The project has three modules, wired in `build.zig`. Imports flow one way: `pith` depends on both
libs, and the libs never import each other or the app. The module boundary makes a back-edge a
compile error:

- `lib/terminal/`: the reusable terminal rendering engine (`Tty`, `escape`, the reconciling `View`
  renderer, `Input`, the UAX #29 `grapheme` segmenter, and the display-`width` math built on it). It
  knows nothing about the app or the agent.
- `lib/ai/`: the provider-neutral agent core (`Agent`, `llm`, `models`, `provider`, `command`,
  `tool`, `anthropic`).
- `src/`: the `pith` app. It contains `main`, `App` (the composition root and event loop), the
  `Transcript` model, the `layout` projection onto the bounded window, and the `ui/` widgets drawn
  on the engine (`Editor`, `Picker`, `status`, and the `block`, `color`, and `paint` primitives).

Each module has its own test artifact. Its `root.zig` owns the public namespace and is the only
place where re-exports are allowed. A test only runs if its file is reachable from the module
`root.zig` through a re-export or an analyzed test path. An unwired test file passes silently.
Because of this, `test-audit.sh` fails CI when the number of tests that ran differs from the number
declared in source.

### Features

`FEATURES.md` is a human-readable overview of what pith supports, with one short sentence per
capability. Keep it current. When you land a capability, add its line and mark the matching
`BACKLOG.md` item done, if one exists. When a capability goes away, delete its line. Keep the file
short. It is an orientation document, not a spec. The tests are what guard against regressions.

### Writing style

Write all human-readable prose in ASD-STE100 Simplified Technical English. This covers all Markdown
files, the code comments, and every pith-generated user-facing string. Apply these practical rules:

- Write short sentences in the active voice or the direct imperative. Keep one topic per sentence.
  Use at most 20 words in an instruction and 25 in a description.
- Use the same noun for the same thing. Prefer a simple technical noun over a rare synonym. Break up
  a chain of more than three nouns.
- Keep the articles (`the`, `a`, `this`). Write `must` for a requirement and `can` for a capability.
  Do not write `should`, `may`, `might`, or `would`.
- Do not use semicolons or contractions (write `do not`, `cannot`). Prefer a finite verb to an -ing
  form. Keep the rest of normal English punctuation.
- A message that reports an event, a result, or a required action is a complete sentence in sentence
  case with end punctuation. A label, metric, or control hint can stay a fragment. Give a fragment
  clear casing and a colon between its key or action and its value (`Context: 42%`, `Esc: Cancel`).
- Wrap a dynamic error name in a complete sentence:
  `Pith could not open {path} because of error {name}.`

The rules do not cover provider, model, user, or shell output. They also do not cover literal
technical identifiers (command names, flags, JSON keys, tool argument schemas). Preserve the meaning
and the terminal-width limits when you reword a string.

### CI

After code changes, always run:

```sh
zig build
zig fmt --check build.zig src lib scripts
sh scripts/test-audit.sh
```

`zig build unicode` regenerates `lib/terminal/unicode_data.zig` (the display-width and
grapheme-break tables) from the Unicode Character Database. It fetches over the network. Run it by
hand, never as part of the default build.
