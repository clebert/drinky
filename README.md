# pith

A minimal, dependency-free coding-agent harness in Zig, inspired by
[pi](https://github.com/earendil-works/pi-mono). Writing the agent loop is the easy part; the hard
part is the terminal UI. The goal here is a tiny hand-rolled TUI renderer that targets only modern
terminals (Ghostty, kitty, WezTerm) and keeps the line count as low as possible.

The name is a placeholder.

## Build

```sh
zig build          # build + ZLS check
zig build run      # run
zig build test     # run all tests
```

Requires Zig 0.16.0.

## Docs

Research notes that inform the design live in [`docs/`](docs/):

- [`docs/pi-tui-internals.md`](docs/pi-tui-internals.md) — how pi's renderer actually works.
- [`docs/text-width.md`](docs/text-width.md) — the display-width problem and how to solve it in Zig.
- [`docs/architecture.md`](docs/architecture.md) — the renderer model chosen here, and the traps.
