# pith

A minimal, dependency-free coding-agent harness in Zig, inspired by
[pi](https://github.com/earendil-works/pi-mono). The agent loop is the easy part. The terminal UI
is the hard part. The goal here is a tiny hand-rolled TUI renderer that targets only modern
terminals (Ghostty, kitty, WezTerm). It keeps the line count as low as possible.

The name is a placeholder.

## Terminal

Pith uses synchronized output, true color, and the Kitty keyboard protocol. At startup it asks for
grapheme cluster processing (DECSET 2027), because it measures one grapheme cluster per cell step.

Pith does not test the terminal for these capabilities. An older terminal, such as Apple Terminal,
still shows the interface. In such a terminal an emoji can take the wrong width, a repaint can
flicker, and a color can be approximate.

## Build

```sh
zig build          # build + ZLS check
zig build run      # run
zig build test     # run all tests
```

Pith requires Zig 0.16.0.

## Trust

Project `AGENTS.md` files and skills are repository-controlled model instructions. Open untrusted
repositories only inside an external container or sandbox. Pith does not yet provide a permission
gate or a sandbox.

## Roadmap

Planned features and where they hook into the current architecture live in
[`BACKLOG.md`](BACKLOG.md).
