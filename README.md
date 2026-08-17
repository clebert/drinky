# pith

A minimal, dependency-free coding-agent harness in Zig, inspired by
[pi](https://github.com/earendil-works/pi-mono). The agent loop is the easy part. The terminal UI
is the hard part. The goal here is a tiny hand-rolled TUI renderer that targets only modern
terminals (Ghostty, kitty, WezTerm). It keeps the line count as low as possible.

The name is a placeholder.

## Terminal

Pith uses synchronized output and the Kitty keyboard protocol. At startup it asks for grapheme
cluster processing (DECSET 2027), because it measures one grapheme cluster per cell step. It paints
with the default colors and the ANSI slots 0 to 15 alone, so the theme of the terminal owns every
color.

Pith does not query the terminal for these capabilities. It reads `TERM_PROGRAM` for one exception.
Apple Terminal has neither the modern alternate screen nor the alternate-scroll mode, so a
full-window page there takes the older escapes and the mouse reports. Every other terminal takes the
modern path, and an older one still shows the interface. In such a terminal an emoji can take the
wrong width and a repaint can flicker.

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
