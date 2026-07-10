# AGENTS.md

A minimal, dependency-free coding-agent harness in Zig, inspired by pi. The focus is a hand-rolled
terminal UI renderer for modern terminals (Ghostty and friends).

## CI

After code changes, always run:

```sh
zig build
zig fmt --check build.zig src
zig build test
```
