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

## Roadmap

Planned features and where they hook into the current architecture live in
[`BACKLOG.md`](BACKLOG.md).
