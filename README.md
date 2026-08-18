# pith

Pith is a coding agent for the terminal. You type a prompt. The model reads, searches, writes, and
edits the files in the working directory, and the reply streams into your scrollback.

Pith is written in Zig and has no dependencies. It talks to Anthropic and OpenAI, through a
subscription login or an API key. The agent loop is the easy part. The terminal UI is the hard part.
The goal is a small hand-rolled renderer for modern terminals, with the lowest line count possible.
The project takes its inspiration from [pi](https://github.com/earendil-works/pi-mono).

Status: early and unreleased. The name is a placeholder. There is no license yet.

## Run

Pith needs Zig 0.16.0, a POSIX system, and the `HOME` variable.

```sh
zig build          # build and ZLS check
zig build run      # run
zig build test     # run all tests
```

Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, or sign in with `/login`. `~/.pith/config.json` is
optional.

## Terminal

Pith uses synchronized output, the Kitty keyboard protocol, and grapheme cluster processing (DECSET
2027). It paints with the default colors and the ANSI slots 0 to 15 alone, so the theme of the
terminal owns every color.

Pith does not query the terminal. It reads `TERM_PROGRAM` for one exception: Apple Terminal has
neither the modern alternate screen nor the alternate-scroll mode, so it takes the older escapes and
the mouse reports. Every other terminal takes the modern path. An older terminal still shows the
interface, but an emoji can take the wrong width and a repaint can flicker.

## Trust

The `AGENTS.md` files and the skills of a repository are model instructions. Pith has no permission
gate and no sandbox. Open an untrusted repository in a container.

## More

- [`FEATURES.md`](FEATURES.md): every capability, one sentence each.
- [`BACKLOG.md`](BACKLOG.md): the planned work.
- [`docs/`](docs): the design notes.
