# AGENTS.md

A minimal, dependency-free coding-agent harness in Zig, inspired by pi. The focus is a hand-rolled
terminal UI renderer for modern terminals (Ghostty and friends).

## Layout

Three modules, wired in `build.zig`. Imports flow one way — `pith` depends on both libs; the libs
never import each other or the app — and the module boundary makes a back-edge a compile error:

- `lib/terminal/` — the reusable terminal rendering engine (`Tty`, `escape`, the differential
  `Surface`, `Input`, the `cursor` marker, the UAX #29 `grapheme` segmenter, and the display-`width`
  math built on it). Knows nothing about the app or the agent.
- `lib/ai/` — the provider-neutral agent core (`Agent`, `llm`, `models`, `provider`, `command`,
  `tool`, `anthropic`).
- `src/` — the `pith` app: `main`, `App` (composition root + transcript block rendering), and the
  `ui/` widgets (`Editor`, `Picker`, `status`, `separator`) drawn on the engine.

Each module has its own test artifact, and its `root.zig` owns the public namespace (the only place
re-exports are allowed). A test only runs if its file is reachable from the module `root.zig` (via a
re-export or an analyzed test path); an unwired test file passes silently, so `test-audit.sh` fails
CI when the number of tests that ran differs from the number declared in source.

## CI

After code changes, always run:

```sh
zig build
zig fmt --check build.zig src lib scripts
sh scripts/test-audit.sh
```

`zig build unicode` regenerates `lib/terminal/unicode_data.zig` (the display-width and
grapheme-break tables) from the Unicode Character Database; it fetches over the network and is run
by hand, never as part of the default build.
